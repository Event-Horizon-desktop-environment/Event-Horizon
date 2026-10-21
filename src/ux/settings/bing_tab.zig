//! The Bing Wallpaper tab — the Zig port of
//! `src/ux/settings/settings_tab_bing/settings_tab_bing.cpp`.
//!
//! Like the Wallpaper tab this is a *page*, not a card list: `ui_content.Content`
//! has no rows for tab 16 and delegates here (see `Content.bing`). Six stacked
//! cards — General, Daily Wallpaper, Updates, Archive Download, a conditional
//! Status card and Blocked Keywords — with two dropdowns that hang past the
//! bottom of their card and a progress bar. The Status card appearing and
//! disappearing shifts everything below it, so the layout has to be one
//! function both the paint and the hit test read, which is what `layout` is.
//!
//! Split of ownership:
//!   page   — every `App.bing*` session field (busy flags, status text, counts,
//!            the progress bar, the year/month selection, the dropdowns), the
//!            worker service, and the keyword list it hands the worker.
//!   window — `Settings` values, the two blocking dialogs (folder picker and
//!            the zenity keyword entry), and saving.
//!
//! Two departures from the C++, both of them places the upstream code is
//! visibly unfinished rather than merely different — each is called out where
//! it happens:
//!   * `App::bingFolderPickerOpen` is written by the Browse button and read by
//!     nothing in the whole C++ tree, so upstream the button is inert. Here it
//!     opens a real folder dialog.
//!   * the tab is painted at fixed window coordinates with no scroll offset in
//!     the C++, which puts the bottom third of it below the fold on a normal
//!     window. Here it scrolls, like every other tall tab.

const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const bing_service = @import("bing_service.zig");
const archive = @import("../../services/bing_archive.zig");
const local_time = @import("../../desktop_shell/desktop/local_time.zig");

/// Sidebar tab id (`kBingSettingsTab` / the `16` in `rows.zig`).
pub const tab_id: i32 = 16;

const k_content_top: i32 = common.content_top; // 16
const k_card_pad: i32 = common.card_pad; // 16
const k_card_gap: i32 = common.card_gap; // 12
const k_spacing_s: i32 = common.spacing_s; // 8
const k_spacing_m: i32 = common.spacing_m; // 12
const k_spacing_xl: i32 = common.spacing_xl; // 24
const k_dd_row_h: i32 = common.settings_dd_row_h; // 26

const k_btn_w: i32 = 120;
const k_btn_h: i32 = 28;
const k_combo_w: i32 = 130;
const k_combo_h: i32 = 28;
const k_dl_btn_w: i32 = 180;
const k_toggle_w: i32 = 52;
const k_toggle_h: i32 = 26;

/// Card title / description / toggle offsets from the card top.
const k_title_y: i32 = 36;
const k_desc_y: i32 = 53;
const k_toggle_y: i32 = 17;

// Card 1 — General.
const k_gen_top: i32 = k_content_top;
const k_gen_label_y: i32 = 100;
const k_gen_path_row: i32 = 124;
const k_gen_h: i32 = 168; // 124 + btnH + 16

// Card 2 — Daily Wallpaper.
const k_daily_top: i32 = k_gen_top + k_gen_h + k_card_gap; // 196
const k_daily_btn_row: i32 = 100;
const k_daily_file_row: i32 = 136;
const k_daily_h: i32 = 166; // 136 + textH + 16

// Card 3 — Updates.
const k_upd_top: i32 = k_daily_top + k_daily_h + k_card_gap; // 374
const k_upd_info_row: i32 = 96;
const k_upd_btn_row: i32 = 120;
const k_upd_h: i32 = 164; // 120 + btnH + 16

// Card 4 — Archive Download.
const k_arch_top: i32 = k_upd_top + k_upd_h + k_card_gap; // 550
const k_arch_label_y: i32 = 92;
const k_arch_combo_y: i32 = 118;
const k_arch_dl_row: i32 = 194;
const k_arch_h: i32 = 240;

// Card 5 — Status (conditional).
const k_status_top: i32 = k_arch_top + k_arch_h + k_card_gap; // 802
const k_status_h: i32 = 140;
const k_status_label_y: i32 = 80;

// Card 6 — Blocked Keywords.
const k_block_h: i32 = 120;
const k_block_btn_y: i32 = 74;
const k_block_text_y: i32 = 80;

/// How far back the year combo reaches. The C++ hardcodes `2026 - y` for
/// thirteen rows; `Page.newest_year` takes the top row from the clock instead
/// so the list does not go stale next January. Today it is the same list.
const k_year_rows: i32 = 13;
const k_month_rows: i32 = 12;

const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

/// Everything the page needs from `Settings` for one frame. Synced by the
/// window right before relayout so paint, hit-test and the scroll height all
/// read the same values.
pub const Snapshot = struct {
    enabled: bool = false,
    daily_enabled: bool = false,
    download_path: []const u8 = "",
    blocked_keywords: []const u8 = "",
};

/// One Bing-tab press, translated into what the window must do. Everything
/// that is only session state has already moved by the time this is returned.
pub const Action = union(enum) {
    /// Session state moved; repaint is all that is needed.
    repaint,
    /// Persist `bing_enabled`.
    toggle_enabled,
    /// Persist `bing_daily_enabled` (the page already started the fetch).
    toggle_daily,
    /// Browse: window runs the (blocking) folder dialog.
    pick_folder,
    /// Edit...: window runs the keyword entry dialog and persists the answer.
    edit_keywords,
};

/// Content-column geometry, passed in rather than read from `Content` so this
/// module stays free of a cycle back into `ui_content`.
pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Every y the page draws at, in one struct. Derived once per frame so the
/// paint, the hit test and the scroll height cannot disagree about where the
/// Status card left off and the Blocked Keywords card begins.
pub const Layout = struct {
    /// Card column: inset 8 from the content edge, as every tab does.
    cx: i32,
    cw: i32,
    /// Text column inside a card (`kCardPad` in from each card edge).
    lx: i32,
    lw: i32,
    card_x: f64,
    card_w: f64,
    gen_top: i32,
    daily_top: i32,
    upd_top: i32,
    arch_top: i32,
    status_top: i32,
    block_top: i32,
    show_status: bool,
    /// Scroll extent, measured from `kContentTop`.
    total_h: i32,
};

fn layoutOf(g: Geo, show_status: bool) Layout {
    const cx = g.content_x + 8;
    const cw = g.content_w - 16;
    const block_top = if (show_status) k_status_top + k_status_h + k_card_gap else k_status_top;
    return .{
        .cx = cx,
        .cw = cw,
        .lx = cx + k_card_pad,
        .lw = cw - 2 * k_card_pad,
        .card_x = @floatFromInt(cx),
        .card_w = @floatFromInt(cw),
        .gen_top = k_gen_top,
        .daily_top = k_daily_top,
        .upd_top = k_upd_top,
        .arch_top = k_arch_top,
        .status_top = k_status_top,
        .block_top = block_top,
        .show_status = show_status,
        .total_h = block_top + k_block_h - k_content_top + 12,
    };
}

