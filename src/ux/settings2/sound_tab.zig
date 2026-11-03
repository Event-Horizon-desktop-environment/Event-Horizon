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
const xkb = @import("../../wl/seat.zig").xkb;

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
    /// Selectable combo contents after an Edit-list action.
    rate_values: ?[]const i32 = null,
    quantum_values: ?[]const i32 = null,
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
const k_restart_arm_ms: i64 = 3500;
const k_restart_done_ms: i64 = 2600;
const k_drag_apply_ms: i64 = 40;
const k_snap_ms: i64 = 1000;
const k_engine_ms: i64 = 1200;
const k_cards_ms: i64 = 2500;
const k_caps_ms: i64 = 4000;
const k_max_dd_rows: usize = 32;

const k_engine_rates = [_]i32{ 44100, 48000, 88200, 96000, 176400, 192000 };
const k_engine_quantums = [_]i32{ 128, 256, 512, 1024, 2048, 4096, 8192 };
/// How many user-editable values the two Engine combos hold.
const k_max_values: usize = 16;
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
    latency: SGeom = .{},
    restart: SGeom = .{},
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

/// Engine header refresh (re-reads metadata, pw-top and PCM).
fn engineRefreshRect(sec: SGeom) common.Rect {
    return .{ .x = sec.x + sec.w - common.card_pad - 24, .y = sec.y + 12, .w = 24, .h = 24 };
}

/// Engine live-status strip under the 2x3 grid.
fn engineStatusRect(sec: SGeom) common.Rect {
    return .{
        .x = sec.x + common.card_pad,
        .y = sec.y0 + 3 * k_grid_row_h + 2,
        .w = sec.w - 2 * common.card_pad,
        .h = 64,
    };
}

fn engineCardHeight() i32 {
    return k_sec_body_top + 3 * k_grid_row_h + 2 + 64 + k_sec_bottom_pad;
}

/// Xrun reset hit target inside the status strip's middle column.
fn xrunResetRect(sec: SGeom) common.Rect {
    const s = engineStatusRect(sec);
    const col_w = @divTrunc(s.w, 3);
    return .{
        .x = s.x + 2 * col_w - 30,
        .y = s.y + 14,
        .w = 20,
        .h = 20,
    };
}

/// The whole middle readout is the reset affordance (Cable's clickable
/// counter), not just the little restart glyph.
fn xrunHitRect(sec: SGeom) common.Rect {
    const s = engineStatusRect(sec);
    const col_w = @divTrunc(s.w, 3);
    return .{ .x = s.x + col_w, .y = s.y, .w = col_w, .h = s.h };
}

/// Latency-offset card rows. The field shrinks before it can leave the card.
fn latencyFieldRect(sec: SGeom) common.Rect {
    const start = 120;
    const unit_w = 116;
    const avail = sec.w - 2 * common.card_pad - start - unit_w - common.spacing_s;
    const w = @max(60, @min(160, avail));
    return .{
        .x = sec.x + common.card_pad + start,
        .y = sec.y0 + k_row_h + @divTrunc(k_row_h - common.settings_combo_h, 2),
        .w = w,
        .h = common.settings_combo_h,
    };
}

fn latencyUnitRect(sec: SGeom) common.Rect {
    const f = latencyFieldRect(sec);
    return .{ .x = f.x + f.w + common.spacing_s, .y = f.y, .w = 116, .h = f.h };
}

fn latencyApplyRect(sec: SGeom) common.Rect {
    return .{
        .x = sec.x + sec.w - common.card_pad - 300,
        .y = sec.y0 + 2 * k_row_h + @divTrunc(k_row_h - k_restart_btn_h, 2),
        .w = 140,
        .h = k_restart_btn_h,
    };
}

fn latencyResetAllRect(sec: SGeom) common.Rect {
    const a = latencyApplyRect(sec);
    return .{ .x = a.x + a.w + common.spacing_s, .y = a.y, .w = 152, .h = a.h };
}

fn latencyCardHeight() i32 {
    return k_sec_body_top + 3 * k_row_h + k_sec_bottom_pad;
}

fn restartCardHeight() i32 {
    return k_sec_body_top + 2 * k_restart_row_h + k_sec_bottom_pad;
}

