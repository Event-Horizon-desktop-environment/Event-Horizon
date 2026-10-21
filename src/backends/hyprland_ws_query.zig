//! Reads the Hyprland workspace tables back out for the desk-source
//! interface: regions for the taskbar, the per-desk app map, and the focused
//! window.
//!
//! Everything returns owned copies — callers free every list and every string
//! they get back.

const std = @import("std");
const desk = @import("desk.zig");
const ws_state = @import("hyprland_ws_state.zig");

const State = ws_state.State;

const t = std.testing;

/// One workspace as the UI sees it. The region id is the numeric workspace id
/// (the key every `jumpTo` parses back out), and the name falls back to that id
/// so a workspace Hyprland gave no name still renders as something.
fn toRegion(ws: ws_state.Space, id_buf: []u8) desk.Region {
    const id = std.fmt.bufPrint(id_buf, "{d}", .{ws.id}) catch "";
    return .{
        .id = id,
        .name = if (ws.name.len != 0) ws.name else id,
        .index = if (ws.id >= 0) @intCast(ws.id) else 0,
        .active = ws.active,
        .urgent = ws.urgent,
        .occupied = ws.occupied,
    };
}

fn byId(_: void, a: *const ws_state.Space, b: *const ws_state.Space) bool {
    return a.id < b.id;
}

/// Every workspace as a region, ascending by id. The sort matters: the snapshot
/// table is in whatever order `j/workspaces` listed, and the taskbar's index
/// positions have to be stable across refreshes.
pub fn allRegions(self: *State) ![]desk.Region {
    return regionsOnMonitor(self, "");
}

/// The same, restricted to one monitor. An empty name means "every monitor",
/// which is how `regionsOnOutput` fell back when the output could not be named.
pub fn regionsOnMonitor(self: *State, monitor: []const u8) ![]desk.Region {
    var ordered: std.ArrayList(*const ws_state.Space) = .empty;
    defer ordered.deinit(self.alloc);
    for (self.spaces.items) |*ws| {
        if (ws.id < 0) continue;
        if (monitor.len != 0 and !std.mem.eql(u8, ws.monitor, monitor)) continue;
        try ordered.append(self.alloc, ws);
    }
    std.mem.sort(*const ws_state.Space, ordered.items, {}, byId);

    var out: std.ArrayList(desk.Region) = .empty;
    errdefer {
        desk.freeRegionElems(self.alloc, out.items);
        out.deinit(self.alloc);
    }
    var id_buf: [16]u8 = undefined;
    for (ordered.items) |ws| {
        try out.append(self.alloc, try desk.dupRegion(self.alloc, toRegion(ws.*, &id_buf)));
    }
    return out.toOwnedSlice(self.alloc);
}

fn hasApp(list: std.ArrayList([]const u8), needle: []const u8) bool {
    for (list.items) |app| {
        if (std.mem.eql(u8, app, needle)) return true;
    }
    return false;
}

/// deskKey -> the app ids running on it, deduplicated, in window-table order.
/// Keys and ids are owned copies (see `desk.AppMap`); the output parameter is
/// ignored — Hyprland's client list is
/// global, and windows are attributed to desks by their workspace id.
pub fn appsByDesk(self: *State) !desk.AppMap {
    var out = desk.AppMap.init(self.alloc);
    errdefer desk.freeAppMap(self.alloc, &out);

    for (self.windows.values()) |win| {
        if (win.app_id.len == 0) continue;
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{win.workspace_id}) catch continue;

        const gop = try out.getOrPut(key);
        if (gop.found_existing) {
            // The stored key stays; `StringHashMap.put` keeps it too.
        } else {
            // Value first, then the key: if the copy fails the entry has to be
            // gone again before we return, or `freeAppMap` would release the
            // stack buffer we handed it.
            gop.value_ptr.* = .empty;
            gop.key_ptr.* = self.alloc.dupe(u8, key) catch |err| {
                _ = out.remove(key);
                return err;
            };
        }
        if (hasApp(gop.value_ptr.*, win.app_id)) continue;
        const owned = try self.alloc.dupe(u8, win.app_id);
        errdefer self.alloc.free(owned);
        try gop.value_ptr.*.append(self.alloc, owned);
    }
    return out;
}

/// The title of the first window in the table, or nothing when the table is
/// empty. Windows read out of a hash map, so *which* window that
/// was depended on the platform's hash order; here it is insertion order —
/// whatever `j/clients` listed first. Note it hands back a title, not an id,
/// despite the name the fan-out gave it.
pub fn focusedWindowTitle(self: *const State) ?[]const u8 {
    const values = self.windows.values();
    if (values.len == 0) return null;
    return values[0].title;
}

// Tests

