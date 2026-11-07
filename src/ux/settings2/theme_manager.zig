//! User colour themes.
//!
//! Port of the C++ `theme_manager.cpp`: user themes live as flat TOML files
//! under `$XDG_DATA_HOME/event-horizon/themes` (falling back to
//! `~/.local/share/event-horizon/themes`). Each file carries a name/source/
//! variant plus the 16 palette roles as `role_r/g/b` floats. Built-in presets
//! stay read-only in `theme_data.zig`; only the scan/load/save helpers live
//! here, so the Color Themes page stays free of file IO.
//!
//! Everything is best-effort: a missing directory yields an empty list and a
//! malformed file is skipped rather than failing the page.

const std = @import("std");
const theme_data = @import("theme_data.zig");
const toml = @import("../../config/toml.zig");

pub const UserTheme = struct {
    name: []const u8 = "",
    source: []const u8 = "custom",
    variant: []const u8 = "",
    /// Absolute path the theme was read from (owned by the same allocation
    /// as the strings above).
    file_path: []const u8 = "",
    palette: theme_data.Palette = .{},

    pub fn deinit(self: *UserTheme, alloc: std.mem.Allocator) void {
        if (self.name.len > 0) alloc.free(self.name);
        if (self.source.len > 0) alloc.free(self.source);
        if (self.variant.len > 0) alloc.free(self.variant);
        if (self.file_path.len > 0) alloc.free(self.file_path);
        self.* = .{};
    }
};

/// `$XDG_DATA_HOME/event-horizon/themes`, else `~/.local/share/...`.
pub fn themeDirectory(alloc: std.mem.Allocator) ?[]u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |xdg_raw| {
        const xdg = std.mem.span(xdg_raw);
        if (xdg.len > 0) return std.fmt.allocPrint(alloc, "{s}/event-horizon/themes", .{xdg}) catch null;
    }
    if (std.c.getenv("HOME")) |home_raw| {
        const home = std.mem.span(home_raw);
        if (home.len > 0) return std.fmt.allocPrint(alloc, "{s}/.local/share/event-horizon/themes", .{home}) catch null;
    }
    return alloc.dupe(u8, "/tmp/event-horizon/themes") catch null;
}

const role_keys = [_][]const u8{
    "primary",
    "on_primary",
    "secondary",
    "on_secondary",
    "tertiary",
    "on_tertiary",
    "error",
    "on_error",
    "surface",
    "on_surface",
    "surface_variant",
    "on_surface_variant",
    "outline",
    "shadow",
    "hover",
    "on_hover",
};

const PaletteField = enum {
    primary,
    on_primary,
    secondary,
    on_secondary,
    tertiary,
    on_tertiary,
    err,
    on_error,
    surface,
    on_surface,
    surface_variant,
    on_surface_variant,
    outline,
    shadow,
    hover,
    on_hover,
};

const role_fields = [_]PaletteField{
    .primary,
    .on_primary,
    .secondary,
    .on_secondary,
    .tertiary,
    .on_tertiary,
    .err,
    .on_error,
    .surface,
    .on_surface,
    .surface_variant,
    .on_surface_variant,
    .outline,
    .shadow,
    .hover,
    .on_hover,
};

