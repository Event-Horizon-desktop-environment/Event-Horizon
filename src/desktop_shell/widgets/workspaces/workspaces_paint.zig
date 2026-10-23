//! Scrollable workspace strip slot: one cell per workspace showing an
//! app-icon row (up to N), else the id/name text, else a dot. Active cells
//! get the accent fill, occupied ones a grey fill, idle ones a dim fill,
//! and a 200 ms ease-out animation bridges cell resizes.
//!
//! What could not come across verbatim, and why:
//!
//! * **The poll inputs.** The global workspaces object and
//!   the config snapshot itself behind `workspace_strip_poll`. The Zig
//!   shell keeps no such global (`wl/toplevel/workspaces.zig` documents the
//!   omission), so `Strip.poll` takes the host's regions plus its
//!   desk-key → app-id map in — the throttle, the entry mapping and the
//!   max-slots gap fill are the port; the enumeration stays with the host.
//! * **The `jumpTo` call.** `activateTarget` answers the workspace id to
//!   jump to (null for placeholders); the host's own workspaces object
//!   performs the jump, ignoring any compositor-kind parameter.
//! * **The `IconCache`.** `paintWorkspacesSlot` takes an `Icons` provider
//!   (a key → cairo surface lookup the host fills in, e.g. from its icon
//!   theme); a null provider or a missing key paints the ghost tile. Steam keys keep their blue tile.
//! * **The text caches.** Two entries
//!   per instance (`:L` for layout, `:P` for paint). They are ported as-is
//!   in the local `TextCache` below rather than through the shared
//!   single-entry `layout_cache.zig`, which could only hold one of the two
//!   and would report a refresh every frame (a repaint storm). One
//!   deliberate correction: cached paint widths are indexed by text cell in
//!   encounter order — identical for
//!   text-only strips, and correct (instead of misaligned) when icon cells
//!   interleave.
//! * **`anyPaletteActive`.** The Zig schema has no such helper, so the
//!   matugen branch reads the same three terms inline
//!   (`matugen_theming && matugen_palette_ok`, `horizon_colors_native &&
//!   horizon_colors_ok`, `custom_theme_enabled`).

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const schema = @import("../../../config/schema.zig");
const desk = @import("../../../backends/desk.zig");
const pill = @import("../shared/pill.zig");
const chrome_colors = @import("../shared/chrome_colors.zig");
const wset = @import("../shared/widget_settings.zig");
const measure = @import("../shared/measure_scratch.zig");
const helpers = @import("../../shared/cairo_helpers.zig");

/// Pango has no `WRAP_NONE` in `text/layout.zig`; the `PangoWrapMode` order
/// is WORD, CHAR, WORD_CHAR, NONE.
const WRAP_NONE: c_int = 3;

const k_prim: [3]f64 = .{ 0.90, 0.90, 0.90 };
const k_surf: [3]f64 = .{ 0.96, 0.98, 0.99 };
/// `workspace_strip_poll` re-reads at most every 280 ms.
pub const poll_throttle_ms: i64 = 280;
/// `WsStripAnimState::durationMs`.
pub const anim_duration_ms: u64 = 200;

// Model

/// `WorkspaceEntry` — owned strings; see `Strip`.
pub const Entry = struct {
    id: i32 = 0,
    label: []u8 = &.{},
    active: bool = false,
    occupied: bool = false,
    urgent: bool = false,
    app_keys: [][]const u8 = &.{},
};

pub const DisplayMode = enum { id, name, none };

/// `parse_display_mode` — `name`/`none`, anything else (or absent) is `id`.
pub fn parseDisplayMode(sc: *const schema.ShellConfig, instance_id: []const u8) DisplayMode {
    const raw = wset.widgetSetting(sc, instance_id, "display");
    if (std.mem.eql(u8, raw, "name")) return .name;
    if (std.mem.eql(u8, raw, "none")) return .none;
    return .id;
}

/// `parse_show_workspace_apps` — defaults on.
pub fn parseShowApps(sc: *const schema.ShellConfig, instance_id: []const u8) bool {
    return wset.settingBool(sc, instance_id, "show_apps", true);
}

/// `parse_max_workspace_icons` — defaults to 4, clamps to `[1, 8]`.
pub fn parseMaxIcons(sc: *const schema.ShellConfig, instance_id: []const u8) i32 {
    return @intCast(wset.settingInt(sc, instance_id, "max_workspace_icons", 1, 8, 4));
}

/// `workspace_max_slots_from_settings` — defaults to 5, clamps to `[0, 32]`.
/// Zero (or negative, clamped to zero) disables the gap fill.
pub fn maxSlotsFromSettings(sc: *const schema.ShellConfig, instance_id: []const u8) i32 {
    return @intCast(wset.settingInt(sc, instance_id, "max_workspaces", 0, 32, 5));
}

/// `cell_text` — the cell's label under `mode`. `buf` (≥12 bytes) carries
/// the decimal id when no label is used.
pub fn cellText(e: *const Entry, mode: DisplayMode, buf: []u8) []const u8 {
    return switch (mode) {
        .none => "",
        .id => std.fmt.bufPrint(buf, "{d}", .{e.id}) catch "",
        .name => if (e.label.len > 0) e.label else std.fmt.bufPrint(buf, "{d}", .{e.id}) catch "",
    };
}

