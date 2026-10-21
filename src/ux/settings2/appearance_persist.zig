//! The `[appearance]` section of
//! `~/.config/Event-Horizon/appearance/appearance.toml`.
//!
//! Shared by three UI surfaces: the Launcher/Overview cards (`launchpad_*`,
//! `overview_*`), the Appearance rail category's General page (overlay
//! opacity grid + the matugen scheme/mode controls) and its Templates page
//! (`[appearance.matugen_templates]`). Same narrow rule as `dock_persist`:
//! force exactly the keys this writer owns, leaving the rest of the document
//! byte-for-byte intact. `load` is the other half — without it the first
//! save would write the struct's defaults over whatever the file already
//! held.

const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const overlay = @import("../../config/overlay.zig");
const section_store = @import("../../config/section_store.zig");

pub const component = "appearance";
pub const section = "appearance";
/// The template switches live in their own sub-table so the parent pass
/// (`section`) never walks over them: `applySection` stops at the next
/// header line, whatever its name.
pub const templates_section = "appearance.matugen_templates";

/// The config stores the overlay opacities as multipliers on each surface's
/// designed body alpha (1.0 = the design), while the page works in whole
/// percents *of the body*: 0% shows nothing and 100% must be fully opaque.
/// `design` — `overlay.designAlpha`'s number for that knob's surface — is the
/// bridge: the percent shown is `min(1, v * design)`, and 100% saves
/// `1 / design`, a hair past 1.0 where the body saturates.
fn pctFromUnit(v: f32, design: f64) i32 {
    const body = std.math.clamp(@as(f64, v) * design, 0.0, 1.0);
    return @intFromFloat(@round(body * 100.0));
}

fn unitFromPct(v: i32, design: f64) f64 {
    const c = @max(0, @min(100, v));
    return (@as(f64, @floatFromInt(c)) / 100.0) / design;
}

