const std = @import("std");
const toml = @import("toml.zig");
const decode = @import("decode.zig");
const T = toml.Value.Table;
const childTbl = decode.childTbl;
const getBool = decode.getBool;
const getStr = decode.getStr;
const getInt = decode.getInt;
const getFloat = decode.getFloat;
const getFloatStrict = decode.getFloatStrict;
const setBool = decode.setBool;
const setInt = decode.setInt;
const setStr = decode.setStr;
const setStrArray = decode.setStrArray;
const setScale = decode.setScale;
const setOpacity = decode.setOverlayOpacity;
const clampF = decode.clampF;

pub const MatugenToggles = struct {
    run_bundled_toml: bool = true,
    niri: bool = true,
    hyprland: bool = true,
    mango: bool = true,
    gtk_shell_css: bool = true,
    gtk_event_colors_light: bool = true,
    gtk_event_colors_dark: bool = true,
    kcolorscheme: bool = true,
    qt5ct: bool = true,
    qt6ct: bool = true,
    kitty_theme: bool = true,
    kitty_tabs: bool = true,
    ghostty: bool = true,
    wezterm: bool = true,
    alacritty: bool = true,
    foot: bool = true,
    otter_term: bool = true,
    btop: bool = true,
    neovim: bool = true,
    vscode_material: bool = true,
    vscode_color_themes: bool = true,
    firefox: bool = true,
    zenbrowser: bool = true,
    vesktop: bool = true,
    equibop: bool = true,
    pywalfox: bool = true,
    steam: bool = true,
    dgop: bool = true,
    emacs: bool = true,
    zed: bool = true,
    ptyxis: bool = true,
    horizon_files: bool = true,
    horizon_photo: bool = true,
    horizon_calendar: bool = true,
    obs: bool = true,
    heroic: bool = true,
    fluxer: bool = true,
    owler: bool = true,
};

fn decodeToggles(_: std.mem.Allocator, t: *const T, m: *MatugenToggles) !void {
    setBool(t, "run_bundled", &m.run_bundled_toml);
    setBool(t, "niri", &m.niri);
    setBool(t, "hyprland", &m.hyprland);
    setBool(t, "mango", &m.mango);
    if (getBool(t, "gtk_shell_css")) |v| m.gtk_shell_css = v;
    if (getBool(t, "gtk")) |v| {
        if (t.get("gtk_shell_css") == null) m.gtk_shell_css = v;
        if (t.get("gtk_event_colors_light") == null) m.gtk_event_colors_light = v;
        if (t.get("gtk_event_colors_dark") == null) m.gtk_event_colors_dark = v;
    }
    if (getBool(t, "gtk_event_colors_light")) |v| m.gtk_event_colors_light = v;
    if (getBool(t, "gtk_event_colors_dark")) |v| m.gtk_event_colors_dark = v;
    setBool(t, "kcolorscheme", &m.kcolorscheme);
    setBool(t, "qt5ct", &m.qt5ct);
    setBool(t, "qt6ct", &m.qt6ct);
    if (getBool(t, "kitty_theme")) |v| m.kitty_theme = v;
    if (getBool(t, "kitty")) |v| if (t.get("kitty_theme") == null) {
        m.kitty_theme = v;
    };
    if (getBool(t, "kitty_tabs")) |v| m.kitty_tabs = v;
    if (getBool(t, "kitty")) |v| if (t.get("kitty_tabs") == null) {
        m.kitty_tabs = v;
    };
    setBool(t, "ghostty", &m.ghostty);
    setBool(t, "wezterm", &m.wezterm);
    setBool(t, "alacritty", &m.alacritty);
    setBool(t, "foot", &m.foot);
    setBool(t, "otter_term", &m.otter_term);
    setBool(t, "btop", &m.btop);
    setBool(t, "neovim", &m.neovim);
    if (getBool(t, "vscode_material")) |v| m.vscode_material = v;
    if (getBool(t, "vscode")) |v| {
        if (t.get("vscode_material") == null) m.vscode_material = v;
        if (t.get("vscode_color_themes") == null) m.vscode_color_themes = v;
    }
    if (getBool(t, "vscode_color_themes")) |v| m.vscode_color_themes = v;
    setBool(t, "firefox", &m.firefox);
    setBool(t, "zenbrowser", &m.zenbrowser);
    setBool(t, "vesktop", &m.vesktop);
    setBool(t, "equibop", &m.equibop);
    setBool(t, "pywalfox", &m.pywalfox);
    setBool(t, "steam", &m.steam);
    setBool(t, "dgop", &m.dgop);
    setBool(t, "emacs", &m.emacs);
    setBool(t, "zed", &m.zed);
    setBool(t, "ptyxis", &m.ptyxis);
    setBool(t, "horizon_files", &m.horizon_files);
    setBool(t, "horizon_photo", &m.horizon_photo);
    setBool(t, "horizon_calendar", &m.horizon_calendar);
    setBool(t, "obs", &m.obs);
    setBool(t, "heroic", &m.heroic);
    setBool(t, "fluxer", &m.fluxer);
    setBool(t, "owler", &m.owler);
}

