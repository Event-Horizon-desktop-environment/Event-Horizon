//! Taskbar paint helpers: the bar frame plus pure text/color math
//! (label ellipsizing, hot-track color,
//! title trimming). Cairo drawing stays thin; everything branchy is tested
//! here without a compositor.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const tokens = @import("../../m3/tokens.zig");
const cairo_helpers = @import("../shared/cairo_helpers.zig");
const pill_style = @import("../widgets/shared/pill.zig");

pub fn paintTaskbar(cr: ?*cairo.cairo_t, w: i32, h: i32, slot_count: usize, active: usize) void {
    if (cr == null) return;
    cairo_helpers.paintBar(cr, w, h, 12.0, 1.0);
    if (slot_count == 0) return;
    const c = cr.?;
    const sw: f64 = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(slot_count));
    var i: usize = 0;
    while (i < slot_count) : (i += 1) {
        if (i == active) {
            cairo.cairo_set_source_rgba(c, tokens.Tokens.accent.r, tokens.Tokens.accent.g, tokens.Tokens.accent.b, 0.35);
            cairo.cairo_rectangle(c, @as(f64, @floatFromInt(i)) * sw + 2, 2, sw - 4, @as(f64, @floatFromInt(h)) - 4);
            cairo.cairo_fill(c);
        }
    }
}

/// UTF-8 code-point length of the leading sequence at `s[0]`.
fn utf8Len(first: u8) usize {
    if ((first & 0x80) == 0) return 1;
    if ((first & 0xE0) == 0xC0) return 2;
    if ((first & 0xF0) == 0xE0) return 3;
    if ((first & 0xF8) == 0xF0) return 4;
    return 1;
}

/// Trim `title` so `measure` fits `max_w`, appending "…" (U+2026). The
/// measurer maps text → advance px; the walk is UTF-8 safe so multibyte
/// titles never split mid-sequence. Mirrors `tb_label_ellipsize`.
pub fn ellipsize(
    gpa: std.mem.Allocator,
    text: []const u8,
    max_w: f64,
    measure: *const fn ([]const u8) f64,
) ![]u8 {
    if (measure(text) <= max_w) return gpa.dupe(u8, text);
    const ell = "…";
    const ell_w = measure(ell);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const len = @min(utf8Len(text[i]), text.len - i);
        try out.appendSlice(gpa, text[i .. i + len]);
        i += len;
        if (measure(out.items) + ell_w > max_w) {
            // Drop the point that overflowed, then back off until the
            // ellipsis itself fits.
            out.items.len -= len;
            while (out.items.len > 0 and measure(out.items) + ell_w > max_w) {
                var e = out.items.len;
                e -= 1;
                while (e > 0 and (out.items[e] & 0xC0) == 0x80) e -= 1;
                out.items.len = e;
            }
            break;
        }
    }
    try out.appendSlice(gpa, ell);
    return out.toOwnedSlice(gpa);
}

/// Dominant icon color via a 27-bucket RGB histogram (channel thirds
/// 0-60/60-200/200-255), transparent pixels skipped, gray buckets
/// disqualified, first-wins ties. `pixels` is ARGB32 (BGRA bytes
/// little-endian). Mirrors `tb_hot_track_color`'s centroid choice.
pub fn hotTrack(pixels: []const u8, w: usize, h: usize, stride: usize) ?struct { r: f32, g: f32, b: f32 } {
    if (w == 0 or h == 0 or stride == 0) return null;
    var buckets: [3][3][3]u64 = @splat(@splat(@splat(0)));
    const step: usize = @max(1, @min(w, h) / 48);
    var y: usize = 0;
    while (y < h) : (y += step) {
        var x: usize = 0;
        while (x < w) : (x += step) {
            const off = y * stride + x * 4;
            if (off + 4 > pixels.len) break;
            if (pixels[off + 3] < 128) continue;
            const bi: usize = if (pixels[off] <= 60) 0 else if (pixels[off] <= 200) 1 else 2;
            const gi: usize = if (pixels[off + 1] <= 60) 0 else if (pixels[off + 1] <= 200) 1 else 2;
            const ri: usize = if (pixels[off + 2] <= 60) 0 else if (pixels[off + 2] <= 200) 1 else 2;
            if (bi == gi and gi == ri) continue;
            buckets[bi][gi][ri] += 1;
        }
    }
    var best: u64 = 0;
    var bb: ?usize = null;
    var bg: ?usize = null;
    var br: ?usize = null;
    for (0..3) |bi| for (0..3) |gi| for (0..3) |ri| {
        if (buckets[bi][gi][ri] > best) {
            best = buckets[bi][gi][ri];
            bb = bi;
            bg = gi;
            br = ri;
        }
    };
    if (best == 0) return null;
    const cent = [_]f32{ 30.0 / 255.0, 130.0 / 255.0, 228.0 / 255.0 };
    return .{ .r = cent[br.?], .g = cent[bg.?], .b = cent[bb.?] };
}

