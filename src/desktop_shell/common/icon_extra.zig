//! Icon artwork the theme chain cannot name.
//!
//! Two kinds of launcher routinely ship art with no file in any icon theme:
//!
//! * AppImages. A Type 2 AppImage is a squashfs image with a runtime prefix;
//!   its `.DirIcon` (and a `.desktop` file whose `Icon=` names the art) lives
//!   inside that image, not under `$XDG_DATA_DIRS/icons`. AppImage integration
//!   tools normally copy it out, but a bare download has no desktop entry at
//!   all, so a window whose app id matches the file would paint a placeholder.
//! * Steam games, and especially Proton titles. A running game reports
//!   `steam_app_<appid>` (or a launcher exports `steam_icon_<appid>`); the
//!   client's own art cache carries a small square icon per app id, and a
//!   Windows `.exe` carries its icon in PE resources when the cache is cold.
//!
//! This module turns either into a filesystem path that the normal
//! `icon_cache` decoder can read (PNG/SVG/JPEG), materializing a PNG in the
//! user cache when the source is an embedded icon resource. Nothing here is
//! theme-specific: a theme switch must not throw an extracted icon away.
//!
//! AppImage extraction executes the AppImage's own runtime with
//! `--appimage-extract`, exactly what a user asking for its icon would run.
//! It is bounded by a timeout, only attempted for a running AppImage (found
//! through `/proc/<pid>/environ`) or a file the caller named, and every
//! extracted artefact is cached so the runtime only runs once.

const std = @import("std");
const icon_raster = @import("icon_raster.zig");
const decode = @import("../../wallpaper/decode.zig");
const paths = @import("paths.zig");
const logz = @import("../../logz.zig");

extern fn eh_write_png(path: [*:0]const u8, w: c_int, h: c_int, data: [*]const u8, stride: c_int, exclusive: c_int) c_int;

const k_cache_leaf = "icon-sources";
const k_max_source_bytes = 16 * 1024 * 1024;
const k_max_pe_resource = 64 * 1024 * 1024;
const k_max_exe_header = 1 * 1024 * 1024;
const k_extract_timeout_ms: u64 = 8_000;

/// Extensions an extracted AppImage icon may carry once copied to the cache.
const k_icon_exts = [_][]const u8{ ".png", ".svg", ".jpg", ".jpeg", ".webp", ".xpm" };

const c_stdlib = @import("c_stdlib");

fn getenv(key: [:0]const u8) ?[]const u8 {
    if (c_stdlib.getenv(key)) |p| return std.mem.span(p);
    return null;
}

/// A cache directory shared by every component (`$XDG_CACHE_HOME/Event-Horizon`
/// or `~/.cache/Event-Horizon`), with the icon-source leaf appended.
fn cacheDir(gpa: std.mem.Allocator) ?[]u8 {
    const root = paths.cacheDir(gpa, getenv("XDG_CACHE_HOME"), getenv("HOME")) catch return null;
    defer gpa.free(root);
    return std.fs.path.join(gpa, &.{ root, k_cache_leaf }) catch null;
}

fn ensureCacheDir(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const dir = cacheDir(gpa) orelse return null;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {
        gpa.free(dir);
        return null;
    };
    return dir;
}

fn hashKey(buf: []u8, key: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x}", .{std.hash.Wyhash.hash(0, key)}) catch "0";
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn readBounded(gpa: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(limit)) catch null;
}

