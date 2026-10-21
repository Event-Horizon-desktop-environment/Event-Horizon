//! The M3 bottom sheet, Modal or
//! Standard, with its top edge rounded and a drag handle.
//!
//! The sheet is `min(sh * 0.6, 400)` tall and sits flush against the bottom
//! of the geometry. Only its **top two corners** are rounded: the path arcs
//! across the top and then drops straight to the bottom edge, so the bottom
//! corners stay square — that is what lets it disappear off the screen.
//!
//! `hitScrim` covers the whole area *above* the sheet, which is exactly the
//! region the modal variant paints its scrim over; a standard sheet has no
//! scrim, so it reports no hits. Note the check uses `py < sheet_top` only —
//! it does not exclude the sheet's own x range, so a point above the sheet
//! but far to its left still counts.
//!
//! `visible` starts false, and `variant` defaults to Modal.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// M3 Bottom Sheet — Modal or Standard, slides up from bottom.
pub const BottomSheet = struct {
    pub const Variant = enum {
        modal,
        standard,
    };

    /// Sheet height is 60% of the geometry, capped at this.
    pub const kHeightFraction: f32 = 0.6;
    pub const kMaxHeight: f32 = 400.0;
    /// Top corner radius.
    pub const kRadius: f32 = 16.0;
    /// Drag handle: width, stroke width, and inset from the sheet's top.
    pub const kHandleHalfWidth: f32 = 16.0;
    pub const kHandleWidth: f32 = 4.0;
    pub const kHandleTop: f32 = 8.0;
    pub const kHandleAlpha: f32 = 0.3;

    /// Modal scrim, matching `NavDrawer`.
    pub const kScrimR: f32 = 0.071;
    pub const kScrimG: f32 = 0.047;
    pub const kScrimB: f32 = 0.149;
    pub const kScrimAlpha: f32 = 0.32;

    variant: Variant = .modal,
    visible: bool = false,

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

    pub fn setVariant(self: *BottomSheet, v: Variant) void {
        self.variant = v;
    }

    pub fn setVisible(self: *BottomSheet, v: bool) void {
        self.visible = v;
    }

    pub fn setGeometry(self: *BottomSheet, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.sx = gx;
        self.sy = gy;
        self.sw = gw;
        self.sh = gh;
    }

    pub fn setAccentColor(self: *BottomSheet, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *BottomSheet, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *BottomSheet, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *BottomSheet, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn isVisible(self: *const BottomSheet) bool {
        return self.visible;
    }

    pub fn isModal(self: *const BottomSheet) bool {
        return self.variant == .modal;
    }

    /// The sheet's height: 60% of the geometry, capped at 400.
    pub fn sheetHeight(self: *const BottomSheet) f32 {
        return @min(self.sh * kHeightFraction, kMaxHeight);
    }

    /// The sheet's top edge — flush bottom, so top = bottom - height.
    pub fn sheetTop(self: *const BottomSheet) f32 {
        return self.sy + self.sh - self.sheetHeight();
    }

    /// True where a tap would land on the scrim: inside the geometry but
    /// above the sheet. Modal and visible only.
    pub fn hitScrim(self: *const BottomSheet, px: f32, py: f32) bool {
        if (!self.visible or !self.isModal()) return false;
        return px >= self.sx and px < self.sx + self.sw and py < self.sheetTop();
    }

    pub fn paint(self: *const BottomSheet, c: ?*cairo.cairo_t) void {
        if (!self.visible or self.sw <= 0.0) return;
        const cr = c orelse return;

        const sheet_y = self.sheetTop();
        const r = kRadius;

        // Scrim (modal only).
        if (self.isModal()) {
            cairo.cairo_save(cr);
            cairo.cairo_set_source_rgba(cr, kScrimR, kScrimG, kScrimB, kScrimAlpha);
            cairo.cairo_rectangle(cr, self.sx, self.sy, self.sw, self.sh);
            cairo.cairo_fill(cr);
            cairo.cairo_restore(cr);
        }

        // Sheet surface — rounded across the top only, square at the bottom.
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_new_path(cr);
        cairo.cairo_arc(cr, self.sx + r, sheet_y + r, r, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, self.sx + self.sw - r, sheet_y + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_line_to(cr, self.sx + self.sw, self.sy + self.sh);
        cairo.cairo_line_to(cr, self.sx, self.sy + self.sh);
        cairo.cairo_close_path(cr);
        cairo.cairo_fill(cr);

        // Drag handle — a 4dp round-capped stroke, 32dp wide, 8dp down.
        const hx = self.sx + self.sw * 0.5;
        cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, kHandleAlpha);
        cairo.cairo_set_line_width(cr, kHandleWidth);
        cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
        cairo.cairo_move_to(cr, hx - kHandleHalfWidth, sheet_y + kHandleTop);
        cairo.cairo_line_to(cr, hx + kHandleHalfWidth, sheet_y + kHandleTop);
        cairo.cairo_stroke(cr);

        cairo.cairo_restore(cr);
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-bottom-sheet: sheet height is 60%, capped at 400" {
    const t = testing;
    var s = BottomSheet{};
    s.setGeometry(0, 0, 1000, 500);
    try t.expectApproxEqAbs(@as(f32, 300.0), s.sheetHeight(), 1e-4);
    // Top edge: 500 - 300 = 200.
    try t.expectApproxEqAbs(@as(f32, 200.0), s.sheetTop(), 1e-4);

    // Tall screens hit the 400 cap.
    s.setGeometry(0, 0, 1000, 3000);
    try t.expectEqual(@as(f32, 400.0), s.sheetHeight());
    try t.expectEqual(@as(f32, 2600.0), s.sheetTop());
}

test "m3-bottom-sheet: scrim hits only above the sheet, and only when modal" {
    const t = testing;
    var s = BottomSheet{};
    s.setGeometry(0, 0, 1000, 500);
    s.setVisible(true);
    // Sheet top is 200, so 100 is scrim and 300 is sheet.
    try t.expect(s.hitScrim(500, 100));
    try t.expect(!s.hitScrim(500, 300));

    // A standard sheet has no scrim at all.
    s.setVariant(.standard);
    try t.expect(!s.isModal());
    try t.expect(!s.hitScrim(500, 100));
    s.setVariant(.modal);
    try t.expect(s.isModal());

    // Hidden means no hits either.
    s.setVisible(false);
    try t.expect(!s.hitScrim(500, 100));
}

test "m3-bottom-sheet: both variants paint, hidden paints nothing" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 420, 320);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .modal, .standard }) |v| {
        var s = BottomSheet{};
        s.setVariant(v);
        s.setVisible(true);
        s.setGeometry(0, 0, 400, 300);
        s.paint(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // Hidden, or zero width: paint returns before touching the context.
    var hidden = BottomSheet{};
    hidden.setVisible(false);
    hidden.setGeometry(0, 0, 400, 300);
    hidden.paint(null);
    hidden.paint(cr);

    var narrow = BottomSheet{};
    narrow.setVisible(true);
    narrow.setGeometry(0, 0, 0, 300);
    narrow.paint(null);
    narrow.paint(cr);
}