/// Rounded-rectangle path (shared by bar, cards and close buttons).
pub fn roundedRect(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r_in: f64) void {
    if (cr == null) return;
    const c = cr.?;
    const r = @min(r_in, @min(w * 0.5, h * 0.5));
    cairo.cairo_new_sub_path(c);
    cairo.cairo_arc(c, x + w - r, y + r, r, -std.math.pi / 2.0, 0);
    cairo.cairo_arc(c, x + w - r, y + h - r, r, 0, std.math.pi / 2.0);
    cairo.cairo_arc(c, x + r, y + h - r, r, std.math.pi / 2.0, std.math.pi);
    cairo.cairo_arc(c, x + r, y + r, r, std.math.pi, 3.0 * std.math.pi / 2.0);
    cairo.cairo_close_path(c);
}

// Win7 tasklist button decorations: the glass face (open apps only), the
// layered window sheets behind stacks, the cursor-centered color hot-track,
// the window-count badge and the overflow chevron's dots.

/// Sheets peeking from behind a stacked button: `min(count - 1, 2)`.
pub fn stackSheetsFor(window_count: usize) usize {
    if (window_count <= 1) return 0;
    return @min(window_count - 1, 2);
}

/// Hot-track glow centre: the cursor, clamped into the slot.
pub fn hotTrackCentreX(pointer_x: f64, slot_x: f64, slot_w: f64) f64 {
    return std.math.clamp(pointer_x - slot_x, 0.0, slot_w);
}

/// An icon's dominant color, or the fallback sky blue.
pub const Heat = struct {
    r: f64 = 0.55,
    g: f64 = 0.75,
    b: f64 = 1.0,
};

pub fn paintStackSheets(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, sheets: usize, ui: f64) void {
    const c = cr orelse return;
    const rad = pill_style.cornerRadius(h, w);
    var sh = sheets;
    while (sh >= 1) : (sh -= 1) {
        const off = 3.0 * @as(f64, @floatFromInt(sh)) * ui;
        roundedRect(c, x + off, y - off, w, h, rad);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, if (sh == sheets) 0.16 else 0.11);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.32);
        cairo.cairo_set_line_width(c, 1.25);
        cairo.cairo_stroke(c);
    }
}

/// Glass button face. Unopened pins stay bare; callers skip the face then.
pub fn paintWin7Face(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, focused: bool, accent: Heat) void {
    const c = cr orelse return;
    const rad = pill_style.cornerRadius(h, w);
    roundedRect(c, x, y, w, h, rad);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, if (focused) 0.22 else 0.13);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, if (focused) 0.45 else 0.22);
    cairo.cairo_set_line_width(c, if (focused) 1.5 else 1.0);
    cairo.cairo_stroke(c);
    cairo.cairo_save(c);
    roundedRect(c, x + 1.5, y + 1.5, w - 3.0, h * 0.45, rad * 0.7);
    cairo.cairo_clip(c);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, if (focused) 0.14 else 0.08);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
    if (focused) {
        roundedRect(c, x - 1.0, y - 1.0, w + 2.0, h + 2.0, rad + 1.0);
        cairo.cairo_set_source_rgba(c, accent.r, accent.g, accent.b, 0.35);
        cairo.cairo_set_line_width(c, 1.5);
        cairo.cairo_stroke(c);
    }
}

