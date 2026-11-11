//! The Updates page (tab 51) — the redesign in
//! `Updater/event-horizon-updates.html`.
//!
//! Like the Bing and Wallpaper tabs this is a *page*, not a card list:
//! `ui_content.Content` has no rows for tab 51 and delegates paint, hit-test
//! and scroll height here. Three stacked cards plus a footer line:
//!
//!   Hero       orb, title/subtitle, version pair, the four-step bar, the
//!              contextual note and the action row
//!   Notes      the latest release body, collapsed by default when there is
//!              nothing new to show
//!   Prefs      auto-check toggle and the frequency segmented control
//!
//! The worker lives in `updater_service.zig`; this file owns only session
//! state (which screen of the flow is up, the progress fraction, the release
//! text) and the geometry both the painter and the hit test read, so they
//! cannot disagree.

const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const decode = @import("../../wallpaper/decode.zig");
const version = @import("../../version.zig");
const updater = @import("updater_service.zig");

/// The app icon the hero card shows, embedded so the page does not depend on
/// the icon theme being installed or on the executable's working directory.
const logo_png = @embedFile("../../resources/icons/292896733.png");

/// The sidebar tab this page owns (`app.zig` rail entry, `rows.zig` 51).
pub const tab_id: i32 = 51;

const k_content_top: i32 = common.content_top;
const k_card_pad: i32 = common.card_pad;
const k_card_gap: i32 = common.card_gap;
const k_spacing_s: i32 = common.spacing_s;
const k_spacing_m: i32 = common.spacing_m;
const k_spacing_l: i32 = common.spacing_l;

const k_hero_h: i32 = 236;
const k_notes_h_open: i32 = 214;
const k_notes_h_closed: i32 = 80;
const k_prefs_h: i32 = 84;

const k_btn_h: i32 = 34;
const k_primary_w: i32 = 186;
const k_secondary_w: i32 = 132;
const k_toggle_w: i32 = 40;
const k_toggle_h: i32 = 24;
const k_seg_btn_w: i32 = 44;
const k_seg_h: i32 = 28;

/// Offsets inside the hero card.
const k_orb_x: i32 = 22;
const k_orb_y: i32 = 18;
const k_orb_size: i32 = 52;
const k_title_y: i32 = 40;
const k_sub_y: i32 = 62;
const k_steps_y: i32 = 94;
const k_step_label_y: i32 = 118;
const k_note_y: i32 = 140;
const k_note_h: i32 = 38;
const k_actions_y: i32 = 186;

const k_step_gap: i32 = 8;
const k_step_names = [4][]const u8{ "Check", "Download", "Install", "Restart" };
const k_freq_hours = [4]u8{ 1, 3, 6, 24 };

/// Which screen of the flow is up. `failed` carries the message the worker
/// published in `err_buf`.
pub const State = enum { never, checking, uptodate, available, downloading, ready, installing, restart, failed };

const StepState = enum { pending, done, active };

pub const Snapshot = struct {
    /// `Settings.updater_auto_check`, persisted in `general/general.toml`.
    auto_check: bool = true,
    /// `Settings.updater_check_hours`: 1, 3, 6 or 24.
    check_hours: u8 = 6,
};

/// One press, translated into what the window must persist or run. Anything
/// that is purely session state (starting a worker job, collapsing the notes)
/// has already moved by the time this is returned.
pub const Action = union(enum) {
    repaint,
    /// Persist `updater_auto_check`.
    toggle_auto,
    /// Persist `updater_check_hours`.
    set_freq: u8,
    /// Restart the supervisor (stops and starts `horizon`).
    restart,
    /// Open the release page in the browser.
    open_releases,
};

pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

const Layout = struct {
    cx: i32,
    cw: i32,
    lx: i32,
    lw: i32,
    card_x: f64,
    card_w: f64,
    hero_top: i32,
    notes_top: i32,
    notes_h: i32,
    prefs_top: i32,
    foot_y: i32,
    total_h: i32,
};

fn layoutOf(g: Geo, notes_open: bool, has_notes: bool) Layout {
    const cx = g.content_x + 8;
    const cw = g.content_w - 16;
    const hero_top = k_content_top;
    const notes_top = hero_top + k_hero_h + k_card_gap;
    const notes_h = if (notes_open and has_notes) k_notes_h_open else k_notes_h_closed;
    const prefs_top = notes_top + notes_h + k_card_gap;
    const foot_y = prefs_top + k_prefs_h + 12;
    return .{
        .cx = cx,
        .cw = cw,
        .lx = cx + k_card_pad,
        .lw = cw - 2 * k_card_pad,
        .card_x = @floatFromInt(cx),
        .card_w = @floatFromInt(cw),
        .hero_top = hero_top,
        .notes_top = notes_top,
        .notes_h = notes_h,
        .prefs_top = prefs_top,
        .foot_y = foot_y,
        .total_h = foot_y + 20 - k_content_top,
    };
}

fn primaryRect(l: *const Layout) Rect {
    return .{ .x = l.lx, .y = l.hero_top + k_actions_y, .w = k_primary_w, .h = k_btn_h };
}

fn secondaryRect(l: *const Layout) Rect {
    return .{ .x = l.lx + k_primary_w + k_spacing_m, .y = l.hero_top + k_actions_y, .w = k_secondary_w, .h = k_btn_h };
}

fn notesHeaderRect(l: *const Layout) Rect {
    return .{ .x = l.cx, .y = l.notes_top, .w = l.cw, .h = k_notes_h_closed };
}

fn prefsColW(l: *const Layout) i32 {
    return @divTrunc(l.lw - k_spacing_l, 2);
}

fn autoToggleRect(l: *const Layout) Rect {
    const col_w = prefsColW(l);
    return .{
        .x = l.lx + col_w - k_toggle_w - k_spacing_s,
        .y = l.prefs_top + @divTrunc(k_prefs_h - k_toggle_h, 2),
        .w = k_toggle_w,
        .h = k_toggle_h,
    };
}

