const std = @import("std");

pub const Net = struct {
    ssid: []const u8,
    strength: u8,
    secured: bool,
    connected: bool = false,
};

pub const Model = struct {
    alloc: std.mem.Allocator,
    wifi_enabled: bool = true,
    nets: std.ArrayList(Net),

    pub fn init(alloc: std.mem.Allocator) Model {
        return .{ .alloc = alloc, .nets = .empty };
    }

    pub fn deinit(self: *Model) void {
        for (self.nets.items) |*n| self.alloc.free(n.ssid);
        self.nets.deinit(self.alloc);
    }

    pub fn setNets(self: *Model, ssids: []const []const u8, strengths: []const u8, secured: []const bool, connected: ?[]const u8) !void {
        for (self.nets.items) |*n| self.alloc.free(n.ssid);
        self.nets.clearRetainingCapacity();
        for (ssids, 0..) |s, i| {
            try self.nets.append(self.alloc, .{
                .ssid = try self.alloc.dupe(u8, s),
                .strength = if (i < strengths.len) strengths[i] else 0,
                .secured = if (i < secured.len) secured[i] else false,
                .connected = if (connected) |c| std.mem.eql(u8, c, s) else false,
            });
        }
        std.mem.sort(Net, self.nets.items, {}, struct {
            fn lt(_: void, a: Net, b: Net) bool {
                return a.strength > b.strength;
            }
        }.lt);
    }
};

test "settings-network: sorted nets" {
    const t = std.testing;
    var m = Model.init(t.allocator);
    defer m.deinit();
    try m.setNets(&[_][]const u8{ "a", "b" }, &[_]u8{ 30, 90 }, &[_]bool{ true, false }, "b");
    try t.expectEqualStrings("b", m.nets.items[0].ssid);
    try t.expect(m.nets.items[0].connected);
}
