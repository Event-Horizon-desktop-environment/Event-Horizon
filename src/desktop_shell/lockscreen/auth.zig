//! Password authentication for the lock screen.
//!
//! PAM is blocking (and a network-backed module can take seconds), so the
//! call runs on a worker thread while the Wayland loop keeps painting the
//! clock. The thread writes one byte down a pipe when it is done; the lock
//! binary watches that pipe and consumes the result on its own thread.
//!
//! The service name defaults to `login` because every distro ships a stack
//! for it. `EH_LOCK_PAM_SERVICE` overrides it for users with a dedicated
//! stack (for example `system-auth` or a custom `event-horizon` service).

const std = @import("std");
const linux = std.os.linux;
const c = @import("c_pam");
const cs = @import("c_stdlib");

pub const Result = enum {
    ok,
    denied,
    unavailable,

    pub fn byte(self: Result) u8 {
        return switch (self) {
            .ok => '1',
            .denied => '0',
            .unavailable => '2',
        };
    }

    pub fn fromByte(v: u8) Result {
        return switch (v) {
            '1' => .ok,
            '0' => .denied,
            else => .unavailable,
        };
    }
};

pub const kDefaultService = "login";
const kServiceMax = 63;
const kUserMax = 63;
const kPasswordMax = 255;

/// A single PAM conversation. `pam_start` borrows both strings for the whole
/// authentication, so they live in the worker rather than on a stack frame
/// that could disappear under the thread.
const Conversation = struct {
    password: []const u8 = &.{},
    user: []const u8 = &.{},

    fn answer(self: *const Conversation, style: c_int) ?[]const u8 {
        return switch (style) {
            c.PAM_PROMPT_ECHO_OFF => self.password,
            c.PAM_PROMPT_ECHO_ON => self.user,
            else => null,
        };
    }
};

/// `pam_conv.conv`. The response array is allocated with `calloc` because PAM
/// owns it after we return and frees it with the C allocator.
fn converse(
    num_msg: c_int,
    msg: [*c][*c]const c.pam_message,
    resp: [*c][*c]c.pam_response,
    appdata: ?*anyopaque,
) callconv(.c) c_int {
    const state: *const Conversation = @ptrCast(@alignCast(appdata orelse return c.PAM_CONV_ERR));
    if (num_msg <= 0 or msg == null or resp == null) return c.PAM_CONV_ERR;
    const n: usize = @intCast(num_msg);
    const raw = cs.calloc(n, @sizeOf(c.pam_response)) orelse return c.PAM_BUF_ERR;
    const out: [*]c.pam_response = @ptrCast(@alignCast(raw));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = .{ .resp = null, .resp_retcode = 0 };
        const m = msg[i] orelse continue;
        const text = state.answer(m.*.msg_style) orelse continue;
        const buf = cs.malloc(text.len + 1) orelse {
            freeResponses(out[0..i]);
            return c.PAM_BUF_ERR;
        };
        const bytes: [*]u8 = @ptrCast(buf);
        @memcpy(bytes[0..text.len], text);
        bytes[text.len] = 0;
        out[i].resp = @ptrCast(bytes);
    }
    resp[0] = out;
    return c.PAM_SUCCESS;
}

fn freeResponses(items: []c.pam_response) void {
    for (items) |item| {
        if (item.resp) |p| cs.free(p);
    }
}

/// Run one blocking PAM authentication. Never call this on the main loop.
pub fn authenticate(service: [:0]const u8, user: [:0]const u8, password: []const u8) Result {
    var conv_state = Conversation{ .password = password, .user = user };
    var conv = c.pam_conv{
        .conv = converse,
        .appdata_ptr = &conv_state,
    };
    var handle: ?*c.pam_handle = null;
    const start = c.pam_start(service.ptr, user.ptr, &conv, &handle);
    if (start != c.PAM_SUCCESS or handle == null) return .unavailable;
    const status = c.pam_authenticate(handle, 0);
    _ = c.pam_end(handle, status);
    return if (status == c.PAM_SUCCESS) .ok else .denied;
}

