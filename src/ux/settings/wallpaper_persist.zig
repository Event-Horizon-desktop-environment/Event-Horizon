const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");

// The Wallpaper + Bing tabs' round trip to `[wallpaper]` in
// `~/.config/Event-Horizon/wallpaper/wallpaper.toml` — the Zig port of the
// wallpaper keys in C++ `save_settings` / `load_settings`.
//
// One file carries both tabs (that is how the C++ serialiser lays it out), so
// one module owns every key: `wallpaper_*` for the Wallpaper tab and
// `bing_*` for the Bing tab. A save forces exactly those keys and leaves the
// rest of the document alone, the same rule `dock_persist` follows — the
// section store merges, it does not rewrite.
//
// This file is also the apply path. The wallpaper component watches its own
// directory with inotify and re-reads it on change, so writing the file is
// what repaints the desktop; there is no explicit "apply" call to port.

pub const component = "wallpaper";
pub const section = "wallpaper";

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

/// Every key the two tabs own, under the names the C++ loader reads.
pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    // Wallpaper tab.
    try pushBool(list, out, "enabled", s.wallpaper_enabled);
    try pushInt(list, values, out, "mode", s.wallpaper_mode);
    try pushStr(list, values, out, "image", s.wallpaper_image);
    try pushStr(list, values, out, "folder", s.wallpaper_folder);
    try pushInt(list, values, out, "folder_picker_mode", s.wallpaper_folder_picker_mode);

    // Bing tab.
    try pushBool(list, out, "bing_enabled", s.bing_enabled);
    try pushBool(list, out, "bing_daily_enabled", s.bing_daily_enabled);
    try pushStr(list, values, out, "bing_download_path", s.bing_download_path);
    try pushInt(list, values, out, "bing_filter", s.bing_filter);
    try pushStr(list, values, out, "bing_blocked_keywords", s.bing_blocked_keywords);
}

/// Write both tabs back. The wallpaper component's watcher picks the change
/// up and applies it — this is the only writer.
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

const Vals = struct {
    enabled: ?bool = null,
    mode: ?i64 = null,
    image: ?[]const u8 = null,
    folder: ?[]const u8 = null,
    folder_picker_mode: ?i64 = null,
    bing_enabled: ?bool = null,
    bing_daily_enabled: ?bool = null,
    bing_download_path: ?[]const u8 = null,
    bing_filter: ?i64 = null,
    bing_blocked_keywords: ?[]const u8 = null,
};

fn str(v: ?toml.Value, alloc: std.mem.Allocator) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| alloc.dupe(u8, s) catch null,
        else => null,
    };
}

fn int(v: ?toml.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |n| n,
        else => null,
    };
}

fn boolean(v: ?toml.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .boolean => |b| b,
        else => null,
    };
}

fn decode(text: []const u8, alloc: std.mem.Allocator) !Vals {
    var doc = try toml.parse(alloc, text);
    defer doc.deinit();
    const tbl = doc.table(section) orelse return .{};
    const t = tbl.table;
    return .{
        .enabled = boolean(t.get("enabled")),
        .mode = int(t.get("mode")),
        .image = str(t.get("image"), alloc),
        .folder = str(t.get("folder"), alloc),
        .folder_picker_mode = int(t.get("folder_picker_mode")),
        .bing_enabled = boolean(t.get("bing_enabled")),
        .bing_daily_enabled = boolean(t.get("bing_daily_enabled")),
        .bing_download_path = str(t.get("bing_download_path"), alloc),
        .bing_filter = int(t.get("bing_filter")),
        .bing_blocked_keywords = str(t.get("bing_blocked_keywords"), alloc),
    };
}

/// Seed the tabs from what is on disk. Without this the first save would
/// write the struct's defaults over live values — an absent `folder_picker_mode`
/// would silently reset a user's kdialog choice back to "native dialog".
///
/// `alloc` is the window's string arena: `Settings` holds plain slices and
/// the document is thrown away immediately after parsing. A missing file (or
/// a missing key) simply leaves the field untouched.
pub fn loadInto(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8, s: *app_mod.Settings) void {
    const path = cfg.componentPath(alloc, state_dir, component) catch return;
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 16)) catch return;
    defer alloc.free(text);
    const v = decode(text, alloc) catch |e| {
        std.log.scoped(.settings).warn("wallpaper: config parse failed: {s}", .{@errorName(e)});
        return;
    };
    if (v.enabled) |b| s.wallpaper_enabled = b;
    if (v.mode) |n| s.wallpaper_mode = @intCast(std.math.clamp(n, 0, 4));
    if (v.image) |sv| s.wallpaper_image = sv;
    if (v.folder) |sv| s.wallpaper_folder = sv;
    if (v.folder_picker_mode) |n| s.wallpaper_folder_picker_mode = @intCast(std.math.clamp(n, 0, 3));
    if (v.bing_enabled) |b| s.bing_enabled = b;
    if (v.bing_daily_enabled) |b| s.bing_daily_enabled = b;
    if (v.bing_download_path) |sv| s.bing_download_path = sv;
    if (v.bing_filter) |n| s.bing_filter = @intCast(@max(0, n));
    if (v.bing_blocked_keywords) |sv| s.bing_blocked_keywords = sv;
}

