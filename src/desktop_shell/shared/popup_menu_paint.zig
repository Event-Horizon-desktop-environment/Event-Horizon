//! The dock's right-click menu chrome — the glass card, rows, separators and
//! hover treatment over a plain row list.
//!
//! Geometry is expressed in design pixels and multiplied by `us` at paint and
//! hit-test time, so the two can never drift apart: `rowAt` and `paintMenu`
//! both go through `rowHeight`.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const m3_box = @import("../../m3/core/primitives/box.zig");
const chrome = @import("../widgets/shared/chrome_colors.zig");
const text_layout = @import("../../text/layout.zig");
const cairo_helpers = @import("./cairo_helpers.zig");

/// One entry. `id` is what a click hands back to whoever built the menu:
/// `-1` is a separator.
pub const Row = struct {
    label: []const u8 = "",
    id: i32 = -1,
    enabled: bool = true,
    hover: bool = false,
};

pub fn isSeparator(r: Row) bool {
    return r.id < 0;
}

/// Design pixels — the sizes the menu is laid out at before `us` is applied.
/// `row_h`/`sep_h`/`pad_v` are `26`/`rowH/2`/`4`: the paint walks
/// `y = 4*us` and a separator costs half a row, so a menu is
/// `4 + 26*items + 13*seps + 4` design pixels tall.
pub const row_h: i32 = 26;
pub const sep_h: i32 = 13;
pub const pad_v: i32 = 4;
pub const pad_h: i32 = 16;
pub const font_pt: f64 = 13.0;
pub const radius: f64 = 10.0;
/// `paint_glass_card`'s `bgMul`: the card's fill is the dock fill knocked
/// back to a third, so the compositor's blur — matched by namespace — is
/// what mostly shows through it.
pub const bg_mul: f64 = 0.35;
/// The card's nominal alpha before the overlay-opacity scale. 0.78 is what
/// keeps the menu translucent without the rows losing contrast.
pub const base_alpha: f64 = 0.78;

pub fn scale(v: f64, us: f64) f64 {
    return v * us;
}

pub fn rowHeight(r: Row, us: f64) i32 {
    const base: f64 = if (isSeparator(r)) @floatFromInt(sep_h) else @floatFromInt(row_h);
    return @intFromFloat(std.math.round(base * us));
}

/// Total height. A separator is 8 px against a 32 px row, so a row-*count*
/// height over-allocates by 24 px per separator — which is why this wants the
/// rows rather than a number.
pub fn menuHeight(rows: []const Row, us: f64) i32 {
    const top: i32 = @intFromFloat(std.math.round(@as(f64, @floatFromInt(pad_v)) * us));
    var h: i32 = top * 2;
    for (rows) |r| h += rowHeight(r, us);
    return h;
}

/// `"Inter <px>"` — the description `text.Layout.setFont` wants.
pub fn fontDesc(buf: []u8, us: f64) ?[]const u8 {
    const px: i32 = @intFromFloat(std.math.round(font_pt * us));
    return std.fmt.bufPrint(buf, "Inter {d}", .{px}) catch null;
}

/// Widest label in `rows`, in pixels. Callers pad this out to a menu width;
/// separators and empty labels cannot make a menu wider.
pub fn widestLabel(cr: ?*cairo.cairo_t, rows: []const Row, us: f64) f64 {
    const c = cr orelse return 0;
    var fbuf: [64]u8 = undefined;
    const fd = fontDesc(&fbuf, us) orelse return 0;
    var l = text_layout.Layout.createForCairo(c);
    defer l.destroy();
    l.setFont(fd);
    var widest: f64 = 0;
    for (rows) |r| {
        if (isSeparator(r) or r.label.len == 0) continue;
        l.setText(r.label);
        const s = l.pixelSize();
        widest = @max(widest, @as(f64, @floatFromInt(s.w)));
    }
    return widest;
}

/// One UTF-8 scalar's length at `i`, `1` for a byte that does not start a
/// well-formed sequence: a cut lands on a scalar boundary, and a broken byte
/// trims rather than crashing.
fn scalarLen(label: []const u8, i: usize) usize {
    return std.unicode.utf8ByteSequenceLength(label[i]) catch 1;
}

