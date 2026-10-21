//! Per-instance widget
//! settings and the boolean word list.
//!
//! Kept separate from `dock/widgets.zig`, whose `settingBool` implements
//! `widget_instance_enabled` (first-byte test). This file is what the
//! *paint* code reads: `show_seconds`, `use_24h`, `show_percent`, …

const std = @import("std");
const schema = @import("../../../config/schema.zig");

const ShellConfig = schema.ShellConfig;

/// `widget_setting` — the raw value of `key` on widget instance `id`, or an
/// empty string when either table or the key is absent.
pub fn widgetSetting(sc: *const ShellConfig, id: []const u8, key: []const u8) []const u8 {
    for (sc.widgets) |*w| {
        if (!std.mem.eql(u8, w.id, id)) continue;
        for (w.settings) |*s| {
            if (std.mem.eql(u8, s.key, key)) return s.value;
        }
        return "";
    }
    return "";
}

/// Boolean word parser — empty falls back, the word list decides, and
/// anything else is the fallback too.
pub fn parseBoolSetting(v: []const u8, fallback: bool) bool {
    if (v.len == 0) return fallback;
    if (wordIs(v, "1") or wordIs(v, "true") or wordIs(v, "True") or wordIs(v, "yes") or wordIs(v, "Yes")) return true;
    if (wordIs(v, "0") or wordIs(v, "false") or wordIs(v, "False") or wordIs(v, "no") or wordIs(v, "No")) return false;
    return fallback;
}

fn wordIs(v: []const u8, w: []const u8) bool {
    return std.mem.eql(u8, v, w);
}

/// The common `widget_setting` + `parse_bool_setting` pair.
pub fn settingBool(sc: *const ShellConfig, id: []const u8, key: []const u8, fallback: bool) bool {
    return parseBoolSetting(widgetSetting(sc, id, key), fallback);
}

/// `widget_setting` where the value must be an integer in `[lo, hi]`;
/// malformed or absent values fall back.
pub fn settingInt(sc: *const ShellConfig, id: []const u8, key: []const u8, lo: i64, hi: i64, fallback: i64) i64 {
    const v = widgetSetting(sc, id, key);
    if (v.len == 0) return fallback;
    const n = std.fmt.parseInt(i64, v, 10) catch return fallback;
    return @min(hi, @max(lo, n));
}

/// `widget_list_contains_*` — does any id in `list` resolve to `impl`?
pub fn listContainsImpl(sc: *const ShellConfig, list: []const []const u8, impl: []const u8) bool {
    for (list) |id| {
        if (std.mem.eql(u8, implementationType(sc, id), impl)) return true;
    }
    return false;
}

/// `widget_implementation_type`, re-declared here so the widget layer does
/// not have to depend on the dock model. `pear_center` is the user-facing
/// name for the quick-settings widget and shares `control_center`.
pub fn implementationType(sc: *const ShellConfig, id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "pear_center")) {
        if (find(sc, id)) |w| {
            if (w.type.len == 0 or std.mem.eql(u8, w.type, "pear_center")) return "control_center";
            return w.type;
        }
        return "control_center";
    }
    if (find(sc, id)) |w| {
        if (std.mem.eql(u8, w.type, "pear_center")) return "control_center";
        return w.type;
    }
    return id;
}

fn find(sc: *const ShellConfig, id: []const u8) ?*const schema.WidgetInstance {
    for (sc.widgets) |*w| {
        if (std.mem.eql(u8, w.id, id)) return w;
    }
    return null;
}

fn load(text: []const u8) !schema.Loaded {
    return schema.loadText(std.testing.allocator, text);
}

test "widget-settings: value lookup and bool words" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.clock]
        \\show_seconds = "true"
        \\[widget.battery]
        \\show_percent = "0"
        \\label = "no"
        \\weird = "perhaps"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    try t.expectEqualStrings("true", widgetSetting(c, "clock", "show_seconds"));
    try t.expectEqualStrings("", widgetSetting(c, "clock", "missing"));
    try t.expectEqualStrings("", widgetSetting(c, "nope", "show_seconds"));

    try t.expect(settingBool(c, "clock", "show_seconds", false));
    try t.expect(!settingBool(c, "battery", "show_percent", true));
    try t.expect(!settingBool(c, "battery", "label", true));
    // Unknown words keep the fallback.
    try t.expect(settingBool(c, "battery", "weird", true));
    try t.expect(!settingBool(c, "battery", "weird", false));
    // Absent keys keep the fallback too.
    try t.expect(settingBool(c, "clock", "use_24h", true));
    try t.expect(!settingBool(c, "clock", "use_24h", false));
}

test "widget-settings: clamped integer and empty values" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.workspaces]
        \\max_slots = "6"
        \\bad = "xx"
        \\big = "99"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    try t.expectEqual(@as(i64, 6), settingInt(c, "workspaces", "max_slots", 1, 10, 3));
    try t.expectEqual(@as(i64, 3), settingInt(c, "workspaces", "bad", 1, 10, 3));
    try t.expectEqual(@as(i64, 3), settingInt(c, "workspaces", "gone", 1, 10, 3));
    // Clamped to `hi` rather than rejected.
    try t.expectEqual(@as(i64, 10), settingInt(c, "workspaces", "big", 1, 10, 3));
}

test "widget-settings: implementation type resolution" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.pear_center]
        \\[widget.custom]
        \\type = "clock"
        \\[widget.tray]
        \\type = "system_tray"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    try t.expectEqualStrings("control_center", implementationType(c, "pear_center"));
    try t.expectEqualStrings("clock", implementationType(c, "custom"));
    try t.expectEqualStrings("system_tray", implementationType(c, "tray"));
    try t.expectEqualStrings("media", implementationType(c, "media"));

    const list = [_][]const u8{ "media", "custom", "pear_center" };
    try t.expect(listContainsImpl(c, &list, "clock"));
    try t.expect(!listContainsImpl(c, &list, "battery"));
}
