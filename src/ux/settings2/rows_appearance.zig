const std = @import("std");
const rows = @import("rows.zig");
const fields = @import("fields.zig");

const Row = rows.Row;
const Card = rows.Card;
const Field = fields.Field;

// Appearance rail category — General (tab 2), Opacity (79), Color (80) and
// Templates (tab 3).
//
// Port of `settings_tab_appearance.cpp` onto the declarative card renderer:
// the General page is the "Appearance" top card (Wallpaper tint / Color
// engine toggles + the Color scheme and Theme mode combos), Opacity is the
// overlay-opacity tile grid, and Color is the "Color adjustment" tile grid.
// Templates is now a dedicated self-painted page (`templates_tab.zig`), so
// this module carries no list for tab 3. The overlay grid has two static
// lists — `opacity` holds the master slider plus the Advanced switch,
// `opacity_advanced` adds the per-surface sliders; `Content.cards` picks
// between them from `overlay_opacity_advanced`. The C++ in-page child-tab
// bar has no counterpart here: the pages read as this category's
// list-column rows, like every other rail category's subs.

pub const scheme_options = [_][]const u8{
    "scheme-content",
    "scheme-expressive",
    "scheme-fidelity",
    "scheme-fruit-salad",
    "scheme-monochrome",
    "scheme-neutral",
    "scheme-rainbow",
    "scheme-tonal-spot",
    "scheme-vibrant",
};

pub const scheme_labels = [_][]const u8{
    "Content",
    "Expressive",
    "Fidelity",
    "Fruit salad",
    "Monochrome",
    "Neutral",
    "Rainbow",
    "Tonal spot",
    "Vibrant",
};

pub const mode_options = [_][]const u8{ "dark", "light", "auto" };
pub const mode_labels = [_][]const u8{ "Dark", "Light", "Auto (dark)" };

const top_card = Card{
    .title = "Appearance",
    .subtitle = "System color and style settings",
    .rows = &[_]Row{
        .{ .toggle = .{ .label = "Wallpaper tint", .desc = "Generate Material You colors from wallpaper.", .field = .matugen_enabled } },
        .{ .toggle = .{ .label = "Color engine", .desc = "Use native C++ engine instead of external matugen.", .field = .horizon_native } },
        .{ .combo = .{ .label = "Color scheme", .desc = "Select the tonal palette for generated colors.", .field = .matugen_scheme, .options = &scheme_options, .labels = &scheme_labels } },
        .{ .combo = .{ .label = "Theme mode", .desc = "Dark, light, or automatic theme switching.", .field = .matugen_mode, .options = &mode_options, .labels = &mode_labels } },
    },
};

/// Overlay-opacity tiles in C++ order (idx 0 master, idx 1 the Advanced
/// switch, idx 2-15 the per-surface sliders). The basic grid shows only the
/// first two; the advanced grid all of them.
const overlay_master = Row{ .tile_slider = .{ .label = "Master opacity", .field = .overlay_opacity_master_pct, .min = 0, .max = 100, .unit = "%" } };
const overlay_advanced_switch = Row{ .tile_toggle = .{ .label = "Advanced", .field = .overlay_opacity_advanced, .style = .title_band } };

