//! Hyprland config key table — **generated, do not hand-edit**.
//!
//! Emitted from the C++ data layer (`settings_hyprland_data.{hpp,cpp}`)
//! and the `settings_tab_hyprland/m3` sub-tabs:
//!
//! * `k_keys`    — every key the C++ reads or writes, in the order the
//!                 C++ writer emits them (`std::vector` push order, then
//!                 `write_nested_entries`' alphabetical sub-tables), with
//!                 the `*_val(kv, key, default)` read fallback as the
//!                 default and the write-side conditions (`if (!x.empty())`
//!                 and the `screen_shader_enabled && !screen_shader.empty()`
//!                 gate) as flags. Keys the C++ reads but never writes keep
//!                 `.write = false`.
//! * `k_sections` — the 16 `~/.config/hypr/hyprland/<name>.lua` files and
//!                 the `-- <header> -- managed by Event Horizon` line each
//!                 starts with.
//! * `k_ui`       — the 179 controls the sub-tabs paint, mapping a UI slot
//!                 (the `hypr_*` `Field` enum value) to its key plus the
//!                 value transform: `ui = scale * real + offset`, an index
//!                 into `labels` for the string keys the C++ paints as
//!                 `value_labels[val - lo]` sliders, and the `%d %%` pill
//!                 format.
//!
//! Regenerate with the port's extraction scripts; nothing here is written
//! by hand except the comment text above.
const std = @import("std");

pub const Kind = enum { boolean, integer, number, text };

pub const Value = union(Kind) {
    boolean: bool,
    integer: i32,
    number: f64,
    text: []const u8,
};

pub const Key = struct {
    /// Dotted, relative to the section root (C++ `parse_lua_kv` skips the
    /// first non-empty table frame).
    key: []const u8,
    kind: Kind,
    default: Value,
    /// C++ emits the key only when the string is non-empty.
    omit_empty: bool = false,
    /// C++ emits the key only when this sibling bool is true as well.
    gate: ?u16 = null,
    /// Read by the C++ but never written back (dropped on save, exactly
    /// like the C++ writer, which regenerates each file from its struct).
    write: bool = true,
    /// Written as `"' + value + '"` instead of `escape_lua(value)` -- the
    /// C++ does this for exactly one key (the Layout combo).
    quote: bool = false,
};

pub const Section = struct {
    name: []const u8,
    /// Whole first line of the file the C++ writes.
    header: []const u8,
    first: u16,
    len: u16,
};

/// Pill text for a slider value (C++ `fmt` argument).
pub const Fmt = enum { plain, percent };

pub const UiSlot = struct {
    key: u16,
    scale: i32 = 1,
    offset: i32 = 0,
    /// The key stores text and the UI shows `labels[index]`; the C++
    /// computes the index in paint and writes `labels[index]` back.
    indexed: bool = false,
    /// C++ `value_labels[val - lo]` (display table for int keys, storage
    /// table for the indexed text keys).
    labels: []const []const u8 = &.{},
    fmt: Fmt = .plain,
};

