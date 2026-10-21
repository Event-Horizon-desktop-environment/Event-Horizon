//! Live bluetooth behind the control-center tile + panel: BlueZ
//! `GetManagedObjects` over the system bus (adapters + devices, incl.
//! `Battery1` percentages), writes via direct method calls (`Powered`,
//! `Connect`/`Disconnect`/`Pair`, discovery). Slow verbs run in detached
//! threads; failures keep the cache.

const std = @import("std");
const live = @import("live.zig");
const wire = @import("../../dbus/wire.zig");
const conn_mod = @import("../../dbus/connection.zig");

pub const bluez_dest = "org.bluez";
pub const bluez_root = "/";
pub const adapter_iface = "org.bluez.Adapter1";
pub const device_iface = "org.bluez.Device1";
pub const battery_iface = "org.bluez.Battery1";

/// Mutex for the three module locks below.
/// no longer exists in this toolchain, and `std.Io.Mutex` needs an `io` that
/// detached BlueZ threads don't carry. The guarded sections are a few
/// instructions (mailbox push, connection guard, flag read), so a spin with
/// the repo's usual `spinLoopHint` is cheaper than plumbing Io through every
/// caller — and the `.lock()` / `.unlock()` call sites stay untouched.
const SpinMu = struct {
    flag: std.atomic.Value(bool) = .init(false),
    fn lock(m: *SpinMu) void {
        while (m.flag.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(m: *SpinMu) void {
        m.flag.store(false, .release);
    }
};

pub const Device = struct {
    path: []const u8 = "",
    address: []const u8 = "",
    name: []const u8 = "",
    /// `Alias`, falling back to `Name`, then the address — the display name
    /// the Bluetooth widget paints (BlueZ guarantees `Alias`, not `Name`).
    alias: []const u8 = "",
    paired: bool = false,
    connected: bool = false,
    rssi: i16 = 0,
    battery_pct: i32 = -1,
    /// Freedesktop `Icon` name (`audio-headphones`, `input-mouse`, …) for
    /// device-kind classification. Empty when the device reports none.
    icon: []const u8 = "",
    /// Bluetooth Class of Device for kind classification when `Icon` is
    /// absent. Only valid when `has_class` is set.
    class_code: u32 = 0,
    has_class: bool = false,
};

pub const Snapshot = struct {
    have_bluez: bool = false,
    powered: bool = false,
    discovering: bool = false,
    adapter_path: []const u8 = "",
};

/// Walk `a{oa{sa{sv}}}`: for every object, for every interface, call `f`
/// with (object path, interface name, its `a{sv}` dict).
fn walkManaged(objects: wire.Value, ctx: *anyopaque, f: *const fn (ctx: *anyopaque, path: []const u8, iface: []const u8, props: wire.Value) void) void {
    if (objects != .array) return;
    for (objects.array.items) |obj| {
        if (obj != .structure or obj.structure.len != 2) continue;
        if (obj.structure[0] != .object_path) continue;
        const path = obj.structure[0].object_path;
        if (obj.structure[1] != .array) continue;
        for (obj.structure[1].array.items) |ifentry| {
            if (ifentry != .structure or ifentry.structure.len != 2) continue;
            if (ifentry.structure[0] != .string) continue;
            f(ctx, path, ifentry.structure[0].string, ifentry.structure[1]);
        }
    }
}

const WalkCtx = struct {
    alloc: std.mem.Allocator,
    snap: *Snapshot,
    devices: *std.ArrayList(Device),
    // Per-device staging: devices arrive as up to two interface dicts
    // (Device1 + Battery1) for the same path; merge into one row.
    cur_path: []const u8 = "",
    cur: Device = .{},
    have_cur: bool = false,

    fn flush(self: *WalkCtx) void {
        if (!self.have_cur) return;
        self.have_cur = false;
        // No cap: every BlueZ object is kept and each view
        // budgets its own rows (dock popup: 7, settings tab: 12 with
        // paired/connected priority). Capping here evicted arbitrary
        // devices — during a scan the paired headset could vanish.
        if (self.cur.name.len == 0) self.cur.name = self.cur.address;
        if (self.cur.alias.len == 0) self.cur.alias = self.cur.name;
        const row = Device{
            .path = self.alloc.dupe(u8, self.cur.path) catch "",
            .address = self.alloc.dupe(u8, self.cur.address) catch "",
            .name = self.alloc.dupe(u8, self.cur.name) catch "",
            .alias = self.alloc.dupe(u8, self.cur.alias) catch "",
            .paired = self.cur.paired,
            .connected = self.cur.connected,
            .rssi = self.cur.rssi,
            .battery_pct = self.cur.battery_pct,
            .icon = self.alloc.dupe(u8, self.cur.icon) catch "",
            .class_code = self.cur.class_code,
            .has_class = self.cur.has_class,
        };
        self.devices.append(self.alloc, row) catch {};
        self.cur = .{};
        self.cur_path = "";
    }

    fn visit(ctx: *anyopaque, path: []const u8, iface: []const u8, props: wire.Value) void {
        const self: *WalkCtx = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, iface, adapter_iface)) {
            if (self.snap.adapter_path.len == 0) {
                self.snap.adapter_path = self.alloc.dupe(u8, path) catch "";
                self.snap.powered = live.asBool(live.dictFind(props, "Powered") orelse return);
                self.snap.discovering = live.asBool(live.dictFind(props, "Discovering") orelse wire.Value{ .boolean = false });
            }
            return;
        }
        if (std.mem.eql(u8, iface, device_iface)) {
            self.flush();
            self.have_cur = true;
            self.cur_path = path;
            self.cur.path = path;
            if (live.dictFind(props, "Address")) |v| self.cur.address = live.asString(v);
            if (live.dictFind(props, "Name")) |v| self.cur.name = live.asString(v);
            if (self.cur.name.len == 0) {
                if (live.dictFind(props, "Alias")) |v| self.cur.name = live.asString(v);
            }
            if (live.dictFind(props, "Alias")) |v| self.cur.alias = live.asString(v);
            if (live.dictFind(props, "Icon")) |v| self.cur.icon = live.asString(v);
            if (live.dictFind(props, "Class")) |v| {
                self.cur.class_code = live.asU32(v);
                self.cur.has_class = true;
            }
            if (live.dictFind(props, "Paired")) |v| self.cur.paired = live.asBool(v);
            if (live.dictFind(props, "Connected")) |v| self.cur.connected = live.asBool(v);
            if (live.dictFind(props, "RSSI")) |v| {
                const r = live.asI32(v);
                self.cur.rssi = @intCast(std.math.clamp(r, @as(i32, std.math.minInt(i16)), @as(i32, std.math.maxInt(i16))));
            }
            return;
        }
        if (std.mem.eql(u8, iface, battery_iface)) {
            // Merge into the Device1 row staged above when paths match.
            if (self.have_cur and std.mem.eql(u8, self.cur_path, path)) {
                if (live.dictFind(props, "Percentage")) |v| {
                    const p = live.asU32(v);
                    self.cur.battery_pct = if (p <= 100) @intCast(p) else -1;
                }
            }
            return;
        }
    }
};

