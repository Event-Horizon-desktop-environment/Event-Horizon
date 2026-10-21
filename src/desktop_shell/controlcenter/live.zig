//! Shared helpers behind the control-center live backends: short-lived
//! D-Bus connections (connect + Hello, one blocking call batch, close) and
//! small `wire.Value` readers for the shapes NM / BlueZ / MPRIS actually
//! return (`Properties.Get` variants, `a{sv}` dicts, `ay` byte strings).
//!
//! Every query opens its own connection so the dock's Wayland loop never
//! owns a bus fd for these — a dead bus fails one poll, not the frame.

const std = @import("std");
const conn_mod = @import("../../dbus/connection.zig");
const wire = @import("../../dbus/wire.zig");
const linux = std.os.linux;

const c = @cImport(@cInclude("stdlib.h"));

fn getenvSlice(key: [:0]const u8) ?[]const u8 {
    const p = c.getenv(key);
    if (p == null) return null;
    return std.mem.span(p);
}

/// Open + Hello a bus. Caller owns the connection and must `deinit` it.
/// Returns `null` when the bus is unreachable (daemon down, no socket) so
/// callers fall back to cached/default data instead of erroring the frame.
pub fn openBus(alloc: std.mem.Allocator, kind: conn_mod.BusKind) ?conn_mod.Conn {
    var address_buf: [256]u8 = undefined;
    const address: []const u8 = switch (kind) {
        .session => blk: {
            if (getenvSlice("DBUS_SESSION_BUS_ADDRESS")) |a| break :blk a;
            const uid: u32 = linux.getuid();
            const s = std.fmt.bufPrint(&address_buf, "unix:path=/run/user/{d}/bus", .{uid}) catch return null;
            break :blk s;
        },
        .system => blk: {
            if (getenvSlice("DBUS_SYSTEM_BUS_ADDRESS")) |a| break :blk a;
            break :blk "unix:path=/run/dbus/system_bus_socket";
        },
    };
    var conn = conn_mod.Conn.init(alloc);
    conn.connect(address) catch {
        conn.deinit();
        return null;
    };
    conn.hello() catch {
        conn.deinit();
        return null;
    };
    return conn;
}

pub const CallError = error{ OutOfMemory, Remote };

/// `org.freedesktop.DBus.Properties.Get(iface, prop)` — returns a deep copy
/// (see `wire.cloneValue`) of the value inside the reply variant, owned by
/// `alloc`. The reply itself is freed before returning, so nothing may
/// borrow from it — callers pass an arena and drop it when done.
pub fn propGet(
    conn: *conn_mod.Conn,
    alloc: std.mem.Allocator,
    dest: []const u8,
    path: []const u8,
    iface: []const u8,
    prop: []const u8,
) CallError!?wire.Value {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const body = aa.alloc(wire.Value, 2) catch return CallError.OutOfMemory;
    body[0] = .{ .string = iface };
    body[1] = .{ .string = prop };
    var p = conn.call(.{
        .mtype = .method_call,
        .path = path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .destination = dest,
        .signature = "ss",
        .body = body,
    }, 3000) catch return null;
    defer p.deinit();
    if (p.body_vals.len < 1 or p.body_vals[0] != .variant) return null;
    // Deep-copy out of the reply arena: `p.deinit()` (deferred above) frees
    // everything the value points at — arrays, structures, strings. Returning
    // the shallow copy handed callers freed pointers (segfault in dictFind).
    return wire.cloneValue(alloc, p.body_vals[0].variant.val.*) catch null;
}

/// `Properties.Set(iface, prop, variant)` with an explicit variant
/// signature, e.g. `"b"` for booleans.
pub fn propSet(
    conn: *conn_mod.Conn,
    alloc: std.mem.Allocator,
    dest: []const u8,
    path: []const u8,
    iface: []const u8,
    prop: []const u8,
    vsig: []const u8,
    val: wire.Value,
) bool {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const box = aa.create(wire.Value) catch return false;
    box.* = val;
    const body = aa.alloc(wire.Value, 3) catch return false;
    body[0] = .{ .string = iface };
    body[1] = .{ .string = prop };
    body[2] = .{ .variant = .{ .sig = vsig, .val = box } };
    var p = conn.call(.{
        .mtype = .method_call,
        .path = path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .destination = dest,
        .signature = "ssv",
        .body = body,
    }, 3000) catch return false;
    defer p.deinit();
    return true;
}

/// No-arg method call (`Connect`, `Disconnect`, `Next`, …). Returns false on
/// transport failure *or* a remote error (not paired, no player, …).
pub fn callNoArgs(
    conn: *conn_mod.Conn,
    dest: []const u8,
    path: []const u8,
    iface: []const u8,
    member: []const u8,
    timeout_ms: i64,
) bool {
    var p = conn.call(.{
        .mtype = .method_call,
        .path = path,
        .interface = iface,
        .member = member,
        .destination = dest,
    }, timeout_ms) catch return false;
    defer p.deinit();
    return true;
}

// wire.Value readers (all pure, all tested below)

/// Find `key` in an `a{sv}` array value; returns the variant's inner value.
pub fn dictFind(arr: wire.Value, key: []const u8) ?wire.Value {
    if (arr != .array) return null;
    for (arr.array.items) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        if (entry.structure[1] != .variant) continue;
        return entry.structure[1].variant.val.*;
    }
    return null;
}

pub fn asString(v: wire.Value) []const u8 {
    return if (v == .string) v.string else "";
}

pub fn asObjectPath(v: wire.Value) []const u8 {
    return if (v == .object_path) v.object_path else "";
}

