const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const scan = @import("wallpaper_scan.zig");
const thumbs = @import("wallpaper_thumbs.zig");

// The Wallpaper tab.
//
// This tab is a *page*, not a card list: `ui_content.Content` has no rows for
// it and instead delegates here (see `Content.wall`). The reason is the tab's
// own shape — a hero preview with a floating toolbar overlaid inside it, a
// gallery grid with paging, two sub-tabs and a dropdown that hangs off the
// toolbar — none of which is a row of controls in a card. So the page owns
// its metrics, paints itself in *layout* space (inside the content clip and
// the scroll translate, exactly like a card list would), and reports hits as
// `Action`s the window applies to `Settings` and persists.
//
// Split of ownership:
//   page  — sub-tab, view-options panel, mode dropdown, gallery ordering and
//           paging, the thumbnail service + surface cache, the folder-picker
//           modal flag. All session state, nothing persisted.
//   window — `Settings` values, saving, and the blocking folder dialog.
//
// Every constant below sits beside its use.

/// Sidebar tab id.
pub const tab_id: i32 = 6;

const k_content_top: i32 = common.content_top; // 16
const k_wallpaper_toggle_band_h: i32 = 80;
const k_spacing_xl: i32 = common.spacing_xl; // 24
const k_card_pad: i32 = common.card_pad; // 16
const k_hero_h: i32 = 300;
const k_hero_radius: f64 = 20.0;
const k_tool_bar_h: i32 = 56;
const k_tool_btn_s: i32 = 40;
const k_tool_combo_w: i32 = 128;
const k_tool_combo_h: i32 = 34;
const k_picker_h: i32 = 48;
const k_gallery_bar_h: i32 = 32;
const k_view_panel_h: i32 = 148;
const k_thumb_gap: i32 = 6;
const k_thumb_label_h: i32 = 0;
const k_dd_row_h: i32 = common.settings_dd_row_h; // 26
/// Page-nav buttons under the grid (`WallpaperTabLayout::kNavW/kNavH`).
const nav_w: i32 = 80;
const nav_h: i32 = 32;
/// Surfaces kept alive for the hero + visible tiles (one per path
/// with no bound; 64 covers a full page plus the hero with room to spare).
const thumb_cache_cap: usize = 64;
/// Longest side the unified cache renders at — precaching every
/// gallery path through the service at 512px and paints the hero from the
/// same service, so one size serves both.
const cache_px: u32 = 512;
/// Stat debounce for the gallery sync.
const stat_debounce_ns: u64 = 500 * std.time.ns_per_ms;

/// `kWallpaperModeLabels` order, which is what `wallpaperMode`
/// indexes into (Fill/Fit/Stretch/Center/Tile, *not* the four-plus-span list
/// the placeholder card row used).
pub const mode_labels = [_][]const u8{ "Fill", "Fit", "Stretch", "Center", "Tile" };
/// `wallpaper_folder_picker_row_label`.
pub const picker_labels = [_][]const u8{ "Native dialog", "KDE — kdialog", "Qt — qarma", "GTK — zenity" };
const sort_labels = [_][]const u8{ "Name", "Oldest", "Newest" };
const sort_pill_w = [_]i32{ 72, 88, 88 };

/// Everything the page needs from `Settings` for one frame. Synced by the
/// window right before relayout so paint, hit-test and the scroll height all
/// read the same values.
pub const Snapshot = struct {
    image: []const u8 = "",
    folder: []const u8 = "",
    mode: i32 = 0,
    enabled: bool = false,
};

/// One wallpaper-tab press, translated into what the window must do. The
/// page has already moved its own session state by the time this is returned.
pub const Action = union(enum) {
    /// Session state moved; repaint is all that is needed.
    repaint,
    toggle_enabled,
    /// Step the selection through the gallery (-1 / +1).
    cycle: i32,
    set_mode: i32,
    /// Toolbar folder button: run the (blocking) folder dialog now.
    pick_folder,
    /// A gallery tile was picked by absolute index into the gallery.
    select_image: usize,
    /// Delete button: clear the image and disable the wallpaper.
    clear_image,
};

/// Content-column geometry, passed in rather than read from `Content` so this
/// module stays free of a cycle back into `ui_content`.
pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

pub const Metrics = struct {
    sub_tab_y: i32,
    hero_x: f64,
    hero_y: i32,
    hero_w: i32,
    hero_h: i32 = k_hero_h,
    tool_bar_x: i32,
    tool_bar_y: i32,
    tool_bar_w: i32,
    tool_bar_h: i32 = k_tool_bar_h,
    tool_icon_y: i32,
    tool_prev_x: i32,
    tool_next_x: i32,
    tool_delete_x: i32,
    tool_folder_x: i32,
    tool_tune_x: i32,
    tool_combo_x: i32,
    tool_combo_y: i32,
    tool_combo_w: i32 = k_tool_combo_w,
    tool_combo_h: i32 = k_tool_combo_h,
    tool_text_x: i32,
    tool_text_w: i32,
    picker_y: i32,
    gallery_toolbar_y: i32,
    sort_pills_y: i32,
    sort_pills_x: i32,
    gallery_tune_x: i32,
    view_panel_y: i32,
    view_panel_h: i32,
    gallery_grid_top: i32,
};

/// `wallpaper_vertical_metrics`.
pub fn metrics(content_x: f64, content_w: f64, view_open: bool) Metrics {
    var m: Metrics = undefined;
    m.sub_tab_y = k_content_top + 96;
    m.hero_x = content_x + @as(f64, @floatFromInt(k_card_pad));
    m.hero_y = m.sub_tab_y + 52;
    m.hero_w = @intFromFloat(content_w - 2.0 * @as(f64, @floatFromInt(k_card_pad)));
    m.hero_h = k_hero_h;

    m.tool_bar_h = k_tool_bar_h;
    m.tool_bar_w = m.hero_w - 24;
    m.tool_bar_x = @as(i32, @intFromFloat(m.hero_x)) + 12;
    m.tool_bar_y = m.hero_y + k_hero_h - 12 - k_tool_bar_h;
    m.tool_icon_y = m.tool_bar_y + @divTrunc(k_tool_bar_h - k_tool_btn_s, 2);
    m.tool_prev_x = m.tool_bar_x + 8;
    m.tool_next_x = m.tool_prev_x + k_tool_btn_s + 8;
    m.tool_delete_x = m.tool_bar_x + m.tool_bar_w - 8 - k_tool_btn_s;
    m.tool_folder_x = m.tool_delete_x - 8 - k_tool_btn_s;
    m.tool_tune_x = m.tool_folder_x - 8 - k_tool_btn_s;
    m.tool_combo_w = k_tool_combo_w;
    m.tool_combo_h = k_tool_combo_h;
    m.tool_combo_x = m.tool_tune_x - 8 - k_tool_combo_w;
    m.tool_combo_y = m.tool_bar_y + @divTrunc(k_tool_bar_h - k_tool_combo_h, 2);
    m.tool_text_x = m.tool_next_x + k_tool_btn_s + 12;
    m.tool_text_w = @max(40, m.tool_combo_x - 8 - m.tool_text_x);

    m.picker_y = m.hero_y + k_hero_h + 12;
    m.gallery_toolbar_y = m.picker_y + k_picker_h + 16;
    m.sort_pills_y = m.gallery_toolbar_y + @divTrunc(k_gallery_bar_h - 28, 2);
    // Right-aligned: Name(72) Oldest(88) Newest(88) + tune(40), 8px gaps.
    m.sort_pills_x = @as(i32, @intFromFloat(m.hero_x)) + m.hero_w - (72 + 8 + 88 + 8 + 88 + 8 + 40);
    m.gallery_tune_x = m.sort_pills_x + 72 + 8 + 88 + 8 + 88 + 8;

    m.view_panel_y = m.gallery_toolbar_y + k_gallery_bar_h + 12;
    m.view_panel_h = if (view_open) k_view_panel_h else 0;
    m.gallery_grid_top = m.view_panel_y + (if (view_open) m.view_panel_h + 12 else 12);
    return m;
}

/// One view-panel stepper cell — `wallpaper_view_cell_geom`, shared by the
/// paint and the hit test so they cannot disagree.
pub const ViewCell = struct { x: i32, minus_x: i32, plus_x: i32, btn_y: i32 };

pub fn viewCell(m: *const Metrics, idx: i32) ViewCell {
    const cell_w = @divTrunc(m.hero_w - 24 - 3 * 12, 4);
    const cx = @as(i32, @intFromFloat(m.hero_x)) + 12 + idx * (cell_w + 12);
    return .{ .x = cx, .minus_x = cx, .plus_x = cx + cell_w - 44, .btn_y = m.view_panel_y + 96 };
}

pub const Grid = struct {
    gap: i32 = k_thumb_gap,
    cols: i32,
    rows: i32,
    thumb: i32,
    thumb_h: i32,
    per_page: usize,
    top: i32,
    nav_y: i32,
    show_nav: bool,
    prev_x: i32,
    next_x: i32,
};

const CacheEntry = struct {
    surf: ?*cairo.cairo_surface_t = null,
    w: i32 = 0,
    h: i32 = 0,
    /// Owned pixel buffer the surface wraps; freed with the entry.
    pixels: []u32 = &.{},
    /// False for a file that would not decode — a tombstone, so the paint
    /// loop stops asking for it every frame. A tombstone is retried on a
    /// backoff because the usual cause is a source that was scanned mid-write
    /// (a download or a copy); the finished file decodes fine.
    ok: bool = false,
    /// Retries already scheduled for a tombstone (drives `retryDelayNs`).
    retries: u8 = 0,
    /// `nowNs` at which `requestMissing` may ask for the source again.
    /// Zero for decoded entries.
    retry_at_ns: u64 = 0,
    stamp: u64 = 0,
};

/// Backoff before re-decoding a tombstone: 0.5s, 1s, 2s, 4s, then 8s cap.
/// Long enough that a still-downloading file stops being decoded every
/// frame, short enough that the tile fills in on its own when it finishes.
const retry_base_ns: u64 = 500 * std.time.ns_per_ms;
const retry_max_ns: u64 = 8 * std.time.ns_per_s;

fn retryDelayNs(retries: u8) u64 {
    const shift: u6 = @intCast(@min(retries, 5));
    return @min(retry_base_ns << shift, retry_max_ns);
}

/// The gallery tile hover pop. Entering
/// a tile rises it to 1.10 over 120 ms of ease-out-quad and then settles it back
/// to 1.0 over 180 ms of ease-out-cubic; leaving the tile settles from wherever
/// it currently is over 150 ms. The scale only wraps the tile's image pass — the
/// stroke, "In use" badge and hover tint stay on the unscaled rect, so the pop reads as the picture swelling under a fixed frame.
pub const HoverPop = struct {
    const Phase = enum { idle, rise, settle, leave };

    scale: f64 = 1.0,
    from: f64 = 1.0,
    to: f64 = 1.0,
    start_ns: u64 = 0,
    dur_ns: u64 = 0,
    phase: Phase = .idle,

    pub const rise_ns: u64 = 120 * std.time.ns_per_ms;
    pub const settle_ns: u64 = 180 * std.time.ns_per_ms;
    pub const leave_ns: u64 = 150 * std.time.ns_per_ms;
    pub const peak: f64 = 1.10;

    pub fn running(self: *const HoverPop) bool {
        return self.phase != .idle;
    }

    /// Drop the tween without animating. Needed when the page stops painting
    /// mid-pop (tab switch) — `step` would otherwise never run, leaving
    /// `running` stuck true and the window's timer armed forever.
    pub fn cancel(self: *HoverPop) void {
        self.scale = 1.0;
        self.phase = .idle;
    }

    /// Pointer moved onto a new tile: restart the rise from 1.0 so the pop is
    /// legible even when sweeping across several tiles in one gesture.
    pub fn beginEnter(self: *HoverPop) void {
        self.scale = 1.0;
        self.from = 1.0;
        self.to = peak;
        self.dur_ns = rise_ns;
        self.start_ns = nowNs();
        self.phase = .rise;
    }

    /// Pointer left the gallery (or the tab): settle back to 1.0 from the
    /// scale it happens to be at mid-pop.
    pub fn beginLeave(self: *HoverPop) void {
        if (self.phase == .idle) return;
        self.from = self.scale;
        self.to = 1.0;
        self.dur_ns = leave_ns;
        self.start_ns = nowNs();
        self.phase = .leave;
    }

    /// Advance the tween and report whether another frame is wanted. `paint`
    /// calls this once per frame; `Win.armTick` keeps the 16 ms timer armed for
    /// as long as it returns true.
    pub fn step(self: *HoverPop) bool {
        if (self.phase == .idle) return false;
        const el: u64 = nowNs() -% self.start_ns;
        const t: f64 = if (self.dur_ns == 0) 1.0 else @min(
            @as(f64, @floatFromInt(el)) / @as(f64, @floatFromInt(self.dur_ns)),
            1.0,
        );
        const e: f64 = switch (self.phase) {
            .rise => easeOutQuad(t),
            .settle, .leave => easeOutCubic(t),
            .idle => 1.0,
        };
        self.scale = self.from + (self.to - self.from) * e;
        if (t < 1.0) return true;
        switch (self.phase) {
            // Completion chains straight back into `animate`, so
            // the rise always hands off to a settle rather than stopping at 1.10.
            .rise => {
                self.from = peak;
                self.to = 1.0;
                self.dur_ns = settle_ns;
                self.start_ns = nowNs();
                self.phase = .settle;
                return true;
            },
            else => {
                self.scale = 1.0;
                self.phase = .idle;
                return false;
            },
        }
    }
};

