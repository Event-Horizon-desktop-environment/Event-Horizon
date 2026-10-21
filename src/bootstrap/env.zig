const std = @import("std");

pub const Pair = struct { k: []const u8, v: []const u8 };

pub fn childEnv(alloc: std.mem.Allocator, pairs: []const Pair) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (pairs) |p| {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}", .{ p.k, p.v }));
    }
    return out.toOwnedSlice(alloc);
}

pub fn supervisorMarker(alloc: std.mem.Allocator, pid: i32) ![]u8 {
    return std.fmt.allocPrint(alloc, "EH_SUPERVISOR_PID={d}", .{pid});
}

pub fn freeEnv(alloc: std.mem.Allocator, env: [][]const u8) void {
    for (env) |e| alloc.free(e);
    alloc.free(env);
}

test "bootstrap-env: block build" {
    const t = std.testing;
    const env = try childEnv(t.allocator, &[_]Pair{
        .{ .k = "A", .v = "1" },
        .{ .k = "B", .v = "x y" },
    });
    defer freeEnv(t.allocator, env);
    try t.expectEqual(@as(usize, 2), env.len);
    try t.expectEqualStrings("A=1", env[0]);
    const m = try supervisorMarker(t.allocator, 1234);
    defer t.allocator.free(m);
    try t.expectEqualStrings("EH_SUPERVISOR_PID=1234", m);
}
