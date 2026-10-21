const std = @import("std");

pub const schema = @import("config/schema.zig");
pub const toml = @import("config/toml.zig");
pub const watch = @import("config/watch.zig");
pub const ShellConfig = schema.ShellConfig;
pub const Loaded = schema.Loaded;
/// The `[dock]` section's decoded shape, exported so the settings app can
/// seed the Dock tab from what is on disk without reaching into `schema1`.
pub const DockSettings = @import("config/schema1.zig").DockSettings;
pub const TaskbarSettings = @import("config/schema1.zig").TaskbarSettings;
pub const AppearanceSettings = @import("config/schema3.zig").Appearance;

/// Leaf directory for every shell settings root (`<xdg-config>/Event-Horizon`).
/// `EH_ZIG_ISOLATED` switches the Zig binaries to `Event-Horizon-zig` so
/// testing the rewrite never touches the live shell's files.
/// All Zig settings (`settings.toml` plus one `<component>/<component>.toml`
/// per entry in `kComponents`) live under `$XDG_CONFIG_HOME/<leaf>` — i.e.
/// `~/.config/Event-Horizon` — never under `~/.local/state/...`.
pub const kLeafDefault: []const u8 = "Event-Horizon";
pub const kLeafIsolated: []const u8 = "Event-Horizon-zig";
pub const kIsolateEnv: []const u8 = "EH_ZIG_ISOLATED";

/// Process-wide leaf override, set once at startup from the environ (see
/// `leafForEnvFlag`). Tests never set it, so they always see the default.
var leaf_override: ?[]const u8 = null;

pub fn setLeafOverride(leaf: ?[]const u8) void {
    leaf_override = leaf;
}

pub fn leafName() []const u8 {
    return leaf_override orelse kLeafDefault;
}

/// Any non-empty `EH_ZIG_ISOLATED` value except `"0"` selects the isolated
/// leaf; unset keeps the live settings paths.
pub fn leafForEnvFlag(flag: ?[]const u8) ?[]const u8 {
    const v = flag orelse return null;
    if (v.len == 0 or std.mem.eql(u8, v, "0")) return null;
    return kLeafIsolated;
}

/// Component IDs in the exact order `merge_declarative_and_state()` walks them
/// The `section` column of the table only
/// matters when *writing* settings.toml — component files already carry their
/// own top-level sections, so the merge just unions the raw roots.
pub const kComponents = [_][]const u8{
    "general",
    "shell",
    "desktop",
    "autostart",
    "dock",
    "taskbar",
    "dashboard",
    // `launchpad` merges BEFORE `appearance`. In the C++ tree the settings
    // app owned `launchpad/launchpad.toml` and leaned on it merging last
    // (its `[appearance]` table carried the launcher page's values, folders
    // included). The Zig settings writes those keys to the appearance
    // component instead, so that file is the live writer and must win —
    // a `launchpad.toml` left over from the C++ era must not shadow it.
    // (Same reasoning as the C++ comment, opposite order, because the
    // writer moved.)
    "launchpad",
    "appearance",
    "wallpaper",
    "notifications",
    "keyboard",
    "audio",
    "power",
    "bluetooth",
    "vram_boost",
    "nightlight",
    "time",
    "default_apps",
    "mpris",
    "widgets",
    "idle",
    "file_browser",
    "live_wallpaper",
};

pub fn configFile(
    gpa: std.mem.Allocator,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
) ![]u8 {
    const dir = try declarativeDir(gpa, xdg_config_home, home);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "config.toml" });
}

/// `$XDG_CONFIG_HOME/<leaf>` — the *declarative* directory whose
/// `*.toml` files merge first (sorted by name). `<leaf>` is `Event-Horizon`,
/// or `Event-Horizon-zig` under `EH_ZIG_ISOLATED`.
pub fn declarativeDir(gpa: std.mem.Allocator, xdg_config_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    const leaf = leafName();
    if (xdg_config_home) |v| return std.fs.path.join(gpa, &.{ v, leaf });
    if (home) |h| return std.fs.path.join(gpa, &.{ h, ".config", leaf });
    return std.fs.path.join(gpa, &.{ "/tmp", leaf });
}