/// Color hot-track: radial glow centered on the cursor, white core fading
/// into the icon's dominant color, over the button's rounded-rect outline.
pub fn paintHotTrack(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, pointer_x: f64, col: Heat) void {
    const c = cr orelse return;
    const rad = pill_style.cornerRadius(h, w);
    const pcx = hotTrackCentreX(pointer_x, x, w);
    const prad = @max(w, h) * 0.9;
    roundedRect(c, x, y, w, h, rad);
    const pat = cairo.cairo_pattern_create_radial(x + pcx, y + h * 0.5, 1.0, x + pcx, y + h * 0.5, prad);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0.0, 1, 1, 1, 0.38);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0.35, col.r, col.g, col.b, 0.55);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 1.0, col.r, col.g, col.b, 0.0);
    cairo.cairo_set_source(c, pat);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_pattern_destroy(pat);
    cairo.cairo_set_source_rgba(c, col.r, col.g, col.b, 0.55);
    cairo.cairo_set_line_width(c, 1.25);
    cairo.cairo_stroke(c);
}

/// Window-count badge, top-right. No-op for zero/one window.
pub fn paintWindowBadge(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, ui: f64, count: usize) void {
    if (count <= 1) return;
    const c = cr orelse return;
    var buf: [24]u8 = undefined;
    const num = std.fmt.bufPrintZ(&buf, "{d}", .{count}) catch return;
    const br = @max(8.0, 8.5 * ui);
    const bcx = x + w - 3.0 * ui;
    const bcy = y + 3.0 * ui;
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, bcx, bcy, br, 0, 2 * std.math.pi);
    cairo.cairo_set_source_rgba(c, 0.10, 0.11, 0.13, 0.92);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.35);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
    cairo.cairo_set_font_size(c, @max(9.0, 10.5 * ui));
    var be: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    cairo.cairo_text_extents(c, num.ptr, &be);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.95);
    cairo.cairo_move_to(c, bcx - be.width / 2.0 - be.x_bearing, bcy - be.height / 2.0 - be.y_bearing);
    cairo.cairo_show_text(c, num.ptr);
}

/// Overflow chevron: three dots on its pill.
pub fn paintChevronDots(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    const c = cr orelse return;
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.85);
    const r = @max(1.5, h * 0.055);
    const cy = y + h * 0.5;
    var d: i32 = -1;
    while (d <= 1) : (d += 1) {
        cairo.cairo_arc(c, x + w * 0.5 + @as(f64, @floatFromInt(d)) * r * 3.0, cy, r, 0, 2 * std.math.pi);
        cairo.cairo_fill(c);
    }
}

/// Run indicator dot; `active` switches to the activated blue.
pub fn paintRunDot(cr: ?*cairo.cairo_t, cx: f64, cy: f64, active: bool) void {
    const c = cr orelse return;
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, cx, cy, 3.0, 0, 2 * std.math.pi);
    if (active) {
        cairo.cairo_set_source_rgba(c, 0.4, 0.7, 1.0, 0.95);
    } else {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.35);
    }
    cairo.cairo_fill(c);
}

/// Run dot vertical centre: just under the icon, kept inside the bar box.
pub fn runDotY(icon_bottom: f64, box_h: f64) f64 {
    return @min(icon_bottom + 3.0, box_h - 3.0);
}

test "taskbar-paint: slots render" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 800, 48);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintTaskbar(cr, 800, 48, 4, 1);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    // Empty and null are no-ops, never crashes.
    paintTaskbar(cr, 800, 48, 0, 0);
    paintTaskbar(null, 800, 48, 4, 1);
}

test "taskbar-paint: ellipsize keeps short text, trims long" {
    const t = std.testing;
    const meas = struct {
        fn f(s: []const u8) f64 {
            return @as(f64, @floatFromInt(s.len)) * 7.0;
        }
    }.f;
    const keep = try ellipsize(t.allocator, "hi", 100, &meas);
    defer t.allocator.free(keep);
    try t.expectEqualStrings("hi", keep);
    const cut = try ellipsize(t.allocator, "a very long window title", 60, &meas);
    defer t.allocator.free(cut);
    try t.expect(std.mem.endsWith(u8, cut, "…"));
    try t.expect(cut.len < "a very long window title".len);
}

test "taskbar-paint: hot-track finds the dominant color" {
    const t = std.testing;
    // 2x2 opaque red (BGRA: B=0 G=0 R=228 A=255) plus one transparent pixel.
    const px = [_]u8{
        0, 0, 228, 255, 0, 0, 228, 255,
        0, 0, 228, 255, 0, 0, 0,   0,
    };
    const c = hotTrack(&px, 2, 2, 8).?;
    try t.expect(c.r > c.b and c.r > c.g);
    // All gray → disqualified.
    const gray = [_]u8{ 130, 130, 130, 255, 130, 130, 130, 255 } ++ [_]u8{0} ** 0;
    try t.expect(hotTrack(&gray, 2, 1, 8) == null);
}

