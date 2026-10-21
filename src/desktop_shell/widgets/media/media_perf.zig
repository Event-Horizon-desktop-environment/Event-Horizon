//! Always-on paint/cadence profiler for the media pill (and its hosts).
//!
//! Same data the C++ surface probe emits, so the rewrite answers the same
//! question: is the progress bar chunky because the host repaints it too
//! rarely (cadence), or because each paint is slow (cost)?
//!
//! No command or env toggle: probes live in each process, and `logz.log`
//! writes summaries into that process's own log (horizon-dock-zig.log), one
//! line every 2 s while something is being painted:
//!
//!   [media-perf] surface=dock frames=19 pill:avg=0.210ms max=0.840ms
//!                dt:avg=500ms max=502ms min=498ms spikes=0 slow_frames=0
//!                reason=ring playing=1 pos_est=83.2s pos_snap=79.5s
//!                est_ahead=3.70s dur=210s
//!   [media-perf] surface=dock frames> paint:avg=2.4ms max=5.1ms
//!   [media-perf] surface=dock phases> body=0.080ms content=0.400ms ring=0.020ms
//!
//! plus a rate-limited warning the moment a single paint or host frame
//! exceeds its budget (1.5 ms for the pill, 12 ms for a host frame).
//!
//! Per-call cost: two `nowUs()` reads for the pill and a
//! few more per frame — far below a microsecond. Dock/desktop run their event
//! loops single-threaded, so the file-static probes need no locking.

const std = @import("std");
const logz = @import("../../../logz.zig");

/// Monotonic microseconds; same primitive the dock's anim clock uses.
fn nowUs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const s: i64 = @intCast(@max(ts.sec, 0));
    const n: i64 = @intCast(@max(ts.nsec, 0));
    return s * std.time.us_per_s + @divTrunc(n, 1000);
}

pub const Surface = enum { dock, desktop };
const surface_names = [_][]const u8{ "dock", "desktop" };
const surface_count = surface_names.len;

/// Phase buckets; labels are adopted from whichever paint call first reaches
/// them, so the log names them by what the caller labelled them.
const max_phases = 4;

/// Host-frame buckets, measured beside the pill: what a whole repaint spends
/// on chrome (bar fill + border), the specialized widget slots, the generic
/// icon run, the tail (dragged pin) and the present (attach/damage/commit).
const max_fph = 6;

/// A pill paint slower than this prints as `slow_frames`.
const k_slow_pill_us: u64 = 1500;
/// A host frame slower than this warns: the target is "everything below
/// 5ms", so any frame over that budget names its phase split immediately.
const k_slow_frame_us: u64 = 5000;
/// A repaint gap above this is a "why did it freeze then" spike.
const k_dt_spike_us: u64 = 250_000;

pub const FrameData = struct {
    playing: bool = false,
    /// The playhead the pill actually drew (projected).
    est_us: i64 = 0,
    /// The MPRIS snapshot position the projection started from.
    snap_us: i64 = 0,
    dur_us: i64 = 0,
};

var probes: [surface_count]Probe = .{ Probe{}, Probe{} };
var probes_init = false;

pub fn get(surface: Surface) *Probe {
    if (!probes_init) {
        for (0..surface_count) |i| probes[i].name = surface_names[i];
        probes_init = true;
    }
    return &probes[@intFromEnum(surface)];
}

