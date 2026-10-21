//! `zwlr_foreign_toplevel_manager_v1`: every toplevel the compositor reports,
//! with its title, `app_id`, and state bits.
//!
//! The `ext_foreign_toplevel_*
//!` side already lives in `foreign.zig`; this is the wlr one, which is what the
//! panel/taskbar/overview read windows from (it carries `activated` and the
//! state bits, which the ext list does not).
//!
//! One entry per handle in a flat `ArrayList`, looked up by handle on every
//! callback — and a listener never holds a
//! pointer into storage an append may relocate.
//!
//! Two things are guarded rather than assumed, because a Wayland proxy outlives
//! its usefulness the moment the display errors:
//!
//! * every *destructive* proxy call goes through `canProxy`, which needs a
//!   display and a healthy one at that;
//! * registering the per-handle listener is skipped without a display.
//!
//! `attach` therefore insists on both arguments. Both callers pass the connection's display, and the shutdown
//! guard is only meaningful when there is one.

const std = @import("std");
const wl = @import("../c.zig").wl;

/// An unowned protocol handle. Never dereferenced by this file except through
/// the `canProxy` gate, so a test can hand one in from a fixture address.
pub const Handle = ?*wl.zwlr_foreign_toplevel_handle_v1;

pub const Toplevel = struct {
    handle: Handle = null,
    app_id: []const u8 = "",
    title: []const u8 = "",
    activated: bool = false,
    minimized: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    /// Set by `closed`; the entry stays until `pruneClosed` removes it.
    closed: bool = false,
    serial: u64 = 0,
};

/// The three hooks, set together. They always belong to one
/// owner, so they travel together with a single context.
pub const Hooks = struct {
    ctx: *anyopaque,
    handleDestroyed: ?*const fn (ctx: *anyopaque, handle: Handle) void = null,
    handleDone: ?*const fn (ctx: *anyopaque, handle: Handle) void = null,
    visualDirty: ?*const fn (ctx: *anyopaque) void = null,
};

const SnapshotCb = struct {
    token: u64,
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque) void,
};

