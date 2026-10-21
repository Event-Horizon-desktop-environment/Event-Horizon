//! Notification pipeline benchmarks and failure log.
//!
//! Per-process counters, split sender (album-art loads, pushes) and
//! receiver (frames, drops, paint/layout latency), plus a capped ring of
//! recent failures with change serials so reporters poll for new ones.
//! Durations are monotonic-ms, per-hop only, never compared across
//! processes. Single-threaded by construction on both users (dock sender,
//! daemon receiver): no locks.
//!
//! Typical wires: the sender logs `senderSummary` when it changes (or
//! hourly), the daemon logs `receiverSummary` + `failuresSince` every 60 s
//! when the serial moved — same 60 s bench cadence.

const std = @import("std");

pub const kFailureCap: usize = 16;

pub const Stats = struct {
    // Sender: album-art loads.
    art_loads_ok: u64 = 0,
    art_loads_fail: u64 = 0,
    art_loads_stale: u64 = 0,
    art_load_ms_total: u64 = 0,
    art_load_ms_max: u64 = 0,
    art_in_flight: bool = false,
    art_kick_ms: i64 = 0,

    // Sender: pushes.
    mpris_pushed: u64 = 0,
    art_pushed: u64 = 0,
    art_bytes_pushed: u64 = 0,
    emit_no_art: u64 = 0,
    push_failed: u64 = 0,

    // Receiver: frames.
    mpris_rx: u64 = 0,
    art_rx: u64 = 0,
    art_rx_bytes: u64 = 0,
    art_attached: u64 = 0,
    drop_malformed: u64 = 0,
    drop_no_entry: u64 = 0,
    drop_blob: u64 = 0,

    // Receiver: paint/layout.
    paints: u64 = 0,
    paint_ms_total: u64 = 0,
    paint_ms_max: u64 = 0,
    layouts: u64 = 0,
    layout_ms_total: u64 = 0,
    layout_ms_max: u64 = 0,

    failures: [kFailureCap][]const u8 = [_][]const u8{""} ** kFailureCap,
    failure_serials: [kFailureCap]u64 = [_]u64{0} ** kFailureCap,
    nfailures: usize = 0,
    change_serial: u64 = 0,
    boot_ms: i64 = 0,

    pub fn init(now_ms: i64) Stats {
        return .{ .boot_ms = now_ms };
    }

    pub fn deinit(self: *Stats, alloc: std.mem.Allocator) void {
        for (self.failures[0..self.nfailures]) |f| {
            if (f.len > 0) alloc.free(f);
        }
        self.nfailures = 0;
    }

    fn bump(self: *Stats) void {
        self.change_serial += 1;
    }

    fn tplus(self: *Stats, alloc: std.mem.Allocator, now_ms: i64) []u8 {
        const s: f64 = @as(f64, @floatFromInt(now_ms - self.boot_ms)) / 1000.0;
        return std.fmt.allocPrint(alloc, "T+{d:.1}s", .{s}) catch "";
    }

    fn noteFailure(self: *Stats, alloc: std.mem.Allocator, now_ms: i64, msg: []const u8) void {
        const tp = self.tplus(alloc, now_ms);
        defer if (tp.len > 0) alloc.free(tp);
        const stamped = std.fmt.allocPrint(alloc, "[{s}] {s}", .{ tp, msg }) catch return;
        if (self.nfailures < kFailureCap) {
            self.failures[self.nfailures] = stamped;
            self.failure_serials[self.nfailures] = self.change_serial + 1;
            self.nfailures += 1;
        } else {
            alloc.free(self.failures[0]);
            std.mem.copyForwards([]const u8, self.failures[0..], self.failures[1..]);
            std.mem.copyForwards(u64, self.failure_serials[0..], self.failure_serials[1..]);
            self.failures[kFailureCap - 1] = stamped;
            self.failure_serials[kFailureCap - 1] = self.change_serial + 1;
        }
        self.bump();
    }

    // -- sender ---------------------------------------------------------

    pub fn noteArtLoadKick(self: *Stats) void {
        self.art_in_flight = true;
        self.bump();
    }

    pub fn setArtKickMs(self: *Stats, now_ms: i64) void {
        self.art_kick_ms = now_ms;
    }

    /// Returns the load latency in ms (-1 when no kick was recorded).
    pub fn noteArtLoadDone(self: *Stats, alloc: std.mem.Allocator, now_ms: i64, ok: bool) i64 {
        const ms: i64 = if (self.art_kick_ms > 0) now_ms - self.art_kick_ms else -1;
        self.art_in_flight = false;
        self.art_kick_ms = 0;
        if (ok) {
            self.art_loads_ok += 1;
            if (ms >= 0) {
                self.art_load_ms_total += @intCast(ms);
                self.art_load_ms_max = @max(self.art_load_ms_max, @as(u64, @intCast(ms)));
            }
        } else {
            self.art_loads_fail += 1;
            const msg = std.fmt.allocPrint(alloc, "art-load FAIL after_ms={d}", .{ms}) catch "";
            defer if (msg.len > 0) alloc.free(msg);
            if (msg.len > 0) self.noteFailure(alloc, now_ms, msg);
        }
        self.bump();
        return ms;
    }

    pub fn noteArtLoadStale(self: *Stats, alloc: std.mem.Allocator, now_ms: i64) void {
        self.art_loads_stale += 1;
        self.noteFailure(alloc, now_ms, "art-load STALE (track moved on)");
        self.bump();
    }

    pub fn notePushMpris(self: *Stats) void {
        self.mpris_pushed += 1;
        self.bump();
    }

    pub fn notePushArt(self: *Stats, bytes: u64) void {
        self.art_pushed += 1;
        self.art_bytes_pushed += bytes;
        self.bump();
    }

    pub fn noteEmitNoArt(self: *Stats) void {
        self.emit_no_art += 1;
        self.bump();
    }

    pub fn notePushFailed(self: *Stats, alloc: std.mem.Allocator, now_ms: i64, what: []const u8) void {
        self.push_failed += 1;
        const msg = std.fmt.allocPrint(alloc, "push FAILED kind={s} (no IPC sender or bus down — toast never left this process)", .{what}) catch "";
        defer if (msg.len > 0) alloc.free(msg);
        if (msg.len > 0) self.noteFailure(alloc, now_ms, msg);
        self.bump();
    }

    pub fn artAvgMs(self: *const Stats) u64 {
        return if (self.art_loads_ok > 0) self.art_load_ms_total / self.art_loads_ok else 0;
    }

    pub fn senderSummary(self: *Stats, alloc: std.mem.Allocator) []u8 {
        return std.fmt.allocPrint(alloc, "art loads ok={d} fail={d} stale={d} avg_ms={d} max_ms={d} pushed mpris={d} art={d} ({d}B) no_art={d} push_failed={d}", .{
            self.art_loads_ok,  self.art_loads_fail, self.art_loads_stale,
            self.artAvgMs(),    self.art_load_ms_max,
            self.mpris_pushed,  self.art_pushed,      self.art_bytes_pushed,
            self.emit_no_art,   self.push_failed,
        }) catch "";
    }

    // -- receiver --------------------------------------------------------

    pub fn noteMprisRx(self: *Stats) void {
        self.mpris_rx += 1;
        self.bump();
    }

    pub fn noteArtRx(self: *Stats, bytes: u64) void {
        self.art_rx += 1;
        self.art_rx_bytes += bytes;
        self.bump();
    }

    pub fn noteArtAttached(self: *Stats) void {
        self.art_attached += 1;
        self.bump();
    }

    pub fn noteDropMalformed(self: *Stats, alloc: std.mem.Allocator, now_ms: i64) void {
        self.drop_malformed += 1;
        self.noteFailure(alloc, now_ms, "drop MALFORMED art frame");
        self.bump();
    }

    pub fn noteDropNoEntry(self: *Stats, alloc: std.mem.Allocator, now_ms: i64) void {
        self.drop_no_entry += 1;
        self.noteFailure(alloc, now_ms, "drop NO-ENTRY (art before notification)");
        self.bump();
    }

    pub fn noteDropBlob(self: *Stats, alloc: std.mem.Allocator, now_ms: i64, bytes: u64) void {
        self.drop_blob += 1;
        const msg = std.fmt.allocPrint(alloc, "drop BLOB-DECODE bytes={d}", .{bytes}) catch "";
        defer if (msg.len > 0) alloc.free(msg);
        if (msg.len > 0) self.noteFailure(alloc, now_ms, msg);
        self.bump();
    }

    pub fn notePaint(self: *Stats, ms: u64) void {
        self.paints += 1;
        self.paint_ms_total += ms;
        self.paint_ms_max = @max(self.paint_ms_max, ms);
        self.bump();
    }

    pub fn noteLayout(self: *Stats, ms: u64) void {
        self.layouts += 1;
        self.layout_ms_total += ms;
        self.layout_ms_max = @max(self.layout_ms_max, ms);
        self.bump();
    }

    pub fn paintAvgMs(self: *const Stats) u64 {
        return if (self.paints > 0) self.paint_ms_total / self.paints else 0;
    }

    pub fn layoutAvgMs(self: *const Stats) u64 {
        return if (self.layouts > 0) self.layout_ms_total / self.layouts else 0;
    }

    pub fn receiverSummary(self: *Stats, alloc: std.mem.Allocator) []u8 {
        return std.fmt.allocPrint(alloc, "rx mpris={d} art={d} ({d}B) attached={d} drops malformed={d} no_entry={d} blob={d} paint n={d} avg_ms={d} max_ms={d} layout n={d} avg_ms={d} max_ms={d}", .{
            self.mpris_rx, self.art_rx, self.art_rx_bytes, self.art_attached,
            self.drop_malformed, self.drop_no_entry, self.drop_blob,
            self.paints,   self.paintAvgMs(),       self.paint_ms_max,
            self.layouts,  self.layoutAvgMs(),      self.layout_ms_max,
        }) catch "";
    }

    /// New failures since `seen` (call with a kept cursor, initially 0).
    pub fn failuresSince(self: *Stats, alloc: std.mem.Allocator, seen: *u64) []u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        for (self.failures[0..self.nfailures], 0..) |f, i| {
            if (self.failure_serials[i] <= seen.*) continue;
            out.appendSlice(alloc, "  ") catch break;
            out.appendSlice(alloc, f) catch break;
            out.append(alloc, '\n') catch break;
        }
        seen.* = self.change_serial;
        return out.toOwnedSlice(alloc) catch "";
    }

    pub fn serial(self: *const Stats) u64 {
        return self.change_serial;
    }
};

