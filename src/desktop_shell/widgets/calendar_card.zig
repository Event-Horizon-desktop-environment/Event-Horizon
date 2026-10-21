//! The month-grid card shared by the dock's calendar popup and the desktop
//! calendar widget: one painter, so the two surfaces cannot drift apart.
//!
//! Cell geometry is fixed in *card* pixels (the popup renders at scale 1) so
//! hit-testing and painting are the same arithmetic. The card draws a dark
//! glass panel, the month and year, the two month-stepping buttons, the
//! `S M T W T F S` header and the 6x7 grid, with today on an accent disc and
//! the selected day on a quiet glass ring.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const helpers = @import("../shared/cairo_helpers.zig");
const chrome = @import("shared/chrome_colors.zig");
const cal = @import("calendar.zig");
const lt = @import("../desktop/local_time.zig");

pub const Date = lt.Date;

/// The card's fixed size: 320 x 370.
pub const width: f64 = 320.0;
pub const height: f64 = 370.0;

const k_pad: f64 = 16.0;
const k_header_font: f64 = 20.0;
const k_day_font: f64 = 12.0;
const k_date_font: f64 = 15.0;
const k_row_h: f64 = 44.0;
const k_cell_w: f64 = 39.0;
const k_cell_r: f64 = 14.0;
const k_top_pad: f64 = 28.0;
const k_corner: f64 = 24.0;

const k_month_names = [_][]const u8{
    "January",  "February", "March",     "April",
    "May",      "June",     "July",     "August",
    "September", "October", "November", "December",
};

const k_day_labels = [_][]const u8{ "S", "M", "T", "W", "T", "F", "S" };

pub fn monthName(m: u8) []const u8 {
    if (m < 1 or m > 12) return "";
    return k_month_names[m - 1];
}

// Days as numbers

/// Days elapsed since 1970-01-01. `d` may be outside the month, which is the
/// whole point: the grid starts on the Sunday that contains the 1st.
///
/// Counted year by year rather than through a closed form — the card walks a
/// handful of days around the current month, so the linear scan costs nothing
/// and cannot be off by a century.
pub fn daysFromCivil(y: i32, m: u8, d: i32) i64 {
    var n: i64 = 0;
    var yy: i32 = 1970;
    while (yy < y) : (yy += 1) n += yearLen(yy);
    while (yy > y) {
        yy -= 1;
        n -= yearLen(yy);
    }
    var mm: u8 = 1;
    while (mm < m) : (mm += 1) n += cal.daysInMonth(y, mm);
    return n + @as(i64, @intCast(d)) - 1;
}

/// The inverse of `daysFromCivil`.
pub fn civilFromDays(z0: i64) Date {
    var z = z0;
    var y: i32 = 1970;
    while (true) {
        const len: i64 = yearLen(y);
        if (z < len) break;
        z -= len;
        y += 1;
    }
    while (z < 0) {
        y -= 1;
        z += yearLen(y);
    }
    var m: u8 = 1;
    while (true) : (m += 1) {
        const dim: i64 = cal.daysInMonth(y, m);
        if (z < dim) break;
        z -= dim;
    }
    return .{ .year = y, .month = m, .day = @intCast(z + 1) };
}

fn yearLen(y: i32) i64 {
    return if (cal.isLeapYear(y)) 366 else 365;
}

// Geometry

pub fn cellX(col: i32, us: f64) f64 {
    return k_pad * us + @as(f64, @floatFromInt(col)) * (k_cell_w * us + 2.5 * us);
}

pub fn cellY(row: i32, us: f64) f64 {
    return (k_top_pad * us + k_header_font * us + 22.0 * us + 12.0 * us) +
        @as(f64, @floatFromInt(row)) * k_row_h * us;
}

pub const Nav = struct {
    prev_x: f64 = 0,
    next_x: f64 = 0,
    nav_y: f64 = 0,
    btn: f64 = 0,
};

