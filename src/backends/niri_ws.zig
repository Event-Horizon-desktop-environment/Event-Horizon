//! niri workspace manager: the persistent `EventStream` connection and the
//! metadata-backend surface the shell polls.
//!
//! The tables themselves live in `niri_ws_state.zig`, the event handlers that
//! mutate them in `niri_ws_events.zig` and the read-back queries in
//! `niri_ws_query.zig`; this file is the socket, the buffer, the retry
//! backoff and the notification callbacks — the parts that need a file
//! descriptor to exist.
//!
//! It is the extra metadata source `power_actions` hangs
//! off the workspace tables when the compositor is niri, and it hands out
//! plain values instead of being driven by the Wayland binding.

const std = @import("std");
const linux = std.os.linux;
const POLL = std.posix.POLL;
const sock = @import("../sock.zig");
const logz = @import("../logz.zig");
const desk = @import("desk.zig");
const st = @import("niri_ws_state.zig");
const events = @import("niri_ws_events.zig");
const query = @import("niri_ws_query.zig");
const run_ctx = @import("niri_run_ctx.zig");

/// First reconnect delay (2000 ms), doubling up to a 30000 ms ceiling.
const retry_init_ms: i64 = 2000;
const retry_max_ms: i64 = 30000;
/// `C_BufMax`: a stream that never sends a newline is a broken peer, not a
/// workspace list worth growing into.
const buf_max: usize = 1024 * 1024;
/// The one request that opens the stream, newline included.
const event_req = "\"EventStream\"\n";

