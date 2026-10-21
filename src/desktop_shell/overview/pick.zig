//! Hit testing for the overview's workspace side.
//!
//! Everything here is pure geometry over the computed layout: which card,
//! which window tile, which close button, which quick-select thumb. Window
//! tiles prefer real backend geometry and fall back to an even grid.

const std = @import("std");
const types = @import("types.zig");
const layout = @import("layout.zig");

const Layout = types.Layout;
const Rect = types.Rect;
const WinBox = types.WinBox;

fn clampF(v: f64, lo: f64, hi: f64) f64 {
    return @min(hi, @max(lo, v));
}

/// Tile for one window inside `card`. Normalized geometry wins when present,
/// absolute pixels are scaled down from the output, and zeros in both mean
/// an even cell in a grid sized for `n_in_ws`.
pub fn tileRect(l: *const Layout, card: Rect, win: WinBox, win_index: i32, n_in_ws: i32) Rect {
    const pad = 12.0 * l.ui;
    const inner_w: f64 = @max(1.0, card.w - pad * 2.0);
    const inner_h: f64 = @max(1.0, card.h - pad * 2.0);
    if (win.nw > 0.0 and win.nh > 0.0 and l.w > 0.0 and l.h > 0.0) {
        const w = clampF(win.nw * inner_w, 18.0 * l.ui, inner_w);
        const h = clampF(win.nh * inner_h, 14.0 * l.ui, inner_h);
        return .{
            .w = w,
            .h = h,
            .x = clampF(card.x + pad + win.nx * inner_w, card.x + pad, card.x + card.w - pad - w),
            .y = clampF(card.y + pad + win.ny * inner_h, card.y + pad, card.y + card.h - pad - h),
        };
    }
    if (win.w > 0.0 and win.h > 0.0 and l.w > 0.0 and l.h > 0.0) {
        const w = clampF(win.w / l.w * inner_w, 18.0 * l.ui, inner_w);
        const h = clampF(win.h / l.h * inner_h, 14.0 * l.ui, inner_h);
        return .{
            .w = w,
            .h = h,
            .x = clampF(card.x + pad + win.x / l.w * inner_w, card.x + pad, card.x + card.w - pad - w),
            .y = clampF(card.y + pad + win.y / l.h * inner_h, card.y + pad, card.y + card.h - pad - h),
        };
    }
    const n: f64 = @floatFromInt(@max(1, n_in_ws));
    const cols: i32 = @min(3, @max(1, @as(i32, @intFromFloat(@ceil(@sqrt(n))))));
    const rows: i32 = @divTrunc(@max(1, n_in_ws) + cols - 1, cols);
    const gap = 10.0 * l.ui;
    const fc: f64 = @floatFromInt(cols);
    const fr: f64 = @floatFromInt(rows);
    const cell_w = (inner_w - (fc - 1.0) * gap) / fc;
    const cell_h = (inner_h - (fr - 1.0) * gap) / fr;
    const w = clampF(cell_w * 0.9, 40.0 * l.ui, cell_w);
    const h = clampF(cell_h * 0.9, 24.0 * l.ui, cell_h);
    const col: i32 = @rem(win_index, cols);
    const row: i32 = @divTrunc(win_index, cols);
    const cx = card.x + pad + @as(f64, @floatFromInt(col)) * (cell_w + gap);
    const cy = card.y + pad + @as(f64, @floatFromInt(row)) * (cell_h + gap);
    return .{ .w = w, .h = h, .x = cx + (cell_w - w) * 0.5, .y = cy + (cell_h - h) * 0.5 };
}

/// Topmost card under the pointer, or -1.
pub fn pickWorkspace(l: *const Layout, n: i32, mx: f64, my: f64, scroll: f64) i32 {
    var i = n - 1;
    while (i >= 0) : (i -= 1) {
        if (layout.cardRect(l, i, scroll).contains(mx, my)) return i;
    }
    return -1;
}

/// Close button for a tile: a square straddling its top-right corner.
pub fn closeRect(l: *const Layout, tile: Rect) Rect {
    const bs = l.close_sz * 0.72;
    return .{ .x = tile.x + tile.w - bs * 0.5, .y = tile.y - bs * 0.5, .w = bs, .h = bs };
}

/// First thumb/add origin along the scroll axis: centered while everything
/// fits, pad-aligned once the column outgrows the strip and scrolls.
fn stripOrigin(s: *const types.Strip, n: i32) f64 {
    const count: f64 = @floatFromInt(@max(1, n));
    if (s.horizontal) {
        const content = (count + 1.0) * s.thumb_w + count * s.gap;
        if (s.scroll_max <= 0.0) return s.x + (s.w - content) * 0.5;
        return s.x + s.pad_x;
    }
    const content = (count + 1.0) * s.thumb_h + count * s.gap;
    if (s.scroll_max <= 0.0) return s.y + (s.h - content) * 0.5;
    return s.y + s.pad_y;
}

