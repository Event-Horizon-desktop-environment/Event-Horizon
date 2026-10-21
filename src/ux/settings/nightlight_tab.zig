const std = @import("std");
const common = @import("common.zig");

// Nightlight + Notifications tabs — Zig port of
// settings_tab_nightlight/* and settings_tab_notifications/*.
// Same design: temp sliders + schedule combo; toast position combo +
// timeout slider + scale slider + test button.

pub const night_schedules = [_][]const u8{ "Manual", "Sunset to sunrise", "Scheduled" };

pub const NightlightModel = struct {
    enabled: bool = false,
    day_temp: i32 = 6500,
    night_temp: i32 = 4000,
    schedule: i32 = 0,
    start_min: i32 = 1200,
    end_min: i32 = 360,

    pub fn clampAll(self: *NightlightModel) void {
        self.day_temp = common.clampInt(self.day_temp, 2500, 7500);
        self.night_temp = common.clampInt(self.night_temp, 2500, 7500);
        if (self.schedule < 0 or self.schedule >= night_schedules.len) self.schedule = 0;
        self.start_min = common.clampInt(self.start_min, 0, 1439);
        self.end_min = common.clampInt(self.end_min, 0, 1439);
    }
};

pub const toast_positions = [_][]const u8{ "top_right", "top_left", "bottom_right", "bottom_left", "top_center" };

pub const NotificationsModel = struct {
    dbus_enabled: bool = true,
    dnd: bool = false,
    timeout_ms: i32 = 6000,
    toast_position: []const u8 = "top_right",
    scale_pct: i32 = 100,

    pub fn clampAll(self: *NotificationsModel) void {
        self.timeout_ms = common.clampInt(self.timeout_ms, 1000, 30000);
        self.scale_pct = common.clampInt(self.scale_pct, 50, 200);
    }

    pub fn positionIndex(self: *const NotificationsModel) usize {
        for (toast_positions, 0..) |p, i| {
            if (std.mem.eql(u8, p, self.toast_position)) return i;
        }
        return 0;
    }
};

pub fn formatClock(minutes: i32, buf: []u8) ![]u8 {
    const h: u32 = @intCast(@divTrunc(minutes, 60));
    const m: u32 = @intCast(@mod(minutes, 60));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ h, m });
}

test "settings-night-notif: clamp + position" {
    const t = std.testing;
    var n = NightlightModel{};
    n.clampAll();
    try t.expectEqual(@as(i32, 0), n.schedule);
    var nb = NotificationsModel{};
    try t.expectEqual(@as(usize, 0), nb.positionIndex());
    nb.toast_position = "bottom_left";
    try t.expectEqual(@as(usize, 3), nb.positionIndex());
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("20:00", try formatClock(1200, &buf));
}
