const std = @import("std");
const ipc_client = @import("../ipc_client.zig");

pub fn runIpcClient(io: std.Io, args: []const []const u8, eh_ipc_socket: ?[]const u8, xdg_runtime: ?[]const u8) u8 {
    var arena_buf: [8192]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&arena_buf);
    const a = arena.allocator();

    var err_buf: [256]u8 = undefined;
    var ef = std.Io.File.stderr();
    var ew = ef.writer(io, &err_buf);
    if (args.len < 3) {
        ew.interface.print("Usage: EventHorizon --ipc <command> [args...]\n", .{}) catch {};
        ew.interface.flush() catch {};
        return 1;
    }
    const path = ipc_client.socketPathFor(a, eh_ipc_socket, xdg_runtime) catch return 1;
    const cmd = std.mem.join(a, " ", args[2..]) catch return 1;
    const resp = ipc_client.sendLegacy(a, path, cmd) catch |err| {
        ew.interface.print("eh-ipc: {s} ({s})\n", .{ path, @errorName(err) }) catch {};
        ew.interface.flush() catch {};
        return 1;
    };
    var out_buf: [4096]u8 = undefined;
    var of = std.Io.File.stdout();
    var ow = of.writer(io, &out_buf);
    ow.interface.print("{s}\n", .{resp}) catch {};
    ow.interface.flush() catch {};
    if (std.mem.startsWith(u8, resp, "error")) return 1;
    return 0;
}

pub const TrayState = enum { idle, watching };
pub const MprisState = enum { stopped, playing, paused };

test "services: placeholder" {
    try std.testing.expect(true);
}
