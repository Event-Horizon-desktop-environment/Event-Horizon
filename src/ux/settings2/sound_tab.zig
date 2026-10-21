//! Settings ▸ Sound — the Audio Center, ported from the C++
//! `settings_tab_sound` (`kSoundChildDevices | Bluetooth | Apps | Engine`)
//! onto the live control-center backend (`controlcenter/live_audio.zig`).
//!
//! Four rail pages under their own Sound category:
//!
//!   Devices (8)    default output/input + volume/mute, over-amplification,
//!                  speaker test, ALSA card profiles
//!   Bluetooth (81) Bluetooth card codec/profile combos
//!   Apps (82)      per-stream volume/mute with playback/recording routing
//!   Engine (83)    clock rate, force rate, allowed-rates preset, PCM
//!                  format, quantum, force quantum, restart services
//!
//! Like the Bluetooth page, the whole scrollable region is self-painted:
//! these are live lists (devices, streams, cards), not a fixed row set.
//! Every combo opens the same single-dropdown model (`dd_*`), the volume
//! sliders drag with a local optimistic value while the live snapshot is
//! frozen, and the backend spawns are throttled per cache:
//!
//!   snapshot (sinks/sources/streams)   1000 ms
//!   `pw-link -l` routing blob          1000 ms (Apps page)
//!   engine metadata (`pw-metadata`)    1200 ms
//!   PCM drop-in probe                  1200 ms
//!   card list (`pactl list cards`)     2500 ms (Devices/Bluetooth pages)
//!
//! The combo id numbering matches the C++ page: 0 default sink, 1 default
//! source, 2..7 engine, 5 PCM, 100+i playback route, 600+i card profile,
//! 1000+i recording route. Drag codes: 2000 sink volume, 2001 source
//! volume, 200+i playback stream, 1000+i recording stream.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const live_audio = @import("../../desktop_shell/controlcenter/live_audio.zig");
const vmx = @import("../../desktop_shell/widgets/volume_mixer.zig");
const icon_cache = @import("../../desktop_shell/common/icon_cache.zig");

pub const devices_tab: i32 = 8;
pub const bt_audio_tab: i32 = 81;
pub const apps_tab: i32 = 82;
pub const engine_tab: i32 = 83;

pub fn isSoundTab(tab: i32) bool {
    return tab == devices_tab or tab == bt_audio_tab or tab == apps_tab or tab == engine_tab;
}

pub const Child = enum { devices, bluetooth, apps, engine };

pub fn childOf(tab: i32) Child {
    return switch (tab) {
        bt_audio_tab => .bluetooth,
        apps_tab => .apps,
        engine_tab => .engine,
        else => .devices,
    };
}

/// One audio config change the window owns (the page already ran the live
/// write; this is the `audio/audio.toml [audio]` bookkeeping the C++ page
/// persisted with `save_settings`).
pub const AudioPersist = struct {
    overamp: ?bool = null,
    sink_name: ?[]const u8 = null,
    source_name: ?[]const u8 = null,
    sink_muted: ?bool = null,
    source_muted: ?bool = null,
    clock_hz: ?i32 = null,
    force_hz: ?i32 = null,
    quantum: ?i32 = null,
    force_quantum: ?i32 = null,
    /// Borrowed, stable for the life of the `Action` (static preset table
    /// or the page's own `rate_single` buffer).
    rates: ?[]const i32 = null,
    pcm: ?i32 = null,
};

pub const Action = union(enum) {
    /// Backend work happened in the page; a repaint is all that is needed.
    repaint,
    /// Over-amplification toggle — the window owns `Settings` + the save.
    overamp_toggle,
    /// One audio config key to write back to `audio/audio.toml`.
    persist: AudioPersist,
};

/// Content-column geometry, passed in rather than read from `Content` so
/// this module stays free of a cycle back into `ui_content`.
pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_w: i32 = 900,
    win_h: i32,
    tab: i32,
};

// ---------------------------------------------------------------------------
// Layout constants — the C++ `kSnd*` / monitors-section metrics.
// ---------------------------------------------------------------------------

const k_card_top: i32 = common.content_top;
const k_sec_gap: i32 = 32;
const k_sec_title_pad_top: i32 = 20;
const k_sec_title_line_h: i32 = 22;
const k_sec_after_title: i32 = 20;
const k_sec_bottom_pad: i32 = 24;
const k_sec_body_top: i32 = k_sec_title_pad_top + k_sec_title_line_h + k_sec_after_title; // 62
const k_row_h: i32 = 56;
const k_combo_min_w: i32 = 140;
const k_slider_icon_w: i32 = 30;
const k_slider_hit_h: i32 = 30;
const k_app_icon: i32 = 36;
const k_app_icon_rad: f64 = 10;
const k_grid_row_h: i32 = 82;
const k_grid_label_h: i32 = 18;
const k_grid_label_gap: i32 = 12;
const k_restart_btn_w: i32 = 140;
const k_restart_btn_h: i32 = 36;
const k_restart_row_h: i32 = 52;
const k_restart_gap: i32 = 14;
const k_restart_arm_ms: i64 = 3500;
const k_restart_done_ms: i64 = 2600;
const k_drag_apply_ms: i64 = 40;
const k_snap_ms: i64 = 1000;
const k_engine_ms: i64 = 1200;
const k_cards_ms: i64 = 2500;
const k_max_dd_rows: usize = 32;

const k_engine_rates = [_]i32{ 44100, 48000, 88200, 96000, 176400, 192000 };
const k_engine_quantums = [_]i32{ 128, 256, 512, 1024, 2048, 4096, 8192 };
const k_pcm_labels = [_][]const u8{
    "16-bit PCM (S16 LE)",
    "24-bit PCM (S24 LE)",
    "32-bit PCM (S32 LE)",
    "32-bit float (F32 LE)",
};

const preset_hifi = [_]i32{ 44100, 48000, 88200, 96000, 176400, 192000 };
const preset_consumer = [_]i32{ 44100, 48000 };
const preset_pro = [_]i32{ 48000, 96000, 192000 };

/// Rates a 0..3 allowed-rates preset writes (`Single` uses the page's
/// current clock rate, so it is filled by the caller).
pub fn presetRates(i: i32) ?[]const i32 {
    return switch (i) {
        0 => &preset_hifi,
        1 => &preset_consumer,
        2 => &preset_pro,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested)
// ---------------------------------------------------------------------------

fn nowMs() i64 {
    return vmx.nowMs();
}

/// `sound_engine_hz_display` — "44.1 kHz" style, whole kHz without a decimal.
pub fn hzDisplay(buf: []u8, hz: i32) []const u8 {
    if (hz <= 0) return std.fmt.bufPrint(buf, "{d}", .{hz}) catch "0";
    const k = @divTrunc(hz, 1000);
    const frac = @rem(hz, 1000);
    if (frac == 0) return std.fmt.bufPrint(buf, "{d} kHz", .{k}) catch "?";
    return std.fmt.bufPrint(buf, "{d}.{d} kHz", .{ k, @divTrunc(frac, 100) }) catch "?";
}

/// `sound_engine_allowed_preset_sel` — which preset the live allowed list
/// is, or -1 for a custom set.
pub fn allowedPresetSel(clock_rate_hz: i32, allowed: []const i32) i32 {
    var norm_buf: [16]i32 = undefined;
    const n = @min(allowed.len, norm_buf.len);
    @memcpy(norm_buf[0..n], allowed[0..n]);
    std.mem.sort(i32, norm_buf[0..n], {}, std.sort.asc(i32));
    const norm = norm_buf[0..n];
    if (std.mem.eql(i32, norm, &preset_hifi)) return 0;
    if (std.mem.eql(i32, norm, &preset_consumer)) return 1;
    if (std.mem.eql(i32, norm, &preset_pro)) return 2;
    if (norm.len == 1 and norm[0] == clock_rate_hz) return 3;
    return -1;
}

/// `sound_engine_allowed_combo_display`.
pub fn allowedPresetLabel(sel: i32) []const u8 {
    return switch (sel) {
        0 => "Hi-Fi (44.1-192 kHz)",
        1 => "Consumer (44.1 / 48 kHz)",
        2 => "Pro (48 / 96 / 192 kHz)",
        3 => "Single (default rate only)",
        else => "Custom",
    };
}

/// Device label for the combos — friendly description, raw name fallback.
pub fn deviceLabel(d: live_audio.Device) []const u8 {
    return if (d.description.len > 0) d.description else d.name;
}

/// Profile label — WirePlumber's human description, key fallback.
pub fn profileLabel(p: live_audio.AudioCardProfile) []const u8 {
    return if (p.description.len > 0) p.description else p.key;
}

/// Compact display strings, mirroring the C++ Sound page's
/// `shorten_device_name` / `shorten_profile_label` calls (shared with the
/// mixer popup). Falls back to the raw label on allocation failure.
fn shortDeviceLabel(alloc: std.mem.Allocator, name: []const u8) []const u8 {
    return vmx.shortenDeviceName(alloc, name) catch name;
}

fn shortProfileLabel(alloc: std.mem.Allocator, p: live_audio.AudioCardProfile) []const u8 {
    const desc = profileLabel(p);
    return vmx.shortenProfileLabel(alloc, p.key, desc) catch desc;
}

fn inRect(px: f64, py: f64, r: common.Rect) bool {
    return common.pointInRect(px, py, r);
}

// ---------------------------------------------------------------------------
// Layout geometry
// ---------------------------------------------------------------------------

const SGeom = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    /// Top of the first content row (title band consumed).
    y0: i32 = 0,
};

const Geom = struct {
    devices: SGeom = .{},
    cards: SGeom = .{},
    playback: SGeom = .{},
    recording: SGeom = .{},
    engine: SGeom = .{},
    n_cards: usize = 0,
    n_play: usize = 0,
    n_rec: usize = 0,
    bottom: i32 = 0,
};

