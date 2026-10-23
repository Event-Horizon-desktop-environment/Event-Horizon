//! The M3 slider.
//!
//! Continuous or discrete (via `step`), with an active and inactive track, a
//! stop indicator at the track's end, a thumb that swells while dragged, an
//! optional value popup, and a `centered` variant whose thumb travels either
//! side of the middle.
//!
//! ## The value popup's glyph cache
//!
//! `drawValuePopup` carries an explicit performance note, and the
//! port keeps the whole design: the popup's text used to be re-rasterized
//! every frame with a `cairo_text_path` + 2.2px stroke + fill, costing
//! 20-45us *during drags*, which is exactly when the value changes each
//! frame. So each distinct glyph is rendered once — white fill plus dark
//! outline baked in — into its own image surface and blitted thereafter. The
//! rounded background (keyed by width) and the arrow (shape-constant, tinted
//! through a mask so the accent colour stays out of the cache key) are cached
//! the same way.
//!
//! One known delta worth repeating here: adjacent
//! glyphs' 2.2px outlines overlap, and per-glyph strokes double-darken those
//! ~1px seam columns compared to the old single combined stroke. Invisible at
//! 1x, measurable under magnification. This port preserves that.
//!
//! Caches are file-scope maps behind a spin lock, cleared wholesale past
//! their limits — file-scope maps behind a lock, since Zig has no function-local statics.

const std = @import("std");
const math = std.math;
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const state_layer_mod = @import("../../core/primitives/state_layer.zig");

pub const StateLayer = state_layer_mod.StateLayer;
pub const FocusRing = state_layer_mod.FocusRing;