/// `$XDG_CONFIG_HOME/<leaf>` — the settings root that hosts `settings.toml`
/// plus one `<component>/<component>.toml` per entry in `kComponents.
/// This is the ONLY settings location: `~/.config/Event-Horizon`. Nothing is
/// read from or written to `~/.local/state/...`.
/// Currently identical to `declarativeDir` (same physical dir holds both the
/// top-level declarative `*.toml` files and the component subdirs), kept as
/// its own helper so the intent stays explicit at call sites.
pub fn settingsDir(gpa: std.mem.Allocator, xdg_config_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    return declarativeDir(gpa, xdg_config_home, home);
}

/// `<settings>/<component>/<component>.toml`.
pub fn componentPath(gpa: std.mem.Allocator, settings: []const u8, component: []const u8) ![]u8 {
    const inner = try std.fs.path.join(gpa, &.{ settings, component });
    defer gpa.free(inner);
    return std.fmt.allocPrint(gpa, "{s}/{s}.toml", .{ inner, component });
}

/// `<settings>/<component>` — the directory that actually holds the component
/// file. Worth its own helper because inotify is not recursive: watching
/// `<settings>` never reports an edit to `<settings>/<component>/<component>.toml`.
pub fn componentDir(
    gpa: std.mem.Allocator,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
    component: []const u8,
) ![]u8 {
    const settings = try settingsDir(gpa, xdg_config_home, home);
    defer gpa.free(settings);
    return std.fs.path.join(gpa, &.{ settings, component });
}

/// `<settings>/settings.toml` — the umbrella settings file.
pub fn settingsPath(gpa: std.mem.Allocator, settings: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ settings, "settings.toml" });
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Sorted `*.toml` basenames directly inside `dir_path`.
///
/// Returns an empty slice when the directory cannot be opened, mirroring the
/// Directory-existence guard. Every name is owned by the
/// caller; `errdefer` cleans up partial results.
fn listTomlNames(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]const []const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".toml")) continue;
        try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanName);
    return names.toOwnedSlice(gpa);
}

/// Deep-merges `src` over `dst` (`deep_merge_toml` semantics): nested
/// tables recurse, everything else replaces.
///
/// `alloc` is only used to grow *new* container tables in `dst`; leaf values
/// and keys keep pointing into their source document's arena, so every parsed
/// doc must outlive the merged tree (see `loadStacked`).
fn mergeInto(
    alloc: std.mem.Allocator,
    dst: *toml.Value.Table,
    src: *const toml.Value.Table,
) !void {
    var it = src.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const sv = e.value_ptr.*;
        if (sv != .table) {
            try dst.put(k, sv);
            continue;
        }
        const gop = try dst.getOrPut(k);
        gop.key_ptr.* = k;
        if (!(gop.found_existing and gop.value_ptr.* == .table)) {
            gop.value_ptr.* = .{ .table = toml.Value.Table.init(alloc) };
        }
        // `gop` points into `dst`, which this recursion never grows, so the
        // pointer stays valid across the call.
        try mergeInto(alloc, &gop.value_ptr.*.table, &sv.table);
    }
}

pub fn loadPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch
        return schema.loadText(gpa, "");
    defer gpa.free(data);
    return schema.loadText(gpa, data);
}