pub fn navGeom(w: f64, us: f64) Nav {
    const btn = 28.0 * us;
    return .{
        .btn = btn,
        .nav_y = (k_top_pad * us + k_header_font * us) - btn * 0.5,
        .prev_x = w - k_pad * us - btn * 2.0 - 4.0 * us,
        .next_x = w - k_pad * us - btn,
    };
}

/// Which nav button a point is on: -1 previous, +1 next, 0 neither.
pub fn navHit(w: f64, x: f64, y: f64, us: f64) i32 {
    const n = navGeom(w, us);
    if (x >= n.prev_x and x < n.prev_x + n.btn and y >= n.nav_y and y < n.nav_y + n.btn) return -1;
    if (x >= n.next_x and x < n.next_x + n.btn and y >= n.nav_y and y < n.nav_y + n.btn) return 1;
    return 0;
}

/// Whether `(x, y)` is inside cell (`row`, `col`) — a 14 px disc, exactly as
/// `cal_cell_hit` decides it.
pub fn cellHit(row: i32, col: i32, x: f64, y: f64, us: f64) bool {
    const cx = cellX(col, us) + k_cell_w * us * 0.5;
    const cy = cellY(row, us) + k_row_h * us * 0.5;
    const dx = x - cx;
    const dy = y - cy;
    const r = k_cell_r * us;
    return dx * dx + dy * dy <= r * r;
}

/// The grid index (0..41) under a point, or null outside every cell.
pub fn cellAt(x: f64, y: f64, us: f64) ?usize {
    var row: i32 = 0;
    while (row < 6) : (row += 1) {
        var col: i32 = 0;
        while (col < 7) : (col += 1) {
            if (cellHit(row, col, x, y, us)) return @intCast(row * 7 + col);
        }
    }
    return null;
}

/// The date in grid slot `idx` (0..41) of the month containing `display`.
pub fn cellDate(display: Date, idx: usize) Date {
    const first = daysFromCivil(display.year, display.month, 1) -
        @as(i64, @intCast(cal.weekday(display.year, display.month, 1)));
    return civilFromDays(first + @as(i64, @intCast(idx)));
}

// Paint

fn showText(cr: ?*cairo.cairo_t, s: []const u8, x: f64, y: f64) void {
    const c = cr orelse return;
    if (s.len == 0) return;
    var z: [32:0]u8 = [_:0]u8{0} ** 32;
    const n = @min(s.len, 31);
    @memcpy(z[0..n], s[0..n]);
    cairo.cairo_move_to(c, x, y);
    cairo.cairo_show_text(c, &z);
}

fn textAdvance(cr: ?*cairo.cairo_t, s: []const u8) f64 {
    const c = cr orelse return 0.0;
    if (s.len == 0) return 0.0;
    var z: [32:0]u8 = [_:0]u8{0} ** 32;
    const n = @min(s.len, 31);
    @memcpy(z[0..n], s[0..n]);
    var te: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(c, &z, &te);
    return te.x_advance;
}

fn textHeight(cr: ?*cairo.cairo_t, s: []const u8) f64 {
    const c = cr orelse return 0.0;
    if (s.len == 0) return 0.0;
    var z: [32:0]u8 = [_:0]u8{0} ** 32;
    const n = @min(s.len, 31);
    @memcpy(z[0..n], s[0..n]);
    var te: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(c, &z, &te);
    return te.height;
}

fn textBearing(cr: ?*cairo.cairo_t, s: []const u8) f64 {
    const c = cr orelse return 0.0;
    if (s.len == 0) return 0.0;
    var z: [32:0]u8 = [_:0]u8{0} ** 32;
    const n = @min(s.len, 31);
    @memcpy(z[0..n], s[0..n]);
    var te: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(c, &z, &te);
    return te.y_bearing;
}

