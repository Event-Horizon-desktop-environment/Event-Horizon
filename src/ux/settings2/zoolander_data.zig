//! Zoolander config data layer: typed model, loader, and writer for the
//! Lua setters in `~/.config/zoolander/*.lua`.
//!
//! Zoolander's config is LuaJIT code, not a key/value file. The settings app
//! exposes the schema-driven setters that take a table (`zl.set_window_style
//! { ... }` and friends); this layer locates the last call of a setter, reads
//! the literal at a dotted path out of its table, and rewrites only that
//! literal. Comments, surrounding calls and computed values stay as written.
//! A setter that is missing from the config gets a fresh call appended to
//! `init.lua`, so a stock config can still be edited from the settings app.
//!
//! The table parser is deliberately small: it understands the literal shapes
//! Zoolander's schema uses (booleans, numbers, quoted strings, nested tables)
//! and skips Lua comments and long strings. Values computed by code are left
//! alone; the app never tries to evaluate Lua.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("../../sock.zig");
const logz = @import("../../logz.zig");

pub const Kind = enum { boolean, integer, number, text, flag, list };

pub const Meta = struct {
    setter: []const u8,
    /// Dotted path inside the setter's table (`shadow.enabled`).
    key: []const u8,
    kind: Kind,
    bool_default: bool = false,
    int_default: i32 = 0,
    num_default: f64 = 0,
    text_default: []const u8 = "",
    /// UI integer = round(value * scale). Floats use 10/100/1000 so the
    /// integer slider keeps their hundredths without a new row type.
    scale: i32 = 1,
    /// The literal is one of the setter's positional arguments
    /// (`zl.set_layout("scrolling", 0.6, 2, "vertical")`) rather than a
    /// table key.
    positional: bool = false,
    /// Which positional argument `positional` addresses (0 = first).
    arg_index: u8 = 0,
    /// For setters whose first argument names a record and whose second is a
    /// table (`set_animation_leaf("fade", { ... })`), the record name this
    /// entry belongs to. Empty for every other setter.
    leaf: []const u8 = "",
    /// Index of the animation leaf within the leaf table (0..8), used to
    /// track per-leaf curve state and one-shot rewrites.
    lnum: u8 = 0,
};

