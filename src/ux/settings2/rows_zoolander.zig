//! Zoolander settings sub-pages.
//!
//! One card list per Zoolander page, carrying the schema-driven setters the
//! settings app can edit in place. The card titles and groups follow the
//! Zoolander settings app: Keyboard, Mouse & Touchpad, Windows & Borders,
//! Effects, Animations, Decorations, Workspaces & Layouts and XWayland.
//!
//! Displays is not here: the live Monitors tab owns `output_rule` and the
//! global `set_presentation` keys (including the confirm/revert flow).

const std = @import("std");
const rows = @import("rows.zig");
const Field = rows.Field;
const Card = rows.Card;

/// --- Keyboard (`set_keyboard`) ---
pub const keyboard = [_]Card{
    .{ .title = "Keyboard", .subtitle = "Repeat rate and Num Lock", .rows = &.{
        .{ .toggle = .{ .label = "Num Lock on", .desc = "Enable Num Lock at startup", .field = Field.zool_keyboard_numlock } },
        .{ .slider = .{ .label = "Repeat rate", .field = Field.zool_keyboard_repeat_rate, .min = 0, .max = 1000, .unit = "Hz" } },
        .{ .slider = .{ .label = "Repeat delay", .field = Field.zool_keyboard_repeat_delay, .min = 0, .max = 5000, .unit = "ms" } },
    } },
    .{ .title = "Layout", .subtitle = "XKB rules, model, layout and variants", .rows = &.{
        .{ .text = .{ .label = "Layout", .desc = "XKB layout names, comma separated", .field = Field.zool_keyboard_layout, .placeholder = "us" } },
        .{ .text = .{ .label = "Variant", .desc = "XKB variant names parallel to the layout", .field = Field.zool_keyboard_variant, .placeholder = "" } },
        .{ .text = .{ .label = "Options", .desc = "XKB options, comma separated", .field = Field.zool_keyboard_options, .placeholder = "grp:alt_shift_toggle" } },
        .{ .text = .{ .label = "Model", .desc = "XKB keyboard model", .field = Field.zool_keyboard_model, .placeholder = "pc105" } },
        .{ .text = .{ .label = "Rules", .desc = "XKB rules file", .field = Field.zool_keyboard_rules, .placeholder = "evdev" } },
    } },
};

/// --- Mouse & Touchpad (`set_pointer`, `set_floating`) ---
pub const pointer = [_]Card{
    .{ .title = "Pointer", .subtitle = "Buttons, acceleration and focus", .rows = &.{
        .{ .toggle = .{ .label = "Left-handed", .desc = "Swap the primary and secondary buttons", .field = Field.zool_pointer_left_handed } },
        .{ .combo = .{ .label = "Acceleration", .field = Field.zool_pointer_accel_profile, .options = &.{ "adaptive", "flat" }, .labels = &.{ "Adaptive", "Flat" } } },
        .{ .slider = .{ .label = "Sensitivity", .field = Field.zool_pointer_sensitivity, .min = -100, .max = 100, .unit = "" } },
        .{ .combo = .{ .label = "Focus follows mouse", .field = Field.zool_pointer_follow_mouse, .options = &.{ "disabled", "focus", "click", "detached" }, .labels = &.{ "Disabled", "Focus", "Click", "Detached" } } },
    } },
    .{ .title = "Floating Windows", .subtitle = "Raising floating windows on hover", .rows = &.{
        .{ .toggle = .{ .label = "Raise on hover", .desc = "Raise a floating window when the pointer enters", .field = Field.zool_floating_raise_on_hover } },
        .{ .slider = .{ .label = "Raise delay", .field = Field.zool_floating_raise_delay, .min = 0, .max = 2000, .unit = "ms" } },
    } },
};