/// `workspace_strip_apply_max_slots` — sorts by id, then walks `1..max`
/// keeping matches and manufacturing `{id, "id"}` placeholders for the
/// gaps. `max_slots <= 0` leaves the list alone. Returns an owned list.
pub fn applyMaxSlots(alloc: std.mem.Allocator, entries: []const Entry, max_slots: i32) ![]Entry {
    if (max_slots <= 0) {
        var out = try alloc.alloc(Entry, entries.len);
        for (entries, 0..) |*e, i| out[i] = .{
            .id = e.id,
            .label = try alloc.dupe(u8, e.label),
            .active = e.active,
            .occupied = e.occupied,
            .urgent = e.urgent,
            .app_keys = try dupeKeys(alloc, e.app_keys),
        };
        return out;
    }
    var sorted = try alloc.alloc(Entry, entries.len);
    defer alloc.free(sorted);
    for (entries, 0..) |*e, i| sorted[i] = e.*;
    std.mem.sort(Entry, sorted, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.id < b.id;
        }
    }.lt);
    var out = std.ArrayList(Entry).empty;
    errdefer {
        for (out.items) |*e| freeEntry(alloc, e);
        out.deinit(alloc);
    }
    var idx: usize = 0;
    var id: i32 = 1;
    while (id <= max_slots) : (id += 1) {
        if (idx < sorted.len and sorted[idx].id == id) {
            const src = sorted[idx];
            try out.append(alloc, .{
                .id = src.id,
                .label = try alloc.dupe(u8, src.label),
                .active = src.active,
                .occupied = src.occupied,
                .urgent = src.urgent,
                .app_keys = try dupeKeys(alloc, src.app_keys),
            });
            idx += 1;
        } else {
            var num: [12]u8 = undefined;
            const label = std.fmt.bufPrint(&num, "{d}", .{id}) catch "?";
            try out.append(alloc, .{
                .id = id,
                .label = try alloc.dupe(u8, label),
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

fn dupeKeys(alloc: std.mem.Allocator, keys: []const []const u8) ![][]const u8 {
    var out = try alloc.alloc([]const u8, keys.len);
    for (keys, 0..) |k, i| out[i] = try alloc.dupe(u8, k);
    return out;
}

fn freeEntry(alloc: std.mem.Allocator, e: *Entry) void {
    alloc.free(e.label);
    for (e.app_keys) |k| alloc.free(k);
    alloc.free(e.app_keys);
    e.* = .{};
}

/// Release a list built by `applyMaxSlots` or by hand. Hosts own their
/// entries because the paint path only ever borrows them.
pub fn freeEntries(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*e| freeEntry(alloc, e);
    alloc.free(entries);
}

/// The polled strip: owned entries plus the throttle stamp. This is the
/// output vector plus `last_poll_mono` threaded through
/// `workspace_strip_poll`.
pub const Strip = struct {
    alloc: std.mem.Allocator,
    entries: []Entry = &.{},
    last_poll_ms: ?i64 = null,

    pub fn init(alloc: std.mem.Allocator) Strip {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Strip) void {
        for (self.entries) |*e| freeEntry(self.alloc, e);
        self.alloc.free(self.entries);
        self.entries = &.{};
    }

    /// Monotonic milliseconds — the `CLOCK_MONOTONIC` stamp the throttle
    /// compares.
    pub fn nowMs() i64 {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
            @divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), 1000000);
    }

    /// `workspace_strip_poll` — rebuilds from the host's regions plus its
    /// desk-key → app-id map, at most every 280 ms. `max_slots` applies the
    /// gap fill (0 disables it). Answers whether the strip was rebuilt;
    /// a throttled call leaves everything untouched.
    pub fn poll(
        self: *Strip,
        now_ms: i64,
        regions: []const desk.Region,
        appmap: *const desk.AppMap,
        max_slots: i32,
    ) !bool {
        if (self.last_poll_ms) |last| {
            const dt = now_ms - last;
            if (dt >= 0 and dt < poll_throttle_ms and self.entries.len > 0) return false;
        }
        self.last_poll_ms = now_ms;
        var fresh = std.ArrayList(Entry).empty;
        errdefer {
            for (fresh.items) |*e| freeEntry(self.alloc, e);
            fresh.deinit(self.alloc);
        }
        for (regions) |r| {
            const keys: []const []const u8 = if (appmap.get(r.id)) |v| v.items else &.{};
            try fresh.append(self.alloc, .{
                .id = @intCast(r.index),
                .label = try self.alloc.dupe(u8, if (r.name.len > 0) r.name else r.id),
                .active = r.active,
                .occupied = r.occupied,
                .urgent = r.urgent,
                .app_keys = try dupeKeys(self.alloc, keys),
            });
        }
        const filled = try applyMaxSlots(self.alloc, fresh.items, max_slots);
        for (fresh.items) |*e| freeEntry(self.alloc, e);
        fresh.deinit(self.alloc);
        for (self.entries) |*e| freeEntry(self.alloc, e);
        self.alloc.free(self.entries);
        self.entries = filled;
        return true;
    }
};

/// `workspace_activate_entry` — the id to jump to, or null for placeholders
/// (`id <= 0`). The host performs the jump on its own workspaces object.
pub fn activateTarget(e: *const Entry, buf: []u8) ?[]const u8 {
    if (e.id <= 0) return null;
    return std.fmt.bufPrint(buf, "{d}", .{e.id}) catch null;
}

/// `widget_list_contains_workspaces`.
pub fn widgetListContainsWorkspaces(sc: *const schema.ShellConfig, list: []const []const u8) bool {
    return wset.listContainsImpl(sc, list, "workspaces");
}

// Strip animation

pub const CellGeom = struct {
    x: f64 = 0,
    w: f64 = 0,
};

/// `WsStripAnimState` — eases cell geometry over 200 ms with an ease-out
/// cubic (`1 - (1-t)^3`).
pub const AnimState = struct {
    from_cells: std.ArrayList(CellGeom) = .empty,
    to_cells: std.ArrayList(CellGeom) = .empty,
    start_ms: u64 = 0,
    duration_ms: u64 = anim_duration_ms,
    active: bool = false,
    alloc: std.mem.Allocator = std.heap.page_allocator,

    pub fn init(alloc: std.mem.Allocator) AnimState {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *AnimState) void {
        self.from_cells.deinit(self.alloc);
        self.to_cells.deinit(self.alloc);
    }

    pub fn reset(self: *AnimState) void {
        self.from_cells.clearRetainingCapacity();
        self.to_cells.clearRetainingCapacity();
        self.active = false;
        self.start_ms = 0;
    }

    /// `updateTargets` — first call only latches the targets; later calls
    /// sample the in-flight geometry as the new start.
    pub fn updateTargets(self: *AnimState, new_cells: []const CellGeom, now_ms: u64) !void {
        if (self.to_cells.items.len == 0) {
            self.to_cells.clearRetainingCapacity();
            try self.to_cells.appendSlice(self.alloc, new_cells);
            return;
        }
        try self.from_cells.ensureTotalCapacity(self.alloc, new_cells.len);
        self.from_cells.clearRetainingCapacity();
        for (new_cells, 0..) |nc, i| {
            if (self.active and i < self.to_cells.items.len) {
                try self.from_cells.append(self.alloc, .{ .x = self.getX(i, now_ms), .w = self.getW(i, now_ms) });
            } else if (i < self.to_cells.items.len) {
                try self.from_cells.append(self.alloc, self.to_cells.items[i]);
            } else {
                try self.from_cells.append(self.alloc, nc);
            }
        }
        self.to_cells.clearRetainingCapacity();
        try self.to_cells.appendSlice(self.alloc, new_cells);
        self.start_ms = now_ms;
        self.active = true;
    }

    pub fn progress(self: *const AnimState, now_ms: u64) f32 {
        const elapsed = now_ms -| self.start_ms;
        if (elapsed >= self.duration_ms) return 1.0;
        return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ms));
    }

    fn ease(t: f32) f64 {
        return 1.0 - std.math.pow(f64, 1.0 - @as(f64, t), 3.0);
    }

    pub fn getX(self: *const AnimState, i: usize, now_ms: u64) f64 {
        if (!self.active or i >= self.from_cells.items.len or i >= self.to_cells.items.len)
            return if (i < self.to_cells.items.len) self.to_cells.items[i].x else 0.0;
        const e = ease(self.progress(now_ms));
        return self.from_cells.items[i].x + (self.to_cells.items[i].x - self.from_cells.items[i].x) * e;
    }

    pub fn getW(self: *const AnimState, i: usize, now_ms: u64) f64 {
        if (!self.active or i >= self.from_cells.items.len or i >= self.to_cells.items.len)
            return if (i < self.to_cells.items.len) self.to_cells.items[i].w else 0.0;
        const e = ease(self.progress(now_ms));
        return self.from_cells.items[i].w + (self.to_cells.items[i].w - self.from_cells.items[i].w) * e;
    }
};

