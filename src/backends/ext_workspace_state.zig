//! The tables behind `ext-workspace-v1`: which workspaces exist, which group
//! holds them, which outputs each group sits on, and what the taskbar should
//! draw for each of them.
//!
//! A plain value type with no protocol proxy of its own, so every mutation is
//! reachable from a fixture. The reads are in `ext_workspace_query.zig`, the
//! protocol binding in `ext_workspace.zig`.

const std = @import("std");
const wl = @import("../wl/c.zig").wl;
const desk = @import("desk.zig");

pub const Notify = desk.Notify;

pub const Ws = *wl.ext_workspace_handle_v1;
pub const GroupHandle = *wl.ext_workspace_group_handle_v1;
pub const Output = *wl.wl_output;

/// The two state bits this backend reads. `u32` because that is what the
/// protocol hands the listener — the `c_int` the header defines would not even
/// fit a `&` against it.
pub const state_active: u32 = @intCast(wl.EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE);
pub const state_urgent: u32 = @intCast(wl.EXT_WORKSPACE_HANDLE_V1_STATE_URGENT);

pub const Group = struct {
    handle: GroupHandle,
    outs: std.ArrayList(Output) = .empty,
    ws: std.ArrayList(Ws) = .empty,
};

pub const Tables = struct {
    alloc: std.mem.Allocator,
    groups: std.ArrayList(Group) = .empty,
    regions: std.array_hash_map.Auto(Ws, desk.Region) = .empty,
    notify: ?Notify = null,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
        self.groups.deinit(self.alloc);
        self.regions.deinit(self.alloc);
    }

    /// Drops every record. The proxies are somebody else's problem: `finished`
    /// leaves the handles to the protocol, and teardown never gets here first.
    pub fn clear(self: *Self) void {
        var it = self.regions.iterator();
        while (it.next()) |e| desk.freeRegion(self.alloc, e.value_ptr.*);
        self.regions.clearRetainingCapacity();

        for (self.groups.items) |*g| {
            g.outs.deinit(self.alloc);
            g.ws.deinit(self.alloc);
        }
        self.groups.clearRetainingCapacity();
    }

    // -- groups ------------------------------------------------------------

    pub fn addGroup(self: *Self, handle: GroupHandle) !void {
        try self.groups.append(self.alloc, .{ .handle = handle });
    }

    pub fn groupFor(self: *Self, handle: GroupHandle) ?*Group {
        for (self.groups.items) |*g| {
            if (g.handle == handle) return g;
        }
        return null;
    }

    /// `removed`. Drops the record only — destroying the handle is the
    /// listener's job, and it is the only place that knows there is one.
    pub fn removeGroup(self: *Self, handle: GroupHandle) void {
        const g = self.groupFor(handle) orelse return;
        const idx: usize = @intFromPtr(g) - @intFromPtr(self.groups.items.ptr);
        g.outs.deinit(self.alloc);
        g.ws.deinit(self.alloc);
        _ = self.groups.orderedRemove(idx);
    }

    /// `output_enter`/`output_leave`. Only the first group that matches is
    /// touched; later duplicates are left alone.
    pub fn groupOutput(self: *Self, handle: GroupHandle, output: Output, entered: bool) void {
        const g = self.groupFor(handle) orelse return;
        if (entered) {
            g.outs.append(self.alloc, output) catch {};
        } else {
            removeAll(Output, &g.outs, output);
        }
    }

    pub fn groupWorkspace(self: *Self, handle: GroupHandle, w: Ws, entered: bool) void {
        const g = self.groupFor(handle) orelse return;
        if (entered) {
            g.ws.append(self.alloc, w) catch {};
        } else {
            removeAll(Ws, &g.ws, w);
        }
    }

    // -- workspaces --------------------------------------------------------

    pub fn addWorkspace(self: *Self, w: Ws) !void {
        // `emplace`: a workspace we already track keeps the values it has.
        const gop = try self.regions.getOrPut(self.alloc, w);
        if (!gop.found_existing) gop.value_ptr.* = .{};
    }

    pub fn regionOf(self: *Self, w: Ws) ?*desk.Region {
        return self.regions.getPtr(w);
    }

    /// `removed`. The handle stays in its group — it
    /// never had to, because every reader consults this table first.
    pub fn removeWorkspace(self: *Self, w: Ws) void {
        if (self.regions.fetchOrderedRemove(w)) |kv| desk.freeRegion(self.alloc, kv.value);
    }

    pub fn setWorkspaceId(self: *Self, w: Ws, id: []const u8) void {
        const r = self.regionOf(w) orelse return;
        setOwned(self.alloc, &r.id, id);
    }

    pub fn setWorkspaceName(self: *Self, w: Ws, n: []const u8) void {
        const r = self.regionOf(w) orelse return;
        setOwned(self.alloc, &r.name, n);
    }

    /// The protocol's `wl_array`, unwrapped into `setCoordinates`. A non-empty
    /// array with no backing store is not a coordinate list anyone can read —
    /// so it counts as none.
    pub fn setWorkspaceCoordinates(self: *Self, w: Ws, coordinates: ?*wl.wl_array) void {
        const arr = coordinates orelse {
            self.setCoordinates(w, &.{});
            return;
        };
        if (arr.data == null) {
            self.setCoordinates(w, &.{});
            return;
        }
        const count = arr.size / @sizeOf(u32);
        if (count == 0) {
            self.setCoordinates(w, &.{});
            return;
        }
        const words: [*]const u32 = @ptrCast(@alignCast(arr.data.?));
        self.setCoordinates(w, words[0..count]);
    }

    /// Coordinates straight from a slice. The slice is copied, so it may point
    /// straight at the dispatch buffer.
    pub fn setCoordinates(self: *Self, w: Ws, words: []const u32) void {
        const r = self.regionOf(w) orelse return;
        var fresh: []const u32 = &.{};
        if (words.len > 0) fresh = self.alloc.dupe(u32, words) catch &.{};
        if (r.coordinates.len > 0) self.alloc.free(r.coordinates);
        r.coordinates = fresh;
    }

    /// Unlike id/name/coordinates, a state change is the one thing worth
    /// announcing — and only when the visible flags actually moved. Returns
    /// whether they did, so a caller with more work to do can tell.
    pub fn setWorkspaceState(self: *Self, w: Ws, state: u32) bool {
        const r = self.regionOf(w) orelse return false;
        const active = (state & state_active) != 0;
        const urgent = (state & state_urgent) != 0;
        if (r.active == active and r.urgent == urgent) return false;
        r.active = active;
        r.urgent = urgent;
        self.fire();
        return true;
    }

    /// The `done` after a batch of changes: always news, unlike any one change.
    pub fn fire(self: *Self) void {
        if (self.notify) |n| n.run();
    }
};

