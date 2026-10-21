const std = @import("std");

/// `horizon-desktop` child spawn/pidfile: supervisor spawns the
/// split-out desktop child, guards PID reuse via `/proc`, and the child owns
/// its pidfile + log.
///
/// Pidfile: `$XDG_STATE_HOME|~/.local/state|/tmp/event-horizon/desktop.pid`
/// (+ `horizon-desktop.log` next to it).

pub const pid_file_name: []const u8 = "desktop.pid";
pub const log_file_name: []const u8 = "horizon-desktop.log";

pub fn stateDir(env_state: ?[]const u8, home: ?[]const u8, buf: []u8) ?[]const u8 {
    if (env_state) |s| {
        if (s.len > 0) {
            const out = std.fmt.bufPrint(buf, "{s}/event-horizon", .{s}) catch return null;
            return out;
        }
    }
    if (home) |h| {
        const out = std.fmt.bufPrint(buf, "{s}/.local/state/event-horizon", .{h}) catch return null;
        return out;
    }
    return std.fmt.bufPrint(buf, "/tmp/event-horizon", .{}) catch null;
}

pub fn pidFilePath(alloc: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ dir, pid_file_name });
}

pub fn logFilePath(alloc: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ dir, log_file_name });
}

/// Parse a pidfile body (`"%d\n"`). Returns null on garbage.
pub fn parsePidFile(text: []const u8) ?i32 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    const v = std.fmt.parseInt(i32, t, 10) catch return null;
    if (v <= 0) return null;
    return v;
}

/// Sibling binary lookup: `./horizon-desktop` next to the supervisor else PATH.
/// Returns the scheme so the spawner knows which `posix_spawn` flavor to use.
pub const BinaryKind = enum { sibling, path };

pub fn siblingPath(alloc: std.mem.Allocator, supervisor_exe: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(supervisor_exe) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, "horizon-desktop" });
}

/// Read `/proc/<pid>/stat` comm and check it is `horizon-desktop`
/// (PID-reuse guard).
pub fn procCommIsDesktop(comm: []const u8) bool {
    // comm is `(horizon-desktop)` with parens.
    const t = std.mem.trim(u8, comm, " \t\r\n");
    if (t.len >= 2 and t[0] == '(' and t[t.len - 1] == ')') {
        return std.mem.eql(u8, t[1 .. t.len - 1], "horizon-desktop");
    }
    return std.mem.indexOf(u8, t, "horizon-desktop") != null;
}

/// Extract comm `(...)` from a full `/proc/pid/stat` line.
pub fn statComm(stat_text: []const u8) ?[]const u8 {
    const l = std.mem.indexOfScalar(u8, stat_text, '(') orelse return null;
    const r = std.mem.lastIndexOfScalar(u8, stat_text, ')') orelse return null;
    if (r <= l) return null;
    return stat_text[l .. r + 1];
}

/// Double-fork launch helper command:
/// `setsid`, fork twice, `/dev/null` stdio, `execlp(bin)`.
pub fn launchBinaryCmd(alloc: std.mem.Allocator, bin: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "setsid {s} </dev/null >/dev/null 2>&1 &", .{bin});
}

test "spawn: state dir + pid parse" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("/tmp/event-horizon", stateDir(null, null, &buf).?);
    try t.expectEqualStrings("/x/event-horizon", stateDir("/x", null, &buf).?);
    try t.expectEqual(@as(?i32, 1234), parsePidFile("1234\n"));
    try t.expect(parsePidFile("abc") == null);
    try t.expect(parsePidFile("-5") == null);
    const p = try pidFilePath(t.allocator, "/tmp/event-horizon");
    defer t.allocator.free(p);
    try t.expectEqualStrings("/tmp/event-horizon/desktop.pid", p);
    const s = try siblingPath(t.allocator, "/usr/bin/EventHorizon");
    defer t.allocator.free(s);
    try t.expectEqualStrings("/usr/bin/horizon-desktop", s);
}

test "spawn: proc comm guard + launch cmd" {
    const t = std.testing;
    try t.expect(procCommIsDesktop("(horizon-desktop)"));
    try t.expect(!procCommIsDesktop("(something-else)"));
    try t.expectEqualStrings("(horizon-desktop)", statComm("1234 (horizon-desktop) S 1").?);
    const c = try launchBinaryCmd(t.allocator, "horizon-live-wallpaper");
    defer t.allocator.free(c);
    try t.expect(std.mem.indexOf(u8, c, "setsid") != null);
}
