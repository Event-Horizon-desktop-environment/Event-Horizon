//! On-disk WebP thumbnail cache.
//!
//! The in-memory map in `wallpaper_tab.zig` dies with the Settings process,
//! so every cold open re-decoded the whole gallery from scratch. Persisting
//! each scaled thumbnail next to a key of
//! `path + size + mtime + max_px + version`; thumbnails cached by either
//! tree are hits here.
//!
//! Everything fallible here fails *quiet*: a missing libwebp feature, an
//! unwritable cache dir or a corrupt entry just means "decode the source",
//! never an error surface.

/// Cache version, part of the key — must stay stable.
pub const cache_version = "eh-wallpaper-thumb-v3-webp";
/// WebP quality (82).
pub const webp_quality: f32 = 82.0;
/// Biggest cache file we will read; a 512px WebP thumb is tens of kilobytes.
pub const max_cache_bytes: usize = 8 << 20;

pub const Loaded = struct {
    w: i32,
    h: i32,
    /// Straight (non-premultiplied) RGBA, owned by the caller.
    pixels: []u8,
};

pub const SourceStat = struct {
    size: u64,
    mtime_ns: i96,
};

fn fnv1a64(text: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (text) |ch| {
        hash ^= ch;
        hash *%= 1099511628211;
    }
    return hash;
}

fn hex16(value: u64, out: *[16]u8) void {
    const digits = "0123456789abcdef";
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        out[i] = digits[v & 0xF];
        v >>= 4;
    }
}

/// `$XDG_CACHE_HOME/event-horizon/wallpaper-thumbnails` (`~/.cache`, then `/tmp`).
pub fn cacheDirBuf(out: []u8) ?[]u8 {
    const xdg = env("XDG_CACHE_HOME");
    const home = env("HOME");
    const base: []const u8 = if (xdg) |x| x else if (home) |h| h else "/tmp";
    const tail: []const u8 = if (xdg != null)
        "event-horizon/wallpaper-thumbnails"
    else if (home != null)
        ".cache/event-horizon/wallpaper-thumbnails"
    else
        "event-horizon/wallpaper-thumbnails";
    if (base.len + 1 + tail.len > out.len) return null;
    @memcpy(out[0..base.len], base);
    out[base.len] = '/';
    @memcpy(out[base.len + 1 .. base.len + 1 + tail.len], tail);
    return out[0 .. base.len + 1 + tail.len];
}

/// `<dir>/<fnv-hex>.webp` for this exact source revision at this exact size.
/// `{d}` without a fill spec never emits a sign, so the signed mtime formats
/// cleanly.
pub fn cachePathFor(out: []u8, dir: []const u8, source: []const u8, size: u64, mtime_ns: i96, px: u32) ?[]u8 {
    var key: [2048]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "{s}\n{d}\n{d}\n{d}\n{s}", .{
        source,
        size,
        mtime_ns,
        px,
        cache_version,
    }) catch return null;
    var hex: [16]u8 = undefined;
    hex16(fnv1a64(k), &hex);
    if (dir.len + 1 + hex.len + 5 > out.len) return null;
    @memcpy(out[0..dir.len], dir);
    out[dir.len] = '/';
    @memcpy(out[dir.len + 1 .. dir.len + 1 + 16], &hex);
    @memcpy(out[dir.len + 1 + 16 .. dir.len + 1 + 16 + 5], ".webp");
    return out[0 .. dir.len + 1 + 16 + 5];
}

/// Size + mtime of the source, or null when it cannot be stated.
pub fn statSource(io: std.Io, path: []const u8) ?SourceStat {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds };
}

