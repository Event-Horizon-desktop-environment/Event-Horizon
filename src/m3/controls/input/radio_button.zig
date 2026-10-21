//! The M3 radio button.
//!
//! Selected / unselected, with an inner dot that grows on selection. Unlike
//! `Checkbox`, a radio button is a one-way switch: `handlePointerUp` only
//! moves toward selected, never back to unselected, because deselecting is
//! the job of whichever sibling gets selected instead.
//!
//! Its hit target is a **circle**, not the geometry box: `containsPoint`
//! measures distance from the centre against a fixed 24dp radius, so a radio
//! responds within a 48dp touch target however small its geometry was set.
//!
//! Two distinct sinks fire on release — `on_select` only when the click
//! actually changed the state, `on_click` every time. That is what lets a
//! listener both apply the selection and, say, close a menu, without having
//! to re-read `isSelected()` to tell the two apart.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const state_layer_mod = @import("../../core/primitives/state_layer.zig");
const animation = @import("../../core/animation.zig");

pub const StateLayer = state_layer_mod.StateLayer;
pub const FocusRing = state_layer_mod.FocusRing;
pub const Tween = animation.Tween;

pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// M3 RadioButton — selected/unselected, state layer, focus ring, animated dot.
pub const RadioButton = struct {
    /// Outer ring radius, giving the 20dp visual.
    pub const kOuterR: f32 = 10.0;
    /// Full radius the inner dot grows to.
    pub const kInnerR: f32 = 5.0;
    /// Ring stroke width.
    pub const kStrokeWidth: f32 = 2.0;
    /// Fixed touch-target radius — 48dp across, centred on the control.
    pub const kTouchRadius: f32 = 24.0;
    /// Tween length for a selection change: `200` ms.
    pub const kAnimMs: u64 = 200;

    selected: bool = false,
    enabled: bool = true,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 48.0,
    h: f32 = 48.0,

    accent_r: f32 = 0.769,
    accent_g: f32 = 0.659,
    accent_b: f32 = 0.941,
    text_r: f32 = 1.0,
    text_g: f32 = 1.0,
    text_b: f32 = 1.0,

    anim_tween: Tween = .{},
    state_layer: StateLayer = .{},
    focus_ring: FocusRing = .{},

    on_click: ?Callback = null,
    on_select: ?Callback = null,
    cb_ctx: ?*anyopaque = null,

    pub fn setSelected(self: *RadioButton, s: bool, now_ms: u64) void {
        if (s == self.selected) return;
        self.selected = s;
        self.anim_tween.start(
            self.anim_tween.value(now_ms),
            if (s) 1.0 else 0.0,
            now_ms,
            kAnimMs,
            animation.kEmphasized,
        );
    }

    pub fn setEnabled(self: *RadioButton, e: bool) void {
        self.enabled = e;
    }

    pub fn setGeometry(self: *RadioButton, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *RadioButton, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setTextColor(self: *RadioButton, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setHovered(self: *RadioButton, h: bool) void {
        self.hovered = h;
    }

    pub fn setPressed(self: *RadioButton, p: bool) void {
        self.pressed = p;
    }

    pub fn setFocused(self: *RadioButton, f: bool) void {
        self.focused = f;
    }

    pub fn setOnClick(self: *RadioButton, cb: ?Callback) void {
        self.on_click = cb;
    }

    /// Fires only when the press actually changed the selection.
    pub fn setOnSelect(self: *RadioButton, cb: ?Callback) void {
        self.on_select = cb;
    }

    pub fn setCallbackContext(self: *RadioButton, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn isSelected(self: *const RadioButton) bool {
        return self.selected;
    }

    pub fn isEnabled(self: *const RadioButton) bool {
        return self.enabled;
    }

    /// Circular hit target: distance from the centre against `kTouchRadius`,
    /// independent of the geometry box.
    pub fn containsPoint(self: *const RadioButton, px: f32, py: f32) bool {
        const cx = self.x + self.w * 0.5;
        const cy = self.y + self.h * 0.5;
        const r = kTouchRadius;
        return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r;
    }

    pub fn handlePointerEnter(self: *RadioButton, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        self.hovered = true;
        return true;
    }

    pub fn handlePointerLeave(self: *RadioButton) bool {
        self.hovered = false;
        self.pressed = false;
        return true;
    }

    pub fn handlePointerDown(self: *RadioButton, px: f32, py: f32) bool {
        if (!self.enabled or !self.containsPoint(px, py)) return false;
        self.pressed = true;
        return true;
    }

    /// One-way: a press selects, and deselecting is left to a sibling. Note
    /// this sets `selected` directly rather than going through
    /// `setSelected` directly — so the dot tween is *not*
    /// re-armed, and the change appears immediately.
    pub fn handlePointerUp(self: *RadioButton, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        if (self.pressed) {
            self.pressed = false;
            if (!self.selected) {
                self.selected = true;
                if (self.on_select) |cb| cb(self.cb_ctx);
            }
            if (self.on_click) |cb| cb(self.cb_ctx);
        }
        return true;
    }

    /// Non-animated paint — forwards to the timestamped
    /// overload at 0.
    pub fn paintStatic(self: *RadioButton, c: ?*cairo.cairo_t) void {
        self.paint(c, 0);
    }

    pub fn paint(self: *RadioButton, c: ?*cairo.cairo_t, now_ms: u64) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        const cx = self.x + self.w * 0.5;
        const cy = self.y + self.h * 0.5;
        const outer_r = kOuterR;
        const inner_r = kInnerR;

        const anim_t = self.anim_tween.value(now_ms);
        const alpha: f32 = if (self.enabled) 1.0 else 0.38;

        // Ring colour: text when unselected, accent when selected. Disabled
        // uses the text colour in all three channels again, matching the
        // other input controls.
        var ring_r: f32 = 0;
        var ring_g: f32 = 0;
        var ring_b: f32 = 0;
        if (!self.enabled) {
            ring_r = self.text_r;
            ring_g = self.text_r;
            ring_b = self.text_r;
        } else if (self.selected) {
            ring_r = self.accent_r;
            ring_g = self.accent_g;
            ring_b = self.accent_b;
        } else {
            ring_r = self.text_r;
            ring_g = self.text_g;
            ring_b = self.text_b;
        }

        cairo.cairo_save(cr);

        // Outer ring.
        cairo.cairo_set_source_rgba(cr, ring_r, ring_g, ring_b, alpha);
        cairo.cairo_set_line_width(cr, kStrokeWidth);
        cairo.cairo_arc(cr, cx, cy, outer_r, 0.0, 2.0 * std.math.pi);
        cairo.cairo_stroke(cr);

        // Inner dot — both its radius *and* its alpha follow the tween, so it
        // swells into place rather than fading in at full size.
        if (anim_t > 0.0) {
            const dot_r = inner_r * anim_t;
            cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, alpha * anim_t);
            cairo.cairo_arc(cr, cx, cy, dot_r, 0.0, 2.0 * std.math.pi);
            cairo.cairo_fill(cr);
        }

        cairo.cairo_restore(cr);

        // State layer — a circle 8dp wider than the ring on each side.
        if (self.selected) {
            self.state_layer.setColor(self.accent_r, self.accent_g, self.accent_b);
        } else {
            self.state_layer.setColor(self.text_r, self.text_g, self.text_b);
        }
        self.state_layer.setRadius(outer_r + 8.0);
        self.state_layer.setGeometry(cx - outer_r - 8.0, cy - outer_r - 8.0, (outer_r + 8.0) * 2.0, (outer_r + 8.0) * 2.0);
        self.state_layer.setHovered(self.hovered);
        self.state_layer.setPressed(self.pressed);
        self.state_layer.setFocused(self.focused);
        self.state_layer.tick(now_ms);
        self.state_layer.paint(c, now_ms);

        // Focus ring — a touch tighter than the state layer, at +6.
        self.focus_ring.setFocused(self.focused);
        self.focus_ring.setColor(self.text_r, self.text_g, self.text_b);
        self.focus_ring.setRadius(outer_r + 6.0);
        self.focus_ring.paint(c, cx - outer_r - 6.0, cy - outer_r - 6.0, (outer_r + 6.0) * 2.0, (outer_r + 6.0) * 2.0);
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-radio: the touch target is a circle, not the geometry box" {
    const t = testing;
    var rb = RadioButton{};
    // A tiny 4x4 geometry, centred at (50, 50).
    rb.setGeometry(48, 48, 4, 4);

    // Inside the 24dp radius but well outside the 4px box — this is the point
    // of the circular test.
    try t.expect(rb.containsPoint(60, 50));
    try t.expect(rb.containsPoint(50, 72));
    // Beyond the radius, still inside the parent square.
    try t.expect(!rb.containsPoint(50, 75));
}

test "m3-radio: presses select but never deselect" {
    const t = testing;
    const S = struct {
        var clicks: usize = 0;
        var selects: usize = 0;
        fn onClick(ctx: ?*anyopaque) void {
            _ = ctx;
            clicks += 1;
        }
        fn onSelect(ctx: ?*anyopaque) void {
            _ = ctx;
            selects += 1;
        }
    };
    S.clicks = 0;
    S.selects = 0;

    var rb = RadioButton{};
    rb.setGeometry(0, 0, 48, 48);
    rb.setOnClick(S.onClick);
    rb.setOnSelect(S.onSelect);

    // The control is centred at (24, 24), so (40, 40) — 22.6dp out — sits
    // inside the 24dp circular target. First press selects and fires both sinks.
    try t.expect(rb.handlePointerDown(40, 40));
    _ = rb.handlePointerUp(40, 40);
    try t.expect(rb.isSelected());
    try t.expectEqual(@as(usize, 1), S.selects);
    try t.expectEqual(@as(usize, 1), S.clicks);

    // A second press keeps it selected, fires on_click but not on_select —
    // deselecting is a sibling's job.
    _ = rb.handlePointerDown(40, 40);
    _ = rb.handlePointerUp(40, 40);
    try t.expect(rb.isSelected());
    try t.expectEqual(@as(usize, 1), S.selects);
    try t.expectEqual(@as(usize, 2), S.clicks);

    // Disabled refuses input outright.
    rb.setEnabled(false);
    try t.expect(!rb.handlePointerDown(40, 40));
}

test "m3-radio: paints selected, unselected and disabled" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 96, 96);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var plain = RadioButton{};
    plain.setGeometry(20, 20, 48, 48);
    plain.setFocused(true);
    plain.paintStatic(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    var picked = RadioButton{};
    picked.setGeometry(20, 20, 48, 48);
    picked.setSelected(true, 0);
    picked.paint(cr, 1000);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Mid-grow: the dot is part-way out.
    var growing = RadioButton{};
    growing.setGeometry(20, 20, 48, 48);
    growing.setSelected(true, 1000);
    growing.paint(cr, 1050);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    var disabled = RadioButton{};
    disabled.setEnabled(false);
    disabled.setGeometry(20, 20, 48, 48);
    disabled.paintStatic(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = RadioButton{};
    degenerate.paint(null, 0);
}
