const std = @import("std");
const app_mod = @import("app.zig");
const widget_defaults = @import("widget_defaults.zig");
const island_specs = @import("../../desktop_shell/dock/island_specs.zig");

pub const Bar = enum { dock, taskbar };

/// Sidebar tab id -> widget bar, or null when the tab owns no sections.
pub fn barForTab(tab: i32) ?Bar {
    return switch (tab) {
        0 => .dock,
        11 => .taskbar,
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
    };
}

fn defaultsFor(bar: Bar) struct { l: []const []const u8, c: []const []const u8, r: []const []const u8 } {
    return switch (bar) {
        .dock => .{ .l = &widget_defaults.dock_left, .c = &widget_defaults.dock_center, .r = &widget_defaults.dock_right },
        .taskbar => .{ .l = &widget_defaults.taskbar_left, .c = &widget_defaults.taskbar_center, .r = &widget_defaults.taskbar_right },
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

/// Whether `id` in column `col` is drawn as part of an island
/// (`[dock] islands`). Section specs (`@center`, …) count only for the
/// column they name.
pub fn isIslandIn(s: *const app_mod.Settings, col: usize, id: []const u8) bool {
    return island_specs.groupIndex(s.dock_island_widgets, id, island_specs.Section.fromCol(col)) != null;
}

/// Whether `id` is islanded in any column. Used where only the widget id is
/// at hand; the board's chip tests use `isIslandIn` with its column.
pub fn isIsland(s: *const app_mod.Settings, id: []const u8) bool {
    for (0..3) |col| {
        if (isIslandIn(s, col, id)) return true;
    }
    return false;
}

/// True when every widget currently in `col` is in one island group. This
/// lights the section button even for an explicit `'a+b+c'` group, not just
/// the `@col` shorthand.
pub fn isSectionIslanded(s: *const app_mod.Settings, col: usize) bool {
    const ids = slotAt(s, .dock, col);
    return island_specs.sectionIslanded(s.dock_island_widgets, ids, island_specs.Section.fromCol(col));
}

fn appendPart(alloc: std.mem.Allocator, out: *std.ArrayList(u8), part: []const u8) !void {
    if (part.len == 0) return;
    var it = std.mem.splitScalar(u8, out.items, '+');
    while (it.next()) |have| {
        if (std.mem.eql(u8, have, part)) return;
    }
    if (out.items.len > 0) try out.append(alloc, '+');
    try out.appendSlice(alloc, part);
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |have| {
        if (std.mem.eql(u8, have, id)) return true;
    }
    return false;
}

/// Rebuild `spec` without `id`. A matching section tag is expanded to the
/// rest of that section, so taking one widget out of `@center` leaves the
/// remaining center widgets linked instead of dissolving the whole island.
fn removeWidgetFromSpec(
    alloc: std.mem.Allocator,
    spec: []const u8,
    id: []const u8,
    section: island_specs.Section,
    section_ids: []const []const u8,
) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (island_specs.Section.fromTag(part)) |sec| {
            if (sec != section) {
                try appendPart(alloc, &out, part);
                continue;
            }
            for (section_ids) |section_id| {
                if (std.mem.eql(u8, section_id, id)) continue;
                try appendPart(alloc, &out, section_id);
            }
            continue;
        }
        if (std.mem.eql(u8, part, id)) continue;
        try appendPart(alloc, &out, part);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(alloc);
}

/// Rebuild `spec` without any widget from the section and without its
/// `@col` tag. Other sections' members stay linked.
fn removeSectionFromSpec(
    alloc: std.mem.Allocator,
    spec: []const u8,
    section: island_specs.Section,
    section_ids: []const []const u8,
) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (island_specs.Section.fromTag(part)) |sec| {
            if (sec == section) continue;
            try appendPart(alloc, &out, part);
            continue;
        }
        if (containsId(section_ids, part)) continue;
        try appendPart(alloc, &out, part);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(alloc);
}

