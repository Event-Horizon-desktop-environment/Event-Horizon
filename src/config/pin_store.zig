//! Persisting the dock's `pinned_apps` list back into `dock/dock.toml`.
//!
//! `horizon-settings` is the shell's normal config writer and there is no
//! general config serialiser in the Zig tree yet, so a Pin/Unpin that dumped
//! the whole document would drop every key the loader understands but the
//! dumper does not. This rewrites exactly one array instead: find the
//! `pinned_apps` key inside `[dock]` — `drawer_pinned_apps` and
//! `start_menu_pinned_apps` live in the same section and must be left alone —
//! replace it, and leave every other byte of the file untouched.

const std = @import("std");

const key = "pinned_apps";

/// A line is the pinned list when it *starts* with the key and the next
/// character ends it — `drawer_pinned_apps = []` shares the suffix and must
/// not be mistaken for it.
fn isPinnedKey(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, t, key)) return false;
    if (t.len == key.len) return true;
    const c = t[key.len];
    return c == ' ' or c == '\t' or c == '=';
}

/// The section a `[name]` line opens, or null for a plain line.
fn sectionName(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len < 3 or t[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, t, ']') orelse return null;
    return std.mem.trim(u8, t[1..close], " \t\"'");
}

/// Everything after the `=` on a key line.
fn valueOf(line: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return "";
    return std.mem.trim(u8, line[eq + 1 ..], " \t\r");
}

fn closesArray(line: []const u8) bool {
    return std.mem.endsWith(u8, std.mem.trim(u8, line, " \t\r"), "]");
}

/// TOML: a literal string when it can be one, a basic string otherwise. The
/// ids are desktop-file names so the literal branch is the normal one, but a
/// `'` in an id must not silently truncate the array.
fn quoteInto(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    var simple = s.len > 0;
    for (s) |ch| {
        if (ch == '\'' or ch == '\n' or ch == '\r' or ch < 0x20 or ch == 0x7f) {
            simple = false;
            break;
        }
    }
    if (simple) {
        try out.append(alloc, '\'');
        try out.appendSlice(alloc, s);
        try out.append(alloc, '\'');
        return;
    }
    try out.append(alloc, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => if (ch < 0x20 or ch == 0x7f) {
                var buf: [8]u8 = undefined;
                const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch});
                try out.appendSlice(alloc, esc);
            } else try out.append(alloc, ch),
        }
    }
    try out.append(alloc, '"');
}

/// The key line, in the multi-line form `dock.toml` already uses.
pub fn renderPinned(alloc: std.mem.Allocator, ids: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (ids.len == 0) {
        try out.appendSlice(alloc, "pinned_apps = []");
        return try out.toOwnedSlice(alloc);
    }
    try out.appendSlice(alloc, "pinned_apps = [\n");
    for (ids, 0..) |id, i| {
        try out.appendSlice(alloc, "    ");
        try quoteInto(&out, alloc, id);
        if (i + 1 < ids.len) try out.append(alloc, ',');
        try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, "]");
    return try out.toOwnedSlice(alloc);
}

fn joinInto(out: *std.ArrayList(u8), alloc: std.mem.Allocator, lines: []const []const u8) !void {
    for (lines, 0..) |l, i| {
        if (i > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, l);
    }
}

