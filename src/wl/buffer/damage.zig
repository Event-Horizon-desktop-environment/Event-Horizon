const std = @import("std");

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn empty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

pub const max_spans: usize = 16;

pub const Region = struct {
    alloc: std.mem.Allocator,
    full: bool = false,
    spans: std.ArrayList(Rect),

    pub fn init(alloc: std.mem.Allocator) Region {
        return .{ .alloc = alloc, .spans = .empty };
    }

    pub fn deinit(self: *Region) void {
        self.spans.deinit(self.alloc);
    }

    pub fn markFull(self: *Region) void {
        self.full = true;
        self.spans.clearRetainingCapacity();
    }

    pub fn clear(self: *Region) void {
        self.full = false;
        self.spans.clearRetainingCapacity();
    }

    pub fn isEmpty(self: *const Region) bool {
        return !self.full and self.spans.items.len == 0;
    }

    pub fn isFull(self: *const Region) bool {
        return self.full;
    }

    pub fn spanCount(self: *const Region) usize {
        return self.spans.items.len;
    }

    pub fn addRect(self: *Region, r: Rect) !void {
        if (self.full or r.empty()) return;
        try self.spans.append(self.alloc, r);
        self.coalesce();
    }

    pub fn addXywh(self: *Region, x: i32, y: i32, w: i32, h: i32) !void {
        try self.addRect(.{ .x = x, .y = y, .w = w, .h = h });
    }

    pub fn unionWith(self: *Region, other: *const Region) !void {
        if (self.full) return;
        if (other.full) {
            self.markFull();
            return;
        }
        try self.spans.appendSlice(self.alloc, other.spans.items);
        self.coalesce();
    }

    pub fn clipTo(self: *Region, max_w: i32, max_h: i32) void {
        if (self.full or self.spans.items.len == 0) return;
        var out: usize = 0;
        for (self.spans.items) |*s| {
            var r = s.*;
            const x0 = @max(0, @min(r.x, max_w));
            const y0 = @max(0, @min(r.y, max_h));
            const x1 = @max(0, @min(r.x + r.w, max_w));
            const y1 = @max(0, @min(r.y + r.h, max_h));
            r.x = x0;
            r.y = y0;
            r.w = x1 - x0;
            r.h = y1 - y0;
            if (!r.empty()) {
                self.spans.items[out] = r;
                out += 1;
            }
        }
        self.spans.items.len = out;
    }

    pub fn expand(self: *Region, margin: i32, max_w: i32, max_h: i32) void {
        if (self.full or margin <= 0) {
            self.clipTo(max_w, max_h);
            return;
        }
        for (self.spans.items) |*r| {
            const nx: i32 = if (r.x < margin) 0 else r.x - margin;
            const ny: i32 = if (r.y < margin) 0 else r.y - margin;
            const nw: i64 = @as(i64, r.w) + @as(i64, r.x - nx) + margin;
            const nh: i64 = @as(i64, r.h) + @as(i64, r.y - ny) + margin;
            r.x = nx;
            r.y = ny;
            r.w = @intCast(@min(nw, std.math.maxInt(i32)));
            r.h = @intCast(@min(nh, std.math.maxInt(i32)));
        }
        self.clipTo(max_w, max_h);
        self.coalesce();
    }

    fn touches(a: Rect, b: Rect) bool {
        return a.x <= b.x + b.w and b.x <= a.x + a.w and a.y <= b.y + b.h and b.y <= a.y + a.h;
    }

    fn coalesce(self: *Region) void {
        var merged_any = true;
        while (merged_any and !self.full) {
            merged_any = false;
            var i: usize = 0;
            while (i < self.spans.items.len) : (i += 1) {
                var j = i + 1;
                while (j < self.spans.items.len) {
                    const a = self.spans.items[i];
                    const b = self.spans.items[j];
                    if (touches(a, b)) {
                        const x0 = @min(a.x, b.x);
                        const y0 = @min(a.y, b.y);
                        const x1 = @max(a.x + a.w, b.x + b.w);
                        const y1 = @max(a.y + a.h, b.y + b.h);
                        self.spans.items[i] = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
                        self.spans.items[j] = self.spans.items[self.spans.items.len - 1];
                        self.spans.items.len -= 1;
                        merged_any = true;
                        continue;
                    }
                    j += 1;
                }
                if (self.spans.items.len > max_spans) {
                    self.markFull();
                    return;
                }
            }
        }
    }
};

test "damage: default empty" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    try t.expect(r.isEmpty());
    try t.expect(!r.isFull());
    try t.expectEqual(@as(usize, 0), r.spanCount());
}

test "damage: mark full and clear" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    r.markFull();
    try t.expect(r.isFull());
    try t.expect(!r.isEmpty());
    try t.expectEqual(@as(usize, 0), r.spanCount());
    try r.addXywh(0, 0, 10, 10);
    try t.expect(r.isFull());
    try t.expectEqual(@as(usize, 0), r.spanCount());
    r.clear();
    try t.expect(r.isEmpty());
    try t.expect(!r.isFull());
}

