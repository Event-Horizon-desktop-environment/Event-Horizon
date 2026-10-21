const std = @import("std");
const prefs = @import("preferences.zig");
const et = @import("entry_types.zig");

/// Desktop icon model + grid layout:
/// Icon kinds, `.desktop` parsing
/// file→icon-key mapping
/// scan filtering, sorting
/// and the grid assign/collide/apply + auto /
/// align / stacked-left / stacked-right relayouts (`:274-495`).

pub const IconKind = enum(u8) {
    application = 0,
    file = 1,
    folder = 2,
    drive = 3,
    trash = 4,
    my_computer = 5,
};

pub const IconItem = struct {
    desktop_path: []const u8 = "",
    name: []const u8 = "",
    exec: []const u8 = "",
    icon_key: []const u8 = "",
    grid_col: i32 = -1,
    grid_row: i32 = -1,
    layer: i32 = 0,
    kind: IconKind = .application,
    drive_mounted: bool = true,
    /// UDisks2 metadata for `.drive` icons (C++ `DesktopIconItem` drive_*).
    /// `drive_device` is the `/dev/...` node; `drive_object_path` is the D-Bus
    /// path used to mount/unmount. Empty when the drive came from `/proc/mounts`
    /// with no UDisks2 match.
    drive_device: []const u8 = "",
    drive_object_path: []const u8 = "",
    drive_uuid: []const u8 = "",
    drive_fstype: []const u8 = "",
    /// Block `Configuration` has an `fstab` item: the Mount row mounts
    /// straight away (deferred FstabMount) instead of opening the dialog.
    drive_has_fstab: bool = false,
    cell_x: f64 = 0,
    cell_y: f64 = 0,
};

pub const margin: f64 = 20.0;
pub const drag_threshold_px: f64 = 6.0;

pub fn userDesktopDir(env_desktop: ?[]const u8, home: ?[]const u8, buf: []u8) ?[]const u8 {
    if (env_desktop) |d| {
        if (d.len > 0) return d;
    }
    if (home) |h| {
        const out = std.fmt.bufPrint(buf, "{s}/Desktop", .{h}) catch return null;
        return out;
    }
    return null;
}

pub fn disablesIcons(env_val: ?[]const u8) bool {
    const e = env_val orelse return false;
    return e.len > 0 and e[0] == '1';
}

fn lowerExtBuf(path: []const u8, buf: *[16]u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    const e = base[dot..];
    const n: usize = @min(e.len, 16);
    for (0..n) |i| buf[i] = std.ascii.toLower(e[i]);
    return buf[0..n];
}