fn font(cr: ?*cairo.cairo_t, px: f64, bold: bool) void {
    const c = cr orelse return;
    cairo.cairo_select_font_face(
        c,
        "Inter",
        cairo.CAIRO_FONT_SLANT_NORMAL,
        if (bold) cairo.CAIRO_FONT_WEIGHT_BOLD else cairo.CAIRO_FONT_WEIGHT_NORMAL,
    );
    cairo.cairo_set_font_size(c, px);
}

/// A single chevron, drawn as two joined strokes — the nav arrows keep
/// their hand-drawn weight rather than going through the glyph bank.
fn chevron(cr: ?*cairo.cairo_t, cx: f64, cy: f64, px: f64, dir: i32, cc: chrome.Chrome, a: f64) void {
    const c = cr orelse return;
    const half = px * 0.5;
    const tail = px * 0.22;
    cairo.cairo_save(c);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_line_join(c, cairo.CAIRO_LINE_JOIN_ROUND);
    cairo.cairo_set_line_width(c, @max(1.5, px * 0.14));
    cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, a);
    cairo.cairo_move_to(c, cx + @as(f64, @floatFromInt(dir)) * tail, cy - half);
    cairo.cairo_line_to(c, cx - @as(f64, @floatFromInt(dir)) * tail, cy);
    cairo.cairo_line_to(c, cx + @as(f64, @floatFromInt(dir)) * tail, cy + half);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
}

/// The full card at (0,0)-(w,h). `card_alpha` multiplies the panel's fill so
/// a host can fade it without touching the text.
pub fn paintCard(
    cr: ?*cairo.cairo_t,
    w: f64,
    h: f64,
    us: f64,
    cc: chrome.Chrome,
    card_alpha: f64,
    display: Date,
    selected: Date,
    today_d: Date,
) void {
    const c = cr orelse return;

    cairo.cairo_save(c);

    helpers.roundedRect(c, 0.0, 0.0, w, h, k_corner * us);
    cairo.cairo_set_source_rgba(
        c,
        cc.dock_fill.r * 0.30,
        cc.dock_fill.g * 0.30,
        cc.dock_fill.b * 0.30,
        0.92 * card_alpha,
    );
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    // Month + year header.
    font(c, k_header_font * us, true);
    const month = monthName(display.month);
    cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.95);
    showText(c, month, k_pad * us, (k_top_pad + k_header_font) * us);

    var ybuf: [8]u8 = undefined;
    const year = std.fmt.bufPrint(&ybuf, "{d}", .{display.year}) catch "";
    font(c, k_header_font * us, false);
    cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.50);
    showText(c, year, k_pad * us + textAdvance(c, month) * 1.0 + 8.0 * us, (k_top_pad + k_header_font) * us);

    const nav = navGeom(w, us);
    const nav_cy = nav.nav_y + nav.btn * 0.5;
    chevron(c, nav.prev_x + nav.btn * 0.5, nav_cy, 18.0 * us, 1, cc, 0.60);
    chevron(c, nav.next_x + nav.btn * 0.5, nav_cy, 18.0 * us, -1, cc, 0.60);

    // `S M T W T F S`.
    font(c, k_day_font * us, false);
    cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.50);
    const y_day_base = (k_top_pad + k_header_font + 22.0) * us;
    for (0..7) |col| {
        const label = k_day_labels[col];
        showText(
            c,
            label,
            cellX(@intCast(col), us) + (k_cell_w * us - textAdvance(c, label)) * 0.5,
            y_day_base,
        );
    }

    // The soft wash behind whichever row holds today.
    const first = daysFromCivil(display.year, display.month, 1) -
        @as(i64, @intCast(cal.weekday(display.year, display.month, 1)));
    const today_idx = todayIndexOf(first, today_d);
    if (today_idx) |ti| {
        const band_y = cellY(@intCast(ti / 7), us);
        helpers.roundedRect(c, k_pad * us, band_y, w - k_pad * 2.0 * us, k_row_h * us, 12.0 * us);
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.05);
        cairo.cairo_fill(c);
    }

    font(c, k_date_font * us, false);
    for (0..42) |idx| {
        const d = civilFromDays(first + @as(i64, @intCast(idx)));
        const in_month = d.month == display.month;
        const is_today = d.eql(today_d);
        const is_sel = d.eql(selected);

        const row: i32 = @intCast(idx / 7);
        const col: i32 = @intCast(idx % 7);
        const cx = cellX(col, us) + k_cell_w * us * 0.5;
        const cy = cellY(row, us) + k_row_h * us * 0.5;

        var dbuf: [4]u8 = undefined;
        const day = std.fmt.bufPrint(&dbuf, "{d}", .{d.day}) catch continue;

        if (is_today) {
            cairo.cairo_new_path(c);
            cairo.cairo_arc(c, cx, cy, k_cell_r * us, 0.0, 2.0 * std.math.pi);
            cairo.cairo_set_source_rgba(c, cc.accent.r, cc.accent.g, cc.accent.b, 0.90);
            cairo.cairo_fill(c);
        } else if (is_sel) {
            helpers.roundedRect(
                c,
                cellX(col, us) + 2.0 * us,
                cellY(row, us) + 5.0 * us,
                k_cell_w * us - 4.0 * us,
                k_row_h * us - 10.0 * us,
                10.0 * us,
            );
            cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.12);
            cairo.cairo_fill_preserve(c);
            cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.35);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_stroke(c);
        }

        const alpha: f64 = if (is_sel or is_today)
            0.95
        else if (in_month)
            0.90
        else
            0.28;
        cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, alpha);
        showText(c, day, cx - textAdvance(c, day) * 0.5, cy - textBearing(c, day) * 0.5 - textHeight(c, day) * 0.5);
    }

    cairo.cairo_restore(c);
}

