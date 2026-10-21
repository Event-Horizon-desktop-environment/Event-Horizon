//! niri compositor IPC, transport half: endpoint discovery from `$NIRI_SOCKET`
//! and the one-shot request exchange.
//!
//! Unlike Hyprland there is
//! no long-lived request socket here — every call opens the socket, writes one
//! line, reads one line back and closes it. The
//! persistent event stream is a different connection; `niri_ws.zig` owns that
//! one.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("../sock.zig");
const logz = @import("../logz.zig");

/// A reply is supposed to be one line, read until the first newline
/// with no bound at all, so a peer that never sends one would pin the shell's
/// heap indefinitely; stopping at a megabyte keeps the wire format identical
/// for every real answer and turns the pathological case into a failed read.
const max_reply = 1 << 20;

/// What the exchange did, kept separate from the payload because callers care
/// which of the failures happened: `NoContent` is a success for anyone willing
/// to accept silence, and `BadJson` never is.
pub const Tag = enum {
    /// No endpoint, empty request, socket creation failure or connect refusal.
    none,
    write_fail,
    read_fail,
    /// The peer closed without saying anything.
    no_content,
    /// Bytes arrived but were not JSON.
    bad_json,
    ok,
};

pub const Reply = struct {
    tag: Tag = .none,
    data: ?std.json.Parsed(std.json.Value) = null,

    /// Takes the value by value; the arena `Parsed` owns covers every slice
    /// the document handed out, so nothing is freed individually.
    pub fn deinit(self: Reply) void {
        if (self.data) |d| d.deinit();
    }
};

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    /// Owned copy of `$NIRI_SOCKET`. niri gives one ready-made path with nothing to join onto
    /// it, but the copy still matters: the environment map frees the old value
    /// whenever a key is rewritten, and a borrowed slice would dangle the
    /// moment that happened.
    endpoint: ?[]u8 = null,
    resolved: bool = false,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) Self {
        return .{ .alloc = alloc, .env = env };
    }

    pub fn deinit(self: *Self) void {
        self.freeEndpoint();
    }

    pub fn canConnect(self: *Self) bool {
        self.resolveIfPending();
        return self.queryEndpoint().len > 0;
    }

    pub fn queryEndpoint(self: *Self) []const u8 {
        self.resolveIfPending();
        return self.endpoint orelse "";
    }

    /// Re-reads `$NIRI_SOCKET`, for after a compositor restart. The endpoint
    /// is dropped first so a variable that went away does not leave a stale
    /// path behind.
    pub fn rescan(self: *Self) void {
        self.freeEndpoint();
        self.resolved = false;
        self.locateEndpoint();
    }

    pub fn resolveIfPending(self: *Self) void {
        if (!self.resolved) self.locateEndpoint();
    }

    fn freeEndpoint(self: *Self) void {
        if (self.endpoint) |e| self.alloc.free(e);
        self.endpoint = null;
    }

    fn locateEndpoint(self: *Self) void {
        self.resolved = true;
        const p = self.env.get("NIRI_SOCKET") orelse return;
        if (p.len == 0) return;
        const copy = self.alloc.dupe(u8, p) catch return;
        self.freeEndpoint();
        self.endpoint = copy;
    }

    pub fn sendQuery(self: *Self, req: []const u8) ?std.json.Parsed(std.json.Value) {
        return self.transmit(req).data;
    }

    /// True when the reply is an `Ok`. `allow_no_response` covers the handful
    /// of requests niri accepts but never answers.
    pub fn sendCheck(self: *Self, req: []const u8, allow_no_response: bool) bool {
        const reply = self.transmit(req);
        defer reply.deinit();
        return switch (reply.tag) {
            .no_content => allow_no_response,
            else => isOk(reply.data),
        };
    }

    /// Wraps a serialised action in the `{"Action": …}` envelope the niri
    /// socket expects and dispatches it. `action` is already JSON text —
    /// building it here would only hide the wire format from the caller.
    pub fn dispatchAction(self: *Self, action: []const u8, allow_no_response: bool) bool {
        const req = std.fmt.allocPrint(self.alloc, "{{\"Action\":{s}}}\n", .{action}) catch return false;
        defer self.alloc.free(req);
        return self.sendCheck(req, allow_no_response);
    }

    /// One complete request/response exchange over the endpoint.
    pub fn transmit(self: *Self, req: []const u8) Reply {
        self.resolveIfPending();
        const path = self.endpoint orelse return .{};
        if (path.len == 0 or req.len == 0) return .{};

        const fd = sock.createStream(false) catch return .{};
        defer sock.closeFd(fd);
        if (sock.connectPath(fd, path) != null) return .{};

        sock.sendAll(fd, req) catch {
            logz.log("niri: tx write failed", .{});
            return .{ .tag = .write_fail };
        };

        const text = readReply(self.alloc, fd) orelse {
            logz.log("niri: tx read failed", .{});
            return .{ .tag = .read_fail };
        };
        defer self.alloc.free(text);

        if (text.len == 0) return .{ .tag = .no_content };

        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, text, .{}) catch {
            logz.log("niri: reply JSON parse failed: {s}", .{text[0..@min(text.len, 160)]});
            return .{ .tag = .bad_json };
        };
        return .{ .tag = .ok, .data = parsed };
    }

    pub fn isOk(data: ?std.json.Parsed(std.json.Value)) bool {
        const doc = data orelse return false;
        if (doc.value != .object) return false;
        return doc.value.object.contains("Ok");
    }
};

