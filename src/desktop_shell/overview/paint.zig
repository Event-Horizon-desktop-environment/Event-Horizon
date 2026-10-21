//! Pixels for the overview's workspace side.
//!
//! Dim backdrop, glassy workspace cards with a centered label pill, the top
//! search bar, and the bottom apps pill. Window tiles and captures arrive
//! with the host; this file stays to chrome that needs no backend data.

const cairo = @import("../../wl/buffer/shm.zig").cairo;
const dw = @import("../dock/widgets_paint.zig");
const glyph = @import("../common/material_glyph.zig");
const types = @import("types.zig");
const tiles = @import("tiles.zig");
const cairo_helpers = @import("../shared/cairo_helpers.zig");

const Layout = types.Layout;
const Colors = types.Colors;
const Rect = types.Rect;

fn setRgb(c: *cairo.cairo_t, rgb: [3]f64, a: f64) void {
    cairo.cairo_set_source_rgba(c, rgb[0], rgb[1], rgb[2], a);
}

pub fn paintDim(cr: ?*cairo.cairo_t, w: f64, h: f64, colors: Colors, alpha: f64) void {
    const c = cr orelse return;
    if (alpha <= 0.0) return;
    setRgb(c, colors.bg, alpha);
    cairo.cairo_rectangle(c, 0, 0, w, h);
    cairo.cairo_fill(c);
}

/// One workspace card: flat base, glass layers, the backdrop capture when
/// there is one (fitted inside the corners, under the state overlays),
/// then hover, selection, and drop cues. The backdrop scales once per
/// card size through `cache`, then blits 1:1. `chrome` is the pre-baked
/// fill-plus-glass for a card this size (blitted when alpha is 1) — the
/// gradients are identical every paint, so re-filling them is pure waste.
pub fn paintCardBody(
    cr: ?*cairo.cairo_t,
    card: Rect,
    colors: Colors,
    ui: f64,
    alpha: f64,
    selected: bool,
    hovered: bool,
    drop: bool,
    cache: *tiles.ScaledCache,
    bg_kind: tiles.SrcKind,
    bg_id: u64,
    bg: ?tiles.LiveFrame,
    chrome: ?*cairo.cairo_surface_t,
    base: ?*cairo.cairo_surface_t,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or card.w <= 0.0 or card.h <= 0.0) return;
    if (base) |surf| {
        cairo.cairo_set_source_surface(c, surf, card.x, card.y);
        cairo.cairo_paint(c);
    } else {
        if (chrome) |surf| {
            cairo.cairo_set_source_surface(c, surf, card.x, card.y);
            cairo.cairo_paint(c);
        } else {
            setRgb(c, colors.card_bg, 0.9 * alpha);
            cairo_helpers.roundedRect(c, card.x, card.y, card.w, card.h, 24.0 * ui);
            cairo.cairo_fill(c);
            dw.paintGlassLayers(c, card.x, card.y, card.w, card.h, alpha, 24.0 * ui);
        }
        if (bg) |fr| tiles.paintFrameCached(cache, c, bg_kind, bg_id, card, fr, alpha, 24.0 * ui);
    }
    if (hovered) {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.06 * alpha);
        cairo_helpers.roundedRect(c, card.x, card.y, card.w, card.h, 24.0 * ui);
        cairo.cairo_fill(c);
    }
    if (selected) {
        const acc = colors.accent;
        cairo.cairo_set_source_rgba(c, acc[0], acc[1], acc[2], 0.9 * alpha);
        cairo.cairo_set_line_width(c, 3.0 * ui);
        cairo_helpers.roundedRect(c, card.x, card.y, card.w, card.h, 24.0 * ui);
        cairo.cairo_stroke(c);
    }
    if (drop) {
        const acc = colors.accent;
        cairo.cairo_set_source_rgba(c, acc[0], acc[1], acc[2], 0.95 * alpha);
        cairo.cairo_set_line_width(c, 4.0 * ui);
        cairo_helpers.roundedRect(c, card.x, card.y, card.w, card.h, 24.0 * ui);
        cairo.cairo_stroke(c);
    }
}

