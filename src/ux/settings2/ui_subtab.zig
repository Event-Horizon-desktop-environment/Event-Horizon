const std = @import("std");
const common = @import("common.zig");
const subtabs = @import("subtabs.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

// Child tab bar painter + hit geometry —
// Fixed strip above the
// scrollable content, cards start below it (kContentTop + 34 + 12 = 62).

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Bar = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    def: subtabs.Bar,
};

pub fn barRect(tab: i32, content_x: i32, content_w: i32) ?Bar {
    const def = subtabs.barFor(tab) orelse return null;
    return .{
        .x = content_x + 8,
        .y = common.content_top,
        .w = content_w - 16,
        .h = common.child_bar_h,
        .def = def,
    };
}

/// Window-space rect of child tab `i`.
pub fn tabRect(bar: Bar, i: usize) Rect {
    const n: i32 = @intCast(bar.def.labels.len);
    const tabs_w = n * bar.def.tab_w + (n - 1) * bar.def.gap;
    const start = if (bar.def.centered)
        bar.x + @divTrunc(bar.w - tabs_w, 2)
    else
        bar.x + 4;
    const tx = start + @as(i32, @intCast(i)) * (bar.def.tab_w + bar.def.gap);
    return .{ .x = tx, .y = bar.y + 3, .w = bar.def.tab_w, .h = common.child_tab_h };
}

/// Child tab index at window-space point, when inside the strip.
pub fn hit(bar: ?Bar, px: f64, py: f64) ?usize {
    const b = bar orelse return null;
    if (py < b.y or py >= b.y + b.h) return null;
    if (px < b.x or px >= b.x + b.w) return null;
    for (b.def.labels, 0..) |_, i| {
        const r = tabRect(b, i);
        if (px >= r.x and px < r.x + r.w) return i;
    }
    return null;
}

/// Paint the fixed strip: bg (text 0.04, r8), tabs h34 (selected text 0.10
/// r6), labels 13px weight 600/400 at alpha 0.90/0.55.
pub fn paint(
    c: ?*cairo.cairo_t,
    tab: i32,
    content_x: i32,
    content_w: i32,
    active_sub: usize,
    pointer_x: f64,
    pointer_y: f64,
) void {
    const cr = c orelse return;
    const bar = barRect(tab, content_x, content_w) orelse return;
    ui_paint.glassBox(
        cr,
        @floatFromInt(bar.x),
        @floatFromInt(bar.y),
        @floatFromInt(bar.w),
        @floatFromInt(bar.h),
        8,
        1,
        1,
        1,
        0.04,
    );
    // Clip the strip to the bar so a narrow window can't paint tab labels
    // past its right edge (the fixed-width tabs may overflow the bar).
    cairo.cairo_save(cr);
    cairo.cairo_rectangle(cr, @floatFromInt(bar.x), @floatFromInt(bar.y), @floatFromInt(bar.w), @floatFromInt(bar.h));
    cairo.cairo_clip(cr);
    for (bar.def.labels, 0..) |label, i| {
        const r = tabRect(bar, i);
        const sel = i == active_sub;
        const hov = common.pointInRect(pointer_x, pointer_y, .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
        });
        if (sel or hov) {
            ui_paint.glassBox(
                cr,
                @floatFromInt(r.x),
                @floatFromInt(r.y),
                @floatFromInt(r.w),
                @floatFromInt(r.h),
                6,
                1,
                1,
                1,
                if (sel) 0.10 else 0.06,
            );
        }
        const tw = ui_paint.textWidthPx(cr, label, 13, if (sel) 600 else 400);
        const cx = @as(f64, @floatFromInt(r.x)) +
            (@as(f64, @floatFromInt(r.w)) - @as(f64, @floatFromInt(tw))) * 0.5;
        ui_paint.showText(
            cr,
            cx,
            @floatFromInt(r.y + 22),
            label,
            13,
            if (sel) 600 else 400,
            1,
            1,
            1,
            if (sel) 0.90 else 0.55,
        );
    }
    cairo.cairo_restore(cr);
}

test "settings-ui-subtab: bar and tab rects" {
    const t = std.testing;
    const bar = barRect(0, 292, 592).?;
    try t.expectEqual(@as(i32, 300), bar.x);
    try t.expectEqual(@as(i32, 40), bar.h);
    const r0 = tabRect(bar, 0);
    try t.expectEqual(@as(i32, 304), r0.x);
    try t.expectEqual(@as(i32, 51), r0.y);
    try t.expectEqual(@as(i32, 130), r0.w);
    try t.expect(hit(bar, 400, 55) == 0);
    try t.expect(hit(bar, 400, 96) == null);
    try t.expect(barRect(7, 292, 592) == null);
    // Power bar is centered with 150px tabs.
    const pb = barRect(32, 292, 592).?;
    const pr0 = tabRect(pb, 0);
    try t.expect(pr0.x > pb.x + 4);
}
