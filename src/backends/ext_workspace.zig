//! `ext-workspace-v1`, the protocol side: bind the manager, keep the listener
//! alive, and turn a `jumpTo` into a workspace-activation request.
//!
//! The model is split out — `ext_workspace_state.zig` for the tables and their mutations,
//! `ext_workspace_query.zig` for reading them back — three jobs, only the third needs a compositor at all.
//!
//! Every proxy call is gated on `manager != null`. That is not only a test
//! convenience: `finished` nulls the manager *before* dropping the records, so a
//! null manager and a live handle have never coexisted. The gate destroys unconditionally while staying inert when a test injects fake
//! handles.

const std = @import("std");
const wl = @import("../wl/c.zig").wl;
const desk = @import("desk.zig");
const st = @import("ext_workspace_state.zig");
const ws_query = @import("ext_workspace_query.zig");

pub const Notify = st.Notify;
pub const Tables = st.Tables;

const Ws = st.Ws;
const Output = st.Output;

pub const Manager = struct {
    alloc: std.mem.Allocator,
    manager: ?*wl.ext_workspace_manager_v1 = null,
    tables: Tables,

    const Self = @This();

    pub const name: []const u8 = "ext-workspace";

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc, .tables = Tables.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.teardown();
        self.tables.deinit();
    }

    /// Binds the ext-workspace protocol manager.
    pub fn bindExtProtocol(self: *Self, mgr: ?*wl.ext_workspace_manager_v1) void {
        const m = mgr orelse return;
        self.manager = m;
        _ = wl.ext_workspace_manager_v1_add_listener(m, &manager_listener, self);
    }

    pub fn ready(self: *const Self) bool {
        return self.manager != null;
    }

    pub fn onStateChange(self: *Self, cb: Notify) void {
        self.tables.notify = cb;
    }

    /// Destroys every proxy this backend still holds and drops the records,
    /// whether or not there is a manager to stop. Safe to call twice.
    pub fn teardown(self: *Self) void {
        if (self.manager != null) {
            for (self.tables.regions.keys()) |w| wl.ext_workspace_handle_v1_destroy(w);
            for (self.tables.groups.items) |g| wl.ext_workspace_group_handle_v1_destroy(g.handle);
            if (self.manager) |m| {
                wl.ext_workspace_manager_v1_stop(m);
                wl.ext_workspace_manager_v1_destroy(m);
            }
            self.manager = null;
        }
        self.tables.clear();
    }

    // -- the interface, over somebody else's tables -------------------------

    pub fn allRegions(self: *Self) ![]desk.Region {
        return ws_query.allRegions(&self.tables);
    }

    pub fn regionsOnOutput(self: *Self, output: ?Output) ![]desk.Region {
        return ws_query.regionsOnOutput(&self.tables, output);
    }

    pub fn jumpTo(self: *Self, id: []const u8) void {
        const w = ws_query.handleForId(&self.tables, id) orelse return;
        self.sendActivate(w);
    }

    /// `jumpTo`, restricted to a group on `output`, falling back to the global
    /// search when the id belongs somewhere else.
    pub fn jumpToOnOutput(self: *Self, output: ?Output, id: []const u8) void {
        if (self.manager == null) return;
        const o = output orelse return;
        if (ws_query.handleOnOutputForId(&self.tables, o, id)) |w| {
            self.sendActivate(w);
            return;
        }
        self.jumpTo(id);
    }

    /// Same, matched the way the overview re-finds a workspace it only knows by
    /// shape, falling back to the id when nothing matched by shape either.
    pub fn jumpToRegion(self: *Self, output: ?Output, ws: desk.Region) void {
        if (self.manager == null) return;
        const o = output orelse return;
        if (ws_query.handleOnOutputForRegion(&self.tables, o, ws)) |w| {
            self.sendActivate(w);
            return;
        }
        if (ws.id.len != 0) self.jumpTo(ws.id);
    }

    fn sendActivate(self: *Self, w: Ws) void {
        const m = self.manager orelse return;
        wl.ext_workspace_handle_v1_activate(w);
        wl.ext_workspace_manager_v1_commit(m);
    }

    /// The `done` after a batch of changes: always news, unlike any one change.
    pub fn managerDone(self: *Self) void {
        self.tables.fire();
    }

    /// `finished`: the compositor stopped advertising. The protocol destroys the
    /// handles itself, which is why this only drops the records.
    pub fn managerFinished(self: *Self) void {
        self.manager = null;
        self.tables.clear();
    }

    // -- Wayland callbacks -------------------------------------------------
    //
    // Each is a table read or a call into `Tables`; the two that remove
    // something also let go of the handle, because they are the only place that
    // knows which listener is running.

    fn fromData(data: ?*anyopaque) ?*Self {
        return @ptrCast(@alignCast(data orelse return null));
    }

    fn noteGroupCreated(data: ?*anyopaque, m: ?*wl.ext_workspace_manager_v1, g: ?*wl.ext_workspace_group_handle_v1) callconv(.c) void {
        _ = m;
        const self = fromData(data) orelse return;
        const handle = g orelse return;
        self.tables.addGroup(handle) catch return;
        if (self.manager != null) {
            _ = wl.ext_workspace_group_handle_v1_add_listener(handle, &group_listener, self);
        }
    }

    fn noteGroupRemoved(data: ?*anyopaque, g: ?*wl.ext_workspace_group_handle_v1) callconv(.c) void {
        const self = fromData(data) orelse return;
        const handle = g orelse return;
        self.tables.removeGroup(handle);
        if (self.manager != null) wl.ext_workspace_group_handle_v1_destroy(handle);
    }

    fn noteGroupOutputEnter(data: ?*anyopaque, g: ?*wl.ext_workspace_group_handle_v1, output: ?*wl.wl_output) callconv(.c) void {
        const self = fromData(data) orelse return;
        const handle = g orelse return;
        const o = output orelse return;
        self.tables.groupOutput(handle, o, true);
    }

    fn noteGroupOutputLeave(data: ?*anyopaque, g: ?*wl.ext_workspace_group_handle_v1, output: ?*wl.wl_output) callconv(.c) void {
        const self = fromData(data) orelse return;
        const handle = g orelse return;
        const o = output orelse return;
        self.tables.groupOutput(handle, o, false);
    }

    fn noteGroupWorkspaceEnter(data: ?*anyopaque, g: ?*wl.ext_workspace_group_handle_v1, w: ?*wl.ext_workspace_handle_v1) callconv(.c) void {
        const self = fromData(data) orelse return;
        const handle = g orelse return;
        const ws = w orelse return;
        self.tables.groupWorkspace(handle, ws, true);
    }

    fn noteGroupWorkspaceLeave(data: ?*anyopaque, g: ?*wl.ext_workspace_group_handle_v1, w: ?*wl.ext_workspace_handle_v1) callconv(.c) void {
        const self = fromData(data) orelse return;
        const handle = g orelse return;
        const ws = w orelse return;
        self.tables.groupWorkspace(handle, ws, false);
    }

    fn noteGroupCapabilities(data: ?*anyopaque, g: ?*wl.ext_workspace_group_handle_v1, caps: u32) callconv(.c) void {
        _ = data;
        _ = g;
        _ = caps;
    }

    fn noteWorkspaceCreated(data: ?*anyopaque, m: ?*wl.ext_workspace_manager_v1, w: ?*wl.ext_workspace_handle_v1) callconv(.c) void {
        _ = m;
        const self = fromData(data) orelse return;
        const ws = w orelse return;
        self.tables.addWorkspace(ws) catch return;
        if (self.manager != null) {
            _ = wl.ext_workspace_handle_v1_add_listener(ws, &workspace_listener, self);
        }
    }

    fn noteWorkspaceId(data: ?*anyopaque, w: ?*wl.ext_workspace_handle_v1, id: [*c]const u8) callconv(.c) void {
        const self = fromData(data) orelse return;
        const ws = w orelse return;
        self.tables.setWorkspaceId(ws, cstr(id));
    }

    fn noteWorkspaceName(data: ?*anyopaque, w: ?*wl.ext_workspace_handle_v1, n: [*c]const u8) callconv(.c) void {
        const self = fromData(data) orelse return;
        const ws = w orelse return;
        self.tables.setWorkspaceName(ws, cstr(n));
    }

    fn noteWorkspaceCoords(data: ?*anyopaque, w: ?*wl.ext_workspace_handle_v1, coordinates: [*c]wl.wl_array) callconv(.c) void {
        const self = fromData(data) orelse return;
        const ws = w orelse return;
        self.tables.setWorkspaceCoordinates(ws, coordinates);
    }

    fn noteWorkspaceState(data: ?*anyopaque, w: ?*wl.ext_workspace_handle_v1, state: u32) callconv(.c) void {
        const self = fromData(data) orelse return;
        const ws = w orelse return;
        _ = self.tables.setWorkspaceState(ws, state);
    }

    fn noteWorkspaceCaps(data: ?*anyopaque, w: ?*wl.ext_workspace_handle_v1, caps: u32) callconv(.c) void {
        _ = data;
        _ = w;
        _ = caps;
    }

    fn noteWorkspaceRemoved(data: ?*anyopaque, w: ?*wl.ext_workspace_handle_v1) callconv(.c) void {
        const self = fromData(data) orelse return;
        const ws = w orelse return;
        self.tables.removeWorkspace(ws);
        if (self.manager != null) wl.ext_workspace_handle_v1_destroy(ws);
    }

    fn noteManagerDone(data: ?*anyopaque, m: ?*wl.ext_workspace_manager_v1) callconv(.c) void {
        _ = m;
        const self = fromData(data) orelse return;
        self.managerDone();
    }

    fn noteManagerFinished(data: ?*anyopaque, m: ?*wl.ext_workspace_manager_v1) callconv(.c) void {
        _ = m;
        const self = fromData(data) orelse return;
        self.managerFinished();
    }

    const group_listener = wl.ext_workspace_group_handle_v1_listener{
        .capabilities = noteGroupCapabilities,
        .output_enter = noteGroupOutputEnter,
        .output_leave = noteGroupOutputLeave,
        .workspace_enter = noteGroupWorkspaceEnter,
        .workspace_leave = noteGroupWorkspaceLeave,
        .removed = noteGroupRemoved,
    };

    const workspace_listener = wl.ext_workspace_handle_v1_listener{
        .id = noteWorkspaceId,
        .name = noteWorkspaceName,
        .coordinates = noteWorkspaceCoords,
        .state = noteWorkspaceState,
        .capabilities = noteWorkspaceCaps,
        .removed = noteWorkspaceRemoved,
    };

    const manager_listener = wl.ext_workspace_manager_v1_listener{
        .workspace_group = noteGroupCreated,
        .workspace = noteWorkspaceCreated,
        .done = noteManagerDone,
        .finished = noteManagerFinished,
    };
};

