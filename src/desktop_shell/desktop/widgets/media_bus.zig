const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const mpris = @import("../../../services/mpris_client.zig");
const mpris_art = @import("../../../services/mpris_art.zig");
const cover_worker = @import("../../../services/cover_worker.zig");

// Shared MPRIS snapshot bus for the desktop media widgets — the Zig side of
// the `DockMpris*` widgets hold. The desktop layer polls its client
// and publishes snapshots here; both media painters read the same snapshot,
// and clicks dispatch through the installed action handler. Cover art flows
// through `cover_worker`, cached per URL.

pub const Snapshot = mpris.Snapshot;

var snap_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var current: Snapshot = .{};
/// Anchor for the position projection (C++ `projected_position`): the bus
/// publishes at the 1s service cadence, so between publishes the position is
/// extrapolated forward while Playing — otherwise the seekbar steps once a
/// second instead of sliding.
var anchor_pos_us: i64 = 0;
var anchor_ms: i64 = 0;

fn monotonicMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 + @divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), 1_000_000);
}

pub fn publish(s: Snapshot) void {
    snap_store.deinit();
    snap_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = snap_store.allocator();
    var out = s;
    out.bus_name = a.dupe(u8, s.bus_name) catch "";
    out.title = a.dupe(u8, s.title) catch "";
    out.artist = a.dupe(u8, s.artist) catch "";
    out.album = a.dupe(u8, s.album) catch "";
    out.art_url = a.dupe(u8, s.art_url) catch "";
    out.track_url = a.dupe(u8, s.track_url) catch "";
    out.track_id = a.dupe(u8, s.track_id) catch "";
    out.status = a.dupe(u8, s.status) catch "";
    out.loop_status = a.dupe(u8, s.loop_status) catch "";
    current = out;
    anchor_pos_us = s.position_us;
    anchor_ms = monotonicMs();
}

pub fn get() Snapshot {
    var s = current;
    // C++ `DockMpris::projected_position`: while Playing, carry the position
    // forward from the last anchor (max 5s, so a stalled poll does not run
    // away), clamped into the track.
    if (std.mem.eql(u8, s.status, "Playing")) {
        const delta_ms = monotonicMs() - anchor_ms;
        if (delta_ms > 0 and delta_ms <= 5000) {
            s.position_us = anchor_pos_us + delta_ms * 1000;
            if (s.position_us < 0) s.position_us = 0;
            if (s.duration_us > 0 and s.position_us > s.duration_us) s.position_us = s.duration_us;
        }
    }
    return s;
}

pub const Action = enum { play_pause, next, previous, shuffle, loop, seek };

pub const Handler = struct {
    ctx: *anyopaque,
    act: *const fn (ctx: *anyopaque, a: Action, pos_us: i64) bool,
};

var handler: ?Handler = null;

pub fn setHandler(h: ?Handler) void {
    handler = h;
}

pub fn dispatch(a: Action, pos_us: i64) bool {
    const h = handler orelse return false;
    return h.act(h.ctx, a, pos_us);
}

// Cover art cache: one address at a time, pixels owned here. The address —
// and the retry budget — belong to one snapshot, so paints of the same
// track reuse them; a frame never re-derives, re-allocates or re-asks.
const max_cover_misses: u8 = 6;
const retry_base_ms: i64 = 2000;
const retry_max_ms: i64 = 10_000;

var art_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var art = struct {
    url: []const u8 = "",
    w: i32 = 0,
    h: i32 = 0,
    px: []u8 = &.{},
    /// Hash of the snapshot fields the address was derived from.
    mask: u64 = 0,
    derived: bool = false,
    misses: u8 = 0,
    retry_ms: i64 = 0,
}{};

fn clearArt() void {
    art_arena.deinit();
    art_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    art = .{};
}

/// Identity of the track as far as its art is concerned. The private-cache
/// marker is hashed from these same fields, so the mask moves whenever the
/// address does.
fn snapshotMask(s: Snapshot) u64 {
    var h = std.hash.Wyhash.init(0);
    for ([_][]const u8{ s.bus_name, s.art_url, s.track_url, s.title, s.artist, s.album }) |part| {
        h.update(part);
        h.update("\x00");
    }
    return h.final();
}

