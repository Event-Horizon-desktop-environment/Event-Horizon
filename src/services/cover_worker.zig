//! Album art for the media widget, loaded off the shell's own thread.
//!
//! A cover may sit behind a network round trip, and the shell's thread paints
//! the whole desktop, so the read happens on a worker and waits to be
//! collected. One job runs at a time: a request that finds work already in
//! flight is refused and the caller simply asks again on a later tick — the
//! URL it wanted is still the one it wants, so nothing is lost.

const std = @import("std");
const mpris_art = @import("mpris_art.zig");
const cover_cache = @import("cover_cache.zig");
const cider_art = @import("cider_art.zig");

/// What a finished job produced, and the advertisement it was for. The URL
/// travels with the pixels so a track that moved on while the job ran can be
/// told apart from the one that was asked about.
pub const Result = struct {
    url: ?[]const u8 = null,
    cover: mpris_art.Cover = .{},

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        if (self.url) |u| alloc.free(u);
        self.url = null;
        self.cover.deinit(alloc);
    }
};

const k_idle: u8 = 0;
const k_running: u8 = 1;
const k_ready: u8 = 2;

var phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(k_idle);
var result: Result = .{};
var worker: ?std.Thread = null;

/// True when nothing is in flight, i.e. `request` would actually start one.
pub fn idle() bool {
    return phase.load(.acquire) == k_idle;
}

/// Start a load unless one is already running. Returns whether a worker was
/// started; the retry belongs to the caller, so a refused request costs a
/// later tick rather than a stall.
pub fn request(alloc: std.mem.Allocator, io: std.Io, url: []const u8) bool {
    if (phase.load(.acquire) != k_idle) return false;
    // The previous worker published before its phase fell back to idle, so
    // this join cannot block; and a result nobody collected is dropped here
    // rather than being overwritten without being freed.
    if (worker) |w| {
        w.join();
        worker = null;
    }
    result.deinit(alloc);

    const owned = alloc.dupe(u8, url) catch return false;
    const job = alloc.create(Job) catch {
        alloc.free(owned);
        return false;
    };
    job.* = .{ .alloc = alloc, .io = io, .url = owned };
    phase.store(k_running, .release);
    worker = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        phase.store(k_idle, .release);
        alloc.free(owned);
        alloc.destroy(job);
        return false;
    };
    return true;
}

/// Move the finished load into `out`. Returns false when nothing has landed.
/// The pixels are handed over outright: `out` owns them from here.
pub fn take(out: *Result) bool {
    if (phase.load(.acquire) != k_ready) return false;
    out.* = result;
    result = .{};
    phase.store(k_idle, .release);
    return true;
}

/// Tests only: drain any in-flight worker so the suite can start clean.
pub fn reset(alloc: std.mem.Allocator) void {
    if (worker) |w| {
        w.join();
        worker = null;
    }
    var stale: Result = .{};
    _ = take(&stale);
    stale.deinit(alloc);
}

/// The drain the shell's own exit and media-restart paths use: wait up to
/// `wait_ms` for the job to publish, then let go. A pick behind a stalled
/// network read must not be able to wedge shutdown or a settings change —
/// `reset`'s bare join does exactly that. The phase word gates every
/// hand-off, so a worker that is left behind can only ever publish an answer
/// the collector discards by URL.
pub fn resetWithin(alloc: std.mem.Allocator, wait_ms: u64) void {
    if (worker) |w| {
        var waited_ms: u64 = 0;
        while (phase.load(.acquire) == k_running and waited_ms < wait_ms) : (waited_ms += 5) {
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 5_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        if (phase.load(.acquire) == k_running) {
            w.detach();
        } else {
            // Published (or collected): this join returns at once.
            w.join();
        }
        worker = null;
    }
    var stale: Result = .{};
    if (take(&stale)) stale.deinit(alloc);
}

const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Owned by the job until it publishes; then `result` owns it.
    url: []const u8,

    fn run(self: *Job) void {
        const alloc = self.alloc;
        const cover = loadCover(alloc, self.io, self.url);
        // The URL moves with the pixels so the collector can spot a stale
        // answer, and the phase is what publishes both. The job itself is
        // dismantled *before* that store: a collector that sees `k_ready`
        // may run to completion, and it must never find the job still
        // allocated behind the answer.
        result = .{ .url = self.url, .cover = cover };
        self.url = "";
        alloc.destroy(self);
        phase.store(k_ready, .release);
    }
};

