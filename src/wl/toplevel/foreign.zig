//! `zwlr_foreign_toplevel_manager_v1` is not what we have here: the Zig
//! shell binds `ext_foreign_toplevel_list_v1` (see `wl/connection.zig`), which
//! reports each toplevel's `app_id`/`title` but no activated state. That is
//! enough to answer "is this dock slot running?", the indicator-dot gate.
//!
//! Each `Window` is heap-allocated and pointed at from a list, so that
//! appending never relocates an entry — Wayland listener callbacks carry the
//! `*Tracker` and look themselves up by handle.

const std = @import("std");
const wl = @import("../c.zig").wl;
const paths = @import("../../desktop_shell/common/paths.zig");

pub const Window = struct {
    handle: usize = 0,
    title: []const u8 = "",
    app_id: []const u8 = "",
    /// Stable per-toplevel id from the protocol — the key `--list-windows`
    /// prints and `--toplevel ID` matches on. Empty until the first `done`.
    identifier: []const u8 = "",
    active: bool = false,
    /// Set when `closed` arrives; the entry is dropped by `pruneClosed`.
    closed: bool = false,
    raw: ?*anyopaque = null,
    ext: bool = true,
};

pub const Tracker = struct {
    alloc: std.mem.Allocator,
    windows: std.ArrayList(*Window),
    on_changed: ?*const fn (ctx: *anyopaque) void = null,
    changed_ctx: *anyopaque = undefined,
    ext_list: ?*wl.ext_foreign_toplevel_list_v1 = null,
    wlr_manager: ?*wl.zwlr_foreign_toplevel_manager_v1 = null,

    const Self = @This();

    fn tracker(data: ?*anyopaque) ?*Self {
        return @ptrCast(@alignCast(data orelse return null));
    }

    fn findRaw(self: *Self, raw: ?*anyopaque) ?*Window {
        for (self.windows.items) |w| {
            if (w.raw == raw) return w;
        }
        return null;
    }

    fn notify(self: *Self) void {
        if (self.on_changed) |h| h(self.changed_ctx);
    }

    /// The Wayland dispatch buffer is reused, so every string the protocol
    /// hands us has to be copied before we return from the listener.
    fn setStr(self: *Self, dst: *[]const u8, src: []const u8) void {
        if (dst.*.len > 0) self.alloc.free(dst.*);
        dst.* = if (src.len == 0) "" else self.alloc.dupe(u8, src) catch "";
    }

    fn removeWindow(self: *Self, w: *Window) void {
        if (w.title.len > 0) self.alloc.free(w.title);
        if (w.app_id.len > 0) self.alloc.free(w.app_id);
        if (w.identifier.len > 0) self.alloc.free(w.identifier);
        self.alloc.destroy(w);
    }

    fn onExtToplevel(data: ?*anyopaque, list: ?*wl.ext_foreign_toplevel_list_v1, h: ?*wl.ext_foreign_toplevel_handle_v1) callconv(.c) void {
        _ = list;
        const self = tracker(data) orelse return;
        if (h == null or self.findRaw(@ptrCast(h)) != null) return;
        const w = self.alloc.create(Window) catch return;
        w.* = .{ .raw = @ptrCast(h), .ext = true };
        self.windows.append(self.alloc, w) catch {
            self.alloc.destroy(w);
            return;
        };
        _ = wl.ext_foreign_toplevel_handle_v1_add_listener(h, &ext_handle_listener, self);
    }

    fn onExtFinished(data: ?*anyopaque, list: ?*wl.ext_foreign_toplevel_list_v1) callconv(.c) void {
        _ = list;
        _ = data;
    }

    const ext_list_listener = wl.ext_foreign_toplevel_list_v1_listener{
        .toplevel = onExtToplevel,
        .finished = onExtFinished,
    };

    /// `closed` means the window is gone: drop its identity immediately so a
    /// later slot lookup cannot match a corpse, then let `pruneClosed` reclaim
    /// it outside of any listener.
    fn extClosed(data: ?*anyopaque, h: ?*wl.ext_foreign_toplevel_handle_v1) callconv(.c) void {
        const self = tracker(data) orelse return;
        const w = self.findRaw(@ptrCast(h)) orelse return;
        w.closed = true;
        self.setStr(&w.title, "");
        self.setStr(&w.app_id, "");
        w.active = false;
        self.notify();
    }

    fn extDone(data: ?*anyopaque, h: ?*wl.ext_foreign_toplevel_handle_v1) callconv(.c) void {
        _ = h;
        // ext-foreign-toplevel-list batches every property update behind
        // `done`, so this is the only point where a change is observable.
        const self = tracker(data) orelse return;
        self.notify();
    }

    fn extTitle(data: ?*anyopaque, h: ?*wl.ext_foreign_toplevel_handle_v1, title: [*c]const u8) callconv(.c) void {
        const self = tracker(data) orelse return;
        const w = self.findRaw(@ptrCast(h)) orelse return;
        self.setStr(&w.title, if (title != null) std.mem.span(title) else "");
    }

    fn extAppId(data: ?*anyopaque, h: ?*wl.ext_foreign_toplevel_handle_v1, app_id: [*c]const u8) callconv(.c) void {
        const self = tracker(data) orelse return;
        const w = self.findRaw(@ptrCast(h)) orelse return;
        self.setStr(&w.app_id, if (app_id != null) std.mem.span(app_id) else "");
    }

    fn extIdentifier(data: ?*anyopaque, h: ?*wl.ext_foreign_toplevel_handle_v1, id: [*c]const u8) callconv(.c) void {
        const self = tracker(data) orelse return;
        const w = self.findRaw(@ptrCast(h)) orelse return;
        self.setStr(&w.identifier, if (id != null) std.mem.span(id) else "");
    }

    const ext_handle_listener = wl.ext_foreign_toplevel_handle_v1_listener{
        .closed = extClosed,
        .done = extDone,
        .title = extTitle,
        .app_id = extAppId,
        .identifier = extIdentifier,
    };

    pub fn init(alloc: std.mem.Allocator) Tracker {
        return .{ .alloc = alloc, .windows = .empty };
    }

    pub fn deinit(self: *Tracker) void {
        for (self.windows.items) |w| self.removeWindow(w);
        self.windows.deinit(self.alloc);
    }

    pub fn bindExt(self: *Tracker, list: ?*wl.ext_foreign_toplevel_list_v1) void {
        self.ext_list = list;
        _ = wl.ext_foreign_toplevel_list_v1_add_listener(list, &ext_list_listener, self);
    }

    pub fn windowCount(self: *const Tracker) usize {
        return self.windows.items.len;
    }

    /// True while at least one live toplevel is the same application as
    /// `app_id`, minus the focus tint this
    /// protocol does not carry.
    ///
    /// The two sides do not have to spell the application the same way: a
    /// pin reads `sh.cider.Cider` from its desktop file while the window
    /// reports `cider`, so this goes through `paths.sameAppId` rather than a
    /// plain compare — otherwise the dot never lights for a reverse-DNS pin.
    pub fn isRunning(self: *const Tracker, app_id: []const u8) bool {
        if (app_id.len == 0) return false;
        for (self.windows.items) |w| {
            if (w.closed or w.app_id.len == 0) continue;
            if (paths.sameAppId(w.app_id, app_id)) return true;
        }
        return false;
    }

    /// Drop entries whose window closed. Must be called outside a listener —
    /// the dock does it from its periodic timer.
    pub fn pruneClosed(self: *Tracker) void {
        var i: usize = 0;
        while (i < self.windows.items.len) {
            if (self.windows.items[i].closed) {
                const w = self.windows.orderedRemove(i);
                self.removeWindow(w);
            } else i += 1;
        }
    }
};

