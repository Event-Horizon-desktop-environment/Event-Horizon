//! Covers from a player that keeps them in a sandbox-private cache instead
//! of publishing a file path.
//!
//! That cache is a directory of keyed entries: a small binary header, the
//! address the player fetched, then the body of that response. A thumbnail
//! entry's key still carries the image store's URL and the size it was
//! asked for, so the biggest thumbnail on hand is the one the current track
//! wanted. Finding it means walking the entries and reading each header —
//! far too much work to repeat between two requests, so the winner is
//! remembered and only re-found when the track (or the entry itself)
//! moves; its pixels then live in the shared cover cache like any other
//! cover, and a repeat find is a read of those.

const std = @import("std");
const mpris_art = @import("mpris_art.zig");
const cover_cache = @import("cover_cache.zig");

/// Layouts this player has used, relative to $HOME.
const dirnames = [_][]const u8{
    ".var/app/sh.cider.Cider/config/sh.cider.genten/Cache/Cache_Data",
    ".config/sh.cider.genten/Cache/Cache_Data",
};

/// Data entries end with this; the leading part is the entry's identity.
const entry_suffix = "_0";
const entry_magic = [4]u8{ 0x30, 0x5c, 0x72, 0xa7 };
const min_entry_bytes: u64 = 40;
const min_key_bytes: u32 = 8;
const max_key_bytes: u32 = 2048;
/// From the key of a thumbnail fetch; anything else cached in there is not
/// a cover and is skipped.
const cover_key_marker = "mzstatic.com/image/thumb/";
/// Enough for the entry header, the longest allowed key, and a WebP frame
/// header past it — one read of this size decides every filter.
const head_bytes = 4096;

/// Tests point the search at a directory they built; null reads $HOME.
pub var search_dirs: ?[]const []const u8 = null;

/// How many searches have run since `resetForTests`; the tests watch worst
/// -case work through this.
pub var scan_count: usize = 0;

const Candidate = struct {
    /// Owned by the scan (page allocator, process lifetime).
    file: []const u8,
    size: u64,
    mtime_ns: i128,
    off: usize,
    len: usize,
    url_w: i32 = 0,
    url_h: i32 = 0,
    pix_w: i32 = 0,
    pix_h: i32 = 0,
};

/// The winner of the last search, and which track asked for it.
var best: ?Candidate = null;
var last_marker: ?[]const u8 = null;

var home_dirs: ?[dirnames.len][]u8 = null;

/// Find the cover for `marker` — the per-track address `mpris_art.sourceFor`
/// derived. A fresh search runs when the track is new, nothing has been
/// found yet, or the remembered entry no longer matches its stat; otherwise
/// the winner is used straight away. Owned pixels on the caller's
/// allocator.
pub fn find(alloc: std.mem.Allocator, io: std.Io, marker: []const u8) ?mpris_art.Cover {
    if (best == null or !markerMatches(marker) or !intact(io, best.?)) {
        var fresh = scan(io);
        replaceBest(&fresh);
        rememberMarker(marker);
    }
    const cand = best orelse return null;
    const key = keyFor(alloc, cand) orelse return null;
    defer alloc.free(key);
    // Pixels for this exact entry were decoded before: the find is a read.
    if (cover_cache.find(alloc, io, key)) |cover| return cover;
    const body = loadBody(alloc, io, cand) orelse return null;
    defer alloc.free(body);
    const cover = mpris_art.decode(alloc, body) orelse return null;
    cover_cache.store(io, key, cover);
    return cover;
}

/// Tests start and end clean: the module memoizes across calls by design.
pub fn resetForTests() void {
    if (best) |b| std.heap.page_allocator.free(b.file);
    best = null;
    if (last_marker) |m| std.heap.page_allocator.free(m);
    last_marker = null;
    scan_count = 0;
}

fn markerMatches(marker: []const u8) bool {
    const last = last_marker orelse return false;
    return std.mem.eql(u8, last, marker);
}

