//! The Hyprland workspace manager plus the binding to a
//! live `HyprlandRuntime`.
//!
//! Here the file
//! is split by concern because the one TU was doing four unrelated jobs:
//!
//! | file                         | what it owns                                   |
//! |------------------------------|------------------------------------------------|
//! | `hyprland_ws_state.zig`      | the tables and their mutations                 |
//! | `hyprland_ws_snapshot.zig`   | parsing the three `j/…` documents              |
//! | `hyprland_ws_query.zig`      | reading the tables back out for the interface  |
//! | `hyprland_ws_events.zig`     | `socket2` payload → mutation, via a `Host`      |
//! | this file                    | interface implementation and runtime binding   |
//!
//! This is the only one of the five that knows a socket exists.

const std = @import("std");
const desk = @import("desk.zig");
const codec = @import("hyprland_ws_codec.zig");
const ws_state = @import("hyprland_ws_state.zig");
const ws_query = @import("hyprland_ws_query.zig");
const ws_events = @import("hyprland_ws_events.zig");
const run = @import("hyprland_run_ctx.zig");
const logz = @import("../logz.zig");

const POLL = std.posix.POLL;

pub const State = ws_state.State;

/// Change notification — shared, see `desk.zig`.
pub const Notify = desk.Notify;

/// `IOutputNameLookup::Resolver`: `wl_output*` → the compositor's name for it.
/// Shared — see `desk.Resolver`; mango installs exactly the same shape.
pub const Resolver = desk.Resolver;