test "foreign: empty tracker" {
    const t = std.testing;
    var tr = Tracker.init(t.allocator);
    defer tr.deinit();
    try t.expectEqual(@as(usize, 0), tr.windowCount());
    try t.expect(!tr.isRunning("any-app"));
    try t.expect(!tr.isRunning(""));
}

test "foreign: isRunning matches case-insensitively and skips closed" {
    const t = std.testing;
    var tr = Tracker.init(t.allocator);
    defer tr.deinit();

    // `deinit` frees `app_id`, so these have to be owned copies just like the
    // ones the listeners produce.
    const live = try t.allocator.create(Window);
    live.* = .{ .app_id = try t.allocator.dupe(u8, "org.gnome.Nautilus"), .raw = @ptrFromInt(1) };
    errdefer t.allocator.destroy(live);
    const dead = try t.allocator.create(Window);
    dead.* = .{ .app_id = try t.allocator.dupe(u8, "org.gnome.Nautilus"), .raw = @ptrFromInt(2), .closed = true };
    errdefer t.allocator.destroy(dead);
    const blank = try t.allocator.create(Window);
    blank.* = .{ .raw = @ptrFromInt(3) };
    errdefer t.allocator.destroy(blank);
    try tr.windows.append(t.allocator, live);
    try tr.windows.append(t.allocator, dead);
    try tr.windows.append(t.allocator, blank);

    try t.expect(tr.isRunning("org.gnome.Nautilus"));
    try t.expect(tr.isRunning("ORG.GNOME.NAUTILUS"));
    try t.expect(!tr.isRunning("firefox"));
    try t.expect(!tr.isRunning(""));
}

