const std = @import("std");

pub const Stats = struct {
    samples: u32 = 0,
    total_mbps: f64 = 0,
    min_mbps: f64 = std.math.inf(f64),
    max_mbps: f64 = 0,

    pub fn add(self: *Stats, mbps: f64) void {
        self.samples += 1;
        self.total_mbps += mbps;
        self.min_mbps = @min(self.min_mbps, mbps);
        self.max_mbps = @max(self.max_mbps, mbps);
    }

    pub fn avg(self: *const Stats) f64 {
        if (self.samples == 0) return 0;
        return self.total_mbps / @as(f64, @floatFromInt(self.samples));
    }
};

pub const Job = enum { idle, reading, writing, done, failed };

pub const Bench = struct {
    stats: Stats = .{},
    job: Job = .idle,
    progress_pct: u8 = 0,

    pub fn start(self: *Bench, job: Job) void {
        self.job = job;
        self.progress_pct = 0;
        self.stats = .{};
    }

    pub fn finish(self: *Bench, ok: bool) void {
        self.job = if (ok) .done else .failed;
        if (ok) self.progress_pct = 100;
    }
};

test "disks-bench: stats + job" {
    const t = std.testing;
    var b = Bench{};
    b.start(.reading);
    b.stats.add(100);
    b.stats.add(200);
    try t.expectEqual(@as(f64, 150.0), b.stats.avg());
    try t.expectEqual(@as(f64, 100.0), b.stats.min_mbps);
    b.finish(true);
    try t.expectEqual(Job.done, b.job);
    try t.expectEqual(@as(u8, 100), b.progress_pct);
}
