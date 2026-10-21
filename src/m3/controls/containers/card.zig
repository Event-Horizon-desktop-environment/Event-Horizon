//! The M3 card, in its three variants.
//!
//! A card is a content surface rather than an interactive control, but it still
//! tracks hover/press and draws a focus ring, because the shell uses cards as
//! clickable tiles. `paint` composes, in order: shadow (elevated only), the
//! glassy background box, the outline (outlined only), the surface-tint wash
//! (elevated only), then the state layer and focus ring.
//!
//! The corner radius is the fixed `corner.medium` of 12dp on every variant —
//! unlike `Button`, a card does not pill out at small sizes.
//!
//! Note `paint` ticks its state layer with a fixed time of 0: with no
//! `nowMs` parameter here, so card hover transitions are evaluated at the
//! start of the animation clock. That is faithful, and it means cards respond
//! on the first frame rather than easing over 100ms.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const box_mod = @import("../../core/primitives/box.zig");
const state_layer_mod = @import("../../core/primitives/state_layer.zig");

pub const Box = box_mod.Box;
pub const StateLayer = state_layer_mod.StateLayer;
pub const FocusRing = state_layer_mod.FocusRing;

/// Click sink, lowered the same way `Button.Callback` is.
pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// `corner.medium` — the card's one radius.
pub const kCardRadius: f32 = 12.0;

