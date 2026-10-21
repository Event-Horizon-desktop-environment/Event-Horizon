const std = @import("std");
const config = @import("../../config.zig");

// Desktop widget configs — Zig port of
// src/ux/settings/data/settings_desktop_widgets_data.hpp +
// src/desktop_shell/desktop/widgets/desktop_widgets_preferences.cpp.
// Same design: typed widget ids with pos/scale/output, string round-trip,
// plus the `desktop_widgets_layout.txt` store both the settings tab and the
// desktop shell read and write.
//
// File format (verbatim C++): lines of
// `desktop_widget_<i>_<field>=<value>` with fields
// type/id/posX/posY/scale/timeFormat/showSeconds/showDate/fontSize/output.
// The parser tolerates gaps (missing indices materialise as defaults) and
// ignores anything else; the writer emits every field per index with
// `scale` at `%.2f` and skips an empty output. Writes go through
// `<path>.tmp` + rename, and create the config dir on demand.

pub const WidgetType = enum(i32) {
    clock = 0,
    weather = 1,
    system_monitor = 2,
    weather_fancy = 3,
    calendar = 4,
    media = 5,
    media_compact = 6,
    world_clock = 7,
    fetch = 8,
};

pub fn widgetId(t: WidgetType) []const u8 {
    return switch (t) {
        .clock => "clock",
        .weather => "weather",
        .system_monitor => "system_monitor",
        .weather_fancy => "weather_fancy",
        .calendar => "calendar",
        .media => "media",
        .media_compact => "media_compact",
        .world_clock => "world_clock",
        .fetch => "fetch",
    };
}

pub fn widgetTypeFromId(id: []const u8) WidgetType {
    if (std.mem.eql(u8, id, "weather")) return .weather;
    if (std.mem.eql(u8, id, "media")) return .media;
    if (std.mem.eql(u8, id, "calendar")) return .calendar;
    if (std.mem.eql(u8, id, "weather_fancy")) return .weather_fancy;
    if (std.mem.eql(u8, id, "media_compact")) return .media_compact;
    if (std.mem.eql(u8, id, "system_monitor")) return .system_monitor;
    if (std.mem.eql(u8, id, "world_clock")) return .world_clock;
    if (std.mem.eql(u8, id, "fetch")) return .fetch;
    return .clock;
}

/// The widget id a config renders under: an explicit `widget_id` wins (it is
/// how a second clock gets its own slot), otherwise the type's id.
pub fn slotId(c: WidgetConfig) []const u8 {
    return if (c.widget_id.len > 0) c.widget_id else widgetId(c.wtype);
}

pub const WidgetConfig = struct {
    wtype: WidgetType = .clock,
    id: []const u8 = "",
    widget_id: []const u8 = "",
    pos_x: i32 = 100,
    pos_y: i32 = 100,
    scale: f64 = 1.0,
    time_format: []const u8 = "",
    show_seconds: bool = false,
    show_date: bool = true,
    font_size: i32 = 48,
    output_name: []const u8 = "",
};

/// The Zig settings root (`$XDG_CONFIG_HOME/<leaf>/`, else
/// `~/.config/<leaf>/`) where `<leaf>` is `config.leafName()` (`Event-Horizon`,
/// or `Event-Horizon-zig` under `EH_ZIG_ISOLATED`). The widget layout file
/// lives directly under it — never under the C++ lowercase
/// `event-horizon/` dir, so Zig widgets no longer share the C++ layout.
/// Null when neither env var names a directory (the C++ returns empty and
/// both callers no-op).
pub fn configDir(alloc: std.mem.Allocator) !?[]u8 {
    const leaf = config.leafName();
    if (std.c.getenv("XDG_CONFIG_HOME")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return try std.fmt.allocPrint(alloc, "{s}/{s}/", .{ s, leaf });
    }
    if (std.c.getenv("HOME")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return try std.fmt.allocPrint(alloc, "{s}/.config/{s}/", .{ s, leaf });
    }
    return null;
}

pub fn layoutPath(alloc: std.mem.Allocator) !?[]u8 {
    const dir = try configDir(alloc) orelse return null;
    defer alloc.free(dir);
    return try std.fmt.allocPrint(alloc, "{s}desktop_widgets_layout.txt", .{dir});
}

fn parseInt(s: []const u8) ?i32 {
    return std.fmt.parseInt(i32, std.mem.trim(u8, s, " \t\r\n"), 10) catch null;
}

