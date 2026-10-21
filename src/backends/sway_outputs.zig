const std = @import("std");

pub const Output = struct {
    name: []const u8 = "",
    make: []const u8 = "",
    model: []const u8 = "",
    active: bool = false,
    primary: bool = false,
    scale: f64 = 1.0,
    width: i32 = 0,
    height: i32 = 0,
};

pub fn primaryOf(outputs: []const Output) ?*const Output {
    for (outputs) |*o| {
        if (o.primary) return o;
    }
    for (outputs) |*o| {
        if (o.active) return o;
    }
    if (outputs.len > 0) return &outputs[0];
    return null;
}

test "sway-outputs: primary election" {
    const t = std.testing;
    const outs = [_]Output{
        .{ .name = "DP-1", .active = true },
        .{ .name = "HDMI-1", .active = true, .primary = true },
    };
    try t.expectEqualStrings("HDMI-1", primaryOf(&outs).?.name);
    const outs2 = [_]Output{.{ .name = "DP-1", .active = true }};
    try t.expectEqualStrings("DP-1", primaryOf(&outs2).?.name);
    try t.expect(primaryOf(&[_]Output{}) == null);
}
