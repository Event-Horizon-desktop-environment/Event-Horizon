//! Workspace fan-out: one handle over whichever workspace backend the
//! compositor actually gave us.
//!
//! Every backend is a typed field and the selection is a tag, so dispatch is
//! a field read, and adding a backend without giving it an arm is a compile
//! error rather than a wrong-type call at runtime.
//!
//! Backend dispatch table:
//!
//! | situation | handling |
//! |-----------|----------|
//! | opening the socket | `self.hyprland.?` |
//! | snapshot refresh when an output appears | same |
//! | `focusedWindowTitle()` | `if (self.active == .hyprland)` |
//! | handing back the concrete backend | `self.hyprland` |
//!
//! The Mango arm arrives with that backend, and the switch will refuse to
//! compile until it does.
//!
//! No global instance: the shell reaches its workspaces through `Connection`.

const std = @import("std");
const wl = @import("../c.zig").wl;
const desk = @import("../../backends/desk.zig");
const bk = @import("../../backends/compositor.zig");
const ext_ws = @import("../../backends/ext_workspace.zig");
const hypr_ws = @import("../../backends/hyprland_ws.zig");
const hypr_run = @import("../../backends/hyprland_run_ctx.zig");

const POLL = std.posix.POLL;
const Output = *wl.wl_output;
const WinMap = std.AutoHashMap(usize, desk.Win);

/// The tags that can be active. Names double as field names, which is how
/// Selection can tell whether the backend a tag names exists.
pub const Backend = enum { ext, hyprland };

