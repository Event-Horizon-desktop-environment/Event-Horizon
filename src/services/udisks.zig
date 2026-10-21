const std = @import("std");
const net = @import("network.zig");
const connection = @import("../dbus/connection.zig");
const wire = @import("../dbus/wire.zig");

pub const Drive = struct {
    path: []const u8 = "",
    model: []const u8 = "",
    vendor: []const u8 = "",
    removable: bool = false,
    optical: bool = false,
    size_bytes: u64 = 0,
};

pub const Block = struct {
    path: []const u8 = "",
    device: []const u8 = "",
    label: []const u8 = "",
    fs_type: []const u8 = "",
    mount_points: u32 = 0,
    size_bytes: u64 = 0,
    crypto_backing: bool = false,
};

pub fn parseDrive(props: []const @import("../dbus/wire.zig").Value) Drive {
    return .{
        .model = net.propString(props, "Model"),
        .vendor = net.propString(props, "Vendor"),
        .size_bytes = propU64(props, "Size"),
    };
}

fn propU64(props: []const @import("../dbus/wire.zig").Value, key: []const u8) u64 {
    for (props) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        if (v.variant.val.* == .uint64) return v.variant.val.uint64;
    }
    return 0;
}

pub fn parseBlock(props: []const @import("../dbus/wire.zig").Value) Block {
    var b = Block{
        .device = net.propString(props, "Device"),
        .label = net.propString(props, "IdLabel"),
        .fs_type = net.propString(props, "IdType"),
        .size_bytes = propU64(props, "Size"),
    };
    for (props) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (std.mem.eql(u8, entry.structure[0].string, "MountPoints")) {
            const v = entry.structure[1];
            if (v == .variant and v.variant.val.* == .array) {
                b.mount_points = @intCast(v.variant.val.array.items.len);
            }
        }
        if (std.mem.eql(u8, entry.structure[0].string, "CryptoBackingDevice")) {
            b.crypto_backing = true;
        }
    }
    return b;
}

/// One filesystem-bearing block device, as the desktop models a drive.
/// `mount_point` is empty when the volume is not mounted; `object_path` is the
/// UDisks2 D-Bus path used to mount/unmount it.
pub const DriveEntry = struct {
    device: []const u8 = "",
    label: []const u8 = "",
    mount_point: []const u8 = "",
    mounted: bool = false,
    object_path: []const u8 = "",
    uuid: []const u8 = "",
    fstype: []const u8 = "",
    /// Block `Configuration` lists an `fstab` item (`has_fstab_entry`): the
    /// Mount row mounts directly instead of showing the mount dialog.
    has_fstab: bool = false,
};

pub const block_iface = "org.freedesktop.UDisks2.Block";
pub const fs_iface = "org.freedesktop.UDisks2.Filesystem";