/// One entry per `Field.zool_*` variant, in the same order.
pub const k_meta = [_]Meta{
    // -- Displays / set_presentation --
    .{ .setter = "set_presentation", .key = "allow_tearing", .kind = .boolean },
    .{ .setter = "set_presentation", .key = "immediate_fullscreen", .kind = .boolean },
    .{ .setter = "set_presentation", .key = "direct_scanout", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_presentation", .key = "partial_damage", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_presentation", .key = "vrr", .kind = .text, .text_default = "off" },
    .{ .setter = "set_presentation", .key = "hdr", .kind = .text, .text_default = "auto" },
    .{ .setter = "set_presentation", .key = "sdr_brightness", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_presentation", .key = "sdr_saturation", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_presentation", .key = "sdr_min_luminance", .kind = .number, .num_default = 0, .scale = 1000 },
    .{ .setter = "set_presentation", .key = "sdr_max_luminance", .kind = .number, .num_default = 100, .scale = 1 },
    .{ .setter = "set_presentation", .key = "sdr_eotf", .kind = .text, .text_default = "gamma24" },

    // -- Keyboard --
    .{ .setter = "set_keyboard", .key = "repeat_rate", .kind = .integer, .int_default = 25 },
    .{ .setter = "set_keyboard", .key = "repeat_delay", .kind = .integer, .int_default = 600 },
    .{ .setter = "set_keyboard", .key = "numlock", .kind = .boolean },

    // -- Pointer --
    .{ .setter = "set_pointer", .key = "left_handed", .kind = .boolean },
    .{ .setter = "set_pointer", .key = "accel_profile", .kind = .text, .text_default = "adaptive" },
    .{ .setter = "set_pointer", .key = "sensitivity", .kind = .number, .num_default = 0, .scale = 100 },
    .{ .setter = "set_pointer", .key = "follow_mouse", .kind = .text, .text_default = "focus" },

    // -- Floating windows --
    .{ .setter = "set_floating", .key = "raise_on_hover", .kind = .boolean },
    .{ .setter = "set_floating", .key = "raise_delay", .kind = .integer, .int_default = 100 },

    // -- Windows / set_window_style --
    .{ .setter = "set_window_style", .key = "gaps_in", .kind = .integer },
    .{ .setter = "set_window_style", .key = "gaps_out", .kind = .integer },
    .{ .setter = "set_window_style", .key = "border_size", .kind = .integer, .int_default = 2 },
    .{ .setter = "set_window_style", .key = "rounding", .kind = .integer },
    .{ .setter = "set_window_style", .key = "rounding_power", .kind = .number, .num_default = 2, .scale = 10 },
    .{ .setter = "set_window_style", .key = "active_opacity", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_window_style", .key = "inactive_opacity", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_window_style", .key = "fullscreen_opacity", .kind = .number, .num_default = 1, .scale = 100 },

    // -- Decorations / set_ssd --
    .{ .setter = "set_ssd", .key = "enabled", .kind = .boolean },
    .{ .setter = "set_ssd", .key = "floating_workspaces_only", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_ssd", .key = "include_floating_windows", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_ssd", .key = "follow_theme", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_ssd", .key = "show_title", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_ssd", .key = "border", .kind = .integer, .int_default = 2 },
    .{ .setter = "set_ssd", .key = "titlebar", .kind = .integer, .int_default = 22 },
    .{ .setter = "set_ssd", .key = "title_font_size", .kind = .integer, .int_default = 13 },
    .{ .setter = "set_ssd", .key = "title_align", .kind = .text, .text_default = "center" },

    // -- Blur --
    .{ .setter = "set_blur", .key = "enabled", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_blur", .key = "ignore_opacity", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_blur", .key = "popups", .kind = .boolean },
    .{ .setter = "set_blur", .key = "popups_ignorealpha", .kind = .number, .num_default = 0.2, .scale = 100 },
    .{ .setter = "set_blur", .key = "input_methods", .kind = .boolean },
    .{ .setter = "set_blur", .key = "input_methods_ignorealpha", .kind = .number, .num_default = 0.2, .scale = 100 },
    .{ .setter = "set_blur", .key = "size", .kind = .integer, .int_default = 8 },
    .{ .setter = "set_blur", .key = "passes", .kind = .integer, .int_default = 1 },
    .{ .setter = "set_blur", .key = "resolution", .kind = .text, .text_default = "quarter" },
    .{ .setter = "set_blur", .key = "noise", .kind = .number, .num_default = 0.0117, .scale = 1000 },
    .{ .setter = "set_blur", .key = "contrast", .kind = .number, .num_default = 0.8916, .scale = 100 },
    .{ .setter = "set_blur", .key = "brightness", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_blur", .key = "vibrancy", .kind = .number, .num_default = 0.1696, .scale = 100 },
    .{ .setter = "set_blur", .key = "vibrancy_darkness", .kind = .number, .num_default = 0, .scale = 100 },

    // -- Dimming --
    .{ .setter = "set_dim", .key = "inactive", .kind = .boolean },
    .{ .setter = "set_dim", .key = "strength", .kind = .number, .num_default = 0.5, .scale = 100 },
    .{ .setter = "set_dim", .key = "special", .kind = .number, .num_default = 0.2, .scale = 100 },
    .{ .setter = "set_dim", .key = "around", .kind = .number, .num_default = 0, .scale = 100 },

    // -- Tab bar --
    .{ .setter = "set_tab_bar", .key = "enabled", .kind = .boolean },
    .{ .setter = "set_tab_bar", .key = "height", .kind = .integer, .int_default = 30 },
    .{ .setter = "set_tab_bar", .key = "radius", .kind = .integer, .int_default = 8 },
    .{ .setter = "set_tab_bar", .key = "gap", .kind = .integer, .int_default = 3 },
    .{ .setter = "set_tab_bar", .key = "padding_x", .kind = .integer, .int_default = 12 },
    .{ .setter = "set_tab_bar", .key = "size", .kind = .integer, .int_default = 13 },
    .{ .setter = "set_tab_bar", .key = "monocle_all", .kind = .boolean, .bool_default = true },

    // -- Animations --
    .{ .setter = "set_animations", .key = "enabled", .kind = .boolean },
    .{ .setter = "set_animations", .key = "duration", .kind = .integer, .int_default = 180 },
    .{ .setter = "set_animations", .key = "easing", .kind = .text, .text_default = "ease_out_cubic" },

    // -- Default layout (`set_layout`) --
    // `zl.set_layout(layout, ratio?, master_count?, axis?)`; each argument
    // is its own field so the layout card can edit them independently and
    // preserve the trailing ones.
    .{ .setter = "set_layout", .key = "layout", .kind = .text, .text_default = "master_stack", .positional = true },
    .{ .setter = "set_layout", .key = "ratio", .kind = .number, .num_default = 0.6, .scale = 1000, .positional = true, .arg_index = 1 },
    .{ .setter = "set_layout", .key = "master_count", .kind = .integer, .int_default = 1, .positional = true, .arg_index = 2 },
    .{ .setter = "set_layout", .key = "axis", .kind = .text, .text_default = "auto", .positional = true, .arg_index = 3 },

    // -- Dwindle --
    .{ .setter = "set_dwindle", .key = "preserve_split", .kind = .boolean },
    .{ .setter = "set_dwindle", .key = "smart_split", .kind = .boolean },
    .{ .setter = "set_dwindle", .key = "smart_resizing", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_dwindle", .key = "force_split", .kind = .integer },
    .{ .setter = "set_dwindle", .key = "split_width_multiplier", .kind = .number, .num_default = 1, .scale = 10 },

    // -- Spatial layouts --
    .{ .setter = "set_spatial", .key = "fallback_width", .kind = .number, .num_default = 0.667, .scale = 1000 },
    .{ .setter = "set_spatial", .key = "fallback_height", .kind = .number, .num_default = 0.75, .scale = 1000 },
    .{ .setter = "set_spatial", .key = "width_cap", .kind = .integer, .int_default = 1440 },
    .{ .setter = "set_spatial", .key = "shelf_width", .kind = .integer },
    .{ .setter = "set_spatial", .key = "shelf_mode", .kind = .text, .text_default = "auto" },
    .{ .setter = "set_spatial", .key = "snap", .kind = .integer, .int_default = 12 },
    .{ .setter = "set_spatial", .key = "reveal_margin", .kind = .integer, .int_default = 24 },
    .{ .setter = "set_spatial", .key = "pan_fingers", .kind = .integer, .int_default = 3 },

    // -- Overview --
    .{ .setter = "set_overview", .key = "axis", .kind = .text, .text_default = "vertical" },
    .{ .setter = "set_overview", .key = "rail", .kind = .text, .text_default = "bottom" },
    .{ .setter = "set_overview", .key = "scale", .kind = .number, .num_default = 1, .scale = 100 },

    // -- XWayland --
    .{ .setter = "set_xwayland", .key = "enabled", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_xwayland", .key = "force_zero_scaling", .kind = .boolean },

    // -- Keyboard XKB layout (`set_keyboard`) --
    .{ .setter = "set_keyboard", .key = "layout", .kind = .text },
    .{ .setter = "set_keyboard", .key = "variant", .kind = .text },
    .{ .setter = "set_keyboard", .key = "options", .kind = .text },
    .{ .setter = "set_keyboard", .key = "model", .kind = .text },
    .{ .setter = "set_keyboard", .key = "rules", .kind = .text },

    // -- Window borders (`set_window_style`) --
    .{ .setter = "set_window_style", .key = "active_border", .kind = .text, .text_default = "#598cf2ff" },
    .{ .setter = "set_window_style", .key = "active_border_end", .kind = .text, .text_default = "#598cf2ff" },
    .{ .setter = "set_window_style", .key = "active_border_angle", .kind = .number, .num_default = 0, .scale = 10 },
    .{ .setter = "set_window_style", .key = "inactive_border", .kind = .text, .text_default = "#40404dff" },
    .{ .setter = "set_window_style", .key = "inactive_border_end", .kind = .text, .text_default = "#40404dff" },
    .{ .setter = "set_window_style", .key = "inactive_border_angle", .kind = .number, .num_default = 0, .scale = 10 },

    // -- Server-side decoration colours (`set_ssd`) --
    .{ .setter = "set_ssd", .key = "active_border", .kind = .text, .text_default = "#598cf2ff" },
    .{ .setter = "set_ssd", .key = "active_border_end", .kind = .text, .text_default = "#598cf2ff" },
    .{ .setter = "set_ssd", .key = "active_border_angle", .kind = .number, .num_default = 0, .scale = 10 },
    .{ .setter = "set_ssd", .key = "inactive_border", .kind = .text, .text_default = "#40404dff" },
    .{ .setter = "set_ssd", .key = "inactive_border_end", .kind = .text, .text_default = "#40404dff" },
    .{ .setter = "set_ssd", .key = "inactive_border_angle", .kind = .number, .num_default = 0, .scale = 10 },
    .{ .setter = "set_ssd", .key = "active_titlebar", .kind = .text, .text_default = "#292e3dff" },
    .{ .setter = "set_ssd", .key = "inactive_titlebar", .kind = .text, .text_default = "#1a1a21ff" },
    .{ .setter = "set_ssd", .key = "title_color", .kind = .text, .text_default = "#ebf0faff" },
    .{ .setter = "set_ssd", .key = "inactive_title_color", .kind = .text, .text_default = "#ebf0faff" },
    .{ .setter = "set_ssd", .key = "title_font", .kind = .text },

    // -- Tab bar theme (`set_tab_bar`) --
    .{ .setter = "set_tab_bar", .key = "font", .kind = .text },
    .{ .setter = "set_tab_bar", .key = "bg", .kind = .text },
    .{ .setter = "set_tab_bar", .key = "fg", .kind = .text },
    .{ .setter = "set_tab_bar", .key = "focus_bg", .kind = .text },
    .{ .setter = "set_tab_bar", .key = "focus_fg", .kind = .text },

    // -- Animation master flags (bare calls, not tables) --
    .{ .setter = "set_animations_enabled", .key = "enabled", .kind = .flag, .bool_default = true },
    .{ .setter = "set_reduced_motion", .key = "enabled", .kind = .flag },

    // -- Window shadows (`set_window_style.shadow.*`) --
    .{ .setter = "set_window_style", .key = "shadow.enabled", .kind = .boolean },
    .{ .setter = "set_window_style", .key = "shadow.range", .kind = .integer, .int_default = 16 },
    .{ .setter = "set_window_style", .key = "shadow.sharp", .kind = .number, .num_default = 0, .scale = 100 },
    .{ .setter = "set_window_style", .key = "shadow.render_power", .kind = .number, .num_default = 2, .scale = 10 },
    .{ .setter = "set_window_style", .key = "shadow.offset_x", .kind = .integer },
    .{ .setter = "set_window_style", .key = "shadow.offset_y", .kind = .integer },
    .{ .setter = "set_window_style", .key = "shadow.scale", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_window_style", .key = "shadow.color", .kind = .text, .text_default = "#00000066" },
    .{ .setter = "set_window_style", .key = "shadow.color_inactive", .kind = .text, .text_default = "#00000066" },

    // -- Scrolling layouts (`set_scrolling`) --
    // Comma-separated floats in the UI; the writer emits a Lua list.
    .{ .setter = "set_scrolling", .key = "width_presets", .kind = .list, .text_default = "0.333, 0.667, 1" },

    // -- Workspace swipe (`set_workspace_gesture`) --
    .{ .setter = "set_workspace_gesture", .key = "enabled", .kind = .boolean, .positional = true },
    .{ .setter = "set_workspace_gesture", .key = "fingers", .kind = .integer, .int_default = 3, .positional = true, .arg_index = 1 },

    // -- Bell sound (`set_bell_sound`) --
    .{ .setter = "set_bell_sound", .key = "sound", .kind = .text, .text_default = "error", .positional = true },

    // -- Animation leaf: Windows in --
    .{ .setter = "set_animation_leaf", .key = "enabled", .kind = .boolean, .leaf = "windows_in", .bool_default = false, .lnum = 0 },
    .{ .setter = "set_animation_leaf", .key = "duration", .kind = .integer, .int_default = 180, .leaf = "windows_in", .lnum = 0 },
    .{ .setter = "set_animation_leaf", .key = "easing", .kind = .text, .text_default = "ease_out_cubic", .leaf = "windows_in", .lnum = 0 },
    .{ .setter = "set_animation_leaf", .key = "style", .kind = .text, .text_default = "slide", .leaf = "windows_in", .lnum = 0 },
    .{ .setter = "set_animation_leaf", .key = "percent", .kind = .integer, .int_default = 20, .leaf = "windows_in", .lnum = 0 },
    // -- Animation leaf: Windows out --
    .{ .setter = "set_animation_leaf", .key = "enabled", .kind = .boolean, .leaf = "windows_out", .bool_default = false, .lnum = 1 },
    .{ .setter = "set_animation_leaf", .key = "duration", .kind = .integer, .int_default = 180, .leaf = "windows_out", .lnum = 1 },
    .{ .setter = "set_animation_leaf", .key = "easing", .kind = .text, .text_default = "ease_out_cubic", .leaf = "windows_out", .lnum = 1 },
    .{ .setter = "set_animation_leaf", .key = "style", .kind = .text, .text_default = "slide", .leaf = "windows_out", .lnum = 1 },
    .{ .setter = "set_animation_leaf", .key = "percent", .kind = .integer, .int_default = 20, .leaf = "windows_out", .lnum = 1 },
    // -- Animation leaf: Windows move --
    .{ .setter = "set_animation_leaf", .key = "enabled", .kind = .boolean, .leaf = "windows_move", .bool_default = true, .lnum = 2 },
    .{ .setter = "set_animation_leaf", .key = "duration", .kind = .integer, .int_default = 180, .leaf = "windows_move", .lnum = 2 },
    .{ .setter = "set_animation_leaf", .key = "easing", .kind = .text, .text_default = "ease_out_cubic", .leaf = "windows_move", .lnum = 2 },
    .{ .setter = "set_animation_leaf", .key = "style", .kind = .text, .text_default = "slide", .leaf = "windows_move", .lnum = 2 },
    .{ .setter = "set_animation_leaf", .key = "percent", .kind = .integer, .int_default = 20, .leaf = "windows_move", .lnum = 2 },
    // -- Animation leaf: Fade --
    .{ .setter = "set_animation_leaf", .key = "enabled", .kind = .boolean, .leaf = "fade", .bool_default = false, .lnum = 3 },
    .{ .setter = "set_animation_leaf", .key = "duration", .kind = .integer, .int_default = 180, .leaf = "fade", .lnum = 3 },
    .{ .setter = "set_animation_leaf", .key = "easing", .kind = .text, .text_default = "ease_out_cubic", .leaf = "fade", .lnum = 3 },
    .{ .setter = "set_animation_leaf", .key = "style", .kind = .text, .text_default = "slide", .leaf = "fade", .lnum = 3 },
    .{ .setter = "set_animation_leaf", .key = "percent", .kind = .integer, .int_default = 20, .leaf = "fade", .lnum = 3 },
    // -- Animation leaf: Layers --
    .{ .setter = "set_animation_leaf", .key = "enabled", .kind = .boolean, .leaf = "layers", .bool_default = false, .lnum = 4 },
    .{ .setter = "set_animation_leaf", .key = "duration", .kind = .integer, .int_default = 180, .leaf = "layers", .lnum = 4 },
    .{ .setter = "set_animation_leaf", .key = "easing", .kind = .text, .text_default = "ease_out_cubic", .leaf = "layers", .lnum = 4 },
    .{ .setter = "set_animation_leaf", .key = "style", .kind = .text, .text_default = "slide", .leaf = "layers", .lnum = 4 },
    .{ .setter = "set_animation_leaf", .key = "percent", .kind = .integer, .int_default = 20, .leaf = "layers", .lnum = 4 },
    // -- Animation leaf: Workspaces --
    .{ .setter = "set_animation_leaf", .key = "enabled", .kind = .boolean, .leaf = "workspaces", .bool_default = true, .lnum = 5 },
    .{ .setter = "set_animation_leaf", .key = "duration", .kind = .integer, .int_default = 180, .leaf = "workspaces", .lnum = 5 },
    .{ .setter = "set_animation_leaf", .key = "easing", .kind = .text, .text_default = "ease_out_cubic", .leaf = "workspaces", .lnum = 5 },
    .{ .setter = "set_animation_leaf", .key = "style", .kind = .text, .text_default = "slide", .leaf = "workspaces", .lnum = 5 },
    .{ .setter = "set_animation_leaf", .key = "percent", .kind = .integer, .int_default = 20, .leaf = "workspaces", .lnum = 5 },
    // -- Animation leaf: Camera --
    .{ .setter = "set_animation_leaf", .key = "enabled", .kind = .boolean, .leaf = "camera", .bool_default = true, .lnum = 6 },
    .{ .setter = "set_animation_leaf", .key = "duration", .kind = .integer, .int_default = 170, .leaf = "camera", .lnum = 6 },
    .{ .setter = "set_animation_leaf", .key = "easing", .kind = .text, .text_default = "ease_out_cubic", .leaf = "camera", .lnum = 6 },
    .{ .setter = "set_animation_leaf", .key = "style", .kind = .text, .text_default = "slide", .leaf = "camera", .lnum = 6 },
    .{ .setter = "set_animation_leaf", .key = "percent", .kind = .integer, .int_default = 20, .leaf = "camera", .lnum = 6 },
    // -- Animation leaf: Layout --
    .{ .setter = "set_animation_leaf", .key = "enabled", .kind = .boolean, .leaf = "layout", .bool_default = true, .lnum = 7 },
    .{ .setter = "set_animation_leaf", .key = "duration", .kind = .integer, .int_default = 180, .leaf = "layout", .lnum = 7 },
    .{ .setter = "set_animation_leaf", .key = "easing", .kind = .text, .text_default = "ease_out_cubic", .leaf = "layout", .lnum = 7 },
    .{ .setter = "set_animation_leaf", .key = "style", .kind = .text, .text_default = "slide", .leaf = "layout", .lnum = 7 },
    .{ .setter = "set_animation_leaf", .key = "percent", .kind = .integer, .int_default = 20, .leaf = "layout", .lnum = 7 },
    // -- Animation leaf: Windows minimize --
    .{ .setter = "set_animation_leaf", .key = "enabled", .kind = .boolean, .leaf = "windows_minimize", .bool_default = true, .lnum = 8 },
    .{ .setter = "set_animation_leaf", .key = "duration", .kind = .integer, .int_default = 250, .leaf = "windows_minimize", .lnum = 8 },
    .{ .setter = "set_animation_leaf", .key = "easing", .kind = .text, .text_default = "ease_out_cubic", .leaf = "windows_minimize", .lnum = 8 },
    .{ .setter = "set_animation_leaf", .key = "style", .kind = .text, .text_default = "minimize", .leaf = "windows_minimize", .lnum = 8 },
    .{ .setter = "set_animation_leaf", .key = "percent", .kind = .integer, .int_default = 20, .leaf = "windows_minimize", .lnum = 8 },
};

pub const slot_count: u16 = k_meta.len;

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    number: f64,
    text: []const u8,
};

// State.

var g_values: [k_meta.len]Value = initValues();
var g_edits: [k_meta.len]?Value = @splat(null);
/// Per-animation-leaf custom curve state. `g_leaf_curve` records whether the
/// leaf call carries a `curve` table; the four points are the editor's.
pub const anim_leaf_count: usize = 9;
var g_leaf_curve: [anim_leaf_count]bool = @splat(false);
var g_curve: [anim_leaf_count][4]f64 = @splat(.{ 0.25, 0.1, 0.25, 1.0 });
var g_leaf_dirty: [anim_leaf_count]bool = @splat(false);
var g_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var g_files: std.ArrayListUnmanaged(File) = .empty;
var g_dirty = false;

/// `set_presentation` touches the display group, so an applied change waits
/// for an explicit keep. The files written by the first commit in the window
/// are kept here so a timeout can put them back.
pub const confirm_seconds: u32 = 15;

const Backup = struct {
    path: []u8,
    /// null when the file did not exist before the commit.
    text: ?[]const u8,
};

var g_backups: std.ArrayListUnmanaged(Backup) = .empty;
var g_confirm_pending = false;
var g_confirm_deadline_ms: i64 = 0;

fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(i64, @intCast(@divTrunc(@max(ts.nsec, 0), 1_000_000)));
}

pub fn confirmPending() bool {
    return g_confirm_pending;
}

pub fn confirmRemaining() u32 {
    if (!g_confirm_pending) return 0;
    const left = g_confirm_deadline_ms - nowMs();
    if (left <= 0) return 0;
    return @intCast(@divTrunc(left + 999, 1000));
}

fn freeBackups() void {
    for (g_backups.items) |b| {
        std.heap.page_allocator.free(b.path);
        if (b.text) |t| std.heap.page_allocator.free(t);
    }
    g_backups.deinit(std.heap.page_allocator);
    g_backups = .empty;
}

/// Accept the applied display settings.
pub fn keep(io: std.Io) void {
    clearMarker(io);
    freeBackups();
    g_confirm_pending = false;
    g_confirm_deadline_ms = 0;
}

/// Restore every file captured by the first display commit and reload.
pub fn revert(io: std.Io) void {
    for (g_backups.items) |b| {
        if (b.text) |t| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = b.path, .data = t }) catch {};
        } else {
            std.Io.Dir.cwd().deleteFile(io, b.path) catch {};
        }
    }
    clearMarker(io);
    freeBackups();
    g_confirm_pending = false;
    g_confirm_deadline_ms = 0;
    reload(std.heap.page_allocator, io);
    load(io);
}