/// `Easing::EaseOutQuad` — `1 - (1-t)²`.
fn easeOutQuad(t: f64) f64 {
    const u = std.math.clamp(t, 0.0, 1.0);
    return u * (2.0 - u);
}

/// `Easing::EaseOutCubic` — `1 - (1-t)³`.
fn easeOutCubic(t: f64) f64 {
    const u = std.math.clamp(t, 0.0, 1.0);
    const f = u - 1.0;
    return f * f * f + 1.0;
}

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    inited: bool = false,

    /// Values borrowed from `Settings` this frame (see `sync`).
    snap: Snapshot = .{},

    sub_tab: i32 = 0,
    mode_drop_open: bool = false,
    mode_drop_hover: i32 = -1,
    picker_modal_open: bool = false,
    view_open: bool = false,
    /// Session-only window opacity preview (kept out of the
    /// persisted settings too — the slider is a live preview).
    opacity_pct: i32 = 100,

    gallery: scan.Gallery = undefined,
    sort_mode: i32 = 2,
    sort_applied: i32 = -1,
    page_idx: i32 = 0,
    columns: i32 = 4,
    rows: i32 = 3,
    scale_pct: i32 = 100,
    radius_px: i32 = 12,

    folder_synced: ?[]u8 = null,
    folder_mtime_ns: i96 = 0,
    valid: bool = false,
    last_stat_ns: u64 = 0,
    precached: bool = false,

    svc: thumbs.Service = undefined,
    cache: std.StringHashMap(CacheEntry) = undefined,
    lru_seq: u64 = 0,
    hovered_slot: i32 = -1,
    /// Tile hover pop; stepped once per frame by `paint`.
    hover_pop: HoverPop = .{},
    dragging_opacity: bool = false,

    pub fn init(self: *Page, alloc: std.mem.Allocator, io: std.Io) void {
        self.* = .{};
        self.alloc = alloc;
        self.io = io;
        self.gallery = scan.Gallery.init(alloc);
        self.svc = thumbs.Service.init(alloc, io);
        self.cache = std.StringHashMap(CacheEntry).init(alloc);
        self.inited = true;
    }

    pub fn deinit(self: *Page) void {
        if (!self.inited) return;
        // The cache goes first: dropping an entry tells the service it may
        // queue that path again (`forget`), which needs its request map alive.
        // The old order destroyed the service first, so tearing down a page
        // with anything still cached crashed inside the dead map.
        self.clearCache();
        self.svc.deinit();
        self.cache.deinit();
        self.gallery.deinit();
        if (self.folder_synced) |k| {
            self.alloc.free(k);
            self.folder_synced = null;
        }
        self.inited = false;
    }

    /// Borrow this frame's `Settings` values.
    pub fn sync(self: *Page, snap: Snapshot) void {
        self.snap = snap;
    }

    // ------------------------------------------------------------- gallery --

    /// `ensure_wallpaper_gallery`: rescan a changed folder (500ms stat
    /// debounce), order it when the sort pill moved, and warm the thumbnail
    /// queue once per scan.
    ///
    /// A folder *switch* still resets everything, but new or deleted files in
    /// the *same* folder merge incrementally (`syncIncremental`): cached
    /// thumbnails for files that are still there are kept, and only arrivals
    /// are queued for decode. Clearing the whole cache on every mtime bump is
    /// what blanked the grid after a Bing download landed in the watched
    /// folder — every tile had to decode again before anything painted.
    pub fn ensureGallery(self: *Page) void {
        if (!self.inited) return;
        const folder = self.snap.folder;
        if (folder.len == 0) {
            if (self.gallery.entries.items.len > 0) {
                self.svc.releaseAll();
                self.clearCache();
                self.gallery.deinit();
                self.page_idx = 0;
            }
            if (self.folder_synced) |k| {
                self.alloc.free(k);
                self.folder_synced = null;
            }
            self.folder_mtime_ns = 0;
            self.sort_applied = -1;
            self.valid = false;
            return;
        }

        const key = scan.folderKey(self.alloc, folder) catch return;
        defer self.alloc.free(key);

        var needs_rescan = false;
        var needs_refresh = false;
        const now = nowNs();
        if (self.last_stat_ns == 0 or now -% self.last_stat_ns >= stat_debounce_ns) {
            self.last_stat_ns = now;
            const mt = scan.mtimeNs(self.io, key);
            const synced = if (self.folder_synced) |k| std.mem.eql(u8, k, key) else false;
            if (!synced) {
                needs_rescan = true;
                if (self.folder_synced) |k| self.alloc.free(k);
                self.folder_synced = self.alloc.dupe(u8, key) catch null;
                self.folder_mtime_ns = mt;
            } else if (self.folder_mtime_ns != mt) {
                // Same folder, new contents — merge, don't wipe.
                needs_refresh = true;
                self.folder_mtime_ns = mt;
            }
        }

        if (needs_rescan or self.gallery.entries.items.len == 0 or !self.valid) {
            self.fullRescan(key);
        } else if (needs_refresh) {
            self.syncIncremental(key);
        } else {
            self.valid = true;
        }

        if (self.sort_mode != self.sort_applied) {
            scan.sortEntries(self.gallery.entries.items, self.sort_mode);
            self.sort_applied = self.sort_mode;
        }

        if (!self.precached and self.gallery.entries.items.len > 0) {
            self.precached = true;
            for (self.gallery.entries.items) |e| _ = self.svc.request(e.path, cache_px);
        }
    }

    /// Folder switch (or first scan): drop everything and start over. Stale
    /// decodes from the old folder must never land in the new one's cache,
    /// which is what the generation bump in `releaseAll` guarantees.
    fn fullRescan(self: *Page, key: []const u8) void {
        self.svc.releaseAll();
        self.clearCache();
        self.gallery.deinit();
        scan.scanFolder(self.alloc, self.io, key, &self.gallery);
        self.page_idx = 0;
        self.sort_applied = -1;
        self.precached = false;
        self.valid = true;
    }

    /// Drop one path's cached thumbnail (if any) and let the service queue it
    /// again should the file come back.
    fn dropCached(self: *Page, path: []const u8) void {
        if (self.cache.fetchRemove(path)) |kv| {
            var v = kv.value;
            destroyEntry(self.alloc, &v);
            self.svc.forget(kv.key);
            self.alloc.free(kv.key);
        } else {
            self.svc.forget(path);
        }
    }

    /// Same folder, new mtime: merge a fresh listing into the live gallery.
    /// Survivors keep their cache entries and their in-flight decodes;
    /// arrivals are queued; departures are dropped. The page index is only
    /// clamped (by the paint path), never reset — a single download must not
    /// yank the grid back to page one.
    fn syncIncremental(self: *Page, key: []const u8) void {
        var tmp = scan.Gallery.init(self.alloc);
        scan.scanFolder(self.alloc, self.io, key, &tmp);

        var fresh = std.StringHashMap(void).init(self.alloc);
        defer fresh.deinit();
        var live = std.StringHashMap(void).init(self.alloc);
        defer live.deinit();

        var maps_ok = true;
        for (tmp.entries.items) |e| {
            fresh.put(e.path, {}) catch {
                maps_ok = false;
                break;
            };
        }
        if (maps_ok) {
            for (self.gallery.entries.items) |e| {
                live.put(e.path, {}) catch {
                    maps_ok = false;
                    break;
                };
            }
        }
        if (!maps_ok) {
            // Two tiny tables failing to allocate means memory is gone; fall
            // back to a full rescan rather than prune against half-built sets.
            tmp.deinit();
            self.fullRescan(key);
            return;
        }

        // Departures: out of the gallery and out of the cache.
        var i: usize = 0;
        while (i < self.gallery.entries.items.len) {
            const old_path = self.gallery.entries.items[i].path;
            if (fresh.contains(old_path)) {
                i += 1;
            } else {
                self.dropCached(old_path);
                self.alloc.free(old_path);
                _ = self.gallery.entries.orderedRemove(i);
            }
        }

        // Arrivals: take over the fresh dupe and queue a decode. Entries for
        // files we already own are duplicate dupes — free them.
        for (tmp.entries.items) |e| {
            if (live.contains(e.path)) {
                self.alloc.free(e.path);
            } else {
                self.gallery.entries.append(self.alloc, e) catch {
                    self.alloc.free(e.path);
                    continue;
                };
                _ = self.svc.request(e.path, cache_px);
            }
        }
        const truncated = tmp.truncated;
        tmp.entries.deinit(self.alloc);
        self.gallery.truncated = truncated;
        self.sort_applied = -1;
    }

    /// Absolute index of `image` in the gallery, or null.
    pub fn indexOfImage(self: *const Page, image: []const u8) ?usize {
        for (self.gallery.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, image)) return i;
        }
        return null;
    }

    fn clampPage(self: *Page, per_page: usize) void {
        const pp: usize = @max(1, per_page);
        const n: usize = self.gallery.entries.items.len;
        const pages: i32 = @intCast(@max(1, (n + pp - 1) / pp));
        if (self.page_idx >= pages) self.page_idx = pages - 1;
        if (self.page_idx < 0) self.page_idx = 0;
    }

    fn pagesOf(self: *const Page, per_page: usize) i32 {
        const pp: usize = @max(1, per_page);
        const n: usize = self.gallery.entries.items.len;
        return @intCast(@max(1, (n + pp - 1) / pp));
    }

    /// `wallpaper_tab_layout` — the gallery grid's columns, tile size and
    /// page-nav placement for the current view options.
    pub fn grid(self: *const Page, card_inset_x: i32, content_w: i32, gallery_top: i32) Grid {
        const avail_w = content_w - 8 - 2 * k_card_pad;
        const cols: i32 = std.math.clamp(self.columns, 1, 10);
        const scale = @as(f64, @floatFromInt(std.math.clamp(self.scale_pct, 50, 200))) / 100.0;
        var tw: i32 = @intFromFloat(@ceil(
            (@as(f64, @floatFromInt(avail_w - k_thumb_gap * (cols - 1))) /
                @as(f64, @floatFromInt(cols))) * scale,
        ));
        tw = @max(40, tw);
        const thumb_h: i32 = @divTrunc(tw * 9 + 8, 16);
        const rows: i32 = std.math.clamp(self.rows, 1, 10);
        const per_page: usize = @as(usize, @intCast(cols)) * @as(usize, @intCast(rows));
        const n: usize = self.gallery.entries.items.len;
        const row_stride_nav = thumb_h + k_thumb_label_h + 6;
        const grid_bottom_nav = gallery_top + rows * row_stride_nav;
        const nav_y = grid_bottom_nav + 14;
        const show_nav = n > per_page;
        return .{
            .cols = cols,
            .rows = rows,
            .thumb = tw,
            .thumb_h = thumb_h,
            .per_page = per_page,
            .top = gallery_top,
            .nav_y = nav_y,
            .show_nav = show_nav,
            .prev_x = card_inset_x + k_card_pad,
            .next_x = card_inset_x + content_w - k_card_pad - nav_w,
        };
    }

    /// `wp_tab_logical_bottom_px` — what the scroll extent is measured to.
    pub fn totalHeight(self: *Page, g: Geo) i32 {
        if (!self.inited) return g.win_h;
        self.ensureGallery();
        const m = metrics(@floatFromInt(g.content_x), @floatFromInt(g.content_w), self.view_open);
        const gr = self.grid(g.content_x + 8, g.content_w, m.gallery_grid_top);
        const bottom_px: i32 = if (self.sub_tab == 1)
            m.sub_tab_y + 48 + 88 + 28 + 12 + 5 * 48 + 8 + 24
        else if (gr.show_nav)
            gr.nav_y + nav_h + 20
        else
            gr.top + gr.rows * (gr.thumb_h + k_thumb_label_h + 6) + 28;
        return @max(0, bottom_px - k_content_top + 12);
    }

    // ----------------------------------------------------------- thumbnails --

    /// `Page` keeps the decoded surfaces; the service
    /// only decodes. Results land on the eventfd the window watches, so this
    /// runs once per frame that has anything new.
    pub fn drainThumbs(self: *Page) void {
        if (!self.inited) return;
        var list: std.ArrayList(thumbs.Result) = .empty;
        defer {
            for (list.items) |r| thumbs.freeResult(self.alloc, r);
            list.deinit(self.alloc);
        }
        self.svc.drain(&list);
        // By pointer: `cachePut` takes over the path and pixels and empties
        // each result, so the `defer` above only frees what it declined.
        for (list.items) |*r| self.cachePut(r);
    }

    fn nextStamp(self: *Page) u64 {
        self.lru_seq += 1;
        return self.lru_seq;
    }

    /// Take a drained result into the cache: `path` becomes the key and
    /// `pixels` the wrapped buffer. Both are detached from the result, so the
    /// caller's deferred `freeResult` no longer owns them — freeing here
    /// would leave the map keying off reused memory and let two entries
    /// collide on rehash.
    fn cachePut(self: *Page, r: *thumbs.Result) void {
        const path = r.path;
        const pixels = r.pixels;
        r.path = r.path[0..0];
        r.pixels = r.pixels[0..0];

        // Carry the tombstone's retry count across the replacement so a
        // second failure backs off rather than restarting at 0.5s.
        var prev_retries: u8 = 0;
        if (self.cache.fetchRemove(path)) |kv| {
            prev_retries = kv.value.retries;
            var old = kv.value;
            destroyEntry(self.alloc, &old);
            self.alloc.free(kv.key);
        }
        var e: CacheEntry = .{
            .w = r.w,
            .h = r.h,
            .pixels = pixels,
            .ok = r.ok,
            .stamp = self.nextStamp(),
        };
        if (!r.ok) {
            e.retries = prev_retries;
            e.retry_at_ns = nowNs() +% retryDelayNs(prev_retries);
        }
        if (r.ok and r.w > 0 and r.h > 0) {
            // Built on the UI thread: cairo image surfaces are not safe to
            // hand between threads, and the pixels are already final.
            const s = cairo.cairo_image_surface_create_for_data(
                @ptrCast(pixels.ptr),
                cairo.CAIRO_FORMAT_ARGB32,
                r.w,
                r.h,
                r.w * 4,
            );
            if (cairo.cairo_surface_status(s) == cairo.CAIRO_STATUS_SUCCESS) {
                e.surf = s;
            } else {
                cairo.cairo_surface_destroy(s);
            }
        }
        self.cache.put(path, e) catch {
            destroyEntry(self.alloc, &e);
            self.alloc.free(path);
        };
        self.evictLru();
    }

    fn evictLru(self: *Page) void {
        while (self.cache.count() > thumb_cache_cap) {
            var it = self.cache.iterator();
            var oldest_key: ?[]const u8 = null;
            var oldest_stamp: u64 = std.math.maxInt(u64);
            while (it.next()) |e| {
                if (e.value_ptr.stamp < oldest_stamp) {
                    oldest_stamp = e.value_ptr.stamp;
                    oldest_key = e.key_ptr.*;
                }
            }
            const key = oldest_key orelse return;
            if (self.cache.fetchRemove(key)) |kv| {
                var v = kv.value;
                destroyEntry(self.alloc, &v);
                self.svc.forget(kv.key);
                self.alloc.free(kv.key);
            }
        }
    }

    fn clearCache(self: *Page) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            destroyEntry(self.alloc, e.value_ptr);
            self.svc.forget(e.key_ptr.*);
            self.alloc.free(e.key_ptr.*);
        }
        self.cache.clearRetainingCapacity();
    }

    fn destroyEntry(alloc: std.mem.Allocator, e: *CacheEntry) void {
        if (e.surf) |s| cairo.cairo_surface_destroy(s);
        e.surf = null;
        if (e.pixels.len > 0) alloc.free(e.pixels);
        e.pixels = &.{};
    }

    /// Cached surface for `path`, touching its LRU stamp.
    fn surfaceFor(self: *Page, path: []const u8) ?*cairo.cairo_surface_t {
        if (path.len == 0) return null;
        const e = self.cache.getPtr(path) orelse return null;
        e.stamp = self.nextStamp();
        return e.surf;
    }

    /// Request `path` if nothing is cached, or re-request a tombstone once
    /// its backoff has elapsed. A failed decode is usually a source that was
    /// scanned mid-write (a download or a copy), so the finished file has to
    /// get another chance; without one the tile stayed black until the tab
    /// was reopened.
    fn requestOrRetry(self: *Page, path: []const u8, px: u32) void {
        if (path.len == 0) return;
        if (self.cache.getPtr(path)) |e| {
            if (e.ok) return;
            const now = nowNs();
            if (now < e.retry_at_ns) return;
            self.svc.forget(path);
            if (self.svc.request(path, px)) {
                e.retries +|= 1;
                e.retry_at_ns = now +% retryDelayNs(e.retries);
            }
            return;
        }
        _ = self.svc.request(path, px);
    }

    /// Ask for whatever is missing: the hero, and every tile on this page.
    /// (`wallpaper_ensure_hero_surface` plus the grid loop's own requests.)
    fn requestMissing(self: *Page, gr: *const Grid) void {
        self.requestOrRetry(self.snap.image, cache_px);

        const gall_off: usize = @as(usize, @intCast(@max(0, self.page_idx))) * gr.per_page;
        const n_total: usize = self.gallery.entries.items.len;
        if (gall_off >= n_total) return;
        const n_slots: usize = @min(gr.per_page, n_total - gall_off);
        const decode_px: u32 = @intCast(std.math.clamp(@max(gr.thumb, gr.thumb_h), 64, 1600));
        var ii: usize = 0;
        while (ii < n_slots) : (ii += 1) {
            const fp = self.gallery.entries.items[gall_off + ii].path;
            self.requestOrRetry(fp, decode_px);
        }
    }

    // ---------------------------------------------------------------- paint --

    pub fn paint(
        self: *Page,
        cr: ?*cairo.cairo_t,
        g: Geo,
        px: f64,
        py: f64,
        glass_ov: f64,
    ) void {
        const c = cr orelse return;
        if (!self.inited) return;
        self.drainThumbs();
        self.ensureGallery();

        const t = common.Theme;
        const m = metrics(@floatFromInt(g.content_x), @floatFromInt(g.content_w), self.view_open);
        const card_inset_x = g.content_x + 8;
        const gr = self.grid(card_inset_x, g.content_w, m.gallery_grid_top);
        self.clampPage(gr.per_page);

        // The card surface stretches to the logical content height.
        const bottom_px: i32 = if (self.sub_tab == 1)
            m.sub_tab_y + 48 + 88 + 28 + 12 + 5 * 48 + 8 + 24
        else if (gr.show_nav)
            gr.nav_y + nav_h + 20
        else
            gr.top + gr.rows * (gr.thumb_h + k_thumb_label_h + 6) + 28;
        const view_fill: i32 = g.win_h - k_content_top - k_spacing_xl;
        const card_h: i32 = @max(view_fill, bottom_px - k_content_top + 12);
        ui_paint.card(
            c,
            @floatFromInt(g.content_x),
            @floatFromInt(k_content_top),
            @floatFromInt(g.content_w),
            @floatFromInt(card_h),
            glass_ov,
        );

        // Title.
        ui_paint.showText(
            c,
            @floatFromInt(g.content_x + k_card_pad),
            @floatFromInt(k_content_top + 36),
            "Wallpaper",
            17,
            600,
            t.text_r,
            t.text_g,
            t.text_b,
            0.95,
        );

        // `settings_toggle` band: 52x26 at the right of the top row.
        {
            const wg_w: i32 = 52;
            const wg_h: i32 = 26;
            const wg_x = card_inset_x + (g.content_w - 16) - wg_w - k_spacing_xl;
            const wg_y = k_content_top + @divTrunc(k_wallpaper_toggle_band_h - wg_h, 2);
            paintSwitch(c, wg_x, wg_y, wg_w, wg_h, self.snap.enabled);
        }

        // Underline sub-tab bar.
        {
            const st_x: i32 = g.content_x + k_card_pad;
            const st_y = m.sub_tab_y;
            const st_h: i32 = 48;
            cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.25);
            cairo_set_line_width(c, 1.0);
            const rule_y = @as(f64, @floatFromInt(st_y + st_h)) - 0.5;
            cairo_move_to(c, @floatFromInt(st_x), rule_y);
            cairo_line_to(c, @floatFromInt(st_x + g.content_w - 2 * k_card_pad), rule_y);
            cairo_stroke(c);

            ui_paint.showText(c, @floatFromInt(st_x + 16), @floatFromInt(st_y + st_h / 2 + 6), "Wallpaper", 16, 500, t.text_r, t.text_g, t.text_b, if (self.sub_tab == 0) 0.95 else 0.5);
            if (self.sub_tab == 0) paintUnderline(c, st_x + 16, st_y + st_h - 3, 100, t);

            const tab1_x = st_x + 100 + 24;
            ui_paint.showText(c, @floatFromInt(tab1_x + 16), @floatFromInt(st_y + st_h / 2 + 6), "Gallery settings", 16, 500, t.text_r, t.text_g, t.text_b, if (self.sub_tab == 1) 0.95 else 0.5);
            if (self.sub_tab == 1) paintUnderline(c, tab1_x + 16, st_y + st_h - 3, 160, t);
        }

        if (self.sub_tab == 1) {
            self.paintGallerySettings(c, g, &m, px, py);
        } else {
            self.paintWallpaperTab(c, g, &m, &gr, px, py, glass_ov);
        }

        // The mode list hangs off the toolbar combo and scrolls with the page,
        // (it is painted in layout space too).
        if (self.sub_tab == 0 and self.mode_drop_open) {
            const dd_y = m.tool_combo_y + m.tool_combo_h + 2;
            self.mode_drop_hover = ddHoverRow(px, py, m.tool_combo_x, dd_y, m.tool_combo_w);
            paintComboPopup(c, m.tool_combo_x, dd_y, m.tool_combo_w, self.snap.mode, self.mode_drop_hover, t);
        }
    }

    fn paintWallpaperTab(
        self: *Page,
        c: anytype,
        g: Geo,
        m: *const Metrics,
        gr: *const Grid,
        px: f64,
        py: f64,
        glass_ov: f64,
    ) void {
        const t = common.Theme;
        const hero_x: i32 = @intFromFloat(m.hero_x);
        const hero_y = m.hero_y;
        const hero_w = m.hero_w;
        const hero_h = m.hero_h;

        // Hero: clipped cover of the cached surface over a dark plate.
        cairo_save(c);
        ui_paint.roundRect(c, @floatFromInt(hero_x), @floatFromInt(hero_y), @floatFromInt(hero_w), @floatFromInt(hero_h), k_hero_radius);
        cairo_clip(c);
        cairo_set_source_rgba(c, t.bg_r * 0.35, t.bg_g * 0.35, t.bg_b * 0.35, 0.94);
        cairo_paint(c);
        if (self.surfaceFor(self.snap.image)) |surf| {
            cairo_surface_flush(surf);
            const iw = cairo_image_surface_get_width(surf);
            const ih = cairo_image_surface_get_height(surf);
            if (iw > 0 and ih > 0) {
                const wf: f64 = @floatFromInt(hero_w);
                const hf: f64 = @floatFromInt(hero_h);
                const sc = @max(
                    wf / @as(f64, @floatFromInt(iw)),
                    hf / @as(f64, @floatFromInt(ih)),
                );
                const disp_w = @as(f64, @floatFromInt(iw)) * sc;
                const disp_h = @as(f64, @floatFromInt(ih)) * sc;
                const ox = @as(f64, @floatFromInt(hero_x)) + (wf - disp_w) * 0.5;
                const oy = @as(f64, @floatFromInt(hero_y)) + (hf - disp_h) * 0.5;
                cairo_translate(c, ox, oy);
                cairo_scale(c, sc, sc);
                cairo_set_source_surface(c, surf, 0, 0);
                cairo_paint(c);
            }
        }
        cairo_restore(c);

        // Bright inner rim + dark hairline.
        cairo_save(c);
        const rim = cairo_pattern_create_linear(0, @floatFromInt(hero_y), 0, @floatFromInt(hero_y + hero_h));
        cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.38 * glass_ov);
        cairo_pattern_add_color_stop_rgba(rim, 0.35, 1.0, 1.0, 1.0, 0.14 * glass_ov);
        cairo_pattern_add_color_stop_rgba(rim, 0.7, 1.0, 1.0, 1.0, 0.05 * glass_ov);
        cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.12 * glass_ov);
        cairo_set_source(c, rim);
        cairo_set_line_width(c, 1.0);
        ui_paint.roundRect(c, @floatFromInt(hero_x + 1), @floatFromInt(hero_y + 1), @floatFromInt(hero_w - 2), @floatFromInt(hero_h - 2), k_hero_radius - 1.0);
        cairo_stroke(c);
        cairo_pattern_destroy(rim);
        cairo_restore(c);

        cairo_save(c);
        ui_paint.roundRect(c, @as(f64, @floatFromInt(hero_x)) + 0.5, @as(f64, @floatFromInt(hero_y)) + 0.5, @floatFromInt(hero_w - 1), @floatFromInt(hero_h - 1), k_hero_radius);
        cairo_set_source_rgba(c, 0, 0, 0, 0.25);
        cairo_set_line_width(c, 1.0);
        cairo_stroke(c);
        cairo_restore(c);

        // Top/bottom scrims.
        {
            const gtop = cairo_pattern_create_linear(@floatFromInt(hero_x), @floatFromInt(hero_y), @floatFromInt(hero_x), @floatFromInt(hero_y + 64));
            cairo_pattern_add_color_stop_rgba(gtop, 0, 0, 0, 0, 0.5);
            cairo_pattern_add_color_stop_rgba(gtop, 1, 0, 0, 0, 0);
            cairo_set_source(c, gtop);
            cairo_rectangle(c, @floatFromInt(hero_x), @floatFromInt(hero_y), @floatFromInt(hero_w), 64);
            cairo_fill(c);
            cairo_pattern_destroy(gtop);

            const gbot = cairo_pattern_create_linear(@floatFromInt(hero_x), @floatFromInt(hero_y + hero_h - 72), @floatFromInt(hero_x), @floatFromInt(hero_y + hero_h));
            cairo_pattern_add_color_stop_rgba(gbot, 0, 0, 0, 0, 0);
            cairo_pattern_add_color_stop_rgba(gbot, 1, 0, 0, 0, 0.55);
            cairo_set_source(c, gbot);
            cairo_rectangle(c, @floatFromInt(hero_x), @floatFromInt(hero_y + hero_h - 72), @floatFromInt(hero_w), 72);
            cairo_fill(c);
            cairo_pattern_destroy(gbot);
        }

        // "In use" badge over the hero.
        if (self.snap.image.len > 0) {
            ui_paint.glassBox(c, @floatFromInt(hero_x + 12), @floatFromInt(hero_y + 12), 62, 24, 9, 0.55, 0.53, 0.58, 0.35);
            ui_paint.showText(c, @floatFromInt(hero_x + 20), @floatFromInt(hero_y + 29), "In use", 10, 500, 1, 1, 1, 1.0);
        }

        // Floating toolbar over the hero bottom.
        ui_paint.glassBox(
            c,
            @floatFromInt(m.tool_bar_x),
            @floatFromInt(m.tool_bar_y),
            @floatFromInt(m.tool_bar_w),
            @floatFromInt(m.tool_bar_h),
            14,
            0,
            0,
            0,
            0.45,
        );
        paintGlyphBtn(c, m.tool_prev_x, m.tool_icon_y, "chevron_left", false, inR(px, py, m.tool_prev_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s), t);
        paintGlyphBtn(c, m.tool_next_x, m.tool_icon_y, "chevron_right", false, inR(px, py, m.tool_next_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s), t);

        // Current file name + position counter.
        {
            const n_total: usize = self.gallery.entries.items.len;
            const cur = if (self.snap.image.len > 0) self.indexOfImage(self.snap.image) else null;
            const base: []const u8 = if (self.snap.image.len == 0)
                "No wallpaper selected"
            else
                std.fs.path.basename(self.snap.image);
            var name_buf: [96]u8 = undefined;
            const max_c: usize = @intCast(std.math.clamp(@divTrunc(m.tool_text_w, 7), 12, 64));
            const shown = truncateVisual(&name_buf, base, max_c);
            ui_paint.showText(c, @floatFromInt(m.tool_text_x), @floatFromInt(m.tool_bar_y + 24), shown, 14, 600, 1, 1, 1, 0.95);
            var pos_buf: [48]u8 = undefined;
            if (cur) |ci| {
                const pos = std.fmt.bufPrint(&pos_buf, "{d} / {d}", .{ ci + 1, n_total }) catch "";
                ui_paint.showText(c, @floatFromInt(m.tool_text_x), @floatFromInt(m.tool_bar_y + 42), pos, 12, 400, 1, 1, 1, 0.65);
            } else if (n_total > 0) {
                const pos = std.fmt.bufPrint(&pos_buf, "{d} wallpapers", .{n_total}) catch "";
                ui_paint.showText(c, @floatFromInt(m.tool_text_x), @floatFromInt(m.tool_bar_y + 42), pos, 12, 400, 1, 1, 1, 0.65);
            }
        }

        // Fill-mode combo.
        {
            const mm: usize = @intCast(std.math.clamp(self.snap.mode, 0, 4));
            const hov = inR(px, py, m.tool_combo_x, m.tool_combo_y, m.tool_combo_w, m.tool_combo_h);
            paintCombo(c, m.tool_combo_x, m.tool_combo_y, m.tool_combo_w, m.tool_combo_h, mode_labels[mm], hov or self.mode_drop_open, t);
        }

        paintGlyphBtn(c, m.tool_tune_x, m.tool_icon_y, "tune", self.view_open, inR(px, py, m.tool_tune_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s), t);
        paintGlyphBtn(c, m.tool_folder_x, m.tool_icon_y, "folder", false, inR(px, py, m.tool_folder_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s), t);
        paintGlyphBtn(c, m.tool_delete_x, m.tool_icon_y, "delete", false, inR(px, py, m.tool_delete_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s), t);

        // Full-width primary button under the hero.
        paintBtn(
            c,
            hero_x,
            m.picker_y,
            hero_w,
            k_picker_h,
            "Open Picker…",
            true,
            inR(px, py, hero_x, m.picker_y, hero_w, k_picker_h),
            t,
        );

        // Gallery toolbar: folder path + count left, sort pills + tune right.
        {
            var hd_buf: [256]u8 = undefined;
            const folder_disp: []const u8 = if (self.snap.folder.len == 0) "No folder" else self.snap.folder;
            const hd_full = std.fmt.bufPrint(&hd_buf, "{s}  ·  {d} wallpapers", .{ folder_disp, self.gallery.entries.items.len }) catch "";
            const max_c: usize = @intCast(std.math.clamp(@divTrunc(m.sort_pills_x - 12 - hero_x, 7), 16, 120));
            var hd_out: [320]u8 = undefined;
            const shown = truncateVisual(&hd_out, hd_full, max_c);
            ui_paint.showText(c, @floatFromInt(hero_x), m.gallery_toolbar_y + 21, shown, 13, 500, t.text_r, t.text_g, t.text_b, 0.7);
        }
        {
            var px_i = m.sort_pills_x;
            for (sort_labels, 0..) |lab, pi| {
                const sel = self.sort_mode == @as(i32, @intCast(pi));
                paintBtn(
                    c,
                    px_i,
                    m.sort_pills_y,
                    sort_pill_w[pi],
                    28,
                    lab,
                    sel,
                    inR(px, py, px_i, m.sort_pills_y, sort_pill_w[pi], 28),
                    t,
                );
                px_i += sort_pill_w[pi] + 8;
            }
            const hov = inR(px, py, m.gallery_tune_x, m.sort_pills_y, 40, 28);
            paintGlyphBtnWide(c, m.gallery_tune_x, m.sort_pills_y, 40, 28, "tune", self.view_open, hov, t);
        }

        // Collapsible view-options panel.
        if (self.view_open) {
            const panel_x = hero_x;
            const panel_y = m.view_panel_y;
            const panel_w = hero_w;
            ui_paint.glassBox(c, @floatFromInt(panel_x), @floatFromInt(panel_y), @floatFromInt(panel_w), k_view_panel_h, 20, 1, 1, 1, 0.07);
            cairo_save(c);
            ui_paint.roundRect(c, @floatFromInt(panel_x), @floatFromInt(panel_y), @floatFromInt(panel_w), k_view_panel_h, 20.0);
            cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.25);
            cairo_set_line_width(c, 1.0);
            cairo_stroke(c);
            cairo_restore(c);

            ui_paint.showText(c, @floatFromInt(panel_x + 20), @floatFromInt(panel_y + 30), "View options", 14, 600, t.text_r, t.text_g, t.text_b, 0.95);
            ui_paint.showText(c, @floatFromInt(panel_x + panel_w - 20 - 118), @floatFromInt(panel_y + 30), "All settings →", 12, 500, t.acc_r, t.acc_g, t.acc_b, 0.9);

            const labels = [_][]const u8{ "Columns", "Rows", "Scale", "Radius" };
            for (labels, 0..) |lab, vi| {
                const cell = viewCell(m, @intCast(vi));
                ui_paint.showText(c, @floatFromInt(cell.x), panel_y + 62, lab, 12, 400, t.text_r, t.text_g, t.text_b, 0.6);
                var val_buf: [16]u8 = undefined;
                const val = self.viewValue(@intCast(vi), &val_buf) catch "";
                ui_paint.showText(c, @floatFromInt(cell.x + 44 + 8), panel_y + 92, val, 15, 600, t.text_r, t.text_g, t.text_b, 1.0);
                const hov_m = inR(px, py, cell.minus_x, cell.btn_y, 44, 32);
                const hov_p = inR(px, py, cell.plus_x, cell.btn_y, 44, 32);
                paintStepperIcon(c, cell.minus_x, cell.btn_y, 44, 32, false, hov_m, t);
                paintStepperIcon(c, cell.plus_x, cell.btn_y, 44, 32, true, hov_p, t);
            }
        }

        // Thumbnail grid.
        {
            self.requestMissing(gr);
            // `gr.prev_x` is `card_inset_x + kCardPad` — the grid's left edge.
            const gx0: f64 = @floatFromInt(gr.prev_x);
            const gall_off: usize = @as(usize, @intCast(@max(0, self.page_idx))) * gr.per_page;
            const n_total: usize = self.gallery.entries.items.len;
            const n_slots: usize = if (gall_off >= n_total) 0 else @min(gr.per_page, n_total - gall_off);
            const row_stride = gr.thumb_h + k_thumb_label_h + 6;
            const tile_rad: f64 = @floatFromInt(std.math.clamp(self.radius_px, 0, 48));
            // Advance the pop before the loop so this frame paints the freshest
            // scale; `hovered_slot` is filled in by the loop and the transition
            // is judged once it is final.
            _ = self.hover_pop.step();
            const prev_hover: i32 = self.hovered_slot;
            self.hovered_slot = -1;

            var ii: usize = 0;
            while (ii < n_slots) : (ii += 1) {
                const fp = self.gallery.entries.items[gall_off + ii].path;
                const row: i32 = @intCast(ii / @as(usize, @intCast(gr.cols)));
                const col: i32 = @intCast(ii % @as(usize, @intCast(gr.cols)));
                const gx = gx0 + @as(f64, @floatFromInt(col * (gr.thumb + gr.gap)));
                const gy_f: f64 = @floatFromInt(gr.top + row * row_stride);
                const hovered = inR(px, py, @intFromFloat(gx), @intFromFloat(gy_f), gr.thumb, gr.thumb_h);
                if (hovered) self.hovered_slot = @intCast(ii);

                cairo_save(c);
                // The pop wraps only the image pass, and only while it is above
                // the base — same `hs > 1.001` guard.
                const hs: f64 = if (hovered) self.hover_pop.scale else 1.0;
                if (hs > 1.001) {
                    const cx = gx + @as(f64, @floatFromInt(gr.thumb)) * 0.5;
                    const cy = gy_f + @as(f64, @floatFromInt(gr.thumb_h)) * 0.5;
                    cairo_translate(c, cx, cy);
                    cairo_scale(c, hs, hs);
                    cairo_translate(c, -cx, -cy);
                }
                ui_paint.roundRect(c, gx, gy_f, @floatFromInt(gr.thumb), @floatFromInt(gr.thumb_h), tile_rad);
                cairo_clip(c);
                cairo_set_operator(c, CAIRO_OPERATOR_OVER);
                if (self.surfaceFor(fp)) |surf| {
                    cairo_surface_flush(surf);
                    const iw = cairo_image_surface_get_width(surf);
                    const ih = cairo_image_surface_get_height(surf);
                    if (iw > 0 and ih > 0) {
                        const twf: f64 = @floatFromInt(gr.thumb);
                        const thf: f64 = @floatFromInt(gr.thumb_h);
                        const sc = @max(
                            twf / @as(f64, @floatFromInt(iw)),
                            thf / @as(f64, @floatFromInt(ih)),
                        );
                        const ox = gx + (twf - @as(f64, @floatFromInt(iw)) * sc) * 0.5;
                        const oy = gy_f + (thf - @as(f64, @floatFromInt(ih)) * sc) * 0.5;
                        cairo_translate(c, ox, oy);
                        cairo_scale(c, sc, sc);
                        cairo_set_source_surface(c, surf, 0, 0);
                        cairo_paint(c);
                    }
                } else {
                    cairo_set_source_rgba(c, t.bg_r * 0.35, t.bg_g * 0.35, t.bg_b * 0.35, 0.95);
                    cairo_paint(c);
                }
                cairo_restore(c);

                const selected = std.mem.eql(u8, fp, self.snap.image);
                if (selected) {
                    cairo_save(c);
                    ui_paint.roundRect(c, gx, gy_f, @floatFromInt(gr.thumb), @floatFromInt(gr.thumb_h), tile_rad);
                    cairo_clip(c);
                    cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.22);
                    cairo_set_operator(c, CAIRO_OPERATOR_OVER);
                    cairo_paint(c);
                    cairo_restore(c);
                }

                cairo_save(c);
                ui_paint.roundRect(c, gx, gy_f, @floatFromInt(gr.thumb), @floatFromInt(gr.thumb_h), tile_rad);
                cairo_set_line_width(c, if (selected) 2.3 else 1.0);
                if (selected)
                    cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.72)
                else
                    cairo_set_source_rgba(c, 1, 1, 1, 0.12);
                cairo_stroke(c);
                cairo_restore(c);

                if (selected) {
                    ui_paint.glassBox(c, gx + 6, gy_f + 6, 54, 18, 6, 0.55, 0.53, 0.58, 0.35);
                    ui_paint.showText(c, gx + 10, gy_f + 19, "In use", 9, 400, t.text_r, t.text_g, t.text_b, 1.0);
                }

                if (hovered) {
                    cairo_save(c);
                    ui_paint.roundRect(c, gx, gy_f, @floatFromInt(gr.thumb), @floatFromInt(gr.thumb_h), tile_rad);
                    cairo_clip(c);
                    cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.15);
                    cairo_paint(c);
                    cairo_restore(c);
                }
            }

            // Hover transitions, judged once the loop has filled in the slot.
            // Moving between two tiles deliberately does not restart the pop —
            // the rise keys off `!wasHovering` only, so a sweep across
            // the grid runs one continuous tween.
            if (self.hovered_slot >= 0 and prev_hover < 0) {
                self.hover_pop.beginEnter();
            } else if (self.hovered_slot < 0 and prev_hover >= 0) {
                self.hover_pop.beginLeave();
            }

            // Page navigation.
            if (gr.show_nav) {
                const hov_p = inR(px, py, gr.prev_x, gr.nav_y, nav_w, nav_h);
                const hov_n = inR(px, py, gr.next_x, gr.nav_y, nav_w, nav_h);
                paintBtn(c, gr.prev_x, gr.nav_y, nav_w, nav_h, "Prev", false, hov_p, t);
                paintBtn(c, gr.next_x, gr.nav_y, nav_w, nav_h, "Next", false, hov_n, t);
                var ps_buf: [32]u8 = undefined;
                const ps = std.fmt.bufPrint(&ps_buf, "{d} / {d}", .{ self.page_idx + 1, self.pagesOf(gr.per_page) }) catch "";
                ui_paint.showText(
                    c,
                    @as(f64, @floatFromInt(g.content_x)) + @as(f64, @floatFromInt(g.content_w)) / 2.0,
                    @floatFromInt(gr.nav_y + 18),
                    ps,
                    12,
                    400,
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    0.6,
                );
            }
        }
    }

    fn paintGallerySettings(
        self: *Page,
        c: anytype,
        g: Geo,
        m: *const Metrics,
        px: f64,
        py: f64,
    ) void {
        const t = common.Theme;
        const gs_x: i32 = g.content_x + k_card_pad;
        const gs_w: i32 = @min(640, g.content_w - 2 * k_card_pad);
        const gs_y: i32 = m.sub_tab_y + 60;

        ui_paint.glassBox(c, @floatFromInt(gs_x), @floatFromInt(gs_y), @floatFromInt(gs_w), 392, 24, 1, 1, 1, 0.07);
        cairo_save(c);
        ui_paint.roundRect(c, @floatFromInt(gs_x), @floatFromInt(gs_y), @floatFromInt(gs_w), 392, 24.0);
        cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.25);
        cairo_set_line_width(c, 1.0);
        cairo_stroke(c);
        cairo_restore(c);

        ui_paint.showText(c, @floatFromInt(gs_x + 32), @floatFromInt(gs_y + 36), "Grid Layout", 18, 600, t.text_r, t.text_g, t.text_b, 1.0);
        ui_paint.showText(
            c,
            @floatFromInt(gs_x + 32),
            @floatFromInt(gs_y + 56),
            "Session only — quick options also on the Wallpaper tab.",
            12,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.55,
        );

        const gal_picker_y = gs_y + 88;
        paintBtn(
            c,
            gs_x + 32,
            gal_picker_y,
            gs_w - 64,
            28,
            "Folder dialog (native / kdialog / …)",
            false,
            inR(px, py, gs_x + 32, gal_picker_y, gs_w - 64, 28),
            t,
        );

        const row0 = gal_picker_y + 28 + 20;
        const row_pitch: i32 = 48;
        const btn_w: i32 = 36;
        const btn_h: i32 = 28;
        const minus_x = gs_x + gs_w - 32 - 2 * btn_w - 10;
        const plus_x = gs_x + gs_w - 32 - btn_w;

        const labels = [_][]const u8{ "Columns", "Rows", "Thumbnail scale", "Corner radius" };
        for (labels, 0..) |lab, r| {
            const ry = row0 + @as(i32, @intCast(r)) * row_pitch;
            ui_paint.showText(c, @floatFromInt(gs_x + 32), @floatFromInt(ry + 20), lab, 13, 500, t.text_r, t.text_g, t.text_b, 1.0);
            var val_buf: [16]u8 = undefined;
            const val = self.viewValue(@intCast(r), &val_buf) catch "";
            ui_paint.showText(c, @floatFromInt(gs_x + 240), @floatFromInt(ry + 20), val, 13, 500, t.text_r, t.text_g, t.text_b, 1.0);
            paintStepperIcon(c, minus_x, ry + 4, btn_w, btn_h, false, inR(px, py, minus_x, ry + 4, btn_w, btn_h), t);
            paintStepperIcon(c, plus_x, ry + 4, btn_w, btn_h, true, inR(px, py, plus_x, ry + 4, btn_w, btn_h), t);
        }

        // Opacity preview slider (session-only).
        {
            const track_h: i32 = 6;
            const thumb_r: f64 = 10.0;
            const ry = row0 + 4 * row_pitch;
            const track_y = ry + @divTrunc(row_pitch, 2) - @divTrunc(track_h, 2);
            const track_x = gs_x + 240;
            const track_w = gs_w - 64 - 240;
            ui_paint.showText(c, @floatFromInt(gs_x + 32), @floatFromInt(ry + 20), "Window opacity", 13, 500, t.text_r, t.text_g, t.text_b, 1.0);

            ui_paint.roundRect(c, @floatFromInt(track_x), @floatFromInt(track_y), @floatFromInt(track_w), @floatFromInt(track_h), 3.0);
            cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.3);
            cairo_fill(c);

            const fill_w: i32 = @intFromFloat(@as(f64, @floatFromInt(track_w)) * @as(f64, @floatFromInt(self.opacity_pct)) / 100.0);
            if (fill_w > 2) {
                ui_paint.roundRect(c, @floatFromInt(track_x), @floatFromInt(track_y), @floatFromInt(fill_w), @floatFromInt(track_h), 3.0);
                cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.85);
                cairo_fill(c);
            }
            cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 1.0);
            cairo_arc(c, @floatFromInt(track_x + fill_w), @floatFromInt(track_y + @divTrunc(track_h, 2)), thumb_r, 0, 2.0 * std.math.pi);
            cairo_fill(c);

            var pct_buf: [12]u8 = undefined;
            const pct = std.fmt.bufPrint(&pct_buf, "{d}%", .{self.opacity_pct}) catch "";
            ui_paint.showText(c, @floatFromInt(gs_x + gs_w - 32 - 40), @floatFromInt(ry + 20), pct, 13, 500, t.text_r, t.text_g, t.text_b, 1.0);
        }
    }

    /// `viewValue` for stepper cell `vi`: plain number, percent, or pixels.
    fn viewValue(self: *const Page, vi: i32, buf: []u8) ![]const u8 {
        return switch (vi) {
            0 => std.fmt.bufPrint(buf, "{d}", .{self.columns}),
            1 => std.fmt.bufPrint(buf, "{d}", .{self.rows}),
            2 => std.fmt.bufPrint(buf, "{d}%", .{self.scale_pct}),
            else => std.fmt.bufPrint(buf, "{d} px", .{self.radius_px}),
        };
    }

    /// One stepper press, with clamping.
    fn stepView(self: *Page, vi: i32, dir: i32) void {
        switch (vi) {
            0 => self.columns = std.math.clamp(self.columns + dir, 1, 10),
            1 => self.rows = std.math.clamp(self.rows + dir, 1, 10),
            2 => self.scale_pct = std.math.clamp(self.scale_pct + dir * 5, 50, 200),
            else => self.radius_px = std.math.clamp(self.radius_px + dir, 0, 32),
        }
    }

    // ------------------------------------------------------------------ hit --

    /// `settings_wallpaper_consume_pointer_down` in layout space. Returns
    /// what the window must do; session state has already moved.
    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        if (!self.inited) return null;
        const m = metrics(@floatFromInt(g.content_x), @floatFromInt(g.content_w), self.view_open);
        const card_inset_x = g.content_x + 8;
        const gr = self.grid(card_inset_x, g.content_w, m.gallery_grid_top);
        self.clampPage(gr.per_page);

        // The open mode list eats every press while it is up.
        // handles it before the tab's own handler).
        if (self.sub_tab == 0 and self.mode_drop_open) {
            const dd_y = m.tool_combo_y + m.tool_combo_h + 2;
            const lh = 5 * k_dd_row_h;
            self.mode_drop_open = false;
            if (inR(px, ly, m.tool_combo_x, dd_y, m.tool_combo_w, lh)) {
                const rr: i32 = @divTrunc(@as(i32, @intFromFloat(ly)) - dd_y, k_dd_row_h);
                if (rr >= 0 and rr <= 4) return .{ .set_mode = rr };
            }
            return .repaint;
        }

        // Sub-tab underline.
        {
            const st_x: i32 = g.content_x + k_card_pad;
            const st_y = m.sub_tab_y;
            const st_h: i32 = 48;
            if (inR(px, ly, st_x + 16, st_y, 100, st_h)) {
                self.sub_tab = 0;
                return .repaint;
            }
            if (inR(px, ly, st_x + 100 + 24 + 16, st_y, 160, st_h)) {
                self.sub_tab = 1;
                return .repaint;
            }
        }

        // Wallpaper enabled switch.
        {
            const wg_w: i32 = 52;
            const wg_h: i32 = 26;
            const wg_x = card_inset_x + (g.content_w - 16) - wg_w - k_spacing_xl;
            const wg_y = k_content_top + @divTrunc(k_wallpaper_toggle_band_h - wg_h, 2);
            if (inR(px, ly, wg_x, wg_y, wg_w, wg_h)) return .toggle_enabled;
        }

        if (self.sub_tab == 1) {
            const gs_x: i32 = g.content_x + k_card_pad;
            const gs_w: i32 = @min(640, g.content_w - 2 * k_card_pad);
            const gs_y: i32 = m.sub_tab_y + 60;
            const gal_picker_y = gs_y + 88;
            if (inR(px, ly, gs_x + 32, gal_picker_y, gs_w - 64, 28)) {
                self.picker_modal_open = true;
                return .repaint;
            }
            const row0 = gal_picker_y + 28 + 20;
            const row_pitch: i32 = 48;
            const btn_w: i32 = 36;
            const btn_h: i32 = 28;
            const minus_x = gs_x + gs_w - 32 - 2 * btn_w - 10;
            const plus_x = gs_x + gs_w - 32 - btn_w;
            for (0..4) |r| {
                const ry = row0 + @as(i32, @intCast(r)) * row_pitch;
                if (inR(px, ly, minus_x, ry + 4, btn_w, btn_h)) {
                    self.stepView(@intCast(r), -1);
                    return .repaint;
                }
                if (inR(px, ly, plus_x, ry + 4, btn_w, btn_h)) {
                    self.stepView(@intCast(r), 1);
                    return .repaint;
                }
            }
            // Opacity slider drag start (`app.sliderDrag = 220` there).
            {
                const track_h: i32 = 6;
                const ry = row0 + 4 * row_pitch;
                const track_y = ry + @divTrunc(row_pitch, 2) - @divTrunc(track_h, 2);
                const track_x = gs_x + 240;
                const track_w = gs_w - 64 - 240;
                const hit_pad = 16;
                if (inR(px, ly, track_x - hit_pad, track_y - hit_pad, track_w + 2 * hit_pad, track_h + 2 * hit_pad)) {
                    self.dragging_opacity = true;
                    self.setOpacityFromX(px, track_x, track_w);
                    return .repaint;
                }
            }
            return .repaint;
        }

        // Toolbar chevrons step through the gallery.
        if (inR(px, ly, m.tool_prev_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s)) return .{ .cycle = -1 };
        if (inR(px, ly, m.tool_next_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s)) return .{ .cycle = 1 };

        // Fill-mode combo: open the list.
        if (inR(px, ly, m.tool_combo_x, m.tool_combo_y, m.tool_combo_w, m.tool_combo_h)) {
            self.mode_drop_open = true;
            return .repaint;
        }

        // Toolbar tune / folder / delete.
        if (inR(px, ly, m.tool_tune_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s)) {
            self.view_open = !self.view_open;
            return .repaint;
        }
        if (inR(px, ly, m.tool_folder_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s)) return .pick_folder;
        if (inR(px, ly, m.tool_delete_x, m.tool_icon_y, k_tool_btn_s, k_tool_btn_s)) return .clear_image;

        // Open Picker… opens the folder-dialog chooser.
        if (inR(px, ly, @as(i32, @intFromFloat(m.hero_x)), m.picker_y, m.hero_w, k_picker_h)) {
            self.picker_modal_open = true;
            return .repaint;
        }

        // Gallery toolbar: view-options toggle.
        if (inR(px, ly, m.gallery_tune_x, m.sort_pills_y, 40, 28)) {
            self.view_open = !self.view_open;
            return .repaint;
        }

        // View-options panel: the "All settings" link and the steppers.
        if (self.view_open) {
            const link_x = @as(i32, @intFromFloat(m.hero_x)) + m.hero_w - 20 - 118;
            if (inR(px, ly, link_x, m.view_panel_y + 8, 118, 26)) {
                self.sub_tab = 1;
                return .repaint;
            }
            for (0..4) |vi| {
                const cell = viewCell(&m, @intCast(vi));
                if (inR(px, ly, cell.minus_x, cell.btn_y, 44, 32)) {
                    self.stepView(@intCast(vi), -1);
                    return .repaint;
                }
                if (inR(px, ly, cell.plus_x, cell.btn_y, 44, 32)) {
                    self.stepView(@intCast(vi), 1);
                    return .repaint;
                }
            }
        }

        // Sort pills.
        {
            var px_i = m.sort_pills_x;
            for (sort_pill_w, 0..) |w, pi| {
                if (inR(px, ly, px_i, m.sort_pills_y, w, 28)) {
                    const pi32: i32 = @intCast(pi);
                    if (self.sort_mode != pi32) {
                        self.sort_mode = pi32;
                        scan.sortEntries(self.gallery.entries.items, self.sort_mode);
                        self.sort_applied = self.sort_mode;
                        self.page_idx = 0;
                    }
                    return .repaint;
                }
                px_i += w + 8;
            }
        }

        // Thumbnail selection.
        {
            const gx0 = @as(f64, @floatFromInt(card_inset_x + k_card_pad));
            const gall_off: usize = @as(usize, @intCast(@max(0, self.page_idx))) * gr.per_page;
            const n_total: usize = self.gallery.entries.items.len;
            const row_stride = gr.thumb_h + k_thumb_label_h + 6;
            var ii: usize = 0;
            while (ii < gr.per_page) : (ii += 1) {
                const gi = gall_off + ii;
                if (gi >= n_total) break;
                const row: i32 = @intCast(ii / @as(usize, @intCast(gr.cols)));
                const col: i32 = @intCast(ii % @as(usize, @intCast(gr.cols)));
                const gx = gx0 + @as(f64, @floatFromInt(col * (gr.thumb + gr.gap)));
                const gy: f64 = @floatFromInt(gr.top + row * row_stride);
                if (inR(px, ly, @intFromFloat(gx), @intFromFloat(gy), gr.thumb, gr.thumb_h)) {
                    return .{ .select_image = gi };
                }
            }
        }

        // Prev/next page.
        if (gr.show_nav) {
            if (inR(px, ly, gr.prev_x, gr.nav_y, nav_w, nav_h)) {
                if (self.page_idx > 0) self.page_idx -= 1;
                return .repaint;
            }
            if (inR(px, ly, gr.next_x, gr.nav_y, nav_w, nav_h)) {
                if (self.page_idx + 1 < self.pagesOf(gr.per_page)) self.page_idx += 1;
                return .repaint;
            }
        }

        return null;
    }

    /// Live opacity drag (window routes motion here while armed).
    pub fn dragOpacity(self: *Page, g: Geo, px: f64) void {
        if (!self.dragging_opacity) return;
        const gs_x: i32 = g.content_x + k_card_pad;
        const gs_w: i32 = @min(640, g.content_w - 2 * k_card_pad);
        const track_x = gs_x + 240;
        const track_w = gs_w - 64 - 240;
        self.setOpacityFromX(px, track_x, track_w);
    }

    fn setOpacityFromX(self: *Page, px: f64, track_x: i32, track_w: i32) void {
        if (track_w <= 0) return;
        const nt = (px - @as(f64, @floatFromInt(track_x))) /
            @as(f64, @floatFromInt(track_w));
        self.opacity_pct = @intFromFloat(@round(@min(1.0, @max(0.0, nt)) * 100.0));
        self.opacity_pct = std.math.clamp(self.opacity_pct, 10, 100);
    }
};