fn segRect(l: *const Layout) Rect {
    const col_w = prefsColW(l);
    const right_x = l.lx + col_w + k_spacing_l;
    return .{
        .x = right_x + col_w - k_seg_btn_w * 4 - k_spacing_s,
        .y = l.prefs_top + @divTrunc(k_prefs_h - k_seg_h, 2),
        .w = k_seg_btn_w * 4,
        .h = k_seg_h,
    };
}

fn segBtnRect(l: *const Layout, i: usize) Rect {
    const s = segRect(l);
    return .{
        .x = s.x + @as(i32, @intCast(i)) * k_seg_btn_w + 2,
        .y = s.y + 2,
        .w = k_seg_btn_w - 4,
        .h = k_seg_h - 4,
    };
}

fn inRect(px: f64, py: f64, r: Rect) bool {
    return common.pointInRect(px, py, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}

fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
        @divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), std.time.ns_per_ms);
}

fn setStr(dst: []u8, len: *u16, src: []const u8) void {
    const n: u16 = @intCast(@min(src.len, dst.len));
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch buf[0..0];
}

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    inited: bool = false,

    snap: Snapshot = .{},

    svc: updater.Service = undefined,
    /// Decoded app icon, drawn in the hero. Null if the embed fails to
    /// decode, in which case the hand-drawn orb stands in.
    logo: ?*cairo.cairo_surface_t = null,
    /// Detected once at init from `/etc/os-release`.
    kind: updater.PackageKind = .deb,
    /// `$XDG_CACHE_HOME/event-horizon/updates`, owned.
    dir: []const u8 = &.{},

    // --- session state -----------------------------------------------------
    state: State = .never,
    latest_buf: [32]u8 = undefined,
    latest_len: u16 = 0,
    notes_buf: [updater.notes_cap]u8 = undefined,
    notes_len: u16 = 0,

    asset_url: [1024]u8 = undefined,
    asset_url_len: u16 = 0,
    asset_digest: [80]u8 = undefined,
    asset_digest_len: u16 = 0,
    asset_name: [256]u8 = undefined,
    asset_name_len: u16 = 0,
    asset_size: u64 = 0,
    has_asset: bool = false,

    pkg_path: [1024]u8 = undefined,
    pkg_path_len: u16 = 0,

    got: u64 = 0,
    total: u64 = 0,

    err_buf: [256]u8 = undefined,
    err_len: u16 = 0,

    notes_open: bool = true,
    /// Monotonic ms of the last finished check, for the frequency pref. The
    /// page only checks while the settings window is open, so this is a
    /// session timer, not a daemon.
    last_check_ms: i64 = 0,
    /// A cancelled download's result is dropped when the worker publishes it,
    /// so Cancel returns the page to `available` even though the bytes were
    /// still arriving.
    cancel_download: bool = false,

    pub fn init(self: *Page, alloc: std.mem.Allocator, io: std.Io) void {
        self.* = .{};
        self.alloc = alloc;
        self.io = io;
        self.svc = updater.Service.init(alloc, io);
        self.kind = updater.detectKind(io, alloc);
        const xdg = updater.env("XDG_CACHE_HOME");
        const home = updater.env("HOME");
        self.dir = updater.downloadDir(alloc, xdg, home) catch &.{};
        self.logo = decodeLogo(alloc);
        self.inited = true;
    }

    pub fn deinit(self: *Page) void {
        if (!self.inited) return;
        self.svc.deinit();
        if (self.logo) |s| {
            cairo.cairo_surface_destroy(s);
            self.logo = null;
        }
        if (self.dir.len > 0) self.alloc.free(self.dir);
        self.dir = &.{};
        self.inited = false;
    }

    /// Borrow this frame's preferences. With auto-check on, the page checks
    /// when it has never done so and then again once the chosen frequency has
    /// elapsed. The window only passes `auto_check = true` while the Updates
    /// page is on screen, so this is not a background daemon.
    pub fn sync(self: *Page, snap: Snapshot) void {
        self.snap = snap;
        if (!self.inited or !snap.auto_check or self.svc.busy()) return;
        const now = nowMs();
        if (self.state == .never) {
            self.startCheck();
            return;
        }
        if (self.last_check_ms == 0) return;
        const hours: i64 = @intCast(std.math.clamp(snap.check_hours, 1, 24));
        if (now - self.last_check_ms >= hours * 60 * 60 * 1000) self.startCheck();
    }

    /// Pull everything the worker published and move it into session state.
    pub fn drain(self: *Page) void {
        if (!self.inited) return;
        self.svc.drainWake();

        if (self.svc.takeProgress()) |pr| {
            self.got = pr.got;
            self.total = pr.total;
            if (self.state == .downloading) {
                // Only a download publishes progress; keep the screen there
                // until the Done result lands.
            }
        }
        if (self.svc.takeCheck()) |ck| {
            self.last_check_ms = nowMs();
            if (!ck.ok) {
                setStr(&self.err_buf, &self.err_len, ck.errorMsg());
                self.state = .failed;
                // Do not leave the previous release's notes and download
                // button behind an error the user has to read past.
                self.latest_len = 0;
                self.notes_len = 0;
                self.has_asset = false;
                self.asset_size = 0;
                self.notes_open = false;
            } else {
                self.err_len = 0;
                setStr(&self.latest_buf, &self.latest_len, ck.latest[0..ck.latest_len]);
                setStr(&self.notes_buf, &self.notes_len, ck.notes[0..ck.notes_len]);
                self.has_asset = ck.has_asset;
                if (ck.has_asset) {
                    const a = ck.asset;
                    setStr(&self.asset_url, &self.asset_url_len, a.url[0..a.url_len]);
                    setStr(&self.asset_digest, &self.asset_digest_len, a.digest[0..a.digest_len]);
                    setStr(&self.asset_name, &self.asset_name_len, a.name[0..a.name_len]);
                    self.asset_size = a.size;
                }
                self.state = if (ck.has_update) .available else .uptodate;
                self.notes_open = ck.has_update;
                self.got = 0;
                self.total = 0;
            }
        }
        if (self.svc.takeDownload()) |dl| {
            if (self.cancel_download) {
                // The user already went back to `available`; drop the bytes
                // the worker kept fetching behind them.
                self.cancel_download = false;
            } else if (!dl.ok) {
                setStr(&self.err_buf, &self.err_len, dl.errorMsg());
                self.state = .failed;
            } else {
                setStr(&self.pkg_path, &self.pkg_path_len, dl.localPath());
                self.got = dl.got;
                self.total = dl.got;
                self.state = .ready;
            }
        }
        if (self.svc.takeInstall()) |ir| {
            if (!ir.ok) {
                setStr(&self.err_buf, &self.err_len, ir.errorMsg());
                self.state = .failed;
            } else {
                self.state = .restart;
            }
        }
    }

    pub fn busy(self: *const Page) bool {
        return self.state == .checking or self.state == .downloading or self.state == .installing;
    }

    pub fn totalHeight(self: *Page, g: Geo) i32 {
        if (!self.inited) return g.win_h;
        return layoutOf(g, self.notes_open, self.hasNotes()).total_h;
    }

    fn hasNotes(self: *const Page) bool {
        return self.notes_len > 0;
    }

    // -- launches -----------------------------------------------------------

    fn startCheck(self: *Page) void {
        if (!self.svc.checkAsync(self.kind)) return;
        self.state = .checking;
        self.err_len = 0;
    }

    fn startDownload(self: *Page) void {
        if (!self.has_asset) return;
        var dest_buf: [1024]u8 = undefined;
        const dest = fmt(&dest_buf, "{s}/{s}", .{
            self.dir,
            self.asset_name[0..self.asset_name_len],
        });
        if (dest.len == 0) return;
        if (!self.svc.downloadAsync(
            self.asset_url[0..self.asset_url_len],
            dest,
            self.asset_digest[0..self.asset_digest_len],
            self.asset_size,
        )) return;
        self.state = .downloading;
        self.cancel_download = false;
        self.got = 0;
        self.total = self.asset_size;
    }

    fn startInstall(self: *Page) void {
        if (self.pkg_path_len == 0) return;
        if (!self.svc.installAsync(self.kind, self.pkg_path[0..self.pkg_path_len])) return;
        self.state = .installing;
    }

    /// What the primary button does on this screen.
    fn primaryAction(self: *Page) ?Action {
        switch (self.state) {
            .never, .uptodate, .failed => {
                self.startCheck();
                return .repaint;
            },
            .available => {
                self.startDownload();
                return .repaint;
            },
            .ready => {
                self.startInstall();
                return .repaint;
            },
            .restart => return .restart,
            .checking, .downloading, .installing => return null,
        }
    }

    fn secondaryAction(self: *Page) ?Action {
        switch (self.state) {
            .downloading => {
                self.state = .available;
                self.cancel_download = true;
                return .repaint;
            },
            .restart => {
                self.state = .uptodate;
                return .repaint;
            },
            else => return null,
        }
    }

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        if (!self.inited) return null;
        const l = layoutOf(g, self.notes_open, self.hasNotes());

        if (inRect(px, ly, notesHeaderRect(&l))) {
            if (self.hasNotes()) {
                self.notes_open = !self.notes_open;
                return .repaint;
            }
            return .repaint;
        }
        if (inRect(px, ly, primaryRect(&l))) {
            if (self.primaryAction()) |act| return act;
            return null;
        }
        if (self.secondaryLabel().len > 0 and inRect(px, ly, secondaryRect(&l))) {
            if (self.secondaryAction()) |act| return act;
            return null;
        }
        if (inRect(px, ly, autoToggleRect(&l))) return .toggle_auto;
        for (0..4) |i| {
            if (inRect(px, ly, segBtnRect(&l, i))) return .{ .set_freq = k_freq_hours[i] };
        }
        // The version block links to the release page, like "View on GitHub".
        const vx = l.cx + l.cw - k_card_pad - 220;
        if (inRect(px, ly, .{ .x = vx, .y = l.hero_top + 18, .w = 220, .h = 40 })) return .open_releases;
        return null;
    }

    // -- text ---------------------------------------------------------------

    fn latest(self: *const Page) []const u8 {
        return self.latest_buf[0..self.latest_len];
    }

    fn errorMsg(self: *const Page) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn secondaryLabel(self: *const Page) []const u8 {
        return switch (self.state) {
            .downloading => "Cancel",
            .restart => "Later",
            else => "",
        };
    }

    fn percent(self: *const Page) i32 {
        if (self.total == 0) return 0;
        const p = @divTrunc(self.got * 100, self.total);
        return @intCast(std.math.clamp(p, 0, 100));
    }

    fn stepStates(state: State) [4]StepState {
        return switch (state) {
            .never, .failed => .{ .pending, .pending, .pending, .pending },
            .checking => .{ .active, .pending, .pending, .pending },
            .uptodate => .{ .done, .pending, .pending, .pending },
            .available, .downloading => .{ .done, .active, .pending, .pending },
            .ready, .installing => .{ .done, .done, .active, .pending },
            .restart => .{ .done, .done, .done, .active },
        };
    }
};