fn parseFloat(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch null;
}

/// Load the layout file. Strings borrow from the file buffer, which is owned
/// by `arena` (the C++ keeps them in the returned structs; here the caller
/// passes a scratch arena that outlives the result).
pub fn load(alloc: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) []WidgetConfig {
    const path = layoutPath(alloc) catch return &.{};
    if (path == null) return &.{};
    defer alloc.free(path.?);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path.?, arena, .limited(1 << 20)) catch return &.{};
    var out: std.ArrayListUnmanaged(WidgetConfig) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| parseLineArena(&out, arena, line);
    return out.items;
}

fn parseLineArena(out: *std.ArrayListUnmanaged(WidgetConfig), arena: std.mem.Allocator, line: []const u8) void {
    const prefix = "desktop_widget_";
    if (!std.mem.startsWith(u8, line, prefix)) return;
    const p = prefix.len;
    var e = p;
    while (e < line.len and line[e] >= '0' and line[e] <= '9') e += 1;
    if (e == p or e >= line.len or line[e] != '_') return;
    const idx = std.fmt.parseInt(usize, line[p..e], 10) catch return;
    const rest = line[e + 1 ..];
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return;
    if (eq == 0) return;
    const field = rest[0..eq];
    const val = rest[eq + 1 ..];
    while (out.items.len <= idx) out.append(arena, WidgetConfig{}) catch return;
    var c = &out.items[idx];
    if (std.mem.eql(u8, field, "type")) {
        if (parseInt(val)) |v| c.wtype = @enumFromInt(v);
    } else if (std.mem.eql(u8, field, "id")) {
        c.id = val;
    } else if (std.mem.eql(u8, field, "posX")) {
        if (parseInt(val)) |v| c.pos_x = v;
    } else if (std.mem.eql(u8, field, "posY")) {
        if (parseInt(val)) |v| c.pos_y = v;
    } else if (std.mem.eql(u8, field, "scale")) {
        if (parseFloat(val)) |v| c.scale = v;
    } else if (std.mem.eql(u8, field, "timeFormat")) {
        c.time_format = val;
    } else if (std.mem.eql(u8, field, "showSeconds")) {
        c.show_seconds = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, field, "showDate")) {
        c.show_date = std.mem.eql(u8, val, "1");
    } else if (std.mem.eql(u8, field, "fontSize")) {
        if (parseInt(val)) |v| c.font_size = v;
    } else if (std.mem.eql(u8, field, "output")) {
        c.output_name = val;
    }
}

fn emit(alloc: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

/// Serialize one config block exactly as the C++ `fprintf` sequence does.
pub fn writeBlock(alloc: std.mem.Allocator, out: *std.ArrayList(u8), i: usize, c: WidgetConfig) !void {
    try emit(alloc, out, "desktop_widget_{d}_type={d}\n", .{ i, @intFromEnum(c.wtype) });
    try emit(alloc, out, "desktop_widget_{d}_id={s}\n", .{ i, c.id });
    try emit(alloc, out, "desktop_widget_{d}_posX={d}\n", .{ i, c.pos_x });
    try emit(alloc, out, "desktop_widget_{d}_posY={d}\n", .{ i, c.pos_y });
    try emit(alloc, out, "desktop_widget_{d}_scale={d:.2}\n", .{ i, c.scale });
    try emit(alloc, out, "desktop_widget_{d}_timeFormat={s}\n", .{ i, c.time_format });
    try emit(alloc, out, "desktop_widget_{d}_showSeconds={d}\n", .{ i, @intFromBool(c.show_seconds) });
    try emit(alloc, out, "desktop_widget_{d}_showDate={d}\n", .{ i, @intFromBool(c.show_date) });
    try emit(alloc, out, "desktop_widget_{d}_fontSize={d}\n", .{ i, c.font_size });
    if (c.output_name.len > 0) try emit(alloc, out, "desktop_widget_{d}_output={s}\n", .{ i, c.output_name });
}

/// Save through `<path>.tmp` + rename (fsync before close, like the C++).
pub fn save(alloc: std.mem.Allocator, io: std.Io, configs: []const WidgetConfig) bool {
    const path = layoutPath(alloc) catch return false;
    if (path == null) return false;
    defer alloc.free(path.?);
    const dir = configDir(alloc) catch return false;
    if (dir == null) return false;
    defer alloc.free(dir.?);
    std.Io.Dir.cwd().createDirPath(io, dir.?) catch return false;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (configs, 0..) |c, i| writeBlock(alloc, &buf, i, c) catch return false;

    const tmp = std.fmt.allocPrint(alloc, "{s}.tmp", .{path.?}) catch return false;
    defer alloc.free(tmp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = buf.items }) catch return false;
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp, cwd, path.?, io) catch return false;
    return true;
}

