//! mango workspace manager: the `watch all-monitors` subscription, its buffer
//! and its notification, plus the desk-source surface the shell polls.
//!
//! The
//! tables themselves live in `mango_ws_state.zig`, the event handler that
//! mutates them in `mango_ws_events.zig` and the read-back queries in
//! `mango_ws_query.zig`; this file is the socket, the buffer and the parts of
//! the interface that need a file descriptor to exist.
//!
//! mango is the one backend that also answers three things nobody else does:
//! `bringToFront`, per-output `windowsOnDesk`, and the two `ipc…` hooks
//! `power_actions` takes when the compositor is mango. They are all here.

const std = @import("std");
const linux = std.os.linux;
const POLL = std.posix.POLL;
const sock = @import("../sock.zig");
const logz = @import("../logz.zig");
const desk = @import("desk.zig");
const st = @import("mango_ws_state.zig");
const events = @import("mango_ws_events.zig");
const query = @import("mango_ws_query.zig");
const run_ctx = @import("mango_run_ctx.zig");

/// The one line that opens the subscription, newline included.
const watch_req = "watch all-monitors\n";
/// A stream that never sends a newline is a broken peer, not a monitor list
/// worth growing into. This matches the cap
/// `niri_run_ctx` and `niri_ws` already put on their reads.
const buf_max: usize = 1024 * 1024;
/// How long a poll may sleep while there is no session to wait on — 2000 ms,
/// which is what makes a mango that appears later get
/// noticed without spinning.
const retry_timeout_ms: i32 = 2000;