// Hover-preview (Win7 thumbnail cards), context menu, tooltip.
// Ports `taskbar_thumbs_paint` + `draw_context_menu` paint halves; geometry
// comes from `types.zig` so motion/click can never disagree with pixels.

const types = @import("types.zig");

pub const IconPx = struct {
    pixels: []const u8 = &.{},
    w: i32 = 0,
    h: i32 = 0,
};

fn blitIcon(cr: *cairo.cairo_t, icon: IconPx, cx: f64, cy: f64, size: f64) void {
    if (icon.pixels.len == 0 or icon.w <= 0 or icon.h <= 0) return;
    const avail = @max(4.0, size);
    const s = avail / @as(f64, @floatFromInt(@max(1, @max(icon.w, icon.h))));
    const tw: i32 = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(icon.w)) * s))));
    const th: i32 = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(icon.h)) * s))));
    const tmp = cairo.cairo_image_surface_create_for_data(
        @constCast(icon.pixels.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        icon.w,
        icon.h,
        icon.w * 4,
    );
    defer cairo.cairo_surface_destroy(tmp);
    if (cairo.cairo_surface_status(tmp) != cairo.CAIRO_STATUS_SUCCESS) return;
    cairo.cairo_save(cr);
    cairo.cairo_translate(cr, cx - @as(f64, @floatFromInt(tw)) * 0.5, cy - @as(f64, @floatFromInt(th)) * 0.5);
    cairo.cairo_scale(cr, @as(f64, @floatFromInt(tw)) / @as(f64, @floatFromInt(icon.w)), @as(f64, @floatFromInt(th)) / @as(f64, @floatFromInt(icon.h)));
    cairo.cairo_set_source_surface(cr, tmp, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_restore(cr);
}

fn textAdvance(cr: *cairo.cairo_t, text: []const u8) f64 {
    if (text.len == 0) return 0;
    var buf: [512]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    cairo.cairo_text_extents(cr, @ptrCast(&buf), &ex);
    return @max(0.0, ex.x_advance);
}

/// Trim with an ellipsis to `max_w` using the live cairo context.
/// UTF-8 safe; mirrors `thumbs_trim_title`. Paints from a caller-owned
/// scratch buffer (returned slice borrows it).
fn trimTitleBuf(cr: *cairo.cairo_t, text: []const u8, font_px: f64, max_w: f64, buf: *[512]u8) []const u8 {
    cairo.cairo_save(cr);
    defer cairo.cairo_restore(cr);
    cairo.cairo_select_font_face(cr, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(cr, font_px);
    const t = if (text.len == 0) "(untitled)" else text;
    if (textAdvance(cr, t) <= max_w) {
        const n = @min(t.len, buf.len);
        @memcpy(buf[0..n], t[0..n]);
        return buf[0..n];
    }
    const ell = "…";
    const ell_w = textAdvance(cr, ell);
    var len: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        const l = @min(utf8Len(t[i]), t.len - i);
        if (len + l >= buf.len) break;
        @memcpy(buf[len .. len + l], t[i .. i + l]);
        len += l;
        i += l;
        if (textAdvance(cr, buf[0..len]) + ell_w > max_w) {
            len -= l;
            while (len > 0 and textAdvance(cr, buf[0..len]) + ell_w > max_w) {
                var e = len - 1;
                while (e > 0 and (buf[e] & 0xC0) == 0x80) e -= 1;
                len = e;
            }
            break;
        }
    }
    const n = @min(ell.len, buf.len - len);
    @memcpy(buf[len .. len + n], ell[0..n]);
    return buf[0 .. len + n];
}

fn drawClose(cr: *cairo.cairo_t, x: f64, y: f64, sz: f64, hover: bool) void {
    if (hover) {
        roundedRect(cr, x, y, sz, sz, 5.0);
        cairo.cairo_set_source_rgba(cr, 0.85, 0.25, 0.22, 0.95);
        cairo.cairo_fill(cr);
    }
    cairo.cairo_set_source_rgba(cr, 1, 1, 1, if (hover) 0.95 else 0.65);
    cairo.cairo_set_line_width(cr, 1.6);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    const m = sz * 0.30;
    cairo.cairo_move_to(cr, x + m, y + m);
    cairo.cairo_line_to(cr, x + sz - m, y + sz - m);
    cairo.cairo_move_to(cr, x + sz - m, y + m);
    cairo.cairo_line_to(cr, x + m, y + sz - m);
    cairo.cairo_stroke(cr);
}

pub const ThumbItem = struct {
    title: []const u8 = "",
    icon: IconPx = .{},
    active: bool = false,
};

/// Win7 hover previews. `peek` dims non-hovered cards (Aero Peek);
/// `peek_zoom` draws the hovered icon larger.
pub fn paintThumbs(
    cr: ?*cairo.cairo_t,
    items: []const ThumbItem,
    list_mode: bool,
    hover_row: i32,
    close_hover: bool,
    peek: bool,
) void {
    const c = cr orelse return;
    if (items.len == 0) return;
    const g = types.thumbsGeom(items.len, list_mode);
    roundedRect(c, 0.5, 0.5, g.w - 1.0, g.h - 1.0, 10.0);
    cairo.cairo_set_source_rgba(c, 0.13, 0.13, 0.15, 0.96);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    if (g.list) {
        for (items, 0..) |it, i| {
            const hov = @as(i32, @intCast(i)) == hover_row;
            const dimmed = peek and hover_row >= 0 and !hov;
            const ry = types.thumb_pad + @as(f64, @floatFromInt(i)) * types.thumb_list_row_h;
            const rw = g.w - types.thumb_pad * 2.0;
            if (hov) {
                roundedRect(c, types.thumb_pad, ry, rw, types.thumb_list_row_h, 6.0);
                cairo.cairo_set_source_rgba(c, 0.32, 0.42, 0.62, 0.55);
                cairo.cairo_fill(c);
            }
            blitIcon(c, it.icon, types.thumb_pad + 17.0, ry + types.thumb_list_row_h * 0.5, 20.0);
            var title_buf: [512]u8 = undefined;
            const shown = trimTitleBuf(c, it.title, 12.0, rw - 34.0 - types.thumb_close_sz - 8.0, &title_buf);
            cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
            cairo.cairo_set_font_size(c, 12.0);
            cairo.cairo_set_source_rgba(c, 1, 1, 1, if (dimmed) 0.55 else 0.92);
            cairo.cairo_move_to(c, types.thumb_pad + 34.0, ry + types.thumb_list_row_h * 0.5 + 4.0);
            var tbuf: [512]u8 = undefined;
            const n = @min(shown.len, tbuf.len - 1);
            @memcpy(tbuf[0..n], shown[0..n]);
            tbuf[n] = 0;
            cairo.cairo_show_text(c, @ptrCast(&tbuf));
            if (hov) {
                const q = types.thumbsCloseRect(&g, i);
                drawClose(c, q.x, q.y, types.thumb_close_sz, close_hover);
            }
            if (it.active) {
                cairo.cairo_arc(c, types.thumb_pad + 6.0, ry + types.thumb_list_row_h * 0.5, 2.5, 0, 2 * std.math.pi);
                cairo.cairo_set_source_rgba(c, 0.45, 0.65, 1.0, 0.9);
                cairo.cairo_fill(c);
            }
        }
        return;
    }
    // Cards: non-hovered first (dimmed under the peeked card), hovered last.
    for (items, 0..) |it, i| {
        if (@as(i32, @intCast(i)) == hover_row) continue;
        paintThumbCard(c, &g, it, i, false, peek and hover_row >= 0, false);
    }
    if (hover_row >= 0 and @as(usize, @intCast(hover_row)) < items.len) {
        const i: usize = @intCast(hover_row);
        paintThumbCard(c, &g, items[i], i, true, false, close_hover);
    }
}

fn paintThumbCard(
    c: *cairo.cairo_t,
    g: *const types.ThumbGeom,
    it: ThumbItem,
    idx: usize,
    hov: bool,
    dimmed: bool,
    close_hov: bool,
) void {
    const r = types.thumbsCardRect(g, idx);
    roundedRect(c, r.x, r.y, g.card_w, g.card_h, 8.0);
    if (hov) cairo.cairo_set_source_rgba(c, 0.32, 0.42, 0.62, if (dimmed) 0.35 else 0.55) else cairo.cairo_set_source_rgba(c, 1, 1, 1, if (dimmed) 0.04 else 0.07);
    cairo.cairo_fill_preserve(c);
    if (hov) {
        cairo.cairo_set_source_rgba(c, 0.45, 0.65, 1.0, 0.9);
        cairo.cairo_set_line_width(c, 2.0);
    } else if (it.active) {
        cairo.cairo_set_source_rgba(c, 0.45, 0.65, 1.0, 0.45);
        cairo.cairo_set_line_width(c, 1.5);
    } else {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.10);
        cairo.cairo_set_line_width(c, 1.0);
    }
    cairo.cairo_stroke(c);
    const close_x0 = r.x + g.card_w - types.thumb_close_sz - 4.0;
    const title_max = (close_x0 - 8.0) - (r.x + 8.0);
    var card_title_buf: [512]u8 = undefined;
    const shown = trimTitleBuf(c, it.title, 12.0, title_max, &card_title_buf);
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, if (hov) cairo.CAIRO_FONT_WEIGHT_BOLD else cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, 12.0);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, if (dimmed) 0.55 else 0.92);
    cairo.cairo_move_to(c, r.x + 8.0, r.y + types.thumb_title_h * 0.5 + 4.0);
    var tbuf: [512]u8 = undefined;
    const n = @min(shown.len, tbuf.len - 1);
    @memcpy(tbuf[0..n], shown[0..n]);
    tbuf[n] = 0;
    cairo.cairo_show_text(c, @ptrCast(&tbuf));
    if (hov) {
        const q = types.thumbsCloseRect(g, idx);
        drawClose(c, q.x, q.y, types.thumb_close_sz, close_hov);
    }
    const px0 = r.x + 6.0;
    const py0 = r.y + types.thumb_title_h + 4.0;
    const pw = g.card_w - 12.0;
    const ph = types.thumb_preview_h - 4.0;
    roundedRect(c, px0, py0, pw, ph, 6.0);
    cairo.cairo_set_source_rgba(c, 0, 0, 0, if (dimmed) 0.30 else 0.45);
    cairo.cairo_fill(c);
    blitIcon(c, it.icon, px0 + pw * 0.5, py0 + ph * 0.5, if (hov) 52.0 else 34.0);
}

