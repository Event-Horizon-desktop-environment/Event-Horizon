const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const icon_raster = @import("icon_raster.zig");
const icon_lookup = @import("icon_lookup.zig");

// Icon-theme service for the settings app: the
// installed-theme list the settings app's Icons tab grids over, the preview
// icon loader behind each card, and `apply_icon_theme`, which pushes a choice
// out to GNOME/Qt/KDE. The dock-side runtime cache stays in `icon_cache.zig`.
//
// Same design: XDG icon bases in probe order (test hook, home,
// XDG_DATA_HOME, XDG_DATA_DIRS, flatpak), `index.theme` read with the same
// validation ([Icon Theme] section + at least one Directories entry), the
// search ladder from `append_theme_search_dirs` (theme-declared directories
// first — deliberately not returning early, third-party index.theme files are
// often incomplete — then the fixed size/context patterns), and the same
// preview rule: vectors render at the target size, bitmaps are only ever
// downscaled, never upscaled past what the theme ships.

const c = @import("c_stdlib");

// Shared literal names. Everything read from the environment,
// from an ini file or from a toolkit's config is spelled once here, so the
// functions below carry no bare strings or magic numbers.

// Environment variables, in probe order.
const env_test_extra_dir = "EH_ICON_EXTRA_DIR";
const env_home = "HOME";
const env_xdg_data_home = "XDG_DATA_HOME";
const env_xdg_data_dirs = "XDG_DATA_DIRS";
const env_xdg_config_home = "XDG_CONFIG_HOME";

/// Directory names appended to a base in `icon_base_dirs`.
const k_icons_dir = "icons";
const k_themes_dir = "themes";
/// Home-relative icon roots, in probe order.
const k_home_icon_dirs = [_][]const u8{
    ".icons",
    ".themes",
    ".local/share/icons",
    ".local/share/flatpak/exports/share/icons",
};
/// `XDG_DATA_DIRS` when the variable is unset — the bases the spec names.
const k_default_data_dirs = [_][]const u8{ "/usr/local/share", "/usr/share" };
/// Flatpak export roots probed after the XDG ones.
const k_flatpak_export_icon_dirs = [_][]const u8{
    "/var/lib/flatpak/exports/share/icons",
    "/run/flatpak/exports/share/icons",
};
/// The user config dir component (`XDG_CONFIG_HOME` falls back to this).
const k_dot_config_dir = ".config";

/// The per-theme index file, probed at the theme root and under the nested
/// `icons/` spelling.
const k_index_theme = "index.theme";
/// `read_ini_kv` wants the section as the full bracketed line.
const k_section_icon_theme = "[Icon Theme]";
/// …while the line parser in `read_icon_theme_dirs` sees the header with
/// the brackets already stripped.
const k_icon_theme_header = "Icon Theme";
const k_key_directories = "Directories";
const k_key_scaled_directories = "ScaledDirectories";
const k_key_name = "Name";
const k_key_hidden = "Hidden";
const k_key_example = "Example";

/// Sections and keys `apply_icon_theme` writes into the toolkit files
/// (`update_ini_key` arguments).
const k_section_gtk_settings = "[Settings]";
const k_section_qt_appearance = "[Appearance]";
const k_section_kde_icons = "[Icons]";
const k_key_gtk_icon_theme = "gtk-icon-theme-name";
const k_key_qt_icon_theme = "icon_theme";
const k_key_kde_icon_theme = "Theme";

/// gsettings program, the schema it is asked about, and the one key set.
const k_gsettings_bin = "gsettings";
const k_gsettings_schema = "org.gnome.desktop.interface";
const k_gsettings_key = "icon-theme";

/// File extensions a preview loader probes, in order: vectors first so they
/// render at the requested size (`.svgz` reaches stb uncompressed and fails).
const k_svg_ext = ".svg";
const k_png_ext = ".png";
const k_svgz_ext = ".svgz";
const k_icon_exts = [_][]const u8{ k_svg_ext, k_png_ext, k_svgz_ext };

/// Every ini read in this file stops at this cap; larger `index.theme`
/// files are treated as ending there.
const max_ini_bytes = 1 << 20;
/// Preview render size when the caller does not name one (256).
const k_default_render_px = 256;

/// One environment read, C `getenv` semantics (unset is null; an empty value
/// is still a value).
fn env(key: [:0]const u8) ?[]const u8 {
    const p = c.getenv(key) orelse return null;
    return std.mem.span(p);
}

fn fileReadable(path: []const u8) bool {
    return icon_lookup.isReadable(path);
}

pub const ThemeInfo = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    hidden: bool = false,
};

pub fn freeThemes(alloc: std.mem.Allocator, themes: []ThemeInfo) void {
    for (themes) |t| {
        alloc.free(t.id);
        alloc.free(t.name);
        alloc.free(t.path);
    }
    alloc.free(themes);
}

