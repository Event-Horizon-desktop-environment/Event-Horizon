const std = @import("std");
const dbus_obj = @import("object.zig");
const wire = @import("wire.zig");

pub const bus_name = "org.freedesktop.FileManager1";
pub const object_path = "/org/freedesktop/FileManager1";
pub const interface = "org.freedesktop.FileManager1";

pub const Proxy = struct {
    alloc: std.mem.Allocator,
    tree: dbus_obj.Tree,
    launch_fn: ?*const fn (ctx: *anyopaque, manager: []const u8, uris: []const []const u8) void = null,
    launch_ctx: *anyopaque = undefined,
    methods: [2]dbus_obj.Method = undefined,

    pub fn init(alloc: std.mem.Allocator, conn: *@import("connection.zig").Conn) Proxy {
        return .{ .alloc = alloc, .tree = dbus_obj.Tree.init(alloc, conn) };
    }

    pub fn deinit(self: *Proxy) void {
        self.tree.deinit();
    }

    fn showFolders(ctx: *anyopaque, args: []const wire.Value) dbus_obj.MethodResult {
        const self: *Proxy = @ptrCast(@alignCast(ctx));
        if (args.len < 1 or args[0] != .array) {
            return .{ .err = .{ .name = "org.freedesktop.DBus.Error.InvalidArgs", .message = "need as" } };
        }
        if (self.launch_fn) |h| {
            h(self.launch_ctx, "", &.{});
        }
        return .{ .ok = &.{} };
    }

    fn showItems(ctx: *anyopaque, args: []const wire.Value) dbus_obj.MethodResult {
        const self: *Proxy = @ptrCast(@alignCast(ctx));
        if (args.len < 2 or args[0] != .array or args[1] != .string) {
            return .{ .err = .{ .name = "org.freedesktop.DBus.Error.InvalidArgs", .message = "need as,s" } };
        }
        if (self.launch_fn) |h| {
            h(self.launch_ctx, args[1].string, &.{});
        }
        return .{ .ok = &.{} };
    }

    pub fn wireTable(self: *Proxy) dbus_obj.VTable {
        self.methods = [_]dbus_obj.Method{
            .{ .name = "ShowFolders", .in_sig = "as", .out_sig = "", .handler = showFolders, .ctx = self },
            .{ .name = "ShowItems", .in_sig = "ass", .out_sig = "", .handler = showItems, .ctx = self },
        };
        return .{ .interface = interface, .methods = &self.methods };
    }
};

test "filemanager1: constants" {
    const t = std.testing;
    try t.expectEqualStrings("org.freedesktop.FileManager1", bus_name);
    try t.expectEqualStrings("/org/freedesktop/FileManager1", object_path);
}
