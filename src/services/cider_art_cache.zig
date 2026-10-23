//! Single-flight artwork loader for the Cider widget's many thumbnails.
//!
//! The media widget's cover path is tuned for one "now playing" image; a
//! queue, library grid, and hero can ask for a dozen. This loader keeps the
//! same non-blocking hand-off but drains the whole visible page in one batch,
//! so a list does not fill in one thumbnail per shell tick. It shares the
//! on-disk cover cache with the media widgets, so a URL decoded once by either
//! is a read the second time.

const std = @import("std");
const mpris_art = @import("mpris_art.zig");
const cover_cache = @import("cover_cache.zig");
const cider_art = @import("cider_art.zig");
const logz = @import("../logz.zig");

pub const Result = struct {
    url: ?[]const u8 = null,
    cover: mpris_art.Cover = .{},
    elapsed_ns: u64 = 0,

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        if (self.url) |u| alloc.free(u);
        self.url = null;
        self.cover.deinit(alloc);
    }
};

const queue_cap = 64;

var mu: std.atomic.Mutex = .unlocked;
var pending: [queue_cap]?[]u8 = @as([queue_cap]?[]u8, @splat(null));
var pending_head: usize = 0;
var pending_len: usize = 0;
var ready: [queue_cap]Result = @as([queue_cap]Result, @splat(.{}));
var ready_head: usize = 0;
var ready_len: usize = 0;
// The URL the worker is loading right now. Without this, `queued` only saw
// pending and ready entries; while a slow 1-4 second cover was in flight, the
// widget re-requested it every refresh, queueing duplicate downloads whose
// late results bumped the art generation and repainted the card again.
var inflight: ?[]u8 = null;
var running = false;
var stopping = false;
var worker_alloc: std.mem.Allocator = std.heap.page_allocator;
var worker_io: std.Io = undefined;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * std.time.ns_per_s +
        @as(u64, @intCast(@max(ts.nsec, 0)));
}

fn lock() void {
    // Yield after a short spin. The critical sections here are tiny, but a
    // pure spinlock makes the UI burn a whole timeslice if the worker is
    // preempted mid-batch (which is exactly when artwork loads get heavy).
    var spins: u32 = 0;
    while (!mu.tryLock()) {
        spins +%= 1;
        if (spins < 64) {
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
        }
    }
}

fn unlock() void {
    mu.unlock();
}

fn queued(url: []const u8) bool {
    if (inflight) |u| {
        if (std.mem.eql(u8, u, url)) return true;
    }
    var i: usize = 0;
    while (i < pending_len) : (i += 1) {
        const slot = (pending_head + i) % queue_cap;
        if (pending[slot]) |u| {
            if (std.mem.eql(u8, u, url)) return true;
        }
    }
    i = 0;
    while (i < ready_len) : (i += 1) {
        const slot = (ready_head + i) % queue_cap;
        if (ready[slot].url) |u| {
            if (std.mem.eql(u8, u, url)) return true;
        }
    }
    return false;
}

pub fn idle() bool {
    lock();
    defer unlock();
    return pending_len == 0 and ready_len == 0 and !running;
}

/// Queue one URL. Repeated requests for the same URL collapse into the one
/// already waiting or loaded. A single worker drains the queue in order.
pub fn request(alloc: std.mem.Allocator, io: std.Io, url: []const u8) bool {
    if (url.len == 0 or url.len > 2048) return false;

    lock();
    if (!queued(url)) {
        if (pending_len == queue_cap) {
            unlock();
            return false;
        }
        const owned = alloc.dupe(u8, url) catch {
            unlock();
            return false;
        };
        const tail = (pending_head + pending_len) % queue_cap;
        pending[tail] = owned;
        pending_len += 1;
    }
    worker_alloc = alloc;
    worker_io = io;
    // A previous spawn may have failed while URLs were already queued; a
    // duplicate request still has to restart the drain.
    const spawn = !running and pending_len > 0;
    if (spawn) {
        running = true;
        stopping = false;
    }
    unlock();

    if (spawn) {
        const thread = std.Thread.spawn(.{}, workerMain, .{}) catch {
            lock();
            running = false;
            unlock();
            return false;
        };
        thread.detach();
    }
    return true;
}

pub fn take(out: *Result) bool {
    const wait_t = nowNs();
    lock();
    const waited = nowNs() -| wait_t;
    if (ready_len == 0) {
        unlock();
        if (waited >= 1 * std.time.ns_per_ms) {
            logz.log("perf: art take waited {d:.2}ms", .{@as(f64, @floatFromInt(waited)) / @as(f64, @floatFromInt(std.time.ns_per_ms))});
        }
        return false;
    }
    out.* = ready[ready_head];
    ready[ready_head] = .{};
    ready_head = (ready_head + 1) % queue_cap;
    ready_len -= 1;
    unlock();
    if (waited >= 1 * std.time.ns_per_ms) {
        logz.log("perf: art take waited {d:.2}ms", .{@as(f64, @floatFromInt(waited)) / @as(f64, @floatFromInt(std.time.ns_per_ms))});
    }
    return true;
}