pub const Manager = struct {
    alloc: std.mem.Allocator,
    rt: *run_ctx.Runtime,
    resolver: ?desk.Resolver = null,
    notify: ?desk.Notify = null,
    fd: i32 = -1,
    buf: std.ArrayList(u8) = .empty,
    /// The `wl_output*` the Wayland binding has told us about, which is what
    /// `selectedOutput` matches monitor names back onto.
    known_outputs: std.ArrayList(?*anyopaque) = .empty,
    tables: st.Tables,

    const Self = @This();

    pub const name: []const u8 = "mango-ipc";

    /// Nothing is connected here: mango's constructor only stored the runtime,
    /// and `openConnection` is what the compositor-kind check calls.
    pub fn init(alloc: std.mem.Allocator, rt: *run_ctx.Runtime) Self {
        return .{ .alloc = alloc, .rt = rt, .tables = st.Tables.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.teardown();
        self.buf.deinit(self.alloc);
        self.known_outputs.deinit(self.alloc);
        self.tables.deinit();
    }

    // -- interface: change notification -------------------------------------

    pub fn onStateChange(self: *Self, cb: desk.Notify) void {
        self.notify = cb;
    }

    pub fn setOutputResolver(self: *Self, r: desk.Resolver) void {
        self.resolver = r;
    }

    // -- interface: life-cycle ----------------------------------------------

    pub fn ready(self: *const Self) bool {
        return self.fd >= 0;
    }

    /// Opens the subscription and pulls the client list behind it. A session
    /// that is already up counts as success without redoing either.
    pub fn openConnection(self: *Self) bool {
        if (self.fd >= 0) return true;
        if (!self.openSocket()) return false;
        events.fetchClients(&self.tables, self.rt);
        return true;
    }

    /// Nothing to observe and nothing to reset: mango's `teardown` closes the
    /// watch socket and empties both tables, and says nothing about it.
    pub fn teardown(self: *Self) void {
        self.shutSocket();
        self.known_outputs.clearRetainingCapacity();
        self.tables.clear();
        self.buf.clearRetainingCapacity();
    }

    // -- interface: output watching -----------------------------------------

    pub fn outputAttached(self: *Self, output: ?*anyopaque) void {
        const o = output orelse return;
        for (self.known_outputs.items) |known| {
            if (known == o) return;
        }
        self.known_outputs.append(self.alloc, o) catch {};
    }

    pub fn outputDetached(self: *Self, output: ?*anyopaque) void {
        var i: usize = 0;
        while (i < self.known_outputs.items.len) {
            if (self.known_outputs.items[i] == output) {
                _ = self.known_outputs.orderedRemove(i);
            } else i += 1;
        }
    }

    // -- interface: navigation ---------------------------------------------

    /// mango numbers tags from one, so the id it dispatches is the id it was
    /// given, not an index. An id that is not a positive tag number never
    /// reaches the socket: the taskbar feeds this raw region ids.
    pub fn jumpTo(self: *Self, id: []const u8) void {
        if (st.parseIdx(id) == null) return;
        if (self.tables.currentOutput()) |out| {
            if (out.name.len != 0) {
                _ = self.runCommand("viewcrossmon,{s},{s}", .{ id, out.name });
                return;
            }
        }
        _ = self.runCommand("view,{s}", .{id});
    }

    pub fn jumpToOnOutput(self: *Self, output: ?*anyopaque, id: []const u8) void {
        if (st.parseIdx(id) == null) return;
        const output_name = query.resolveName(self.resolver, output);
        if (output_name.len != 0) {
            _ = self.runCommand("viewcrossmon,{s},{s}", .{ id, output_name });
            return;
        }
        self.jumpTo(id);
    }

    /// Region-based focus jump, by shape with id fallback.
    pub fn jumpToRegion(self: *Self, output: ?*anyopaque, ws: desk.Region) void {
        const idx = st.idxFromRegion(ws) orelse return;
        var buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "{d}", .{idx + 1}) catch return;
        self.jumpToOnOutput(output, id);
    }

    pub fn bringToFront(self: *Self, windowId: []const u8) void {
        if (windowId.len == 0) return;
        _ = self.runCommand("focusid client,{s}", .{windowId});
    }

    // -- interface: desk queries --------------------------------------------

    pub fn allRegions(self: *Self) ![]desk.Region {
        return query.allRegions(self.alloc, &self.tables);
    }

    pub fn regionsOnOutput(self: *Self, output: ?*anyopaque) ![]desk.Region {
        return query.regionsOnOutput(self.alloc, &self.tables, self.resolver, output);
    }

    pub fn appsByDesk(self: *Self, output: ?*anyopaque) !desk.AppMap {
        return query.appsByDesk(self.alloc, &self.tables, self.resolver, output);
    }

    pub fn windowsOnDesk(self: *Self, output: ?*anyopaque) ![]desk.Win {
        return query.windowsOnDesk(self.alloc, &self.tables, self.resolver, output);
    }

    /// `taskbarMode` and `matchEntries` are not overridden by mango either:
    /// `workspace_manager.h` hands it the generic mode and the "nothing
    /// matched" map, and saying so keeps the fan-out's switch exhaustive.
    pub fn taskbarMode(_: *const Self) desk.TaskbarMode {
        return .generic;
    }

    pub fn matchEntries(self: *const Self) std.AutoHashMap(usize, desk.Win) {
        return std.AutoHashMap(usize, desk.Win).init(self.alloc);
    }

    // -- the two mango-only hooks -------------------------------------------

    pub fn selectedOutput(self: *const Self) ?*anyopaque {
        if (self.fd < 0) return null;
        return query.selectedOutput(&self.tables, self.known_outputs.items, self.resolver);
    }

    pub fn focusedToplevel(self: *const Self, output: ?*anyopaque) ?query.Focused {
        if (self.fd < 0) return null;
        return query.focusedToplevel(&self.tables, self.resolver, output);
    }

    // -- interface: poll integration ----------------------------------------

    pub fn eventFd(self: *const Self) i32 {
        return self.fd;
    }

    /// Interface default —
    /// the same answer ext-workspace gives, and *not* the bare `POLLIN` the
    /// fan-out reports when there is no backend at all.
    pub fn eventFlags(_: *const Self) i16 {
        return POLL.IN | POLL.HUP | POLL.ERR;
    }

    pub fn eventTimeout(self: *const Self) i32 {
        return if (self.fd >= 0) -1 else retry_timeout_ms;
    }

    pub fn onEvent(self: *Self, revents: i16) void {
        if (self.fd < 0) {
            _ = self.openConnection();
            return;
        }
        if ((revents & (POLL.HUP | POLL.ERR | POLL.NVAL)) != 0) {
            // The tables are deliberately left standing: close the
            // socket and announce the change, and a UI reading the last known
            // monitor list keeps showing something rather than going blank.
            self.shutSocket();
            self.emitChange();
            return;
        }
        if ((revents & POLL.IN) != 0) self.drainSocket();
    }

    // -- lifecycle internals -------------------------------------------------

    fn openSocket(self: *Self) bool {
        const path = self.rt.socketPath();
        if (path.len == 0) return false;
        // `AddrUn.init` truncates rather than failing, and a truncated path is
        // some other socket — overlong paths are refused outright.
        if (path.len >= sock.max_path) return false;

        const fd = sock.createStream(false) catch return false;
        if (sock.connectPath(fd, path) != null) {
            sock.closeFd(fd);
            return false;
        }
        // The subscription goes out while the socket is still blocking, so a
        // slow mango cannot make us spin on an unflushed socket.
        sock.sendAll(fd, watch_req) catch {
            sock.closeFd(fd);
            return false;
        };
        sock.setNonblock(fd);
        self.fd = fd;
        self.buf.clearRetainingCapacity();
        return true;
    }

    fn shutSocket(self: *Self) void {
        if (self.fd >= 0) {
            sock.closeFd(self.fd);
            self.fd = -1;
        }
        self.buf.clearRetainingCapacity();
    }

    /// Reads until the socket would block, applying every complete line as it
    /// arrives — interleaved with further reads.
    fn drainSocket(self: *Self) void {
        var chunk: [8192]u8 = undefined;
        var changed = false;
        while (true) {
            const rc = linux.recvfrom(self.fd, &chunk, chunk.len, 0, null, null);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) {
                if (e != .AGAIN) {
                    self.shutSocket();
                    changed = true;
                }
                break;
            }
            if (rc == 0) {
                self.shutSocket();
                changed = true;
                break;
            }
            if (self.buf.items.len + rc > buf_max) {
                logz.log("mango: monitor stream overran its buffer", .{});
                self.shutSocket();
                self.buf.clearRetainingCapacity();
                changed = true;
                break;
            }
            self.buf.appendSlice(self.alloc, chunk[0..rc]) catch {
                self.shutSocket();
                self.buf.clearRetainingCapacity();
                changed = true;
                break;
            };
            if (self.consumeLines()) changed = true;
        }
        if (changed) self.emitChange();
    }

    /// Applies every newline-terminated line and keeps the partial one back for
    /// the next read. Returns whether any of them was a monitor list.
    fn consumeLines(self: *Self) bool {
        var changed = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i < self.buf.items.len) : (i += 1) {
            if (self.buf.items[i] != '\n') continue;
            var line = self.buf.items[start..i];
            if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (events.processMsg(&self.tables, self.rt, line)) changed = true;
            start = i + 1;
        }
        if (start != 0) {
            const keep = self.buf.items.len - start;
            std.mem.copyForwards(u8, self.buf.items[0..keep], self.buf.items[start..]);
            self.buf.shrinkRetainingCapacity(keep);
        }
        return changed;
    }

    fn runCommand(self: *Self, comptime fmt: []const u8, args: anytype) bool {
        const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return false;
        defer self.alloc.free(text);
        return self.rt.runCommand(text);
    }

    fn emitChange(self: *const Self) void {
        if (self.notify) |n| n.run();
    }
};

