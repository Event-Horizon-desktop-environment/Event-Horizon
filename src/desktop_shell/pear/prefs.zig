//! Pear toggle persistence: line-oriented TOML key upserts into component
//! files (`~/.config/Event-Horizon/<component>/<component>.toml`), following the
//! `wallpaper/setimage.zig` discipline — only the one key inside its table
//! is replaced, everything else survives byte for byte, and running
//! components pick the change up over their inotify watches.
//!
//! - DND → `notifications/notifications.toml`, `[notifications] do_not_disturb`
//! - Night light → `general/general.toml`, `[nightlight] enabled`
//! - Theme mode → `appearance/appearance.toml`, `[appearance] matugen_mode`

const std = @import("std");

fn keyIs(line: []const u8, key: []const u8) bool {
    if (!std.mem.startsWith(u8, line, key)) return false;
    const rest = line[key.len..];
    if (rest.len == 0) return false;
    return rest[0] == ' ' or rest[0] == '\t' or rest[0] == '=';
}

/// Upsert `key = value` inside `[table]` (appending table/key when missing).
/// Returns the new file content, owned by the caller.
pub fn upsertKey(alloc: std.mem.Allocator, existing: []const u8, table: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (std.mem.trim(u8, existing, " \t\r\n").len == 0) {
        return std.fmt.allocPrint(alloc, "[{s}]\n{s} = {s}\n", .{ table, key, value });
    }
    const body = if (std.mem.endsWith(u8, existing, "\n")) existing[0 .. existing.len - 1] else existing;
    var in_table = false;
    var seen_table = false;
    var seen_key = false;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (in_table and !seen_key) {
                try out.appendSlice(alloc, key);
                try out.appendSlice(alloc, " = ");
                try out.appendSlice(alloc, value);
                try out.append(alloc, '\n');
                seen_key = true;
            }
            const name = if (trimmed.len >= 2 and trimmed[trimmed.len - 1] == ']') trimmed[1 .. trimmed.len - 1] else "";
            in_table = std.mem.eql(u8, std.mem.trim(u8, name, " \t"), table);
            if (in_table) seen_table = true;
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
            continue;
        }
        if (in_table and !seen_key and keyIs(trimmed, key)) {
            try out.appendSlice(alloc, key);
            try out.appendSlice(alloc, " = ");
            try out.appendSlice(alloc, value);
            try out.append(alloc, '\n');
            seen_key = true;
            continue;
        }
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    if (!seen_table) {
        try out.append(alloc, '\n');
        try out.appendSlice(alloc, "[");
        try out.appendSlice(alloc, table);
        try out.appendSlice(alloc, "]\n");
        try out.appendSlice(alloc, key);
        try out.appendSlice(alloc, " = ");
        try out.appendSlice(alloc, value);
        try out.append(alloc, '\n');
    } else if (in_table and !seen_key) {
        try out.appendSlice(alloc, key);
        try out.appendSlice(alloc, " = ");
        try out.appendSlice(alloc, value);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// Write one key into a component file (creating parent dirs). Best-effort:
// false on any IO failure (the toggle still paints locally).
pub fn writeComponentKey(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8, component: []const u8, table: []const u8, key: []const u8, value: []const u8) bool {
    const path = std.fs.path.join(alloc, &.{ state_dir, component, component }) catch return false;
    // "<state>/<component>/<component>" + ".toml"
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(alloc);
    full.appendSlice(alloc, path) catch {
        alloc.free(path);
        return false;
    };
    alloc.free(path);
    full.appendSlice(alloc, ".toml") catch return false;
    const file_path = full.items;
    // Ensure the component dir exists (creating it first).
    if (std.fs.path.dirname(file_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    const cwd = std.Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, file_path, alloc, .limited(1 << 20)) catch "";
    defer if (existing.len > 0) alloc.free(existing);
    const next = upsertKey(alloc, existing, table, key, value) catch return false;
    defer alloc.free(next);
    cwd.writeFile(io, .{ .sub_path = file_path, .data = next }) catch return false;
    return true;
}

pub fn setDnd(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8, on: bool) bool {
    return writeComponentKey(alloc, io, state_dir, "notifications", "notifications", "do_not_disturb", if (on) "true" else "false");
}

pub fn setNightLight(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8, on: bool) bool {
    return writeComponentKey(alloc, io, state_dir, "general", "nightlight", "enabled", if (on) "true" else "false");
}

pub fn setThemeMode(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8, dark: bool) bool {
    return writeComponentKey(alloc, io, state_dir, "appearance", "appearance", "matugen_mode", if (dark) "\"dark\"" else "\"light\"");
}

test "pear-prefs: upsert replaces, inserts and appends" {
    const t = std.testing;
    // Replace in place, neighbours survive.
    const a = try upsertKey(t.allocator, "[notifications]\ndo_not_disturb = false\nother = 1\n", "notifications", "do_not_disturb", "true");
    defer t.allocator.free(a);
    try t.expect(std.mem.indexOf(u8, a, "do_not_disturb = true") != null);
    try t.expect(std.mem.indexOf(u8, a, "other = 1") != null);
    // `do_not_disturb_extra` must not match `do_not_disturb`.
    const b = try upsertKey(t.allocator, "[notifications]\ndo_not_disturb_extra = 1\n", "notifications", "do_not_disturb", "true");
    defer t.allocator.free(b);
    try t.expect(std.mem.indexOf(u8, b, "do_not_disturb_extra = 1") != null);
    try t.expect(std.mem.indexOf(u8, b, "\ndo_not_disturb = true") != null);
    // Missing table appends.
    const c = try upsertKey(t.allocator, "[other]\nx = 1\n", "nightlight", "enabled", "true");
    defer t.allocator.free(c);
    try t.expect(std.mem.indexOf(u8, c, "[nightlight]\nenabled = true") != null);
    // Empty file seeds.
    const d = try upsertKey(t.allocator, "", "appearance", "matugen_mode", "\"dark\"");
    defer t.allocator.free(d);
    try t.expectEqualStrings("[appearance]\nmatugen_mode = \"dark\"\n", d);
}
