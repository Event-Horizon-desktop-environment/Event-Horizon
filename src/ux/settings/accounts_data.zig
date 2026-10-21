const std = @import("std");

// Accounts/users data — Zig port of
// src/ux/settings/settings_tab_accounts/accounts_users.{hpp,cpp} (logic).
// Same design: last-admin guard, autologin info, hostname validation.
// I/O (passwd/group spawn) stays outside; pure rules are tested here.

pub const User = struct {
    name: []const u8,
    real_name: []const u8 = "",
    admin: bool = false,
    locked: bool = false,
};

pub fn canRemove(users: []const User, name: []const u8) bool {
    var found: ?User = null;
    var admins: usize = 0;
    for (users) |u| {
        if (u.admin and !u.locked) admins += 1;
        if (std.mem.eql(u8, u.name, name)) found = u;
    }
    const f = found orelse return false;
    if (users.len <= 1) return false;
    if (f.admin and admins <= 1) return false;
    return true;
}

pub fn isValidHostname(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        if (!ok) return false;
    }
    if (s[0] == '-' or s[s.len - 1] == '-') return false;
    return true;
}

pub fn isValidUsername(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    if (!std.ascii.isLower(s[0]) and s[0] != '_') return false;
    for (s) |c| {
        const ok = std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

test "settings-accounts: guards + validation" {
    const t = std.testing;
    const us = [_]User{ .{ .name = "a", .admin = true }, .{ .name = "b" } };
    try t.expect(!canRemove(&us, "a"));
    try t.expect(canRemove(&us, "b"));
    try t.expect(!canRemove(&us, "zzz"));
    try t.expect(isValidHostname("my-pc"));
    try t.expect(!isValidHostname("-bad"));
    try t.expect(isValidUsername("matt"));
    try t.expect(!isValidUsername("Matt"));
}
