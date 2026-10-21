//! Per-output screen shots for workspace cards and rail thumbs.
//!
//! Every bound output is captured once through wlr-screencopy and keyed by
//! the output's name — exactly the monitor name each workspace carries — so
//! a card or thumb asks for its monitor and gets a backdrop. A capture that
//! fails logs and leaves whatever was there before: the previous shot, or
//! the card's own fill.

const std = @import("std");
const logz = @import("../../logz.zig");
const tiles = @import("tiles.zig");
const decode = @import("../../wallpaper/decode.zig");
const stream_mod = @import("../../wl/capture/toplevel_stream.zig");
const output_copy = @import("../../wl/capture/output_copy.zig");
const shot_cache = @import("../../wl/capture/shot_cache.zig");
const Output = @import("../../wl/output.zig").Output;
const wl = @import("../../wl/c.zig").wl;

/// Wallpaper file captures are thumbnailed to this size: cards and rail
/// only ever paint a few hundred pixels, so keeping full-res RGBA around
/// would burn memory and per-paint scaling time for nothing.
const kWallpaperMaxDim: i32 = 960;
/// Same cap for the live output copies: a 4K screenshot would otherwise be
/// resampled on the CPU every paint just to fill a 600px card.
const kShotMaxDim: i32 = 1280;