fn cstr(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.sliceTo(p, 0);
}

// Tests

const t = std.testing;

test "ext-workspace: a fresh manager is never ready and holds nothing" {
    var m = Manager.init(t.allocator);
    defer m.deinit();

    try t.expect(!m.ready());
    try t.expectEqual(@as(usize, 0), m.tables.groups.items.len);
    try t.expectEqual(@as(usize, 0), m.tables.regions.count());
    try t.expectEqualStrings("ext-workspace", Manager.name);

    // No manager means no listener to register and no proxy to touch.
    m.bindExtProtocol(null);
    try t.expect(!m.ready());
}

test "ext-workspace: jumps stay inert while unbound" {
    var m = Manager.init(t.allocator);
    defer m.deinit();
    const f = try st.fixture(&m.tables);

    const exact = desk.Region{ .id = "2", .name = "two", .coordinates = &.{ 2, 0, 0 } };
    m.jumpTo("2");
    m.jumpToOnOutput(f.out1, "2");
    m.jumpToRegion(f.out1, exact);
    try t.expect(!m.ready());
    // The forwarders work over the same tables whether or not a proxy exists —
    // reading is never gated, only asking the compositor to do something is.
    if (m.allRegions()) |regions| {
        defer desk.freeRegionList(t.allocator, regions);
        try t.expectEqual(@as(usize, 4), regions.len);
    } else |_| try t.expect(false);
    if (m.regionsOnOutput(f.out1)) |on_out| {
        defer desk.freeRegionList(t.allocator, on_out);
        try t.expectEqual(@as(usize, 2), on_out.len);
    } else |_| try t.expect(false);
}