// Plain helpers

/// Erase-all: every occurrence, order preserved.
fn removeAll(comptime T: type, list: *std.ArrayList(T), needle: T) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == needle) {
            _ = list.orderedRemove(i);
        } else i += 1;
    }
}

/// The protocol hands us the dispatch buffer, so every string is copied.
fn setOwned(alloc: std.mem.Allocator, dst: *[]const u8, src: []const u8) void {
    const owned = if (src.len == 0) "" else alloc.dupe(u8, src) catch "";
    if (dst.*.len > 0) alloc.free(dst.*);
    dst.* = owned;
}

// Tests

const t = std.testing;

/// Stand-ins for protocol handles. All three are opaque, so nothing ever
/// dereferences them.
pub fn fakeWs(addr: usize) Ws {
    return @ptrFromInt(addr);
}

pub fn fakeGroup(addr: usize) GroupHandle {
    return @ptrFromInt(addr);
}

pub fn fakeOutput(addr: usize) Output {
    return @ptrFromInt(addr);
}

pub const Counter = struct {
    calls: usize = 0,

    pub fn note(ctx: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.calls += 1;
    }
};

/// One group on `out1` holding two named workspaces and one that never got a
/// name, plus two workspaces nobody grouped.
pub const Fixture = struct {
    out1: Output,
    out2: Output,
    w1: Ws,
    w2: Ws,
    w3: Ws,
    w4: Ws,
    wn: Ws,
};

pub fn fixture(tab: *Tables) !Fixture {
    const out1 = fakeOutput(0x2000);
    const out2 = fakeOutput(0x2100);
    const w1 = fakeWs(0x3000);
    const w2 = fakeWs(0x3100);
    const w3 = fakeWs(0x3200);
    const w4 = fakeWs(0x3300);
    const wn = fakeWs(0x3400);

    try tab.addGroup(fakeGroup(0x1000));
    tab.groupOutput(fakeGroup(0x1000), out1, true);
    tab.groupWorkspace(fakeGroup(0x1000), w1, true);
    tab.groupWorkspace(fakeGroup(0x1000), w2, true);
    tab.groupWorkspace(fakeGroup(0x1000), wn, true);

    try tab.addWorkspace(w1);
    tab.setWorkspaceId(w1, "1");
    tab.setWorkspaceName(w1, "one");
    tab.setCoordinates(w1, &.{ 1, 0, 0 });

    try tab.addWorkspace(w2);
    tab.setWorkspaceId(w2, "2");
    tab.setWorkspaceName(w2, "two");
    tab.setCoordinates(w2, &.{ 2, 0, 0 });

    try tab.addWorkspace(w3);
    tab.setWorkspaceId(w3, "3");
    tab.setWorkspaceName(w3, "three");
    tab.setCoordinates(w3, &.{ 3, 0, 0 });

    // No group ever claimed it.
    try tab.addWorkspace(w4);
    tab.setWorkspaceId(w4, "4");
    tab.setWorkspaceName(w4, "four");
    tab.setCoordinates(w4, &.{ 4, 0, 0 });

    // Named only by its id — the taskbar has nothing to draw.
    try tab.addWorkspace(wn);
    tab.setWorkspaceId(wn, "n");
    tab.setCoordinates(wn, &.{ 9, 0, 0 });

    return .{ .out1 = out1, .out2 = out2, .w1 = w1, .w2 = w2, .w3 = w3, .w4 = w4, .wn = wn };
}

