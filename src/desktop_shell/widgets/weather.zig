const std = @import("std");

pub const Condition = enum { clear, clouds, rain, snow, storm, fog, unknown };

pub fn parseCondition(icon: []const u8) Condition {
    if (std.mem.startsWith(u8, icon, "01")) return .clear;
    if (std.mem.startsWith(u8, icon, "02")) return .clouds;
    if (std.mem.startsWith(u8, icon, "03") or std.mem.startsWith(u8, icon, "04")) return .clouds;
    if (std.mem.startsWith(u8, icon, "09") or std.mem.startsWith(u8, icon, "10")) return .rain;
    if (std.mem.startsWith(u8, icon, "11")) return .storm;
    if (std.mem.startsWith(u8, icon, "13")) return .snow;
    if (std.mem.startsWith(u8, icon, "50")) return .fog;
    return .unknown;
}

pub fn formatTemp(alloc: std.mem.Allocator, celsius: f64, unit: u8) ![]u8 {
    if (unit == 'F' or unit == 'f') {
        return std.fmt.allocPrint(alloc, "{d}°F", .{@as(i32, @intFromFloat(@round(celsius * 9.0 / 5.0 + 32.0)))});
    }
    return std.fmt.allocPrint(alloc, "{d}°C", .{@as(i32, @intFromFloat(@round(celsius)))});
}

test "weather: icon codes + units" {
    const t = std.testing;
    try t.expectEqual(Condition.clear, parseCondition("01d"));
    try t.expectEqual(Condition.rain, parseCondition("10n"));
    try t.expectEqual(Condition.unknown, parseCondition("zz"));
    const a = try formatTemp(t.allocator, 21.6, 'C');
    defer t.allocator.free(a);
    try t.expectEqualStrings("22°C", a);
    const b = try formatTemp(t.allocator, 0, 'F');
    defer t.allocator.free(b);
    try t.expectEqualStrings("32°F", b);
}
