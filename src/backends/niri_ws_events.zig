//! niri workspace events: one line of the `EventStream` into a table mutation.
//!
//! The event half of `NiriWorkspaceManager`
//! niri tags each event by
//! wrapping a single key around its payload — `{"WorkspacesChanged":
//! {"workspaces":[…]}}` — so the dispatcher looks for exactly one key and
//! ignores everything else, including the `{"Ok":…}` handshake that opens the
//! stream and the `ConfigLoaded` event niri always sends first.

const std = @import("std");
const st = @import("niri_ws_state.zig");

/// What one line did. `ok` and the two change flags are independent: an
/// overview event flips only `view_changed` and never wakes the workspace
/// listeners, hence two separate notify callbacks.
pub const Outcome = struct {
    /// `false` means the stream rejected itself with an `Err` and the owner
    /// has to drop the connection and start the retry backoff again.
    ok: bool = true,
    state_changed: bool = false,
    view_changed: bool = false,
};

pub fn routeLine(t: *st.Tables, line: []const u8) !Outcome {
    var out = Outcome{};
    if (line.len == 0) return out;

    const doc = std.json.parseFromSlice(std.json.Value, t.alloc, line, .{}) catch return out;
    defer doc.deinit();
    const j = doc.value;
    if (j != .object) return out;
    if (j.object.contains("Ok")) return out;
    if (j.object.contains("Err")) {
        out.ok = false;
        return out;
    }
    if (j.object.count() != 1) return out;

    var it = j.object.iterator();
    const ent = it.next() orelse return out;
    const key = ent.key_ptr.*;
    const payload = ent.value_ptr.*;

    if (std.mem.eql(u8, key, "WorkspacesChanged")) {
        out.state_changed = try workspacesChanged(t, payload);
    } else if (std.mem.eql(u8, key, "WindowsChanged")) {
        out.state_changed = try windowsChanged(t, payload);
    } else if (std.mem.eql(u8, key, "OverviewOpenedOrClosed")) {
        out.view_changed = overviewFrom(t, payload);
        return out;
    } else if (std.mem.eql(u8, key, "OverviewOpened")) {
        out.view_changed = setOverview(t, true);
        return out;
    } else if (std.mem.eql(u8, key, "OverviewClosed")) {
        out.view_changed = setOverview(t, false);
        return out;
    } else if (std.mem.eql(u8, key, "WindowOpenedOrChanged")) {
        out.state_changed = try windowOpened(t, payload);
    } else if (std.mem.eql(u8, key, "WindowLayoutsChanged")) {
        out.state_changed = windowLayouts(t, payload);
    } else if (std.mem.eql(u8, key, "WindowClosed")) {
        out.state_changed = windowClosed(t, payload);
    }
    return out;
}

// Workspace table

fn workspacesChanged(t: *st.Tables, p: std.json.Value) !bool {
    const arr = st.asArray(p, "workspaces") orelse return false;

    var next: st.WsMap = .empty;
    errdefer st.freeWsMap(t.alloc, &next);
    for (arr.items) |item| {
        const parsed = (try st.decodeWorkspace(t.alloc, item)) orelse continue;
        // `emplace`, not `put`: a duplicated id keeps the first row.
        const gop = try next.getOrPut(t.alloc, parsed.id);
        if (gop.found_existing) st.freeWs(t.alloc, parsed) else gop.value_ptr.* = parsed;
    }

    if (st.sameWsMaps(&next, &t.workspaces)) {
        st.freeWsMap(t.alloc, &next);
        return false;
    }
    t.adoptWorkspaces(&next);
    return true;
}

// Window table

fn windowsChanged(t: *st.Tables, p: std.json.Value) !bool {
    const arr = st.asArray(p, "windows") orelse return false;

    var next: st.WinMap = .empty;
    errdefer st.freeWinMap(t.alloc, &next);
    for (arr.items) |item| {
        const parsed = (try st.decodeWindow(t.alloc, item)) orelse continue;
        const gop = try next.getOrPut(t.alloc, parsed.id);
        if (gop.found_existing) st.freeWin(t.alloc, parsed.st) else gop.value_ptr.* = parsed.st;
    }

    if (st.sameWinMaps(&next, &t.windows)) {
        st.freeWinMap(t.alloc, &next);
        return false;
    }
    const members = !st.sameMembershipMaps(&next, &t.windows);
    t.adoptWindows(&next);
    if (members) t.refreshOccupancy();
    return members;
}

