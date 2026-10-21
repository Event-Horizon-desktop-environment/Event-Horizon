const std = @import("std");
const cairo = @import("../wl/buffer/shm.zig").cairo;
const tokens = @import("tokens.zig");
const cairo_helpers = @import("../desktop_shell/shared/cairo_helpers.zig");

pub fn paintButton(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, hover: bool, pressed: bool) void {
    if (cr == null) return;
    const c = cr.?;
    if (pressed) {
        cairo.cairo_set_source_rgba(c, tokens.Tokens.accent.r * 0.7, tokens.Tokens.accent.g * 0.7, tokens.Tokens.accent.b * 0.7, 1.0);
    } else if (hover) {
        cairo.cairo_set_source_rgba(c, tokens.Tokens.surface.r * 1.4, tokens.Tokens.surface.g * 1.4, tokens.Tokens.surface.b * 1.4, 1.0);
    } else {
        cairo.cairo_set_source_rgba(c, tokens.Tokens.surface.r, tokens.Tokens.surface.g, tokens.Tokens.surface.b, 1.0);
    }
    cairo_helpers.roundedRect(c, x, y, w, h, tokens.Tokens.corner_md);
    cairo.cairo_fill(c);
}

pub fn paintCard(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_set_source_rgba(c, tokens.Tokens.surface.r, tokens.Tokens.surface.g, tokens.Tokens.surface.b, 1.0);
    cairo_helpers.roundedRect(c, x, y, w, h, tokens.Tokens.corner_lg);
    cairo.cairo_fill(c);
    cairo.cairo_set_source_rgba(c, tokens.Tokens.outline.r, tokens.Tokens.outline.g, tokens.Tokens.outline.b, 0.4);
    cairo.cairo_set_line_width(c, 1.0);
    cairo_helpers.roundedRect(c, x + 0.5, y + 0.5, w - 1.0, h - 1.0, tokens.Tokens.corner_lg - 1.0);
    cairo.cairo_stroke(c);
}

pub fn paintSlider(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, ratio: f64) void {
    if (cr == null) return;
    const c = cr.?;
    const r = @max(0.0, @min(1.0, ratio));
    cairo.cairo_set_source_rgba(c, 0.3, 0.3, 0.35, 1.0);
    cairo_helpers.roundedRect(c, x, y, w, 6.0, 3.0);
    cairo.cairo_fill(c);
    cairo.cairo_set_source_rgba(c, tokens.Tokens.accent.r, tokens.Tokens.accent.g, tokens.Tokens.accent.b, 1.0);
    cairo_helpers.roundedRect(c, x, y, w * r, 6.0, 3.0);
    cairo.cairo_fill(c);
    const kx = x + w * r;
    cairo.cairo_arc(c, kx, y + 3.0, 9.0, 0, 2.0 * std.math.pi);
    cairo.cairo_fill(c);
}

pub fn paintToggle(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, on: bool) void {
    if (cr == null) return;
    const c = cr.?;
    if (on) {
        cairo.cairo_set_source_rgba(c, tokens.Tokens.accent.r, tokens.Tokens.accent.g, tokens.Tokens.accent.b, 1.0);
    } else {
        cairo.cairo_set_source_rgba(c, 0.3, 0.3, 0.35, 1.0);
    }
    cairo_helpers.roundedRect(c, x, y, w, w / 2.0, w / 4.0);
    cairo.cairo_fill(c);
    const kx = if (on) x + w - w / 4.0 else x + w / 4.0;
    cairo.cairo_set_source_rgb(c, 1.0, 1.0, 1.0);
    cairo.cairo_arc(c, kx, y + w / 4.0, w / 4.0 - 2.0, 0, 2.0 * std.math.pi);
    cairo.cairo_fill(c);
}

test "m3-controls: all paint without error" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 300, 200);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintButton(cr, 10, 10, 100, 36, true, false);
    paintButton(cr, 10, 50, 100, 36, false, true);
    paintCard(cr, 10, 100, 200, 80);
    paintSlider(cr, 10, 190, 200, 0.6);
    paintToggle(cr, 220, 10, 48, true);
    paintToggle(cr, 220, 50, 48, false);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
