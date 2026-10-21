const std = @import("std");
const sock = @import("../sock.zig");

pub const magic = "i3-ipc";

pub const MsgType = struct {
    pub const run_command: u32 = 0;
    pub const get_workspaces: u32 = 1;
    pub const get_outputs: u32 = 3;
    pub const get_version: u32 = 7;
};

pub const Workspace = struct {
    num: i64 = 0,
    name: []const u8 = "",
    focused: bool = false,
    output: []const u8 = "",
};

pub fn encodeRequest(alloc: std.mem.Allocator, mtype: u32, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, magic);
    var lenb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenb, @intCast(payload.len), .little);
    try out.appendSlice(alloc, &lenb);
    var typeb: [4]u8 = undefined;
    std.mem.writeInt(u32, &typeb, mtype, .little);
    try out.appendSlice(alloc, &typeb);
    try out.appendSlice(alloc, payload);
    return out.toOwnedSlice(alloc);
}

pub const Decoded = struct {
    mtype: u32,
    payload: []const u8,
    consumed: usize,
};

pub fn decodeReply(data: []const u8) ?Decoded {
    if (data.len < 14) return null;
    if (!std.mem.eql(u8, data[0..6], magic)) return null;
    const len = std.mem.readInt(u32, data[6..10], .little);
    const mtype = std.mem.readInt(u32, data[10..14], .little);
    if (len > 64 << 20) return null;
    if (data.len < 14 + len) return null;
    return .{ .mtype = mtype, .payload = data[14 .. 14 + len], .consumed = 14 + len };
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
        if (item.object.get("num")) |v| {
            if (v == .integer) w.num = v.integer;
        }
        if (item.object.get("name")) |v| {
            if (v == .string) w.name = try alloc.dupe(u8, v.string);
        }
        if (item.object.get("focused")) |v| {
            if (v == .bool) w.focused = v.bool;
        }
        if (item.object.get("output")) |v| {
            if (v == .string) w.output = try alloc.dupe(u8, v.string);
        }
        try out.append(alloc, w);
    }
    return out.toOwnedSlice(alloc);
}

test "sway: framing round trip" {
    const t = std.testing;
    const enc = try encodeRequest(t.allocator, MsgType.get_workspaces, "");
    defer t.allocator.free(enc);
    try t.expectEqual(@as(usize, 14), enc.len);
    const d = decodeReply(enc).?;
    try t.expectEqual(MsgType.get_workspaces, d.mtype);
    try t.expect(d.payload.len == 0);
    try t.expect(decodeReply(enc[0..10]) == null);
    try t.expect(decodeReply("bogus-payload-padd") == null);
}

test "sway: workspace JSON parse" {
    const t = std.testing;
    const doc =
        \\[{"num":1,"name":"1","focused":true,"output":"DP-1"}]
    ;
    const ws = try parseWorkspaces(t.allocator, doc);
    defer {
        for (ws) |w| {
            t.allocator.free(w.name);
            t.allocator.free(w.output);
        }
        t.allocator.free(ws);
    }
    try t.expectEqual(@as(usize, 1), ws.len);
    try t.expectEqualStrings("DP-1", ws[0].output);
}
