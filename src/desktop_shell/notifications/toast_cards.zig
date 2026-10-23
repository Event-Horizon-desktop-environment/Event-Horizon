//! Toast cards — selection, layout, paint and hit-testing for the
//! notification daemon.
//!
//! Model rules: at most 4 cards, newest first, nothing under
//! do-not-disturb or `silent`, one card per app name, one per
//! summary+body. Clicking a card dismisses it; the close X highlights on
//! hover. The countdown bar fills with the remaining fraction.
//!
//! Text goes through cairo's toy API (no pango in the Zig tree), so
//! wrapping/ellipsis are implemented here: titles shrink 18→6pt and may use
//! two lines, bodies cap at two ellipsized lines. Measurement uses the same
//! cr and the same Sans Bold/Regular faces the paint uses, so layout never
//! disagrees with pixels.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const layer = @import("../../wl/surface/layer.zig");
const chrome = @import("../widgets/shared/chrome_colors.zig");
const svg_icons = @import("../../ux/shared/svg_icons.zig");
const manager_mod = @import("../../services/notify_manager.zig");

const Manager = manager_mod.Manager;
const Notification = manager_mod.Notification;

pub const kMaxCards: usize = 4;

pub const Card = struct {
    id: u32 = 0,
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
};

/// Scale-aware metrics. `us` is `toast.scale_pct / 100`.
pub const Metrics = struct {
    us: f64 = 1.0,
    card_radius: f64 = 16.0,

    pub fn cardW(_: Metrics) f64 {
        return 360.0;
    }
    pub fn cardH(m: Metrics) f64 {
        return 140.0 * m.us;
    }
    pub fn gap(m: Metrics) f64 {
        return 8.0 * m.us;
    }
    pub fn pad(m: Metrics) f64 {
        return 18.0 * m.us;
    }
    pub fn iconTextGap(m: Metrics) f64 {
        return 22.0 * m.us;
    }
    pub fn iconSz(m: Metrics) f64 {
        return 96.0 * m.us;
    }
    pub fn iconRad(m: Metrics) f64 {
        return 14.0 * m.us;
    }
    pub fn progressH(m: Metrics) f64 {
        return 3.0 * m.us;
    }
    pub fn closeBtnSz(m: Metrics) f64 {
        return 20.0 * m.us;
    }
    pub fn headerGap(m: Metrics) f64 {
        return 6.0 * m.us;
    }
};

