//! Audio Center — the shell's pavucontrol.
//!
//! One xdg-toplevel with the shell's rail + page chrome and six pages:
//! Playback, Recording, Output Devices, Input Devices, Configuration and
//! Engine. Every list entry is a card:
//!
//!   - stream rows   (Playback / Recording): app icon, title, "on <device>"
//!     move combo, terminate, volume slider, mute and L/R meters;
//!   - device rows   (Output / Input):       device icon, name, port combo,
//!     "Default" button, volume slider, mute and monitor meters;
//!   - card rows      (Configuration):       card name and profile combo;
//!   - engine rows    (Engine):              `clock.*` metadata combos, the
//!     `pw-top` latency/xrun/DSP strip, per-node latency offsets and the
//!     WirePlumber/PipeWire restarts.
//!
//! All audio state comes from the native libpipewire backend in this
//! directory (`client.zig` reads and writes, `graph.zig` is the model,
//! `meter.zig` the peak streams). The PipeWire loop is pumped from the UI
//! frame, so the whole app is single-threaded.
//!
//! Dropdowns never leave the window: the popup is painted inside the frame
//! and flips above its trigger when it would overflow the bottom edge (see
//! `settings2/dropdown.zig`).

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const shm_mod = @import("../../wl/buffer/shm.zig");
const wl_conn = @import("../../wl/connection.zig");
const wl_loop = @import("../../loop.zig");
const wl_pump = @import("../../wl/pump.zig");
const wl_seat = @import("../../wl/seat.zig");
const xdg = @import("../../wl/surface/xdg.zig");
const linux = std.os.linux;
const logz = @import("../../logz.zig");
const ns = @import("../../desktop_shell/common/namespaces.zig");
const icon_cache = @import("../../desktop_shell/common/icon_cache.zig");
const icon_themes = @import("../../desktop_shell/common/icon_themes.zig");
const vmx = @import("../../desktop_shell/widgets/volume_mixer.zig");
const common = @import("../settings2/common.zig");
const ui_paint = @import("../settings2/ui_paint.zig");
const config = @import("../../config.zig");
const palette_sync = @import("../../color/palette_sync.zig");
const chrome_colors = @import("../../desktop_shell/widgets/shared/chrome_colors.zig");
const scroll_mod = @import("../settings2/scroll.zig");
const dropdown_mod = @import("../settings2/dropdown.zig");
const graph_mod = @import("graph.zig");
const live_audio = @import("../../desktop_shell/controlcenter/live_audio.zig");
const prefs_mod = @import("prefs.zig");
const client_mod = @import("client.zig");
const meter_mod = @import("meter.zig");

const Graph = graph_mod.Graph;
const Node = graph_mod.Node;
const Route = graph_mod.Route;
const Profile = graph_mod.Profile;
const Device = graph_mod.Device;
const Theme = common.Theme;

const log = std.log.scoped(.audio_center);

pub const window_width: i32 = 1020;
pub const window_height: i32 = 760;
const min_win_w: i32 = 820;
const min_win_h: i32 = 560;

// ── chrome ──────────────────────────────────────────────────────────────────
const rail_w: i32 = 88;
const rail_btn_x: i32 = 8;
const rail_btn_w: i32 = rail_w - 16;
const rail_btn_h: i32 = 58;
const rail_pitch: i32 = 64;
const rail_base_y: i32 = 16;

const content_x: i32 = rail_w + 24; // 112
const content_pad_r: i32 = 24;
const header_h: i32 = 104; // eyebrow + title band; cards start here
const band_pad_b: i32 = 16;
const wheel_scale: f64 = 4.0;

// ── cards ───────────────────────────────────────────────────────────────────
const card_h: i32 = 108;
const card_h_config: i32 = 78;
const card_gap: i32 = 12;
const card_pad: i32 = 16;
const icon_sz: i32 = 40;
const icon_off_y: i32 = 12;
const icon_sz_config: i32 = 36;

const combo_w: i32 = 236;
const combo_h: i32 = 30;
const close_sz: i32 = 30;
const def_w: i32 = 112;
const mute_sz: i32 = 36;
const track_off_x: i32 = card_pad + mute_sz + 12; // 64
const track_w_pad: i32 = 84; // pct label + right padding
const track_off_y: i32 = 72;
const track_h: i32 = 14;
const meter_h: i32 = 3;
const meter_gap: i32 = 2;

const slider_max_pct: i32 = 150;
const drag_apply_ns: u64 = 40 * std.time.ns_per_ms;
/// How far a popup's soft shadow can spill outside its own rect — damage for
/// an opening or closing dropdown has to cover it.
const popup_pad: i32 = 8;

pub const Page = enum(u8) {
    playback = 0,
    recording = 1,
    output = 2,
    input = 3,
    configuration = 4,
    engine = 5,

    fn title(self: Page) []const u8 {
        return switch (self) {
            .playback => "Playback",
            .recording => "Recording",
            .output => "Output Devices",
            .input => "Input Devices",
            .configuration => "Configuration",
            .engine => "Audio Engine",
        };
    }

    fn glyph(self: Page) []const u8 {
        return switch (self) {
            .playback => "play_arrow",
            .recording => "mic",
            .output => "volume_up",
            .input => "headset_mic",
            .configuration => "tune",
            .engine => "tune",
        };
    }

    fn railLabel(self: Page) []const u8 {
        return switch (self) {
            .playback => "Play",
            .recording => "Record",
            .output => "Output",
            .input => "Input",
            .configuration => "Config",
            .engine => "Engine",
        };
    }

    /// Short, log-friendly name (no spaces) for the frame telemetry lines.
    fn tag(self: Page) []const u8 {
        return switch (self) {
            .playback => "playback",
            .recording => "recording",
            .output => "output",
            .input => "input",
            .configuration => "configuration",
            .engine => "engine",
        };
    }

    /// True when the page lists nodes (streams or devices) rather than cards,
    /// and thus drives meters.
    fn hasMeters(self: Page) bool {
        return self != .configuration and self != .engine;
    }
};

const pages = [_]Page{ .playback, .recording, .output, .input, .configuration, .engine };

// ── engine page ─────────────────────────────────────────────────────────────
/// Values the Engine page's combos offer. The live allowed list can be any
/// set, but these are the rates every PipeWire build ships.
const engine_rates = [_]i32{ 44100, 48000, 88200, 96000, 176400, 192000 };
const engine_quantums = [_]i32{ 128, 256, 512, 1024, 2048, 4096, 8192 };
const engine_preset_hifi = [_]i32{ 44100, 48000, 88200, 96000, 176400, 192000 };
const engine_preset_consumer = [_]i32{ 44100, 48000 };
const engine_preset_pro = [_]i32{ 48000, 96000, 192000 };
/// Engine rows, in paint order.
const engine_row_count: usize = 11;
/// `pw-metadata` spawns are not free; the page re-reads at most this often.
const engine_refresh_ns: u64 = 1200 * std.time.ns_per_ms;
/// `pw-dump` for hardware capabilities is heavier: 4 s like settings2.
const engine_caps_ns: u64 = 4000 * std.time.ns_per_ms;
const engine_restart_arm_ns: u64 = 3500 * std.time.ns_per_ms;
const engine_restart_done_ns: u64 = 2600 * std.time.ns_per_ms;
/// Retry spacing while a read is still failing (PipeWire/session coming up).
const engine_retry_ns: u64 = 300 * std.time.ns_per_ms;

/// Engine rows, in paint order.
const EngineRow = enum(u32) {
    clock_rate = 0,
    force_rate = 1,
    allowed_rates = 2,
    pcm = 3,
    quantum = 4,
    force_quantum = 5,
    status = 6,
    latency_node = 7,
    latency_offset = 8,
    restart_wp = 9,
    restart_pw = 10,
};

/// Engine page: the numeric-entry dialog behind "Custom rate…" / "Custom
/// quantum…". A port of the settings app's modal, minus the value-list editor
/// (that one only rewrites its own dropdown contents, which the Audio Center
/// derives from the live graph instead).
const EngineModal = enum { none, rate, quantum };

const engine_pcm_labels = [_][]const u8{
    "16-bit PCM (S16 LE)",
    "24-bit PCM (S24 LE)",
    "32-bit PCM (S32 LE)",
    "32-bit float (F32 LE)",
};

/// Monotonic now in nanoseconds (frame timing + drag write throttle).
fn liveNowNs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const s: u64 = @intCast(@max(ts.sec, 0));
    const n: u64 = @intCast(@max(ts.nsec, 0));
    return s * std.time.ns_per_s + n;
}

/// FNV-1a step for the scene hash.
fn mixHash(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}

/// Fold a string into the scene hash (text changes are visible changes).
fn hashStr(h: u64, s: []const u8) u64 {
    var v = h;
    for (s) |b| v = mixHash(v, b);
    return mixHash(v, s.len);
}

/// Owned copy of an ambient XDG path (or null); the config watch keeps these
/// across reloads (same helper shape as `bin/app.zig`).
fn dupOrNull(gpa: std.mem.Allocator, v: ?[]const u8) !?[]u8 {
    if (v) |s| return try gpa.dupe(u8, s);
    return null;
}

// ── frame telemetry ─────────────────────────────────────────────────────────

/// The budget a whole repaint is held to: 1 ms. The numbers behind the "UX is
/// under a millisecond" claim live here — every frame is sampled, frames over
/// budget are logged with a stage breakdown, and a rolling percentile summary
/// is written to `EH-logs/horizon-audio-center.log` every `frame_flush_every`
/// frames and once more on exit.
const frame_budget_ns: u64 = std.time.ns_per_ms;
const frame_samples = 512;
const frame_flush_every: u64 = 256;

/// Paint-stage durations (ns) for one frame — the breakdown that says where
/// the milliseconds went when a frame is over budget.
const PaintProf = struct {
    rail: u64 = 0,
    hdr: u64 = 0,
    cards: u64 = 0,
    dd: u64 = 0,
    close: u64 = 0,
};

/// Where the card band's time goes, accumulated across the visible rows of
/// one frame: background fills, icons, text, combo/default controls, and the
/// volume row (slider + meter). Split out because "cards" is the whole band.
const CardProf = struct {
    bg: u64 = 0,
    icon: u64 = 0,
    text: u64 = 0,
    ctrl: u64 = 0,
    vol: u64 = 0,
};

/// Which half of the frame budget a frame came out of: a scene paint runs
/// every painter, a narrow paint runs them clipped to the damage (a hover
/// highlight, the open popup), an animation frame only restores and redraws
/// the meters.
const FrameKind = enum {
    scene,
    narrow,
    anim,

    fn tag(self: FrameKind) []const u8 {
        return switch (self) {
            .scene => "scene",
            .narrow => "narrow",
            .anim => "anim",
        };
    }
};

/// One row's meter band: where the L/R bars sit, plus what they need. Every
/// scene paint records these; animation frames restore the band background
/// from the scene cache, redraw the bars and damage just that rect.
const MeterBand = struct {
    id: u32,
    /// Track rect — the bar origin (logical coords).
    tr: common.Rect,
    /// The area the two bars occupy (logical coords).
    rect: common.Rect,
    muted: bool,
};

/// Bands for at most this many rows; far above what fits on screen.
const max_meter_bands = 64;

/// One baked card background: the exact pixels `ui_paint.card` produces,
/// rendered once and blitted per frame. The glass fill is five translucent
/// passes over ~200k pixels; the blit is one.
const CardBg = struct {
    surface: ?*cairo.cairo_surface_t = null,
    w: i32 = 0,
    h: i32 = 0,
    stamp: u64 = 0,
};
/// Two slots: the mixer has one card height per page, so a page flip finds
/// its card already baked instead of re-rendering.
const card_bg_slots = 2;

fn bandRect(tr: common.Rect) common.Rect {
    return .{
        .x = tr.x,
        .y = tr.y + tr.h + 4,
        .w = tr.w,
        .h = 2 * meter_h + meter_gap,
    };
}

/// `showText`/`showTextW`'s y is an anchor, not a baseline: the layout's top
/// lands at `y - pixelHeight + 2`. To centre a label in a box, measure it and
/// hand back the y that puts its top on the box's optical middle.
fn cyTextTop(box_y: i32, box_h: i32, text_h: i32) i32 {
    return box_y + @divTrunc(box_h - text_h, 2) + text_h - 2;
}

/// The same centring for a combo pill's label.
fn comboLabelTop(r: common.Rect, text_h: i32) i32 {
    return cyTextTop(r.y, r.h, text_h);
}

/// Overlap of two rects, or null when they miss each other.
fn rectIsect(a: common.Rect, b: common.Rect) ?common.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Grow a rect by `pad` on each side — the soft edge of a shadow or a
/// highlight lands a pixel or two outside the box that owns it.
fn padRect(r: common.Rect, pad: i32) common.Rect {
    return .{ .x = r.x - pad, .y = r.y - pad, .w = r.w + 2 * pad, .h = r.h + 2 * pad };
}

