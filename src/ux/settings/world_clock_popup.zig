const std = @import("std");
const common = @import("common.zig");
const config = @import("../../config.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

// World Clock settings popup — Zig port of
// `settings_tab_desktop_widgets/world_clock_popup.{hpp,cpp}`. Same design:
// a 480px modal dialog with a timezone search field, one dropdown trigger
// row per configured city, a scrollable zoneinfo list, Save, and an
// Esc-hint footer. City config round-trips through `<leaf>/WorldClock` as
// `city_N_tz`/`city_N_label` pairs (the widget reads the same file), so Zig
// cities no longer share the C++ `~/.local/state/event-horizon/WorldClock`.
//
// State lives in `Popup` (owned by the Desktop Widgets tab page); the
// dialog is modal while open — pointer-down anywhere arms an item,
// pointer-up resolves it, exactly like the C++ consume_down/up pair.

pub const dlg_w: f64 = 480.0;
pub const panel_r: f64 = 16.0;
pub const card_r: f64 = 10.0;
pub const icon_box_s: f64 = 38.0;
pub const close_s: f64 = 26.0;
pub const box_w: f64 = 250.0;
pub const box_h: f64 = 30.0;
pub const clear_w: f64 = 26.0;
pub const clear_h: f64 = 26.0;
pub const done_w: f64 = 132.0;
pub const done_h: f64 = 34.0;
pub const row_h: f64 = 44.0;
pub const tz_item_h: f64 = 24.0;
pub const visible_tz_items: i32 = 9;

const pad: f64 = 20.0;
const header_h: f64 = 56.0;
const search_h: f64 = 44.0;
const hdr_gap: f64 = 12.0;
const grid_gap: f64 = 12.0;
const list_gap: f64 = 8.0;
const done_gap: f64 = 14.0;
const foot_gap: f64 = 16.0;
const foot_h: f64 = 18.0;

/// `<leaf>/WorldClock` under the Zig settings root (`config.leafName()`),
/// never the C++ `~/.local/state/event-horizon/WorldClock`.
pub fn configPath(alloc: std.mem.Allocator) !?[]u8 {
    const leaf = config.leafName();
    if (std.c.getenv("XDG_CONFIG_HOME")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return try std.fmt.allocPrint(alloc, "{s}/{s}/WorldClock", .{ s, leaf });
    }
    if (std.c.getenv("HOME")) |p| {
        const home = std.mem.span(p);
        if (home.len > 0)
            return try std.fmt.allocPrint(alloc, "{s}/.config/{s}/WorldClock", .{home, leaf});
    }
    return try std.fmt.allocPrint(alloc, "/tmp/{s}/WorldClock", .{leaf});
}

const linux = std.os.linux;

fn monotonicMs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(u64, @intCast(@max(ts.nsec, 0))) / 1_000_000;
}

pub const Popup = struct {
    open: bool = false,
    /// Swallow the release that opened the popup (C++ `JustOpened`).
    just_opened: bool = false,
    cities: std.ArrayListUnmanaged([]const u8) = .empty,
    tzs: std.ArrayListUnmanaged([]const u8) = .empty,
    tz_list: std.ArrayListUnmanaged([]const u8) = .empty,
    tz_filtered: std.ArrayListUnmanaged([]const u8) = .empty,
    search_buf: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    search_focus: bool = false,
    open_dropdown: i32 = -1,
    dd_scroll: i32 = 0,
    dd_hover: i32 = -1,
    hover_item: i32 = -1,
    arm_item: i32 = -1,
    caret_half: u64 = 0,

    pub fn searchSlice(self: *const Popup) []const u8 {
        return self.search_buf[0..self.search_len];
    }

    pub fn activeList(self: *const Popup) []const []const u8 {
        return if (self.search_len > 0) self.tz_filtered.items else self.tz_list.items;
    }

    pub fn reset(self: *Popup) void {
        self.* = .{};
    }
};

pub const Layout = struct {
    dlg_x: f64 = 0,
    dlg_y: f64 = 0,
    dlg_w: f64 = 0,
    dlg_h: f64 = 0,
    rows_y: f64 = 0,
    search_x: f64 = 0,
    search_y: f64 = 0,
    search_w: f64 = 0,
    search_h: f64 = 0,
    clear_x: f64 = 0,
    clear_y: f64 = 0,
    list_x: f64 = 0,
    list_y: f64 = 0,
    list_w: f64 = 0,
    list_h: f64 = 0,
    done_x: f64 = 0,
    done_y: f64 = 0,
    foot_y: f64 = 0,
    visible_items: i32 = 0,
    max_scroll: i32 = 0,
};