fn windowOpened(t: *st.Tables, p: std.json.Value) !bool {
    const obj = st.asObject(p, "window") orelse return false;
    const id = st.optU64(obj, "id") orelse return false;

    // A window we already know gets copied before it is edited: the field
    // appliers free whatever they replace, so running them against the map's
    // own row would free memory the map still points at.
    if (t.windows.getPtr(id)) |slot| {
        var fresh = try cloneWin(t.alloc, slot.*);
        if (!(try st.mergeWindowFields(t.alloc, obj, &fresh))) {
            st.freeWin(t.alloc, fresh);
            return false;
        }
        if (st.sameWin(slot.*, fresh)) {
            st.freeWin(t.alloc, fresh);
            return false;
        }
        const members = !st.sameMembership(slot.*, fresh);
        st.freeWin(t.alloc, slot.*);
        slot.* = fresh;
        if (members) t.refreshOccupancy();
        return members;
    }

    var fresh = st.WinState{};
    if (!(try st.mergeWindowFields(t.alloc, obj, &fresh))) {
        st.freeWin(t.alloc, fresh);
        return false;
    }
    // A window with neither a workspace nor an app id is not a window the
    // shell can place, so it never enters the table.
    const members = fresh.ws_id != null or fresh.app_id.len > 0;
    t.windows.put(t.alloc, id, fresh) catch |err| {
        st.freeWin(t.alloc, fresh);
        return err;
    };
    if (members) t.refreshOccupancy();
    return members;
}

fn cloneWin(alloc: std.mem.Allocator, w: st.WinState) !st.WinState {
    var out = st.WinState{ .ws_id = w.ws_id, .x = w.x, .y = w.y };
    out.app_id = try alloc.dupe(u8, w.app_id);
    errdefer st.freeStr(alloc, out.app_id);
    out.title = try alloc.dupe(u8, w.title);
    return out;
}

fn windowLayouts(t: *st.Tables, p: std.json.Value) bool {
    const changes = st.asArray(p, "changes") orelse return false;
    var changed = false;
    for (changes.items) |item| {
        if (applyLayoutItem(t, item)) changed = true;
    }
    return changed;
}

/// One `[id, layout]` pair out of `WindowLayoutsChanged.changes`. Positions
/// are the only thing this touches; a row that does not name a window we hold
/// is skipped rather than creating one.
fn applyLayoutItem(t: *st.Tables, item: std.json.Value) bool {
    if (item != .array or item.array.items.len < 2) return false;
    const id = st.jsonU64(item.array.items[0]) orelse return false;
    const slot = t.windows.getPtr(id) orelse return false;
    const layout = item.array.items[1];
    if (layout != .object) return false;
    const pos = layout.object.get("pos_in_scrolling_layout") orelse return false;
    if (pos != .array or pos.array.items.len < 2) return false;
    const x = st.jsonI32(pos.array.items[0]) orelse return false;
    const y = st.jsonI32(pos.array.items[1]) orelse return false;
    if (slot.x == x and slot.y == y) return false;
    slot.x = x;
    slot.y = y;
    return true;
}

/// The id arrives bare or under `id`/`window_id` depending on which niri
/// release is talking, so all three shapes are accepted.
fn windowClosed(t: *st.Tables, p: std.json.Value) bool {
    var wid = st.jsonU64(p);
    if (wid == null and p == .object) {
        if (st.optU64(p, "id")) |v| {
            wid = v;
        } else if (st.optU64(p, "window_id")) |v| {
            wid = v;
        }
    }
    const id = wid orelse return false;
    const gone = t.windows.fetchOrderedRemove(id) orelse return false;
    st.freeWin(t.alloc, gone.value);
    t.refreshOccupancy();
    return true;
}