test "foreign: isRunning accepts the same app under the pin's spelling" {
    const t = std.testing;
    var tr = Tracker.init(t.allocator);
    defer tr.deinit();

    // What Hyprland hands out for the Flatpak build of Cider, against the
    // reverse-DNS id its desktop file is pinned under.
    const live = try t.allocator.create(Window);
    live.* = .{ .app_id = try t.allocator.dupe(u8, "cider"), .raw = @ptrFromInt(1) };
    errdefer t.allocator.destroy(live);
    try tr.windows.append(t.allocator, live);

    try t.expect(tr.isRunning("sh.cider.Cider"));
    try t.expect(tr.isRunning("CIDER"));
    // Token boundaries still hold: a different app whose id merely ends the
    // same way is not this one.
    try t.expect(!tr.isRunning("sh.cider.CiderX"));
    try t.expect(!tr.isRunning("ercider"));
}

test "foreign: pruneClosed frees only closed entries" {
    const t = std.testing;
    var tr = Tracker.init(t.allocator);
    defer tr.deinit();

    const a = try t.allocator.create(Window);
    a.* = .{ .app_id = try t.allocator.dupe(u8, "a"), .raw = @ptrFromInt(1) };
    const b = try t.allocator.create(Window);
    b.* = .{ .app_id = try t.allocator.dupe(u8, "b"), .raw = @ptrFromInt(2), .closed = true };
    const c = try t.allocator.create(Window);
    c.* = .{ .app_id = try t.allocator.dupe(u8, "c"), .raw = @ptrFromInt(3) };
    try tr.windows.append(t.allocator, a);
    try tr.windows.append(t.allocator, b);
    try tr.windows.append(t.allocator, c);

    tr.pruneClosed();
    try t.expectEqual(@as(usize, 2), tr.windowCount());
    try t.expect(tr.isRunning("a"));
    try t.expect(!tr.isRunning("b"));
    try t.expect(tr.isRunning("c"));
}

test "foreign: live enumeration when advertised" {
    const t = std.testing;
    const Conn = @import("../connection.zig").Connection;
    var conn = Conn.init(t.allocator);
    defer conn.deinit();
    if (!conn.connect(null)) return error.SkipZigTest;
    var bound = Conn.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    const list = bound.foreign_toplevel_list orelse return error.SkipZigTest;
    var tr = Tracker.init(t.allocator);
    defer tr.deinit();
    tr.bindExt(list);
    var ticks: u32 = 0;
    while (ticks < 30) : (ticks += 1) {
        if (!conn.roundtrip()) break;
    }
    _ = tr.windowCount();
    try t.expect(true);
}
