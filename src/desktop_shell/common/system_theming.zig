const std = @import("std");
const c = @import("c_stdlib");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const icon_lookup = @import("icon_lookup.zig");
const icon_themes = @import("icon_themes.zig");

// System theming service — the GTK / Qt / cursor / Plasma port of
// `desktop_shell/common/system_theming/` from the C++ tree.
//
// The settings app's Themes page grids over these lists, previews each theme
// by reading the toolkit's own files, and pushes an Apply out to the desktop
// session. Everything is file-based and best-effort: a missing toolkit, a
// malformed theme or a compositor without the setter tool simply degrades
// (empty list / no preview / no-op apply), never crashes.

const max_ini_bytes = 1 << 20;
const max_css_bytes = 8 << 20;
const max_cursor_bytes = 4 << 20;

const env_home = "HOME";
const env_xdg_config_home = "XDG_CONFIG_HOME";
const env_xdg_data_home = "XDG_DATA_HOME";
const env_xdg_data_dirs = "XDG_DATA_DIRS";
const env_hyprland = "HYPRLAND_INSTANCE_SIGNATURE";
const env_sway = "SWAYSOCK";

const k_default_data_dirs = [_][]const u8{ "/usr/local/share", "/usr/share" };

fn env(key: [:0]const u8) ?[]const u8 {
    const p = c.getenv(key) orelse return null;
    return std.mem.span(p);
}

fn readable(path: []const u8) bool {
    return icon_lookup.isReadable(path);
}

/// The user's config dir: `XDG_CONFIG_HOME` when set, else `<home>/.config`.
fn userConfigDir(alloc: std.mem.Allocator) ?[]u8 {
    if (env(env_xdg_config_home)) |xdg| {
        if (xdg.len > 0) return alloc.dupe(u8, xdg) catch null;
    }
    const home = env(env_home) orelse return null;
    return std.fs.path.join(alloc, &.{ home, ".config" }) catch null;
}

fn readIniKv(alloc: std.mem.Allocator, io: std.Io, path: []const u8, want_section: []const u8, want_key: []const u8) ?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_ini_bytes)) catch return null;
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

fn updateIniKey(io: std.Io, path: []const u8, section: []const u8, key: []const u8, value: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_ini_bytes)) catch "";
    var out: std.ArrayListUnmanaged(u8) = .empty;

    var found_section = false;
    var wrote_key = false;
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and line[0] == '[') {
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) void {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
}

fn runCmd(io: std.Io, argv: []const []const u8) void {
    if (std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    })) |sc| {
        var child = sc;
        _ = child.wait(io) catch {};
    } else |_| {}
}

fn runCapture(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]u8 {
    const res = std.process.run(alloc, io, .{ .argv = argv }) catch return null;
    defer alloc.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        alloc.free(res.stdout);
        return null;
    }
    return res.stdout;
}

// ------------------------------------------------------------------ types --

pub const ThemeInfo = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
};

pub fn freeThemes(alloc: std.mem.Allocator, list: []ThemeInfo) void {
    for (list) |t| {
        alloc.free(t.id);
        alloc.free(t.name);
        alloc.free(t.path);
    }
    alloc.free(list);
}

pub fn freeNames(alloc: std.mem.Allocator, list: [][]const u8) void {
    for (list) |n| alloc.free(n);
    alloc.free(list);
}

/// The subset of the palette a preview needs. Values are normalized 0..1;
/// defaults are the light fallback the C++ preview starts from.
pub const Colors = struct {
    bg: [3]f64 = .{ 1, 1, 1 },
    fg: [3]f64 = .{ 0, 0, 0 },
    accent: [3]f64 = .{ 0.2, 0.5, 0.9 },
    base: [3]f64 = .{ 1, 1, 1 },
    text: [3]f64 = .{ 0, 0, 0 },
    header_bg: [3]f64 = .{ 0.9, 0.9, 0.9 },
    header_fg: [3]f64 = .{ 0, 0, 0 },
    valid: bool = false,

    pub fn setHeaderFromBg(self: *Colors) void {
        self.header_bg = .{ self.bg[0] * 0.92, self.bg[1] * 0.92, self.bg[2] * 0.92 };
    }
};

pub const Design = struct {
    window_rad: f64 = 6,
    button_rad: f64 = 3,
    entry_rad: f64 = 2,
    titlebar_h: i32 = 16,
    border_w: i32 = 1,
    valid: bool = false,
};

// ------------------------------------------------------------------- XDG --

/// Roots themes can live under. Icon bases cover `.themes` and the system
/// data dirs, but `~/.local/share/themes` / `$XDG_DATA_HOME/themes` need
/// adding explicitly because the icon probe only appends `icons/` there.
pub fn themeBaseDirs(alloc: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    if (icon_themes.iconBaseDirs(alloc)) |bases| {
        defer {
            for (bases) |b| alloc.free(b);
            alloc.free(bases);
        }
        for (bases) |b| {
            const d = alloc.dupe(u8, b) catch continue;
            try pushThemeBase(alloc, &out, d);
        }
    } else |_| {}
    if (env(env_home)) |home| {
        for ([_][]const u8{ ".themes", ".local/share/themes" }) |rel| {
            const p = std.fs.path.join(alloc, &.{ home, rel }) catch continue;
            try pushThemeBase(alloc, &out, p);
        }
    }
    if (env(env_xdg_data_home)) |xdg| {
        const p = std.fs.path.join(alloc, &.{ xdg, "themes" }) catch null;
        if (p) |pp| try pushThemeBase(alloc, &out, pp);
    }
    return out.toOwnedSlice(alloc);
}

fn pushThemeBase(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), s: []const u8) !void {
    for (out.items) |e| {
        if (std.mem.eql(u8, e, s)) {
            alloc.free(s);
            return;
        }
    }
    try out.append(alloc, s);
}

fn freeBases(alloc: std.mem.Allocator, bases: [][]const u8) void {
    for (bases) |b| alloc.free(b);
    alloc.free(bases);
}

fn pushInfo(alloc: std.mem.Allocator, list: *std.ArrayList(ThemeInfo), base: []const u8, id: []const u8, name: []const u8) !void {
    const id_d = try alloc.dupe(u8, id);
    errdefer alloc.free(id_d);
    const name_d = try alloc.dupe(u8, name);
    errdefer alloc.free(name_d);
    const path_d = try std.fs.path.join(alloc, &.{ base, id });
    try list.append(alloc, .{ .id = id_d, .name = name_d, .path = path_d });
}

fn hasById(list: []const ThemeInfo, id: []const u8) bool {
    for (list) |t| if (std.mem.eql(u8, t.id, id)) return true;
    return false;
}

fn sortThemes(list: []ThemeInfo) void {
    std.mem.sort(ThemeInfo, list, {}, struct {
        fn less(_: void, a: ThemeInfo, b: ThemeInfo) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
}

// ------------------------------------------------------------------- GTK --

fn gtkDirHasCss(io: std.Io, dir: []const u8) bool {
    var buf: [4096]u8 = undefined;
    for ([_][]const u8{ "/gtk-3.0/gtk.css", "/gtk-4.0/gtk.css" }) |rel| {
        const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ dir, rel }) catch continue;
        if (readable(p)) return true;
    }
    _ = io;
    return false;
}

pub fn listGtkThemes(alloc: std.mem.Allocator, io: std.Io) ![]ThemeInfo {
    const bases = themeBaseDirs(alloc) catch return try alloc.alloc(ThemeInfo, 0);
    defer freeBases(alloc, bases);
    var list: std.ArrayList(ThemeInfo) = .empty;
    errdefer {
        for (list.items) |t| {
            alloc.free(t.id);
            alloc.free(t.name);
            alloc.free(t.path);
        }
        list.deinit(alloc);
    }
    const cwd = std.Io.Dir.cwd();
    for (bases) |base| {
        var d = cwd.openDir(io, base, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |ent| {
            if (ent.kind != .directory and ent.kind != .unknown) continue;
            const id = ent.name;
            if (id.len == 0 or id[0] == '.') continue;
            if (hasById(list.items, id)) continue;
            const dir = std.fs.path.join(alloc, &.{ base, id }) catch continue;
            defer alloc.free(dir);
            if (!gtkDirHasCss(io, dir)) continue;
            var name: []u8 = &.{};
            const idx = std.fs.path.join(alloc, &.{ dir, "index.theme" }) catch continue;
            defer alloc.free(idx);
            if (readIniKv(alloc, io, idx, "[Desktop Entry]", "Name")) |n| {
                name = n;
            } else {
                name = alloc.dupe(u8, id) catch continue;
            }
            defer alloc.free(name);
            pushInfo(alloc, &list, base, id, name) catch continue;
        }
    }
    const out = try list.toOwnedSlice(alloc);
    sortThemes(out);
    return out;
}

pub fn detectGtkTheme(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (runCapture(alloc, io, &.{ "gsettings", "get", "org.gnome.desktop.interface", "gtk-theme" })) |raw| {
        defer alloc.free(raw);
        const s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') {
            const inner = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
            if (inner.len > 0) return alloc.dupe(u8, inner) catch null;
        }
    }
    const cfg = userConfigDir(alloc) orelse return null;
    defer alloc.free(cfg);
    for ([_][]const u8{ "gtk-4.0/settings.ini", "gtk-3.0/settings.ini" }) |rel| {
        const p = std.fs.path.join(alloc, &.{ cfg, rel }) catch continue;
        defer alloc.free(p);
        if (readIniKv(alloc, io, p, "[Settings]", "gtk-theme-name")) |v| {
            if (v.len > 0) return v;
            alloc.free(v);
        }
    }
    return null;
}

