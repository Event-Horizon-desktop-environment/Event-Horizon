//! `horizonClipboardDaemon` core — the pieces of the C++ daemon
//! (`src/clipboard_daemon/main.cpp`) that are not the event loop: the
//! argument contract, PNG loading, and the data-control backend choice.
//! The loop itself lives in `src/bin/clipboard.zig`.
//!
//! The C++ binary is the standalone half of the clipboard system: it reads
//! one PNG, owns the Wayland selection with `image/png`, and exits when
//! another client replaces the selection. `--eh-screenshot` hands its PNG
//! to it (`bootstrap/screenshot.zig`), which is why it must outlive its
//! spawner.
//!
//! The C++ also had an in-memory `Daemon`/`HeldMime` sketch in this file
//! from an earlier design round; that shape never existed in the C++ and
//! nothing referenced it, so it is replaced by the real port.

const std = @import("std");
const conn_mod = @import("wl/connection.zig");
const clipboard = @import("wl/input/clipboard.zig");

/// Fallback argv0 for the usage line — the C++ prints
/// `<argv0 ? argv0 : "horizonClipboardDaemon">` (main.cpp:50).
pub const usage_name = "horizonClipboardDaemon";

/// `Usage: <argv0> <file.png>` on stderr; the C++ main exits 1 when the
/// argument is missing (main.cpp:48-52).
pub fn printUsage(argv0: []const u8) void {
    std.debug.print("Usage: {s} <file.png>\n", .{argv0});
}

/// Upper bound on the PNG handed to the service. The C++ `std::ifstream`
/// read whatever the file claimed, with no cap (main.cpp:70-79); this only
/// guards a pathological file and is far above any screenshot.
pub const max_png_bytes: usize = 512 * 1024 * 1024;

/// Read the whole PNG into memory — the C++ main does:
///   std::ifstream in(path, std::ios::binary);
///   if (!in) { "Failed to open: <path>"; return 1; }
///   ... read to string ...
///   if (in.bad()) { "Failed to read: <path>"; return 1; }
/// One Zig call covers both; the caller reports the error name.
pub fn loadPng(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_png_bytes));
}

pub const BackendChoice = struct {
    backend: clipboard.Backend,
    manager: *anyopaque,
};

/// ext-data-control-v1 preferred, wlr fallback — the exact rule of the C++
/// registry handler (main.cpp:26-45): the ext branch binds whenever the
/// interface shows up, the wlr branch only while no manager is known, so
/// ext wins whenever both exist, regardless of arrival order. The Zig
/// `Connection.bindAll` already bound both globals (ext v1, wlr v2), so the
/// choice reduces to the preference order.
pub fn chooseBackend(bound: *const conn_mod.Connection.Bound) ?BackendChoice {
    if (bound.ext_data_control) |m| return .{ .backend = .ext, .manager = m };
    if (bound.wlr_data_control) |m| return .{ .backend = .wlr, .manager = m };
    return null;
}

test "clipboard-daemon: backend choice prefers ext, falls back to wlr" {
    const t = std.testing;
    const Bound = conn_mod.Connection.Bound;
    var b = Bound{};
    try t.expect(chooseBackend(&b) == null);
    b.wlr_data_control = @ptrFromInt(0x2222);
    const w = chooseBackend(&b).?;
    try t.expectEqual(clipboard.Backend.wlr, w.backend);
    b.ext_data_control = @ptrFromInt(0x1111);
    const e = chooseBackend(&b).?;
    try t.expectEqual(clipboard.Backend.ext, e.backend);
    try t.expectEqual(@as(*anyopaque, @ptrFromInt(0x1111)), e.manager);
}

test "clipboard-daemon: loadPng reads the whole file, missing file errors" {
    const t = std.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/shot.png", .{&tmp.sub_path});
    defer t.allocator.free(path);

    {
        const file = try tmp.dir.createFile(io, "shot.png", .{});
        var wbuf: [64]u8 = undefined;
        var wr = file.writer(io, &wbuf);
        const payload = "\x89PNG\r\n\x1a\nprobe";
        wr.interface.writeAll(payload) catch {
            file.close(io);
            return error.WriteFailed;
        };
        wr.end() catch {
            file.close(io);
            return error.WriteFailed;
        };
        file.close(io);
    }

    const png = try loadPng(io, t.allocator, path);
    defer t.allocator.free(png);
    try t.expectEqualStrings("\x89PNG\r\n\x1a\nprobe", png);

    try t.expectError(error.FileNotFound, loadPng(io, t.allocator, ".zig-cache/tmp/eh-missing.png"));
}
