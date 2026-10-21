//! `com.canonical.dbusmenu` — the right-click menu a tray icon offers.
//!
//! Read the
//! item's `Menu` property, poke lazy menus with `AboutToShow`, pull one level
//! of layout with `GetLayout`, and address a click back with `Event`.
//!
//! Every call runs with the short interactive timeout on purpose. The
//! connection-wide one would stall the Wayland input thread for seconds —
//! Steam's DBusMenu is the usual offender — which is the exact freeze those
//! constants exist to prevent.

const std = @import("std");
const connection = @import("../dbus/connection.zig");
const wire = @import("../dbus/wire.zig");

/// `kTrayMenuCallTimeout`.
pub const kCallTimeoutMs: i64 = 750;
/// `kTrayAboutToShowTimeout`.
pub const kAboutToShowTimeoutMs: i64 = 400;
/// Nothing the tray's click path waits on may block any longer than this.
pub const kActivateTimeoutMs: i64 = 800;

pub const item_iface = "org.kde.StatusNotifierItem";
pub const menu_iface = "com.canonical.dbusmenu";

/// One menu line. `label` is borrowed from whatever arena the caller passed
/// to `fetchTopLevel`; `id` is the dbusmenu id a click reports back, or `-1`
/// for a separator.
pub const Entry = struct {
    label: []const u8 = "",
    id: i32 = -1,
    enabled: bool = true,
};

pub fn isSeparator(e: Entry) bool {
    return e.id < 0;
}

/// Wall-clock milliseconds — the dbusmenu `Event` timestamp asks for the
/// epoch, not a monotonic tick.
pub fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    const s: i64 = @intCast(@max(ts.sec, 0));
    const n: i64 = @intCast(@max(ts.nsec, 0));
    return s * 1000 + @divTrunc(n, 1_000_000);
}

// Wire parsing — pure, so it can be tested without a bus

/// One `(ia{sv}av)` node of a layout tree.
pub const Layout = struct {
    id: i32 = -1,
    props: []const wire.Value = &.{},
    children: []const wire.Value = &.{},
};

pub fn asLayout(v: wire.Value) ?Layout {
    if (v != .structure or v.structure.len != 3) return null;
    if (v.structure[0] != .int32) return null;
    const props = switch (v.structure[1]) {
        .array => |a| a.items,
        else => return null,
    };
    const children = switch (v.structure[2]) {
        .array => |a| a.items,
        else => return null,
    };
    return .{ .id = v.structure[0].int32, .props = props, .children = children };
}

/// A child is a `v` wrapping its own `(ia{sv}av)`.
pub fn asChildLayout(v: wire.Value) ?Layout {
    return switch (v) {
        .variant => |vr| asLayout(vr.val.*),
        else => asLayout(v),
    };
}

/// The body of `GetLayout` — `u (ia{sv}av) ai`.
pub fn parseGetLayout(vals: []const wire.Value) ?Layout {
    if (vals.len < 2) return null;
    return asLayout(vals[1]);
}

fn prop(props: []const wire.Value, key: []const u8) ?wire.Value {
    for (props) |p| {
        if (p != .structure or p.structure.len != 2) continue;
        if (p.structure[0] != .string) continue;
        if (!std.mem.eql(u8, p.structure[0].string, key)) continue;
        if (p.structure[1] != .variant) continue;
        return p.structure[1].variant.val.*;
    }
    return null;
}

pub fn propStr(props: []const wire.Value, key: []const u8) ?[]const u8 {
    const v = prop(props, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// dbusmenu clients are not consistent about `enabled`/`visible`: some send a
/// `b`, some an `i`. Take either, fall back to the caller's default.
pub fn propBool(props: []const wire.Value, key: []const u8, def: bool) bool {
    const v = prop(props, key) orelse return def;
    return switch (v) {
        .boolean => |b| b,
        .int32 => |i| i != 0,
        .uint32 => |i| i != 0,
        else => def,
    };
}

/// `_` is how dbusmenu marks an mnemonics underline; every one is stripped
/// of them rather than trying to work out which are mnemonics.
fn stripMnemonic(alloc: std.mem.Allocator, label: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, label, '_') == null) return try alloc.dupe(u8, label);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (label) |ch| {
        if (ch == '_') continue;
        try out.append(alloc, ch);
    }
    return try out.toOwnedSlice(alloc);
}

