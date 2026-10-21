const std = @import("std");

pub fn signalRule(alloc: std.mem.Allocator, sender: ?[]const u8, iface: ?[]const u8, member: ?[]const u8, path: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "type='signal'");
    if (sender) |s| {
        try out.appendSlice(alloc, ",sender='");
        try out.appendSlice(alloc, s);
        try out.append(alloc, '\'');
    }
    if (iface) |s| {
        try out.appendSlice(alloc, ",interface='");
        try out.appendSlice(alloc, s);
        try out.append(alloc, '\'');
    }
    if (member) |s| {
        try out.appendSlice(alloc, ",member='");
        try out.appendSlice(alloc, s);
        try out.append(alloc, '\'');
    }
    if (path) |s| {
        try out.appendSlice(alloc, ",path='");
        try out.appendSlice(alloc, s);
        try out.append(alloc, '\'');
    }
    return out.toOwnedSlice(alloc);
}

test "dbus-match: rule builder" {
    const t = std.testing;
    const r = try signalRule(t.allocator, "org.bluez", "org.freedesktop.DBus.Properties", "PropertiesChanged", null);
    defer t.allocator.free(r);
    try t.expectEqualStrings("type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'", r);
    const r2 = try signalRule(t.allocator, null, null, null, null);
    defer t.allocator.free(r2);
    try t.expectEqualStrings("type='signal'", r2);
}
