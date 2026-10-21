//! M3 state-layer overlay and focus ring.
//! focus ring.
//!
//! The state layer is the translucent wash Material paints *over* a container
//! to show hover/press/focus/drag, tinted with the container's content colour
//! rather than an accent. Its opacity is a spec constant per state
//! (hover 0.08, focus 0.12, press 0.12, drag 0.16), and it eases toward that
//! target over 100ms so the wash fades rather than snapping.
//!
//! `FocusRing` also lives here.
//! Defined alongside `StateLayer`. `focus_ring.zig`
//! re-exports it for the same reason.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const animation = @import("../animation.zig");

pub const Tween = animation.Tween;
pub const kStandardDecelerate = animation.kStandardDecelerate;

/// The rounded-rect path both classes build, repeating these four
/// quarter-arc calls inline in `StateLayer::paint` and `FocusRing::paint`;
/// hoisting them here produces bit-identical geometry without the copy.
fn roundedPath(cr: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, rad: f64) void {
    const r = @min(rad, @min(w, h) * 0.5);
    if (r > 0) {
        cairo.cairo_new_path(cr);
        cairo.cairo_arc(cr, x + r, y + r, r, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, x + w - r, y + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_arc(cr, x + w - r, y + h - r, r, 0.0, 0.5 * std.math.pi);
        cairo.cairo_arc(cr, x + r, y + h - r, r, 0.5 * std.math.pi, std.math.pi);
        cairo.cairo_close_path(cr);
    } else {
        cairo.cairo_rectangle(cr, x, y, w, h);
    }
}

/// M3 state layer overlay. Renders a semi-transparent shape on top of a
/// container using the container's content colour as the layer colour.
/// Opacities: hover=0.08, focus=0.12, press=0.12, drag=0.16.
pub const StateLayer = struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
    radius: f32 = 0.0,
    gx: f32 = 0.0,
    gy: f32 = 0.0,
    gw: f32 = 0.0,
    gh: f32 = 0.0,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    dragged: bool = false,
    opacity_tween: Tween = .{},

    pub fn setColor(self: *StateLayer, red: f32, green: f32, blue: f32) void {
        self.r = red;
        self.g = green;
        self.b = blue;
    }

    pub fn setRadius(self: *StateLayer, rad: f32) void {
        self.radius = rad;
    }

    pub fn setGeometry(self: *StateLayer, x: f32, y: f32, w: f32, h: f32) void {
        self.gx = x;
        self.gy = y;
        self.gw = w;
        self.gh = h;
    }

    pub fn setHovered(self: *StateLayer, h: bool) void {
        self.hovered = h;
    }

    pub fn setPressed(self: *StateLayer, p: bool) void {
        self.pressed = p;
    }

    pub fn setFocused(self: *StateLayer, f: bool) void {
        self.focused = f;
    }

    pub fn setDragged(self: *StateLayer, d: bool) void {
        self.dragged = d;
    }

    pub fn hoveredState(self: *const StateLayer) bool {
        return self.hovered;
    }

    pub fn pressedState(self: *const StateLayer) bool {
        return self.pressed;
    }

    pub fn focusedState(self: *const StateLayer) bool {
        return self.focused;
    }

    /// Current target opacity from M3 spec.
    ///
    /// The order matters: drag outranks press, press outranks focus, focus
    /// outranks hover. Only the most emphatic active state paints, so a
    /// dragged-and-hovered layer reads as a drag.
    pub fn targetOpacity(self: *const StateLayer) f32 {
        if (self.dragged) return 0.16;
        if (self.pressed) return 0.12;
        if (self.focused) return 0.12;
        if (self.hovered) return 0.08;
        return 0.0;
    }

    /// Animate opacity toward target. Call tick() each frame.
    pub fn tick(self: *StateLayer, now_ms: u64) void {
        // Retarget from wherever the tween currently is, over the spec's
        // 100ms, so switching state mid-fade does not jump.
        const from = self.opacity_tween.value(now_ms);
        self.opacity_tween.start(from, self.targetOpacity(), now_ms, 100, kStandardDecelerate);
    }

    pub fn paint(self: *const StateLayer, c: ?*cairo.cairo_t, now_ms: u64) void {
        const alpha = if (self.opacity_tween.active) self.opacity_tween.value(now_ms) else self.targetOpacity();
        if (alpha <= 0.0 or self.gw <= 0 or self.gh <= 0) return;
        const cr = c orelse return;

        cairo.cairo_save(cr);
        cairo.cairo_translate(cr, self.gx, self.gy);

        roundedPath(cr, 0, 0, self.gw, self.gh, self.radius);
        cairo.cairo_set_source_rgba(cr, self.r, self.g, self.b, alpha);
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);
    }
};

