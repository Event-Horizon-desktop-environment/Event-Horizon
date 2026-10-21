const std = @import("std");

pub const Glyph = struct {
    name: []const u8,
    codepoint: u21,
};

pub const table = [_]Glyph{
    .{ .name = "search", .codepoint = 0xE8B6 },
    .{ .name = "home", .codepoint = 0xE88A },
    .{ .name = "settings", .codepoint = 0xE8B8 },
    .{ .name = "power", .codepoint = 0xE8AC },
    .{ .name = "wifi", .codepoint = 0xE63E },
    .{ .name = "bluetooth", .codepoint = 0xE1A7 },
    .{ .name = "volume_up", .codepoint = 0xE050 },
    .{ .name = "volume_down", .codepoint = 0xE04D },
    .{ .name = "volume_mute", .codepoint = 0xE04E },
    .{ .name = "brightness_high", .codepoint = 0xE1AC },
    .{ .name = "battery_full", .codepoint = 0xE1A4 },
    .{ .name = "lock", .codepoint = 0xE897 },
    .{ .name = "logout", .codepoint = 0xE9BA },
    .{ .name = "restart", .codepoint = 0xE5D5 },
    .{ .name = "close", .codepoint = 0xE5CD },
    .{ .name = "check", .codepoint = 0xE5CA },
    .{ .name = "folder", .codepoint = 0xE2C7 },
    .{ .name = "terminal", .codepoint = 0xEB40 },
    .{ .name = "calendar", .codepoint = 0xEBCC },
    .{ .name = "clock", .codepoint = 0xE8B5 },
    .{ .name = "camera", .codepoint = 0xE3AF },
    .{ .name = "mic", .codepoint = 0xE029 },
    .{ .name = "play", .codepoint = 0xE037 },
    .{ .name = "pause", .codepoint = 0xE034 },
    .{ .name = "moon", .codepoint = 0xE3A8 },
    .{ .name = "sun", .codepoint = 0xE3A9 },
    .{ .name = "trash", .codepoint = 0xE872 },
    .{ .name = "edit", .codepoint = 0xE3C9 },
    .{ .name = "info", .codepoint = 0xE88E },
    .{ .name = "warning", .codepoint = 0xE002 },
    .{ .name = "menu", .codepoint = 0xE5D2 },
    .{ .name = "arrow_back", .codepoint = 0xE5C4 },
    .{ .name = "arrow_forward", .codepoint = 0xE5C8 },
    .{ .name = "refresh", .codepoint = 0xE5D5 },
    .{ .name = "download", .codepoint = 0xF090 },
    .{ .name = "upload", .codepoint = 0xF09B },
    .{ .name = "keyboard", .codepoint = 0xE312 },
    .{ .name = "monitor", .codepoint = 0xE01B },
    .{ .name = "print", .codepoint = 0xE8AD },
    .{ .name = "save", .codepoint = 0xE161 },
};

pub fn lookup(name: []const u8) ?u21 {
    for (table) |g| {
        if (std.mem.eql(u8, g.name, name)) return g.codepoint;
    }
    return null;
}

pub fn search(alloc: std.mem.Allocator, query: []const u8, max: usize) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var qbuf: [64]u8 = undefined;
    const q = std.ascii.lowerString(qbuf[0..@min(query.len, 64)], query[0..@min(query.len, 64)]);
    for (table) |g| {
        if (out.items.len >= max) break;
        if (std.mem.indexOf(u8, g.name, q) != null) {
            try out.append(alloc, g.name);
        }
    }
    return out.toOwnedSlice(alloc);
}

test "seeker-glyphs: lookup and search" {
    const t = std.testing;
    try t.expectEqual(@as(u21, 0xE8B6), lookup("search").?);
    try t.expect(lookup("nope") == null);
    const r = try search(t.allocator, "vol", 10);
    defer t.allocator.free(r);
    try t.expectEqual(@as(usize, 3), r.len);
}
