const std = @import("std");

pub const Format = enum { png, svg, unknown };

pub const Found = struct {
    path: []u8,
    format: Format,
};

/// Icon bases, in priority order: the XDG icon directories plus the older
/// probe paths the shell has always honoured — `~/.icons`, `~/.themes` for
/// hand-installed packs, each data dir's `themes/`, and the flatpak exports
/// trees, which is where a flatpak app's own artwork actually lives.
pub fn dataDirs(alloc: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8, xdg_data_dirs: ?[]const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    if (xdg_data_home) |d| {
        try out.append(alloc, try std.fs.path.join(alloc, &.{ d, "icons" }));
    } else if (home) |h| {
        try out.append(alloc, try std.fs.path.join(alloc, &.{ h, ".local", "share", "icons" }));
    }
    if (home) |h| {
        try out.append(alloc, try std.fs.path.join(alloc, &.{ h, ".icons" }));
        try out.append(alloc, try std.fs.path.join(alloc, &.{ h, ".themes" }));
        try out.append(alloc, try std.fs.path.join(alloc, &.{ h, ".local", "share", "flatpak", "exports", "share", "icons" }));
    }
    if (xdg_data_dirs) |dirs| {
        var it = std.mem.splitScalar(u8, dirs, ':');
        while (it.next()) |d| {
            if (d.len == 0) continue;
            try out.append(alloc, try std.fs.path.join(alloc, &.{ d, "icons" }));
            try out.append(alloc, try std.fs.path.join(alloc, &.{ d, "themes" }));
        }
    } else {
        try out.append(alloc, try alloc.dupe(u8, "/usr/local/share/icons"));
        try out.append(alloc, try alloc.dupe(u8, "/usr/share/icons"));
    }
    try out.append(alloc, try alloc.dupe(u8, "/var/lib/flatpak/exports/share/icons"));
    try out.append(alloc, try alloc.dupe(u8, "/run/flatpak/exports/share/icons"));
    return out.toOwnedSlice(alloc);
}

pub fn freeDirs(alloc: std.mem.Allocator, dirs: [][]const u8) void {
    for (dirs) |d| alloc.free(d);
    alloc.free(dirs);
}

// Search

/// Icon contexts, ordered so the first ones a dock glyph is likely to live in
/// come first. `mimes` is the spelling some icon packs use for `mimetypes`.
const kContexts = [_][]const u8{
    "apps",    "places", "actions",   "status",
    "devices", "mimes",  "mimetypes", "categories",
    "emblems", "panel",  "anim",
};

/// Application ids resolve against the app directory and the theme root only.
const kAppContexts = [_][]const u8{ "apps", "" };

/// Sizes the ladder offers, probed in both the `44x44` and the bare `44`
/// spelling — the freedesktop layout uses the first, several icon packs the
/// second.
const kLadder = [_]u32{ 16, 22, 24, 32, 44, 48, 64, 72, 96, 128, 192, 256, 512, 1024 };

const SubCand = struct { name: []const u8, dist: u32 };

/// Ordered candidate sub-directory names for one requested size. Slices point
/// into this struct, so it must stay put while it is being read.
const SizeCands = struct {
    items: [40]SubCand = undefined,
    bufs: [40][16]u8 = undefined,
    n: usize = 0,

    fn add(self: *SizeCands, s: []const u8, dist: u32) void {
        if (self.n >= self.items.len) return;
        if (s.len == 0 or s.len > 15) return;
        const i = self.n;
        @memcpy(self.bufs[i][0..s.len], s);
        self.items[i] = .{ .name = self.bufs[i][0..s.len], .dist = dist };
        self.n += 1;
    }

    fn addPair(self: *SizeCands, px: u32, dist: u32) void {
        var b: [16]u8 = undefined;
        if (std.fmt.bufPrint(&b, "{d}x{d}", .{ px, px })) |s| {
            self.add(s, dist);
        } else |_| {}
        if (std.fmt.bufPrint(&b, "{d}", .{px})) |s| {
            self.add(s, dist);
        } else |_| {}
    }

    /// Stable insertion sort by distance from the requested size.
    fn finish(self: *SizeCands) void {
        var i: usize = 1;
        while (i < self.n) : (i += 1) {
            const cur = self.items[i];
            var j = i;
            while (j > 0 and self.items[j - 1].dist > cur.dist) : (j -= 1) {
                self.items[j] = self.items[j - 1];
            }
            self.items[j] = cur;
        }
    }
};

