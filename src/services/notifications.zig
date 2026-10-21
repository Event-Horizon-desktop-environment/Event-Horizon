const std = @import("std");
const dbus_obj = @import("../dbus/object.zig");
const wire = @import("../dbus/wire.zig");

pub const bus_name = "org.freedesktop.Notifications";
pub const object_path = "/org/freedesktop/Notifications";
pub const interface = "org.freedesktop.Notifications";

pub const Urgency = enum(u8) { low = 0, normal = 1, critical = 2 };

pub const Notification = struct {
    id: u32,
    app_name: []const u8,
    title: []const u8,
    body: []const u8,
    urgency: Urgency = .normal,
    timeout_ms: i32 = 6000,
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(Notification),
    next_id: u32 = 1,
    history: std.ArrayList(Notification),

    pub fn init(alloc: std.mem.Allocator) Store {
        return .{ .alloc = alloc, .items = .empty, .history = .empty };
    }

    pub fn deinit(self: *Store) void {
        for (self.items.items) |*n| freeNotif(self.alloc, n);
        for (self.history.items) |*n| freeNotif(self.alloc, n);
        self.items.deinit(self.alloc);
        self.history.deinit(self.alloc);
    }

    fn freeNotif(alloc: std.mem.Allocator, n: *Notification) void {
        alloc.free(n.app_name);
        alloc.free(n.title);
        alloc.free(n.body);
    }

    fn dupeNotif(alloc: std.mem.Allocator, n: *const Notification) !Notification {
        return .{
            .id = n.id,
            .app_name = try alloc.dupe(u8, n.app_name),
            .title = try alloc.dupe(u8, n.title),
            .body = try alloc.dupe(u8, n.body),
            .urgency = n.urgency,
            .timeout_ms = n.timeout_ms,
        };
    }

    pub fn notify(self: *Store, app: []const u8, title: []const u8, body: []const u8, urgency: Urgency, timeout_ms: i32, save_history: bool) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        const n = Notification{
            .id = id,
            .app_name = try self.alloc.dupe(u8, app),
            .title = try self.alloc.dupe(u8, title),
            .body = try self.alloc.dupe(u8, body),
            .urgency = urgency,
            .timeout_ms = timeout_ms,
        };
        errdefer freeNotif(self.alloc, @constCast(&n));
        try self.items.append(self.alloc, n);
        if (save_history) {
            const h = try Store.dupeNotif(self.alloc, &self.items.items[self.items.items.len - 1]);
            errdefer freeNotif(self.alloc, @constCast(&h));
            try self.history.append(self.alloc, h);
        }
        return id;
    }

    pub fn close(self: *Store, id: u32) bool {
        for (self.items.items, 0..) |*n, i| {
            if (n.id == id) {
                freeNotif(self.alloc, n);
                _ = self.items.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn getUrgency(hints: []const wire.Value) Urgency {
        for (hints) |h| {
            if (h != .structure or h.structure.len != 2) continue;
            if (h.structure[0] != .string) continue;
            if (!std.mem.eql(u8, h.structure[0].string, "urgency")) continue;
            const v = h.structure[1];
            if (v != .variant) continue;
            if (v.variant.val.* == .byte) {
                return switch (v.variant.val.byte) {
                    0 => .low,
                    2 => .critical,
                    else => .normal,
                };
            }
            if (v.variant.val.* == .uint32) {
                return switch (v.variant.val.uint32) {
                    0 => .low,
                    2 => .critical,
                    else => .normal,
                };
            }
        }
        return .normal;
    }
};

test "notifications: store lifecycle + urgency parse" {
    const t = std.testing;
    var s = Store.init(t.allocator);
    defer s.deinit();
    const id = try s.notify("app", "t", "b", .critical, 5000, true);
    try t.expectEqual(@as(u32, 1), id);
    try t.expectEqual(@as(usize, 1), s.items.items.len);
    try t.expectEqual(@as(usize, 1), s.history.items.len);
    try t.expect(s.close(id));
    try t.expect(!s.close(id));
    try t.expectEqual(@as(usize, 0), s.items.items.len);
    try t.expectEqual(@as(usize, 1), s.history.items.len);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const vb = try arena.allocator().create(wire.Value);
    vb.* = .{ .byte = 2 };
    const pair = try arena.allocator().alloc(wire.Value, 2);
    pair[0] = .{ .string = "urgency" };
    pair[1] = .{ .variant = .{ .sig = "y", .val = vb } };
    const hints = [_]wire.Value{.{ .structure = pair }};
    try t.expectEqual(Urgency.critical, Store.getUrgency(&hints));
    try t.expectEqual(Urgency.normal, Store.getUrgency(&[_]wire.Value{}));
}