// Layout

/// Key → cairo surface lookup the host fills in (its icon theme). Null when
/// the host has no icons: every cell paints the ghost tile.
pub const Icons = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, key: []const u8) ?*cairo.cairo_surface_t,
};

pub const LayoutResult = struct {
    cells: []CellGeom,
    gap: f64,
    hpad: f64,
    pill_h: f64,
    /// Whether the text cache was refreshed (the host must repaint).
    refreshed: bool,
};

/// One `WorkspaceTextCache` entry: joined-texts key, font size, measured
/// widths/heights and the layout that produced them.
const TextEntry = struct {
    key: []u8 = &.{},
    font_px: i32 = 0,
    widths: [40]i32 = @as([40]i32, @splat(0)),
    heights: [40]i32 = @as([40]i32, @splat(0)),
    n: usize = 0,
    layout: ?*text.PangoLayout = null,
};

var g_text: std.StringHashMap(TextEntry) = undefined;
var g_text_ready: bool = false;

fn textMap() *std.StringHashMap(TextEntry) {
    if (!g_text_ready) {
        g_text = std.StringHashMap(TextEntry).init(std.heap.page_allocator);
        g_text_ready = true;
    }
    return &g_text;
}

/// Drops every module-level cache, kept for the life of the
/// process; `reset` exists for tests and for a host that wants a clean slate.
pub fn reset() void {
    if (!g_text_ready) return;
    var it = g_text.iterator();
    while (it.next()) |e| {
        std.heap.page_allocator.free(e.key_ptr.*);
        if (e.value_ptr.layout) |lo| text.Layout.release(lo);
    }
    g_text.clearRetainingCapacity();
}

fn textFind(kid: []const u8) ?*TextEntry {
    if (!g_text_ready) return null;
    return g_text.getPtr(kid);
}

/// Fetch-or-create the entry for `kid`, resetting it when the key or font
/// moved. Answers the entry plus whether it was just (re)created — the
/// caller then fills `widths`/`heights` and owns no layout work beyond that.
fn textEntryFor(kid: []const u8, key: []const u8, font_px: i32) ?*TextEntry {
    const m = textMap();
    if (m.getPtr(kid)) |e| {
        if (e.font_px == font_px and std.mem.eql(u8, e.key, key)) return e;
        std.heap.page_allocator.free(e.key);
        if (e.layout) |lo| {
            text.Layout.release(lo);
            e.layout = null;
        }
        e.key = std.heap.page_allocator.dupe(u8, key) catch return null;
        e.font_px = font_px;
        e.n = 0;
        return e;
    }
    const owned_id = std.heap.page_allocator.dupe(u8, kid) catch return null;
    const owned_key = std.heap.page_allocator.dupe(u8, key) catch {
        std.heap.page_allocator.free(owned_id);
        return null;
    };
    const gop = m.getOrPut(owned_id) catch {
        std.heap.page_allocator.free(owned_id);
        std.heap.page_allocator.free(owned_key);
        return null;
    };
    if (gop.found_existing) {
        std.heap.page_allocator.free(owned_id);
        std.heap.page_allocator.free(owned_key);
        return null;
    }
    gop.key_ptr.* = owned_id;
    gop.value_ptr.* = .{ .key = owned_key, .font_px = font_px };
    return gop.value_ptr;
}

/// The entry's layout, rebuilt when the font moved, updated for the current
/// transform otherwise. Returned as a `text.Layout` view the caller must
/// not destroy.
fn entryLayout(e: *TextEntry, cr: ?*cairo.cairo_t, font_desc: []const u8) text.Layout {
    const c = cr orelse return .{};
    if (e.layout) |lo| {
        text.pango_cairo_update_layout(c, lo);
        return .{ .layout = lo };
    }
    var built = text.Layout.createForCairo(c);
    built.setFont(font_desc);
    e.layout = built.layout;
    return built;
}

fn fontDescInter(buf: *[48]u8, font_px: i32) []const u8 {
    return std.fmt.bufPrint(buf, "Inter SemiBold {d}", .{font_px}) catch unreachable;
}

/// Measures one cell text with a throwaway layout, exactly like the cache
/// miss branches (layout-construction spots).
fn measureText(cr: ?*cairo.cairo_t, font_desc: []const u8, txt: []const u8) struct { w: i32, h: i32 } {
    const c = cr orelse return .{ .w = 0, .h = 0 };
    var l = text.Layout.createForCairo(c);
    defer l.destroy();
    l.setFont(font_desc);
    l.setWrap(WRAP_NONE);
    l.setEllipsize(text.ELLIPSIZE_NONE);
    l.setText(txt);
    const s = l.pixelSize();
    return .{ .w = s.w, .h = s.h };
}

