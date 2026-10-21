//! Hyprland compositor IPC, session half: the persistent event socket
//! (`.socket2.sock`), its listener fan-out, and the request plumbing that the
//! workspace manager drives.
//!
//! Hyprland runtime: endpoint discovery plus the event-stream connection; the raw socket transport lives
//! in `hyprland_ipc.zig`. Here a
//! listener is a plain function-pointer record with an explicit `ctx`, so the
//! same fan-out is reachable from a test without subclassing anything.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("../sock.zig");
const logz = @import("../logz.zig");
const desk = @import("desk.zig");
const ipc = @import("hyprland_ipc.zig");

const POLL = std.posix.POLL;

/// A registered event-source observer. `onEvent` receives one already-split
/// Hyprland event; `onCleanup` runs whenever the socket goes away (including a
/// routine `rescan`); `onStateChange` runs when the compositor connection is
/// lost, which is the cue for a backend to try reconnecting.
pub const Listener = struct {
    ctx: *anyopaque,
    onEvent: *const fn (ctx: *anyopaque, ev: []const u8, data: []const u8) void,
    onCleanup: *const fn (ctx: *anyopaque) void = ignore,
    onStateChange: *const fn (ctx: *anyopaque) void = ignore,

    fn ignore(_: *anyopaque) void {}
};

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,

    fd: i32 = -1,
    buffer: std.ArrayList(u8),
    paths: ipc.Paths = .{},
    paths_known: bool = false,
    lua_mode: bool = false,
    listeners: std.ArrayList(*const Listener),

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
    ) Self {
        return .{
            .alloc = alloc,
            .io = io,
            .env = env,
            .buffer = .empty,
            .listeners = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        ipc.freePaths(self.alloc, &self.paths);
        self.buffer.deinit(self.alloc);
        self.listeners.deinit(self.alloc);
    }

    pub fn canConnect(self: *const Self) bool {
        return self.fd >= 0;
    }

    pub fn isLuaConfig(self: *const Self) bool {
        return self.lua_mode;
    }

    pub fn pollHandle(self: *const Self) i32 {
        return self.fd;
    }

    pub fn registerListener(self: *Self, l: *const Listener) !void {
        try self.listeners.append(self.alloc, l);
    }

    pub fn unregisterListener(self: *Self, l: *const Listener) void {
        for (self.listeners.items, 0..) |item, i| {
            if (item == l) {
                _ = self.listeners.orderedRemove(i);
                return;
            }
        }
    }

    /// Re-reads the environment and re-probes both socket paths, for after a
    /// compositor restart. Every listener gets `onCleanup` first: their
    /// workspace snapshots belong to the connection that just died.
    pub fn rescan(self: *Self) void {
        ipc.freePaths(self.alloc, &self.paths);
        self.paths_known = false;
        self.lua_mode = false;
        self.resolveIfPending();
    }

    pub fn resolveIfPending(self: *Self) void {
        if (self.paths_known) return;
        self.paths_known = true;
        const found = ipc.resolvePaths(self.alloc, self.io, self.env) catch null;
        if (found) |p| {
            ipc.freePaths(self.alloc, &self.paths);
            self.paths = p;
        }
    }

    /// Opens the event socket and primes `lua_mode` from `j/status`, so that
    /// `jumpTo` can pick its dispatch syntax before the first workspace click.
    pub fn openSession(self: *Self) bool {
        if (!self.startSession()) return false;
        self.readConfig();
        return true;
    }

    pub fn startSession(self: *Self) bool {
        if (self.paths.ev.len == 0) {
            self.resolveIfPending();
            if (self.paths.ev.len == 0) return false;
        }
        self.shutdown();
        const fd = sock.createStream(false) catch {
            logz.log("hyprland: failed to create event socket", .{});
            return false;
        };
        if (sock.connectPath(fd, self.paths.ev) != null) {
            logz.log("hyprland: failed to connect event socket {s}", .{self.paths.ev});
            sock.closeFd(fd);
            return false;
        }
        sock.setNonblock(fd);
        self.fd = fd;
        return true;
    }

    pub fn shutdown(self: *Self) void {
        if (self.fd >= 0) {
            sock.closeFd(self.fd);
            self.fd = -1;
        }
        self.buffer.clearRetainingCapacity();
        for (self.listeners.items) |l| l.onCleanup(l.ctx);
    }

    /// Drives the session from the poll loop. A hangup or error tears the
    /// socket down and tells every listener the connection is gone; readable
    /// data drains into the line splitter.
    pub fn handlePoll(self: *Self, revents: i16) void {
        if (self.fd < 0) return;
        if ((revents & (POLL.ERR | POLL.HUP | POLL.NVAL)) != 0) {
            logz.log("hyprland: IPC disconnected", .{});
            self.shutdown();
            for (self.listeners.items) |l| l.onStateChange(l.ctx);
            return;
        }
        if ((revents & POLL.IN) != 0) self.drainSocket();
    }

    fn drainSocket(self: *Self) void {
        if (self.fd < 0) return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const rc = linux.recvfrom(self.fd, &buf, buf.len, linux.MSG.DONTWAIT, null, null);
            const e = linux.errno(rc);
            if (e == .SUCCESS) {
                if (rc == 0) {
                    self.shutdown();
                    return;
                }
                self.buffer.appendSlice(self.alloc, buf[0..rc]) catch {
                    self.shutdown();
                    return;
                };
                continue;
            }
            if (e == .AGAIN or e == .INTR) break;
            logz.log("hyprland: read from event socket failed: {}", .{e});
            self.shutdown();
            return;
        }
        self.processLines();
    }

    /// Splits whatever has arrived on complete newline boundaries and routes
    /// it; a trailing partial line stays buffered for the next drain, so a
    /// mid-line poll wakeup can never produce garbage events.
    fn processLines(self: *Self) void {
        while (true) {
            const nl = std.mem.indexOfScalar(u8, self.buffer.items, '\n') orelse return;
            // Copy before mutating: a listener that re-enters the runtime (a
            // `rescan` on a hung compositor, say) would otherwise invalidate
            // the slice mid-dispatch.
            const line = self.alloc.dupe(u8, self.buffer.items[0..nl]) catch {
                self.buffer.clearRetainingCapacity();
                return;
            };
            defer self.alloc.free(line);
            if (line.len > 0) self.routeEvent(line);
            // Drop the line *and* its terminator in one move; dropping only the
            // newline would leave the already-routed bytes at the head of the
            // buffer and route them a second time on the next drain.
            _ = self.buffer.replaceRange(self.alloc, 0, nl + 1, &.{}) catch {
                self.buffer.clearRetainingCapacity();
                return;
            };
        }
    }

    fn routeEvent(self: *Self, line: []const u8) void {
        const split = std.mem.indexOf(u8, line, ">>") orelse return;
        const ev = line[0..split];
        const payload = line[split + 2 ..];
        for (self.listeners.items) |l| l.onEvent(l.ctx, ev, payload);
    }

    fn readConfig(self: *Self) void {
        const text = self.sendCommand("j/status") orelse return;
        defer self.alloc.free(text);
        var parsed = ipc.parseReply(self.alloc, "j/status", text) orelse return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        if (std.mem.eql(u8, desk.jsonStr(parsed.value, "configProvider"), "lua")) {
            self.lua_mode = true;
        }
    }

    pub fn sendCommand(self: *Self, command: []const u8) ?[]u8 {
        self.resolveIfPending();
        return ipc.requestOnce(self.alloc, self.paths.req, command);
    }

    pub fn sendQuery(self: *Self, command: []const u8) ?std.json.Parsed(std.json.Value) {
        const text = self.sendCommand(command) orelse return null;
        defer self.alloc.free(text);
        return ipc.parseReply(self.alloc, command, text);
    }
};

