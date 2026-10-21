//! Panel child spawn — port of
//! `src/desktop_shell/panel/spawn/panel_spawn.{hpp,cpp}`.
//!
//! Same process contract as the dock/taskbar spawn (pidfile guard against PID
//! reuse, next-to-exe resolution, log redirect, setsid) with horizon-panel
//! names. The C++ `mark_child_parent_pid` guard is the supervisor's
//! `parent_guard`; this file only owns the pidfile + spawn/kill pair.

const std = @import("std");

pub const pid_file_name: []const u8 = "panel.pid";
pub const child_bin_name: []const u8 = "horizon-panel";
pub const log_file_name: []const u8 = "horizon-panel.log";

/// `panel_state_base` (`panel_spawn.cpp:34-38`).
pub fn stateBase(xdg_state_home: ?[]const u8, home: ?[]const u8, buf: []u8) []const u8 {
    if (xdg_state_home) |d| {
        if (d.len == 0) return "/tmp";
        return d;
    }
    if (home) |h| {
        const r = std.fmt.bufPrint(buf, "{s}/.local/state", .{h}) catch return "/tmp";
        return r;
    }
    return "/tmp";
}

/// `<base>/event-horizon/panel.pid` (`panel_spawn.cpp:40-45`).
pub fn pidFilePath(
    gpa: std.mem.Allocator,
    xdg_state_home: ?[]const u8,
    home: ?[]const u8,
) ![]u8 {
    const base = stateBase(xdg_state_home, home, &[_]u8{});
    // stateBase borrows its inputs; rebuild the owned form here.
    if (xdg_state_home) |d| {
        if (d.len > 0) return std.fs.path.join(gpa, &.{ d, "event-horizon", pid_file_name });
    }
    if (home) |h| return std.fs.path.join(gpa, &.{ h, ".local/state", "event-horizon", pid_file_name });
    _ = base;
    return std.fs.path.join(gpa, &.{ "/tmp", "event-horizon", pid_file_name });
}

/// Parse a pidfile's contents (`panel_spawn.cpp:47-59`).
pub fn parsePidFile(text: []const u8) ?i32 {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (line.len == 0) return null;
    const v = std.fmt.parseInt(i32, line, 10) catch return null;
    if (v <= 1) return null;
    return v;
}

/// Whether `/proc/<pid>` looks like our child: comm == horizon-panel or the
/// exe link contains it (`panel_spawn.cpp:61-84`).
pub fn pidIsOurs(pid: i32, comm: ?[]const u8, exe_link: ?[]const u8) bool {
    if (pid <= 1) return false;
    if (comm) |c| {
        if (std.mem.eql(u8, std.mem.trim(u8, c, " \t\r\n"), child_bin_name)) return true;
    }
    if (exe_link) |e| {
        if (std.mem.indexOf(u8, e, child_bin_name) != null) return true;
    }
    return false;
}

/// Next-to-exe child resolution (`panel_spawn.cpp:113-123`): prefer
/// `<self-dir>/horizon-panel` when executable, else `horizon-panel` on PATH.
pub fn childBin(self_exe_dir: ?[]const u8, self_dir_has_child: bool, buf: []u8) []const u8 {
    if (self_exe_dir) |dir| {
        if (self_dir_has_child) {
            const r = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, child_bin_name }) catch return child_bin_name;
            return r;
        }
    }
    return child_bin_name;
}

test "panel-spawn: pidfile parse rejects junk" {
    const t = std.testing;
    try t.expectEqual(@as(?i32, 1234), parsePidFile("1234\n"));
    try t.expect(parsePidFile("") == null);
    try t.expect(parsePidFile("1\n") == null);
    try t.expect(parsePidFile("abc\n") == null);
    try t.expect(parsePidFile("-5\n") == null);
}

test "panel-spawn: pid ownership needs a name match" {
    const t = std.testing;
    try t.expect(pidIsOurs(100, "horizon-panel\n", null));
    try t.expect(pidIsOurs(100, null, "/usr/bin/horizon-panel"));
    try t.expect(!pidIsOurs(100, "horizon-dock", "/usr/bin/horizon-dock"));
    try t.expect(!pidIsOurs(1, "horizon-panel", null));
    try t.expect(!pidIsOurs(100, null, null));
}

test "panel-spawn: state base + child resolution" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("/x/state", stateBase("/x/state", "/home/u", &buf));
    try t.expectEqualStrings("/home/u/.local/state", stateBase(null, "/home/u", &buf));
    try t.expectEqualStrings("/tmp", stateBase(null, null, &buf));
    var bin_buf: [256]u8 = undefined;
    try t.expectEqualStrings("/exe/horizon-panel", childBin("/exe", true, &bin_buf));
    try t.expectEqualStrings("horizon-panel", childBin("/exe", false, &bin_buf));
    try t.expectEqualStrings("horizon-panel", childBin(null, false, &bin_buf));
    const p = try pidFilePath(t.allocator, "/x/state", null);
    defer t.allocator.free(p);
    try t.expectEqualStrings("/x/state/event-horizon/panel.pid", p);
}
