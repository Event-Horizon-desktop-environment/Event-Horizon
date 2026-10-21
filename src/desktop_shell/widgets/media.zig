const std = @import("std");

pub const MediaInfo = struct {
    title: []const u8 = "Nothing playing",
    artist: []const u8 = "",
    playing: bool = false,
    position_us: i64 = 0,
    length_us: i64 = 0,
};

pub fn progressPct(m: MediaInfo) f64 {
    if (m.length_us <= 0) return 0;
    return @max(0.0, @min(1.0, @as(f64, @floatFromInt(m.position_us)) / @as(f64, @floatFromInt(m.length_us))));
}

fn two(alloc: std.mem.Allocator, v: i64) ![]u8 {
    if (v < 10) return std.fmt.allocPrint(alloc, "0{d}", .{v});
    return std.fmt.allocPrint(alloc, "{d}", .{v});
}

pub fn formatTimestamp(alloc: std.mem.Allocator, us: i64) ![]u8 {
    const total_s: i64 = @max(0, @divTrunc(us, 1000000));
    const m: i64 = @divTrunc(total_s, 60);
    const s: i64 = @mod(total_s, 60);
    const ss = try two(alloc, s);
    defer alloc.free(ss);
    if (m >= 60) {
        const mm = try two(alloc, @mod(m, 60));
        defer alloc.free(mm);
        return std.fmt.allocPrint(alloc, "{d}:{s}:{s}", .{ @divTrunc(m, 60), mm, ss });
    }
    return std.fmt.allocPrint(alloc, "{d}:{s}", .{ m, ss });
}

pub fn displayTitle(m: MediaInfo, buf: []u8) []const u8 {
    if (m.artist.len == 0) {
        const n = @min(m.title.len, buf.len);
        @memcpy(buf[0..n], m.title[0..n]);
        return buf[0..n];
    }
    const r = std.fmt.bufPrint(buf, "{s} — {s}", .{ m.artist, m.title }) catch buf[0..0];
    return r;
}

test "media: progress + timestamps + title" {
    const t = std.testing;
    const m = MediaInfo{ .title = "Song", .artist = "Band", .playing = true, .position_us = 90000000, .length_us = 180000000 };
    try t.expectEqual(@as(f64, 0.5), progressPct(m));
    const a = try formatTimestamp(t.allocator, 90000000);
    defer t.allocator.free(a);
    try t.expectEqualStrings("1:30", a);
    const b = try formatTimestamp(t.allocator, 3723000000);
    defer t.allocator.free(b);
    try t.expectEqualStrings("1:02:03", b);
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("Band — Song", displayTitle(m, &buf));
}
