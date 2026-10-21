const std = @import("std");

pub fn escapeElement(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9');
        if (ok) {
            try out.append(alloc, ch);
        } else {
            const digits = "0123456789abcdef";
            try out.append(alloc, '_');
            try out.append(alloc, digits[ch >> 4]);
            try out.append(alloc, digits[ch & 0x0F]);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn joinPath(alloc: std.mem.Allocator, base: []const u8, elem: []const u8) ![]u8 {
    const esc = try escapeElement(alloc, elem);
    defer alloc.free(esc);
    if (base.len > 0 and base[base.len - 1] == '/') {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ base, esc });
    }
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, esc });
}

test "dbus-paths: escape + join" {
    const t = std.testing;
    const e = try escapeElement(t.allocator, "foo bar/baz");
    defer t.allocator.free(e);
    try t.expectEqualStrings("foo_20bar_2fbaz", e);
    const j = try joinPath(t.allocator, "/org/test", "a b");
    defer t.allocator.free(j);
    try t.expectEqualStrings("/org/test/a_20b", j);
}
