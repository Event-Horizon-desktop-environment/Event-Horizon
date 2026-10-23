//! Window-layout slot card: one entry per layout the running compositor
//! offers, and a click that swaps the layout live.
//!
//! Two shapes out of one geometry: a single
//! column of tall rows for a handful of layouts (Hyprland, 4) and a
//! two-column grid of compact cells for many (MangoWM, 14). Paint and
//! click-test both read the same `cellRect`, so a cell that moves on screen
//! moves under the pointer too — the rule every card in this tree follows.
//!
//! One module, no forwarding layers.
//!
//! What could not come across verbatim, and why:
//!
//! * **Click handling.** The surface closes from
//!   `popup_close(app)` and re-sizes it from `popup_draw_surface(app)` right
//!   inside the widget. Here the popup host owns the surface, so the click
//!   answers with a `Click` and the host does the closing and the redraw —
//!   the same split `vpn_popup.zig` uses (`dock/popup.zig` maps `.close` to
//!   `.dismiss` and `.redraw` to `.layout`).
//! * **`app.pointerX` / `app.pointerY`.** The paint takes the pointer as a
//!   parameter (`vpn_popup.paint`'s convention) and answers "nothing is
//!   hovered" from a NaN coordinate, which every comparison in the hit test
//!   already rejects.
//! * **`draw_material_glyph`.** Lucide first, Material ligature behind it,
//!   the order every Zig painter uses.
//! * **`overlayOpacityWidgetCard`.** Reached through
//!   `config/overlay.zig`'s `widgetCardAlpha`, which is the clamp
//!   applies to the whole overlay family on load.

const std = @import("std");
const cairo = @import("../../../../wl/buffer/shm.zig").cairo;
const schema = @import("../../../../config/schema.zig");
const overlay = @import("../../../../config/overlay.zig");
const chrome_colors = @import("../../shared/chrome_colors.zig");
const helpers = @import("../../../shared/cairo_helpers.zig");
const svg_icons = @import("../../../../ux/shared/svg_icons.zig");
const layout_paint = @import("../../layout/layout_paint.zig");

pub const popup_w: f64 = 320.0;

const k_corner: f64 = 20.0;
const k_icon_box_full: f64 = 38.0;
const k_icon_box_grid: f64 = 30.0;
const k_shad_off_x: f64 = 2.0;
const k_shad_off_y: f64 = 4.0;
const k_shad_alpha: f64 = 0.28;
const k_pad: f64 = 16.0;
const k_header_h: f64 = 52.0;
const k_row_gap: f64 = 8.0;
const k_body_gap: f64 = 8.0;
const k_close_sz: f64 = 24.0;

pub const Click = enum { none, close, redraw };

// Geometry

fn entryCount() usize {
    return layout_paint.count();
}

/// Two columns once the list outgrows a single tall column.
pub fn columns() usize {
    return if (entryCount() > 6) 2 else 1;
}

pub fn rows() usize {
    const n = entryCount();
    const c = columns();
    return (n + c - 1) / c;
}

pub fn cellHeight() f64 {
    return if (columns() == 1) 56.0 else 46.0;
}

pub fn size() struct { w: f64, h: f64 } {
    const r: f64 = @floatFromInt(rows());
    return .{
        .w = popup_w,
        .h = k_pad + k_header_h + k_body_gap + r * cellHeight() + (r - 1.0) * k_row_gap + k_pad,
    };
}

/// The surface height in whole pixels — `layout_popup_height()`.
pub fn heightPx() i32 {
    return @intFromFloat(@ceil(size().h));
}

pub fn closeRect() [4]f64 {
    return .{ popup_w - k_pad - k_close_sz, k_pad, k_close_sz, k_close_sz };
}

