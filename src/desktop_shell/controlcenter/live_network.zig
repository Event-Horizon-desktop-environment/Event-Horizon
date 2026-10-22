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

// NM_STATE_* (NetworkManager.h): 50 == CONNECTED_LOCAL,
// 70 == CONNECTED_GLOBAL.
pub const NM_CONNECTED_LOCAL: u32 = 50;
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

// ---------------------------------------------------------------------------
// Settings-page snapshot.
//
// The dock's `query` caps the AP list at 8 and skips everything the Network
// settings pages need (band + security per AP, saved profiles, the wired
// device's link/IP/DNS/driver detail). Rather than grow the dock's hot path,
// the settings page runs this richer, slower read on its own throttle.
// ---------------------------------------------------------------------------

pub const wired_iface = "org.freedesktop.NetworkManager.Device.Wired";
pub const ip4_iface = "org.freedesktop.NetworkManager.IP4Config";
pub const ip6_iface = "org.freedesktop.NetworkManager.IP6Config";

/// What the connection is riding on, mirroring the service's
/// `NetworkConnectivity`.
pub const Kind = enum { none, wifi, wired };

/// AP security flavour, derived exactly as the service derives it:
/// WpaFlags/RsnFlags both set → WPA/WPA2, RSN only → WPA2, WPA only → WPA,
/// privacy-only → Secure.
pub const Security = enum {
    open,
    wpa_wpa2,
    wpa2,
    wpa,
    secure,

    pub fn label(self: Security) []const u8 {
        return switch (self) {
            .open => "",
            .wpa_wpa2 => "WPA/WPA2",
            .wpa2 => "WPA2",
            .wpa => "WPA",
            .secure => "Secure",
        };
    }
};

pub const SettingsAp = struct {
    ssid: []const u8 = "",
    strength: u8 = 0,
    secured: bool = false,
    active: bool = false,
    frequency: u32 = 0,
    security: Security = .open,
};

/// One ethernet device's worth of detail, flattened into display strings the
/// Wired → Status page renders row by row (empty string = row omitted).
pub const WiredDetail = struct {
    present: bool = false,
    interface: []const u8 = "",
    carrier: bool = false,
    speed: u32 = 0,
    duplex: []const u8 = "",
    auto_negotiate: bool = false,
    hw_address: []const u8 = "",
    perm_hw_address: []const u8 = "",
    ipv4: []const u8 = "",
    ipv4_gateway: []const u8 = "",
    ipv6: []const u8 = "",
    ipv6_gateway: []const u8 = "",
    dns: [4][]const u8 = .{ "", "", "", "" },
    dns_len: usize = 0,
    domains: [4][]const u8 = .{ "", "", "", "" },
    domains_len: usize = 0,
    driver: []const u8 = "",
    driver_version: []const u8 = "",
    firmware_version: []const u8 = "",
    vendor: []const u8 = "",
    product: []const u8 = "",
    mtu: u32 = 0,
    device_state: u32 = 0,
};

pub const SettingsSnapshot = struct {
    alloc: std.mem.Allocator,
    have_nm: bool = false,
    wireless_enabled: bool = true,
    connected: bool = false,
    kind: Kind = .none,
    iface: []const u8 = "",
    ssid: []const u8 = "",
    signal_pct: i32 = -1,
    aps: std.ArrayList(SettingsAp) = .empty,
    wired: WiredDetail = .{},
    saved_ssids: std.ArrayList([]const u8) = .empty,

    /// `has_saved_connection` — a stored profile for this SSID means connect
    /// without prompting (the secrets are already in the keyring or profile).
    pub fn hasSaved(self: *const SettingsSnapshot, ssid: []const u8) bool {
        for (self.saved_ssids.items) |s| {
            if (std.mem.eql(u8, s, ssid)) return true;
        }
        return false;
    }

    pub fn deinit(self: *SettingsSnapshot) void {
        if (self.iface.len > 0) self.alloc.free(self.iface);
        if (self.ssid.len > 0) self.alloc.free(self.ssid);
        for (self.aps.items) |a| if (a.ssid.len > 0) self.alloc.free(a.ssid);
        self.aps.deinit(self.alloc);
        for (self.saved_ssids.items) |s| self.alloc.free(s);
        self.saved_ssids.deinit(self.alloc);
        const w = &self.wired;
        if (w.interface.len > 0) self.alloc.free(w.interface);
        if (w.duplex.len > 0) self.alloc.free(w.duplex);
        if (w.hw_address.len > 0) self.alloc.free(w.hw_address);
        if (w.perm_hw_address.len > 0) self.alloc.free(w.perm_hw_address);
        if (w.ipv4.len > 0) self.alloc.free(w.ipv4);
        if (w.ipv4_gateway.len > 0) self.alloc.free(w.ipv4_gateway);
        if (w.ipv6.len > 0) self.alloc.free(w.ipv6);
        if (w.ipv6_gateway.len > 0) self.alloc.free(w.ipv6_gateway);
        for (w.dns[0..w.dns_len]) |s| self.alloc.free(s);
        for (w.domains[0..w.domains_len]) |s| self.alloc.free(s);
        if (w.driver.len > 0) self.alloc.free(w.driver);
        if (w.driver_version.len > 0) self.alloc.free(w.driver_version);
        if (w.firmware_version.len > 0) self.alloc.free(w.firmware_version);
        if (w.vendor.len > 0) self.alloc.free(w.vendor);
        if (w.product.len > 0) self.alloc.free(w.product);
        self.* = undefined;
    }
};