pub fn freeNames(alloc: std.mem.Allocator, names: [][]const u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

// Bases and index.theme

/// `icon_base_dirs()` — every root icon themes can live under, in probe
/// order.
pub fn iconBaseDirs(alloc: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    // Test hook: hermetic fixture theme directory.
    if (env(env_test_extra_dir)) |extra| try pushUnique(alloc, &out, try alloc.dupe(u8, extra));
    if (env(env_home)) |home| {
        for (k_home_icon_dirs) |rel| {
            try pushUnique(alloc, &out, try std.fs.path.join(alloc, &.{ home, rel }));
        }
    }
    if (env(env_xdg_data_home)) |xdg| {
        try pushUnique(alloc, &out, try std.fs.path.join(alloc, &.{ xdg, k_icons_dir }));
    }
    if (env(env_xdg_data_dirs)) |dirs_s| {
        var it = std.mem.splitScalar(u8, dirs_s, ':');
        while (it.next()) |d| {
            const t = std.mem.trim(u8, d, " \t");
            if (t.len == 0) continue;
            for ([_][]const u8{ k_icons_dir, k_themes_dir }) |sub| {
                try pushUnique(alloc, &out, try std.fs.path.join(alloc, &.{ t, sub }));
            }
        }
    } else {
        for (k_default_data_dirs) |base| {
            for ([_][]const u8{ k_icons_dir, k_themes_dir }) |sub| {
                try pushUnique(alloc, &out, try std.fs.path.join(alloc, &.{ base, sub }));
            }
        }
    }
    for (k_flatpak_export_icon_dirs) |dir| {
        try pushUnique(alloc, &out, try alloc.dupe(u8, dir));
    }
    return out.toOwnedSlice(alloc);
}

/// Append `s` unless an equal string is already present; consumes `s`.
fn pushUnique(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), s: []const u8) !void {
    for (out.items) |e| {
        if (std.mem.eql(u8, e, s)) {
            alloc.free(s);
            return;
        }
    }
    try out.append(alloc, s);
}

/// `read_ini_kv` — the value of `wantKey` inside `wantSection`, or null.
fn readIniKv(alloc: std.mem.Allocator, io: std.Io, path: []const u8, want_section: []const u8, want_key: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, alloc, .limited(max_ini_bytes)) catch return null;
    defer alloc.free(data);
    var in_sec = want_section.len == 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            in_sec = std.mem.eql(u8, line, want_section);
            continue;
        }
        if (!in_sec) continue;
        if (line.len > want_key.len and line[want_key.len] == '=' and
            std.mem.eql(u8, line[0..want_key.len], want_key))
        {
            return alloc.dupe(u8, line[want_key.len + 1 ..]) catch null;
        }
    }
    return null;
}

// detect_system_icon_theme

/// `EH_ICON_THEME` short-circuits every probe.
const env_eh_icon_theme = "EH_ICON_THEME";
/// How long a probe answer is reused — the C++ probe keeps its answer for
/// `kCacheDuration`, so a theme applied by the settings app is seen within
/// seconds without paying a `gsettings` spawn per icon lookup.
const k_detect_ttl_ms: u64 = 5000;
/// Toolkit files probed after gsettings, in order, under the config dir.
const k_detect_gtk_ini = [_][]const u8{ "gtk-4.0/settings.ini", "gtk-3.0/settings.ini" };
/// kdeglobals carries the icon theme under `[Icons] Theme`.
const k_detect_kdeglobals = "kdeglobals";

/// Cached probe answer and the tick it was read at; `detect_valid` tells
/// "no answer" apart from "never probed". The answer allocation is never
/// freed — callers keep the slice (the app drawer stores the theme beside
/// its search path), and a later probe hands out a fresh string instead of
/// reusing one that is still referenced.
var detect_theme: ?[]u8 = null;
var detect_at_ms: u64 = 0;
var detect_valid: bool = false;

fn monoMs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 + @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

/// `detect_system_icon_theme` — the theme the desktop session is set to:
/// the `EH_ICON_THEME` override, then the GNOME interface setting, then the
/// GTK toolkit inis, then kdeglobals. Null when none of them answers, which
/// leaves callers on `hicolor`.
pub fn detectSystemIconTheme(io: std.Io) ?[]const u8 {
    if (env(env_eh_icon_theme)) |v| {
        if (v.len > 0) return v;
    }
    const now = monoMs();
    if (detect_valid and now -% detect_at_ms < k_detect_ttl_ms) return detect_theme;
    detect_valid = true;
    detect_at_ms = now;
    detect_theme = readGsettingsTheme(io) orelse readToolkitTheme(io);
    return detect_theme;
}

/// `gsettings get org.gnome.desktop.interface icon-theme` — the answer comes
/// back quoted; a failed or empty read falls through to the files.
fn readGsettingsTheme(io: std.Io) ?[]u8 {
    const alloc = std.heap.page_allocator;
    const res = std.process.run(alloc, io, .{
        .argv = &.{ k_gsettings_bin, "get", k_gsettings_schema, k_gsettings_key },
    }) catch return null;
    defer alloc.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        alloc.free(res.stdout);
        return null;
    }
    defer alloc.free(res.stdout);
    var v = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (v.len >= 2 and v[0] == '\'' and v[v.len - 1] == '\'') {
        v = std.mem.trim(u8, v[1 .. v.len - 1], " \t\r\n");
    }
    if (v.len == 0) return null;
    return alloc.dupe(u8, v) catch null;
}

/// The toolkit files, in probe order: gtk-4.0 then gtk-3.0
/// `[Settings] gtk-icon-theme-name`, then kdeglobals `[Icons] Theme`.
fn readToolkitTheme(io: std.Io) ?[]u8 {
    const alloc = std.heap.page_allocator;
    const cfg = userConfigDir() orelse return null;
    defer alloc.free(cfg);
    for (k_detect_gtk_ini) |rel| {
        const path = std.fs.path.join(alloc, &.{ cfg, rel }) catch continue;
        defer alloc.free(path);
        const v = readIniKv(alloc, io, path, k_section_gtk_settings, k_key_gtk_icon_theme) orelse continue;
        if (v.len > 0) return v;
        alloc.free(v);
    }
    const path = std.fs.path.join(alloc, &.{ cfg, k_detect_kdeglobals }) catch return null;
    defer alloc.free(path);
    const v = readIniKv(alloc, io, path, k_section_kde_icons, k_key_kde_icon_theme) orelse return null;
    if (v.len > 0) return v;
    alloc.free(v);
    return null;
}

