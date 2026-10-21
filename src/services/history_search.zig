const std = @import("std");

pub const Item = struct {
    app: []const u8,
    title: []const u8,
    id: u32,
};

pub fn search(items: []const Item, alloc: std.mem.Allocator, query: []const u8, max: usize) ![]*const Item {
    const Scored = struct {
        item: *const Item,
        score: u32,
    };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(alloc);
    var qbuf: [128]u8 = undefined;
    const q = std.ascii.lowerString(qbuf[0..@min(query.len, 128)], query[0..@min(query.len, 128)]);
    for (items) |*it| {
        var nb: [256]u8 = undefined;
        const hay = std.ascii.lowerString(nb[0..@min(it.title.len, 256)], it.title[0..@min(it.title.len, 256)]);
        var s: u32 = 0;
        if (q.len == 0) {
            s = 1;
        } else if (std.mem.startsWith(u8, hay, q)) {
            s = 60;
        } else if (std.mem.indexOf(u8, hay, q) != null) {
            s = 30;
        } else {
            var ab: [128]u8 = undefined;
            const ahay = std.ascii.lowerString(ab[0..@min(it.app.len, 128)], it.app[0..@min(it.app.len, 128)]);
            if (std.mem.indexOf(u8, ahay, q) != null) s = 20;
        }
        if (s > 0) try scored.append(alloc, .{ .item = it, .score = s });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lt);
    var out: std.ArrayList(*const Item) = .empty;
    errdefer out.deinit(alloc);
    for (scored.items) |e| {
        if (out.items.len >= max) break;
        try out.append(alloc, e.item);
    }
    return out.toOwnedSlice(alloc);
}

test "history-search: ranked substring" {
    const t = std.testing;
    const items = [_]Item{
        .{ .app = "a", .title = "zebra", .id = 1 },
        .{ .app = "b", .title = "apple", .id = 2 },
    };
    const r = try search(&items, t.allocator, "app", 10);
    defer t.allocator.free(r);
    try t.expectEqual(@as(usize, 1), r.len);
    try t.expectEqual(@as(u32, 2), r[0].id);
    const r2 = try search(&items, t.allocator, "", 10);
    defer t.allocator.free(r2);
    try t.expectEqual(@as(usize, 2), r2.len);
}
