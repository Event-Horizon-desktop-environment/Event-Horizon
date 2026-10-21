//! M3 dialog: scrim, rounded surface,
//! title, content, and a right-aligned row of actions. Three variants
//! (Alert, Simple, Confirmation) exist in the enum, but nothing
//! branches on `variant_` — the draw is identical for all three, so this keeps
//! keeps the field and the enum without inventing behaviour for them.
//!
//! ## The `actionBtns_` bug
//!
//! Three parallel members exist: `actions_` (label + callback),
//! `actionBtns_` and `actionBtnGeoms_`. Only
//! `actions_` is ever appended to and only `actionBtnGeoms_` is ever
//! resized — **`actionBtns_` is never populated**. Consequences:
//!
//!   * `handlePointerDown`'s loop over `actionBtns_` runs zero times, so an
//!     inside click never arms a button; it just falls through to
//!     `return true`.
//!   * `handlePointerUp` loops over `actionBtns_` too, so the branch that
//!     fires `actions_[i].callback` is unreachable — **actions never fire**.
//!   * `paint` iterates `i < actions_.size()` and reads `actionBtns_[i]`,
//!     indexing an empty vector. That is undefined behaviour, not a missed
//!     draw.
//!
//! Out-of-bounds indexing cannot be reproduced, and should not.
//! This file therefore owns **one `Button` per action** (`btns`, kept in sync
//! by `addAction`/`clearActions` rather than grown unboundedly), and paints
//! and presses it like the obvious reading of the code intends. That is the
//! one structural deviation here; the geometry, colours, layout maths and
//! the scrim are otherwise verbatim.
//!
//! Everything else is faithful, including two oddities worth reading twice:
//!
//!   * The provisional `dy_ = sy_ + (sh_ - dw_ * 0.6) * 0.5` is computed
//!     before the height is known, then thrown away when `dh_` is finalised.
//!   * `dw_ = clamp(sw * 0.85, 328, 560)` puts the *value* between the
//!     bounds, so on a screen narrower than ~386px the dialog is forced out
//!     to 328 and can be wider than 85% of the screen — and wider than the
//!     screen below 328.
//!
//! `dx_`/`dy_`/`dw_`/`dh_` are written by `paint` only, so pointer handling
//! before the first frame acts on whatever the last paint left behind (zero,
//! for a dialog that has never been shown).

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const label_mod = @import("../../core/label.zig");
const button_mod = @import("../containers/button.zig");

pub const Label = label_mod.Label;
pub const Button = button_mod.Button;

pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// One action: its label (borrowed) and what tapping it runs.
pub const Action = struct {
    label: []const u8 = "",
    callback: ?Callback = null,
    ctx: ?*anyopaque = null,
};

const BtnGeom = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,
};

/// Fixed action capacity. Unbounded growth would leak; a
/// dialog has at most a couple of buttons, so this trades that for a
/// fixed buffer and reports a full one from `addAction` instead of
/// reallocating. See the module note.
pub const kMaxActions = 8;