const overlay_surfaces = [_]Row{
    .{ .tile_slider = .{ .label = "Control center", .field = .overlay_opacity_control_center_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Control center tiles", .field = .overlay_opacity_control_center_inner_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "App drawer", .field = .overlay_opacity_app_drawer_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Launchpad", .field = .overlay_opacity_launchpad_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Settings", .field = .overlay_opacity_settings_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Settings sidebar", .field = .overlay_opacity_settings_sidebar_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Dock context menus", .field = .overlay_opacity_dock_menu_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Desktop context menus", .field = .overlay_opacity_desktop_menu_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Tray menus", .field = .overlay_opacity_tray_menu_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Calendar", .field = .overlay_opacity_calendar_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Weather", .field = .overlay_opacity_weather_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "World clock", .field = .overlay_opacity_world_clock_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Dock tooltip", .field = .overlay_opacity_tooltip_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Widget cards", .field = .overlay_opacity_widget_card_pct, .min = 0, .max = 100, .unit = "%" } },
    .{ .tile_slider = .{ .label = "Notifications", .field = .overlay_opacity_notifications_pct, .min = 0, .max = 100, .unit = "%" } },
};

const overlay_basic = [_]Row{
    overlay_master,
    overlay_advanced_switch,
};

const overlay_all = [_]Row{
    overlay_master,
    overlay_advanced_switch,
} ++ overlay_surfaces;

const color_adjust = Card{
    .title = "Color adjustment",
    .subtitle = "Tune brightness, contrast, vibrance and gamma.",
    .grid = true,
    .rows = &[_]Row{
        .{ .tile_slider = .{ .label = "Brightness", .desc = "Overall brightness.", .field = .color_brightness_pct, .min = 50, .max = 150, .unit = "%" } },
        .{ .tile_slider = .{ .label = "Contrast", .desc = "Contrast stretch.", .field = .color_contrast_pct, .min = 50, .max = 150, .unit = "%" } },
        .{ .tile_slider = .{ .label = "Vibrance", .desc = "Color saturation.", .field = .color_vibrance_pct, .min = 0, .max = 200, .unit = "%" } },
        .{ .tile_slider = .{ .label = "Gamma", .desc = "Midtone contrast curve.", .field = .color_gamma_pct, .min = 50, .max = 200, .unit = "%" } },
    },
};

/// General page: the appearance top card alone.
pub const general = [_]Card{top_card};

/// Opacity page as painted with the Advanced overlay switch off.
pub const opacity = [_]Card{
    .{ .grid = true, .rows = &overlay_basic },
};

/// Opacity page with the Advanced overlay switch on: every per-surface
/// opacity slider joins the master tile (C++ `maxIdx = 15`).
pub const opacity_advanced = [_]Card{
    .{ .grid = true, .rows = &overlay_all },
};

/// Color page: the color-adjustment tile grid.
pub const color = [_]Card{color_adjust};

test "settings-rows-appearance: overlays line up" {
    const t = std.testing;
    // General is the top card alone (4 rows, no grid tiles).
    try t.expectEqual(@as(usize, 1), general.len);
    try t.expectEqual(@as(usize, 4), general[0].rows.len);
    // Opacity basic: master + Advanced. Advanced: every slider (17 tiles).
    try t.expectEqual(@as(usize, 1), opacity.len);
    try t.expectEqual(@as(usize, 2), opacity[0].rows.len);
    try t.expectEqual(@as(usize, 17), opacity_advanced[0].rows.len);
    try t.expectEqualStrings("Master opacity", opacity[0].rows[0].tile_slider.label);
    try t.expectEqualStrings("Advanced", opacity[0].rows[1].tile_toggle.label);
    try t.expectEqual(Field.overlay_opacity_advanced, opacity[0].rows[1].tile_toggle.field);
    try t.expectEqualStrings("Notifications", opacity_advanced[0].rows[16].tile_slider.label);
    try t.expectEqual(Field.overlay_opacity_notifications_pct, opacity_advanced[0].rows[16].tile_slider.field);
    // The Advanced switch survives in the expanded grid, so the page can
    // always switch back to the basic one.
    try t.expectEqual(Field.overlay_opacity_advanced, opacity_advanced[0].rows[1].tile_toggle.field);
    // Per-surface tiles step through the C++ index order (idx 2..15 of
    // `overlay_title`); the World clock tile rides with its card siblings
    // right after Weather.
    try t.expectEqual(Field.overlay_opacity_control_center_pct, opacity_advanced[0].rows[2].tile_slider.field);
    try t.expectEqual(Field.overlay_opacity_launchpad_pct, opacity_advanced[0].rows[5].tile_slider.field);
    try t.expectEqual(Field.overlay_opacity_calendar_pct, opacity_advanced[0].rows[11].tile_slider.field);
    try t.expectEqual(Field.overlay_opacity_world_clock_pct, opacity_advanced[0].rows[13].tile_slider.field);
    // Color page: the 4 color tiles, same as the old trailing grid.
    try t.expectEqual(@as(usize, 1), color.len);
    try t.expectEqual(@as(usize, 4), color[0].rows.len);
    try t.expectEqualStrings("Color adjustment", color[0].title);
    try t.expectEqual(Field.color_brightness_pct, color[0].rows[0].tile_slider.field);
}
