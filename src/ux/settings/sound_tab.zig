const std = @import("std");

pub const Device = struct {
    name: []const u8,
    volume: i32 = 100,
    muted: bool = false,
    is_default: bool = false,
};

pub const Model = struct {
    alloc: std.mem.Allocator,
    sinks: std.ArrayList(Device),
    sources: std.ArrayList(Device),

    pub fn init(alloc: std.mem.Allocator) Model {
        return .{ .alloc = alloc, .sinks = .empty, .sources = .empty };
    }

    pub fn deinit(self: *Model) void {
        for (self.sinks.items) |*d| self.alloc.free(d.name);
        for (self.sources.items) |*d| self.alloc.free(d.name);
        self.sinks.deinit(self.alloc);
        self.sources.deinit(self.alloc);
    }

    pub fn upsertSink(self: *Model, name: []const u8, volume: i32, muted: bool) !void {
        for (self.sinks.items) |*d| {
            if (std.mem.eql(u8, d.name, name)) {
                d.volume = volume;
                d.muted = muted;
                return;
            }
        }
        try self.sinks.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .volume = volume,
            .muted = muted,
        });
    }
};

test "settings-sound: sink upsert" {
    const t = std.testing;
    var m = Model.init(t.allocator);
    defer m.deinit();
    try m.upsertSink("alsa", 70, false);
    try m.upsertSink("alsa", 80, true);
    try t.expectEqual(@as(usize, 1), m.sinks.items.len);
    try t.expectEqual(@as(i32, 80), m.sinks.items[0].volume);
    try t.expect(m.sinks.items[0].muted);
}