fn buildSizeCands(size: u32, out: *SizeCands) void {
    out.* = .{};
    var b: [16]u8 = undefined;
    if (std.fmt.bufPrint(&b, "{d}x{d}", .{ size, size })) |exact| out.add(exact, 0) else |_| {}
    // A vector in `scalable/` is resolution independent, so it beats a
    // bitmap that happens to be one step closer to the requested size.
    out.add("scalable", 1);
    for (kLadder) |px| {
        const d: u32 = if (px >= size) px - size else size - px;
        out.addPair(px, @max(d, 2));
    }
    out.add("symbolic", 100000);
    out.finish();
}

/// Resolved theme search path: the theme, everything it inherits from, and
/// always `hicolor` last. Names are copied into this struct, so it must not be
/// copied after being filled.
const ThemeChain = struct {
    names: [6][]const u8 = undefined,
    slots: [6][48]u8 = undefined,
    len: usize = 0,

    fn add(self: *ThemeChain, name: []const u8) bool {
        if (name.len == 0 or name.len >= 48) return false;
        if (self.len >= self.names.len) return false;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (std.mem.eql(u8, self.names[i], name)) return false;
        }
        const k = self.len;
        @memcpy(self.slots[k][0..name.len], name);
        self.names[k] = self.slots[k][0..name.len];
        self.len += 1;
        return true;
    }

    fn slice(self: *ThemeChain) []const []const u8 {
        return self.names[0..self.len];
    }
};

fn readInherits(io: std.Io, dir: []const u8, theme: []const u8, buf: []u8) ?[]const u8 {
    var path: [700]u8 = undefined;
    const rel = std.fmt.bufPrint(&path, "{s}/{s}/index.theme", .{ dir, theme }) catch return null;
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFile(io, rel, buf) catch return null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "Inherits=")) continue;
        const v = std.mem.trim(u8, line["Inherits=".len..], " \t");
        if (v.len == 0 or v.len >= buf.len) return null;
        return v;
    }
    return null;
}

fn buildThemeChain(io: std.Io, dir: []const u8, theme: []const u8, out: *ThemeChain, fbuf: []u8) void {
    out.* = .{};
    if (theme.len > 0) _ = out.add(theme);
    var guard: usize = 0;
    while (guard < 5) : (guard += 1) {
        if (out.len == 0) break;
        const cur = out.names[out.len - 1];
        const inh = readInherits(io, dir, cur, fbuf) orelse break;
        var added = false;
        var it = std.mem.splitScalar(u8, inh, ',');
        while (it.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t");
            if (t.len == 0) continue;
            if (out.add(t)) {
                added = true;
                break;
            }
        }
        if (!added) break;
    }
    _ = out.add("hicolor");
}

/// One `access()` probe, preferring the vector spelling of an icon.
pub fn isReadable(path: []const u8) bool {
    var zbuf: [1024:0]u8 = @as([1024:0]u8, @splat(0));
    if (path.len >= zbuf.len) return false;
    @memcpy(zbuf[0..path.len], path);
    return std.os.linux.errno(std.os.linux.access(&zbuf, std.os.linux.R_OK)) == .SUCCESS;
}

fn existsPath(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (!isReadable(path)) return null;
    return alloc.dupe(u8, path) catch return null;
}

fn existsExt(alloc: std.mem.Allocator, base: []const u8, ext: []const u8) ?[]u8 {
    // An `Icon=` value often already carries the extension
    // (`Icon=/usr/share/icons/foo.svg`); appending again never matches.
    if (ext.len == 0 or std.mem.endsWith(u8, base, ext)) return existsPath(alloc, base);
    const full = std.fmt.allocPrint(alloc, "{s}{s}", .{ base, ext }) catch return null;
    defer alloc.free(full);
    return existsPath(alloc, full);
}

/// How a found file should be rasterized: librsvg for vectors, stb_image for
/// everything else (png/jpg/bmp are all "raster" as far as the dock cares).
fn formatOf(path: []const u8) Format {
    return if (std.mem.endsWith(u8, path, ".svg")) .svg else .png;
}

fn probePath(alloc: std.mem.Allocator, parts: []const []const u8) ?Found {
    const p = std.fs.path.join(alloc, parts) catch return null;
    defer alloc.free(p);
    if (existsExt(alloc, p, ".svg")) |f| return .{ .path = f, .format = .svg };
    if (existsExt(alloc, p, ".png")) |f| return .{ .path = f, .format = .png };
    return null;
}

fn dirHasTheme(io: std.Io, dir: []const u8, theme: []const u8) bool {
    var p: [700]u8 = undefined;
    const rel = std.fmt.bufPrint(&p, "{s}/{s}", .{ dir, theme }) catch return false;
    const cwd = std.Io.Dir.cwd();
    _ = cwd.statFile(io, rel, .{}) catch return false;
    return true;
}

