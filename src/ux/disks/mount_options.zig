const std = @import("std");

pub fn buildOptions(alloc: std.mem.Allocator, opts: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (opts, 0..) |o, i| {
        if (o.len == 0 or std.mem.indexOfScalar(u8, o, ',') != null) continue;
        if (i > 0 and out.items.len > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, o);
    }
    return out.toOwnedSlice(alloc);
}

pub fn splitOptions(opts: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, opts, ',');
    while (it.next()) |p| {
        if (p.len > 0) try out.append(alloc, p);
    }
    return out.toOwnedSlice(alloc);
}

test "disks-mount-opts: build/split round trip" {
    const t = std.testing;
    const b = try buildOptions(t.allocator, &[_][]const u8{ "nosuid", "nodev", "", "noexec,x" });
    defer t.allocator.free(b);
    try t.expectEqualStrings("nosuid,nodev", b);
    const s = try splitOptions("a,,b", t.allocator);
    defer t.allocator.free(s);
    try t.expectEqual(@as(usize, 2), s.len);
}
