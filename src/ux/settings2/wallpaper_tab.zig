const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const scan = @import("wallpaper_scan.zig");
const browser = @import("wallpaper_browser.zig");
const thumbs = @import("wallpaper_thumbs.zig");
const icon_cache = @import("../../desktop_shell/common/icon_cache.zig");

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

const k_content_top: i32 = common.content_top; // 48
const k_spacing_xl: i32 = common.spacing_xl; // 24
const k_card_pad: i32 = common.card_pad; // 16

// Page geometry (the "Wallpaper Settings Redesign" mock, adapted to the
// content column): the card interior is a single column, top to bottom:
//
//   header row  — title + subtitle, enable switch centred on it
//   tabs row    — Wallpaper | Gallery settings, hairline rule
//   current card— 16:9 thumb + info column (name, counter, Fit, buttons)
//   view panel  — optional Adjust panel
//   library     — header row + segmented sort control, then the tile grid
const k_page_pad: i32 = 20; // inset of the page column inside the outer card
const k_hdr_gap_tabs: i32 = 24; // header row to tabs row
const k_tabs_h: i32 = 48; // tab row height (text pad 12, rule at the bottom)
const k_sec_gap: i32 = 24; // between stacked sections (mock `gap: 24`)
const k_title_lh: i32 = 30; // nominal 22px/600 line box
const k_sub_lh: i32 = 18; // nominal 13px line box
const k_name_lh: i32 = 22; // nominal 16px/600 line box
const k_lib_lh: i32 = 22; // "Library" 16px/600
const k_cur_pad: i32 = 20; // current-card padding
const k_thumb_w: i32 = 400; // current-card thumb target width (16:9)
const k_fit_w: i32 = 150;
const k_fit_h: i32 = 36;
const k_btn_h: i32 = 36; // action buttons row (mock .btn height)
const k_btn_gap: i32 = 8;
const k_btn_pad_x: i32 = 16;
const k_seg_h: i32 = 36; // segmented control outer (3+30+3)
const k_seg_pad: i32 = 3;
const k_seg_btn_h: i32 = 30;
const k_seg_btn_pad_x: i32 = 14;
const k_view_panel_h: i32 = 148;
const k_thumb_gap: i32 = 16; // grid gutter, both axes (mock 16)
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
    /// The custom folder browser confirmed the current directory; the
    /// window reads `Page.fb_cwd` (it holds the fronting Page instance).
    use_folder,
    /// The browser confirmed a picked image by index into `fb_imgs`; the
    /// window takes `Page.fb_imgs.items[idx].full`.
    use_image: usize,
};

/// Content-column geometry, passed in rather than read from `Content` so this
/// module stays free of a cycle back into `ui_content`.
pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

pub const Metrics = struct {
    /// Tabs row top. The Gallery settings blocks anchor off it.
    sub_tab_y: i32,
    /// Page column inside the outer card.
    pg_x: i32,
    pg_w: i32,
    // Header: enable switch centred on the title block.
    toggle_x: i32,
    toggle_y: i32,
    // Current-wallpaper card and its 16:9 thumb.
    cur_x: i32,
    cur_y: i32,
    cur_h: i32,
    thumb_x: i32,
    thumb_y: i32,
    thumb_w: i32,
    thumb_h: i32,
    /// Info column: the Fit combo and the action buttons row.
    info_x: i32,
    fit_x: i32,
    fit_y: i32,
    fit_w: i32 = k_fit_w,
    fit_h: i32 = k_fit_h,
    btns_y: i32,
    choose_w: i32,
    prev_w: i32,
    next_w: i32,
    adj_w: i32,
    // View panel (Adjust).
    view_panel_y: i32,
    view_panel_h: i32,
    // Library header + segmented sort control.
    lib_y: i32,
    lib_h: i32,
    seg_x: i32,
    seg_y: i32,
    seg_w: i32,
    seg_name_w: i32,
    seg_oldest_w: i32,
    seg_newest_w: i32,
    gallery_grid_top: i32,
};

/// Width of a text button measured without a paint context — `metrics()` is
/// also called from `hit` and `totalHeight`, where no cr exists.
fn textBtnW(label: []const u8, size: f32) i32 {
    return ui_paint.measureTextWidth(label, size, 500) + 2 * k_btn_pad_x;
}

/// `wallpaper_vertical_metrics` — the whole Wallpaper tab stacked in one
/// place so paint, hit-test and scroll height cannot disagree.
pub fn metrics(content_x: f64, content_w: f64, view_open: bool) Metrics {
    var m: Metrics = undefined;
    const cx: i32 = @intFromFloat(content_x);
    const cw: i32 = @intFromFloat(content_w);
    m.pg_x = cx + k_page_pad;
    m.pg_w = cw - 2 * k_page_pad;

    // Header row: title + subtitle stack, the toggle centred on it.
    const hdr_top = k_content_top + k_page_pad;
    const hdr_h = k_title_lh + 2 + k_sub_lh; // 50
    m.sub_tab_y = hdr_top + hdr_h + k_hdr_gap_tabs;
    m.toggle_x = m.pg_x + m.pg_w - k_toggle_w;
    m.toggle_y = hdr_top + @divTrunc(hdr_h - k_toggle_h, 2);

    // Current-wallpaper card: 16:9 thumb left, info column right.
    m.cur_x = m.pg_x;
    m.cur_y = m.sub_tab_y + k_tabs_h + k_sec_gap;
    const inner_w = m.pg_w - 2 * k_cur_pad;
    // Button row width decides the worst case; the thumb shrinks before the
    // info column ever starves (mock: 400px, `max-width:100%`).
    m.choose_w = textBtnW("Choose Wallpaper", k_btn_font);
    m.prev_w = textBtnW("Previous", k_btn_font);
    m.next_w = textBtnW("Next", k_btn_font);
    m.adj_w = textBtnW("Adjust", k_btn_font);
    const row_w = m.choose_w + m.prev_w + m.next_w + m.adj_w + 3 * k_btn_gap;
    m.thumb_w = std.math.clamp(inner_w - row_w - 24, 180, k_thumb_w);
    m.thumb_h = @divTrunc(m.thumb_w * 9 + 8, 16);
    m.thumb_x = m.cur_x + k_cur_pad;
    m.thumb_y = m.cur_y + k_cur_pad;
    m.cur_h = m.thumb_h + 2 * k_cur_pad;
    m.info_x = m.thumb_x + m.thumb_w + 24;

    // Fit stack: name, counter, 20px gap, label, 6px gap, combo.
    m.fit_x = m.info_x;
    m.fit_w = k_fit_w;
    m.fit_h = k_fit_h;
    m.fit_y = m.thumb_y + k_name_lh + 4 + k_sub_lh + 20 + k_sub_lh + 6;
    // The action row is pinned to the card's bottom edge (mock margin-top:auto).
    m.btns_y = m.cur_y + m.cur_h - k_cur_pad - k_btn_h;

    m.view_panel_h = if (view_open) k_view_panel_h else 0;
    m.view_panel_y = m.cur_y + m.cur_h + 12;
    m.lib_y = if (view_open) m.view_panel_y + k_view_panel_h + 16 else m.cur_y + m.cur_h + k_sec_gap;
    m.lib_h = k_lib_lh + 2 + k_sub_lh; // 42

    // Segmented sort control (right-aligned, centred on the Library head).
    m.seg_name_w = textBtnW("Name", k_seg_font);
    m.seg_oldest_w = textBtnW("Oldest", k_seg_font);
    m.seg_newest_w = textBtnW("Newest", k_seg_font);
    m.seg_w = m.seg_name_w + m.seg_oldest_w + m.seg_newest_w + 2 * k_seg_pad;
    m.seg_x = m.pg_x + m.pg_w - m.seg_w;
    m.seg_y = m.lib_y + @divTrunc(m.lib_h - k_seg_h, 2);

    m.gallery_grid_top = m.lib_y + m.lib_h + 16;
    return m;
}

/// One view-panel stepper cell — `wallpaper_view_cell_geom`, shared by the
/// paint and the hit test so they cannot disagree.
pub const ViewCell = struct { x: i32, minus_x: i32, plus_x: i32, btn_y: i32 };

pub fn viewCell(m: *const Metrics, idx: i32) ViewCell {
    const cell_w = @divTrunc(m.pg_w - 3 * 12, 4);
    const cx = m.pg_x + idx * (cell_w + 12);
    return .{ .x = cx, .minus_x = cx, .plus_x = cx + cell_w - 44, .btn_y = m.view_panel_y + 96 };
}

/// One segmented-control button's rect. Lefts are cumulative widths, so
/// paint and hit can never disagree.
fn segBtn(m: *const Metrics, pi: i32) common.Rect {
    const ws = [3]i32{ m.seg_name_w, m.seg_oldest_w, m.seg_newest_w };
    var left: i32 = 0;
    for (0..@intCast(pi)) |i| left += ws[i];
    return .{
        .x = m.seg_x + k_seg_pad + left,
        .y = m.seg_y + k_seg_pad,
        .w = ws[@intCast(pi)],
        .h = k_seg_btn_h,
    };
}

