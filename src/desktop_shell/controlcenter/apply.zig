//! Slider writes that do not block the pointer.
//!
//! Dragging an output/input/mixer slider produces one action per pointer
//! motion, and each action used to run `pactl` (falling back to `wpctl`)
//! inline: fork, exec, wait — tens of milliseconds on the Wayland loop
//! thread, so motion events queued behind the child and the slider dragged
//! at a fraction of the pointer's speed.
//!
//! Coalesced writes plus a suppress window, kept here for a subprocess backend:
//!
//! - **coalesced writes.** `request*` only stores the newest value per
//!   channel; one worker thread drains the queue. pactl therefore runs no
//!   faster than it can return, intermediate drag samples are skipped, and
//!   order is preserved because a single thread drains. The pointer thread
//!   touches a mutex, an integer and a condvar and returns. The worker
//!   additionally spaces batch starts 16 ms apart (`apply_ms`), the same
//!   gate on `audioLastApplyMs`, so a backend that answers in
//!   3 ms still sees at most one spawn per frame instead of one per motion
//!   event.
//! - **a suppress window** (`audioIgnoreStateUntilMs = now + 180`). The
//!   1 s live poll runs `pactl get-*` and would otherwise read the value the
//!   backend had *before* an in-flight write landed, snapping the slider
//!   back for a frame. `suppressEcho` substitutes what we last wrote while
//!   the window is open.
//!
//! Only the loop thread calls `request*` and `suppressEcho`, so the stamp
//! fields need no lock — the mutex guards the queue alone.

const std = @import("std");
const live_audio = @import("live_audio.zig");
const anim = @import("../dock/anim.zig");

/// `audioIgnoreStateUntilMs = now + 180`.
pub const ignore_ms: u64 = 180;

/// Rate gate: two applies start at most 16 ms apart.
/// pactl can return in a few milliseconds on a healthy box, so coalescing
/// alone would still mean one process spawn per pointer-motion event.
pub const apply_ms: u64 = 16;

/// Newest-wins coalescing slot. A drag writes far faster than pactl can
/// return, so only the latest sample per channel matters; `dirty` is the
/// worker's wake condition.
pub const Queue = struct {
    sink_pct: i32 = -1,
    source_pct: i32 = -1,
    stream_id: i32 = -1,
    stream_pct: i32 = -1,
    stream_is_input: bool = false,
    dirty: bool = false,

    /// Move the pending batch out and leave an idle queue behind.
    pub fn take(self: *Queue) Queue {
        const batch = self.*;
        self.* = .{};
        return batch;
    }

    pub fn empty(self: *const Queue) bool {
        return !self.dirty;
    }
};

var mu = std.Io.Mutex.init;
var cv = std.Io.Condition.init;
var queue: Queue = .{};
var worker_running: bool = false;

// Loop-thread-only suppress stamps (see the module doc).
var sink_applied_pct: i32 = -1;
var sink_ignore_until_ms: u64 = 0;
var source_applied_pct: i32 = -1;
var source_ignore_until_ms: u64 = 0;
var stream_applied_id: i32 = -1;
var stream_applied_pct: i32 = -1;
var stream_ignore_until_ms: u64 = 0;

fn worker(io: std.Io) void {
    while (true) {
        mu.lockUncancelable(io);
        while (queue.empty()) cv.waitUncancelable(io, &mu);
        const batch = queue.take();
        mu.unlock(io);

        // One channel at a time, in queue order: two threads racing pactl
        // could land an older sample after a newer one.
        const started_ns = anim.monotonicNs();
        if (batch.sink_pct >= 0) _ = live_audio.setSinkVolume(io, batch.sink_pct);
        if (batch.source_pct >= 0) _ = live_audio.setSourceVolume(io, batch.source_pct);
        if (batch.stream_id >= 0 and batch.stream_pct >= 0) {
            _ = live_audio.setStreamVolume(io, batch.stream_id, batch.stream_is_input, batch.stream_pct);
        }

        // Space batch starts by at least `apply_ms` (16 ms gate). The sleep only holds the *worker*: the mutex is free, so
        // motions arriving meanwhile coalesce into the next take and the newest
        // value is the one that lands.
        const elapsed = anim.monotonicNs() -| started_ns;
        const min_ns = apply_ms * std.time.ns_per_ms;
        if (elapsed < min_ns) {
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = @intCast(min_ns - elapsed) };
            _ = std.os.linux.nanosleep(&ts, null);
        }
    }
}

/// Queue a write and wake the worker. Never blocks on a child process.
fn submit(io: std.Io, ch: Channel, id: i32, is_input: bool, pct: i32) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    switch (ch) {
        .sink => queue.sink_pct = pct,
        .source => queue.source_pct = pct,
        .stream => {
            queue.stream_id = id;
            queue.stream_is_input = is_input;
            queue.stream_pct = pct;
        },
    }
    queue.dirty = true;
    cv.signal(io);
    if (worker_running) return;
    worker_running = true;
    const t = std.Thread.spawn(.{}, worker, .{io}) catch {
        // No thread (resource exhaustion): the next request retries, and
        // falling back to an inline write would put the stall back.
        worker_running = false;
        return;
    };
    t.detach();
}

const Channel = enum { sink, source, stream };

pub fn requestSink(now_ms: u64, io: std.Io, pct: i32) void {
    sink_applied_pct = pct;
    sink_ignore_until_ms = now_ms + ignore_ms;
    submit(io, .sink, -1, false, pct);
}

