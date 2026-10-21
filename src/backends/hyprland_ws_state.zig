//! Hyprland workspace state: the snapshot tables and the mutations that keep
//! them honest between snapshots.
//!
//! Socket-free half of `HyprlandWorkspaceManager`
//! Everything here
//! takes plain slices, so the recorded `testdata/backends/hyprland/*` fixtures
//! can drive it in a test without a compositor:
//!
//! * `hyprland_ws_snapshot.zig` loads the three `j/…` documents into the tables
//! * `hyprland_ws_events.zig` turns `socket2` payloads into the mutations below
//! * `hyprland_ws_query.zig` reads the tables back out for the interface

const std = @import("std");
const desk = @import("desk.zig");
const codec = @import("hyprland_ws_codec.zig");

/// One `j/workspaces` entry. Strings are owned by the `State` holding it.
pub const Space = struct {
    id: i32 = -1,
    name: []const u8 = "",
    monitor: []const u8 = "",
    active: bool = false,
    urgent: bool = false,
    occupied: bool = false,
};

/// One `j/clients` entry, keyed by its hex window address.
pub const Toplevel = struct {
    workspace_id: i32 = -1,
    app_id: []const u8 = "",
    title: []const u8 = "",
    urgent: bool = false,
};

pub const State = struct {
    alloc: std.mem.Allocator,
    /// Workspaces in the order the snapshot listed them; the query layer sorts
    /// by id whenever the UI wants a stable order.
    spaces: std.ArrayList(Space) = .empty,
    windows: std.array_hash_map.Auto(u64, Toplevel) = .empty,
    /// Monitor name -> the workspace that monitor has focused.
    active_map: std.StringHashMap(i32),

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc, .active_map = std.StringHashMap(i32).init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
        self.spaces.deinit(self.alloc);
        self.windows.deinit(self.alloc);
        self.active_map.deinit();
    }

    /// The connection that owned these tables went away — this is the runtime's
    /// `onCleanup`, and it must leave nothing behind for the next snapshot.
    pub fn clear(self: *Self) void {
        for (self.spaces.items) |ws| freeSpace(self.alloc, ws);
        self.spaces.clearRetainingCapacity();
        var wit = self.windows.iterator();
        while (wit.next()) |e| freeToplevel(self.alloc, e.value_ptr.*);
        self.windows.clearRetainingCapacity();
        freeActiveMap(self);
    }

    pub fn findSpace(self: *Self, id: i32) ?*Space {
        for (self.spaces.items) |*ws| {
            if (ws.id == id) return ws;
        }
        return null;
    }

    /// Recomputes the derived flags on every workspace from the two tables. This
    /// is deliberately allocation-free: it runs on every workspace change and
    /// must not leave stale flags behind.
    pub fn refreshFlags(self: *Self) void {
        for (self.spaces.items) |*ws| {
            var occupied = false;
            var urgent = false;
            for (self.windows.values()) |t| {
                if (t.workspace_id != ws.id) continue;
                occupied = true;
                if (t.urgent) urgent = true;
            }
            ws.occupied = occupied;
            ws.urgent = urgent;
            if (ws.monitor.len == 0) {
                ws.active = false;
            } else if (self.active_map.get(ws.monitor)) |focused| {
                ws.active = focused == ws.id;
            } else {
                ws.active = false;
            }
        }
    }

    // -- mutations, one per event that changes a table ---------------------

    /// `focusedmonv2`: move a monitor's focus pointer and clear urgency on the
    /// workspace it landed on. Returns false when the payload carried no
    /// monitor name, without notifying either.
    pub fn handleFocusChange(self: *Self, monitor: []const u8, ws_id: i32) bool {
        if (monitor.len == 0) return false;
        putActive(self, monitor, ws_id);
        dismissUrgent(self, ws_id);
        self.refreshFlags();
        return true;
    }

    /// Clears urgency on every window sitting on `ws_id`.
    pub fn dismissUrgent(self: *Self, ws_id: i32) void {
        for (self.windows.values()) |*t| {
            if (t.workspace_id == ws_id) t.urgent = false;
        }
    }

    /// `movewindowv2`/`openwindow`: re-home a window, creating the entry when
    /// the address is new — get-or-create by address.
    pub fn relocate(self: *Self, addr: u64, ws_id: i32) void {
        const gop = self.windows.getOrPut(self.alloc, addr) catch return;
        if (!gop.found_existing) gop.value_ptr.* = Toplevel{};
        gop.value_ptr.workspace_id = ws_id;
    }

    /// `openwindow`: stamp the class and title the event carried. Both are
    /// copied — the payload does not outlive the dispatch.
    pub fn setWindowMeta(self: *Self, addr: u64, app_id: []const u8, title: []const u8) void {
        const t = self.windows.getPtr(addr) orelse return;
        replace(self.alloc, &t.app_id, app_id);
        replace(self.alloc, &t.title, title);
    }

    /// `closewindow`: drop the entry; a miss is a no-op.
    pub fn dropWindow(self: *Self, addr: u64) void {
        if (self.windows.fetchOrderedRemove(addr)) |kv| freeToplevel(self.alloc, kv.value);
    }

    /// `urgent`: mark a window urgent, stubbing the entry in when the address
    /// is not in the snapshot yet (urgency can arrive before the client list
    /// has caught up).
    pub fn markUrgent(self: *Self, addr: u64) void {
        const gop = self.windows.getOrPut(self.alloc, addr) catch return;
        if (gop.found_existing) {
            gop.value_ptr.urgent = true;
            return;
        }
        gop.value_ptr.* = Toplevel{ .workspace_id = -1, .urgent = true };
    }

    /// `createworkspacev2`: add the workspace if it is unknown, else rename it.
    pub fn ensureWorkspace(self: *Self, id: i32, name: []const u8) void {
        if (self.findSpace(id)) |ws| {
            replace(self.alloc, &ws.name, name);
            return;
        }
        const owned = self.alloc.dupe(u8, name) catch return;
        self.spaces.append(self.alloc, .{ .id = id, .name = owned, .monitor = "" }) catch {
            self.alloc.free(owned);
        };
    }

    /// `renameworkspace`. Returns false when the workspace is unknown, which is
    /// the dispatcher's cue to reload the snapshot instead.
    pub fn renameWorkspace(self: *Self, id: i32, new_name: []const u8) bool {
        const ws = self.findSpace(id) orelse return false;
        replace(self.alloc, &ws.name, new_name);
        return true;
    }

    /// `moveworkspacev2`. An unknown workspace, or a payload with no monitor
    /// name, changes nothing at all.
    pub fn setMonitor(self: *Self, id: i32, monitor: []const u8) bool {
        if (monitor.len == 0) return false;
        const ws = self.findSpace(id) orelse return false;
        replace(self.alloc, &ws.monitor, monitor);
        return true;
    }

    /// `destroyworkspacev2`: drop the workspace and every window still on it.
    pub fn dropWorkspace(self: *Self, id: i32) void {
        var i: usize = 0;
        while (i < self.spaces.items.len) {
            if (self.spaces.items[i].id == id) {
                freeSpace(self.alloc, self.spaces.items[i]);
                _ = self.spaces.orderedRemove(i);
            } else i += 1;
        }
        // Walk the windows by index rather than iterator: `orderedRemove`
        // shifts the tail down, so whatever lands at this index is next.
        i = 0;
        while (i < self.windows.count()) {
            const addr = self.windows.keys()[i];
            if (self.windows.values()[i].workspace_id == id) {
                if (self.windows.fetchOrderedRemove(addr)) |kv| freeToplevel(self.alloc, kv.value);
            } else i += 1;
        }
    }

    // -- shared string/table plumbing -------------------------------------

    /// `put` on a string map keeps whatever key it already stores, so a
    /// duplicate key would be dropped on the floor (leaked) unless we only copy
    /// one for a genuinely new entry.
    pub fn putActive(self: *Self, name: []const u8, ws_id: i32) void {
        const gop = self.active_map.getOrPut(name) catch return;
        if (gop.found_existing) {
            gop.value_ptr.* = ws_id;
            return;
        }
        gop.key_ptr.* = self.alloc.dupe(u8, name) catch {
            // `getOrPut` already installed the borrowed key; take it back out
            // so nothing points at a buffer that is about to go away.
            _ = self.active_map.remove(name);
            return;
        };
        gop.value_ptr.* = ws_id;
    }

    pub fn freeActiveMap(self: *Self) void {
        var it = self.active_map.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.active_map.clearRetainingCapacity();
    }
};