/// Turn the root's children into menu entries. Exported for tests.
pub fn entriesFromLayout(alloc: std.mem.Allocator, root: Layout) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| alloc.free(e.label);
        out.deinit(alloc);
    }
    for (root.children) |raw| {
        const child = asChildLayout(raw) orelse continue;
        const typ = propStr(child.props, "type") orelse "";
        if (std.mem.eql(u8, typ, "separator")) {
            try out.append(alloc, .{ .id = -1, .enabled = false });
            continue;
        }
        if (!propBool(child.props, "visible", true)) continue;
        const raw_label = propStr(child.props, "label") orelse "";
        const stripped = try stripMnemonic(alloc, raw_label);
        const label = if (stripped.len == 0) blk: {
            alloc.free(stripped);
            break :blk try alloc.dupe(u8, "(unnamed)");
        } else
            stripped;
        try out.append(alloc, .{
            .label = label,
            .id = child.id,
            .enabled = propBool(child.props, "enabled", true),
        });
    }
    return try out.toOwnedSlice(alloc);
}

// Bus I/O

fn call(
    conn: *connection.Conn,
    path: []const u8,
    iface: []const u8,
    member: []const u8,
    dest: []const u8,
    signature: []const u8,
    body: []const wire.Value,
    timeout_ms: i64,
) ?wire.Parsed {
    return conn.call(.{
        .mtype = .method_call,
        .path = path,
        .interface = iface,
        .member = member,
        .destination = dest,
        .signature = signature,
        .body = body,
    }, timeout_ms) catch null;
}

/// The SNI's `Menu` property — an object path pointing at a
/// `com.canonical.dbusmenu` object, or absent when the item offers no menu.
/// The result is owned by `alloc`.
pub fn menuPath(
    alloc: std.mem.Allocator,
    conn: *connection.Conn,
    service: []const u8,
    item_path: []const u8,
) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const body = aa.alloc(wire.Value, 2) catch return null;
    body[0] = .{ .string = item_iface };
    body[1] = .{ .string = "Menu" };
    const reply = call(
        conn,
        item_path,
        "org.freedesktop.DBus.Properties",
        "Get",
        service,
        "ss",
        body,
        kCallTimeoutMs,
    ) orelse return null;
    var p = reply;
    defer p.deinit();
    if (p.body_vals.len < 1) return null;
    const v = switch (p.body_vals[0]) {
        .variant => |vr| vr.val.*,
        else => return null,
    };
    const path = switch (v) {
        .object_path => |s| s,
        .string => |s| s,
        else => return null,
    };
    if (path.len <= 1) return null;
    return alloc.dupe(u8, path) catch null;
}

/// Best-effort `AboutToShow(0)`. Steam and friends only populate their layout
/// after this, so `GetLayout` alone returns an empty menu and we fall back to
/// the item's own `ContextMenu` for no good reason. Failures are ignored —
/// plenty of menus do not implement it.
pub fn aboutToShow(conn: *connection.Conn, service: []const u8, menu_path: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const body = arena.allocator().alloc(wire.Value, 1) catch return;
    body[0] = .{ .int32 = 0 };
    const reply = call(
        conn,
        menu_path,
        menu_iface,
        "AboutToShow",
        service,
        "i",
        body,
        kAboutToShowTimeoutMs,
    ) orelse return;
    var p = reply;
    defer p.deinit();
}

/// The top level of the menu, with every label copied into `alloc`. Returns
/// an empty slice when the item has no readable DBusMenu — the caller decides
/// whether to fall back to `ContextMenu`.
pub fn fetchTopLevel(
    alloc: std.mem.Allocator,
    conn: *connection.Conn,
    service: []const u8,
    menu_path: []const u8,
) []Entry {
    if (menu_path.len == 0) return &.{};
    aboutToShow(conn, service, menu_path);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const names = aa.alloc(wire.Value, 4) catch return &.{};
    names[0] = .{ .string = "label" };
    names[1] = .{ .string = "enabled" };
    names[2] = .{ .string = "visible" };
    names[3] = .{ .string = "type" };
    const body = aa.alloc(wire.Value, 3) catch return &.{};
    body[0] = .{ .int32 = 0 };
    body[1] = .{ .int32 = 1 };
    body[2] = .{ .array = .{ .elem = "s", .items = names } };

    const reply = call(
        conn,
        menu_path,
        menu_iface,
        "GetLayout",
        service,
        "iias",
        body,
        kCallTimeoutMs,
    ) orelse return &.{};
    var p = reply;
    defer p.deinit();

    const root = parseGetLayout(p.body_vals) orelse return &.{};
    return entriesFromLayout(alloc, root) catch &.{};
}