/// Smallest rect covering both, treating null as "nothing".
fn rectJoin(a: ?common.Rect, b: ?common.Rect) ?common.Rect {
    const x = a orelse return b;
    const y = b orelse return a;
    const x0 = @min(x.x, y.x);
    const y0 = @min(x.y, y.y);
    const x1 = @max(x.x + x.w, y.x + y.w);
    const y1 = @max(x.y + x.h, y.y + y.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Copy one buffer-pixel rect between two image surfaces of equal size —
/// the scene cache in either direction. Both ends are SHM-backed ARGB32, so
/// this is a row memcpy per line, not a composite.
fn copyRect(src: *cairo.cairo_surface_t, dst: *cairo.cairo_surface_t, bx: i32, by: i32, bw: i32, bh: i32) void {
    if (bw <= 0 or bh <= 0) return;
    const w = cairo.cairo_image_surface_get_width(src);
    const h = cairo.cairo_image_surface_get_height(src);
    if (cairo.cairo_image_surface_get_width(dst) != w or cairo.cairo_image_surface_get_height(dst) != h) return;
    var x = bx;
    var y = by;
    var cw = bw;
    var ch = bh;
    if (x < 0) {
        cw += x;
        x = 0;
    }
    if (y < 0) {
        ch += y;
        y = 0;
    }
    cw = @min(cw, w - x);
    ch = @min(ch, h - y);
    if (cw <= 0 or ch <= 0) return;
    cairo.cairo_surface_flush(src);
    const sstride: usize = @intCast(cairo.cairo_image_surface_get_stride(src));
    const dstride: usize = @intCast(cairo.cairo_image_surface_get_stride(dst));
    const sdata: [*]u8 = @ptrCast(cairo.cairo_image_surface_get_data(src));
    const ddata: [*]u8 = @ptrCast(cairo.cairo_image_surface_get_data(dst));
    const row_bytes: usize = @as(usize, @intCast(cw)) * 4;
    const xu: usize = @intCast(x);
    const yu: usize = @intCast(y);
    const rows: usize = @intCast(ch);
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        const so = (yu + row) * sstride + xu * 4;
        const do = (yu + row) * dstride + xu * 4;
        @memcpy(ddata[do .. do + row_bytes], sdata[so .. so + row_bytes]);
    }
    cairo.cairo_surface_mark_dirty(dst);
}

const FrameStats = struct {
    /// Frames sampled since the last flush.
    n: u64 = 0,
    /// Last `frame_samples` frame totals in µs, for the percentile summary.
    ring: [frame_samples]u32 = @as([frame_samples]u32, @splat(0)),
    idx: usize = 0,
    sum_pw_ns: u64 = 0,
    sum_sync_ns: u64 = 0,
    sum_paint_ns: u64 = 0,
    sum_commit_ns: u64 = 0,
    max_ns: u64 = 0,
    over: u64 = 0,
    // Lifetime counters; never reset, so the exit line can state totals.
    life_frames: u64 = 0,
    life_ns: u64 = 0,
    life_over: u64 = 0,
    life_max_ns: u64 = 0,

    /// One repaint: stage durations in ns. `pw` is the PipeWire pump, `sync`
    /// the model/scroll/meter update, `paint` cairo, `commit` attach+commit.
    fn record(self: *FrameStats, pw_ns: u64, sync_ns: u64, paint_ns: u64, commit_ns: u64) void {
        const total = pw_ns + sync_ns + paint_ns + commit_ns;
        self.n += 1;
        self.life_frames += 1;
        self.life_ns += total;
        self.ring[self.idx] = @intCast(@min(total / std.time.ns_per_us, std.math.maxInt(u32)));
        self.idx = (self.idx + 1) % frame_samples;
        self.sum_pw_ns += pw_ns;
        self.sum_sync_ns += sync_ns;
        self.sum_paint_ns += paint_ns;
        self.sum_commit_ns += commit_ns;
        self.max_ns = @max(self.max_ns, total);
        self.life_max_ns = @max(self.life_max_ns, total);
        if (total > frame_budget_ns) {
            self.over += 1;
            self.life_over += 1;
        }
    }

    fn percentile(sorted: []const u32, q: f64) f64 {
        if (sorted.len == 0) return 0;
        const last = sorted.len - 1;
        const i: usize = @intFromFloat(@round(q * @as(f64, @floatFromInt(last))));
        return @as(f64, @floatFromInt(sorted[@min(i, last)])) / 1000.0;
    }

    /// Write the rolling summary and start a fresh window.
    fn flush(self: *FrameStats, kind: []const u8, page: Page, rows: usize) void {
        if (self.n == 0) return;
        const count = @min(self.n, frame_samples);
        var sorted: [frame_samples]u32 = undefined;
        @memcpy(sorted[0..count], self.ring[0..count]);
        std.mem.sort(u32, sorted[0..count], {}, std.sort.asc(u32));
        const nf: f64 = @floatFromInt(self.n);
        const ms: f64 = @floatFromInt(std.time.ns_per_ms);
        logz.log(
            "frame {s}: n={d} p50={d:.3} p95={d:.3} p99={d:.3} max={d:.3} over1ms={d} | avg ms paint={d:.3} pw={d:.3} sync={d:.3} commit={d:.3} | page={s} rows={d}",
            .{
                kind,
                self.n,
                percentile(sorted[0..count], 0.50),
                percentile(sorted[0..count], 0.95),
                percentile(sorted[0..count], 0.99),
                @as(f64, @floatFromInt(self.max_ns)) / ms,
                self.over,
                @as(f64, @floatFromInt(self.sum_paint_ns)) / nf / ms,
                @as(f64, @floatFromInt(self.sum_pw_ns)) / nf / ms,
                @as(f64, @floatFromInt(self.sum_sync_ns)) / nf / ms,
                @as(f64, @floatFromInt(self.sum_commit_ns)) / nf / ms,
                page.tag(),
                rows,
            },
        );
        self.n = 0;
        self.idx = 0;
        self.sum_pw_ns = 0;
        self.sum_sync_ns = 0;
        self.sum_paint_ns = 0;
        self.sum_commit_ns = 0;
        self.max_ns = 0;
        self.over = 0;
    }

    /// One line for the process exit: the lifetime picture.
    fn report(self: *FrameStats, kind: []const u8) void {
        if (self.life_frames == 0) return;
        const nf: f64 = @floatFromInt(self.life_frames);
        const ms: f64 = @floatFromInt(std.time.ns_per_ms);
        logz.log(
            "frame {s} total: frames={d} avg={d:.3}ms max={d:.3}ms over1ms={d} ({d:.1}%)",
            .{
                kind,
                self.life_frames,
                @as(f64, @floatFromInt(self.life_ns)) / nf / ms,
                @as(f64, @floatFromInt(self.life_max_ns)) / ms,
                self.life_over,
                @as(f64, @floatFromInt(self.life_over)) / nf * 100.0,
            },
        );
    }
};

/// An in-progress volume drag. The pct is optimistic (the frame paints it
/// until the live graph catches up) and writes are throttled like the Sound
/// tab's sliders.
const Drag = struct {
    /// Node whose volume is being dragged.
    id: u32,
    monitor: bool,
    track: common.Rect,
    /// The card the drag started in: everything a drag can repaint is inside
    /// it, which is what lets drag frames stay damage-scoped.
    row: common.Rect,
    pct: i32,
    last_apply_ns: u64,
};

const DdKind = enum { none, move, port, profile, engine };

/// Which list the open dropdown shows. `id` is the stream for `.move`, the
/// node for `.port` and the card device for `.profile`; `dir` is the port
/// direction (1 = output/sinks, 0 = input/sources).
const DdState = struct {
    kind: DdKind = .none,
    id: u32 = 0,
    dir: u32 = 1,
};

const IconEntry = struct {
    name: []u8 = &.{},
    owned: ?icon_cache.Owned = null,
    /// The candidate cascade was already handed to the cache's worker; when
    /// false the frame queues it and draws a placeholder for a tick or two.
    requested: bool = false,
    /// Cache generation the cascade was queued at. A theme switch bumps it,
    /// dropping every in-flight result, so the row asks again straight away.
    gen: u64 = 0,
    /// Frames this row has waited without pixels. Bounded retries keep a lost
    /// worker verdict from leaving the row blank for good.
    waited: u16 = 0,
};

pub const Win = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    conn: wl_conn.Connection = undefined,
    bound: wl_conn.Connection.Bound = .{},
    loop: wl_loop.Loop = undefined,
    surface: xdg.Toplevel = .{},
    shm: shm_mod.ShmBuffer = undefined,

    // ── shell chrome theme ──
    /// The layered config plus the wallpaper-palette pass every shell
    /// process runs on load (`bin/app.zig`, `bin/overview.zig`). `publishTheme`
    /// resolves `chrome_colors.of` off this into the shared settings Theme,
    /// and an inotify watch on the settings dir reloads it live — without the
    /// pair the window is the one shell surface that paints the M3 defaults
    /// forever.
    loaded: ?config.Loaded = null,
    palette: ?palette_sync.Sync = null,
    cfg_watch: config.watch.Watcher = .{},
    /// Owned copies of the ambient XDG paths, kept for reloads.
    cfg_xdg: ?[]u8 = null,
    cfg_home: ?[]u8 = null,

    running: bool = false,
    wl_ready: bool = false,
    loop_ready: bool = false,
    buf_ready: bool = false,
    pending_redraw: bool = false,
    win_w: i32 = window_width,
    win_h: i32 = window_height,
    ptr_x: f64 = -1,
    ptr_y: f64 = -1,
    timer_fd: i32 = -1,
    last_frame_ns: u64 = 0,
    last_gen: u64 = 0,

    // ── audio ──
    graph: Graph = undefined,
    client: ?*client_mod.Client = null,
    meters: meter_mod.Manager = undefined,

    // ── ui state ──
    page: Page = .playback,
    scroll: scroll_mod.ScrollController = .{},
    dd: dropdown_mod.Dropdown = .{},
    dd_state: DdState = .{},
    drag: ?Drag = null,
    show_meters: bool = true,
    /// Recording: also list the mixer tools' own streams.
    all_streams: bool = false,
    /// Output/Input: only devices with a `device.id`.
    hw_only: bool = false,
    /// Engine page: the last `pw-metadata` read.
    es: live_audio.EngineSettings = .{},
    engine_loaded: bool = false,
    engine_at_ns: u64 = 0,
    /// Scratch for combo labels (rates/quantums are formatted per frame).
    engine_label_buf: [64]u8 = undefined,
    /// Default PCM format of the sink (0..3, -1 unknown).
    pcm_choice: i32 = -1,
    have_pcm: bool = false,
    /// `pw-top` live sample for the status strip and the xrun counter base.
    top: live_audio.PwTopSample = .{},
    xrun_base: i64 = 0,
    xrun_based: bool = false,
    /// Selected output's advertised formats/rates (Engine caption + menus).
    caps: live_audio.NodeCaps = .{},
    caps_at_ns: u64 = 0,
    /// Latency offset card: selected node index and editable field.
    lat_node: i32 = -1,
    lat_field: [24]u8 = [_]u8{0} ** 24,
    lat_len: usize = 0,
    lat_focus: bool = false,
    lat_ns: bool = false,
    restart_wp_arm_ns: u64 = 0,
    restart_wp_done_ns: u64 = 0,
    restart_pw_arm_ns: u64 = 0,
    restart_pw_done_ns: u64 = 0,
    /// Engine page: open custom-value dialog and its text field.
    emodal: EngineModal = .none,
    emodal_force: bool = false,
    emodal_buf: [16]u8 = [_]u8{0} ** 16,
    emodal_len: usize = 0,
    /// Latency unit toggle: the x offset of the frames/ns divider, measured by
    /// the last paint so the hit test picks the segment the user actually sees.
    engine_unit_split: i32 = 0,
    /// Per-node resolved application icons (Playback/Recording rows).
    icons: std.AutoHashMapUnmanaged(u32, IconEntry) = .empty,
    /// Last value of the icon cache's completion counter; a change means a
    /// background decode landed and the frame has to be repainted.
    icons_done: u64 = 0,
    /// Click rects of the header toggles, refreshed every frame by paint.
    hit_meters: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    hit_page_toggle: ?common.Rect = null,
    /// Engine page: the header's Refresh button (it replaces the Meters
    /// toggle, since this page has no meters).
    hit_engine_refresh: ?common.Rect = null,
    needs_repaint: bool = false,
    /// `~/.config/Event-Horizon/audio-center/audio-center.toml`, or "" when
    /// the config root could not be resolved (then nothing is persisted).
    prefs_path: []const u8 = "",
    /// Debug/testing: stop the loop at this instant so an automated run exits
    /// through the normal teardown (EH_AUDIO_CENTER_EXIT_MS).
    exit_at_ns: u64 = 0,
    /// Set when any EH_AUDIO_CENTER_* hook is in play: the run is a test, so
    /// never write the user's prefs from it.
    prefs_locked: bool = false,

    // ── telemetry ──
    /// Frame timing (see FrameStats): the evidence for the 1 ms UX budget.
    /// Scene paints and animation frames are tracked separately, because
    /// they are held to the same budget but do very different work.
    frames: FrameStats = .{},
    anim_frames: FrameStats = .{},
    /// Damage-scoped scene paints (hover, popup) — same budget as the rest,
    /// reported apart because they cost a fraction of a full scene paint.
    narrow_frames: FrameStats = .{},
    /// Card sub-stage accumulators for the current frame (see CardProf).
    card_prof: CardProf = .{},
    /// Baked card backgrounds, keyed by size (see CardBg).
    card_bg: [card_bg_slots]CardBg = @as([card_bg_slots]CardBg, @splat(.{})),
    card_bg_stamp: u64 = 0,

    // ── scene cache ──
    /// The last scene paint as buffer pixels. A frame whose scene hash is
    /// unchanged restores its meter bands from here and touches nothing else,
    /// which is the steady state while audio plays.
    scene: ?*cairo.cairo_surface_t = null,
    scene_w: i32 = 0,
    scene_h: i32 = 0,
    scene_ready: bool = false,
    scene_hash: u64 = 0,
    /// Narrowest region this frame has to repaint (logical px). Input handlers
    /// narrow it to the pixels the pointer can influence — a hover highlight,
    /// an open popup — and every frame ends by clearing it, so anything that
    /// can touch pixels anywhere (a volume write, a page flip) paints fully.
    damage: ?common.Rect = null,
    /// Set by every scene paint (see MeterBand).
    meter_bands: [max_meter_bands]MeterBand = undefined,
    meter_band_n: usize = 0,
    /// EH_AUDIO_CENTER_TRACE=1 — log every single frame, not just summaries.
    trace_frames: bool = false,
    /// EH_AUDIO_CENTER_DUMP=<dir> — write every scene/narrow frame's buffer as
    /// a PNG. Pixel-level verification of the damage-scoped paints: two frames
    /// of the same visible state must be byte-identical outside the meter bars.
    dump_dir: ?[]const u8 = null,
    dump_buf: [512]u8 = undefined,
    dump_n: u32 = 0,
    /// EH_AUDIO_CENTER_HOVER=1 — scripted hover driver for benchmarks. It runs
    /// in-process through the same code path as a real motion event; the real
    /// cursor is never moved (the pointer is the user's, not the app's).
    hover_test: bool = false,
    hover_full: bool = false,
    hover_step: u32 = 0,
    hover_next_ns: u64 = 0,
    /// Armed by an input handler; the frame it triggers logs the
    /// input→pixels latency and clears it (the UX number that matters).
    action_ns: u64 = 0,
    action_tag: []const u8 = "",
    /// Frames that wanted to draw while the compositor still held the buffer.
    busy_skips: u64 = 0,
    /// Timer ticks that found nothing to draw, i.e. frames skipped by design.
    idle_ticks: u64 = 0,
    /// Process start, for the time-to-first-frame line.
    start_ns: u64 = 0,
    first_frame_ns: u64 = 0,

    /// Arm the input→pixels probe for the frame this action triggers.
    fn markAction(self: *Win, tag: []const u8) void {
        self.action_ns = liveNowNs();
        self.action_tag = tag;
    }

    // ── colour engine ───────────────────────────────────────────────────────

    /// Config + wallpaper palette for the window chrome: the same
    /// `loadStacked` + palette-refresh pair every shell process runs, then the
    /// watch that keeps it live.
    fn loadThemeConfig(self: *Win, xdg_config: ?[]const u8, home: ?[]const u8) void {
        self.cfg_xdg = dupOrNull(self.gpa, xdg_config) catch null;
        self.cfg_home = dupOrNull(self.gpa, home) catch null;
        self.reloadThemeConfig();

        const settings = config.settingsDir(self.gpa, xdg_config, home) catch return;
        defer self.gpa.free(settings);
        if (!self.cfg_watch.watchConfigDir(settings)) {
            logz.err("audio-center: theme watch failed for {s}", .{settings});
            return;
        }
        self.loop.watchFd(self.cfg_watch.pollFd(), std.posix.POLL.IN, onConfigFd, @ptrCast(self)) catch {
            self.cfg_watch.close();
            logz.err("audio-center: theme watch fd registration failed", .{});
        };
    }

    /// Re-read the layered config and publish the palette. The `appearance`
    /// palette fields are runtime-only, so the refresh pass has to run after
    /// every load or `chrome_colors.of` hands out the stock colours. Only the
    /// read side is run here (`runPalette`): templates and the compositor
    /// border IPC belong to the shell process, not this window.
    fn reloadThemeConfig(self: *Win) void {
        var fresh = config.loadStacked(self.gpa, self.io, self.cfg_xdg, self.cfg_home) catch |e| {
            logz.err("audio-center: config load failed: {s}", .{@errorName(e)});
            return;
        };
        var pal: palette_sync.Sync = undefined;
        if (self.palette) |p| {
            pal = p;
        } else {
            pal = palette_sync.Sync.init(self.gpa, self.io) catch |e| {
                logz.err("audio-center: palette sync init failed: {s}", .{@errorName(e)});
                fresh.deinit();
                return;
            };
        }
        pal.runPalette(&fresh.cfg);
        self.palette = pal;

        if (self.loaded) |*old| old.deinit();
        self.loaded = fresh;
        self.publishTheme();
    }

    /// Resolve the engine palette into the shared settings Theme — the same
    /// `chrome_colors.of` bridge the dock and desktop widgets paint with
    /// (custom theme > horizon-native > matugen > defaults, colour
    /// adjustments included), so every `ui_paint` call and local paint site
    /// follows the wallpaper.
    fn publishTheme(self: *Win) void {
        const cfg = if (self.loaded) |*l| &l.cfg else return;
        const c = chrome_colors.of(cfg);
        Theme.acc_r = c.accent.r;
        Theme.acc_g = c.accent.g;
        Theme.acc_b = c.accent.b;
        Theme.text_r = c.text.r;
        Theme.text_g = c.text.g;
        Theme.text_b = c.text.b;
        Theme.bg_r = c.dock_fill.r;
        Theme.bg_g = c.dock_fill.g;
        Theme.bg_b = c.dock_fill.b;
        Theme.outline_r = c.outline.r;
        Theme.outline_g = c.outline.g;
        Theme.outline_b = c.outline.b;
    }

    /// Settings-dir inotify fired: reload, drop every cache that baked the old
    /// palette, and repaint the whole window.
    fn onConfigFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = fd;
        _ = revents;
        const self: *Win = @ptrCast(@alignCast(ctx));
        if (!self.cfg_watch.drainAnyLive(&config.watch.live_extra_names)) return;
        self.reloadThemeConfig();
        if (self.loaded == null) return;
        for (&self.card_bg) |*e| {
            if (e.surface) |s| cairo.cairo_surface_destroy(s);
            e.surface = null;
        }
        self.scene_ready = false;
        self.scene_hash = 0;
        self.damage = null;
        self.repaint();
    }

    pub fn start(self: *Win, init: std.process.Init) !bool {
        self.gpa = init.gpa;
        self.io = init.io;

        self.graph = Graph.init(self.gpa);
        self.client = client_mod.Client.create(self.gpa, &self.graph) catch |e| {
            logz.err("audio-center: pipewire connect failed: {s}", .{@errorName(e)});
            return false;
        };
        self.meters = meter_mod.Manager.init(self.gpa, self.client.?);
        logz.log("audio-center: pipewire up ({d} nodes)", .{self.graph.nodes.items.len});

        icon_cache.initGlobal(self.gpa, self.io);
        if (icon_cache.shared()) |ic| {
            ic.setTheme(icon_themes.detectSystemIconTheme(self.io) orelse "hicolor");
        }
        // Start the worker (and the theme index build) now rather than at the
        // first row's paint: on a cold cache that is the longest icon cost
        // there is, and it is entirely off the UI thread.
        self.prefetchIcons();

        self.shm = shm_mod.ShmBuffer.init(self.gpa);
        self.conn = wl_conn.Connection.init(self.gpa);
        if (!self.conn.connect(null)) return false;
        self.wl_ready = true;
        self.conn.bindAll(&self.bound);
        if (!self.conn.roundtrip()) return false;
        self.loop = try wl_loop.Loop.init(self.gpa);
        self.loop_ready = true;
        try self.loop.watchFd(
            self.conn.displayFd(),
            std.posix.POLL.IN,
            wl_pump.displayCallback,
            @ptrCast(self.conn.display.?),
        );
        self.loadThemeConfig(init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME"));

        if (self.bound.xdg_wm_base == null or self.bound.compositor == null) {
            logz.err("audio-center: no xdg_wm_base global", .{});
            return false;
        }
        self.clampToOutput();
        if (!self.surface.create(
            self.bound.compositor,
            self.bound.xdg_wm_base,
            self.win_w,
            self.win_h,
            "Audio Center",
            ns.audio_center_app_id,
        )) return false;
        self.surface.on_configure = onConfigure;
        self.surface.on_closed = noteClosed;
        self.surface.on_scale = onScale;
        self.surface.ctx = self;
        self.surface.setMinSize(min_win_w, min_win_h);

        var ticks: u32 = 0;
        while (ticks < 100 and !self.surface.configured) : (ticks += 1) {
            if (!self.conn.roundtrip()) break;
        }
        if (!self.surface.configured) {
            logz.err("audio-center: surface never configured", .{});
            return false;
        }
        if (!self.shm.ensure(self.bound.shm, "audio-center", self.bufW(), self.bufH())) {
            logz.err("audio-center: shm buffer alloc failed", .{});
            return false;
        }
        self.shm.setReleaseHook(onBufRelease, self);
        self.buf_ready = true;

        if (self.bound.seat_obj) |seat| {
            seat.on_pointer_enter = onEnter;
            seat.on_pointer_leave = onLeave;
            seat.on_pointer_motion = onMotion;
            seat.on_pointer_button = onButton;
            seat.on_pointer_axis = onAxis;
            seat.on_key = onKey;
            seat.cb_ctx = self;
        } else {
            logz.err("audio-center: no wl_seat — the window will be inert", .{});
        }

        // Restore the last session's page and view filters, then let the
        // EH_AUDIO_CENTER_* hooks below override them so test runs stay
        // deterministic.
        if (prefs_mod.path(self.gpa, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME"))) |p| {
            self.prefs_path = p;
            const prefs = prefs_mod.load(self.gpa, self.io, p);
            self.show_meters = prefs.show_meters;
            self.all_streams = prefs.all_streams;
            self.hw_only = prefs.hw_only;
            if (prefs.page < pages.len) self.page = @enumFromInt(prefs.page);
            const band = self.scrollMax();
            self.scroll.setMax(band);
        } else |_| {}

        // Debug/testing: open straight onto a page (EH_AUDIO_CENTER_PAGE=0..5).
        if (std.c.getenv("EH_AUDIO_CENTER_PAGE")) |v| {
            self.prefs_locked = true;
            if (std.fmt.parseInt(u8, std.mem.span(v), 10) catch null) |p| {
                self.setPage(@enumFromInt(@min(p, pages.len - 1)));
            }
        }
        // Debug/testing: start scrolled (EH_AUDIO_CENTER_SCROLL=<px>), so a
        // screenshot test can reach the Engine page's lower cards.
        if (std.c.getenv("EH_AUDIO_CENTER_SCROLL")) |v| {
            self.prefs_locked = true;
            if (std.fmt.parseInt(i32, std.mem.span(v), 10) catch null) |px| {
                self.scroll.setMax(self.scrollMax());
                self.scroll.snapTo(px);
            }
        }
        // Debug/testing: pre-open a dropdown on the first row, so a
        // screenshot test can check the popup's placement without synthetic
        // pointer input (EH_AUDIO_CENTER_DD="<move|port|profile>:<id>[:dir]").
        if (std.c.getenv("EH_AUDIO_CENTER_DD")) |v| {
            self.prefs_locked = true;
            const spec = std.mem.span(v);
            var it = std.mem.splitScalar(u8, spec, ':');
            const kind_s = it.next() orelse "";
            const id_s = it.next() orelse "0";
            const dir_s = it.next();
            const kind: DdKind = if (std.mem.eql(u8, kind_s, "move"))
                .move
            else if (std.mem.eql(u8, kind_s, "port"))
                .port
            else if (std.mem.eql(u8, kind_s, "profile"))
                .profile
            else if (std.mem.eql(u8, kind_s, "engine"))
                .engine
            else
                .none;
            const id = std.fmt.parseInt(u32, id_s, 10) catch 0;
            const dir: u32 = if (dir_s) |d| (std.fmt.parseInt(u32, d, 10) catch 1) else 1;
            if (kind != .none and (id != 0 or kind == .engine)) {
                const r0 = self.cardRect(0);
                const trigger = switch (kind) {
                    .move => moveComboRect(r0),
                    .port => portComboRect(r0),
                    .profile, .engine => profileComboRect(r0),
                    .none => r0,
                };
                self.openDropdown(kind, id, dir, trigger);
            }
        }
        // Debug/testing: leave through the normal teardown after N ms
        // (EH_AUDIO_CENTER_EXIT_MS), so a scripted run exercises deinit and
        // the allocator's leak check.
        if (std.c.getenv("EH_AUDIO_CENTER_EXIT_MS")) |v| {
            if (std.fmt.parseInt(u64, std.mem.span(v), 10) catch null) |ms| {
                self.exit_at_ns = liveNowNs() + ms * std.time.ns_per_ms;
            }
        }
        // EH_AUDIO_CENTER_TRACE=1 — one log line per frame (benchmarking).
        self.trace_frames = std.c.getenv("EH_AUDIO_CENTER_TRACE") != null;
        // EH_AUDIO_CENTER_DUMP=<dir> — pixel dumps for damage verification.
        if (std.c.getenv("EH_AUDIO_CENTER_DUMP")) |dir| {
            const s = std.mem.span(dir);
            if (s.len > 0 and s.len < self.dump_buf.len) {
                @memcpy(self.dump_buf[0..s.len], s);
                self.dump_dir = self.dump_buf[0..s.len];
                logz.log("audio-center: dumping frames to {s}", .{self.dump_dir.?});
            }
        }
        // EH_AUDIO_CENTER_HOVER=1 — scripted hover benchmark.
        self.hover_test = std.c.getenv("EH_AUDIO_CENTER_HOVER") != null;
        if (self.hover_test) self.hover_next_ns = liveNowNs();
        // EH_AUDIO_CENTER_FULL=1 — with the hover driver, force every frame to
        // be a full scene paint: the worst case, sampled on demand.
        self.hover_full = std.c.getenv("EH_AUDIO_CENTER_FULL") != null;
        // The saved page may already be Engine: setPage() early-returns for an
        // unchanged page, so read the live state before the first frame or the
        // page opens on "Unavailable".
        if (self.page == .engine) self.refreshEngine(true);
        // Debug/testing: open the custom-value dialog without synthetic input
        // (EH_AUDIO_CENTER_EMODAL="rate|quantum[:force]").
        if (std.c.getenv("EH_AUDIO_CENTER_EMODAL")) |v| {
            self.prefs_locked = true;
            const spec = std.mem.span(v);
            var it = std.mem.splitScalar(u8, spec, ':');
            const kind_s = it.next() orelse "";
            const force = if (it.next()) |f| std.mem.eql(u8, f, "1") else false;
            if (std.mem.eql(u8, kind_s, "rate")) {
                self.openEngineModal(.rate, force);
            } else if (std.mem.eql(u8, kind_s, "quantum")) {
                self.openEngineModal(.quantum, force);
            }
        }
        logz.log("audio-center ready: {d}x{d} scale={d} page={s} meters={} hw_only={} all_streams={} trace={}", .{
            self.win_w,
            self.win_h,
            self.surface.scale,
            self.page.tag(),
            self.show_meters,
            self.hw_only,
            self.all_streams,
            self.trace_frames,
        });
        self.running = true;
        return true;
    }

    pub fn deinit(self: *Win) void {
        // Closing the window is the common way out; persist the view state
        // here so a session that never touched a control still remembers.
        self.savePrefs();
        if (self.timer_fd >= 0) {
            self.loop.unwatch(self.timer_fd);
            _ = linux.close(self.timer_fd);
            self.timer_fd = -1;
        }
        var it = self.icons.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.owned) |*o| o.deinit(self.gpa);
            self.gpa.free(e.value_ptr.name);
        }
        self.icons.deinit(self.gpa);
        live_audio.freeEngineSettings(self.gpa, &self.es);
        if (self.client) |c| {
            self.meters.deinit();
            c.destroy();
            self.client = null;
        }
        self.graph.deinit();
        icon_cache.deinitGlobal();
        if (self.scene) |s| cairo.cairo_surface_destroy(s);
        for (&self.card_bg) |*e| {
            if (e.surface) |s| cairo.cairo_surface_destroy(s);
        }
        self.surface.destroy();
        self.shm.deinit();
        if (self.wl_ready) self.conn.freeBound(&self.bound);
        if (self.loop_ready) self.loop.deinit();
        if (self.wl_ready) self.conn.deinit();
        if (self.prefs_path.len > 0) self.gpa.free(self.prefs_path);
        self.cfg_watch.close();
        if (self.palette) |*p| p.deinit();
        if (self.loaded) |*l| l.deinit();
        if (self.cfg_xdg) |s| self.gpa.free(s);
        if (self.cfg_home) |s| self.gpa.free(s);
    }

    fn bufW(self: *const Win) i32 {
        return self.win_w * self.surface.scale;
    }

    fn bufH(self: *const Win) i32 {
        return self.win_h * self.surface.scale;
    }

    fn clampToOutput(self: *Win) void {
        if (self.win_w > 1600) self.win_w = 1600;
        if (self.win_h > 1000) self.win_h = 1000;
    }

    fn ensureBufferAndPaint(self: *Win) void {
        if (!self.buf_ready) return;
        if (self.shm.ensure(self.bound.shm, "audio-center", self.bufW(), self.bufH())) {
            self.shm.setReleaseHook(onBufRelease, self);
            self.pending_redraw = false;
            // A fresh buffer holds no pixels: the scene must be painted again
            // before any animation frame may damage only the meter bands.
            self.scene_ready = false;
            self.damageAll();
            self.repaint();
        } else {
            self.buf_ready = false;
        }
    }

    // ── content geometry ────────────────────────────────────────────────────

    fn contentW(self: *const Win) i32 {
        return self.win_w - content_x - content_pad_r;
    }

    fn rowH(self: *const Win) i32 {
        return if (self.page == .configuration or self.page == .engine) card_h_config else card_h;
    }

    /// Layout-space y of card `i` (before scroll).
    fn rowY(self: *const Win, i: usize) i32 {
        return header_h + @as(i32, @intCast(i)) * (self.rowH() + card_gap);
    }

    /// Total content height (layout space, including the header band).
    fn contentHeight(self: *Win) i32 {
        const n: i32 = @intCast(self.rowCount());
        if (n == 0) return header_h;
        return header_h + n * (self.rowH() + card_gap) - card_gap;
    }

    fn scrollMax(self: *Win) i32 {
        return @max(0, self.contentHeight() - (self.win_h - band_pad_b));
    }

    /// Screen-space rect of card `i`.
    fn cardRect(self: *Win, i: usize) common.Rect {
        return .{
            .x = content_x,
            .y = self.rowY(i) - self.scroll.currentPx(),
            .w = self.contentW(),
            .h = self.rowH(),
        };
    }

    // ── row enumeration ─────────────────────────────────────────────────────

    fn nodeVisible(self: *const Win, node: *const Node) bool {
        switch (self.page) {
            .playback => return node.role == .stream_playback and !node.is_meter,
            .recording => {
                if (node.role != .stream_record or node.is_meter) return false;
                if (!self.all_streams and graph_mod.isControlToolApp(node.app_id.get())) return false;
                return true;
            },
            .output, .input => {
                const role: graph_mod.Role = if (self.page == .output) .sink else .source;
                if (node.role != role) return false;
                if (self.hw_only and !node.isHardware()) return false;
                return true;
            },
            .configuration, .engine => return false,
        }
    }

    fn rowCount(self: *const Win) usize {
        if (self.page == .engine) return engine_row_count;
        if (self.page == .configuration) {
            var n: usize = 0;
            for (self.graph.devices.items) |*d| {
                if (d.isAudioCard() and d.profiles.items.len > 0) n += 1;
            }
            return n;
        }
        var n: usize = 0;
        for (self.graph.nodes.items) |*node| {
            if (self.nodeVisible(node)) n += 1;
        }
        return n;
    }

    fn nodeAt(self: *const Win, i: usize) ?*Node {
        var n: usize = 0;
        for (self.graph.nodes.items) |*node| {
            if (!self.nodeVisible(node)) continue;
            if (n == i) return node;
            n += 1;
        }
        return null;
    }

    fn deviceAt(self: *const Win, i: usize) ?*Device {
        var n: usize = 0;
        for (self.graph.devices.items) |*d| {
            if (!d.isAudioCard() or d.profiles.items.len == 0) continue;
            if (n == i) return d;
            n += 1;
        }
        return null;
    }

    /// The card backing a hardware row, when there is one.
    fn deviceFor(self: *Win, node: *const Node) ?*Device {
        if (node.device_id == graph_mod.ID_ANY) return null;
        return self.graph.findDevice(node.device_id);
    }

    fn setPage(self: *Win, p: Page) void {
        if (self.page == p) return;
        self.page = p;
        self.closeDropdown();
        self.emodal = .none;
        self.drag = null;
        self.scroll.snapTo(0);
        self.scroll.setMax(self.scrollMax());
        self.damageAll();
        self.needs_repaint = true;
        self.markAction("page");
        if (p == .engine) {
            self.refreshEngine(true);
            if (self.lat_node < 0) {
                self.lat_node = self.latencyDefaultIndex();
                self.loadLatencyField();
            }
        }
        logz.log("ux: page -> {s} (rows={d})", .{ p.tag(), self.rowCount() });
        self.savePrefs();
    }

    /// Re-read everything the Engine page shows: metadata, PCM choice, the
    /// `pw-top` strip and (every 4 s) the sink's advertised capabilities.
    /// Invalidates pixels only when a value actually moved.
    fn refreshEngine(self: *Win, force: bool) void {
        const now = liveNowNs();
        if (!force and self.engine_at_ns != 0 and now - self.engine_at_ns < engine_refresh_ns) return;
        self.engine_at_ns = now;
        var changed = false;

        var next = live_audio.queryEngineSettings(self.gpa, self.io);
        if (next.available != self.es.available) {
            logz.log("engine: metadata {s}", .{if (next.available) "available" else "unavailable"});
        }
        if (!engineSame(&self.es, &next)) changed = true;
        live_audio.freeEngineSettings(self.gpa, &self.es);
        self.es = next;
        self.engine_loaded = true;

        const pcm = live_audio.queryCompatPcm(self.gpa, self.io);
        if (!self.have_pcm or pcm != self.pcm_choice) {
            self.pcm_choice = pcm;
            self.have_pcm = true;
            changed = true;
        }

        // The default sink drives the graph, so its pw-top row is the real
        // cycle; ask for it by name, since pactl ids and pw-top ids differ.
        const sink_id = self.defaultSinkNodeId();
        const top = live_audio.queryPwTopForName(self.gpa, self.io, self.graph.default_sink.get());
        if (top.available != self.top.available) {
            logz.log("engine: pw-top {s} xruns={d}", .{ if (top.available) "available" else "unavailable", top.xruns_total });
        }
        if (!self.xrun_based) {
            self.xrun_base = top.xruns_total;
            self.xrun_based = true;
        }
        if (top.available != self.top.available or
            top.xruns_total != self.top.xruns_total or
            top.dsp_load_pct != self.top.dsp_load_pct or
            top.reference_quantum != self.top.reference_quantum or
            top.reference_rate_hz != self.top.reference_rate_hz or
            top.focus_quantum != self.top.focus_quantum or
            top.focus_rate_hz != self.top.focus_rate_hz)
        {
            changed = true;
        }
        self.top = top;

        if (force or self.caps_at_ns == 0 or now - self.caps_at_ns >= engine_caps_ns) {
            const id = sink_id;
            const caps = if (id != 0) live_audio.queryNodeCaps(self.gpa, self.io, id) else live_audio.NodeCaps{};
            if (caps.available != self.caps.available) {
                logz.log("engine: caps {s} id={d}", .{ if (caps.available) "available" else "unavailable", id });
            }
            // No sink yet (graph still arriving): do not start the 4 s window,
            // so the caption fills in on the next tick. A failed `pw-dump` is
            // retried sooner, not 4 s later.
            self.caps_at_ns = if (id == 0)
                0
            else if (caps.available)
                now
            else
                now -| (engine_caps_ns - engine_retry_ns);
            if (caps.available != self.caps.available or
                caps.rate_min != self.caps.rate_min or
                caps.rate_max != self.caps.rate_max or
                caps.quantum_limit != self.caps.quantum_limit or
                caps.channels != self.caps.channels or
                caps.formats != self.caps.formats)
            {
                changed = true;
            }
            self.caps = caps;
        }

        // Pick the default output for the latency card once the graph has
        // nodes; also recover when the selected node disappeared.
        const ln = self.latencyNodeCount();
        if (ln == 0) {
            if (self.lat_node != -1) {
                self.lat_node = -1;
                changed = true;
            }
        } else if (self.lat_node < 0 or self.lat_node >= @as(i32, @intCast(ln))) {
            self.lat_node = self.latencyDefaultIndex();
            self.loadLatencyField();
            changed = true;
        }

        if (changed) {
            self.damageAll();
            self.needs_repaint = true;
        }

        // A missing read is usually a startup race (the session is still
        // coming up) or a device that has not appeared yet: retry on a short
        // cadence instead of waiting the full 1.2 s.
        if (!self.es.available or !self.have_pcm or self.pcm_choice < 0 or !self.top.available) {
            self.engine_at_ns = now -| (engine_refresh_ns - engine_retry_ns);
        }
    }

    /// Restart buttons show a short "Confirm" window and a short "Restarted"
    /// one. Clear an expired window here so the label falls back on the next
    /// paint instead of waiting for an unrelated redraw.
    fn expireEngineTransients(self: *Win, now: u64) void {
        var changed = false;
        if (self.restart_wp_arm_ns != 0 and now - self.restart_wp_arm_ns > engine_restart_arm_ns) {
            self.restart_wp_arm_ns = 0;
            changed = true;
        }
        if (self.restart_pw_arm_ns != 0 and now - self.restart_pw_arm_ns > engine_restart_arm_ns) {
            self.restart_pw_arm_ns = 0;
            changed = true;
        }
        if (self.restart_wp_done_ns != 0 and now - self.restart_wp_done_ns > engine_restart_done_ns) {
            self.restart_wp_done_ns = 0;
            changed = true;
        }
        if (self.restart_pw_done_ns != 0 and now - self.restart_pw_done_ns > engine_restart_done_ns) {
            self.restart_pw_done_ns = 0;
            changed = true;
        }
        if (changed) self.needs_repaint = true;
    }

    /// `node.id` of the live default sink, or 0 when it is not in the graph.
    fn defaultSinkNodeId(self: *const Win) u32 {
        const name = self.graph.default_sink.get();
        if (name.len == 0) return 0;
        for (self.graph.nodes.items) |*n| {
            if (n.role == .sink and !n.is_meter and std.mem.eql(u8, n.node_name.get(), name)) return n.id;
        }
        return 0;
    }

    /// Hardware sinks and sources that accept a processing offset.
    fn latencyNodeCount(self: *const Win) usize {
        var n: usize = 0;
        for (self.graph.nodes.items) |*node| {
            if ((node.role == .sink or node.role == .source) and !node.is_meter) n += 1;
        }
        return n;
    }

    fn latencyNodeAt(self: *const Win, i: usize) ?*Node {
        var n: usize = 0;
        for (self.graph.nodes.items) |*node| {
            if (node.role != .sink and node.role != .source) continue;
            if (node.is_meter) continue;
            if (n == i) return node;
            n += 1;
        }
        return null;
    }

    fn latencyNode(self: *const Win) ?*Node {
        if (self.lat_node < 0) return null;
        return self.latencyNodeAt(@intCast(self.lat_node));
    }

    fn latencyNodeLabel(self: *const Win) []const u8 {
        const node = self.latencyNode() orelse return "Choose a node";
        return node.displayName();
    }

    /// Index of the default sink in the latency node list (else the first
    /// node, else -1 when there is nothing to offset yet).
    fn latencyDefaultIndex(self: *const Win) i32 {
        const n = self.latencyNodeCount();
        if (n == 0) return -1;
        const id = self.defaultSinkNodeId();
        if (id != 0) {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const node = self.latencyNodeAt(i) orelse continue;
                if (node.id == id) return @intCast(i);
            }
        }
        return 0;
    }

    fn loadLatencyField(self: *Win) void {
        const node = self.latencyNode() orelse return;
        const off = live_audio.queryLatencyOffset(self.gpa, self.io, node.id);
        self.lat_len = 0;
        if (!off.ok) {
            self.lat_ns = false;
            return;
        }
        self.lat_ns = off.nanoseconds;
        const written = std.fmt.bufPrint(&self.lat_field, "{d}", .{off.value}) catch "";
        self.lat_len = written.len;
    }

    /// Open the numeric dialog for a custom rate/quantum. Mirrors the
    /// settings app: the field starts on the value the row is using now.
    fn openEngineModal(self: *Win, kind: EngineModal, force: bool) void {
        self.emodal = kind;
        self.emodal_force = force;
        self.emodal_len = 0;
        const current: i32 = switch (kind) {
            .rate => if (force and self.es.clock_force_rate_hz > 0) self.es.clock_force_rate_hz else self.es.clock_rate_hz,
            .quantum => if (force and self.es.clock_force_quantum > 0) self.es.clock_force_quantum else self.es.clock_quantum,
            .none => 0,
        };
        if (current > 0) {
            const s = std.fmt.bufPrint(&self.emodal_buf, "{d}", .{current}) catch "";
            self.emodal_len = s.len;
        }
        self.needs_repaint = true;
        self.damageAll();
    }

    fn submitEngineModal(self: *Win) void {
        const raw = std.mem.trim(u8, self.emodal_buf[0..self.emodal_len], " \t\r\n");
        const v = std.fmt.parseInt(i32, raw, 10) catch return;
        if (v <= 0 or v > 2_000_000) return;
        const ok = switch (self.emodal) {
            .rate => if (self.emodal_force)
                live_audio.applyEngineForceRateHz(self.io, v)
            else
                live_audio.applyEngineClockRateHz(self.io, v),
            .quantum => if (self.emodal_force)
                live_audio.applyEngineForceQuantum(self.io, v)
            else
                live_audio.applyEngineQuantum(self.io, v),
            .none => return,
        };
        if (!ok) logz.err("engine: custom write failed kind={s} v={d}", .{ @tagName(self.emodal), v });
        self.emodal = .none;
        if (ok) self.refreshEngine(true);
        self.needs_repaint = true;
        self.damageAll();
    }

    fn applyLatency(self: *Win) void {
        const node = self.latencyNode() orelse return;
        const raw = self.lat_field[0..self.lat_len];
        const value: i64 = if (raw.len == 0) 0 else std.fmt.parseInt(i64, raw, 10) catch return;
        if (live_audio.applyLatencyOffset(self.io, node.id, value, self.lat_ns)) self.loadLatencyField();
        self.needs_repaint = true;
        self.damageAll();
    }

    fn resetAllLatency(self: *Win) void {
        var ids: [64]u32 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.latencyNodeCount() and n < ids.len) : (i += 1) {
            const node = self.latencyNodeAt(i) orelse continue;
            if (node.id == 0) continue;
            ids[n] = node.id;
            n += 1;
        }
        _ = live_audio.resetAllLatency(self.io, ids[0..n]);
        if (self.latencyNode() != null) self.loadLatencyField();
        self.needs_repaint = true;
        self.damageAll();
    }

    /// Persist the view flags (page, meters, filters). Cheap enough to call
    /// on every toggle: the file never changes during a drag.
    fn savePrefs(self: *Win) void {
        if (self.prefs_path.len == 0 or self.prefs_locked) return;
        prefs_mod.save(self.gpa, self.io, self.prefs_path, .{
            .page = @intFromEnum(self.page),
            .show_meters = self.show_meters,
            .all_streams = self.all_streams,
            .hw_only = self.hw_only,
        });
        logz.log("prefs: page={s} meters={} hw_only={} all_streams={}", .{
            self.page.tag(),
            self.show_meters,
            self.hw_only,
            self.all_streams,
        });
    }

    // ── per-frame model sync ────────────────────────────────────────────────

    /// Hand the meter manager exactly the rows the frame will draw (nothing
    /// off-screen keeps a capture stream alive).
    fn syncMeters(self: *Win) void {
        var targets: [96]meter_mod.Target = undefined;
        var n: usize = 0;
        if (self.show_meters and self.page.hasMeters()) {
            const band_y0 = header_h;
            const band_y1 = self.win_h - band_pad_b;
            var i: usize = 0;
            while (i < self.rowCount() and n < targets.len) : (i += 1) {
                const r = self.cardRect(i);
                if (r.y + r.h < band_y0 or r.y > band_y1) continue;
                const node = self.nodeAt(i) orelse continue;
                targets[n] = .{ .id = node.id, .sink = node.role == .sink };
                n += 1;
            }
        }
        _ = self.meters.setTargets(targets[0..n]);
    }

    /// Icons for a stream row: the volume-mixer candidate cascade, resolved
    /// through the shared cache. A cold icon never stalls a frame — the
    /// cascade is handed to the cache's worker once, the frame draws the
    /// placeholder, and the pixels are picked up on a later tick (the cache's
    /// completion counter is what wakes the loop).
    /// The candidate names for a node's icon, in cascade order. Pure string
    /// work over the model — no allocation, no cache access.
    fn iconCandidates(node: *const Node, buf: *[24][2][]const u8) [][2][]const u8 {
        return vmx.streamIconNames(
            buf,
            node.app_icon.get(),
            node.app_id.get(),
            node.app_binary.get(),
            node.app_name.get(),
        );
    }

    /// Queue a node's cascade (once per cache generation) and hand back its
    /// entry. Never blocks, never draws — shared by the paint path and the
    /// prefetch, so a row's icons are usually in flight before it first shows.
    fn requestIcon(self: *Win, node: *const Node) ?*IconEntry {
        const gop = self.icons.getOrPut(self.gpa, node.id) catch return null;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const entry = gop.value_ptr;
        if (entry.owned != null) return entry;
        const ic = icon_cache.shared() orelse return null;
        if (entry.requested and entry.gen == ic.currentGeneration()) return entry;
        entry.requested = true;
        entry.gen = ic.currentGeneration();
        entry.waited = 0;
        var names: [24][2][]const u8 = undefined;
        for (iconCandidates(node, &names)) |cand| {
            ic.enqueue(kindOf(cand), cand[0], icon_sz * 2);
        }
        return entry;
    }

    /// Warm the shared cache ahead of the rows that need it. The seeds start
    /// the worker — and with it the theme index build — before any row exists,
    /// and every stream the graph already knows gets its cascade queued the
    /// moment it appears, so the row usually paints with art instead of a
    /// placeholder. Called once at startup and again on every graph change.
    fn prefetchIcons(self: *Win) void {
        const ic = icon_cache.shared() orelse return;
        for (icon_seeds) |s| ic.enqueue(.app, s, icon_sz * 2);
        if (self.page != .playback and self.page != .recording) return;
        var i: usize = 0;
        while (i < self.rowCount()) : (i += 1) {
            const node = self.nodeAt(i) orelse continue;
            _ = self.requestIcon(node);
        }
    }

    fn adoptIcon(self: *Win, entry: *IconEntry, name: []const u8, owned: icon_cache.Owned) *const icon_cache.Owned {
        if (entry.name.len > 0) self.gpa.free(entry.name);
        entry.name = self.gpa.dupe(u8, name) catch &.{};
        entry.owned = owned;
        return &entry.owned.?;
    }

    fn iconForNode(self: *Win, node: *const Node) ?*const icon_cache.Owned {
        const entry = self.requestIcon(node) orelse return null;
        if (entry.owned) |*o| return o;
        const ic = icon_cache.shared() orelse return null;
        var names: [24][2][]const u8 = undefined;
        const cands = iconCandidates(node, &names);
        entry.waited +|= 1;
        if (entry.waited >= 90) {
            // ~1.5s with nothing to show: resolve inline once (the index is
            // long since built, so this is a cache lookup) — a row can never
            // sit icon-less.
            entry.waited = 0;
            for (cands) |cand| {
                const owned = ic.getOwned(kindOf(cand), cand[0], icon_sz * 2) orelse continue;
                return self.adoptIcon(entry, cand[0], owned);
            }
        } else if (entry.waited % 30 == 0) {
            // Retry: a worker verdict can be lost (theme switch mid-decode,
            // eviction) and the row must not wear a placeholder forever.
            for (cands) |cand| {
                ic.enqueue(kindOf(cand), cand[0], icon_sz * 2);
            }
        }
        // Whatever the worker finished so far wins in cascade order.
        for (cands) |cand| {
            const kind = kindOf(cand);
            if (ic.peek(kind, cand[0], icon_sz * 2)) |owned| {
                return self.adoptIcon(entry, cand[0], owned);
            }
        }
        return null;
    }

    // ── frame ───────────────────────────────────────────────────────────────

    /// Everything a scene paint reads, at the granularity that matters: the
    /// rows the page draws plus the state the chrome shows. Pure model churn
    /// — meter streams arriving, registry noise bumping `graph.generation` —
    /// changes no pixel, so it must not invalidate the cache. Meter *levels*
    /// are absent for the same reason: they are what animation frames redraw.
    fn sceneHash(self: *Win) u64 {
        var h: u64 = 0xcbf29ce484222325;
        h = mixHash(h, @intCast(self.win_w));
        h = mixHash(h, @intCast(self.win_h));
        h = mixHash(h, @intCast(self.surface.scale));
        h = mixHash(h, @intFromEnum(self.page));
        h = mixHash(h, @intFromBool(self.show_meters));
        h = mixHash(h, @intFromBool(self.all_streams));
        h = mixHash(h, @intFromBool(self.hw_only));
        h = mixHash(h, @as(u64, @bitCast(self.scroll.current)));
        h = mixHash(h, self.hoverToken());
        h = mixHash(h, @intFromBool(self.dd.open));
        h = mixHash(h, @intFromEnum(self.dd_state.kind));
        h = mixHash(h, self.dd_state.id);
        h = mixHash(h, self.dd_state.dir);
        h = mixHash(h, self.dd.count);
        h = mixHash(h, @intCast(self.dd.hover_row + 1));
        if (self.drag) |d| {
            h = mixHash(h, 0x9e3779b97f4a7c15);
            h = mixHash(h, d.id);
            h = mixHash(h, @intFromBool(d.monitor));
            h = mixHash(h, @intCast(d.pct));
        }
        h = mixHash(h, self.icons.count());
        // The Engine rows are not graph nodes: their values come from
        // pw-metadata/pw-top/pw-dump, so the loop below hashes nothing for
        // them. Without this the page would keep its first frame forever.
        if (self.page == .engine) h = self.engineSceneHash(h);

        const n = self.rowCount();
        h = mixHash(h, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.page == .configuration) {
                const dev = self.deviceAt(i) orelse continue;
                h = mixHash(h, dev.id);
                h = mixHash(h, @intCast(dev.active_profile + 1));
                h = hashStr(h, dev.displayName());
                h = hashStr(h, dev.device_name.get());
            } else {
                const node = self.nodeAt(i) orelse continue;
                h = mixHash(h, node.id);
                const t = self.graph.volumeTarget(node, false);
                h = mixHash(h, @as(u32, @bitCast(t.volumes[0])));
                h = mixHash(h, @intFromBool(t.mute));
                h = mixHash(h, @intFromBool(self.isDefaultNode(node)));
                h = hashStr(h, node.displayName());
                h = hashStr(h, node.streamTitle());
                h = hashStr(h, self.streamSubLine(node));
                if (self.page == .output or self.page == .input) {
                    const dir: u32 = if (node.role == .sink) 1 else 0;
                    if (self.portCount(node, dir) > 0) h = hashStr(h, self.portLabel(node, dir));
                } else {
                    h = hashStr(h, self.streamComboLabel(node));
                }
            }
        }
        return h;
    }

    /// Fold everything the Engine page can display into the scene hash:
    /// metadata, PCM choice, `pw-top` sample, sink capabilities, the latency
    /// card's field/unit and the restart buttons' arm/done windows.
    fn engineSceneHash(self: *Win, h0: u64) u64 {
        var h = h0;
        h = mixHash(h, @intFromBool(self.es.available));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.es.clock_rate_hz))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.es.clock_force_rate_hz))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.es.clock_quantum))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.es.clock_force_quantum))));
        for (self.es.allowed_rates_hz) |hz| h = mixHash(h, @as(u64, @bitCast(@as(i64, hz))));

        h = mixHash(h, @intFromBool(self.have_pcm));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.pcm_choice))));

        h = mixHash(h, @intFromBool(self.top.available));
        h = mixHash(h, @as(u64, @bitCast(self.top.xruns_total)));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.top.reference_quantum))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.top.reference_rate_hz))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.top.focus_quantum))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.top.focus_rate_hz))));
        // Hundredths: the strip prints up to two decimals below 1%, so a
        // change the user can see has to change the hash.
        h = mixHash(h, @as(u64, @intFromFloat(@round(@max(0, @min(100, self.top.dsp_load_pct)) * 100.0))));

        h = mixHash(h, @intFromBool(self.caps.available));
        h = mixHash(h, @intCast(self.caps.rate_count));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.caps.rate_min))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.caps.rate_max))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.caps.channels))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.caps.formats))));
        h = mixHash(h, @as(u64, @bitCast(@as(i64, self.caps.quantum_limit))));

        h = mixHash(h, @intCast(self.lat_node + 1));
        h = mixHash(h, @intFromBool(self.lat_focus));
        h = mixHash(h, @intFromBool(self.lat_ns));
        h = mixHash(h, self.lat_len);
        h = hashStr(h, self.lat_field[0..self.lat_len]);

        h = mixHash(h, @intFromEnum(self.emodal));
        h = mixHash(h, @intFromBool(self.emodal_force));
        h = mixHash(h, self.emodal_len);
        h = hashStr(h, self.emodal_buf[0..self.emodal_len]);

        // The restart buttons change label (Restart -> Confirm -> Restarted)
        // purely with time; folding the current window in lets the label flip
        // repaint and then settle.
        const now = liveNowNs();
        h = mixHash(h, @intFromBool(self.restart_wp_arm_ns != 0 and now - self.restart_wp_arm_ns <= engine_restart_arm_ns));
        h = mixHash(h, @intFromBool(self.restart_wp_done_ns != 0 and now - self.restart_wp_done_ns <= engine_restart_done_ns));
        h = mixHash(h, @intFromBool(self.restart_pw_arm_ns != 0 and now - self.restart_pw_arm_ns <= engine_restart_arm_ns));
        h = mixHash(h, @intFromBool(self.restart_pw_done_ns != 0 and now - self.restart_pw_done_ns <= engine_restart_done_ns));
        return h;
    }

    /// What the pointer actually hovers, as one value: the widget *and* the row
    /// it belongs to (row 0's mute button is different pixels from row 1's), or
    /// 0 for "nothing here reacts to hover". The scene hash folds this in
    /// instead of the raw position, so moving across the header, a gap or the
    /// icon column keeps the hash stable: those frames stay meter-only
    /// animation frames — or idle ticks — instead of scene paints.
    fn hoverToken(self: *Win) u64 {
        const x = self.ptr_x;
        const y = self.ptr_y;
        if (x < 0 or y < 0) return 0;
        if (x >= @as(f64, @floatFromInt(self.win_w)) or y >= @as(f64, @floatFromInt(self.win_h))) return 0;
        if (self.dd.open) {
            const popup = self.popupRect();
            if (common.pointInRect(x, y, popup)) return 0xd0;
        }
        if (y < @as(f64, @floatFromInt(header_h))) return 0;
        if (x < @as(f64, @floatFromInt(rail_w))) {
            for (pages, 0..) |_, i| {
                if (common.pointInRect(x, y, railBtnRect(i))) return 0x100 + i;
            }
            return 0;
        }
        const i = self.hitCard(x, y) orelse return 0;
        const r = self.cardRect(i);
        const row: u64 = @as(u64, i) + 1;
        switch (self.page) {
            .configuration, .engine => {},
            .output, .input => {
                if (common.pointInRect(x, y, defaultBtnRect(r))) return (0x2 << 8) | row;
                if (common.pointInRect(x, y, muteBtnRect(r))) return (0x4 << 8) | row;
            },
            else => {
                if (common.pointInRect(x, y, closeBtnRect(r))) return (0x8 << 8) | row;
                if (common.pointInRect(x, y, muteBtnRect(r))) return (0x4 << 8) | row;
            },
        }
        return 0;
    }

    /// (Re)create the scene cache for the current buffer size. Any size change
    /// drops the cached pixels.
    fn ensureSceneSurface(self: *Win) bool {
        const w = self.bufW();
        const h = self.bufH();
        if (self.scene) |s| {
            if (self.scene_w == w and self.scene_h == h) return true;
            cairo.cairo_surface_destroy(s);
            self.scene = null;
            self.scene_ready = false;
        }
        const s = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
        if (cairo.cairo_surface_status(s) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(s);
            return false;
        }
        self.scene = s;
        self.scene_w = w;
        self.scene_h = h;
        return true;
    }

    /// Snapshot the meter bands of the freshly painted scene into the cache.
    /// Bands are the only pixels animation frames ever restore, so a full paint
    /// copies just those (thin strips) instead of the whole buffer; a narrow
    /// paint passes its damage and refreshes only the bands it touched.
    fn cacheBands(self: *Win, clip: ?common.Rect) void {
        const cache = self.scene orelse return;
        const sc: i32 = @max(1, self.surface.scale);
        const target = self.shm.cr orelse return;
        const src = cairo.cairo_get_target(target) orelse return;
        for (self.meter_bands[0..self.meter_band_n]) |b| {
            const inter = if (clip) |d| (rectIsect(b.rect, d) orelse continue) else b.rect;
            copyRect(src, cache, inter.x * sc, inter.y * sc, inter.w * sc, inter.h * sc);
        }
        self.scene_ready = true;
    }

    /// Put one band's background back from the cache (buffer pixels).
    fn restoreBand(self: *Win, cr: *cairo.cairo_t, rect: common.Rect) void {
        const cache = self.scene orelse return;
        const dst = cairo.cairo_get_target(cr) orelse return;
        const sc: i32 = @max(1, self.surface.scale);
        copyRect(cache, dst, rect.x * sc, rect.y * sc, rect.w * sc, rect.h * sc);
    }

    /// The open popup's box in window coordinates, widened to cover the soft
    /// shadow that spills past its own rect.
    fn popupRect(self: *Win) common.Rect {
        const g = self.dd.popupGeom(self.win_h);
        return padRect(.{ .x = g.x, .y = g.y, .w = g.w, .h = g.h }, popup_pad);
    }

    /// Pixels the pointer can influence at (x, y). Only a handful of widgets
    /// react to hover at all — the four per-row buttons (close, default, mute,
    /// and the rail's page buttons) plus the open popup. Everywhere else the
    /// scene is pointer-independent, and a zero-area rect says exactly that:
    /// "this frame has nothing to repaint". Null means the pointer is outside
    /// the window (the old region still has to be cleared).
    fn pointerRegion(self: *Win, x: f64, y: f64) ?common.Rect {
        if (x < 0 or y < 0) return null;
        if (x >= @as(f64, @floatFromInt(self.win_w)) or y >= @as(f64, @floatFromInt(self.win_h))) return null;
        const nothing = common.Rect{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = 0, .h = 0 };
        if (self.dd.open) {
            const popup = self.popupRect();
            if (common.pointInRect(x, y, popup)) return popup;
        }
        // Header: the close button and the toggles have no hover state.
        if (y < @as(f64, @floatFromInt(header_h))) return nothing;
        if (x < @as(f64, @floatFromInt(rail_w))) {
            for (pages, 0..) |_, i| {
                const r = railBtnRect(i);
                if (common.pointInRect(x, y, r)) return padRect(r, 4);
            }
            return nothing;
        }
        if (self.hitCard(x, y)) |i| {
            const r = self.cardRect(i);
            switch (self.page) {
                .configuration, .engine => {},
                .output, .input => {
                    const br = defaultBtnRect(r);
                    if (common.pointInRect(x, y, br)) return padRect(br, 4);
                    const mr = muteBtnRect(r);
                    if (common.pointInRect(x, y, mr)) return padRect(mr, 4);
                },
                else => {
                    const xr = closeBtnRect(r);
                    if (common.pointInRect(x, y, xr)) return padRect(xr, 4);
                    const mr = muteBtnRect(r);
                    if (common.pointInRect(x, y, mr)) return padRect(mr, 4);
                },
            }
        }
        return nothing;
    }

    /// Narrow this frame to the pixels the pointer moved over (old and new
    /// position). Joining with the pending damage keeps a frame the
    /// compositor skipped from dropping the highlight it never painted.
    fn damagePointer(self: *Win, from_x: f64, from_y: f64, to_x: f64, to_y: f64) void {
        const a = self.pointerRegion(from_x, from_y);
        const b = self.pointerRegion(to_x, to_y);
        self.damage = rectJoin(self.damage, rectJoin(a, b));
    }

    /// Widen this frame back to a full paint: a model change can touch pixels
    /// anywhere (another row's default chip, a row appearing, a meter band).
    fn damageAll(self: *Win) void {
        self.damage = null;
    }

    /// Record where this row's meter bars go; the bars themselves are drawn
    /// after the scene is cached (see `repaint`).
    /// The card's glass background: the exact pixels `ui_paint.card` drew on
    /// the previous frame, baked over the window's base fill and blitted with
    /// SOURCE (a replace, never a second composite). Baked once per card size —
    /// the five translucent passes cost ~500µs each, the blit ~50µs.
    fn paintCardBg(self: *Win, c: *cairo.cairo_t, r: common.Rect) void {
        const cw = r.w;
        const ch = r.h + 2; // the soft shadow spills 2px below the card
        if (cw <= 0 or ch <= 2) return;
        var slot: *CardBg = &self.card_bg[0];
        self.card_bg_stamp += 1;
        for (&self.card_bg) |*e| {
            if (e.surface != null and e.w == cw and e.h == ch) {
                e.stamp = self.card_bg_stamp;
                slot = e;
                break;
            }
            if (e.surface == null) {
                slot = e;
                break;
            }
            if (e.stamp < slot.stamp) slot = e;
        }
        if (slot.surface == null or slot.w != cw or slot.h != ch) {
            if (slot.surface) |s| cairo.cairo_surface_destroy(s);
            slot.surface = null;
            const s = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, cw, ch);
            if (cairo.cairo_surface_status(s) != cairo.CAIRO_STATUS_SUCCESS) {
                cairo.cairo_surface_destroy(s);
                ui_paint.card(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 1.0);
                return;
            }
            const cr2 = cairo.cairo_create(s);
            defer cairo.cairo_destroy(cr2);
            cairo.cairo_set_operator(cr2, cairo.CAIRO_OPERATOR_SOURCE);
            cairo.cairo_set_source_rgba(cr2, Theme.bg_r * 0.35, Theme.bg_g * 0.35, Theme.bg_b * 0.35, 0.78);
            cairo.cairo_paint(cr2);
            cairo.cairo_set_operator(cr2, cairo.CAIRO_OPERATOR_OVER);
            ui_paint.card(cr2, 0, 0, @floatFromInt(cw), @floatFromInt(r.h), 1.0);
            slot.surface = s;
            slot.w = cw;
            slot.h = ch;
            slot.stamp = self.card_bg_stamp;
        }
        cairo.cairo_save(c);
        cairo.cairo_set_operator(c, cairo.CAIRO_OPERATOR_SOURCE);
        cairo.cairo_set_source_surface(c, slot.surface.?, @floatFromInt(r.x), @floatFromInt(r.y));
        cairo.cairo_rectangle(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(cw), @floatFromInt(ch));
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
    }

    /// Record where this row's meter bars go; the bars themselves are drawn
    /// after the scene is cached (see `repaint`).
    fn noteMeterBand(self: *Win, id: u32, tr: common.Rect, muted: bool) void {
        if (!self.show_meters or !self.page.hasMeters()) return;
        if (self.meter_band_n >= max_meter_bands) return;
        self.meter_bands[self.meter_band_n] = .{
            .id = id,
            .tr = tr,
            .rect = bandRect(tr),
            .muted = muted,
        };
        self.meter_band_n += 1;
    }

    fn paintMetersPass(self: *Win, c: *cairo.cairo_t) void {
        for (self.meter_bands[0..self.meter_band_n]) |b| {
            self.paintMeterBars(c, b.id, b.tr, b.muted);
        }
    }

    /// The buffer damage for the bands of the frame just painted.
    fn damageMeterBands(self: *Win) void {
        const sc: i32 = @max(1, self.surface.scale);
        for (self.meter_bands[0..self.meter_band_n]) |b| {
            self.surface.damage(
                b.rect.x * sc,
                b.rect.y * sc,
                b.rect.w * sc,
                b.rect.h * sc,
            );
        }
    }

    /// EH_AUDIO_CENTER_DUMP=<dir>: write this frame's buffer as a PNG. Only
    /// scene and narrow frames dump — animation frames reuse those pixels.
    fn dumpFrame(self: *Win, cr: *cairo.cairo_t, kind: []const u8) void {
        const dir = self.dump_dir orelse return;
        if (self.dump_n >= 500) return;
        var path: [600]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&path, "{s}/fr_{d:0>4}_{s}.png", .{ dir, self.dump_n, kind }, 0) catch return;
        const target = cairo.cairo_get_target(cr) orelse return;
        _ = cairo.cairo_surface_write_to_png(target, z.ptr);
        self.dump_n += 1;
    }

    /// Hand the finished frame to the compositor.
    fn commitFrame(self: *Win) void {        self.shm.markBusy();
        self.surface.attach(self.shm.wlBuffer(), 0, 0);
        self.surface.setBufferScale(self.surface.scale);
        self.surface.commit();
        _ = self.conn.flush();
    }

    pub fn repaint(self: *Win) void {
        if (!self.buf_ready) return;
        const cr = self.shm.cr orelse return;
        if (self.shm.busy) {
            self.pending_redraw = true;
            self.busy_skips += 1;
            return;
        }

        const now = liveNowNs();
        const t_pw0 = now;
        const dt: f32 = if (self.last_frame_ns == 0)
            0.016
        else
            @floatCast(@as(f64, @floatFromInt(now - self.last_frame_ns)) / @as(f64, std.time.ns_per_s));
        self.last_frame_ns = now;

        // PipeWire events (including meter callbacks) land here, on the UI
        // thread, before the frame reads the model.
        if (self.client) |c| c.iterate(0);
        const t_pw1 = liveNowNs();
        self.syncMeters();
        self.meters.tick(dt);

        // Streams that appeared in this frame's PipeWire events get their icon
        // cascades queued before the paint, so the worker has the whole frame
        // (and usually several) to beat the row to the screen.
        if (self.graph.generation != self.last_gen) self.prefetchIcons();

        self.scroll.setMax(self.scrollMax());
        self.scroll.tick();
        const t_sync1 = liveNowNs();

        // Steady state: the scene is byte-identical to the last paint, only
        // the meter levels moved. Restore the bands, redraw the bars, done.
        const hash = self.sceneHash();
        // A frame without a valid scene cache has to paint the whole window:
        // the damage-scoped path relies on the buffer already holding this
        // scene everywhere the damage does not reach. An empty damage rect
        // means "no pixel the pointer can reach changed" — no scene paint.
        const dmg = if (self.damage) |d| (if (d.w > 0 and d.h > 0) d else null) else null;
        const narrow = if (self.scene_ready) dmg else null;
        if (hash == self.scene_hash and self.scene_ready and narrow == null) {
            if (self.meter_band_n == 0) {
                // Nothing animates on this page and nothing changed: the
                // frame is not worth a commit at all.
                self.idle_ticks += 1;
                self.needs_repaint = false;
                self.damage = null;
                self.armTick();
                return;
            }
            cairo.cairo_reset_clip(cr);
            cairo.cairo_identity_matrix(cr);
            const sca: f64 = @floatFromInt(self.surface.scale);
            cairo.cairo_scale(cr, sca, sca);
            cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
            for (self.meter_bands[0..self.meter_band_n]) |b| self.restoreBand(cr, b.rect);
            self.paintMetersPass(cr);
            const t_paint1 = liveNowNs();

            self.damageMeterBands();
            self.commitFrame();
            const t_end = liveNowNs();

            self.telemetryFrame(.anim, t_pw0, t_pw1, t_sync1, .{
                .cards = t_paint1 - t_sync1,
            }, t_paint1, t_end);
            self.last_gen = self.graph.generation;
            self.needs_repaint = false;
            self.damage = null;
            self.armTick();
            return;
        }

        cairo.cairo_reset_clip(cr);
        cairo.cairo_identity_matrix(cr);
        const sc: f64 = @floatFromInt(self.surface.scale);
        cairo.cairo_scale(cr, sc, sc);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
        if (narrow) |d| {
            // Damage-scoped paint: the same painters, clipped to the pixels
            // the pointer can have changed. Outside the clip the buffer
            // already holds this scene, so the result is identical to a full
            // paint at a fraction of the cost.
            cairo.cairo_rectangle(cr, @floatFromInt(d.x), @floatFromInt(d.y), @floatFromInt(d.w), @floatFromInt(d.h));
            cairo.cairo_clip(cr);
        }
        cairo.cairo_set_source_rgba(cr, Theme.bg_r * 0.35, Theme.bg_g * 0.35, Theme.bg_b * 0.35, 0.78);
        cairo.cairo_paint(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);

        self.paintRail(cr);
        const t_rail = liveNowNs();
        self.paintHeader(cr);
        const t_hdr = liveNowNs();
        self.card_prof = .{};
        self.meter_band_n = 0;
        self.paintCards(cr);
        const t_cards = liveNowNs();
        self.paintDropdown(cr);
        self.paintEngineModal(cr);
        const t_dd = liveNowNs();
        drawClose(cr, self.win_w);
        const t_paint1 = liveNowNs();

        // Cache the finished scene's meter bands (meters excluded), then draw
        // the bars over it: the cache must hold the band backgrounds, not the
        // bars.
        if (self.ensureSceneSurface()) {
            self.cacheBands(narrow);
            self.scene_hash = hash;
        }
        cairo.cairo_reset_clip(cr);
        if (narrow != null) {
            // A narrow paint can leave the previous frame's bars sitting under
            // a band the damage did not cover: put every band's cached
            // background back first (the ones inside the damage were just
            // repainted, and refreshed in the cache, so this is a no-op there).
            for (self.meter_bands[0..self.meter_band_n]) |b| self.restoreBand(cr, b.rect);
        }
        self.paintMetersPass(cr);

        if (narrow) |d| {
            const dsc = self.surface.scale;
            self.surface.damage(d.x * dsc, d.y * dsc, d.w * dsc, d.h * dsc);
            self.damageMeterBands();
        } else {
            self.surface.damage(0, 0, self.bufW(), self.bufH());
        }
        self.commitFrame();
        const t_end = liveNowNs();

        self.telemetryFrame(if (narrow != null) .narrow else .scene, t_pw0, t_pw1, t_sync1, .{
            .rail = t_rail - t_sync1,
            .hdr = t_hdr - t_rail,
            .cards = t_cards - t_hdr,
            .dd = t_dd - t_cards,
            .close = t_paint1 - t_dd,
        }, t_paint1, t_end);
        self.dumpFrame(cr, if (narrow != null) "narrow" else "scene");

        self.last_gen = self.graph.generation;
        self.needs_repaint = false;
        self.damage = null;
        self.armTick();
    }

    /// Everything the frame logs: graph deltas, the budget check, an optional
    /// per-frame trace line, the input→pixels latency of the action that
    /// triggered it, and the rolling percentile summary.
    fn telemetryFrame(self: *Win, kind: FrameKind, t0: u64, t_pw1: u64, t_sync1: u64, prof: PaintProf, t_paint1: u64, t_end: u64) void {
        const pw_ns = t_pw1 - t0;
        const sync_ns = t_sync1 - t_pw1;
        const paint_ns = t_paint1 - t_sync1;
        const commit_ns = t_end - t_paint1;
        const total_ns = t_end - t0;
        const ms: f64 = @floatFromInt(std.time.ns_per_ms);

        if (self.graph.generation != self.last_gen) {
            logz.log("graph: gen={d} nodes={d} streams={d} devices={d} links={d} default_sink={s} default_source={s}", .{
                self.graph.generation,
                self.graph.nodes.items.len,
                self.graph.countRole(.stream_playback) + self.graph.countRole(.stream_record),
                self.graph.devices.items.len,
                self.graph.links.items.len,
                self.graph.default_sink.get(),
                self.graph.default_source.get(),
            });
        }

        const stats: *FrameStats = switch (kind) {
            .anim => &self.anim_frames,
            .narrow => &self.narrow_frames,
            .scene => &self.frames,
        };
        stats.record(pw_ns, sync_ns, paint_ns, commit_ns);

        if (total_ns > frame_budget_ns) {
            logz.log("frame slow: kind={s} {d:.3}ms (pw {d:.3} sync {d:.3} paint {d:.3} commit {d:.3} | rail {d:.3} hdr {d:.3} cards {d:.3} dd {d:.3} close {d:.3} | card bg {d:.3} icon {d:.3} text {d:.3} ctrl {d:.3} vol {d:.3}) page={s} rows={d} bands={d} meters={} dd_open={} drag={} scroll={}", .{
                kind.tag(),
                @as(f64, @floatFromInt(total_ns)) / ms,
                @as(f64, @floatFromInt(pw_ns)) / ms,
                @as(f64, @floatFromInt(sync_ns)) / ms,
                @as(f64, @floatFromInt(paint_ns)) / ms,
                @as(f64, @floatFromInt(commit_ns)) / ms,
                @as(f64, @floatFromInt(prof.rail)) / ms,
                @as(f64, @floatFromInt(prof.hdr)) / ms,
                @as(f64, @floatFromInt(prof.cards)) / ms,
                @as(f64, @floatFromInt(prof.dd)) / ms,
                @as(f64, @floatFromInt(prof.close)) / ms,
                @as(f64, @floatFromInt(self.card_prof.bg)) / ms,
                @as(f64, @floatFromInt(self.card_prof.icon)) / ms,
                @as(f64, @floatFromInt(self.card_prof.text)) / ms,
                @as(f64, @floatFromInt(self.card_prof.ctrl)) / ms,
                @as(f64, @floatFromInt(self.card_prof.vol)) / ms,
                self.page.tag(),
                self.rowCount(),
                self.meter_band_n,
                self.show_meters and self.page.hasMeters(),
                self.dd.open,
                self.drag != null,
                self.scroll.animating,
            });
        }
        if (self.trace_frames) {
            logz.log("frame: kind={s} {d:.3}ms (pw {d:.3} sync {d:.3} paint {d:.3} commit {d:.3} | rail {d:.3} hdr {d:.3} cards {d:.3} dd {d:.3} | card bg {d:.3} icon {d:.3} text {d:.3} ctrl {d:.3} vol {d:.3}) page={s} rows={d} bands={d}", .{
                kind.tag(),
                @as(f64, @floatFromInt(total_ns)) / ms,
                @as(f64, @floatFromInt(pw_ns)) / ms,
                @as(f64, @floatFromInt(sync_ns)) / ms,
                @as(f64, @floatFromInt(paint_ns)) / ms,
                @as(f64, @floatFromInt(commit_ns)) / ms,
                @as(f64, @floatFromInt(prof.rail)) / ms,
                @as(f64, @floatFromInt(prof.hdr)) / ms,
                @as(f64, @floatFromInt(prof.cards)) / ms,
                @as(f64, @floatFromInt(prof.dd)) / ms,
                @as(f64, @floatFromInt(self.card_prof.bg)) / ms,
                @as(f64, @floatFromInt(self.card_prof.icon)) / ms,
                @as(f64, @floatFromInt(self.card_prof.text)) / ms,
                @as(f64, @floatFromInt(self.card_prof.ctrl)) / ms,
                @as(f64, @floatFromInt(self.card_prof.vol)) / ms,
                self.page.tag(),
                self.rowCount(),
                self.meter_band_n,
            });
        }
        if (self.first_frame_ns == 0 and self.start_ns != 0) {
            self.first_frame_ns = t_end;
            logz.log("ux: first frame in {d:.2}ms (page={s}, {d}x{d})", .{
                @as(f64, @floatFromInt(t_end - self.start_ns)) / ms,
                self.page.tag(),
                self.win_w,
                self.win_h,
            });
        }
        if (self.action_ns != 0) {
            logz.log("ux: {s} -> pixels in {d:.3}ms", .{
                self.action_tag,
                @as(f64, @floatFromInt(t_end - self.action_ns)) / ms,
            });
            self.action_ns = 0;
            self.action_tag = "";
        }
        if (stats.n >= frame_flush_every) stats.flush(kind.tag(), self.page, self.rowCount());
    }

    /// 16 ms while meters run or a drag/scroll animates; a lazy 500 ms tick
    /// otherwise so graph changes still reach the frame.
    fn armTick(self: *Win) void {
        const meter_live = self.show_meters and self.page.hasMeters();
        const fast = meter_live or self.scroll.animating or self.drag != null or self.exit_at_ns != 0 or self.hover_test;
        if (self.timer_fd < 0) {
            const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
            if (rc < 0) return;
            const fd: i32 = @intCast(rc);
            self.loop.watchFd(fd, std.posix.POLL.IN, onTimer, @ptrCast(self)) catch {
                _ = linux.close(fd);
                return;
            };
            self.timer_fd = fd;
        }
        const period: i64 = if (fast) 16_000_000 else 500_000_000;
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = period },
        };
        _ = linux.timerfd_settime(self.timer_fd, .{}, &its, null);
    }

    fn onBufRelease(ctx: *anyopaque) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        if (self.pending_redraw) {
            self.pending_redraw = false;
            self.repaint();
        }
    }

    fn onTimer(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        if (self.exit_at_ns != 0 and liveNowNs() >= self.exit_at_ns) {
            self.running = false;
            wl_loop.Loop.requestStop();
            return;
        }
        if (self.hover_test) self.hoverStep();
        // The Engine page reads processes (`pw-metadata`, `pw-top`, `pw-dump`),
        // so it polls from the tick rather than polling inside a paint: an idle
        // page still notices an external rate change or a new xrun. An open
        // dropdown does not stop the polling: checking a value while the popup
        // is up is exactly when the read has to be current.
        if (self.page == .engine) {
            self.refreshEngine(false);
            self.expireEngineTransients(liveNowNs());
        }
        // A background icon decode landed: redraw so the placeholder becomes
        // the real artwork.
        if (icon_cache.shared()) |ic| {
            const done = ic.completions();
            if (done != self.icons_done) {
                self.icons_done = done;
                self.needs_repaint = true;
            }
        }
        // Skip the frame when nothing moved: no meters, no drag, no scroll
        // animation and no graph change since the last paint.
        const moving = (self.show_meters and self.page.hasMeters()) or
            self.scroll.animating or self.drag != null or
            self.needs_repaint or self.graph.generation != self.last_gen;
        if (moving) {
            // Only a frame the model changed has to be a full paint; a tick
            // that merely follows the meters stays as narrow as the damage
            // the pointer left behind.
            if (self.graph.generation != self.last_gen or self.needs_repaint) self.damageAll();
            self.repaint();
        } else {
            // Nothing moved: the frame is deliberately skipped, which is what
            // keeps an idle mixer at ~0% CPU.
            self.idle_ticks += 1;
            self.armTick();
        }
    }

    /// `EH_AUDIO_CENTER_HOVER=1`: cycle the pointer through the spots a user
    /// actually visits — a row's mute button, the default button, a rail page,
    /// the header, the gaps that react to nothing, the open popup — feeding the
    /// same damage path a real motion event does. One step per ~40 ms.
    fn hoverStep(self: *Win) void {
        const now = liveNowNs();
        if (now < self.hover_next_ns) return;
        self.hover_next_ns = now + 40 * std.time.ns_per_ms;
        const step = self.hover_step;
        self.hover_step += 1;

        const w: f64 = @floatFromInt(self.win_w);
        const h: f64 = @floatFromInt(self.win_h);
        const pitch: f64 = @floatFromInt(self.rowH() + card_gap);
        const row0: f64 = @floatFromInt(header_h + 1);
        var px: f64 = w * 0.5;
        var py: f64 = h * 0.5;
        switch (step % 10) {
            0 => {
                px = @floatFromInt(content_x + card_pad + @divTrunc(mute_sz, 2));
                py = row0 + @as(f64, @floatFromInt(track_off_y + @divTrunc(track_h, 2)));
            },
            1 => {
                px = @floatFromInt(content_x + self.contentW() - card_pad - @divTrunc(def_w, 2));
                py = row0 + pitch + 30.0;
            },
            2 => {
                px = @floatFromInt(content_x + self.contentW() - card_pad - @divTrunc(close_sz, 2));
                py = row0 + 2.0 * pitch + 31.0;
            },
            3 => {
                px = @floatFromInt(rail_btn_x + @divTrunc(rail_btn_w, 2));
                py = @floatFromInt(rail_base_y + rail_pitch + @divTrunc(rail_btn_h, 2));
            },
            4 => {
                px = w - 60;
                py = 74;
            },
            5 => {
                px = w * 0.4;
                py = row0 + pitch - 6.0;
            },
            6 => {
                px = @floatFromInt(content_x + card_pad + 8);
                py = row0 + @as(f64, @floatFromInt(icon_off_y + 8));
            },
            7 => {
                px = -1;
                py = -1;
            },
            8 => {
                if (!self.dd.open) self.openTestDropdown();
                px = w * 0.5;
                py = row0 + 30.0;
            },
            else => {
                if (self.dd.open) {
                    self.dd.hover_row = 1;
                    self.damage = rectJoin(self.damage, self.popupRect());
                    self.closeDropdown();
                }
            },
        }
        const from_x = self.ptr_x;
        const from_y = self.ptr_y;
        self.ptr_x = px;
        self.ptr_y = py;
        self.damagePointer(from_x, from_y, px, py);
        if (self.hover_full) self.damageAll();
        self.repaint();
    }

    /// Whatever dropdown the page's first row offers — the hover benchmark
    /// opens and closes it so popup damage is measured too.
    fn openTestDropdown(self: *Win) void {
        if (self.rowCount() == 0) return;
        const r = self.cardRect(0);
        switch (self.page) {
            .configuration => {
                const dev = self.deviceAt(0) orelse return;
                self.openDropdown(.profile, dev.id, 0, profileComboRect(r));
            },
            .output, .input => {
                const node = self.nodeAt(0) orelse return;
                const dir: u32 = if (node.role == .sink) 1 else 0;
                if (self.portCount(node, dir) == 0) return;
                self.openDropdown(.port, node.id, dir, portComboRect(r));
            },
            .engine => {},
            else => {
                const node = self.nodeAt(0) orelse return;
                const dir: u32 = if (self.page == .playback) 1 else 0;
                self.openDropdown(.move, node.id, dir, moveComboRect(r));
            },
        }
    }

    fn onConfigure(ctx: *anyopaque, w: i32, h: i32) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        self.win_w = @max(w, min_win_w);
        self.win_h = @max(h, min_win_h);
        self.scroll.setMax(self.scrollMax());
        self.ensureBufferAndPaint();
    }

    fn onScale(ctx: *anyopaque, scale: i32) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        logz.log("audio-center: output scale changed -> {}x", .{scale});
        self.ensureBufferAndPaint();
    }

    fn noteClosed(ctx: *anyopaque) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        self.running = false;
        wl_loop.Loop.requestStop();
    }

