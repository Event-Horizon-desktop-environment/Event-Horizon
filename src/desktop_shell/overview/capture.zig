//! Captured window frames for the overview's tiles.
//!
//! Supports two compositor backends:
//! - Hyprland: `hyprland_toplevel_export_manager_v1` keyed by truncated address
//! - Zoolander/others: `ext_foreign_toplevel_image_capture_source_manager_v1` keyed by foreign toplevel handle
//! The active backend is selected at runtime based on which manager is bound.

const std = @import("std");
const tiles = @import("tiles.zig");
const wl = @import("../../wl/c.zig").wl;
const logz = @import("../../logz.zig");
const hypr_stream = @import("../../wl/capture/toplevel_stream.zig");
const zoo_stream = @import("../../wl/capture/zoolander_stream.zig");
const wait_mod = @import("../../wl/capture/wait.zig");

/// Frame-store key for a window address. Hyprland addresses are `0x…` hex;
/// Zoolander's are foreign-toplevel identifiers like `zoo-toplevel-12`, which
/// are not hex, so they are hashed (hex-parsing them gave every window id 0).
pub fn windowKey(addr: []const u8) u32 {
    if (std.mem.startsWith(u8, addr, "0x") or std.mem.startsWith(u8, addr, "0X")) {
        return hypr_stream.handleFromAddr(addr);
    }
    return @truncate(std.hash.Wyhash.hash(0, addr));
}

pub const Capture = struct {
    alloc: std.mem.Allocator,
    hypr: hypr_stream.Stream,
    zoo: zoo_stream.Stream,
    frames: std.AutoHashMap(u32, Frame),
    /// Source generation for the paint cache: bumped on every stored
    /// frame so a replaced capture can never paint stale.
    seq: u64 = 0,
    /// A frame landed since the owner last painted.
    dirty: bool = false,
    /// Owner hook: called (during dispatch) when a frame lands, so the
    /// repaint timer arms without the owner polling.
    wake_ctx: *anyopaque = undefined,
    wake: ?*const fn (*anyopaque) void = null,

    /// One stored frame: owned premultiplied BGRA plus its dimensions.
    pub const Frame = struct {
        width: i32 = 0,
        height: i32 = 0,
        bgra: []u8 = &.{},
        gen: u64 = 0,
    };

    pub fn init(alloc: std.mem.Allocator) Capture {
        return .{
            .alloc = alloc,
            .hypr = hypr_stream.Stream.init(alloc),
            .zoo = zoo_stream.Stream.init(alloc),
            .frames = std.AutoHashMap(u32, Frame).init(alloc),
        };
    }

    pub fn deinit(self: *Capture) void {
        self.hypr.deinit();
        self.zoo.deinit();
        var it = self.frames.valueIterator();
        while (it.next()) |v| self.alloc.free(v.bgra);
        self.frames.deinit();
    }

    /// Attach to the compositor's export managers. If both are bound,
    /// Hyprland takes priority. If neither, tiles stay tinted.
    pub fn start(
        self: *Capture,
        hypr_mgr: ?*wl.hyprland_toplevel_export_manager_v1,
        copy_mgr: ?*wl.ext_image_copy_capture_manager_v1,
        src_mgr: ?*wl.ext_foreign_toplevel_image_capture_source_manager_v1,
        shm: ?*wl.wl_shm,
        size_mgr: ?*wl.zoolander_image_copy_capture_size_manager_v1,
    ) bool {
        var ok = false;
        if (hypr_mgr != null and shm != null) {
            ok = self.hypr.start(hypr_mgr, shm, self, onFrame) or ok;
        }
        if (copy_mgr != null and src_mgr != null and shm != null) {
            ok = self.zoo.start(copy_mgr, src_mgr, shm, size_mgr, self, onFrame) or ok;
        }
        return ok;
    }

    pub fn active(self: *const Capture) bool {
        return self.hypr.active() or self.zoo.active();
    }

    /// Match streams to `addrs` (Hyprland) and `handles` (Zoolander).
    pub fn sync(
        self: *Capture,
        addrs: []const []const u8,
        handles: []const *wl.ext_foreign_toplevel_handle_v1,
        zoo_addrs: []const []const u8,
        max_dim: i32,
        live: bool,
    ) void {
        self.hypr.setOneShot(!live);
        self.zoo.setOneShot(!live);

        // Hyprland: addresses -> u32 handles
        var hypr_ids: std.ArrayList(u32) = .empty;
        defer hypr_ids.deinit(self.alloc);
        for (addrs) |addr| {
            if (!std.mem.startsWith(u8, addr, "0x")) continue;
            hypr_ids.append(self.alloc, hypr_stream.handleFromAddr(addr)) catch continue;
        }
        self.hypr.syncWindows(hypr_ids.items, max_dim);

        // Zoolander: foreign toplevel handles, keyed by the same
        // address-derived id frameFor() looks up.
        var zoo_ids: std.ArrayList(u32) = .empty;
        defer zoo_ids.deinit(self.alloc);
        for (zoo_addrs) |addr| {
            zoo_ids.append(self.alloc, windowKey(addr)) catch return;
        }
        self.zoo.syncWindows(handles, zoo_ids.items, max_dim);

        // One prune against both backends' ids so neither wipes the other's frames.
        hypr_ids.appendSlice(self.alloc, zoo_ids.items) catch return;
        self.pruneHypr(hypr_ids.items);
    }

    /// Drop stored frames whose window is no longer in the Hyprland set.
    fn pruneHypr(self: *Capture, ids: []const u32) void {
        var dead: std.ArrayList(u32) = .empty;
        defer dead.deinit(self.alloc);
        var it = self.frames.keyIterator();
        while (it.next()) |k| {
            // Only prune frames that came from Hyprland (have a matching handle)
            if (!contains(ids, k.*)) dead.append(self.alloc, k.*) catch break;
        }
        for (dead.items) |k| {
            if (self.frames.fetchRemove(k)) |kv| self.alloc.free(kv.value.bgra);
        }
    }

    /// Paint-time lookup by window address. Works for both backends.
    pub fn frameFor(self: *Capture, addr: []const u8) ?tiles.LiveFrame {
        if (addr.len == 0) return null;
        const id = windowKey(addr);
        const f = self.frames.get(id) orelse return null;
        if (f.bgra.len == 0 or f.width <= 0 or f.height <= 0) return null;
        return .{ .data = f.bgra, .w = f.width, .h = f.height, .gen = f.gen };
    }

    /// Reset one window's attempt budget for a forced fresh capture.
    /// For Hyprland, `addr` is the hex address. For Zoolander, `addr` is the
    /// identifier string and `zoo_handle` should be the foreign toplevel handle.
    pub fn retryWindow(
        self: *Capture,
        addr: []const u8,
        zoo_handle: ?*wl.ext_foreign_toplevel_handle_v1,
    ) bool {
        if (addr.len == 0) return false;
        if (zoo_handle == null) return self.hypr.retrySessionFor(windowKey(addr));
        return self.zoo.retrySessionFor(zoo_handle);
    }

    /// True-and-clear: the owner repaints once per landed frame batch.
    pub fn takeDirty(self: *Capture) bool {
        const d = self.dirty;
        self.dirty = false;
        return d;
    }

    /// Release deferred re-requests whose pacing interval elapsed.
    pub fn tick(self: *Capture) void {
        const stalls0 = self.hypr.stalls + self.zoo.stalls;
        const retries0 = self.hypr.retries + self.zoo.retries;
        self.hypr.tick();
        self.zoo.tick();
        if (self.hypr.stalls + self.zoo.stalls > stalls0) {
            logz.log("capture: {d} attempt(s) timed out", .{self.hypr.stalls + self.zoo.stalls - stalls0});
        }
        if (self.hypr.retries + self.zoo.retries > retries0) {
            logz.log("capture: {d} retry attempt(s) started", .{self.hypr.retries + self.zoo.retries - retries0});
        }
    }

    /// True while any window still owes its first frame.
    pub fn needsWork(self: *const Capture) bool {
        return self.hypr.needsWork() or self.zoo.needsWork();
    }

    /// Bounded wait for the first frames.
    pub fn drain(self: *Capture, display: ?*wl.wl_display, budget_ms: u64) void {
        if (!self.active()) return;
        _ = wait_mod.pumpUntil(display, self, settled, budget_ms);
    }

    fn settled(self: *Capture) bool {
        return !self.needsWork();
    }

    /// Frame landing during display dispatch: store it, mark dirty, wake the owner.
    fn onFrame(ctx: *anyopaque, frame: hypr_stream.Frame) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        const bgra = frame.bgra;
        const gop = self.frames.getOrPut(frame.window_id) catch {
            self.alloc.free(bgra);
            return;
        };
        const fresh = !gop.found_existing;
        if (fresh) {
            gop.value_ptr.* = .{};
        } else {
            self.alloc.free(gop.value_ptr.bgra);
        }
        self.seq += 1;
        gop.value_ptr.* = .{ .width = frame.width, .height = frame.height, .bgra = bgra, .gen = self.seq };
        if (fresh) logz.log("capture: first frame id={x} {d}x{d}", .{ frame.window_id, frame.width, frame.height });
        self.dirty = true;
        if (self.wake) |w| w(self.wake_ctx);
    }
};

