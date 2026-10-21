const std = @import("std");

pub const Curve = enum { linear, stepped };

pub fn stepsFor(max_nits: u32) u32 {
    if (max_nits == 0) return 20;
    if (max_nits <= 400) return 16;
    return 24;
}

pub fn pctToNits(pct: i32, max_nits: u32) u32 {
    const c = @max(0, @min(100, pct));
    return @intCast(@divTrunc(@as(u64, @intCast(c)) * @as(u64, max_nits), 100));
}

pub fn nitsToPct(nits: u32, max_nits: u32) i32 {
    if (max_nits == 0) return 0;
    return @intCast(@divTrunc(@as(u64, nits) * 100, @as(u64, max_nits)));
}

test "brightness: steps + conversions" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 16), stepsFor(300));
    try t.expectEqual(@as(u32, 24), stepsFor(1000));
    try t.expectEqual(@as(u32, 200), pctToNits(50, 400));
    try t.expectEqual(@as(i32, 50), nitsToPct(200, 400));
    try t.expectEqual(@as(i32, 0), nitsToPct(0, 0));
}