pub fn computeLayout(p: *const Popup, win_w: i32, win_h: i32) Layout {
    var l = Layout{};
    const n: f64 = @floatFromInt(p.cities.items.len);
    const tz_count: i32 = @intCast(p.activeList().len);
    l.visible_items = @min(visible_tz_items, tz_count);
    const list_extra: f64 = if (p.open_dropdown >= 0 and l.visible_items > 0)
        list_gap + @as(f64, @floatFromInt(l.visible_items)) * tz_item_h + 8.0
    else
        0.0;
    const rows_y_rel = pad + header_h + hdr_gap + search_h + grid_gap;
    const rows_bottom_rel = rows_y_rel + n * row_h + list_extra;
    const done_y_rel = rows_bottom_rel + done_gap;
    const foot_y_rel = done_y_rel + done_h + foot_gap;
    l.dlg_w = dlg_w;
    l.dlg_h = foot_y_rel + foot_h * 0.5 + pad;
    l.dlg_x = (@as(f64, @floatFromInt(win_w)) - l.dlg_w) * 0.5;
    l.dlg_y = (@as(f64, @floatFromInt(win_h)) - l.dlg_h) * 0.5;
    l.search_x = l.dlg_x + pad;
    l.search_y = l.dlg_y + pad + header_h;
    l.search_w = l.dlg_w - 2.0 * pad;
    l.search_h = search_h;
    l.clear_x = l.search_x + l.search_w - 14.0 - clear_w;
    l.clear_y = l.search_y + (search_h - clear_h) * 0.5;
    l.rows_y = l.search_y + search_h + grid_gap;
    l.list_x = l.dlg_x + l.dlg_w - pad - box_w;
    l.list_w = box_w;
    l.list_y = l.rows_y + n * row_h + list_gap;
    l.list_h = @as(f64, @floatFromInt(l.visible_items)) * tz_item_h + 8.0;
    l.max_scroll = @max(0, tz_count - l.visible_items);
    l.done_x = l.dlg_x + (l.dlg_w - done_w) * 0.5;
    l.done_y = l.dlg_y + done_y_rel;
    l.foot_y = l.dlg_y + foot_y_rel;
    return l;
}

// -3 close; -5 clear; -4 search; 1+i dropdown box of row i;
// 10000+idx tz item; -2 Done/Save.
pub fn hitItem(p: *const Popup, lx: f64, ly: f64, l: Layout) i32 {
    const close_x = l.dlg_x + l.dlg_w - pad - close_s;
    const close_y = l.dlg_y + pad - 2.0;
    if (inRect(lx, ly, close_x, close_y, close_s, close_s)) return -3;
    if (p.search_len > 0 and inRect(lx, ly, l.clear_x, l.clear_y, clear_w, clear_h)) return -5;
    if (inRect(lx, ly, l.search_x, l.search_y, l.search_w, l.search_h)) return -4;
    for (p.cities.items, 0..) |_, i| {
        const row_y = l.rows_y + @as(f64, @floatFromInt(i)) * row_h;
        const box_x = l.dlg_x + l.dlg_w - pad - box_w;
        const box_y = row_y + (row_h - box_h) * 0.5;
        if (inRect(lx, ly, box_x, box_y, box_w, box_h)) return @as(i32, @intCast(1 + i));
    }
    if (p.open_dropdown >= 0 and l.visible_items > 0) {
        if (inRect(lx, ly, l.list_x, l.list_y, l.list_w, l.list_h)) {
            const row: i32 = @intFromFloat(@floor((ly - l.list_y) / tz_item_h));
            const idx = p.dd_scroll + row;
            if (row >= 0 and row < l.visible_items and idx >= 0 and idx < p.activeList().len)
                return 10000 + idx;
        }
    }
    if (inRect(lx, ly, l.done_x, l.done_y, done_w, done_h)) return -2;
    return -1;
}

fn inRect(px: f64, py: f64, x: f64, y: f64, w: f64, h: f64) bool {
    return px >= x and px < x + w and py >= y and py < y + h;
}

fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn rebuildFilter(p: *Popup, alloc: std.mem.Allocator) void {
    p.tz_filtered.clearRetainingCapacity();
    if (p.search_len == 0) return;
    const needle = p.searchSlice();
    for (p.tz_list.items) |tz| {
        if (containsFold(tz, needle)) p.tz_filtered.append(alloc, tz) catch break;
    }
}

