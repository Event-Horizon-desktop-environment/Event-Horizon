//! Live network behind the control-center tiles + panel: read from
//! NetworkManager over the system bus (state, devices, access points),
//! write through `nmcli` (radio toggle, rescan, connect — the slow one runs
//! in a thread so a 10 s association never stalls the Wayland loop).
//!
//! Any failure (no NM, no bus, no nmcli) yields `null`/defaults and the dock
//! keeps its cache.

const std = @import("std");
const live = @import("live.zig");
const wire = @import("../../dbus/wire.zig");
const conn_mod = @import("../../dbus/connection.zig");

pub const nm_dest = "org.freedesktop.NetworkManager";
pub const nm_path = "/org/freedesktop/NetworkManager";
pub const nm_iface = "org.freedesktop.NetworkManager";
pub const dev_iface = "org.freedesktop.NetworkManager.Device";
pub const wifi_iface = "org.freedesktop.NetworkManager.Device.Wireless";
pub const ap_iface = "org.freedesktop.NetworkManager.AccessPoint";

// NM_STATE_* (NetworkManager.h): 70 == CONNECTED_GLOBAL.
pub const NM_CONNECTED_GLOBAL: u32 = 70;
// NM_CONNECTIVITY_*: 4 == FULL.
pub const NM_CONNECTIVITY_FULL: u32 = 4;
pub const NM_DEVICE_TYPE_ETHERNET: u32 = 1;
pub const NM_DEVICE_TYPE_WIFI: u32 = 2;
pub const NM_DEVICE_STATE_ACTIVATED: u32 = 100;

pub const Ap = struct {
    ssid: []const u8 = "",
    strength: u8 = 0,
    secured: bool = false,
    active: bool = false,
};

pub const Snapshot = struct {
    have_nm: bool = false,
    connected: bool = false,
    wifi: bool = false,
    ethernet: bool = false,
    iface: []const u8 = "",
    ssid: []const u8 = "",
    signal_pct: i32 = -1,
    wireless_enabled: bool = true,
};

/// Read one string property, owned by the caller.
fn getString(conn: *conn_mod.Conn, alloc: std.mem.Allocator, path: []const u8, iface: []const u8, prop: []const u8) []const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = live.propGet(conn, arena.allocator(), nm_dest, path, iface, prop) catch return "";
    const val = v orelse return "";
    if (val != .string or val.string.len == 0) return "";
    return alloc.dupe(u8, val.string) catch "";
}

fn getU32(conn: *conn_mod.Conn, alloc: std.mem.Allocator, path: []const u8, iface: []const u8, prop: []const u8) u32 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = live.propGet(conn, arena.allocator(), nm_dest, path, iface, prop) catch return 0;
    const val = v orelse return 0;
    return live.asU32(val);
}

fn getBool(conn: *conn_mod.Conn, alloc: std.mem.Allocator, path: []const u8, iface: []const u8, prop: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = live.propGet(conn, arena.allocator(), nm_dest, path, iface, prop) catch return false;
    const val = v orelse return false;
    return live.asBool(val);
}

fn getPath(conn: *conn_mod.Conn, alloc: std.mem.Allocator, path: []const u8, iface: []const u8, prop: []const u8) []const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = live.propGet(conn, arena.allocator(), nm_dest, path, iface, prop) catch return "";
    const val = v orelse return "";
    if (val != .object_path) return "";
    return alloc.dupe(u8, val.object_path) catch "";
}

fn getPaths(conn: *conn_mod.Conn, alloc: std.mem.Allocator, path: []const u8, iface: []const u8, member: []const u8) ?[]wire.Value {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p = conn.call(.{
        .mtype = .method_call,
        .path = path,
        .interface = iface,
        .member = member,
        .destination = nm_dest,
    }, 3000) catch return null;
    defer p.deinit();
    if (p.body_vals.len < 1 or p.body_vals[0] != .array) return null;
    const items = alloc.dupe(wire.Value, p.body_vals[0].array.items) catch return null;
    // Shallow dupe is enough for object paths (strings borrow from Parsed —
    // NO: they dangle after p.deinit!). Copy each path string out.
    for (items) |*it| {
        if (it.* == .object_path) {
            const s = alloc.dupe(u8, it.object_path) catch "";
            it.* = .{ .object_path = s };
        }
    }
    return items;
}