// ── card sub-rects ──────────────────────────────────────────────────────────
//
// All in screen coordinates, derived from one card rect so paint and hit
// tests can never disagree.

/// The rail page button for page index `i` — paint and hit tests share it.
fn railBtnRect(i: usize) common.Rect {
    return .{
        .x = rail_btn_x,
        .y = rail_base_y + @as(i32, @intCast(i)) * rail_pitch,
        .w = rail_btn_w,
        .h = rail_btn_h,
    };
}

fn closeBtnRect(r: common.Rect) common.Rect {
    return .{ .x = r.x + r.w - card_pad - close_sz, .y = r.y + 16, .w = close_sz, .h = close_sz };
}

/// Stream rows: the move combo sits left of the terminate button.
fn moveComboRect(r: common.Rect) common.Rect {
    return .{
        .x = r.x + r.w - card_pad - close_sz - 8 - combo_w,
        .y = r.y + 15,
        .w = combo_w,
        .h = combo_h,
    };
}

fn defaultBtnRect(r: common.Rect) common.Rect {
    return .{ .x = r.x + r.w - card_pad - def_w, .y = r.y + 15, .w = def_w, .h = combo_h };
}

/// Device rows: the port combo sits left of the "Default" button.
fn portComboRect(r: common.Rect) common.Rect {
    return .{
        .x = r.x + r.w - card_pad - def_w - 10 - combo_w,
        .y = r.y + 15,
        .w = combo_w,
        .h = combo_h,
    };
}

