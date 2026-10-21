const std = @import("std");

pub const Card = struct {
    id: []const u8,
    span: i32,
    x: i32 = 0,
    w: i32 = 0,
};

pub fn packRow(alloc: std.mem.Allocator, ids: []const []const u8, spans: []const i32, columns: i32, col_w: i32, gap: i32) ![]Card {
    var out: std.ArrayList(Card) = .empty;
    errdefer out.deinit(alloc);
    var col: i32 = 0;
    var i: usize = 0;
    while (i < ids.len) : (i += 1) {
        var span: i32 = if (i < spans.len) spans[i] else 1;
        span = @max(1, @min(span, columns));
        if (col + span > columns) col = 0;
        const w = span * col_w + (span - 1) * gap;
        try out.append(alloc, .{ .id = ids[i], .span = span, .x = col * (col_w + gap), .w = w });
        col += span;
        if (col >= columns) col = 0;
    }
    return out.toOwnedSlice(alloc);
}

test "dashboard: span packing with wrap" {
    const t = std.testing;
    const ids = [_][]const u8{ "clock", "weather", "calendar", "media" };
    const spans = [_]i32{ 1, 1, 2, 2 };
    const cards = try packRow(t.allocator, &ids, &spans, 4, 200, 12);
    defer t.allocator.free(cards);
    try t.expectEqual(@as(i32, 0), cards[0].x);
    try t.expectEqual(@as(i32, 2 * 200 + 12), cards[2].w);
    try t.expectEqual(@as(i32, 0), cards[3].x);
}
