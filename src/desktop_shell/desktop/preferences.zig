const std = @import("std");

/// Desktop icon arrangement.
pub const Arrangement = enum(u8) {
    auto_arrange = 0,
    align_to_grid = 1,
    stacked = 2,
    stacked_right = 3,
};

/// Desktop icon sort order.
pub const Sort = enum(u8) {
    name = 0,
    @"type" = 1,
};

/// Desktop icon size.
pub const SizeKind = enum(u8) {
    small = 0,
    medium = 1,
    large = 2,
};

/// Icon layout metrics.
pub const Metrics = struct {
    icon_sz: f64,
    cell_w: f64,
    cell_h: f64,
    /// Output fit factor these metrics were scaled by (output height / 1440,
    /// clamped). The label font and its baseline are authored in natural px,
    /// so they scale by this — the icon art scales through `icon_sz`.
    fit: f64 = 1.0,
};

pub fn metricsFor(k: SizeKind) Metrics {
    return switch (k) {
        .small => .{ .icon_sz = 36.0, .cell_w = 78.0, .cell_h = 72.0 },
        .large => .{ .icon_sz = 64.0, .cell_w = 130.0, .cell_h = 108.0 },
        .medium => .{ .icon_sz = 48.0, .cell_w = 104.0, .cell_h = 88.0 },
    };
}

pub fn arrangementToken(a: Arrangement) []const u8 {
    return switch (a) {
        .auto_arrange => "auto",
        .align_to_grid => "align",
        .stacked => "stacked",
        .stacked_right => "stacked-right",
    };
}

pub fn parseArrangement(s: []const u8) ?Arrangement {
    if (std.mem.eql(u8, s, "auto")) return .auto_arrange;
    if (std.mem.eql(u8, s, "align")) return .align_to_grid;
    if (std.mem.eql(u8, s, "stacked")) return .stacked;
    if (std.mem.eql(u8, s, "stacked-right")) return .stacked_right;
    return null;
}

pub fn sizeToken(k: SizeKind) []const u8 {
    return switch (k) {
        .small => "small",
        .medium => "medium",
        .large => "large",
    };
}

pub fn parseSize(s: []const u8) ?SizeKind {
    if (std.mem.eql(u8, s, "small")) return .small;
    if (std.mem.eql(u8, s, "large")) return .large;
    if (std.mem.eql(u8, s, "medium")) return .medium;
    return null;
}

pub fn sortToken(s: Sort) []const u8 {
    return switch (s) {
        .name => "name",
        .@"type" => "type",
    };
}

pub fn parseSort(s: []const u8) ?Sort {
    if (std.mem.eql(u8, s, "type")) return .@"type";
    if (std.mem.eql(u8, s, "name")) return .name;
    return null;
}

pub fn parseIconsVisible(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "false")) return false;
    if (std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true")) return true;
    return null;
}

/// Pure-logic prefs snapshot: arrangement/sort/size/visible + grid map.
/// Follows the prefs fields + `desktop_icons_layout.txt` format.
pub const Prefs = struct {
    arrangement: Arrangement = .align_to_grid,
    sort: Sort = .name,
    size: SizeKind = .medium,
    icons_visible: bool = true,
};

pub const GridSlot = struct {
    col: i32,
    row: i32,
    layer: i32,
};

/// Parse one `key=value` header line. Returns true if consumed.
pub fn parseHeaderLine(prefs: *Prefs, key: []const u8, val: []const u8) bool {
    if (std.mem.eql(u8, key, "arrangement")) {
        if (parseArrangement(val)) |a| prefs.arrangement = a;
        return true;
    }
    if (std.mem.eql(u8, key, "sort")) {
        if (parseSort(val)) |s| prefs.sort = s;
        return true;
    }
    if (std.mem.eql(u8, key, "size")) {
        if (parseSize(val)) |z| prefs.size = z;
        return true;
    }
    if (std.mem.eql(u8, key, "icons_visible")) {
        if (parseIconsVisible(val)) |v| prefs.icons_visible = v;
        return true;
    }
    return false;
}

