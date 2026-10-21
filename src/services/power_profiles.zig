const std = @import("std");

pub const Profile = enum { performance, balanced, power_saver };

pub fn fromString(s: []const u8) ?Profile {
    if (std.mem.eql(u8, s, "performance")) return .performance;
    if (std.mem.eql(u8, s, "balanced")) return .balanced;
    if (std.mem.eql(u8, s, "power-saver")) return .power_saver;
    return null;
}

pub fn toString(p: Profile) []const u8 {
    return switch (p) {
        .performance => "performance",
        .balanced => "balanced",
        .power_saver => "power-saver",
    };
}

pub const Holder = struct {
    current: Profile = .balanced,
    held: bool = false,

    pub fn holdPerformance(self: *Holder) Profile {
        self.held = true;
        const prev = self.current;
        self.current = .performance;
        return prev;
    }

    pub fn release(self: *Holder, prev: Profile) void {
        self.held = false;
        self.current = prev;
    }
};

test "power-profiles: convert + hold" {
    const t = std.testing;
    try t.expectEqual(Profile.balanced, fromString("balanced").?);
    try t.expect(fromString("nope") == null);
    var h = Holder{};
    const prev = h.holdPerformance();
    try t.expectEqual(Profile.performance, h.current);
    h.release(prev);
    try t.expectEqual(Profile.balanced, h.current);
}