pub const ValueCallback = *const fn (ctx: ?*anyopaque, value: f32) void;
pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// M3 Slider — continuous/discrete, active+inactive track, stop indicator,
/// value indicator popup, thumb press shrink, centered variant.
pub const Slider = struct {
    pub const Size = enum {
        xs,
        s,
        m,
        l,
        xl,
    };

    /// Thumb diameter and track thickness per size.
    pub const kThumbSize = [_]f32{ 16.0, 16.0, 20.0, 24.0, 24.0 };
    pub const kTrackHeight = [_]f32{ 4.0, 4.0, 4.0, 6.0, 6.0 };

    /// Stop-indicator dot radius at the end of the track.
    pub const kStopRadius: f32 = 2.0;
    /// Inactive track alpha.
    pub const kInactiveAlpha: f32 = 0.35;
    /// Thumb swell factor while dragging.
    pub const kDragScale: f32 = 1.1;
    /// Extra state-layer / focus-ring padding around the thumb.
    pub const kStatePad: f32 = 8.0;
    pub const kFocusPad: f32 = 6.0;
    /// `animateToValue`'s duration.
    pub const kAnimMs: u64 = 100;
    /// Two values closer than this are treated as equal, so no change fires.
    pub const kEpsilon: f32 = 0.0001;
    /// Scroll fallback step when `step` is zero: 5% of the range.
    pub const kScrollFrac: f32 = 0.05;

    // — value popup geometry —
    pub const kPopupH: f32 = 26.0;
    pub const kPopupR: f32 = 9.0;
    pub const kPopupMinW: f32 = 44.0;
    pub const kPopupMaxW: f32 = 180.0;
    pub const kPopupPadW: f32 = 18.0;
    /// Gap between the popup's bottom and the thumb's top.
    pub const kPopupGap: f32 = 6.0;
    pub const kPopupFont: f32 = 10.0;
    /// Stroke width baked into each cached glyph.
    pub const kPopupStroke: f32 = 2.2;
    /// Padding around a glyph in its cache surface, in dp.
    pub const kGlyphPad: i32 = 3;
    pub const kArrowW: f32 = 10.0;
    pub const kArrowH: f32 = 7.0;

    lo: f32 = 0.0,
    hi: f32 = 100.0,
    step: f32 = 1.0,
    value: f32 = 50.0,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,
    size: Size = .m,

    enabled: bool = true,
    hovered: bool = false,
    dragging: bool = false,
    /// Set by `setHovered`/`setPressed`, so the *caller's* intent wins over
    /// the internally derived hover/drag state.
    force_hover: bool = false,
    force_pressed: bool = false,
    centered: bool = false,
    show_value_label: bool = false,
    focused: bool = false,
    value_label: []const u8 = "",
    grab_offset_x: f32 = 0.0,

    anim_start_ms: u64 = 0,
    anim_from: f32 = 0.0,
    anim_to: f32 = 0.0,
    anim_duration_ms: u64 = 0,

    accent_r: f32 = 0.769,
    accent_g: f32 = 0.659,
    accent_b: f32 = 0.941,
    surface_r: f32 = 0.102,
    surface_g: f32 = 0.075,
    surface_b: f32 = 0.188,
    text_r: f32 = 1.0,
    text_g: f32 = 1.0,
    text_b: f32 = 1.0,

    state_layer: StateLayer = .{},
    focus_ring: FocusRing = .{},

    on_value_changed: ?ValueCallback = null,
    on_drag_started: ?Callback = null,
    on_drag_finished: ?Callback = null,
    cb_ctx: ?*anyopaque = null,

    // ——— configuration ———

    /// Replaces the range, swapping the bounds if they arrive reversed, then
    /// re-snaps the current value into the new range.
    pub fn setRange(self: *Slider, low: f32, high: f32) void {
        var a = low;
        var b = high;
        if (b < a) {
            const tmp = a;
            a = b;
            b = tmp;
        }
        self.lo = a;
        self.hi = b;
        self.applyValue(self.value);
    }

    /// A negative step is treated as zero, i.e. continuous.
    pub fn setStep(self: *Slider, s: f32) void {
        self.step = @max(s, 0.0);
        self.applyValue(self.value);
    }

    /// Jumps immediately — zeroing the animation duration first so the
    /// value is never interpolated.
    pub fn setValue(self: *Slider, val: f32) void {
        self.anim_duration_ms = 0;
        self.applyValue(val);
    }

    /// Tweens toward `val` over `kAnimMs`, unless already dragging or the
    /// change is below `kEpsilon`, in which case it snaps.
    pub fn animateToValue(self: *Slider, val: f32, now_ms: u64) void {
        if (self.dragging or @abs(val - self.value) < kEpsilon) {
            self.applyValue(val);
            return;
        }
        self.anim_from = self.value;
        self.anim_to = self.snap(val);
        self.anim_start_ms = now_ms;
        self.anim_duration_ms = kAnimMs;
    }

    pub fn setSize(self: *Slider, s: Size) void {
        self.size = s;
    }

    /// Disabling also clears hover and drag.
    pub fn setEnabled(self: *Slider, e: bool) void {
        self.enabled = e;
        if (!e) {
            self.hovered = false;
            self.dragging = false;
        }
    }

    pub fn setGeometry(self: *Slider, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    /// Marks hover as externally driven from here on.
    pub fn setHovered(self: *Slider, h: bool) void {
        self.force_hover = true;
        self.hovered = h;
    }

    /// Marks press as externally driven, and mirrors it into `dragging`.
    pub fn setPressed(self: *Slider, p: bool) void {
        self.force_pressed = true;
        self.dragging = p;
    }

    pub fn setFocused(self: *Slider, f: bool) void {
        self.focused = f;
    }

    /// The zero-centred variant: the thumb travels either side of the middle.
    pub fn setCentered(self: *Slider, c: bool) void {
        self.centered = c;
    }

    pub fn setShowValueLabel(self: *Slider, s: bool) void {
        self.show_value_label = s;
    }

    pub fn setValueLabel(self: *Slider, text: []const u8) void {
        self.value_label = text;
    }

    pub fn setAccentColor(self: *Slider, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Slider, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Slider, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOnValueChanged(self: *Slider, cb: ?ValueCallback) void {
        self.on_value_changed = cb;
    }

    pub fn setOnDragStarted(self: *Slider, cb: ?Callback) void {
        self.on_drag_started = cb;
    }

    pub fn setOnDragFinished(self: *Slider, cb: ?Callback) void {
        self.on_drag_finished = cb;
    }

    pub fn setCallbackContext(self: *Slider, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn currentValue(self: *const Slider) f32 {
        return self.value;
    }

    pub fn minValue(self: *const Slider) f32 {
        return self.lo;
    }

    pub fn maxValue(self: *const Slider) f32 {
        return self.hi;
    }

    pub fn isEnabled(self: *const Slider) bool {
        return self.enabled;
    }

    pub fn isDragging(self: *const Slider) bool {
        return self.dragging;
    }

    pub fn xPos(self: *const Slider) f32 {
        return self.x;
    }

    pub fn yPos(self: *const Slider) f32 {
        return self.y;
    }

    pub fn width(self: *const Slider) f32 {
        return self.w;
    }

    pub fn height(self: *const Slider) f32 {
        return self.h;
    }

    pub fn isAnimating(self: *const Slider) bool {
        return self.anim_duration_ms > 0;
    }

    /// The value the slider is currently displaying, interpolating between
    /// `anim_from` and `anim_to` with an ease-out cubic while an animation
    /// is in flight.
    ///
    /// This uses its own cubic rather than the `m3/tokens/motion` curves —
    /// hand-rolled `1 - (1-t)³` instead of going through
    /// `evaluateEasing`, so the port does too.
    pub fn animatedValue(self: *const Slider, now_ms: u64) f32 {
        if (self.anim_duration_ms == 0) return self.value;
        const elapsed = now_ms - self.anim_start_ms;
        if (elapsed >= self.anim_duration_ms) return self.anim_to;
        const t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.anim_duration_ms));
        const ease = 1.0 - std.math.pow(f32, 1.0 - t, 3.0);
        return self.anim_from + (self.anim_to - self.anim_from) * ease;
    }

    /// Position along the track from 0..1, clamped.
    fn normalized(self: *const Slider) f32 {
        if (self.hi <= self.lo) return 0.0;
        return std.math.clamp((self.value - self.lo) / (self.hi - self.lo), 0.0, 1.0);
    }

    /// The same mapping for the centered variant, giving -1..+1.
    fn normalizedCentered(self: *const Slider) f32 {
        if (self.hi <= self.lo) return 0.0;
        const n = (self.value - self.lo) / (self.hi - self.lo);
        return n * 2.0 - 1.0;
    }

    /// The track starts half a thumb in, so the thumb never overhangs.
    fn trackLeft(self: *const Slider) f32 {
        const ts = kThumbSize[@intFromEnum(self.size)] * 0.5;
        return self.x + ts;
    }

    fn trackWidth(self: *const Slider) f32 {
        const ts = kThumbSize[@intFromEnum(self.size)];
        return @max(0.0, self.w - ts);
    }

    /// The thumb's centre x, from the current value.
    fn thumbCenter(self: *const Slider) f32 {
        if (self.centered) {
            return self.trackLeft() + (self.normalizedCentered() * 0.5 + 0.5) * self.trackWidth();
        }
        return self.trackLeft() + self.normalized() * self.trackWidth();
    }

    /// Clamp to the range, then round to the nearest whole step.
    fn snap(self: *const Slider, val: f32) f32 {
        const clamped = math.clamp(val, self.lo, self.hi);
        if (self.step <= 0.0 or self.hi <= self.lo) return clamped;
        const steps = @round((clamped - self.lo) / self.step);
        return math.clamp(self.lo + steps * self.step, self.lo, self.hi);
    }

    /// Snaps, stores, and notifies — but only if the value actually moved.
    fn applyValue(self: *Slider, raw: f32) void {
        const snapped = self.snap(raw);
        if (@abs(snapped - self.value) < kEpsilon) return;
        self.value = snapped;
        if (self.on_value_changed) |cb| cb(self.cb_ctx, self.value);
    }

    // ——— input ———

    pub fn containsPoint(self: *const Slider, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    /// Distance from a point to the thumb centre — kept so a caller can apply
    /// its own drag threshold.
    pub fn grabOffset(self: *const Slider, px: f32) f32 {
        return px - self.thumbCenter();
    }

    pub fn handlePointerEnter(self: *Slider, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        self.hovered = true;
        return true;
    }

    pub fn handlePointerLeave(self: *Slider) bool {
        self.hovered = false;
        return true;
    }

    pub fn handlePointerDown(self: *Slider, px: f32, py: f32) bool {
        if (!self.enabled or !self.containsPoint(px, py)) return false;
        self.anim_duration_ms = 0;
        self.dragging = true;
        // Grab offset keeps the thumb under the pointer rather than snapping
        // its *centre* to the click.
        self.grab_offset_x = self.grabOffset(px);
        self.applyValue(self.lo + ((px - self.grab_offset_x - self.trackLeft()) / self.trackWidth()) * (self.hi - self.lo));
        if (self.on_drag_started) |cb| cb(self.cb_ctx);
        return true;
    }

    pub fn handlePointerMove(self: *Slider, px: f32, py: f32) bool {
        _ = py;
        if (!self.enabled or !self.dragging) return false;
        self.applyValue(self.lo + ((px - self.grab_offset_x - self.trackLeft()) / self.trackWidth()) * (self.hi - self.lo));
        return true;
    }

    pub fn handlePointerUp(self: *Slider, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled or !self.dragging) return false;
        self.dragging = false;
        if (self.on_drag_finished) |cb| cb(self.cb_ctx);
        return true;
    }

    /// A positive delta lowers the value (scroll-down decreases).
    pub fn handleScroll(self: *Slider, delta: f32) bool {
        if (!self.enabled) return false;
        const adj: f32 = if (self.step > 0.0) self.step else (self.hi - self.lo) * kScrollFrac;
        self.applyValue(self.value - delta * adj);
        return true;
    }

    // ——— rendering ———

    /// Non-animated paint — forwards at time 0 through the mutating body.
    pub fn paintStatic(self: *const Slider, c: ?*cairo.cairo_t) void {
        const mutable: *Slider = @constCast(self);
        mutable.paint(c, 0);
    }

    pub fn paint(self: *Slider, c: ?*cairo.cairo_t, now_ms: u64) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        // Hover derives from drag unless the caller forced hover explicitly.
        const is_hov = if (self.force_hover) self.hovered else (self.hovered or self.dragging);
        // Both branches test `dragging_`; the flag only
        // records that a caller took control.
        const is_drag = self.dragging;
        _ = self.force_pressed;

        const pv = self.animatedValue(now_ms);

        const si: usize = @intFromEnum(self.size);
        const thumb_size = kThumbSize[si];
        const track_h = kTrackHeight[si];
        const tl = self.trackLeft();
        const tw = self.trackWidth();
        const ty = self.y + self.h * 0.5;
        const alpha: f32 = if (self.enabled) 1.0 else 0.38;

        // The centered variant maps the animated value directly; the plain
        // one uses the clamped normalisation. Both are derived from `pv` so
        // the animation is actually visible — `thumbCenter()` reads the
        // settled `value` instead, which is what pointer math wants.
        const t_norm: f32 = if (self.hi <= self.lo) 0.0 else std.math.clamp((pv - self.lo) / (self.hi - self.lo), 0.0, 1.0);
        const tc: f32 = if (self.centered)
            tl + (t_norm * 2.0 - 1.0) * 0.5 * tw + tw * 0.5
        else
            tl + t_norm * tw;

        cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);

        // Inactive track — the full run.
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, alpha * kInactiveAlpha);
        cairo.cairo_set_line_width(cr, track_h);
        cairo.cairo_move_to(cr, tl, ty);
        cairo.cairo_line_to(cr, tl + tw, ty);
        cairo.cairo_stroke(cr);

        // Active track — up to the thumb.
        cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, alpha);
        cairo.cairo_set_line_width(cr, track_h);
        cairo.cairo_move_to(cr, tl, ty);
        cairo.cairo_line_to(cr, tc, ty);
        cairo.cairo_stroke(cr);

        if (self.enabled) self.drawStopIndicator(cr, tl, tw, ty);

        // Thumb — swells by 10% while dragging.
        const ts: f32 = if (is_drag) thumb_size * kDragScale else thumb_size;
        const thumb_r = ts * 0.5;

        // State layer around the thumb, 8dp out on each side.
        self.state_layer.setColor(self.accent_r, self.accent_g, self.accent_b);
        self.state_layer.setRadius(thumb_r + kStatePad);
        self.state_layer.setGeometry(tc - thumb_r - kStatePad, ty - thumb_r - kStatePad, ts + kStatePad * 2.0, ts + kStatePad * 2.0);
        self.state_layer.setHovered(is_hov);
        self.state_layer.setPressed(is_drag);
        self.state_layer.tick(now_ms);
        self.state_layer.paint(c, now_ms);

        cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, alpha);
        cairo.cairo_arc(cr, tc, ty, thumb_r, 0.0, 2.0 * math.pi);
        cairo.cairo_fill(cr);

        // Only the drag state shows the value popup.
        if (self.show_value_label and is_drag) self.drawValuePopup(cr, tc, ty, alpha);

        // Focus ring around the thumb.
        self.focus_ring.setFocused(self.focused);
        self.focus_ring.setColor(self.accent_r, self.accent_g, self.accent_b);
        self.focus_ring.setRadius(thumb_r + kFocusPad);
        self.focus_ring.paint(c, tc - thumb_r - kFocusPad, ty - thumb_r - kFocusPad, (thumb_r + kFocusPad) * 2.0, (thumb_r + kFocusPad) * 2.0);
    }

    /// A small dot marking the end of the track.
    fn drawStopIndicator(self: *const Slider, c: ?*cairo.cairo_t, tl: f32, tw: f32, ty: f32) void {
        cairo.cairo_set_source_rgba(c, self.surface_r, self.surface_g, self.surface_b, 0.6);
        cairo.cairo_arc(c, tl + tw, ty, kStopRadius, 0.0, 2.0 * math.pi);
        cairo.cairo_fill(c);
    }

    fn drawValuePopup(self: *const Slider, c: ?*cairo.cairo_t, tc: f32, ty: f32, alpha: f32) void {
        const cr = c orelse return;
        if (self.value_label.len == 0) return;

        // The transform's scale tells us the effective device scale, so the
        // cache surfaces are rastered at the right density once rather than
        // per frame.
        var ctm: cairo.cairo_matrix_t = undefined;
        cairo.cairo_get_matrix(cr, &ctm);
        var ds = @abs(ctm.xx) + @abs(ctm.xy);
        if (!(ds > 0.0) or !math.isFinite(ds)) ds = 1.0;
        const ds_q: i64 = @intFromFloat(@round(ds * 128.0));
        const alpha_q: i32 = math.clamp(@as(i32, @intFromFloat(@round(alpha * 255.0))), 0, 255);

        // Total advance from cached (or freshly measured) per-glyph advances.
        // Toy-font text has no kerning, so summing advances equals the
        // whole-string advance.
        var total_adv: f32 = 0.0;
        {
            var it = Utf8Iter{ .bytes = self.value_label };
            while (it.next()) |cp| {
                const gkey = glyphKey(cp, ds_q, alpha_q);
                lockCache();
                const hit = glyph_cache.get(gkey);
                unlockCache();
                if (hit) |e| {
                    total_adv += e.adv;
                    continue;
                }
                // Cold glyph: measure with the same toy-font calls the old
                // path used, then bake fill + outline into a surface once.
                const e = renderGlyph(cr, cp, ds, alpha, alpha_q) orelse continue;
                total_adv += e.adv;
                lockCache();
                if (glyph_cache.count() >= 256) clearGlyphsLocked();
                glyph_cache.put(std.heap.c_allocator, gkey, e) catch {};
                unlockCache();
            }
        }

        const popup_w = math.clamp(total_adv + kPopupPadW, kPopupMinW, kPopupMaxW);
        const popup_h = kPopupH;

        // Clamp the popup inside the slider, unless it is wider than the
        // slider entirely — then pin it to the left edge.
        var popup_x = tc - popup_w * 0.5;
        if (popup_w <= self.w) {
            popup_x = math.clamp(popup_x, self.x, self.x + self.w - popup_w);
        } else {
            popup_x = self.x;
        }
        const thumb_r = kThumbSize[@intFromEnum(self.size)] * 0.5;
        const popup_y = ty - popup_h - kPopupGap - thumb_r;

        // Background: a cached rounded rect keyed by width + accent + alpha.
        {
            const pw_q: i64 = @intFromFloat(@round(popup_w * 64.0));
            const ac_r: i64 = math.clamp(@as(i64, @intFromFloat(@round(self.accent_r * 255.0))), 0, 255);
            const ac_g: i64 = math.clamp(@as(i64, @intFromFloat(@round(self.accent_g * 255.0))), 0, 255);
            const ac_b: i64 = math.clamp(@as(i64, @intFromFloat(@round(self.accent_b * 255.0))), 0, 255);
            const bkey: u64 = @bitCast(
                (@as(u64, @intCast(pw_q)) << 40) |
                    (@as(u64, @intCast(ac_r)) << 32) |
                    (@as(u64, @intCast(ac_g)) << 24) |
                    (@as(u64, @intCast(ac_b)) << 16) |
                    (@as(u64, @intCast(@as(u32, @intCast(alpha_q)))) << 8) |
                    @as(u64, @intCast(@as(u32, @intCast(@rem(ds_q, 256))))),
            );

            lockCache();
            var entry = bg_cache.get(bkey);
            unlockCache();

            if (entry == null) {
                const bsw: c_int = @max(1, @as(c_int, @intFromFloat(@ceil(popup_w * ds))));
                const bsh: c_int = @max(1, @as(c_int, @intFromFloat(@ceil(popup_h * ds))));
                if (cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, bsw, bsh)) |surf| {
                    const tmp = cairo.cairo_create(surf);
                    // Clear first so the surface starts fully transparent,
                    // then work in OVER.
                    cairo.cairo_set_operator(tmp, cairo.CAIRO_OPERATOR_CLEAR);
                    cairo.cairo_paint(tmp);
                    cairo.cairo_set_operator(tmp, cairo.CAIRO_OPERATOR_OVER);
                    cairo.cairo_scale(tmp, ds, ds);
                    cairo.cairo_new_path(tmp);
                    cairo.cairo_arc(tmp, kPopupR, kPopupR, kPopupR, math.pi, 1.5 * math.pi);
                    cairo.cairo_arc(tmp, popup_w - kPopupR, kPopupR, kPopupR, 1.5 * math.pi, 2.0 * math.pi);
                    cairo.cairo_arc(tmp, popup_w - kPopupR, popup_h - kPopupR, kPopupR, 0.0, 0.5 * math.pi);
                    cairo.cairo_arc(tmp, kPopupR, popup_h - kPopupR, kPopupR, 0.5 * math.pi, math.pi);
                    cairo.cairo_close_path(tmp);
                    cairo.cairo_set_source_rgba(tmp, self.accent_r, self.accent_g, self.accent_b, alpha * 0.96);
                    cairo.cairo_fill(tmp);
                    cairo.cairo_destroy(tmp);
                    entry = .{ .surf = surf, .sw = bsw, .sh = bsh };
                    lockCache();
                    if (bg_cache.count() >= 32) clearBgsLocked();
                    bg_cache.put(std.heap.c_allocator, bkey, entry.?) catch {};
                    unlockCache();
                }
            }

            if (entry) |e| {
                cairo.cairo_save(cr);
                cairo.cairo_translate(cr, popup_x, popup_y);
                cairo.cairo_scale(cr, 1.0 / ds, 1.0 / ds);
                cairo.cairo_set_source_surface(cr, e.surf, 0, 0);
                cairo.cairo_rectangle(cr, 0, 0, @floatFromInt(e.sw), @floatFromInt(e.sh));
                cairo.cairo_fill(cr);
                cairo.cairo_restore(cr);
            }
        }

        // Arrow — shape-constant, tinted through a mask so the accent colour
        // stays out of its cache key.
        {
            const asw: c_int = @max(1, @as(c_int, @intFromFloat(@ceil(kArrowW * ds))));
            const ash: c_int = @max(1, @as(c_int, @intFromFloat(@ceil(kArrowH * ds))));
            lockCache();
            const need_rebuild = (arrow_surf == null) or (arrow_ds_q != ds_q) or (arrow_sw != asw) or (arrow_sh != ash);
            unlockCache();

            if (need_rebuild) {
                lockCache();
                if (arrow_surf) |old| cairo.cairo_surface_destroy(old);
                arrow_surf = null;
                unlockCache();

                if (cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, asw, ash)) |surf| {
                    const tmp = cairo.cairo_create(surf);
                    cairo.cairo_set_operator(tmp, cairo.CAIRO_OPERATOR_CLEAR);
                    cairo.cairo_paint(tmp);
                    cairo.cairo_set_operator(tmp, cairo.CAIRO_OPERATOR_OVER);
                    cairo.cairo_scale(tmp, ds, ds);
                    cairo.cairo_move_to(tmp, 0, 0);
                    cairo.cairo_line_to(tmp, kArrowW, 0);
                    cairo.cairo_line_to(tmp, kArrowW * 0.5, kArrowH);
                    cairo.cairo_close_path(tmp);
                    cairo.cairo_set_source_rgba(tmp, 1, 1, 1, 1);
                    cairo.cairo_fill(tmp);
                    cairo.cairo_destroy(tmp);
                    lockCache();
                    arrow_surf = surf;
                    arrow_ds_q = ds_q;
                    arrow_sw = asw;
                    arrow_sh = ash;
                    unlockCache();
                }
            }

            lockCache();
            const drawn_arrow = arrow_surf;
            unlockCache();
            if (drawn_arrow) |arrow| {
                cairo.cairo_save(cr);
                cairo.cairo_translate(cr, tc - kArrowW * 0.5, popup_y + popup_h);
                cairo.cairo_scale(cr, 1.0 / ds, 1.0 / ds);
                cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, alpha * 0.96);
                cairo.cairo_mask_surface(cr, arrow, 0, 0);
                cairo.cairo_restore(cr);
            }
        }

        // Text: blit the cached glyphs along the baseline, at the same
        // positions `cairo_text_path` would have laid them out.
        {
            const text_x = popup_x + (popup_w - total_adv) * 0.5;
            const text_y = popup_y + popup_h * 0.5 + 4.0;
            var cur = text_x;
            var it = Utf8Iter{ .bytes = self.value_label };
            while (it.next()) |cp| {
                const gkey = glyphKey(cp, ds_q, alpha_q);
                lockCache();
                const hit = glyph_cache.get(gkey);
                unlockCache();
                const e = hit orelse break;

                cairo.cairo_save(cr);
                cairo.cairo_translate(cr, cur + e.xb - @as(f32, @floatFromInt(kGlyphPad)), text_y + e.yb - @as(f32, @floatFromInt(kGlyphPad)));
                cairo.cairo_scale(cr, 1.0 / ds, 1.0 / ds);
                cairo.cairo_set_source_surface(cr, e.surf, 0, 0);
                cairo.cairo_rectangle(cr, 0, 0, @floatFromInt(e.sw), @floatFromInt(e.sh));
                cairo.cairo_fill(cr);
                cairo.cairo_restore(cr);
                cur += e.adv;
            }
        }
    }
};

