const std = @import("std");
const hyprland_page = @import("hyprland_page.zig");
const zoolander_page = @import("zoolander_page.zig");
const overlay = @import("../../config/overlay.zig");

// Full Settings state model — all persisted fields plus the `App` window/sidebar geometry.
// Same design and layout: window 900x980, sidebar 260px, content area
// to the right of the sidebar, per-tab scroll offsets, numeric tab ids.
//
// Numeric tab ids match the sidebar defs exactly. The rail categories are
// sorted A-Z by label; the list below follows that order:
//   Accounts(46): 46 Accounts
//   Appearance(2): 2 General, 45 Themes, 50 Color Themes, 44 Icons, 79 Opacity,
//                 80 Color, 3 Templates
//   Bluetooth(47): 47 Bluetooth (single-page rail category)
//   Default Apps(10): 10 Default Apps
//   Display(13): 7 Monitors, 19 Nightlight
//   Hyprland(33): 64 General, 65 Decoration, 66 Input, 67 Binds, 68 Dwindle, 69 Master,
//                 70 Scrolling, 71 Animations, 72 Misc, 73 Render, 74 Cursor, 75 Group,
//                 76 XWayland, 77 OpenGL, 78 Quirks
//   MangoWM(16): 20 Decoration, 21 Colors, 22 Animations, 23 Keybinds, 24 Layout, 25 Input, 26 Misc
//   Network(85): 18 Wired, 28 VPN
//   Panels&UI(12): 0 Dock, 1 Panel, 11 Taskbar, 9 Launcher, 29 Desktop, 27 Desktop Widgets
//   Sound(18): 8 Devices, 81 Bluetooth Audio, 82 Apps, 83 Engine
//   System(14): 5 Notifications, 31 Keyboard, 32 Power, 48 Startup
//   Time(35): 30 System Time, 84 World Clock
//   Updates(51): 51 Updates
//   Wallpaper(15): 6 Wallpaper, 34 Bing
//   Wi-Fi(17): 17 Wi-Fi (single-page rail category)
//
// MangoWM's rail category keeps id 16 to itself on purpose: tab 16 used to
// double as the Bing Wallpaper page, which made every Bing click land on
// the MangoWM list. Bing now lives on 34 and MangoWM — gated to Mango-only
// visibility by `compositor.visibleCategory` — owns 16 exclusively.

pub const window_width: i32 = 900;
pub const window_height: i32 = 980;

pub const TabId = struct {
    pub const dock: i32 = 0;
    pub const appearance: i32 = 2;
    /// Appearance child pages appended after the Hyprland range: the
    /// per-surface opacity tile grid and the color-adjustment tile grid.
    /// List order in `appearance_subs` is General | Themes | Color Themes |
    /// Icons | Opacity | Color | Templates, so these ids are non-contiguous
    /// on purpose.
    pub const appearance_opacity: i32 = 79;
    pub const appearance_color: i32 = 80;
    /// Appearance child page: matugen template toggles.
    pub const appearance_templates: i32 = 3;
    pub const notifications: i32 = 5;
    pub const wallpaper: i32 = 6;
    pub const monitors: i32 = 7;
    pub const sound: i32 = 8;
    /// Sound rail children, appended after the Hyprland range: the Audio
    /// Center's Bluetooth-audio, per-app stream and engine pages.
    pub const sound_bt_audio: i32 = 81;
    pub const sound_apps: i32 = 82;
    pub const sound_engine: i32 = 83;
    pub const launcher: i32 = 9;
    pub const default_apps: i32 = 10;
    pub const taskbar: i32 = 11;
    pub const bing: i32 = 34;
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
    /// Time rail child: the shared world-clock city editor, split out of the
    /// old single Time page so the two halves read as their own list rows.
    pub const world_clock: i32 = 84;
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
    .{ .label = "Taskbar", .glyph = "dock_to_bottom", .tab_id = 11 },
    .{ .label = "Launcher", .glyph = "apps", .tab_id = 9 },
    .{ .label = "Desktop", .glyph = "desktop_windows", .tab_id = 29 },
    .{ .label = "Desktop Widgets", .glyph = "widgets", .tab_id = 27 },
};