/// M3 Dialog — 3 variants: Alert, Simple, Confirmation.
pub const Dialog = struct {
    pub const Variant = enum {
        alert,
        simple,
        confirmation,
    };

    /// Corner radius — M3 `corner.extra-large`.
    pub const kRadius: f32 = 28.0;
    pub const kPad: f32 = 24.0;
    /// Gap between the title block and the content, and content and actions.
    pub const kTitleGap: f32 = 16.0;
    /// Action button geometry.
    pub const kActionBtnH: f32 = 40.0;
    pub const kActionBtnMinW: f32 = 80.0;
    /// Action buttons are at least `kActionBtnMinW` wide.
    pub const kActionBtnFallbackW: f32 = 48.0;
    pub const kActionGap: f32 = 8.0;
    /// Width clamp range, and the height floor.
    pub const kMinDialogW: f32 = 328.0;
    pub const kMaxDialogW: f32 = 560.0;
    pub const kMinDialogH: f32 = 140.0;
    pub const kWidthFraction: f32 = 0.85;
    /// Action row is `pad * 0.66` above the bottom edge.
    pub const kActionBottomFrac: f32 = 0.66;
    /// Extra action-area height, again `pad * 0.66`.
    pub const kActionAreaFrac: f32 = 0.66;

    /// Scrim, matching `NavDrawer` and `BottomSheet`.
    pub const kScrimR: f32 = 0.071;
    pub const kScrimG: f32 = 0.047;
    pub const kScrimB: f32 = 0.149;
    pub const kScrimAlpha: f32 = 0.32;
    /// Shadow ring drawn just outside the surface, and its width.
    pub const kShadowAlpha: f32 = 0.12;
    pub const kShadowWidth: f32 = 4.0;
    /// `surface-container-high`: the surface blended 15% toward the outline.
    pub const kSurfaceBlend: f32 = 0.15;

    /// Title and action label font sizes and families.
    pub const kActionFont: f32 = 14.0;
    pub const kActionFontFamily = "Inter";
    /// The action label is offset left by half a fixed 60dp, not measured.
    pub const kActionLabelHalfWidth: f32 = 30.0;

    variant: Variant = .alert,
    visible: bool = false,

    /// Screen bounds the scrim covers.
    sx: f32 = 0.0,
    sy: f32 = 0.0,
    sw: f32 = 0.0,
    sh: f32 = 0.0,
    /// Dialog surface — written by `paint`.
    dx: f32 = 0.0,
    dy: f32 = 0.0,
    dw: f32 = 0.0,
    dh: f32 = 0.0,

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

    title: Label = .{},
    content: Label = .{},

    actions: [kMaxActions]Action = @splat(.{}),
    /// Parallel button state — see the module note on why this exists.
    btns: [kMaxActions]Button = @splat(.{}),
    geoms: [kMaxActions]BtnGeom = @splat(.{}),
    action_count: usize = 0,

    pub fn setVariant(self: *Dialog, v: Variant) void {
        self.variant = v;
    }

    pub fn setTitle(self: *Dialog, t: []const u8) void {
        self.title.setText(t);
    }

    pub fn setContent(self: *Dialog, c: []const u8) void {
        self.content.setText(c);
    }

    pub fn setVisible(self: *Dialog, v: bool) void {
        self.visible = v;
    }

    pub fn setGeometry(self: *Dialog, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.sx = gx;
        self.sy = gy;
        self.sw = gw;
        self.sh = gh;
    }

    pub fn setAccentColor(self: *Dialog, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Dialog, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Dialog, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Dialog, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    /// Appends an action. Returns false once `kMaxActions` are used — the
    /// Unbounded growth would leak here.
    pub fn addAction(self: *Dialog, label: []const u8, cb: ?Callback) bool {
        if (self.action_count >= kMaxActions) return false;
        const i = self.action_count;
        self.actions[i] = .{ .label = label, .callback = cb, .ctx = null };
        // The parallel button, kept ready from the moment the action exists.
        self.btns[i] = .{};
        self.action_count = i + 1;
        return true;
    }

    pub fn clearActions(self: *Dialog) void {
        self.action_count = 0;
        self.actions = @splat(.{});
        self.btns = @splat(.{});
        self.geoms = @splat(.{});
    }

    pub fn isVisible(self: *const Dialog) bool {
        return self.visible;
    }

    pub fn actionCount(self: *const Dialog) usize {
        return self.action_count;
    }

    /// Scrim hit test: the whole screen bounds, but only while visible.
    pub fn containsPoint(self: *const Dialog, px: f32, py: f32) bool {
        if (!self.visible) return false;
        return px >= self.sx and px < self.sx + self.sw and py >= self.sy and py < self.sy + self.sh;
    }

    /// A press on the scrim dismisses; a press on a button arms it; a press
    /// anywhere else inside the dialog does nothing but is still reported as
    /// handled.
    ///
    /// "Returns true if the scrim backdrop
    /// was clicked", but its trailing `return true` is unconditional, so the
    /// only false it can produce is "wasn't visible to begin with". Check
    /// `isVisible()` after the call to learn whether the press dismissed.
    /// The dialog rect is only as fresh as the last `paint`.
    pub fn handlePointerDown(self: *Dialog, px: f32, py: f32) bool {
        if (!self.visible) return false;
        // Note `>` rather than `>=`: the dialog's right and bottom edges are
        // treated as *inside*.
        if (px < self.dx or px > self.dx + self.dw or py < self.dy or py > self.dy + self.dh) {
            self.visible = false;
            return true;
        }
        for (0..self.action_count) |i| {
            if (self.btns[i].containsPoint(px, py)) {
                _ = self.btns[i].handlePointerDown(px, py);
                return true;
            }
        }
        return true;
    }

    /// The point is ignored. A release
    /// that lands on a pressed button runs its action and dismisses the
    /// dialog.
    pub fn handlePointerUp(self: *Dialog, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.visible) return false;
        for (0..self.action_count) |i| {
            if (self.btns[i].isPressed()) {
                _ = self.btns[i].handlePointerUp(0, 0);
                if (i < self.action_count) {
                    if (self.actions[i].callback) |cb| cb(self.actions[i].ctx);
                }
                self.visible = false;
                return true;
            }
        }
        return false;
    }

    /// Take `*Dialog`, not `*const`: the layout is written back into
    /// `dx`/`dy`/`dw`/`dh`, matching paint.
    pub fn paint(self: *Dialog, c: ?*cairo.cairo_t) void {
        if (!self.visible or self.sw <= 0.0 or self.sh <= 0.0) return;
        const cr = c orelse return;

        // ——— Layout ———
        self.dw = std.math.clamp(self.sw * kWidthFraction, kMinDialogW, kMaxDialogW);
        self.dh = 0.0;
        self.dx = self.sx + (self.sw - self.dw) * 0.5;
        // Provisional centre, based on a guessed height of `dw * 0.6`.
        self.dy = self.sy + (self.sh - self.dw * 0.6) * 0.5;

        var title_w: f32 = 0;
        var title_h: f32 = 0;
        self.title.measureExtents(&title_w, &title_h);

        var content_w: f32 = 0;
        var content_h: f32 = 0;
        self.content.measureExtents(&content_w, &content_h);

        const title_area_h = kPad + title_h + kTitleGap;
        const content_area_h: f32 = if (content_h > 0) content_h + kPad else kPad;
        const action_count_f: f32 = @floatFromInt(self.action_count);
        const action_area_h = kActionBtnH + (if (action_count_f > 0) kPad * kActionAreaFrac else 0.0);
        const total_h = title_area_h + content_area_h + action_area_h + kPad * 0.5;
        self.dh = @max(total_h, kMinDialogH);
        self.dy = self.sy + (self.sh - self.dh) * 0.5;

        // Action button positions, laid right to left.
        var btn_x = self.dx + self.dw - kPad;
        var i: i32 = @intCast(self.action_count);
        while (i > 0) {
            i -= 1;
            const idx: usize = @intCast(i);
            const bw = @max(kActionBtnMinW, kActionBtnFallbackW);
            const bh = kActionBtnH;
            const bx = btn_x - bw;
            const by = self.dy + self.dh - kPad * kActionBottomFrac - kActionBtnH;
            self.geoms[idx] = .{ .x = bx, .y = by, .w = bw, .h = bh };
            btn_x = bx - kActionGap;
        }

        const r = kRadius;
        const pad = kPad;

        // ——— Scrim ———
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, kScrimR, kScrimG, kScrimB, kScrimAlpha);
        cairo.cairo_paint(cr);
        cairo.cairo_restore(cr);

        // ——— Dialog surface ———
        cairo.cairo_save(cr);

        // Shadow ring: the rounded rect stroked just outside itself.
        cairo.cairo_new_path(cr);
        cairo.cairo_arc(cr, self.dx + r, self.dy + r, r, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, self.dx + self.dw - r, self.dy + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_arc(cr, self.dx + self.dw - r, self.dy + self.dh - r, r, 0.0, 0.5 * std.math.pi);
        cairo.cairo_arc(cr, self.dx + r, self.dy + self.dh - r, r, 0.5 * std.math.pi, std.math.pi);
        cairo.cairo_close_path(cr);
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, kShadowAlpha);
        cairo.cairo_set_line_width(cr, kShadowWidth);
        cairo.cairo_stroke(cr);

        // Background — surface-container-high.
        const bg_r = blend(self.surface_r, self.outline_r, kSurfaceBlend);
        const bg_g = blend(self.surface_g, self.outline_g, kSurfaceBlend);
        const bg_b = blend(self.surface_b, self.outline_b, kSurfaceBlend);
        cairo.cairo_new_path(cr);
        cairo.cairo_arc(cr, self.dx + r, self.dy + r, r, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, self.dx + self.dw - r, self.dy + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_arc(cr, self.dx + self.dw - r, self.dy + self.dh - r, r, 0.0, 0.5 * std.math.pi);
        cairo.cairo_arc(cr, self.dx + r, self.dy + self.dh - r, r, 0.5 * std.math.pi, std.math.pi);
        cairo.cairo_close_path(cr);
        cairo.cairo_set_source_rgba(cr, bg_r, bg_g, bg_b, 1.0);
        cairo.cairo_fill(cr);

        // Title.
        self.title.setColor(self.text_r, self.text_g, self.text_b, 0.93);
        self.title.paintAt(c, self.dx + pad, self.dy + pad);

        // Content.
        if (content_h > 0) {
            self.content.setColor(self.text_r, self.text_g, self.text_b, 0.66);
            self.content.paintAt(c, self.dx + pad, self.dy + pad + title_h + kTitleGap);
        }

        // Action buttons carry no label of their own (it
        // never gets `setLabel`), so it draws just its container and the
        // dialog paints the text over it — here too.
        for (0..self.action_count) |bi| {
            const g = self.geoms[bi];
            const btn = &self.btns[bi];
            btn.setGeometry(g.x, g.y, g.w, g.h);
            btn.setAccentColor(self.accent_r, self.accent_g, self.accent_b);
            btn.setTextColor(self.text_r, self.text_g, self.text_b);
            btn.paint(c, 0);

            cairo.cairo_select_font_face(
                cr,
                kActionFontFamily,
                cairo.CAIRO_FONT_SLANT_NORMAL,
                cairo.CAIRO_FONT_WEIGHT_NORMAL,
            );
            cairo.cairo_set_font_size(cr, kActionFont);
            cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
            cairo.cairo_move_to(
                cr,
                g.x + g.w * 0.5 - kActionLabelHalfWidth,
                g.y + g.h * 0.5 + 5,
            );
            var label_buf: [256:0]u8 = undefined;
            cairo.cairo_show_text(cr, toCString(self.actions[bi].label, &label_buf));
        }

        cairo.cairo_restore(cr);
    }

    fn blend(a: f32, b: f32, t: f32) f32 {
        return a + (b - a) * t;
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

test "m3-dialog: width clamps to [328, 560] and centring follows" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 800, 500);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    // Wide screen: 1000 * 0.85 = 850, clamped down to 560, centred at 220.
    var wide = Dialog{};
    wide.setVisible(true);
    wide.setGeometry(0, 0, 1000, 400);
    wide.paint(cr);
    try t.expectEqual(@as(f32, 560.0), wide.dw);
    try t.expectEqual(@as(f32, 220.0), wide.dx);

    // Mid screen: 500 * 0.85 = 425 sits inside the range.
    var mid = Dialog{};
    mid.setVisible(true);
    mid.setGeometry(0, 0, 500, 400);
    mid.paint(cr);
    try t.expectEqual(@as(f32, 425.0), mid.dw);
    try t.expectEqual(@as(f32, 37.5), mid.dx);

    // Narrow screen: the floor wins, so the dialog is 328 wide even though
    // that is *more* than 85% of the 200px available.
    var narrow = Dialog{};
    narrow.setVisible(true);
    narrow.setGeometry(0, 0, 200, 400);
    narrow.paint(cr);
    try t.expectEqual(@as(f32, 328.0), narrow.dw);
    try t.expectEqual(@as(f32, -64.0), narrow.dx);

    // The dialog is always vertically centred on its computed height, and
    // never shorter than 140.
    try t.expect(wide.dh >= 140.0);
    try t.expectApproxEqAbs(@as(f32, (400.0 - wide.dh) * 0.5), wide.dy, 1e-3);
}