pub const Queried = struct {
    alloc: std.mem.Allocator,
    snap: Snapshot = .{ .have_bluez = true },
    device_list: std.ArrayList(Device) = .empty,

    pub fn init(alloc: std.mem.Allocator) Queried {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Queried) void {
        if (self.snap.adapter_path.len > 0) self.alloc.free(self.snap.adapter_path);
        for (self.device_list.items) |d| {
            if (d.path.len > 0) self.alloc.free(d.path);
            if (d.address.len > 0) self.alloc.free(d.address);
            if (d.name.len > 0) self.alloc.free(d.name);
            if (d.alias.len > 0) self.alloc.free(d.alias);
            if (d.icon.len > 0) self.alloc.free(d.icon);
        }
        self.device_list.deinit(self.alloc);
        self.snap = .{};
    }
};

pub fn query(alloc: std.mem.Allocator) ?Queried {
    var conn = live.openBus(alloc, .system) orelse return null;
    defer conn.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p = conn.call(.{
        .mtype = .method_call,
        .path = bluez_root,
        .interface = "org.freedesktop.DBus.ObjectManager",
        .member = "GetManagedObjects",
        .destination = bluez_dest,
    }, 4000) catch return null;
    defer p.deinit();
    if (p.body_vals.len < 1) return null;
    var q = Queried.init(alloc);
    errdefer q.deinit();
    var ctx = WalkCtx{ .alloc = alloc, .snap = &q.snap, .devices = &q.device_list };
    walkManaged(p.body_vals[0], &ctx, WalkCtx.visit);
    ctx.flush();
    return q;
}

