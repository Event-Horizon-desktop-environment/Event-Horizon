const std = @import("std");

pub const Item = struct {
    name: []const u8,
    exec: []const u8,
    categories: []const u8 = "",
    frequently_used: u32 = 0,
};

pub fn pinScore(it: Item) u64 {
    return @as(u64, it.frequently_used) * 1000 + @as(u64, it.name.len);
}

pub fn sortPinned(items: []Item) void {
    std.mem.sort(Item, items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return pinScore(a) > pinScore(b);
        }
    }.lt);
}

pub fn filterByCategory(items: []const Item, alloc: std.mem.Allocator, cat: []const u8) ![]*const Item {
    var out: std.ArrayList(*const Item) = .empty;
    errdefer out.deinit(alloc);
    for (items) |*it| {
        if (std.mem.indexOf(u8, it.categories, cat) != null) {
            try out.append(alloc, it);
        }
    }
    return out.toOwnedSlice(alloc);
}

test "startmenu: pin sort + category filter" {
    const t = std.testing;
    var items = [_]Item{
        .{ .name = "B", .exec = "b", .frequently_used = 1 },
        .{ .name = "A", .exec = "a", .frequently_used = 9, .categories = "Utility;" },
    };
    sortPinned(&items);
    try t.expectEqualStrings("A", items[0].name);
    const f = try filterByCategory(&items, t.allocator, "Utility");
    defer t.allocator.free(f);
    try t.expectEqual(@as(usize, 1), f.len);
}
