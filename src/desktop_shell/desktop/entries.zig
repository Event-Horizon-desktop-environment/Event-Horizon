const std = @import("std");
const et = @import("entry_types.zig");

/// Full `[Desktop Entry]` + `[Desktop Action *]` parser:
/// keys `Type/Name/Icon/Exec/StartupWMClass/URL/DBusActivatable/Terminal/
/// Hidden/NoDisplay/TryExec/OnlyShowIn|NotShowIn(;,,)/X-GNOME-Autostart-enabled|
/// Delay/Actions` plus per-action `Name/Exec/Icon`, ordered by `Actions=`.
///
/// All slices borrow from the input text (or caller-owned copies); the
/// `actions` slice is allocated.

pub const Action = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
};

pub const Entry = struct {
    entry_type: []const u8 = "application",
    name: []const u8 = "",
    icon: []const u8 = "",
    exec: []const u8 = "",
    url: []const u8 = "",
    dbus_activatable: bool = false,
    terminal: bool = false,
    startup_wm_class: []const u8 = "",
    hidden: bool = false,
    no_display: bool = false,
    try_exec: []const u8 = "",
    autostart_enabled: bool = true,
    autostart_delay_sec: i32 = 0,
    actions: []Action = &.{},
};

fn isTrue(v: []const u8) bool {
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
}

fn sectionName(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return null;
    return line[1 .. line.len - 1];
}

fn splitList(s: []const u8) std.mem.SplitIterator(u8, .sequence) {
    return std.mem.splitSequence(u8, s, ";");
}

pub fn readEntry(alloc: std.mem.Allocator, text: []const u8) !Entry {
    var e = Entry{};
    var actions_order: [32][]const u8 = undefined;
    var actions_n: usize = 0;
    // First pass: main section + action order.
    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = et.trimLine(std.mem.trimEnd(u8, raw, "\r"));
        if (line.len == 0 or line[0] == '#') continue;
        if (sectionName(line)) |name| {
            section = name;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = et.trimLine(line[0..eq]);
        const val = et.trimLine(line[eq + 1 ..]);
        if (std.mem.eql(u8, section, "Desktop Entry")) {
            if (eqFold(key, "type")) e.entry_type = val;
            if (eqFold(key, "name")) e.name = val;
            if (eqFold(key, "icon")) e.icon = val;
            if (eqFold(key, "exec")) e.exec = val;
            if (eqFold(key, "url")) e.url = val;
            if (eqFold(key, "startupwmclass")) e.startup_wm_class = val;
            if (eqFold(key, "tryexec")) e.try_exec = val;
            if (eqFold(key, "dbusactivatable")) e.dbus_activatable = isTrue(val);
            if (eqFold(key, "terminal")) e.terminal = isTrue(val);
            if (eqFold(key, "hidden")) e.hidden = isTrue(val);
            if (eqFold(key, "nodisplay")) e.no_display = isTrue(val);
            if (eqFold(key, "x-gnome-autostart-enabled")) e.autostart_enabled = !std.mem.eql(u8, val, "false");
            if (eqFold(key, "x-gnome-autostart-delay")) e.autostart_delay_sec = std.fmt.parseInt(i32, val, 10) catch e.autostart_delay_sec;
            if (eqFold(key, "actions")) {
                var li = splitList(val);
                while (li.next()) |part| {
                    const p = et.trimLine(part);
                    if (p.len == 0 or actions_n >= actions_order.len) continue;
                    actions_order[actions_n] = p;
                    actions_n += 1;
                }
            }
        }
    }
    // Second pass: per-action sections.
    var acts: std.ArrayList(Action) = .empty;
    errdefer acts.deinit(alloc);
    for (actions_order[0..actions_n]) |aid| {
        var a = Action{ .id = aid };
        var want: [64]u8 = undefined;
        const hdr = std.fmt.bufPrint(&want, "Desktop Action {s}", .{aid}) catch continue;
        section = "";
        var it2 = std.mem.splitScalar(u8, text, '\n');
        while (it2.next()) |raw| {
            const line = et.trimLine(std.mem.trimEnd(u8, raw, "\r"));
            if (line.len == 0 or line[0] == '#') continue;
            if (sectionName(line)) |name| {
                section = name;
                continue;
            }
            if (!std.mem.eql(u8, section, hdr)) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = et.trimLine(line[0..eq]);
            const val = et.trimLine(line[eq + 1 ..]);
            if (eqFold(key, "name")) a.name = val;
            if (eqFold(key, "exec")) a.exec = val;
            if (eqFold(key, "icon")) a.icon = val;
        }
        if (a.name.len > 0 and a.exec.len > 0) try acts.append(alloc, a);
    }
    e.actions = try acts.toOwnedSlice(alloc);
    if (e.entry_type.len == 0) e.entry_type = "application";
    return e;
}

fn eqFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |c1, c2| {
        if (std.ascii.toLower(c1) != std.ascii.toLower(c2)) return false;
    }
    return true;
}

/// Normalize an app-id for lookup:
/// lowercase, strip `.desktop`, keep full + first dot segment candidates.
pub fn normalizeAppId(alloc: std.mem.Allocator, app_id: []const u8) ![]u8 {
    var s = try alloc.dupe(u8, app_id);
    for (s) |*c| c.* = std.ascii.toLower(c.*);
    if (std.mem.endsWith(u8, s, ".desktop")) {
        alloc.free(s);
        s = try alloc.dupe(u8, app_id[0 .. app_id.len - 8]);
        for (s) |*c| c.* = std.ascii.toLower(c.*);
    }
    return s;
}

/// Known generic runtime binaries skipped during stream→entry resolution
/// (`is_generic_runtime_binary`: chromium/chrome/electron/node/python/java/wine…).
pub fn isGenericRuntimeBinary(base: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n: usize = @min(base.len, 64);
    for (0..n) |i| buf[i] = std.ascii.toLower(base[i]);
    const l = buf[0..n];
    for ([_][]const u8{ "chromium", "chrome", "electron", "node", "python", "java", "wine", "perl", "ruby", "bash", "sh", "flatpak", "snap" }) |g| {
        if (std.mem.indexOf(u8, l, g) != null) return true;
    }
    return false;
}

test "entries: full desktop file + actions order" {
    const t = std.testing;
    const text =
        "[Desktop Entry]\nName=Foo\nExec=foo %u\nIcon=foo\nType=Application\nActions=NewWindow;Settings;\n" ++
        "[Desktop Action Settings]\nName=Settings\nExec=foo --settings\n" ++
        "[Desktop Action NewWindow]\nName=New Window\nExec=foo --new\n";
    const e = try readEntry(t.allocator, text);
    defer t.allocator.free(e.actions);
    try t.expectEqualStrings("Foo", e.name);
    try t.expectEqualStrings("foo %u", e.exec);
    try t.expectEqual(@as(usize, 2), e.actions.len);
    // Ordered by Actions= list, not file order.
    try t.expectEqualStrings("NewWindow", e.actions[0].id);
    try t.expectEqualStrings("New Window", e.actions[0].name);
    try t.expectEqualStrings("Settings", e.actions[1].id);
}

test "entries: normalize + generic runtimes" {
    const t = std.testing;
    const n = try normalizeAppId(t.allocator, "Firefox.Desktop");
    defer t.allocator.free(n);
    try t.expectEqualStrings("firefox", n);
    try t.expect(isGenericRuntimeBinary("electron"));
    try t.expect(isGenericRuntimeBinary("python3.11"));
    try t.expect(!isGenericRuntimeBinary("firefox"));
}
