//! Supervisor-side
//! spawn/kill of the split-out `horizon-taskbar` child.
//!
//! The child owns the bar + app drawer + popups on its own Wayland
//! connection (mirroring `horizon-dock`). A pidfile guards against double
//! spawns and PID reuse: `pidIsOurs` matches `/proc/<pid>/stat`'s comm or
//! the `exe` link, so a stale child from a previous session is reaped, and
//! an unrelated process that inherited the pid is never signaled.

const std = @import("std");

pub const pid_file_name = "taskbar.pid";
pub const child_bin_name = "horizon-taskbar";

pub fn stateBase(gpa: std.mem.Allocator, xdg_state_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    if (xdg_state_home) |d| return gpa.dupe(u8, d);
    if (home) |h| return std.fs.path.join(gpa, &.{ h, ".local", "state" });
    return gpa.dupe(u8, "/tmp");
}

pub fn pidFilePath(gpa: std.mem.Allocator, xdg_state_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    const base = try stateBase(gpa, xdg_state_home, home);
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, "event-horizon", pid_file_name });
}

pub fn parsePid(text: []const u8) ?i32 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    const v = std.fmt.parseInt(i32, t, 10) catch return null;
    return if (v > 1) v else null;
}

/// Match `/proc/<pid>/stat`'s comm against `horizon-taskbar`.
/// `stat_text` is the file's content (borrowed); pure and tested.
pub fn statCommIsOurs(stat_text: []const u8) bool {
    const open_p = std.mem.indexOfScalar(u8, stat_text, '(') orelse return false;
    const close_p = std.mem.lastIndexOfScalar(u8, stat_text, ')') orelse return false;
    if (close_p <= open_p) return false;
    return std.mem.eql(u8, stat_text[open_p + 1 .. close_p], child_bin_name);
}

/// Match a `/proc/<pid>/exe` link target against the child name.
pub fn exeIsOurs(exe_target: []const u8) bool {
    return std.mem.indexOf(u8, exe_target, child_bin_name) != null;
}

pub fn childBinBeside(gpa: std.mem.Allocator, self_exe: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(self_exe) orelse ".";
    return std.fs.path.join(gpa, &.{ dir, child_bin_name });
}

test "taskbar-spawn: pid parsing" {
    const t = std.testing;
    try t.expectEqual(@as(?i32, 1234), parsePid("1234\n"));
    try t.expect(parsePid("1\n") == null);
    try t.expect(parsePid("nope") == null);
}

test "taskbar-spawn: pid identity never signals strangers" {
    const t = std.testing;
    try t.expect(statCommIsOurs("42 (horizon-taskbar) S 1 2 3"));
    try t.expect(!statCommIsOurs("42 (horizon-dock) S 1 2 3"));
    try t.expect(!statCommIsOurs("garbage"));
    try t.expect(exeIsOurs("/build/horizon-taskbar"));
    try t.expect(!exeIsOurs("/usr/bin/horizon-dock"));
}

test "taskbar-spawn: pidfile path" {
    const t = std.testing;
    const p = try pidFilePath(t.allocator, "/run/user/1000", null);
    defer t.allocator.free(p);
    try t.expectEqualStrings("/run/user/1000/event-horizon/taskbar.pid", p);
    const q = try childBinBeside(t.allocator, "/build/horizon");
    defer t.allocator.free(q);
    try t.expectEqualStrings("/build/horizon-taskbar", q);
}