fn secCardHeightRows(rows: i32) i32 {
    return k_sec_body_top + rows * k_row_h + k_sec_bottom_pad;
}

/// Combo rect for row `row_i` of a section: right-aligned, base 200px
/// widened to fit `value` (C++ `sound_combo_geom_for`), so long device and
/// profile names widen the box instead of being cut off. Paint and hit
/// resolve the same display string, so the rects always agree.
fn comboRect(sec: SGeom, row_i: i32, value: []const u8) common.Rect {
    const pad = common.card_pad;
    const max_w = @max(common.settings_combo_w, sec.w - 2 * pad - common.spacing_m);
    const desired = ui_paint.measureTextWidth(value, 12, 500) + 48;
    const cw = @max(common.settings_combo_w, @min(desired, max_w));
    return .{
        .x = sec.x + sec.w - pad - cw,
        .y = sec.y0 + row_i * k_row_h + @divTrunc(k_row_h - common.settings_combo_h, 2),
        .w = cw,
        .h = common.settings_combo_h,
    };
}

/// Mute-icon button and slider track for a volume row.
const SliderGeom = struct {
    icon: common.Rect,
    track: common.Rect,
};
fn sliderGeom(sec: SGeom, row_i: i32) SliderGeom {
    const row_y = sec.y0 + row_i * k_row_h;
    const track_x = sec.x + common.card_pad + k_slider_icon_w + common.spacing_s;
    const track_w = sec.w - 2 * common.card_pad - k_slider_icon_w - common.spacing_s - 64;
    return .{
        .icon = .{
            .x = sec.x + common.card_pad,
            .y = row_y + @divTrunc(k_row_h - common.settings_combo_h, 2),
            .w = k_slider_icon_w,
            .h = common.settings_combo_h,
        },
        .track = .{
            .x = track_x,
            .y = row_y + @divTrunc(k_row_h, 2) - 3,
            .w = @max(40, track_w),
            .h = 6,
        },
    };
}

/// Toggle pill rect for the over-amp row.
fn toggleRowRect(sec: SGeom, row_i: i32) common.Rect {
    return .{
        .x = sec.x + common.card_pad,
        .y = sec.y0 + row_i * k_row_h,
        .w = sec.w - 2 * common.card_pad,
        .h = k_row_h,
    };
}

/// Button rect of a row (right-aligned).
fn rowButtonRect(sec: SGeom, row_i: i32) common.Rect {
    return .{
        .x = sec.x + sec.w - common.card_pad - k_restart_btn_w,
        .y = sec.y0 + row_i * k_row_h + @divTrunc(k_row_h - k_restart_btn_h, 2),
        .w = k_restart_btn_w,
        .h = k_restart_btn_h,
    };
}

/// Engine grid cell rect (2 columns x 3 rows).
fn gridCellRect(sec: SGeom, col: i32, row_i: i32) common.Rect {
    const col_gap = common.spacing_l;
    const cell_w = @divTrunc(sec.w - 2 * common.card_pad - col_gap, 2);
    const x = sec.x + common.card_pad + col * (cell_w + col_gap);
    const y = sec.y0 + row_i * k_grid_row_h + k_grid_label_h + k_grid_label_gap;
    return .{ .x = x, .y = y, .w = cell_w, .h = common.settings_combo_h };
}

fn restartRowY(sec: SGeom) i32 {
    return sec.y0 + 3 * k_grid_row_h + k_restart_gap;
}