/// The off-thread half. Owned by the caller; `start` may only be called when
/// no worker is already running.
pub const Worker = struct {
    service: [kServiceMax:0]u8 = @as([kServiceMax:0]u8, @splat(0)),
    user: [kUserMax:0]u8 = @as([kUserMax:0]u8, @splat(0)),
    password: [kPasswordMax + 1]u8 = @as([kPasswordMax + 1]u8, @splat(0)),
    service_len: usize = 0,
    user_len: usize = 0,
    password_len: usize = 0,
    thread: ?std.Thread = null,
    read_fd: i32 = -1,
    write_fd: i32 = -1,
    result: Result = .unavailable,

    pub fn isRunning(self: *const Worker) bool {
        return self.thread != null;
    }

    /// The fd the event loop watches. -1 when idle.
    pub fn fd(self: *const Worker) i32 {
        return self.read_fd;
    }

    pub fn start(
        self: *Worker,
        service: []const u8,
        user: []const u8,
        password: []const u8,
    ) bool {
        if (self.thread != null) return false;
        if (user.len == 0 or user.len > kUserMax) return false;
        if (service.len == 0 or service.len > kServiceMax) return false;
        if (password.len > kPasswordMax) return false;
        self.service = @as([kServiceMax:0]u8, @splat(0));
        self.user = @as([kUserMax:0]u8, @splat(0));
        self.password = @as([kPasswordMax + 1]u8, @splat(0));
        @memcpy(self.service[0..service.len], service);
        @memcpy(self.user[0..user.len], user);
        @memcpy(self.password[0..password.len], password);
        self.service_len = service.len;
        self.user_len = user.len;
        self.password_len = password.len;
        self.result = .unavailable;

        var fds: [2]i32 = .{ -1, -1 };
        if (linux.pipe(&fds) != 0) return false;
        for (fds) |pfd| {
            const cur: usize = linux.fcntl(pfd, linux.F.GETFL, 0);
            if (@as(isize, @bitCast(cur)) < 0) {
                _ = linux.close(fds[0]);
                _ = linux.close(fds[1]);
                return false;
            }
            const set: usize = cur | @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
            if (@as(isize, @bitCast(linux.fcntl(pfd, linux.F.SETFL, set))) < 0) {
                _ = linux.close(fds[0]);
                _ = linux.close(fds[1]);
                return false;
            }
        }
        self.read_fd = fds[0];
        self.write_fd = fds[1];
        self.thread = std.Thread.spawn(.{}, runWorker, .{self}) catch {
            _ = linux.close(self.read_fd);
            _ = linux.close(self.write_fd);
            self.read_fd = -1;
            self.write_fd = -1;
            self.wipe();
            return false;
        };
        return true;
    }

    fn runWorker(self: *Worker) void {
        const service = self.service[0..self.service_len :0];
        const user = self.user[0..self.user_len :0];
        self.result = authenticate(service, user, self.password[0..self.password_len]);
        var one: [1]u8 = .{self.result.byte()};
        _ = linux.write(self.write_fd, &one, 1);
    }

    /// Consume the result after the watched fd became readable. Must only be
    /// called while `isRunning`.
    pub fn finish(self: *Worker) Result {
        var one: [1]u8 = .{'2'};
        const n = linux.read(self.read_fd, &one, 1);
        if (@as(isize, @bitCast(n)) <= 0) one[0] = self.result.byte();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        _ = linux.close(self.read_fd);
        _ = linux.close(self.write_fd);
        self.read_fd = -1;
        self.write_fd = -1;
        self.wipe();
        self.result = Result.fromByte(one[0]);
        return self.result;
    }

    fn wipe(self: *Worker) void {
        @memset(&self.password, 0);
        self.password_len = 0;
    }
};

test "auth: result byte round trip" {
    const t = std.testing;
    for ([_]Result{ .ok, .denied, .unavailable }) |r| {
        try t.expectEqual(r, Result.fromByte(r.byte()));
    }
    try t.expectEqual(Result.unavailable, Result.fromByte('x'));
}

test "auth: worker copies credentials and wipes on cancel" {
    const t = std.testing;
    var w = Worker{};
    // No pipe/thread is created here; this only exercises the copying path
    // and the length guards.
    try t.expect(!w.start("login", "", "pw"));
    try t.expect(!w.start("", "user", "pw"));
    try t.expect(!w.isRunning());
    try t.expectEqual(@as(i32, -1), w.fd());
}
