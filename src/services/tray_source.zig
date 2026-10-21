//! The dock's live system-tray source.
//!
//! The dock is a standalone process, so it owns `org.kde.StatusNotifierWatcher`
//! itself and does that work directly:
//!
//!   * when nobody owns the watcher name it takes it and answers
//!     `RegisterStatusNotifierItem` directly;
//!   * otherwise it mirrors the running watcher's
//!     `RegisteredStatusNotifierItems`, which lets concurrent dock processes
//!     show the same tray.
//!
//! Either way each item's `Id`/`Title`/`IconName`/`Status` come from one
//! `org.freedesktop.DBus.Properties.GetAll` round trip (with a per-property
//! `Get` fallback for items whose `GetAll` misbehaves), and later changes arrive as
//! `org.kde.StatusNotifierItem` signals.
//!
//! Not ported yet: tray env filter (the
//! `EH_HIDE_TRAYIDS`/`EH_BLACKLIST_TRAYIDS` suppression list — opt-in via
//! environment, empty by default, so no behavior gap unless set).
//! `IconThemePath` storage and lookup: the dock searches the
//! item's own directory first. Items owned by the shell itself are suppressed; here the dock is the
//! shell, so that case cannot arise.

const std = @import("std");
const wire = @import("../dbus/wire.zig");
const connection = @import("../dbus/connection.zig");
const object = @import("../dbus/object.zig");
const sock = @import("../sock.zig");
const tray = @import("tray.zig");
const logz = @import("../logz.zig");
const libc = @cImport(@cInclude("stdlib.h"));

/// Tray slot key prefix: a tray
/// slot's key is this prefix followed by the item's service and object path.
pub const slot_key = "__tray__";

/// How long one blocking round trip may hold the wayland loop. The session
/// bus answers in well under a millisecond; this bound only bites once the
/// bus has gone away, and it keeps the dock drawing.
const k_call_timeout_ms: i64 = 1000;

/// Shorter bound for the startup discovery probes: one hung name must not
/// stall the dock the way a full item read might.
const k_probe_timeout_ms: i64 = 400;

/// Shared reply budget for one pipelined discovery burst. Every probe is
/// already in flight when the clock starts, so this is the whole scan's
/// worst case no matter how many names stay silent.
const k_discover_budget_ms: i64 = 1500;

/// Full re-read of the registration list this often — a safety net for the
/// signals that can be lost while a call is in flight.
const k_resync_ms: i64 = 5000;

/// `DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER` / `_ALREADY_OWNER`.
const k_name_owned = [_]u32{ 1, 4 };

/// Heap-owned copy of the watcher object description. Only the arrays are
/// allocated — every string and function pointer inside aliases static data
/// or the source, so freeing the four arrays is the whole teardown.
const WatcherTables = struct {
    vtables: []object.VTable,
    methods: []object.Method,
    properties: []object.Property,
    signals: []object.VTable.Signal,

    fn deinit(self: *WatcherTables, alloc: std.mem.Allocator) void {
        alloc.free(self.vtables);
        alloc.free(self.methods);
        alloc.free(self.properties);
        alloc.free(self.signals);
        self.* = undefined;
    }
};

/// Builds the heap-owned watcher tables for `adoptWatcher`. Factored out
/// so tests can pin the shape: `Tree.addObject` keeps the slices it is
/// handed, so these must never be function-local temporaries.
fn buildWatcherTables(alloc: std.mem.Allocator, ctx: *anyopaque) !WatcherTables {
    var wt = WatcherTables{
        .vtables = &.{},
        .methods = &.{},
        .properties = &.{},
        .signals = &.{},
    };
    wt.methods = try alloc.dupe(object.Method, &.{
        .{ .name = "RegisterStatusNotifierItem", .in_sig = "s", .out_sig = "", .handler = registerItemHandler, .ctx = ctx },
        .{ .name = "RegisterStatusNotifierHost", .in_sig = "s", .out_sig = "", .handler = registerHostHandler, .ctx = ctx },
        .{ .name = "UnregisterStatusNotifierItem", .in_sig = "s", .out_sig = "", .handler = registerHostHandler, .ctx = ctx },
        .{ .name = "UnregisterStatusNotifierHost", .in_sig = "s", .out_sig = "", .handler = registerHostHandler, .ctx = ctx },
    });
    errdefer alloc.free(wt.methods);
    wt.properties = try alloc.dupe(object.Property, &.{
        .{ .name = "IsStatusNotifierHostRegistered", .sig = "b", .access = .read, .get = propHostRegistered, .ctx = ctx },
        .{ .name = "ProtocolVersion", .sig = "i", .access = .read, .get = propProtocolVersion, .ctx = ctx },
        .{ .name = "RegisteredStatusNotifierItems", .sig = "as", .access = .read, .get = propRegisteredItems, .ctx = ctx },
    });
    errdefer alloc.free(wt.properties);
    wt.signals = try alloc.dupe(object.VTable.Signal, &.{
        .{ .name = "StatusNotifierHostRegistered" },
        .{ .name = "StatusNotifierHostUnregistered" },
        .{ .name = "StatusNotifierItemRegistered" },
        .{ .name = "StatusNotifierItemUnregistered" },
    });
    errdefer alloc.free(wt.signals);
    wt.vtables = try alloc.dupe(object.VTable, &.{
        .{
            .interface = tray.watcher_iface,
            .methods = wt.methods,
            .properties = wt.properties,
            .signals = wt.signals,
        },
    });
    errdefer alloc.free(wt.vtables);
    return wt;
}

