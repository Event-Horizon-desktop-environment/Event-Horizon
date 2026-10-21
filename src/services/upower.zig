const std = @import("std");

pub const Battery = struct {
    pct: i32 = 100,
    charging: bool = false,
    time_to_empty_min: u32 = 0,
    time_to_full_min: u32 = 0,
};

pub fn displayText(b: Battery, alloc: std.mem.Allocator) ![]u8 {
    if (b.charging) {
        if (b.time_to_full_min > 0) {
            return std.fmt.allocPrint(alloc, "{d}% ({d}m to full)", .{ b.pct, b.time_to_full_min });
        }
        return std.fmt.allocPrint(alloc, "{d}% charging", .{b.pct});
    }
    if (b.time_to_empty_min > 0) {
        return std.fmt.allocPrint(alloc, "{d}% ({d}m left)", .{ b.pct, b.time_to_empty_min });
    }
    return std.fmt.allocPrint(alloc, "{d}%", .{b.pct});
}

test "upower: display text" {
    const t = std.testing;
    const a = try displayText(.{ .pct = 80 }, t.allocator);
    defer t.allocator.free(a);
    try t.expectEqualStrings("80%", a);
    const b = try displayText(.{ .pct = 50, .charging = true, .time_to_full_min = 30 }, t.allocator);
    defer t.allocator.free(b);
    try t.expectEqualStrings("50% (30m to full)", b);
}