/// Enumerate `/usr/share/zoneinfo`, skipping the `posix/` + `right/`
/// duplicate subtrees, dotfiles and `localtime`. Sorted, like the C++.
pub fn enumerateZoneinfo(alloc: std.mem.Allocator, io: std.Io, out: *std.ArrayListUnmanaged([]const u8)) void {
    out.clearRetainingCapacity();
    var root = std.Io.Dir.cwd().openDir(io, "/usr/share/zoneinfo", .{ .iterate = true }) catch return;
    defer root.close(io);
    var walker = root.walk(alloc) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const rel = entry.path;
        if (std.mem.startsWith(u8, rel, "posix/") or std.mem.startsWith(u8, rel, "right/")) continue;
        const base = std.fs.path.basename(rel);
        if (base.len == 0 or base[0] == '.') continue;
        if (std.mem.eql(u8, rel, "localtime")) continue;
        out.append(alloc, alloc.dupe(u8, rel) catch continue) catch break;
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

/// Load `city_N_tz`/`city_N_label` pairs (labels default to the tz's tail,
/// truncated to 8 chars, like the widget's loader).
pub fn loadConfig(alloc: std.mem.Allocator, io: std.Io, cities: *std.ArrayListUnmanaged([]const u8), tzs: *std.ArrayListUnmanaged([]const u8)) void {
    cities.clearRetainingCapacity();
    tzs.clearRetainingCapacity();
    const path = configPath(alloc) catch return;
    if (path == null) return;
    defer alloc.free(path.?);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path.?, alloc, .limited(1 << 20)) catch return;
    defer alloc.free(text);
    var idx: usize = 1;
    while (true) : (idx += 1) {
        var tz_buf: [128]u8 = undefined;
        const tz_key = std.fmt.bufPrint(&tz_buf, "city_{d}_tz", .{idx}) catch break;
        const tz = tomlLookup(text, tz_key) orelse break;
        var lb_buf: [128]u8 = undefined;
        const lb_key = std.fmt.bufPrint(&lb_buf, "city_{d}_label", .{idx}) catch break;
        const label = tomlLookup(text, lb_key) orelse defaultLabel(tz);
        cities.append(alloc, alloc.dupe(u8, label) catch break) catch break;
        tzs.append(alloc, alloc.dupe(u8, tz) catch break) catch break;
    }
}

fn defaultLabel(tz: []const u8) []const u8 {
    const tail = if (std.mem.lastIndexOfScalar(u8, tz, '/')) |i| tz[i + 1 ..] else tz;
    return if (tail.len > 8) tail[0..8] else tail;
}

/// Minimal `key = "value"` lookup for the flat WorldClock file.
fn tomlLookup(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trim(u8, line[key.len..], " \t");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        var val = std.mem.trim(u8, rest[1..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val = val[1 .. val.len - 1];
        return val;
    }
    return null;
}

pub fn saveConfig(alloc: std.mem.Allocator, io: std.Io, cities: []const []const u8, tzs: []const []const u8) void {
    const path = configPath(alloc) catch return;
    if (path == null) return;
    defer alloc.free(path.?);
    if (std.fs.path.dirname(path.?)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const n = @min(cities.len, tzs.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const line = std.fmt.allocPrint(alloc, "city_{d}_tz = \"{s}\"\ncity_{d}_label = \"{s}\"\n", .{ i + 1, tzs[i], i + 1, cities[i] }) catch break;
        defer alloc.free(line);
        buf.appendSlice(alloc, line) catch break;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path.?, .data = buf.items }) catch {};
}

test "settings-world-clock-popup: filter + layout ids" {
    const t = std.testing;
    var p = Popup{};
    try t.expectEqual(@as(usize, 0), p.activeList().len);
    try t.expect(containsFold("America/New_York", "new"));
    try t.expect(!containsFold("Asia/Tokyo", "new"));
    const l = computeLayout(&p, 900, 700);
    try t.expectApproxEqAbs(@as(f64, 480.0), l.dlg_w, 1e-9);
    try t.expect(hitItem(&p, -1000, -1000, l) == -1);
    try t.expectEqualStrings("New_York", defaultLabel("America/New_York"));
}

test "settings-world-clock-popup: config path follows the zig leaf" {
    const t = std.testing;
    const prev = config.leafName();
    defer config.setLeafOverride(if (std.mem.eql(u8, prev, config.kLeafIsolated)) config.kLeafIsolated else null);
    config.setLeafOverride(null);
    {
        const p = try configPath(t.allocator);
        defer if (p) |v| t.allocator.free(v);
        try t.expect(p != null);
        try t.expect(std.mem.endsWith(u8, p.?, "/Event-Horizon/WorldClock"));
    }
    config.setLeafOverride(config.kLeafIsolated);
    {
        const p = try configPath(t.allocator);
        defer if (p) |v| t.allocator.free(v);
        try t.expect(p != null);
        try t.expect(std.mem.endsWith(u8, p.?, "/Event-Horizon-zig/WorldClock"));
        try t.expect(std.mem.indexOf(u8, p.?, "event-horizon/") == null);
    }
}