/// Locate an installed theme by id, requiring a GTK4 stylesheet because the
/// libadwaita override needs one.
fn findGtk4ThemeDir(alloc: std.mem.Allocator, theme: []const u8) ?[]u8 {
    const bases = themeBaseDirs(alloc) catch return null;
    defer freeBases(alloc, bases);
    for (bases) |base| {
        const dir = std.fs.path.join(alloc, &.{ base, theme }) catch continue;
        const css = std.fs.path.join(alloc, &.{ dir, "gtk-4.0/gtk.css" }) catch {
            alloc.free(dir);
            continue;
        };
        const ok = readable(css);
        alloc.free(css);
        if (ok) return dir;
        alloc.free(dir);
    }
    return null;
}

/// Replace one path in the GTK4 config dir. A real file or directory is moved
/// to `<name>.eh-backup` the first time, so the matugen-generated gtk.css is
/// recoverable; on later applies the old override is just removed.
fn clearGtk4OverridePath(io: std.Io, alloc: std.mem.Allocator, path: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch return;
    switch (st.kind) {
        .file, .directory => {
            const backup = std.fmt.allocPrint(alloc, "{s}.eh-backup", .{path}) catch {
                if (st.kind == .directory) cwd.deleteTree(io, path) catch {} else cwd.deleteFile(io, path) catch {};
                return;
            };
            defer alloc.free(backup);
            if (cwd.statFile(io, backup, .{})) |_| {
                if (st.kind == .directory) cwd.deleteTree(io, path) catch {} else cwd.deleteFile(io, path) catch {};
            } else |_| {
                std.Io.Dir.renameAbsolute(path, backup, io) catch {
                    if (st.kind == .directory) cwd.deleteTree(io, path) catch {} else cwd.deleteFile(io, path) catch {};
                };
            }
        },
        else => cwd.deleteFile(io, path) catch {},
    }
}

/// The `-l/--libadwaita` override from the MacTahoe installer: libadwaita /
/// GTK4 apps ignore `gtk-theme-name` for their own widgets, so the theme only
/// takes effect if its gtk-4.0 stylesheet and assets are installed into
/// `~/.config/gtk-4.0` as the user stylesheet.
fn installGtk4Override(io: std.Io, theme: []const u8) void {
    const alloc = std.heap.page_allocator;
    const theme_dir = findGtk4ThemeDir(alloc, theme) orelse return;
    defer alloc.free(theme_dir);
    const cfg = userConfigDir(alloc) orelse return;
    defer alloc.free(cfg);
    const gtk4 = std.fs.path.join(alloc, &.{ cfg, "gtk-4.0" }) catch return;
    defer alloc.free(gtk4);
    const src_base = std.fs.path.join(alloc, &.{ theme_dir, "gtk-4.0" }) catch return;
    defer alloc.free(src_base);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, gtk4) catch return;

    // Copy the stylesheets rather than linking them: the colour engine also
    // writes gtk.css, and writing through a symlink into /usr/share would be
    // wrong (or fail) on the next matugen run.
    for ([_][]const u8{ "gtk.css", "gtk-dark.css" }) |name| {
        const src = std.fs.path.join(alloc, &.{ src_base, name }) catch continue;
        defer alloc.free(src);
        if (!readable(src)) continue;
        const dst = std.fs.path.join(alloc, &.{ gtk4, name }) catch continue;
        defer alloc.free(dst);
        clearGtk4OverridePath(io, alloc, dst);
        cwd.copyFile(src, cwd, dst, io, .{}) catch {};
    }

    // The stylesheet references assets/ and windows-assets/ relatively, so
    // expose the theme's copies at the same paths. Links keep this cheap and
    // are never written to.
    for ([_][]const u8{ "assets", "windows-assets" }) |name| {
        const src = std.fs.path.join(alloc, &.{ src_base, name }) catch continue;
        defer alloc.free(src);
        const st = cwd.statFile(io, src, .{}) catch continue;
        if (st.kind != .directory) continue;
        const dst = std.fs.path.join(alloc, &.{ gtk4, name }) catch continue;
        defer alloc.free(dst);
        clearGtk4OverridePath(io, alloc, dst);
        cwd.symLink(io, src, dst, .{}) catch {};
    }
}

pub fn applyGtkTheme(io: std.Io, theme: []const u8) void {
    if (theme.len == 0) return;
    runCmd(io, &.{ "gsettings", "set", "org.gnome.desktop.interface", "gtk-theme", theme });
    const alloc = std.heap.page_allocator;
    const cfg = userConfigDir(alloc) orelse return;
    defer alloc.free(cfg);
    for ([_][]const u8{ "gtk-4.0/settings.ini", "gtk-3.0/settings.ini" }) |rel| {
        const p = std.fs.path.join(alloc, &.{ cfg, rel }) catch continue;
        defer alloc.free(p);
        updateIniKey(io, p, "[Settings]", "gtk-theme-name", theme) catch {};
    }
    // GTK4/libadwaita needs the `-l` install treatment as well.
    installGtk4Override(io, theme);
}

fn parseHexColor(hex: []const u8) ?[3]f64 {
    if (hex.len == 0) return null;
    var h = hex;
    if (h[0] == '#') h = h[1..];
    var buf: [6]u8 = undefined;
    if (h.len == 3) {
        buf = .{ h[0], h[0], h[1], h[1], h[2], h[2] };
        h = &buf;
    }
    if (h.len != 6) return null;
    const a = std.fmt.parseInt(u8, h[0..2], 16) catch return null;
    const b = std.fmt.parseInt(u8, h[2..4], 16) catch return null;
    const c2 = std.fmt.parseInt(u8, h[4..6], 16) catch return null;
    return .{ @as(f64, @floatFromInt(a)) / 255.0, @as(f64, @floatFromInt(b)) / 255.0, @as(f64, @floatFromInt(c2)) / 255.0 };
}

fn isDefaultColor(v: [3]f64, dr: f64, dg: f64, db: f64) bool {
    const eps = 0.001;
    return @abs(v[0] - dr) < eps and @abs(v[1] - dg) < eps and @abs(v[2] - db) < eps;
}

fn setIfName(name: []const u8, want: []const u8, out: *[3]f64, rgb: [3]f64) bool {
    if (!std.mem.eql(u8, name, want)) return false;
    out.* = rgb;
    return true;
}

fn applyDefineColor(name_in: []const u8, val: []const u8, out: *Colors) void {
    const rgb = parseHexColor(val) orelse return;
    var lname_buf: [128]u8 = undefined;
    if (name_in.len > lname_buf.len) return;
    for (name_in, 0..) |ch, i| lname_buf[i] = std.ascii.toLower(ch);
    const name = lname_buf[0..name_in.len];

    _ = setIfName(name, "headerbar_bg_color", &out.header_bg, rgb);
    _ = setIfName(name, "headerbar_fg_color", &out.header_fg, rgb);
    if (setIfName(name, "window_bg_color", &out.bg, rgb) or
        setIfName(name, "theme_bg_color", &out.bg, rgb) or
        setIfName(name, "bg_color", &out.bg, rgb) or
        setIfName(name, "popover_bg_color", &out.bg, rgb))
    {}
    if (setIfName(name, "window_fg_color", &out.fg, rgb) or
        setIfName(name, "theme_fg_color", &out.fg, rgb) or
        setIfName(name, "fg_color", &out.fg, rgb) or
        setIfName(name, "popover_fg_color", &out.fg, rgb))
    {}
    if (setIfName(name, "accent_bg_color", &out.accent, rgb) or
        setIfName(name, "theme_selected_bg_color", &out.accent, rgb) or
        setIfName(name, "selected_bg_color", &out.accent, rgb) or
        setIfName(name, "button_bg_color", &out.accent, rgb))
    {}
    if (setIfName(name, "view_bg_color", &out.base, rgb) or
        setIfName(name, "theme_base_color", &out.base, rgb) or
        setIfName(name, "base_color", &out.base, rgb) or
        setIfName(name, "card_bg_color", &out.base, rgb))
    {}
    if (setIfName(name, "view_fg_color", &out.text, rgb) or
        setIfName(name, "theme_text_color", &out.text, rgb) or
        setIfName(name, "text_color", &out.text, rgb) or
        setIfName(name, "card_fg_color", &out.text, rgb))
    {}
}

