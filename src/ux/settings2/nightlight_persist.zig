//! Night-light settings: seed the UI model from the layered config and
//! write `[nightlight]` back to the shell state.
//!
//! The section lives in `general/general.toml`, not its own component file,
//! on purpose: the dock/taskbar night toggles (`pear.prefs.setNightLight`)
//! already write `enabled` there, and writing two files for one section
//! would let one shadow the other through the layered merge.
//! The supervisor watches this dir and drives the gamma client from it —
//! see `runner.zig`'s `NightHost`.

const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const decode = @import("../../config/decode.zig");
const schema2 = @import("../../config/schema2.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");

/// Same file `pear.prefs` touches; only this section is owned here.
pub const component = "general";
pub const section = "nightlight";

/// Config → UI model. Scalars only, so no allocation dance is needed; the
/// `nightlight_*` names line up with `fields.Field`.
pub fn load(_alloc: std.mem.Allocator, s: *app_mod.Settings, nl: *const schema2.NightLightSettings) void {
    _ = _alloc;
    s.nightlight_enabled = nl.enabled;
    s.nightlight_day_temp = nl.day_temperature;
    s.nightlight_night_temp = nl.night_temperature;
    s.nightlight_schedule = nl.schedule_mode;
    s.nightlight_start_min = nl.schedule_start_min;
    s.nightlight_end_min = nl.schedule_end_min;
    s.nightlight_use_location = nl.use_location;
    s.nightlight_latitude = nl.latitude;
    s.nightlight_longitude = nl.longitude;
}

pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try out.append(list, .{ .key = "enabled", .value = section_store.boolValue(s.nightlight_enabled) });
    try out.append(list, .{ .key = "day_temperature", .value = try section_store.intValue(values, s.nightlight_day_temp) });
    try out.append(list, .{ .key = "night_temperature", .value = try section_store.intValue(values, s.nightlight_night_temp) });
    try out.append(list, .{ .key = "schedule_mode", .value = try section_store.intValue(values, s.nightlight_schedule) });
    try out.append(list, .{ .key = "schedule_start_min", .value = try section_store.intValue(values, s.nightlight_start_min) });
    try out.append(list, .{ .key = "schedule_end_min", .value = try section_store.intValue(values, s.nightlight_end_min) });
    try out.append(list, .{ .key = "use_location", .value = section_store.boolValue(s.nightlight_use_location) });
    try out.append(list, .{ .key = "latitude", .value = try section_store.intValue(values, s.nightlight_latitude) });
    try out.append(list, .{ .key = "longitude", .value = try section_store.intValue(values, s.nightlight_longitude) });
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

test "nightlight-persist: save round-trips and keeps foreign sections" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);

    // A pre-existing general.toml with content this module must not touch.
    const dir = try std.fs.path.join(alloc, &.{ root, "general" });
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "general.toml" });
    defer alloc.free(path);
    try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{
        .sub_path = path,
        .data =
        \\[general]
        \\icon_theme = 'Papirus'
        \\icon_frames = true
        \\
    });

    var s: app_mod.Settings = .{};
    s.nightlight_enabled = true;
    s.nightlight_night_temp = 3400;
    s.nightlight_use_location = true;
    s.nightlight_longitude = -72;

    try save(alloc, io, root, &s);

    const text = try cwd.readFileAlloc(io, path, alloc, .limited(1 << 16));
    defer alloc.free(text);

    var doc = try toml.parse(alloc, text);
    defer doc.deinit();

    const nl_tbl = doc.table("nightlight").?.table;
    try t.expectEqual(true, nl_tbl.get("enabled").?.boolean);
    try t.expectEqual(@as(i64, 3400), nl_tbl.get("night_temperature").?.integer);
    try t.expectEqual(true, nl_tbl.get("use_location").?.boolean);
    try t.expectEqual(@as(i64, -72), nl_tbl.get("longitude").?.integer);

    // The unrelated section survived, keys intact.
    const gen_tbl = doc.table("general").?.table;
    try t.expectEqualStrings("Papirus", gen_tbl.get("icon_theme").?.string);
    try t.expectEqual(true, gen_tbl.get("icon_frames").?.boolean);

    // And the decode schema reads the whole thing back within its clamps.
    var decoded: schema2.NightLightSettings = .{};
    if (decode.childTbl(&doc.root, "nightlight")) |dec_tbl| try schema2.decodeNightLight(dec_tbl, &decoded);
    try t.expect(decoded.enabled);
    try t.expectEqual(@as(i32, 3400), decoded.night_temperature);
    try t.expect(decoded.use_location);
    try t.expectEqual(@as(i32, -72), decoded.longitude);
}
