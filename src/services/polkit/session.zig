//! The helper side of the polkit agent: a port of libpolkit-agent's
//! `PolkitAgentSession` (polkit src/polkitagent/polkitagentsession.c) with no
//! GLib underneath.
//!
//! The privileged half of authentication lives in polkit's own setuid
//! `polkit-agent-helper-1`. This session owns that child (or a connection to
//! the systemd-socket-activated variant), writes it the cookie, and speaks
//! the exact line protocol the C implementation does:
//!
//!     agent -> helper   <cookie>\n          right after spawn / connect
//!                       <user>\n            socket mode only, before the cookie
//!                       <response>\n        once per PAM prompt
//!
//!     helper -> agent   PAM_PROMPT_ECHO_OFF <escaped>\n
//!                       PAM_PROMPT_ECHO_ON <escaped>\n
//!                       PAM_ERROR_MSG <escaped>\n
//!                       PAM_TEXT_INFO <escaped>\n
//!                       SUCCESS\n | FAILURE\n
//!
//! The helper `g_strescape`s every message, so lines are decoded with the
//! matching `g_strcompress` rules before they reach the dialog. On any
//! terminal event — SUCCESS, FAILURE, EOF, HUP, an unknown line, or an
//! explicit cancel — the helper is SIGTERM'd, reaped, and closed, and the
//! callback sees exactly one terminal message.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("../../sock.zig");

/// systemd socket that lets the agent authenticate without the setuid
/// binary. Checked first, exactly like libpolkit does.
pub const socket_path = "/run/polkit/agent-helper.socket";

/// Where distros install the setuid helper. libpolkit uses
/// `PACKAGE_PREFIX "/lib/polkit-1/polkit-agent-helper-1"`; Fedora and
/// Debian both land on `/usr/lib/polkit-1`.
pub const helper_paths = [_][:0]const u8{
    "/usr/lib/polkit-1/polkit-agent-helper-1",
    "/usr/libexec/polkit-1/polkit-agent-helper-1",
    "/usr/local/lib/polkit-1/polkit-agent-helper-1",
};

/// One decoded protocol line. Slices point into the session's line arena and
/// are only valid for the duration of the callback — a consumer that keeps
/// them must copy.
pub const Message = union(enum) {
    prompt: Prompt,
    info: []const u8,
    err: []const u8,
    success,
    failure,

    pub const Prompt = struct {
        text: []const u8,
        echo: bool,
    };
};

pub const MessageCallback = *const fn (ctx: *anyopaque, msg: Message) void;

/// Called before the session closes its read fd so the event loop can drop
/// the poll watch; polling a closed descriptor is undefined.
pub const StopCallback = *const fn (ctx: *anyopaque, fd: i32) void;

/// Longest unterminated line the helper may write. PAM text is small; the
/// cap only exists so a helper that never sends `\n` cannot grow the buffer
/// without bound.
const kMaxBuffered = 64 * 1024;

/// The shape of a decoded line, before a session turns it into a `Message`.
pub const Decoded = union(enum) {
    prompt_echo_off: []const u8,
    prompt_echo_on: []const u8,
    error_msg: []const u8,
    text_info: []const u8,
    success,
    failure,
};

/// `g_strcompress`: undo the helper's `g_strescape`. Unknown escapes decode
/// to the escaped character itself, which is what glib does — the helper
/// never emits them, but a PAM module message must not be able to split a
/// line.
pub fn unescape(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    // The decode never grows the text (every escape shrinks), so one pass
    // over a full-size allocation is enough; the result is shrunk at the end
    // so the caller can free it with the length it holds.
    const out = try alloc.alloc(u8, src.len);
    errdefer alloc.free(out);
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        i += 1;
        if (ch != '\\') {
            out[n] = ch;
            n += 1;
            continue;
        }
        if (i >= src.len) break; // trailing backslash: glib drops it
        const e = src[i];
        i += 1;
        out[n] = switch (e) {
            '0'...'7' => blk: {
                var v: u32 = e - '0';
                var k: u8 = 0;
                while (k < 2 and i < src.len and src[i] >= '0' and src[i] <= '7') : (k += 1) {
                    v = v * 8 + (src[i] - '0');
                    i += 1;
                }
                break :blk @truncate(v);
            },
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 0x0b,
            '\\' => '\\',
            '"' => '"',
            else => e,
        };
        n += 1;
    }
    return try alloc.realloc(out, n);
}