/// Configuration rows: one wide profile combo on the right.
fn profileComboRect(r: common.Rect) common.Rect {
    const w: i32 = @min(420, r.w - icon_sz_config - 32 - 160);
    return .{ .x = r.x + r.w - card_pad - w, .y = r.y + @divTrunc(r.h - combo_h, 2), .w = w, .h = combo_h };
}

fn muteBtnRect(r: common.Rect) common.Rect {
    // Centred on the volume track; the icon above it keeps its own row, so
    // the two never read as one glyph.
    return .{ .x = r.x + card_pad, .y = r.y + track_off_y + @divTrunc(track_h - mute_sz, 2), .w = mute_sz, .h = mute_sz };
}

fn trackRect(r: common.Rect) common.Rect {
    return .{
        .x = r.x + track_off_x,
        .y = r.y + track_off_y,
        .w = r.w - track_off_x - track_w_pad,
        .h = track_h,
    };
}

fn iconRect(r: common.Rect) common.Rect {
    return .{ .x = r.x + card_pad, .y = r.y + icon_off_y, .w = icon_sz, .h = icon_sz };
}

/// Volume-mixer icon candidates tag their kind in the second slot: "t" is a
/// tray/status icon, anything else a themed app icon.
fn kindOf(cand: [2][]const u8) icon_cache.Kind {
    return if (std.mem.eql(u8, cand[1], "t")) .tray else .app;
}