/// Seed the Launcher + Overview + Appearance cards from a decoded
/// `[appearance]` section.
// Covers every launchpad_* key the Launcher child owns, the nine overview_*
// keys the Overview child (and the Desktop tab's Overview card) share, the
// overlay grid and the matugen controls. `alloc` owns the two borrowed
// strings (scheme/mode): the loaded config arena is freed right after
// `seedFromConfig`, so they have to be copied into the window's arena.
pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, a: *const cfg.AppearanceSettings) void {
    s.launchpad_grid_columns = a.launchpad_grid_columns;
    s.launchpad_grid_rows = a.launchpad_grid_rows;
    s.launchpad_cell_gap_px = a.launchpad_cell_gap_px;
    s.launchpad_icon_fill_pct = a.launchpad_icon_fill_pct;
    s.launchpad_layout_scale_pct = a.launchpad_layout_scale_pct;
    s.launchpad_dpi_scale_pct = a.launchpad_dpi_scale_pct;
    s.launchpad_view_mode = a.launchpad_view_mode;
    s.launchpad_folder_size_pct = a.launchpad_folder_size_pct;
    s.launchpad_folder_gap_px = a.launchpad_folder_gap_px;
    s.launchpad_folder_columns = a.launchpad_folder_columns;
    s.launchpad_folder_rows = a.launchpad_folder_rows;
    s.overview_axis = a.overview_axis;
    s.overview_capture_mode = a.overview_capture_mode;
    s.overview_live_updates = a.overview_live_updates;
    s.overview_multi_monitor = a.overview_multi_monitor;
    s.overview_card_scale_pct = a.overview_card_scale_pct;
    s.overview_card_gap_px = a.overview_card_gap_px;
    s.overview_scroll_delay_ms = a.overview_scroll_delay_ms;
    s.overview_close_btn_size_px = a.overview_close_btn_size_px;
    s.overview_search_width_px = a.overview_search_width_px;

    // Appearance General: overlay grid + matugen controls.
    s.overlay_opacity_advanced = a.overlay_opacity_advanced;
    s.overlay_opacity_master_pct = pctFromUnit(a.overlay_opacity_master, overlay.master_design);
    s.overlay_opacity_control_center_pct = pctFromUnit(a.overlay_opacity_control_center, overlay.designAlpha(.control_center));
    s.overlay_opacity_control_center_inner_pct = pctFromUnit(a.overlay_opacity_control_center_inner, overlay.designAlpha(.control_center));
    s.overlay_opacity_app_drawer_pct = pctFromUnit(a.overlay_opacity_app_drawer, overlay.designAlpha(.app_drawer));
    s.overlay_opacity_launchpad_pct = pctFromUnit(a.overlay_opacity_launchpad, overlay.designAlpha(.launchpad));
    s.overlay_opacity_settings_pct = pctFromUnit(a.overlay_opacity_settings, overlay.designAlpha(.settings));
    s.overlay_opacity_settings_sidebar_pct = pctFromUnit(a.overlay_opacity_settings_sidebar, overlay.designAlpha(.settings));
    s.overlay_opacity_dock_menu_pct = pctFromUnit(a.overlay_opacity_dock_menu, overlay.designAlpha(.dock_menu));
    s.overlay_opacity_desktop_menu_pct = pctFromUnit(a.overlay_opacity_desktop_menu, overlay.designAlpha(.desktop_menu));
    s.overlay_opacity_tray_menu_pct = pctFromUnit(a.overlay_opacity_tray_menu, overlay.designAlpha(.tray_menu));
    s.overlay_opacity_calendar_pct = pctFromUnit(a.overlay_opacity_calendar, overlay.designAlpha(.calendar));
    s.overlay_opacity_weather_pct = pctFromUnit(a.overlay_opacity_weather, overlay.designAlpha(.weather));
    s.overlay_opacity_world_clock_pct = pctFromUnit(a.overlay_opacity_world_clock, overlay.designAlpha(.world_clock));
    s.overlay_opacity_tooltip_pct = pctFromUnit(a.overlay_opacity_tooltip, overlay.designAlpha(.tooltip));
    s.overlay_opacity_widget_card_pct = pctFromUnit(a.overlay_opacity_widget_card, overlay.widget_card_design);
    s.overlay_opacity_notifications_pct = pctFromUnit(a.overlay_opacity_notifications, overlay.designAlpha(.notifications));
    s.matugen_enabled = a.matugen_theming;
    s.horizon_native = a.horizon_colors_native;
    s.matugen_scheme = alloc.dupe(u8, a.matugen_scheme) catch "scheme-content";
    s.matugen_mode = alloc.dupe(u8, a.matugen_mode) catch "dark";

    // Templates: the base-recipe switch plus the 37 per-app switches. The
    // TOML keys and the UI array are in different orders past index 30 (see
    // `tpl_ui_index`), so the mapping is by name, not by position.
    const m = &a.matugen_outputs;
    s.matugen_base_recipes = m.run_bundled_toml;
    s.matugen_templates[0] = m.niri;
    s.matugen_templates[1] = m.hyprland;
    s.matugen_templates[2] = m.mango;
    s.matugen_templates[3] = m.gtk_shell_css;
    s.matugen_templates[4] = m.gtk_event_colors_light;
    s.matugen_templates[5] = m.gtk_event_colors_dark;
    s.matugen_templates[6] = m.kcolorscheme;
    s.matugen_templates[7] = m.qt5ct;
    s.matugen_templates[8] = m.qt6ct;
    s.matugen_templates[9] = m.kitty_theme;
    s.matugen_templates[10] = m.kitty_tabs;
    s.matugen_templates[11] = m.ghostty;
    s.matugen_templates[12] = m.wezterm;
    s.matugen_templates[13] = m.alacritty;
    s.matugen_templates[14] = m.foot;
    s.matugen_templates[15] = m.otter_term;
    s.matugen_templates[16] = m.btop;
    s.matugen_templates[17] = m.neovim;
    s.matugen_templates[18] = m.vscode_material;
    s.matugen_templates[19] = m.vscode_color_themes;
    s.matugen_templates[20] = m.firefox;
    s.matugen_templates[21] = m.zenbrowser;
    s.matugen_templates[22] = m.vesktop;
    s.matugen_templates[23] = m.equibop;
    s.matugen_templates[24] = m.pywalfox;
    s.matugen_templates[25] = m.steam;
    s.matugen_templates[26] = m.dgop;
    s.matugen_templates[27] = m.emacs;
    s.matugen_templates[28] = m.zed;
    s.matugen_templates[29] = m.ptyxis;
    s.matugen_templates[30] = m.horizon_files;
    s.matugen_templates[31] = m.obs;
    s.matugen_templates[32] = m.heroic;
    s.matugen_templates[33] = m.horizon_photo;
    s.matugen_templates[34] = m.horizon_calendar;
    s.matugen_templates[35] = m.fluxer;
    s.matugen_templates[36] = m.owler;
}