pub fn setPowered(alloc: std.mem.Allocator, powered: bool) bool {
    var conn = live.openBus(alloc, .system) orelse return false;
    defer conn.deinit();
    // Adapter path unknown without a query; query first (cheap, cached by
    // the caller in practice — this is the toggle path).
    var q = query(alloc) orelse return false;
    defer q.deinit();
    if (q.snap.adapter_path.len == 0) return false;
    return live.propSet(&conn, alloc, bluez_dest, q.snap.adapter_path, adapter_iface, "Powered", "b", .{ .boolean = powered });
}

pub fn deviceVerb(alloc: std.mem.Allocator, device_path: []const u8, verb: []const u8, timeout_ms: i64) bool {
    if (device_path.len == 0) return false;
    var conn = live.openBus(alloc, .system) orelse return false;
    defer conn.deinit();
    return live.callNoArgs(&conn, bluez_dest, device_path, device_iface, verb, timeout_ms);
}

// Async-verb completion mailbox
//
// Slow verbs (`Connect`/`Pair`) run in detached threads; the Settings tab
// needs the outcome to clear the row's spinner and surface failures. One
// slot, newest wins, mutex-guarded, copied out under the lock so the caller
// owns the bytes.

pub const VerbResult = struct {
    seq: u64 = 0,
    ok: bool = false,
    path_len: u16 = 0,
    verb_len: u8 = 0,
    err_len: u16 = 0,
    path: [128]u8 = undefined,
    verb: [32]u8 = undefined,
    err: [256]u8 = undefined,
};

var g_mail_mu: SpinMu = .{};
var g_mail_seq: u64 = 0;
var g_mail_result: VerbResult = .{};

/// Copy the newest completed async verb when its sequence is newer than
/// `since_seq` (start at 0 to see the first result).
pub fn pollVerbResult(since_seq: u64) ?VerbResult {
    g_mail_mu.lock();
    defer g_mail_mu.unlock();
    if (g_mail_seq == 0 or g_mail_seq <= since_seq) return null;
    return g_mail_result;
}

fn publishVerb(path: []const u8, verb: []const u8, ok: bool, err: []const u8) void {
    g_mail_mu.lock();
    defer g_mail_mu.unlock();
    g_mail_seq += 1;
    var r = VerbResult{ .seq = g_mail_seq, .ok = ok };
    r.path_len = @intCast(@min(path.len, r.path.len));
    @memcpy(r.path[0..r.path_len], path[0..r.path_len]);
    r.verb_len = @intCast(@min(verb.len, r.verb.len));
    @memcpy(r.verb[0..r.verb_len], verb[0..r.verb_len]);
    r.err_len = @intCast(@min(err.len, r.err.len));
    @memcpy(r.err[0..r.err_len], err[0..r.err_len]);
    g_mail_result = r;
}

fn copyStr(out: []u8, len: *usize, s: []const u8) void {
    const n = @min(s.len, out.len);
    @memcpy(out[0..n], s[0..n]);
    len.* = n;
}

fn appendStr(out: []u8, len: *usize, s: []const u8) void {
    const start = len.*;
    if (start >= out.len) return;
    const n = @min(s.len, out.len - start);
    @memcpy(out[start .. start + n], s[0..n]);
    len.* = start + n;
}

/// Format a failure (`"<verb> failed: <err>"`) into
/// `out`, returning the length.
fn formatVerbErr(out: []u8, verb: []const u8, err: []const u8) usize {
    // `std.io.fixedBufferStream` is gone in this toolchain; `bufPrint`
    // plus a memcpy keeps the same truncation (prefix, then what fits).
    const pre = std.fmt.bufPrint(out, "{s} failed: ", .{verb}) catch return 0;
    var len: usize = pre.len;
    if (len < out.len and err.len > 0) {
        const n = @min(err.len, out.len - len);
        @memcpy(out[len .. len + n], err[0..n]);
        len += n;
    }
    return len;
}