/// Called from the repaint tick; reverts when the window has expired.
pub fn tick(io: std.Io) bool {
    if (!g_confirm_pending) return false;
    if (nowMs() < g_confirm_deadline_ms) return false;
    revert(io);
    return true;
}

fn markerPath(a: std.mem.Allocator) ?[]u8 {
    const dir = configDir(a) catch return null;
    defer a.free(dir);
    return std.fmt.allocPrint(a, "{s}/.eh-pending-presentation", .{dir}) catch null;
}

fn clearMarker(io: std.Io) void {
    const a = std.heap.page_allocator;
    const path = markerPath(a) orelse return;
    defer a.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn writeMarker(io: std.Io) void {
    const a = std.heap.page_allocator;
    const path = markerPath(a) orelse return;
    defer a.free(path);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    out.appendSlice(a, "EHP1\n") catch return;
    for (g_backups.items) |b| {
        out.appendSlice(a, b.path) catch return;
        out.append(a, '\n') catch return;
        out.appendSlice(a, if (b.text != null) "1\n" else "0\n") catch return;
        var nb: [24]u8 = undefined;
        const txt: []const u8 = b.text orelse "";
        const ns = std.fmt.bufPrint(&nb, "{d}\n", .{txt.len}) catch return;
        out.appendSlice(a, ns) catch return;
        out.appendSlice(a, b.text orelse "") catch return;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// Restore presentation files captured before a commit that was never kept.
/// Called once at window startup, before the first `load`.
pub fn recoverAtLaunch(io: std.Io) void {
    const a = std.heap.page_allocator;
    const path = markerPath(a) orelse return;
    defer a.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch return;
    defer a.free(data);
    if (!std.mem.startsWith(u8, data, "EHP1\n")) {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return;
    }
    const cwd = std.Io.Dir.cwd();
    var pos: usize = 5;
    while (pos < data.len) {
        const pnl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
        const fpath = data[pos..pnl];
        pos = pnl + 1;
        const hnl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
        const had = std.mem.eql(u8, std.mem.trim(u8, data[pos..hnl], " \t\r"), "1");
        pos = hnl + 1;
        const lnl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
        const n = std.fmt.parseInt(usize, std.mem.trim(u8, data[pos..lnl], " \t\r"), 10) catch break;
        pos = lnl + 1;
        if (pos + n > data.len) break;
        const text = data[pos .. pos + n];
        pos += n;
        if (had) {
            cwd.writeFile(io, .{ .sub_path = fpath, .data = text }) catch {};
        } else {
            cwd.deleteFile(io, fpath) catch {};
        }
    }
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    reload(a, io);
    load(io);
}

fn captureBackup(path: []const u8, io: std.Io) void {
    if (g_confirm_pending) return;
    const a = std.heap.page_allocator;
    const path_copy = a.dupe(u8, path) catch return;
    const text_copy = readFile(a, io, path);
    g_backups.append(a, .{ .path = path_copy, .text = text_copy }) catch {
        a.free(path_copy);
        if (text_copy) |t| a.free(t);
    };
}

const File = struct {
    path: []const u8,
    text: []const u8,
};

fn initValues() [k_meta.len]Value {
    var out: [k_meta.len]Value = undefined;
    for (&out, 0..) |*v, i| {
        const m = k_meta[i];
        v.* = switch (m.kind) {
            .boolean, .flag => .{ .boolean = m.bool_default },
            .integer => .{ .integer = m.int_default },
            .number => .{ .number = m.num_default },
            .text, .list => .{ .text = m.text_default },
        };
    }
    return out;
}

pub fn isDirty() bool {
    return g_dirty;
}

pub fn markDirty() void {
    g_dirty = true;
}

// Paths.

fn envStr(key: [:0]const u8) ?[]const u8 {
    const p = std.c.getenv(key) orelse return null;
    const s = std.mem.span(p);
    return if (s.len == 0) null else s;
}

fn homeDir() []const u8 {
    return envStr("HOME") orelse "/tmp";
}

/// `$XDG_CONFIG_HOME/zoolander`, or `~/.config/zoolander`.
pub fn configDir(a: std.mem.Allocator) ![]u8 {
    const base = envStr("XDG_CONFIG_HOME") orelse return std.fmt.allocPrint(a, "{s}/.config/zoolander", .{homeDir()});
    return std.fmt.allocPrint(a, "{s}/zoolander", .{base});
}

/// Pick the module file that owns `setter` when appending a brand-new call.
/// Animation leaves go to `animations.lua`, layout to `layout.lua`, and so on,
/// so a split config keeps its setters beside their siblings instead of dumping
/// everything into `init.lua`. Falls back to `init.lua` when no module matches.
fn moduleForSetter(setter: []const u8) []const u8 {
    if (std.mem.eql(u8, setter, "set_animation_leaf")) return "animations.lua";
    if (std.mem.eql(u8, setter, "set_animations_enabled")) return "animations.lua";
    if (std.mem.eql(u8, setter, "set_reduced_motion")) return "animations.lua";
    if (std.mem.eql(u8, setter, "set_layout")) return "layout.lua";
    if (std.mem.eql(u8, setter, "set_keyboard")) return "keyboard.lua";
    if (std.mem.eql(u8, setter, "set_pointer")) return "pointer.lua";
    if (std.mem.eql(u8, setter, "set_presentation")) return "presentation.lua";
    if (std.mem.eql(u8, setter, "set_xwayland")) return "xwayland.lua";
    if (std.mem.eql(u8, setter, "set_window_style")) return "window_style.lua";
    if (std.mem.eql(u8, setter, "set_ssd")) return "ssd.lua";
    if (std.mem.eql(u8, setter, "set_blur")) return "blur.lua";
    if (std.mem.eql(u8, setter, "set_dim")) return "dim.lua";
    if (std.mem.eql(u8, setter, "set_floating")) return "floating.lua";
    if (std.mem.eql(u8, setter, "set_tab_bar")) return "tab_bar.lua";
    if (std.mem.eql(u8, setter, "set_spatial")) return "spatial.lua";
    if (std.mem.eql(u8, setter, "set_scrolling")) return "scrolling.lua";
    if (std.mem.eql(u8, setter, "set_overview")) return "overview.lua";
    if (std.mem.eql(u8, setter, "set_bell_sound")) return "bell.lua";
    if (std.mem.eql(u8, setter, "set_workspace_gesture")) return "workspace_gesture.lua";
    return "init.lua";
}

fn readFile(a: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch null;
}

// Tiny Lua table parser. It never evaluates code; it only records spans.

const Entry = struct {
    key: []const u8,
    value_start: usize,
    value_end: usize,
    child: ?*Object = null,
};

const Object = struct {
    open: usize,
    close: usize = 0,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
};

const Call = struct {
    name: []const u8,
    object: ?*Object = null,
    arg_start: usize = 0,
    arg_end: usize = 0,
    /// Offset of the `zl` identifier, for replacing a whole call.
    start: usize = 0,
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipLongBracket(text: []const u8, i: usize) ?usize {
    if (i >= text.len or text[i] != '[') return null;
    var j = i + 1;
    var eqs: usize = 0;
    while (j < text.len and text[j] == '=') : (j += 1) eqs += 1;
    if (j >= text.len or text[j] != '[') return null;
    j += 1;
    while (j < text.len) : (j += 1) {
        if (text[j] == ']') {
            var k = j + 1;
            var n: usize = 0;
            while (n < eqs and k < text.len and text[k] == '=') : ({
                k += 1;
                n += 1;
            }) {}
            if (n == eqs and k < text.len and text[k] == ']') return k + 1;
        }
    }
    return text.len;
}

fn skipString(text: []const u8, i: usize) usize {
    const quote = text[i];
    var j = i + 1;
    while (j < text.len) : (j += 1) {
        if (text[j] == '\\' and j + 1 < text.len) {
            j += 1;
            continue;
        }
        if (text[j] == quote) return j + 1;
    }
    return text.len;
}

fn skipWsComments(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i] == '-' and text[i + 1] == '-') {
            if (skipLongBracket(text, i + 2)) |end| {
                i = end;
                continue;
            }
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        break;
    }
    return i;
}

/// Skip a non-table value up to its top-level `,`, `;`, `}` or `)`.
fn scanValue(text: []const u8, start: usize) usize {
    var i = start;
    var depth: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            i = skipString(text, i);
            continue;
        }
        if (c == '[') {
            if (skipLongBracket(text, i)) |end| {
                i = end;
                continue;
            }
        }
        if (c == '-' and i + 1 < text.len and text[i + 1] == '-') {
            const end = skipWsComments(text, i);
            i = end;
            continue;
        }
        switch (c) {
            '{', '(', '[' => depth += 1,
            '}', ')' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            ']' => if (depth > 0) {
                depth -= 1;
            },
            ',', ';' => if (depth == 0) return i,
            else => {},
        }
        i += 1;
    }
    return i;
}