/// `toggle_geom` — the switch sits at the right of a 60 px band under the
/// card's title, 52x26, `kSpacingXL` in from the card edge.
fn toggleRect(l: *const Layout, card_top: i32) Rect {
    return .{
        .x = l.cx + l.cw - k_toggle_w - k_spacing_xl,
        .y = card_top + k_toggle_y,
        .w = k_toggle_w,
        .h = k_toggle_h,
    };
}

fn yearComboRect(l: *const Layout) Rect {
    return .{ .x = l.lx, .y = l.arch_top + k_arch_combo_y, .w = k_combo_w, .h = k_combo_h };
}

fn monthComboRect(l: *const Layout) Rect {
    return .{
        .x = l.lx + k_combo_w + k_spacing_xl,
        .y = l.arch_top + k_arch_combo_y,
        .w = k_combo_w,
        .h = k_combo_h,
    };
}

/// The open list hangs `kComboH + 2` below its trigger. Returns the row index
/// under the point, or -1 outside the list.
fn ddRowAt(trigger: Rect, rows: i32, px: f64, py: f64) i32 {
    const y0 = trigger.y + trigger.h + 2;
    const h = rows * k_dd_row_h;
    if (!common.pointInRect(px, py, .{ .x = trigger.x, .y = y0, .w = trigger.w, .h = h })) return -1;
    const r: i32 = @intFromFloat(@divTrunc(
        py - @as(f64, @floatFromInt(y0)),
        @as(f64, @floatFromInt(k_dd_row_h)),
    ));
    if (r < 0 or r >= rows) return -1;
    return r;
}

