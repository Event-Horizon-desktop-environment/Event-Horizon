const std = @import("std");

// Material glyph ligatures — Zig port of
// src/ux/settings/utils/helpers/material_glyphs.{hpp,cpp} (logic only;
// actual Pango/Cairo draw reuses text/layout.zig).
// Same design: widget-id -> ligature table used by picker + tabs.

pub const entries = [_]struct { id: []const u8, glyph: []const u8 }{
    .{ .id = "clock", .glyph = "schedule" },
    .{ .id = "weather", .glyph = "cloud" },
    .{ .id = "system_monitor", .glyph = "memory" },
    .{ .id = "weather_fancy", .glyph = "partly_cloudy_day" },
    .{ .id = "calendar", .glyph = "calendar_month" },
    .{ .id = "media", .glyph = "music_note" },
    .{ .id = "media_compact", .glyph = "music_note" },
    .{ .id = "world_clock", .glyph = "public" },
    .{ .id = "fetch", .glyph = "terminal" },
    .{ .id = "dock", .glyph = "dock_to_bottom" },
    .{ .id = "panel", .glyph = "dock_to_top" },
    .{ .id = "taskbar", .glyph = "dock_to_bottom" },
    .{ .id = "wifi", .glyph = "wifi" },
    .{ .id = "bluetooth", .glyph = "bluetooth" },
    .{ .id = "battery", .glyph = "battery_full" },
    .{ .id = "volume", .glyph = "volume_up" },
};

pub fn ligatureFor(id: []const u8) []const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.id, id)) return e.glyph;
    }
    return "widgets";
}

test "settings-material-glyphs: table" {
    const t = std.testing;
    try t.expectEqualStrings("schedule", ligatureFor("clock"));
    try t.expectEqualStrings("widgets", ligatureFor("bogus"));
}
