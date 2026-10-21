//! The Dock tab's round trip to `[dock]` in
//! `~/.config/Event-Horizon/dock/dock.toml`.
//!
//! `settings_to_shell_config()` / `load_settings()` in the C++ `settings_serialize.cpp`
//! do the same job there with a full serialiser; here it is deliberately
//! narrower. The Zig tree still has no general `ShellConfig` dumper, and one
//! would silently drop every key the loader understands but the dumper does
//! not — `left_widgets`, `slot_pill_opacity`, `bar_follows_icons` and the
//! rest. So a save goes through `config/section_store.zig` and forces exactly
//! the keys this tab owns, leaving the rest of the document byte-for-byte
//! intact (the same rule `config/pin_store.zig` follows for `pinned_apps`).
//!
//! `load` is the other half of the contract and the part that is easy to
//! skip: without it the first save would write the struct's defaults over
//! values the file already held — `dock_output_name` in particular defaults
//! to `"Auto"` while a live `dock.toml` says `'DP-1'`, so the Display combo
//! would silently move the dock.

const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");
const widgets = @import("../../desktop_shell/dock/widgets.zig");

pub const component = "dock";
pub const section = "dock";

/// Seed the Dock tab from a decoded `[dock]` section.
///
/// `alloc` only takes the output name: `Settings` holds plain slices with no
/// lifetime of their own, and the config's arena is torn down long before the
/// window is. Every other field is a scalar that copies.
pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, d: *const cfg.DockSettings) void {
    s.dock_show_dock = d.dock_show_dock;
    s.dock_auto_hide = d.dock_autohide;
    s.dock_group_apps = d.dock_group_apps;
    s.dock_tooltips_enabled = d.dock_tooltips_enabled;
    s.dock_widgets_enabled = d.dock_widgets_enabled;
    s.dock_pinned_apps_tray_pill = d.dock_pinned_apps_tray_pill;
    s.dock_running_apps_tray_pill = d.dock_running_apps_tray_pill;

    s.dock_radius = d.dock_radius;
    s.dock_icon_size = d.dock_icon_size;
    s.dock_icon_spacing = d.dock_icon_spacing;
    s.dock_bottom_gap = d.dock_bottom_gap;
    s.dock_exclusive_zone_gap = d.dock_exclusive_zone_gap;
    s.dock_opacity = d.dock_opacity;
    s.dock_border_enabled = d.dock_border_enabled;
    s.dock_border_size = d.dock_border_size;
    s.dock_border_opacity = d.dock_border_opacity;
    s.dock_liquid_glass = d.dock_liquid_glass;
    s.dock_colored_glass = d.dock_colored_glass;

    s.dock_scale = d.dock_scale;
    s.dock_scale_pct = @intFromFloat(@round(d.dock_scale * 100.0));

    // An empty `output` is what an absent key leaves behind, and the combo
    // has no empty row — "Auto" is its spelling for "no output pinned".
    // Always a copy: `Settings` outlives the config arena it was read from,
    // and the caller releases this wholesale (see `Win.str_arena`).
    const raw = std.mem.trim(u8, d.output_name, " \t\r\n");
    s.dock_output_name = alloc.dupe(u8, if (raw.len == 0) "Auto" else raw) catch "Auto";

    // Widget sections: an all-empty triple means "defaults apply" (the same
    // rule `widgets.sections` reads by), so seed the visible defaults rather
    // than an empty board — otherwise the first save would blank the dock.
    const use_defaults = d.left_widgets.len == 0 and
        d.center_widgets.len == 0 and
        d.right_widgets.len == 0;
    s.dock_left_widgets = dupeStrList(
        alloc,
        if (use_defaults) &widgets.default_left else d.left_widgets,
    ) catch &.{};
    s.dock_center_widgets = dupeStrList(
        alloc,
        if (use_defaults) &widgets.default_center else d.center_widgets,
    ) catch &.{};
    s.dock_right_widgets = dupeStrList(
        alloc,
        if (use_defaults) &widgets.default_right else d.right_widgets,
    ) catch &.{};
}

/// Arena copies of one widget section. Elements are literals or arena
/// slices; either way the caller owns the copies wholesale.
fn dupeStrList(alloc: std.mem.Allocator, src: []const []const u8) ![][]const u8 {
    const out = try alloc.alloc([]const u8, src.len);
    for (src, 0..) |id, i| out[i] = try alloc.dupe(u8, id);
    return out;
}

