//! Shared runtime marker for "the compositor has presented the locked frame".
//!
//! `horizon-lock` and `horizon-idle` are separate processes. The idle daemon
//! holds a logind sleep delay inhibitor while the session is unlocked and
//! releases it only after this marker appears, so a suspend requested from
//! anywhere (lid, power menu, `systemctl`) cannot beat the lock screen to the
//! framebuffer. Without the handshake the machine sleeps with the desktop on
//! screen and wakes up showing it until the lock client catches up.
//!
//! `horizon-lock` writes the file from the compositor's `locked` event, which
//! ext-session-lock-v1 only sends after a locked frame has been presented on
//! every output. The file holds the lock client's pid: a leftover file from a
//! client that was killed (SIGKILL, crash) reads as unlocked once that pid is
//! gone.

const std = @import("std");
const linux = std.os.linux;

pub const kFileName = "event-horizon-lock.state";

/// `<xdg_runtime>/event-horizon-lock.state`, owned by the caller. Null when
/// `XDG_RUNTIME_DIR` is unset: no marker, and the idle daemon simply keeps its
/// inhibitor until logind's own cap.
pub fn path(alloc: std.mem.Allocator, xdg_runtime: ?[]const u8) ?[]u8 {
    const dir = xdg_runtime orelse return null;
    if (dir.len == 0) return null;
    return std.fs.path.join(alloc, &.{ dir, kFileName }) catch null;
}

pub fn markLocked(io: std.Io, alloc: std.mem.Allocator, xdg_runtime: ?[]const u8) void {
    const p = path(alloc, xdg_runtime) orelse return;
    defer alloc.free(p);
    var buf: [32]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{d}\n", .{linux.getpid()}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = body }) catch {};
}

pub fn clear(io: std.Io, alloc: std.mem.Allocator, xdg_runtime: ?[]const u8) void {
    const p = path(alloc, xdg_runtime) orelse return;
    defer alloc.free(p);
    std.Io.Dir.cwd().deleteFile(io, p) catch {};
}

/// True when a live lock client announced a presented lock screen.
pub fn lockedNow(io: std.Io, alloc: std.mem.Allocator, xdg_runtime: ?[]const u8) bool {
    const p = path(alloc, xdg_runtime) orelse return false;
    defer alloc.free(p);
    var buf: [64]u8 = undefined;
    const data = std.Io.Dir.cwd().readFile(io, p, &buf) catch return false;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, data, " \t\r\n"), 10) catch return false;
    if (pid <= 0) return false;
    // Signal 0 only checks for existence and permission, it is not delivered.
    const rc = linux.kill(pid, @enumFromInt(0));
    return linux.errno(rc) == .SUCCESS;
}

test "lock-state: mark, read, clear" {
    const t = std.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(dir);

    try t.expect(!lockedNow(io, t.allocator, dir));
    markLocked(io, t.allocator, dir);
    try t.expect(lockedNow(io, t.allocator, dir));
    clear(io, t.allocator, dir);
    try t.expect(!lockedNow(io, t.allocator, dir));

    // A marker left behind by a dead client must not count as locked.
    const p = path(t.allocator, dir).?;
    defer t.allocator.free(p);
    const file = try std.Io.Dir.cwd().createFile(io, p, .{});
    var wbuf: [32]u8 = undefined;
    var wr = file.writer(io, &wbuf);
    try wr.interface.writeAll("2147483647\n");
    try wr.end();
    file.close(io);
    try t.expect(!lockedNow(io, t.allocator, dir));
}

test "lock-state: no runtime dir means no path" {
    const t = std.testing;
    try t.expect(path(t.allocator, null) == null);
    try t.expect(path(t.allocator, "") == null);
}
