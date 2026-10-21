//! The Desktop tab's Overview card round trip to `[appearance]` in
//! `~/.config/Event-Horizon/appearance/appearance.toml`.
//!
//! Same narrow rule as `dock_persist`: force exactly the keys this card
//! owns, leaving the rest of the document byte-for-byte intact. `load` is
//! the other half — without it the first save would write the struct's
//! defaults over whatever the file already held.

const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const section_store = @import("../../config/section_store.zig");

pub const component = "appearance";
pub const section = "appearance";

/// Seed the Launcher + Overview cards from a decoded `[appearance]` section.
// Covers every launchpad_* key the Launcher child owns plus the nine
// overview_* keys the Overview child (and the Desktop tab's Overview card)
// share — matching settings_serialize.cpp load_settings().
pub fn load(s: *app_mod.Settings, a: *const cfg.AppearanceSettings) void {
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
}

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
}

test "appearance-persist: entries carry all nine overview keys" {
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
    };
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(t.allocator);
    try appendEntries(t.allocator, arena.allocator(), &s, &entries);
    // 11 launchpad keys + 9 overview keys.
    try t.expectEqual(@as(usize, 20), entries.items.len);
    try t.expectEqualStrings("launchpad_grid_columns", entries.items[0].key);
    try t.expectEqualStrings("overview_axis", entries.items[11].key);
    try t.expectEqualStrings("1", entries.items[11].value);
    try t.expectEqualStrings("overview_live_updates", entries.items[13].key);
    try t.expectEqualStrings("true", entries.items[13].value);
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