pub const Source = struct {
    alloc: std.mem.Allocator,
    conn: connection.Conn,
    tree: ?object.Tree = null,
    store: tray.Watcher,
    /// Set once the session bus answered `Hello`.
    live: bool = false,
    /// True when *we* own `org.kde.StatusNotifierWatcher`.
    hosting: bool = false,
    /// Set whenever `store` changed, so the dock knows to rebuild its strip.
    changed: bool = false,
    next_resync_ms: i64 = 0,
    /// Heap-owned watcher vtable (methods/properties/signals + the table
    /// itself). `Tree.addObject` keeps the slices it is handed, so the
    /// function-local literals the old code passed danced on freed stack
    /// frames after `adoptWatcher` returned — every inbound lookup then
    /// read garbage. These live as long as the source does.
    watcher_tables: ?WatcherTables = null,
    /// The watcher object is added to the tree at most once; re-adopting
    /// the name must not stack a second copy.
    watcher_object_added: bool = false,

    pub fn init(alloc: std.mem.Allocator) Source {
        return .{
            .alloc = alloc,
            .conn = connection.Conn.init(alloc),
            .store = tray.Watcher.init(alloc),
        };
    }

    pub fn deinit(self: *Source) void {
        if (self.tree) |*t| t.deinit();
        self.tree = null;
        if (self.watcher_tables) |*wt| {
            wt.deinit(self.alloc);
            self.watcher_tables = null;
        }
        self.watcher_object_added = false;
        self.store.deinit();
        self.conn.deinit();
        self.live = false;
    }

    // -----------------------------------------------------------------
    // Startup
    // -----------------------------------------------------------------

    /// Connects to the session bus and takes a first snapshot. Returns false
    /// when there is no bus — the dock then simply has no tray section.
    pub fn start(self: *Source) bool {
        if (self.live) return true;
        const t0 = sock.nowMs();
        const env_ptr = libc.getenv("DBUS_SESSION_BUS_ADDRESS");
        const c_env: ?[]const u8 = if (env_ptr) |p| std.mem.span(p) else null;
        const addr = connection.addressFor(.session, c_env, null) orelse return false;
        self.conn.connect(addr) catch |e| {
            logz.err("tray: connect failed: {}", .{e});
            return false;
        };
        self.conn.hello() catch |e| {
            logz.err("tray: hello failed: {}", .{e});
            return false;
        };
        const t_bus = sock.nowMs();
        self.tree = object.Tree.init(self.alloc, &self.conn);

        const rules = [_][]const u8{
            "type='signal',interface='org.kde.StatusNotifierWatcher'",
            "type='signal',interface='org.kde.StatusNotifierItem'",
            "type='signal',interface='org.freedesktop.DBus.Properties',arg0='org.kde.StatusNotifierItem'",
            "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'",
        };
        for (rules) |r| self.conn.addMatch(r, 2000) catch {};
        const t_match = sock.nowMs();

        self.live = true;
        self.hosting = self.adoptWatcher();
        const t_adopt = sock.nowMs();
        if (self.hosting) {
            logz.log("tray: hosting {s}", .{tray.watcher_bus});
        } else {
            self.syncItems();
            logz.log("tray: mirroring {s}, {d} item(s)", .{ tray.watcher_bus, self.store.items.items.len });
        }
        const t_sync = sock.nowMs();
        // Existing-item discovery runs at startup in
        // both modes: items that never registered with any watcher (crashed
        // hosts, path-only registrations) are found by probing every bus
        // name for an `Id` at `/StatusNotifierItem`.
        self.discoverItems();
        self.next_resync_ms = sock.nowMs() + k_resync_ms;
        self.changed = false;
        logz.log(
            "tray: phases bus={d}ms match={d}ms adopt={d}ms sync={d}ms discover={d}ms",
            .{ t_bus - t0, t_match - t_bus, t_adopt - t_match, t_sync - t_adopt, sock.nowMs() - t_sync },
        );
        return true;
    }

    /// Claims the watcher name when it is free. Failure is not an error: it
    /// just means somebody else is already hosting.
    fn adoptWatcher(self: *Source) bool {
        const rc = self.conn.requestName(tray.watcher_bus, 1500) catch |e| {
            logz.err("tray: requestName failed: {}", .{e});
            return false;
        };
        for (k_name_owned) |want| {
            if (rc == want) break;
        } else return false;
        if (self.tree == null) return false;
        const t = &self.tree.?;
        if (!self.watcher_object_added) {
            var wt = buildWatcherTables(self.alloc, self) catch return false;
            errdefer wt.deinit(self.alloc);
            t.addObject(tray.watcher_path, wt.vtables) catch {
                wt.deinit(self.alloc);
                return false;
            };
            self.watcher_tables = wt;
            self.watcher_object_added = true;
        }

        t.emitSignal(tray.watcher_path, tray.watcher_iface, "StatusNotifierHostRegistered", "", &.{}) catch {};
        return true;
    }

    // -----------------------------------------------------------------
    // The event loop side
    // -----------------------------------------------------------------

    /// Drains the bus and returns true when the item set (or an item's
    /// appearance) changed, so the dock can rebuild. Called both from the
    /// connection's readable callback and once a second as a safety net.
    pub fn pump(self: *Source, now_ms: i64) bool {
        if (!self.live) return false;
        while (true) {
            const got = self.conn.recvNow() catch |e| {
                logz.err("tray: bus read failed: {}", .{e});
                self.live = false;
                break;
            };
            var msg = got orelse break;
            defer msg.deinit();
            self.handle(&msg);
            if (!self.live) break;
        }
        if (!self.live) return false;
        if (now_ms >= self.next_resync_ms) {
            self.next_resync_ms = now_ms + k_resync_ms;
            if (!self.hosting) self.syncItems();
        }
        const ch = self.changed;
        self.changed = false;
        return ch;
    }

    fn handle(self: *Source, p: *wire.Parsed) void {
        const m = p.msg;
        // Inbound method calls addressed to our watcher object (client
        // registrations, property reads, introspection) go to the object
        // tree, which answers them. Without this nothing we host ever gets
        // a reply — client registrations time out and their items never
        // appear. Registration handlers flag `changed` themselves when the
        // item set moves; anything else answered here needs no rebuild.
        if (m.mtype == .method_call) {
            if (self.tree) |*t| {
                _ = t.dispatch(m, p.body_vals) catch {};
            }
            return;
        }
        if (m.mtype != .signal) return;
        const iface = m.interface orelse return;
        const member = m.member orelse return;

        if (std.mem.eql(u8, iface, tray.watcher_iface)) {
            if (std.mem.eql(u8, member, "StatusNotifierItemRegistered")) {
                if (p.body_vals.len >= 2 and p.body_vals[0] == .string and p.body_vals[1] == .object_path) {
                    self.addItem(p.body_vals[0].string, p.body_vals[1].object_path);
                } else if (p.body_vals.len >= 2 and p.body_vals[0] == .string and p.body_vals[1] == .string) {
                    self.addItem(p.body_vals[0].string, p.body_vals[1].string);
                } else if (p.body_vals.len == 1 and p.body_vals[0] == .string) {
                    // The spec's `serviceAndPath` single-string form.
                    if (splitRegistration(p.body_vals[0].string)) |split| {
                        self.addItem(split.service, split.path);
                    }
                }
                return;
            }
            if (std.mem.eql(u8, member, "StatusNotifierItemUnregistered")) {
                if (p.body_vals.len == 1 and p.body_vals[0] == .string) {
                    if (splitRegistration(p.body_vals[0].string)) |split| {
                        if (self.store.unregisterItem(split.service, split.path)) self.changed = true;
                    }
                    return;
                }
                if (p.body_vals.len >= 2 and p.body_vals[0] == .string) {
                    const path = switch (p.body_vals[1]) {
                        .string => |v| v,
                        .object_path => |v| v,
                        else => return,
                    };
                    if (self.store.unregisterItem(p.body_vals[0].string, path)) self.changed = true;
                }
                return;
            }
            return;
        }

        if (std.mem.eql(u8, iface, "org.freedesktop.DBus")) {
            if (!std.mem.eql(u8, member, "NameOwnerChanged")) return;
            if (p.body_vals.len < 3) return;
            if (p.body_vals[0] != .string or p.body_vals[1] != .string or p.body_vals[2] != .string) return;
            if (p.body_vals[2].string.len > 0) return;
            // The name lost its owner: drop whatever was hanging off it.
            const name = p.body_vals[0].string;
            if (self.dropByName(name)) self.changed = true;
            if (std.mem.eql(u8, name, tray.watcher_bus) and self.hosting == false) {
                // The watcher went away; try to take over on the next resync.
                self.hosting = self.adoptWatcher();
            }
            return;
        }

        // Any update from a status-notifier item. Working out *which*
        // property moved saves nothing when there are a handful of items, so
        // every touched item is re-read.
        const sender = m.sender orelse return;
        self.refreshBySender(sender);
    }

    /// Re-reads every item whose service or resolved owner is `name`.
    fn refreshBySender(self: *Source, name: []const u8) void {
        var i: usize = 0;
        while (i < self.store.items.items.len) : (i += 1) {
            const it = &self.store.items.items[i];
            const hit = std.mem.eql(u8, it.owner, name) or std.mem.eql(u8, it.service, name);
            if (!hit) continue;
            if (self.refreshItem(it.service, it.path)) self.changed = true;
        }
    }

    /// Removes every item registered under `name` (well-known or unique).
    fn dropByName(self: *Source, name: []const u8) bool {
        if (name.len == 0) return false;
        var any = false;
        while (true) {
            var hit = false;
            for (self.store.items.items, 0..) |*it, i| {
                if (std.mem.eql(u8, it.service, name) or std.mem.eql(u8, it.owner, name)) {
                    // Free first: `orderedRemove` shifts the *next* entry
                    // over this slot, so the pointers have to be released
                    // while they are still ours.
                    self.freeItemFields(it);
                    _ = self.store.items.orderedRemove(i);
                    hit = true;
                    any = true;
                    break;
                }
            }
            if (!hit) break;
        }
        return any;
    }

    fn freeItemFields(self: *Source, it: *tray.Item) void {
        self.alloc.free(it.service);
        self.alloc.free(it.path);
        self.alloc.free(it.title);
        self.alloc.free(it.icon_name);
        self.alloc.free(it.id);
        self.alloc.free(it.owner);
    }

    // -----------------------------------------------------------------
    // Talking to the watcher and the items
    // -----------------------------------------------------------------

    /// Re-reads the watcher's registration list and reconciles it with the
    /// store. Only used in mirror mode — hosting keeps the list itself.
    fn syncItems(self: *Source) void {
        const list = self.getStringArray(tray.watcher_bus, tray.watcher_path, tray.watcher_iface, "RegisteredStatusNotifierItems") orelse return;
        defer {
            for (list) |s| self.alloc.free(s);
            self.alloc.free(list);
        }
        // Anything in the store that the watcher no longer lists goes away.
        var i: usize = 0;
        while (i < self.store.items.items.len) {
            const it = &self.store.items.items[i];
            var listed = false;
            for (list) |raw| {
                const split = splitRegistration(raw) orelse continue;
                if (std.mem.eql(u8, split.service, it.service) and std.mem.eql(u8, split.path, it.path)) {
                    listed = true;
                    break;
                }
            }
            if (listed) {
                i += 1;
                continue;
            }
            self.freeItemFields(it);
            _ = self.store.items.orderedRemove(i);
            self.changed = true;
        }
        for (list) |raw| {
            const split = splitRegistration(raw) orelse continue;
            self.addItem(split.service, split.path);
        }
    }

    /// Adds `service`/`path` if it is new and reads its properties.
    fn addItem(self: *Source, service: []const u8, path: []const u8) void {
        const known = self.store.indexOf(service, path) != null;
        if (!known) {
            self.store.registerItem(service, path) catch return;
            self.setOwnerOwned(service, path);
            self.changed = true;
        }
        if (self.refreshItem(service, path)) self.changed = true;
    }

    /// One `GetAll` round trip for an item; returns true when anything the
    /// dock paints moved. Items whose `GetAll` misbehaves fall back to
    /// per-property `Get` reads — each property reads independently and tolerates individual
    /// failures, so an item that only answers `Get` still resolves fully.
    fn refreshItem(self: *Source, service: []const u8, path: []const u8) bool {
        if (service.len == 0) return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = aa.alloc(wire.Value, 1) catch return false;
        body[0] = .{ .string = tray.item_iface };
        if (self.conn.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = "org.freedesktop.DBus.Properties",
            .member = "GetAll",
            .destination = service,
            .signature = "s",
            .body = body,
        }, k_call_timeout_ms)) |p| {
            var reply = p;
            defer reply.deinit();
            if (parseGetAll(reply.body_vals)) |got| {
                return self.applyGetAll(service, path, got);
            }
        } else |_| {}
        return self.refreshItemViaGet(service, path);
    }

    /// Shared tail of both property paths: applies text fields plus the
    /// pixmap preference (preferring the shipped pixmap —
    /// Chromium and most libappindicator clients ship no `IconName` at all —
    /// falling back to the attention pixmap only when there is neither a
    /// primary pixmap nor a theme name).
    fn applyGetAll(self: *Source, service: []const u8, path: []const u8, got: ItemProps) bool {
        if (self.store.indexOf(service, path) == null) return false;
        var changed = self.store.applyProps(service, path, .{
            .id = got.id,
            .title = got.title,
            .status = got.status,
            .icon = got.icon,
            .icon_theme_path = got.icon_theme_path,
        });

        var conv = if (got.pixmap) |pv| convertPixmap(self.alloc, pv) else null;
        if (conv == null and (got.icon == null or got.icon.?.len == 0)) {
            conv = if (got.attention_pixmap) |pv| convertPixmap(self.alloc, pv) else null;
        }
        if (conv) |c| {
            defer self.alloc.free(c.pixels);
            if (self.store.setPixmap(service, path, c.pixels, c.w, c.h)) changed = true;
        }
        return changed;
    }

    /// One `Properties.Get` round trip for a single property. The caller owns
    /// the reply and must `deinit` it; values alias it.
    fn callGet(self: *Source, service: []const u8, path: []const u8, prop: []const u8) ?wire.Parsed {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = aa.alloc(wire.Value, 2) catch return null;
        body[0] = .{ .string = tray.item_iface };
        body[1] = .{ .string = prop };
        return self.conn.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = "org.freedesktop.DBus.Properties",
            .member = "Get",
            .destination = service,
            .signature = "ss",
            .body = body,
        }, k_call_timeout_ms) catch null;
    }

    /// The bare value inside a `Get` reply's variant, or null.
    fn getReplyValue(p: *const wire.Parsed) ?wire.Value {
        if (p.body_vals.len < 1 or p.body_vals[0] != .variant) return null;
        return p.body_vals[0].variant.val.*;
    }

    fn propStr(v: wire.Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            .object_path => |s| s,
            else => null,
        };
    }

    /// Per-property re-read used when `GetAll` fails. Each reply is consumed
    /// (strings duped into the store, pixmaps converted) before it is
    /// released, so nothing aliases freed memory.
    fn refreshItemViaGet(self: *Source, service: []const u8, path: []const u8) bool {
        if (self.store.indexOf(service, path) == null) return false;
        var changed = false;
        const fields = [_]struct { key: []const u8, prop: []const u8 }{
            .{ .key = "id", .prop = "Id" },
            .{ .key = "title", .prop = "Title" },
            .{ .key = "status", .prop = "Status" },
            .{ .key = "icon", .prop = "IconName" },
            .{ .key = "icon_theme_path", .prop = "IconThemePath" },
        };
        for (fields) |f| {
            var p = self.callGet(service, path, f.prop) orelse continue;
            defer p.deinit();
            const v = getReplyValue(&p) orelse continue;
            const s = propStr(v) orelse continue;
            var props = tray.Watcher.Props{};
            if (std.mem.eql(u8, f.key, "id")) props.id = s;
            if (std.mem.eql(u8, f.key, "title")) props.title = s;
            if (std.mem.eql(u8, f.key, "status")) props.status = s;
            if (std.mem.eql(u8, f.key, "icon")) props.icon = s;
            if (std.mem.eql(u8, f.key, "icon_theme_path")) props.icon_theme_path = s;
            if (self.store.applyProps(service, path, props)) changed = true;
        }
        if (self.getPixmapViaGet(service, path, "IconPixmap")) |c| {
            defer self.alloc.free(c.pixels);
            if (self.store.setPixmap(service, path, c.pixels, c.w, c.h)) changed = true;
        }
        if (self.currentIconEmpty(service, path) and self.currentPixmapEmpty(service, path)) {
            if (self.getPixmapViaGet(service, path, "AttentionIconPixmap")) |c| {
                defer self.alloc.free(c.pixels);
                if (self.store.setPixmap(service, path, c.pixels, c.w, c.h)) changed = true;
            }
        }
        return changed;
    }

    /// Converts one pixmap property via `Get`; the pixels are freshly
    /// allocated, so the reply can go right away.
    fn getPixmapViaGet(self: *Source, service: []const u8, path: []const u8, prop: []const u8) ?Pixmap {
        var p = self.callGet(service, path, prop) orelse return null;
        defer p.deinit();
        const v = getReplyValue(&p) orelse return null;
        if (v != .array) return null;
        return convertPixmap(self.alloc, v);
    }

    /// Whether the item currently has no theme name (for the attention
    /// pixmap fallback rule).
    fn currentIconEmpty(self: *Source, service: []const u8, path: []const u8) bool {
        const i = self.store.indexOf(service, path) orelse return true;
        return self.store.items.items[i].icon_name.len == 0;
    }

    /// Whether the item currently holds no pixmap bytes.
    fn currentPixmapEmpty(self: *Source, service: []const u8, path: []const u8) bool {
        const i = self.store.indexOf(service, path) orelse return true;
        return self.store.items.items[i].pixels.len == 0;
    }

    /// Resolves `service` and stores the result without leaking it: the
    /// store copies whatever it is handed.
    fn setOwnerOwned(self: *Source, service: []const u8, path: []const u8) void {
        const own = self.ownerOf(service) orelse return;
        defer self.alloc.free(own);
        self.store.setOwner(service, path, own);
    }

    /// `discover_existing_items`: `ListNames` plus one `Id` probe per bus
    /// name at `/StatusNotifierItem`. Skips the watcher and daemon names
    /// and anything already registered. Probes go out
    /// in one pipelined burst and share a single reply budget: the names
    /// that never answer all expire together instead of each eating a full
    /// timeout in turn, which is what used to stall startup for seconds.
    fn discoverItems(self: *Source) void {
        const names = self.listNames() orelse return;
        defer {
            for (names) |s| self.alloc.free(s);
            self.alloc.free(names);
        }
        const Probe = struct { service: []const u8, path: []const u8, serial: u32, done: bool = false };
        var probes: std.ArrayList(Probe) = .empty;
        defer probes.deinit(self.alloc);
        // The conventional path plus the Chromium/Electron family, which
        // hangs its items under `/org/chromium/StatusNotifierItem/N`
        // (seen live on this bus).
        const paths = [_][]const u8{
            "/StatusNotifierItem",
            "/org/chromium/StatusNotifierItem/1",
            "/org/chromium/StatusNotifierItem/2",
            "/org/chromium/StatusNotifierItem/3",
        };
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        for (names) |name| {
            if (std.mem.startsWith(u8, name, "org.kde.StatusNotifier")) continue;
            if (std.mem.startsWith(u8, name, "org.freedesktop.")) continue;
            if (!std.mem.startsWith(u8, name, ":")) {
                // A well-known name with no owner would auto-activate its
                // service on first contact — dozens of background apps woken
                // at every boot. The daemon answers ownership itself, with
                // no activation.
                if (!self.nameHasOwner(name)) continue;
            }
            for (paths) |path| {
                if (self.store.indexOf(name, path) != null) continue;
                const aa = arena.allocator();
                const body = aa.alloc(wire.Value, 2) catch continue;
                body[0] = .{ .string = tray.item_iface };
                body[1] = .{ .string = "Id" };
                const serial = self.conn.sendMessage(.{
                    .mtype = .method_call,
                    .path = path,
                    .interface = "org.freedesktop.DBus.Properties",
                    .member = "Get",
                    .destination = name,
                    .signature = "ss",
                    .body = body,
                }) catch continue;
                probes.append(self.alloc, .{ .service = name, .path = path, .serial = serial }) catch continue;
            }
        }
        var pending = probes.items.len;
        var found: usize = 0;
        const deadline = sock.nowMs() + k_discover_budget_ms;
        while (pending > 0) {
            const remaining = deadline - sock.nowMs();
            if (remaining <= 0) break;
            var p = self.conn.recvMessage(remaining) catch break;
            const rs = p.msg.reply_serial orelse {
                p.deinit();
                continue;
            };
            var hit: ?usize = null;
            for (probes.items, 0..) |pr, i| {
                if (!pr.done and pr.serial == rs) {
                    hit = i;
                    break;
                }
            }
            if (hit) |i| {
                probes.items[i].done = true;
                pending -= 1;
                if (p.msg.mtype == .method_return) {
                    const v = getReplyValue(&p) orelse {
                        p.deinit();
                        continue;
                    };
                    const id = propStr(v) orelse {
                        p.deinit();
                        continue;
                    };
                    // Answered with a real id: a full read follows, against
                    // a service that just proved it responds.
                    if (id.len > 0) {
                        self.addItem(probes.items[i].service, probes.items[i].path);
                        found += 1;
                    }
                }
                p.deinit();
            } else {
                p.deinit();
            }
        }
        if (found > 0) logz.log("tray: discover found {d} unregistered item(s)", .{found});
    }

    /// `org.freedesktop.DBus.GetNameOwner`: answered by the daemon itself,
    /// so it never activates the service the way a direct probe would.
    fn nameHasOwner(self: *Source, name: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = aa.alloc(wire.Value, 1) catch return false;
        body[0] = .{ .string = name };
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "GetNameOwner",
            .destination = "org.freedesktop.DBus",
            .signature = "s",
            .body = body,
        }, k_probe_timeout_ms) catch return false;
        defer p.deinit();
        return true;
    }

    /// `org.freedesktop.DBus.ListNames` — owned result, or null. Unlike the
    /// watcher property (a variant-wrapped array), this reply is a bare
    /// array of strings.
    fn listNames(self: *Source) ?[][]const u8 {
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "ListNames",
            .destination = "org.freedesktop.DBus",
            .signature = "",
            .body = &.{},
        }, k_call_timeout_ms) catch return null;
        defer p.deinit();
        if (p.body_vals.len < 1 or p.body_vals[0] != .array) return null;
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| self.alloc.free(s);
            out.deinit(self.alloc);
        }
        for (p.body_vals[0].array.items) |it| {
            const s = switch (it) {
                .string => |v| v,
                else => continue,
            };
            const copy = self.alloc.dupe(u8, s) catch continue;
            out.append(self.alloc, copy) catch {
                self.alloc.free(copy);
                break;
            };
        }
        return out.toOwnedSlice(self.alloc) catch null;
    }

    /// `org.freedesktop.DBus.GetNameOwner` — needed so item signals, which
    /// carry the unique name, can be matched against a well-known service.
    fn ownerOf(self: *Source, service: []const u8) ?[]u8 {
        if (std.mem.startsWith(u8, service, ":")) return self.alloc.dupe(u8, service) catch null;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = aa.alloc(wire.Value, 1) catch return null;
        body[0] = .{ .string = service };
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "GetNameOwner",
            .destination = "org.freedesktop.DBus",
            .signature = "s",
            .body = body,
        }, k_call_timeout_ms) catch return null;
        defer p.deinit();
        if (p.body_vals.len < 1 or p.body_vals[0] != .string) return null;
        return self.alloc.dupe(u8, p.body_vals[0].string) catch null;
    }

    /// `Properties.Get` for a string-array property. Owned result, or null.
    fn getStringArray(
        self: *Source,
        dest: []const u8,
        path: []const u8,
        iface: []const u8,
        prop: []const u8,
    ) ?[][]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = aa.alloc(wire.Value, 2) catch return null;
        body[0] = .{ .string = iface };
        body[1] = .{ .string = prop };
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = "org.freedesktop.DBus.Properties",
            .member = "Get",
            .destination = dest,
            .signature = "ss",
            .body = body,
        }, k_call_timeout_ms) catch return null;
        defer p.deinit();
        if (p.body_vals.len < 1 or p.body_vals[0] != .variant) return null;
        const inner = p.body_vals[0].variant.val.*;
        if (inner != .array) return null;
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| self.alloc.free(s);
            out.deinit(self.alloc);
        }
        for (inner.array.items) |it| {
            const s = switch (it) {
                .string => |v| v,
                .object_path => |v| v,
                else => continue,
            };
            const copy = self.alloc.dupe(u8, s) catch continue;
            out.append(self.alloc, copy) catch {
                self.alloc.free(copy);
                break;
            };
        }
        return out.toOwnedSlice(self.alloc) catch null;
    }

    // -----------------------------------------------------------------
    // Host side (`org.kde.StatusNotifierWatcher`)
    // -----------------------------------------------------------------

    fn handleRegistration(self: *Source, arg: []const u8) void {
        if (arg.len == 0) return;
        var service: []const u8 = arg;
        var path: []const u8 = "/StatusNotifierItem";
        if (arg[0] == '/') {
            // The client passed an object path, so the bus name is the
            // caller's — `Tree.last_sender` is what `dispatch` recorded.
            if (self.tree == null) return;
            service = self.tree.?.last_sender;
            path = arg;
            if (service.len == 0) return;
        }
        const existed = self.store.indexOf(service, path) != null;
        if (!existed) {
            self.store.registerItem(service, path) catch return;
            self.changed = true;
        }
        self.setOwnerOwned(service, path);
        if (self.refreshItem(service, path)) self.changed = true;
        if (existed) return;
        if (self.tree == null) return;
        const t = &self.tree.?;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = aa.alloc(wire.Value, 2) catch return;
        body[0] = .{ .string = service };
        body[1] = .{ .object_path = path };
        t.emitSignal(tray.watcher_path, tray.watcher_iface, "StatusNotifierItemRegistered", "so", body) catch {};
    }

    // -----------------------------------------------------------------
    // Public read API for the dock
    // -----------------------------------------------------------------

    /// Owned slot keys in registration order. The strip borrows these.
    pub fn keys(self: *Source, alloc: std.mem.Allocator) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| alloc.free(s);
            out.deinit(alloc);
        }
        for (self.store.items.items) |it| {
            const k = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ slot_key, it.service, it.path });
            try out.append(alloc, k);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Items currently held, for callers that only need the count (the first
    /// frame goes out before the tray has even connected).
    pub fn itemCount(self: *const Source) usize {
        return self.store.items.items.len;
    }

    pub fn itemForKey(self: *Source, key: []const u8) ?*tray.Item {
        if (!std.mem.startsWith(u8, key, slot_key)) return null;
        const rest = key[slot_key.len..];
        for (self.store.items.items) |*it| {
            if (rest.len < it.path.len) continue;
            const head_len = rest.len - it.path.len;
            if (!std.mem.eql(u8, rest[head_len..], it.path)) continue;
            if (std.mem.eql(u8, rest[0..head_len], it.service)) return it;
        }
        return null;
    }

    /// `org.kde.StatusNotifierItem.Activate(x, y)` — what a click on a tray
    /// icon means. `x`/`y` are surface coordinates, which is what the
    /// protocol asks for.
    pub fn activate(self: *Source, key: []const u8, x: i32, y: i32) void {
        const it = self.itemForKey(key) orelse return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = aa.alloc(wire.Value, 2) catch return;
        body[0] = .{ .int32 = x };
        body[1] = .{ .int32 = y };
        _ = self.conn.call(.{
            .mtype = .method_call,
            .path = it.path,
            .interface = tray.item_iface,
            .member = "Activate",
            .destination = it.service,
            .signature = "ii",
            .body = body,
        }, 800) catch {};
    }
};