/// Classify one unescaped line. Prefix matching mirrors `g_str_has_prefix`
/// in the C session, including its quirks: the PAM_* prefixes carry their
/// trailing space (a bare "PAM_PROMPT_ECHO_OFF" is unknown), while SUCCESS /
/// FAILURE match any line starting with those words.
pub fn decode(text: []const u8) ?Decoded {
    if (std.mem.startsWith(u8, text, "PAM_PROMPT_ECHO_OFF ")) {
        return .{ .prompt_echo_off = text["PAM_PROMPT_ECHO_OFF ".len..] };
    }
    if (std.mem.startsWith(u8, text, "PAM_PROMPT_ECHO_ON ")) {
        return .{ .prompt_echo_on = text["PAM_PROMPT_ECHO_ON ".len..] };
    }
    if (std.mem.startsWith(u8, text, "PAM_ERROR_MSG ")) {
        return .{ .error_msg = text["PAM_ERROR_MSG ".len..] };
    }
    if (std.mem.startsWith(u8, text, "PAM_TEXT_INFO ")) {
        return .{ .text_info = text["PAM_TEXT_INFO ".len..] };
    }
    if (std.mem.startsWith(u8, text, "SUCCESS")) return .success;
    if (std.mem.startsWith(u8, text, "FAILURE")) return .failure;
    return null;
}

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    child: ?std.process.Child = null,
    pid: i32 = -1,
    /// Write end: helper stdin, or the socket itself.
    in_fd: i32 = -1,
    /// Read end: helper stdout, or the socket itself (same fd in socket mode).
    out_fd: i32 = -1,
    socket_mode: bool = false,

    /// Human name of the user being authenticated; owned by the caller and
    /// only read during `start`.
    user: []const u8 = &.{},
    /// Owned by the caller (the agent keeps it for the lifetime of the
    /// request); only read during `start` and `respond`.
    cookie: []const u8 = &.{},

    running: bool = false,
    reported: bool = false,
    rbuf: std.ArrayList(u8) = .empty,
    arena: std.heap.ArenaAllocator,

    on_message: ?MessageCallback = null,
    cb_ctx: ?*anyopaque = null,
    on_stop: ?StopCallback = null,
    stop_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Self {
        return .{
            .gpa = gpa,
            .io = io,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.rbuf.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn live(self: *const Self) bool {
        return self.running;
    }

    /// The fd the event loop should poll for helper output.
    pub fn pollFd(self: *const Self) i32 {
        return self.out_fd;
    }

    fn emit(self: *Self, msg: Message) void {
        const cb = self.on_message orelse return;
        cb(self.cb_ctx orelse return, msg);
    }

    /// Small writes on a pipe or socket: the buffer cannot fill for a
    /// protocol line, but EINTR/EAGAIN are still retried rather than dropped.
    fn writeAll(fd: i32, bytes: []const u8) void {
        var off: usize = 0;
        var spins: u32 = 0;
        while (off < bytes.len) {
            const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
            const s: isize = @bitCast(rc);
            if (s < 0) {
                const e = linux.errno(rc);
                if (e == .INTR) continue;
                if (e == .AGAIN) {
                    spins += 1;
                    if (spins > 5000) return;
                    var ts: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
                    _ = linux.nanosleep(&ts, null);
                    continue;
                }
                return;
            }
            if (s == 0) return;
            off += @intCast(s);
            spins = 0;
        }
    }

    fn firstExistingHelper() ?[]const u8 {
        for (helper_paths) |p| {
            if (linux.errno(linux.access(p.ptr, linux.F_OK)) == .SUCCESS) return p;
        }
        return null;
    }

    /// Start a helper for `user`, sending the cookie first. Returns false if
    /// neither the socket nor the setuid helper could be used — the caller
    /// then reports the session as completed-without-authorization, which is
    /// what libpolkit does.
    pub fn start(self: *Self, user: []const u8, cookie: []const u8) bool {
        self.reset();
        self.user = user;
        self.cookie = cookie;

        if (linux.errno(linux.access(socket_path, linux.F_OK)) == .SUCCESS) {
            const fd = sock.createStream(true) catch -1;
            if (fd >= 0) {
                if (sock.connectPath(fd, socket_path) == null) {
                    self.in_fd = fd;
                    self.out_fd = fd;
                    self.socket_mode = true;
                    // Socket mode: the helper cannot see our process, so the
                    // user name travels first and identifies the identity.
                    writeAll(fd, user);
                    writeAll(fd, "\n");
                } else {
                    sock.closeFd(fd);
                }
            }
        }

        if (self.out_fd < 0) {
            const helper = firstExistingHelper() orelse return false;
            const child = std.process.spawn(self.io, .{
                .argv = &.{ helper, user },
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
            }) catch return false;
            self.child = child;
            self.pid = child.id orelse -1;
            self.in_fd = child.stdin.?.handle;
            self.out_fd = child.stdout.?.handle;
        }

        sock.setNonblock(self.out_fd);

        // The cookie goes on the private pipe (or socket), never in argv.
        writeAll(self.in_fd, cookie);
        writeAll(self.in_fd, "\n");

        self.running = true;
        self.reported = false;
        return true;
    }

    /// Deliver the user's response to the pending prompt. A trailing newline
    /// is added when missing, matching `polkit_agent_session_response`.
    pub fn respond(self: *Self, response: []const u8) void {
        if (!self.running) return;
        writeAll(self.in_fd, response);
        if (response.len == 0 or response[response.len - 1] != '\n') writeAll(self.in_fd, "\n");
    }

    /// Tear down the helper and report failure exactly once. Cancel is
    /// idempotent; a session that already reported SUCCESS/FAILURE ignores it.
    pub fn cancel(self: *Self) void {
        self.finish(false);
    }

    pub fn stop(self: *Self) void {
        self.teardown();
    }

    fn reset(self: *Self) void {
        self.child = null;
        self.pid = -1;
        self.in_fd = -1;
        self.out_fd = -1;
        self.socket_mode = false;
        self.running = false;
        self.reported = false;
        self.rbuf.clearRetainingCapacity();
    }

    fn teardown(self: *Self) void {
        const read_fd = self.out_fd;
        if (self.on_stop) |cb| {
            if (read_fd >= 0) cb(self.stop_ctx orelse undefined, read_fd);
        }
        if (self.in_fd >= 0 and self.in_fd != self.out_fd) _ = linux.close(self.in_fd);
        if (self.out_fd >= 0) _ = linux.close(self.out_fd);
        if (self.child) |*child| {
            if (child.id) |pid| {
                _ = linux.kill(pid, .TERM);
                var status: u32 = 0;
                const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
                if (@as(isize, @bitCast(rc)) == 0) {
                    // Still alive one syscall after SIGTERM. Reap off the
                    // main loop: the C++ hit (and logged) a cancel path that
                    // blocked on the helper, wedging the dialog on screen.
                    if (std.Thread.spawn(.{}, reapDetached, .{pid})) |th| {
                        th.detach();
                    } else |_| {
                        var st: u32 = 0;
                        _ = linux.waitpid(pid, &st, 0);
                    }
                }
            }
        }
        self.reset();
    }

    fn reapDetached(pid: i32) void {
        var status: u32 = 0;
        while (true) {
            const rc = linux.waitpid(pid, &status, 0);
            const s: isize = @bitCast(rc);
            if (s < 0 and linux.errno(rc) == .INTR) continue;
            return;
        }
    }

    /// Kill the helper, close the pipes, and emit the terminal message once.
    fn finish(self: *Self, ok: bool) void {
        if (!self.running) return;
        self.teardown();
        if (!self.reported) {
            self.reported = true;
            self.emit(if (ok) .success else .failure);
        }
    }

    /// Drain the helper fd and dispatch every complete line. A closed pipe, a
    /// read error, or an unknown line completes the session as a failure —
    /// exactly the cases libpolkit's io watch treats as `complete(FALSE)`.
    pub fn onReadable(self: *Self) void {
        if (!self.running) return;
        var chunk: [4096]u8 = undefined;
        while (true) {
            const rc = linux.read(self.out_fd, &chunk, chunk.len);
            const s: isize = @bitCast(rc);
            if (s < 0) {
                const e = linux.errno(rc);
                if (e == .INTR) continue;
                if (e == .AGAIN) break;
                self.finish(false);
                return;
            }
            if (s == 0) {
                self.finish(false);
                return;
            }
            self.rbuf.appendSlice(self.gpa, chunk[0..@intCast(s)]) catch {
                self.finish(false);
                return;
            };
            if (self.rbuf.items.len > kMaxBuffered) {
                self.finish(false);
                return;
            }
        }

        while (self.running) {
            const nl = std.mem.indexOfScalar(u8, self.rbuf.items, '\n') orelse break;
            const line_len = nl;
            const rest_len = self.rbuf.items.len - nl - 1;
            // Copy the line out before consuming it: emitting may tear the
            // session down and clear the buffer.
            _ = self.arena.reset(.retain_capacity);
            const aa = self.arena.allocator();
            const raw = aa.dupe(u8, self.rbuf.items[0..line_len]) catch {
                self.finish(false);
                return;
            };
            std.mem.copyForwards(u8, self.rbuf.items[0..rest_len], self.rbuf.items[nl + 1 ..]);
            self.rbuf.shrinkRetainingCapacity(rest_len);
            self.emitLine(raw);
        }
    }

    fn emitLine(self: *Self, raw: []const u8) void {
        const aa = self.arena.allocator();
        const text = unescape(aa, raw) catch {
            self.finish(false);
            return;
        };
        const decoded = decode(text) orelse {
            // Unknown line. libpolkit warns and gives up on the session.
            self.finish(false);
            return;
        };
        switch (decoded) {
            .prompt_echo_off => |t| self.emit(.{ .prompt = .{ .text = t, .echo = false } }),
            .prompt_echo_on => |t| self.emit(.{ .prompt = .{ .text = t, .echo = true } }),
            .error_msg => |t| self.emit(.{ .err = t }),
            .text_info => |t| self.emit(.{ .info = t }),
            .success => self.finish(true),
            .failure => self.finish(false),
        }
    }
};

// -- tests -----------------------------------------------------------------

const testing = std.testing;

test "unescape: g_strcompress escapes and octal" {
    const t = testing;
    {
        const got = try unescape(t.allocator, "plain text");
        defer t.allocator.free(got);
        try t.expectEqualStrings("plain text", got);
    }
    {
        const got = try unescape(t.allocator, "a\\nb\\tc\\\\d");
        defer t.allocator.free(got);
        try t.expectEqualStrings("a\nb\tc\\d", got);
    }
    {
        const got = try unescape(t.allocator, "\\101\\102\\103");
        defer t.allocator.free(got);
        try t.expectEqualStrings("ABC", got);
    }
    {
        // Unknown escape keeps the escaped byte; a trailing backslash is
        // dropped (both are glib's behavior).
        const got = try unescape(t.allocator, "x\\qy\\");
        defer t.allocator.free(got);
        try t.expectEqualStrings("xqy", got);
    }
    {
        const got = try unescape(t.allocator, "\\\"quoted\\\"");
        defer t.allocator.free(got);
        try t.expectEqualStrings("\"quoted\"", got);
    }
}

test "decode: protocol prefixes" {
    try testing.expectEqualDeep(
        @as(?Decoded, .{ .prompt_echo_off = "Password:" }),
        decode("PAM_PROMPT_ECHO_OFF Password:"),
    );
    try testing.expectEqualDeep(
        @as(?Decoded, .{ .prompt_echo_on = "Login:" }),
        decode("PAM_PROMPT_ECHO_ON Login:"),
    );
    try testing.expectEqualDeep(@as(?Decoded, .{ .error_msg = "denied" }), decode("PAM_ERROR_MSG denied"));
    try testing.expectEqualDeep(@as(?Decoded, .{ .text_info = "hint" }), decode("PAM_TEXT_INFO hint"));
    try testing.expectEqualDeep(@as(?Decoded, .success), decode("SUCCESS"));
    try testing.expectEqualDeep(@as(?Decoded, .failure), decode("FAILURE"));
    // Prefix quirks: the PAM_* names need their trailing space, SUCCESS and
    // FAILURE are plain prefixes.
    try testing.expectEqual(@as(?Decoded, null), decode("PAM_PROMPT_ECHO_OFF"));
    try testing.expectEqualDeep(@as(?Decoded, .{ .prompt_echo_off = "" }), decode("PAM_PROMPT_ECHO_OFF "));
    try testing.expectEqualDeep(@as(?Decoded, .success), decode("SUCCESSFUL"));
    try testing.expectEqual(@as(?Decoded, null), decode("WHAT"));
}

/// A session wired to a pipe standing in for the helper: no child, no
/// teardown, but the real buffering, unescaping and line splitting.
const Harness = struct {
    session: Session,
    read_fd: i32,
    write_fd: i32,
    prompts: usize = 0,
    successes: usize = 0,
    failures: usize = 0,

    fn open(self: *Harness) !void {
        var fds: [2]i32 = undefined;
        if (linux.pipe(&fds) != 0) return error.SkipZigTest;
        self.read_fd = fds[0];
        self.write_fd = fds[1];
        self.prompts = 0;
        self.successes = 0;
        self.failures = 0;
        // The production fd is non-blocking (the loop polls it); a blocking
        // read end would hang `onReadable`'s drain loop forever.
        sock.setNonblock(fds[0]);
        self.session = Session.init(testing.allocator, std.testing.io);
        self.session.out_fd = fds[0];
        self.session.running = true;
        self.session.on_message = onMsg;
        self.session.cb_ctx = self;
    }

    fn close(self: *Harness) void {
        self.session.running = false;
        self.session.child = null;
        self.session.in_fd = -1;
        self.session.out_fd = -1;
        self.session.deinit();
        _ = linux.close(self.read_fd);
        _ = linux.close(self.write_fd);
    }

    fn feed(self: *Harness, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = linux.write(self.write_fd, bytes.ptr + off, bytes.len - off);
            const s: isize = @bitCast(rc);
            if (s <= 0) return;
            off += @intCast(s);
        }
    }

    fn onMsg(ctx: *anyopaque, msg: Message) void {
        const h: *Harness = @ptrCast(@alignCast(ctx));
        switch (msg) {
            .prompt => h.prompts += 1,
            .success => h.successes += 1,
            .failure => h.failures += 1,
            else => {},
        }
    }
};

