const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const prefs = @import("preferences.zig");
const icon_item = @import("icon_item.zig");
const menu = @import("menu.zig");
const icon_menu = @import("icon_menu.zig");
const marquee = @import("marquee.zig");

/// Full desktop Cairo paint: icons + marquee + menus.
/// and the marquee rect in `core/desktop_layer`.
///
/// All functions are null-safe like the existing `paint.zig` so tests can
/// pass `null` and headless code can skip frames without branching.

pub fn paintIconPlate(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, hovered: bool, pressed_or_selected: bool) void {
    if (cr == null) return;
    const c = cr.?;
    if (hovered) {
        cairo.cairo_save(c);
        cairo.cairo_set_source_rgba(c, 0.25, 0.45, 0.85, 0.15);
        cairo.cairo_rectangle(c, x + 1, y + 1, w - 2, h - 2);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
    }
    if (pressed_or_selected) {
        cairo.cairo_save(c);
        cairo.cairo_set_source_rgba(c, 0.22, 0.42, 0.82, 0.2);
        cairo.cairo_rectangle(c, x + 1, y + 1, w - 2, h - 2);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, 0.4, 0.62, 0.98, 0.65);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_rectangle(c, x + 1.5, y + 1.5, w - 3, h - 3);
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);
    }
}

/// Drop shadow under the glyph: radial
/// `0,0,0,0.40 → 0,0,0,0.20 → transparent`, clipped to `0.7*icon_sz`.
pub fn paintIconShadow(cr: ?*cairo.cairo_t, cx: f64, cy: f64, icon_sz: f64) void {
    if (cr == null) return;
    const c = cr.?;
    const sr = icon_sz * 0.7;
    cairo.cairo_save(c);
    cairo.cairo_rectangle(c, cx - sr, cy - sr, sr * 2, sr * 2);
    cairo.cairo_clip(c);
    const pat = cairo.cairo_pattern_create_radial(cx, cy, 0, cx, cy, sr);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0, 0, 0, 0, 0.40);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0.5, 0, 0, 0, 0.20);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 1, 0, 0, 0, 0);
    cairo.cairo_set_source(c, pat);
    cairo.cairo_paint(c);
    cairo.cairo_pattern_destroy(pat);
    cairo.cairo_restore(c);
}

/// Label with the dark offset pass (`:903-912`).
pub fn paintIconLabel(cr: ?*cairo.cairo_t, text: []const u8, lx: f64, ly: f64, with_shadow: bool) void {
    if (cr == null) return;
    const c = cr.?;
    if (with_shadow) {
        cairo.cairo_save(c);
        cairo.cairo_move_to(c, lx + 1.0, ly + 1.0);
        cairo.cairo_set_source_rgba(c, 0.0, 0.0, 0.0, 0.35);
        cairo.cairo_show_text(c, text.ptr);
        cairo.cairo_restore(c);
    }
    cairo.cairo_move_to(c, lx, ly);
    cairo.cairo_set_source_rgba(c, 0.95, 0.96, 0.98, 1.0);
    cairo.cairo_show_text(c, text.ptr);
}

/// Truncate with `…` to fit `max_w` (`truncate_label`, `:497-513`).
pub fn truncateLabel(alloc: std.mem.Allocator, text: []const u8, max_chars: usize) ![]u8 {
    if (text.len <= max_chars) return alloc.dupe(u8, text);
    if (max_chars <= 1) return alloc.dupe(u8, "…");
    var out = try alloc.alloc(u8, max_chars);
    @memcpy(out[0 .. max_chars - 3], text[0 .. max_chars - 3]);
    @memcpy(out[max_chars - 3 ..], "…");
    return out;
}

/// Cairo-measured truncate (`truncate_label` exact port): shrink by one byte
/// until `cairo_text_extents.x_advance <= max_w`, append `…`.
/// `measure` answers advance width for a utf8 slice (cairo in prod, stub in tests).
pub fn truncateToWidth(alloc: std.mem.Allocator, text: []const u8, max_w: f64, measure: *const fn ([]const u8) f64) ![]u8 {
    if (measure(text) <= max_w) return alloc.dupe(u8, text);
    var len = text.len;
    while (len > 1) {
        len -= 1;
        const cand = try std.fmt.allocPrint(alloc, "{s}…", .{text[0..len]});
        errdefer alloc.free(cand);
        if (measure(cand) <= max_w) return cand;
        alloc.free(cand);
    }
    return alloc.dupe(u8, "…");
}

/// Label layout: centered `lx` for `shown` inside `cell_w` (`:895-902`).
/// `advance` is the cairo `x_advance` of `shown`.
pub fn labelX(cell_x: f64, cell_w: f64, advance: f64) f64 {
    return cell_x + (cell_w - advance) * 0.5;
}