// ————— popup glyph cache —————

/// One rastered glyph: its surface, pixel size, x advance, and the bearing
/// offsets needed to place it on the baseline.
const GlyphEntry = struct {
    surf: ?*cairo.cairo_surface_t,
    sw: c_int,
    sh: c_int,
    adv: f32,
    xb: f32,
    yb: f32,
};

const BgEntry = struct {
    surf: ?*cairo.cairo_surface_t,
    sw: c_int,
    sh: c_int,
};

var cache_mu: std.atomic.Mutex = .unlocked;
var glyph_cache: std.AutoHashMapUnmanaged(u64, GlyphEntry) = .empty;
var bg_cache: std.AutoHashMapUnmanaged(u64, BgEntry) = .empty;
var arrow_surf: ?*cairo.cairo_surface_t = null;
var arrow_ds_q: i64 = 0;
var arrow_sw: c_int = 0;
var arrow_sh: c_int = 0;

fn lockCache() void {
    while (!cache_mu.tryLock()) std.atomic.spinLoopHint();
}

fn unlockCache() void {
    cache_mu.unlock();
}

fn clearGlyphsLocked() void {
    var it = glyph_cache.valueIterator();
    while (it.next()) |e| {
        if (e.surf) |s| cairo.cairo_surface_destroy(s);
    }
    glyph_cache.clearRetainingCapacity();
}