/// Encode `rgba` (straight, `w*h*4`) and land it at `cache_path`, creating
/// parents. Best-effort: any failure just skips the cache.
pub fn store(io: std.Io, cache_path: []const u8, w: i32, h: i32, rgba: []const u8) void {
    if (w <= 0 or h <= 0) return;
    if (rgba.len != @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) return;
    if (std.fs.path.dirname(cache_path)) |d| {
        std.Io.Dir.cwd().createDirPath(io, d) catch return;
    }
    var out_ptr: [*]u8 = undefined;
    const n = WebPEncodeRGBA(
        rgba.ptr,
        w,
        h,
        w * 4,
        webp_quality,
        &out_ptr,
    );
    if (n == 0) return;
    defer WebPFree(out_ptr);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cache_path, .data = out_ptr[0..n] }) catch {};
}

/// Read `cache_path` and decode it. Validates dimensions against the payload
/// so a truncated file cannot produce a short buffer.
pub fn load(alloc: std.mem.Allocator, io: std.Io, cache_path: []const u8) ?Loaded {
    const data = std.Io.Dir.cwd().readFileAlloc(io, cache_path, alloc, .limited(max_cache_bytes)) catch return null;
    defer alloc.free(data);
    if (data.len == 0) return null;
    var w: c_int = 0;
    var h: c_int = 0;
    const raw = WebPDecodeRGBA(data.ptr, data.len, &w, &h) orelse return null;
    defer WebPFree(raw);
    if (w <= 0 or h <= 0) return null;
    const nbytes: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const pixels = alloc.dupe(u8, raw[0..nbytes]) catch return null;
    return .{ .w = w, .h = h, .pixels = pixels };
}

/// Integer nearest-neighbour downscale of straight RGBA — the same
/// `x*sw/dw, y*sh/dh` mapping `blitCover`'s stretch branch samples with, split
/// out so the worker can persist the scaled bytes before premultiplying them
/// for cairo. A test below locks the two together.
pub fn scaleStraight(dst: []u8, dw: i32, dh: i32, src: []const u8, sw: i32, sh: i32) void {
    if (dw <= 0 or dh <= 0 or sw <= 0 or sh <= 0) return;
    if (src.len < @as(usize, @intCast(sw * sh * 4))) return;
    if (dst.len < @as(usize, @intCast(dw * dh * 4))) return;
    var y: i32 = 0;
    while (y < dh) : (y += 1) {
        const fy: i32 = @intCast(@divTrunc(@as(i64, y) * @as(i64, sh), @as(i64, dh)));
        var x: i32 = 0;
        while (x < dw) : (x += 1) {
            const fx: i32 = @intCast(@divTrunc(@as(i64, x) * @as(i64, sw), @as(i64, dw)));
            const s: usize = @intCast((fy * sw + fx) * 4);
            const d: usize = @intCast((y * dw + x) * 4);
            @memcpy(dst[d .. d + 4], src[s .. s + 4]);
        }
    }
}

/// Straight RGBA bytes to cairo-native premultiplied ARGB32 — the `premult`
/// in `blit.zig`, over a same-size buffer.
pub fn premultInto(dst: []u32, src: []const u8) void {
    const n = @min(dst.len, src.len / 4);
    for (0..n) |i| {
        const r: u32 = src[i * 4];
        const g: u32 = src[i * 4 + 1];
        const b: u32 = src[i * 4 + 2];
        const a: u32 = src[i * 4 + 3];
        dst[i] = premult(r, g, b, a);
    }
}

fn premult(r: u32, g: u32, b: u32, a: u32) u32 {
    if (a >= 255) return (@as(u32, 0xFF) << 24) | (r << 16) | (g << 8) | b;
    if (a == 0) return 0;
    const rr = (r * a + 127) / 255;
    const gg = (g * a + 127) / 255;
    const bb = (b * a + 127) / 255;
    return (a << 24) | (rr << 16) | (gg << 8) | bb;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}


const std = @import("std");

extern fn WebPEncodeRGBA(rgba: [*]const u8, width: c_int, height: c_int, stride: c_int, quality_factor: f32, output: *[*]u8) usize;
extern fn WebPFree(ptr: ?*anyopaque) void;
extern fn WebPDecodeRGBA(data: [*]const u8, data_size: usize, width: *c_int, height: *c_int) ?[*]u8;

