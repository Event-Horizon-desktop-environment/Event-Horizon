const std = @import("std");

pub const Channel = struct {
    name: []const u8,
    volume_pct: i32 = 100,
    muted: bool = false,
    is_default: bool = false,
};

pub fn defaultChannel(channels: []const Channel) ?*const Channel {
    for (channels) |*c| {
        if (c.is_default) return c;
    }
    if (channels.len > 0) return &channels[0];
    return null;
}

pub fn iconFor(volume_pct: i32, muted: bool) []const u8 {
    if (muted) return "volume_mute";
    if (volume_pct <= 0) return "volume_mute";
    if (volume_pct < 50) return "volume_down";
    return "volume_up";
}

test "volume-widget: default + icons" {
    const t = std.testing;
    const chs = [_]Channel{
        .{ .name = "a", .volume_pct = 30 },
        .{ .name = "b", .volume_pct = 80, .is_default = true },
    };
    try t.expectEqualStrings("b", defaultChannel(&chs).?.name);
    try t.expectEqualStrings("volume_down", iconFor(30, false));
    try t.expectEqualStrings("volume_mute", iconFor(80, true));
}
