const std = @import("std");

pub const Op = enum { ask, sleep, hibernate, shutdown, reboot, logout, lock };

pub fn logindOp(op: Op) ?[]const u8 {
    return switch (op) {
        .sleep => "Suspend",
        .hibernate => "Hibernate",
        .shutdown => "PowerOff",
        .reboot => "Reboot",
        else => null,
    };
}

pub fn fromPowerButtonAction(v: i32) Op {
    return switch (v) {
        1 => .sleep,
        2 => .hibernate,
        3 => .shutdown,
        else => .ask,
    };
}

test "power-actions: mapping" {
    const t = std.testing;
    try t.expectEqualStrings("Suspend", logindOp(.sleep).?);
    try t.expect(logindOp(.ask) == null);
    try t.expectEqual(Op.shutdown, fromPowerButtonAction(3));
    try t.expectEqual(Op.ask, fromPowerButtonAction(99));
}
