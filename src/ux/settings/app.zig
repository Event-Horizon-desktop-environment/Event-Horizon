const std = @import("std");

// Full Settings state model — Zig port of src/ux/settings/settings_app_types.hpp
// `Settings` (all persisted fields) plus the `App` window/sidebar geometry.
// Same design and layout as C++: window 900x980, sidebar 260px, content area
// to the right of the sidebar, per-tab scroll offsets, numeric tab ids.
//
// Numeric tab ids match settings_app.cpp kSidebarDefs exactly:
//   Panels&UI(12): 0 Dock, 1 Panel, 11 Taskbar, 9 Launcher, 29 Desktop, 27 Desktop Widgets
//   Display(13): 7 Monitors, 2 Appearance, 45 Themes, 50 Color Themes, 44 Icons, 19 Nightlight
//   MangoWM(16): 20 Decoration, 21 Colors, 22 Animations, 23 Keybinds, 24 Layout, 25 Input, 26 Misc
//   Hyprland: 33
//   System(14): 5 Notifications, 8 Sound, 10 Default Apps, 30 Time, 31 Keyboard,
//               47 Bluetooth, 32 Power, 46 Accounts, 48 Startup
//   Wallpaper(15): 6 Wallpaper, 16 Bing
//   Network(17): 17 Wi-Fi, 18 Wired, 28 VPN

pub const window_width: i32 = 900;
pub const window_height: i32 = 980;

pub const TabId = struct {
    pub const dock: i32 = 0;
    pub const panel: i32 = 1;
    pub const appearance: i32 = 2;
    pub const notifications: i32 = 5;
    pub const wallpaper: i32 = 6;
    pub const monitors: i32 = 7;
    pub const sound: i32 = 8;
    pub const launcher: i32 = 9;
    pub const default_apps: i32 = 10;
    pub const taskbar: i32 = 11;
    pub const bing: i32 = 16;
    pub const wifi: i32 = 17;
    pub const wired: i32 = 18;
    pub const nightlight: i32 = 19;
    pub const mango_decoration: i32 = 20;
    pub const mango_colors: i32 = 21;
    pub const mango_animations: i32 = 22;
    pub const mango_keybinds: i32 = 23;
    pub const mango_layout: i32 = 24;
    pub const mango_input: i32 = 25;
    pub const mango_misc: i32 = 26;
    pub const desktop_widgets: i32 = 27;
    pub const vpn: i32 = 28;
    pub const desktop: i32 = 29;
    pub const time: i32 = 30;
    pub const keyboard: i32 = 31;
    pub const power: i32 = 32;
    pub const hyprland: i32 = 33;
    pub const icons: i32 = 44;
    pub const themes: i32 = 45;
    pub const accounts: i32 = 46;
    pub const bluetooth: i32 = 47;
    pub const autostart: i32 = 48;
    pub const color_themes: i32 = 50;
    pub const taskflip: i32 = 60;
    pub const workspaces: i32 = 61;
    pub const dashboard: i32 = 62;
};

pub const SidebarSub = struct {
    label: []const u8,
    glyph: []const u8,
    tab_id: i32,
};

pub const SidebarCategory = struct {
    id: i32,
    label: []const u8,
    glyph: []const u8,
    subs: []const SidebarSub,
};

pub const panels_ui_subs = [_]SidebarSub{
    .{ .label = "Dock", .glyph = "dock_to_bottom", .tab_id = 0 },
    .{ .label = "Panel", .glyph = "dock_to_top", .tab_id = 1 },
    .{ .label = "Taskbar", .glyph = "dock_to_bottom", .tab_id = 11 },
    .{ .label = "Launcher", .glyph = "apps", .tab_id = 9 },
    .{ .label = "Desktop", .glyph = "desktop_windows", .tab_id = 29 },
    .{ .label = "Desktop Widgets", .glyph = "widgets", .tab_id = 27 },
};

pub const display_subs = [_]SidebarSub{
    .{ .label = "Monitors", .glyph = "monitor", .tab_id = 7 },
    .{ .label = "Appearance", .glyph = "palette", .tab_id = 2 },
    .{ .label = "Themes", .glyph = "palette", .tab_id = 45 },
    .{ .label = "Color Themes", .glyph = "colorize", .tab_id = 50 },
    .{ .label = "Icons", .glyph = "photo_library", .tab_id = 44 },
    .{ .label = "Nightlight", .glyph = "dark_mode", .tab_id = 19 },
};

