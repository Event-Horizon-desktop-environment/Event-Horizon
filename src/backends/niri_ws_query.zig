//! niri workspace queries: the tables back out into the shapes the interface
//! hands to the shell (`desk.Region`, `desk.AppMap`, `desk.Win`).
//!
//! Query side: everything here allocates
//! owned results, because the tables it reads can be replaced by the next
//! event line the moment a query returns.
//!
//! Two deliberate differences:
//! candidate order comes from an insertion-ordered map, and `windowsOnDesk` therefore lists windows
//! in the order niri first told us about them instead of in whatever order the
//! platform hash picked that day.

const std = @import("std");
const desk = @import("desk.zig");
const st = @import("niri_ws_state.zig");
const events = @import("niri_ws_events.zig");

/// The alias every signature below is written against: the tables live in the
/// state module and each query takes them by const pointer.
const Tables = st.Tables;

/// The workspaces a region list may claim against, filtered to one output when
/// a name was given, then ordered by position and id. Pointers alias the table,
/// so they stay valid only while the table is not mutated.
pub fn sortedWorkspaceCandidates(
    tb: *const Tables,
    out_name: []const u8,
) ![]*const st.WsState {
    const alloc = tb.alloc;
    var cand: std.ArrayList(*const st.WsState) = .empty;
    errdefer cand.deinit(alloc);
    var it = tb.workspaces.iterator();
    while (it.next()) |e| {
        if (out_name.len != 0 and !std.mem.eql(u8, e.value_ptr.output, out_name)) continue;
        try cand.append(alloc, e.value_ptr);
    }
    std.mem.sort(*const st.WsState, cand.items, {}, byPositionThenId);
    return cand.toOwnedSlice(alloc);
}

fn byPositionThenId(_: void, a: *const st.WsState, b: *const st.WsState) bool {
    if (a.idx != b.idx) return a.idx < b.idx;
    return a.id < b.id;
}

/// Claims the candidate this region describes, in three passes:
/// exact niri id, then workspace name, then leading position. Each pass only
/// claims an id nobody has taken yet, so two regions never claim one workspace
/// and a weaker match on a later pass cannot steal a row that an earlier pass
/// already skipped as busy.
pub fn claimMatching(
    cand: []const *const st.WsState,
    used: *std.AutoHashMap(u64, void),
    row: desk.Region,
    by_id: ?u64,
    by_idx: ?usize,
) !?*const st.WsState {
    if (by_id) |want| {
        for (cand) |c| {
            if (c.id != want or used.contains(c.id)) continue;
            try used.put(c.id, {});
            return c;
        }
    }
    if (row.name.len != 0) {
        for (cand) |c| {
            if (!std.mem.eql(u8, c.name, row.name) or used.contains(c.id)) continue;
            try used.put(c.id, {});
            return c;
        }
    }
    if (by_idx) |want| {
        for (cand) |c| {
            if (@as(usize, c.idx) != want or used.contains(c.id)) continue;
            try used.put(c.id, {});
            return c;
        }
    }
    return null;
}