/// `wallpaper_folder_picker_modal_geom`: a centred window-space panel listing
/// how the folder button should open. It is a modal, so the window paints and
/// hits it outside the content clip.
pub const PickerModal = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    row_pitch: i32 = 34,
    n: i32 = 4,
};

pub fn pickerModalGeom(win_w: i32, win_h: i32) PickerModal {
    const n: i32 = 4;
    const row_pitch: i32 = 34;
    const w: i32 = 540;
    const h: i32 = 56 + n * row_pitch + 18;
    return .{
        .x = @max(20, @divTrunc(win_w - w, 2)),
        .y = @max(20, @divTrunc(win_h - h, 2)),
        .w = w,
        .h = h,
        .row_pitch = row_pitch,
        .n = n,
    };
}

pub fn paintPickerModal(
    cr: ?*cairo.cairo_t,
    win_w: i32,
    win_h: i32,
    selected: i32,
    px: f64,
    py: f64,
) void {
    const c = cr orelse return;
    const t = common.Theme;
    const g = pickerModalGeom(win_w, win_h);

    ui_paint.glassBox(c, @floatFromInt(g.x), @floatFromInt(g.y), @floatFromInt(g.w), @floatFromInt(g.h), 14, t.bg_r, t.bg_g, t.bg_b, 0.96);
    ui_paint.showText(c, @floatFromInt(g.x + 18), @floatFromInt(g.y + 30), "Wallpaper folder picker", 14, 700, t.text_r, t.text_g, t.text_b, 1.0);
    ui_paint.showText(c, @floatFromInt(g.x + 18), @floatFromInt(g.y + 46), "Choose how the folder button opens; saved with settings.", 11, 400, t.text_r, t.text_g, t.text_b, 1.0);

    const list_y0 = g.y + 56;
    for (picker_labels, 0..) |lab, i| {
        const ry = list_y0 + @as(i32, @intCast(i)) * g.row_pitch;
        const hov = px >= g.x + 10 and px < g.x + g.w - 10 and py >= ry and py < ry + g.row_pitch;
        const sel = std.math.clamp(selected, 0, 3) == @as(i32, @intCast(i));
        if (hov or sel) {
            ui_paint.glassBox(
                c,
                @floatFromInt(g.x + 10),
                @floatFromInt(ry),
                @floatFromInt(g.w - 20),
                @floatFromInt(g.row_pitch),
                6,
                1,
                1,
                1,
                @as(f64, if (hov) 0.08 else 0.0) + @as(f64, if (sel) 0.06 else 0.0),
            );
        }
        ui_paint.showText(c, @floatFromInt(g.x + 18), @floatFromInt(ry + g.row_pitch - 12), lab, 12, if (sel) 700 else 400, t.text_r, t.text_g, t.text_b, 1.0);
    }
}