fn inRect(px: f64, py: f64, r: Rect) bool {
    return common.pointInRect(px, py, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}

fn basename(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}

/// `{d}` on a signed integer prints its sign, and "2026" must stay four
/// characters to compare against (and produce) a `YYYY-MM` archive key.
fn ymYear(year: i32) u16 {
    return @intCast(@max(0, @min(year, 9999)));
}

/// The same trap in the other half of the key: a signed month rendered as
/// `+3`. Both halves have to be unsigned for `YYYY-MM` to come out clean.
fn ymMonth(month: i32) u8 {
    return @intCast(std.math.clamp(month, 1, 12));
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/// How the last message should be tinted (`app.bingStatusType`).
const StatusKind = enum { none, idle, info, success, fail };

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    inited: bool = false,

    /// Values borrowed from `Settings` this frame (see `sync`).
    snap: Snapshot = .{},

    svc: bing_service.Service = undefined,
    /// The keyword string last handed to the worker, so a repaint does not
    /// push the same list through the mutex every frame.
    synced_keywords: []const u8 = &.{},
    /// Resolved download folder for when `download_path` is empty. Upstream
    /// passes the empty string straight through, which lands the files at the
    /// filesystem root; the path box already *displays*
    /// `~/Pictures/BingWallpaper` as the location, so that is what it uses.
    default_dir: []const u8 = &.{},

    // --- app.bing* session state -----------------------------------------
    is_checking: bool = false,
    is_downloading: bool = false,
    is_fetching_daily: bool = false,
    has_updates: bool = false,
    update_count: i32 = 0,
    progress_current: i32 = 0,
    progress_total: i32 = 0,
    found_in_archive: i32 = 0,
    downloaded_count: i32 = 0,
    skipped_count: i32 = 0,
    failed_count: i32 = 0,

    status_kind: StatusKind = .none,
    status_buf: [1024]u8 = undefined,
    status_len: u16 = 0,
    daily_buf: [1024]u8 = undefined,
    daily_len: u16 = 0,
    last_buf: [512]u8 = undefined,
    last_len: u16 = 0,
    /// `bingNewestAvailableDate`: the C++ keeps it but never draws it, so it
    /// is carried for parity rather than shown.
    newest_buf: [32]u8 = undefined,
    newest_len: u16 = 0,
    /// Transient buffer messages are composed in before `setStatus` copies
    /// them out; never read outside a `drain`/`paint` call.
    scratch: [2048]u8 = undefined,
    disp_buf: [512]u8 = undefined,

    show_blocked: bool = false,
    selected_year: i32 = 0,
    selected_month: i32 = 0,
    year_dd_open: bool = false,
    month_dd_open: bool = false,
    /// The newest year the combo offers, fixed at init from the clock.
    newest_year: i32 = 2026,

    pub fn init(self: *Page, alloc: std.mem.Allocator, io: std.Io) void {
        self.* = .{};
        self.alloc = alloc;
        self.io = io;
        self.svc = bing_service.Service.init(alloc, io);
        self.newest_year = local_time.today().year;
        const home = env("HOME");
        self.default_dir = archive.defaultDownloadDir(alloc, home) catch &.{};
        const d = local_time.today();
        self.selected_year = d.year;
        self.selected_month = d.month;
        self.inited = true;
    }

    pub fn deinit(self: *Page) void {
        if (!self.inited) return;
        self.svc.deinit();
        if (self.synced_keywords.len > 0) self.alloc.free(self.synced_keywords);
        self.synced_keywords = &.{};
        if (self.default_dir.len > 0) self.alloc.free(self.default_dir);
        self.default_dir = &.{};
        self.inited = false;
    }

    /// Borrow this frame's settings (the page's geometry and paint read `snap`,
    /// not `Settings`, to stay free of a cycle).
    pub fn sync(self: *Page, snap: Snapshot) void {
        self.snap = snap;
        if (std.mem.eql(u8, self.synced_keywords, snap.blocked_keywords)) return;
        if (self.synced_keywords.len > 0) self.alloc.free(self.synced_keywords);
        self.synced_keywords = self.alloc.dupe(u8, snap.blocked_keywords) catch &.{};
        self.svc.setKeywords(self.synced_keywords);
    }

    /// Pull everything the worker published since the last call and move it
    /// into session state. Returns the local path of a freshly fetched daily
    /// wallpaper when the caller should point the desktop at it.
    ///
    /// The C++ does this at the top of `paint_bing_tab`, i.e. as a side effect
    /// of drawing. Doing it where the window already syncs the page keeps that
    /// work independent of whether this tab is the one on screen, so a daily
    /// fetch that finishes while the user is reading another tab still applies.
    pub fn drain(self: *Page) ?[]const u8 {
        if (!self.inited) return null;
        self.svc.drainWake();
        var apply: ?[]const u8 = null;

        if (self.svc.takeProgress()) |pr| {
            self.progress_current = pr.current;
            self.progress_total = pr.total;
            self.found_in_archive = pr.found;
            if (pr.newestAvailable().len > 0) copyStr(&self.newest_buf, &self.newest_len, pr.newestAvailable());
            if (pr.lastDownloaded().len > 0) copyStr(&self.last_buf, &self.last_len, pr.lastDownloaded());
            self.is_downloading = true;
        }
        if (self.svc.takeDone()) |dd| {
            self.downloaded_count = dd.downloaded;
            self.skipped_count = dd.skipped;
            self.failed_count = dd.failed;
            self.is_downloading = false;
            self.is_checking = false;
            if (dd.ok and dd.downloaded > 0) {
                const word: []const u8 = if (dd.downloaded != 1) "wallpapers" else "wallpaper";
                self.setStatus(.success, fmt(&self.scratch, "Downloaded {d} {s}", .{ dd.downloaded, word }) catch "");
            } else if (dd.failed > 0) {
                const word: []const u8 = if (dd.failed != 1) "downloads" else "download";
                self.setStatus(.fail, fmt(&self.scratch, "{d} {s} failed", .{ dd.failed, word }) catch "");
            } else if (dd.skipped > 0) {
                self.setStatus(.success, fmt(&self.scratch, "All {d} already downloaded", .{dd.skipped}) catch "");
            } else {
                self.setStatus(.info, "Nothing to download");
            }
        }
        if (self.svc.takeUpdates()) |uc| {
            self.is_checking = false;
            self.update_count = uc.new_count;
            self.has_updates = uc.new_count > 0;
            if (uc.new_count > 0) {
                const word: []const u8 = if (uc.new_count != 1) "wallpapers" else "wallpaper";
                self.setStatus(.info, fmt(&self.scratch, "{d} new {s} available", .{ uc.new_count, word }) catch "");
            } else {
                self.setStatus(.success, "Already up to date");
            }
        }
        if (self.svc.takeDaily()) |dl| {
            self.is_fetching_daily = false;
            if (dl.ok) {
                const p = dl.localPath();
                copyStr(&self.daily_buf, &self.daily_len, p);
                self.setStatus(.success, fmt(
                    &self.scratch,
                    "Daily wallpaper: {s}",
                    .{basename(self.daily_buf[0..self.daily_len])},
                ) catch "");
                if (self.snap.daily_enabled) apply = self.daily_buf[0..self.daily_len];
            } else {
                self.setStatus(.fail, fmt(
                    &self.scratch,
                    "Daily wallpaper failed: {s}",
                    .{dl.errorMsg()},
                ) catch "");
            }
        }
        return apply;
    }

    /// True while a job is queued or running — what the disabled button states
    /// key on (`app.bingIsCheckingUpdates || IsDownloading || IsFetchingDaily`).
    pub fn busy(self: *const Page) bool {
        return self.is_checking or self.is_downloading or self.is_fetching_daily;
    }

    /// Whether the Status card exists this frame.
    fn showStatus(self: *const Page) bool {
        return self.busy() or self.status_len > 0;
    }

    pub fn statusText(self: *const Page) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn totalHeight(self: *Page, g: Geo) i32 {
        if (!self.inited) return g.win_h;
        return layoutOf(g, self.showStatus()).total_h;
    }

    /// The folder the worker writes into, falling back to the default when the
    /// user has never picked one.
    fn downloadDir(self: *const Page) []const u8 {
        if (self.snap.download_path.len > 0) return self.snap.download_path;
        return self.default_dir;
    }

    /// `~` when unset, otherwise the path elided at 38 characters the way the
    /// C++ does (`substr(0,35) + "..."`), without splitting a UTF-8 sequence.
    fn pathDisplay(self: *Page) []const u8 {
        const p = self.snap.download_path;
        if (p.len == 0) return "~/Pictures/BingWallpaper";
        if (p.len <= 38) return p;
        var cut: usize = 35;
        while (cut > 0 and (p[cut] & 0xC0) == 0x80) cut -= 1;
        return fmt(&self.disp_buf, "{s}...", .{p[0..cut]}) catch p;
    }

    fn setStatus(self: *Page, kind: StatusKind, msg: []const u8) void {
        self.status_kind = kind;
        copyStr(&self.status_buf, &self.status_len, msg);
    }

    // -- layout helpers used by paint and hit ------------------------------

    fn layout(self: *Page, g: Geo) Layout {
        return layoutOf(g, self.showStatus());
    }

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
        const t = common.Theme;
        const l = self.layout(g);
        const is_busy = self.busy();

        paintCard1(self, c, &l, px, py, glass_ov);
        paintCard2(self, c, &l, px, py, glass_ov);
        paintCard3(self, c, &l, px, py, glass_ov, is_busy);
        paintCard4(self, c, &l, px, py, glass_ov, is_busy);
        if (l.show_status) paintStatusCard(self, c, &l, glass_ov);
        paintCard6(self, c, &l, px, py, glass_ov);

        // Both dropdown lists last: they overhang their card, and the cards
        // below them would otherwise paint straight over the open rows.
        if (self.year_dd_open) paintYearRows(c, yearComboRect(&l), px, py, self.newest_year, t);
        if (self.month_dd_open) paintMonthRows(c, monthComboRect(&l), px, py, t);
    }

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        if (!self.inited) return null;
        const l = self.layout(g);
        const is_busy = self.busy();

        // Card 1 — General.
        if (inRect(px, ly, toggleRect(&l, l.gen_top))) return .toggle_enabled;
        const path_fw = l.lw - k_btn_w - k_spacing_m;
        if (inRect(px, ly, .{
            .x = l.lx + path_fw + k_spacing_m,
            .y = l.gen_top + k_gen_path_row,
            .w = k_btn_w,
            .h = k_btn_h,
        })) return .pick_folder;

        // Card 2 — Daily.
        if (inRect(px, ly, toggleRect(&l, l.daily_top))) {
            // Only launching when the toggle lands on ON,
            // which flips the setting first and then checks the new value.
            if (!self.snap.daily_enabled) self.startDaily(false);
            return .toggle_daily;
        }
        if (!self.is_fetching_daily and inRect(px, ly, .{
            .x = l.lx + l.lw - k_btn_w,
            .y = l.daily_top + k_daily_btn_row,
            .w = k_btn_w,
            .h = k_btn_h,
        })) {
            self.startDaily(true);
            return .repaint;
        }

        // Card 3 — Updates.
        if (!is_busy) {
            if (inRect(px, ly, .{
                .x = l.lx + l.lw - k_btn_w,
                .y = l.upd_top + k_upd_btn_row,
                .w = k_btn_w,
                .h = k_btn_h,
            })) {
                self.startCheck();
                return .repaint;
            }
            if (self.has_updates and inRect(px, ly, .{
                .x = l.lx + l.lw - 2 * k_btn_w - k_spacing_m,
                .y = l.upd_top + k_upd_btn_row,
                .w = k_btn_w,
                .h = k_btn_h,
            })) {
                _ = self.startDownload(.all, "");
                return .repaint;
            }
        }

        // Card 6 — Blocked Keywords (checked before the archive card, as in
        // the C++ handler).
        if (inRect(px, ly, .{
            .x = l.lx + l.lw - 2 * k_btn_w - k_spacing_m,
            .y = l.block_top + k_block_btn_y,
            .w = k_btn_w,
            .h = k_btn_h,
        })) {
            self.show_blocked = !self.show_blocked;
            return .repaint;
        }
        if (inRect(px, ly, .{
            .x = l.lx + l.lw - k_btn_w,
            .y = l.block_top + k_block_btn_y,
            .w = k_btn_w,
            .h = k_btn_h,
        })) return .edit_keywords;

        // Card 4 — Archive Download. Each list runs in the C++ order: the
        // trigger (toggling), then its rows, then fall through. Nothing here
        // dismisses a list on an outside press — the row test simply doesn't
        // match, so a press landing on a card *above* this one fires that card
        // and the list stays up, exactly as upstream does.
        const year_trig = yearComboRect(&l);
        if (inRect(px, ly, year_trig)) {
            self.year_dd_open = !self.year_dd_open;
            self.month_dd_open = false;
            return .repaint;
        }
        if (self.year_dd_open) {
            const yr = ddRowAt(year_trig, k_year_rows, px, ly);
            if (yr >= 0) {
                self.selected_year = self.newest_year - yr;
                self.year_dd_open = false;
                return .repaint;
            }
        }
        const month_trig = monthComboRect(&l);
        if (inRect(px, ly, month_trig)) {
            self.month_dd_open = !self.month_dd_open;
            self.year_dd_open = false;
            return .repaint;
        }
        if (self.month_dd_open) {
            const mr = ddRowAt(month_trig, k_month_rows, px, ly);
            if (mr >= 0) {
                self.selected_month = mr + 1;
                self.month_dd_open = false;
                return .repaint;
            }
        }
        if (!is_busy and inRect(px, ly, .{
            .x = l.lx + l.lw - k_dl_btn_w,
            .y = l.arch_top + k_arch_dl_row,
            .w = k_dl_btn_w,
            .h = k_btn_h,
        })) {
            var mb: [8]u8 = undefined;
            const month = fmt(&mb, "{d:0>4}-{d:0>2}", .{
                ymYear(self.selected_year),
                ymMonth(self.selected_month),
            }) catch "";
            _ = self.startDownload(.custom, month);
            return .repaint;
        }

        return null;
    }

    // -- launches (all page-owned: they only touch session state) ----------

    fn startCheck(self: *Page) void {
        if (!self.svc.checkUpdatesAsync(self.downloadDir())) return;
        self.is_checking = true;
        self.setStatus(.idle, "Checking for updates...");
    }

    fn startDaily(self: *Page, use_cache: bool) void {
        if (!self.svc.dailyAsync(self.downloadDir(), use_cache)) return;
        self.is_fetching_daily = true;
        self.setStatus(.idle, "Fetching daily wallpaper...");
    }

    fn startDownload(self: *Page, filter: archive.Filter, month: []const u8) bool {
        if (!self.svc.downloadAsync(self.downloadDir(), filter, month)) return false;
        self.is_downloading = true;
        self.progress_current = 0;
        self.progress_total = 0;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

fn paintCardTitle(c: anytype, l: *const Layout, top: i32, title: []const u8, desc: []const u8, t: anytype) void {
    ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(top + k_title_y), title, 14, 500, t.text_r, t.text_g, t.text_b, 0.93);
    ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(top + k_desc_y), desc, 11, 400, t.text_r, t.text_g, t.text_b, 0.46);
}

