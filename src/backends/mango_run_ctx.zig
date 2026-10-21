//! mango compositor IPC, transport half: endpoint discovery from
//! `$MANGO_INSTANCE_SIGNATURE` and the one-shot request exchange.
//!
//! Mango runtime: endpoint discovery plus one-shot requests. Every call opens the
//! socket, writes one line, reads one line back and closes it — mango has no
//! long-lived request socket. The `watch all-monitors`
//! subscription is a *different* connection and belongs to `mango_ws.zig`.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("../sock.zig");
const logz = @import("../logz.zig");
const desk = @import("desk.zig");

/// A reply is supposed to be one line, read until the first newline
/// with no bound at all, so a peer that never sent one would pin the shell's
/// heap indefinitely; stopping at a megabyte keeps the wire format identical
/// for every real answer and turns the pathological case into a failed read.
/// Same deviation, same figure, as `niri_run_ctx.zig`.
const max_reply = 1 << 20;

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// Owned copy of `$MANGO_INSTANCE_SIGNATURE`. The copy matters even though the variable
    /// looks stable: the environment map frees the old value whenever a key is
    /// rewritten, and a borrowed slice would dangle the moment that happened.
    endpoint: ?[]u8 = null,
    resolved: bool = false,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Self {
        return .{ .alloc = alloc, .io = io, .env = env };
    }

    pub fn deinit(self: *Self) void {
        self.freeEndpoint();
    }

    /// A signature only counts when it names a socket that is really there.
    /// Stale variables outlive a compositor that has
    /// already gone, and connecting to whatever the path now holds would be a
    /// failure for a reason nobody logs.
    pub fn available(self: *Self) bool {
        return self.socketPath().len > 0;
    }

    pub fn socketPath(self: *Self) []const u8 {
        self.resolveIfPending();
        return self.endpoint orelse "";
    }

    /// Re-reads the environment, for after a compositor restart. The endpoint
    /// is dropped first so a variable that went away does not leave a stale
    /// path behind.
    pub fn refresh(self: *Self) void {
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

    /// Marks the search done even when it found nothing: an absent variable is
    /// an answer, and re-running `stat` on every call would be work for no
    /// change. A variable that is present but no longer a socket leaves the
    /// previous endpoint alone — `refresh` is what clears it.
    fn locateEndpoint(self: *Self) void {
        self.resolved = true;
        const sig = self.env.get("MANGO_INSTANCE_SIGNATURE") orelse return;
        if (sig.len == 0) return;
        if (!isValidSocket(self.io, sig)) return;
        const copy = self.alloc.dupe(u8, sig) catch return;
        self.freeEndpoint();
        self.endpoint = copy;
    }

    /// One complete request/response exchange: `"cmd" ++ "\n"` out, one line
    /// back, socket closed. Every failure — no endpoint, refused connect,
    /// short read, non-JSON — is the same `null` for all of them,
    /// because no caller distinguished them.
    pub fn ipcQuery(self: *Self, cmd: []const u8) ?std.json.Parsed(std.json.Value) {
        self.resolveIfPending();
        const path = self.endpoint orelse return null;
        if (path.len == 0 or cmd.len == 0) return null;
        // `connect` would otherwise be handed a truncated path and could land
        // on an unrelated socket; overlong paths are refused.
        if (path.len >= sock.max_path) {
            logz.log("mango: socket path too long ({d})", .{path.len});
            return null;
        }

        const fd = sock.createStream(false) catch {
            logz.log("mango: request socket() failed", .{});
            return null;
        };
        defer sock.closeFd(fd);

        if (sock.connectPath(fd, path)) |e| {
            logz.log("mango: connect to '{s}' failed: {}", .{ path, e });
            return null;
        }

        // The newline is a second write rather than a concatenated buffer: on
        // a stream socket the peer sees the same bytes either way, and this
        // keeps every command allocation-free at the call site.
        sock.sendAll(fd, cmd) catch {
            logz.log("mango: request write failed: {s}", .{cmd});
            return null;
        };
        sock.sendAll(fd, "\n") catch {
            logz.log("mango: request write failed: {s}", .{cmd});
            return null;
        };

        const text = readReply(self.alloc, fd) orelse {
            logz.log("mango: request read failed: {s}", .{cmd});
            return null;
        };
        defer self.alloc.free(text);
        if (text.len == 0) return null;

        return std.json.parseFromSlice(std.json.Value, self.alloc, text, .{}) catch {
            logz.log("mango: reply JSON parse failed: {s}", .{text[0..@min(text.len, 160)]});
            return null;
        };
    }

    /// `runCommand <cmd>`, which mango answers with `{"success": true}`. Anything
    /// else — no answer, an object without that field, a `false` — is a
    /// failure, with the reason discarded every time.
    pub fn runCommand(self: *Self, cmd: []const u8) bool {
        const text = std.fmt.allocPrint(self.alloc, "dispatch {s}", .{cmd}) catch return false;
        defer self.alloc.free(text);
        const resp = self.ipcQuery(text) orelse return false;
        defer resp.deinit();
        if (resp.value != .object) return false;
        return desk.jsonBoolOr(resp.value, "success", false);
    }
};

