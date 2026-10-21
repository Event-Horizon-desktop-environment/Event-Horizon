const std = @import("std");
const app_mod = @import("app.zig");
const hyprland_data = @import("hyprland_data.zig");

// Field bindings between the declarative row list (rows.zig) and the
// persisted `Settings` struct. Same design as C++, where every control in a
// tab reads/writes `app.settings.<field>`: here a control names a `Field`
// and the generic renderer gets/sets it by switch, so paint, hit-test and
// persistence can never disagree about which field a row drives.

pub const Kind = enum { bool, int, str };

pub const Field = enum {
    // -- bools --
    dock_show_dock,
    dock_auto_hide,
    dock_widgets_enabled,
    dock_group_apps,
    dock_tooltips_enabled,
    dock_border_enabled,
    taskbar_enabled,
    taskbar_position_top,
    taskbar_group_apps,
    taskbar_show_labels,
    panel_enabled,
    panel_position_top,
    panel_auto_hide,
    panel_reserve_space,
    dashboard_enabled,
    desktop_enabled,
    wallpaper_enabled,
    bing_enabled,
    bing_daily_enabled,
    workspaces_show_apps,
    notifications_dbus_enabled,
    notifications_dnd,
    notifications_layer_shell,
    matugen_enabled,
    horizon_native,
    color_theme_enabled,
    overview_live_updates,
    overview_multi_monitor,
    power_display_sleep,
    power_idle_suspend,
    power_show_battery_pct,
    time_use_24h,
    time_show_seconds,
    time_show_date,
    keyboard_numlock,
    keyboard_middle_paste,
    bt_auto_reconnect,
    audio_sink_muted,
    audio_source_muted,
    audio_allow_overamp,
    autostart_enabled,
    updater_auto_check,
    nightlight_enabled,

    dock_pinned_apps_tray_pill,
    dock_running_apps_tray_pill,
    dock_liquid_glass,
    dock_colored_glass,
    panel_border,
    taskbar_border,
    taskbar_auto_hide,
    taskbar_tooltips_enabled,
    taskbar_pinned_apps_tray_pill,
    taskbar_running_apps_tray_pill,
    taskbar_collapse_when_full,
    taskbar_thumbnails_enabled,
    taskbar_thumbnail_peek_enabled,
    taskbar_compact_media,
    taskbar_widgets_enabled,
    panel_tooltips_enabled,
    panel_widgets_enabled,
    panel_overlay_layer,
    panel_hover_highlight,
    panel_smart_auto_hide,
    panel_reveal_on_switch,
    panel_scroll_volume,
    panel_capsule,
    monitor_enabled,
    matugen_base_recipes,
    power_tuning_profile,

    // -- ints --
    dock_radius,
    dock_icon_size,
    dock_icon_spacing,
    dock_bottom_gap,
    dock_opacity,
    dock_border_size,
    nightlight_day_temp,
    nightlight_night_temp,
    nightlight_schedule,
    nightlight_start_min,
    nightlight_end_min,
    taskbar_height,
    taskbar_radius,
    taskbar_opacity,
    taskbar_icon_size,
    panel_height,
    panel_radius,
    panel_opacity,
    panel_width_mode,
    dashboard_columns,
    wallpaper_mode,
    bing_filter,
    workspaces_max_slots,
    notifications_timeout_ms,
    notifications_scale_pct,
    notifications_margin_px,
    notifications_corner_radius_px,
    notifications_max_width_px,
    color_brightness_pct,
    color_contrast_pct,
    color_vibrance_pct,
    overlay_opacity_master_pct,
    overlay_opacity_settings_pct,
    overlay_opacity_notifications_pct,
    launchpad_grid_columns,
    launchpad_grid_rows,
    launchpad_layout_scale_pct,
    launchpad_icon_fill_pct,
    launchpad_cell_gap_px,
    launchpad_folder_size_pct,
    launchpad_folder_gap_px,
    launchpad_folder_columns,
    launchpad_folder_rows,
    launchpad_dpi_scale_pct,
    launchpad_view_mode,
    slot_pill_opacity,
    taskbar_slot_pill_opacity,
    workspaces_max_icons,
    overview_axis,
    overview_capture_mode,
    overview_card_scale_pct,
    overview_card_gap_px,
    overview_scroll_delay_ms,
    overview_close_btn_size_px,
    overview_search_width_px,
    power_display_timeout_min,
    power_idle_timeout_min,
    power_button_action,
    power_lid_action,
    time_date_format,
    keyboard_repeat_rate,
    keyboard_repeat_delay_ms,
    audio_sink_volume_pct,
    audio_source_volume_pct,
    audio_engine_rate_hz,

    dock_scale_pct,
    dock_border_opacity,
    dock_exclusive_zone_gap,
    panel_icon_size,
    panel_icon_spacing,
    panel_scale_pct,
    panel_border_size,
    panel_edge_gap,
    panel_exclusive_zone_gap,
    panel_floating_amount,
    panel_capsule_opacity,
    panel_corner_tl,
    panel_corner_tr,
    panel_corner_bl,
    panel_corner_br,
    taskbar_icon_spacing,
    taskbar_scale_pct,
    taskbar_border_size,
    taskbar_edge_gap,
    taskbar_exclusive_zone_gap,
    taskbar_width_mode,
    taskbar_thumbnail_threshold,
    // Monitor form int fields. These are stored in monitors_state.State, not
    // Settings; Content routes them there (see ui_content.zig).
    monitor_sel,
    monitor_mode_idx,
    monitor_refresh_idx,
    monitor_scale_pct,
    monitor_transform_idx,
    monitor_vrr_idx,
    monitor_bitdepth_idx,
    monitor_cm_idx,
    monitor_hdr_support_idx,
    monitor_wide_idx,
    monitor_eotf_idx,
    monitor_sdr_brightness,
    monitor_sdr_saturation,
    monitor_sdr_min_lum,
    monitor_sdr_max_lum,
    monitor_hdr_min_lum,
    monitor_hdr_max_lum,
    monitor_hdr_avg_lum,
    power_perf_pref,

    // -- strings --
    renderer,
    icon_theme,
    wallpaper_image,
    wallpaper_folder,
    bing_download_path,
    notifications_toast_position,
    notifications_output,
    matugen_scheme,
    matugen_mode,
    color_theme_name,
    time_timezone,
    keyboard_layout,
    avatar_path,

    dock_output_name,
    taskbar_output_name,
    panel_output_name,
    panel_deadzone_left,
    panel_deadzone_middle,
    panel_deadzone_right,
    panel_icon_theme,
    panel_click_through,

    // -- Hyprland config bindings (settings_tab_hyprland) --
    // Declared last and contiguous: the value is the `hyprland_data` UI slot
    // (`hyprSlot`), which maps onto one of the 291 config keys through the
    // generated `k_ui` table. They have no `Settings` field of their own, so
    // `kind` and every get/set route them through hyprland_data instead of
    // reflecting off `Settings` like the members above.
// Hyprland config bindings: enum value = hyprland_data UI slot.
    hypr_animations_enabled, // animations.enabled
    hypr_animations_workspace_wraparound, // animations.workspace_wraparound
    hypr_binds_workspace_back_and_forth, // binds.workspace_back_and_forth
    hypr_binds_allow_workspace_cycles, // binds.allow_workspace_cycles
    hypr_binds_scroll_event_delay, // binds.scroll_event_delay
    hypr_binds_focus_preferred_method, // binds.focus_preferred_method
    hypr_cursor_enable_hyprcursor, // cursor.enable_hyprcursor
    hypr_cursor_sync_gsettings_theme, // cursor.sync_gsettings_theme
    hypr_cursor_hide_on_key_press, // cursor.hide_on_key_press
    hypr_cursor_hide_on_touch, // cursor.hide_on_touch
    hypr_cursor_hide_on_tablet, // cursor.hide_on_tablet
    hypr_cursor_no_hardware_cursors, // cursor.no_hardware_cursors
    hypr_cursor_zoom_rigid, // cursor.zoom_rigid
    hypr_cursor_zoom_detached_camera, // cursor.zoom_detached_camera
    hypr_cursor_zoom_disable_aa, // cursor.zoom_disable_aa
    hypr_cursor_warp_back_after_non_mouse_input, // cursor.warp_back_after_non_mouse_input
    hypr_cursor_no_break_fs_vrr, // cursor.no_break_fs_vrr
    hypr_cursor_use_cpu_buffer, // cursor.use_cpu_buffer
    hypr_cursor_ecosystem_no_update_news, // cursor.ecosystem.no_update_news
    hypr_cursor_ecosystem_no_donation_nag, // cursor.ecosystem.no_donation_nag
    hypr_cursor_ecosystem_enforce_permissions, // cursor.ecosystem.enforce_permissions
    hypr_decoration_rounding, // decoration.rounding
    hypr_decoration_rounding_power, // decoration.rounding_power
    hypr_decoration_active_opacity, // decoration.active_opacity
    hypr_decoration_inactive_opacity, // decoration.inactive_opacity
    hypr_decoration_fullscreen_opacity, // decoration.fullscreen_opacity
    hypr_decoration_blur_enabled, // decoration.blur.enabled
    hypr_decoration_blur_xray, // decoration.blur.xray
    hypr_decoration_blur_special, // decoration.blur.special
    hypr_decoration_blur_new_optimizations, // decoration.blur.new_optimizations
    hypr_decoration_blur_ignore_opacity, // decoration.blur.ignore_opacity
    hypr_decoration_blur_popups, // decoration.blur.popups
    hypr_decoration_blur_input_methods, // decoration.blur.input_methods
    hypr_decoration_blur_size, // decoration.blur.size
    hypr_decoration_blur_passes, // decoration.blur.passes
    hypr_decoration_blur_noise, // decoration.blur.noise
    hypr_decoration_blur_contrast, // decoration.blur.contrast
    hypr_decoration_blur_brightness, // decoration.blur.brightness
    hypr_decoration_blur_vibrancy, // decoration.blur.vibrancy
    hypr_decoration_blur_vibrancy_darkness, // decoration.blur.vibrancy_darkness
    hypr_decoration_blur_popups_ignorealpha, // decoration.blur.popups_ignorealpha
    hypr_decoration_blur_input_methods_ignorealpha, // decoration.blur.input_methods_ignorealpha
    hypr_decoration_dim_modal, // decoration.dim_modal
    hypr_decoration_dim_inactive, // decoration.dim_inactive
    hypr_decoration_dim_strength, // decoration.dim_strength
    hypr_decoration_dim_special, // decoration.dim_special
    hypr_decoration_dim_around, // decoration.dim_around
    hypr_decoration_shadow_enabled, // decoration.shadow.enabled
    hypr_decoration_shadow_sharp, // decoration.shadow.sharp
    hypr_decoration_shadow_range, // decoration.shadow.range
    hypr_decoration_shadow_render_power, // decoration.shadow.render_power
    hypr_decoration_shadow_scale, // decoration.shadow.scale
    hypr_decoration_glow_enabled, // decoration.glow.enabled
    hypr_decoration_glow_range, // decoration.glow.range
    hypr_decoration_glow_render_power, // decoration.glow.render_power
    hypr_decoration_motion_blur_enabled, // decoration.motion_blur.enabled
    hypr_decoration_motion_blur_samples, // decoration.motion_blur.samples
    hypr_decoration_border_part_of_window, // decoration.border_part_of_window
    hypr_dwindle_preserve_split, // dwindle.preserve_split
    hypr_dwindle_smart_split, // dwindle.smart_split
    hypr_dwindle_smart_resizing, // dwindle.smart_resizing
    hypr_dwindle_use_active_for_splits, // dwindle.use_active_for_splits
    hypr_dwindle_permanent_direction_override, // dwindle.permanent_direction_override
    hypr_dwindle_precise_mouse_move, // dwindle.precise_mouse_move
    hypr_dwindle_force_split, // dwindle.force_split
    hypr_dwindle_special_scale_factor, // dwindle.special_scale_factor
    hypr_dwindle_split_width_multiplier, // dwindle.split_width_multiplier
    hypr_dwindle_default_split_ratio, // dwindle.default_split_ratio
    hypr_dwindle_split_bias, // dwindle.split_bias
    hypr_general_border_size, // general.border_size
    hypr_general_gaps_in, // general.gaps_in
    hypr_general_gaps_out, // general.gaps_out
    hypr_general_gaps_workspaces, // general.gaps_workspaces
    hypr_general_snap_enabled, // general.snap.enabled
    hypr_general_snap_border_overlap, // general.snap.border_overlap
    hypr_general_snap_respect_gaps, // general.snap.respect_gaps
    hypr_general_snap_window_gap, // general.snap.window_gap
    hypr_general_snap_monitor_gap, // general.snap.monitor_gap
    hypr_general_allow_tearing, // general.allow_tearing
    hypr_general_resize_on_border, // general.resize_on_border
    hypr_general_hover_icon_on_border, // general.hover_icon_on_border
    hypr_general_no_focus_fallback, // general.no_focus_fallback
    hypr_general_extend_border_grab_area, // general.extend_border_grab_area
    hypr_general_resize_corner, // general.resize_corner
    hypr_group_auto_group, // group.auto_group
    hypr_group_insert_after_current, // group.insert_after_current
    hypr_group_focus_removed_window, // group.focus_removed_window
    hypr_group_merge_groups_on_drag, // group.merge_groups_on_drag
    hypr_group_merge_groups_on_groupbar, // group.merge_groups_on_groupbar
    hypr_group_merge_floated_into_tiled_on_groupbar, // group.merge_floated_into_tiled_on_groupbar
    hypr_group_group_on_movetoworkspace, // group.group_on_movetoworkspace
    hypr_group_drag_into_group, // group.drag_into_group
    hypr_input_numlock_by_default, // input.numlock_by_default
    hypr_input_resolve_binds_by_sym, // input.resolve_binds_by_sym
    hypr_input_force_no_accel, // input.force_no_accel
    hypr_input_repeat_delay, // input.repeat_delay
    hypr_input_repeat_rate, // input.repeat_rate
    hypr_input_rotation, // input.rotation
    hypr_input_natural_scroll, // input.natural_scroll
    hypr_input_left_handed, // input.left_handed
    hypr_input_mouse_refocus, // input.mouse_refocus
    hypr_input_scroll_button_lock, // input.scroll_button_lock
    hypr_input_sensitivity, // input.sensitivity
    hypr_input_accel_profile, // input.accel_profile
    hypr_input_follow_mouse, // input.follow_mouse
    hypr_input_scroll_button, // input.scroll_button
    hypr_input_follow_mouse_shrink, // input.follow_mouse_shrink
    hypr_input_touchpad_natural_scroll, // input.touchpad.natural_scroll
    hypr_input_touchpad_disable_while_typing, // input.touchpad.disable_while_typing
    hypr_input_touchpad_tap_to_click, // input.touchpad.tap_to_click
    hypr_input_touchpad_clickfinger_behavior, // input.touchpad.clickfinger_behavior
    hypr_input_touchpad_middle_button_emulation, // input.touchpad.middle_button_emulation
    hypr_input_touchpad_tap_and_drag, // input.touchpad.tap_and_drag
    hypr_input_touchpad_flip_x, // input.touchpad.flip_x
    hypr_input_touchpad_flip_y, // input.touchpad.flip_y
    hypr_input_touchpad_scroll_factor, // input.touchpad.scroll_factor
    hypr_gestures_workspace_swipe_create_new, // gestures.workspace_swipe_create_new
    hypr_gestures_workspace_swipe_distance, // gestures.workspace_swipe_distance
    hypr_input_special_fallthrough, // input.special_fallthrough
    hypr_input_touchdevice_enabled, // input.touchdevice.enabled
    hypr_input_touchdevice_transform, // input.touchdevice.transform
    hypr_input_virtualkeyboard_release_pressed_on_close, // input.virtualkeyboard.release_pressed_on_close
    hypr_input_virtualkeyboard_share_states, // input.virtualkeyboard.share_states
    hypr_input_tablet_absolute_region_position, // input.tablet.absolute_region_position
    hypr_input_tablet_relative_input, // input.tablet.relative_input
    hypr_input_tablet_left_handed, // input.tablet.left_handed
    hypr_input_tablet_transform, // input.tablet.transform
    hypr_input_tablettool_eraser_button_mode, // input.tablettool.eraser_button_mode
    hypr_input_tablettool_eraser_button_override, // input.tablettool.eraser_button_override
    hypr_input_tablettool_pressure_range_min, // input.tablettool.pressure_range_min
    hypr_input_tablettool_pressure_range_max, // input.tablettool.pressure_range_max
    hypr_master_new_on_top, // master.new_on_top
    hypr_master_allow_small_split, // master.allow_small_split
    hypr_master_smart_resizing, // master.smart_resizing
    hypr_master_drop_at_cursor, // master.drop_at_cursor
    hypr_master_always_keep_position, // master.always_keep_position
    hypr_master_focus_master_on_close, // master.focus_master_on_close
    hypr_master_mfact, // master.mfact
    hypr_master_special_scale_factor, // master.special_scale_factor
    hypr_master_slave_count_for_center_master, // master.slave_count_for_center_master
    hypr_master_new_status, // master.new_status
    hypr_master_new_on_active, // master.new_on_active
    hypr_master_orientation, // master.orientation
    hypr_master_center_master_fallback, // master.center_master_fallback
    hypr_misc_disable_autoreload, // misc.disable_autoreload
    hypr_misc_disable_splash_rendering, // misc.disable_splash_rendering
    hypr_misc_disable_hyprland_logo, // misc.disable_hyprland_logo
    hypr_misc_allow_session_lock_restore, // misc.allow_session_lock_restore
    hypr_misc_mouse_move_enables_dpms, // misc.mouse_move_enables_dpms
    hypr_misc_middle_click_paste, // misc.middle_click_paste
    hypr_misc_animate_manual_resizes, // misc.animate_manual_resizes
    hypr_misc_animate_mouse_windowdragging, // misc.animate_mouse_windowdragging
    hypr_misc_enable_swallow, // misc.enable_swallow
    hypr_misc_vrr, // misc.vrr
    hypr_misc_force_default_wallpaper, // misc.force_default_wallpaper
    hypr_misc_initial_workspace_tracking, // misc.initial_workspace_tracking
    hypr_misc_render_unfocused_fps, // misc.render_unfocused_fps
    hypr_misc_initial_workspace_token_timeout, // misc.initial_workspace_token_timeout
    hypr_opengl_nvidia_anti_flicker, // opengl.nvidia_anti_flicker
    hypr_quirks_skip_non_kms_dmabuf_formats, // quirks.skip_non_kms_dmabuf_formats
    hypr_quirks_prefer_hdr, // quirks.prefer_hdr






    hypr_scrolling_follow_focus, // scrolling.follow_focus
    hypr_scrolling_wrap_focus, // scrolling.wrap_focus
    hypr_scrolling_wrap_swapcol, // scrolling.wrap_swapcol
    hypr_scrolling_column_width, // scrolling.column_width
    hypr_scrolling_focus_fit_method, // scrolling.focus_fit_method
    hypr_scrolling_follow_min_visible, // scrolling.follow_min_visible
    hypr_scrolling_direction, // scrolling.direction
    hypr_xwayland_enabled, // xwayland.enabled
    hypr_general_layout, // general.layout

    /// The `hyprland_data` UI slot a Hyprland field drives, or null for a
    /// field that lives in `Settings`. The hypr block is declared last, so a
    /// slot is just the distance from its first member.
    pub fn hyprSlot(self: Field) ?u16 {
        const n: u16 = @intFromEnum(self);
        const first: u16 = @intFromEnum(Field.hypr_animations_enabled);
        if (n < first) return null;
        return n - first;
    }

    pub fn isHypr(self: Field) bool {
        return @intFromEnum(self) >= @intFromEnum(Field.hypr_animations_enabled) and
               @intFromEnum(self) <= @intFromEnum(Field.hypr_general_layout);
    }

    pub fn kind(self: Field) Kind {
        return switch (self) {
            // Monitor fields are routed through Content -> monitors_state, so
            // they cannot be reflected off `Settings`; list them explicitly.
            .monitor_enabled => .bool,
            .monitor_sel,
            .monitor_mode_idx,
            .monitor_refresh_idx,
            .monitor_scale_pct,
            .monitor_transform_idx,
            .monitor_vrr_idx,
            .monitor_bitdepth_idx,
            .monitor_cm_idx,
            .monitor_hdr_support_idx,
            .monitor_wide_idx,
            .monitor_eotf_idx,
            .monitor_sdr_brightness,
            .monitor_sdr_saturation,
            .monitor_sdr_min_lum,
            .monitor_sdr_max_lum,
            .monitor_hdr_min_lum,
            .monitor_hdr_max_lum,
            .monitor_hdr_avg_lum,
            => .int,
            // Notifications extras bypass the reflective walk below: the
            // enum sits exactly at the compiler's branch budget, and five
            // more reflective arms tip it over (see the `kind` note).
            .notifications_margin_px,
            .notifications_corner_radius_px,
            .notifications_max_width_px,
            => .int,
            .notifications_layer_shell => .bool,
            .notifications_output => .str,
            inline else => |f| blk: {
                // Hyprland slots have no `Settings` field; their kind comes
                // from the config key behind them (a `.number` key is an int
                // row too — the slider is integral in the UI).
                if (comptime f.isHypr()) {
                    break :blk switch (hyprland_data.kindOf(f.hyprSlot().?)) {
                        .boolean => .bool,
                        else => .int,
                    };
                }
                const T = @TypeOf(@field(@as(app_mod.Settings, undefined), @tagName(f)));
                break :blk if (T == bool) .bool else if (T == i32) .int else .str;
            },
        };
    }
};

