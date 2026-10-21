//! Captured window frames for the overview's tiles.
//!
//! One toplevel-export stream feeds a small store keyed by window handle
//! (the truncated address the compositor accepted). `sync` asks for the
//! windows the caller lists — live mode keeps those sessions running at
//! up to frame rate, snapshot mode asks once per window and stops. Paint
//! asks `frameFor` by window address; a miss falls back to the tinted
//! tile. A landed frame flips `dirty` so the owner repaints, and `tick`
//! releases re-requests that hit the pacing interval.

const std = @import("std");
const tiles = @import("tiles.zig");
const wl = @import("../../wl/c.zig").wl;
const logz = @import("../../logz.zig");
const stream_mod = @import("../../wl/capture/toplevel_stream.zig");
const wait_mod = @import("../../wl/capture/wait.zig");

pub const Capture = struct {
    alloc: std.mem.Allocator,
    stream: stream_mod.Stream,
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
            .stream = stream_mod.Stream.init(alloc),
            .frames = std.AutoHashMap(u32, Frame).init(alloc),
        };
    }

    pub fn deinit(self: *Capture) void {
        self.stream.deinit();
        var it = self.frames.valueIterator();
        while (it.next()) |v| self.alloc.free(v.bgra);
        self.frames.deinit();
    }

    /// Attach to the compositor's export manager. Both must be bound or
    /// the overview simply keeps its tinted tiles.
    pub fn start(self: *Capture, mgr: ?*wl.hyprland_toplevel_export_manager_v1, shm: ?*wl.wl_shm) bool {
        return self.stream.start(mgr, shm, self, onFrame);
    }

    pub fn active(self: *const Capture) bool {
        return self.stream.active();
    }

    /// Match the stream and store to `addrs`: drop frames and sessions for
    /// windows no longer asked for, open a session for each new one.
    pub fn sync(self: *Capture, addrs: []const []const u8, max_dim: i32, live: bool) void {
        self.stream.setOneShot(!live);
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(self.alloc);
        for (addrs) |addr| {
            if (addr.len == 0) continue;
            ids.append(self.alloc, stream_mod.handleFromAddr(addr)) catch continue;
        }
        self.stream.syncWindows(ids.items, max_dim);
        self.prune(ids.items);
    }

    /// Drop stored frames whose window is no longer in the asked-for set.
    fn prune(self: *Capture, ids: []const u32) void {
        var dead: std.ArrayList(u32) = .empty;
        defer dead.deinit(self.alloc);
        var it = self.frames.keyIterator();
        while (it.next()) |k| {
            if (!contains(ids, k.*)) dead.append(self.alloc, k.*) catch break;
        }
        for (dead.items) |k| {
            if (self.frames.fetchRemove(k)) |kv| self.alloc.free(kv.value.bgra);
        }
    }

    /// Paint-time lookup by window address. Returns a borrowed frame —
    /// valid until the next sync prunes or a new frame replaces it.
    pub fn frameFor(self: *Capture, addr: []const u8) ?tiles.LiveFrame {
        if (addr.len == 0) return null;
        const f = self.frames.get(stream_mod.handleFromAddr(addr)) orelse return null;
        if (f.bgra.len == 0 or f.width <= 0 or f.height <= 0) return null;
        return .{ .data = f.bgra, .w = f.width, .h = f.height, .gen = f.gen };
    }

    /// Reset one window's attempt budget for a forced fresh capture (the
    /// reveal pass's resync). False when no session covers the window.
    pub fn retryWindow(self: *Capture, addr: []const u8) bool {
        if (addr.len == 0) return false;
        return self.stream.retrySessionFor(stream_mod.handleFromAddr(addr));
    }

    /// True-and-clear: the owner repaints once per landed frame batch.
    pub fn takeDirty(self: *Capture) bool {
        const d = self.dirty;
        self.dirty = false;
        return d;
    }

    /// Release deferred re-requests whose pacing interval elapsed. Once
    /// per paint frame. Stall and retry events are surfaced here, at the
    /// place that already owns the cadence.
    pub fn tick(self: *Capture) void {
        const stalls0 = self.stream.stalls;
        const retries0 = self.stream.retries;
        self.stream.tick();
        if (self.stream.stalls > stalls0) {
            logz.log("capture: {d} attempt(s) timed out (hyprland never answered)", .{self.stream.stalls - stalls0});
        }
        if (self.stream.retries > retries0) {
            logz.log("capture: {d} retry attempt(s) started", .{self.stream.retries - retries0});
        }
    }

    /// True while any window still owes its first frame or a restart within
    /// its attempt budget. The owner keeps its pulse running exactly this
    /// long.
    pub fn needsWork(self: *const Capture) bool {
        return self.stream.needsWork();
    }

    /// Bounded wait for the first frames: dispatch until every session has
    /// delivered (or the budget runs out), so the first paint can show real
    /// content instead of tints. Loop-level only — it dispatches on its own.
    pub fn drain(self: *Capture, display: ?*wl.wl_display, budget_ms: u64) void {
        if (!self.active()) return;
        _ = wait_mod.pumpUntil(display, self, settled, budget_ms);
    }

    fn settled(self: *Capture) bool {
        return !self.stream.needsWork();
    }

    /// Frame landing during display dispatch: store it (freeing whatever
    /// the window held), mark dirty, wake the owner. The first frame for a
    /// window is logged so the open-to-content gap is visible in the log.
    fn onFrame(ctx: *anyopaque, frame: stream_mod.Frame) void {
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
    Capture.onFrame(&cap, .{ .window_id = stream_mod.handleFromAddr("0xabc"), .width = 2, .height = 2, .bgra = bgra });
    const fr = cap.frameFor("0xabc").?;
    try t.expectEqual(@as(i32, 2), fr.w);
    try t.expectEqual(@as(usize, 16), fr.data.len);
    try t.expect(cap.takeDirty());
    try t.expect(!cap.takeDirty());
    // A sync that still lists the window keeps its frame.
    const addrs = [_][]const u8{"0xabc"};
    cap.sync(&addrs, 256, false);
    try t.expect(cap.frameFor("0xabc") != null);
    // A sync without it drops the frame.
    const empty = [_][]const u8{};
    cap.sync(&empty, 256, false);
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
