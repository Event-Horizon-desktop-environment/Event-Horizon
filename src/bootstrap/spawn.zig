const std = @import("std");

pub const RestartPolicy = enum { always, on_demand, never };
pub const Component = struct {
    name: []const u8,
    argv0: []const u8,
    extra_args: []const []const u8 = &.{},
    policy: RestartPolicy = .always,
    restarts: u32 = 0,
    backoff_ms: u64 = 0,
    crashed_at_ms: i64 = 0,
};

pub const table = [_]Component{
    .{ .name = "wallpaper", .argv0 = "horizon-wallpaper", .policy = .always },
    .{ .name = "desktop", .argv0 = "horizon-desktop", .policy = .always },
    .{ .name = "dock", .argv0 = "horizon-dock", .policy = .always },
    .{ .name = "taskbar", .argv0 = "horizon-taskbar", .policy = .always },
    .{ .name = "notifications", .argv0 = "horizon-notifications", .policy = .always },
    // The polkit authentication agent: registers with polkitd on the system
    // bus and shows the auth card. Always on — a dead agent means every
    // privileged action falls back to the ugly polkit text agent.
    .{ .name = "polkit-agent", .argv0 = "horizon-polkit-agent", .policy = .always },
    // ClipStack: clipboard history + selection owner. Always on — history
    // only exists while somebody is watching, and startup re-publishes the
    // newest entry so the clipboard survives a shell restart. The picker
    // (`horizon-clipstack-pick`, Super+V) is spawned by the session's own
    // key binding and is deliberately not in this table.
    .{ .name = "clipstack", .argv0 = "horizon-clipstack", .policy = .always },
    .{ .name = "stage", .argv0 = "horizon-stage", .policy = .always },
    // Not a boot component: the C++ shell never spawned the daemon from its
    // supervisor either — `--eh-screenshot` spawns it per copy with the PNG
    // path as its argument. Without a path the binary prints usage and exits
    // 1, so an `always` policy here would crash-loop it at the backoff cap.
    .{ .name = "clipboard", .argv0 = "horizonClipboardDaemon", .policy = .on_demand },
    .{ .name = "filemanager1", .argv0 = "horizon-filemanager1", .policy = .always },
    .{ .name = "settings", .argv0 = "horizon-settings", .policy = .on_demand },
    .{ .name = "disks", .argv0 = "horizon-disks", .policy = .on_demand },
    .{ .name = "live-wallpaper", .argv0 = "horizon-live-wallpaper", .policy = .on_demand },
};

pub fn nextBackoffMs(restarts: u32) u64 {    return switch (restarts) {
        0, 1, 2 => 0,
        3 => 1000,
        4 => 5000,
        else => 30000,
    };
}

pub fn shouldEscalate(recent_crashes: u32) bool {
    return recent_crashes >= 3;
}

/// Settings gate for the bar components:
/// dock runs while `[dock] show_dock`, taskbar while `[taskbar] enabled` —
/// everything else is ungated and always wanted. Unknown names are wanted
/// (fail open, never strand a child).
pub const Gates = struct {
    dock_show: bool = true,
    taskbar_enabled: bool = false,
};

pub fn wanted(name: []const u8, gates: Gates) bool {
    if (std.mem.eql(u8, name, "dock")) return gates.dock_show;
    if (std.mem.eql(u8, name, "taskbar")) return gates.taskbar_enabled;
    return true;
}

pub fn indexOf(name: []const u8) ?usize {
    for (table, 0..) |c, i| {
        if (std.mem.eql(u8, c.name, name)) return i;
    }
    return null;
}

test "spawn: table completeness + backoff ladder" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 13), table.len);
    var always: usize = 0;
    var demand: usize = 0;
    for (table) |c| {
        if (c.policy == .always) always += 1;
        if (c.policy == .on_demand) demand += 1;
    }
    try t.expectEqual(@as(usize, 9), always);
    try t.expectEqual(@as(usize, 4), demand);
    try t.expectEqual(@as(u64, 0), nextBackoffMs(0));
    try t.expectEqual(@as(u64, 1000), nextBackoffMs(3));
    try t.expectEqual(@as(u64, 30000), nextBackoffMs(9));
    try t.expect(shouldEscalate(3));
    try t.expect(!shouldEscalate(2));
}

test "spawn: settings gates for the bars" {
    const t = std.testing;
    const off = Gates{ .dock_show = false, .taskbar_enabled = false };
    try t.expect(!wanted("dock", off));
    try t.expect(!wanted("taskbar", off));
    // Ungated components stay wanted whatever the settings say.
    try t.expect(wanted("wallpaper", off));
    try t.expect(wanted("notifications", off));
    try t.expect(wanted("no-such-component", off));
    const on = Gates{ .dock_show = true, .taskbar_enabled = true };
    try t.expect(wanted("dock", on));
    try t.expect(wanted("taskbar", on));
    try t.expectEqual(@as(?usize, 3), indexOf("taskbar"));
    try t.expect(indexOf("nope") == null);
}
