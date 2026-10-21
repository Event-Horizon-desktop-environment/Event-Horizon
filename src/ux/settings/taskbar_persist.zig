const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");
const widget_defaults = @import("widget_defaults.zig");

pub const component = "taskbar";
pub const section = "taskbar";

/// Seed the Taskbar tab from a decoded `[taskbar]` section. Only the keys the
/// tab owns are copied; `floating_amount`, `slot_pill_opacity`, `pinned_apps`
/// and `icon_theme` survive saves untouched. String lists are arena copies.
/// An all-empty widget triple seeds the visible defaults.
pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, t: *const cfg.TaskbarSettings) void {
    s.taskbar_enabled = t.enabled;
    s.taskbar_width_mode = t.width_mode;
    s.taskbar_height = t.height;
    s.taskbar_radius = t.radius;
    s.taskbar_opacity = t.opacity;
    s.taskbar_icon_size = t.icon_size;
    s.taskbar_icon_spacing = t.icon_spacing;
    s.taskbar_edge_gap = t.edge_gap;
    s.taskbar_exclusive_zone_gap = t.exclusive_zone_gap;
    s.taskbar_scale_pct = @intFromFloat(@round(t.scale * 100.0));
    s.taskbar_group_apps = t.group_apps;
    s.taskbar_show_labels = t.show_labels;
    s.taskbar_collapse_when_full = t.collapse_when_full;
    s.taskbar_thumbnails_enabled = t.thumbnails_enabled;
    s.taskbar_thumbnail_peek_enabled = t.thumbnail_peek_enabled;
    s.taskbar_thumbnail_threshold = t.thumbnail_threshold;
    s.taskbar_compact_media = t.compact_media;
    s.taskbar_position_top = t.position_top;
    s.taskbar_auto_hide = t.auto_hide;
    s.taskbar_tooltips_enabled = t.tooltips_enabled;
    s.taskbar_pinned_apps_tray_pill = t.pinned_apps_tray_pill;
    s.taskbar_running_apps_tray_pill = t.running_apps_tray_pill;
    s.taskbar_widgets_enabled = t.widgets_enabled;
    s.taskbar_border = t.border;
    s.taskbar_border_size = t.border_size;

    const raw = std.mem.trim(u8, t.output_name, " \t\r\n");
    s.taskbar_output_name = alloc.dupe(u8, if (raw.len == 0) "Auto" else raw) catch "Auto";

    const use_defaults = t.left_widgets.len == 0 and
        t.center_widgets.len == 0 and
        t.right_widgets.len == 0;
    s.taskbar_left_widgets = dupeStrList(
        alloc,
        if (use_defaults) &widget_defaults.taskbar_left else t.left_widgets,
    ) catch &.{};
    s.taskbar_center_widgets = dupeStrList(
        alloc,
        if (use_defaults) &widget_defaults.taskbar_center else t.center_widgets,
    ) catch &.{};
    s.taskbar_right_widgets = dupeStrList(
        alloc,
        if (use_defaults) &widget_defaults.taskbar_right else t.right_widgets,
    ) catch &.{};
}

fn dupeStrList(alloc: std.mem.Allocator, src: []const []const u8) ![][]const u8 {
    const out = try alloc.alloc([]const u8, src.len);
    for (src, 0..) |id, i| out[i] = try alloc.dupe(u8, id);
    return out;
}

fn pushBool(
    list: std.mem.Allocator,
    out: *std.ArrayList(section_store.Entry),
    key: []const u8,
    v: bool,
) !void {
    try out.append(list, .{ .key = key, .value = section_store.boolValue(v) });
}

fn pushInt(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    out: *std.ArrayList(section_store.Entry),
    key: []const u8,
    v: i32,
) !void {
    try out.append(list, .{ .key = key, .value = try section_store.intValue(values, v) });
}

fn pushStr(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    out: *std.ArrayList(section_store.Entry),
    key: []const u8,
    v: []const u8,
) !void {
    try out.append(list, .{ .key = key, .value = try section_store.stringValue(values, v) });
}

