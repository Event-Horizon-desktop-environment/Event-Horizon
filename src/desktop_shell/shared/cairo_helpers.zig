//! Two rounded-rect path
//! builders the shell shares.
//!
//! They differ only in how they start: `roundedRect` uses `cairo_new_sub_path`
//! so it can be appended to an existing path, `pathRoundedRect` always starts
//! fresh because callers clip with the result.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const tokens = @import("../../m3/tokens.zig");

pub fn roundedRect(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const c = cr orelse return;
    const rad = @min(r, @min(w * 0.5, h * 0.5));
    cairo.cairo_new_sub_path(c);
    cairo.cairo_arc(c, x + w - rad, y + rad, rad, -std.math.pi / 2.0, 0);
    cairo.cairo_arc(c, x + w - rad, y + h - rad, rad, 0, std.math.pi / 2.0);
    cairo.cairo_arc(c, x + rad, y + h - rad, rad, std.math.pi / 2.0, std.math.pi);
    cairo.cairo_arc(c, x + rad, y + rad, rad, std.math.pi, 3.0 * std.math.pi / 2.0);
    cairo.cairo_close_path(c);
}

pub fn pathRoundedRect(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const c = cr orelse return;
    const r = @min(radius, @min(w * 0.5, h * 0.5));
    const p = std.math.pi;
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, x + w - r, y + r, r, -p * 0.5, 0);
    cairo.cairo_arc(c, x + w - r, y + h - r, r, 0, p * 0.5);
    cairo.cairo_arc(c, x + r, y + h - r, r, p * 0.5, p);
    cairo.cairo_arc(c, x + r, y + r, r, p, p * 1.5);
    cairo.cairo_close_path(c);
}

test "cairo-helpers: both builders produce a filled round rect" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 32);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    roundedRect(cr, 4, 4, 24, 24, 8);
    cairo.cairo_set_source_rgba(cr, 1, 0, 0, 1);
    cairo.cairo_fill(cr);
    pathRoundedRect(cr, 34, 4, 24, 24, 8);
    cairo.cairo_set_source_rgba(cr, 0, 1, 0, 1);
    cairo.cairo_fill(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Oversized radii clamp to half the short side instead of self-crossing.
    roundedRect(cr, 0, 0, 20, 10, 999);
    cairo.cairo_fill(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Null is a no-op rather than a crash.
    roundedRect(null, 0, 0, 1, 1, 1);
    pathRoundedRect(null, 0, 0, 1, 1, 1);
}

/// Filled rounded bar in the theme background (shared by the dock/taskbar
/// bars and plates).
pub fn paintBar(cr: ?*cairo.cairo_t, w: i32, h: i32, radius: f64, opacity: f64) void {
    const c = cr orelse return;
    cairo.cairo_set_source_rgba(c, tokens.Tokens.background.r, tokens.Tokens.background.g, tokens.Tokens.background.b, opacity);
    roundedRect(c, 0, 0, @floatFromInt(w), @floatFromInt(h), radius);
    cairo.cairo_fill(c);
}

/// Layered soft drop shadow: concentric rounded rects grown one step at a
/// time, each ring faded so the *cumulative* coverage falls off
/// quadratically — the edge reads as a gradient without an offscreen blur
/// pass (cairo has no gaussian). Deeper than the old pasted `+2px` slab, so
/// the shape reads as lifted off the wallpaper rather than stamped into it.
/// `spread` is how far past the shape the shadow reaches; `offset_y` drops
/// the whole gradient below the shape, since light comes from above.
/// Colour is always black; `alpha` is the peak opacity right at the shape.
pub fn paintSoftShadow(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    radius: f64,
    alpha: f64,
    offset_y: f64,
    spread: f64,
) void {
    const c = cr orelse return;
    if (w <= 1.0 or h <= 1.0 or alpha <= 0.0 or spread <= 0.0) return;
    // One ring per logical px reads smooth; clamp so a huge spread cannot
    // turn into a fill storm and a tiny one still gets a gradient.
    const n: usize = @intFromFloat(@max(2.0, @min(16.0, spread)));
    const denom: f64 = @as(f64, @floatFromInt(n + 1));
    // `prev` is the transparency left by the rings drawn so far. Ring `i`
    // is solved so the coverage inside it lands exactly on the quadratic
    // target — drawing order then cannot double-darken the core.
    var prev: f64 = 1.0;
    var i: usize = n;
    while (i >= 1) : (i -= 1) {
        const t: f64 = @as(f64, @floatFromInt(i)) / denom; // 0..1 toward the rim
        const target = alpha * (1.0 - t) * (1.0 - t);
        const ring = 1.0 - (1.0 - target) / prev;
        if (ring > 0.002) {
            const grow = spread * t;
            roundedRect(c, x - grow, y - grow + offset_y, w + 2.0 * grow, h + 2.0 * grow, radius + grow);
            cairo.cairo_set_source_rgba(c, 0.0, 0.0, 0.0, ring);
            cairo.cairo_fill(c);
        }
        prev *= 1.0 - ring;
    }
}

test "soft shadow: degenerate geometry is a no-op and full geometry draws" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    paintSoftShadow(null, 0, 0, 10, 10, 2, 0.3, 1, 5);
    paintSoftShadow(cr, 0, 0, 0, 0, 2, 0.3, 1, 5); // degenerate: no-op
    paintSoftShadow(cr, 4, 4, 20, 20, 6, 0.0, 2, 6); // zero alpha: no-op
    paintSoftShadow(cr, 4, 4, 20, 20, 6, 0.3, 2, 6);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