pub const Shots = struct {
    alloc: std.mem.Allocator,
    by_name: std.StringHashMap(output_copy.Shot),
    wallpaper: output_copy.Shot = .{},
    /// Source generation for the paint cache: every stored or loaded shot
    /// takes the next number, so a replaced shot can never paint stale.
    seq: u64 = 0,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc, .by_name = .init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        var it = self.by_name.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            e.value_ptr.deinit(self.alloc);
        }
        self.by_name.deinit();
        self.wallpaper.deinit(self.alloc);
    }

    /// Capture every named output once, concurrently. Returns how many landed.
    pub fn fill(
        self: *Self,
        display: ?*wl.wl_display,
        mgr: ?*wl.zwlr_screencopy_manager_v1,
        shm: ?*wl.wl_shm,
        outputs: []const *Output,
    ) u32 {
        if (display == null or mgr == null or shm == null) return 0;
        const objs = self.alloc.alloc(?*wl.wl_output, outputs.len) catch return 0;
        defer self.alloc.free(objs);
        for (outputs, 0..) |o, i| {
            objs[i] = if (o.obj != null and o.name.len > 0) o.obj else null;
        }
        const results = output_copy.copyOutputs(self.alloc, display, mgr, shm, objs, kShotMaxDim) catch |err| {
            logz.log("overview: shots batch failed: {s}", .{@errorName(err)});
            return 0;
        };
        defer self.alloc.free(results);
        var n: u32 = 0;
        for (results, 0..) |r, i| {
            if (!r.ok) {
                if (outputs[i].name.len > 0) logz.log("overview: shot {s} failed", .{outputs[i].name});
                continue;
            }
            self.put(outputs[i].name, r.shot) catch {
                var s = r.shot;
                s.deinit(self.alloc);
                continue;
            };
            n += 1;
        }
        return n;
    }

    /// The shot for a monitor, borrowed: valid until the next capture.
    pub fn frame(self: *Self, monitor: []const u8) ?tiles.LiveFrame {
        if (monitor.len == 0) return null;
        const s = self.by_name.get(monitor) orelse return null;
        if (s.bgra.len == 0) return null;
        return .{ .data = s.bgra, .w = s.width, .h = s.height, .gen = s.gen };
    }

    /// Load the desktop wallpaper file once, thumbnailed to card size.
    /// Occupied cards paint this behind their tiles (a desktop copy would
    /// double-paint the windows); empty cards fall back to it when they
    /// have no monitor shot. `dir_path` enables the disk cache: the file
    /// is decoded once and reloaded in milliseconds while its mtime and
    /// size still match. False when there is no usable file.
    pub fn loadWallpaper(self: *Self, io: std.Io, dir_path: ?[]const u8, path: []const u8) bool {
        self.wallpaper.deinit(self.alloc);
        if (path.len == 0) return false;
        if (dir_path) |dir| {
            if (self.loadWallpaperCache(io, dir, path)) return true;
        }
        var img = decode.loadRgba(self.alloc, path) orelse return false;
        defer img.free(self.alloc);
        const dims = stream_mod.targetDims(img.w, img.h, kWallpaperMaxDim);
        const bgra = stream_mod.downsample(
            self.alloc,
            img.pixels,
            img.w,
            img.h,
            img.w * 4,
            wl.WL_SHM_FORMAT_RGBA8888,
            false,
            kWallpaperMaxDim,
        ) catch return false;
        self.seq += 1;
        self.wallpaper = .{ .width = dims[0], .height = dims[1], .bgra = bgra, .gen = self.seq };
        if (dir_path) |dir| self.saveWallpaperCache(io, dir, path);
        return true;
    }

    const wp_cache_name = "wallpaper.bgra";

    fn loadWallpaperCache(self: *Self, io: std.Io, dir_path: []const u8, path: []const u8) bool {
        const id = shot_cache.fileId(io, path) orelse return false;
        var pbuf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir_path, wp_cache_name }) catch return false;
        const data = std.Io.Dir.cwd().readFileAlloc(io, full, self.alloc, .limited(32 * 1024 * 1024)) catch return false;
        defer self.alloc.free(data);
        if (data.len < 4) return false;
        const plen = std.mem.readInt(u32, data[0..4], .little);
        var off: usize = 4;
        if (plen != path.len or data.len < off + plen + 16 + 8 + 4 + 4) return false;
        if (!std.mem.eql(u8, data[off .. off + plen], path)) return false;
        off += plen;
        const mtime = std.mem.readInt(i128, @as(*const [16]u8, @ptrCast(data.ptr + off)), .little);
        off += 16;
        const size = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(data.ptr + off)), .little);
        off += 8;
        if (mtime != id.mtime_ns or size != id.size) return false;
        const w: i32 = @intCast(std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(data.ptr + off)), .little));
        off += 4;
        const h: i32 = @intCast(std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(data.ptr + off)), .little));
        off += 4;
        if (w <= 0 or h <= 0 or w > 2048 or h > 2048) return false;
        const want: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        if (want != data.len - off) return false;
        const bgra = self.alloc.dupe(u8, data[off..]) catch return false;
        self.seq += 1;
        self.wallpaper = .{ .width = w, .height = h, .bgra = bgra, .gen = self.seq };
        return true;
    }

    fn saveWallpaperCache(self: *Self, io: std.Io, dir_path: []const u8, path: []const u8) void {
        const id = shot_cache.fileId(io, path) orelse return;
        const wp = self.wallpaper;
        if (wp.bgra.len == 0) return;
        var pbuf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir_path, wp_cache_name }) catch return;
        const tmp_full = std.fmt.bufPrint(&pbuf, "{s}/{s}.tmp", .{ dir_path, wp_cache_name }) catch return;
        const file = std.Io.Dir.cwd().createFile(io, tmp_full, .{}) catch return;
        var wbuf: [512]u8 = undefined;
        var wr = file.writer(io, &wbuf);
        var head: [32]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], @intCast(path.len), .little);
        wr.interface.writeAll(head[0..4]) catch {
            file.close(io);
            return;
        };
        wr.interface.writeAll(path) catch {
            file.close(io);
            return;
        };
        std.mem.writeInt(i128, head[0..16], id.mtime_ns, .little);
        std.mem.writeInt(u64, head[16..24], id.size, .little);
        std.mem.writeInt(u32, head[24..28], @intCast(wp.width), .little);
        std.mem.writeInt(u32, head[28..32], @intCast(wp.height), .little);
        wr.interface.writeAll(&head) catch {
            file.close(io);
            return;
        };
        wr.interface.writeAll(wp.bgra) catch {
            file.close(io);
            return;
        };
        wr.end() catch {
            file.close(io);
            return;
        };
        file.close(io);
        const cwd = std.Io.Dir.cwd();
        cwd.rename(tmp_full, cwd, full, io) catch {};
    }

    /// The loaded wallpaper, borrowed; null until loadWallpaper lands one.
    pub fn wallpaperFrame(self: *Self) ?tiles.LiveFrame {
        if (self.wallpaper.bgra.len == 0) return null;
        return .{ .data = self.wallpaper.bgra, .w = self.wallpaper.width, .h = self.wallpaper.height, .gen = self.wallpaper.gen };
    }

    /// Take ownership of one shot under `name`, replacing any older one.
    pub fn put(self: *Self, name: []const u8, shot_in: output_copy.Shot) !void {
        var shot = shot_in;
        self.seq += 1;
        shot.gen = self.seq;
        const gop = try self.by_name.getOrPut(name);
        if (gop.found_existing) {
            gop.value_ptr.deinit(self.alloc);
            gop.value_ptr.* = shot;
            return;
        }
        errdefer _ = self.by_name.remove(name);
        errdefer {
            var s = shot;
            s.deinit(self.alloc);
        }
        gop.key_ptr.* = try self.alloc.dupe(u8, name);
        gop.value_ptr.* = shot;
    }
};

test "overview-shots: empty fill and unknown monitors stay empty" {
    const t = std.testing;
    var shots = Shots.init(t.allocator);
    defer shots.deinit();
    try t.expectEqual(@as(u32, 0), shots.fill(null, null, null, &.{}));
    try t.expectEqual(@as(?tiles.LiveFrame, null), shots.frame("DP-1"));
}

test "overview-shots: put then frame by monitor name, replace keeps one" {
    const t = std.testing;
    var shots = Shots.init(t.allocator);
    defer shots.deinit();
    const first = try t.allocator.alloc(u8, 4);
    try shots.put("HDMI-A-1", .{ .width = 1, .height = 1, .bgra = first });
    const fr = shots.frame("HDMI-A-1");
    try t.expect(fr != null);
    try t.expectEqual(@as(i32, 1), fr.?.w);
    try t.expectEqual(@as(?tiles.LiveFrame, null), shots.frame("nope"));
    const second = try t.allocator.alloc(u8, 8);
    try shots.put("HDMI-A-1", .{ .width = 2, .height = 1, .bgra = second });
    try t.expectEqual(@as(usize, 1), shots.by_name.count());
    try t.expectEqual(@as(i32, 2), shots.frame("HDMI-A-1").?.w);
}