test "ext-workspace: teardown and finished drop the records without touching proxies" {
    var m = Manager.init(t.allocator);
    defer m.deinit();
    _ = try st.fixture(&m.tables);
    var counter = st.Counter{};
    m.onStateChange(.{ .ctx = &counter, .call = st.Counter.note });

    m.managerFinished();
    try t.expect(!m.ready());
    try t.expectEqual(@as(usize, 0), m.tables.regions.count());
    try t.expectEqual(@as(usize, 0), m.tables.groups.items.len);

    // Records come back; teardown clears them again and stays safe to repeat.
    try m.tables.addWorkspace(st.fakeWs(0x3000));
    m.managerDone();
    try t.expectEqual(@as(usize, 1), counter.calls);
    m.teardown();
    try t.expectEqual(@as(usize, 0), m.tables.regions.count());
    m.teardown();
    try t.expectEqual(@as(usize, 0), m.tables.groups.items.len);
    try t.expectEqual(@as(usize, 1), counter.calls);
}

test "ext-workspace: live enumeration when advertised" {
    const Conn = @import("../wl/connection.zig").Connection;
    var conn = Conn.init(t.allocator);
    defer conn.deinit();
    if (!conn.connect(null)) return error.SkipZigTest;
    var bound = Conn.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    const mgr = bound.workspace_manager orelse return error.SkipZigTest;
    var m = Manager.init(t.allocator);
    defer m.deinit();
    m.bindExtProtocol(mgr);
    try t.expect(m.ready());
    var ticks: u32 = 0;
    while (ticks < 30) : (ticks += 1) {
        if (!conn.roundtrip()) break;
    }
    const regions = try m.allRegions();
    defer desk.freeRegionList(t.allocator, regions);
}
