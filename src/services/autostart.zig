const std = @import("std");
const linux = std.os.linux;

pub const Entry = struct {
    name: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    try_exec: []const u8 = "",
    hidden: bool = false,
    no_display: bool = false,
    terminal: bool = false,
    only_show_in: []const u8 = "",
    not_show_in: []const u8 = "",
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        if (self.arena) |a| {
            const child = a.child_allocator;
            a.deinit();
            child.destroy(a);
            self.arena = null;
        } else {
            _ = alloc;
        }
    }
};

fn parseBool(v: []const u8) bool {
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
}

pub fn parseDesktopFile(alloc: std.mem.Allocator, data: []const u8) !Entry {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var e = Entry{ .arena = arena };
    var in_desktop = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_desktop = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_desktop) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const val = try aa.dupe(u8, line[eq + 1 ..]);
        if (std.mem.eql(u8, key, "Name")) e.name = val;
        if (std.mem.eql(u8, key, "Exec")) e.exec = val;
        if (std.mem.eql(u8, key, "Icon")) e.icon = val;
        if (std.mem.eql(u8, key, "TryExec")) e.try_exec = val;
        if (std.mem.eql(u8, key, "Hidden")) e.hidden = parseBool(val);
        if (std.mem.eql(u8, key, "NoDisplay")) e.no_display = parseBool(val);
        if (std.mem.eql(u8, key, "Terminal")) e.terminal = parseBool(val);
        if (std.mem.eql(u8, key, "OnlyShowIn")) e.only_show_in = val;
        if (std.mem.eql(u8, key, "NotShowIn")) e.not_show_in = val;
    }
    return e;
}

pub fn listContains(list: []const u8, item: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ';');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, item)) return true;
    }
    return false;
}

pub fn shouldRun(e: *const Entry, desktop_env: []const u8) bool {
    if (e.hidden or e.no_display) return false;
    if (e.exec.len == 0) return false;
    if (e.only_show_in.len > 0 and !listContains(e.only_show_in, desktop_env)) return false;
    if (e.not_show_in.len > 0 and listContains(e.not_show_in, desktop_env)) return false;
    return true;
}

pub fn expandFieldCodes(alloc: std.mem.Allocator, exec: []const u8, file_arg: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < exec.len) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            const code = exec[i + 1];
            switch (code) {
                'f', 'F', 'u', 'U' => {
                    if (file_arg) |f| try out.appendSlice(alloc, f);
                    i += 2;
                    continue;
                },
                'i', 'c', 'k' => {
                    i += 2;
                    continue;
                },
                '%' => {
                    try out.append(alloc, '%');
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try out.append(alloc, exec[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

test "autostart: desktop entry parse + filter" {
    const t = std.testing;
    const data =
        \\[Desktop Entry]
        \\Name=Foo
        \\Exec=foo %F
        \\TryExec=foo
        \\Hidden=false
        \\OnlyShowIn=Hyprland;Niri;
        \\
    ;
    var e = try parseDesktopFile(t.allocator, data);
    defer e.deinit(t.allocator);
    try t.expectEqualStrings("Foo", e.name);
    try t.expectEqualStrings("foo %F", e.exec);
    try t.expect(shouldRun(&e, "Hyprland"));
    try t.expect(!shouldRun(&e, "Sway"));
    var e2 = try parseDesktopFile(t.allocator, "[Desktop Entry]\nHidden=true\nExec=x\n");
    defer e2.deinit(t.allocator);
    try t.expect(!shouldRun(&e2, "Hyprland"));
}

test "autostart: field code expansion" {
    const t = std.testing;
    const a = try expandFieldCodes(t.allocator, "foo %F --bar", "/tmp/x");
    defer t.allocator.free(a);
    try t.expectEqualStrings("foo /tmp/x --bar", a);
    const b = try expandFieldCodes(t.allocator, "foo %% %i", null);
    defer t.allocator.free(b);
    try t.expectEqualStrings("foo % ", b);
}

/// Children we started but have not reaped yet. App launches outlive a single
/// call, so the list is global and drained opportunistically — every new spawn
/// and `reapChildren()` from a periodic tick keep zombies from piling up.
var spawned: std.ArrayList(std.posix.pid_t) = .empty;
var spawned_init = false;

/// Reaps exited children without blocking.
pub fn reapChildren() void {
    if (!spawned_init) {
        spawned = .empty;
        spawned_init = true;
    }
    var i: usize = 0;
    while (i < spawned.items.len) {
        const pid = spawned.items[i];
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.wait4(pid, &status, linux.W.NOHANG, null));
        if (rc == pid or rc < 0) {
            _ = spawned.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Spawns `argv` with stdio detached from ours and remembers it for reaping.
/// Returns once the child exists — the caller never waits for it.
///
/// The child also detaches itself into a fresh process group before exec
/// (`.pgid = 0` is the child running `setpgid(0, 0)`): an app launched from
/// the dock or the taskbar must not share the bar's group. Every death the
/// bars can die is a *group* or a *parent* event — SIGKILL from the parent
/// guard their own parent death carries, Ctrl+C in the terminal that started
/// the session, `pkill`-by-group — and none of those should reach the app.
/// With its own group the app is reparented and keeps running, the same
/// shape `launch_exec_command` reaches with its double-fork + `setsid` in
/// taskbar.cpp. Group changes leave parentage alone, so the app stays our
/// direct child and `reapChildren` collects it exactly as before.
pub fn spawnDetached(io: std.Io, argv: []const []const u8) !void {
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    if (child.id) |pid| {
        if (!spawned_init) {
            spawned = .empty;
            spawned_init = true;
        }
        spawned.append(std.heap.page_allocator, pid) catch {};
    }
    reapChildren();
}