pub const Manager = struct {
    alloc: std.mem.Allocator,
    rt: *run_ctx.Runtime,
    fd: i32 = -1,
    buf: std.ArrayList(u8) = .empty,
    tables: st.Tables,
    /// Steady-clock millisecond the next connect attempt is allowed, 0 for
    /// "not waiting on anything". niri's own clock has no epoch to read, so
    /// `sock.nowMs()` stands in for `steady_clock::now()`.
    retry_at: i64 = 0,
    backoff_ms: i64 = retry_init_ms,
    notify: ?desk.Notify = null,
    view_notify: ?desk.Notify = null,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, rt: *run_ctx.Runtime) Self {
        var m = Self{ .alloc = alloc, .rt = rt, .tables = st.Tables.init(alloc) };
        if (m.rt.canConnect()) m.tryConnect();
        return m;
    }

    pub fn deinit(self: *Self) void {
        self.teardown();
        self.buf.deinit(self.alloc);
        self.tables.deinit();
    }

    // -- interface: change notification -------------------------------------

    pub fn onStateChange(self: *Self, cb: desk.Notify) void {
        self.notify = cb;
    }

    pub fn onOverviewChange(self: *Self, cb: desk.Notify) void {
        self.view_notify = cb;
    }

    // -- interface: overview capability -------------------------------------

    /// The overview exists only where there is a niri to ask about it.
    pub fn supportsOverview(self: *Self) bool {
        return self.rt.canConnect();
    }

    pub fn hasOverview(self: *const Self) bool {
        return self.tables.known_overview;
    }

    pub fn overviewActive(self: *const Self) bool {
        return self.tables.overview_open;
    }

    // -- interface: poll integration ----------------------------------------

    pub fn eventFd(self: *const Self) i32 {
        return self.fd;
    }

    pub fn eventFlags(_: *const Self) i16 {
        return POLL.IN | POLL.HUP | POLL.ERR;
    }

    /// How long a poll may sleep before the next connect attempt is due:
    /// forever while the stream is up or the compositor is unreachable, 0
    /// while nothing has scheduled a retry, and the remaining delay otherwise.
    pub fn eventTimeout(self: *Self) i32 {
        if (self.fd >= 0 or !self.rt.canConnect()) return -1;
        if (self.retry_at == 0) return 0;
        const rem = self.retry_at - sock.nowMs();
        return @intCast(@min(@max(rem, 0), std.math.maxInt(i32)));
    }

    pub fn onEvent(self: *Self, revents: i16) void {
        if (!self.rt.canConnect()) return;
        if (self.fd < 0) {
            self.tryConnect();
            return;
        }
        if ((revents & (POLL.ERR | POLL.HUP | POLL.NVAL)) != 0) {
            self.closeFd(true);
            return;
        }
        if ((revents & POLL.IN) != 0) self.readFd();
    }

    // -- interface: queries -------------------------------------------------

    pub fn sync(self: *const Self, regions: []desk.Region, out_name: []const u8) !void {
        return query.sync(&self.tables, regions, out_name, self.rt.canConnect());
    }

    pub fn deskKeys(self: *const Self, out_name: []const u8) ![][]const u8 {
        return query.deskKeys(&self.tables, out_name);
    }

    pub fn appsByDesk(self: *const Self, out_name: []const u8) !desk.AppMap {
        return query.appsByDesk(&self.tables, out_name);
    }

    pub fn windowsOnDesk(self: *const Self, out_name: []const u8) ![]desk.Win {
        return query.windowsOnDesk(&self.tables, out_name);
    }

    // -- lifecycle ----------------------------------------------------------

    pub fn teardown(self: *Self) void {
        self.closeFd(false);
        const view_was_open = self.tables.known_overview and self.tables.overview_open;
        self.tables.clear();
        self.buf.clearRetainingCapacity();
        self.backoff_ms = retry_init_ms;
        // Only an open overview is a change worth announcing: a shell that
        // never saw one should not be told it just closed.
        if (view_was_open) self.emitOverviewChange();
    }

    fn tryConnect(self: *Self) void {
        const path = self.rt.queryEndpoint();
        if (self.fd >= 0 or path.len == 0) return;
        const now = sock.nowMs();
        if (self.retry_at != 0 and now < self.retry_at) return;

        const fd = sock.createStream(false) catch {
            self.scheduleRetry();
            return;
        };
        if (sock.connectPath(fd, path) != null) {
            sock.closeFd(fd);
            self.scheduleRetry();
            return;
        }
        // The subscription is written before the socket turns non-blocking,
        // so a slow niri cannot make us spin on an unflushed request.
        sock.sendAll(fd, event_req) catch {
            sock.closeFd(fd);
            self.scheduleRetry();
            return;
        };
        sock.setNonblock(fd);
        self.fd = fd;
        self.retry_at = 0;
        self.backoff_ms = retry_init_ms;
        self.buf.clearRetainingCapacity();
    }

    fn closeFd(self: *Self, do_reconnect: bool) void {
        if (self.fd >= 0) {
            sock.closeFd(self.fd);
            self.fd = -1;
        }
        if (do_reconnect) self.scheduleRetry() else self.retry_at = 0;
    }

    fn scheduleRetry(self: *Self) void {
        self.retry_at = sock.nowMs() + self.backoff_ms;
        self.backoff_ms = @min(self.backoff_ms * 2, retry_max_ms);
    }

    // -- reading ------------------------------------------------------------

    fn readFd(self: *Self) void {
        var chunk: [4096]u8 = undefined;
        var peer_gone = false;
        while (true) {
            const n: usize = linux.read(self.fd, &chunk, chunk.len);
            const s: isize = @bitCast(n);
            if (s < 0) {
                const e = linux.errno(n);
                if (e == .INTR) continue;
                if (e != .AGAIN) peer_gone = true;
                break;
            }
            if (s == 0) {
                peer_gone = true;
                break;
            }
            self.buf.appendSlice(self.alloc, chunk[0..@intCast(s)]) catch {
                self.closeFd(true);
                self.buf.clearRetainingCapacity();
                return;
            };
            if (self.buf.items.len > buf_max) {
                logz.log("niri: event stream overran its buffer", .{});
                self.closeFd(true);
                self.buf.clearRetainingCapacity();
                return;
            }
        }
        // Drain first, then drop the connection.
        // on EOF and on a read error, stranding every byte this very call had
        // just delivered — a niri that closes after its final batch would lose
        // it, which is precisely when a state snapshot matters most.
        self.parseLines() catch {
            logz.log("niri: event could not be applied", .{});
            self.closeFd(true);
            self.buf.clearRetainingCapacity();
            return;
        };
        if (peer_gone and self.fd >= 0) self.closeFd(true);
    }

    fn parseLines(self: *Self) !void {
        var start: usize = 0;
        var i: usize = 0;
        while (i < self.buf.items.len) : (i += 1) {
            if (self.buf.items[i] != '\n') continue;
            var line = self.buf.items[start..i];
            if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len != 0) {
                if (!(try self.dispatchLine(line))) {
                    self.buf.clearRetainingCapacity();
                    return;
                }
            }
            start = i + 1;
        }
        // Whatever is left is a partial line waiting for its newline.
        if (start != 0) {
            const keep = self.buf.items.len - start;
            std.mem.copyForwards(u8, self.buf.items[0..keep], self.buf.items[start..]);
            self.buf.shrinkRetainingCapacity(keep);
        }
    }

    /// Returns false when the stream rejected itself with an `Err`: the buffer
    /// goes, and `readFd` decides whether the connection survives.
    fn dispatchLine(self: *Self, line: []const u8) !bool {
        const out = try events.routeLine(&self.tables, line);
        if (!out.ok) {
            self.closeFd(true);
            return false;
        }
        if (out.state_changed) self.emitChange();
        if (out.view_changed) self.emitOverviewChange();
        return true;
    }

    fn emitChange(self: *const Self) void {
        if (self.notify) |n| n.run();
    }

    fn emitOverviewChange(self: *const Self) void {
        if (self.view_notify) |n| n.run();
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

test "niri-ws: with no niri to talk to, the interface stays at its defaults" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run_ctx.Runtime.init(t.allocator, &env);
    defer rt.deinit();

    var note = Notifier{};
    var view = Notifier{};
    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();
    m.onStateChange(note.notify());
    m.onOverviewChange(view.notify());

    try t.expectEqual(@as(i32, -1), m.eventFd());
    try t.expectEqual(@as(i16, POLL.IN | POLL.HUP | POLL.ERR), m.eventFlags());
    // Nothing to reconnect to, so the poller is told to wait forever.
    try t.expectEqual(@as(i32, -1), m.eventTimeout());
    try t.expect(!m.supportsOverview());
    try t.expect(!m.hasOverview());
    try t.expect(!m.overviewActive());

    // A poll is a no-op rather than a crash, and a region list is left alone
    // because there is no workspace data to fill it with.
    m.onEvent(POLL.IN);
    var regions = [_]desk.Region{.{ .id = "1", .index = 7 }};
    try m.sync(&regions, "");
    try t.expectEqual(@as(u32, 7), regions[0].index);
    try t.expect(!regions[0].occupied);
    try t.expectEqual(@as(usize, 0), note.fired);
    try t.expectEqual(@as(usize, 0), view.fired);
}

