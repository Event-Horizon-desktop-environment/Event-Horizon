//! Testable decisions of the split-out `horizon-taskbar` child.
//!
//! The child owns its own Wayland connection, toplevel tracking, tray bus,
//! 1 s poll timer, settings inotify and MPRIS listener. What lives here is
//! the routing that can be pinned without a compositor: IPC topic dispatch
//! (`config.applied` → reload, `command.request/taskbar.menu.toggle` →
//! menu), output assignment (all / auto / named), and the poll-timer tick
//! contract.

const std = @import("std");

pub const menu_toggle_cmd = "taskbar.menu.toggle";
pub const settings_toggle_cmd = "settings.toggle";
pub const nightlight_toggle_cmd = "nightlight.toggle";
pub const overview_toggle_cmd = "overview.toggle";

pub const IpcAction = enum {
    none,
    reload_config,
    toggle_menu,
    ignore_settings_toggle,
};

/// Route one IPC event to an action. Unknown topics/payloads are `none`.
pub fn routeIpc(topic: []const u8, payload: []const u8) IpcAction {
    if (std.mem.eql(u8, topic, "config.applied")) return .reload_config;
    if (std.mem.eql(u8, topic, "command.request")) {
        if (std.mem.eql(u8, payload, menu_toggle_cmd)) return .toggle_menu;
        if (std.mem.eql(u8, payload, settings_toggle_cmd)) return .ignore_settings_toggle;
    }
    return .none;
}

pub const OutputAssign = enum { all, auto, named };

/// Classify the `[taskbar] output` value. Trims whitespace; empty means
/// auto (first output), matching `trim_output_assign`.
pub fn classifyOutput(raw: []const u8) struct { kind: OutputAssign, name: []const u8 } {
    const v = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(v, "all")) return .{ .kind = .all, .name = "" };
    if (v.len == 0 or std.ascii.eqlIgnoreCase(v, "auto")) return .{ .kind = .auto, .name = "" };
    return .{ .kind = .named, .name = v };
}

/// Pick the target output index for single-bar mode: the named one when
/// present (case-insensitive), else the first output at/below the origin,
/// else output 0. Returns null with no outputs.
pub fn pickSingleOutput(names: []const []const u8, want: []const u8, xs: []const i32, ys: []const i32) ?usize {
    if (names.len == 0) return null;
    if (want.len > 0) {
        for (names, 0..) |n, i| {
            if (std.ascii.eqlIgnoreCase(n, want)) return i;
        }
    }
    for (names, 0..) |_, i| {
        const x = if (i < xs.len) xs[i] else 0;
        const y = if (i < ys.len) ys[i] else 0;
        if (x <= 0 and y <= 0) return i;
    }
    return 0;
}

/// The 1 s poll tick: battery/bluetooth polls, MPRIS refresh, then a frame
/// request — skipped entirely while the bar is disabled.
pub fn tickNeedsFrame(enabled: bool) bool {
    return enabled;
}

test "taskbar-standalone: ipc routing" {
    const t = std.testing;
    try t.expectEqual(IpcAction.reload_config, routeIpc("config.applied", ""));
    try t.expectEqual(IpcAction.toggle_menu, routeIpc("command.request", "taskbar.menu.toggle"));
    try t.expectEqual(IpcAction.ignore_settings_toggle, routeIpc("command.request", "settings.toggle"));
    try t.expectEqual(IpcAction.none, routeIpc("command.request", "menu.toggle"));
    try t.expectEqual(IpcAction.none, routeIpc("other", "x"));
}

test "taskbar-standalone: output assignment" {
    const t = std.testing;
    try t.expectEqual(OutputAssign.all, classifyOutput("All").kind);
    try t.expectEqual(OutputAssign.auto, classifyOutput("").kind);
    try t.expectEqual(OutputAssign.auto, classifyOutput("Auto").kind);
    try t.expectEqualStrings("HDMI-1", classifyOutput(" HDMI-1 ").name);
    const names = [_][]const u8{ "DP-1", "HDMI-1" };
    const xs = [_]i32{ 0, 1920 };
    const ys = [_]i32{ 0, 0 };
    try t.expectEqual(@as(?usize, 1), pickSingleOutput(&names, "hdmi-1", &xs, &ys));
    try t.expectEqual(@as(?usize, 0), pickSingleOutput(&names, "missing", &xs, &ys));
    try t.expect(pickSingleOutput(&.{}, "x", &xs, &ys) == null);
    try t.expect(tickNeedsFrame(true) and !tickNeedsFrame(false));
}