pub const Manager = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    backend: *run.Runtime,
    state: State,
    notify: ?Notify = null,
    resolver: ?Resolver = null,
    /// Registered with the runtime for the lifetime of this manager, which is
    /// why it lives on the heap: the listener keeps a pointer back to us.
    listener: run.Listener,

    const Self = @This();

    pub const name: []const u8 = "hyprland-ipc";

    /// Heap-allocated so `&self.listener` stays valid for as long as the
    /// runtime holds it. The listener is registered before this returns.
    pub fn create(
        alloc: std.mem.Allocator,
        io: std.Io,
        backend: *run.Runtime,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .backend = backend,
            .state = State.init(alloc),
            .listener = .{
                .ctx = @ptrCast(self),
                .onEvent = onEventThunk,
                .onCleanup = onCleanupThunk,
                .onStateChange = onStateChangeThunk,
            },
        };
        try backend.registerListener(&self.listener);
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.backend.unregisterListener(&self.listener);
        const alloc = self.alloc;
        self.state.deinit();
        alloc.destroy(self);
    }

    // -- interface: life-cycle --------------------------------------------

    /// Shutdown the backend, then run the cleanup listeners.
    /// every listener. Calling `clear` again is harmless and covers the case
    /// where the runtime had no socket to close.
    pub fn teardown(self: *Self) void {
        self.backend.shutdown();
        self.state.clear();
    }

    pub fn ready(self: *const Self) bool {
        return self.backend.canConnect();
    }

    /// Opens the event session and pulls the first snapshot, including the
    /// lua-config verdict.
    pub fn openConnection(self: *Self) bool {
        if (!self.backend.openSession()) return false;
        self.reloadSnapshot();
        return true;
    }

    pub fn onStateChange(self: *Self, cb: Notify) void {
        self.notify = cb;
    }

    pub fn setOutputResolver(self: *Self, r: Resolver) void {
        self.resolver = r;
    }

    // -- interface: navigation --------------------------------------------

    /// `dispatch workspace N`, in whichever syntax this session accepts. Ids
    /// that are not a positive workspace number are silently dropped — the
    /// taskbar feeds this raw region ids, and `special:xyz`-style names do not
    /// reach a `dispatch` call that would fail anyway.
    pub fn jumpTo(self: *Self, id: []const u8) void {
        const ws_id = codec.findIdForName(id);
        if (ws_id <= 0) return;
        var buf: [96]u8 = undefined;
        const cmd = codec.jumpCommand(&buf, self.backend.isLuaConfig(), ws_id) orelse return;
        // The reply is ours to release either way: `sendCommand` hands back an
        // owned buffer, dropped after reading.
        if (self.backend.sendCommand(cmd)) |reply| {
            self.alloc.free(reply);
        } else {
            logz.log("hyprland: workspace focus request went unanswered: {s}", .{cmd});
        }
    }

    pub fn jumpToOnOutput(self: *Self, output: ?*anyopaque, id: []const u8) void {
        _ = output; // Hyprland focuses the workspace wherever it lives
        self.jumpTo(id);
    }

    pub fn jumpToRegion(self: *Self, output: ?*anyopaque, ws: desk.Region) void {
        _ = output;
        self.jumpTo(ws.id);
    }

    // -- interface: desk queries ------------------------------------------

    pub fn allRegions(self: *Self) ![]desk.Region {
        return ws_query.allRegions(&self.state);
    }

    /// Regions on one output, falling back to "everything" whenever the
    /// name lookup came back empty, so an unresolvable output still gets a
    /// taskbar rather than a blank one.
    pub fn regionsOnOutput(self: *Self, output: ?*anyopaque) ![]desk.Region {
        const r = self.resolver orelse return ws_query.allRegions(&self.state);
        if (output == null) return ws_query.allRegions(&self.state);
        const output_name = r.call(r.ctx, output);
        if (output_name.len == 0) return ws_query.allRegions(&self.state);
        return ws_query.regionsOnMonitor(&self.state, output_name);
    }

    /// The output parameter is ignored: Hyprland's client list is global and
    /// windows are attributed to desks by their workspace id, so there is
    /// nothing per-output to filter.
    pub fn appsByDesk(self: *Self, output: ?*anyopaque) !desk.AppMap {
        _ = output;
        return ws_query.appsByDesk(&self.state);
    }

    pub fn focusedWindowTitle(self: *const Self) ?[]const u8 {
        return ws_query.focusedWindowTitle(&self.state);
    }

    // -- interface: taskbar defaults Hyprland never overrides --------------

    pub fn taskbarMode(_: *const Self) desk.TaskbarMode {
        return .generic;
    }

    pub fn matchEntries(self: *const Self) std.AutoHashMap(usize, desk.Win) {
        return std.AutoHashMap(usize, desk.Win).init(self.alloc);
    }

    pub fn windowsOnDesk(_: *const Self) []const desk.Win {
        return &.{};
    }

    // -- interface: poll integration ---------------------------------------

    pub fn eventFd(self: *const Self) i32 {
        return self.backend.pollHandle();
    }

    pub fn eventFlags(_: *const Self) i16 {
        return POLL.IN | POLL.HUP | POLL.ERR;
    }

    pub fn eventTimeout(_: *const Self) i32 {
        return -1;
    }

    /// Drives the runtime's socket read; events come back through `onEventThunk`.
    pub fn handlePoll(self: *Self, revents: i16) void {
        self.backend.handlePoll(revents);
    }

    // -- change notification -----------------------------------------------

    /// Full snapshot reload: three queries, recompute the flags, one
    /// notification for the batch.
    pub fn reloadSnapshot(self: *Self) void {
        ws_events.reload(self.host(), &self.state);
    }

    fn notifyListeners(self: *Self) void {
        if (self.notify) |n| n.run();
    }

    fn host(self: *Self) ws_events.Host {
        return .{
            .ctx = @ptrCast(self),
            .query = queryThunk,
            .reload = reloadThunk,
            .notify = notifyThunk,
        };
    }

    // -- listener thunks ----------------------------------------------------

    fn onEventThunk(ctx: *anyopaque, ev: []const u8, data: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        ws_events.apply(self.host(), &self.state, ev, data);
    }

    /// The socket went away. The runtime calls this *before* `onStateChange`,
    /// so listeners see an empty table followed by a notification — the cue to
    /// re-initialise once the compositor is back.
    fn onCleanupThunk(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state.clear();
    }

    fn onStateChangeThunk(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.notifyListeners();
    }

    fn queryThunk(ctx: *anyopaque, command: []const u8) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.backend.sendCommand(command);
    }

    fn reloadThunk(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reloadSnapshot();
    }

    fn notifyThunk(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.notifyListeners();
    }
};

