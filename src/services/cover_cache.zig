//! Decoded covers on disk, keyed by the address a player advertised — so
//! finding a cover a second time (a repeat track, a shell restart, a card
//! opened long after the cover landed) is a read of ready pixels, never
//! another decode.
//!
//! One file per address, named by `mpris_art.cacheName`: 6 magic bytes,
//! w/h as u32le, then the cairo-order pixel body. Capped at 64 files,
//! oldest-evicted on insert. The shell keeps covers at a 512px edge, so a
//! whole entry fits in about a megabyte and a warm read stays far below
//! the frame the find would otherwise sit in.

const std = @import("std");
const mpris_art = @import("mpris_art.zig");

const magic = "EHAR01";
pub const cap_files: usize = 64;
const max_edge: i32 = 512;

/// The directory is computed once per process and lives as long as it does;
/// there is nothing to hand back to an allocator mid-flight. The pixels a
/// `find` answers with are owned by the *caller's* allocator, so the
/// collect-and-free rules everywhere else stay exactly as they were.
var shared_disk: ?Disk = null;

pub const Disk = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8 = "",

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Self {
        var d = Self{ .gpa = gpa, .io = io };
        d.dir = cacheDir(gpa) catch "";
        if (d.dir.len > 0) {
            std.Io.Dir.cwd().createDirPath(io, d.dir) catch {
                gpa.free(d.dir);
                d.dir = "";
            };
        }
        return d;
    }

    pub fn deinit(self: *Self) void {
        if (self.dir.len > 0) self.gpa.free(self.dir);
        self.dir = "";
    }

    fn cacheDir(gpa: std.mem.Allocator) ![]u8 {
        var owned: ?[]u8 = null;
        defer if (owned) |o| gpa.free(o);
        const base = if (envStr("XDG_CACHE_HOME")) |p| p else blk: {
            const home = envStr("HOME") orelse return error.NoHome;
            owned = try std.fs.path.join(gpa, &.{ home, ".cache" });
            break :blk owned.?;
        };
        // Testing never pollutes the live shell's cache.
        const iso = if (envStr("EH_ZIG_ISOLATED")) |v| v.len > 0 else false;
        return std.fs.path.join(gpa, &.{
            base,
            if (iso) "Event-Horizon-zig" else "Event-Horizon",
            "mpris-art",
        });
    }

    fn pathFor(self: *Self, name: []const u8, buf: []u8) ?[]const u8 {
        if (self.dir.len == 0 or name.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.dir, name }) catch null;
    }

    /// Owned pixels on hit; a header that does not describe its body is a
    /// miss, never a partial cover. Read as a header plus one positional
    /// read straight into the caller's buffer: the find sits on the shell's
    /// thread when a track changes, so a megabyte must not be copied twice
    /// (or streamed through the reader's small chunks).
    pub fn find(self: *Self, alloc: std.mem.Allocator, url: []const u8) ?mpris_art.Cover {
        if (self.dir.len == 0 or url.len == 0) return null;
        const name = mpris_art.cacheName(self.gpa, url) catch return null;
        defer self.gpa.free(name);
        var pbuf: [1024]u8 = undefined;
        const path = self.pathFor(name, &pbuf) orelse return null;
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        var hdr: [14]u8 = undefined;
        const hn = file.readPositionalAll(self.io, &hdr, 0) catch return null;
        if (hn != hdr.len or !std.mem.eql(u8, hdr[0..6], magic)) return null;
        const w: i32 = @bitCast(std.mem.readInt(u32, hdr[6..10], .little));
        const h: i32 = @bitCast(std.mem.readInt(u32, hdr[10..14], .little));
        if (w <= 0 or h <= 0 or w > max_edge or h > max_edge) return null;
        const len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        const st = file.stat(self.io) catch return null;
        if (st.size != 14 + len) return null;
        const pixels = alloc.alloc(u8, len) catch return null;
        const n = file.readPositionalAll(self.io, pixels, 14) catch {
            alloc.free(pixels);
            return null;
        };
        if (n != len) {
            alloc.free(pixels);
            return null;
        }
        return .{ .w = w, .h = h, .pixels = pixels };
    }

    /// Remember a decoded cover. Best-effort throughout: a cache that could
    /// not be written is a slower find later, never a failed one.
    pub fn store(self: *Self, url: []const u8, cover: mpris_art.Cover) void {
        if (self.dir.len == 0 or url.len == 0 or !cover.present()) return;
        if (cover.w > max_edge or cover.h > max_edge) return;
        if (cover.pixels.len != @as(usize, @intCast(cover.w)) * @as(usize, @intCast(cover.h)) * 4) return;
        const name = mpris_art.cacheName(self.gpa, url) catch return;
        defer self.gpa.free(name);
        var pbuf: [1024]u8 = undefined;
        const path = self.pathFor(name, &pbuf) orelse return;
        const cwd = std.Io.Dir.cwd();
        const file = cwd.createFile(self.io, path, .{}) catch return;
        var wbuf: [512]u8 = undefined;
        var wr = file.writer(self.io, &wbuf);
        wr.interface.writeAll(magic) catch {
            file.close(self.io);
            return;
        };
        var hb: [8]u8 = undefined;
        std.mem.writeInt(u32, hb[0..4], @bitCast(cover.w), .little);
        std.mem.writeInt(u32, hb[4..8], @bitCast(cover.h), .little);
        wr.interface.writeAll(&hb) catch {
            file.close(self.io);
            return;
        };
        wr.interface.writeAll(cover.pixels) catch {};
        wr.end() catch {};
        file.close(self.io);
        self.prune();
    }

    fn prune(self: *Self) void {
        if (self.dir.len == 0) return;
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(self.io, self.dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| self.gpa.free(n);
            names.deinit(self.gpa);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".bin")) continue;
            names.append(self.gpa, self.gpa.dupe(u8, e.name) catch continue) catch continue;
        }
        if (names.items.len <= cap_files) return;
        // Oldest first by mtime; delete down to the cap.
        std.mem.sort([]const u8, names.items, self, struct {
            fn lt(ctx: *Self, a: []const u8, b: []const u8) bool {
                const cwd2 = std.Io.Dir.cwd();
                var pa: [1024]u8 = undefined;
                var pb: [1024]u8 = undefined;
                const fa = std.fmt.bufPrint(&pa, "{s}/{s}", .{ ctx.dir, a }) catch return false;
                const fb = std.fmt.bufPrint(&pb, "{s}/{s}", .{ ctx.dir, b }) catch return true;
                const sa = cwd2.statFile(ctx.io, fa, .{}) catch return false;
                const sb = cwd2.statFile(ctx.io, fb, .{}) catch return true;
                return sa.mtime.nanoseconds < sb.mtime.nanoseconds;
            }
        }.lt);
        var i: usize = 0;
        while (i + cap_files < names.items.len) : (i += 1) {
            var del: [1024]u8 = undefined;
            const dp = std.fmt.bufPrint(&del, "{s}/{s}", .{ self.dir, names.items[i] }) catch continue;
            cwd.deleteFile(self.io, dp) catch {};
        }
    }
};