fn scanDefines(alloc: std.mem.Allocator, io: std.Io, path: []const u8, out: *Colors) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_css_bytes)) catch return;
    defer alloc.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "@define-color")) continue;
        var rest = std.mem.trim(u8, line["@define-color".len..], " \t");
        const sp = std.mem.indexOfAny(u8, rest, " \t") orelse continue;
        const name = rest[0..sp];
        rest = std.mem.trim(u8, rest[sp..], " \t");
        const semi = std.mem.indexOfAny(u8, rest, " \t;") orelse rest.len;
        const val = rest[0..semi];
        if (val.len == 0 or val[0] != '#') continue;
        applyDefineColor(name, val, out);
    }
}

fn scanSelectors(alloc: std.mem.Allocator, io: std.Io, path: []const u8, out: *Colors) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_css_bytes)) catch return;
    defer alloc.free(data);
    var current_selector: []const u8 = "";
    var in_block = false;
    var depth: i32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const s = raw;
        if (!hasContent(s)) continue;
        if (!in_block) {
            if (std.mem.indexOfScalar(u8, s, '{')) |bc| {
                current_selector = std.mem.trimEnd(u8, s[0..bc], " \t");
                in_block = true;
                depth = 1;
                const after = s[bc + 1 ..];
                if (std.mem.indexOfScalar(u8, after, '}') != null) {
                    in_block = false;
                    depth = 0;
                }
            }
        } else {
            for (s) |ch| {
                if (ch == '{') {
                    depth += 1;
                } else if (ch == '}') {
                    depth -= 1;
                    if (depth <= 0) {
                        in_block = false;
                        current_selector = "";
                        depth = 0;
                        break;
                    }
                }
            }
        }
        if (!in_block and current_selector.len == 0) continue;
        if (!in_block or current_selector.len == 0) continue;

        const is_window = std.mem.indexOf(u8, current_selector, "window") != null or std.mem.indexOf(u8, current_selector, "WINDOW") != null;
        const is_button = std.mem.indexOf(u8, current_selector, "button") != null or std.mem.indexOf(u8, current_selector, "BUTTON") != null;
        const is_entry = std.mem.indexOf(u8, current_selector, "entry") != null or std.mem.indexOf(u8, current_selector, "textview") != null or std.mem.indexOf(u8, current_selector, "text") != null;
        const is_header = std.mem.indexOf(u8, current_selector, "headerbar") != null or std.mem.indexOf(u8, current_selector, "titlebar") != null;
        const is_global = std.mem.eql(u8, current_selector, "*");

        if (std.mem.indexOf(u8, s, "background-color")) |pos| {
            if (extractHex(s, pos + "background-color".len)) |hex| {
                if (parseHexColor(hex)) |rgb| {
                    if (is_header and isDefaultColor(out.header_bg, 0.9, 0.9, 0.9)) out.header_bg = rgb;
                    if (is_window and isDefaultColor(out.bg, 1, 1, 1)) out.bg = rgb;
                    if (is_button and isDefaultColor(out.accent, 0.2, 0.5, 0.9)) out.accent = rgb;
                    if (is_entry and isDefaultColor(out.base, 1, 1, 1)) out.base = rgb;
                    if (is_global and isDefaultColor(out.bg, 1, 1, 1)) out.bg = rgb;
                }
            }
        }

        if (std.mem.indexOf(u8, s, "color:")) |pos| {
            var is_bg = false;
            if (pos >= 16) {
                const before = s[pos - 16 .. pos];
                if (std.mem.indexOf(u8, before, "background") != null) is_bg = true;
            }
            if (!is_bg) {
                if (extractHex(s, pos + "color:".len)) |hex| {
                    if (parseHexColor(hex)) |rgb| {
                        if (is_header and isDefaultColor(out.header_fg, 0, 0, 0)) out.header_fg = rgb;
                        if (is_window and isDefaultColor(out.fg, 0, 0, 0)) out.fg = rgb;
                        if ((std.mem.indexOf(u8, current_selector, "label") != null or std.mem.indexOf(u8, current_selector, "text") != null) and isDefaultColor(out.text, 0, 0, 0)) out.text = rgb;
                        if (is_global and isDefaultColor(out.fg, 0, 0, 0)) out.fg = rgb;
                        if (is_global and isDefaultColor(out.text, 0, 0, 0)) out.text = rgb;
                    }
                }
            }
        }
    }
}

fn hasContent(s: []const u8) bool {
    for (s) |ch| if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') return true;
    return false;
}

fn extractHex(s: []const u8, from: usize) ?[]const u8 {
    if (from >= s.len) return null;
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i >= s.len or s[i] != '#') return null;
    const start = i;
    i += 1;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (!std.ascii.isHex(ch)) break;
    }
    return s[start..i];
}

pub fn extractGtkColors(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) Colors {
    var out: Colors = .{};
    for ([_][]const u8{ "/gtk-3.0/gtk.css", "/gtk-4.0/gtk.css" }) |rel| {
        const p = std.fs.path.join(alloc, &.{ dir, rel }) catch continue;
        defer alloc.free(p);
        scanDefines(alloc, io, p, &out);
    }
    if (isDefaultColor(out.bg, 1, 1, 1) or isDefaultColor(out.fg, 0, 0, 0) or isDefaultColor(out.accent, 0.2, 0.5, 0.9)) {
        for ([_][]const u8{ "/gtk-3.0/gtk.css", "/gtk-4.0/gtk.css" }) |rel| {
            const p = std.fs.path.join(alloc, &.{ dir, rel }) catch continue;
            defer alloc.free(p);
            scanSelectors(alloc, io, p, &out);
        }
    }
    if (isDefaultColor(out.header_bg, 0.9, 0.9, 0.9) and !isDefaultColor(out.bg, 1, 1, 1)) out.setHeaderFromBg();
    if (isDefaultColor(out.header_fg, 0, 0, 0) and !isDefaultColor(out.fg, 0, 0, 0)) out.header_fg = out.fg;
    if (isDefaultColor(out.base, 1, 1, 1) and !isDefaultColor(out.bg, 1, 1, 1)) out.base = out.bg;
    if (isDefaultColor(out.text, 0, 0, 0) and !isDefaultColor(out.fg, 0, 0, 0)) out.text = out.fg;
    out.valid = true;
    return out;
}

fn parseCssPx(val: []const u8) i32 {
    var end: usize = 0;
    while (end < val.len and (std.ascii.isDigit(val[end]) or val[end] == '.')) end += 1;
    if (end == 0) return -1;
    const f = std.fmt.parseFloat(f64, val[0..end]) catch return -1;
    return @intFromFloat(@round(f));
}

fn extractProp(s: []const u8, prop: []const u8) ?[]const u8 {
    const p = std.mem.indexOf(u8, s, prop) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, s, p + prop.len, ':') orelse return null;
    var start = colon + 1;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    if (start >= s.len) return null;
    var end = start;
    while (end < s.len and s[end] != ';' and s[end] != '}' and s[end] != '\r') end += 1;
    return s[start..end];
}

pub fn extractGtkDesign(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) Design {
    var out: Design = .{};
    for ([_][]const u8{ "/gtk-3.0/gtk.css", "/gtk-4.0/gtk.css" }) |rel| {
        const p = std.fs.path.join(alloc, &.{ dir, rel }) catch continue;
        defer alloc.free(p);
        const data = std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(max_css_bytes)) catch continue;
        defer alloc.free(data);
        var current_selector: []const u8 = "";
        var in_block = false;
        var depth: i32 = 0;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |s| {
            if (!hasContent(s)) continue;
            if (!in_block) {
                if (std.mem.indexOfScalar(u8, s, '{')) |bc| {
                    current_selector = std.mem.trimEnd(u8, s[0..bc], " \t");
                    in_block = true;
                    depth = 1;
                }
            } else {
                for (s) |ch| {
                    if (ch == '{') {
                        depth += 1;
                    } else if (ch == '}') {
                        depth -= 1;
                        if (depth <= 0) {
                            in_block = false;
                            current_selector = "";
                            depth = 0;
                            break;
                        }
                    }
                }
            }
            if (!in_block) {
                current_selector = "";
                continue;
            }
            if (current_selector.len == 0) continue;

            const is_window = std.mem.indexOf(u8, current_selector, "window") != null or std.mem.indexOf(u8, current_selector, "decoration") != null;
            const is_button = std.mem.indexOf(u8, current_selector, "button") != null;
            const is_entry = std.mem.indexOf(u8, current_selector, "entry") != null or std.mem.indexOf(u8, current_selector, "textview") != null;
            const is_header = std.mem.indexOf(u8, current_selector, "headerbar") != null or std.mem.indexOf(u8, current_selector, "titlebar") != null;
            const is_global = std.mem.eql(u8, current_selector, "*");

            if (extractProp(s, "border-radius")) |br| {
                const px = parseCssPx(br);
                if (px >= 0) {
                    if (is_window and px > 0) out.window_rad = @floatFromInt(px);
                    if (is_button and px > 0) out.button_rad = @floatFromInt(px);
                    if (is_entry and px > 0) out.entry_rad = @floatFromInt(px);
                    if (is_global and px > 0) {
                        if (out.window_rad == 6) out.window_rad = @floatFromInt(px);
                        if (out.button_rad == 3) out.button_rad = @floatFromInt(px);
                        if (out.entry_rad == 2) out.entry_rad = @floatFromInt(px);
                    }
                }
            }
            if (extractProp(s, "border-width")) |bw| {
                const px = parseCssPx(bw);
                if (px >= 0 and is_window) out.border_w = px;
            }
            if (is_header) {
                if (extractProp(s, "min-height")) |mh| {
                    const px = parseCssPx(mh);
                    if (px > 0 and px < 200) out.titlebar_h = @max(12, @min(40, @divTrunc(px, 2)));
                }
            }
        }
    }
    out.valid = true;
    return out;
}