/// Row index at the point, or null when outside the panel (which dismisses).
pub fn hitPickerModal(win_w: i32, win_h: i32, px: f64, py: f64) ?i32 {
    const g = pickerModalGeom(win_w, win_h);
    if (!common.pointInRect(px, py, .{ .x = g.x, .y = g.y, .w = g.w, .h = g.h })) return null;
    const list_y0 = g.y + 56;
    if (py < list_y0 or py >= list_y0 + g.n * g.row_pitch) return -1;
    const idx: i32 = @intFromFloat(@divTrunc(py - list_y0, @as(f64, @floatFromInt(g.row_pitch))));
    if (idx < 0 or idx >= g.n) return -1;
    return idx;
}

fn inR(px: f64, py: f64, x: i32, y: i32, w: i32, h: i32) bool {
    return common.pointInRect(px, py, .{ .x = x, .y = y, .w = w, .h = h });
}

fn paintUnderline(c: anytype, x: i32, y: i32, w: i32, t: anytype) void {
    ui_paint.roundRect(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), 3, 1.5);
    cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.9);
    cairo_fill(c);
}

/// `m3::Button` — pill radius, accent fill (white label) or a glass backing
/// with an accent label inside an outline stroke.
fn paintBtn(
    c: anytype,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    label: []const u8,
    filled: bool,
    hovered: bool,
    t: anytype,
) void {
    if (w <= 0 or h <= 0) return;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    const rad = @min(wf, hf) * 0.5;
    if (filled) {
        ui_paint.glassBox(c, xf, yf, wf, hf, rad, t.acc_r, t.acc_g, t.acc_b, 1.0);
    } else {
        ui_paint.glassBox(c, xf, yf, wf, hf, rad, 1, 1, 1, if (hovered) 0.12 else 0.06);
        cairo_save(c);
        ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, @max(0.5, rad - 0.5));
        cairo_set_line_width(c, 1.0);
        cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (hovered) 0.9 else 0.6);
        cairo_stroke(c);
        cairo_restore(c);
    }
    const font_px: f32 = if (h >= 44) 14 else 12;
    const ts = ui_paint.textSizePx(c, label, font_px, 500);
    const cx = xf + (wf - @as(f64, @floatFromInt(ts.w))) / 2.0;
    const top = yf + (hf - @as(f64, @floatFromInt(ts.h))) / 2.0;
    ui_paint.showText(
        c,
        cx,
        top + @as(f64, @floatFromInt(ts.h)) - 2.0,
        label,
        font_px,
        500,
        if (filled) 1.0 else t.acc_r,
        if (filled) 1.0 else t.acc_g,
        if (filled) 1.0 else t.acc_b,
        1.0,
    );
}