pub const Workspaces = struct {
    alloc: std.mem.Allocator,
    /// Always present: ext-workspace-v1 needs no socket and no runtime, so
    /// there is never a version of this struct without it.
    ext: ext_ws.Manager,
    /// Heap-allocated because it registers a listener holding a pointer to
    /// itself; absent until a Hyprland run context is attached.
    hyprland: ?*hypr_ws.Manager = null,
    /// Which one answers. `null` before `initialize` and after `teardown`.
    active: ?Backend = null,
    change: ?desk.Notify = null,

    const Self = @This();

    /// Heap-allocated: `onStateChange` and `bindExtProtocol` both hand the
    /// compositor a pointer back to us, which has to outlive every call.
    pub fn create(alloc: std.mem.Allocator) !*Self {
        const self = try alloc.create(Self);
        self.* = .{ .alloc = alloc, .ext = ext_ws.Manager.init(alloc) };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const alloc = self.alloc;
        self.teardown();
        self.ext.deinit();
        if (self.hyprland) |h| h.destroy();
        alloc.destroy(self);
    }

    /// Only Hyprland needs a runtime so far, and it
    /// owns its listener, so it attaches here rather than being inlined.
    pub fn attachHyprland(self: *Self, io: std.Io, runtime: *hypr_run.Runtime) !void {
        self.hyprland = try hypr_ws.Manager.create(self.alloc, io, runtime);
        // A listener registered before this call would have missed this backend.
        if (self.change != null) self.hyprland.?.onStateChange(wrapper(self));
    }

    /// Binds the ext-workspace protocol manager.
    pub fn bindExtProtocol(self: *Self, mgr: ?*wl.ext_workspace_manager_v1) void {
        self.ext.bindExtProtocol(mgr);
    }

    /// Output resolvers cover mango + hyprland + sway; only
    /// Hyprland exists yet. The `Resolver` takes `wl_output*`
    /// as `?*anyopaque` so the backends stay free of Wayland types.
    pub fn setOutputResolver(self: *Self, resolver: hypr_ws.Resolver) void {
        if (self.hyprland) |h| h.setOutputResolver(resolver);
    }

    // -- selection ----------------------------------------------------------

    /// Compositor detection lives in `compositor.Kind.detectWithMap` (tested
    /// there), so this takes the answer and does nothing
    /// but decide — which is the part worth testing.
    pub fn initialize(self: *Self, kind: bk.Kind) void {
        // The compositor that was detected gets first refusal, socket and all.
        // Check Hyprland, then Sway, then Mango, in that order; only
        // the first exists, and `.sway`/`.mango` fall through to ext below
        // until their managers land.
        switch (kind) {
            .hyprland => if (self.openHyprland()) return,
            else => {},
        }

        // ext-workspace-v1 needs neither a socket nor a compositor kind: the
        // protocol is advertised or it is not.
        if (self.ext.ready()) {
            self.selectBackend(.ext);
            return;
        }

        // Detection missed, or what it found would not open: anything still
        // listening gets a turn anyway. Retry Hyprland here and then
        // tries Sway; with mango and sway unported, Hyprland is the last stop.
        if (self.openHyprland()) return;

        self.selectBackend(null);
    }

    /// `if (!hyprland->ready()) hyprland->openConnection(); if (ready()) …` —
    /// true only when there is a backend *and* it answers, and true implies
    /// the slot is taken.
    fn openHyprland(self: *Self) bool {
        const h = self.hyprland orelse return false;
        if (!h.ready()) _ = h.openConnection();
        if (!h.ready()) return false;
        self.selectBackend(.hyprland);
        return true;
    }

    /// Backend selection, and the invariant the whole file leans on:
    /// `.hyprland` can only be active when a Hyprland manager exists, so every
    /// `self.hyprland.?` below is a proof, not a guess.
    fn selectBackend(self: *Self, b: ?Backend) void {
        const k = b orelse {
            self.active = null;
            return;
        };
        self.active = switch (k) {
            .ext => .ext,
            .hyprland => if (self.hyprland != null) .hyprland else null,
        };
    }

    // -- fan-out ------------------------------------------------------------

    pub fn teardown(self: *Self) void {
        self.ext.teardown();
        if (self.hyprland) |h| h.teardown();
        self.active = null;
    }

    /// Registers one wrapper on every backend, so a change anywhere reaches
    /// the single callback the shell installed.
    pub fn onStateChange(self: *Self, cb: desk.Notify) void {
        self.change = cb;
        const w = wrapper(self);
        self.ext.onStateChange(w);
        if (self.hyprland) |h| h.onStateChange(w);
    }

    fn wrapper(self: *Self) desk.Notify {
        return .{ .ctx = self, .call = notifyThunk };
    }

    fn notifyThunk(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.change) |cb| cb.run();
    }

    /// Output observers cover Mango, so the observer loop
    /// has nobody to call yet — but a new output can move Hyprland's
    /// workspace-to-monitor map, which is why line 118 was a downcast.
    pub fn outputAttached(self: *Self, output: ?Output) void {
        _ = output;
        if (self.active == .hyprland) self.hyprland.?.reloadSnapshot();
    }

    pub fn outputDetached(_: *Self, output: ?Output) void {
        _ = output;
    }

    // -- navigation ---------------------------------------------------------

    pub fn jumpTo(self: *Self, id: []const u8) void {
        const k = self.active orelse return;
        switch (k) {
            .ext => self.ext.jumpTo(id),
            .hyprland => self.hyprland.?.jumpTo(id),
        }
    }

    pub fn jumpToOnOutput(self: *Self, output: ?Output, id: []const u8) void {
        const k = self.active orelse return;
        switch (k) {
            .ext => self.ext.jumpToOnOutput(output, id),
            .hyprland => self.hyprland.?.jumpToOnOutput(toOpaque(output), id),
        }
    }

    /// Region-based focus jump, by shape with id fallback.
    pub fn jumpToRegion(self: *Self, output: ?Output, ws: desk.Region) void {
        const k = self.active orelse return;
        switch (k) {
            .ext => self.ext.jumpToRegion(output, ws),
            .hyprland => self.hyprland.?.jumpToRegion(toOpaque(output), ws),
        }
    }

    /// Only ever asked of Hyprland, and only while it was active — which is
    /// what the downcast at line 220 existed to say out loud.
    pub fn focusedWindowTitle(self: *const Self) ?[]const u8 {
        if (self.active != .hyprland) return null;
        return self.hyprland.?.focusedWindowTitle();
    }

    // -- queries ------------------------------------------------------------

    pub fn allRegions(self: *Self) ![]desk.Region {
        const k = self.active orelse return try self.alloc.alloc(desk.Region, 0);
        return switch (k) {
            .ext => self.ext.allRegions(),
            .hyprland => self.hyprland.?.allRegions(),
        };
    }

    pub fn regionsOnOutput(self: *Self, output: ?Output) ![]desk.Region {
        const k = self.active orelse return try self.alloc.alloc(desk.Region, 0);
        return switch (k) {
            .ext => self.ext.regionsOnOutput(output),
            .hyprland => self.hyprland.?.regionsOnOutput(toOpaque(output)),
        };
    }

    pub fn appsByDesk(self: *Self, output: ?Output) !desk.AppMap {
        const k = self.active orelse return desk.AppMap.init(self.alloc);
        return switch (k) {
            .ext => desk.AppMap.init(self.alloc),
            .hyprland => self.hyprland.?.appsByDesk(toOpaque(output)),
        };
    }

    // -- taskbar integration: the interface defaults, stated per backend -----
    //
    // `workspace_manager.h` gives these bodies to anyone who does not override
    // them. Saying so per arm costs a line and keeps the switch exhaustive.

    pub fn taskbarMode(self: *const Self) desk.TaskbarMode {
        const k = self.active orelse return .generic;
        return switch (k) {
            .ext => .generic,
            .hyprland => self.hyprland.?.taskbarMode(),
        };
    }

    pub fn matchEntries(self: *const Self, entries: []const desk.TaskbarEntry, output: ?Output) WinMap {
        // Nothing here reads them: Hyprland's own `matchEntries` takes no
        // arguments (it is the default of "no entries matched"), and Mango is
        // the only backend that answers per entry. Remove both when it lands.
        _ = entries;
        _ = output;
        const k = self.active orelse return WinMap.init(self.alloc);
        return switch (k) {
            .ext => WinMap.init(self.alloc),
            .hyprland => self.hyprland.?.matchEntries(),
        };
    }

    pub fn windowsOnDesk(self: *const Self, output: ?Output) []const desk.Win {
        // Same: only Mango filters by output.
        _ = output;
        const k = self.active orelse return &.{};
        return switch (k) {
            .ext => &.{},
            .hyprland => self.hyprland.?.windowsOnDesk(),
        };
    }

    pub fn bringToFront(_: *Self, windowId: []const u8) void {
        // Only `MangoWorkspaceManager` overrides this, so no arm of the switch
        // could differ — the whole body is the interface default.
        _ = windowId;
    }

    // -- poll integration ---------------------------------------------------

    pub fn eventFd(self: *const Self) i32 {
        const k = self.active orelse return -1;
        return switch (k) {
            .ext => -1,
            .hyprland => self.hyprland.?.eventFd(),
        };
    }

    /// Note the asymmetry: with no active backend the
    /// fan-out reports `POLLIN` alone, while a backend that does not override
    /// the interface gets `POLLIN|POLLHUP|POLLERR`. Two different answers, both
    /// deliberate.
    pub fn eventFlags(self: *const Self) i16 {
        const k = self.active orelse return POLL.IN;
        return switch (k) {
            .ext => POLL.IN | POLL.HUP | POLL.ERR,
            .hyprland => self.hyprland.?.eventFlags(),
        };
    }

    pub fn eventTimeout(self: *const Self) i32 {
        const k = self.active orelse return -1;
        return switch (k) {
            .ext => -1,
            .hyprland => self.hyprland.?.eventTimeout(),
        };
    }

    pub fn onEvent(self: *Self, revents: i16) void {
        const k = self.active orelse return;
        switch (k) {
            .ext => {},
            .hyprland => self.hyprland.?.handlePoll(revents),
        }
    }

    // -- identity -----------------------------------------------------------

    pub fn name(self: *const Self) []const u8 {
        const k = self.active orelse return "none";
        return switch (k) {
            .ext => ext_ws.Manager.name,
            .hyprland => hypr_ws.Manager.name,
        };
    }

    pub fn workspaceBackend(self: *const Self) ?Backend {
        return self.active;
    }

    /// Hands back the Hyprland manager; the field already is one.
    pub fn hyprlandBackend(self: *Self) ?*hypr_ws.Manager {
        return self.hyprland;
    }
};

