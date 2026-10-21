const std = @import("std");
const wire = @import("../dbus/wire.zig");

pub const watcher_bus = "org.kde.StatusNotifierWatcher";
pub const watcher_path = "/StatusNotifierWatcher";
pub const watcher_iface = "org.kde.StatusNotifierWatcher";
pub const item_iface = "org.kde.StatusNotifierItem";

pub const ItemStatus = enum { passive, active, needs_attention };

pub fn parseStatus(s: []const u8) ItemStatus {
    if (std.mem.eql(u8, s, "Active")) return .active;
    if (std.mem.eql(u8, s, "NeedsAttention")) return .needs_attention;
    return .passive;
}

pub const Item = struct {
    service: []const u8 = "",
    path: []const u8 = "",
    title: []const u8 = "",
    status: ItemStatus = .passive,
    icon_name: []const u8 = "",
    /// `IconThemePath` — a directory the client ships its icons in (Steam is
    /// the usual offender). Appended to the theme search path on resolve.
    icon_theme_path: []const u8 = "",
    /// `IconPixmap`/`AttentionIconPixmap` already converted to cairo's
    /// premultiplied `CAIRO_FORMAT_ARGB32`. Empty when the client only
    /// advertised a themed name.
    pixels: []u8 = &.{},
    pw: i32 = 0,
    ph: i32 = 0,
    /// `Id` — the client's stable identifier, used by the env
    /// filter. Empty until the first successful `GetAll`.
    id: []const u8 = "",
    /// Unique bus name the service currently resolves to, so a signal's
    /// `sender` field can be matched even when `service` is well-known.
    owner: []const u8 = "",
};