/// Parse one `path\tcol\trow\tlayer` grid line (`:154-170`).
pub fn parseGridLine(line: []const u8) ?struct { path: []const u8, slot: GridSlot } {
    var it = std.mem.splitScalar(u8, line, '\t');
    const path = it.next() orelse return null;
    const cols = it.next() orelse return null;
    const rows = it.next() orelse return null;
    const layers = it.next() orelse "0";
    const c = std.fmt.parseInt(i32, std.mem.trim(u8, cols, " \t"), 10) catch return null;
    const r = std.fmt.parseInt(i32, std.mem.trim(u8, rows, " \t"), 10) catch return null;
    const l = std.fmt.parseInt(i32, std.mem.trim(u8, layers, " \t"), 10) catch return null;
    if (c < 0 or r < 0 or l < 0) return null;
    if (path.len == 0) return null;
    return .{ .path = path, .slot = .{ .col = c, .row = r, .layer = l } };
}

/// Parse a whole layout file into prefs + grid count (grid storage stays with caller).
/// Header lines are `key=value`, grid lines are `path\tcol\trow\tlayer`;
/// `#`/empty lines skipped (`:130-171`).
pub fn parseLayoutFile(text: []const u8, prefs: *Prefs) usize {
    var grid_lines: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            var key = std.mem.trimEnd(u8, line[0..eq], " \t");
            key = std.mem.trimStart(u8, key, " \t");
            var val = line[eq + 1 ..];
            val = std.mem.trimStart(u8, val, " \t");
            val = std.mem.trimEnd(u8, val, " \t");
            if (parseHeaderLine(prefs, key, val)) continue;
        }
        if (parseGridLine(line) != null) grid_lines += 1;
    }
    return grid_lines;
}

/// Serialize prefs header (`:181-185`). Grid lines are appended by the caller
/// only for align/stacked modes (`:186-191`).
pub fn writeHeader(alloc: std.mem.Allocator, prefs: Prefs) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "# EventHorizon desktop icon layout (generated)\narrangement={s}\nsort={s}\nsize={s}\nicons_visible={s}\n",
        .{
            arrangementToken(prefs.arrangement),
            sortToken(prefs.sort),
            sizeToken(prefs.size),
            if (prefs.icons_visible) "1" else "0",
        });
}

/// Grid lines are persisted only for align/stacked modes (`:186-188`).
pub fn persistsGrid(a: Arrangement) bool {
    return a == .align_to_grid or a == .stacked or a == .stacked_right;
}

pub const file_name: []const u8 = "desktop_icons_layout.txt";

pub const GridEntry = struct {
    path: []const u8,
    slot: GridSlot,
};

/// Load prefs + grid from a real file. Missing file -> defaults.
/// Uses `std.Io` (Zig 0.16 file API).
pub fn loadFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8, prefs: *Prefs, grid_out: *std.ArrayList(GridEntry)) !void {
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path, alloc, .limited(1 << 20)) catch |e| {
        if (e == error.FileNotFound) return;
        return e;
    };
    defer alloc.free(text);
    _ = parseLayoutFile(text, prefs);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '=') != null) {
            // Header already consumed; grid lines never contain '=' before tab?
            // Re-parse strictly as grid:
            if (parseGridLine(line)) |g| {
                const duped = try alloc.dupe(u8, g.path);
                try grid_out.append(alloc, .{ .path = duped, .slot = g.slot });
            }
            continue;
        }
        if (parseGridLine(line)) |g| {
            const duped = try alloc.dupe(u8, g.path);
            try grid_out.append(alloc, .{ .path = duped, .slot = g.slot });
        }
    }
}

/// Save prefs + grid to a real file (creates parent dirs).
/// Uses `std.Io` (Zig 0.16 file API).
pub fn saveFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8, prefs: Prefs, grid: []const GridEntry) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(io, dir);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const hdr = try std.fmt.allocPrint(alloc,
        "# EventHorizon desktop icon layout (generated)\narrangement={s}\nsort={s}\nsize={s}\nicons_visible={s}\n",
        .{ arrangementToken(prefs.arrangement), sortToken(prefs.sort), sizeToken(prefs.size), if (prefs.icons_visible) "1" else "0" });
    defer alloc.free(hdr);
    try buf.appendSlice(alloc, hdr);
    if (persistsGrid(prefs.arrangement)) {
        for (grid) |g| {
            const line = try std.fmt.allocPrint(alloc, "{s}\t{d}\t{d}\t{d}\n", .{ g.path, g.slot.col, g.slot.row, g.slot.layer });
            defer alloc.free(line);
            try buf.appendSlice(alloc, line);
        }
    }
    try cwd.writeFile(io, .{ .sub_path = path, .data = buf.items });
}