fn rememberMarker(marker: []const u8) void {
    const gpa = std.heap.page_allocator;
    if (last_marker) |old| gpa.free(old);
    last_marker = gpa.dupe(u8, marker) catch null;
}

fn replaceBest(fresh: *?Candidate) void {
    const gpa = std.heap.page_allocator;
    if (best) |old| gpa.free(old.file);
    best = fresh.*;
    fresh.* = null;
}

/// Does the remembered winner still look exactly like it did at scan time?
fn intact(io: std.Io, c: Candidate) bool {
    const st = std.Io.Dir.cwd().statFile(io, c.file, .{}) catch return false;
    if (st.size != c.size or st.mtime.nanoseconds != c.mtime_ns) return false;
    return st.size >= c.off + c.len;
}

/// The address the disk cache knows this entry by: its file, the stamp that
/// changes when it is rewritten, and where its body sits inside.
fn keyFor(alloc: std.mem.Allocator, c: Candidate) ?[]const u8 {
    return std.fmt.allocPrint(alloc, "cider:{s}:{d}:{d}:{d}", .{
        c.file, c.mtime_ns, c.off, c.len,
    }) catch null;
}

fn dirsOut() ?[]const []const u8 {
    if (search_dirs) |o| return o;
    if (home_dirs == null) {
        const home = envStr("HOME") orelse return null;
        const gpa = std.heap.page_allocator;
        var out: [dirnames.len][]u8 = undefined;
        for (dirnames, 0..) |rel, i| {
            out[i] = std.fs.path.join(gpa, &.{ home, rel }) catch return null;
        }
        home_dirs = out;
    }
    return &home_dirs.?;
}

/// Walk every entry and keep the biggest thumbnail. Every filter is read
/// from a bounded head of the file; only the winner's body is read whole,
/// and only when its pixels are not already cached.
fn scan(io: std.Io) ?Candidate {
    scan_count += 1;
    const gpa = std.heap.page_allocator;
    const dirs = dirsOut() orelse return null;
    const cwd = std.Io.Dir.cwd();
    var found: ?Candidate = null;
    var found_area: i64 = -1;
    for (dirs) |dir| {
        var d = cwd.openDir(io, dir, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file) continue;
            if (e.name.len < entry_suffix.len + 1) continue;
            if (!std.mem.endsWith(u8, e.name, entry_suffix)) continue;
            const path = std.fs.path.join(gpa, &.{ dir, e.name }) catch continue;
            defer gpa.free(path);
            const st = cwd.statFile(io, path, .{}) catch continue;
            if (st.size < min_entry_bytes or st.size > mpris_art.max_art_bytes) continue;
            const cand = inspect(io, path, st) orelse continue;
            const rw: i64 = if (cand.url_w > 0) cand.url_w else cand.pix_w;
            const rh: i64 = if (cand.url_h > 0) cand.url_h else cand.pix_h;
            const area = rw * rh;
            if (found == null or area > found_area or
                (area == found_area and cand.mtime_ns > found.?.mtime_ns))
            {
                if (found) |old| gpa.free(old.file);
                found = cand;
                found_area = area;
            } else {
                gpa.free(cand.file);
            }
        }
    }
    return found;
}

