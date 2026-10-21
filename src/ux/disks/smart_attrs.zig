const std = @import("std");

pub const Attr = struct {
    id: u8,
    name: []const u8,
    value: u8,
    worst: u8,
    thresh: u8,
    failing: bool = false,
};

pub fn isFailing(value: u8, thresh: u8) bool {
    if (thresh == 0) return false;
    return value <= thresh;
}

pub fn parseAttrLine(line: []const u8) ?struct { id: u8, value: u8, worst: u8, thresh: u8 } {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const id_s = it.next() orelse return null;
    _ = it.next();
    const val_s = it.next() orelse return null;
    const worst_s = it.next() orelse return null;
    const thresh_s = it.next() orelse return null;
    const id = std.fmt.parseInt(u8, id_s, 10) catch return null;
    return .{
        .id = id,
        .value = std.fmt.parseInt(u8, val_s, 10) catch return null,
        .worst = std.fmt.parseInt(u8, worst_s, 10) catch return null,
        .thresh = std.fmt.parseInt(u8, thresh_s, 10) catch return null,
    };
}

test "disks-smart: attr parse + failing" {
    const t = std.testing;
    const a = parseAttrLine("  5 Reallocated_Sector_Ct 100 100 010").?;
    try t.expectEqual(@as(u8, 5), a.id);
    try t.expect(!isFailing(a.value, a.thresh));
    try t.expect(isFailing(5, 10));
    try t.expect(!isFailing(50, 0));
    try t.expect(parseAttrLine("bogus") == null);
}