/// Which live ids earn cards, newest first. Pure: the caller lays out and
/// paints whatever comes back.
pub fn selectCards(mgr: *Manager, out: []u32) []u32 {
    var n: usize = 0;
    if (mgr.do_not_disturb) return out[0..0];
    const items = mgr.all();
    var ri: usize = items.len;
    var seen_apps: [kMaxCards][]const u8 = undefined;
    var n_apps: usize = 0;
    var seen_content: [kMaxCards][2][]const u8 = undefined;
    var n_content: usize = 0;
    while (ri > 0) {
        ri -= 1;
        if (n >= kMaxCards or n >= out.len) break;
        const it = &items[ri];
        if (it.silent) continue;
        var dup = false;
        for (seen_apps[0..n_apps]) |a| {
            if (std.mem.eql(u8, a, it.app_name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        for (seen_content[0..n_content]) |c| {
            if (std.mem.eql(u8, c[0], it.summary) and std.mem.eql(u8, c[1], it.body)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        seen_apps[n_apps] = it.app_name;
        n_apps += 1;
        seen_content[n_content] = .{ it.summary, it.body };
        n_content += 1;
        out[n] = it.id;
        n += 1;
    }
    return out[0..n];
}

pub fn anchorFor(position: []const u8) u32 {
    if (std.mem.eql(u8, position, "top_left")) return layer.Anchor.top | layer.Anchor.left;
    if (std.mem.eql(u8, position, "bottom_right")) return layer.Anchor.bottom | layer.Anchor.right;
    if (std.mem.eql(u8, position, "bottom_left")) return layer.Anchor.bottom | layer.Anchor.left;
    if (std.mem.eql(u8, position, "top_center")) return layer.Anchor.top;
    if (std.mem.eql(u8, position, "bottom_center")) return layer.Anchor.bottom;
    return layer.Anchor.top | layer.Anchor.right;
}

pub fn stackBottom(position: []const u8) bool {
    return std.mem.startsWith(u8, position, "bottom");
}

// Text helpers (cairo toy API, Sans family)

fn selectFont(c: *cairo.cairo_t, size: f64, bold: bool) void {
    cairo.cairo_select_font_face(
        c,
        "Sans",
        cairo.CAIRO_FONT_SLANT_NORMAL,
        if (bold) cairo.CAIRO_FONT_WEIGHT_BOLD else cairo.CAIRO_FONT_WEIGHT_NORMAL,
    );
    cairo.cairo_set_font_size(c, size);
}

fn advance(c: *cairo.cairo_t, size: f64, bold: bool, s: []const u8) f64 {
    if (s.len == 0) return 0;
    selectFont(c, size, bold);
    var buf: [1024:0]u8 = undefined;
    const n = @min(s.len, 1023);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    cairo.cairo_text_extents(c, @ptrCast(&buf), &ex);
    return @max(ex.x_advance, ex.x_bearing + ex.width);
}

fn showAt(c: *cairo.cairo_t, size: f64, bold: bool, s: []const u8, x: f64, y: f64, r: f64, g: f64, b: f64, a: f64) void {
    if (s.len == 0) return;
    selectFont(c, size, bold);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    var buf: [1024:0]u8 = undefined;
    const n = @min(s.len, 1023);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    cairo.cairo_move_to(c, x, y);
    cairo.cairo_show_text(c, @ptrCast(&buf));
}

fn ascent(c: *cairo.cairo_t, size: f64, bold: bool, s: []const u8) f64 {
    if (s.len == 0) return size * 0.8;
    selectFont(c, size, bold);
    var buf: [1024:0]u8 = undefined;
    const n = @min(s.len, 1023);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    cairo.cairo_text_extents(c, @ptrCast(&buf), &ex);
    return -ex.y_bearing;
}

/// Greedy word wrap into at most `max_lines` stack lines. Returns the line
/// count; `lens[i]` is the byte length of line i into `s` (lines are
/// space-joined words, no trailing spaces). Words longer than the width
/// overflow rather than split — titles shrink instead, bodies ellipsize.

// Layout

pub const Layout = struct {
    cards: []Card,
    width: i32,
    height: i32,
};

/// Fill `cards` (ids preselected) with rects and return the surface size.
/// `measure_cr` sizes titles like the paint will draw them.
pub fn layoutCards(
    measure_cr: *cairo.cairo_t,
    ids: []const u32,
    mgr: *Manager,
    m: Metrics,
    position: []const u8,
    max_width_px: f64,
    cards: []Card,
) Layout {
    const n = @min(ids.len, cards.len);
    var card_w = m.cardW() * m.us;
    for (ids[0..n]) |id| {
        const nn = findLive(mgr, id) orelse continue;
        if (nn.summary.len == 0) continue;
        const title_w = advance(measure_cr, 14.0 * m.us, true, nn.summary);
        const needed = m.pad() + m.iconSz() + m.iconTextGap() + title_w +
            m.headerGap() + m.closeBtnSz() + m.pad();
        card_w = @max(card_w, needed);
    }
    if (max_width_px > 0) card_w = @min(card_w, max_width_px * m.us);
    const ch = m.cardH();
    const total_h = @as(f64, @floatFromInt(n)) * ch +
        @as(f64, @floatFromInt(if (n > 0) n - 1 else 0)) * m.gap() +
        m.pad() * 2.0;
    const width: i32 = @intFromFloat(@ceil(card_w + m.pad() * 2.0));
    const height: i32 = @intFromFloat(@ceil(total_h));
    const bottom = stackBottom(position);
    var y = if (bottom) total_h - m.pad() - ch else m.pad();
    for (ids[0..n], 0..) |id, i| {
        cards[i] = .{ .id = id, .x = m.pad(), .y = y, .w = card_w, .h = ch };
        y += if (bottom) -(ch + m.gap()) else (ch + m.gap());
    }
    return .{ .cards = cards[0..n], .width = width, .height = height };
}

fn findLive(mgr: *Manager, id: u32) ?*const Notification {
    for (mgr.all()) |*nn| {
        if (nn.id == id) return nn;
    }
    return null;
}

/// Remaining/total countdown fraction, or null for timeless cards.
pub fn progressFraction(n: *const Notification, now_ms: i64) ?f64 {
    const exp = n.expiry_ms orelse return null;
    const total = exp - n.received_ms;
    if (total <= 0) return 0.0;
    const remaining = exp - now_ms;
    return std.math.clamp(@as(f64, @floatFromInt(remaining)) / @as(f64, @floatFromInt(total)), 0.0, 1.0);
}

// Hit-testing — one source of truth with paint

pub fn closeBox(card: Card, m: Metrics) struct { x: f64, y: f64, s: f64 } {
    const s = m.closeBtnSz();
    return .{
        .x = card.x + card.w - m.pad() - s,
        .y = card.y + m.pad() + 2.0 * m.us,
        .s = s,
    };
}

pub fn hitCard(cards: []const Card, x: f64, y: f64) ?usize {
    for (cards, 0..) |c, i| {
        if (x >= c.x and x < c.x + c.w and y >= c.y and y < c.y + c.h) return i;
    }
    return null;
}

pub fn hitClose(cards: []const Card, m: Metrics, x: f64, y: f64) ?u32 {
    for (cards) |c| {
        const b = closeBox(c, m);
        if (x >= b.x and x < b.x + b.s and y >= b.y and y < b.y + b.s) return c.id;
    }
    return null;
}

// Paint

pub const Converted = struct {
    surf: *cairo.cairo_surface_t,
    w: i32,
    h: i32,
};

/// RGBA/RGB bytes → cairo ARGB32 (R/B swap), like
/// `notification_image_to_cairo_surface`. Null on empty/odd input; the icon
/// box simply stays empty then, and the text column never reflows.
pub fn convertImage(_: std.mem.Allocator, img: manager_mod.ImageData) ?Converted {
    if (img.width <= 0 or img.height <= 0 or img.pixels.len == 0) return null;
    if (img.channels != 4 and img.channels != 3) return null;
    if (img.bits_per_sample != 8) return null;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, img.width, img.height) orelse return null;
    errdefer cairo.cairo_surface_destroy(surf);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const dst = cairo.cairo_image_surface_get_data(surf) orelse {
        cairo.cairo_surface_destroy(surf);
        return null;
    };
    const dst_stride: usize = @intCast(cairo.cairo_image_surface_get_stride(surf));
    const src_pb: usize = @intCast(img.channels);
    const src_stride: usize = if (img.row_stride > 0) @as(usize, @intCast(img.row_stride)) else @as(usize, @intCast(img.width)) * src_pb;
    const h: usize = @intCast(img.height);
    const w: usize = @intCast(img.width);
    if (img.pixels.len < (h - 1) * src_stride + w * src_pb) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    var yy: usize = 0;
    while (yy < h) : (yy += 1) {
        var xx: usize = 0;
        while (xx < w) : (xx += 1) {
            const so = yy * src_stride + xx * src_pb;
            const doff = yy * dst_stride + xx * 4;
            dst[doff + 0] = img.pixels[so + 2];
            dst[doff + 1] = img.pixels[so + 1];
            dst[doff + 2] = img.pixels[so + 0];
            dst[doff + 3] = if (src_pb >= 4) img.pixels[so + 3] else 0xFF;
        }
    }
    cairo.cairo_surface_mark_dirty(surf);
    return .{ .surf = surf, .w = img.width, .h = img.height };
}

fn roundedPath(c: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const rr = @min(r, 0.5 * @min(w, h));
    cairo.cairo_new_sub_path(c);
    cairo.cairo_arc(c, x + w - rr, y + rr, rr, -std.math.pi / 2.0, 0);
    cairo.cairo_arc(c, x + w - rr, y + h - rr, rr, 0, std.math.pi / 2.0);
    cairo.cairo_arc(c, x + rr, y + h - rr, rr, std.math.pi / 2.0, std.math.pi);
    cairo.cairo_arc(c, x + rr, y + rr, rr, std.math.pi, 3.0 * std.math.pi / 2.0);
    cairo.cairo_close_path(c);
}

/// One card: glass body, critical tint when urgent, image or empty icon box,
/// auto-fit title, two-line body, close X, countdown bar.
///
/// `bg_alpha` is the Appearance → Opacity multiplier for the notification
/// *background* only. It scales the card body and outline; art, glyphs,
/// text and the countdown bar keep their design alpha so the slider never
/// washes out the content. The knob's 100% maps to `1 / 0.78`, hence the
/// nominal `0.78 * bg_alpha` body reaching solid.
pub fn paintCard(
    c: *cairo.cairo_t,
    alloc: std.mem.Allocator,
    card: Card,
    n: *const Notification,
    ch: chrome.Chrome,
    m: Metrics,
    bg_alpha: f64,
    now_ms: i64,
    hover_close: bool,
) void {
    const critical = n.urgency == .critical;
    // Body.
    if (critical) {
        cairo.cairo_set_source_rgba(c, ch.notif_bg.r * 0.5, ch.notif_bg.g * 0.5, ch.notif_bg.b * 0.5, 0.78 * bg_alpha);
    } else {
        cairo.cairo_set_source_rgba(c, ch.dock_fill.r * 0.35, ch.dock_fill.g * 0.35, ch.dock_fill.b * 0.35, 0.78 * bg_alpha);
    }
    roundedPath(c, card.x, card.y, card.w, card.h, m.card_radius * m.us);
    cairo.cairo_fill(c);
    // Border — background chrome too, so it tracks the fill. Clamped at 1 so
    // the settings-page ceiling (`1 / design`) does not brighten it above the
    // designed stroke.
    const edge_alpha = @min(1.0, bg_alpha);
    roundedPath(c, card.x + 0.5, card.y + 0.5, card.w - 1.0, card.h - 1.0, m.card_radius * m.us);
    if (critical) {
        cairo.cairo_set_source_rgba(c, ch.notif_ol.r, ch.notif_ol.g, ch.notif_ol.b, 0.85 * edge_alpha);
        cairo.cairo_set_line_width(c, 1.5);
    } else {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.12 * edge_alpha);
        cairo.cairo_set_line_width(c, 1.0);
    }
    cairo.cairo_stroke(c);

    const icon_x = card.x + m.pad();
    const icon_y = card.y + m.pad() + 2.0 * m.us;
    if (n.image) |img| {
        if (convertImage(alloc, img)) |cv| {
            defer cairo.cairo_surface_destroy(cv.surf);
            const iw: f64 = @floatFromInt(cv.w);
            const ih: f64 = @floatFromInt(cv.h);
            if (iw > 0 and ih > 0) {
                const sc = @max(m.iconSz() / iw, m.iconSz() / ih);
                cairo.cairo_save(c);
                roundedPath(c, icon_x, icon_y, m.iconSz(), m.iconSz(), m.iconRad());
                cairo.cairo_clip(c);
                cairo.cairo_translate(c, icon_x + (m.iconSz() - iw * sc) * 0.5, icon_y + (m.iconSz() - ih * sc) * 0.5);
                cairo.cairo_scale(c, sc, sc);
                cairo.cairo_set_source_surface(c, cv.surf, 0, 0);
                cairo.cairo_pattern_set_extend(cairo.cairo_get_source(c), cairo.CAIRO_EXTEND_PAD);
                cairo.cairo_paint(c);
                cairo.cairo_restore(c);
            }
        }
    }

    const text_x = icon_x + m.iconSz() + m.iconTextGap();
    const cb = closeBox(card, m);
    const right_edge = cb.x - m.headerGap();
    const pbar_y = card.y + card.h - m.progressH() - 8.0 * m.us;

    // Close button: the `close` SVG (Lucide `x`), tinted like the old
    // vector-X wash (dim idle, bright on hover) with a hover disc behind
    // it so the target is discoverable. Vector strokes stay as fallback.
    {
        if (hover_close) {
            cairo.cairo_new_path(c);
            cairo.cairo_arc(c, cb.x + cb.s * 0.5, cb.y + cb.s * 0.5, cb.s * 0.5, 0, 2.0 * std.math.pi);
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.10);
            cairo.cairo_fill(c);
        }
        const ta: f64 = if (hover_close) 0.90 else 0.55;
        if (!svg_icons.draw(c, "close", cb.x + cb.s * 0.5, cb.y + cb.s * 0.5, cb.s * 0.7, ch.text.r, ch.text.g, ch.text.b, ta, false)) {
            const inset = cb.s * 0.30;
            cairo.cairo_set_source_rgba(c, ch.text.r, ch.text.g, ch.text.b, ta);
            cairo.cairo_set_line_width(c, @max(1.0, 1.6 * m.us));
            cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
            cairo.cairo_new_path(c);
            cairo.cairo_move_to(c, cb.x + inset, cb.y + inset);
            cairo.cairo_line_to(c, cb.x + cb.s - inset, cb.y + cb.s - inset);
            cairo.cairo_move_to(c, cb.x + cb.s - inset, cb.y + inset);
            cairo.cairo_line_to(c, cb.x + inset, cb.y + inset);
            cairo.cairo_stroke(c);
            cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_BUTT);
        }
    }

    const avail_w = right_edge - text_x;

    // Body first (≤2 lines): the title fills whatever vertical space is left.
    // Measure with a throwaway wrap to learn its height.
    const line_h = 13.0 * m.us * 1.25;
    var measure_starts = [_]usize{ 0, 0 };
    var measure_ends = [_]usize{ 0, 0 };
    const measure_nl = wrapSpans(c, 13.0 * m.us, false, n.body, avail_w, &measure_starts, &measure_ends);
    const body_h = @as(f64, @floatFromInt(measure_nl)) * line_h;
    const body_top = (pbar_y - 18.0 * m.us) - body_h;
    const title_avail_h = body_top - 6.0 * m.us - icon_y;

    // Title: shrink 18→6pt until it fits in ≤2 lines with every byte
    // visible, then 0.98×.
    var pt: f64 = 18.0 * m.us;
    var starts = [_]usize{ 0, 0 };
    var ends = [_]usize{ 0, 0 };
    var nl: usize = 0;
    var ti: usize = 0;
    while (ti < 30) : (ti += 1) {
        nl = wrapSpans(c, pt, true, n.summary, avail_w, &starts, &ends);
        const th = @as(f64, @floatFromInt(nl)) * pt * 1.25;
        // Each wrap consumes one space; the tail must reach the end.
        const covered = nl == 0 or ends[nl - 1] + nl >= n.summary.len;
        if ((th <= title_avail_h and covered) or pt <= 6.0 * m.us) break;
        pt -= 0.5 * m.us;
    }
    pt *= 0.98;
    {
        var yy = icon_y + ascent(c, pt, true, if (nl > 0) n.summary[starts[0]..ends[0]] else "");
        for (0..nl) |li| {
            showAt(c, pt, true, n.summary[starts[li]..ends[li]], text_x, yy, ch.text.r, ch.text.g, ch.text.b, 0.92);
            yy += pt * 1.25;
        }
    }

    // Body lines, bottom-aligned above the progress bar.
    {
        var b_starts = [_]usize{ 0, 0 };
        var b_ends = [_]usize{ 0, 0 };
        const b_nl = wrapSpans(c, 13.0 * m.us, false, n.body, avail_w, &b_starts, &b_ends);
        const truncated = b_nl == 2 and b_ends[1] < n.body.len;
        var yy = (pbar_y - 12.0 * m.us) - @as(f64, @floatFromInt(b_nl)) * line_h + line_h * 0.8;
        for (0..b_nl) |li| {
            var line = n.body[b_starts[li]..b_ends[li]];
            var ebuf: [1024]u8 = undefined;
            if (truncated and li == b_nl - 1) {
                // Ellipsize the last visible line.
                var elen = line.len;
                while (elen > 0) {
                    const cand_len = elen + 3; // "…"
                    if (cand_len <= ebuf.len) {
                        @memcpy(ebuf[0..elen], line[0..elen]);
                        ebuf[elen] = 0xE2;
                        ebuf[elen + 1] = 0x80;
                        ebuf[elen + 2] = 0xA6;
                        if (advance(c, 13.0 * m.us, false, ebuf[0..cand_len]) <= avail_w) break;
                    }
                    // Step back a whole UTF-8 char.
                    elen -= 1;
                    while (elen > 0 and (line[elen] & 0xC0) == 0x80) elen -= 1;
                }
                line = ebuf[0 .. elen + 3];
                if (elen == 0) line = "…";
            }
            showAt(c, 13.0 * m.us, false, line, text_x, yy, ch.text.r, ch.text.g, ch.text.b, 0.78);
            yy += line_h;
        }
    }

    // Progress bar.
    const pbar_x = card.x + m.pad();
    const pbar_w = card.w - m.pad() * 2.0;
    cairo.cairo_set_source_rgba(c, ch.drawer_dim.r, ch.drawer_dim.g, ch.drawer_dim.b, 0.50);
    cairo.cairo_rectangle(c, pbar_x, pbar_y, pbar_w, m.progressH());
    cairo.cairo_fill(c);
    if (progressFraction(n, now_ms)) |f| {
        cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.55);
        cairo.cairo_rectangle(c, pbar_x, pbar_y, pbar_w * f, m.progressH());
        cairo.cairo_fill(c);
    }
}

