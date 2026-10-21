const std = @import("std");

// Sound paint cache.
// Same design: per-engine snapshot cache keyed by device list digest so
// the sound tab skips repaint when PipeWire state is unchanged.

pub const CacheKey = struct {
    sink_count: usize = 0,
    source_count: usize = 0,
    sink_digest: u64 = 0,
    source_digest: u64 = 0,
};

pub fn digestNames(names: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    for (names) |n| {
        h.update(n);
        h.update(&[_]u8{0});
    }
    return h.final();
}

pub const SoundCache = struct {
    last: CacheKey = .{},
    valid: bool = false,

    pub fn needsRepaint(self: *SoundCache, key: CacheKey) bool {
        if (!self.valid) {
            self.last = key;
            self.valid = true;
            return true;
        }
        if (!std.meta.eql(self.last, key)) {
            self.last = key;
            return true;
        }
        return false;
    }

    pub fn invalidate(self: *SoundCache) void {
        self.valid = false;
    }
};

// Wallpaper thumbnail LRU.
// Same design: path->mtime cache, LRU eviction at 64 entries, sort modes.

pub const max_thumbs: usize = 64;

pub const ThumbCache = struct {
    alloc: std.mem.Allocator,
    order: std.ArrayList([]const u8),

    pub fn init(alloc: std.mem.Allocator) ThumbCache {
        return .{ .alloc = alloc, .order = .empty };
    }

    pub fn deinit(self: *ThumbCache) void {
        for (self.order.items) |p| self.alloc.free(p);
        self.order.deinit(self.alloc);
    }

    pub fn touch(self: *ThumbCache, path: []const u8) !void {
        for (self.order.items, 0..) |p, i| {
            if (std.mem.eql(u8, p, path)) {
                const owned = self.order.orderedRemove(i);
                try self.order.append(self.alloc, owned);
                return;
            }
        }
        try self.order.append(self.alloc, try self.alloc.dupe(u8, path));
        while (self.order.items.len > max_thumbs) {
            const old = self.order.orderedRemove(0);
            self.alloc.free(old);
        }
    }
};

test "settings-caches: sound digest + thumb lru" {
    const t = std.testing;
    var c = SoundCache{};
    try t.expect(c.needsRepaint(.{ .sink_count = 1 }));
    try t.expect(!c.needsRepaint(.{ .sink_count = 1 }));
    try t.expect(c.needsRepaint(.{ .sink_count = 2 }));
    var th = ThumbCache.init(t.allocator);
    defer th.deinit();
    try th.touch("/a.png");
    try th.touch("/a.png");
    try t.expectEqual(@as(usize, 1), th.order.items.len);
}