/// procfs files report `st_size = 0`, so `readFileAlloc` returns an empty
/// buffer. Read in chunks until EOF instead, as `/proc/<pid>/environ` has no
/// position to seek to and no advertised length.
fn readProcFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ?[]u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [16 * 1024]u8 = undefined;
    while (out.items.len < limit) {
        const want = @min(buf.len, limit - out.items.len);
        const n = f.readPositionalAll(io, buf[0..want], @intCast(out.items.len)) catch {
            out.deinit(gpa);
            return null;
        };
        if (n == 0) break;
        out.appendSlice(gpa, buf[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
        if (n < want) break;
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn isDir(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

// -- public entry point ----------------------------------------------------

/// Best artwork path for `app_id`, or null when this is not one of the extra
/// sources. The returned slice is owned by the caller. `allow_run` permits
/// AppImage extraction and PE resource extraction; a paint-path caller that
/// must never block passes false, which still finds already-cached artwork and
/// the Steam library cache (a cheap directory scan).
pub fn pathFor(gpa: std.mem.Allocator, io: std.Io, app_id: []const u8, allow_run: bool) ?[]u8 {
    if (app_id.len == 0) return null;

    // A direct path to an AppImage, or a desktop file that named one as its
    // `Icon=` (absolute paths are legal there).
    if (std.fs.path.isAbsolute(app_id)) {
        if (isAppImagePath(app_id)) return appImage(gpa, io, app_id, allow_run);
        return null;
    }

    if (parseSteamAppId(app_id)) |appid| {
        if (steamIcon(gpa, io, appid, allow_run)) |p| return p;
        // Fall through: an old client may have installed a real theme icon
        // under the steam_icon_<id> name after all.
    }

    if (isAppImagePath(app_id)) return appImage(gpa, io, app_id, allow_run);

    // The window class is usually the app's own name, not the AppImage file
    // name, so look for a running AppImage whose name normalizes to it.
    return appImageByAppId(gpa, io, app_id, allow_run);
}

/// The non-blocking subset of `pathFor`: Steam library art (a directory read)
/// and icons already extracted to the cache. Never scans `/proc`, never runs
/// an AppImage, so paint paths can call it. Returns an owned path.
pub fn cheapPathFor(gpa: std.mem.Allocator, io: std.Io, app_id: []const u8) ?[]u8 {
    if (app_id.len == 0) return null;
    if (std.fs.path.isAbsolute(app_id)) {
        if (!isAppImagePath(app_id)) return null;
        var hbuf: [32]u8 = undefined;
        return cachedAppImageIcon(gpa, io, hashKey(&hbuf, app_id));
    }
    if (parseSteamAppId(app_id)) |appid| return steamIcon(gpa, io, appid, false);
    return null;
}

fn isAppImagePath(s: []const u8) bool {
    const base = std.fs.path.basename(s);
    return std.ascii.endsWithIgnoreCase(base, ".appimage");
}

// -- Steam ----------------------------------------------------------------

fn parseSteamAppId(name: []const u8) ?u32 {
    const lower_ok = if (std.ascii.startsWithIgnoreCase(name, "steam_app_"))
        name["steam_app_".len..]
    else if (std.ascii.startsWithIgnoreCase(name, "steam_icon_"))
        name["steam_icon_".len..]
    else
        return null;
    if (lower_ok.len == 0 or lower_ok.len > 10) return null;
    const id = std.fmt.parseInt(u32, lower_ok, 10) catch return null;
    if (id == 0) return null;
    return id;
}

fn steamIcon(gpa: std.mem.Allocator, io: std.Io, appid: u32, allow_run: bool) ?[]u8 {
    var idbuf: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&idbuf, "{d}", .{appid}) catch return null;

    // 1. The client's library cache: `<root>/appcache/librarycache/<appid>/`.
    //    Modern clients keep the square icon as a 40-hex-named JPEG beside the
    //    wide `logo.png`; older ones used `<appid>_icon.jpg` at the app root.
    var clients: std.ArrayListUnmanaged([]u8) = .empty;
    defer freeList(gpa, &clients);
    steamClientRoots(gpa, io, &clients);
    for (clients.items) |root| {
        if (steamLibraryCacheIcon(gpa, io, root, id)) |p| return p;
    }

    if (!allow_run) return null;

    // 2. Cold cache: read the installed game's main `.exe` and pull its PE
    //    icon resource. Proton installs are Windows binaries, and that icon is
    //    exactly what the desktop shortcut would show under Windows.
    var libs: std.ArrayListUnmanaged([]u8) = .empty;
    defer freeList(gpa, &libs);
    steamLibraryRoots(gpa, io, &libs);
    for (libs.items) |lib| {
        if (steamExeIcon(gpa, io, lib, appid, id)) |p| return p;
    }
    return null;
}

fn steamClientRoots(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayListUnmanaged([]u8)) void {
    const home = getenv("HOME");
    const xdg = getenv("XDG_DATA_HOME");
    if (xdg) |d| addRoot(gpa, io, out, &.{ d, "Steam" });
    if (home) |h| {
        addRoot(gpa, io, out, &.{ h, ".local", "share", "Steam" });
        addRoot(gpa, io, out, &.{ h, ".steam", "steam" });
        addRoot(gpa, io, out, &.{ h, ".steam", "root" });
    }
}

fn steamLibraryRoots(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayListUnmanaged([]u8)) void {
    steamClientRoots(gpa, io, out);
    // `libraryfolders.vdf` names extra library roots; the client root itself
    // is already in the list and is a library too.
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        var vdf_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const p1 = std.fmt.bufPrint(&vdf_path_buf, "{s}/steamapps/libraryfolders.vdf", .{out.items[i]}) catch continue;
        const data = readBounded(gpa, io, p1, 512 * 1024) orelse blk: {
            var pbuf: [std.fs.max_path_bytes]u8 = undefined;
            const p2 = std.fmt.bufPrint(&pbuf, "{s}/config/libraryfolders.vdf", .{out.items[i]}) catch continue;
            break :blk readBounded(gpa, io, p2, 512 * 1024);
        };
        if (data) |d| {
            defer gpa.free(d);
            collectVdfPaths(gpa, io, out, d);
        }
    }
}

fn collectVdfPaths(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayListUnmanaged([]u8), data: []const u8) void {
    var it = VdfTokens{ .data = data };
    while (it.next()) |tok| {
        if (!std.mem.eql(u8, tok, "path")) continue;
        const value = it.next() orelse return;
        if (value.len == 0 or value[0] != '/') continue;
        addRoot(gpa, io, out, &.{value});
    }
}

fn addRoot(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayListUnmanaged([]u8), parts: []const []const u8) void {
    const p = std.fs.path.join(gpa, parts) catch return;
    if (!isDir(io, p)) {
        gpa.free(p);
        return;
    }
    for (out.items) |x| {
        if (std.mem.eql(u8, x, p)) {
            gpa.free(p);
            return;
        }
    }
    out.append(gpa, p) catch gpa.free(p);
}

/// One ordered token from a Valve KeyValues file. Quoted strings are
/// unescaped in place (the caller's buffer is borrowed, not owned).
const VdfTokens = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *VdfTokens) ?[]const u8 {
        while (self.pos < self.data.len) {
            const ch = self.data[self.pos];
            if (ch == '/' and self.pos + 1 < self.data.len and self.data[self.pos + 1] == '/') {
                while (self.pos < self.data.len and self.data[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (ch == '"') {
                self.pos += 1;
                const start = self.pos;
                while (self.pos < self.data.len and self.data[self.pos] != '"') self.pos += 1;
                const tok = self.data[start..self.pos];
                if (self.pos < self.data.len) self.pos += 1;
                return tok;
            }
            if (ch == '{' or ch == '}') {
                self.pos += 1;
                continue;
            }
            if (std.ascii.isWhitespace(ch)) {
                self.pos += 1;
                continue;
            }
            const start = self.pos;
            while (self.pos < self.data.len and !std.ascii.isWhitespace(self.data[self.pos]) and
                self.data[self.pos] != '"' and self.data[self.pos] != '{' and self.data[self.pos] != '}') self.pos += 1;
            return self.data[start..self.pos];
        }
        return null;
    }
};

/// Best icon in `<root>/appcache/librarycache/<id>/`. The square 32px icon is
/// what Valve paints in window lists; a `logo.png` is a wide wordmark and is
/// only a last resort. Returns an owned path to the original file, since the
/// decoders read PNG, JPEG and WebP directly.
fn steamLibraryCacheIcon(gpa: std.mem.Allocator, io: std.Io, root: []const u8, id: []const u8) ?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&path_buf, "{s}/appcache/librarycache/{s}", .{ root, id }) catch return null;
    if (isDir(io, dir_path)) {
        if (bestImageInDir(gpa, io, dir_path)) |p| return p;
    }
    // Flat legacy layout.
    const jpg = std.fmt.bufPrint(&path_buf, "{s}/appcache/librarycache/{s}_icon.jpg", .{ root, id }) catch return null;
    if (fileExists(io, jpg)) return gpa.dupe(u8, jpg) catch null;
    const png = std.fmt.bufPrint(&path_buf, "{s}/appcache/librarycache/{s}_icon.png", .{ root, id }) catch return null;
    if (fileExists(io, png)) return gpa.dupe(u8, png) catch null;
    return null;
}

const ImageCandidate = struct {
    path: []u8,
    score: i32,
};

fn bestImageInDir(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best: ?ImageCandidate = null;
    defer if (best) |b| gpa.free(b.path);

    var it = dir.iterate();
    var seen: usize = 0;
    while (it.next(io) catch null) |e| {
        if (seen >= 64) break;
        if (e.kind != .file and e.kind != .sym_link) continue;
        if (!isImageName(e.name)) continue;
        seen += 1;

        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir_path, e.name }) catch continue;
        const dim = imageSize(io, p) orelse continue;
        const square_penalty: i32 = @intCast(@abs(dim.w - dim.h));
        const ideal: i32 = @intCast(@abs(@as(i64, @intCast(dim.w)) - 32));
        var score: i32 = 200 - square_penalty * 4 - ideal;
        if (dim.w < 16 or dim.h < 16) score -= 60;
        if (std.ascii.startsWithIgnoreCase(e.name, "logo")) score -= 120;
        if (containsIgnoreCase(e.name, "hero")) score -= 200;
        if (score <= 0) continue;
        if (best == null or score > best.?.score) {
            const owned = gpa.dupe(u8, p) catch continue;
            if (best) |b| gpa.free(b.path);
            best = .{ .path = owned, .score = score };
        }
    }
    if (best) |b| {
        const out = b.path;
        best = null;
        return out;
    }
    return null;
}