// Painting

fn fillRound(c: anytype, x: f64, y: f64, w: f64, h: f64, r: f64, col: [4]f64) void {
    if (w <= 0 or h <= 0) return;
    cairo.cairo_new_path(c);
    ui_paint.roundRect(c, x, y, w, h, r);
    cairo.cairo_set_source_rgba(c, col[0], col[1], col[2], col[3]);
    cairo.cairo_fill(c);
}

fn strokeRound(c: anytype, x: f64, y: f64, w: f64, h: f64, r: f64, col: [4]f64, lw: f64) void {
    cairo.cairo_save(c);
    cairo.cairo_new_path(c);
    ui_paint.roundRect(c, x + 0.5, y + 0.5, w - 1.0, h - 1.0, @max(0.5, r - 0.5));
    cairo.cairo_set_line_width(c, lw);
    cairo.cairo_set_source_rgba(c, col[0], col[1], col[2], col[3]);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
}

fn paintSwitch(c: anytype, r: Rect, on: bool) void {
    const xf: f64 = @floatFromInt(r.x);
    const yf: f64 = @floatFromInt(r.y);
    const wf: f64 = @floatFromInt(r.w);
    const hf: f64 = @floatFromInt(r.h);
    const t = common.Theme;
    if (on) {
        fillRound(c, xf, yf, wf, hf, hf / 2.0, .{ t.acc_r, t.acc_g, t.acc_b, 1.0 });
    } else {
        fillRound(c, xf, yf, wf, hf, hf / 2.0, .{ 1, 1, 1, 0.14 });
    }
    const knob_r = hf * 0.38;
    const kx = if (on) xf + wf - hf * 0.5 else xf + hf * 0.5;
    fillRound(c, kx - knob_r, yf + hf / 2.0 - knob_r, knob_r * 2, knob_r * 2, knob_r, .{ 1, 1, 1, 1 });
}