fn valueString(v: toml.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn valueFloat(v: toml.Value) ?f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// Parse one theme file body. `path` is borrowed; the returned strings are
/// owned by `alloc` (use `UserTheme.deinit`).
pub fn parseUserTheme(alloc: std.mem.Allocator, text: []const u8, path: []const u8) !UserTheme {
    var doc = toml.parse(alloc, text) catch return error.BadTheme;
    defer doc.deinit();

    var out: UserTheme = .{ .source = "" };
    errdefer out.deinit(alloc);

    if (doc.get("name")) |v| {
        if (valueString(v)) |s| out.name = try alloc.dupe(u8, s);
    }
    if (doc.get("source")) |v| {
        if (valueString(v)) |s| out.source = try alloc.dupe(u8, s);
    }
    if (out.source.len == 0) out.source = try alloc.dupe(u8, "custom");
    if (doc.get("variant")) |v| {
        if (valueString(v)) |s| out.variant = try alloc.dupe(u8, s);
    }
    out.file_path = try alloc.dupe(u8, path);

    inline for (role_keys, role_fields) |key, field| {
        var buf: [64]u8 = undefined;
        inline for ([_][]const u8{ "r", "g", "b" }, 0..) |suffix, ch| {
            const name = std.fmt.bufPrint(&buf, "{s}_{s}", .{ key, suffix }) catch "";
            if (name.len > 0) {
                if (doc.get(name)) |v| {
                    if (valueFloat(v)) |f| {
                        @field(out.palette, @tagName(field))[ch] = std.math.clamp(f, 0.0, 1.0);
                    }
                }
            }
        }
    }
    return out;
}

/// Read and parse one theme file. Returns `error.FileNotFound`-style errors
/// from the IO layer and `error.BadTheme` for malformed TOML.
pub fn loadThemeFromFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !UserTheme {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20));
    defer alloc.free(text);
    return parseUserTheme(alloc, text, path);
}

/// Scan the user theme directory. The returned slice and its strings are
/// owned by `alloc`; free with `freeUserThemes`.
pub fn scanUserThemes(alloc: std.mem.Allocator, io: std.Io) ![]UserTheme {
    const dir_path = themeDirectory(alloc) orelse return &.{};
    defer alloc.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var list: std.ArrayList(UserTheme) = .empty;
    errdefer freeUserThemes(alloc, list.items);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry.name });
        defer alloc.free(full);
        const theme = loadThemeFromFile(alloc, io, full) catch continue;
        try list.append(alloc, theme);
    }
    std.mem.sort(UserTheme, list.items, {}, struct {
        fn lessThan(_: void, a: UserTheme, b: UserTheme) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return list.toOwnedSlice(alloc) catch &.{};
}

pub fn freeUserThemes(alloc: std.mem.Allocator, themes: []UserTheme) void {
    for (themes) |*t| t.deinit(alloc);
    if (themes.len > 0) alloc.free(themes);
}

/// Serialize a theme as a flat TOML file and write it atomically.
pub fn saveThemeToFile(alloc: std.mem.Allocator, io: std.Io, theme: UserTheme) !void {
    const dir_path = themeDirectory(alloc) orelse return error.NoHome;
    defer alloc.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    const dir = std.Io.Dir.cwd();

    var name_buf: [256]u8 = undefined;
    const stem = sanitizeFileStem(&name_buf, theme.name);
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.toml", .{ dir_path, stem });
    defer alloc.free(path);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.__thtmp", .{path});
    defer alloc.free(tmp);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("# Event Horizon color theme\n\n");
    const source = if (theme.source.len > 0) theme.source else "custom";
    try w.print("name = \"{s}\"\nsource = \"{s}\"\nvariant = \"{s}\"\n", .{ theme.name, source, theme.variant });
    inline for (role_keys, role_fields) |key, field| {
        const rgb = @field(theme.palette, @tagName(field));
        try w.print("{s}_r = {d}\n{s}_g = {d}\n{s}_b = {d}\n", .{ key, rgb[0], key, rgb[1], key, rgb[2] });
    }
    try dir.writeFile(io, .{ .sub_path = tmp, .data = aw.written() });
    dir.rename(tmp, dir, path, io) catch |e| {
        dir.deleteFile(io, tmp) catch {};
        return e;
    };
}

fn sanitizeFileStem(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (n >= buf.len) break;
        buf[n] = if (ch == '/' or ch == '\\') '_' else ch;
        n += 1;
    }
    if (n == 0) {
        @memcpy(buf[0.."unnamed".len], "unnamed");
        return buf[0.."unnamed".len];
    }
    return buf[0..n];
}