/// Names that start the icon worker before any stream exists, so the theme
/// index is being built (cold start: ~130ms of directory walking, on the
/// worker) while the first rows are still arriving.
const icon_seeds = [_][]const u8{ "audio-headphones", "audio-card", "audio-speakers", "multimedia-player" };

fn rowHover(px: f64, py: f64, r: common.Rect) bool {
    return common.pointInRect(px, py, r);
}

fn blitIcon(c: *cairo.cairo_t, icon: *const icon_cache.Owned, x: f64, y: f64, size: f64) void {    if (icon.pixels.len == 0 or icon.w <= 0 or icon.h <= 0) return;
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

// ── paint ───────────────────────────────────────────────────────────────────

fn paintRail(self: *Win, c: *cairo.cairo_t) void {
    const cx = @as(f64, @floatFromInt(rail_btn_x + @divTrunc(rail_btn_w, 2)));
    // Flush column, darker than the page like the settings rail.
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.20);
    cairo.cairo_rectangle(c, 0, 0, @floatFromInt(rail_w), @floatFromInt(self.win_h));
    cairo.cairo_fill(c);
    cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, 0.08);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_move_to(c, @as(f64, @floatFromInt(rail_w)) + 0.5, 0);
    cairo.cairo_line_to(c, @as(f64, @floatFromInt(rail_w)) + 0.5, @floatFromInt(self.win_h));
    cairo.cairo_stroke(c);

    for (pages, 0..) |p, i| {
        const r = railBtnRect(i);
        const selected = self.page == p;
        if (selected) {
            ui_paint.glassBox(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 14, Theme.acc_r, Theme.acc_g, Theme.acc_b, 0.20);
        } else if (rowHover(self.ptr_x, self.ptr_y, r)) {
            ui_paint.glassBox(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 14, Theme.text_r, Theme.text_g, Theme.text_b, 0.07);
        }
        const tint_a: f64 = if (selected) 1.0 else 0.62;
        const tr: f64 = if (selected) Theme.acc_r else Theme.text_r;
        const tg: f64 = if (selected) Theme.acc_g else Theme.text_g;
        const tb: f64 = if (selected) Theme.acc_b else Theme.text_b;
        ui_paint.glyph(c, cx, @as(f64, @floatFromInt(r.y)) + 22, 22, p.glyph(), tr, tg, tb, tint_a);
        const lbl = p.railLabel();
        const lw: f64 = @floatFromInt(ui_paint.textWidthPx(c, lbl, 11, 400));
        ui_paint.showText(c, cx - lw / 2.0, @as(f64, @floatFromInt(r.y)) + 48, lbl, 11, 400, tr, tg, tb, if (selected) 1.0 else 0.55);
    }
}

/// One header toggle: label + switch, right-aligned. Returns the rect the
/// click test uses (so paint and hit test can never disagree about layout).
fn paintHeaderToggle(c: *cairo.cairo_t, right_x: i32, label: []const u8, on: bool) common.Rect {
    const sw: i32 = 44;
    const sh: i32 = 24;
    const gap: i32 = 8;
    const pill_y: i32 = 62;
    const ts = ui_paint.textSizePx(c, label, 12, 500);
    const lw: i32 = ts.w;
    const total = lw + gap + sw;
    const x0 = right_x - total;
    // Center the label on the switch, the way paintBtn centers a button
    // label: showText pins the layout top at (y - ph + 2), so the ink sits
    // mid-pill only when y is derived from the measured layout height.
    // Hardcoding y parked the text ~6px above the pill.
    const th_f: f64 = @floatFromInt(ts.h);
    const ltop = @as(f64, @floatFromInt(pill_y)) + (@as(f64, @floatFromInt(sh)) - th_f) / 2.0;
    ui_paint.showText(
        c,
        @floatFromInt(x0),
        ltop + th_f - 2.0,
        label,
        12,
        500,
        Theme.text_r,
        Theme.text_g,
        Theme.text_b,
        0.80,
    );
    ui_paint.paintSwitch(c, x0 + lw + gap, pill_y, sw, sh, on);
    return .{ .x = x0 - 6, .y = 56, .w = total + 12, .h = sh + 12 };
}

fn paintHeader(self: *Win, c: *cairo.cairo_t) void {
    ui_paint.catLabel(c, @floatFromInt(content_x), 46, "AUDIO");
    ui_paint.showText(
        c,
        @floatFromInt(content_x),
        80,
        self.page.title(),
        22,
        600,
        Theme.text_r,
        Theme.text_g,
        Theme.text_b,
        0.95,
    );
    // Right-side options: page-specific filter, then the meters toggle. The
    // click rects are stored on the way past so hit tests reuse exactly what
    // the frame drew.
    if (self.page == .engine) {
        var cap_buf: [160]u8 = undefined;
        const cap = self.engineHardwareCaption(&cap_buf);
        const right = self.win_w - content_pad_r - 250;
        const width = ui_paint.measureTextWidth(cap, 11, 500);
        const x = @max(content_x + 280, right - width);
        if (right > x) {
            ui_paint.showTextW(
                c,
                @floatFromInt(x),
                58,
                cap,
                11,
                500,
                @floatFromInt(right - x),
                Theme.text_r,
                Theme.text_g,
                Theme.text_b,
                0.45,
            );
        }
    }
    const mx = self.win_w - content_pad_r - 10;
    self.hit_engine_refresh = null;
    if (self.page == .engine) {
        // No meters on this page: offer the manual re-read the settings app
        // has instead of a toggle that does nothing.
        self.hit_meters = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const bw: i32 = 104;
        const bh: i32 = 32;
        const bx = mx - bw;
        ui_paint.paintBtn(c, bx, 58, bw, bh, "Refresh", false);
        self.hit_engine_refresh = .{ .x = bx, .y = 58, .w = bw, .h = bh };
    } else {
        self.hit_meters = paintHeaderToggle(c, mx, "Meters", self.show_meters);
    }
    self.hit_page_toggle = null;
    switch (self.page) {
        .recording => self.hit_page_toggle = paintHeaderToggle(c, self.hit_meters.x - 20, "All streams", self.all_streams),
        .output, .input => self.hit_page_toggle = paintHeaderToggle(c, self.hit_meters.x - 20, "Hardware only", self.hw_only),
        else => {},
    }
}

fn paintCards(self: *Win, c: *cairo.cairo_t) void {
    const band_y0: f64 = @floatFromInt(header_h - 6);
    const band_y1: f64 = @floatFromInt(self.win_h - band_pad_b + 8);
    cairo.cairo_save(c);
    cairo.cairo_rectangle(
        c,
        @floatFromInt(rail_w),
        band_y0,
        @floatFromInt(self.win_w - rail_w),
        band_y1 - band_y0,
    );
    cairo.cairo_clip(c);

    const n = self.rowCount();
    if (n == 0) {
        const msg = switch (self.page) {
            .playback => "No applications are playing audio",
            .recording => "No applications are recording audio",
            .output => "No output devices",
            .input => "No input devices",
            .configuration => "No audio cards",
            .engine => "Engine settings",
        };
        ui_paint.showText(c, @floatFromInt(content_x + 4), 160, msg, 14, 400, Theme.text_r, Theme.text_g, Theme.text_b, 0.45);
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = self.cardRect(i);
        if (r.y + r.h < header_h - 6 or r.y > self.win_h - band_pad_b + 8) continue;
        switch (self.page) {
            .configuration => {
                const dev = self.deviceAt(i) orelse continue;
                self.paintConfigCard(c, r, dev);
            },
            .engine => self.paintEngineCard(c, r, i),
            else => {
                const node = self.nodeAt(i) orelse continue;
                if (self.page == .output or self.page == .input) {
                    self.paintDeviceCard(c, r, node);
                } else {
                    self.paintStreamCard(c, r, node);
                }
            },
        }
    }
    cairo.cairo_restore(c);
}

fn streamComboLabel(self: *Win, node: *const Node) []const u8 {
    if (self.page == .playback) {
        if (self.graph.sinkForStream(node.id)) |sid| {
            if (self.graph.findNode(sid)) |sink| return sink.displayName();
        }
    } else {
        if (self.graph.sourceForStream(node.id)) |sid| {
            if (self.graph.findNode(sid)) |src| return src.displayName();
        }
    }
    return "—";
}

fn streamSubLine(self: *Win, node: *const Node) []const u8 {
    const sub = node.streamSubtitle();
    if (sub.len > 0) return sub;
    return self.streamComboLabel(node);
}

fn paintStreamCard(self: *Win, c: *cairo.cairo_t, r: common.Rect, node: *const Node) void {
    var t = liveNowNs();
    self.paintCardBg(c, r);
    self.card_prof.bg += liveNowNs() - t;
    t = liveNowNs();
    const ir = iconRect(r);
    if (self.iconForNode(node)) |icon| {
        blitIcon(c, icon, @floatFromInt(ir.x), @floatFromInt(ir.y), @floatFromInt(icon_sz));
    } else {
        ui_paint.glyph(c, @floatFromInt(ir.x + @divTrunc(ir.w, 2)), @floatFromInt(ir.y + @divTrunc(ir.h, 2)), 24, "music_note", Theme.text_r, Theme.text_g, Theme.text_b, 0.45);
    }
    const title = node.streamTitle();
    ui_paint.showTextW(c, @floatFromInt(r.x + 72), @floatFromInt(r.y + 34), title, 15, 500, @floatFromInt(r.w - 72 - 300), Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
    ui_paint.showTextW(c, @floatFromInt(r.x + 72), @floatFromInt(r.y + 54), self.streamSubLine(node), 11, 400, @floatFromInt(r.w - 72 - 300), Theme.text_r, Theme.text_g, Theme.text_b, 0.50);
    self.card_prof.text += liveNowNs() - t;

    t = liveNowNs();
    // Move combo + terminate.
    const cr_ = moveComboRect(r);
    const open = self.dd.open and self.dd_state.kind == .move and self.dd_state.id == node.id;
    paintCombo(c, r, cr_, self.streamComboLabel(node), open);
    const xr = closeBtnRect(r);
    const xhov = rowHover(self.ptr_x, self.ptr_y, xr);
    ui_paint.roundRect(c, @floatFromInt(xr.x), @floatFromInt(xr.y), @floatFromInt(xr.w), @floatFromInt(xr.h), 8);
    cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, if (xhov) 0.14 else 0.06);
    cairo.cairo_fill(c);
    ui_paint.glyph(c, @floatFromInt(xr.x + @divTrunc(xr.w, 2)), @floatFromInt(xr.y + @divTrunc(xr.h, 2)), 15, "close", Theme.text_r, Theme.text_g, Theme.text_b, if (xhov) 0.95 else 0.60);
    self.card_prof.ctrl += liveNowNs() - t;

    t = liveNowNs();
    self.paintVolumeRow(c, r, node, false);
    self.card_prof.vol += liveNowNs() - t;
}

fn isDefaultNode(self: *Win, node: *const Node) bool {
    if (node.role == .sink) {
        const want = self.graph.default_sink.get();
        return want.len > 0 and std.mem.eql(u8, want, node.node_name.get());
    }
    const want = self.graph.default_source.get();
    return want.len > 0 and std.mem.eql(u8, want, node.node_name.get());
}

/// The visible port routes for a hardware row, in graph order (the same
/// filter pipewire-pulse applies before showing a sink's ports).
fn portRouteAt(self: *Win, node: *const Node, dir: u32, i: usize) ?*const Route {
    const dev = self.deviceFor(node) orelse return null;
    var n: usize = 0;
    for (dev.routes.items) |*route| {
        if (!route.visibleFor(dir, dev.active_profile, node.card_profile_device)) continue;
        if (n == i) return route;
        n += 1;
    }
    return null;
}

fn portCount(self: *Win, node: *const Node, dir: u32) usize {
    var n: usize = 0;
    while (self.portRouteAt(node, dir, n) != null) n += 1;
    return n;
}

fn portLabel(self: *Win, node: *const Node, dir: u32) []const u8 {
    const dev = self.deviceFor(node) orelse return "";
    const active = dev.activeRouteFor(dir);
    if (active.index < 0) return "";
    if (dev.findRoute(active.index, dir)) |route| return route.label();
    return "";
}

/// Freedesktop device-icon names → the Material glyphs this app ships, for
/// themes that do not carry the ALSA/BlueZ names (`pavucontrol` leans on the
/// GTK theme here; this keeps a real icon on screen when the theme is thin).
fn glyphForDevice(icon_name: []const u8, desc: []const u8, role: graph_mod.Role) []const u8 {
    const table = [_]struct { needle: []const u8, glyph: []const u8 }{
        .{ .needle = "microphone", .glyph = "mic" },
        .{ .needle = "headset", .glyph = "headset_mic" },
        .{ .needle = "headphone", .glyph = "headset_mic" },
        .{ .needle = "speaker", .glyph = "speaker" },
        .{ .needle = "bluetooth", .glyph = "bluetooth" },
        .{ .needle = "hdmi", .glyph = "monitor" },
        .{ .needle = "display", .glyph = "monitor" },
        .{ .needle = "gamepad", .glyph = "gamepad" },
        .{ .needle = "phone", .glyph = "smartphone" },
    };
    for (table) |e| {
        if (std.mem.indexOf(u8, icon_name, e.needle) != null) return e.glyph;
    }
    // ALSA cards ship no icon name for their HDMI outputs: the description is
    // the only telling signal, and a display glyph reads truer than a speaker
    // box for "…Digital Stereo (HDMI) [MAG 272Q X24]".
    if (role == .sink and desc.len > 0) {
        if (std.ascii.findIgnoreCase(desc, "hdmi") != null) return "monitor";
        if (std.ascii.findIgnoreCase(desc, "displayport") != null) return "monitor";
    }
    return if (role == .sink) "speaker" else "mic";
}

