//! Reading the `ext-workspace-v1` tables back out: the list the taskbar draws,
//! the list one output draws, and the handle a jump should reach.
//!
//! Nothing here touches a proxy, so the whole surface is fixture testable. The
//! tables themselves are `ext_workspace_state.zig`; the protocol binding is
//! `ext_workspace.zig`.

const std = @import("std");
const desk = @import("desk.zig");
const st = @import("ext_workspace_state.zig");
const Tables = st.Tables;
const Ws = st.Ws;
const Output = st.Output;

/// Which of the three ways of finding a workspace to try.
const Match = enum { exact, by_id, by_coord };

/// The workspaces the taskbar lists, grouped workspaces first, sorted by
/// coordinates and numbered from 1. The caller owns the slice.
pub fn allRegions(tables: *Tables) ![]desk.Region {
    var out: std.ArrayList(desk.Region) = .empty;
    errdefer {
        desk.freeRegionElems(tables.alloc, out.items);
        out.deinit(tables.alloc);
    }
    var seen: std.ArrayList(Ws) = .empty;
    defer seen.deinit(tables.alloc);

    // Workspaces a group claimed first, in group order, so a region with no
    // coordinates still keeps the group's place next to its neighbours.
    for (tables.groups.items) |g| {
        for (g.ws.items) |w| {
            if (hasPtr(Ws, seen.items, w)) continue;
            const region = tables.regions.get(w) orelse continue;
            if (region.name.len == 0) continue;
            try out.append(tables.alloc, try desk.dupRegion(tables.alloc, region));
            try seen.append(tables.alloc, w);
        }
    }

    // Then everything nobody claimed. Unnamed regions never reach a taskbar,
    // in either pass.
    var it = tables.regions.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.name.len == 0) continue;
        if (hasPtr(Ws, seen.items, e.key_ptr.*)) continue;
        try out.append(tables.alloc, try desk.dupRegion(tables.alloc, e.value_ptr.*));
    }

    sortAndIndex(&out);
    return out.toOwnedSlice(tables.alloc);
}

/// `allRegions` narrowed to the groups containing `output`. A null output is a
/// place no group can contain, so the answer is the empty list rather than
/// everything. Handles are not deduplicated: a workspace in two groups on that
/// output appears once per group.
pub fn regionsOnOutput(tables: *Tables, output: ?Output) ![]desk.Region {
    const o = output orelse return try tables.alloc.alloc(desk.Region, 0);

    var out: std.ArrayList(desk.Region) = .empty;
    errdefer {
        desk.freeRegionElems(tables.alloc, out.items);
        out.deinit(tables.alloc);
    }

    for (tables.groups.items) |g| {
        if (!hasPtr(Output, g.outs.items, o)) continue;
        for (g.ws.items) |w| {
            const region = tables.regions.get(w) orelse continue;
            if (region.name.len == 0) continue;
            try out.append(tables.alloc, try desk.dupRegion(tables.alloc, region));
        }
    }

    sortAndIndex(&out);
    return out.toOwnedSlice(tables.alloc);
}

pub fn handleForId(tables: *Tables, id: []const u8) ?Ws {
    var it = tables.regions.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.id, id)) return e.key_ptr.*;
    }
    return null;
}

pub fn handleOnOutputForId(tables: *Tables, output: Output, id: []const u8) ?Ws {
    for (tables.groups.items) |*g| {
        if (!hasPtr(Output, g.outs.items, output)) continue;
        for (g.ws.items) |w| {
            const region = tables.regions.get(w) orelse continue;
            if (std.mem.eql(u8, region.id, id)) return w;
        }
    }
    return null;
}

/// The way the overview re-finds a workspace it only knows by shape: an exact
/// id+name+coordinates, then the id, then whatever the first coordinate was.
/// Per group, so a workspace the output actually holds always beats one that
/// merely sorts the same.
pub fn handleOnOutputForRegion(tables: *Tables, output: Output, ws: desk.Region) ?Ws {
    for (tables.groups.items) |*g| {
        if (!hasPtr(Output, g.outs.items, output)) continue;
        if (matchInGroup(tables, g, ws, .exact)) |w| return w;
        if (matchInGroup(tables, g, ws, .by_id)) |w| return w;
        if (matchInGroup(tables, g, ws, .by_coord)) |w| return w;
    }
    return null;
}

fn matchInGroup(tables: *Tables, g: *const st.Group, ws: desk.Region, how: Match) ?Ws {
    for (g.ws.items) |w| {
        const c = tables.regions.get(w) orelse continue;
        const hit = switch (how) {
            .exact => std.mem.eql(u8, c.id, ws.id) and
                std.mem.eql(u8, c.name, ws.name) and
                coordsEqual(trimZeros(c.coordinates), trimZeros(ws.coordinates)),
            .by_id => ws.id.len != 0 and std.mem.eql(u8, c.id, ws.id),
            .by_coord => blk: {
                const want = trimZeros(ws.coordinates);
                const have = trimZeros(c.coordinates);
                break :blk want.len != 0 and have.len != 0 and want[0] == have[0];
            },
        };
        if (hit) return w;
    }
    return null;
}

// Plain helpers

fn hasPtr(comptime T: type, list: []const T, needle: T) bool {
    for (list) |v| if (v == needle) return true;
    return false;
}