pub const Appearance = struct {
    overlay_opacity_advanced: bool = false,
    overlay_opacity_master: f32 = 1.0,
    overlay_opacity_control_center: f32 = 1.0,
    overlay_opacity_control_center_inner: f32 = 1.0,
    overlay_opacity_app_drawer: f32 = 1.0,
    overlay_opacity_launchpad: f32 = 1.0,
    overlay_opacity_settings: f32 = 1.0,
    overlay_opacity_settings_sidebar: f32 = 1.0,
    overlay_opacity_dock_menu: f32 = 1.0,
    overlay_opacity_desktop_menu: f32 = 1.0,
    overlay_opacity_tray_menu: f32 = 1.0,
    overlay_opacity_calendar: f32 = 1.0,
    overlay_opacity_weather: f32 = 1.0,
    overlay_opacity_world_clock: f32 = 1.0,
    overlay_opacity_tooltip: f32 = 1.0,
    overlay_opacity_overview: f32 = 1.0,
    overlay_opacity_widget_card: f32 = 1.0,
    overlay_opacity_notifications: f32 = 1.0,
    launchpad_grid_columns: i32 = 8,
    launchpad_grid_rows: i32 = 5,
    launchpad_cell_gap_px: i32 = 0,
    launchpad_icon_fill_pct: i32 = 58,
    launchpad_layout_scale_pct: i32 = 100,
    launchpad_dpi_scale_pct: i32 = 100,
    launchpad_view_mode: i32 = 0,
    launchpad_folder_size_pct: i32 = 100,
    launchpad_folder_gap_px: i32 = 16,
    launchpad_folder_columns: i32 = 3,
    launchpad_folder_rows: i32 = 3,
    overview_axis: i32 = 0,
    overview_capture_mode: i32 = 0,
    overview_live_updates: bool = false,
    overview_multi_monitor: bool = false,
    overview_card_scale_pct: i32 = 50,
    overview_card_gap_px: i32 = 24,
    overview_scroll_delay_ms: i32 = 200,
    overview_close_btn_size_px: i32 = 34,
    overview_search_width_px: i32 = 420,
    matugen_theming: bool = false,
    horizon_colors_native: bool = true,
    horizon_colors_ok: bool = false,
    matugen_scheme: []const u8 = "scheme-content",
    matugen_mode: []const u8 = "dark",
    matugen_palette_ok: bool = false,
    font_family: []const u8 = "Inter",
    matugen_outputs: MatugenToggles = .{},
    custom_theme_enabled: bool = false,
    active_theme_name: []const u8 = "",
    active_theme_source: []const u8 = "",
    custom_primary: [3]f32 = .{ 0.769, 0.659, 0.941 },
    custom_on_primary: [3]f32 = .{ 1, 1, 1 },
    custom_secondary: [3]f32 = .{ 0.239, 0.125, 0.439 },
    custom_on_secondary: [3]f32 = .{ 1, 1, 1 },
    custom_tertiary: [3]f32 = .{ 0.910, 0.522, 0.290 },
    custom_on_tertiary: [3]f32 = .{ 1, 1, 1 },
    custom_error: [3]f32 = .{ 0.910, 0.416, 0.353 },
    custom_on_error: [3]f32 = .{ 1, 1, 1 },
    custom_surface: [3]f32 = .{ 0.102, 0.075, 0.188 },
    custom_on_surface: [3]f32 = .{ 1, 1, 1 },
    custom_surface_variant: [3]f32 = .{ 0.133, 0.102, 0.227 },
    custom_on_surface_variant: [3]f32 = .{ 1, 1, 1 },
    custom_outline: [3]f32 = .{ 0.478, 0.416, 0.588 },
    custom_shadow: [3]f32 = .{ 0.031, 0.020, 0.063 },
    custom_hover: [3]f32 = .{ 0.212, 0.165, 0.337 },
    custom_on_hover: [3]f32 = .{ 1, 1, 1 },
    /// Brightness/contrast/vibrance/gamma knobs for `derived_chrome_colors`.
    /// Runtime-only (default 1.0 = identity): no TOML keys for
    /// these either, so nothing decodes them.
    color_brightness: f32 = 1.0,
    color_contrast: f32 = 1.0,
    color_vibrance: f32 = 1.0,
    color_gamma: f32 = 1.0,
    /// Wallpaper-derived palette payloads, filled by `color/refresh.zig` on
    /// config load. Runtime-only as well: written to
    /// state-settings.toml for *other* apps but never reads them back, so
    /// neither does the decoder.
    hc_dock_fill: [3]f32 = .{ 0.12, 0.12, 0.14 },
    hc_panel_fill: [3]f32 = .{ 0.08, 0.10, 0.13 },
    hc_drawer_dim: [3]f32 = .{ 0.11, 0.11, 0.13 },
    hc_outline: [3]f32 = .{ 0.55, 0.60, 0.62 },
    hc_accent: [3]f32 = .{ 0.90, 0.90, 0.90 },
    hc_text: [3]f32 = .{ 0.92, 0.92, 0.95 },
    hc_notif_bg: [3]f32 = .{ 0.18, 0.06, 0.06 },
    hc_notif_ol: [3]f32 = .{ 0.70, 0.10, 0.10 },
    matugen_dock_fill: [3]f32 = .{ 0.12, 0.12, 0.14 },
    matugen_panel_fill: [3]f32 = .{ 0.08, 0.10, 0.13 },
    matugen_drawer_dim: [3]f32 = .{ 0.11, 0.11, 0.13 },
    matugen_outline: [3]f32 = .{ 0.55, 0.60, 0.62 },
    matugen_accent: [3]f32 = .{ 0.90, 0.90, 0.90 },
    matugen_text: [3]f32 = .{ 0.92, 0.92, 0.95 },
    matugen_notif_bg: [3]f32 = .{ 0.18, 0.06, 0.06 },
    matugen_notif_ol: [3]f32 = .{ 0.70, 0.10, 0.10 },
};