fn freePaths(alloc: std.mem.Allocator, list: []wire.Value) void {
    for (list) |d| if (d == .object_path) alloc.free(d.object_path);
    alloc.free(list);
}

/// First `key` inside an `aa{sv}` property (NM's AddressData / NameserverData
/// shape: an array of dicts), owned by `alloc`; "" when absent.
fn dictArrayFirstString(
    conn: *conn_mod.Conn,
    alloc: std.mem.Allocator,
    path: []const u8,
    iface: []const u8,
    prop: []const u8,
    key: []const u8,
) []const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = live.propGet(conn, arena.allocator(), nm_dest, path, iface, prop) catch return "";
    const val = v orelse return "";
    if (val != .array) return "";
    for (val.array.items) |item| {
        if (item != .array) continue;
        const s = live.dictFind(item, key) orelse continue;
        const str = live.asString(s);
        if (str.len > 0) return alloc.dupe(u8, str) catch "";
    }
    return "";
}

/// Every `key` inside an `aa{sv}` property, capped at `out.len`, owned.
fn dictArrayStrings(
    conn: *conn_mod.Conn,
    alloc: std.mem.Allocator,
    path: []const u8,
    iface: []const u8,
    prop: []const u8,
    key: []const u8,
    out: *[4][]const u8,
    len: *usize,
) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = live.propGet(conn, arena.allocator(), nm_dest, path, iface, prop) catch return;
    const val = v orelse return;
    if (val != .array) return;
    for (val.array.items) |item| {
        if (len.* >= out.len) break;
        if (item != .array) continue;
        const s = live.dictFind(item, key) orelse continue;
        const str = live.asString(s);
        if (str.len == 0) continue;
        out[len.*] = alloc.dupe(u8, str) catch "";
        if (out[len.*].len > 0) len.* += 1;
    }
}

/// Every string of an `as` property (`Domains`), capped at `out.len`, owned.
fn strArrayInto(
    conn: *conn_mod.Conn,
    alloc: std.mem.Allocator,
    path: []const u8,
    iface: []const u8,
    prop: []const u8,
    out: *[4][]const u8,
    len: *usize,
) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const v = live.propGet(conn, arena.allocator(), nm_dest, path, iface, prop) catch return;
    const val = v orelse return;
    if (val != .array) return;
    for (val.array.items) |item| {
        if (len.* >= out.len) break;
        if (item != .string or item.string.len == 0) continue;
        out[len.*] = alloc.dupe(u8, item.string) catch "";
        if (out[len.*].len > 0) len.* += 1;
    }
}

/// `settings_conn_type` — find `key` in an `a{sa{sv}}` Settings document.
fn outerFind(arr: wire.Value, key: []const u8) ?wire.Value {
    if (arr != .array) return null;
    for (arr.array.items) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        return entry.structure[1];
    }
    return null;
}

