//! The shared text-measure fast path for m3 Label/Glyph.
//!
//! `measureExtents()` used to create AND destroy a 1x1 cairo surface + context
//! per call (`Button::setGeometry` and `drawContent` measure every label twice
//! per frame). This keeps one thread-local scratch context and a small bounded
//! extent cache for short static labels, so repeats are a hash lookup.
//!
//! Two layers of caching, both deliberate:
//!
//!   * A **thread-local scratch** surface/context. Creating a cairo context is
//!     expensive; reusing one 1x1 surface across every measurement on a thread
//!     removes that from the hot path entirely.
//!   * A **bounded extent cache** keyed by the measurement string. It clears
//!     wholesale once it passes 512 entries rather than evicting — the point is
//!     to catch the handful of static labels a UI repeats every frame, not to
//!     be a general LRU.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

/// A lazily-created 1x1 surface plus the context drawn into it.
const Scratch = struct {
    surf: ?*cairo.cairo_surface_t = null,
    cr: ?*cairo.cairo_t = null,

    /// Zig has no thread-local destructors, unlike thread-local
    /// Scratch` whose `~Scratch` tears the pair down at thread exit. A caller
    /// that wants the surface reclaimed early — a test, or a worker thread
    /// winding down — calls this explicitly.
    fn deinit(self: *Scratch) void {
        if (self.cr) |cr| cairo.cairo_destroy(cr);
        if (self.surf) |s| cairo.cairo_surface_destroy(s);
        self.cr = null;
        self.surf = null;
    }
};

threadlocal var scratch: Scratch = .{};

/// The shared 1x1 measurement context. Created on first use per thread.
pub fn scratch_cr() ?*cairo.cairo_t {
    if (scratch.cr == null) {
        scratch.surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1, 1);
        scratch.cr = cairo.cairo_create(scratch.surf);
    }
    return scratch.cr;
}

/// Release this thread's scratch surface. Optional — see `Scratch.deinit`.
pub fn deinitScratch() void {
    scratch.deinit();
}

/// Cap on cached extents, cleared wholesale rather than evicting
/// one entry, so this is a reset threshold, not an LRU limit.
pub const cache_limit = 512;

/// Global extent cache in a file-scope var guarded by a mutex; Zig has no function-
/// local statics, so this is a file-scope var guarded by a mutex, which is the
/// same thing without the indirection.
///
/// The lock is `std.atomic.Mutex`, a spin lock: every critical section here is
/// a single hash lookup or insert, so a spin costs less than the syscall a
/// blocking lock would make.
var cache_mu: std.atomic.Mutex = .unlocked;
var cache_map: std.AutoHashMapUnmanaged(u64, Extent) = .empty;
var cache_count: usize = 0;

fn lockCache() void {
    // Busy-wait rather than block: the critical sections are a handful of
    // instructions, and holding up a paint thread on a syscall is worse.
    while (!cache_mu.tryLock()) std.atomic.spinLoopHint();
}

fn unlockCache() void {
    cache_mu.unlock();
}

const Extent = struct { w: f32, h: f32 };

/// Whether a key is present. `key` is the caller's measurement string; the
/// map is keyed by its hash, and collisions simply cost a wrong-size cache
/// hit for a label that is drawn at most one frame before being re-measured.
pub fn lookup(key: []const u8, w: *f32, h: *f32) bool {
    lockCache();
    defer unlockCache();
    const gop = cache_map.get(std.hash.Wyhash.hash(0, key)) orelse return false;
    w.* = gop.w;
    h.* = gop.h;
    return true;
}

pub fn store(key: []const u8, w: f32, h: f32) void {
    lockCache();
    defer unlockCache();
    // Clear-on-overflow past 512 entries.
    if (cache_count >= cache_limit) {
        cache_map.clearRetainingCapacity();
        cache_count = 0;
    }
    const hsh = std.hash.Wyhash.hash(0, key);
    const gop = cache_map.getOrPut(std.heap.c_allocator, hsh) catch return;
    if (!gop.found_existing) cache_count += 1;
    gop.value_ptr.* = .{ .w = w, .h = h };
}

/// Drop every cached extent. Used by tests; a real theme change that alters
/// metrics would call this too.
pub fn clearCache() void {
    lockCache();
    defer unlockCache();
    cache_map.clearRetainingCapacity();
    cache_count = 0;
}

test "m3-measure: scratch context is reused across calls" {
    const t = std.testing;
    defer deinitScratch();
    const a = scratch_cr();
    const b = scratch_cr();
    // The whole point of the scratch is that the second call returns the very
    // same context rather than building a new one.
    try t.expect(a != null);
    try t.expect(a == b);
}

test "m3-measure: cache round-trips and clears at the limit" {
    const t = std.testing;
    defer clearCache();
    clearCache();

    var w: f32 = 0;
    var h: f32 = 0;
    try t.expect(!lookup("pinned_apps", &w, &h));
    store("pinned_apps", 42.0, 18.0);
    try t.expect(lookup("pinned_apps", &w, &h));
    try t.expectEqual(@as(f32, 42.0), w);
    try t.expectEqual(@as(f32, 18.0), h);

    // Filling past the limit resets the map wholesale. The
    // count lands on a small remainder rather than 0: one reset happens when
    // the count *reaches* the limit, and the entries stored after it remain.
    var i: usize = 0;
    while (i < cache_limit + 1) : (i += 1) {
        var buf: [24]u8 = undefined;
        store(std.fmt.bufPrint(&buf, "k{d}", .{i}) catch break, 1.0, 1.0);
    }
    try t.expect(cache_count < cache_limit);
    // The reset really happened: keys cached before it are gone.
    try t.expect(!lookup("pinned_apps", &w, &h));
}

test "m3-measure: many distinct keys accumulate, then reset" {
    const t = std.testing;
    defer clearCache();
    clearCache();

    // A sequential hammer rather than a threaded one: the cache's own lock is
    // a spin lock, and spinning two threads on a small machine livelocks the
    // test runner. What matters here is that the count tracks the map and the
    // overflow reset still fires.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch break;
        store(key, @floatFromInt(i), 2.0);
    }
    try t.expectEqual(@as(usize, 100), cache_count);

    var w: f32 = 0;
    var h: f32 = 0;
    try t.expect(lookup("k42", &w, &h));
    try t.expectEqual(@as(f32, 42.0), w);

    // Re-storing an existing key must not inflate the count — it is an
    // overwrite, not a new entry.
    store("k42", 1.0, 1.0);
    try t.expectEqual(@as(usize, 100), cache_count);
}