fn parseObject(a: std.mem.Allocator, text: []const u8, open: usize) !*Object {
    const obj = try a.create(Object);
    obj.* = .{ .open = open };
    var i = open + 1;
    while (true) {
        i = skipWsComments(text, i);
        if (i >= text.len) return error.UnterminatedTable;
        if (text[i] == '}') {
            obj.close = i;
            return obj;
        }
        if (text[i] == ',' or text[i] == ';') {
            i += 1;
            continue;
        }
        var key: []const u8 = "";
        if (text[i] == '[') {
            var j = i + 1;
            if (j < text.len and (text[j] == '"' or text[j] == '\'')) {
                const quote = text[j];
                j += 1;
                const ks = j;
                while (j < text.len and text[j] != quote) : (j += 1) {
                    if (text[j] == '\\' and j + 1 < text.len) j += 1;
                }
                key = text[ks..j];
                if (j < text.len) j += 1;
            }
            while (j < text.len and text[j] != ']') j += 1;
            if (j < text.len) j += 1;
            i = j;
        } else if (isIdent(text[i])) {
            const ks = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            key = text[ks..i];
        } else {
            i += 1;
            continue;
        }
        i = skipWsComments(text, i);
        if (i >= text.len or text[i] != '=') {
            i = scanValue(text, i);
            continue;
        }
        i += 1;
        i = skipWsComments(text, i);
        const value_start = i;
        var value_end: usize = 0;
        var child: ?*Object = null;
        if (i < text.len and text[i] == '{') {
            child = try parseObject(a, text, i);
            value_end = child.?.close + 1;
            i = value_end;
        } else {
            value_end = scanValue(text, i);
            i = value_end;
        }
        try obj.entries.append(a, .{
            .key = key,
            .value_start = value_start,
            .value_end = value_end,
            .child = child,
        });
    }
}

fn scanCalls(a: std.mem.Allocator, text: []const u8) ![]Call {
    var out: std.ArrayListUnmanaged(Call) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            i = skipString(text, i);
            continue;
        }
        if (c == '[') {
            if (skipLongBracket(text, i)) |end| {
                i = end;
                continue;
            }
        }
        if (c == '-' and i + 1 < text.len and text[i + 1] == '-') {
            i = skipWsComments(text, i);
            continue;
        }
        if (i + 1 < text.len and text[i] == 'z' and text[i + 1] == 'l' and
            (i == 0 or !isIdent(text[i - 1])) and (i + 2 >= text.len or !isIdent(text[i + 2])))
        {
            var j = skipWsComments(text, i + 2);
            if (j < text.len and text[j] == '.') {
                j = skipWsComments(text, j + 1);
                const name_start = j;
                while (j < text.len and isIdent(text[j])) j += 1;
                const name = text[name_start..j];
                j = skipWsComments(text, j);
                if (name.len > 0 and j < text.len and text[j] == '(') {
                    j = skipWsComments(text, j + 1);
                    const arg_start = j;
                    if (j < text.len and text[j] == '{') {
                        const obj = parseObject(a, text, j) catch null;
                        try out.append(a, .{ .name = name, .object = obj, .arg_start = arg_start });
                        i = if (obj) |o| o.close + 1 else j + 1;
                        continue;
                    }
                    const end = scanValue(text, j);
                    try out.append(a, .{ .name = name, .arg_start = arg_start, .arg_end = end });
                    i = end;
                    continue;
                }
            }
        }
        i += 1;
    }
    return out.toOwnedSlice(a);
}

/// A top-level argument span inside a call's parentheses.
const ArgSpan = struct { start: usize, end: usize };

/// The span of argument `idx` of `c` (`start..end` excludes the argument's
/// surrounding whitespace). Null when the call has fewer arguments.
fn argSpan(text: []const u8, c: Call, idx: usize) ?ArgSpan {
    if (c.arg_start >= c.arg_end) return null;
    var i = c.arg_start;
    var depth: usize = 0;
    var arg: usize = 0;
    var start = i;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '"' or ch == '\'') {
            i = skipString(text, i);
            continue;
        }
        if (ch == '[') {
            if (skipLongBracket(text, i)) |end| {
                i = end;
                continue;
            }
        }
        if (ch == '-' and i + 1 < text.len and text[i + 1] == '-') {
            i = skipWsComments(text, i);
            continue;
        }
        switch (ch) {
            '{', '(', '[' => depth += 1,
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            ')' => {
                if (depth == 0) {
                    if (arg == idx) return trimSpan(text, start, i);
                    return null;
                }
                depth -= 1;
            },
            ',' => if (depth == 0) {
                if (arg == idx) return trimSpan(text, start, i);
                arg += 1;
                start = i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

fn trimSpan(text: []const u8, start: usize, end: usize) ArgSpan {
    var s = start;
    var e = end;
    while (s < e and std.ascii.isWhitespace(text[s])) s += 1;
    while (e > s and std.ascii.isWhitespace(text[e - 1])) e -= 1;
    return .{ .start = s, .end = e };
}

/// Index of the call's closing `)`.
fn callClose(text: []const u8, c: Call) ?usize {
    var i = c.arg_start;
    var depth: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '"' or ch == '\'') {
            i = skipString(text, i);
            continue;
        }
        if (ch == '[') {
            if (skipLongBracket(text, i)) |end| {
                i = end;
                continue;
            }
        }
        if (ch == '-' and i + 1 < text.len and text[i + 1] == '-') {
            i = skipWsComments(text, i);
            continue;
        }
        switch (ch) {
            '{', '(', '[' => depth += 1,
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            ')' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

fn argCount(text: []const u8, c: Call) usize {
    var n: usize = 0;
    while (argSpan(text, c, n) != null) n += 1;
    return n;
}

/// Default literal for positional argument `idx` of `setter`, from the
/// matching `k_meta` entry. Used as a placeholder when the UI sets a later
/// argument (e.g. master count) on a call that stops earlier.
fn defaultArgLiteral(setter: []const u8, idx: u8, buf: []u8) ?[]const u8 {
    for (k_meta) |m| {
        if (!m.positional or m.arg_index != idx) continue;
        if (!std.mem.eql(u8, m.setter, setter)) continue;
        const v: Value = switch (m.kind) {
            .boolean, .flag => .{ .boolean = m.bool_default },
            .integer => .{ .integer = m.int_default },
            .number => .{ .number = m.num_default },
            .text, .list => .{ .text = m.text_default },
        };
        return formatLiteral(buf, v);
    }
    return null;
}

fn findDirect(obj: *const Object, key: []const u8) ?*const Entry {
    var i = obj.entries.items.len;
    while (i > 0) {
        i -= 1;
        const e = &obj.entries.items[i];
        if (std.mem.eql(u8, e.key, key)) return e;
    }
    return null;
}

fn findEntry(obj: *const Object, path: []const u8) ?*const Entry {
    var cur = obj;
    var it = std.mem.splitScalar(u8, path, '.');
    var seg = it.next() orelse return null;
    while (true) {
        const e = findDirect(cur, seg) orelse return null;
        if (it.next()) |next| {
            cur = e.child orelse return null;
            seg = next;
        } else {
            return e;
        }
    }
}

// Formatting.

fn formatNumber(buf: []u8, v: f64) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d:.4}", .{v}) catch return "0";
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

fn formatLiteral(buf: []u8, v: Value) []const u8 {
    return switch (v) {
        .boolean => |b| if (b) "true" else "false",
        .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "0",
        .number => |n| formatNumber(buf, n),
        .text => |s| blk: {
            if (buf.len < 2) return "\"\"";
            var i: usize = 0;
            buf[i] = '"';
            i += 1;
            for (s) |c| {
                if (i + 3 >= buf.len) break;
                if (c == '"' or c == '\\') {
                    buf[i] = '\\';
                    i += 1;
                }
                buf[i] = c;
                i += 1;
            }
            buf[i] = '"';
            i += 1;
            break :blk buf[0..i];
        },
    };
}

/// Render the editable comma-separated text as a Lua list literal. Tokens
/// that are not finite numbers fall back to a quoted string so a typo can
/// never inject code into the config.
fn formatList(buf: []u8, text: []const u8) []const u8 {
    if (buf.len < 4) return "{}";
    var n: usize = 0;
    buf[n] = '{';
    buf[n + 1] = ' ';
    n += 2;
    var any = false;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        const item = std.mem.trim(u8, part, " \t\r\n");
        if (item.len == 0) continue;
        if (any) {
            if (n + 2 >= buf.len) break;
            buf[n] = ',';
            buf[n + 1] = ' ';
            n += 2;
        }
        const numeric = if (std.fmt.parseFloat(f64, item)) |_| true else |_| false;
        if (numeric) {
            if (n + item.len + 2 >= buf.len) break;
            @memcpy(buf[n .. n + item.len], item);
            n += item.len;
        } else {
            if (n + 2 >= buf.len) break;
            buf[n] = '"';
            n += 1;
            for (item) |ch| {
                const need: usize = if (ch == '"' or ch == '\\') 2 else 1;
                if (n + need + 2 >= buf.len) break;
                if (need == 2) {
                    buf[n] = '\\';
                    n += 1;
                }
                buf[n] = ch;
                n += 1;
            }
            buf[n] = '"';
            n += 1;
        }
        any = true;
    }
    if (n + 2 < buf.len) {
        if (any) {
            buf[n] = ' ';
            n += 1;
        }
        buf[n] = '}';
        n += 1;
    }
    return buf[0..n];
}

fn nestedLiteral(a: std.mem.Allocator, path: []const u8, lit: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const head = path[0..dot];
        const tail = try nestedLiteral(a, path[dot + 1 ..], lit);
        defer a.free(tail);
        return std.fmt.allocPrint(a, "{s} = {{ {s} }}", .{ head, tail });
    }
    return std.fmt.allocPrint(a, "{s} = {s}", .{ path, lit });
}