/// SSIDs of every stored `802-11-wireless` profile (`savedConns` in the
/// service). Best-effort: any shape surprise just leaves the list short.
fn savedSsids(conn: *conn_mod.Conn, alloc: std.mem.Allocator, q: *SettingsSnapshot) void {
    const settings_path = "/org/freedesktop/NetworkManager/Settings";
    const settings_iface = "org.freedesktop.NetworkManager.Settings";
    const conn_iface = "org.freedesktop.NetworkManager.Settings.Connection";

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const v = live.propGet(conn, aa, nm_dest, settings_path, settings_iface, "Connections") catch return;
    const val = v orelse return;
    if (val != .array) return;
    for (val.array.items) |item| {
        if (item != .object_path) continue;
        const cpath = item.object_path;
        var arena2 = std.heap.ArenaAllocator.init(alloc);
        defer arena2.deinit();
        const sv = live.propGet(conn, arena2.allocator(), nm_dest, cpath, conn_iface, "Settings") catch continue;
        const settings = sv orelse continue;
        const wireless = outerFind(settings, "802-11-wireless") orelse continue;
        const ssid_v = live.dictFind(wireless, "ssid") orelse continue;
        var buf: [128]u8 = undefined;
        const ssid = live.bytesInto(ssid_v, &buf);
        if (ssid.len == 0) continue;
        const owned = alloc.dupe(u8, ssid) catch continue;
        q.saved_ssids.append(alloc, owned) catch {
            alloc.free(owned);
        };
    }
}

fn apSecurity(flags: u32, wpa: u32, rsn: u32) Security {
    if (wpa != 0 and rsn != 0) return .wpa_wpa2;
    if (rsn != 0) return .wpa2;
    if (wpa != 0) return .wpa;
    if ((flags & 0x1) != 0) return .secure;
    return .open;
}