fn isImageName(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".png") or
        std.ascii.endsWithIgnoreCase(name, ".jpg") or
        std.ascii.endsWithIgnoreCase(name, ".jpeg") or
        std.ascii.endsWithIgnoreCase(name, ".webp");
}

const Dim = struct { w: i32, h: i32 };

/// Width/height for the two formats Steam's cache uses, without decoding.
fn imageSize(io: std.Io, path: []const u8) ?Dim {
    var buf: [4096]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, &buf, 0) catch return null;
    const d = buf[0..n];
    if (d.len >= 24 and std.mem.eql(u8, d[0..8], "\x89PNG\r\n\x1a\n")) {
        const w = std.mem.readInt(u32, d[16..20], .big);
        const h = std.mem.readInt(u32, d[20..24], .big);
        return .{ .w = @intCast(w), .h = @intCast(h) };
    }
    if (d.len >= 4 and d[0] == 0xFF and d[1] == 0xD8) return jpegSize(d);
    return null;
}

fn jpegSize(d: []const u8) ?Dim {
    var i: usize = 2;
    while (i + 9 < d.len) {
        if (d[i] != 0xFF) {
            i += 1;
            continue;
        }
        const marker = d[i + 1];
        i += 2;
        // SOF0..SOF15 minus DHT/JPG/DAC markers.
        if (marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC) {
            if (i + 7 > d.len) return null;
            const h = (@as(u32, d[i + 3]) << 8) | d[i + 4];
            const w = (@as(u32, d[i + 5]) << 8) | d[i + 6];
            return .{ .w = @intCast(w), .h = @intCast(h) };
        }
        if (i + 2 > d.len) return null;
        const len = (@as(usize, d[i]) << 8) | d[i + 1];
        if (len < 2) return null;
        i += len;
    }
    return null;
}

fn steamExeIcon(gpa: std.mem.Allocator, io: std.Io, lib: []const u8, appid: u32, id: []const u8) ?[]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const manifest = std.fmt.bufPrint(&pbuf, "{s}/steamapps/appmanifest_{s}.acf", .{ lib, id }) catch return null;
    const data = readBounded(gpa, io, manifest, 256 * 1024) orelse return null;
    defer gpa.free(data);
    const installdir = vdfValue(data, "installdir") orelse return null;
    if (installdir.len == 0 or std.mem.indexOfAny(u8, installdir, "/\\") != null) return null;

    var gbuf: [std.fs.max_path_bytes]u8 = undefined;
    const game_dir = std.fmt.bufPrint(&gbuf, "{s}/steamapps/common/{s}", .{ lib, installdir }) catch return null;
    if (!isDir(io, game_dir)) return null;

    var found: ?ExeHit = .{ .path = null, .score = 0, .size = 0 };
    scanGameExes(gpa, io, game_dir, installdir, 0, &found);
    defer if (found) |f| if (f.path) |p| gpa.free(p);

    const f = found orelse return null;
    const exe_path = f.path orelse return null;
    const key = std.fmt.allocPrint(gpa, "pe:{s}:{d}", .{ exe_path, appid }) catch return null;
    defer gpa.free(key);
    return extractPeIcon(gpa, io, exe_path, key);
}

const ExeHit = struct { path: ?[]u8, score: i32, size: u64 };

fn scanGameExes(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    installdir: []const u8,
    depth: u32,
    best: *?ExeHit,
) void {
    if (depth > 3) return;
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    var guard: usize = 0;
    while (it.next(io) catch null) |e| {
        guard += 1;
        if (guard > 4096) return;
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir_path, e.name }) catch continue;
        if (e.kind == .directory) {
            scanGameExes(gpa, io, p, installdir, depth + 1, best);
            continue;
        }
        if (e.kind != .file and e.kind != .sym_link) continue;
        if (!std.ascii.endsWithIgnoreCase(e.name, ".exe")) continue;
        if (isExeNoise(e.name)) continue;
        const st = cwd.statFile(io, p, .{}) catch continue;
        var score: i32 = 0;
        if (containsIgnoreCase(e.name, installdir)) score += 100;
        const b: ExeHit = best.* orelse .{ .path = null, .score = 0, .size = 0 };
        if (score > b.score or (score == b.score and st.size > b.size)) {
            const owned = gpa.dupe(u8, p) catch continue;
            if (b.path) |old| gpa.free(old);
            best.* = .{ .path = owned, .score = score, .size = st.size };
        }
    }
}

