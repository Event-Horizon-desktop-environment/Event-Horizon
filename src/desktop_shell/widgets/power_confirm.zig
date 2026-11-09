//! The power confirmation card, ported from the reference
//! `desktop_shell/power_confirm/power_confirm.cpp`.
//!
//! It is deliberately a pure layout/paint/hit-test module: the caller owns the
//! fullscreen overlay surface, the clock and the action that follows. That is
//! what lets the card live outside the launcher's own popup instead of being
//! drawn into the start menu's surface.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const chrome = @import("shared/chrome_colors.zig");
const helpers = @import("../shared/cairo_helpers.zig");

pub const Pick = enum { none, cancel, confirm, close };

pub const CardGeom = struct {
    cx: f64,
    cy: f64,
    cw: f64,
    ch: f64,
    close_x: f64,
    close_y: f64,
    close_w: f64,
    close_h: f64,
    cancel_x: f64,
    cancel_y: f64,
    cancel_w: f64,
    cancel_h: f64,
    confirm_x: f64,
    confirm_y: f64,
    confirm_w: f64,
    confirm_h: f64,
};

fn inRect(x: f64, y: f64, rx: f64, ry: f64, rw: f64, rh: f64) bool {
    return x >= rx and x < rx + rw and y >= ry and y < ry + rh;
}

fn box(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, rad: f64, c: chrome.Rgb, a: f64) void {
    if (w <= 0.0 or h <= 0.0 or a <= 0.0) return;
    helpers.roundedRect(cr, x, y, w, h, rad);
    cairo.cairo_set_source_rgba(cr, c.r, c.g, c.b, a);
    cairo.cairo_fill(cr);
}

/// Only actions that can lose work ask for confirmation. Lock (0) and sleep
/// (1) run straight from the footer.
pub fn isConfirmable(idx: i32) bool {
    return idx >= 2 and idx <= 5;
}

pub fn titleFor(idx: i32) [:0]const u8 {
    return switch (idx) {
        2 => "Hibernate?",
        3 => "Log out?",
        4 => "Restart?",
        5 => "Shut down?",
        else => "",
    };
}

pub fn messageFor(idx: i32) [:0]const u8 {
    return switch (idx) {
        2 => "Save the session to disk and power off.",
        3 => "End this session and return to the login screen.",
        4 => "The system will restart.",
        5 => "The system will power off.",
        else => "",
    };
}

pub fn confirmLabelFor(idx: i32) [:0]const u8 {
    return switch (idx) {
        2 => "Hibernate",
        3 => "Log out",
        4 => "Restart",
        5 => "Shut down",
        else => "Confirm",
    };
}

pub fn layout(W: f64, H: f64, us: f64) CardGeom {
    const pad = 28.0 * us;
    const btn_h = 52.0 * us;
    const btn_gap = 12.0 * us;
    const timer_h = 28.0 * us;
    const progress_h = 4.0;
    const card_w = @min(480.0 * us, @max(0.0, W - 32.0 * us));
    const natural_h = pad + 40.0 * us + 10.0 * us + 24.0 * us + 10.0 * us +
        timer_h + 6.0 * us + progress_h + 16.0 * us + btn_h + pad;
    const card_h = @min(natural_h, @max(0.0, H - 32.0 * us));

    const cx = (W - card_w) * 0.5;
    const cy = (H - card_h) * 0.5;
    const btn_y = cy + card_h - pad - btn_h;
    const btn_w = (card_w - 2.0 * pad - btn_gap) * 0.5;

    return .{
        .cx = cx,
        .cy = cy,
        .cw = card_w,
        .ch = card_h,
        .close_x = cx + card_w - pad - 32.0 * us,
        .close_y = cy + pad - 6.0 * us,
        .close_w = 32.0 * us,
        .close_h = 32.0 * us,
        .cancel_x = cx + pad,
        .cancel_y = btn_y,
        .cancel_w = btn_w,
        .cancel_h = btn_h,
        .confirm_x = cx + pad + btn_w + btn_gap,
        .confirm_y = btn_y,
        .confirm_w = btn_w,
        .confirm_h = btn_h,
    };
}

pub fn pick(W: f64, H: f64, power_idx: i32, px: f64, py: f64, us: f64) Pick {
    if (!isConfirmable(power_idx)) return .none;
    if (W <= 0.0 or H <= 0.0) return .none;
    const g = layout(W, H, us);
    if (inRect(px, py, g.close_x, g.close_y, g.close_w, g.close_h)) return .close;
    if (inRect(px, py, g.cancel_x, g.cancel_y, g.cancel_w, g.cancel_h)) return .cancel;
    if (inRect(px, py, g.confirm_x, g.confirm_y, g.confirm_w, g.confirm_h)) return .confirm;
    return .none;
}