/// `layout_cells` — natural cell widths (icon rows measured arithmetically,
/// texts through pango), then a scale-to-fit pass into `slot_w`. Answers
/// the cells plus gap/pads and whether the text cache refreshed.
pub fn layoutCells(
    alloc: std.mem.Allocator,
    measure_cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
    slot_w: f64,
    slot_h: f64,
    entries: []const Entry,
) !LayoutResult {
    var cells = std.ArrayList(CellGeom).empty;
    errdefer cells.deinit(alloc);
    const s = icon_ref_px / 30.0;
    const hpad = @max(6.0, 8.0 * s);
    const gap = @max(4.0, 6.0 * s);
    const pill_h = slot_h * pill.pill_height_mul;
    if (entries.len == 0 or slot_w <= 1.0) {
        return .{ .cells = try cells.toOwnedSlice(alloc), .gap = gap, .hpad = hpad, .pill_h = pill_h, .refreshed = false };
    }
    const mode = parseDisplayMode(sc, instance_id);
    const dot_d = @max(6.0, @round(icon_ref_px * 0.20));
    const pill_min = @max(22.0, @round(icon_ref_px * 0.52));
    const font_px: i32 = @max(9, @as(i32, @intFromFloat(@round(10.0 * s))));
    const show_apps = parseShowApps(sc, instance_id);
    const max_icons = parseMaxIcons(sc, instance_id);

    const mcr = measure_cr orelse measure.measureCr();

    var kbuf: [2048]u8 = undefined;
    var klen: usize = 0;
    kbuf[0] = if (show_apps) 'a' else 'A';
    klen = 1;
    {
        var nbuf: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nbuf, "{d}", .{max_icons}) catch "?";
        @memcpy(kbuf[klen..][0..ns.len], ns);
        klen += ns.len;
    }
    var tbuf: [16]u8 = undefined;
    for (entries) |*e| {
        const t = cellText(e, mode, &tbuf);
        for (t) |ch| {
            if (klen >= kbuf.len) break;
            kbuf[klen] = ch;
            klen += 1;
        }
        if (klen >= kbuf.len) break;
        kbuf[klen] = '\n';
        klen += 1;
        var nbuf: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nbuf, "{d},", .{e.app_keys.len}) catch "?";
        for (ns) |ch| {
            if (klen >= kbuf.len) break;
            kbuf[klen] = ch;
            klen += 1;
        }
        if (klen >= kbuf.len) break;
    }
    {
        var nbuf: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nbuf, "{d}", .{font_px}) catch "?";
        for (ns) |ch| {
            if (klen >= kbuf.len) break;
            kbuf[klen] = ch;
            klen += 1;
        }
    }
    const ws_key = kbuf[0..klen];

    var fbuf: [48]u8 = undefined;
    const fd = fontDescInter(&fbuf, font_px);

    var widths = std.ArrayList(f64).empty;
    defer widths.deinit(alloc);
    var refreshed = false;

    var kidbuf: [128]u8 = undefined;
    const kid = std.fmt.bufPrint(&kidbuf, "{s}:L", .{instance_id}) catch instance_id;
    if (textFind(kid)) |e| {
        if (e.font_px == font_px and std.mem.eql(u8, e.key, ws_key)) {
            for (e.widths[0..@min(e.n, entries.len)]) |w| try widths.append(alloc, @floatFromInt(w));
        }
    }
    if (widths.items.len == 0 and mcr != null) {
        const entry = textEntryFor(kid, ws_key, font_px);
        var cwidths: [40]i32 = @as([40]i32, @splat(0));
        var cn: usize = 0;
        for (entries) |*e| {
            if (show_apps and e.app_keys.len > 0) {
                const n: usize = @intCast(@min(max_icons, @as(i32, @intCast(e.app_keys.len))));
                const icon_cell = pill_h * 0.62;
                const igap = @max(2.0, 3.0 * s);
                const ipad = @max(4.0, 6.0 * s);
                const iw = @as(f64, @floatFromInt(n)) * icon_cell +
                    @as(f64, @floatFromInt(@max(n, 1) - 1)) * igap + 2.0 * ipad;
                const w = @max(pill_min, iw);
                try widths.append(alloc, w);
                if (cn < cwidths.len) {
                    cwidths[cn] = @intFromFloat(w);
                    cn += 1;
                }
                continue;
            }
            const txt = cellText(e, mode, &tbuf);
            if (mode == .none) {
                const w: f64 = if (e.active) pill_min else dot_d;
                try widths.append(alloc, w);
                if (cn < cwidths.len) {
                    cwidths[cn] = @intFromFloat(w);
                    cn += 1;
                }
                continue;
            }
            if (txt.len == 0) {
                try widths.append(alloc, dot_d);
                if (cn < cwidths.len) {
                    cwidths[cn] = @intFromFloat(dot_d);
                    cn += 1;
                }
                continue;
            }
            const ms = measureText(mcr, fd, txt);
            const w = @max(pill_min, @as(f64, @floatFromInt(ms.w)) + 12.0 * s);
            try widths.append(alloc, w);
            if (cn < cwidths.len) {
                cwidths[cn] = @intFromFloat(w);
                cn += 1;
            }
        }
        refreshed = true;
        if (entry) |ent| {
            const n = @min(cn, ent.widths.len);
            @memcpy(ent.widths[0..n], cwidths[0..n]);
            ent.n = n;
        }
    } else if (widths.items.len == 0) {
        for (entries) |*e| {
            if (show_apps and e.app_keys.len > 0) {
                const n: usize = @intCast(@min(max_icons, @as(i32, @intCast(e.app_keys.len))));
                const icon_cell = pill_h * 0.62;
                const igap = @max(2.0, 3.0 * s);
                const ipad = @max(4.0, 6.0 * s);
                const iw = @as(f64, @floatFromInt(n)) * icon_cell +
                    @as(f64, @floatFromInt(@max(n, 1) - 1)) * igap + 2.0 * ipad;
                try widths.append(alloc, @max(pill_min, iw));
                continue;
            }
            if (mode == .none) {
                try widths.append(alloc, if (e.active) pill_min else dot_d);
            } else {
                try widths.append(alloc, pill_min);
            }
        }
    }

    var sum: f64 = 0;
    for (widths.items, 0..) |w, i| {
        sum += w;
        if (i + 1 < widths.items.len) sum += gap;
    }
    const inner = @max(1.0, slot_w - 2.0 * hpad);
    var scale: f64 = 1.0;
    if (sum > inner + 0.5 and sum > 1.0) scale = inner / sum;

    // The row is centred in what the slot leaves for it rather than glued to
    // the left pad: the widget's own width floor, the fit pass's shrink, and
    // an idle cell or two all leave slack, and a row pinned to one side reads
    // as broken inside the pill it draws in.
    const row_w = sum * scale;
    var x = hpad + @max(0.0, inner - row_w) * 0.5;
    for (widths.items, 0..) |w, i| {
        const cw = @max(4.0, w * scale);
        try cells.append(alloc, .{ .x = x, .w = cw });
        x += cw;
        if (i + 1 < widths.items.len) x += gap * scale;
    }
    return .{ .cells = try cells.toOwnedSlice(alloc), .gap = gap, .hpad = hpad, .pill_h = pill_h, .refreshed = refreshed };
}