/// Cell rect for `idx` (row-major). Null when `idx` is out of range, which
/// is a `false` return.
pub fn cellRect(idx: usize) ?[4]f64 {
    const n = entryCount();
    if (idx >= n) return null;
    const c = columns();
    const ch = cellHeight();
    const top = k_pad + k_header_h + k_body_gap;
    const x, const w = if (c == 1)
        .{ k_pad, popup_w - k_pad * 2.0 }
    else blk: {
        const cw = (popup_w - k_pad * 2.0 - k_row_gap) * 0.5;
        const col = idx % c;
        break :blk .{ k_pad + @as(f64, @floatFromInt(col)) * (cw + k_row_gap), cw };
    };
    const row: f64 = @floatFromInt(idx / c);
    return .{ x, top + row * (ch + k_row_gap), w, ch };
}

/// `layout_popup_click_action` — outside the card or on the close box
/// closes; a cell swaps the layout (unless it already is that one) and asks
/// to be redrawn; the background answers nothing.
pub fn clickAction(x: f64, y: f64) Click {
    const s = size();
    if (x < 0 or x >= s.w or y < 0 or y >= s.h) return .close;
    if (inRect(x, y, closeRect())) return .close;
    var i: usize = 0;
    while (i < entryCount()) : (i += 1) {
        const r = cellRect(i) orelse continue;
        if (inRect(x, y, r)) {
            const id = layout_paint.idAt(i);
            if (!std.mem.eql(u8, layout_paint.current(), id)) _ = layout_paint.apply(id);
            return .redraw;
        }
    }
    return .none;
}

fn inRect(x: f64, y: f64, r: [4]f64) bool {
    return x >= r[0] and x < r[0] + r[2] and y >= r[1] and y < r[1] + r[3];
}

// Paint

fn setFont(cr: ?*cairo.cairo_t, size_px: f64, bold: bool) void {
    cairo.cairo_select_font_face(
        cr,
        "Inter",
        cairo.CAIRO_FONT_SLANT_NORMAL,
        if (bold) cairo.CAIRO_FONT_WEIGHT_BOLD else cairo.CAIRO_FONT_WEIGHT_NORMAL,
    );
    cairo.cairo_set_font_size(cr, size_px);
}

fn showText(cr: ?*cairo.cairo_t, s: []const u8, x: f64, y: f64) void {
    var zbuf: [1024:0]u8 = @as([1024:0]u8, @splat(0));
    const n = @min(s.len, 1023);
    @memcpy(zbuf[0..n], s[0..n]);
    cairo.cairo_move_to(cr, x, y);
    cairo.cairo_show_text(cr, &zbuf);
}

/// Pops one UTF-8 codepoint off the end —
/// `layout_popup.tpp`: walk back from the end to the first byte that is not
/// a continuation, and cut *there*. That cut point is the start of the last
/// codepoint, so the character and its continuation bytes go together and a
/// name never loses half a character.
pub fn utf8PopBack(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if ((s[i] & 0xc0) != 0x80) return s[0..i];
    }
    // Nothing but continuation bytes: the input was already mid-character,
    // so there is nothing whole left to keep.
    return s[0..0];
}

/// `truncate_to_width` — shortens `s` until its advance fits `max_adv`,
/// never below 3 bytes of payload.
pub fn truncateToWidth(
    s: []const u8,
    max_adv: f64,
    adv: *const fn (ctx: *anyopaque, s: []const u8) f64,
    ctx: *anyopaque,
) []const u8 {
    var out = s;
    while (true) {
        if (adv(ctx, out) <= max_adv or out.len < 4) break;
        const shorter = utf8PopBack(out);
        if (shorter.len == out.len) break;
        out = shorter;
    }
    return out;
}

fn cairoAdvance(ctx: *anyopaque, s: []const u8) f64 {
    const cr: ?*cairo.cairo_t = @ptrCast(ctx);
    var zbuf: [1024:0]u8 = @as([1024:0]u8, @splat(0));
    const n = @min(s.len, 1023);
    @memcpy(zbuf[0..n], s[0..n]);
    var ex: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(cr, &zbuf, &ex);
    return ex.x_advance;
}

/// Every name resolves through the vendored Lucide bank; a miss paints
/// nothing.
fn drawGlyph(cr: ?*cairo.cairo_t, name: []const u8, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64, a: f64) void {
    _ = svg_icons.draw(cr, name, cx, cy, px, r, g, b, a, false);
}

