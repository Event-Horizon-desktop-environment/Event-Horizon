//! Default Apps tab persistence: `default_apps/default_apps.toml`, one
//! key per stored desktop id — the same `web`/`mail`/…/`pdf` keys
//! `schema2.decodeDefaultApps` reads (and the C++ shell's
//! `[default_apps]` section), so the config round-trips both ways. The tab
//! owns every key of its section: an unset slot is written as an empty
//! string (the runtime resolves the system default for it), which is also
//! how a cleared slot is expressed — `section_store` merges and cannot
//! delete keys. Sections the tab does not own survive byte for byte.

const std = @import("std");
const app_mod = @import("app.zig");
const data = @import("default_apps_data.zig");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");

pub const component = "default_apps";
pub const section = "default_apps";

/// Seed tab state from the decoded config (window init).
pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, da: anytype) void {
    inline for (@typeInfo(data.Category).@"enum".fields, 0..) |f, i| {
        data.setStoredId(s, @enumFromInt(f.value), alloc.dupe(u8, @field(da, data.category_keys[i])) catch "");
    }
}

pub fn appendEntries(
    list: std.mem.Allocator,
    values: std.mem.Allocator,
    s: *const app_mod.Settings,
    out: *std.ArrayList(section_store.Entry),
) !void {
    for (data.category_keys, 0..) |key, i| {
        const id = data.storedId(s, @enumFromInt(i));
        try out.append(list, .{ .key = key, .value = try section_store.stringValue(values, id) });
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

test "default-apps-persist: save round-trips through the loader" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    const dir = try std.fs.path.join(alloc, &.{ root, "default_apps" });
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "default_apps.toml" });
    defer alloc.free(path);

    try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{
        .sub_path = path,
        .data =
        \\[default_apps]
        \\web = 'firefox.desktop'
        \\video = 'mpv.desktop'
        \\
    });

    var s: app_mod.Settings = .{};
    data.setStoredId(&s, .calendar, "korganizer.desktop");
    data.setStoredId(&s, .terminal, "org.wezfurlong.wezterm.desktop");

    var values = std.heap.ArenaAllocator.init(alloc);
    defer values.deinit();
    var entries: std.ArrayList(section_store.Entry) = .empty;
    defer entries.deinit(alloc);
    try appendEntries(alloc, values.allocator(), &s, &entries);
    try section_store.save(alloc, io, path, section, entries.items);

    // Decode path: same shape `schema2.decodeDefaultApps` reads.
    const text = try cwd.readFileAlloc(io, path, alloc, .limited(1 << 16));
    defer alloc.free(text);
    var doc = try toml.parse(alloc, text);
    defer doc.deinit();
    const tbl = doc.table("default_apps").?.table;

    try t.expectEqualStrings("korganizer.desktop", tbl.get("calendar").?.string);
    try t.expectEqualStrings("org.wezfurlong.wezterm.desktop", tbl.get("terminal").?.string);
    // Every category key is rewritten from `Settings`: slots with no stored
    // id land as empty strings (the runtime resolves the system default for
    // them), so the stale file values are replaced rather than merged.
    try t.expectEqualStrings("", tbl.get("web").?.string);
    try t.expectEqualStrings("", tbl.get("video").?.string);
}
