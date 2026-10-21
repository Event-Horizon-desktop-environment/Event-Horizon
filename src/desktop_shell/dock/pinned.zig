const std = @import("std");

pub const Pin = struct {
    app_id: []const u8,
    title: []const u8 = "",
};

pub const PinList = struct {
    alloc: std.mem.Allocator,
    pins: std.ArrayList(Pin),

    pub fn init(alloc: std.mem.Allocator) PinList {
        return .{ .alloc = alloc, .pins = .empty };
    }

    pub fn deinit(self: *PinList) void {
        for (self.pins.items) |*p| {
            self.alloc.free(p.app_id);
            if (p.title.len > 0) self.alloc.free(p.title);
        }
        self.pins.deinit(self.alloc);
    }

    pub fn add(self: *PinList, app_id: []const u8) !bool {
        for (self.pins.items) |p| {
            if (std.mem.eql(u8, p.app_id, app_id)) return false;
        }
        try self.pins.append(self.alloc, .{ .app_id = try self.alloc.dupe(u8, app_id) });
        return true;
    }

    pub fn remove(self: *PinList, app_id: []const u8) bool {
        for (self.pins.items, 0..) |*p, i| {
            if (std.mem.eql(u8, p.app_id, app_id)) {
                self.alloc.free(p.app_id);
                if (p.title.len > 0) self.alloc.free(p.title);
                _ = self.pins.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn move(self: *PinList, from: usize, to: usize) bool {
        if (from >= self.pins.items.len or to >= self.pins.items.len) return false;
        const p = self.pins.orderedRemove(from);
        self.pins.insert(self.alloc, to, p) catch {
            self.pins.insert(self.alloc, from, p) catch {};
            return false;
        };
        return true;
    }
};

test "dock-pins: add/remove/move" {
    const t = std.testing;
    var l = PinList.init(t.allocator);
    defer l.deinit();
    try t.expect(try l.add("firefox"));
    try t.expect(!try l.add("firefox"));
    try t.expect(try l.add("kitty"));
    try t.expect(l.move(0, 1));
    try t.expectEqualStrings("kitty", l.pins.items[0].app_id);
    try t.expect(l.remove("firefox"));
    try t.expect(!l.remove("firefox"));
}