/// Delete the theme file behind a scanned entry.
pub fn deleteThemeFile(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().deleteFile(io, path) catch return false;
    return true;
}

pub const Manager = struct {
    alloc: std.mem.Allocator,
    customs: std.ArrayList(UserTheme),
    active_name: []const u8 = "",
    brightness_pct: i32 = 100,
    contrast_pct: i32 = 100,
    vibrance_pct: i32 = 100,

    pub fn init(alloc: std.mem.Allocator) Manager {
        return .{ .alloc = alloc, .customs = .empty };
    }

    pub fn deinit(self: *Manager) void {
        freeUserThemes(self.alloc, self.customs.items);
        self.customs.deinit(self.alloc);
    }

    pub fn addCustom(self: *Manager, name: []const u8, palette: theme_data.Palette) !void {
        for (self.customs.items) |*c| {
            if (std.mem.eql(u8, c.name, name)) {
                c.palette = palette;
                return;
            }
        }
        try self.customs.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .source = try self.alloc.dupe(u8, "custom"),
            .palette = palette,
        });
    }

    pub fn removeCustom(self: *Manager, name: []const u8) bool {
        for (self.customs.items, 0..) |*c, i| {
            if (std.mem.eql(u8, c.name, name)) {
                c.deinit(self.alloc);
                _ = self.customs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn resolve(self: *const Manager, name: []const u8) ?theme_data.Palette {
        for (self.customs.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.palette;
        }
        if (theme_data.findPreset(name)) |p| return p.palette;
        return null;
    }

    pub fn adjustChannel(v: f32, brightness_pct: i32, contrast_pct: i32) f32 {
        const b: f32 = @as(f32, @floatFromInt(brightness_pct)) / 100.0;
        const c: f32 = @as(f32, @floatFromInt(contrast_pct)) / 100.0;
        return @min(1, @max(0, (v - 0.5) * c + 0.5 * b));
    }
};

test "settings-theme-manager: add/resolve/remove" {
    const t = std.testing;
    var m = Manager.init(t.allocator);
    defer m.deinit();
    try m.addCustom("Mine", .{});
    try t.expect(m.resolve("Mine") != null);
    try t.expect(m.resolve("Catppuccin Mocha") != null);
    try t.expect(m.removeCustom("Mine"));
    try t.expect(!m.removeCustom("Mine"));
    try t.expectEqual(@as(f32, 0.5), Manager.adjustChannel(0.5, 100, 100));
}

test "settings-theme-manager: save helpers are type-checked" {
    // Keeping the writer reachable from tests forces semantic analysis even
    // though the Color Themes page only reads user themes.
    _ = &saveThemeToFile;
    _ = &deleteThemeFile;
    _ = &themeDirectory;
}

test "settings-theme-manager: parse a flat user theme file" {
    const t = std.testing;
    const text =
        \\name = "My Theme"
        \\source = "custom"
        \\variant = "dark"
        \\primary_r = 0.1
        \\primary_g = 0.2
        \\primary_b = 0.3
        \\surface_r = 0.4
        \\surface_g = 0.5
        \\surface_b = 0.6
        \\on_hover_b = 0.7
    ;
    var ut = try parseUserTheme(t.allocator, text, "/tmp/x.toml");
    defer ut.deinit(t.allocator);
    try t.expectEqualStrings("My Theme", ut.name);
    try t.expectEqualStrings("custom", ut.source);
    try t.expectEqualStrings("/tmp/x.toml", ut.file_path);
    try t.expectApproxEqAbs(@as(f32, 0.2), ut.palette.primary[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.6), ut.palette.surface[2], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.7), ut.palette.on_hover[2], 1e-6);
    // Unspecified roles keep the palette defaults.
    try t.expectApproxEqAbs(@as(f32, 1.0), ut.palette.on_surface[0], 1e-6);
}