// Tests

const t = std.testing;

const Notifier = struct {
    fired: usize = 0,

    fn cb(ctx: *anyopaque) void {
        const self: *Notifier = @ptrCast(@alignCast(ctx));
        self.fired += 1;
    }

    fn notify(self: *Notifier) desk.Notify {
        return .{ .ctx = @ptrCast(self), .call = cb };
    }
};

/// Built from concatenated halves rather than a `\\` literal on purpose: a
/// multiline literal carries the newline that ended each of its source lines,
/// and this payload has to be *one* line for the socket's framing to be what
/// the test is actually exercising.
const monitors_line =
    "{\"monitors\":[{\"name\":\"DP-1\",\"active\":true,\"x\":0,\"y\":0,\"width\":2560,\"height\":1440," ++
    "\"active_client\":{\"title\":\"Terminal\",\"appid\":\"otter-term\"}," ++
    "\"tags\":[{\"index\":1,\"is_active\":true,\"client_count\":1}," ++
    "{\"index\":2,\"is_active\":false,\"client_count\":0}]}]}";

/// Accepts one connection per canned reply, records each request line, and
/// answers. The accepted fd is non-blocking, so `readLine` polls out `EAGAIN`.
const Serve = struct {
    lfd: i32,
    replies: []const []const u8,
    alloc: std.mem.Allocator,
    seen: *std.ArrayList([]u8),

    fn run(self: @This()) void {
        for (self.replies) |reply| {
            const c = self.accept() orelse return;
            defer sock.closeFd(c);
            var slot: [512]u8 = undefined;
            if (readLine(c, &slot)) |req| {
                const copy = self.alloc.dupe(u8, req) catch continue;
                self.seen.append(self.alloc, copy) catch {
                    self.alloc.free(copy);
                    continue;
                };
            }
            if (reply.len != 0) sock.sendAll(c, reply) catch return;
        }
    }

    fn accept(self: @This()) ?i32 {
        const deadline = sock.nowMs() + 5000;
        while (sock.nowMs() < deadline) : ({
            _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
        }) {
            if (sock.acceptConn(self.lfd)) |c| return c;
        }
        return null;
    }

    fn readLine(c: i32, got: *[512]u8) ?[]u8 {
        var n: usize = 0;
        const deadline = sock.nowMs() + 5000;
        while (n < got.len and sock.nowMs() < deadline) {
            const rc = linux.recvfrom(c, got[n..].ptr, got.len - n, 0, null, null);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e == .AGAIN) {
                _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
                continue;
            }
            if (e != .SUCCESS) return null;
            if (rc == 0) return null;
            n += rc;
            if (std.mem.indexOfScalar(u8, got[0..n], '\n')) |nl| return got[0..nl];
        }
        return null;
    }
};