pub const ForeignToplevels = struct {
    alloc: std.mem.Allocator,
    display: ?*wl.wl_display = null,
    mgr: ?*wl.zwlr_foreign_toplevel_manager_v1 = null,
    toplevels: std.ArrayList(Toplevel) = .empty,
    next_serial: u64 = 1,
    hooks: ?Hooks = null,
    snapshot_cbs: std.ArrayList(SnapshotCb) = .empty,
    next_snapshot_cb_token: u64 = 1,
    /// `pruneClosed` fires the snapshot callbacks, which may re-enter it; the
    /// `pruning_closed` flag keeps that from recursing.
    pruning_closed: bool = false,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.toplevels.deinit(self.alloc);
        self.snapshot_cbs.deinit(self.alloc);
    }

    // -- protocol ----------------------------------------------------------

    pub fn attach(self: *Self, mgr: ?*wl.zwlr_foreign_toplevel_manager_v1, display: ?*wl.wl_display) void {
        const manager = mgr orelse return;
        const d = display orelse return;
        if (self.mgr == manager) return;
        self.mgr = manager;
        self.display = d;
        _ = wl.zwlr_foreign_toplevel_manager_v1_add_listener(manager, &manager_listener, self);
    }

    pub fn shutdown(self: *Self) void {
        self.hooks = null;
        self.snapshot_cbs.clearRetainingCapacity();

        if (self.canProxy()) {
            for (self.toplevels.items) |*tl| {
                if (tl.handle) |h| {
                    wl.zwlr_foreign_toplevel_handle_v1_destroy(h);
                    tl.handle = null;
                }
            }
            if (self.mgr) |m| {
                wl.zwlr_foreign_toplevel_manager_v1_stop(m);
                wl.zwlr_foreign_toplevel_manager_v1_destroy(m);
                self.mgr = null;
            }
        }

        for (self.toplevels.items) |tl| freeStrings(self.alloc, tl);
        self.toplevels.clearRetainingCapacity();
    }

    /// Proxy calls are only safe while we have a display *and* that display has
    /// not errored — proxy calls segfault once the display has errored.
    fn canProxy(self: *const Self) bool {
        const d = self.display orelse return false;
        return wl.wl_display_get_error(d) == 0;
    }

    // -- queries -----------------------------------------------------------

    pub fn size(self: *const Self) usize {
        return self.toplevels.items.len;
    }

    pub fn list(self: *const Self) []const Toplevel {
        return self.toplevels.items;
    }

    pub fn find(self: *Self, handle: Handle) ?*Toplevel {
        const idx = self.findIndex(handle) orelse return null;
        return &self.toplevels.items[idx];
    }

    pub fn findIndex(self: *Self, handle: Handle) ?usize {
        for (self.toplevels.items, 0..) |tl, i| {
            if (tl.handle == handle) return i;
        }
        return null;
    }

    /// `zwlr_foreign_toplevel_handle_v1_activate` for one entry — the call made
    /// when you click an app that
    /// already has a window. Guarded like every other proxy call here: no
    /// handle, a closed window, no seat, or a display that has errored all
    /// mean "there is nothing safe to ask".
    pub fn raiseToplevel(self: *Self, tl: *const Toplevel, seat: ?*wl.wl_seat) bool {
        const h = tl.handle orelse return false;
        if (tl.closed) return false;
        if (seat == null) return false;
        if (!self.canProxy()) return false;
        wl.zwlr_foreign_toplevel_handle_v1_activate(h, seat);
        return true;
    }

    // -- observer registry -------------------------------------------------

    pub fn addSnapshotCb(self: *Self, ctx: *anyopaque, call: *const fn (ctx: *anyopaque) void) !u64 {
        const token = self.next_snapshot_cb_token;
        self.next_snapshot_cb_token += 1;
        try self.snapshot_cbs.append(self.alloc, .{ .token = token, .ctx = ctx, .call = call });
        return token;
    }

    pub fn removeSnapshotCb(self: *Self, token: u64) void {
        var i: usize = 0;
        while (i < self.snapshot_cbs.items.len) {
            if (self.snapshot_cbs.items[i].token == token) {
                _ = self.snapshot_cbs.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn notifySnapshotCbs(self: *Self) void {
        // Re-read the list on every step rather than holding a slice across the
        // call: a callback that appends may relocate the backing array.
        var i: usize = 0;
        while (i < self.snapshot_cbs.items.len) {
            const cb = self.snapshot_cbs.items[i];
            i += 1;
            cb.call(cb.ctx);
        }
    }

    /// Drops the entries whose window has gone away. Order is preserved, which
    /// is what `erase(remove_if(...))` gives.
    pub fn pruneClosed(self: *Self) void {
        if (self.pruning_closed) return;
        self.pruning_closed = true;
        defer self.pruning_closed = false;

        var i: usize = 0;
        while (i < self.toplevels.items.len) {
            if (self.toplevels.items[i].closed) {
                freeStrings(self.alloc, self.toplevels.items[i]);
                _ = self.toplevels.orderedRemove(i);
            } else i += 1;
        }
        self.notifySnapshotCbs();
    }

    fn notifyVisualDirty(self: *Self) void {
        if (self.hooks) |h| {
            if (h.visualDirty) |cb| cb(h.ctx);
        }
    }

    // -- state transitions (the callback bodies, minus the proxy calls) ----

    /// Appends a fresh entry for a newly announced handle. Returns null when the
    /// list cannot grow, which the caller turns into "this window is not tracked".
    pub fn trackHandle(self: *Self, handle: Handle) ?*Toplevel {
        const serial = self.next_serial;
        self.next_serial += 1;
        self.toplevels.append(self.alloc, .{ .handle = handle, .serial = serial }) catch return null;
        return &self.toplevels.items[self.toplevels.items.len - 1];
    }

    pub fn applyTitle(self: *Self, handle: Handle, title: [*c]const u8) void {
        const tl = self.find(handle) orelse return;
        setString(self.alloc, &tl.title, cstr(title));
    }

    pub fn applyAppId(self: *Self, handle: Handle, app_id: [*c]const u8) void {
        const tl = self.find(handle) orelse return;
        setString(self.alloc, &tl.app_id, cstr(app_id));
    }

    /// Decodes the state word array. Anything the wire cannot be trusted about
    /// — a null array, a size that is not a whole number of words, a non-empty
    /// array with no backing store — leaves the flags exactly as they were.
    pub fn applyState(self: *Self, handle: Handle, states: ?*wl.wl_array) void {
        const tl = self.find(handle) orelse return;
        const arr = states orelse return;
        if (arr.size > 0 and arr.data == null) return;
        if (arr.size % @sizeOf(u32) != 0) return;

        var activated = false;
        var minimized = false;
        var maximized = false;
        var fullscreen = false;
        if (arr.size > 0) {
            const entries: [*]const u32 = @ptrCast(@alignCast(arr.data.?));
            const count = arr.size / @sizeOf(u32);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                switch (entries[i]) {
                    wl.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED => activated = true,
                    wl.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED => minimized = true,
                    wl.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED => maximized = true,
                    wl.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN => fullscreen = true,
                    else => {},
                }
            }
        }
        tl.activated = activated;
        tl.minimized = minimized;
        tl.maximized = maximized;
        tl.fullscreen = fullscreen;
    }

    /// The window went away: flag it, drop the handle, and announce it. The
    /// entry survives until `pruneClosed`, which is what lets a caller keep
    /// rendering the last known state until it decides to forget.
    pub fn markClosed(self: *Self, handle: Handle) void {
        const tl = self.find(handle) orelse return;
        tl.closed = true;
        if (self.hooks) |h| {
            if (h.handleDestroyed) |cb| cb(h.ctx, handle);
        }
        if (tl.handle) |raw| {
            if (self.canProxy()) wl.zwlr_foreign_toplevel_handle_v1_destroy(raw);
            tl.handle = null;
        }
        self.notifyVisualDirty();
        self.notifySnapshotCbs();
    }

    /// `manager.finished`: the compositor stopped advertising; the proxy is gone
    /// from our side but the windows stay known.
    pub fn markDone(self: *Self) void {
        self.mgr = null;
        self.notifyVisualDirty();
        self.notifySnapshotCbs();
    }

    // -- Wayland callbacks -------------------------------------------------

    fn fromData(data: ?*anyopaque) ?*Self {
        return @ptrCast(@alignCast(data orelse return null));
    }

    fn onTitle(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, title: [*c]const u8) callconv(.c) void {
        const self = fromData(data) orelse return;
        self.applyTitle(handle, title);
    }

    fn onAppId(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, app_id: [*c]const u8) callconv(.c) void {
        const self = fromData(data) orelse return;
        self.applyAppId(handle, app_id);
    }

    fn onOutputEnter(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, output: ?*wl.wl_output) callconv(.c) void {
        _ = data;
        _ = handle;
        _ = output;
    }

    fn onOutputLeave(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, output: ?*wl.wl_output) callconv(.c) void {
        _ = data;
        _ = handle;
        _ = output;
    }

    fn onState(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, states: [*c]wl.wl_array) callconv(.c) void {
        const self = fromData(data) orelse return;
        self.applyState(handle, states);
    }

    fn onDone(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
        const self = fromData(data) orelse return;
        if (self.hooks) |h| {
            if (h.handleDone) |cb| cb(h.ctx, handle);
        }
        self.notifyVisualDirty();
        self.notifySnapshotCbs();
    }

    fn noteClosed(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
        const self = fromData(data) orelse return;
        self.markClosed(handle);
    }

    fn onParent(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, parent: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
        _ = data;
        _ = handle;
        _ = parent;
    }

    fn onManagerToplevel(data: ?*anyopaque, mgr: ?*wl.zwlr_foreign_toplevel_manager_v1, toplevel: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
        _ = mgr;
        const self = fromData(data) orelse return;
        if (self.trackHandle(toplevel) == null) return;
        if (self.display != null and toplevel != null) {
            _ = wl.zwlr_foreign_toplevel_handle_v1_add_listener(toplevel, &handle_listener, self);
        }
        self.notifyVisualDirty();
        self.notifySnapshotCbs();
    }

    fn noteManagerFinished(data: ?*anyopaque, mgr: ?*wl.zwlr_foreign_toplevel_manager_v1) callconv(.c) void {
        _ = mgr;
        const self = fromData(data) orelse return;
        self.markDone();
    }

    const handle_listener = wl.zwlr_foreign_toplevel_handle_v1_listener{
        .title = onTitle,
        .app_id = onAppId,
        .output_enter = onOutputEnter,
        .output_leave = onOutputLeave,
        .state = onState,
        .done = onDone,
        .closed = noteClosed,
        .parent = onParent,
    };

    const manager_listener = wl.zwlr_foreign_toplevel_manager_v1_listener{
        .toplevel = onManagerToplevel,
        .finished = noteManagerFinished,
    };
};

// Plain helpers

/// The Wayland dispatch buffer is reused, so every string the protocol hands us
/// has to be copied before we return from the listener.
fn setString(alloc: std.mem.Allocator, dst: *[]const u8, src: []const u8) void {
    const owned = if (src.len == 0) "" else alloc.dupe(u8, src) catch "";
    if (dst.*.len > 0) alloc.free(dst.*);
    dst.* = owned;
}

fn cstr(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.sliceTo(p, 0);
}

fn freeStrings(alloc: std.mem.Allocator, tl: Toplevel) void {
    if (tl.title.len > 0) alloc.free(tl.title);
    if (tl.app_id.len > 0) alloc.free(tl.app_id);
}

// Tests

const t = std.testing;

/// Stand-ins for protocol handles. Both are opaque types, so nothing ever
/// dereferences them — `display` stays null, which is what keeps every proxy
/// call in the file from firing.
fn fakeHandle(addr: usize) Handle {
    return @ptrFromInt(addr);
}

fn fakeManager(addr: usize) ?*wl.zwlr_foreign_toplevel_manager_v1 {
    return @ptrFromInt(addr);
}

const Counter = struct {
    visual: usize = 0,
    done: usize = 0,
    destroyed: usize = 0,
    snapshots: usize = 0,
    last_handle: Handle = null,

    fn hooks(self: *Counter) Hooks {
        return .{
            .ctx = @ptrCast(self),
            .visualDirty = onVisual,
            .handleDone = onDone,
            .handleDestroyed = onDestroyed,
        };
    }

    fn onVisual(ctx: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.visual += 1;
    }

    fn onDone(ctx: *anyopaque, handle: Handle) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.done += 1;
        self.last_handle = handle;
    }

    fn onDestroyed(ctx: *anyopaque, handle: Handle) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.destroyed += 1;
        self.last_handle = handle;
    }

    fn onSnapshot(ctx: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.snapshots += 1;
    }
};

