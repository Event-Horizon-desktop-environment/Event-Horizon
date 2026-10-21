//! `horizon-wallpaper --set <image>` writes the component file
//! `<state>/wallpaper/wallpaper.toml` so a running instance can pick the new
//! picture up over its inotify watch. That is what makes wallpaper switching
//! possible without porting the whole settings app.
//!
//! The rewrite is line-oriented on purpose: the file is machine-generated, but
//! it also carries keys we have no business touching (bing_*, folder,
//! player_cmd, mode), so only `image` and `enabled` inside `[wallpaper]` are
//! replaced and everything else survives byte for byte.

const std = @import("std");

const kHeader = "# Event Horizon component config — auto-generated.\n";

/// A TOML string literal. Paths are written as literal (single-quoted)
/// strings, which is what the existing generator produces, and fall back to a
/// basic string when the path itself contains a single quote.
pub fn quoteToml(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, s, '\'') == null) {
        return std.fmt.allocPrint(alloc, "'{s}'", .{s});
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.append(alloc, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

/// Is this (trimmed) line an assignment for exactly `key`? `image_extra = x`
/// must not count as `image`.
fn keyIs(line: []const u8, key: []const u8) bool {
    if (!std.mem.startsWith(u8, line, key)) return false;
    const rest = line[key.len..];
    if (rest.len == 0) return false;
    return rest[0] == ' ' or rest[0] == '\t' or rest[0] == '=';
}

/// Rewrites `existing` so `[wallpaper].image` points at `image` and
/// `enabled` is true. Appends the whole table when it is missing, and inserts
/// the individual key when the table exists but lacks it.
pub fn applySetImage(alloc: std.mem.Allocator, existing: []const u8, image: []const u8) ![]u8 {
    const quoted = try quoteToml(alloc, image);
    defer alloc.free(quoted);

    if (std.mem.trim(u8, existing, " \t\r\n").len == 0) {
        return std.fmt.allocPrint(alloc, "{s}\n[wallpaper]\nenabled = true\nimage = {s}\n", .{ kHeader, quoted });
    }

    // Strip exactly one trailing newline: `splitScalar` would otherwise hand
    // us a final empty element and we would write the newline twice.
    const body = if (std.mem.endsWith(u8, existing, "\n")) existing[0 .. existing.len - 1] else existing;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    // The [wallpaper] table is buffered so a key that is missing entirely can
    // be spliced in after its last real line, ahead of any trailing blanks.
    var sec: std.ArrayList(u8) = .empty;
    defer sec.deinit(alloc);

    var in_wallpaper = false;
    var seen_header = false;
    var seen_image = false;
    var seen_enabled = false;
    var content_end: usize = 0;

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        const is_header = trimmed.len > 0 and trimmed[0] == '[';

        if (is_header and in_wallpaper) {
            try spliceSection(alloc, &out, &sec, content_end, quoted, seen_image, seen_enabled);
            in_wallpaper = false;
        }

        if (is_header) {
            if (std.mem.eql(u8, trimmed, "[wallpaper]")) {
                in_wallpaper = true;
                seen_header = true;
            }
        }

        if (in_wallpaper and !is_header and keyIs(trimmed, "image")) {
            try outAppendKey(alloc, &sec, "image = ", quoted);
            seen_image = true;
            content_end = sec.items.len;
            continue;
        }
        if (in_wallpaper and !is_header and keyIs(trimmed, "enabled")) {
            try outAppendKey(alloc, &sec, "enabled = true\n", null);
            seen_enabled = true;
            content_end = sec.items.len;
            continue;
        }

        const dest: *std.ArrayList(u8) = if (in_wallpaper) &sec else &out;
        try outAppendLine(alloc, dest, line);
        if (in_wallpaper and trimmed.len > 0) content_end = sec.items.len;
    }

    if (in_wallpaper) {
        try spliceSection(alloc, &out, &sec, content_end, quoted, seen_image, seen_enabled);
    } else if (!seen_header) {
        if (out.items.len > 0) try out.appendSlice(alloc, "\n");
        try out.appendSlice(alloc, "[wallpaper]\n");
        try out.appendSlice(alloc, "image = ");
        try out.appendSlice(alloc, quoted);
        try out.append(alloc, '\n');
        try out.appendSlice(alloc, "enabled = true\n");
    }

    return out.toOwnedSlice(alloc);
}

fn outAppendLine(alloc: std.mem.Allocator, dest: *std.ArrayList(u8), line: []const u8) !void {
    try dest.appendSlice(alloc, line);
    try dest.append(alloc, '\n');
}

/// `value == null` writes `prefix` verbatim; otherwise `prefix + value + "\n"`.
fn outAppendKey(alloc: std.mem.Allocator, dest: *std.ArrayList(u8), prefix: []const u8, value: ?[]const u8) !void {
    try dest.appendSlice(alloc, prefix);
    if (value) |v| try dest.appendSlice(alloc, v);
    if (value != null) try dest.append(alloc, '\n');
}

fn spliceSection(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    sec: *std.ArrayList(u8),
    content_end: usize,
    quoted: []const u8,
    seen_image: bool,
    seen_enabled: bool,
) !void {
    const end = @min(content_end, sec.items.len);
    try out.appendSlice(alloc, sec.items[0..end]);
    if (!seen_image) {
        try out.appendSlice(alloc, "image = ");
        try out.appendSlice(alloc, quoted);
        try out.append(alloc, '\n');
    }
    if (!seen_enabled) try out.appendSlice(alloc, "enabled = true\n");
    try out.appendSlice(alloc, sec.items[end..]);
    sec.clearRetainingCapacity();
}

test "setimage: an existing table is edited in place" {
    const t = std.testing;
    const src =
        \\# Event Horizon component config — auto-generated.
        \\
        \\[wallpaper]
        \\bing_enabled = false
        \\enabled = true
        \\folder = '/home/matt/Pictures'
        \\image = '/old/one.jpg'
        \\mode = 0
        \\
    ;
    const got = try applySetImage(t.allocator, src, "/new/two.png");
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        \\# Event Horizon component config — auto-generated.
        \\
        \\[wallpaper]
        \\bing_enabled = false
        \\enabled = true
        \\folder = '/home/matt/Pictures'
        \\image = '/new/two.png'
        \\mode = 0
        \\
    , got);
}