fn text(cr: ?*cairo.cairo_t, s: [:0]const u8, x: f64, y: f64, size: f64, bold: bool, r: f64, g: f64, b: f64, a: f64) void {
    cairo.cairo_select_font_face(cr, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, if (bold) cairo.CAIRO_FONT_WEIGHT_BOLD else cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(cr, size);
    cairo.cairo_set_source_rgba(cr, r, g, b, a);
    cairo.cairo_move_to(cr, x, y);
    cairo.cairo_show_text(cr, s);
}

fn centredText(cr: ?*cairo.cairo_t, s: [:0]const u8, cx: f64, cy: f64, size: f64, bold: bool, r: f64, g: f64, b: f64, a: f64) void {
    cairo.cairo_select_font_face(cr, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, if (bold) cairo.CAIRO_FONT_WEIGHT_BOLD else cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(cr, size);
    var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    cairo.cairo_text_extents(cr, s, &ex);
    cairo.cairo_set_source_rgba(cr, r, g, b, a);
    cairo.cairo_move_to(cr, cx - ex.x_advance * 0.5, cy + ex.height * 0.5);
    cairo.cairo_show_text(cr, s);
}

/// `remaining_sec` is the whole seconds left on the 60 s countdown. The caller
/// computes it from its monotonic clock so the card itself stays time-free.
pub fn paint(
    cr: ?*cairo.cairo_t,
    W: f64,
    H: f64,
    power_idx: i32,
    px: f64,
    py: f64,
    remaining_sec: i32,
    colors: chrome.Chrome,
    us: f64,
) void {
    if (!isConfirmable(power_idx)) return;
    if (W <= 0.0 or H <= 0.0) return;
    const g = layout(W, H, us);

    // Dim everything behind the card.
    cairo.cairo_set_source_rgba(cr, colors.drawer_dim.r, colors.drawer_dim.g, colors.drawer_dim.b, 0.55);
    cairo.cairo_paint(cr);

    // Card shadow and glassy fill.
    box(cr, g.cx + 2.0 * us, g.cy + 3.0 * us, g.cw, g.ch, 18.0 * us, .{ .r = 0.0, .g = 0.0, .b = 0.0 }, 0.28);
    box(cr, g.cx, g.cy, g.cw, g.ch, 18.0 * us, colors.dock_fill, 0.97);
    helpers.roundedRect(cr, g.cx, g.cy, g.cw, g.ch, 18.0 * us);
    cairo.cairo_set_source_rgba(cr, colors.outline.r, colors.outline.g, colors.outline.b, 0.35);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);

    // Close button.
    const close_hover = inRect(px, py, g.close_x, g.close_y, g.close_w, g.close_h);
    box(cr, g.close_x, g.close_y, g.close_w, g.close_h, 10.0 * us, colors.drawer_dim, if (close_hover) 0.55 else 0.40);
    if (close_hover) {
        box(cr, g.close_x, g.close_y, g.close_w, g.close_h, 10.0 * us, .{ .r = 0.9, .g = 0.94, .b = 0.97 }, 0.10);
    }
    {
        const ccx = g.close_x + g.close_w * 0.5;
        const ccy = g.close_y + g.close_h * 0.5;
        const arm = 5.0 * us;
        cairo.cairo_set_source_rgba(cr, 0.88, 0.92, 0.95, 1.0);
        cairo.cairo_set_line_width(cr, 2.0 * us);
        cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
        cairo.cairo_move_to(cr, ccx - arm, ccy - arm);
        cairo.cairo_line_to(cr, ccx + arm, ccy + arm);
        cairo.cairo_move_to(cr, ccx + arm, ccy - arm);
        cairo.cairo_line_to(cr, ccx - arm, ccy + arm);
        cairo.cairo_stroke(cr);
    }

    // Title and message.
    text(cr, titleFor(power_idx), g.cx + 28.0 * us, g.cy + 28.0 * us + 16.0 * us, 20.0 * us, true, 0.93, 0.96, 0.98, 1.0);
    text(
        cr,
        messageFor(power_idx),
        g.cx + 28.0 * us,
        g.cy + 28.0 * us + 40.0 * us + 10.0 * us + 16.0 * us,
        14.0 * us,
        false,
        @min(1.0, colors.outline.r + 0.15),
        @min(1.0, colors.outline.g + 0.12),
        @min(1.0, colors.outline.b + 0.12),
        0.88,
    );

    // Countdown bar and seconds.
    const timer_y = g.cy + 28.0 * us + 40.0 * us + 10.0 * us + 24.0 * us + 10.0 * us;
    const pbar_x = g.cx + 28.0 * us;
    const pbar_w = g.cw - 56.0 * us;
    const pbar_y = timer_y + 28.0 * us + 6.0 * us;
    box(cr, pbar_x, pbar_y, pbar_w, 4.0, 2.0, colors.drawer_dim, 0.55);
    const fraction = std.math.clamp(@as(f64, @floatFromInt(remaining_sec)) / 60.0, 0.0, 1.0);
    if (fraction > 0.0) {
        box(cr, pbar_x, pbar_y, pbar_w * fraction, 4.0, 2.0, colors.accent, 0.85);
    }
    var timer_buf: [16]u8 = undefined;
    const timer_text = std.fmt.bufPrintZ(&timer_buf, "{d}s", .{remaining_sec}) catch "0s";
    centredText(cr, timer_text, g.cx + g.cw * 0.5, timer_y + 14.0 * us, 22.0 * us, true, 0.88, 0.92, 0.95, 0.85);

    // Cancel.
    const cancel_hover = inRect(px, py, g.cancel_x, g.cancel_y, g.cancel_w, g.cancel_h);
    box(cr, g.cancel_x, g.cancel_y, g.cancel_w, g.cancel_h, 12.0 * us, colors.drawer_dim, if (cancel_hover) 0.55 else 0.42);
    helpers.roundedRect(cr, g.cancel_x, g.cancel_y, g.cancel_w, g.cancel_h, 12.0 * us);
    cairo.cairo_set_source_rgba(cr, colors.outline.r, colors.outline.g, colors.outline.b, 0.45);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);
    if (cancel_hover) {
        box(cr, g.cancel_x, g.cancel_y, g.cancel_w, g.cancel_h, 12.0 * us, .{ .r = 0.9, .g = 0.94, .b = 0.97 }, 0.10);
    }
    centredText(cr, "Cancel", g.cancel_x + g.cancel_w * 0.5, g.cancel_y + g.cancel_h * 0.5, 15.0 * us, false, 0.90, 0.94, 0.96, 0.95);

    // Confirm, tinted as the danger action.
    const err = chrome.Rgb{ .r = 0.93, .g = 0.38, .b = 0.42 };
    const ok_hover = inRect(px, py, g.confirm_x, g.confirm_y, g.confirm_w, g.confirm_h);
    box(cr, g.confirm_x, g.confirm_y, g.confirm_w, g.confirm_h, 12.0 * us, err, if (ok_hover) 0.26 else 0.16);
    helpers.roundedRect(cr, g.confirm_x, g.confirm_y, g.confirm_w, g.confirm_h, 12.0 * us);
    cairo.cairo_set_source_rgba(cr, err.r, err.g, err.b, 0.85);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);
    if (ok_hover) {
        box(cr, g.confirm_x, g.confirm_y, g.confirm_w, g.confirm_h, 12.0 * us, err, 0.12);
    }
    centredText(
        cr,
        confirmLabelFor(power_idx),
        g.confirm_x + g.confirm_w * 0.5,
        g.confirm_y + g.confirm_h * 0.5,
        15.0 * us,
        false,
        @min(1.0, err.r + 0.05),
        @min(1.0, err.g + 0.35),
        @min(1.0, err.b + 0.35),
        0.98,
    );
}