fn insertSnippet(a: std.mem.Allocator, text: []const u8, obj: *const Object, snippet: []const u8) ![]u8 {
    const at = obj.close;
    var prev = at;
    while (prev > obj.open + 1 and std.ascii.isWhitespace(text[prev - 1])) prev -= 1;
    const need_comma = prev > obj.open + 1 and text[prev - 1] != '{' and text[prev - 1] != ',' and text[prev - 1] != ';';
    const prefix: []const u8 = if (need_comma) ", " else "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text[0..at]);
    try out.appendSlice(a, prefix);
    try out.appendSlice(a, snippet);
    try out.appendSlice(a, ", ");
    try out.appendSlice(a, text[at..]);
    return out.toOwnedSlice(a);
}

fn replaceSpan(a: std.mem.Allocator, text: []const u8, start: usize, end: usize, lit: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text[0..start]);
    try out.appendSlice(a, lit);
    try out.appendSlice(a, text[end..]);
    return out.toOwnedSlice(a);
}

/// Rewrite one setter literal in `text`. Returns a new allocation, or null
/// when the setter has no call at all (the file writer then appends one).
fn editText(a: std.mem.Allocator, text: []const u8, setter: []const u8, key: []const u8, lit: []const u8) !?[]u8 {
    const calls = try scanCalls(a, text);
    var best: ?*Object = null;
    var last: ?*Object = null;
    for (calls) |c| {
        if (!std.mem.eql(u8, c.name, setter)) continue;
        const obj = c.object orelse continue;
        last = obj;
        if (findEntry(obj, key) != null) best = obj;
    }
    const target = best orelse last orelse return null;
    if (findEntry(target, key)) |e| {
        return try replaceSpan(a, text, e.value_start, e.value_end, lit);
    }
    const snippet = try nestedLiteral(a, key, lit);
    defer a.free(snippet);
    return try insertSnippet(a, text, target, snippet);
}

/// True when `raw` is a quoted string literal equal to `want`.
fn argStringEq(raw: []const u8, want: []const u8) bool {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len < 2) return false;
    if (!((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) return false;
    return std.mem.eql(u8, s[1 .. s.len - 1], want);
}

/// Rewrite one key in the options table of `set_animation_leaf(leaf, { ... })`.
/// Returns null when that leaf has no call, so the writer appends one.
fn editLeaf(a: std.mem.Allocator, text: []const u8, leaf: []const u8, key: []const u8, lit: []const u8) !?[]u8 {
    const calls = try scanCalls(a, text);
    var target: ?Call = null;
    for (calls) |c| {
        if (!std.mem.eql(u8, c.name, "set_animation_leaf")) continue;
        const s0 = argSpan(text, c, 0) orelse continue;
        if (!argStringEq(text[s0.start..s0.end], leaf)) continue;
        target = c;
    }
    const c = target orelse return null;
    if (argSpan(text, c, 1)) |s1| {
        const start = skipWsComments(text, s1.start);
        if (start >= text.len or text[start] != '{') return null;
        const obj = try parseObject(a, text, start);
        if (findEntry(obj, key)) |e| {
            return try replaceSpan(a, text, e.value_start, e.value_end, lit);
        }
        const snippet = try nestedLiteral(a, key, lit);
        defer a.free(snippet);
        return try insertSnippet(a, text, obj, snippet);
    }
    // Call exists but has no options table yet: add it as the second argument.
    const close = callClose(text, c) orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text[0..close]);
    try out.appendSlice(a, ", { ");
    try out.appendSlice(a, key);
    try out.appendSlice(a, " = ");
    try out.appendSlice(a, lit);
    try out.appendSlice(a, " }");
    try out.appendSlice(a, text[close..]);
    return try out.toOwnedSlice(a);
}

fn appendLeafCall(a: std.mem.Allocator, text: []const u8, leaf: []const u8, key: []const u8, lit: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, "\nzl.set_animation_leaf(\"");
    try out.appendSlice(a, leaf);
    try out.appendSlice(a, "\", { ");
    try out.appendSlice(a, key);
    try out.appendSlice(a, " = ");
    try out.appendSlice(a, lit);
    try out.appendSlice(a, " })\n");
    return out.toOwnedSlice(a);
}

/// Rewrite the boolean argument of a bare-call setter (`zl.set_reduced_motion
/// (true)`). Returns null when the call is absent, so the writer appends one.
fn editFlag(a: std.mem.Allocator, text: []const u8, setter: []const u8, lit: []const u8) !?[]u8 {
    const calls = try scanCalls(a, text);
    var last: ?Call = null;
    for (calls) |c| {
        if (std.mem.eql(u8, c.name, setter) and c.object == null) last = c;
    }
    const c = last orelse return null;
    return try replaceSpan(a, text, c.arg_start, c.arg_end, lit);
}

/// Rewrite one positional argument of a setter call
/// (`zl.set_layout("dwindle", 0.62)`), leaving the other arguments alone.
/// Missing intermediate arguments are filled from their schema defaults so
/// setting, say, `master_count` on a one-argument call stays valid Lua.
/// Returns null when the call is absent, so the writer appends one.
fn editArgAt(a: std.mem.Allocator, text: []const u8, setter: []const u8, idx: u8, lit: []const u8) !?[]u8 {
    const calls = try scanCalls(a, text);
    var last: ?Call = null;
    for (calls) |c| {
        if (std.mem.eql(u8, c.name, setter) and c.object == null) last = c;
    }
    const c = last orelse return null;
    if (c.arg_start >= c.arg_end) return null;
    if (argSpan(text, c, idx)) |span| {
        return try replaceSpan(a, text, span.start, span.end, lit);
    }
    const close = callClose(text, c) orelse return null;
    const have = argCount(text, c);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text[0..close]);
    var k: usize = have;
    while (k <= idx) : (k += 1) {
        var buf: [256]u8 = undefined;
        const value = if (k == idx) lit else defaultArgLiteral(setter, @intCast(k), &buf) orelse return null;
        try out.appendSlice(a, ", ");
        try out.appendSlice(a, value);
    }
    try out.appendSlice(a, text[close..]);
    return try out.toOwnedSlice(a);
}

/// Backwards-compatible first-argument form used by the existing tests.
fn editArgText(a: std.mem.Allocator, text: []const u8, setter: []const u8, lit: []const u8) !?[]u8 {
    return editArgAt(a, text, setter, 0, lit);
}

fn appendArgCall(a: std.mem.Allocator, text: []const u8, setter: []const u8, lit: []const u8) ![]u8 {
    return appendArgAtCall(a, text, setter, 0, lit);
}

fn appendArgAtCall(a: std.mem.Allocator, text: []const u8, setter: []const u8, idx: u8, lit: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, "\nzl.");
    try out.appendSlice(a, setter);
    try out.append(a, '(');
    var k: usize = 0;
    while (k <= idx) : (k += 1) {
        if (k > 0) try out.appendSlice(a, ", ");
        var buf: [256]u8 = undefined;
        const value = if (k == idx) lit else defaultArgLiteral(setter, @intCast(k), &buf) orelse "";
        try out.appendSlice(a, value);
    }
    try out.appendSlice(a, ")\n");
    return out.toOwnedSlice(a);
}

