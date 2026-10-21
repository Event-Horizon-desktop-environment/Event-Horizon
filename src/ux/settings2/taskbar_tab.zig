const std = @import("std");
const common = @import("common.zig");

// Taskbar tab.
// Same design as dock tab: visibility + width-mode combo + thumbnail
// threshold combo + sliders (height/radius/opacity/icon/floating/gaps).

pub const width_modes = [_][]const u8{ "Floating", "Edge to edge", "Fill" };
pub const thumb_thresholds = [_]i32{ 5, 10, 15, 20 };

pub const Model = struct {
    enabled: bool = false,
    width_mode: i32 = 0,
    height: i32 = 48,
    radius: i32 = 12,
    opacity: i32 = 80,
    icon_size: i32 = 32,
    icon_spacing: i32 = 8,
    floating: i32 = 8,
    group_apps: bool = true,
    show_labels: bool = false,
    thumbnails: bool = true,
    thumb_threshold: i32 = 10,

    pub fn clampAll(self: *Model) void {
        if (self.width_mode < 0 or self.width_mode >= width_modes.len) self.width_mode = 0;
        self.height = common.clampInt(self.height, 24, 96);
        self.radius = common.clampInt(self.radius, 0, 32);
        self.opacity = common.clampInt(self.opacity, 0, 100);
        self.icon_size = common.clampInt(self.icon_size, 16, 64);
    }
};

pub fn widthModeLabel(idx: i32) []const u8 {
    if (idx < 0 or idx >= width_modes.len) return width_modes[0];
    return width_modes[@intCast(idx)];
}

test "settings-taskbar-tab: modes + clamp" {
    const t = std.testing;
    try t.expectEqualStrings("Floating", widthModeLabel(0));
    try t.expectEqualStrings("Floating", widthModeLabel(99));
    var m = Model{ .height = 999 };
    m.clampAll();
    try t.expectEqual(@as(i32, 96), m.height);
}