/// Layered load from `~/.config/Event-Horizon` ONLY — nothing is read from
/// `~/.local/state/...` or any lowercase legacy dir.
///
/// Layers, in order:
/// 1. `<config>/Event-Horizon/*.toml`, sorted by name
/// 2. `<config>/Event-Horizon/settings.toml`
/// 3. `<config>/Event-Horizon/<name>/<name>.toml` for each `kComponents`
///    entry, in order
///
/// Missing files are skipped and parse errors are ignored, both silently.
/// `live_wallpaper` has its stray `wallpaper` key dropped before merging so
/// it cannot clobber the wallpaper app.
///
/// All documents stay parsed until the deep-merged root has been decoded,
/// because merged values alias the per-document arenas.
pub fn loadStacked(
    gpa: std.mem.Allocator,
    io: std.Io,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
) !Loaded {
    const cwd = std.Io.Dir.cwd();

    const decl = try declarativeDir(gpa, xdg_config_home, home);
    defer gpa.free(decl);
    const settings = try settingsDir(gpa, xdg_config_home, home);
    defer gpa.free(settings);

    const Candidate = struct {
        path: []const u8,
        /// `live_wallpaper` files may carry a stray `[wallpaper]` table that
        /// must not clobber the wallpaper app's own component file.
        drop_wallpaper: bool = false,
    };
    var paths: std.ArrayList(Candidate) = .empty;
    defer {
        for (paths.items) |c| gpa.free(c.path);
        paths.deinit(gpa);
    }

    const names = try listTomlNames(gpa, io, decl);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    for (names) |n| {
        try paths.append(gpa, .{ .path = try std.fs.path.join(gpa, &.{ decl, n }) });
    }

    try paths.append(gpa, .{ .path = try settingsPath(gpa, settings) });
    for (kComponents) |c| {
        try paths.append(gpa, .{
            .path = try componentPath(gpa, settings, c),
            .drop_wallpaper = std.mem.eql(u8, c, "live_wallpaper"),
        });
    }

    // Parse errors (including "file does not exist") are ignored per file.
    var docs: std.ArrayList(toml.Doc) = .empty;
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(gpa);
    }

    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    const ta = tmp.allocator();

    var merged = toml.Value.Table.init(ta);
    for (paths.items) |cand| {
        const data = cwd.readFileAlloc(io, cand.path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(data);
        const doc = toml.parse(gpa, data) catch continue;
        docs.append(gpa, doc) catch {
            var d = doc;
            d.deinit();
            return error.OutOfMemory;
        };
        const last = &docs.items[docs.items.len - 1];
        if (cand.drop_wallpaper) _ = last.root.remove("wallpaper");
        try mergeInto(ta, &merged, &last.root);
    }

    return schema.loadRoot(gpa, &merged);
}

/// Layered load from the ambient XDG paths. See `loadStacked`.
pub fn loadDefault(
    gpa: std.mem.Allocator,
    io: std.Io,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
) !Loaded {
    return loadStacked(gpa, io, xdg_config_home, home);
}

test "config: leaf isolation flag parsing" {
    const t = std.testing;
    try t.expect(leafForEnvFlag(null) == null);
    try t.expect(leafForEnvFlag("") == null);
    try t.expect(leafForEnvFlag("0") == null);
    try t.expectEqualStrings(kLeafIsolated, leafForEnvFlag("1").?);
    try t.expectEqualStrings("Event-Horizon-zig", leafForEnvFlag("yes").?);
}

test "config: leaf override redirects the dir helpers" {
    const t = std.testing;
    const prev = leaf_override;
    defer setLeafOverride(prev);
    setLeafOverride(kLeafIsolated);
    try t.expectEqualStrings(kLeafIsolated, leafName());
    const d = try declarativeDir(t.allocator, "/xdg", "/home/u");
    defer t.allocator.free(d);
    try t.expectEqualStrings("/xdg/Event-Horizon-zig", d);
    const s = try settingsDir(t.allocator, "/xdg", "/home/u");
    defer t.allocator.free(s);
    try t.expectEqualStrings("/xdg/Event-Horizon-zig", s);
    const c = try componentPath(t.allocator, s, "dock");
    defer t.allocator.free(c);
    try t.expectEqualStrings("/xdg/Event-Horizon-zig/dock/dock.toml", c);
}

test "config: config file paths" {
    const t = std.testing;
    const p1 = try configFile(t.allocator, "/xdg", null);
    defer t.allocator.free(p1);
    try t.expectEqualStrings("/xdg/Event-Horizon/config.toml", p1);
    const p2 = try configFile(t.allocator, null, "/home/u");
    defer t.allocator.free(p2);
    try t.expectEqualStrings("/home/u/.config/Event-Horizon/config.toml", p2);
}