fn isExeNoise(name: []const u8) bool {
    const noise = [_][]const u8{
        "crashreport", "crashhandler", "crashpad",      "unins",    "installer",  "dxsetup", "dxwebsetup",
        "vcredist",    "redist",       "easyanticheat", "battleye", "steamworks", "setup",   "helper",
    };
    for (noise) |n| if (containsIgnoreCase(name, n)) return true;
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn vdfValue(data: []const u8, key: []const u8) ?[]const u8 {
    var it = VdfTokens{ .data = data };
    while (it.next()) |tok| {
        if (!std.mem.eql(u8, tok, key)) continue;
        return it.next();
    }
    return null;
}

// -- AppImage -------------------------------------------------------------

fn appImageByAppId(gpa: std.mem.Allocator, io: std.Io, app_id: []const u8, allow_run: bool) ?[]u8 {
    // A running AppImage exports its own path as `APPIMAGE`. Matching that is
    // how a window class that is only the program name finds the file.
    if (findRunningAppImage(gpa, io, app_id)) |path| {
        defer gpa.free(path);
        return appImage(gpa, io, path, allow_run);
    }
    if (!allow_run) return null;
    if (findAppImageInDirs(gpa, io, app_id)) |path| {
        defer gpa.free(path);
        return appImage(gpa, io, path, allow_run);
    }
    return null;
}

fn findRunningAppImage(gpa: std.mem.Allocator, io: std.Io, app_id: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    var proc = cwd.openDir(io, "/proc", .{ .iterate = true }) catch return null;
    defer proc.close(io);
    var it = proc.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        if (e.name.len == 0 or !std.ascii.isDigit(e.name[0])) continue;
        var ebuf: [std.fs.max_path_bytes]u8 = undefined;
        const environ = std.fmt.bufPrint(&ebuf, "/proc/{s}/environ", .{e.name}) catch continue;
        const data = readProcFile(gpa, io, environ, 256 * 1024) orelse continue;
        defer gpa.free(data);
        var appimage_path: ?[]const u8 = null;
        var appdir: ?[]const u8 = null;
        var iter = std.mem.splitScalar(u8, data, 0);
        while (iter.next()) |item| {
            if (std.mem.startsWith(u8, item, "APPIMAGE=")) {
                appimage_path = item["APPIMAGE=".len..];
            } else if (std.mem.startsWith(u8, item, "APPDIR=")) {
                appdir = item["APPDIR=".len..];
            }
        }
        const path = appimage_path orelse continue;
        if (!isAppImagePath(path)) continue;
        if (appImageStemMatches(app_id, path)) return gpa.dupe(u8, path) catch null;
        if (appdir) |d| {
            if (desktopDirMatches(gpa, io, d, app_id)) return gpa.dupe(u8, path) catch null;
        }
    }
    return null;
}

/// A window class is often the reverse-DNS id from the image's desktop file
/// (`io.github.zortos293.lichii`) rather than the file name
/// (`lichii-linux-x86_64.AppImage`). A running AppImage exposes its mounted
/// root as `APPDIR`, so the desktop entry's `Icon=` and `StartupWMClass=`
/// identify it without another extraction.
fn desktopDirMatches(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, app_id: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    var guard: usize = 0;
    while (it.next(io) catch null) |e| {
        guard += 1;
        if (guard > 32) break;
        if (!std.ascii.endsWithIgnoreCase(e.name, ".desktop")) continue;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, e.name }) catch continue;
        const data = readBounded(gpa, io, p, 128 * 1024) orelse continue;
        defer gpa.free(data);
        if (desktopDataMatches(data, app_id)) return true;
    }
    return false;
}

fn desktopDataMatches(data: []const u8, app_id: []const u8) bool {
    var section_ok = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            section_ok = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!section_ok) continue;
        const v = if (std.mem.startsWith(u8, line, "Icon="))
            std.mem.trim(u8, line["Icon=".len..], " \t\r")
        else if (std.mem.startsWith(u8, line, "StartupWMClass="))
            std.mem.trim(u8, line["StartupWMClass=".len..], " \t\r")
        else
            continue;
        if (v.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(v, app_id)) return true;
    }
    return false;
}

fn findAppImageInDirs(gpa: std.mem.Allocator, io: std.Io, app_id: []const u8) ?[]u8 {
    const home = getenv("HOME") orelse return null;
    const xdg = getenv("XDG_DATA_HOME");
    var dirs_buf: [8][]u8 = undefined;
    var n: usize = 0;
    defer for (dirs_buf[0..n]) |d| gpa.free(d);

    const relative = [_][]const []const u8{
        &.{"Applications"},
        &.{"AppImages"},
        &.{"Downloads"},
        &.{"Desktop"},
        &.{"bin"},
        &.{ ".local", "bin" },
    };
    for (relative) |r| {
        if (n >= dirs_buf.len) break;
        var parts: [4][]const u8 = undefined;
        parts[0] = home;
        @memcpy(parts[1 .. 1 + r.len], r);
        dirs_buf[n] = std.fs.path.join(gpa, parts[0 .. 1 + r.len]) catch continue;
        n += 1;
    }
    if (xdg) |d| {
        if (n < dirs_buf.len) {
            if (std.fs.path.join(gpa, &.{ d, "AppImages" })) |p| {
                dirs_buf[n] = p;
                n += 1;
            } else |_| {}
        }
    }

    const cwd = std.Io.Dir.cwd();
    var best: ?[]u8 = null;
    defer if (best) |b| gpa.free(b);
    for (dirs_buf[0..n]) |dir_path| {
        var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        var guard: usize = 0;
        while (it.next(io) catch null) |e| {
            guard += 1;
            if (guard > 512) break;
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (!isAppImagePath(e.name)) continue;
            if (!appImageStemMatches(app_id, e.name)) continue;
            var pbuf: [std.fs.max_path_bytes]u8 = undefined;
            const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir_path, e.name }) catch continue;
            // Exact stem beats a prefix match; keep the first exact one.
            const exact = exactStem(app_id, e.name);
            if (exact) {
                if (best) |b| gpa.free(b);
                return gpa.dupe(u8, p) catch null;
            }
            if (best == null) best = gpa.dupe(u8, p) catch null;
        }
    }
    if (best) |b| {
        const out = b;
        best = null;
        return out;
    }
    return null;
}

fn appImageStemMatches(app_id: []const u8, path: []const u8) bool {
    return exactStem(app_id, path) or prefixStem(app_id, path);
}

fn exactStem(app_id: []const u8, path: []const u8) bool {
    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const a = normalizeStem(&a_buf, app_id) orelse return false;
    const b = normalizeStem(&b_buf, std.fs.path.basename(path)) orelse return false;
    return std.mem.eql(u8, a, b);
}

fn prefixStem(app_id: []const u8, path: []const u8) bool {
    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const a = normalizeStem(&a_buf, app_id) orelse return false;
    const b = normalizeStem(&b_buf, std.fs.path.basename(path)) orelse return false;
    if (a.len == 0 or b.len == 0) return false;
    if (std.mem.eql(u8, a, b)) return true;
    if (a.len < b.len) {
        if (!std.mem.startsWith(u8, b, a)) return false;
        return b[a.len] == '-' or b[a.len] == '_' or b[a.len] == '.';
    }
    if (!std.mem.startsWith(u8, a, b)) return false;
    return a[b.len] == '-' or a[b.len] == '_' or a[b.len] == '.';
}

