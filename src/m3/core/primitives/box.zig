//! The colored rounded rectangle every m3
//! surface (and every dock widget pill) is built on.
//!
//! `paint` is one pass: an optional drop shadow offset two pixels down, the
//! base fill, then — when `glassy` is set — the same milky lift / rim /
//! outer-glow triple that `slot_pill_style::paint_glass_layers` lays over a
//! dock pill. The dock calls it with `glassy = false` because the pill style
//! adds the glass itself, so both paths must agree on the fill.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

pub const Box = struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
    a: f32 = 0.0,
    radius: f32 = 0.0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,
    glassy: bool = false,
    /// Drop-shadow alpha. Surfaces whose fill rides an opacity knob thin the
    /// shadow with it (`popup_menu_paint`), so a faint card is not just its
    /// shadow; everyone else keeps the design weight.
    shadow_a: f64 = 0.22,

    pub fn setColor(self: *Box, r: f32, g: f32, b: f32, a: f32) void {
        self.r = r;
        self.g = g;
        self.b = b;
        self.a = a;
    }

    pub fn setRadius(self: *Box, rad: f32) void {
        self.radius = rad;
    }

    pub fn setGeometry(self: *Box, x: f32, y: f32, w: f32, h: f32) void {
        self.x = x;
        self.y = y;
        self.w = w;
        self.h = h;
    }

    pub fn setGlassy(self: *Box, g: bool) void {
        self.glassy = g;
    }

    /// The rounded-rect path, built four times per paint: four quarter
    /// arcs when the radius is usable, a plain rectangle otherwise. A
    /// negative radius is not an error — it falls into the `else` branch,
    /// which is what keeps `radius - 1` on a radius-0 box working.
    fn path(cr: *cairo.cairo_t, ix: f64, iy: f64, iw: f64, ih: f64, ir: f64) void {
        const rr = @min(ir, @min(iw, ih) * 0.5);
        if (rr > 0) {
            cairo.cairo_new_path(cr);
            cairo.cairo_arc(cr, ix + rr, iy + rr, rr, std.math.pi, 1.5 * std.math.pi);
            cairo.cairo_arc(cr, ix + iw - rr, iy + rr, rr, 1.5 * std.math.pi, 2.0 * std.math.pi);
            cairo.cairo_arc(cr, ix + iw - rr, iy + ih - rr, rr, 0.0, 0.5 * std.math.pi);
            cairo.cairo_arc(cr, ix + rr, iy + ih - rr, rr, 0.5 * std.math.pi, std.math.pi);
            cairo.cairo_close_path(cr);
        } else {
            cairo.cairo_rectangle(cr, ix, iy, iw, ih);
        }
    }

    pub fn paint(self: *const Box, c: ?*cairo.cairo_t) void {
        const cr = c orelse return;
        const w: f64 = self.w;
        const h: f64 = self.h;
        if (self.w <= 0 or self.h <= 0 or self.a <= 0) return;

        cairo.cairo_save(cr);
        cairo.cairo_translate(cr, self.x, self.y);

        const rad: f64 = self.radius;

        // Soft drop shadow (Hyprland handles the blur; this offset fill reads
        // as lift), then the base path again — the fill above consumed it.
        cairo.cairo_save(cr);
        path(cr, 0, 2.0, w, h, rad);
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, self.shadow_a);
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);
        path(cr, 0, 0, w, h, rad);

        cairo.cairo_set_source_rgba(
            cr,
            @as(f64, self.r),
            @as(f64, self.g),
            @as(f64, self.b),
            @as(f64, self.a),
        );
        cairo.cairo_fill(cr);

        if (self.glassy) {
            const op: f64 = self.a;

            // Milky lift — faint white wash so the fill reads frosted.
            cairo.cairo_save(cr);
            path(cr, 0, 0, w, h, rad);
            cairo.cairo_clip(cr);
            cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.07 * op);
            cairo.cairo_rectangle(cr, 0, 0, w, h);
            cairo.cairo_fill(cr);
            cairo.cairo_restore(cr);

            // Edge light — inner 1 px stroke, soft on top, bright at the
            // bottom.
            cairo.cairo_save(cr);
            const rim = cairo.cairo_pattern_create_linear(0, 0, 0, h);
            cairo.cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.12 * op);
            cairo.cairo_pattern_add_color_stop_rgba(rim, 0.5, 1.0, 1.0, 1.0, 0.05 * op);
            cairo.cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.42 * op);
            cairo.cairo_set_source(cr, rim);
            cairo.cairo_set_line_width(cr, 1.0);
            path(cr, 1.0, 1.0, w - 2.0, h - 2.0, rad - 1.0);
            cairo.cairo_stroke(cr);
            cairo.cairo_pattern_destroy(rim);
            cairo.cairo_restore(cr);

            // Faint outer glow so the edge lifts off the wallpaper.
            cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.08 * op);
            cairo.cairo_set_line_width(cr, 1.0);
            path(cr, 0.5, 0.5, w - 1.0, h - 1.0, rad);
            cairo.cairo_stroke(cr);
        }

        // `rad` is read once and clamped inside each path builder, and the
        // `radius - 1` variant below is allowed to go negative (it falls back
        // to a rectangle).
        cairo.cairo_restore(cr);
    }
};

test "m3-box: degenerate geometry draws nothing" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var empty = Box{};
    empty.paint(cr);
    var transparent = Box{};
    transparent.setGeometry(0, 0, 20, 20);
    transparent.setColor(1, 1, 1, 0);
    transparent.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "m3-box: fill and glass render" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 80, 80);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var b = Box{};
    b.setColor(0.2, 0.3, 0.4, 1.0);
    b.setRadius(10.0);
    b.setGeometry(8, 8, 40, 40);
    b.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    var g = Box{};
    g.setColor(1.0, 1.0, 1.0, 0.5);
    g.setRadius(8.0);
    g.setGeometry(8, 8, 40, 40);
    g.setGlassy(true);
    g.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // A zero-radius box takes the rectangle branch even when glassy asks for
    // `radius - 1`.
    var sq = Box{};
    sq.setColor(1.0, 0.0, 0.0, 1.0);
    sq.setGeometry(50, 50, 20, 20);
    sq.setGlassy(true);
    sq.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
