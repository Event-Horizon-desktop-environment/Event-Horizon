const std = @import("std");

pub const Sample = struct {
    cpu_pct: f32 = 0,
    mem_used_mb: u64 = 0,
    mem_total_mb: u64 = 0,
};

pub fn cpuPct(prev_idle: u64, prev_total: u64, idle: u64, total: u64) f32 {
    const dt = total -| prev_total;
    const di = idle -| prev_idle;
    if (dt == 0) return 0;
    return @as(f32, @floatFromInt(dt -| di)) / @as(f32, @floatFromInt(dt)) * 100.0;
}

pub fn parseMeminfoLine(line: []const u8) ?struct { key: []const u8, kb: u64 } {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    const num = it.next() orelse return null;
    const kb = std.fmt.parseInt(u64, num, 10) catch return null;
    return .{ .key = key, .kb = kb };
}

pub fn memUsedPct(used_mb: u64, total_mb: u64) f32 {
    if (total_mb == 0) return 0;
    return @as(f32, @floatFromInt(used_mb)) / @as(f32, @floatFromInt(total_mb)) * 100.0;
}

test "sysmon: cpu + meminfo + pct" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f32, 50.0), cpuPct(100, 200, 150, 300), 0.01);
    try t.expectEqual(@as(f32, 0.0), cpuPct(0, 0, 0, 0));
    const p = parseMeminfoLine("MemTotal:       16384000 kB").?;
    try t.expectEqualStrings("MemTotal", p.key);
    try t.expectEqual(@as(u64, 16384000), p.kb);
    try t.expect(parseMeminfoLine("bogus") == null);
    try t.expectApproxEqAbs(@as(f32, 50.0), memUsedPct(8000, 16000), 0.01);
}
