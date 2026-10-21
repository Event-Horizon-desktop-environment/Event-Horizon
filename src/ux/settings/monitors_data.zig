const std = @import("std");

// Monitor data model — Zig port of
// src/ux/settings/data/monitors/settings_monitors.{hpp,cpp} + utils/monitors/*.
// Same design: rows with mode/refresh/scale/position, arrange-rect canvas,
// DRM probe aggregation is I/O (not here); layout math is pure and tested.

pub const MonitorRow = struct {
    name: []const u8,
    w: i32 = 1920,
    h: i32 = 1080,
    refresh_mhz: i32 = 60000,
    scale_pct: i32 = 100,
    x: i32 = 0,
    y: i32 = 0,
    enabled: bool = true,
    primary: bool = false,
};

pub fn scaledW(m: MonitorRow) i32 {
    return @divTrunc(m.w * m.scale_pct, 100);
}

pub fn arrangeRow(mons: []MonitorRow) void {
    var x: i32 = 0;
    for (mons) |*m| {
        if (!m.enabled) continue;
        m.x = x;
        m.y = 0;
        x += scaledW(m.*);
    }
}

pub fn totalWidth(mons: []const MonitorRow) i32 {
    var w: i32 = 0;
    for (mons) |m| {
        if (m.enabled) w += scaledW(m);
    }
    return w;
}

pub fn primaryIndex(mons: []const MonitorRow) ?usize {
    for (mons, 0..) |m, i| {
        if (m.primary and m.enabled) return i;
    }
    for (mons, 0..) |m, i| {
        if (m.enabled) return i;
    }
    return null;
}

pub fn parseMode(str: []const u8) ?struct { w: i32, h: i32 } {
    var it = std.mem.splitScalar(u8, str, 'x');
    const ws = it.next() orelse return null;
    const hs = it.next() orelse return null;
    const w = std.fmt.parseInt(i32, ws, 10) catch return null;
    const h = std.fmt.parseInt(i32, hs, 10) catch return null;
    if (w <= 0 or h <= 0) return null;
    return .{ .w = w, .h = h };
}

test "settings-monitors-data: arrange + parse" {
    const t = std.testing;
    var ms = [_]MonitorRow{
        .{ .name = "DP-1", .w = 1920 },
        .{ .name = "HDMI-1", .w = 1280, .scale_pct = 200 },
    };
    arrangeRow(&ms);
    try t.expectEqual(@as(i32, 0), ms[0].x);
    try t.expectEqual(@as(i32, 1920), ms[1].x);
    try t.expectEqual(@as(i32, 1920 + 2560), totalWidth(&ms));
    try t.expectEqual(@as(usize, 0), primaryIndex(&ms).?);
    const m = parseMode("2560x1440").?;
    try t.expectEqual(@as(i32, 2560), m.w);
    try t.expect(parseMode("bad") == null);
}
