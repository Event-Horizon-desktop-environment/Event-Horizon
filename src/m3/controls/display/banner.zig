//! A persistent message bar with an
//! optional action.
//!
//! The banner is invisible until `set_visible(true)` — `visible` defaults to
//! false, unlike every other control here which defaults to showing. Its
//! paint is a flat rectangle, a 1dp outline band along the bottom edge, the
//! message at `x+16, y+24`, and an optional action right-aligned 16dp from
//! the edge on a baseline 12dp above the bottom.
//!
//! The action is positioned by *measuring* it and subtracting from the right,
//! so it stays flush right regardless of length — but it shares no baseline
//! with the message, which sits near the top of the bar rather than the
//! middle. Both positions are fixed by the layout.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// M3 Banner — persistent message with optional action.
pub const Banner = struct {
    pub const kFontSize: f32 = 14.0;
    /// Message inset from the left, and its baseline from the top.
    pub const kTextX: f32 = 16.0;
    pub const kTextY: f32 = 24.0;
    /// Action inset from the right, and its baseline from the bottom.
    pub const kActionRight: f32 = 16.0;
    pub const kActionBottom: f32 = 12.0;
    /// Bottom edge band thickness and alpha.
    pub const kEdgeThickness: f32 = 1.0;
    pub const kEdgeAlpha: f32 = 0.2;

    text: []const u8 = "",
    action: []const u8 = "",
    visible: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 72.0,

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

    pub fn setText(self: *Banner, t: []const u8) void {
        self.text = t;
    }

    pub fn setAction(self: *Banner, a: []const u8) void {
        self.action = a;
    }

    pub fn setVisible(self: *Banner, v: bool) void {
        self.visible = v;
    }

    pub fn setGeometry(self: *Banner, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *Banner, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Banner, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Banner, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Banner, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn isVisible(self: *const Banner) bool {
        return self.visible;
    }

    pub fn paint(self: *const Banner, c: ?*cairo.cairo_t) void {
        // Hidden, or zero width — note `h` is not checked, exactly as the
        // Only `w_` is checked.
        if (!self.visible or self.w <= 0.0) return;
        const cr = c orelse return;

        cairo.cairo_save(cr);

        // Container.
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_rectangle(cr, self.x, self.y, self.w, self.h);
        cairo.cairo_fill(cr);

        // Bottom edge band, in the outline colour at 20%.
        cairo.cairo_set_source_rgba(cr, self.outline_r, self.outline_g, self.outline_b, kEdgeAlpha);
        cairo.cairo_rectangle(cr, self.x, self.y + self.h - kEdgeThickness, self.w, kEdgeThickness);
        cairo.cairo_fill(cr);

        // Message.
        cairo.cairo_select_font_face(
            cr,
            "Sans",
            cairo.CAIRO_FONT_SLANT_NORMAL,
            cairo.CAIRO_FONT_WEIGHT_NORMAL,
        );
        cairo.cairo_set_font_size(cr, kFontSize);
        cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, 0.93);
        cairo.cairo_move_to(cr, self.x + kTextX, self.y + kTextY);
        var text_buf: [256:0]u8 = undefined;
        cairo.cairo_show_text(cr, toCString(self.text, &text_buf));

        // Action, flush right.
        if (self.action.len != 0) {
            cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
            cairo.cairo_set_font_size(cr, kFontSize);
            var action_buf: [256:0]u8 = undefined;
            const action = toCString(self.action, &action_buf);
            var te: cairo.cairo_text_extents_t = undefined;
            cairo.cairo_text_extents(cr, action, &te);
            cairo.cairo_move_to(cr, self.x + self.w - @as(f32, @floatCast(te.width)) - kActionRight, self.y + self.h - kActionBottom);
            cairo.cairo_show_text(cr, action);
        }

        cairo.cairo_restore(cr);
    }

    fn toCString(s: []const u8, buf: *[256:0]u8) [*c]const u8 {
        const n = @min(s.len, 255);
        @memcpy(buf[0..n], s[0..n]);
        buf[n] = 0;
        return buf;
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-banner: hidden by default, and paints once shown" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 320, 90);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var b = Banner{};
    b.setGeometry(4, 4, 300, 72);
    b.setText("Update available");
    // Starts hidden — the only control here that does.
    try t.expect(!b.isVisible());
    b.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    b.setVisible(true);
    b.setAction("Install");
    b.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Zero width bails even when visible; zero height does not.
    // checks `w_` only.
    var narrow = Banner{};
    narrow.setVisible(true);
    narrow.setGeometry(0, 0, 0, 72);
    narrow.paint(null);
    narrow.paint(cr);

    var no_height = Banner{};
    no_height.setVisible(true);
    no_height.setGeometry(0, 0, 300, 0);
    no_height.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "m3-banner: setters and geometry round-trip" {
    const t = testing;
    var b = Banner{};
    b.setText("Hello");
    b.setAction("OK");
    b.setVisible(true);
    b.setGeometry(1, 2, 3, 4);
    try t.expectEqualStrings("Hello", b.text);
    try t.expectEqualStrings("OK", b.action);
    try t.expect(b.isVisible());
    try t.expectEqual(@as(f32, 3.0), b.w);
    try t.expectEqual(@as(f32, 4.0), b.h);
}
