//! Blocking "Keep these display settings?" dialog.
//!
//! Zoolander applies every edit in the display group immediately, then hides
//! behind a 15-second confirmation window. Both the per-output monitor edits
//! and the global `set_presentation` edits share that window, so this module
//! paints one unambiguous dialog for either case: a veil over the whole
//! settings window, the countdown, and Revert / Keep actions. While it is up
//! the underlying page must not receive clicks; `hit` reports which button (if
//! any) was pressed and callers swallow everything else.

const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

/// Which pending change the dialog is confirming. Only the wording differs;
/// the timeout is shared.
pub const Kind = enum { monitors, presentation };

pub const Action = enum { keep, revert };

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h;
    }
};

pub const Layout = struct {
    panel: Rect,
    revert: Rect,
    keep: Rect,
};

pub const panel_w: i32 = 440;
pub const panel_h: i32 = 208;
const pad: i32 = 22;
const button_w: i32 = 112;
const button_h: i32 = 36;
const button_gap: i32 = 12;

/// Centered panel with the two actions pinned to the bottom right. Kept pure
/// so the hit test and the painter cannot disagree.
pub fn layout(win_w: i32, win_h: i32) Layout {
    const px = @divTrunc(win_w - panel_w, 2);
    const py = @divTrunc(win_h - panel_h, 2);
    const by = py + panel_h - pad - button_h;
    const keep_x = px + panel_w - pad - button_w;
    return .{
        .panel = .{ .x = px, .y = py, .w = panel_w, .h = panel_h },
        .keep = .{ .x = keep_x, .y = by, .w = button_w, .h = button_h },
        .revert = .{ .x = keep_x - button_gap - button_w, .y = by, .w = button_w, .h = button_h },
    };
}

/// Button under the pointer, or null for the veil/panel. A null result still
/// means "the dialog consumed the click".
pub fn hit(win_w: i32, win_h: i32, x: i32, y: i32) ?Action {
    const l = layout(win_w, win_h);
    if (l.keep.contains(x, y)) return .keep;
    if (l.revert.contains(x, y)) return .revert;
    return null;
}

pub fn titleFor(kind: Kind) []const u8 {
    return switch (kind) {
        .monitors => "Keep these display settings?",
        .presentation => "Keep these display settings?",
    };
}

pub fn bodyFor(kind: Kind, seconds: u32, buf: []u8) []const u8 {
    _ = kind;
    return std.fmt.bufPrint(
        buf,
        "Zoolander applied the change right away. Reverting in {d} s unless you keep it.",
        .{seconds},
    ) catch "Zoolander applied the change right away.";
}

