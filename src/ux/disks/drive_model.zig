const std = @import("std");

pub const Partition = struct {
    number: u32,
    label: []const u8 = "",
    fs: []const u8 = "",
    size_mb: u64 = 0,
    mounted: bool = false,
};

pub const Drive = struct {
    alloc: std.mem.Allocator,
    path: []const u8,
    model: []const u8 = "",
    size_mb: u64 = 0,
    parts: std.ArrayList(Partition),

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !Drive {
        return .{ .alloc = alloc, .path = try alloc.dupe(u8, path), .parts = .empty };
    }

    pub fn deinit(self: *Drive) void {
        self.alloc.free(self.path);
        if (self.model.len > 0) self.alloc.free(self.model);
        for (self.parts.items) |*p| {
            if (p.label.len > 0) self.alloc.free(p.label);
            if (p.fs.len > 0) self.alloc.free(p.fs);
        }
        self.parts.deinit(self.alloc);
    }

    pub fn usedMb(self: *const Drive) u64 {
        var n: u64 = 0;
        for (self.parts.items) |p| n += p.size_mb;
        return n;
    }

    pub fn freeMb(self: *const Drive) u64 {
        return self.size_mb -| self.usedMb();
    }
};

test "disks-drive: used/free" {
    const t = std.testing;
    var d = try Drive.init(t.allocator, "/dev/sda");
    defer d.deinit();
    d.size_mb = 1000;
    try d.parts.append(t.allocator, .{ .number = 1, .size_mb = 400 });
    try d.parts.append(t.allocator, .{ .number = 2, .size_mb = 700 });
    try t.expectEqual(@as(u64, 1100), d.usedMb());
    try t.expectEqual(@as(u64, 0), d.freeMb());
}