pub fn freeSpace(alloc: std.mem.Allocator, ws: Space) void {
    alloc.free(ws.name);
    alloc.free(ws.monitor);
}

pub fn freeToplevel(alloc: std.mem.Allocator, t: Toplevel) void {
    alloc.free(t.app_id);
    alloc.free(t.title);
}

/// Replaces `slot` with a copy of `text`. On allocation failure the old value
/// stays: a shell that cannot grow a string should keep showing the last title
/// it knew rather than clear it.
pub fn replace(alloc: std.mem.Allocator, slot: *[]const u8, text: []const u8) void {
    const copy = alloc.dupe(u8, text) catch return;
    alloc.free(slot.*);
    slot.* = copy;
}

// Tests

/// Builds a state whose tables hold the shape a real snapshot would leave
/// behind: workspace 2 focused on DP-2, two windows, one of them urgent. Every
/// string is copied, because `clear` frees what the tables hold.
fn fixture(alloc: std.mem.Allocator) State {
    var s = State.init(alloc);
    addSpace(&s, 1, "1", "DP-1");
    addSpace(&s, 2, "2", "DP-2");
    s.putActive("DP-2", 2);
    addWindow(&s, 0x10, 1, "otter-term", "One", false);
    addWindow(&s, 0x20, 2, "vesktop", "Two", true);
    return s;
}

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

