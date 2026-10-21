const std = @import("std");
const live = @import("desktop_shell/controlcenter/live.zig");

test "child env" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const r2 = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "/usr/bin/env" } }) catch |e| {
        std.debug.print("run error: {}\n", .{e});
        return;
    };
    defer std.testing.allocator.free(r2.stdout);
    defer std.testing.allocator.free(r2.stderr);
    var it = std.mem.splitScalar(u8, r2.stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "DBUS") or std.mem.startsWith(u8, line, "XDG_RUNTIME") or std.mem.startsWith(u8, line, "WAYLAND") or std.mem.startsWith(u8, line, "DISPLAY")) {
            std.debug.print("child: {s}\n", .{line});
        }
    }
    std.debug.print("child env total bytes: {d}, stderr={d}\n", .{ r2.stdout.len, r2.stderr.len });
}