pub const display_subs = [_]SidebarSub{
    .{ .label = "Monitors", .glyph = "monitor", .tab_id = 7 },
    .{ .label = "Nightlight", .glyph = "dark_mode", .tab_id = 19 },
};

/// Appearance's own rail category (directly below Panels & UI). Its child
/// pages read General | Themes | Color Themes | Icons | Opacity | Color |
/// Templates in the inner list column, like every other category's subs, so
/// there is no in-page child strip.
pub const appearance_subs = [_]SidebarSub{
    .{ .label = "General", .glyph = "palette", .tab_id = 2 },
    .{ .label = "Themes", .glyph = "palette", .tab_id = 45 },
    .{ .label = "Color Themes", .glyph = "colorize", .tab_id = 50 },
    .{ .label = "Icons", .glyph = "photo_library", .tab_id = 44 },
    .{ .label = "Opacity", .glyph = "layers", .tab_id = 79 },
    .{ .label = "Color", .glyph = "colorize", .tab_id = 80 },
    .{ .label = "Templates", .glyph = "app_registration", .tab_id = 3 },
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
    .{ .label = "Keyboard & Language", .glyph = "keyboard", .tab_id = 31 },
    .{ .label = "Power", .glyph = "power_settings_new", .tab_id = 32 },
    .{ .label = "Startup", .glyph = "play_arrow", .tab_id = 48 },
};

/// Time rail category — the old single Time page split into its two halves,
/// now the category's list rows: the format / date / preview / network-time
/// / timezone stack and the world-clock city editor (one `time_tab.Page`
/// serving both, so the editor's list, picker and stores stay shared).
pub const time_subs = [_]SidebarSub{
    .{ .label = "System Time", .glyph = "schedule", .tab_id = 30 },
    .{ .label = "World Clock", .glyph = "public", .tab_id = 84 },
};

/// Sound rail category — the C++ Audio Center ported whole (Devices |
/// Bluetooth | Apps | Engine), each row opening a self-painted live page
/// (`sound_tab.zig`).
pub const sound_subs = [_]SidebarSub{
    .{ .label = "Devices", .glyph = "speaker", .tab_id = 8 },
    .{ .label = "Bluetooth Audio", .glyph = "bluetooth", .tab_id = 81 },
    .{ .label = "Apps", .glyph = "apps", .tab_id = 82 },
    .{ .label = "Engine", .glyph = "tune", .tab_id = 83 },
};

pub const wallpaper_subs = [_]SidebarSub{
    .{ .label = "Wallpaper", .glyph = "wallpaper", .tab_id = 6 },
    .{ .label = "Bing Wallpaper", .glyph = "photo_library", .tab_id = 34 },
};

pub const network_subs = [_]SidebarSub{
    .{ .label = "Wired", .glyph = "lan", .tab_id = 18 },
    .{ .label = "VPN", .glyph = "vpn_key", .tab_id = 28 },
};

/// Hyprland section pages, one rail row each (`hyprland_page.sections`
/// mapped onto the sidebar's sub shape, so the list column reads them
/// exactly like every other category's pages). The MangoWM category above
/// stays a separate rail entry: `compositor.visibleCategory` shows it only
/// while Mango itself is running, the way Hyprland's section band is
/// Hyprland-only.
pub const hyprland_subs = blk: {
    var subs: [hyprland_page.sections.len]SidebarSub = undefined;
    for (hyprland_page.sections, 0..) |sec, i| {
        subs[i] = .{ .label = sec.label, .glyph = sec.glyph, .tab_id = sec.tab_id };
    }
    break :blk subs;
};

/// Zoolander's rail rows: one page per group of Lua setters. The category
/// itself is hidden unless Zoolander is running (`compositor.visibleCategory`
/// on `zoolander_category_id`).
pub const zoolander_category_id: i32 = 100;

pub const zoolander_subs = blk: {
    var subs: [zoolander_page.sections.len]SidebarSub = undefined;
    for (zoolander_page.sections, 0..) |sec, i| {
        subs[i] = .{ .label = sec.label, .glyph = sec.glyph, .tab_id = sec.tab_id };
    }
    break :blk subs;
};