fn addWindow(s: *State, addr: u64, ws_id: i32, app_id: []const u8, title: []const u8, urgent: bool) void {
    const owned_app = s.alloc.dupe(u8, app_id) catch return;
    const owned_title = s.alloc.dupe(u8, title) catch {
        s.alloc.free(owned_app);
        return;
    };
    s.windows.put(s.alloc, addr, .{
        .workspace_id = ws_id,
        .app_id = owned_app,
        .title = owned_title,
        .urgent = urgent,
    }) catch {
        s.alloc.free(owned_app);
        s.alloc.free(owned_title);
    };
}

test "hyprland-ws-state: refreshFlags derives occupied/urgent/active without allocating" {
    const t = std.testing;
    var s = fixture(t.allocator);
    defer s.deinit();
    s.refreshFlags();

    const ws1 = s.findSpace(1).?;
    const ws2 = s.findSpace(2).?;
    try t.expect(ws1.occupied); // one window on it
    try t.expect(!ws1.urgent);
    try t.expect(!ws1.active); // DP-1 has no entry in active_map yet
    try t.expect(ws2.occupied);
    try t.expect(ws2.urgent); // 0x20 is urgent
    try t.expect(ws2.active); // active_map says DP-2 -> 2

    // A monitor with no recorded focus never marks a workspace active, and an
    // empty monitor name never does either. The table owns `monitor`, so the
    // test keeps the original buffer and hands it back — leaving a literal in
    // there would have `clear` freeing bytes it never allocated.
    const owned_monitor = s.spaces.items[1].monitor;
    s.spaces.items[1].monitor = "";
    s.refreshFlags();
    try t.expect(!s.findSpace(2).?.active);

    s.spaces.items[1].monitor = owned_monitor;
    s.refreshFlags();
    try t.expect(s.findSpace(2).?.active);

    // Urgency is cleared through the mutation, then the flags follow.
    s.dismissUrgent(2);
    s.refreshFlags();
    try t.expect(!s.findSpace(2).?.urgent);
}