/// One entry: header, key, body. The key has to be a thumbnail fetch, the
/// body the WebP that answered it, and the caption has to describe a real
/// image; the file path is duped because the caller walks on.
fn inspect(io: std.Io, path: []const u8, st: std.Io.File.Stat) ?Candidate {
    const gpa = std.heap.page_allocator;
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var head: [head_bytes]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return null;
    if (n < min_entry_bytes) return null;
    if (!std.mem.eql(u8, head[0..4], &entry_magic)) return null;
    const key_len = std.mem.readInt(u32, head[12..16], .little);
    if (key_len < min_key_bytes or key_len > max_key_bytes) return null;
    const off: usize = 24 + key_len;
    if (off + 12 > n) return null;
    if (!std.mem.eql(u8, head[off .. off + 4], "RIFF")) return null;
    if (!std.mem.eql(u8, head[off + 8 .. off + 12], "WEBP")) return null;
    const key = head[24..off];
    if (std.mem.indexOf(u8, key, cover_key_marker) == null) return null;
    const token = resolutionToken(key);
    var len: usize = @intCast(st.size - off);
    const riff = std.mem.readInt(u32, head[off + 4 ..][0..4], .little);
    if (@as(usize, riff) + 8 < len) len = @as(usize, riff) + 8;
    if (len < 12) return null;
    const dims = mpris_art.webpInfo(head[off..@min(n, off + len)]) orelse return null;
    return .{
        .file = gpa.dupe(u8, path) catch return null,
        .size = st.size,
        .mtime_ns = st.mtime.nanoseconds,
        .off = off,
        .len = len,
        .url_w = token.w,
        .url_h = token.h,
        .pix_w = dims.w,
        .pix_h = dims.h,
    };
}

fn loadBody(alloc: std.mem.Allocator, io: std.Io, c: Candidate) ?[]u8 {
    if (c.len == 0 or c.len > mpris_art.max_art_bytes) return null;
    const buf = alloc.alloc(u8, c.len) catch return null;
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, c.file, .{}) catch {
        alloc.free(buf);
        return null;
    };
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, c.off) catch {
        alloc.free(buf);
        return null;
    };
    if (n != buf.len) {
        alloc.free(buf);
        return null;
    }
    return buf;
}

/// The last `digits x digits` pair in a URL — the size the fetch asked
/// for. Zeroes when the key never states one.
pub fn resolutionToken(u: []const u8) struct { w: i32, h: i32 } {
    var w: i32 = 0;
    var h: i32 = 0;
    var i: usize = 0;
    while (i + 2 < u.len) {
        if (u[i] < '0' or u[i] > '9') {
            i += 1;
            continue;
        }
        const a = i;
        while (i < u.len and u[i] >= '0' and u[i] <= '9') i += 1;
        if (i < u.len and u[i] == 'x') {
            const b = i + 1;
            var j = b;
            while (j < u.len and u[j] >= '0' and u[j] <= '9') j += 1;
            if (j > b) {
                var nw: i64 = 0;
                for (u[a..i]) |ch| nw = @min(nw * 10 + (ch - '0'), 1 << 20);
                var nh: i64 = 0;
                for (u[b..j]) |ch| nh = @min(nh * 10 + (ch - '0'), 1 << 20);
                w = @intCast(nw);
                h = @intCast(nh);
                i = j;
                continue;
            }
        }
    }
    return .{ .w = w, .h = h };
}

fn envStr(key: [:0]const u8) ?[]const u8 {
    const p = getenv(key) orelse return null;
    return std.mem.span(p);
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const test_webp_b64 = "UklGRjgAAABXRUJQVlA4ICwAAACQAQCdASoDAAIAAQAcJaACdLoAA5gA/uuOX4oBSOHO//efP/vAn/vAn+jQAA==";

fn writeEntry(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, key: []const u8) !void {
    var payload: [128]u8 = undefined;
    const n = try std.base64.standard.Decoder.calcSizeForSlice(test_webp_b64);
    try std.base64.standard.Decoder.decode(payload[0..n], test_webp_b64);
    var entry: [512]u8 = undefined;
    @memset(&entry, 0);
    @memcpy(entry[0..4], &entry_magic);
    std.mem.writeInt(u32, entry[12..16], @intCast(key.len), .little);
    @memcpy(entry[24 .. 24 + key.len], key);
    const off = 24 + key.len;
    @memcpy(entry[off .. off + n], payload[0..n]);
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = entry[0 .. off + n] });
}

