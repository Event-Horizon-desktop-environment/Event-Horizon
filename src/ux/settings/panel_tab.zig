const std = @import("std");
const common = @import("common.zig");

// Panel tab — Zig port of src/ux/settings/settings_tab_panel/*.
// Same design as taskbar tab with panel-specific fields: width mode
// (floating/edge-to-edge/fill), reserve-space, overlay layer, capsule.

pub const width_modes = [_][]const u8{ "Floating", "Edge to edge", "Fill" };

pub const Model = struct {
    enabled: bool = false,
    width_mode: i32 = 1,
    height: i32 = 34,
    radius: i32 = 14,
    opacity: i32 = 96,
    icon_size: i32 = 22,
    icon_spacing: i32 = 8,
    floating_amount: i32 = 8,
    edge_gap: i32 = 0,
    exclusive_zone_gap: i32 = 0,
    position_top: bool = true,
    auto_hide: bool = false,
    reserve_space: bool = true,
    overlay_layer: bool = false,
    hover_highlight: bool = true,
    smart_auto_hide: bool = false,
    reveal_on_switch: bool = true,
    scroll_volume: bool = true,
    capsule: bool = true,
    capsule_opacity: i32 = 100,
    corner_tl: i32 = 14,
    corner_tr: i32 = 14,
    corner_bl: i32 = 14,
    corner_br: i32 = 14,
    border_size: i32 = 1,

    pub fn clampAll(self: *Model) void {
        if (self.width_mode < 0 or self.width_mode >= width_modes.len) self.width_mode = 1;
        self.height = common.clampInt(self.height, 20, 120);
        self.radius = common.clampInt(self.radius, 0, 50);
        self.opacity = common.clampInt(self.opacity, 0, 100);
        self.icon_size = common.clampInt(self.icon_size, 8, 96);
        self.icon_spacing = common.clampInt(self.icon_spacing, 0, 50);
        self.floating_amount = common.clampInt(self.floating_amount, 0, 50);
        self.edge_gap = common.clampInt(self.edge_gap, 0, 25);
        self.exclusive_zone_gap = common.clampInt(self.exclusive_zone_gap, 0, 100);
        self.capsule_opacity = common.clampInt(self.capsule_opacity, 0, 100);
        self.corner_tl = common.clampInt(self.corner_tl, 0, 50);
        self.corner_tr = common.clampInt(self.corner_tr, 0, 50);
        self.corner_bl = common.clampInt(self.corner_bl, 0, 50);
        self.corner_br = common.clampInt(self.corner_br, 0, 50);
        self.border_size = common.clampInt(self.border_size, 1, 12);
    }
};

test "settings-panel-tab: clamp" {
    const t = std.testing;
    var m = Model{ .width_mode = 9, .height = 5 };
    m.clampAll();
    try t.expectEqual(@as(i32, 1), m.width_mode);
    try t.expectEqual(@as(i32, 20), m.height);
}