fn setColor(t: *const T, base: []const u8, field: *[3]f32, alloc: std.mem.Allocator) void {
    _ = alloc;
    var tmp: [64]u8 = undefined;
    const keys = [_][]const u8{ "_r", "_g", "_b" };
    for (keys, 0..) |suf, i| {
        const key = std.fmt.bufPrint(&tmp, "{s}{s}", .{ base, suf }) catch continue;
        if (getFloatStrict(t, key)) |d| {
            field.*[i] = clampF(d, 0.0, 1.0);
        }
    }
}

pub fn decodeAppearance(alloc: std.mem.Allocator, t: *const T, a: *Appearance) !void {
    setBool(t, "overlay_opacity_advanced", &a.overlay_opacity_advanced);
    inline for (.{
        .{ "overlay_opacity_master", "overlay_opacity_master" },
        .{ "overlay_opacity_control_center", "overlay_opacity_control_center" },
        .{ "overlay_opacity_control_center_inner", "overlay_opacity_control_center_inner" },
        .{ "overlay_opacity_app_drawer", "overlay_opacity_app_drawer" },
        .{ "overlay_opacity_launchpad", "overlay_opacity_launchpad" },
        .{ "overlay_opacity_settings", "overlay_opacity_settings" },
        .{ "overlay_opacity_settings_sidebar", "overlay_opacity_settings_sidebar" },
        .{ "overlay_opacity_dock_menu", "overlay_opacity_dock_menu" },
        .{ "overlay_opacity_desktop_menu", "overlay_opacity_desktop_menu" },
        .{ "overlay_opacity_tray_menu", "overlay_opacity_tray_menu" },
        .{ "overlay_opacity_calendar", "overlay_opacity_calendar" },
        .{ "overlay_opacity_weather", "overlay_opacity_weather" },
        .{ "overlay_opacity_world_clock", "overlay_opacity_world_clock" },
        .{ "overlay_opacity_tooltip", "overlay_opacity_tooltip" },
        .{ "overlay_opacity_overview", "overlay_opacity_overview" },
        .{ "overlay_opacity_widget_card", "overlay_opacity_widget_card" },
        .{ "overlay_opacity_notifications", "overlay_opacity_notifications" },
    }) |pair| {
        setOpacity(t, pair[0], &@field(a, pair[1]));
    }
    setInt(t, "launchpad_grid_columns", &a.launchpad_grid_columns, 4, 12);
    setInt(t, "launchpad_grid_rows", &a.launchpad_grid_rows, 3, 10);
    setInt(t, "launchpad_cell_gap_px", &a.launchpad_cell_gap_px, 0, 24);
    setInt(t, "launchpad_icon_fill_pct", &a.launchpad_icon_fill_pct, 30, 95);
    setInt(t, "launchpad_layout_scale_pct", &a.launchpad_layout_scale_pct, 70, 150);
    setInt(t, "launchpad_dpi_scale_pct", &a.launchpad_dpi_scale_pct, 50, 300);
    setInt(t, "launchpad_view_mode", &a.launchpad_view_mode, 0, 1);
    setInt(t, "launchpad_folder_size_pct", &a.launchpad_folder_size_pct, 50, 200);
    setInt(t, "launchpad_folder_gap_px", &a.launchpad_folder_gap_px, 4, 48);
    setInt(t, "launchpad_folder_columns", &a.launchpad_folder_columns, 2, 8);
    setInt(t, "launchpad_folder_rows", &a.launchpad_folder_rows, 1, 6);
    setInt(t, "overview_axis", &a.overview_axis, 0, 1);
    setInt(t, "overview_capture_mode", &a.overview_capture_mode, 0, 1);
    setBool(t, "overview_live_updates", &a.overview_live_updates);
    setBool(t, "overview_multi_monitor", &a.overview_multi_monitor);
    setInt(t, "overview_card_scale_pct", &a.overview_card_scale_pct, 20, 80);
    setInt(t, "overview_card_gap_px", &a.overview_card_gap_px, 8, 80);
    setInt(t, "overview_scroll_delay_ms", &a.overview_scroll_delay_ms, 50, 500);
    setInt(t, "overview_close_btn_size_px", &a.overview_close_btn_size_px, 20, 60);
    setInt(t, "overview_search_width_px", &a.overview_search_width_px, 200, 800);
    setBool(t, "matugen_theming", &a.matugen_theming);
    setBool(t, "horizon_colors_native", &a.horizon_colors_native);
    try setStr(alloc, t, "matugen_scheme", &a.matugen_scheme);
    try setStr(alloc, t, "matugen_mode", &a.matugen_mode);
    if (childTbl(t, "matugen_templates")) |mt| try decodeToggles(alloc, mt, &a.matugen_outputs);
    setBool(t, "color_theme_enabled", &a.custom_theme_enabled);
    try setStr(alloc, t, "color_theme_name", &a.active_theme_name);
    try setStr(alloc, t, "color_theme_source", &a.active_theme_source);
    inline for (.{
        .{ "color_theme_primary", "custom_primary" },
        .{ "color_theme_on_primary", "custom_on_primary" },
        .{ "color_theme_secondary", "custom_secondary" },
        .{ "color_theme_on_secondary", "custom_on_secondary" },
        .{ "color_theme_tertiary", "custom_tertiary" },
        .{ "color_theme_on_tertiary", "custom_on_tertiary" },
        .{ "color_theme_error", "custom_error" },
        .{ "color_theme_on_error", "custom_on_error" },
        .{ "color_theme_surface", "custom_surface" },
        .{ "color_theme_on_surface", "custom_on_surface" },
        .{ "color_theme_surface_variant", "custom_surface_variant" },
        .{ "color_theme_on_surface_variant", "custom_on_surface_variant" },
        .{ "color_theme_outline", "custom_outline" },
        .{ "color_theme_shadow", "custom_shadow" },
        .{ "color_theme_hover", "custom_hover" },
        .{ "color_theme_on_hover", "custom_on_hover" },
    }) |pair| {
        setColor(t, pair[0], &@field(a, pair[1]), alloc);
    }
}