pub fn getBool(s: *const app_mod.Settings, f: Field) bool {
    return switch (f) {
        .dock_show_dock => s.dock_show_dock,
        .dock_auto_hide => s.dock_auto_hide,
        .dock_widgets_enabled => s.dock_widgets_enabled,
        .dock_group_apps => s.dock_group_apps,
        .dock_tooltips_enabled => s.dock_tooltips_enabled,
        .dock_border_enabled => s.dock_border_enabled,
        .taskbar_enabled => s.taskbar_enabled,
        .taskbar_position_top => s.taskbar_position_top,
        .taskbar_group_apps => s.taskbar_group_apps,
        .taskbar_show_labels => s.taskbar_show_labels,
        .panel_enabled => s.panel_enabled,
        .panel_position_top => s.panel_position_top,
        .panel_auto_hide => s.panel_auto_hide,
        .panel_reserve_space => s.panel_reserve_space,
        .dashboard_enabled => s.dashboard_enabled,
        .desktop_enabled => s.desktop_enabled,
        .wallpaper_enabled => s.wallpaper_enabled,
        .bing_enabled => s.bing_enabled,
        .bing_daily_enabled => s.bing_daily_enabled,
        .workspaces_show_apps => s.workspaces_show_apps,
        .notifications_dbus_enabled => s.notifications_dbus_enabled,
        .notifications_dnd => s.notifications_dnd,
        .notifications_layer_shell => s.notifications_layer_shell,
        .matugen_enabled => s.matugen_enabled,
        .horizon_native => s.horizon_native,
        .color_theme_enabled => s.color_theme_enabled,
        .overview_live_updates => s.overview_live_updates,
        .overview_multi_monitor => s.overview_multi_monitor,
        .power_display_sleep => s.power_display_sleep,
        .power_idle_suspend => s.power_idle_suspend,
        .power_show_battery_pct => s.power_show_battery_pct,
        .time_use_24h => s.time_use_24h,
        .time_show_seconds => s.time_show_seconds,
        .time_show_date => s.time_show_date,
        .keyboard_numlock => s.keyboard_numlock,
        .keyboard_middle_paste => s.keyboard_middle_paste,
        .bt_auto_reconnect => s.bt_auto_reconnect,
        .audio_sink_muted => s.audio_sink_muted,
        .audio_source_muted => s.audio_source_muted,
        .audio_allow_overamp => s.audio_allow_overamp,
        .autostart_enabled => s.autostart_enabled,
        .updater_auto_check => s.updater_auto_check,
        .nightlight_enabled => s.nightlight_enabled,
        .dock_pinned_apps_tray_pill => s.dock_pinned_apps_tray_pill,
        .dock_running_apps_tray_pill => s.dock_running_apps_tray_pill,
        .dock_liquid_glass => s.dock_liquid_glass,
        .dock_colored_glass => s.dock_colored_glass,
        .panel_border => s.panel_border,
        .taskbar_border => s.taskbar_border,
        .taskbar_auto_hide => s.taskbar_auto_hide,
        .taskbar_tooltips_enabled => s.taskbar_tooltips_enabled,
        .taskbar_pinned_apps_tray_pill => s.taskbar_pinned_apps_tray_pill,
        .taskbar_running_apps_tray_pill => s.taskbar_running_apps_tray_pill,
        .taskbar_collapse_when_full => s.taskbar_collapse_when_full,
        .taskbar_thumbnails_enabled => s.taskbar_thumbnails_enabled,
        .taskbar_thumbnail_peek_enabled => s.taskbar_thumbnail_peek_enabled,
        .taskbar_compact_media => s.taskbar_compact_media,
        .taskbar_widgets_enabled => s.taskbar_widgets_enabled,
        .panel_tooltips_enabled => s.panel_tooltips_enabled,
        .panel_widgets_enabled => s.panel_widgets_enabled,
        .panel_overlay_layer => s.panel_overlay_layer,
        .panel_hover_highlight => s.panel_hover_highlight,
        .panel_smart_auto_hide => s.panel_smart_auto_hide,
        .panel_reveal_on_switch => s.panel_reveal_on_switch,
        .panel_scroll_volume => s.panel_scroll_volume,
        .panel_capsule => s.panel_capsule,
        .matugen_base_recipes => s.matugen_base_recipes,
        .power_tuning_profile => s.power_tuning_profile,
        else => false,
    };
}

