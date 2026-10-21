//! A brief message at the bottom of the
//! screen with an optional action.
//!
//! The snackbar ignores its own surface and text colours: the container is
//! hard-coded to `rgba(0.18, 0.16, 0.24)` and the message to white at 93%.
//! `set_surface_color` and `set_text_color` still exist and still store, but
//! `paint` never reads them — kept unwired rather than silently connected.
//! keeps it rather than silently wiring them up. Only `accent_color` reaches
//! the drawing, through the action label.
//!
//! Geometry is *screen* bounds: the bar is derived from them rather than
//! being them. Width is `min(sw - 32, 600)` centred horizontally, height is a
//! fixed 48 sitting `pad` above the bottom edge. So the snackbar shrinks to a
//! 600dp maximum on wide screens and floats on narrow ones.
//!
//! `visible` starts false.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// M3 Snackbar — brief message at the bottom with optional action.
pub const Snackbar = struct {
    /// Edge padding on every side, and the corner radius.
    pub const kPad: f32 = 16.0;
    pub const kRadius: f32 = 8.0;
    /// The bar never grows past this, however wide the screen is.
    pub const kMaxWidth: f32 = 600.0;
    pub const kHeight: f32 = 48.0;
    pub const kFontSize: f32 = 14.0;
    /// Inset for the message and the action label.
    pub const kInset: f32 = 16.0;

    /// Container fill — hard-coded, see the module note.
    pub const kContainerR: f32 = 0.18;
    pub const kContainerG: f32 = 0.16;
    pub const kContainerB: f32 = 0.24;

    text: []const u8 = "",
    action: []const u8 = "",
    visible: bool = false,

    /// The *screen* bounds the bar is laid out within.
    sx: f32 = 0.0,
    sy: f32 = 0.0,
    sw: f32 = 0.0,
    sh: f32 = 0.0,

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

    on_action: ?Callback = null,
    cb_ctx: ?*anyopaque = null,

    pub fn setText(self: *Snackbar, t: []const u8) void {
        self.text = t;
    }

    pub fn setAction(self: *Snackbar, a: []const u8) void {
        self.action = a;
    }

    pub fn setVisible(self: *Snackbar, v: bool) void {
        self.visible = v;
    }

    pub fn setGeometry(self: *Snackbar, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.sx = gx;
        self.sy = gy;
        self.sw = gw;
        self.sh = gh;
    }

    pub fn setAccentColor(self: *Snackbar, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    /// Stored, but `paint` uses the hard-coded container colour instead.
    pub fn setSurfaceColor(self: *Snackbar, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    /// Stored, but `paint` uses white instead.
    pub fn setTextColor(self: *Snackbar, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Snackbar, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn setOnAction(self: *Snackbar, cb: ?Callback) void {
        self.on_action = cb;
    }

    pub fn setCallbackContext(self: *Snackbar, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn isVisible(self: *const Snackbar) bool {
        return self.visible;
    }

    /// Fire the action sink, as tapping the label would.
    pub fn performAction(self: *Snackbar) void {
        if (self.on_action) |cb| cb(self.cb_ctx);
    }

    /// The bar's width: the screen inset by padding on both sides, capped.
    pub fn barWidth(self: *const Snackbar) f32 {
        return @min(self.sw - kPad * 2.0, kMaxWidth);
    }

    /// The bar's left edge, centred in the screen bounds.
    pub fn barX(self: *const Snackbar) f32 {
        return self.sx + (self.sw - self.barWidth()) * 0.5;
    }

    /// The bar's top edge: a fixed 48, one pad above the bottom.
    pub fn barY(self: *const Snackbar) f32 {
        return self.sy + self.sh - kHeight - kPad;
    }

    pub fn paint(self: *const Snackbar, c: ?*cairo.cairo_t) void {
        if (!self.visible) return;
        const cr = c orelse return;

        const r = kRadius;
        const w = self.barWidth();
        const h = kHeight;
        const x = self.barX();
        const y = self.barY();

        cairo.cairo_save(cr);

        // Container — the fixed colour, not `surface_*`.
        cairo.cairo_set_source_rgba(cr, kContainerR, kContainerG, kContainerB, 1.0);
        cairo.cairo_new_path(cr);
        cairo.cairo_arc(cr, x + r, y + r, r, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, x + w - r, y + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_arc(cr, x + w - r, y + h - r, r, 0.0, 0.5 * std.math.pi);
        cairo.cairo_arc(cr, x + r, y + h - r, r, 0.5 * std.math.pi, std.math.pi);
        cairo.cairo_close_path(cr);
        cairo.cairo_fill(cr);

        // Message — white at 93%, not `text_*`.
        cairo.cairo_select_font_face(
            cr,
            "Sans",
            cairo.CAIRO_FONT_SLANT_NORMAL,
            cairo.CAIRO_FONT_WEIGHT_NORMAL,
        );
        cairo.cairo_set_font_size(cr, kFontSize);
        cairo.cairo_set_source_rgba(cr, 1, 1, 1, 0.93);
        cairo.cairo_move_to(cr, x + kInset, y + h * 0.5 + 5);
        var text_buf: [256:0]u8 = undefined;
        cairo.cairo_show_text(cr, toCString(self.text, &text_buf));

        // Action, flush right on the same baseline as the message.
        if (self.action.len != 0) {
            cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
            cairo.cairo_set_font_size(cr, kFontSize);
            var action_buf: [256:0]u8 = undefined;
            const action = toCString(self.action, &action_buf);
            var te: cairo.cairo_text_extents_t = undefined;
            cairo.cairo_text_extents(cr, action, &te);
            cairo.cairo_move_to(cr, x + w - @as(f32, @floatCast(te.width)) - kInset, y + h * 0.5 + 5);
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

test "m3-snackbar: bar layout is derived from the screen bounds" {
    const t = testing;
    var s = Snackbar{};
    s.setGeometry(0, 0, 1600, 900);

    // Wide screen: capped at 600 and centred.
    try t.expectEqual(@as(f32, 600.0), s.barWidth());
    try t.expectEqual(@as(f32, 500.0), s.barX());
    // 900 - 48 - 16 = 836.
    try t.expectEqual(@as(f32, 836.0), s.barY());

    // Narrow screen: the cap stops mattering and padding rules instead.
    var narrow = Snackbar{};
    narrow.setGeometry(0, 0, 320, 480);
    try t.expectEqual(@as(f32, 288.0), narrow.barWidth());
    try t.expectEqual(@as(f32, 16.0), narrow.barX());
    try t.expectEqual(@as(f32, 416.0), narrow.barY());
}

test "m3-snackbar: hidden by default; visible paints and fires its action" {
    const t = testing;
    const S = struct {
        var actions: usize = 0;
        fn onAction(ctx: ?*anyopaque) void {
            _ = ctx;
            actions += 1;
        }
    };
    S.actions = 0;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 400, 200);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var s = Snackbar{};
    s.setGeometry(0, 0, 400, 200);
    s.setText("Deleted");
    s.setAction("Undo");
    s.setOnAction(S.onAction);

    try t.expect(!s.isVisible());
    s.paint(null); // hidden: no context needed
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    s.setVisible(true);
    s.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    s.performAction();
    try t.expectEqual(@as(usize, 1), S.actions);
}
