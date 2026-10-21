//! The M3 chip, in four variants.
//!
//! Assist, Filter, Input and Suggestion. Only Filter toggles: a press flips
//! `selected` and reports the new value through `onToggle`, while the other
//! three just fire `on_click`. The Input variant is also the only one that
//! draws an outline.
//!
//! Layout runs left to right from `kPad`: an optional leading icon, the
//! label, an optional trailing icon, then an optional close icon rightmost.
//! Everything is positioned by walking a cursor (`cx`) and letting each
//! element claim its width plus the icon gap — there is no measuring pass,
//! so the chip's own width is whatever the caller gave it rather than what
//! its contents need.
//!
//! Two details that are easy to lose:
//!
//!   * `handlePointerUp` flips `selected` *directly* rather than calling
//!     `setSelected`, so the select tween is not re-armed and a filter chip
//!     changes state instantly on click. `setSelected` exists for callers
//!     driving the chip externally, and only it animates.
//!   * `setSelected` only starts the tween when the variant is Filter; for
//!     the other three it records the flag and does nothing else.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const label_mod = @import("../../core/label.zig");
const glyph_mod = @import("../../core/glyph.zig");
const box_mod = @import("../../core/primitives/box.zig");
const state_layer_mod = @import("../../core/primitives/state_layer.zig");
const animation = @import("../../core/animation.zig");

pub const Label = label_mod.Label;
pub const Glyph = glyph_mod.Glyph;
pub const Box = box_mod.Box;
pub const StateLayer = state_layer_mod.StateLayer;
pub const FocusRing = state_layer_mod.FocusRing;
pub const Tween = animation.Tween;

pub const Callback = *const fn (ctx: ?*anyopaque) void;
pub const ToggleCallback = *const fn (ctx: ?*anyopaque, selected: bool) void;