/// Trailing zeros are padding the protocol writes for matrix depth, not part
/// of the position.
fn trimZeros(c: []const u32) []const u32 {
    var end = c.len;
    while (end > 0 and c[end - 1] == 0) end -= 1;
    return c[0..end];
}

fn coordsEqual(a: []const u32, b: []const u32) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}

/// Lexicographic comparison over `u32` coordinate vectors: element by
/// element, shorter-is-less on a shared prefix.
fn coordsLess(a: []const u32, b: []const u32) bool {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.len < b.len;
}

fn regionLess(_: void, a: desk.Region, b: desk.Region) bool {
    return coordsLess(a.coordinates, b.coordinates);
}

fn sortAndIndex(list: *std.ArrayList(desk.Region)) void {
    std.mem.sort(desk.Region, list.items, {}, regionLess);
    var idx: u32 = 1;
    for (list.items) |*r| {
        r.index = idx;
        idx += 1;
    }
}

// Tests

const t = std.testing;

test "ext-workspace-query: allRegions prefers the groups, drops the unnamed, then sorts and indexes" {
    var tab = Tables.init(t.allocator);
    defer tab.deinit();
    const f = try st.fixture(&tab);

    const regions = try allRegions(&tab);
    defer desk.freeRegionList(t.allocator, regions);

    // Coordinates 1,2,3,4 in order — the two group claims (1, 2) and the two
    // standalones (3, 4) all survive, the unnamed one does not.
    try t.expectEqual(@as(usize, 4), regions.len);
    const expect_ids = [_][]const u8{ "1", "2", "3", "4" };
    for (expect_ids, 0..) |want, i| {
        try t.expectEqualStrings(want, regions[i].id);
        try t.expectEqual(@as(u32, @intCast(i + 1)), regions[i].index);
    }

    // The sort is by coordinates, not by discovery: hand the same set a workspace
    // whose coordinates sort earlier than anything in a group.
    tab.setCoordinates(f.w4, &.{ 0, 5 });
    const reordered = try allRegions(&tab);
    defer desk.freeRegionList(t.allocator, reordered);
    try t.expectEqualStrings("4", reordered[0].id);
    try t.expectEqual(@as(u32, 1), reordered[0].index);
}

test "ext-workspace-query: regionsOnOutput walks only the groups on that output" {
    var tab = Tables.init(t.allocator);
    defer tab.deinit();
    const f = try st.fixture(&tab);

    const on_out1 = try regionsOnOutput(&tab, f.out1);
    defer desk.freeRegionList(t.allocator, on_out1);
    // w4 is in no group, wn has no name, so neither is reachable from an output.
    try t.expectEqual(@as(usize, 2), on_out1.len);
    try t.expectEqualStrings("one", on_out1[0].name);
    try t.expectEqualStrings("two", on_out1[1].name);

    const nowhere = try regionsOnOutput(&tab, f.out2);
    defer desk.freeRegionList(t.allocator, nowhere);
    try t.expectEqual(@as(usize, 0), nowhere.len);

    // No group contains a null output either, so the answer is
    // the empty list rather than "everything".
    const unset = try regionsOnOutput(&tab, null);
    defer desk.freeRegionList(t.allocator, unset);
    try t.expectEqual(@as(usize, 0), unset.len);
}

test "ext-workspace-query: jump matching tries exact, then id, then coordinates" {
    var tab = Tables.init(t.allocator);
    defer tab.deinit();
    const f = try st.fixture(&tab);

    const exact = desk.Region{ .id = "2", .name = "two", .coordinates = &.{ 2, 0, 0 } };
    try t.expect(handleOnOutputForRegion(&tab, f.out1, exact) == f.w2);

    // Id alone is enough when the name moved: the overview's cached region is
    // only as fresh as its last refresh.
    const stale = desk.Region{ .id = "1", .name = "renamed", .coordinates = &.{7} };
    try t.expect(handleOnOutputForRegion(&tab, f.out1, stale) == f.w1);

    // No id and no name — the workspace the overview only knows as "the ninth".
    // It is grouped, unlike w3, so the output narrows it down and the first
    // coordinate still gets there even though it never got a name.
    const byCoord = desk.Region{ .id = "", .name = "", .coordinates = &.{ 9, 9, 9 } };
    try t.expect(handleOnOutputForRegion(&tab, f.out1, byCoord) == f.wn);
    try t.expect(tab.regionOf(f.wn).?.name.len == 0);

    // Nothing to match on, and nothing with that first coordinate.
    const miss = desk.Region{ .id = "", .name = "", .coordinates = &.{77} };
    try t.expect(handleOnOutputForRegion(&tab, f.out1, miss) == null);

    // Trailing zeros are padding, so {1,0,0} and {1} are the same workspace.
    const padded = desk.Region{ .id = "", .name = "", .coordinates = &.{ 1, 0, 0 } };
    try t.expect(handleOnOutputForRegion(&tab, f.out1, padded) == f.w1);

    // An output no group contains never matches, however good the region is.
    try t.expect(handleOnOutputForRegion(&tab, f.out2, exact) == null);
    try t.expect(handleOnOutputForId(&tab, f.out2, "2") == null);
    try t.expect(handleOnOutputForId(&tab, f.out1, "2") == f.w2);
    try t.expect(handleForId(&tab, "3") == f.w3);
    try t.expect(handleForId(&tab, "nope") == null);
}