fn restartButtonRect(sec: SGeom, row_i: i32) common.Rect {
    return .{
        .x = sec.x + sec.w - common.card_pad - k_restart_btn_w,
        .y = sec.y0 + row_i * k_restart_row_h + @divTrunc(k_restart_row_h - k_restart_btn_h, 2),
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

const Modal = enum { none, custom_rate, custom_quantum, edit_rates, edit_quantums };

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
    /// `pw-top` batch for the Engine page's latency / xrun / DSP strip.
    top: live_audio.PwTopSample = .{},
    top_ms: i64 = 0,
    /// Selected output node's advertised rates/formats/quantum limit.
    caps: live_audio.NodeCaps = .{},
    caps_ms: i64 = 0,
    caps_node: u32 = 0,
    /// Xrun total when the user last pressed Reset; the display shows the
    /// delta so "reset" behaves the way Cable's counter does.
    xrun_base: i64 = 0,

    // --- Engine latency-offset card ---------------------------------------
    lat_node: i32 = -1,
    lat_ns: bool = false,
    lat_field: [24]u8 = undefined,
    lat_len: usize = 0,
    lat_focus: bool = false,
    /// Table of selectable Engine combo values (editable, persisted in
    /// `audio/audio.toml`).
    rate_values: [k_max_values]i32 = [_]i32{0} ** k_max_values,
    rate_values_len: usize = 0,
    quantum_values: [k_max_values]i32 = [_]i32{0} ** k_max_values,
    quantum_values_len: usize = 0,

    // --- modal text entry (custom value / edit list) ----------------------
    modal: Modal = .none,
    modal_buf: [256]u8 = undefined,
    modal_len: usize = 0,
    modal_select_all: bool = false,
    modal_force: bool = false,
    modal_arm: i32 = -1,
    modal_hover: i32 = -1,
    /// Action produced by a modal submit/keyboard commit; the window drains
    /// it after `key` / `modalUp`.
    pending_action: ?Action = null,
    /// Combo lists are seeded from config once; after that the page owns
    /// them and persists every edit.
    lists_seeded: bool = false,
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

    // --- restart buttons arm/done windows ---------------------------------
    restart_wp_arm_ms: i64 = -1,
    restart_wp_done_ms: i64 = -1,
    restart_pw_arm_ms: i64 = -1,
    restart_pw_done_ms: i64 = -1,

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
        self.setValueList(&self.rate_values, &self.rate_values_len, &k_engine_rates);
        self.setValueList(&self.quantum_values, &self.quantum_values_len, &k_engine_quantums);
        self.inited = true;
        self.refresh(devices_tab, true);
    }

    fn setValueList(self: *Page, dst: *[k_max_values]i32, len: *usize, src: []const i32) void {
        _ = self;
        var n: usize = 0;
        for (src) |v| {
            if (v <= 0 or n >= dst.len) continue;
            var dup = false;
            for (dst[0..n]) |have| {
                if (have == v) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            dst[n] = v;
            n += 1;
        }
        len.* = n;
    }

    fn appendRate(out: *[k_max_values]i32, n: *usize, hz: i32) void {
        if (hz <= 0 or n.* >= out.len) return;
        var i: usize = 0;
        while (i < n.*) : (i += 1) {
            if (out[i] == hz) return;
            if (out[i] > hz) break;
        }
        var j = n.*;
        while (j > i) : (j -= 1) out[j] = out[j - 1];
        out[i] = hz;
        n.* += 1;
    }

    /// Rates the selected output actually advertises. A `Range` keeps the
    /// page's common-rate list sliced to its bounds (plus the node default
    /// and any user values inside the range); an `Enum` is used verbatim.
    /// Falls back to the editable list when capabilities are unavailable.
    fn menuRates(self: *const Page, out: *[k_max_values]i32) []const i32 {
        const user = self.rate_values[0..self.rate_values_len];
        if (!self.caps.available) return user;
        var n: usize = 0;
        if (self.caps.rate_count > 0 and !self.caps.is_range) {
            for (self.caps.rates[0..self.caps.rate_count]) |hz| appendRate(out, &n, hz);
        } else {
            const lo = self.caps.rate_min;
            const hi = if (self.caps.rate_max > 0) self.caps.rate_max else std.math.maxInt(i32);
            for (k_engine_rates) |hz| {
                if (hz >= lo and hz <= hi) appendRate(out, &n, hz);
            }
            for (user) |hz| {
                if (hz >= lo and hz <= hi) appendRate(out, &n, hz);
            }
            // Range endpoints are advertised as supported even when they are
            // not one of the page's common rates (e.g. 32 kHz HDMI).
            appendRate(out, &n, self.caps.rate_min);
            appendRate(out, &n, self.caps.rate_max);
            appendRate(out, &n, self.caps.rate_default);
        }
        if (n == 0) return user;
        return out[0..n];
    }

    /// Quantum choices trimmed to the node's `clock.quantum-limit`. An
    /// empty result (or no limit) keeps the user's list as-is.
    fn menuQuantums(self: *const Page, out: *[k_max_values]i32) []const i32 {
        const user = self.quantum_values[0..self.quantum_values_len];
        if (!self.caps.available or self.caps.quantum_limit <= 0) return user;
        var n: usize = 0;
        for (user) |qn| {
            if (qn > 0 and qn <= self.caps.quantum_limit) out[n] = qn else continue;
            n += 1;
        }
        if (n == 0) return user;
        return out[0..n];
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

    /// Window-side per-frame state (`Settings` values the page cannot own).
    pub fn sync(self: *Page, overamp: bool, rate_values: []const i32, quantum_values: []const i32) void {
        self.overamp = overamp;
        if (!self.lists_seeded) {
            self.lists_seeded = true;
            if (rate_values.len > 0) self.setValueList(&self.rate_values, &self.rate_values_len, rate_values);
            if (quantum_values.len > 0) self.setValueList(&self.quantum_values, &self.quantum_values_len, quantum_values);
        }
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

    const LatNode = struct { d: live_audio.Device, is_input: bool };

    fn latNodeCount(self: *const Page) i32 {
        const q = if (self.q) |*qq| qq else return 0;
        return @intCast(q.snap.sinks.len + q.snap.sources.len);
    }

    fn latNodeAt(self: *const Page, idx: i32) ?LatNode {
        const q = if (self.q) |*qq| qq else return null;
        if (idx < 0) return null;
        const i: usize = @intCast(idx);
        if (i < q.snap.sinks.len) return .{ .d = q.snap.sinks[i], .is_input = false };
        const j = i - q.snap.sinks.len;
        if (j < q.snap.sources.len) return .{ .d = q.snap.sources[j], .is_input = true };
        return null;
    }

    fn latNodeDisplay(self: *Page) []const u8 {
        const n = self.latNodeAt(self.lat_node) orelse return "Choose a node";
        return shortDeviceLabel(self.frame_arena.allocator(), deviceLabel(n.d));
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

        if (child == .engine and (force or now - self.top_ms >= k_engine_ms)) {
            self.top = live_audio.queryPwTop(self.alloc, self.io);
            self.top_ms = now;
        }

        if (child == .engine) {
            const out_id: u32 = if (self.q) |*qq| qq.snap.out.id else 0;
            if (out_id != self.caps_node or force or now - self.caps_ms >= k_caps_ms) {
                self.caps = if (out_id != 0) live_audio.queryNodeCaps(self.alloc, self.io, out_id) else .{};
                self.caps_node = out_id;
                self.caps_ms = now;
            }
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
            const rc: isize = @bitCast(linux.wait4(pid, @ptrCast(&status), linux.W.NOHANG, null));
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
                out.engine = .{ .x = x, .y = y, .w = w, .h = engineCardHeight(), .y0 = y + k_sec_body_top };
                y += out.engine.h + k_sec_gap;
                out.latency = .{ .x = x, .y = y, .w = w, .h = latencyCardHeight(), .y0 = y + k_sec_body_top };
                y += out.latency.h + k_sec_gap;
                out.restart = .{ .x = x, .y = y, .w = w, .h = restartCardHeight(), .y0 = y + k_sec_body_top };
                y += out.restart.h;
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
            var buf: [k_max_values]i32 = undefined;
            for (self.menuRates(&buf), 0..) |hz, i| {
                if (hz == self.es.clock_rate_hz) return @intCast(i);
            }
            return -1;
        }
        if (id == 3) {
            if (self.es.clock_force_rate_hz == 0) return 0;
            var buf: [k_max_values]i32 = undefined;
            for (self.menuRates(&buf), 0..) |hz, i| {
                if (hz == self.es.clock_force_rate_hz) return @intCast(i + 1);
            }
            return -1;
        }
        if (id == 4) return allowedPresetSel(self.es.clock_rate_hz, self.es.allowed_rates_hz);
        if (id == 5) return self.pcm_choice;
        if (id == 6) {
            if (self.es.clock_quantum == 0) return 0;
            var buf: [k_max_values]i32 = undefined;
            for (self.menuQuantums(&buf), 0..) |qn, i| {
                if (qn == self.es.clock_quantum) return @intCast(i + 1);
            }
            return -1;
        }
        if (id == 7) {
            if (self.es.clock_force_quantum == 0) return 0;
            var buf: [k_max_values]i32 = undefined;
            for (self.menuQuantums(&buf), 0..) |qn, i| {
                if (qn == self.es.clock_force_quantum) return @intCast(i + 1);
            }
            return -1;
        }
        if (id == 8) return self.lat_node;
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
        if (id == 8) return "Latency offset node";
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
            8 => self.latNodeDisplay(),
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
            var rate_buf: [k_max_values]i32 = undefined;
            var qn_buf: [k_max_values]i32 = undefined;
            const rates = self.menuRates(&rate_buf);
            const quantums = self.menuQuantums(&qn_buf);
            if (id == 2) {
                for (rates) |hz| mn(self, aa, hzDisplay(&buf, hz));
                mn(self, aa, "Custom rate…");
                mn(self, aa, "Edit rate values…");
            } else if (id == 3) {
                mn(self, aa, "Auto");
                for (rates) |hz| mn(self, aa, hzDisplay(&buf, hz));
                mn(self, aa, "Custom rate…");
                mn(self, aa, "Edit rate values…");
            } else if (id == 4) {
                for (0..4) |i| mn(self, aa, allowedPresetLabel(@intCast(i)));
            } else if (id == 5) {
                for (k_pcm_labels) |l| mn(self, aa, l);
            } else if (id == 6) {
                mn(self, aa, "Auto (default)");
                for (quantums) |qn| {
                    const s = std.fmt.bufPrint(&buf, "{d} frames", .{qn}) catch continue;
                    mn(self, aa, s);
                }
                mn(self, aa, "Custom quantum…");
                mn(self, aa, "Edit quantum values…");
            } else {
                mn(self, aa, "Auto");
                for (quantums) |qn| {
                    const s = std.fmt.bufPrint(&buf, "{d} frames", .{qn}) catch continue;
                    mn(self, aa, s);
                }
                mn(self, aa, "Custom quantum…");
                mn(self, aa, "Edit quantum values…");
            }
            return;
        }
        if (id == 8) {
            const n = self.latNodeCount();
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                const node = self.latNodeAt(i) orelse continue;
                const label = shortDeviceLabel(aa, deviceLabel(node.d));
                const s = std.fmt.allocPrint(aa, "{s} ({s})", .{ label, if (node.is_input) "input" else "output" }) catch continue;
                mn(self, aa, s);
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
        if (self.modal != .none) {
            cairo.cairo_save(c);
            cairo.cairo_translate(c, 0, @floatFromInt(self.scroll_px_est));
            cairo.cairo_reset_clip(c);
            self.paintModal(c, g.win_w, g.win_h);
            cairo.cairo_restore(c);
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
        // anything longer than the (already text-fitted) box. The label is
        // pinned dead-centre the btnBody way: showText's layout top lands
        // at y - lh + 2, so passing y = top + lh - 2 centres the ink.
        const ts = ui_paint.textSizePx(c, value, 12, 500);
        const top = @as(f64, @floatFromInt(r.y)) + (@as(f64, @floatFromInt(r.h)) - @as(f64, @floatFromInt(ts.h))) / 2.0;
        ui_paint.showTextW(
            c,
            @floatFromInt(r.x + 10),
            top + @as(f64, @floatFromInt(ts.h)) - 2.0,
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
        {
            const rr = engineRefreshRect(sec);
            ui_paint.roundRect(c, @floatFromInt(rr.x), @floatFromInt(rr.y), @floatFromInt(rr.w), @floatFromInt(rr.h), 6);
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.06);
            cairo.cairo_fill(c);
            ui_paint.glyph(c, @floatFromInt(rr.x + @divTrunc(rr.w, 2)), @floatFromInt(rr.y + @divTrunc(rr.h, 2)), 14, "refresh", t.text_r, t.text_g, t.text_b, 0.62);
        }
        {
            // Detected hardware, right-aligned in the header row. Truncated
            // (not wrapped) so it can never collide with the refresh button.
            var hw_buf: [192]u8 = undefined;
            const hw = self.hardwareCaption(&hw_buf);
            const title_w = ui_paint.textSizePx(c, "Engine & default output", 10, 400).w;
            const start = sec.x + common.card_pad + 20 + title_w + 16;
            const end = engineRefreshRect(sec).x - 12;
            if (end > start + 48) {
                const tw = ui_paint.measureTextWidth(hw, 11, 500);
                const x = @max(start, end - tw);
                ui_paint.showTextW(
                    c,
                    @floatFromInt(x),
                    @floatFromInt(sec.y + 21),
                    hw,
                    11,
                    500,
                    @floatFromInt(end - x),
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    0.42,
                );
            }
        }

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

        // Live strip: latency, xruns (click to reset) and DSP load.
        const st = engineStatusRect(sec);
        ui_paint.roundRect(c, @floatFromInt(st.x), @floatFromInt(st.y), @floatFromInt(st.w), @floatFromInt(st.h), 12);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.045);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.28);
        cairo.cairo_stroke(c);

        const col_w = @divTrunc(st.w, 3);
        var i: i32 = 1;
        while (i < 3) : (i += 1) {
            cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.22);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_move_to(c, @floatFromInt(st.x + i * col_w), @floatFromInt(st.y + 10));
            cairo.cairo_line_to(c, @floatFromInt(st.x + i * col_w), @floatFromInt(st.y + st.h - 10));
            cairo.cairo_stroke(c);
        }

        var lat_buf: [32]u8 = undefined;
        const lat = self.latencyDisplay(&lat_buf);
        statusMetric(c, st.x + 14, st.y, "LATENCY", lat, t.text_r, t.text_g, t.text_b, 0.95);

        const xr = @max(@as(i64, 0), self.top.xruns_total - self.xrun_base);
        var xr_buf: [24]u8 = undefined;
        const xr_s = if (!self.top.available) "—" else std.fmt.bufPrint(&xr_buf, "{d}", .{xr}) catch "0";
        statusMetric(c, st.x + col_w + 14, st.y, "XRUNS", xr_s, t.text_r, t.text_g, t.text_b, 0.95);
        if (self.top.available) {
            const rr = xrunResetRect(sec);
            ui_paint.roundRect(c, @floatFromInt(rr.x), @floatFromInt(rr.y), @floatFromInt(rr.w), @floatFromInt(rr.h), 6);
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.06);
            cairo.cairo_fill(c);
            ui_paint.glyph(
                c,
                @floatFromInt(rr.x + @divTrunc(rr.w, 2)),
                @floatFromInt(rr.y + @divTrunc(rr.h, 2)),
                12,
                "restart_alt",
                t.text_r,
                t.text_g,
                t.text_b,
                0.62,
            );
        }

        var dsp_buf: [24]u8 = undefined;
        const dsp_s = if (!self.top.available) "—" else std.fmt.bufPrint(&dsp_buf, "{d:.0}%", .{self.top.dsp_load_pct}) catch "0%";
        const dsp_x = st.x + 2 * col_w + 14;
        statusMetric(c, dsp_x, st.y, "DSP LOAD", dsp_s, t.text_r, t.text_g, t.text_b, 0.95);
        const meter_y = st.y + st.h - 16;
        const meter_w = col_w - 28;
        ui_paint.roundRect(c, @floatFromInt(dsp_x), @floatFromInt(meter_y), @floatFromInt(meter_w), 4, 2);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.10);
        cairo.cairo_fill(c);
        if (self.top.available and self.top.dsp_load_pct > 0) {
            const pct: f64 = @max(0, @min(100, self.top.dsp_load_pct));
            const fw = @as(f64, @floatFromInt(meter_w)) * pct / 100.0;
            ui_paint.roundRect(c, @floatFromInt(dsp_x), @floatFromInt(meter_y), fw, 4, 2);
            cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.95);
            cairo.cairo_fill(c);
        }

        self.paintLatencyCard(c, ge.latency, g_ov);
        self.paintRestartCard(c, ge.restart, g_ov);
    }

    fn statusMetric(c: *cairo.cairo_t, x: i32, y: i32, label: []const u8, value: []const u8, r: f64, g: f64, b: f64, a: f64) void {
        const t = common.Theme;
        ui_paint.showText(c, @floatFromInt(x), @floatFromInt(y + 18), label, 9, 600, t.text_r, t.text_g, t.text_b, 0.45);
        ui_paint.showText(c, @floatFromInt(x), @floatFromInt(y + 42), value, 15, 600, r, g, b, a);
    }

    fn latencyDisplay(self: *const Page, buf: []u8) []const u8 {
        const qn: i32 = if (self.es.clock_force_quantum > 0)
            self.es.clock_force_quantum
        else if (self.es.clock_quantum > 0)
            self.es.clock_quantum
        else
            self.top.reference_quantum;
        const rate: i32 = if (self.es.clock_force_rate_hz > 0)
            self.es.clock_force_rate_hz
        else if (self.es.clock_rate_hz > 0)
            self.es.clock_rate_hz
        else
            self.top.reference_rate_hz;
        if (qn <= 0 or rate <= 0) return "—";
        const ms = @as(f64, @floatFromInt(qn)) / @as(f64, @floatFromInt(rate)) * 1000.0;
        return std.fmt.bufPrint(buf, "{d:.2} ms", .{ms}) catch "—";
    }

    /// `44100` → `44.1`, `48000` → `48` (kHz shorthand for the caption).
    fn shortRate(buf: []u8, hz: i32) []const u8 {
        if (hz <= 0) return "?";
        if (@mod(hz, 1000) == 0) return std.fmt.bufPrint(buf, "{d}", .{@divTrunc(hz, 1000)}) catch "?";
        return std.fmt.bufPrint(buf, "{d}.{d}", .{
            @divTrunc(hz, 1000),
            @divTrunc(@mod(hz, 1000), 100),
        }) catch "?";
    }

    fn capsFormatLabel(bits: u16, buf: []u8) []const u8 {
        const names = [_]struct { bit: u16, name: []const u8 }{
            .{ .bit = live_audio.fmt_s16, .name = "S16LE" },
            .{ .bit = live_audio.fmt_s24, .name = "S24LE" },
            .{ .bit = live_audio.fmt_s32, .name = "S32LE" },
            .{ .bit = live_audio.fmt_f32, .name = "F32LE" },
            .{ .bit = live_audio.fmt_f64, .name = "F64LE" },
        };
        var n: usize = 0;
        for (names) |entry| {
            if (bits & entry.bit == 0) continue;
            const need: usize = entry.name.len + (if (n == 0) @as(usize, 0) else 3);
            if (n + need > buf.len) break;
            if (n > 0) {
                @memcpy(buf[n..][0..3], " / ");
                n += 3;
            }
            @memcpy(buf[n..][0..entry.name.len], entry.name);
            n += entry.name.len;
        }
        return buf[0..n];
    }

    fn appendCaptionPart(buf: []u8, n: *usize, part: []const u8) void {
        if (part.len == 0) return;
        const sep = if (n.* == 0) "" else " · ";
        if (n.* + sep.len + part.len > buf.len) return;
        @memcpy(buf[n.*..][0..sep.len], sep);
        n.* += sep.len;
        @memcpy(buf[n.*..][0..part.len], part);
        n.* += part.len;
    }

    /// Subtle "what this output can actually do" line in the Engine card
    /// header. Detection comes from the selected sink's `EnumFormat`, so an
    /// unavailable result says so rather than inventing limits.
    fn hardwareCaption(self: *Page, buf: []u8) []const u8 {
        const c = &self.caps;
        const d = self.storeDevice();
        if (!c.available) return if (hasDevice(d)) "Hardware limits unavailable" else "No output device";

        var parts: [5][]const u8 = undefined;
        var np: usize = 0;
        if (hasDevice(d)) {
            parts[np] = deviceLabel(d);
            np += 1;
        }

        var lo_b: [12]u8 = undefined;
        var hi_b: [12]u8 = undefined;
        var rate_b: [40]u8 = undefined;
        var rate_s: []const u8 = "";
        if (c.rate_min > 0 and c.rate_max >= c.rate_min) {
            if (c.rate_min == c.rate_max) {
                rate_s = std.fmt.bufPrint(&rate_b, "{s} kHz", .{shortRate(&lo_b, c.rate_min)}) catch "";
            } else {
                const lo = shortRate(&lo_b, c.rate_min);
                const hi = shortRate(&hi_b, c.rate_max);
                rate_s = std.fmt.bufPrint(&rate_b, "{s}–{s} kHz", .{ lo, hi }) catch "";
            }
        } else if (c.rate_count > 0) {
            const lo = shortRate(&lo_b, c.rates[0]);
            const hi = shortRate(&hi_b, c.rates[c.rate_count - 1]);
            rate_s = std.fmt.bufPrint(&rate_b, "{s}–{s} kHz", .{ lo, hi }) catch "";
        }
        if (rate_s.len > 0) {
            parts[np] = rate_s;
            np += 1;
        }

        var fmt_b: [32]u8 = undefined;
        const fmt_s = capsFormatLabel(c.formats, &fmt_b);
        if (fmt_s.len > 0) {
            parts[np] = fmt_s;
            np += 1;
        }

        var ch_b: [24]u8 = undefined;
        if (c.channels > 0) {
            parts[np] = std.fmt.bufPrint(&ch_b, "{d} ch", .{c.channels}) catch "";
            np += 1;
        }

        var q_b: [32]u8 = undefined;
        if (c.quantum_limit > 0) {
            parts[np] = std.fmt.bufPrint(&q_b, "quantum ≤{d}", .{c.quantum_limit}) catch "";
            np += 1;
        }

        var n: usize = 0;
        for (parts[0..np]) |part| appendCaptionPart(buf, &n, part);
        return buf[0..n];
    }

    fn paintLatencyCard(self: *Page, c: *cairo.cairo_t, sec: SGeom, g_ov: f64) void {
        ui_paint.card(c, @floatFromInt(sec.x), @floatFromInt(sec.y), @floatFromInt(sec.w), @floatFromInt(sec.h), g_ov);
        paintHeading(c, sec, "Latency offset", "timer");

        ui_paint.settingLabel(c, @floatFromInt(sec.x + common.card_pad), @floatFromInt(sec.y0 + 24), "Audio node", "");
        const nd = self.latNodeDisplay();
        paintCombo(c, comboRect(sec, 0, nd), nd, self.dd_open and self.dd_id == 8);

        ui_paint.settingLabel(c, @floatFromInt(sec.x + common.card_pad), @floatFromInt(sec.y0 + k_row_h + 24), "Offset", "");
        paintTextField(c, latencyFieldRect(sec), self.lat_field[0..self.lat_len], self.lat_focus, "0");
        paintUnitToggle(c, latencyUnitRect(sec), self.lat_ns);

        const has_node = self.latNodeAt(self.lat_node) != null;
        const label_y = sec.y0 + 2 * k_row_h + 24;
        ui_paint.settingLabel(
            c,
            @floatFromInt(sec.x + common.card_pad),
            @floatFromInt(label_y),
            "Apply to selected node",
            if (has_node) "Stored on the PipeWire node as a processing offset." else "Choose an output or input node first.",
        );
        const apply_r = latencyApplyRect(sec);
        if (has_node) {
            ui_paint.paintBtn(c, apply_r.x, apply_r.y, apply_r.w, apply_r.h, "Apply latency", false);
        } else {
            ui_paint.paintBtnDisabled(c, apply_r.x, apply_r.y, apply_r.w, apply_r.h, "Apply latency");
        }
        const reset_r = latencyResetAllRect(sec);
        if (self.latNodeCount() > 0) {
            ui_paint.paintBtn(c, reset_r.x, reset_r.y, reset_r.w, reset_r.h, "Reset all latency", false);
        } else {
            ui_paint.paintBtnDisabled(c, reset_r.x, reset_r.y, reset_r.w, reset_r.h, "Reset all latency");
        }
    }

    fn paintRestartCard(self: *Page, c: *cairo.cairo_t, sec: SGeom, g_ov: f64) void {
        ui_paint.card(c, @floatFromInt(sec.x), @floatFromInt(sec.y), @floatFromInt(sec.w), @floatFromInt(sec.h), g_ov);
        paintHeading(c, sec, "Restart services", "restart_alt");
        const now = nowMs();
        self.paintRestartRow(c, sec, 0, "Restart WirePlumber", "Reloads device and session policy without touching the graph.", self.restart_wp_arm_ms, self.restart_wp_done_ms, now);
        self.paintRestartRow(c, sec, 1, "Restart PipeWire", "Restarts the audio graph; every client reconnects.", self.restart_pw_arm_ms, self.restart_pw_done_ms, now);
    }

    fn paintRestartRow(self: *Page, c: *cairo.cairo_t, sec: SGeom, row_i: i32, title: []const u8, desc: []const u8, arm_ms: i64, done_ms: i64, now: i64) void {
        const t = common.Theme;
        var armed = arm_ms >= 0 and now - arm_ms >= 0 and now - arm_ms <= k_restart_arm_ms;
        const done = done_ms >= 0 and now - done_ms <= k_restart_done_ms;
        if (arm_ms >= 0 and now - arm_ms > k_restart_arm_ms) {
            if (row_i == 0) self.restart_wp_arm_ms = -1 else self.restart_pw_arm_ms = -1;
            armed = false;
        }
        if (done_ms >= 0 and now - done_ms > k_restart_done_ms) {
            if (row_i == 0) self.restart_wp_done_ms = -1 else self.restart_pw_done_ms = -1;
        }
        ui_paint.settingLabel(c, @floatFromInt(sec.x + common.card_pad), @floatFromInt(sec.y0 + row_i * k_restart_row_h + 22), title, desc);
        const br = restartButtonRect(sec, row_i);
        const label = if (done) "Restarted" else if (armed) "Confirm" else "Restart";
        ui_paint.paintBtn(c, br.x, br.y, br.w, br.h, label, false);
        if (done) {
            ui_paint.glyph(c, @floatFromInt(br.x + 22), @floatFromInt(br.y + @divTrunc(br.h, 2)), 15, "check", t.acc_r, t.acc_g, t.acc_b, 0.95);
        }
    }

    fn paintTextField(c: *cairo.cairo_t, r: common.Rect, value: []const u8, focused: bool, placeholder: []const u8) void {
        const t = common.Theme;
        ui_paint.roundRect(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 8);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, if (focused) 0.10 else 0.06);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_line_width(c, 1.0);
        if (focused) {
            cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.9);
        } else {
            cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.45);
        }
        cairo.cairo_stroke(c);
        const shown = if (value.len > 0) value else placeholder;
        const alpha: f64 = if (value.len > 0) 0.92 else 0.38;
        ui_paint.showTextW(
            c,
            @floatFromInt(r.x + 10),
            @floatFromInt(r.y + 19),
            shown,
            12,
            500,
            @as(f64, @floatFromInt(@max(0, r.w - 18))),
            t.text_r,
            t.text_g,
            t.text_b,
            alpha,
        );
        if (focused) {
            const tw = ui_paint.measureTextWidth(value, 12, 500);
            const cx = @as(f64, @floatFromInt(r.x + 10)) + @as(f64, @floatFromInt(@min(tw, @max(0, r.w - 18))));
            cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.95);
            cairo.cairo_set_line_width(c, 1.4);
            cairo.cairo_move_to(c, cx, @floatFromInt(r.y + 7));
            cairo.cairo_line_to(c, cx, @floatFromInt(r.y + r.h - 7));
            cairo.cairo_stroke(c);
        }
    }

    fn paintUnitToggle(c: *cairo.cairo_t, r: common.Rect, ns: bool) void {
        const t = common.Theme;
        const half = @divTrunc(r.w, 2);
        ui_paint.roundRect(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 8);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.06);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.45);
        cairo.cairo_stroke(c);
        const ax = if (ns) r.x + half else r.x;
        ui_paint.roundRect(c, @floatFromInt(ax + 2), @floatFromInt(r.y + 2), @floatFromInt(half - 4), @floatFromInt(r.h - 4), 6);
        cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.20);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.28);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_move_to(c, @floatFromInt(r.x + half), @floatFromInt(r.y + 6));
        cairo.cairo_line_to(c, @floatFromInt(r.x + half), @floatFromInt(r.y + r.h - 6));
        cairo.cairo_stroke(c);
        const labels = [_][]const u8{ "frames", "ns" };
        for (labels, 0..) |lab, i| {
            const active = (i == 1) == ns;
            const lx = r.x + @as(i32, @intCast(i)) * half + @divTrunc(half, 2);
            ui_paint.showText(
                c,
                @floatFromInt(lx - @divTrunc(ui_paint.measureTextWidth(lab, 11, 600), 2)),
                @floatFromInt(r.y + 19),
                lab,
                11,
                600,
                if (active) t.acc_r else t.text_r,
                if (active) t.acc_g else t.text_g,
                if (active) t.acc_b else t.text_b,
                if (active) 1.0 else 0.62,
            );
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
            // Same dead-centre pinning as the closed combo (btnBody rule).
            const ts = ui_paint.textSizePx(c, row, 12, 500);
            const top = @as(f64, @floatFromInt(ry)) + (@as(f64, @floatFromInt(row_h)) - @as(f64, @floatFromInt(ts.h))) / 2.0;
            ui_paint.showTextW(
                c,
                @floatFromInt(list.x + 30),
                top + @as(f64, @floatFromInt(ts.h)) - 2.0,
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
        if (id == 8) return comboRect(ge.latency, 0, self.latNodeDisplay());
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
        const on_field = inRect(px, ly, latencyFieldRect(ge.latency));
        if (!on_field) self.lat_focus = false;
        if (inRect(px, ly, engineRefreshRect(sec))) {
            self.engine_ms = 0;
            self.top_ms = 0;
            self.caps_ms = 0;
            self.pcm_ms = 0;
            self.snap_ms = 0;
            return .repaint;
        }
        for (0..6) |i| {
            const col: i32 = @intCast(i % 2);
            const row_i: i32 = @intCast(i / 2);
            const cell = gridCellRect(sec, col, row_i);
            if (inRect(px, ly, cell)) {
                self.openDropdown(2 + @as(i32, @intCast(i)));
                return .repaint;
            }
        }
        if (self.top.available and inRect(px, ly, xrunHitRect(sec))) {
            self.xrun_base = self.top.xruns_total;
            return .repaint;
        }

        const lat = ge.latency;
        if (inRect(px, ly, comboRect(lat, 0, self.latNodeDisplay()))) {
            self.openDropdown(8);
            return .repaint;
        }
        if (on_field) {
            self.lat_focus = true;
            self.modal_select_all = true;
            return .repaint;
        }
        if (inRect(px, ly, latencyUnitRect(lat))) {
            self.lat_ns = !self.lat_ns;
            return .repaint;
        }
        if (inRect(px, ly, latencyApplyRect(lat))) {
            if (self.latNodeAt(self.lat_node) != null) self.applyLatency();
            return .repaint;
        }
        if (inRect(px, ly, latencyResetAllRect(lat))) {
            self.resetAllLatency();
            return .repaint;
        }

        const rst = ge.restart;
        if (inRect(px, ly, restartButtonRect(rst, 0))) {
            const now = nowMs();
            const armed = self.restart_wp_arm_ms >= 0 and now - self.restart_wp_arm_ms <= k_restart_arm_ms;
            if (!armed) {
                self.restart_wp_arm_ms = now;
                return .repaint;
            }
            self.restart_wp_arm_ms = -1;
            _ = live_audio.restartWirePlumber(self.io);
            self.restart_wp_done_ms = nowMs();
            self.snap_ms = 0;
            self.engine_ms = 0;
            self.cards_ms = 0;
            return .repaint;
        }
        if (inRect(px, ly, restartButtonRect(rst, 1))) {
            const now = nowMs();
            const armed = self.restart_pw_arm_ms >= 0 and now - self.restart_pw_arm_ms <= k_restart_arm_ms;
            if (!armed) {
                self.restart_pw_arm_ms = now;
                return .repaint;
            }
            self.restart_pw_arm_ms = -1;
            _ = live_audio.restartPipeWire(self.io);
            self.restart_pw_done_ms = nowMs();
            self.snap_ms = 0;
            self.engine_ms = 0;
            self.cards_ms = 0;
            return .repaint;
        }
        return null;
    }

    fn applyLatency(self: *Page) void {
        const node = self.latNodeAt(self.lat_node) orelse return;
        const raw = self.lat_field[0..self.lat_len];
        const value: i64 = if (raw.len == 0) 0 else std.fmt.parseInt(i64, raw, 10) catch return;
        if (live_audio.applyLatencyOffset(self.io, node.d.id, value, self.lat_ns)) {
            self.loadLatencyField();
        }
    }

    fn resetAllLatency(self: *Page) void {
        var ids: [k_max_values * 2]u32 = undefined;
        var n: usize = 0;
        const count = self.latNodeCount();
        var i: i32 = 0;
        while (i < count and n < ids.len) : (i += 1) {
            if (self.latNodeAt(i)) |node| {
                if (node.d.id == 0) continue;
                ids[n] = node.d.id;
                n += 1;
            }
        }
        _ = live_audio.resetAllLatency(self.io, ids[0..n]);
        if (self.latNodeAt(self.lat_node) != null) self.loadLatencyField();
    }

    fn loadLatencyField(self: *Page) void {
        const node = self.latNodeAt(self.lat_node) orelse return;
        const off = live_audio.queryLatencyOffset(self.alloc, self.io, node.d.id);
        if (!off.ok) {
            self.lat_len = 0;
            self.lat_ns = false;
            return;
        }
        self.lat_ns = off.nanoseconds;
        const s = std.fmt.bufPrint(&self.lat_field, "{d}", .{off.value}) catch "";
        self.lat_len = s.len;
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
        if (id >= 2 and id <= 8) return self.applyEnginePick(id, row);
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
        if (id == 8) {
            if (row >= 0 and row < self.latNodeCount()) {
                self.lat_node = row;
                self.loadLatencyField();
            }
            return .repaint;
        }
        var rate_buf: [k_max_values]i32 = undefined;
        var qn_buf: [k_max_values]i32 = undefined;
        const menu_rates = self.menuRates(&rate_buf);
        const menu_quantums = self.menuQuantums(&qn_buf);
        const rate_n: i32 = @intCast(menu_rates.len);
        const qn_n: i32 = @intCast(menu_quantums.len);
        if (id == 2) {
            if (row >= 0 and row < rate_n) {
                const hz = menu_rates[@intCast(row)];
                _ = live_audio.applyEngineClockRateHz(self.io, hz);
                self.engine_ms = now - k_engine_ms + 150;
                return .{ .persist = .{ .clock_hz = hz } };
            }
            if (row == rate_n) self.openModal(.custom_rate, false);
            if (row == rate_n + 1) self.openModal(.edit_rates, false);
            return .repaint;
        }
        if (id == 3) {
            if (row == 0) {
                _ = live_audio.applyEngineForceRateHz(self.io, 0);
                self.engine_ms = now - k_engine_ms + 150;
                return .{ .persist = .{ .force_hz = 0 } };
            }
            if (row >= 1 and row <= rate_n) {
                const hz = menu_rates[@intCast(row - 1)];
                _ = live_audio.applyEngineForceRateHz(self.io, hz);
                self.engine_ms = now - k_engine_ms + 150;
                return .{ .persist = .{ .force_hz = hz } };
            }
            if (row == rate_n + 1) self.openModal(.custom_rate, true);
            if (row == rate_n + 2) self.openModal(.edit_rates, true);
            return .repaint;
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
            if (row == 0) {
                _ = live_audio.applyEngineQuantum(self.io, 0);
                self.engine_ms = now - k_engine_ms + 150;
                return .{ .persist = .{ .quantum = 0 } };
            }
            if (row >= 1 and row <= qn_n) {
                const qn = menu_quantums[@intCast(row - 1)];
                _ = live_audio.applyEngineQuantum(self.io, qn);
                self.engine_ms = now - k_engine_ms + 150;
                return .{ .persist = .{ .quantum = qn } };
            }
            if (row == qn_n + 1) self.openModal(.custom_quantum, false);
            if (row == qn_n + 2) self.openModal(.edit_quantums, false);
            return .repaint;
        }
        if (id == 7) {
            if (row == 0) {
                _ = live_audio.applyEngineForceQuantum(self.io, 0);
                self.engine_ms = now - k_engine_ms + 150;
                return .{ .persist = .{ .force_quantum = 0 } };
            }
            if (row >= 1 and row <= qn_n) {
                const qn = menu_quantums[@intCast(row - 1)];
                _ = live_audio.applyEngineForceQuantum(self.io, qn);
                self.engine_ms = now - k_engine_ms + 150;
                return .{ .persist = .{ .force_quantum = qn } };
            }
            if (row == qn_n + 1) self.openModal(.custom_quantum, true);
            if (row == qn_n + 2) self.openModal(.edit_quantums, true);
            return .repaint;
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Custom value / edit-list modal
    // -----------------------------------------------------------------------

    fn openModal(self: *Page, kind: Modal, force: bool) void {
        self.modal = kind;
        self.modal_force = force;
        self.dd_open = false;
        self.dd_id = -1;
        self.modal_arm = -1;
        self.modal_hover = -1;
        self.modal_select_all = true;
        self.modal_len = 0;
        switch (kind) {
            .custom_rate => {
                const v = if (self.es.clock_force_rate_hz > 0) self.es.clock_force_rate_hz else self.es.clock_rate_hz;
                self.setModalText(std.fmt.bufPrint(&self.modal_buf, "{d}", .{v}) catch "");
            },
            .custom_quantum => {
                const v = if (self.es.clock_force_quantum > 0) self.es.clock_force_quantum else self.es.clock_quantum;
                if (v > 0) self.setModalText(std.fmt.bufPrint(&self.modal_buf, "{d}", .{v}) catch "");
            },
            .edit_rates => self.setModalList(self.rate_values[0..self.rate_values_len]),
            .edit_quantums => self.setModalList(self.quantum_values[0..self.quantum_values_len]),
            .none => {},
        }
    }

    fn setModalText(self: *Page, s: []const u8) void {
        const n = @min(s.len, self.modal_buf.len);
        @memcpy(self.modal_buf[0..n], s[0..n]);
        self.modal_len = n;
    }

    fn setModalList(self: *Page, list: []const i32) void {
        self.modal_len = 0;
        for (list, 0..) |v, i| {
            const piece = if (i == 0)
                std.fmt.bufPrint(self.modal_buf[self.modal_len..], "{d}", .{v})
            else
                std.fmt.bufPrint(self.modal_buf[self.modal_len..], ", {d}", .{v});
            const w = piece catch break;
            self.modal_len += w.len;
        }
    }

    fn modalTitle(self: *const Page) []const u8 {
        return switch (self.modal) {
            .custom_rate => "Custom sample rate",
            .custom_quantum => "Custom quantum",
            .edit_rates => "Edit rate values",
            .edit_quantums => "Edit quantum values",
            .none => "",
        };
    }

    fn modalHint(self: *const Page) []const u8 {
        return switch (self.modal) {
            .custom_rate => "The rate joins the allowed list and becomes the graph rate.",
            .custom_quantum => "Frames per graph cycle. Use a value from the quantum list or your own.",
            .edit_rates => "Comma-separated rates in Hz. These become the dropdown choices.",
            .edit_quantums => "Comma-separated quantum sizes in frames. These become the dropdown choices.",
            .none => "",
        };
    }

    fn modalPrimary(self: *const Page) []const u8 {
        return if (self.modal == .edit_rates or self.modal == .edit_quantums) "Save list" else "Apply";
    }

    const ModalLayout = struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        field: common.Rect,
        cancel: common.Rect,
        submit: common.Rect,
    };

    fn modalLayout(self: *const Page, win_w: i32, win_h: i32) ModalLayout {
        _ = self;
        var w: i32 = win_w - 80;
        if (w > 480) w = 480;
        if (w < 340) w = 340;
        const h: i32 = 214;
        var x = @divTrunc(win_w - w, 2);
        if (x < 16) x = 16;
        var y = @divTrunc(win_h - h, 2);
        if (y < 16) y = 16;
        const pad: i32 = 20;
        return .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .field = .{ .x = x + pad, .y = y + 92, .w = w - 2 * pad, .h = 34 },
            .cancel = .{ .x = x + w - pad - 236, .y = y + h - pad - 36, .w = 110, .h = 36 },
            .submit = .{ .x = x + w - pad - 116, .y = y + h - pad - 36, .w = 116, .h = 36 },
        };
    }

    fn modalItemAt(self: *const Page, win_w: i32, win_h: i32, px: f64, py: f64) i32 {
        const l = self.modalLayout(win_w, win_h);
        if (inRect(px, py, l.field)) return -1;
        if (inRect(px, py, l.cancel)) return -11;
        if (inRect(px, py, l.submit)) return -12;
        return -2;
    }

    fn submitModal(self: *Page) void {
        const raw = std.mem.trim(u8, self.modal_buf[0..self.modal_len], " \t\r\n");
        switch (self.modal) {
            .custom_rate => {
                const hz = std.fmt.parseInt(i32, raw, 10) catch return;
                if (hz <= 0 or hz > 2_000_000) return;
                const changed = self.addValue(&self.rate_values, &self.rate_values_len, hz);
                if (self.modal_force) {
                    _ = live_audio.applyEngineForceRateHz(self.io, hz);
                    self.pending_action = .{ .persist = .{
                        .force_hz = hz,
                        .rate_values = if (changed) self.rate_values[0..self.rate_values_len] else null,
                    } };
                } else {
                    _ = live_audio.applyEngineClockRateHz(self.io, hz);
                    self.pending_action = .{ .persist = .{
                        .clock_hz = hz,
                        .rate_values = if (changed) self.rate_values[0..self.rate_values_len] else null,
                    } };
                }
                self.engine_ms = nowMs() - k_engine_ms + 150;
            },
            .custom_quantum => {
                const qn = std.fmt.parseInt(i32, raw, 10) catch return;
                if (qn <= 0 or qn > 2_000_000) return;
                const changed = self.addValue(&self.quantum_values, &self.quantum_values_len, qn);
                if (self.modal_force) {
                    _ = live_audio.applyEngineForceQuantum(self.io, qn);
                    self.pending_action = .{ .persist = .{
                        .force_quantum = qn,
                        .quantum_values = if (changed) self.quantum_values[0..self.quantum_values_len] else null,
                    } };
                } else {
                    _ = live_audio.applyEngineQuantum(self.io, qn);
                    self.pending_action = .{ .persist = .{
                        .quantum = qn,
                        .quantum_values = if (changed) self.quantum_values[0..self.quantum_values_len] else null,
                    } };
                }
                self.engine_ms = nowMs() - k_engine_ms + 150;
            },
            .edit_rates => {
                if (!self.parseList(&self.rate_values, &self.rate_values_len, raw)) return;
                self.pending_action = .{ .persist = .{ .rate_values = self.rate_values[0..self.rate_values_len] } };
            },
            .edit_quantums => {
                if (!self.parseList(&self.quantum_values, &self.quantum_values_len, raw)) return;
                self.pending_action = .{ .persist = .{ .quantum_values = self.quantum_values[0..self.quantum_values_len] } };
            },
            .none => return,
        }
        self.modal = .none;
    }

    fn addValue(self: *Page, dst: *[k_max_values]i32, len: *usize, v: i32) bool {
        _ = self;
        for (dst[0..len.*]) |have| if (have == v) return false;
        if (len.* < dst.len) {
            dst[len.*] = v;
            len.* += 1;
        } else {
            dst[dst.len - 1] = v;
        }
        return true;
    }

    fn parseList(self: *Page, dst: *[k_max_values]i32, len: *usize, raw: []const u8) bool {
        _ = self;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, raw, ", \t");
        while (it.next()) |tok| {
            const v = std.fmt.parseInt(i32, tok, 10) catch continue;
            if (v <= 0 or v > 2_000_000 or n >= dst.len) continue;
            var dup = false;
            for (dst[0..n]) |have| {
                if (have == v) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            dst[n] = v;
            n += 1;
        }
        if (n == 0) return false;
        len.* = n;
        return true;
    }

    pub fn modalActive(self: *const Page) bool {
        return self.modal != .none;
    }

    pub fn modalDown(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (self.modal == .none) return false;
        const l = self.modalLayout(win_w, win_h);
        const inside = px >= @as(f64, @floatFromInt(l.x)) and
            px <= @as(f64, @floatFromInt(l.x + l.w)) and
            py >= @as(f64, @floatFromInt(l.y)) and
            py <= @as(f64, @floatFromInt(l.y + l.h));
        if (!inside) {
            self.modal = .none;
            return true;
        }
        self.modal_arm = self.modalItemAt(win_w, win_h, px, py);
        if (self.modal_arm == -1) self.modal_select_all = true;
        return true;
    }

    pub fn modalUp(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (self.modal == .none) return false;
        const armed = self.modal_arm;
        self.modal_arm = -1;
        const item = self.modalItemAt(win_w, win_h, px, py);
        if (item != armed) return true;
        switch (item) {
            -11 => self.modal = .none,
            -12 => self.submitModal(),
            else => {},
        }
        return true;
    }

    pub fn modalMotion(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) void {
        if (self.modal == .none) return;
        self.modal_hover = self.modalItemAt(win_w, win_h, px, py);
    }

    pub fn handleKey(self: *Page, sym: u32, text: []const u8) bool {
        if (!self.inited) return false;
        if (self.modal != .none) {
            switch (sym) {
                xkb.XKB_KEY_Escape => {
                    self.modal = .none;
                    return true;
                },
                xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                    self.submitModal();
                    return true;
                },
                xkb.XKB_KEY_BackSpace => {
                    if (self.modal_select_all) {
                        self.modal_len = 0;
                        self.modal_select_all = false;
                    } else if (self.modal_len > 0) {
                        self.modal_len -= 1;
                    }
                    return true;
                },
                else => {},
            }
            if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
                if (self.modal_select_all) {
                    self.modal_len = 0;
                    self.modal_select_all = false;
                }
                const n = @min(text.len, self.modal_buf.len - self.modal_len);
                @memcpy(self.modal_buf[self.modal_len..][0..n], text[0..n]);
                self.modal_len += n;
            }
            return true;
        }
        if (!self.lat_focus) return false;
        switch (sym) {
            xkb.XKB_KEY_Escape => {
                self.lat_focus = false;
                return true;
            },
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                self.applyLatency();
                self.lat_focus = false;
                return true;
            },
            xkb.XKB_KEY_BackSpace => {
                if (self.modal_select_all) {
                    self.lat_len = 0;
                    self.modal_select_all = false;
                } else if (self.lat_len > 0) {
                    self.lat_len -= 1;
                }
                return true;
            },
            else => {},
        }
        if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
            if (self.modal_select_all) {
                self.lat_len = 0;
                self.modal_select_all = false;
            }
            for (text) |ch| {
                if (ch < '0' or ch > '9') continue;
                if (self.lat_len >= self.lat_field.len) break;
                self.lat_field[self.lat_len] = ch;
                self.lat_len += 1;
            }
        }
        return true;
    }

    pub fn takeAction(self: *Page) ?Action {
        const act = self.pending_action;
        self.pending_action = null;
        return act;
    }

    fn paintModal(self: *Page, c: *cairo.cairo_t, win_w: i32, win_h: i32) void {
        const t = common.Theme;
        const l = self.modalLayout(win_w, win_h);
        cairo.cairo_save(c);
        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.45);
        cairo.cairo_rectangle(c, 0, 0, @floatFromInt(win_w), @floatFromInt(win_h));
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
        ui_paint.card(c, @floatFromInt(l.x), @floatFromInt(l.y), @floatFromInt(l.w), @floatFromInt(l.h), 0.92);
        ui_paint.roundRect(c, @floatFromInt(l.x), @floatFromInt(l.y), @floatFromInt(l.w), @floatFromInt(l.h), 16);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.12);
        cairo.cairo_stroke(c);

        ui_paint.showText(c, @floatFromInt(l.x + 20), @floatFromInt(l.y + 30), self.modalTitle(), 18, 600, t.text_r, t.text_g, t.text_b, 0.95);
        ui_paint.showTextW(c, @floatFromInt(l.x + 20), @floatFromInt(l.y + 54), self.modalHint(), 12, 400, @as(f64, @floatFromInt(l.w - 40)), t.text_r, t.text_g, t.text_b, 0.5);
        ui_paint.showText(c, @floatFromInt(l.x + 20), @floatFromInt(l.y + 84), if (self.modal == .edit_rates or self.modal == .edit_quantums) "Values" else "Value", 11, 500, t.text_r, t.text_g, t.text_b, 0.62);
        paintTextField(c, l.field, self.modal_buf[0..self.modal_len], true, "");
        const prim = self.modalPrimary();
        ui_paint.paintBtn(c, l.cancel.x, l.cancel.y, l.cancel.w, l.cancel.h, "Cancel", false);
        ui_paint.paintBtn(c, l.submit.x, l.submit.y, l.submit.w, l.submit.h, prim, false);
        if (self.modal_hover == -12) {
            ui_paint.roundRect(c, @floatFromInt(l.submit.x), @floatFromInt(l.submit.y), @floatFromInt(l.submit.w), @floatFromInt(l.submit.h), 8);
            cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.14);
            cairo.cairo_fill(c);
        }
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
    const huge = comboRect(sec, 0, &@as([400:0]u8, @splat('x')));
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