/// Context menu (tray/app): 26px rows, 13px separators, hover wash.
pub fn paintMenu(cr: ?*cairo.cairo_t, w: f64, items: []const types.PopupItem, hover: i32) void {
    const c = cr orelse return;
    roundedRect(c, 0, 0, w, menuHeight(items), 12.0);
    cairo.cairo_set_source_rgba(c, 0.12, 0.12, 0.13, 0.96);
    cairo.cairo_fill(c);
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, 13.0);
    var yy: f64 = 4.0;
    for (items, 0..) |it, idx| {
        if (it.isSeparator()) {
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.10);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_move_to(c, 10.0, yy + 13.0);
            cairo.cairo_line_to(c, w - 10.0, yy + 13.0);
            cairo.cairo_stroke(c);
            yy += 13.0;
            continue;
        }
        if (@as(i32, @intCast(idx)) == hover and it.enabled) {
            roundedRect(c, 4.0, yy, w - 8.0, 26.0, 6.0);
            cairo.cairo_set_source_rgba(c, 0.35, 0.55, 1.0, 0.16);
            cairo.cairo_fill(c);
        }
        cairo.cairo_set_source_rgba(c, 1, 1, 1, if (it.enabled) 0.87 else 0.35);
        cairo.cairo_move_to(c, 12.0, yy + 17.0);
        var tbuf: [256]u8 = undefined;
        const n = @min(it.label.len, tbuf.len - 1);
        @memcpy(tbuf[0..n], it.label[0..n]);
        tbuf[n] = 0;
        cairo.cairo_show_text(c, @ptrCast(&tbuf));
        yy += 26.0;
    }
}

