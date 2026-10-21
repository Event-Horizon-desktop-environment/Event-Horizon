const std = @import("std");

pub const ScanResult = struct {
    path: []const u8,
    exec: []const u8,
    terminal: bool,
};

pub fn isDesktopFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".desktop");
}

pub fn shouldSkipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, "autostart-post") or std.mem.eql(u8, name, ".hidden");
}

test "autostart-scan: filters" {
    const t = std.testing;
    try t.expect(isDesktopFile("foo.desktop"));
    try t.expect(!isDesktopFile("foo.txt"));
    try t.expect(shouldSkipDir("autostart-post"));
    try t.expect(!shouldSkipDir("default"));
}