pub fn setBool(s: *app_mod.Settings, f: Field, v: bool) void {
    switch (f) {
        .dock_show_dock => s.dock_show_dock = v,
        .dock_auto_hide => s.dock_auto_hide = v,
        .dock_widgets_enabled => s.dock_widgets_enabled = v,
        .dock_group_apps => s.dock_group_apps = v,
        .dock_tooltips_enabled => s.dock_tooltips_enabled = v,
        .dock_border_enabled => s.dock_border_enabled = v,
        .taskbar_enabled => s.taskbar_enabled = v,
        .taskbar_position_top => s.taskbar_position_top = v,
        .taskbar_group_apps => s.taskbar_group_apps = v,
        .taskbar_show_labels => s.taskbar_show_labels = v,
        .panel_enabled => s.panel_enabled = v,
        .panel_position_top => s.panel_position_top = v,
        .panel_auto_hide => s.panel_auto_hide = v,
        .panel_reserve_space => s.panel_reserve_space = v,
        .dashboard_enabled => s.dashboard_enabled = v,
        .desktop_enabled => s.desktop_enabled = v,
        .wallpaper_enabled => s.wallpaper_enabled = v,
        .bing_enabled => s.bing_enabled = v,
        .bing_daily_enabled => s.bing_daily_enabled = v,
        .workspaces_show_apps => s.workspaces_show_apps = v,
        .notifications_dbus_enabled => s.notifications_dbus_enabled = v,
        .notifications_dnd => s.notifications_dnd = v,
        .notifications_layer_shell => s.notifications_layer_shell = v,
        .matugen_enabled => s.matugen_enabled = v,
        .horizon_native => s.horizon_native = v,
        .color_theme_enabled => s.color_theme_enabled = v,
        .overview_live_updates => s.overview_live_updates = v,
        .overview_multi_monitor => s.overview_multi_monitor = v,
        .power_display_sleep => s.power_display_sleep = v,
        .power_idle_suspend => s.power_idle_suspend = v,
        .power_show_battery_pct => s.power_show_battery_pct = v,
        .time_use_24h => s.time_use_24h = v,
        .time_show_seconds => s.time_show_seconds = v,
        .time_show_date => s.time_show_date = v,
        .keyboard_numlock => s.keyboard_numlock = v,
        .keyboard_middle_paste => s.keyboard_middle_paste = v,
        .bt_auto_reconnect => s.bt_auto_reconnect = v,
        .audio_sink_muted => s.audio_sink_muted = v,
        .audio_source_muted => s.audio_source_muted = v,
        .audio_allow_overamp => s.audio_allow_overamp = v,
        .autostart_enabled => s.autostart_enabled = v,
        .updater_auto_check => s.updater_auto_check = v,
        .nightlight_enabled => s.nightlight_enabled = v,
        .dock_pinned_apps_tray_pill => s.dock_pinned_apps_tray_pill = v,
        .dock_running_apps_tray_pill => s.dock_running_apps_tray_pill = v,
        .dock_liquid_glass => s.dock_liquid_glass = v,
        .dock_colored_glass => s.dock_colored_glass = v,
        .panel_border => s.panel_border = v,
        .taskbar_border => s.taskbar_border = v,
        .taskbar_auto_hide => s.taskbar_auto_hide = v,
        .taskbar_tooltips_enabled => s.taskbar_tooltips_enabled = v,
        .taskbar_pinned_apps_tray_pill => s.taskbar_pinned_apps_tray_pill = v,
        .taskbar_running_apps_tray_pill => s.taskbar_running_apps_tray_pill = v,
        .taskbar_collapse_when_full => s.taskbar_collapse_when_full = v,
        .taskbar_thumbnails_enabled => s.taskbar_thumbnails_enabled = v,
        .taskbar_thumbnail_peek_enabled => s.taskbar_thumbnail_peek_enabled = v,
        .taskbar_compact_media => s.taskbar_compact_media = v,
        .taskbar_widgets_enabled => s.taskbar_widgets_enabled = v,
        .panel_tooltips_enabled => s.panel_tooltips_enabled = v,
        .panel_widgets_enabled => s.panel_widgets_enabled = v,
        .panel_overlay_layer => s.panel_overlay_layer = v,
        .panel_hover_highlight => s.panel_hover_highlight = v,
        .panel_smart_auto_hide => s.panel_smart_auto_hide = v,
        .panel_reveal_on_switch => s.panel_reveal_on_switch = v,
        .panel_scroll_volume => s.panel_scroll_volume = v,
        .panel_capsule => s.panel_capsule = v,
        .matugen_base_recipes => s.matugen_base_recipes = v,
        .power_tuning_profile => s.power_tuning_profile = v,
        else => {},
    }
}

