const std = @import("std");

pub const version = @import("version.zig");
pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const ipc = @import("ipc.zig");
pub const loop = @import("loop.zig");
pub const threads = @import("threads.zig");
pub const parent_guard = @import("parent_guard.zig");
pub const backends = @import("backends/compositor.zig");
pub const wl = @import("wl/connection.zig");
pub const services = @import("services/services.zig");
pub const desktop_shell = @import("desktop_shell/shell.zig");
pub const wallpaper = @import("wallpaper.zig");
pub const logz = @import("logz.zig");
pub const runner = @import("bootstrap/runner.zig");
pub const screenshot = @import("bootstrap/screenshot.zig");

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));

    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    logz.init(io, init.environ_map.get("HOME"), "EventHorizon-zig");
    defer logz.deinit();

    const args = try init.minimal.args.toSlice(arena);
    logz.log("boot: pid={d} argc={d}", .{ std.os.linux.getpid(), args.len });

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &stdout_buf);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr = stderr_file.writer(io, &stderr_buf);

    const mode = cli.parseArgs(args);
    logz.log("mode: {s}", .{@tagName(mode)});

    switch (mode) {
        .help => {
            try stdout.interface.print("{s}", .{cli.usage});
            stdout.interface.flush() catch {};
            return 0;
        },
        .version => {
            try stdout.interface.print("EventHorizon {s} (zig port)\n", .{version.string});
            stdout.interface.flush() catch {};
            return 0;
        },
        .screenshot => {
            // A screenshot is a one-shot CLI mode: it owns nothing of the
            // shell's loop, so it takes the arena and returns an exit code.
            // XDG_RUNTIME_DIR carries the interactive picker's single-flight
            // lock (see screenshot.zig).
            return screenshot.run(io, arena, args, init.environ_map.get("XDG_RUNTIME_DIR"));
        },
        .ipc => return services.runIpcClient(io, args, init.environ_map.get("EH_IPC_SOCKET"), init.environ_map.get("XDG_RUNTIME_DIR")),
        .full, .dock_only => {
            const eh_sock = init.environ_map.get("EH_IPC_SOCKET");
            const xdg_runtime = init.environ_map.get("XDG_RUNTIME_DIR");
            const xdg = init.environ_map.get("XDG_CONFIG_HOME");
            const home = init.environ_map.get("HOME");
            var cfg = config.loadDefault(gpa, io, xdg, home) catch |err| {
                try stderr.interface.print("config load failed: {s}, continuing with defaults\n", .{@errorName(err)});
                stderr.interface.flush() catch {};
                return runner.run(io, eh_sock, xdg_runtime, xdg, home);
            };
            defer cfg.deinit();
            return runner.run(io, eh_sock, xdg_runtime, xdg, home);
        },
    }
}