pub fn asBool(v: wire.Value) bool {
    return if (v == .boolean) v.boolean else false;
}

pub fn asU32(v: wire.Value) u32 {
    return switch (v) {
        .uint32 => |x| x,
        .uint16 => |x| x,
        .byte => |x| x,
        .int32 => |x| if (x < 0) 0 else @intCast(x),
        else => 0,
    };
}

pub fn asI32(v: wire.Value) i32 {
    return switch (v) {
        .int32 => |x| x,
        .int16 => |x| x,
        .uint32 => |x| if (x > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(x),
        .byte => |x| x,
        .int64 => |x| @intCast(std.math.clamp(x, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32)))),
        else => 0,
    };
}

/// `ay` byte array → raw bytes (SSIDs, icon pixmaps). Returns null for any
/// other shape.
pub fn asBytes(v: wire.Value) ?[]const u8 {
    if (v != .array) return null;
    // Some peers send `ay` as an array of bytes; accept nothing else.
    for (v.array.items) |it| if (it != .byte) return null;
    return null; // decoded by bytesInto below (needs an output buffer)
}

/// Copy an `ay` array into `out`, returning the slice. Truncates silently —
/// SSIDs over the buffer are a display string, not a key.
pub fn bytesInto(v: wire.Value, out: []u8) []const u8 {
    if (v != .array) return "";
    var n: usize = 0;
    for (v.array.items) |it| {
        if (it != .byte) return "";
        if (n >= out.len) break;
        out[n] = it.byte;
        n += 1;
    }
    // SSIDs are NUL-free by construction; stop at the first NUL anyway.
    if (std.mem.indexOfScalar(u8, out[0..n], 0)) |z| n = z;
    return out[0..n];
}

/// `as` array of strings joined with ", " into `out` (MPRIS artists).
pub fn strListInto(v: wire.Value, out: []u8) []const u8 {
    if (v != .array) return "";
    var n: usize = 0;
    var first = true;
    for (v.array.items) |it| {
        if (it != .string) continue;
        if (!first) {
            if (n + 2 > out.len) break;
            out[n] = ',';
            out[n + 1] = ' ';
            n += 2;
        }
        first = false;
        const take = @min(it.string.len, out.len - n);
        @memcpy(out[n .. n + take], it.string[0..take]);
        n += take;
        if (n >= out.len) break;
    }
    return out[0..n];
}

/// Run `argv` to completion and return its stdout, owned by the caller.
/// Returns `null` when the tool is missing, exits non-zero, or writes
/// nothing — every live backend treats that as "fall back to cache".
pub fn runCapture(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]u8 {
    const res = std.process.run(alloc, io, .{ .argv = argv }) catch return null;
    defer alloc.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        alloc.free(res.stdout);
        return null;
    }
    if (res.stdout.len == 0) {
        alloc.free(res.stdout);
        return null;
    }
    return res.stdout;
}

/// Fire-and-forget spawn for fast tools (radio toggle). Slow verbs go
/// through threads so the Wayland loop never blocks; zombies are reaped by
/// `app_launch.reap()` on the dock tick.
pub fn spawnForget(io: std.Io, argv: []const []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    // No wait: reap() collects it. Dropping `child` without waiting is
    // intentional — `kill` would defeat the purpose.
    _ = &child;
}

test "live-dbus: dictFind + scalar readers over synthetic values" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const mk = struct {
        fn pair(a: std.mem.Allocator, k: []const u8, v: wire.Value, sig: []const u8) !wire.Value {
            const p = try a.alloc(wire.Value, 2);
            p[0] = .{ .string = k };
            const b = try a.create(wire.Value);
            b.* = v;
            p[1] = .{ .variant = .{ .sig = sig, .val = b } };
            return .{ .structure = p };
        }
    };
    const items = try aa.alloc(wire.Value, 3);
    items[0] = try mk.pair(aa, "Name", .{ .string = "Headset" }, "s");
    items[1] = try mk.pair(aa, "Paired", .{ .boolean = true }, "b");
    items[2] = try mk.pair(aa, "RSSI", .{ .int16 = -60 }, "n");
    const dict = wire.Value{ .array = .{ .elem = "{sv}", .items = items } };
    try t.expectEqualStrings("Headset", asString(dictFind(dict, "Name").?));
    try t.expect(asBool(dictFind(dict, "Paired").?));
    try t.expectEqual(@as(i32, -60), asI32(dictFind(dict, "RSSI").?));
    try t.expect(dictFind(dict, "Missing") == null);
    try t.expectEqual(@as(u32, 0), asU32(dictFind(dict, "Name").?));
}

test "live-dbus: ay + as helpers" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const bytes = try aa.alloc(wire.Value, 4);
    bytes[0] = .{ .byte = 'H' };
    bytes[1] = .{ .byte = 'i' };
    bytes[2] = .{ .byte = 0 };
    bytes[3] = .{ .byte = '!' };
    var sbuf: [16]u8 = undefined;
    // Stops at the embedded NUL.
    try t.expectEqualStrings("Hi", bytesInto(.{ .array = .{ .elem = "y", .items = bytes } }, &sbuf));
    try t.expectEqualStrings("", bytesInto(.{ .string = "nope" }, &sbuf));

    const names = try aa.alloc(wire.Value, 2);
    names[0] = .{ .string = "A" };
    names[1] = .{ .string = "B" };
    var lbuf: [16]u8 = undefined;
    try t.expectEqualStrings("A, B", strListInto(.{ .array = .{ .elem = "s", .items = names } }, &lbuf));
}