/// Glyph button sized to a square (the toolbar icons).
fn paintGlyphBtn(c: anytype, x: i32, y: i32, lig: []const u8, filled: bool, hovered: bool, t: anytype) void {
    paintGlyphBtnWide(c, x, y, k_tool_btn_s, k_tool_btn_s, lig, filled, hovered, t);
}

fn paintGlyphBtnWide(
    c: anytype,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    lig: []const u8,
    filled: bool,
    hovered: bool,
    t: anytype,
) void {
    if (w <= 0 or h <= 0) return;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    const rad = @min(wf, hf) * 0.5;
    if (filled) {
        ui_paint.glassBox(c, xf, yf, wf, hf, rad, t.acc_r, t.acc_g, t.acc_b, 1.0);
    } else {
        ui_paint.glassBox(c, xf, yf, wf, hf, rad, 1, 1, 1, if (hovered) 0.14 else 0.06);
        cairo_save(c);
        ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, @max(0.5, rad - 0.5));
        cairo_set_line_width(c, 1.0);
        cairo_set_source_rgba(c, 1, 1, 1, if (hovered) 0.55 else 0.3);
        cairo_stroke(c);
        cairo_restore(c);
    }
    ui_paint.glyph(
        c,
        xf + wf / 2.0,
        yf + hf / 2.0,
        @min(wf, hf) * 0.55,
        lig,
        if (filled) 1.0 else 1.0,
        if (filled) 1.0 else 1.0,
        if (filled) 1.0 else 1.0,
        if (filled) 1.0 else (if (hovered) 0.95 else 0.75),
    );
}