fn clearBgsLocked() void {
    var it = bg_cache.valueIterator();
    while (it.next()) |e| {
        if (e.surf) |s| cairo.cairo_surface_destroy(s);
    }
    bg_cache.clearRetainingCapacity();
}

/// Drop every cached popup surface. Tests call this so a run cannot leak.
pub fn deinitPopupCache() void {
    lockCache();
    defer unlockCache();
    clearGlyphsLocked();
    clearBgsLocked();
    if (arrow_surf) |s| cairo.cairo_surface_destroy(s);
    arrow_surf = null;
    arrow_sw = 0;
    arrow_sh = 0;
}

/// Cache key: code point, device scale (quantised to 1/128) and alpha — the
/// three things that change a glyph's rasterized appearance.
fn glyphKey(cp: u21, ds_q: i64, alpha_q: i32) u64 {
    return (@as(u64, cp) << 24) |
        (@as(u64, @intCast(@as(u32, @intCast(@rem(ds_q, 65536))))) << 8) |
        @as(u64, @intCast(@as(u32, @intCast(@rem(alpha_q, 256)))));
}

/// Raster one glyph at 10pt bold "Sans" with the outline baked in, exactly
/// as the old per-frame path drew it.
fn renderGlyph(
    cr: ?*cairo.cairo_t,
    cp: u21,
    ds: f64,
    alpha: f32,
    alpha_q: i32,
) ?GlyphEntry {
    _ = alpha_q;
    // Measure a one-code-point string with the same toy-font calls,
    // so the advance matches the pre-cache path exactly.
    var buf: [8:0]u8 = @as([8:0]u8, @splat(0));
    const len = std.unicode.utf8Encode(cp, &buf) catch return null;
    buf[len] = 0;

    cairo.cairo_select_font_face(cr, "Sans", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
    cairo.cairo_set_font_size(cr, Slider.kPopupFont);
    var te: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(cr, &buf, &te);

    const adv: f32 = @floatCast(te.x_advance);
    const xb: f32 = @floatCast(te.x_bearing);
    const yb: f32 = @floatCast(te.y_bearing);

    const gsw: c_int = @max(1, @as(c_int, @intFromFloat(@ceil((te.width + 2.0 * @as(f64, @floatFromInt(Slider.kGlyphPad))) * ds))));
    const gsh: c_int = @max(1, @as(c_int, @intFromFloat(@ceil((te.height + 2.0 * @as(f64, @floatFromInt(Slider.kGlyphPad))) * ds))));

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, gsw, gsh);
    const tmp = cairo.cairo_create(surf);

    cairo.cairo_set_operator(tmp, cairo.CAIRO_OPERATOR_CLEAR);
    cairo.cairo_paint(tmp);
    cairo.cairo_set_operator(tmp, cairo.CAIRO_OPERATOR_OVER);
    cairo.cairo_scale(tmp, ds, ds);
    cairo.cairo_translate(tmp, @as(f64, @floatFromInt(Slider.kGlyphPad)) - te.x_bearing, @as(f64, @floatFromInt(Slider.kGlyphPad)) - te.y_bearing);
    cairo.cairo_select_font_face(tmp, "Sans", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
    cairo.cairo_set_font_size(tmp, Slider.kPopupFont);
    cairo.cairo_new_path(tmp);
    cairo.cairo_move_to(tmp, 0, 0);
    cairo.cairo_text_path(tmp, &buf);

    // Dark outline first, preserved, then the white fill on top.
    cairo.cairo_set_line_width(tmp, Slider.kPopupStroke);
    cairo.cairo_set_line_join(tmp, cairo.CAIRO_LINE_JOIN_ROUND);
    cairo.cairo_set_line_cap(tmp, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_source_rgba(tmp, 0.0, 0.0, 0.0, alpha * 0.9);
    cairo.cairo_stroke_preserve(tmp);
    cairo.cairo_set_source_rgba(tmp, 1.0, 1.0, 1.0, alpha);
    cairo.cairo_fill(tmp);
    cairo.cairo_destroy(tmp);

    return .{ .surf = surf, .sw = gsw, .sh = gsh, .adv = adv, .xb = xb, .yb = yb };
}

/// Decodes one UTF-8 code point at a time, substituting U+FFFD for invalid
/// input.
const Utf8Iter = struct {
    bytes: []const u8,
    i: usize = 0,

    fn next(self: *Utf8Iter) ?u21 {
        if (self.i >= self.bytes.len) return null;
        const b0 = self.bytes[self.i];
        if (b0 == 0) return null;
        const len = std.unicode.utf8ByteSequenceLength(b0) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + len > self.bytes.len) {
            self.i = self.bytes.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.i .. self.i + len]) catch {
            self.i += len;
            return 0xFFFD;
        };
        self.i += len;
        return cp;
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-slider: setRange swaps reversed bounds and re-snaps the value" {
    const t = testing;
    var s = Slider{};
    s.setValue(50);
    // Reversed bounds come back the right way round.
    s.setRange(100, 0);
    try t.expectEqual(@as(f32, 0.0), s.minValue());
    try t.expectEqual(@as(f32, 100.0), s.maxValue());

    // A value outside the new range is pulled in by the re-snap.
    s.setRange(60, 80);
    try t.expect(s.currentValue() >= 60.0 and s.currentValue() <= 80.0);
}

test "m3-slider: discrete values snap to the nearest step" {
    const t = testing;
    var s = Slider{};
    s.setRange(0, 10);
    s.setStep(2.5);
    s.setValue(3.7);
    // 3.7 / 2.5 = 1.48, which rounds to one step => 2.5.
    try t.expectEqual(@as(f32, 2.5), s.currentValue());
    s.setValue(4.0);
    // 4.0 / 2.5 = 1.6, which rounds to two steps => 5.0.
    try t.expectEqual(@as(f32, 5.0), s.currentValue());

    // A zero step means continuous — no rounding at all.
    s.setStep(0);
    s.setValue(3.7);
    try t.expectApproxEqAbs(@as(f32, 3.7), s.currentValue(), 1e-4);
}

test "m3-slider: normalized mapping and the centered variant" {
    const t = testing;
    var s = Slider{};
    s.setRange(0, 100);
    s.setValue(50);
    try t.expectEqual(@as(f32, 0.5), s.normalized());
    s.setValue(0);
    try t.expectEqual(@as(f32, 0.0), s.normalized());
    // The centered mapping turns 0..1 into -1..+1.
    s.setValue(50);
    try t.expectApproxEqAbs(@as(f32, 0.0), s.normalizedCentered(), 1e-6);
    s.setValue(100);
    try t.expectApproxEqAbs(@as(f32, 1.0), s.normalizedCentered(), 1e-6);

    // A degenerate range (hi <= lo) normalizes to zero rather than dividing.
    var flat = Slider{};
    flat.setRange(5, 5);
    try t.expectEqual(@as(f32, 0.0), flat.normalized());
}

test "m3-slider: animateToValue eases, and dragging snaps instead" {
    const t = testing;
    var s = Slider{};
    s.setRange(0, 100);
    s.setValue(0);

    s.animateToValue(100, 1000);
    try t.expect(s.isAnimating());
    // Partway through the 100ms window it must be strictly between the ends,
    // and the ease-out cubic is above the linear midpoint.
    const mid = s.animatedValue(1050);
    try t.expect(mid > 0.0 and mid < 100.0);
    // At or past the end it settles on the target.
    try t.expectEqual(@as(f32, 100.0), s.animatedValue(1100));

    // A drag must never animate — the value tracks the pointer.
    var d = Slider{};
    d.setRange(0, 100);
    d.setValue(10);
    d.setGeometry(0, 0, 200, 40);
    try t.expect(d.handlePointerDown(20, 20));
    try t.expect(d.isDragging());
    d.animateToValue(90, 2000);
    try t.expect(!d.isAnimating());
}

test "m3-slider: dragging tracks the pointer and keeps the grab offset" {
    const t = testing;
    const S = struct {
        var changes: usize = 0;
        var starts: usize = 0;
        var finishes: usize = 0;
        var last: f32 = -1;
        fn onValue(ctx: ?*anyopaque, v: f32) void {
            _ = ctx;
            changes += 1;
            last = v;
        }
        fn onStart(ctx: ?*anyopaque) void {
            _ = ctx;
            starts += 1;
        }
        fn onFinish(ctx: ?*anyopaque) void {
            _ = ctx;
            finishes += 1;
        }
    };
    S.changes = 0;
    S.starts = 0;
    S.finishes = 0;

    var s = Slider{};
    s.setRange(0, 100);
    s.setValue(50);
    s.setSize(.m);
    s.setGeometry(0, 0, 100, 40);
    s.setOnValueChanged(S.onValue);
    s.setOnDragStarted(S.onStart);
    s.setOnDragFinished(S.onFinish);

    // Thumb size for M is 20, so the track runs 10..90 and the thumb starts
    // at 50 — exactly the midpoint.
    try t.expectApproxEqAbs(@as(f32, 50.0), s.thumbCenter(), 1e-3);

    // Pressing at the thumb keeps it under the pointer rather than snapping
    // the centre to the click.
    try t.expect(s.handlePointerDown(50, 20));
    try t.expectEqual(@as(usize, 1), S.starts);
    try t.expectApproxEqAbs(@as(f32, 50.0), s.currentValue(), 1e-3);

    // Dragging left by 20 moves the value down by a corresponding amount, and
    // that is the *only* change so far: the press landed exactly on the
    // existing value, so it notified nothing.
    _ = s.handlePointerMove(30, 20);
    try t.expect(s.currentValue() < 50.0);
    try t.expectEqual(@as(usize, 1), S.changes);

    try t.expect(s.handlePointerUp(30, 20));
    try t.expectEqual(@as(usize, 1), S.finishes);
    try t.expect(!s.isDragging());

    // A pointer outside the slider arms nothing at all.
    var fresh = Slider{};
    fresh.setGeometry(0, 0, 100, 40);
    try t.expect(!fresh.handlePointerDown(500, 500));
    try t.expect(!fresh.handlePointerMove(500, 500));
    try t.expect(!fresh.handlePointerUp(500, 500));
}

test "m3-slider: scroll steps by the step, or 5% of the range when continuous" {
    const t = testing;
    var s = Slider{};
    s.setRange(0, 100);
    s.setValue(50);
    s.setStep(10);
    _ = s.handleScroll(1);
    try t.expectEqual(@as(f32, 40.0), s.currentValue());

    // Continuous: the fallback is 5% of the range per notch.
    var c = Slider{};
    c.setRange(0, 100);
    c.setValue(50);
    c.setStep(0);
    _ = c.handleScroll(1);
    try t.expectApproxEqAbs(@as(f32, 45.0), c.currentValue(), 1e-4);

    // Disabled sliders ignore scroll entirely.
    c.setEnabled(false);
    _ = c.handleScroll(1);
    try t.expectApproxEqAbs(@as(f32, 45.0), c.currentValue(), 1e-4);
}

test "m3-slider: paints every size, centered, dragging and disabled" {
    const t = testing;
    defer deinitPopupCache();
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 260, 80);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .xs, .s, .m, .l, .xl }) |sz| {
        var s = Slider{};
        s.setSize(sz);
        s.setGeometry(10, 10, 240, 40);
        s.setShowValueLabel(true);
        s.setValueLabel("50 nits");
        s.setValue(50);
        s.paint(cr, 0);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // Centered, dragging (which arms the value popup), and focused.
    var mid = Slider{};
    mid.setCentered(true);
    mid.setGeometry(10, 10, 240, 40);
    mid.setValue(50);
    mid.setFocused(true);
    mid.paintStatic(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    var dragged = Slider{};
    dragged.setGeometry(10, 10, 240, 40);
    dragged.setShowValueLabel(true);
    dragged.setValueLabel("72 nits");
    dragged.setValue(72);
    try t.expect(dragged.handlePointerDown(60, 20));
    // Mid-drag is exactly when the popup renders, so the glyph cache path is
    // exercised here rather than only by a settled slider.
    dragged.paint(cr, 1000);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    _ = dragged.handlePointerUp(60, 20);

    // Repeated paints must reuse the cache without error.
    dragged.paint(cr, 1001);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Disabled dims both tracks and skips the stop indicator.
    var off = Slider{};
    off.setEnabled(false);
    off.setGeometry(10, 10, 240, 40);
    off.paint(cr, 0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = Slider{};
    degenerate.paintStatic(null);
    degenerate.paint(null, 0);
}

test "m3-slider: utf8 iterator decodes and survives bad input" {
    const t = testing;
    var it = Utf8Iter{ .bytes = "50 \xc3\xb0 nits" };
    var cps = std.ArrayList(u21).empty;
    defer cps.deinit(testing.allocator);
    while (it.next()) |cp| try cps.append(testing.allocator, cp);
    // '5', '0', ' ', U+0xF0, ' ', 'n','i','t','s'
    try t.expectEqual(@as(usize, 9), cps.items.len);
    try t.expectEqual(@as(u21, 0xF0), cps.items[3]);

    // A truncated sequence yields U+FFFD rather than looping or panicking,
    // and the iterator is exhausted immediately after.
    var bad = Utf8Iter{ .bytes = "\xc3" };
    try t.expectEqual(@as(u21, 0xFFFD), bad.next() orelse return error.TestUnexpectedResult);
    try t.expect(bad.next() == null);
}
