const std = @import("std");

pub const Zone = struct {
    name: []const u8,
    offset_min: i32,
};

pub fn localMinutes(hour: u8, min: u8, offset_min: i32, base_offset_min: i32) struct { h: u8, m: u8 } {
    const total: i32 = @as(i32, hour) * 60 + @as(i32, min) + (offset_min - base_offset_min);
    const wrapped = @mod(total, 24 * 60);
    return .{ .h = @intCast(@divTrunc(wrapped, 60)), .m = @intCast(@mod(wrapped, 60)) };
}

pub fn formatOffset(alloc: std.mem.Allocator, offset_min: i32) ![]u8 {
    const sign: u8 = if (offset_min < 0) '-' else '+';
    const a: u32 = @intCast(@abs(offset_min));
    return std.fmt.allocPrint(alloc, "UTC{c}{d:0>2}:{d:0>2}", .{ sign, a / 60, a % 60 });
}

test "world-clock: zone math" {
    const t = std.testing;
    const r = localMinutes(12, 0, 60, 0);
    try t.expect(r.h == 13 and r.m == 0);
    const r2 = localMinutes(0, 30, -300, 0);
    try t.expect(r2.h == 19 and r2.m == 30);
    const s = try formatOffset(t.allocator, -330);
    defer t.allocator.free(s);
    try t.expectEqualStrings("UTC-05:30", s);
}