/// M3 Card — 3 variants: Elevated, Filled, Outlined.
///
/// Content container with state layer, surface tint, and optional shadow/outline.
pub const Card = struct {
    pub const Variant = enum {
        elevated,
        filled,
        outlined,
    };

    variant: Variant = .filled,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    /// Extra shadow weight; only the elevated variant reads it.
    elevated: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,

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

    state_layer: StateLayer = .{},
    focus_ring: FocusRing = .{},

    on_click: ?Callback = null,
    cb_ctx: ?*anyopaque = null,

    pub fn setVariant(self: *Card, v: Variant) void {
        self.variant = v;
    }

    pub fn setGeometry(self: *Card, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *Card, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Card, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Card, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Card, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn setHovered(self: *Card, h: bool) void {
        self.hovered = h;
    }

    pub fn setPressed(self: *Card, p: bool) void {
        self.pressed = p;
    }

    pub fn setFocused(self: *Card, f: bool) void {
        self.focused = f;
    }

    /// Toggle the heavier shadow. Only `Variant.elevated` draws a shadow at
    /// all, so setting this on a filled or outlined card changes nothing.
    pub fn setElevated(self: *Card, e: bool) void {
        self.elevated = e;
    }

    pub fn setOnClick(self: *Card, cb: ?Callback) void {
        self.on_click = cb;
    }

    pub fn setCallbackContext(self: *Card, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn variantOf(self: *const Card) Variant {
        return self.variant;
    }

    pub fn xPos(self: *const Card) f32 {
        return self.x;
    }

    pub fn yPos(self: *const Card) f32 {
        return self.y;
    }

    pub fn width(self: *const Card) f32 {
        return self.w;
    }

    pub fn height(self: *const Card) f32 {
        return self.h;
    }

    pub fn containsPoint(self: *const Card, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    pub fn handlePointerEnter(self: *Card, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        self.hovered = true;
        return true;
    }

    pub fn handlePointerLeave(self: *Card) bool {
        self.hovered = false;
        self.pressed = false;
        return true;
    }

    pub fn handlePointerDown(self: *Card, px: f32, py: f32) bool {
        if (!self.containsPoint(px, py)) return false;
        self.pressed = true;
        return true;
    }

    /// Unlike `Button`, a card fires on release without requiring the pointer
    /// to still be inside — only `pressed_` is checked.
    pub fn handlePointerUp(self: *Card, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (self.pressed) {
            self.pressed = false;
            if (self.on_click) |cb| cb(self.cb_ctx);
        }
        return true;
    }

    /// Linear blend helper.
    fn blend(a: f32, b: f32, t: f32) f32 {
        return a + (b - a) * t;
    }

    pub fn paint(self: *Card, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;
        const r = kCardRadius;

        // Container colours per variant.
        var bg_r: f32 = 0;
        var bg_g: f32 = 0;
        var bg_b: f32 = 0;
        const bg_a: f32 = 1.0;
        var has_outline = false;
        var o_r: f32 = 0;
        var o_g: f32 = 0;
        var o_b: f32 = 0;

        switch (self.variant) {
            .elevated => {
                bg_r = blend(self.surface_r, self.outline_r, 0.04);
                bg_g = blend(self.surface_g, self.outline_g, 0.04);
                bg_b = blend(self.surface_b, self.outline_b, 0.04);
            },
            .filled => {
                bg_r = blend(self.surface_r, self.outline_r, 0.08);
                bg_g = blend(self.surface_g, self.outline_g, 0.08);
                bg_b = blend(self.surface_b, self.outline_b, 0.08);
            },
            .outlined => {
                bg_r = self.surface_r;
                bg_g = self.surface_g;
                bg_b = self.surface_b;
                has_outline = true;
                o_r = self.outline_r;
                o_g = self.outline_g;
                o_b = self.outline_b;
            },
        }

        cairo.cairo_save(cr);

        // Shadow (elevated variant only) — a stroked outline path rather than a
        // drop shadow: the line is the shadow, and `setElevated` thickens it.
        if (self.variant == .elevated) {
            const shadow_a: f32 = if (self.elevated) 0.24 else 0.16;
            roundedPath(cr, self.x, self.y, self.w, self.h, r);
            cairo.cairo_set_source_rgba(cr, 0, 0, 0, shadow_a);
            cairo.cairo_set_line_width(cr, if (self.elevated) 3.0 else 1.0);
            cairo.cairo_stroke(cr);
        }

        // Background fill — Box supplies the glassy inner rim and highlights,
        // already clipped to the radius.
        var bg_box = Box{};
        bg_box.setColor(bg_r, bg_g, bg_b, bg_a);
        bg_box.setRadius(r);
        bg_box.setGeometry(self.x, self.y, self.w, self.h);
        bg_box.setGlassy(true);
        bg_box.paint(c);

        if (has_outline) {
            // `r - 0.5` so the 1dp stroke straddles the edge, centred on it.
            roundedPathInset(cr, self.x, self.y, self.w, self.h, r);
            cairo.cairo_set_source_rgba(cr, o_r, o_g, o_b, 0.5);
            cairo.cairo_set_line_width(cr, 1.0);
            cairo.cairo_stroke(cr);
        }

        // Surface tint layer (elevated variant) — a faint accent wash over the
        // fill, at full radius.
        if (self.variant == .elevated) {
            roundedPath(cr, self.x, self.y, self.w, self.h, r);
            cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 0.05);
            cairo.cairo_fill(cr);
        }

        cairo.cairo_restore(cr);

        // State layer — tinted with the card's own text colour.
        self.state_layer.setColor(self.text_r, self.text_g, self.text_b);
        self.state_layer.setRadius(r);
        self.state_layer.setGeometry(self.x, self.y, self.w, self.h);
        self.state_layer.setHovered(self.hovered);
        self.state_layer.setPressed(self.pressed);
        self.state_layer.setFocused(self.focused);
        self.state_layer.tick(0);
        self.state_layer.paint(c, 0);

        // Focus ring.
        self.focus_ring.setFocused(self.focused);
        self.focus_ring.setColor(self.outline_r, self.outline_g, self.outline_b);
        self.focus_ring.setRadius(r);
        self.focus_ring.paint(c, self.x, self.y, self.w, self.h);
    }

    /// Build the rounded-rectangle outline at full radius.
    fn roundedPath(cr: ?*cairo.cairo_t, x: f32, y: f32, w: f32, h: f32, r: f32) void {
        strokePathAt(cr, x, y, w, h, r, r);
    }

    /// The same shape pulled in by half a pixel, for centring a 1dp stroke.
    fn roundedPathInset(cr: ?*cairo.cairo_t, x: f32, y: f32, w: f32, h: f32, r: f32) void {
        strokePathAt(cr, x, y, w, h, r, r - 0.5);
    }

    /// Four quarter-arcs joined into a rounded rectangle.
    ///
    /// `stroke_r` is separate from `r`: the corner *centres* are derived from
    /// the true radius while the arcs sweep `stroke_r`, which is how the
    /// outline lands on the shape's edge instead of inside it.
    fn strokePathAt(cr: ?*cairo.cairo_t, x: f32, y: f32, w: f32, h: f32, r: f32, stroke_r: f32) void {
        cairo.cairo_new_path(cr);
        cairo.cairo_arc(cr, x + r, y + r, stroke_r, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, x + w - r, y + r, stroke_r, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_arc(cr, x + w - r, y + h - r, stroke_r, 0.0, 0.5 * std.math.pi);
        cairo.cairo_arc(cr, x + r, y + h - r, stroke_r, 0.5 * std.math.pi, std.math.pi);
        cairo.cairo_close_path(cr);
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-card: every variant paints without error" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 150);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .elevated, .filled, .outlined }) |v| {
        var card = Card{};
        card.setVariant(v);
        card.setGeometry(10, 10, 180, 120);
        card.setHovered(true);
        card.paint(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // `setElevated` only matters on the elevated variant.
    var raised = Card{};
    raised.setVariant(.elevated);
    raised.setElevated(true);
    raised.setGeometry(10, 10, 180, 120);
    raised.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "m3-card: hit testing and press/release fire the click" {
    const t = testing;
    const S = struct {
        var clicks: usize = 0;
        fn onClick(_: ?*anyopaque) void {
            clicks += 1;
        }
    };
    S.clicks = 0;

    var card = Card{};
    card.setGeometry(50, 50, 100, 100);
    card.setOnClick(S.onClick);

    try t.expect(card.containsPoint(60, 60));
    try t.expect(!card.containsPoint(10, 10));

    // A press that misses arms nothing, so the release fires no click.
    try t.expect(!card.handlePointerDown(10, 10));
    _ = card.handlePointerUp(60, 60);
    try t.expectEqual(@as(usize, 0), S.clicks);

    try t.expect(card.handlePointerDown(60, 60));
    _ = card.handlePointerUp(60, 60);
    try t.expectEqual(@as(usize, 1), S.clicks);

    // Leaving clears both hover and press.
    card.setHovered(true);
    card.setPressed(true);
    _ = card.handlePointerLeave();
    try t.expect(!card.hovered);
    try t.expect(!card.pressed);
}

test "m3-card: degenerate geometry paints nothing and is null-safe" {
    var card = Card{};
    card.setGeometry(0, 0, 0, 0);
    card.paint(null);
}
