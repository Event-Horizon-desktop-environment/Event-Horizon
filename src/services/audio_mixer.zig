const std = @import("std");

pub const max_volume_pct: i32 = 150;

pub fn clampVolume(pct: i32, allow_overamp: bool) i32 {
    const hi: i32 = if (allow_overamp) max_volume_pct else 100;
    return @max(0, @min(hi, pct));
}

pub fn volumeToScalar(pct: i32) f64 {
    const c = @as(f64, @floatFromInt(@max(0, @min(150, pct)))) / 100.0;
    return c * c * c;
}

pub fn scalarToVolume(scalar: f64) i32 {
    const c = @max(0.0, @min(1.5, scalar));
    return @intFromFloat(@round(100.0 * std.math.pow(f64, c, 1.0 / 3.0)));
}

pub const Channel = struct {
    name: []const u8,
    volume_pct: i32 = 100,
    muted: bool = false,
};

test "audio-mixer: clamp + cubic curves" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 100), clampVolume(150, false));
    try t.expectEqual(@as(i32, 150), clampVolume(150, true));
    try t.expectEqual(@as(i32, 0), clampVolume(-5, false));
    try t.expect(volumeToScalar(100) > 0.99 and volumeToScalar(100) <= 1.0);
    try t.expect(volumeToScalar(50) < 0.2);
    try t.expectEqual(@as(i32, 100), scalarToVolume(1.0));
    try t.expectEqual(@as(i32, 50), scalarToVolume(volumeToScalar(50)));
}