pub fn getInt(s: *const app_mod.Settings, f: Field) i32 {
    return switch (f) {
        .dock_radius => s.dock_radius,
        .dock_icon_size => s.dock_icon_size,
        .dock_icon_spacing => s.dock_icon_spacing,
        .dock_bottom_gap => s.dock_bottom_gap,
        .dock_opacity => s.dock_opacity,
        .dock_border_size => s.dock_border_size,
        .nightlight_day_temp => s.nightlight_day_temp,
        .nightlight_night_temp => s.nightlight_night_temp,
        .nightlight_schedule => s.nightlight_schedule,
        .nightlight_start_min => s.nightlight_start_min,
        .nightlight_end_min => s.nightlight_end_min,
        .dock_scale_pct => s.dock_scale_pct,
        .dock_border_opacity => s.dock_border_opacity,
        .dock_exclusive_zone_gap => s.dock_exclusive_zone_gap,
        .panel_icon_size => s.panel_icon_size,
        .panel_floating_amount => s.panel_floating_amount,
        .panel_capsule_opacity => s.panel_capsule_opacity,
        .panel_corner_tl => s.panel_corner_tl,
        .panel_corner_tr => s.panel_corner_tr,
        .panel_corner_bl => s.panel_corner_bl,
        .panel_corner_br => s.panel_corner_br,
        .panel_icon_spacing => s.panel_icon_spacing,
        .panel_scale_pct => s.panel_scale_pct,
        .panel_border_size => s.panel_border_size,
        .panel_edge_gap => s.panel_edge_gap,
        .panel_exclusive_zone_gap => s.panel_exclusive_zone_gap,
        .taskbar_icon_spacing => s.taskbar_icon_spacing,
        .taskbar_scale_pct => s.taskbar_scale_pct,
        .taskbar_border_size => s.taskbar_border_size,
        .taskbar_edge_gap => s.taskbar_edge_gap,
        .taskbar_exclusive_zone_gap => s.taskbar_exclusive_zone_gap,
        .taskbar_width_mode => s.taskbar_width_mode,
        .taskbar_thumbnail_threshold => s.taskbar_thumbnail_threshold,
        .power_perf_pref => s.power_perf_pref,
        .taskbar_height => s.taskbar_height,
        .taskbar_radius => s.taskbar_radius,
        .taskbar_opacity => s.taskbar_opacity,
        .taskbar_icon_size => s.taskbar_icon_size,
        .panel_height => s.panel_height,
        .panel_radius => s.panel_radius,
        .panel_opacity => s.panel_opacity,
        .panel_width_mode => s.panel_width_mode,
        .dashboard_columns => s.dashboard_columns,
        .wallpaper_mode => s.wallpaper_mode,
        .bing_filter => s.bing_filter,
        .workspaces_max_slots => s.workspaces_max_slots,
        .notifications_timeout_ms => s.notifications_timeout_ms,
        .notifications_scale_pct => s.notifications_scale_pct,
        .notifications_margin_px => s.notifications_margin_px,
        .notifications_corner_radius_px => s.notifications_corner_radius_px,
        .notifications_max_width_px => s.notifications_max_width_px,
        .color_brightness_pct => s.color_brightness_pct,
        .color_contrast_pct => s.color_contrast_pct,
        .color_vibrance_pct => s.color_vibrance_pct,
        .overlay_opacity_master_pct => s.overlay_opacity_master_pct,
        .overlay_opacity_settings_pct => s.overlay_opacity_settings_pct,
        .overlay_opacity_notifications_pct => s.overlay_opacity_notifications_pct,
        .launchpad_grid_columns => s.launchpad_grid_columns,
        .launchpad_grid_rows => s.launchpad_grid_rows,
        .launchpad_layout_scale_pct => s.launchpad_layout_scale_pct,
        .launchpad_icon_fill_pct => s.launchpad_icon_fill_pct,
        .launchpad_cell_gap_px => s.launchpad_cell_gap_px,
        .launchpad_folder_size_pct => s.launchpad_folder_size_pct,
        .launchpad_folder_gap_px => s.launchpad_folder_gap_px,
        .launchpad_folder_columns => s.launchpad_folder_columns,
        .launchpad_folder_rows => s.launchpad_folder_rows,
        .launchpad_dpi_scale_pct => s.launchpad_dpi_scale_pct,
        .launchpad_view_mode => s.launchpad_view_mode,
        .slot_pill_opacity => s.slot_pill_opacity,
        .taskbar_slot_pill_opacity => s.taskbar_slot_pill_opacity,
        .workspaces_max_icons => s.workspaces_max_icons,
        .overview_axis => s.overview_axis,
        .overview_capture_mode => s.overview_capture_mode,
        .overview_card_scale_pct => s.overview_card_scale_pct,
        .overview_card_gap_px => s.overview_card_gap_px,
        .overview_scroll_delay_ms => s.overview_scroll_delay_ms,
        .overview_close_btn_size_px => s.overview_close_btn_size_px,
        .overview_search_width_px => s.overview_search_width_px,
        .power_display_timeout_min => s.power_display_timeout_min,
        .power_idle_timeout_min => s.power_idle_timeout_min,
        .power_button_action => s.power_button_action,
        .power_lid_action => s.power_lid_action,
        .time_date_format => s.time_date_format,
        .keyboard_repeat_rate => s.keyboard_repeat_rate,
        .keyboard_repeat_delay_ms => s.keyboard_repeat_delay_ms,
        .audio_sink_volume_pct => s.audio_sink_volume_pct,
        .audio_source_volume_pct => s.audio_source_volume_pct,
        .audio_engine_rate_hz => s.audio_engine_rate_hz,
        else => if (f.kind() == .bool) @intFromBool(getBool(s, f)) else 0,
    };
}