fn paintCard1(
    self: *Page,
    c: anytype,
    l: *const Layout,
    px: f64,
    py: f64,
    glass_ov: f64,
) void {
    const t = common.Theme;
    ui_paint.card(c, l.card_x, @floatFromInt(l.gen_top), l.card_w, @floatFromInt(k_gen_h), glass_ov);
    paintCardTitle(c, l, l.gen_top, "General", "Download wallpapers from the Bing archive", t);

    const tg = toggleRect(l, l.gen_top);
    paintSwitch(c, tg.x, tg.y, tg.w, tg.h, self.snap.enabled);

    // `settings_label` — a single 15 px line, no description.
    ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(k_gen_label_y + l.gen_top + 1), "Save location", 15, 400, t.text_r, t.text_g, t.text_b, 0.93);

    const path_y = l.gen_top + k_gen_path_row;
    const path_fw = l.lw - k_btn_w - k_spacing_m;
    ui_paint.roundRect(
        c,
        @floatFromInt(l.lx),
        @floatFromInt(path_y),
        @floatFromInt(path_fw),
        @floatFromInt(k_btn_h),
        6,
    );
    cairo.cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.30);
    cairo.cairo_fill(c);

    // The C++ centres this one by hand (top-anchored translate), so centre it
    // against the measured line height rather than the `showText` baseline.
    const disp = self.pathDisplay();
    const th = ui_paint.textSizePx(c, disp, 11, 400).h;
    ui_paint.showText(
        c,
        @floatFromInt(l.lx + k_spacing_s),
        @floatFromInt(path_y + @divTrunc(k_btn_h - th, 2) + th - 2),
        disp,
        11,
        400,
        t.text_r,
        t.text_g,
        t.text_b,
        1.0,
    );

    const bx = l.lx + path_fw + k_spacing_m;
    paintBtn(
        c,
        bx,
        path_y,
        k_btn_w,
        k_btn_h,
        "Browse",
        inRect(px, py, .{ .x = bx, .y = path_y, .w = k_btn_w, .h = k_btn_h }),
        t,
    );
}

fn paintCard2(self: *Page, c: anytype, l: *const Layout, px: f64, py: f64, glass_ov: f64) void {
    const t = common.Theme;
    ui_paint.card(c, l.card_x, @floatFromInt(l.daily_top), l.card_w, @floatFromInt(k_daily_h), glass_ov);
    paintCardTitle(
        c,
        l,
        l.daily_top,
        "Daily Wallpaper",
        "Automatically fetch and set today's Bing wallpaper",
        t,
    );

    const tg = toggleRect(l, l.daily_top);
    paintSwitch(c, tg.x, tg.y, tg.w, tg.h, self.snap.daily_enabled);

    const btn = Rect{
        .x = l.lx + l.lw - k_btn_w,
        .y = l.daily_top + k_daily_btn_row,
        .w = k_btn_w,
        .h = k_btn_h,
    };
    if (self.is_fetching_daily) {
        paintBtnDisabled(c, btn.x, btn.y, btn.w, btn.h, "Fetching...", t);
    } else {
        paintBtn(c, btn.x, btn.y, btn.w, btn.h, "Fetch Now", inRect(px, py, btn), t);
    }

    if (self.daily_len > 0 and !self.is_fetching_daily) {
        ui_paint.showText(
            c,
            @floatFromInt(l.lx),
            @floatFromInt(l.daily_top + k_daily_file_row),
            basename(self.daily_buf[0..self.daily_len]),
            10,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.70,
        );
    }
}