fn restartBtnRect(sec: SGeom) common.Rect {
    return .{
        .x = sec.x + sec.w - common.card_pad - k_restart_btn_w,
        .y = restartRowY(sec) + @divTrunc(k_restart_row_h - k_restart_btn_h, 2),
        .w = k_restart_btn_w,
        .h = k_restart_btn_h,
    };
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

const Drag = struct {
    code: i32 = -1,
    is_input: bool = false,
    raw: []const u8 = "",
    node_id: u32 = 0,
    stream_id: i32 = -1,
    pct: i32 = 100,
    track: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    inited: bool = false,

    // --- live caches (throttled) ------------------------------------------
    q: ?live_audio.Queried = null,
    snap_ms: i64 = 0,
    es: live_audio.EngineSettings = .{},
    engine_ms: i64 = 0,
    have_engine: bool = false,
    pcm_choice: i32 = -1,
    pcm_ms: i64 = 0,
    have_pcm: bool = false,
    cards: []live_audio.AudioCard = &.{},
    cards_ms: i64 = 0,
    cards_bt: bool = false,
    link_blob: ?[]u8 = null,
    link_ms: i64 = 0,

    /// Borrowed from `Settings` every frame (`sync`).
    overamp: bool = false,
    /// Current rail page, recorded by the last paint/hit/totalHeight.
    tab: i32 = devices_tab,
    /// Scratch for engine combo labels (`comboDisplay`); copied by paint.
    disp_buf: [32]u8 = undefined,
    /// One-frame-stale scroll offset, used only to clamp the dropdown popup.
    scroll_px_est: i32 = 0,

    // --- dropdown (single model: one builder feeds paint and hit) ---------
    dd_open: bool = false,
    dd_id: i32 = -1,
    dd_rows: [k_max_dd_rows][]const u8 = undefined,
    dd_rows_len: usize = 0,
    dd_sel: i32 = -1,
    dd_title: []const u8 = "",
    dd_hover: i32 = -1,
    dd_arena: std.heap.ArenaAllocator = undefined,
    frame_arena: std.heap.ArenaAllocator = undefined,

    // --- drag --------------------------------------------------------------
    drag: ?Drag = null,
    drag_apply_ms: i64 = 0,
    /// Backing for the "Single" preset's one-element rate list.
    rate_single: [1]i32 = .{48000},

    // --- restart button arm/done windows ----------------------------------
    restart_arm_ms: i64 = -1,
    restart_done_ms: i64 = -1,

    // --- speaker-test shells to reap --------------------------------------
    tone_pids: [2]i32 = .{ 0, 0 },
    tone_len: usize = 0,

    // --- app icons (duplicated keys; page-owned pixels) --------------------
    icon_pixels: std.StringHashMapUnmanaged(icon_cache.Owned) = .empty,

    pub fn init(self: *Page, gpa: std.mem.Allocator, io: std.Io) void {
        self.alloc = gpa;
        self.io = io;
        self.dd_arena = std.heap.ArenaAllocator.init(gpa);
        self.frame_arena = std.heap.ArenaAllocator.init(gpa);
        self.inited = true;
        self.refresh(devices_tab, true);
    }

    pub fn deinit(self: *Page) void {
        if (!self.inited) return;
        if (self.q) |*q| q.deinit();
        self.q = null;
        if (self.es.allowed_rates_hz.len > 0) live_audio.freeEngineSettings(self.alloc, &self.es);
        self.es = .{};
        if (self.cards.len > 0) live_audio.freeAudioCards(self.alloc, self.cards);
        self.cards = &.{};
        if (self.link_blob) |b| self.alloc.free(b);
        self.link_blob = null;
        var it = self.icon_pixels.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            var v = e.value_ptr.*;
            v.deinit(self.alloc);
        }
        self.icon_pixels.deinit(self.alloc);
        self.icon_pixels = .empty;
        self.dd_arena.deinit();
        self.frame_arena.deinit();
    }

    /// Window-side per-frame state (`Settings` value the page cannot own).
    pub fn sync(self: *Page, overamp: bool) void {
        self.overamp = overamp;
    }

    pub fn maxPct(self: *const Page) i32 {
        return if (self.overamp) 150 else 100;
    }

    fn storeDevice(self: *const Page) live_audio.Device {
        return if (self.q) |*q| q.snap.out else .{};
    }

    fn sourceDevice(self: *const Page) live_audio.Device {
        return if (self.q) |*q| q.snap.in else .{};
    }

    fn hasDevice(d: live_audio.Device) bool {
        return d.id != 0 or d.name.len > 0;
    }

    // -----------------------------------------------------------------------
    // Refresh (throttled, frozen while dragging)
    // -----------------------------------------------------------------------

    fn refresh(self: *Page, tab: i32, force: bool) void {
        if (!self.inited) return;
        self.tab = tab;
        self.reapTones();
        if (self.drag != null) return;
        const now = nowMs();
        const child = childOf(tab);

        if (force or now - self.snap_ms >= k_snap_ms) {
            if (self.q) |*q| q.deinit();
            self.q = live_audio.query(self.alloc, self.io, child == .apps);
            self.snap_ms = now;
        }

        if (force or now - self.engine_ms >= k_engine_ms) {
            if (self.es.allowed_rates_hz.len > 0) live_audio.freeEngineSettings(self.alloc, &self.es);
            self.es = live_audio.queryEngineSettings(self.alloc, self.io);
            self.engine_ms = now;
            self.have_engine = true;
        }

        if (force or now - self.pcm_ms >= k_engine_ms) {
            self.pcm_choice = live_audio.queryCompatPcm(self.alloc, self.io);
            self.pcm_ms = now;
            self.have_pcm = true;
        }

        if (child == .apps) {
            if (force or now - self.link_ms >= k_snap_ms) {
                if (self.link_blob) |b| self.alloc.free(b);
                self.link_blob = live_audio.capturePwLinkBlob(self.alloc, self.io);
                self.link_ms = now;
            }
        }

        if (child == .devices or child == .bluetooth) {
            const want_bt = child == .bluetooth;
            if (force or want_bt != self.cards_bt or now - self.cards_ms >= k_cards_ms) {
                // A failed query keeps the previous list (empty list on the
                // first poll) and retries on the next throttle window.
                if (live_audio.queryAudioCards(self.alloc, self.io, want_bt) catch null) |fresh| {
                    if (self.cards.len > 0) live_audio.freeAudioCards(self.alloc, self.cards);
                    self.cards = fresh;
                }
                self.cards_bt = want_bt;
                self.cards_ms = now;
            }
        }
    }

    fn reapTones(self: *Page) void {
        const linux = std.os.linux;
        var i: usize = 0;
        while (i < self.tone_len) {
            const pid = self.tone_pids[i];
            var status: u32 = 0;
            const rc: isize = @bitCast(linux.wait4(pid, &status, linux.W.NOHANG, null));
            if (rc == pid or rc < 0) {
                self.tone_pids[i] = self.tone_pids[self.tone_len - 1];
                self.tone_len -= 1;
            } else {
                i += 1;
            }
        }
    }

    fn rememberTone(self: *Page, pid: i32) void {
        if (self.tone_len >= self.tone_pids.len) return; // reaped on the next refresh
        self.tone_pids[self.tone_len] = pid;
        self.tone_len += 1;
    }

    // -----------------------------------------------------------------------
    // Geometry
    // -----------------------------------------------------------------------

    fn computeGeom(self: *Page, g: Geo) Geom {
        const x = g.content_x + 8;
        const w = g.content_w - 16;
        var out = Geom{};
        var y = k_card_top;
        switch (childOf(g.tab)) {
            .devices => {
                out.devices = .{ .x = x, .y = y, .w = w, .h = secCardHeightRows(6), .y0 = y + k_sec_body_top };
                y += out.devices.h + k_sec_gap;
                out.n_cards = self.cards.len;
                const rows = @max(1, @as(i32, @intCast(self.cards.len)));
                out.cards = .{ .x = x, .y = y, .w = w, .h = secCardHeightRows(rows), .y0 = y + k_sec_body_top };
                y += out.cards.h;
            },
            .bluetooth => {
                out.n_cards = self.cards.len;
                const rows = @max(1, @as(i32, @intCast(self.cards.len)));
                out.cards = .{ .x = x, .y = y, .w = w, .h = secCardHeightRows(rows), .y0 = y + k_sec_body_top };
                y += out.cards.h;
            },
            .apps => {
                const n_play: i32 = if (self.q) |*q| @intCast(q.snap.out_streams.len) else 0;
                const n_rec: i32 = if (self.q) |*q| @intCast(q.snap.in_streams.len) else 0;
                out.n_play = @intCast(@max(0, n_play));
                out.n_rec = @intCast(@max(0, n_rec));
                out.playback = .{ .x = x, .y = y, .w = w, .h = secCardHeightRows(@max(1, n_play * 2)), .y0 = y + k_sec_body_top };
                y += out.playback.h + k_sec_gap;
                out.recording = .{ .x = x, .y = y, .w = w, .h = secCardHeightRows(@max(1, n_rec * 2)), .y0 = y + k_sec_body_top };
                y += out.recording.h;
            },
            .engine => {
                const h = k_sec_body_top + 3 * k_grid_row_h + k_restart_gap + k_restart_row_h + k_sec_bottom_pad;
                out.engine = .{ .x = x, .y = y, .w = w, .h = h, .y0 = y + k_sec_body_top };
                y += h;
            },
        }
        out.bottom = y;
        return out;
    }

    pub fn totalHeight(self: *Page, g: Geo) i32 {
        if (!self.inited) return 0;
        self.refresh(g.tab, false);
        const ge = self.computeGeom(g);
        return ge.bottom + common.spacing_xl;
    }

    // -----------------------------------------------------------------------
    // Dropdown model
    // -----------------------------------------------------------------------

    fn ddSelFor(self: *Page, id: i32) i32 {
        const q = if (self.q) |*qq| qq else return -1;
        if (id == 0) {
            for (q.snap.sinks, 0..) |d, i| {
                if (d.id != 0 and d.id == q.snap.out.id) return @intCast(i);
            }
            return 0;
        }
        if (id == 1) {
            for (q.snap.sources, 0..) |d, i| {
                if (d.id != 0 and d.id == q.snap.in.id) return @intCast(i);
            }
            return 0;
        }
        if (id == 2) {
            for (k_engine_rates, 0..) |hz, i| {
                if (hz == self.es.clock_rate_hz) return @intCast(i);
            }
            return -1;
        }
        if (id == 3) {
            if (self.es.clock_force_rate_hz == 0) return 0;
            for (k_engine_rates, 0..) |hz, i| {
                if (hz == self.es.clock_force_rate_hz) return @intCast(i + 1);
            }
            return -1;
        }
        if (id == 4) return allowedPresetSel(self.es.clock_rate_hz, self.es.allowed_rates_hz);
        if (id == 5) return self.pcm_choice;
        if (id == 6) {
            if (self.es.clock_quantum == 0) return 0;
            for (k_engine_quantums, 0..) |qn, i| {
                if (qn == self.es.clock_quantum) return @intCast(i + 1);
            }
            return -1;
        }
        if (id == 7) {
            if (self.es.clock_force_quantum == 0) return 0;
            for (k_engine_quantums, 0..) |qn, i| {
                if (qn == self.es.clock_force_quantum) return @intCast(i + 1);
            }
            return -1;
        }
        if (id >= 600 and id < 1000) {
            const ci: usize = @intCast(id - 600);
            if (ci < self.cards.len) {
                const active = self.cards[ci].active_profile_key;
                for (self.cards[ci].profiles, 0..) |p, i| {
                    if (std.mem.eql(u8, p.key, active)) return @intCast(i);
                }
            }
            return 0;
        }
        if (id >= 100 and id < 600) {
            const si: usize = @intCast(id - 100);
            const q2 = if (self.q) |*qq| qq else return 0;
            if (si >= q2.snap.out_streams.len) return 0;
            return self.routeSel(q2.snap.out_streams[si], false);
        }
        if (id >= 1000) {
            const si: usize = @intCast(id - 1000);
            const q2 = if (self.q) |*qq| qq else return 0;
            if (si >= q2.snap.in_streams.len) return 0;
            return self.routeSel(q2.snap.in_streams[si], true);
        }
        return -1;
    }

    /// Route dropdown selection: 0 = default, 1+i = the i-th device whose
    /// raw name matches the live `pw-link` route.
    fn routeSel(self: *Page, st: live_audio.Stream, is_input: bool) i32 {
        const raw = self.routeRaw(st, is_input);
        if (raw.len == 0) return 0;
        const q = if (self.q) |*qq| qq else return 0;
        const devs = if (is_input) q.snap.sources else q.snap.sinks;
        for (devs, 0..) |d, i| {
            if (std.mem.eql(u8, d.name, raw)) return @intCast(i + 1);
        }
        return 0;
    }

    fn routeRaw(self: *Page, st: live_audio.Stream, is_input: bool) []const u8 {
        const blob = self.link_blob orelse return "";
        if (st.node_name.len == 0) return "";
        return if (is_input)
            vmx.captureSourceForStream(blob, st.node_name)
        else
            vmx.playbackSinkForStream(blob, st.node_name);
    }

    /// Route combo display: "Default" or the routed device's label.
    fn routeDisplay(self: *Page, st: live_audio.Stream, is_input: bool) []const u8 {
        const raw = self.routeRaw(st, is_input);
        if (raw.len == 0) return "Default";
        const q = if (self.q) |*qq| qq else return "Default";
        const devs = if (is_input) q.snap.sources else q.snap.sinks;
        for (devs) |d| {
            if (std.mem.eql(u8, d.name, raw)) return shortDeviceLabel(self.frame_arena.allocator(), deviceLabel(d));
        }
        return raw;
    }

    fn ddTitleFor(id: i32) []const u8 {
        if (id == 0) return "Default output";
        if (id == 1) return "Default input";
        if (id == 2) return "Default rate";
        if (id == 3) return "Force graph rate";
        if (id == 4) return "Allowed rates preset";
        if (id == 5) return "Default PCM format";
        if (id == 6) return "Default quantum";
        if (id == 7) return "Force quantum";
        if (id >= 600 and id < 1000) return "Card profile";
        if (id >= 1000) return "Move recording to";
        return "Move playback to";
    }

    /// Combo text shown in the page for a dropdown id. Paint-only; the
    /// scratch buffer is copied by `showText` immediately.
    fn comboDisplay(self: *Page, id: i32) []const u8 {
        if (id == 0) {
            const d = self.storeDevice();
            return if (hasDevice(d)) shortDeviceLabel(self.frame_arena.allocator(), deviceLabel(d)) else "(no output)";
        }
        if (id == 1) {
            const d = self.sourceDevice();
            return if (hasDevice(d)) shortDeviceLabel(self.frame_arena.allocator(), deviceLabel(d)) else "(no input)";
        }
        const buf = &self.disp_buf;
        return switch (id) {
            2 => hzDisplay(buf, self.es.clock_rate_hz),
            3 => if (self.es.clock_force_rate_hz == 0) "Auto" else hzDisplay(buf, self.es.clock_force_rate_hz),
            4 => allowedPresetLabel(allowedPresetSel(self.es.clock_rate_hz, self.es.allowed_rates_hz)),
            5 => if (!self.have_pcm or self.pcm_choice < 0 or self.pcm_choice > 3) "(unknown)" else k_pcm_labels[@intCast(self.pcm_choice)],
            6 => if (self.es.clock_quantum == 0) "Auto (default)" else std.fmt.bufPrint(buf, "{d} frames", .{self.es.clock_quantum}) catch "?",
            else => if (self.es.clock_force_quantum == 0) "Auto" else std.fmt.bufPrint(buf, "{d} frames", .{self.es.clock_force_quantum}) catch "?",
        };
    }

    /// Build the open dropdown's rows from the current caches (deterministic:
    /// paint and hit rebuild identically).
    fn rebuildDd(self: *Page) void {
        const id = self.dd_id;
        self.dd_rows_len = 0;
        self.dd_sel = self.ddSelFor(id);
        self.dd_title = ddTitleFor(id);
        _ = self.dd_arena.reset(.retain_capacity);
        const aa = self.dd_arena.allocator();
        const mn = struct {
            fn add(p: *Page, a: std.mem.Allocator, s: []const u8) void {
                if (p.dd_rows_len >= k_max_dd_rows) return;
                const owned = a.dupe(u8, s) catch return;
                p.dd_rows[p.dd_rows_len] = owned;
                p.dd_rows_len += 1;
            }
        }.add;

        const q = if (self.q) |*qq| qq else null;
        if (id == 0) {
            if (q) |qq| for (qq.snap.sinks) |d| mn(self, aa, shortDeviceLabel(aa, deviceLabel(d)));
            return;
        }
        if (id == 1) {
            if (q) |qq| for (qq.snap.sources) |d| mn(self, aa, shortDeviceLabel(aa, deviceLabel(d)));
            return;
        }
        if (id >= 2 and id <= 7) {
            var buf: [32]u8 = undefined;
            if (id == 2) {
                for (k_engine_rates) |hz| mn(self, aa, hzDisplay(&buf, hz));
            } else if (id == 3) {
                mn(self, aa, "Auto");
                for (k_engine_rates) |hz| mn(self, aa, hzDisplay(&buf, hz));
            } else if (id == 4) {
                for (0..4) |i| mn(self, aa, allowedPresetLabel(@intCast(i)));
            } else if (id == 5) {
                for (k_pcm_labels) |l| mn(self, aa, l);
            } else if (id == 6) {
                mn(self, aa, "Auto (default)");
                for (k_engine_quantums) |qn| {
                    const s = std.fmt.bufPrint(&buf, "{d} frames", .{qn}) catch continue;
                    mn(self, aa, s);
                }
            } else {
                mn(self, aa, "Auto");
                for (k_engine_quantums) |qn| {
                    const s = std.fmt.bufPrint(&buf, "{d} frames", .{qn}) catch continue;
                    mn(self, aa, s);
                }
            }
            return;
        }
        if (id >= 600 and id < 1000) {
            const ci: usize = @intCast(id - 600);
            if (ci < self.cards.len) {
                for (self.cards[ci].profiles) |p| mn(self, aa, shortProfileLabel(aa, p));
            }
            return;
        }
        if (id >= 100 and id < 600) {
            const qq = q orelse return;
            const si: usize = @intCast(id - 100);
            if (si >= qq.snap.out_streams.len) return;
            mn(self, aa, "Default");
            for (qq.snap.sinks) |d| mn(self, aa, shortDeviceLabel(aa, deviceLabel(d)));
            return;
        }
        if (id >= 1000) {
            const qq = q orelse return;
            const si: usize = @intCast(id - 1000);
            if (si >= qq.snap.in_streams.len) return;
            mn(self, aa, "Default");
            for (qq.snap.sources) |d| mn(self, aa, shortDeviceLabel(aa, deviceLabel(d)));
            return;
        }
    }

    fn openDropdown(self: *Page, id: i32) void {
        if (self.dd_open and self.dd_id == id) {
            self.dd_open = false;
            return;
        }
        self.dd_open = true;
        self.dd_id = id;
        self.dd_hover = -1;
        self.rebuildDd();
    }

    fn closeDropdown(self: *Page) void {
        self.dd_open = false;
        self.dd_id = -1;
        self.dd_hover = -1;
    }

    /// Popup list rect in document space; opens below the combo, flips
    /// above it when the window bottom is in the way (C++
    /// `sound_dd_popup_list_doc_top_y`, minus the scroll term because the
    /// caller already works in layout space).
    fn ddListRect(self: *Page, g: Geo, combo: common.Rect) common.Rect {
        const title_h = 28;
        const row_h = 30;
        const pad = 10;
        const n: i32 = @intCast(self.dd_rows_len);
        const h = title_h + n * row_h + pad;
        // Fit the longest row (C++ `sound_bt_dropdown_popup_geom`), clamped
        // to the window so an item can never paint past the edge.
        var w = combo.w;
        for (self.dd_rows[0..self.dd_rows_len]) |row| {
            w = @max(w, ui_paint.measureTextWidth(row, 12, 500) + 28);
        }
        const margin: i32 = 12;
        w = @min(w, @max(combo.w, g.win_w - 2 * margin));
        var x = combo.x + combo.w - w;
        if (x + w > g.win_w - margin) x = g.win_w - margin - w;
        if (x < margin) x = margin;
        var y = combo.y + combo.h + 2;
        const viewport_bottom = g.win_h - common.spacing_l + self.scroll_px_est;
        if (y + h > viewport_bottom) {
            const above = combo.y - h - 2;
            if (above >= k_card_top) y = above;
        }
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    // -----------------------------------------------------------------------
    // Paint
    // -----------------------------------------------------------------------

    pub fn paint(
        self: *Page,
        cr: ?*cairo.cairo_t,
        g: Geo,
        px: f64,
        ly: f64,
        glass_ov: f64,
    ) void {
        const c = cr orelse return;
        if (!self.inited) return;
        self.refresh(g.tab, false);
        _ = self.frame_arena.reset(.retain_capacity);
        const ge = self.computeGeom(g);
        self.paintChildren(c, g, ge, glass_ov);
        if (self.dd_open) {
            self.rebuildDd();
            self.paintDropdown(c, g, ge, px, ly);
        }
    }

    fn paintChildren(self: *Page, c: *cairo.cairo_t, g: Geo, ge: Geom, g_ov: f64) void {
        switch (childOf(g.tab)) {
            .devices => self.paintDevices(c, ge, g_ov),
            .bluetooth => self.paintCardsSection(c, ge.cards, "Bluetooth Audio", "bluetooth", "No Bluetooth audio devices connected.", g_ov),
            .apps => self.paintApps(c, ge, g_ov),
            .engine => self.paintEngine(c, ge, g_ov),
        }
    }

    fn paintHeading(c: *cairo.cairo_t, sec: SGeom, title: []const u8, glyph: []const u8) void {
        const t = common.Theme;
        ui_paint.glyph(
            c,
            @floatFromInt(sec.x + common.card_pad + 7),
            @floatFromInt(sec.y + 17),
            14,
            glyph,
            t.acc_r,
            t.acc_g,
            t.acc_b,
            0.9,
        );
        ui_paint.catLabel(
            c,
            @floatFromInt(sec.x + common.card_pad + 20),
            @floatFromInt(sec.y + 21),
            title,
        );
    }

    fn paintCombo(c: *cairo.cairo_t, r: common.Rect, value: []const u8, open: bool) void {
        const t = common.Theme;
        ui_paint.roundRect(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 8);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, if (open) 0.10 else 0.06);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (open) 0.9 else 0.45);
        cairo.cairo_stroke(c);
        // Leave room for the chevron and the right padding; Pango ellipsises
        // anything longer than the (already text-fitted) box.
        ui_paint.showTextW(
            c,
            @floatFromInt(r.x + 10),
            @floatFromInt(r.y + 19),
            value,
            12,
            500,
            @as(f64, @floatFromInt(@max(0, r.w - 10 - 26))),
            t.text_r,
            t.text_g,
            t.text_b,
            0.92,
        );
        ui_paint.glyph(
            c,
            @floatFromInt(r.x + r.w - 12),
            @floatFromInt(r.y + @divTrunc(r.h, 2)),
            13,
            "expand_more",
            t.text_r,
            t.text_g,
            t.text_b,
            0.55,
        );
    }

    /// One volume row: mute icon button, track, value text.
    fn paintSliderRow(
        self: *Page,
        c: *cairo.cairo_t,
        sec: SGeom,
        row_i: i32,
        code: i32,
        muted: bool,
        pct_in: i32,
        icon_on: []const u8,
        icon_off: []const u8,
    ) void {
        const t = common.Theme;
        var pct = pct_in;
        if (self.drag) |d| {
            if (d.code == code) pct = d.pct;
        }
        const max = self.maxPct();
        pct = @max(0, @min(max, pct));
        const sg = sliderGeom(sec, row_i);
        const icon = if (muted) icon_off else icon_on;
        ui_paint.roundRect(
            c,
            @floatFromInt(sg.icon.x),
            @floatFromInt(sg.icon.y),
            @floatFromInt(sg.icon.w),
            @floatFromInt(sg.icon.h),
            8,
        );
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.06);
        cairo.cairo_fill(c);
        ui_paint.glyph(
            c,
            @floatFromInt(sg.icon.x + @divTrunc(sg.icon.w, 2)),
            @floatFromInt(sg.icon.y + @divTrunc(sg.icon.h, 2)),
            16,
            icon,
            t.text_r,
            t.text_g,
            t.text_b,
            if (muted) 0.45 else 0.92,
        );
        // Track + fill + knob.
        const tr = sg.track;
        const yf: f64 = @floatFromInt(tr.y);
        const hf: f64 = @floatFromInt(tr.h);
        ui_paint.roundRect(c, @floatFromInt(tr.x), yf, @floatFromInt(tr.w), hf, hf / 2.0);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.10);
        cairo.cairo_fill(c);
        if (pct > 0) {
            const fw = @max(hf, @as(f64, @floatFromInt(tr.w)) * @as(f64, @floatFromInt(pct)) / @as(f64, @floatFromInt(max)));
            ui_paint.roundRect(c, @floatFromInt(tr.x), yf, fw, hf, hf / 2.0);
            if (muted) {
                cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.30);
            } else {
                cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.95);
            }
            cairo.cairo_fill(c);
        }
        const kx = @as(f64, @floatFromInt(tr.x)) + @as(f64, @floatFromInt(tr.w)) * @as(f64, @floatFromInt(pct)) / @as(f64, @floatFromInt(max));
        ui_paint.glassBox(c, kx - 7, yf + hf / 2.0 - 7, 14, 14, 7, 1, 1, 1, 0.96);
        var vbuf: [16]u8 = undefined;
        const vs = std.fmt.bufPrint(&vbuf, "{d}%", .{pct}) catch "0%";
        ui_paint.showText(
            c,
            @floatFromInt(tr.x + tr.w + 12),
            @floatFromInt(tr.y + 8),
            vs,
            12,
            600,
            t.text_r,
            t.text_g,
            t.text_b,
            0.85,
        );
    }

    fn paintToggleRow(c: *cairo.cairo_t, sec: SGeom, row_i: i32, title: []const u8, desc: []const u8, on: bool) void {
        const r = toggleRowRect(sec, row_i);
        ui_paint.settingLabel(c, @floatFromInt(r.x), @floatFromInt(r.y + 24), title, desc);
        const tw: i32 = 52;
        const th: i32 = 26;
        ui_paint.paintSwitch(
            c,
            r.x + r.w - tw,
            r.y + @divTrunc(r.h - th, 2),
            tw,
            th,
            on,
        );
    }

    fn paintLabelButtonRow(c: *cairo.cairo_t, sec: SGeom, row_i: i32, title: []const u8, desc: []const u8, label: []const u8, enabled: bool, glyph: ?[]const u8) void {
        const t = common.Theme;
        const r = rowButtonRect(sec, row_i);
        ui_paint.settingLabel(c, @floatFromInt(sec.x + common.card_pad), @floatFromInt(sec.y0 + row_i * k_row_h + 24), title, desc);
        if (enabled) {
            ui_paint.paintBtn(c, r.x, r.y, r.w, r.h, label, false);
        } else {
            ui_paint.paintBtnDisabled(c, r.x, r.y, r.w, r.h, label);
        }
        if (glyph) |gl| {
            ui_paint.glyph(
                c,
                @floatFromInt(r.x + 22),
                @floatFromInt(r.y + @divTrunc(r.h, 2)),
                15,
                gl,
                t.acc_r,
                t.acc_g,
                t.acc_b,
                if (enabled) 0.95 else 0.5,
            );
        }
    }

    // --- Devices -----------------------------------------------------------

    fn paintDevices(self: *Page, c: *cairo.cairo_t, ge: Geom, g_ov: f64) void {
        const sec = ge.devices;
        ui_paint.card(c, @floatFromInt(sec.x), @floatFromInt(sec.y), @floatFromInt(sec.w), @floatFromInt(sec.h), g_ov);
        paintHeading(c, sec, "Alsa Devices", "speaker");

        const sink = self.storeDevice();
        const source = self.sourceDevice();

        // Row 0: default output combo.
        ui_paint.settingLabel(c, @floatFromInt(sec.x + common.card_pad), @floatFromInt(sec.y0 + 24), "Default output", "");
        {
            const disp = self.comboDisplay(0);
            const r = comboRect(sec, 0, disp);
            paintCombo(c, r, disp, self.dd_open and self.dd_id == 0);
        }
        // Row 1: output volume.
        self.paintSliderRow(c, sec, 1, 2000, hasDevice(sink) and sink.muted, if (hasDevice(sink)) sink.volume_pct else 100, "volume_up", "volume_off");

        // Row 2: default input combo.
        ui_paint.settingLabel(c, @floatFromInt(sec.x + common.card_pad), @floatFromInt(sec.y0 + 2 * k_row_h + 24), "Default input", "");
        {
            const disp = self.comboDisplay(1);
            const r = comboRect(sec, 2, disp);
            paintCombo(c, r, disp, self.dd_open and self.dd_id == 1);
        }
        // Row 3: input volume.
        self.paintSliderRow(c, sec, 3, 2001, hasDevice(source) and source.muted, if (hasDevice(source)) source.volume_pct else 100, "mic", "mic_off");

        // Row 4: over-amplification toggle.
        paintToggleRow(c, sec, 4, "Allow volume above 100%", "Lets volume reach 150% on every output and stream.", self.overamp);

        // Row 5: speaker test.
        const testable = hasDevice(sink);
        paintLabelButtonRow(
            c,
            sec,
            5,
            "Speaker test",
            "Play test tones on the default output",
            if (testable) "Test Speakers" else "No Output",
            testable,
            null,
        );

        self.paintCardsSection(c, ge.cards, "Card profiles", "tune", "No configurable audio cards found.", g_ov);
    }

    fn paintCardsSection(
        self: *Page,
        c: *cairo.cairo_t,
        sec: SGeom,
        title: []const u8,
        glyph: []const u8,
        empty: []const u8,
        g_ov: f64,
    ) void {
        const t = common.Theme;
        ui_paint.card(c, @floatFromInt(sec.x), @floatFromInt(sec.y), @floatFromInt(sec.w), @floatFromInt(sec.h), g_ov);
        paintHeading(c, sec, title, glyph);
        if (self.cards.len == 0) {
            ui_paint.showText(
                c,
                @floatFromInt(sec.x + common.card_pad),
                @floatFromInt(sec.y0 + 22),
                empty,
                12,
                400,
                t.text_r,
                t.text_g,
                t.text_b,
                0.70,
            );
            return;
        }
        for (self.cards, 0..) |card, i| {
            const row_i: i32 = @intCast(i);
            const raw_name = if (card.card_name.len > 0) card.card_name else card.card_key;
            ui_paint.settingLabel(
                c,
                @floatFromInt(sec.x + common.card_pad),
                @floatFromInt(sec.y0 + row_i * k_row_h + 24),
                shortDeviceLabel(self.frame_arena.allocator(), raw_name),
                "",
            );
            const disp = self.profileComboDisplay(card);
            const r = comboRect(sec, row_i, disp);
            paintCombo(c, r, disp, self.dd_open and self.dd_id == 600 + row_i);
        }
    }

    fn profileComboDisplay(self: *Page, card: live_audio.AudioCard) []const u8 {
        for (card.profiles) |p| {
            if (std.mem.eql(u8, p.key, card.active_profile_key)) return shortProfileLabel(self.frame_arena.allocator(), p);
        }
        return if (card.active_profile_key.len > 0) card.active_profile_key else "(unavailable)";
    }

    // --- Apps --------------------------------------------------------------

    fn paintApps(self: *Page, c: *cairo.cairo_t, ge: Geom, g_ov: f64) void {
        const t = common.Theme;
        const pb = ge.playback;
        ui_paint.card(c, @floatFromInt(pb.x), @floatFromInt(pb.y), @floatFromInt(pb.w), @floatFromInt(pb.h), g_ov);
        paintHeading(c, pb, "Playback", "play_arrow");
        const q = if (self.q) |*qq| qq else null;
        if (q == null or q.?.snap.out_streams.len == 0) {
            ui_paint.showText(c, @floatFromInt(pb.x + common.card_pad), @floatFromInt(pb.y0 + 22), "No applications are playing audio.", 12, 400, t.text_r, t.text_g, t.text_b, 0.70);
        } else {
            for (q.?.snap.out_streams, 0..) |st, i| {
                self.paintStreamRows(c, pb, @intCast(i), st, false);
            }
        }

        const rc = ge.recording;
        ui_paint.card(c, @floatFromInt(rc.x), @floatFromInt(rc.y), @floatFromInt(rc.w), @floatFromInt(rc.h), g_ov);
        paintHeading(c, rc, "Recording", "mic");
        if (q == null or q.?.snap.in_streams.len == 0) {
            ui_paint.showText(c, @floatFromInt(rc.x + common.card_pad), @floatFromInt(rc.y0 + 22), "No applications are recording.", 12, 400, t.text_r, t.text_g, t.text_b, 0.70);
        } else {
            for (q.?.snap.in_streams, 0..) |st, i| {
                self.paintStreamRows(c, rc, @intCast(i), st, true);
            }
        }
    }

    fn paintStreamRows(self: *Page, c: *cairo.cairo_t, sec: SGeom, i: i32, st: live_audio.Stream, is_input: bool) void {
        const t = common.Theme;
        const row_a = i * 2;
        const row_b = i * 2 + 1;
        const ay = sec.y0 + row_a * k_row_h;
        const resolved = self.resolveStream(st);

        // Row A: icon + name + description + route combo.
        const icon_x = sec.x + common.card_pad;
        const icon_y = ay + @divTrunc(k_row_h - k_app_icon, 2);
        ui_paint.glassBox(
            c,
            @floatFromInt(icon_x),
            @floatFromInt(icon_y),
            @floatFromInt(k_app_icon),
            @floatFromInt(k_app_icon),
            k_app_icon_rad,
            t.acc_r,
            t.acc_g,
            t.acc_b,
            0.16,
        );
        var icon_drawn = false;
        if (self.iconForStream(resolved, st)) |icon| {
            blitIcon(c, icon, @floatFromInt(icon_x), @floatFromInt(icon_y), @floatFromInt(k_app_icon));
            icon_drawn = true;
        }
        if (!icon_drawn) {
            ui_paint.glyph(
                c,
                @floatFromInt(icon_x + @divTrunc(k_app_icon, 2)),
                @floatFromInt(icon_y + @divTrunc(k_app_icon, 2)),
                18,
                "apps",
                t.acc_r,
                t.acc_g,
                t.acc_b,
                0.95,
            );
        }

        const name = resolved.app_name;
        ui_paint.showText(c, @floatFromInt(icon_x + k_app_icon + common.spacing_m), @floatFromInt(ay + 24), name, 13, 600, t.text_r, t.text_g, t.text_b, 0.95);
        if (st.description.len > 0 and !std.mem.eql(u8, st.description, name)) {
            ui_paint.showText(c, @floatFromInt(icon_x + k_app_icon + common.spacing_m), @floatFromInt(ay + 40), st.description, 11, 400, t.text_r, t.text_g, t.text_b, 0.46);
        }

        const code: i32 = if (is_input) @as(i32, 1000) + i else @as(i32, 100) + i;
        const route_disp = self.routeDisplay(st, is_input);
        const cr_rect = comboRect(sec, row_a, route_disp);
        paintCombo(c, cr_rect, route_disp, self.dd_open and self.dd_id == code);

        // Row B: mute icon + slider + %.
        const code_b: i32 = if (is_input) 1000 + i else i;
        self.paintSliderRow(c, sec, row_b, code_b, st.muted, st.volume_pct, "volume_up", "volume_off");
    }

    /// Resolve a stream's display name + icon through the shared desktop
    /// candidates (same resolution the mixer popup uses). Strings land in
    /// the per-frame arena.
    fn resolveStream(self: *Page, st: live_audio.Stream) vmx.ResolvedName {
        const fa = self.frame_arena.allocator();
        return vmx.resolveStreamDisplay(
            fa,
            st.app_name,
            st.icon_name,
            st.app_id,
            st.process_binary,
            st.node_name,
            st.description,
            null,
        ) catch .{ .app_name = st.app_name, .icon_name = st.icon_name };
    }

    /// Try the same candidate cascade the mixer popup uses: the stream's
    /// `application.icon-name`, app id, binary basename, known theme hints
    /// and the app-name slug. The first name the theme has wins; null falls
    /// back to the generic glyph.
    fn iconForStream(self: *Page, resolved: vmx.ResolvedName, st: live_audio.Stream) ?*const icon_cache.Owned {
        var names: [24][2][]const u8 = undefined;
        for (vmx.streamIconNames(&names, resolved.icon_name, st.app_id, st.process_binary, resolved.app_name)) |cand| {
            if (self.iconForName(cand[0])) |icon| return icon;
        }
        return null;
    }

    /// Borrowed icon pixels for a resolved icon name, cached for the page's
    /// life (keys are page-owned dups — the snapshot they came from is freed
    /// every second).
    fn iconForName(self: *Page, icon_name: []const u8) ?*const icon_cache.Owned {
        if (icon_name.len == 0) return null;
        if (self.icon_pixels.getEntry(icon_name)) |e| return &e.value_ptr.*;
        const ic = icon_cache.shared() orelse return null;
        const owned = ic.getOwned(.app, icon_name, k_app_icon) orelse return null;
        const key = self.alloc.dupe(u8, icon_name) catch {
            var o = owned;
            o.deinit(self.alloc);
            return null;
        };
        const gop = self.icon_pixels.getOrPut(self.alloc, key) catch {
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

    // --- Engine ------------------------------------------------------------

    fn paintEngine(self: *Page, c: *cairo.cairo_t, ge: Geom, g_ov: f64) void {
        const t = common.Theme;
        const sec = ge.engine;
        ui_paint.card(c, @floatFromInt(sec.x), @floatFromInt(sec.y), @floatFromInt(sec.w), @floatFromInt(sec.h), g_ov);
        paintHeading(c, sec, "Engine & default output", "tune");

        var buf_rate: [32]u8 = undefined;
        var buf_force: [32]u8 = undefined;
        var buf_quantum: [32]u8 = undefined;
        var buf_force_q: [32]u8 = undefined;
        const disp_rate = hzDisplay(&buf_rate, self.es.clock_rate_hz);
        const disp_force = if (self.es.clock_force_rate_hz == 0) "Auto" else hzDisplay(&buf_force, self.es.clock_force_rate_hz);
        const disp_quantum = if (self.es.clock_quantum == 0) "Auto (default)" else (std.fmt.bufPrint(&buf_quantum, "{d} frames", .{self.es.clock_quantum}) catch "?");
        const disp_force_q = if (self.es.clock_force_quantum == 0) "Auto" else (std.fmt.bufPrint(&buf_force_q, "{d} frames", .{self.es.clock_force_quantum}) catch "?");
        const items = [_]struct { label: []const u8, id: i32, disp: []const u8 }{
            .{ .label = "Default rate", .id = 2, .disp = disp_rate },
            .{ .label = "Force graph rate", .id = 3, .disp = disp_force },
            .{ .label = "Allowed rates preset", .id = 4, .disp = allowedPresetLabel(allowedPresetSel(self.es.clock_rate_hz, self.es.allowed_rates_hz)) },
            .{ .label = "Default PCM format", .id = 5, .disp = if (!self.have_pcm or self.pcm_choice < 0 or self.pcm_choice > 3) "(unknown)" else k_pcm_labels[@intCast(self.pcm_choice)] },
            .{ .label = "Default quantum", .id = 6, .disp = disp_quantum },
            .{ .label = "Force quantum", .id = 7, .disp = disp_force_q },
        };
        for (items, 0..) |it, i| {
            const col: i32 = @intCast(i % 2);
            const row_i: i32 = @intCast(i / 2);
            const cell = gridCellRect(sec, col, row_i);
            ui_paint.showText(c, @floatFromInt(cell.x), @floatFromInt(cell.y - 4), it.label, 11, 500, t.text_r, t.text_g, t.text_b, 0.55);
            paintCombo(c, cell, it.disp, self.dd_open and self.dd_id == it.id);
        }

        // Restart row (arm-to-confirm).
        const now = nowMs();
        const armed = self.restart_arm_ms >= 0 and now - self.restart_arm_ms >= 0 and now - self.restart_arm_ms <= k_restart_arm_ms;
        const done = self.restart_done_ms >= 0 and now - self.restart_done_ms <= k_restart_done_ms;
        if (self.restart_arm_ms >= 0 and now - self.restart_arm_ms > k_restart_arm_ms) self.restart_arm_ms = -1;
        if (self.restart_done_ms >= 0 and now - self.restart_done_ms > k_restart_done_ms) self.restart_done_ms = -1;
        const ry = restartRowY(sec);
        ui_paint.settingLabel(
            c,
            @floatFromInt(sec.x + common.card_pad),
            @floatFromInt(ry + 22),
            "Restart audio services",
            "Briefly stops all audio while PipeWire and WirePlumber come back.",
        );
        const br = restartBtnRect(sec);
        const label = if (done) "Restarted" else if (armed) "Confirm" else "Restart";
        ui_paint.paintBtn(c, br.x, br.y, br.w, br.h, label, false);
        if (done) {
            ui_paint.glyph(c, @floatFromInt(br.x + 22), @floatFromInt(br.y + @divTrunc(br.h, 2)), 15, "check", t.acc_r, t.acc_g, t.acc_b, 0.95);
        }
    }

    fn paintDropdown(self: *Page, c: *cairo.cairo_t, g: Geo, ge: Geom, px: f64, ly: f64) void {
        const t = common.Theme;
        const combo = self.ddComboRect(ge);
        const list = self.ddListRect(g, combo);
        // Opaque panel so page text cannot bleed through.
        ui_paint.roundRect(c, @floatFromInt(list.x), @floatFromInt(list.y), @floatFromInt(list.w), @floatFromInt(list.h), 12);
        cairo.cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 1.0);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.35);
        cairo.cairo_stroke(c);

        ui_paint.showText(c, @floatFromInt(list.x + 12), @floatFromInt(list.y + 21), self.dd_title, 11, 700, t.text_r, t.text_g, t.text_b, 0.55);
        const row_h = 30;
        var hover: i32 = -1;
        if (inRect(px, ly, list)) {
            const rel = @divTrunc(@as(i32, @intFromFloat(@max(0, ly))) - (list.y + 28), row_h);
            if (rel >= 0 and rel < @as(i32, @intCast(self.dd_rows_len))) hover = rel;
        }
        self.dd_hover = hover;
        for (self.dd_rows[0..self.dd_rows_len], 0..) |row, i| {
            const ri: i32 = @intCast(i);
            const ry = list.y + 28 + ri * row_h;
            const hov = ri == hover;
            if (hov) {
                ui_paint.glassBox(c, @floatFromInt(list.x + 6), @floatFromInt(ry + 2), @floatFromInt(list.w - 12), @floatFromInt(row_h - 4), 8, 1, 1, 1, 0.08);
            }
            const sel = ri == self.dd_sel;
            ui_paint.showTextW(
                c,
                @floatFromInt(list.x + 30),
                @floatFromInt(ry + 21),
                row,
                12,
                500,
                @as(f64, @floatFromInt(@max(0, list.w - 30 - 10))),
                if (sel) t.acc_r else t.text_r,
                if (sel) t.acc_g else t.text_g,
                if (sel) t.acc_b else t.text_b,
                if (sel) 1.0 else 0.88,
            );
            if (sel) {
                ui_paint.glyph(c, @floatFromInt(list.x + 18), @floatFromInt(ry + @divTrunc(row_h, 2)), 10, "check", t.acc_r, t.acc_g, t.acc_b, 1.0);
            }
        }
    }

    /// The combo rect of the open dropdown (mirrors the paint-side rects).
    fn ddComboRect(self: *Page, ge: Geom) common.Rect {
        const id = self.dd_id;
        if (id == 0) return comboRect(ge.devices, 0, self.comboDisplay(0));
        if (id == 1) return comboRect(ge.devices, 2, self.comboDisplay(1));
        if (id >= 2 and id <= 7) {
            const idx: i32 = id - 2;
            return gridCellRect(ge.engine, @mod(idx, 2), @divTrunc(idx, 2));
        }
        if (id >= 600 and id < 1000) {
            const i = id - 600;
            if (i >= 0 and i < @as(i32, @intCast(self.cards.len))) {
                const card = self.cards[@intCast(i)];
                return comboRect(ge.cards, i, self.profileComboDisplay(card));
            }
            return comboRect(ge.cards, 0, "");
        }
        if (id >= 100 and id < 600) {
            const i = id - 100;
            if (self.q) |q| {
                if (i >= 0 and i < @as(i32, @intCast(q.snap.out_streams.len))) {
                    return comboRect(ge.playback, i * 2, self.routeDisplay(q.snap.out_streams[@intCast(i)], false));
                }
            }
            return comboRect(ge.playback, 0, "");
        }
        const i = id - 1000;
        if (self.q) |q| {
            if (i >= 0 and i < @as(i32, @intCast(q.snap.in_streams.len))) {
                return comboRect(ge.recording, i * 2, self.routeDisplay(q.snap.in_streams[@intCast(i)], true));
            }
        }
        return comboRect(ge.recording, 0, "");
    }

    // -----------------------------------------------------------------------
    // Hit
    // -----------------------------------------------------------------------

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        if (!self.inited) return null;
        self.refresh(g.tab, false);
        const ge = self.computeGeom(g);

        // Open dropdown eats the press: a row pick or a dismiss.
        if (self.dd_open) {
            self.rebuildDd();
            const combo = self.ddComboRect(ge);
            const list = self.ddListRect(g, combo);
            if (inRect(px, ly, list)) {
                const row_h = 30;
                const rel = @divTrunc(@as(i32, @intFromFloat(@max(0, ly))) - (list.y + 28), row_h);
                if (rel >= 0 and rel < @as(i32, @intCast(self.dd_rows_len))) {
                    const act = self.applyPick(self.dd_id, rel);
                    self.closeDropdown();
                    return act;
                }
                // Title / padding: dismiss only.
                self.closeDropdown();
                return .repaint;
            }
            self.closeDropdown();
            return .repaint;
        }

        var act: ?Action = null;
        switch (childOf(g.tab)) {
            .devices => act = self.hitDevices(ge, px, ly),
            .bluetooth => act = self.hitCards(ge.cards, ge, px, ly),
            .apps => act = self.hitApps(ge, px, ly),
            .engine => act = self.hitEngine(ge, px, ly),
        }
        return act;
    }

    fn hitDevices(self: *Page, ge: Geom, px: f64, ly: f64) ?Action {
        const sec = ge.devices;
        const sink = self.storeDevice();
        const source = self.sourceDevice();

        if (inRect(px, ly, comboRect(sec, 0, self.comboDisplay(0)))) {
            self.openDropdown(0);
            return .repaint;
        }
        if (inRect(px, ly, comboRect(sec, 2, self.comboDisplay(1)))) {
            self.openDropdown(1);
            return .repaint;
        }
        if (hasDevice(sink)) {
            const sg = sliderGeom(sec, 1);
            if (inRect(px, ly, sg.icon)) {
                _ = live_audio.setDeviceMute(self.io, sink.name, sink.id, false, !sink.muted);
                self.snap_ms = 0;
                return .{ .persist = .{ .sink_muted = !sink.muted } };
            }
            if (inRect(px, ly, sg.track)) {
                self.beginDrag(2000, false, sink.name, sink.id, -1, sg.track, px);
                return .repaint;
            }
        }
        if (hasDevice(source)) {
            const sg = sliderGeom(sec, 3);
            if (inRect(px, ly, sg.icon)) {
                _ = live_audio.setDeviceMute(self.io, source.name, source.id, true, !source.muted);
                self.snap_ms = 0;
                return .{ .persist = .{ .source_muted = !source.muted } };
            }
            if (inRect(px, ly, sg.track)) {
                self.beginDrag(2001, true, source.name, source.id, -1, sg.track, px);
                return .repaint;
            }
        }
        if (inRect(px, ly, toggleRowRect(sec, 4))) {
            return .overamp_toggle;
        }
        if (inRect(px, ly, rowButtonRect(sec, 5))) {
            if (hasDevice(sink)) {
                if (live_audio.testSpeakers(self.io, sink.name)) |pid| self.rememberTone(pid);
            }
            return .repaint;
        }
        if (self.hitCards(ge.cards, ge, px, ly)) |a| return a;
        return null;
    }

    fn hitCards(self: *Page, sec: SGeom, ge: Geom, px: f64, ly: f64) ?Action {
        _ = ge;
        for (self.cards, 0..) |card, i| {
            const row_i: i32 = @intCast(i);
            if (inRect(px, ly, comboRect(sec, row_i, self.profileComboDisplay(card)))) {
                self.openDropdown(600 + row_i);
                return .repaint;
            }
        }
        return null;
    }

    fn hitApps(self: *Page, ge: Geom, px: f64, ly: f64) ?Action {
        const q = if (self.q) |*qq| qq else return null;
        for (q.snap.out_streams, 0..) |st, i| {
            const row_i: i32 = @intCast(i);
            if (inRect(px, ly, comboRect(ge.playback, row_i * 2, self.routeDisplay(st, false)))) {
                self.openDropdown(100 + row_i);
                return .repaint;
            }
            const sg = sliderGeom(ge.playback, row_i * 2 + 1);
            if (inRect(px, ly, sg.icon)) {
                _ = live_audio.setStreamMute(self.io, st.id, false, !st.muted);
                self.snap_ms = 0;
                return .repaint;
            }
            if (inRect(px, ly, sg.track)) {
                self.beginDrag(row_i, false, "", 0, st.id, sg.track, px);
                return .repaint;
            }
        }
        for (q.snap.in_streams, 0..) |st, i| {
            const row_i: i32 = @intCast(i);
            if (inRect(px, ly, comboRect(ge.recording, row_i * 2, self.routeDisplay(st, true)))) {
                self.openDropdown(1000 + row_i);
                return .repaint;
            }
            const sg = sliderGeom(ge.recording, row_i * 2 + 1);
            if (inRect(px, ly, sg.icon)) {
                _ = live_audio.setStreamMute(self.io, st.id, true, !st.muted);
                self.snap_ms = 0;
                return .repaint;
            }
            if (inRect(px, ly, sg.track)) {
                self.beginDrag(1000 + row_i, true, "", 0, st.id, sg.track, px);
                return .repaint;
            }
        }
        return null;
    }

    fn hitEngine(self: *Page, ge: Geom, px: f64, ly: f64) ?Action {
        const sec = ge.engine;
        for (0..6) |i| {
            const col: i32 = @intCast(i % 2);
            const row_i: i32 = @intCast(i / 2);
            const cell = gridCellRect(sec, col, row_i);
            if (inRect(px, ly, cell)) {
                self.openDropdown(2 + @as(i32, @intCast(i)));
                return .repaint;
            }
        }
        if (inRect(px, ly, restartBtnRect(sec))) {
            const now = nowMs();
            const armed = self.restart_arm_ms >= 0 and now - self.restart_arm_ms <= k_restart_arm_ms;
            if (!armed) {
                self.restart_arm_ms = now;
                return .repaint;
            }
            self.restart_arm_ms = -1;
            _ = live_audio.restartServices(self.io);
            self.restart_done_ms = nowMs();
            self.snap_ms = 0;
            self.engine_ms = 0;
            self.cards_ms = 0;
            return .repaint;
        }
        return null;
    }

    /// Apply a dropdown pick; returns the window-owned follow-up (persist or
    /// overamp) when there is one.
    fn applyPick(self: *Page, id: i32, row: i32) ?Action {
        const q = if (self.q) |*qq| qq else return null;
        if (id == 0) {
            if (row >= 0 and row < q.snap.sinks.len) {
                const d = q.snap.sinks[@intCast(row)];
                _ = live_audio.setDefaultSink(self.io, d.name);
                self.snap_ms = 0;
                return .{ .persist = .{ .sink_name = d.name } };
            }
            return null;
        }
        if (id == 1) {
            if (row >= 0 and row < q.snap.sources.len) {
                const d = q.snap.sources[@intCast(row)];
                _ = live_audio.setDefaultSource(self.io, d.name);
                self.snap_ms = 0;
                return .{ .persist = .{ .source_name = d.name } };
            }
            return null;
        }
        if (id >= 2 and id <= 7) return self.applyEnginePick(id, row);
        if (id >= 600 and id < 1000) {
            const ci: usize = @intCast(id - 600);
            if (ci < self.cards.len) {
                const card = self.cards[ci];
                if (row >= 0 and row < card.profiles.len) {
                    const key = card.profiles[@intCast(row)].key;
                    const force_off = live_audio.isBluetoothCard(card.card_key) and live_audio.isVendorCodecProfile(key);
                    _ = live_audio.setCardProfile(self.io, card.card_index, key, force_off);
                    self.cards_ms = 0;
                }
            }
            return .repaint;
        }
        if (id >= 100 and id < 600) {
            const si: usize = @intCast(id - 100);
            if (si < q.snap.out_streams.len and q.snap.out_streams[si].id > 0) {
                const st = q.snap.out_streams[si];
                if (row == 0) {
                    const d = self.storeDevice();
                    if (hasDevice(d)) _ = live_audio.moveSinkInput(self.io, @intCast(st.id), d.name);
                } else if (row - 1 < q.snap.sinks.len) {
                    const d = q.snap.sinks[@intCast(row - 1)];
                    _ = live_audio.moveSinkInput(self.io, @intCast(st.id), d.name);
                }
                self.link_ms = 0;
                self.snap_ms = 0;
            }
            return .repaint;
        }
        if (id >= 1000) {
            const si: usize = @intCast(id - 1000);
            if (si < q.snap.in_streams.len and q.snap.in_streams[si].id > 0) {
                const st = q.snap.in_streams[si];
                if (row == 0) {
                    const d = self.sourceDevice();
                    if (hasDevice(d)) _ = live_audio.moveSourceOutput(self.io, @intCast(st.id), d.name);
                } else if (row - 1 < q.snap.sources.len) {
                    const d = q.snap.sources[@intCast(row - 1)];
                    _ = live_audio.moveSourceOutput(self.io, @intCast(st.id), d.name);
                }
                self.link_ms = 0;
                self.snap_ms = 0;
            }
            return .repaint;
        }
        return null;
    }

    fn applyEnginePick(self: *Page, id: i32, row: i32) ?Action {
        const now = nowMs();
        if (id == 2) {
            if (row >= 0 and row < k_engine_rates.len) {
                const hz = k_engine_rates[@intCast(row)];
                _ = live_audio.applyEngineClockRateHz(self.io, hz);
                self.engine_ms = now - k_engine_ms + 150;
                return .{ .persist = .{ .clock_hz = hz } };
            }
            return null;
        }
        if (id == 3) {
            const hz: i32 = if (row == 0) 0 else if (row - 1 < k_engine_rates.len) k_engine_rates[@intCast(row - 1)] else return null;
            _ = live_audio.applyEngineForceRateHz(self.io, hz);
            self.engine_ms = now - k_engine_ms + 150;
            return .{ .persist = .{ .force_hz = hz } };
        }
        if (id == 4) {
            if (row >= 0 and row < 4) {
                if (row == 3) {
                    self.rate_single[0] = self.es.clock_rate_hz;
                    _ = live_audio.applyEngineAllowedRatesHz(self.io, &self.rate_single);
                    self.engine_ms = now - k_engine_ms + 150;
                    return .{ .persist = .{ .rates = &self.rate_single } };
                }
                if (presetRates(row)) |rates| {
                    _ = live_audio.applyEngineAllowedRatesHz(self.io, rates);
                    self.engine_ms = now - k_engine_ms + 150;
                    return .{ .persist = .{ .rates = rates } };
                }
            }
            return null;
        }
        if (id == 5) {
            if (row >= 0 and row < 4) {
                const choice: i32 = row;
                _ = live_audio.applyCompatPcm(self.alloc, self.io, choice);
                self.pcm_choice = choice;
                self.pcm_ms = now;
                self.have_pcm = true;
                return .{ .persist = .{ .pcm = choice } };
            }
            return null;
        }
        if (id == 6) {
            const qn: i32 = if (row == 0) 0 else if (row - 1 < k_engine_quantums.len) k_engine_quantums[@intCast(row - 1)] else return null;
            _ = live_audio.applyEngineQuantum(self.io, qn);
            self.engine_ms = now - k_engine_ms + 150;
            return .{ .persist = .{ .quantum = qn } };
        }
        if (id == 7) {
            const qn: i32 = if (row == 0) 0 else if (row - 1 < k_engine_quantums.len) k_engine_quantums[@intCast(row - 1)] else return null;
            _ = live_audio.applyEngineForceQuantum(self.io, qn);
            self.engine_ms = now - k_engine_ms + 150;
            return .{ .persist = .{ .force_quantum = qn } };
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Drag
    // -----------------------------------------------------------------------

    fn beginDrag(self: *Page, code: i32, is_input: bool, raw: []const u8, node_id: u32, stream_id: i32, track: common.Rect, px: f64) void {
        const pct = common.sliderValueFromX(px, track.x, track.w, 0, self.maxPct());
        self.drag = .{
            .code = code,
            .is_input = is_input,
            .raw = raw,
            .node_id = node_id,
            .stream_id = stream_id,
            .pct = pct,
            .track = track,
        };
        self.drag_apply_ms = 0;
        self.applyDragNow();
    }

    /// Pointer moved while dragging: repaint-only updates at full rate, live
    /// writes throttled to ~25 Hz (the CC/dock pace).
    pub fn dragMotion(self: *Page, g: Geo, px: f64, ly: f64) bool {
        _ = g;
        _ = ly;
        const d = &(self.drag orelse return false);
        const pct = common.sliderValueFromX(px, d.track.x, d.track.w, 0, self.maxPct());
        d.pct = pct;
        const now = nowMs();
        if (now - self.drag_apply_ms >= k_drag_apply_ms) self.applyDragNow();
        return true;
    }

    fn applyDragNow(self: *Page) void {
        const d = self.drag orelse return;
        self.drag_apply_ms = nowMs();
        if (d.code == 2000 or d.code == 2001) {
            _ = live_audio.setDeviceVolume(self.io, d.raw, d.node_id, d.is_input, d.pct);
        } else if (d.stream_id >= 0) {
            _ = live_audio.setStreamVolume(self.io, d.stream_id, d.is_input, d.pct);
        }
    }

    /// Release: land the final write and unfreeze the snapshot.
    pub fn endDrag(self: *Page) bool {
        if (self.drag == null) return false;
        self.applyDragNow();
        self.drag = null;
        self.snap_ms = nowMs() - k_snap_ms + 200;
        return true;
    }
};

/// Blit cached icon pixels (cairo ARGB32) into a `size`-sized square,
/// aspect-preserved and centred (same as the generic renderer's combo
/// icons).
fn blitIcon(c: *cairo.cairo_t, icon: *const icon_cache.Owned, x: f64, y: f64, size: f64) void {
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
    cairo.cairo_translate(
        c,
        x + (size - @as(f64, @floatFromInt(tw))) * 0.5,
        y + (size - @as(f64, @floatFromInt(th))) * 0.5,
    );
    cairo.cairo_scale(c, sf, sf);
    cairo.cairo_set_source_surface(c, tmp, 0, 0);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sound-tab: rail ids and children" {
    const t = std.testing;
    try t.expect(isSoundTab(devices_tab));
    try t.expect(isSoundTab(bt_audio_tab));
    try t.expect(isSoundTab(apps_tab));
    try t.expect(isSoundTab(engine_tab));
    try t.expect(!isSoundTab(3));
    try t.expectEqual(Child.bluetooth, childOf(81));
    try t.expectEqual(Child.engine, childOf(83));
    try t.expectEqual(Child.devices, childOf(8));
}

test "sound-tab: engine rate labels" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("44.1 kHz", hzDisplay(&buf, 44100));
    try t.expectEqualStrings("48 kHz", hzDisplay(&buf, 48000));
    try t.expectEqualStrings("192 kHz", hzDisplay(&buf, 192000));
    try t.expectEqualStrings("96 kHz", hzDisplay(&buf, 96000));
}