var odd_bytes: [3]u8 = .{ 1, 2, 3 };

fn words(list: []const u32) wl.wl_array {
    var arr = std.mem.zeroes(wl.wl_array);
    arr.size = list.len * @sizeOf(u32);
    arr.data = @ptrCast(@constCast(list.ptr));
    return arr;
}

test "foreign-toplevels: handles arrive in order with their serials" {
    var ft = ForeignToplevels.init(t.allocator);
    defer ft.deinit();

    const a = ft.trackHandle(fakeHandle(0x1000)).?;
    const b = ft.trackHandle(fakeHandle(0x2000)).?;
    try t.expectEqual(@as(u64, 1), a.serial);
    try t.expectEqual(@as(u64, 2), b.serial);
    try t.expectEqual(@as(usize, 2), ft.size());
    try t.expect(ft.find(fakeHandle(0x1000)).? == a);
    try t.expect(ft.find(fakeHandle(0x9999)) == null);

    // Attaching without a display never touches a proxy, and re-attaching the
    // same manager is a no-op even then.
    ft.attach(fakeManager(0x3000), null);
    try t.expect(ft.mgr == null);
}

test "foreign-toplevels: titles and app ids are copied, and unknown handles are dropped" {
    var ft = ForeignToplevels.init(t.allocator);
    defer ft.deinit();

    const h = fakeHandle(0x1000);
    _ = ft.trackHandle(h).?;

    ft.applyTitle(h, "A title");
    ft.applyAppId(h, "otter-term");
    const tl = ft.find(h).?;
    try t.expectEqualStrings("A title", tl.title);
    try t.expectEqualStrings("otter-term", tl.app_id);

    // A handle we never saw must not create an entry, and a null C string is
    // an empty one rather than a crash.
    ft.applyTitle(fakeHandle(0x8888), "ignored");
    ft.applyTitle(h, null);
    try t.expectEqualStrings("", ft.find(h).?.title);
    try t.expectEqual(@as(usize, 1), ft.size());
}