pub const Watcher = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(Item),
    host_registered: bool = false,

    pub fn init(alloc: std.mem.Allocator) Watcher {
        return .{ .alloc = alloc, .items = .empty };
    }

    pub fn deinit(self: *Watcher) void {
        for (self.items.items) |*it| {
            self.freeFields(it);
        }
        self.items.deinit(self.alloc);
    }

    /// Releases every owned field of one entry without touching the list —
    /// the caller removes it right after, and doing it in the other order
    /// would free pointers that `orderedRemove` has already shuffled away.
    pub fn freeFields(self: *Watcher, it: *Item) void {
        self.alloc.free(it.service);
        self.alloc.free(it.path);
        self.alloc.free(it.title);
        self.alloc.free(it.icon_name);
        self.alloc.free(it.icon_theme_path);
        if (it.pixels.len > 0) self.alloc.free(it.pixels);
        self.alloc.free(it.id);
        self.alloc.free(it.owner);
    }

    pub fn indexOf(self: *Watcher, service: []const u8, path: []const u8) ?usize {
        for (self.items.items, 0..) |*it, i| {
            if (std.mem.eql(u8, it.service, service) and std.mem.eql(u8, it.path, path)) return i;
        }
        return null;
    }

    pub fn registerItem(self: *Watcher, service: []const u8, path: []const u8) !void {
        if (self.indexOf(service, path) != null) return;
        // `id` and `owner` start out as *allocated* empties, not the struct
        // default literal: `deinit`/`unregisterItem` free them unconditionally
        // and freeing a static `""` would trip the allocator.
        const svc = try self.alloc.dupe(u8, service);
        errdefer self.alloc.free(svc);
        const pth = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(pth);
        const ttl = try self.alloc.dupe(u8, "");
        errdefer self.alloc.free(ttl);
        const ico = try self.alloc.dupe(u8, "");
        errdefer self.alloc.free(ico);
        const thp = try self.alloc.dupe(u8, "");
        errdefer self.alloc.free(thp);
        const iid = try self.alloc.dupe(u8, "");
        errdefer self.alloc.free(iid);
        const own = try self.alloc.dupe(u8, "");
        errdefer self.alloc.free(own);
        try self.items.append(self.alloc, .{
            .service = svc,
            .path = pth,
            .title = ttl,
            .icon_name = ico,
            .icon_theme_path = thp,
            .id = iid,
            .owner = own,
        });
    }

    pub fn unregisterItem(self: *Watcher, service: []const u8, path: []const u8) bool {
        const i = self.indexOf(service, path) orelse return false;
        const it = &self.items.items[i];
        self.freeFields(it);
        _ = self.items.orderedRemove(i);
        return true;
    }

    pub fn updateFromProps(self: *Watcher, service: []const u8, title: ?[]const u8, status: ?[]const u8, icon: ?[]const u8) void {
        for (self.items.items) |*it| {
            if (!std.mem.eql(u8, it.service, service)) continue;
            // Dup first, free second: a failed dupe must not leave the field
            // pointing at a static literal that `deinit` would then free.
            if (title) |v| {
                if (self.alloc.dupe(u8, v)) |fresh| {
                    self.alloc.free(it.title);
                    it.title = fresh;
                } else |_| {}
            }
            if (status) |v| it.status = parseStatus(v);
            if (icon) |v| {
                if (self.alloc.dupe(u8, v)) |fresh| {
                    self.alloc.free(it.icon_name);
                    it.icon_name = fresh;
                } else |_| {}
            }
        }
    }

    /// The text half of one item's `GetAll` answer. Matching is by
    /// `(service, path)` so two items sharing a bus name do not overwrite each
    /// other. Every field is optional: a client may not expose one at all.
    pub const Props = struct {
        id: ?[]const u8 = null,
        title: ?[]const u8 = null,
        status: ?[]const u8 = null,
        icon: ?[]const u8 = null,
        icon_theme_path: ?[]const u8 = null,
    };

    pub fn applyProps(self: *Watcher, service: []const u8, path: []const u8, p: Props) bool {
        const i = self.indexOf(service, path) orelse return false;
        const it = &self.items.items[i];
        var changed = false;
        if (p.title) |v| {
            if (!std.mem.eql(u8, it.title, v)) {
                const fresh = self.alloc.dupe(u8, v) catch null;
                if (fresh) |f| {
                    self.alloc.free(it.title);
                    it.title = f;
                    changed = true;
                }
            }
        }
        if (p.icon) |v| {
            if (!std.mem.eql(u8, it.icon_name, v)) {
                const fresh = self.alloc.dupe(u8, v) catch null;
                if (fresh) |f| {
                    self.alloc.free(it.icon_name);
                    it.icon_name = f;
                    changed = true;
                }
            }
        }
        if (p.icon_theme_path) |v| {
            if (!std.mem.eql(u8, it.icon_theme_path, v)) {
                const fresh = self.alloc.dupe(u8, v) catch null;
                if (fresh) |f| {
                    self.alloc.free(it.icon_theme_path);
                    it.icon_theme_path = f;
                    changed = true;
                }
            }
        }
        if (p.id) |v| {
            if (!std.mem.eql(u8, it.id, v)) {
                const fresh = self.alloc.dupe(u8, v) catch null;
                if (fresh) |f| {
                    self.alloc.free(it.id);
                    it.id = f;
                    changed = true;
                }
            }
        }
        if (p.status) |v| {
            const s = parseStatus(v);
            if (it.status != s) {
                it.status = s;
                changed = true;
            }
        }
        return changed;
    }

    /// Installs an already-converted `IconPixmap`. Returns true when the image
    /// actually moved, so the dock knows to re-resolve the slot's art. An
    /// empty or degenerate buffer is ignored rather than clearing what the
    /// client sent last time.
    pub fn setPixmap(self: *Watcher, service: []const u8, path: []const u8, pixels: []const u8, w: i32, h: i32) bool {
        if (pixels.len == 0 or w <= 0 or h <= 0) return false;
        const i = self.indexOf(service, path) orelse return false;
        const it = &self.items.items[i];
        if (it.pixels.len == pixels.len and it.pw == w and it.ph == h and std.mem.eql(u8, it.pixels, pixels)) {
            return false;
        }
        const fresh = self.alloc.dupe(u8, pixels) catch return false;
        if (it.pixels.len > 0) self.alloc.free(it.pixels);
        it.pixels = fresh;
        it.pw = w;
        it.ph = h;
        return true;
    }

    pub fn setOwner(self: *Watcher, service: []const u8, path: []const u8, owner: []const u8) void {
        const i = self.indexOf(service, path) orelse return;
        const it = &self.items.items[i];
        if (std.mem.eql(u8, it.owner, owner)) return;
        if (self.alloc.dupe(u8, owner)) |fresh| {
            self.alloc.free(it.owner);
            it.owner = fresh;
        } else |_| {}
    }

    /// The item whose service *or* resolved owner is `name`. A signal always
    /// carries the unique name, while `RegisteredStatusNotifierItems` usually
    /// carries a well-known one.
    pub fn findByOwner(self: *Watcher, name: []const u8) ?*Item {
        for (self.items.items) |*it| {
            if (std.mem.eql(u8, it.owner, name) and it.owner.len > 0) return it;
        }
        for (self.items.items) |*it| {
            if (std.mem.eql(u8, it.service, name)) return it;
        }
        return null;
    }
};

test "tray: register/update/unregister" {
    const t = std.testing;
    var w = Watcher.init(t.allocator);
    defer w.deinit();
    try w.registerItem(":1.50", "/StatusNotifierItem");
    try w.registerItem(":1.50", "/StatusNotifierItem");
    try t.expectEqual(@as(usize, 1), w.items.items.len);
    w.updateFromProps(":1.50", "Mail", "Active", "mail-unread");
    try t.expectEqual(ItemStatus.active, w.items.items[0].status);
    try t.expect(w.unregisterItem(":1.50", "/StatusNotifierItem"));
    try t.expect(!w.unregisterItem(":1.50", "/StatusNotifierItem"));
}

test "tray: status parse" {
    const t = std.testing;
    try t.expectEqual(ItemStatus.passive, parseStatus("Passive"));
    try t.expectEqual(ItemStatus.active, parseStatus("Active"));
    try t.expectEqual(ItemStatus.needs_attention, parseStatus("NeedsAttention"));
    try t.expectEqual(ItemStatus.passive, parseStatus("Bogus"));
}