test "niri-ws: an unreachable endpoint backs off from two to four seconds" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("NIRI_SOCKET", "/tmp/opencode/eh-niri-ws-absent.sock");
    var rt = run_ctx.Runtime.init(t.allocator, &env);
    defer rt.deinit();

    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();

    // `init` tried once and failed, so the first retry is two seconds out.
    try t.expectEqual(@as(i32, -1), m.eventFd());
    try t.expect(m.supportsOverview());
    try t.expectEqual(@as(i32, 2000), m.eventTimeout());

    // Within the window the manager does not retry at all.
    m.onEvent(POLL.IN);
    try t.expectEqual(@as(i32, -1), m.eventFd());
    try t.expectEqual(@as(i32, 2000), m.eventTimeout());

    // Let the window lapse: the second failure pushes the delay to four.
    m.retry_at = 0;
    m.onEvent(POLL.IN);
    try t.expect(m.eventTimeout() > 3000);
    try t.expect(m.eventTimeout() <= 4000);

    // A connected stream has nothing left to wait for. The fd is one this
    // test owns, and `deinit` is what closes it.
    m.fd = try sock.createStream(false);
    try t.expectEqual(@as(i32, -1), m.eventTimeout());
}

const stream_payload =
    \\{"Ok":null}
    \\{"WorkspacesChanged":{"workspaces":[{"id":1,"idx":1,"name":null,"output":"DP-1"},{"id":5,"idx":2,"name":"dev","output":"DP-1"}]}}
    \\{"WindowsChanged":{"windows":[{"id":10,"workspace_id":1,"app_id":"foot","title":"one"},{"id":11,"workspace_id":5,"app_id":"firefox","title":"two"}]}}
    \\{"WindowClosed":{"id":11}}
    \\{"OverviewOpenedOrClosed":{"is_open":true}}
    \\{"OverviewOpenedOrClosed":{"is_open":true}}
    \\{"ConfigLoaded":{"config":null}}
    \\{"Err":"boom"}
    \\{"WorkspacesChanged":{"workspaces":[]}}
