//! Upserting scalar keys into one section of a per-component TOML file.
//!
//! `horizon-settings` is the shell's config writer, but the Zig tree has no
//! general serialiser yet: dumping a `ShellConfig` back out would drop every
//! key the loader understands and the dumper does not. So a save edits only
//! the keys it owns — inside the one section it owns — and leaves every other
//! byte of the file alone, exactly the way `pin_store.zig` rewrites
//! `pinned_apps`. Where `pin_store` handles one array key, this handles a
//! batch of scalars in a single pass, so one settings change writes the file
//! once instead of once per field.

const std = @import("std");
const toml = @import("toml.zig");

/// One key to force inside the section. `value` is the rendered right-hand
/// side — `true`, `44`, `'DP-1'` — so quoting stays with the caller that
/// knows what kind of thing it is writing.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

pub fn boolValue(v: bool) []const u8 {
    return if (v) "true" else "false";
}

pub fn intValue(alloc: std.mem.Allocator, v: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{d}", .{v});
}

/// Rendered with a decimal point even for a whole number: a float field read
/// back as an integer still works (`setScale` accepts both), but a writer
/// should not silently change the type of a value it is only refreshing.
pub fn floatValue(alloc: std.mem.Allocator, v: f64) ![]u8 {
    const s = try std.fmt.allocPrint(alloc, "{d}", .{v});
    if (std.mem.indexOfAny(u8, s, ".eEnN") != null) return s;
    defer alloc.free(s);
    return std.fmt.allocPrint(alloc, "{s}.0", .{s});
}

/// TOML string: a literal when it can be one, a basic string otherwise. The
/// values here are monitor names and paths, so the literal branch is the
/// normal one — but a `'` in a path must not silently truncate the value.
pub fn stringValue(alloc: std.mem.Allocator, v: []const u8) ![]u8 {
    var simple = v.len > 0;
    for (v) |ch| {
        if (ch == '\'' or ch == '\n' or ch == '\r' or ch < 0x20 or ch == 0x7f) {
            simple = false;
            break;
        }
    }
    if (simple) return std.fmt.allocPrint(alloc, "'{s}'", .{v});

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '"');
    for (v) |ch| {
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
    return out.toOwnedSlice(alloc);
}

/// Render a string array in the multi-line literal form `dock.toml` uses:
/// `[\n    'a',\n    'b'\n]`, or `[]` when empty. Items reuse `stringValue`
/// quoting, so a `'` in an id cannot truncate the array. Returned text is the
/// right-hand side only; `emit` adds `key = `. `applySection` recognises the
/// opener line and replaces the whole block (continuations included) on the
/// next save.
pub fn arrayValue(alloc: std.mem.Allocator, ids: []const []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    if (ids.len == 0) return alloc.dupe(u8, "[]");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "[\n");
    for (ids, 0..) |id, i| {
        const q = try stringValue(aa, id);
        try out.appendSlice(alloc, "    ");
        try out.appendSlice(alloc, q);
        if (i + 1 < ids.len) try out.append(alloc, ',');
        try out.append(alloc, '\n');
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

/// The section a `[name]` line opens, or null for a plain line.
fn sectionName(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len < 3 or t[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, t, ']') orelse return null;
    return std.mem.trim(u8, t[1..close], " \t\"'");
}

/// The key a line assigns, or null when the line cannot start one. A
/// continuation line of a multi-line array has no `=`, so it returns null and
/// rides along with the line that did match.
fn keyOf(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#' or t[0] == '[') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    const k = std.mem.trim(u8, t[0..eq], " \t");
    if (k.len == 0) return null;
    return k;
}

fn valueOf(line: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return "";
    return std.mem.trim(u8, line[eq + 1 ..], " \t\r");
}

/// True when the value opens a `[` that this line does not close — the
/// multi-line array form `dock.toml` uses for every app list.
fn opensArray(line: []const u8) bool {
    const v = std.mem.trim(u8, valueOf(line), " \t");
    return v.len > 0 and v[0] == '[' and !std.mem.endsWith(u8, v, "]");
}

fn closesArray(line: []const u8) bool {
    return std.mem.endsWith(u8, std.mem.trim(u8, line, " \t\r"), "]");
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

fn findEntry(entries: []const Entry, k: []const u8) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.key, k)) return i;
    }
    return null;
}

/// Render one `key = value` line and remember it so it can be released with
/// the rest once the document has been joined back together.
fn emit(
    alloc: std.mem.Allocator,
    rendered: *std.ArrayList([]const u8),
    e: Entry,
) ![]const u8 {
    const line = try std.fmt.allocPrint(alloc, "{s} = {s}", .{ e.key, e.value });
    errdefer alloc.free(line);
    try rendered.append(alloc, line);
    return line;
}