/// True when the file carries an `[Icon Theme]` section at all —
/// themes without one are skipped (KDE splash themes, plain icon drops).
fn hasIconThemeSection(alloc: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, alloc, .limited(max_ini_bytes)) catch return false;
    defer alloc.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), k_section_icon_theme)) return true;
    }
    return false;
}

/// `atoi` — leading integer, 0 when there is none.
fn atoi(s: []const u8) i32 {
    const max: i64 = std.math.maxInt(i32);
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    const start = i;
    var v: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
        if (v > max) break;
    }
    if (i == start) return 0;
    const capped: i32 = @intCast(@min(v, max));
    return if (neg) -capped else capped;
}

fn splitCsv(alloc: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p);
        out.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len == 0) continue;
        try out.append(alloc, try alloc.dupe(u8, t));
    }
    return out.toOwnedSlice(alloc);
}

/// `find_index_theme_path` — `base/<id>/index.theme` then the nested
/// `base/<id>/icons/index.theme` spelling.
fn findIndexPath(alloc: std.mem.Allocator, bases: []const []const u8, theme_id: []const u8) ?[]u8 {
    for (bases) |base| {
        const p = std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ base, theme_id, k_index_theme }) catch continue;
        if (fileReadable(p)) return p;
        alloc.free(p);
        const p2 = std.fmt.allocPrint(alloc, "{s}/{s}/{s}/{s}", .{ base, theme_id, k_icons_dir, k_index_theme }) catch continue;
        if (fileReadable(p2)) return p2;
        alloc.free(p2);
    }
    return null;
}

// Directory listing (theme-declared, best-matching first)

const DirMeta = struct {
    size: i32 = 0,
    scalable: bool = false,
    symbolic: bool = false,
};

/// `read_icon_theme_dirs` — the theme's own `Directories=`/`ScaledDirectories=`
/// entries, ordered symbolic-last, scalable-before-bitmap, then by Size/MaxSize
/// descending.
fn readIconThemeDirs(
    alloc: std.mem.Allocator,
    io: std.Io,
    bases: []const []const u8,
    theme_id: []const u8,
) ![][]const u8 {
    const idx = findIndexPath(alloc, bases, theme_id) orelse return try alloc.alloc([]const u8, 0);
    defer alloc.free(idx);
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, idx, alloc, .limited(max_ini_bytes)) catch return try alloc.alloc([]const u8, 0);
    defer alloc.free(data);

    var dirs: std.ArrayListUnmanaged([]const u8) = .empty; // slices into `data`
    defer dirs.deinit(alloc); // buffer only; the slices belong to `data`
    var meta: std.StringHashMapUnmanaged(DirMeta) = .empty;
    defer meta.deinit(alloc);

    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];

        if (std.mem.eql(u8, section, k_icon_theme_header)) {
            if (std.mem.eql(u8, key, k_key_directories) or std.mem.eql(u8, key, k_key_scaled_directories)) {
                var cit = std.mem.splitScalar(u8, value, ',');
                while (cit.next()) |raw_part| {
                    const part = std.mem.trim(u8, raw_part, " \t");
                    if (part.len == 0) continue;
                    try dirs.append(alloc, part);
                    try meta.put(alloc, part, .{ .symbolic = std.mem.indexOf(u8, part, "symbolic") != null });
                }
            }
            // `Inherits` is parsed here but never consulted for
            // this listing (inheritance belongs to the dock's resolver).
            continue;
        }

        if (meta.getPtr(section)) |m| {
            if (std.mem.eql(u8, key, "Size")) {
                const v = atoi(value);
                if (v > 0) m.size = v;
            } else if (std.mem.eql(u8, key, "Type")) {
                m.scalable = std.mem.eql(u8, value, "Scalable") or std.mem.eql(u8, value, "Threshold");
            } else if (std.mem.eql(u8, key, "MaxSize")) {
                const v = atoi(value);
                if (v > m.size) m.size = v;
            }
        }
    }

    std.mem.sort([]const u8, dirs.items, &meta, metaLess);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |d| alloc.free(d);
        out.deinit(alloc);
    }
    for (dirs.items) |d| {
        var dup = false;
        for (out.items) |e| {
            if (std.mem.eql(u8, e, d)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        try out.append(alloc, try alloc.dupe(u8, d));
    }
    return out.toOwnedSlice(alloc);
}

/// Stable-sort comparator: symbolic dirs last, scalable before
/// bitmap, then the declared size descending.
fn metaLess(ctx: *const std.StringHashMapUnmanaged(DirMeta), a: []const u8, b: []const u8) bool {
    const da = ctx.get(a) orelse DirMeta{};
    const db = ctx.get(b) orelse DirMeta{};
    if (da.symbolic != db.symbolic) return !da.symbolic;
    if (da.scalable != db.scalable) return da.scalable;
    return da.size > db.size;
}

const k_ctx = [_][]const u8{
    "apps",       "actions",    "status",   "devices",  "places",   "categories",
    "emblems",    "preferences", "mimetypes", "mimes",  "panel",    "legacy",
    "emotes",     "animations", "logos",
};
const k_sizes = [_][]const u8{
    "scalable", "symbolic", "512x512", "256x256", "128x128", "96x96",
    "64x64",    "48x48",    "32x32",   "24x24",   "22x22",   "16x16",
};
/// Root-level app directories probed after the theme's own ones.
const k_root_app_dirs = [_][]const u8{
    "/scalable/apps/", "/256x256/apps/", "/128x128/apps/",
    "/64x64/apps/",    "/48x48/apps/",   "/32x32/apps/",
};

/// `append_theme_search_dirs` — every directory one icon can hide in for
/// this theme, theme-declared ones first. The fixed patterns follow even
/// when the index.theme listed directories: many third-party themes have
/// incomplete or misleading indexes.
fn appendThemeSearchDirs(
    out: *std.ArrayListUnmanaged([]const u8),
    alloc: std.mem.Allocator,
    io: std.Io,
    theme_root: []const u8,
    theme_id: []const u8,
    bases: []const []const u8,
) !void {
    const dirs = try readIconThemeDirs(alloc, io, bases, theme_id);
    defer freeNames(alloc, dirs);
    for (dirs) |d| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}/", .{ theme_root, d }));
    }

    for (k_root_app_dirs) |p| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s}", .{ theme_root, p }));
    }
    for (k_sizes) |sz| {
        for (k_ctx) |ctx| {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}/{s}/", .{ theme_root, sz, ctx }));
        }
    }
    for (k_ctx) |ctx_name| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}/", .{ theme_root, ctx_name }));
    }
}

