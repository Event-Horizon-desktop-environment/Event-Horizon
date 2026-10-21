const std = @import("std");

pub fn joinCommand(alloc: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (args, 0..) |a, i| {
        if (i > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, a);
    }
    try out.append(alloc, '\n');
    return out.toOwnedSlice(alloc);
}

pub fn splitResponse(resp: []const u8) []const u8 {
    return std.mem.trimEnd(u8, resp, "\r\n ");
}

pub fn isError(resp: []const u8) bool {
    return std.mem.startsWith(u8, resp, "error");
}

test "ipc-legacy: join/split/error" {
    const t = std.testing;
    const c = try joinCommand(t.allocator, &[_][]const u8{ "ping", "x" });
    defer t.allocator.free(c);
    try t.expectEqualStrings("ping x\n", c);
    try t.expectEqualStrings("pong", splitResponse("pong\n"));
    try t.expect(isError("error bad"));
    try t.expect(!isError("ok"));
}