/// `dock_workspaces_slot_width` — `min(bar*3.5, 120)` when empty, else pads
/// plus natural widths, clamped to `[60, min(bar*22, 920)]`.
pub fn dockWorkspacesSlotWidth(
    measure_cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
    bar_height: f64,
    entries: []const Entry,
) f64 {
    if (entries.len == 0) return @min(bar_height * 3.5, 120.0);
    const s = icon_ref_px / 30.0;
    const hpad = @max(6.0, 8.0 * s);
    const gap = @max(4.0, 6.0 * s);
    const mode = parseDisplayMode(sc, instance_id);
    const dot_d = @max(6.0, @round(icon_ref_px * 0.20));
    const pill_min = @max(22.0, @round(icon_ref_px * 0.52));
    const font_px: i32 = @max(9, @as(i32, @intFromFloat(@round(10.0 * s))));
    const pill_h_meas = icon_ref_px * pill.pill_height_mul;
    const show_apps = parseShowApps(sc, instance_id);
    const max_icons = parseMaxIcons(sc, instance_id);
    const mcr = measure_cr orelse measure.measureCr();
    var fbuf: [48]u8 = undefined;
    const fd = fontDescInter(&fbuf, font_px);
    var tbuf: [16]u8 = undefined;
    var sum: f64 = 0;
    for (entries, 0..) |*e, i| {
        var w = pill_min;
        if (show_apps and e.app_keys.len > 0) {
            const n: usize = @intCast(@min(max_icons, @as(i32, @intCast(e.app_keys.len))));
            const icon_cell = pill_h_meas * 0.62;
            const igap = @max(2.0, 3.0 * s);
            const ipad = @max(4.0, 6.0 * s);
            w = @max(pill_min, @as(f64, @floatFromInt(n)) * icon_cell +
                @as(f64, @floatFromInt(@max(n, 1) - 1)) * igap + 2.0 * ipad);
        } else if (mode == .none) {
            w = if (e.active) pill_min else dot_d;
        } else {
            const txt = cellText(e, mode, &tbuf);
            if (txt.len > 0) {
                const ms = measureText(mcr, fd, txt);
                w = @max(pill_min, @as(f64, @floatFromInt(ms.w)) + 12.0 * s);
            } else {
                w = dot_d;
            }
        }
        sum += w;
        if (i + 1 < entries.len) sum += gap;
    }
    const natural = 2.0 * hpad + sum;
    return std.math.clamp(natural, 60.0, @min(bar_height * 22.0, 920.0));
}

// Paint

fn drawScaledIconAlpha(cr: ?*cairo.cairo_t, surf: ?*cairo.cairo_surface_t, ix: f64, iy: f64, cell_sz: f64, alpha: f64) void {
    const c = cr orelse return;
    const sf = surf orelse return;
    if (alpha <= 0.001) return;
    const sw: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(sf));
    const sh: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(sf));
    if (sw <= 0 or sh <= 0) return;
    const sc = @min(cell_sz / sw, cell_sz / sh);
    cairo.cairo_save(c);
    cairo.cairo_translate(c, ix + (cell_sz - sw * sc) * 0.5, iy + (cell_sz - sh * sc) * 0.5);
    cairo.cairo_scale(c, sc, sc);
    cairo.cairo_set_source_surface(c, sf, 0, 0);
    cairo.cairo_paint_with_alpha(c, alpha);
    cairo.cairo_restore(c);
}

fn drawSteamTile(cr: ?*cairo.cairo_t, ix: f64, iy: f64, cell_sz: f64, alpha: f64) void {
    const c = cr orelse return;
    const rr = @max(2.0, cell_sz * 0.22);
    helpers.roundedRect(c, ix, iy, cell_sz, cell_sz, rr);
    cairo.cairo_set_source_rgba(c, 0.55, 0.72, 0.94, 0.5 * alpha);
    cairo.cairo_fill(c);
}

fn isSteamKey(key: []const u8) bool {
    return std.mem.indexOf(u8, key, "steam_app") != null;
}

