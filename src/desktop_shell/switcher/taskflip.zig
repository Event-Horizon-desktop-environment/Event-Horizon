const std = @import("std");

pub const Entry = struct {
    id: u64,
    title: []const u8,
    last_focus_ms: i64 = 0,
};

pub const Model = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    selected: usize = 0,
    mru: bool = true,

    pub fn init(alloc: std.mem.Allocator) Model {
        return .{ .alloc = alloc, .entries = .empty };
    }

    pub fn deinit(self: *Model) void {
        self.entries.deinit(self.alloc);
    }

    pub fn setWindows(self: *Model, ids: []const u64, titles: []const []const u8, now_ms: i64) !void {
        _ = now_ms;
        self.entries.clearRetainingCapacity();
        for (ids, 0..) |id, i| {
            try self.entries.append(self.alloc, .{
                .id = id,
                .title = if (i < titles.len) titles[i] else "",
            });
        }
        self.selected = 0;
    }

    pub fn focus(self: *Model, id: u64, now_ms: i64) void {
        for (self.entries.items, 0..) |*e, i| {
            if (e.id == id) {
                e.last_focus_ms = now_ms;
                if (self.mru and i != 0) {
                    const entry = self.entries.orderedRemove(i);
                    self.entries.insert(self.alloc, 0, entry) catch {};
                }
                self.selected = 0;
                return;
            }
        }
    }

    pub fn moveSelection(self: *Model, delta: isize) void {
        if (self.entries.items.len == 0) return;
        const n: isize = @intCast(self.entries.items.len);
        var s: isize = @intCast(self.selected);
        s = @mod(s + delta, n);
        self.selected = @intCast(s);
    }

    pub fn selectedId(self: *const Model) ?u64 {
        if (self.selected < self.entries.items.len) return self.entries.items[self.selected].id;
        return null;
    }
};

test "taskflip: mru reorder + wrap selection" {
    const t = std.testing;
    var m = Model.init(t.allocator);
    defer m.deinit();
    try m.setWindows(&[_]u64{ 1, 2, 3 }, &[_][]const u8{ "a", "b", "c" }, 0);
    m.focus(3, 100);
    try t.expectEqual(@as(u64, 3), m.entries.items[0].id);
    try t.expectEqual(@as(u64, 3), m.selectedId().?);
    m.moveSelection(1);
    try t.expectEqual(@as(u64, 1), m.selectedId().?);
    m.moveSelection(-1);
    try t.expectEqual(@as(u64, 3), m.selectedId().?);
}