// ------------------------------------------------------------------ tests --

test "wallpaper-persist: entries render as the keys the loader reads" {
    const t = std.testing;
    const alloc = t.allocator;
    var s: app_mod.Settings = .{};
    s.wallpaper_enabled = true;
    s.wallpaper_mode = 3;
    s.wallpaper_image = "/w/a.png";
    s.wallpaper_folder = "/w";
    s.wallpaper_folder_picker_mode = 2;
    s.bing_enabled = true;
    s.bing_filter = 4;

    var values = std.heap.ArenaAllocator.init(alloc);
    defer values.deinit();
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(alloc);
    try appendEntries(alloc, values.allocator(), &s, &entries);

    var found = std.StringHashMap([]const u8).init(alloc);
    defer found.deinit();
    for (entries.items) |e| try found.put(e.key, e.value);

    try t.expectEqualStrings("true", found.get("enabled").?);
    try t.expectEqualStrings("3", found.get("mode").?);
    try t.expectEqualStrings("'/w/a.png'", found.get("image").?);
    try t.expectEqualStrings("'/w'", found.get("folder").?);
    try t.expectEqualStrings("2", found.get("folder_picker_mode").?);
    try t.expectEqualStrings("true", found.get("bing_enabled").?);
    try t.expectEqualStrings("4", found.get("bing_filter").?);
    try t.expectEqualStrings("\"\"", found.get("bing_blocked_keywords").?);
}

test "wallpaper-persist: save round-trips through loadInto and keeps foreign keys" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    const dir = try std.fs.path.join(alloc, &.{ root, "wallpaper" });
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "wallpaper.toml" });
    defer alloc.free(path);

    try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{
        .sub_path = path,
        .data =
        \\[wallpaper]
        \\hand_edited = 42
        \\interval_min = 15
        \\
    });

    var s: app_mod.Settings = .{};
    s.wallpaper_mode = 1;
    s.wallpaper_image = "/pics/x.jpg";
    s.wallpaper_folder_picker_mode = 3;
    s.bing_blocked_keywords = "cat,dog";

    try save(alloc, io, root, &s);

    // `loadInto` dupes strings into the caller's allocator — in the window
    // that is the long-lived string arena; here an arena stands in for it.
    var seeded: app_mod.Settings = .{};
    var str_arena = std.heap.ArenaAllocator.init(alloc);
    defer str_arena.deinit();
    loadInto(str_arena.allocator(), io, root, &seeded);
    try t.expectEqual(@as(i32, 1), seeded.wallpaper_mode);
    try t.expectEqualStrings("/pics/x.jpg", seeded.wallpaper_image);
    try t.expectEqual(@as(i32, 3), seeded.wallpaper_folder_picker_mode);
    try t.expectEqualStrings("cat,dog", seeded.bing_blocked_keywords);
    // The save wrote every key, so the seeded value is what was saved — not
    // the struct default (false). A key the file lacked would stay default.
    try t.expect(!seeded.wallpaper_enabled);

    const text = try cwd.readFileAlloc(io, path, alloc, .limited(1 << 16));
    defer alloc.free(text);
    var doc = try toml.parse(alloc, text);
    defer doc.deinit();
    const tbl = doc.table("wallpaper").?.table;
    try t.expectEqual(@as(i64, 42), tbl.get("hand_edited").?.integer);
    try t.expectEqual(@as(i64, 15), tbl.get("interval_min").?.integer);
}

test "wallpaper-persist: a missing file leaves the struct alone" {
    const t = std.testing;
    const alloc = t.allocator;
    var s: app_mod.Settings = .{};
    s.wallpaper_mode = 4;
    loadInto(alloc, std.testing.io, "/nonexistent-state-dir-xyz", &s);
    try t.expectEqual(@as(i32, 4), s.wallpaper_mode);
}