fn paintButton(c: anytype, r: Rect, label: []const u8, primary: bool, enabled: bool, hovered: bool, t: anytype) void {
    if (r.w <= 0 or r.h <= 0) return;
    const xf: f64 = @floatFromInt(r.x);
    const yf: f64 = @floatFromInt(r.y);
    const wf: f64 = @floatFromInt(r.w);
    const hf: f64 = @floatFromInt(r.h);
    if (primary) {
        var r_col = t.acc_r;
        var g_col = t.acc_g;
        var b_col = t.acc_b;
        if (!enabled) {
            r_col *= 0.5;
            g_col *= 0.5;
            b_col *= 0.5;
        } else if (hovered) {
            r_col = @min(1.0, r_col * 1.1);
            g_col = @min(1.0, g_col * 1.1);
            b_col = @min(1.0, b_col * 1.1);
        }
        fillRound(c, xf, yf, wf, hf, 10, .{ r_col, g_col, b_col, if (enabled) 1.0 else 0.55 });
    } else {
        fillRound(c, xf, yf, wf, hf, 10, .{ 1, 1, 1, if (hovered and enabled) 0.12 else 0.06 });
        strokeRound(c, xf, yf, wf, hf, 10, .{ t.outline_r, t.outline_g, t.outline_b, if (hovered) 0.85 else 0.55 }, 1.0);
    }
    const ink: [4]f64 = if (primary) .{ 0.07, 0.09, 0.04, if (enabled) 1.0 else 0.7 } else .{ t.text_r, t.text_g, t.text_b, if (enabled) 0.9 else 0.45 };
    const size = ui_paint.textSizePx(c, label, 12.5, 600);
    const tx = xf + (wf - @as(f64, @floatFromInt(size.w))) / 2.0;
    const ty = yf + hf / 2.0 + @as(f64, @floatFromInt(size.h)) / 2.0 - 2.0;
    ui_paint.showText(c, tx, ty, label, 12.5, 600, ink[0], ink[1], ink[2], ink[3]);
}

fn paintSteps(self: *Page, c: anytype, l: *const Layout, t: anytype) void {
    const states = Page.stepStates(self.state);
    const active_frac: ?f64 = if (self.state == .downloading) @as(f64, @floatFromInt(self.percent())) / 100.0 else null;
    const col_w = @divTrunc(l.lw - 3 * k_step_gap, 4);
    for (0..4) |i| {
        const x = l.lx + @as(i32, @intCast(i)) * (col_w + k_step_gap);
        const y = l.hero_top + k_steps_y;
        fillRound(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(col_w), 3, 2, .{ 1, 1, 1, 0.09 });
        switch (states[i]) {
            .pending => {},
            .done => fillRound(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(col_w), 3, 2, .{ t.acc_r, t.acc_g, t.acc_b, 1.0 }),
            .active => {
                if (active_frac) |f| {
                    const w = @as(f64, @floatFromInt(col_w)) * std.math.clamp(f, 0.0, 1.0);
                    fillRound(c, @floatFromInt(x), @floatFromInt(y), w, 3, 2, .{ t.acc_r, t.acc_g, t.acc_b, 1.0 });
                } else {
                    // Indeterminate: a third of the track, sitting in the
                    // middle so it reads as "working" without a timer.
                    const w = @as(f64, @floatFromInt(col_w)) / 3.0;
                    fillRound(c, @as(f64, @floatFromInt(x)) + w, @floatFromInt(y), w, 3, 2, .{ t.acc_r, t.acc_g, t.acc_b, 1.0 });
                }
            },
        }

        const label = k_step_names[i];
        const done = states[i] == .done;
        const active = states[i] == .active;
        const alpha: f64 = if (active) 0.95 else if (done) 0.62 else 0.36;
        var tx = x;
        if (done) {
            // The check dot stands in for the SVG tick in the design.
            fillRound(
                c,
                @floatFromInt(x),
                @floatFromInt(l.hero_top + k_step_label_y - 8),
                5,
                5,
                2.5,
                .{ t.acc_r, t.acc_g, t.acc_b, 1.0 },
            );
            tx += 9;
        }
        ui_paint.showText(
            c,
            @floatFromInt(tx),
            @floatFromInt(l.hero_top + k_step_label_y),
            label,
            11,
            550,
            t.text_r,
            t.text_g,
            t.text_b,
            alpha,
        );
    }
}