fn findIn(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    theme: []const u8,
    name: []const u8,
    size: u32,
    contexts: []const []const u8,
) ?Found {
    if (name.len == 0) return null;

    // `Icon=/path/to/icon.svg` is legal in a desktop file.
    if (std.fs.path.isAbsolute(name)) {
        // The value may already name the file outright (with or without an
        // extension), so probe it as-is before trying the usual suffixes.
        if (existsPath(alloc, name)) |p| return .{ .path = p, .format = formatOf(name) };
        if (existsExt(alloc, name, ".svg")) |p| return .{ .path = p, .format = .svg };
        if (existsExt(alloc, name, ".png")) |p| return .{ .path = p, .format = .png };
        return null;
    }

    var cands: SizeCands = .{};
    buildSizeCands(size, &cands);

    var fbuf: [8192]u8 = undefined;
    for (dirs) |dir| {
        var tc = ThemeChain{};
        buildThemeChain(io, dir, theme, &tc, &fbuf);
        for (tc.slice()) |th| {
            if (!dirHasTheme(io, dir, th)) continue;
            for (contexts) |ctx| {
                for (cands.items[0..cands.n]) |sc| {
                    // Freedesktop standard: <dir>/<theme>/<size>/<ctx>/<name>
                    if (ctx.len > 0) {
                        if (probePath(alloc, &.{ dir, th, sc.name, ctx, name })) |f| return f;
                        // Reversed order, as used by several icon packs:
                        // <dir>/<theme>/<ctx>/<size>/<name>
                        if (probePath(alloc, &.{ dir, th, ctx, sc.name, name })) |f| return f;
                    } else {
                        if (probePath(alloc, &.{ dir, th, sc.name, name })) |f| return f;
                    }
                }
                if (ctx.len > 0) {
                    if (probePath(alloc, &.{ dir, th, ctx, name })) |f| return f;
                }
            }
            if (probePath(alloc, &.{ dir, th, name })) |f| return f;
        }
        // A loose icon dropped straight into the theme directory.
        if (probePath(alloc, &.{ dir, name })) |f| return f;
    }
    if (probePath(alloc, &.{ "/usr/share/pixmaps", name })) |f| return f;
    return null;
}

/// Application-icon lookup: the app directory, then the theme root.
pub fn lookup(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    theme: []const u8,
    name: []const u8,
    size: u32,
) ?Found {
    return findIn(alloc, io, dirs, theme, name, size, &kAppContexts);
}

/// Like `lookup`, but walks every icon context, so widget glyphs such as
/// `user-trash` (places) or `bluetooth-active` (status) resolve too. Apps
/// are still tried first, so an app id behaves exactly as it does in `lookup`.
pub fn lookupAny(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    theme: []const u8,
    name: []const u8,
    size: u32,
) ?Found {
    return findIn(alloc, io, dirs, theme, name, size, &kContexts);
}

/// The last probe of `findIn`: a loose file dropped straight into
/// `/usr/share/pixmaps`, the one directory outside the icon themes. Exposed so
/// a caller that answers from the shared theme index can keep this fallback
/// for the price of one stat instead of the full theme walk.
pub fn lookupPixmaps(alloc: std.mem.Allocator, name: []const u8) ?Found {
    if (name.len == 0) return null;
    return probePath(alloc, &.{ "/usr/share/pixmaps", name });
}

pub fn freeFound(alloc: std.mem.Allocator, f: Found) void {
    alloc.free(f.path);
}

fn mkAbsDir(path: []const u8) void {
    var zbuf: [256:0]u8 = @as([256:0]u8, @splat(0));
    if (path.len + 1 > zbuf.len) return;
    @memcpy(zbuf[0..path.len], path);
    _ = std.os.linux.mkdir(&zbuf, 0o755);
}

fn rmAbsFile(path: []const u8) void {
    var zbuf: [256:0]u8 = @as([256:0]u8, @splat(0));
    if (path.len + 1 > zbuf.len) return;
    @memcpy(zbuf[0..path.len], path);
    _ = std.os.linux.unlink(&zbuf);
}

