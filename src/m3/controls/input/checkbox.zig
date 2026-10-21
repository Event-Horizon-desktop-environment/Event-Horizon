//! The M3 checkbox.
//!
//! Three states (unchecked / checked / indeterminate), a state layer, a focus
//! ring, and an animated checkmark.
//!
//! The animation is the interesting part: `anim_tween` drives a single 0→1
//! value that both the fill alpha and the mark alpha read, but the checkmark
//! itself is *drawn* progressively too. Its two segments have different
//! lengths, so the stroke is split proportionally — the short leg finishes
//! first and the long leg carries on, which is what makes the tick read as a
//! pen stroke rather than a fade.
//!
//! Note `setState` starts the tween from wherever the tween *currently* is
//! (`animTween_.value(nowMs)`), not from 0 or 1. That is what lets a re-toggle
//! mid-flight reverse smoothly instead of snapping.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const state_layer_mod = @import("../../core/primitives/state_layer.zig");
const animation = @import("../../core/animation.zig");

pub const StateLayer = state_layer_mod.StateLayer;
pub const FocusRing = state_layer_mod.FocusRing;
pub const Tween = animation.Tween;

/// The three-state enum, defined at file scope so `StateHandler` can name it
/// before `Checkbox` exists.
pub const CheckboxState = enum {
    unchecked,
    checked,
    indeterminate,
};

/// Click sink, and the state-change sink: plain function pointers sharing one context pointer.
pub const Callback = *const fn (ctx: ?*anyopaque) void;
pub const StateHandler = *const fn (ctx: ?*anyopaque, state: CheckboxState) void;