pub fn setInt(s: *app_mod.Settings, f: Field, v: i32) void {
    switch (f) {
        .dock_radius => s.dock_radius = v,
        .dock_icon_size => s.dock_icon_size = v,
        .dock_icon_spacing => s.dock_icon_spacing = v,
        .dock_bottom_gap => s.dock_bottom_gap = v,
        .dock_opacity => s.dock_opacity = v,
        .dock_border_size => s.dock_border_size = v,
        .nightlight_day_temp => s.nightlight_day_temp = v,
        .nightlight_night_temp => s.nightlight_night_temp = v,
        .nightlight_schedule => s.nightlight_schedule = v,
        .nightlight_start_min => s.nightlight_start_min = v,
        .nightlight_end_min => s.nightlight_end_min = v,
        .dock_scale_pct => s.dock_scale_pct = v,
        .dock_border_opacity => s.dock_border_opacity = v,
        .dock_exclusive_zone_gap => s.dock_exclusive_zone_gap = v,
        .panel_icon_size => s.panel_icon_size = v,
        .panel_floating_amount => s.panel_floating_amount = v,
        .panel_capsule_opacity => s.panel_capsule_opacity = v,
        .panel_corner_tl => s.panel_corner_tl = v,
        .panel_corner_tr => s.panel_corner_tr = v,
        .panel_corner_bl => s.panel_corner_bl = v,
        .panel_corner_br => s.panel_corner_br = v,
        .panel_icon_spacing => s.panel_icon_spacing = v,
        .panel_scale_pct => s.panel_scale_pct = v,
        .panel_border_size => s.panel_border_size = v,
        .panel_edge_gap => s.panel_edge_gap = v,
        .panel_exclusive_zone_gap => s.panel_exclusive_zone_gap = v,
        .taskbar_icon_spacing => s.taskbar_icon_spacing = v,
        .taskbar_scale_pct => s.taskbar_scale_pct = v,
        .taskbar_border_size => s.taskbar_border_size = v,
        .taskbar_edge_gap => s.taskbar_edge_gap = v,
        .taskbar_exclusive_zone_gap => s.taskbar_exclusive_zone_gap = v,
        .taskbar_width_mode => s.taskbar_width_mode = v,
        .taskbar_thumbnail_threshold => s.taskbar_thumbnail_threshold = v,
        .power_perf_pref => s.power_perf_pref = v,
        .taskbar_height => s.taskbar_height = v,
        .taskbar_radius => s.taskbar_radius = v,
        .taskbar_opacity => s.taskbar_opacity = v,
        .taskbar_icon_size => s.taskbar_icon_size = v,
        .panel_height => s.panel_height = v,
        .panel_radius => s.panel_radius = v,
        .panel_opacity => s.panel_opacity = v,
        .panel_width_mode => s.panel_width_mode = v,
        .dashboard_columns => s.dashboard_columns = v,
        .wallpaper_mode => s.wallpaper_mode = v,
        .bing_filter => s.bing_filter = v,
        .workspaces_max_slots => s.workspaces_max_slots = v,
        .notifications_timeout_ms => s.notifications_timeout_ms = v,
        .notifications_scale_pct => s.notifications_scale_pct = v,
        .notifications_margin_px => s.notifications_margin_px = v,
        .notifications_corner_radius_px => s.notifications_corner_radius_px = v,
        .notifications_max_width_px => s.notifications_max_width_px = v,
        .color_brightness_pct => s.color_brightness_pct = v,
        .color_contrast_pct => s.color_contrast_pct = v,
        .color_vibrance_pct => s.color_vibrance_pct = v,
        .overlay_opacity_master_pct => s.overlay_opacity_master_pct = v,
        .overlay_opacity_settings_pct => s.overlay_opacity_settings_pct = v,
        .overlay_opacity_notifications_pct => s.overlay_opacity_notifications_pct = v,
        .launchpad_grid_columns => s.launchpad_grid_columns = v,
        .launchpad_grid_rows => s.launchpad_grid_rows = v,
        .launchpad_layout_scale_pct => s.launchpad_layout_scale_pct = v,
        .launchpad_icon_fill_pct => s.launchpad_icon_fill_pct = v,
        .launchpad_cell_gap_px => s.launchpad_cell_gap_px = v,
        .launchpad_folder_size_pct => s.launchpad_folder_size_pct = v,
        .launchpad_folder_gap_px => s.launchpad_folder_gap_px = v,
        .launchpad_folder_columns => s.launchpad_folder_columns = v,
        .launchpad_folder_rows => s.launchpad_folder_rows = v,
        .launchpad_dpi_scale_pct => s.launchpad_dpi_scale_pct = v,
        .launchpad_view_mode => s.launchpad_view_mode = v,
        // One Widget-opacity slider drives both bars, like the C++
        // `case 7: slotPillOpacity = v; taskbarSlotPillOpacity = v`.
        .slot_pill_opacity => {
            s.slot_pill_opacity = v;
            s.taskbar_slot_pill_opacity = v;
        },
        .taskbar_slot_pill_opacity => {
            s.taskbar_slot_pill_opacity = v;
            s.slot_pill_opacity = v;
        },
        .workspaces_max_icons => s.workspaces_max_icons = v,
        .overview_axis => s.overview_axis = v,
        .overview_capture_mode => s.overview_capture_mode = v,
        .overview_card_scale_pct => s.overview_card_scale_pct = v,
        .overview_card_gap_px => s.overview_card_gap_px = v,
        .overview_scroll_delay_ms => s.overview_scroll_delay_ms = v,
        .overview_close_btn_size_px => s.overview_close_btn_size_px = v,
        .overview_search_width_px => s.overview_search_width_px = v,
        .power_display_timeout_min => s.power_display_timeout_min = v,
        .power_idle_timeout_min => s.power_idle_timeout_min = v,
        .power_button_action => s.power_button_action = v,
        .power_lid_action => s.power_lid_action = v,
        .time_date_format => s.time_date_format = v,
        .keyboard_repeat_rate => s.keyboard_repeat_rate = v,
        .keyboard_repeat_delay_ms => s.keyboard_repeat_delay_ms = v,
        .audio_sink_volume_pct => s.audio_sink_volume_pct = v,
        .audio_source_volume_pct => s.audio_source_volume_pct = v,
        .audio_engine_rate_hz => s.audio_engine_rate_hz = v,
        else => if (f.kind() == .bool) setBool(s, f, v != 0),
    }
}