/// Lowercase, drop the extension, the architecture tag and a trailing version
/// so `Krita-5.2.0-x86_64.AppImage` and the window class `krita` agree.
fn normalizeStem(buf: []u8, name: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(name);
    if (base.len == 0 or base.len > buf.len) return null;
    var out = buf[0..base.len];
    for (base, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    if (std.ascii.endsWithIgnoreCase(out, ".appimage")) out = out[0 .. out.len - ".appimage".len];
    const arch = [_][]const u8{ "-x86_64", "-amd64", "-aarch64", "-arm64", "-i386", "-i686", ".x86_64", ".amd64" };
    for (arch) |suffix| {
        if (std.ascii.endsWithIgnoreCase(out, suffix)) {
            out = out[0 .. out.len - suffix.len];
            break;
        }
    }
    for (out) |*ch| {
        if (ch.* == ' ' or ch.* == '_') ch.* = '-';
    }
    // A trailing `-1.2.3`, `-v1.2.3`, `-1.2.3-beta` style version.
    if (std.mem.lastIndexOfScalar(u8, out, '-')) |dash| {
        const tail = out[dash + 1 ..];
        if (tail.len > 0 and tail[0] == 'v') {
            if (looksNumericVersion(tail[1..])) out = out[0..dash];
        } else if (looksNumericVersion(tail)) {
            out = out[0..dash];
        }
    }
    return out;
}

fn looksNumericVersion(s: []const u8) bool {
    var digits: usize = 0;
    for (s) |ch| {
        if (std.ascii.isDigit(ch)) {
            digits += 1;
            continue;
        }
        if (ch == '.' or ch == '_' or ch == '-') continue;
        return false;
    }
    return digits > 0;
}

fn appImage(gpa: std.mem.Allocator, io: std.Io, path: []const u8, allow_run: bool) ?[]u8 {
    var hbuf: [32]u8 = undefined;
    const key = hashKey(&hbuf, path);
    // Cached extraction: one of the possible extensions already on disk.
    if (cachedAppImageIcon(gpa, io, key)) |p| return p;
    if (!allow_run) return null;
    if (!fileExists(io, path)) return null;
    return extractAppImage(gpa, io, path, key);
}

fn cachedAppImageIcon(gpa: std.mem.Allocator, io: std.Io, key: []const u8) ?[]u8 {
    const dir = cacheDir(gpa) orelse return null;
    defer gpa.free(dir);
    for (k_icon_exts) |ext| {
        const p = std.fmt.allocPrint(gpa, "{s}/appimage-{s}{s}", .{ dir, key, ext }) catch continue;
        if (fileExists(io, p)) return p;
        gpa.free(p);
    }
    return null;
}

fn extractAppImage(gpa: std.mem.Allocator, io: std.Io, path: []const u8, key: []const u8) ?[]u8 {
    const dir = ensureCacheDir(gpa, io) orelse return null;
    defer gpa.free(dir);

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/tmp-{s}-{d}", .{ dir, key, std.os.linux.getpid() }) catch return null;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, tmp) catch {};
    cwd.createDirPath(io, tmp) catch return null;
    defer cwd.deleteTree(io, tmp) catch {};

    // Preferred: the image's own `.DirIcon`. `--appimage-extract` takes a
    // squashfs glob, does not need FUSE, and is the runtime's supported path.
    var icon_path: ?[]u8 = null;
    defer if (icon_path) |p| gpa.free(p);

    icon_path = extractEntry(gpa, io, path, tmp, ".DirIcon", 1);

    // Some AppImages ship no `.DirIcon`; extract the top-level desktop file
    // and follow its `Icon=` instead.
    if (icon_path == null) {
        _ = runExtract(gpa, io, path, tmp, "*.desktop");
        if (findDesktopIcon(gpa, io, tmp)) |icon_name| {
            defer gpa.free(icon_name);
            const rel = if (std.fs.path.isAbsolute(icon_name))
                std.mem.trimStart(u8, icon_name, "/")
            else
                icon_name;
            const with_ext = std.ascii.endsWithIgnoreCase(rel, ".png") or
                std.ascii.endsWithIgnoreCase(rel, ".svg") or
                std.ascii.endsWithIgnoreCase(rel, ".xpm");
            if (with_ext) {
                icon_path = extractEntry(gpa, io, path, tmp, rel, 1);
            } else {
                for ([_][]const u8{ ".png", ".svg", ".xpm" }) |ext| {
                    const candidate = std.fmt.allocPrint(gpa, "{s}{s}", .{ rel, ext }) catch continue;
                    defer gpa.free(candidate);
                    if (extractEntry(gpa, io, path, tmp, candidate, 1)) |p| {
                        icon_path = p;
                        break;
                    }
                }
            }
        }
    }

    const src = icon_path orelse return null;
    const ext = iconExt(src) orelse ".png";
    const dest = std.fmt.allocPrint(gpa, "{s}/appimage-{s}{s}", .{ dir, key, ext }) catch return null;
    cwd.copyFile(src, cwd, dest, io, .{ .replace = true, .make_path = true }) catch {
        gpa.free(dest);
        return null;
    };
    return dest;
}

fn iconExt(path: []const u8) ?[]const u8 {
    for (k_icon_exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return ext;
    }
    return null;
}

/// Extract `rel` from the AppImage and follow symlinks until a concrete file is
/// on disk. A `.DirIcon` that names `foo.png` and an `Icon=` that names a
/// hicolor path are both commonly symlinks inside the image, and extracting
/// the link alone leaves a dangling entry that no decoder can read.
fn extractEntry(
    gpa: std.mem.Allocator,
    io: std.Io,
    appimage: []const u8,
    tmp: []const u8,
    rel: []const u8,
    depth: usize,
) ?[]u8 {
    if (rel.len == 0 or depth > 8) return null;
    _ = runExtract(gpa, io, appimage, tmp, rel);

    const root = std.fs.path.join(gpa, &.{ tmp, "squashfs-root" }) catch return null;
    defer gpa.free(root);
    const full = std.fs.path.join(gpa, &.{ root, rel }) catch return null;
    defer gpa.free(full);

    // Follows symlinks, so a link to an already-extracted file succeeds here.
    if (fileExists(io, full)) return gpa.dupe(u8, full) catch null;

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().readLink(io, full, &link_buf) catch return null;
    const link = link_buf[0..len];
    const next = resolveImageRel(gpa, rel, link) orelse return null;
    defer gpa.free(next);
    return extractEntry(gpa, io, appimage, tmp, next, depth + 1);
}

/// Lexically resolve a symlink target to a path relative to the image root.
fn resolveImageRel(gpa: std.mem.Allocator, rel: []const u8, link: []const u8) ?[]u8 {
    const abs = if (std.fs.path.isAbsolute(link))
        std.fs.path.resolve(gpa, &.{ "/", link }) catch return null
    else
        std.fs.path.resolve(gpa, &.{ "/", std.fs.path.dirname(rel) orelse "", link }) catch return null;
    defer gpa.free(abs);
    return gpa.dupe(u8, std.mem.trimStart(u8, abs, "/")) catch null;
}

fn findDesktopIcon(gpa: std.mem.Allocator, io: std.Io, tmp: []const u8) ?[]u8 {
    const root = std.fs.path.join(gpa, &.{ tmp, "squashfs-root" }) catch return null;
    defer gpa.free(root);
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        if (!std.ascii.endsWithIgnoreCase(e.name, ".desktop")) continue;
        const p = std.fs.path.join(gpa, &.{ root, e.name }) catch continue;
        defer gpa.free(p);
        const data = readBounded(gpa, io, p, 128 * 1024) orelse continue;
        defer gpa.free(data);
        var section_ok = false;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                section_ok = std.mem.eql(u8, line, "[Desktop Entry]");
                continue;
            }
            if (!section_ok or !std.mem.startsWith(u8, line, "Icon=")) continue;
            const v = std.mem.trim(u8, line["Icon=".len..], " \t\r");
            if (v.len > 0) return gpa.dupe(u8, v) catch null;
        }
    }
    return null;
}

