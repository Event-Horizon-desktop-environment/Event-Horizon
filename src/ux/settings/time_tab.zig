const std = @import("std");

pub const zones = [_][]const u8{
    "UTC",             "Europe/London",    "Europe/Berlin",       "America/New_York",
    "America/Chicago", "America/Denver",   "America/Los_Angeles", "Asia/Tokyo",
    "Asia/Shanghai",   "Australia/Sydney",
};

pub fn suggestZone(query: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var qbuf: [64]u8 = undefined;
    const q = std.ascii.lowerString(qbuf[0..@min(query.len, 64)], query[0..@min(query.len, 64)]);
    for (zones) |z| {
        var zb: [64]u8 = undefined;
        const zl = std.ascii.lowerString(zb[0..@min(z.len, 64)], z[0..@min(z.len, 64)]);
        if (std.mem.indexOf(u8, zl, q) != null) try out.append(alloc, z);
    }
    return out.toOwnedSlice(alloc);
}

test "settings-time: zone suggest" {
    const t = std.testing;
    const r = try suggestZone("america", t.allocator);
    defer t.allocator.free(r);
    try t.expect(r.len >= 4);
    const r2 = try suggestZone("zzz", t.allocator);
    defer t.allocator.free(r2);
    try t.expectEqual(@as(usize, 0), r2.len);
}