test "power-confirm: the card's labels cover the four session actions" {
    const t = std.testing;
    try t.expectEqualStrings("Hibernate?", titleFor(2));
    try t.expectEqualStrings("Log out?", titleFor(3));
    try t.expectEqualStrings("Restart?", titleFor(4));
    try t.expectEqualStrings("Shut down?", titleFor(5));
    try t.expectEqualStrings("Hibernate", confirmLabelFor(2));
    try t.expectEqualStrings("Log out", confirmLabelFor(3));
    try t.expectEqualStrings("", titleFor(0));
    try t.expectEqualStrings("", titleFor(1));
    try t.expectEqualStrings("", titleFor(6));
    try t.expect(!isConfirmable(1));
    try t.expect(isConfirmable(2));
}

test "power-confirm: buttons are hit in the card and missed outside it" {
    const t = std.testing;
    const W = 1280.0;
    const H = 720.0;
    const g = layout(W, H, 1.0);
    try t.expect(pick(W, H, 2, g.confirm_x + 4.0, g.confirm_y + 4.0, 1.0) == .confirm);
    try t.expect(pick(W, H, 3, g.cancel_x + 4.0, g.cancel_y + 4.0, 1.0) == .cancel);
    try t.expect(pick(W, H, 4, g.close_x + 4.0, g.close_y + 4.0, 1.0) == .close);
    try t.expect(pick(W, H, 2, 2.0, 2.0, 1.0) == .none);
    // Lock, sleep, out-of-range actions and empty surfaces have no buttons.
    try t.expect(pick(W, H, 0, g.confirm_x + 4.0, g.confirm_y + 4.0, 1.0) == .none);
    try t.expect(pick(W, H, 1, g.confirm_x + 4.0, g.confirm_y + 4.0, 1.0) == .none);
    try t.expect(pick(0.0, H, 2, 2.0, 2.0, 1.0) == .none);
}

test "power-confirm: paint is a no-op for an invalid action" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 32, 32);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paint(cr, 32.0, 32.0, 0, 0.0, 0.0, 60, .{}, 1.0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
