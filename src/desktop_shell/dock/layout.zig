const std = @import("std");

pub const Slot = struct {
    x: i32,
    y: i32,
    size: i32,
};

pub fn layoutSlots(alloc: std.mem.Allocator, count: usize, icon_size: i32, spacing: i32, x0: i32, y0: i32) ![]Slot {
    var out: std.ArrayList(Slot) = .empty;
    errdefer out.deinit(alloc);
    var x = x0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.append(alloc, .{ .x = x, .y = y0, .size = icon_size });
        x += icon_size + spacing;
    }
    return out.toOwnedSlice(alloc);
}

pub fn barWidth(count: usize, icon_size: i32, spacing: i32, padding: i32) i32 {
    if (count == 0) return padding * 2;
    return @as(i32, @intCast(count)) * icon_size + @as(i32, @intCast(count - 1)) * spacing + padding * 2;
}

pub fn slotAt(slots: []const Slot, px: i32, py: i32) ?usize {
    for (slots, 0..) |s, i| {
        if (px >= s.x and px < s.x + s.size and py >= s.y and py < s.y + s.size) return i;
    }
    return null;
}

test "dock-layout: slots, width, hit" {
    const t = std.testing;
    const slots = try layoutSlots(t.allocator, 3, 48, 8, 10, 10);
    defer t.allocator.free(slots);
    try t.expectEqual(@as(i32, 10), slots[0].x);
    try t.expectEqual(@as(i32, 10 + 48 + 8), slots[1].x);
    try t.expectEqual(@as(i32, 3 * 48 + 2 * 8 + 2 * 12), barWidth(3, 48, 8, 12));
    try t.expectEqual(@as(usize, 1), slotAt(slots, 70, 20).?);
    try t.expect(slotAt(slots, 5, 5) == null);
}
