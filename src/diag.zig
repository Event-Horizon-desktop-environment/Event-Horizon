//! Temporary end-to-end diagnostics for the settings → `dock.toml` → dock
//! reload chain. Both the settings app and the dock append to
//! `~/EH-logs/diag-chain.log` so the handoff between the two processes can be
//! read in one place. Remove once the chain is verified.

const std = @import("std");

/// Appends one timestamped line (`[epoch-ms] message`). Every step is a
/// no-op on error and never disturbs the caller's control flow, so call
/// sites stay free of handling — the shared log must be able to break down
/// without taking the dock down with it.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    const home_c = std.c.getenv("HOME") orelse return;
    const home = std.mem.span(home_c);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/EH-logs/diag-chain.log", .{home}) catch return;

    var msg_buf: [768]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;

    var line_buf: [832]u8 = undefined;
    var ts: std.os.linux.timespec = undefined;
    const ms = if (std.os.linux.clock_gettime(.MONOTONIC, &ts) == 0)
        ts.sec * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000)
    else
        0;
    const line = std.fmt.bufPrint(&line_buf, "[{d}ms] {s}\n", .{ ms, msg }) catch return;

    var zbuf: [512:0]u8 = @as([512:0]u8, @splat(0));
    if (path.len + 1 > zbuf.len) return;
    @memcpy(zbuf[0..path.len], path);
    const fd_rc = std.os.linux.open(&zbuf, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    if (std.os.linux.errno(fd_rc) != .SUCCESS) return;
    const fd: std.posix.fd_t = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);
    _ = std.os.linux.write(fd, line.ptr, line.len);
}
