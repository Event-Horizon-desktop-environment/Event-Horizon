const std = @import("std");

pub const Surface = enum { dock, panel, taskbar, desktop, overview, notifications, wallpaper };

pub const Layer = enum { background, bottom, top, overlay };

test "shell surfaces enumerate" {
    try std.testing.expect(@intFromEnum(Surface.dock) == 0);
}
