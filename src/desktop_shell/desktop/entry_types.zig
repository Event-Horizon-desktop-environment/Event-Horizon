const std = @import("std");

/// Desktop entry + action model.
pub const DesktopEntryAction = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
};

pub const DesktopEntryInfo = struct {
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
};

/// Trim spaces/tabs/CR.
pub fn trimLine(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r')) : (a += 1) {}
    var b = s.len;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\r')) : (b -= 1) {}
    return s[a..b];
}

/// Strip `%f/%F/%u/...` field codes from an Exec line
/// (`strip_exec_field_codes`).
/// `%%` collapses to `%`.
pub fn stripExecFieldCodes(alloc: std.mem.Allocator, exec: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            if (exec[i + 1] == '%') try out.append(alloc, '%');
            i += 1;
            continue;
        }
        try out.append(alloc, exec[i]);
    }
    const s = try out.toOwnedSlice(alloc);
    defer alloc.free(s);
    return alloc.dupe(u8, trimLine(s));
}

/// `strip_namespace_leaf`.
pub fn stripNamespaceLeaf(s: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, s, '.') orelse return s;
    if (dot != 0 and dot + 1 < s.len) return s[dot + 1 ..];
    return s;
}

/// `\040`-style octal escapes in `/proc/mounts` (`decode_mount_escapes`, `:523-539`).
pub fn decodeMountEscapes(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 3 < s.len) {
            const d1 = s[i + 1];
            const d2 = s[i + 2];
            const d3 = s[i + 3];
            if (d1 >= '0' and d1 <= '7' and d2 >= '0' and d2 <= '7' and d3 >= '0' and d3 <= '7') {
                const c: u8 = @intCast((d1 - '0') * 64 + (d2 - '0') * 8 + (d3 - '0'));
                try out.append(alloc, c);
                i += 3;
                continue;
            }
        }
        try out.append(alloc, s[i]);
    }
    return out.toOwnedSlice(alloc);
}

test "entry_types: exec strip + trim" {
    const t = std.testing;
    const a = try stripExecFieldCodes(t.allocator, "firefox %u  ");
    defer t.allocator.free(a);
    try t.expectEqualStrings("firefox", a);
    const b = try stripExecFieldCodes(t.allocator, "echo 100%%");
    defer t.allocator.free(b);
    try t.expectEqualStrings("echo 100%", b);
    try t.expectEqualStrings("resolve", stripNamespaceLeaf("com.blackmagicdesign.resolve"));
    try t.expectEqualStrings("single", stripNamespaceLeaf("single"));
    const c = try decodeMountEscapes(t.allocator, "/run/media/u/My\\040Disk");
    defer t.allocator.free(c);
    try t.expectEqualStrings("/run/media/u/My Disk", c);
}
