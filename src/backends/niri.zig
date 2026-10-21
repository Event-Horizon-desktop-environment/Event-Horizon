const std = @import("std");

pub const Workspace = struct {
    idx: u32 = 0,
    name: []const u8 = "",
    focused: bool = false,
    active_window_id: u64 = 0,
};

pub fn socketPath(env_niri_socket: ?[]const u8, xdg_runtime: ?[]const u8) ?[]const u8 {
    if (env_niri_socket) |p| return p;
    _ = xdg_runtime;
    return null;
}

pub fn parseWorkspaces(alloc: std.mem.Allocator, json_text: []const u8) ![]Workspace {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadShape;
    const arr = parsed.value.object.get("workspaces") orelse return error.BadShape;
    if (arr != .array) return error.BadShape;
    var out: std.ArrayList(Workspace) = .empty;
    errdefer out.deinit(alloc);
    for (arr.array.items) |item| {
        if (item != .object) continue;
        var w = Workspace{};
        if (item.object.get("idx")) |v| {
            if (v == .integer) w.idx = @intCast(v.integer);
        }
        if (item.object.get("name")) |v| {
            if (v == .string) w.name = try alloc.dupe(u8, v.string);
        }
        if (item.object.get("is_focused")) |v| {
            if (v == .bool) w.focused = v.bool;
        }
        if (item.object.get("active_window_id")) |v| {
            if (v == .integer) w.active_window_id = @intCast(v.integer);
        }
        try out.append(alloc, w);
    }
    return out.toOwnedSlice(alloc);
}

test "niri: workspace JSON parse" {
    const t = std.testing;
    const doc =
        \\{"workspaces":[{"idx":0,"name":null,"is_focused":true,"active_window_id":42}]}
    ;
    const ws = try parseWorkspaces(t.allocator, doc);
    defer {
        for (ws) |w| {
            if (w.name.len > 0) t.allocator.free(w.name);
        }
        t.allocator.free(ws);
    }
    try t.expectEqual(@as(usize, 1), ws.len);
    try t.expect(ws[0].focused);
    try t.expectEqual(@as(u64, 42), ws[0].active_window_id);
    try t.expect(socketPath("/tmp/niri.sock", null) != null);
}