fn freeSeen(list: *std.ArrayList([]u8), alloc: std.mem.Allocator) void {
    for (list.items) |s| alloc.free(s);
    list.deinit(alloc);
}

fn bindListener(path: []const u8) !i32 {
    const lfd = try sock.createStream(false);
    errdefer sock.closeFd(lfd);
    try sock.bindPath(lfd, path);
    try sock.listenOn(lfd, 8);
    return lfd;
}

fn testRoot(buf: *[128]u8, tag: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const root = try std.fmt.bufPrint(buf, "/tmp/opencode/eh-mango-ws-{s}-{d}", .{ tag, std.os.linux.getpid() });
    cwd.deleteTree(t.io, root) catch {};
    try cwd.createDirPath(t.io, root);
    return root;
}

test "mango-ws: with no mango to talk to, the interface stays at its defaults" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run_ctx.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var note = Notifier{};
    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();
    m.onStateChange(note.notify());

    try t.expectEqualStrings("mango-ipc", Manager.name);
    try t.expect(!m.ready());
    try t.expect(!m.openConnection());
    try t.expectEqual(@as(i32, -1), m.eventFd());
    try t.expectEqual(@as(i16, POLL.IN | POLL.HUP | POLL.ERR), m.eventFlags());
    try t.expectEqual(@as(i32, retry_timeout_ms), m.eventTimeout());
    try t.expectEqual(@as(usize, 0), note.fired);

    // A poll with nothing behind it tries once more and stays quiet.
    m.onEvent(POLL.IN);
    try t.expect(!m.ready());
    try t.expectEqual(@as(usize, 0), note.fired);

    // Queries and navigation on an empty table are all "nothing", never a crash.
    try t.expectEqual(@as(usize, 0), (try m.allRegions()).len);
    try t.expectEqual(@as(usize, 0), (try m.regionsOnOutput(null)).len);
    try t.expectEqual(@as(usize, 0), (try m.appsByDesk(null)).count());
    try t.expectEqual(@as(usize, 0), (try m.windowsOnDesk(null)).len);
    try t.expectEqual(desk.TaskbarMode.generic, m.taskbarMode());
    var matches = m.matchEntries();
    defer matches.deinit();
    try t.expectEqual(@as(usize, 0), matches.count());
    try t.expect(m.selectedOutput() == null);
    try t.expect(m.focusedToplevel(null) == null);
    m.jumpTo("1");
    m.jumpToOnOutput(null, "1");
    m.jumpToRegion(null, .{ .id = "1" });
    m.bringToFront("0x10");
}