/// Word wrap recording byte spans (no allocation). Returns line count.
pub fn wrapSpans(
    c: *cairo.cairo_t,
    size: f64,
    bold: bool,
    s: []const u8,
    width: f64,
    starts: []usize,
    ends: []usize,
) usize {
    const max_lines = @min(starts.len, ends.len);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ' ');
    var cur_start: usize = 0;
    var cur_end: usize = 0; // one past last word byte
    var pos: usize = 0;
    var has_word = false;
    while (it.next()) |word| {
        const wstart = pos;
        pos += word.len + 1;
        if (word.len == 0) continue;
        const cand_end = wstart + word.len;
        const fits = if (!has_word) true else advance(c, size, bold, s[cur_start..cand_end]) <= width;
        // A leading word always fits (it overflows rather than splits).
        if (fits or !has_word) {
            cur_end = cand_end;
            has_word = true;
            continue;
        }
        if (n < max_lines) {
            starts[n] = cur_start;
            ends[n] = cur_end;
            n += 1;
        } else return n;
        if (n >= max_lines) return n;
        cur_start = wstart;
        cur_end = cand_end;
        has_word = true;
    }
    if (has_word and n < max_lines) {
        starts[n] = cur_start;
        ends[n] = cur_end;
        n += 1;
    }
    return n;
}

