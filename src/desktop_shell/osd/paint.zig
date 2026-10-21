const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const cairo_helpers = @import("../shared/cairo_helpers.zig");

pub fn paintOsd(cr: ?*cairo.cairo_t, w: i32, h: i32, ratio: f64) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_set_source_rgba(c, 0.08, 0.08, 0.1, 0.92);
    cairo_helpers.roundedRect(c, 0, 0, @floatFromInt(w), @floatFromInt(h), 16.0);
    cairo.cairo_fill(c);
    const bw = @as(f64, @floatFromInt(w - 32)) * @max(0.0, @min(1.0, ratio));
    cairo.cairo_set_source_rgba(c, 0.9, 0.9, 0.9, 0.9);
    cairo_helpers.roundedRect(c, 16, @as(f64, @floatFromInt(h)) - 24.0, bw, 8.0, 3.0);
    cairo.cairo_fill(c);
}

test "osd-paint: pill + bar" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 300, 80);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintOsd(cr, 300, 80, 0.7);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