/// --- Windows & Borders (`set_window_style`) ---
pub const windows = [_]Card{
    .{ .title = "Gaps", .subtitle = "Spacing between windows and outputs", .rows = &.{
        .{ .slider = .{ .label = "Inner gaps", .field = Field.zool_window_style_gaps_in, .min = 0, .max = 256, .unit = "px" } },
        .{ .slider = .{ .label = "Outer gaps", .field = Field.zool_window_style_gaps_out, .min = 0, .max = 256, .unit = "px" } },
    } },
    .{ .title = "Borders", .subtitle = "Window border width", .rows = &.{
        .{ .slider = .{ .label = "Border width", .field = Field.zool_window_style_border_size, .min = 0, .max = 64, .unit = "px" } },
    } },
    .{ .title = "Border colours", .subtitle = "#RRGGBBAA gradients, angles in degrees", .rows = &.{
        .{ .text = .{ .label = "Active border", .desc = "Start colour of the focused border", .field = Field.zool_window_style_active_border, .placeholder = "#598cf2ff" } },
        .{ .text = .{ .label = "Active border end", .desc = "End colour of the focused border", .field = Field.zool_window_style_active_border_end, .placeholder = "#598cf2ff" } },
        .{ .slider = .{ .label = "Active border angle", .field = Field.zool_window_style_active_border_angle, .min = -3600, .max = 3600, .unit = "°" } },
        .{ .text = .{ .label = "Inactive border", .desc = "Start colour of the unfocused border", .field = Field.zool_window_style_inactive_border, .placeholder = "#40404dff" } },
        .{ .text = .{ .label = "Inactive border end", .desc = "End colour of the unfocused border", .field = Field.zool_window_style_inactive_border_end, .placeholder = "#40404dff" } },
        .{ .slider = .{ .label = "Inactive border angle", .field = Field.zool_window_style_inactive_border_angle, .min = -3600, .max = 3600, .unit = "°" } },
    } },
    .{ .title = "Corners", .subtitle = "Rounded corners", .rows = &.{
        .{ .slider = .{ .label = "Corner radius", .field = Field.zool_window_style_rounding, .min = 0, .max = 128, .unit = "px" } },
        .{ .slider = .{ .label = "Corner shape", .field = Field.zool_window_style_rounding_power, .min = 20, .max = 100, .unit = "×" } },
    } },
    .{ .title = "Shadow", .subtitle = "Drop shadow under windows", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Draw a shadow under windows", .field = Field.zool_window_style_shadow_enabled } },
        .{ .slider = .{ .label = "Range", .field = Field.zool_window_style_shadow_range, .min = 0, .max = 256, .unit = "px" } },
        .{ .slider = .{ .label = "Sharpness", .field = Field.zool_window_style_shadow_sharp, .min = 0, .max = 100, .unit = "%" } },
        .{ .slider = .{ .label = "Falloff", .field = Field.zool_window_style_shadow_render_power, .min = 10, .max = 80, .unit = "×" } },
        .{ .slider = .{ .label = "Offset X", .field = Field.zool_window_style_shadow_offset_x, .min = -256, .max = 256, .unit = "px" } },
        .{ .slider = .{ .label = "Offset Y", .field = Field.zool_window_style_shadow_offset_y, .min = -256, .max = 256, .unit = "px" } },
        .{ .slider = .{ .label = "Scale", .field = Field.zool_window_style_shadow_scale, .min = 50, .max = 200, .unit = "×" } },
        .{ .text = .{ .label = "Colour", .field = Field.zool_window_style_shadow_color, .placeholder = "#00000066" } },
        .{ .text = .{ .label = "Inactive colour", .field = Field.zool_window_style_shadow_color_inactive, .placeholder = "#00000066" } },
    } },
    .{ .title = "Opacity", .subtitle = "Window transparency", .rows = &.{
        .{ .slider = .{ .label = "Active opacity", .field = Field.zool_window_style_active_opacity, .min = 0, .max = 100, .unit = "%" } },
        .{ .slider = .{ .label = "Inactive opacity", .field = Field.zool_window_style_inactive_opacity, .min = 0, .max = 100, .unit = "%" } },
        .{ .slider = .{ .label = "Fullscreen opacity", .field = Field.zool_window_style_fullscreen_opacity, .min = 0, .max = 100, .unit = "%" } },
    } },
};