/// One method call with the D-Bus error name + message captured into
/// `err_out` (length through `err_len`), so callers can map them to
/// friendly text. `Conn.call` discards the error name on `RemoteError`, so
/// this replays the send/recv loop and copies it out.
fn verbOnConn(
    conn: *conn_mod.Conn,
    path: []const u8,
    iface: []const u8,
    member: []const u8,
    sig: []const u8,
    body: []const wire.Value,
    timeout_ms: i64,
    err_out: []u8,
    err_len: *usize,
) bool {
    err_len.* = 0;
    if (path.len == 0) return false;
    const serial = conn.sendMessage(.{
        .mtype = .method_call,
        .path = path,
        .interface = iface,
        .member = member,
        .destination = bluez_dest,
        .signature = sig,
        .body = body,
    }) catch {
        copyStr(err_out, err_len, "send failed");
        return false;
    };
    while (true) {
        var p = conn.recvMessage(timeout_ms) catch {
            copyStr(err_out, err_len, "no reply (timeout)");
            return false;
        };
        defer p.deinit();
        if (p.msg.reply_serial) |rs| {
            if (rs == serial) {
                if (p.msg.mtype == .@"error") {
                    // "org.bluez.Error.X: message" — the name plus the first
                    // body string when BlueZ supplies one.
                    copyStr(err_out, err_len, p.msg.err_name orelse "org.bluez.Error.Failed");
                    if (p.body_vals.len > 0 and p.body_vals[0] == .string) {
                        appendStr(err_out, err_len, ": ");
                        appendStr(err_out, err_len, p.body_vals[0].string);
                    }
                    return false;
                }
                return true;
            }
        }
        // Not ours — a signal. This connection is one-shot; drop it.
    }
}

/// `verbOnConn` on a throwaway system-bus connection.
fn verbOnBus(
    alloc: std.mem.Allocator,
    path: []const u8,
    iface: []const u8,
    member: []const u8,
    sig: []const u8,
    body: []const wire.Value,
    timeout_ms: i64,
    err_out: []u8,
    err_len: *usize,
) bool {
    err_len.* = 0;
    if (path.len == 0) return false;
    var conn = live.openBus(alloc, .system) orelse {
        copyStr(err_out, err_len, "no system bus");
        return false;
    };
    defer conn.deinit();
    return verbOnConn(&conn, path, iface, member, sig, body, timeout_ms, err_out, err_len);
}

/// Synchronous device verb that captures the D-Bus error and publishes the
/// outcome to the completion mailbox (so the Settings tab surfaces a failed
/// Disconnect in its status line). Returns true on success.
pub fn deviceVerbErr(alloc: std.mem.Allocator, device_path: []const u8, verb: []const u8, timeout_ms: i64) bool {
    var err_buf: [256]u8 = undefined;
    var err_len: usize = 0;
    const ok = verbOnBus(alloc, device_path, device_iface, verb, "", &.{}, timeout_ms, &err_buf, &err_len);
    var fb: [256]u8 = undefined;
    const fbn: usize = if (ok) 0 else formatVerbErr(&fb, verb, err_buf[0..err_len]);
    publishVerb(device_path, verb, ok, fb[0..fbn]);
    return ok;
}

const Bond = struct { paired: bool = false, connected: bool = false };

/// One device's fresh Paired/Connected state on a new connection, so a
/// cross-process change is visible (`read_bt_device_fresh` parity).
fn freshBond(alloc: std.mem.Allocator, device_path: []const u8) Bond {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var conn = live.openBus(aa, .system) orelse return .{};
    defer conn.deinit();
    var b = Bond{};
    if (live.propGet(&conn, aa, bluez_dest, device_path, device_iface, "Paired") catch null) |v| {
        b.paired = live.asBool(v);
    }
    if (live.propGet(&conn, aa, bluez_dest, device_path, device_iface, "Connected") catch null) |v| {
        b.connected = live.asBool(v);
    }
    return b;
}