pub fn reset(alloc: std.mem.Allocator) void {
    _ = alloc;
    lock();
    stopping = true;
    unlock();

    while (true) {
        lock();
        const busy = running;
        unlock();
        if (!busy) break;
        std.Thread.yield() catch {};
    }

    // Requests may have been queued with a different allocator than the one
    // passed here (tests do exactly that), so release with the allocator the
    // worker was started with.
    const owner = worker_alloc;
    lock();
    while (pending_len > 0) {
        const u = pending[pending_head].?;
        pending[pending_head] = null;
        pending_head = (pending_head + 1) % queue_cap;
        pending_len -= 1;
        owner.free(u);
    }
    while (ready_len > 0) {
        var res = ready[ready_head];
        ready[ready_head] = .{};
        ready_head = (ready_head + 1) % queue_cap;
        ready_len -= 1;
        res.deinit(owner);
    }
    pending_head = 0;
    ready_head = 0;
    inflight = null;
    stopping = false;
    running = false;
    unlock();
}

fn workerMain() void {
    // Artwork decode/scan is pure background work. Nice it down so a cold
    // Cider cache (or a 512px WebP decode) cannot starve the UI thread or the
    // compositor while the card is animating.
    _ = std.os.linux.syscall3(.setpriority, 0, 0, 10);
    while (true) {
        lock();
        if (stopping or pending_len == 0) {
            running = false;
            unlock();
            return;
        }
        const url = pending[pending_head].?;
        pending[pending_head] = null;
        pending_head = (pending_head + 1) % queue_cap;
        pending_len -= 1;
        inflight = url;
        const alloc = worker_alloc;
        const io = worker_io;
        unlock();

        const load_t = nowNs();
        var cover = load(alloc, io, url);
        const load_ns = nowNs() -| load_t;

        lock();
        inflight = null;
        if (stopping) {
            unlock();
            alloc.free(url);
            cover.deinit(alloc);
            lock();
            running = false;
            unlock();
            return;
        }
        const tail = (ready_head + ready_len) % queue_cap;
        ready[tail] = .{ .url = url, .cover = cover, .elapsed_ns = load_ns };
        ready_len += 1;
        unlock();
    }
}

/// Resolve one URL all the way to pixels. Missing sources return an empty
/// cover, which the caller remembers as a miss instead of retrying forever.
pub fn load(alloc: std.mem.Allocator, io: std.Io, url: []const u8) mpris_art.Cover {
    if (mpris_art.isCiderCache(url)) return cider_art.find(alloc, io, url) orelse .{};
    const path = mpris_art.resolve(alloc, url) orelse return .{};
    defer alloc.free(path);
    if (path.len == 0) return .{};
    if (mpris_art.isCiderCache(path)) return cider_art.find(alloc, io, path) orelse .{};
    if (cover_cache.find(alloc, io, url)) |cover| return cover;
    const cover = blk: {
        if (path[0] == '/') break :blk mpris_art.loadFile(alloc, io, path);
        switch (mpris_art.schemeOf(path)) {
            .http, .https => {
                const bytes = mpris_art.fetchBytes(alloc, io, path) catch break :blk null;
                defer alloc.free(bytes);
                break :blk mpris_art.decode(alloc, bytes);
            },
            else => break :blk null,
        }
    } orelse return .{};
    cover_cache.store(io, url, cover);
    return cover;
}

test "cider-art-cache: reset leaves no published work" {
    reset(std.testing.allocator);
    try std.testing.expect(idle());
}

test "cider-art-cache: duplicate requests collapse and reset drains them" {
    reset(std.testing.allocator);
    _ = request(std.testing.allocator, std.testing.io, "");
    try std.testing.expect(idle());
    reset(std.testing.allocator);
}

test "cider-art-cache: one worker drains a whole visible batch" {
    reset(std.testing.allocator);
    defer reset(std.testing.allocator);
    const a = "/nonexistent/event-horizon-cider-art-a.png";
    const b = "/nonexistent/event-horizon-cider-art-b.png";
    try std.testing.expect(request(std.heap.page_allocator, std.testing.io, a));
    try std.testing.expect(request(std.heap.page_allocator, std.testing.io, a));
    try std.testing.expect(request(std.heap.page_allocator, std.testing.io, b));
    try std.testing.expect(!idle());

    var seen_a = false;
    var seen_b = false;
    var spins: usize = 0;
    while ((!seen_a or !seen_b) and spins < 1_000) : (spins += 1) {
        var res: Result = .{};
        if (take(&res)) {
            defer res.deinit(std.heap.page_allocator);
            const url = res.url orelse continue;
            try std.testing.expect(!res.cover.present());
            if (std.mem.eql(u8, url, a)) seen_a = true;
            if (std.mem.eql(u8, url, b)) seen_b = true;
        } else {
            std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
        }
    }
    try std.testing.expect(seen_a and seen_b);
    try std.testing.expect(idle());
}