/// --- Effects (`set_blur`, `set_dim`) ---
pub const effects = [_]Card{
    .{ .title = "Blur", .subtitle = "Window and popup blur", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Blur behind windows", .field = Field.zool_blur_enabled } },
        .{ .toggle = .{ .label = "Ignore opacity", .desc = "Blur fully transparent windows too", .field = Field.zool_blur_ignore_opacity } },
        .{ .toggle = .{ .label = "Popups", .desc = "Blur layer-shell popups", .field = Field.zool_blur_popups } },
        .{ .slider = .{ .label = "Popup alpha threshold", .field = Field.zool_blur_popups_ignorealpha, .min = 0, .max = 100, .unit = "%" } },
        .{ .toggle = .{ .label = "Input method popups", .desc = "Blur input method windows", .field = Field.zool_blur_input_methods } },
        .{ .slider = .{ .label = "Input method alpha threshold", .field = Field.zool_blur_input_methods_ignorealpha, .min = 0, .max = 100, .unit = "%" } },
        .{ .slider = .{ .label = "Radius", .field = Field.zool_blur_size, .min = 1, .max = 40, .unit = "px" } },
        .{ .slider = .{ .label = "Passes", .field = Field.zool_blur_passes, .min = 1, .max = 8, .unit = "" } },
        .{ .combo = .{ .label = "Resolution", .field = Field.zool_blur_resolution, .options = &.{ "full", "half", "quarter" }, .labels = &.{ "Full", "Half", "Quarter" } } },
    } },
    .{ .title = "Blur Colour", .subtitle = "Noise, contrast and vibrancy", .rows = &.{
        .{ .slider = .{ .label = "Noise", .field = Field.zool_blur_noise, .min = 0, .max = 1000, .unit = "" } },
        .{ .slider = .{ .label = "Contrast", .field = Field.zool_blur_contrast, .min = 0, .max = 200, .unit = "%" } },
        .{ .slider = .{ .label = "Brightness", .field = Field.zool_blur_brightness, .min = 0, .max = 200, .unit = "%" } },
        .{ .slider = .{ .label = "Vibrancy", .field = Field.zool_blur_vibrancy, .min = 0, .max = 100, .unit = "%" } },
        .{ .slider = .{ .label = "Vibrancy darkness", .field = Field.zool_blur_vibrancy_darkness, .min = 0, .max = 100, .unit = "%" } },
    } },
    .{ .title = "Dimming", .subtitle = "Dim unfocused and special windows", .rows = &.{
        .{ .toggle = .{ .label = "Dim unfocused windows", .desc = "Darken windows that do not have focus", .field = Field.zool_dim_inactive } },
        .{ .slider = .{ .label = "Strength", .field = Field.zool_dim_strength, .min = 0, .max = 100, .unit = "%" } },
        .{ .slider = .{ .label = "Behind special workspaces", .field = Field.zool_dim_special, .min = 0, .max = 100, .unit = "%" } },
        .{ .slider = .{ .label = "Around dialogs", .field = Field.zool_dim_around, .min = 0, .max = 100, .unit = "%" } },
    } },
};

/// --- Animations (`set_animations`) ---
pub const animations = [_]Card{
    .{ .title = "Animations", .subtitle = "Default motion for windows and layers", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Animate windows, layers and workspaces", .field = Field.zool_animations_enabled } },
        .{ .toggle = .{ .label = "All animations on", .desc = "Master switch for every animation", .field = Field.zool_animations_all_enabled } },
        .{ .toggle = .{ .label = "Reduced motion", .desc = "Spatial travel and zoom happen at once", .field = Field.zool_reduced_motion } },
        .{ .slider = .{ .label = "Duration", .field = Field.zool_animations_duration, .min = 1, .max = 5000, .unit = "ms" } },
        .{ .combo = .{ .label = "Easing", .field = Field.zool_animations_easing, .options = &.{ "linear", "ease_out_cubic", "ease_in_out_cubic" }, .labels = &.{ "Linear", "Ease out", "Ease in-out" } } },
    } },
};

