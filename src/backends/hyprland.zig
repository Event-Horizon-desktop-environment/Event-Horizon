const std = @import("std");
const sock = @import("../sock.zig");

pub const Workspace = struct {
    id: i64 = 0,
    name: []const u8 = "",
    focused: bool = false,
};

pub fn socketDir(alloc: std.mem.Allocator, xdg_runtime: ?[]const u8, sig: []const u8) ![]u8 {
    if (xdg_runtime) |d| {
        return std.fs.path.join(alloc, &.{ d, "hypr", sig });
    }
    return alloc.dupe(u8, "/tmp/hypr");
}

pub fn socketPath(alloc: std.mem.Allocator, dir: []const u8, events: bool) ![]u8 {
    return std.fs.path.join(alloc, &.{ dir, if (events) ".socket2.sock" else ".socket.sock" });
}

pub fn ipcQuery(alloc: std.mem.Allocator, sock_path: []const u8, cmd: []const u8) ![]u8 {
    const fd = try sock.createStream(false);
    defer sock.closeFd(fd);
    if (sock.connectPath(fd, sock_path) != null) return error.ConnectFailed;
    try sock.sendAll(fd, cmd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n: usize = std.os.linux.read(fd, &chunk, chunk.len);
        const s: isize = @bitCast(n);
        if (s < 0) {
            const e = std.os.linux.errno(n);
            if (e == .INTR) continue;
            break;
        }
        if (s == 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(s)]);
        if (out.items.len > 8 << 20) break;
    }
    return out.toOwnedSlice(alloc);
}

pub fn parseWorkspaces(alloc: std.mem.Allocator, json_text: []const u8) ![]Workspace {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.BadShape;
    var out: std.ArrayList(Workspace) = .empty;
    errdefer out.deinit(alloc);
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        var w = Workspace{};
        if (item.object.get("id")) |v| {
            if (v == .integer) w.id = v.integer;
        }
        if (item.object.get("name")) |v| {
            if (v == .string) w.name = try alloc.dupe(u8, v.string);
        }
        if (item.object.get("focused")) |v| {
            if (v == .bool) w.focused = v.bool;
        }
        try out.append(alloc, w);
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeWorkspaces(alloc: std.mem.Allocator, ws: []Workspace) void {
    for (ws) |w| {
        if (w.name.len > 0) alloc.free(w.name);
    }
    alloc.free(ws);
}

test "hyprland: workspace JSON parse" {
    const t = std.testing;
    const doc =
        \\[{"id":1,"name":"1","focused":true},{"id":2,"name":"code","focused":false}]
    ;
    const ws = try parseWorkspaces(t.allocator, doc);
    defer freeWorkspaces(t.allocator, ws);
    try t.expectEqual(@as(usize, 2), ws.len);
    try t.expectEqual(@as(i64, 1), ws[0].id);
    try t.expect(ws[0].focused);
    try t.expectEqualStrings("code", ws[1].name);
    const dir = try socketDir(t.allocator, "/run/user/1000", "abc123");
    defer t.allocator.free(dir);
    try t.expectEqualStrings("/run/user/1000/hypr/abc123", dir);
}