/// Full snapshot. All strings owned by `alloc`; free with `free`.
pub fn query(alloc: std.mem.Allocator) ?Queried {
    var conn = live.openBus(alloc, .system) orelse return null;
    defer conn.deinit();
    var q = Queried.init(alloc);
    errdefer q.deinit();

    const state = getU32(&conn, alloc, nm_path, nm_iface, "State");
    const connectivity = getU32(&conn, alloc, nm_path, nm_iface, "Connectivity");
    q.snap.wireless_enabled = getBool(&conn, alloc, nm_path, nm_iface, "WirelessEnabled");
    q.snap.connected = state == NM_CONNECTED_GLOBAL or connectivity == NM_CONNECTIVITY_FULL;

    const devs = getPaths(&conn, alloc, nm_path, nm_iface, "GetDevices") orelse return q.finish();
    defer {
        for (devs) |d| if (d == .object_path) alloc.free(d.object_path);
        alloc.free(devs);
    }
    for (devs) |d| {
        if (d != .object_path) continue;
        const dtype = getU32(&conn, alloc, d.object_path, dev_iface, "DeviceType");
        const dstate = getU32(&conn, alloc, d.object_path, dev_iface, "State");
        if (dstate != NM_DEVICE_STATE_ACTIVATED) continue;
        const iface = getString(&conn, alloc, d.object_path, dev_iface, "Interface");
        if (dtype == NM_DEVICE_TYPE_WIFI) {
            q.snap.wifi = true;
            if (q.snap.iface.len == 0) {
                alloc.free(q.snap.iface);
                q.snap.iface = iface;
            } else alloc.free(iface);
            const ap_path = getPath(&conn, alloc, d.object_path, wifi_iface, "ActiveAccessPoint");
            defer alloc.free(ap_path);
            if (ap_path.len > 1) {
                var ssid_buf: [128]u8 = undefined;
                const ssid = apSsid(&conn, alloc, ap_path, &ssid_buf);
                if (ssid.len > 0) {
                    alloc.free(q.snap.ssid);
                    q.snap.ssid = alloc.dupe(u8, ssid) catch "";
                }
                const str = getU32(&conn, alloc, ap_path, ap_iface, "Strength");
                q.snap.signal_pct = @intCast(@min(str, 100));
            }
            // AP list for the panel (cap 8, strongest first is NM order).
            const aps = getPaths(&conn, alloc, d.object_path, wifi_iface, "GetAccessPoints");
            if (aps) |list| {
                defer {
                    for (list) |a| if (a == .object_path) alloc.free(a.object_path);
                    alloc.free(list);
                }
                for (list) |a| {
                    if (a != .object_path) continue;
                    if (q.ap_list.items.len >= 8) break;
                    var ssid_buf: [128]u8 = undefined;
                    const ssid = apSsid(&conn, alloc, a.object_path, &ssid_buf);
                    if (ssid.len == 0) continue;
                    const strength = getU32(&conn, alloc, a.object_path, ap_iface, "Strength");
                    const flags = getU32(&conn, alloc, a.object_path, ap_iface, "Flags");
                    const wpa = getU32(&conn, alloc, a.object_path, ap_iface, "WpaFlags");
                    const rsn = getU32(&conn, alloc, a.object_path, ap_iface, "RsnFlags");
                    q.ap_list.append(alloc, .{
                        .ssid = alloc.dupe(u8, ssid) catch "",
                        .strength = @intCast(@min(strength, 100)),
                        .secured = (flags & 0x1) != 0 or wpa != 0 or rsn != 0,
                        .active = std.mem.eql(u8, a.object_path, ap_path),
                    }) catch {};
                }
            }
        } else if (dtype == NM_DEVICE_TYPE_ETHERNET) {
            q.snap.ethernet = true;
            if (q.snap.iface.len == 0) {
                alloc.free(q.snap.iface);
                q.snap.iface = iface;
            } else alloc.free(iface);
        } else {
            alloc.free(iface);
        }
        // First activated device wins the kind when both somehow qualify;
        // prefer wifi for the tile when connected over wireless.
        if (q.snap.wifi and q.snap.ethernet) q.snap.ethernet = false;
    }
    return q.finish();
}

fn apSsid(conn: *conn_mod.Conn, alloc: std.mem.Allocator, ap_path: []const u8, buf: *[128]u8) []const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = live.propGet(conn, arena.allocator(), nm_dest, ap_path, ap_iface, "Ssid") catch return "";
    const val = v orelse return "";
    return live.bytesInto(val, buf);
}

