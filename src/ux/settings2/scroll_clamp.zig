const std = @import("std");
const common = @import("common.zig");

// Per-tab scroll clamps plus per-tab scroll_max helpers.
// Same design: each tab owns its scroll offset; content height minus
// viewport height bounds it; sidebar has its own clamp.

pub fn clampScroll(scroll_px: i32, content_h: i32, viewport_h: i32) i32 {
    const max: i32 = @max(0, content_h - viewport_h);
    return @min(@max(scroll_px, 0), max);
}

pub fn sidebarMaxScroll(total_h: i32, window_h: i32) i32 {
    // Flush list column: rows may run to the window's bottom edge.
    return @max(0, total_h - window_h);
}

pub fn sidebarTotalHeight(page_rows: usize, result_rows: usize) i32 {
    // Design B: only the list column scrolls — rows from base y on a 38px
    // pitch (search results use the 52px pitch; either fits the clamp).
    const rows: i32 = @as(i32, @intCast(@max(page_rows, result_rows))) * common.list_row_pitch_y;
    return common.list_row_base_y + rows + 8;
}

test "settings2-scroll-clamp: per-tab bounds" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 0), clampScroll(-10, 2000, 900));
    try t.expectEqual(@as(i32, 1100), clampScroll(9999, 2000, 900));
    try t.expectEqual(@as(i32, 500), clampScroll(500, 2000, 900));
    try t.expect(sidebarMaxScroll(2000, 980) > 0);
    try t.expect(sidebarTotalHeight(10, 0) > common.list_row_base_y);
}