test "m3-dialog: actions fill right-to-left with a fixed 80x40 button" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 800, 500);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var d = Dialog{};
    d.setVisible(true);
    d.setGeometry(0, 0, 1000, 400);
    _ = d.addAction("Cancel", null);
    _ = d.addAction("OK", null);
    d.paint(cr);

    // dw = 560, dx = 220, so btn_x starts at 220 + 560 - 24 = 756.
    // Button 1 (drawn last, laid out first) is 756 - 80 = 676.
    try t.expectEqual(@as(f32, 756.0), d.geoms[1].x + d.geoms[1].w);
    try t.expectEqual(@as(f32, 676.0), d.geoms[1].x);
    try t.expectEqual(@as(f32, 80.0), d.geoms[1].w);
    try t.expectEqual(@as(f32, 40.0), d.geoms[1].h);
    // Button 0 sits one 8dp gap further left.
    try t.expectEqual(@as(f32, 676.0 - 88.0), d.geoms[0].x);
    // Both share the baseline `dy + dh - 24*0.66 - 40`.
    const expected_y = d.dy + d.dh - 24.0 * 0.66 - 40.0;
    try t.expectApproxEqAbs(expected_y, d.geoms[0].y, 1e-3);
    try t.expectApproxEqAbs(expected_y, d.geoms[1].y, 1e-3);

    // Fixed capacity: the first
    // kMaxActions land, and after that nothing does.
    var many = Dialog{};
    for (0..kMaxActions) |_| {
        try t.expect(many.addAction("X", null));
    }
    try t.expect(!many.addAction("overflow", null));
    try t.expectEqual(@as(usize, kMaxActions), many.actionCount());
    many.clearActions();
    try t.expectEqual(@as(usize, 0), many.actionCount());
}