/// The text and image half of one status-notifier property dump. Every pointer
/// aliases the reply's arena, so a caller copies what it keeps before letting
/// the message go.
const ItemProps = struct {
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    status: ?[]const u8 = null,
    icon_theme_path: ?[]const u8 = null,
    pixmap: ?wire.Value = null,
    attention_pixmap: ?wire.Value = null,
};

/// Reads the body of an `org.freedesktop.DBus.Properties.GetAll` reply.
///
/// The reply's shape is the whole point: `Properties.Get` answers a `v`, so
/// reading *that* as a variant works, while `GetAll` hands back a bare `a{sv}`.
/// Demanding a variant here yields nothing at all — no title, no icon name,
/// no pixmap — which is how the tray slots first came up empty.
fn parseGetAll(vals: []const wire.Value) ?ItemProps {
    if (vals.len < 1) return null;
    const entries: wire.Value.Array = switch (vals[0]) {
        .array => |a| a,
        .variant => |v| if (v.val.* == .array) v.val.*.array else return null,
        else => return null,
    };

    var got = ItemProps{};
    for (entries.items) |it| {
        if (it != .structure or it.structure.len != 2) continue;
        if (it.structure[0] != .string) continue;
        const key = it.structure[0].string;
        const v = it.structure[1];
        if (v != .variant) continue;
        const val = v.variant.val.*;
        if (std.mem.eql(u8, key, "IconPixmap")) {
            got.pixmap = val;
            continue;
        }
        if (std.mem.eql(u8, key, "AttentionIconPixmap")) {
            got.attention_pixmap = val;
            continue;
        }
        const str = switch (val) {
            .string => |s| s,
            .object_path => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, key, "Id")) got.id = str;
        if (std.mem.eql(u8, key, "Title")) got.title = str;
        if (std.mem.eql(u8, key, "IconName")) got.icon = str;
        if (std.mem.eql(u8, key, "IconThemePath")) got.icon_theme_path = str;
        if (std.mem.eql(u8, key, "Status")) got.status = str;
    }
    return got;
}

