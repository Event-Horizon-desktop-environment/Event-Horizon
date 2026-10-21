const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");

pub const component = "shell";
pub const section = "shell";

pub fn load(s: *app_mod.Settings, r: cfg.ShellConfig.Renderer) void {
    s.renderer = switch (r) {
        .vulkan => "vulkan",
        .cairo => "cairo",
    };
}

pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    try out.append(list, .{ .key = "renderer", .value = try section_store.stringValue(values, s.renderer) });
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

test "shell-persist: load maps the renderer enum to its option string" {
    const t = std.testing;
    var s: app_mod.Settings = .{};
    s.renderer = "cairo";
    load(&s, .vulkan);
    try t.expectEqualStrings("vulkan", s.renderer);
    load(&s, .cairo);
    try t.expectEqualStrings("cairo", s.renderer);
}

test "shell-persist: save round-trips through the loader" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    const dir = try std.fs.path.join(alloc, &.{ root, "shell" });
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "shell.toml" });
    defer alloc.free(path);

    try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{
        .sub_path = path,
        .data =
        \\[shell]
        \\ui_scale = 1.0
        \\
    });

    var s: app_mod.Settings = .{};
    s.renderer = "cairo";

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
    const shell_tbl = doc.table("shell").?.table;

    try t.expectEqualStrings("cairo", shell_tbl.get("renderer").?.string);
    try t.expectApproxEqAbs(@as(f64, 1.0), shell_tbl.get("ui_scale").?.float, 1e-9);
}