fn touchFile(path: []const u8) void {
    var zbuf: [256:0]u8 = @as([256:0]u8, @splat(0));
    if (path.len + 1 > zbuf.len) return;
    @memcpy(zbuf[0..path.len], path);
    const fd = std.os.linux.open(&zbuf, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    if (std.os.linux.errno(fd) == .SUCCESS) _ = std.os.linux.close(@intCast(fd));
}

test "icon-lookup: finds hicolor icon + misses cleanly" {
    const t = std.testing;
    const io = std.testing.io;
    const base = "/tmp/eh-icon-test";
    mkAbsDir(base);
    mkAbsDir(base ++ "/icons");
    mkAbsDir(base ++ "/icons/TestTheme");
    mkAbsDir(base ++ "/icons/TestTheme/48x48");
    mkAbsDir(base ++ "/icons/TestTheme/48x48/apps");
    defer {
        rmAbsFile(base ++ "/icons/TestTheme/48x48/apps/myapp.png");
        var zbuf: [256:0]u8 = @as([256:0]u8, @splat(0));
        const dirs = [_][]const u8{
            base ++ "/icons/TestTheme/48x48/apps",
            base ++ "/icons/TestTheme/48x48",
            base ++ "/icons/TestTheme",
            base ++ "/icons",
            base,
        };
        for (dirs) |d| {
            @memcpy(zbuf[0..d.len], d);
            zbuf[d.len] = 0;
            _ = std.os.linux.rmdir(&zbuf);
        }
    }
    const fp = base ++ "/icons/TestTheme/48x48/apps/myapp.png";
    touchFile(fp);
    const dirs = [_][]const u8{base ++ "/icons"};
    const found = lookup(t.allocator, io, &dirs, "TestTheme", "myapp", 48).?;
    defer freeFound(t.allocator, found);
    try t.expectEqual(Format.png, found.format);
    try t.expect(lookup(t.allocator, io, &dirs, "TestTheme", "nope", 48) == null);
}

test "icon-lookup: nearest size wins when the exact one is missing" {
    const t = std.testing;
    const io = std.testing.io;
    const base = "/tmp/eh-icon-test2";
    mkAbsDir(base);
    mkAbsDir(base ++ "/icons");
    mkAbsDir(base ++ "/icons/Sizes");
    mkAbsDir(base ++ "/icons/Sizes/apps");
    mkAbsDir(base ++ "/icons/Sizes/apps/32");
    defer {
        rmAbsFile(base ++ "/icons/Sizes/apps/32/nearest.png");
        var zbuf: [256:0]u8 = @as([256:0]u8, @splat(0));
        const dirs = [_][]const u8{
            base ++ "/icons/Sizes/apps/32",
            base ++ "/icons/Sizes/apps",
            base ++ "/icons/Sizes",
            base ++ "/icons",
            base,
        };
        for (dirs) |d| {
            @memcpy(zbuf[0..d.len], d);
            zbuf[d.len] = 0;
            _ = std.os.linux.rmdir(&zbuf);
        }
    }
    touchFile(base ++ "/icons/Sizes/apps/32/nearest.png");
    const dirs = [_][]const u8{base ++ "/icons"};
    // 44 requested, only a 32px bitmap exists — still resolves.
    const found = lookupAny(t.allocator, io, &dirs, "Sizes", "nearest", 44).?;
    defer freeFound(t.allocator, found);
    try t.expectEqualStrings(base ++ "/icons/Sizes/apps/32/nearest.png", found.path);
}

test "icon-lookup: absolute paths from Icon= are used as-is" {
    const t = std.testing;
    const io = std.testing.io;
    const base = "/tmp/eh-icon-test3";
    mkAbsDir(base);
    defer {
        rmAbsFile(base ++ "/abs-icon.svg");
        var zbuf: [256:0]u8 = @as([256:0]u8, @splat(0));
        const p = base;
        @memcpy(zbuf[0..p.len], p);
        zbuf[p.len] = 0;
        _ = std.os.linux.rmdir(&zbuf);
    }
    touchFile(base ++ "/abs-icon.svg");
    const abs = base ++ "/abs-icon.svg";
    const dirs = [_][]const u8{};
    const found = lookupAny(t.allocator, io, &dirs, "Sizes", abs, 44).?;
    defer freeFound(t.allocator, found);
    try t.expectEqual(Format.svg, found.format);
    try t.expectEqualStrings(abs, found.path);
    // A missing absolute path is a miss, not a fallback search.
    try t.expect(lookupAny(t.allocator, io, &dirs, "Sizes", "/tmp/definitely-not-here.svg", 44) == null);
}

test "icon-lookup: the standalone pixmaps probe is the walk's last step" {
    const t = std.testing;
    const io = std.testing.io;
    // An empty name never reaches the filesystem.
    try t.expect(lookupPixmaps(t.allocator, "") == null);
    // With no theme directory to search, `findIn` ends at exactly this probe,
    // so both paths have to return the same file — or the same nothing.
    const dirs = [_][]const u8{};
    const name = "eh-no-such-icon-anywhere-42";
    const direct = lookupPixmaps(t.allocator, name);
    defer if (direct) |f| freeFound(t.allocator, f);
    const walked = lookupAny(t.allocator, io, &dirs, "Sizes", name, 44);
    defer if (walked) |f| freeFound(t.allocator, f);
    if (direct) |d| {
        const w = walked.?;
        try t.expectEqualStrings(d.path, w.path);
        try t.expectEqual(d.format, w.format);
    } else {
        try t.expect(walked == null);
    }
}