pub const mango_subs = [_]SidebarSub{
    .{ .label = "Decoration", .glyph = "border_style", .tab_id = 20 },
    .{ .label = "Colors", .glyph = "palette", .tab_id = 21 },
    .{ .label = "Animations", .glyph = "play_arrow", .tab_id = 22 },
    .{ .label = "Keybinds", .glyph = "keyboard", .tab_id = 23 },
    .{ .label = "Layout", .glyph = "grid_view", .tab_id = 24 },
    .{ .label = "Input", .glyph = "mouse", .tab_id = 25 },
    .{ .label = "Misc", .glyph = "tune", .tab_id = 26 },
};

pub const system_subs = [_]SidebarSub{
    .{ .label = "Notifications", .glyph = "notifications", .tab_id = 5 },
    .{ .label = "Sound", .glyph = "volume_up", .tab_id = 8 },
    .{ .label = "Default Apps", .glyph = "app_registration", .tab_id = 10 },
    .{ .label = "Time", .glyph = "schedule", .tab_id = 30 },
    .{ .label = "Keyboard & Language", .glyph = "keyboard", .tab_id = 31 },
    .{ .label = "Bluetooth", .glyph = "bluetooth", .tab_id = 47 },
    .{ .label = "Power", .glyph = "power_settings_new", .tab_id = 32 },
    .{ .label = "Accounts", .glyph = "account_circle", .tab_id = 46 },
    .{ .label = "Startup", .glyph = "play_arrow", .tab_id = 48 },
    .{ .label = "Updates", .glyph = "system_update", .tab_id = 51 },
};

pub const wallpaper_subs = [_]SidebarSub{
    .{ .label = "Wallpaper", .glyph = "wallpaper", .tab_id = 6 },
    .{ .label = "Bing Wallpaper", .glyph = "photo_library", .tab_id = 16 },
};

pub const network_subs = [_]SidebarSub{
    .{ .label = "Wi-Fi", .glyph = "wifi", .tab_id = 17 },
    .{ .label = "Wired", .glyph = "lan", .tab_id = 18 },
    .{ .label = "VPN", .glyph = "vpn_key", .tab_id = 28 },
};

pub const sidebar_categories = [_]SidebarCategory{
    .{ .id = 12, .label = "Panels & UI", .glyph = "dashboard", .subs = &panels_ui_subs },
    .{ .id = 13, .label = "Display", .glyph = "display_settings", .subs = &display_subs },
    .{ .id = 16, .label = "MangoWM", .glyph = "view_module", .subs = &mango_subs },
    .{ .id = 33, .label = "Hyprland", .glyph = "view_module", .subs = &.{} },
    .{ .id = 14, .label = "System", .glyph = "tune", .subs = &system_subs },
    .{ .id = 15, .label = "Wallpaper Settings", .glyph = "wallpaper", .subs = &wallpaper_subs },
    .{ .id = 17, .label = "Network", .glyph = "wifi", .subs = &network_subs },
};

