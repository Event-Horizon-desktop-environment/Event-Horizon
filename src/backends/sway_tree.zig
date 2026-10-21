const std = @import("std");

pub const NodeKind = enum { root, output, workspace, app, window };

pub fn findFocusedWorkspace(node: std.json.Value) ?[]const u8 {
    if (node != .object) return null;
    if (node.object.get("focused")) |f| {
        if (f == .bool and f.bool) {
            if (node.object.get("name")) |n| {
                if (n == .string) return n.string;
            }
        }
    }
    if (node.object.get("nodes")) |kids| {
        if (kids == .array) {
            for (kids.array.items) |kid| {
                if (findFocusedWorkspace(kid)) |name| return name;
            }
        }
    }
    if (node.object.get("floating_nodes")) |kids| {
        if (kids == .array) {
            for (kids.array.items) |kid| {
                if (findFocusedWorkspace(kid)) |name| return name;
            }
        }
    }
    return null;
}

pub fn countWindows(node: std.json.Value) usize {
    if (node != .object) return 0;
    var n: usize = 0;
    if (node.object.get("app_id") != null or node.object.get("window") != null) n += 1;
    if (node.object.get("nodes")) |kids| {
        if (kids == .array) {
            for (kids.array.items) |kid| n += countWindows(kid);
        }
    }
    if (node.object.get("floating_nodes")) |kids| {
        if (kids == .array) {
            for (kids.array.items) |kid| n += countWindows(kid);
        }
    }
    return n;
}

test "sway-tree: focused workspace + window count" {
    const t = std.testing;
    const doc =
        \\{"name":"root","nodes":[{"name":"1","focused":true,"nodes":[{"app_id":"foot"}],"floating_nodes":[]}],"floating_nodes":[]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, doc, .{});
    defer parsed.deinit();
    try t.expectEqualStrings("1", findFocusedWorkspace(parsed.value).?);
    try t.expectEqual(@as(usize, 1), countWindows(parsed.value));
}