// -------------------------------------------------------------------- Qt --

const qt_style_dirs_common = [_][]const u8{
    "/usr/lib/qt6/plugins/styles",
    "/usr/lib/x86_64-linux-gnu/qt6/plugins/styles",
    "/usr/lib64/qt6/plugins/styles",
    "/usr/lib/qt5/plugins/styles",
    "/usr/lib/x86_64-linux-gnu/qt5/plugins/styles",
    "/usr/lib64/qt5/plugins/styles",
    "/usr/local/lib/qt6/plugins/styles",
    "/usr/local/lib/qt5/plugins/styles",
};

fn scanQtPluginDir(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, out: *std.ArrayList([]const u8)) void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |ent| {
        const name = ent.name;
        if (name.len < 6 or !std.mem.endsWith(u8, name, ".so")) continue;
        var style: []const u8 = undefined;
        if (std.mem.startsWith(u8, name, "lib")) {
            style = name[3 .. name.len - 3];
        } else {
            style = name[0 .. name.len - 3];
        }
        if (style.len == 0 or std.mem.eql(u8, style, "qt6ct-style") or std.mem.eql(u8, style, "qt5ct-style")) continue;
        var buf: [128]u8 = undefined;
        if (style.len > buf.len) continue;
        buf[0] = std.ascii.toUpper(style[0]);
        @memcpy(buf[1..style.len], style[1..]);
        const titled = buf[0..style.len];
        var seen = false;
        for (out.items) |s| if (std.mem.eql(u8, s, titled)) {
            seen = true;
            break;
        };
        if (seen) continue;
        const dup = alloc.dupe(u8, titled) catch continue;
        out.append(alloc, dup) catch {
            alloc.free(dup);
            return;
        };
    }
}

pub fn knownQtStyles(alloc: std.mem.Allocator, io: std.Io) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    try out.append(alloc, try alloc.dupe(u8, "Fusion"));
    try out.append(alloc, try alloc.dupe(u8, "Windows"));

    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (dirs.items) |d| alloc.free(d);
        dirs.deinit(alloc);
    }
    if (env(env_home)) |home| {
        for ([_][]const u8{ ".local/share/qt6/styles", ".local/share/qt5/styles", ".local/share/flatpak/exports/share/qt6/styles", ".local/share/flatpak/exports/share/qt5/styles" }) |rel| {
            dirs.append(alloc, std.fs.path.join(alloc, &.{ home, rel }) catch continue) catch {};
        }
    }
    if (env(env_xdg_data_dirs)) |dd| {
        var it = std.mem.splitScalar(u8, dd, ':');
        while (it.next()) |raw| {
            const d = std.mem.trim(u8, raw, " \t");
            if (d.len == 0) continue;
            for ([_][]const u8{ "qt6/styles", "qt5/styles" }) |sub| {
                dirs.append(alloc, std.fs.path.join(alloc, &.{ d, sub }) catch continue) catch {};
            }
        }
    }
    for (qt_style_dirs_common) |p| dirs.append(alloc, alloc.dupe(u8, p) catch continue) catch {};

    for (dirs.items) |d| scanQtPluginDir(alloc, io, d, &out);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

pub fn detectQtStyle(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    const cfg = userConfigDir(alloc) orelse return null;
    defer alloc.free(cfg);
    for ([_][]const u8{ "qt6ct/qt6ct.conf", "qt5ct/qt5ct.conf" }) |rel| {
        const p = std.fs.path.join(alloc, &.{ cfg, rel }) catch continue;
        defer alloc.free(p);
        if (readIniKv(alloc, io, p, "[Appearance]", "style")) |v| {
            if (v.len > 0) return v;
            alloc.free(v);
        }
    }
    return null;
}

pub fn applyQtStyle(io: std.Io, style: []const u8) void {
    if (style.len == 0) return;
    const alloc = std.heap.page_allocator;
    const cfg = userConfigDir(alloc) orelse return;
    defer alloc.free(cfg);
    for ([_][]const u8{ "qt6ct/qt6ct.conf", "qt5ct/qt5ct.conf" }) |rel| {
        const p = std.fs.path.join(alloc, &.{ cfg, rel }) catch continue;
        defer alloc.free(p);
        updateIniKey(io, p, "[Appearance]", "style", style) catch {};
    }
    const kg = std.fs.path.join(alloc, &.{ cfg, "kdeglobals" }) catch return;
    defer alloc.free(kg);
    updateIniKey(io, kg, "[KDE]", "widgetStyle", style) catch {};
}

fn scanColorSchemeDir(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, out: *std.ArrayList([]const u8)) void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |ent| {
        const name = ent.name;
        if (!std.mem.endsWith(u8, name, ".conf") or name.len <= 5) continue;
        const stem = name[0 .. name.len - 5];
        var seen = false;
        for (out.items) |s| if (std.mem.eql(u8, s, stem)) {
            seen = true;
            break;
        };
        if (seen) continue;
        const dup = alloc.dupe(u8, stem) catch continue;
        out.append(alloc, dup) catch {
            alloc.free(dup);
            return;
        };
    }
}

pub fn listQtColorSchemes(alloc: std.mem.Allocator, io: std.Io) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    const home = env(env_home);
    if (home) |h| {
        for ([_][]const u8{ ".config/qt6ct/colors", ".config/qt5ct/colors", ".local/share/qt6ct/colors", ".local/share/qt5ct/colors" }) |rel| {
            const p = std.fs.path.join(alloc, &.{ h, rel }) catch continue;
            defer alloc.free(p);
            scanColorSchemeDir(alloc, io, p, &out);
        }
    }
    for ([_][]const u8{ "/usr/share/qt6ct/colors", "/usr/share/qt5ct/colors", "/usr/local/share/qt6ct/colors", "/usr/local/share/qt5ct/colors" }) |p| {
        scanColorSchemeDir(alloc, io, p, &out);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

pub fn detectQtColorScheme(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    const cfg = userConfigDir(alloc) orelse return null;
    defer alloc.free(cfg);
    for ([_][]const u8{ "qt6ct/qt6ct.conf", "qt5ct/qt5ct.conf" }) |rel| {
        const p = std.fs.path.join(alloc, &.{ cfg, rel }) catch continue;
        defer alloc.free(p);
        if (readIniKv(alloc, io, p, "[Appearance]", "color_scheme_path")) |v| {
            defer alloc.free(v);
            if (v.len == 0) continue;
            const base = std.fs.path.basename(v);
            const stem = if (std.mem.endsWith(u8, base, ".conf")) base[0 .. base.len - 5] else base;
            if (stem.len > 0) return alloc.dupe(u8, stem) catch null;
        }
    }
    return null;
}

const color_scheme_dirs = [_][]const u8{
    ".config/qt6ct/colors",                            ".config/qt5ct/colors",
    ".local/share/qt6ct/colors",                       ".local/share/qt5ct/colors",
    ".local/share/flatpak/exports/share/qt6ct/colors", ".local/share/flatpak/exports/share/qt5ct/colors",
};

pub fn applyQtColorScheme(io: std.Io, scheme: []const u8) void {
    const alloc = std.heap.page_allocator;
    const cfg = userConfigDir(alloc) orelse return;
    defer alloc.free(cfg);
    const detected = detectQtStyle(alloc, io);
    defer if (detected) |s| alloc.free(s);
    const use_style = if (detected) |s| s else "Fusion";
    for ([_][]const u8{ "qt6ct", "qt5ct" }) |tool| {
        const rel = std.fmt.allocPrint(alloc, "{s}/{s}.conf", .{ tool, tool }) catch continue;
        defer alloc.free(rel);
        const path = std.fs.path.join(alloc, &.{ cfg, rel }) catch continue;
        defer alloc.free(path);
        updateIniKey(io, path, "[Appearance]", "style", use_style) catch {};
        if (scheme.len == 0 or std.mem.eql(u8, scheme, "None")) {
            updateIniKey(io, path, "[Appearance]", "color_scheme_path", "") catch {};
        } else {
            const colors_rel = std.fmt.allocPrint(alloc, "{s}/colors/{s}.conf", .{ tool, scheme }) catch continue;
            defer alloc.free(colors_rel);
            const scheme_path = std.fs.path.join(alloc, &.{ cfg, colors_rel }) catch continue;
            defer alloc.free(scheme_path);
            updateIniKey(io, path, "[Appearance]", "color_scheme_path", scheme_path) catch {};
        }
    }
}

fn parseRgbTriplet(val: []const u8) ?[3]f64 {
    var it = std.mem.splitScalar(u8, val, ',');
    var out: [3]f64 = .{ 0, 0, 0 };
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 3) break;
        const n = std.fmt.parseInt(i32, std.mem.trim(u8, part, " \t"), 10) catch return null;
        out[i] = @as(f64, @floatFromInt(std.math.clamp(n, 0, 255))) / 255.0;
    }
    if (i < 3) return null;
    return out;
}