pub fn requestSource(now_ms: u64, io: std.Io, pct: i32) void {
    source_applied_pct = pct;
    source_ignore_until_ms = now_ms + ignore_ms;
    submit(io, .source, -1, false, pct);
}

pub fn requestStream(now_ms: u64, io: std.Io, id: i32, is_input: bool, pct: i32) void {
    stream_applied_id = id;
    stream_applied_pct = pct;
    stream_ignore_until_ms = now_ms + ignore_ms;
    submit(io, .stream, id, is_input, pct);
}

/// The poll-side suppress window: overwrite the freshly read values with the
/// ones we wrote while the backend is still catching up, including the
/// `volume_pct <= 0` derivation of `muted`.
pub fn suppressEcho(now_ms: u64, snap: *live_audio.Snapshot) void {
    if (now_ms < sink_ignore_until_ms and sink_applied_pct >= 0) {
        const p = std.math.clamp(sink_applied_pct, 0, 150);
        snap.out.volume_pct = p;
        snap.out.muted = p <= 0;
    }
    if (now_ms < source_ignore_until_ms and source_applied_pct >= 0) {
        const p = std.math.clamp(source_applied_pct, 0, 150);
        snap.in.volume_pct = p;
        snap.in.muted = p <= 0;
    }
    if (now_ms < stream_ignore_until_ms and stream_applied_id >= 0 and stream_applied_pct >= 0) {
        const p = std.math.clamp(stream_applied_pct, 0, 150);
        // The snapshot views the query's lists as const, but the list itself
        // is the query's own (rebuilt wholesale on the next poll) — same
        // mutable-in-place contract the drag override already relies on.
        const outs: []live_audio.Stream = @constCast(snap.out_streams);
        const ins: []live_audio.Stream = @constCast(snap.in_streams);
        for (outs) |*s| {
            if (s.id == stream_applied_id) s.volume_pct = p;
        }
        for (ins) |*s| {
            if (s.id == stream_applied_id) s.volume_pct = p;
        }
    }
}

test "cc-apply: the queue keeps only the newest sample per channel" {
    const t = std.testing;
    var q = Queue{};
    try t.expect(q.empty());

    q.sink_pct = 40;
    q.dirty = true;
    q.sink_pct = 55;
    q.sink_pct = 70;
    q.stream_id = 12;
    q.stream_is_input = false;
    q.stream_pct = 30;
    q.dirty = true;

    const batch = q.take();
    try t.expectEqual(@as(i32, 70), batch.sink_pct);
    try t.expectEqual(@as(i32, 12), batch.stream_id);
    try t.expect(!batch.stream_is_input);
    try t.expectEqual(@as(i32, 30), batch.stream_pct);
    // Drained means idle: the worker sleeps until the next request.
    try t.expect(q.empty());
    try t.expectEqual(@as(i32, -1), q.sink_pct);

    // A second take on an idle queue yields an empty batch rather than
    // replaying the old one.
    const again = q.take();
    try t.expect(again.empty());
    try t.expectEqual(@as(i32, -1), again.sink_pct);
    try t.expectEqual(@as(i32, -1), again.stream_id);
}

test "cc-apply: the suppress window shows what we wrote, then the backend" {
    const t = std.testing;
    var streams = [_]live_audio.Stream{.{ .id = 7, .volume_pct = 90 }};
    var snap = live_audio.Snapshot{
        .out = .{ .volume_pct = 100 },
        .in = .{ .volume_pct = 40 },
        .out_streams = &streams,
    };
    // Stamps the way the request paths set them.
    sink_applied_pct = 55;
    sink_ignore_until_ms = 1_000 + ignore_ms;
    source_applied_pct = 12;
    source_ignore_until_ms = 1_000 + ignore_ms;
    stream_applied_id = 7;
    stream_applied_pct = 3;
    stream_ignore_until_ms = 1_000 + ignore_ms;
    defer {
        sink_applied_pct = -1;
        sink_ignore_until_ms = 0;
        source_applied_pct = -1;
        source_ignore_until_ms = 0;
        stream_applied_id = -1;
        stream_applied_pct = -1;
        stream_ignore_until_ms = 0;
    }

    // Inside the window: the write wins over the stale read.
    suppressEcho(1_050, &snap);
    try t.expectEqual(@as(i32, 55), snap.out.volume_pct);
    try t.expect(!snap.out.muted);
    try t.expectEqual(@as(i32, 12), snap.in.volume_pct);
    try t.expectEqual(@as(i32, 3), snap.out_streams[0].volume_pct);

    // Dragging to zero reads back as muted.
    sink_applied_pct = 0;
    suppressEcho(1_100, &snap);
    try t.expect(snap.out.muted);

    // Past the window the backend's own answer stands. The stream list is
    // mutated in place by the call above, so re-seed it the way the next
    // poll does (every poll rebuilds the query's lists from scratch).
    streams[0].volume_pct = 90;
    snap.out.volume_pct = 100;
    snap.out.muted = false;
    sink_applied_pct = 55;
    suppressEcho(1_000 + ignore_ms + 1, &snap);
    try t.expectEqual(@as(i32, 100), snap.out.volume_pct);
    try t.expect(!snap.out.muted);
    try t.expectEqual(@as(i32, 90), snap.out_streams[0].volume_pct);
}