/// Persisted settings — one field per Settings struct member in
/// settings_app_types.hpp. Strings are borrowed slices (owned by the
/// TOML arena / config store); numeric defaults match the C++ initializers.
pub const Settings = struct {
    dock_show_dock: bool = true,
    dock_auto_hide: bool = false,
    dock_radius: i32 = 18,
    dock_icon_size: i32 = 44,
    dock_icon_spacing: i32 = 15,
    dock_bottom_gap: i32 = 6,
    dock_opacity: i32 = 72,
    dock_border_enabled: bool = false,
    dock_border_size: i32 = 1,
    renderer: []const u8 = "vulkan",
    icon_theme: []const u8 = "",

    nightlight_enabled: bool = false,
    nightlight_day_temp: i32 = 6500,
    nightlight_night_temp: i32 = 4000,
    nightlight_schedule: i32 = 0,
    nightlight_start_min: i32 = 1200,
    nightlight_end_min: i32 = 360,

    dock_scale: f64 = 1.0,
    dock_scale_pct: i32 = 100,
    ui_scale: f64 = 1.0,
    dock_widgets_enabled: bool = true,
    dock_group_apps: bool = true,
    dock_tooltips_enabled: bool = true,
    dock_pinned_apps_tray_pill: bool = false,
    dock_running_apps_tray_pill: bool = false,
    dock_output_name: []const u8 = "Auto",
    dock_liquid_glass: bool = true,
    dock_colored_glass: bool = false,
    dock_border_opacity: i32 = 100,
    dock_exclusive_zone_gap: i32 = 0,

    taskbar_enabled: bool = false,
    taskbar_height: i32 = 48,
    taskbar_radius: i32 = 12,
    taskbar_opacity: i32 = 80,
    taskbar_icon_size: i32 = 32,
    taskbar_position_top: bool = false,
    taskbar_group_apps: bool = true,
    taskbar_show_labels: bool = false,
    taskbar_auto_hide: bool = false,
    taskbar_tooltips_enabled: bool = true,
    taskbar_pinned_apps_tray_pill: bool = false,
    taskbar_running_apps_tray_pill: bool = false,
    taskbar_width_mode: i32 = 0,
    taskbar_collapse_when_full: bool = true,
    taskbar_thumbnails_enabled: bool = true,
    taskbar_thumbnail_peek_enabled: bool = true,
    taskbar_thumbnail_threshold: i32 = 10,
    taskbar_compact_media: bool = true,
    taskbar_output_name: []const u8 = "Auto",
    taskbar_widgets_enabled: bool = true,
    // Appearance-child-tab controls (C++ taskbarTab appearance sliders).
    taskbar_icon_spacing: i32 = 0,
    taskbar_border: bool = false,
    taskbar_border_size: i32 = 1,
    taskbar_edge_gap: i32 = 0,
    taskbar_exclusive_zone_gap: i32 = 0,
    taskbar_scale_pct: i32 = 100,

    panel_enabled: bool = false,
    panel_height: i32 = 34,
    panel_radius: i32 = 14,
    panel_opacity: i32 = 96,
    panel_width_mode: i32 = 1,
    panel_position_top: bool = true,
    panel_auto_hide: bool = false,
    panel_reserve_space: bool = true,
    panel_tooltips_enabled: bool = true,
    panel_widgets_enabled: bool = true,
    panel_output_name: []const u8 = "Auto",
    // Appearance-child-tab controls (C++ panelTab appearance sliders).
    panel_icon_size: i32 = 24,
    panel_icon_spacing: i32 = 0,
    panel_border: bool = false,
    panel_border_size: i32 = 1,
    panel_edge_gap: i32 = 0,
    panel_exclusive_zone_gap: i32 = 0,
    panel_scale_pct: i32 = 100,
    panel_floating_amount: i32 = 8,
    panel_overlay_layer: bool = false,
    panel_hover_highlight: bool = true,
    panel_smart_auto_hide: bool = false,
    panel_reveal_on_switch: bool = true,
    panel_scroll_volume: bool = true,
    panel_deadzone_left: []const u8 = "none",
    panel_deadzone_middle: []const u8 = "none",
    panel_deadzone_right: []const u8 = "none",
    panel_capsule: bool = true,
    panel_capsule_opacity: i32 = 100,
    panel_corner_tl: i32 = 12,
    panel_corner_tr: i32 = 12,
    panel_corner_bl: i32 = 12,
    panel_corner_br: i32 = 12,
    panel_icon_theme: []const u8 = "",
    panel_click_through: []const u8 = "", // comma-separated widget ids

    // Monitor form state lives in monitors_state.State (see Content.mon), not
    // here; the generic renderer routes the monitor_* Field variants there.
    matugen_base_recipes: bool = true,

    dashboard_enabled: bool = true,
    dashboard_columns: i32 = 4,

    wallpaper_enabled: bool = false,
    wallpaper_mode: i32 = 0,
    wallpaper_image: []const u8 = "",
    wallpaper_folder: []const u8 = "",
    /// Which dialog the folder buttons open (0 native, 1 kdialog, 2 qarma,
    /// 3 zenity) — `wallpaperFolderPickerMode`, chosen in the modal.
    wallpaper_folder_picker_mode: i32 = 0,

    bing_enabled: bool = false,
    bing_daily_enabled: bool = false,
    bing_download_path: []const u8 = "",
    bing_filter: i32 = 0,
    /// Comma-separated market keywords the Bing tab filters out.
    bing_blocked_keywords: []const u8 = "",

    workspaces_max_slots: i32 = 5,
    workspaces_show_apps: bool = true,
    workspaces_max_icons: i32 = 4,

    notifications_dbus_enabled: bool = true,
    notifications_dnd: bool = false,
    notifications_timeout_ms: i32 = 6000,
    notifications_toast_position: []const u8 = "top_right",
    notifications_scale_pct: i32 = 100,
    notifications_margin_px: i32 = 16,
    notifications_corner_radius_px: i32 = 12,
    notifications_max_width_px: i32 = 420,
    notifications_layer_shell: bool = true,
    notifications_output: []const u8 = "auto",

    matugen_enabled: bool = false,
    matugen_scheme: []const u8 = "scheme-content",
    matugen_mode: []const u8 = "dark",
    horizon_native: bool = true,
    color_theme_enabled: bool = false,
    color_theme_name: []const u8 = "",
    /// Custom-theme RGB triples feeding `resolveColors` (defaults mirror
    /// `settings_app_types.hpp`).
    theme_primary: [3]f32 = .{ 0.769, 0.659, 0.941 },
    theme_on_surface: [3]f32 = .{ 1, 1, 1 },
    theme_surface: [3]f32 = .{ 0.102, 0.075, 0.188 },
    theme_outline: [3]f32 = .{ 0.478, 0.416, 0.588 },
    /// Wallpaper-derived palette payloads, filled by `color/refresh.zig` on
    /// load and wallpaper change. Runtime-only (never persisted): the C++
    /// derives them the same way instead of reading them back.
    horizon_colors_ok: bool = false,
    hc_accent: [3]f32 = .{ 0.90, 0.90, 0.90 },
    hc_text: [3]f32 = .{ 0.92, 0.92, 0.95 },
    hc_surface: [3]f32 = .{ 0.12, 0.12, 0.14 },
    hc_outline: [3]f32 = .{ 0.55, 0.60, 0.62 },
    matugen_palette_ok: bool = false,
    matugen_accent: [3]f32 = .{ 0.90, 0.90, 0.90 },
    matugen_text: [3]f32 = .{ 0.92, 0.92, 0.95 },
    matugen_surface: [3]f32 = .{ 0.12, 0.12, 0.14 },
    matugen_outline: [3]f32 = .{ 0.55, 0.60, 0.62 },
    color_brightness_pct: i32 = 100,
    color_contrast_pct: i32 = 100,
    color_vibrance_pct: i32 = 100,

    overlay_opacity_master_pct: i32 = 100,
    overlay_opacity_settings_pct: i32 = 100,
    overlay_opacity_notifications_pct: i32 = 100,

    launchpad_grid_columns: i32 = 8,
    launchpad_grid_rows: i32 = 5,
    launchpad_layout_scale_pct: i32 = 100,
    launchpad_icon_fill_pct: i32 = 58,
    launchpad_cell_gap_px: i32 = 0,
    launchpad_folder_size_pct: i32 = 100,
    launchpad_folder_gap_px: i32 = 16,
    launchpad_folder_columns: i32 = 3,
    launchpad_folder_rows: i32 = 3,
    launchpad_dpi_scale_pct: i32 = 100,
    launchpad_view_mode: i32 = 0,
    slot_pill_opacity: i32 = 100,
    taskbar_slot_pill_opacity: i32 = 100,

    overview_axis: i32 = 0,
    overview_live_updates: bool = false,
    overview_capture_mode: i32 = 0,
    overview_multi_monitor: bool = false,
    overview_card_scale_pct: i32 = 50,
    overview_card_gap_px: i32 = 24,
    overview_scroll_delay_ms: i32 = 200,
    overview_close_btn_size_px: i32 = 34,
    overview_search_width_px: i32 = 420,

    desktop_enabled: bool = true,

    /// Display-output name desktop widgets appear on ("" = Auto, "all" =
    /// every display).
    desktop_widgets_output_name: []const u8 = "",
    /// Disabled desktop-widget slots, by widget id. Absent means enabled —
    /// the same "only differences tracked" rule as `widget_states`.
    /// Empty by default.
    desktop_widget_slots_disabled: [][]const u8 = &.{},

    power_display_sleep: bool = true,
    power_display_timeout_min: i32 = 10,
    power_idle_suspend: bool = true,
    power_idle_timeout_min: i32 = 30,
    power_button_action: i32 = 0,
    power_lid_action: i32 = 1,
    power_perf_pref: i32 = 1,
    power_tuning_profile: bool = true,
    power_show_battery_pct: bool = true,

    time_use_24h: bool = false,
    time_show_seconds: bool = false,
    time_show_date: bool = true,
    time_date_format: i32 = 0,
    time_timezone: []const u8 = "",

    keyboard_layout: []const u8 = "us",
    keyboard_repeat_rate: i32 = 25,
    keyboard_repeat_delay_ms: i32 = 600,
    keyboard_numlock: bool = true,
    keyboard_middle_paste: bool = true,

    bt_auto_reconnect: bool = true,

    audio_sink_volume_pct: i32 = 100,
    audio_sink_muted: bool = false,
    audio_source_volume_pct: i32 = 100,
    audio_source_muted: bool = false,
    audio_allow_overamp: bool = false,
    audio_engine_rate_hz: i32 = 48000,

    avatar_path: []const u8 = "",
    autostart_enabled: bool = true,
    updater_auto_check: bool = true,

    // Widget section lists per bar (left/center/right), mirroring the
    // `[dock]`/`[taskbar]`/`[panel]` `left_widgets` & co. arrays. Borrowed
    // slices owned by `Win.str_arena`; empty means "defaults apply" exactly
    // like the loader treats it (`widgets.sections` fills in).
    dock_left_widgets: [][]const u8 = &.{},
    dock_center_widgets: [][]const u8 = &.{},
    dock_right_widgets: [][]const u8 = &.{},
    taskbar_left_widgets: [][]const u8 = &.{},
    taskbar_center_widgets: [][]const u8 = &.{},
    taskbar_right_widgets: [][]const u8 = &.{},
    panel_left_widgets: [][]const u8 = &.{},
    panel_center_widgets: [][]const u8 = &.{},
    panel_right_widgets: [][]const u8 = &.{},
    /// Widget instance states (`[widget.<id>]`), again `str_arena`-owned.
    /// Only instances that differ from the all-enabled default are tracked.
    widget_states: []WidgetState = &.{},
};