// The five entry points

/// `list_installed_icon_themes()` — every installed theme with a real
/// `[Icon Theme]` index, sorted by display name.
pub fn listInstalledThemes(alloc: std.mem.Allocator, io: std.Io) ![]ThemeInfo {
    const bases = try iconBaseDirs(alloc);
    defer {
        for (bases) |b| alloc.free(b);
        alloc.free(bases);
    }
    return listInstalledThemesIn(alloc, io, bases);
}

/// Hermetic core of `listInstalledThemes` (explicit bases).
pub fn listInstalledThemesIn(alloc: std.mem.Allocator, io: std.Io, bases: []const []const u8) ![]ThemeInfo {
    var by_id: std.StringHashMapUnmanaged(ThemeInfo) = .empty;
    errdefer {
        var it = by_id.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.name);
            alloc.free(e.value_ptr.path);
        }
        by_id.deinit(alloc);
    }

    const cwd = std.Io.Dir.cwd();
    for (bases) |base| {
        var d = cwd.openDir(io, base, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |ent| {
            const id = ent.name;
            if (id.len == 0 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) continue;

            // `<base>/<id>/index.theme`, else the nested `icons/` spelling.
            const flat = std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ base, id, k_index_theme }) catch continue;
            const nested = std.fmt.allocPrint(alloc, "{s}/{s}/{s}/{s}", .{ base, id, k_icons_dir, k_index_theme }) catch {
                alloc.free(flat);
                continue;
            };
            const use_flat = fileReadable(flat);
            if (use_flat) {
                alloc.free(nested);
            } else {
                alloc.free(flat);
                if (!fileReadable(nested)) {
                    alloc.free(nested);
                    continue;
                }
            }
            const idx = if (use_flat) flat else nested;
            defer alloc.free(idx);

            if (by_id.contains(id)) continue;
            if (!hasIconThemeSection(alloc, io, idx)) continue;
            {
                const dirs = readIniKv(alloc, io, idx, k_section_icon_theme, k_key_directories);
                if (dirs) |v| alloc.free(v);
                const sdirs = readIniKv(alloc, io, idx, k_section_icon_theme, k_key_scaled_directories);
                if (sdirs) |v| alloc.free(v);
                if ((dirs == null or dirs.?.len == 0) and (sdirs == null or sdirs.?.len == 0)) continue;
            }

            const name = readIniKv(alloc, io, idx, k_section_icon_theme, k_key_name) orelse alloc.dupe(u8, id) catch {
                continue;
            };
            errdefer alloc.free(name);
            var hidden = false;
            if (readIniKv(alloc, io, idx, k_section_icon_theme, k_key_hidden)) |hid| {
                defer alloc.free(hid);
                if (hid.len > 0) {
                    const ch = hid[0];
                    hidden = ch == '1' or ch == 't' or ch == 'T' or ch == 'y' or ch == 'Y';
                }
            }
            const key = alloc.dupe(u8, id) catch {
                alloc.free(name);
                continue;
            };
            errdefer alloc.free(key);
            // The theme path goes last: its only failure exit is an OOM
            // below, which the errdefer covers (the `catch` frees by hand
            // because `continue` does not run errdefers).
            const p = if (use_flat)
                std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, id })
            else
                std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ base, id, k_icons_dir });
            const path = p catch {
                alloc.free(key);
                alloc.free(name);
                continue;
            };
            errdefer alloc.free(path);
            try by_id.put(alloc, key, .{ .id = key, .name = name, .path = path, .hidden = hidden });
        }
    }

    var list = try alloc.alloc(ThemeInfo, by_id.count());
    {
        var i: usize = 0;
        var it = by_id.valueIterator();
        while (it.next()) |v| {
            list[i] = v.*;
            i += 1;
        }
    }
    by_id.deinit(alloc); // keys live on in `ThemeInfo.id`
    std.mem.sort(ThemeInfo, list, {}, lessByName);
    return list;
}

fn lessByName(_: void, a: ThemeInfo, b: ThemeInfo) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// `theme_example_icon_name` — the `[Icon Theme] Example=` preview hint.
pub fn themeExampleIconName(alloc: std.mem.Allocator, io: std.Io, theme_dir: []const u8) ?[]u8 {
    const idx = std.fmt.allocPrint(alloc, "{s}/{s}", .{ theme_dir, k_index_theme }) catch return null;
    defer alloc.free(idx);
    return readIniKv(alloc, io, idx, k_section_icon_theme, k_key_example);
}