/// Force every `entries` key inside `[section]`, adding the ones that are not
/// there yet. A document with no such section gets one appended at the end.
/// Anything outside the section — including a same-named key in another
/// section — is byte-for-byte preserved.
pub fn applySection(
    alloc: std.mem.Allocator,
    text: []const u8,
    section: []const u8,
    entries: []const Entry,
) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| try lines.append(alloc, l);
    }

    var start: ?usize = null;
    for (lines.items, 0..) |l, i| {
        if (sectionName(l)) |s| {
            if (std.mem.eql(u8, s, section)) {
                start = i;
                break;
            }
        }
    }

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(alloc);
    // Every line this call rendered. `out` borrows them for the join below;
    // they are released together once the result is a single buffer.
    var rendered: std.ArrayList([]const u8) = .empty;
    defer {
        for (rendered.items) |l| alloc.free(l);
        rendered.deinit(alloc);
    }
    const matched = try alloc.alloc(bool, entries.len);
    defer alloc.free(matched);
    @memset(matched, false);

    if (start) |s| {
        var end: usize = lines.items.len;
        for (s + 1..lines.items.len) |i| {
            if (sectionName(lines.items[i]) != null) {
                end = i;
                break;
            }
        }

        try out.appendSlice(alloc, lines.items[0 .. s + 1]);
        var i: usize = s + 1;
        while (i < end) : (i += 1) {
            const l = lines.items[i];
            if (keyOf(l)) |k| {
                if (findEntry(entries, k)) |ei| {
                    if (!matched[ei]) {
                        matched[ei] = true;
                        try out.append(alloc, try emit(alloc, &rendered, entries[ei]));
                        // A multi-line array continues on the lines below;
                        // replacing the opener must take them with it.
                        if (opensArray(l)) {
                            while (i + 1 < end and !closesArray(lines.items[i + 1])) : (i += 1) {}
                            if (i + 1 < end) i += 1;
                        }
                        continue;
                    }
                }
            }
            try out.append(alloc, l);
        }

        // New keys join the section where its content ends, not after the
        // blank lines that separate it from the next header.
        var insert_at = out.items.len;
        while (insert_at > s + 1 and isBlank(out.items[insert_at - 1])) insert_at -= 1;
        for (entries, 0..) |e, ei| {
            if (matched[ei]) continue;
            const line = try emit(alloc, &rendered, e);
            try out.insertSlice(alloc, insert_at, &.{line});
            insert_at += 1;
        }
        try out.appendSlice(alloc, lines.items[end..]);
    } else {
        try out.appendSlice(alloc, lines.items);
        while (out.items.len > 0 and isBlank(out.items[out.items.len - 1])) _ = out.pop();
        try out.append(alloc, "");
        {
            const header = try std.fmt.allocPrint(alloc, "[{s}]", .{section});
            errdefer alloc.free(header);
            try rendered.append(alloc, header);
            try out.append(alloc, header);
        }
        for (entries) |e| {
            try out.append(alloc, try emit(alloc, &rendered, e));
        }
    }

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (out.items, 0..) |l, i| {
        if (i > 0) try joined.append(alloc, '\n');
        try joined.appendSlice(alloc, l);
    }
    return joined.toOwnedSlice(alloc);
}