fn paintDeviceCard(self: *Win, c: *cairo.cairo_t, r: common.Rect, node: *const Node) void {
    var t = liveNowNs();
    self.paintCardBg(c, r);
    self.card_prof.bg += liveNowNs() - t;
    t = liveNowNs();
    const ir = iconRect(r);
    // Device rows wear the app's own glyph family, never the icon theme's
    // art: themes ship these entries as macOS-style filled app tiles (a white
    // rounded plate) or photorealistic renders, which read as stickers next
    // to the monochrome grid. The glyph is picked from the device's
    // Freedesktop icon name, so a headset still reads as a headset.
    const dev = self.deviceFor(node);
    const icon_name: []const u8 = blk: {
        if (dev) |d| {
            if (d.icon.get().len > 0) break :blk d.icon.get();
        }
        if (node.device_icon.get().len > 0) break :blk node.device_icon.get();
        break :blk "";
    };
    const desc: []const u8 = if (dev) |d| d.desc.get() else "";
    ui_paint.glyph(c, @floatFromInt(ir.x + @divTrunc(ir.w, 2)), @floatFromInt(ir.y + @divTrunc(ir.h, 2)), 26, glyphForDevice(icon_name, desc, node.role), Theme.text_r, Theme.text_g, Theme.text_b, 0.62);
    self.card_prof.icon += liveNowNs() - t;

    t = liveNowNs();
    ui_paint.showTextW(c, @floatFromInt(r.x + 72), @floatFromInt(r.y + 34), node.displayName(), 15, 500, @floatFromInt(r.w - 72 - 400), Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
    ui_paint.showTextW(c, @floatFromInt(r.x + 72), @floatFromInt(r.y + 54), node.node_name.get(), 11, 400, @floatFromInt(r.w - 72 - 400), Theme.text_r, Theme.text_g, Theme.text_b, 0.50);
    self.card_prof.text += liveNowNs() - t;

    t = liveNowNs();
    const dir: u32 = if (node.role == .sink) 1 else 0;
    if (self.portCount(node, dir) > 0) {
        const pr = portComboRect(r);
        const open = self.dd.open and self.dd_state.kind == .port and self.dd_state.id == node.id;
        paintCombo(c, r, pr, self.portLabel(node, dir), open);
    }
    // Set as default.
    const br = defaultBtnRect(r);
    const is_def = self.isDefaultNode(node);
    const bhov = rowHover(self.ptr_x, self.ptr_y, br);
    ui_paint.paintBtn(c, br.x, br.y, br.w, br.h, if (is_def) "Default" else "Set default", bhov and !is_def);
    if (is_def) {
        ui_paint.glyph(c, @floatFromInt(br.x + 16), @floatFromInt(br.y + @divTrunc(br.h, 2)), 14, "check", Theme.acc_r, Theme.acc_g, Theme.acc_b, 0.95);
    }
    self.card_prof.ctrl += liveNowNs() - t;

    t = liveNowNs();
    self.paintVolumeRow(c, r, node, false);
    self.card_prof.vol += liveNowNs() - t;
}

// ── engine page ─────────────────────────────────────────────────────────────

fn engineRow(row: usize) EngineRow {
    return @enumFromInt(@as(u32, @intCast(row)));
}

fn engineRowValueCount(self: *Win, row: u32) usize {
    if (row >= engine_row_count) return 0;
    return switch (engineRow(@intCast(row))) {
        .clock_rate => blk: {
            var buf: [24]i32 = undefined;
            break :blk 1 + self.engineMenuRatesFor(&buf).len;
        },
        .force_rate => blk: {
            var buf: [24]i32 = undefined;
            break :blk 2 + self.engineMenuRatesFor(&buf).len;
        },
        .allowed_rates => 4,
        .pcm => 4,
        .latency_node => self.latencyNodeCount(),
        .quantum, .force_quantum => blk: {
            var buf: [24]i32 = undefined;
            break :blk 2 + self.engineMenuQuantumsFor(&buf).len;
        },
        else => 0,
    };
}

fn engineAppendSorted(out: *[24]i32, n: *usize, v: i32) void {
    if (v <= 0 or n.* >= out.len) return;
    var i: usize = 0;
    while (i < n.*) : (i += 1) {
        if (out[i] == v) return;
        if (out[i] > v) break;
    }
    var j = n.*;
    while (j > i) : (j -= 1) out[j] = out[j - 1];
    out[i] = v;
    n.* += 1;
}

/// Rates offered by the two rate combos: the live allowed list plus the
/// common set, trimmed to the selected sink's advertised range when known.
fn engineMenuRates(out: *[24]i32) []const i32 {
    var n: usize = 0;
    for (engine_rates) |hz| engineAppendSorted(out, &n, hz);
    return out[0..n];
}

fn engineMenuRatesFor(self: *Win, out: *[24]i32) []const i32 {
    const lo: i32 = if (self.caps.available and self.caps.rate_min > 0) self.caps.rate_min else 1;
    const hi: i32 = if (self.caps.available and self.caps.rate_max > 0) self.caps.rate_max else std.math.maxInt(i32);
    var n: usize = 0;
    for (engine_rates) |hz| {
        if (hz >= lo and hz <= hi) engineAppendSorted(out, &n, hz);
    }
    for (self.es.allowed_rates_hz) |hz| engineAppendSorted(out, &n, hz);
    engineAppendSorted(out, &n, self.es.clock_rate_hz);
    engineAppendSorted(out, &n, self.es.clock_force_rate_hz);
    engineAppendSorted(out, &n, self.caps.rate_min);
    engineAppendSorted(out, &n, self.caps.rate_max);
    engineAppendSorted(out, &n, self.caps.rate_default);
    if (n == 0) {
        for (engine_rates) |hz| engineAppendSorted(out, &n, hz);
    }
    return out[0..n];
}

fn engineMenuQuantums(out: *[24]i32) []const i32 {
    var n: usize = 0;
    for (engine_quantums) |q| engineAppendSorted(out, &n, q);
    return out[0..n];
}

fn engineMenuQuantumsFor(self: *Win, out: *[24]i32) []const i32 {
    const limit: i32 = if (self.caps.available) self.caps.quantum_limit else 0;
    var n: usize = 0;
    for (engine_quantums) |q| {
        if (limit <= 0 or q <= limit) engineAppendSorted(out, &n, q);
    }
    if (limit <= 0 or self.es.clock_quantum <= limit) engineAppendSorted(out, &n, self.es.clock_quantum);
    if (limit <= 0 or self.es.clock_force_quantum <= limit) engineAppendSorted(out, &n, self.es.clock_force_quantum);
    if (n == 0) {
        for (engine_quantums) |q| engineAppendSorted(out, &n, q);
    }
    return out[0..n];
}

fn engineRateIndex(self: *Win, hz: i32) i32 {
    var buf: [24]i32 = undefined;
    const rates = self.engineMenuRatesFor(&buf);
    for (rates, 0..) |v, k| {
        if (v == hz) return @intCast(k);
    }
    return -1;
}

fn engineQuantumIndex(self: *Win, q: i32) i32 {
    var buf: [24]i32 = undefined;
    const qs = self.engineMenuQuantumsFor(&buf);
    for (qs, 0..) |v, k| {
        if (v == q) return @intCast(k);
    }
    return -1;
}

fn enginePresetRates(i: usize) ?[]const i32 {
    return switch (i) {
        0 => &engine_preset_hifi,
        1 => &engine_preset_consumer,
        2 => &engine_preset_pro,
        else => null,
    };
}

fn enginePresetSel(es: *const live_audio.EngineSettings) i32 {
    var buf: [24]i32 = undefined;
    const n = @min(es.allowed_rates_hz.len, buf.len);
    @memcpy(buf[0..n], es.allowed_rates_hz[0..n]);
    std.mem.sort(i32, buf[0..n], {}, std.sort.asc(i32));
    const norm = buf[0..n];
    if (std.mem.eql(i32, norm, &engine_preset_hifi)) return 0;
    if (std.mem.eql(i32, norm, &engine_preset_consumer)) return 1;
    if (std.mem.eql(i32, norm, &engine_preset_pro)) return 2;
    if (norm.len == 1 and norm[0] == es.clock_rate_hz) return 3;
    return -1;
}

fn enginePresetLabel(sel: i32) []const u8 {
    return switch (sel) {
        0 => "Hi-Fi (44.1-192 kHz)",
        1 => "Consumer (44.1 / 48 kHz)",
        2 => "Pro (48 / 96 / 192 kHz)",
        3 => "Single (default rate only)",
        else => "Custom",
    };
}

fn enginePcmLabel(choice: i32) []const u8 {
    if (choice < 0 or choice >= engine_pcm_labels.len) return "(unknown)";
    return engine_pcm_labels[@intCast(choice)];
}

fn engineHzDisplay(buf: []u8, hz: i32) []const u8 {
    if (hz <= 0) return std.fmt.bufPrint(buf, "{d}", .{hz}) catch "?";
    const k = @divTrunc(hz, 1000);
    const frac = @rem(hz, 1000);
    if (frac == 0) return std.fmt.bufPrint(buf, "{d} kHz", .{k}) catch "?";
    return std.fmt.bufPrint(buf, "{d}.{d} kHz", .{ k, @divTrunc(frac, 100) }) catch "?";
}

fn engineSame(a: *const live_audio.EngineSettings, b: *const live_audio.EngineSettings) bool {
    if (a.available != b.available) return false;
    if (a.clock_rate_hz != b.clock_rate_hz) return false;
    if (a.clock_force_rate_hz != b.clock_force_rate_hz) return false;
    if (a.clock_quantum != b.clock_quantum) return false;
    if (a.clock_force_quantum != b.clock_force_quantum) return false;
    return std.mem.eql(i32, a.allowed_rates_hz, b.allowed_rates_hz);
}

fn engineRowTitle(row: usize) []const u8 {
    return switch (engineRow(row)) {
        .clock_rate => "Default clock rate",
        .force_rate => "Force graph rate",
        .allowed_rates => "Allowed rates",
        .pcm => "Default PCM format",
        .quantum => "Default quantum",
        .force_quantum => "Force quantum",
        .status => "Live engine",
        .latency_node => "Latency offset node",
        .latency_offset => "Latency offset",
        .restart_wp => "Restart WirePlumber",
        .restart_pw => "Restart PipeWire",
    };
}

fn engineRowHint(row: usize) []const u8 {
    return switch (engineRow(row)) {
        .clock_rate => "The graph rate PipeWire settles on",
        .force_rate => "Pin the graph instead of following streams",
        .allowed_rates => "Rates the graph may switch between",
        .pcm => "Pin the default sink's sample format",
        .quantum => "Buffer size in frames (lower = less latency)",
        .force_quantum => "Pin the buffer size instead of adapting",
        .status => "Latency, xruns (click to reset) and DSP load",
        .latency_node => "Output or input that accepts a processing offset",
        .latency_offset => "Stored on the node as an offset",
        .restart_wp => "Reload device and session policy",
        .restart_pw => "Restarts the graph; every client reconnects",
    };
}

fn engineRowItemLabel(self: *Win, row: usize, i: usize) []const u8 {
    switch (engineRow(row)) {
        .clock_rate => {
            var buf: [24]i32 = undefined;
            const rates = self.engineMenuRatesFor(&buf);
            if (i == rates.len) return "Custom rate…";
            if (i > rates.len) return "";
            return engineHzDisplay(&self.engine_label_buf, rates[i]);
        },
        .force_rate => {
            if (i == 0) return "Auto";
            var buf: [24]i32 = undefined;
            const rates = self.engineMenuRatesFor(&buf);
            if (i - 1 == rates.len) return "Custom rate…";
            if (i - 1 > rates.len) return "";
            return engineHzDisplay(&self.engine_label_buf, rates[i - 1]);
        },
        .allowed_rates => return enginePresetLabel(@intCast(i)),
        .pcm => return enginePcmLabel(@intCast(i)),
        .quantum, .force_quantum => {
            if (i == 0) return if (engineRow(row) == .quantum) "Auto (default)" else "Auto";
            var buf: [24]i32 = undefined;
            const qs = self.engineMenuQuantumsFor(&buf);
            if (i - 1 == qs.len) return "Custom quantum…";
            if (i - 1 > qs.len) return "";
            return std.fmt.bufPrint(&self.engine_label_buf, "{d} frames", .{qs[i - 1]}) catch "?";
        },
        .latency_node => {
            const node = self.latencyNodeAt(i) orelse return "";
            return node.displayName();
        },
        else => return "",
    }
}

fn engineRowValue(self: *Win, row: usize, buf: []u8) []const u8 {
    return switch (engineRow(row)) {
        .clock_rate => if (!self.engine_loaded) "Reading…" else if (!self.es.available) "Unavailable" else engineHzDisplay(buf, self.es.clock_rate_hz),
        .force_rate => if (!self.engine_loaded) "Reading…" else if (!self.es.available) "Unavailable" else if (self.es.clock_force_rate_hz == 0) "Auto" else engineHzDisplay(buf, self.es.clock_force_rate_hz),
        .allowed_rates => if (!self.engine_loaded) "Reading…" else if (!self.es.available) "Unavailable" else enginePresetLabel(enginePresetSel(&self.es)),
        .pcm => if (!self.have_pcm) "Reading…" else if (self.pcm_choice < 0) "(unknown)" else enginePcmLabel(self.pcm_choice),
        .quantum => if (!self.engine_loaded) "Reading…" else if (!self.es.available) "Unavailable" else if (self.es.clock_quantum == 0) "Auto (default)" else std.fmt.bufPrint(buf, "{d} frames", .{self.es.clock_quantum}) catch "?",
        .force_quantum => if (!self.engine_loaded) "Reading…" else if (!self.es.available) "Unavailable" else if (self.es.clock_force_quantum == 0) "Auto" else std.fmt.bufPrint(buf, "{d} frames", .{self.es.clock_force_quantum}) catch "?",
        .latency_node => self.latencyNodeLabel(),
        else => "",
    };
}

fn engineRowSel(self: *Win, row: usize) i32 {
    if (row >= engine_row_count) return -1;
    return switch (engineRow(row)) {
        .clock_rate => if (!self.es.available) -1 else self.engineRateIndex(self.es.clock_rate_hz),
        .force_rate => if (!self.es.available) -1 else if (self.es.clock_force_rate_hz == 0) 0 else blk: {
            const k = self.engineRateIndex(self.es.clock_force_rate_hz);
            break :blk if (k < 0) -1 else k + 1;
        },
        .allowed_rates => if (!self.es.available) -1 else enginePresetSel(&self.es),
        .pcm => self.pcm_choice,
        .quantum => if (!self.es.available) -1 else if (self.es.clock_quantum == 0) 0 else blk: {
            const k = self.engineQuantumIndex(self.es.clock_quantum);
            break :blk if (k < 0) -1 else k + 1;
        },
        .force_quantum => if (!self.es.available) -1 else if (self.es.clock_force_quantum == 0) 0 else blk: {
            const k = self.engineQuantumIndex(self.es.clock_force_quantum);
            break :blk if (k < 0) -1 else k + 1;
        },
        .latency_node => self.lat_node,
        else => -1,
    };
}

fn applyEngineRow(self: *Win, row: usize, i: usize) void {
    if (row >= engine_row_count) return;
    var rb: [24]i32 = undefined;
    var qb: [24]i32 = undefined;
    var ok = false;
    switch (engineRow(row)) {
        .clock_rate => {
            const rates = self.engineMenuRatesFor(&rb);
            if (i < rates.len) {
                ok = live_audio.applyEngineClockRateHz(self.io, rates[i]);
            } else if (i == rates.len) {
                self.openEngineModal(.rate, false);
                return;
            }
        },
        .force_rate => {
            if (i == 0) {
                ok = live_audio.applyEngineForceRateHz(self.io, 0);
            } else {
                const rates = self.engineMenuRatesFor(&rb);
                if (i - 1 < rates.len) {
                    ok = live_audio.applyEngineForceRateHz(self.io, rates[i - 1]);
                } else if (i - 1 == rates.len) {
                    self.openEngineModal(.rate, true);
                    return;
                }
            }
        },
        .allowed_rates => {
            if (i == 3) {
                ok = live_audio.applyEngineAllowedRatesHz(self.io, &.{self.es.clock_rate_hz});
            } else if (enginePresetRates(i)) |rates| {
                ok = live_audio.applyEngineAllowedRatesHz(self.io, rates);
            }
        },
        .pcm => {
            if (i < engine_pcm_labels.len) {
                ok = live_audio.applyCompatPcm(self.gpa, self.io, @intCast(i));
                if (ok) {
                    self.pcm_choice = @intCast(i);
                    self.have_pcm = true;
                }
            }
        },
        .quantum => {
            if (i == 0) {
                ok = live_audio.applyEngineQuantum(self.io, 0);
            } else {
                const qs = self.engineMenuQuantumsFor(&qb);
                if (i - 1 < qs.len) {
                    ok = live_audio.applyEngineQuantum(self.io, qs[i - 1]);
                } else if (i - 1 == qs.len) {
                    self.openEngineModal(.quantum, false);
                    return;
                }
            }
        },
        .force_quantum => {
            if (i == 0) {
                ok = live_audio.applyEngineForceQuantum(self.io, 0);
            } else {
                const qs = self.engineMenuQuantumsFor(&qb);
                if (i - 1 < qs.len) {
                    ok = live_audio.applyEngineForceQuantum(self.io, qs[i - 1]);
                } else if (i - 1 == qs.len) {
                    self.openEngineModal(.quantum, true);
                    return;
                }
            }
        },
        .latency_node => {
            if (i < self.latencyNodeCount()) {
                self.lat_node = @intCast(i);
                self.loadLatencyField();
                self.needs_repaint = true;
            }
            return;
        },
        else => {},
    }
    if (!ok) logz.err("engine: write failed row={d} item={d}", .{ row, i });
    if (ok) {
        self.refreshEngine(true);
        self.damageAll();
        self.needs_repaint = true;
    }
}

// Engine row geometry. The list rows all use `card_h_config`.

fn engineModalRect(win_w: i32, win_h: i32) common.Rect {
    var w: i32 = win_w - 80;
    if (w > 440) w = 440;
    if (w < 320) w = 320;
    const h: i32 = 208;
    return .{ .x = @divTrunc(win_w - w, 2), .y = @divTrunc(win_h - h, 2), .w = w, .h = h };
}

fn engineModalFieldRect(r: common.Rect) common.Rect {
    return .{ .x = r.x + 20, .y = r.y + 76, .w = r.w - 40, .h = combo_h };
}

fn engineModalCancelRect(r: common.Rect) common.Rect {
    return .{ .x = r.x + r.w - 20 - 100 - 8 - 100, .y = r.y + r.h - 20 - combo_h, .w = 100, .h = combo_h };
}

fn engineModalSubmitRect(r: common.Rect) common.Rect {
    return .{ .x = r.x + r.w - 20 - 100, .y = r.y + r.h - 20 - combo_h, .w = 100, .h = combo_h };
}

fn engineStatusColW(r: common.Rect) i32 {
    return @divTrunc(r.w - 56 - card_pad, 3);
}

fn engineXrunResetRect(r: common.Rect) common.Rect {
    const cw = engineStatusColW(r);
    return .{ .x = r.x + 56 + cw + cw - 30, .y = r.y + 16, .w = 20, .h = 20 };
}

fn engineXrunHitRect(r: common.Rect) common.Rect {
    const cw = engineStatusColW(r);
    return .{ .x = r.x + 56 + cw, .y = r.y, .w = cw, .h = r.h };
}

fn engineLatFieldRect(r: common.Rect) common.Rect {
    const w: i32 = 84;
    const h: i32 = combo_h;
    const y = r.y + @divTrunc(r.h - h, 2);
    const x = engineLatResetRect(r).x - 8 - 118 - 8 - 104 - 8 - w;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

fn engineLatUnitRect(r: common.Rect) common.Rect {
    const f = engineLatFieldRect(r);
    return .{ .x = f.x + f.w + 8, .y = f.y, .w = 104, .h = f.h };
}

fn engineLatApplyRect(r: common.Rect) common.Rect {
    const u = engineLatUnitRect(r);
    return .{ .x = u.x + u.w + 8, .y = u.y, .w = 118, .h = u.h };
}

fn engineLatResetRect(r: common.Rect) common.Rect {
    return .{ .x = r.x + r.w - card_pad - 128, .y = r.y + @divTrunc(r.h - combo_h, 2), .w = 128, .h = combo_h };
}

fn engineRestartBtnRect(r: common.Rect) common.Rect {
    return .{ .x = r.x + r.w - card_pad - 120, .y = r.y + @divTrunc(r.h - combo_h, 2), .w = 120, .h = combo_h };
}

fn paintEngineTextField(c: *cairo.cairo_t, r: common.Rect, value: []const u8, focused: bool, placeholder: []const u8) void {
    ui_paint.roundRect(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 8);
    cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, if (focused) 0.10 else 0.06);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_line_width(c, 1.0);
    if (focused) {
        cairo.cairo_set_source_rgba(c, Theme.acc_r, Theme.acc_g, Theme.acc_b, 0.9);
    } else {
        cairo.cairo_set_source_rgba(c, Theme.outline_r, Theme.outline_g, Theme.outline_b, 0.45);
    }
    cairo.cairo_stroke(c);
    const shown = if (value.len > 0) value else placeholder;
    ui_paint.showTextW(
        c,
        @floatFromInt(r.x + 10),
        @floatFromInt(r.y + 19),
        shown,
        12,
        500,
        @floatFromInt(@max(0, r.w - 18)),
        Theme.text_r,
        Theme.text_g,
        Theme.text_b,
        if (value.len > 0) 0.92 else 0.38,
    );
}

/// Width of the "frames" segment in the latency unit toggle. The control is a
/// fixed 104 px; the split follows the measured label so both words keep the
/// same breathing room instead of an equal 50/50 split cramming "frames".
fn paintEngineUnitToggle(self: *Win, c: *cairo.cairo_t, r: common.Rect, use_ns: bool) void {
    // Size each segment to its label plus padding, then share the leftover
    // width equally. Measuring keeps the padding symmetric whatever the font
    // renders "frames" as.
    const pad: i32 = 12;
    const lw = ui_paint.measureTextWidth("frames", 11, 600);
    const nw = ui_paint.measureTextWidth("ns", 11, 600);
    var split = lw + 2 * pad + @divTrunc(@max(0, r.w - (lw + nw + 4 * pad)), 2);
    if (split < 8 or split > r.w - 8) split = @divTrunc(r.w, 2);
    self.engine_unit_split = split;
    ui_paint.roundRect(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 8);
    cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, 0.06);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_set_source_rgba(c, Theme.outline_r, Theme.outline_g, Theme.outline_b, 0.45);
    cairo.cairo_stroke(c);

    const ax = if (use_ns) r.x + split else r.x;
    const aw = if (use_ns) r.w - split else split;
    ui_paint.roundRect(c, @floatFromInt(ax + 2), @floatFromInt(r.y + 2), @floatFromInt(aw - 4), @floatFromInt(r.h - 4), 6);
    cairo.cairo_set_source_rgba(c, Theme.acc_r, Theme.acc_g, Theme.acc_b, 0.20);
    cairo.cairo_fill(c);

    cairo.cairo_set_source_rgba(c, Theme.outline_r, Theme.outline_g, Theme.outline_b, 0.28);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_move_to(c, @floatFromInt(r.x + split), @floatFromInt(r.y + 6));
    cairo.cairo_line_to(c, @floatFromInt(r.x + split), @floatFromInt(r.y + r.h - 6));
    cairo.cairo_stroke(c);

    const labels = [_][]const u8{ "frames", "ns" };
    for (labels, 0..) |lab, i| {
        const active = (i == 1) == use_ns;
        const center = if (i == 0)
            r.x + @divTrunc(split, 2)
        else
            r.x + split + @divTrunc(r.w - split, 2);
        ui_paint.showText(
            c,
            @floatFromInt(center - @divTrunc(ui_paint.measureTextWidth(lab, 11, 600), 2)),
            @floatFromInt(r.y + 19),
            lab,
            11,
            600,
            if (active) Theme.acc_r else Theme.text_r,
            if (active) Theme.acc_g else Theme.text_g,
            if (active) Theme.acc_b else Theme.text_b,
            if (active) 1.0 else 0.62,
        );
    }
}

fn paintEngineStatus(self: *Win, c: *cairo.cairo_t, r: common.Rect) void {
    const cw = engineStatusColW(r);
    const x0 = r.x + 56;
    ui_paint.glyph(c, @floatFromInt(r.x + card_pad + 18), @floatFromInt(r.y + @divTrunc(r.h, 2)), 24, "timer", Theme.text_r, Theme.text_g, Theme.text_b, 0.62);

    // Column separators.
    var k: i32 = 1;
    while (k < 3) : (k += 1) {
        cairo.cairo_set_source_rgba(c, Theme.outline_r, Theme.outline_g, Theme.outline_b, 0.22);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_move_to(c, @floatFromInt(x0 + k * cw), @floatFromInt(r.y + 12));
        cairo.cairo_line_to(c, @floatFromInt(x0 + k * cw), @floatFromInt(r.y + r.h - 12));
        cairo.cairo_stroke(c);
    }

    var lat_buf: [32]u8 = undefined;
    const lat = self.engineLatencyDisplay(&lat_buf);
    ui_paint.showText(c, @floatFromInt(x0 + 14), @floatFromInt(r.y + 24), "LATENCY", 9, 600, Theme.text_r, Theme.text_g, Theme.text_b, 0.45);
    ui_paint.showText(c, @floatFromInt(x0 + 14), @floatFromInt(r.y + 48), lat, 15, 600, Theme.text_r, Theme.text_g, Theme.text_b, 0.95);

    const xr: i64 = @max(@as(i64, 0), self.top.xruns_total - self.xrun_base);
    var xr_buf: [24]u8 = undefined;
    const xr_s = if (!self.top.available) "—" else std.fmt.bufPrint(&xr_buf, "{d}", .{xr}) catch "0";
    ui_paint.showText(c, @floatFromInt(x0 + cw + 14), @floatFromInt(r.y + 24), "XRUNS", 9, 600, Theme.text_r, Theme.text_g, Theme.text_b, 0.45);
    ui_paint.showText(c, @floatFromInt(x0 + cw + 14), @floatFromInt(r.y + 48), xr_s, 15, 600, Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
    if (self.top.available) {
        const rr = engineXrunResetRect(r);
        ui_paint.roundRect(c, @floatFromInt(rr.x), @floatFromInt(rr.y), @floatFromInt(rr.w), @floatFromInt(rr.h), 6);
        cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, 0.06);
        cairo.cairo_fill(c);
        ui_paint.glyph(c, @floatFromInt(rr.x + @divTrunc(rr.w, 2)), @floatFromInt(rr.y + @divTrunc(rr.h, 2)), 12, "restart_alt", Theme.text_r, Theme.text_g, Theme.text_b, 0.62);
    }

    var dsp_buf: [24]u8 = undefined;
    const dsp_s = if (!self.top.available)
        "—"
    else blk: {
        const pct = @max(0, @min(100, self.top.dsp_load_pct));
        // DSP load is often well under 1% for a desktop graph. Scale the
        // precision so the number actually moves instead of reading "0%".
        break :blk if (pct < 1)
            std.fmt.bufPrint(&dsp_buf, "{d:.2}%", .{pct}) catch "0%"
        else if (pct < 10)
            std.fmt.bufPrint(&dsp_buf, "{d:.1}%", .{pct}) catch "0%"
        else
            std.fmt.bufPrint(&dsp_buf, "{d:.0}%", .{pct}) catch "0%";
    };
    const dx = x0 + 2 * cw + 14;
    ui_paint.showText(c, @floatFromInt(dx), @floatFromInt(r.y + 24), "DSP LOAD", 9, 600, Theme.text_r, Theme.text_g, Theme.text_b, 0.45);
    ui_paint.showText(c, @floatFromInt(dx), @floatFromInt(r.y + 48), dsp_s, 15, 600, Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
    const my = r.y + r.h - 16;
    const mw = cw - 28;
    ui_paint.roundRect(c, @floatFromInt(dx), @floatFromInt(my), @floatFromInt(mw), 4, 2);
    cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, 0.10);
    cairo.cairo_fill(c);
    if (self.top.available and self.top.dsp_load_pct > 0) {
        const pct: f64 = @max(0, @min(100, self.top.dsp_load_pct));
        const fw: f64 = @as(f64, @floatFromInt(mw)) * pct / 100.0;
        ui_paint.roundRect(c, @floatFromInt(dx), @floatFromInt(my), fw, 4, 2);
        cairo.cairo_set_source_rgba(c, Theme.acc_r, Theme.acc_g, Theme.acc_b, 0.95);
        cairo.cairo_fill(c);
    }
}