/// Outlined pill stepper (the "−"/"+" pair). The glyph is drawn by the caller
/// only where needed; the view-panel and gallery-settings pairs are
/// identical 36x28 / 44x32 outlined boxes there.
fn paintStepper(c: anytype, x: i32, y: i32, w: i32, h: i32, hovered: bool, t: anytype) void {
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    ui_paint.glassBox(c, xf, yf, wf, hf, hf / 2.0, 1, 1, 1, if (hovered) 0.12 else 0.06);
    cairo_save(c);
    ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, hf / 2.0 - 0.5);
    cairo_set_line_width(c, 1.0);
    cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (hovered) 0.9 else 0.6);
    cairo_stroke(c);
    cairo_restore(c);
}

/// The same stepper with a minus or plus glyph centred inside it.
fn paintStepperIcon(
    c: anytype,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    plus: bool,
    hovered: bool,
    t: anytype,
) void {
    paintStepper(c, x, y, w, h, hovered, t);
    ui_paint.glyph(
        c,
        @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(w)) / 2.0,
        @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(h)) / 2.0,
        @as(f64, @floatFromInt(@min(w, h))) * 0.5,
        if (plus) "add" else "remove",
        1.0,
        1.0,
        1.0,
        if (hovered) 0.95 else 0.75,
    );
}