test "foreign-toplevels: state words decode, and a malformed array changes nothing" {
    var ft = ForeignToplevels.init(t.allocator);
    defer ft.deinit();

    const h = fakeHandle(0x1000);
    _ = ft.trackHandle(h).?;

    var full = words(&.{
        wl.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED,
        wl.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN,
        99, // an enum value this protocol version does not define
    });
    ft.applyState(h, &full);
    {
        const tl = ft.find(h).?;
        try t.expect(tl.activated);
        try t.expect(!tl.minimized);
        try t.expect(!tl.maximized);
        try t.expect(tl.fullscreen);
    }

    // Nothing set: an empty array clears the flags, which is how a window that
    // lost focus is reported.
    var none = words(&.{});
    ft.applyState(h, &none);
    try t.expect(!ft.find(h).?.activated);
    try t.expect(!ft.find(h).?.fullscreen);

    // A word count that is not a whole number of words, and a non-empty array
    // with no backing store, both leave the previous flags standing.
    var minimized = words(&.{wl.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED});
    ft.applyState(h, &minimized);
    try t.expect(ft.find(h).?.minimized);

    var odd = std.mem.zeroes(wl.wl_array);
    odd.size = 3;
    odd.data = @ptrCast(&odd_bytes);
    ft.applyState(h, &odd);
    try t.expect(ft.find(h).?.minimized);

    var hollow = std.mem.zeroes(wl.wl_array);
    hollow.size = 4;
    ft.applyState(h, &hollow);
    try t.expect(ft.find(h).?.minimized);

    ft.applyState(h, null);
    try t.expect(ft.find(h).?.minimized);
}

