const std = @import("std");

pub const Tab = enum {
    appearance,
    sound,
    network,
    bluetooth,
    keyboard,
    dock,
    taskbar,
    panel,
    wallpaper,
    notifications,
};

pub const SoundState = struct {
    sink_volume: i32 = 100,
    sink_muted: bool = false,
    source_volume: i32 = 100,
    source_muted: bool = false,

    pub fn setSinkVolume(self: *SoundState, v: i32, allow_overamp: bool) void {
        const hi: i32 = if (allow_overamp) 150 else 100;
        self.sink_volume = @max(0, @min(hi, v));
    }
};

pub const WifiEntry = struct {
    ssid: []const u8,
    strength: u8,
    secured: bool,
    known: bool = false,
};

pub const BtDevice = struct {
    address: []const u8,
    name: []const u8,
    connected: bool = false,
    paired: bool = false,
};

pub const KbdPreview = struct {
    layout: []const u8 = "us",
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,

    pub fn repeatCharsPer(self: *const KbdPreview, seconds: u32) u32 {
        return @intCast(@max(0, self.repeat_rate) * @as(i32, @intCast(seconds)));
    }
};

test "settings-models: sound clamp, kbd preview" {
    const t = std.testing;
    var s = SoundState{};
    s.setSinkVolume(140, false);
    try t.expectEqual(@as(i32, 100), s.sink_volume);
    s.setSinkVolume(140, true);
    try t.expectEqual(@as(i32, 140), s.sink_volume);
    const k = KbdPreview{ .repeat_rate = 25 };
    try t.expectEqual(@as(u32, 50), k.repeatCharsPer(2));
    try t.expectEqual(Tab.sound, Tab.sound);
}