// Tests

/// Records everything a runtime pushes at it, owning its copies: the runtime
/// only guarantees a listener sees valid slices for the duration of the call.
const Recorder = struct {
    alloc: std.mem.Allocator = undefined,
    got: std.ArrayList([]const u8) = .empty,
    payloads: std.ArrayList([]const u8) = .empty,
    cleaned: usize = 0,
    changed: usize = 0,

    fn init(alloc: std.mem.Allocator) Recorder {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *Recorder) void {
        for (self.got.items) |s| self.alloc.free(s);
        for (self.payloads.items) |s| self.alloc.free(s);
        self.got.deinit(self.alloc);
        self.payloads.deinit(self.alloc);
    }

    fn onEvent(ctx: *anyopaque, ev: []const u8, data: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.got.append(self.alloc, self.alloc.dupe(u8, ev) catch return) catch return;
        self.payloads.append(self.alloc, self.alloc.dupe(u8, data) catch return) catch return;
    }

    fn onCleanup(ctx: *anyopaque) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.cleaned += 1;
    }

    fn onStateChange(ctx: *anyopaque) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.changed += 1;
    }

    fn listener(self: *Recorder) Listener {
        return .{
            .ctx = @ptrCast(self),
            .onEvent = onEvent,
            .onCleanup = onCleanup,
            .onStateChange = onStateChange,
        };
    }
};

