//! Pin lists for layout and drag-time reorder.
//! the layout pass reads, and the drag-time reorder that builds the preview
//! order.
//!
//! Identity here is the normalized app id (`paths.sameAppId`): the drag
//! key is normalized at press, and the reorder below works on positions, so
//! spelling differences between the config and the hit never matter.

const std = @import("std");
const paths = @import("../common/paths.zig");

pub const settings_app_id = "event-horizon-settings";

/// The redesigned `settings` binary's window carries its own app id —
/// skipped here too, so it never appears as a pin or running chip: both
/// settings variants are shell components with dedicated widgets.
pub const rail_settings_app_id = "event-horizon-rail-settings";

fn isSkipped(raw: []const u8, alloc: std.mem.Allocator) bool {
    const n = paths.normalizeAppId(alloc, raw) catch return true;
    defer alloc.free(n);
    return std.mem.eql(u8, n, "unknown") or std.mem.eql(u8, n, settings_app_id) or
        std.mem.eql(u8, n, rail_settings_app_id);
}

/// The pin list the layout pass reads: the drag preview while dragging,
/// the live settings otherwise. Pure borrow — no allocation.
pub fn sourceForLayout(
    dragging: bool,
    snapshot: []const []const u8,
    paint_order: []const []const u8,
    live: []const []const u8,
) []const []const u8 {
    if (dragging and snapshot.len > 0) {
        if (paint_order.len > 0) return paint_order;
        return snapshot;
    }
    return live;
}

/// Rebuild the drag preview order: move the entry whose normalized id is
/// `drag_key` to `insert_idx` (in the *reduced* list, i.e. with the dragged
/// entry removed, with the insert index clamped). Entries that normalize to
/// `unknown`/settings keep their raw slots: only the reorderable strings
/// move, the rest stay pinned in place by raw index.
///
/// Returns an owned list of owned strings, or null when there is nothing to
/// reorder. The caller frees each entry, then the list.
pub fn rebuildPaintOrder(
    gpa: std.mem.Allocator,
    snapshot: []const []const u8,
    drag_key_norm: []const u8,
    insert_idx: i32,
) !?[][]const u8 {
    if (snapshot.len == 0 or drag_key_norm.len == 0) return null;
    if (insert_idx < 0) {
        var out = try gpa.alloc([]const u8, snapshot.len);
        errdefer gpa.free(out);
        for (snapshot, 0..) |p, i| out[i] = try gpa.dupe(u8, p);
        return out;
    }
    // Raw indices of reorderable pins.
    var raw_idx: std.ArrayList(usize) = .empty;
    defer raw_idx.deinit(gpa);
    for (snapshot, 0..) |p, i| {
        if (isSkipped(p, gpa)) continue;
        try raw_idx.append(gpa, i);
    }
    if (raw_idx.items.len <= 1) {
        var out = try gpa.alloc([]const u8, snapshot.len);
        errdefer gpa.free(out);
        for (snapshot, 0..) |p, i| out[i] = try gpa.dupe(u8, p);
        return out;
    }
    // Position of the dragged pin inside the reorderable subsequence.
    var str_cur: ?usize = null;
    for (raw_idx.items, 0..) |ri, k| {
        const n = paths.normalizeAppId(gpa, snapshot[ri]) catch continue;
        defer gpa.free(n);
        if (std.mem.eql(u8, n, drag_key_norm)) {
            str_cur = k;
            break;
        }
    }
    const cur = str_cur orelse {
        var out = try gpa.alloc([]const u8, snapshot.len);
        errdefer gpa.free(out);
        for (snapshot, 0..) |p, i| out[i] = try gpa.dupe(u8, p);
        return out;
    };
    // Move within the reorderable strings.
    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(gpa);
    for (raw_idx.items) |ri| try strings.append(gpa, snapshot[ri]);
    const reduced: i32 = @intCast(strings.items.len - 1);
    const at: usize = @intCast(std.math.clamp(insert_idx, 0, reduced));
    const moved = strings.orderedRemove(cur);
    strings.insert(gpa, at, moved) catch return error.OutOfMemory;
    // Write back into raw slots.
    var out = try gpa.alloc([]const u8, snapshot.len);
    errdefer gpa.free(out);
    for (snapshot, 0..) |p, i| out[i] = try gpa.dupe(u8, p);
    errdefer {
        for (out) |s| gpa.free(s);
        gpa.free(out);
    }
    for (raw_idx.items, 0..) |ri, k| {
        gpa.free(out[ri]);
        out[ri] = try gpa.dupe(u8, strings.items[k]);
    }
    return out;
}

pub fn freeOrder(gpa: std.mem.Allocator, order: [][]const u8) void {
    for (order) |s| gpa.free(s);
    gpa.free(order);
}

test "taskbar-pinned: layout source prefers the drag preview" {
    const t = std.testing;
    const snap = [_][]const u8{ "a", "b" };
    const live = [_][]const u8{"z"};
    try t.expectEqualSlices([]const u8, &[_][]const u8{ "a", "b" }, sourceForLayout(true, &snap, &.{}, &live));
    try t.expectEqualSlices([]const u8, &[_][]const u8{"z"}, sourceForLayout(false, &snap, &snap, &live));
}

test "taskbar-pinned: reorder moves the dragged pin" {
    const t = std.testing;
    const snap = [_][]const u8{ "firefox", "kitty", "steam" };
    const fwd = (try rebuildPaintOrder(t.allocator, &snap, "kitty", 2)).?;
    defer freeOrder(t.allocator, fwd);
    try t.expectEqualStrings("firefox", fwd[0]);
    try t.expectEqualStrings("steam", fwd[1]);
    try t.expectEqualStrings("kitty", fwd[2]);
    const back = (try rebuildPaintOrder(t.allocator, &snap, "steam", 0)).?;
    defer freeOrder(t.allocator, back);
    try t.expectEqualStrings("steam", back[0]);
}

test "taskbar-pinned: skipped entries hold their raw slots" {
    const t = std.testing;
    const snap = [_][]const u8{ "firefox", "event-horizon-settings", "kitty" };
    const out = (try rebuildPaintOrder(t.allocator, &snap, "kitty", 0)).?;
    defer freeOrder(t.allocator, out);
    try t.expectEqualStrings("kitty", out[0]);
    try t.expectEqualStrings("event-horizon-settings", out[1]);
    try t.expectEqualStrings("firefox", out[2]);
}