test "session: line buffering across reads" {
    const t = testing;
    var h: Harness = undefined;
    try h.open();
    defer h.close();

    // Half a line: nothing may be emitted yet.
    h.feed("PAM_PROMPT_ECHO_OFF Pass");
    h.session.onReadable();
    try t.expectEqual(@as(usize, 0), h.prompts);
    // The rest of the prompt, its real line terminator, then SUCCESS.
    h.feed("word:\nSUCCESS\n");
    h.session.onReadable();
    try t.expectEqual(@as(usize, 1), h.prompts);
    try t.expectEqual(@as(usize, 1), h.successes);
    try t.expect(!h.session.running);
    try t.expect(h.session.reported);
}

test "session: unknown line completes as failure once" {
    const t = testing;
    var h: Harness = undefined;
    try h.open();
    defer h.close();

    h.feed("GIBBERISH\n");
    h.session.onReadable();
    try t.expectEqual(@as(usize, 1), h.failures);
    // A second pump after completion must not emit again.
    h.session.onReadable();
    try t.expectEqual(@as(usize, 1), h.failures);
}

test "session: cancel is idempotent and reports failure once" {
    const t = testing;
    var h: Harness = undefined;
    try h.open();
    defer h.close();

    h.session.cancel();
    try t.expectEqual(@as(usize, 1), h.failures);
    h.session.cancel();
    try t.expectEqual(@as(usize, 1), h.failures);
    try t.expect(!h.session.running);
}
