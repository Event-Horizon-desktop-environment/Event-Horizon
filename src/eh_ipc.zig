const std = @import("std");
const ipc_client = @import("ipc_client.zig");
const logz = @import("logz.zig");

const c = @import("c_stdlib");

fn envDup(alloc: std.mem.Allocator, key: [:0]const u8) ?[]u8 {
    const p = c.getenv(key);
    if (p == null) return null;
    return alloc.dupe(u8, std.mem.span(p)) catch null;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        var buf: [128]u8 = undefined;
        var f = std.Io.File.stderr();
        var w = f.writer(io, &buf);
        w.interface.print("Usage: eh-ipc <command> [args...]\n", .{}) catch {};
        w.interface.flush() catch {};
        return 1;
    }

    const eh_sock = envDup(arena, "EH_IPC_SOCKET");
    const xdg = envDup(arena, "XDG_RUNTIME_DIR");
    const path = try ipc_client.socketPathFor(arena, eh_sock, xdg);

    const cmd = try std.mem.join(arena, " ", args[1..]);

    logz.init(io, init.environ_map.get("HOME"), "eh-ipc-zig");
    defer logz.deinit();
    logz.log("send: socket='{s}' cmd='{s}'", .{ path, cmd });

    const resp = ipc_client.sendLegacy(gpa, path, cmd) catch |err| {
        var buf: [256]u8 = undefined;
        var f = std.Io.File.stderr();
        var w = f.writer(io, &buf);
        const hint: []const u8 = if (err == error.ConnectFailed) "Is Event Horizon running?" else @errorName(err);
        w.interface.print("eh-ipc: {s} ({s})\n", .{ path, hint }) catch {};
        w.interface.flush() catch {};
        return 1;
    };
    defer gpa.free(resp);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout();
    var ow = out.writer(io, &out_buf);
    ow.interface.print("{s}\n", .{resp}) catch {};
    ow.interface.flush() catch {};
    if (std.mem.startsWith(u8, resp, "error")) return 1;
    return 0;
}