test "setimage: a missing key is inserted before the next table" {
    const t = std.testing;
    const src =
        \\[wallpaper]
        \\folder = '/pics'
        \\
        \\[dock]
        \\icon_size = 44
        \\
    ;
    const got = try applySetImage(t.allocator, src, "/pics/new.jpg");
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        \\[wallpaper]
        \\folder = '/pics'
        \\image = '/pics/new.jpg'
        \\enabled = true
        \\
        \\[dock]
        \\icon_size = 44
        \\
    , got);
}

test "setimage: a missing table is appended" {
    const t = std.testing;
    const src = "# nothing here yet\n";
    const got = try applySetImage(t.allocator, src, "/a/b.jpg");
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        \\# nothing here yet
        \\
        \\[wallpaper]
        \\image = '/a/b.jpg'
        \\enabled = true
        \\
    , got);
}

test "setimage: an empty file becomes the canonical component file" {
    const t = std.testing;
    const got = try applySetImage(t.allocator, "", "/a/b.jpg");
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        \\# Event Horizon component config — auto-generated.
        \\
        \\[wallpaper]
        \\enabled = true
        \\image = '/a/b.jpg'
        \\
    , got);
}

test "setimage: keys outside [wallpaper] are left alone" {
    const t = std.testing;
    const src =
        \\image = '/top-level.jpg'
        \\
        \\[wallpaper]
        \\enabled = false
        \\image = '/in-section.jpg'
        \\
    ;
    const got = try applySetImage(t.allocator, src, "/chosen.jpg");
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        \\image = '/top-level.jpg'
        \\
        \\[wallpaper]
        \\enabled = true
        \\image = '/chosen.jpg'
        \\
    , got);
}

test "setimage: quoting survives apostrophes and backslashes" {
    const t = std.testing;
    const lit = try quoteToml(t.allocator, "/plain/path.jpg");
    defer t.allocator.free(lit);
    try t.expectEqualStrings("'/plain/path.jpg'", lit);

    const esc = try quoteToml(t.allocator, "/home/matt/it's a \"test\".png");
    defer t.allocator.free(esc);
    try t.expectEqualStrings("\"/home/matt/it's a \\\"test\\\".png\"", esc);

    // A rewritten path with an apostrophe round-trips through applySetImage.
    const got = try applySetImage(t.allocator, "[wallpaper]\nimage = 'x'\n", "/it's.jpg");
    defer t.allocator.free(got);
    try t.expectEqualStrings("[wallpaper]\nimage = \"/it's.jpg\"\nenabled = true\n", got);
}