test "foreign-toplevels: closing flags the entry, destroying the handle is gated on a display" {
    var ft = ForeignToplevels.init(t.allocator);
    defer ft.deinit();
    var counter = Counter{};
    ft.hooks = counter.hooks();
    const token = try ft.addSnapshotCb(&counter, Counter.onSnapshot);

    const h = fakeHandle(0x1000);
    const tl = ft.trackHandle(h).?;
    ft.applyAppId(h, "vesktop");

    // `display` is null, so the handle is not handed to the Wayland destructor —
    // exactly the guard for an errored display. The entry
    // itself is what the rest of the assertions read, because `markClosed` takes
    // the handle out of the lookup.
    ft.markClosed(h);
    try t.expect(tl.closed);
    try t.expect(tl.handle == null);
    try t.expectEqual(@as(usize, 1), counter.destroyed);
    try t.expectEqual(h, counter.last_handle);
    try t.expectEqual(@as(usize, 1), counter.visual);
    try t.expectEqual(@as(usize, 1), counter.snapshots);

    ft.markClosed(fakeHandle(0x9999)); // nothing to close
    try t.expectEqual(@as(usize, 1), counter.destroyed);

    ft.notifySnapshotCbs();
    try t.expectEqual(@as(usize, 2), counter.snapshots);

    ft.removeSnapshotCb(token);
    ft.notifySnapshotCbs();
    try t.expectEqual(@as(usize, 2), counter.snapshots);
}

test "foreign-toplevels: prune keeps order, skips survivors, and cannot recurse" {
    var ft = ForeignToplevels.init(t.allocator);
    defer ft.deinit();
    var counter = Counter{};
    ft.hooks = counter.hooks();
    const token = try ft.addSnapshotCb(&counter, Counter.onSnapshot);

    const h1 = fakeHandle(0x1000);
    const h2 = fakeHandle(0x2000);
    const h3 = fakeHandle(0x3000);
    _ = ft.trackHandle(h1).?;
    _ = ft.trackHandle(h2).?;
    _ = ft.trackHandle(h3).?;
    ft.applyAppId(h1, "one");
    ft.applyAppId(h2, "two");
    ft.applyAppId(h3, "three");
    ft.markClosed(h2);
    counter.snapshots = 0;

    ft.pruneClosed();
    try t.expectEqual(@as(usize, 2), ft.size());
    try t.expectEqualStrings("one", ft.list()[0].app_id);
    try t.expectEqualStrings("three", ft.list()[1].app_id);
    try t.expectEqual(@as(usize, 1), counter.snapshots);

    // A snapshot callback that prunes again must not walk the list it is inside.
    ft.markClosed(h1);
    const Reenter = struct {
        fn prune(ctx: *anyopaque) void {
            const self: *ForeignToplevels = @ptrCast(@alignCast(ctx));
            self.pruneClosed();
        }
    };
    ft.removeSnapshotCb(token);
    _ = try ft.addSnapshotCb(&ft, Reenter.prune);
    ft.pruneClosed();
    try t.expectEqual(@as(usize, 1), ft.size());
    try t.expectEqualStrings("three", ft.list()[0].app_id);
}

test "foreign-toplevels: shutdown drops everything without a display" {
    var ft = ForeignToplevels.init(t.allocator);
    defer ft.deinit();
    var counter = Counter{};
    ft.hooks = counter.hooks();

    const h = fakeHandle(0x1000);
    _ = ft.trackHandle(h).?;
    ft.applyTitle(h, "gone");
    ft.mgr = fakeManager(0x4000);

    ft.shutdown();
    try t.expectEqual(@as(usize, 0), ft.size());
    // The records go but the manager proxy is left alone: with no display there
    // is no way to tell whether it is still usable, which is the same reason the
    // the whole teardown block is skipped.
    try t.expect(ft.mgr != null);
    try t.expect(ft.hooks == null);
    try t.expectEqual(@as(usize, 0), ft.snapshot_cbs.items.len);

    // Idempotent: safe after an explicit shutdown.
    ft.shutdown();
    try t.expectEqual(@as(usize, 0), ft.size());
}