/// `…` followed by the longest prefix of `label` that fits `max_w` — the
/// trim the taskbar runs on its slot titles (`trimOne`), measured through
/// the layout the menu itself paints with, so the cut and the draw agree.
/// `alloc` is the popup's arena: the replacement label dies with the menu
/// it was trimmed for.
fn ellipsizeLabel(alloc: std.mem.Allocator, l: *text_layout.Layout, label: []const u8, max_w: f64) ![]u8 {
    const ell: []const u8 = "…";
    l.setText(ell);
    const ell_w: f64 = @floatFromInt(l.pixelSize().w);
    var fit: usize = 0;
    while (fit < label.len) {
        const len = scalarLen(label, fit);
        if (fit + len > label.len) break;
        l.setText(label[0 .. fit + len]);
        if (@as(f64, @floatFromInt(l.pixelSize().w)) + ell_w > max_w) break;
        fit += len;
    }
    const out = try alloc.alloc(u8, fit + ell.len);
    @memcpy(out[0..fit], label[0..fit]);
    @memcpy(out[fit..], ell);
    return out;
}

/// Trim every row's label to `max_w` pixels with a trailing `…`, mutating
/// `rows` in place. A running window's title is a row and titles run pages
/// long — the caller passes the text width the menu's width cap allows
/// *before* `widestLabel`, so a trimmed row ends in the model instead of
/// painting past the card's inner edge, and the menu is sized to what is
/// left to draw. Separators and labels that already fit are untouched; an
/// allocation failure leaves the row as it would have been.
pub fn ellipsizeRows(alloc: std.mem.Allocator, cr: ?*cairo.cairo_t, rows: []Row, max_w: f64, us: f64) void {
    const c = cr orelse return;
    var fbuf: [64]u8 = undefined;
    const fd = fontDesc(&fbuf, us) orelse return;
    var l = text_layout.Layout.createForCairo(c);
    defer l.destroy();
    l.setFont(fd);
    for (rows) |*r| {
        if (isSeparator(r.*) or r.label.len == 0) continue;
        l.setText(r.label);
        if (@as(f64, @floatFromInt(l.pixelSize().w)) <= max_w) continue;
        r.label = ellipsizeLabel(alloc, &l, r.label, max_w) catch continue;
    }
}