test "config: declarative and settings path helpers" {
    const t = std.testing;
    const d = try declarativeDir(t.allocator, "/xdg", "/home/u");
    defer t.allocator.free(d);
    try t.expectEqualStrings("/xdg/Event-Horizon", d);
    const s = try settingsDir(t.allocator, "/xdg", "/home/u");
    defer t.allocator.free(s);
    try t.expectEqualStrings("/xdg/Event-Horizon", s);
    const c = try componentPath(t.allocator, s, "dock");
    defer t.allocator.free(c);
    try t.expectEqualStrings("/xdg/Event-Horizon/dock/dock.toml", c);
    const st = try settingsPath(t.allocator, s);
    defer t.allocator.free(st);
    try t.expectEqualStrings("/xdg/Event-Horizon/settings.toml", st);
}

test "config: deep merge recurses tables and replaces scalars" {
    const t = std.testing;
    var a = try toml.parse(t.allocator,
        \\[dock]
        \\icon_size = 40
        \\pinned_apps = ["a"]
        \\autohide = true
        \\[appearance]
        \\overlay_opacity_master = 1.0
    );
    defer a.deinit();
    var b = try toml.parse(t.allocator,
        \\[dock]
        \\icon_size = 46
        \\pinned_apps = ["b", "c"]
        \\[taskbar]
        \\height = 30
    );
    defer b.deinit();

    var tmp = std.heap.ArenaAllocator.init(t.allocator);
    defer tmp.deinit();
    var merged = toml.Value.Table.init(tmp.allocator());
    try mergeInto(tmp.allocator(), &merged, &a.root);
    try mergeInto(tmp.allocator(), &merged, &b.root);

    var loaded = try schema.loadRoot(t.allocator, &merged);
    defer loaded.deinit();
    const c = loaded.cfg;
    // later layer wins scalar/array, earlier layer survives untouched keys
    // (icon_size clamps to [0, 50] in schema1.decodeDock)
    try t.expectEqual(@as(i32, 46), c.dock.dock_icon_size);
    try t.expectEqual(@as(usize, 2), c.dock.pinned_apps.len);
    try t.expect(c.dock.dock_autohide);
    try t.expectEqual(@as(i32, 30), c.taskbar.height);
    try t.expectEqual(@as(f32, 1.0), c.appearance.overlay_opacity_master);
}