pub fn getStr(s: *const app_mod.Settings, f: Field) []const u8 {
    return switch (f) {
        .renderer => s.renderer,
        .dock_output_name => s.dock_output_name,
        .taskbar_output_name => s.taskbar_output_name,
        .panel_output_name => s.panel_output_name,
        .panel_deadzone_left => s.panel_deadzone_left,
        .panel_deadzone_middle => s.panel_deadzone_middle,
        .panel_deadzone_right => s.panel_deadzone_right,
        .panel_icon_theme => s.panel_icon_theme,
        .panel_click_through => s.panel_click_through,
        .icon_theme => s.icon_theme,
        .wallpaper_image => s.wallpaper_image,
        .wallpaper_folder => s.wallpaper_folder,
        .bing_download_path => s.bing_download_path,
        .notifications_toast_position => s.notifications_toast_position,
        .notifications_output => s.notifications_output,
        .matugen_scheme => s.matugen_scheme,
        .matugen_mode => s.matugen_mode,
        .color_theme_name => s.color_theme_name,
        .time_timezone => s.time_timezone,
        .keyboard_layout => s.keyboard_layout,
        .avatar_path => s.avatar_path,
        else => "",
    };
}

pub fn setStr(s: *app_mod.Settings, f: Field, v: []const u8) void {
    switch (f) {
        .renderer => s.renderer = v,
        .dock_output_name => s.dock_output_name = v,
        .taskbar_output_name => s.taskbar_output_name = v,
        .panel_output_name => s.panel_output_name = v,
        .panel_deadzone_left => s.panel_deadzone_left = v,
        .panel_deadzone_middle => s.panel_deadzone_middle = v,
        .panel_deadzone_right => s.panel_deadzone_right = v,
        .panel_icon_theme => s.panel_icon_theme = v,
        .panel_click_through => s.panel_click_through = v,
        .icon_theme => s.icon_theme = v,
        .wallpaper_image => s.wallpaper_image = v,
        .wallpaper_folder => s.wallpaper_folder = v,
        .bing_download_path => s.bing_download_path = v,
        .notifications_toast_position => s.notifications_toast_position = v,
        .notifications_output => s.notifications_output = v,
        .matugen_scheme => s.matugen_scheme = v,
        .matugen_mode => s.matugen_mode = v,
        .color_theme_name => s.color_theme_name = v,
        .time_timezone => s.time_timezone = v,
        .keyboard_layout => s.keyboard_layout = v,
        .avatar_path => s.avatar_path = v,
        else => {},
    }
}