test "m3-dialog: the scrim dismisses, an inside press does not" {
    const t = testing;
    var d = Dialog{};
    d.setVisible(true);
    d.setGeometry(0, 0, 800, 600);

    // Before any paint the dialog rect is degenerate (all zeros), so *any*
    // point counts as outside and dismisses — the same stale-layout
    // behaviour.
    try t.expect(d.handlePointerDown(400, 300));
    try t.expect(!d.isVisible());

    // With a paint behind it, points inside the surface are consumed but do
    // not dismiss. The call still reports true — see the note on the
    // unconditional trailing `return true` — so `isVisible` is the test.
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 800, 600);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    d.setVisible(true);
    d.setTitle("Title");
    d.setContent("Body");
    _ = d.addAction("OK", null);
    d.paint(cr);

    try t.expect(d.handlePointerDown(d.dx + 10, d.dy + 10));
    try t.expect(d.isVisible());

    // A press on the scrim, well clear of the surface, dismisses — and that
    // is what makes `isVisible` the only reliable signal.
    const sx = d.sx + 2;
    const sy = d.sy + 2;
    try t.expect(d.handlePointerDown(sx, sy));
    try t.expect(!d.isVisible());

    // A hidden dialog reports false for any press.
    try t.expect(!d.handlePointerDown(sx, sy));
}