fn appendFlagCall(a: std.mem.Allocator, text: []const u8, setter: []const u8, lit: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, "\nzl.");
    try out.appendSlice(a, setter);
    try out.append(a, '(');
    try out.appendSlice(a, lit);
    try out.appendSlice(a, ")\n");
    return out.toOwnedSlice(a);
}

fn appendCall(a: std.mem.Allocator, text: []const u8, setter: []const u8, key: []const u8, lit: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    try out.append(a, '\n');
    try out.appendSlice(a, "zl.");
    try out.appendSlice(a, setter);
    try out.appendSlice(a, "({\n    ");
    try out.appendSlice(a, key);
    try out.appendSlice(a, " = ");
    try out.appendSlice(a, lit);
    try out.appendSlice(a, ",\n})\n");
    return out.toOwnedSlice(a);
}

// Load.

/// Re-read every Lua file in the config directory. Missing files and
/// directories simply leave the schema defaults in place.
pub fn load(io: std.Io) void {
    g_arena.deinit();
    g_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    g_files = .empty;
    g_values = initValues();
    g_edits = @splat(null);
    g_leaf_curve = @splat(false);
    g_curve = @splat(.{ 0.25, 0.1, 0.25, 1.0 });
    g_leaf_dirty = @splat(false);
    g_dirty = false;

    const a = g_arena.allocator();
    const dir_path = configDir(a) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".lua")) continue;
        const name = a.dupe(u8, e.name) catch continue;
        names.append(a, name) catch continue;
    }
    std.mem.sort([]const u8, names.items, {}, nameLessThan);
    for (names.items) |name| {
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name }) catch continue;
        const text = readFile(a, io, path) orelse continue;
        g_files.append(a, .{ .path = path, .text = text }) catch continue;
    }

    for (g_files.items) |f| {
        const calls = scanCalls(a, f.text) catch continue;
        for (calls) |c| {
            for (k_meta, 0..) |m, i| {
                if (!std.mem.eql(u8, m.setter, c.name)) continue;
                if (m.leaf.len > 0) {
                    const s0 = argSpan(f.text, c, 0) orelse continue;
                    if (!argStringEq(f.text[s0.start..s0.end], m.leaf)) continue;
                    const s1 = argSpan(f.text, c, 1) orelse continue;
                    const start = skipWsComments(f.text, s1.start);
                    if (start >= f.text.len or f.text[start] != '{') continue;
                    const obj = parseObject(a, f.text, start) catch continue;
                    // Pull the optional custom curve once per leaf, then the
                    // scalar option this entry owns.
                    if (m.lnum < anim_leaf_count and std.mem.eql(u8, m.key, "enabled")) {
                        if (findEntry(obj, "curve")) |ce| {
                            if (ce.child) |co| {
                                g_leaf_curve[m.lnum] = true;
                                const curve_keys = [_][]const u8{ "x1", "y1", "x2", "y2" };
                                for (curve_keys, 0..) |n, k| {
                                    if (findDirect(co, n)) |pe| {
                                        const praw = std.mem.trim(u8, f.text[pe.value_start..pe.value_end], " \t\r\n");
                                        g_curve[m.lnum][k] = std.fmt.parseFloat(f64, praw) catch g_curve[m.lnum][k];
                                    }
                                }
                            }
                        }
                    }
                    const e = findEntry(obj, m.key) orelse continue;
                    const raw = std.mem.trim(u8, f.text[e.value_start..e.value_end], " \t\r\n");
                    g_values[i] = parseValue(a, m, raw);
                    continue;
                }
                if (m.kind == .flag) {
                    const raw = std.mem.trim(u8, f.text[c.arg_start..c.arg_end], " \t\r\n");
                    g_values[i] = parseValue(a, m, raw);
                    continue;
                }
                if (m.positional) {
                    const span = argSpan(f.text, c, m.arg_index) orelse continue;
                    const raw = f.text[span.start..span.end];
                    // A computed layout argument (a Lua function that places
                    // windows) is not ours to interpret; keep the default.
                    if (m.arg_index == 0 and (raw.len < 2 or (raw[0] != '"' and raw[0] != '\''))) continue;
                    if (raw.len == 0) continue;
                    g_values[i] = parseValue(a, m, raw);
                    continue;
                }
                const obj = c.object orelse continue;
                const e = findEntry(obj, m.key) orelse continue;
                const raw = std.mem.trim(u8, f.text[e.value_start..e.value_end], " \t\r\n");
                g_values[i] = parseValue(a, m, raw);
            }
        }
    }
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, "init.lua")) return false;
    if (std.mem.eql(u8, b, "init.lua")) return true;
    return std.mem.lessThan(u8, a, b);
}

fn parseValue(a: std.mem.Allocator, m: Meta, raw: []const u8) Value {
    return switch (m.kind) {
        .boolean, .flag => .{ .boolean = std.mem.eql(u8, raw, "true") },
        .integer => .{ .integer = std.fmt.parseInt(i64, raw, 10) catch m.int_default },
        .number => .{ .number = std.fmt.parseFloat(f64, raw) catch m.num_default },
        .text => blk: {
            var s = raw;
            if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
                s = s[1 .. s.len - 1];
            }
            break :blk .{ .text = a.dupe(u8, s) catch m.text_default };
        },
        .list => blk: {
            // Show a Lua list as the comma-separated text the band edits.
            var s = std.mem.trim(u8, raw, " \t\r\n");
            if (s.len >= 2 and s[0] == '{' and s[s.len - 1] == '}') s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
            var out: std.ArrayListUnmanaged(u8) = .empty;
            var it = std.mem.splitScalar(u8, s, ',');
            var first = true;
            while (it.next()) |part| {
                const item = std.mem.trim(u8, part, " \t\r\n");
                if (item.len == 0) continue;
                if (!first) out.appendSlice(a, ", ") catch {};
                out.appendSlice(a, item) catch {};
                first = false;
            }
            break :blk .{ .text = out.toOwnedSlice(a) catch m.text_default };
        },
    };
}

pub fn ensureLoaded(io: std.Io) void {
    if (g_dirty) return;
    load(io);
}

// UI accessors.

fn uiToValue(m: Meta, v: i32) Value {
    return switch (m.kind) {
        .boolean, .flag => .{ .boolean = v != 0 },
        .integer => .{ .integer = v },
        .number => .{ .number = @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(m.scale)) },
        .text, .list => .{ .text = "" },
    };
}

pub fn kindOf(slot: u16) Kind {
    return k_meta[slot].kind;
}

pub fn getBool(slot: u16) bool {
    return switch (g_values[slot]) {
        .boolean => |b| b,
        .integer => |n| n != 0,
        .number => |n| n != 0,
        .text => |s| s.len > 0,
    };
}

pub fn setBool(slot: u16, v: bool) void {
    g_values[slot] = .{ .boolean = v };
    g_edits[slot] = .{ .boolean = v };
    if (k_meta[slot].leaf.len > 0) g_leaf_dirty[k_meta[slot].lnum] = true;
    g_dirty = true;
}

pub fn getInt(slot: u16) i32 {
    const m = k_meta[slot];
    return switch (g_values[slot]) {
        .boolean => |b| if (b) 1 else 0,
        .integer => |n| std.math.cast(i32, n) orelse if (n > 0) std.math.maxInt(i32) else std.math.minInt(i32),
        .number => |n| blk: {
            const scaled = @round(n * @as(f64, @floatFromInt(m.scale)));
            if (scaled >= 2147483647.0) break :blk std.math.maxInt(i32);
            if (scaled <= -2147483648.0) break :blk std.math.minInt(i32);
            break :blk @intFromFloat(scaled);
        },
        .text => 0,
    };
}

pub fn setInt(slot: u16, v: i32) void {
    const m = k_meta[slot];
    const value = uiToValue(m, v);
    g_values[slot] = value;
    g_edits[slot] = value;
    if (m.leaf.len > 0) g_leaf_dirty[m.lnum] = true;
    g_dirty = true;
}

pub fn getStr(slot: u16) []const u8 {
    return switch (g_values[slot]) {
        .text => |s| s,
        else => "",
    };
}

pub fn setStr(slot: u16, v: []const u8) void {
    g_values[slot] = .{ .text = v };
    g_edits[slot] = .{ .text = v };
    if (k_meta[slot].leaf.len > 0) g_leaf_dirty[k_meta[slot].lnum] = true;
    g_dirty = true;
}

/// Restore a slot to its schema default (the reference's "Default" buttons).
pub fn resetSlot(slot: u16) void {
    const m = k_meta[slot];
    switch (m.kind) {
        .boolean, .flag => setBool(slot, m.bool_default),
        .integer => setInt(slot, m.int_default),
        .number => setInt(slot, @intFromFloat(@round(m.num_default * @as(f64, @floatFromInt(m.scale))))),
        .text, .list => setStr(slot, m.text_default),
    }
}

pub fn comboIndex(slot: u16, options: []const []const u8) usize {
    const cur = getStr(slot);
    for (options, 0..) |opt, i| {
        if (std.mem.eql(u8, opt, cur)) return i;
    }
    return 0;
}

pub fn setComboIndex(slot: u16, options: []const []const u8, idx: usize) void {
    if (idx < options.len) setStr(slot, options[idx]);
}

/// Slider display text: floats print with their scaled precision and no
/// floating-point noise; integers stay bare; enums never reach here.
pub fn valueText(slot: u16, v: i32, unit: []const u8, buf: []u8) []const u8 {
    const m = k_meta[slot];
    switch (m.kind) {
        .number => {
            const actual = @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(m.scale));
            var num_buf: [32]u8 = undefined;
            const num = formatNumber(&num_buf, actual);
            return if (unit.len == 0)
                std.fmt.bufPrint(buf, "{s}", .{num}) catch ""
            else
                std.fmt.bufPrint(buf, "{s} {s}", .{ num, unit }) catch "";
        },
        else => return if (unit.len == 0)
            std.fmt.bufPrint(buf, "{d}", .{v}) catch ""
        else
            std.fmt.bufPrint(buf, "{d} {s}", .{ v, unit }) catch "",
    }
}

// Animation leaf curve state.

pub fn leafCurveSet(lnum: u8) bool {
    return lnum < anim_leaf_count and g_leaf_curve[lnum];
}

pub fn leafCurvePoint(lnum: u8, k: usize) f64 {
    if (lnum >= anim_leaf_count or k >= 4) return 0;
    return g_curve[lnum][k];
}

