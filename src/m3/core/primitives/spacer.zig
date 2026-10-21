//! Flexible empty space for layout.
//!
//! A spacer occupies available space inside a `Flex` container and paints
//! nothing. Its only real state is the minimum size it will refuse to shrink
//! below; the geometry fields exist so a layout pass can report where the
//! spacer ended up even though nothing is drawn there.

const std = @import("std");

/// Flexible empty space for layout. Occupies available space in Flex
/// containers. Invisible; does not paint.
pub const Spacer = struct {
    min_w: f32 = 0.0,
    min_h: f32 = 0.0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,

    /// `mw`/`mh` rather than `width`/`height`, which would shadow the
    /// accessor methods of the same name.
    pub fn setMinSize(self: *Spacer, mw: f32, mh: f32) void {
        self.min_w = mw;
        self.min_h = mh;
    }

    pub fn setGeometry(self: *Spacer, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn x0(self: *const Spacer) f32 {
        return self.x;
    }

    pub fn y0(self: *const Spacer) f32 {
        return self.y;
    }

    pub fn width(self: *const Spacer) f32 {
        return self.w;
    }

    pub fn height(self: *const Spacer) f32 {
        return self.h;
    }

    pub fn minWidth(self: *const Spacer) f32 {
        return self.min_w;
    }

    pub fn minHeight(self: *const Spacer) f32 {
        return self.min_h;
    }

    /// Deliberately empty — a spacer draws nothing.
    /// paint(cairo_t*) const {}`. It still takes the context so `Flex` can
    /// call paint on every child uniformly.
    pub fn paint(self: *const Spacer, c: ?*cairo.cairo_t) void {
        _ = self;
        _ = c;
    }
};

const cairo = @import("../../../wl/buffer/shm.zig").cairo;

test "m3-spacer: holds geometry and paints nothing" {
    const t = std.testing;
    var s = Spacer{};
    s.setMinSize(8, 4);
    s.setGeometry(10, 20, 30, 40);
    try t.expectEqual(@as(f32, 8), s.minWidth());
    try t.expectEqual(@as(f32, 4), s.minHeight());
    try t.expectEqual(@as(f32, 10), s.x0());
    try t.expectEqual(@as(f32, 40), s.height());

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 16, 16);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    // Painting must leave the context untouched — no path, no status change.
    s.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    // A null context is not an error either; the dock paints with one.
    s.paint(null);
}
