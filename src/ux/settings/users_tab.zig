const std = @import("std");

pub const User = struct {
    name: []const u8,
    real_name: []const u8 = "",
    admin: bool = false,
    locked: bool = false,
};

pub fn canRemove(users: []const User, name: []const u8) bool {
    var admins: usize = 0;
    var found = false;
    for (users) |u| {
        if (u.admin and !u.locked) admins += 1;
        if (std.mem.eql(u8, u.name, name)) found = true;
    }
    if (!found) return false;
    if (users.len <= 1) return false;
    for (users) |u| {
        if (std.mem.eql(u8, u.name, name) and u.admin and admins <= 1) return false;
    }
    return true;
}

test "settings-users: last-admin guard" {
    const t = std.testing;
    const us = [_]User{ .{ .name = "a", .admin = true }, .{ .name = "b" } };
    try t.expect(!canRemove(&us, "a"));
    try t.expect(canRemove(&us, "b"));
    const solo = [_]User{.{ .name = "a", .admin = true }};
    try t.expect(!canRemove(&solo, "a"));
}
