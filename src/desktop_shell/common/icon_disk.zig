//! Disk cache for resolved app icons, so a fresh process — the overview
//! grid or the start menu — opens with its art already on hand instead of
//! re-decoding every theme file.
//!
//! One file per (theme, icon name, source path, source mtime/size, target
//! px): 6 magic bytes, w/h as u32le, then raw ARGB32 pixels. The source
//! stat rides the key, so an edited theme file invalidates itself. Capped
//! at 512 files, oldest-evicted on insert. Both consumers share the one
//! directory; the key's target px keeps their sizes apart.

const std = @import("std");
const logz = @import("../../logz.zig");

const magic = "EHIC01";
const cap_files: usize = 512;

pub const Disk = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8 = "",
    /// Saves since the last prune. Pruning stats/iterates the whole directory,
    /// so it runs periodically rather than on every insert.
    saves: u32 = 0,

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
        const c = @import("c_stdlib");
        const home = if (c.getenv("XDG_CACHE_HOME")) |p| std.mem.span(p) else null;
        const base = home orelse blk: {
            const h = if (c.getenv("HOME")) |p| std.mem.span(p) else return error.NoHome;
            break :blk try std.fs.path.join(gpa, &.{ h, ".cache" });
        };
        defer if (home == null) gpa.free(base);
        // Testing never pollutes the live shell's cache.
        const iso = if (c.getenv("EH_ZIG_ISOLATED")) |p| std.mem.span(p).len > 0 else false;
        return std.fs.path.join(gpa, &.{ base, if (iso) "Event-Horizon-zig" else "Event-Horizon", "app-icons" });
    }

    /// Hex key for one icon, or null when the source cannot be stated
    /// (the caller then skips the disk entirely).
    pub fn key(self: *Self, theme: []const u8, name: []const u8, src_path: []const u8, px: i32, out: *[16]u8) ?[]const u8 {
        const st = std.Io.Dir.cwd().statFile(self.io, src_path, .{}) catch return null;
        var buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{s}|{s}|{s}|{d}|{d}|{d}", .{
            theme, name, src_path, st.size, st.mtime.nanoseconds, px,
        }) catch return null;
        const h = std.hash.Wyhash.hash(0, body);
        const hex = std.fmt.bufPrint(out, "{x:0>16}", .{h}) catch return null;
        return hex;
    }

    fn pathFor(self: *Self, hexkey: []const u8, buf: []u8) ?[]const u8 {
        if (self.dir.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/{s}.ehicon", .{ self.dir, hexkey }) catch null;
    }

    /// Owned pixels on hit; the header size must match the payload.
    pub fn load(self: *Self, hexkey: []const u8) ?struct { pixels: []u8, w: i32, h: i32 } {
        var pbuf: [1024]u8 = undefined;
        const path = self.pathFor(hexkey, &pbuf) orelse return null;
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(4 << 20)) catch return null;
        errdefer self.gpa.free(data);
        if (data.len < 14 or !std.mem.eql(u8, data[0..6], magic)) {
            self.gpa.free(data);
            return null;
        }
        const w: i32 = @bitCast(std.mem.readInt(u32, data[6..10], .little));
        const h: i32 = @bitCast(std.mem.readInt(u32, data[10..14], .little));
        if (w <= 0 or h <= 0 or w > 512 or h > 512) {
            self.gpa.free(data);
            return null;
        }
        if (data.len != 14 + @as(usize, @intCast(w * h)) * 4) {
            self.gpa.free(data);
            return null;
        }
        const pixels = self.gpa.dupe(u8, data[14..]) catch {
            self.gpa.free(data);
            return null;
        };
        self.gpa.free(data);
        return .{ .pixels = pixels, .w = w, .h = h };
    }

    pub fn save(self: *Self, hexkey: []const u8, pixels: []const u8, w: i32, h: i32) void {
        // `load` refuses these sizes, so writing them would only churn the
        // directory with entries nobody can ever read back.
        if (self.dir.len == 0 or w <= 0 or h <= 0 or w > 512 or h > 512) return;
        if (pixels.len != @as(usize, @intCast(w * h)) * 4) return;
        var pbuf: [1024]u8 = undefined;
        const path = self.pathFor(hexkey, &pbuf) orelse return;
        const cwd = std.Io.Dir.cwd();
        const file = cwd.createFile(self.io, path, .{}) catch |e| {
            logz.log("icons: disk save failed for {s}: {}", .{ path, e });
            return;
        };
        var wbuf: [512]u8 = undefined;
        var wr = file.writer(self.io, &wbuf);
        wr.interface.writeAll(magic) catch {
            file.close(self.io);
            return;
        };
        var hb: [8]u8 = undefined;
        std.mem.writeInt(u32, hb[0..4], @bitCast(w), .little);
        std.mem.writeInt(u32, hb[4..8], @bitCast(h), .little);
        wr.interface.writeAll(&hb) catch {
            file.close(self.io);
            return;
        };
        wr.interface.writeAll(pixels) catch {};
        wr.end() catch {};
        file.close(self.io);
        self.saves +%= 1;
        if (self.saves % 32 == 0) self.prune();
    }

    fn prune(self: *Self) void {
        if (self.dir.len == 0) return;
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(self.io, self.dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        const Item = struct { name: []u8, mtime: i96 };
        var items: std.ArrayList(Item) = .empty;
        defer {
            for (items.items) |it| self.gpa.free(it.name);
            items.deinit(self.gpa);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".ehicon")) continue;
            const owned = self.gpa.dupe(u8, e.name) catch continue;
            var pbuf: [1024]u8 = undefined;
            const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ self.dir, owned }) catch {
                self.gpa.free(owned);
                continue;
            };
            const st = cwd.statFile(self.io, p, .{}) catch {
                self.gpa.free(owned);
                continue;
            };
            items.append(self.gpa, .{ .name = owned, .mtime = st.mtime.nanoseconds }) catch self.gpa.free(owned);
        }
        if (items.items.len <= cap_files) return;
        // Oldest first, one stat per file (not per comparison); delete down
        // to the cap.
        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return a.mtime < b.mtime;
            }
        }.lt);
        var i: usize = 0;
        while (i + cap_files < items.items.len) : (i += 1) {
            var del: [1024]u8 = undefined;
            const dp = std.fmt.bufPrint(&del, "{s}/{s}", .{ self.dir, items.items[i].name }) catch continue;
            cwd.deleteFile(self.io, dp) catch {};
        }
    }
};