/// Fills in `index` and `occupied` for a region list the shell already built.
/// Nothing is appended: a region that cannot be tied to a niri workspace goes
/// back to `index = 0, occupied = false`, which is how a taskbar row for a
/// workspace that has since been renamed or closed blanks out.
pub fn sync(
    tb: *const Tables,
    regions: []desk.Region,
    out_name: []const u8,
    can_connect: bool,
) !void {
    const alloc = tb.alloc;
    if (!can_connect or regions.len == 0 or tb.workspaces.count() == 0) return;

    const cand = try sortedWorkspaceCandidates(tb, out_name);
    defer alloc.free(cand);

    const matches = try alloc.alloc(?*const st.WsState, regions.len);
    defer alloc.free(matches);
    @memset(matches, null);

    var used: std.AutoHashMap(u64, void) = .init(alloc);
    defer used.deinit();

    for (regions, matches) |row, *match| {
        const id_num = st.parseUint(row.id);
        var idx_num = st.parseLeadingDigits(row.id);
        if (idx_num == null) idx_num = st.parseLeadingDigits(row.name);
        match.* = try claimMatching(cand, &used, row, id_num, idx_num);
    }

    // Second chance for the regions that claimed nothing: hand out whatever is
    // left in sorted order. Only when we were given an output to scope to —
    // with every output mixed together, guessing which leftover belongs where
    // would be worse than leaving the row blank.
    if (out_name.len != 0) {
        var cursor: usize = 0;
        for (matches) |*match| {
            if (match.* != null) continue;
            while (cursor < cand.len and used.contains(cand[cursor].id)) cursor += 1;
            if (cursor >= cand.len) break;
            match.* = cand[cursor];
            try used.put(cand[cursor].id, {});
            cursor += 1;
        }
    }

    for (regions, matches) |*region, match| {
        if (match == null) {
            region.index = 0;
            region.occupied = false;
            continue;
        }
        const hit = match.?;
        // `idx == 0` means niri has not numbered this workspace yet, so the
        // region keeps whatever position it already carried.
        if (hit.idx > 0) region.index = hit.idx;
        region.occupied = tb.occupied(hit.id);
    }
}

/// The desk keys of every candidate, in candidate order. Owned: the strings
/// come from `regionKey`, which formats a number.
pub fn deskKeys(tb: *const Tables, out_name: []const u8) ![][]const u8 {
    const alloc = tb.alloc;
    const cand = try sortedWorkspaceCandidates(tb, out_name);
    defer alloc.free(cand);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |key| alloc.free(key);
        out.deinit(alloc);
    }
    for (cand) |ws| try out.append(alloc, try st.regionKey(alloc, ws.*));
    return out.toOwnedSlice(alloc);
}

pub fn freeKeys(alloc: std.mem.Allocator, keys: [][]const u8) void {
    for (keys) |key| alloc.free(key);
    alloc.free(keys);
}

/// app ids per desk key, deduplicated within each desk and in window-table
/// order. Keys and ids are owned copies — see `desk.AppMap`.
pub fn appsByDesk(tb: *const Tables, out_name: []const u8) !desk.AppMap {
    const alloc = tb.alloc;
    var by_id = try workspaceIndex(tb, out_name);
    defer by_id.deinit();

    var result: desk.AppMap = .init(alloc);
    errdefer desk.freeAppMap(alloc, &result);

    for (tb.windows.keys(), tb.windows.values()) |_, win| {
        const ws_id = win.ws_id orelse continue;
        if (win.app_id.len == 0) continue;
        const ws = by_id.get(ws_id) orelse continue;

        const key = try st.regionKey(alloc, ws.*);
        var own_key = true;
        defer if (own_key) alloc.free(key);
        const gop = try result.getOrPut(key);
        // A new key arrives with an undefined value, so start it empty — and
        // hand the formatted key over, since from here the map frees it.
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            own_key = false;
        }
        if (hasApp(gop.value_ptr.*, win.app_id)) continue;

        const app = try alloc.dupe(u8, win.app_id);
        errdefer alloc.free(app);
        try gop.value_ptr.*.append(alloc, app);
    }
    return result;
}

fn hasApp(list: std.ArrayList([]const u8), needle: []const u8) bool {
    for (list.items) |app| {
        if (std.mem.eql(u8, app, needle)) return true;
    }
    return false;
}

