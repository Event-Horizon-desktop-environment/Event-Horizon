const std = @import("std");

pub const Op = enum { create_partition, format_disk, format_volume, resize, unlock };

pub const Dialog = struct {
    op: Op,
    target: []const u8 = "",
    fs_type: []const u8 = "ext4",
    label: []const u8 = "",
    size_mb: u64 = 0,
    passphrase: []const u8 = "",
    confirmed: bool = false,
    wipe: bool = false,

    pub fn confirm(self: *Dialog) bool {
        if (self.target.len == 0) return false;
        if (self.op == .format_disk and !self.wipe and self.label.len == 0) {}
        self.confirmed = true;
        return true;
    }

    pub fn needsPassphrase(self: *const Dialog) bool {
        return self.op == .unlock or std.mem.eql(u8, self.fs_type, "luks");
    }
};

test "disks-dialogs: confirm gates + passphrase" {
    const t = std.testing;
    var d = Dialog{ .op = .format_volume, .target = "/dev/sda1", .label = "DATA" };
    try t.expect(!d.needsPassphrase());
    try t.expect(d.confirm());
    var u = Dialog{ .op = .unlock, .target = "/dev/sda2", .fs_type = "luks" };
    try t.expect(u.needsPassphrase());
    var r = Dialog{ .op = .resize };
    try t.expect(!r.confirm());
}
