const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

pub fn paintDesktop(cr: ?*cairo.cairo_t, w: i32, h: i32, r: f64, g: f64, b: f64) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_set_source_rgb(c, r, g, b);
    cairo.cairo_paint(c);
    _ = w;
    _ = h;
}

pub fn paintIconPlate(cr: ?*cairo.cairo_t, x: f64, y: f64, size: f64, selected: bool) void {
    if (cr == null) return;
    const c = cr.?;
    if (selected) {
        cairo.cairo_set_source_rgba(c, 0.3, 0.5, 0.9, 0.4);
    } else {
        cairo.cairo_set_source_rgba(c, 0.0, 0.0, 0.0, 0.25);
    }
    cairo.cairo_rectangle(c, x, y, size, size);
    cairo.cairo_fill(c);
}

test "desktop-paint: bg + plate" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintDesktop(cr, 64, 64, 0.1, 0.1, 0.12);
    paintIconPlate(cr, 8, 8, 48, true);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