pub const ThreadVerb = struct {
    path: []u8,
    verb: []u8,
    /// Adapter path for the pre-Pair `Pairable` nudge; may be empty.
    adapter: []u8,

    fn run(self: *ThreadVerb) void {
        const pa = std.heap.page_allocator;
        // Snapshot the fields and destroy the struct FIRST: deferred frees
        // run LIFO, so freeing through `self` after `destroy` reads
        // unmapped memory (use-after-free).
        const path = self.path;
        const verb = self.verb;
        const adapter = self.adapter;
        pa.destroy(self);
        defer {
            pa.free(path);
            pa.free(verb);
            if (adapter.len > 0) pa.free(adapter);
        }
        var arena = std.heap.ArenaAllocator.init(pa);
        defer arena.deinit();
        const aa = arena.allocator();

        const is_pair = std.mem.eql(u8, verb, "Pair");

        // Pre-Pair `Pairable = true` nudge (best-effort) so a device
        // waiting to bond is accepted without a rediscovery round.
        if (is_pair and adapter.len > 0) {
            var c1 = live.openBus(aa, .system);
            if (c1) |*c| {
                defer c.deinit();
                _ = live.propSet(c, aa, bluez_dest, adapter, adapter_iface, "Pairable", "b", .{ .boolean = true });
            }
        }

        var err_buf: [256]u8 = undefined;
        var err_len: usize = 0;
        const ok = verbOnBus(aa, path, device_iface, verb, "", &.{}, 25000, &err_buf, &err_len);

        // A failed Pair/Connect can still leave a usable bond (the
        // cross-process Pair vs Connect race). Only suppress the error when
        // BlueZ shows Connected AND Paired — an unpaired "Connected" is the
        // classic headphones-not-in-pairing-mode drop and must keep its
        // banner.
        var effective = ok;
        if (!ok and (is_pair or std.mem.eql(u8, verb, "Connect"))) {
            const b = freshBond(aa, path);
            if (b.connected and b.paired) effective = true;
        }

        // A successful Pair trusts the device so it may reconnect
        // without re-prompting.
        if (effective and is_pair) {
            var c2 = live.openBus(aa, .system);
            if (c2) |*c| {
                defer c.deinit();
                _ = live.propSet(c, aa, bluez_dest, path, device_iface, "Trusted", "b", .{ .boolean = true });
            }
        }

        var fb: [256]u8 = undefined;
        const fbn: usize = if (effective) 0 else formatVerbErr(&fb, verb, err_buf[0..err_len]);
        publishVerb(path, verb, effective, fb[0..fbn]);
    }
};

/// Slow verbs (`Connect`/`Pair`) in a detached thread with error capture
/// (page allocator only — never the dock's debug allocator off the loop
/// thread). The outcome lands in the completion mailbox.
pub fn deviceVerbThread(device_path: []const u8, verb: []const u8, adapter_path: []const u8) void {
    const pa = std.heap.page_allocator;
    const t = pa.create(ThreadVerb) catch return;
    t.* = .{
        .path = pa.dupe(u8, device_path) catch {
            pa.destroy(t);
            return;
        },
        .verb = pa.dupe(u8, verb) catch {
            pa.free(t.path);
            pa.destroy(t);
            return;
        },
        .adapter = pa.dupe(u8, adapter_path) catch {
            pa.free(t.path);
            pa.free(t.verb);
            pa.destroy(t);
            return;
        },
    };
    const th = std.Thread.spawn(.{}, ThreadVerb.run, .{t}) catch {
        pa.free(t.path);
        pa.free(t.verb);
        pa.free(t.adapter);
        pa.destroy(t);
        return;
    };
    th.detach();
}

pub fn removeDevice(alloc: std.mem.Allocator, adapter_path: []const u8, device_path: []const u8) bool {
    if (adapter_path.len == 0 or device_path.len == 0) return false;
    var conn = live.openBus(alloc, .system) orelse return false;
    defer conn.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const body = aa.alloc(wire.Value, 1) catch return false;
    body[0] = .{ .object_path = device_path };
    var p = conn.call(.{
        .mtype = .method_call,
        .path = adapter_path,
        .interface = adapter_iface,
        .member = "RemoveDevice",
        .destination = bluez_dest,
        .signature = "o",
        .body = body,
    }, 5000) catch return false;
    defer p.deinit();
    return true;
}

