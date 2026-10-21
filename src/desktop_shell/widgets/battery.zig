const std = @import("std");

pub const Level = enum { full, high, medium, low, critical, unknown };

pub fn levelFor(pct: i32, charging: bool) Level {
    if (pct < 0 or pct > 100) return .unknown;
    if (charging and pct >= 99) return .full;
    if (pct >= 60) return .high;
    if (pct >= 30) return .medium;
    if (pct >= 15) return .low;
    return .critical;
}

pub fn iconName(level: Level, charging: bool) []const u8 {
    if (charging) return "battery-charging";
    return switch (level) {
        .full => "battery-full",
        .high => "battery-good",
        .medium => "battery-medium",
        .low => "battery-low",
        .critical => "battery-caution",
        .unknown => "battery-missing",
    };
}

pub fn timeRemainingMin(pct: i32, rate_pct_per_hour: f64, charging: bool) ?u32 {
    if (rate_pct_per_hour <= 0) return null;
    if (charging) {
        if (pct >= 100) return 0;
        return @intFromFloat(@as(f64, @floatFromInt(100 - pct)) / rate_pct_per_hour * 60.0);
    }
    return @intFromFloat(@as(f64, @floatFromInt(pct)) / rate_pct_per_hour * 60.0);
}

test "battery: levels + icons + eta" {
    const t = std.testing;
    try t.expectEqual(Level.high, levelFor(80, false));
    try t.expectEqual(Level.critical, levelFor(5, false));
    try t.expectEqual(Level.full, levelFor(100, true));
    try t.expectEqualStrings("battery-low", iconName(.low, false));
    try t.expectEqualStrings("battery-charging", iconName(.low, true));
    try t.expectEqual(@as(?u32, 60), timeRemainingMin(50, 50.0, false));
    try t.expect(timeRemainingMin(50, 0, false) == null);
}
