const std = @import("std");

pub const Entry = struct {
    app: []const u8,
    name: []const u8,
    pending: bool = false,
    update_id: []const u8 = "",
};

pub fn toggle(entries: []Entry, app_id: []const u8) ?bool {
    for (entries) |*e| {
        if (std.mem.eql(u8, e.app, app_id)) {
            e.pending = !e.pending;
            return e.pending;
        }
    }
    return null;
}

pub fn pendingCount(entries: []const Entry) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (e.pending) n += 1;
    }
    return n;
}

test "settings-updater: toggle + count" {
    const t = std.testing;
    var es = [_]Entry{ .{ .app = "system", .name = "System" }, .{ .app = "repo", .name = "Repo", .pending = false } };
    try t.expectEqual(@as(bool, true), toggle(&es, "system").?);
    try t.expectEqual(@as(usize, 1), pendingCount(&es));
    try t.expectEqual(@as(bool, false), toggle(&es, "system").?);
    try t.expectEqual(@as(usize, 0), pendingCount(&es));
    try t.expect(toggle(&es, "zzz") == null);
}
