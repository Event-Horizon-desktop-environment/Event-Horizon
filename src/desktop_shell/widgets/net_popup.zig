const std = @import("std");

pub const Net = struct {
    ssid: []const u8,
    strength: u8,
    connected: bool = false,
};

pub const Bt = struct {
    name: []const u8,
    connected: bool = false,
};

pub fn topNets(nets: []Net, out: []*const Net, max: usize) usize {
    var n: usize = 0;
    for (nets) |*x| {
        if (n >= max or n >= out.len) break;
        out[n] = x;
        n += 1;
    }
    std.mem.sort(*const Net, out[0..n], {}, struct {
        fn lt(_: void, a: *const Net, b: *const Net) bool {
            return a.strength > b.strength;
        }
    }.lt);
    return n;
}

test "net-bt-popups: top sort" {
    const t = std.testing;
    var nets = [_]Net{
        .{ .ssid = "a", .strength = 20 },
        .{ .ssid = "b", .strength = 90 },
        .{ .ssid = "c", .strength = 50 },
    };
    var out: [2]*const Net = undefined;
    const n = topNets(&nets, &out, 2);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqualStrings("b", out[0].ssid);
}