/// Wall-timer: `var tm = scope(); defer stats.notePaint(tm.ms());`
/// records on every exit path.
pub const Scope = struct {
    t0: i64,
    pub fn ms(self: *const Scope, now_ms: i64) u64 {
        return @intCast(@max(0, now_ms - self.t0));
    }
};

pub fn scope(now_ms: i64) Scope {
    return .{ .t0 = now_ms };
}

test "notify-stats: counters, ring cap and summaries" {
    const t = std.testing;
    const a = t.allocator;
    var s = Stats.init(1000);
    defer s.deinit(a);
    s.setArtKickMs(1100);
    try t.expectEqual(@as(i64, 100), s.noteArtLoadDone(a, 1200, true));
    try t.expectEqual(@as(u64, 100), s.artAvgMs());
    s.notePushMpris();
    s.notePushArt(500);
    s.noteMprisRx();
    s.noteArtRx(500);
    s.noteArtAttached();
    s.notePaint(7);
    s.noteLayout(3);
    const sum = s.senderSummary(a);
    defer if (sum.len > 0) a.free(sum);
    try t.expect(std.mem.indexOf(u8, sum, "ok=1") != null);
    const rsum = s.receiverSummary(a);
    defer if (rsum.len > 0) a.free(rsum);
    try t.expect(std.mem.indexOf(u8, rsum, "attached=1") != null);
    // Ring caps at 16 and the cursor only yields fresh entries.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        s.noteDropMalformed(a, 2000);
    }
    try t.expectEqual(@as(usize, 16), s.nfailures);
    var seen: u64 = 0;
    const f1 = s.failuresSince(a, &seen);
    defer a.free(f1);
    try t.expect(f1.len > 0);
    const f2 = s.failuresSince(a, &seen);
    defer a.free(f2);
    try t.expectEqual(@as(usize, 0), f2.len);
}