pub fn menuHeight(items: []const types.PopupItem) f64 {
    var h: f64 = 8.0;
    for (items) |it| h += if (it.isSeparator()) 13.0 else 26.0;
    return h;
}

pub fn menuRowAt(items: []const types.PopupItem, py: f64) i32 {
    var yy: f64 = 4.0;
    for (items, 0..) |it, idx| {
        const rh: f64 = if (it.isSeparator()) 13.0 else 26.0;
        if (py >= yy and py < yy + rh) {
            if (it.isSeparator() or !it.enabled) return -1;
            return @intCast(idx);
        }
        yy += rh;
    }
    return -1;
}

/// Tooltip body: single-line label on a dark pill. `ov` is the tooltip
/// overlay knob (`overlay_opacity_tooltip`): 1.0 at default, it fades the
/// pill and the label together as the slider comes down.
pub fn paintTooltip(cr: ?*cairo.cairo_t, text: []const u8, w: f64, h: f64, ov: f64) void {
    const c = cr orelse return;
    roundedRect(c, 0.5, 0.5, w - 1.0, h - 1.0, 6.0);
    cairo.cairo_set_source_rgba(c, 0.10, 0.10, 0.11, 0.96 * ov);
    cairo.cairo_fill(c);
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, 12.0);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.92 * ov);
    cairo.cairo_move_to(c, 8.0, h - 8.0);
    var tbuf: [256]u8 = undefined;
    const n = @min(text.len, tbuf.len - 1);
    @memcpy(tbuf[0..n], text[0..n]);
    tbuf[n] = 0;
    cairo.cairo_show_text(c, @ptrCast(&tbuf));
}

