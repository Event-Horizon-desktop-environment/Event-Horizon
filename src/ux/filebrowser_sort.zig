const std = @import("std");

pub const Field = enum { name, size, modified, kind };
pub const Dir = enum { asc, desc };

pub const Entry = struct {
    name: []const u8,
    size: i64 = 0,
    modified: i64 = 0,
    is_dir: bool = false,
    kind_rank: u8 = 0,
};

pub fn less(a: Entry, b: Entry, field: Field, dir: Dir, folders_first: bool) bool {
    if (folders_first and a.is_dir != b.is_dir) return a.is_dir;
    const ord: std.math.Order = switch (field) {
        .name => std.mem.order(u8, a.name, b.name),
        .size => std.math.order(a.size, b.size),
        .modified => std.math.order(a.modified, b.modified),
        .kind => std.math.order(a.kind_rank, b.kind_rank),
    };
    if (dir == .asc) return ord == .lt;
    return ord == .gt;
}

pub fn sort(entries: []Entry, field: Field, dir: Dir, folders_first: bool) void {
    std.mem.sort(Entry, entries, .{ field, dir, folders_first }, struct {
        fn lt(ctx: struct { Field, Dir, bool }, a: Entry, b: Entry) bool {
            return less(a, b, ctx[0], ctx[1], ctx[2]);
        }
    }.lt);
}

test "filebrowser-sort: folders first + desc" {
    const t = std.testing;
    var es = [_]Entry{
        .{ .name = "b.txt", .size = 5 },
        .{ .name = "a", .is_dir = true },
        .{ .name = "c.txt", .size = 99 },
    };
    sort(&es, .name, .asc, true);
    try t.expect(es[0].is_dir);
    try t.expectEqualStrings("b.txt", es[1].name);
    sort(&es, .size, .desc, false);
    try t.expectEqual(@as(i64, 99), es[0].size);
}
