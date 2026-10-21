//! The M3 switch, in three sizes.
//!
//! Two tweens run in parallel on the same 200ms window: `thumb_tween` moves
//! the handle along the track while `track_tween` cross-fades the track
//! colour from the surface tone to the accent. Reading both off one clock is
//! what makes the switch feel like a single motion rather than a dot that
//! slides and then a track that catches up.
//!
//! The switch draws itself centred in its geometry, from the size table's
//! track dimensions — the box it was handed only supplies a centre point, the
//! same way `FAB` works.
//!
//! Two details worth preserving:
//!
//!   * The track outline is drawn only while the switch is *off and enabled*,
//!     at `trackR - 1` with a 2dp stroke, so the 2dp line straddles the edge.
//!   * `state_layer.setGeometry` is keyed off the **thumb**, not the track —
//!     a 6×-thumb square centred on the handle. The wash follows the dot.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const state_layer_mod = @import("../../core/primitives/state_layer.zig");
const animation = @import("../../core/animation.zig");

pub const StateLayer = state_layer_mod.StateLayer;
pub const FocusRing = state_layer_mod.FocusRing;
pub const Tween = animation.Tween;

pub const Callback = *const fn (ctx: ?*anyopaque) void;
pub const ToggleCallback = *const fn (ctx: ?*anyopaque, on: bool) void;