/// `[appearance.matugen_templates]` keys in the exact order the C++ writer
/// emits them (`shell_config.cpp`, `MatugenExternalTemplateToggles`).
const tpl_keys = [_][]const u8{
    "niri",
    "hyprland",
    "mango",
    "gtk_shell_css",
    "gtk_event_colors_light",
    "gtk_event_colors_dark",
    "kcolorscheme",
    "qt5ct",
    "qt6ct",
    "kitty_theme",
    "kitty_tabs",
    "ghostty",
    "wezterm",
    "alacritty",
    "foot",
    "otter_term",
    "btop",
    "neovim",
    "vscode_material",
    "vscode_color_themes",
    "firefox",
    "zenbrowser",
    "vesktop",
    "equibop",
    "pywalfox",
    "steam",
    "dgop",
    "emacs",
    "zed",
    "ptyxis",
    "horizon_files",
    "horizon_photo",
    "horizon_calendar",
    "obs",
    "heroic",
    "fluxer",
    "owler",
};

/// `Settings.matugen_templates` slot behind each key in `tpl_keys`. The
/// writer/struct order swaps the last two groups against the UI order
/// (`matugen_tpl_title`): the table lists horizon_photo, horizon_calendar,
/// obs, heroic where the tiles read obs, heroic, Horizon Photo,
/// Horizon Calendar.
const tpl_ui_index = [_]usize{
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16, 17,
    18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 33, 34, 31, 32, 35,
    36,
};

pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try out.append(list, .{ .key = "launchpad_grid_columns", .value = try section_store.intValue(values, s.launchpad_grid_columns) });
    try out.append(list, .{ .key = "launchpad_grid_rows", .value = try section_store.intValue(values, s.launchpad_grid_rows) });
    try out.append(list, .{ .key = "launchpad_cell_gap_px", .value = try section_store.intValue(values, s.launchpad_cell_gap_px) });
    try out.append(list, .{ .key = "launchpad_icon_fill_pct", .value = try section_store.intValue(values, s.launchpad_icon_fill_pct) });
    try out.append(list, .{ .key = "launchpad_layout_scale_pct", .value = try section_store.intValue(values, s.launchpad_layout_scale_pct) });
    try out.append(list, .{ .key = "launchpad_dpi_scale_pct", .value = try section_store.intValue(values, s.launchpad_dpi_scale_pct) });
    try out.append(list, .{ .key = "launchpad_view_mode", .value = try section_store.intValue(values, s.launchpad_view_mode) });
    try out.append(list, .{ .key = "launchpad_folder_size_pct", .value = try section_store.intValue(values, s.launchpad_folder_size_pct) });
    try out.append(list, .{ .key = "launchpad_folder_gap_px", .value = try section_store.intValue(values, s.launchpad_folder_gap_px) });
    try out.append(list, .{ .key = "launchpad_folder_columns", .value = try section_store.intValue(values, s.launchpad_folder_columns) });
    try out.append(list, .{ .key = "launchpad_folder_rows", .value = try section_store.intValue(values, s.launchpad_folder_rows) });
    try out.append(list, .{ .key = "overview_axis", .value = try section_store.intValue(values, s.overview_axis) });
    try out.append(list, .{ .key = "overview_capture_mode", .value = try section_store.intValue(values, s.overview_capture_mode) });
    try out.append(list, .{ .key = "overview_live_updates", .value = section_store.boolValue(s.overview_live_updates) });
    try out.append(list, .{ .key = "overview_multi_monitor", .value = section_store.boolValue(s.overview_multi_monitor) });
    try out.append(list, .{ .key = "overview_card_scale_pct", .value = try section_store.intValue(values, s.overview_card_scale_pct) });
    try out.append(list, .{ .key = "overview_card_gap_px", .value = try section_store.intValue(values, s.overview_card_gap_px) });
    try out.append(list, .{ .key = "overview_scroll_delay_ms", .value = try section_store.intValue(values, s.overview_scroll_delay_ms) });
    try out.append(list, .{ .key = "overview_close_btn_size_px", .value = try section_store.intValue(values, s.overview_close_btn_size_px) });
    try out.append(list, .{ .key = "overview_search_width_px", .value = try section_store.intValue(values, s.overview_search_width_px) });

    // Appearance General: overlay floats (0..1) + the matugen controls, in
    // the C++ writer's key order. `overlay_opacity_overview` is owned by the
    // Launcher's Overview child and stays untouched here.
    try out.append(list, .{ .key = "overlay_opacity_advanced", .value = section_store.boolValue(s.overlay_opacity_advanced) });
    try out.append(list, .{ .key = "overlay_opacity_master", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_master_pct, overlay.master_design)) });
    try out.append(list, .{ .key = "overlay_opacity_control_center", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_control_center_pct, overlay.designAlpha(.control_center))) });
    try out.append(list, .{ .key = "overlay_opacity_control_center_inner", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_control_center_inner_pct, overlay.designAlpha(.control_center))) });
    try out.append(list, .{ .key = "overlay_opacity_app_drawer", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_app_drawer_pct, overlay.designAlpha(.app_drawer))) });
    try out.append(list, .{ .key = "overlay_opacity_launchpad", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_launchpad_pct, overlay.designAlpha(.launchpad))) });
    try out.append(list, .{ .key = "overlay_opacity_settings", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_settings_pct, overlay.designAlpha(.settings))) });
    try out.append(list, .{ .key = "overlay_opacity_settings_sidebar", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_settings_sidebar_pct, overlay.designAlpha(.settings))) });
    try out.append(list, .{ .key = "overlay_opacity_dock_menu", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_dock_menu_pct, overlay.designAlpha(.dock_menu))) });
    try out.append(list, .{ .key = "overlay_opacity_desktop_menu", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_desktop_menu_pct, overlay.designAlpha(.desktop_menu))) });
    try out.append(list, .{ .key = "overlay_opacity_tray_menu", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_tray_menu_pct, overlay.designAlpha(.tray_menu))) });
    try out.append(list, .{ .key = "overlay_opacity_calendar", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_calendar_pct, overlay.designAlpha(.calendar))) });
    try out.append(list, .{ .key = "overlay_opacity_weather", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_weather_pct, overlay.designAlpha(.weather))) });
    try out.append(list, .{ .key = "overlay_opacity_world_clock", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_world_clock_pct, overlay.designAlpha(.world_clock))) });
    try out.append(list, .{ .key = "overlay_opacity_tooltip", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_tooltip_pct, overlay.designAlpha(.tooltip))) });
    try out.append(list, .{ .key = "overlay_opacity_widget_card", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_widget_card_pct, overlay.widget_card_design)) });
    try out.append(list, .{ .key = "overlay_opacity_notifications", .value = try section_store.floatValue(values, unitFromPct(s.overlay_opacity_notifications_pct, overlay.designAlpha(.notifications))) });
    try out.append(list, .{ .key = "matugen_theming", .value = section_store.boolValue(s.matugen_enabled) });
    try out.append(list, .{ .key = "horizon_colors_native", .value = section_store.boolValue(s.horizon_native) });
    try out.append(list, .{ .key = "matugen_scheme", .value = try section_store.stringValue(values, s.matugen_scheme) });
    try out.append(list, .{ .key = "matugen_mode", .value = try section_store.stringValue(values, s.matugen_mode) });
}

