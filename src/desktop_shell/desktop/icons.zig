const std = @import("std");

pub const Icon = struct {
    x: i32,
    y: i32,
    label: []const u8 = "",
};

pub fn layoutGrid(alloc: std.mem.Allocator, count: usize, cell_w: i32, cell_h: i32, cols: i32, x0: i32, y0: i32, gap: i32) ![]Icon {
    var out: std.ArrayList(Icon) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const col: i32 = @intCast(i % @as(usize, @intCast(@max(1, cols))));
        const row: i32 = @intCast(i / @as(usize, @intCast(@max(1, cols))));
        try out.append(alloc, .{
            .x = x0 + col * (cell_w + gap),
            .y = y0 + row * (cell_h + gap),
        });
    }
    return out.toOwnedSlice(alloc);
}

pub const Marquee = struct {
    x0: i32 = 0,
    y0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,
    active: bool = false,

    pub fn normalized(self: Marquee) struct { x: i32, y: i32, w: i32, h: i32 } {
        return .{
            .x = @min(self.x0, self.x1),
            .y = @min(self.y0, self.y1),
            .w = @intCast(@abs(self.x1 - self.x0)),
            .h = @intCast(@abs(self.y1 - self.y0)),
        };
    }

    pub fn hitsIcon(self: Marquee, ix: i32, iy: i32, iw: i32, ih: i32) bool {
        if (!self.active) return false;
        const r = self.normalized();
        return ix < r.x + r.w and ix + iw > r.x and iy < r.y + r.h and iy + ih > r.y;
    }
};

test "desktop: grid + marquee" {
    const t = std.testing;
    const icons = try layoutGrid(t.allocator, 5, 96, 96, 3, 16, 16, 8);
    defer t.allocator.free(icons);
    try t.expectEqual(@as(i32, 16), icons[0].x);
    try t.expectEqual(@as(i32, 16 + 96 + 8), icons[1].x);
    try t.expectEqual(@as(i32, 16 + 96 + 8), icons[3].y);
    const m = Marquee{ .x0 = 100, .y0 = 100, .x1 = 10, .y1 = 10, .active = true };
    const n = m.normalized();
    try t.expect(n.x == 10 and n.w == 90);
    try t.expect(m.hitsIcon(50, 50, 96, 96));
    try t.expect(!m.hitsIcon(500, 500, 96, 96));
}