/// `paint_workspaces_slot` — pill, per-cell active/occupied/idle fills, then
/// icon rows or centred text. Answers whether the host must repaint (text
/// cache refresh or a running resize animation). A null `cr` still runs the
/// layout so width-only callers share the path.
pub fn paintWorkspacesSlot(
    alloc: std.mem.Allocator,
    cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    x: f64,
    y: f64,
    slot_w: f64,
    slot_h: f64,
    icon_ref_px: f64,
    entries: []const Entry,
    hovered: bool,
    pressed: bool,
    icons: ?Icons,
    anim: ?*AnimState,
    now_ms: u64,
) !bool {
    _ = hovered;
    if (slot_w <= 1.0) return false;
    const c = cr;
    const pill_h = slot_h * pill.pill_height_mul;
    const pill_y = y + (slot_h - pill_h) * 0.5;

    if (c) |cc| {
        cairo.cairo_save(cc);
        pill.paintPill(cc, x, pill_y, slot_w, pill_h);
        pill.pillClipPath(cc, x, pill_y, slot_w, pill_h);
        cairo.cairo_clip(cc);
    }
    defer if (c) |cc| cairo.cairo_restore(cc);

    if (entries.len == 0) {
        if (c) |cc| {
            var l = text.Layout.createForCairo(cc);
            defer l.destroy();
            l.setFont("Inter SemiBold 10");
            l.setText("—");
            const s = l.pixelSize();
            cairo.cairo_set_source_rgba(cc, k_surf[0], k_surf[1], k_surf[2], 0.45);
            cairo.cairo_move_to(cc, x + (slot_w - @as(f64, @floatFromInt(s.w))) * 0.5, pill_y + (pill_h - @as(f64, @floatFromInt(s.h))) * 0.5);
            // "\342\200\224" is U+2014 EM DASH.
            l.show(cc);
        }
        return false;
    }

    const laid = try layoutCells(alloc, c, sc, instance_id, icon_ref_px, slot_w, slot_h, entries);
    defer alloc.free(laid.cells);
    var needs_redraw = laid.refreshed;

    if (anim) |a| {
        if (a.to_cells.items.len != laid.cells.len) {
            try a.updateTargets(laid.cells, now_ms);
        } else {
            for (laid.cells, 0..) |nc, i| {
                if (@abs(a.to_cells.items[i].x - nc.x) > 0.5 or @abs(a.to_cells.items[i].w - nc.w) > 0.5) {
                    try a.updateTargets(laid.cells, now_ms);
                    break;
                }
            }
        }
        if (a.active) {
            if (a.progress(now_ms) >= 1.0) {
                a.active = false;
            } else {
                for (laid.cells, 0..) |*cell, i| {
                    cell.x = a.getX(i, now_ms);
                    cell.w = a.getW(i, now_ms);
                }
                needs_redraw = true;
            }
        }
    }

    const cc = c orelse return needs_redraw;
    const mode = parseDisplayMode(sc, instance_id);
    const s = icon_ref_px / 30.0;
    const font_px: i32 = @max(9, @as(i32, @intFromFloat(@round(10.0 * s))));
    var fbuf: [48]u8 = undefined;
    const fd = fontDescInter(&fbuf, font_px);
    const show_apps = parseShowApps(sc, instance_id);
    const max_icons: usize = @intCast(parseMaxIcons(sc, instance_id));

    var pbuf: [2048]u8 = undefined;
    var plen: usize = 0;
    var tbuf: [16]u8 = undefined;
    for (entries) |*e| {
        const t = cellText(e, mode, &tbuf);
        for (t) |ch| {
            if (plen >= pbuf.len) break;
            pbuf[plen] = ch;
            plen += 1;
        }
        if (plen >= pbuf.len) break;
        pbuf[plen] = '\n';
        plen += 1;
    }
    {
        var nbuf: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nbuf, "{d}", .{font_px}) catch "?";
        for (ns) |ch| {
            if (plen >= pbuf.len) break;
            pbuf[plen] = ch;
            plen += 1;
        }
    }
    const paint_key = pbuf[0..plen];
    var kidbuf: [128]u8 = undefined;
    const kid = std.fmt.bufPrint(&kidbuf, "{s}:P", .{instance_id}) catch instance_id;
    const pentry = textEntryFor(kid, paint_key, font_px);
    var pl = if (pentry) |pe| entryLayout(pe, cc, fd) else text.Layout{};
    pl.setAlignment(text.ALIGN_CENTER);

    const a = sc.appearance;
    const matugen_chrome = (a.matugen_theming and a.matugen_palette_ok) or
        (a.horizon_colors_native and a.horizon_colors_ok) or a.custom_theme_enabled;
    const mc = chrome_colors.of(sc);
    const fill_r = if (matugen_chrome) mc.accent.r else k_prim[0];
    const fill_g = if (matugen_chrome) mc.accent.g else k_prim[1];
    const fill_b = if (matugen_chrome) mc.accent.b else k_prim[2];
    const tx_r = if (matugen_chrome) k_surf[0] else 0.04;
    const tx_g = if (matugen_chrome) k_surf[1] else 0.10;
    const tx_b = if (matugen_chrome) k_surf[2] else 0.09;

    var pw: [40]i32 = @as([40]i32, @splat(0));
    var ph: [40]i32 = @as([40]i32, @splat(0));
    var pn: usize = 0;
    var cache_miss = false;

    for (entries, 0..) |*e, i| {
        if (i >= laid.cells.len) break;
        const cell = laid.cells[i];
        const cx = x + cell.x;
        const cw = cell.w;
        const rr = @min(cw * 0.5, pill_h * 0.5) - 1.0;
        const fill_r2 = @max(2.0, rr * 0.5);

        if (e.active) {
            helpers.roundedRect(cc, cx, pill_y + 2.0, cw, pill_h - 4.0, fill_r2);
            cairo.cairo_set_source_rgba(cc, fill_r, fill_g, fill_b, if (pressed) 0.85 else 0.75);
            cairo.cairo_fill(cc);
        } else if (e.occupied) {
            helpers.roundedRect(cc, cx, pill_y + 2.0, cw, pill_h - 4.0, fill_r2);
            cairo.cairo_set_source_rgba(cc, 0.35, 0.38, 0.42, 0.55);
            cairo.cairo_fill(cc);
        } else {
            helpers.roundedRect(cc, cx, pill_y + 2.0, cw, pill_h - 4.0, fill_r2);
            cairo.cairo_set_source_rgba(cc, 0.22, 0.24, 0.26, 0.45);
            cairo.cairo_fill(cc);
        }

        const txt = cellText(e, mode, &tbuf);
        const icon_alpha: f64 = if (e.active) 1.0 else 0.62;

        if (show_apps and e.app_keys.len > 0) {
            if (icons) |lookup| {
                const n = @min(max_icons, e.app_keys.len);
                const icon_cell = pill_h * 0.62;
                const igap = @max(2.0, 3.0 * s);
                const row_w = @as(f64, @floatFromInt(n)) * icon_cell +
                    @as(f64, @floatFromInt(@max(n, 1) - 1)) * igap;
                const ix0 = cx + (cw - row_w) * 0.5;
                const iy0 = pill_y + (pill_h - icon_cell) * 0.5;
                for (e.app_keys[0..n], 0..) |ak, ki| {
                    const ixx = ix0 + @as(f64, @floatFromInt(ki)) * (icon_cell + igap);
                    if (isSteamKey(ak)) {
                        drawSteamTile(cc, ixx, iy0, icon_cell, icon_alpha);
                    } else if (lookup.get(lookup.ctx, ak)) |surf| {
                        drawScaledIconAlpha(cc, surf, ixx, iy0, icon_cell, icon_alpha);
                    } else {
                        helpers.roundedRect(cc, ixx, iy0, icon_cell, icon_cell, @max(2.0, icon_cell * 0.22));
                        cairo.cairo_set_source_rgba(cc, 0.55, 0.60, 0.65, 0.25 * icon_alpha);
                        cairo.cairo_fill(cc);
                    }
                }
            }
        } else if (txt.len > 0) {
            pl.setText(txt);
            pl.setWrap(WRAP_NONE);
            pl.setEllipsize(text.ELLIPSIZE_NONE);
            pl.setAlignment(text.ALIGN_CENTER);
            var tw: i32 = 0;
            var th: i32 = 0;
            if (pentry) |pe| {
                // A cached measurement is only trusted when it is real: a
                // frame that once stored zeros must not anchor the text at
                // the cell centre on every later frame.
                if (pn < pe.n and pe.widths[pn] > 0 and pe.heights[pn] > 0) {
                    tw = pe.widths[pn];
                    th = pe.heights[pn];
                } else {
                    const ms = pl.pixelSize();
                    tw = ms.w;
                    th = ms.h;
                    cache_miss = true;
                }
            } else {
                const ms = pl.pixelSize();
                tw = ms.w;
                th = ms.h;
            }
            // Every cell records its measurement, cached or fresh, so the
            // write-back stores a full table instead of a partial one.
            if (pn < pw.len) {
                pw[pn] = tw;
                ph[pn] = th;
            }
            pn += 1;
            if (e.active) {
                cairo.cairo_set_source_rgba(cc, tx_r, tx_g, tx_b, 1.0);
            } else {
                cairo.cairo_set_source_rgba(cc, k_surf[0], k_surf[1], k_surf[2], 0.88);
            }
            cairo.cairo_move_to(cc, cx + (cw - @as(f64, @floatFromInt(tw))) * 0.5, pill_y + (pill_h - @as(f64, @floatFromInt(th))) * 0.5);
            pl.show(cc);
        }
    }

    if (cache_miss) {
        if (pentry) |pe| {
            const n = @min(pn, pe.widths.len);
            @memcpy(pe.widths[0..n], pw[0..n]);
            @memcpy(pe.heights[0..n], ph[0..n]);
            pe.n = n;
        }
    }
    return needs_redraw;
}

/// `workspaces_pick_index` — nearest cell centre to `local_x`, or -1 when
/// there is nothing to pick.
pub fn pickIndex(
    alloc: std.mem.Allocator,
    local_x: f64,
    slot_w: f64,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
    entries: []const Entry,
) !i32 {
    if (entries.len == 0 or slot_w <= 1.0) return -1;
    // Measure against a null context here with `slot_h =
    // icon_ref_px`; text falls back to `pill_min` widths, icons to math.
    const laid = try layoutCells(alloc, null, sc, instance_id, icon_ref_px, slot_w, icon_ref_px, entries);
    defer alloc.free(laid.cells);
    if (laid.cells.len == 0) return -1;
    var best: i32 = 0;
    var best_dist = @abs(local_x - (laid.cells[0].x + laid.cells[0].w * 0.5));
    for (laid.cells[1..], 1..) |cell, i| {
        const d = @abs(local_x - (cell.x + cell.w * 0.5));
        if (d < best_dist) {
            best_dist = d;
            best = @intCast(i);
        }
    }
    return best;
}