pub fn setLeafCurvePoint(lnum: u8, k: usize, v: f64) void {
    if (lnum >= anim_leaf_count or k >= 4) return;
    g_curve[lnum][k] = std.math.clamp(v, -1.0, 2.0);
    g_leaf_curve[lnum] = true;
    g_leaf_dirty[lnum] = true;
    g_dirty = true;
}

/// Seed the stored curve from the easing the leaf is showing right now, so
/// the first drag of a handle moves just that handle instead of snapping the
/// other three to the schema default.
pub fn beginLeafCurve(lnum: u8, p: [4]f64) void {
    if (lnum >= anim_leaf_count or g_leaf_curve[lnum]) return;
    g_curve[lnum] = p;
    g_leaf_curve[lnum] = true;
}

pub fn clearLeafCurve(lnum: u8) void {
    if (lnum >= anim_leaf_count) return;
    g_leaf_curve[lnum] = false;
    g_leaf_dirty[lnum] = true;
    g_dirty = true;
}

fn leafSlot(lnum: u8, key: []const u8) ?u16 {
    for (k_meta, 0..) |m, i| {
        if (m.leaf.len == 0 or m.lnum != lnum) continue;
        if (std.mem.eql(u8, m.key, key)) return @intCast(i);
    }
    return null;
}

/// Rebuild the whole `set_animation_leaf` call for one leaf from the current
/// values. Rewriting the call keeps the editor simple (a curve can appear or
/// disappear) and still preserves every option the schema knows about.
fn buildLeafCall(a: std.mem.Allocator, lnum: u8) ![]u8 {
    const leaf = blk: {
        for (k_meta) |m| {
            if (m.leaf.len > 0 and m.lnum == lnum) break :blk m.leaf;
        }
        return error.NoLeaf;
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "zl.set_animation_leaf(\"");
    try out.appendSlice(a, leaf);
    try out.appendSlice(a, "\", { ");
    const keys = [_][]const u8{ "enabled", "duration", "easing", "style", "percent" };
    for (keys, 0..) |key, k| {
        const slot = leafSlot(lnum, key) orelse continue;
        if (k > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, key);
        try out.appendSlice(a, " = ");
        var buf: [512]u8 = undefined;
        const lit = if (k_meta[slot].kind == .list) formatList(&buf, g_values[slot].text) else formatLiteral(&buf, g_values[slot]);
        try out.appendSlice(a, lit);
    }
    if (g_leaf_curve[lnum]) {
        var cb: [256]u8 = undefined;
        const nums = [_]f64{ g_curve[lnum][0], g_curve[lnum][1], g_curve[lnum][2], g_curve[lnum][3] };
        var nb: [32]u8 = undefined;
        const n0 = formatNumber(&nb, nums[0]);
        var n1b: [32]u8 = undefined;
        const n1 = formatNumber(&n1b, nums[1]);
        var n2b: [32]u8 = undefined;
        const n2 = formatNumber(&n2b, nums[2]);
        var n3b: [32]u8 = undefined;
        const n3 = formatNumber(&n3b, nums[3]);
        const curve = std.fmt.bufPrint(&cb, ", curve = {{ x1 = {s}, y1 = {s}, x2 = {s}, y2 = {s} }}", .{ n0, n1, n2, n3 }) catch "";
        try out.appendSlice(a, curve);
    }
    try out.appendSlice(a, " })\n");
    return out.toOwnedSlice(a);
}

fn hasLeafCall(text: []const u8, lnum: u8) bool {
    const a = std.heap.page_allocator;
    const calls = scanCalls(a, text) catch return false;
    defer a.free(calls);
    for (calls) |c| {
        if (!std.mem.eql(u8, c.name, "set_animation_leaf")) continue;
        const s0 = argSpan(text, c, 0) orelse continue;
        if (argStringEq(text[s0.start..s0.end], leafKey(lnum))) return true;
    }
    return false;
}

/// Replace the last call for `leaf`, or append one when absent.
fn rewriteLeafCall(a: std.mem.Allocator, text: []const u8, lnum: u8, call: []const u8) ![]u8 {
    const calls = try scanCalls(a, text);
    var last: ?Call = null;
    for (calls) |c| {
        if (!std.mem.eql(u8, c.name, "set_animation_leaf")) continue;
        const s0 = argSpan(text, c, 0) orelse continue;
        if (!argStringEq(text[s0.start..s0.end], leafKey(lnum))) continue;
        last = c;
    }
    if (last) |c| {
        const close = callClose(text, c) orelse return try appendLeafLine(a, text, call);
        return try replaceSpan(a, text, c.start, close + 1, std.mem.trimEnd(u8, call, "\n"));
    }
    return try appendLeafLine(a, text, call);
}

fn leafKey(lnum: u8) []const u8 {
    for (k_meta) |m| {
        if (m.leaf.len > 0 and m.lnum == lnum) return m.leaf;
    }
    return "";
}

fn appendLeafLine(a: std.mem.Allocator, text: []const u8, call: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    if (text.len > 0) try out.append(a, '\n');
    try out.appendSlice(a, call);
    return out.toOwnedSlice(a);
}

// Write.

/// Write every pending edit back to its Lua file, then ask Zoolander to
/// reload. A field with no setter call gets a new call appended to the module
/// that owns the setter (e.g. `set_animation_leaf` → `animations.lua`), falling
/// back to `init.lua` when no module matches.
pub fn commit(alloc: std.mem.Allocator, io: std.Io) void {
    if (!g_dirty) return;

    // Any presentation edit belongs to the display group and must be
    // confirmed before it sticks.
    var touches_displays = false;
    for (g_edits, 0..) |maybe, i| {
        if (maybe != null and std.mem.eql(u8, k_meta[i].setter, "set_presentation")) {
            touches_displays = true;
            break;
        }
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var texts: std.ArrayListUnmanaged([]u8) = .empty;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (g_files.items) |f| {
        const copy = a.dupe(u8, f.text) catch continue;
        texts.append(a, copy) catch continue;
        paths.append(a, f.path) catch continue;
    }

    var any = false;
    for (g_edits, 0..) |maybe, i| {
        const value = maybe orelse continue;
        const m = k_meta[i];
        // Leaf slots are written once per leaf below, rebuilding the whole
        // call so a curve table can appear or disappear cleanly.
        if (m.leaf.len > 0) continue;
        var lit_buf: [512]u8 = undefined;
        const lit = if (m.kind == .list) formatList(&lit_buf, value.text) else formatLiteral(&lit_buf, value);
        var applied = false;
        const is_flag = m.kind == .flag;
        for (texts.items, 0..) |old, ti| {
            const edited = if (is_flag)
                editFlag(a, old, m.setter, lit) catch null
            else if (m.leaf.len > 0)
                editLeaf(a, old, m.leaf, m.key, lit) catch null
            else if (m.positional)
                editArgAt(a, old, m.setter, m.arg_index, lit) catch null
            else
                editText(a, old, m.setter, m.key, lit) catch null;
            if (edited) |new| {
                texts.items[ti] = new;
                applied = true;
                break;
            }
        }
        if (!applied) {
            // No call anywhere: append to the module that owns this setter,
            // falling back to init.lua when no module matches.
            const dir_path = configDir(a) catch continue;
            std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
            const target = moduleForSetter(m.setter);
            var found: ?usize = null;
            for (paths.items, 0..) |p, pi| {
                if (std.mem.endsWith(u8, p, target)) found = pi;
            }
            if (found) |fi| {
                const new = if (is_flag)
                    appendFlagCall(a, texts.items[fi], m.setter, lit) catch continue
                else if (m.leaf.len > 0)
                    appendLeafCall(a, texts.items[fi], m.leaf, m.key, lit) catch continue
                else if (m.positional)
                    appendArgAtCall(a, texts.items[fi], m.setter, m.arg_index, lit) catch continue
                else
                    appendCall(a, texts.items[fi], m.setter, m.key, lit) catch continue;
                texts.items[fi] = new;
            } else {
                const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, target }) catch continue;
                const new = if (is_flag)
                    appendFlagCall(a, "", m.setter, lit) catch continue
                else if (m.positional)
                    appendArgAtCall(a, "", m.setter, m.arg_index, lit) catch continue
                else
                    appendCall(a, "", m.setter, m.key, lit) catch continue;
                paths.append(a, path) catch continue;
                texts.append(a, new) catch continue;
            }
            applied = true;
        }
        if (applied) any = true;
    }

    // Animation leaves: one rebuilt call per dirty leaf.
    for (g_leaf_dirty, 0..) |dirty, lnum| {
        if (!dirty) continue;
        const call = buildLeafCall(a, @intCast(lnum)) catch continue;
        var applied = false;
        for (texts.items, 0..) |old, ti| {
            if (!hasLeafCall(old, @intCast(lnum))) continue;
            texts.items[ti] = rewriteLeafCall(a, old, @intCast(lnum), call) catch continue;
            applied = true;
            break;
        }
        if (!applied) {
            const dir_path = configDir(a) catch continue;
            std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
            const target = moduleForSetter("set_animation_leaf");
            var found: ?usize = null;
            for (paths.items, 0..) |p, pi| {
                if (std.mem.endsWith(u8, p, target)) found = pi;
            }
            if (found) |fi| {
                texts.items[fi] = appendLeafLine(a, texts.items[fi], call) catch continue;
            } else {
                const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, target }) catch continue;
                paths.append(a, path) catch continue;
                texts.append(a, call) catch continue;
            }
        }
        any = true;
    }

    if (any) {
        for (texts.items, 0..) |text, i| {
            const path = paths.items[i];
            var unchanged = false;
            for (g_files.items) |f| {
                if (std.mem.eql(u8, f.path, path) and std.mem.eql(u8, f.text, text)) {
                    unchanged = true;
                    break;
                }
            }
            if (unchanged) continue;
            if (touches_displays) captureBackup(path, io);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |e| {
                logz.log("zoolander-data: cannot write {s}: {s}", .{ path, @errorName(e) });
                setReloadError("Could not write the Zoolander config");
                continue;
            };
            logz.log("zoolander-data: wrote {s} ({d} bytes)", .{ path, text.len });
        }
        if (touches_displays) writeMarker(io);
        reload(alloc, io);
        if (touches_displays) {
            g_confirm_pending = true;
            g_confirm_deadline_ms = nowMs() + @as(i64, confirm_seconds) * 1000;
        }
    }

    load(io);
}

/// How long one `reload` request may take. Zoolander evaluates the whole
/// config before it answers, so this is generous.
const reload_timeout_ms: i32 = 8000;