fn paintCard3(
    self: *Page,
    c: anytype,
    l: *const Layout,
    px: f64,
    py: f64,
    glass_ov: f64,
    busy: bool,
) void {
    const t = common.Theme;
    ui_paint.card(c, l.card_x, @floatFromInt(l.upd_top), l.card_w, @floatFromInt(k_upd_h), glass_ov);
    paintCardTitle(c, l, l.upd_top, "Updates", "Check for new wallpapers", t);

    const info_y = l.upd_top + k_upd_info_row;
    if (self.is_checking) {
        ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(info_y), "Checking for updates...", 12, 400, t.text_r, t.text_g, t.text_b, 0.80);
    } else if (self.has_updates) {
        const word: []const u8 = if (self.update_count != 1) "wallpapers" else "wallpaper";
        const msg = fmt(&self.scratch, "{d} new {s} available", .{ self.update_count, word }) catch "";
        ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(info_y), msg, 12, 400, 0.40, 0.85, 0.40, 0.85);
    }

    const check = Rect{
        .x = l.lx + l.lw - k_btn_w,
        .y = l.upd_top + k_upd_btn_row,
        .w = k_btn_w,
        .h = k_btn_h,
    };
    if (busy) paintBtnDisabled(c, check.x, check.y, check.w, check.h, "Check Now", t) else {
        paintBtn(c, check.x, check.y, check.w, check.h, "Check Now", inRect(px, py, check), t);
    }
    if (self.has_updates) {
        const dl = Rect{
            .x = l.lx + l.lw - 2 * k_btn_w - k_spacing_m,
            .y = l.upd_top + k_upd_btn_row,
            .w = k_btn_w,
            .h = k_btn_h,
        };
        if (busy) paintBtnDisabled(c, dl.x, dl.y, dl.w, dl.h, "Download All", t) else {
            paintBtn(c, dl.x, dl.y, dl.w, dl.h, "Download All", inRect(px, py, dl), t);
        }
    }
}

fn yearLabel(self: *Page) []const u8 {
    return fmt(&self.disp_buf, "{d}", .{self.selected_year}) catch "";
}

fn monthLabel(self: *Page) []const u8 {
    const i = std.math.clamp(self.selected_month - 1, 0, 11);
    return month_names[@intCast(i)];
}

fn paintCard4(
    self: *Page,
    c: anytype,
    l: *const Layout,
    px: f64,
    py: f64,
    glass_ov: f64,
    busy: bool,
) void {
    const t = common.Theme;
    ui_paint.card(c, l.card_x, @floatFromInt(l.arch_top), l.card_w, @floatFromInt(k_arch_h), glass_ov);
    paintCardTitle(
        c,
        l,
        l.arch_top,
        "Archive Download",
        "Download wallpapers from past months",
        t,
    );

    ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(l.arch_top + k_arch_label_y + 1), "Year", 15, 400, t.text_r, t.text_g, t.text_b, 0.93);
    const month_x = l.lx + k_combo_w + k_spacing_xl;
    ui_paint.showText(c, @floatFromInt(month_x), @floatFromInt(l.arch_top + k_arch_label_y + 1), "Month", 15, 400, t.text_r, t.text_g, t.text_b, 0.93);

    const yt = yearComboRect(l);
    paintCombo(c, yt, yearLabel(self), inRect(px, py, yt), t);
    const mt = monthComboRect(l);
    paintCombo(c, mt, monthLabel(self), inRect(px, py, mt), t);

    const dl = Rect{
        .x = l.lx + l.lw - k_dl_btn_w,
        .y = l.arch_top + k_arch_dl_row,
        .w = k_dl_btn_w,
        .h = k_btn_h,
    };
    const lab = fmt(&self.scratch, "{s} {d}", .{ monthLabel(self), self.selected_year }) catch "";
    if (busy) paintBtnDisabled(c, dl.x, dl.y, dl.w, dl.h, lab, t) else {
        paintBtn(c, dl.x, dl.y, dl.w, dl.h, lab, inRect(px, py, dl), t);
    }
}

fn paintStatusCard(self: *Page, c: anytype, l: *const Layout, glass_ov: f64) void {
    const t = common.Theme;
    const st = l.status_top;
    ui_paint.card(c, l.card_x, @floatFromInt(st), l.card_w, @floatFromInt(k_status_h), glass_ov);
    paintCardTitle(c, l, st, "Status", "Current activity and results", t);

    const label_y = st + k_status_label_y;
    const msg = self.statusText();
    if (msg.len > 0) {
        var r = t.text_r;
        var g = t.text_g;
        var b = t.text_b;
        var a: f64 = 1.0;
        switch (self.status_kind) {
            .fail => {
                r = 0.90;
                g = 0.30;
                b = 0.30;
                a = 0.85;
            },
            .success => {
                r = 0.40;
                g = 0.85;
                b = 0.40;
                a = 0.85;
            },
            else => {},
        }
        ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(label_y), msg, 11, 400, r, g, b, a);
    } else if (self.is_checking) {
        ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(label_y), "Checking for updates...", 11, 400, t.text_r, t.text_g, t.text_b, 1.0);
    } else if (self.is_fetching_daily) {
        ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(label_y), "Fetching daily wallpaper...", 11, 400, t.text_r, t.text_g, t.text_b, 1.0);
    }

    if (!self.is_downloading) return;

    const pbar_y = label_y + k_spacing_m + 4;
    const pbar_w = l.lw - 2 * k_card_pad;
    const pbar_h: i32 = 8;

    // The C++ truncates a double division here rather than scaling the
    // integers first, so 7/10 reads 69% there; keep the readout identical.
    const pct: []const u8 = if (self.progress_total > 0)
        fmt(&self.scratch, "{d} / {d}  ({d}%)", .{
            self.progress_current,
            self.progress_total,
            @as(i32, @intFromFloat(
                @as(f64, @floatFromInt(self.progress_current)) /
                    @as(f64, @floatFromInt(self.progress_total)) * 100.0,
            )),
        }) catch ""
    else
        "Fetching list...";
    ui_paint.showText(c, @floatFromInt(l.lx), @floatFromInt(pbar_y - k_spacing_s), pct, 10, 400, t.text_r, t.text_g, t.text_b, 1.0);

    ui_paint.roundRect(
        c,
        @floatFromInt(l.lx),
        @floatFromInt(pbar_y),
        @floatFromInt(pbar_w),
        @floatFromInt(pbar_h),
        @as(f64, pbar_h) * 0.5,
    );
    cairo.cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.20);
    cairo.cairo_fill(c);

    const fill: f64 = if (self.progress_total > 0)
        std.math.clamp(@as(f64, @floatFromInt(self.progress_current)) /
            @as(f64, @floatFromInt(self.progress_total)), 0.0, 1.0)
    else
        0.3;
    const alpha: f64 = if (self.progress_total > 0) 0.70 else 0.50;
    if (fill > 0.0) {
        ui_paint.roundRect(
            c,
            @floatFromInt(l.lx),
            @floatFromInt(pbar_y),
            @floatFromInt(@as(i32, @intFromFloat(@as(f64, @floatFromInt(pbar_w)) * fill))),
            @floatFromInt(pbar_h),
            @as(f64, pbar_h) * 0.5,
        );
        cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, alpha);
        cairo.cairo_fill(c);
    }

    if (self.last_len > 0) {
        ui_paint.showText(
            c,
            @floatFromInt(l.lx),
            @floatFromInt(pbar_y + pbar_h + k_spacing_m + 4),
            self.last_buf[0..self.last_len],
            9,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.70,
        );
    }
}