/// The whole menu: the shared glass card, then rows, separators and the hover
/// pill over it. `colors`/`alpha` are the popup chrome and the
/// `overlay_surface_alpha_scale` for this menu's kind (tray menu vs dock
/// context menu) — the caller reads both off the config, so the menu thins
/// out with the rest of the shell's overlays.
pub fn paintMenu(
    cr: ?*cairo.cairo_t,
    w: i32,
    rows: []const Row,
    us: f64,
    colors: chrome.Chrome,
    alpha: f64,
) void {
    const c = cr orelse return;
    const h = menuHeight(rows, us);

    // Glass card fill: the dock fill knocked
    // back by `bgMul`, at `0.78 * alphaMul`, through the shared glassy Box —
    // drop shadow, milky lift, inner rim, outer hairline. The fill's alpha
    // below 1 is the whole point: it is what the compositor's namespace
    // blur reads through, so an opaque fill here would kill the effect.
    // No [0,1] clamp on `alpha`: `overlay.scale` already caps it at the
    // kind's `1/design`, which is how 100% on the page reaches a solid fill.
    var card = m3_box.Box{};
    card.setColor(
        @floatCast(colors.dock_fill.r * bg_mul),
        @floatCast(colors.dock_fill.g * bg_mul),
        @floatCast(colors.dock_fill.b * bg_mul),
        @floatCast(base_alpha * alpha),
    );
    // The drop shadow thins with the card: at low opacities a full-strength
    // shadow is all that is left of the menu. (At 100% it stays at the
    // design weight, like the dock's own slider.)
    card.shadow_a = 0.22 * std.math.clamp(alpha, 0.0, 1.0);
    card.setRadius(@floatCast(scale(radius, us)));
    card.setGeometry(0, 0, @floatFromInt(w), @floatFromInt(h));
    card.setGlassy(true);
    card.paint(c);

    var fbuf: [64]u8 = undefined;
    var maybe_layout: ?text_layout.Layout = null;
    if (fontDesc(&fbuf, us)) |fd| {
        var l = text_layout.Layout.createForCairo(c);
        l.setFont(fd);
        maybe_layout = l;
    }
    defer if (maybe_layout) |*l| l.destroy();

    const pad_x = scale(@floatFromInt(pad_h), us);
    const row_w = @as(f64, @floatFromInt(w)) - pad_x * 2.0;
    var y = scale(@floatFromInt(pad_v), us);
    for (rows) |r| {
        const rh = @as(f64, @floatFromInt(rowHeight(r, us)));
        if (isSeparator(r)) {
            // Separator rule: a white hairline at 0.10 across the
            // same inset the labels sit at.
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.10);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_move_to(c, pad_x, y + rh * 0.5);
            cairo.cairo_line_to(c, pad_x + row_w, y + rh * 0.5);
            cairo.cairo_stroke(c);
            y += rh;
            continue;
        }
        if (r.hover and r.enabled) {
            cairo.cairo_set_source_rgba(
                c,
                colors.accent.r,
                colors.accent.g,
                colors.accent.b,
                0.16,
            );
            cairo_helpers.roundedRect(
                c,
                scale(4.0, us),
                y,
                @as(f64, @floatFromInt(w)) - scale(8.0, us),
                rh,
                scale(6.0, us),
            );
            cairo.cairo_fill(c);
        }
        if (maybe_layout) |*l| {
            if (r.label.len > 0) {
                l.setText(r.label);
                const s = l.pixelSize();
                // `show` puts the top-left of the layout at the current point,
                // so this centres the text box in the row — which lands on
                // `y + 18*us` baseline for a 13 px font in a 26 px
                // row, within a pixel.
                cairo.cairo_set_source_rgba(c, 1, 1, 1, if (r.enabled) 0.92 else 0.45);
                cairo.cairo_move_to(c, pad_x, y + (rh - @as(f64, @floatFromInt(s.h))) * 0.5);
                l.show(c);
            }
        }
        y += rh;
    }
}

/// Row under a menu-local `y`, or null for the padding above the first row
/// or the empty space past the last one.
pub fn rowAt(y: i32, rows: []const Row, us: f64) ?usize {
    const top: i32 = @intFromFloat(std.math.round(@as(f64, @floatFromInt(pad_v)) * us));
    const rel = y - top;
    if (rel < 0) return null;
    var rest = rel;
    for (rows, 0..) |r, i| {
        const rh = rowHeight(r, us);
        if (rest < rh) return i;
        rest -= rh;
    }
    return null;
}

test "popup-menu: height counts separators, not rows" {
    const t = std.testing;
    const no_sep = [_]Row{ .{ .label = "a", .id = 1 }, .{ .label = "b", .id = 2 }, .{ .label = "c", .id = 3 } };
    // 4 px of pad at each end, 26 per row.
    try t.expectEqual(@as(i32, 3 * 26 + 8), menuHeight(&no_sep, 1.0));
    // One of those three rows is a separator: half a row (13) instead of 26.
    const with_sep = [_]Row{ .{ .label = "a", .id = 1 }, .{ .id = -1 }, .{ .label = "b", .id = 2 } };
    try t.expectEqual(@as(i32, 2 * 26 + 13 + 8), menuHeight(&with_sep, 1.0));
    try t.expectEqual(@as(i32, menuHeight(&with_sep, 1.0) * 2), menuHeight(&with_sep, 2.0));
}

test "popup-menu: hit rows agree with painted rows" {
    const t = std.testing;
    const rows = [_]Row{ .{ .label = "a", .id = 1 }, .{ .id = -1 }, .{ .label = "b", .id = 2 } };
    // 4 px of padding, then 26, then 13, then 26.
    try t.expectEqual(@as(usize, 0), rowAt(10, &rows, 1.0).?);
    try t.expectEqual(@as(usize, 1), rowAt(34, &rows, 1.0).?);
    try t.expectEqual(@as(usize, 2), rowAt(44, &rows, 1.0).?);
    try t.expect(rowAt(200, &rows, 1.0) == null);
    try t.expect(rowAt(3, &rows, 1.0) == null);
    // Everything still lines up at 2x.
    try t.expectEqual(@as(usize, 2), rowAt(88, &rows, 2.0).?);
    try t.expect(rowAt(5, &rows, 2.0) == null);
}