/// Tray icon limits: never bigger than
/// the dock's own art, and a hostile or careless client must not be able to
/// make us allocate megabytes per item.
const k_max_pixmap_side_px = 128;
const k_max_pixmap_pixels: i64 = 128 * 128;

const Pixmap = struct {
    /// Premultiplied `CAIRO_FORMAT_ARGB32` in host byte order, tightly packed.
    pixels: []u8,
    w: i32,
    h: i32,
};

/// Turns an `a(iiay)` status-notifier pixmap into what cairo wants.
///
/// The protocol sends ARGB in *network* byte order — `A,R,G,B` per pixel,
/// straight alpha — while a little-endian `CAIRO_FORMAT_ARGB32` surface is
/// stored `B,G,R,A` premultiplied, including the `+127` rounding.
/// conversion, including the `+127` rounding. Returns null for anything that
/// is not a well-formed pixmap.
fn convertPixmap(alloc: std.mem.Allocator, v: wire.Value) ?Pixmap {
    if (v != .array) return null;
    var best: ?Pixmap = null;

    for (v.array.items) |entry| {
        if (entry != .structure or entry.structure.len < 3) continue;
        if (entry.structure[0] != .int32 or entry.structure[1] != .int32) continue;
        if (entry.structure[2] != .array) continue;
        const w = entry.structure[0].int32;
        const h = entry.structure[1].int32;
        if (w <= 0 or h <= 0) continue;
        if (w > k_max_pixmap_side_px or h > k_max_pixmap_side_px) continue;
        const area: i64 = @as(i64, w) * @as(i64, h);
        if (area > k_max_pixmap_pixels) continue;
        const raw = entry.structure[2].array;
        const need: usize = @intCast(area * 4);
        // Only short buffers are rejected — padded (longer)
        // ones are accepted and the surplus ignored, so this is `<`, not
        // `!=`. Vesktop-class clients have been seen padding rows.
        if (raw.items.len < need) continue;
        if (best) |b| {
            // Largest usable wins, matching `better_tray_pixmap`.
            const have: i64 = @as(i64, b.w) * @as(i64, b.h);
            if (have >= area) continue;
        }

        const out = alloc.alloc(u8, need) catch continue;
        var i: usize = 0;
        var ok = true;
        while (i + 4 <= need) : (i += 4) {
            const ba = pixByte(raw.items[i]);
            const br = pixByte(raw.items[i + 1]);
            const bg = pixByte(raw.items[i + 2]);
            const bb = pixByte(raw.items[i + 3]);
            if (ba == null or br == null or bg == null or bb == null) {
                ok = false;
                break;
            }
            const pr: u8 = @intCast((@as(u32, br.?) * ba.? + 127) / 255);
            const pg: u8 = @intCast((@as(u32, bg.?) * ba.? + 127) / 255);
            const pb: u8 = @intCast((@as(u32, bb.?) * ba.? + 127) / 255);
            out[i] = pb;
            out[i + 1] = pg;
            out[i + 2] = pr;
            out[i + 3] = ba.?;
        }
        if (!ok or i != need) {
            alloc.free(out);
            continue;
        }
        if (best) |old| alloc.free(old.pixels);
        best = .{ .pixels = out, .w = w, .h = h };
    }
    return best;
}