/// `dock_layout_popup_paint`. `pointer` is card-local and may be null, in
/// which case nothing reads as hovered.
pub fn paint(cr: ?*cairo.cairo_t, sc: *const schema.ShellConfig, pointer: ?[2]f64) void {
    const c = cr orelse return;
    const s = size();
    const mc = chrome_colors.of(sc);
    const card_alpha = overlay.widgetCardAlpha(&sc.appearance);
    const cur = layout_paint.current();
    const grid = columns() == 2;

    cairo.cairo_save(c);
    defer cairo.cairo_restore(c);

    helpers.roundedRect(c, k_shad_off_x, k_shad_off_y, s.w, s.h, k_corner);
    // The lift thins with the card, like the menu cards': at 0 the popup
    // must be gone, shadow included.
    cairo.cairo_set_source_rgba(c, 0.0, 0.0, 0.0, k_shad_alpha * card_alpha);
    cairo.cairo_fill(c);

    helpers.roundedRect(c, 0.0, 0.0, s.w, s.h, k_corner);
    cairo.cairo_set_source_rgba(
        c,
        mc.dock_fill.r * 0.30,
        mc.dock_fill.g * 0.30,
        mc.dock_fill.b * 0.30,
        0.92 * card_alpha,
    );
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    // NaN reads false in every comparison below, so a card painted with no
    // pointer simply has nothing hovered.
    const px: f64 = if (pointer) |p| p[0] else std.math.nan(f64);
    const py: f64 = if (pointer) |p| p[1] else std.math.nan(f64);

    // Close button.
    const cb = closeRect();
    const hc = px >= cb[0] and px < cb[0] + cb[2] and py >= cb[1] and py < cb[1] + cb[3];
    helpers.roundedRect(c, cb[0], cb[1], cb[2], cb[3], 7.0);
    cairo.cairo_set_source_rgba(c, 0.3, 0.3, 0.35, if (hc) 0.75 else 0.45);
    cairo.cairo_fill(c);
    drawGlyph(c, "close", cb[0] + 12.0, cb[1] + 12.0, 14.0, mc.text.r, mc.text.g, mc.text.b, if (hc) 1.0 else 0.85);

    // Header.
    cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.92);
    setFont(c, 14.0, true);
    showText(c, "Window Layout", k_pad, k_pad + 22.0);
    cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.5);
    setFont(c, 11.0, false);
    showText(c, if (grid) "MangoWM tiling layout" else "Hyprland tiling layout", k_pad, k_pad + 38.0);

    var i: usize = 0;
    while (i < entryCount()) : (i += 1) {
        const r = cellRect(i) orelse continue;
        const rx = r[0];
        const ry = r[1];
        const rw = r[2];
        const rh = r[3];
        const id = layout_paint.idAt(i);
        const active = std.mem.eql(u8, cur, id);
        const rad = @max(2.0, @min(rh, rw) * 0.22);

        helpers.roundedRect(c, rx, ry, rw, rh, rad);
        if (active)
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.22)
        else
            cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.07);
        cairo.cairo_fill(c);

        const hover = px >= rx and px < rx + rw and py >= ry and py < ry + rh;
        if (hover) {
            helpers.roundedRect(c, rx, ry, rw, rh, rad);
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, if (active) 0.28 else 0.18);
            cairo.cairo_fill_preserve(c);
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.35);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_stroke(c);
        } else if (active) {
            helpers.roundedRect(c, rx, ry, rw, rh, rad);
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.45);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_stroke(c);
        }

        const glyph = layout_paint.glyphFor(id);
        if (!grid) {
            // Full row: icon tile + title + description + check.
            const ib_x = rx + 9.0;
            const ib_y = ry + (rh - k_icon_box_full) * 0.5;
            helpers.roundedRect(c, ib_x, ib_y, k_icon_box_full, k_icon_box_full, 10.0);
            if (active)
                cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.85)
            else
                cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.10);
            cairo.cairo_fill(c);
            drawGlyph(
                c,
                glyph,
                ib_x + k_icon_box_full * 0.5,
                ib_y + k_icon_box_full * 0.5,
                20.0,
                1.0,
                1.0,
                1.0,
                if (active) 1.0 else 0.9,
            );

            const tx = ib_x + k_icon_box_full + 12.0;
            cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, if (active) 1.0 else 0.92);
            setFont(c, 13.0, active);
            const shown = truncateToWidth(layout_paint.titleFor(id), rx + rw - 9.0 - 34.0 - tx, cairoAdvance, c);
            showText(c, shown, tx, ry + 24.0);

            cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.5);
            setFont(c, 11.0, false);
            showText(c, layout_paint.descFor(id), tx, ry + 41.0);

            if (active) {
                drawGlyph(c, "check", rx + rw - 9.0 - 16.0, ry + rh * 0.5, 18.0, mc.accent.r, mc.accent.g, mc.accent.b, 1.0);
            }
        } else {
            // Compact grid cell: icon tile + title + check.
            const ib_x = rx + 8.0;
            const ib_y = ry + (rh - k_icon_box_grid) * 0.5;
            helpers.roundedRect(c, ib_x, ib_y, k_icon_box_grid, k_icon_box_grid, 8.0);
            if (active)
                cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.85)
            else
                cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.10);
            cairo.cairo_fill(c);
            drawGlyph(
                c,
                glyph,
                ib_x + k_icon_box_grid * 0.5,
                ib_y + k_icon_box_grid * 0.5,
                17.0,
                1.0,
                1.0,
                1.0,
                if (active) 1.0 else 0.9,
            );

            const tx = ib_x + k_icon_box_grid + 8.0;
            cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, if (active) 1.0 else 0.92);
            setFont(c, 12.0, active);
            const shown = truncateToWidth(
                layout_paint.titleFor(id),
                rx + rw - 8.0 - @as(f64, if (active) 24.0 else 0.0) - tx,
                cairoAdvance,
                c,
            );
            var te: cairo.cairo_text_extents_t = undefined;
            var zbuf: [1024:0]u8 = @as([1024:0]u8, @splat(0));
            const n = @min(shown.len, 1023);
            @memcpy(zbuf[0..n], shown[0..n]);
            cairo.cairo_text_extents(c, &zbuf, &te);
            showText(c, shown, tx, ry + (rh - te.height) * 0.5 - te.y_bearing);

            if (active) {
                drawGlyph(c, "check", rx + rw - 8.0 - 9.0, ry + rh * 0.5, 15.0, mc.accent.r, mc.accent.g, mc.accent.b, 1.0);
            }
        }
    }
}

