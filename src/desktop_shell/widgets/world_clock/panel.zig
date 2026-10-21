//! The world-clock popup: layout, paint and input for the taskbar-owned
//! layer surface (the spec's "Popup"). All state lives in `session.zig`; the
//! taskbar owns the surface, sizes it with the display scale and routes
//! pointer, key and scroll events here.
//!
//! Coordinates in this file are natural (unscaled) pixels — the card is 360
//! wide — and the caller multiplies surface sizes, margins and input
//! coordinates by the scale factor. The card is inset by `k_shadow_pad` on
//! every side inside the surface: the margin is invisible, but a press that
//! lands in it still hits the popup and counts as a click outside the card,
//! which closes it.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const helpers = @import("../../shared/cairo_helpers.zig");
const svg = @import("../../../ux/shared/svg_icons.zig");
const measure = @import("../shared/measure_scratch.zig");
const chrome = @import("../shared/chrome_colors.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;
const Focus = session_mod.Focus;
const HoverTarget = session_mod.HoverTarget;
const Rgb = chrome.Rgb;

pub const k_w: f64 = 360.0;
/// Transparent margin around the card: an outside-press ring, no longer a
/// shadow (the reference's soft shadow was dropped by request).
pub const k_shadow_pad: f64 = 24.0;

const k_open_ms: u64 = 160;
const k_fade_ms: u64 = 120;
const k_sw_ms: u64 = 150;

const k_radius = 14.0;

// Header
const hdr_pt = 14.0;
const hdr_pb = 8.0;
const hdr_pl = 16.0;
const weekday_px = 16.0;
const date_px = 12.0;

// Rows
const row_pv = 9.0;
const row_ph = 8.0;
const row_gap = 12.0;
const row_r = 10.0;
const list_ph = 8.0;
const icon_col = 18.0;
const day_icon = 16.0;
const act_sz = 28.0;
const act_r = 8.0;
const name_px = 14.0;
const sub_px = 12.0;
const time_min_w = 92.0;
const hm_px = 26.0;
const sm_px = 12.0;
const sm_margin = 3.0;

// Time shift
const shift_mt = 6.0;
const shift_pt = 10.0;
const shift_pb = 4.0;
const shift_px = 12.0;
const slider_h = 18.0;
const track_h = 4.0;
const track_r = 2.0;
const thumb_d = 16.0;
const reset_gap = 8.0;

// Footer
const foot_pt = 8.0;
const foot_pb = 12.0;
const sw_gap = 18.0;
const sw_label_gap = 8.0;
const sw_w = 28.0;
const sw_h = 16.0;
const sw_r = 9.0;
const sw_thumb = 10.0;
const sw_thumb_off = 2.0;
const sw_travel = 12.0;

const lh = 1.35;

// Derived line boxes (natural px).
const k_weekday_h = weekday_px * lh;
const k_date_h = date_px * lh;
const k_hdr_text_h = k_weekday_h + k_date_h;
const k_name_h = name_px * lh;
const k_sub_h = sub_px * lh;
const k_who_h = k_name_h + k_sub_h;
const k_hm_h = hm_px * lh;
const k_shift_text_h = shift_px * lh;
const k_row_content = @max(@max(k_hm_h, k_who_h), act_sz);
const k_row_h = row_pv * 2.0 + k_row_content;
const k_header_h = hdr_pt + k_hdr_text_h + hdr_pb;
const k_slider_dy = shift_mt + 1.0 + shift_pt + k_shift_text_h + shift_mt;
const k_shift_h = k_slider_dy + slider_h + shift_pb;
const k_footer_content = @max(sw_h, k_shift_text_h);
const k_footer_h = foot_pt + k_footer_content + foot_pb;

const k_pi = 3.14159265358979323846;

const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

fn hit(r: Rect, px: f64, py: f64) bool {
    return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
}

fn hoverPin(h: HoverTarget, i: usize) bool {
    return switch (h) {
        .row_pin => |v| v == i,
        else => false,
    };
}

fn hoverDel(h: HoverTarget, i: usize) bool {
    return switch (h) {
        .row_del => |v| v == i,
        else => false,
    };
}

fn focusPin(f: Focus, i: usize) bool {
    return switch (f) {
        .pin => |v| v == i,
        else => false,
    };
}

fn focusDel(f: Focus, i: usize) bool {
    return switch (f) {
        .del => |v| v == i,
        else => false,
    };
}

/// Layout of the popup card; every field is card-local (no shadow pad).
pub const Geom = struct {
    w: f64 = k_w,
    header_h: f64 = k_header_h,
    row_h: f64 = k_row_h,
    list_y: f64 = k_header_h,
    list_h: f64 = 0,
    content_h: f64 = 0,
    max_scroll: f64 = 0,
    /// Width of the measured time column (min 98).
    time_w: f64 = time_min_w,
    shift_y: f64 = 0,
    shift_h: f64 = k_shift_h,
    slider_y: f64 = 0,
    footer_y: f64 = 0,
    footer_h: f64 = k_footer_h,
    total_h: f64 = 0,
    /// Clock-row count in the list.
    rows: usize = 0,
};

/// Everything the popup needs to know about a completed input event.
pub const Outcome = struct {
    handled: bool = false,
    repaint: bool = false,
    /// The popup's height changed; the host re-measures and resizes.
    relayout: bool = false,
    /// The widget face (bar) changed: pin, city list, 24-hour.
    face: bool = false,
    /// Esc asked for the popup to close.
    close: bool = false,
    /// Settings changed; save when convenient.
    saved: bool = false,
};

// ---------------------------------------------------------------------------
// Layout

fn setFont(l: *text.Layout, weight: []const u8, px: f64) void {
    var buf: [32]u8 = undefined;
    const fd = std.fmt.bufPrint(&buf, "Inter {s}{d}", .{ weight, @as(i32, @intFromFloat(@round(px))) }) catch "Inter 12";
    l.setFont(fd);
}

fn textW(cr: ?*cairo.cairo_t, str: []const u8, weight: []const u8, px: f64) f64 {
    if (str.len == 0) return 0;
    var l = text.Layout.createForCairo(cr);
    defer l.destroy();
    setFont(&l, weight, px);
    l.setText(str);
    return @floatFromInt(l.pixelSize().w);
}

/// Widest time sample so the column never wiggles as the clock ticks.
fn measuredTimeW(s: *const Session) f64 {
    const cr = measure.measureCr() orelse return time_min_w;
    var w: f64 = textW(cr, "88:88", "Medium ", hm_px);
    if (s.sec) w += sm_margin + textW(cr, ":88", "", sm_px);
    if (!s.h24) w += sm_margin + textW(cr, "PM", "", sm_px);
    // 2 px of slack between the widest sample and the column edge; the
    // row's own 12 px gap keeps the actions off the time.
    return @max(time_min_w, w + 2.0);
}

pub fn compute(s: *Session, max_h: f64) Geom {
    var g = Geom{
        .time_w = measuredTimeW(s),
        .shift_y = k_header_h,
        .slider_y = k_header_h + k_slider_dy,
        .footer_y = k_header_h + k_shift_h,
    };
    const max_list = @max(24.0, max_h - k_header_h - k_shift_h - k_footer_h);
    g.rows = s.count();
    g.content_h = @as(f64, @floatFromInt(g.rows)) * k_row_h;
    g.list_h = @min(g.content_h, max_list);
    g.max_scroll = @max(0.0, g.content_h - g.list_h);
    g.shift_y = g.list_y + g.list_h;
    g.slider_y = g.shift_y + k_slider_dy;
    g.footer_y = g.shift_y + k_shift_h;
    g.total_h = k_header_h + g.list_h + k_shift_h + k_footer_h;
    return g;
}

// ---------------------------------------------------------------------------
// Element rectangles (card-local)

fn rowRect(g: *const Geom, s: *const Session, i: usize) Rect {
    return .{
        .x = list_ph,
        .y = g.list_y + @as(f64, @floatFromInt(i)) * g.row_h - s.p.scroll_list,
        .w = g.w - 2.0 * list_ph,
        .h = g.row_h,
    };
}

fn actsOf(s: *const Session, i: usize) f64 {
    return if (Session.isLocal(s.idAt(i))) act_sz else act_sz * 2.0;
}

fn actsX(g: *const Geom, s: *const Session, i: usize) f64 {
    return g.w - list_ph - row_ph - g.time_w - row_gap - actsOf(s, i);
}

fn actRect(g: *const Geom, s: *const Session, i: usize, which: u1) Rect {
    const ry = rowRect(g, s, i).y;
    const cx = actsX(g, s, i) + @as(f64, @floatFromInt(which)) * act_sz;
    return .{ .x = cx, .y = ry + (g.row_h - act_sz) * 0.5, .w = act_sz, .h = act_sz };
}

fn sliderBand(g: *const Geom) Rect {
    return .{ .x = 16.0, .y = g.slider_y, .w = g.w - 32.0, .h = slider_h };
}

fn resetRect(g: *const Geom, cr: ?*cairo.cairo_t) Rect {
    const w = textW(cr, "Reset", "", shift_px);
    return .{
        .x = g.w - 16.0 - w,
        .y = g.shift_y + k_slider_dy - shift_mt - k_shift_text_h,
        .w = w,
        .h = k_shift_text_h,
    };
}

fn swRects(g: *const Geom, cr: ?*cairo.cairo_t) struct { t1: Rect, h1: Rect, t2: Rect, h2: Rect } {
    const top = g.footer_y + foot_pt + (k_footer_content - sw_h) * 0.5;
    const x1 = 16.0;
    const w1 = textW(cr, "24-hour", "", shift_px);
    const x2 = 16.0 + sw_w + sw_label_gap + w1 + sw_gap;
    const w2 = textW(cr, "Seconds", "", shift_px);
    return .{
        .t1 = .{ .x = x1, .y = top, .w = sw_w, .h = sw_h },
        .h1 = .{ .x = x1, .y = g.footer_y + foot_pt, .w = sw_w + sw_label_gap + w1, .h = k_footer_content },
        .t2 = .{ .x = x2, .y = top, .w = sw_w, .h = sw_h },
        .h2 = .{ .x = x2, .y = g.footer_y + foot_pt, .w = sw_w + sw_label_gap + w2, .h = k_footer_content },
    };
}

fn rowAt(g: *const Geom, s: *const Session, py: f64) ?usize {
    if (py < g.list_y or py >= g.list_y + g.list_h) return null;
    const y = py - g.list_y + s.p.scroll_list;
    const i: usize = @intFromFloat(y / g.row_h);
    if (i >= g.rows) return null;
    return i;
}

/// Slider minutes for a card-local pointer x (unsnapped; `setShift` snaps).
fn shiftFromX(g: *const Geom, px: f64) i32 {
    const x0 = 16.0 + thumb_d * 0.5;
    const x1 = g.w - 16.0 - thumb_d * 0.5;
    const t = std.math.clamp((px - x0) / (x1 - x0), 0.0, 1.0);
    return @intFromFloat(@round(t * 1440.0 - 720.0));
}

fn swT(s: *const Session, on: bool, start: u64, now_ms: u64) f64 {
    const t = if (s.reduce_motion) 1.0 else progress(start, k_sw_ms, now_ms);
    const e = session_mod.bezierEase(0.2, 0.7, 0.2, 1.0, t);
    return if (on) e else 1.0 - e;
}

fn progress(start: u64, dur: u64, now_ms: u64) f64 {
    return std.math.clamp(@as(f64, @floatFromInt(now_ms -| start)) / @as(f64, @floatFromInt(dur)), 0.0, 1.0);
}

fn shiftedNow(s: *const Session, now_ms: u64) i64 {
    const now_sec = @divFloor(@as(i64, @intCast(now_ms)), 1000);
    return s.popupInstant(now_sec);
}

// ---------------------------------------------------------------------------
// Paint

fn setInk(c: *cairo.cairo_t, col: Rgb, a: f64) void {
    cairo.cairo_set_source_rgba(c, col.r, col.g, col.b, a);
}

fn wash(c: *cairo.cairo_t, r: Rect, rad: f64, col: Rgb, a: f64) void {
    helpers.roundedRect(c, r.x, r.y, r.w, r.h, rad);
    setInk(c, col, a);
    cairo.cairo_fill(c);
}

fn focusRing(c: *cairo.cairo_t, r: Rect, rad: f64, col: Rgb) void {
    helpers.roundedRect(c, r.x - 3.0, r.y - 3.0, r.w + 6.0, r.h + 6.0, rad + 3.0);
    cairo.cairo_set_line_width(c, 2.0);
    setInk(c, col, 1.0);
    cairo.cairo_stroke(c);
}

fn drawLine(
    c: *cairo.cairo_t,
    str: []const u8,
    x: f64,
    y: f64,
    weight: []const u8,
    px: f64,
    col: Rgb,
    a: f64,
    max_w: f64,
) void {
    if (str.len == 0) return;
    var l = text.Layout.createForCairo(c);
    defer l.destroy();
    setFont(&l, weight, px);
    l.setText(str);
    if (max_w > 0) {
        l.setWidthUnits(@intFromFloat(max_w * 1024.0));
        l.setEllipsize(text.ELLIPSIZE_END);
    }
    cairo.cairo_move_to(c, x, y);
    setInk(c, col, a);
    l.show(c);
}

/// `bg` is the panel plate's alpha (0.0-1.0): the Appearance → Opacity
/// "World clock" knob resolved through `overlay.scale(.world_clock)` (design
/// 1.0, so 100% is the solid plate). Only the plate — the card fill and its
/// 1px rim — takes it; the rows, text, switches and icons stay fully inked,
/// so a see-through panel still reads. The value is read at paint time, so
/// dragging the slider updates a panel that is already up.
pub fn paint(cr: ?*cairo.cairo_t, s: *Session, g: *const Geom, mc: chrome.Chrome, bg: f64, now_ms: u64) void {
    const c = cr orelse return;
    const t: f64 = if (s.reduce_motion) 1.0 else progress(s.p.open_ms, k_open_ms, now_ms);
    if (t >= 1.0) {
        paintBody(c, s, g, mc, bg, now_ms);
        return;
    }
    // Entrance: 160ms, 0.98 scale and 6px lower, anchored bottom-right. The
    // whole card fades as one through this group (the transforms collapse
    // to identity at `e == 1`); the steady-state plate alpha is separate.
    const e = session_mod.bezierEase(0.2, 0.7, 0.2, 1.0, t);
    cairo.cairo_push_group(c);
    cairo.cairo_save(c);
    const bx = k_shadow_pad + g.w;
    const by = k_shadow_pad + g.total_h;
    cairo.cairo_translate(c, bx, by);
    const sc = 0.98 + 0.02 * e;
    cairo.cairo_scale(c, sc, sc);
    cairo.cairo_translate(c, -bx, -by);
    cairo.cairo_translate(c, 0, 6.0 * (1.0 - e));
    paintBody(c, s, g, mc, bg, now_ms);
    cairo.cairo_restore(c);
    cairo.cairo_pop_group_to_source(c);
    cairo.cairo_paint_with_alpha(c, e);
}

fn paintBody(c: *cairo.cairo_t, s: *Session, g: *const Geom, mc: chrome.Chrome, bg: f64, now_ms: u64) void {
    const pad = k_shadow_pad;
    // The plate — card fill and its 1px line border — is the only thing the
    // background knob fades; everything painted after it is content.
    const plate = std.math.clamp(bg, 0.0, 1.0);
    helpers.roundedRect(c, pad, pad, g.w, g.total_h, k_radius);
    setInk(c, mc.panel_fill, plate);
    cairo.cairo_fill(c);
    helpers.roundedRect(c, pad + 0.5, pad + 0.5, g.w - 1.0, g.total_h - 1.0, k_radius - 0.5);
    cairo.cairo_set_line_width(c, 1.0);
    setInk(c, mc.text, 0.09 * plate);
    cairo.cairo_stroke(c);

    paintHeader(c, s, mc, now_ms);

    cairo.cairo_save(c);
    cairo.cairo_rectangle(c, pad, pad + g.list_y, g.w, g.list_h);
    cairo.cairo_clip(c);
    for (0..g.rows) |i| paintRow(c, s, g, mc, i, now_ms);
    cairo.cairo_restore(c);

    paintScrollbar(c, s, g, mc);
    paintShift(c, s, g, mc, now_ms);
    paintFooter(c, s, g, mc, now_ms);
}

fn paintHeader(c: *cairo.cairo_t, s: *Session, mc: chrome.Chrome, now_ms: u64) void {
    const pad = k_shadow_pad;
    const t = shiftedNow(s, now_ms);
    const civ = s.wallOf("", t);
    var dbuf: [48]u8 = undefined;
    const date = std.fmt.bufPrint(&dbuf, "{d} {s} {d}", .{ civ.d, session_mod.monthName(civ.mo), civ.y }) catch "";
    drawLine(c, session_mod.weekdayName(civ.wday), pad + hdr_pl, pad + hdr_pt, "SemiBold ", weekday_px, mc.text, 1.0, 0);
    drawLine(c, date, pad + hdr_pl, pad + hdr_pt + k_weekday_h, "", date_px, mc.outline, 1.0, 0);
}

fn rowActsAlpha(s: *const Session, i: usize, pinned_row: bool, now_ms: u64) f64 {
    const vis = pinned_row or s.p.hover_row == @as(i32, @intCast(i)) or
        (switch (s.p.focus) {
            .pin => |f| f == i,
            .del => |f| f == i,
            else => false,
        });
    if (s.reduce_motion) return if (vis) 1.0 else 0.0;
    if (vis) {
        if (pinned_row or s.p.hover_row != @as(i32, @intCast(i))) return 1.0;
        const e = session_mod.bezierEase(0.2, 0.7, 0.2, 1.0, progress(s.p.hover_ms, k_fade_ms, now_ms));
        return e;
    }
    if (s.p.prev_hover_row == @as(i32, @intCast(i))) {
        const e = session_mod.bezierEase(0.2, 0.7, 0.2, 1.0, progress(s.p.hover_ms, k_fade_ms, now_ms));
        return 1.0 - e;
    }
    return 0.0;
}

/// The row background wash's own envelope: it fades in on the row the
/// pointer entered and out on the one it left, over the same `k_fade_ms` the
/// row's action buttons use. Drawing the previous row's wash at full strength
/// instead is what left two rows looking hovered at once — it never faded,
/// it only stopped being painted when a third row was entered.
fn rowWashAlpha(s: *const Session, i: usize, now_ms: u64) f64 {
    const self_hover = s.p.hover_row == @as(i32, @intCast(i));
    if (!self_hover and s.p.prev_hover_row != @as(i32, @intCast(i))) return 0.0;
    if (s.reduce_motion) return if (self_hover) 1.0 else 0.0;
    const e = session_mod.bezierEase(0.2, 0.7, 0.2, 1.0, progress(s.p.hover_ms, k_fade_ms, now_ms));
    return if (self_hover) e else 1.0 - e;
}

fn paintRow(c: *cairo.cairo_t, s: *Session, g: *const Geom, mc: chrome.Chrome, i: usize, now_ms: u64) void {
    const pad = k_shadow_pad;
    const r = rowRect(g, s, i);
    if (r.y + r.h < g.list_y or r.y > g.list_y + g.list_h) return;
    const wa = rowWashAlpha(s, i, now_ms);
    if (wa > 0.01)
        wash(c, .{ .x = pad + r.x, .y = pad + r.y, .w = r.w, .h = r.h }, row_r, mc.text, 0.06 * wa);

    const id = s.idAt(i);
    const t = shiftedNow(s, now_ms);
    const tv = s.wallOf(id, t);

    // Day / night icon.
    const day = tv.h >= 6 and tv.h < 18;
    _ = svg.draw(c, if (day) "sunny" else "dark_mode", pad + r.x + row_ph + icon_col * 0.5, pad + r.y + r.h * 0.5, day_icon, mc.outline.r, mc.outline.g, mc.outline.b, 1.0, false);

    const pinned_row = s.pinned() and s.current() == i;
    const acts_w = actsOf(s, i);
    const name_w = r.w - 2.0 * row_ph - icon_col - row_gap - acts_w - row_gap - g.time_w - row_gap;
    const name_x = pad + r.x + row_ph + icon_col + row_gap;
    const top = pad + r.y + row_pv + (k_row_content - k_who_h) * 0.5;
    const name = s.nameOf(id);
    drawLine(c, name, name_x, top, "Medium ", name_px, mc.text, 1.0, @max(4.0, name_w));
    var sbuf: [48]u8 = undefined;
    const sub = s.subline(&sbuf, id, t);
    drawLine(c, sub, name_x, top + k_name_h, "", sub_px, mc.outline, 1.0, @max(4.0, name_w));

    // Actions: pin and (non-local) remove, fading with the row hover.
    const a = rowActsAlpha(s, i, pinned_row, now_ms);
    if (a > 0.01) {
        const pin_r = actRect(g, s, i, 0);
        if (pinned_row) {
            wash(c, .{ .x = pad + pin_r.x, .y = pad + pin_r.y, .w = pin_r.w, .h = pin_r.h }, act_r, mc.accent, 0.14);
        } else if (hoverPin(s.p.hover, i)) {
            wash(c, .{ .x = pad + pin_r.x, .y = pad + pin_r.y, .w = pin_r.w, .h = pin_r.h }, act_r, mc.text, 0.06);
        }
        if (focusPin(s.p.focus, i) and s.p.focus_visible) focusRing(c, .{ .x = pad + pin_r.x, .y = pad + pin_r.y, .w = pin_r.w, .h = pin_r.h }, act_r, mc.accent);
        const pin_col = if (pinned_row or hoverPin(s.p.hover, i)) mc.accent else mc.outline;
        _ = svg.draw(c, "push_pin", pad + pin_r.x + act_sz * 0.5, pad + pin_r.y + act_sz * 0.5, 16.0, pin_col.r, pin_col.g, pin_col.b, a, false);
        if (!Session.isLocal(id)) {
            const del_r = actRect(g, s, i, 1);
            const del_hov = hoverDel(s.p.hover, i);
            if (del_hov) wash(c, .{ .x = pad + del_r.x, .y = pad + del_r.y, .w = del_r.w, .h = del_r.h }, act_r, mc.notif_ol, 0.12);
            if (focusDel(s.p.focus, i) and s.p.focus_visible) focusRing(c, .{ .x = pad + del_r.x, .y = pad + del_r.y, .w = del_r.w, .h = del_r.h }, act_r, mc.accent);
            const del_col = if (del_hov) mc.notif_ol else mc.outline;
            _ = svg.draw(c, "close", pad + del_r.x + act_sz * 0.5, pad + del_r.y + act_sz * 0.5, 16.0, del_col.r, del_col.g, del_col.b, a, false);
        }
    }

    // Time: right aligned, tabular; accent while shifted.
    const time_r = pad + r.x + r.w - row_ph;
    const hm_col = if (s.p.shift_min != 0) mc.accent else mc.text;
    const tvv = session_mod.timeVec(tv, s.h24, s.sec);
    var l = text.Layout.createForCairo(c);
    defer l.destroy();
    l.setFontFeatures("tnum 1");
    setFont(&l, "Medium ", hm_px);
    const hm = tvv.hm();
    l.setText(hm);
    const hm_w: f64 = @floatFromInt(l.pixelSize().w);
    const hm_b = l.baseline();
    var tw = hm_w;
    var ss_w: f64 = 0;
    var ap_w: f64 = 0;
    if (tvv.ss().len > 0) {
        setFont(&l, "", sm_px);
        l.setText(tvv.ss());
        ss_w = @floatFromInt(l.pixelSize().w);
        tw += sm_margin + ss_w;
    }
    if (tvv.ap().len > 0) {
        setFont(&l, "", sm_px);
        l.setText(tvv.ap());
        ap_w = @floatFromInt(l.pixelSize().w);
        tw += sm_margin + ap_w;
    }
    const time_top = pad + r.y + row_pv + (k_row_content - k_hm_h) * 0.5;
    var x = time_r - tw;
    setFont(&l, "Medium ", hm_px);
    l.setText(hm);
    cairo.cairo_move_to(c, x, time_top);
    setInk(c, hm_col, 1.0);
    l.show(c);
    x += hm_w;
    if (ss_w > 0) {
        setFont(&l, "", sm_px);
        l.setText(tvv.ss());
        cairo.cairo_move_to(c, x + sm_margin, time_top + (hm_b - l.baseline()));
        setInk(c, mc.outline, 1.0);
        l.show(c);
        x += sm_margin + ss_w;
    }
    if (ap_w > 0) {
        setFont(&l, "", sm_px);
        l.setText(tvv.ap());
        cairo.cairo_move_to(c, x + sm_margin, time_top + (hm_b - l.baseline()));
        setInk(c, mc.outline, 1.0);
        l.show(c);
    }
}

fn paintShift(c: *cairo.cairo_t, s: *Session, g: *const Geom, mc: chrome.Chrome, now_ms: u64) void {
    _ = now_ms;
    const pad = k_shadow_pad;
    // Top line border spanning the section's 16px side margins.
    cairo.cairo_set_line_width(c, 1.0);
    setInk(c, mc.text, 0.09);
    cairo.cairo_move_to(c, pad + 16.0, pad + g.shift_y + shift_mt + 0.5);
    cairo.cairo_line_to(c, pad + g.w - 16.0, pad + g.shift_y + shift_mt + 0.5);
    cairo.cairo_stroke(c);

    const row_y = pad + g.shift_y + shift_mt + 1.0 + shift_pt;
    drawLine(c, "Time shift", pad + 16.0, row_y, "", shift_px, mc.outline, 1.0, 0);
    var vbuf: [24]u8 = undefined;
    const val = if (s.p.shift_min == 0) "Now" else session_mod.durText(&vbuf, s.p.shift_min);
    var val_r = pad + g.w - 16.0;
    if (s.p.shift_min != 0) {
        const rr = resetRect(g, c);
        const rw = rr.w;
        val_r = pad + rr.x - reset_gap;
        const rh = s.p.hover == .reset;
        if (rh) {
            // Underline on hover, like the reference's text-decoration.
            cairo.cairo_set_line_width(c, 1.0);
            setInk(c, mc.accent, 0.9);
            cairo.cairo_move_to(c, pad + rr.x, row_y + k_shift_text_h - 0.5);
            cairo.cairo_line_to(c, pad + rr.x + rw, row_y + k_shift_text_h - 0.5);
            cairo.cairo_stroke(c);
        }
        if (s.p.focus == .reset and s.p.focus_visible)
            focusRing(c, .{ .x = pad + rr.x, .y = pad + rr.y, .w = rr.w, .h = rr.h }, 4.0, mc.accent);
        drawLine(c, "Reset", pad + rr.x, row_y, "", shift_px, if (rh) mc.text else mc.accent, 1.0, 0);
    }
    const vw = textW(c, val, "Medium ", shift_px);
    drawLine(c, val, val_r - vw, row_y, "Medium ", shift_px, if (s.p.shift_min != 0) mc.accent else mc.text, 1.0, 0);

    // Slider.
    const cy = pad + g.slider_y + slider_h * 0.5;
    helpers.roundedRect(c, pad + 16.0, cy - track_h * 0.5, g.w - 32.0, track_h, track_r);
    setInk(c, mc.text, 0.10);
    cairo.cairo_fill(c);
    const t = (@as(f64, @floatFromInt(s.p.shift_min)) + 720.0) / 1440.0;
    const tx = pad + 16.0 + thumb_d * 0.5 + t * (g.w - 32.0 - thumb_d);
    if (s.p.focus == .slider and s.p.focus_visible) {
        cairo.cairo_arc(c, tx, cy, 13.0, 0.0, 2.0 * k_pi);
        setInk(c, mc.accent, 0.25);
        cairo.cairo_fill(c);
    }
    cairo.cairo_arc(c, tx, cy, thumb_d * 0.5 - 1.0, 0.0, 2.0 * k_pi);
    setInk(c, mc.accent, 1.0);
    cairo.cairo_fill(c);
    cairo.cairo_arc(c, tx, cy, thumb_d * 0.5 - 0.75, 0.0, 2.0 * k_pi);
    cairo.cairo_set_line_width(c, 1.5);
    setInk(c, mc.panel_fill, 1.0);
    cairo.cairo_stroke(c);
}

fn paintSwitch(c: *cairo.cairo_t, r: Rect, on: bool, t: f64, mc: chrome.Chrome) void {
    const pad = k_shadow_pad;
    const x = pad + r.x;
    const y = pad + r.y;
    helpers.roundedRect(c, x, y, sw_w, sw_h, sw_r);
    if (on) {
        setInk(c, mc.accent, 0.25 + 0.75 * t);
    } else {
        setInk(c, mc.text, 0.10);
    }
    cairo.cairo_fill(c);
    helpers.roundedRect(c, x + 0.5, y + 0.5, sw_w - 1.0, sw_h - 1.0, sw_r);
    cairo.cairo_set_line_width(c, 1.0);
    if (on) {
        setInk(c, mc.accent, 0.3 + 0.7 * t);
    } else {
        setInk(c, mc.text, 0.09);
    }
    cairo.cairo_stroke(c);
    const off = sw_thumb_off + sw_travel * (if (on) t else 1.0 - t);
    const cx = x + off + sw_thumb * 0.5;
    const cy = y + sw_h * 0.5;
    cairo.cairo_arc(c, cx, cy, sw_thumb * 0.5, 0.0, 2.0 * k_pi);
    const thumb = if (on) Rgb{ .r = 1, .g = 1, .b = 1 } else mc.outline;
    setInk(c, thumb, 1.0);
    cairo.cairo_fill(c);
}

fn paintFooter(c: *cairo.cairo_t, s: *Session, g: *const Geom, mc: chrome.Chrome, now_ms: u64) void {
    const pad = k_shadow_pad;
    const sr = swRects(g, c);
    paintSwitch(c, sr.t1, s.h24, swT(s, s.h24, s.p.sw_h24_ms, now_ms), mc);
    if (s.p.focus == .sw_h24 and s.p.focus_visible) focusRing(c, .{ .x = pad + sr.h1.x, .y = pad + sr.h1.y, .w = sr.h1.w, .h = sr.h1.h }, sw_r, mc.accent);
    drawLine(c, "24-hour", pad + sr.h1.x + sw_w + sw_label_gap, pad + sr.h1.y + (k_footer_content - k_shift_text_h) * 0.5, "", shift_px, mc.outline, 1.0, 0);
    paintSwitch(c, sr.t2, s.sec, swT(s, s.sec, s.p.sw_sec_ms, now_ms), mc);
    if (s.p.focus == .sw_sec and s.p.focus_visible) focusRing(c, .{ .x = pad + sr.h2.x, .y = pad + sr.h2.y, .w = sr.h2.w, .h = sr.h2.h }, sw_r, mc.accent);
    drawLine(c, "Seconds", pad + sr.h2.x + sw_w + sw_label_gap, pad + sr.h2.y + (k_footer_content - k_shift_text_h) * 0.5, "", shift_px, mc.outline, 1.0, 0);
}

fn paintScrollbar(c: *cairo.cairo_t, s: *const Session, g: *const Geom, mc: chrome.Chrome) void {
    if (g.max_scroll <= 0.001) return;
    const pad = k_shadow_pad;
    const th = @max(24.0, g.list_h * (g.list_h / g.content_h));
    const y = g.list_y + (g.list_h - th) * (s.p.scroll_list / g.max_scroll);
    helpers.roundedRect(c, pad + g.w - 5.5, pad + y + 1.0, 3.0, th - 2.0, 1.5);
    setInk(c, mc.outline, 0.45);
    cairo.cairo_fill(c);
}

// ---------------------------------------------------------------------------
// Input

fn cycleFocus(s: *Session, g: *const Geom, back: bool) void {
    var buf: [96]Focus = undefined;
    var n: usize = 0;
    for (0..s.count()) |i| {
        buf[n] = .{ .pin = i };
        n += 1;
        if (!Session.isLocal(s.idAt(i))) {
            buf[n] = .{ .del = i };
            n += 1;
        }
    }
    buf[n] = .slider;
    n += 1;
    if (s.p.shift_min != 0) {
        buf[n] = .reset;
        n += 1;
    }
    buf[n] = .sw_h24;
    n += 1;
    buf[n] = .sw_sec;
    n += 1;

    var cur: ?usize = null;
    for (buf[0..n], 0..) |f, i| {
        if (std.meta.eql(f, s.p.focus)) {
            cur = i;
            break;
        }
    }
    const idx = if (cur) |ci|
        (if (back) (ci + n - 1) % n else (ci + 1) % n)
    else
        0;
    s.p.focus = buf[idx];
    s.p.focus_visible = true;
    _ = g;
}

fn setH24(s: *Session, v: bool, now_ms: u64, out: *Outcome) void {
    s.setH24(v);
    s.p.sw_h24_ms = now_ms;
    out.handled = true;
    out.repaint = true;
    out.face = true;
    out.saved = true;
}

fn setSec(s: *Session, v: bool, now_ms: u64, out: *Outcome) void {
    s.setSec(v);
    s.p.sw_sec_ms = now_ms;
    out.handled = true;
    out.repaint = true;
    out.saved = true;
}

fn activate(s: *Session, now_ms: u64, out: *Outcome) void {
    switch (s.p.focus) {
        .none => {},
        .pin => |i| {
            s.togglePinAt(i);
            out.handled = true;
            out.repaint = true;
            out.face = true;
            out.saved = true;
        },
        .del => |i| {
            s.removeAt(i);
            out.handled = true;
            out.repaint = true;
            out.relayout = true;
            out.face = true;
            out.saved = true;
        },
        .slider => {},
        .reset => {
            s.resetShift();
            out.handled = true;
            out.repaint = true;
        },
        .sw_h24 => setH24(s, !s.h24, now_ms, out),
        .sw_sec => setSec(s, !s.sec, now_ms, out),
    }
}

fn setShiftFromX(s: *Session, g: *const Geom, px: f64, out: *Outcome) void {
    const before = s.p.shift_min;
    s.setShift(shiftFromX(g, px));
    if (s.p.shift_min != before) out.repaint = true;
    out.handled = true;
}

/// Pointer press at padded surface coordinates (as routed from the seat).
pub fn press(s: *Session, g: *const Geom, px_pad: f64, py_pad: f64, now_ms: u64) Outcome {
    const px = px_pad - k_shadow_pad;
    const py = py_pad - k_shadow_pad;
    var out = Outcome{ .handled = true };
    s.p.focus_visible = false;
    if (rowAt(g, s, py)) |i| {
        if (hit(actRect(g, s, i, 0), px, py)) {
            s.togglePinAt(i);
            out.repaint = true;
            out.face = true;
            out.saved = true;
            return out;
        }
        if (!Session.isLocal(s.idAt(i)) and hit(actRect(g, s, i, 1), px, py)) {
            s.removeAt(i);
            out.repaint = true;
            out.relayout = true;
            out.face = true;
            out.saved = true;
            return out;
        }
        return out;
    }
    if (hit(sliderBand(g), px, py)) {
        s.p.dragging_slider = true;
        s.p.focus = .slider;
        setShiftFromX(s, g, px, &out);
        return out;
    }
    if (s.p.shift_min != 0) {
        const rr = resetRect(g, measure.measureCr());
        if (hit(rr, px, py)) {
            s.resetShift();
            out.repaint = true;
            return out;
        }
    }
    const sr = swRects(g, measure.measureCr());
    if (hit(sr.h1, px, py)) {
        setH24(s, !s.h24, now_ms, &out);
        return out;
    }
    if (hit(sr.h2, px, py)) {
        setSec(s, !s.sec, now_ms, &out);
        return out;
    }
    return out;
}

/// Pointer motion at padded surface coordinates.
pub fn motion(s: *Session, g: *const Geom, px_pad: f64, py_pad: f64, now_ms: u64) Outcome {
    const px = px_pad - k_shadow_pad;
    const py = py_pad - k_shadow_pad;
    var out = Outcome{};
    const in_card = px >= 0 and py >= 0 and px <= g.w and py <= g.total_h;
    var target: HoverTarget = .none;
    var new_row: i32 = -1;
    if (in_card) {
        if (rowAt(g, s, py)) |i| {
            new_row = @intCast(i);
            if (hit(actRect(g, s, i, 0), px, py)) {
                target = .{ .row_pin = i };
            } else if (!Session.isLocal(s.idAt(i)) and hit(actRect(g, s, i, 1), px, py)) {
                target = .{ .row_del = i };
            }
        } else if (hit(sliderBand(g), px, py)) {
            target = .slider;
        } else if (s.p.shift_min != 0 and hit(resetRect(g, measure.measureCr()), px, py)) {
            target = .reset;
        } else {
            const sr = swRects(g, measure.measureCr());
            if (hit(sr.h1, px, py)) {
                target = .sw_h24;
            } else if (hit(sr.h2, px, py)) {
                target = .sw_sec;
            }
        }
    }
    if (new_row != s.p.hover_row) {
        s.p.prev_hover_row = s.p.hover_row;
        s.p.hover_row = new_row;
        s.p.hover_ms = now_ms;
        out.repaint = true;
    }
    if (!std.meta.eql(target, s.p.hover)) {
        s.p.hover = target;
        out.repaint = true;
    }
    if (s.p.dragging_slider) setShiftFromX(s, g, px, &out);
    out.handled = out.repaint;
    return out;
}

pub fn release(s: *Session) Outcome {
    var out = Outcome{};
    if (s.p.dragging_slider) {
        s.p.dragging_slider = false;
        out.handled = true;
    }
    return out;
}

pub fn scroll(s: *Session, g: *const Geom, delta: f64) Outcome {
    var out = Outcome{ .handled = true };
    if (g.max_scroll <= 0.0) return out;
    const step = std.math.clamp(delta * 40.0, -240.0, 240.0);
    s.p.scroll_list = std.math.clamp(s.p.scroll_list + step, 0.0, g.max_scroll);
    out.repaint = true;
    return out;
}

pub const KeySym = struct {
    pub const esc: u32 = 0xff1b;
    pub const backspace: u32 = 0xff08;
    pub const tab: u32 = 0xff09;
    pub const ret: u32 = 0xff0d;
    pub const kp_enter: u32 = 0xff8d;
    pub const home: u32 = 0xff50;
    pub const left: u32 = 0xff51;
    pub const up: u32 = 0xff52;
    pub const right: u32 = 0xff53;
    pub const down: u32 = 0xff54;
    pub const end: u32 = 0xff57;
    pub const space: u32 = 0x20;
};

pub fn key(s: *Session, g: *const Geom, sym: u32, utf8: []const u8, pressed: bool, shift: bool, now_ms: u64) Outcome {
    // The popup has no text field since the add pane moved to settings.
    _ = utf8;
    var out = Outcome{};
    if (!pressed) {
        out.handled = switch (sym) {
            KeySym.esc, KeySym.tab, KeySym.ret, KeySym.kp_enter, KeySym.space, KeySym.backspace => true,
            else => false,
        };
        return out;
    }
    switch (sym) {
        KeySym.esc => {
            out.close = true;
            out.handled = true;
        },
        KeySym.tab => {
            cycleFocus(s, g, shift);
            out.repaint = true;
            out.handled = true;
        },
        KeySym.ret, KeySym.kp_enter => {
            activate(s, now_ms, &out);
        },
        KeySym.space => {
            activate(s, now_ms, &out);
        },
        KeySym.left, KeySym.down, KeySym.up, KeySym.right => {
            if (s.p.focus == .slider) {
                const d: i32 = switch (sym) {
                    KeySym.left, KeySym.down => -30,
                    else => 30,
                };
                s.setShift(s.p.shift_min + d);
                out.repaint = true;
                out.handled = true;
            }
        },
        KeySym.home, KeySym.end => {
            if (s.p.focus == .slider) {
                s.setShift(if (sym == KeySym.home) -720 else 720);
                out.repaint = true;
                out.handled = true;
            }
        },
        else => {},
    }
    return out;
}

/// True while any popup transition needs frames.
pub fn animActive(s: *const Session, now_ms: u64) bool {
    if (s.reduce_motion or !s.open) return false;
    if (now_ms < s.p.open_ms +| k_open_ms) return true;
    if (now_ms < s.p.sw_h24_ms +| k_sw_ms) return true;
    if (now_ms < s.p.sw_sec_ms +| k_sw_ms) return true;
    if (s.p.hover_row != s.p.prev_hover_row and now_ms < s.p.hover_ms +| k_fade_ms) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Start a session whose io outlives it: the threaded runtime must live in
/// the caller's frame.
fn startSession(threaded: *std.Io.Threaded) Session {
    threaded.* = .init(testing.allocator, .{});
    return Session.init(testing.allocator, threaded.io());
}

test "wc-panel: compute hugs content and caps the list" {
    var threaded: std.Io.Threaded = undefined;
    defer threaded.deinit();
    var s = startSession(&threaded);
    defer s.deinit();
    const g = compute(&s, 1000.0);
    try testing.expectApproxEqAbs(k_header_h + k_row_h + k_shift_h + k_footer_h, g.total_h, 1e-9);
    try testing.expectApproxEqAbs(k_row_h, g.list_h, 1e-9);
    try testing.expectEqual(@as(usize, 1), g.rows);

    // A short screen caps the list and enables scrolling.
    _ = s.addCity("Europe/London");
    _ = s.addCity("Asia/Tokyo");
    _ = s.addCity("Australia/Sydney");
    const g2 = compute(&s, 220.0);
    try testing.expect(g2.list_h < g2.content_h);
    try testing.expect(g2.max_scroll > 0);
    try testing.expectApproxEqAbs(220.0, g2.total_h, 1e-6);
}

test "wc-panel: press where the add button was does nothing" {
    var threaded: std.Io.Threaded = undefined;
    defer threaded.deinit();
    var s = startSession(&threaded);
    defer s.deinit();
    _ = s.addCity("Europe/London");
    _ = s.addCity("Asia/Tokyo");
    const g = compute(&s, 1000.0);
    const before = s.count();
    // The old + button sat 30x30 in the header's top-right corner. The add
    // pane is gone: a press there is handled but changes nothing.
    const ax = k_w - 12.0 - 30.0;
    const ay = hdr_pt + (k_hdr_text_h - 30.0) * 0.5;
    const out = press(&s, &g, k_shadow_pad + ax + 4, k_shadow_pad + ay + 4, 1000);
    try testing.expect(out.handled);
    try testing.expect(!out.repaint and !out.relayout and !out.face and !out.saved);
    try testing.expect(s.p.focus == .none);
    try testing.expectEqual(before, s.count());
    try testing.expectEqual(@as(i32, 0), s.p.shift_min);
}

test "wc-panel: only the row under the pointer keeps its wash" {
    var threaded: std.Io.Threaded = undefined;
    defer threaded.deinit();
    var s = startSession(&threaded);
    defer s.deinit();
    _ = s.addCity("Europe/London");
    _ = s.addCity("Asia/Tokyo");
    const g = compute(&s, 1000.0);
    // Into row 0, then straight down into row 1. Both may wash for the
    // length of the crossfade, but once it has run out only row 1 is lit —
    // the bug this pins painted row 0 at full strength until some third
    // row was entered.
    const r0 = rowRect(&g, &s, 0);
    _ = motion(&s, &g, k_shadow_pad + g.w * 0.5, k_shadow_pad + r0.y + r0.h * 0.5, 1_000);
    try testing.expectEqual(@as(i32, 0), s.p.hover_row);
    const r1 = rowRect(&g, &s, 1);
    _ = motion(&s, &g, k_shadow_pad + g.w * 0.5, k_shadow_pad + r1.y + r1.h * 0.5, 1_010);
    try testing.expectEqual(@as(i32, 1), s.p.hover_row);
    try testing.expectApproxEqAbs(@as(f64, 0.0), rowWashAlpha(&s, 0, 1_010 + k_fade_ms), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), rowWashAlpha(&s, 1, 1_010 + k_fade_ms), 1e-9);
    // Mid-fade both are up, each at its own strength.
    const a0 = rowWashAlpha(&s, 0, 1_010 + k_fade_ms / 2);
    const a1 = rowWashAlpha(&s, 1, 1_010 + k_fade_ms / 2);
    try testing.expect(a0 > 0.0 and a0 < 1.0);
    try testing.expect(a1 > 0.0 and a1 < 1.0);
}

test "wc-panel: Esc closes the popup" {
    var threaded: std.Io.Threaded = undefined;
    defer threaded.deinit();
    var s = startSession(&threaded);
    defer s.deinit();
    const g = compute(&s, 1000.0);
    const out = key(&s, &g, KeySym.esc, "", true, false, 1000);
    try testing.expect(out.close);
}

test "wc-panel: slider press shifts and clamps" {
    var threaded: std.Io.Threaded = undefined;
    defer threaded.deinit();
    var s = startSession(&threaded);
    defer s.deinit();
    const g = compute(&s, 1000.0);
    const band = sliderBand(&g);
    // Far right: +720. Far left: -720. Center: 0.
    _ = press(&s, &g, k_shadow_pad + band.x + band.w - 1.0, k_shadow_pad + band.y + 9.0, 1000);
    try testing.expectEqual(@as(i32, 720), s.p.shift_min);
    _ = press(&s, &g, k_shadow_pad + band.x + 1.0, k_shadow_pad + band.y + 9.0, 1100);
    try testing.expectEqual(@as(i32, -720), s.p.shift_min);
    _ = press(&s, &g, k_shadow_pad + k_w * 0.5, k_shadow_pad + band.y + 9.0, 1200);
    try testing.expectEqual(@as(i32, 0), s.p.shift_min);
}

test "wc-panel: pin press flips, remove press drops" {
    var threaded: std.Io.Threaded = undefined;
    defer threaded.deinit();
    var s = startSession(&threaded);
    defer s.deinit();
    _ = s.addCity("Europe/London");
    _ = s.addCity("Asia/Tokyo");
    const g = compute(&s, 1000.0);
    const pin1 = actRect(&g, &s, 1, 0);
    var out = press(&s, &g, k_shadow_pad + pin1.x + 4, k_shadow_pad + pin1.y + 4, 1000);
    try testing.expect(out.face);
    try testing.expectEqualStrings("Europe/London", s.pin_id.?);

    const del1 = actRect(&g, &s, 1, 1);
    out = press(&s, &g, k_shadow_pad + del1.x + 4, k_shadow_pad + del1.y + 4, 1100);
    try testing.expect(out.relayout);
    try testing.expect(!s.containsStored("Europe/London"));
    try testing.expect(s.pin_id == null);
}

test "wc-panel: switch clicks set settings and a face repaint" {
    var threaded: std.Io.Threaded = undefined;
    defer threaded.deinit();
    var s = startSession(&threaded);
    defer s.deinit();
    const g = compute(&s, 1000.0);
    const sr = swRects(&g, measure.measureCr());
    const out = press(&s, &g, k_shadow_pad + sr.h1.x + 4, k_shadow_pad + sr.h1.y + 4, 1000);
    try testing.expect(!s.h24);
    try testing.expect(out.face);
    try testing.expect(out.saved);
}

test "wc-panel: a character key no longer edits the session" {
    var threaded: std.Io.Threaded = undefined;
    defer threaded.deinit();
    var s = startSession(&threaded);
    defer s.deinit();
    const g = compute(&s, 1000.0);
    const before = s.count();
    var out = key(&s, &g, 'a', "a", true, false, 1000);
    try testing.expect(!out.handled and !out.repaint);
    out = key(&s, &g, 'n', "n", true, false, 1010);
    try testing.expect(!out.handled and !out.repaint);
    try testing.expectEqual(before, s.count());
    try testing.expect(s.p.focus == .none);
    try testing.expectEqual(@as(i32, 0), s.p.shift_min);
    // Enter on the resting popup no longer opens the pane or adds a city.
    out = key(&s, &g, KeySym.ret, "", true, false, 2000);
    try testing.expect(!out.handled and !out.relayout and !out.face and !out.saved);
    try testing.expectEqual(before, s.count());
}
