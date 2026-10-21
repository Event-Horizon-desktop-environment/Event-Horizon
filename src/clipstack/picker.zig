//! ClipStack picker model — rows, filtering, selection and the label text
//! the picker paints. Pure data: no Wayland, no cairo, so the filter and
//! selection behavior is unit-testable and the UI half stays thin.

const std = @import("std");
const store = @import("store.zig");

pub const Row = struct {
    id: u64,
    kind: store.Kind,
    captured_ms: i64,
    size: u64,
    /// Display label, allocated by the caller (the picker's label arena).
    label: []const u8,
};

pub const Model = struct {
    /// All rows, newest first (the store's order).
    rows: std.ArrayList(Row) = .empty,
    /// Indices into `rows` matching the current query.
    filtered: std.ArrayList(usize) = .empty,
    query: std.ArrayList(u8) = .empty,
    /// Index into `filtered`.
    selected: usize = 0,
    /// First visible `filtered` index.
    scroll: usize = 0,

    pub fn deinit(self: *Model, alloc: std.mem.Allocator) void {
        self.rows.deinit(alloc);
        self.filtered.deinit(alloc);
        self.query.deinit(alloc);
    }

    /// Replace the rows (labels are borrowed; the caller keeps them alive
    /// until the next `setRows`). Re-applies the current query.
    pub fn setRows(self: *Model, alloc: std.mem.Allocator, rows: []const Row) !void {
        self.rows.clearRetainingCapacity();
        try self.rows.appendSlice(alloc, rows);
        try self.refilter(alloc);
    }

    pub fn refilter(self: *Model, alloc: std.mem.Allocator) !void {
        self.filtered.clearRetainingCapacity();
        for (self.rows.items, 0..) |r, i| {
            if (match(r.label, self.query.items)) try self.filtered.append(alloc, i);
        }
        if (self.selected >= self.filtered.items.len) {
            self.selected = if (self.filtered.items.len == 0) 0 else self.filtered.items.len - 1;
        }
        self.scroll = 0;
    }

    pub fn count(self: *const Model) usize {
        return self.filtered.items.len;
    }

    pub fn selectedRow(self: *const Model) ?Row {
        if (self.filtered.items.len == 0) return null;
        const idx = self.filtered.items[@min(self.selected, self.filtered.items.len - 1)];
        return self.rows.items[idx];
    }

    pub fn rowAtVisible(self: *const Model, visible: usize) ?Row {
        const idx = self.scroll + visible;
        if (idx >= self.filtered.items.len) return null;
        return self.rows.items[self.filtered.items[idx]];
    }

    /// Move the selection by `delta`, wrapping nothing and clamping at the
    /// ends (a picker should not cycle past the newest entry).
    pub fn move(self: *Model, delta: isize) void {
        const n = self.filtered.items.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.selected);
        var next = cur + delta;
        if (next < 0) next = 0;
        if (next >= @as(isize, @intCast(n))) next = @intCast(n - 1);
        self.selected = @intCast(next);
    }

    /// Append printable UTF-8 bytes to the query, capped at 128 bytes.
    pub fn typeBytes(self: *Model, alloc: std.mem.Allocator, bytes: []const u8) !void {
        for (bytes) |b| {
            if (b < 0x20 or b == 0x7f) continue;
            if (self.query.items.len >= 128) break;
            try self.query.append(alloc, b);
        }
    }

    /// Remove the last UTF-8 scalar from the query.
    pub fn backspace(self: *Model) void {
        var len = self.query.items.len;
        while (len > 0) {
            len -= 1;
            const b = self.query.items[len];
            if (b & 0xC0 != 0x80) break;
        }
        self.query.shrinkRetainingCapacity(len);
    }

    /// Keep the selected row inside the window of `visible` rows.
    pub fn clampScroll(self: *Model, visible: usize) void {
        if (visible == 0 or self.filtered.items.len == 0) {
            self.scroll = 0;
            return;
        }
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + visible) self.scroll = self.selected + 1 - visible;
        const max_scroll = if (self.filtered.items.len > visible) self.filtered.items.len - visible else 0;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
    }
};

/// Case-insensitive substring match. An empty query matches everything.
pub fn match(label: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > label.len) return false;
    var i: usize = 0;
    while (i + query.len <= label.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(label[i .. i + query.len], query)) return true;
    }
    return false;
}

/// Human byte size for a row: `812 B`, `3.4 KB`, `1.2 MB`.
pub fn fmtSize(alloc: std.mem.Allocator, bytes: u64) ![]u8 {
    if (bytes < 1024) return std.fmt.allocPrint(alloc, "{d} B", .{bytes});
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024.0) return std.fmt.allocPrint(alloc, "{d:.1} KB", .{kb});
    const mb = kb / 1024.0;
    if (mb < 1024.0) return std.fmt.allocPrint(alloc, "{d:.1} MB", .{mb});
    return std.fmt.allocPrint(alloc, "{d:.1} GB", .{mb / 1024.0});
}