// Tests

fn testEntry(id: i32, label: []const u8, active: bool, occupied: bool, keys: []const []const u8) Entry {
    return .{ .id = id, .label = @constCast(label), .active = active, .occupied = occupied, .app_keys = @constCast(keys) };
}

test "workspaces: display mode parsing" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[widget.ws]
        \\display = "name"
        \\[widget.ws2]
        \\display = "none"
        \\[widget.ws3]
        \\display = "bogus"
    );
    defer loaded.deinit();
    const c = &loaded.cfg;
    try t.expectEqual(DisplayMode.name, parseDisplayMode(c, "ws"));
    try t.expectEqual(DisplayMode.none, parseDisplayMode(c, "ws2"));
    try t.expectEqual(DisplayMode.id, parseDisplayMode(c, "ws3"));
    try t.expectEqual(DisplayMode.id, parseDisplayMode(c, "missing"));
    try t.expect(parseShowApps(c, "ws"));
    try t.expectEqual(@as(i32, 4), parseMaxIcons(c, "ws"));
    try t.expectEqual(@as(i32, 5), maxSlotsFromSettings(c, "ws"));
}

test "workspaces: max icons and slots clamp like strtol" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[widget.ws]
        \\max_workspace_icons = "99"
        \\max_workspaces = "99"
        \\[widget.bad]
        \\max_workspace_icons = "xx"
        \\max_workspaces = "xx"
    );
    defer loaded.deinit();
    const c = &loaded.cfg;
    try t.expectEqual(@as(i32, 8), parseMaxIcons(c, "ws"));
    try t.expectEqual(@as(i32, 32), maxSlotsFromSettings(c, "ws"));
    try t.expectEqual(@as(i32, 4), parseMaxIcons(c, "bad"));
    try t.expectEqual(@as(i32, 5), maxSlotsFromSettings(c, "bad"));
}

test "workspaces: cell text follows the mode" {
    const t = std.testing;
    var buf: [16]u8 = undefined;
    var e = testEntry(3, "dev", false, true, &.{});
    try t.expectEqualStrings("3", cellText(&e, .id, &buf));
    try t.expectEqualStrings("dev", cellText(&e, .name, &buf));
    try t.expectEqualStrings("", cellText(&e, .none, &buf));
    e.label = @constCast("");
    try t.expectEqualStrings("3", cellText(&e, .name, &buf));
}

test "workspaces: applyMaxSlots sorts and gap-fills" {
    const t = std.testing;
    const src = [_]Entry{ testEntry(3, "c", false, true, &.{}), testEntry(1, "a", true, true, &.{}) };
    const filled = try applyMaxSlots(t.allocator, &src, 3);
    defer {
        for (filled) |*e| freeEntry(t.allocator, e);
        t.allocator.free(filled);
    }
    try t.expectEqual(@as(usize, 3), filled.len);
    try t.expectEqual(@as(i32, 1), filled[0].id);
    try t.expect(filled[0].active);
    try t.expectEqual(@as(i32, 2), filled[1].id);
    try t.expectEqualStrings("2", filled[1].label);
    try t.expectEqual(@as(i32, 3), filled[2].id);
    // Non-positive disables the fill but still copies.
    const plain = try applyMaxSlots(t.allocator, &src, 0);
    defer {
        for (plain) |*e| freeEntry(t.allocator, e);
        t.allocator.free(plain);
    }
    try t.expectEqual(@as(usize, 2), plain.len);
}

test "workspaces: strip poll throttles and maps regions" {
    const t = std.testing;
    var strip = Strip.init(t.allocator);
    defer strip.deinit();
    var map = desk.AppMap.init(t.allocator);
    defer desk.freeAppMap(t.allocator, &map);
    const regions = [_]desk.Region{
        .{ .id = "1", .name = "", .index = 1, .active = true, .occupied = true },
        .{ .id = "3", .name = "web", .index = 3, .occupied = true },
    };
    try t.expect(try strip.poll(1000, &regions, &map, 0));
    try t.expectEqual(@as(usize, 2), strip.entries.len);
    try t.expectEqualStrings("1", strip.entries[0].label);
    try t.expect(strip.entries[0].active);
    try t.expectEqualStrings("web", strip.entries[1].label);
    // Inside 280 ms with entries present: throttled.
    try t.expect(!try strip.poll(1100, &regions, &map, 0));
    // Past the window: rebuilds (and gap-fills the missing id 2 here).
    try t.expect(try strip.poll(1400, &regions, &map, 4));
    try t.expectEqual(@as(usize, 4), strip.entries.len);
    try t.expectEqualStrings("2", strip.entries[1].label);
    try t.expectEqualStrings("web", strip.entries[2].label);
}

test "workspaces: anim eases out over 200ms" {
    const t = std.testing;
    var a = AnimState.init(t.allocator);
    defer a.deinit();
    const from = [_]CellGeom{ .{ .x = 0, .w = 10 }, .{ .x = 14, .w = 10 } };
    const to = [_]CellGeom{ .{ .x = 0, .w = 20 }, .{ .x = 24, .w = 20 } };
    try a.updateTargets(&from, 1000);
    // First call only latches.
    try t.expect(!a.active);
    try a.updateTargets(&to, 1000);
    try t.expect(a.active);
    try t.expectEqual(@as(f64, 0.0), a.getX(0, 1000));
    try t.expectEqual(@as(f64, 10.0), a.getW(0, 1000));
    const mid_w = a.getW(0, 1100);
    try t.expect(mid_w > 10.0 and mid_w < 20.0);
    // ease-out cubic at t=0.5 is 0.875: 10 + 10*0.875 = 18.75.
    try t.expectApproxEqAbs(@as(f64, 18.75), mid_w, 1e-9);
    try t.expectEqual(@as(f64, 20.0), a.getW(0, 1200));
    try t.expectEqual(@as(f32, 1.0), a.progress(1200));
    // Out-of-range indices fall back to targets, then zero.
    try t.expectEqual(@as(f64, 0.0), a.getX(9, 1100));
}

