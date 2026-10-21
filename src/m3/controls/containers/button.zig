//! The M3 button: 4 styles, 5 sizes,
//! state layers, focus ring, and optional toggle mode.
//!
//! A button is a composition rather than a drawing: it owns a `Box` for the
//! container, a `StateLayer` for the hover/press wash, a `FocusRing`, and a
//! `Label` + `Glyph` pair for content. `paint` sequences them — container,
//! state layer, content, focus ring — in that order so the wash sits under
//! the text and the ring sits above everything.
//!
//! Two behaviours worth calling out because they are easy to lose:
//!
//!   * `setPointer` derives `hovered` automatically on the next paint, so a
//!     caller can just feed mouse coordinates and never touch `setHovered`.
//!   * `setGeometry` grows the button to fit its label. If the label needs
//!     more room than it was given, the box widens *and shifts left by half
//!     the difference*, keeping the visual centre where it was.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const box_mod = @import("../../core/primitives/box.zig");
const state_layer_mod = @import("../../core/primitives/state_layer.zig");
const label_mod = @import("../../core/label.zig");
const glyph_mod = @import("../../core/glyph.zig");

pub const Box = box_mod.Box;
pub const StateLayer = state_layer_mod.StateLayer;
pub const FocusRing = state_layer_mod.FocusRing;
pub const Label = label_mod.Label;
pub const Glyph = glyph_mod.Glyph;