/// Combo index for a row: int fields store the index directly, string fields
/// store the selected option text (matched, defaulting to 0 like the C++
/// `rendererIndex()` helper in dock_tab.zig).
pub fn comboIndex(s: *const app_mod.Settings, f: Field, options: []const []const u8) usize {
    if (f.kind() == .str) {
        const cur = getStr(s, f);
        for (options, 0..) |o, i| {
            if (std.mem.eql(u8, o, cur)) return i;
        }
        return 0;
    }
    const v = getInt(s, f);
    if (v < 0 or v >= options.len) return 0;
    return @intCast(v);
}

pub fn setComboIndex(s: *app_mod.Settings, f: Field, options: []const []const u8, i: usize) void {
    if (i >= options.len) return;
    if (f.kind() == .str) {
        setStr(s, f, options[i]);
    } else {
        setInt(s, f, @intCast(i));
    }
}

test "settings-fields: kinds mirror Settings types" {
    const t = std.testing;
    try t.expectEqual(Kind.bool, Field.dock_show_dock.kind());
    try t.expectEqual(Kind.int, Field.dock_radius.kind());
    try t.expectEqual(Kind.str, Field.renderer.kind());
    // Monitor fields are routed through monitors_state, not Settings.
    try t.expectEqual(Kind.bool, Field.monitor_enabled.kind());
    try t.expectEqual(Kind.int, Field.monitor_sdr_max_lum.kind());
    try t.expectEqual(Kind.int, Field.monitor_scale_pct.kind());
}