/// Icon key for a file path.
pub fn iconKeyForFilePath(path: []const u8) []const u8 {
    var buf: [16]u8 = undefined;
    const ext = lowerExtBuf(path, &buf);
    if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg") or
        std.mem.eql(u8, ext, ".gif") or std.mem.eql(u8, ext, ".bmp") or std.mem.eql(u8, ext, ".webp") or
        std.mem.eql(u8, ext, ".tif") or std.mem.eql(u8, ext, ".tiff") or std.mem.eql(u8, ext, ".svg") or
        std.mem.eql(u8, ext, ".ico") or std.mem.eql(u8, ext, ".avif") or std.mem.eql(u8, ext, ".heic") or
        std.mem.eql(u8, ext, ".jxl")) return "image-x-generic";
    if (std.mem.eql(u8, ext, ".mp4") or std.mem.eql(u8, ext, ".mkv") or std.mem.eql(u8, ext, ".avi") or
        std.mem.eql(u8, ext, ".webm") or std.mem.eql(u8, ext, ".mov") or std.mem.eql(u8, ext, ".wmv") or
        std.mem.eql(u8, ext, ".mpeg") or std.mem.eql(u8, ext, ".mpg") or std.mem.eql(u8, ext, ".m4v") or
        std.mem.eql(u8, ext, ".flv") or std.mem.eql(u8, ext, ".ogv") or std.mem.eql(u8, ext, ".3gp") or
        std.mem.eql(u8, ext, ".ts")) return "video-x-generic";
    if (std.mem.eql(u8, ext, ".mp3") or std.mem.eql(u8, ext, ".wav") or std.mem.eql(u8, ext, ".flac") or
        std.mem.eql(u8, ext, ".ogg") or std.mem.eql(u8, ext, ".opus") or std.mem.eql(u8, ext, ".m4a") or
        std.mem.eql(u8, ext, ".aac") or std.mem.eql(u8, ext, ".wma")) return "audio-x-generic";
    if (std.mem.eql(u8, ext, ".pdf")) return "application-pdf";
    if (std.mem.eql(u8, ext, ".zip") or std.mem.eql(u8, ext, ".7z") or std.mem.eql(u8, ext, ".tar") or
        std.mem.eql(u8, ext, ".tgz") or std.mem.eql(u8, ext, ".tbz2") or std.mem.eql(u8, ext, ".tbz") or
        std.mem.eql(u8, ext, ".txz") or std.mem.eql(u8, ext, ".tzst") or std.mem.eql(u8, ext, ".gz") or
        std.mem.eql(u8, ext, ".xz") or std.mem.eql(u8, ext, ".bz2") or std.mem.eql(u8, ext, ".rar") or
        std.mem.eql(u8, ext, ".zst") or std.mem.eql(u8, ext, ".cab")) return "package-x-generic";
    if (std.mem.eql(u8, ext, ".txt") or std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".csv") or
        std.mem.eql(u8, ext, ".json") or std.mem.eql(u8, ext, ".toml") or std.mem.eql(u8, ext, ".xml") or
        std.mem.eql(u8, ext, ".log")) return "text-x-generic";
    return "inode-x-generic";
}

/// Raster thumbnails only for these (`file_wants_raster_thumbnail`, `:141-144`).
pub fn fileWantsRasterThumbnail(path: []const u8) bool {
    var buf: [16]u8 = undefined;
    const ext = lowerExtBuf(path, &buf);
    return std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or
        std.mem.eql(u8, ext, ".jpeg") or std.mem.eql(u8, ext, ".webp") or
        std.mem.eql(u8, ext, ".bmp") or std.mem.eql(u8, ext, ".gif");
}

pub const ParsedDesktop = struct {
    name: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    no_display: bool = false,
    hidden: bool = false,
    terminal: bool = false,
    entry_type: []const u8 = "application",
};

fn eqFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |c1, c2| {
        if (std.ascii.toLower(c1) != std.ascii.toLower(c2)) return false;
    }
    return true;
}

/// `parse_desktop_file` (`:234-266`): only `[Desktop Entry]` section.
pub fn parseDesktopLine(st: *ParsedDesktop, in_entry: bool, line: []const u8) void {
    if (!in_entry) return;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = et.trimLine(line[0..eq]);
    const val = et.trimLine(line[eq + 1 ..]);
    if (eqFold(key, "name")) st.name = val;
    if (eqFold(key, "exec")) st.exec = val;
    if (eqFold(key, "icon")) st.icon = val;
    if (eqFold(key, "nodisplay")) st.no_display = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
    if (eqFold(key, "hidden")) st.hidden = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
    if (eqFold(key, "terminal")) st.terminal = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
    if (eqFold(key, "type")) st.entry_type = val;
}

pub fn parseDesktopFile(text: []const u8) ParsedDesktop {
    var st = ParsedDesktop{};
    var in_entry = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = et.trimLine(std.mem.trimEnd(u8, raw, "\r"));
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        parseDesktopLine(&st, in_entry, line);
    }
    if (st.entry_type.len == 0) st.entry_type = "application";
    return st;
}

/// Skip `.lnk/.ink`, dotfiles (`rescan`, `:693-713`).
pub fn scanSkips(filename: []const u8) bool {
    if (filename.len == 0) return true;
    if (filename[0] == '.') return true;
    var buf: [16]u8 = undefined;
    const ext = lowerExtBuf(filename, &buf);
    if (std.mem.eql(u8, ext, ".lnk") or std.mem.eql(u8, ext, ".ink")) return true;
    return false;
}

