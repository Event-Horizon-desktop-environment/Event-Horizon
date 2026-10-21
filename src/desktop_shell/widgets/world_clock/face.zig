//! The world-clock widget face: one city's time at a time, rotating with a
//! short slide and a pager-dot column (the spec's "Clock widget"), sitting in
//! the same frosted pill every other widget slot uses. All state lives in
//! `session.zig`; this file only measures and paints.
//!
//! Sizes are the spec's logical pixels times a scale factor derived from the
//! icon box the taskbar hands the face (38 px is the default `icon_size`,
//! i.e. factor 1).

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const widget_pill = @import("../shared/pill.zig");
const measure = @import("../shared/measure_scratch.zig");
const chrome = @import("../shared/chrome_colors.zig");
const helpers = @import("../../shared/cairo_helpers.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;

const k_pi = 3.14159265358979323846;

// Spec sizes, logical px at factor 1.
const k_btn_h = 40.0;
const k_pad_l = 12.0;
const k_pad_r = 10.0;
const k_gap = 9.0;
const k_block_min = 76.0;
const k_name_max = 88.0;
const k_clip_h = 34.0;
const k_name_px = 10.0;
const k_time_px = 16.0;
/// The spec's line height for both lines (1.15). Stacking the fonts'
/// natural logical heights instead leaves the city name floating a few
/// pixels above the time; the line boxes are what tightens the pair.
const k_line_h = 1.15;
const k_ap_px = 10.0;
const k_dot = 3.0;
const k_dot_gap = 3.0;
const k_ap_margin = 3.0;

/// The whole face scales with the icon box (38 px default -> 1.0).
pub fn scaleOf(icon_px: f64) f64 {
    return std.math.clamp(icon_px / 38.0, 0.6, 1.8);
}

fn dotsVisible(s: *const Session) bool {
    return s.count() >= 2 and !s.pinned();
}

fn pxi(v: f64) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(v))));
}

/// Width of the text block: the widest city name capped at 88, floored at
/// the 76 minimum and at the widest time sample. Measuring the whole list
/// (not just the shown city) keeps the slot width stable while it rotates.
fn measuredBlock(s: *Session, c: *cairo.cairo_t, us: f64) f64 {
    var l = text.Layout.createForCairo(c);
    defer l.destroy();
    var fbuf: [48]u8 = undefined;

    const name_fd = std.fmt.bufPrint(&fbuf, "Inter {d}", .{pxi(k_name_px * us)}) catch "Inter 11";
    var name_w: f64 = 0;
    for (0..s.count()) |i| {
        const name = s.nameOf(s.idAt(i));
        l.setFont(name_fd);
        l.setText(name);
        name_w = @max(name_w, @as(f64, @floatFromInt(l.pixelSize().w)));
    }

    const time_fd = std.fmt.bufPrint(&fbuf, "Inter SemiBold {d}", .{pxi(k_time_px * us)}) catch "Inter SemiBold 16";
    l.setFont(time_fd);
    l.setFontFeatures("tnum 1");
    l.setText("88:88");
    var time_w: f64 = @floatFromInt(l.pixelSize().w);
    if (!s.h24) {
        const ap_fd = std.fmt.bufPrint(&fbuf, "Inter Medium {d}", .{pxi(k_ap_px * us)}) catch "Inter Medium 10";
        l.setFont(ap_fd);
        l.setText("PM");
        time_w += k_ap_margin * us + @as(f64, @floatFromInt(l.pixelSize().w));
    }

    return @max(@max(k_block_min * us, @min(name_w, k_name_max * us)), time_w);
}

/// The slot width the paint wants: pads + text block + gap + dots.
pub fn slotWidth(s: *Session, cr_in: ?*cairo.cairo_t, us: f64) f64 {
    const block = if (cr_in orelse measure.measureCr()) |c|
        measuredBlock(s, c, us)
    else
        // No cairo: assume the widest name so nothing clips if it appears.
        k_name_max * us;
    const dots_w: f64 = if (dotsVisible(s)) k_gap * us + k_dot * us else 0.0;
    return k_pad_l * us + block + dots_w + k_pad_r * us;
}

