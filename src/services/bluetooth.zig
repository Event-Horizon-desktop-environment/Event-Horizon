const std = @import("std");
const wire = @import("../dbus/wire.zig");

pub const net = @import("network.zig");

pub const Device = struct {
    path: []const u8 = "",
    address: []const u8 = "",
    name: []const u8 = "",
    paired: bool = false,
    connected: bool = false,
    rssi: i16 = 0,
};

pub fn propBool(props: []const wire.Value, key: []const u8) bool {
    for (props) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        if (v.variant.val.* == .boolean) return v.variant.val.boolean;
    }
    return false;
}

pub fn propInt16(props: []const wire.Value, key: []const u8) i16 {
    for (props) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        if (v.variant.val.* == .int16) return v.variant.val.int16;
    }
    return 0;
}

pub fn parseDevice(props: []const wire.Value) Device {
    return .{
        .address = net.propString(props, "Address"),
        .name = net.propString(props, "Name"),
        .paired = propBool(props, "Paired"),
        .connected = propBool(props, "Connected"),
        .rssi = propInt16(props, "RSSI"),
    };
}

test "bluetooth: device parse" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const mk = struct {
        fn b(a: std.mem.Allocator, k: []const u8, v: bool) !wire.Value {
            const p = try a.alloc(wire.Value, 2);
            p[0] = .{ .string = k };
            const box = try a.create(wire.Value);
            box.* = .{ .boolean = v };
            p[1] = .{ .variant = .{ .sig = "b", .val = box } };
            return .{ .structure = p };
        }
        fn s(a: std.mem.Allocator, k: []const u8, v: []const u8) !wire.Value {
            const p = try a.alloc(wire.Value, 2);
            p[0] = .{ .string = k };
            const box = try a.create(wire.Value);
            box.* = .{ .string = v };
            p[1] = .{ .variant = .{ .sig = "s", .val = box } };
            return .{ .structure = p };
        }
    };
    const props = try aa.alloc(wire.Value, 3);
    props[0] = try mk.s(aa, "Address", "AA:BB:CC:DD:EE:FF");
    props[1] = try mk.s(aa, "Name", "Headset");
    props[2] = try mk.b(aa, "Paired", true);
    const d = parseDevice(props);
    try t.expectEqualStrings("AA:BB:CC:DD:EE:FF", d.address);
    try t.expect(d.paired);
    try t.expect(!d.connected);
}