test "preferences: metrics match the specified values" {
    const t = std.testing;
    try t.expectEqualDeep(Metrics{ .icon_sz = 36.0, .cell_w = 78.0, .cell_h = 72.0 }, metricsFor(.small));
    try t.expectEqualDeep(Metrics{ .icon_sz = 48.0, .cell_w = 104.0, .cell_h = 88.0 }, metricsFor(.medium));
    try t.expectEqualDeep(Metrics{ .icon_sz = 64.0, .cell_w = 130.0, .cell_h = 108.0 }, metricsFor(.large));
}

test "preferences: tokens round-trip" {
    const t = std.testing;
    try t.expectEqualStrings("auto", arrangementToken(.auto_arrange));
    try t.expectEqualStrings("align", arrangementToken(.align_to_grid));
    try t.expectEqualStrings("stacked-right", arrangementToken(.stacked_right));
    try t.expectEqual(Arrangement.stacked, parseArrangement("stacked").?);
    try t.expect(parseArrangement("bogus") == null);
    try t.expectEqual(SizeKind.large, parseSize("large").?);
    try t.expectEqual(Sort.@"type", parseSort("type").?);
    try t.expectEqual(false, parseIconsVisible("false").?);
    try t.expectEqual(true, parseIconsVisible("1").?);
}

test "preferences: layout file parse + header write" {
    const t = std.testing;
    var prefs = Prefs{};
    const n = parseLayoutFile(
        "# comment\narrangement=stacked-right\nsort=type\nsize=large\nicons_visible=0\n/home/u/Desktop/a.desktop\t1\t2\t0\n",
        &prefs,
    );
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(Arrangement.stacked_right, prefs.arrangement);
    try t.expectEqual(Sort.@"type", prefs.sort);
    try t.expectEqual(SizeKind.large, prefs.size);
    try t.expect(!prefs.icons_visible);
    const hdr = try writeHeader(t.allocator, prefs);
    defer t.allocator.free(hdr);
    try t.expect(std.mem.indexOf(u8, hdr, "arrangement=stacked-right") != null);
    try t.expect(std.mem.indexOf(u8, hdr, "icons_visible=0") != null);
    try t.expect(persistsGrid(.align_to_grid));
    try t.expect(!persistsGrid(.auto_arrange));
    const g = parseGridLine("/a/b\t3\t4\t1").?;
    try t.expectEqual(@as(i32, 3), g.slot.col);
    try t.expect(parseGridLine("no-tabs-here") == null);
    try t.expect(parseGridLine("/a\t-1\t0\t0") == null);
}

test "preferences: save/load round trip" {
    const t = std.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "desktop_icons_layout.txt" });
    defer t.allocator.free(path);
    const prefs_in = Prefs{
        .arrangement = .align_to_grid,
        .sort = .@"type",
        .size = .large,
        .icons_visible = false,
    };
    const grid_in = [_]GridEntry{
        .{ .path = "/home/u/Desktop/a.desktop", .slot = .{ .col = 1, .row = 2, .layer = 0 } },
        .{ .path = "/home/u/Desktop/b.desktop", .slot = .{ .col = 3, .row = 4, .layer = 1 } },
    };
    try saveFile(io, t.allocator, path, prefs_in, &grid_in);
    var prefs_out = Prefs{};
    var grid_out: std.ArrayList(GridEntry) = .empty;
    defer {
        for (grid_out.items) |g| t.allocator.free(g.path);
        grid_out.deinit(t.allocator);
    }
    try loadFile(io, t.allocator, path, &prefs_out, &grid_out);
    try t.expectEqual(prefs_in.arrangement, prefs_out.arrangement);
    try t.expectEqual(prefs_in.sort, prefs_out.sort);
    try t.expectEqual(prefs_in.size, prefs_out.size);
    try t.expectEqual(prefs_in.icons_visible, prefs_out.icons_visible);
    try t.expectEqual(@as(usize, grid_in.len), grid_out.items.len);
    try t.expectEqualStrings(grid_in[0].path, grid_out.items[0].path);
    try t.expectEqual(grid_in[0].slot.col, grid_out.items[0].slot.col);
    try t.expectEqual(grid_in[0].slot.row, grid_out.items[0].slot.row);
    try t.expectEqual(grid_in[0].slot.layer, grid_out.items[0].slot.layer);
    try t.expectEqualStrings(grid_in[1].path, grid_out.items[1].path);
    try t.expectEqual(grid_in[1].slot.col, grid_out.items[1].slot.col);
    try t.expectEqual(grid_in[1].slot.row, grid_out.items[1].slot.row);
    try t.expectEqual(grid_in[1].slot.layer, grid_out.items[1].slot.layer);
}
