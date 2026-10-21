const std = @import("std");
const cairo = @import("../wl/buffer/shm.zig").cairo;

pub const Fit = enum { stretch, fit, fill, tile, center };

pub fn coverScale(img_w: i32, img_h: i32, out_w: i32, out_h: i32, mode: Fit) struct { sw: f64, sh: f64, dx: f64, dy: f64 } {
    if (img_w <= 0 or img_h <= 0 or out_w <= 0 or out_h <= 0) return .{ .sw = 1, .sh = 1, .dx = 0, .dy = 0 };
    const iw: f64 = @floatFromInt(img_w);
    const ih: f64 = @floatFromInt(img_h);
    const ow: f64 = @floatFromInt(out_w);
    const oh: f64 = @floatFromInt(out_h);
    return switch (mode) {
        .stretch => .{ .sw = ow / iw, .sh = oh / ih, .dx = 0, .dy = 0 },
        .fit => blk: {
            const s = @min(ow / iw, oh / ih);
            break :blk .{ .sw = s, .sh = s, .dx = (ow - iw * s) / 2.0, .dy = (oh - ih * s) / 2.0 };
        },
        .fill, .center => blk: {
            const s = @max(ow / iw, oh / ih);
            break :blk .{ .sw = s, .sh = s, .dx = (ow - iw * s) / 2.0, .dy = (oh - ih * s) / 2.0 };
        },
        .tile => .{ .sw = 1, .sh = 1, .dx = 0, .dy = 0 },
    };
}

pub fn paintSolid(cr: ?*cairo.cairo_t, r: f64, g: f64, b: f64) void {
    if (cr) |c| {
        cairo.cairo_set_source_rgb(c, r, g, b);
        cairo.cairo_paint(c);
    }
}

test "wallpaper-paint: cover math" {
    const t = std.testing;
    const f = coverScale(1920, 1080, 1920, 1080, .fill);
    try t.expectEqual(@as(f64, 1.0), f.sw);
    const p = coverScale(100, 100, 200, 100, .fit);
    try t.expectEqual(@as(f64, 1.0), p.sw);
    try t.expectEqual(@as(f64, 50.0), p.dx);
    const z = coverScale(0, 0, 100, 100, .fill);
    try t.expectEqual(@as(f64, 1.0), z.sw);
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 32, 32);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintSolid(cr, 0.1, 0.2, 0.3);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