/// The `wl_output*` the fan-out speaks, reinterpreted for the backends that
/// take `?*anyopaque` so they can stay free of Wayland types. Same address.
fn toOpaque(output: ?Output) ?*anyopaque {
    const o = output orelse return null;
    const p: *anyopaque = @ptrCast(o);
    return p;
}

// Tests

const t = std.testing;

test "workspaces: with nothing selected every read is the interface default" {
    const ww = try Workspaces.create(t.allocator);
    defer ww.destroy();

    try t.expectEqualStrings("none", ww.name());
    try t.expect(ww.workspaceBackend() == null);
    try t.expect(ww.hyprlandBackend() == null);

    try t.expectEqual(@as(usize, 0), (try ww.allRegions()).len);
    try t.expectEqual(@as(usize, 0), (try ww.regionsOnOutput(null)).len);
    try t.expectEqual(@as(usize, 0), (try ww.appsByDesk(null)).count());
    try t.expectEqual(desk.TaskbarMode.generic, ww.taskbarMode());
    try t.expectEqual(@as(usize, 0), ww.matchEntries(&.{}, null).count());
    try t.expectEqual(@as(usize, 0), ww.windowsOnDesk(null).len);
    ww.bringToFront("0x10");

    // The no-backend answer, which is *not* the interface default.
    try t.expectEqual(@as(i32, -1), ww.eventFd());
    try t.expectEqual(@as(i16, POLL.IN), ww.eventFlags());
    try t.expectEqual(@as(i32, -1), ww.eventTimeout());
    try t.expect(ww.focusedWindowTitle() == null);

    // Nothing to jump on, and nothing that could crash trying.
    ww.jumpTo("3");
    ww.jumpToOnOutput(null, "3");
    ww.jumpToRegion(null, .{ .id = "3" });
    ww.onEvent(POLL.IN);
    try t.expect(ww.workspaceBackend() == null);
}