/// Header toggle (mock `.tg`): 44x26.
const k_toggle_w: i32 = 44;
const k_toggle_h: i32 = 26;
/// Button fonts — 13px labels, this close to the mock's 14px inheritance.
const k_btn_font: f32 = 13;
const k_seg_font: f32 = 13;
/// Sub-tab labels (mock `.tab`: 15px, 12px vertical padding).
const k_tab_font: f32 = 15;
const k_tab_text_off: i32 = 12;
const k_tab_lh: i32 = 20;
const k_tab_gap: i32 = 28;

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

    // ------------------------------------------------ custom folder browser
    /// The in-app chooser state: window-space modal driven by
    /// `openFolderBrowser` / `paintFolderBrowser` / `hitFolderBrowser`.
    /// Listing arrays own their strings; the scan worker publishes via
    /// `wallpaper_browser`'s mailbox and `drainFolderScan` adopts.
    fb_open: bool = false,
    fb_cwd: std.ArrayList(u8) = .empty,
    fb_hidden: bool = false,
    fb_scroll: i32 = 0,
    fb_dirs: std.ArrayList(browser.DirEntry) = .empty,
    fb_imgs: std.ArrayList(browser.DirEntry) = .empty,
    fb_err: bool = false,
    fb_loading: bool = false,
    /// The in-flight listing request id; a stale mailbox payload is dropped.
    fb_seq: u32 = 0,
    fb_img_sel: i32 = -1,
    /// Scratch buffer for footer/status strings (`std.fmt.bufPrint` target);
    /// valid only until the next call — `fbFootLabel` consumers draw
    /// immediately.
    fb_stamp_buf: [512]u8 = undefined,
    /// Borrowed system-icon pixels for the browser rail and folder rows,
    /// keyed by icon name (page-owned dups) — the freedesktop icons the
    /// user's theme provides, so the browser reads native.
    fb_icons: std.StringHashMapUnmanaged(icon_cache.Owned) = .empty,

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
        self.fbCloseLists();
        self.fb_cwd.deinit(self.alloc);
        self.fb_cwd = .empty;
        var it = self.fb_icons.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.alloc);
            self.alloc.free(e.key_ptr.*);
        }
        self.fb_icons.deinit(self.alloc);
        self.fb_icons = .empty;
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

        var fresh = std.StringHashMap(i96).init(self.alloc);
        defer fresh.deinit();
        var live = std.StringHashMap(void).init(self.alloc);
        defer live.deinit();

        var maps_ok = true;
        for (tmp.entries.items) |e| {
            fresh.put(e.path, e.mtime_ns) catch {
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

        // Survivors: keep the gallery entry, but a rewritten source (same
        // name, new bytes — a re-download or an editor save) must drop its
        // stale thumbnail and go back through the decode queue.
        var i: usize = 0;
        while (i < self.gallery.entries.items.len) {
            const old_path = self.gallery.entries.items[i].path;
            if (fresh.get(old_path)) |new_mtime| {
                if (new_mtime != self.gallery.entries.items[i].mtime_ns) {
                    self.gallery.entries.items[i].mtime_ns = new_mtime;
                    self.dropCached(old_path);
                    _ = self.svc.request(old_path, cache_px);
                }
                i += 1;
            } else {
                // Departures: out of the gallery and out of the cache.
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
    pub fn grid(self: *const Page, pg_x: i32, pg_w: i32, gallery_top: i32) Grid {
        const cols: i32 = std.math.clamp(self.columns, 1, 10);
        const scale = @as(f64, @floatFromInt(std.math.clamp(self.scale_pct, 50, 200))) / 100.0;
        var tw: i32 = @intFromFloat(@ceil(
            (@as(f64, @floatFromInt(pg_w - k_thumb_gap * (cols - 1))) /
                @as(f64, @floatFromInt(cols))) * scale,
        ));
        tw = @max(40, tw);
        // 16:10 tiles (mock .th aspect-ratio).
        const thumb_h: i32 = @divTrunc(tw * 10 + 15, 16);
        const rows: i32 = std.math.clamp(self.rows, 1, 10);
        const per_page: usize = @as(usize, @intCast(cols)) * @as(usize, @intCast(rows));
        const n: usize = self.gallery.entries.items.len;
        const row_stride_nav = thumb_h + k_thumb_gap;
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
            .prev_x = pg_x,
            .next_x = pg_x + pg_w - nav_w,
        };
    }

    /// `wp_tab_logical_bottom_px` — what the scroll extent is measured to.
    pub fn totalHeight(self: *Page, g: Geo) i32 {
        if (!self.inited) return g.win_h;
        self.ensureGallery();
        const m = metrics(@floatFromInt(g.content_x), @floatFromInt(g.content_w), self.view_open);
        const gr = self.grid(m.pg_x, m.pg_w, m.gallery_grid_top);
        const bottom_px: i32 = if (self.sub_tab == 1)
            m.sub_tab_y + 48 + 88 + 28 + 12 + 5 * 48 + 8 + 24
        else if (gr.show_nav)
            gr.nav_y + nav_h + 20
        else
            gr.top + gr.rows * (gr.thumb_h + k_thumb_gap) + 28;
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
        const gr = self.grid(m.pg_x, m.pg_w, m.gallery_grid_top);
        self.clampPage(gr.per_page);

        // The card surface stretches to the logical content height.
        const bottom_px: i32 = if (self.sub_tab == 1)
            m.sub_tab_y + 48 + 88 + 28 + 12 + 5 * 48 + 8 + 24
        else if (gr.show_nav)
            gr.nav_y + nav_h + 20
        else
            gr.top + gr.rows * (gr.thumb_h + k_thumb_gap) + 28;
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

        // Header row: 22px title over a dim subtitle, enable switch on the
        // right, centred on the title block.
        {
            drawTextTop(c, @floatFromInt(m.pg_x), @floatFromInt(k_content_top + k_page_pad), "Wallpaper", 22, 600, t.text_r, t.text_g, t.text_b, 0.95);
            drawTextTop(c, @floatFromInt(m.pg_x), @floatFromInt(k_content_top + k_page_pad + k_title_lh + 2), "Choose what shows behind your windows.", 13, 400, t.text_r, t.text_g, t.text_b, 0.55);
            paintSwitch(c, m.toggle_x, m.toggle_y, k_toggle_w, k_toggle_h, self.snap.enabled);
        }

        // Tabs row: hairline rule with accent underline under the active tab.
        {
            const st_x: i32 = m.pg_x;
            const st_y = m.sub_tab_y;
            cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.25);
            cairo_set_line_width(c, 1.0);
            const rule_y = @as(f64, @floatFromInt(st_y + k_tabs_h)) - 0.5;
            cairo_move_to(c, @floatFromInt(st_x), rule_y);
            cairo_line_to(c, @floatFromInt(st_x + m.pg_w), rule_y);
            cairo_stroke(c);

            const t0_w = ui_paint.measureTextWidth("Wallpaper", k_tab_font, 500);
            ui_paint.showText(c, @floatFromInt(st_x), @floatFromInt(st_y + k_tab_text_off + k_tab_lh - 2), "Wallpaper", k_tab_font, 500, t.text_r, t.text_g, t.text_b, if (self.sub_tab == 0) 0.95 else 0.5);
            if (self.sub_tab == 0) paintUnderline(c, st_x, st_y + k_tabs_h - 3, t0_w, t);

            const t1_x = st_x + t0_w + k_tab_gap;
            const t1_w = ui_paint.measureTextWidth("Gallery settings", k_tab_font, 500);
            ui_paint.showText(c, @floatFromInt(t1_x), @floatFromInt(st_y + k_tab_text_off + k_tab_lh - 2), "Gallery settings", k_tab_font, 500, t.text_r, t.text_g, t.text_b, if (self.sub_tab == 1) 0.95 else 0.5);
            if (self.sub_tab == 1) paintUnderline(c, t1_x, st_y + k_tabs_h - 3, t1_w, t);
        }

        if (self.sub_tab == 1) {
            self.paintGallerySettings(c, g, &m, px, py);
        } else {
            self.paintWallpaperTab(c, g, &m, &gr, px, py, glass_ov);
        }

        // The Fit list hangs off the current-card combo and scrolls with the
        // page (it is painted in layout space too).
        if (self.sub_tab == 0 and self.mode_drop_open) {
            const dd_y = m.fit_y + m.fit_h + 2;
            self.mode_drop_hover = ddHoverRow(px, py, m.fit_x, dd_y, m.fit_w);
            paintComboPopup(c, m.fit_x, dd_y, m.fit_w, self.snap.mode, self.mode_drop_hover, t);
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
        // The old hero rims were the only consumer; the flat sub-card keeps
        // the outer card's glass scaling.
        _ = glass_ov;
        const t = common.Theme;

        // ---- Current-wallpaper card (mock section.cur) ----
        // Sub-card surface: glassy fill + hairline outline, radius 16.
        ui_paint.glassBox(c, @floatFromInt(m.cur_x), @floatFromInt(m.cur_y), @floatFromInt(m.pg_w), @floatFromInt(m.cur_h), 16, 1, 1, 1, 0.07);
        cairo_save(c);
        ui_paint.roundRect(c, @floatFromInt(m.cur_x), @floatFromInt(m.cur_y), @floatFromInt(m.pg_w), @floatFromInt(m.cur_h), 16.0);
        cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.25);
        cairo_set_line_width(c, 1.0);
        cairo_stroke(c);
        cairo_restore(c);

        // 16:9 thumb, cover-fitted over a dark plate, clip-rounded.
        ui_paint.roundRect(
            c,
            @as(f64, @floatFromInt(m.thumb_x)),
            @as(f64, @floatFromInt(m.thumb_y)),
            @as(f64, @floatFromInt(m.thumb_w)),
            @as(f64, @floatFromInt(m.thumb_h)),
            12.0,
        );
        cairo_set_source_rgba(c, t.bg_r * 0.35, t.bg_g * 0.35, t.bg_b * 0.35, 0.5);
        cairo_fill(c);
        cairo_save(c);
        _ = ui_paint.roundRect(
            c,
            @as(f64, @floatFromInt(m.thumb_x)),
            @as(f64, @floatFromInt(m.thumb_y)),
            @as(f64, @floatFromInt(m.thumb_w)),
            @as(f64, @floatFromInt(m.thumb_h)),
            12.0,
        );
        cairo_clip(c);
        if (self.surfaceFor(self.snap.image)) |surf| {
            cairo_surface_flush(surf);
            const iw = cairo_image_surface_get_width(surf);
            const ih = cairo_image_surface_get_height(surf);
            if (iw > 0 and ih > 0) {
                const wf: f64 = @floatFromInt(m.thumb_w);
                const hf: f64 = @floatFromInt(m.thumb_h);
                const sc = @max(
                    wf / @as(f64, @floatFromInt(iw)),
                    hf / @as(f64, @floatFromInt(ih)),
                );
                const ox = @as(f64, @floatFromInt(m.thumb_x)) + (wf - @as(f64, @floatFromInt(iw)) * sc) * 0.5;
                const oy = @as(f64, @floatFromInt(m.thumb_y)) + (hf - @as(f64, @floatFromInt(ih)) * sc) * 0.5;
                cairo_translate(c, ox, oy);
                cairo_scale(c, sc, sc);
                cairo_set_source_surface(c, surf, 0, 0);
                cairo_paint(c);
            }
        } else {
            ui_paint.glyph(
                c,
                @as(f64, @floatFromInt(m.thumb_x)) + @as(f64, @floatFromInt(m.thumb_w)) / 2.0,
                @as(f64, @floatFromInt(m.thumb_y)) + @as(f64, @floatFromInt(m.thumb_h)) / 2.0,
                40,
                "wallpaper",
                t.text_r,
                t.text_g,
                t.text_b,
                0.25,
            );
        }
        cairo_restore(c);
        // Hairline around the thumb itself.
        cairo_save(c);
        ui_paint.roundRect(
            c,
            @as(f64, @floatFromInt(m.thumb_x)) + 0.5,
            @as(f64, @floatFromInt(m.thumb_y)) + 0.5,
            @as(f64, @floatFromInt(m.thumb_w)) - 1.0,
            @as(f64, @floatFromInt(m.thumb_h)) - 1.0,
            12.0,
        );
        cairo_set_source_rgba(c, 1, 1, 1, 0.12);
        cairo_set_line_width(c, 1.0);
        cairo_stroke(c);
        cairo_restore(c);

        // "In use" chip over the thumb (accent pill, dark 12/600 text).
        if (self.snap.image.len > 0) {
            paintChip(c, @floatFromInt(m.thumb_x + 10), @floatFromInt(m.thumb_y + 10), 12.0, t);
        }

        // Info column: file name + counter, the Fit combo, then the action
        // row pinned to the card's bottom edge.
        {
            const base: []const u8 = if (self.snap.image.len == 0)
                "No wallpaper selected"
            else
                std.fs.path.basename(self.snap.image);
            const name_top: f64 = @floatFromInt(m.thumb_y);
            ui_paint.showTextW(
                c,
                @floatFromInt(m.info_x),
                name_top + @as(f64, @floatFromInt(k_name_lh)) - 2.0,
                base,
                16,
                600,
                @floatFromInt(@max(80, m.pg_x + m.pg_w - k_cur_pad - m.info_x)),
                t.text_r,
                t.text_g,
                t.text_b,
                0.95,
            );

            const cur_idx = if (self.snap.image.len > 0) self.indexOfImage(self.snap.image) else null;
            const n_total: usize = self.gallery.entries.items.len;
            const folder_disp: []const u8 = if (self.snap.folder.len == 0)
                "no folder"
            else
                std.fs.path.basename(self.snap.folder);
            var pos_buf: [160]u8 = undefined;
            const pos: []const u8 = if (cur_idx) |ci|
                std.fmt.bufPrint(&pos_buf, "{d} of {d} in {s}", .{ ci + 1, n_total, folder_disp }) catch ""
            else if (n_total > 0)
                std.fmt.bufPrint(&pos_buf, "{s} · {d} wallpapers", .{ folder_disp, n_total }) catch ""
            else
                folder_disp;
            drawTextTop(c, @floatFromInt(m.info_x), @floatFromInt(m.thumb_y + k_name_lh + 4), pos, 13, 400, t.text_r, t.text_g, t.text_b, 0.55);
        }

        // Fit label + combo.
        drawTextTop(c, @floatFromInt(m.fit_x), @floatFromInt(m.fit_y - k_sub_lh - 6), "Fit", 13, 400, t.text_r, t.text_g, t.text_b, 0.55);

        // Fit combo (closed state; the popup paints back in `paint`).
        {
            const mm: usize = @intCast(std.math.clamp(self.snap.mode, 0, 4));
            const hov = inR(px, py, m.fit_x, m.fit_y, m.fit_w, m.fit_h);
            paintCombo(c, m.fit_x, m.fit_y, m.fit_w, m.fit_h, mode_labels[mm], hov or self.mode_drop_open, t);
        }

        // Action row: primary Choose Wallpaper opens the folder browser;
        // Previous/Next step the gallery; Adjust toggles the view panel.
        {
            var bx = m.info_x;
            const by = m.btns_y;
            paintBtn(c, bx, by, m.choose_w, k_btn_h, "Choose Wallpaper", true, inR(px, py, bx, by, m.choose_w, k_btn_h), t);
            bx += m.choose_w + k_btn_gap;
            paintBtn(c, bx, by, m.prev_w, k_btn_h, "Previous", false, inR(px, py, bx, by, m.prev_w, k_btn_h), t);
            bx += m.prev_w + k_btn_gap;
            paintBtn(c, bx, by, m.next_w, k_btn_h, "Next", false, inR(px, py, bx, by, m.next_w, k_btn_h), t);
            bx += m.next_w + k_btn_gap;
            paintBtn(c, bx, by, m.adj_w, k_btn_h, "Adjust", false, inR(px, py, bx, by, m.adj_w, k_btn_h), t);
        }

        // Library header: title + dim "path, N wallpapers" line; the segmented
        // sort control rides on the right.
        drawTextTop(c, @floatFromInt(m.pg_x), @floatFromInt(m.lib_y), "Library", 16, 600, t.text_r, t.text_g, t.text_b, 0.95);
        {
            const folder_disp: []const u8 = if (self.snap.folder.len == 0) "No folder" else self.snap.folder;
            var hd_buf: [512]u8 = undefined;
            const hd_full = std.fmt.bufPrint(&hd_buf, "{s}, {d} wallpapers", .{ folder_disp, self.gallery.entries.items.len }) catch "";
            const max_w: i32 = @max(80, m.seg_x - 12 - m.pg_x);
            drawTextTopW(c, @floatFromInt(m.pg_x), @floatFromInt(m.lib_y + k_lib_lh + 2), hd_full, 13, 400, @floatFromInt(max_w), t.text_r, t.text_g, t.text_b, 0.55);
        }

        // Segmented sort control (mock .seg): pill container, active knob.
        ui_paint.glassBox(c, @floatFromInt(m.seg_x), @floatFromInt(m.seg_y), @floatFromInt(m.seg_w), @floatFromInt(k_seg_h), 12, 1, 1, 1, 0.06);
        cairo_save(c);
        ui_paint.roundRect(c, @floatFromInt(m.seg_x), @floatFromInt(m.seg_y), @floatFromInt(m.seg_w), @floatFromInt(k_seg_h), 12.0);
        cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.35);
        cairo_set_line_width(c, 1.0);
        cairo_stroke(c);
        cairo_restore(c);
        for (sort_labels, 0..) |lab, pi| {
            const cell = segBtn(m, @intCast(pi));
            const sel = self.sort_mode == @as(i32, @intCast(pi));
            if (sel) {
                ui_paint.glassBox(c, @floatFromInt(cell.x), @floatFromInt(cell.y), @floatFromInt(cell.w), @floatFromInt(cell.h), 9, t.acc_r, t.acc_g, t.acc_b, 0.18);
            }
            const ts = ui_paint.textSizePx(c, lab, k_seg_font, 500);
            const top = @as(f64, @floatFromInt(cell.y)) + (@as(f64, @floatFromInt(cell.h)) - @as(f64, @floatFromInt(ts.h))) / 2.0;
            ui_paint.showText(
                c,
                @as(f64, @floatFromInt(cell.x)) + (@as(f64, @floatFromInt(cell.w)) - @as(f64, @floatFromInt(ts.w))) / 2.0,
                top + @as(f64, @floatFromInt(ts.h)) - 2.0,
                lab,
                k_seg_font,
                if (sel) 600 else 400,
                t.acc_r,
                t.acc_g,
                t.acc_b,
                if (sel) 0.95 else 0.55,
            );
        }

        // Collapsible view-options panel.
        if (self.view_open) {
            const panel_x = m.pg_x;
            const panel_y = m.view_panel_y;
            const panel_w = m.pg_w;
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
                ui_paint.showText(c, @floatFromInt(cell.x + 44 + 8), panel_y + 92, val, 15, 600, t.text_r, t.text_g, t.text_b, 1.0);                const hov_m = inR(px, py, cell.minus_x, cell.btn_y, 44, 32);
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
            const row_stride = gr.thumb_h + k_thumb_gap;
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

                // Hairline border: the tile edge, dimmer when selected (the
                // selection rings own the contrast then).
                cairo_save(c);
                ui_paint.roundRect(c, gx, gy_f, @floatFromInt(gr.thumb), @floatFromInt(gr.thumb_h), tile_rad);
                cairo_set_line_width(c, 1.0);
                if (selected)
                    cairo_set_source_rgba(c, 1, 1, 1, 0.06)
                else
                    cairo_set_source_rgba(c, 1, 1, 1, 0.12);
                cairo_stroke(c);
                cairo_restore(c);

                // Selected: the mock's double ring — a 2px dark band right at
                // the edge wrapped by a 4px accent band.
                if (selected) {
                    paintSelectedRings(c, gx, gy_f, @floatFromInt(gr.thumb), @floatFromInt(gr.thumb_h), tile_rad, t);
                    paintChip(c, gx + 8, gy_f + 8, 12.0, t);
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
        const gr = self.grid(m.pg_x, m.pg_w, m.gallery_grid_top);
        self.clampPage(gr.per_page);

        // The open mode list eats every press while it is up.
        // handles it before the tab's own handler).
        if (self.sub_tab == 0 and self.mode_drop_open) {
            const dd_y = m.fit_y + m.fit_h + 2;
            const lh = 5 * k_dd_row_h;
            self.mode_drop_open = false;
            if (inR(px, ly, m.fit_x, dd_y, m.fit_w, lh)) {
                const rr: i32 = @divTrunc(@as(i32, @intFromFloat(ly)) - dd_y, k_dd_row_h);
                if (rr >= 0 and rr <= 4) return .{ .set_mode = rr };
            }
            return .repaint;
        }

        // Sub-tab labels.
        {
            const st_x: i32 = m.pg_x;
            const st_y = m.sub_tab_y;
            const t0_w = ui_paint.measureTextWidth("Wallpaper", k_tab_font, 500);
            if (inR(px, ly, st_x, st_y, t0_w, k_tabs_h)) {
                self.sub_tab = 0;
                return .repaint;
            }
            const t1_x = st_x + t0_w + k_tab_gap;
            const t1_w = ui_paint.measureTextWidth("Gallery settings", k_tab_font, 500);
            if (inR(px, ly, t1_x, st_y, t1_w, k_tabs_h)) {
                self.sub_tab = 1;
                return .repaint;
            }
        }

        // Wallpaper enabled switch.
        if (inR(px, ly, m.toggle_x, m.toggle_y, k_toggle_w, k_toggle_h)) return .toggle_enabled;

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

        // Current card: Fit combo, then the action row.
        if (inR(px, ly, m.fit_x, m.fit_y, m.fit_w, m.fit_h)) {
            self.mode_drop_open = true;
            return .repaint;
        }
        {
            var bx = m.info_x;
            if (inR(px, ly, bx, m.btns_y, m.choose_w, k_btn_h)) return .pick_folder;
            bx += m.choose_w + k_btn_gap;
            if (inR(px, ly, bx, m.btns_y, m.prev_w, k_btn_h)) return .{ .cycle = -1 };
            bx += m.prev_w + k_btn_gap;
            if (inR(px, ly, bx, m.btns_y, m.next_w, k_btn_h)) return .{ .cycle = 1 };
            bx += m.next_w + k_btn_gap;
            if (inR(px, ly, bx, m.btns_y, m.adj_w, k_btn_h)) {
                self.view_open = !self.view_open;
                return .repaint;
            }
        }

        // View-options panel: the "All settings" link and the steppers.
        if (self.view_open) {
            const link_x = m.pg_x + m.pg_w - 20 - 118;
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

        // Segmented sort control.
        for (0..3) |pi| {
            const cell = segBtn(&m, @intCast(pi));
            if (inR(px, ly, cell.x, cell.y, cell.w, cell.h)) {
                const pi32: i32 = @intCast(pi);
                if (self.sort_mode != pi32) {
                    self.sort_mode = pi32;
                    scan.sortEntries(self.gallery.entries.items, self.sort_mode);
                    self.sort_applied = self.sort_mode;
                    self.page_idx = 0;
                }
                return .repaint;
            }
        }

        // Thumbnail selection.
        {
            const gx0 = @as(f64, @floatFromInt(gr.prev_x));
            const gall_off: usize = @as(usize, @intCast(@max(0, self.page_idx))) * gr.per_page;
            const n_total: usize = self.gallery.entries.items.len;
            const row_stride = gr.thumb_h + k_thumb_gap;
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

    // ------------------------------------------------- custom folder browser

    /// The in-app folder chooser. The old flow shelled out to kdialog/qarma/
    /// zenity and blocked the UI thread; this modal is drawn by the page and
    /// reads the filesystem off the UI thread.
    pub fn openFolderBrowser(self: *Page) void {
        if (!self.inited) return;
        const start = if (self.snap.folder.len > 0) self.snap.folder else browserHome();
        self.fb_open = true;
        self.browseTo(start);
    }

    /// The modal's start point: the configured folder, else HOME.
    fn browserHome() []const u8 {
        const h = getenv("HOME") orelse "/";
        return std.mem.span(h);
    }

    /// System-icon pixels for a freedesktop name (`folder`, `user-home`, …),
    /// fetched once through the shell's shared icon cache and kept for the
    /// page's life. Falls back to null → the caller draws its own glyph.
    fn fbIcon(self: *Page, name: []const u8) ?*const icon_cache.Owned {
        if (name.len == 0) return null;
        if (self.fb_icons.getEntry(name)) |e| return &e.value_ptr.*;
        const ic = icon_cache.shared() orelse return null;
        const owned = ic.getOwned(.app, name, 32) orelse return null;
        const key = self.alloc.dupe(u8, name) catch {
            var o = owned;
            o.deinit(self.alloc);
            return null;
        };
        const gop = self.fb_icons.getOrPut(self.alloc, key) catch {
            self.alloc.free(key);
            var o = owned;
            o.deinit(self.alloc);
            return null;
        };
        if (gop.found_existing) {
            self.alloc.free(key);
            var o = owned;
            o.deinit(self.alloc);
            return gop.value_ptr;
        }
        gop.key_ptr.* = key;
        gop.value_ptr.* = owned;
        return gop.value_ptr;
    }

    /// Free both entry lists (each owns its name/path strings).
    fn fbCloseLists(self: *Page) void {
        for (self.fb_dirs.items) |d| {
            self.alloc.free(d.full);
            if (d.name.ptr != d.full.ptr) self.alloc.free(d.name);
        }
        self.fb_dirs.deinit(self.alloc);
        self.fb_dirs = .empty;
        for (self.fb_imgs.items) |d| {
            self.alloc.free(d.full);
            if (d.name.ptr != d.full.ptr) self.alloc.free(d.name);
        }
        self.fb_imgs.deinit(self.alloc);
        self.fb_imgs = .empty;
    }

    /// Point the browser at `dir` and kick the listing worker.
    fn browseTo(self: *Page, dir: []const u8) void {
        const key = scan.folderKey(self.alloc, dir) catch return;
        self.fb_cwd.deinit(self.alloc);
        self.fb_cwd = .empty;
        self.fb_cwd.appendSlice(self.alloc, key) catch {
            self.alloc.free(key);
            return;
        };
        self.alloc.free(key);
        self.fbCloseLists();
        self.fb_err = false;
        self.fb_loading = true;
        self.fb_img_sel = -1;
        self.fb_scroll = 0;
        self.fb_seq +%= 1;
        browser.requestListing(self.io, self.fb_cwd.items, self.fb_hidden, self.fb_seq);
    }

    /// Up = the parent of the current directory (root stays root).
    fn fbUp(self: *Page) void {
        const parent = std.fs.path.dirname(self.fb_cwd.items) orelse return;
        self.browseTo(parent);
    }

    /// Adopt a published listing. Older or mismatched sequences are dropped,
    /// so a fast navigation cannot land a slow directory's entries late.
    fn drainFolderScan(self: *Page) void {
        if (!self.inited or !self.fb_open) return;
        while (browser.take()) |l| {
            defer l.freeListing();
            if (l.seq != self.fb_seq) continue;
            if (!std.mem.eql(u8, l.root, self.fb_cwd.items)) continue;
            self.fbCloseLists();
            for (l.dirs) |*d| self.adoptEntry(&self.fb_dirs, d) catch break;
            for (l.imgs) |*d| self.adoptEntry(&self.fb_imgs, d) catch break;
            self.fb_err = !l.ok;
            self.fb_loading = false;
        }
    }

    fn adoptEntry(self: *Page, list: *std.ArrayList(browser.DirEntry), d: *browser.DirEntry) !void {
        const full = self.alloc.dupe(u8, d.full) catch return error.OutOfMemory;
        errdefer self.alloc.free(full);
        var name = full;
        const base = std.fs.path.basename(full);
        if (base.len != full.len) name = self.alloc.dupe(u8, base) catch return error.OutOfMemory;
        // The thumb cache keys off `full`; the label can share it whenever
        // the basename is the whole path (one free site).
        errdefer if (name.ptr != full.ptr) self.alloc.free(name);
        try list.append(self.alloc, .{
            .full = full,
            .name = name,
            .mtime_ns = d.mtime_ns,
            .size = d.size,
        });
    }

    /// Wheel over the modal's list region scrolls it; `true` when absorbed.
    pub fn fbAxis(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64, step: i64) bool {
        if (!self.fb_open) return false;
        const g = fbGeom(win_w, win_h);
        if (!common.pointInRect(px, py, fbBodyRect(g))) return false;
        self.fb_scroll = @max(0, self.fb_scroll + @as(i32, @intCast(@max(-4096, @min(4096, step)))));
        return true;
    }

    /// `true` when the pointer is anywhere over the modal panel (the window
    /// absorbs wheel events there so the page behind stays put).
    pub fn fbPanelHovered(self: *const Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (!self.fb_open) return false;
        const g = fbGeom(win_w, win_h);
        return common.pointInRect(px, py, .{ .x = g.x, .y = g.y, .w = g.w, .h = g.h });
    }

    /// Content height of the browser body (folder rows + the image grid).
    fn fbContentH(self: *Page, g: FbGeom) i32 {
        const dirs_h: i32 = @as(i32, @intCast(self.fb_dirs.items.len)) * fb_row_h;
        var h: i32 = dirs_h;
        if (self.fb_imgs.items.len > 0) {
            const rows: i32 = @intCast((self.fb_imgs.items.len +
                @as(usize, @intCast(g.tile_cols)) - 1) / @as(usize, @intCast(g.tile_cols)));
            h += fb_sec_h + rows * (fb_tile_h + fb_cap_h);
        }
        return h;
    }

    /// Clamp `fb_scroll` against the real window size and copy it into the
    /// frame geometry so paint and hit read the same offset.
    fn fbPrepGeom(self: *Page, g: FbGeom) FbGeom {
        const content = self.fbContentH(g);
        self.fb_scroll = std.math.clamp(self.fb_scroll, 0, @max(0, content - g.body_h));
        var g2 = g;
        g2.scroll = self.fb_scroll;
        return g2;
    }

    /// The modal: dim backdrop, glass panel, places rail, a toolbar (Up,
    /// path readout, hidden toggle, refresh), the scrolled folder/image body
    /// and the footer actions. Hit terrain in `clickFolderBrowser` mirrors
    /// the rects here.
    pub fn paintFolderBrowser(self: *Page, cr: ?*cairo.cairo_t, win_w: i32, win_h: i32, px: f64, py: f64) void {
        const c = cr orelse return;
        if (!self.inited) return;
        const t = common.Theme;
        const g = self.fbPrepGeom(fbGeom(win_w, win_h));
        self.drainFolderScan();

        cairo_set_source_rgba(c, 0, 0, 0, 0.40);
        cairo_rectangle(c, 0, 0, @as(f64, @floatFromInt(win_w)), @as(f64, @floatFromInt(win_h)));
        cairo_fill(c);

        ui_paint.glassBox(
            c,
            @as(f64, @floatFromInt(g.x)),
            @as(f64, @floatFromInt(g.y)),
            @as(f64, @floatFromInt(g.w)),
            @as(f64, @floatFromInt(g.h)),
            16,
            t.bg_r,
            t.bg_g,
            t.bg_b,
            0.96,
        );

        // Title + close.
        ui_paint.showText(
            c,
            @as(f64, @floatFromInt(g.x + fb_pad)),
            @as(f64, @floatFromInt(g.y + fb_title_h - 14)),
            "Choose a wallpaper folder",
            14,
            700,
            t.text_r,
            t.text_g,
            t.text_b,
            1.0,
        );
        paintGlyphBtnWide(c, g.x + g.w - fb_pad - 28, g.y + fb_pad, 28, 28, "close", false, inR(px, py, g.x + g.w - fb_pad - 28, g.y + fb_pad, 28, 28), t);

        // Toolbar: Up, path, hidden toggle, refresh.
        const root = self.fb_cwd.items.len == 0 or std.mem.eql(u8, self.fb_cwd.items, "/");
        paintGlyphBtnWide(c, g.body_x, g.tool_y, 30, 30, "arrow_back", false, inR(px, py, g.body_x, g.tool_y, 30, 30), t);
        paintGlyphBtnWide(c, g.refresh_x, g.tool_y, 30, 30, "autorenew", false, inR(px, py, g.refresh_x, g.tool_y, 30, 30), t);
        const hid_x = g.refresh_x - 10 - fb_hidden_w;
        paintBtn(c, hid_x, g.tool_y, fb_hidden_w, 30, "Hidden", self.fb_hidden, inR(px, py, hid_x, g.tool_y, fb_hidden_w, 30), t);
        if (self.fb_hidden) {
            ui_paint.glyph(
                c,
                @as(f64, @floatFromInt(hid_x + fb_hidden_w - 18)),
                @as(f64, @floatFromInt(g.tool_y + 15)),
                12,
                "check",
                t.acc_r,
                t.acc_g,
                t.acc_b,
                1.0,
            );
        }
        const path_w: f64 = @floatFromInt(hid_x - 10 - (g.body_x + 42));
        ui_paint.showTextW(
            c,
            @as(f64, @floatFromInt(g.body_x + 42)),
            @as(f64, @floatFromInt(g.tool_y + 21)),
            if (self.fb_cwd.items.len > 0) self.fb_cwd.items else "/",
            11,
            400,
            @max(40.0, path_w),
            t.text_r,
            t.text_g,
            t.text_b,
            if (root) 0.45 else 0.8,
        );

        // Places rail.
        var place_buf: [512]u8 = undefined;
        for (fb_places, 0..) |p, i| {
            const ry = g.body_y + @as(i32, @intCast(i)) * fb_place_h;
            const hov = inR(px, py, g.side_x, ry, g.side_w, fb_place_h);
            if (hov) {
                ui_paint.glassBox(c, @as(f64, @floatFromInt(g.side_x)), @as(f64, @floatFromInt(ry)), @as(f64, @floatFromInt(g.side_w)), @as(f64, @floatFromInt(fb_place_h)), 8, 1, 1, 1, 0.05);
            }
            if (self.fbIcon(p.icon)) |ic| {
                fbBlitIcon(c, ic, @as(f64, @floatFromInt(g.side_x + 10)), @as(f64, @floatFromInt(ry + (fb_place_h - 18) / 2)), 18);
            } else {
                ui_paint.glyph(c, @as(f64, @floatFromInt(g.side_x + 22)), @as(f64, @floatFromInt(ry + fb_place_h / 2)), 14, p.glyph, t.text_r, t.text_g, t.text_b, if (hov) 0.95 else 0.7);
            }
            ui_paint.showText(c, @as(f64, @floatFromInt(g.side_x + 44)), @as(f64, @floatFromInt(ry + fb_place_h / 2 + 8)), p.label, 12, 400, t.text_r, t.text_g, t.text_b, if (hov) 1.0 else 0.8);
        }
        const counts = std.fmt.bufPrint(
            &place_buf,
            "{d} folders · {d} images",
            .{ self.fb_dirs.items.len, self.fb_imgs.items.len },
        ) catch "";
        const counts_y = g.body_y + @as(i32, @intCast(fb_places.len)) * fb_place_h + 22;
        ui_paint.showTextW(
            c,
            @as(f64, @floatFromInt(g.side_x + 8)),
            @as(f64, @floatFromInt(counts_y)),
            counts,
            10,
            400,
            @as(f64, @floatFromInt(g.side_w - 16)),
            t.text_r,
            t.text_g,
            t.text_b,
            0.45,
        );
        // Rail separator.
        cairo_save(c);
        cairo_move_to(c, @as(f64, @floatFromInt(g.side_x + g.side_w + 7)), @as(f64, @floatFromInt(g.body_y)));
        cairo_line_to(c, @as(f64, @floatFromInt(g.side_x + g.side_w + 7)), @as(f64, @floatFromInt(g.body_y + g.body_h)));
        cairo_set_line_width(c, 1.0);
        cairo_set_source_rgba(c, 1, 1, 1, 0.08);
        cairo_stroke(c);
        cairo_restore(c);

        // Scrolled body (clipped).
        cairo_save(c);
        ui_paint.roundRect(
            c,
            @as(f64, @floatFromInt(g.body_x)),
            @as(f64, @floatFromInt(g.body_y)),
            @as(f64, @floatFromInt(g.body_w)),
            @as(f64, @floatFromInt(g.body_h)),
            10.0,
        );
        cairo_clip(c);
        const base_y: i32 = g.body_y - g.scroll;
        const loading = self.fb_loading and self.fb_dirs.items.len == 0 and self.fb_imgs.items.len == 0;

        if (self.fb_err and !loading) {
            ui_paint.showText(c, @as(f64, @floatFromInt(g.body_x + 12)), @as(f64, @floatFromInt(g.body_y + 26)), "Could not open this folder.", 12, 400, t.text_r, t.text_g, t.text_b, 0.6);
        } else if (loading) {
            ui_paint.showText(c, @as(f64, @floatFromInt(g.body_x + 12)), @as(f64, @floatFromInt(g.body_y + 26)), "Listing…", 12, 400, t.text_r, t.text_g, t.text_b, 0.5);
        } else if (self.fb_dirs.items.len == 0 and self.fb_imgs.items.len == 0) {
            ui_paint.showText(c, @as(f64, @floatFromInt(g.body_x + 12)), @as(f64, @floatFromInt(g.body_y + 26)), "No folders or images here.", 12, 400, t.text_r, t.text_g, t.text_b, 0.5);
        }

        // Folder rows.
        for (self.fb_dirs.items, 0..) |d, i| {
            const ry = base_y + @as(i32, @intCast(i)) * fb_row_h;
            if (ry > g.body_y + g.body_h or ry + fb_row_h < g.body_y) continue;
            const rx = g.body_x;
            const hov = inR(px, py, rx, ry, g.body_w, fb_row_h);
            if (hov) {
                ui_paint.glassBox(c, @as(f64, @floatFromInt(rx)), @as(f64, @floatFromInt(ry)), @as(f64, @floatFromInt(g.body_w)), @as(f64, @floatFromInt(fb_row_h)), 8, 1, 1, 1, 0.05);
            }
            if (self.fbIcon("folder")) |ic| {
                fbBlitIcon(c, ic, @as(f64, @floatFromInt(rx + 14)), @as(f64, @floatFromInt(ry + (fb_row_h - 20) / 2)), 20);
            } else {
                paintFolderIcon(c, @as(f64, @floatFromInt(rx + 16)), @as(f64, @floatFromInt(ry + fb_row_h / 2 - 7)), t, if (hov) 0.95 else 0.7);
            }
            ui_paint.showTextW(
                c,
                @as(f64, @floatFromInt(rx + 44)),
                @as(f64, @floatFromInt(ry + fb_row_h / 2 + 8)),
                d.name,
                12,
                400,
                @as(f64, @floatFromInt(g.body_w - 64)),
                t.text_r,
                t.text_g,
                t.text_b,
                if (hov) 1.0 else 0.85,
            );
            ui_paint.glyph(
                c,
                @as(f64, @floatFromInt(rx + g.body_w - 20)),
                @as(f64, @floatFromInt(ry + fb_row_h / 2)),
                12,
                "expand_more",
                t.text_r,
                t.text_g,
                t.text_b,
                0.35,
            );
        }

        // Image tiles.
        if (self.fb_imgs.items.len > 0) {
            const sec_y = base_y + @as(i32, @intCast(self.fb_dirs.items.len)) * fb_row_h;
            const hdr = std.fmt.bufPrint(&place_buf, "Images ({d})", .{self.fb_imgs.items.len}) catch "Images";
            ui_paint.showText(c, @as(f64, @floatFromInt(g.body_x + 4)), @as(f64, @floatFromInt(sec_y + 18)), hdr, 11, 600, t.text_r, t.text_g, t.text_b, 0.55);
            const tiles_top = sec_y + fb_sec_h;
            const cap_top_extra = fb_tile_h + 14;
            for (self.fb_imgs.items, 0..) |d, i| {
                const m: usize = @intCast(g.tile_cols);
                const tx = g.body_x +
                    @as(i32, @intCast(i % m)) * (fb_tile_w + fb_gap);
                const ty = tiles_top +
                    @as(i32, @intCast(i / m)) * (fb_tile_h + fb_cap_h);
                if (ty > g.body_y + g.body_h or ty + fb_tile_h < g.body_y) continue;
                const sel = @as(i32, @intCast(i)) == self.fb_img_sel;
                const hov = inR(px, py, tx, ty, fb_tile_w, fb_tile_h + fb_cap_h);
                // Thumb: cover-fit like the gallery, requested off-thread.
                self.requestOrRetry(d.full, fbThumbPx());
                // Plate behind (outside the clip — `cairo_fill` clears the
                // current path, which is exactly what blanked every tile in
                // the first build: the fill ran before the clip and the clip
                // then clipped to an empty path).
                ui_paint.roundRect(c, @as(f64, @floatFromInt(tx)), @as(f64, @floatFromInt(ty)), @as(f64, @floatFromInt(fb_tile_w)), @as(f64, @floatFromInt(fb_tile_h)), 9.0);
                cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.5);
                cairo_fill(c);
                cairo_save(c);
                ui_paint.roundRect(c, @as(f64, @floatFromInt(tx)), @as(f64, @floatFromInt(ty)), @as(f64, @floatFromInt(fb_tile_w)), @as(f64, @floatFromInt(fb_tile_h)), 9.0);
                cairo_clip(c);
                if (self.surfaceFor(d.full)) |surf| {
                    cairo_surface_flush(surf);
                    const iw = cairo_image_surface_get_width(surf);
                    const ih = cairo_image_surface_get_height(surf);
                    if (iw > 0 and ih > 0) {
                        const twf: f64 = @floatFromInt(fb_tile_w);
                        const thf: f64 = @floatFromInt(fb_tile_h);
                        const sc = @max(twf / @as(f64, @floatFromInt(iw)), thf / @as(f64, @floatFromInt(ih)));
                        cairo_set_operator(c, CAIRO_OPERATOR_OVER);
                        cairo_translate(
                            c,
                            @as(f64, @floatFromInt(tx)) + (twf - @as(f64, @floatFromInt(iw)) * sc) * 0.5,
                            @as(f64, @floatFromInt(ty)) + (thf - @as(f64, @floatFromInt(ih)) * sc) * 0.5,
                        );
                        cairo_scale(c, sc, sc);
                        cairo_set_source_surface(c, surf, 0, 0);
                        cairo_paint(c);
                    }
                } else {
                    ui_paint.glyph(
                        c,
                        @as(f64, @floatFromInt(tx + fb_tile_w / 2)),
                        @as(f64, @floatFromInt(ty + fb_tile_h / 2)),
                        20,
                        "photo_library",
                        1,
                        1,
                        1,
                        0.25,
                    );
                }
                cairo_restore(c);
                if (hov and !sel) {
                    ui_paint.roundRect(c, @as(f64, @floatFromInt(tx)), @as(f64, @floatFromInt(ty)), @as(f64, @floatFromInt(fb_tile_w)), @as(f64, @floatFromInt(fb_tile_h)), 9.0);
                    cairo_set_source_rgba(c, 1, 1, 1, 0.35);
                    cairo_set_line_width(c, 1.0);
                    cairo_stroke(c);
                }
                if (sel) {
                    ui_paint.roundRect(c, @as(f64, @floatFromInt(tx - 1)), @as(f64, @floatFromInt(ty - 1)), @as(f64, @floatFromInt(fb_tile_w + 2)), @as(f64, @floatFromInt(fb_tile_h + 2)), 10.0);
                    cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 1.0);
                    cairo_set_line_width(c, 2.0);
                    cairo_stroke(c);
                }
                ui_paint.showTextW(
                    c,
                    @as(f64, @floatFromInt(tx + 2)),
                    @as(f64, @floatFromInt(ty + cap_top_extra)),
                    d.name,
                    10,
                    400,
                    @as(f64, @floatFromInt(fb_tile_w - 4)),
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    if (sel) 1.0 else 0.7,
                );
            }
        }
        cairo_restore(c);

        // Footer: status + Cancel + Use.
        ui_paint.showTextW(
            c,
            @as(f64, @floatFromInt(g.x + fb_pad)),
            @as(f64, @floatFromInt(g.foot_y + 32)),
            self.fbFootLabel(),
            11,
            400,
            @as(f64, @floatFromInt(fbFootStatusW(g))),
            t.text_r,
            t.text_g,
            t.text_b,
            0.55,
        );
        paintBtn(c, g.cancel_x, g.foot_y, 90, 34, "Cancel", false, inR(px, py, g.cancel_x, g.foot_y, 90, 34), t);
        const use_label: []const u8 = if (self.fb_img_sel >= 0) "Use image" else "Use folder";
        paintBtn(c, g.use_x, g.foot_y, fb_use_w, 34, use_label, true, inR(px, py, g.use_x, g.foot_y, fb_use_w, 34), t);
    }

    fn fbFootLabel(self: *Page) []const u8 {
        const is_img = self.fb_img_sel >= 0;
        const safe: bool = is_img and @as(usize, @intCast(self.fb_img_sel)) < self.fb_imgs.items.len;
        if (is_img) {
            if (!safe) return "Image";
            const name = self.fb_imgs.items[@intCast(self.fb_img_sel)].name;
            return std.fmt.bufPrint(&self.fb_stamp_buf, "Image · {s}", .{name}) catch "Image";
        }
        const cwd: []const u8 = if (self.fb_cwd.items.len > 0) self.fb_cwd.items else "/";
        return std.fmt.bufPrint(&self.fb_stamp_buf, "Folder · {s}", .{cwd}) catch "Folder";
    }

    /// What one click does inside the modal. The page moves its own session
    /// state and closes itself; `use_folder`/`use_image` tell the window to
    /// commit the choice (it reads `fb_cwd` / `fb_imgs`).
    pub fn clickFolderBrowser(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) ?Action {
        const g = self.fbPrepGeom(fbGeom(win_w, win_h));

        if (inR(px, py, g.x + g.w - fb_pad - 28, g.y + fb_pad, 28, 28)) {
            self.fb_open = false;
            return null; // repaint only
        }
        if (inR(px, py, g.body_x, g.tool_y, 30, 30)) {
            self.fbUp();
            return null;
        }
        if (inR(px, py, g.refresh_x, g.tool_y, 30, 30)) {
            self.browseTo(self.fb_cwd.items);
            return null;
        }
        const hid_x = g.refresh_x - 10 - fb_hidden_w;
        if (inR(px, py, hid_x, g.tool_y, fb_hidden_w, 30)) {
            self.fb_hidden = !self.fb_hidden;
            self.browseTo(self.fb_cwd.items);
            return null;
        }
        for (fb_places, 0..) |p, i| {
            const ry = g.body_y + @as(i32, @intCast(i)) * fb_place_h;
            if (inR(px, py, g.side_x, ry, g.side_w, fb_place_h)) {
                var buf: [512]u8 = undefined;
                self.browseTo(fbPlacePath(buf[0..], p.sub));
                return null;
            }
        }
        if (inR(px, py, g.body_x, g.body_y, g.body_w, g.body_h)) {
            // Folder rows, then the image grid, both relative to scroll.
            if (self.fb_dirs.items.len > 0) {
                const dir_cnt = self.fb_dirs.items.len;
                const y = py - @as(f64, @floatFromInt(g.body_y + g.scroll));
                if (y >= 0) {
                    const idx: usize = @intFromFloat(y / @as(f64, @floatFromInt(fb_row_h)));
                    if (idx < dir_cnt and !self.fb_loading) {
                        self.browseTo(self.fb_dirs.items[idx].full);
                        return null;
                    }
                }
            }
            if (self.fb_imgs.items.len > 0) {
                const tiles_top = g.body_y + g.scroll +
                    @as(i32, @intCast(self.fb_dirs.items.len)) * fb_row_h + fb_sec_h;
                const rel_y = py - @as(f64, @floatFromInt(tiles_top));
                const pitch_x: i32 = fb_tile_w + fb_gap;
                const cols = g.tile_cols;
                // Reverse base: from the pixel back to col/row/index.
                const any_col = @as(i32, @intFromFloat((px - @as(f64, @floatFromInt(g.body_x))) / @as(f64, @floatFromInt(pitch_x))));
                if (rel_y >= 0 and any_col < cols) {
                    const row: i32 = @intFromFloat(rel_y / @as(f64, @floatFromInt(fb_tile_h + fb_cap_h)));
                    const col: i32 = std.math.clamp(any_col, 0, cols - 1);
                    const idx = row * cols + col;
                    if (idx >= 0 and idx < @as(i32, @intCast(self.fb_imgs.items.len))) {
                        const in_click = inR(px, py, g.body_x + col * pitch_x, tiles_top + row * (fb_tile_h + fb_cap_h), fb_tile_w, fb_tile_h + fb_cap_h);
                        if (in_click) {
                            self.fb_img_sel = idx;
                            return null;
                        }
                    }
                }
            }
            return null;
        }
        // Footer.
        if (inR(px, py, g.cancel_x, g.foot_y, 90, 34)) {
            self.fb_open = false;
            return null;
        }
        if (inR(px, py, g.use_x, g.foot_y, fb_use_w, 34)) {
            if (self.fb_img_sel >= 0) {
                const idx: usize = @intCast(self.fb_img_sel);
                if (idx >= self.fb_imgs.items.len) return null;
                self.fb_open = false;
                return .{ .use_image = idx };
            }
            self.fb_open = false;
            return .use_folder;
        }
        // Clicks over the toolbar, places or title bar, or outside: absorbed.
        return null;
    }

};

/// Draw a system-icon pixel buffer at `size`, centred in the box at (x, y).
/// Same shape as the Sound tab's `blitIcon`.
fn fbBlitIcon(c: *cairo.cairo_t, icon: *const icon_cache.Owned, x: f64, y: f64, size: f64) void {
    if (icon.pixels.len == 0 or icon.w <= 0 or icon.h <= 0) return;
    const sf = size / @as(f64, @floatFromInt(@max(1, @max(icon.w, icon.h))));
    const tw: i32 = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(icon.w)) * sf))));
    const th: i32 = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(icon.h)) * sf))));
    const tmp = cairo.cairo_image_surface_create_for_data(
        @constCast(icon.pixels.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        icon.w,
        icon.h,
        icon.w * 4,
    );
    defer cairo.cairo_surface_destroy(tmp);
    if (cairo.cairo_surface_status(tmp) != cairo.CAIRO_STATUS_SUCCESS) return;
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x + (size - @as(f64, @floatFromInt(tw))) * 0.5, y + (size - @as(f64, @floatFromInt(th))) * 0.5);
    cairo.cairo_scale(c, sf, sf);
    cairo.cairo_set_source_surface(c, tmp, 0, 0);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
}