/// Expected graph latency from the resolved quantum and rate.
fn engineLatencyDisplay(self: *Win, buf: []u8) []const u8 {
    // Prefer the sink's live pw-top row: it is the cycle the graph is actually
    // running, while `clock.quantum` is only the ceiling clients may ask for.
    const qn: i32 = if (self.top.focus_quantum > 0)
        self.top.focus_quantum
    else if (self.es.clock_force_quantum > 0)
        self.es.clock_force_quantum
    else if (self.es.clock_quantum > 0)
        self.es.clock_quantum
    else
        self.top.reference_quantum;
    const rate: i32 = if (self.top.focus_rate_hz > 0)
        self.top.focus_rate_hz
    else if (self.es.clock_force_rate_hz > 0)
        self.es.clock_force_rate_hz
    else if (self.es.clock_rate_hz > 0)
        self.es.clock_rate_hz
    else
        self.top.reference_rate_hz;
    if (qn <= 0 or rate <= 0) return "—";
    const ms = @as(f64, @floatFromInt(qn)) / @as(f64, @floatFromInt(rate)) * 1000.0;
    return std.fmt.bufPrint(buf, "{d:.2} ms", .{ms}) catch "—";
}

fn paintEngineLatencyRow(self: *Win, c: *cairo.cairo_t, r: common.Rect) void {
    ui_paint.glyph(c, @floatFromInt(r.x + card_pad + 18), @floatFromInt(r.y + @divTrunc(r.h, 2)), 24, "timer", Theme.text_r, Theme.text_g, Theme.text_b, 0.62);
    ui_paint.showTextW(c, @floatFromInt(r.x + 56), @floatFromInt(r.y + 30), engineRowTitle(8), 15, 500, @floatFromInt(r.w - 500), Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
    ui_paint.showTextW(c, @floatFromInt(r.x + 56), @floatFromInt(r.y + 50), engineRowHint(8), 11, 400, @floatFromInt(r.w - 500), Theme.text_r, Theme.text_g, Theme.text_b, 0.50);

    const has_node = self.latencyNode() != null;
    paintEngineTextField(c, engineLatFieldRect(r), self.lat_field[0..self.lat_len], self.lat_focus, "0");
    paintEngineUnitToggle(self, c, engineLatUnitRect(r), self.lat_ns);
    const ar = engineLatApplyRect(r);
    if (has_node) {
        ui_paint.paintBtn(c, ar.x, ar.y, ar.w, ar.h, "Apply", false);
    } else {
        ui_paint.paintBtnDisabled(c, ar.x, ar.y, ar.w, ar.h, "Apply");
    }
    const rr = engineLatResetRect(r);
    if (self.latencyNodeCount() > 0) {
        ui_paint.paintBtn(c, rr.x, rr.y, rr.w, rr.h, "Reset all", false);
    } else {
        ui_paint.paintBtnDisabled(c, rr.x, rr.y, rr.w, rr.h, "Reset all");
    }
}

fn paintEngineRestartRow(self: *Win, c: *cairo.cairo_t, r: common.Rect, row: usize) void {
    ui_paint.glyph(c, @floatFromInt(r.x + card_pad + 18), @floatFromInt(r.y + @divTrunc(r.h, 2)), 24, "restart_alt", Theme.text_r, Theme.text_g, Theme.text_b, 0.62);
    ui_paint.showTextW(c, @floatFromInt(r.x + 56), @floatFromInt(r.y + 30), engineRowTitle(row), 15, 500, @floatFromInt(r.w - 260), Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
    ui_paint.showTextW(c, @floatFromInt(r.x + 56), @floatFromInt(r.y + 50), engineRowHint(row), 11, 400, @floatFromInt(r.w - 260), Theme.text_r, Theme.text_g, Theme.text_b, 0.50);

    const now = liveNowNs();
    const is_wp = engineRow(row) == .restart_wp;
    const arm_ns = if (is_wp) self.restart_wp_arm_ns else self.restart_pw_arm_ns;
    const done_ns = if (is_wp) self.restart_wp_done_ns else self.restart_pw_done_ns;
    const armed = arm_ns != 0 and now - arm_ns <= engine_restart_arm_ns;
    const done = done_ns != 0 and now - done_ns <= engine_restart_done_ns;
    const br = engineRestartBtnRect(r);
    const label = if (done) "Restarted" else if (armed) "Confirm" else "Restart";
    ui_paint.paintBtn(c, br.x, br.y, br.w, br.h, label, false);
    if (done) {
        ui_paint.glyph(c, @floatFromInt(br.x + 22), @floatFromInt(br.y + @divTrunc(br.h, 2)), 15, "check", Theme.acc_r, Theme.acc_g, Theme.acc_b, 0.95);
    }
}

fn paintEngineModal(self: *Win, c: *cairo.cairo_t) void {
    if (self.emodal == .none) return;
    // Dim the page so the dialog reads as modal.
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.55);
    cairo.cairo_paint(c);

    const r = engineModalRect(self.win_w, self.win_h);
    ui_paint.roundRect(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 16);
    cairo.cairo_set_source_rgba(c, Theme.bg_r * 0.55, Theme.bg_g * 0.55, Theme.bg_b * 0.55, 0.99);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_set_source_rgba(c, Theme.outline_r, Theme.outline_g, Theme.outline_b, 0.45);
    cairo.cairo_stroke(c);

    const title = switch (self.emodal) {
        .rate => "Custom sample rate",
        .quantum => "Custom quantum",
        .none => "",
    };
    const hint = switch (self.emodal) {
        .rate => "Written to the graph through pw-metadata.",
        .quantum => "Frames per graph cycle; lower means less latency.",
        .none => "",
    };
    ui_paint.showText(c, @floatFromInt(r.x + 20), @floatFromInt(r.y + 34), title, 17, 600, Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
    ui_paint.showTextW(c, @floatFromInt(r.x + 20), @floatFromInt(r.y + 56), hint, 11, 400, @floatFromInt(r.w - 40), Theme.text_r, Theme.text_g, Theme.text_b, 0.55);

    const placeholder = switch (self.emodal) {
        .rate => "e.g. 48000",
        .quantum => "e.g. 1024",
        .none => "",
    };
    paintEngineTextField(c, engineModalFieldRect(r), self.emodal_buf[0..self.emodal_len], true, placeholder);
    const cr = engineModalCancelRect(r);
    ui_paint.paintBtn(c, cr.x, cr.y, cr.w, cr.h, "Cancel", false);
    const sr = engineModalSubmitRect(r);
    ui_paint.paintBtn(c, sr.x, sr.y, sr.w, sr.h, "Apply", false);
}

fn paintEngineCard(self: *Win, c: *cairo.cairo_t, r: common.Rect, i: usize) void {
    self.paintCardBg(c, r);
    switch (engineRow(i)) {
        .status => return paintEngineStatus(self, c, r),
        .latency_offset => return paintEngineLatencyRow(self, c, r),
        .restart_wp, .restart_pw => return paintEngineRestartRow(self, c, r, i),
        else => {},
    }
    const row = engineRow(i);
    const glyph_name: []const u8 = switch (row) {
        .latency_node => "timer",
        .pcm => "tune",
        else => "tune",
    };
    ui_paint.glyph(c, @floatFromInt(r.x + card_pad + 18), @floatFromInt(r.y + @divTrunc(r.h, 2)), 24, glyph_name, Theme.text_r, Theme.text_g, Theme.text_b, 0.62);
    ui_paint.showTextW(c, @floatFromInt(r.x + 56), @floatFromInt(r.y + 30), engineRowTitle(i), 15, 500, @floatFromInt(r.w - 400), Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
    ui_paint.showTextW(c, @floatFromInt(r.x + 56), @floatFromInt(r.y + 50), engineRowHint(i), 11, 400, @floatFromInt(r.w - 420), Theme.text_r, Theme.text_g, Theme.text_b, 0.50);
    var buf: [64]u8 = undefined;
    const cr = profileComboRect(r);
    const open = self.dd.open and self.dd_state.kind == .engine and self.dd_state.id == @as(u32, @intCast(i));
    paintCombo(c, r, cr, self.engineRowValue(i, &buf), open);
}

/// "What this output can actually do" line: sink, rate span, formats,
/// channels and quantum limit from its `EnumFormat`.
fn engineHardwareCaption(self: *Win, buf: []u8) []const u8 {
    const caps = &self.caps;
    if (!caps.available) {
        return if (self.defaultSinkNodeId() != 0) "Hardware limits unavailable" else "No output device";
    }
    var n: usize = 0;
    const append = struct {
        fn add(b: []u8, at: *usize, part: []const u8) void {
            if (part.len == 0) return;
            const sep = if (at.* == 0) "" else " · ";
            if (at.* + sep.len + part.len > b.len) return;
            @memcpy(b[at.*..][0..sep.len], sep);
            at.* += sep.len;
            @memcpy(b[at.*..][0..part.len], part);
            at.* += part.len;
        }
    }.add;

    var rate_b: [40]u8 = undefined;
    if (caps.rate_min > 0 and caps.rate_max >= caps.rate_min) {
        var lo_b: [12]u8 = undefined;
        var hi_b: [12]u8 = undefined;
        const lo = engineShortRate(&lo_b, caps.rate_min);
        const hi = engineShortRate(&hi_b, caps.rate_max);
        if (caps.rate_min == caps.rate_max) {
            append(buf, &n, std.fmt.bufPrint(&rate_b, "{s} kHz", .{lo}) catch "");
        } else {
            append(buf, &n, std.fmt.bufPrint(&rate_b, "{s}-{s} kHz", .{ lo, hi }) catch "");
        }
    } else if (caps.rate_count > 0) {
        var lo_b: [12]u8 = undefined;
        var hi_b: [12]u8 = undefined;
        const lo = engineShortRate(&lo_b, caps.rates[0]);
        const hi = engineShortRate(&hi_b, caps.rates[caps.rate_count - 1]);
        append(buf, &n, std.fmt.bufPrint(&rate_b, "{s}-{s} kHz", .{ lo, hi }) catch "");
    }

    var fmt_b: [32]u8 = undefined;
    const fmt_s = engineCapsFormats(caps.formats, &fmt_b);
    append(buf, &n, fmt_s);

    var ch_b: [24]u8 = undefined;
    if (caps.channels > 0) append(buf, &n, std.fmt.bufPrint(&ch_b, "{d} ch", .{caps.channels}) catch "");

    var q_b: [32]u8 = undefined;
    if (caps.quantum_limit > 0) append(buf, &n, std.fmt.bufPrint(&q_b, "quantum <={d}", .{caps.quantum_limit}) catch "");

    return buf[0..n];
}

fn engineShortRate(buf: []u8, hz: i32) []const u8 {
    if (hz <= 0) return "?";
    if (@mod(hz, 1000) == 0) return std.fmt.bufPrint(buf, "{d}", .{@divTrunc(hz, 1000)}) catch "?";
    return std.fmt.bufPrint(buf, "{d}.{d}", .{
        @divTrunc(hz, 1000),
        @divTrunc(@mod(hz, 1000), 100),
    }) catch "?";
}

fn engineCapsFormats(bits: u16, buf: []u8) []const u8 {
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

fn paintConfigCard(self: *Win, c: *cairo.cairo_t, r: common.Rect, dev: *const Device) void {
    var t = liveNowNs();
    self.paintCardBg(c, r);
    self.card_prof.bg += liveNowNs() - t;
    t = liveNowNs();
    const ir = iconRect(r);
    _ = ir;
    const ix = r.x + card_pad + 18;
    const iy = r.y + @divTrunc(r.h, 2);
    ui_paint.glyph(c, @floatFromInt(ix), @floatFromInt(iy), 24, "tune", Theme.text_r, Theme.text_g, Theme.text_b, 0.62);
    self.card_prof.icon += liveNowNs() - t;

    t = liveNowNs();
    ui_paint.showTextW(c, @floatFromInt(r.x + 56), @floatFromInt(r.y + 34), dev.displayName(), 15, 500, @floatFromInt(r.w - 400), Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
    ui_paint.showTextW(c, @floatFromInt(r.x + 56), @floatFromInt(r.y + 54), dev.device_name.get(), 11, 400, @floatFromInt(r.w - 400), Theme.text_r, Theme.text_g, Theme.text_b, 0.50);
    self.card_prof.text += liveNowNs() - t;

    t = liveNowNs();
    const pr = profileComboRect(r);
    const open = self.dd.open and self.dd_state.kind == .profile and self.dd_state.id == dev.id;
    const cur = if (dev.active_profile >= 0) blk: {
        if (dev.findProfile(dev.active_profile)) |p| break :blk p.label();
        break :blk "(unknown)";
    } else "(unset)";
    paintCombo(c, r, pr, cur, open);
    self.card_prof.ctrl += liveNowNs() - t;
}

/// The shared combo look: rounded body, current value, chevron. `open`
/// lifts the fill and stroke so the trigger reads as pressed.
fn paintCombo(c: *cairo.cairo_t, card_rect: common.Rect, r: common.Rect, value: []const u8, open: bool) void {
    _ = card_rect;
    ui_paint.roundRect(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 8);
    cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, if (open) 0.10 else 0.06);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_set_source_rgba(c, Theme.outline_r, Theme.outline_g, Theme.outline_b, if (open) 0.9 else 0.45);
    cairo.cairo_stroke(c);
    ui_paint.showTextW(
        c,
        @floatFromInt(r.x + 10),
        @floatFromInt(comboLabelTop(r, ui_paint.textSizePx(c, value, 12, 500).h)),
        value,
        12,
        500,
        @floatFromInt(@max(0, r.w - 10 - 28)),
        Theme.text_r,
        Theme.text_g,
        Theme.text_b,
        0.92,
    );
    ui_paint.glyph(
        c,
        @floatFromInt(r.x + r.w - 13),
        @floatFromInt(r.y + @divTrunc(r.h, 2)),
        13,
        "expand_more",
        Theme.text_r,
        Theme.text_g,
        Theme.text_b,
        0.55,
    );
}

/// Mute button, track, percentage and L/R meter bars for one row.
fn paintVolumeRow(self: *Win, c: *cairo.cairo_t, r: common.Rect, node: *const Node, monitor: bool) void {
    const target = self.graph.volumeTarget(node, monitor);
    const muted = target.mute or node.mute and target.n_volumes == 0;
    var pct: i32 = blk: {
        if (target.n_volumes == 0) break :blk 100;
        const ratio = graph_mod.amplitudeRatio(target.volumes[0]);
        break :blk common.clampInt(@intFromFloat(@round(ratio * 100.0)), 0, slider_max_pct);
    };
    if (self.drag) |d| {
        if (d.id == node.id and d.monitor == monitor) pct = d.pct;
    }

    // Mute button.
    const mr = muteBtnRect(r);
    const mhov = rowHover(self.ptr_x, self.ptr_y, mr);
    ui_paint.roundRect(c, @floatFromInt(mr.x), @floatFromInt(mr.y), @floatFromInt(mr.w), @floatFromInt(mr.h), 10);
    cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, if (mhov) 0.13 else 0.06);
    cairo.cairo_fill(c);
    const on_glyph = if (monitor) "mic" else "volume_up";
    const off_glyph = if (monitor) "mic_off" else "volume_off";
    ui_paint.glyph(
        c,
        @floatFromInt(mr.x + @divTrunc(mr.w, 2)),
        @floatFromInt(mr.y + @divTrunc(mr.h, 2)),
        18,
        if (muted) off_glyph else on_glyph,
        Theme.text_r,
        Theme.text_g,
        Theme.text_b,
        if (muted) 0.45 else 0.92,
    );

    // Track, fill, knob.
    const tr = trackRect(r);
    const yf: f64 = @floatFromInt(tr.y);
    const hf: f64 = @floatFromInt(tr.h);
    ui_paint.roundRect(c, @floatFromInt(tr.x), yf, @floatFromInt(tr.w), hf, hf / 2.0);
    cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, 0.10);
    cairo.cairo_fill(c);
    const pct_frac = @as(f64, @floatFromInt(pct)) / @as(f64, @floatFromInt(slider_max_pct));
    if (pct > 0) {
        const fw = @max(hf, @as(f64, @floatFromInt(tr.w)) * pct_frac);
        ui_paint.roundRect(c, @floatFromInt(tr.x), yf, fw, hf, hf / 2.0);
        if (muted) {
            cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, 0.30);
        } else {
            cairo.cairo_set_source_rgba(c, Theme.acc_r, Theme.acc_g, Theme.acc_b, 0.95);
        }
        cairo.cairo_fill(c);
    }
    const kx = @as(f64, @floatFromInt(tr.x)) + @as(f64, @floatFromInt(tr.w)) * pct_frac;
    ui_paint.glassBox(c, kx - 7, yf + hf / 2.0 - 7, 14, 14, 7, 1, 1, 1, 0.96);

    var vbuf: [16]u8 = undefined;
    const vs = std.fmt.bufPrint(&vbuf, "{d}%", .{pct}) catch "0%";
    ui_paint.showText(
        c,
        @floatFromInt(tr.x + tr.w + 12),
        yf + hf / 2.0 + 5,
        vs,
        12,
        600,
        Theme.text_r,
        Theme.text_g,
        Theme.text_b,
        0.85,
    );

    self.noteMeterBand(node.id, tr, muted);
}

/// The L/R bars of one row, from the meter manager's latest levels.
fn paintMeterBars(self: *Win, c: *cairo.cairo_t, id: u32, tr: common.Rect, muted: bool) void {
    const lv = self.meters.level(id) orelse return;
    const y0 = tr.y + tr.h + 4;
    for (0..2) |ch| {
        const y = y0 + @as(i32, @intCast(ch)) * (meter_h + meter_gap);
        ui_paint.roundRect(c, @floatFromInt(tr.x), @floatFromInt(y), @floatFromInt(tr.w), @floatFromInt(meter_h), @as(f64, @floatFromInt(meter_h)) / 2.0);
        cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, 0.07);
        cairo.cairo_fill(c);
        const v: f64 = @floatCast(@min(lv[ch], 1.0));
        if (v > 0.001) {
            const fw = @max(2.0, @as(f64, @floatFromInt(tr.w)) * v);
            ui_paint.roundRect(c, @floatFromInt(tr.x), @floatFromInt(y), fw, @floatFromInt(meter_h), @as(f64, @floatFromInt(meter_h)) / 2.0);
            if (muted) {
                cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, 0.35);
            } else {
                cairo.cairo_set_source_rgba(c, Theme.acc_r, Theme.acc_g, Theme.acc_b, 0.90);
            }
            cairo.cairo_fill(c);
        }
    }
}

/// The popup, painted above every card but inside the window. `popupGeom`
/// flips it above the trigger when the list would overflow the bottom;
/// `paintDropdown` additionally clamps x so it can never leave the frame.
fn paintDropdown(self: *Win, c: *cairo.cairo_t) void {
    if (!self.dd.open) return;
    const count = self.ddCount();
    if (count == 0) return;
    self.dd.count = count;
    var g = self.dd.popupGeom(self.win_h);
    if (g.x + g.w > self.win_w - 8) g.x = self.win_w - 8 - g.w;
    if (g.x < 8) g.x = 8;

    ui_paint.glassBox(
        c,
        @floatFromInt(g.x),
        @floatFromInt(g.y),
        @floatFromInt(g.w),
        @floatFromInt(g.h),
        12,
        Theme.bg_r * 0.5,
        Theme.bg_g * 0.5,
        Theme.bg_b * 0.5,
        0.97,
    );
    cairo.cairo_save(c);
    ui_paint.roundRect(c, @floatFromInt(g.x), @floatFromInt(g.y), @floatFromInt(g.w), @floatFromInt(g.h), 12);
    cairo.cairo_clip(c);
    const sel = self.dd.displayIndex();
    for (0..count) |i| {
        const ry = g.y + @as(i32, @intCast(i)) * self.dd.row_h;
        const hovered = @as(i32, @intCast(i)) == self.dd.hover_row;
        if (hovered) {
            cairo.cairo_set_source_rgba(c, Theme.text_r, Theme.text_g, Theme.text_b, 0.08);
            cairo.cairo_rectangle(c, @floatFromInt(g.x), @floatFromInt(ry), @floatFromInt(g.w), @floatFromInt(self.dd.row_h));
            cairo.cairo_fill(c);
        }
        const is_sel = i == sel;
        const label = self.ddLabel(i);
        const lth = ui_paint.textSizePx(c, label, 12, if (is_sel) 600 else 400).h;
        ui_paint.showTextW(
            c,
            @floatFromInt(g.x + 12),
            @floatFromInt(cyTextTop(ry, self.dd.row_h, lth)),
            label,
            12,
            if (is_sel) @as(c_uint, 600) else @as(c_uint, 400),
            @floatFromInt(g.w - 24 - (if (is_sel) @as(i32, 20) else @as(i32, 0))),
            Theme.text_r,
            Theme.text_g,
            Theme.text_b,
            if (is_sel) 1.0 else 0.82,
        );
        if (is_sel) {
            ui_paint.glyph(
                c,
                @floatFromInt(g.x + g.w - 18),
                @floatFromInt(ry + @divTrunc(self.dd.row_h, 2)),
                13,
                "check",
                Theme.acc_r,
                Theme.acc_g,
                Theme.acc_b,
                0.95,
            );
        }
    }
    cairo.cairo_restore(c);
}

fn closeRect(win_w: i32) common.Rect {
    return .{ .x = win_w - 44, .y = common.spacing_l, .w = 28, .h = 28 };
}

