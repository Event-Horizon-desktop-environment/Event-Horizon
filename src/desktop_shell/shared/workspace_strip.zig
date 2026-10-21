const std = @import("std");

pub const Ws = struct {
    id: []const u8,
    active: bool = false,
    urgent: bool = false,
    empty: bool = true,
};

pub fn layoutSlots(count: usize, total_w: i32, min_w: i32, alloc: std.mem.Allocator) ![]i32 {
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(alloc);
    if (count == 0) return out.toOwnedSlice(alloc);
    const w = @max(min_w, @divTrunc(total_w, @as(i32, @intCast(count))));
    var i: usize = 0;
    while (i < count) : (i += 1) try out.append(alloc, w);
    return out.toOwnedSlice(alloc);
}

pub fn activeIndex(ws: []const Ws) ?usize {
    for (ws, 0..) |w, i| {
        if (w.active) return i;
    }
    return null;
}

test "workspace-strip: slots + active" {
    const t = std.testing;
    const widths = try layoutSlots(4, 400, 48, t.allocator);
    defer t.allocator.free(widths);
    try t.expectEqual(@as(i32, 100), widths[0]);
    const narrow = try layoutSlots(20, 400, 48, t.allocator);
    defer t.allocator.free(narrow);
    try t.expectEqual(@as(i32, 48), narrow[0]);
    const ws = [_]Ws{ .{ .id = "1" }, .{ .id = "2", .active = true } };
    try t.expectEqual(@as(usize, 1), activeIndex(&ws).?);
    try t.expect(activeIndex(&[_]Ws{}) == null);
}