/// Run `<appimage> --appimage-extract <pattern>` in `dir`. Returns true when
/// the runtime exited 0 inside the timeout, regardless of whether the pattern
/// matched. Output is discarded: AppImage runtimes are chatty on stderr.
fn runExtract(gpa: std.mem.Allocator, io: std.Io, path: []const u8, dir: []const u8, pattern: []const u8) bool {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ path, "--appimage-extract", pattern },
        .cwd = .{ .path = dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(k_extract_timeout_ms)),
            .clock = .awake,
        } },
    }) catch |err| {
        logz.log("icons: appimage extract '{s}' failed: {s}", .{ path, @errorName(err) });
        return false;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    return res.term == .exited and res.term.exited == 0;
}

// -- PE icon resources ----------------------------------------------------

/// Extract the largest icon from a Windows executable, cache it as a PNG and
/// return the cache path. `key` makes the cache name stable for one exe.
fn extractPeIcon(gpa: std.mem.Allocator, io: std.Io, exe_path: []const u8, key: []const u8) ?[]u8 {
    const dir = ensureCacheDir(gpa, io) orelse return null;
    defer gpa.free(dir);
    var hbuf: [32]u8 = undefined;
    const h = hashKey(&hbuf, key);
    const dest = std.fmt.allocPrint(gpa, "{s}/pe-{s}.png", .{ dir, h }) catch return null;
    if (fileExists(io, dest)) return dest;
    errdefer gpa.free(dest);

    const rgba = peIconRgba(gpa, io, exe_path) orelse {
        gpa.free(dest);
        return null;
    };
    defer gpa.free(rgba.data);

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/pe-{s}.{d}.tmp", .{ dir, h, std.os.linux.getpid() }) catch {
        gpa.free(dest);
        return null;
    };
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, tmp) catch {};
    var z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zpath = std.fmt.bufPrintSentinel(&z_buf, "{s}", .{tmp}, 0) catch {
        gpa.free(dest);
        return null;
    };
    const ok = eh_write_png(zpath.ptr, rgba.w, rgba.h, rgba.data.ptr, rgba.w * 4, 1);
    if (ok == 0) {
        gpa.free(dest);
        return null;
    }
    cwd.rename(tmp, cwd, dest, io) catch {
        cwd.deleteFile(io, tmp) catch {};
        // A concurrent writer may have won the race; use its file.
        if (fileExists(io, dest)) return dest;
        gpa.free(dest);
        return null;
    };
    return dest;
}

const Rgba = struct { w: i32, h: i32, data: []u8 };

const PeHeader = struct {
    res_rva: u32,
    res_size: u32,
    res_offset: u64,
};

fn u16le(d: []const u8, off: usize) ?u16 {
    if (off + 2 > d.len) return null;
    return std.mem.readInt(u16, d[off..][0..2], .little);
}

fn u32le(d: []const u8, off: usize) ?u32 {
    if (off + 4 > d.len) return null;
    return std.mem.readInt(u32, d[off..][0..4], .little);
}

fn parsePeHeader(head: []const u8) ?PeHeader {
    const pe_off = u32le(head, 0x3C) orelse return null;
    if (pe_off + 24 > head.len) return null;
    if (!std.mem.eql(u8, head[pe_off..][0..4], "PE\x00\x00")) return null;
    const coff = pe_off + 4;
    const nsec = u16le(head, coff + 2) orelse return null;
    const opt_size = u16le(head, coff + 16) orelse return null;
    const opt = coff + 20;
    const magic = u16le(head, opt) orelse return null;
    const dd = opt + (if (magic == 0x20b) @as(usize, 112) else 96);
    const res_rva = u32le(head, dd + 2 * 8) orelse return null;
    const res_size = u32le(head, dd + 2 * 8 + 4) orelse return null;
    if (res_rva == 0 or res_size == 0) return null;

    const sec_off = opt + opt_size;
    var i: usize = 0;
    while (i < nsec) : (i += 1) {
        const o = sec_off + i * 40;
        if (o + 40 > head.len) return null;
        const vsize = u32le(head, o + 8) orelse return null;
        const vaddr = u32le(head, o + 12) orelse return null;
        const raw_size = u32le(head, o + 16) orelse return null;
        const raw_ptr = u32le(head, o + 20) orelse return null;
        const span = @max(vsize, raw_size);
        if (res_rva >= vaddr and res_rva < vaddr + span) {
            const delta = res_rva - vaddr;
            return .{
                .res_rva = res_rva,
                .res_size = res_size,
                .res_offset = @as(u64, raw_ptr) + delta,
            };
        }
    }
    return null;
}

fn peIconRgba(gpa: std.mem.Allocator, io: std.Io, exe_path: []const u8) ?Rgba {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, exe_path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    if (st.size < 0x200) return null;

    var head = gpa.alloc(u8, @intCast(@min(st.size, k_max_exe_header))) catch return null;
    defer gpa.free(head);
    const got = file.readPositionalAll(io, head, 0) catch return null;
    if (got < 0x40) return null;
    const hdr = parsePeHeader(head[0..got]) orelse return null;

    const want: usize = @intCast(@min(@as(u64, hdr.res_size), @as(u64, k_max_pe_resource)));
    var res = gpa.alloc(u8, want) catch return null;
    defer gpa.free(res);
    const res_got = file.readPositionalAll(io, res, hdr.res_offset) catch return null;
    if (res_got < 16) return null;

    return decodePeResources(gpa, res[0..res_got], hdr.res_rva);
}

