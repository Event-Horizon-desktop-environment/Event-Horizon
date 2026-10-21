//! Time tab persistence: `time/time.toml [time]`.
//!
//! The six keys are exactly the ones `schema2.decodeTime` reads back, so a
//! save here is a live config change for every clock face — the dock, the
//! taskbar and the desktop widgets all resolve `cfg.time` through the
//! layered config. The window seeds `Settings` from the decoded section at
//! startup (`seedFromConfig`) and flushes on every committed edit, the same
//! shape as `shell_persist`.

const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const schema2 = @import("../../config/schema2.zig");
const section_store = @import("../../config/section_store.zig");

pub const component = "time";
pub const section = "time";

/// Copy the decoded `[time]` section into the tab's `Settings` (strings go
/// through the caller's arena, which outlives the frame).
pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, t: *const schema2.TimeSettings) void {
    s.time_use_24h = t.use_24h;
    s.time_show_seconds = t.show_seconds;
    s.time_show_date = t.show_date;
    s.time_date_format = t.date_format;
    s.time_custom_format = alloc.dupe(u8, t.custom_format) catch "";
    s.time_timezone = alloc.dupe(u8, t.timezone) catch "";
}

pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    var fmt_buf: [8]u8 = undefined;
    const fmt = std.fmt.bufPrint(&fmt_buf, "{d}", .{s.time_date_format}) catch "0";
    try out.append(list, .{ .key = "use_24h", .value = section_store.boolValue(s.time_use_24h) });
    try out.append(list, .{ .key = "show_seconds", .value = section_store.boolValue(s.time_show_seconds) });
    try out.append(list, .{ .key = "show_date", .value = section_store.boolValue(s.time_show_date) });
    try out.append(list, .{ .key = "date_format", .value = fmt });
    try out.append(list, .{ .key = "custom_format", .value = try section_store.stringValue(values, s.time_custom_format) });
    try out.append(list, .{ .key = "timezone", .value = try section_store.stringValue(values, s.time_timezone) });
}

/// Upsert the six `[time]` keys, leaving every other byte of the component
/// file (and every other component) alone.
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

test "time-persist: round-trips every [time] key" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const state = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(state);

    const s = app_mod.Settings{
        .time_use_24h = true,
        .time_show_seconds = true,
        .time_show_date = true,
        .time_date_format = 3,
        .time_custom_format = "%A %B %d",
        .time_timezone = "Europe/Paris",
    };
    try save(alloc, io, state, &s);

    const path = try cfg.componentPath(alloc, state, component);
    defer alloc.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 16));
    defer alloc.free(text);
    try t.expect(std.mem.indexOf(u8, text, "[time]") != null);
    try t.expect(std.mem.indexOf(u8, text, "use_24h = true") != null);
    try t.expect(std.mem.indexOf(u8, text, "date_format = 3") != null);
    try t.expect(std.mem.indexOf(u8, text, "'%A %B %d'") != null);
    try t.expect(std.mem.indexOf(u8, text, "'Europe/Paris'") != null);
}

test "time-persist: load mirrors the decoded section" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var s = app_mod.Settings{};
    const sec = schema2.TimeSettings{
        .use_24h = true,
        .show_seconds = true,
        .show_date = false,
        .date_format = 2,
        .custom_format = "%Y",
        .timezone = "Asia/Tokyo",
    };
    load(arena.allocator(), &s, &sec);
    try t.expect(s.time_use_24h);
    try t.expect(s.time_show_seconds);
    try t.expect(!s.time_show_date);
    try t.expectEqual(@as(i32, 2), s.time_date_format);
    try t.expectEqualStrings("%Y", s.time_custom_format);
    try t.expectEqualStrings("Asia/Tokyo", s.time_timezone);
}