/// Rail categories, sorted A-Z by label. A category with no subs is a
/// single-page entry: its id is the page tab, per `pageTab`, so the rail
/// button opens that page directly.
pub const sidebar_categories = [_]SidebarCategory{
    .{ .id = 46, .label = "Accounts", .glyph = "account_circle", .subs = &.{} },
    .{ .id = 2, .label = "Appearance", .glyph = "palette", .subs = &appearance_subs },
    // Bluetooth and Wi-Fi left their old parent categories for their own
    // rail entries. Their ids are also their page ids.
    .{ .id = 47, .label = "Bluetooth", .glyph = "bluetooth", .subs = &.{} },
    .{ .id = 10, .label = "Default Apps", .glyph = "app_registration", .subs = &.{} },
    .{ .id = 13, .label = "Display", .glyph = "display_settings", .subs = &display_subs },
    .{ .id = 33, .label = "Hyprland", .glyph = "layers", .subs = &hyprland_subs },
    .{ .id = 16, .label = "MangoWM", .glyph = "view_module", .subs = &mango_subs },
    // Network keeps the wired and VPN pages. Its old id 17 was also the
    // Wi-Fi page, so the rail id moved out of the page-id range.
    .{ .id = 85, .label = "Network", .glyph = "wifi", .subs = &network_subs },
    .{ .id = 12, .label = "Panels & UI", .glyph = "dashboard", .subs = &panels_ui_subs },
    .{ .id = 18, .label = "Sound", .glyph = "volume_up", .subs = &sound_subs },
    .{ .id = 14, .label = "System", .glyph = "tune", .subs = &system_subs },
    .{ .id = 35, .label = "Time", .glyph = "schedule", .subs = &time_subs },
    .{ .id = 51, .label = "Updates", .glyph = "system_update", .subs = &.{} },
    .{ .id = 15, .label = "Wallpaper Settings", .glyph = "wallpaper", .subs = &wallpaper_subs },
    .{ .id = 17, .label = "Wi-Fi", .glyph = "wifi", .subs = &.{} },
    .{ .id = zoolander_category_id, .label = "Zoolander", .glyph = "layers", .subs = &zoolander_subs },
};