/// Age of an entry: `now`, `5m`, `3h`, `2d`.
pub fn fmtAge(alloc: std.mem.Allocator, age_ms: i64) ![]u8 {
    const s = @divTrunc(@max(0, age_ms), 1000);
    if (s < 60) return std.fmt.allocPrint(alloc, "now", .{});
    const m = @divTrunc(s, 60);
    if (m < 60) return std.fmt.allocPrint(alloc, "{d}m", .{m});
    const h = @divTrunc(m, 60);
    if (h < 24) return std.fmt.allocPrint(alloc, "{d}h", .{h});
    return std.fmt.allocPrint(alloc, "{d}d", .{@divTrunc(h, 24)});
}

/// First `file://…` URI inside a preview, decoded to a path. File
/// selections preview as the gnome body (`copy\nfile:///…`), so the URI is
/// not always the first token.
pub fn firstPathInPreview(preview: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, preview, "file://") orelse return null;
    var rest = preview[at + "file://".len ..];
    if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| rest = rest[0..sp];
    if (std.mem.startsWith(u8, rest, "localhost")) rest = rest["localhost".len..];
    return if (rest.len == 0) null else rest;
}

pub fn basename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[idx + 1 ..];
}

/// The row label for one entry.
pub fn labelFor(alloc: std.mem.Allocator, meta: *const store.Meta, age_ms: i64) ![]u8 {
    const age = try fmtAge(alloc, age_ms);
    defer alloc.free(age);
    const size = try fmtSize(alloc, meta.size);
    defer alloc.free(size);
    switch (meta.kind) {
        .image => {
            const dims = if (meta.preview.len > 0) meta.preview else "image";
            return std.fmt.allocPrint(alloc, "[image] {s}  ·  {s}  ·  {s}", .{ dims, size, age });
        },
        .files => {
            const name = if (firstPathInPreview(meta.preview)) |p| basename(p) else meta.preview;
            const single = if (name.len > 0) name else "files";
            return std.fmt.allocPrint(alloc, "[files] {s}  ·  {s}  ·  {s}", .{ single, size, age });
        },
        .text => {
            return std.fmt.allocPrint(alloc, "{s}  ·  {s}", .{ std.mem.trim(u8, meta.preview, " "), age });
        },
        .other => {
            const mime = if (meta.first_mime.len > 0) meta.first_mime else "data";
            return std.fmt.allocPrint(alloc, "[{s}] {s}  ·  {s}", .{ mime, size, age });
        },
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn row(id: u64, label: []const u8) Row {
    return .{ .id = id, .kind = .text, .captured_ms = 0, .size = 1, .label = label };
}

test "clipstack picker: filter is case-insensitive substring" {
    const t = testing;
    try t.expect(match("Hello World", ""));
    try t.expect(match("Hello World", "world"));
    try t.expect(match("Hello World", "WORLD"));
    try t.expect(match("Hello World", "lo wo"));
    try t.expect(!match("Hello World", "worlds"));
    try t.expect(!match("short", "longer than label"));
}

test "clipstack picker: typing filters and selection clamps" {
    const t = testing;
    var m = Model{};
    defer m.deinit(t.allocator);
    const rows = [_]Row{
        row(3, "gamma"),
        row(2, "beta"),
        row(1, "alpha"),
    };
    try m.setRows(t.allocator, &rows);
    try t.expectEqual(@as(usize, 3), m.count());
    try t.expectEqual(@as(u64, 3), m.selectedRow().?.id);

    try m.typeBytes(t.allocator, "bet");
    try m.refilter(t.allocator);
    try t.expectEqual(@as(usize, 1), m.count());
    try t.expectEqual(@as(u64, 2), m.selectedRow().?.id);

    while (m.query.items.len > 0) {
        m.backspace();
        try m.refilter(t.allocator);
    }
    try t.expectEqual(@as(usize, 3), m.count());
    try t.expectEqual(@as(u64, 3), m.selectedRow().?.id);

    try m.typeBytes(t.allocator, "ALPHA");
    try m.refilter(t.allocator);
    try t.expectEqual(@as(usize, 1), m.count());
    try t.expectEqual(@as(u64, 1), m.selectedRow().?.id);
}

test "clipstack picker: backspace removes a full utf-8 scalar" {
    const t = testing;
    var m = Model{};
    defer m.deinit(t.allocator);
    try m.typeBytes(t.allocator, "aé");
    try t.expectEqual(@as(usize, 3), m.query.items.len);
    m.backspace();
    try t.expectEqualStrings("a", m.query.items);
    m.backspace();
    try t.expectEqualStrings("", m.query.items);
    m.backspace(); // extra backspaces are a no-op
    try t.expectEqualStrings("", m.query.items);
}

test "clipstack picker: control bytes never enter the query" {
    const t = testing;
    var m = Model{};
    defer m.deinit(t.allocator);
    try m.typeBytes(t.allocator, "a\n\r\tb\x7f");
    try t.expectEqualStrings("ab", m.query.items);
}

test "clipstack picker: move clamps at both ends, scroll follows" {
    const t = testing;
    var m = Model{};
    defer m.deinit(t.allocator);
    const rows = [_]Row{ row(3, "c"), row(2, "b"), row(1, "a") };
    try m.setRows(t.allocator, &rows);

    m.move(-1);
    try t.expectEqual(@as(usize, 0), m.selected);
    m.move(1);
    m.move(1);
    m.move(1);
    try t.expectEqual(@as(usize, 2), m.selected);

    m.clampScroll(1);
    try t.expectEqual(@as(usize, 2), m.scroll);
    m.move(-1);
    m.clampScroll(1);
    try t.expectEqual(@as(usize, 1), m.scroll);
    m.clampScroll(3);
    try t.expectEqual(@as(usize, 0), m.scroll);
}

test "clipstack picker: rowAtVisible walks the filtered window" {
    const t = testing;
    var m = Model{};
    defer m.deinit(t.allocator);
    const rows = [_]Row{ row(4, "dd"), row(3, "cc"), row(2, "bb"), row(1, "aa") };
    try m.setRows(t.allocator, &rows);
    try m.typeBytes(t.allocator, "c");
    try m.refilter(t.allocator);
    try t.expectEqual(@as(u64, 3), m.rowAtVisible(0).?.id);
    try t.expect(m.rowAtVisible(1) == null);

    try m.typeBytes(t.allocator, "\x7f\x7f"); // ignored bytes
    try m.refilter(t.allocator);
    try t.expectEqual(@as(usize, 1), m.count());
}

test "clipstack picker: sizes and ages format for the footer" {
    const t = testing;
    const a = try fmtSize(t.allocator, 812);
    defer t.allocator.free(a);
    try t.expectEqualStrings("812 B", a);
    const b = try fmtSize(t.allocator, 3481);
    defer t.allocator.free(b);
    try t.expectEqualStrings("3.4 KB", b);
    const c = try fmtSize(t.allocator, 1_258_291);
    defer t.allocator.free(c);
    try t.expectEqualStrings("1.2 MB", c);

    const s0 = try fmtAge(t.allocator, 5_000);
    defer t.allocator.free(s0);
    try t.expectEqualStrings("now", s0);
    const s1 = try fmtAge(t.allocator, 5 * 60_000);
    defer t.allocator.free(s1);
    try t.expectEqualStrings("5m", s1);
    const s2 = try fmtAge(t.allocator, 3 * 3_600_000);
    defer t.allocator.free(s2);
    try t.expectEqualStrings("3h", s2);
    const s3 = try fmtAge(t.allocator, 50 * 3_600_000);
    defer t.allocator.free(s3);
    try t.expectEqualStrings("2d", s3);
}

test "clipstack picker: labels per kind" {
    const t = testing;
    {
        const meta = store.Meta{ .kind = .text, .preview = @constCast("hello world"), .size = 40 };
        const l = try labelFor(t.allocator, &meta, 3_000);
        defer t.allocator.free(l);
        try t.expect(std.mem.indexOf(u8, l, "hello world") != null);
        try t.expect(std.mem.indexOf(u8, l, "now") != null);
    }
    {
        const meta = store.Meta{
            .kind = .image,
            .preview = @constCast("1920x1080"),
            .size = 1_258_291,
            .first_mime = @constCast("image/png"),
        };
        const l = try labelFor(t.allocator, &meta, 120_000);
        defer t.allocator.free(l);
        try t.expect(std.mem.indexOf(u8, l, "[image] 1920x1080") != null);
        try t.expect(std.mem.indexOf(u8, l, "1.2 MB") != null);
        try t.expect(std.mem.indexOf(u8, l, "2m") != null);
    }
    {
        const meta = store.Meta{
            .kind = .files,
            .preview = @constCast("copy file:///home/matt/Notes/todo.md"),
            .size = 120,
            .first_mime = @constCast("x-special/gnome-copied-files"),
        };
        const l = try labelFor(t.allocator, &meta, 0);
        defer t.allocator.free(l);
        try t.expect(std.mem.indexOf(u8, l, "[files] todo.md") != null);
    }
    {
        const meta = store.Meta{
            .kind = .other,
            .preview = @constCast(""),
            .size = 10,
            .first_mime = @constCast("application/pdf"),
        };
        const l = try labelFor(t.allocator, &meta, 0);
        defer t.allocator.free(l);
        try t.expect(std.mem.indexOf(u8, l, "[application/pdf]") != null);
    }
}

test "clipstack picker: preview path extraction handles localhost and spaces" {
    const t = testing;
    try t.expectEqualStrings(
        "todo.md",
        basename(firstPathInPreview("copy file:///home/matt/Notes/todo.md").?),
    );
    try t.expectEqualStrings(
        "/tmp/some",
        firstPathInPreview("copy file://localhost/tmp/some file.png").?,
    );
    try t.expectEqualStrings(
        "some",
        basename(firstPathInPreview("copy file://localhost/tmp/some file.png").?),
    );
    try t.expect(firstPathInPreview("no uri here") == null);
}