const ResourceRef = struct { id: u32, off: usize, size: usize };

fn decodePeResources(gpa: std.mem.Allocator, res: []const u8, res_rva: u32) ?Rgba {
    var groups: std.ArrayListUnmanaged(ResourceRef) = .empty;
    defer groups.deinit(gpa);
    var icons: std.ArrayListUnmanaged(ResourceRef) = .empty;
    defer icons.deinit(gpa);

    const root = 0;
    const group_dir = findNamedEntry(res, root, 14) orelse return null;
    const icon_dir = findNamedEntry(res, root, 3) orelse return null;

    collectResources(gpa, res, group_dir, res_rva, &groups);
    collectResources(gpa, res, icon_dir, res_rva, &icons);
    if (groups.items.len == 0 or icons.items.len == 0) return null;

    var best: ?Rgba = null;
    defer if (best) |b| gpa.free(b.data);

    for (groups.items) |g| {
        const group = res[g.off..][0..g.size];
        const count = u16le(group, 2) orelse continue;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const e = 6 + i * 14;
            if (e + 14 > group.len) break;
            const w: i32 = if (group[e] == 0) 256 else group[e];
            const h: i32 = if (group[e + 1] == 0) 256 else group[e + 1];
            if (w <= 0 or h <= 0 or w > 1024 or h > 1024) continue;
            const nid = u16le(group, e + 12) orelse continue;
            const icon = findResource(icons.items, nid) orelse continue;
            const data = res[icon.off..][0..icon.size];
            const decoded = decodeIconImage(gpa, data) orelse continue;
            const area = decoded.w * decoded.h;
            if (best == null or area > best.?.w * best.?.h) {
                if (best) |b| gpa.free(b.data);
                best = decoded;
            } else {
                gpa.free(decoded.data);
            }
        }
    }
    return best;
}

fn findNamedEntry(res: []const u8, dir_off: usize, want: u32) ?usize {
    const named = u16le(res, dir_off + 12) orelse return null;
    const ids = u16le(res, dir_off + 14) orelse return null;
    const count: usize = @as(usize, named) + ids;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = dir_off + 16 + i * 8;
        const name = u32le(res, e) orelse return null;
        if (name & 0x80000000 != 0) continue;
        if (name != want) continue;
        const off = u32le(res, e + 4) orelse return null;
        if (off & 0x80000000 == 0) return null;
        return off & 0x7fffffff;
    }
    return null;
}

fn collectResources(gpa: std.mem.Allocator, res: []const u8, dir_off: usize, res_rva: u32, out: *std.ArrayListUnmanaged(ResourceRef)) void {
    const named = u16le(res, dir_off + 12) orelse return;
    const ids = u16le(res, dir_off + 14) orelse return;
    const count: usize = @as(usize, named) + ids;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = dir_off + 16 + i * 8;
        const name = u32le(res, e) orelse return;
        if (name & 0x80000000 != 0) continue;
        const off = u32le(res, e + 4) orelse return;
        // Each named resource has a language subdirectory; the first leaf is
        // the icon. A leaf directly under the type directory is malformed.
        if (off & 0x80000000 == 0) continue;
        const sub = off & 0x7fffffff;
        const l_named = u16le(res, sub + 12) orelse continue;
        const l_ids = u16le(res, sub + 14) orelse continue;
        if (@as(usize, l_named) + l_ids == 0) continue;
        const loff = u32le(res, sub + 16 + 4) orelse continue;
        if (loff & 0x80000000 != 0) continue;
        const data_off = loff & 0x7fffffff;
        const data_rva = u32le(res, data_off) orelse continue;
        const data_size = u32le(res, data_off + 4) orelse continue;
        if (data_size == 0 or data_rva < res_rva) continue;
        const rel_off: usize = @intCast(data_rva - res_rva);
        if (rel_off >= res.len or rel_off + data_size > res.len) continue;
        out.append(gpa, .{ .id = name, .off = rel_off, .size = data_size }) catch {};
    }
}

fn findResource(list: []const ResourceRef, id: u16) ?ResourceRef {
    for (list) |r| {
        if (r.id == id) return r;
    }
    return null;
}

fn decodeIconImage(gpa: std.mem.Allocator, data: []const u8) ?Rgba {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) {
        const img = decode.loadRgbaMemory(gpa, data) orelse return null;
        return .{ .w = img.w, .h = img.h, .data = img.pixels };
    }
    return decodeDib(gpa, data);
}