// Overview

fn setOverview(t: *st.Tables, open: bool) bool {
    const changed = !t.known_overview or t.overview_open != open;
    t.known_overview = true;
    t.overview_open = open;
    return changed;
}

fn overviewFrom(t: *st.Tables, p: std.json.Value) bool {
    const open = overviewValue(p) orelse return false;
    return setOverview(t, open);
}

/// A boolean, one of the words niri has used for one, or an object carrying
/// `is_open`/`isOpen`/`open`. Anything else leaves the flag untouched rather
/// than guessing.
fn overviewValue(p: std.json.Value) ?bool {
    if (p == .bool) return p.bool;
    if (p == .string) {
        for ([_][]const u8{ "open", "opened", "true" }) |w| {
            if (std.mem.eql(u8, p.string, w)) return true;
        }
        for ([_][]const u8{ "closed", "false" }) |w| {
            if (std.mem.eql(u8, p.string, w)) return false;
        }
        return null;
    }
    if (p == .object) {
        if (st.optBool(p, "is_open")) |b| return b;
        if (st.optBool(p, "isOpen")) |b| return b;
        if (st.optBool(p, "open")) |b| return b;
    }
    return null;
}

// Tests

test "niri-ws-events: only an Err tears the stream down" {
    const t = std.testing;
    var tb = st.Tables.init(t.allocator);
    defer tb.deinit();

    const rejected = try routeLine(&tb, "{\"Err\":\"nope\"}");
    try t.expect(!rejected.ok);

    // Malformed JSON, a bare scalar, the stream handshake, an event with two
    // keys, and a variant niri added since — all carried, none fatal.
    for ([_][]const u8{
        "not json at all",
        "\"just a string\"",
        "{\"Ok\":{\"Handled\":null}}",
        "{\"a\":1,\"b\":2}",
        "{\"SomethingNew\":{\"x\":1}}",
        "",
    }) |line| {
        const out = try routeLine(&tb, line);
        try t.expect(out.ok);
        try t.expect(!out.state_changed);
        try t.expect(!out.view_changed);
    }
    try t.expectEqual(@as(usize, 0), tb.workspaces.count());
    try t.expectEqual(@as(usize, 0), tb.windows.count());
}

test "niri-ws-events: WorkspacesChanged swaps the table and only reports movement" {
    const t = std.testing;
    var tb = st.Tables.init(t.allocator);
    defer tb.deinit();

    const first = try routeLine(&tb,
        \\{"WorkspacesChanged":{"workspaces":[
        \\ {"id":1,"idx":1,"name":null,"output":"DP-1"},
        \\ {"id":2,"idx":2,"name":"dev","output":"DP-1"}
        \\]}}
    );
    try t.expect(first.state_changed);
    try t.expect(first.ok);
    try t.expectEqual(@as(usize, 2), tb.workspaces.count());
    try t.expectEqualStrings("dev", tb.workspaces.get(2).?.name);

    // The identical document again changes nothing, so no listener wakes.
    const again = try routeLine(&tb,
        \\{"WorkspacesChanged":{"workspaces":[
        \\ {"id":1,"idx":1,"name":null,"output":"DP-1"},
        \\ {"id":2,"idx":2,"name":"dev","output":"DP-1"}
        \\]}}
    );
    try t.expect(!again.state_changed);

    // A renamed workspace is a change even though the ids are the same.
    const renamed = try routeLine(&tb,
        \\{"WorkspacesChanged":{"workspaces":[{"id":1,"idx":1,"name":"renamed","output":"DP-1"}]}}
    );
    try t.expect(renamed.state_changed);
    try t.expectEqual(@as(usize, 1), tb.workspaces.count());

    // A missing `workspaces` array is not a workspace event at all.
    const junk = try routeLine(&tb, "{\"WorkspacesChanged\":{\"nope\":1}}");
    try t.expect(!junk.state_changed);
    try t.expectEqual(@as(usize, 1), tb.workspaces.count());
}

