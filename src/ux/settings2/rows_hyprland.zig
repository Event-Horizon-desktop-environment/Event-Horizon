//! Hyprland settings sub-tabs.
//!
//! One entry per child tab, in dispatch order, with every card and row lifted 1:1 from
//! the matching layout groups + card painters:
//! `paintSliderCard` calls -- labels, descriptions, ranges and grouping
//! carried over.
//!
//! Slider pill text is resolved by `hyprland_data.valueText` (the
//! `fmt` / `value_labels[]` tables live in the UI-slot binding), so hypr
//! slider rows leave `unit` empty.
const rows = @import("rows.zig");
const Field = rows.Field;
const Card = rows.Card;

/// Child-tab labels.
pub const child_labels = [_][]const u8{
    "General",   "Decoration", "Input",      "Binds",      "Dwindle",
    "Master",    "Scrolling",  "Animations", "Misc",       "Render",
    "Cursor",    "Group",      "XWayland",   "OpenGL",     "Quirks",
};

/// --- general ---
pub const general = [_]Card{
    .{ .title = "Window && Gaps", .subtitle = "Borders and spacing between windows", .rows = &.{
        .{ .slider = .{ .label = "Border size", .field = Field.hypr_general_border_size, .min = 0, .max = 20, .unit = "" } },
        .{ .slider = .{ .label = "Inner gaps", .field = Field.hypr_general_gaps_in, .min = 0, .max = 50, .unit = "" } },
        .{ .slider = .{ .label = "Outer gaps", .field = Field.hypr_general_gaps_out, .min = 0, .max = 50, .unit = "" } },
        .{ .slider = .{ .label = "Workspace gaps", .field = Field.hypr_general_gaps_workspaces, .min = 0, .max = 50, .unit = "" } },
    } },
    .{ .title = "Snap", .subtitle = "Window snapping behavior", .rows = &.{
        .{ .toggle = .{ .label = "Snap enabled", .desc = "Snap windows to screen edges", .field = Field.hypr_general_snap_enabled } },
        .{ .toggle = .{ .label = "Border overlap", .desc = "Allow windows to overlap snap borders", .field = Field.hypr_general_snap_border_overlap } },
        .{ .toggle = .{ .label = "Respect gaps", .desc = "Respect gap settings when snapping", .field = Field.hypr_general_snap_respect_gaps } },
        .{ .slider = .{ .label = "Window gap", .field = Field.hypr_general_snap_window_gap, .min = 0, .max = 50, .unit = "" } },
        .{ .slider = .{ .label = "Monitor gap", .field = Field.hypr_general_snap_monitor_gap, .min = 0, .max = 50, .unit = "" } },
    } },
    .{ .title = "Tearing", .subtitle = "Tearing behavior", .rows = &.{
        .{ .toggle = .{ .label = "Allow tearing", .desc = "Allow variable refresh rate tearing", .field = Field.hypr_general_allow_tearing } },
    } },
    .{ .title = "Border Behavior", .subtitle = "Resize and focus behavior", .rows = &.{
        .{ .toggle = .{ .label = "Resize on border", .desc = "Resize window by dragging border", .field = Field.hypr_general_resize_on_border } },
        .{ .toggle = .{ .label = "Hover icon on border", .desc = "Show cursor icon when hovering border", .field = Field.hypr_general_hover_icon_on_border } },
        .{ .toggle = .{ .label = "No focus fallback", .desc = "Disable focus fallback behavior", .field = Field.hypr_general_no_focus_fallback } },
        .{ .slider = .{ .label = "Extend border grab area", .field = Field.hypr_general_extend_border_grab_area, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Resize corner", .field = Field.hypr_general_resize_corner, .min = 0, .max = 4, .unit = "" } },
    } },
    .{ .title = "Layout", .subtitle = "Active window layout", .rows = &.{
        .{ .combo = .{ .label = "", .field = Field.hypr_general_layout, .options = &.{ "dwindle", "master", "scrolling", "monocle" } } },
    } },
};

/// --- decoration ---
pub const decoration = [_]Card{
    .{ .title = "Rounding && Opacity", .subtitle = "Window corners and transparency", .rows = &.{
        .{ .slider = .{ .label = "Radius", .field = Field.hypr_decoration_rounding, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Rounding power", .field = Field.hypr_decoration_rounding_power, .min = 1, .max = 10, .unit = "" } },
        .{ .slider = .{ .label = "Active opacity", .field = Field.hypr_decoration_active_opacity, .min = 50, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Inactive opacity", .field = Field.hypr_decoration_inactive_opacity, .min = 50, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Fullscreen opacity", .field = Field.hypr_decoration_fullscreen_opacity, .min = 50, .max = 100, .unit = "" } },
    } },
    .{ .title = "Blur", .subtitle = "Blur effect and optimization", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Enable window blur effect", .field = Field.hypr_decoration_blur_enabled } },
        .{ .toggle = .{ .label = "X-ray", .desc = "X-ray blur mode", .field = Field.hypr_decoration_blur_xray } },
        .{ .toggle = .{ .label = "Special", .desc = "Blur special workspaces", .field = Field.hypr_decoration_blur_special } },
        .{ .toggle = .{ .label = "New optimizations", .desc = "Use optimized blur path", .field = Field.hypr_decoration_blur_new_optimizations } },
        .{ .toggle = .{ .label = "Ignore opacity", .desc = "Ignore window opacity for blur", .field = Field.hypr_decoration_blur_ignore_opacity } },
        .{ .toggle = .{ .label = "Blur popups", .desc = "Blur popup windows", .field = Field.hypr_decoration_blur_popups } },
        .{ .toggle = .{ .label = "Blur input methods", .desc = "Blur input method windows", .field = Field.hypr_decoration_blur_input_methods } },
        .{ .slider = .{ .label = "Size", .field = Field.hypr_decoration_blur_size, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Passes", .field = Field.hypr_decoration_blur_passes, .min = 0, .max = 10, .unit = "" } },
        .{ .slider = .{ .label = "Noise", .field = Field.hypr_decoration_blur_noise, .min = 0, .max = 100, .unit = "" } },
    } },
    .{ .title = "Blur Advanced", .subtitle = "Blur contrast, brightness, and color", .rows = &.{
        .{ .slider = .{ .label = "Contrast", .field = Field.hypr_decoration_blur_contrast, .min = 30, .max = 200, .unit = "" } },
        .{ .slider = .{ .label = "Brightness", .field = Field.hypr_decoration_blur_brightness, .min = 30, .max = 200, .unit = "" } },
        .{ .slider = .{ .label = "Vibrancy", .field = Field.hypr_decoration_blur_vibrancy, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Vibrancy darkness", .field = Field.hypr_decoration_blur_vibrancy_darkness, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Popups ignore alpha", .field = Field.hypr_decoration_blur_popups_ignorealpha, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Input methods ignore alpha", .field = Field.hypr_decoration_blur_input_methods_ignorealpha, .min = 0, .max = 100, .unit = "" } },
    } },
    .{ .title = "Dim", .subtitle = "Dimming behavior for windows", .rows = &.{
        .{ .toggle = .{ .label = "Dim modal", .desc = "Dim behind modal windows", .field = Field.hypr_decoration_dim_modal } },
        .{ .toggle = .{ .label = "Dim inactive", .desc = "Dim inactive windows", .field = Field.hypr_decoration_dim_inactive } },
        .{ .slider = .{ .label = "Dim strength", .field = Field.hypr_decoration_dim_strength, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Dim special", .field = Field.hypr_decoration_dim_special, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Dim around", .field = Field.hypr_decoration_dim_around, .min = 0, .max = 100, .unit = "" } },
    } },
    .{ .title = "Shadow", .subtitle = "Shadow rendering settings", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Enable window shadows", .field = Field.hypr_decoration_shadow_enabled } },
        .{ .toggle = .{ .label = "Sharp", .desc = "Use sharp shadow edges", .field = Field.hypr_decoration_shadow_sharp } },
        .{ .slider = .{ .label = "Range", .field = Field.hypr_decoration_shadow_range, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Render power", .field = Field.hypr_decoration_shadow_render_power, .min = 1, .max = 10, .unit = "" } },
        .{ .slider = .{ .label = "Scale", .field = Field.hypr_decoration_shadow_scale, .min = 0, .max = 100, .unit = "" } },
    } },
    .{ .title = "Glow", .subtitle = "Glow rendering settings", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Enable window glow effect", .field = Field.hypr_decoration_glow_enabled } },
        .{ .slider = .{ .label = "Range", .field = Field.hypr_decoration_glow_range, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Render power", .field = Field.hypr_decoration_glow_render_power, .min = 1, .max = 10, .unit = "" } },
    } },
    .{ .title = "Motion Blur", .subtitle = "Motion blur settings", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Enable motion blur for moving windows", .field = Field.hypr_decoration_motion_blur_enabled } },
        .{ .slider = .{ .label = "Samples", .field = Field.hypr_decoration_motion_blur_samples, .min = 1, .max = 64, .unit = "" } },
    } },
    .{ .title = "Misc", .subtitle = "Border and window geometry", .rows = &.{
        .{ .toggle = .{ .label = "Border part of window", .desc = "Include border in window area", .field = Field.hypr_decoration_border_part_of_window } },
    } },
};

/// --- input ---
pub const input = [_]Card{
    .{ .title = "Keyboard", .subtitle = "Repeat, rotation, and key handling", .rows = &.{
        .{ .toggle = .{ .label = "Numlock by default", .desc = "Enable numlock at startup", .field = Field.hypr_input_numlock_by_default } },
        .{ .toggle = .{ .label = "Resolve binds by sym", .desc = "Resolve keybinds by keysym", .field = Field.hypr_input_resolve_binds_by_sym } },
        .{ .toggle = .{ .label = "Force no accel", .desc = "Disable mouse acceleration", .field = Field.hypr_input_force_no_accel } },
        .{ .slider = .{ .label = "Repeat delay", .field = Field.hypr_input_repeat_delay, .min = 100, .max = 1000, .unit = "" } },
        .{ .slider = .{ .label = "Repeat rate", .field = Field.hypr_input_repeat_rate, .min = 10, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Input rotation", .field = Field.hypr_input_rotation, .min = 0, .max = 3, .unit = "" } },
    } },
    .{ .title = "Mouse", .subtitle = "Pointer speed, acceleration, and behavior", .rows = &.{
        .{ .toggle = .{ .label = "Natural scroll", .desc = "Invert mouse scroll direction", .field = Field.hypr_input_natural_scroll } },
        .{ .toggle = .{ .label = "Left handed", .desc = "Swap mouse buttons for left-handed use", .field = Field.hypr_input_left_handed } },
        .{ .toggle = .{ .label = "Mouse refocus", .desc = "Refocus window on mouse move", .field = Field.hypr_input_mouse_refocus } },
        .{ .toggle = .{ .label = "Scroll button lock", .desc = "Do not need to hold the scroll button", .field = Field.hypr_input_scroll_button_lock } },
        .{ .slider = .{ .label = "Sensitivity", .field = Field.hypr_input_sensitivity, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Accel profile", .field = Field.hypr_input_accel_profile, .min = 0, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "Follow mouse", .field = Field.hypr_input_follow_mouse, .min = 0, .max = 3, .unit = "" } },
        .{ .slider = .{ .label = "Scroll button", .field = Field.hypr_input_scroll_button, .min = 0, .max = 300, .unit = "" } },
        .{ .slider = .{ .label = "Follow mouse shrink", .field = Field.hypr_input_follow_mouse_shrink, .min = 0, .max = 10, .unit = "" } },
    } },
    .{ .title = "Touchpad", .subtitle = "Scroll, tap, and gesture behavior", .rows = &.{
        .{ .toggle = .{ .label = "Natural scroll", .desc = "Invert touchpad scroll direction", .field = Field.hypr_input_touchpad_natural_scroll } },
        .{ .toggle = .{ .label = "Disable while typing", .desc = "Pause touchpad while typing", .field = Field.hypr_input_touchpad_disable_while_typing } },
        .{ .toggle = .{ .label = "Tap to click", .desc = "Enable tap-to-click on touchpad", .field = Field.hypr_input_touchpad_tap_to_click } },
        .{ .toggle = .{ .label = "Clickfinger behavior", .desc = "Use finger count for button mapping", .field = Field.hypr_input_touchpad_clickfinger_behavior } },
        .{ .toggle = .{ .label = "Emulate middle click with two-finger tap", .field = Field.hypr_input_touchpad_middle_button_emulation } },
        .{ .toggle = .{ .label = "Tap and drag", .desc = "Enable tap-and-drag gesture", .field = Field.hypr_input_touchpad_tap_and_drag } },
        .{ .toggle = .{ .label = "Flip X", .desc = "Invert touchpad X axis", .field = Field.hypr_input_touchpad_flip_x } },
        .{ .toggle = .{ .label = "Flip Y", .desc = "Invert touchpad Y axis", .field = Field.hypr_input_touchpad_flip_y } },
        .{ .slider = .{ .label = "Scroll factor", .field = Field.hypr_input_touchpad_scroll_factor, .min = 10, .max = 200, .unit = "" } },
    } },
    .{ .title = "Gestures", .subtitle = "Workspace swipe and gesture controls", .rows = &.{
        .{ .toggle = .{ .label = "Swipe create new", .desc = "Create new workspace on swipe", .field = Field.hypr_gestures_workspace_swipe_create_new } },
        .{ .slider = .{ .label = "Swipe distance", .field = Field.hypr_gestures_workspace_swipe_distance, .min = 100, .max = 1000, .unit = "" } },
    } },
    .{ .title = "Window Behavior", .subtitle = "Focus and keybind fallthrough behavior", .rows = &.{
        .{ .toggle = .{ .label = "Special fallthrough", .desc = "Let keybinds reach the fallthrough window", .field = Field.hypr_input_special_fallthrough } },
    } },
    .{ .title = "Touch Device", .subtitle = "Touchscreen input mapping", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Enable input for touch devices", .field = Field.hypr_input_touchdevice_enabled } },
        .{ .slider = .{ .label = "Transform", .field = Field.hypr_input_touchdevice_transform, .min = 0, .max = 6, .unit = "" } },
    } },
    .{ .title = "Virtual Keyboard", .subtitle = "Virtual keyboard state sharing", .rows = &.{
        .{ .toggle = .{ .label = "Release keys on close", .desc = "Release pressed keys when virtual keyboard closes", .field = Field.hypr_input_virtualkeyboard_release_pressed_on_close } },
        .{ .slider = .{ .label = "Share states", .field = Field.hypr_input_virtualkeyboard_share_states, .min = 0, .max = 2, .unit = "" } },
    } },
    .{ .title = "Tablet", .subtitle = "Tablet mapping and behavior", .rows = &.{
        .{ .toggle = .{ .label = "Absolute region position", .desc = "Treat region position as absolute in monitor layout", .field = Field.hypr_input_tablet_absolute_region_position } },
        .{ .toggle = .{ .label = "Relative input", .desc = "Use relative input mode", .field = Field.hypr_input_tablet_relative_input } },
        .{ .toggle = .{ .label = "Left handed", .desc = "Rotate tablet by 180 degrees", .field = Field.hypr_input_tablet_left_handed } },
        .{ .slider = .{ .label = "Transform", .field = Field.hypr_input_tablet_transform, .min = 0, .max = 6, .unit = "" } },
    } },
    .{ .title = "Tablet Tool", .subtitle = "Stylus eraser and pressure range", .rows = &.{
        .{ .slider = .{ .label = "Eraser button mode", .field = Field.hypr_input_tablettool_eraser_button_mode, .min = 0, .max = 6, .unit = "" } },
        .{ .slider = .{ .label = "Eraser button override", .field = Field.hypr_input_tablettool_eraser_button_override, .min = 0, .max = 300, .unit = "" } },
        .{ .slider = .{ .label = "Pressure range min", .field = Field.hypr_input_tablettool_pressure_range_min, .min = -100, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Pressure range max", .field = Field.hypr_input_tablettool_pressure_range_max, .min = -100, .max = 100, .unit = "" } },
    } },
};

/// --- binds ---
pub const binds = [_]Card{
    .{ .title = "Bind Behavior", .subtitle = "Workspace and keybind behavior", .rows = &.{
        .{ .toggle = .{ .label = "Workspace back and forth", .desc = "Toggle back to previous workspace", .field = Field.hypr_binds_workspace_back_and_forth } },
        .{ .toggle = .{ .label = "Allow workspace cycles", .desc = "Allow cycling past end workspaces", .field = Field.hypr_binds_allow_workspace_cycles } },
        .{ .slider = .{ .label = "Scroll event delay", .field = Field.hypr_binds_scroll_event_delay, .min = 0, .max = 300, .unit = "" } },
        .{ .slider = .{ .label = "Focus preferred method", .field = Field.hypr_binds_focus_preferred_method, .min = 0, .max = 2, .unit = "" } },
    } },
};

/// --- dwindle ---
pub const dwindle = [_]Card{
    .{ .title = "Split Behavior", .subtitle = "Dwindle splitting and resizing", .rows = &.{
        .{ .toggle = .{ .label = "Preserve split", .desc = "Keep split direction when reopening", .field = Field.hypr_dwindle_preserve_split } },
        .{ .toggle = .{ .label = "Smart split", .desc = "Split in direction with more space", .field = Field.hypr_dwindle_smart_split } },
        .{ .toggle = .{ .label = "Smart resizing", .desc = "Resize neighbor when splitting", .field = Field.hypr_dwindle_smart_resizing } },
        .{ .toggle = .{ .label = "Use active for splits", .desc = "Use active window for split direction", .field = Field.hypr_dwindle_use_active_for_splits } },
        .{ .toggle = .{ .label = "Persistent direction", .desc = "Keep preselect direction until changed", .field = Field.hypr_dwindle_permanent_direction_override } },
        .{ .toggle = .{ .label = "Precise mouse move", .desc = "Drop moved windows at precise cursor point", .field = Field.hypr_dwindle_precise_mouse_move } },
        .{ .slider = .{ .label = "Force split", .field = Field.hypr_dwindle_force_split, .min = 0, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "Special scale factor", .field = Field.hypr_dwindle_special_scale_factor, .min = 10, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Split width multiplier", .field = Field.hypr_dwindle_split_width_multiplier, .min = 10, .max = 300, .unit = "" } },
        .{ .slider = .{ .label = "Default split ratio", .field = Field.hypr_dwindle_default_split_ratio, .min = 10, .max = 190, .unit = "" } },
        .{ .slider = .{ .label = "Split bias", .field = Field.hypr_dwindle_split_bias, .min = 0, .max = 1, .unit = "" } },
    } },
};

/// --- master ---
pub const master = [_]Card{
    .{ .title = "Master Layout", .subtitle = "Master window placement and sizing", .rows = &.{
        .{ .toggle = .{ .label = "New on top", .desc = "Place new windows at top of stack", .field = Field.hypr_master_new_on_top } },
        .{ .toggle = .{ .label = "Allow small split", .desc = "Allow splitting with small windows", .field = Field.hypr_master_allow_small_split } },
        .{ .toggle = .{ .label = "Smart resizing", .desc = "Resize direction from cursor position", .field = Field.hypr_master_smart_resizing } },
        .{ .toggle = .{ .label = "Drop at cursor", .desc = "Drop dragged windows at cursor position", .field = Field.hypr_master_drop_at_cursor } },
        .{ .toggle = .{ .label = "Always keep position", .desc = "Keep master position with no slaves", .field = Field.hypr_master_always_keep_position } },
        .{ .toggle = .{ .label = "Focus master on close", .desc = "Focus master window when slave is closed", .field = Field.hypr_master_focus_master_on_close } },
        .{ .slider = .{ .label = "M-Factor", .field = Field.hypr_master_mfact, .min = 20, .max = 80, .unit = "" } },
        .{ .slider = .{ .label = "Special scale factor", .field = Field.hypr_master_special_scale_factor, .min = 10, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Slave count for center master", .field = Field.hypr_master_slave_count_for_center_master, .min = 1, .max = 10, .unit = "" } },
        .{ .slider = .{ .label = "New window status", .field = Field.hypr_master_new_status, .min = 0, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "New window placement", .field = Field.hypr_master_new_on_active, .min = 0, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "Orientation", .field = Field.hypr_master_orientation, .min = 0, .max = 4, .unit = "" } },
        .{ .slider = .{ .label = "Center master fallback", .field = Field.hypr_master_center_master_fallback, .min = 0, .max = 3, .unit = "" } },
    } },
};

/// --- scrolling ---
pub const scrolling = [_]Card{
    .{ .title = "Scrolling Layout", .subtitle = "Column layout and scrolling", .rows = &.{
        .{ .toggle = .{ .label = "Follow focus", .desc = "Scroll to follow focused window", .field = Field.hypr_scrolling_follow_focus } },
        .{ .toggle = .{ .label = "Wrap focus", .desc = "Wrap around when moving focus", .field = Field.hypr_scrolling_wrap_focus } },
        .{ .toggle = .{ .label = "Wrap swap column", .desc = "Wrap around when swapping columns", .field = Field.hypr_scrolling_wrap_swapcol } },
        .{ .slider = .{ .label = "Column width", .field = Field.hypr_scrolling_column_width, .min = 20, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Focus fit method", .field = Field.hypr_scrolling_focus_fit_method, .min = 0, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "Follow min visible", .field = Field.hypr_scrolling_follow_min_visible, .min = 0, .max = 100, .unit = "" } },
        .{ .slider = .{ .label = "Direction", .field = Field.hypr_scrolling_direction, .min = 0, .max = 3, .unit = "" } },
    } },
};

/// --- animations ---
pub const animations = [_]Card{
    .{ .title = "Animation Master Toggle", .subtitle = "Global animation toggle for all window effects", .rows = &.{
        .{ .toggle = .{ .label = "Enable animations", .desc = "Global animation toggle for all window effects", .field = Field.hypr_animations_enabled } },
        .{ .toggle = .{ .label = "Workspace wraparound", .desc = "Slide between first and last workspaces", .field = Field.hypr_animations_workspace_wraparound } },
    } },
    .{ .title = "Global", .subtitle = "Global animation entry", .rows = &.{
        .{ .anim = .{ .entry = 0 } },
    } },
    .{ .title = "Windows && Layers", .subtitle = "Window and layer surface animations", .rows = &.{
        .{ .anim = .{ .entry = 1 } },
        .{ .anim = .{ .entry = 2 } },
        .{ .anim = .{ .entry = 3 } },
        .{ .anim = .{ .entry = 4 } },
        .{ .anim = .{ .entry = 5 } },
        .{ .anim = .{ .entry = 6 } },
        .{ .anim = .{ .entry = 7 } },
    } },
    .{ .title = "Fading", .subtitle = "Fade effects across surfaces", .rows = &.{
        .{ .anim = .{ .entry = 8 } },
        .{ .anim = .{ .entry = 9 } },
        .{ .anim = .{ .entry = 10 } },
        .{ .anim = .{ .entry = 11 } },
        .{ .anim = .{ .entry = 12 } },
        .{ .anim = .{ .entry = 13 } },
        .{ .anim = .{ .entry = 14 } },
        .{ .anim = .{ .entry = 15 } },
        .{ .anim = .{ .entry = 16 } },
        .{ .anim = .{ .entry = 17 } },
        .{ .anim = .{ .entry = 18 } },
        .{ .anim = .{ .entry = 19 } },
        .{ .anim = .{ .entry = 20 } },
    } },
    .{ .title = "Workspaces", .subtitle = "Workspace switch animations", .rows = &.{
        .{ .anim = .{ .entry = 21 } },
        .{ .anim = .{ .entry = 22 } },
        .{ .anim = .{ .entry = 23 } },
        .{ .anim = .{ .entry = 24 } },
        .{ .anim = .{ .entry = 25 } },
        .{ .anim = .{ .entry = 26 } },
    } },
    .{ .title = "Other", .subtitle = "Border, zoom, and monitor animations", .rows = &.{
        .{ .anim = .{ .entry = 27 } },
        .{ .anim = .{ .entry = 28 } },
        .{ .anim = .{ .entry = 29 } },
        .{ .anim = .{ .entry = 30 } },
    } },
};

/// --- misc ---
pub const misc = [_]Card{
    .{ .title = "General", .subtitle = "Splash, logo, locks, and startup behavior", .rows = &.{
        .{ .toggle = .{ .label = "Disable autoreload", .desc = "Prevent config auto-reload on file change", .field = Field.hypr_misc_disable_autoreload } },
        .{ .toggle = .{ .label = "Disable splash rendering", .desc = "Hide the splash message on startup", .field = Field.hypr_misc_disable_splash_rendering } },
        .{ .toggle = .{ .label = "Disable Hyprland logo", .desc = "Hide the logo on startup", .field = Field.hypr_misc_disable_hyprland_logo } },
        .{ .toggle = .{ .label = "Allow session lock restore", .desc = "Restore session after lock", .field = Field.hypr_misc_allow_session_lock_restore } },
        .{ .toggle = .{ .label = "Mouse move enables DPMS", .desc = "Wake display on mouse movement", .field = Field.hypr_misc_mouse_move_enables_dpms } },
        .{ .toggle = .{ .label = "Middle-click paste", .desc = "Enable middle-click-paste (primary selection)", .field = Field.hypr_misc_middle_click_paste } },
        .{ .toggle = .{ .label = "Animate manual resizes", .desc = "Animate windows when resizing manually", .field = Field.hypr_misc_animate_manual_resizes } },
    } },
    .{ .title = "Animation && Swallow", .subtitle = "Window dragging and swallow behavior", .rows = &.{
        .{ .toggle = .{ .label = "Animate mouse window dragging", .desc = "Animate windows when dragging with mouse", .field = Field.hypr_misc_animate_mouse_windowdragging } },
        .{ .toggle = .{ .label = "Enable swallow", .desc = "Enable swallow functionality for terminals", .field = Field.hypr_misc_enable_swallow } },
    } },
    .{ .title = "VRR && Wallpaper && Timing", .subtitle = "Display refresh, wallpaper, and background fps", .rows = &.{
        .{ .slider = .{ .label = "VRR", .field = Field.hypr_misc_vrr, .min = 0, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "Force default wallpaper", .field = Field.hypr_misc_force_default_wallpaper, .min = -1, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "Initial workspace tracking", .field = Field.hypr_misc_initial_workspace_tracking, .min = 0, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "Render unfocused FPS", .field = Field.hypr_misc_render_unfocused_fps, .min = 1, .max = 240, .unit = "" } },
        .{ .slider = .{ .label = "Workspace token timeout", .field = Field.hypr_misc_initial_workspace_token_timeout, .min = 1, .max = 120, .unit = "" } },
    } },
};

/// --- render ---
pub const render = [_]Card{
    .{ .title = "Render", .subtitle = "Color, scheduling, and render hints", .rows = &.{
        .{ .toggle = .{ .label = "Color management", .desc = "Enable color management pipeline", .field = Field.hypr_render_cm_enabled } },
        .{ .toggle = .{ .label = "Send content type", .desc = "Send content type hints to compositor", .field = Field.hypr_render_send_content_type } },
        .{ .toggle = .{ .label = "New render scheduling", .desc = "Use new render scheduling", .field = Field.hypr_render_new_render_scheduling } },
        .{ .toggle = .{ .label = "Expand undersized textures", .desc = "Expand small textures to fill", .field = Field.hypr_render_expand_undersized_textures } },
        .{ .toggle = .{ .label = "Shader blur blend", .desc = "Use experimental blurred bg blending", .field = Field.hypr_render_use_shader_blur_blend } },
        .{ .slider = .{ .label = "FP16 SDR TF", .field = Field.hypr_render_fp16_sdr_tf, .min = 0, .max = 1, .unit = "" } },
        .{ .slider = .{ .label = "Use FP16 buffer", .field = Field.hypr_render_use_fp16, .min = 0, .max = 2, .unit = "" } },
    } },
    .{ .title = "Vulkan && Scanout", .subtitle = "GPU presentation behavior", .rows = &.{
        .{ .slider = .{ .label = "Direct scanout", .field = Field.hypr_render_direct_scanout, .min = 0, .max = 2, .unit = "" } },
    } },
};

/// --- cursor ---
pub const cursor = [_]Card{
    .{ .title = "Cursor", .subtitle = "Cursor rendering and visibility", .rows = &.{
        .{ .toggle = .{ .label = "Enable hyprcursor", .desc = "Use hyprcursor theme format", .field = Field.hypr_cursor_enable_hyprcursor } },
        .{ .toggle = .{ .label = "Sync gsettings theme", .desc = "Sync cursor theme from gsettings", .field = Field.hypr_cursor_sync_gsettings_theme } },
        .{ .toggle = .{ .label = "Hide on key press", .desc = "Hide cursor when any key is pressed", .field = Field.hypr_cursor_hide_on_key_press } },
        .{ .toggle = .{ .label = "Hide on touch", .desc = "Hide cursor on touch input", .field = Field.hypr_cursor_hide_on_touch } },
        .{ .toggle = .{ .label = "Hide on tablet", .desc = "Hide cursor on tablet input", .field = Field.hypr_cursor_hide_on_tablet } },
        .{ .slider = .{ .label = "Hardware cursors", .field = Field.hypr_cursor_no_hardware_cursors, .min = 0, .max = 2, .unit = "" } },
    } },
    .{ .title = "Zoom && Behavior", .subtitle = "Cursor zoom and keyboard behavior", .rows = &.{
        .{ .toggle = .{ .label = "Zoom rigid", .desc = "Keep zoom center fixed", .field = Field.hypr_cursor_zoom_rigid } },
        .{ .toggle = .{ .label = "Zoom detached camera", .desc = "Detached zoom camera", .field = Field.hypr_cursor_zoom_detached_camera } },
        .{ .toggle = .{ .label = "Zoom disable AA", .desc = "Disable antialiasing while zoomed", .field = Field.hypr_cursor_zoom_disable_aa } },
        .{ .toggle = .{ .label = "Warp back after non-mouse", .desc = "Return cursor after keyboard navigation", .field = Field.hypr_cursor_warp_back_after_non_mouse_input } },
        .{ .slider = .{ .label = "No break FS VRR", .field = Field.hypr_cursor_no_break_fs_vrr, .min = 0, .max = 2, .unit = "" } },
        .{ .slider = .{ .label = "Use CPU buffer", .field = Field.hypr_cursor_use_cpu_buffer, .min = 0, .max = 2, .unit = "" } },
    } },
    .{ .title = "Ecosystem", .subtitle = "Notifications and permission checks", .rows = &.{
        .{ .toggle = .{ .label = "No update news", .desc = "Suppress Hyprland update notifications", .field = Field.hypr_cursor_ecosystem_no_update_news } },
        .{ .toggle = .{ .label = "No donation nag", .desc = "Suppress donation prompts", .field = Field.hypr_cursor_ecosystem_no_donation_nag } },
        .{ .toggle = .{ .label = "Enforce permissions", .desc = "Enforce permission checks", .field = Field.hypr_cursor_ecosystem_enforce_permissions } },
    } },
};

/// --- group ---
pub const group = [_]Card{
    .{ .title = "Group Behavior", .subtitle = "Window grouping behavior", .rows = &.{
        .{ .toggle = .{ .label = "Auto group", .desc = "Automatically group spawned windows", .field = Field.hypr_group_auto_group } },
        .{ .toggle = .{ .label = "Insert after current", .desc = "Insert new window after the focused one", .field = Field.hypr_group_insert_after_current } },
        .{ .toggle = .{ .label = "Focus removed window", .desc = "Focus the removed window when ungrouping", .field = Field.hypr_group_focus_removed_window } },
        .{ .toggle = .{ .label = "Merge groups on drag", .desc = "Merge entire groups when dragging", .field = Field.hypr_group_merge_groups_on_drag } },
        .{ .toggle = .{ .label = "Merge on groupbar", .desc = "Merge groups via groupbar drag", .field = Field.hypr_group_merge_groups_on_groupbar } },
        .{ .toggle = .{ .label = "Merge floated into tiled", .desc = "Allow merging floated into tiled groups", .field = Field.hypr_group_merge_floated_into_tiled_on_groupbar } },
        .{ .toggle = .{ .label = "Group on move-to-workspace", .desc = "Group window when moving to another workspace", .field = Field.hypr_group_group_on_movetoworkspace } },
        .{ .slider = .{ .label = "Drag into group", .field = Field.hypr_group_drag_into_group, .min = 0, .max = 2, .unit = "" } },
    } },
};

/// --- xwayland ---
pub const xwayland = [_]Card{
    .{ .title = "XWayland", .subtitle = "X11 compatibility layer", .rows = &.{
        .{ .toggle = .{ .label = "Enabled", .desc = "Enable XWayland compatibility layer", .field = Field.hypr_xwayland_enabled } },
    } },
};

/// --- opengl ---
pub const opengl = [_]Card{
    .{ .title = "OpenGL", .subtitle = "GL rendering behavior", .rows = &.{
        .{ .toggle = .{ .label = "Nvidia anti-flicker", .desc = "Reduce flickering on Nvidia GPUs", .field = Field.hypr_opengl_nvidia_anti_flicker } },
    } },
};

/// --- quirks ---
pub const quirks = [_]Card{
    .{ .title = "Quirks", .subtitle = "Compatibility and output quirks", .rows = &.{
        .{ .toggle = .{ .label = "Skip non-KMS DMABUF", .desc = "Skip non-KMS compatible DMABUF formats", .field = Field.hypr_quirks_skip_non_kms_dmabuf_formats } },
        .{ .slider = .{ .label = "Prefer HDR", .field = Field.hypr_quirks_prefer_hdr, .min = 0, .max = 2, .unit = "" } },
    } },
};