/// The Network settings page's full read: radio state, connected Wi-Fi (with
/// its AP), the uncapped AP list (band + security), every saved Wi-Fi SSID,
/// and the first wired device's detail block. Null when the system bus is
/// unreachable; the caller keeps its previous snapshot.
pub fn settingsQuery(alloc: std.mem.Allocator) ?SettingsSnapshot {
    var conn = live.openBus(alloc, .system) orelse return null;
    defer conn.deinit();
    var q = SettingsSnapshot{ .alloc = alloc, .have_nm = true };
    errdefer q.deinit();

    const state = getU32(&conn, alloc, nm_path, nm_iface, "State");
    q.wireless_enabled = getBool(&conn, alloc, nm_path, nm_iface, "WirelessEnabled");
    // The reference treats every post-connect state (connected-local / site /
    // global = 50/60/70) as connected, not just CONNECTED_GLOBAL.
    q.connected = state >= NM_CONNECTED_LOCAL;

    savedSsids(&conn, alloc, &q);

    const devs = getPaths(&conn, alloc, nm_path, nm_iface, "GetDevices") orelse return q;
    defer freePaths(alloc, devs);

    var have_wifi_device = false;
    var wifi_active = false;
    var wired_active = false;
    for (devs) |d| {
        if (d != .object_path) continue;
        const path = d.object_path;
        const dtype = getU32(&conn, alloc, path, dev_iface, "DeviceType");
        const dstate = getU32(&conn, alloc, path, dev_iface, "State");
        if (dtype == NM_DEVICE_TYPE_WIFI) {
            const iface = getString(&conn, alloc, path, dev_iface, "Interface");
            const ap_path = getPath(&conn, alloc, path, wifi_iface, "ActiveAccessPoint");
            defer if (ap_path.len > 0) alloc.free(ap_path);
            if (dstate == NM_DEVICE_STATE_ACTIVATED) {
                wifi_active = true;
                if (q.iface.len == 0) {
                    q.iface = iface;
                } else alloc.free(iface);
                if (ap_path.len > 1) {
                    var ssid_buf: [128]u8 = undefined;
                    const ssid = apSsid(&conn, alloc, ap_path, &ssid_buf);
                    if (ssid.len > 0) {
                        if (q.ssid.len > 0) alloc.free(q.ssid);
                        q.ssid = alloc.dupe(u8, ssid) catch "";
                    }
                    const str = getU32(&conn, alloc, ap_path, ap_iface, "Strength");
                    q.signal_pct = @intCast(@min(str, 100));
                }
            } else alloc.free(iface);

            // AP list from the first wifi device (NM exposes one AP set per
            // device; the settings page wants them all, uncapped).
            if (!have_wifi_device) {
                have_wifi_device = true;
                const aps = getPaths(&conn, alloc, path, wifi_iface, "GetAccessPoints");
                if (aps) |list| {
                    defer freePaths(alloc, list);
                    for (list) |a| {
                        if (a != .object_path) continue;
                        var ssid_buf: [128]u8 = undefined;
                        const ssid = apSsid(&conn, alloc, a.object_path, &ssid_buf);
                        if (ssid.len == 0) continue;
                        const strength = getU32(&conn, alloc, a.object_path, ap_iface, "Strength");
                        const flags = getU32(&conn, alloc, a.object_path, ap_iface, "Flags");
                        const wpa = getU32(&conn, alloc, a.object_path, ap_iface, "WpaFlags");
                        const rsn = getU32(&conn, alloc, a.object_path, ap_iface, "RsnFlags");
                        const freq = getU32(&conn, alloc, a.object_path, ap_iface, "Frequency");
                        const sec = apSecurity(flags, wpa, rsn);
                        const owned_ssid = alloc.dupe(u8, ssid) catch continue;
                        q.aps.append(alloc, .{
                            .ssid = owned_ssid,
                            .strength = @intCast(@min(strength, 100)),
                            .secured = sec != .open,
                            .active = std.mem.eql(u8, a.object_path, ap_path),
                            .frequency = freq,
                            .security = sec,
                        }) catch {
                            alloc.free(owned_ssid);
                        };
                    }
                }
            }
        } else if (dtype == NM_DEVICE_TYPE_ETHERNET) {
            const iface = getString(&conn, alloc, path, dev_iface, "Interface");
            if (dstate == NM_DEVICE_STATE_ACTIVATED) wired_active = true;
            if (!q.wired.present) {
                const w = &q.wired;
                w.present = true;
                w.interface = iface;
                w.carrier = getBool(&conn, alloc, path, wired_iface, "Carrier");
                w.speed = getU32(&conn, alloc, path, wired_iface, "Speed");
                w.duplex = getString(&conn, alloc, path, wired_iface, "Duplex");
                w.auto_negotiate = getBool(&conn, alloc, path, wired_iface, "AutoNegotiate");
                w.hw_address = getString(&conn, alloc, path, dev_iface, "HwAddress");
                w.perm_hw_address = getString(&conn, alloc, path, wired_iface, "PermHwAddress");
                w.driver = getString(&conn, alloc, path, dev_iface, "Driver");
                w.driver_version = getString(&conn, alloc, path, dev_iface, "DriverVersion");
                w.firmware_version = getString(&conn, alloc, path, dev_iface, "FirmwareVersion");
                w.vendor = getString(&conn, alloc, path, dev_iface, "Vendor");
                w.product = getString(&conn, alloc, path, dev_iface, "Product");
                w.mtu = getU32(&conn, alloc, path, dev_iface, "Mtu");
                w.device_state = getU32(&conn, alloc, path, dev_iface, "State");
                const ip4_path = getPath(&conn, alloc, path, dev_iface, "Ip4Config");
                defer if (ip4_path.len > 0) alloc.free(ip4_path);
                if (ip4_path.len > 1) {
                    w.ipv4 = dictArrayFirstString(&conn, alloc, ip4_path, ip4_iface, "AddressData", "address");
                    w.ipv4_gateway = getString(&conn, alloc, ip4_path, ip4_iface, "Gateway");
                    dictArrayStrings(&conn, alloc, ip4_path, ip4_iface, "NameserverData", "address", &w.dns, &w.dns_len);
                    strArrayInto(&conn, alloc, ip4_path, ip4_iface, "Domains", &w.domains, &w.domains_len);
                }
                const ip6_path = getPath(&conn, alloc, path, dev_iface, "Ip6Config");
                defer if (ip6_path.len > 0) alloc.free(ip6_path);
                if (ip6_path.len > 1) {
                    w.ipv6 = dictArrayFirstString(&conn, alloc, ip6_path, ip6_iface, "AddressData", "address");
                    w.ipv6_gateway = getString(&conn, alloc, ip6_path, ip6_iface, "Gateway");
                }
            } else alloc.free(iface);
        }
    }
    // The reference prefers a wireless link when both radios are up: its
    // primary connection usually says wired, then the Wi-Fi fallback
    // upgrades the kind so the Wi-Fi card reads connected.
    q.kind = if (wifi_active) .wifi else if (wired_active) .wired else .none;

    foldAps(alloc, &q.aps, q.ssid);

    if (!q.connected) q.kind = .none;
    return q;
}