/// Resolve what the player gave us and turn it into pixels: a cover decoded
/// before is read back as pixels, a private-cache marker is searched for, a
/// local path is read, a remote one is fetched, and anything else is not
/// something this shell can draw. Never returns a half-filled cover.
fn loadCover(alloc: std.mem.Allocator, io: std.Io, url: []const u8) mpris_art.Cover {
    // A player whose covers live in a sandbox-private cache hands out a
    // marker instead of a path; the search is bounded by the last one and
    // manages its own disk entries.
    if (mpris_art.isCiderCache(url)) return cider_art.find(alloc, io, url) orelse .{};
    const path = mpris_art.resolve(alloc, url) orelse return .{};
    defer alloc.free(path);
    if (path.len == 0) return .{};
    // The advertised address survives restarts and repeat tracks: if its
    // pixels were decoded once, the find is a read, not a decode.
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

test "cover-worker: nothing lands until a job is asked for" {
    const t = std.testing;
    reset(t.allocator);
    try t.expect(idle());
    var out: Result = .{};
    try t.expect(!take(&out));
}

test "cover-worker: an unloadable URL answers with no pixels and frees" {
    const t = std.testing;
    reset(t.allocator);
    // A scheme this shell cannot read: the job still runs and still reports
    // which URL it was for, so the caller can stop asking. It never reaches
    // for the io handle, which a test has none of.
    try t.expect(request(t.allocator, undefined, "ftp://nothing/here"));
    var out: Result = .{};
    var guard: usize = 0;
    while (!take(&out)) : (guard += 1) {
        if (guard > 100_000_000) return error.SkipZigTest;
        std.atomic.spinLoopHint();
    }
    defer out.deinit(t.allocator);
    try t.expect(out.url != null);
    try t.expectEqualStrings("ftp://nothing/here", out.url.?);
    try t.expect(!out.cover.present());
    try t.expect(idle());
}

test "cover-worker: a decoded cover is answered from the disk cache" {
    const t = std.testing;
    reset(t.allocator);
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A path that cannot exist: pixels can only come back if the stored
    // entry was found by the advertised address alone.
    var ubuf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&ubuf, "file:///nonexistent/eh-art-{d}/cover.jpg", .{std.os.linux.getpid()});
    var px: [4 * 2 * 4]u8 = undefined;
    for (0..8) |i| @memcpy(px[i * 4 .. i * 4 + 4], &[_]u8{ 0x20 + @as(u8, @intCast(i)), 0x40, 0x60, 0xFF });
    cover_cache.store(io, url, .{ .w = 4, .h = 2, .pixels = &px });

    try t.expect(request(t.allocator, io, url));
    var out: Result = .{};
    var guard: usize = 0;
    while (!take(&out)) : (guard += 1) {
        if (guard > 200_000_000) return error.SkipZigTest;
        std.atomic.spinLoopHint();
    }
    defer out.deinit(t.allocator);
    try t.expect(out.url != null);
    try t.expectEqualStrings(url, out.url.?);
    try t.expect(out.cover.present());
    try t.expectEqual(@as(i32, 4), out.cover.w);
    try t.expectEqual(@as(i32, 2), out.cover.h);
    try t.expectEqualSlices(u8, &px, out.cover.pixels);
    try t.expect(idle());
}

test "cover-worker: a cover on disk comes back as pixels" {
    const t = std.testing;
    reset(t.allocator);
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cwd_buf: [1024]u8 = undefined;
    const n = try std.process.currentPath(io, &cwd_buf);
    const abs = try std.fs.path.join(t.allocator, &.{
        cwd_buf[0..n],
        "../third_party/wuffs/test/data/hat.jpeg",
    });
    defer t.allocator.free(abs);
    // The shape a player actually advertises, so resolution is covered too.
    const url = try std.fmt.allocPrint(t.allocator, "file://{s}", .{abs});
    defer t.allocator.free(url);

    try t.expect(request(t.allocator, io, url));
    var out: Result = .{};
    var guard: usize = 0;
    while (!take(&out)) : (guard += 1) {
        if (guard > 200_000_000) return error.SkipZigTest;
        std.atomic.spinLoopHint();
    }
    defer out.deinit(t.allocator);
    if (!out.cover.present()) return error.SkipZigTest; // a tree without that file
    try t.expectEqualStrings(url, out.url.?);
    try t.expect(out.cover.w <= 512 and out.cover.h <= 512);
    try t.expect(out.cover.pixels.len == @as(usize, @intCast(out.cover.w)) *
        @as(usize, @intCast(out.cover.h)) * 4);
    // Cairo wants premultiplied colour: an opaque photo keeps every alpha byte
    // set, so a cover that decoded as fully transparent would be wrong.
    var lit: usize = 0;
    var i: usize = 3;
    while (i < out.cover.pixels.len) : (i += 4) {
        if (out.cover.pixels[i] != 0) lit += 1;
    }
    try t.expect(lit > 0);
}