/// Directories scanned when the theme's own index declares nothing useful
/// (the inline ladder), relative to the theme
/// root. `theme_find_any_icons`' index-declared directories come first.
const k_fallback_scan_dirs = [_][]const u8{
    "scalable/apps/",     "scalable/places/",   "scalable/devices/",  "scalable/actions/",
    "scalable/mimetypes/", "scalable/status/",
    "48x48/apps/",        "48x48/places/",      "48x48/devices/",
    "32x32/apps/",        "32x32/places/",      "32x32/devices/",
    "16x16/apps/",        "16x16/places/",      "16x16/devices/",
    "places/scalable/",   "places/48/",         "places/32/",         "places/16/",
    "devices/scalable/",  "devices/48/",        "devices/32/",        "devices/16/",
    "mimes/scalable/",    "mimes/16/",
};

/// `theme_find_any_icons` — up to `max_count` icon names found in the theme's
/// own directories, for themes too old or too sloppy to declare an Example.
pub fn themeFindAnyIcons(alloc: std.mem.Allocator, io: std.Io, theme_dir: []const u8, max_count: usize) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |n| alloc.free(n);
        out.deinit(alloc);
    }

    const idx = std.fmt.allocPrint(alloc, "{s}/{s}", .{ theme_dir, k_index_theme }) catch return out.toOwnedSlice(alloc);
    defer alloc.free(idx);
    if (!fileReadable(idx)) return out.toOwnedSlice(alloc);

    var scan_dirs: std.ArrayList([]const u8) = .empty;
    defer {
        // Owned strings, not the file-data slices: free them explicitly
        // (`deinit` only drops the list buffer).
        for (scan_dirs.items) |p| alloc.free(p);
        scan_dirs.deinit(alloc);
    }
    if (readIniKv(alloc, io, idx, k_section_icon_theme, k_key_directories)) |dirs_all| {
        defer alloc.free(dirs_all);
        var cit = std.mem.splitScalar(u8, dirs_all, ',');
        while (cit.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t");
            if (part.len == 0) continue;
            const p = std.fmt.allocPrint(alloc, "{s}/{s}/", .{ theme_dir, part }) catch continue;
            scan_dirs.append(alloc, p) catch {
                alloc.free(p);
                break;
            };
        }
    }
    for (k_fallback_scan_dirs) |rel| {
        const p = std.fmt.allocPrint(alloc, "{s}/{s}", .{ theme_dir, rel }) catch continue;
        scan_dirs.append(alloc, p) catch {
            alloc.free(p);
            break;
        };
    }

    const cwd = std.Io.Dir.cwd();
    outer: for (scan_dirs.items) |sd| {
        var d = cwd.openDir(io, sd, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |ent| {
            if (out.items.len >= max_count) break :outer;
            const nm = ent.name;
            if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
            const dot = std.mem.lastIndexOfScalar(u8, nm, '.') orelse continue;
            const ext = nm[dot..];
            var is_icon_ext = false;
            for (k_icon_exts) |known| {
                if (std.mem.eql(u8, ext, known)) {
                    is_icon_ext = true;
                    break;
                }
            }
            if (!is_icon_ext) continue;
            const base = nm[0..dot];
            if (base.len == 0) continue;
            var dup = false;
            for (out.items) |e| {
                if (std.mem.eql(u8, e, base)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            const owned = alloc.dupe(u8, base) catch break;
            out.append(alloc, owned) catch {
                alloc.free(owned);
                break;
            };
        }
    }
    return out.toOwnedSlice(alloc);
}

/// `load_theme_preview_icon` — a self-contained cairo surface with this icon
/// rendered from `theme_dir` at (at most) `target_px`, or null.
pub fn loadThemePreviewIcon(
    alloc: std.mem.Allocator,
    io: std.Io,
    theme_dir: []const u8,
    icon_name: []const u8,
    target_px: i32,
) ?*cairo.cairo_surface_t {
    const bases = iconBaseDirs(alloc) catch return null;
    defer {
        for (bases) |b| alloc.free(b);
        alloc.free(bases);
    }
    return loadThemePreviewIconIn(alloc, io, bases, theme_dir, icon_name, target_px);
}

/// Hermetic core of `loadThemePreviewIcon` (explicit bases).
pub fn loadThemePreviewIconIn(
    alloc: std.mem.Allocator,
    io: std.Io,
    bases: []const []const u8,
    theme_dir: []const u8,
    icon_name: []const u8,
    target_px: i32,
) ?*cairo.cairo_surface_t {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const theme_id = std.mem.lastIndexOfScalar(u8, theme_dir, '/') orelse 0;
    const id = if (theme_id > 0) theme_dir[theme_id + 1 ..] else theme_dir;

    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    appendThemeSearchDirs(&dirs, a, io, theme_dir, id, bases) catch return null;

    outer: for (dirs.items) |sd| {
        // One pass over the (possibly repeated) directory list: a duplicated
        // path can't hold a file the first visit missed.
        for (k_icon_exts) |ext| {
            const fp = std.fmt.allocPrint(a, "{s}{s}{s}", .{ sd, icon_name, ext }) catch continue;
            if (!fileReadable(fp)) continue;
            const want_px = if (target_px > 0) target_px else k_default_render_px;
            var px = if (std.mem.eql(u8, ext, k_svg_ext))
                icon_raster.loadSvg(a, fp, want_px)
            else
                icon_raster.loadPng(a, fp);
            if (px) |*p| {
                if (target_px > 0 and (p.w > target_px or p.h > target_px)) {
                    // Never upscale past what the theme ships; downscale
                    // through cairo and keep the original when that fails.
                    const surf = pixelsToSurface(p.*) orelse break :outer;
                    const scaled = scaleSurfaceDown(surf, target_px);
                    if (scaled) |s| return s;
                    return surf;
                }
                return pixelsToSurface(p.*);
            }
            // Load failed: keep looking.
        }
    }
    return null;
}

/// Copy `Pixels` (already premultiplied cairo BGRA) into a cairo-owned
/// ARGB32 surface so the cache can outlive the decode buffer.
fn pixelsToSurface(p: icon_raster.Pixels) ?*cairo.cairo_surface_t {
    if (p.w <= 0 or p.h <= 0) return null;
    const expect: usize = @as(usize, @intCast(p.w)) * @as(usize, @intCast(p.h)) * 4;
    if (p.data.len < expect) return null;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, p.w, p.h);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const dst: [*]u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    @memcpy(dst[0..expect], p.data[0..expect]);
    // Direct buffer write: `mark_dirty`, not `flush` — without it cairo
    // keeps serving the blank snapshot taken at creation, so every paint
    // from this surface deposits nothing (exactly the empty-cards bug).
    cairo.cairo_surface_mark_dirty(surf);
    return surf;
}

/// Downscale to fit `target_px` on the longest side
/// resize block). Returns null when the caller should keep the original.
fn scaleSurfaceDown(surf: *cairo.cairo_surface_t, target_px: i32) ?*cairo.cairo_surface_t {
    const w = cairo.cairo_image_surface_get_width(surf);
    const h = cairo.cairo_image_surface_get_height(surf);
    if (w <= 0 or h <= 0) return null;
    if (w <= target_px and h <= target_px) return null;
    const sc = @as(f64, @floatFromInt(target_px)) / @as(f64, @floatFromInt(@max(w, h)));
    const dw: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * sc))));
    const dh: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * sc))));
    const scaled = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, dw, dh);
    if (cairo.cairo_surface_status(scaled) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(scaled);
        return null;
    }
    const cr = cairo.cairo_create(scaled);
    cairo.cairo_scale(cr, sc, sc);
    cairo.cairo_set_source_surface(cr, surf, 0, 0);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_paint(cr);
    cairo.cairo_destroy(cr);
    cairo.cairo_surface_destroy(surf);
    return scaled;
}