/// --- Decorations (`set_ssd`, `set_tab_bar`) ---
pub const decorations = [_]Card{
    .{ .title = "Title Bars", .subtitle = "Server-side decorations", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Draw title bars for windows", .field = Field.zool_ssd_enabled } },
        .{ .toggle = .{ .label = "Floating workspaces only", .desc = "Decorate only windows on floating workspaces", .field = Field.zool_ssd_floating_workspaces_only } },
        .{ .toggle = .{ .label = "Floating windows too", .desc = "Decorate floating windows as well", .field = Field.zool_ssd_include_floating_windows } },
        .{ .toggle = .{ .label = "Follow theme", .desc = "Use the current colour theme", .field = Field.zool_ssd_follow_theme } },
        .{ .toggle = .{ .label = "Show title", .desc = "Show the window title", .field = Field.zool_ssd_show_title } },
    } },
    .{ .title = "Title Bar Metrics", .subtitle = "Size, alignment and border", .rows = &.{
        .{ .slider = .{ .label = "Border width", .field = Field.zool_ssd_border, .min = 0, .max = 64, .unit = "px" } },
        .{ .slider = .{ .label = "Title bar height", .field = Field.zool_ssd_titlebar, .min = 0, .max = 128, .unit = "px" } },
        .{ .slider = .{ .label = "Title size", .field = Field.zool_ssd_title_font_size, .min = 1, .max = 128, .unit = "px" } },
        .{ .combo = .{ .label = "Title alignment", .field = Field.zool_ssd_title_align, .options = &.{ "left", "center", "right" }, .labels = &.{ "Left", "Centre", "Right" } } },
    } },
    .{ .title = "Title bar colours", .subtitle = "Borders, title bars and title text (#RRGGBBAA)", .rows = &.{
        .{ .text = .{ .label = "Active border", .field = Field.zool_ssd_active_border, .placeholder = "#598cf2ff" } },
        .{ .text = .{ .label = "Active border end", .field = Field.zool_ssd_active_border_end, .placeholder = "#598cf2ff" } },
        .{ .slider = .{ .label = "Active border angle", .field = Field.zool_ssd_active_border_angle, .min = -3600, .max = 3600, .unit = "°" } },
        .{ .text = .{ .label = "Inactive border", .field = Field.zool_ssd_inactive_border, .placeholder = "#40404dff" } },
        .{ .text = .{ .label = "Inactive border end", .field = Field.zool_ssd_inactive_border_end, .placeholder = "#40404dff" } },
        .{ .slider = .{ .label = "Inactive border angle", .field = Field.zool_ssd_inactive_border_angle, .min = -3600, .max = 3600, .unit = "°" } },
        .{ .text = .{ .label = "Active title bar", .field = Field.zool_ssd_active_titlebar, .placeholder = "#292e3dff" } },
        .{ .text = .{ .label = "Inactive title bar", .field = Field.zool_ssd_inactive_titlebar, .placeholder = "#1a1a21ff" } },
        .{ .text = .{ .label = "Title colour", .field = Field.zool_ssd_title_color, .placeholder = "#ebf0faff" } },
        .{ .text = .{ .label = "Inactive title colour", .field = Field.zool_ssd_inactive_title_color, .placeholder = "#ebf0faff" } },
        .{ .text = .{ .label = "Title font", .desc = "Font family for window titles", .field = Field.zool_ssd_title_font, .placeholder = "Sans" } },
    } },
    .{ .title = "Tab Bars", .subtitle = "The window tab bar", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Show a tab bar over grouped windows", .field = Field.zool_tab_bar_enabled } },
        .{ .slider = .{ .label = "Height", .field = Field.zool_tab_bar_height, .min = 8, .max = 96, .unit = "px" } },
        .{ .slider = .{ .label = "Corner radius", .field = Field.zool_tab_bar_radius, .min = 0, .max = 48, .unit = "px" } },
        .{ .slider = .{ .label = "Gap", .field = Field.zool_tab_bar_gap, .min = 0, .max = 32, .unit = "px" } },
        .{ .slider = .{ .label = "Title inset", .field = Field.zool_tab_bar_padding_x, .min = 0, .max = 64, .unit = "px" } },
        .{ .slider = .{ .label = "Title size", .field = Field.zool_tab_bar_size, .min = 6, .max = 64, .unit = "px" } },
        .{ .toggle = .{ .label = "One bar in Monocle", .desc = "Use a single tab bar when the layout is monocle", .field = Field.zool_tab_bar_monocle_all } },
    } },
    .{ .title = "Tab Bar Theme", .subtitle = "Font and colours (#RRGGBBAA)", .rows = &.{
        .{ .text = .{ .label = "Font", .desc = "Font family for tab titles", .field = Field.zool_tab_bar_font, .placeholder = "Sans" } },
        .{ .text = .{ .label = "Background", .field = Field.zool_tab_bar_bg, .placeholder = "#1a1a21ff" } },
        .{ .text = .{ .label = "Foreground", .field = Field.zool_tab_bar_fg, .placeholder = "#ebf0faff" } },
        .{ .text = .{ .label = "Focused background", .field = Field.zool_tab_bar_focus_bg, .placeholder = "#292e3dff" } },
        .{ .text = .{ .label = "Focused foreground", .field = Field.zool_tab_bar_focus_fg, .placeholder = "#ebf0faff" } },
    } },
};

