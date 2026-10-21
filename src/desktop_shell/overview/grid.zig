//! App-grid geometry for the overview's launchpad mode.
//!
//! The grid is capped in width so ultrawide outputs do not stretch it, fills
//! its viewport, and scrolls when more rows are needed. The folder modal is
//! the same cell with a fixed four columns and up to four visible rows.

const std = @import("std");
const types = @import("types.zig");

const Grid = types.Grid;
const Rect = types.Rect;

fn resScale(w: f64, h: f64) f64 {
    if (w <= 0.0 or h <= 0.0) return 1.0;
    return @min(1.75, @max(1.0, @min(w, h) / 900.0));
}

fn clampScroll(v: f64, max: f64) f64 {
    return @min(@max(0.0, max), @max(0.0, v));
}

/// Main grid between the search bar and the bottom chrome.
pub fn computeGrid(g: *Grid, w: f64, h: f64, search_y: f64, ui: f64, n_apps: i32, reserve: f64) void {
    g.* = .{};
    const s = ui * resScale(w, h);
    const top = search_y + 50.0 * s;
    const bottom = h - (60.0 + reserve) * s;
    const avail_h = bottom - top;
    if (avail_h <= 0.0) return;

    g.icon_size = 64.0 * s;
    g.font_size = 12.5 * s;
    g.cell_w = g.icon_size + 56.0 * s;
    g.cell_h = g.icon_size + g.font_size + 24.0 * s;
    const max_w = @min(w - 80.0 * s, 1060.0 * s);
    g.cols = @max(1, @as(i32, @intFromFloat(max_w / g.cell_w)));
    g.rows = @max(1, @as(i32, @intFromFloat(avail_h / g.cell_h)));
    if (g.cols < 4) g.cols = 4;

    const needed: i32 = @max(1, @divTrunc(@max(n_apps, 1) + g.cols - 1, g.cols));
    if (needed > g.rows) g.scroll_max = @as(f64, @floatFromInt(needed - g.rows)) * g.cell_h;

    const total_w: f64 = @as(f64, @floatFromInt(g.cols)) * g.cell_w;
    const total_h: f64 = @as(f64, @floatFromInt(g.rows)) * g.cell_h;
    g.start_x = (w - total_w) * 0.5;
    g.start_y = top + (avail_h - total_h) * 0.5;
}

/// Folder modal: four columns, up to four rows, own scroll past that.
pub fn computeModal(m: *Grid, w: f64, h: f64, ui: f64, n_apps: i32) void {
    m.* = .{};
    const s = ui * resScale(w, h);
    m.icon_size = 64.0 * s;
    m.font_size = 12.5 * s;
    m.cell_w = m.icon_size + 56.0 * s;
    m.cell_h = m.icon_size + m.font_size + 24.0 * s;
    m.cols = 4;
    const needed: i32 = @max(1, @divTrunc(@max(n_apps, 1) + m.cols - 1, m.cols));
    const vis: i32 = @min(4, @max(1, needed));
    m.rows = vis;
    if (needed > vis) m.scroll_max = @as(f64, @floatFromInt(needed - vis)) * m.cell_h;
    m.start_x = (w - @as(f64, @floatFromInt(m.cols)) * m.cell_w) * 0.5;
    m.start_y = (h - @as(f64, @floatFromInt(vis)) * m.cell_h) * 0.5 + 12.0 * s;
}

/// Cell origin for item `idx`, scrolled into the viewport.
pub fn cellRect(g: *const Grid, idx: i32, scroll: f64) Rect {
    if (g.cols <= 0 or g.cell_w <= 0.0 or g.cell_h <= 0.0 or idx < 0) return .{};
    const sc = clampScroll(scroll, g.scroll_max);
    const col: i32 = @rem(idx, g.cols);
    const row: i32 = @divTrunc(idx, g.cols);
    return .{
        .x = g.start_x + @as(f64, @floatFromInt(col)) * g.cell_w,
        .y = g.start_y + @as(f64, @floatFromInt(row)) * g.cell_h - sc,
        .w = g.cell_w,
        .h = g.cell_h,
    };
}

