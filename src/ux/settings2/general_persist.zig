const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");

pub const component = "general";
pub const section = "general";

pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, icon_theme: []const u8, avatar_path: []const u8) void {
    s.icon_theme = alloc.dupe(u8, icon_theme) catch "";
    s.avatar_path = alloc.dupe(u8, avatar_path) catch "";
}

pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try out.append(list, .{ .key = "icon_theme", .value = try section_store.stringValue(values, s.icon_theme) });
    try out.append(list, .{ .key = "avatar_path", .value = try section_store.stringValue(values, s.avatar_path) });
    try out.append(list, .{ .key = "updater_auto_check", .value = section_store.boolValue(s.updater_auto_check) });
    try out.append(list, .{ .key = "updater_check_hours", .value = try section_store.intValue(values, s.updater_check_hours) });
}

/// Seed the Updates page preferences from `general/general.toml`. `load` above
/// takes the schema-backed `[general]` values, and these two keys have no
/// schema entry — the page is their only writer, so reading its own file is
/// the whole persistence path.
pub fn loadUpdaterPrefs(
    alloc: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    s: *app_mod.Settings,
) void {
    const path = cfg.componentPath(alloc, state_dir, component) catch return;
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return;
    defer alloc.free(text);
    var doc = toml.parse(alloc, text) catch return;
    defer doc.deinit();
    const tbl = (doc.table(section) orelse return).table;
    if (tbl.get("updater_auto_check")) |v| {
        if (v == .boolean) s.updater_auto_check = v.boolean;
    }
    if (tbl.get("updater_check_hours")) |v| {
        if (v == .integer) {
            // Only the four segmented values are selectable, so a file edited
            // by hand lands on its nearest neighbour instead of leaving the
            // page with no segment highlighted.
            const h = v.integer;
            s.updater_check_hours = if (h <= 2) 1 else if (h <= 4) 3 else if (h <= 12) 6 else 24;
        }
    }
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

test "general-persist: load copies the theme instead of borrowing the arena" {
    const t = std.testing;
    var str_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer str_arena.deinit();

    var s: app_mod.Settings = .{};
    load(str_arena.allocator(), &s, "Papirus", "/tmp/face.png");
    try t.expectEqualStrings("Papirus", s.icon_theme);
    try t.expectEqualStrings("/tmp/face.png", s.avatar_path);
}

test "general-persist: save round-trips through the loader" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    const dir = try std.fs.path.join(alloc, &.{ root, "general" });
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "general.toml" });
    defer alloc.free(path);

    try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = path, .data =
        \\[general]
        \\avatar_path = '/tmp/face.png'
        \\
    });

    var s: app_mod.Settings = .{};
    s.icon_theme = "Papirus";
    s.avatar_path = "/tmp/face.png";

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
    const general_tbl = doc.table("general").?.table;

    try t.expectEqualStrings("Papirus", general_tbl.get("icon_theme").?.string);
    try t.expectEqualStrings("/tmp/face.png", general_tbl.get("avatar_path").?.string);
}