fn parseColorSchemeFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) Colors {
    var out: Colors = .{};
    var any = false;
    const win_bg = readIniKv(alloc, io, path, "[Colors:Window]", "BackgroundNormal");
    if (win_bg) |v| {
        defer alloc.free(v);
        if (parseRgbTriplet(v)) |rgb| {
            out.bg = rgb;
            any = true;
        }
    }
    if (readIniKv(alloc, io, path, "[Colors:Window]", "ForegroundNormal")) |v| {
        defer alloc.free(v);
        if (parseRgbTriplet(v)) |rgb| {
            out.fg = rgb;
            out.header_fg = rgb;
            any = true;
        }
    }
    if (readIniKv(alloc, io, path, "[Colors:Selection]", "BackgroundNormal")) |v| {
        defer alloc.free(v);
        if (parseRgbTriplet(v)) |rgb| {
            out.accent = rgb;
            any = true;
        }
    }
    if (readIniKv(alloc, io, path, "[Colors:View]", "BackgroundNormal")) |v| {
        defer alloc.free(v);
        if (parseRgbTriplet(v)) |rgb| {
            out.base = rgb;
            out.text = rgb;
            any = true;
        }
    }
    if (readIniKv(alloc, io, path, "[Colors:View]", "ForegroundNormal")) |v| {
        defer alloc.free(v);
        if (parseRgbTriplet(v)) |rgb| {
            out.text = rgb;
            any = true;
        }
    }
    if (readIniKv(alloc, io, path, "[Colors:Button]", "BackgroundNormal")) |v| {
        defer alloc.free(v);
        if (parseRgbTriplet(v)) |rgb| {
            out.header_bg = rgb;
            any = true;
        }
    }
    out.valid = any;
    return out;
}

pub fn qtColorSchemeColors(alloc: std.mem.Allocator, io: std.Io, scheme: []const u8) Colors {
    if (scheme.len == 0) return .{};
    const home = env(env_home) orelse return .{};
    for (color_scheme_dirs) |rel| {
        const p = std.fs.path.join(alloc, &.{ home, rel, scheme }) catch continue;
        defer alloc.free(p);
        const p2 = std.fmt.allocPrint(alloc, "{s}.conf", .{p}) catch continue;
        defer alloc.free(p2);
        const colors = parseColorSchemeFile(alloc, io, p2);
        if (colors.valid) return colors;
    }
    for ([_][]const u8{ "/usr/share/qt6ct/colors", "/usr/share/qt5ct/colors", "/usr/local/share/qt6ct/colors", "/usr/local/share/qt5ct/colors" }) |dir| {
        const p = std.fmt.allocPrint(alloc, "{s}/{s}.conf", .{ dir, scheme }) catch continue;
        defer alloc.free(p);
        const colors = parseColorSchemeFile(alloc, io, p);
        if (colors.valid) return colors;
    }
    return .{};
}

const QtPalette = struct {
    name: []const u8,
    bg: [3]f64,
    fg: [3]f64,
    accent: [3]f64,
    base: [3]f64,
};

const qt_palettes = [_]QtPalette{
    .{ .name = "fusion", .bg = .{ 0.88, 0.88, 0.88 }, .fg = .{ 0.12, 0.12, 0.12 }, .accent = .{ 0.55, 0.55, 0.55 }, .base = .{ 1, 1, 1 } },
    .{ .name = "breeze", .bg = .{ 0.85, 0.88, 0.92 }, .fg = .{ 0.10, 0.12, 0.15 }, .accent = .{ 0.25, 0.55, 0.88 }, .base = .{ 0.98, 0.98, 1 } },
    .{ .name = "kvantum", .bg = .{ 0.82, 0.82, 0.86 }, .fg = .{ 0.15, 0.15, 0.18 }, .accent = .{ 0.60, 0.50, 0.70 }, .base = .{ 0.95, 0.95, 0.98 } },
    .{ .name = "windows", .bg = .{ 0.92, 0.92, 0.94 }, .fg = .{ 0.10, 0.10, 0.10 }, .accent = .{ 0.45, 0.65, 0.82 }, .base = .{ 1, 1, 1 } },
    .{ .name = "windowsxp", .bg = .{ 0.88, 0.92, 0.85 }, .fg = .{ 0.10, 0.15, 0.08 }, .accent = .{ 0.30, 0.70, 0.35 }, .base = .{ 0.98, 1, 0.95 } },
    .{ .name = "windowsvista", .bg = .{ 0.90, 0.90, 0.94 }, .fg = .{ 0.10, 0.10, 0.14 }, .accent = .{ 0.30, 0.65, 0.80 }, .base = .{ 1, 1, 1 } },
    .{ .name = "fluent", .bg = .{ 0.88, 0.88, 0.90 }, .fg = .{ 0.10, 0.10, 0.12 }, .accent = .{ 0.35, 0.55, 0.85 }, .base = .{ 0.98, 0.98, 1 } },
    .{ .name = "material", .bg = .{ 0.90, 0.90, 0.92 }, .fg = .{ 0.10, 0.10, 0.12 }, .accent = .{ 0.40, 0.60, 0.85 }, .base = .{ 1, 1, 1 } },
    .{ .name = "gtk2", .bg = .{ 0.88, 0.88, 0.88 }, .fg = .{ 0.12, 0.12, 0.12 }, .accent = .{ 0.50, 0.60, 0.70 }, .base = .{ 0.98, 0.98, 0.98 } },
    .{ .name = "gtk3", .bg = .{ 0.86, 0.88, 0.90 }, .fg = .{ 0.12, 0.14, 0.16 }, .accent = .{ 0.40, 0.55, 0.75 }, .base = .{ 0.96, 0.97, 0.99 } },
    .{ .name = "qtcurve", .bg = .{ 0.85, 0.85, 0.88 }, .fg = .{ 0.14, 0.14, 0.16 }, .accent = .{ 0.55, 0.55, 0.55 }, .base = .{ 0.96, 0.96, 0.98 } },
    .{ .name = "oxygen", .bg = .{ 0.86, 0.88, 0.90 }, .fg = .{ 0.12, 0.14, 0.16 }, .accent = .{ 0.25, 0.55, 0.75 }, .base = .{ 0.96, 0.97, 0.99 } },
    .{ .name = "cleanlooks", .bg = .{ 0.88, 0.88, 0.88 }, .fg = .{ 0.12, 0.12, 0.12 }, .accent = .{ 0.50, 0.50, 0.50 }, .base = .{ 1, 1, 1 } },
    .{ .name = "plastique", .bg = .{ 0.89, 0.89, 0.91 }, .fg = .{ 0.11, 0.11, 0.13 }, .accent = .{ 0.50, 0.55, 0.60 }, .base = .{ 0.99, 0.99, 1 } },
    .{ .name = "chrome", .bg = .{ 0.89, 0.89, 0.91 }, .fg = .{ 0.11, 0.11, 0.13 }, .accent = .{ 0.45, 0.65, 0.75 }, .base = .{ 0.99, 0.99, 1 } },
    .{ .name = "redmond", .bg = .{ 0.92, 0.92, 0.94 }, .fg = .{ 0.10, 0.10, 0.12 }, .accent = .{ 0.45, 0.65, 0.80 }, .base = .{ 1, 1, 1 } },
};