/// Synchronous UDisks2 enumerator over the system bus. Mirrors the C++
/// `UDisks2DriveService::query_drives` shape: one `GetManagedObjects` call
/// filtered to Block+Filesystem objects, skipping `HintIgnore` entries.
///
/// The desktop rescans on a 1s tick, so results are cached behind a TTL —
/// a steady-state tick costs nothing and only a real change re-queries.
pub const Client = struct {
    alloc: std.mem.Allocator,
    conn: connection.Conn = undefined,
    connected: bool = false,
    /// Owned copy of the last enumeration; valid until the next `refresh`.
    entries: []DriveEntry = &.{},
    /// Arena backing `entries` (dupe'd device/label/mount strings).
    arena: ?std.heap.ArenaAllocator = null,
    last_query_ms: i64 = -1,

    pub fn init(alloc: std.mem.Allocator) Client {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Client) void {
        self.clearEntries();
        if (self.connected) self.conn.deinit();
        self.connected = false;
    }

    fn clearEntries(self: *Client) void {
        if (self.arena) |*ar| ar.deinit();
        self.arena = null;
        self.entries = &.{};
    }

    fn ensure(self: *Client) bool {
        if (self.connected) return true;
        const addr = connection.addressFor(.system, null, null) orelse return false;
        self.conn = connection.Conn.init(self.alloc);
        self.conn.connect(addr) catch return false;
        self.conn.hello() catch {
            self.conn.deinit();
            return false;
        };
        self.connected = true;
        return true;
    }

    /// (Re)enumerate drives. `now_ms` drives the cache TTL; pass a fresh
    /// monotonic reading each tick. Returns the cached slice, which stays
    /// valid until the next refresh that actually re-queries.
    pub fn drives(self: *Client, now_ms: i64, ttl_ms: i64) []const DriveEntry {
        if (self.last_query_ms >= 0 and now_ms - self.last_query_ms < ttl_ms) return self.entries;
        self.refresh() catch {};
        self.last_query_ms = now_ms;
        return self.entries;
    }

    /// Force a re-query on the next `drives` call (used after mount/unmount).
    pub fn invalidate(self: *Client) void {
        self.last_query_ms = -1;
    }

    /// Fire-and-forget `Block.AddConfigurationItem` carrying an `fstab` tuple —
    /// the port of C++ `add_fstab_async` (`udisks2_drive_service.cpp:297-325`):
    /// `(("fstab", {fsname, dir, type, opts, freq, passno}), {})` with every
    /// string as an `ay` (`string_to_bytes`). Sent `no_reply_expected` so the
    /// desktop never stalls behind the polkit prompt UDisks2 may raise; the C++
    /// callback only resolves a promise, so nothing consumes the reply there
    /// either. Body values live in a scratch arena that `sendMessage` copies
    /// out through `wire.marshal`. `opts` is the fstab mount-option field
    /// (`"defaults"`, or `"defaults,ro"` for a read-only mount).
    pub fn addFstab(self: *Client, object_path: []const u8, mount_point: []const u8, fstype: []const u8, uuid: []const u8, opts: []const u8) void {
        if (object_path.len == 0 or mount_point.len == 0) return;
        if (!self.ensure()) return;
        var tmp = std.heap.ArenaAllocator.init(self.alloc);
        defer tmp.deinit();
        const body = buildFstabBody(tmp.allocator(), mount_point, fstype, uuid, opts) catch return;
        _ = self.conn.sendMessage(.{
            .mtype = .method_call,
            .flags = wire.Flags.no_reply_expected,
            .path = object_path,
            .interface = block_iface,
            .member = "AddConfigurationItem",
            .destination = "org.freedesktop.UDisks2",
            .signature = "(sa{sv})a{sv}",
            .body = &body,
        }) catch {};
    }

    fn refresh(self: *Client) !void {
        if (!self.ensure()) return;
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/UDisks2",
            .interface = "org.freedesktop.DBus.ObjectManager",
            .member = "GetManagedObjects",
            .destination = "org.freedesktop.UDisks2",
        }, 4000) catch return;
        defer p.deinit();
        if (p.body_vals.len < 1 or p.body_vals[0] != .array) return;

        // Build into a fresh arena so the old slice is released wholesale and
        // every string outlives the reply (which `p.deinit` frees).
        var ar = std.heap.ArenaAllocator.init(self.alloc);
        errdefer ar.deinit();
        const aa = ar.allocator();
        var list: std.ArrayList(DriveEntry) = .empty;

        for (p.body_vals[0].array.items) |entry| {
            if (entry != .structure or entry.structure.len < 2) continue;
            const opath = entry.structure[0];
            if (opath != .object_path) continue;
            const ifaces = entry.structure[1];
            if (ifaces != .array) continue;

            var block_props: ?[]const wire.Value = null;
            var fs_props: ?[]const wire.Value = null;
            for (ifaces.array.items) |ie| {
                if (ie != .structure or ie.structure.len < 2) continue;
                const nm = ie.structure[0];
                if (nm != .string) continue;
                const props = ie.structure[1];
                if (props != .array) continue;
                if (std.mem.eql(u8, nm.string, block_iface)) block_props = props.array.items;
                if (std.mem.eql(u8, nm.string, fs_iface)) fs_props = props.array.items;
            }
            // Only filesystem-bearing blocks are desktop drives.
            const bp = block_props orelse continue;
            const fp = fs_props orelse continue;
            if (propBool(bp, "HintIgnore")) continue;

            const dev = propBytes(aa, bp, "Device") orelse continue;
            if (dev.len == 0) continue;

            var label = net.propString(bp, "IdLabel");
            if (label.len == 0) label = std.fs.path.basename(dev);

            const mp = propFirstMountPoint(aa, fp);
            try list.append(aa, .{
                .device = aa.dupe(u8, dev) catch continue,
                .label = aa.dupe(u8, label) catch continue,
                .mount_point = mp,
                .mounted = mp.len > 0,
                .object_path = aa.dupe(u8, opath.object_path) catch continue,
                .uuid = aa.dupe(u8, net.propString(bp, "IdUUID")) catch "",
                .fstype = aa.dupe(u8, net.propString(bp, "IdType")) catch "",
                .has_fstab = propHasFstab(bp),
            });
        }

        self.clearEntries();
        self.arena = ar;
        self.entries = try list.toOwnedSlice(aa);
    }
};