fn pixByte(v: wire.Value) ?u8 {
    return switch (v) {
        .byte => |b| b,
        else => null,
    };
}

/// `service/object_path` → both halves. The service never contains a slash,
/// so the first one starts the path; a bare service means the conventional
/// `/StatusNotifierItem`.
const Registration = struct { service: []const u8, path: []const u8 };

fn splitRegistration(raw: []const u8) ?Registration {
    const i = std.mem.indexOfScalar(u8, raw, '/') orelse {
        if (raw.len == 0) return null;
        return .{ .service = raw, .path = "/StatusNotifierItem" };
    };
    if (i == 0) return null;
    return .{ .service = raw[0..i], .path = raw[i..] };
}

// D-Bus callbacks (`object.zig` uses C-style handlers, so these are free
// functions whose `ctx` is the `Source`)

fn registerItemHandler(alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) object.MethodResult {
    const self: *Source = @ptrCast(@alignCast(ctx));
    if (args.len < 1 or args[0] != .string) {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.InvalidArgs", .message = "expected a service name or object path" } };
    }
    self.handleRegistration(args[0].string);
    _ = alloc;
    return .{ .ok = &.{} };
}

/// The `*Host` methods exist only so a client that registers defensively
/// does not see an unknown-method error; the Zig shell has no separate host
/// process to track.
fn registerHostHandler(alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) object.MethodResult {
    _ = alloc;
    _ = ctx;
    _ = args;
    return .{ .ok = &.{} };
}