test "damage: single rect" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    try r.addRect(.{ .x = 5, .y = 7, .w = 3, .h = 4 });
    try t.expect(!r.isEmpty() and !r.isFull());
    try t.expectEqual(@as(usize, 1), r.spanCount());
    const s = r.spans.items[0];
    try t.expect(s.x == 5 and s.y == 7 and s.w == 3 and s.h == 4);
}

test "damage: degenerate ignored" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    try r.addXywh(1, 1, 0, 5);
    try r.addXywh(1, 1, 5, 0);
    try r.addXywh(1, 1, -3, 5);
    try t.expect(r.isEmpty());
}

test "damage: overlap coalesces" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    try r.addXywh(0, 0, 10, 10);
    try r.addXywh(5, 5, 10, 10);
    try t.expectEqual(@as(usize, 1), r.spanCount());
    const s = r.spans.items[0];
    try t.expect(s.x == 0 and s.y == 0 and s.w == 15 and s.h == 15);
}

test "damage: touching edges coalesce" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    try r.addXywh(0, 0, 10, 10);
    try r.addXywh(10, 0, 10, 10);
    try t.expectEqual(@as(usize, 1), r.spanCount());
    try t.expect(r.spans.items[0].w == 20 and r.spans.items[0].h == 10);
}

test "damage: disjoint stay separate" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    try r.addXywh(0, 0, 4, 4);
    try r.addXywh(100, 100, 4, 4);
    try t.expectEqual(@as(usize, 2), r.spanCount());
    var e = Region.init(t.allocator);
    defer e.deinit();
    try r.unionWith(&e);
    try t.expectEqual(@as(usize, 2), r.spanCount());
}

test "damage: union with full" {
    const t = std.testing;
    var a = Region.init(t.allocator);
    defer a.deinit();
    try a.addXywh(0, 0, 2, 2);
    var b = Region.init(t.allocator);
    defer b.deinit();
    b.markFull();
    try a.unionWith(&b);
    try t.expect(a.isFull());
    try t.expectEqual(@as(usize, 0), a.spanCount());
}

test "damage: overflow falls back to full" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        try r.addXywh(i * 1000, @mod(i, 2) * 1000, 1, 1);
        if (r.isFull()) break;
    }
    try t.expect(r.isFull());
    try r.addXywh(1, 1, 1, 1);
    try t.expect(r.isFull());
}

test "damage: clip to" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    try r.addXywh(-5, -5, 20, 20);
    r.clipTo(10, 10);
    try t.expectEqual(@as(usize, 1), r.spanCount());
    const s = r.spans.items[0];
    try t.expect(s.x == 0 and s.y == 0 and s.w == 10 and s.h == 10);

    var out = Region.init(t.allocator);
    defer out.deinit();
    try out.addXywh(50, 50, 5, 5);
    out.clipTo(10, 10);
    try t.expect(out.isEmpty());

    var f = Region.init(t.allocator);
    defer f.deinit();
    f.markFull();
    f.clipTo(4, 4);
    try t.expect(f.isFull());

    var e = Region.init(t.allocator);
    defer e.deinit();
    e.clipTo(4, 4);
    try t.expect(e.isEmpty());
}

test "damage: expand" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    try r.addXywh(10, 10, 4, 4);
    r.expand(3, 100, 100);
    try t.expect(r.spanCount() >= 1);
    var min_x: i32 = 1 << 30;
    var min_y: i32 = 1 << 30;
    var max_x: i32 = 0;
    var max_y: i32 = 0;
    for (r.spans.items) |s| {
        min_x = @min(min_x, s.x);
        min_y = @min(min_y, s.y);
        max_x = @max(max_x, s.x + s.w);
        max_y = @max(max_y, s.y + s.h);
    }
    try t.expect(min_x == 7 and min_y == 7 and max_x == 17 and max_y == 17);

    var edge = Region.init(t.allocator);
    defer edge.deinit();
    try edge.addXywh(0, 0, 2, 2);
    edge.expand(5, 4, 4);
    try t.expectEqual(@as(usize, 1), edge.spanCount());
    try t.expect(edge.spans.items[0].x == 0 and edge.spans.items[0].y == 0 and edge.spans.items[0].w == 4 and edge.spans.items[0].h == 4);

    var f = Region.init(t.allocator);
    defer f.deinit();
    f.markFull();
    f.expand(3, 10, 10);
    try t.expect(f.isFull());
}

test "damage: marquee pattern stays small" {
    const t = std.testing;
    var r = Region.init(t.allocator);
    defer r.deinit();
    var i: i32 = 0;
    while (i < 200) : (i += 1) {
        try r.addXywh(@mod(i, 40), 30, 60, 12);
        try t.expect(!r.isFull());
        try t.expect(r.spanCount() <= max_spans);
    }
    try t.expectEqual(@as(usize, 1), r.spanCount());
}

test "damage: rect contains" {
    const t = std.testing;
    const rect = Rect{ .x = 10, .y = 10, .w = 5, .h = 5 };
    try t.expect(rect.contains(10, 10));
    try t.expect(rect.contains(14, 14));
    try t.expect(!rect.contains(15, 15));
    try t.expect(!rect.contains(9, 10));
    try t.expect(!rect.contains(10, 9));
}