/// Persisted settings — one field per Settings struct member in
/// Strings are borrowed slices (owned by the
/// TOML arena / config store).
pub const Settings = struct {
    dock_show_dock: bool = true,
    dock_auto_hide: bool = false,
    dock_radius: i32 = 18,
    dock_icon_size: i32 = 44,
    dock_icon_spacing: i32 = 15,
    /// Px between island pills (`[dock] island_gap`).
    dock_island_gap: i32 = 9,
    dock_bottom_gap: i32 = 6,
    dock_opacity: i32 = 72,
    dock_border_enabled: bool = false,
    dock_border_size: i32 = 1,
    renderer: []const u8 = "cairo",
    icon_theme: []const u8 = "",

    nightlight_enabled: bool = false,
    nightlight_day_temp: i32 = 6500,
    nightlight_night_temp: i32 = 4000,
    nightlight_schedule: i32 = 0,
    nightlight_start_min: i32 = 1200,
    nightlight_end_min: i32 = 360,
    nightlight_use_location: bool = false,
    nightlight_latitude: i32 = 0,
    nightlight_longitude: i32 = 0,

    dock_scale: f64 = 1.0,
    dock_scale_pct: i32 = 100,
    ui_scale: f64 = 1.0,
    dock_widgets_enabled: bool = true,
    dock_group_apps: bool = true,
    dock_tooltips_enabled: bool = true,
    dock_slim: bool = false,
    dock_pinned_apps_tray_pill: bool = false,
    dock_running_apps_tray_pill: bool = false,
    dock_output_name: []const u8 = "Auto",
    dock_liquid_glass: bool = true,
    dock_colored_glass: bool = false,
    dock_icon_frames: bool = true,
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
    // Appearance-child-tab controls (taskbar appearance sliders).
    taskbar_icon_spacing: i32 = 0,
    taskbar_border: bool = false,
    taskbar_border_size: i32 = 1,
    taskbar_edge_gap: i32 = 0,
    taskbar_exclusive_zone_gap: i32 = 0,
    taskbar_scale_pct: i32 = 100,

    // Default Apps stored desktop ids (one per slot, `default_apps.toml`).
    default_apps_web: []const u8 = "",
    default_apps_mail: []const u8 = "",
    default_apps_calendar: []const u8 = "",
    default_apps_files: []const u8 = "",
    default_apps_terminal: []const u8 = "",
    default_apps_music: []const u8 = "",
    default_apps_video: []const u8 = "",
    default_apps_images: []const u8 = "",
    default_apps_pdf: []const u8 = "",

    // Appearance-child-tab controls (panel appearance sliders).

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
    /// Per-app external-template switches (`[appearance.matugen_templates]`,
    /// keys in the same order as `templates_registry.templates`).
    matugen_templates: [37]bool = @splat(true),
    horizon_native: bool = true,
    color_theme_enabled: bool = false,
    color_theme_name: []const u8 = "",
    /// Custom-theme RGB triples feeding `resolveColors` (defaults mirror
    /// settings types).
    theme_primary: [3]f32 = .{ 0.769, 0.659, 0.941 },
    theme_on_surface: [3]f32 = .{ 1, 1, 1 },
    theme_surface: [3]f32 = .{ 0.102, 0.075, 0.188 },
    theme_outline: [3]f32 = .{ 0.478, 0.416, 0.588 },
    /// Wallpaper-derived palette payloads, filled by `color/refresh.zig` on
    /// load and wallpaper change. Runtime-only (never persisted).
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
    color_gamma_pct: i32 = 100,

    /// Overlay-opacity grid on the Appearance page. Percentages (0-100);
    /// the config file stores 0..1 floats.
    overlay_opacity_advanced: bool = false,
    overlay_opacity_master_pct: i32 = 100,
    overlay_opacity_control_center_pct: i32 = 100,
    overlay_opacity_control_center_inner_pct: i32 = 100,
    overlay_opacity_app_drawer_pct: i32 = 100,
    overlay_opacity_launchpad_pct: i32 = 100,
    overlay_opacity_settings_pct: i32 = 100,
    overlay_opacity_settings_sidebar_pct: i32 = 100,
    overlay_opacity_dock_menu_pct: i32 = 100,
    overlay_opacity_desktop_menu_pct: i32 = 100,
    overlay_opacity_tray_menu_pct: i32 = 100,
    overlay_opacity_calendar_pct: i32 = 100,
    overlay_opacity_weather_pct: i32 = 100,
    overlay_opacity_world_clock_pct: i32 = 100,
    overlay_opacity_tooltip_pct: i32 = 100,
    overlay_opacity_widget_card_pct: i32 = 100,
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
    time_custom_format: []const u8 = "",
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
    /// Engine page combo contents (`[audio] engine_rate_values` /
    /// `engine_quantum_values`); 0 length means the page's built-ins.
    audio_rate_values: [16]i32 = [_]i32{0} ** 16,
    audio_rate_values_len: u8 = 0,
    audio_quantum_values: [16]i32 = [_]i32{0} ** 16,
    audio_quantum_values_len: u8 = 0,

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
    /// Widget island specs drawn as their own floating pill (`[dock]
    /// islands`): widget ids, `+`-linked groups, or `@left`/`@center`/
    /// `@right` section tags. `str_arena`-owned; empty keeps the classic
    /// single bar.
    dock_island_widgets: [][]const u8 = &.{},
    taskbar_left_widgets: [][]const u8 = &.{},
    taskbar_center_widgets: [][]const u8 = &.{},
    taskbar_right_widgets: [][]const u8 = &.{},
    /// Widget instance states (`[widget.<id>]`), again `str_arena`-owned.
    /// Only instances that differ from the all-enabled default are tracked.
    widget_states: []WidgetState = &.{},

    /// Appearance → Opacity: the `Settings` overlay scale this window's own
    /// glass follows. Advanced off reads the master, otherwise the settings
    /// knob — `overlay_surface_alpha_scale(.., .Settings)`. 1.0 at defaults.
    pub fn glassScale(self: *const Settings) f64 {
        const pct: i32 = if (self.overlay_opacity_advanced)
            self.overlay_opacity_settings_pct
        else
            self.overlay_opacity_master_pct;
        // The page edits *body opacity*, the paint sites carry this as a
        // multiplier on the 0.78 design fill — so the percent divides back
        // through the design and 100% reaches a solid body (cairo saturates
        // the small overage). Advanced off, the master's 0.55 reference body
        // is the divisor, exactly like `overlay.master_design`.
        const design: f64 = if (self.overlay_opacity_advanced)
            overlay.designAlpha(.settings)
        else
            overlay.master_design;
        return @as(f64, @floatFromInt(std.math.clamp(pct, 0, 100))) / 100.0 / design;
    }

    /// Appearance → Opacity: `overlay_opacity_settings_sidebar` as the
    /// multiplier the sidebar paints its 0.78 fill with — same percent-of-
    /// body conversion as `glassScale` (its own knob, no master fallback).
    pub fn sidebarScale(self: *const Settings) f64 {
        return @as(f64, @floatFromInt(std.math.clamp(self.overlay_opacity_settings_sidebar_pct, 0, 100))) / 100.0 / overlay.designAlpha(.settings);
    }
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
    try t.expectEqual(@as(usize, 16), sidebar_categories.len);
    // The rail is sorted A-Z by label.
    var prev: []const u8 = "";
    for (sidebar_categories) |cat| {
        try t.expect(std.mem.order(u8, prev, cat.label) == .lt);
        prev = cat.label;
    }
    for (sidebar_categories, 0..) |a, i| {
        for (sidebar_categories[i + 1 ..]) |b| try t.expect(a.id != b.id);
    }
    try t.expectEqualStrings("Dock", tabTitle(0).?);
    try t.expectEqualStrings("VPN", tabTitle(28).?);
    // Sound is its own rail category now — the Audio Center's four live
    // pages read as its list rows (Devices | Bluetooth Audio | Apps |
    // Engine) and no longer sit under System.
    try t.expectEqualStrings("Devices", tabTitle(8).?);
    try t.expectEqualStrings("Bluetooth Audio", tabTitle(81).?);
    try t.expectEqualStrings("Apps", tabTitle(82).?);
    try t.expectEqualStrings("Engine", tabTitle(83).?);
    try t.expectEqual(@as(usize, 4), sound_subs.len);
    for (system_subs) |s| {
        try t.expect(s.tab_id != 8); // Sound owns its four pages now.
        try t.expect(s.tab_id != 47); // Bluetooth owns its own rail entry.
        // Time, Default Apps, Accounts and Updates left the System list for
        // their own rail entries.
        try t.expect(s.tab_id != 30 and s.tab_id != 10 and s.tab_id != 46 and s.tab_id != 51);
    }
    try t.expectEqual(@as(usize, 4), system_subs.len);
    // Time is a rail category with two list rows now (System Time | World
    // Clock); the rail id itself answers nothing, like Hyprland's 33.
    try t.expectEqualStrings("System Time", tabTitle(30).?);
    try t.expectEqualStrings("World Clock", tabTitle(84).?);
    try t.expect(tabTitle(35) == null);
    try t.expectEqual(@as(usize, 2), time_subs.len);
    // Default Apps / Accounts / Updates are single-page rail categories:
    // their category id is their page id, so `tabTitle` still resolves them.
    try t.expectEqualStrings("Default Apps", tabTitle(10).?);
    try t.expectEqualStrings("Accounts", tabTitle(46).?);
    try t.expectEqualStrings("Updates", tabTitle(51).?);
    // Bluetooth and Wi-Fi are single-page rail categories. Network keeps
    // the Wired and VPN pages and has its own rail id.
    try t.expectEqualStrings("Bluetooth", tabTitle(47).?);
    try t.expectEqualStrings("Wi-Fi", tabTitle(17).?);
    try t.expectEqualStrings("Wired", tabTitle(18).?);
    try t.expectEqualStrings("VPN", tabTitle(28).?);
    try t.expectEqual(@as(usize, 2), network_subs.len);
    // Appearance now carries the theme pages and Icons alongside its own
    // General / Opacity / Color / Templates pages.
    try t.expectEqualStrings("General", tabTitle(2).?);
    try t.expectEqualStrings("Themes", tabTitle(45).?);
    try t.expectEqualStrings("Color Themes", tabTitle(50).?);
    try t.expectEqualStrings("Icons", tabTitle(44).?);
    try t.expectEqualStrings("Opacity", tabTitle(79).?);
    try t.expectEqualStrings("Color", tabTitle(80).?);
    try t.expectEqualStrings("Templates", tabTitle(3).?);
    try t.expectEqual(@as(usize, 7), appearance_subs.len);
    try t.expectEqual(@as(usize, 2), display_subs.len);
    for (display_subs) |s| try t.expect(s.tab_id != 2 and s.tab_id != 45 and s.tab_id != 50 and s.tab_id != 44);
    // The Hyprland rail category expands into section pages: the category
    // itself has subs now, so `tabTitle` answers for the section tabs
    // (64 = General … 78 = Quirks) and not for the rail id 33.
    try t.expect(tabTitle(33) == null);
    try t.expectEqualStrings("General", tabTitle(64).?);
    try t.expectEqualStrings("Binds", tabTitle(67).?);
    // Bing owns its own tab id — it shares nothing with MangoWM's rail id.
    try t.expectEqualStrings("Bing Wallpaper", tabTitle(34).?);
    try t.expectEqualStrings("Decoration", tabTitle(20).?);
    try t.expect(isMangoTab(24));
    try t.expect(!isMangoTab(33));
    // Zoolander is its own rail category with one page per setter group.
    try t.expectEqual(zoolander_category_id, sidebar_categories[sidebar_categories.len - 1].id);
    try t.expectEqualStrings("Keyboard", tabTitle(86).?);
    try t.expectEqualStrings("Workspaces & Layouts", tabTitle(92).?);
    try t.expectEqualStrings("XWayland", tabTitle(93).?);
    try t.expect(tabTitle(zoolander_category_id) == null);
    const app = AppState{};
    try t.expectEqual(@as(i32, 292), AppState.contentX());
    try t.expectEqual(@as(i32, 900 - 292 - 16), app.contentW());
}