/// Hand-drawn folder glyph (fallback when the icon theme has no `folder`):
/// a filled tab over an outlined rounded body.
fn paintFolderIcon(c: anytype, x: f64, y: f64, t: anytype, a: f64) void {
    ui_paint.roundRect(c, x, y, 8, 5, 1.5);
    cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, a * 0.9);
    cairo_fill(c);
    ui_paint.roundRect(c, x, y + 3, 18, 11, 3);
    cairo_set_line_width(c, 1.0);
    cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, a);
    cairo_stroke(c);
}

/// Sidebar quick targets, all rooted at HOME (`sub == ""` is HOME itself).
/// `icon` is the freedesktop name the user's theme supplies; `glyph` is the
/// Lucide fallback.
const FbPlace = struct { label: []const u8, glyph: []const u8, icon: []const u8, sub: []const u8 };
const fb_places = [_]FbPlace{
    .{ .label = "Home", .glyph = "home", .icon = "user-home", .sub = "" },
    .{ .label = "Pictures", .glyph = "photo_library", .icon = "folder-pictures", .sub = "Pictures" },
    .{ .label = "Downloads", .glyph = "download", .icon = "folder-download", .sub = "Downloads" },
    .{ .label = "Desktop", .glyph = "desktop_windows", .icon = "user-desktop", .sub = "Desktop" },
};