fn drawClose(cr: ?*cairo.cairo_t, win_w: i32) void {
    const c = cr orelse return;
    const r = closeRect(win_w);
    const cx = @as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) * 0.5;
    const cy = @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) * 0.5;
    ui_paint.glassBox(
        c,
        @floatFromInt(r.x),
        @floatFromInt(r.y),
        @floatFromInt(r.w),
        @floatFromInt(r.h),
        @as(f64, @floatFromInt(r.w)) * 0.5,
        Theme.acc_r,
        Theme.acc_g,
        Theme.acc_b,
        0.35,
    );
    ui_paint.glyph(c, cx, cy + 0.5, 15, "close", Theme.text_r, Theme.text_g, Theme.text_b, 0.95);
}

// ── dropdown plumbing ───────────────────────────────────────────────────────

fn closeDropdown(self: *Win) void {
    if (self.dd.open) {
        // The popup's pixels go away (and its shadow spills past the rect):
        // whatever it covered has to be repainted.
        self.damage = rectJoin(self.damage, self.popupRect());
    }
    self.dd.close();
    self.dd_state = .{};
}

fn openDropdown(self: *Win, kind: DdKind, id: u32, dir: u32, trigger: common.Rect) void {
    self.dd_state = .{ .kind = kind, .id = id, .dir = dir };
    self.dd.count = self.ddCount();
    self.dd.selected = self.ddCurrentSel();
    self.dd.setAnchor(trigger.x, trigger.y, trigger.w, trigger.h);
    self.dd.openPopup();
    // The popup is new pixels; the trigger's own "open" highlight is inside
    // the row the pointer sits on.
    self.damage = rectJoin(self.damage, self.pointerRegion(self.ptr_x, self.ptr_y));
    self.damage = rectJoin(self.damage, self.popupRect());
    self.needs_repaint = true;
    self.markAction("combo-open");
    logz.log("ux: combo open {s} id={d} dir={d} rows={d}", .{ @tagName(kind), id, dir, self.dd.count });
}

/// The i-th node of the open `.move` dropdown (sinks for playback streams,
/// sources for recording streams).
fn ddItemNode(self: *Win, i: usize) ?*Node {
    const want: graph_mod.Role = if (self.dd_state.dir == 1) .sink else .source;
    var n: usize = 0;
    for (self.graph.nodes.items) |*node| {
        if (node.role != want) continue;
        if (n == i) return node;
        n += 1;
    }
    return null;
}

fn ddItemRoute(self: *Win, i: usize) ?*const Route {
    const node = self.graph.findNode(self.dd_state.id) orelse return null;
    return self.portRouteAt(node, self.dd_state.dir, i);
}

fn ddItemProfile(self: *Win, i: usize) ?*const Profile {
    const dev = self.graph.findDevice(self.dd_state.id) orelse return null;
    if (i >= dev.profiles.items.len) return null;
    return &dev.profiles.items[i];
}

fn ddCount(self: *Win) usize {
    switch (self.dd_state.kind) {
        .none => return 0,
        .move => {
            var n: usize = 0;
            while (self.ddItemNode(n) != null) n += 1;
            return n;
        },
        .port => {
            const node = self.graph.findNode(self.dd_state.id) orelse return 0;
            return self.portCount(node, self.dd_state.dir);
        },
        .profile => {
            const dev = self.graph.findDevice(self.dd_state.id) orelse return 0;
            return dev.profiles.items.len;
        },
        .engine => return engineRowValueCount(self, self.dd_state.id),
    }
}

fn ddLabel(self: *Win, i: usize) []const u8 {
    switch (self.dd_state.kind) {
        .none => return "",
        .move => {
            const node = self.ddItemNode(i) orelse return "";
            return node.displayName();
        },
        .port => {
            const route = self.ddItemRoute(i) orelse return "";
            return route.label();
        },
        .profile => {
            const prof = self.ddItemProfile(i) orelse return "";
            return prof.label();
        },
        .engine => {
            const row: usize = @intCast(self.dd_state.id);
            if (row >= engine_row_count) return "";
            return self.engineRowItemLabel(row, i);
        },
    }
}

/// Index of the current value inside the open list, for the popup highlight.
fn ddCurrentSel(self: *Win) i32 {
    switch (self.dd_state.kind) {
        .none => return -1,
        .move => {
            const cur: u32 = if (self.dd_state.dir == 1)
                (self.graph.sinkForStream(self.dd_state.id) orelse return -1)
            else
                (self.graph.sourceForStream(self.dd_state.id) orelse return -1);
            var i: usize = 0;
            while (self.ddItemNode(i)) |node| : (i += 1) {
                if (node.id == cur) return @intCast(i);
            }
            return -1;
        },
        .port => {
            const node = self.graph.findNode(self.dd_state.id) orelse return -1;
            const dev = self.deviceFor(node) orelse return -1;
            const active = dev.activeRouteFor(self.dd_state.dir).index;
            if (active < 0) return -1;
            var i: usize = 0;
            while (self.ddItemRoute(i)) |route| : (i += 1) {
                if (route.index == active) return @intCast(i);
            }
            return -1;
        },
        .profile => {
            const dev = self.graph.findDevice(self.dd_state.id) orelse return -1;
            if (dev.active_profile < 0) return -1;
            var i: usize = 0;
            while (self.ddItemProfile(i)) |prof| : (i += 1) {
                if (prof.index == dev.active_profile) return @intCast(i);
            }
            return -1;
        },
        .engine => {
            const row: usize = @intCast(self.dd_state.id);
            return self.engineRowSel(row);
        },
    }
}

/// Land a popup row: move the stream, switch the port or the profile.
fn ddApply(self: *Win, row: i32) void {
    if (row < 0) return;
    const i: usize = @intCast(row);
    if (self.dd_state.kind == .engine) {
        self.applyEngineRow(@intCast(self.dd_state.id), i);
    } else {
        const c = self.client orelse return;
        switch (self.dd_state.kind) {
            .none, .engine => {},
            .move => {
                const target = self.ddItemNode(i) orelse return;
                _ = c.moveStream(self.dd_state.id, target.id);
            },
            .port => {
                const node = self.graph.findNode(self.dd_state.id) orelse return;
                const route = self.ddItemRoute(i) orelse return;
                const dev = self.deviceFor(node) orelse return;
                // Exactly what pipewire-pulse does: the route's index plus the
                // node's `card.profile.device`.
                _ = c.setRoute(dev.id, route.index, node.card_profile_device);
            },
            .profile => {
                const prof = self.ddItemProfile(i) orelse return;
                _ = c.setProfile(self.dd_state.id, prof.index);
            },
        }
    }
    logz.log("ux: combo select {s} id={d} row={d}", .{ @tagName(self.dd_state.kind), self.dd_state.id, row });
    self.markAction("combo-select");
    self.needs_repaint = true;
}

// ── volume drag ─────────────────────────────────────────────────────────────

fn pctFromTrack(tr: common.Rect, x: f64) i32 {
    const w: f64 = @floatFromInt(@max(1, tr.w));
    const frac = (x - @as(f64, @floatFromInt(tr.x))) / w;
    return common.clampInt(
        @intFromFloat(@round(frac * @as(f64, @floatFromInt(slider_max_pct)))),
        0,
        slider_max_pct,
    );
}

fn applyDrag(self: *Win, d: *Drag, force: bool) void {
    const now = liveNowNs();
    if (!force and now - d.last_apply_ns < drag_apply_ns) return;
    d.last_apply_ns = now;
    const node = self.graph.findNode(d.id) orelse return;
    const target = self.graph.volumeTarget(node, d.monitor);
    const c = self.client orelse return;
    const n = if (target.n_volumes == 0) 2 else target.n_volumes;
    var vols: [graph_mod.max_channels]f32 = @splat(0);
    const amp = graph_mod.ratioAmplitude(@as(f32, @floatFromInt(d.pct)) / 100.0);
    for (0..n) |i| vols[i] = amp;
    _ = c.setVolume(d.id, vols[0..n], d.monitor);
    // Every write is already throttled to one per 40 ms by the caller; the
    // log line is the audit trail of what actually reached PipeWire.
    logz.log("ux: volume set node={d} pct={d} monitor={} final={}", .{ d.id, d.pct, d.monitor, force });
}

// ── input ───────────────────────────────────────────────────────────────────

fn onEnter(ctx: *anyopaque, x: f64, y: f64) void {
    const self: *Win = @ptrCast(@alignCast(ctx));
    self.ptr_x = x;
    self.ptr_y = y;
    self.damage = rectJoin(self.damage, self.pointerRegion(x, y));
    self.repaint();
}

fn onLeave(ctx: *anyopaque) void {
    const self: *Win = @ptrCast(@alignCast(ctx));
    self.damagePointer(self.ptr_x, self.ptr_y, -1, -1);
    self.ptr_x = -1;
    self.ptr_y = -1;
    if (self.dd.open) self.dd.hover_row = -1;
    self.repaint();
}

fn onMotion(ctx: *anyopaque, x: f64, y: f64) void {
    const self: *Win = @ptrCast(@alignCast(ctx));
    const from_x = self.ptr_x;
    const from_y = self.ptr_y;
    self.ptr_x = x;
    self.ptr_y = y;
    if (self.dd.open) {
        self.dd.hover_row = self.dd.hitRow(
            @intFromFloat(@max(0, x)),
            @intFromFloat(@max(0, y)),
            self.win_h,
        );
    }
    if (self.drag) |*d| {
        const pct = pctFromTrack(d.track, x);
        if (pct != d.pct) {
            d.pct = pct;
            self.applyDrag(d, false);
            self.needs_repaint = true;
            self.markAction("volume-drag");
        }
    }
    // A hover highlight is all that moves with the pointer: repaint the rows
    // (or header/popup) under the old and the new position, nothing else.
    self.damagePointer(from_x, from_y, x, y);
    if (self.drag) |d| self.damage = rectJoin(self.damage, padRect(d.row, 4));
    self.repaint();
}

fn onAxis(ctx: *anyopaque, delta: f64) void {
    const self: *Win = @ptrCast(@alignCast(ctx));
    if (self.ptr_x >= 0 and self.ptr_x < @as(f64, @floatFromInt(rail_w))) return;
    if (self.dd.open) self.closeDropdown();
    self.damageAll();
    self.scroll.scrollBy(delta * wheel_scale);
    self.markAction("scroll");
    self.repaint();
}

fn onKey(ctx: *anyopaque, ev: *const wl_seat.KeyEvent) void {
    const self: *Win = @ptrCast(@alignCast(ctx));
    if (ev.state != 1) return; // pressed only
    if (self.emodal != .none) {
        switch (ev.sym) {
            wl_seat.xkb.XKB_KEY_Escape => self.emodal = .none,
            wl_seat.xkb.XKB_KEY_Return, wl_seat.xkb.XKB_KEY_KP_Enter => self.submitEngineModal(),
            wl_seat.xkb.XKB_KEY_BackSpace => {
                if (self.emodal_len > 0) self.emodal_len -= 1;
            },
            else => {
                if (ev.utf8_len > 0) {
                    const ch = ev.utf8[0];
                    if (ch >= '0' and ch <= '9' and self.emodal_len < self.emodal_buf.len - 1) {
                        self.emodal_buf[self.emodal_len] = ch;
                        self.emodal_len += 1;
                    }
                }
            },
        }
        self.needs_repaint = true;
        self.damageAll();
        self.repaint();
        return;
    }
    if (self.lat_focus and self.page == .engine) {
        switch (ev.sym) {
            wl_seat.xkb.XKB_KEY_Escape => {
                self.lat_focus = false;
            },
            wl_seat.xkb.XKB_KEY_Return, wl_seat.xkb.XKB_KEY_KP_Enter => {
                self.applyLatency();
                self.lat_focus = false;
            },
            wl_seat.xkb.XKB_KEY_BackSpace => {
                if (self.lat_len > 0) self.lat_len -= 1;
            },
            else => {
                if (ev.utf8_len > 0) {
                    const ch = ev.utf8[0];
                    if (ch >= '0' and ch <= '9' and self.lat_len < self.lat_field.len - 1) {
                        self.lat_field[self.lat_len] = ch;
                        self.lat_len += 1;
                    }
                }
            },
        }
        self.needs_repaint = true;
        self.damageAll();
        self.repaint();
        return;
    }
    switch (ev.sym) {
        wl_seat.xkb.XKB_KEY_Escape => {
            if (self.dd.open) {
                self.closeDropdown();
            } else {
                self.running = false;
                wl_loop.Loop.requestStop();
                return;
            }
            self.repaint();
        },
        else => {},
    }
}

fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
    const self: *Win = @ptrCast(@alignCast(ctx));
    const BTN_LEFT: u32 = 0x110;
    if (button != BTN_LEFT) return;
    const px = self.ptr_x;
    const py = self.ptr_y;

    if (state == 0) {
        // Release: land the final volume write of a drag.
        if (self.drag) |*d| {
            self.applyDrag(d, true);
            self.damage = rectJoin(self.damage, padRect(d.row, 4));
            self.drag = null;
            self.repaint();
        }
        return;
    }

    // The custom-value dialog is modal: it swallows every click.
    if (self.emodal != .none) {
        const r = engineModalRect(self.win_w, self.win_h);
        if (common.pointInRect(px, py, engineModalSubmitRect(r))) {
            self.submitEngineModal();
        } else {
            self.emodal = .none;
            self.needs_repaint = true;
            self.damageAll();
        }
        self.repaint();
        return;
    }

    // An open dropdown swallows the next click: a popup row applies, any
    // other click just closes it.
    if (self.dd.open) {
        const row = self.dd.hitRow(
            @intFromFloat(@max(0, px)),
            @intFromFloat(@max(0, py)),
            self.win_h,
        );
        const applied = row >= 0;
        if (applied) self.ddApply(row);
        self.closeDropdown();
        // Applying a row can rewrite the label, move the stream to another
        // device, change a profile — pixels anywhere. A plain close only
        // drops the popup, which closeDropdown has already marked.
        if (applied) self.damageAll();
        self.repaint();
        return;
    }

    if (common.pointInRect(px, py, closeRect(self.win_w))) {
        self.running = false;
        wl_loop.Loop.requestStop();
        return;
    }

    // Rail: page switch.
    if (px >= 0 and px < @as(f64, @floatFromInt(rail_w))) {
        for (pages, 0..) |p, i| {
            if (common.pointInRect(px, py, railBtnRect(i))) {
                self.setPage(p);
                self.repaint();
                return;
            }
        }
        return;
    }

    // Header toggles.
    if (py < @as(f64, @floatFromInt(header_h))) {
        var changed = false;
        if (self.hit_engine_refresh) |r| {
            if (common.pointInRect(px, py, r)) {
                self.refreshEngine(true);
                self.needs_repaint = true;
                self.damageAll();
                self.markAction("engine-refresh");
                self.repaint();
                return;
            }
        }
        if (common.pointInRect(px, py, self.hit_meters)) {
            self.show_meters = !self.show_meters;
            changed = true;
        } else if (self.hit_page_toggle) |r| {
            if (common.pointInRect(px, py, r)) {
                switch (self.page) {
                    .recording => self.all_streams = !self.all_streams,
                    .output, .input => self.hw_only = !self.hw_only,
                    .engine => {},
                    else => {},
                }
                changed = true;
            }
        }
        if (changed) {
            self.scroll.setMax(self.scrollMax());
            self.savePrefs();
            self.markAction("toggle");
            logz.log("ux: toggle meters={} hw_only={} all_streams={}", .{
                self.show_meters,
                self.hw_only,
                self.all_streams,
            });
            // Rows appear and disappear: everything below moves.
            self.damageAll();
            self.repaint();
        }
        return;
    }

    const idx = self.hitCard(px, py) orelse return;
    const r = self.cardRect(idx);
    switch (self.page) {
        .configuration => {
            const dev = self.deviceAt(idx) orelse return;
            const pr = profileComboRect(r);
            if (common.pointInRect(px, py, pr)) self.openDropdown(.profile, dev.id, 0, pr);
        },
        .output, .input => {
            const node = self.nodeAt(idx) orelse return;
            self.clickNodeRow(r, node);
        },
        .engine => {
            const now = liveNowNs();
            switch (engineRow(idx)) {
                .status => {
                    if (self.top.available and common.pointInRect(px, py, engineXrunHitRect(r))) {
                        self.xrun_base = self.top.xruns_total;
                        self.needs_repaint = true;
                        self.markAction("xrun-reset");
                        self.damageAll();
                    }
                },
                .latency_offset => {
                    if (common.pointInRect(px, py, engineLatFieldRect(r))) {
                        self.lat_focus = true;
                        self.needs_repaint = true;
                        self.markAction("latency-focus");
                    } else if (common.pointInRect(px, py, engineLatUnitRect(r))) {
                        // Pick the half that was clicked, not a blind toggle.
                        const ur = engineLatUnitRect(r);
                        const split = if (self.engine_unit_split > 0) self.engine_unit_split else @divTrunc(ur.w, 2);
                        self.lat_ns = px >= @as(f64, @floatFromInt(ur.x + split));
                        self.needs_repaint = true;
                        self.damageAll();
                    } else if (common.pointInRect(px, py, engineLatApplyRect(r))) {
                        if (self.latencyNode() != null) self.applyLatency();
                    } else if (common.pointInRect(px, py, engineLatResetRect(r))) {
                        if (self.latencyNodeCount() > 0) self.resetAllLatency();
                    } else {
                        self.lat_focus = false;
                    }
                },
                .restart_wp => {
                    if (common.pointInRect(px, py, engineRestartBtnRect(r))) {
                        const armed = self.restart_wp_arm_ns != 0 and now - self.restart_wp_arm_ns <= engine_restart_arm_ns;
                        if (!armed) {
                            self.restart_wp_arm_ns = now;
                        } else {
                            self.restart_wp_arm_ns = 0;
                            _ = live_audio.restartWirePlumber(self.io);
                            self.restart_wp_done_ns = now;
                            self.engine_at_ns = 0;
                            self.caps_at_ns = 0;
                        }
                        self.needs_repaint = true;
                        self.damageAll();
                        self.markAction("restart-wp");
                    }
                },
                .restart_pw => {
                    if (common.pointInRect(px, py, engineRestartBtnRect(r))) {
                        const armed = self.restart_pw_arm_ns != 0 and now - self.restart_pw_arm_ns <= engine_restart_arm_ns;
                        if (!armed) {
                            self.restart_pw_arm_ns = now;
                        } else {
                            self.restart_pw_arm_ns = 0;
                            _ = live_audio.restartPipeWire(self.io);
                            self.restart_pw_done_ns = now;
                            self.engine_at_ns = 0;
                            self.caps_at_ns = 0;
                        }
                        self.needs_repaint = true;
                        self.damageAll();
                        self.markAction("restart-pw");
                    }
                },
                else => {
                    const cr = profileComboRect(r);
                    if (common.pointInRect(px, py, cr)) {
                        self.lat_focus = false;
                        self.openDropdown(.engine, @intCast(idx), 0, cr);
                    }
                },
            }
        },
        else => {
            const node = self.nodeAt(idx) orelse return;
            if (common.pointInRect(px, py, closeBtnRect(r))) {
                if (self.client) |c| _ = c.killNode(node.id);
                self.needs_repaint = true;
                self.markAction("kill");
                logz.log("ux: kill stream node={d} app={s}", .{ node.id, node.app_name.get() });
                // The row disappears and everything below it moves up.
                self.damageAll();
            } else if (common.pointInRect(px, py, moveComboRect(r))) {
                const dir: u32 = if (self.page == .playback) 1 else 0;
                self.openDropdown(.move, node.id, dir, moveComboRect(r));
            } else {
                self.clickVolumeRow(r, node, false);
            }
        },
    }
    self.repaint();
}

fn clickNodeRow(self: *Win, r: common.Rect, node: *const Node) void {
    const dir: u32 = if (node.role == .sink) 1 else 0;
    const px = self.ptr_x;
    const py = self.ptr_y;
    if (self.portCount(node, dir) > 0 and common.pointInRect(px, py, portComboRect(r))) {
        self.openDropdown(.port, node.id, dir, portComboRect(r));
        return;
    }
    if (common.pointInRect(px, py, defaultBtnRect(r))) {
        if (!self.isDefaultNode(node)) {
            if (self.client) |c| {
                if (node.role == .sink) {
                    _ = c.setDefaultSinkName(node.node_name.get());
                } else {
                    _ = c.setDefaultSourceName(node.node_name.get());
                }
            }
            self.needs_repaint = true;
            self.markAction("default");
            logz.log("ux: default {s} = {s}", .{ @tagName(node.role), node.node_name.get() });
            // The default chip moves from another row to this one — that row
            // can be any card on the page, so this frame is a full paint.
            self.damageAll();
        }
        return;
    }
    self.clickVolumeRow(r, node, false);
}

/// Mute button toggles; the track starts a drag.
fn clickVolumeRow(self: *Win, r: common.Rect, node: *const Node, monitor: bool) void {
    const tr = trackRect(r);
    if (common.pointInRect(self.ptr_x, self.ptr_y, muteBtnRect(r))) {
        const t = self.graph.volumeTarget(node, monitor);
        if (self.client) |c| _ = c.setMute(node.id, !t.mute, monitor);
        self.needs_repaint = true;
        self.damage = rectJoin(self.damage, padRect(r, 4));
        self.markAction("mute");
        logz.log("ux: mute node={d} -> {} (monitor={})", .{ node.id, !t.mute, monitor });
        return;
    }
    const grab = common.Rect{ .x = tr.x, .y = tr.y - 8, .w = tr.w, .h = tr.h + 16 };
    if (common.pointInRect(self.ptr_x, self.ptr_y, grab)) {
        self.drag = .{
            .id = node.id,
            .monitor = monitor,
            .track = tr,
            .row = r,
            .pct = pctFromTrack(tr, self.ptr_x),
            .last_apply_ns = 0,
        };
        if (self.drag) |*d| self.applyDrag(d, true);
        self.needs_repaint = true;
        self.markAction("volume-seek");
        self.damage = rectJoin(self.damage, padRect(r, 4));
    }
}

fn hitCard(self: *Win, px: f64, py: f64) ?usize {
    const n = self.rowCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = self.cardRect(i);
        if (common.pointInRect(px, py, r)) return i;
    }
    return null;
}
};

pub fn run(init: std.process.Init) !u8 {
    logz.init(init.io, init.environ_map.get("HOME"), "horizon-audio-center");
    defer logz.deinit();
    var win = Win{};
    win.start_ns = liveNowNs();
    defer win.deinit();
    if (!(try win.start(init))) {
        logz.err("audio-center: window start failed", .{});
        return 1;
    }
    win.repaint();
    _ = win.conn.roundtrip();
    logz.log("audio-center up: {d}x{d} page={s}", .{ win.win_w, win.win_h, win.page.tag() });
    win.loop.run();
    // Exit summary: the last stats windows plus the lifetime picture, so a
    // short scripted run still leaves numbers in the log.
    win.frames.flush("scene", win.page, win.rowCount());
    win.narrow_frames.flush("narrow", win.page, win.rowCount());
    win.anim_frames.flush("anim", win.page, win.rowCount());
    win.frames.report("scene");
    win.narrow_frames.report("narrow");
    win.anim_frames.report("anim");
    logz.log("frame session: busy_skips={d} idle_ticks={d}", .{ win.busy_skips, win.idle_ticks });
    if (icon_cache.shared()) |ic| {
        const st = ic.statsOf();
        // hits = served from memory, disk_hits = decoded pixels off disk
        // instead of rasterizing, rasters = librsvg/stb actually run.
        logz.log("icons: session hits={d} misses={d} disk={d} rasters={d} enqueued={d}", .{
            st.hits, st.misses, st.disk_hits, st.rasters, st.enqueued,
        });
    }
    logz.log("audio-center exit: clean (page={s})", .{win.page.tag()});
    return 0;
}