;

test "niri-ws: the event stream fills the tables, notifies, and stops at an Err" {
    const io = t.io;
    const cwd = std.Io.Dir.cwd();

    var name_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-niri-ws-{d}", .{linux.getpid()});
    defer cwd.deleteTree(io, root) catch {};
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "stream.sock" });
    defer t.allocator.free(path);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, path);
    try sock.listenOn(lfd, 4);

    // One connection: answer the subscription, push the batch, then hold the
    // socket open until the client drops it (which the `Err` below makes it
    // do) so no read can race the shutdown and mistake a short write for EOF.
    const Serve = struct {
        lfd: i32,
        payload: []const u8,
        alloc: std.mem.Allocator,
        seen: *?[]u8,

        fn run(self: @This()) void {
            const c = self.accept() orelse return;
            defer sock.closeFd(c);
            var slot: [256]u8 = undefined;
            if (readLine(c, &slot)) |req| {
                const copy = self.alloc.dupe(u8, req) catch return;
                if (self.seen.*) |old| self.alloc.free(old);
                self.seen.* = copy;
            }
            sock.sendAll(c, self.payload) catch return;
            waitUntilClosed(c);
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

        // The accepted fd is non-blocking, so a request that has not landed
        // yet reads as EAGAIN rather than as a short line. The bytes go into
        // the caller's buffer so the returned slice outlives this frame.
        fn readLine(c: i32, got: *[256]u8) ?[]u8 {
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

        fn waitUntilClosed(c: i32) void {
            const deadline = sock.nowMs() + 5000;
            while (sock.nowMs() < deadline) {
                var pfd = [1]std.posix.pollfd{.{ .fd = c, .events = POLL.IN, .revents = 0 }};
                const rc = std.posix.poll(&pfd, 25) catch break;
                if (rc == 0) continue;
                if ((pfd[0].revents & (POLL.HUP | POLL.ERR | POLL.NVAL)) != 0) return;
            }
        }
    };

    var seen: ?[]u8 = null;
    defer if (seen) |s| t.allocator.free(s);
    var thread = try std.Thread.spawn(
        .{},
        Serve.run,
        .{Serve{ .lfd = lfd, .payload = stream_payload, .alloc = t.allocator, .seen = &seen }},
    );
    defer thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("NIRI_SOCKET", path);
    var rt = run_ctx.Runtime.init(t.allocator, &env);
    defer rt.deinit();

    var note = Notifier{};
    var view = Notifier{};
    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();
    m.onStateChange(note.notify());
    m.onOverviewChange(view.notify());

    // Pump until the `Err` line drops the connection.
    const deadline = sock.nowMs() + 4000;
    while (m.eventFd() >= 0 and sock.nowMs() < deadline) {
        m.onEvent(POLL.IN);
        _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
    }

    // The subscription went out in the form niri expects.
    try t.expect(seen != null);
    try t.expectEqualStrings("\"EventStream\"", seen.?);

    try t.expectEqual(@as(usize, 2), m.tables.workspaces.count());
    try t.expectEqualStrings("dev", m.tables.workspaces.get(5).?.name);
    // Window 11 was closed after the batch landed.
    try t.expectEqual(@as(usize, 1), m.tables.windows.count());
    try t.expect(m.tables.occupied(1));
    try t.expect(!m.tables.occupied(5));
    try t.expect(m.hasOverview());
    try t.expect(m.overviewActive());

    // Workspaces, windows and the close each notified once; the duplicate
    // overview line and the unknown `ConfigLoaded` did not.
    try t.expectEqual(@as(usize, 3), note.fired);
    try t.expectEqual(@as(usize, 1), view.fired);

    // The `Err` closed the stream, and everything queued behind it — including
    // a workspace list that would have wiped the tables — was discarded.
    try t.expectEqual(@as(i32, -1), m.eventFd());
    try t.expectEqual(@as(usize, 2), m.tables.workspaces.count());
    try t.expect(m.eventTimeout() > 0);
    try t.expect(m.eventTimeout() <= 2000);

    // The tables stay readable for the interface after the stream is gone.
    const keys = try m.deskKeys("DP-1");
    defer query.freeKeys(t.allocator, keys);
    try t.expectEqual(@as(usize, 2), keys.len);
}

test "niri-ws: a stream that never sends a newline is cut off at a megabyte" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("NIRI_SOCKET", "/tmp/opencode/eh-niri-ws-flood.sock");
    var rt = run_ctx.Runtime.init(t.allocator, &env);
    defer rt.deinit();

    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();

    // `sendAll` returns an error union, which a thread body is not allowed to
    // hand back; the flood is expected to fail once the reader bails out.
    const push = struct {
        fn run(fd: i32, data: []const u8) void {
            sock.sendAll(fd, data) catch {};
        }
    }.run;

    var pair: [2]i32 = .{ -1, -1 };
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair);
    try t.expect(linux.errno(rc) == .SUCCESS);
    defer sock.closeFd(pair[0]);
    sock.setNonblock(pair[1]);
    m.fd = pair[1];
    try t.expect(m.eventFd() == pair[1]);
    try t.expectEqual(@as(i32, -1), m.eventTimeout());

    const flood = try t.allocator.alloc(u8, buf_max + 8192);
    defer t.allocator.free(flood);
    @memset(flood, 'x');

    // Written from another thread because the reader only drains when asked,
    // and a blocking socket would otherwise sit on a full receive window.
    var writer = try std.Thread.spawn(.{}, push, .{ pair[0], flood });
    defer writer.join();

    const deadline = sock.nowMs() + 4000;
    while (m.eventFd() >= 0 and sock.nowMs() < deadline) {
        m.onEvent(POLL.IN);
        _ = std.posix.poll(&[_]std.posix.pollfd{}, 2) catch 0;
    }

    // Over the cap means the peer is broken: the connection is dropped, the
    // half-line with it, and a retry scheduled.
    try t.expectEqual(@as(i32, -1), m.eventFd());
    try t.expectEqual(@as(usize, 0), m.buf.items.len);
    try t.expect(m.eventTimeout() > 0);
}