/// Flip `id`'s island membership in column `col`. Arena-owned like every
/// other list here (abandoned buffers are released with `str_arena`
/// wholesale); returns false only on OOM — a flip always has something to
/// save.
pub fn toggleIsland(s: *app_mod.Settings, alloc: std.mem.Allocator, col: usize, id: []const u8) bool {
    const section = island_specs.Section.fromCol(col);
    const section_ids = columnsFor(s, .dock).at(col).*;
    const was_on = isIslandIn(s, col, id);
    var out: std.ArrayList([]const u8) = .empty;
    for (s.dock_island_widgets) |spec| {
        if (was_on and island_specs.specMatches(spec, id, section)) {
            const rebuilt = removeWidgetFromSpec(alloc, spec, id, section, section_ids) catch return false;
            if (rebuilt) |next| out.append(alloc, next) catch return false;
            continue;
        }
        out.append(alloc, spec) catch return false;
    }
    if (!was_on) {
        const nid = alloc.dupe(u8, id) catch return false;
        out.append(alloc, nid) catch return false;
    }
    s.dock_island_widgets = out.toOwnedSlice(alloc) catch return false;
    return true;
}

/// Toggle a whole-section island: `@left`, `@center` or `@right`. Turning it
/// on detaches those widgets from any narrower groups first, so the section
/// really is one pill; turning it off leaves every other island untouched.
pub fn toggleSectionIsland(s: *app_mod.Settings, alloc: std.mem.Allocator, col: usize) bool {
    const section = island_specs.Section.fromCol(col);
    const section_ids = columnsFor(s, .dock).at(col).*;
    const was_on = island_specs.sectionIslanded(s.dock_island_widgets, section_ids, section);
    var out: std.ArrayList([]const u8) = .empty;
    for (s.dock_island_widgets) |spec| {
        const rebuilt = removeSectionFromSpec(alloc, spec, section, section_ids) catch return false;
        if (rebuilt) |next| out.append(alloc, next) catch return false;
    }
    if (!was_on) {
        const tag = alloc.dupe(u8, section.tag()) catch return false;
        out.append(alloc, tag) catch return false;
    }
    s.dock_island_widgets = out.toOwnedSlice(alloc) catch return false;
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

    // Islands toggle in and out of the `[dock] islands` set.
    try t.expect(!isIsland(&s, "clock"));
    try t.expect(toggleIsland(&s, alloc, 0, "clock"));
    try t.expect(isIsland(&s, "clock"));
    try t.expectEqual(@as(usize, 1), s.dock_island_widgets.len);
    try t.expect(toggleIsland(&s, alloc, 0, "clock"));
    try t.expect(!isIsland(&s, "clock"));
    try t.expectEqual(@as(usize, 0), s.dock_island_widgets.len);

    var s2: app_mod.Settings = .{};
    try t.expect(resetBar(&s2, alloc, .taskbar));
    try t.expect(s2.taskbar_left_widgets.len >= 0);
}

test "widget-lists: section button islands the whole column" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var s: app_mod.Settings = .{};

    s.dock_left_widgets = try dupeList(alloc, &.{ "smenu", "media" });
    s.dock_center_widgets = try dupeList(alloc, &.{ "clock", "weather" });
    s.dock_right_widgets = try dupeList(alloc, &.{"trash"});

    // One click makes all of CENTER one linked island.
    try t.expect(toggleSectionIsland(&s, alloc, 1));
    try t.expectEqual(@as(usize, 1), s.dock_island_widgets.len);
    try t.expectEqualStrings("@center", s.dock_island_widgets[0]);
    try t.expect(isSectionIslanded(&s, 1));
    try t.expect(isIslandIn(&s, 1, "clock"));
    try t.expect(isIslandIn(&s, 1, "weather"));
    try t.expect(!isIslandIn(&s, 0, "smenu"));

    // Taking one widget out leaves the rest linked, not the whole section on.
    try t.expect(toggleIsland(&s, alloc, 1, "clock"));
    try t.expect(!isIslandIn(&s, 1, "clock"));
    try t.expect(isIslandIn(&s, 1, "weather"));
    try t.expect(!isSectionIslanded(&s, 1));
    try t.expectEqualStrings("weather", s.dock_island_widgets[0]);

    // The section button folds it back into one group.
    try t.expect(toggleSectionIsland(&s, alloc, 1));
    try t.expect(isSectionIslanded(&s, 1));
    try t.expectEqual(@as(usize, 1), s.dock_island_widgets.len);
    try t.expectEqualStrings("@center", s.dock_island_widgets[0]);

    // Turning it off clears the section and leaves other sections alone.
    try t.expect(toggleSectionIsland(&s, alloc, 0));
    try t.expect(isSectionIslanded(&s, 0));
    try t.expect(toggleSectionIsland(&s, alloc, 1));
    try t.expect(!isSectionIslanded(&s, 1));
    try t.expectEqual(@as(usize, 1), s.dock_island_widgets.len);
    try t.expectEqualStrings("@left", s.dock_island_widgets[0]);
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