/// `list` owns the `Entry` array; `values` owns every rendered payload. They
/// are deliberately different allocators: the array is freed entry-by-entry
/// the ordinary way, while the payloads come from an arena that is released
/// in one sweep once the document has been written. (`boolValue` returns a
/// literal, so that one payload is neither — the arena simply never sees it.)
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

/// The keys the Dock tab can move, keyed by the names `decodeDock` reads.
/// Anything the tab does not expose — `border_hue`, `slot_pill_opacity`,
/// `bar_follows_icons`, the widget lists — is simply not in here, which is
/// how it survives a save.
pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try pushBool(list, out, "show_dock", s.dock_show_dock);
    try pushBool(list, out, "autohide", s.dock_auto_hide);
    try pushBool(list, out, "group_apps", s.dock_group_apps);
    try pushBool(list, out, "dock_tooltips_enabled", s.dock_tooltips_enabled);
    try pushBool(list, out, "dock_widgets_enabled", s.dock_widgets_enabled);
    try pushBool(list, out, "dock_pinned_apps_tray_pill", s.dock_pinned_apps_tray_pill);
    try pushBool(list, out, "dock_running_apps_tray_pill", s.dock_running_apps_tray_pill);

    try pushInt(list, values, out, "radius", s.dock_radius);
    try pushInt(list, values, out, "icon_size", s.dock_icon_size);
    try pushInt(list, values, out, "icon_spacing", s.dock_icon_spacing);
    try pushInt(list, values, out, "bottom_gap", s.dock_bottom_gap);
    try pushInt(list, values, out, "exclusive_zone_gap", s.dock_exclusive_zone_gap);
    try pushInt(list, values, out, "opacity", s.dock_opacity);
    try pushBool(list, out, "border_enabled", s.dock_border_enabled);
    try pushInt(list, values, out, "border_size", s.dock_border_size);
    try pushInt(list, values, out, "border_opacity", s.dock_border_opacity);
    try pushBool(list, out, "liquid_glass", s.dock_liquid_glass);
    try pushBool(list, out, "colored_glass", s.dock_colored_glass);

    const scale = try section_store.floatValue(
        values,
        @as(f64, @floatFromInt(s.dock_scale_pct)) / 100.0,
    );
    try out.append(list, .{ .key = "scale", .value = scale });

    try pushStr(list, values, out, "output", s.dock_output_name);

    // Widget sections ride with the tab: the board edits these in place and
    // the dock rebuilds its strip from them on reload.
    try out.append(list, .{ .key = "left_widgets", .value = try section_store.arrayValue(values, s.dock_left_widgets) });
    try out.append(list, .{ .key = "center_widgets", .value = try section_store.arrayValue(values, s.dock_center_widgets) });
    try out.append(list, .{ .key = "right_widgets", .value = try section_store.arrayValue(values, s.dock_right_widgets) });
}

/// Write every Dock-tab field back into `~/.config/Event-Horizon/dock/dock.toml`.
/// The file watcher in `src/bin/app.zig` picks the change up and the dock
/// rebuilds from it, which is the whole point: this is the only writer.
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

// ------------------------------------------------------------------ tests --

test "dock-persist: load seeds the tab instead of the struct defaults" {
    const t = std.testing;
    var str_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer str_arena.deinit();

    var s: app_mod.Settings = .{};
    // Everything the struct defaults differ from on the live dock.toml.
    const d: cfg.DockSettings = .{
        .dock_show_dock = true,
        .dock_autohide = false,
        .dock_radius = 35,
        .dock_icon_size = 44,
        .dock_icon_spacing = 15,
        .dock_bottom_gap = 2,
        .dock_opacity = 48,
        .dock_liquid_glass = true,
        .dock_colored_glass = false,
        .dock_scale = 1.0,
        .output_name = "DP-1",
    };
    load(str_arena.allocator(), &s, &d);
    try t.expectEqual(@as(i32, 35), s.dock_radius);
    try t.expectEqual(@as(i32, 2), s.dock_bottom_gap);
    try t.expectEqual(@as(i32, 48), s.dock_opacity);
    try t.expectEqual(@as(i32, 100), s.dock_scale_pct);
    try t.expectEqualStrings("DP-1", s.dock_output_name);
}