/// A click/press/release sink. `ctx` is handed back untouched.
pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// M3 Button — 4 styles, 5 sizes, state layers, focus ring, toggle mode.
pub const Button = struct {
    pub const Style = enum {
        filled,
        tonal,
        outlined,
        text,
    };

    /// Indexed by `sizeIndex()` into the `kSize*` tables below.
    pub const Size = enum {
        xs,
        s,
        m,
        l,
        xl,
    };

    /// M3 Expressive. `square` keeps a fixed 12dp corner; `pill` rounds to
    /// half the shorter side.
    pub const CornerStyle = enum {
        pill,
        square,
    };

    // — size tables, indexed by Size —
    pub const kSizeHeight = [_]f32{ 24.0, 32.0, 40.0, 48.0, 56.0 };
    pub const kSizeHPad = [_]f32{ 16.0, 16.0, 24.0, 24.0, 24.0 };
    pub const kSizeFont = [_]f32{ 12.0, 13.0, 14.0, 16.0, 16.0 };
    /// Extra padding either side of the label when auto-sizing.
    pub const kAutoPad: f32 = 10.0;
    /// Fixed corner radius for `CornerStyle.square`.
    pub const kSquareRadius: f32 = 12.0;
    /// Icon diameter in `drawContent`.
    pub const kIconSize: f32 = 20.0;
    /// Gap between icon and label when both are present.
    pub const kIconGap: f32 = 6.0;

    style: Style = .filled,
    size: Size = .m,
    corner_style: CornerStyle = .pill,
    enabled: bool = true,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    toggle_mode: bool = false,
    toggled: bool = false,

    // Geometry. Note min_w/min_h default to 64x36, not zero.
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,
    min_w: f32 = 64.0,
    min_h: f32 = 36.0,

    // Pointer tracking for auto-hover.
    pointer_x: f32 = 0.0,
    pointer_y: f32 = 0.0,
    pointer_enabled: bool = false,

    // Colour overrides. (0,0,0) means "unset", so an override is
    // only honoured when at least one channel is non-zero.
    accent_r: f32 = 0.769,
    accent_g: f32 = 0.659,
    accent_b: f32 = 0.941,
    surface_r: f32 = 0.102,
    surface_g: f32 = 0.075,
    surface_b: f32 = 0.188,
    text_r: f32 = 1.0,
    text_g: f32 = 1.0,
    text_b: f32 = 1.0,
    outline_r: f32 = 0.0,
    outline_g: f32 = 0.0,
    outline_b: f32 = 0.0,

    /// Resolved foreground, written by `drawContainer` and read by
    /// `drawContent`; `paint` takes a mutable self.
    resolved_fg_r: f32 = 1.0,
    resolved_fg_g: f32 = 1.0,
    resolved_fg_b: f32 = 1.0,

    label: Label = .{},
    glyph: Glyph = .{},
    state_layer: StateLayer = .{},
    focus_ring: FocusRing = .{},

    on_click: ?Callback = null,
    on_press: ?Callback = null,
    on_release: ?Callback = null,
    cb_ctx: ?*anyopaque = null,

    // ——— configuration ———

    pub fn setLabel(self: *Button, text: []const u8) void {
        self.label.setText(text);
    }

    pub fn setGlyph(self: *Button, name: []const u8) void {
        self.glyph.setGlyph(name);
    }

    pub fn setStyle(self: *Button, s: Style) void {
        self.style = s;
    }

    pub fn setSize(self: *Button, s: Size) void {
        self.size = s;
    }

    pub fn setCornerStyle(self: *Button, cs: CornerStyle) void {
        self.corner_style = cs;
    }

    /// Disabling also clears hover and press, so a disabled button can never
    /// look interactive.
    pub fn setEnabled(self: *Button, e: bool) void {
        self.enabled = e;
        if (!e) {
            self.hovered = false;
            self.pressed = false;
        }
    }

    pub fn setToggleMode(self: *Button, t: bool) void {
        self.toggle_mode = t;
    }

    /// Note this also clears automatic pointer tracking — handing control back
    /// to the caller means the button stops deriving hover itself.
    pub fn setHovered(self: *Button, h: bool) void {
        self.hovered = h;
        self.pointer_enabled = false;
    }

    pub fn setPressed(self: *Button, p: bool) void {
        self.pressed = p;
    }

    pub fn setToggled(self: *Button, t: bool) void {
        self.toggled = t;
    }

    /// Built-in pointer tracking for auto-hover. Call once per frame before
    /// paint(). When set, `hovered` is derived automatically from
    /// `containsPoint` — no external hit lambda or setHovered call needed.
    /// Pure float compares.
    pub fn setPointer(self: *Button, px: f32, py: f32) void {
        self.pointer_x = px;
        self.pointer_y = py;
        self.pointer_enabled = true;
    }

    pub fn clearPointer(self: *Button) void {
        self.pointer_enabled = false;
    }

    /// Override colours (leave at 0,0,0 to use M3 role defaults).
    pub fn setAccentColor(self: *Button, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Button, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Button, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Button, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    // ——— sizing ———

    pub fn setMinSize(self: *Button, mw: f32, mh: f32) void {
        self.min_w = mw;
        self.min_h = mh;
    }

    /// Set geometry, then grow to fit the label.
    ///
    /// The label is measured with this size's font. If it needs more width
    /// than the box has, the box widens to `label + 2 * kAutoPad` and shifts
    /// left by half the increase so the centre stays put. A non-zero `min_h`
    /// also pulls the height up to the size's nominal height.
    pub fn setGeometry(self: *Button, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = @max(gw, self.min_w);
        self.h = @max(gh, self.min_h);

        if (self.label.text.len != 0) {
            self.label.setFontSize(self.fontForSize());
            var lw: f32 = 0;
            var lh: f32 = 0;
            self.label.measureExtents(&lw, &lh);
            const need_w = lw + 2.0 * kAutoPad;
            if (self.min_h > 0) self.h = @max(self.h, self.heightForSize());
            if (self.w < need_w) {
                const dw = need_w - self.w;
                self.w = need_w;
                self.x -= dw * 0.5;
            }
        }
    }

    pub fn styleOf(self: *const Button) Style {
        return self.style;
    }

    pub fn sizeOf(self: *const Button) Size {
        return self.size;
    }

    pub fn isEnabled(self: *const Button) bool {
        return self.enabled;
    }

    pub fn isToggled(self: *const Button) bool {
        return self.toggled;
    }

    pub fn xPos(self: *const Button) f32 {
        return self.x;
    }

    pub fn yPos(self: *const Button) f32 {
        return self.y;
    }

    pub fn width(self: *const Button) f32 {
        return self.w;
    }

    pub fn height(self: *const Button) f32 {
        return self.h;
    }

    pub fn isHovered(self: *const Button) bool {
        return self.hovered;
    }

    pub fn isPressed(self: *const Button) bool {
        return self.pressed;
    }

    pub fn minWidth(self: *const Button) f32 {
        return self.min_w;
    }

    pub fn minHeight(self: *const Button) f32 {
        return self.min_h;
    }

    fn sizeIndex(self: *const Button) usize {
        return @intFromEnum(self.size);
    }

    fn heightForSize(self: *const Button) f32 {
        return kSizeHeight[self.sizeIndex()];
    }

    fn hPadForSize(self: *const Button) f32 {
        return kSizeHPad[self.sizeIndex()];
    }

    fn fontForSize(self: *const Button) f32 {
        return kSizeFont[self.sizeIndex()];
    }

    /// `square` is a fixed 12dp; `pill` rounds to half the shorter side, which
    /// reads as a stadium on a rectangle and a circle on a square.
    fn radius(self: *const Button) f32 {
        if (self.corner_style == .square) return kSquareRadius;
        return @min(self.w, self.h) * 0.5;
    }

    // ——— hit testing ———

    pub fn containsPoint(self: *const Button, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    // ——— events ———

    pub fn handlePointerEnter(self: *Button, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        self.hovered = true;
        return true;
    }

    pub fn handlePointerLeave(self: *Button) bool {
        self.hovered = false;
        self.pressed = false;
        return true;
    }

    /// Fires `on_press` on the way down, not on release.
    pub fn handlePointerDown(self: *Button, px: f32, py: f32) bool {
        if (!self.enabled or !self.containsPoint(px, py)) return false;
        self.pressed = true;
        if (self.on_press) |cb| cb(self.cb_ctx);
        return true;
    }

    pub fn handlePointerUp(self: *Button, px: f32, py: f32) bool {
        if (!self.enabled) return false;
        const was_pressed = self.pressed;
        self.pressed = false;

        // Toggle and click both require the release to land inside the button,
        // so a drag-off cancels both.
        if (self.toggle_mode and was_pressed and self.containsPoint(px, py)) {
            self.toggled = !self.toggled;
        }
        if (was_pressed and self.containsPoint(px, py)) {
            if (self.on_click) |cb| cb(self.cb_ctx);
        }
        // `on_release` fires regardless of where the pointer came up — it
        // reports "the press ended", not "you clicked".
        if (self.on_release) |cb| cb(self.cb_ctx);
        return was_pressed;
    }

    pub fn setOnClick(self: *Button, cb: ?Callback) void {
        self.on_click = cb;
    }

    pub fn setOnPress(self: *Button, cb: ?Callback) void {
        self.on_press = cb;
    }

    pub fn setOnRelease(self: *Button, cb: ?Callback) void {
        self.on_release = cb;
    }

    /// Share one context pointer across all three callbacks.
    pub fn setCallbackContext(self: *Button, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    // ——— rendering ———

    /// Animated paint: retargets the state layer toward `now_ms`.
    pub fn paint(self: *Button, c: ?*cairo.cairo_t, now_ms: u64) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;

        // Auto-hover: if a pointer is being tracked, hover is derived here
        // rather than being set by the caller.
        if (self.pointer_enabled) {
            self.hovered = self.enabled and self.containsPoint(self.pointer_x, self.pointer_y);
        }

        self.state_layer.setGeometry(self.x, self.y, self.w, self.h);
        self.state_layer.setRadius(self.radius());
        self.state_layer.setHovered(self.hovered);
        self.state_layer.setPressed(self.pressed);
        self.state_layer.tick(now_ms);

        self.resolveColors();
        self.drawContainer(c);
        self.state_layer.paint(c, now_ms);
        self.drawContent(c);
        self.drawFocusRing(c);
    }

    /// Non-animated paint — uses the current state directly.
    pub fn paintStatic(self: *Button, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        // Zero elapsed, forwarding to `paint(cr, 0)`.
        self.paint(c, 0);
    }

    /// Fill in any colour the caller did not override.
    ///
    /// Currently a no-op beyond the early return: the full
    /// `ColorRole` lookup is deferred to a later sprint, so the hardcoded
    /// accent/surface defaults above are what actually get used. Kept as a
    /// distinct step so that swap lands in one place.
    fn resolveColors(self: *Button) void {
        if (self.accent_r != 0 or self.accent_g != 0 or self.accent_b != 0) return;
    }

    fn drawContainer(self: *Button, c: ?*cairo.cairo_t) void {
        const cr = c orelse return;
        const r = self.radius();
        const alpha: f32 = if (self.enabled) 1.0 else 0.12;

        var bg_r: f32 = 0;
        var bg_g: f32 = 0;
        var bg_b: f32 = 0;
        var bg_a: f32 = 0;
        var fg_r: f32 = 0;
        var fg_g: f32 = 0;
        var fg_b: f32 = 0;

        const blend = struct {
            fn mix(a: f32, b: f32, t: f32) f32 {
                return a + (b - a) * t;
            }
        }.mix;

        switch (self.style) {
            .filled => {
                if (self.toggled) {
                    // A toggled filled button drops to a near-neutral surface
                    // with a muted blue foreground — "on but not brand".
                    bg_r = 0.12;
                    bg_g = 0.12;
                    bg_b = 0.14;
                    bg_a = if (self.enabled) 1.0 else alpha;
                    fg_r = 0.43;
                    fg_g = 0.59;
                    fg_b = 0.88;
                } else {
                    bg_r = self.accent_r;
                    bg_g = self.accent_g;
                    bg_b = self.accent_b;
                    bg_a = if (self.enabled) 1.0 else alpha;
                    fg_r = 1.0;
                    fg_g = 1.0;
                    fg_b = 1.0;
                }
            },
            .tonal => {
                // Accent pulled 55% toward surface.
                bg_r = blend(self.accent_r, self.surface_r, 0.55);
                bg_g = blend(self.accent_g, self.surface_g, 0.55);
                bg_b = blend(self.accent_b, self.surface_b, 0.55);
                bg_a = if (self.enabled) 1.0 else alpha;
                fg_r = self.surface_r;
                fg_g = self.surface_g;
                fg_b = self.surface_b;
            },
            .outlined, .text => {
                // No fill of their own; the content is the accent.
                bg_r = 0;
                bg_g = 0;
                bg_b = 0;
                bg_a = 0;
                fg_r = self.accent_r;
                fg_g = self.accent_g;
                fg_b = self.accent_b;
            },
        }

        // For Outlined/Text we still want a subtle glassy backing so the inner
        // frosted effect is visible on buttons.
        var cont_r = bg_r;
        var cont_g = bg_g;
        var cont_b = bg_b;
        var cont_a = bg_a;
        if ((self.style == .outlined or self.style == .text) and cont_a < 0.05) {
            cont_r = self.surface_r;
            cont_g = self.surface_g;
            cont_b = self.surface_b;
            cont_a = 0.08;
        }

        var container = Box{};
        container.setColor(cont_r, cont_g, cont_b, if (self.enabled) cont_a else 0.06);
        container.setRadius(r);
        container.setGeometry(self.x, self.y, self.w, self.h);
        container.setGlassy(true);
        container.paint(c);

        if (self.style == .outlined) {
            cairo.cairo_save(cr);
            const o_r = if (self.outline_r != 0) self.outline_r else 0.35;
            const o_g = if (self.outline_g != 0) self.outline_g else 0.35;
            const o_b = if (self.outline_b != 0) self.outline_b else 0.37;
            cairo.cairo_set_source_rgba(cr, o_r, o_g, o_b, if (self.enabled) 1.0 else 0.12);
            cairo.cairo_set_line_width(cr, 1.0);
            // Note the arcs use `r - 0.5` so the 1dp stroke straddles the
            // container edge rather than sitting fully inside it.
            if (r > 0) {
                cairo.cairo_new_path(cr);
                cairo.cairo_arc(cr, self.x + r, self.y + r, r - 0.5, std.math.pi, 1.5 * std.math.pi);
                cairo.cairo_arc(cr, self.x + self.w - r, self.y + r, r - 0.5, 1.5 * std.math.pi, 2.0 * std.math.pi);
                cairo.cairo_arc(cr, self.x + self.w - r, self.y + self.h - r, r - 0.5, 0.0, 0.5 * std.math.pi);
                cairo.cairo_arc(cr, self.x + r, self.y + self.h - r, r - 0.5, 0.5 * std.math.pi, std.math.pi);
                cairo.cairo_close_path(cr);
            } else {
                cairo.cairo_rectangle(cr, self.x, self.y, self.w, self.h);
            }
            cairo.cairo_stroke(cr);
            cairo.cairo_restore(cr);
        }

        // Stash the foreground for `drawContent`, and tint the state layer
        // with it so the wash reads as the button's own content colour.
        self.resolved_fg_r = fg_r;
        self.resolved_fg_g = fg_g;
        self.resolved_fg_b = fg_b;
        self.state_layer.setColor(fg_r, fg_g, fg_b);
    }

    fn drawContent(self: *Button, c: ?*cairo.cairo_t) void {
        const cr = c orelse return;
        const fg_a: f32 = if (self.enabled) 1.0 else 0.38;
        const has_glyph = self.glyph.glyph.len != 0;
        const has_label = self.label.text.len != 0;

        if (!has_glyph and !has_label) return;

        cairo.cairo_save(cr);
        cairo.cairo_translate(cr, self.x, self.y);

        if (has_glyph) {
            self.glyph.setSize(kIconSize);
            self.glyph.setColor(self.resolved_fg_r, self.resolved_fg_g, self.resolved_fg_b, fg_a);

            if (has_label) {
                var iw: f32 = 0;
                var ih: f32 = 0;
                self.glyph.measureExtents(&iw, &ih);

                self.label.setFontSize(self.fontForSize());
                var lw: f32 = 0;
                var lh: f32 = 0;
                self.label.measureExtents(&lw, &lh);

                // Centred as one run: icon, gap, then label.
                const total_w = iw + kIconGap + lw;
                const base_x = @round((self.w - total_w) * 0.5);
                const iy = @round((self.h - ih) * 0.5);
                const ly = @round((self.h - lh) * 0.5);

                self.glyph.paintAt(c, base_x, iy);
                self.label.setColor(self.resolved_fg_r, self.resolved_fg_g, self.resolved_fg_b, fg_a);
                self.label.paintAt(c, base_x + iw + kIconGap, ly);
            } else {
                var iw: f32 = 0;
                var ih: f32 = 0;
                self.glyph.measureExtents(&iw, &ih);
                const gx = @round((self.w - iw) * 0.5);
                const gy = @round((self.h - ih) * 0.5);
                self.glyph.paintAt(c, gx, gy);
            }
        } else if (has_label) {
            self.label.setFontSize(self.fontForSize());
            self.label.setColor(self.resolved_fg_r, self.resolved_fg_g, self.resolved_fg_b, fg_a);

            var lw: f32 = 0;
            var lh: f32 = 0;
            self.label.measureExtents(&lw, &lh);
            const lx = @round((self.w - lw) * 0.5);
            const ly = @round((self.h - lh) * 0.5);

            // A 1px black shadow under the label before the real text, so the
            // label stays legible over a light or busy container.
            self.label.setColor(0, 0, 0, fg_a * 0.35);
            self.label.paintAt(c, lx + 1.0, ly + 1.0);
            self.label.setColor(self.resolved_fg_r, self.resolved_fg_g, self.resolved_fg_b, fg_a);
            self.label.paintAt(c, lx, ly);
        }

        cairo.cairo_restore(cr);
    }

    fn drawFocusRing(self: *Button, c: ?*cairo.cairo_t) void {
        if (!self.focused) return;
        self.focus_ring.setFocused(true);
        self.focus_ring.setColor(
            if (self.outline_r != 0) self.outline_r else 0.6,
            if (self.outline_g != 0) self.outline_g else 0.6,
            if (self.outline_b != 0) self.outline_b else 0.6,
        );
        self.focus_ring.setRadius(self.radius());
        self.focus_ring.paint(c, self.x, self.y, self.w, self.h);
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-button: size tables are indexed by Size" {
    const t = testing;
    var b = Button{};
    b.setSize(.xs);
    try t.expectEqual(@as(f32, 24.0), Button.kSizeHeight[b.sizeIndex()]);
    try t.expectEqual(@as(f32, 12.0), b.fontForSize());
    b.setSize(.xl);
    try t.expectEqual(@as(f32, 56.0), b.heightForSize());
    try t.expectEqual(@as(f32, 24.0), b.hPadForSize());
}

test "m3-button: pill vs square radius" {
    const t = testing;
    var b = Button{};
    b.setGeometry(0, 0, 100, 40);
    // Pill rounds to half the shorter side — 20 on a 40-tall button.
    try t.expectEqual(@as(f32, 20.0), b.radius());
    b.setCornerStyle(.square);
    // Square is a fixed 12dp regardless of the box.
    try t.expectEqual(@as(f32, 12.0), b.radius());
}

test "m3-button: setGeometry grows to fit the label and re-centres" {
    const t = testing;
    var b = Button{};
    b.setMinSize(0, 0);
    b.setLabel("Add widget");
    b.setSize(.m);
    b.setGeometry(200, 10, 10, 10);

    // The label needs more than 10px, so the box must have widened past it.
    try t.expect(b.w > 10);
    // …and shifted left by half the growth, keeping the original centre.
    try t.expect(b.x < 200);
    // The height bump is gated on `min_h > 0`,
    // so with the minimum disabled the requested 10 is what stays.
    try t.expectEqual(@as(f32, 10.0), b.h);

    // With a minimum height in place the size's nominal height (M = 40) is
    // pulled in instead, since it is larger than the 10 we asked for.
    var c = Button{};
    c.setMinSize(64, 36);
    c.setLabel("Add widget");
    c.setSize(.m);
    c.setGeometry(0, 0, 10, 10);
    try t.expectEqual(@as(f32, 40.0), c.h);
}

test "m3-button: disabling clears hover and press" {
    const t = testing;
    var b = Button{};
    b.setHovered(true);
    b.setPressed(true);
    b.setEnabled(false);
    try t.expect(!b.isHovered());
    try t.expect(!b.isPressed());
    // Disabled buttons refuse pointer input entirely.
    try t.expect(!b.handlePointerDown(0, 0));
}

test "m3-button: toggle flips only on an inside release" {
    const t = testing;
    var b = Button{};
    b.setMinSize(0, 0);
    b.setGeometry(0, 0, 40, 40);
    b.setToggleMode(true);

    try t.expect(b.handlePointerDown(20, 20));
    _ = b.handlePointerUp(20, 20);
    try t.expect(b.isToggled());

    // A release outside the button cancels the toggle — this is the drag-off
    // case, and it must not flip the state back.
    _ = b.handlePointerDown(20, 20);
    _ = b.handlePointerUp(900, 900);
    try t.expect(b.isToggled());
}

test "m3-button: auto-hover follows the tracked pointer" {
    const t = testing;
    var b = Button{};
    b.setMinSize(0, 0);
    b.setGeometry(0, 0, 40, 40);
    b.setPointer(200, 200);
    // Painting derives hover from the pointer, without any setHovered call.
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    b.paint(cr, 0);
    try t.expect(!b.isHovered());

    b.setPointer(10, 10);
    b.paint(cr, 0);
    try t.expect(b.isHovered());
}

test "m3-button: every style paints cleanly, including degenerate geometry" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 120, 80);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .filled, .tonal, .outlined, .text }) |s| {
        var b = Button{};
        b.setStyle(s);
        b.setMinSize(0, 0);
        b.setLabel("Go");
        b.setGeometry(4, 4, 100, 32);
        b.paint(cr, 1000);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // Glyph + label together.
    var both = Button{};
    both.setMinSize(0, 0);
    both.setGlyph("close");
    both.setLabel("Close");
    both.setGeometry(4, 4, 100, 32);
    both.paint(cr, 0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Zero geometry returns before drawing anything, so a null context is fine.
    var degenerate = Button{};
    degenerate.paint(null, 0);
    degenerate.paintStatic(null);
}

test "m3-button: callbacks fire in the documented order" {
    const t = testing;
    // Three independent counters, each reached through its own sink:
    // three plain function pointers sharing the button's context pointer.
    const S = struct {
        var clicks: usize = 0;
        var presses: usize = 0;
        var releases: usize = 0;
        fn onClick(_: ?*anyopaque) void {
            clicks += 1;
        }
        fn onPress(_: ?*anyopaque) void {
            presses += 1;
        }
        fn onRelease(_: ?*anyopaque) void {
            releases += 1;
        }
    };
    S.clicks = 0;
    S.presses = 0;
    S.releases = 0;

    var b = Button{};
    b.setMinSize(0, 0);
    b.setGeometry(0, 0, 40, 40);
    b.setOnClick(S.onClick);
    b.setOnPress(S.onPress);
    b.setOnRelease(S.onRelease);

    // A press-then-release inside the button hits all three, with press
    // firing on the way down and click on the way up.
    try t.expect(b.handlePointerDown(10, 10));
    try t.expectEqual(@as(usize, 1), S.presses);
    try t.expectEqual(@as(usize, 0), S.clicks);
    try t.expect(b.handlePointerUp(10, 10));
    try t.expectEqual(@as(usize, 1), S.clicks);

    // A release outside cancels the click but still reports the release —
    // `on_release` means "the press ended", not "you clicked".
    _ = b.handlePointerDown(10, 10);
    _ = b.handlePointerUp(900, 900);
    try t.expectEqual(@as(usize, 1), S.clicks);
    try t.expectEqual(@as(usize, 2), S.releases);

    // A press that misses the button fires nothing at all.
    _ = b.handlePointerDown(900, 900);
    try t.expectEqual(@as(usize, 2), S.presses);
}