/// Paint the current track's cover scaled into the `s`-px square at (x, y)
/// with corner radius `r`, asking the worker for it when it is not on hand
/// yet. Returns true when art was painted.
///
/// The worker thread outlives any paint frame, so its allocations (and the
/// matching `deinit`) always go through the process-lifetime page
/// allocator — never a caller arena. A frame arena here was the
/// use-after-free that crashed the process.
pub fn paintArt(cr: ?*cairo.cairo_t, io: std.Io, snap: Snapshot, x: f64, y: f64, s: f64, r: f64) bool {
    const c = cr orelse return false;
    const alloc = std.heap.page_allocator;
    const mask = snapshotMask(snap);
    if (!art.derived or mask != art.mask) {
        // A new track: the old pixels and the old budget go with it. The
        // address is derived once here — the fallbacks (a video still, a
        // private-cache marker) allocate, and a paint may happen sixty
        // times a second.
        clearArt();
        art.mask = mask;
        art.derived = true;
        const src = mpris_art.sourceFor(alloc, .{
            .bus_name = snap.bus_name,
            .art_url = snap.art_url,
            .track_url = snap.track_url,
            .title = snap.title,
            .artist = snap.artist,
            .album = snap.album,
        });
        if (src) |u| {
            defer alloc.free(u);
            art.url = art_arena.allocator().dupe(u8, u) catch "";
        }
    }
    if (art.url.len == 0) return false;
    if (art.px.len == 0 and art.misses < max_cover_misses and monotonicMs() >= art.retry_ms) {
        _ = cover_worker.request(alloc, io, art.url);
    }
    var res: cover_worker.Result = .{};
    if (cover_worker.take(&res)) {
        defer res.deinit(alloc);
        if (res.url != null and std.mem.eql(u8, res.url.?, art.url)) {
            if (res.cover.present()) {
                const a = art_arena.allocator();
                art.w = res.cover.w;
                art.h = res.cover.h;
                art.px = a.dupe(u8, res.cover.pixels) catch &.{};
                art.misses = 0;
                art.retry_ms = 0;
            } else {
                // The source answered with nothing: wait before asking
                // again, backing off per miss, so a dead URL costs one
                // request per window instead of one per frame.
                art.misses += 1;
                const step: u6 = @intCast(@min(art.misses - 1, 5));
                art.retry_ms = monotonicMs() + @min(retry_base_ms << step, retry_max_ms);
            }
        }
    }
    if (art.px.len == 0 or art.w <= 0 or art.h <= 0) return false;
    const surf = cairo.cairo_image_surface_create_for_data(art.px.ptr, cairo.CAIRO_FORMAT_ARGB32, art.w, art.h, art.w * 4);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) return false;
    defer cairo.cairo_surface_destroy(surf);
    const sc = @max(s / @as(f64, @floatFromInt(art.w)), s / @as(f64, @floatFromInt(art.h)));
    cairo.cairo_save(c);
    roundRect(c, x, y, s, s, r);
    cairo.cairo_clip(c);
    cairo.cairo_translate(c, x + (s - @as(f64, @floatFromInt(art.w)) * sc) * 0.5, y + (s - @as(f64, @floatFromInt(art.h)) * sc) * 0.5);
    cairo.cairo_scale(c, sc, sc);
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    const pat = cairo.cairo_get_source(c);
    cairo.cairo_pattern_set_extend(pat, cairo.CAIRO_EXTEND_PAD);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
    return true;
}

fn roundRect(c: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const cr = c orelse return;
    const rr = @min(r, @min(w, h) * 0.5);
    cairo.cairo_new_path(cr);
    cairo.cairo_arc(cr, x + w - rr, y + rr, rr, -std.math.pi * 0.5, 0);
    cairo.cairo_arc(cr, x + w - rr, y + h - rr, rr, 0, std.math.pi * 0.5);
    cairo.cairo_arc(cr, x + rr, y + h - rr, rr, std.math.pi * 0.5, std.math.pi);
    cairo.cairo_arc(cr, x + rr, y + rr, rr, std.math.pi, std.math.pi * 1.5);
    cairo.cairo_close_path(cr);
}

/// Triangle-wave marquee offset (`marquee_triangle_offset`).
pub fn marqueeOffset(range_px: f64, tsec: f64, period_sec: f64) f64 {
    if (range_px <= 0.5 or period_sec <= 0.0) return 0.0;
    const u = @mod(tsec / period_sec, 1.0);
    if (u < 0.0) return 0.0;
    const tri = if (u < 0.5) u * 2.0 else 2.0 - u * 2.0;
    return tri * range_px;
}

/// `m:ss` / `-m:ss` timestamp.
pub fn formatMmss(buf: []u8, us: i64, neg: bool) []const u8 {
    const v: u64 = if (us < 0) 0 else @intCast(us);
    const total = v / 1_000_000;
    if (neg) {
        return std.fmt.bufPrint(buf, "-{d}:{d:0>2}", .{ total / 60, total % 60 }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ total / 60, total % 60 }) catch buf[0..0];
}

test "settings-desktop-media-bus: marquee + timestamps" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f64, 0.0), marqueeOffset(0.0, 4.5, 9.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 50.0), marqueeOffset(100.0, 2.25, 9.0), 1e-9);
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("1:05", formatMmss(&buf, 65_000_000, false));
    try t.expectEqualStrings("-0:30", formatMmss(&buf, 30_000_000, true));
    const s = get();
    try t.expect(!s.realActive());
}

test "settings-desktop-media-bus: the art address follows the track" {
    const t = std.testing;
    var a: Snapshot = .{};
    a.title = "one";
    a.art_url = "file:///a.jpg";
    var b: Snapshot = .{};
    b.title = "one";
    b.art_url = "file:///b.jpg";
    try t.expect(snapshotMask(a) != snapshotMask(b));
    try t.expectEqual(snapshotMask(a), snapshotMask(a));
    // No destination: no painting, and no worker traffic either.
    try t.expect(!paintArt(null, undefined, a, 0, 0, 10, 2));
}