/// `S_ISSOCK` on the signature. `statFile` follows the link, which is what
/// `::stat` did, and `kind` is where the file-type bits landed.
fn isValidSocket(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .unix_domain_socket;
}

/// Reads until the first newline, the peer's hang-up, or a read error, then
/// drops the newline and everything after it. EOF with a partial line still
/// yields those bytes — mango may close right behind its answer — while EOF
/// with nothing yields an empty slice, which the caller reports as no answer.
fn readReply(alloc: std.mem.Allocator, fd: i32) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    // `toOwnedSlice` empties the list on success, so this is a no-op then and
    // the only release on every other path.
    defer out.deinit(alloc);
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

const t = std.testing;

/// Accepts one connection per canned reply, records the request line that
/// arrived on it, answers, then hangs up. The accepted fd is non-blocking
/// (`acceptConn` passes `SOCK_NONBLOCK`), so `readLine` polls out `EAGAIN`
/// rather than mistaking it for a short read.
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
            sock.sendAll(c, reply) catch return;
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

test "mango-run-ctx: no signature means no endpoint and every query is a no-op" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    try t.expect(!rt.available());
    try t.expectEqualStrings("", rt.socketPath());
    try t.expect(rt.ipcQuery("get all-clients") == null);
    try t.expect(!rt.runCommand("view,1"));

    // An empty signature is the same as an absent one.
    try env.put("MANGO_INSTANCE_SIGNATURE", "");
    rt.refresh();
    try t.expect(!rt.available());
    try t.expect(rt.endpoint == null);
}

test "mango-run-ctx: a signature naming something other than a socket is ignored" {
    const cwd = std.Io.Dir.cwd();
    var name_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-mango-rt-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(t.io, root) catch {};
    cwd.deleteTree(t.io, root) catch {};
    try cwd.createDirPath(t.io, root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "not-a-socket" });
    defer t.allocator.free(path);
    const file = try cwd.createFile(t.io, path, .{});
    file.close(t.io);

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MANGO_INSTANCE_SIGNATURE", path);
    var rt = Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    try t.expect(!rt.available());
    try t.expect(rt.ipcQuery("get all-clients") == null);
}

test "mango-run-ctx: a live socket answers a query, and refresh re-reads the signature" {
    const cwd = std.Io.Dir.cwd();
    var name_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-mango-rt2-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(t.io, root) catch {};
    cwd.deleteTree(t.io, root) catch {};
    try cwd.createDirPath(t.io, root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "mango.sock" });
    defer t.allocator.free(path);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, path);
    try sock.listenOn(lfd, 4);

    var seen: std.ArrayList([]u8) = .empty;
    defer freeSeen(&seen, t.allocator);
    var thread = try std.Thread.spawn(
        .{},
        Serve.run,
        .{Serve{
            .lfd = lfd,
            .replies = &[_][]const u8{
                "{\"clients\":[{\"id\":7}]}\n",
                "{\"success\":true}\n",
                // No newline at all: the peer hangs up behind it and those
                // bytes are still a complete answer.
                "{\"success\":false}",
                "not json at all\n",
            },
            .alloc = t.allocator,
            .seen = &seen,
        }},
    );
    defer thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MANGO_INSTANCE_SIGNATURE", path);
    var rt = Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    try t.expect(rt.available());
    try t.expectEqualStrings(path, rt.socketPath());

    const doc = rt.ipcQuery("get all-clients").?;
    defer doc.deinit();
    try t.expect(doc.value == .object);
    try t.expectEqual(@as(usize, 1), doc.value.object.get("clients").?.array.items.len);

    try t.expect(rt.runCommand("view,1"));
    try t.expect(!rt.runCommand("view,2")); // answered, just not with success

    // Unparsable answers and empty commands are both "no".
    try t.expect(rt.ipcQuery("get all-monitors") == null);
    try t.expect(rt.ipcQuery("") == null);

    // The commands that went out are exactly what mango expects to read.
    try t.expectEqual(@as(usize, 4), seen.items.len);
    try t.expectEqualStrings("get all-clients", seen.items[0]);
    try t.expectEqualStrings("dispatch view,1", seen.items[1]);
    try t.expectEqualStrings("dispatch view,2", seen.items[2]);
    try t.expectEqualStrings("get all-monitors", seen.items[3]);

    // Pointing the variable at nothing at all drops the endpoint.
    try env.put("MANGO_INSTANCE_SIGNATURE", "/tmp/opencode/eh-mango-rt2-absent.sock");
    rt.refresh();
    try t.expect(!rt.available());
}
