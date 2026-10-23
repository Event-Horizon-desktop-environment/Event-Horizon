const std = @import("std");

const c = @import("c_stdlib");

pub const supervisor_env = "EH_SUPERVISOR_PID";
const max_pid: i64 = 4194304;

pub const GuardState = enum {
    standalone,
    guarded,
};

fn getMarker() ?[]const u8 {
    const p = c.getenv(supervisor_env);
    if (p == null) return null;
    return std.mem.span(p);
}

pub fn installGuard() GuardState {
    const raw = getMarker() orelse return .standalone;
    if (raw.len == 0) return .standalone;
    const v = std.fmt.parseInt(i64, raw, 10) catch return .standalone;
    if (v <= 1 or v > max_pid) return .standalone;
    const expected: std.posix.pid_t = @intCast(v);

    _ = c.unsetenv(supervisor_env);
    const sigkill: usize = @intCast(@intFromEnum(std.posix.SIG.KILL));
    _ = std.posix.prctl(.SET_PDEATHSIG, .{sigkill}) catch std.process.exit(1);
    if (std.posix.getppid() != expected) std.process.exit(1);
    return .guarded;
}

pub fn markChildEnv() void {
    var buf: [32]u8 = undefined;
    const val = std.fmt.bufPrintSentinel(&buf, "{d}", .{std.os.linux.getpid()}, 0) catch return;
    _ = c.setenv(supervisor_env, val.ptr, 1);
}

pub fn clearChildEnv() void {
    _ = c.unsetenv(supervisor_env);
}

test "guard: standalone without marker" {
    _ = c.unsetenv(supervisor_env);
    try std.testing.expectEqual(GuardState.standalone, installGuard());
}

test "guard: garbage and out-of-range markers stay standalone" {
    const t = std.testing;
    for ([_][:0]const u8{ "abc", "", "0", "1", "-5", "99999999", "12x" }) |bad| {
        _ = c.setenv(supervisor_env, bad.ptr, 1);
        try t.expectEqual(GuardState.standalone, installGuard());
    }
    _ = c.unsetenv(supervisor_env);
}
