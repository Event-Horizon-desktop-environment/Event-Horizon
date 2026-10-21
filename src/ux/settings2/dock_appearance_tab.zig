const std = @import("std");
const common = @import("common.zig");

// Dock appearance child tab.
// Same design as dock tab appearance card: glass/border sliders +
// slot-pill opacity + colored-glass toggle. Scrolls with the dock page.

pub const Model = struct {
    liquid_glass: bool = true,
    colored_glass: bool = false,
    icon_frames: bool = true,
    border_enabled: bool = false,
    border_size: i32 = 1,
    border_opacity: i32 = 100,
    slot_pill_opacity: i32 = 100,

    pub fn clampAll(self: *Model) void {
        self.border_size = common.clampInt(self.border_size, 1, 12);
        self.border_opacity = common.clampInt(self.border_opacity, 0, 100);
        self.slot_pill_opacity = common.clampInt(self.slot_pill_opacity, 0, 100);
    }
};

pub fn scrollMaxPx() i32 {
    // Mirrors dock_appearance_tab_scroll_max_px(): appearance card + border band.
    return 2 * common.slider_row_h + 3 * 64 + 48;
}

test "settings-dock-appearance: clamp + scroll" {
    const t = std.testing;
    var m = Model{ .border_size = 99 };
    m.clampAll();
    try t.expectEqual(@as(i32, 12), m.border_size);
    try t.expect(scrollMaxPx() > 0);
}