fn paintCard6(self: *Page, c: anytype, l: *const Layout, px: f64, py: f64, glass_ov: f64) void {
    const t = common.Theme;
    const top = l.block_top;
    ui_paint.card(c, l.card_x, @floatFromInt(top), l.card_w, @floatFromInt(k_block_h), glass_ov);
    paintCardTitle(
        c,
        l,
        top,
        "Blocked Keywords",
        "Wallpapers matching these words will be skipped",
        t,
    );

    const kw = self.snap.blocked_keywords;
    const display: []const u8 = if (kw.len == 0)
        "(none)"
    else if (self.show_blocked)
        kw
    else blk: {
        // Reuse the display buffer: it is not needed again this frame, and a
        // stack array could not be returned from here anyway.
        const n = @min(kw.len, self.disp_buf.len);
        @memset(self.disp_buf[0..n], '*');
        break :blk self.disp_buf[0..n];
    };
    // Upstream passes `kBingW - kBtnW*2 - kSpacingM*2` (344) in the *weight*
    // position of `settings_show_text`, so the C++ renders this line in a
    // near-Light face while every other 11 px line on the tab is Regular.
    // That is a mis-passed max-width, not a style choice, so this keeps the
    // Regular weight the rest of the card uses.
    ui_paint.showText(
        c,
        @floatFromInt(l.lx),
        @floatFromInt(top + k_block_text_y),
        display,
        11,
        400,
        t.text_r,
        t.text_g,
        t.text_b,
        1.0,
    );

    const show = Rect{
        .x = l.lx + l.lw - 2 * k_btn_w - k_spacing_m,
        .y = top + k_block_btn_y,
        .w = k_btn_w,
        .h = k_btn_h,
    };
    const edit = Rect{
        .x = l.lx + l.lw - k_btn_w,
        .y = top + k_block_btn_y,
        .w = k_btn_w,
        .h = k_btn_h,
    };
    paintBtn(c, show.x, show.y, show.w, show.h, if (self.show_blocked) "Hide" else "Show", inRect(px, py, show), t);
    paintBtn(c, edit.x, edit.y, edit.w, edit.h, "Edit...", inRect(px, py, edit), t);
}

/// The open list under a trigger: one 26 px row box each, the row under the
/// pointer a shade brighter. `labelAt` turns the row index into its text.
fn paintDdRows(
    c: anytype,
    trig: Rect,
    rows: i32,
    px: f64,
    py: f64,
    labelAt: *const fn (ctx: ?*anyopaque, i: i32, buf: []u8) []const u8,
    ctx: ?*anyopaque,
    t: anytype,
) void {
    const y0 = trig.y + trig.h + 2;
    const hover = ddRowAt(trig, rows, px, py);
    for (0..@as(usize, @intCast(rows))) |i| {
        const idx: i32 = @intCast(i);
        const ry = y0 + idx * k_dd_row_h;
        ui_paint.roundRect(
            c,
            @floatFromInt(trig.x),
            @floatFromInt(ry),
            @floatFromInt(trig.w),
            @floatFromInt(k_dd_row_h),
            4,
        );
        cairo.cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, if (idx == hover) 0.60 else 0.45);
        cairo.cairo_fill(c);
        var buf: [8]u8 = undefined;
        const lab = labelAt(ctx, idx, &buf);
        ui_paint.showText(
            c,
            @floatFromInt(trig.x + k_spacing_s),
            @floatFromInt(ry + @divTrunc(k_dd_row_h, 2)),
            lab,
            12,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            1.0,
        );
    }
}

const YearRows = struct { newest: i32 };

fn yearRowAt(ctx: ?*anyopaque, i: i32, buf: []u8) []const u8 {
    const y: *YearRows = @ptrCast(@alignCast(ctx.?));
    return std.fmt.bufPrint(buf, "{d}", .{y.newest - i}) catch "";
}

fn paintYearRows(c: anytype, trig: Rect, px: f64, py: f64, newest: i32, t: anytype) void {
    var y: YearRows = .{ .newest = newest };
    paintDdRows(c, trig, k_year_rows, px, py, yearRowAt, @ptrCast(&y), t);
}

fn monthRowAt(ctx: ?*anyopaque, i: i32, buf: []u8) []const u8 {
    _ = ctx;
    _ = buf;
    return month_names[@intCast(i)];
}

fn paintMonthRows(c: anytype, trig: Rect, px: f64, py: f64, t: anytype) void {
    paintDdRows(c, trig, k_month_rows, px, py, monthRowAt, null, t);
}

// -- small controls (local copies of the C++ lambdas in `paint_bing_tab`) --

/// `m3::Button` Outlined/XS: glass pill, accent label, accent-weight outline.
fn paintBtn(c: anytype, x: i32, y: i32, w: i32, h: i32, label: []const u8, hovered: bool, t: anytype) void {
    btnBody(c, x, y, w, h, label, hovered, false, t);
}

/// Same button with `setEnabled(false)`: no hover response, dimmer label.
fn paintBtnDisabled(c: anytype, x: i32, y: i32, w: i32, h: i32, label: []const u8, t: anytype) void {
    btnBody(c, x, y, w, h, label, false, true, t);
}