pub fn qtStyleColors(style: []const u8) Colors {
    var lower_buf: [128]u8 = undefined;
    if (style.len > lower_buf.len) return .{};
    for (style, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const lower = lower_buf[0..style.len];
    for (qt_palettes) |p| {
        if (std.mem.eql(u8, lower, p.name)) {
            var out: Colors = .{};
            out.bg = p.bg;
            out.fg = p.fg;
            out.accent = p.accent;
            out.base = p.base;
            out.text = p.fg;
            out.header_bg = .{ p.bg[0] * 0.85, p.bg[1] * 0.85, p.bg[2] * 0.85 };
            out.header_fg = p.fg;
            out.valid = true;
            return out;
        }
    }
    return .{};
}

// ---------------------------------------------------------------- Plasma --

fn plasmaColorSchemePath(alloc: std.mem.Allocator, io: std.Io, theme_dir: []const u8) ?[]u8 {
    const colors_dir = std.fs.path.join(alloc, &.{ theme_dir, "colors" }) catch return null;
    defer alloc.free(colors_dir);
    var d = std.Io.Dir.cwd().openDir(io, colors_dir, .{ .iterate = true }) catch null;
    if (d) |*dir| {
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |ent| {
            if (!std.mem.endsWith(u8, ent.name, ".colors")) continue;
            return std.fs.path.join(alloc, &.{ colors_dir, ent.name }) catch null;
        }
    }

    const meta = std.fs.path.join(alloc, &.{ theme_dir, "metadata.desktop" }) catch return null;
    defer alloc.free(meta);
    const name_owned: ?[]u8 = readIniKv(alloc, io, meta, "[Desktop Entry]", "Name");
    defer if (name_owned) |n| alloc.free(n);
    const theme_name = if (name_owned) |n| n else std.fs.path.basename(theme_dir);

    var search: std.ArrayList([]const u8) = .empty;
    defer {
        for (search.items) |s| alloc.free(s);
        search.deinit(alloc);
    }
    if (env(env_home)) |home| {
        for ([_][]const u8{ ".local/share/color-schemes", ".local/share/flatpak/exports/share/color-schemes" }) |rel| {
            const p = std.fs.path.join(alloc, &.{ home, rel }) catch continue;
            search.append(alloc, p) catch alloc.free(p);
        }
    }
    for ([_][]const u8{ "/usr/share/color-schemes", "/usr/local/share/color-schemes", "/var/lib/flatpak/exports/share/color-schemes" }) |p| {
        const dup = alloc.dupe(u8, p) catch continue;
        search.append(alloc, dup) catch alloc.free(dup);
    }

    for (search.items) |dir| {
        var d2 = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch continue;
        defer d2.close(io);
        var it2 = d2.iterate();
        while (it2.next(io) catch null) |ent| {
            if (!std.mem.endsWith(u8, ent.name, ".colors")) continue;
            const base = ent.name[0 .. ent.name.len - 7];
            if (std.mem.eql(u8, base, theme_name) or normalizedEqual(base, theme_name)) {
                return std.fs.path.join(alloc, &.{ dir, ent.name }) catch null;
            }
        }
    }
    return null;
}

fn normalizedEqual(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and (a[ai] == ' ' or a[ai] == '-')) ai += 1;
        while (bi < b.len and (b[bi] == ' ' or b[bi] == '-')) bi += 1;
        if (ai >= a.len or bi >= b.len) return ai >= a.len and bi >= b.len;
        if (std.ascii.toLower(a[ai]) != std.ascii.toLower(b[bi])) return false;
        ai += 1;
        bi += 1;
    }
}

pub fn listPlasmaThemes(alloc: std.mem.Allocator, io: std.Io) ![]ThemeInfo {
    var list: std.ArrayList(ThemeInfo) = .empty;
    errdefer {
        for (list.items) |t| {
            alloc.free(t.id);
            alloc.free(t.name);
            alloc.free(t.path);
        }
        list.deinit(alloc);
    }
    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (dirs.items) |d| alloc.free(d);
        dirs.deinit(alloc);
    }
    if (env(env_home)) |home| {
        const p = std.fs.path.join(alloc, &.{ home, ".local/share/plasma/desktoptheme" }) catch null;
        if (p) |pp| dirs.append(alloc, pp) catch alloc.free(pp);
    }
    const usr = alloc.dupe(u8, "/usr/share/plasma/desktoptheme") catch null;
    if (usr) |u| dirs.append(alloc, u) catch alloc.free(u);

    for (dirs.items) |base| {
        var d = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |ent| {
            if (ent.kind != .directory and ent.kind != .unknown) continue;
            const id = ent.name;
            if (id.len == 0 or id[0] == '.') continue;
            if (hasById(list.items, id)) continue;
            const meta = std.fs.path.join(alloc, &.{ base, id, "metadata.desktop" }) catch continue;
            defer alloc.free(meta);
            if (!readable(meta)) continue;
            var name: []u8 = &.{};
            if (readIniKv(alloc, io, meta, "[Desktop Entry]", "Name")) |n| {
                name = n;
            } else {
                name = alloc.dupe(u8, id) catch continue;
            }
            defer alloc.free(name);
            pushInfo(alloc, &list, base, id, name) catch continue;
        }
    }
    const out = try list.toOwnedSlice(alloc);
    return out;
}

pub fn detectPlasmaTheme(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    const cfg = userConfigDir(alloc) orelse return null;
    defer alloc.free(cfg);
    const p = std.fs.path.join(alloc, &.{ cfg, "plasmarc" }) catch return null;
    defer alloc.free(p);
    if (readIniKv(alloc, io, p, "[Theme]", "name")) |v| {
        if (v.len > 0) return v;
        alloc.free(v);
    }
    return null;
}

pub fn applyPlasmaTheme(alloc: std.mem.Allocator, io: std.Io, theme_id: []const u8) void {
    if (theme_id.len == 0) return;
    const home = env(env_home) orelse return;
    var theme_path: ?[]u8 = null;
    const bases = [_][]const u8{ "/usr/share/plasma/desktoptheme", "/usr/local/share/plasma/desktoptheme" };
    const user_base = std.fs.path.join(alloc, &.{ home, ".local/share/plasma/desktoptheme" }) catch null;
    defer if (user_base) |b| alloc.free(b);
    if (user_base) |ub| {
        const p = std.fs.path.join(alloc, &.{ ub, theme_id }) catch null;
        if (p) |pp| {
            const meta = std.fs.path.join(alloc, &.{ pp, "metadata.desktop" }) catch null;
            if (meta) |m| {
                defer alloc.free(m);
                if (readable(m)) theme_path = pp else alloc.free(pp);
            } else alloc.free(pp);
        }
    }
    if (theme_path == null) {
        for (bases) |base| {
            const p = std.fs.path.join(alloc, &.{ base, theme_id }) catch continue;
            const meta = std.fs.path.join(alloc, &.{ p, "metadata.desktop" }) catch {
                alloc.free(p);
                continue;
            };
            if (readable(meta)) {
                alloc.free(meta);
                theme_path = p;
                break;
            }
            alloc.free(meta);
            alloc.free(p);
        }
    }
    const tpath = theme_path orelse return;
    defer alloc.free(tpath);

    const cfg = userConfigDir(alloc) orelse return;
    defer alloc.free(cfg);

    // plasmarc: [Theme] name=<id>, preserving other sections.
    {
        const p = std.fs.path.join(alloc, &.{ cfg, "plasmarc" }) catch return;
        defer alloc.free(p);
        const existing = std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(max_ini_bytes)) catch "";
        defer if (existing.len > 0) alloc.free(existing);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        out.appendSlice(alloc, "[Theme]\n") catch return;
        out.appendSlice(alloc, std.fmt.allocPrint(alloc, "name={s}\n", .{theme_id}) catch return) catch return;
        if (existing.len > 0) {
            var in_theme = false;
            var it = std.mem.splitScalar(u8, existing, '\n');
            while (it.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (line.len > 0 and line[0] == '[') {
                    in_theme = std.mem.eql(u8, line, "[Theme]");
                    if (!in_theme) {
                        out.appendSlice(alloc, line) catch return;
                        out.append(alloc, '\n') catch return;
                    }
                } else if (!in_theme) {
                    out.appendSlice(alloc, line) catch return;
                    out.append(alloc, '\n') catch return;
                }
            }
        }
        writeFile(io, p, out.items);
    }

    // kdeglobals: copy the .colors sections and point ColorScheme at it.
    if (plasmaColorSchemePath(alloc, io, tpath)) |colors_path| {
        defer alloc.free(colors_path);
        const colors_content = std.Io.Dir.cwd().readFileAlloc(io, colors_path, alloc, .limited(max_ini_bytes)) catch "";
        defer if (colors_content.len > 0) alloc.free(colors_content);
        const kg = std.fs.path.join(alloc, &.{ cfg, "kdeglobals" }) catch return;
        defer alloc.free(kg);
        const existing = std.Io.Dir.cwd().readFileAlloc(io, kg, alloc, .limited(max_ini_bytes)) catch "";
        defer if (existing.len > 0) alloc.free(existing);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        out.appendSlice(alloc, "[General]\n") catch return;
        {
            var cit = std.mem.splitScalar(u8, colors_content, '\n');
            var in_general = false;
            while (cit.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (line.len > 0 and line[0] == '[') {
                    in_general = std.mem.eql(u8, line, "[General]");
                    continue;
                }
                if (in_general and !std.mem.startsWith(u8, line, "Name=") and !std.mem.startsWith(u8, line, "ColorScheme=")) {
                    out.appendSlice(alloc, line) catch return;
                    out.append(alloc, '\n') catch return;
                }
            }
        }
        const scheme = std.fs.path.stem(colors_path);
        out.appendSlice(alloc, std.fmt.allocPrint(alloc, "ColorScheme={s}\n\n", .{scheme}) catch return) catch return;
        {
            var cit = std.mem.splitScalar(u8, colors_content, '\n');
            var in_colors = false;
            while (cit.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (std.mem.startsWith(u8, line, "[Colors:")) {
                    in_colors = true;
                    out.appendSlice(alloc, line) catch return;
                    out.append(alloc, '\n') catch return;
                } else if (in_colors) {
                    if (line.len > 0 and line[0] == '[') {
                        in_colors = false;
                    } else {
                        out.appendSlice(alloc, line) catch return;
                        out.append(alloc, '\n') catch return;
                    }
                }
            }
        }
        if (existing.len > 0) {
            var eit = std.mem.splitScalar(u8, existing, '\n');
            var skip_section = false;
            while (eit.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (line.len > 0 and line[0] == '[') {
                    if (std.mem.eql(u8, line, "[General]") or std.mem.startsWith(u8, line, "[Colors:")) {
                        skip_section = true;
                    } else {
                        skip_section = false;
                        out.appendSlice(alloc, line) catch return;
                        out.append(alloc, '\n') catch return;
                    }
                } else if (!skip_section) {
                    out.appendSlice(alloc, line) catch return;
                    out.append(alloc, '\n') catch return;
                }
            }
        }
        writeFile(io, kg, out.items);
    }

    applyQtStyle(io, "Breeze");
}