/// Reads up to the first newline, then drops the newline and everything after
/// it. EOF with a partial line still yields those bytes — niri may close right
/// behind its answer — while EOF with nothing yields an empty slice, which the
/// caller reports as `NoContent`.
fn readReply(alloc: std.mem.Allocator, fd: i32) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return null;
        if (rc == 0) break;
        out.appendSlice(alloc, buf[0..rc]) catch return null;
        if (std.mem.indexOfScalar(u8, out.items, '\n') != null) break;
        if (out.items.len > max_reply) return null;
    }
    if (std.mem.indexOfScalar(u8, out.items, '\n')) |nl| out.shrinkRetainingCapacity(nl);
    return out.toOwnedSlice(alloc) catch null;
}

// Tests

test "niri-run-ctx: an unset NIRI_SOCKET makes every request a no-op" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = Runtime.init(t.allocator, &env);
    defer rt.deinit();

    try t.expect(!rt.canConnect());
    try t.expectEqualStrings("", rt.queryEndpoint());
    // Resolved once: a later `put` is not seen until `rescan`.
    try t.expect(rt.resolved);
    try t.expect(rt.sendQuery("\"Workspaces\"\n") == null);
    // `NoContent` is only ever produced by a real exchange, so an absent
    // endpoint fails even when the caller said it would tolerate silence.
    try t.expect(!rt.sendCheck("\"Workspaces\"\n", true));
    try t.expect(!rt.dispatchAction("{\"PowerOffMonitors\":{}}", true));
    try t.expectEqualStrings("", rt.queryEndpoint());
}

test "niri-run-ctx: rescan re-reads the endpoint" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("NIRI_SOCKET", "/tmp/opencode/eh-niri-absent.sock");
    var rt = Runtime.init(t.allocator, &env);
    defer rt.deinit();

    try t.expect(rt.canConnect());

    // A variable that empties out clears the cached path, but only once
    // `rescan` asks for a fresh read — same lifetime as the cached copy.
    try env.put("NIRI_SOCKET", "");
    try t.expectEqualStrings("/tmp/opencode/eh-niri-absent.sock", rt.queryEndpoint());
    rt.rescan();
    try t.expect(!rt.canConnect());

    try env.put("NIRI_SOCKET", "/tmp/opencode/eh-niri-absent.sock");
    rt.rescan();
    try t.expectEqualStrings("/tmp/opencode/eh-niri-absent.sock", rt.queryEndpoint());
}

test "niri-run-ctx: empty request and absent listener both come back as none" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("NIRI_SOCKET", "/tmp/opencode/eh-niri-nosuch.sock");
    var rt = Runtime.init(t.allocator, &env);
    defer rt.deinit();

    try t.expect(rt.canConnect());
    const empty = rt.transmit("");
    try t.expectEqual(Tag.none, empty.tag);
    try t.expect(empty.data == null);

    // Nothing is bound at that path, so the connect itself fails.
    const refused = rt.transmit("\"Workspaces\"\n");
    try t.expectEqual(Tag.none, refused.tag);
    try t.expect(refused.data == null);
}

