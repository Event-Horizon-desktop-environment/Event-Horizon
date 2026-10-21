const std = @import("std");

// Settings persistence — Zig port of src/ux/settings/settings_serialize.hpp/.cpp
// (join/parse helpers + TOML key surface + state-dir paths).
// Same semantics: semicolon-joined sets, per-component state files, atomic
// write-temp-rename done by the caller. TOML encode/decode itself lives in
// config/toml.zig; this file owns the settings-specific key mapping.

pub fn joinList(alloc: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (items, 0..) |it, i| {
        if (i > 0) try out.append(alloc, ';');
        try out.appendSlice(alloc, it);
    }
    return out.toOwnedSlice(alloc);
}

pub fn parseSemicolonSet(alloc: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try out.append(alloc, try alloc.dupe(u8, trimmed));
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeStrList(alloc: std.mem.Allocator, list: [][]const u8) void {
    for (list) |s| alloc.free(s);
    alloc.free(list);
}

/// State-component file names mirror shell_config state_component_toml_path().
pub fn componentFileName(component: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}.toml", .{ component, component });
}

pub const known_components = [_][]const u8{
    "launchpad", "general", "shell",      "desktop",   "autostart",     "dock",
    "taskbar",   "panel",   "appearance", "wallpaper", "notifications", "keyboard",
    "audio",     "power",   "nightlight", "time",      "default_apps",  "mpris",
    "widgets",   "idle", "desktop_widgets",
};

pub fn isKnownComponent(name: []const u8) bool {
    for (known_components) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

/// Widget-slot enable check mirrors widget_slot_enabled_for_settings().
pub fn widgetSlotEnabled(disabled: []const []const u8, id: []const u8) bool {
    for (disabled) |d| {
        if (std.mem.eql(u8, d, id)) return false;
    }
    return true;
}

pub fn dockPreviewAutoBarPx(icon_size: i32, spacing: i32, count: usize, manual_bar_px: i32, follows_icons: bool) i32 {
    if (!follows_icons) return manual_bar_px;
    if (count == 0) return manual_bar_px;
    const c: i32 = @intCast(count);
    return c * icon_size + (c - 1) * spacing + 32;
}

test "settings-serialize: join/parse round-trip" {
    const t = std.testing;
    const j = try joinList(t.allocator, &[_][]const u8{ "a", "b", "c" });
    defer t.allocator.free(j);
    try t.expectEqualStrings("a;b;c", j);
    const parts = try parseSemicolonSet(t.allocator, "a; b;;c;");
    defer freeStrList(t.allocator, parts);
    try t.expectEqual(@as(usize, 3), parts.len);
    try t.expectEqualStrings("b", parts[1]);
}

test "settings-serialize: components + slot + preview" {
    const t = std.testing;
    try t.expect(isKnownComponent("dock"));
    try t.expect(!isKnownComponent("nope"));
    try t.expect(!widgetSlotEnabled(&[_][]const u8{"clock"}, "clock"));
    try t.expect(widgetSlotEnabled(&[_][]const u8{"clock"}, "weather"));
    try t.expectEqual(@as(i32, 76), dockPreviewAutoBarPx(44, 15, 1, 72, true));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("dock/dock.toml", try componentFileName("dock", &buf));
}