test "sound-tab: combo boxes fit their value and clamp to the card" {
    const t = std.testing;
    const sec = SGeom{ .x = 100, .w = 600, .y0 = 200 };

    const narrow = comboRect(sec, 0, "Off");
    try t.expectEqual(common.settings_combo_w, narrow.w);
    try t.expectEqual(sec.x + sec.w - common.card_pad, narrow.x + narrow.w);
    try t.expectEqual(@as(i32, 200 + @divTrunc(k_row_h - common.settings_combo_h, 2)), narrow.y);

    // A long profile name widens the box instead of clipping, with the
    // right edge pinned to the card padding.
    const wide = comboRect(sec, 0, "High Fidelity Playback (A2DP Sink, codec SBC-XQ)");
    try t.expect(wide.w > narrow.w);
    try t.expectEqual(narrow.x + narrow.w, wide.x + wide.w);

    // Never wider than the card's inner width minus the label gap.
    const huge = comboRect(sec, 0, "x" ** 400);
    try t.expectEqual(sec.w - 2 * common.card_pad - common.spacing_m, huge.w);
    try t.expectEqual(sec.x + common.card_pad + common.spacing_m, huge.x);
}

test "sound-tab: dropdown fits the longest row and stays in the window" {
    const t = std.testing;
    var p: Page = .{};
    p.dd_rows[0] = "Off";
    p.dd_rows[1] = "High Fidelity Playback (A2DP Sink, codec SBC-XQ)";
    p.dd_rows_len = 2;
    const combo: common.Rect = .{ .x = 500, .y = 200, .w = 200, .h = 30 };
    const g: Geo = .{ .content_x = 386, .content_w = 498, .win_w = 900, .win_h = 900, .tab = bt_audio_tab };

    const list = p.ddListRect(g, combo);
    try t.expect(list.w >= ui_paint.measureTextWidth(p.dd_rows[1], 12, 500) + 28);
    try t.expectEqual(combo.x + combo.w, list.x + list.w);
    try t.expect(list.x + list.w <= g.win_w - 12);
    try t.expectEqual(@as(i32, 28 + 2 * 30 + 10), list.h);

    // Narrow window: the popup is pushed inside the margin, never clipped.
    const narrow: Geo = .{ .content_x = 100, .content_w = 250, .win_w = 380, .win_h = 900, .tab = bt_audio_tab };
    const nlist = p.ddListRect(narrow, .{ .x = 100, .y = 200, .w = 220, .h = 30 });
    try t.expect(nlist.x >= 12);
    try t.expect(nlist.x + nlist.w <= narrow.win_w - 12);
}

test "sound-tab: allowed-rates preset detection" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 0), allowedPresetSel(48000, &preset_hifi));
    try t.expectEqual(@as(i32, 1), allowedPresetSel(48000, &preset_consumer));
    try t.expectEqual(@as(i32, 2), allowedPresetSel(48000, &preset_pro));
    const single = [_]i32{48000};
    try t.expectEqual(@as(i32, 3), allowedPresetSel(48000, &single));
    const custom = [_]i32{ 44100, 96000 };
    try t.expectEqual(@as(i32, -1), allowedPresetSel(48000, &custom));
    try t.expectEqualStrings("Custom", allowedPresetLabel(-1));
}