test "taskbar-paint: menu metrics and hit" {
    const t = std.testing;
    const items = [_]types.PopupItem{
        .{ .id = 1, .label = "Open" },
        .{ .id = -1 },
        .{ .id = 2, .label = "Quit", .enabled = false },
    };
    try t.expectEqual(@as(f64, 8 + 26 + 13 + 26), menuHeight(&items));
    try t.expectEqual(@as(i32, 0), menuRowAt(&items, 10));
    try t.expectEqual(@as(i32, -1), menuRowAt(&items, 34));
    try t.expectEqual(@as(i32, -1), menuRowAt(&items, 50));
}

test "taskbar-paint: thumbs + menu + tooltip render" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 640, 300);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    const red = [_]u8{ 0, 0, 228, 255 } ** 64;
    const items = [_]ThumbItem{
        .{ .title = "Firefox", .icon = .{ .pixels = &red, .w = 8, .h = 8 }, .active = true },
        .{ .title = "Terminal", .icon = .{ .pixels = &red, .w = 8, .h = 8 } },
    };
    paintThumbs(cr, &items, false, 0, false, true);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    const menu = [_]types.PopupItem{.{ .id = 1, .label = "Open" }};
    paintMenu(cr, 200, &menu, 0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    paintTooltip(cr, "Firefox", 120, 28, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}

test "taskbar-paint: win7 sheets and hot-track geometry" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), stackSheetsFor(0));
    try t.expectEqual(@as(usize, 0), stackSheetsFor(1));
    try t.expectEqual(@as(usize, 1), stackSheetsFor(2));
    try t.expectEqual(@as(usize, 2), stackSheetsFor(3));
    try t.expectEqual(@as(usize, 2), stackSheetsFor(9));
    try t.expectEqual(@as(f64, 0.0), hotTrackCentreX(4.0, 10.0, 48.0));
    try t.expectEqual(@as(f64, 5.0), hotTrackCentreX(15.0, 10.0, 48.0));
    try t.expectEqual(@as(f64, 48.0), hotTrackCentreX(90.0, 10.0, 48.0));
    try t.expectEqual(@as(f64, 30.0), runDotY(27.0, 48.0));
    try t.expectEqual(@as(f64, 45.0), runDotY(80.0, 48.0));
}

test "taskbar-paint: win7 decorations render" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 400, 48);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintStackSheets(cr, 10.0, 4.0, 120.0, 40.0, 2, 1.0);
    paintWin7Face(cr, 10.0, 4.0, 120.0, 40.0, true, .{});
    paintHotTrack(cr, 10.0, 4.0, 120.0, 40.0, 60.0, .{ .r = 0.9, .g = 0.2, .b = 0.1 });
    paintWindowBadge(cr, 10.0, 4.0, 120.0, 1.0, 3);
    paintWindowBadge(cr, 10.0, 4.0, 120.0, 1.0, 1);
    paintChevronDots(cr, 200.0, 4.0, 40.0, 40.0);
    paintRunDot(cr, 300.0, 44.0, false);
    paintRunDot(cr, 320.0, 44.0, true);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
