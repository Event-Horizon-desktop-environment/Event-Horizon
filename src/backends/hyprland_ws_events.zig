//! The Hyprland event dispatcher: `socket2` payloads in, state mutations out.
//!
//! Event entry point. The dispatcher reaches back into
//! its own members to re-query the compositor mid-event (`loadWorkspaces` on
//! `createworkspacev2`, `loadMonitors` on `workspacev2`); here those go through
//! a `Host` record, so a test can serve the recorded fixtures and drive the
//! whole dispatch without a socket. The same record carries the notification
//! callback, which is what makes "did this event change anything" observable.

const std = @import("std");
const codec = @import("hyprland_ws_codec.zig");
const ws_state = @import("hyprland_ws_state.zig");
const ws_snapshot = @import("hyprland_ws_snapshot.zig");
/// Recorded replies and events, wired in by the build (see `testdata/root.zig`).
const testdata = @import("testdata");

const State = ws_state.State;

/// How the dispatcher reaches the compositor. Every field takes a `ctx` so a
/// fixture harness can stand in for a live `Runtime`.
pub const Host = struct {
    ctx: *anyopaque,
    /// One `j/…` request. Returns **owned** bytes the caller frees, or null
    /// when the compositor did not answer.
    query: *const fn (ctx: *anyopaque, command: []const u8) ?[]u8,
    /// Full snapshot reload. `configreloaded` hands off to it so the manager
    /// keeps control of notification ordering for the whole batch.
    reload: *const fn (ctx: *anyopaque) void,
    /// Fans one state change out to the registered listeners.
    notify: *const fn (ctx: *anyopaque) void,
};

const What = enum { workspaces, monitors, clients };

fn commandFor(what: What) []const u8 {
    return switch (what) {
        .workspaces => "j/workspaces",
        .monitors => "j/monitors",
        .clients => "j/clients",
    };
}

/// Pulls one document into the matching table. A reply that never arrives
/// leaves the table alone — non-object payloads return early, and it
/// is why an event can still be applied when the compositor is wedged.
fn load(host: Host, s: *State, what: What) void {
    const text = host.query(host.ctx, commandFor(what)) orelse return;
    defer s.alloc.free(text);
    switch (what) {
        .workspaces => ws_snapshot.loadWorkspaces(s, text),
        .monitors => ws_snapshot.loadMonitors(s, text),
        .clients => ws_snapshot.loadClients(s, text),
    }
}

/// The manager's `reloadSnapshot`: three queries, recompute the flags, one
/// notification for the whole batch rather than one per table.
pub fn reload(host: Host, s: *State) void {
    load(host, s, .workspaces);
    load(host, s, .monitors);
    load(host, s, .clients);
    s.refreshFlags();
    host.notify(host.ctx);
}

/// Applies one already-split `event>>payload` pair. Anything this does not
/// recognise — and any payload it cannot parse — changes nothing and notifies
/// nobody, because a taskbar that flickers on garbage is worse than one that
/// ignores it.
pub fn apply(host: Host, s: *State, event: []const u8, data: []const u8) void {
    if (std.mem.eql(u8, event, "configreloaded")) {
        host.reload(host.ctx);
        return;
    }

    if (std.mem.eql(u8, event, "focusedmonv2")) {
        const args = codec.splitByN(2, data);
        const ws_id = codec.decodeInt(args[1]) orelse return;
        if (s.handleFocusChange(args[0], ws_id)) host.notify(host.ctx);
        return;
    }

    if (std.mem.eql(u8, event, "workspacev2")) {
        const args = codec.splitByN(2, data);
        const ws_id = codec.decodeInt(args[0]) orelse return;
        load(host, s, .monitors);
        s.dismissUrgent(ws_id);
        s.refreshFlags();
        host.notify(host.ctx);
        return;
    }

    if (std.mem.eql(u8, event, "createworkspacev2")) {
        const args = codec.splitByN(2, data);
        const ws_id = codec.decodeInt(args[0]) orelse return;
        if (args[1].len == 0) return;
        s.ensureWorkspace(ws_id, args[1]);
        load(host, s, .workspaces);
        s.refreshFlags();
        host.notify(host.ctx);
        return;
    }

    if (std.mem.eql(u8, event, "destroyworkspacev2")) {
        const args = codec.splitByN(2, data);
        const ws_id = codec.decodeInt(args[0]) orelse return;
        s.dropWorkspace(ws_id);
        s.refreshFlags();
        host.notify(host.ctx);
        return;
    }

    if (std.mem.eql(u8, event, "renameworkspace")) {
        const args = codec.splitByN(2, data);
        const ws_id = codec.decodeInt(args[0]) orelse return;
        if (args[1].len == 0) return;
        // Unknown workspace: fall back to a reload rather than rename nothing.
        if (!s.renameWorkspace(ws_id, args[1])) load(host, s, .workspaces);
        s.refreshFlags();
        host.notify(host.ctx);
        return;
    }

    if (std.mem.eql(u8, event, "moveworkspacev2")) {
        const args = codec.splitByN(3, data);
        const ws_id = codec.decodeInt(args[0]) orelse return;
        if (s.setMonitor(ws_id, args[2])) {
            s.refreshFlags();
            host.notify(host.ctx);
        }
        return;
    }

    if (std.mem.eql(u8, event, "openwindow")) {
        const args = codec.splitByN(4, data);
        const addr = codec.decodeHex(args[0]) orelse return;
        // Park it at -1 first: the event's workspace field is a *name*, and
        // only the following `j/clients` round trip knows its number.
        s.relocate(addr, -1);
        s.setWindowMeta(addr, args[2], args[3]);
        load(host, s, .clients);
        s.refreshFlags();
        host.notify(host.ctx);
        return;
    }

    if (std.mem.eql(u8, event, "closewindow")) {
        const args = codec.splitByN(1, data);
        const addr = codec.decodeHex(args[0]) orelse return;
        s.dropWindow(addr);
        s.refreshFlags();
        host.notify(host.ctx);
        return;
    }

    if (std.mem.eql(u8, event, "movewindowv2")) {
        const args = codec.splitByN(3, data);
        const addr = codec.decodeHex(args[0]) orelse return;
        const ws_id = codec.decodeInt(args[2]) orelse return;
        s.relocate(addr, ws_id);
        s.refreshFlags();
        host.notify(host.ctx);
        return;
    }

    if (std.mem.eql(u8, event, "urgent")) {
        const args = codec.splitByN(1, data);
        const addr = codec.decodeHex(args[0]) orelse return;
        s.markUrgent(addr);
        s.refreshFlags();
        host.notify(host.ctx);
    }
}