pub fn extractPlasmaColors(alloc: std.mem.Allocator, io: std.Io, theme_dir: []const u8) Colors {
    const path = plasmaColorSchemePath(alloc, io, theme_dir) orelse return .{};
    defer alloc.free(path);
    return parseColorSchemeFile(alloc, io, path);
}

// ---------------------------------------------------------------- Cursor --

pub fn listCursorThemes(alloc: std.mem.Allocator, io: std.Io) ![]ThemeInfo {
    const bases = themeBaseDirs(alloc) catch return try alloc.alloc(ThemeInfo, 0);
    defer freeBases(alloc, bases);
    var list: std.ArrayList(ThemeInfo) = .empty;
    errdefer {
        for (list.items) |t| {
            alloc.free(t.id);
            alloc.free(t.name);
            alloc.free(t.path);
        }
        list.deinit(alloc);
    }
    const cwd = std.Io.Dir.cwd();
    for (bases) |base| {
        var d = cwd.openDir(io, base, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |ent| {
            if (ent.kind != .directory and ent.kind != .unknown) continue;
            const id = ent.name;
            if (id.len == 0 or id[0] == '.') continue;
            if (hasById(list.items, id)) continue;
            const dir = std.fs.path.join(alloc, &.{ base, id }) catch continue;
            defer alloc.free(dir);
            const cursors = std.fs.path.join(alloc, &.{ dir, "cursors" }) catch continue;
            defer alloc.free(cursors);
            if (!readable(cursors)) continue;
            var name: []u8 = &.{};
            const idx = std.fs.path.join(alloc, &.{ dir, "index.theme" }) catch continue;
            defer alloc.free(idx);
            if (readIniKv(alloc, io, idx, "[Icon Theme]", "Name")) |n| {
                name = n;
            } else {
                name = alloc.dupe(u8, id) catch continue;
            }
            defer alloc.free(name);
            pushInfo(alloc, &list, base, id, name) catch continue;
        }
    }
    const out = try list.toOwnedSlice(alloc);
    sortThemes(out);
    return out;
}

pub fn detectCursorTheme(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (runCapture(alloc, io, &.{ "gsettings", "get", "org.desktop.interface", "cursor-theme" })) |raw| {
        defer alloc.free(raw);
        const s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') {
            const inner = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
            if (inner.len > 0) return alloc.dupe(u8, inner) catch null;
        }
    }
    if (runCapture(alloc, io, &.{ "gsettings", "get", "org.gnome.desktop.interface", "cursor-theme" })) |raw| {
        defer alloc.free(raw);
        const s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') {
            const inner = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
            if (inner.len > 0) return alloc.dupe(u8, inner) catch null;
        }
    }
    return null;
}

pub fn detectCursorSize(alloc: std.mem.Allocator, io: std.Io) i32 {
    if (runCapture(alloc, io, &.{ "gsettings", "get", "org.gnome.desktop.interface", "cursor-size" })) |raw| {
        defer alloc.free(raw);
        const s = std.mem.trim(u8, raw, " \t\r\n");
        const v = std.fmt.parseInt(i32, s, 10) catch 24;
        return std.math.clamp(v, 16, 64);
    }
    return 24;
}

pub fn applyCursorConfig(alloc: std.mem.Allocator, io: std.Io, theme: []const u8, size: i32) void {
    if (theme.len == 0) return;
    runCmd(io, &.{ "gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", theme });
    var size_buf: [16]u8 = undefined;
    const size_s = std.fmt.bufPrint(&size_buf, "{d}", .{size}) catch "24";
    runCmd(io, &.{ "gsettings", "set", "org.gnome.desktop.interface", "cursor-size", size_s });
    if (env(env_hyprland) != null) {
        runCmd(io, &.{ "hyprctl", "setcursor", theme, size_s });
    } else if (env(env_sway) != null) {
        runCmd(io, &.{ "swaymsg", "seat", "seat0", "xcursor_theme", theme, size_s });
    }
    _ = alloc;
}

fn rd32(data: []const u8, off: usize) ?u32 {
    if (off + 4 > data.len) return null;
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

/// Load the first image in an Xcursor file (nearest nominal size) into a
/// cairo ARGB32 surface. Parsing the file directly keeps the service free of
/// a libXcursor dependency.
pub fn loadCursorSurface(alloc: std.mem.Allocator, io: std.Io, file_path: []const u8, target_px: i32) ?*cairo.cairo_surface_t {
    const data = std.Io.Dir.cwd().readFileAlloc(io, file_path, alloc, .limited(max_cursor_bytes)) catch return null;
    defer alloc.free(data);
    if (data.len < 16 or !std.mem.eql(u8, data[0..4], "Xcur")) return null;
    const ntoc = rd32(data, 12) orelse return null;

    var best_pos: usize = 0;
    var best_score: i64 = std.math.maxInt(i64);
    var found = false;
    var i: u32 = 0;
    while (i < ntoc) : (i += 1) {
        const off: usize = 16 + @as(usize, i) * 12;
        const kind = rd32(data, off) orelse break;
        if (kind != 0xfffd0002) continue;
        const subtype = rd32(data, off + 4) orelse break;
        const pos = rd32(data, off + 8) orelse break;
        const score: i64 = @intCast(@abs(@as(i64, subtype) - @as(i64, target_px)));
        if (score < best_score) {
            best_score = score;
            best_pos = pos;
            found = true;
        }
    }
    if (!found) return null;

    const header = rd32(data, best_pos) orelse return null;
    const pix_off = best_pos + header;
    const w = rd32(data, best_pos + 16) orelse return null;
    const h = rd32(data, best_pos + 20) orelse return null;
    if (w == 0 or h == 0 or w >= 512 or h >= 512) return null;
    const w_us: usize = w;
    const h_us: usize = h;
    if (pix_off + w_us * h_us * 4 > data.len) return null;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, @intCast(w), @intCast(h));
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const dst: [*]u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const stride: usize = @intCast(cairo.cairo_image_surface_get_stride(surf));
    var y: usize = 0;
    while (y < h_us) : (y += 1) {
        var x: usize = 0;
        while (x < w_us) : (x += 1) {
            const p = std.mem.readInt(u32, data[pix_off + (y * w_us + x) * 4 ..][0..4], .little);
            const a: u8 = @intCast((p >> 24) & 0xff);
            var r: u8 = @intCast((p >> 16) & 0xff);
            var g: u8 = @intCast((p >> 8) & 0xff);
            var b: u8 = @intCast(p & 0xff);
            if (a > 0 and a < 255) {
                r = @intCast((@as(u32, r) * a) / 255);
                g = @intCast((@as(u32, g) * a) / 255);
                b = @intCast((@as(u32, b) * a) / 255);
            }
            const o = y * stride + x * 4;
            dst[o + 0] = b;
            dst[o + 1] = g;
            dst[o + 2] = r;
            dst[o + 3] = a;
        }
    }
    cairo.cairo_surface_mark_dirty(surf);
    return surf;
}