test "niri-ws-events: WindowsChanged reports membership, not titles" {
    const t = std.testing;
    var tb = st.Tables.init(t.allocator);
    defer tb.deinit();

    const first = try routeLine(&tb,
        \\{"WindowsChanged":{"windows":[
        \\ {"id":10,"workspace_id":1,"app_id":"foot","title":"one"},
        \\ {"id":11,"workspace_id":2,"app_id":"firefox","title":"two"}
        \\]}}
    );
    try t.expect(first.state_changed);
    try t.expectEqual(@as(usize, 2), tb.windows.count());
    try t.expect(tb.occupied(1));
    try t.expect(tb.occupied(2));

    // Retitled windows are stored but are not a membership change, so the
    // taskbar is not told about them.
    const retitled = try routeLine(&tb,
        \\{"WindowsChanged":{"windows":[
        \\ {"id":10,"workspace_id":1,"app_id":"foot","title":"renamed"},
        \\ {"id":11,"workspace_id":2,"app_id":"firefox","title":"two"}
        \\]}}
    );
    try t.expect(!retitled.state_changed);
    try t.expectEqualStrings("renamed", tb.windows.get(10).?.title);

    // Moving a window between workspaces is.
    const moved = try routeLine(&tb,
        \\{"WindowsChanged":{"windows":[
        \\ {"id":10,"workspace_id":2,"app_id":"foot","title":"renamed"},
        \\ {"id":11,"workspace_id":2,"app_id":"firefox","title":"two"}
        \\]}}
    );
    try t.expect(moved.state_changed);
    try t.expect(tb.occupancy.get(1) == null);
    try t.expectEqual(@as(?usize, 2), tb.occupancy.get(2));

    // An absent `windows` key leaves the table alone.
    const junk = try routeLine(&tb, "{\"WindowsChanged\":{\"nope\":1}}");
    try t.expect(!junk.state_changed);
    try t.expectEqual(@as(usize, 2), tb.windows.count());
}

test "niri-ws-events: WindowOpenedOrChanged fills in only what it knows" {
    const t = std.testing;
    var tb = st.Tables.init(t.allocator);
    defer tb.deinit();

    // An id with no fields cannot conjure a window out of nothing.
    const empty = try routeLine(&tb, "{\"WindowOpenedOrChanged\":{\"window\":{\"id\":5}}}");
    try t.expect(!empty.state_changed);
    try t.expectEqual(@as(usize, 0), tb.windows.count());

    const opened = try routeLine(&tb,
        \\{"WindowOpenedOrChanged":{"window":{"id":5,"workspace_id":1,"app_id":"foot","title":"hi"}}}
    );
    try t.expect(opened.state_changed);
    try t.expectEqual(@as(usize, 1), tb.windows.count());
    try t.expect(tb.occupied(1));

    // The same row again is a no-op.
    const same = try routeLine(&tb,
        \\{"WindowOpenedOrChanged":{"window":{"id":5,"workspace_id":1,"app_id":"foot","title":"hi"}}}
    );
    try t.expect(!same.state_changed);

    // A retitle is stored without waking the workspace listeners.
    const retitled = try routeLine(&tb,
        \\{"WindowOpenedOrChanged":{"window":{"id":5,"workspace_id":1,"app_id":"foot","title":"bye"}}}
    );
    try t.expect(!retitled.state_changed);
    try t.expectEqualStrings("bye", tb.windows.get(5).?.title);

    // Relocating it is a membership change.
    const moved = try routeLine(&tb,
        \\{"WindowOpenedOrChanged":{"window":{"id":5,"workspace_id":9}}}
    );
    try t.expect(moved.state_changed);
    try t.expect(tb.occupied(9));
}