// Tests

const t = std.testing;
const sock = @import("../sock.zig");
const linux = std.os.linux;

const Notifier = struct {
    fired: usize = 0,

    fn cb(ctx: *anyopaque) void {
        const self: *Notifier = @ptrCast(@alignCast(ctx));
        self.fired += 1;
    }

    fn notify(self: *Notifier) Notify {
        return .{ .ctx = @ptrCast(self), .call = cb };
    }
};

fn addSpace(s: *State, id: i32, name: []const u8, monitor: []const u8) void {
    const owned_name = s.alloc.dupe(u8, name) catch return;
    const owned_monitor = s.alloc.dupe(u8, monitor) catch {
        s.alloc.free(owned_name);
        return;
    };
    s.spaces.append(s.alloc, .{ .id = id, .name = owned_name, .monitor = owned_monitor }) catch {
        s.alloc.free(owned_name);
        s.alloc.free(owned_monitor);
    };
}

fn fixedResolver(ctx: *anyopaque, output: ?*anyopaque) []const u8 {
    _ = ctx;
    _ = output;
    return "DP-2";
}

test "hyprland-ws: the runtime listener routes events into the manager" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var note = Notifier{};
    const m = try Manager.create(t.allocator, t.io, &rt);
    defer m.destroy();
    m.onStateChange(note.notify());

    // The listener is registered for the manager's lifetime and points back at
    // the manager, which is why `create` hands out a heap allocation.
    try t.expectEqual(@as(usize, 1), rt.listeners.items.len);
    try t.expect(rt.listeners.items[0] == &m.listener);

    addSpace(&m.state, 2, "2", "DP-2");
    m.state.putActive("DP-2", 2);
    m.state.refreshFlags();
    try t.expect(m.state.findSpace(2).?.active);

    // An event the backend understands mutates the table and notifies.
    m.listener.onEvent(m.listener.ctx, "focusedmonv2", "DP-1,2");
    try t.expectEqual(@as(i32, 2), m.state.active_map.get("DP-1").?);
    try t.expectEqual(@as(usize, 1), note.fired);

    // One it does not understand changes nothing and stays quiet — the same
    // event goes through the v1 twin and the title noise the fixture carries.
    m.listener.onEvent(m.listener.ctx, "windowtitlev2", "0x10,some title");
    m.listener.onEvent(m.listener.ctx, "activewindowv2", "0x10");
    try t.expectEqual(@as(usize, 1), note.fired);

    // `configreloaded` reloads through the runtime — which answers nothing here,
    // so the tables survive — and still notifies once for the batch.
    m.listener.onEvent(m.listener.ctx, "configreloaded", "");
    try t.expectEqual(@as(usize, 2), note.fired);
    try t.expectEqual(@as(usize, 1), m.state.spaces.items.len);

    // The event socket belongs to the runtime, so a manager that never opened
    // one is never `ready`, and a poll on a runtime with no fd is a no-op.
    try t.expect(!m.ready());
    m.handlePoll(POLL.IN);
    try t.expectEqual(@as(usize, 2), note.fired);
}