fn fbPlacePath(buf: []u8, sub: []const u8) []const u8 {
    const home = std.mem.span(getenv("HOME") orelse "/");
    if (sub.len == 0) return std.fmt.bufPrint(buf, "{s}", .{home}) catch "/";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, sub }) catch "/";
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// The modal's window-space layout. `scroll` is filled per frame by
/// `fbPrepGeom` so every rect helper stays a pure function of one struct.
pub const FbGeom = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    pad: i32,
    side_x: i32,
    side_w: i32,
    body_x: i32,
    body_y: i32,
    body_w: i32,
    body_h: i32,
    tool_y: i32,
    refresh_x: i32,
    foot_y: i32,
    cancel_x: i32,
    use_x: i32,
    tile_cols: i32,
    scroll: i32 = 0,
};

const fb_pad: i32 = 16;
const fb_title_h: i32 = 46;
const fb_tool_h: i32 = 42;
const fb_foot_h: i32 = 56;
const fb_side_w: i32 = 172;
const fb_row_h: i32 = 38;
const fb_place_h: i32 = 34;
const fb_sec_h: i32 = 30;
const fb_tile_w: i32 = 120;
const fb_tile_h: i32 = 75;
const fb_cap_h: i32 = 18;
const fb_gap: i32 = 10;
const fb_hidden_w: i32 = 76;
const fb_use_w: i32 = 116;