test "dock-persist: an absent output key reads as Auto" {
    const t = std.testing;
    var str_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer str_arena.deinit();

    var s: app_mod.Settings = .{};
    const d: cfg.DockSettings = .{ .output_name = "" };
    load(str_arena.allocator(), &s, &d);
    try t.expectEqualStrings("Auto", s.dock_output_name);
}

test "dock-persist: entries render as the keys decodeDock reads" {
    const t = std.testing;
    const alloc = t.allocator;
    var s: app_mod.Settings = .{};
    s.dock_icon_size = 50;
    s.dock_bottom_gap = 4;
    s.dock_output_name = "DP-3";
    s.dock_scale_pct = 125;
    s.dock_auto_hide = true;

    var values = std.heap.ArenaAllocator.init(alloc);
    defer values.deinit();
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(alloc);
    try appendEntries(alloc, values.allocator(), &s, &entries);

    var found = std.StringHashMap([]const u8).init(alloc);
    defer found.deinit();
    for (entries.items) |e| try found.put(e.key, e.value);

    try t.expectEqualStrings("50", found.get("icon_size").?);
    try t.expectEqualStrings("4", found.get("bottom_gap").?);
    try t.expectEqualStrings("'DP-3'", found.get("output").?);
    try t.expectEqualStrings("1.25", found.get("scale").?);
    try t.expectEqualStrings("true", found.get("autohide").?);
    // Widget sections ride with the tab now (empty here renders `[]`).
    try t.expectEqualStrings("[]", found.get("left_widgets").?);
    try t.expectEqualStrings("[]", found.get("center_widgets").?);
    try t.expectEqualStrings("[]", found.get("right_widgets").?);
    // Keys the tab does not own must not be emitted at all.
    try t.expect(found.get("border_hue") == null);
    try t.expect(found.get("pinned_apps") == null);
    try t.expect(found.get("slot_pill_opacity") == null);
}

test "dock-persist: save round-trips through the loader" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    const dir = try std.fs.path.join(alloc, &.{ root, "dock" });
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "dock.toml" });
    defer alloc.free(path);

    // A document that carries keys the tab must not disturb.
    try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{
        .sub_path = path,
        .data =
        \\# hand-edited
        \\[dock]
        \\pinned_apps = [
        \\    'a',
        \\    'b'
        \\]
        \\border_hue = 200
        \\slot_pill_opacity = 10
        \\
        \\[panel]
        \\output = 'DP-9'
        \\
    ,
    });

    var s: app_mod.Settings = .{};
    s.dock_radius = 24;
    s.dock_icon_size = 40;
    s.dock_output_name = "DP-2";
    s.dock_scale_pct = 90;
    s.dock_pinned_apps_tray_pill = true;

    var values = std.heap.ArenaAllocator.init(alloc);
    defer values.deinit();
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(alloc);
    try appendEntries(alloc, values.allocator(), &s, &entries);
    try section_store.save(alloc, io, path, section, entries.items);

    const text = try cwd.readFileAlloc(io, path, alloc, .limited(1 << 16));
    defer alloc.free(text);

    var doc = try toml.parse(alloc, text);
    defer doc.deinit();
    const dock_tbl = doc.table("dock").?.table;

    try t.expectEqual(@as(i64, 24), dock_tbl.get("radius").?.integer);
    try t.expectEqual(@as(i64, 40), dock_tbl.get("icon_size").?.integer);
    try t.expectEqualStrings("DP-2", dock_tbl.get("output").?.string);
    try t.expectApproxEqAbs(@as(f64, 0.9), dock_tbl.get("scale").?.float, 1e-9);
    try t.expect(dock_tbl.get("autohide").?.boolean == false);
    try t.expect(dock_tbl.get("dock_pinned_apps_tray_pill").?.boolean == true);

    // Untouched: a hand-written key, a multi-line array, and another section.
    try t.expectEqual(@as(i64, 200), dock_tbl.get("border_hue").?.integer);
    try t.expectEqual(@as(i64, 10), dock_tbl.get("slot_pill_opacity").?.integer);
    try t.expectEqual(@as(usize, 2), dock_tbl.get("pinned_apps").?.array.len);
    try t.expectEqualStrings(
        "DP-9",
        doc.table("panel").?.table.get("output").?.string,
    );
    try t.expect(std.mem.indexOf(u8, text, "# hand-edited") != null);
}