var g_reload_err_buf: [256]u8 = undefined;
var g_reload_err_len: usize = 0;

/// The compositor's last refusal (`ERR ...`) or a transport problem, or null
/// when the last reload succeeded. Lets the UI say why a change did not land.
pub fn lastReloadError() ?[]const u8 {
    return if (g_reload_err_len == 0) null else g_reload_err_buf[0..g_reload_err_len];
}

fn setReloadError(msg: []const u8) void {
    const trimmed = std.mem.trim(u8, msg, " \t\r\n");
    const n = @min(trimmed.len, g_reload_err_buf.len);
    @memcpy(g_reload_err_buf[0..n], trimmed[0..n]);
    g_reload_err_len = n;
}

/// `$XDG_RUNTIME_DIR/zoolander-<WAYLAND_DISPLAY>.sock`, the same socket
/// `zoolanderctl` talks to. `WAYLAND_DISPLAY` may be an absolute path; the
/// socket is named after its last component.
fn controlSocketPath(buf: []u8) ?[]const u8 {
    const rt = envStr("XDG_RUNTIME_DIR") orelse return null;
    const wd = envStr("WAYLAND_DISPLAY") orelse return null;
    const base = if (std.mem.lastIndexOfScalar(u8, wd, '/')) |i| wd[i + 1 ..] else wd;
    if (base.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/zoolander-{s}.sock", .{ rt, base }) catch null;
}

const ReloadOutcome = enum { ok, refused, unreachable_socket };

/// Send `reload` straight to the control socket. This does not depend on
/// `zoolanderctl` being on PATH or on `nc` supporting `-U -N`, and it reads
/// the compositor's verdict so a refused config is not silent.
fn reloadViaSocket(alloc: std.mem.Allocator) ReloadOutcome {
    var path_buf: [512]u8 = undefined;
    const path = controlSocketPath(&path_buf) orelse return .unreachable_socket;
    const fd = sock.createStream(false) catch return .unreachable_socket;
    defer sock.closeFd(fd);
    if (sock.connectPath(fd, path)) |e| {
        logz.log("zoolander-data: connect {s} failed: {s}", .{ path, @tagName(e) });
        return .unreachable_socket;
    }
    sock.sendAll(fd, "reload\n") catch return .unreachable_socket;
    // Same as `nc -N`: tell the compositor the command is complete.
    _ = linux.shutdown(fd, linux.SHUT.WR);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [1024]u8 = undefined;
    while (out.items.len < 64 * 1024) {
        var pfd = std.posix.pollfd{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        const ready = std.posix.poll(@as(*[1]std.posix.pollfd, &pfd)[0..], reload_timeout_ms) catch break;
        if (ready <= 0) {
            logz.log("zoolander-data: reload timed out waiting for the compositor", .{});
            break;
        }
        const rc = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) break;
        if (rc == 0) break;
        out.appendSlice(alloc, buf[0..rc]) catch break;
    }

    // Line 1 is the greeting; line 2 is `OK ...` or `ERR <message>`.
    var it = std.mem.splitScalar(u8, out.items, '\n');
    _ = it.next();
    const verdict = std.mem.trim(u8, it.next() orelse "", " \t\r");
    if (std.mem.startsWith(u8, verdict, "OK")) {
        logz.log("zoolander-data: reload ok ({s})", .{verdict});
        return .ok;
    }
    if (verdict.len == 0) {
        // Connected but no verdict: treat as a transport problem so the
        // fallback still runs.
        logz.log("zoolander-data: reload gave no verdict ({d} bytes)", .{out.items.len});
        return .unreachable_socket;
    }
    logz.log("zoolander-data: reload refused: {s}", .{verdict});
    setReloadError(verdict);
    return .refused;
}

/// Ask Zoolander to reload its config. Tries the control socket first and
/// falls back to the `zoolanderctl` script. A missing compositor or tool is
/// harmless (the files are already on disk and Zoolander also watches the
/// directory), but every outcome is logged to `~/EH-logs`.
pub fn reload(alloc: std.mem.Allocator, io: std.Io) void {
    g_reload_err_len = 0;
    switch (reloadViaSocket(alloc)) {
        .ok, .refused => return,
        .unreachable_socket => {},
    }
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "zoolanderctl", "reload" },
    }) catch |e| {
        logz.log("zoolander-data: zoolanderctl reload could not run: {s}", .{@errorName(e)});
        setReloadError("Zoolander control socket not reachable");
        return;
    };
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    const failed = switch (res.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        const detail = if (res.stdout.len > 0) res.stdout else res.stderr;
        logz.log("zoolander-data: zoolanderctl reload failed: {s}", .{std.mem.trim(u8, detail, " \t\r\n")});
        setReloadError(if (detail.len > 0) detail else "zoolanderctl reload failed");
    } else {
        logz.log("zoolander-data: zoolanderctl reload ok", .{});
    }
}

// Tests.

test "zoolander-data: literal edit preserves the rest of the file" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\-- keep me
        \\zl.set_window_style({
        \\    gaps_in = 3, -- inner
        \\    shadow = { enabled = false, range = 35 },
        \\    rounding = 20,
        \\})
        \\zl.set_blur({ enabled = true, size = 8 })
    ;
    const out = (try editText(a, src, "set_window_style", "gaps_in", "12")).?;
    try t.expect(std.mem.indexOf(u8, out, "gaps_in = 12") != null);
    try t.expect(std.mem.indexOf(u8, out, "-- keep me") != null);
    try t.expect(std.mem.indexOf(u8, out, "-- inner") != null);
    const nested = (try editText(a, out, "set_window_style", "shadow.enabled", "true")).?;
    try t.expect(std.mem.indexOf(u8, nested, "shadow = { enabled = true") != null);
    const inserted = (try editText(a, nested, "set_window_style", "border_size", "4")).?;
    try t.expect(std.mem.indexOf(u8, inserted, "border_size = 4") != null);
    const fresh = (try editText(a, inserted, "set_blur", "noise", "0.02")).?;
    try t.expect(std.mem.indexOf(u8, fresh, "noise = 0.02") != null);
    try t.expect(try editText(a, fresh, "set_dim", "inactive", "true") == null);
}

test "zoolander-data: append creates a call when the setter is absent" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try appendCall(a, "", "set_presentation", "vrr", "\"always\"");
    try t.expect(std.mem.indexOf(u8, out, "zl.set_presentation({") != null);
    try t.expect(std.mem.indexOf(u8, out, "vrr = \"always\",") != null);
}

test "zoolander-data: the display confirmation keeps or expires" {
    const t = std.testing;
    keep(std.testing.io);
    g_confirm_pending = true;
    g_confirm_deadline_ms = nowMs() + 15_000;
    try t.expect(confirmPending());
    try t.expect(confirmRemaining() > 0);
    keep(std.testing.io);
    try t.expect(!confirmPending());
    try t.expectEqual(@as(u32, 0), confirmRemaining());
}

test "zoolander-data: defaults mirror the schema" {
    const t = std.testing;
    const vals = initValues();
    try t.expectEqual(@as(f64, 0.0117), vals[46].number);
    try t.expectEqual(false, vals[0].boolean);
    try t.expectEqualStrings("quarter", vals[45].text);
}

test "zoolander-data: bare-call flags rewrite their boolean argument" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\zl.set_reduced_motion(false)
        \\zl.set_animations_enabled( true )
    ;
    const off = (try editFlag(a, src, "set_reduced_motion", "true")).?;
    try t.expect(std.mem.indexOf(u8, off, "zl.set_reduced_motion(true)") != null);
    const on = (try editFlag(a, off, "set_animations_enabled", "false")).?;
    try t.expect(std.mem.indexOf(u8, on, "zl.set_animations_enabled( false)") != null);
    try t.expect(try editFlag(a, on, "set_missing_flag", "true") == null);
    const appended = try appendFlagCall(a, "", "set_reduced_motion", "true");
    try t.expectEqualStrings("\nzl.set_reduced_motion(true)\n", appended);
}

test "zoolander-data: positional setters rewrite only their first argument" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\zl.set_layout("dwindle", 0.62)
    ;
    const out = (try editArgText(a, src, "set_layout", "\"scrolling\"")).?;
    try t.expectEqualStrings("zl.set_layout(\"scrolling\", 0.62)", out);
    try t.expect(try editArgText(a, out, "set_missing_layout", "\"grid\"") == null);
    try t.expectEqualStrings("\nzl.set_layout(\"grid\")\n", try appendArgCall(a, "", "set_layout", "\"grid\""));
}

test "zoolander-data: positional setters edit later arguments and fill gaps" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Editing an existing later argument keeps the others untouched.
    const src = "zl.set_layout(\"dwindle\", 0.6, 1, \"vertical\")\n";
    const ratio = (try editArgAt(a, src, "set_layout", 1, "0.5")).?;
    try t.expectEqualStrings("zl.set_layout(\"dwindle\", 0.5, 1, \"vertical\")\n", ratio);
    const axis = (try editArgAt(a, ratio, "set_layout", 3, "\"horizontal\"")).?;
    try t.expectEqualStrings("zl.set_layout(\"dwindle\", 0.5, 1, \"horizontal\")\n", axis);

    // Appending a missing argument uses schema defaults for the gaps.
    const one = "zl.set_layout(\"dwindle\")";
    try t.expectEqualStrings(
        "zl.set_layout(\"dwindle\", 0.5)",
        (try editArgAt(a, one, "set_layout", 1, "0.5")).?,
    );
    try t.expectEqualStrings(
        "zl.set_layout(\"dwindle\", 0.6, 1, \"vertical\")",
        (try editArgAt(a, one, "set_layout", 3, "\"vertical\"")).?,
    );

    // A brand-new call also fills the preceding arguments.
    try t.expectEqualStrings(
        "\nzl.set_layout(\"master_stack\", 0.6, 2)\n",
        try appendArgAtCall(a, "", "set_layout", 2, "2"),
    );
}

test "zoolander-data: list values bridge Lua tables and comma text" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const meta = Meta{ .setter = "set_scrolling", .key = "width_presets", .kind = .list };
    const v = parseValue(a, meta, "{ 0.333, 0.667, 1 }");
    try t.expectEqualStrings("0.333, 0.667, 1", v.text);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("{ 0.333, 0.667, 1 }", formatList(&buf, "0.333, 0.667, 1"));
    try t.expectEqualStrings("{ \"a\", 2 }", formatList(&buf, "a, 2"));
}
