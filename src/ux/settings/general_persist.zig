const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");

pub const component = "general";
pub const section = "general";

pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, icon_theme: []const u8) void {
    s.icon_theme = alloc.dupe(u8, icon_theme) catch "";
}

pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try out.append(list, .{ .key = "icon_theme", .value = try section_store.stringValue(values, s.icon_theme) });
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
    load(str_arena.allocator(), &s, "Papirus");
    try t.expectEqualStrings("Papirus", s.icon_theme);
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
    try cwd.writeFile(io, .{
        .sub_path = path,
        .data =
        \\[general]
        \\avatar_path = '/tmp/face.png'
        \\
    });

    var s: app_mod.Settings = .{};
    s.icon_theme = "Papirus";

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
