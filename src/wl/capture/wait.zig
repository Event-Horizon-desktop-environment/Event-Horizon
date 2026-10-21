//! Bounded waits for capture replies. Poll the display fd in short slices
//! and dispatch until the caller's predicate says the wait is over or the
//! deadline passes: a compositor that stops answering costs one timeout
//! instead of hanging the shell. Capture is the only path that waits on
//! purpose, so the shell's normal loop never needs a timeout of its own.

const std = @import("std");
const wl = @import("../c.zig").wl;

fn nowMs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

/// Flush pending requests, then dispatch events until `done(ctx)` reports
/// the wait finished. False on timeout, a missing display, or a display
/// error — the caller decides what a failed wait means.
pub fn pumpUntil(
    display: ?*wl.wl_display,
    ctx: anytype,
    comptime done: fn (@TypeOf(ctx)) bool,
    timeout_ms: u64,
) bool {
    const d = display orelse return false;
    const fd = wl.wl_display_get_fd(d);
    const deadline = nowMs() + timeout_ms;
    while (!done(ctx)) {
        const now = nowMs();
        if (now >= deadline) return false;
        _ = wl.wl_display_flush(d);
        const slice: i32 = @intCast(@min(deadline - now, 25));
        var pfd = [1]std.posix.pollfd{ .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 } };
        const n = std.posix.poll(&pfd, @max(1, slice)) catch return false;
        if (n == 0) continue;
        if (wl.wl_display_dispatch(d) < 0) return false;
    }
    return true;
}

test "wl-capture-wait: a missing display never completes a wait" {
    const t = std.testing;
    var flag = false;
    const doneFn = struct {
        fn call(f: *bool) bool {
            return f.*;
        }
    }.call;
    try t.expect(!pumpUntil(null, &flag, doneFn, 10));
    flag = true;
    try t.expect(!pumpUntil(null, &flag, doneFn, 10));
}
