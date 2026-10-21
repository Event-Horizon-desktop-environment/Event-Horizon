const std = @import("std");

pub const Flow = enum { vertical, horizontal };

pub const Item = struct {
    w: i32,
    h: i32,
    gap_after: i32 = 0,
};

pub const Placed = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub fn layoutFlow(items: []const Item, x0: i32, y0: i32, flow: Flow, gap: i32, alloc: std.mem.Allocator) ![]Placed {
    var out: std.ArrayList(Placed) = .empty;
    errdefer out.deinit(alloc);
    var cx = x0;
    var cy = y0;
    for (items) |it| {
        try out.append(alloc, .{ .x = cx, .y = cy, .w = it.w, .h = it.h });
        if (flow == .vertical) {
            cy += it.h + it.gap_after + gap;
        } else {
            cx += it.w + it.gap_after + gap;
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn extent(items: []const Placed) struct { w: i32, h: i32 } {
    var mw: i32 = 0;
    var mh: i32 = 0;
    for (items) |p| {
        mw = @max(mw, p.x + p.w);
        mh = @max(mh, p.y + p.h);
    }
    return .{ .w = mw, .h = mh };
}

test "popup-layout: vertical flow with gaps" {
    const t = std.testing;
    const items = [_]Item{ .{ .w = 100, .h = 20 }, .{ .w = 100, .h = 30, .gap_after = 4 } };
    const placed = try layoutFlow(&items, 10, 10, .vertical, 6, t.allocator);
    defer t.allocator.free(placed);
    try t.expectEqual(@as(usize, 2), placed.len);
    try t.expectEqual(@as(i32, 10), placed[0].y);
    try t.expectEqual(@as(i32, 10 + 20 + 6), placed[1].y);
    const e = extent(placed);
    try t.expectEqual(@as(i32, 110), e.w);
}