/// Decode the embedded app icon into an ARGB32 surface. stb gives RGBA; cairo
/// wants premultiplied BGRA, the same conversion `accounts_tab` applies to
/// avatars.
fn decodeLogo(alloc: std.mem.Allocator) ?*cairo.cairo_surface_t {
    var img = decode.loadRgbaMemory(alloc, logo_png) orelse return null;
    defer img.free(alloc);
    if (img.w <= 0 or img.h <= 0) return null;
    const w: usize = @intCast(img.w);
    const h: usize = @intCast(img.h);
    if (img.pixels.len < w * h * 4) return null;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, img.w, img.h);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const data = cairo.cairo_image_surface_get_data(surf);
    const stride = cairo.cairo_image_surface_get_stride(surf);
    if (data == null or stride <= 0) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const dst: [*]u8 = @ptrCast(data);
    const stride_us: usize = @intCast(stride);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const si = (y * w + x) * 4;
            const a: u32 = img.pixels[si + 3];
            const r: u32 = img.pixels[si];
            const g: u32 = img.pixels[si + 1];
            const b: u32 = img.pixels[si + 2];
            const rp: u8 = @intCast((r * a + 127) / 255);
            const gp: u8 = @intCast((g * a + 127) / 255);
            const bp: u8 = @intCast((b * a + 127) / 255);
            const off = y * stride_us + x * 4;
            dst[off] = bp;
            dst[off + 1] = gp;
            dst[off + 2] = rp;
            dst[off + 3] = @intCast(a);
        }
    }
    cairo.cairo_surface_mark_dirty(surf);
    return surf;
}

/// Blit the app icon into the hero, clipped to a rounded tile. `dim` is used
/// for the failure screen so the error colour stays the focus.
fn paintLogo(self: *Page, c: anytype, x: i32, y: i32, size: i32, dim: bool) bool {
    const surf = self.logo orelse return false;
    const iw = cairo.cairo_image_surface_get_width(surf);
    const ih = cairo.cairo_image_surface_get_height(surf);
    if (iw <= 0 or ih <= 0) return false;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const sf: f64 = @floatFromInt(size);
    cairo.cairo_save(c);
    cairo.cairo_new_path(c);
    ui_paint.roundRect(c, xf, yf, sf, sf, sf * 0.24);
    cairo.cairo_clip(c);
    cairo.cairo_translate(c, xf, yf);
    cairo.cairo_scale(c, sf / @as(f64, @floatFromInt(iw)), sf / @as(f64, @floatFromInt(ih)));
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    if (dim) {
        cairo.cairo_paint_with_alpha(c, 0.45);
    } else {
        cairo.cairo_paint(c);
    }
    cairo.cairo_restore(c);
    return true;
}

fn paintHero(self: *Page, c: anytype, l: *const Layout, px: f64, py: f64, glass_ov: f64, t: anytype) void {
    ui_paint.card(c, l.card_x, @floatFromInt(l.hero_top), l.card_w, @floatFromInt(k_hero_h), glass_ov);

    // Orb: the embedded app icon, dimmed on failure. If the PNG could not be
    // decoded, the hand-drawn accent orb stands in.
    const accent: [3]f64 = if (self.state == .failed) .{ 1.0, 0.49, 0.43 } else .{ t.acc_r, t.acc_g, t.acc_b };
    if (!paintLogo(self, c, l.cx + k_orb_x, l.hero_top + k_orb_y, k_orb_size, self.state == .failed)) {
        const orb_cx = @as(f64, @floatFromInt(l.cx + k_orb_x)) + @as(f64, @floatFromInt(k_orb_size)) / 2.0;
        const orb_cy = @as(f64, @floatFromInt(l.hero_top + k_orb_y)) + @as(f64, @floatFromInt(k_orb_size)) / 2.0;
        const orb_r = @as(f64, @floatFromInt(k_orb_size)) / 2.0;
        cairo.cairo_new_path(c);
        cairo.cairo_arc(c, orb_cx, orb_cy, orb_r, 0, 2.0 * std.math.pi);
        cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 0.14);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_line_width(c, 1.2);
        cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 0.55);
        cairo.cairo_stroke(c);
        cairo.cairo_new_path(c);
        cairo.cairo_arc(c, orb_cx, orb_cy, orb_r * 0.42, 0, 2.0 * std.math.pi);
        cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 0.95);
        cairo.cairo_fill(c);
    }

    // Title / subtitle.
    var title_buf: [96]u8 = undefined;
    var sub_buf: [192]u8 = undefined;
    const title = titleText(self, &title_buf);
    const sub = subText(self, &sub_buf);
    const text_x = l.cx + k_orb_x + k_orb_size + k_spacing_l;
    ui_paint.showText(c, @floatFromInt(text_x), @floatFromInt(l.hero_top + k_title_y), title, 17, 650, t.text_r, t.text_g, t.text_b, 0.96);
    ui_paint.showText(c, @floatFromInt(text_x), @floatFromInt(l.hero_top + k_sub_y), sub, 12, 400, t.text_r, t.text_g, t.text_b, 0.58);

    // Version block, right-aligned.
    var ver_buf: [96]u8 = undefined;
    const ver = versionText(self, &ver_buf);
    const right = l.cx + l.cw - k_card_pad;
    ui_paint.showText(
        c,
        @floatFromInt(right - 60),
        @floatFromInt(l.hero_top + 22),
        "Version",
        10,
        600,
        t.text_r,
        t.text_g,
        t.text_b,
        0.36,
    );
    const vs = ui_paint.textSizePx(c, ver, 12.5, 600);
    ui_paint.showText(
        c,
        @floatFromInt(right - vs.w),
        @floatFromInt(l.hero_top + 40),
        ver,
        12.5,
        600,
        t.text_r,
        t.text_g,
        t.text_b,
        0.72,
    );

    paintSteps(self, c, l, t);

    // Note band: info for `ready`, error for `failed`, hidden otherwise.
    const note = noteText(self);
    if (note.len > 0) {
        const is_err = self.state == .failed;
        const bg: [4]f64 = if (is_err) .{ 1.0, 0.49, 0.43, 0.10 } else .{ t.acc_r, t.acc_g, t.acc_b, 0.13 };
        const fg: [4]f64 = if (is_err) .{ 1.0, 0.70, 0.66, 1.0 } else .{ 0.85, 0.91, 0.69, 1.0 };
        fillRound(
            c,
            @floatFromInt(l.lx),
            @floatFromInt(l.hero_top + k_note_y),
            @floatFromInt(l.lw),
            @floatFromInt(k_note_h),
            10,
            bg,
        );
        ui_paint.showText(
            c,
            @floatFromInt(l.lx + k_spacing_m),
            @floatFromInt(l.hero_top + k_note_y + 24),
            note,
            11.5,
            400,
            fg[0],
            fg[1],
            fg[2],
            fg[3],
        );
    }

    // Actions.
    const busy_here = self.busy();
    var btn_buf: [64]u8 = undefined;
    const primary_label = primaryLabel(self, &btn_buf);
    const pr = primaryRect(l);
    paintButton(
        c,
        pr,
        primary_label,
        !primaryGhost(self),
        !busy_here,
        inRect(px, py, pr),
        t,
    );
    const sec = self.secondaryLabel();
    if (sec.len > 0) {
        const sr = secondaryRect(l);
        paintButton(c, sr, sec, false, true, inRect(px, py, sr), t);
    }

    // Meta at the right of the action row.
    var meta_buf: [64]u8 = undefined;
    const meta = metaText(self, &meta_buf);
    if (meta.len > 0) {
        const ms = ui_paint.textSizePx(c, meta, 11.5, 400);
        ui_paint.showText(
            c,
            @floatFromInt(right - ms.w),
            @floatFromInt(l.hero_top + k_actions_y + 22),
            meta,
            11.5,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.36,
        );
    }

    // Download progress line, between the buttons and the meta.
    if (self.state == .downloading) {
        var pl_buf: [128]u8 = undefined;
        const line = fmt(&pl_buf, "{d}%   {d:.1} / {d:.1} MB", .{
            self.percent(),
            @as(f64, @floatFromInt(self.got)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(self.total)) / (1024.0 * 1024.0),
        });
        ui_paint.showText(
            c,
            @floatFromInt(l.lx + k_primary_w + k_spacing_m + k_secondary_w + k_spacing_m),
            @floatFromInt(l.hero_top + k_actions_y + 22),
            line,
            11.5,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.58,
        );
    }
}