/// The `[appearance.matugen_templates]` sub-table: `run_bundled` plus the 37
/// template switches, keyed by `tpl_keys`/`tpl_ui_index`.
pub fn appendTemplateEntries(
    list: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try out.append(list, .{ .key = "run_bundled", .value = section_store.boolValue(s.matugen_base_recipes) });
    for (tpl_keys, tpl_ui_index) |key, idx| {
        try out.append(list, .{ .key = key, .value = section_store.boolValue(s.matugen_templates[idx]) });
    }
}

pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    s: *const app_mod.Settings,
) !void {
    const path = try cfg.componentPath(gpa, state_dir, component);
    defer gpa.free(path);

    var values = std.heap.ArenaAllocator.init(gpa);
    defer values.deinit();

    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(gpa);
    try appendEntries(gpa, values.allocator(), s, &entries);
    try section_store.save(gpa, io, path, section, entries.items);

    // Second pass for the nested table: the parent pass stops at the next
    // header line, so `[appearance]` and `[appearance.matugen_templates]`
    // never touch each other's keys. A file that lacks the table gets it
    // appended at the end.
    var tpl_entries: std.ArrayList(section_store.Entry) = .empty;
    defer tpl_entries.deinit(gpa);
    try appendTemplateEntries(gpa, s, &tpl_entries);
    try section_store.save(gpa, io, path, templates_section, tpl_entries.items);
}

test "appearance-persist: entries carry the launcher, overlay and matugen keys" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = app_mod.Settings{
        .overview_axis = 1,
        .overview_capture_mode = 1,
        .overview_live_updates = true,
        .overview_multi_monitor = true,
        .overview_card_scale_pct = 60,
        .overview_card_gap_px = 32,
        .overview_scroll_delay_ms = 250,
        .overview_close_btn_size_px = 40,
        .overview_search_width_px = 500,
        .overlay_opacity_master_pct = 44,
        .overlay_opacity_advanced = true,
        .matugen_enabled = true,
        .matugen_scheme = "scheme-vibrant",
    };
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(t.allocator);
    try appendEntries(t.allocator, arena.allocator(), &s, &entries);
    // 11 launchpad keys + 9 overview keys + 17 overlay keys + 4 matugen keys.
    try t.expectEqual(@as(usize, 41), entries.items.len);
    try t.expectEqualStrings("launchpad_grid_columns", entries.items[0].key);
    try t.expectEqualStrings("overview_axis", entries.items[11].key);
    try t.expectEqualStrings("1", entries.items[11].value);
    try t.expectEqualStrings("overview_live_updates", entries.items[13].key);
    try t.expectEqualStrings("true", entries.items[13].value);
    // Overlay floats render as TOML floats; the master's 44% divides back
    // through its 0.55 design body to a 0.8 multiplier.
    try t.expectEqualStrings("overlay_opacity_advanced", entries.items[20].key);
    try t.expectEqualStrings("true", entries.items[20].value);
    try t.expectEqualStrings("overlay_opacity_master", entries.items[21].key);
    try t.expectApproxEqAbs(@as(f64, 0.8), try std.fmt.parseFloat(f64, entries.items[21].value), 1e-9);
    try t.expectEqualStrings("matugen_theming", entries.items[37].key);
    try t.expectEqualStrings("true", entries.items[37].value);
    try t.expectEqualStrings("matugen_scheme", entries.items[39].key);
    try t.expectEqualStrings("'scheme-vibrant'", entries.items[39].value);
}

test "appearance-persist: launchpad keys round-trip" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = app_mod.Settings{
        .launchpad_layout_scale_pct = 120,
        .launchpad_icon_fill_pct = 70,
        .launchpad_cell_gap_px = 8,
        .launchpad_folder_size_pct = 150,
        .launchpad_folder_gap_px = 20,
        .launchpad_folder_columns = 4,
        .launchpad_folder_rows = 2,
        .launchpad_dpi_scale_pct = 200,
    };
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(t.allocator);
    try appendEntries(t.allocator, arena.allocator(), &s, &entries);
    var found = std.StringHashMap([]const u8).init(t.allocator);
    defer found.deinit();
    for (entries.items) |e| try found.put(e.key, e.value);
    try t.expectEqualStrings("120", found.get("launchpad_layout_scale_pct").?);
    try t.expectEqualStrings("70", found.get("launchpad_icon_fill_pct").?);
    try t.expectEqualStrings("8", found.get("launchpad_cell_gap_px").?);
    try t.expectEqualStrings("150", found.get("launchpad_folder_size_pct").?);
    try t.expectEqualStrings("20", found.get("launchpad_folder_gap_px").?);
    try t.expectEqualStrings("4", found.get("launchpad_folder_columns").?);
    try t.expectEqualStrings("2", found.get("launchpad_folder_rows").?);
    try t.expectEqualStrings("200", found.get("launchpad_dpi_scale_pct").?);
}