/// A click on a row: `Event(id, "clicked", Variant(i32 0), 0)`. The `data` parameter is a dbusmenu `v`, not a bare
/// `a{sv}`: servers validate the signature and reject anything else, which
/// is how a click used to vanish without a sound. The timestamp is 0 for
/// the same reason — 0 is sent, and an epoch-ms value does not fit a
/// `u32` anyway (`@intCast` on it panics a Debug build).
pub fn activate(
    conn: *connection.Conn,
    service: []const u8,
    menu_path: []const u8,
    id: i32,
) void {
    if (menu_path.len == 0 or id < 0) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var zero = wire.Value{ .int32 = 0 };
    const body = aa.alloc(wire.Value, 4) catch return;
    body[0] = .{ .int32 = id };
    body[1] = .{ .string = "clicked" };
    body[2] = .{ .variant = .{ .sig = "i", .val = &zero } };
    body[3] = .{ .uint32 = 0 };
    const reply = call(
        conn,
        menu_path,
        menu_iface,
        "Event",
        service,
        "isvu",
        body,
        kActivateTimeoutMs,
    ) orelse return;
    var p = reply;
    defer p.deinit();
}

/// Per-spec right-click fallback: ask the item to open its own menu at the
/// pointer. Used when there is no DBusMenu at all, or when `GetLayout` comes
/// back empty (a Steam stall being the classic case).
pub fn contextMenuFallback(
    conn: *connection.Conn,
    service: []const u8,
    item_path: []const u8,
    x: i32,
    y: i32,
) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const body = aa.alloc(wire.Value, 2) catch return;
    body[0] = .{ .int32 = x };
    body[1] = .{ .int32 = y };
    const reply = call(
        conn,
        item_path,
        item_iface,
        "ContextMenu",
        service,
        "ii",
        body,
        kCallTimeoutMs,
    ) orelse return;
    var p = reply;
    defer p.deinit();
}