fn propHostRegistered(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!wire.Value {
    _ = ctx;
    _ = alloc;
    return .{ .boolean = true };
}

fn propProtocolVersion(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!wire.Value {
    _ = ctx;
    _ = alloc;
    return .{ .int32 = 0 };
}

fn propRegisteredItems(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!wire.Value {
    const self: *Source = @ptrCast(@alignCast(ctx));
    const items = try alloc.alloc(wire.Value, self.store.items.items.len);
    for (self.store.items.items, 0..) |*it, i| {
        items[i] = .{ .string = try std.fmt.allocPrint(alloc, "{s}{s}", .{ it.service, it.path }) };
    }
    // `Tree.dispatchProperties` releases the value with `freeValue`, which
    // frees `elem` too — so it has to be heap memory, not a literal.
    return .{ .array = .{ .elem = try alloc.dupe(u8, "s"), .items = items } };
}

test "tray-source: registration strings split on the first slash" {
    const t = std.testing;
    const a = splitRegistration(":1.50/StatusNotifierItem").?;
    try t.expectEqualStrings(":1.50", a.service);
    try t.expectEqualStrings("/StatusNotifierItem", a.path);

    const b = splitRegistration("org.kde.StatusNotifierItem-12-1/org/foo/Bar").?;
    try t.expectEqualStrings("org.kde.StatusNotifierItem-12-1", b.service);
    try t.expectEqualStrings("/org/foo/Bar", b.path);

    // A bare service means the conventional path.
    const c = splitRegistration("org.example.Item").?;
    try t.expectEqualStrings("org.example.Item", c.service);
    try t.expectEqualStrings("/StatusNotifierItem", c.path);

    try t.expect(splitRegistration("/nothing/here") == null);
    try t.expect(splitRegistration("") == null);
}

test "tray-source: keys round-trip through itemForKey" {
    const t = std.testing;
    var s = Source.init(t.allocator);
    defer s.deinit();
    try s.store.registerItem(":1.42", "/StatusNotifierItem");
    try s.store.registerItem("org.example.Item", "/Item");
    s.store.updateFromProps(":1.42", "Mail", "Active", "mail-unread");

    const ks = try s.keys(t.allocator);
    defer {
        for (ks) |k| t.allocator.free(k);
        t.allocator.free(ks);
    }
    try t.expectEqual(@as(usize, 2), ks.len);
    try t.expectEqualStrings("__tray__:1.42/StatusNotifierItem", ks[0]);
    try t.expectEqualStrings("__tray__org.example.Item/Item", ks[1]);

    const it = s.itemForKey(ks[0]).?;
    try t.expectEqualStrings("Mail", it.title);
    try t.expectEqualStrings("mail-unread", it.icon_name);
    try t.expectEqual(tray.ItemStatus.active, it.status);
    try t.expect(s.itemForKey("__tray__nope") == null);
}

test "tray-source: store reconciliation frees what it removes" {
    const t = std.testing;
    var w = tray.Watcher.init(t.allocator);
    defer w.deinit();
    try w.registerItem(":1.7", "/StatusNotifierItem");
    w.setOwner(":1.7", "/StatusNotifierItem", ":1.7");
    try t.expect(w.applyProps(":1.7", "/StatusNotifierItem", .{
        .id = "id",
        .title = "Title",
        .status = "NeedsAttention",
        .icon = "icon",
    }));
    const it = w.findByOwner(":1.7").?;
    try t.expectEqualStrings("id", it.id);
    try t.expectEqualStrings("Title", it.title);
    try t.expectEqual(tray.ItemStatus.needs_attention, it.status);
    // Nothing moved on the second identical read.
    try t.expect(!w.applyProps(":1.7", "/StatusNotifierItem", .{
        .id = "id",
        .title = "Title",
        .status = "NeedsAttention",
        .icon = "icon",
    }));
    try t.expect(w.unregisterItem(":1.7", "/StatusNotifierItem"));
}

test "tray-source: GetAll answers a bare a{sv} while Get answers a v" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const pair = try aa.alloc(wire.Value, 2);
    pair[0] = .{ .string = "Title" };
    const slot = try aa.create(wire.Value);
    slot.* = .{ .string = "Mail" };
    pair[1] = .{ .variant = .{ .sig = "s", .val = slot } };

    const entries = try aa.alloc(wire.Value, 1);
    entries[0] = .{ .structure = pair };
    const dict = wire.Value{ .array = .{ .elem = "s", .items = entries } };

    // `GetAll` returns the dictionary itself. Reading it as a variant is what
    // emptied every tray slot, so this half of the test is the regression.
    const all_body = [_]wire.Value{dict};
    const got_all = parseGetAll(&all_body).?;
    try t.expectEqualStrings("Mail", got_all.title.?);
    try t.expect(got_all.icon == null);

    // `Get` wraps the same dictionary in a variant; both shapes are legal.
    const box = try aa.create(wire.Value);
    box.* = dict;
    const get_body = [_]wire.Value{.{ .variant = .{ .sig = "a{sv}", .val = box } }};
    const got_one = parseGetAll(&get_body).?;
    try t.expectEqualStrings("Mail", got_one.title.?);

    try t.expect(parseGetAll(&.{}) == null);
    const nonsense = [_]wire.Value{.{ .string = "nope" }};
    try t.expect(parseGetAll(&nonsense) == null);
}

test "tray-source: pixmap converts network ARGB into premultiplied cairo ARGB32" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // 1x1, opaque: A=0xFF, R=0x11, G=0x22, B=0x33 in network order.
    const px = try aa.alloc(wire.Value, 4);
    px[0] = .{ .byte = 0xFF };
    px[1] = .{ .byte = 0x11 };
    px[2] = .{ .byte = 0x22 };
    px[3] = .{ .byte = 0x33 };
    const entry = [_]wire.Value{
        .{ .int32 = 1 },
        .{ .int32 = 1 },
        .{ .array = .{ .elem = "ay", .items = px } },
    };
    const items = try aa.alloc(wire.Value, 1);
    items[0] = .{ .structure = try aa.dupe(wire.Value, &entry) };

    const got = convertPixmap(t.allocator, .{ .array = .{ .elem = "a(iiay)", .items = items } }).?;
    defer t.allocator.free(got.pixels);
    try t.expectEqual(@as(i32, 1), got.w);
    try t.expectEqual(@as(i32, 1), got.h);
    try t.expectEqualSlices(u8, &[_]u8{ 0x33, 0x22, 0x11, 0xFF }, got.pixels);
}

test "tray-source: pixmap conversion rejects the documented blocklist" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Oversized, degenerate and short: none of these may become an image.
    const cases = [_]struct { w: i32, h: i32, bytes: usize }{
        .{ .w = 129, .h = 4, .bytes = 129 * 4 * 4 },
        .{ .w = 0, .h = 4, .bytes = 16 },
        .{ .w = 4, .h = 4, .bytes = 7 },
    };
    for (cases) |c| {
        const px = try aa.alloc(wire.Value, c.bytes);
        for (px) |*b| b.* = .{ .byte = 0xFF };
        const entry = [_]wire.Value{
            .{ .int32 = c.w },
            .{ .int32 = c.h },
            .{ .array = .{ .elem = "ay", .items = px } },
        };
        const items = try aa.alloc(wire.Value, 1);
        items[0] = .{ .structure = try aa.dupe(wire.Value, &entry) };
        try t.expect(convertPixmap(t.allocator, .{ .array = .{ .elem = "a(iiay)", .items = items } }) == null);
    }
    try t.expect(convertPixmap(t.allocator, .{ .string = "not a pixmap" }) == null);
}