/// Splice the rendered array into `text`, replacing whatever the pinned list
/// was. `ids` may be empty; a document with no `[dock]` section gets one.
pub fn applyPinned(
    alloc: std.mem.Allocator,
    text: []const u8,
    ids: []const []const u8,
) ![]u8 {
    const rendered = try renderPinned(alloc, ids);
    defer alloc.free(rendered);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| try lines.append(alloc, l);
    }

    var section: []const u8 = "";
    var dock_hdr: ?usize = null;
    var key_idx: ?usize = null;
    var key_end: usize = 0;
    for (lines.items, 0..) |l, i| {
        if (sectionName(l)) |s| {
            section = s;
            if (dock_hdr == null and std.mem.eql(u8, s, "dock")) dock_hdr = i;
            continue;
        }
        if (key_idx != null or !std.mem.eql(u8, section, "dock")) continue;
        if (!isPinnedKey(l)) continue;
        key_idx = i;
        key_end = i + 1;
        // `pinned_apps = [ 'a' ]` closes on its own line; the common
        // multi-line form does not, and everything up to the `]` is the old
        // value whether it spans two lines or twenty.
        if (!closesArray(l)) {
            while (key_end < lines.items.len) : (key_end += 1) {
                if (closesArray(lines.items[key_end])) {
                    key_end += 1;
                    break;
                }
            }
        }
    }

    // Where a `[dock]` that has no pinned list gets one: before the next
    // section, backing up over the blank lines that separate the two so the
    // new key lands inside its own section rather than in the gap. This is
    // only reached when `key_idx` is null.
    var dock_end: usize = 0;
    if (dock_hdr) |h| {
        dock_end = lines.items.len;
        var i = h + 1;
        while (i < lines.items.len) : (i += 1) {
            if (sectionName(lines.items[i]) != null) {
                dock_end = i;
                break;
            }
        }
        while (dock_end > h + 1 and std.mem.trim(u8, lines.items[dock_end - 1], " \t\r").len == 0) {
            dock_end -= 1;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (key_idx) |ks| {
        try joinInto(&out, alloc, lines.items[0..ks]);
        if (ks > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, rendered);
        for (lines.items[key_end..]) |l| {
            try out.append(alloc, '\n');
            try out.appendSlice(alloc, l);
        }
        return try out.toOwnedSlice(alloc);
    }

    if (dock_hdr != null) {
        try joinInto(&out, alloc, lines.items[0..dock_end]);
        if (dock_end > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, rendered);
        for (lines.items[dock_end..]) |l| {
            try out.append(alloc, '\n');
            try out.appendSlice(alloc, l);
        }
        return try out.toOwnedSlice(alloc);
    }

    // No `[dock]` at all: append one, keeping whatever the document already
    // had and its trailing newline convention intact.
    if (text.len > 0) try out.appendSlice(alloc, text);
    if (text.len > 0 and !std.mem.endsWith(u8, text, "\n")) try out.append(alloc, '\n');
    try out.appendSlice(alloc, "[dock]\n");
    try out.appendSlice(alloc, rendered);
    if (std.mem.endsWith(u8, text, "\n")) try out.append(alloc, '\n');
    return try out.toOwnedSlice(alloc);
}

/// Read-modify-write `path`. Missing or unreadable files are created, so a
/// Pin on a box that has never written a dock config still sticks.
pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    ids: []const []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch "";
    defer if (existing.len > 0) gpa.free(existing);
    const updated = try applyPinned(gpa, existing, ids);
    defer gpa.free(updated);
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = path, .data = updated });
}

test "pin-store: only the pinned key moves, and only inside [dock]" {
    const t = std.testing;
    const alloc = t.allocator;

    const src =
        \\# comment
        \\[dock]
        \\icon_size = 44
        \\drawer_pinned_apps = []
        \\pinned_apps = [
        \\    'a',
        \\    'b'
        \\]
        \\start_menu_pinned_apps = []
        \\
        \\[panel]
        \\pinned_apps = [ 'leave-me' ]
        \\
    ;
    const out = try applyPinned(alloc, src, &.{ "x", "y" });
    defer alloc.free(out);
    const want =
        \\# comment
        \\[dock]
        \\icon_size = 44
        \\drawer_pinned_apps = []
        \\pinned_apps = [
        \\    'x',
        \\    'y'
        \\]
        \\start_menu_pinned_apps = []
        \\
        \\[panel]
        \\pinned_apps = [ 'leave-me' ]
        \\
    ;
    try t.expectEqualStrings(want, out);

    // The other section's array is untouched even though `[dock]` was rewritten.
    try t.expect(std.mem.indexOf(u8, out, "'leave-me'") != null);
    try t.expect(std.mem.indexOf(u8, out, "drawer_pinned_apps = []") != null);
}

test "pin-store: inline arrays, empty lists and missing sections" {
    const t = std.testing;
    const alloc = t.allocator;

    const inline_src = "[dock]\npinned_apps = [ 'one' ]\nopacity = 23\n";
    const out = try applyPinned(alloc, inline_src, &.{});
    defer alloc.free(out);
    try t.expectEqualStrings("[dock]\npinned_apps = []\nopacity = 23\n", out);

    const bare = "[panel]\nfoo = 1\n";
    const added = try applyPinned(alloc, bare, &.{"steam"});
    defer alloc.free(added);
    try t.expectEqualStrings("[panel]\nfoo = 1\n[dock]\npinned_apps = [\n    'steam'\n]\n", added);

    const empty_doc = try applyPinned(alloc, "", &.{"steam"});
    defer alloc.free(empty_doc);
    try t.expectEqualStrings("[dock]\npinned_apps = [\n    'steam'\n]", empty_doc);

    const no_trailing = try applyPinned(alloc, "[dock]\nicon_size = 44", &.{"a"});
    defer alloc.free(no_trailing);
    try t.expectEqualStrings("[dock]\nicon_size = 44\npinned_apps = [\n    'a'\n]", no_trailing);
}

test "pin-store: ids that are not plain words survive the round trip" {
    const t = std.testing;
    const alloc = t.allocator;
    const plain = try renderPinned(alloc, &.{"plain"});
    defer alloc.free(plain);
    try t.expectEqualStrings("pinned_apps = [\n    'plain'\n]", plain);
    const tricky = try renderPinned(alloc, &.{ "it's", "quo\"te" });
    defer alloc.free(tricky);
    // `it's` needs a basic string; `quo"te` still qualifies for a literal one,
    // and a literal string is the better choice because it needs no escaping.
    try t.expectEqualStrings("pinned_apps = [\n    \"it's\",\n    'quo\"te'\n]", tricky);
}
