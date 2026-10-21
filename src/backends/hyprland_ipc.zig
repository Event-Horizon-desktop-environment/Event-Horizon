//! Hyprland compositor IPC, transport half: endpoint discovery and the
//! one-shot request socket (`.socket.sock`).
//!
//! The persistent event socket lives next door in `hyprland_run_ctx.zig`; the
//! split keeps both files under the size budget. The environment is read
//! through `getenv`; here the environment is a `std.process.Environ.Map`
//! handed in by the caller, so every path is reachable from a test.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("../sock.zig");
const logz = @import("../logz.zig");
const desk = @import("desk.zig");

const POLL = std.posix.POLL;

/// Hard cap on a single reply: 8 MiB, past which the peer is presumed stuck.
const max_reply = 8 << 20;
/// Per-poll budget for one request/response round trip, in milliseconds.
const request_timeout_ms: i32 = 3000;

pub const Paths = struct {
    req: []const u8 = "",
    ev: []const u8 = "",

    pub fn empty(self: Paths) bool {
        return self.req.len == 0 and self.ev.len == 0;
    }
};

fn isDir(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

pub fn freePaths(alloc: std.mem.Allocator, paths: *Paths) void {
    alloc.free(paths.req);
    alloc.free(paths.ev);
    paths.* = .{};
}

/// `$XDG_RUNTIME_DIR/hypr/<sig>` when it exists, else `/tmp/hypr/<sig>`, else
/// nothing: both sockets have to sit in a directory that is really there or
/// every later `connect` fails for a reason nobody logs. Returns owned strings
/// or `null` when the instance signature is absent/unknown.
pub fn resolvePaths(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !?Paths {
    const sig = env.get("HYPRLAND_INSTANCE_SIGNATURE") orelse return null;
    if (sig.len == 0) return null;

    var primary: ?[]u8 = null;
    defer if (primary) |p| alloc.free(p);

    var dir: []const u8 = "";
    if (env.get("XDG_RUNTIME_DIR")) |rt| {
        if (rt.len > 0) {
            primary = try std.fs.path.join(alloc, &.{ rt, "hypr", sig });
            dir = primary.?;
        }
    }
    if (dir.len == 0 or !isDir(io, dir)) {
        if (primary) |p| {
            alloc.free(p);
            primary = null;
        }
        primary = try std.fs.path.join(alloc, &.{ "/tmp/hypr", sig });
        dir = primary.?;
    }
    if (!isDir(io, dir)) return null;

    const req = try std.fs.path.join(alloc, &.{ dir, ".socket.sock" });
    errdefer alloc.free(req);
    const ev = try std.fs.path.join(alloc, &.{ dir, ".socket2.sock" });
    return .{ .req = req, .ev = ev };
}

/// Blocking read of a whole reply, terminated by the peer closing its write
/// side. Returns owned bytes, or `null` on timeout / transport error — the
/// caller treats both as "no answer".
fn readReply(alloc: std.mem.Allocator, fd: i32) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        var pfd = std.posix.pollfd{ .fd = fd, .events = POLL.IN, .revents = 0 };
        const ready = std.posix.poll(@as(*[1]std.posix.pollfd, &pfd)[0..], request_timeout_ms) catch return null;
        if (ready <= 0) return null;
        const rc = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return null;
        if (rc == 0) break;
        out.appendSlice(alloc, buf[0..rc]) catch return null;
        if (out.items.len > max_reply) break;
    }
    return out.toOwnedSlice(alloc) catch null;
}

/// One request/response exchange over `path`: connect, send, half-close the
/// write side so the compositor sees the end of the command, read to EOF.
pub fn requestOnce(alloc: std.mem.Allocator, path: []const u8, command: []const u8) ?[]u8 {
    if (path.len == 0 or command.len == 0) return null;
    const fd = sock.createStream(false) catch return null;
    defer sock.closeFd(fd);
    if (sock.connectPath(fd, path) != null) return null;
    sock.sendAll(fd, command) catch return null;
    _ = linux.shutdown(fd, linux.SHUT.WR);
    return readReply(alloc, fd);
}

/// Wraps a raw reply in a parsed JSON value. Parse failures are logged and
/// dropped rather than thrown: a compositor that answers with garbage must not
/// take the shell down.
pub fn parseReply(
    alloc: std.mem.Allocator,
    command: []const u8,
    text: []const u8,
) ?std.json.Parsed(std.json.Value) {
    if (text.len == 0) return null;
    return std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch |err| {
        logz.log("hyprland: failed to parse response for {s}: {}", .{ command, err });
        return null;
    };
}

/// Environment-only request, for the handful of call sites (power actions,
/// config probes) that have no long-lived session object.
pub fn ipcRequest(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    command: []const u8,
) ?[]u8 {
    const paths = (resolvePaths(alloc, io, env) catch return null) orelse return null;
    defer {
        var p = paths;
        freePaths(alloc, &p);
    }
    return requestOnce(alloc, paths.req, command);
}