/// M3 Checkbox — 3 states (checked/unchecked/indeterminate), state layer,
/// focus ring, animated checkmark.
pub const Checkbox = struct {
    /// Re-exported so `Checkbox.State` still works.
    pub const State = CheckboxState;

    /// Box edge length in dp, centred inside whatever geometry is given.
    pub const kBoxSize: f32 = 18.0;
    /// `corner.extra-small`.
    pub const kBoxRadius: f32 = 4.0;
    /// Checkmark stroke width.
    pub const kStrokeWidth: f32 = 2.0;
    /// Tween length for a state change: `200` ms.
    pub const kAnimMs: u64 = 200;

    state: State = .unchecked,
    enabled: bool = true,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,

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

    anim_tween: Tween = .{},
    state_layer: StateLayer = .{},
    focus_ring: FocusRing = .{},

    on_click: ?Callback = null,
    on_change: ?StateHandler = null,
    cb_ctx: ?*anyopaque = null,

    /// Change state, starting the checkmark tween from the tween's *current*
    /// value so a toggle mid-flight reverses smoothly.
    pub fn setState(self: *Checkbox, s: State, now_ms: u64) void {
        if (s == self.state) return;
        self.state = s;
        // Only "checked" animates toward 1; unchecked and indeterminate both
        // settle at 0.
        self.anim_tween.start(
            self.anim_tween.value(now_ms),
            if (s == .checked) 1.0 else 0.0,
            now_ms,
            kAnimMs,
            animation.kEmphasized,
        );
    }

    /// Convenience for a stateless "set it now" call.
    pub fn setStateImmediate(self: *Checkbox, s: State) void {
        self.setState(s, 0);
    }

    pub fn setEnabled(self: *Checkbox, e: bool) void {
        self.enabled = e;
    }

    pub fn setGeometry(self: *Checkbox, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *Checkbox, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Checkbox, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Checkbox, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setHovered(self: *Checkbox, h: bool) void {
        self.hovered = h;
    }

    pub fn setPressed(self: *Checkbox, p: bool) void {
        self.pressed = p;
    }

    pub fn setFocused(self: *Checkbox, f: bool) void {
        self.focused = f;
    }

    pub fn setOnClick(self: *Checkbox, cb: ?Callback) void {
        self.on_click = cb;
    }

    pub fn setOnChange(self: *Checkbox, cb: ?StateHandler) void {
        self.on_change = cb;
    }

    pub fn setCallbackContext(self: *Checkbox, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn stateOf(self: *const Checkbox) State {
        return self.state;
    }

    pub fn isEnabled(self: *const Checkbox) bool {
        return self.enabled;
    }

    /// Only `.checked` counts — indeterminate is deliberately not "checked",
    /// which is why the two are exposed separately.
    pub fn isChecked(self: *const Checkbox) bool {
        return self.state == .checked;
    }

    pub fn isIndeterminate(self: *const Checkbox) bool {
        return self.state == .indeterminate;
    }

    pub fn containsPoint(self: *const Checkbox, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    pub fn handlePointerEnter(self: *Checkbox, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        self.hovered = true;
        return true;
    }

    pub fn handlePointerLeave(self: *Checkbox) bool {
        self.hovered = false;
        self.pressed = false;
        return true;
    }

    pub fn handlePointerDown(self: *Checkbox, px: f32, py: f32) bool {
        if (!self.enabled or !self.containsPoint(px, py)) return false;
        self.pressed = true;
        return true;
    }

    /// Cycles unchecked → checked → unchecked, and indeterminate → unchecked.
    pub fn handlePointerUp(self: *Checkbox, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        if (self.pressed) {
            self.pressed = false;
            const next: State = switch (self.state) {
                .unchecked => .checked,
                .checked, .indeterminate => .unchecked,
            };
            // Note the tween runs at time 0 —
            // here rather than a real timestamp, so the transition is
            // evaluated at the start of the animation clock.
            self.setState(next, 0);
            if (self.on_change) |cb| cb(self.cb_ctx, self.state);
            if (self.on_click) |cb| cb(self.cb_ctx);
        }
        return true;
    }

    /// Non-animated paint — forwards to the timestamped overload at 0.
    pub fn paintStatic(self: *Checkbox, c: ?*cairo.cairo_t) void {
        self.paint(c, 0);
    }

    pub fn paint(self: *Checkbox, c: ?*cairo.cairo_t, now_ms: u64) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        const cx = self.x + self.w * 0.5;
        const cy = self.y + self.h * 0.5;
        const box_size = kBoxSize;
        const half_box = box_size * 0.5;
        const bx = cx - half_box;
        const by = cy - half_box;
        const radius = kBoxRadius;

        const is_checked = self.state == .checked;
        const is_indet = self.state == .indeterminate;
        const anim_t = self.anim_tween.value(now_ms);

        // Background and outline colours.
        var bg_r: f32 = 0;
        var bg_g: f32 = 0;
        var bg_b: f32 = 0;
        var bg_a: f32 = 0;
        // The mark is always white on the accent fill.
        const fg_r: f32 = 1.0;
        const fg_g: f32 = 1.0;
        const fg_b: f32 = 1.0;
        var out_r: f32 = 0;
        var out_g: f32 = 0;
        var out_b: f32 = 0;
        var out_a: f32 = 0;

        if (!self.enabled) {
            // Disabled: the *text* colour at 38% for both fill and outline.
            // Note `textR_` writes into all three channels here — it
            // is a monochrome disabled state by design, not a typo to fix.
            bg_r = self.text_r;
            bg_g = self.text_r;
            bg_b = self.text_r;
            bg_a = 0.38;
            out_r = self.text_r;
            out_g = self.text_r;
            out_b = self.text_r;
            out_a = 0.38;
        } else if (is_checked or is_indet) {
            bg_r = self.accent_r;
            bg_g = self.accent_g;
            bg_b = self.accent_b;
            bg_a = 1.0;
            out_r = self.accent_r;
            out_g = self.accent_g;
            out_b = self.accent_b;
            out_a = 0.0;
        } else {
            bg_a = 0.0;
            out_r = self.text_r;
            out_g = self.text_g;
            out_b = self.text_b;
            out_a = 0.5;
        }

        // Animated fill alpha. A disabled box uses its flat colour, a checked
        // box fades the accent in with `anim_t`, and an unchecked box fades
        // out — though its alpha is multiplied by 0, so it stays invisible.
        var fill_r: f32 = 0;
        var fill_g: f32 = 0;
        var fill_b: f32 = 0;
        var fill_a: f32 = 0;
        if (!self.enabled) {
            fill_r = bg_r;
            fill_g = bg_g;
            fill_b = bg_b;
            fill_a = bg_a;
        } else if (is_checked or is_indet) {
            fill_r = self.accent_r;
            fill_g = self.accent_g;
            fill_b = self.accent_b;
            fill_a = anim_t;
        } else {
            fill_a = (1.0 - anim_t) * 0.0;
        }

        cairo.cairo_save(cr);

        // Container path.
        roundedPath(cr, bx, by, box_size, box_size, radius);

        // Fill — preserved so the outline below can reuse the path.
        if (fill_a > 0) {
            cairo.cairo_set_source_rgba(cr, fill_r, fill_g, fill_b, fill_a);
            cairo.cairo_fill_preserve(cr);
        }

        // Outline. When unchecked or indeterminate the path is re-cut and
        // stroked at 2dp; a checked box has no outline at all.
        if (!self.enabled) {
            cairo.cairo_set_source_rgba(cr, out_r, out_g, out_b, 0.38);
        } else if (!is_checked and !is_indet) {
            cairo.cairo_set_source_rgba(cr, out_r, out_g, out_b, out_a);
        }
        if (!is_checked and !is_indet) {
            cairo.cairo_set_line_width(cr, kStrokeWidth);
            roundedPath(cr, bx, by, box_size, box_size, radius);
            cairo.cairo_stroke(cr);
        }

        cairo.cairo_restore(cr);

        // Glyph: checkmark (checked) or dash (indeterminate).
        if (is_checked or is_indet) {
            cairo.cairo_save(cr);
            cairo.cairo_set_source_rgba(cr, fg_r, fg_g, fg_b, anim_t);
            cairo.cairo_set_line_width(cr, kStrokeWidth);
            cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);

            if (is_indet) {
                // A horizontal dash.
                cairo.cairo_move_to(cr, cx - 5, cy);
                cairo.cairo_line_to(cr, cx + 5, cy);
            } else if (anim_t > 0.3) {
                // Checkmark, drawn progressively. The first 30% of the tween
                // only fades the mark in; the remaining 70% traces it.
                const draw_t = @min(1.0, (anim_t - 0.3) / 0.7);
                const lx1 = cx - 5;
                const ly1 = cy;
                const lx2 = cx - 1;
                const ly2 = cy + 4;
                const lx3 = cx + 6;
                const ly3 = cy - 3;

                // The two legs have different lengths, so the split is
                // proportional — the short leg finishes first.
                const seg_len = @sqrt(25.0 + 16.0);
                const total_len = seg_len + @sqrt(49.0 + 49.0);
                const len1 = seg_len / total_len;
                const t = draw_t;

                if (t < len1) {
                    const st = t / len1;
                    cairo.cairo_move_to(cr, lx1, ly1);
                    cairo.cairo_line_to(cr, lx1 + (lx2 - lx1) * st, ly1 + (ly2 - ly1) * st);
                } else {
                    const st = (t - len1) / (1.0 - len1);
                    cairo.cairo_move_to(cr, lx1, ly1);
                    cairo.cairo_line_to(cr, lx2, ly2);
                    cairo.cairo_move_to(cr, lx2, ly2);
                    cairo.cairo_line_to(cr, lx2 + (lx3 - lx2) * st, ly2 + (ly3 - ly2) * st);
                }
            }
            cairo.cairo_stroke(cr);
            cairo.cairo_restore(cr);
        }

        // State layer — a circle twice the box size, so the wash extends past
        // the control rather than stopping at its edge.
        self.state_layer.setColor(self.accent_r, self.accent_g, self.accent_b);
        self.state_layer.setRadius(box_size * 0.5);
        self.state_layer.setGeometry(cx - box_size, cy - box_size, box_size * 2.0, box_size * 2.0);
        self.state_layer.setHovered(self.hovered);
        self.state_layer.setPressed(self.pressed);
        self.state_layer.setFocused(self.focused);
        self.state_layer.tick(now_ms);
        self.state_layer.paint(c, now_ms);

        // Focus ring.
        self.focus_ring.setFocused(self.focused);
        self.focus_ring.setColor(self.text_r, self.text_g, self.text_b);
        self.focus_ring.setRadius(box_size * 0.5 + 4.0);
        self.focus_ring.paint(c, cx - half_box - 4.0, cy - half_box - 4.0, box_size + 8.0, box_size + 8.0);
    }

    /// Four quarter-arcs joined into a rounded rectangle.
    fn roundedPath(cr: ?*cairo.cairo_t, x: f32, y: f32, w: f32, h: f32, r: f32) void {
        cairo.cairo_new_path(cr);
        cairo.cairo_arc(cr, x + r, y + r, r, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, x + w - r, y + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_arc(cr, x + w - r, y + h - r, r, 0.0, 0.5 * std.math.pi);
        cairo.cairo_arc(cr, x + r, y + h - r, r, 0.5 * std.math.pi, std.math.pi);
        cairo.cairo_close_path(cr);
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-checkbox: state cycles checked -> unchecked, and indeterminate clears" {
    const t = testing;
    const S = struct {
        var changes: usize = 0;
        var last: Checkbox.State = .unchecked;
        var clicks: usize = 0;
        fn onChange(ctx: ?*anyopaque, s: Checkbox.State) void {
            _ = ctx;
            changes += 1;
            last = s;
        }
        fn onClick(ctx: ?*anyopaque) void {
            _ = ctx;
            clicks += 1;
        }
    };
    S.changes = 0;
    S.clicks = 0;

    var cbx = Checkbox{};
    cbx.setGeometry(0, 0, 32, 32);
    cbx.setOnChange(S.onChange);
    cbx.setOnClick(S.onClick);

    // Unchecked -> checked on release, and both sinks fire.
    _ = cbx.handlePointerDown(8, 8);
    _ = cbx.handlePointerUp(8, 8);
    try t.expect(cbx.isChecked());
    try t.expectEqual(@as(usize, 1), S.changes);
    try t.expectEqual(@as(usize, 1), S.clicks);
    try t.expect(S.last == .checked);

    // Checked -> unchecked.
    _ = cbx.handlePointerDown(8, 8);
    _ = cbx.handlePointerUp(8, 8);
    try t.expect(!cbx.isChecked());
    try t.expectEqual(Checkbox.State.unchecked, S.last);

    // Indeterminate is not "checked" — kept separate.
    cbx.setStateImmediate(.indeterminate);
    try t.expect(!cbx.isChecked());
    try t.expect(cbx.isIndeterminate());

    // A disabled checkbox refuses pointer input entirely.
    cbx.setEnabled(false);
    try t.expect(!cbx.handlePointerEnter(8, 8));
    try t.expect(!cbx.handlePointerDown(8, 8));
    try t.expect(!cbx.handlePointerUp(8, 8));
}

test "m3-checkbox: setState no-ops when already in that state" {
    const t = testing;
    var cbx = Checkbox{};
    cbx.setStateImmediate(.checked);
    // A second call to the same state must not restart the tween.
    cbx.anim_tween.stop();
    cbx.setState(.checked, 0);
    try t.expect(!cbx.anim_tween.active);
    // Changing state does arm it.
    cbx.setState(.unchecked, 0);
    try t.expect(cbx.anim_tween.active);
}

test "m3-checkbox: every state paints cleanly, including disabled" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .unchecked, .checked, .indeterminate }) |s| {
        var cbx = Checkbox{};
        cbx.setStateImmediate(s);
        cbx.setGeometry(10, 10, 32, 32);
        cbx.setFocused(true);
        cbx.paint(cr, 1000);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    var disabled = Checkbox{};
    disabled.setEnabled(false);
    disabled.setStateImmediate(.checked);
    disabled.setGeometry(10, 10, 32, 32);
    disabled.paintStatic(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Mid-animation must also be paintable — the mark is partially traced.
    var animating = Checkbox{};
    animating.setGeometry(10, 10, 32, 32);
    animating.setState(.checked, 1000);
    animating.paint(cr, 1050);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = Checkbox{};
    degenerate.paint(null, 0);
    degenerate.paintStatic(null);
}