fn fbGeom(win_w: i32, win_h: i32) FbGeom {
    const w: i32 = @min(880, win_w - 100);
    const h: i32 = @min(640, win_h - 90);
    const x = @max(10, @divTrunc(win_w - w, 2));
    const y = @max(10, @divTrunc(win_h - h, 2));
    const body_x = x + fb_pad + fb_side_w + 14;
    const body_w = x + w - fb_pad - body_x;
    const body_y = y + fb_title_h + fb_tool_h;
    const foot_y = y + h - fb_foot_h;
    const use_x = x + w - fb_pad - fb_use_w;
    return .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .pad = fb_pad,
        .side_x = x + fb_pad,
        .side_w = fb_side_w,
        .body_x = body_x,
        .body_y = body_y,
        .body_w = body_w,
        .body_h = foot_y - body_y,
        .tool_y = y + fb_title_h + (fb_tool_h - 30) / 2,
        .refresh_x = x + w - fb_pad - 30,
        .foot_y = foot_y + 6,
        .cancel_x = use_x - 10 - 90,
        .use_x = use_x,
        .tile_cols = @max(1, @divTrunc(body_w + fb_gap, fb_tile_w + fb_gap)),
    };
}

fn fbBodyRect(g: FbGeom) common.Rect {
    return .{ .x = g.body_x, .y = g.body_y, .w = g.body_w, .h = g.body_h };
}