test "tray-source: pixmap conversion accepts padded buffers" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // 1x1 needs 4 bytes; this client pads rows to 8. Only short buffers
    // are rejected, so the surplus must be ignored.
    const px = try aa.alloc(wire.Value, 8);
    px[0] = .{ .byte = 0xFF };
    px[1] = .{ .byte = 0x11 };
    px[2] = .{ .byte = 0x22 };
    px[3] = .{ .byte = 0x33 };
    px[4] = .{ .byte = 0x00 };
    px[5] = .{ .byte = 0x00 };
    px[6] = .{ .byte = 0x00 };
    px[7] = .{ .byte = 0x00 };
    const entry = [_]wire.Value{
        .{ .int32 = 1 },
        .{ .int32 = 1 },
        .{ .array = .{ .elem = "ay", .items = px } },
    };
    const items = try aa.alloc(wire.Value, 1);
    items[0] = .{ .structure = try aa.dupe(wire.Value, &entry) };

    const got = convertPixmap(t.allocator, .{ .array = .{ .elem = "a(iiay)", .items = items } }).?;
    defer t.allocator.free(got.pixels);
    try t.expectEqual(@as(i32, 1), got.w);
    try t.expectEqual(@as(i32, 1), got.h);
    try t.expectEqualSlices(u8, &[_]u8{ 0x33, 0x22, 0x11, 0xFF }, got.pixels);
}

