const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const section_store = @import("../../config/section_store.zig");
const widget_defaults = @import("widget_defaults.zig");

pub const component = "panel";
pub const section = "panel";

/// Seed the Panel tab from a decoded `[panel]` section. Only the keys the
/// tab owns are copied; overlay/hover/smarthide/capsule/corners/click-through
/// and friends survive saves untouched. An all-empty widget triple seeds the
/// visible defaults.
pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, p: *const cfg.PanelSettings) void {
    s.panel_enabled = p.enabled;
    s.panel_width_mode = p.width_mode;
    s.panel_height = p.height;
    s.panel_radius = p.radius;
    s.panel_opacity = p.opacity;
    s.panel_icon_size = p.icon_size;
    s.panel_icon_spacing = p.icon_spacing;
    s.panel_edge_gap = p.edge_gap;
    s.panel_exclusive_zone_gap = p.exclusive_zone_gap;
    s.panel_scale_pct = @intFromFloat(@round(p.scale * 100.0));
    s.panel_position_top = p.position_top;
    s.panel_auto_hide = p.auto_hide;
    s.panel_tooltips_enabled = p.tooltips_enabled;
    s.panel_widgets_enabled = p.widgets_enabled;
    s.panel_reserve_space = p.reserve_space;
    s.panel_border = p.border;
    s.panel_border_size = p.border_size;
    s.panel_floating_amount = p.floating_amount;
    s.panel_overlay_layer = p.overlay_layer;
    s.panel_hover_highlight = p.hover_highlight;
    s.panel_smart_auto_hide = p.smart_auto_hide;
    s.panel_reveal_on_switch = p.reveal_on_switch;
    s.panel_scroll_volume = p.scroll_volume;
    s.panel_deadzone_left = p.deadzone_left;
    s.panel_deadzone_middle = p.deadzone_middle;
    s.panel_deadzone_right = p.deadzone_right;
    s.panel_capsule = p.capsule;
    s.panel_capsule_opacity = p.capsule_opacity;
    s.panel_corner_tl = p.corner_tl;
    s.panel_corner_tr = p.corner_tr;
    s.panel_corner_bl = p.corner_bl;
    s.panel_corner_br = p.corner_br;
    s.panel_icon_theme = p.icon_theme;
    s.panel_click_through = joinStrList(alloc, p.click_through) catch "";

    const raw = std.mem.trim(u8, p.output_name, " \t\r\n");
    s.panel_output_name = alloc.dupe(u8, if (raw.len == 0) "Auto" else raw) catch "Auto";

    const use_defaults = p.left_widgets.len == 0 and
        p.center_widgets.len == 0 and
        p.right_widgets.len == 0;
    s.panel_left_widgets = dupeStrList(
        alloc,
        if (use_defaults) &widget_defaults.panel_left else p.left_widgets,
    ) catch &.{};
    s.panel_center_widgets = dupeStrList(
        alloc,
        if (use_defaults) &widget_defaults.panel_center else p.center_widgets,
    ) catch &.{};
    s.panel_right_widgets = dupeStrList(
        alloc,
        if (use_defaults) &widget_defaults.panel_right else p.right_widgets,
    ) catch &.{};
}

fn dupeStrList(alloc: std.mem.Allocator, src: []const []const u8) ![][]const u8 {
    const out = try alloc.alloc([]const u8, src.len);
    for (src, 0..) |id, i| out[i] = try alloc.dupe(u8, id);
    return out;
}

fn joinStrList(alloc: std.mem.Allocator, src: []const []const u8) ![]const u8 {
    if (src.len == 0) return "";
    var total: usize = 0;
    for (src, 0..) |id, i| {
        total += id.len;
        if (i + 1 < src.len) total += 1;
    }
    const out = try alloc.alloc(u8, total);
    var off: usize = 0;
    for (src, 0..) |id, i| {
        @memcpy(out[off..][0..id.len], id);
        off += id.len;
        if (i + 1 < src.len) {
            out[off] = ',';
            off += 1;
        }
    }
    return out;
}