test "settings-desktop-widgets-data: layout path follows the zig leaf" {
    const t = std.testing;
    const prev = config.leafName();
    defer config.setLeafOverride(if (std.mem.eql(u8, prev, config.kLeafIsolated)) config.kLeafIsolated else null);
    config.setLeafOverride(null);
    {
        const p = try layoutPath(t.allocator);
        defer if (p) |v| t.allocator.free(v);
        try t.expect(p != null);
        try t.expect(std.mem.endsWith(u8, p.?, "/Event-Horizon/desktop_widgets_layout.txt"));
    }
    config.setLeafOverride(config.kLeafIsolated);
    {
        const p = try layoutPath(t.allocator);
        defer if (p) |v| t.allocator.free(v);
        try t.expect(p != null);
        try t.expect(std.mem.endsWith(u8, p.?, "/Event-Horizon-zig/desktop_widgets_layout.txt"));
        try t.expect(std.mem.indexOf(u8, p.?, "event-horizon/") == null);
    }
}

test "settings-desktop-widgets-data: id round-trip" {
    const t = std.testing;
    try t.expectEqualStrings("clock", widgetId(.clock));
    try t.expectEqualStrings("media_compact", widgetId(.media_compact));
    try t.expectEqual(WidgetType.weather, widgetTypeFromId("weather"));
    try t.expectEqual(WidgetType.clock, widgetTypeFromId("bogus"));
    try t.expectEqualStrings("media", slotId(.{ .wtype = .media }));
    try t.expectEqualStrings("my-clock", slotId(.{ .wtype = .clock, .widget_id = "my-clock" }));
}

test "settings-desktop-widgets-data: layout text round-trips" {
    const t = std.testing;
    const alloc = t.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const text =
        \\desktop_widget_0_type=0
        \\desktop_widget_0_id=clock-1
        \\desktop_widget_0_posX=100
        \\desktop_widget_0_posY=120
        \\desktop_widget_0_scale=1.50
        \\desktop_widget_0_timeFormat=
        \\desktop_widget_0_showSeconds=1
        \\desktop_widget_0_showDate=1
        \\desktop_widget_0_fontSize=48
        \\desktop_widget_2_type=7
        \\desktop_widget_2_id=wc-1
        \\desktop_widget_2_posX=10
        \\desktop_widget_2_posY=20
        \\desktop_widget_2_scale=1.00
        \\desktop_widget_2_timeFormat=
        \\desktop_widget_2_showSeconds=0
        \\desktop_widget_2_showDate=1
        \\desktop_widget_2_fontSize=32
        \\desktop_widget_2_output=DP-1
        \\not_a_widget_line=yes
        \\
    ;
    var out: std.ArrayListUnmanaged(WidgetConfig) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| parseLineArena(&out, arena.allocator(), line);
    // Index 1 materialises as defaults (the C++ gap rule).
    try t.expectEqual(@as(usize, 3), out.items.len);
    try t.expectEqual(WidgetType.clock, out.items[0].wtype);
    try t.expectEqualStrings("clock-1", out.items[0].id);
    try t.expectEqual(@as(i32, 120), out.items[0].pos_y);
    try t.expect(out.items[0].show_seconds);
    try t.expectEqual(WidgetType.clock, out.items[1].wtype);
    try t.expectEqual(WidgetType.world_clock, out.items[2].wtype);
    try t.expectEqualStrings("DP-1", out.items[2].output_name);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try writeBlock(alloc, &buf, 0, out.items[0]);
    try t.expectEqualStrings(
        \\desktop_widget_0_type=0
        \\desktop_widget_0_id=clock-1
        \\desktop_widget_0_posX=100
        \\desktop_widget_0_posY=120
        \\desktop_widget_0_scale=1.50
        \\desktop_widget_0_timeFormat=
        \\desktop_widget_0_showSeconds=1
        \\desktop_widget_0_showDate=1
        \\desktop_widget_0_fontSize=48
        \\
    , buf.items);
}