fn lessByName(a: IconItem, b: IconItem) bool {
    if (a.layer != b.layer) return a.layer < b.layer;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessByType(a: IconItem, b: IconItem) bool {
    if (a.layer != b.layer) return a.layer < b.layer;
    if (@intFromEnum(a.kind) != @intFromEnum(b.kind))
        return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return std.mem.lessThan(u8, a.name, b.name);
}

/// `sort_icons` (`:363-382`).
pub fn sortIcons(items: []IconItem, mode: prefs.Sort) void {
    switch (mode) {
        .@"type" => std.mem.sort(IconItem, items, {}, struct {
            fn lt(_: void, a: IconItem, b: IconItem) bool {
                return lessByType(a, b);
            }
        }.lt),
        .name => std.mem.sort(IconItem, items, {}, struct {
            fn lt(_: void, a: IconItem, b: IconItem) bool {
                return lessByName(a, b);
            }
        }.lt),
    }
}

pub fn gridCols(cell_w: f64, w: i32) i32 {
    const usable: f64 = @floatFromInt(@max(0, w - @as(i32, @intFromFloat(margin * 2.0))));
    return @max(1, @as(i32, @intFromFloat(@floor(usable / cell_w))));
}

pub fn availableRows(cell_h: f64, h: i32, dock_reserve: i32, taskbar_reserve: i32) i32 {
    const avail = @max(1, h - @as(i32, @intFromFloat(margin)) - dock_reserve - taskbar_reserve);
    return @max(1, @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(avail)) / cell_h))));
}

/// Snap a dropped cell to the nearest grid slot (`finish_icon_drag`, `:994-998`).
pub fn snapToGrid(cell_x: f64, cell_y: f64, m: prefs.Metrics, cols: i32) struct { col: i32, row: i32 } {
    var col: i32 = @intFromFloat(@round((cell_x - margin) / m.cell_w));
    var row: i32 = @intFromFloat(@round((cell_y - margin) / m.cell_h));
    col = std.math.clamp(col, 0, cols - 1);
    row = @max(0, row);
    return .{ .col = col, .row = row };
}

pub fn cellPos(col: i32, row: i32, m: prefs.Metrics) struct { x: f64, y: f64 } {
    return .{
        .x = margin + @as(f64, @floatFromInt(col)) * m.cell_w,
        .y = margin + @as(f64, @floatFromInt(row)) * m.cell_h,
    };
}

/// Hit test (`desktop_icons_hit_index`, `:1320-1332`).
pub fn hitIndex(items: []const IconItem, layer_idx: i32, x: f64, y: f64, m: prefs.Metrics) ?usize {
    for (items, 0..) |ic, i| {
        if (ic.layer != layer_idx) continue;
        if (x >= ic.cell_x and x < ic.cell_x + m.cell_w and y >= ic.cell_y and y < ic.cell_y + m.cell_h)
            return i;
    }
    return null;
}

/// Trash full check input: whether `~/.local/share/Trash/files` has any entry.
/// (iterating the dir; this pure helper folds the answer
/// into the icon list so it stays testable.)
pub fn trashIconKey(has_files: bool) []const u8 {
    return if (has_files) "user-trash-full" else "user-trash";
}

/// Deferred rescan timing (`desktop_icons_defer/poll/kick`, `:1261-1298`):
/// defer arms a 4000ms window, poll re-scans at most every 100ms inside it,
/// kick arms a 100ms window for the initial scan.
pub const defer_window_ms: i64 = 4000;
pub const defer_gap_ms: i64 = 100;
pub const kick_window_ms: i64 = 100;