fn btnBody(
    c: anytype,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    label: []const u8,
    hovered: bool,
    disabled: bool,
    t: anytype,
) void {
    if (w <= 0 or h <= 0) return;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    const rad = @min(wf, hf) * 0.5;
    const hover = hovered and !disabled;
    ui_paint.glassBox(c, xf, yf, wf, hf, rad, 1, 1, 1, if (hover) 0.12 else 0.06);
    cairo.cairo_save(c);
    ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, @max(0.5, rad - 0.5));
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (disabled) 0.30 else if (hover) 0.9 else 0.6);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);

    const font_px: f32 = 12;
    const ts = ui_paint.textSizePx(c, label, font_px, 500);
    const tw_f: f64 = @floatFromInt(ts.w);
    const th_f: f64 = @floatFromInt(ts.h);
    const top = yf + (hf - th_f) / 2.0;
    ui_paint.showText(
        c,
        xf + (wf - tw_f) / 2.0,
        top + th_f - 2.0,
        label,
        font_px,
        500,
        t.acc_r,
        t.acc_g,
        t.acc_b,
        if (disabled) 0.35 else 1.0,
    );
}

/// `settings_paint_combo_closed` — glass pill with a chevron.
fn paintCombo(c: anytype, r: Rect, text: []const u8, hovered: bool, t: anytype) void {
    const xf: f64 = @floatFromInt(r.x);
    const yf: f64 = @floatFromInt(r.y);
    const wf: f64 = @floatFromInt(r.w);
    const hf: f64 = @floatFromInt(r.h);
    ui_paint.glassBox(c, xf, yf, wf, hf, 8, 1, 1, 1, if (hovered) 0.14 else 0.06);
    cairo.cairo_save(c);
    ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, 7.5);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (hovered) 0.95 else 0.6);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
    cairo.cairo_save(c);
    cairo.cairo_rectangle(c, xf + 8, yf + 2, wf - 30, hf - 4);
    cairo.cairo_clip(c);
    ui_paint.showText(c, xf + 12, yf + hf - 8.0, text, 12, 400, t.text_r, t.text_g, t.text_b, 0.92);
    cairo.cairo_restore(c);
    ui_paint.glyph(c, xf + wf - 14.0, yf + hf / 2.0, 16, "expand_more", t.text_r, t.text_g, t.text_b, 0.7);
}

/// `settings_switch` — pill track with a sliding knob.
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
        cairo.cairo_save(c);
        ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, hf / 2.0 - 0.5);
        cairo.cairo_set_line_width(c, 1.4);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.8);
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);
    }
    const knob_r: f64 = if (on) hf * 0.42 else hf * 0.34;
    const kx = if (on) xf + wf - hf * 0.5 else xf + hf * 0.5;
    ui_paint.glassBox(c, kx - knob_r, yf + hf / 2.0 - knob_r, knob_r * 2, knob_r * 2, knob_r, 1, 1, 1, 1.0);
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn copyStr(dst: []u8, len: *u16, src: []const u8) void {
    const n: u16 = @intCast(@min(src.len, dst.len));
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(buf, f, args);
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bing-tab: card tops follow the specified constants" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 16), k_gen_top);
    try t.expectEqual(@as(i32, 196), k_daily_top);
    try t.expectEqual(@as(i32, 374), k_upd_top);
    try t.expectEqual(@as(i32, 550), k_arch_top);
    try t.expectEqual(@as(i32, 802), k_status_top);
    try t.expectEqual(@as(i32, 802), layoutOf(.{ .content_x = 0, .content_w = 600, .win_h = 900 }, false).block_top);
    try t.expectEqual(@as(i32, 954), layoutOf(.{ .content_x = 0, .content_w = 600, .win_h = 900 }, true).block_top);
}

test "bing-tab: the status card grows the scroll extent" {
    const t = std.testing;
    const g = Geo{ .content_x = 0, .content_w = 600, .win_h = 900 };
    const quiet = layoutOf(g, false);
    const busy_l = layoutOf(g, true);
    try t.expectEqual(k_status_h + k_card_gap, busy_l.total_h - quiet.total_h);
    // The whole stack is taller than a 900 px window, which is why the page
    // reports its own height instead of the view's.
    try t.expect(quiet.total_h > g.win_h);
    try t.expectEqual(@as(i32, 954 + k_block_h - k_content_top + 12), busy_l.total_h);
}

test "bing-tab: the content column is inset from the card column" {
    const t = std.testing;
    const l = layoutOf(.{ .content_x = 100, .content_w = 600, .win_h = 900 }, false);
    try t.expectEqual(@as(i32, 108), l.cx);
    try t.expectEqual(@as(i32, 584), l.cw);
    try t.expectEqual(@as(i32, 124), l.lx);
    try t.expectEqual(@as(i32, 552), l.lw);
}

test "bing-tab: the toggle sits under the card title at the right edge" {
    const t = std.testing;
    const l = layoutOf(.{ .content_x = 100, .content_w = 600, .win_h = 900 }, false);
    const tg = toggleRect(&l, l.gen_top);
    try t.expectEqual(@as(i32, 108 + 584 - 52 - 24), tg.x);
    try t.expectEqual(@as(i32, k_gen_top + k_toggle_y), tg.y);
    try t.expectEqual(@as(i32, 52), tg.w);
    try t.expectEqual(@as(i32, 26), tg.h);
}

test "bing-tab: dropdown rows land under their trigger" {
    const t = std.testing;
    const trig = Rect{ .x = 100, .y = 600, .w = k_combo_w, .h = k_combo_h };
    try t.expectEqual(@as(i32, -1), ddRowAt(trig, k_year_rows, 100, 627));
    try t.expectEqual(@as(i32, 0), ddRowAt(trig, k_year_rows, 100, 631));
    try t.expectEqual(@as(i32, 1), ddRowAt(trig, k_year_rows, 100, 631 + k_dd_row_h));
    // The last row ends exactly at the list's bottom edge.
    try t.expectEqual(
        @as(i32, k_year_rows - 1),
        ddRowAt(trig, k_year_rows, 100, 631 + (k_year_rows - 1) * k_dd_row_h),
    );
    try t.expectEqual(@as(i32, -1), ddRowAt(trig, k_year_rows, 100, 631 + k_year_rows * k_dd_row_h));
    try t.expectEqual(@as(i32, -1), ddRowAt(trig, k_year_rows, 300, 631));
}

test "bing-tab: the year list walks back from the newest year" {
    const t = std.testing;
    var p: Page = .{};
    p.newest_year = 2026;
    p.selected_year = 2026;
    p.selected_month = 10;
    // Row 0 is the newest year, row n walks backwards — the C++ is
    // `2026 - y`, so the third row is 2024.
    try t.expectEqual(@as(i32, 2026), p.newest_year - 0);
    try t.expectEqual(@as(i32, 2024), p.newest_year - 2);
    try t.expectEqual(@as(i32, 2014), p.newest_year - (k_year_rows - 1));
    // A month picked from the list is 1-based, and its archive key is
    // `YYYY-MM` with no sign on either number — `{d}` on a signed int would
    // render "2026-+3", a filter that matches nothing.
    p.selected_month = 3;
    var mb: [8]u8 = undefined;
    const key = try std.fmt.bufPrint(&mb, "{d:0>4}-{d:0>2}", .{ ymYear(p.selected_year), ymMonth(p.selected_month) });
    try t.expectEqualStrings("2026-03", key);
    try t.expectEqual(@as(usize, 7), key.len);
}