/// The windows sitting on the workspaces of one output, in window-table order.
/// Rows with no workspace, with no app id, or on a workspace that is not in
/// the filtered set are skipped — they cannot be placed on a desk.
pub fn windowsOnDesk(tb: *const Tables, out_name: []const u8) ![]desk.Win {
    const alloc = tb.alloc;
    var by_id = try workspaceIndex(tb, out_name);
    defer by_id.deinit();

    var out: std.ArrayList(desk.Win) = .empty;
    errdefer {
        desk.freeWinElems(alloc, out.items);
        out.deinit(alloc);
    }

    for (tb.windows.keys(), tb.windows.values()) |wid, win| {
        const ws_id = win.ws_id orelse continue;
        if (win.app_id.len == 0) continue;
        const ws = by_id.get(ws_id) orelse continue;

        var row = desk.Win{ .x = win.x, .y = win.y };
        errdefer desk.freeWin(alloc, row);
        row.window_id = try std.fmt.allocPrint(alloc, "{d}", .{wid});
        row.desk_key = try st.regionKey(alloc, ws.*);
        row.app_id = try alloc.dupe(u8, win.app_id);
        row.title = try alloc.dupe(u8, win.title);
        try out.append(alloc, row);
    }
    return out.toOwnedSlice(alloc);
}

/// id -> the workspace it names, restricted the same way the candidate list is.
/// Built once per query because both `appsByDesk` and `windowsOnDesk` need it.
fn workspaceIndex(
    tb: *const Tables,
    out_name: []const u8,
) !std.AutoHashMap(u64, *const st.WsState) {
    var map: std.AutoHashMap(u64, *const st.WsState) = .init(tb.alloc);
    errdefer map.deinit();
    var it = tb.workspaces.iterator();
    while (it.next()) |e| {
        if (out_name.len != 0 and !std.mem.eql(u8, e.value_ptr.output, out_name)) continue;
        try map.put(e.key_ptr.*, e.value_ptr);
    }
    return map;
}

// Tests

const workspaces_doc =
    \\{"WorkspacesChanged":{"workspaces":[
    \\ {"id":1,"idx":1,"name":null,"output":"DP-1"},
    \\ {"id":5,"idx":2,"name":"dev","output":"DP-1"},
    \\ {"id":7,"idx":0,"name":null,"output":"DP-1"},
    \\ {"id":4,"idx":3,"name":"web","output":"DP-1"},
    \\ {"id":3,"idx":1,"name":null,"output":"HDMI-1"}
    \\]}}
;

const windows_doc =
    \\{"WindowsChanged":{"windows":[
    \\ {"id":10,"workspace_id":1,"app_id":"foot","title":"one"},
    \\ {"id":11,"workspace_id":1,"app_id":"foot","title":"two"},
    \\ {"id":12,"workspace_id":5,"app_id":"firefox","title":"three"},
    \\ {"id":13,"workspace_id":3,"app_id":"alacritty","title":"four"},
    \\ {"id":14,"workspace_id":99,"app_id":"ghost","title":"five"},
    \\ {"id":15,"app_id":"loose","title":"six"}
    \\]}}
;

fn populated() st.Tables {
    var tb = st.Tables.init(std.testing.allocator);
    feed(&tb, workspaces_doc) catch unreachable;
    feed(&tb, windows_doc) catch unreachable;
    return tb;
}

fn feed(tb: *st.Tables, doc: []const u8) !void {
    const out = try events.routeLine(tb, doc);
    if (!out.ok) return error.EventRejected;
}

test "niri-ws-query: candidates sort by position then id and honour the output" {
    const t = std.testing;
    var tb = populated();
    defer tb.deinit();

    const all = try sortedWorkspaceCandidates(&tb, "");
    defer t.allocator.free(all);
    try t.expectEqual(@as(usize, 5), all.len);
    try t.expectEqual(@as(u64, 7), all[0].id);
    try t.expectEqual(@as(u64, 1), all[1].id);
    try t.expectEqual(@as(u64, 3), all[2].id);
    try t.expectEqual(@as(u64, 5), all[3].id);
    try t.expectEqual(@as(u64, 4), all[4].id);

    const one = try sortedWorkspaceCandidates(&tb, "DP-1");
    defer t.allocator.free(one);
    try t.expectEqual(@as(usize, 4), one.len);
    try t.expectEqual(@as(u64, 7), one[0].id);
    try t.expectEqual(@as(u64, 4), one[3].id);

    const other = try sortedWorkspaceCandidates(&tb, "HDMI-1");
    defer t.allocator.free(other);
    try t.expectEqual(@as(usize, 1), other.len);
    try t.expectEqual(@as(u64, 3), other[0].id);

    // A name no workspace reports leaves nothing to claim, which is what makes
    // `sync` blank every row instead of borrowing another output's workspaces.
    const none = try sortedWorkspaceCandidates(&tb, "eDP-9");
    defer t.allocator.free(none);
    try t.expectEqual(@as(usize, 0), none.len);
}

