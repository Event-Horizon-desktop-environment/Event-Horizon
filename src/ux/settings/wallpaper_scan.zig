const std = @import("std");

// Folder scan + ordering for the Wallpaper tab gallery — the Zig port of
// `eh::wallpaper::scan_image_files` plus `wallpaper_sort_paths_inplace`
// (settings_tab_wallpaper.cpp). One pass over the folder collects raster
// files with their mtime; sorting is then a pure reorder of that list, which
// is what makes the three sort pills re-order instantly instead of re-statting
// the whole folder on every press (the C++ keeps the same times in its
// `mtimeCache`).
//
// Recursion is opt-in through `EH_WALLPAPER_GALLERY_RECURSIVE`, exactly like
// the C++ scan: the default gallery is one flat folder.

/// Extensions `scan_image_files` accepts, compared case-insensitively.
pub const raster_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".svg" };
/// Same ceiling as the C++ scan — a folder of tens of thousands of files
/// would make the grid unusable and the thumbnail queue meaningless.
pub const max_files: usize = 4000;
/// Bound on the recursive walk (a symlink loop or a huge tree).
pub const max_depth: u8 = 6;

pub const Entry = struct {
    /// Owned by the `Gallery` that holds it.
    path: []u8,
    /// Last modification, nanoseconds since the epoch. 0 when the stat
    /// failed, which sorts the file first among its mtime peers.
    mtime_ns: i96 = 0,
};

pub const Gallery = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Set when the folder hit `max_files` — the grid shows what fits.
    truncated: bool = false,

    pub fn init(alloc: std.mem.Allocator) Gallery {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Gallery) void {
        for (self.entries.items) |e| self.alloc.free(e.path);
        self.entries.deinit(self.alloc);
        self.entries = .empty;
        self.truncated = false;
    }
};

/// `name` ends in one of `raster_exts`, ASCII case-insensitive.
pub fn isRasterName(name: []const u8) bool {
    for (raster_exts) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// `EH_WALLPAPER_GALLERY_RECURSIVE` set and not "0" descends into subfolders.
pub fn recursiveEnabled() bool {
    const raw = std.c.getenv("EH_WALLPAPER_GALLERY_RECURSIVE") orelse return false;
    const v = std.mem.span(raw);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Last modification of `path` in nanoseconds, 0 when unreadable.
pub fn mtimeNs(io: std.Io, path: []const u8) i96 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.mtime.nanoseconds;
}

/// Collect every raster file under `root` into `out` (which must be empty).
/// A failure to open the folder leaves the gallery empty rather than
/// propagating: an unreadable directory simply has no gallery.
pub fn scanFolder(alloc: std.mem.Allocator, io: std.Io, root: []const u8, out: *Gallery) void {
    scanInto(alloc, io, root, out, 0);
}

fn scanInto(alloc: std.mem.Allocator, io: std.Io, root: []const u8, out: *Gallery, depth: u8) void {
    if (depth > max_depth or out.truncated) return;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        switch (e.kind) {
            .directory => {
                if (!recursiveEnabled()) continue;
                const sub = std.fs.path.join(alloc, &.{ root, e.name }) catch continue;
                defer alloc.free(sub);
                scanInto(alloc, io, sub, out, depth + 1);
                if (out.truncated) return;
            },
            .file => {
                // Dotfiles stay hidden, same as the C++ scan.
                if (e.name.len == 0 or e.name[0] == '.') continue;
                if (!isRasterName(e.name)) continue;
                if (out.entries.items.len >= max_files) {
                    out.truncated = true;
                    return;
                }
                const p = std.fs.path.join(alloc, &.{ root, e.name }) catch continue;
                out.entries.append(alloc, .{ .path = p, .mtime_ns = mtimeNs(io, p) }) catch {
                    alloc.free(p);
                    return;
                };
            },
            else => {},
        }
    }
}

/// `wallpaper_folder_key`: strip trailing separators so `/a/b` and `/a/b/`
/// are one folder (and one rescan key). Allocates the trimmed length exactly,
/// so the caller's `free` matches the allocation.
pub fn folderKey(alloc: std.mem.Allocator, folder: []const u8) ![]u8 {
    if (folder.len == 0) return try alloc.dupe(u8, "");
    var len = folder.len;
    while (len > 1 and (folder[len - 1] == '/' or folder[len - 1] == '\\')) len -= 1;
    return try alloc.dupe(u8, folder[0..len]);
}