/// Item under the pointer, or -1. The closing bounds check keeps clicks in
/// the column gap from rounding into a neighbour.
pub fn pickCell(g: *const Grid, mx: f64, my: f64, n_apps: i32, scroll: f64) i32 {
    if (g.cols <= 0 or g.rows <= 0 or n_apps <= 0 or g.cell_w <= 0.0 or g.cell_h <= 0.0) return -1;
    const sc = clampScroll(scroll, g.scroll_max);
    const col: i32 = @intFromFloat((mx - g.start_x) / g.cell_w);
    const row: i32 = @intFromFloat((my - g.start_y + sc) / g.cell_h);
    if (col < 0 or col >= g.cols or row < 0 or row >= g.rows) return -1;
    const idx = row * g.cols + col;
    if (idx >= n_apps) return -1;
    const cx = g.start_x + @as(f64, @floatFromInt(col)) * g.cell_w;
    const cy = g.start_y + @as(f64, @floatFromInt(row)) * g.cell_h - sc;
    if (mx < cx or mx > cx + g.cell_w or my < cy or my > cy + g.cell_h) return -1;
    return idx;
}

/// Modal box around the folder grid; the title sits above it.
pub fn modalBox(m: *const Grid, ui: f64) Rect {
    return .{
        .w = @as(f64, @floatFromInt(m.cols)) * m.cell_w + 32.0 * ui,
        .h = @as(f64, @floatFromInt(m.rows)) * m.cell_h + 32.0 * ui,
        .x = m.start_x - 16.0 * ui,
        .y = m.start_y - 16.0 * ui,
    };
}

/// Page dots under the grid: hidden when everything fits one page.
pub fn pageCount(g: *const Grid) i32 {
    if (g.cols <= 0 or g.rows <= 0 or g.cell_h <= 0.0) return 1;
    const view_h: f64 = @as(f64, @floatFromInt(g.rows)) * g.cell_h;
    if (view_h <= 0.0) return 1;
    const pages: i32 = @intFromFloat(@ceil((view_h + @max(0.0, g.scroll_max)) / view_h));
    return @max(1, pages);
}

pub fn activePage(g: *const Grid, scroll: f64) i32 {
    const pages = pageCount(g);
    if (pages < 2 or g.scroll_max <= 0.0) return 0;
    const sc = clampScroll(scroll, g.scroll_max);
    const p: i32 = @intFromFloat(@round(sc / g.scroll_max * @as(f64, @floatFromInt(pages - 1))));
    return @min(pages - 1, @max(0, p));
}

test "overview-grid: 1080p stays at base size and scrolls past the rows" {
    const t = std.testing;
    var g: Grid = .{};
    // min(1920,1080)/900 = 1.2, so 1080p cells scale up from the base size.
    computeGrid(&g, 1920, 1080, 20, 1.0, 60, 0);
    try t.expectEqual(@as(f64, 64 * 1.2), g.icon_size);
    try t.expectEqual(@as(f64, 120 * 1.2), g.cell_w);
    try t.expect(g.cols >= 4);
    try t.expect(g.rows >= 1);
    try t.expect(g.scroll_max > 0);
    // Small outputs clamp back to the base size.
    var small: Grid = .{};
    computeGrid(&small, 1280, 720, 20, 1.0, 10, 0);
    try t.expectEqual(@as(f64, 64), small.icon_size);
    try t.expect(g.cols >= 4);
    try t.expect(g.rows >= 1);
    try t.expect(g.scroll_max > 0);
    try t.expectEqual(@as(i32, -1), pickCell(&g, -100, -100, 60, 0));
    const c = cellRect(&g, g.cols + 1, 0);
    try t.expectEqual(g.start_x + g.cell_w, c.x);
    try t.expectEqual(g.start_y + g.cell_h, c.y);
    try t.expect(pageCount(&g) >= 2);
    try t.expectEqual(@as(i32, 0), activePage(&g, 0));
}

test "overview-grid: modal is four columns and boxes its content" {
    const t = std.testing;
    var m: Grid = .{};
    computeModal(&m, 1920, 1080, 1.0, 10);
    try t.expectEqual(@as(i32, 4), m.cols);
    try t.expectEqual(@as(i32, 3), m.rows);
    try t.expectEqual(@as(f64, 0), m.scroll_max);
    const b = modalBox(&m, 1.0);
    try t.expectEqual(m.start_x - 16, b.x);
    try t.expectEqual(m.cell_w * 4 + 32, b.w);
}