/// Read `path` (missing file is fine), apply, write back.
pub fn save(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    section: []const u8,
    entries: []const Entry,
) !void {
    const cwd = std.Io.Dir.cwd();
    const existing = cwd.readFileAlloc(io, path, alloc, .limited(1 << 20)) catch "";
    defer if (existing.len > 0) alloc.free(existing);
    const updated = try applySection(alloc, existing, section, entries);
    defer alloc.free(updated);
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    // Write a sibling temp file and rename it over the target. Every reader
    // of these files is *another process* watching for changes (dock,
    // taskbar, desktop, notifications, the supervisor's gates), and the old
    // in-place truncate+write let one of them read a half-written file —
    // an empty one parses as "all defaults", which reads as a flash of the
    // design opacity while a slider is being dragged. The watchers sit on
    // the *directory* and take IN_MOVE, so they still see this.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = updated });
    cwd.rename(tmp, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
}

fn expectRoundTrip(alloc: std.mem.Allocator, src: []const u8, want: []const u8) !void {
    const out = try applySection(alloc, src, "dock", &.{
        .{ .key = "icon_size", .value = "50" },
        .{ .key = "output", .value = "'DP-3'" },
    });
    defer alloc.free(out);
    try std.testing.expectEqualStrings(want, out);
}

test "section-store: replaces, appends and leaves other sections alone" {
    const alloc = std.testing.allocator;
    try expectRoundTrip(alloc,
        \\# comment
        \\[dock]
        \\icon_size = 44
        \\drawer_pinned_apps = []
        \\
        \\[panel]
        \\icon_size = 12
        \\
    ,
        \\# comment
        \\[dock]
        \\icon_size = 50
        \\drawer_pinned_apps = []
        \\output = 'DP-3'
        \\
        \\[panel]
        \\icon_size = 12
        \\
    );
}

test "section-store: a same-named key in another section is untouched" {
    const alloc = std.testing.allocator;
    const src =
        \\[panel]
        \\output = 'DP-1'
        \\
        \\[dock]
        \\radius = 18
        \\
    ;
    const out = try applySection(alloc, src, "dock", &.{.{ .key = "output", .value = "'DP-2'" }});
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\[panel]
        \\output = 'DP-1'
        \\
        \\[dock]
        \\radius = 18
        \\output = 'DP-2'
        \\
    , out);
}

test "section-store: a missing section is appended" {
    const alloc = std.testing.allocator;
    const out = try applySection(alloc, "[panel]\nfoo = 1\n", "dock", &.{.{ .key = "radius", .value = "24" }});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("[panel]\nfoo = 1\n\n[dock]\nradius = 24", out);
}

test "section-store: a multi-line array opener takes its rows with it" {
    const alloc = std.testing.allocator;
    const src =
        \\[dock]
        \\pinned_apps = [
        \\    'a',
        \\    'b'
        \\]
        \\radius = 18
        \\
    ;
    const out = try applySection(alloc, src, "dock", &.{.{ .key = "pinned_apps", .value = "[ 'c' ]" }});
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\[dock]
        \\pinned_apps = [ 'c' ]
        \\radius = 18
        \\
    , out);
}

test "section-store: arrays render multiline and replace as one block" {
    const t = std.testing;
    const alloc = t.allocator;

    const rendered = try arrayValue(alloc, &.{ "smenu", "media" });
    defer alloc.free(rendered);
    try t.expectEqualStrings("[\n    'smenu',\n    'media'\n]", rendered);

    const empty = try arrayValue(alloc, &.{});
    defer alloc.free(empty);
    try t.expectEqualStrings("[]", empty);

    // A save forces the array key and leaves the neighbouring multiline
    // array (pinned_apps) byte-for-byte alone.
    const src =
        \\[dock]
        \\pinned_apps = [
        \\    'a',
        \\    'b'
        \\]
        \\left_widgets = [ 'old' ]
        \\
    ;
    const arr = try arrayValue(alloc, &.{ "smenu", "media" });
    defer alloc.free(arr);
    const out = try applySection(alloc, src, "dock", &.{.{ .key = "left_widgets", .value = arr }});
    defer alloc.free(out);
    var doc = try toml.parse(alloc, out);
    defer doc.deinit();
    const dock_tbl = doc.table("dock").?.table;
    try t.expectEqual(@as(usize, 2), dock_tbl.get("left_widgets").?.array.len);
    try t.expectEqual(@as(usize, 2), dock_tbl.get("pinned_apps").?.array.len);
    try t.expectEqualStrings("smenu", dock_tbl.get("left_widgets").?.array[0].string);
}

test "section-store: rendered values parse back as the right types" {
    const t = std.testing;
    const alloc = t.allocator;
    try t.expectEqualStrings("true", boolValue(true));
    try t.expectEqualStrings("false", boolValue(false));

    const i = try intValue(alloc, -5);
    defer alloc.free(i);
    const f = try floatValue(alloc, 1.0);
    defer alloc.free(f);
    const s = try stringValue(alloc, "DP-1");
    defer alloc.free(s);
    const q = try stringValue(alloc, "don't");
    defer alloc.free(q);

    const text = try std.fmt.allocPrint(alloc, "i = {s}\nf = {s}\ns = {s}\nq = {s}\n", .{ i, f, s, q });
    defer alloc.free(text);
    var doc = try toml.parse(alloc, text);
    defer doc.deinit();

    try t.expect(doc.get("i").?.integer == -5);
    try t.expectApproxEqAbs(@as(f64, 1.0), doc.get("f").?.float, 1e-9);
    try t.expectEqualStrings("DP-1", doc.get("s").?.string);
    try t.expectEqualStrings("don't", doc.get("q").?.string);
}