/// Discovery must be issued on a connection that outlives the call: BlueZ
/// stops discovery when the requesting client disconnects, so a throwaway
/// connection yields a scan that dies on return (persistent
/// `discovery_bus`, used ONLY here, serialized by the
/// mutex, so no connection is ever touched by two threads at once).
/// Module-level + mutex-guarded; the parked signal list is drained each
/// call so it cannot grow without bound.
var g_disc_mu: SpinMu = .{};
var g_disc_conn: ?conn_mod.Conn = null;

const DiscoveryWorker = struct {
    adapter: []u8,
    start: bool,

    fn run(self: *DiscoveryWorker) void {
        const pa = std.heap.page_allocator;
        // Snapshot + destroy first: deferred frees run LIFO, so freeing
        // through `self` after `destroy` reads unmapped memory.
        const adapter = self.adapter;
        const start = self.start;
        pa.destroy(self);
        defer pa.free(adapter);
        // `run_adapter_method_async` parity: Start/StopDiscovery with NO
        // arguments (never SetDiscoveryFilter) and a 10 s timeout, off the
        // UI thread, serialized on the discovery mutex.
        const method = if (start) "StartDiscovery" else "StopDiscovery";
        var err_buf: [256]u8 = undefined;
        var err_len: usize = 0;
        var ok = false;
        g_disc_mu.lock();
        if (g_disc_conn == null) g_disc_conn = live.openBus(pa, .system);
        if (g_disc_conn) |*c| {
            ok = verbOnConn(c, adapter, adapter_iface, method, "", &.{}, 10000, &err_buf, &err_len);
            // BlueZ emits discovery signals on this connection; drain them
            // so the parked list cannot grow without bound across a scan.
            for (c.pending.items) |*sp| sp.deinit();
            c.pending.clearRetainingCapacity();
        } else {
            copyStr(&err_buf, &err_len, "no discovery bus");
        }
        g_disc_mu.unlock();
        // Error format `method + " failed: " + err`:
        // the tab surfaces this in the Discovery status line.
        var fb: [256]u8 = undefined;
        const fbn: usize = if (ok) 0 else formatVerbErr(&fb, method, err_buf[0..err_len]);
        publishVerb(adapter, method, ok, fb[0..fbn]);
    }
};

/// Start/stop discovery WITHOUT blocking the caller: the BlueZ round trip
/// (up to 10 s) runs in a detached thread on the persistent discovery
/// connection in a detached thread. Failures land in
/// the completion mailbox (`"StartDiscovery failed: …"`) for the tab's
/// status line; the periodic refresh picks up the new `Discovering` state.
pub fn setDiscovery(alloc: std.mem.Allocator, adapter_path: []const u8, start: bool) void {
    _ = alloc;
    if (adapter_path.len == 0) return;
    const pa = std.heap.page_allocator;
    const w = pa.create(DiscoveryWorker) catch return;
    w.* = .{
        .adapter = pa.dupe(u8, adapter_path) catch {
            pa.destroy(w);
            return;
        },
        .start = start,
    };
    const th = std.Thread.spawn(.{}, DiscoveryWorker.run, .{w}) catch {
        pa.free(w.adapter);
        pa.destroy(w);
        return;
    };
    th.detach();
}