test "tray-source: watcher tables outlive their builder" {
    const t = std.testing;
    var ctx: u8 = 0;
    // Built in a nested scope and used after it returns: this is exactly
    // the use-after-scope the old function-local literals had, and it must
    // stay valid because the tables own their arrays.
    var wt: ?WatcherTables = null;
    {
        wt = try buildWatcherTables(t.allocator, &ctx);
    }
    defer wt.?.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), wt.?.vtables.len);
    try t.expectEqualStrings(tray.watcher_iface, wt.?.vtables[0].interface);
    try t.expectEqual(@as(usize, 4), wt.?.methods.len);
    try t.expectEqualStrings("RegisterStatusNotifierItem", wt.?.methods[0].name);
    try t.expectEqual(@as(usize, 3), wt.?.properties.len);
    try t.expectEqualStrings("ProtocolVersion", wt.?.properties[1].name);
    try t.expectEqualStrings("as", wt.?.properties[2].sig);
    try t.expectEqual(@as(usize, 4), wt.?.signals.len);
    try t.expectEqualStrings("StatusNotifierItemRegistered", wt.?.signals[2].name);
}

test "tray-source: setPixmap keeps the largest art it was given" {
    const t = std.testing;
    var w = tray.Watcher.init(t.allocator);
    defer w.deinit();
    try w.registerItem(":1.9", "/StatusNotifierItem");

    const big = [_]u8{ 1, 2, 3, 4 };
    try t.expect(w.setPixmap(":1.9", "/StatusNotifierItem", &big, 1, 1));
    // Identical bytes are not a change.
    try t.expect(!w.setPixmap(":1.9", "/StatusNotifierItem", &big, 1, 1));
    // A degenerate answer must not wipe good art.
    try t.expect(!w.setPixmap(":1.9", "/StatusNotifierItem", &.{}, 0, 0));
    const newer = [_]u8{ 9, 9, 9, 9, 8, 8, 8, 8 };
    try t.expect(w.setPixmap(":1.9", "/StatusNotifierItem", &newer, 2, 1));

    const it = w.items.items[0];
    try t.expectEqualSlices(u8, &newer, it.pixels);
    try t.expectEqual(@as(i32, 2), it.pw);
    // The watcher owns a copy, not the caller's buffer.
    const caller: []const u8 = &newer;
    try t.expect(it.pixels.ptr != caller.ptr);
}