/// Paint the face into `(x, y, w, h)` — the slot box the taskbar laid out.
/// `hovered` is the bar's hover on this slot; the session carries the rest
/// (open state, pin, slide, reduced motion).
pub fn paint(
    c: ?*cairo.cairo_t,
    s: *Session,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    icon_px: f64,
    hovered: bool,
    now_ms: u64,
    mc: chrome.Chrome,
) void {
    const cr = c orelse return;
    if (w <= 1.0 or h <= 1.0) return;
    const us = scaleOf(icon_px);
    const bh = k_btn_h * us;
    const by = y + (h - bh) * 0.5;

    // The same frosted pill every other widget slot sits in (both bars set
    // `widget_pill.style` before their strip pass), so the face reads as one
    // more widget instead of bare text on the bar. Hover and the
    // popup-open states are the host's wash — the shared accent overlay it
    // paints on top of every widget slot — so `hovered` is unused here.
    _ = hovered;
    widget_pill.paintPill(cr, x, y, w, h);

    const fx: session_mod.SlideFx = if (s.reduce_motion) .{} else s.slideFx(now_ms);

    // Text block: name over time, clipped to the spec's 34 px container so
    // slides never spill out of it.
    const dots_w: f64 = if (dotsVisible(s)) k_gap * us + k_dot * us else 0.0;
    const clip_w = @max(1.0, w - (k_pad_l + k_pad_r) * us - dots_w);
    cairo.cairo_save(cr);
    cairo.cairo_rectangle(cr, x + k_pad_l * us, by + (bh - k_clip_h * us) * 0.5, clip_w, k_clip_h * us);
    cairo.cairo_clip(cr);

    var l_name = text.Layout.createForCairo(cr);
    defer l_name.destroy();
    var l_time = text.Layout.createForCairo(cr);
    defer l_time.destroy();

    var fbuf: [48]u8 = undefined;
    const id = s.currentId();
    const name = s.nameOf(id);
    const name_fd = std.fmt.bufPrint(&fbuf, "Inter {d}", .{pxi(k_name_px * us)}) catch "Inter 11";
    l_name.setFont(name_fd);
    l_name.setText(name);
    const name_sz = l_name.pixelSize();

    const t: i64 = @divFloor(@as(i64, @intCast(now_ms)), 1000);
    const tv = session_mod.timeVec(s.wallOf(id, t), s.h24, false);
    const time_fd = std.fmt.bufPrint(&fbuf, "Inter SemiBold {d}", .{pxi(k_time_px * us)}) catch "Inter SemiBold 16";
    l_time.setFont(time_fd);
    l_time.setFontFeatures("tnum 1");
    l_time.setText(tv.hm());
    const time_sz = l_time.pixelSize();

    // The spec's 1.15 line height governs the pair, not the natural font
    // heights: those carry the name's descent *and* the time's ascent, which
    // is what opened the gap between the two lines.
    const name_line = k_name_px * k_line_h * us;
    const time_line = k_time_px * k_line_h * us;
    const text_h = name_line + time_line;
    const top = by + (bh - text_h) * 0.5 + fx.dy * text_h;
    const alpha = fx.alpha;

    // Each run is centred in its own 1.15 line box, the way a browser lays
    // the two lines out.
    const name_y = top + (name_line - @as(f64, @floatFromInt(name_sz.h))) * 0.5;

    // Name: dim, or the accent while a city is pinned.
    const name_c = if (s.pinned()) mc.accent else mc.outline;
    cairo.cairo_set_source_rgba(cr, name_c.r, name_c.g, name_c.b, alpha);
    cairo.cairo_move_to(cr, x + k_pad_l * us, name_y);
    l_name.show(cr);

    // Time line, tabular numerals.
    const time_y = top + name_line + (time_line - @as(f64, @floatFromInt(time_sz.h))) * 0.5;
    cairo.cairo_set_source_rgba(cr, mc.text.r, mc.text.g, mc.text.b, alpha);
    cairo.cairo_move_to(cr, x + k_pad_l * us, time_y);
    l_time.show(cr);

    // AM/PM suffix: 10 px, dim, baseline-aligned with the big time.
    if (!s.h24 and tv.ap().len > 0) {
        var l_ap = text.Layout.createForCairo(cr);
        defer l_ap.destroy();
        const ap_fd = std.fmt.bufPrint(&fbuf, "Inter Medium {d}", .{pxi(k_ap_px * us)}) catch "Inter Medium 10";
        l_ap.setFont(ap_fd);
        l_ap.setText(tv.ap());
        const ap_x = x + k_pad_l * us + @as(f64, @floatFromInt(time_sz.w)) + k_ap_margin * us;
        const ap_y = time_y + (l_time.baseline() - l_ap.baseline());
        cairo.cairo_set_source_rgba(cr, mc.outline.r, mc.outline.g, mc.outline.b, alpha);
        cairo.cairo_move_to(cr, ap_x, ap_y);
        l_ap.show(cr);
    }
    cairo.cairo_restore(cr);

    // Pager dots: one per clock, active in the accent. Hidden for a single
    // clock or a pinned city.
    if (dotsVisible(s)) {
        const n = s.count();
        const cur = s.current();
        const nf: f64 = @floatFromInt(n);
        var step = (k_dot + k_dot_gap) * us;
        const avail = bh - 6.0 * us;
        if (step * (nf - 1.0) + k_dot * us > avail)
            step = @max(3.5 * us, (avail - k_dot * us) / @max(1.0, nf - 1.0));
        const total = step * (nf - 1.0) + k_dot * us;
        const cx = x + w - k_pad_r * us - k_dot * us * 0.5;
        var cy = by + (bh - total) * 0.5 + k_dot * us * 0.5;
        for (0..n) |i| {
            if (i == cur) {
                cairo.cairo_set_source_rgba(cr, mc.accent.r, mc.accent.g, mc.accent.b, 1.0);
            } else {
                cairo.cairo_set_source_rgba(cr, mc.outline.r, mc.outline.g, mc.outline.b, 0.45);
            }
            cairo.cairo_arc(cr, cx, cy, k_dot * us * 0.5, 0, 2.0 * k_pi);
            cairo.cairo_fill(cr);
            cy += step;
        }
    }
}

// Tests

const testing = std.testing;

test "wc-face: scale factor clamps" {
    try testing.expectApproxEqAbs(@as(f64, 1.0), scaleOf(38.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.6), scaleOf(1.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.8), scaleOf(500.0), 1e-9);
}

test "wc-face: slot width without a caller context is well-formed" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();
    // One clock (local), no dots. The block is the 76..88 range (measured
    // through the shared scratch context, or the 88 cap with no cairo at
    // all), plus the 12 + 10 pads.
    const w = slotWidth(&s, null, 1.0);
    try testing.expect(w >= 12.0 + 76.0 + 10.0 - 1e-9);
    try testing.expect(w <= 12.0 + 88.0 + 10.0 + 1e-9);
}

test "wc-face: paint into an image surface is stable" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();
    s.reduce_motion = true;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 54);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    const mc = chrome.Chrome{};
    paint(cr, &s, 0, 0, slotWidth(&s, cr, 1.0), 54, 38, true, 1_000_000, mc);
    paint(cr, &s, 0, 0, slotWidth(&s, cr, 1.0), 54, 38, false, 1_000_990, mc);
    try testing.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
