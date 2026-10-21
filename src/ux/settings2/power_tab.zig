const std = @import("std");

pub const Profile = enum { performance, balanced, power_saver };

pub fn profileName(p: Profile) []const u8 {
    return switch (p) {
        .performance => "Performance",
        .balanced => "Balanced",
        .power_saver => "Power Saver",
    };
}

pub const Model = struct {
    profile: Profile = .balanced,
    display_timeout_min: i32 = 10,
    suspend_timeout_min: i32 = 30,
    show_battery_pct: bool = true,

    pub fn setDisplayTimeout(self: *Model, v: i32) void {
        self.display_timeout_min = @max(1, @min(120, v));
    }
};

test "settings-power: profile + clamp" {
    const t = std.testing;
    var m = Model{};
    m.setDisplayTimeout(999);
    try t.expectEqual(@as(i32, 120), m.display_timeout_min);
    try t.expectEqualStrings("Power Saver", profileName(.power_saver));
}