pub const DeferState = struct {
    until_ms: ?i64 = null,
    last_tick_ms: ?i64 = null,

    pub fn arm(self: *DeferState, now_ms: i64, window_ms: i64) void {
        self.until_ms = now_ms + window_ms;
        self.last_tick_ms = null;
    }

    /// Returns true when the caller should rescan now.
    pub fn poll(self: *DeferState, now_ms: i64) bool {
        const until = self.until_ms orelse return false;
        if (now_ms >= until) {
            self.until_ms = null;
            self.last_tick_ms = null;
            return false;
        }
        if (self.last_tick_ms) |last| {
            if (now_ms - last < defer_gap_ms) return false;
        }
        self.last_tick_ms = now_ms;
        return true;
    }
};

/// Merge saved grid slots into live icons (`merge_grid_from_prefs`, `:280-293`).
pub fn mergeGridFromPrefs(items: []IconItem, lookup: *const fn (path: []const u8) ?struct { col: i32, row: i32, layer: i32 }) void {
    for (items) |*ic| {
        if (lookup(ic.desktop_path)) |s| {
            ic.grid_col = s.col;
            ic.grid_row = s.row;
            ic.layer = s.layer;
        } else {
            ic.grid_col = -1;
            ic.grid_row = -1;
            ic.layer = 0;
        }
    }
}

/// Occupancy set helpers for assign/collide (small N, linear scan is fine).
fn occupied(cols: []const i32, rows: []const i32, n: usize, col: i32, row: i32) bool {
    for (0..n) |i| {
        if (cols[i] == col and rows[i] == row) return true;
    }
    return false;
}

/// Assign free slots in row-major order (`assign_free_grid_slots`, `:295-327`).
pub fn assignFreeSlots(items: []IconItem, layer_idx: i32, cols: i32, max_row: i32) void {
    // Collect occupancy of already-placed icons on this layer.
    var occ_cols: [1024]i32 = undefined;
    var occ_rows: [1024]i32 = undefined;
    var occ_n: usize = 0;
    for (items) |ic| {
        if (ic.layer != layer_idx) continue;
        if (ic.grid_col >= 0 and ic.grid_row >= 0 and occ_n < occ_cols.len) {
            occ_cols[occ_n] = ic.grid_col;
            occ_rows[occ_n] = ic.grid_row;
            occ_n += 1;
        }
    }
    for (items) |*ic| {
        if (ic.layer != layer_idx) continue;
        if (ic.grid_col >= 0 and ic.grid_row >= 0) continue;
        var placed = false;
        var row: i32 = 0;
        while (!placed and row <= max_row) : (row += 1) {
            var col: i32 = 0;
            while (col < cols) : (col += 1) {
                if (!occupied(&occ_cols, &occ_rows, occ_n, col, row)) {
                    ic.grid_col = col;
                    ic.grid_row = row;
                    if (occ_n < occ_cols.len) {
                        occ_cols[occ_n] = col;
                        occ_rows[occ_n] = row;
                        occ_n += 1;
                    }
                    placed = true;
                    break;
                }
            }
        }
    }
}

/// Column-major stacked assign (`assign_free_grid_slots_stacked`, `:420-455`).
/// `from_right`: stacked-right scans col `cols-1..0`, else `0..cols-1`.
pub fn assignStackedSlots(items: []IconItem, layer_idx: i32, cols: i32, max_row: i32, from_right: bool) void {
    var occ_cols: [1024]i32 = undefined;
    var occ_rows: [1024]i32 = undefined;
    var occ_n: usize = 0;
    for (items) |ic| {
        if (ic.layer != layer_idx) continue;
        if (ic.grid_col >= 0 and ic.grid_row >= 0 and occ_n < occ_cols.len) {
            occ_cols[occ_n] = ic.grid_col;
            occ_rows[occ_n] = ic.grid_row;
            occ_n += 1;
        }
    }
    for (items) |*ic| {
        if (ic.layer != layer_idx) continue;
        if (ic.grid_col >= 0 and ic.grid_row >= 0) continue;
        var placed = false;
        var ci: i32 = 0;
        while (!placed and ci < cols) : (ci += 1) {
            const col: i32 = if (from_right) cols - 1 - ci else ci;
            var row: i32 = 0;
            while (row <= max_row) : (row += 1) {
                if (!occupied(&occ_cols, &occ_rows, occ_n, col, row)) {
                    ic.grid_col = col;
                    ic.grid_row = row;
                    if (occ_n < occ_cols.len) {
                        occ_cols[occ_n] = col;
                        occ_rows[occ_n] = row;
                        occ_n += 1;
                    }
                    placed = true;
                    break;
                }
            }
        }
    }
}