// Tests

test "toast-cards: selection newest-first with dedupe + cap" {
    const t = std.testing;
    var m = Manager.init(t.allocator);
    defer m.deinit();
    // Distinct app names dodge the same-app merge; distinct bodies dodge the
    // duplicate window. No clock control needed.
    const id1 = m.addOrUpdate(0, .{ .app_name = "A", .summary = "s1", .body = "b1" });
    const id2 = m.addOrUpdate(0, .{ .app_name = "B", .summary = "s2", .body = "b2" });
    const id3 = m.addOrUpdate(0, .{ .app_name = "C", .summary = "s3", .body = "b3" });
    const id4 = m.addOrUpdate(0, .{ .app_name = "D", .summary = "s4", .body = "b4" });
    const id5 = m.addOrUpdate(0, .{ .app_name = "E", .summary = "s5", .body = "b5" });
    var ids = @as([8]u32, @splat(0));
    const sel = selectCards(&m, &ids);
    try t.expectEqual(@as(usize, 4), sel.len);
    try t.expectEqual(id5, sel[0]); // newest first
    try t.expectEqual(id2, sel[3]);
    _ = id1;
    _ = id3;
    _ = id4;
}

test "toast-cards: silent + DND hide everything" {
    const t = std.testing;
    var m = Manager.init(t.allocator);
    defer m.deinit();
    _ = m.addOrUpdate(0, .{ .app_name = "A", .summary = "s", .body = "b", .silent = true });
    var ids = @as([8]u32, @splat(0));
    try t.expectEqual(@as(usize, 0), selectCards(&m, &ids).len);
    m.setQuietMode(true);
    _ = m.addOrUpdate(0, .{ .app_name = "B", .summary = "s", .body = "b" });
    try t.expectEqual(@as(usize, 0), selectCards(&m, &ids).len);
}