test "mango-ws: opening the session subscribes and pulls the client list" {
    var name_buf: [128]u8 = undefined;
    const root = try testRoot(&name_buf, "open");
    defer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};
    const path = try std.fs.path.join(t.allocator, &.{ root, "mango.sock" });
    defer t.allocator.free(path);

    const lfd = try bindListener(path);
    defer sock.closeFd(lfd);

    var seen: std.ArrayList([]u8) = .empty;
    defer freeSeen(&seen, t.allocator);
    // One connection for the subscription — which gets no answer, exactly as
    // mango treats it — and one for the client query.
    var thread = try std.Thread.spawn(
        .{},
        Serve.run,
        .{Serve{
            .lfd = lfd,
            .replies = &[_][]const u8{
                "",
                "{\"clients\":[{\"id\":9,\"title\":\"Nine\",\"appid\":\"foot\",\"monitor\":\"DP-1\",\"tags\":[1]}]}",
            },
            .alloc = t.allocator,
            .seen = &seen,
        }},
    );
    defer thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MANGO_INSTANCE_SIGNATURE", path);
    var rt = run_ctx.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var note = Notifier{};
    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();
    m.onStateChange(note.notify());

    try t.expect(m.openConnection());
    try t.expect(m.ready());
    try t.expectEqual(@as(i32, -1), m.eventTimeout());
    try t.expectEqualStrings("watch all-monitors", seen.items[0]);
    try t.expectEqualStrings("get all-clients", seen.items[1]);
    try t.expectEqual(@as(usize, 1), m.tables.clients.items.len);
    try t.expectEqualStrings("9", m.tables.clients.items[0].id);

    // Opening an already-open session is a no-op rather than a second socket.
    try t.expect(m.openConnection());
    try t.expectEqual(@as(usize, 2), seen.items.len);
}