pub const Probe = struct {
    name: []const u8 = "media",

    // Cadence.
    last_pill_us: i64 = 0,
    dt_sum_us: u64 = 0,
    dt_max_us: u64 = 0,
    dt_min_us: u64 = 0,
    dt_spikes: u64 = 0,

    // Pill cost.
    pill_sum_us: u64 = 0,
    pill_max_us: u64 = 0,
    slow_pill: u64 = 0,
    frames: u64 = 0,
    active: bool = false,
    pill_begin_us: i64 = 0,
    phase_begin_us: i64 = 0,

    // Host frame cost (repaint() → present() while a media reason drove it).
    frame_pending: bool = false,
    frame_begin_us: i64 = 0,
    frame_sum_us: u64 = 0,
    frame_max_us: u64 = 0,
    slow_frames: u64 = 0,
    n_frames: u64 = 0,

    // Where a frame's time goes: chrome / widgets / icons / tail / present.
    fph: [max_fph]u64 = .{ 0, 0, 0, 0, 0, 0 },
    flabels: [max_fph]?[]const u8 = .{ null, null, null, null, null, null },
    fphase_open: usize = 0,
    fphase_begin_us: i64 = 0,

    // Per-slot cost: one clock read per slot head settles the painter that
    // just ran. `slot_best_*` is this frame's argmax; `slot_max_*` the
    // window's, printed as `worst=` so long frames name their culprit.
    slot_open: bool = false,
    slot_begin_us: i64 = 0,
    slot_best_us: u64 = 0,
    slot_best_name: []const u8 = "",
    slot_max_us: u64 = 0,
    slot_max_name: []const u8 = "",

    phases: [max_phases]u64 = .{ 0, 0, 0, 0 },
    labels: [max_phases]?[]const u8 = .{ null, null, null, null },

    // Replay data.
    playing: bool = false,
    est_us: i64 = 0,
    snap_us: i64 = 0,
    dur_us: i64 = 0,
    reason: []const u8 = "unset",
    frame_reason: ?[]const u8 = null,

    // Throttles.
    window_open_us: i64 = 0,
    last_warn_us: i64 = 0,

    // Scratch for fphText (single-threaded dock loop: no lock needed).
    fph_buf: [384]u8 = undefined,
    fph_buf_len: usize = 0,

    pub fn noteReason(self: *Probe, r: []const u8) void {
        self.reason = r;
        self.frame_reason = r;
    }

    /// Opens phase 0 for this pill paint.
    pub fn begin(self: *Probe, phase0_label: []const u8) void {
        const now = nowUs();
        if (self.last_pill_us != 0) {
            const dt: u64 = @intCast(@max(0, now - self.last_pill_us));
            if (dt > k_dt_spike_us) self.dt_spikes += 1;
            self.dt_sum_us += dt;
            if (dt > self.dt_max_us) self.dt_max_us = dt;
            if (self.dt_min_us == 0 or dt < self.dt_min_us) self.dt_min_us = dt;
        }
        self.last_pill_us = now;
        self.pill_begin_us = now;
        self.phase_begin_us = now;
        self.active = true;
        if (self.labels[0] == null) self.labels[0] = phase0_label;
    }

    /// Closes the phase open since begin()/the last milestone, opens `idx`.
    pub fn milestone(self: *Probe, idx: usize, label: []const u8) void {
        if (!self.active) return;
        const now = nowUs();
        const us: u64 = @intCast(@max(0, now - self.phase_begin_us));
        self.phases[idx] += us;
        if (self.labels[idx] == null) self.labels[idx] = label;
        self.phase_begin_us = now;
    }

    pub fn end(self: *Probe, data: FrameData) void {
        if (!self.active) return;
        self.active = false;
        const now = nowUs();
        const whole: u64 = @intCast(@max(0, now - self.pill_begin_us));
        self.pill_sum_us += whole;
        if (whole > self.pill_max_us) self.pill_max_us = whole;
        self.frames += 1;
        if (whole > k_slow_pill_us) self.slow_pill += 1;
        self.playing = data.playing;
        self.est_us = data.est_us;
        self.snap_us = data.snap_us;
        self.dur_us = data.dur_us;
        self.emit(now, whole);
    }

    /// Called by the host when a repaint starts for a media-driven frame.
    /// Bucket 0 ("chrome") is implicitly open from here.
    pub fn beginFrame(self: *Probe, reason: []const u8) void {
        self.frame_pending = true;
        self.frame_begin_us = nowUs();
        self.frame_reason = reason;
        self.fphase_open = 0;
        if (self.flabels[0] == null) self.flabels[0] = "chrome";
        self.fphase_begin_us = self.frame_begin_us;
        self.slot_open = false;
        self.slot_best_us = 0;
        self.slot_best_name = "";
    }

    /// Closes the span open since the last milestone into its bucket and
    /// opens `idx`. Safe to no-op when no media-driven frame is in flight.
    pub fn frameMilestone(self: *Probe, idx: usize, label: []const u8) void {
        if (!self.frame_pending) return;
        const now = nowUs();
        self.fph[self.fphase_open] += @intCast(@max(0, now - self.fphase_begin_us));
        if (self.flabels[idx] == null) self.flabels[idx] = label;
        self.fphase_open = idx;
        self.fphase_begin_us = now;
    }

    /// A slot painter is about to run: re-arm the per-slot cost clock.
    pub fn slotTick(self: *Probe) void {
        if (!self.frame_pending) return;
        self.slot_begin_us = nowUs();
        self.slot_open = true;
    }

    /// Head of the next slot: the span since the previous head belongs to the
    /// painter named `last_kind_name`. Bills it into this frame's argmax.
    pub fn settleSlot(self: *Probe, last_kind_name: []const u8) void {
        if (!self.frame_pending) return;
        const now = nowUs();
        if (self.slot_open) {
            const us: u64 = @intCast(@max(0, now - self.slot_begin_us));
            if (us > self.slot_best_us) {
                self.slot_best_us = us;
                self.slot_best_name = last_kind_name;
            }
        }
        self.slot_begin_us = now;
        self.slot_open = true;
    }

    /// Marks an aborted repaint so its partial cost is not billed.
    pub fn cancelFrame(self: *Probe) void {
        self.frame_pending = false;
        self.frame_reason = null;
        self.slot_open = false;
    }

    /// Called by the host once a repaint has presented; no-op for frames that
    /// were not driven by a media reason.
    pub fn endFrame(self: *Probe) void {
        if (!self.frame_pending) return;
        self.frame_pending = false;
        const now = nowUs();
        // Close the still-open last-slot span under the argmax so far is the
        // painter reached last; the host settles it explicitly if it can, so
        // only an unsettled tail lands here.
        if (self.slot_open) {
            const us: u64 = @intCast(@max(0, now - self.slot_begin_us));
            if (us > self.slot_best_us) {
                self.slot_best_us = us;
                // A tail span unset by the host: no better name exists.
                if (self.slot_best_name.len == 0) self.slot_best_name = "tail";
            }
            self.slot_open = false;
        }
        if (self.slot_best_us > self.slot_max_us) {
            self.slot_max_us = self.slot_best_us;
            self.slot_max_name = self.slot_best_name;
        }
        self.fph[self.fphase_open] += @intCast(@max(0, now - self.fphase_begin_us));
        const reason = self.frame_reason orelse "unset";
        self.frame_reason = null;
        const whole: u64 = @intCast(@max(0, now - self.frame_begin_us));
        self.frame_sum_us += whole;
        if (whole > self.frame_max_us) self.frame_max_us = whole;
        self.n_frames += 1;
        if (whole > k_slow_frame_us) {
            self.slow_frames += 1;
            if (now - self.last_warn_us > 1_000_000) {
                self.last_warn_us = now;
                logz.log(
                    "[media-perf] surface={s} slow_frame={d}us frame_phases>{s} worst_slot={s}={d}us reason={s}",
                    .{ self.name, whole, self.fphText(), self.slot_best_name, self.slot_best_us, reason },
                );
            }
        }
    }

    /// " chrome=… widgets=… " — bucket averages over the current window.
    pub fn fphText(self: *Probe) []const u8 {
        if (self.n_frames == 0) return "";
        self.fph_buf_len = 0;
        const d: u64 = @max(self.n_frames, 1);
        for (self.fph, 0..) |us, i| {
            if (us == 0) continue;
            const label = self.flabels[i] orelse "fph?";
            const left = self.fph_buf[self.fph_buf_len..];
            const wrote = std.fmt.bufPrint(left, " {s}={d}us", .{ label, us / d }) catch break;
            self.fph_buf_len += wrote.len;
        }
        return self.fph_buf[0..self.fph_buf_len];
    }

    fn emit(self: *Probe, now: i64, whole: u64) void {
        if (whole > k_slow_pill_us and now - self.last_warn_us > 1_000_000) {
            self.last_warn_us = now;
            logz.log("[media-perf] surface={s} slow_pill={d}ms reason={s} playing={}", .{ self.name, whole / 1000, self.reason, self.playing });
        }
        if (self.window_open_us == 0) {
            self.window_open_us = now;
            return;
        }
        if (now - self.window_open_us < 2_000_000) return;
        self.window_open_us = now;
        const n: u64 = @max(self.frames, 1);
        var phases_buf: [384]u8 = undefined;
        var phases_len: usize = 0;
        for (self.phases, 0..) |us, i| {
            if (us == 0) continue;
            const label = self.labels[i] orelse "ph?";
            const left = phases_buf[phases_len..];
            const wrote = std.fmt.bufPrint(left, " {s}={d}us", .{ label, us / n }) catch break;
            phases_len += wrote.len;
        }
        const n_frames = self.n_frames;
        logz.log(
            "[media-perf] surface={s} " ++
                "frames={d} pill:avg={d}us max={d}us " ++
                "dt:avg={d}us max={d}us min={d}us spikes={d} slow_pill={d} " ++
                "reason={s} playing={} pos_est={d}.{d:0>2}s pos_snap={d}.{d:0>2}s est_ahead={d}us dur={d}us" ++
                "{s}",
            .{
                self.name,
                self.frames,
                self.pill_sum_us / n,
                self.pill_max_us,
                self.dt_sum_us / n,
                self.dt_max_us,
                self.dt_min_us,
                self.dt_spikes,
                self.slow_pill,
                self.reason,
                self.playing,
                @divTrunc(self.est_us, 1_000_000),
                @mod(@as(u64, @intCast(@max(0, self.est_us))), 1_000_000) / 10_000,
                @divTrunc(self.snap_us, 1_000_000),
                @mod(@as(u64, @intCast(@max(0, self.snap_us))), 1_000_000) / 10_000,
                self.est_us - self.snap_us,
                self.dur_us,
                if (phases_len > 0) phases_buf[0..phases_len] else "",
            },
        );
        if (n_frames > 0) {
            logz.log(
                "[media-perf] surface={s} paint:avg={d}us max={d}us slow_frames={d} reason={s} fph>{s} worst_slot={s}={d}us",
                .{
                    self.name,
                    self.frame_sum_us / @max(n_frames, 1),
                    self.frame_max_us,
                    self.slow_frames,
                    reasonText(self.frame_reason),
                    self.fphText(),
                    self.slot_max_name,
                    self.slot_max_us,
                },
            );
        }
        self.resetWindow();
    }

    fn resetWindow(self: *Probe) void {
        self.frames = 0;
        self.pill_sum_us = 0;
        self.pill_max_us = 0;
        self.slow_pill = 0;
        self.dt_sum_us = 0;
        self.dt_max_us = 0;
        self.dt_min_us = 0;
        self.dt_spikes = 0;
        self.frame_sum_us = 0;
        self.frame_max_us = 0;
        self.slow_frames = 0;
        self.n_frames = 0;
        for (&self.phases) |*p| p.* = 0;
        for (&self.fph) |*p| p.* = 0;
        for (&self.flabels) |*l| l.* = null;
        self.slot_max_us = 0;
        self.slot_max_name = "";
        self.slot_open = false;
    }
};