fn fbFootStatusW(g: FbGeom) i32 {
    return g.cancel_x - 10 - (g.x + fb_pad);
}

/// Decode size for one browser tile: the same `cache_px` the gallery and
/// hero use, so a browse always reuses the cached surface for that path
/// (one decode, one disk-cache entry) instead of rendering a second size.
fn fbThumbPx() u32 {
    return cache_px;
}

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

/// Show text with `top_y` as the visual top of the first line. `showText`
/// anchors its layout top at `y - lh + 2`, so this measures once and passes
/// `top + lh - 2` — layout math can then stack runs without drift.
fn drawTextTop(c: anytype, x: f64, top_y: f64, str: []const u8, size: f32, weight: c_uint, r: f64, g: f64, b: f64, a: f64) void {
    const ts = ui_paint.textSizePx(c, str, size, weight);
    ui_paint.showText(c, x, top_y + @as(f64, @floatFromInt(ts.h)) - 2.0, str, size, weight, r, g, b, a);
}

/// `drawTextTop` with an ellipsis width clamp (single-line runs, so the
/// unclamped measurement carries the same line box the clamped one uses).
fn drawTextTopW(c: anytype, x: f64, top_y: f64, str: []const u8, size: f32, weight: c_uint, max_w: f64, r: f64, g: f64, b: f64, a: f64) void {
    const ts = ui_paint.textSizePx(c, str, size, weight);
    ui_paint.showTextW(c, x, top_y + @as(f64, @floatFromInt(ts.h)) - 2.0, str, size, weight, max_w, r, g, b, a);
}