test "settings-app: overlay glass scales follow the opacity knobs" {
    const t = std.testing;
    // Advanced off: the window body reads the master; the sidebar reads its
    // own knob raw (no master fallback) — the C++ settings app's exact reads.
    var s = Settings{};
    s.overlay_opacity_advanced = false;
    s.overlay_opacity_master_pct = 40;
    s.overlay_opacity_settings_pct = 90;
    s.overlay_opacity_settings_sidebar_pct = 70;
    try t.expectApproxEqAbs(0.40 / 0.55, s.glassScale(), 1e-9);
    try t.expectApproxEqAbs(0.70 / 0.78, s.sidebarScale(), 1e-9);
    // Advanced on: each knob for itself; both clamp like the loader does.
    s.overlay_opacity_advanced = true;
    try t.expectApproxEqAbs(0.90 / 0.78, s.glassScale(), 1e-9);
    // 100% is body opacity 1.0, i.e. the 1/0.78 multiplier both paint with.
    s.overlay_opacity_settings_pct = 100;
    s.overlay_opacity_settings_sidebar_pct = 100;
    try t.expectApproxEqAbs(1.0 / 0.78, s.glassScale(), 1e-9);
    try t.expectApproxEqAbs(1.0 / 0.78, s.sidebarScale(), 1e-9);
    s.overlay_opacity_settings_pct = 250;
    s.overlay_opacity_settings_sidebar_pct = -5;
    try t.expectApproxEqAbs(1.0 / 0.78, s.glassScale(), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0.0), s.sidebarScale(), 1e-9);
}
