const std = @import("std");

pub const Item = struct {
    path: []const u8,
    is_video: bool = false,
    thumb_ready: bool = false,
};

pub const Gallery = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(Item),
    selected: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Gallery {
        return .{ .alloc = alloc, .items = .empty };
    }

    pub fn deinit(self: *Gallery) void {
        for (self.items.items) |*it| self.alloc.free(it.path);
        self.items.deinit(self.alloc);
    }

    pub fn add(self: *Gallery, path: []const u8, is_video: bool) !void {
        try self.items.append(self.alloc, .{
            .path = try self.alloc.dupe(u8, path),
            .is_video = is_video,
        });
    }

    pub fn moveSelection(self: *Gallery, delta: isize) void {
        if (self.items.items.len == 0) return;
        const n: isize = @intCast(self.items.items.len);
        var s: isize = @intCast(self.selected);
        s = @mod(s + delta, n);
        self.selected = @intCast(s);
    }

    pub fn current(self: *const Gallery) ?*const Item {
        if (self.selected < self.items.items.len) return &self.items.items[self.selected];
        return null;
    }
};

test "live-gallery: add/move/current" {
    const t = std.testing;
    var g = Gallery.init(t.allocator);
    defer g.deinit();
    try g.add("/a.png", false);
    try g.add("/b.mp4", true);
    try t.expectEqual(@as(usize, 0), g.selected);
    g.moveSelection(1);
    try t.expect(g.current().?.is_video);
    g.moveSelection(1);
    try t.expectEqual(@as(usize, 0), g.selected);
}
