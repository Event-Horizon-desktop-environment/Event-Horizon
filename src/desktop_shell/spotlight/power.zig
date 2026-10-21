const std = @import("std");

pub const Action = enum {
    lock,
    logout,
    sleep,
    hibernate,
    reboot,
    shutdown,
    reload_shell,
};

pub const Entry = struct {
    action: Action,
    title: []const u8,
    keywords: []const []const u8,
};

pub const entries = [_]Entry{
    .{ .action = .lock, .title = "Lock screen", .keywords = &.{ "lock", "screen" } },
    .{ .action = .logout, .title = "Log out", .keywords = &.{ "logout", "log", "out", "exit" } },
    .{ .action = .sleep, .title = "Suspend", .keywords = &.{ "suspend", "sleep" } },
    .{ .action = .hibernate, .title = "Hibernate", .keywords = &.{"hibernate"} },
    .{ .action = .reboot, .title = "Restart", .keywords = &.{ "reboot", "restart" } },
    .{ .action = .shutdown, .title = "Shut down", .keywords = &.{ "shutdown", "power", "off" } },
    .{ .action = .reload_shell, .title = "Reload shell", .keywords = &.{ "reload", "restart shell" } },
};

pub fn score(query: []const u8, e: Entry) u32 {
    var best: u32 = 0;
    for (e.keywords) |kw| {
        if (std.mem.eql(u8, kw, query)) return 100;
        if (std.mem.startsWith(u8, kw, query)) {
            best = @max(best, 60);
        } else if (std.mem.indexOf(u8, kw, query) != null) {
            best = @max(best, 30);
        }
    }
    if (std.mem.indexOf(u8, e.title, query) != null) best = @max(best, 20);
    return best;
}

pub fn match(alloc: std.mem.Allocator, query: []const u8) ![]Entry {
    var qbuf: [64]u8 = undefined;
    const q = std.ascii.lowerString(qbuf[0..@min(query.len, 64)], query[0..@min(query.len, 64)]);
    if (q.len == 0) return &.{};
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(alloc);
    for (entries) |e| {
        if (score(q, e) > 0) try out.append(alloc, e);
    }
    std.mem.sort(Entry, out.items, q, struct {
        fn lt(qq: []const u8, a: Entry, b: Entry) bool {
            return score(qq, a) > score(qq, b);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

test "seeker-power: matches and ranks" {
    const t = std.testing;
    const r = try match(t.allocator, "lock");
    defer t.allocator.free(r);
    try t.expect(r.len >= 1);
    try t.expectEqual(Action.lock, r[0].action);
    const r2 = try match(t.allocator, "zzz-nope");
    defer t.allocator.free(r2);
    try t.expectEqual(@as(usize, 0), r2.len);
}