const cursor_aliases = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "left_ptr", &[_][]const u8{ "left_ptr", "default", "arrow" } },
    .{ "hand2", &[_][]const u8{ "hand2", "hand1", "pointer", "hand", "openhand" } },
    .{ "xterm", &[_][]const u8{ "xterm", "text", "ibeam" } },
    .{ "crosshair", &[_][]const u8{ "crosshair", "cross", "cross_reverse", "diamond_cross" } },
    .{ "watch", &[_][]const u8{ "watch", "wait", "left_ptr_watch", "half-busy" } },
    .{ "fleur", &[_][]const u8{ "fleur", "move", "all-scroll", "grabbing", "grab" } },
    .{ "no-drop", &[_][]const u8{ "no-drop", "not-allowed", "crossed_circle", "forbidden" } },
    .{ "help", &[_][]const u8{ "help", "question_arrow", "left_ptr_help", "whats_this" } },
});

pub fn loadCursorShape(alloc: std.mem.Allocator, io: std.Io, theme_path: []const u8, shape: []const u8, target_px: i32) ?*cairo.cairo_surface_t {
    if (theme_path.len == 0) return null;
    const names = cursor_aliases.get(shape) orelse &[_][]const u8{shape};
    for (names) |name| {
        const p = std.fs.path.join(alloc, &.{ theme_path, "cursors", name }) catch continue;
        defer alloc.free(p);
        if (!readable(p)) continue;
        if (loadCursorSurface(alloc, io, p, target_px)) |s| return s;
    }
    return null;
}

// ---------------------------------------------------------------- tests --

test "system-theming: hex parsing and fallback derivation" {
    const t = std.testing;
    try t.expectEqual(@as(?[3]f64, .{ 1, 1, 1 }), parseHexColor("#fff"));
    try t.expectEqual(@as(?[3]f64, .{ 1, 0, 0 }), parseHexColor("#ff0000"));
    try t.expect(parseHexColor("nope") == null);
    var colors: Colors = .{};
    applyDefineColor("window_bg_color", "#202020", &colors);
    try t.expectApproxEqAbs(@as(f64, 0x20) / 255.0, colors.bg[0], 1e-9);
    try t.expect(isDefaultColor(.{ 1, 1, 1 }, 1, 1, 1));
}

test "system-theming: gtk4 libadwaita override" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/opencode/system-theming-override-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    const alloc = t.allocator;
    const home = try std.fs.path.join(alloc, &.{ root, "home" });
    defer alloc.free(home);
    const cfg = try std.fs.path.join(alloc, &.{ home, ".config" });
    defer alloc.free(cfg);
    const data_home = try std.fs.path.join(alloc, &.{ home, ".local", "share" });
    defer alloc.free(data_home);
    const theme_gtk4 = try std.fs.path.join(alloc, &.{ data_home, "themes", "FakeTheme", "gtk-4.0" });
    defer alloc.free(theme_gtk4);
    const assets = try std.fs.path.join(alloc, &.{ theme_gtk4, "assets" });
    defer alloc.free(assets);
    const win_assets = try std.fs.path.join(alloc, &.{ theme_gtk4, "windows-assets" });
    defer alloc.free(win_assets);
    const src_css = try std.fs.path.join(alloc, &.{ theme_gtk4, "gtk.css" });
    defer alloc.free(src_css);
    const src_dark = try std.fs.path.join(alloc, &.{ theme_gtk4, "gtk-dark.css" });
    defer alloc.free(src_dark);
    const dst_css = try std.fs.path.join(alloc, &.{ cfg, "gtk-4.0", "gtk.css" });
    defer alloc.free(dst_css);
    const dst_backup = try std.fmt.allocPrint(alloc, "{s}.eh-backup", .{dst_css});
    defer alloc.free(dst_backup);
    const dst_assets = try std.fs.path.join(alloc, &.{ cfg, "gtk-4.0", "assets" });
    defer alloc.free(dst_assets);

    try cwd.createDirPath(io, assets);
    try cwd.createDirPath(io, win_assets);
    try cwd.writeFile(io, .{ .sub_path = src_css, .data = "/* fake gtk4 v1 */\n" });
    try cwd.writeFile(io, .{ .sub_path = src_dark, .data = "/* fake gtk4 dark */\n" });

    const old_home = std.c.getenv("HOME");
    const old_cfg = std.c.getenv("XDG_CONFIG_HOME");
    const old_data = std.c.getenv("XDG_DATA_HOME");
    const old_home_owned = if (old_home) |v| try alloc.dupe(u8, std.mem.span(v)) else null;
    const old_cfg_owned = if (old_cfg) |v| try alloc.dupe(u8, std.mem.span(v)) else null;
    const old_data_owned = if (old_data) |v| try alloc.dupe(u8, std.mem.span(v)) else null;
    defer {
        if (old_home_owned) |v| alloc.free(v);
        if (old_cfg_owned) |v| alloc.free(v);
        if (old_data_owned) |v| alloc.free(v);
    }
    {
        const zh = try alloc.dupeSentinel(u8, home, 0);
        defer alloc.free(zh);
        const zc = try alloc.dupeSentinel(u8, cfg, 0);
        defer alloc.free(zc);
        const zd = try alloc.dupeSentinel(u8, data_home, 0);
        defer alloc.free(zd);
        _ = c.setenv("HOME", zh, 1);
        _ = c.setenv("XDG_CONFIG_HOME", zc, 1);
        _ = c.setenv("XDG_DATA_HOME", zd, 1);
    }
    defer {
        if (old_home_owned) |v| {
            if (alloc.dupeSentinel(u8, v, 0)) |z| {
                defer alloc.free(z);
                _ = c.setenv("HOME", z, 1);
            } else |_| {}
        } else _ = c.unsetenv("HOME");
        if (old_cfg_owned) |v| {
            if (alloc.dupeSentinel(u8, v, 0)) |z| {
                defer alloc.free(z);
                _ = c.setenv("XDG_CONFIG_HOME", z, 1);
            } else |_| {}
        } else _ = c.unsetenv("XDG_CONFIG_HOME");
        if (old_data_owned) |v| {
            if (alloc.dupeSentinel(u8, v, 0)) |z| {
                defer alloc.free(z);
                _ = c.setenv("XDG_DATA_HOME", z, 1);
            } else |_| {}
        } else _ = c.unsetenv("XDG_DATA_HOME");
    }

    installGtk4Override(io, "FakeTheme");
    const first = try cwd.readFileAlloc(io, dst_css, alloc, .limited(1024));
    defer alloc.free(first);
    try t.expectEqualStrings("/* fake gtk4 v1 */\n", first);
    const ast = try cwd.statFile(io, dst_assets, .{ .follow_symlinks = false });
    try t.expectEqual(std.Io.File.Kind.sym_link, ast.kind);

    // A second apply replaces the stylesheet and keeps the first one as the
    // one-time backup, so a later colour refresh can restore it if needed.
    try cwd.writeFile(io, .{ .sub_path = src_css, .data = "/* fake gtk4 v2 */\n" });
    installGtk4Override(io, "FakeTheme");
    const second = try cwd.readFileAlloc(io, dst_css, alloc, .limited(1024));
    defer alloc.free(second);
    try t.expectEqualStrings("/* fake gtk4 v2 */\n", second);
    const backup = try cwd.readFileAlloc(io, dst_backup, alloc, .limited(1024));
    defer alloc.free(backup);
    try t.expectEqualStrings("/* fake gtk4 v1 */\n", backup);
}

test "system-theming: qt palette previews" {
    const t = std.testing;
    const fusion = qtStyleColors("Fusion");
    try t.expect(fusion.valid);
    try t.expectApproxEqAbs(@as(f64, 0.55), fusion.accent[0], 1e-9);
    try t.expect(!qtStyleColors("not-a-style").valid);
    try t.expectEqual(@as(?[3]f64, .{ 1, 0, 0.5019607843137255 }), parseRgbTriplet("255,0,128"));
}

test "system-theming: layout-independent helpers" {
    const t = std.testing;
    try t.expect(normalizedEqual("Breeze Dark", "breeze-dark"));
    try t.expect(!normalizedEqual("Breeze", "Breeze Dark"));
    try t.expectEqual(@as(i32, 12), parseCssPx("12px"));
    try t.expectEqual(@as(i32, -1), parseCssPx("nope"));
}