fn splitStrList(alloc: std.mem.Allocator, src: []const u8) ![][]const u8 {
    if (std.mem.trim(u8, src, " \t").len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, src, ',');
    while (it.next()) |part| {
        const tok = std.mem.trim(u8, part, " \t");
        if (tok.len == 0) continue;
        try out.append(alloc, try alloc.dupe(u8, tok));
    }
    return out.toOwnedSlice(alloc);
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

/// The keys the Panel tab owns, named as `decodePanel` reads them.
pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try pushBool(list, out, "enabled", s.panel_enabled);
    try pushInt(list, values, out, "width_mode", s.panel_width_mode);
    try pushInt(list, values, out, "height", s.panel_height);
    try pushInt(list, values, out, "radius", s.panel_radius);
    try pushInt(list, values, out, "opacity", s.panel_opacity);
    try pushInt(list, values, out, "icon_size", s.panel_icon_size);
    try pushInt(list, values, out, "icon_spacing", s.panel_icon_spacing);
    try pushInt(list, values, out, "edge_gap", s.panel_edge_gap);
    try pushInt(list, values, out, "exclusive_zone_gap", s.panel_exclusive_zone_gap);
    try pushBool(list, out, "position_top", s.panel_position_top);
    try pushBool(list, out, "auto_hide", s.panel_auto_hide);
    try pushBool(list, out, "tooltips", s.panel_tooltips_enabled);
    try pushBool(list, out, "widgets_enabled", s.panel_widgets_enabled);
    try pushBool(list, out, "reserve_space", s.panel_reserve_space);
    try pushBool(list, out, "border", s.panel_border);
    try pushInt(list, values, out, "border_size", s.panel_border_size);
    try pushInt(list, values, out, "floating_amount", s.panel_floating_amount);
    try pushBool(list, out, "overlay_layer", s.panel_overlay_layer);
    try pushBool(list, out, "hover_highlight", s.panel_hover_highlight);
    try pushBool(list, out, "smart_auto_hide", s.panel_smart_auto_hide);
    try pushBool(list, out, "reveal_on_switch", s.panel_reveal_on_switch);
    try pushBool(list, out, "scroll_volume", s.panel_scroll_volume);
    try pushStr(list, values, out, "deadzone_left", s.panel_deadzone_left);
    try pushStr(list, values, out, "deadzone_middle", s.panel_deadzone_middle);
    try pushStr(list, values, out, "deadzone_right", s.panel_deadzone_right);
    try pushBool(list, out, "capsule", s.panel_capsule);
    try pushInt(list, values, out, "capsule_opacity", s.panel_capsule_opacity);
    try pushInt(list, values, out, "radius_tl", s.panel_corner_tl);
    try pushInt(list, values, out, "radius_tr", s.panel_corner_tr);
    try pushInt(list, values, out, "radius_bl", s.panel_corner_bl);
    try pushInt(list, values, out, "radius_br", s.panel_corner_br);
    try pushStr(list, values, out, "icon_theme", s.panel_icon_theme);
    {
        const parts = try splitStrList(list, s.panel_click_through);
        defer list.free(parts);
        try out.append(list, .{ .key = "click_through", .value = try section_store.arrayValue(values, parts) });
    }

    const scale = try section_store.floatValue(
        values,
        @as(f64, @floatFromInt(s.panel_scale_pct)) / 100.0,
    );
    try out.append(list, .{ .key = "scale", .value = scale });

    try pushStr(list, values, out, "output", s.panel_output_name);
    try out.append(list, .{ .key = "left_widgets", .value = try section_store.arrayValue(values, s.panel_left_widgets) });
    try out.append(list, .{ .key = "center_widgets", .value = try section_store.arrayValue(values, s.panel_center_widgets) });
    try out.append(list, .{ .key = "right_widgets", .value = try section_store.arrayValue(values, s.panel_right_widgets) });
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

test "panel-persist: load seeds scalars, output and widget defaults" {
    const t = std.testing;
    var str_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer str_arena.deinit();

    var s: app_mod.Settings = .{};
    const p: cfg.PanelSettings = .{ .height = 40, .output_name = "" };
    load(str_arena.allocator(), &s, &p);
    try t.expectEqual(@as(i32, 40), s.panel_height);
    try t.expectEqualStrings("Auto", s.panel_output_name);
    try t.expectEqual(@as(usize, 1), s.panel_left_widgets.len);
    try t.expectEqualStrings("workspaces", s.panel_left_widgets[0]);
}

test "panel-persist: owned keys emit, alien keys never do" {
    const t = std.testing;
    const alloc = t.allocator;
    var s: app_mod.Settings = .{};
    s.panel_height = 44;

    var values = std.heap.ArenaAllocator.init(alloc);
    defer values.deinit();
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(alloc);
    try appendEntries(alloc, values.allocator(), &s, &entries);

    var found = std.StringHashMap([]const u8).init(alloc);
    defer found.deinit();
    for (entries.items) |e| try found.put(e.key, e.value);

    try t.expectEqualStrings("44", found.get("height").?);
    try t.expect(found.get("smart_auto_hide") != null);
    try t.expect(found.get("capsule") != null);
    try t.expect(found.get("capsule_opacity") != null);
    try t.expect(found.get("deadzone_left") != null);
    try t.expect(found.get("deadzone_middle") != null);
    try t.expect(found.get("deadzone_right") != null);
    try t.expect(found.get("radius_tl") != null);
    try t.expect(found.get("overlay_layer") != null);
    try t.expect(found.get("hover_highlight") != null);
    try t.expect(found.get("scroll_volume") != null);
    try t.expect(found.get("floating_amount") != null);
    try t.expect(found.get("icon_theme") != null);
    try t.expect(found.get("click_through") != null);
    try t.expect(found.get("left_widgets") != null);
}