/// --- Workspaces & Layouts (`set_layout`, `set_dwindle`, `set_spatial`, `set_scrolling`, `set_overview`) ---
pub const layouts = [_]Card{
    .{ .title = "Default layout", .subtitle = "The arrangement workspaces without a rule use", .rows = &.{
        .{ .combo = .{
            .label = "Layout",
            .desc = "Built-in arrangement for workspaces without their own layout",
            .field = Field.zool_layout_default,
            .options = &.{ "dwindle", "master_stack", "grid", "monocle", "spiral", "scrolling", "floating", "canvas", "shelves", "islands", "lanes", "accordion", "workbench", "pairs", "anchors" },
            .labels = &.{ "Dwindle", "Master", "Grid", "Monocle", "Spiral", "Scrolling", "Floating", "Canvas", "Side Shelves", "Islands", "Lanes", "Accordion", "Workbench", "Pairs", "Anchors" },
        } },
    } },
    .{ .title = "Dwindle", .subtitle = "Split direction and resizing", .rows = &.{
        .{ .toggle = .{ .label = "Preserve split", .desc = "Keep the split direction when reopening", .field = Field.zool_dwindle_preserve_split } },
        .{ .toggle = .{ .label = "Smart split", .desc = "Split towards the larger half", .field = Field.zool_dwindle_smart_split } },
        .{ .toggle = .{ .label = "Smart resizing", .desc = "Resize the neighbouring window when splitting", .field = Field.zool_dwindle_smart_resizing } },
        .{ .slider = .{ .label = "Force split", .field = Field.zool_dwindle_force_split, .min = 0, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "Split width bias", .field = Field.zool_dwindle_split_width_multiplier, .min = 1, .max = 40, .unit = "×" } },
    } },
    .{ .title = "Spatial Layouts", .subtitle = "Floating canvas, shelves and snapping", .rows = &.{
        .{ .slider = .{ .label = "Fallback width", .field = Field.zool_spatial_fallback_width, .min = 200, .max = 1000, .unit = "" } },
        .{ .slider = .{ .label = "Fallback height", .field = Field.zool_spatial_fallback_height, .min = 200, .max = 1000, .unit = "" } },
        .{ .slider = .{ .label = "Width cap", .field = Field.zool_spatial_width_cap, .min = 0, .max = 16384, .unit = "px" } },
        .{ .slider = .{ .label = "Shelf width", .field = Field.zool_spatial_shelf_width, .min = 0, .max = 1200, .unit = "px" } },
        .{ .combo = .{ .label = "Shelves", .field = Field.zool_spatial_shelf_mode, .options = &.{ "auto", "persistent", "drawer" }, .labels = &.{ "Automatic", "Persistent", "Drawer" } } },
        .{ .slider = .{ .label = "Edge snapping", .field = Field.zool_spatial_snap, .min = 0, .max = 64, .unit = "px" } },
        .{ .slider = .{ .label = "Reveal margin", .field = Field.zool_spatial_reveal_margin, .min = 0, .max = 200, .unit = "px" } },
        .{ .slider = .{ .label = "Pan fingers", .field = Field.zool_spatial_pan_fingers, .min = 0, .max = 5, .unit = "" } },
    } },
    .{ .title = "Scrolling", .subtitle = "Column widths cycled by the scrolling layout", .rows = &.{
        .{ .text = .{ .label = "Column width presets", .desc = "Screen shares, comma separated, rising", .field = Field.zool_scrolling_width_presets, .placeholder = "0.333, 0.667, 1" } },
    } },
    .{ .title = "Overview", .subtitle = "Workspace overview direction and size", .rows = &.{
        .{ .combo = .{ .label = "Axis", .field = Field.zool_overview_axis, .options = &.{ "vertical", "horizontal" }, .labels = &.{ "Vertical", "Horizontal" } } },
        .{ .combo = .{ .label = "Rail", .field = Field.zool_overview_rail, .options = &.{ "bottom", "top" }, .labels = &.{ "Bottom", "Top" } } },
        .{ .slider = .{ .label = "Size", .field = Field.zool_overview_scale, .min = 20, .max = 125, .unit = "%" } },
    } },
};

/// --- XWayland (`set_xwayland`) ---
pub const xwayland = [_]Card{
    .{ .title = "XWayland", .subtitle = "The X11 compatibility server", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Start XWayland with the session", .field = Field.zool_xwayland_enabled } },
        .{ .toggle = .{ .label = "Unscaled X11", .desc = "Force zero scaling for X11 clients", .field = Field.zool_xwayland_force_zero_scaling } },
    } },
};

test "zoolander-rows: every page has cards" {
    const t = std.testing;
    const page = @import("zoolander_page.zig");
    const sets = [_][]const Card{
        &keyboard,   &pointer,     &windows, &effects,
        &animations, &decorations, &layouts, &xwayland,
    };
    try t.expectEqual(page.sections.len, sets.len);
    for (sets) |cards| try t.expect(cards.len > 0);
}