test "bing-tab: status messages keep their plural and their tint" {
    const t = std.testing;
    var p: Page = .{};
    p.setStatus(.success, "Downloaded 3 wallpapers");
    try t.expectEqualStrings("Downloaded 3 wallpapers", p.statusText());
    try t.expectEqual(StatusKind.success, p.status_kind);
    p.setStatus(.fail, "1 download failed");
    try t.expectEqual(StatusKind.fail, p.status_kind);
    // Idle is what an operation reports when it starts, and it must not read
    // as either a success or a failure.
    p.setStatus(.idle, "Checking for updates...");
    try t.expectEqual(StatusKind.idle, p.status_kind);
    // Clearing works: an empty message removes the Status card entirely.
    p.setStatus(.none, "");
    try t.expectEqual(@as(usize, 0), p.statusText().len);
}

test "bing-tab: a truncated path keeps its ellipsis and its codepoints" {
    const t = std.testing;
    var p: Page = .{};
    p.snap.download_path = "";
    try t.expectEqualStrings("~/Pictures/BingWallpaper", p.pathDisplay());

    p.snap.download_path = "/home/u/Pictures/BingWallpaper";
    try t.expectEqualStrings("/home/u/Pictures/BingWallpaper", p.pathDisplay());

    var long: [64]u8 = undefined;
    @memset(&long, 'a');
    p.snap.download_path = &long;
    const disp = p.pathDisplay();
    try t.expect(disp.len <= 38);
    try t.expect(std.mem.endsWith(u8, disp, "..."));
    try t.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++ "aaaa...", disp);
}

test "bing-tab: the download folder falls back to the default" {
    const t = std.testing;
    var p: Page = .{};
    p.default_dir = "/home/u/Pictures/BingWallpaper";
    p.snap.download_path = "";
    try t.expectEqualStrings("/home/u/Pictures/BingWallpaper", p.downloadDir());
    p.snap.download_path = "/mnt/data/bing";
    try t.expectEqualStrings("/mnt/data/bing", p.downloadDir());
}

test "bing-tab: results move into session state and a daily apply is offered" {
    const t = std.testing;
    var p: Page = .{};
    p.svc = bing_service.Service.init(t.allocator, std.testing.io);
    defer p.svc.deinit();
    p.inited = true;
    // Nothing published: no daily apply, no status.
    try t.expect(p.drain() == null);

    // Stand in for the worker publishing a done result.
    p.is_checking = true;
    p.setStatus(.idle, "Checking for updates...");
    p.svc.running = true;
    p.svc.updates = .{ .ok = true, .new_count = 4 };
    p.svc.running = false;
    _ = p.drain();
    try t.expect(!p.is_checking);
    try t.expect(p.has_updates);
    try t.expectEqual(@as(i32, 4), p.update_count);
    try t.expectEqualStrings("4 new wallpapers available", p.statusText());
    try t.expectEqual(StatusKind.info, p.status_kind);
}

// `handle_bing_click` tests the year/month trigger and its row loop only
// inside Card 4 — the last card — and never dismisses a list on a press that
// lands elsewhere: the row test misses, the loop falls through, and the list
// stays up. So with the year list open a press on an earlier card fires that
// card and leaves the list open. Neither the ordering nor the fall-through was
// previously pinned by a test.
test "bing-tab: an open list only owns presses inside Card 4" {
    const t = std.testing;
    var p: Page = .{};
    p.svc = bing_service.Service.init(t.allocator, std.testing.io);
    defer p.svc.deinit();
    p.inited = true;
    p.newest_year = 2026;
    p.selected_year = 2026;
    p.selected_month = 10;

    const g: Geo = .{ .content_x = 100, .content_w = 600, .win_h = 900 };
    // Nothing busy and no status set, so `showStatus()` is false and there is
    // no Status card shifting the Blocked Keywords card down.
    const l = layoutOf(g, false);
    const year_trig = yearComboRect(&l);
    const month_trig = monthComboRect(&l);
    const mid = struct {
        fn of(r: Rect) [2]f64 {
            return .{ @floatFromInt(r.x + @divTrunc(r.w, 2)), @floatFromInt(r.y + @divTrunc(r.h, 2)) };
        }
    }.of;

    // Card 1's toggle fires straight through an open list, which stays up.
    p.year_dd_open = true;
    const tg = mid(toggleRect(&l, l.gen_top));
    try t.expectEqual(Action.toggle_enabled, p.hit(g, tg[0], tg[1]).?);
    try t.expect(p.year_dd_open);

    // Card 6's Show button too: the list overhangs to y 1036 and the button
    // sits at y 876 inside that band, but Card 6 is checked first and the
    // button's column is outside the list's, so it fires and the list stays.
    p.year_dd_open = true;
    p.show_blocked = false;
    const sw = mid(.{
        .x = l.lx + l.lw - 2 * k_btn_w - k_spacing_m,
        .y = l.block_top + k_block_btn_y,
        .w = k_btn_w,
        .h = k_btn_h,
    });
    try t.expectEqual(Action.repaint, p.hit(g, sw[0], sw[1]).?);
    try t.expect(p.show_blocked);
    try t.expect(p.year_dd_open);
    p.show_blocked = false;

    // The list's own trigger toggles it shut — the C++ writes `!`.
    p.year_dd_open = true;
    const yt = mid(year_trig);
    try t.expectEqual(Action.repaint, p.hit(g, yt[0], yt[1]).?);
    try t.expect(!p.year_dd_open);

    // A row picks that year and closes the list. Row 2 is the third newest.
    p.year_dd_open = true;
    const row_y: f64 = @floatFromInt(year_trig.y + year_trig.h + 2 + 2 * k_dd_row_h + @divTrunc(k_dd_row_h, 2));
    try t.expectEqual(Action.repaint, p.hit(g, @floatFromInt(year_trig.x + 60), row_y).?);
    try t.expectEqual(@as(i32, 2024), p.selected_year);
    try t.expect(!p.year_dd_open);

    // Fall-through within Card 4: with the year list open the month trigger
    // still opens its own list and closes the year one, because the year row
    // test above it misses rather than returning.
    p.year_dd_open = true;
    p.month_dd_open = false;
    const mt = mid(month_trig);
    try t.expectEqual(Action.repaint, p.hit(g, mt[0], mt[1]).?);
    try t.expect(p.month_dd_open);
    try t.expect(!p.year_dd_open);

    // A press that matches nothing anywhere leaves the list up: nothing in the
    // handler dismisses it on an outside press.
    p.year_dd_open = true;
    p.month_dd_open = false;
    try t.expect(p.hit(g, 140, 400) == null);
    try t.expect(p.year_dd_open);
}