// apply_icon_theme

/// Toolkit settings files `apply_icon_theme` rewrites, relative to the user
/// config dir (five `update_ini_key` ports).
const k_toolkit_ini = [_]struct { rel: []const u8, section: []const u8, key: []const u8 }{
    .{ .rel = "gtk-4.0/settings.ini", .section = k_section_gtk_settings, .key = k_key_gtk_icon_theme },
    .{ .rel = "gtk-3.0/settings.ini", .section = k_section_gtk_settings, .key = k_key_gtk_icon_theme },
    .{ .rel = "qt6ct/qt6ct.conf", .section = k_section_qt_appearance, .key = k_key_qt_icon_theme },
    .{ .rel = "qt5ct/qt5ct.conf", .section = k_section_qt_appearance, .key = k_key_qt_icon_theme },
    .{ .rel = "kdeglobals", .section = k_section_kde_icons, .key = k_key_kde_icon_theme },
};

/// The user's config dir: `XDG_CONFIG_HOME` when set (and non-empty), else
/// `<home>/.config` — so a relocated config gets the toolkit writes too.
/// Owned by `page_allocator`.
fn userConfigDir() ?[]u8 {
    const alloc = std.heap.page_allocator;
    if (env(env_xdg_config_home)) |xdg| {
        if (xdg.len > 0) return alloc.dupe(u8, xdg) catch null;
    }
    const home = env(env_home) orelse return null;
    return std.fs.path.join(alloc, &.{ home, k_dot_config_dir }) catch null;
}

/// `apply_icon_theme` — set the GNOME interface theme through gsettings and
/// write the toolkit settings files (gtk3/4, qt5ct/qt6ct, kdeglobals).
pub fn applyIconTheme(io: std.Io, theme_id: []const u8) void {
    if (theme_id.len == 0) return;
    if (std.process.spawn(io, .{
        .argv = &.{ k_gsettings_bin, "set", k_gsettings_schema, k_gsettings_key, theme_id },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    })) |sc| {
        var child = sc;
        _ = child.wait(io) catch {};
    } else |_| {
        // Missing or broken gsettings: the ini writes below still run — the
        // This failure is ignored too.
    }

    const cfg = userConfigDir() orelse return;
    defer std.heap.page_allocator.free(cfg);
    for (k_toolkit_ini) |t| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const path = std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ cfg, t.rel }) catch continue;
        var farena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer farena.deinit();
        const value = farena.allocator().dupe(u8, theme_id) catch continue;
        updateIniKey(io, path, t.section, t.key, value) catch {};
    }
}

/// INI key update — set
/// `key=value` inside `section`, replacing the first existing occurrence and
/// preserving every other line; appends the section when missing.
pub fn updateIniKey(io: std.Io, path: []const u8, section: []const u8, key: []const u8, value: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Missing file reads as empty.
    const existing = cwd.readFileAlloc(io, path, alloc, .limited(max_ini_bytes)) catch "";
    var out: std.ArrayListUnmanaged(u8) = .empty;

    var found_section = false;
    var wrote_key = false;
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and line[0] == '[') {
            // A new section closes the previous one without its key.
            if (found_section and !wrote_key) {
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}={s}\n", .{ key, value }));
                wrote_key = true;
            }
            found_section = std.mem.indexOf(u8, line, section) != null;
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
        } else if (found_section) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const existing_key = std.mem.trimEnd(u8, line[0..eq], " \t");
                if (std.mem.eql(u8, existing_key, key)) {
                    if (!wrote_key) {
                        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}={s}\n", .{ key, value }));
                        wrote_key = true;
                    }
                    continue;
                }
            }
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
        } else {
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
        }
    }
    if (found_section and !wrote_key) {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s}={s}\n", .{ key, value }));
    }
    if (!found_section) {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\n{s}\n{s}={s}\n", .{ section, key, value }));
    }

    try cwd.writeFile(io, .{ .sub_path = path, .data = out.items });
}