/// Toolbar mode combo in its closed state (`settings_paint_combo_closed`).
fn paintCombo(
    c: anytype,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    text: []const u8,
    hovered: bool,
    t: anytype,
) void {
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    ui_paint.glassBox(c, xf, yf, wf, hf, 8, 1, 1, 1, if (hovered) 0.14 else 0.06);
    cairo_save(c);
    ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, 7.5);
    cairo_set_line_width(c, 1.0);
    cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (hovered) 0.95 else 0.6);
    cairo_stroke(c);
    cairo_restore(c);
    cairo_save(c);
    cairo_rectangle(c, xf + 8, yf + 2, wf - 30, hf - 4);
    cairo_clip(c);
    ui_paint.showText(c, xf + 12, yf + hf - 8.0, text, 12, 400, t.text_r, t.text_g, t.text_b, 0.92);
    cairo_restore(c);
    ui_paint.glyph(c, xf + wf - 14.0, yf + hf / 2.0, 16, "expand_more", t.text_r, t.text_g, t.text_b, 0.7);
}

/// The open list (`settings_paint_combo_list_popup`).
fn paintComboPopup(
    c: anytype,
    x: i32,
    y: i32,
    w: i32,
    selected: i32,
    hover_row: i32,
    t: anytype,
) void {
    const row_h = k_dd_row_h;
    const list_h = @as(i32, @intCast(mode_labels.len)) * row_h;
    ui_paint.glassBox(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(list_h), 8, t.bg_r, t.bg_g, t.bg_b, 1.0);
    cairo_save(c);
    ui_paint.roundRect(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(list_h), 8.0);
    cairo_set_source_rgba(c, 1, 1, 1, 0.28);
    cairo_set_line_width(c, 1.0);
    cairo_stroke(c);
    cairo_restore(c);

    cairo_save(c);
    cairo_rectangle(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(list_h));
    cairo_clip(c);
    for (mode_labels, 0..) |lab, i| {
        const i32x: i32 = @intCast(i);
        const ry = y + i32x * row_h;
        if (i32x == hover_row) {
            cairo_rectangle(c, @floatFromInt(x + 1), @floatFromInt(ry + 1), @floatFromInt(w - 2), @floatFromInt(row_h - 2));
            cairo_set_source_rgba(c, 1, 1, 1, 0.16);
            cairo_fill(c);
        }
        const sel = i32x == selected;
        const text_a: f64 = if (sel) 1.0 else if (i32x == hover_row) 0.92 else 0.82;
        ui_paint.showText(c, @floatFromInt(x + 12), @floatFromInt(ry + 19), lab, 12, if (sel) 700 else 400, t.text_r, t.text_g, t.text_b, text_a);
    }
    cairo_restore(c);
}

/// `settings_mode_dd_pointer_row` — the row under the pointer, or -1.
fn ddHoverRow(px: f64, py: f64, x: i32, y: i32, w: i32) i32 {
    if (!inR(px, py, x, y, w, 5 * k_dd_row_h)) return -1;
    const rr: i32 = @divTrunc(@as(i32, @intFromFloat(py)) - y, k_dd_row_h);
    if (rr < 0 or rr >= @as(i32, @intCast(mode_labels.len))) return -1;
    return rr;
}

/// `settings_switch`: pill track with a sliding knob.
fn paintSwitch(c: anytype, x: i32, y: i32, w: i32, h: i32, on: bool) void {
    const t = common.Theme;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    if (on) {
        ui_paint.glassBox(c, xf, yf, wf, hf, hf / 2.0, t.acc_r, t.acc_g, t.acc_b, 1.0);
    } else {
        ui_paint.glassBox(c, xf, yf, wf, hf, hf / 2.0, 1, 1, 1, 0.06);
        cairo_save(c);
        ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, hf / 2.0 - 0.5);
        cairo_set_line_width(c, 1.4);
        cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.8);
        cairo_stroke(c);
        cairo_restore(c);
    }
    const knob_r: f64 = if (on) hf * 0.375 else hf / 3.0;
    const kx = if (on) xf + wf - hf * 0.5 else xf + hf * 0.5;
    cairo_set_source_rgba(c, 1, 1, 1, if (on) 1.0 else 0.75);
    cairo_arc(c, kx, yf + hf / 2.0, knob_r, 0, std.math.pi * 2.0);
    cairo_fill(c);
}

/// `wallpaper_truncate_visual`: cut to `max_c` characters, with an ellipsis
/// in the middle when it had to cut.
fn truncateVisual(buf: []u8, s: []const u8, max_c: usize) []const u8 {
    if (s.len <= max_c) return s;
    if (max_c < 12) return s[0..max_c];
    if (buf.len < max_c + 4) return s[0..@min(s.len, max_c)];
    const head = max_c / 2 - 2;
    const tail = max_c - head - 3;
    @memcpy(buf[0..head], s[0..head]);
    buf[head] = 0xE2;
    buf[head + 1] = 0x80;
    buf[head + 2] = 0xA6; // U+2026
    @memcpy(buf[head + 3 .. head + 3 + tail], s[s.len - tail ..]);
    return buf[0 .. head + 3 + tail];
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const s: u64 = @intCast(@max(ts.sec, 0));
    const n: u64 = @intCast(@max(ts.nsec, 0));
    return s * std.time.ns_per_s + n;
}

// Cairo aliases, same shape as `ui_content`'s.
const cairo_save = cairo.cairo_save;
const cairo_restore = cairo.cairo_restore;
const cairo_rectangle = cairo.cairo_rectangle;
const cairo_clip = cairo.cairo_clip;
const cairo_translate = cairo.cairo_translate;
const cairo_scale = cairo.cairo_scale;
const cairo_set_source_rgba = cairo.cairo_set_source_rgba;
const cairo_set_source = cairo.cairo_set_source;
const cairo_set_source_surface = cairo.cairo_set_source_surface;
const cairo_set_line_width = cairo.cairo_set_line_width;
const cairo_move_to = cairo.cairo_move_to;
const cairo_line_to = cairo.cairo_line_to;
const cairo_stroke = cairo.cairo_stroke;
const cairo_fill = cairo.cairo_fill;
const cairo_paint = cairo.cairo_paint;
const cairo_arc = cairo.cairo_arc;
const cairo_surface_flush = cairo.cairo_surface_flush;
const cairo_image_surface_get_width = cairo.cairo_image_surface_get_width;
const cairo_image_surface_get_height = cairo.cairo_image_surface_get_height;
const cairo_pattern_create_linear = cairo.cairo_pattern_create_linear;
const cairo_pattern_add_color_stop_rgba = cairo.cairo_pattern_add_color_stop_rgba;
const cairo_pattern_destroy = cairo.cairo_pattern_destroy;
const CAIRO_OPERATOR_OVER = cairo.CAIRO_OPERATOR_OVER;
const cairo_set_operator = cairo.cairo_set_operator;