test "niri-ws-events: WindowLayoutsChanged moves positions and nothing else" {
    const t = std.testing;
    var tb = st.Tables.init(t.allocator);
    defer tb.deinit();
    _ = try routeLine(&tb,
        \\{"WindowsChanged":{"windows":[{"id":10,"workspace_id":1,"app_id":"foot"}]}}
    );

    const moved = try routeLine(&tb,
        \\{"WindowLayoutsChanged":{"changes":[[10,{"pos_in_scrolling_layout":[40,0]}],[99,{"pos_in_scrolling_layout":[1,2]}]]}}
    );
    try t.expect(moved.state_changed);
    try t.expectEqual(@as(i32, 40), tb.windows.get(10).?.x);
    try t.expectEqual(@as(usize, 1), tb.windows.count());

    // The same coordinates, a malformed pair, and an empty `changes` list are
    // all inert.
    for ([_][]const u8{
        \\{"WindowLayoutsChanged":{"changes":[[10,{"pos_in_scrolling_layout":[40,0]}]]}}
        ,
        \\{"WindowLayoutsChanged":{"changes":[[10]]}}
        ,
        \\{"WindowLayoutsChanged":{"changes":[]}}
        ,
        \\{"WindowLayoutsChanged":{}}
        ,
    }) |line| {
        const out = try routeLine(&tb, line);
        try t.expect(!out.state_changed);
    }
}

test "niri-ws-events: WindowClosed takes the id in every shape niri sends" {
    const t = std.testing;
    var tb = st.Tables.init(t.allocator);
    defer tb.deinit();
    _ = try routeLine(&tb,
        \\{"WindowsChanged":{"windows":[
        \\ {"id":10,"workspace_id":1,"app_id":"a"},
        \\ {"id":11,"workspace_id":1,"app_id":"b"},
        \\ {"id":12,"workspace_id":1,"app_id":"c"}
        \\]}}
    );
    try t.expectEqual(@as(usize, 3), tb.windows.count());

    for ([_][]const u8{
        "{\"WindowClosed\":10}",
        "{\"WindowClosed\":{\"id\":11}}",
        "{\"WindowClosed\":{\"window_id\":12}}",
    }) |shape| {
        const out = try routeLine(&tb, shape);
        try t.expect(out.state_changed);
    }
    try t.expectEqual(@as(usize, 0), tb.windows.count());
    try t.expect(!tb.occupied(1));

    // Closing something that is not there changes nothing.
    const noop = try routeLine(&tb, "{\"WindowClosed\":77}");
    try t.expect(!noop.state_changed);
}

test "niri-ws-events: the overview has its own channel" {
    const t = std.testing;
    var tb = st.Tables.init(t.allocator);
    defer tb.deinit();

    // Never seen before, so the first verdict is news either way.
    try t.expect(!tb.known_overview);
    const opened = try routeLine(&tb, "{\"OverviewOpenedOrClosed\":{\"is_open\":true}}");
    try t.expect(opened.view_changed);
    try t.expect(!opened.state_changed);
    try t.expect(tb.known_overview);
    try t.expect(tb.overview_open);

    // The same verdict again is not news.
    const still = try routeLine(&tb, "{\"OverviewOpenedOrClosed\":{\"is_open\":true}}");
    try t.expect(!still.view_changed);

    // The unit variants carry no payload; one is synthesised for them.
    const closed = try routeLine(&tb, "{\"OverviewClosed\":null}");
    try t.expect(closed.view_changed);
    try t.expect(!tb.overview_open);
    const up = try routeLine(&tb, "{\"OverviewOpened\":null}");
    try t.expect(up.view_changed);
    try t.expect(tb.overview_open);

    // Strings work too, and an unrecognised payload leaves the flag alone.
    const str = try routeLine(&tb, "{\"OverviewOpenedOrClosed\":\"closed\"}");
    try t.expect(str.view_changed);
    const junk = try routeLine(&tb, "{\"OverviewOpenedOrClosed\":\"maybe\"}");
    try t.expect(!junk.view_changed);
    const missing = try routeLine(&tb, "{\"OverviewOpenedOrClosed\":{}}");
    try t.expect(!missing.view_changed);
    try t.expect(!tb.overview_open);

    // A rejected overview line still tears the stream down.
    const rejected = try routeLine(&tb, "{\"Err\":\"nope\"}");
    try t.expect(!rejected.ok);
}
