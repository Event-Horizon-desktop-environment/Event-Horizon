//! Launchpad grid model: the app catalog filtered by the search query.
//!
//! Flat list of matching catalog entries (folders arrive later), scored
//! and sorted like the launcher ranks them. Icons resolve lazily through
//! the theme and cache by name; the cache is dropped with the catalog.
//! Strings belong to the catalog arena — items only carry indices.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const logz = @import("../../logz.zig");
const cat = @import("../../services/app_catalog.zig");
const icon_lookup = @import("../common/icon_lookup.zig");
const icon_raster = @import("../common/icon_raster.zig");
const icon_cache = @import("../common/icon_cache.zig");
const icon_disk = @import("../common/icon_disk.zig");
const folders_mod = @import("folders.zig");
const app_launch = @import("../../services/app_launch.zig");
const tiles = @import("tiles.zig");

const icon_cache_cap: usize = 256;

pub const IconPx = struct {
    data: []u8 = &.{},
    w: i32 = 0,
    h: i32 = 0,
    /// Cairo surface over `data`, built once on first use so paints never
    /// pay create/destroy per cell per frame.
    surf: ?*cairo.cairo_surface_t = null,
};

const ScoredHit = struct { idx: usize, sc: u32 };

pub const Apps = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    catalog: cat.Catalog = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) },
    loaded: bool = false,
    query: std.ArrayList(u8) = .empty,
    /// Catalog indices that match, best first.
    hits: std.ArrayList(usize) = .empty,
    hovered: i32 = -1,
    scroll: f64 = 0,
    /// Scratch views for folder ops. Borrows catalog strings; only valid
    /// for the call that filled it (single-threaded loop, never held).
    view_buf: [1024]folders_mod.State.App = undefined,
    /// Folder state: auto buckets, manual folders, overrides, order.
    folders: folders_mod.State = undefined,
    folders_init: bool = false,
    /// Open folder index into `folders.folders`, -1 when closed.
    open_folder: i32 = -1,
    modal_scroll: f64 = 0,
    modal_hovered: i32 = -1,
    rename: folders_mod.State.Rename = .{},
    /// Right-click pin menu. Labels owned; empty when closed.
    ctx_open: bool = false,
    ctx_rect: [4]f64 = .{ 0, 0, 0, 0 },
    ctx_labels: std.ArrayList([]const u8) = .empty,
    ctx_actions: std.ArrayList(u8) = .empty,
    ctx_app: []const u8 = "",
    ctx_hover: i32 = -1,
    /// Diagnostic counters for the paint that just ran: cold resolves and
    /// what they cost, and how many came from disk. Reset by the host
    /// before each grid paint.
    dbg_resolves: u32 = 0,
    dbg_resolve_ms: u64 = 0,
    dbg_disk_hits: u32 = 0,
    /// A paint skipped at least one icon for budget. The host reports it
    /// so the dock keeps the tick alive until the grid is complete.
    icon_pending: bool = false,
    theme: []const u8 = "",
    dirs: [][]const u8 = &.{},
    /// Application directories for class-to-icon mapping. Borrowed for the
    /// process; the host binary sets it once from its own dirs.
    app_dirs: [][]const u8 = &.{},
    /// Window class -> icon name, owned. `desktopIcon` reads desktop files,
    /// so the mapping is computed once per class, not once per paint.
    class_icons: std.StringHashMap([]const u8) = undefined,
    class_icons_init: bool = false,
    disk: icon_disk.Disk = undefined,
    disk_init: bool = false,
    icons: std.StringHashMap(IconPx) = undefined,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Self {
        return .{
            .gpa = gpa,
            .io = io,
            .icons = std.StringHashMap(IconPx).init(gpa),
            .class_icons = std.StringHashMap([]const u8).init(gpa),
            .class_icons_init = true,
            .disk = icon_disk.Disk.init(gpa, io),
            .disk_init = true,
            .folders = folders_mod.State.init(gpa),
            .folders_init = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.closeCtx();
        // Labels borrow string literals; only the list buffers are owned.
        self.ctx_labels.deinit(self.gpa);
        self.ctx_actions.deinit(self.gpa);
        if (self.folders_init) self.folders.deinit();
        self.clearIcons();
        self.icons.deinit();
        if (self.class_icons_init) {
            var it = self.class_icons.iterator();
            while (it.next()) |e| {
                self.gpa.free(e.value_ptr.*);
                self.gpa.free(e.key_ptr.*);
            }
            self.class_icons.deinit();
        }
        if (self.disk_init) self.disk.deinit();
        self.query.deinit(self.gpa);
        self.hits.deinit(self.gpa);
        if (self.loaded) self.catalog.deinit();
        if (self.dirs.len > 0) icon_lookup.freeDirs(self.gpa, self.dirs);
    }

    fn clearIcons(self: *Self) void {
        var it = self.icons.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.surf) |sf| cairo.cairo_surface_destroy(sf);
            self.gpa.free(e.value_ptr.data);
            self.gpa.free(e.key_ptr.*);
        }
        self.icons.clearRetainingCapacity();
    }

    /// (Re)load the catalog and theme path. Slow (hundreds of desktop
    /// files), so the host calls it on first open, not per frame.
    pub fn ensureLoaded(self: *Self, theme: []const u8) void {
        if (self.loaded) return;
        self.folders.loadFile(self.io);
        self.catalog = cat.load(self.gpa, self.io) catch {
            self.catalog = .{ .arena = std.heap.ArenaAllocator.init(self.gpa) };
            self.loaded = true;
            self.refresh();
            return;
        };
        self.loaded = true;
        self.theme = theme;
        self.dirs = icon_lookup.dataDirs(
            self.gpa,
            getenv("XDG_DATA_HOME"),
            getenv("HOME"),
            getenv("XDG_DATA_DIRS"),
        ) catch &.{};
        self.refresh();
    }

    fn nowMs() u64 {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 + @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
    }

    fn getenv(key: [:0]const u8) ?[]const u8 {
        const p = std.c.getenv(key) orelse return null;
        return std.mem.span(p);
    }

    fn foldByte(c: u8) u8 {
        return std.ascii.toLower(c);
    }

    pub fn refresh(self: *Self) void {
        self.hits.clearRetainingCapacity();
        if (!self.loaded) return;
        var pat: [256]u8 = undefined;
        const raw = std.mem.trim(u8, self.query.items, " \t");
        const n = @min(raw.len, pat.len);
        for (raw[0..n], 0..) |c, i| pat[i] = foldByte(c);
        const pattern = pat[0..n];
        // Scores are computed once per refresh; the sort below only reads
        // them, instead of re-scoring every comparison like a naive sort.
        var scored: std.ArrayList(ScoredHit) = .empty;
        defer scored.deinit(self.gpa);
        for (self.catalog.entries, 0..) |*e, i| {
            const sc = cat.score(pattern, e);
            if (sc == 0) continue;
            scored.append(self.gpa, .{ .idx = i, .sc = sc }) catch continue;
        }
        // Best score first; the catalog is name-ordered and the sort is
        // stable, so ties stay alphabetical the way the launcher leaves them.
        std.mem.sort(ScoredHit, scored.items, {}, struct {
            fn lt(_: void, a: ScoredHit, b: ScoredHit) bool {
                return a.sc > b.sc;
            }
        }.lt);
        for (scored.items) |r| self.hits.append(self.gpa, r.idx) catch continue;
        if (self.hovered >= @as(i32, @intCast(self.hits.items.len))) self.hovered = -1;
        // Folders only browse the full catalog: any query shows flat hits
        // and closes an open folder.
        if (std.mem.trim(u8, self.query.items, " \t").len > 0) {
            self.open_folder = -1;
            self.modal_scroll = 0;
        }
        self.rebuildGrid();
        // Scroll clamps against the layout's page count, which the host
        // owns — it re-clamps after every layout.
    }

    /// App views for the folder build, in hit order.
    fn appViews(self: *Self, buf: []folders_mod.State.App) []folders_mod.State.App {
        var n: usize = 0;
        for (self.hits.items) |idx| {
            if (n >= buf.len or idx >= self.catalog.entries.len) break;
            const e = self.catalog.entries[idx];
            buf[n] = .{ .path = e.path, .categories = e.categories };
            n += 1;
        }
        return buf[0..n];
    }

    fn rebuildGrid(self: *Self) void {
        var buf: [1024]folders_mod.State.App = undefined;
        const views = self.appViews(&buf);
        // Folders only browse the full catalog: any query shows flat hits.
        const empty = std.mem.trim(u8, self.query.items, " \t").len == 0;
        self.folders.rebuild(views, empty) catch return;
        if (self.open_folder >= @as(i32, @intCast(self.folders.folders.len))) {
            self.open_folder = -1;
            self.modal_scroll = 0;
        }
        if (self.modal_hovered >= self.modalCount()) self.modal_hovered = -1;
    }

    /// Persist folder edits. Called after every mutation that
    /// funnels through `after_folder_edit`.
    fn saveFolders(self: *Self) void {
        self.folders.saveFile(self.io);
        self.rebuildGrid();
    }

    /// Grid being interacted with: folder modal when open, else main.
    pub fn modalOpen(self: *const Self) bool {
        return self.open_folder >= 0 and self.open_folder < self.folders.folders.len;
    }

    pub fn gridCount(self: *const Self) usize {
        return self.folders.items.len;
    }

    pub fn modalCount(self: *const Self) usize {
        if (!self.modalOpen()) return 0;
        return self.folders.folders[@intCast(self.open_folder)].members.len;
    }

    /// Catalog index for a main-grid item, or null for folders/out of range.
    pub fn gridAppIndex(self: *Self, item_idx: usize) ?usize {
        if (item_idx >= self.folders.items.len) return null;
        const it = self.folders.items[item_idx];
        if (it.folder) return null;
        if (it.index >= self.hits.items.len) return null;
        const cat_idx = self.hits.items[it.index];
        if (cat_idx >= self.catalog.entries.len) return null;
        return cat_idx;
    }

    /// Catalog index for a modal cell.
    pub fn modalAppIndex(self: *Self, cell: usize) ?usize {
        if (!self.modalOpen()) return null;
        const m = self.folders.folders[@intCast(self.open_folder)].members;
        if (cell >= m.len) return null;
        for (self.hits.items) |cat_idx| {
            if (cat_idx < self.catalog.entries.len and
                std.mem.eql(u8, self.catalog.entries[cat_idx].path, m[cell])) return cat_idx;
        }
        // Member missing from this catalog (uninstalled since): skip.
        return null;
    }

    /// Desktop path for a main-grid item, "" for folders.
    pub fn gridItemPath(self: *Self, item_idx: usize) []const u8 {
        if (item_idx >= self.folders.items.len) return "";
        const it = self.folders.items[item_idx];
        if (it.folder) return "";
        if (it.index >= self.hits.items.len) return "";
        const cat_idx = self.hits.items[it.index];
        if (cat_idx >= self.catalog.entries.len) return "";
        return self.catalog.entries[cat_idx].path;
    }

    pub fn modalItemPath(self: *Self, cell: usize) []const u8 {
        if (!self.modalOpen()) return "";
        const m = self.folders.folders[@intCast(self.open_folder)].members;
        if (cell >= m.len) return "";
        return m[cell];
    }

    pub fn openFolder(self: *Self, folder_idx: usize) void {
        if (folder_idx >= self.folders.folders.len) return;
        self.open_folder = @intCast(folder_idx);
        self.modal_scroll = 0;
        self.modal_hovered = -1;
    }

    pub fn closeFolder(self: *Self) void {
        self.open_folder = -1;
        self.modal_scroll = 0;
        self.modal_hovered = -1;
    }

    pub fn folderTitle(self: *Self, buf: []u8) []const u8 {
        if (!self.modalOpen()) return "";
        const f = self.folders.folders[@intCast(self.open_folder)];
        if (self.rename.active) {
            const t = self.rename.text();
            const n = @min(t.len, buf.len);
            @memcpy(buf[0..n], t[0..n]);
            return buf[0..n];
        }
        const n = @min(f.name.len, buf.len);
        @memcpy(buf[0..n], f.name[0..n]);
        return buf[0..n];
    }

    /// Right-click pin menu over an app cell. Labels read live pin state;
    /// empty path (a folder) gets no menu.
    pub fn openCtx(self: *Self, x: f64, y: f64, w: f64, h: f64, ui: f64, app_path: []const u8, dock_pinned: bool, taskbar_pinned: bool) void {
        self.closeCtx();
        if (app_path.len == 0 or w <= 0 or h <= 0) return;
        const row_h = 34.0 * ui;
        const menu_w = 220.0 * ui;
        const menu_h = row_h * 2.0 + 12.0 * ui;
        self.ctx_rect = .{
            @min(@max(x, 8.0), @max(8.0, w - menu_w - 8.0)),
            @min(@max(y, 8.0), @max(8.0, h - menu_h - 8.0)),
            menu_w,
            menu_h,
        };
        self.ctx_app = app_path;
        self.ctx_labels.append(self.gpa, if (dock_pinned) "Unpin from dock" else "Pin to dock") catch return;
        self.ctx_actions.append(self.gpa, 0) catch return;
        self.ctx_labels.append(self.gpa, if (taskbar_pinned) "Unpin from taskbar" else "Pin to taskbar") catch return;
        self.ctx_actions.append(self.gpa, 1) catch return;
        self.ctx_open = true;
    }

    pub fn closeCtx(self: *Self) void {
        if (!self.ctx_open) return;
        self.ctx_open = false;
        self.ctx_hover = -1;
        self.ctx_labels.clearRetainingCapacity();
        self.ctx_actions.clearRetainingCapacity();
        self.ctx_app = "";
    }

    /// Row under the pointer, or -1. Geometry matches the paint exactly.
    pub fn ctxHit(self: *Self, mx: f64, my: f64, ui: f64) i32 {
        if (!self.ctx_open) return -1;
        const r = self.ctx_rect;
        if (mx < r[0] or mx > r[0] + r[2] or my < r[1] or my > r[1] + r[3]) return -1;
        if (self.ctx_labels.items.len == 0) return -1;
        const row_h = (r[3] - 12.0 * ui) / @as(f64, @floatFromInt(self.ctx_labels.items.len));
        if (row_h <= 0.0) return -1;
        const row: i32 = @intFromFloat((my - r[1] - 6.0 * ui) / row_h);
        if (row < 0 or row >= self.ctx_labels.items.len) return -1;
        return row;
    }

    /// Which pin the row toggles: 0 dock, 1 taskbar. -1 dismisses.
    pub fn ctxAction(self: *Self, row: i32) i32 {
        if (!self.ctx_open or row < 0 or row >= self.ctx_actions.items.len) return -1;
        return self.ctx_actions.items[@intCast(row)];
    }

    /// Reorder main-grid cell before/after another (edge drops only, never
    /// while searching or with a folder open).
    pub fn reorderCell(self: *Self, src_idx: usize, dst_idx: usize, after: bool) void {
        if (self.modalOpen()) return;
        if (std.mem.trim(u8, self.query.items, " \t").len > 0) return;
        self.folders.reorder(src_idx, dst_idx, after);
        self.saveFolders();
        self.hovered = -1;
    }

    /// Remove a modal cell's app from the open folder (drag-out release).
    pub fn removeModalCell(self: *Self, cell: usize) void {
        if (!self.modalOpen()) return;
        const path = self.modalItemPath(cell);
        if (path.len == 0) return;
        // Copy the id: the edit below rebuilds the folder list.
        var idbuf: [64]u8 = undefined;
        const fid = self.folders.folders[@intCast(self.open_folder)].id;
        const n = @min(fid.len, idbuf.len);
        @memcpy(idbuf[0..n], fid[0..n]);
        const fid_copy = idbuf[0..n];
        self.folders.removeFrom(path, self.open_folder);
        self.saveFolders();
        // Follow the edited folder across the rebuild by id.
        self.rebuildGrid();
        self.open_folder = -1;
        for (self.folders.folders, 0..) |f, i| {
            if (std.mem.eql(u8, f.id, fid_copy)) {
                self.open_folder = @intCast(i);
                break;
            }
        }
        self.modal_scroll = 0;
        self.modal_hovered = -1;
    }

    /// Commit an inline rename to the open folder.
    pub fn commitRename(self: *Self) void {
        if (!self.rename.active or !self.modalOpen()) {
            self.rename.cancel();
            return;
        }
        const fid = self.folders.folders[@intCast(self.open_folder)].id;
        self.folders.renameFolder(fid, self.rename.text());
        self.rename.cancel();
        self.saveFolders();
    }

    /// Activate a grid cell: folders open, apps report their catalog index
    /// for the host to launch. Modal cells resolve through the open folder.
    /// Returns null for folders (opened, not launched).
    pub fn activateCell(self: *Self, item_idx: usize, modal: bool) ?usize {
        if (modal) {
            if (!self.modalOpen()) return null;
            return self.modalAppIndex(item_idx);
        }
        if (item_idx >= self.folders.items.len) return null;
        const it = self.folders.items[item_idx];
        if (it.folder) {
            self.openFolder(it.index);
            return null;
        }
        return self.gridAppIndex(item_idx);
    }

    /// Drop a main-grid cell onto another. App onto app makes a manual
    /// folder, app onto folder moves in. Folders themselves never drag.
    pub fn dropCell(self: *Self, src_idx: usize, dst_idx: usize) void {
        // Center drops only flow with no query and no open folder; the
        // host already enforces the modal/edge split before calling.
        if (self.modalOpen()) return;
        if (std.mem.trim(u8, self.query.items, " \t").len > 0) return;
        if (src_idx >= self.folders.items.len or dst_idx >= self.folders.items.len) return;
        if (self.folders.items[src_idx].folder) return;
        const src = self.gridItemPath(src_idx);
        if (src.len == 0) return;
        const dst = self.folders.items[dst_idx];
        if (dst.folder) {
            if (dst.index >= self.folders.folders.len) return;
            self.folders.moveInto(self.currentViews(), src, self.folders.folders[dst.index].id);
        } else {
            const dst_path = self.gridItemPath(dst_idx);
            if (dst_path.len == 0) return;
            _ = self.folders.createManual(self.currentViews(), src, dst_path);
        }
        self.saveFolders();
    }

    /// Scratch views for ops outside refresh; borrows catalog strings,
    /// valid only for the call that filled it.
    fn currentViews(self: *Self) []folders_mod.State.App {
        return self.appViews(&self.view_buf);
    }

    pub fn typeText(self: *Self, text: []const u8) void {
        if (text.len == 0) return;
        self.query.appendSlice(self.gpa, text) catch return;
        self.hovered = -1;
        self.scroll = 0;
        self.refresh();
    }

    pub fn backspace(self: *Self) void {
        if (self.query.items.len == 0) return;
        var end = self.query.items.len - 1;
        while (end > 0 and (self.query.items[end] & 0xC0) == 0x80) end -= 1;
        self.query.shrinkRetainingCapacity(end);
        self.hovered = -1;
        self.scroll = 0;
        self.refresh();
    }

    pub fn clearQuery(self: *Self) void {
        if (self.query.items.len == 0) return;
        self.query.clearRetainingCapacity();
        self.hovered = -1;
        self.scroll = 0;
        self.refresh();
    }

    /// Catalog entry by desktop path, for folder member resolution.
    pub fn entryByPath(self: *Self, path: []const u8) ?*const cat.Entry {
        for (self.catalog.entries) |*e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }

    /// Themed icon name for a member path, "" when uninstalled.
    pub fn memberIcon(self: *Self, path: []const u8) []const u8 {
        if (self.entryByPath(path)) |e| return e.icon;
        return "";
    }

    pub fn entry(self: *const Self, hit: usize) ?*const cat.Entry {
        if (hit >= self.hits.items.len) return null;
        const idx = self.hits.items[hit];
        if (idx >= self.catalog.entries.len) return null;
        return &self.catalog.entries[idx];
    }

    /// Catalog entry by catalog index (folder/modal launches resolve to
    /// these, not hit positions).
    pub fn catalogEntry(self: *const Self, cat_idx: usize) ?*const cat.Entry {
        if (cat_idx >= self.catalog.entries.len) return null;
        return &self.catalog.entries[cat_idx];
    }

    /// Cache-only surface: what paints use. Never resolves, never
    /// decodes — a miss paints the letter tile and raises `icon_pending`
    /// so the tick prefetches it. This is what keeps keystrokes fast.
    pub fn surfCached(self: *Self, name: []const u8) ?*cairo.cairo_surface_t {
        if (name.len == 0) return null;
        const e = self.icons.getPtr(name) orelse {
            self.icon_pending = true;
            return null;
        };
        if (e.data.len == 0) return null;
        if (e.surf) |sf| return sf;
        // Pixels cached but no surface yet: surface creation is
        // microseconds, safe on the paint path.
        const sf = cairo.cairo_image_surface_create_for_data(
            e.data.ptr,
            cairo.CAIRO_FORMAT_ARGB32,
            e.w,
            e.h,
            e.w * 4,
        );
        if (cairo.cairo_surface_status(sf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(sf);
            return null;
        }
        e.surf = sf;
        return sf;
    }

    /// Lazily resolved + cached icon pixels for an icon name. Borrowed
    /// until the catalog reloads; empty names and misses answer null. Only
    /// the tick prefetcher calls this; paints go through `surfCached`.
    pub fn iconFor(self: *Self, name: []const u8) ?tiles.IconPx {
        if (name.len == 0 or self.dirs.len == 0) return null;
        if (self.icons.get(name)) |px| {
            if (px.data.len == 0) return null;
            return .{ .data = px.data, .w = px.w, .h = px.h };
        }
        const t0 = nowMs();
        defer {
            self.dbg_resolves += 1;
            self.dbg_resolve_ms += nowMs() - t0;
        }
        if (self.icons.count() >= icon_cache_cap) self.clearIcons();
        // The shared cache answers this from its theme-directory index — an
        // in-memory hash hit — instead of `icon_lookup.lookupAny`, which probed
        // the filesystem with thousands of `access()` calls per miss. The path
        // is borrowed from the cache and outlives this call; the overview still
        // keeps its own disk + pixel caches below, so a fresh process opens
        // with art already on hand.
        // The shared cache's path is borrowed and outlives this call; the
        // fallback probe's path is freed with `Found`, so it must be copied
        // out before the probe is released.
        var owned_fpath: ?[]u8 = null;
        defer if (owned_fpath) |p| self.gpa.free(p);
        const fpath: []const u8 = blk: {
            if (icon_cache.shared()) |ic| {
                break :blk ic.pathFor(.app, name, 96) orelse {
                    // The cache is authoritative and it missed: log once per
                    // name per process (the empty entry below makes a repeat
                    // paint O(1), so a repeated line would be a bug).
                    logz.log("overview: no icon for '{s}'", .{name});
                    self.icons.put(self.gpa.dupe(u8, name) catch return null, .{}) catch {};
                    return null;
                };
            }
            // No shared cache installed (a test, or a binary that skipped
            // init): fall back to the old probe so icons still resolve.
            const f = icon_lookup.lookupAny(self.gpa, self.io, self.dirs, self.theme, name, 96) orelse {
                logz.log("overview: no icon for '{s}'", .{name});
                self.icons.put(self.gpa.dupe(u8, name) catch return null, .{}) catch {};
                return null;
            };
            defer icon_lookup.freeFound(self.gpa, f);
            owned_fpath = self.gpa.dupe(u8, f.path) catch return null;
            break :blk owned_fpath.?;
        };
        const is_svg = std.mem.endsWith(u8, fpath, ".svg");
        // Disk first: a previous process already paid the raster here.
        if (self.disk_init) {
            var hex: [16]u8 = undefined;
            if (self.disk.key(self.theme, name, fpath, 96, &hex)) |dk| {
                if (self.disk.load(dk)) |saved| {
                    self.dbg_disk_hits += 1;
                    errdefer self.gpa.free(saved.pixels);
                    const key = self.gpa.dupe(u8, name) catch {
                        self.gpa.free(saved.pixels);
                        return null;
                    };
                    errdefer self.gpa.free(key);
                    self.icons.put(key, .{ .data = saved.pixels, .w = saved.w, .h = saved.h }) catch {
                        self.gpa.free(key);
                        self.gpa.free(saved.pixels);
                        return null;
                    };
                    return .{ .data = saved.pixels, .w = saved.w, .h = saved.h };
                }
            }
        }
        const px = if (is_svg)
            icon_raster.loadSvg(self.gpa, fpath, 96)
        else
            icon_raster.loadPng(self.gpa, fpath);
        const p = px orelse {
            self.icons.put(self.gpa.dupe(u8, name) catch return null, .{}) catch {};
            return null;
        };
        errdefer self.gpa.free(p.data);
        const key = self.gpa.dupe(u8, name) catch {
            self.gpa.free(p.data);
            return null;
        };
        errdefer self.gpa.free(key);
        self.icons.put(key, .{ .data = p.data, .w = p.w, .h = p.h }) catch {
            self.gpa.free(key);
            self.gpa.free(p.data);
            return null;
        };
        if (self.disk_init) {
            var hex: [16]u8 = undefined;
            if (self.disk.key(self.theme, name, fpath, 96, &hex)) |dk| {
                self.disk.save(dk, p.data, p.w, p.h);
            }
        }
        return .{ .data = p.data, .w = p.w, .h = p.h };
    }

    /// Window class -> themed icon name, cached. Falls back to the
    /// class itself, which is the icon name as often as not.
    pub fn iconNameForClass(self: *Self, class: []const u8) []const u8 {
        if (class.len == 0) return "";
        if (self.class_icons.get(class)) |n| return n;
        var name: []const u8 = class;
        var owned: []u8 = &.{};
        if (self.app_dirs.len > 0) {
            if (app_launch.desktopIcon(self.gpa, self.io, self.app_dirs, class)) |icon| {
                owned = icon;
                name = icon;
            }
        }
        const key = self.gpa.dupe(u8, class) catch {
            if (owned.len > 0) self.gpa.free(owned);
            return class;
        };
        errdefer self.gpa.free(key);
        const val = self.gpa.dupe(u8, name) catch {
            self.gpa.free(key);
            if (owned.len > 0) self.gpa.free(owned);
            return class;
        };
        errdefer self.gpa.free(val);
        self.class_icons.put(key, val) catch {
            self.gpa.free(key);
            self.gpa.free(val);
            if (owned.len > 0) self.gpa.free(owned);
            return class;
        };
        if (owned.len > 0) self.gpa.free(owned);
        return val;
    }

    /// Surface for a window class: mapping plus pixels, paint-safe.
    pub fn surfForClass(self: *Self, class: []const u8) ?*cairo.cairo_surface_t {
        return self.surfCached(self.iconNameForClass(class));
    }

    /// Warm one name fully: pixels plus surface. The tick prefetcher's
    /// unit of work.
    fn warmOne(self: *Self, name: []const u8) void {
        if (name.len == 0) return;
        if (self.icons.get(name) != null) {
            _ = self.surfCached(name);
            return;
        }
        _ = self.iconFor(name);
        _ = self.surfCached(name);
    }

    /// Resolve uncached hit icons until `budget_ms` runs out. True means
    /// uncached names remain — the host keeps the tick alive and repaints
    /// what landed. Hits order is relevance order, so the visible page
    /// warms first.
    pub fn prefetch(self: *Self, budget_ms: u64, extra: []const []const u8) bool {
        if (!self.loaded) return false;
        const t0 = nowMs();
        for (self.hits.items) |idx| {
            if (nowMs() - t0 >= budget_ms) return true;
            if (idx >= self.catalog.entries.len) continue;
            const e = self.catalog.entries[idx];
            if (self.icons.get(e.icon) != null) continue;
            self.warmOne(e.icon);
        }
        // Window classes on the cards resolve to icon names first; the
        // grid above already warmed most of them.
        for (extra) |class| {
            if (nowMs() - t0 >= budget_ms) return true;
            const name = self.iconNameForClass(class);
            if (name.len == 0 or self.icons.get(name) != null) continue;
            self.warmOne(name);
        }
        self.icon_pending = false;
        return false;
    }
};

test "overview-apps: empty catalog answers without crashing" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    var a = Apps.init(t.allocator, threaded.io());
    defer a.deinit();
    a.refresh();
    try t.expectEqual(@as(usize, 0), a.hits.items.len);
    try t.expect(a.entry(0) == null);
    try t.expect(a.iconFor("") == null);
    a.typeText("x");
    a.backspace();
    a.clearQuery();
    try t.expectEqual(@as(usize, 0), a.query.items.len);
    try t.expect(a.surfCached("nope") == null);
    try t.expect(!a.prefetch(25, &.{}));
}
