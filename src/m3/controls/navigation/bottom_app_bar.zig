//! M3 bottom app bar.
//!
//! Documented as "container with FAB notch, action icon
//! slots", but the implementation is much smaller than that: `paint` fills an
//! opaque surface rectangle and lays a 1dp black band across its top edge as
//! a shadow. The notch and the icon slots are not drawn at all — `fabD_` is
//! stored, exposed through its setter, and never read again.
//!
//! That is faithful rather than unfinished on this side: the port keeps the
//! unused `fab_diameter` field and the same two draw calls so the two
//! implementations stay line-for-line comparable. If the notch is ever
//! wanted, it is a cut into the top edge arc centred on the FAB.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// M3 Bottom App Bar — container with FAB notch, action icon slots.
pub const BottomAppBar = struct {
    /// Nominal FAB diameter the notch would be cut for. Unused by `paint`,
    /// stored for the setter round-trip.
    pub const kDefaultFabDiameter: f32 = 56.0;

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 80.0,
    fab_d: f32 = kDefaultFabDiameter,

    accent_r: f32 = 0.769,
    accent_g: f32 = 0.659,
    accent_b: f32 = 0.941,
    surface_r: f32 = 0.102,
    surface_g: f32 = 0.075,
    surface_b: f32 = 0.188,
    text_r: f32 = 1.0,
    text_g: f32 = 1.0,
    text_b: f32 = 1.0,
    outline_r: f32 = 0.478,
    outline_g: f32 = 0.416,
    outline_b: f32 = 0.588,

    pub fn setGeometry(self: *BottomAppBar, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *BottomAppBar, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *BottomAppBar, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *BottomAppBar, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *BottomAppBar, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    /// Sets the diameter the notch would use; `paint` does not read it yet.
    pub fn setFabDiameter(self: *BottomAppBar, d: f32) void {
        self.fab_d = d;
    }

    pub fn xPos(self: *const BottomAppBar) f32 {
        return self.x;
    }

    pub fn yPos(self: *const BottomAppBar) f32 {
        return self.y;
    }

    pub fn width(self: *const BottomAppBar) f32 {
        return self.w;
    }

    pub fn height(self: *const BottomAppBar) f32 {
        return self.h;
    }

    pub fn paint(self: *const BottomAppBar, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        cairo.cairo_save(cr);

        // Surface — an opaque rectangle, not a rounded Box.
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_new_path(cr);
        cairo.cairo_rectangle(cr, self.x, self.y, self.w, self.h);
        cairo.cairo_fill(cr);

        // Top edge shadow — a 1dp black band along the upper edge.
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.08);
        cairo.cairo_rectangle(cr, self.x, self.y, self.w, 1);
        cairo.cairo_fill(cr);

        cairo.cairo_restore(cr);
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-bottom-app-bar: paints the surface and its 1dp top band" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 240, 90);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var bar = BottomAppBar{};
    bar.setGeometry(10, 10, 220, 80);
    bar.setSurfaceColor(0.2, 0.1, 0.3);
    bar.setFabDiameter(64);
    bar.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // The setter round-trips even though nothing draws it.
    try t.expectEqual(@as(f32, 64.0), bar.fab_d);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = BottomAppBar{};
    degenerate.setGeometry(0, 0, 0, 0);
    degenerate.paint(cr);
    degenerate.paint(null);
}

test "m3-bottom-app-bar: accessors mirror the geometry" {
    const t = testing;
    var bar = BottomAppBar{};
    bar.setGeometry(5, 7, 200, 64);
    try t.expectEqual(@as(f32, 5.0), bar.xPos());
    try t.expectEqual(@as(f32, 7.0), bar.yPos());
    try t.expectEqual(@as(f32, 200.0), bar.width());
    try t.expectEqual(@as(f32, 64.0), bar.height());
    // Default height is 80.
    var fresh = BottomAppBar{};
    try t.expectEqual(@as(f32, 80.0), fresh.height());
}
