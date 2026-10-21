const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");

// The Desktop Widgets tab's round trip to `[desktop_widgets]` in
// `~/.config/Event-Horizon/desktop_widgets/desktop_widgets.toml`.
// Covers the two `Settings` keys the tab owns — the display-output name and
// the disabled widget-slot list. The widget configs themselves live in
// `desktop_widgets_layout.txt` (`desktop_widgets_data.zig`); the C++
// `save_settings`/`load_settings` split the same way (`sc`/`s` versus the
// layout file).
//
// A save forces exactly these keys and leaves the rest of the document
// alone (section-store merge, like every other tab).

pub const component = "desktop_widgets";
pub const section = "desktop_widgets";

pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try out.append(list, .{ .key = "output_name", .value = try section_store.stringValue(values, s.desktop_widgets_output_name) });
    try out.append(list, .{ .key = "disabled_slots", .value = try section_store.arrayValue(values, s.desktop_widget_slots_disabled) });
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

// ------------------------------------------------------------------ load --

fn str(v: ?toml.Value, alloc: std.mem.Allocator) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| alloc.dupe(u8, s) catch null,
        else => null,
    };
}

fn strList(v: ?toml.Value, alloc: std.mem.Allocator) ?[][]const u8 {
    const val = v orelse return null;
    const arr = switch (val) {
        .array => |a| a,
        else => return null,
    };
    const out = alloc.alloc([]const u8, arr.len) catch return null;
    for (arr, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |s| alloc.dupe(u8, s) catch "",
            else => "",
        };
    }
    return out;
}

/// Seed the tab from a decoded `[desktop_widgets]` section. `alloc` owns the
/// output name and the disabled list (`Settings` outlives the config arena).
pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, text: []const u8) void {
    var doc = toml.parse(alloc, text) catch return;
    defer doc.deinit();
    const tbl = doc.table(section) orelse return;
    const t = tbl.table;
    if (str(t.get("output_name"), alloc)) |name| s.desktop_widgets_output_name = name;
    if (strList(t.get("disabled_slots"), alloc)) |ids| s.desktop_widget_slots_disabled = ids;
}

pub fn loadFile(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8, s: *app_mod.Settings) void {
    const path = cfg.componentPath(alloc, state_dir, component) catch return;
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return;
    defer alloc.free(text);
    load(alloc, s, text);
}

/// Shell-side view of the same file (the desktop process has no
/// `Settings`; it reads output + disabled slots straight from the toml).
pub const ShellSlots = struct {
    output_name: []const u8 = "",
    disabled: [][]const u8 = &.{},
};

pub fn loadShellSlots(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8) ShellSlots {
    const path = cfg.componentPath(alloc, state_dir, component) catch return .{};
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return .{};
    defer alloc.free(text);
    var doc = toml.parse(alloc, text) catch return .{};
    defer doc.deinit();
    const tbl = doc.table(section) orelse return .{};
    const t = tbl.table;
    var out = ShellSlots{};
    if (str(t.get("output_name"), alloc)) |name| out.output_name = name;
    if (strList(t.get("disabled_slots"), alloc)) |ids| out.disabled = ids;
    return out;
}

/// Slot enable check: absent from the disabled list means enabled — the same
/// rule as `serialize.widgetSlotEnabled`.
pub fn slotEnabled(s: *const app_mod.Settings, id: []const u8) bool {
    for (s.desktop_widget_slots_disabled) |d| {
        if (std.mem.eql(u8, d, id)) return false;
    }
    return true;
}

pub fn setSlotEnabled(alloc: std.mem.Allocator, s: *app_mod.Settings, id: []const u8, enabled: bool) !void {
    if (enabled) {
        var n: usize = 0;
        for (s.desktop_widget_slots_disabled) |d| {
            if (!std.mem.eql(u8, d, id)) {
                s.desktop_widget_slots_disabled[n] = d;
                n += 1;
            }
        }
        s.desktop_widget_slots_disabled = s.desktop_widget_slots_disabled[0..n];
    } else {
        if (slotEnabled(s, id)) {
            const grown = try alloc.alloc([]const u8, s.desktop_widget_slots_disabled.len + 1);
            @memcpy(grown[0..s.desktop_widget_slots_disabled.len], s.desktop_widget_slots_disabled);
            grown[grown.len - 1] = try alloc.dupe(u8, id);
            s.desktop_widget_slots_disabled = grown;
        }
    }
}

test "settings-desktop-widgets-persist: round-trip" {
    const t = std.testing;
    const alloc = t.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var s: app_mod.Settings = .{};
    s.desktop_widgets_output_name = "DP-1";
    try setSlotEnabled(a, &s, "weather", false);
    try setSlotEnabled(a, &s, "clock", false);
    try t.expect(!slotEnabled(&s, "weather"));
    try t.expect(slotEnabled(&s, "calendar"));
    try setSlotEnabled(a, &s, "weather", true);
    try t.expect(slotEnabled(&s, "weather"));
    try t.expect(!slotEnabled(&s, "clock"));

    var values = std.heap.ArenaAllocator.init(alloc);
    defer values.deinit();
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(alloc);
    try appendEntries(alloc, values.allocator(), &s, &entries);
    try t.expectEqual(@as(usize, 2), entries.items.len);
    try t.expectEqualStrings("output_name", entries.items[0].key);
    try t.expectEqualStrings("disabled_slots", entries.items[1].key);

    var s2: app_mod.Settings = .{};
    load(a, &s2, "[desktop_widgets]\noutput_name = 'DP-1'\ndisabled_slots = [ 'clock' ]\n");
    try t.expectEqualStrings("DP-1", s2.desktop_widgets_output_name);
    try t.expect(!slotEnabled(&s2, "clock"));
    try t.expect(slotEnabled(&s2, "weather"));
}
