//! `horizonClipboardDaemon <file.png>` — port of
//! `src/clipboard_daemon/main.cpp`.
//!
//! Reads one PNG, connects to Wayland, binds the data-control manager
//! (ext-data-control-v1 preferred, wlr-data-control-unstable-v1 fallback)
//! plus the seat, owns the clipboard *and* primary selection with
//! `image/png` and the file bytes, then exits 0 once another client
//! replaces the selection or the connection dies.
//!
//! Spawned by `--eh-screenshot` for the "copy to clipboard" handoff
//! (`bootstrap/screenshot.zig`) and listed in the supervisor table as an
//! on-demand component — the C++ shell never spawned it from its supervisor
//! either; it only ever existed as a screenshot child.
//!
//! Deliberately does NOT install the parent guard the other bins use: the
//! daemon must outlive the screenshot process that spawns it (the C++ had
//! no guard). The guard would also misfire when the screenshot process
//! inherited a supervisor marker — the daemon's PPID is the screenshot
//! process, not the supervisor, so `installGuard` would exit(1) instantly.

const std = @import("std");
const eh = @import("eh");
const wl = eh.wl_c.wl;
const core = eh.clipboard_daemon;
const clipboard = eh.clipboard;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    eh.logz.init(io, init.environ_map.get("HOME"), "horizonClipboardDaemon-zig");
    defer eh.logz.deinit();

    const args = init.minimal.args.toSlice(arena) catch &.{};
    const argv0: []const u8 = if (args.len > 0 and args[0].len > 0) args[0] else core.usage_name;

    if (args.len < 2) {
        core.printUsage(argv0);
        eh.logz.err("no PNG path given", .{});
        return 1;
    }
    const png_path = args[1];

    const png = core.loadPng(io, gpa, png_path) catch |e| {
        // The C++ prints "Failed to open: <path>" when the ifstream cannot
        // open and "Failed to read: <path>" on a bad read; one line with
        // the error name covers both.
        eh.logz.err("Failed to open: {s} ({s})", .{ png_path, @errorName(e) });
        return 1;
    };
    defer gpa.free(png);

    var conn = eh.wl_conn.Connection.init(gpa);
    defer conn.deinit();
    if (!conn.connect(null)) {
        eh.logz.err("Failed to connect to Wayland display.", .{});
        return 1;
    }
    var bound = eh.wl_conn.Connection.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    const display = conn.display orelse {
        eh.logz.err("Failed to connect to Wayland display.", .{});
        return 1;
    };

    const choice = core.chooseBackend(&bound) orelse {
        eh.logz.err("No data-control protocol available.", .{});
        return 1;
    };
    const seat = bound.seat orelse {
        eh.logz.err("No wl_seat available.", .{});
        return 1;
    };

    var svc = clipboard.Service.init(gpa);
    defer svc.deinit();
    if (!svc.bind(choice.manager, choice.backend, seat, display)) {
        eh.logz.err("Failed to bind clipboard.", .{});
        return 1;
    }
    if (!svc.copyData("image/png", png)) {
        eh.logz.err("Failed to copy to clipboard.", .{});
        return 1;
    }
    _ = conn.flush();
    eh.logz.log("holding image/png ({d} bytes, backend={s})", .{ png.len, @tagName(choice.backend) });

    // Hold the clipboard until another client replaces the selection; the
    // data-control device finishing (display closing) breaks the loop too.
    while (svc.ownsSelection()) {
        if (wl.wl_display_dispatch(display) < 0) break;
    }
    eh.logz.log("selection replaced or display closed; exiting", .{});
    return 0;
}