test "niri-ws-query: sync matches by id, then position, then fills the gaps" {
    const t = std.testing;
    var tb = populated();
    defer tb.deinit();

    // On DP-1 the candidates are 7(idx0), 1(idx1), 5(idx2), 4(idx3).
    var regions = [_]desk.Region{
        .{ .id = "1" },
        .{ .id = "2" },
        .{ .id = "zz", .index = 42 },
        .{ .id = "9", .index = 42 },
        .{ .id = "8", .index = 42 },
    };
    try sync(&tb, &regions, "DP-1", true);

    // id 1: the exact-id pass, workspace 1, which holds two windows.
    try t.expectEqual(@as(u32, 1), regions[0].index);
    try t.expect(regions[0].occupied);
    // id 2: no workspace 2, so the position pass finds idx 2.
    try t.expectEqual(@as(u32, 2), regions[1].index);
    try t.expect(regions[1].occupied);
    // "zz" claims nothing by id, name or position and is handed the leftover
    // workspace 7 — unnumbered, so the region keeps the position it came with.
    try t.expectEqual(@as(u32, 42), regions[2].index);
    try t.expect(!regions[2].occupied);
    // The next leftover is workspace 4, which niri has numbered.
    try t.expectEqual(@as(u32, 3), regions[3].index);
    try t.expect(!regions[3].occupied);
    // Out of candidates: back to zero, whatever position it arrived with.
    try t.expectEqual(@as(u32, 0), regions[4].index);
    try t.expect(!regions[4].occupied);
}

test "niri-ws-query: sync with no output name never guesses, and only by name" {
    const t = std.testing;
    var tb = populated();
    defer tb.deinit();

    var regions = [_]desk.Region{
        .{ .id = "1" },
        .{ .id = "2" },
        .{ .id = "3" },
        .{ .id = "zz", .name = "web" },
        .{ .id = "9", .index = 42 },
    };
    try sync(&tb, &regions, "", true);

    try t.expectEqual(@as(u32, 1), regions[0].index);
    try t.expect(regions[0].occupied);
    try t.expectEqual(@as(u32, 2), regions[1].index);
    try t.expect(regions[1].occupied);
    // The exact-id pass reached workspace 3 on the other output, because with
    // no name to scope to every workspace is in play.
    try t.expectEqual(@as(u32, 1), regions[2].index);
    try t.expect(regions[2].occupied);
    // The name pass.
    try t.expectEqual(@as(u32, 3), regions[3].index);
    try t.expect(!regions[3].occupied);
    // No fill-in pass, so the unmatched row is blanked.
    try t.expectEqual(@as(u32, 0), regions[4].index);
    try t.expect(!regions[4].occupied);
}

test "niri-ws-query: sync leaves the regions alone when there is nothing to sync" {
    const t = std.testing;
    var tb = populated();
    defer tb.deinit();

    var offline = [_]desk.Region{.{ .id = "1", .index = 7 }};
    try sync(&tb, &offline, "DP-1", false);
    try t.expectEqual(@as(u32, 7), offline[0].index);
    try t.expect(!offline[0].occupied);

    var none: [0]desk.Region = .{};
    try sync(&tb, &none, "DP-1", true);

    var empty = st.Tables.init(t.allocator);
    defer empty.deinit();
    var rows = [_]desk.Region{.{ .id = "1", .index = 7 }};
    try sync(&empty, &rows, "DP-1", true);
    try t.expectEqual(@as(u32, 7), rows[0].index);
    try t.expect(!rows[0].occupied);
}