const PowerWorker = struct {
    adapter: []u8,
    on: bool,

    fn run(self: *PowerWorker) void {
        const pa = std.heap.page_allocator;
        // Snapshot + destroy first (see DiscoveryWorker.run): the deferred
        // free must not read through the struct after it is unmapped.
        const adapter = self.adapter;
        const on = self.on;
        pa.destroy(self);
        defer pa.free(adapter);
        // `run_set_powered_async` parity: Properties.Set(Powered) off the UI
        // thread (BlueZ can block for seconds on adapter init) with error
        // capture. A throwaway connection is fine — power is not a session.
        var arena = std.heap.ArenaAllocator.init(pa);
        defer arena.deinit();
        const aa = arena.allocator();
        const box = aa.create(wire.Value) catch return;
        box.* = .{ .boolean = on };
        const body = aa.alloc(wire.Value, 3) catch return;
        body[0] = .{ .string = adapter_iface };
        body[1] = .{ .string = "Powered" };
        body[2] = .{ .variant = .{ .sig = "b", .val = box } };
        var err_buf: [256]u8 = undefined;
        var err_len: usize = 0;
        const ok = verbOnBus(
            aa,
            adapter,
            "org.freedesktop.DBus.Properties",
            "Set",
            "ssv",
            body,
            10000,
            &err_buf,
            &err_len,
        );
        // `"Power on failed: …"` / `"Power off failed: …"` format.
        const vlabel = if (on) "Power on" else "Power off";
        var fb: [256]u8 = undefined;
        const fbn: usize = if (ok) 0 else formatVerbErr(&fb, vlabel, err_buf[0..err_len]);
        publishVerb(adapter, vlabel, ok, fb[0..fbn]);
    }
};

/// Set adapter power WITHOUT blocking the caller (see `setDiscovery`).
/// The tab flips its own `powered` snap optimistically and the periodic
/// refresh corrects it from the next poll.
pub fn setPoweredThread(alloc: std.mem.Allocator, adapter_path: []const u8, on: bool) void {
    _ = alloc;
    if (adapter_path.len == 0) return;
    const pa = std.heap.page_allocator;
    const w = pa.create(PowerWorker) catch return;
    w.* = .{
        .adapter = pa.dupe(u8, adapter_path) catch {
            pa.destroy(w);
            return;
        },
        .on = on,
    };
    const th = std.Thread.spawn(.{}, PowerWorker.run, .{w}) catch {
        pa.free(w.adapter);
        pa.destroy(w);
        return;
    };
    th.detach();
}

// rfkill
//
// A bluetooth rfkill block stops both powering on and scanning, so the
// adapter card calls it out explicitly (otherwise the failure looks like a
// broken button). Reads `/sys/class/rfkill/*/type|soft|hard`, OR-aggregated,
// with a 2 s re-read gate.

pub const Rfkill = struct { soft: bool = false, hard: bool = false };

/// Fresh on each call — the caller's ~500 ms refresh throttle gates the
/// rate (2 s cache; three tiny sysfs
/// reads are cheap enough here).
pub fn rfkillBlocked(io: std.Io, alloc: std.mem.Allocator) Rfkill {
    return readRfkill(io, alloc);
}

fn readRfkill(io: std.Io, alloc: std.mem.Allocator) Rfkill {
    var out = Rfkill{};
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/rfkill", .{ .iterate = true }) catch return out;
    defer dir.close(io);
    var it = dir.iterate();
    const cwd = std.Io.Dir.cwd();
    while (it.next(io) catch null) |e| {
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const tf = std.fs.path.join(alloc, &.{ "/sys/class/rfkill", e.name, "type" }) catch continue;
        defer alloc.free(tf);
        const tdata = cwd.readFileAlloc(io, tf, alloc, .limited(32)) catch continue;
        defer alloc.free(tdata);
        if (std.mem.indexOf(u8, tdata, "bluetooth") == null) continue;
        const sf = std.fs.path.join(alloc, &.{ "/sys/class/rfkill", e.name, "soft" }) catch continue;
        defer alloc.free(sf);
        if (cwd.readFileAlloc(io, sf, alloc, .limited(8))) |sdata| {
            defer alloc.free(sdata);
            if (sdata.len > 0 and sdata[0] == '1') out.soft = true;
        } else |_| {}
        const hf = std.fs.path.join(alloc, &.{ "/sys/class/rfkill", e.name, "hard" }) catch continue;
        defer alloc.free(hf);
        if (cwd.readFileAlloc(io, hf, alloc, .limited(8))) |hdata| {
            defer alloc.free(hdata);
            if (hdata.len > 0 and hdata[0] == '1') out.hard = true;
        } else |_| {}
    }
    return out;
}

