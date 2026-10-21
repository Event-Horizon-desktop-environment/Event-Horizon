const std = @import("std");

pub const Mode = enum { image, video, live };

pub fn isVideoPath(path: []const u8) bool {
    const exts = [_][]const u8{ ".mp4", ".webm", ".mkv", ".mov", ".avi" };
    for (exts) |e| {
        if (path.len >= e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

test "wallpaper: video detection" {
    const t = std.testing;
    try t.expect(isVideoPath("clip.MP4"));
    try t.expect(!isVideoPath("photo.png"));
}
