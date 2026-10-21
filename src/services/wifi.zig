const std = @import("std");

pub const Ap = struct {
    ssid: []const u8,
    strength: u8,
    secured: bool,
};

pub fn sortByStrength(aps: []Ap) void {
    std.mem.sort(Ap, aps, {}, struct {
        fn lt(_: void, a: Ap, b: Ap) bool {
            if (a.strength != b.strength) return a.strength > b.strength;
            return std.mem.lessThan(u8, a.ssid, b.ssid);
        }
    }.lt);
}

pub fn securityOf(flags: u32, wpa_flags: u32, rsn_flags: u32) []const u8 {
    _ = flags;
    if (rsn_flags != 0) return "WPA2/WPA3";
    if (wpa_flags != 0) return "WPA1";
    return "open";
}

test "wifi: sort + security" {
    const t = std.testing;
    var aps = [_]Ap{
        .{ .ssid = "b", .strength = 40, .secured = true },
        .{ .ssid = "a", .strength = 80, .secured = false },
        .{ .ssid = "c", .strength = 80, .secured = true },
    };
    sortByStrength(&aps);
    try t.expectEqualStrings("a", aps[0].ssid);
    try t.expectEqualStrings("c", aps[1].ssid);
    try t.expectEqualStrings("WPA2/WPA3", securityOf(0, 0, 1));
    try t.expectEqualStrings("open", securityOf(0, 0, 0));
}