test "hyprland-run-ctx: event lines split and route, partial lines wait" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var rec = Recorder.init(t.allocator);
    defer rec.deinit();
    const listener = rec.listener();
    try rt.registerListener(&listener);

    // A complete line plus a partial one: only the complete line routes.
    try rt.buffer.appendSlice(t.allocator, "workspacev2>>2,2\ncreatework");
    rt.processLines();
    try t.expectEqual(@as(usize, 1), rec.got.items.len);
    try t.expectEqualStrings("workspacev2", rec.got.items[0]);
    try t.expectEqualStrings("2,2", rec.payloads.items[0]);
    try t.expectEqualStrings("creatework", rt.buffer.items);

    // Finish the partial line and check it lands too.
    try rt.buffer.appendSlice(t.allocator, "spacev2>>9,9\n");
    rt.processLines();
    try t.expectEqual(@as(usize, 2), rec.got.items.len);
    try t.expectEqualStrings("createworkspacev2", rec.got.items[1]);
    try t.expectEqual(@as(usize, 0), rt.buffer.items.len);

    // A line with no `>>` separator is dropped, not routed as an empty event.
    try rt.buffer.appendSlice(t.allocator, "garbage\n");
    rt.processLines();
    try t.expectEqual(@as(usize, 2), rec.got.items.len);

    // shutdown fans onCleanup out to every listener exactly once.
    rt.shutdown();
    try t.expectEqual(@as(usize, 1), rec.cleaned);
    try t.expectEqual(@as(i32, -1), rt.fd);

    // ...and a lost connection fans onStateChange out alongside it. The fake
    // session fd has to be a real one: `shutdown` closes it, and fd 0 is the
    // test runner's own IPC pipe.
    const dummy = try sock.createStream(false);
    rt.fd = dummy;
    rt.handlePoll(POLL.HUP);
    try t.expectEqual(@as(usize, 2), rec.cleaned);
    try t.expectEqual(@as(usize, 1), rec.changed);
    try t.expectEqual(@as(i32, -1), rt.fd);
}

test "hyprland-run-ctx: unregistering a listener stops its deliveries" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var rec = Recorder.init(t.allocator);
    defer rec.deinit();
    var listener = rec.listener();
    try rt.registerListener(&listener);
    rt.unregisterListener(&listener);
    try t.expectEqual(@as(usize, 0), rt.listeners.items.len);

    try rt.buffer.appendSlice(t.allocator, "workspace>>2\n");
    rt.processLines();
    try t.expectEqual(@as(usize, 0), rec.got.items.len);
}

test "hyprland-run-ctx: unresolved endpoints make every request a no-op" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    // No signature in the environment: resolution runs once, finds nothing,
    // and nothing downstream opens a socket or waits out a poll budget.
    try t.expect(!rt.paths_known);
    try t.expect(rt.sendCommand("j/status") == null);
    try t.expect(rt.paths_known);
    try t.expect(rt.sendQuery("j/status") == null);
    try t.expect(!rt.openSession());
    try t.expect(!rt.canConnect());
    try t.expect(!rt.isLuaConfig());

    // An empty command short-circuits even once paths *are* known — the path
    // itself is a real allocation, because `rescan` frees it below.
    const absent = try std.fs.path.join(t.allocator, &.{ "/tmp/opencode", "definitely-absent.sock" });
    rt.paths = .{ .req = absent, .ev = "" };
    try t.expect(rt.sendCommand("") == null);

    // `rescan` throws away the cached result and the lua verdict, then probes
    // again — so a restarted compositor gets a fresh answer instead of a stale
    // one, and the paths it left behind are freed rather than leaked.
    rt.lua_mode = true;
    rt.rescan();
    try t.expect(rt.paths_known);
    try t.expect(rt.paths.empty());
    try t.expect(!rt.isLuaConfig());
}