// Tests

const testing = std.testing;

fn testDir(sub: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{sub});
}

test "icon-themes: readIniKv honours section and key" {
    const alloc = testing.allocator;
    const io = testing.io;
    const dir = try testDir("eh-it-ini");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, k_index_theme });
    defer alloc.free(path);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteDir(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data =
        \\# a comment
        \\[Icon Theme]
        \\Name= Papirus
        \\Directories=48x48/apps
        \\
        \\[Desktop Entry]
        \\Name=Not the icon name
        \\
    });
    const name = readIniKv(alloc, io, path, k_section_icon_theme, k_key_name).?;
    defer alloc.free(name);
    try testing.expectEqualStrings(" Papirus", name); // post-= spacing kept
    const dirs = readIniKv(alloc, io, path, k_section_icon_theme, k_key_directories).?;
    defer alloc.free(dirs);
    try testing.expectEqualStrings("48x48/apps", dirs);
    try testing.expect(readIniKv(alloc, io, path, k_section_icon_theme, k_key_example) == null);
    try testing.expect(readIniKv(alloc, io, path, "[Nope]", k_key_name) == null);
    try testing.expect(readIniKv(alloc, io, "/nonexistent/index.theme", k_section_icon_theme, k_key_name) == null);
}

test "icon-themes: listInstalledThemesIn validates and sorts" {
    const alloc = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = try testDir("eh-it-list");
    defer alloc.free(root);
    const base = try std.fs.path.join(alloc, &.{ root, "icons" });
    defer alloc.free(base);

    const th_a = try std.fs.path.join(alloc, &.{ base, "ThemeA" });
    defer alloc.free(th_a);
    const th_a_idx = try std.fs.path.join(alloc, &.{ th_a, k_index_theme });
    defer alloc.free(th_a_idx);
    const th_b = try std.fs.path.join(alloc, &.{ base, "ThemeB", "icons" });
    defer alloc.free(th_b);
    const th_b_idx = try std.fs.path.join(alloc, &.{ th_b, k_index_theme });
    defer alloc.free(th_b_idx);
    const th_c = try std.fs.path.join(alloc, &.{ base, "NotAnIconTheme" });
    defer alloc.free(th_c);
    const th_c_idx = try std.fs.path.join(alloc, &.{ th_c, k_index_theme });
    defer alloc.free(th_c_idx);
    const th_d = try std.fs.path.join(alloc, &.{ base, "NoDirs" });
    defer alloc.free(th_d);
    const th_d_idx = try std.fs.path.join(alloc, &.{ th_d, k_index_theme });
    defer alloc.free(th_d_idx);

    try cwd.createDirPath(io, th_a);
    try cwd.createDirPath(io, th_b);
    try cwd.createDirPath(io, th_c);
    try cwd.createDirPath(io, th_d);
    defer {
        cwd.deleteDir(io, th_a) catch {};
        cwd.deleteDir(io, th_b) catch {};
        cwd.deleteDir(io, th_c) catch {};
        cwd.deleteDir(io, th_d) catch {};
        cwd.deleteDir(io, base) catch {};
        cwd.deleteDir(io, root) catch {};
    }

    try cwd.writeFile(io, .{ .sub_path = th_a_idx, .data =
        \\[Icon Theme]
        \\Name=Zebra Pack
        \\Directories=48x48/apps
        \\
    });
    // Nested `icons/` spelling, and a display name that sorts before ThemeA.
    try cwd.writeFile(io, .{ .sub_path = th_b_idx, .data =
        \\[Icon Theme]
        \\Name=Alpha Pack
        \\Directories=48x48/apps
        \\Hidden=1
        \\
    });
    try cwd.writeFile(io, .{ .sub_path = th_c_idx, .data =
        \\[Desktop Entry]
        \\Name=A splash theme, not an icon theme
        \\
    });
    try cwd.writeFile(io, .{ .sub_path = th_d_idx, .data =
        \\[Icon Theme]
        \\Name=No Dirs
        \\
    });

    const bases = [_][]const u8{base};
    const themes = try listInstalledThemesIn(alloc, io, &bases);
    defer freeThemes(alloc, themes);
    try testing.expectEqual(@as(usize, 2), themes.len);
    // Sorted by display name: Alpha (ThemeB, nested path, hidden) first.
    try testing.expectEqualStrings("ThemeB", themes[0].id);
    try testing.expectEqualStrings("Alpha Pack", themes[0].name);
    try testing.expectEqualStrings(th_b, themes[0].path);
    try testing.expect(themes[0].hidden);
    try testing.expectEqualStrings("ThemeA", themes[1].id);
    try testing.expectEqualStrings("Zebra Pack", themes[1].name);
    try testing.expectEqualStrings(th_a, themes[1].path);
    try testing.expect(!themes[1].hidden);
}

