const std = @import("std");

pub const mib: u64 = 1024 * 1024;

pub fn alignUp(v: u64, alignment: u64) u64 {
    if (alignment == 0) return v;
    return ((v + alignment - 1) / alignment) * alignment;
}

pub fn validateSize(request_mb: u64, free_mb: u64, min_mb: u64) bool {
    if (request_mb < min_mb) return false;
    return request_mb <= free_mb;
}

pub fn validateLabel(label: []const u8, max_len: usize) bool {
    if (label.len == 0 or label.len > max_len) return false;
    for (label) |c| {
        if (c == '/' or c < 0x20) return false;
    }
    return true;
}

pub const known_fs = [_][]const u8{ "ext4", "btrfs", "xfs", "vfat", "exfat", "ntfs", "f2fs", "luks" };

pub fn knownFs(name: []const u8) bool {
    for (known_fs) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

test "disks-create-format: validation" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 2048), alignUp(1500, 1024));
    try t.expect(validateSize(500, 1000, 100));
    try t.expect(!validateSize(50, 1000, 100));
    try t.expect(!validateSize(2000, 1000, 100));
    try t.expect(validateLabel("DATA", 16));
    try t.expect(!validateLabel("a/b", 16));
    try t.expect(knownFs("ext4"));
    try t.expect(!knownFs("zfs"));
}