fn paintNotes(self: *Page, c: anytype, l: *const Layout, px: f64, py: f64, glass_ov: f64, t: anytype) void {
    ui_paint.card(c, l.card_x, @floatFromInt(l.notes_top), l.card_w, @floatFromInt(l.notes_h), glass_ov);

    ui_paint.showText(
        c,
        @floatFromInt(l.lx),
        @floatFromInt(l.notes_top + 34),
        "Release notes",
        13,
        650,
        t.text_r,
        t.text_g,
        t.text_b,
        0.93,
    );

    // Version chip, only when there is something newer to show.
    const chip_states = self.state == .available or self.state == .downloading or
        self.state == .ready or self.state == .installing or self.state == .restart;
    if (chip_states and self.latest().len > 0) {
        var chip_buf: [40]u8 = undefined;
        const chip = fmt(&chip_buf, "v{s}", .{self.latest()});
        const cs = ui_paint.textSizePx(c, chip, 10.5, 600);
        const cw: f64 = @floatFromInt(cs.w + 16);
        const cx = @as(f64, @floatFromInt(l.lx + 92));
        fillRound(c, cx, @floatFromInt(l.notes_top + 15), cw, 19, 9.5, .{ t.acc_r, t.acc_g, t.acc_b, 0.14 });
        ui_paint.showText(c, cx + 8, @floatFromInt(l.notes_top + 30), chip, 10.5, 600, t.acc_r, t.acc_g, t.acc_b, 1.0);
    }

    // Chevron on the right: two strokes, pointing down (up when open).
    const chx = @as(f64, @floatFromInt(l.cx + l.cw - k_card_pad - 14));
    const chy = @as(f64, @floatFromInt(l.notes_top + 24));
    cairo.cairo_new_path(c);
    if (self.notes_open) {
        cairo.cairo_move_to(c, chx, chy + 6);
        cairo.cairo_line_to(c, chx + 5, chy + 1);
        cairo.cairo_line_to(c, chx + 10, chy + 6);
    } else {
        cairo.cairo_move_to(c, chx, chy + 1);
        cairo.cairo_line_to(c, chx + 5, chy + 6);
        cairo.cairo_line_to(c, chx + 10, chy + 1);
    }
    cairo.cairo_set_line_width(c, 1.4);
    cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.36);
    cairo.cairo_stroke(c);

    if (self.notes_open and self.hasNotes()) {
        var y = l.notes_top + 78;
        var lines = std.mem.splitScalar(u8, self.notes_buf[0..self.notes_len], '\n');
        var drawn: usize = 0;
        while (lines.next()) |raw| {
            if (drawn >= 6) break;
            const line = sanitizeNote(raw);
            if (line.len == 0) continue;
            ui_paint.showText(
                c,
                @floatFromInt(l.lx),
                @floatFromInt(y),
                line,
                11.5,
                400,
                t.text_r,
                t.text_g,
                t.text_b,
                0.78,
            );
            y += 20;
            drawn += 1;
        }
    } else if (!self.hasNotes()) {
        ui_paint.showText(
            c,
            @floatFromInt(l.lx),
            @floatFromInt(l.notes_top + 62),
            "Notes for the latest release appear here after a check.",
            11.5,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.5,
        );
    }
    _ = px;
    _ = py;
}