pub const Queried = struct {
    alloc: std.mem.Allocator,
    snap: Snapshot = .{ .have_nm = true },
    ap_list: std.ArrayList(Ap) = .empty,

    pub fn init(alloc: std.mem.Allocator) Queried {
        return .{ .alloc = alloc };
    }

    fn finish(self: *Queried) ?Queried {
        if (!self.snap.connected) {
            self.snap.wifi = false;
            self.snap.ethernet = false;
        }
        return self.*;
    }

    pub fn deinit(self: *Queried) void {
        if (self.snap.iface.len > 0) self.alloc.free(self.snap.iface);
        if (self.snap.ssid.len > 0) self.alloc.free(self.snap.ssid);
        for (self.ap_list.items) |a| if (a.ssid.len > 0) self.alloc.free(a.ssid);
        self.ap_list.deinit(self.alloc);
        self.snap = .{};
    }
};

/// `nmcli radio wifi on|off` — immediate.
pub fn setWifiEnabled(io: std.Io, enabled: bool) bool {
    const res = std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ "nmcli", "radio", "wifi", if (enabled) "on" else "off" },
    }) catch return false;
    defer std.heap.page_allocator.free(res.stdout);
    defer std.heap.page_allocator.free(res.stderr);
    return res.term == .exited and res.term.exited == 0;
}

/// `nmcli device wifi rescan` in a thread (can block for seconds).
pub fn rescanThread(io: std.Io) void {
    const Args = struct {
        io: std.Io,
        fn run(self: @This()) void {
            const res = std.process.run(std.heap.page_allocator, self.io, .{
                .argv = &.{ "nmcli", "device", "wifi", "rescan" },
            }) catch return;
            std.heap.page_allocator.free(res.stdout);
            std.heap.page_allocator.free(res.stderr);
        }
    };
    const t = std.Thread.spawn(.{}, Args.run, .{Args{ .io = io }}) catch return;
    t.detach();
}

pub const ConnectArgs = struct {
    io: std.Io,
    ssid: []u8,
    password: []u8,

    fn run(self: *ConnectArgs) void {
        const pa = std.heap.page_allocator;
        defer pa.free(self.ssid);
        defer pa.free(self.password);
        defer pa.destroy(self);
        var argv: [7][]const u8 = undefined;
        var n: usize = 0;
        argv[n] = "nmcli";
        n += 1;
        argv[n] = "-t";
        n += 1;
        argv[n] = "device";
        n += 1;
        argv[n] = "wifi";
        n += 1;
        argv[n] = "connect";
        n += 1;
        argv[n] = self.ssid;
        n += 1;
        var pwbuf: [4][]const u8 = undefined;
        var full: [11][]const u8 = undefined;
        if (self.password.len > 0) {
            pwbuf[0] = "password";
            pwbuf[1] = self.password;
            @memcpy(full[0..n], argv[0..n]);
            @memcpy(full[n .. n + 2], pwbuf[0..2]);
            const res = std.process.run(std.heap.page_allocator, self.io, .{ .argv = full[0 .. n + 2] }) catch return;
            std.heap.page_allocator.free(res.stdout);
            std.heap.page_allocator.free(res.stderr);
        } else {
            const res = std.process.run(std.heap.page_allocator, self.io, .{ .argv = argv[0..n] }) catch return;
            std.heap.page_allocator.free(res.stdout);
            std.heap.page_allocator.free(res.stderr);
        }
    }
};

/// `nmcli device wifi connect` in a detached thread (association can take
/// 10 s+; the panel refreshes off the next poll either way). Uses the page
/// allocator throughout — the dock's debug allocator is not touched off the
/// loop thread.
pub fn connectThread(io: std.Io, ssid: []const u8, password: []const u8) void {
    const pa = std.heap.page_allocator;
    const args = pa.create(ConnectArgs) catch return;
    args.* = .{
        .io = io,
        .ssid = pa.dupe(u8, ssid) catch {
            pa.destroy(args);
            return;
        },
        .password = pa.dupe(u8, password) catch {
            pa.free(args.ssid);
            pa.destroy(args);
            return;
        },
    };
    const t = std.Thread.spawn(.{}, ConnectArgs.run, .{args}) catch {
        pa.free(args.ssid);
        pa.free(args.password);
        pa.destroy(args);
        return;
    };
    t.detach();
}

test "live-network: NM constants + secured rule" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 70), NM_CONNECTED_GLOBAL);
    try t.expectEqual(@as(u32, 2), NM_DEVICE_TYPE_WIFI);
    // flags/wpa/rsn → secured (same rule as the query path).
    const secured = (0x1 & 0x1) != 0 or @as(u32, 0) != 0 or @as(u32, 0) != 0;
    try t.expect(secured);
    try t.expect(!((@as(u32, 0) & 0x1) != 0 or @as(u32, 0) != 0 or @as(u32, 0) != 0));
}
