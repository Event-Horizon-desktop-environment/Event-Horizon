const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const cairo_helpers = @import("../shared/cairo_helpers.zig");

pub const urgency_colors = [_][3]f64{
    .{ 0.2, 0.6, 1.0 },
    .{ 0.9, 0.9, 0.9 },
    .{ 0.9, 0.25, 0.2 },
};

pub fn paintToast(cr: ?*cairo.cairo_t, w: i32, h: i32, urgency: u8, progress: f64) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_set_source_rgba(c, 0.1, 0.1, 0.12, 0.97);
    cairo_helpers.roundedRect(c, 0, 0, @floatFromInt(w), @floatFromInt(h), 12.0);
    cairo.cairo_fill(c);
    const col = urgency_colors[@min(urgency, 2)];
    cairo.cairo_set_source_rgb(c, col[0], col[1], col[2]);
    cairo.cairo_rectangle(c, 0, 0, 4, @floatFromInt(h));
    cairo.cairo_fill(c);
    if (progress >= 0.0) {
        const bw = @as(f64, @floatFromInt(w)) * @max(0.0, @min(1.0, progress));
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.25);
        cairo.cairo_rectangle(c, 0, @as(f64, @floatFromInt(h)) - 3.0, bw, 3.0);
        cairo.cairo_fill(c);
    }
}

test "toast-paint: urgencies + progress" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 420, 100);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintToast(cr, 420, 100, 0, 0.5);
    paintToast(cr, 420, 100, 2, -1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