test "live-bluetooth: managed-objects walk merges adapters, devices, batteries" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const mkdict = struct {
        fn d(a: std.mem.Allocator, pairs: []const struct { k: []const u8, v: wire.Value, sig: []const u8 }) !wire.Value {
            const items = try a.alloc(wire.Value, pairs.len);
            for (pairs, 0..) |pr, i| {
                const p = try a.alloc(wire.Value, 2);
                p[0] = .{ .string = pr.k };
                const b = try a.create(wire.Value);
                b.* = pr.v;
                p[1] = .{ .variant = .{ .sig = pr.sig, .val = b } };
                items[i] = .{ .structure = p };
            }
            return .{ .array = .{ .elem = "{sv}", .items = items } };
        }
        fn ifrow(a: std.mem.Allocator, iface: []const u8, dict: wire.Value) !wire.Value {
            const p = try a.alloc(wire.Value, 2);
            p[0] = .{ .string = iface };
            p[1] = dict;
            return .{ .structure = p };
        }
    };
    const adapter_props = try mkdict.d(aa, &.{
        .{ .k = "Powered", .v = .{ .boolean = true }, .sig = "b" },
        .{ .k = "Discovering", .v = .{ .boolean = false }, .sig = "b" },
    });
    const dev_props = try mkdict.d(aa, &.{
        .{ .k = "Address", .v = .{ .string = "AA:BB:CC:DD:EE:FF" }, .sig = "s" },
        .{ .k = "Name", .v = .{ .string = "Headset" }, .sig = "s" },
        .{ .k = "Paired", .v = .{ .boolean = true }, .sig = "b" },
        .{ .k = "Connected", .v = .{ .boolean = true }, .sig = "b" },
        .{ .k = "RSSI", .v = .{ .int16 = -55 }, .sig = "n" },
    });
    const bat_props = try mkdict.d(aa, &.{
        .{ .k = "Percentage", .v = .{ .byte = 80 }, .sig = "y" },
    });
    const ifaces_dev = try aa.alloc(wire.Value, 2);
    ifaces_dev[0] = try mkdict.ifrow(aa, device_iface, dev_props);
    ifaces_dev[1] = try mkdict.ifrow(aa, battery_iface, bat_props);
    const ifaces_ad = try aa.alloc(wire.Value, 1);
    ifaces_ad[0] = try mkdict.ifrow(aa, adapter_iface, adapter_props);
    const objs = try aa.alloc(wire.Value, 2);
    {
        const p = try aa.alloc(wire.Value, 2);
        p[0] = .{ .object_path = "/org/bluez/hci0" };
        p[1] = .{ .array = .{ .elem = "{sa{sv}}", .items = ifaces_ad } };
        objs[0] = .{ .structure = p };
    }
    {
        const p = try aa.alloc(wire.Value, 2);
        p[0] = .{ .object_path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" };
        p[1] = .{ .array = .{ .elem = "{sa{sv}}", .items = ifaces_dev } };
        objs[1] = .{ .structure = p };
    }
    const managed = wire.Value{ .array = .{ .elem = "{oa{sa{sv}}}", .items = objs } };
    var snap = Snapshot{};
    var devices: std.ArrayList(Device) = .empty;
    defer {
        for (devices.items) |d| {
            t.allocator.free(d.path);
            t.allocator.free(d.address);
            t.allocator.free(d.name);
            t.allocator.free(d.alias);
            t.allocator.free(d.icon);
        }
        devices.deinit(t.allocator);
    }
    var ctx = WalkCtx{ .alloc = t.allocator, .snap = &snap, .devices = &devices };
    walkManaged(managed, &ctx, WalkCtx.visit);
    ctx.flush();
    defer if (snap.adapter_path.len > 0) t.allocator.free(snap.adapter_path);
    try t.expect(snap.powered);
    try t.expectEqualStrings("/org/bluez/hci0", snap.adapter_path);
    try t.expectEqual(@as(usize, 1), devices.items.len);
    try t.expectEqualStrings("Headset", devices.items[0].name);
    try t.expectEqualStrings("Headset", devices.items[0].alias);
    try t.expect(devices.items[0].paired and devices.items[0].connected);
    try t.expectEqual(@as(i32, 80), devices.items[0].battery_pct);
}