test "popup-menu: a page-long title is trimmed into the budget, others untouched" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 8, 8);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rows = [_]Row{
        .{ .label = "Unpin", .id = 3 },
        .{ .id = -1 },
        .{ .label = "Linux packages · many-pages-away/from-the-user@4da0eec and 5 more pages - Personal - Microsoft Edge Dev", .id = 2000 },
    };
    const budget: f64 = 420.0;
    ellipsizeRows(arena.allocator(), cr, &rows, budget, 1.0);
    try t.expectEqualStrings("Unpin", rows[0].label);
    try t.expect(std.mem.endsWith(u8, rows[2].label, "…"));
    // The cut label now measures inside the budget itself: the menu does not
    // widen past it — the trade the trim exists to make.
    var fbuf: [64]u8 = undefined;
    const fd = fontDesc(&fbuf, 1.0) orelse return;
    var l = text_layout.Layout.createForCairo(cr);
    defer l.destroy();
    l.setFont(fd);
    l.setText(rows[2].label);
    try t.expect(@as(f64, @floatFromInt(l.pixelSize().w)) <= budget);
}

test "popup-menu: paint is clean" {
    const t = std.testing;
    const rows = [_]Row{
        .{ .label = "Pin", .id = 3 },
        .{ .id = -1 },
        .{ .label = "Close all windows", .id = 2 },
        .{ .label = "Disabled", .id = 4, .enabled = false },
        .{ .label = "Hovered", .id = 5, .hover = true },
    };
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 240, menuHeight(&rows, 1.0));
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintMenu(cr, 240, &rows, 1.0, .{}, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    try t.expect(widestLabel(cr, &rows, 1.0) > 0);
}

test "popup-menu: the card is translucent, so the compositor's blur reads" {
    const t = std.testing;
    const rows = [_]Row{.{ .label = "Pin", .id = 3 }};
    const w: i32 = 240;
    const h = menuHeight(&rows, 1.0);
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
    defer cairo.cairo_surface_destroy(surf);
    // Start from a genuinely empty buffer the way the popup host clears its
    // frame: SOURCE-to-transparent, then paint on top.
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
    paintMenu(cr, w, &rows, 1.0, .{}, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);

    _ = cairo.cairo_surface_flush(surf);
    const data: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const stride: i32 = @intCast(cairo.cairo_image_surface_get_stride(surf));
    // Cairo's ARGB32 is little-endian premultiplied: byte 3 is alpha. The
    // sample has to be inside the fill *and* clear of the rows' labels: they
    // start at `pad_h`, so a fixed `x = 20` landed straight in the "Pin"
    // glyphs (white at 0.92) and read the text instead of the card. Measure
    // the widest label and sit just past it.
    const y: i32 = @divTrunc(h, 2);
    const label_edge: i32 = @intFromFloat(@ceil(widestLabel(cr, &rows, 1.0)));
    const x: i32 = @min(pad_h + label_edge + 8, w - 4);
    const alpha = data[@as(usize, @intCast(y)) * @as(usize, @intCast(stride)) + @as(usize, @intCast(x)) * 4 + 3];
    // 0.78 base alpha at full overlay scale, over the Box's own 0.22 drop
    // shadow (which the fill composites onto, lifting it) plus the glassy
    // milky lift: ~213/255. Translucent, but not so thin the rows lose
    // contrast — and thin enough that the namespace blur still reads.
    try t.expect(alpha > 150 and alpha < 220);
    // And full scale really is full: the alpha knob thins the card further.
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
    paintMenu(cr, w, &rows, 1.0, .{}, 0.5);
    _ = cairo.cairo_surface_flush(surf);
    const half = data[@as(usize, @intCast(y)) * @as(usize, @intCast(stride)) + @as(usize, @intCast(x)) * 4 + 3];
    try t.expect(half < alpha);
}