/// Whether the compositor runs the lua config provider. Under lua the plain
/// `dispatch workspace N` form is rejected, so callers that focus a workspace
/// have to know which syntax they are talking to.
pub fn usesLuaConfig(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
    const text = ipcRequest(alloc, io, env, "j/status") orelse return false;
    defer alloc.free(text);
    var parsed = parseReply(alloc, "j/status", text) orelse return false;
    defer parsed.deinit();
    return parsed.value == .object and
        std.mem.eql(u8, desk.jsonStr(parsed.value, "configProvider"), "lua");
}

// Tests

test "hyprland-ipc: no signature means no sockets" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    try t.expect((try resolvePaths(t.allocator, t.io, &env)) == null);

    try env.put("HYPRLAND_INSTANCE_SIGNATURE", "");
    try t.expect((try resolvePaths(t.allocator, t.io, &env)) == null);

    try env.put("HYPRLAND_INSTANCE_SIGNATURE", "nosuchsignature");
    try t.expect((try resolvePaths(t.allocator, t.io, &env)) == null);
}

test "hyprland-ipc: env-only request honours a missing signature" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try t.expect(ipcRequest(t.allocator, t.io, &env, "j/status") == null);
    try t.expect(!usesLuaConfig(t.allocator, t.io, &env));
}

test "hyprland-ipc: empty command never touches the filesystem" {
    const t = std.testing;
    try t.expect(requestOnce(t.allocator, "", "j/status") == null);
    try t.expect(requestOnce(t.allocator, "/tmp/opencode/absent.sock", "") == null);
    try t.expect(requestOnce(t.allocator, "/tmp/opencode/absent.sock", "j/status") == null);
}

test "hyprland-ipc: unparseable reply is dropped, well-formed one is kept" {
    const t = std.testing;
    try t.expect(parseReply(t.allocator, "j/status", "") == null);
    try t.expect(parseReply(t.allocator, "j/status", "not json") == null);
    var good = parseReply(t.allocator, "j/status", "{\"configProvider\":\"lua\"}").?;
    defer good.deinit();
    try t.expectEqualStrings("lua", desk.jsonStr(good.value, "configProvider"));
}

test "hyprland-ipc: request round trip over a real socket" {
    const t = std.testing;
    const io = t.io;
    const cwd = std.Io.Dir.cwd();

    var name_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-hypr-ipc-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(io, root) catch {};
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    const dir = try std.fs.path.join(t.allocator, &.{ root, "hypr", "sig" });
    defer t.allocator.free(dir);
    try cwd.createDirPath(io, dir);
    const path = try std.fs.path.join(t.allocator, &.{ dir, ".socket.sock" });
    defer t.allocator.free(path);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, path);
    try sock.listenOn(lfd, 4);

    // Answers `want` connections: `j/status` gets the lua provider document,
    // anything else is closed with no reply at all, which is what an
    // unrecognised command looks like to the caller.
    const Serve = struct {
        lfd: i32,
        want: u32,
        reply: []const u8,

        fn run(self: @This()) void {
            var served: u32 = 0;
            while (served < self.want) : (served += 1) {
                const c = self.accept() orelse return;
                defer sock.closeFd(c);
                if (self.readOne(c)) sock.sendAll(c, self.reply) catch {};
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

        /// Reads one command to EOF. Returns whether the peer asked for the
        /// one document this stub knows how to answer.
        fn readOne(_: @This(), c: i32) bool {
            var got: [512]u8 = undefined;
            var n: usize = 0;
            while (n < got.len) {
                const rc = linux.recvfrom(c, got[n..].ptr, got.len - n, 0, null, null);
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
                return false;
            }
            return std.mem.eql(u8, got[0..n], "j/status");
        }
    };
    var thread = try std.Thread.spawn(
        .{},
        Serve.run,
        .{Serve{ .lfd = lfd, .want = 3, .reply = "{\"configProvider\":\"lua\"}" }},
    );
    defer thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", "sig");
    // Point XDG at our sandbox root; `/tmp/hypr/sig` does not exist so the
    // fallback branch cannot accidentally satisfy the test.
    var xdg_buf: [160]u8 = undefined;
    const xdg = try std.fmt.bufPrint(&xdg_buf, "{s}", .{root});
    try env.put("XDG_RUNTIME_DIR", xdg);

    const found = (try resolvePaths(t.allocator, io, &env)).?;
    var owned = found;
    defer freePaths(t.allocator, &owned);
    try t.expect(std.mem.endsWith(u8, found.req, "/hypr/sig/.socket.sock"));

    const reply = requestOnce(t.allocator, found.req, "j/status").?;
    defer t.allocator.free(reply);
    try t.expectEqualStrings("{\"configProvider\":\"lua\"}", reply);

    // The same document, reached through the env-only path the config probes
    // use — this is the `hyprland_config_is_lua` behaviour.
    try t.expect(usesLuaConfig(t.allocator, io, &env));

    // A command the peer answers with nothing: closed, empty, not an error.
    const ignored = requestOnce(t.allocator, found.req, "nope").?;
    defer t.allocator.free(ignored);
    try t.expectEqual(@as(usize, 0), ignored.len);

    // A path in a directory that exists but holds no socket fails to connect.
    const absent = try std.fs.path.join(t.allocator, &.{ root, "hypr", "sig", ".absent.sock" });
    defer t.allocator.free(absent);
    try t.expect(requestOnce(t.allocator, absent, "j/status") == null);
}