/// The mock's "In use" chip: an accent pill with dark 600 text at `size`.
fn paintChip(c: anytype, x: f64, y: f64, size: f32, t: anytype) void {
    const label = "In use";
    const ts = ui_paint.textSizePx(c, label, size, 600);
    const w: f64 = @as(f64, @floatFromInt(ts.w)) + 16.0;
    const h: f64 = @as(f64, @floatFromInt(ts.h)) + 6.0;
    ui_paint.glassBox(c, x, y, w, h, h / 2.0, t.acc_r, t.acc_g, t.acc_b, 1.0);
    const top = y + (h - @as(f64, @floatFromInt(ts.h))) / 2.0;
    ui_paint.showText(
        c,
        x + w / 2.0 - @as(f64, @floatFromInt(ts.w)) / 2.0,
        top + @as(f64, @floatFromInt(ts.h)) - 2.0,
        label,
        size,
        600,
        t.bg_r,
        t.bg_g,
        t.bg_b,
        1.0,
    );
}

/// The mock's `.th.s` selection: a 2px dark band hugging the edge wrapped by
/// a 4px accent band.
fn paintSelectedRings(c: anytype, x: f64, y: f64, w: f64, h: f64, rad: f64, t: anytype) void {
    cairo_save(c);
    ui_paint.roundRect(c, x - 3.0, y - 3.0, w + 6.0, h + 6.0, rad + 3.0);
    cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.95);
    cairo_set_line_width(c, 5.0);
    cairo_stroke(c);
    ui_paint.roundRect(c, x - 1.0, y - 1.0, w + 2.0, h + 2.0, rad + 1.0);
    cairo_set_source_rgba(c, t.bg_r * 0.15, t.bg_g * 0.15, t.bg_b * 0.15, 1.0);
    cairo_set_line_width(c, 2.0);
    cairo_stroke(c);
    cairo_restore(c);
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
    // Mock .btn.p: accent fill with dark ink; outlined variants keep accent.
    const ink: [3]f64 = if (filled) .{ t.bg_r, t.bg_g, t.bg_b } else .{ t.acc_r, t.acc_g, t.acc_b };
    ui_paint.showText(
        c,
        cx,
        top + @as(f64, @floatFromInt(ts.h)) - 2.0,
        label,
        font_px,
        500,
        ink[0],
        ink[1],
        ink[2],
        1.0,
    );
}