fn baseName(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |s| return p[s + 1 ..];
    return p;
}

fn lessBaseName(_: void, a: Entry, b: Entry) bool {
    const ba = baseName(a.path);
    const bb = baseName(b.path);
    if (!std.mem.eql(u8, ba, bb)) return std.mem.lessThan(u8, ba, bb);
    return std.mem.lessThan(u8, a.path, b.path);
}

fn lessMtimeAsc(_: void, a: Entry, b: Entry) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns < b.mtime_ns;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn lessMtimeDesc(_: void, a: Entry, b: Entry) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
    return std.mem.lessThan(u8, a.path, b.path);
}

/// `wallpaper_sort_paths_inplace`: 0 by basename, 1 oldest first, 2 newest
/// first (the default), path as the tie-break in every mode.
pub fn sortEntries(entries: []Entry, mode: i32) void {
    if (entries.len < 2) return;
    switch (mode) {
        0 => std.sort.pdq(Entry, entries, {}, lessBaseName),
        1 => std.sort.pdq(Entry, entries, {}, lessMtimeAsc),
        else => std.sort.pdq(Entry, entries, {}, lessMtimeDesc),
    }
}

// ------------------------------------------------------------------ tests --

fn testEntry(alloc: std.mem.Allocator, path: []const u8, mt: i96) Entry {
    return .{ .path = alloc.dupe(u8, path) catch unreachable, .mtime_ns = mt };
}

test "wallpaper-scan: raster extensions match the specified filter" {
    const t = std.testing;
    try t.expect(isRasterName("a.PNG"));
    try t.expect(isRasterName("photo.jpeg"));
    try t.expect(isRasterName("x.webp"));
    try t.expect(isRasterName("y.svg"));
    try t.expect(!isRasterName("clip.mp4"));
    try t.expect(!isRasterName("png"));
    try t.expect(!isRasterName("notes.txt"));
}

test "wallpaper-scan: sort modes reorder as specified" {
    const t = std.testing;
    const alloc = t.allocator;

    var entries = [_]Entry{
        testEntry(alloc, "/g/b.png", 30),
        testEntry(alloc, "/g/a.png", 20),
        testEntry(alloc, "/g/c.png", 20),
    };
    defer for (&entries) |*e| alloc.free(e.path);

    sortEntries(&entries, 0);
    try t.expectEqualStrings("/g/a.png", entries[0].path);
    try t.expectEqualStrings("/g/b.png", entries[1].path);
    try t.expectEqualStrings("/g/c.png", entries[2].path);

    // Equal mtimes fall back to the path, oldest first.
    sortEntries(&entries, 1);
    try t.expectEqualStrings("/g/a.png", entries[0].path);
    try t.expectEqualStrings("/g/c.png", entries[1].path);
    try t.expectEqualStrings("/g/b.png", entries[2].path);

    sortEntries(&entries, 2);
    try t.expectEqualStrings("/g/b.png", entries[0].path);
    // Ties break by path ascending even in newest-first order.
    try t.expectEqualStrings("/g/a.png", entries[1].path);
    try t.expectEqualStrings("/g/c.png", entries[2].path);
}

test "wallpaper-scan: folderKey strips trailing separators" {
    const t = std.testing;
    const alloc = t.allocator;
    const k = try folderKey(alloc, "/pics/walls///");
    defer alloc.free(k);
    try t.expectEqualStrings("/pics/walls", k);
    const empty = try folderKey(alloc, "");
    defer alloc.free(empty);
    try t.expectEqualStrings("", empty);
}

test "wallpaper-scan: reads a real folder" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try cwd.createDirPath(io, root);

    const pic = try std.fs.path.join(alloc, &.{ root, "b.PNG" });
    defer alloc.free(pic);
    try cwd.writeFile(io, .{ .sub_path = pic, .data = "not really a png" });
    const doc = try std.fs.path.join(alloc, &.{ root, "notes.txt" });
    defer alloc.free(doc);
    try cwd.writeFile(io, .{ .sub_path = doc, .data = "x" });

    var g = Gallery.init(alloc);
    defer g.deinit();
    scanFolder(alloc, io, root, &g);
    try t.expectEqual(@as(usize, 1), g.entries.items.len);
    try t.expectEqualStrings("b.PNG", std.fs.path.basename(g.entries.items[0].path));
    try t.expect(g.entries.items[0].mtime_ns > 0);
}