pub fn labelY(cell_y: f64, cell_h: f64) f64 {
    return cell_y + cell_h - 10.0;
}

/// Full menu panel frame: glass highlight per row handled by caller;
/// this helper paints one row's text color (normal vs dimmed).
pub fn menuTextDimmed(panel: menu.Panel, row: i32, undo_empty: bool, marquee_empty: bool) bool {
    return menu.isRowDisabled(panel, row, undo_empty, marquee_empty);
}

/// Marquee rect (`desktop_layer` paint): fill `0.25,0.55,1,0.14`, dashed
/// `4,4` stroke `0.4,0.65,1,0.85`.
pub fn paintMarquee(cr: ?*cairo.cairo_t, r: marquee.Rect) void {
    if (cr == null) return;
    if (!marquee.shouldPaintRect(r)) return;
    const c = cr.?;
    const o = marquee.ordered(r);
    cairo.cairo_save(c);
    cairo.cairo_set_source_rgba(c, 0.25, 0.55, 1.0, 0.14);
    cairo.cairo_rectangle(c, o.x0, o.y0, o.x1 - o.x0, o.y1 - o.y0);
    cairo.cairo_fill(c);
    const dashes = [_]f64{ 4.0, 4.0 };
    cairo.cairo_set_dash(c, &dashes, 2, 0);
    cairo.cairo_set_source_rgba(c, 0.4, 0.65, 1.0, 0.85);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_rectangle(c, o.x0, o.y0, o.x1 - o.x0, o.y1 - o.y0);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
}

/// Menu row highlight.
pub fn paintMenuHighlight(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, row_h: f64, us: f64, alpha: f64) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_set_source_rgba(c, 0.18, 0.22, 0.3, 0.85 * alpha);
    cairo.cairo_rectangle(c, x + 2 * us, y, w - 4 * us, row_h);
    cairo.cairo_fill(c);
}

/// Menu separator line (`:432-441`).
pub fn paintMenuSeparator(cr: ?*cairo.cairo_t, x0: f64, x1: f64, y: f64, alpha: f64) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_save(c);
    cairo.cairo_new_path(c);
    cairo.cairo_set_source_rgba(c, 0.35, 0.38, 0.42, 0.7 * alpha);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_move_to(c, x0, y);
    cairo.cairo_line_to(c, x1, y);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
}

/// Check mark (`draw_check`, `:265-277`).
pub fn paintCheck(cr: ?*cairo.cairo_t, x: f64, y: f64, us: f64, alpha: f64) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_save(c);
    cairo.cairo_set_source_rgba(c, 0.85, 0.9, 0.98, 0.95 * alpha);
    cairo.cairo_set_line_width(c, 2.0);
    cairo.cairo_move_to(c, x, y + 8 * us);
    cairo.cairo_line_to(c, x + 4 * us, y + 12 * us);
    cairo.cairo_line_to(c, x + 12 * us, y + 4 * us);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
}

test "desktop_paint: plates + marquee + menu atoms" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintIconPlate(cr, 8, 8, 48, 48, true, true);
    paintIconShadow(cr, 32, 32, 48);
    paintIconLabel(cr, "Hi", 10, 50, true);
    paintMarquee(cr, .{ .x0 = 5, .y0 = 5, .x1 = 30, .y1 = 30 });
    paintMenuHighlight(cr, 0, 0, 200, 28, 1.0, 1.0);
    paintMenuSeparator(cr, 10, 190, 14, 1.0);
    paintCheck(cr, 10, 10, 1.0, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    const trunc = try truncateLabel(t.allocator, "hello world", 6);
    defer t.allocator.free(trunc);
    try t.expect(std.mem.endsWith(u8, trunc, "…"));
    _ = prefs.metricsFor(.small);
    _ = icon_item.IconKind.file;
    _ = menu.Panel.main;
    _ = icon_menu.CtxKind.open;
}

test "desktop_paint: measured truncate + label layout" {
    const t = std.testing;
    const M = struct {
        fn measure(s: []const u8) f64 {
            return @as(f64, @floatFromInt(s.len)) * 7.0;
        }
    };
    const w = try truncateToWidth(t.allocator, "hello world", 7.0 * 6.0, &M.measure);
    defer t.allocator.free(w);
    try t.expect(std.mem.endsWith(u8, w, "…"));
    try t.expectApproxEqAbs(@as(f64, 20 + (104 - 70) * 0.5), labelX(20, 104, 70), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 20 + 88 - 10), labelY(20, 88), 1e-9);
    try t.expect(menuTextDimmed(.main, 5, true, false));
}