/// The keys the Taskbar tab owns, named as `decodeTaskbar` reads them.
pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try pushBool(list, out, "enabled", s.taskbar_enabled);
    try pushInt(list, values, out, "width_mode", s.taskbar_width_mode);
    try pushInt(list, values, out, "height", s.taskbar_height);
    try pushInt(list, values, out, "radius", s.taskbar_radius);
    try pushInt(list, values, out, "opacity", s.taskbar_opacity);
    try pushInt(list, values, out, "icon_size", s.taskbar_icon_size);
    try pushInt(list, values, out, "icon_spacing", s.taskbar_icon_spacing);
    try pushInt(list, values, out, "edge_gap", s.taskbar_edge_gap);
    try pushInt(list, values, out, "exclusive_zone_gap", s.taskbar_exclusive_zone_gap);
    try pushBool(list, out, "group_apps", s.taskbar_group_apps);
    try pushBool(list, out, "show_labels", s.taskbar_show_labels);
    try pushBool(list, out, "collapse_when_full", s.taskbar_collapse_when_full);
    try pushBool(list, out, "thumbnails", s.taskbar_thumbnails_enabled);
    try pushBool(list, out, "thumbnail_peek", s.taskbar_thumbnail_peek_enabled);
    try pushInt(list, values, out, "thumbnail_threshold", s.taskbar_thumbnail_threshold);
    try pushBool(list, out, "compact_media", s.taskbar_compact_media);
    try pushBool(list, out, "position_top", s.taskbar_position_top);
    try pushBool(list, out, "auto_hide", s.taskbar_auto_hide);
    try pushBool(list, out, "tooltips", s.taskbar_tooltips_enabled);
    try pushBool(list, out, "pinned_apps_tray_pill", s.taskbar_pinned_apps_tray_pill);
    try pushBool(list, out, "running_apps_tray_pill", s.taskbar_running_apps_tray_pill);
    try pushBool(list, out, "widgets_enabled", s.taskbar_widgets_enabled);
    try pushBool(list, out, "border", s.taskbar_border);
    try pushInt(list, values, out, "border_size", s.taskbar_border_size);

    const scale = try section_store.floatValue(
        values,
        @as(f64, @floatFromInt(s.taskbar_scale_pct)) / 100.0,
    );
    try out.append(list, .{ .key = "scale", .value = scale });

    try pushStr(list, values, out, "output", s.taskbar_output_name);
    try out.append(list, .{ .key = "left_widgets", .value = try section_store.arrayValue(values, s.taskbar_left_widgets) });
    try out.append(list, .{ .key = "center_widgets", .value = try section_store.arrayValue(values, s.taskbar_center_widgets) });
    try out.append(list, .{ .key = "right_widgets", .value = try section_store.arrayValue(values, s.taskbar_right_widgets) });
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

test "taskbar-persist: load seeds scalars, output and widget defaults" {
    const t = std.testing;
    var str_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer str_arena.deinit();

    var s: app_mod.Settings = .{};
    const tb: cfg.TaskbarSettings = .{
        .height = 56,
        .output_name = "HDMI-A-1",
    };
    load(str_arena.allocator(), &s, &tb);
    try t.expectEqual(@as(i32, 56), s.taskbar_height);
    try t.expectEqualStrings("HDMI-A-1", s.taskbar_output_name);
    try t.expect(s.taskbar_left_widgets.len > 0);
    try t.expectEqualStrings("smenu", s.taskbar_left_widgets[0]);
}

test "taskbar-persist: owned keys emit, alien keys never do" {
    const t = std.testing;
    const alloc = t.allocator;
    var s: app_mod.Settings = .{};
    s.taskbar_height = 60;
    s.taskbar_output_name = "DP-1";

    var values = std.heap.ArenaAllocator.init(alloc);
    defer values.deinit();
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(alloc);
    try appendEntries(alloc, values.allocator(), &s, &entries);

    var found = std.StringHashMap([]const u8).init(alloc);
    defer found.deinit();
    for (entries.items) |e| try found.put(e.key, e.value);

    try t.expectEqualStrings("60", found.get("height").?);
    try t.expectEqualStrings("'DP-1'", found.get("output").?);
    try t.expect(found.get("floating_amount") == null);
    try t.expect(found.get("pinned_apps") == null);
    try t.expect(found.get("slot_pill_opacity") == null);
    try t.expect(found.get("icon_theme") == null);
    try t.expect(found.get("left_widgets") != null);
}