// Tests

const t = std.testing;

/// Stands in for a live runtime: answers each `j/…` command at most once from a
/// fixture, counts notifications, and records how often a full reload ran.
const Harness = struct {
    state: *State,
    workspaces: ?[]const u8 = null,
    monitors: ?[]const u8 = null,
    clients: ?[]const u8 = null,
    answered: u8 = 0,
    notified: usize = 0,
    reloads: usize = 0,

    fn host(self: *Harness) Host {
        return .{
            .ctx = @ptrCast(self),
            .query = queryThunk,
            .reload = reloadThunk,
            .notify = notifyThunk,
        };
    }

    fn queryThunk(ctx: *anyopaque, command: []const u8) ?[]u8 {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        const bit: u8 = if (std.mem.eql(u8, command, "j/workspaces"))
            1
        else if (std.mem.eql(u8, command, "j/monitors"))
            2
        else if (std.mem.eql(u8, command, "j/clients"))
            4
        else
            return null;
        if ((self.answered & bit) != 0) return null;
        self.answered |= bit;
        const doc = if (bit == 1) self.workspaces else if (bit == 2) self.monitors else self.clients;
        const text = doc orelse return null;
        return self.state.alloc.dupe(u8, text) catch null;
    }

    fn reloadThunk(ctx: *anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        self.reloads += 1;
        reload(self.host(), self.state);
    }

    fn notifyThunk(ctx: *anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        self.notified += 1;
    }
};

fn send(h: *Harness, event: []const u8, data: []const u8) void {
    apply(h.host(), h.state, event, data);
}

test "hyprland-ws-events: recorded session replays to a stable state" {
    var s = State.init(t.allocator);
    defer s.deinit();
    var h = Harness{
        .state = &s,
        .workspaces = testdata.hyprland.workspaces,
        .monitors = testdata.hyprland.monitors,
        .clients = testdata.hyprland.clients,
    };

    reload(h.host(), &s);
    try t.expectEqual(@as(usize, 1), h.notified);
    try t.expectEqual(@as(usize, 3), s.spaces.items.len);
    try t.expectEqual(@as(usize, 3), s.windows.count());

    const events_text = testdata.hyprland.events;
    var lines = std.mem.splitScalar(u8, events_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const split = std.mem.indexOf(u8, line, ">>") orelse continue;
        send(&h, line[0..split], line[split + 2 ..]);
    }

    // Ten of the 38 recorded lines are events this backend acts on
    // (focusedmonv2 x3, workspacev2 x3, createworkspacev2 x2,
    // destroyworkspacev2 x2); the v1 variants and the window-title noise are
    // deliberately ignored.
    try t.expectEqual(@as(usize, 11), h.notified);
    try t.expectEqual(@as(usize, 0), h.reloads);

    // 91 and 92 were created and destroyed again; the snapshot queries were
    // already spent, so the event-driven changes had to stand on their own.
    try t.expectEqual(@as(usize, 3), s.spaces.items.len);
    try t.expect(s.findSpace(91) == null);
    try t.expect(s.findSpace(92) == null);
    try t.expectEqual(@as(i32, 1), s.findSpace(1).?.id);
    try t.expectEqual(@as(i32, 3), s.findSpace(3).?.id);

    // focusedmonv2 re-pointed the same monitors the snapshot had recorded.
    try t.expectEqual(@as(i32, 1), s.active_map.get("DP-1").?);
    try t.expectEqual(@as(i32, 2), s.active_map.get("DP-2").?);
    try t.expectEqual(@as(i32, 3), s.active_map.get("DP-3").?);

    s.refreshFlags();
    try t.expect(s.findSpace(1).?.active);
    try t.expect(s.findSpace(2).?.active);
    try t.expect(s.findSpace(3).?.active);
    try t.expect(s.findSpace(1).?.occupied);
    try t.expect(s.findSpace(2).?.occupied);
    try t.expect(!s.findSpace(3).?.occupied);
}

