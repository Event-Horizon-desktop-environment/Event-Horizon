//! Warm screen shots on disk: the dock refreshes these every few seconds
//! so the overview opens on instant backdrops instead of paying for the
//! screencopy round trip itself. One raw BGRA file per output (`w,h` as
//! little-endian u32, then `w*h*4` bytes), written temp-and-renamed so a
//! concurrent overview never reads a torn file. Thumbnails only — cards
//! and rail paint a few hundred pixels, and the live pass replaces these
//! with fresh captures right after open anyway.

const std = @import("std");
const output_copy = @import("output_copy.zig");
const Output = @import("../output.zig").Output;
const paths = @import("../../desktop_shell/common/paths.zig");
const wl = @import("../c.zig").wl;

/// Prefetch thumbnails stay small: they only back cards and rail thumbs.
pub const kPrefetchMaxDim: i32 = 640;

/// A cache is fresh while the dock's 5s prefetcher has touched it within
/// twice its period. Fresher than this, the overview opens on the cache
/// and skips its blocking live pass entirely.
pub const kCacheFreshMs: u64 = 10_000;

fn nowNs() i128 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, @intCast(@max(ts.sec, 0))) * 1_000_000_000 + @as(i128, @intCast(@max(ts.nsec, 0)));
}

/// Identity for cache validation: mtime plus size.
pub const FileId = struct {
    mtime_ns: i128,
    size: u64,
};

/// mtime+size for any path, null when it cannot be stated.
pub fn fileId(io: std.Io, path: []const u8) ?FileId {
    const parent = std.fs.path.dirname(path) orelse return null;
    const base = std.fs.path.basename(path);
    var dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch return null;
    defer dir.close(io);
    const st = dir.statFile(io, base, .{}) catch return null;
    return .{ .mtime_ns = st.mtime.nanoseconds, .size = st.size };
}

/// Age of the oldest cached thumbnail, or huge when any output's file is
/// missing. The overview opens on the cache only when every output has a
/// fresh one.
pub fn cacheAgeMs(io: std.Io, dir_path: []const u8, outputs: []const *Output) u64 {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{}) catch return std.math.maxInt(u64);
    defer dir.close(io);
    var worst: i128 = 0;
    var any = false;
    const now = nowNs();
    for (outputs) |o| {
        if (o.name.len == 0) continue;
        any = true;
        var fbuf: [224]u8 = undefined;
        const st = dir.statFile(io, fileName(o.name, false, &fbuf), .{}) catch return std.math.maxInt(u64);
        const age = now - st.mtime.nanoseconds;
        if (age > worst) worst = age;
    }
    if (!any or worst < 0) return 0;
    return @intCast(@divTrunc(worst, 1_000_000));
}

/// The `<cache>/shots` directory, created on demand. Null when no cache
/// root resolves — prefetch then quietly stays off.
pub fn dirPath(
    alloc: std.mem.Allocator,
    io: std.Io,
    xdg_cache_home: ?[]const u8,
    home: ?[]const u8,
) ?[]u8 {
    const base = paths.cacheDir(alloc, xdg_cache_home, home) catch return null;
    defer alloc.free(base);
    const full = std.fs.path.join(alloc, &.{ base, "shots" }) catch return null;
    std.Io.Dir.cwd().createDirPath(io, full) catch {
        alloc.free(full);
        return null;
    };
    return full;
}

/// One prefetch pass over every named output, concurrently. Loop level
/// only — the copies dispatch on their own. Returns how many thumbnails
/// landed.
pub fn prefetch(
    alloc: std.mem.Allocator,
    io: std.Io,
    display: ?*wl.wl_display,
    mgr: ?*wl.zwlr_screencopy_manager_v1,
    shm: ?*wl.wl_shm,
    outputs: []const *Output,
    dir_path: []const u8,
) u32 {
    if (display == null or mgr == null or shm == null) return 0;
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{}) catch return 0;
    defer dir.close(io);
    const objs = alloc.alloc(?*wl.wl_output, outputs.len) catch return 0;
    defer alloc.free(objs);
    for (outputs, 0..) |o, i| {
        objs[i] = if (o.obj != null and o.name.len > 0) o.obj else null;
    }
    const results = output_copy.copyOutputs(alloc, display, mgr, shm, objs, kPrefetchMaxDim) catch return 0;
    defer alloc.free(results);
    var n: u32 = 0;
    for (results, 0..) |r, i| {
        if (!r.ok) continue;
        defer alloc.free(r.shot.bgra);
        save(io, dir, outputs[i].name, r.shot) catch continue;
        n += 1;
    }
    return n;
}