fn reasonText(r: ?[]const u8) []const u8 {
    return r orelse "unset";
}

test "probe: summaries are throttled, not per-frame" {
    const p = &probes[0];
    p.* = .{};
    get(.dock).name = surface_names[0];
    // Paint #1 opens the 2 s window; the count survives it.
    get(.dock).begin("body");
    get(.dock).milestone(1, "ring");
    get(.dock).end(.{ .playing = true, .est_us = 1_500_000, .snap_us = 1_000_000, .dur_us = 60_000_000 });
    try std.testing.expectEqual(@as(u64, 1), get(.dock).frames);
    // Paint #2 inside the window accumulates into the same summary — the
    // counters are still live, nothing printed yet.
    get(.dock).window_open_us = nowUs() - 1_900_000;
    get(.dock).begin("body");
    get(.dock).end(.{});
    try std.testing.expectEqual(@as(u64, 2), get(.dock).frames);
    // Coming due (2 s passed), the next paint prints and the window resets.
    get(.dock).window_open_us = nowUs() - 2_100_000;
    get(.dock).begin("body");
    get(.dock).end(.{});
    try std.testing.expectEqual(@as(u64, 0), get(.dock).frames);
    try std.testing.expect(get(.dock).window_open_us > 0);
}

test "probe: frame phases bill the right buckets" {
    const p = &probes[1];
    p.* = .{};
    p.name = surface_names[1];
    p.beginFrame("ring");
    try std.testing.expectEqual(@as(usize, 0), p.fphase_open);
    // chrome ran, then a widget slot painted, then the icon run.
    p.frameMilestone(1, "widgets");
    p.frameMilestone(2, "icons");
    p.frameMilestone(4, "present");
    p.endFrame();
    try std.testing.expectEqual(@as(u64, 1), p.n_frames);
    try std.testing.expect(!p.frame_pending);
    // All four buckets received non-negative time; "present" is open so it
    // always holds the tail span (the commit itself).
    for (p.fph) |us| try std.testing.expect(us <= p.frame_max_us + 1);
    p.frame_sum_us = 0; // sanity: the printed text covers all named buckets.
    var named: usize = 0;
    for (p.flabels) |l| {
        if (l != null) named += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), named); // chrome/widgets/icons/present
    // And a cancelled frame bills nothing.
    const before = p.n_frames;
    p.beginFrame("ring");
    p.cancelFrame();
    try std.testing.expectEqual(before, p.n_frames);
    _ = &p;
}
