const std = @import("std");

pub const Monitor = struct {
    name: []const u8,
    w: i32 = 0,
    h: i32 = 0,
    scale_pct: i32 = 100,
    x: i32 = 0,
    y: i32 = 0,
    primary: bool = false,
};

pub fn arrangeSideBySide(monitors: []Monitor) void {
    var x: i32 = 0;
    for (monitors) |*m| {
        m.x = x;
        m.y = 0;
        x += @divTrunc(m.w * m.scale_pct, 100);
    }
}

pub fn findPrimary(monitors: []const Monitor) ?usize {
    for (monitors, 0..) |m, i| {
        if (m.primary) return i;
    }
    if (monitors.len > 0) return 0;
    return null;
}

test "settings-monitors: arrange + primary" {
    const t = std.testing;
    var ms = [_]Monitor{ .{ .name = "DP-1", .w = 1920 }, .{ .name = "HDMI-1", .w = 1280, .primary = true } };
    arrangeSideBySide(&ms);
    try t.expectEqual(@as(i32, 0), ms[0].x);
    try t.expectEqual(@as(i32, 1920), ms[1].x);
    try t.expectEqual(@as(usize, 1), findPrimary(&ms).?);
}