/// Load every cached thumbnail for `outputs` into the caller's store.
/// Stale files are fine — the live pass replaces them right after open.
pub fn loadInto(
    shots: anytype,
    io: std.Io,
    dir_path: []const u8,
    outputs: []const *Output,
) u32 {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{}) catch return 0;
    defer dir.close(io);
    var n: u32 = 0;
    for (outputs) |o| {
        if (o.name.len == 0) continue;
        const shot = load(shots.alloc, io, dir, o.name) catch continue;
        shots.put(o.name, shot) catch {
            var s = shot;
            s.deinit(shots.alloc);
            continue;
        };
        n += 1;
    }
    return n;
}

fn fileName(name: []const u8, tmp: bool, buf: []u8) []u8 {
    var n: usize = @min(name.len, 200);
    if (n + 9 > buf.len) n = buf.len - 9;
    @memcpy(buf[0..n], name[0..n]);
    for (buf[0..n]) |*b| {
        if (b.* == '/' or b.* == 0) b.* = '_';
    }
    @memcpy(buf[n .. n + 5], ".bgra");
    if (!tmp) return buf[0 .. n + 5];
    @memcpy(buf[n + 5 .. n + 9], ".tmp");
    return buf[0 .. n + 9];
}

fn save(io: std.Io, dir: std.Io.Dir, name: []const u8, shot: output_copy.Shot) !void {
    var fbuf: [224]u8 = undefined;
    const final = fileName(name, false, &fbuf);
    var tbuf: [224]u8 = undefined;
    const tmp = fileName(name, true, &tbuf);
    const file = try dir.createFile(io, tmp, .{});
    var wbuf: [512]u8 = undefined;
    var wr = file.writer(io, &wbuf);
    var head: [8]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], @intCast(shot.width), .little);
    std.mem.writeInt(u32, head[4..8], @intCast(shot.height), .little);
    wr.interface.writeAll(&head) catch {
        file.close(io);
        return error.WriteFailed;
    };
    wr.interface.writeAll(shot.bgra) catch {
        file.close(io);
        return error.WriteFailed;
    };
    wr.end() catch {
        file.close(io);
        return error.WriteFailed;
    };
    file.close(io);
    try dir.rename(tmp, dir, final, io);
}

fn load(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !output_copy.Shot {
    var fbuf: [224]u8 = undefined;
    const path = fileName(name, false, &fbuf);
    const data = dir.readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch return error.BadCache;
    errdefer alloc.free(data);
    if (data.len < 8) return error.BadCache;
    const w: i32 = @intCast(std.mem.readInt(u32, data[0..4], .little));
    const h: i32 = @intCast(std.mem.readInt(u32, data[4..8], .little));
    if (w <= 0 or h <= 0 or w > 4096 or h > 4096) return error.BadCache;
    const want: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    if (want != data.len - 8) return error.BadCache;
    const bgra = try alloc.dupe(u8, data[8..]);
    alloc.free(data);
    return .{ .width = w, .height = h, .bgra = bgra };
}

test "wl-capture-shot-cache: save then load round-trips" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var path_buf: [64]u8 = undefined;
    const sub = std.fmt.bufPrint(&path_buf, "/tmp/eh-shot-cache-test-{d}", .{std.os.linux.getpid()}) catch unreachable;
    cwd.createDirPath(io, sub) catch {};
    var file_buf: [96]u8 = undefined;
    const stale = std.fmt.bufPrint(&file_buf, "{s}/DP-1.bgra", .{sub}) catch unreachable;
    defer cwd.deleteFile(io, stale) catch {};
    var dir = cwd.openDir(io, sub, .{}) catch unreachable;
    defer dir.close(io);
    const px = try t.allocator.alloc(u8, 2 * 1 * 4);
    defer t.allocator.free(px);
    @memset(px, 0x7f);
    try save(io, dir, "DP-1", .{ .width = 2, .height = 1, .bgra = px });
    var shot = try load(t.allocator, io, dir, "DP-1");
    defer shot.deinit(t.allocator);
    try t.expectEqual(@as(i32, 2), shot.width);
    try t.expectEqual(@as(i32, 1), shot.height);
    try t.expectEqual(@as(usize, 8), shot.bgra.len);
    try t.expectError(error.BadCache, load(t.allocator, io, dir, "nope"));
}