test "cider-art: the best thumbnail in the cache is found once" {
    const t = std.testing;
    resetForTests();
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const root = try std.fmt.allocPrint(t.allocator, "tmp-cider-art-{d}", .{std.os.linux.getpid()});
    defer t.allocator.free(root);
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    defer cwd.deleteTree(io, root) catch {};
    defer resetForTests();
    const dirs = [_][]const u8{root};
    search_dirs = &dirs;
    defer search_dirs = null;

    // Two thumbnails of the same store fetch and one entry that is not a
    // cover at all: the biggest caption wins, the rest are skipped.
    try writeEntry(t.allocator, io, root, "aaa_0", "https://is1-ssl.mzstatic.com/image/thumb/Music/a/100x100bb.jpg");
    try writeEntry(t.allocator, io, root, "bbb_0", "https://is1-ssl.mzstatic.com/image/thumb/Music/b/1024x1024bb.webp");
    try writeEntry(t.allocator, io, root, "ccc_0", "https://example.com/not-a-thumb/x.jpg");
    try writeEntry(t.allocator, io, root, "ddd_1", "https://is1-ssl.mzstatic.com/image/thumb/Music/d/512x512bb.jpg");

    var cv = find(t.allocator, io, "cider-cache://track-one") orelse return error.TestUnexpectedResult;
    defer cv.deinit(t.allocator);
    try t.expectEqual(@as(i32, 3), cv.w);
    try t.expectEqual(@as(i32, 2), cv.h);
    try t.expect(scan_count == 1);

    // The same track again: no second search, pixels from the disk cache.
    var again = find(t.allocator, io, "cider-cache://track-one") orelse return error.TestUnexpectedResult;
    defer again.deinit(t.allocator);
    try t.expect(scan_count == 1);
    try t.expectEqualSlices(u8, cv.pixels, again.pixels);

    // A new track looks again.
    var other = find(t.allocator, io, "cider-cache://track-two") orelse return error.TestUnexpectedResult;
    defer other.deinit(t.allocator);
    try t.expect(scan_count == 2);

    // The winner rewritten between two requests is noticed: its stat no
    // longer matches what the scan remembered.
    try writeEntry(t.allocator, io, root, "bbb_0", "https://is1-ssl.mzstatic.com/image/thumb/Music/b/2048x2048bb.webp");
    var moved = find(t.allocator, io, "cider-cache://track-two") orelse return error.TestUnexpectedResult;
    defer moved.deinit(t.allocator);
    try t.expect(scan_count == 3);
}

test "cider-art: an empty cache answers nothing" {
    const t = std.testing;
    resetForTests();
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const root = try std.fmt.allocPrint(t.allocator, "tmp-cider-art-empty-{d}", .{std.os.linux.getpid()});
    defer t.allocator.free(root);
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    defer cwd.deleteTree(io, root) catch {};
    defer resetForTests();
    const dirs = [_][]const u8{root};
    search_dirs = &dirs;
    defer search_dirs = null;

    try t.expect(find(t.allocator, io, "cider-cache://none") == null);
    try t.expect(scan_count == 1);
}

test "cider-art: the caption's last size pair is the one that counts" {
    const t = std.testing;
    const a = resolutionToken("thumb/Music/a/100x100bb.jpg");
    try t.expectEqual(@as(i32, 100), a.w);
    try t.expectEqual(@as(i32, 100), a.h);
    // Two pairs: the later one wins, as the URL's final request does.
    const b = resolutionToken("https://x/image/thumb/50x50/1024x1024bb.webp");
    try t.expectEqual(@as(i32, 1024), b.w);
    try t.expectEqual(@as(i32, 1024), b.h);
    const c = resolutionToken("no-size-here");
    try t.expectEqual(@as(i32, 0), c.w);
    try t.expectEqual(@as(i32, 0), c.h);
    // A version segment is not a size.
    const d = resolutionToken("thumb/12345678901234567890123456/x.jpg");
    try t.expectEqual(@as(i32, 0), d.w);
    try t.expectEqual(@as(i32, 0), d.h);
}