test "appearance-persist: template keys follow the writer order and array map" {
    const t = std.testing;
    var s = app_mod.Settings{};
    s.matugen_base_recipes = false;
    s.matugen_templates[31] = false; // OBS Studio
    s.matugen_templates[33] = false; // Horizon Photo
    s.matugen_templates[36] = false; // Owler
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(t.allocator);
    try appendTemplateEntries(t.allocator, &s, &entries);
    try t.expectEqual(@as(usize, 38), entries.items.len);
    try t.expectEqualStrings("run_bundled", entries.items[0].key);
    try t.expectEqualStrings("false", entries.items[0].value);
    try t.expectEqualStrings("niri", entries.items[1].key);
    // keys 30..36: horizon_files, horizon_photo, horizon_calendar, obs,
    // heroic, fluxer, owler (writer order) — values come from the UI slots.
    try t.expectEqualStrings("horizon_files", entries.items[31].key);
    try t.expectEqualStrings("horizon_photo", entries.items[32].key);
    try t.expectEqualStrings("false", entries.items[32].value);
    try t.expectEqualStrings("obs", entries.items[34].key);
    try t.expectEqualStrings("false", entries.items[34].value);
    try t.expectEqualStrings("heroic", entries.items[35].key);
    try t.expectEqualStrings("true", entries.items[35].value);
    try t.expectEqualStrings("fluxer", entries.items[36].key);
    try t.expectEqualStrings("owler", entries.items[37].key);
    try t.expectEqualStrings("false", entries.items[37].value);
}

test "appearance-persist: load maps percents and toggles onto the settings" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var s = app_mod.Settings{};
    var a = cfg.AppearanceSettings{};
    a.overlay_opacity_advanced = true;
    a.overlay_opacity_master = 0.72;
    a.overlay_opacity_notifications = 0.5;
    a.overlay_opacity_world_clock = 0.72;
    a.matugen_theming = true;
    a.horizon_colors_native = false;
    a.matugen_scheme = "scheme-vibrant";
    a.matugen_mode = "auto";
    a.matugen_outputs = .{
        .run_bundled_toml = false,
        .niri = false,
        .obs = false,
        .heroic = false,
        .horizon_photo = false,
        .owler = false,
    };
    load(arena.allocator(), &s, &a);
    try t.expect(s.overlay_opacity_advanced);
    // The page shows body opacity: 0.72 of the master's 0.55 design body
    // reads as 40%, and 0.5 of the toast card's 0.78 as 39%.
    try t.expectEqual(@as(i32, 40), s.overlay_opacity_master_pct);
    try t.expectEqual(@as(i32, 39), s.overlay_opacity_notifications_pct);
    // The world clock plate is painted at 1.0 by design, so its percent is
    // the unit straight.
    try t.expectEqual(@as(i32, 72), s.overlay_opacity_world_clock_pct);
    try t.expect(s.matugen_enabled);
    try t.expect(!s.horizon_native);
    try t.expectEqualStrings("scheme-vibrant", s.matugen_scheme);
    try t.expectEqualStrings("auto", s.matugen_mode);
    try t.expect(!s.matugen_base_recipes);
    try t.expect(!s.matugen_templates[0]); // Niri
    try t.expect(!s.matugen_templates[31]); // OBS Studio
    try t.expect(!s.matugen_templates[32]); // Heroic
    try t.expect(!s.matugen_templates[33]); // Horizon Photo
    try t.expect(s.matugen_templates[34]); // Horizon Calendar keeps its default
    try t.expect(!s.matugen_templates[36]); // Owler
}
