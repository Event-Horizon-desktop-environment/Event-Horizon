//! Live laptop battery behind the dock's battery widget: UPower on the system
//! bus. A poll thread feeds four fields the
//! Zig `battery_paint.State` reads off a global the host fills; this module
//! produces that reading, so the dock host owns the thread it does not have.
//!
//! It reads only the *laptop* battery: the first `Type == 2` (Battery),
//! `PowerSupply`, `IsPresent` device. A
//! Bluetooth headset's `Type 19` cell is a peripheral, never the laptop, so a
//! desktop with only a mouse/headset reports no battery — which is what the
//! widget then paints.

const std = @import("std");
const live = @import("live.zig");
const wire = @import("../../dbus/wire.zig");
const conn_mod = @import("../../dbus/connection.zig");

pub const upower_dest = "org.freedesktop.UPower";
pub const upower_root = "/org/freedesktop/UPower";
pub const upower_iface = "org.freedesktop.UPower";
pub const device_iface = "org.freedesktop.UPower.Device";

/// UPower `DeviceType`: only `Battery` (2) can be the laptop's own cell.
const k_type_battery: u32 = 2;

/// The reading the battery paint wants.
pub const Reading = struct {
    percentage: f64 = 0.0,
    /// 0..6 (`battery_paint.BatteryState.fromRaw`); 0 when unknown/absent.
    state: u32 = 0,
    is_present: bool = false,
    on_battery: bool = false,
};

/// Enumerate every UPower device and take the first laptop battery among them.
/// Any missing property or a bus that does not answer yields an absent reading
/// (`is_present = false`) rather than a guess — the widget paints "No battery
/// detected" then, which is the fallback when UPower is unreachable.
pub fn query(alloc: std.mem.Allocator) Reading {
    var conn = live.openBus(alloc, .system) orelse return .{};
    defer conn.deinit();

    const on_battery = rootOnBattery(&conn, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var p = conn.call(.{
        .mtype = .method_call,
        .path = upower_root,
        .interface = upower_iface,
        .member = "EnumerateDevices",
        .destination = upower_dest,
    }, 3000) catch return .{ .on_battery = on_battery };
    defer p.deinit();
    if (p.body_vals.len < 1 or p.body_vals[0] != .array) return .{ .on_battery = on_battery };

    for (p.body_vals[0].array.items) |pathv| {
        const path = live.asObjectPath(pathv);
        if (path.len == 0) continue;
        if (readDevice(&conn, aa, path)) |d| {
            // OnBattery reads off the root once and is reused; only a
            // present, supply-side battery overrides the absent fallback.
            return .{
                .percentage = d.percentage,
                .state = d.state,
                .is_present = true,
                .on_battery = on_battery,
            };
        }
    }
    return .{ .on_battery = on_battery };
}

const DeviceReading = struct {
    percentage: f64 = 0.0,
    state: u32 = 0,
};

/// One device's four properties: a battery type, a real
/// power supply, and present. A peripheral (headset, mouse) or a removed
/// battery returns null so the scan moves on.
fn readDevice(conn: *conn_mod.Conn, aa: std.mem.Allocator, path: []const u8) ?DeviceReading {
    const dev_type = live.asU32(propGet(conn, aa, path, "Type") orelse return null);
    if (dev_type != k_type_battery) return null;
    if (!live.asBool(propGet(conn, aa, path, "PowerSupply") orelse return null)) return null;
    if (!live.asBool(propGet(conn, aa, path, "IsPresent") orelse return null)) return null;
    const percentage = asDouble(propGet(conn, aa, path, "Percentage") orelse return null);
    const state = live.asU32(propGet(conn, aa, path, "State") orelse .{ .uint32 = 0 });
    return .{ .percentage = percentage, .state = state };
}

/// `Properties.Get` on a device, borrowing from `aa` (the reply is dropped).
fn propGet(conn: *conn_mod.Conn, aa: std.mem.Allocator, path: []const u8, prop: []const u8) ?wire.Value {
    return live.propGet(conn, aa, upower_dest, path, device_iface, prop) catch null;
}

/// Root `OnBattery`: true when the machine is running off its own cell. Absent
/// or a bus that does not answer both read as false.
fn rootOnBattery(conn: *conn_mod.Conn, alloc: std.mem.Allocator) bool {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = (live.propGet(conn, arena.allocator(), upower_dest, upower_root, upower_iface, "OnBattery") catch null) orelse return false;
    return live.asBool(v);
}

/// UPower sends `Percentage` as a `d`; fall back to the integer readers for a
/// peer that rounds it to an integer type.
fn asDouble(v: wire.Value) f64 {
    return switch (v) {
        .double => |x| x,
        .uint32 => |x| @floatFromInt(x),
        .int32 => |x| @floatFromInt(@max(0, x)),
        .byte => |x| @floatFromInt(x),
        else => 0.0,
    };
}

test "live-upower: an unreachable bus reads absent" {
    // `query` with no UPower on the bus must not crash and must read absent;
    // this exercises the early-return paths without asserting a live reading
    // (the dock runs it against a real bus).
    _ = query(std.testing.allocator);
}

test "live-upower: asDouble reads the types UPower actually sends" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 100.0), asDouble(.{ .double = 100.0 }));
    try t.expectEqual(@as(f64, 55.0), asDouble(.{ .uint32 = 55 }));
    try t.expectEqual(@as(f64, 0.0), asDouble(.{ .int32 = -3 }));
    try t.expectEqual(@as(f64, 0.0), asDouble(.{ .string = "nope" }));
}