/// Clamp + resolve collisions (`resolve_grid_collisions`, `:329-352`).
pub fn resolveCollisions(items: []IconItem, layer_idx: i32, cols: i32, max_row: i32) void {
    var seen_cols: [1024]i32 = undefined;
    var seen_rows: [1024]i32 = undefined;
    var seen_n: usize = 0;
    for (items) |*ic| {
        if (ic.layer != layer_idx) continue;
        ic.grid_col = std.math.clamp(ic.grid_col, 0, cols - 1);
        ic.grid_row = std.math.clamp(ic.grid_row, 0, max_row);
        while (seen_n < seen_cols.len and occupied(&seen_cols, &seen_rows, seen_n, ic.grid_col, ic.grid_row)) {
            if (ic.grid_row >= max_row) break;
            ic.grid_row += 1;
        }
        if (seen_n < seen_cols.len) {
            seen_cols[seen_n] = ic.grid_col;
            seen_rows[seen_n] = ic.grid_row;
            seen_n += 1;
        }
    }
}

/// Write pixel positions from grid slots (`apply_grid_pixels`, `:354-361`).
pub fn applyGridPixels(items: []IconItem, layer_idx: i32, m: prefs.Metrics) void {
    for (items) |*ic| {
        if (ic.layer != layer_idx) continue;
        ic.cell_x = margin + @as(f64, @floatFromInt(ic.grid_col)) * m.cell_w;
        ic.cell_y = margin + @as(f64, @floatFromInt(ic.grid_row)) * m.cell_h;
    }
}

/// Full auto relayout (`relayout_auto`, `:384-409`): sort then fill row-major.
pub fn relayoutAuto(items: []IconItem, layer_idx: i32, w: i32, h: i32, m: prefs.Metrics, sort: prefs.Sort, dock_reserve: i32, taskbar_reserve: i32) void {
    const cols = gridCols(m.cell_w, w);
    const rows = availableRows(m.cell_h, h, dock_reserve, taskbar_reserve);
    const max_icons: usize = @intCast(@max(1, cols * rows));
    sortIcons(items, sort);
    var pos: usize = 0;
    for (items) |*ic| {
        if (ic.layer != layer_idx) continue;
        if (pos >= max_icons) continue;
        const col: i32 = @intCast(pos % @as(usize, @intCast(cols)));
        const row: i32 = @intCast(pos / @as(usize, @intCast(cols)));
        ic.grid_col = col;
        ic.grid_row = row;
        const p = cellPos(col, row, m);
        ic.cell_x = p.x;
        ic.cell_y = p.y;
        pos += 1;
    }
}

/// Align relayout (`relayout_align`, `:411-418`).
pub fn relayoutAlign(items: []IconItem, layer_idx: i32, w: i32, h: i32, m: prefs.Metrics, sort: prefs.Sort, dock_reserve: i32, taskbar_reserve: i32) void {
    const cols = gridCols(m.cell_w, w);
    const rows = availableRows(m.cell_h, h, dock_reserve, taskbar_reserve);
    sortIcons(items, sort);
    assignFreeSlots(items, layer_idx, cols, rows - 1);
    resolveCollisions(items, layer_idx, cols, rows - 1);
    applyGridPixels(items, layer_idx, m);
}

/// Stacked relayouts (`relayout_stacked_left/right`, `:457-473`).
pub fn relayoutStacked(items: []IconItem, layer_idx: i32, w: i32, h: i32, m: prefs.Metrics, sort: prefs.Sort, dock_reserve: i32, taskbar_reserve: i32, from_right: bool) void {
    const cols = gridCols(m.cell_w, w);
    const rows = availableRows(m.cell_h, h, dock_reserve, taskbar_reserve);
    sortIcons(items, sort);
    assignStackedSlots(items, layer_idx, cols, rows - 1, from_right);
    resolveCollisions(items, layer_idx, cols, rows - 1);
    applyGridPixels(items, layer_idx, m);
}