test "niri-run-ctx: request round trip over a real socket" {
    const t = std.testing;
    const io = t.io;
    const cwd = std.Io.Dir.cwd();

    var name_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-niri-ipc-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(io, root) catch {};
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "niri.sock" });
    defer t.allocator.free(path);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, path);
    try sock.listenOn(lfd, 8);

    // One connection per entry in `replies`; an empty entry means "close
    // without saying anything", which is what `NoContent` looks like. Every
    // request the client sent is recorded so the wire format can be asserted
    // from the other side of the socket.
    const Serve = struct {
        lfd: i32,
        replies: []const []const u8,
        seen: *std.ArrayList([]const u8),
        alloc: std.mem.Allocator,

        fn run(self: @This()) void {
            for (self.replies) |reply| {
                const c = self.accept() orelse return;
                defer sock.closeFd(c);
                const req = self.readLine(c) orelse continue;
                defer self.alloc.free(req);
                self.record(req);
                if (reply.len > 0) sock.sendAll(c, reply) catch {};
            }
        }

        fn record(self: @This(), req: []const u8) void {
            const copy = self.alloc.dupe(u8, req) catch return;
            self.seen.append(self.alloc, copy) catch self.alloc.free(copy);
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

        // `accept4` hands back a non-blocking fd, so a request that has not
        // landed yet reads as EAGAIN rather than as a short line — waiting it
        // out is the difference between an answer and a dropped connection.
        fn readLine(self: @This(), c: i32) ?[]u8 {
            var got: std.ArrayList(u8) = .empty;
            errdefer got.deinit(self.alloc);
            var buf: [512]u8 = undefined;
            const deadline = sock.nowMs() + 5000;
            while (got.items.len < 4096 and sock.nowMs() < deadline) {
                const n = linux.recvfrom(c, &buf, buf.len, 0, null, null);
                const e = linux.errno(n);
                if (e == .INTR) continue;
                if (e == .AGAIN) {
                    _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
                    continue;
                }
                if (e != .SUCCESS) return null;
                if (n == 0) break;
                got.appendSlice(self.alloc, buf[0..n]) catch return null;
                if (std.mem.indexOfScalar(u8, got.items, '\n')) |nl| {
                    got.shrinkRetainingCapacity(nl);
                    break;
                }
            }
            return got.toOwnedSlice(self.alloc) catch null;
        }
    };

    const replies = [_][]const u8{
        "{\"Ok\":{\"FocusedOutput\":\"winit\"}}\n",
        "{\"Err\":\"no such thing\"}\n",
        "{\"Ok\":1}",
        "this is not json\n",
        "", // connection 5: close with nothing said
        "", // connection 6: the same, for the `allow_no_response` caller
        "{\"Ok\":null}\n",
    };
    var seen: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen.items) |s| t.allocator.free(s);
        seen.deinit(t.allocator);
    }

    var thread = try std.Thread.spawn(
        .{},
        Serve.run,
        .{Serve{
            .lfd = lfd,
            .replies = &replies,
            .seen = &seen,
            .alloc = t.allocator,
        }},
    );
    // Joining on the way out keeps a failing assertion from leaving the server
    // thread reading a socket that `lfd`'s defer is about to close — but only
    // for the ones raised before the join itself.
    var joined = false;
    errdefer if (!joined) thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("NIRI_SOCKET", path);
    var rt = Runtime.init(t.allocator, &env);
    defer rt.deinit();
    try t.expect(rt.canConnect());

    // A query: parsed, and the request line is exactly what niri expects.
    {
        var doc = (rt.sendQuery("\"FocusedOutput\"\n") orelse return error.NoReply);
        defer doc.deinit();
        try t.expect(doc.value == .object);
        const ok = doc.value.object.get("Ok").?;
        try t.expectEqualStrings("winit", ok.object.get("FocusedOutput").?.string);
    }

    // A rejected action: an `Err` envelope is a failure, never an error.
    try t.expect(!rt.sendCheck("\"Nope\"\n", false));

    // Trailing content after the newline is dropped rather than parsed.
    {
        var handled = (rt.sendQuery("\"Handled\"") orelse return error.NoReply);
        defer handled.deinit();
        try t.expect(Runtime.isOk(handled));
    }

    // Bytes that are not JSON are reported as such instead of throwing.
    const bad = rt.transmit("\"FocusedOutput\"\n");
    try t.expectEqual(Tag.bad_json, bad.tag);
    try t.expect(bad.data == null);
    bad.deinit();

    // Silence from the peer: only a caller that allowed it gets a success.
    try t.expect(!rt.sendCheck("\"FocusedOutput\"\n", false));
    try t.expect(rt.sendCheck("\"FocusedOutput\"\n", true));

    // Actions go out wrapped in the `Action` envelope, newline and all.
    try t.expect(rt.dispatchAction("{\"SwitchLayout\":{\"layout\":\"Next\"}}", false));

    thread.join();
    joined = true;

    try t.expectEqual(@as(usize, 7), seen.items.len);
    try t.expectEqualStrings("\"FocusedOutput\"", seen.items[0]);
    try t.expectEqualStrings("\"Nope\"", seen.items[1]);
    try t.expectEqualStrings("\"Handled\"", seen.items[2]);
    try t.expectEqualStrings("\"FocusedOutput\"", seen.items[3]);
    try t.expectEqualStrings("\"FocusedOutput\"", seen.items[4]);
    try t.expectEqualStrings("\"FocusedOutput\"", seen.items[5]);
    try t.expectEqualStrings("{\"Action\":{\"SwitchLayout\":{\"layout\":\"Next\"}}}", seen.items[6]);
}
