const std = @import("std");

pub const Entry = struct {
    desktop_id: []const u8,
    name: []const u8,
    enabled: bool = true,
    delay_sec: u32 = 0,
};

pub fn toggle(entries: []Entry, desktop_id: []const u8) ?bool {
    for (entries) |*e| {
        if (std.mem.eql(u8, e.desktop_id, desktop_id)) {
            e.enabled = !e.enabled;
            return e.enabled;
        }
    }
    return null;
}

pub fn enabledCount(entries: []const Entry) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (e.enabled) n += 1;
    }
    return n;
}

test "settings-autostart: toggle + count" {
    const t = std.testing;
    var es = [_]Entry{ .{ .desktop_id = "a.desktop", .name = "A" }, .{ .desktop_id = "b.desktop", .name = "B", .enabled = false } };
    try t.expectEqual(@as(bool, false), toggle(&es, "a.desktop").?);
    try t.expectEqual(@as(usize, 0), enabledCount(&es));
    try t.expect(toggle(&es, "zzz") == null);
}