/// M3 focus ring — 2–3dp outline drawn outside component edge with 1dp gap.
///
/// The ring is stroked *outside* the component by `gap + width`, which is why
/// the outer rect grows by twice that and the corner radius is inflated by the
/// half-width: the stroke must stay concentric with the component's own corner.
pub const FocusRing = struct {
    /// on-surface-variant default.
    r: f32 = 0.6,
    g: f32 = 0.6,
    b: f32 = 0.6,
    width: f32 = 2.0,
    gap: f32 = 1.0,
    radius: f32 = 0.0,
    focused: bool = false,

    pub fn setColor(self: *FocusRing, red: f32, green: f32, blue: f32) void {
        self.r = red;
        self.g = green;
        self.b = blue;
    }

    pub fn setWidth(self: *FocusRing, w: f32) void {
        self.width = w;
    }

    pub fn setGap(self: *FocusRing, g: f32) void {
        self.gap = g;
    }

    pub fn setRadius(self: *FocusRing, rad: f32) void {
        self.radius = rad;
    }

    pub fn setFocused(self: *FocusRing, f: bool) void {
        self.focused = f;
    }

    /// Geometry is passed per call rather than stored — a single ring object
    /// is reused across a component's children.
    pub fn paint(self: *const FocusRing, c: ?*cairo.cairo_t, x: f32, y: f32, w: f32, h: f32) void {
        if (!self.focused) return;
        const cr = c orelse return;

        const outer_x: f64 = @as(f64, x) - @as(f64, self.gap) - @as(f64, self.width);
        const outer_y: f64 = @as(f64, y) - @as(f64, self.gap) - @as(f64, self.width);
        const outer_w: f64 = @as(f64, w) + 2.0 * (@as(f64, self.gap) + @as(f64, self.width));
        const outer_h: f64 = @as(f64, h) + 2.0 * (@as(f64, self.gap) + @as(f64, self.width));
        const outer_r: f64 = @as(f64, self.radius) + @as(f64, self.gap) + @as(f64, self.width) * 0.5;

        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, self.r, self.g, self.b, 1.0);
        cairo.cairo_set_line_width(cr, self.width);

        roundedPath(cr, outer_x, outer_y, outer_w, outer_h, outer_r);
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
    }
};

test "m3-state-layer: opacity ladder honours drag>press>hover" {
    const t = std.testing;
    var sl = StateLayer{};
    try t.expectEqual(@as(f32, 0.0), sl.targetOpacity());
    sl.setHovered(true);
    try t.expectEqual(@as(f32, 0.08), sl.targetOpacity());
    sl.setFocused(true);
    try t.expectEqual(@as(f32, 0.12), sl.targetOpacity());
    sl.setPressed(true);
    try t.expectEqual(@as(f32, 0.12), sl.targetOpacity());
    // Drag is the most emphatic state and must win over all the others.
    sl.setDragged(true);
    try t.expectEqual(@as(f32, 0.16), sl.targetOpacity());
}

test "m3-state-layer: paints and respects degenerate geometry" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 40, 40);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var sl = StateLayer{};
    sl.setColor(1.0, 1.0, 1.0);
    sl.setRadius(6.0);
    sl.setGeometry(4, 4, 30, 20);
    sl.setHovered(true);
    // No tick yet, so this paints the raw target opacity rather than a tween.
    sl.paint(cr, 0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Zero width short-circuits before any drawing happens.
    var degenerate = StateLayer{};
    degenerate.setHovered(true);
    degenerate.setGeometry(0, 0, 0, 0);
    degenerate.paint(cr, 0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // A transparent layer draws nothing at all, so a null context is fine.
    var idle = StateLayer{};
    idle.setGeometry(0, 0, 10, 10);
    idle.paint(null, 0);
}

test "m3-state-layer: tick retargets the tween and settles on the target" {
    const t = std.testing;
    var sl = StateLayer{};
    sl.setGeometry(0, 0, 10, 10);
    sl.setHovered(true);
    sl.tick(1000);

    // `tick` arms a tween toward the hovered target. With the clamped Newton
    // solve in `m3/tokens/motion.zig`, `kStandardDecelerate` eases smoothly:
    // at 1ms the layer has only just begun to fade toward the 0.08 hover
    // target instead of snapping straight to it.
    // whose first Newton step overshoots — see that file's note — still snaps;
    // this port deliberately clamps, so it animates.)
    try t.expect(sl.opacity_tween.active);
    const early = sl.opacity_tween.value(1001);
    try t.expect(early > 0.0 and early < 0.08);
    // By 1s the tween has long settled on the target.
    try t.expectEqual(@as(f32, 0.08), sl.opacity_tween.value(2000));

    // Retargeting to a different state re-aims the tween at the new opacity.
    sl.setDragged(true);
    sl.tick(3000);
    try t.expectEqual(@as(f32, 0.16), sl.opacity_tween.value(4000));
}

test "m3-focus-ring: draws outside the component only when focused" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 60, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var ring = FocusRing{};
    ring.setColor(0.6, 0.6, 0.6);
    ring.setRadius(8.0);
    // Unfocused, the ring returns before touching the context.
    ring.paint(cr, 10, 10, 30, 30);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    ring.setFocused(true);
    ring.paint(cr, 10, 10, 30, 30);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