test "hyprland-ws: a lost connection clears the tables and then notifies" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var note = Notifier{};
    const m = try Manager.create(t.allocator, t.io, &rt);
    defer m.destroy();
    m.onStateChange(note.notify());
    addSpace(&m.state, 1, "1", "DP-1");

    // A stand-in for the event socket: `handlePoll` bails out when there is no
    // fd, so give it one it is allowed to close.
    const fake = try sock.createStream(false);
    rt.fd = fake;
    try t.expect(m.eventFd() == fake);
    rt.handlePoll(POLL.HUP);

    // Order matters: `onCleanup` empties the state first, `onStateChange` then
    // tells the UI to read it — which is how a reconnect gets noticed.
    try t.expectEqual(@as(usize, 0), m.state.spaces.items.len);
    try t.expectEqual(@as(usize, 1), note.fired);
    try t.expect(!m.ready());
    try t.expectEqual(@as(i32, -1), m.eventFd());
}

test "hyprland-ws: connection, poll defaults, and teardown" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var note = Notifier{};
    const m = try Manager.create(t.allocator, t.io, &rt);
    defer m.destroy();
    m.onStateChange(note.notify());

    try t.expectEqualStrings("hyprland-ipc", Manager.name);
    try t.expect(!m.ready());
    // No `HYPRLAND_INSTANCE_SIGNATURE` in this environment, so the session
    // cannot start and no snapshot is pulled.
    try t.expect(!m.openConnection());
    try t.expectEqual(@as(usize, 0), note.fired);

    try t.expectEqual(@as(i16, POLL.IN | POLL.HUP | POLL.ERR), m.eventFlags());
    try t.expectEqual(@as(i32, -1), m.eventTimeout());

    addSpace(&m.state, 1, "1", "DP-1");
    m.teardown();
    try t.expectEqual(@as(usize, 0), m.state.spaces.items.len);
    // Teardown closes the runtime's socket but leaves the listener registered;
    // only `destroy` detaches it.
    try t.expectEqual(@as(usize, 1), rt.listeners.items.len);
}

test "hyprland-ws: interface queries pass through to the state" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();
    const m = try Manager.create(t.allocator, t.io, &rt);
    defer m.destroy();

    addSpace(&m.state, 2, "2", "DP-2");
    addSpace(&m.state, 1, "", "DP-1"); // no name: the id stands in
    m.state.putActive("DP-2", 2);
    m.state.relocate(0x10, 2);
    m.state.setWindowMeta(0x10, "otter-term", "A fixture title");
    m.state.refreshFlags();

    const all = try m.allRegions();
    defer desk.freeRegionList(t.allocator, all);
    try t.expectEqual(@as(usize, 2), all.len);
    try t.expectEqualStrings("1", all[0].id);
    try t.expectEqualStrings("1", all[0].name); // id fallback
    try t.expectEqualStrings("2", all[1].id);
    try t.expectEqualStrings("2", all[1].name);
    try t.expect(all[1].active);

    // With no resolver set, every output reports every workspace —
    // an unset resolver means "all".
    const out: *anyopaque = @ptrFromInt(0x1000);
    var flag: u8 = 0;
    const unset = try m.regionsOnOutput(out);
    defer desk.freeRegionList(t.allocator, unset);
    try t.expectEqual(@as(usize, 2), unset.len);

    m.setOutputResolver(.{ .ctx = @ptrCast(&flag), .call = fixedResolver });
    const on_dp2 = try m.regionsOnOutput(out);
    defer desk.freeRegionList(t.allocator, on_dp2);
    try t.expectEqual(@as(usize, 1), on_dp2.len);
    try t.expectEqualStrings("2", on_dp2[0].id);

    // A null output means no name to look up, so the fallback still applies.
    const no_output = try m.regionsOnOutput(null);
    defer desk.freeRegionList(t.allocator, no_output);
    try t.expectEqual(@as(usize, 2), no_output.len);

    var apps = try m.appsByDesk(null);
    defer desk.freeAppMap(t.allocator, &apps);
    try t.expectEqual(@as(usize, 1), apps.count());
    try t.expectEqualStrings("otter-term", apps.get("2").?.items[0]);
    try t.expectEqualStrings("A fixture title", m.focusedWindowTitle().?);

    try t.expectEqual(desk.TaskbarMode.generic, m.taskbarMode());
    try t.expectEqual(@as(usize, 0), m.windowsOnDesk().len);
    var matches = m.matchEntries();
    defer matches.deinit();
    try t.expectEqual(@as(usize, 0), matches.count());

    // An empty state has nothing to report and no title to name.
    m.state.clear();
    const nothing = try m.allRegions();
    defer desk.freeRegionList(t.allocator, nothing);
    try t.expectEqual(@as(usize, 0), nothing.len);
    try t.expect(m.focusedWindowTitle() == null);
}