/// One row per SSID, like the reference service: keep the active or
/// strongest BSSID, mark the connected SSID, then order active first and
/// strongest first. Takes ownership of every entry's SSID (frees the ones
/// it drops).
fn foldAps(alloc: std.mem.Allocator, aps: *std.ArrayList(SettingsAp), active_ssid: []const u8) void {
    var di: usize = 0;
    while (di < aps.items.len) : (di += 1) {
        const a = aps.items[di];
        var j: usize = 0;
        while (j < di) : (j += 1) {
            if (!std.mem.eql(u8, aps.items[j].ssid, a.ssid)) continue;
            if (a.strength > aps.items[j].strength or a.active) {
                alloc.free(aps.items[j].ssid);
                aps.items[j] = a;
            } else {
                alloc.free(a.ssid);
            }
            _ = aps.swapRemove(di);
            di -= 1;
            break;
        }
    }
    if (active_ssid.len > 0) {
        for (aps.items) |*a| {
            if (std.mem.eql(u8, a.ssid, active_ssid)) a.active = true;
        }
    }
    std.mem.sort(SettingsAp, aps.items, {}, struct {
        fn lessThan(_: void, a: SettingsAp, b: SettingsAp) bool {
            if (a.active != b.active) return a.active;
            return a.strength > b.strength;
        }
    }.lessThan);
}

/// `nmcli device disconnect <iface>` in a detached thread — deactivates the
/// active connection on that device (the service's `DeactivateConnection`).
pub fn disconnectThread(io: std.Io, iface: []const u8) void {
    if (iface.len == 0) return;
    const Args = struct {
        io: std.Io,
        iface: []u8,
        fn run(self: *@This()) void {
            const pa = std.heap.page_allocator;
            defer pa.free(self.iface);
            defer pa.destroy(self);
            _ = runNmcli(self.io, &.{ "nmcli", "device", "disconnect", self.iface });
        }
        fn runNmcli(io_: std.Io, argv: []const []const u8) bool {
            const res = std.process.run(std.heap.page_allocator, io_, .{ .argv = argv }) catch return false;
            defer std.heap.page_allocator.free(res.stdout);
            defer std.heap.page_allocator.free(res.stderr);
            return res.term == .exited and res.term.exited == 0;
        }
    };
    const pa = std.heap.page_allocator;
    const args = pa.create(Args) catch return;
    args.* = .{
        .io = io,
        .iface = pa.dupe(u8, iface) catch {
            pa.destroy(args);
            return;
        },
    };
    const t = std.Thread.spawn(.{}, Args.run, .{args}) catch {
        pa.free(args.iface);
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

test "live-network: AP fold keeps one row per SSID, active first" {
    const t = std.testing;
    const a = t.allocator;
    const add = struct {
        fn f(alloc: std.mem.Allocator, list: *std.ArrayList(SettingsAp), ssid: []const u8, strength: u8, active: bool) !void {
            try list.append(alloc, .{
                .ssid = try alloc.dupe(u8, ssid),
                .strength = strength,
                .active = active,
            });
        }
    }.f;

    var aps: std.ArrayList(SettingsAp) = .empty;
    defer aps.deinit(a);
    try add(a, &aps, "strong", 80, false);
    try add(a, &aps, "other", 40, false);
    try add(a, &aps, "strong", 60, false); // weaker duplicate of the same BSSID set
    try add(a, &aps, "active", 30, false);
    try add(a, &aps, "active", 20, true); // the active BSSID wins regardless of strength

    foldAps(a, &aps, "active");
    defer for (aps.items) |ap| a.free(ap.ssid);

    try t.expectEqual(@as(usize, 3), aps.items.len);
    try t.expectEqualStrings("active", aps.items[0].ssid);
    try t.expect(aps.items[0].active);
    try t.expectEqualStrings("strong", aps.items[1].ssid);
    try t.expectEqual(@as(u8, 80), aps.items[1].strength);
    try t.expectEqualStrings("other", aps.items[2].ssid);
}