test "niri-ws: teardown clears the tables and only reports a closed overview" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run_ctx.Runtime.init(t.allocator, &env);
    defer rt.deinit();

    var note = Notifier{};
    var view = Notifier{};
    var m = Manager.init(t.allocator, &rt);
    defer m.deinit();
    m.onStateChange(note.notify());
    m.onOverviewChange(view.notify());

    _ = events.routeLine(&m.tables,
        \\{"WorkspacesChanged":{"workspaces":[{"id":1,"idx":1,"name":null,"output":"DP-1"}]}}
    ) catch {};
    try t.expectEqual(@as(usize, 1), m.tables.workspaces.count());
    try t.expectEqual(@as(usize, 0), note.fired);

    // An overview that was never seen is not a closing, so nothing is emitted.
    m.teardown();
    try t.expectEqual(@as(usize, 0), m.tables.workspaces.count());
    try t.expect(!m.hasOverview());
    try t.expectEqual(@as(usize, 0), view.fired);

    _ = events.routeLine(&m.tables, "{\"OverviewOpenedOrClosed\":{\"is_open\":true}}") catch {};
    try t.expect(m.overviewActive());
    m.teardown();
    try t.expect(!m.hasOverview());
    try t.expect(!m.overviewActive());
    try t.expectEqual(@as(usize, 1), view.fired);
}
