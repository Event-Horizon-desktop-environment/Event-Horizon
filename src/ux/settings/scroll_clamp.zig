const std = @import("std");
const common = @import("common.zig");

// Per-tab scroll clamps — Zig port of settings_clamp_*_scroll_px() in
// settings_app.cpp (lines ~1639-1654) + per-tab scroll_max helpers.
// Same design: each tab owns its scroll offset; content height minus
// viewport height bounds it; sidebar has its own clamp.

pub fn clampScroll(scroll_px: i32, content_h: i32, viewport_h: i32) i32 {
    const max: i32 = @max(0, content_h - viewport_h);
    return @min(@max(scroll_px, 0), max);
}

pub fn sidebarMaxScroll(total_h: i32, window_h: i32) i32 {
    const view_h: i32 = window_h - common.content_top - common.spacing_l;
    return @max(0, total_h - view_h);
}

pub fn sidebarTotalHeight(expanded_count: usize, sub_rows: usize) i32 {
    // 7 categories * pitch + expanded sub-rows * 36, from base y.
    const cats: i32 = 7 * common.sidebar_tab_pitch_y;
    const subs: i32 = @as(i32, @intCast(sub_rows)) * common.sidebar_sub_h;
    _ = expanded_count;
    return common.sidebar_tab_base_y + cats + subs;
}

test "settings-scroll-clamp: per-tab bounds" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 0), clampScroll(-10, 2000, 900));
    try t.expectEqual(@as(i32, 1100), clampScroll(9999, 2000, 900));
    try t.expectEqual(@as(i32, 500), clampScroll(500, 2000, 900));
    try t.expect(sidebarMaxScroll(2000, 980) > 0);
    try t.expect(sidebarTotalHeight(7, 10) > common.sidebar_tab_base_y);
}