test "workspaces: initialize walks the backend chain and selects nothing when nothing is ready" {
    const ww = try Workspaces.create(t.allocator);
    defer ww.destroy();

    // No Hyprland runtime is attached, ext is unbound, and mango/sway have no
    // managers — so every compositor kind ends at the same empty answer, after
    // passing through every check.
    const kinds = [_]bk.Kind{ .hyprland, .niri, .mango, .sway, .labwc, .unknown };
    for (kinds) |kind| {
        ww.initialize(kind);
        try t.expect(ww.workspaceBackend() == null);
        try t.expectEqualStrings("none", ww.name());
    }
}

test "workspaces: the selected backend answers, with Hyprland's cast gone" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = hypr_run.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();
    // Declared after the runtime, so it runs first: `destroy` stops the backend,
    // which is the very `shutdown` an already-deinitialized runtime cannot take.
    const ww = try Workspaces.create(t.allocator);
    defer ww.destroy();

    ww.selectBackend(.ext);
    try t.expectEqual(Backend.ext, ww.workspaceBackend().?);
    try t.expectEqualStrings("ext-workspace", ww.name());
    // ext holds no proxy until the protocol is bound, so it is never ready and
    // never has a jump to make — but it is selected, and the interface default
    // for a backend that does not override the poll calls differs from none.
    try t.expect(!ww.ext.ready());
    try t.expectEqual(@as(i16, POLL.IN | POLL.HUP | POLL.ERR), ww.eventFlags());
    try t.expectEqual(@as(i32, -1), ww.eventFd());
    ww.jumpTo("1");
    ww.jumpToOnOutput(null, "1");
    try t.expectEqual(@as(usize, 0), (try ww.allRegions()).len);

    // A tag naming a backend that does not exist cannot be selected, which is
    // what used to be the unchecked premise of every `static_cast`.
    try ww.attachHyprland(t.io, &rt);

    ww.selectBackend(.hyprland);
    try t.expectEqual(Backend.hyprland, ww.workspaceBackend().?);
    try t.expectEqualStrings("hyprland-ipc", ww.name());
    try t.expect(ww.hyprlandBackend() == ww.hyprland);

    // Queries go through with an empty session rather than touching a socket.
    try t.expectEqual(@as(usize, 0), (try ww.allRegions()).len);
    try t.expectEqual(@as(usize, 0), (try ww.appsByDesk(null)).count());
    try t.expectEqual(@as(usize, 0), ww.windowsOnDesk(null).len);
    try t.expectEqual(desk.TaskbarMode.generic, ww.taskbarMode());
    try t.expectEqual(rt.pollHandle(), ww.eventFd());
    // Hyprland answers this only while it is the active backend.
    try t.expect(ww.focusedWindowTitle() == null);

    // An output arriving refreshes the snapshot, which is safe on a session
    // that never opened.
    ww.outputAttached(null);
    ww.outputDetached(null);

    ww.selectBackend(null);
    try t.expect(ww.workspaceBackend() == null);
}

test "workspaces: one wrapper carries every backend's change to the caller" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = hypr_run.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();
    const ww = try Workspaces.create(t.allocator);
    defer ww.destroy();

    var hits: usize = 0;
    ww.onStateChange(.{ .ctx = &hits, .call = countUp });

    // Registered on ext whether or not it was ever bound…
    try t.expect(ww.ext.tables.notify.?.ctx == @as(*anyopaque, @ptrCast(ww)));
    // …and on Hyprland as soon as one is attached.
    try t.expect(ww.hyprland == null);
    try ww.attachHyprland(t.io, &rt);
    try t.expect(ww.hyprland.?.notify.?.ctx == @as(*anyopaque, @ptrCast(ww)));

    // Each backend's slot, run the way the backend would run it, reaches the
    // one callback the shell installed — including after the re-registration
    // `attachHyprland` does for a callback that was already set.
    ww.ext.tables.notify.?.run();
    ww.hyprland.?.notify.?.run();
    try t.expectEqual(@as(usize, 2), hits);
}

test "workspaces: teardown clears the selection and stays safe to repeat" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = hypr_run.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();
    const ww = try Workspaces.create(t.allocator);
    defer ww.destroy();
    try ww.attachHyprland(t.io, &rt);
    ww.selectBackend(.hyprland);

    ww.teardown();
    try t.expect(ww.workspaceBackend() == null);
    try t.expectEqualStrings("none", ww.name());
    ww.teardown();
    try t.expect(ww.hyprland != null);
}

fn countUp(ctx: *anyopaque) void {
    const hits: *usize = @ptrCast(@alignCast(ctx));
    hits.* += 1;
}
