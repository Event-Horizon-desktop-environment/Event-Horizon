const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    exec: []const u8,
    score: u32 = 0,
};

pub fn scoreQuery(name: []const u8, query: []const u8) u32 {
    if (query.len == 0) return 1;
    if (std.ascii.eqlIgnoreCase(name, query)) return 100;
    if (std.mem.startsWith(u8, name, query)) return 80;
    var nb: [128]u8 = undefined;
    var qb: [64]u8 = undefined;
    const nl = std.ascii.lowerString(nb[0..@min(name.len, 128)], name[0..@min(name.len, 128)]);
    const ql = std.ascii.lowerString(qb[0..@min(query.len, 64)], query[0..@min(query.len, 64)]);
    if (std.mem.startsWith(u8, nl, ql)) return 70;
    if (std.mem.indexOf(u8, nl, ql) != null) return 40;
    var ni: usize = 0;
    var qi: usize = 0;
    while (ni < nl.len and qi < ql.len) {
        if (nl[ni] == ql[qi]) qi += 1;
        ni += 1;
    }
    if (qi == ql.len) return 20;
    return 0;
}

pub fn rank(entries: []Entry, query: []const u8) void {
    for (entries) |*e| e.score = scoreQuery(e.name, query);
    std.mem.sort(Entry, entries, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.score > b.score;
        }
    }.lt);
}

test "appdrawer-search: scoring + rank" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 100), scoreQuery("Firefox", "Firefox"));
    try t.expectEqual(@as(u32, 80), scoreQuery("Firefox", "Fire"));
    try t.expect(scoreQuery("Firefox", "ffx") > 0);
    try t.expectEqual(@as(u32, 0), scoreQuery("Firefox", "zzz"));
    var es = [_]Entry{ .{ .name = "Settings", .exec = "s" }, .{ .name = "Firefox", .exec = "f" } };
    rank(&es, "fire");
    try t.expectEqualStrings("Firefox", es[0].name);
}