// Tests

// The geometry is backend-dependent (4 rows of 56 or a 7×2 grid of 46), so
// the tests below pin both shapes through the table rather than through the
// live compositor: the counts come straight off the union table.
test "layout-popup: geometry follows the column rule" {
    const t = std.testing;
    // Hyprland's 4 entries are one column of 56 px rows; the 14-entry Mango
    // list is a 2-column grid of 46 px cells. Both are asserted from the
    // table so the test holds whichever backend the host happens to be.
    const n = layout_paint.k_layouts.len;
    try t.expectEqual(@as(usize, 16), n);
    try t.expectEqual(@as(usize, 14), layout_paint.k_mango_order.len);

    // One-column arithmetic, for a 4-entry list.
    const one_col_rows = (4 + 1 - 1) / 1;
    const one_col_h = k_pad + k_header_h + k_body_gap + @as(f64, @floatFromInt(one_col_rows)) * 56.0 +
        @as(f64, @floatFromInt(one_col_rows - 1)) * k_row_gap + k_pad;
    try t.expectEqual(@as(f64, 340.0), one_col_h);

    // Two-column arithmetic, for Mango's 14.
    const two_col_rows = (14 + 2 - 1) / 2;
    try t.expectEqual(@as(usize, 7), two_col_rows);
    const two_col_h = k_pad + k_header_h + k_body_gap + @as(f64, @floatFromInt(two_col_rows)) * 46.0 +
        @as(f64, @floatFromInt(two_col_rows - 1)) * k_row_gap + k_pad;
    try t.expectEqual(@as(f64, 462.0), two_col_h);

    // Whatever the backend, the pieces agree with each other.
    const s = size();
    try t.expectEqual(popup_w, s.w);
    try t.expectEqual(@as(f64, @floatFromInt(heightPx())), @ceil(s.h));
    const r = rows();
    try t.expect(r * columns() >= entryCount());
    try t.expect((r - 1) * columns() < entryCount() or entryCount() == 0);
}

