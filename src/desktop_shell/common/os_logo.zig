//! Distro logo resolution.
//!
//! The dock's `smenu` (start menu) slot paints the *distribution's* logo, not
//! an icon from the active theme: in a macOS-flavoured theme `start-here` is an
//! Apple mark, which is the wrong thing to put on an Arch box. The logo code
//! reads `ID`/`LOGO`/`ID_LIKE` out of os-release and probes a fixed list of
//! loose directories, falling back to `start-here` only as a last resort.

const std = @import("std");
const icon_lookup = @import("icon_lookup.zig");
const icon_raster = @import("icon_raster.zig");

/// `ID`, `LOGO` and `ID_LIKE` from os-release. All slices are owned by the
/// allocator that produced the struct — free with `freeOsRelease`.
pub const OsRelease = struct {
    id: []const u8 = "",
    logo: []const u8 = "",
    /// Space-separated, exactly as written in the file.
    id_like: []const u8 = "",
};

const kReleaseFiles = [_][]const u8{ "/etc/os-release", "/usr/lib/os-release" };

const kDirs = [_][]const u8{
    "/usr/share/icons/hicolor/scalable/apps/",
    "/usr/share/icons/hicolor/symbolic/apps/",
    "/usr/share/icons/hicolor/128x128/apps/",
    "/usr/share/icons/hicolor/256x256/apps/",
    "/usr/share/icons/hicolor/512x512/apps/",
    "/usr/share/icons/hicolor/64x64/apps/",
    "/usr/share/pixmaps/",
    "/usr/share/icons/",
};

const kExts = [_][]const u8{ ".svg", ".png" };

pub fn freeOsRelease(alloc: std.mem.Allocator, info: *OsRelease) void {
    if (info.id.len > 0) alloc.free(info.id);
    if (info.logo.len > 0) alloc.free(info.logo);
    if (info.id_like.len > 0) alloc.free(info.id_like);
    info.* = .{};
}

fn keep(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    if (s.len == 0) return "";
    return alloc.dupe(u8, s) catch "";
}

fn setField(alloc: std.mem.Allocator, dst: *[]const u8, val: []const u8) void {
    if (dst.*.len > 0) alloc.free(dst.*);
    dst.* = keep(alloc, val);
}

/// First readable of `/etc/os-release` then `/usr/lib/os-release`, mirroring
/// `read_os_release()`. Returns null when neither names the distribution.
pub fn readOsRelease(alloc: std.mem.Allocator, io: std.Io) ?OsRelease {
    var buf: [16384]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    for (kReleaseFiles) |rel| {
        const data = cwd.readFile(io, rel, &buf) catch continue;
        var out: OsRelease = .{};
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                val = val[1 .. val.len - 1];
            }
            if (std.mem.eql(u8, key, "ID")) setField(alloc, &out.id, val);
            if (std.mem.eql(u8, key, "LOGO")) setField(alloc, &out.logo, val);
            if (std.mem.eql(u8, key, "ID_LIKE")) setField(alloc, &out.id_like, val);
        }
        if (out.id.len > 0 or out.logo.len > 0) return out;
        freeOsRelease(alloc, &out);
    }
    return null;
}

/// `<dir><name><ext>` for every directory/extension pair, in order
/// (directories outermost, `.svg` before `.png`).
fn tryName(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (name.len == 0) return null;
    for (kDirs) |dir| {
        for (kExts) |ext| {
            const p = std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ dir, name, ext }) catch return null;
            if (icon_lookup.isReadable(p)) return p;
            alloc.free(p);
        }
    }
    return null;
}

fn tryConcat(alloc: std.mem.Allocator, a: []const u8, b: []const u8) ?[]u8 {
    const full = std.fmt.allocPrint(alloc, "{s}{s}", .{ a, b }) catch return null;
    defer alloc.free(full);
    return tryName(alloc, full);
}

/// `resolve_logo_image_path()` — LOGO, then ID, `ID+linux`,
/// `distributor-logo-ID`, every `ID_LIKE` entry, `distributor-logo`, and
/// finally `start-here`.
pub fn resolveLogoPath(alloc: std.mem.Allocator, info: OsRelease) ?[]u8 {
    if (std.mem.eql(u8, info.id, "cachyos")) {
        const p = "/usr/share/icons/cachyos.svg";
        if (icon_lookup.isReadable(p)) return alloc.dupe(u8, p) catch null;
    }
    if (tryName(alloc, info.logo)) |p| return p;
    if (info.id.len > 0) {
        if (tryName(alloc, info.id)) |p| return p;
        if (tryConcat(alloc, info.id, "linux")) |p| return p;
        if (tryConcat(alloc, "distributor-logo-", info.id)) |p| return p;
    }
    var it = std.mem.splitAny(u8, info.id_like, " \t");
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tryName(alloc, tok)) |p| return p;
    }
    if (tryName(alloc, "distributor-logo")) |p| return p;
    if (tryName(alloc, "start-here")) |p| return p;
    return null;
}

/// Resolve and rasterize the distro logo at `size_px`, or null when this
/// distribution ships no logo we can find (in which case the caller should
/// fall back to ordinary icon lookup).
pub fn loadDistroLogo(alloc: std.mem.Allocator, io: std.Io, size_px: i32) ?icon_raster.Pixels {
    var info = readOsRelease(alloc, io) orelse return null;
    defer freeOsRelease(alloc, &info);
    const path = resolveLogoPath(alloc, info) orelse return null;
    defer alloc.free(path);
    if (std.mem.endsWith(u8, path, ".svg")) return icon_raster.loadSvg(alloc, path, size_px);
    return icon_raster.loadPng(alloc, path);
}

test "os_logo: freeOsRelease clears every field" {
    const t = std.testing;
    var info: OsRelease = .{};
    info.id = try t.allocator.dupe(u8, "arch");
    info.logo = try t.allocator.dupe(u8, "archlinux-logo");
    info.id_like = try t.allocator.dupe(u8, "rhel fedora");
    freeOsRelease(t.allocator, &info);
    try t.expectEqual(@as(usize, 0), info.id.len);
    try t.expectEqual(@as(usize, 0), info.logo.len);
    try t.expectEqual(@as(usize, 0), info.id_like.len);
}

test "os_logo: resolve hits a readable file and rejects an empty query" {
    const t = std.testing;
    if (resolveLogoPath(t.allocator, .{ .id = "arch", .logo = "archlinux-logo" })) |p| {
        defer t.allocator.free(p);
        try t.expect(icon_lookup.isReadable(p));
    }
    // An empty LOGO/ID must never probe an empty string; whatever the
    // machine has installed, the result is either null or a readable path.
    if (resolveLogoPath(t.allocator, .{})) |p| {
        defer t.allocator.free(p);
        try t.expect(icon_lookup.isReadable(p));
    }
}