/// Decode one ICO image stored as a DIB: BITMAPINFOHEADER, optional palette
/// and colour masks, XOR bitmap, then the 1-bit AND transparency mask. Icons
/// in the wild are almost always 32- or 24-bit, but the older depths are cheap
/// and appear in small legacy resources.
fn decodeDib(gpa: std.mem.Allocator, data: []const u8) ?Rgba {
    const hdr_size = u32le(data, 0) orelse return null;
    if (hdr_size < 40 or hdr_size > data.len) return null;
    const bw = u32le(data, 4) orelse return null;
    const bh = u32le(data, 8) orelse return null;
    const w: i32 = @bitCast(bw);
    const height_signed: i32 = @bitCast(bh);
    const bpp = u16le(data, 14) orelse return null;
    const compression = u32le(data, 16) orelse return null;
    const clr_used = u32le(data, 32) orelse 0;

    if (w <= 0 or w > 1024) return null;
    const full_h = if (height_signed < 0) -height_signed else height_signed;
    const h = @divTrunc(full_h, 2);
    if (h <= 0 or h > 1024) return null;
    if (bpp != 1 and bpp != 4 and bpp != 8 and bpp != 16 and bpp != 24 and bpp != 32) return null;

    var masks: [3]u32 = .{ 0, 0, 0 };
    var pixel_off: usize = hdr_size;
    if (compression == 3) {
        if (hdr_size >= 52) {
            masks[0] = u32le(data, 40) orelse return null;
            masks[1] = u32le(data, 44) orelse return null;
            masks[2] = u32le(data, 48) orelse return null;
        } else {
            masks[0] = u32le(data, hdr_size) orelse return null;
            masks[1] = u32le(data, hdr_size + 4) orelse return null;
            masks[2] = u32le(data, hdr_size + 8) orelse return null;
            pixel_off += 12;
        }
    } else if (compression != 0) {
        return null;
    }

    var palette_n: usize = 0;
    if (bpp <= 8) {
        palette_n = if (clr_used > 0 and clr_used <= 256) clr_used else @as(usize, 1) << @intCast(bpp);
        pixel_off += palette_n * 4;
    }
    if (bpp == 16 and masks[0] == 0) {
        masks = .{ 0x7C00, 0x03E0, 0x001F };
    }

    const width: usize = @intCast(w);
    const height: usize = @intCast(h);
    const stride = ((width * bpp + 31) / 32) * 4;
    const xor_size = stride * height;
    const and_stride = ((width + 31) / 32) * 4;
    if (pixel_off + xor_size > data.len) return null;
    const and_off = pixel_off + xor_size;
    const have_and = and_off + and_stride * height <= data.len;

    const out = gpa.alloc(u8, width * height * 4) catch return null;
    errdefer gpa.free(out);
    var any_alpha = false;

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_y = if (height_signed > 0) height - 1 - y else y;
        const row = pixel_off + src_y * stride;
        const and_row = and_off + src_y * and_stride;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;
            var a: u8 = 255;
            switch (bpp) {
                32 => {
                    const p = row + x * 4;
                    b = data[p];
                    g = data[p + 1];
                    r = data[p + 2];
                    a = data[p + 3];
                    if (a != 0) any_alpha = true;
                },
                24 => {
                    const p = row + x * 3;
                    b = data[p];
                    g = data[p + 1];
                    r = data[p + 2];
                },
                16 => {
                    const p = row + x * 2;
                    const v = @as(u16, data[p]) | (@as(u16, data[p + 1]) << 8);
                    r = expandMask(v, masks[0]);
                    g = expandMask(v, masks[1]);
                    b = expandMask(v, masks[2]);
                },
                8 => {
                    const idx = data[row + x];
                    if (idx >= palette_n) continue;
                    const p = hdr_size + idx * 4;
                    b = data[p];
                    g = data[p + 1];
                    r = data[p + 2];
                },
                4 => {
                    const byte = data[row + x / 2];
                    const idx = if (x % 2 == 0) byte >> 4 else byte & 0x0f;
                    if (idx >= palette_n) continue;
                    const p = hdr_size + idx * 4;
                    b = data[p];
                    g = data[p + 1];
                    r = data[p + 2];
                },
                1 => {
                    const byte = data[row + x / 8];
                    const idx = (byte >> @intCast(7 - (x % 8))) & 1;
                    if (idx >= palette_n) continue;
                    const p = hdr_size + idx * 4;
                    b = data[p];
                    g = data[p + 1];
                    r = data[p + 2];
                },
                else => unreachable,
            }
            if (bpp != 32 and have_and) {
                const bit = @as(u8, 0x80) >> @intCast(x % 8);
                if (data[and_row + x / 8] & bit != 0) a = 0;
            }
            const o = (y * width + x) * 4;
            out[o] = r;
            out[o + 1] = g;
            out[o + 2] = b;
            out[o + 3] = a;
        }
    }

    // 32-bit icons frequently leave the alpha channel at zero and rely on
    // the AND mask instead. Only then is the mask authoritative.
    if (bpp == 32 and !any_alpha and have_and) {
        y = 0;
        while (y < height) : (y += 1) {
            const and_row = and_off + y * and_stride;
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const bit = @as(u8, 0x80) >> @intCast(x % 8);
                const o = (y * width + x) * 4;
                out[o + 3] = if (data[and_row + x / 8] & bit != 0) 0 else 255;
            }
        }
    }
    return .{ .w = w, .h = h, .data = out };
}

fn expandMask(v: u16, mask: u32) u8 {
    if (mask == 0) return 0;
    const m: u16 = @truncate(mask);
    const shift: u4 = @intCast(@ctz(m));
    const shifted = (v & m) >> shift;
    const max: u32 = m >> shift;
    if (max == 0) return 0;
    return @intCast((@as(u32, shifted) * 255 + max / 2) / max);
}

pub fn rgbaToCairo(px: []u8) void {
    icon_raster.rgbaToCairo(px);
}

fn freeList(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged([]u8)) void {
    for (list.items) |s| gpa.free(s);
    list.deinit(gpa);
}

test "icon-extra: steam app ids" {
    const t = std.testing;
    try t.expectEqual(@as(?u32, 2246340), parseSteamAppId("steam_app_2246340"));
    try t.expectEqual(@as(?u32, 2246340), parseSteamAppId("steam_icon_2246340"));
    try t.expectEqual(@as(?u32, null), parseSteamAppId("steam"));
    try t.expectEqual(@as(?u32, null), parseSteamAppId("steam_app_"));
    try t.expectEqual(@as(?u32, null), parseSteamAppId("firefox"));
}

test "icon-extra: appimage stem matching" {
    const t = std.testing;
    try t.expect(exactStem("krita", "Krita-5.2.0-x86_64.AppImage"));
    try t.expect(exactStem("obsidian", "/home/u/Applications/Obsidian.AppImage"));
    try t.expect(prefixStem("my app", "my-app-1.0.AppImage"));
    try t.expect(!exactStem("gimp", "krita-5.2.AppImage"));
    try t.expect(!appImageStemMatches("steam", "shadow.AppImage"));
}

test "icon-extra: 24-bit icon dib decodes with the and mask" {
    const t = std.testing;
    // One 2x2 icon: header + two bottom-up rows of 3-byte BGR (stride 8),
    // then two 4-byte AND mask rows. Opaque except the top-left pixel.
    var d: [40 + 16 + 8]u8 = @splat(0);
    std.mem.writeInt(u32, d[0..4], 40, .little);
    std.mem.writeInt(u32, d[4..8], 2, .little);
    std.mem.writeInt(u32, d[8..12], 4, .little); // 2 * 2 rows
    std.mem.writeInt(u16, d[12..14], 1, .little);
    std.mem.writeInt(u16, d[14..16], 24, .little);
    // first pixel white, second black
    d[40] = 0xFF;
    d[41] = 0xFF;
    d[42] = 0xFF;
    // AND mask rows are bottom-up: the second row is the top row, where the
    // leftmost bit means transparent.
    d[60] = 0x80;
    const img = decodeDib(t.allocator, &d).?;
    defer t.allocator.free(img.data);
    try t.expectEqual(@as(i32, 2), img.w);
    try t.expectEqual(@as(i32, 2), img.h);
    try t.expectEqual(@as(u8, 0), img.data[3]);
}
