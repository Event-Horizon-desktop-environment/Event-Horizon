//! Card-strip geometry for the workspace overview.
//!
//! One strip of workspace cards down the middle (vertical axis) or across it
//! (horizontal), with the quick-select strip taking the left or bottom edge
//! and the main strip's center shifted to make room. All units are output
//! pixels; pass the shell UI scale in and every constant follows it.

const std = @import("std");
const types = @import("types.zig");

const Layout = types.Layout;
const Axis = types.Axis;
const Rect = types.Rect;

fn clampF(v: f64, lo: f64, hi: f64) f64 {
    return @min(hi, @max(lo, v));
}

/// Fill `out` for an output of `w` by `h` showing `n_ws` workspaces.
pub fn compute(
    out: *Layout,
    w: f64,
    h: f64,
    n_ws: i32,
    ui: f64,
    axis: Axis,
    card_scale: f64,
    card_gap: f64,
    close_sz: f64,
    search_w: f64,
) void {
    out.* = .{};
    out.w = w;
    out.h = h;
    out.ui = ui;
    out.axis = axis;
    out.scale = clampF(card_scale, 0.2, 0.8);
    out.gap = @max(8.0, card_gap * ui);

    out.search_y = 20.0 * ui;
    out.search_w = clampF(search_w, 100.0, 1200.0) * ui;
    out.search_h = 40.0 * ui;
    out.close_sz = clampF(close_sz, 12.0, 90.0) * ui;

    if (axis == .vertical) {
        out.card_h = h * out.scale;
        out.card_w = @min(w * 0.92, out.card_h * 1.6);
        out.pitch = out.card_h + out.gap;
    } else {
        out.card_w = w * out.scale;
        out.card_h = @min(h * 0.92, out.card_w * 0.625);
        out.pitch = out.card_w + out.gap;
    }

    computeStrip(&out.strip, axis, w, h, out.card_w, out.card_h, ui, n_ws);

    if (axis == .vertical) {
        out.center_x = (w + out.strip.w) * 0.5;
        out.center_y = h * 0.5;
    } else {
        const reserve = (types.apps_btn_h + types.apps_btn_gap + types.apps_btn_bottom) * ui;
        out.center_x = w * 0.5;
        out.center_y = (h - out.strip.h - reserve) * 0.5;
    }

    const btn_h = types.apps_btn_h * ui;
    out.apps_btn = .{
        .w = btn_h,
        .h = btn_h,
        .x = out.center_x - btn_h * 0.5,
        .y = if (axis == .horizontal) h - types.apps_btn_bottom * ui - btn_h else h - btn_h - 12.0 * ui,
    };
}

fn computeStrip(s: *types.Strip, axis: Axis, w: f64, h: f64, card_w: f64, card_h: f64, ui: f64, n_ws: i32) void {
    s.* = .{};
    s.horizontal = axis == .horizontal;
    s.pad_x = 16.0 * ui;
    s.pad_y = 12.0 * ui;
    s.gap = 8.0 * ui;
    s.radius = 8.0 * ui;
    s.thumb_w = @max(40.0, card_w * 0.25);
    s.thumb_h = @max(30.0, card_h * 0.25);

    if (s.horizontal) {
        const reserve = (types.apps_btn_h + types.apps_btn_gap + types.apps_btn_bottom) * ui;
        const content_h = s.thumb_h + s.pad_y * 2.0;
        s.x = 0;
        s.y = h - content_h - reserve;
        s.w = w;
        s.h = content_h;
    } else {
        s.x = 0;
        s.y = 0;
        s.w = s.thumb_w + s.pad_x * 2.0;
        s.h = h;
    }

    const n: f64 = @floatFromInt(@max(1, n_ws));
    s.add.w = s.thumb_w;
    s.add.h = s.thumb_h;
    if (s.horizontal) {
        const content = (n + 1.0) * s.thumb_w + n * s.gap;
        s.scroll_max = @max(0.0, content + s.pad_x * 2.0 - s.w);
        const total = (n + 1.0) * s.thumb_w + n * s.gap;
        s.add.x = s.x + (s.w - total) * 0.5 + n * (s.thumb_w + s.gap);
        s.add.y = s.y + s.pad_y;
    } else {
        const content = (n + 1.0) * s.thumb_h + n * s.gap;
        s.scroll_max = @max(0.0, content + s.pad_y * 2.0 - s.h);
        const total = (n + 1.0) * s.thumb_h + n * s.gap;
        s.add.x = s.x + s.pad_x;
        s.add.y = s.y + (s.h - total) * 0.5 + n * (s.thumb_h + s.gap);
    }
}