/// M3 Chip — 4 variants: Assist, Filter, Input, Suggestion.
/// Optional leading icon, trailing icon, close icon.
/// Filter variant supports toggle selection.
pub const Chip = struct {
    pub const Variant = enum {
        assist,
        filter,
        input,
        suggestion,
    };

    /// `corner.small`.
    pub const kRadius: f32 = 8.0;
    /// Horizontal padding before the leading element.
    pub const kPad: f32 = 16.0;
    /// Gap either side of an icon.
    pub const kIconPad: f32 = 8.0;
    /// Leading/trailing icon size, and close icon size.
    pub const kIconSize: f32 = 18.0;
    pub const kCloseSize: f32 = 18.0;
    /// Tween length for a selection change: 200 ms.
    pub const kAnimMs: u64 = 200;

    variant: Variant = .assist,
    selected: bool = false,
    enabled: bool = true,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 32.0,

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

    label: Label = .{},
    leading_glyph: Glyph = .{},
    trailing_glyph: Glyph = .{},
    close_glyph: Glyph = .{},
    state_layer: StateLayer = .{},
    focus_ring: FocusRing = .{},
    select_tween: Tween = .{},

    on_click: ?Callback = null,
    on_toggle: ?ToggleCallback = null,
    cb_ctx: ?*anyopaque = null,

    pub fn setVariant(self: *Chip, v: Variant) void {
        self.variant = v;
    }

    pub fn setLabel(self: *Chip, t: []const u8) void {
        self.label.setText(t);
    }

    pub fn setLeadingIcon(self: *Chip, g: []const u8) void {
        self.leading_glyph.setGlyph(g);
    }

    pub fn setTrailingIcon(self: *Chip, g: []const u8) void {
        self.trailing_glyph.setGlyph(g);
    }

    pub fn setCloseIcon(self: *Chip, g: []const u8) void {
        self.close_glyph.setGlyph(g);
    }

    /// Only the Filter variant animates; the other three just record the
    /// flag. See the module note on why a *click* does not go through here.
    pub fn setSelected(self: *Chip, s: bool, now_ms: u64) void {
        if (s == self.selected) return;
        self.selected = s;
        if (self.variant == .filter) {
            self.select_tween.start(
                self.select_tween.value(now_ms),
                if (s) 1.0 else 0.0,
                now_ms,
                kAnimMs,
                animation.kEmphasized,
            );
        }
    }

    pub fn setEnabled(self: *Chip, e: bool) void {
        self.enabled = e;
    }

    pub fn setGeometry(self: *Chip, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *Chip, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Chip, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Chip, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Chip, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn setHovered(self: *Chip, h: bool) void {
        self.hovered = h;
    }

    pub fn setPressed(self: *Chip, p: bool) void {
        self.pressed = p;
    }

    pub fn setFocused(self: *Chip, f: bool) void {
        self.focused = f;
    }

    pub fn setOnClick(self: *Chip, cb: ?Callback) void {
        self.on_click = cb;
    }

    pub fn setOnToggle(self: *Chip, cb: ?ToggleCallback) void {
        self.on_toggle = cb;
    }

    pub fn setCallbackContext(self: *Chip, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn isSelected(self: *const Chip) bool {
        return self.selected;
    }

    pub fn isEnabled(self: *const Chip) bool {
        return self.enabled;
    }

    pub fn variantOf(self: *const Chip) Variant {
        return self.variant;
    }

    pub fn containsPoint(self: *const Chip, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    pub fn handlePointerEnter(self: *Chip, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        self.hovered = true;
        return true;
    }

    pub fn handlePointerLeave(self: *Chip) bool {
        self.hovered = false;
        self.pressed = false;
        return true;
    }

    pub fn handlePointerDown(self: *Chip, px: f32, py: f32) bool {
        if (!self.enabled or !self.containsPoint(px, py)) return false;
        self.pressed = true;
        return true;
    }

    /// Only Filter toggles on press; the others are plain buttons.
    pub fn handlePointerUp(self: *Chip, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        if (self.pressed) {
            self.pressed = false;
            if (self.variant == .filter) {
                // Deliberately not `setSelected` — see the module note. The
                // flag flips but the tween is left alone.
                self.selected = !self.selected;
                if (self.on_toggle) |cb| cb(self.cb_ctx, self.selected);
            }
            if (self.on_click) |cb| cb(self.cb_ctx);
        }
        return true;
    }

    /// Non-animated paint — forwards to `paint(cr, 0)`.
    pub fn paintStatic(self: *const Chip, c: ?*cairo.cairo_t) void {
        const mutable: *Chip = @constCast(self);
        mutable.paint(c, 0);
    }

    pub fn paint(self: *Chip, c: ?*cairo.cairo_t, now_ms: u64) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        const r = kRadius;
        const alpha: f32 = if (self.enabled) 1.0 else 0.38;

        // The select tween only feeds the Filter variant; the others read 0.
        const select_t: f32 = if (self.variant == .filter) self.select_tween.value(now_ms) else 0.0;

        // Resolve colours from the variant.
        var bg_r: f32 = 0;
        var bg_g: f32 = 0;
        var bg_b: f32 = 0;
        var bg_a: f32 = 0;
        var fg_r: f32 = 0;
        var fg_g: f32 = 0;
        var fg_b: f32 = 0;
        var outlined = false;

        if (!self.enabled) {
            bg_r = self.surface_r;
            bg_g = self.surface_g;
            bg_b = self.surface_b;
            bg_a = 0.12;
            fg_r = self.text_r;
            fg_g = self.text_g;
            fg_b = self.text_b;
        } else switch (self.variant) {
            .assist => {
                // surface-container-low: surface pulled 8% toward outline.
                bg_r = blend(self.surface_r, self.outline_r, 0.08);
                bg_g = blend(self.surface_g, self.outline_g, 0.08);
                bg_b = blend(self.surface_b, self.outline_b, 0.08);
                bg_a = 1.0;
                fg_r = self.text_r;
                fg_g = self.text_g;
                fg_b = self.text_b;
            },
            .filter => {
                // Unselected is a dark accent (30%), selected a lighter one
                // (70%); the foreground cross-fades from the text colour to
                // white over the same tween.
                const t = select_t;
                bg_r = blend(self.accent_r * 0.3, self.accent_r * 0.7, t);
                bg_g = blend(self.accent_g * 0.3, self.accent_g * 0.7, t);
                bg_b = blend(self.accent_b * 0.3, self.accent_b * 0.7, t);
                bg_a = 1.0;
                fg_r = blend(self.text_r, 1.0, t);
                fg_g = blend(self.text_g, 1.0, t);
                fg_b = blend(self.text_b, 1.0, t);
            },
            .input => {
                bg_r = blend(self.surface_r, self.outline_r, 0.15);
                bg_g = blend(self.surface_g, self.outline_g, 0.15);
                bg_b = blend(self.surface_b, self.outline_b, 0.15);
                bg_a = 1.0;
                fg_r = self.text_r;
                fg_g = self.text_g;
                fg_b = self.text_b;
                // The only variant that draws a border.
                outlined = true;
            },
            .suggestion => {
                bg_r = blend(self.surface_r, self.outline_r, 0.15);
                bg_g = blend(self.surface_g, self.outline_g, 0.15);
                bg_b = blend(self.surface_b, self.outline_b, 0.15);
                bg_a = 1.0;
                fg_r = self.text_r;
                fg_g = self.text_g;
                fg_b = self.text_b;
            },
        }

        cairo.cairo_save(cr);

        // Background via Box, which supplies the glassy inner rim at the
        // chip's native 8dp radius.
        var bg_box = Box{};
        bg_box.setColor(bg_r, bg_g, bg_b, bg_a * alpha);
        bg_box.setRadius(r);
        bg_box.setGeometry(self.x, self.y, self.w, self.h);
        bg_box.setGlassy(true);
        bg_box.paint(c);

        // Everything below is in chip-local coordinates.
        cairo.cairo_translate(cr, self.x, self.y);

        if (outlined and self.enabled) {
            // `r - 0.5` insets the arcs so the 1dp border straddles the edge.
            cairo.cairo_new_path(cr);
            cairo.cairo_arc(cr, r, r, r - 0.5, std.math.pi, 1.5 * std.math.pi);
            cairo.cairo_arc(cr, self.w - r, r, r - 0.5, 1.5 * std.math.pi, 2.0 * std.math.pi);
            cairo.cairo_arc(cr, self.w - r, self.h - r, r - 0.5, 0.0, 0.5 * std.math.pi);
            cairo.cairo_arc(cr, r, self.h - r, r - 0.5, 0.5 * std.math.pi, std.math.pi);
            cairo.cairo_close_path(cr);
            cairo.cairo_set_source_rgba(cr, self.outline_r, self.outline_g, self.outline_b, 1.0);
            cairo.cairo_set_line_width(cr, 1.0);
            cairo.cairo_stroke(cr);
        }

        // Content layout — a left-to-right cursor. No measuring pass, so the
        // chip's width is whatever the caller set, not what the contents need.
        const cy = self.h * 0.5;
        var cx = kPad;

        // Leading icon, at 78% of the foreground alpha.
        if (self.leading_glyph.glyph.len != 0) {
            self.leading_glyph.setSize(kIconSize);
            self.leading_glyph.setColor(fg_r, fg_g, fg_b, alpha * 0.78);
            self.leading_glyph.paintAt(c, cx, cy - kIconSize * 0.5);
            cx += kIconSize + kIconPad;
        }

        // Label, vertically centred on its own measured height.
        var lw: f32 = 0;
        var lh: f32 = 0;
        self.label.measureExtents(&lw, &lh);
        self.label.setColor(fg_r, fg_g, fg_b, alpha);
        self.label.paintAt(c, cx, cy - lh * 0.5);
        cx += lw;

        // Trailing icon.
        if (self.trailing_glyph.glyph.len != 0) {
            cx += kIconPad;
            self.trailing_glyph.setSize(kIconSize);
            self.trailing_glyph.setColor(fg_r, fg_g, fg_b, alpha * 0.78);
            self.trailing_glyph.paintAt(c, cx, cy - kIconSize * 0.5);
            cx += kIconSize;
        }

        // Close icon, rightmost. Note its `cx` is advanced past but never
        // read — left as the end of the run.
        if (self.close_glyph.glyph.len != 0) {
            cx += kIconPad;
            self.close_glyph.setSize(kCloseSize);
            self.close_glyph.setColor(fg_r, fg_g, fg_b, alpha * 0.78);
            self.close_glyph.paintAt(c, cx, cy - kCloseSize * 0.5);
            cx += kCloseSize;
        }

        cairo.cairo_restore(cr);

        // State layer, tinted with the resolved foreground.
        self.state_layer.setColor(fg_r, fg_g, fg_b);
        self.state_layer.setRadius(r);
        self.state_layer.setGeometry(self.x, self.y, self.w, self.h);
        self.state_layer.setHovered(self.hovered);
        self.state_layer.setPressed(self.pressed);
        self.state_layer.setFocused(self.focused);
        self.state_layer.tick(now_ms);
        self.state_layer.paint(c, now_ms);

        // Focus ring.
        self.focus_ring.setFocused(self.focused);
        self.focus_ring.setColor(self.outline_r, self.outline_g, self.outline_b);
        self.focus_ring.setRadius(r);
        self.focus_ring.paint(c, self.x, self.y, self.w, self.h);
    }

    fn blend(a: f32, b: f32, t: f32) f32 {
        return a + (b - a) * t;
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-chip: only the filter variant toggles on press" {
    const t = testing;
    const S = struct {
        var clicks: usize = 0;
        var toggles: usize = 0;
        var last: bool = false;
        fn onClick(ctx: ?*anyopaque) void {
            _ = ctx;
            clicks += 1;
        }
        fn onToggle(ctx: ?*anyopaque, v: bool) void {
            _ = ctx;
            toggles += 1;
            last = v;
        }
    };
    S.clicks = 0;
    S.toggles = 0;

    var filter = Chip{};
    filter.setVariant(.filter);
    filter.setGeometry(0, 0, 80, 32);
    filter.setOnClick(S.onClick);
    filter.setOnToggle(S.onToggle);

    _ = filter.handlePointerDown(10, 10);
    _ = filter.handlePointerUp(10, 10);
    try t.expect(filter.isSelected());
    try t.expectEqual(@as(usize, 1), S.toggles);
    try t.expectEqual(@as(usize, 1), S.clicks);
    try t.expect(S.last);

    // An assist chip fires on_click but never toggles.
    var assist = Chip{};
    assist.setVariant(.assist);
    assist.setGeometry(0, 0, 80, 32);
    assist.setOnClick(S.onClick);
    assist.setOnToggle(S.onToggle);

    _ = assist.handlePointerDown(10, 10);
    _ = assist.handlePointerUp(10, 10);
    try t.expect(!assist.isSelected());
    try t.expectEqual(@as(usize, 1), S.toggles);
    try t.expectEqual(@as(usize, 2), S.clicks);
}

test "m3-chip: a click flips selection without re-arming the tween" {
    const t = testing;
    var chip = Chip{};
    chip.setVariant(.filter);

    // `setSelected` arms it — this is the external-driver path.
    chip.setSelected(true, 0);
    try t.expect(chip.select_tween.active);
    // Stand it back down so the click has something to flip *to*, without
    // going through `setSelected` (which would re-arm the tween).
    chip.select_tween.stop();
    chip.selected = false;

    // A click flips the flag but leaves the tween alone.
    chip.setGeometry(0, 0, 80, 32);
    _ = chip.handlePointerDown(10, 10);
    _ = chip.handlePointerUp(10, 10);
    try t.expect(chip.isSelected());
    try t.expect(!chip.select_tween.active);

    // On a non-filter variant `setSelected` records but does not animate.
    var assist = Chip{};
    assist.setVariant(.assist);
    assist.setSelected(true, 0);
    try t.expect(assist.isSelected());
    try t.expect(!assist.select_tween.active);
}

test "m3-chip: every variant paints, including disabled and outlined" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .assist, .filter, .input, .suggestion }) |v| {
        var chip = Chip{};
        chip.setVariant(v);
        chip.setGeometry(4, 4, 160, 32);
        chip.setLabel("Chip");
        chip.setLeadingIcon("star");
        chip.setTrailingIcon("expand_more");
        chip.setCloseIcon("close");
        chip.setFocused(true);
        chip.setSelected(true, 0);
        chip.paintStatic(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // Disabled drops the outline and dims the fill.
    var off = Chip{};
    off.setEnabled(false);
    off.setVariant(.input);
    off.setGeometry(4, 4, 160, 32);
    off.setLabel("Off");
    off.paint(cr, 0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Mid-selection tween.
    var animating = Chip{};
    animating.setVariant(.filter);
    animating.setGeometry(4, 4, 160, 32);
    animating.setSelected(true, 1000);
    animating.paint(cr, 1050);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = Chip{};
    degenerate.paint(null, 0);
    degenerate.paintStatic(null);
}