/// One `[widget.<id>]` entry: the implementation type plus whether the
/// instance is switched on. Carries no settings map
/// (the tab only moves `enabled`; every other key rides along untouched).
pub const WidgetState = struct {
    id: []const u8 = "",
    impl: []const u8 = "",
    enabled: bool = true,
};

/// Window + sidebar runtime state (non-persisted App fields).
pub const AppState = struct {
    width: i32 = window_width,
    height: i32 = window_height,
    active_tab: i32 = 0,
    active_sub_tab: i32 = -1,
    sidebar_scroll_px: i32 = 0,
    search_query_len: usize = 0,
    search_focused: bool = false,
    embedded: bool = false,
    pending_redraw: bool = false,
    maximized: bool = false,

    pub fn contentX() i32 {
        return 16 + 260 + 16;
    }

    pub fn contentW(self: *const AppState) i32 {
        return self.width - contentX() - 16;
    }
};

pub fn tabTitle(tab_id: i32) ?[]const u8 {
    for (sidebar_categories) |cat| {
        for (cat.subs) |s| {
            if (s.tab_id == tab_id) return s.label;
        }
        if (cat.id == tab_id and cat.subs.len == 0) return cat.label;
    }
    return null;
}

pub fn isMangoTab(tab_id: i32) bool {
    return tab_id >= 20 and tab_id <= 26;
}

test "settings-app: tab registry mirrors the sidebar sections" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 7), sidebar_categories.len);
    try t.expectEqualStrings("Dock", tabTitle(0).?);
    try t.expectEqualStrings("Hyprland", tabTitle(33).?);
    try t.expectEqualStrings("VPN", tabTitle(28).?);
    try t.expect(isMangoTab(24));
    try t.expect(!isMangoTab(33));
    const app = AppState{};
    try t.expectEqual(@as(i32, 292), AppState.contentX());
    try t.expectEqual(@as(i32, 900 - 292 - 16), app.contentW());
}
