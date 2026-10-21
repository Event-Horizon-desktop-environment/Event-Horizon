const std = @import("std");
const wire = @import("../dbus/wire.zig");

pub const DeviceType = enum(u32) {
    unknown = 0,
    ethernet = 1,
    wifi = 2,
    modem = 8,
    bluetooth = 5,
    _,
};

pub const DeviceState = enum(u32) {
    unknown = 0,
    unmanaged = 10,
    disconnected = 30,
    activated = 100,
    _,
};

pub const Device = struct {
    path: []const u8 = "",
    iface: []const u8 = "",
    dtype: DeviceType = .unknown,
    state: DeviceState = .unknown,
};

pub fn propString(props: []const wire.Value, key: []const u8) []const u8 {
    for (props) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        if (v.variant.val.* == .string) return v.variant.val.string;
    }
    return "";
}

pub fn propUint32(props: []const wire.Value, key: []const u8) u32 {
    for (props) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        if (v.variant.val.* == .uint32) return v.variant.val.uint32;
    }
    return 0;
}

pub fn isWifi(props: []const wire.Value) bool {
    return propUint32(props, "DeviceType") == 2;
}

pub const AccessPoint = struct {
    path: []const u8 = "",
    ssid: []const u8 = "",
    strength: u8 = 0,
    secured: bool = false,
};

pub fn ssidBytes(props: []const wire.Value) []const u8 {
    for (props) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, "Ssid")) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        if (v.variant.val.* == .array) return "";
        return "";
    }
    return "";
}

test "network: property helpers" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const mk = struct {
        fn u(a: std.mem.Allocator, k: []const u8, v: u32) !wire.Value {
            const p = try a.alloc(wire.Value, 2);
            p[0] = .{ .string = k };
            const b = try a.create(wire.Value);
            b.* = .{ .uint32 = v };
            p[1] = .{ .variant = .{ .sig = "u", .val = b } };
            return .{ .structure = p };
        }
        fn s(a: std.mem.Allocator, k: []const u8, v: []const u8) !wire.Value {
            const p = try a.alloc(wire.Value, 2);
            p[0] = .{ .string = k };
            const b = try a.create(wire.Value);
            b.* = .{ .string = v };
            p[1] = .{ .variant = .{ .sig = "s", .val = b } };
            return .{ .structure = p };
        }
    };
    const props = try aa.alloc(wire.Value, 2);
    props[0] = try mk.u(aa, "DeviceType", 2);
    props[1] = try mk.s(aa, "Interface", "wlan0");
    try t.expect(isWifi(props));
    try t.expectEqual(@as(u32, 2), propUint32(props, "DeviceType"));
    try t.expectEqualStrings("wlan0", propString(props, "Interface"));
    try t.expectEqualStrings("", propString(props, "Missing"));
}