test "ext-workspace-state: ids, names and coordinates land in the table" {
    var tab = Tables.init(t.allocator);
    defer tab.deinit();
    const f = try fixture(&tab);

    try t.expectEqual(@as(usize, 5), tab.regions.count());
    try t.expectEqualStrings("one", tab.regionOf(f.w1).?.name);
    try t.expectEqual(@as(u32, 2), tab.regionOf(f.w2).?.coordinates[0]);
    try t.expectEqual(@as(usize, 0), tab.regionOf(f.wn).?.name.len);

    // Re-adding a workspace keeps what it already holds, like `emplace`.
    try tab.addWorkspace(f.w1);
    tab.setWorkspaceId(f.w1, "1");
    try t.expectEqualStrings("one", tab.regionOf(f.w1).?.name);

    // An unknown handle is nobody's region, so nothing is invented for it.
    tab.setWorkspaceId(fakeWs(0x9999), "x");
    tab.setWorkspaceName(fakeWs(0x9999), "x");
    tab.setCoordinates(fakeWs(0x9999), &.{1});
    try t.expectEqual(@as(usize, 5), tab.regions.count());

    // A null array means "no coordinates".
    tab.setWorkspaceCoordinates(f.w4, null);
    try t.expectEqual(@as(usize, 0), tab.regionOf(f.w4).?.coordinates.len);

    // …and the protocol path unwraps into exactly the same store.
    var pair: [2]u32 = .{ 7, 0 };
    var arr = std.mem.zeroes(wl.wl_array);
    arr.size = 8;
    arr.data = @ptrCast(&pair);
    tab.setWorkspaceCoordinates(f.w4, &arr);
    try t.expectEqual(@as(u32, 7), tab.regionOf(f.w4).?.coordinates[0]);
    tab.setWorkspaceCoordinates(f.w4, null);
}

test "ext-workspace-state: only a state change announces itself" {
    var tab = Tables.init(t.allocator);
    defer tab.deinit();
    const f = try fixture(&tab);

    var counter = Counter{};
    tab.notify = .{ .ctx = &counter, .call = Counter.note };

    try t.expect(tab.setWorkspaceState(f.w1, state_active));
    try t.expect(tab.regionOf(f.w1).?.active);
    try t.expectEqual(@as(usize, 1), counter.calls);

    // The same word again is not news.
    try t.expect(!tab.setWorkspaceState(f.w1, state_active));
    try t.expectEqual(@as(usize, 1), counter.calls);

    try t.expect(tab.setWorkspaceState(f.w1, state_urgent));
    try t.expect(tab.regionOf(f.w1).?.urgent);
    try t.expectEqual(@as(usize, 2), counter.calls);

    // A handle nobody tracks neither changes nor reports.
    try t.expect(!tab.setWorkspaceState(fakeWs(0x9999), 1));
    try t.expectEqual(@as(usize, 2), counter.calls);

    tab.fire();
    try t.expectEqual(@as(usize, 3), counter.calls);
}

test "ext-workspace-state: removing a workspace or a group leaves the rest standing" {
    var tab = Tables.init(t.allocator);
    defer tab.deinit();
    const f = try fixture(&tab);

    tab.removeWorkspace(f.w2);
    try t.expect(tab.regionOf(f.w2) == null);
    try t.expectEqual(@as(usize, 4), tab.regions.count());
    // The group list is never edited here, and every reader consults the
    // region table first, so the stale handle is inert.
    try t.expectEqual(@as(usize, 3), tab.groups.items[0].ws.items.len);

    tab.groupWorkspace(fakeGroup(0x1000), f.w2, false);
    try t.expectEqual(@as(usize, 2), tab.groups.items[0].ws.items.len);
    tab.groupOutput(fakeGroup(0x1000), f.out1, false);
    try t.expectEqual(@as(usize, 0), tab.groups.items[0].outs.items.len);

    tab.removeGroup(fakeGroup(0x1000));
    try t.expectEqual(@as(usize, 0), tab.groups.items.len);
    try t.expect(tab.groupFor(fakeGroup(0x1000)) == null);

    // Removing what is not there changes nothing.
    tab.removeGroup(fakeGroup(0x1000));
    tab.removeWorkspace(f.w1);
    try t.expectEqual(@as(usize, 3), tab.regions.count());
    tab.clear();
    try t.expectEqual(@as(usize, 0), tab.regions.count());
    try t.expectEqual(@as(usize, 0), tab.groups.items.len);
}