fn paintPrefs(self: *Page, c: anytype, l: *const Layout, px: f64, py: f64, glass_ov: f64, t: anytype) void {
    ui_paint.card(c, l.card_x, @floatFromInt(l.prefs_top), l.card_w, @floatFromInt(k_prefs_h), glass_ov);
    const col_w = prefsColW(l);
    const right_x = l.lx + col_w + k_spacing_l;

    ui_paint.showText(
        c,
        @floatFromInt(l.lx),
        @floatFromInt(l.prefs_top + 34),
        "Check automatically",
        12.5,
        600,
        t.text_r,
        t.text_g,
        t.text_b,
        0.92,
    );
    ui_paint.showText(
        c,
        @floatFromInt(l.lx),
        @floatFromInt(l.prefs_top + 52),
        "Looks at GitHub releases when the page opens",
        11,
        400,
        t.text_r,
        t.text_g,
        t.text_b,
        0.42,
    );
    paintSwitch(c, autoToggleRect(l), self.snap.auto_check);

    ui_paint.showText(
        c,
        @floatFromInt(right_x),
        @floatFromInt(l.prefs_top + 34),
        "Frequency",
        12.5,
        600,
        t.text_r,
        t.text_g,
        t.text_b,
        0.92,
    );
    ui_paint.showText(
        c,
        @floatFromInt(right_x),
        @floatFromInt(l.prefs_top + 52),
        "How often to check",
        11,
        400,
        t.text_r,
        t.text_g,
        t.text_b,
        0.42,
    );

    const sg = segRect(l);
    fillRound(
        c,
        @floatFromInt(sg.x),
        @floatFromInt(sg.y),
        @floatFromInt(sg.w),
        @floatFromInt(sg.h),
        9,
        .{ 0, 0, 0, 0.28 },
    );
    strokeRound(
        c,
        @floatFromInt(sg.x),
        @floatFromInt(sg.y),
        @floatFromInt(sg.w),
        @floatFromInt(sg.h),
        9,
        .{ t.outline_r, t.outline_g, t.outline_b, 0.35 },
        1.0,
    );
    for (0..4) |i| {
        const r = segBtnRect(l, i);
        const on = self.snap.check_hours == k_freq_hours[i];
        if (on) {
            fillRound(
                c,
                @floatFromInt(r.x),
                @floatFromInt(r.y),
                @floatFromInt(r.w),
                @floatFromInt(r.h),
                7,
                .{ 1, 1, 1, 0.12 },
            );
        }
        var lab_buf: [8]u8 = undefined;
        const lab = fmt(&lab_buf, "{d}h", .{k_freq_hours[i]});
        const ls = ui_paint.textSizePx(c, lab, 11.5, 600);
        ui_paint.showText(
            c,
            @floatFromInt(r.x + @divTrunc(r.w - ls.w, 2)),
            @floatFromInt(r.y + @divTrunc(r.h + ls.h, 2) - 1),
            lab,
            11.5,
            600,
            t.text_r,
            t.text_g,
            t.text_b,
            if (on) 0.95 else 0.5,
        );
    }
    _ = px;
    _ = py;
}

/// Strip the markdown markers GitHub release bodies use, so a `### Added`
/// heading and `- bullet` lines still read as plain text in the card.
fn sanitizeNote(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r");
    while (s.len > 0 and (s[0] == '#' or s[0] == '*' or s[0] == '-' or s[0] == '+')) s = s[1..];
    s = std.mem.trimStart(u8, s, " ");
    if (std.mem.startsWith(u8, s, "<!--")) return "";
    return s;
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
    const l = layoutOf(g, self.notes_open, self.hasNotes());

    paintHero(self, c, &l, px, py, glass_ov, t);
    paintNotes(self, c, &l, px, py, glass_ov, t);
    paintPrefs(self, c, &l, px, py, glass_ov, t);

    // Footer: package format and install path.
    var foot_buf: [160]u8 = undefined;
    const pkg_label = self.kind.label();
    const foot = fmt(&foot_buf, "{s}   ·   Installs with pkexec   ·   Source GitHub releases", .{pkg_label});
    ui_paint.showText(
        c,
        @floatFromInt(l.lx + 4),
        @floatFromInt(l.foot_y + 14),
        foot,
        11,
        400,
        t.text_r,
        t.text_g,
        t.text_b,
        0.36,
    );
}

// Text content per state. Kept out of `paint` so tests can read them without
// a cairo surface.

fn titleText(self: *Page, buf: []u8) []const u8 {
    return switch (self.state) {
        .never => "Check for updates",
        .checking => "Checking GitHub releases...",
        .uptodate => "Event Horizon is up to date",
        .available => "Update available",
        .downloading => fmt(buf, "Downloading {s}", .{self.latest()}),
        .ready => "Ready to install",
        .installing => fmt(buf, "Installing {s}", .{self.latest()}),
        .restart => "Update installed",
        .failed => "Couldn't check for updates",
    };
}

fn subText(self: *Page, buf: []u8) []const u8 {
    return switch (self.state) {
        .never => "Event Horizon hasn't looked for updates yet.",
        .checking => "This only takes a moment.",
        .uptodate => "You're on the latest release.",
        .available => fmt(buf, "Event Horizon {s} is ready to download.", .{self.latest()}),
        .downloading => "You can keep using your desktop while this runs.",
        .ready => "Download verified. Installing needs your password.",
        .installing => "Waiting for authentication, then replacing files.",
        .restart => fmt(buf, "Restart the shell to finish applying {s}.", .{self.latest()}),
        .failed => "Event Horizon couldn't reach GitHub.",
    };
}

fn versionText(self: *Page, buf: []u8) []const u8 {
    return switch (self.state) {
        .available, .downloading, .ready, .installing => fmt(buf, "{s}  \u{2192}  {s}", .{
            version.string,
            self.latest(),
        }),
        .restart => fmt(buf, "{s} installed", .{self.latest()}),
        else => version.string,
    };
}

fn metaText(self: *Page, buf: []u8) []const u8 {
    return switch (self.state) {
        .never => "Last checked: never",
        .checking => "Contacting github.com",
        .uptodate => "Last checked: just now",
        .available => "Published release",
        .downloading => fmt(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(self.total)) / (1024.0 * 1024.0)}),
        .ready => "Checksum verified",
        .installing => "Don't power off",
        .restart => "Takes about 2 seconds",
        .failed => "Last checked: never",
    };
}

