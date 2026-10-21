const std = @import("std");

pub const Format = enum { unknown, png, jpeg, webp, gif, bmp, svg };

pub fn sniffFormat(data: []const u8) Format {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) return .jpeg;
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return .webp;
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) return .gif;
    if (data.len >= 2 and data[0] == 'B' and data[1] == 'M') return .bmp;
    if (data.len >= 5 and std.mem.eql(u8, data[0..5], "<?xml")) return .svg;
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "<svg")) return .svg;
    return .unknown;
}

pub fn pngDimensions(data: []const u8) ?struct { w: u32, h: u32 } {
    if (sniffFormat(data) != .png) return null;
    if (data.len < 33) return null;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, data[16..20], .big);
    const h = std.mem.readInt(u32, data[20..24], .big);
    if (w == 0 or h == 0 or w > 100000 or h > 100000) return null;
    return .{ .w = w, .h = h };
}

pub fn isVideoPath(path: []const u8) bool {
    const exts = [_][]const u8{ ".mp4", ".webm", ".mkv", ".mov", ".avi" };
    for (exts) |e| {
        if (path.len >= e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

test "image: format sniff + png dimensions" {
    const t = std.testing;
    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 1, 0, 0, 0, 0, 80, 8, 2, 0, 0, 0, 0, 0, 0, 0 };
    try t.expectEqual(Format.png, sniffFormat(&png));
    const dims = pngDimensions(&png).?;
    try t.expectEqual(@as(u32, 256), dims.w);
    try t.expectEqual(@as(u32, 80), dims.h);
    try t.expectEqual(Format.jpeg, sniffFormat(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 }));
    try t.expectEqual(Format.webp, sniffFormat("RIFF\x00\x00\x00\x00WEBP"));
    try t.expectEqual(Format.unknown, sniffFormat("hello"));
    try t.expect(pngDimensions("short") == null);
    try t.expect(isVideoPath("clip.MP4"));
    try t.expect(!isVideoPath("photo.png"));
}