test "wallpaper-tab: metrics match the specified vertical rhythm" {
    const t = std.testing;
    // contentX 292, contentW 592 (900 - 292 - 16).
    const m = metrics(292.0, 592.0, false);
    try t.expectEqual(@as(i32, 144), m.sub_tab_y); // kContentTop + 96
    try t.expectEqual(@as(f64, 308.0), m.hero_x); // contentX + kCardPad
    try t.expectEqual(@as(i32, 196), m.hero_y); // subTabY + 52
    try t.expectEqual(@as(i32, 560), m.hero_w); // contentW - 2*kCardPad
    try t.expectEqual(@as(i32, 300), m.hero_h);
    // Toolbar: 12 inset, 12 above the hero bottom.
    try t.expectEqual(@as(i32, 320), m.tool_bar_x);
    try t.expectEqual(@as(i32, 196 + 300 - 12 - 56), m.tool_bar_y);
    try t.expectEqual(@as(i32, 560 - 24), m.tool_bar_w);
    try t.expectEqual(@as(i32, m.tool_bar_y + 8), m.tool_icon_y); // (56-40)/2
    // Combo sits 8 left of the tune button.
    try t.expectEqual(@as(i32, m.tool_tune_x - 8 - 128), m.tool_combo_x);
    // Picker under the hero, gallery row 16 below that.
    try t.expectEqual(@as(i32, 196 + 300 + 12), m.picker_y);
    try t.expectEqual(@as(i32, m.picker_y + 48 + 16), m.gallery_toolbar_y);
    try t.expectEqual(@as(i32, m.gallery_toolbar_y + 2), m.sort_pills_y);
    // Right-aligned pill block: 72+8+88+8+88+8+40 = 312.
    try t.expectEqual(@as(i32, 308 + 560 - 312), m.sort_pills_x);
    try t.expectEqual(@as(i32, m.sort_pills_x + 72 + 8 + 88 + 8 + 88 + 8), m.gallery_tune_x);
    try t.expectEqual(@as(i32, m.gallery_toolbar_y + 32 + 12), m.view_panel_y);
    try t.expectEqual(@as(i32, 0), m.view_panel_h);
    // Closed panel: grid starts 12 below the row.
    try t.expectEqual(@as(i32, m.view_panel_y + 12), m.gallery_grid_top);

    const mo = metrics(292.0, 592.0, true);
    try t.expectEqual(@as(i32, 148), mo.view_panel_h);
    try t.expectEqual(@as(i32, mo.view_panel_y + 148 + 12), mo.gallery_grid_top);
}

test "wallpaper-tab: grid tiles at the specified size" {
    const t = std.testing;
    var p: Page = .{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();
    p.columns = 4;
    p.rows = 3;
    p.scale_pct = 100;
    // availW = 592 - 8 - 32 = 552; (552 - 18) / 4 = 133.5 -> ceil 134.
    const gr = p.grid(300, 592, 400);
    try t.expectEqual(@as(i32, 4), gr.cols);
    try t.expectEqual(@as(i32, 3), gr.rows);
    try t.expectEqual(@as(i32, 134), gr.thumb);
    try t.expectEqual(@as(i32, (134 * 9 + 8) / 16), gr.thumb_h);
    try t.expectEqual(@as(usize, 12), gr.per_page);
    try t.expectEqual(@as(i32, 400 + 3 * (gr.thumb_h + 6) + 14), gr.nav_y);
    try t.expectEqual(@as(i32, 300 + 16), gr.prev_x);
    try t.expectEqual(@as(i32, 300 + 592 - 16 - 80), gr.next_x);
    // An empty gallery never shows the pager.
    try t.expect(!gr.show_nav);
}

test "wallpaper-tab: view steppers clamp at the specified limits" {
    const t = std.testing;
    var p: Page = .{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();
    p.columns = 1;
    p.rows = 1;
    p.scale_pct = 50;
    p.radius_px = 0;
    p.stepView(0, -1);
    try t.expectEqual(@as(i32, 1), p.columns);
    p.stepView(0, 1);
    try t.expectEqual(@as(i32, 2), p.columns);
    p.columns = 10;
    p.stepView(0, 1);
    try t.expectEqual(@as(i32, 10), p.columns);
    p.stepView(1, 1);
    try t.expectEqual(@as(i32, 2), p.rows);
    p.stepView(2, -1);
    try t.expectEqual(@as(i32, 50), p.scale_pct);
    p.scale_pct = 200;
    p.stepView(2, 1);
    try t.expectEqual(@as(i32, 200), p.scale_pct);
    p.stepView(3, -1);
    try t.expectEqual(@as(i32, 0), p.radius_px);
    p.radius_px = 32;
    p.stepView(3, 1);
    try t.expectEqual(@as(i32, 32), p.radius_px);
}

test "wallpaper-tab: paging clamps to the last page" {
    const t = std.testing;
    var p: Page = .{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();
    p.columns = 4;
    p.rows = 3; // 12 per page
    p.page_idx = 9;
    p.clampPage(12);
    try t.expectEqual(@as(i32, 0), p.page_idx); // empty gallery -> page 0
    try t.expectEqual(@as(i32, 1), p.pagesOf(12));
}

test "wallpaper-tab: a new file merges without dropping cached thumbs" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try cwd.createDirPath(io, root);

    const a_path = try std.fs.path.join(alloc, &.{ root, "a.png" });
    defer alloc.free(a_path);
    const b_path = try std.fs.path.join(alloc, &.{ root, "b.png" });
    defer alloc.free(b_path);
    try cwd.writeFile(io, .{ .sub_path = a_path, .data = "x" });
    try cwd.writeFile(io, .{ .sub_path = b_path, .data = "y" });

    var p: Page = .{};
    p.init(alloc, io);
    defer p.deinit();
    p.snap.folder = root;
    p.ensureGallery();
    try t.expectEqual(@as(usize, 2), p.gallery.entries.items.len);

    // Stand in for decoded thumbnails: the merge must keep these keys, which
    // is what keeps the grid painted while a download lands.
    for (p.gallery.entries.items) |e| {
        const k = try alloc.dupe(u8, e.path);
        errdefer alloc.free(k);
        try p.cache.put(k, .{ .ok = true, .stamp = 1 });
    }
    try t.expect(p.cache.count() == 2);

    // A download lands: one arrival, no departures, cache untouched.
    const c_path = try std.fs.path.join(alloc, &.{ root, "c.png" });
    defer alloc.free(c_path);
    try cwd.writeFile(io, .{ .sub_path = c_path, .data = "z" });
    const key = try scan.folderKey(alloc, root);
    defer alloc.free(key);
    p.syncIncremental(key);

    try t.expectEqual(@as(usize, 3), p.gallery.entries.items.len);
    try t.expect(p.cache.count() == 2);

    // The source file goes away: gallery and cache both let go of it, and
    // only it.
    try cwd.deleteFile(io, a_path);
    p.syncIncremental(key);
    try t.expectEqual(@as(usize, 2), p.gallery.entries.items.len);
    try t.expect(p.cache.count() == 1);
    var found_b = false;
    var found_a = false;
    var it = p.cache.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, std.fs.path.basename(e.key_ptr.*), "b.png")) found_b = true;
        if (std.mem.eql(u8, std.fs.path.basename(e.key_ptr.*), "a.png")) found_a = true;
    }
    try t.expect(found_b);
    try t.expect(!found_a);
}

test "wallpaper-tab: a failed decode retries on an exponential backoff" {
    const t = std.testing;
    const alloc = t.allocator;
    var p: Page = .{};
    p.init(alloc, std.testing.io);
    defer p.deinit();

    // 0.5s, 1s, 2s, 4s, then the 8s cap.
    try t.expectEqual(retry_base_ns, retryDelayNs(0));
    try t.expectEqual(retry_base_ns * 2, retryDelayNs(1));
    try t.expectEqual(retry_base_ns * 4, retryDelayNs(2));
    try t.expectEqual(retry_max_ns, retryDelayNs(4));
    try t.expectEqual(retry_max_ns, retryDelayNs(255));

    const path = "/nonexistent-wallpaper-retry.png";
    var r = thumbs.Result{ .path = try alloc.dupe(u8, path), .ok = false };
    p.cachePut(&r);
    try t.expectEqual(@as(usize, 0), r.path.len); // cachePut took ownership
    const e = p.cache.getPtr(path).?;
    try t.expect(!e.ok);
    try t.expectEqual(@as(u8, 0), e.retries);
    try t.expect(e.retry_at_ns > 0);

    // Before the backoff elapses the tombstone is left alone: a tile that
    // fails to decode must not be re-decoded every frame.
    p.requestOrRetry(path, 64);
    try t.expectEqual(@as(usize, 0), p.svc.requested.count());

    // Once due, the source is forgotten and queued again.
    p.cache.getPtr(path).?.retry_at_ns = 0;
    p.requestOrRetry(path, 64);
    try t.expectEqual(@as(u8, 1), p.cache.getPtr(path).?.retries);
    try t.expectEqual(@as(usize, 1), p.svc.requested.count());

    // A second failure keeps the count (backoff grows) instead of restarting.
    var r2 = thumbs.Result{ .path = try alloc.dupe(u8, path), .ok = false };
    p.cachePut(&r2);
    const e2 = p.cache.getPtr(path).?;
    try t.expectEqual(@as(u8, 1), e2.retries);
    try t.expect(e2.retry_at_ns > nowNs());

    // A decoded entry is never retried.
    const ok_path = "/nonexistent-wallpaper-ok.png";
    var rok = thumbs.Result{ .path = try alloc.dupe(u8, ok_path), .ok = true };
    p.cachePut(&rok);
    try t.expectEqual(@as(u64, 0), p.cache.getPtr(ok_path).?.retry_at_ns);
    p.requestOrRetry(ok_path, 64);
    try t.expectEqual(@as(u8, 1), p.svc.requested.count()); // unchanged
}

test "wallpaper-tab: picker modal geometry matches the specified layout" {
    const t = std.testing;
    const g = pickerModalGeom(900, 980);
    try t.expectEqual(@as(i32, 540), g.w);
    try t.expectEqual(@as(i32, 56 + 4 * 34 + 18), g.h);
    try t.expectEqual(@as(i32, @divTrunc(900 - 540, 2)), g.x);
    try t.expectEqual(@as(i32, @divTrunc(980 - g.h, 2)), g.y);
    try t.expectEqual(@as(?i32, 0), hitPickerModal(900, 980, g.x + 20, g.y + 56 + 4));
    try t.expectEqual(@as(?i32, 2), hitPickerModal(900, 980, g.x + 20, g.y + 56 + 2 * 34 + 4));
    // Inside the panel but not on a row (header) dismisses without a pick.
    try t.expectEqual(@as(?i32, -1), hitPickerModal(900, 980, g.x + 20, g.y + 4)); // header
    try t.expect(hitPickerModal(10, 10, 4, 4) == null); // outside the clamped panel
}

test "wallpaper-tab: truncation cuts in the middle with an ellipsis" {
    const t = std.testing;
    var buf: [80]u8 = undefined;
    try t.expectEqualStrings("short.png", truncateVisual(&buf, "short.png", 20));
    const out = truncateVisual(&buf, "abcdefghijklmnopqrstuvwxyz.png", 20);
    try t.expect(out.len <= 20);
    try t.expect(std.mem.indexOf(u8, out, "\xE2\x80\xA6") != null);
    // max_c 16 -> head 6 chars, ellipsis, tail 7 chars.
    try t.expectEqualStrings("abcdef…xyz.png", truncateVisual(&buf, "abcdefghijklmnopqrstuvwxyz.png", 16));
}

test "wallpaper-tab: mode labels are the specified set" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 5), mode_labels.len);
    try t.expectEqualStrings("Stretch", mode_labels[2]);
    try t.expectEqualStrings("Tile", mode_labels[4]);
    try t.expectEqualStrings("GTK — zenity", picker_labels[3]);
}

test "wallpaper-tab: hover pop rises to the peak then settles back to 1.0" {
    const t = std.testing;
    var hp = HoverPop{};
    try t.expect(!hp.running());
    // Leaving a tile that was never entered is a no-op, not a stray tween.
    hp.beginLeave();
    try t.expect(!hp.running());

    hp.beginEnter();
    try t.expect(hp.running());
    try t.expectEqual(@as(f64, 1.0), hp.scale);

    // Age the rise past its deadline. The chain must hand off to the settle
    // instead of parking at the 1.10 peak.
    // `onComplete` calls straight back into `animate`).
    hp.start_ns = nowNs() -% (HoverPop.rise_ns + 1);
    try t.expect(hp.step());
    try t.expect(hp.running());
    try t.expectApproxEqAbs(HoverPop.peak, hp.scale, 1e-9);
    try t.expectEqual(HoverPop.settle_ns, hp.dur_ns);

    // Age the settle: it lands on exactly 1.0 and goes idle, so the window's
    // tick timer is released.
    hp.start_ns = nowNs() -% (HoverPop.settle_ns + 1);
    try t.expect(!hp.step());
    try t.expectEqual(@as(f64, 1.0), hp.scale);
    try t.expect(!hp.running());

    // A mid-pop cancel (tab switch) drops straight to the base and releases
    // the timer without waiting out the tween.
    hp.beginEnter();
    hp.cancel();
    try t.expectEqual(@as(f64, 1.0), hp.scale);
    try t.expect(!hp.running());
    try t.expect(!hp.step());
}