/// Glyph button, wide shape — the browser modal's icon buttons use it.
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

/// The Fit combo in its closed state. Same clip + centre idiom as the
/// Sound tab's combo: `showText` anchors its layout top at `y - lh + 2`, so
/// passing `top + lh - 2` pins the ink dead-centre in the box.
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
    ui_paint.roundRect(c, xf, yf, wf, hf, 10.0);
    cairo_set_source_rgba(c, 1, 1, 1, if (hovered) 0.10 else 0.06);
    cairo.cairo_fill_preserve(c);
    cairo_set_line_width(c, 1.0);
    cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (hovered) 0.9 else 0.45);
    cairo_stroke(c);
    // The label is clipped to the space left of the chevron, ellipsised.
    cairo_save(c);
    cairo_rectangle(c, xf + 8, yf + 2, wf - 30, hf - 4);
    cairo_clip(c);
    const ts = ui_paint.textSizePx(c, text, 12, 500);
    const top = yf + (hf - @as(f64, @floatFromInt(ts.h))) / 2.0;
    ui_paint.showText(
        c,
        xf + 12,
        top + @as(f64, @floatFromInt(ts.h)) - 2.0,
        text,
        12,
        500,
        t.text_r,
        t.text_g,
        t.text_b,
        0.92,
    );
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
    const pg_w: i32 = 592 - 2 * k_page_pad;
    const hdr_top = k_content_top + k_page_pad;
    const hdr_h = k_title_lh + 2 + k_sub_lh;
    try t.expectEqual(@as(i32, hdr_top + hdr_h + k_hdr_gap_tabs), m.sub_tab_y);
    try t.expectEqual(@as(i32, 292 + k_page_pad), m.pg_x);
    try t.expectEqual(@as(i32, pg_w), m.pg_w);
    // Toggle centred on the title block, flush right.
    try t.expectEqual(@as(i32, 292 + k_page_pad + pg_w - k_toggle_w), m.toggle_x);
    try t.expectEqual(@as(i32, hdr_top + @divTrunc(hdr_h - k_toggle_h, 2)), m.toggle_y);
    // Current card: tabs + gap lands the card, thumb 16:9 inside the pad.
    try t.expectEqual(@as(i32, m.sub_tab_y + k_tabs_h + k_sec_gap), m.cur_y);
    try t.expectEqual(@as(i32, m.cur_y + k_cur_pad), m.thumb_y);
    try t.expectEqual(@as(i32, m.thumb_h + 2 * k_cur_pad), m.cur_h);
    try t.expectEqual(@as(i32, m.thumb_y + k_name_lh + 4 + k_sub_lh + 20 + k_sub_lh + 6), m.fit_y);
    try t.expectEqual(@as(i32, m.cur_y + m.cur_h - k_cur_pad - k_btn_h), m.btns_y);
    // Closed panel: grid starts below the library head.
    try t.expectEqual(@as(i32, 0), m.view_panel_h);
    try t.expectEqual(@as(i32, m.cur_y + m.cur_h + k_sec_gap), m.lib_y);
    try t.expectEqual(@as(i32, m.lib_y + m.lib_h + 16), m.gallery_grid_top);

    const mo = metrics(292.0, 592.0, true);
    try t.expectEqual(@as(i32, 148), mo.view_panel_h);
    try t.expectEqual(@as(i32, mo.view_panel_y + 148 + 16), mo.lib_y);
    try t.expectEqual(@as(i32, mo.lib_y + mo.lib_h + 16), mo.gallery_grid_top);
}

test "wallpaper-tab: grid tiles at the specified size" {
    const t = std.testing;
    var p: Page = .{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();
    p.columns = 4;
    p.rows = 3;
    p.scale_pct = 100;
    // pgW = 552: (552 - 48) / 4 = 126.
    const gr = p.grid(300, 552, 400);
    try t.expectEqual(@as(i32, 4), gr.cols);
    try t.expectEqual(@as(i32, 3), gr.rows);
    try t.expectEqual(@as(i32, 126), gr.thumb);
    try t.expectEqual(@as(i32, (126 * 10 + 15) / 16), gr.thumb_h);
    try t.expectEqual(@as(usize, 12), gr.per_page);
    try t.expectEqual(@as(i32, 400 + 3 * (gr.thumb_h + 16) + 14), gr.nav_y);
    try t.expectEqual(@as(i32, 300), gr.prev_x);
    try t.expectEqual(@as(i32, 300 + 552 - 80), gr.next_x);
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

    // A source rewritten in place (same name, new bytes) is a cache miss
    // again: the stale thumbnail is dropped instead of being painted forever.
    for (p.gallery.entries.items) |*e| {
        if (std.mem.eql(u8, std.fs.path.basename(e.path), "a.png")) e.mtime_ns = 0;
    }
    p.syncIncremental(key);
    try t.expectEqual(@as(usize, 3), p.gallery.entries.items.len);
    try t.expectEqual(@as(usize, 1), p.cache.count());

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