test "mango-ws: the watch socket delivers monitor lines and notifies once" {
    var name_buf: [128]u8 = undefined;
    const root = try testRoot(&name_buf, "stream");
    defer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    // A signature pointing at nothing: the manager never connects on its own,
    // so this test hands it a socket it is allowed to read.
    try env.put("MANGO_INSTANCE_SIGNATURE", "/tmp/opencode/eh-mango-ws-stream-absent.sock");
    var rt = run_ctx.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var note = Notifier{};
    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();
    m.onStateChange(note.notify());

    var pair: [2]i32 = .{ -1, -1 };
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair);
    try t.expect(linux.errno(rc) == .SUCCESS);
    defer sock.closeFd(pair[0]);
    sock.setNonblock(pair[1]);
    m.fd = pair[1];
    try t.expect(m.ready());
    try t.expectEqual(@as(i32, -1), m.eventTimeout());

    // Half a line first: nothing is applied until its newline arrives.
    sock.sendAll(pair[0], monitors_line[0..40]) catch {};
    m.onEvent(POLL.IN);
    try t.expectEqual(@as(usize, 0), m.tables.outputs.count());
    try t.expectEqual(@as(usize, 0), note.fired);
    try t.expectEqual(@as(usize, 40), m.buf.items.len);

    // The rest completes the payload but not the line: mango is
    // line-delimited, and a monitor list that never ends is never applied.
    // `fetchClients` runs behind the line and has nowhere to answer from,
    // which must not stop the monitors landing once the newline does.
    sock.sendAll(pair[0], monitors_line[40..]) catch {};
    m.onEvent(POLL.IN);
    try t.expectEqual(@as(usize, 0), m.tables.outputs.count());
    try t.expectEqual(monitors_line.len, m.buf.items.len);
    try t.expectEqual(@as(usize, 0), note.fired);

    sock.sendAll(pair[0], "\n") catch {};
    m.onEvent(POLL.IN);
    try t.expectEqual(@as(usize, 1), m.tables.outputs.count());
    try t.expectEqualStrings("DP-1", m.tables.byName("DP-1").?.name);
    try t.expectEqual(@as(usize, 0), m.buf.items.len);
    try t.expectEqual(@as(usize, 1), note.fired);

    // Two monitors on one line, and the second has no name to be found by.
    sock.sendAll(pair[0], "{\"monitors\":[{\"name\":\"DP-1\",\"tags\":[]},{\"tags\":[]}]}\n") catch {};
    m.onEvent(POLL.IN);
    try t.expectEqual(@as(usize, 1), m.tables.outputs.count());
    try t.expectEqual(@as(usize, 2), note.fired);

    // A hang-up closes the session and announces it — but the last monitor
    // list stays, so the UI keeps something to draw.
    sock.closeFd(pair[0]);
    pair[0] = -1;
    m.onEvent(POLL.HUP);
    try t.expect(!m.ready());
    try t.expectEqual(@as(i32, -1), m.eventFd());
    try t.expectEqual(@as(usize, 1), m.tables.outputs.count());
    try t.expectEqual(@as(usize, 3), note.fired);
    try t.expectEqual(@as(i32, retry_timeout_ms), m.eventTimeout());

    // Teardown is what finally empties the tables, and it stays quiet: the
    // hang-up already announced the change.
    m.teardown();
    try t.expectEqual(@as(usize, 0), m.tables.outputs.count());
    try t.expectEqual(@as(usize, 0), m.tables.clients.items.len);
    try t.expectEqual(@as(usize, 3), note.fired);
}

test "mango-ws: a monitor line that never ends is cut off at a megabyte" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MANGO_INSTANCE_SIGNATURE", "/tmp/opencode/eh-mango-ws-flood-absent.sock");
    var rt = run_ctx.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var note = Notifier{};
    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();
    m.onStateChange(note.notify());

    var pair: [2]i32 = .{ -1, -1 };
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair);
    try t.expect(linux.errno(rc) == .SUCCESS);
    defer sock.closeFd(pair[0]);
    sock.setNonblock(pair[1]);
    m.fd = pair[1];

    const push = struct {
        fn run(fd: i32, data: []const u8) void {
            sock.sendAll(fd, data) catch {};
        }
    }.run;
    const flood = try t.allocator.alloc(u8, buf_max + 8192);
    defer t.allocator.free(flood);
    @memset(flood, 'x');

    var writer = try std.Thread.spawn(.{}, push, .{ pair[0], flood });
    defer writer.join();

    const deadline = sock.nowMs() + 4000;
    while (m.eventFd() >= 0 and sock.nowMs() < deadline) {
        m.onEvent(POLL.IN);
        _ = std.posix.poll(&[_]std.posix.pollfd{}, 2) catch 0;
    }

    try t.expectEqual(@as(i32, -1), m.eventFd());
    try t.expectEqual(@as(usize, 0), m.buf.items.len);
    try t.expect(m.eventTimeout() > 0);
    try t.expectEqual(@as(usize, 1), note.fired);
}