pub fn paint(
    cr: ?*cairo.cairo_t,
    win_w: i32,
    win_h: i32,
    kind: Kind,
    seconds: u32,
    pointer_x_f: f64,
    pointer_y_f: f64,
    veil: bool,
) void {
    const pointer_x: i32 = @intFromFloat(@floor(pointer_x_f));
    const pointer_y: i32 = @intFromFloat(@floor(pointer_y_f));
    const c = cr orelse return;
    const t = common.Theme;
    const l = layout(win_w, win_h);

    // Veil: only when the dialog is drawn over the settings page. A
    // standalone layer surface is already its own window and needs none.
    if (veil) {
        cairo.cairo_save(c);
        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.45);
        cairo.cairo_rectangle(c, 0, 0, @floatFromInt(win_w), @floatFromInt(win_h));
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
    }

    ui_paint.card(c, @floatFromInt(l.panel.x), @floatFromInt(l.panel.y), @floatFromInt(l.panel.w), @floatFromInt(l.panel.h), 0.96);
    cairo.cairo_save(c);
    ui_paint.roundRect(
        c,
        @as(f64, @floatFromInt(l.panel.x)) + 0.5,
        @as(f64, @floatFromInt(l.panel.y)) + 0.5,
        @as(f64, @floatFromInt(l.panel.w)) - 1.0,
        @as(f64, @floatFromInt(l.panel.h)) - 1.0,
        common.card_radius,
    );
    cairo.cairo_set_line_width(c, 1);
    cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.12);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);

    const left = l.panel.x + pad;
    const text_w = l.panel.w - pad * 2;
    ui_paint.showTextW(
        c,
        @floatFromInt(left),
        @floatFromInt(l.panel.y + pad + 20),
        titleFor(kind),
        17,
        600,
        @floatFromInt(text_w),
        t.text_r,
        t.text_g,
        t.text_b,
        0.96,
    );

    var body_buf: [160]u8 = undefined;
    const body = bodyFor(kind, seconds, &body_buf);
    ui_paint.showWrapped(
        c,
        @floatFromInt(left),
        @floatFromInt(l.panel.y + pad + 34),
        body,
        13,
        400,
        t.text_r,
        t.text_g,
        t.text_b,
        0.72,
        text_w,
        false,
    );

    // Draining bar: full at the start of the window, empty at the revert.
    const bar_y = l.panel.y + panel_h - pad - button_h - 24;
    ui_paint.roundRect(c, @floatFromInt(left), @floatFromInt(bar_y), @floatFromInt(text_w), 4, 2);
    cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.10);
    cairo.cairo_fill(c);
    const total: f64 = @floatFromInt(countdown_seconds);
    const frac = std.math.clamp(@as(f64, @floatFromInt(seconds)) / total, 0.0, 1.0);
    const bar_w: f64 = @floatFromInt(text_w);
    if (frac > 0.0) {
        ui_paint.roundRect(c, @floatFromInt(left), @floatFromInt(bar_y), bar_w * frac, 4, 2);
        cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.9);
        cairo.cairo_fill(c);
    }

    const keep_hover = l.keep.contains(pointer_x, pointer_y);
    const revert_hover = l.revert.contains(pointer_x, pointer_y);
    ui_paint.paintBtn(c, l.revert.x, l.revert.y, l.revert.w, l.revert.h, "Revert", revert_hover);
    // Keep is the affirmative action, so it carries the accent state layer.
    ui_paint.glassBox(
        c,
        @floatFromInt(l.keep.x),
        @floatFromInt(l.keep.y),
        @floatFromInt(l.keep.w),
        @floatFromInt(l.keep.h),
        @floatFromInt(@divTrunc(button_h, 2)),
        t.acc_r,
        t.acc_g,
        t.acc_b,
        if (keep_hover) 0.30 else 0.20,
    );
    const tw = ui_paint.textWidthPx(c, "Keep", 12, 600);
    const th = ui_paint.textSizePx(c, "Keep", 12, 600).h;
    ui_paint.showText(
        c,
        @floatFromInt(l.keep.x + @divTrunc(l.keep.w - tw, 2)),
        @floatFromInt(l.keep.y + @divTrunc(button_h + th, 2) - 2),
        "Keep",
        12,
        600,
        t.acc_r,
        t.acc_g,
        t.acc_b,
        1.0,
    );
}

/// Mirrors `monitors_state.confirm_seconds` and the Zoolander data layer.
pub const countdown_seconds: u32 = 15;

test "display-confirm: layout centres and hit tests the two actions" {
    const t = std.testing;
    const l = layout(1200, 800);
    try t.expectEqual(@as(i32, 380), l.panel.x);
    try t.expectEqual(@as(i32, 296), l.panel.y);
    const kc = .{ l.keep.x + 1, l.keep.y + 1 };
    try t.expectEqual(Action.keep, hit(1200, 800, kc[0], kc[1]).?);
    const rc = .{ l.revert.x + 1, l.revert.y + 1 };
    try t.expectEqual(Action.revert, hit(1200, 800, rc[0], rc[1]).?);
    try t.expect(hit(1200, 800, 10, 10) == null);
}

test "display-confirm: body text carries the remaining seconds" {
    const t = std.testing;
    var buf: [160]u8 = undefined;
    const s = bodyFor(.monitors, 7, &buf);
    try t.expect(std.mem.indexOf(u8, s, "7 s") != null);
}