test "niri-ws-query: deskKeys renders the position first and the id when it has none" {
    const t = std.testing;
    var tb = populated();
    defer tb.deinit();

    const all = try deskKeys(&tb, "");
    defer freeKeys(t.allocator, all);
    const want_all = [_][]const u8{ "7", "1", "1", "2", "3" };
    try t.expectEqual(want_all.len, all.len);
    for (want_all, all) |want, got| try t.expectEqualStrings(want, got);

    // Workspace 7 has no position, so its key is its niri id; workspace 4 has
    // both, and the position wins.
    const one = try deskKeys(&tb, "DP-1");
    defer freeKeys(t.allocator, one);
    const want_one = [_][]const u8{ "7", "1", "2", "3" };
    try t.expectEqual(want_one.len, one.len);
    for (want_one, one) |want, got| try t.expectEqualStrings(want, got);

    const none = try deskKeys(&tb, "eDP-9");
    defer freeKeys(t.allocator, none);
    try t.expectEqual(@as(usize, 0), none.len);
}

test "niri-ws-query: appsByDesk groups, dedupes, and skips unplaceable windows" {
    const t = std.testing;
    var tb = populated();
    defer tb.deinit();

    // Window 11 repeats window 10's app id on the same desk and is dropped.
    // Windows 14 (unknown workspace) and 15 (no workspace at all) never make
    // it into a desk, so their app ids never show up either.
    var scoped = try appsByDesk(&tb, "DP-1");
    defer desk.freeAppMap(t.allocator, &scoped);
    try t.expectEqual(@as(usize, 2), scoped.count());
    try t.expectEqualStrings("foot", scoped.get("1").?.items[0]);
    try t.expectEqual(@as(usize, 1), scoped.get("1").?.items.len);
    try t.expectEqualStrings("firefox", scoped.get("2").?.items[0]);

    var hdmi = try appsByDesk(&tb, "HDMI-1");
    defer desk.freeAppMap(t.allocator, &hdmi);
    try t.expectEqual(@as(usize, 1), hdmi.count());
    try t.expectEqualStrings("alacritty", hdmi.get("1").?.items[0]);

    // Unscoped, workspaces 1 and 3 on different outputs both key as "1", so
    // their apps land in the one list — the key collision is real.
    var all = try appsByDesk(&tb, "");
    defer desk.freeAppMap(t.allocator, &all);
    try t.expectEqual(@as(usize, 2), all.count());
    try t.expectEqual(@as(usize, 2), all.get("1").?.items.len);
    try t.expectEqualStrings("alacritty", all.get("1").?.items[1]);

    var none = try appsByDesk(&tb, "eDP-9");
    defer desk.freeAppMap(t.allocator, &none);
    try t.expectEqual(@as(usize, 0), none.count());
}

test "niri-ws-query: windowsOnDesk reports placed windows with owned strings" {
    const t = std.testing;
    var tb = populated();
    defer tb.deinit();

    const rows = try windowsOnDesk(&tb, "DP-1");
    defer desk.freeWinList(t.allocator, rows);
    try t.expectEqual(@as(usize, 3), rows.len);
    try t.expectEqualStrings("10", rows[0].window_id);
    try t.expectEqualStrings("1", rows[0].desk_key);
    try t.expectEqualStrings("foot", rows[0].app_id);
    try t.expectEqualStrings("one", rows[0].title);
    try t.expectEqualStrings("12", rows[2].window_id);
    try t.expectEqualStrings("2", rows[2].desk_key);

    const all = try windowsOnDesk(&tb, "");
    defer desk.freeWinList(t.allocator, all);
    try t.expectEqual(@as(usize, 4), all.len);
    try t.expectEqualStrings("13", all[3].window_id);
    try t.expectEqualStrings("1", all[3].desk_key);

    // The rows alias nothing: tearing the table down under them is safe, which
    // LeakSanitizer and the titles below both confirm.
    const title = all[0].title;
    tb.clear();
    try t.expectEqualStrings("one", title);
}
