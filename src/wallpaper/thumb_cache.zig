const std = @import("std");

pub const Entry = struct {
    key: []u8,
    bytes: u64,
    last_used_ms: i64,
};

pub const Cache = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    cap_bytes: u64,

    pub fn init(alloc: std.mem.Allocator, cap_bytes: u64) Cache {
        return .{ .alloc = alloc, .entries = .empty, .cap_bytes = cap_bytes };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |*e| self.alloc.free(e.key);
        self.entries.deinit(self.alloc);
    }

    pub fn totalBytes(self: *const Cache) u64 {
        var n: u64 = 0;
        for (self.entries.items) |e| n += e.bytes;
        return n;
    }

    pub fn insert(self: *Cache, key: []const u8, bytes: u64, now_ms: i64) !void {
        for (self.entries.items, 0..) |*e, i| {
            if (std.mem.eql(u8, e.key, key)) {
                e.bytes = bytes;
                e.last_used_ms = now_ms;
                _ = i;
                return self.evict(now_ms);
            }
        }
        try self.entries.append(self.alloc, .{
            .key = try self.alloc.dupe(u8, key),
            .bytes = bytes,
            .last_used_ms = now_ms,
        });
        return self.evict(now_ms);
    }

    fn evict(self: *Cache, now_ms: i64) void {
        _ = now_ms;
        while (self.totalBytes() > self.cap_bytes and self.entries.items.len > 0) {
            var oldest: usize = 0;
            for (self.entries.items, 0..) |e, i| {
                if (e.last_used_ms < self.entries.items[oldest].last_used_ms) oldest = i;
            }
            const e = self.entries.orderedRemove(oldest);
            self.alloc.free(e.key);
        }
    }

    pub fn lookup(self: *Cache, key: []const u8, now_ms: i64) bool {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.last_used_ms = now_ms;
                return true;
            }
        }
        return false;
    }
};

test "thumb-cache: lru eviction" {
    const t = std.testing;
    var c = Cache.init(t.allocator, 100);
    defer c.deinit();
    try c.insert("a", 60, 1);
    try c.insert("b", 60, 2);
    try t.expectEqual(@as(usize, 1), c.entries.items.len);
    try t.expect(c.lookup("b", 3));
    try t.expect(!c.lookup("a", 3));
}