fn todayIndexOf(first_day_number: i64, today_d: Date) ?usize {
    const n = daysFromCivil(today_d.year, today_d.month, today_d.day) - first_day_number;
    if (n < 0 or n >= 42) return null;
    return @intCast(n);
}

// Tests

test "calendar-card: civil days round-trip" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const back = civilFromDays(0);
    try t.expect(back.year == 1970 and back.month == 1 and back.day == 1);
    var y: i32 = 1999;
    while (y <= 2035) : (y += 1) {
        var m: u8 = 1;
        while (m <= 12) : (m += 1) {
            const d = daysFromCivil(y, m, 15);
            const c = civilFromDays(d);
            try t.expect(c.year == y and c.month == m and c.day == 15);
        }
    }
}

test "calendar-card: walking off either end of a month" {
    const t = std.testing;
    const before = civilFromDays(daysFromCivil(2026, 3, 1) - 1);
    try t.expect(before.year == 2026 and before.month == 2 and before.day == 28);
    const after = civilFromDays(daysFromCivil(2024, 2, 29) + 1);
    try t.expect(after.year == 2024 and after.month == 3 and after.day == 1);
    const leap = civilFromDays(daysFromCivil(2024, 2, 1) + 28);
    try t.expect(leap.month == 2 and leap.day == 29);
}

test "calendar-card: the 42 grid slots start on the Sunday before the 1st" {
    const t = std.testing;
    // October 2026 starts on a Thursday, so the grid opens on the 27th of
    // September and closes on the 7th of November.
    const disp = Date{ .year = 2026, .month = 10, .day = 1 };
    const first = cellDate(disp, 0);
    try t.expectEqual(@as(u8, 0), cal.weekday(first.year, first.month, first.day));
    try t.expectEqual(Date{ .year = 2026, .month = 9, .day = 27 }, first);
    try t.expectEqual(Date{ .year = 2026, .month = 11, .day = 7 }, cellDate(disp, 41));
    // Every slot is one day after the last, all the way across.
    var i: usize = 1;
    while (i < 42) : (i += 1) {
        const a = cellDate(disp, i - 1);
        const b = cellDate(disp, i);
        try t.expectEqual(daysFromCivil(a.year, a.month, a.day) + 1, daysFromCivil(b.year, b.month, b.day));
    }
    // The 1st itself lands somewhere in the first row for a month that starts
    // on a Sunday, and in a later one otherwise.
    const sun = Date{ .year = 2026, .month = 10, .day = 1 };
    try t.expect(daysFromCivil(sun.year, sun.month, 1) - daysFromCivil(cellDate(sun, 0).year, cellDate(sun, 0).month, cellDate(sun, 0).day) == 4);
}

