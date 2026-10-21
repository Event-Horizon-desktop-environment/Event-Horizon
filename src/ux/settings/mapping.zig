const std = @import("std");
const app_mod = @import("app.zig");

// Config mapping — Zig port of settings_to_shell_config() / load_settings()
// key surface in src/ux/settings/settings_serialize.cpp.
// Same design: Settings fields map 1:1 onto ShellConfig sections; the sole
// writer rule holds (only horizon-settings writes config.toml).

pub const TomlKey = struct {
    section: []const u8,
    key: []const u8,
};

pub const dock_keys = [_]TomlKey{
    .{ .section = "dock", .key = "show_dock" },
    .{ .section = "dock", .key = "auto_hide" },
    .{ .section = "dock", .key = "radius" },
    .{ .section = "dock", .key = "icon_size" },
    .{ .section = "dock", .key = "opacity" },
    .{ .section = "dock", .key = "renderer" },
};

pub const audio_keys = [_]TomlKey{
    .{ .section = "audio", .key = "sink_volume" },
    .{ .section = "audio", .key = "sink_muted" },
    .{ .section = "audio", .key = "source_volume" },
    .{ .section = "audio", .key = "source_muted" },
    .{ .section = "audio", .key = "allow_overamp" },
};

pub const launcher_keys = [_]TomlKey{
    .{ .section = "appearance", .key = "launchpad_layout_scale_pct" },
    .{ .section = "appearance", .key = "launchpad_icon_fill_pct" },
    .{ .section = "appearance", .key = "launchpad_cell_gap_px" },
    .{ .section = "appearance", .key = "launchpad_folder_size_pct" },
    .{ .section = "appearance", .key = "launchpad_folder_gap_px" },
    .{ .section = "appearance", .key = "launchpad_folder_columns" },
    .{ .section = "appearance", .key = "launchpad_folder_rows" },
    .{ .section = "appearance", .key = "launchpad_grid_columns" },
    .{ .section = "appearance", .key = "launchpad_grid_rows" },
    .{ .section = "appearance", .key = "launchpad_dpi_scale_pct" },
    .{ .section = "appearance", .key = "overview_axis" },
    .{ .section = "appearance", .key = "overview_capture_mode" },
    .{ .section = "appearance", .key = "overview_card_scale_pct" },
    .{ .section = "appearance", .key = "overview_card_gap_px" },
    .{ .section = "appearance", .key = "overview_scroll_delay_ms" },
    .{ .section = "appearance", .key = "overview_close_btn_size_px" },
    .{ .section = "appearance", .key = "overview_search_width_px" },
    .{ .section = "dock", .key = "slot_pill_opacity" },
    .{ .section = "taskbar", .key = "slot_pill_opacity" },
};
pub fn applyDockPreview(src: app_mod.Settings, icon_count: usize) i32 {
    // Mirrors settings_dock_preview_auto_bar_px().
    if (icon_count == 0) return 72;
    const c: i32 = @intCast(icon_count);
    return c * src.dock_icon_size + (c - 1) * src.dock_icon_spacing + 32;
}

pub fn clampSettings(s: *app_mod.Settings) void {
    if (s.dock_radius < 0) s.dock_radius = 0;
    if (s.dock_radius > 32) s.dock_radius = 32;
    if (s.dock_opacity < 0) s.dock_opacity = 0;
    if (s.dock_opacity > 100) s.dock_opacity = 100;
    if (s.taskbar_height < 24) s.taskbar_height = 24;
    if (s.taskbar_height > 96) s.taskbar_height = 96;
    if (s.panel_height < 20) s.panel_height = 20;
    if (s.panel_height > 80) s.panel_height = 80;
    if (s.audio_sink_volume_pct < 0) s.audio_sink_volume_pct = 0;
    const hi: i32 = if (s.audio_allow_overamp) 150 else 100;
    if (s.audio_sink_volume_pct > hi) s.audio_sink_volume_pct = hi;
    // Launcher tab ranges (shell_config.cpp assign clamps).
    const launcher = @import("launcher_tab.zig");
    s.launchpad_layout_scale_pct = launcher.clampLayoutScale(s.launchpad_layout_scale_pct);
    s.launchpad_icon_fill_pct = launcher.clampIconFill(s.launchpad_icon_fill_pct);
    s.launchpad_cell_gap_px = launcher.clampCellGap(s.launchpad_cell_gap_px);
    s.launchpad_folder_size_pct = launcher.clampFolderSize(s.launchpad_folder_size_pct);
    s.launchpad_folder_gap_px = launcher.clampFolderGap(s.launchpad_folder_gap_px);
    s.launchpad_folder_columns = launcher.clampFolderColumns(s.launchpad_folder_columns);
    s.launchpad_folder_rows = launcher.clampFolderRows(s.launchpad_folder_rows);
    s.launchpad_grid_columns = launcher.clampGridColumns(s.launchpad_grid_columns);
    s.launchpad_grid_rows = launcher.clampGridRows(s.launchpad_grid_rows);
    s.launchpad_dpi_scale_pct = launcher.clampDpiScale(s.launchpad_dpi_scale_pct);
    s.slot_pill_opacity = launcher.clampSlotPill(s.slot_pill_opacity);
    s.taskbar_slot_pill_opacity = launcher.clampSlotPill(s.taskbar_slot_pill_opacity);
    s.workspaces_max_slots = launcher.clampWsSlots(s.workspaces_max_slots);
    s.workspaces_max_icons = launcher.clampWsIcons(s.workspaces_max_icons);
    s.overview_card_scale_pct = launcher.clampCardScale(s.overview_card_scale_pct);
    s.overview_card_gap_px = launcher.clampCardGap(s.overview_card_gap_px);
    s.overview_scroll_delay_ms = launcher.clampScrollDelay(s.overview_scroll_delay_ms);
    s.overview_close_btn_size_px = launcher.clampCloseBtn(s.overview_close_btn_size_px);
    s.overview_search_width_px = launcher.clampSearchWidth(s.overview_search_width_px);
    if (s.overview_axis < 0 or s.overview_axis > 1) s.overview_axis = 0;
    if (s.overview_capture_mode < 0 or s.overview_capture_mode > 1) s.overview_capture_mode = 0;
}

test "settings-mapping: keys + preview + clamp" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 6), dock_keys.len);
    try t.expectEqual(@as(usize, 5), audio_keys.len);
    var s = app_mod.Settings{};
    s.dock_icon_size = 44;
    s.dock_icon_spacing = 15;
    try t.expectEqual(@as(i32, 76), applyDockPreview(s, 1));
    s.audio_sink_volume_pct = 999;
    clampSettings(&s);
    try t.expectEqual(@as(i32, 100), s.audio_sink_volume_pct);
}
