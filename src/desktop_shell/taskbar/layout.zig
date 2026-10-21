//! Taskbar strip layout: slot positions, app grouping, and the shared
//! measure helpers (`slots.zig`) re-exported where the bar sizes itself.
//!
//! `layoutSlots` keeps the legacy coarsely-clamped row (existing callers and
//! tests); `layoutRow` is the gap-aware pass the paint code sizes from.

const std = @import("std");
pub const slots = @import("slots.zig");

pub const Slot = struct {
    x: i32,
    w: i32,
    window_id: u64,
};

pub fn layoutSlots(alloc: std.mem.Allocator, count: usize, total_w: i32, min_slot: i32, max_slot: i32, x0: i32) ![]Slot {
    var out: std.ArrayList(Slot) = .empty;
    errdefer out.deinit(alloc);
    if (count == 0) return out.toOwnedSlice(alloc);
    var w = @divTrunc(total_w, @as(i32, @intCast(count)));
    w = @max(min_slot, @min(max_slot, w));
    var x = x0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.append(alloc, .{ .x = x, .w = w, .window_id = 0 });
        x += w;
    }
    return out.toOwnedSlice(alloc);
}

/// Gap-aware row: each entry `widths[i]` wide, `gap` between neighbours
/// (tray/app pill rules via `slots.gapBetween` when kinds are known —
/// here the plain uniform gap, matching the dock's strip).
pub fn layoutRow(alloc: std.mem.Allocator, widths: []const f64, gap: f64, x0: f64) ![]Slot {
    var out: std.ArrayList(Slot) = .empty;
    errdefer out.deinit(alloc);
    var x = x0;
    for (widths, 0..) |w, i| {
        try out.append(alloc, .{
            .x = @intFromFloat(@round(x)),
            .w = @intFromFloat(@round(w)),
            .window_id = @intCast(i),
        });
        x += w + (if (i + 1 < widths.len) gap else 0);
    }
    return out.toOwnedSlice(alloc);
}

pub fn rowWidth(widths: []const f64, gap: f64) f64 {
    if (widths.len == 0) return 0;
    var tw: f64 = 0;
    for (widths) |w| tw += w;
    return tw + gap * @as(f64, @floatFromInt(widths.len - 1));
}

pub const Group = struct {
    app_id: []const u8,
    ids: []u64,
};

pub fn groupByApp(alloc: std.mem.Allocator, ids: []const u64, apps: []const []const u8) ![]Group {
    var out: std.ArrayList(Group) = .empty;
    errdefer out.deinit(alloc);
    for (ids, 0..) |id, i| {
        const app = if (i < apps.len) apps[i] else "";
        var found = false;
        for (out.items) |*g| {
            if (std.mem.eql(u8, g.app_id, app)) {
                g.ids = try joinId(alloc, g.ids, id);
                found = true;
                break;
            }
        }
        if (!found) {
            const one = try alloc.alloc(u64, 1);
            one[0] = id;
            try out.append(alloc, .{ .app_id = app, .ids = one });
        }
    }
    return out.toOwnedSlice(alloc);
}

fn joinId(alloc: std.mem.Allocator, old: []u64, id: u64) ![]u64 {
    const n = try alloc.alloc(u64, old.len + 1);
    @memcpy(n[0..old.len], old);
    n[old.len] = id;
    alloc.free(old);
    return n;
}

pub fn freeGroups(alloc: std.mem.Allocator, groups: []Group) void {
    for (groups) |g| alloc.free(g.ids);
    alloc.free(groups);
}

pub fn slotAt(slots_in: []const Slot, px: i32) ?usize {
    for (slots_in, 0..) |s, i| {
        if (px >= s.x and px < s.x + s.w) return i;
    }
    return null;
}

test "taskbar: slots clamp + grouping" {
    const t = std.testing;
    const sslots = try layoutSlots(t.allocator, 4, 800, 60, 200, 0);
    defer t.allocator.free(sslots);
    try t.expectEqual(@as(i32, 200), sslots[0].w);
    const narrow = try layoutSlots(t.allocator, 20, 800, 60, 200, 0);
    defer t.allocator.free(narrow);
    try t.expectEqual(@as(i32, 60), narrow[0].w);
    const groups = try groupByApp(t.allocator, &[_]u64{ 1, 2, 3 }, &[_][]const u8{ "a", "b", "a" });
    defer freeGroups(t.allocator, groups);
    try t.expectEqual(@as(usize, 2), groups.len);
    try t.expectEqual(@as(usize, 2), groups[0].ids.len);
}

test "taskbar-layout: gap-aware row and hit" {
    const t = std.testing;
    const row = try layoutRow(t.allocator, &[_]f64{ 40, 60, 40 }, 8, 10);
    defer t.allocator.free(row);
    try t.expectEqual(@as(i32, 10), row[0].x);
    try t.expectEqual(@as(i32, 58), row[1].x);
    try t.expectEqual(@as(f64, 156), rowWidth(&[_]f64{ 40, 60, 40 }, 8));
    try t.expectEqual(@as(usize, 1), slotAt(row, 60).?);
    try t.expect(slotAt(row, 500) == null);
}