test "calendar-card: nav and cell hit-testing agree with the paint" {
    const t = std.testing;
    const us = 1.0;
    try t.expectEqual(@as(i32, -1), navHit(width, navGeom(width, us).prev_x + 4, navGeom(width, us).nav_y + 4, us));
    try t.expectEqual(@as(i32, 1), navHit(width, navGeom(width, us).next_x + 4, navGeom(width, us).nav_y + 4, us));
    try t.expectEqual(@as(i32, 0), navHit(width, 4.0, 4.0, us));

    // Cell (0,0) sits at (16, 82) and is 39x44; the disc is r=14 from centre.
    try t.expectEqual(@as(?usize, 0), cellAt(cellX(0, us) + 19.5, cellY(0, us) + 22.0, us));
    try t.expectEqual(@as(?usize, 6), cellAt(cellX(6, us) + 19.5, cellY(0, us) + 22.0, us));
    try t.expectEqual(@as(?usize, 41), cellAt(cellX(6, us) + 19.5, cellY(5, us) + 22.0, us));
    // Between two discs but inside the card.
    try t.expect(cellAt(cellX(0, us) + 41.0, cellY(0, us) + 22.0, us) == null);
    try t.expect(cellAt(0.0, 0.0, us) == null);
}

test "calendar-card: months name themselves" {
    const t = std.testing;
    try t.expectEqualStrings("January", monthName(1));
    try t.expectEqualStrings("October", monthName(10));
    try t.expectEqualStrings("December", monthName(12));
    try t.expectEqualStrings("", monthName(0));
    try t.expectEqualStrings("", monthName(13));
}

test "calendar-card: the card is translucent, so the compositor's blur reads" {
    const t = std.testing;
    const w: i32 = @intFromFloat(width);
    const h: i32 = @intFromFloat(height);
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    // Cleared to genuine transparency first, the way the popup host clears
    // its frame before the card paints onto it.
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);

    const today = Date{ .year = 2026, .month = 10, .day = 14 };
    const display = Date{ .year = 2026, .month = 10, .day = 1 };
    paintCard(cr, width, height, 1.0, .{}, 1.0, display, today, today);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    _ = cairo.cairo_surface_flush(surf);
    const data: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const stride: i32 = @intCast(cairo.cairo_image_surface_get_stride(surf));
    // Cairo's ARGB32 is little-endian premultiplied: byte 3 is alpha. `k_pad`
    // is 16 and the grid, the weekday row and the header all start there, so
    // the left margin at mid-height is fill alone (the hairline stroke sits
    // at x = 0 ± 0.5).
    const x: i32 = 4;
    const y: i32 = @divTrunc(h, 2);
    const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(stride)) + @as(usize, @intCast(x)) * 4;
    const full = data[idx + 3];
    // 0.92 nominal fill over a cleared buffer — translucent by construction
    // and never the solid 255 the popup painted before `card_alpha` was
    // plumbed through to it.
    try t.expect(full > 225 and full < 245);

    // The widget-card knob is what the blur reads through: at the live 0.18
    // the card keeps a fifth of its ink.
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
    paintCard(cr, width, height, 1.0, .{}, 0.18, display, today, today);
    _ = cairo.cairo_surface_flush(surf);
    const thin = data[idx + 3];
    try t.expect(thin > 30 and thin < 55 and thin < full);
}