/// Card `index` at `scroll`: the strip starts centered and slides against it.
pub fn cardRect(l: *const Layout, index: i32, scroll: f64) Rect {
    const i: f64 = @floatFromInt(index);
    if (l.axis == .vertical) {
        return .{
            .w = l.card_w,
            .h = l.card_h,
            .x = l.center_x - l.card_w * 0.5,
            .y = l.center_y - l.card_h * 0.5 + i * l.pitch - scroll,
        };
    }
    return .{
        .w = l.card_w,
        .h = l.card_h,
        .x = l.center_x - l.card_w * 0.5 + i * l.pitch - scroll,
        .y = l.center_y - l.card_h * 0.5,
    };
}

/// Nearest card to `scroll`, clamped into range.
pub fn selectedIndex(l: *const Layout, scroll: f64, n: i32) f64 {
    if (l.pitch <= 0.0) return 0.0;
    var sel = @round(scroll / l.pitch);
    if (n > 0) sel = clampF(sel, 0.0, @floatFromInt(n - 1));
    return sel;
}

test "overview-layout: vertical strip centers with room for the rail" {
    const t = std.testing;
    var l: Layout = .{};
    compute(&l, 1920, 1080, 3, 1.0, .vertical, 0.5, 24, 34, 420);
    try t.expectEqual(@as(f64, 540), l.card_h);
    try t.expectEqual(@as(f64, 864), l.card_w);
    try t.expectEqual(@as(f64, 564), l.pitch);
    // Rail is 25% of the card wide (216) plus 32 padding.
    try t.expectEqual(@as(f64, 248), l.strip.w);
    try t.expectEqual(@as(f64, (1920 + 248) * 0.5), l.center_x);
    try t.expectEqual(@as(f64, 540), l.center_y);
    const c0 = cardRect(&l, 0, 0);
    try t.expectEqual(@as(f64, 1084 - 432), c0.x);
    try t.expectEqual(@as(f64, 540 - 270), c0.y);
    const c1 = cardRect(&l, 1, 0);
    try t.expectEqual(c0.y + 564, c1.y);
    try t.expectEqual(@as(f64, 1), selectedIndex(&l, 600, 3));
    try t.expectEqual(@as(f64, 2), selectedIndex(&l, 99999, 3));
}

test "overview-layout: horizontal strip lifts above the pill" {
    const t = std.testing;
    var l: Layout = .{};
    compute(&l, 1920, 1080, 2, 1.0, .horizontal, 0.5, 24, 34, 420);
    try t.expectEqual(@as(f64, 960), l.card_w);
    try t.expectEqual(@as(f64, 600), l.card_h);
    // Strip content (150 + 24) lifted by the 60px pill reserve.
    try t.expectEqual(@as(f64, 1080 - 174 - 60), l.strip.y);
    try t.expectEqual(@as(f64, 960), l.center_x);
    try t.expectEqual(@as(f64, (1080 - 174 - 60) * 0.5), l.center_y);
    try t.expectEqual(@as(f64, 960 - 19), l.apps_btn.x);
    try t.expectEqual(@as(f64, 1080 - 12 - 38), l.apps_btn.y);
    const c1 = cardRect(&l, 1, 100);
    const c0 = cardRect(&l, 0, 100);
    try t.expectEqual(c0.x + 984, c1.x);
    try t.expectEqual(c0.y, c1.y);
}