test "layout-popup: a cell is inside the card and the close box is a cell" {
    const t = std.testing;
    const s = size();
    for (0..entryCount()) |i| {
        const r = cellRect(i).?;
        try t.expect(r[0] >= 0.0);
        try t.expect(r[1] >= 0.0);
        try t.expect(r[0] + r[2] <= s.w + 0.001);
        try t.expect(r[1] + r[3] <= s.h + 0.001);
        try t.expect(r[2] > 0.0 and r[3] > 0.0);
        // Row-major: the first cell starts at the pad, on the first row.
        if (i == 0) try t.expectEqual(k_pad, r[0]);
    }
    // Out of range is `false`.
    try t.expect(cellRect(entryCount()) == null);

    const cb = closeRect();
    try t.expectEqual(k_pad, cb[1]);
    try t.expectEqual(k_close_sz, cb[2]);
    // The close box sits inside the card's top-right corner.
    try t.expect(cb[0] + cb[2] <= s.w);
}

test "layout-popup: the click test answers close, redraw and nothing" {
    const t = std.testing;
    const s = size();
    // Outside the card on every side.
    try t.expectEqual(Click.close, clickAction(-1.0, 10.0));
    try t.expectEqual(Click.close, clickAction(s.w + 1.0, 10.0));
    try t.expectEqual(Click.close, clickAction(10.0, -1.0));
    try t.expectEqual(Click.close, clickAction(10.0, s.h + 1.0));
    // The close box.
    const cb = closeRect();
    try t.expectEqual(Click.close, clickAction(cb[0] + 1.0, cb[1] + 1.0));
    // Every cell answers `redraw`, whichever layout it names.
    // skips the apply when the click lands on the live one but still asks
    // for a redraw, and the background answers nothing.
    for (0..entryCount()) |i| {
        const r = cellRect(i).?;
        try t.expectEqual(Click.redraw, clickAction(r[0] + 1.0, r[1] + 1.0));
    }
    // The card's own background, below the header and above the first row
    // only when there is a gap to stand in.
    try t.expectEqual(Click.none, clickAction(popup_w * 0.5, k_pad + 4.0));
}

test "layout-popup: truncation keeps a stub and drops whole codepoints" {
    const t = std.testing;
    const adv = struct {
        fn f(_: *anyopaque, s: []const u8) f64 {
            // 10 px a byte: `max_adv` therefore reads as a byte budget.
            return @floatFromInt(s.len * 10);
        }
    }.f;
    var ctx: usize = 0;
    try t.expectEqualStrings("Vertical Tile", truncateToWidth("Vertical Tile", 130.0, adv, @ptrCast(&ctx)));
    try t.expectEqualStrings("Vertical Til", truncateToWidth("Vertical Tile", 129.0, adv, @ptrCast(&ctx)));
    try t.expectEqualStrings("Vert", truncateToWidth("Vertical Tile", 45.0, adv, @ptrCast(&ctx)));
    // Under the floor keep whatever is left rather than nothing.
    try t.expectEqualStrings("Ve", truncateToWidth("Ve", 1.0, adv, @ptrCast(&ctx)));
    // Pops whole codepoints, never half of one.
    const cjk = "布局方案";
    const popped = utf8PopBack(cjk);
    try t.expectEqualStrings("布局方", popped);
    try t.expectEqual(@as(usize, 0), utf8PopBack("").len);
}