pub fn paintSearch(cr: ?*cairo.cairo_t, l: *const Layout, colors: Colors, alpha: f64, query: []const u8) void {
    const c = cr orelse return;
    if (alpha <= 0.0) return;
    const x = l.center_x - l.search_w * 0.5;
    const y = l.search_y;
    setRgb(c, colors.search_bg, alpha);
    cairo_helpers.roundedRect(c, x, y, l.search_w, l.search_h, l.search_h * 0.5);
    cairo.cairo_fill(c);
    dw.paintGlassLayers(c, x, y, l.search_w, l.search_h, alpha, l.search_h * 0.5);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.14 * alpha);
    cairo.cairo_set_line_width(c, 1.0 * l.ui);
    cairo_helpers.roundedRect(c, x + 0.5, y + 0.5, l.search_w - 1.0, l.search_h - 1.0, l.search_h * 0.5);
    cairo.cairo_stroke(c);
    const dim = colors.dim_fg;
    _ = glyph.draw(c, "search", x + 20.0 * l.ui, y + l.search_h * 0.5, 18.0 * l.ui, dim[0], dim[1], dim[2], alpha);
    cairo.cairo_set_font_size(c, 13.0 * l.ui);
    if (query.len == 0) {
        setRgb(c, colors.dim_fg, alpha);
        cairo.cairo_move_to(c, x + 42.0 * l.ui, y + l.search_h * 0.66);
        cairo.cairo_show_text(c, "Type to search...");
    } else {
        setRgb(c, colors.fg, alpha);
        cairo.cairo_move_to(c, x + 42.0 * l.ui, y + l.search_h * 0.66);
        // Query is shell-owned UTF-8; cairo stops at the first NUL so a
        // scratch copy keeps a query with no terminator printable.
        var buf: [256]u8 = undefined;
        const n = @min(query.len, buf.len - 1);
        @memcpy(buf[0..n], query[0..n]);
        buf[n] = 0;
        cairo.cairo_show_text(c, buf[0..n :0]);
    }
}

pub fn paintAppsBtn(cr: ?*cairo.cairo_t, l: *const Layout, colors: Colors, alpha: f64, hovered: bool, back: bool) void {
    const c = cr orelse return;
    if (alpha <= 0.0) return;
    const b = l.apps_btn;
    if (b.w <= 0.0 or b.h <= 0.0) return;
    setRgb(c, colors.search_bg, alpha);
    cairo_helpers.roundedRect(c, b.x, b.y, b.w, b.h, b.h * 0.5);
    cairo.cairo_fill(c);
    dw.paintGlassLayers(c, b.x, b.y, b.w, b.h, alpha, b.h * 0.5);
    if (hovered) {
        const acc = colors.accent;
        cairo.cairo_set_source_rgba(c, acc[0], acc[1], acc[2], 0.6 * alpha);
    } else {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.14 * alpha);
    }
    cairo.cairo_set_line_width(c, 1.0 * l.ui);
    cairo_helpers.roundedRect(c, b.x + 0.5, b.y + 0.5, b.w - 1.0, b.h - 1.0, b.h * 0.5);
    cairo.cairo_stroke(c);
    const fg = colors.fg;
    // The launchpad's way back is the same pill with a back arrow.
    const mark = if (back) "arrow_back" else "dashboard";
    _ = glyph.draw(c, mark, b.x + b.w * 0.5, b.y + b.h * 0.5, b.h * 0.52, fg[0], fg[1], fg[2], alpha);
}

test "overview-paint: chrome paints without error" {
    const t = @import("std").testing;
    const layout = @import("layout.zig");
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 640, 480);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    var l: Layout = .{};
    layout.compute(&l, 640, 480, 2, 1.0, .vertical, 0.5, 24, 34, 420);
    const colors: Colors = .{};
    paintDim(cr, 640, 480, colors, 0.7);
    var cache = tiles.ScaledCache.init(t.allocator);
    defer cache.deinit();
    paintCardBody(cr, layout.cardRect(&l, 0, 0), colors, 1.0, 1.0, true, false, false, &cache, .wallpaper, 0, null, null, null);
    paintSearch(cr, &l, colors, 1.0, "");
    paintSearch(cr, &l, colors, 1.0, "term");
    paintAppsBtn(cr, &l, colors, 1.0, false, false);
    paintAppsBtn(cr, &l, colors, 1.0, true, true);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