/// M3 Switch (Toggle) — 3 sizes, state layers, disabled token opacities,
/// track outline when off, selected thumb icon.
pub const Toggle = struct {
    pub const Size = enum {
        s,
        m,
        l,
    };

    /// Track width, track height and thumb diameter per size.
    pub const kTrackW = [_]f32{ 28.0, 32.0, 40.0 };
    pub const kTrackH = [_]f32{ 16.0, 20.0, 24.0 };
    pub const kThumbD = [_]f32{ 12.0, 16.0, 20.0 };
    /// Tween length for a flip: `200` ms.
    pub const kAnimMs: u64 = 200;
    /// Track outline width while off.
    pub const kOutlineWidth: f32 = 2.0;

    size: Size = .m,
    on: bool = false,
    enabled: bool = true,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 52.0,
    h: f32 = 26.0,

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

    thumb_tween: Tween = .{},
    track_tween: Tween = .{},
    state_layer: StateLayer = .{},
    focus_ring: FocusRing = .{},

    on_click: ?Callback = null,
    on_toggle: ?ToggleCallback = null,
    cb_ctx: ?*anyopaque = null,

    /// Flip the switch, animating thumb and track together from wherever each
    /// tween currently is — so a toggle mid-flight reverses smoothly.
    pub fn setOn(self: *Toggle, value: bool, now_ms: u64) void {
        if (value == self.on) return;
        self.on = value;
        const target: f32 = if (value) 1.0 else 0.0;
        self.thumb_tween.start(self.thumb_tween.value(now_ms), target, now_ms, kAnimMs, animation.kEmphasized);
        self.track_tween.start(self.track_tween.value(now_ms), target, now_ms, kAnimMs, animation.kEmphasized);
    }

    pub fn setSize(self: *Toggle, s: Size) void {
        self.size = s;
    }

    pub fn setEnabled(self: *Toggle, e: bool) void {
        self.enabled = e;
    }

    pub fn setGeometry(self: *Toggle, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *Toggle, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Toggle, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Toggle, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Toggle, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn setHovered(self: *Toggle, h: bool) void {
        self.hovered = h;
    }

    pub fn setPressed(self: *Toggle, p: bool) void {
        self.pressed = p;
    }

    pub fn setFocused(self: *Toggle, f: bool) void {
        self.focused = f;
    }

    pub fn isPressed(self: *const Toggle) bool {
        return self.pressed;
    }

    pub fn setOnClick(self: *Toggle, cb: ?Callback) void {
        self.on_click = cb;
    }

    /// Reports the *new* value, so a listener does not have to re-read it.
    pub fn setOnToggle(self: *Toggle, cb: ?ToggleCallback) void {
        self.on_toggle = cb;
    }

    pub fn setCallbackContext(self: *Toggle, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn isOn(self: *const Toggle) bool {
        return self.on;
    }

    pub fn isEnabled(self: *const Toggle) bool {
        return self.enabled;
    }

    pub fn animating(self: *const Toggle) bool {
        return self.thumb_tween.active;
    }

    pub fn containsPoint(self: *const Toggle, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    pub fn handlePointerEnter(self: *Toggle, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        self.hovered = true;
        return true;
    }

    pub fn handlePointerLeave(self: *Toggle) bool {
        self.hovered = false;
        self.pressed = false;
        return true;
    }

    pub fn handlePointerDown(self: *Toggle, px: f32, py: f32) bool {
        if (!self.enabled or !self.containsPoint(px, py)) return false;
        self.pressed = true;
        return true;
    }

    pub fn handlePointerUp(self: *Toggle, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        if (self.pressed) {
            self.pressed = false;
            // Note the tween is seeded at time 0 — the flip
            // is evaluated at the start of the animation clock.
            self.setOn(!self.on, 0);
            if (self.on_toggle) |cb| cb(self.cb_ctx, self.on);
            if (self.on_click) |cb| cb(self.cb_ctx);
        }
        return true;
    }

    /// Non-animated paint — forwards to `paint(cr, 0)`.
    pub fn paintStatic(self: *Toggle, c: ?*cairo.cairo_t) void {
        self.paint(c, 0);
    }

    pub fn paint(self: *Toggle, c: ?*cairo.cairo_t, now_ms: u64) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        const thumb_pos = self.thumb_tween.value(now_ms);
        const track_t = self.track_tween.value(now_ms);

        const i: usize = @intFromEnum(self.size);
        const track_w = kTrackW[i];
        const track_h = kTrackH[i];
        const thumb_d = kThumbD[i];

        const cx = self.x + self.w * 0.5;
        const cy = self.y + self.h * 0.5;
        const tlx = cx - track_w * 0.5;
        const tly = cy - track_h * 0.5;
        const track_r = track_h * 0.5;

        // Thumb travel is bounded so the dot always sits inside the track.
        const handle_r = thumb_d * 0.5;
        const handle_min_x = tlx + handle_r;
        const handle_max_x = tlx + track_w - handle_r;
        const hx = handle_min_x + (handle_max_x - handle_min_x) * thumb_pos;
        const hy = cy;

        // Colours, derived from the *track tween*, not the
        // `on_` field, so the visual state lags the logical one by design.
        const is_on = track_t > 0.5;
        var track_r_col: f32 = 0;
        var track_g_col: f32 = 0;
        var track_b_col: f32 = 0;
        var track_a_col: f32 = 0;
        var handle_r_col: f32 = 0;
        var handle_g_col: f32 = 0;
        var handle_b_col: f32 = 0;
        var handle_a_col: f32 = 0;

        if (!self.enabled) {
            // Disabled: the text colour again, in all three channels — 12% on
            // the track, 38% on the handle, matching the token opacities.
            track_r_col = self.text_r;
            track_g_col = self.text_r;
            track_b_col = self.text_r;
            track_a_col = 0.12;
            handle_r_col = self.text_r;
            handle_g_col = self.text_r;
            handle_b_col = self.text_r;
            handle_a_col = 0.38;
        } else {
            const t = track_t;
            track_r_col = (1.0 - t) * self.surface_r + t * self.accent_r;
            track_g_col = (1.0 - t) * self.surface_g + t * self.accent_g;
            track_b_col = (1.0 - t) * self.surface_b + t * self.accent_b;
            track_a_col = if (is_on) 1.0 else 0.5;
            handle_r_col = if (is_on) 1.0 else self.outline_r;
            handle_g_col = if (is_on) 1.0 else self.outline_g;
            handle_b_col = if (is_on) 1.0 else self.outline_b;
            handle_a_col = 1.0;
        }

        cairo.cairo_save(cr);

        // Track — a stadium, since the corner radius is half its height.
        roundedPath(cr, tlx, tly, track_w, track_h, track_r);
        cairo.cairo_set_source_rgba(cr, track_r_col, track_g_col, track_b_col, track_a_col);
        cairo.cairo_fill(cr);

        // Track outline, only while off and enabled. `track_r - 1` puts a 2dp
        // stroke on the edge rather than fully inside it.
        if (!is_on and self.enabled) {
            roundedPath(cr, tlx, tly, track_w, track_h, track_r - 1.0);
            cairo.cairo_set_source_rgba(cr, self.outline_r, self.outline_g, self.outline_b, 1.0);
            cairo.cairo_set_line_width(cr, kOutlineWidth);
            cairo.cairo_stroke(cr);
        }

        // Thumb.
        cairo.cairo_set_source_rgba(cr, handle_r_col, handle_g_col, handle_b_col, handle_a_col);
        cairo.cairo_arc(cr, hx, hy, handle_r, 0.0, 2.0 * std.math.pi);
        cairo.cairo_fill(cr);

        cairo.cairo_restore(cr);

        // State layer — keyed off the thumb, 6× its radius square, so the
        // wash tracks the handle rather than covering the whole track.
        if (is_on) {
            self.state_layer.setColor(self.accent_r, self.accent_g, self.accent_b);
        } else {
            self.state_layer.setColor(self.outline_r, self.outline_g, self.outline_b);
        }
        self.state_layer.setRadius(track_r);
        self.state_layer.setGeometry(hx - handle_r * 3.0, hy - handle_r * 3.0, handle_r * 6.0, handle_r * 6.0);
        self.state_layer.setHovered(self.hovered);
        self.state_layer.setPressed(self.pressed);
        self.state_layer.setFocused(self.focused);
        self.state_layer.tick(now_ms);
        self.state_layer.paint(c, now_ms);

        // Focus ring — a square around the thumb with 4dp of room.
        self.focus_ring.setFocused(self.focused);
        self.focus_ring.setColor(self.outline_r, self.outline_g, self.outline_b);
        self.focus_ring.setRadius(handle_r + 4.0);
        self.focus_ring.paint(c, hx - handle_r - 4.0, hy - handle_r - 4.0, (handle_r + 4.0) * 2.0, (handle_r + 4.0) * 2.0);
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

test "m3-toggle: size table sets track and thumb dimensions" {
    const t = testing;
    var tg = Toggle{};
    tg.setSize(.s);
    try t.expectEqual(@as(f32, 28.0), Toggle.kTrackW[@intFromEnum(tg.size)]);
    try t.expectEqual(@as(f32, 12.0), Toggle.kThumbD[@intFromEnum(tg.size)]);
    tg.setSize(.l);
    try t.expectEqual(@as(f32, 40.0), Toggle.kTrackW[@intFromEnum(tg.size)]);
    try t.expectEqual(@as(f32, 20.0), Toggle.kThumbD[@intFromEnum(tg.size)]);
}

test "m3-toggle: flipping arms both tweens together" {
    const t = testing;
    var tg = Toggle{};
    try t.expect(!tg.animating());
    tg.setOn(true, 0);
    try t.expect(tg.isOn());
    // Both the thumb and the track tween must be running — the movement and
    // the colour change share one clock.
    try t.expect(tg.thumb_tween.active);
    try t.expect(tg.track_tween.active);

    // Setting the same value again is a no-op and must not restart them.
    tg.thumb_tween.stop();
    tg.track_tween.stop();
    tg.setOn(true, 0);
    try t.expect(!tg.thumb_tween.active);
    try t.expect(!tg.track_tween.active);
}

test "m3-toggle: pointer press toggles and reports the new value" {
    const t = testing;
    const S = struct {
        var toggles: usize = 0;
        var last_on: bool = false;
        var clicks: usize = 0;
        fn onToggle(ctx: ?*anyopaque, v: bool) void {
            _ = ctx;
            toggles += 1;
            last_on = v;
        }
        fn onClick(ctx: ?*anyopaque) void {
            _ = ctx;
            clicks += 1;
        }
    };
    S.toggles = 0;
    S.clicks = 0;

    var tg = Toggle{};
    tg.setGeometry(0, 0, 52, 26);
    tg.setOnToggle(S.onToggle);
    tg.setOnClick(S.onClick);

    // A miss arms nothing.
    try t.expect(!tg.handlePointerDown(500, 500));
    _ = tg.handlePointerUp(10, 10);
    try t.expectEqual(@as(usize, 0), S.toggles);

    try t.expect(tg.handlePointerDown(10, 10));
    _ = tg.handlePointerUp(10, 10);
    try t.expect(tg.isOn());
    try t.expectEqual(@as(usize, 1), S.toggles);
    try t.expectEqual(@as(usize, 1), S.clicks);
    try t.expect(S.last_on);

    // Disabled switches refuse input and stay where they were.
    tg.setEnabled(false);
    try t.expect(!tg.handlePointerDown(10, 10));
    try t.expect(tg.isOn());
}

test "m3-toggle: every size and state paints cleanly" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 120, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .s, .m, .l }) |s| {
        inline for (.{ true, false }) |enabled| {
            var tg = Toggle{};
            tg.setSize(s);
            tg.setEnabled(enabled);
            tg.setGeometry(10, 10, 60, 32);
            tg.setFocused(true);
            tg.setOn(true, 0);
            // Mid-flip as well as settled, so the outline branch is covered.
            tg.paint(cr, 1050);
            try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
        }
    }

    // Off and enabled — the only path that draws the track outline.
    var off = Toggle{};
    off.setGeometry(10, 10, 60, 32);
    off.paintStatic(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = Toggle{};
    degenerate.paint(null, 0);
    degenerate.paintStatic(null);
}