pub fn relayout(items: []IconItem, layer_idx: i32, w: i32, h: i32, m: prefs.Metrics, arrangement: prefs.Arrangement, sort: prefs.Sort, dock_reserve: i32, taskbar_reserve: i32) void {
    switch (arrangement) {
        .auto_arrange => relayoutAuto(items, layer_idx, w, h, m, sort, dock_reserve, taskbar_reserve),
        .stacked => relayoutStacked(items, layer_idx, w, h, m, sort, dock_reserve, taskbar_reserve, false),
        .stacked_right => relayoutStacked(items, layer_idx, w, h, m, sort, dock_reserve, taskbar_reserve, true),
        .align_to_grid => relayoutAlign(items, layer_idx, w, h, m, sort, dock_reserve, taskbar_reserve),
    }
}

/// Rect select returning count (`select_icons_in_rect_impl`, `:1022-1043`).
/// `out` receives selected indices (cap = items.len).
pub fn selectInRect(items: []const IconItem, layer_idx: i32, x0: f64, y0: f64, x1: f64, y1: f64, m: prefs.Metrics, out: []usize) usize {
    const rx0 = @min(x0, x1);
    const ry0 = @min(y0, y1);
    const rx1 = @max(x0, x1);
    const ry1 = @max(y0, y1);
    var n: usize = 0;
    for (items, 0..) |ic, i| {
        if (ic.layer != layer_idx) continue;
        const ix1 = ic.cell_x + m.cell_w;
        const iy1 = ic.cell_y + m.cell_h;
        if (ix1 < rx0 or ic.cell_x > rx1 or iy1 < ry0 or ic.cell_y > ry1) continue;
        if (n < out.len) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

/// Single-drag swap finish (`finish_icon_drag` single path, `:991-1019`):
/// snap to grid, swap with occupant, resolve, apply. Returns swapped index or null.
pub fn finishSingleDrag(items: []IconItem, idx: usize, w: i32, m: prefs.Metrics, layer_idx: i32, h: i32, dock_reserve: i32, taskbar_reserve: i32) ?usize {
    if (idx >= items.len) return null;
    const cols = gridCols(m.cell_w, w);
    const rows = availableRows(m.cell_h, h, dock_reserve, taskbar_reserve);
    const s = snapToGrid(items[idx].cell_x, items[idx].cell_y, m, cols);
    const old_c = items[idx].grid_col;
    const old_r = items[idx].grid_row;
    var swapped: ?usize = null;
    for (items, 0..) |*other, j| {
        if (j == idx) continue;
        if (other.layer != layer_idx) continue;
        if (other.grid_col == s.col and other.grid_row == s.row) {
            other.grid_col = old_c;
            other.grid_row = old_r;
            swapped = j;
            break;
        }
    }
    items[idx].grid_col = s.col;
    items[idx].grid_row = s.row;
    resolveCollisions(items, layer_idx, cols, rows - 1);
    applyGridPixels(items, layer_idx, m);
    return swapped;
}

/// "New Text Document.txt" / "New Folder" unique-name builder
/// (`desktop_icons_create_new_*`, `:1132-1173`).
pub fn uniqueNewName(alloc: std.mem.Allocator, dir: []const u8, base: []const u8, exists: *const fn ([]const u8) bool) ![]u8 {
    var n: i32 = 1;
    while (true) : (n += 1) {
        const cand = if (n == 1)
            try std.fs.path.join(alloc, &.{ dir, base })
        else if (std.mem.endsWith(u8, base, ".txt"))
            try std.fmt.allocPrint(alloc, "{s}/New Text Document ({d}).txt", .{ dir, n })
        else
            try std.fmt.allocPrint(alloc, "{s}/{s} ({d})", .{ dir, base, n });
        errdefer alloc.free(cand);
        if (!exists(cand)) return cand;
        alloc.free(cand);
        if (n > 9999) return error.OutOfNames;
    }
}

test "icon_item: keys + raster + scan skips" {
    const t = std.testing;
    try t.expectEqualStrings("image-x-generic", iconKeyForFilePath("a.PNG"));
    try t.expectEqualStrings("video-x-generic", iconKeyForFilePath("a.mkv"));
    try t.expectEqualStrings("audio-x-generic", iconKeyForFilePath("a.Flac"));
    try t.expectEqualStrings("application-pdf", iconKeyForFilePath("a.pdf"));
    try t.expectEqualStrings("package-x-generic", iconKeyForFilePath("a.tar.gz"));
    try t.expectEqualStrings("text-x-generic", iconKeyForFilePath("a.md"));
    try t.expectEqualStrings("inode-x-generic", iconKeyForFilePath("a.unknownxyz"));
    try t.expect(fileWantsRasterThumbnail("a.jpg"));
    try t.expect(!fileWantsRasterThumbnail("a.pdf"));
    try t.expect(scanSkips(".hidden"));
    try t.expect(scanSkips("x.lnk"));
    try t.expect(!scanSkips("app.desktop"));
}

test "icon_item: desktop parse" {
    const t = std.testing;
    const st = parseDesktopFile("[Desktop Entry]\nName=Firefox\nExec=firefox %u\nIcon=firefox\nNoDisplay=true\nType=Application\n");
    try t.expectEqualStrings("Firefox", st.name);
    try t.expectEqualStrings("firefox %u", st.exec);
    try t.expect(st.no_display);
}

test "icon_item: sort + grid + hit" {
    const t = std.testing;
    var items = [_]IconItem{
        .{ .name = "b", .kind = .file, .layer = 0 },
        .{ .name = "a", .kind = .file, .layer = 0 },
        .{ .name = "c", .kind = .folder, .layer = 0 },
    };
    sortIcons(&items, .name);
    try t.expectEqualStrings("a", items[0].name);
    sortIcons(&items, .@"type");
    try t.expectEqual(IconKind.file, items[0].kind);
    const m = prefs.metricsFor(.medium);
    try t.expectEqual(@as(i32, 18), gridCols(m.cell_w, 1920));
    const s = snapToGrid(20 + 104 * 2 + 30, 20 + 10, m, 18);
    try t.expectEqual(@as(i32, 2), s.col);
    const p = cellPos(2, 1, m);
    try t.expectApproxEqAbs(20 + 208, p.x, 1e-9);
    var hit_items = [_]IconItem{.{ .cell_x = 20, .cell_y = 20, .layer = 0 }};
    try t.expectEqual(@as(?usize, 0), hitIndex(&hit_items, 0, 30, 30, m));
    try t.expectEqual(@as(?usize, null), hitIndex(&hit_items, 0, 500, 500, m));
    try t.expectEqualStrings("user-trash-full", trashIconKey(true));
}

test "icon_item: relayout auto/align/stacked + collisions + drag + select + defer" {
    const t = std.testing;
    const m = prefs.metricsFor(.medium);
    var items = [_]IconItem{
        .{ .name = "b", .kind = .file, .layer = 0, .grid_col = -1, .grid_row = -1 },
        .{ .name = "a", .kind = .file, .layer = 0, .grid_col = -1, .grid_row = -1 },
        .{ .name = "c", .kind = .file, .layer = 0, .grid_col = -1, .grid_row = -1 },
    };
    relayoutAuto(&items, 0, 1920, 1080, m, .name, 0, 0);
    try t.expectEqual(@as(i32, 0), items[0].grid_col);
    try t.expectEqual(@as(i32, 1), items[1].grid_col);
    try t.expectEqualStrings("a", items[0].name);
    // Align keeps saved slots, fills free.
    items[0].grid_col = 5;
    items[0].grid_row = 5;
    items[1].grid_col = -1;
    items[1].grid_row = -1;
    items[2].grid_col = -1;
    items[2].grid_row = -1;
    relayoutAlign(&items, 0, 1920, 1080, m, .name, 0, 0);
    try t.expect(items[0].grid_col == 5);
    // Collision: two icons same slot -> second bumps row.
    var coll = [_]IconItem{
        .{ .name = "a", .layer = 0, .grid_col = 0, .grid_row = 0 },
        .{ .name = "b", .layer = 0, .grid_col = 0, .grid_row = 0 },
    };
    resolveCollisions(&coll, 0, 18, 11);
    try t.expect(coll[1].grid_row == 1);
    // Stacked-right packs from the right column.
    var st = [_]IconItem{
        .{ .name = "a", .layer = 0, .grid_col = -1, .grid_row = -1 },
        .{ .name = "b", .layer = 0, .grid_col = -1, .grid_row = -1 },
    };
    relayoutStacked(&st, 0, 1920, 1080, m, .name, 0, 0, true);
    try t.expectEqual(@as(i32, 17), st[0].grid_col);
    // Drag swap.
    var drag = [_]IconItem{
        .{ .name = "a", .layer = 0, .grid_col = 0, .grid_row = 0, .cell_x = 20, .cell_y = 20 },
        .{ .name = "b", .layer = 0, .grid_col = 1, .grid_row = 0, .cell_x = 124, .cell_y = 20 },
    };
    applyGridPixels(&drag, 0, m);
    // Move a onto b's cell.
    drag[0].cell_x = drag[1].cell_x + 5;
    drag[0].cell_y = drag[1].cell_y + 5;
    const swapped = finishSingleDrag(&drag, 0, 1920, m, 0, 1080, 0, 0);
    try t.expectEqual(@as(?usize, 1), swapped);
    // Rect select.
    var buf: [8]usize = undefined;
    const n = selectInRect(&drag, 0, 0, 0, 300, 200, m, &buf);
    try t.expect(n == 2);
    // Defer timing.
    var ds = DeferState{};
    ds.arm(1000, defer_window_ms);
    try t.expect(ds.poll(1050));
    try t.expect(!ds.poll(1060)); // gap 100ms
    try t.expect(ds.poll(1200));
    var kick = DeferState{};
    kick.arm(0, kick_window_ms);
    try t.expect(kick.poll(50));
}

/// `/proc/mounts` drive filter (`add_drive_icons`, `:545-630`).
/// Skips non-/dev, `/`, pseudo fstypes, and non-media prefixes.
/// Returns mount point or null when skipped.
pub fn driveMountFilter(device: []const u8, mount_point: []const u8, fstype: []const u8) ?[]const u8 {
    if (device.len < 6) return null;
    if (!std.mem.startsWith(u8, device, "/dev/")) return null;
    if (std.mem.eql(u8, mount_point, "/")) return null;
    for ([_][]const u8{ "proc", "sysfs", "tmpfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "efivarfs", "fusectl", "securityfs", "selinuxfs", "bpf", "pstore", "debugfs", "tracefs", "hugetlbfs", "mqueue", "configfs", "autofs", "overlay", "squashfs", "rpc_pipefs", "sunrpc" }) |skip| {
        if (std.mem.eql(u8, fstype, skip)) return null;
    }
    if (std.mem.startsWith(u8, mount_point, "/media/") or std.mem.startsWith(u8, mount_point, "/run/media/") or std.mem.startsWith(u8, mount_point, "/mnt/")) {
        return mount_point;
    }
    return null;
}

test "icon_item: drive filter" {
    const t = std.testing;
    try t.expect(driveMountFilter("/dev/sdb1", "/run/media/u/disk", "ext4") != null);
    try t.expect(driveMountFilter("/dev/sdb1", "/", "ext4") == null);
    try t.expect(driveMountFilter("/dev/sdb1", "/run/media/u/d", "tmpfs") == null);
    try t.expect(driveMountFilter("tmpfs", "/run/media/u/d", "tmpfs") == null);
    try t.expect(driveMountFilter("/dev/sdb1", "/home/u", "ext4") == null);
}