test "icon-themes: example, find-any-icons and preview loading" {
    const alloc = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = try testDir("eh-it-prev");
    defer alloc.free(root);
    const base = try std.fs.path.join(alloc, &.{ root, "icons" });
    defer alloc.free(base);
    const theme = try std.fs.path.join(alloc, &.{ base, "PrevTheme" });
    defer alloc.free(theme);
    const idx = try std.fs.path.join(alloc, &.{ theme, k_index_theme });
    defer alloc.free(idx);
    const apps = try std.fs.path.join(alloc, &.{ theme, "48x48", "apps" });
    defer alloc.free(apps);

    try cwd.createDirPath(io, apps);
    const size48 = try std.fs.path.join(alloc, &.{ theme, "48x48" });
    defer alloc.free(size48);
    defer {
        cwd.deleteDir(io, apps) catch {};
        cwd.deleteDir(io, size48) catch {};
        cwd.deleteDir(io, theme) catch {};
        cwd.deleteDir(io, base) catch {};
        cwd.deleteDir(io, root) catch {};
    }
    try cwd.writeFile(io, .{ .sub_path = idx, .data =
        \\[Icon Theme]
        \\Name=Prev
        \\Directories=48x48/apps
        \\Example=myapp
        \\
    });
    const svg = try std.fs.path.join(alloc, &.{ apps, "myapp" ++ k_svg_ext });
    defer alloc.free(svg);
    try cwd.writeFile(io, .{ .sub_path = svg, .data =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48"><rect width="48" height="48" fill="#ff0000"/></svg>
        \\
    });
    const loose = try std.fs.path.join(alloc, &.{ apps, "loose.png" });
    defer alloc.free(loose);
    try cwd.writeFile(io, .{ .sub_path = loose, .data = "not really a png" });

    const example = themeExampleIconName(alloc, io, theme).?;
    defer alloc.free(example);
    try testing.expectEqualStrings("myapp", example);

    const any = try themeFindAnyIcons(alloc, io, theme, 8);
    defer freeNames(alloc, any);
    try testing.expectEqual(@as(usize, 2), any.len);
    try testing.expectEqualStrings("myapp", any[0]);
    try testing.expectEqualStrings("loose", any[1]); // listed, not decoded

    const bases = [_][]const u8{base};
    // Vector renders at the requested size.
    const surf = loadThemePreviewIconIn(alloc, io, &bases, theme, "myapp", 56).?;
    defer cairo.cairo_surface_destroy(surf);
    try testing.expectEqual(@as(i32, 56), cairo.cairo_image_surface_get_width(surf));
    try testing.expectEqual(@as(i32, 56), cairo.cairo_image_surface_get_height(surf));
    // The surface must actually deposit pixels when painted from (regression
    // test: copying pixels into the buffer without `mark_dirty` leaves cairo
    // serving the blank creation snapshot, i.e. empty preview cards).
    {
        const dst = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
        defer cairo.cairo_surface_destroy(dst);
        const cr = cairo.cairo_create(dst);
        defer cairo.cairo_destroy(cr);
        cairo.cairo_set_source_surface(cr, surf, 4, 4);
        cairo.cairo_paint(cr);
        cairo.cairo_surface_flush(dst);
        const stride: usize = @intCast(cairo.cairo_image_surface_get_stride(dst));
        const data: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(dst));
        var red: usize = 0;
        var y: usize = 0;
        while (y < 64) : (y += 1) {
            var x: usize = 0;
            while (x < 64) : (x += 1) {
                const off = y * stride + x * 4;
                // Opaque red rect: R high, B/G low, alpha set.
                if (data[off + 3] != 0 and data[off + 2] > 200 and data[off] < 55 and data[off + 1] < 55) red += 1;
            }
        }
        try testing.expect(red > 1000);
    }
    // A missing icon is a miss, not a fallback.
    try testing.expect(loadThemePreviewIconIn(alloc, io, &bases, theme, "definitely-not-here", 56) == null);
}

test "icon-themes: updateIniKey replaces in place and preserves the rest" {
    const alloc = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = try testDir("eh-it-iniupd");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "settings.ini" });
    defer alloc.free(path);
    try cwd.createDirPath(io, dir);
    defer cwd.deleteDir(io, dir) catch {};
    try cwd.writeFile(io, .{ .sub_path = path, .data =
        \\[Settings]
        \\gtk-theme-name=Adwaita-dark
        \\gtk-icon-theme-name=Old
        \\gtk-font-name=Inter 11
        \\
        \\[Other]
        \\keep=me
        \\
    });

    try updateIniKey(io, path, k_section_gtk_settings, k_key_gtk_icon_theme, "Papirus");
    const after = try cwd.readFileAlloc(io, path, alloc, .limited(1 << 16));
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "gtk-icon-theme-name=Papirus") != null);
    try testing.expect(std.mem.indexOf(u8, after, "gtk-icon-theme-name=Old") == null);
    try testing.expect(std.mem.indexOf(u8, after, "gtk-theme-name=Adwaita-dark") != null);
    try testing.expect(std.mem.indexOf(u8, after, "gtk-font-name=Inter 11") != null);
    try testing.expect(std.mem.indexOf(u8, after, "[Other]") != null);
    try testing.expect(std.mem.indexOf(u8, after, "keep=me") != null);

    // A file without the section gains it once, at the end.
    const path2 = try std.fs.path.join(alloc, &.{ dir, "kdeglobals" });
    defer alloc.free(path2);
    try updateIniKey(io, path2, k_section_kde_icons, k_key_kde_icon_theme, "Tela");
    try updateIniKey(io, path2, k_section_kde_icons, k_key_kde_icon_theme, "Numix");
    const after2 = try cwd.readFileAlloc(io, path2, alloc, .limited(1 << 16));
    defer alloc.free(after2);
    try testing.expect(std.mem.indexOf(u8, after2, "[Icons]") != null);
    try testing.expect(std.mem.indexOf(u8, after2, "Theme=Numix") != null);
    try testing.expect(std.mem.indexOf(u8, after2, "Theme=Tela") == null);
    try testing.expect(std.mem.indexOf(u8, after2, "[Icons]\nTheme=Numix") != null or
        std.mem.indexOf(u8, after2, "[Icons]\r\nTheme=Numix") != null);
}