test "workspaces: layout scales to fit and reports refresh" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator, "");
    defer loaded.deinit();
    const src = [_]Entry{ testEntry(1, "1", true, true, &.{}), testEntry(2, "2", false, false, &.{}) };
    const r1 = try layoutCells(t.allocator, null, &loaded.cfg, "ws", 30.0, 400.0, 30.0, &src);
    defer t.allocator.free(r1.cells);
    try t.expectEqual(@as(usize, 2), r1.cells.len);
    // A null context falls back to the scratch surface
    // `get_measure_cr`), so text measures and the cache refreshes.
    try t.expect(r1.refreshed);
    try t.expect(r1.cells[0].w >= 4.0);
    // Same texts again: the cache hits, no refresh owed.
    const r1b = try layoutCells(t.allocator, null, &loaded.cfg, "ws", 30.0, 400.0, 30.0, &src);
    defer t.allocator.free(r1b.cells);
    try t.expect(!r1b.refreshed);
    // A slot narrower than the natural widths scales cells down.
    const r2 = try layoutCells(t.allocator, null, &loaded.cfg, "ws", 30.0, 60.0, 30.0, &src);
    defer t.allocator.free(r2.cells);
    try t.expect(r2.cells[0].w <= r1.cells[0].w);
    try t.expectEqual(@as(f64, 6.0), r2.gap);
    // An app-keys entry sizes by icon math, not text.
    const apps = [_]Entry{.{ .id = 1, .label = @constCast("1"), .app_keys = @constCast(&[_][]const u8{ "firefox", "code" }) }};
    const r3 = try layoutCells(t.allocator, null, &loaded.cfg, "ws", 30.0, 400.0, 30.0, &apps);
    defer t.allocator.free(r3.cells);
    // 2 icons: 2*18.6 + 1*3 + 2*6 = 52.2 > pill_min 22.
    try t.expectApproxEqAbs(@as(f64, 52.2), r3.cells[0].w, 1e-9);
}

test "workspaces: the cell row floats in the slack instead of hugging the left pad" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator, "");
    defer loaded.deinit();
    const src = [_]Entry{ testEntry(1, "1", true, true, &.{}), testEntry(2, "2", false, false, &.{}) };
    // A slot wider than the two cells need: the row centres itself, so the
    // margin it leaves on the left equals the one it leaves on the right.
    const wide = try layoutCells(t.allocator, null, &loaded.cfg, "ws", 30.0, 400.0, 30.0, &src);
    defer t.allocator.free(wide.cells);
    const first = wide.cells[0];
    const last = wide.cells[wide.cells.len - 1];
    const left_margin = first.x - wide.hpad;
    const right_margin = 400.0 - wide.hpad - (last.x + last.w);
    try t.expect(left_margin > 1.0);
    try t.expectApproxEqAbs(left_margin, right_margin, 1e-9);
    // Slack is shared evenly: the row's own width plus the two margins is
    // exactly the pad-to-pad span.
    try t.expectApproxEqAbs(
        400.0 - 2.0 * wide.hpad,
        (last.x + last.w - first.x) + left_margin + right_margin,
        1e-9,
    );
    // No slack: the slot is exactly the cells' width, and the row sits on the
    // pads with nothing to spare.
    const sum = wide.gap + first.w + wide.cells[1].w;
    const snug = try layoutCells(t.allocator, null, &loaded.cfg, "ws", 30.0, sum + 2.0 * wide.hpad, 30.0, &src);
    defer t.allocator.free(snug.cells);
    try t.expectApproxEqAbs(snug.hpad, snug.cells[0].x, 1e-9);
    // Too narrow for the natural widths: the scale pass shrinks the cells and
    // they still fill the span, so nothing piles up on either side.
    const tight = try layoutCells(t.allocator, null, &loaded.cfg, "ws", 30.0, 60.0, 30.0, &src);
    defer t.allocator.free(tight.cells);
    const tight_last = tight.cells[tight.cells.len - 1];
    try t.expect(tight.cells[0].w < first.w);
    try t.expect(tight.cells[0].x >= tight.hpad - 1e-9);
    try t.expect(tight_last.x + tight_last.w <= 60.0 - tight.hpad + 1e-9);
}

test "workspaces: slot width clamps" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator, "");
    defer loaded.deinit();
    try t.expectEqual(@as(f64, 120.0), dockWorkspacesSlotWidth(null, &loaded.cfg, "ws", 30.0, 200.0, &.{}));
    const src = [_]Entry{testEntry(1, "1", true, true, &.{})};
    const w = dockWorkspacesSlotWidth(null, &loaded.cfg, "ws", 30.0, 200.0, &src);
    try t.expect(w >= 60.0 and w <= @min(200.0 * 22.0, 920.0));
}

test "workspaces: pick and activate" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator, "");
    defer loaded.deinit();
    const src = [_]Entry{ testEntry(1, "1", true, true, &.{}), testEntry(2, "2", false, false, &.{}) };
    try t.expectEqual(@as(i32, 0), try pickIndex(t.allocator, 0.0, 400.0, &loaded.cfg, "ws", 30.0, &src));
    try t.expectEqual(@as(i32, 1), try pickIndex(t.allocator, 399.0, 400.0, &loaded.cfg, "ws", 30.0, &src));
    try t.expectEqual(@as(i32, -1), try pickIndex(t.allocator, 10.0, 1.0, &loaded.cfg, "ws", 30.0, &src));
    try t.expectEqual(@as(i32, -1), try pickIndex(t.allocator, 10.0, 400.0, &loaded.cfg, "ws", 30.0, &.{}));
    var buf: [12]u8 = undefined;
    try t.expectEqualStrings("2", activateTarget(&src[1], &buf).?);
    var ph = Entry{ .id = 0 };
    try t.expect(activateTarget(&ph, &buf) == null);
    var list = [_][]const u8{"ws"};
    var loaded2 = try schema.loadText(t.allocator,
        \\[widget.ws]
        \\type = "workspaces"
    );
    defer loaded2.deinit();
    try t.expect(widgetListContainsWorkspaces(&loaded2.cfg, &list));
    try t.expect(!widgetListContainsWorkspaces(&loaded2.cfg, &.{"media"}));
}

test "workspaces: paint runs headless and drives the anim" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator, "");
    defer loaded.deinit();
    const src = [_]Entry{ testEntry(1, "1", true, true, &.{}), testEntry(2, "2", false, false, &.{}) };
    var anim = AnimState.init(t.allocator);
    defer anim.deinit();
    // Null context: layout runs, nothing paints, no redraw owed.
    const quiet = try paintWorkspacesSlot(t.allocator, null, &loaded.cfg, "ws", 0, 0, 400, 30, 30.0, &src, false, false, null, null, 0);
    try t.expect(!quiet);
    // A target change arms the animation and owes a frame.
    var anim2 = AnimState.init(t.allocator);
    defer anim2.deinit();
    _ = try paintWorkspacesSlot(t.allocator, null, &loaded.cfg, "ws", 0, 0, 400, 30, 30.0, &src, false, false, null, &anim2, 1000);
    const one = [_]Entry{testEntry(1, "1", true, true, &.{})};
    const owed = try paintWorkspacesSlot(t.allocator, null, &loaded.cfg, "ws", 0, 0, 400, 30, 30.0, &one, false, false, null, &anim2, 1100);
    try t.expect(owed);
}
