const std = @import("std");

pub const RunMode = enum {
    full,
    dock_only,
    screenshot,
    ipc,
    help,
    version,
};

pub const usage =
    \\Usage: horizon [options]
    \\
    \\  (no args)            full shell
    \\  --both               full shell
    \\  --dock               dock only
    \\  --eh-screenshot [f]  screenshot to PNG (see --help there)
    \\  --ipc <cmd> [args]   one-shot IPC client (e.g. overview-toggle)
    \\  --version            print version
    \\  -h, --help           this text
    \\
;

pub fn parseArgs(args: []const []const u8) RunMode {
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return .help;
        if (std.mem.eql(u8, a, "--version")) return .version;
        if (std.mem.eql(u8, a, "--eh-screenshot")) return .screenshot;
        if (std.mem.eql(u8, a, "--ipc")) return .ipc;
    }
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--dock")) return .dock_only;
        if (std.mem.eql(u8, a, "--both")) return .full;
    }
    return .full;
}

test "cli: flags map to entry behavior" {
    const t = std.testing;
    try t.expectEqual(RunMode.full, parseArgs(&.{ "EventHorizon", "--both" }));
    try t.expectEqual(RunMode.dock_only, parseArgs(&.{ "EventHorizon", "--dock" }));
    try t.expectEqual(RunMode.screenshot, parseArgs(&.{ "EventHorizon", "--eh-screenshot" }));
    try t.expectEqual(RunMode.ipc, parseArgs(&.{ "EventHorizon", "--ipc", "ping" }));
    try t.expectEqual(RunMode.version, parseArgs(&.{ "EventHorizon", "--version" }));
    try t.expectEqual(RunMode.full, parseArgs(&.{"EventHorizon"}));
}