test "icon-disk: save/load round trip + key changes with stat" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var d = Disk.init(t.allocator, io);
    defer d.deinit();
    if (d.dir.len == 0) return error.SkipZigTest;
    // Use this very file as the stat source: stable mtime, always present.
    const src = "src/desktop_shell/common/icon_disk.zig";
    var namebuf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&namebuf, "name-{d}", .{std.os.linux.getpid()}) catch "name";
    var k1: [16]u8 = undefined;
    const key = d.key("theme", name, src, 96, &k1) orelse return error.SkipZigTest;
    try t.expect(d.load(key) == null);
    const px = try t.allocator.alloc(u8, 4 * 4 * 4);
    defer t.allocator.free(px);
    @memset(px, 0xAB);
    d.save(key, px, 4, 4);
    const got = d.load(key) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(got.pixels);
    try t.expectEqual(@as(i32, 4), got.w);
    try t.expectEqual(px.len, got.pixels.len);
    try t.expectEqual(@as(u8, 0xAB), got.pixels[0]);
    // Wrong size in key space: a different px makes a different file.
    var k2: [16]u8 = undefined;
    const key2 = d.key("theme", "name", src, 48, &k2) orelse return error.SkipZigTest;
    try t.expect(!std.mem.eql(u8, key, key2));
}