pub const k_keys = [_]Key{
    // -- general --
    .{ .key = "border_size", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "gaps_in", .kind = .integer, .default = .{ .integer = 5 }, },
    .{ .key = "gaps_out", .kind = .integer, .default = .{ .integer = 20 }, },
    .{ .key = "float_gaps", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "gaps_workspaces", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "layout", .kind = .text, .default = .{ .text = "dwindle" }, .quote = true, },
    .{ .key = "allow_tearing", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "resize_on_border", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "snap.enabled", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "snap.window_gap", .kind = .integer, .default = .{ .integer = 10 }, },
    .{ .key = "snap.monitor_gap", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "snap.border_overlap", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "snap.respect_gaps", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "no_focus_fallback", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "extend_border_grab_area", .kind = .integer, .default = .{ .integer = 15 }, },
    .{ .key = "hover_icon_on_border", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "resize_corner", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "modal_parent_blocking", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "locale", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "col.active_border", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "col.inactive_border", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "col.nogroup_border", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "col.nogroup_border_active", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    // -- decoration --
    .{ .key = "rounding", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "rounding_power", .kind = .number, .default = .{ .number = 2.0 }, },
    .{ .key = "active_opacity", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "inactive_opacity", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "fullscreen_opacity", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "dim_modal", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "dim_inactive", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "dim_strength", .kind = .number, .default = .{ .number = 0.5 }, },
    .{ .key = "dim_special", .kind = .number, .default = .{ .number = 0.2 }, },
    .{ .key = "dim_around", .kind = .number, .default = .{ .number = 0.4 }, },
    .{ .key = "border_part_of_window", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "blur.enabled", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "blur.xray", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "blur.special", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "blur.new_optimizations", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "blur.ignore_opacity", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "blur.size", .kind = .integer, .default = .{ .integer = 8 }, },
    .{ .key = "blur.passes", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "blur.noise", .kind = .number, .default = .{ .number = 0.0117 }, },
    .{ .key = "blur.contrast", .kind = .number, .default = .{ .number = 0.8916 }, },
    .{ .key = "blur.brightness", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "blur.vibrancy", .kind = .number, .default = .{ .number = 0.1696 }, },
    .{ .key = "blur.popups", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "blur.popups_ignorealpha", .kind = .number, .default = .{ .number = 0.2 }, },
    .{ .key = "blur.input_methods", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "blur.vibrancy_darkness", .kind = .number, .default = .{ .number = 0.0 }, },
    .{ .key = "blur.input_methods_ignorealpha", .kind = .number, .default = .{ .number = 0.2 }, },
    .{ .key = "shadow.enabled", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "shadow.range", .kind = .integer, .default = .{ .integer = 4 }, },
    .{ .key = "shadow.render_power", .kind = .integer, .default = .{ .integer = 3 }, },
    .{ .key = "shadow.sharp", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "shadow.offset", .kind = .text, .default = .{ .text = "0, 0" }, },
    .{ .key = "shadow.scale", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "shadow.color", .kind = .text, .default = .{ .text = "0xee1a1a1a" }, .omit_empty = true, },
    .{ .key = "shadow.color_inactive", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "glow.enabled", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "glow.range", .kind = .integer, .default = .{ .integer = 10 }, },
    .{ .key = "glow.render_power", .kind = .integer, .default = .{ .integer = 3 }, },
    .{ .key = "glow.color", .kind = .text, .default = .{ .text = "0xee33ccff" }, .omit_empty = true, },
    .{ .key = "glow.color_inactive", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "motion_blur.enabled", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "motion_blur.samples", .kind = .integer, .default = .{ .integer = 7 }, },
    .{ .key = "screen_shader", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, .gate = 66, },
    .{ .key = "screen_shader_enabled", .kind = .boolean, .default = .{ .boolean = false }, .write = false, },
    // -- input --
    .{ .key = "kb_layout", .kind = .text, .default = .{ .text = "us" }, },
    .{ .key = "kb_variant", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "kb_options", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "kb_rules", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "kb_model", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "kb_file", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "numlock_by_default", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "repeat_delay", .kind = .integer, .default = .{ .integer = 600 }, },
    .{ .key = "repeat_rate", .kind = .integer, .default = .{ .integer = 25 }, },
    .{ .key = "sensitivity", .kind = .number, .default = .{ .number = 0.0 }, },
    .{ .key = "accel_profile", .kind = .text, .default = .{ .text = "adaptive" }, },
    .{ .key = "scroll_method", .kind = .text, .default = .{ .text = "2fg" }, },
    .{ .key = "natural_scroll", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "resolve_binds_by_sym", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "force_no_accel", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "rotation", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "left_handed", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "scroll_points", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "scroll_button", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "scroll_button_lock", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "scroll_factor", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "follow_mouse_shrink", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "follow_mouse_threshold", .kind = .number, .default = .{ .number = 0.0 }, },
    .{ .key = "focus_on_close", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "off_window_axis_events", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "emulate_discrete_scroll", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "touchpad.natural_scroll", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "touchpad.disable_while_typing", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "touchpad.tap_to_click", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "touchpad.clickfinger_behavior", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "touchpad.scroll_factor", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "touchpad.middle_button_emulation", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "touchpad.tap_button_map", .kind = .text, .default = .{ .text = "" }, },
    .{ .key = "touchpad.drag_lock", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "touchpad.tap_and_drag", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "touchpad.flip_x", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "touchpad.flip_y", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "touchpad.drag_3fg", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "touchdevice.transform", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "touchdevice.output", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "touchdevice.enabled", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "virtualkeyboard.share_states", .kind = .integer, .default = .{ .integer = 2 }, },
    .{ .key = "virtualkeyboard.release_pressed_on_close", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "tablet.transform", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "tablet.output", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "tablet.region_position", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "tablet.absolute_region_position", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "tablet.region_size", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "tablet.relative_input", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "tablet.left_handed", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "tablet.active_area_size", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "tablet.active_area_position", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "tablettool.eraser_button_mode", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "tablettool.eraser_button_override", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "tablettool.pressure_range_min", .kind = .number, .default = .{ .number = -1.0 }, },
    .{ .key = "tablettool.pressure_range_max", .kind = .number, .default = .{ .number = -1.0 }, },
    .{ .key = "special_fallthrough", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "follow_mouse", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "float_switch_override_focus", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "mouse_refocus", .kind = .boolean, .default = .{ .boolean = true }, },
    // -- binds --
    .{ .key = "scroll_event_delay", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "focus_preferred_method", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "workspace_back_and_forth", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "allow_workspace_cycles", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "pass_mouse_when_bound", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "hide_special_on_workspace_change", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "workspace_center_on", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "ignore_group_lock", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "movefocus_cycles_fullscreen", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "movefocus_cycles_groupfirst", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "window_direction_monitor_fallback", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "disable_keybind_grabbing", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "allow_pin_fullscreen", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "drag_threshold", .kind = .integer, .default = .{ .integer = 0 }, },
    // -- dwindle --
    .{ .key = "force_split", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "preserve_split", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "smart_split", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "smart_resizing", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "permanent_direction_override", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "special_scale_factor", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "split_width_multiplier", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "use_active_for_splits", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "default_split_ratio", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "split_bias", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "precise_mouse_move", .kind = .boolean, .default = .{ .boolean = false }, },
    // -- master --
    .{ .key = "allow_small_split", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "special_scale_factor", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "mfact", .kind = .number, .default = .{ .number = 0.55 }, },
    .{ .key = "new_status", .kind = .text, .default = .{ .text = "slave" }, },
    .{ .key = "new_on_top", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "new_on_active", .kind = .text, .default = .{ .text = "none" }, },
    .{ .key = "orientation", .kind = .text, .default = .{ .text = "left" }, },
    .{ .key = "slave_count_for_center_master", .kind = .integer, .default = .{ .integer = 2 }, },
    .{ .key = "center_master_fallback", .kind = .text, .default = .{ .text = "left" }, },
    .{ .key = "smart_resizing", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "drop_at_cursor", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "always_keep_position", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "focus_master_on_close", .kind = .boolean, .default = .{ .boolean = false }, },
    // -- scrolling --
    .{ .key = "column_width", .kind = .number, .default = .{ .number = 0.5 }, },
    .{ .key = "direction", .kind = .text, .default = .{ .text = "right" }, },
    .{ .key = "fullscreen_on_one_column", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "follow_focus", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "follow_min_visible", .kind = .number, .default = .{ .number = 0.4 }, },
    .{ .key = "focus_fit_method", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "explicit_column_widths", .kind = .text, .default = .{ .text = "0.333,0.5,0.62,0.75,1.0" }, },
    .{ .key = "wrap_focus", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "wrap_swapcol", .kind = .boolean, .default = .{ .boolean = true }, },
    // -- animations --
    .{ .key = "enabled", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "workspace_wraparound", .kind = .boolean, .default = .{ .boolean = false }, },
    // -- misc --
    .{ .key = "vrr", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "animate_manual_resizes", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "animate_mouse_windowdragging", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "enable_swallow", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "swallow_regex", .kind = .text, .default = .{ .text = "(foot|kitty|allacritty|Alacritty)" }, },
    .{ .key = "swallow_exception_regex", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "disable_hyprland_logo", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "disable_splash_rendering", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "disable_scale_notification", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "col.splash", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "force_default_wallpaper", .kind = .integer, .default = .{ .integer = -1 }, },
    .{ .key = "allow_session_lock_restore", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "initial_workspace_tracking", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "disable_autoreload", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "background_color", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "font_family", .kind = .text, .default = .{ .text = "Sans" }, },
    .{ .key = "splash_font_family", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "mouse_move_enables_dpms", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "key_press_enables_dpms", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "name_vk_after_proc", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "always_follow_on_dnd", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "layers_hog_keyboard_focus", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "focus_on_activate", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "mouse_move_focuses_monitor", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "session_lock_xray", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "session_lock_blur", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "close_special_on_empty", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "on_focus_under_fullscreen", .kind = .integer, .default = .{ .integer = 2 }, },
    .{ .key = "exit_window_retains_fullscreen", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "initial_workspace_token_timeout", .kind = .integer, .default = .{ .integer = 10 }, },
    .{ .key = "render_unfocused_fps", .kind = .integer, .default = .{ .integer = 15 }, },
    .{ .key = "disable_xdg_env_checks", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "disable_hyprland_guiutils_check", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "lockdead_screen_delay", .kind = .integer, .default = .{ .integer = 1000 }, },
    .{ .key = "enable_anr_dialog", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "anr_missed_pings", .kind = .integer, .default = .{ .integer = 5 }, },
    .{ .key = "size_limits_tiled", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "screencopy_force_8b", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "disable_watchdog_warning", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "middle_click_paste", .kind = .boolean, .default = .{ .boolean = true }, },
    // -- render --
    .{ .key = "new_render_scheduling", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "expand_undersized_textures", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "direct_scanout", .kind = .integer, .default = .{ .integer = 2 }, },
    .{ .key = "cm_enabled", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "send_content_type", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "fp16_sdr_tf", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "xp_mode", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "ctm_animation", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "cm_auto_hdr", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "non_shader_cm", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "non_shader_cm_interop", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "cm_sdr_eotf", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "commit_timing_enabled", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "use_fp16", .kind = .integer, .default = .{ .integer = 2 }, },
    .{ .key = "keep_unmodified_copy", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "icc_vcgt_enabled", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "use_shader_blur_blend", .kind = .boolean, .default = .{ .boolean = false }, },
    // -- cursor --
    .{ .key = "invisible", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "no_hardware_cursors", .kind = .integer, .default = .{ .integer = 2 }, },
    .{ .key = "enable_hyprcursor", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "sync_gsettings_theme", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "min_refresh_rate", .kind = .integer, .default = .{ .integer = 24 }, },
    .{ .key = "hotspot_padding", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "inactive_timeout", .kind = .number, .default = .{ .number = 0.0 }, },
    .{ .key = "no_warps", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "persistent_warps", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "warp_on_change_workspace", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "warp_on_toggle_special", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "default_monitor", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "zoom_factor", .kind = .number, .default = .{ .number = 1.0 }, },
    .{ .key = "zoom_rigid", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "zoom_detached_camera", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "hide_on_key_press", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "hide_on_touch", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "hide_on_tablet", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "warp_back_after_non_mouse_input", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "zoom_disable_aa", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "no_break_fs_vrr", .kind = .integer, .default = .{ .integer = 2 }, },
    .{ .key = "use_cpu_buffer", .kind = .integer, .default = .{ .integer = 2 }, },
    .{ .key = "ecosystem.no_update_news", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "ecosystem.no_donation_nag", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "ecosystem.enforce_permissions", .kind = .boolean, .default = .{ .boolean = false }, },
    // -- gestures --
    .{ .key = "workspace_swipe_distance", .kind = .integer, .default = .{ .integer = 300 }, },
    .{ .key = "workspace_swipe_create_new", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "workspace_swipe_touch", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "workspace_swipe_invert", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "workspace_swipe_touch_invert", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "workspace_swipe_min_speed_to_force", .kind = .integer, .default = .{ .integer = 300 }, },
    .{ .key = "workspace_swipe_cancel_ratio", .kind = .number, .default = .{ .number = 0.2 }, },
    .{ .key = "workspace_swipe_direction_lock", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "workspace_swipe_direction_lock_threshold", .kind = .integer, .default = .{ .integer = 10 }, },
    .{ .key = "workspace_swipe_forever", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "workspace_swipe_use_r", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "close_max_timeout", .kind = .integer, .default = .{ .integer = 1000 }, },
    .{ .key = "scrolling.move_snap_to_grid", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "scrolling.move_snap_cursor", .kind = .boolean, .default = .{ .boolean = true }, },
    // -- group --
    .{ .key = "auto_group", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "insert_after_current", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "focus_removed_window", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "drag_into_group", .kind = .integer, .default = .{ .integer = 1 }, },
    .{ .key = "merge_groups_on_drag", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "merge_groups_on_groupbar", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "merge_floated_into_tiled_on_groupbar", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "group_on_movetoworkspace", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "col.border_active", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "col.border_inactive", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "col.border_locked_active", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    .{ .key = "col.border_locked_inactive", .kind = .text, .default = .{ .text = "" }, .omit_empty = true, },
    // -- xwayland --
    .{ .key = "enabled", .kind = .boolean, .default = .{ .boolean = true }, },
    .{ .key = "use_nearest_neighbor", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "force_zero_scaling", .kind = .boolean, .default = .{ .boolean = false }, },
    .{ .key = "create_abstract_socket", .kind = .boolean, .default = .{ .boolean = false }, },
    // -- opengl --
    .{ .key = "nvidia_anti_flicker", .kind = .boolean, .default = .{ .boolean = true }, },
    // -- quirks --
    .{ .key = "prefer_hdr", .kind = .integer, .default = .{ .integer = 0 }, },
    .{ .key = "skip_non_kms_dmabuf_formats", .kind = .boolean, .default = .{ .boolean = false }, },
};

pub const k_sections = [_]Section{
    .{ .name = "general", .header = "-- General settings -- managed by Event Horizon", .first = 0, .len = 23 },
    .{ .name = "decoration", .header = "-- Decoration settings -- managed by Event Horizon", .first = 23, .len = 44 },
    .{ .name = "input", .header = "-- Input settings -- managed by Event Horizon", .first = 67, .len = 60 },
    .{ .name = "binds", .header = "-- Bind settings -- managed by Event Horizon", .first = 127, .len = 14 },
    .{ .name = "dwindle", .header = "-- Dwindle layout settings -- managed by Event Horizon", .first = 141, .len = 11 },
    .{ .name = "master", .header = "-- Master layout settings -- managed by Event Horizon", .first = 152, .len = 13 },
    .{ .name = "scrolling", .header = "-- Scrolling layout settings -- managed by Event Horizon", .first = 165, .len = 9 },
    .{ .name = "animations", .header = "-- Animation settings -- managed by Event Horizon", .first = 174, .len = 2 },
    .{ .name = "misc", .header = "-- Misc settings -- managed by Event Horizon", .first = 176, .len = 40 },
    .{ .name = "render", .header = "-- Render settings -- managed by Event Horizon", .first = 216, .len = 17 },
    .{ .name = "cursor", .header = "-- Cursor settings -- managed by Event Horizon", .first = 233, .len = 25 },
    .{ .name = "gestures", .header = "-- Gesture settings -- managed by Event Horizon", .first = 258, .len = 14 },
    .{ .name = "group", .header = "-- Group settings -- managed by Event Horizon", .first = 272, .len = 12 },
    .{ .name = "xwayland", .header = "-- Xwayland settings -- managed by Event Horizon", .first = 284, .len = 4 },
    .{ .name = "opengl", .header = "-- OpenGL settings -- managed by Event Horizon", .first = 288, .len = 1 },
    .{ .name = "quirks", .header = "-- Quirks settings -- managed by Event Horizon", .first = 289, .len = 2 },
};

// generated: 179 UI slots -> key index + value transform
pub const k_ui = [_]UiSlot{
    .{ .key = 174 },  // 0: animations.enabled
    .{ .key = 175 },  // 1: animations.workspace_wraparound
    .{ .key = 129 },  // 2: binds.workspace_back_and_forth
    .{ .key = 130 },  // 3: binds.allow_workspace_cycles
    .{ .key = 127 },  // 4: binds.scroll_event_delay
    .{ .key = 128 },  // 5: binds.focus_preferred_method
    .{ .key = 235 },  // 6: cursor.enable_hyprcursor
    .{ .key = 236 },  // 7: cursor.sync_gsettings_theme
    .{ .key = 248 },  // 8: cursor.hide_on_key_press
    .{ .key = 249 },  // 9: cursor.hide_on_touch
    .{ .key = 250 },  // 10: cursor.hide_on_tablet
    .{ .key = 234, .labels = &.{"disabled", "enabled", "auto"} },  // 11: cursor.no_hardware_cursors
    .{ .key = 246 },  // 12: cursor.zoom_rigid
    .{ .key = 247 },  // 13: cursor.zoom_detached_camera
    .{ .key = 252 },  // 14: cursor.zoom_disable_aa
    .{ .key = 251 },  // 15: cursor.warp_back_after_non_mouse_input
    .{ .key = 253, .labels = &.{"disable", "enable", "auto"} },  // 16: cursor.no_break_fs_vrr
    .{ .key = 254, .labels = &.{"disable", "enable", "auto"} },  // 17: cursor.use_cpu_buffer
    .{ .key = 255 },  // 18: cursor.ecosystem.no_update_news
    .{ .key = 256 },  // 19: cursor.ecosystem.no_donation_nag
    .{ .key = 257 },  // 20: cursor.ecosystem.enforce_permissions
    .{ .key = 23 },  // 21: decoration.rounding
    .{ .key = 24 },  // 22: decoration.rounding_power
    .{ .key = 25, .scale = 100, .fmt = .percent },  // 23: decoration.active_opacity
    .{ .key = 26, .scale = 100, .fmt = .percent },  // 24: decoration.inactive_opacity
    .{ .key = 27, .scale = 100, .fmt = .percent },  // 25: decoration.fullscreen_opacity
    .{ .key = 34 },  // 26: decoration.blur.enabled
    .{ .key = 35 },  // 27: decoration.blur.xray
    .{ .key = 36 },  // 28: decoration.blur.special
    .{ .key = 37 },  // 29: decoration.blur.new_optimizations
    .{ .key = 38 },  // 30: decoration.blur.ignore_opacity
    .{ .key = 45 },  // 31: decoration.blur.popups
    .{ .key = 47 },  // 32: decoration.blur.input_methods
    .{ .key = 39 },  // 33: decoration.blur.size
    .{ .key = 40 },  // 34: decoration.blur.passes
    .{ .key = 41, .scale = 100, .fmt = .percent },  // 35: decoration.blur.noise
    .{ .key = 42, .scale = 100, .fmt = .percent },  // 36: decoration.blur.contrast
    .{ .key = 43, .scale = 100, .fmt = .percent },  // 37: decoration.blur.brightness
    .{ .key = 44, .scale = 100, .fmt = .percent },  // 38: decoration.blur.vibrancy
    .{ .key = 48, .scale = 100, .fmt = .percent },  // 39: decoration.blur.vibrancy_darkness
    .{ .key = 46, .scale = 100, .fmt = .percent },  // 40: decoration.blur.popups_ignorealpha
    .{ .key = 49, .scale = 100, .fmt = .percent },  // 41: decoration.blur.input_methods_ignorealpha
    .{ .key = 28 },  // 42: decoration.dim_modal
    .{ .key = 29 },  // 43: decoration.dim_inactive
    .{ .key = 30, .scale = 100, .fmt = .percent },  // 44: decoration.dim_strength
    .{ .key = 31, .scale = 100, .fmt = .percent },  // 45: decoration.dim_special
    .{ .key = 32, .scale = 100, .fmt = .percent },  // 46: decoration.dim_around
    .{ .key = 50 },  // 47: decoration.shadow.enabled
    .{ .key = 53 },  // 48: decoration.shadow.sharp
    .{ .key = 51 },  // 49: decoration.shadow.range
    .{ .key = 52 },  // 50: decoration.shadow.render_power
    .{ .key = 55, .scale = 100, .fmt = .percent },  // 51: decoration.shadow.scale
    .{ .key = 58 },  // 52: decoration.glow.enabled
    .{ .key = 59 },  // 53: decoration.glow.range
    .{ .key = 60 },  // 54: decoration.glow.render_power
    .{ .key = 63 },  // 55: decoration.motion_blur.enabled
    .{ .key = 64 },  // 56: decoration.motion_blur.samples
    .{ .key = 33 },  // 57: decoration.border_part_of_window
    .{ .key = 142 },  // 58: dwindle.preserve_split
    .{ .key = 143 },  // 59: dwindle.smart_split
    .{ .key = 144 },  // 60: dwindle.smart_resizing
    .{ .key = 148 },  // 61: dwindle.use_active_for_splits
    .{ .key = 145 },  // 62: dwindle.permanent_direction_override
    .{ .key = 151 },  // 63: dwindle.precise_mouse_move
    .{ .key = 141, .labels = &.{"follow mouse", "left", "right"} },  // 64: dwindle.force_split
    .{ .key = 146, .scale = 100, .fmt = .percent },  // 65: dwindle.special_scale_factor
    .{ .key = 147, .scale = 100, .fmt = .percent },  // 66: dwindle.split_width_multiplier
    .{ .key = 149, .scale = 100, .fmt = .percent },  // 67: dwindle.default_split_ratio
    .{ .key = 150, .labels = &.{"directional", "current"} },  // 68: dwindle.split_bias
    .{ .key = 0 },  // 69: general.border_size
    .{ .key = 1 },  // 70: general.gaps_in
    .{ .key = 2 },  // 71: general.gaps_out
    .{ .key = 4 },  // 72: general.gaps_workspaces
    .{ .key = 8 },  // 73: general.snap.enabled
    .{ .key = 11 },  // 74: general.snap.border_overlap
    .{ .key = 12 },  // 75: general.snap.respect_gaps
    .{ .key = 9 },  // 76: general.snap.window_gap
    .{ .key = 10 },  // 77: general.snap.monitor_gap
    .{ .key = 6 },  // 78: general.allow_tearing
    .{ .key = 7 },  // 79: general.resize_on_border
    .{ .key = 15 },  // 80: general.hover_icon_on_border
    .{ .key = 13 },  // 81: general.no_focus_fallback
    .{ .key = 14 },  // 82: general.extend_border_grab_area
    .{ .key = 16 },  // 83: general.resize_corner
    .{ .key = 272 },  // 84: group.auto_group
    .{ .key = 273 },  // 85: group.insert_after_current
    .{ .key = 274 },  // 86: group.focus_removed_window
    .{ .key = 276 },  // 87: group.merge_groups_on_drag
    .{ .key = 277 },  // 88: group.merge_groups_on_groupbar
    .{ .key = 278 },  // 89: group.merge_floated_into_tiled_on_groupbar
    .{ .key = 279 },  // 90: group.group_on_movetoworkspace
    .{ .key = 275, .labels = &.{"disabled", "enabled", "groupbar only"} },  // 91: group.drag_into_group
    .{ .key = 73 },  // 92: input.numlock_by_default
    .{ .key = 80 },  // 93: input.resolve_binds_by_sym
    .{ .key = 81 },  // 94: input.force_no_accel
    .{ .key = 74 },  // 95: input.repeat_delay
    .{ .key = 75 },  // 96: input.repeat_rate
    .{ .key = 82 },  // 97: input.rotation
    .{ .key = 79 },  // 98: input.natural_scroll
    .{ .key = 83 },  // 99: input.left_handed
    .{ .key = 126 },  // 100: input.mouse_refocus
    .{ .key = 86 },  // 101: input.scroll_button_lock
    .{ .key = 76, .scale = 50, .offset = 50 },  // 102: input.sensitivity
    .{ .key = 77, .indexed = true, .labels = &.{"adaptive", "flat", "custom"} },  // 103: input.accel_profile
    .{ .key = 124 },  // 104: input.follow_mouse
    .{ .key = 85 },  // 105: input.scroll_button
    .{ .key = 88 },  // 106: input.follow_mouse_shrink
    .{ .key = 93 },  // 107: input.touchpad.natural_scroll
    .{ .key = 94 },  // 108: input.touchpad.disable_while_typing
    .{ .key = 95 },  // 109: input.touchpad.tap_to_click
    .{ .key = 96 },  // 110: input.touchpad.clickfinger_behavior
    .{ .key = 98 },  // 111: input.touchpad.middle_button_emulation
    .{ .key = 101 },  // 112: input.touchpad.tap_and_drag
    .{ .key = 102 },  // 113: input.touchpad.flip_x
    .{ .key = 103 },  // 114: input.touchpad.flip_y
    .{ .key = 97, .scale = 100 },  // 115: input.touchpad.scroll_factor
    .{ .key = 259 },  // 116: gestures.workspace_swipe_create_new
    .{ .key = 258 },  // 117: gestures.workspace_swipe_distance
    .{ .key = 123 },  // 118: input.special_fallthrough
    .{ .key = 107 },  // 119: input.touchdevice.enabled
    .{ .key = 105 },  // 120: input.touchdevice.transform
    .{ .key = 109 },  // 121: input.virtualkeyboard.release_pressed_on_close
    .{ .key = 108, .labels = &.{"disable", "enable", "only non-IME"} },  // 122: input.virtualkeyboard.share_states
    .{ .key = 113 },  // 123: input.tablet.absolute_region_position
    .{ .key = 115 },  // 124: input.tablet.relative_input
    .{ .key = 116 },  // 125: input.tablet.left_handed
    .{ .key = 110 },  // 126: input.tablet.transform
    .{ .key = 119 },  // 127: input.tablettool.eraser_button_mode
    .{ .key = 120 },  // 128: input.tablettool.eraser_button_override
    .{ .key = 121, .scale = 100 },  // 129: input.tablettool.pressure_range_min
    .{ .key = 122, .scale = 100 },  // 130: input.tablettool.pressure_range_max
    .{ .key = 156 },  // 131: master.new_on_top
    .{ .key = 152 },  // 132: master.allow_small_split
    .{ .key = 161 },  // 133: master.smart_resizing
    .{ .key = 162 },  // 134: master.drop_at_cursor
    .{ .key = 163 },  // 135: master.always_keep_position
    .{ .key = 164 },  // 136: master.focus_master_on_close
    .{ .key = 154, .scale = 100, .fmt = .percent },  // 137: master.mfact
    .{ .key = 153, .scale = 100, .fmt = .percent },  // 138: master.special_scale_factor
    .{ .key = 159 },  // 139: master.slave_count_for_center_master
    .{ .key = 155, .indexed = true, .labels = &.{"master", "slave", "inherit"} },  // 140: master.new_status
    .{ .key = 157, .indexed = true, .labels = &.{"before", "after", "none"} },  // 141: master.new_on_active
    .{ .key = 158, .indexed = true, .labels = &.{"left", "right", "top", "bottom", "center"} },  // 142: master.orientation
    .{ .key = 160, .indexed = true, .labels = &.{"left", "right", "top", "bottom"} },  // 143: master.center_master_fallback
    .{ .key = 189 },  // 144: misc.disable_autoreload
    .{ .key = 183 },  // 145: misc.disable_splash_rendering
    .{ .key = 182 },  // 146: misc.disable_hyprland_logo
    .{ .key = 187 },  // 147: misc.allow_session_lock_restore
    .{ .key = 193 },  // 148: misc.mouse_move_enables_dpms
    .{ .key = 215 },  // 149: misc.middle_click_paste
    .{ .key = 177 },  // 150: misc.animate_manual_resizes
    .{ .key = 178 },  // 151: misc.animate_mouse_windowdragging
    .{ .key = 179 },  // 152: misc.enable_swallow
    .{ .key = 176 },  // 153: misc.vrr
    .{ .key = 186, .labels = &.{"default", "none", "wallpaper 1", "wallpaper 2"} },  // 154: misc.force_default_wallpaper
    .{ .key = 188, .labels = &.{"disable", "workspace", "monitor + workspace"} },  // 155: misc.initial_workspace_tracking
    .{ .key = 206 },  // 156: misc.render_unfocused_fps
    .{ .key = 205 },  // 157: misc.initial_workspace_token_timeout
    .{ .key = 288 },  // 158: opengl.nvidia_anti_flicker
    .{ .key = 290 },  // 159: quirks.skip_non_kms_dmabuf_formats
    .{ .key = 289, .labels = &.{"disable", "prefer hdr", "always hdr"} },  // 160: quirks.prefer_hdr
    .{ .key = 219 },  // 161: render.cm_enabled
    .{ .key = 220 },  // 162: render.send_content_type
    .{ .key = 216 },  // 163: render.new_render_scheduling
    .{ .key = 217 },  // 164: render.expand_undersized_textures
    .{ .key = 232 },  // 165: render.use_shader_blur_blend
    .{ .key = 221, .labels = &.{"monitor", "linear"} },  // 166: render.fp16_sdr_tf
    .{ .key = 229, .labels = &.{"disable", "enable", "auto"} },  // 167: render.use_fp16
    .{ .key = 218 },  // 168: render.direct_scanout
    .{ .key = 167 },  // 169: scrolling.fullscreen_on_one_column
    .{ .key = 168 },  // 170: scrolling.follow_focus
    .{ .key = 172 },  // 171: scrolling.wrap_focus
    .{ .key = 173 },  // 172: scrolling.wrap_swapcol
    .{ .key = 165, .scale = 100, .fmt = .percent },  // 173: scrolling.column_width
    .{ .key = 170 },  // 174: scrolling.focus_fit_method
    .{ .key = 169, .scale = 100, .fmt = .percent },  // 175: scrolling.follow_min_visible
    .{ .key = 166, .indexed = true, .labels = &.{"left", "right", "down", "up"} },  // 176: scrolling.direction
    .{ .key = 284 },  // 177: xwayland.enabled
    .{ .key = 5 },  // 178: general.layout
};

/// AnimEntryMeta (hyprland_anim_common.hpp): `styles` stays a raw
/// comma-separated string, split the way the C++ does at use time.
pub const AnimEntry = struct {
    name: []const u8,
    label: []const u8,
    styles: []const u8,
};

pub const k_anim_entries = [_]AnimEntry{
    .{ .name = "global", .label = "Global", .styles = "" },
    .{ .name = "windows", .label = "Windows", .styles = "" },
    .{ .name = "windowsIn", .label = "Open (Window)", .styles = "slide, slidevert" },
    .{ .name = "windowsOut", .label = "Close (Window)", .styles = "slide, slidevert" },
    .{ .name = "windowsMove", .label = "Move", .styles = "slide, slidevert" },
    .{ .name = "layers", .label = "Layers", .styles = "" },
    .{ .name = "layersIn", .label = "Open (Layer)", .styles = "slide, slidevert, fade" },
    .{ .name = "layersOut", .label = "Close (Layer)", .styles = "slide, slidevert, fade" },
    .{ .name = "fade", .label = "Fade", .styles = "" },
    .{ .name = "fadeIn", .label = "Fade In", .styles = "" },
    .{ .name = "fadeOut", .label = "Fade Out", .styles = "" },
    .{ .name = "fadeSwitch", .label = "Fade Switch", .styles = "" },
    .{ .name = "fadeShadow", .label = "Fade Shadow", .styles = "" },
    .{ .name = "fadeDim", .label = "Fade Dim", .styles = "" },
    .{ .name = "fadeLayers", .label = "Fade Layers", .styles = "" },
    .{ .name = "fadeLayersIn", .label = "Layers In", .styles = "" },
    .{ .name = "fadeLayersOut", .label = "Layers Out", .styles = "" },
    .{ .name = "fadePopups", .label = "Fade Popups", .styles = "" },
    .{ .name = "fadePopupsIn", .label = "Popups In", .styles = "popin" },
    .{ .name = "fadePopupsOut", .label = "Popups Out", .styles = "popout" },
    .{ .name = "fadeDpms", .label = "DPMS", .styles = "" },
    .{ .name = "workspaces", .label = "Workspaces", .styles = "" },
    .{ .name = "workspacesIn", .label = "Switch In", .styles = "slide, slidevert, fade" },
    .{ .name = "workspacesOut", .label = "Switch Out", .styles = "slide, slidevert, fade" },
    .{ .name = "specialWorkspace", .label = "Special Workspace", .styles = "" },
    .{ .name = "specialWorkspaceIn", .label = "Special In", .styles = "slide, slidevert, fade" },
    .{ .name = "specialWorkspaceOut", .label = "Special Out", .styles = "slide, slidevert, fade" },
    .{ .name = "border", .label = "Border", .styles = "" },
    .{ .name = "borderangle", .label = "Border Angle", .styles = "" },
    .{ .name = "zoomFactor", .label = "Zoom Factor", .styles = "" },
    .{ .name = "monitorAdded", .label = "Monitor Added", .styles = "" },
};

/// AnimCategoryInfo + the per-category subtitle painted by the m3 file.
pub const AnimCategory = struct {
    label: []const u8,
    sub: []const u8,
    start: u8,
    count: u8,
};

pub const k_anim_categories = [_]AnimCategory{
    .{ .label = "Global", .sub = "Global animation entry", .start = 0, .count = 1 },
    .{ .label = "Windows && Layers", .sub = "Window and layer surface animations", .start = 1, .count = 7 },
    .{ .label = "Fading", .sub = "Fade effects across surfaces", .start = 8, .count = 13 },
    .{ .label = "Workspaces", .sub = "Workspace switch animations", .start = 21, .count = 6 },
    .{ .label = "Other", .sub = "Border, zoom, and monitor animations", .start = 27, .count = 4 },
};

pub const k_curve_names = [_][]const u8{
    "default", "linear", "overshot", "smooth", "easeInOut", "easeIn", "easeOut", "easeOutCirc", "easeInCirc", "easeOutExpo", "easeInExpo", "easeOutBack", "easeInBack",
};

pub const BezierPreset = struct {
    name: []const u8,
    p1x: f64,
    p1y: f64,
    p2x: f64,
    p2y: f64,
};

pub const k_bezier_presets = [_]BezierPreset{
    .{ .name = "default", .p1x = 0.25, .p1y = 0.1, .p2x = 0.25, .p2y = 1.0 },
    .{ .name = "linear", .p1x = 0.0, .p1y = 0.0, .p2x = 1.0, .p2y = 1.0 },
    .{ .name = "overshot", .p1x = 0.05, .p1y = 0.9, .p2x = 0.1, .p2y = 1.1 },
    .{ .name = "smooth", .p1x = 0.25, .p1y = 0.1, .p2x = 0.25, .p2y = 1.0 },
    .{ .name = "easeInOut", .p1x = 0.42, .p1y = 0.0, .p2x = 0.58, .p2y = 1.0 },
    .{ .name = "easeIn", .p1x = 0.42, .p1y = 0.0, .p2x = 1.0, .p2y = 1.0 },
    .{ .name = "easeOut", .p1x = 0.0, .p1y = 0.0, .p2x = 0.58, .p2y = 1.0 },
    .{ .name = "easeOutCirc", .p1x = 0.0, .p1y = 0.55, .p2x = 0.45, .p2y = 1.0 },
    .{ .name = "easeInCirc", .p1x = 0.55, .p1y = 0.0, .p2x = 1.0, .p2y = 0.45 },
    .{ .name = "easeOutExpo", .p1x = 0.16, .p1y = 1.0, .p2x = 0.3, .p2y = 1.0 },
    .{ .name = "easeInExpo", .p1x = 0.7, .p1y = 0.0, .p2x = 0.84, .p2y = 0.0 },
    .{ .name = "easeOutBack", .p1x = 0.34, .p1y = 1.56, .p2x = 0.64, .p2y = 1.0 },
    .{ .name = "easeInBack", .p1x = 0.36, .p1y = 0.0, .p2x = 0.66, .p2y = -0.56 },
};