test "config: loadStacked merges declarative, settings and component files" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);

    const cfg_home = try std.fs.path.join(t.allocator, &.{ root, "cfg" });
    defer t.allocator.free(cfg_home);

    // Settings live under ~/.config/Event-Horizon ONLY (same root as the
    // declarative *.toml files). Nothing is read from state/legacy dirs.
    const decl = try declarativeDir(t.allocator, cfg_home, null);
    defer t.allocator.free(decl);
    const st = try settingsDir(t.allocator, cfg_home, null);
    defer t.allocator.free(st);

    // Two sorted declarative files: the later one must win on icon_size while
    // the earlier one's appearance value survives untouched.
    try cwd.createDirPath(io, decl);
    const base_path = try std.fs.path.join(t.allocator, &.{ decl, "00-base.toml" });
    defer t.allocator.free(base_path);
    try cwd.writeFile(io, .{ .sub_path = base_path, .data =
        \\[appearance]
        \\overlay_opacity_master = 0.5
        \\[dock]
        \\icon_size = 40
        \\
    });
    const override_path = try std.fs.path.join(t.allocator, &.{ decl, "10-override.toml" });
    defer t.allocator.free(override_path);
    try cwd.writeFile(io, .{ .sub_path = override_path, .data =
        \\[dock]
        \\icon_size = 44
        \\
    });

    // Umbrella settings file.
    try cwd.createDirPath(io, st);
    const settings_file = try settingsPath(t.allocator, st);
    defer t.allocator.free(settings_file);
    try cwd.writeFile(io, .{ .sub_path = settings_file, .data =
        \\[taskbar]
        \\height = 40
        \\
    });

    // Component files win over settings.toml.
    const dock_dir = try componentPath(t.allocator, st, "dock");
    defer t.allocator.free(dock_dir);
    try cwd.createDirPath(io, dock_dir[0..std.mem.lastIndexOfScalar(u8, dock_dir, '/').?]);
    try cwd.writeFile(io, .{ .sub_path = dock_dir, .data =
        \\[dock]
        \\icon_size = 46
        \\pinned_apps = ["a", "b", "c"]
        \\
    });

    // live_wallpaper carries a [wallpaper] table that must be dropped so it
    // cannot clobber the wallpaper component's own values.
    const wp_dir = try componentPath(t.allocator, st, "wallpaper");
    defer t.allocator.free(wp_dir);
    try cwd.createDirPath(io, wp_dir[0..std.mem.lastIndexOfScalar(u8, wp_dir, '/').?]);
    try cwd.writeFile(io, .{ .sub_path = wp_dir, .data =
        \\[wallpaper]
        \\enabled = true
        \\image = "/good.jpg"
        \\
    });

    const lw_dir = try componentPath(t.allocator, st, "live_wallpaper");
    defer t.allocator.free(lw_dir);
    try cwd.createDirPath(io, lw_dir[0..std.mem.lastIndexOfScalar(u8, lw_dir, '/').?]);
    try cwd.writeFile(io, .{ .sub_path = lw_dir, .data =
        \\[wallpaper]
        \\image = "/bad.jpg"
        \\
    });

    var loaded = try loadStacked(t.allocator, io, cfg_home, null);
    defer loaded.deinit();
    const c = loaded.cfg;

    // component file beats both declarative files
    try t.expectEqual(@as(i32, 46), c.dock.dock_icon_size);
    try t.expectEqual(@as(usize, 3), c.dock.pinned_apps.len);
    // settings.toml contributes its own section
    try t.expectEqual(@as(i32, 40), c.taskbar.height);
    // untouched declarative key survives the later files
    try t.expectEqual(@as(f32, 0.5), c.appearance.overlay_opacity_master);
    // wallpaper component loads, and live_wallpaper's key was erased
    try t.expect(c.wallpaper_enabled);
    try t.expectEqualStrings("/good.jpg", c.wallpaper_image);
}

test "config: the appearance component beats a stale launchpad file" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);

    const cfg_home = try std.fs.path.join(t.allocator, &.{ root, "cfg" });
    defer t.allocator.free(cfg_home);
    const st = try settingsDir(t.allocator, cfg_home, null);
    defer t.allocator.free(st);

    // The Zig settings writes the launcher page's keys into the appearance
    // component...
    const ap = try componentPath(t.allocator, st, "appearance");
    defer t.allocator.free(ap);
    try cwd.createDirPath(io, ap[0..std.mem.lastIndexOfScalar(u8, ap, '/').?]);
    try cwd.writeFile(io, .{ .sub_path = ap, .data =
        \\[appearance]
        \\launchpad_view_mode = 1
        \\
    });

    // ...while a C++-era `launchpad.toml` still carries an `[appearance]`
    // table of its own (the C++ settings wrote it and relied on it merging
    // last). It must not shadow the file the Zig settings actually writes.
    const lp = try componentPath(t.allocator, st, "launchpad");
    defer t.allocator.free(lp);
    try cwd.createDirPath(io, lp[0..std.mem.lastIndexOfScalar(u8, lp, '/').?]);
    try cwd.writeFile(io, .{ .sub_path = lp, .data =
        \\[appearance]
        \\launchpad_view_mode = 0
        \\
    });

    var loaded = try loadStacked(t.allocator, io, cfg_home, null);
    defer loaded.deinit();
    try t.expectEqual(@as(i32, 1), loaded.cfg.appearance.launchpad_view_mode);
}

test "config: loadStacked tolerates missing trees" {
    const t = std.testing;
    const io = std.testing.io;
    var loaded = try loadStacked(t.allocator, io, "/nonexistent/x", null);
    defer loaded.deinit();
    try t.expectEqual(@as(i32, 44), loaded.cfg.dock.dock_icon_size);
}