test "m3-dialog: a press/release on an action runs it and closes" {
    const t = testing;
    const S = struct {
        var calls: usize = 0;
        fn onOk(ctx: ?*anyopaque) void {
            _ = ctx;
            calls += 1;
        }
        fn onCancel(ctx: ?*anyopaque) void {
            _ = ctx;
            calls += 100;
        }
    };
    S.calls = 0;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 800, 600);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var d = Dialog{};
    d.setVisible(true);
    d.setGeometry(0, 0, 1000, 400);
    d.setTitle("Delete everything?");
    d.setContent("This cannot be undone.");
    _ = d.addAction("Cancel", S.onCancel);
    _ = d.addAction("Delete", S.onOk);
    d.paint(cr);

    // Land on the left-hand (Cancel) button.
    const gx = d.geoms[0].x + d.geoms[0].w * 0.5;
    const gy = d.geoms[0].y + d.geoms[0].h * 0.5;
    try t.expect(d.handlePointerDown(gx, gy));
    try t.expect(d.isVisible());
    try t.expectEqual(@as(usize, 0), S.calls);

    try t.expect(d.handlePointerUp(gx, gy));
    try t.expectEqual(@as(usize, 100), S.calls);
    try t.expect(!d.isVisible());

    // A release with nothing armed reports false and changes nothing.
    d.setVisible(true);
    try t.expect(!d.handlePointerUp(gx, gy));
    try t.expectEqual(@as(usize, 100), S.calls);
    try t.expect(d.isVisible());

    // A release after a scrim dismiss is refused outright.
    try t.expect(d.handlePointerDown(5, 5));
    try t.expect(!d.isVisible());
    try t.expect(!d.handlePointerUp(gx, gy));
}

test "m3-dialog: hidden, or a degenerate screen, paints nothing" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 400, 300);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var hidden = Dialog{};
    hidden.setGeometry(0, 0, 400, 300);
    hidden.paint(null);
    hidden.paint(cr);

    var no_w = Dialog{};
    no_w.setVisible(true);
    no_w.setGeometry(0, 0, 0, 300);
    no_w.paint(null);
    no_w.paint(cr);

    var no_h = Dialog{};
    no_h.setVisible(true);
    no_h.setGeometry(0, 0, 400, 0);
    no_h.paint(cr);

    // A visible dialog with no actions and no content still lays out and
    // paints at the 140 floor.
    var bare = Dialog{};
    bare.setVisible(true);
    bare.setGeometry(0, 0, 400, 300);
    bare.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    try t.expectApproxEqAbs(@as(f32, 140.0), bare.dh, 1e-3);

    // `containsPoint` is the scrim, so it needs `visible` too.
    try t.expect(!hidden.containsPoint(10, 10));
    bare.setVisible(true);
    try t.expect(bare.containsPoint(10, 10));
    try t.expect(!bare.containsPoint(400, 300));
}
