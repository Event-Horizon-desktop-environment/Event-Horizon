//! Reordering the pinned-app list while a drag is in flight. The drag itself
//! — the press, the six pixels, the drop — belongs to the dock; this is the
//! half worth testing on its own, because it is where a list of borrowed
//! strings turned into a list of owned ones and got that wrong once.

const std = @import("std");

/// The pin list with its entry at `from` moved to `insert`. Every entry is
/// copied out of `src` rather than borrowed from it: the caller's strings live
/// in the config's reload arena, and this list is freed entry by entry with
/// `gpa` after that arena is gone.
///
/// null when the list cannot answer at all — `from` is past its end, which is
/// a drag that outlived the config that named it, and the right thing then is
/// to leave the strip alone.
pub fn moved(
    gpa: std.mem.Allocator,
    src: []const []const u8,
    from: usize,
    insert: usize,
) !?[][]const u8 {
    if (from >= src.len) return null;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    for (src, 0..) |p, i| {
        if (i == from) continue;
        const copy = try gpa.dupe(u8, p);
        errdefer gpa.free(copy);
        try list.append(gpa, copy);
    }
    const held = try gpa.dupe(u8, src[from]);
    errdefer gpa.free(held);
    // An insert past the end lands at it, which is the same thing a drop
    // past the last icon means.
    try list.insert(gpa, @min(insert, list.items.len), held);
    return @as(?[][]const u8, try list.toOwnedSlice(gpa));
}

test "pin-order: a pin moves past its neighbours, which stay in order" {
    const t = std.testing;
    const src = [_][]const u8{ "a", "b", "c", "d" };

    const fwd = (try moved(t.allocator, &src, 1, 3)).?;
    defer t.allocator.free(fwd);
    defer for (fwd) |s| t.allocator.free(s);
    try t.expectEqual(@as(usize, 4), fwd.len);
    try t.expectEqualStrings("a", fwd[0]);
    try t.expectEqualStrings("c", fwd[1]);
    try t.expectEqualStrings("d", fwd[2]);
    try t.expectEqualStrings("b", fwd[3]);

    const back = (try moved(t.allocator, &src, 3, 0)).?;
    defer t.allocator.free(back);
    defer for (back) |s| t.allocator.free(s);
    try t.expectEqualStrings("d", back[0]);
    try t.expectEqualStrings("a", back[1]);
    try t.expectEqualStrings("b", back[2]);
    try t.expectEqualStrings("c", back[3]);
}

test "pin-order: a drop where the pin started is the same list, owned" {
    const t = std.testing;
    const src = [_][]const u8{ "a", "b" };
    const same = (try moved(t.allocator, &src, 1, 1)).?;
    defer t.allocator.free(same);
    defer for (same) |s| t.allocator.free(s);
    try t.expectEqual(@as(usize, 2), same.len);
    try t.expectEqualStrings("a", same[0]);
    try t.expectEqualStrings("b", same[1]);
    // Copies, not the config's own strings: freeing them has to be legal.
    try t.expect(same[0].ptr != src[0].ptr);
    try t.expect(same[1].ptr != src[1].ptr);
}

test "pin-order: past the end of the list is not a reorder" {
    const t = std.testing;
    const src = [_][]const u8{"a"};
    try t.expect((try moved(t.allocator, &src, 1, 0)) == null);
    try t.expect((try moved(t.allocator, &.{}, 0, 0)) == null);

    // An insert past the last icon lands on the last one.
    const single = (try moved(t.allocator, &src, 0, 9)).?;
    defer t.allocator.free(single);
    defer for (single) |s| t.allocator.free(s);
    try t.expectEqual(@as(usize, 1), single.len);
    try t.expectEqualStrings("a", single[0]);
}
