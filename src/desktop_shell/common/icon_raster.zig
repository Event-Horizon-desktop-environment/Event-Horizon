const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const decode = @import("../../wallpaper/decode.zig");

pub const RsvgHandle = opaque {};
pub const RsvgRectangle = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};
pub const RsvgDimensionData = extern struct {
    width: c_int,
    height: c_int,
    em: f64,
    ex: f64,
};

extern fn rsvg_handle_new_from_file(filename: [*c]const u8, err: ?*?*anyopaque) ?*RsvgHandle;
extern fn rsvg_handle_close(handle: ?*RsvgHandle, err: ?*?*anyopaque) c_int;
extern fn rsvg_handle_render_document(handle: ?*RsvgHandle, cr: ?*cairo.cairo_t, viewport: *const RsvgRectangle, err: ?*?*anyopaque) c_int;
extern fn rsvg_handle_get_intrinsic_dimensions(handle: ?*RsvgHandle, has_width: *c_int, w: *c_int, has_height: *c_int, h: *c_int, has_viewbox: *c_int, vb: *RsvgRectangle) void;
extern fn g_object_unref(object: ?*anyopaque) void;

pub const Pixels = struct {
    w: i32,
    h: i32,
    /// Always laid out the way cairo's `CAIRO_FORMAT_ARGB32` reads it: a
    /// native-endian `0xAARRGGBB` word, i.e. bytes `B,G,R,A`, with the colour
    /// channels already premultiplied by alpha. `loadSvg` gets this for free
    /// because librsvg paints straight into a cairo surface; PNGs come out of
    /// stb_image as straight `R,G,B,A` and are converted here. Skipping the
    /// swap renders every PNG icon with red and blue exchanged.
    data: []u8,
};

pub fn loadPng(alloc: std.mem.Allocator, path: []const u8) ?Pixels {
    const img = decode.loadRgba(alloc, path) orelse return null;
    toCairoBgra(img.pixels);
    return .{ .w = img.w, .h = img.h, .data = img.pixels };
}

fn toCairoBgra(px: []u8) void {
    var i: usize = 0;
    while (i + 3 < px.len) : (i += 4) {
        const a: u32 = px[i + 3];
        const r: u32 = px[i];
        const g: u32 = px[i + 1];
        const b: u32 = px[i + 2];
        if (a == 0) {
            px[i] = 0;
            px[i + 1] = 0;
            px[i + 2] = 0;
            continue;
        }
        if (a < 255) {
            px[i] = @intCast((b * a + 127) / 255);
            px[i + 1] = @intCast((g * a + 127) / 255);
            px[i + 2] = @intCast((r * a + 127) / 255);
        } else {
            px[i] = @intCast(b);
            px[i + 1] = @intCast(g);
            px[i + 2] = @intCast(r);
        }
    }
}

pub fn freePixels(alloc: std.mem.Allocator, p: *Pixels) void {
    alloc.free(p.data);
    p.* = .{ .w = 0, .h = 0, .data = &.{} };
}

pub fn loadSvg(alloc: std.mem.Allocator, path: []const u8, size: i32) ?Pixels {
    var zbuf: [1024:0]u8 = [_:0]u8{0} ** 1024;
    if (path.len >= zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    const handle = rsvg_handle_new_from_file(&zbuf, null) orelse return null;
    defer g_object_unref(handle);
    _ = rsvg_handle_close(handle, null);
    // Cairo/pixman render straight into this buffer (`create_for_data`
    // below), and image data must be 16-byte aligned — a plain `u8`
    // allocation only guarantees 1 byte, so an arena sitting at an odd
    // offset hands back a pointer librsvg silently renders nothing into.
    const px = alloc.alignedAlloc(u8, .@"16", @intCast(size * size * 4)) catch return null;
    errdefer alloc.free(px);
    @memset(px, 0);
    const surf = cairo.cairo_image_surface_create_for_data(px.ptr, cairo.CAIRO_FORMAT_ARGB32, size, size, size * 4);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        alloc.free(px);
        return null;
    }
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    if (cairo.cairo_status(cr) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_destroy(cr);
        alloc.free(px);
        return null;
    }
    defer cairo.cairo_destroy(cr);
    const vp = RsvgRectangle{ .x = 0, .y = 0, .width = @floatFromInt(size), .height = @floatFromInt(size) };
    if (rsvg_handle_render_document(handle, cr, &vp, null) == 0) {
        alloc.free(px);
        return null;
    }
    cairo.cairo_surface_flush(surf);
    // Normalize to a plain align-1 buffer: `Pixels.data` is `[]u8`, which
    // would erase the 16-byte alignment above, and every later free (cache
    // teardown, direct owners like the distro logo) goes through plain
    // `free` — DebugAllocator aborts on that mismatch. One copy per decode;
    // decodes are cached, frames never re-decode.
    const out = alloc.dupe(u8, px) catch {
        alloc.free(px);
        return null;
    };
    alloc.free(px);
    return .{ .w = size, .h = size, .data = out };
}

test "icon-raster: missing files return null" {
    const t = std.testing;
    try t.expect(loadPng(t.allocator, "/nonexistent-x.png") == null);
    try t.expect(loadSvg(t.allocator, "/nonexistent-x.svg", 48) == null);
}

test "icon-raster: png pixels are converted to premultiplied cairo BGRA" {
    const t = std.testing;

    // stb hands us straight R,G,B,A. cairo wants B,G,R,A premultiplied.
    var semi = [_]u8{ 200, 100, 50, 128 };
    toCairoBgra(&semi);
    try t.expectEqual(@as(u8, 25), semi[0]); // blue * a
    try t.expectEqual(@as(u8, 50), semi[1]); // green * a
    try t.expectEqual(@as(u8, 100), semi[2]); // red * a
    try t.expectEqual(@as(u8, 128), semi[3]);

    var solid = [_]u8{ 10, 20, 30, 255 };
    toCairoBgra(&solid);
    try t.expectEqual(@as(u8, 30), solid[0]);
    try t.expectEqual(@as(u8, 20), solid[1]);
    try t.expectEqual(@as(u8, 10), solid[2]);
    try t.expectEqual(@as(u8, 255), solid[3]);

    // Fully transparent pixels must not keep stale colour behind them.
    var clear = [_]u8{ 9, 9, 9, 0 };
    toCairoBgra(&clear);
    try t.expectEqual(@as(u8, 0), clear[0]);
    try t.expectEqual(@as(u8, 0), clear[1]);
    try t.expectEqual(@as(u8, 0), clear[2]);
}
