const std = @import("std");
const toml = @import("toml.zig");

pub fn writeBool(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, v: bool) !void {
    try out.appendSlice(alloc, key);
    try out.appendSlice(alloc, if (v) " = true\n" else " = false\n");
}

pub fn writeInt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, v: i64) !void {
    const s = try std.fmt.allocPrint(alloc, "{s} = {d}\n", .{ key, v });
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

pub fn writeFloat(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, v: f64) !void {
    const s = try std.fmt.allocPrint(alloc, "{s} = {d}\n", .{ key, v });
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

pub fn writeString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, v: []const u8) !void {
    try out.appendSlice(alloc, key);
    try out.appendSlice(alloc, " = \"");
    for (v) |c| {
        if (c == '"') try out.appendSlice(alloc, "\\\"");
        if (c == '\\') try out.appendSlice(alloc, "\\\\");
        if (c == '\n') try out.appendSlice(alloc, "\\n");
        if (c != '"' and c != '\\' and c != '\n') try out.append(alloc, c);
    }
    try out.appendSlice(alloc, "\"\n");
}

pub fn writeStringArray(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, vals: []const []const u8) !void {
    try out.appendSlice(alloc, key);
    try out.appendSlice(alloc, " = [");
    for (vals, 0..) |v, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        try out.append(alloc, '"');
        for (v) |c| {
            if (c == '"') try out.appendSlice(alloc, "\\\"") else try out.append(alloc, c);
        }
        try out.append(alloc, '"');
    }
    try out.appendSlice(alloc, "]\n");
}

test "toml-writer: round trip through parser" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try writeBool(&out, t.allocator, "autohide", true);
    try writeInt(&out, t.allocator, "icon_size", 48);
    try writeFloat(&out, t.allocator, "scale", 1.5);
    try writeString(&out, t.allocator, "output", "DP-1");
    try writeStringArray(&out, t.allocator, "pinned", &[_][]const u8{ "a", "b\"c" });
    var doc = try toml.parse(t.allocator, out.items);
    defer doc.deinit();
    try t.expect(doc.root.get("autohide").?.boolean);
    try t.expectEqual(@as(i64, 48), doc.root.get("icon_size").?.integer);
    try t.expectEqual(@as(f64, 1.5), doc.root.get("scale").?.float);
    try t.expectEqualStrings("DP-1", doc.root.get("output").?.string);
    try t.expectEqual(@as(usize, 2), doc.root.get("pinned").?.array.len);
}