test "tray-menu: layout node, properties and mnemonic stripping" {
    const t = std.testing;
    const alloc = t.allocator;

    var label_v = wire.Value{ .string = "_Open _Window" };
    var enabled_v = wire.Value{ .boolean = false };
    var visible_v = wire.Value{ .uint32 = 1 };
    var no_items: [0]wire.Value = .{};

    var label_prop = [_]wire.Value{ .{ .string = "label" }, .{ .variant = .{ .sig = "s", .val = &label_v } } };
    var enabled_prop = [_]wire.Value{ .{ .string = "enabled" }, .{ .variant = .{ .sig = "b", .val = &enabled_v } } };
    var visible_prop = [_]wire.Value{ .{ .string = "visible" }, .{ .variant = .{ .sig = "u", .val = &visible_v } } };
    var props = [_]wire.Value{
        .{ .structure = &label_prop },
        .{ .structure = &enabled_prop },
        .{ .structure = &visible_prop },
    };

    // Every `stripMnemonic` copies, even when it copies unchanged.
    {
        const l1 = try stripMnemonic(alloc, "_Open _Window");
        defer alloc.free(l1);
        try t.expectEqualStrings("Open Window", l1);
        const l2 = try stripMnemonic(alloc, "plain");
        defer alloc.free(l2);
        try t.expectEqualStrings("plain", l2);
        const l3 = try stripMnemonic(alloc, "___");
        // A zero-length result carries no allocation to release.
        defer if (l3.len > 0) alloc.free(l3);
        try t.expectEqualStrings("", l3);
    }
    try t.expectEqual(propStr(&props, "label").?, "_Open _Window");
    try t.expectEqual(propStr(&props, "missing"), null);
    try t.expect(!propBool(&props, "enabled", true));
    try t.expect(propBool(&props, "visible", false));
    try t.expect(propBool(&props, "nope", true));

    // A separator is a node whose `type` is `separator`.
    var sep_type = wire.Value{ .string = "separator" };
    var sep_prop = [_]wire.Value{ .{ .string = "type" }, .{ .variant = .{ .sig = "s", .val = &sep_type } } };
    var sep_props = [_]wire.Value{.{ .structure = &sep_prop }};
    var sep_parts = [_]wire.Value{
        .{ .int32 = 7 },
        .{ .array = .{ .elem = "{sv}", .items = &sep_props } },
        .{ .array = .{ .elem = "v", .items = &no_items } },
    };
    var sep_node = wire.Value{ .structure = &sep_parts };

    var child_parts = [_]wire.Value{
        .{ .int32 = 42 },
        .{ .array = .{ .elem = "{sv}", .items = &props } },
        .{ .array = .{ .elem = "v", .items = &no_items } },
    };
    var child_node = wire.Value{ .structure = &child_parts };

    var root_children = [_]wire.Value{
        .{ .variant = .{ .sig = "(ia{sv}av)", .val = &sep_node } },
        .{ .variant = .{ .sig = "(ia{sv}av)", .val = &child_node } },
    };
    var root_parts = [_]wire.Value{
        .{ .int32 = 0 },
        .{ .array = .{ .elem = "{sv}", .items = &no_items } },
        .{ .array = .{ .elem = "v", .items = &root_children } },
    };
    const root = wire.Value{ .structure = &root_parts };
    var no_errs: [0]wire.Value = .{};

    const parsed = parseGetLayout(&[_]wire.Value{
        .{ .uint32 = 3 },
        root,
        .{ .array = .{ .elem = "i", .items = &no_errs } },
    }).?;
    const entries = try entriesFromLayout(alloc, parsed);
    defer {
        for (entries) |e| if (e.label.len > 0) alloc.free(e.label);
        alloc.free(entries);
    }
    try t.expectEqual(@as(usize, 2), entries.len);
    try t.expect(isSeparator(entries[0]));
    try t.expect(!entries[0].enabled);
    try t.expectEqual(@as(i32, 42), entries[1].id);
    try t.expect(!entries[1].enabled);
    try t.expectEqualStrings("Open Window", entries[1].label);

    // `visible = false` drops the row entirely.
    var invisible = wire.Value{ .boolean = false };
    var hidden_prop = [_]wire.Value{ .{ .string = "visible" }, .{ .variant = .{ .sig = "b", .val = &invisible } } };
    var hidden_props = [_]wire.Value{.{ .structure = &hidden_prop }};
    var hidden_parts = [_]wire.Value{
        .{ .int32 = 9 },
        .{ .array = .{ .elem = "{sv}", .items = &hidden_props } },
        .{ .array = .{ .elem = "v", .items = &no_items } },
    };
    var hidden_node = wire.Value{ .structure = &hidden_parts };
    var hidden_children = [_]wire.Value{.{ .variant = .{ .sig = "(ia{sv}av)", .val = &hidden_node } }};
    var hidden_parts_root = [_]wire.Value{
        .{ .int32 = 0 },
        .{ .array = .{ .elem = "{sv}", .items = &no_items } },
        .{ .array = .{ .elem = "v", .items = &hidden_children } },
    };
    const hidden_root = wire.Value{ .structure = &hidden_parts_root };
    const hidden_parsed = parseGetLayout(&[_]wire.Value{
        .{ .uint32 = 1 },
        hidden_root,
        .{ .array = .{ .elem = "i", .items = &no_errs } },
    }).?;
    const hidden_entries = try entriesFromLayout(alloc, hidden_parsed);
    defer {
        for (hidden_entries) |e| if (e.label.len > 0) alloc.free(e.label);
        alloc.free(hidden_entries);
    }
    try t.expectEqual(@as(usize, 0), hidden_entries.len);

    // A malformed reply yields nothing rather than a half-built menu.
    try t.expect(parseGetLayout(&.{}) == null);
    try t.expect(parseGetLayout(&.{ .{ .uint32 = 1 }, .{ .string = "nope" } }) == null);
    try t.expect(asChildLayout(.{ .int32 = 1 }) == null);
}

test "tray-menu: epoch milliseconds are plausible" {
    const t = std.testing;
    const now = nowMs();
    // Somewhere after 2024 and before 2100.
    try t.expect(now > 1_700_000_000_000);
    try t.expect(now < 4_102_444_800_000);
}
