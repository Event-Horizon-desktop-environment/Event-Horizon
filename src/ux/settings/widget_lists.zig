const std = @import("std");
const app_mod = @import("app.zig");
const widget_defaults = @import("widget_defaults.zig");

pub const Bar = enum { dock, taskbar, panel };

/// Sidebar tab id -> widget bar, or null when the tab owns no sections.
pub fn barForTab(tab: i32) ?Bar {
    return switch (tab) {
        0 => .dock,
        11 => .taskbar,
        1 => .panel,
        else => null,
    };
}

/// Mutable views onto one bar's three section lists. The slices themselves
/// are arena-owned; replacing one (append/remove/reset) swaps the field.
pub const Columns = struct {
    left: *[][]const u8,
    center: *[][]const u8,
    right: *[][]const u8,

    pub fn at(self: Columns, col: usize) *[][]const u8 {
        return switch (col) {
            0 => self.left,
            1 => self.center,
            else => self.right,
        };
    }
};

pub fn columnsFor(s: *app_mod.Settings, bar: Bar) Columns {
    return switch (bar) {
        .dock => .{
            .left = &s.dock_left_widgets,
            .center = &s.dock_center_widgets,
            .right = &s.dock_right_widgets,
        },
        .taskbar => .{
            .left = &s.taskbar_left_widgets,
            .center = &s.taskbar_center_widgets,
            .right = &s.taskbar_right_widgets,
        },
        .panel => .{
            .left = &s.panel_left_widgets,
            .center = &s.panel_center_widgets,
            .right = &s.panel_right_widgets,
        },
    };
}

fn defaultsFor(bar: Bar) struct { l: []const []const u8, c: []const []const u8, r: []const []const u8 } {
    return switch (bar) {
        .dock => .{ .l = &widget_defaults.dock_left, .c = &widget_defaults.dock_center, .r = &widget_defaults.dock_right },
        .taskbar => .{ .l = &widget_defaults.taskbar_left, .c = &widget_defaults.taskbar_center, .r = &widget_defaults.taskbar_right },
        .panel => .{ .l = &widget_defaults.panel_left, .c = &widget_defaults.panel_center, .r = &widget_defaults.panel_right },
    };
}

fn dupeList(alloc: std.mem.Allocator, src: []const []const u8) ![][]const u8 {
    const out = try alloc.alloc([]const u8, src.len);
    for (src, 0..) |id, i| out[i] = try alloc.dupe(u8, id);
    return out;
}

/// One bar's three section lists as an indexable tuple.
fn slotsFor(s: *const app_mod.Settings, bar: Bar) [3][]const []const u8 {
    return switch (bar) {
        .dock => .{ s.dock_left_widgets, s.dock_center_widgets, s.dock_right_widgets },
        .taskbar => .{ s.taskbar_left_widgets, s.taskbar_center_widgets, s.taskbar_right_widgets },
        .panel => .{ s.panel_left_widgets, s.panel_center_widgets, s.panel_right_widgets },
    };
}

fn slotAt(s: *const app_mod.Settings, bar: Bar, col: usize) []const []const u8 {
    const all = slotsFor(s, bar);
    return switch (col) {
        0 => all[0],
        1 => all[1],
        else => all[2],
    };
}

/// Whether `id` is already placed anywhere in `bar`.
pub fn hasId(s: *const app_mod.Settings, bar: Bar, id: []const u8) bool {
    for (slotsFor(s, bar)) |slot| {
        for (slot) |have| {
            if (std.mem.eql(u8, have, id)) return true;
        }
    }
    return false;
}

/// The widget id at (col, idx), or null when out of range.
pub fn idAt(s: *const app_mod.Settings, bar: Bar, col: usize, idx: usize) ?[]const u8 {
    const slot = slotAt(s, bar, col);
    if (idx >= slot.len) return null;
    return slot[idx];
}

/// Remove the widget at (col, idx). Out of range is a no-op returning false.
///
/// The old slice buffer is left in the arena (all these lists are
/// `str_arena`-owned and released wholesale); only ever call with an arena.
pub fn removeAt(s: *app_mod.Settings, alloc: std.mem.Allocator, bar: Bar, col: usize, idx: usize) bool {
    const cols = columnsFor(s, bar);
    const slot = cols.at(col);
    if (idx >= slot.*.len) return false;
    var out: std.ArrayList([]const u8) = .empty;
    for (slot.*, 0..) |id, i| {
        if (i == idx) continue;
        out.append(alloc, id) catch return false;
    }
    slot.* = out.toOwnedSlice(alloc) catch return false;
    return true;
}

/// Append `id` to a column unless it is already there. Returns false when
/// nothing changed (duplicate or OOM — both mean "do not save").
pub fn appendUnique(s: *app_mod.Settings, alloc: std.mem.Allocator, bar: Bar, col: usize, id: []const u8) bool {
    const cols = columnsFor(s, bar);
    const slot = cols.at(col);
    for (slot.*) |have| {
        if (std.mem.eql(u8, have, id)) return false;
    }
    const nid = alloc.dupe(u8, id) catch return false;
    errdefer alloc.free(nid);
    var out: std.ArrayList([]const u8) = .empty;
    out.appendSlice(alloc, slot.*) catch return false;
    out.append(alloc, nid) catch return false;
    slot.* = out.toOwnedSlice(alloc) catch return false;
    return true;
}