test "mango-ws: navigation only ever dispatches a positive tag number" {
    var name_buf: [128]u8 = undefined;
    const root = try testRoot(&name_buf, "jump");
    defer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};
    const path = try std.fs.path.join(t.allocator, &.{ root, "mango.sock" });
    defer t.allocator.free(path);

    const lfd = try bindListener(path);
    defer sock.closeFd(lfd);

    var seen: std.ArrayList([]u8) = .empty;
    defer freeSeen(&seen, t.allocator);
    var thread = try std.Thread.spawn(
        .{},
        Serve.run,
        .{Serve{
            .lfd = lfd,
            .replies = &([_][]const u8{"{\"success\":true}"} ** 6),
            .alloc = t.allocator,
            .seen = &seen,
        }},
    );
    defer thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MANGO_INSTANCE_SIGNATURE", path);
    var rt = run_ctx.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();

    // No monitor means no cross-monitor hint, so the plain command goes out.
    m.jumpTo("");
    m.jumpTo("0");
    m.jumpTo("-1");
    m.jumpTo("x");
    m.jumpTo("2x");
    m.bringToFront("");
    try t.expectEqual(@as(usize, 0), seen.items.len);

    m.jumpTo("2");
    m.bringToFront("0x2f");
    m.jumpToOnOutput(null, "3"); // no resolver, so it degrades to plain `view`
    try t.expectEqual(@as(usize, 3), seen.items.len);
    try t.expectEqualStrings("dispatch view,2", seen.items[0]);
    try t.expectEqualStrings("dispatch focusid client,0x2f", seen.items[1]);
    try t.expectEqualStrings("dispatch view,3", seen.items[2]);

    // With a monitor known, the jump names where to go. `decodeMonitor` gives
    // the table an owned row, which `m.deinit` is what frees.
    var doc = try std.json.parseFromSlice(
        std.json.Value,
        t.allocator,
        \\{"monitors":[{"name":"DP-1","active":true}]}
    ,
        .{},
    );
    defer doc.deinit();
    const mon = st.decodeMonitor(t.allocator, doc.value.object.get("monitors").?.array.items[0]).?;
    st.putOut(t.allocator, &m.tables.outputs, mon);

    m.jumpTo("4");
    try t.expectEqual(@as(usize, 4), seen.items.len);
    try t.expectEqualStrings("dispatch viewcrossmon,4,DP-1", seen.items[3]);

    var output_name: []const u8 = "HDMI-A-1";
    m.setOutputResolver(.{ .ctx = @ptrCast(&output_name), .call = fixedResolver });
    m.jumpToOnOutput(@ptrFromInt(0x1000), "5");
    try t.expectEqual(@as(usize, 5), seen.items.len);
    try t.expectEqualStrings("dispatch viewcrossmon,5,HDMI-A-1", seen.items[4]);

    // A region carries the tag number back in either shape.
    m.jumpToRegion(@ptrFromInt(0x1000), .{ .id = "7", .coordinates = &[_]u32{6} });
    try t.expectEqual(@as(usize, 6), seen.items.len);
    try t.expectEqualStrings("dispatch viewcrossmon,7,HDMI-A-1", seen.items[5]);
}

fn fixedResolver(ctx: *anyopaque, _: ?*anyopaque) []const u8 {
    const name: *[]const u8 = @ptrCast(@alignCast(ctx));
    return name.*;
}

test "mango-ws: output watching records each handle exactly once" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run_ctx.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();

    const a: *anyopaque = @ptrFromInt(0x1000);
    const b: *anyopaque = @ptrFromInt(0x2000);
    m.outputAttached(null);
    m.outputAttached(a);
    m.outputAttached(a);
    m.outputAttached(b);
    try t.expectEqual(@as(usize, 2), m.known_outputs.items.len);

    m.outputDetached(a);
    m.outputDetached(a); // detaching twice is fine
    try t.expectEqual(@as(usize, 1), m.known_outputs.items.len);
    try t.expect(m.known_outputs.items[0] == b);
}