test "hyprland-ws-state: focus change needs a monitor name to count" {
    const t = std.testing;
    var s = fixture(t.allocator);
    defer s.deinit();

    try t.expect(!s.handleFocusChange("", 1)); // no notify, no change
    try t.expect(s.active_map.get("DP-2").? == 2);

    try t.expect(s.handleFocusChange("DP-3", 3));
    try t.expectEqual(@as(i32, 3), s.active_map.get("DP-3").?);
    s.refreshFlags();
    try t.expect(!s.findSpace(1).?.active);

    // Re-pointing an existing monitor replaces the value, not the key — the
    // name string must not be duplicated.
    try t.expect(s.handleFocusChange("DP-2", 1));
    try t.expectEqual(@as(i32, 1), s.active_map.get("DP-2").?);
    try t.expectEqual(@as(usize, 2), s.active_map.count());
}

test "hyprland-ws-state: window mutations create, move, and drop entries" {
    const t = std.testing;
    var s = fixture(t.allocator);
    defer s.deinit();

    // relocate on an unknown address stubs the entry in, then meta fills it.
    s.relocate(0x30, -1);
    s.setWindowMeta(0x30, "firefox", "A title with, a comma");
    const stub = s.windows.getPtr(0x30).?;
    try t.expectEqual(@as(i32, -1), stub.workspace_id);
    try t.expectEqualStrings("firefox", stub.app_id);
    try t.expectEqualStrings("A title with, a comma", stub.title);

    s.relocate(0x30, 1);
    try t.expectEqual(@as(i32, 1), s.windows.getPtr(0x30).?.workspace_id);

    // An address with no meta yet is a no-op rather than a crash.
    s.setWindowMeta(0x40, "ignored", "ignored");
    try t.expect(s.windows.get(0x40) == null);

    s.dropWindow(0x30);
    s.dropWindow(0x40); // missing keys are fine
    try t.expect(s.windows.get(0x30) == null);
    try t.expectEqual(@as(usize, 2), s.windows.count());
}

test "hyprland-ws-state: urgency can arrive for a window the snapshot missed" {
    const t = std.testing;
    var s = fixture(t.allocator);
    defer s.deinit();

    s.markUrgent(0x10);
    try t.expect(s.windows.getPtr(0x10).?.urgent);

    s.markUrgent(0x99);
    const fresh = s.windows.getPtr(0x99).?;
    try t.expect(fresh.urgent);
    try t.expectEqual(@as(i32, -1), fresh.workspace_id);
    try t.expectEqual(@as(usize, 0), fresh.app_id.len);
}

test "hyprland-ws-state: workspace add, rename, move, and destroy" {
    const t = std.testing;
    var s = fixture(t.allocator);
    defer s.deinit();

    s.ensureWorkspace(91, "91");
    s.ensureWorkspace(91, "renamed"); // already there: rename, do not duplicate
    try t.expectEqual(@as(usize, 3), s.spaces.items.len);
    try t.expectEqualStrings("renamed", s.findSpace(91).?.name);

    try t.expect(s.renameWorkspace(91, "91"));
    try t.expectEqualStrings("91", s.findSpace(91).?.name);
    // Unknown id is the dispatcher's cue to reload the snapshot. The empty-name
    // rejection lives in the dispatcher too.
    try t.expect(!s.renameWorkspace(99, "nope"));

    try t.expect(s.setMonitor(91, "DP-3"));
    try t.expectEqualStrings("DP-3", s.findSpace(91).?.monitor);
    try t.expect(!s.setMonitor(91, "")); // empty monitor is rejected
    try t.expect(!s.setMonitor(99, "DP-3"));

    s.relocate(0x50, 91);
    s.dropWorkspace(91);
    try t.expect(s.findSpace(91) == null);
    try t.expect(s.windows.get(0x50) == null); // windows on it went too
    try t.expectEqual(@as(usize, 2), s.spaces.items.len);
}

test "hyprland-ws-state: clear empties everything so the next snapshot starts fresh" {
    const t = std.testing;
    var s = fixture(t.allocator);
    defer s.deinit();

    try t.expectEqual(@as(usize, 2), s.spaces.items.len);
    s.clear();
    try t.expectEqual(@as(usize, 0), s.spaces.items.len);
    try t.expectEqual(@as(usize, 0), s.windows.count());
    try t.expectEqual(@as(usize, 0), s.active_map.count());
    s.refreshFlags(); // must be safe on an empty state
}