test "settings-fields: get/set round-trip" {
    const t = std.testing;
    var s = app_mod.Settings{};
    try t.expect(getBool(&s, .dock_show_dock));
    setBool(&s, .dock_show_dock, false);
    try t.expect(!getBool(&s, .dock_show_dock));
    setInt(&s, .dock_radius, 24);
    try t.expectEqual(@as(i32, 24), getInt(&s, .dock_radius));
    setStr(&s, .renderer, "cairo");
    try t.expectEqualStrings("cairo", getStr(&s, .renderer));
    // int fields also read through the bool/int facade without crashing.
    try t.expectEqual(@as(i32, 0), getInt(&s, .renderer));
}

test "settings-fields: combo index for int and str fields" {
    const t = std.testing;
    var s = app_mod.Settings{};
    const opts = [_][]const u8{ "vulkan", "cairo" };
    try t.expectEqual(@as(usize, 0), comboIndex(&s, .renderer, &opts));
    setComboIndex(&s, .renderer, &opts, 1);
    try t.expectEqualStrings("cairo", getStr(&s, .renderer));
    setInt(&s, .nightlight_schedule, 2);
    const s_opts = [_][]const u8{ "Manual", "Sunset", "Scheduled" };
    try t.expectEqual(@as(usize, 2), comboIndex(&s, .nightlight_schedule, &s_opts));
    setComboIndex(&s, .nightlight_schedule, &s_opts, 9); // out of range: no-op
    try t.expectEqual(@as(i32, 2), getInt(&s, .nightlight_schedule));
}
