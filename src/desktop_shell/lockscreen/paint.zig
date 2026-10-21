const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

pub fn paintLock(cr: ?*cairo.cairo_t, w: i32, h: i32, failed: bool) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_set_source_rgb(c, 0.05, 0.05, 0.08);
    cairo.cairo_paint(c);
    const cx: f64 = @as(f64, @floatFromInt(w)) / 2.0;
    const cy: f64 = @as(f64, @floatFromInt(h)) / 2.0 - 40.0;
    if (failed) {
        cairo.cairo_set_source_rgb(c, 0.8, 0.2, 0.2);
    } else {
        cairo.cairo_set_source_rgb(c, 0.9, 0.9, 0.9);
    }
    cairo.cairo_arc(c, cx, cy, 48.0, 0, 2.0 * std.math.pi);
    cairo.cairo_stroke(c);
}

test "lockscreen-paint: avatar ring" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 320, 240);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintLock(cr, 320, 240, false);
    paintLock(cr, 320, 240, true);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