fn primaryLabel(self: *Page, buf: []u8) []const u8 {
    return switch (self.state) {
        .never => "Check now",
        .checking => "Checking...",
        .uptodate => "Check again",
        .available => fmt(buf, "Download \u{00B7} {d:.1} MB", .{
            @as(f64, @floatFromInt(self.asset_size)) / (1024.0 * 1024.0),
        }),
        .downloading => "Downloading...",
        .ready => "Install update",
        .installing => "Installing...",
        .restart => "Restart shell",
        .failed => "Try again",
    };
}

fn primaryGhost(self: *const Page) bool {
    return self.state == .uptodate;
}

fn noteText(self: *const Page) []const u8 {
    return switch (self.state) {
        .ready => "You'll be asked to authenticate with pkexec. Your session stays open.",
        .restart => "Open windows are kept. Only the panels and lock screen restart.",
        .failed => self.errorMsg(),
        else => "",
    };
}

// Tests

test "updater-tab: layout stacks the three cards without overlap" {
    const t = std.testing;
    const g = Geo{ .content_x = 100, .content_w = 600, .win_h = 900 };
    const closed = layoutOf(g, false, true);
    const open = layoutOf(g, true, true);
    try t.expectEqual(@as(i32, k_content_top), closed.hero_top);
    try t.expectEqual(closed.hero_top + k_hero_h + k_card_gap, closed.notes_top);
    try t.expectEqual(closed.notes_top + k_notes_h_closed + k_card_gap, closed.prefs_top);
    try t.expectEqual(open.notes_top + k_notes_h_open + k_card_gap, open.prefs_top);
    try t.expect(open.total_h > closed.total_h);
    // The notes card only grows when it has text to show.
    try t.expectEqual(k_notes_h_closed, layoutOf(g, true, false).notes_h);
}

test "updater-tab: the action row sits inside the hero card" {
    const t = std.testing;
    const l = layoutOf(.{ .content_x = 0, .content_w = 600, .win_h = 900 }, false, false);
    const pr = primaryRect(&l);
    try t.expect(pr.y >= l.hero_top);
    try t.expect(pr.y + pr.h <= l.hero_top + k_hero_h);
    const sr = secondaryRect(&l);
    try t.expect(sr.x >= pr.x + pr.w);
}

test "updater-tab: the frequency segments do not overlap the toggle" {
    const t = std.testing;
    const l = layoutOf(.{ .content_x = 100, .content_w = 600, .win_h = 900 }, false, false);
    const tg = autoToggleRect(&l);
    const sg = segRect(&l);
    try t.expect(tg.x + tg.w <= sg.x);
    const b0 = segBtnRect(&l, 0);
    const b3 = segBtnRect(&l, 3);
    try t.expect(b0.x >= sg.x);
    try t.expect(b3.x + b3.w <= sg.x + sg.w);
}

test "updater-tab: step states follow the flow" {
    const t = std.testing;
    const checking = Page.stepStates(.checking);
    try t.expectEqual(StepState.active, checking[0]);
    try t.expectEqual(StepState.pending, checking[1]);
    const ready = Page.stepStates(.ready);
    try t.expectEqual(StepState.done, ready[0]);
    try t.expectEqual(StepState.done, ready[1]);
    try t.expectEqual(StepState.active, ready[2]);
    try t.expectEqual(StepState.pending, ready[3]);
    const restart = Page.stepStates(.restart);
    try t.expectEqual(StepState.active, restart[3]);
}

test "updater-tab: note sanitising drops markdown markers" {
    const t = std.testing;
    try t.expectEqualStrings("Added a thing", sanitizeNote("### Added a thing"));
    try t.expectEqualStrings("Fixed a bug", sanitizeNote("  - Fixed a bug\r"));
    try t.expectEqualStrings("", sanitizeNote("<!-- hidden -->"));
    try t.expectEqualStrings("plain", sanitizeNote("plain"));
}

test "updater-tab: percent is clamped and total-free is zero" {
    const t = std.testing;
    var p: Page = .{};
    try t.expectEqual(@as(i32, 0), p.percent());
    p.got = 5;
    p.total = 10;
    try t.expectEqual(@as(i32, 50), p.percent());
    p.got = 20;
    try t.expectEqual(@as(i32, 100), p.percent());
}

test "updater-tab: text content tracks the state" {
    const t = std.testing;
    var p: Page = .{};
    var buf: [192]u8 = undefined;
    try t.expectEqualStrings("Check for updates", titleText(&p, &buf));
    p.state = .available;
    @memcpy(p.latest_buf[0..5], "0.2.0");
    p.latest_len = 5;
    try t.expectEqualStrings("Update available", titleText(&p, &buf));
    try t.expectEqualStrings("Event Horizon 0.2.0 is ready to download.", subText(&p, &buf));
    var ver_buf: [64]u8 = undefined;
    const expected_ver = try std.fmt.bufPrint(&ver_buf, "{s}  \u{2192}  0.2.0", .{version.string});
    try t.expectEqualStrings(expected_ver, versionText(&p, &buf));
    p.state = .downloading;
    try t.expectEqualStrings("Downloading 0.2.0", titleText(&p, &buf));
    try t.expectEqualStrings("Downloading...", primaryLabel(&p, &buf));
    p.state = .failed;
    try t.expectEqualStrings("", noteText(&p));
    @memcpy(p.err_buf[0..6], "boom!!");
    p.err_len = 6;
    try t.expectEqualStrings("boom!!", noteText(&p));
    try t.expectEqualStrings("Try again", primaryLabel(&p, &buf));
}

test "updater-tab: the embedded app icon decodes" {
    const t = std.testing;
    const surf = decodeLogo(t.allocator) orelse return error.LogoDecodeFailed;
    defer cairo.cairo_surface_destroy(surf);
    try t.expectEqual(@as(c_int, 400), cairo.cairo_image_surface_get_width(surf));
    try t.expectEqual(@as(c_int, 400), cairo.cairo_image_surface_get_height(surf));
}