fn shared(io: std.Io) *Disk {
    if (shared_disk == null) shared_disk = Disk.init(std.heap.page_allocator, io);
    return &shared_disk.?;
}

/// Find the decoded cover for `key` (an advertised URL, or a private-cache
/// entry's identity). Owned pixels on the caller's allocator.
pub fn find(alloc: std.mem.Allocator, io: std.Io, key: []const u8) ?mpris_art.Cover {
    return shared(io).find(alloc, key);
}

/// Store a decoded cover under `key`. Borrows the pixels.
pub fn store(io: std.Io, key: []const u8, cover: mpris_art.Cover) void {
    shared(io).store(key, cover);
}

fn envStr(key: [:0]const u8) ?[]const u8 {
    const p = getenv(key) orelse return null;
    return std.mem.span(p);
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

test "cover-cache: a stored cover is found by its key alone" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const d = shared(io);
    if (d.dir.len == 0) return error.SkipZigTest;

    // A key no other test (or run) uses, so the entry always starts clean.
    var kbuf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kbuf, "test://cover-cache/{d}/a", .{std.os.linux.getpid()}) catch return error.SkipZigTest;

    var px = try t.allocator.alloc(u8, 4 * 3 * 4);
    defer t.allocator.free(px);
    for (0..12) |i| @memcpy(px[i * 4 .. i * 4 + 4], &[_]u8{ 0x10 + @as(u8, @intCast(i)), 0x20, 0x30, 0xFF });

    d.store(key, .{ .w = 4, .h = 3, .pixels = px });
    var got = d.find(t.allocator, key) orelse return error.TestUnexpectedResult;
    defer got.deinit(t.allocator);
    try t.expectEqual(@as(i32, 4), got.w);
    try t.expectEqual(@as(i32, 3), got.h);
    try t.expectEqualSlices(u8, px, got.pixels);

    // Not the key of that cover: no pixels.
    var other: [64]u8 = undefined;
    const other_key = std.fmt.bufPrint(&other, "test://cover-cache/{d}/b", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    try t.expect(d.find(t.allocator, other_key) == null);
    try t.expect(d.find(t.allocator, "") == null);
}

test "cover-cache: a body that belies its header is a miss" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const d = shared(io);
    if (d.dir.len == 0) return error.SkipZigTest;

    var kbuf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&kbuf, "test://cover-cache/{d}/short", .{std.os.linux.getpid()}) catch return error.SkipZigTest;
    const name = try mpris_art.cacheName(t.allocator, key);
    defer t.allocator.free(name);
    var pbuf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ d.dir, name }) catch return error.SkipZigTest;

    // Header says 4x3; the body is one pixel shy of that.
    var body: [14 + 4 * 3 * 4]u8 = undefined;
    @memcpy(body[0..6], magic);
    std.mem.writeInt(u32, body[6..10], 4, .little);
    std.mem.writeInt(u32, body[10..14], 3, .little);
    @memset(body[14..], 0x55);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body[0 .. body.len - 4] });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try t.expect(d.find(t.allocator, key) == null);
}