// -- jumpTo over a real socket ---------------------------------------------

fn acceptWithTimeout(lfd: i32, budget_ms: i64) ?i32 {
    const deadline = sock.nowMs() + budget_ms;
    while (sock.nowMs() < deadline) {
        var pfd = [1]std.posix.pollfd{.{ .fd = lfd, .events = POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, 5) catch 0;
        if (ready > 0) {
            if (sock.acceptConn(lfd)) |c| return c;
        }
    }
    return null;
}

/// Reads one command to EOF and answers it, then hangs up.
fn readAndReply(c: i32, out: []u8) usize {
    var n: usize = 0;
    while (n < out.len) {
        const rc = linux.recvfrom(c, out[n..].ptr, out.len - n, 0, null, null);
        const e = linux.errno(rc);
        if (e == .SUCCESS) {
            if (rc == 0) break;
            n += rc;
            continue;
        }
        if (e == .INTR) continue;
        if (e == .AGAIN) {
            _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
            continue;
        }
        break;
    }
    sock.sendAll(c, "ok") catch {};
    return n;
}

const Capture = struct {
    lfd: i32,
    got: [256]u8 = undefined,
    len: usize = 0,

    fn run(self: *Capture) void {
        const c = acceptWithTimeout(self.lfd, 5000) orelse return;
        defer sock.closeFd(c);
        self.len = readAndReply(c, &self.got);
    }
};

test "hyprland-ws: jumpTo only dispatches ids that are a positive workspace number" {
    const cwd = std.Io.Dir.cwd();
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/opencode/eh-hypr-ws-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(t.io, root) catch {};
    cwd.deleteTree(t.io, root) catch {};
    try cwd.createDirPath(t.io, root);
    const path = try std.fs.path.join(t.allocator, &.{ root, ".socket.sock" });
    defer t.allocator.free(path);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, path);
    try sock.listenOn(lfd, 4);

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();
    // `paths` is freed by `deinit`, so this is a second allocation, not `path`.
    rt.paths = .{ .req = try std.fs.path.join(t.allocator, &.{ root, ".socket.sock" }), .ev = "" };
    rt.paths_known = true;

    const m = try Manager.create(t.allocator, t.io, &rt);
    defer m.destroy();

    // Nothing that is not a positive workspace number may reach the socket.
    m.jumpTo("");
    m.jumpTo(" ");
    m.jumpTo("abc");
    m.jumpTo("0");
    m.jumpTo("-1");
    m.jumpTo("0x2"); // `sscanf` reads `0`, which is not a workspace either
    m.jumpTo("2147483648"); // out of `int` range
    m.jumpTo("special:magic"); // a named workspace has no number to dispatch
    var pfd = [1]std.posix.pollfd{.{ .fd = lfd, .events = POLL.IN, .revents = 0 }};
    try t.expectEqual(@as(usize, 0), std.posix.poll(&pfd, 50) catch 0);

    var cap = Capture{ .lfd = lfd };
    const thread = try std.Thread.spawn(.{}, Capture.run, .{&cap});

    // This session is not a lua-config one, so the plain dispatch form is what
    // goes out — the lua spelling is `hyprland_ws_codec.zig`'s job to select.
    m.jumpTo("2");
    thread.join();
    try t.expectEqualStrings("dispatch workspace 2", cap.got[0..cap.len]);
}