/// A `ay` byte-array property (e.g. `Device`) as a NUL-terminated string.
fn propBytes(aa: std.mem.Allocator, props: []const wire.Value, key: []const u8) ?[]const u8 {
    const v = findProp(props, key) orelse return null;
    if (v != .array) return null;
    var out: std.ArrayList(u8) = .empty;
    for (v.array.items) |b| {
        if (b != .byte) break;
        if (b.byte == 0) break;
        out.append(aa, b.byte) catch break;
    }
    return out.toOwnedSlice(aa) catch null;
}

/// Unwrap the `variant` value for `key` in a D-Bus property list.
fn findProp(props: []const wire.Value, key: []const u8) ?wire.Value {
    for (props) |entry| {
        if (entry != .structure or entry.structure.len < 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        return v.variant.val.*;
    }
    return null;
}

fn propBool(props: []const wire.Value, key: []const u8) bool {
    const v = findProp(props, key) orelse return false;
    return if (v == .boolean) v.boolean else false;
}

/// First entry of the `aay` `MountPoints` property, as a string.
fn propFirstMountPoint(aa: std.mem.Allocator, props: []const wire.Value) []const u8 {
    const v = findProp(props, "MountPoints") orelse return "";
    if (v != .array) return "";
    for (v.array.items) |inner| {
        if (inner != .array) continue;
        var out: std.ArrayList(u8) = .empty;
        for (inner.array.items) |b| {
            if (b != .byte) break;
            if (b.byte == 0) break;
            out.append(aa, b.byte) catch break;
        }
        const s = out.toOwnedSlice(aa) catch return "";
        if (s.len > 0) return s;
    }
    return "";
}

/// Block `Configuration` (`aa{sv}` of `(type, {…})` tuples) lists an `fstab`
/// item — C++ `UDisks2DriveService::has_fstab_entry` (`:215`), which makes the
/// Mount row mount directly instead of opening the dialog.
fn propHasFstab(props: []const wire.Value) bool {
    const v = findProp(props, "Configuration") orelse return false;
    if (v != .array) return false;
    for (v.array.items) |item| {
        if (item != .structure or item.structure.len == 0) continue;
        if (item.structure[0] == .string and std.mem.eql(u8, item.structure[0].string, "fstab")) return true;
    }
    return false;
}

/// One `("key", variant)` dict entry where the value is an `ay` byte string
/// (`string_to_bytes` in the C++ service).
fn fstabBytesEntry(a: std.mem.Allocator, key: []const u8, bytes: []const u8) !wire.Value {
    const pair = try a.alloc(wire.Value, 2);
    pair[0] = .{ .string = key };
    const octets = try a.alloc(wire.Value, bytes.len);
    for (bytes, 0..) |ch, i| octets[i] = .{ .byte = ch };
    const holder = try a.create(wire.Value);
    holder.* = .{ .array = .{ .elem = "y", .items = octets } };
    pair[1] = .{ .variant = .{ .sig = "ay", .val = holder } };
    return .{ .structure = pair };
}

/// One `("key", variant<i>)` dict entry (`freq` / `passno`).
fn fstabIntEntry(a: std.mem.Allocator, key: []const u8, v: i32) !wire.Value {
    const pair = try a.alloc(wire.Value, 2);
    pair[0] = .{ .string = key };
    const holder = try a.create(wire.Value);
    holder.* = .{ .int32 = v };
    pair[1] = .{ .variant = .{ .sig = "i", .val = holder } };
    return .{ .structure = pair };
}

/// `AddConfigurationItem` body: `(("fstab", {…}), {})` (`:305-317`). `fsname`
/// is `UUID=<uuid>` and is omitted when the drive has no UUID (`:305-307`);
/// an empty fstype falls back to `"auto"` (`:309`).
fn buildFstabBody(a: std.mem.Allocator, mount_point: []const u8, fstype: []const u8, uuid: []const u8, opts: []const u8) ![2]wire.Value {
    const ftype = if (fstype.len > 0) fstype else "auto";
    const fopts = if (opts.len > 0) opts else "defaults";

    var dict: std.ArrayList(wire.Value) = .empty;
    if (uuid.len > 0) {
        const fsname = try std.fmt.allocPrint(a, "UUID={s}", .{uuid});
        try dict.append(a, try fstabBytesEntry(a, "fsname", fsname));
    }
    try dict.append(a, try fstabBytesEntry(a, "dir", mount_point));
    try dict.append(a, try fstabBytesEntry(a, "type", ftype));
    try dict.append(a, try fstabBytesEntry(a, "opts", fopts));
    try dict.append(a, try fstabIntEntry(a, "freq", 0));
    try dict.append(a, try fstabIntEntry(a, "passno", 0));

    const item = try a.alloc(wire.Value, 2);
    item[0] = .{ .string = "fstab" };
    item[1] = .{ .array = .{ .elem = "{sv}", .items = dict.items } };

    var body: [2]wire.Value = undefined;
    body[0] = .{ .structure = item };
    body[1] = .{ .array = .{ .elem = "{sv}", .items = try a.alloc(wire.Value, 0) } };
    return body;
}

test "udisks: drive + block parse" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const mk = struct {
        fn s(a: std.mem.Allocator, k: []const u8, v: []const u8) !wire.Value {
            const p = try a.alloc(wire.Value, 2);
            p[0] = .{ .string = k };
            const b = try a.create(wire.Value);
            b.* = .{ .string = v };
            p[1] = .{ .variant = .{ .sig = "s", .val = b } };
            return .{ .structure = p };
        }
        fn u(a: std.mem.Allocator, k: []const u8, v: u64) !wire.Value {
            const p = try a.alloc(wire.Value, 2);
            p[0] = .{ .string = k };
            const b = try a.create(wire.Value);
            b.* = .{ .uint64 = v };
            p[1] = .{ .variant = .{ .sig = "t", .val = b } };
            return .{ .structure = p };
        }
    };
    const dp = try aa.alloc(wire.Value, 2);
    dp[0] = try mk.s(aa, "Model", "SSD 1TB");
    dp[1] = try mk.u(aa, "Size", 1000204886016);
    const d = parseDrive(dp);
    try t.expectEqualStrings("SSD 1TB", d.model);
    try t.expectEqual(@as(u64, 1000204886016), d.size_bytes);
    const bp = try aa.alloc(wire.Value, 2);
    bp[0] = try mk.s(aa, "IdLabel", "DATA");
    bp[1] = try mk.s(aa, "IdType", "ext4");
    const b = parseBlock(bp);
    try t.expectEqualStrings("DATA", b.label);
    try t.expect(!b.crypto_backing);
}