test "hyprland-ws-events: configreloaded is the one event that reloads everything" {
    var s = State.init(t.allocator);
    defer s.deinit();
    var h = Harness{
        .state = &s,
        .workspaces = "[{\"id\":5,\"name\":\"5\",\"monitor\":\"DP-1\"}]",
        .monitors = "[{\"name\":\"DP-1\",\"activeWorkspace\":{\"id\":5}}]",
    };
    send(&h, "configreloaded", "");
    try t.expectEqual(@as(usize, 1), h.reloads);
    try t.expectEqual(@as(usize, 1), h.notified);
    try t.expectEqual(@as(usize, 1), s.spaces.items.len);
    try t.expectEqual(@as(i32, 5), s.findSpace(5).?.id);
}

test "hyprland-ws-events: unreadable payloads change nothing and notify nobody" {
    var s = State.init(t.allocator);
    defer s.deinit();
    var h = Harness{ .state = &s };

    // Unknown events, the v1 twins of events we do handle, and payloads whose
    // id field does not parse are all dropped before any mutation runs.
    send(&h, "activewindowv2", "0x1");
    send(&h, "focusedmon", "DP-1,1");
    send(&h, "workspace", "2");
    send(&h, "garbage", "");
    send(&h, "focusedmonv2", "DP-1,"); // no id
    send(&h, "workspacev2", "not-a-number,x");
    send(&h, "createworkspacev2", "12,"); // no name
    send(&h, "renameworkspace", "12,");
    send(&h, "closewindow", "zzz");
    send(&h, "movewindowv2", "zzz,2,3");
    try t.expectEqual(@as(usize, 0), h.notified);
    try t.expectEqual(@as(usize, 0), s.spaces.items.len);
    try t.expectEqual(@as(usize, 0), s.windows.count());

    // A monitor with no name is the one focusedmonv2 that does nothing.
    send(&h, "focusedmonv2", ",1");
    try t.expectEqual(@as(usize, 0), h.notified);
    try t.expectEqual(@as(usize, 0), s.active_map.count());
}

test "hyprland-ws-events: window events create, move, and close windows" {
    var s = State.init(t.allocator);
    defer s.deinit();
    var h = Harness{ .state = &s };

    send(&h, "openwindow", "0x10,2,otter-term,A title, with commas");
    try t.expectEqual(@as(usize, 1), h.notified);
    const opened = s.windows.getPtr(0x10).?;
    try t.expectEqual(@as(i32, -1), opened.workspace_id); // reload was silent
    try t.expectEqualStrings("otter-term", opened.app_id);
    try t.expectEqualStrings("A title, with commas", opened.title);

    send(&h, "movewindowv2", "0x10,name,7");
    try t.expectEqual(@as(i32, 7), s.windows.getPtr(0x10).?.workspace_id);

    send(&h, "urgent", "0x10");
    try t.expect(s.windows.getPtr(0x10).?.urgent);
    send(&h, "urgent", "0x99"); // a window we never saw still lights up
    try t.expect(s.windows.get(0x99).?.urgent);

    send(&h, "closewindow", "0x10");
    send(&h, "closewindow", "0x99");
    try t.expectEqual(@as(usize, 0), s.windows.count());
    // One notification per event, unconditionally: every handler ends with one,
    // these branches on an unguarded `onStateChange()`.
    try t.expectEqual(@as(usize, 6), h.notified);
}

test "hyprland-ws-events: a failed rename falls back to reloading the snapshot" {
    var s = State.init(t.allocator);
    defer s.deinit();
    var h = Harness{
        .state = &s,
        .workspaces = "[{\"id\":4,\"name\":\"4\",\"monitor\":\"DP-1\"}]",
    };
    // Events only ever arrive after `openConnection` has pulled a snapshot, so
    // start from the same place and forget the priming's bookkeeping.
    reload(h.host(), &s);
    h.answered = 0;
    h.notified = 0;

    send(&h, "renameworkspace", "4,renamed");
    try t.expectEqual(@as(usize, 0), h.answered); // workspace exists, no query
    try t.expectEqual(@as(usize, 1), h.notified);
    try t.expectEqualStrings("renamed", s.findSpace(4).?.name);

    // Unknown id: reload the snapshot instead of renaming nothing.
    send(&h, "renameworkspace", "8,ghost");
    try t.expectEqual(@as(usize, 1), h.answered);
    try t.expectEqual(@as(usize, 1), s.spaces.items.len); // reload replaced it
    try t.expectEqual(@as(i32, 4), s.findSpace(4).?.id);
}