test "sound-tab: latency display uses the effective rate and quantum" {
    const t = std.testing;
    var p: Page = .{};
    var buf: [32]u8 = undefined;
    p.es.clock_rate_hz = 48000;
    p.es.clock_quantum = 256;
    try t.expectEqualStrings("5.33 ms", p.latencyDisplay(&buf));

    p.es.clock_force_quantum = 512;
    try t.expectEqualStrings("10.67 ms", p.latencyDisplay(&buf));

    p.es.clock_force_rate_hz = 96000;
    p.es.clock_force_quantum = 0;
    try t.expectEqualStrings("2.67 ms", p.latencyDisplay(&buf));

    const g = Geo{ .content_x = 386, .content_w = 700, .win_w = 1100, .win_h = 900, .tab = engine_tab };
    const ge = p.computeGeom(g);
    try t.expect(ge.engine.h >= 3 * k_grid_row_h + 64);
    try t.expect(ge.latency.y > ge.engine.y);
    try t.expect(ge.restart.y > ge.latency.y);
    const f = latencyFieldRect(ge.latency);
    const u = latencyUnitRect(ge.latency);
    try t.expect(f.x + f.w <= ge.latency.x + ge.latency.w - common.card_pad);
    try t.expect(u.x + u.w <= ge.latency.x + ge.latency.w - common.card_pad);
}

