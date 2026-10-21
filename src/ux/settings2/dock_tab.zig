const std = @import("std");
const common = @import("common.zig");

// Dock tab.
// Same design: visibility card (6 toggles + display row), renderer card,
// appearance sliders (radius/icon/spacing/gaps/opacity), border band.
// Layout mirrors card heights; input routes to toggles/sliders/combos.

pub const vis_rows_with_display: i32 = 7;
pub const vis_card_h: i32 = 52 + 32 * vis_rows_with_display + 24;
pub const renderer_card_h: i32 = 52 + 32 + 24;

pub const renderer_labels = [_][]const u8{ "Vulkan (GPU)", "Cairo (CPU, low memory)" };
pub const renderer_values = [_][]const u8{ "vulkan", "cairo" };

pub fn rendererIndex(value: []const u8) usize {
    for (renderer_values, 0..) |v, i| {
        if (std.mem.eql(u8, v, value)) return i;
    }
    return 0;
}

pub const Model = struct {
    show_dock: bool = true,
    auto_hide: bool = false,
    group_apps: bool = true,
    tooltips: bool = true,
    widgets_enabled: bool = true,
    radius: i32 = 18,
    icon_size: i32 = 44,
    icon_spacing: i32 = 15,
    bottom_gap: i32 = 6,
    opacity: i32 = 72,
    scale_pct: i32 = 100,

    pub fn clampAll(self: *Model) void {
        self.radius = common.clampInt(self.radius, 0, 32);
        self.icon_size = common.clampInt(self.icon_size, 16, 96);
        self.icon_spacing = common.clampInt(self.icon_spacing, 0, 48);
        self.bottom_gap = common.clampInt(self.bottom_gap, 0, 64);
        self.opacity = common.clampInt(self.opacity, 0, 100);
        self.scale_pct = common.clampInt(self.scale_pct, 50, 200);
    }
};

test "settings-dock-tab: layout + renderer + clamp" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 52 + 32 * 7 + 24), vis_card_h);
    try t.expectEqual(@as(usize, 0), rendererIndex("vulkan"));
    try t.expectEqual(@as(usize, 1), rendererIndex("cairo"));
    try t.expectEqual(@as(usize, 0), rendererIndex("bogus"));
    var m = Model{ .radius = 999, .opacity = -5 };
    m.clampAll();
    try t.expectEqual(@as(i32, 32), m.radius);
    try t.expectEqual(@as(i32, 0), m.opacity);
}
