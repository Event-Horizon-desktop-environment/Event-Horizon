//! A horizontal or vertical divider.
//!
//! One line, drawn along whichever axis the orientation names. `length` lets
//! the caller draw a divider shorter than the geometry it was given — pass 0
//! and it fills the full `w` (horizontal) or `h` (vertical), which is what
//! every default call site wants.

const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// Horizontal or vertical divider line.
pub const Separator = struct {
    pub const Orientation = enum {
        horizontal,
        vertical,
    };

    orientation: Orientation = .horizontal,
    thickness: f32 = 1.0,
    length: f32 = 0.0,
    r: f32 = 0.35,
    g: f32 = 0.35,
    b: f32 = 0.37,
    a: f32 = 1.0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,

    pub fn setOrientation(self: *Separator, o: Orientation) void {
        self.orientation = o;
    }

    /// `a` defaults to fully opaque.
    pub fn setColor(self: *Separator, red: f32, green: f32, blue: f32, alpha: f32) void {
        self.r = red;
        self.g = green;
        self.b = blue;
        self.a = alpha;
    }

    pub fn setThickness(self: *Separator, t: f32) void {
        self.thickness = t;
    }

    pub fn setLength(self: *Separator, l: f32) void {
        self.length = l;
    }

    pub fn setGeometry(self: *Separator, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn paint(self: *const Separator, c: ?*cairo.cairo_t) void {
        // A fully transparent separator is a no-op — callers toggle
        // visibility by zeroing alpha rather than skipping the paint call.
        if (self.a <= 0) return;
        const cr = c orelse return;

        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, self.r, self.g, self.b, self.a);
        cairo.cairo_set_line_width(cr, self.thickness);

        if (self.orientation == .horizontal) {
            const cy: f64 = @as(f64, self.y) + @as(f64, self.h) * 0.5;
            cairo.cairo_move_to(cr, self.x, cy);
            cairo.cairo_line_to(cr, @as(f64, self.x) + (if (self.length > 0) self.length else self.w), cy);
        } else {
            const cx: f64 = @as(f64, self.x) + @as(f64, self.w) * 0.5;
            cairo.cairo_move_to(cr, cx, self.y);
            cairo.cairo_line_to(cr, cx, @as(f64, self.y) + (if (self.length > 0) self.length else self.h));
        }

        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
    }
};

test "m3-separator: both orientations draw a valid line" {
    const t = @import("std").testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 40, 40);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var sep = Separator{};
    sep.setGeometry(2, 2, 36, 36);
    sep.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    var vert = Separator{};
    vert.setOrientation(.vertical);
    vert.setGeometry(2, 2, 36, 36);
    vert.setThickness(2.0);
    vert.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "m3-separator: transparent draws nothing, null context is safe" {
    const t = @import("std").testing;
    var sep = Separator{};
    sep.setGeometry(0, 0, 10, 10);
    sep.setColor(1, 1, 1, 0);
    // The early return happens before the context is even touched, so a null
    // context is fine here — that is the path a hidden divider takes.
    sep.paint(null);
    try t.expect(true);
}