/// Thumb `idx` in the quick-select strip, shifted by the rail scroll.
pub fn stripThumb(s: *const types.Strip, n: i32, idx: i32, scroll: f64) Rect {
    const i: f64 = @floatFromInt(idx);
    if (s.horizontal) {
        return .{
            .x = stripOrigin(s, n) + i * (s.thumb_w + s.gap) - scroll,
            .y = s.y + s.pad_y,
            .w = s.thumb_w,
            .h = s.thumb_h,
        };
    }
    return .{
        .x = s.x + s.pad_x,
        .y = stripOrigin(s, n) + i * (s.thumb_h + s.gap) - scroll,
        .w = s.thumb_w,
        .h = s.thumb_h,
    };
}

/// The add-workspace slot, shifted by the rail scroll like the thumbs.
pub fn stripAddRect(s: *const types.Strip, n: i32, scroll: f64) Rect {
    const count: f64 = @floatFromInt(@max(1, n));
    if (s.horizontal) {
        return .{
            .x = stripOrigin(s, n) + count * (s.thumb_w + s.gap) - scroll,
            .y = s.y + s.pad_y,
            .w = s.thumb_w,
            .h = s.thumb_h,
        };
    }
    return .{
        .x = s.x + s.pad_x,
        .y = stripOrigin(s, n) + count * (s.thumb_h + s.gap) - scroll,
        .w = s.thumb_w,
        .h = s.thumb_h,
    };
}

/// Whether the pointer is over the strip at all (scrolling routes here).
pub fn stripContains(s: *const types.Strip, mx: f64, my: f64) bool {
    return mx >= s.x and mx <= s.x + s.w and my >= s.y and my <= s.y + s.h;
}

/// Thumb under the pointer, or -1. The add-workspace slot is not a thumb;
/// test it with `pickStripAdd`.
pub fn pickStrip(s: *const types.Strip, n: i32, mx: f64, my: f64, scroll: f64) i32 {
    if (n <= 0) return -1;
    if (!stripContains(s, mx, my)) return -1;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        if (stripThumb(s, n, i, scroll).contains(mx, my)) return i;
    }
    return -1;
}

pub fn pickStripAdd(s: *const types.Strip, n: i32, mx: f64, my: f64, scroll: f64) bool {
    return stripAddRect(s, n, scroll).contains(mx, my);
}

test "overview-pick: cards topmost-first, tiles fall back to grid" {
    const t = std.testing;
    var l: Layout = .{};
    layout.compute(&l, 1920, 1080, 3, 1.0, .vertical, 0.5, 24, 34, 420);
    const c0 = layout.cardRect(&l, 0, 0);
    try t.expectEqual(@as(i32, 0), pickWorkspace(&l, 3, c0.x + 5, c0.y + 5, 0));
    try t.expectEqual(@as(i32, -1), pickWorkspace(&l, 3, 5, 5, 0));
    const tile = tileRect(&l, c0, .{}, 1, 4);
    try t.expect(tile.w >= 40 and tile.h >= 24);
    try t.expect(tile.x >= c0.x + 12 and tile.x + tile.w <= c0.x + c0.w - 12 + 1e-6);
    const norm = tileRect(&l, c0, .{ .nx = 0, .ny = 0, .nw = 0.5, .nh = 0.5 }, 0, 1);
    try t.expectEqual(@as(f64, c0.x + 12), norm.x);
}

test "overview-pick: strip thumbs center with the add slot counted" {
    const t = std.testing;
    var l: Layout = .{};
    layout.compute(&l, 1920, 1080, 3, 1.0, .vertical, 0.5, 24, 34, 420);
    const s = &l.strip;
    const t0 = stripThumb(s, 3, 0, 0);
    try t.expectEqual(s.x + s.pad_x, t0.x);
    try t.expect(pickStrip(s, 3, t0.x + 2, t0.y + 2, 0) == 0);
    try t.expect(pickStripAdd(s, 3, s.add.x + 1, s.add.y + 1, 0));
    try t.expectEqual(@as(i32, -1), pickStrip(s, 0, t0.x, t0.y, 0));
    // Scrolled: the first thumb moves up by exactly the scroll offset,
    // and picks follow it.
    const t1 = stripThumb(s, 3, 0, 50);
    try t.expectEqual(t0.y - 50, t1.y);
    try t.expect(pickStrip(s, 3, t0.x + 2, t0.y + 2 - 50, 50) == 0);
    const big = s.thumb_h + 10;
    try t.expect(!pickStripAdd(s, 3, s.add.x + 1, s.add.y + 1, big));
}