fn addSpace(s: *State, id: i32, name: []const u8, monitor: []const u8) void {
    const owned_name = s.alloc.dupe(u8, name) catch return;
    const owned_monitor = s.alloc.dupe(u8, monitor) catch {
        s.alloc.free(owned_name);
        return;
    };
    s.spaces.append(s.alloc, .{ .id = id, .name = owned_name, .monitor = owned_monitor }) catch {
        s.alloc.free(owned_name);
        s.alloc.free(owned_monitor);
    };
}

fn addWindow(s: *State, addr: u64, ws_id: i32, app_id: []const u8, title: []const u8) void {
    const owned_app = s.alloc.dupe(u8, app_id) catch return;
    const owned_title = s.alloc.dupe(u8, title) catch {
        s.alloc.free(owned_app);
        return;
    };
    s.windows.put(s.alloc, addr, .{
        .workspace_id = ws_id,
        .app_id = owned_app,
        .title = owned_title,
    }) catch {
        s.alloc.free(owned_app);
        s.alloc.free(owned_title);
    };
}

/// Three workspaces spread over two monitors, with workspace 2 focused.
fn populated() State {
    var s = State.init(t.allocator);
    addSpace(&s, 3, "3", "DP-3");
    addSpace(&s, 1, "", "DP-1"); // no name: falls back to the id
    addSpace(&s, 2, "2", "DP-2");
    addSpace(&s, -99, "special", "DP-1"); // never on a taskbar
    s.putActive("DP-2", 2);
    s.spaces.items[2].active = true;
    return s;
}

test "hyprland-ws-query: regions come back sorted, named, and owned" {
    var s = populated();
    defer s.deinit();

    const regions = try allRegions(&s);
    defer desk.freeRegionList(t.allocator, regions);
    try t.expectEqual(@as(usize, 3), regions.len); // -99 filtered out
    try t.expectEqualStrings("1", regions[0].id);
    try t.expectEqualStrings("2", regions[1].id);
    try t.expectEqualStrings("3", regions[2].id);
    // Name falls back to the id when Hyprland gave none.
    try t.expectEqualStrings("1", regions[0].name);
    try t.expectEqualStrings("3", regions[2].name);
    try t.expectEqual(@as(u32, 2), regions[1].index);
    try t.expect(regions[1].active);

    // Owned copies: changing the table afterwards must not disturb them.
    ws_state.replace(s.alloc, &s.spaces.items[1].name, "renamed");
    try t.expectEqualStrings("1", regions[0].name);
}

test "hyprland-ws-query: regionsOnMonitor filters, and an empty name means all" {
    var s = populated();
    defer s.deinit();

    const dp1 = try regionsOnMonitor(&s, "DP-1");
    defer desk.freeRegionList(t.allocator, dp1);
    try t.expectEqual(@as(usize, 1), dp1.len);
    try t.expectEqualStrings("1", dp1[0].id);

    const all = try regionsOnMonitor(&s, "");
    defer desk.freeRegionList(t.allocator, all);
    try t.expectEqual(@as(usize, 3), all.len);

    const unknown = try regionsOnMonitor(&s, "HDMI-A-1");
    defer desk.freeRegionList(t.allocator, unknown);
    try t.expectEqual(@as(usize, 0), unknown.len);
}

test "hyprland-ws-query: appsByDesk groups, dedupes, and owns its strings" {
    var s = State.init(t.allocator);
    defer s.deinit();
    addWindow(&s, 0x1, 2, "otter-term", "One");
    addWindow(&s, 0x2, 2, "otter-term", "Two"); // same app, same desk
    addWindow(&s, 0x3, 2, "vesktop", "Three");
    addWindow(&s, 0x4, 1, "firefox", "Four");
    addWindow(&s, 0x5, 1, "", "No class at all"); // skipped

    var apps = try appsByDesk(&s);
    defer desk.freeAppMap(t.allocator, &apps);
    try t.expectEqual(@as(usize, 2), apps.count());

    const two = apps.get("2").?;
    try t.expectEqual(@as(usize, 2), two.items.len);
    try t.expectEqualStrings("otter-term", two.items[0]);
    try t.expectEqualStrings("vesktop", two.items[1]);
    try t.expectEqual(@as(usize, 1), apps.get("1").?.items.len);

    // Owned: dropping the window must not free the strings we handed out.
    s.dropWindow(0x4);
    try t.expectEqualStrings("firefox", apps.get("1").?.items[0]);
}

test "hyprland-ws-query: focusedWindowTitle returns the first entry's title" {
    var s = State.init(t.allocator);
    defer s.deinit();
    try t.expect(focusedWindowTitle(&s) == null);

    addWindow(&s, 0x10, 1, "a", "First title");
    addWindow(&s, 0x20, 1, "b", "Second title");
    try t.expectEqualStrings("First title", focusedWindowTitle(&s).?);
}