test "toast-cards: wrap + progress math" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 8, 8);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf) orelse return error.OutOfMemory;
    defer cairo.cairo_destroy(cr);
    var starts = [_]usize{ 0, 0 };
    var ends = [_]usize{ 0, 0 };
    const nl = wrapSpans(cr, 13.0, false, "hello brave new world test", 1000.0, &starts, &ends);
    try t.expectEqual(@as(usize, 1), nl);
    try t.expectEqual(@as(usize, 0), starts[0]);
    const n = Notification{ .received_ms = 1000, .expiry_ms = 1500 };
    try t.expectEqual(@as(f64, 0.5), progressFraction(&n, 1250).?);
    try t.expect(progressFraction(&n, 2000).? == 0.0);
    try t.expect(progressFraction(&Notification{ .received_ms = 0 }, 5) == null);
}

test "toast-cards: hit testing incl close box" {
    const t = std.testing;
    const cards = [_]Card{
        .{ .id = 7, .x = 10, .y = 20, .w = 300, .h = 140 },
        .{ .id = 9, .x = 10, .y = 170, .w = 300, .h = 140 },
    };
    const m = Metrics{};
    try t.expectEqual(@as(usize, 0), hitCard(&cards, 50, 50).?);
    try t.expectEqual(@as(usize, 1), hitCard(&cards, 50, 200).?);
    try t.expect(hitCard(&cards, 5, 5) == null);
    const b = closeBox(cards[0], m);
    try t.expectEqual(@as(u32, 7), hitClose(&cards, m, b.x + 1, b.y + 1).?);
    try t.expect(hitClose(&cards, m, 50, 50) == null);
}

test "toast-cards: anchors" {
    const t = std.testing;
    try t.expectEqual(layer.Anchor.top | layer.Anchor.right, anchorFor("top_right"));
    try t.expectEqual(layer.Anchor.top, anchorFor("top_center"));
    try t.expectEqual(layer.Anchor.top | layer.Anchor.right, anchorFor("mystery"));
}