fn contains(ids: []const u32, id: u32) bool {
    for (ids) |x| {
        if (x == id) return true;
    }
    return false;
}

test "overview-capture: frames key by address and survive a sync" {
    const t = std.testing;
    var cap = Capture.init(t.allocator);
    defer cap.deinit();
    const bgra = try t.allocator.alloc(u8, 2 * 2 * 4);
    @memset(bgra, 0x40);
    Capture.onFrame(&cap, .{ .window_id = hypr_stream.handleFromAddr("0xabc"), .width = 2, .height = 2, .bgra = bgra });
    const fr = cap.frameFor("0xabc").?;
    try t.expectEqual(@as(i32, 2), fr.w);
    try t.expectEqual(@as(usize, 16), fr.data.len);
    try t.expect(cap.takeDirty());
    try t.expect(!cap.takeDirty());
    // A sync that still lists the window keeps its frame.
    const addrs = [_][]const u8{"0xabc"};
    const handles = [_]*wl.ext_foreign_toplevel_handle_v1{};
    cap.sync(&addrs, &handles, &.{}, 256, false);
    try t.expect(cap.frameFor("0xabc") != null);
    // A sync without it drops the frame.
    const empty = [_][]const u8{};
    cap.sync(&empty, &handles, &.{}, 256, false);
    try t.expect(cap.frameFor("0xabc") == null);
}

test "overview-capture: a second frame for one window frees the first" {
    const t = std.testing;
    var cap = Capture.init(t.allocator);
    defer cap.deinit();
    const a = try t.allocator.alloc(u8, 4);
    const b = try t.allocator.alloc(u8, 4);
    @memset(a, 1);
    @memset(b, 2);
    Capture.onFrame(&cap, .{ .window_id = 7, .width = 1, .height = 1, .bgra = a });
    Capture.onFrame(&cap, .{ .window_id = 7, .width = 1, .height = 1, .bgra = b });
    const fr = cap.frameFor("0x7").?;
    try t.expectEqual(@as(u8, 2), fr.data[0]);
    try t.expectEqual(@as(usize, 4), fr.data.len);
}