test "thumb-disk: the key tracks the exact source revision" {
    const t = std.testing;
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const p1 = cachePathFor(&a, "/c", "/pics/x.png", 100, 200, 512).?;
    const p2 = cachePathFor(&b, "/c", "/pics/x.png", 100, 200, 512).?;
    try t.expectEqualStrings(p1, p2);
    // Any revision detail — size, mtime, requested px — is a new file.
    var c: [256]u8 = undefined;
    try t.expect(!std.mem.eql(u8, p1, cachePathFor(&c, "/c", "/pics/x.png", 101, 200, 512).?));
    try t.expect(!std.mem.eql(u8, p1, cachePathFor(&c, "/c", "/pics/x.png", 100, 201, 512).?));
    try t.expect(!std.mem.eql(u8, p1, cachePathFor(&c, "/c", "/pics/x.png", 100, 200, 256).?));
    try t.expect(!std.mem.eql(u8, p1, cachePathFor(&c, "/c", "/pics/y.png", 100, 200, 512).?));
    try t.expect(std.mem.endsWith(u8, p1, ".webp"));
}

test "thumb-disk: scale-then-premultiply matches the one-pass blit" {
    const t = std.testing;
    const blit = @import("../../wallpaper/blit.zig");
    // Opaque + translucent texels so both premult branches run.
    var src: [6 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..6) |x| {
            const o = (y * 6 + x) * 4;
            src[o] = @intCast(x * 40);
            src[o + 1] = @intCast(y * 40);
            src[o + 2] = 200;
            src[o + 3] = if ((x + y) % 2 == 0) 255 else 128;
        }
    }
    var want: [4 * 3]u32 = [_]u32{0} ** (4 * 3);
    blit.blitCover(&want, 4, 3, &src, 6, 4, .stretch);
    var scaled: [4 * 3 * 4]u8 = undefined;
    scaleStraight(&scaled, 4, 3, &src, 6, 4);
    var got: [4 * 3]u32 = [_]u32{0} ** (4 * 3);
    premultInto(&got, &scaled);
    try t.expectEqualSlices(u32, &want, &got);
}

test "thumb-disk: a store round-trips through the file" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const file = try std.fs.path.join(alloc, &.{ root, "thumb.webp" });
    defer alloc.free(file);

    // Solid red survives lossy WebP nearly exactly; the assert below allows
    // the codec its slack rather than demanding bit equality.
    var rgba: [16 * 16 * 4]u8 = undefined;
    for (0..16 * 16) |i| {
        rgba[i * 4] = 200;
        rgba[i * 4 + 1] = 30;
        rgba[i * 4 + 2] = 30;
        rgba[i * 4 + 3] = 255;
    }
    store(io, file, 16, 16, &rgba);

    const hit = load(alloc, io, file) orelse return error.CacheMiss;
    defer alloc.free(hit.pixels);
    try t.expectEqual(@as(i32, 16), hit.w);
    try t.expectEqual(@as(i32, 16), hit.h);
    var diff: u64 = 0;
    for (hit.pixels, 0..) |v, i| {
        const want: u8 = switch (i % 4) {
            0 => 200,
            1 => 30,
            2 => 30,
            else => 255,
        };
        diff += if (v > want) @as(u64, v - want) else @as(u64, want - v);
    }
    // Average channel error stays tiny at quality 82 on a flat field.
    try t.expect(diff / @as(u64, hit.pixels.len) < 8);

    // A truncated file is a miss, not a short buffer.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "not a webp" });
    try t.expect(load(alloc, io, file) == null);
    // So is a missing one.
    var missing: [512]u8 = undefined;
    const no_file = std.fmt.bufPrint(&missing, "{s}.nope", .{file}) catch return error.NoSpace;
    try t.expect(load(alloc, io, no_file) == null);
}
