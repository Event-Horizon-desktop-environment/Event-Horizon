const std = @import("std");

// Live-wallpaper settings tab.
// Same design as wallpaper tab: gallery grid + video-thumb rows + apply bar.

pub const Mode = enum { video, slideshow, off };

pub const Model = struct {
    mode: Mode = .video,
    path: []const u8 = "",
    muted: bool = true,
    loop: bool = true,

    pub fn modeLabel(self: *const Model) []const u8 {
        return switch (self.mode) {
            .video => "Video",
            .slideshow => "Slideshow",
            .off => "Off",
        };
    }
};

pub fn isVideoPath(path: []const u8) bool {
    const exts = [_][]const u8{ ".mp4", ".webm", ".mkv", ".mov", ".avi" };
    for (exts) |e| {
        if (path.len >= e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

test "settings-live-wallpaper-tab: mode + video ext" {
    const t = std.testing;
    const m = Model{};
    try t.expectEqualStrings("Video", m.modeLabel());
    try t.expect(isVideoPath("clip.MP4"));
    try t.expect(!isVideoPath("photo.png"));
}