test "sound-tab: edit-list parsing keeps positive unique values" {
    const t = std.testing;
    var p: Page = .{};
    var vals: [k_max_values]i32 = undefined;
    var n: usize = 0;
    try t.expect(p.parseList(&vals, &n, "44100, 48000 48000, nope, -1, 96000"));
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(i32, 44100), vals[0]);
    try t.expectEqual(@as(i32, 48000), vals[1]);
    try t.expectEqual(@as(i32, 96000), vals[2]);
    try t.expect(!p.parseList(&vals, &n, "nope, -5"));
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

test "sound-tab: hardware caps filter the engine menus" {
    const t = std.testing;
    var p: Page = .{};
    p.setValueList(&p.rate_values, &p.rate_values_len, &k_engine_rates);
    p.setValueList(&p.quantum_values, &p.quantum_values_len, &k_engine_quantums);

    // No detection: the editable list is the menu.
    var buf: [k_max_values]i32 = undefined;
    try t.expectEqual(@as(usize, k_engine_rates.len), p.menuRates(&buf).len);

    // A range keeps only rates inside it.
    p.caps = .{ .available = true, .rate_min = 44100, .rate_max = 48000, .rate_default = 48000 };
    const rates = p.menuRates(&buf);
    try t.expectEqual(@as(usize, 2), rates.len);
    try t.expectEqual(@as(i32, 44100), rates[0]);
    try t.expectEqual(@as(i32, 48000), rates[1]);

    // An enum list is used verbatim (sorted by the parser).
    p.caps = .{
        .available = true,
        .rate_min = 44100,
        .rate_max = 96000,
        .rates = .{ 44100, 48000, 96000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .rate_count = 3,
    };
    const exact = p.menuRates(&buf);
    try t.expectEqual(@as(usize, 3), exact.len);
    try t.expectEqual(@as(i32, 96000), exact[2]);

    // Quantum values above the node's limit disappear.
    p.caps = .{ .available = true, .quantum_limit = 512 };
    var qbuf: [k_max_values]i32 = undefined;
    const quantums = p.menuQuantums(&qbuf);
    try t.expectEqual(@as(usize, 3), quantums.len);
    try t.expectEqual(@as(i32, 128), quantums[0]);
    try t.expectEqual(@as(i32, 512), quantums[2]);
}

test "sound-tab: hardware caption summarizes detected limits" {
    const t = std.testing;
    var p: Page = .{};
    p.caps = .{
        .available = true,
        .rate_min = 44100,
        .rate_max = 192000,
        .rate_default = 48000,
        .channels = 2,
        .formats = live_audio.fmt_s16 | live_audio.fmt_s32,
        .quantum_limit = 8192,
    };
    var buf: [192]u8 = undefined;
    const s = p.hardwareCaption(&buf);
    try t.expect(std.mem.indexOf(u8, s, "44.1–192 kHz") != null);
    try t.expect(std.mem.indexOf(u8, s, "S16LE / S32LE") != null);
    try t.expect(std.mem.indexOf(u8, s, "2 ch") != null);
    try t.expect(std.mem.indexOf(u8, s, "quantum ≤8192") != null);

    p.caps = .{};
    try t.expectEqualStrings("No output device", p.hardwareCaption(&buf));
}