/// Move the widget at (src_col, src_idx) to (dst_col, insert_before).
/// Same column = reorder; different column = move between zones. The moved
/// id string is reused in place (arena-owned, like every other mutator).
/// `insert_before` is in erased space (the source row already removed), so
/// callers compute it over the rows that stay — see
/// `ui_widgets.widgetDropTarget`. A same-column drop that lands back on its
/// own slot is a no-op returning false (no save follows).
pub fn moveItem(s: *app_mod.Settings, alloc: std.mem.Allocator, bar: Bar, src_col: usize, src_idx: usize, dst_col: usize, insert_before: usize) bool {
    if (src_col > 2 or dst_col > 2) return false;
    const cols = columnsFor(s, bar);
    const src = cols.at(src_col);
    if (src_idx >= src.*.len) return false;
    const id = src.*[src_idx];
    if (src_col == dst_col) {
        var dst = insert_before;
        if (dst > src.*.len - 1) dst = src.*.len - 1;
        if (dst == src_idx) return false;
        var out: std.ArrayList([]const u8) = .empty;
        for (src.*, 0..) |have, i| {
            if (out.items.len == dst) out.append(alloc, id) catch return false;
            if (i == src_idx) continue;
            out.append(alloc, have) catch return false;
        }
        if (out.items.len == dst) out.append(alloc, id) catch return false;
        src.* = out.toOwnedSlice(alloc) catch return false;
        return true;
    }
    var src_out: std.ArrayList([]const u8) = .empty;
    for (src.*, 0..) |have, i| {
        if (i == src_idx) continue;
        src_out.append(alloc, have) catch return false;
    }
    const dstp = cols.at(dst_col);
    var dst = insert_before;
    if (dst > dstp.*.len) dst = dstp.*.len;
    var dst_out: std.ArrayList([]const u8) = .empty;
    dst_out.appendSlice(alloc, dstp.*[0..dst]) catch return false;
    dst_out.append(alloc, id) catch return false;
    dst_out.appendSlice(alloc, dstp.*[dst..]) catch return false;
    src.* = src_out.toOwnedSlice(alloc) catch return false;
    dstp.* = dst_out.toOwnedSlice(alloc) catch return false;
    return true;
}

/// Restore a bar's three sections to the visible defaults.
pub fn resetBar(s: *app_mod.Settings, alloc: std.mem.Allocator, bar: Bar) bool {
    const d = defaultsFor(bar);
    const cols = columnsFor(s, bar);
    cols.left.* = dupeList(alloc, d.l) catch return false;
    cols.center.* = dupeList(alloc, d.c) catch return false;
    cols.right.* = dupeList(alloc, d.r) catch return false;
    return true;
}

test "widget-lists: remove, append-dedup and reset" {
    const t = std.testing;
    // Arena mirrors real use (`Win.str_arena` owns every list wholesale, so
    // abandoned slice buffers on edit are released with everything else).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var s: app_mod.Settings = .{};

    s.dock_left_widgets = try dupeList(alloc, &.{ "smenu", "media" });
    try t.expect(removeAt(&s, alloc, .dock, 0, 0));
    try t.expectEqual(@as(usize, 1), s.dock_left_widgets.len);
    try t.expectEqualStrings("media", s.dock_left_widgets[0]);
    try t.expect(!removeAt(&s, alloc, .dock, 0, 9));
    // Duplicates never land twice.
    try t.expect(!appendUnique(&s, alloc, .dock, 0, "media"));
    try t.expect(appendUnique(&s, alloc, .dock, 0, "clock"));
    try t.expectEqual(@as(usize, 2), s.dock_left_widgets.len);

    var s2: app_mod.Settings = .{};
    try t.expect(resetBar(&s2, alloc, .panel));
    try t.expectEqualStrings("workspaces", s2.panel_left_widgets[0]);
    try t.expectEqualStrings("clock", s2.panel_center_widgets[0]);
}

test "widget-lists: moveItem reorder and cross-zone" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var s: app_mod.Settings = .{};

    s.dock_left_widgets = try dupeList(alloc, &.{ "smenu", "media", "clock" });
    s.dock_center_widgets = try dupeList(alloc, &.{"workspaces"});
    // Reorder within left: clock (2) to the front (erased-space 0).
    try t.expect(moveItem(&s, alloc, .dock, 0, 2, 0, 0));
    try t.expectEqualStrings("clock", s.dock_left_widgets[0]);
    try t.expectEqualStrings("smenu", s.dock_left_widgets[1]);
    try t.expectEqualStrings("media", s.dock_left_widgets[2]);
    // A drop back on its own slot is a no-op (no save follows).
    try t.expect(!moveItem(&s, alloc, .dock, 0, 0, 0, 0));
    try t.expect(!moveItem(&s, alloc, .dock, 0, 2, 0, 9));
    // Cross-zone: media (left 2) to the front of center.
    try t.expect(moveItem(&s, alloc, .dock, 0, 2, 1, 0));
    try t.expectEqual(@as(usize, 2), s.dock_left_widgets.len);
    try t.expectEqualStrings("media", s.dock_center_widgets[0]);
    try t.expectEqualStrings("workspaces", s.dock_center_widgets[1]);
    // Past-the-end clamps to an append, across bars too.
    try t.expect(moveItem(&s, alloc, .dock, 1, 0, 2, 99));
    try t.expectEqual(@as(usize, 1), s.dock_center_widgets.len);
    try t.expectEqualStrings("media", s.dock_right_widgets[0]);
    // Out of range is a no-op.
    try t.expect(!moveItem(&s, alloc, .dock, 0, 9, 1, 0));
    try t.expect(!moveItem(&s, alloc, .dock, 3, 0, 1, 0));
    try t.expect(!moveItem(&s, alloc, .dock, 0, 0, 3, 0));
}
