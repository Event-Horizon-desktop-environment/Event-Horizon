const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const glyph = @import("../../common/material_glyph.zig");
const svg_icons = @import("../../../ux/shared/svg_icons.zig");
const bus = @import("media_bus.zig");
const widget = @import("widget.zig");
const store = @import("cider_store.zig");
const cider = @import("../../../services/cider_client.zig");
const mpris_art = @import("../../../services/mpris_art.zig");
const cider_art_cache = @import("../../../services/cider_art_cache.zig");
const app_launch = @import("../../../services/app_launch.zig");
const logz = @import("../../../logz.zig");
const builtin = @import("builtin");

// Cider 4 desktop dashboard.
//
// A 900x580 liquid-glass card: an icon rail, a content area with five pages
// (Now Playing, Queue, Library, Lyrics, Connect), and a persistent transport
// strip. Live metadata and transport come from the shell's MPRIS bus; Cider's
// local REST v2 API fills in queue, library, lyrics, audio, and token status.
// The widget is deliberately click-only, matching the desktop host: text
// entry (search, party codes, tokens) hands off to Cider.
//
// Visual language: layered translucent panels over a dark glass base, soft
// tinted light from the current artwork, 1px specular edges, large rounded
// corners, and restrained Inter typography.

pub const kw: f64 = 900.0;
pub const kh: f64 = 580.0;
const outer_r: f64 = 28.0;
const sidebar_x: f64 = 10.0;
const sidebar_y: f64 = 10.0;
const sidebar_w: f64 = 64.0;
const sidebar_h: f64 = 560.0;
const content_x: f64 = 104.0;
const content_right: f64 = 876.0;
const content_w: f64 = content_right - content_x;
const content_top: f64 = 90.0;
const content_bottom: f64 = 490.0;
const player_x: f64 = 104.0;
const player_y: f64 = 506.0;
const player_w: f64 = 772.0;
const player_h: f64 = 54.0;
const queue_rows: usize = 7;
const library_rows_top: usize = 7;
const library_rows_collection: usize = 8;
const row_step: f64 = 46.0;
const row_h: f64 = 42.0;

const green = [3]f64{ 0.34, 0.86, 0.68 };
const amber = [3]f64{ 0.98, 0.72, 0.34 };
const red = [3]f64{ 0.98, 0.44, 0.48 };

pub const Page = enum { now_playing, queue, library, lyrics, connect };

const Frame = struct {
    valid: bool = false,
    kind: cider.LibraryKind = .playlists,
    id: [160]u8 = undefined,
    id_len: u8 = 0,
    name: [192]u8 = undefined,
    name_len: u8 = 0,
    subtitle: [192]u8 = undefined,
    subtitle_len: u8 = 0,

    fn idText(self: *const Frame) []const u8 {
        return self.id[0..self.id_len];
    }
    fn nameText(self: *const Frame) []const u8 {
        return self.name[0..self.name_len];
    }
    fn subtitleText(self: *const Frame) []const u8 {
        return self.subtitle[0..self.subtitle_len];
    }
    fn set(self: *Frame, kind: cider.LibraryKind, id: []const u8, name: []const u8, subtitle: []const u8) void {
        self.valid = true;
        self.kind = kind;
        copyInto(160, &self.id, &self.id_len, id);
        copyInto(192, &self.name, &self.name_len, name);
        copyInto(192, &self.subtitle, &self.subtitle_len, subtitle);
    }
};

fn copyInto(comptime N: usize, dst: *[N]u8, len: *u8, src: []const u8) void {
    const n = @min(src.len, N);
    @memcpy(dst[0..n], src[0..n]);
    len.* = @intCast(n);
}

pub const State = struct {
    page: Page = .now_playing,
    hover: Target = .{},
    lib_tab: cider.LibraryKind = .playlists,
    lib_page: usize = 0,
    frame: Frame = .{},
    back: Frame = .{},
    queue_page: usize = 0,
    queue_seen: bool = false,
    queue_auto: bool = false,
    toast: [160]u8 = undefined,
    toast_len: u8 = 0,
    toast_until: u64 = 0,
    io: std.Io = undefined,
    io_ready: bool = false,
    /// First refresh has run (logs the boot line once).
    booted: bool = false,
    /// Last logged store link, so connection changes land in the log.
    last_link: store.Link = .unknown,
};

pub fn stateFromConfig(cfg: dw_data.WidgetConfig) State {
    _ = cfg;
    return .{};
}

pub fn size(_: *const State) [2]i32 {
    return .{ 900, 580 };
}

pub fn ticks(_: *const State) bool {
    return true;
}

fn animFollowsCider(snap: bus.Snapshot, api_playing: bool) bool {
    if (snap.realActive() and busIsCider(snap.bus_name)) return snap.playing();
    return api_playing;
}

pub fn anim(s: *const State) u32 {
    if (s.page == .lyrics and store.snapshot().lyrics != null) return 100;
    // Only Cider's own playback drives this widget. Other MPRIS players (a
    // browser video, say) must not keep the whole desktop repainting at 30fps.
    if (animFollowsCider(bus.get(), store.playbackState().playing())) return 100;
    if (store.snapshot().busy) return 150;
    if (widget.monotonicMs() < s.toast_until) return 250;
    return 0;
}

pub fn refresh(s: *State, io: std.Io) void {
    ensureWatchdog();
    setPhase(perf_refresh);
    defer clearPhase();
    const perf_t = refreshStarted();
    defer refreshFinished(perf_t);

    s.io = io;
    s.io_ready = true;
    store.poll(io);
    const st = store.snapshot();
    if (!s.booted) {
        s.booted = true;
        s.last_link = st.link;
        logz.log("cider: boot page={s} frame={} perf={} trace={} link={s} version={s} token={}", .{
            @tagName(s.page),  s.frame.valid, perfEnabled(), traceEnabled(),
            @tagName(st.link), st.version,    st.has_token,
        });
    }
    if (st.link != s.last_link) {
        logz.log("cider: link {s} -> {s} version={s} token={} auth_pending={} msg=\"{s}\"", .{
            @tagName(s.last_link), @tagName(st.link), st.version, st.has_token,
            st.auth_pending,       st.auth_message,
        });
        s.last_link = st.link;
    }
    if (st.queue) |q| {
        const page: usize = @intCast(@divTrunc(@max(q.position, 0), @as(i64, queue_rows)));
        if (!s.queue_seen) {
            s.queue_page = page;
            s.queue_seen = true;
            s.queue_auto = true;
        } else if (s.queue_auto and s.queue_page != page) {
            s.queue_page = page;
        }
        const pages = queuePages(q);
        if (s.queue_page >= pages) s.queue_page = pages - 1;
    }
    if (s.page == .library) {
        const lv = View{ .st = st };
        if (visibleLibrary(s, &lv)) |p| {
            const pages = libPages(s, p);
            if (s.lib_page >= pages) s.lib_page = pages - 1;
        }
    }

    // The player bar is persistent, so Cider's playback snapshot has to keep
    // moving on every page. Polling only on Now/Lyrics/Connect left Queue and
    // Library showing a stale track whenever the system bus belonged to some
    // other player.
    store.ensurePlayback(io);
    switch (s.page) {
        .now_playing => {
            store.ensureNowStatus(io);
            store.ensureQueue(io);
            store.ensureLyrics(io);
        },
        .queue => store.ensureQueue(io),
        .lyrics => store.ensureLyrics(io),
        .library => {
            const kind = activeKind(s);
            store.ensureLibrary(io, kind, activeId(s));
        },
        .connect => store.ensureAudio(io),
    }
    ensureCovers(s, io);
}

// ---------------------------------------------------------------------------
// View model

const Now = struct {
    active: bool = false,
    playing: bool = false,
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    art: []const u8 = "",
    position_ms: i64 = 0,
    duration_ms: i64 = 0,
    flavor: []const u8 = "Cider",
    from_mpris: bool = false,
    shuffle: bool = false,
    loop: []const u8 = "",
};

const View = struct {
    snap: bus.Snapshot = .{},
    st: store.Snapshot = .{},
    now: Now = .{},
};

fn busIsCider(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "cider") != null or
        std.mem.indexOf(u8, name, "Cider") != null;
}

fn elapsedMs(since_ms: i64) i64 {
    if (since_ms <= 0) return 0;
    const now_u = widget.monotonicMs();
    const since_u: u64 = @intCast(since_ms);
    if (now_u <= since_u) return 0;
    const d = now_u - since_u;
    return @intCast(@min(d, @as(u64, std.math.maxInt(i64))));
}

fn playbackFlavor(ps: *const cider.PlaybackState) []const u8 {
    const quality = ps.flavorLabelText();
    if (quality.len > 0) return quality;
    return cider.qualityName(ps.flavorText(), ps.lossless);
}

fn nowInfo(snap: bus.Snapshot, ps: *const cider.PlaybackState, playback_at: i64) Now {
    const cider_mpris = snap.realActive() and busIsCider(snap.bus_name);
    if (cider_mpris) {
        return .{
            .active = true,
            .playing = snap.playing(),
            .title = snap.title,
            .artist = snap.artist,
            .album = snap.album,
            .art = snap.art_url,
            .position_ms = @divTrunc(snap.position_us, 1000),
            .duration_ms = @divTrunc(snap.duration_us, 1000),
            .flavor = if (ps.available) playbackFlavor(ps) else "Cider",
            .from_mpris = true,
            .shuffle = snap.shuffle,
            .loop = snap.loop_status,
        };
    }
    if (ps.available) {
        if (ps.title_len > 0) {
            var pos = ps.position_ms;
            if (ps.playing()) pos += elapsedMs(playback_at);
            if (ps.duration_ms > 0 and pos > ps.duration_ms) pos = ps.duration_ms;
            return .{
                .active = true,
                .playing = ps.playing(),
                .title = ps.titleText(),
                .artist = ps.artistText(),
                .album = ps.albumText(),
                .art = ps.artText(),
                .position_ms = pos,
                .duration_ms = ps.duration_ms,
                .flavor = playbackFlavor(ps),
                .from_mpris = false,
                .shuffle = ps.shuffle,
                .loop = if (std.mem.eql(u8, ps.repeatText(), "one"))
                    "Track"
                else if (std.mem.eql(u8, ps.repeatText(), "all"))
                    "Playlist"
                else
                    "None",
            };
        }
        return .{};
    }
    return .{};
}

fn viewFor(s: *State) View {
    _ = s;
    const snap = bus.get();
    const st = store.snapshot();
    return .{ .snap = snap, .st = st, .now = nowInfo(snap, store.playbackState(), st.playback_at_ms) };
}

fn activeKind(s: *const State) cider.LibraryKind {
    return if (s.frame.valid) s.frame.kind else s.lib_tab;
}

fn activeId(s: *const State) []const u8 {
    return if (s.frame.valid) s.frame.idText() else "";
}

fn visibleLibrary(s: *const State, v: *const View) ?*const cider.LibraryPage {
    const p = v.st.library orelse return null;
    if (p.kind != activeKind(s)) return null;
    if (!std.mem.eql(u8, v.st.library_id, activeId(s))) return null;
    return p;
}

/// Test/preview hook: when nonzero, nowMs() returns this value so animated
/// painters (equalizer, spinner, toasts) render deterministically — required
/// to byte-compare cold vs warm preview PNGs.
var frozen_now_ms: u64 = 0;

fn nowMs() u64 {
    if (frozen_now_ms != 0) return frozen_now_ms;
    return widget.monotonicMs();
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * std.time.ns_per_s +
        @as(u64, @intCast(@max(ts.nsec, 0)));
}

/// Perf tracing is off by default: slow frames and multi-second stalls are
/// always logged, but `EH_CIDER_PERF=1` adds a 10s paint/refresh summary and
/// `EH_CIDER_TRACE=1` also logs every store job and cache lock wait.
var perf_env: i8 = -1;
/// Set by the desktop host when its own perf mode is on (`EH_DESKTOP_PERF`),
/// so the Cider element tables come along without a second env var.
pub var perf_force: bool = false;
fn perfEnabled() bool {
    if (perf_force) return true;
    if (perf_env < 0) perf_env = if (std.c.getenv("EH_CIDER_PERF") != null) 1 else 0;
    return perf_env == 1;
}
var trace_env: i8 = -1;
fn traceEnabled() bool {
    if (trace_env < 0) trace_env = if (std.c.getenv("EH_CIDER_TRACE") != null) 1 else 0;
    return trace_env == 1;
}

// Paint section timings, in the order `paintView` renders them.
const perf_card = 0;
const perf_sidebar = 1;
const perf_header = 2;
const perf_page = 3;
const perf_player = 4;
const perf_toast = 5;
var paint_sections_ns: [6]u64 = [_]u64{0} ** 6;
var paint_view_ns: u64 = 0;
var paint_art_ns: u64 = 0;
var paint_art_calls: u32 = 0;
var paint_frames: u64 = 0;
var paint_slow: u64 = 0;
var paint_total_ns: u64 = 0;
var paint_max_ns: u64 = 0;
var paint_report_ns: u64 = 0;
var last_paint_end_ns = std.atomic.Value(u64).init(0);
var last_refresh_start_ns = std.atomic.Value(u64).init(0);
var refresh_total_ns: u64 = 0;
var refresh_max_ns: u64 = 0;
var refresh_last_ns: u64 = 0;

const kSlowPaintNs: u64 = 5 * std.time.ns_per_ms;
const kSlowRefreshNs: u64 = 5 * std.time.ns_per_ms;

// ---------------------------------------------------------------------------
// Per-element budgets

/// The renderer is tuned so no single element — icon, artwork blit, surface
/// build, text layout — crosses 0.5ms. Anything that does is logged live with
/// the element's parameters (icon name, art URL, label text), so a slow
/// element can never hide inside a healthy frame average.
const kElementBudgetNs: u64 = std.time.ns_per_ms / 2;
/// `EH_CIDER_TRACE=1` also logs elements over this, which finds the 50-500us
/// coat-tails while tuning.
const kTraceElementNs: u64 = 50 * std.time.ns_per_us;

const PerfStat = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    over: u64 = 0,

    fn add(self: *PerfStat, ns: u64) void {
        self.calls +%= 1;
        self.total_ns +%= ns;
        if (ns > self.max_ns) self.max_ns = ns;
        if (ns >= kElementBudgetNs) self.over +%= 1;
    }

    fn reset(self: *PerfStat) void {
        self.* = .{};
    }

    fn avgUs(self: *const PerfStat) f64 {
        if (self.calls == 0) return 0;
        return @as(f64, @floatFromInt(self.total_ns / self.calls)) / 1000.0;
    }

    fn maxUs(self: *const PerfStat) f64 {
        return @as(f64, @floatFromInt(self.max_ns)) / 1000.0;
    }
};

var st_icon: PerfStat = .{};
var st_text: PerfStat = .{};
var st_art: PerfStat = .{};
var st_art_build: PerfStat = .{};
var st_art_load: PerfStat = .{};
var st_fallback: PerfStat = .{};
var st_card: PerfStat = .{};
var st_card_build: PerfStat = .{};
var st_halo: PerfStat = .{};
var st_view: PerfStat = .{};
var section_stats: [6]PerfStat = [_]PerfStat{.{}} ** 6;
var slow_elements: u64 = 0;

var art_hits: u64 = 0;
var art_misses: u64 = 0;
var fallback_hits: u64 = 0;
var fallback_misses: u64 = 0;
var card_rebuilds: u64 = 0;
var halo_rebuilds: u64 = 0;

/// Page being painted, so budget logs say where the slow element lives.
var perf_current_page: Page = .now_playing;

/// Records one element's cost and answers "was it over budget?".
fn noteBudget(stat: *PerfStat, ns: u64) bool {
    stat.add(ns);
    if (ns < kElementBudgetNs) return false;
    slow_elements +%= 1;
    return true;
}

fn traceSlow(ns: u64) bool {
    return traceEnabled() and ns >= kTraceElementNs;
}

fn resetElementStats() void {
    st_icon.reset();
    st_text.reset();
    st_art.reset();
    st_art_build.reset();
    st_art_load.reset();
    st_fallback.reset();
    st_card.reset();
    st_card_build.reset();
    st_halo.reset();
    st_view.reset();
    for (&section_stats) |*s| s.reset();
    slow_elements = 0;
    art_hits = 0;
    art_misses = 0;
    fallback_hits = 0;
    fallback_misses = 0;
    label_hits = 0;
    label_misses = 0;
    card_rebuilds = 0;
    halo_rebuilds = 0;
}

fn paintStarted() u64 {
    paint_art_ns = 0;
    paint_art_calls = 0;
    paint_sections_ns = [_]u64{0} ** 6;
    return nowNs();
}

fn paintFinished(page: Page, started_ns: u64) void {
    const now = nowNs();
    const dur = now -| started_ns;
    const prev_paint = last_paint_end_ns.load(.acquire);
    if (prev_paint != 0) {
        const gap = started_ns -| prev_paint;
        if (gap >= 500 * std.time.ns_per_ms and
            animFollowsCider(bus.get(), store.playbackState().playing()))
        {
            logz.log("perf: paint gap {d:.0}ms page={s}", .{ msFromNs(gap), @tagName(page) });
        }
    }
    last_paint_end_ns.store(now, .release);
    paint_view_ns = dur;
    paint_frames += 1;
    paint_total_ns += dur;
    if (dur > paint_max_ns) paint_max_ns = dur;
    if (dur >= kSlowPaintNs) {
        paint_slow += 1;
        logz.log(
            "perf: slow paint page={s} {d:.2}ms art={d:.2}ms/{d} card={d:.2} side={d:.2} head={d:.2} page={d:.2} player={d:.2} toast={d:.2}",
            .{ @tagName(page), msFromNs(dur), msFromNs(paint_art_ns), paint_art_calls, msFromNs(paint_sections_ns[perf_card]), msFromNs(paint_sections_ns[perf_sidebar]), msFromNs(paint_sections_ns[perf_header]), msFromNs(paint_sections_ns[perf_page]), msFromNs(paint_sections_ns[perf_player]), msFromNs(paint_sections_ns[perf_toast]) },
        );
    }
    if (perfEnabled()) {
        const report_now = nowNs();
        if (paint_report_ns == 0) paint_report_ns = report_now;
        if (report_now -| paint_report_ns >= 10 * std.time.ns_per_s) {
            const n = @max(paint_frames, 1);
            logz.log(
                "perf: paints={d} avg={d:.2}ms max={d:.2}ms slow={d} page={s}",
                .{ paint_frames, msFromNs(paint_total_ns / n), msFromNs(paint_max_ns), paint_slow, @tagName(page) },
            );
            logz.log(
                "perf: elem icon n={d} avg={d:.1}us max={d:.2}ms over={d} | text n={d} avg={d:.1}us max={d:.2}ms over={d} | view n={d} avg={d:.1}us max={d:.2}ms over={d}",
                .{
                    st_icon.calls, st_icon.avgUs(), msFromNs(st_icon.max_ns), st_icon.over,
                    st_text.calls, st_text.avgUs(), msFromNs(st_text.max_ns), st_text.over,
                    st_view.calls, st_view.avgUs(), msFromNs(st_view.max_ns), st_view.over,
                },
            );
            logz.log(
                "perf: elem art n={d} avg={d:.1}us max={d:.2}ms over={d} hit={d} miss={d} | build n={d} avg={d:.1}us max={d:.2}ms over={d} | fallback n={d} avg={d:.1}us max={d:.2}ms over={d} hit={d} miss={d} | load n={d} avg={d:.1}us max={d:.2}ms over={d}",
                .{
                    st_art.calls,                 st_art.avgUs(),       msFromNs(st_art.max_ns),       st_art.over,       art_hits,          art_misses,
                    st_art_build.calls,           st_art_build.avgUs(), msFromNs(st_art_build.max_ns), st_art_build.over, st_fallback.calls, st_fallback.avgUs(),
                    msFromNs(st_fallback.max_ns), st_fallback.over,     fallback_hits,                 fallback_misses,   st_art_load.calls, st_art_load.avgUs(),
                    msFromNs(st_art_load.max_ns), st_art_load.over,
                },
            );
            logz.log(
                "perf: elem card n={d} avg={d:.1}us max={d:.2}ms over={d} rebuild={d} | card-build n={d} avg={d:.1}us max={d:.2}ms over={d} | halo n={d} avg={d:.1}us max={d:.2}ms over={d} rebuild={d} | over_budget={d}",
                .{
                    st_card.calls,       st_card.avgUs(),          msFromNs(st_card.max_ns),       st_card.over,       card_rebuilds,
                    st_card_build.calls, st_card_build.avgUs(),    msFromNs(st_card_build.max_ns), st_card_build.over, st_halo.calls,
                    st_halo.avgUs(),     msFromNs(st_halo.max_ns), st_halo.over,                   halo_rebuilds,      slow_elements,
                },
            );
            const sig = svg_icons.cacheStats();
            logz.log(
                "perf: sect ms card={d:.2}/{d:.2} side={d:.2}/{d:.2} head={d:.2}/{d:.2} page={d:.2}/{d:.2} player={d:.2}/{d:.2} toast={d:.2}/{d:.2} | icon raster={d} hit={d}",
                .{
                    statAvgMs(&section_stats[0]), statMaxMs(&section_stats[0]),
                    statAvgMs(&section_stats[1]), statMaxMs(&section_stats[1]),
                    statAvgMs(&section_stats[2]), statMaxMs(&section_stats[2]),
                    statAvgMs(&section_stats[3]), statMaxMs(&section_stats[3]),
                    statAvgMs(&section_stats[4]), statMaxMs(&section_stats[4]),
                    statAvgMs(&section_stats[5]), statMaxMs(&section_stats[5]),
                    sig.rasters,                  sig.hits,
                },
            );
            paint_report_ns = report_now;
            paint_frames = 0;
            paint_total_ns = 0;
            paint_max_ns = 0;
            paint_slow = 0;
            resetElementStats();
        }
    }
}

fn statAvgMs(s: *const PerfStat) f64 {
    return s.avgUs() / 1000.0;
}

fn statMaxMs(s: *const PerfStat) f64 {
    return s.maxUs() / 1000.0;
}

/// Test-only: dump the per-element budget table to stderr so an offscreen
/// run (`EH_CIDER_PERF=1 EH_CIDER_PREVIEW=1 zig build test`) shows exactly
/// what the paint path costs without the wxlog file plumbing.
fn printCiderPerf(comptime phase: []const u8) void {
    const out = struct {
        fn line(what: []const u8, s: *const PerfStat) void {
            std.debug.print(
                "  {s:<11} n={d:<6} avg={d:.3}ms max={d:.3}ms over_budget={d}\n",
                .{ what, s.calls, s.avgUs() / 1000.0, s.maxUs() / 1000.0, s.over },
            );
        }
    };
    std.debug.print("cider-perf [{s}] (per-element, budget 0.500ms):\n", .{phase});
    out.line("icon", &st_icon);
    out.line("text", &st_text);
    out.line("view", &st_view);
    out.line("art", &st_art);
    out.line("art-build", &st_art_build);
    out.line("art-load", &st_art_load);
    out.line("fallback", &st_fallback);
    out.line("card", &st_card);
    out.line("card-build", &st_card_build);
    out.line("halo", &st_halo);
    std.debug.print(
        "  over_budget={d} label_hits={d} label_misses={d} art_hits={d} art_misses={d}\n",
        .{ slow_elements, label_hits, label_misses, art_hits, art_misses },
    );
}

fn msFromNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn setPerfSection(section: usize, started_ns: u64) void {
    const ns = nowNs() -| started_ns;
    paint_sections_ns[section] = ns;
    section_stats[section].add(ns);
}

// A stall watchdog is what turns "it froze sometimes" into a timestamp and a
// phase. It only writes when the UI thread has been stuck for 750ms.
const perf_idle: u8 = 0;
const perf_refresh: u8 = 1;
const perf_paint: u8 = 2;
var perf_phase = std.atomic.Value(u8).init(perf_idle);
var perf_phase_ns = std.atomic.Value(u64).init(0);
var watchdog_started = false;

fn setPhase(p: u8) void {
    perf_phase_ns.store(nowNs(), .release);
    perf_phase.store(p, .release);
}
fn clearPhase() void {
    perf_phase.store(perf_idle, .release);
    perf_phase_ns.store(0, .release);
}

fn watchdogMain() void {
    var stalled = false;
    var stall_start: u64 = 0;
    var last_log: u64 = 0;
    var forensics_done = false;
    while (true) {
        const ts = std.os.linux.timespec{ .sec = 0, .nsec = 250 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
        const phase = perf_phase.load(.acquire);
        const started = perf_phase_ns.load(.acquire);
        if (phase == perf_idle or started == 0) {
            if (stalled) {
                const total = nowNs() -| stall_start;
                logz.log("perf: UI recovered after {d:.0}ms stall", .{msFromNs(total)});
                stalled = false;
                stall_start = 0;
                last_log = 0;
                forensics_done = false;
            }
            // A refresh runs every service second. If the host stops calling
            // us while a frame was recently on screen, the main loop (not the
            // widget paint) is wedged. This catches stalls outside paint.
            const watch_now = nowNs();
            const last_refresh = last_refresh_start_ns.load(.acquire);
            const last_paint = last_paint_end_ns.load(.acquire);
            const recent_paint = last_paint != 0 and watch_now -| last_paint < 5 * std.time.ns_per_s;
            if (recent_paint and last_refresh != 0 and watch_now -| last_refresh > 2500 * std.time.ns_per_ms) {
                if (watch_now -| last_log >= 1000 * std.time.ns_per_ms) {
                    last_log = watch_now;
                    logz.log("perf: UI stalled {d:.0}ms (no refresh)", .{msFromNs(watch_now -| last_refresh)});
                    if (!forensics_done) {
                        forensics_done = true;
                        dumpStallForensics();
                    }
                }
            }
            continue;
        }
        const elapsed = nowNs() -| started;
        if (elapsed < 750 * std.time.ns_per_ms) continue;
        if (!stalled) {
            stalled = true;
            stall_start = started;
        }
        const now = nowNs();
        if (now -| last_log < 1000 * std.time.ns_per_ms) continue;
        last_log = now;
        logz.log(
            "perf: UI stalled {d:.0}ms phase={s}",
            .{ msFromNs(elapsed), if (phase == perf_refresh) "refresh" else "paint" },
        );
        if (!forensics_done) {
            forensics_done = true;
            dumpStallForensics();
        }
    }
}

/// Written once per stall (reset on recovery) from the watchdog thread while
/// the main thread is wedged: thread wait-channels, kernel stacks of every
/// task, and the fd table. This turns "froze for two minutes" into an exact
/// diagnosis instead of a live-gdb scramble.
fn dumpStallForensics() void {
    const linux = std.os.linux;
    logz.log("perf: stall evidence begin", .{});
    readProcLines("/proc/self/status", 14);
    // Threads: iterate /proc/self/task with getdents64 (no allocator); for
    // each task log tid, comm, and the kernel wait-channel. A wedged main
    // thread shows up here instantly (futex/poll skb/other wchan).
    var zdir: [64:0]u8 = [_:0]u8{0} ** 64;
    const dir_path = "/proc/self/task";
    @memcpy(zdir[0..dir_path.len], dir_path);
    const dfd: i32 = @intCast(linux.open(&zdir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0o644));
    if (dfd < 0) {
        logz.log("perf: stall evidence end (no task dir)", .{});
        return;
    }
    defer _ = linux.close(dfd);
    var dbuf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dfd, &dbuf, dbuf.len);
        if (n <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const de: *linux.dirent64 = @ptrCast(@alignCast(&dbuf[off]));
            off += @intCast(de.reclen);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&de.name)), 0);
            const tid = std.fmt.parseInt(i32, name, 10) catch continue;
            const wchan = readProcSlurp(tid, "wchan");
            const comm = readProcSlurp(tid, "comm");
            logz.log("perf: stall task tid={d} comm={s} wchan={s}", .{ tid, comm, wchan });
        }
    }
    logz.log("perf: stall evidence end", .{});
}

/// One scratch path buffer shared by the /proc readers (watchdog thread only).
var tidpath_buf: [160:0]u8 = [_:0]u8{0} ** 160;

/// Reads a small /proc file fully (<256 bytes), returning it as a trimmed
/// string. Uses raw syscalls: safe from the watchdog thread while the main
/// thread is wedged.
fn readProcSlurp(tid: i32, comptime tag: []const u8) []const u8 {
    const linux = std.os.linux;
    const path = std.fmt.bufPrintZ(&tidpath_buf, "/proc/self/task/{d}/" ++ tag, .{tid}) catch return "?";
    const fd: i32 = @intCast(linux.open(path.ptr, .{ .ACCMODE = .RDONLY }, 0o644));
    if (fd < 0) return "?";
    defer _ = linux.close(fd);
    var buf: [128]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len - 1);
    if (n <= 0) return "?";
    const s = buf[0..@intCast(n)];
    return std.mem.trim(u8, s, " \n\t");
}

/// Bounded /proc read, up to `lines` non-empty lines, straight through logz.
fn readProcLines(path: []const u8, lines: usize) void {
    const linux = std.os.linux;
    var zbuf: [256:0]u8 = [_:0]u8{0} ** 256;
    if (path.len + 1 > zbuf.len) return;
    @memcpy(zbuf[0..path.len], path);
    const fd: i32 = @intCast(linux.open(&zbuf, .{ .ACCMODE = .RDONLY }, 0o644));
    if (fd < 0) return;
    defer _ = linux.close(fd);
    var raw: [4096]u8 = undefined;
    var got: usize = 0;
    while (got < raw.len) {
        const n = linux.read(fd, raw[got..].ptr, raw.len - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    var it = std.mem.splitScalar(u8, raw[0..got], '\n');
    var i: usize = 0;
    while (it.next()) |line| {
        if (i >= lines) break;
        if (line.len == 0) continue;
        i += 1;
        logz.log("perf: stall {s}: {s}", .{ std.fs.path.basename(path), line[0..@min(line.len, 160)] });
    }
}

fn ensureWatchdog() void {
    if (builtin.is_test or watchdog_started) return;
    watchdog_started = true;
    const th = std.Thread.spawn(.{}, watchdogMain, .{}) catch return;
    th.detach();
}

fn refreshStarted() u64 {
    const now = nowNs();
    last_refresh_start_ns.store(now, .release);
    return now;
}

fn refreshFinished(started_ns: u64) void {
    const dur = nowNs() -| started_ns;
    refresh_last_ns = dur;
    if (dur > refresh_max_ns) refresh_max_ns = dur;
    if (dur >= kSlowRefreshNs or traceEnabled()) {
        logz.log("perf: refresh {d:.2}ms (max {d:.2}ms)", .{ msFromNs(dur), msFromNs(refresh_max_ns) });
    }
}

fn setToast(s: *State, msg: []const u8) void {
    copyInto(160, &s.toast, &s.toast_len, msg);
    s.toast_until = nowMs() + 3200;
    logz.log("cider: toast \"{s}\"", .{msg[0..@min(msg.len, 120)]});
}

fn setPage(s: *State, p: Page) void {
    if (s.page == p) return;
    logz.log("cider: page {s} -> {s}", .{ @tagName(s.page), @tagName(p) });
    s.page = p;
    s.hover = .{};
    switch (p) {
        .queue => {
            const st = store.snapshot();
            if (st.queue) |q| {
                s.queue_page = @intCast(@divTrunc(@max(q.position, 0), @as(i64, queue_rows)));
                s.queue_seen = true;
                s.queue_auto = true;
            } else {
                s.queue_seen = false;
            }
            store.invalidateQueue();
        },
        .library => {
            store.invalidateLibrary();
        },
        .lyrics => store.invalidateLyrics(),
        .connect => store.invalidateAudio(),
        else => {},
    }
}

fn pushFrame(s: *State, kind: cider.LibraryKind, id: []const u8, name: []const u8, subtitle: []const u8) void {
    logz.log("cider: library open kind={s} name=\"{s}\" subtitle=\"{s}\"", .{
        @tagName(kind), name[0..@min(name.len, 96)], subtitle[0..@min(subtitle.len, 96)],
    });
    s.back = s.frame;
    s.frame.set(kind, id, name, subtitle);
    s.lib_page = 0;
    store.invalidateLibrary();
}

fn goBack(s: *State) void {
    const to_name = if (s.frame.valid and s.back.valid) s.back.nameText() else "";
    logz.log("cider: library back -> \"{s}\"", .{to_name[0..@min(to_name.len, 96)]});
    if (s.frame.valid and s.back.valid) {
        s.frame = s.back;
        s.back.valid = false;
    } else {
        s.frame.valid = false;
        s.back.valid = false;
    }
    s.lib_page = 0;
    store.invalidateLibrary();
}

// ---------------------------------------------------------------------------
// Artwork cache

const ArtEntry = struct {
    url: [768]u8 = undefined,
    url_len: u16 = 0,
    cover: mpris_art.Cover = .{},
    last: u64 = 0,
    retry_ms: u64 = 0,
    /// Bumped whenever `cover` changes. Paint caches key off this instead of
    /// the pixel pointer, which can be recycled by the allocator.
    gen: u32 = 0,
};

var art_entries: [24]ArtEntry = [_]ArtEntry{.{}} ** 24;
var art_clock: u64 = 0;

fn artFind(url: []const u8) ?*ArtEntry {
    for (&art_entries) |*e| {
        if (e.url_len == url.len and std.mem.eql(u8, e.url[0..e.url_len], url)) return e;
    }
    return null;
}

fn artEntryFor(url: []const u8) ?*ArtEntry {
    if (artFind(url)) |e| {
        e.last = art_clock;
        return e;
    }
    var victim: ?*ArtEntry = null;
    for (&art_entries) |*e| {
        if (e.url_len == 0) {
            victim = e;
            break;
        }
        if (victim == null or e.last < victim.?.last) victim = e;
    }
    const e = victim orelse return null;
    if (e.cover.present()) e.cover.deinit(std.heap.page_allocator);
    const n = @min(url.len, e.url.len);
    @memcpy(e.url[0..n], url[0..n]);
    e.url_len = @intCast(n);
    e.cover = .{};
    e.retry_ms = 0;
    e.last = art_clock;
    e.gen +%= 1;
    return e;
}

fn artPump(io: std.Io) void {
    _ = io;
    const pump_t = nowNs();
    var applied: u32 = 0;
    while (true) {
        var res: cider_art_cache.Result = .{};
        if (!cider_art_cache.take(&res)) break;
        defer res.deinit(std.heap.page_allocator);
        applied +|= 1;
        {
            const u = res.url orelse "";
            const load_ms = @as(f64, @floatFromInt(res.elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
            const bytes: u64 = if (res.cover.present()) res.cover.pixels.len else 0;
            if (noteBudget(&st_art_load, res.elapsed_ns)) {
                logz.log("perf: budget art-load {d:.1}ms bytes={d} url={s}", .{
                    load_ms, bytes, u[0..@min(u.len, 96)],
                });
            } else if (traceEnabled()) {
                logz.log("perf: art-load {d:.2}ms bytes={d} url={s}", .{ load_ms, bytes, u[0..@min(u.len, 96)] });
            }
        }
        const url = res.url orelse continue;
        const e = artEntryFor(url) orelse continue;
        if (res.cover.present()) {
            if (e.cover.present()) e.cover.deinit(std.heap.page_allocator);
            e.cover = res.cover;
            res.cover = .{};
            e.retry_ms = 0;
            e.gen +%= 1;
        } else {
            e.retry_ms = nowMs() + 8_000;
        }
        e.last = art_clock;
        art_clock +%= 1;
    }
    const dur = nowNs() -| pump_t;
    if (dur >= 2 * std.time.ns_per_ms or (traceEnabled() and applied > 0)) {
        logz.log("perf: art apply {d:.2}ms results={d}", .{ msFromNs(dur), applied });
    }
}

fn artEnsure(io: std.Io, url: []const u8) void {
    if (url.len == 0 or url.len > 768) return;
    if (artFind(url)) |e| {
        e.last = art_clock;
        art_clock +%= 1;
        if (e.cover.present() or nowMs() < e.retry_ms) return;
    }
    const queued = cider_art_cache.request(std.heap.page_allocator, io, url);
    if (queued and traceEnabled()) {
        logz.log("cider: art request url={s}", .{url[0..@min(url.len, 96)]});
    }
}

fn artReset() void {
    logz.log("cider: art cache reset entries={d} surfaces={d}", .{ art_entries.len, art_surfaces.len });
    for (&fallback_slots) |*slot| {
        if (slot.surface) |old| cairo.cairo_surface_destroy(old);
        slot.* = .{};
    }
    for (&art_surfaces) |*slot| {
        if (slot.surface) |old| cairo.cairo_surface_destroy(old);
        slot.* = .{};
    }
    for (&art_entries) |*e| {
        if (e.cover.present()) e.cover.deinit(std.heap.page_allocator);
        e.* = .{};
    }
    art_clock = 0;
    art_surface_clock = 0;
    cider_art_cache.reset(std.heap.page_allocator);
}

fn ensureCovers(s: *State, io: std.Io) void {
    artPump(io);
    const v = viewFor(s);
    if (v.now.active and v.now.art.len > 0) artEnsure(io, v.now.art);
    switch (s.page) {
        .now_playing => {
            if (v.st.queue) |q| {
                var j: usize = 0;
                while (j < 3) : (j += 1) {
                    const idx = @as(usize, @intCast(@max(q.position + 1, 0))) + j;
                    if (idx >= q.items.len) break;
                    artEnsure(io, q.items[idx].art_url);
                }
            }
        },
        .queue => {
            if (v.st.queue) |q| {
                const start = s.queue_page * queue_rows;
                var j: usize = 0;
                while (j < queue_rows) : (j += 1) {
                    const idx = start + j;
                    if (idx >= q.items.len) break;
                    artEnsure(io, q.items[idx].art_url);
                }
            }
        },
        .library => {
            if (visibleLibrary(s, &v)) |p| {
                const start = s.lib_page * libPageSize(s);
                var j: usize = 0;
                while (j < libRowCount(s)) : (j += 1) {
                    const idx = start + j;
                    if (idx >= p.items.len) break;
                    artEnsure(io, p.items[idx].art_url);
                }
            }
        },
        .lyrics, .connect => {},
    }
}

// ---------------------------------------------------------------------------
// Hit testing

const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    fn has(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

const Target = struct {
    kind: Kind = .none,
    index: usize = 0,
    value: f64 = 0,

    const Kind = enum {
        none,
        nav,
        search,
        header_search,
        header_open,
        status_pill,
        connect_cta,
        mini,
        play,
        prev,
        next,
        shuffle,
        repeat,
        seek,
        queue_icon,
        lyrics_icon,
        volume_icon,
        volume,
        like,
        add,
        lyrics_pill,
        queue_pill,
        upnext,
        upnext_open,
        lyrics_strip,
        queue_row,
        queue_remove,
        qprev,
        qnext,
        lib_tab,
        lib_row,
        lib_add,
        lib_back,
        lib_play,
        lib_prev,
        lib_next,
        lyric_line,
        auth,
        recheck,
        audio_row,
        connect_volume,
        party,
        search_cider,
        audio_listen,
        open_cider,
    };
};

fn navRect(i: usize) Rect {
    return .{ .x = 18, .y = 82 + @as(f64, @floatFromInt(i)) * 54, .w = 48, .h = 48 };
}

fn libTabRect(i: usize) Rect {
    return switch (i) {
        0 => .{ .x = 112, .y = 90, .w = 80, .h = 28 },
        1 => .{ .x = 200, .y = 90, .w = 68, .h = 28 },
        2 => .{ .x = 276, .y = 90, .w = 66, .h = 28 },
        else => .{ .x = 350, .y = 90, .w = 74, .h = 28 },
    };
}

fn libRowsTop(s: *const State) f64 {
    return if (s.frame.valid) 92.0 else 132.0;
}

fn libPageSize(s: *const State) usize {
    return if (s.frame.valid) library_rows_collection else library_rows_top;
}

fn libLoadedTotal(p: *const cider.LibraryPage) usize {
    const n: usize = @intCast(@max(p.total, 0));
    if (n == 0) return p.items.len;
    return @min(n, p.items.len);
}

fn libPages(s: *const State, p: *const cider.LibraryPage) usize {
    const total = libLoadedTotal(p);
    return @max(@as(usize, 1), (total + libPageSize(s) - 1) / libPageSize(s));
}

fn queueLoadedTotal(q: *const cider.QueuePage) usize {
    const n: usize = @intCast(@max(q.total, 0));
    if (n == 0) return q.items.len;
    return @min(n, q.items.len);
}

fn queuePages(q: *const cider.QueuePage) usize {
    const total = queueLoadedTotal(q);
    return @max(@as(usize, 1), (total + queue_rows - 1) / queue_rows);
}

fn libRowCount(s: *const State) usize {
    return libPageSize(s);
}

fn libRowRect(s: *const State, i: usize) Rect {
    return .{
        .x = 112,
        .y = libRowsTop(s) + @as(f64, @floatFromInt(i)) * row_step,
        .w = 764,
        .h = row_h,
    };
}

fn queueRowRect(i: usize) Rect {
    return .{
        .x = 112,
        .y = 92 + @as(f64, @floatFromInt(i)) * 48,
        .w = 764,
        .h = 44,
    };
}

fn nowArtRect() Rect {
    return .{ .x = 112, .y = 96, .w = 252, .h = 252 };
}

fn nowQueuePanelRect() Rect {
    return .{ .x = 688, .y = 96, .w = 180, .h = 252 };
}

fn upNextRect(j: usize) Rect {
    return .{ .x = 696, .y = 138 + @as(f64, @floatFromInt(j)) * 38, .w = 164, .h = 32 };
}

fn lyricsStripRect() Rect {
    return .{ .x = 112, .y = 368, .w = 756, .h = 118 };
}

fn connectCtaRect() Rect {
    return .{ .x = 409, .y = 322, .w = 82, .h = 30 };
}

const NowTextLayout = struct { artist_y: f64, album_y: f64, chips_y: f64, actions_y: f64, from_y: f64 };

fn nowTextLayout(v: *const View) NowTextLayout {
    // The title region is capped at two lines; a short title lets the rest of
    // the block rise instead of leaving a hole under it.
    const title_h: f64 = if (v.now.active and v.now.title.len > 20) 68 else 34;
    const artist_y = 116 + title_h + 8;
    const album_y = artist_y + 21;
    const chips_y = album_y + 25;
    const actions_y = chips_y + 42;
    return .{ .artist_y = artist_y, .album_y = album_y, .chips_y = chips_y, .actions_y = actions_y, .from_y = actions_y + 46 };
}

fn lyricLineRect(offset: i32) Rect {
    return .{
        .x = 112,
        .y = 286 + @as(f64, @floatFromInt(offset)) * 46 - 20,
        .w = 764,
        .h = 40,
    };
}

fn targetAt(s: *const State, x: f64, y: f64) Target {
    if (x < 0 or y < 0 or x >= kw or y >= kh) return .{};

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (navRect(i).has(x, y)) return .{ .kind = .nav, .index = i };
    }
    if ((Rect{ .x = 18, .y = 444, .w = 48, .h = 48 }).has(x, y)) return .{ .kind = .search };

    // The connection pill is painted on every page and always opens Connect.
    if ((Rect{ .x = 640, .y = 22, .w = 112, .h = 24 }).has(x, y)) return .{ .kind = .status_pill };

    if (s.page == .library and s.frame.valid) {
        if ((Rect{ .x = 780, .y = 20, .w = 84, .h = 30 }).has(x, y)) return .{ .kind = .lib_play };
        if ((Rect{ .x = 106, .y = 18, .w = 26, .h = 26 }).has(x, y)) return .{ .kind = .lib_back };
    } else {
        if ((Rect{ .x = 764, .y = 22, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .header_search };
        if ((Rect{ .x = 800, .y = 22, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .header_open };
    }

    // Persistent transport strip.
    if (y >= 500 and y <= 514 and x >= player_x + 16 and x <= player_x + player_w - 16)
        return .{ .kind = .seek, .value = std.math.clamp((x - (player_x + 16)) / (player_w - 32), 0, 1) };
    if ((Rect{ .x = 116, .y = 514, .w = 224, .h = 38 }).has(x, y)) return .{ .kind = .mini };
    if ((Rect{ .x = 344, .y = 519, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .shuffle };
    if ((Rect{ .x = 384, .y = 519, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .prev };
    if ((Rect{ .x = 418, .y = 513, .w = 40, .h = 40 }).has(x, y)) return .{ .kind = .play };
    if ((Rect{ .x = 464, .y = 519, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .next };
    if ((Rect{ .x = 504, .y = 519, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .repeat };
    if ((Rect{ .x = 676, .y = 519, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .queue_icon };
    if ((Rect{ .x = 714, .y = 519, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .lyrics_icon };
    if ((Rect{ .x = 766, .y = 519, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .volume_icon };
    if ((Rect{ .x = 802, .y = 524, .w = 60, .h = 18 }).has(x, y))
        return .{ .kind = .volume, .value = std.math.clamp((x - 802) / 60, 0, 1) };

    switch (s.page) {
        .now_playing => {
            const v = viewFor(@constCast(s));
            const nl = nowTextLayout(&v);
            if ((Rect{ .x = 384, .y = nl.actions_y - 2, .w = 32, .h = 32 }).has(x, y)) return .{ .kind = .like };
            if ((Rect{ .x = 424, .y = nl.actions_y - 2, .w = 32, .h = 32 }).has(x, y)) return .{ .kind = .add };
            if ((Rect{ .x = 464, .y = nl.actions_y, .w = 72, .h = 32 }).has(x, y)) return .{ .kind = .lyrics_pill };
            if ((Rect{ .x = 544, .y = nl.actions_y, .w = 68, .h = 32 }).has(x, y)) return .{ .kind = .queue_pill };
            var up_count: usize = 0;
            if (v.st.queue) |q| {
                const base = @as(usize, @intCast(@max(q.position + 1, 0)));
                if (base < q.items.len) up_count = @min(3, q.items.len - base);
            }
            var j: usize = 0;
            while (j < up_count) : (j += 1) {
                if (upNextRect(j).has(x, y)) return .{ .kind = .upnext, .index = j };
            }
            if ((Rect{ .x = 696, .y = 312, .w = 164, .h = 30 }).has(x, y)) return .{ .kind = .upnext_open };
            if (lyricsStripRect().has(x, y)) return .{ .kind = .lyrics_strip };
        },
        .queue => {
            const st = store.snapshot();
            const start = s.queue_page * queue_rows;
            const count = if (st.queue) |q| @min(queue_rows, q.items.len -| start) else 0;
            var j: usize = 0;
            while (j < count) : (j += 1) {
                const r = queueRowRect(j);
                const current = if (st.queue) |q| start + j == q.position else false;
                if (!current and (Rect{ .x = r.x + r.w - 34, .y = r.y + 8, .w = 28, .h = 28 }).has(x, y))
                    return .{ .kind = .queue_remove, .index = j };
                if (r.has(x, y)) return .{ .kind = .queue_row, .index = j };
            }
            if ((Rect{ .x = 808, .y = 442, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .qprev };
            if ((Rect{ .x = 844, .y = 442, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .qnext };
            if (st.queue == null and st.link != .connected and connectCtaRect().has(x, y))
                return .{ .kind = .connect_cta };
        },
        .library => {
            if (!s.frame.valid) {
                var t: usize = 0;
                while (t < 4) : (t += 1) {
                    if (libTabRect(t).has(x, y)) return .{ .kind = .lib_tab, .index = t };
                }
                if ((Rect{ .x = 786, .y = 90, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .lib_prev };
                if ((Rect{ .x = 822, .y = 90, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .lib_next };
            } else {
                if ((Rect{ .x = 808, .y = 458, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .lib_prev };
                if ((Rect{ .x = 844, .y = 458, .w = 28, .h = 28 }).has(x, y)) return .{ .kind = .lib_next };
            }
            const v = viewFor(@constCast(s));
            const start = s.lib_page * libPageSize(s);
            const count = if (visibleLibrary(s, &v)) |p| @min(libRowCount(s), p.items.len -| start) else 0;
            var j: usize = 0;
            while (j < count) : (j += 1) {
                const r = libRowRect(s, j);
                if (activeKind(s).isSongs() and (Rect{ .x = r.x + r.w - 36, .y = r.y + 7, .w = 28, .h = 28 }).has(x, y))
                    return .{ .kind = .lib_add, .index = j };
                if (r.has(x, y)) return .{ .kind = .lib_row, .index = j };
            }
            if (visibleLibrary(s, &v) == null and v.st.link != .connected and connectCtaRect().has(x, y))
                return .{ .kind = .connect_cta };
        },
        .lyrics => {
            const idx = lyricIndexAt(s);
            var off: i32 = -3;
            while (off <= 3) : (off += 1) {
                if (idx >= 0 and lyricLineRect(off).has(x, y)) {
                    const absolute: i32 = idx + off;
                    if (absolute >= 0) return .{ .kind = .lyric_line, .index = @intCast(absolute) };
                }
            }
        },
        .connect => {
            if ((Rect{ .x = 282, .y = 212, .w = 96, .h = 30 }).has(x, y)) return .{ .kind = .open_cider };
            if ((Rect{ .x = 124, .y = 212, .w = 148, .h = 30 }).has(x, y)) return .{ .kind = .auth };
            var a: usize = 0;
            while (a < 5) : (a += 1) {
                if ((Rect{ .x = 512, .y = 124 + @as(f64, @floatFromInt(a)) * 26, .w = 348, .h = 28 }).has(x, y))
                    return if (a == 4) .{ .kind = .audio_listen } else .{ .kind = .audio_row, .index = a };
            }
            if ((Rect{ .x = 632, .y = 256, .w = 224, .h = 24 }).has(x, y))
                return .{ .kind = .connect_volume, .value = std.math.clamp((x - 640) / 200, 0, 1) };
            if ((Rect{ .x = 124, .y = 416, .w = 132, .h = 32 }).has(x, y)) return .{ .kind = .party };
            if ((Rect{ .x = 512, .y = 416, .w = 140, .h = 32 }).has(x, y)) return .{ .kind = .search_cider };
        },
    }
    return .{};
}

pub fn motion(s: *State, x: f64, y: f64) void {
    s.hover = targetAt(s, x, y);
}

pub fn click(s: *State, x: f64, y: f64) bool {
    if (!s.io_ready) {
        setToast(s, "Cider is starting");
        return true;
    }
    const t = targetAt(s, x, y);
    if (t.kind == .none) return false;
    const io = s.io;

    switch (t.kind) {
        .nav => setPage(s, switch (t.index) {
            0 => .now_playing,
            1 => .queue,
            2 => .library,
            3 => .lyrics,
            else => .connect,
        }),
        .mini => setPage(s, .now_playing),
        .search, .header_search, .search_cider => {
            if (launchCider(io)) setToast(s, "Opened Cider") else setToast(s, "Could not open Cider");
        },
        .header_open, .upnext_open, .queue_pill, .queue_icon => setPage(s, .queue),
        .status_pill, .connect_cta => setPage(s, .connect),
        .open_cider => {
            if (launchCider(io)) setToast(s, "Opened Cider") else setToast(s, "Could not open Cider");
        },
        .none => {},
        .lyrics_pill, .lyrics_strip, .lyrics_icon => setPage(s, .lyrics),
        .volume_icon => setPage(s, .connect),
        .party => {
            if (launchCider(io)) setToast(s, "Opened Cider") else setToast(s, "Could not open Cider");
        },
        .play => controlToggle(s, io),
        .prev => controlPrevious(s, io),
        .next => controlNext(s, io),
        .shuffle => controlShuffle(s, io),
        .repeat => controlLoop(s, io),
        .seek => controlSeek(s, io, t.value),
        .volume, .connect_volume => {
            if (!store.connected() or !store.tokenScopes().has(.audio)) {
                setToast(s, "Connect Cider with audio access");
                return true;
            }
            if (store.actionVolume(io, t.value)) setToast(s, "Volume updated") else setToast(s, "Connect Cider to change volume");
        },
        .like => {
            if (!store.connected() or !store.tokenScopes().has(.library)) {
                setToast(s, "Connect Cider with library access");
                return true;
            }
            const st = store.snapshot();
            const on = st.now.rating != 1;
            if (store.actionLove(io, on)) setToast(s, if (on) "Added to favourites" else "Removed from favourites");
        },
        .add => {
            if (!store.connected() or !store.tokenScopes().has(.library)) {
                setToast(s, "Connect Cider with library access");
                return true;
            }
            const st = store.snapshot();
            const on = !st.now.in_library;
            if (store.actionAddLibrary(io, on)) setToast(s, if (on) "Added to your library" else "Removed from your library");
        },
        .upnext => {
            const st = store.snapshot();
            if (st.queue) |q| {
                const idx = @max(q.position + 1, 0) + @as(i64, @intCast(t.index));
                if (idx >= 0 and idx < @as(i64, @intCast(q.items.len)) and store.actionQueueJump(io, idx)) {
                    s.queue_auto = true;
                    setToast(s, "Jumped in the queue");
                }
            }
        },
        .queue_row => {
            const idx: i64 = @intCast(s.queue_page * queue_rows + t.index);
            if (store.snapshot().queue) |q| {
                if (idx < q.items.len and store.actionQueueJump(io, idx)) {
                    s.queue_auto = true;
                    setToast(s, "Jumped in the queue");
                }
            }
        },
        .queue_remove => {
            const idx: i64 = @intCast(s.queue_page * queue_rows + t.index);
            if (store.snapshot().queue) |q| {
                if (idx < q.items.len and store.actionQueueRemove(io, idx)) setToast(s, "Removed from the queue");
            }
        },
        .qprev => if (s.queue_page > 0) {
            s.queue_page -= 1;
            s.queue_auto = false;
        },
        .qnext => {
            const st = store.snapshot();
            if (st.queue) |q| {
                if (s.queue_page + 1 < queuePages(q)) s.queue_page += 1;
            }
            s.queue_auto = false;
        },
        .lib_tab => {
            s.lib_tab = switch (t.index) {
                0 => .playlists,
                1 => .albums,
                2 => .songs,
                else => .artists,
            };
            s.frame.valid = false;
            s.back.valid = false;
            s.lib_page = 0;
            store.invalidateLibrary();
        },
        .lib_row => openLibraryRow(s, t.index),
        .lib_add => {
            const v = viewFor(s);
            if (!store.connected() or !store.tokenScopes().has(.queue)) {
                setToast(s, "Connect Cider with queue access");
                return true;
            }
            if (visibleLibrary(s, &v)) |p| {
                const idx = s.lib_page * libPageSize(s) + t.index;
                if (idx < p.items.len) {
                    if (store.actionAddNext(io, "library-songs", p.items[idx].id))
                        setToast(s, "Playing next")
                    else
                        setToast(s, "Connect Cider to edit the queue");
                }
            }
        },
        .lib_back => goBack(s),
        .lib_play => playCollection(s),
        .lib_prev => if (s.lib_page > 0) {
            s.lib_page -= 1;
        },
        .lib_next => {
            const v = viewFor(s);
            if (visibleLibrary(s, &v)) |p| {
                if (s.lib_page + 1 < libPages(s, p)) s.lib_page += 1;
            }
        },
        .lyric_line => {
            const v = viewFor(s);
            if (v.st.lyrics) |ly| {
                if (t.index < ly.lines.len) controlSeekSeconds(s, io, ly.lines[t.index].start);
            }
        },
        .auth => {
            if (store.connected()) {
                store.recheck(io);
                setToast(s, "Checking Cider…");
            } else if (store.requestAuth(io)) {
                setToast(s, "Approve the request in Cider");
            } else {
                setToast(s, "Cider is busy; try again");
            }
        },
        .recheck => {
            store.recheck(io);
            setToast(s, "Checking Cider…");
        },
        .audio_listen => {
            if (!store.tokenScopes().has(.audio)) {
                setToast(s, "Connect Cider with audio access");
                return true;
            }
            const mode: cider.ListeningMode = switch (store.snapshot().audio.listening) {
                .off => .game,
                .game => .antifatigue,
                .antifatigue => .off,
            };
            if (store.actionListening(io, mode)) {
                setToast(s, switch (mode) {
                    .off => "Listening mode off",
                    .game => "Game listening mode",
                    .antifatigue => "Anti-fatigue listening mode",
                });
            } else {
                setToast(s, "Connect Cider to change listening mode");
            }
        },
        .audio_row => {
            if (!store.tokenScopes().has(.audio)) {
                setToast(s, "Connect Cider with audio access");
                return true;
            }
            const st = store.snapshot();
            const on = switch (t.index) {
                0 => !st.audio.crossfade,
                1 => !st.audio.automix,
                2 => !st.audio.normalization,
                else => !st.audio.atmos,
            };
            const what: []const u8 = switch (t.index) {
                0 => "crossfade",
                1 => "automix",
                2 => "normalization",
                else => "atmos",
            };
            _ = store.actionAudioBool(io, what, on);
        },
    }
    return true;
}

fn openLibraryRow(s: *State, index: usize) void {
    const v = viewFor(s);
    const p = visibleLibrary(s, &v) orelse return;
    const idx = s.lib_page * libPageSize(s) + index;
    if (idx >= p.items.len) return;
    const item = p.items[idx];
    switch (activeKind(s)) {
        .playlists => pushFrame(s, .playlist_songs, item.id, item.name, "Playlist"),
        .albums => pushFrame(s, .album_songs, item.id, item.name, item.subtitle),
        .artists => pushFrame(s, .artist_albums, item.id, item.name, "Artist"),
        .artist_albums => pushFrame(s, .album_songs, item.id, item.name, item.subtitle),
        .songs, .playlist_songs, .album_songs => {
            if (!store.connected() or !store.tokenScopes().has(.playback)) {
                setToast(s, "Connect Cider with playback access");
                return;
            }
            if (store.actionPlayItem(s.io, "library-songs", item.id))
                setToast(s, "Playing in Cider")
            else
                setToast(s, "Connect Cider to play library tracks");
        },
    }
}

fn playCollection(s: *State) void {
    if (!s.frame.valid) return;
    if (!store.connected() or !store.tokenScopes().has(.playback)) {
        setToast(s, "Connect Cider with playback access");
        return;
    }
    const typ: []const u8 = switch (s.frame.kind) {
        .playlist_songs => "library-playlists",
        .album_songs => "library-albums",
        .artist_albums => "library-artists",
        else => return,
    };
    if (store.actionPlayCollection(s.io, typ, s.frame.idText()))
        setToast(s, "Playing in Cider")
    else
        setToast(s, "Connect Cider to play this collection");
}

fn controlToggle(s: *State, io: std.Io) void {
    const snap = bus.get();
    if (snap.have_player and busIsCider(snap.bus_name)) {
        _ = bus.dispatch(.play_pause, 0);
    } else if (store.connected()) {
        _ = store.actionPlaybackToggle(io);
    } else {
        setToast(s, "Connect Cider to control playback");
    }
    store.invalidateNow();
}

fn controlNext(s: *State, io: std.Io) void {
    const snap = bus.get();
    if (snap.have_player and busIsCider(snap.bus_name)) {
        _ = bus.dispatch(.next, 0);
    } else if (store.connected()) {
        _ = store.actionPlaybackNext(io);
    } else {
        setToast(s, "Connect Cider to control playback");
    }
    store.invalidateNow();
    store.invalidateQueue();
}

fn controlPrevious(s: *State, io: std.Io) void {
    const snap = bus.get();
    if (snap.have_player and busIsCider(snap.bus_name)) {
        _ = bus.dispatch(.previous, 0);
    } else if (store.connected()) {
        _ = store.actionPlaybackPrevious(io);
    } else {
        setToast(s, "Connect Cider to control playback");
    }
    store.invalidateNow();
}

fn controlShuffle(s: *State, io: std.Io) void {
    const snap = bus.get();
    if (snap.have_player and busIsCider(snap.bus_name)) {
        _ = bus.dispatch(.shuffle, 0);
    } else if (store.connected()) {
        _ = store.actionPlaybackShuffle(io);
    } else {
        setToast(s, "Connect Cider to control shuffle");
    }
    store.invalidateNow();
}

fn controlLoop(s: *State, io: std.Io) void {
    const snap = bus.get();
    if (snap.have_player and busIsCider(snap.bus_name)) {
        _ = bus.dispatch(.loop, 0);
    } else if (store.connected()) {
        _ = store.actionPlaybackRepeat(io);
    } else {
        setToast(s, "Connect Cider to control repeat");
    }
    store.invalidateNow();
}

fn controlSeek(s: *State, io: std.Io, fraction: f64) void {
    const v = viewFor(s);
    if (v.now.duration_ms <= 0) return;
    controlSeekSeconds(s, io, @as(f64, @floatFromInt(v.now.duration_ms)) * fraction / 1000.0);
}

fn controlSeekSeconds(s: *State, io: std.Io, seconds: f64) void {
    const snap = bus.get();
    if (snap.have_player and busIsCider(snap.bus_name)) {
        _ = bus.dispatch(.seek, @intFromFloat(@max(seconds, 0) * 1_000_000.0));
    } else if (store.connected()) {
        _ = store.actionPlaybackSeek(io, seconds);
    } else {
        setToast(s, "Connect Cider to seek");
    }
    store.invalidateNow();
}

fn launchCider(io: std.Io) bool {
    if (@import("builtin").is_test) return true;
    const a = std.heap.page_allocator;
    const xdg = if (std.c.getenv("XDG_DATA_HOME")) |p| std.mem.span(p) else null;
    const home = if (std.c.getenv("HOME")) |p| std.mem.span(p) else null;
    const dirs_env = if (std.c.getenv("XDG_DATA_DIRS")) |p| std.mem.span(p) else null;
    const dirs = app_launch.applicationsDirs(a, xdg, home, dirs_env) catch return false;
    defer app_launch.freeDirs(a, dirs);
    if (app_launch.launch(a, io, dirs, "sh.cider.Cider")) return true;
    return app_launch.launchExec(a, io, "flatpak run sh.cider.Cider");
}

fn lyricIndexAt(s: *const State) i32 {
    const ly = store.snapshot().lyrics orelse return -1;
    const snap = bus.get();
    const st = store.snapshot();
    var pos_ms: i64 = @divTrunc(snap.position_us, 1000);
    if (!(snap.have_player and busIsCider(snap.bus_name)) and st.playback.available) {
        pos_ms = st.playback.position_ms;
        if (st.playback.playing()) pos_ms += elapsedMs(st.playback_at_ms);
    }
    const pos = @as(f64, @floatFromInt(pos_ms)) / 1000.0;
    var active: i32 = -1;
    for (ly.lines, 0..) |line, i| {
        if (line.start <= pos + 0.15) active = @intCast(i) else break;
    }
    _ = s;
    return active;
}

// ---------------------------------------------------------------------------
// Paint primitives

fn roundRect(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const c = cr orelse return;
    const rr = @min(r, @min(w, h) * 0.5);
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, x + w - rr, y + rr, rr, -std.math.pi * 0.5, 0);
    cairo.cairo_arc(c, x + w - rr, y + h - rr, rr, 0, std.math.pi * 0.5);
    cairo.cairo_arc(c, x + rr, y + h - rr, rr, std.math.pi * 0.5, std.math.pi);
    cairo.cairo_arc(c, x + rr, y + rr, rr, std.math.pi, std.math.pi * 1.5);
    cairo.cairo_close_path(c);
}

fn setColor(c: ?*cairo.cairo_t, col: [3]f64, a: f64) void {
    cairo.cairo_set_source_rgba(c, col[0], col[1], col[2], a);
}

fn fillRound(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, col: [3]f64, a: f64) void {
    roundRect(cr, x, y, w, h, r);
    setColor(cr, col, a);
    cairo.cairo_fill(cr);
}

fn strokeRound(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, col: [3]f64, a: f64, width: f64) void {
    roundRect(cr, x, y, w, h, r);
    setColor(cr, col, a);
    cairo.cairo_set_line_width(cr, width);
    cairo.cairo_stroke(cr);
}

fn clipRound(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    roundRect(cr, x, y, w, h, r);
    cairo.cairo_clip(cr);
}

fn linearFill(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, a: [3]f64, aa: f64, b: [3]f64, ba: f64) void {
    const pat = cairo.cairo_pattern_create_linear(x, y, x + w, y + h);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0, a[0], a[1], a[2], aa);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 1, b[0], b[1], b[2], ba);
    roundRect(cr, x, y, w, h, r);
    cairo.cairo_set_source(cr, pat);
    cairo.cairo_fill(cr);
    cairo.cairo_pattern_destroy(pat);
}

fn applyFont(l: *text.Layout, px: f64, weight: c_uint) void {
    var buf: [64]u8 = undefined;
    const desc = std.fmt.bufPrint(&buf, "Inter {d:.1}", .{px}) catch "Inter 12";
    l.setFont(desc);
    l.setWeight(weight);
}

const TextMode = enum(u8) {
    plain,
    ellipsis,
    wrap,
    paragraph,
    center,
    right,
};

const TextEntry = struct {
    layout: text.Layout = .{},
    text: []u8 = &.{},
    hash: u64 = 0,
    mode: TextMode = .plain,
    px_q: i32 = 0,
    weight: u16 = 0,
    width_q: i32 = 0,
    last: u64 = 0,
};

// Pango layout construction (font-description parsing, shaping, line
// breaking) was the single largest remaining cost after the card/art caches.
// These labels repeat every frame, so keep up to 192 shaped layouts and just
// re-bind them to the current Cairo context. Pango's update call makes the
// cached layout honour the current transform before measuring/showing it.
const text_cache_cap = 192;
var text_cache: [text_cache_cap]TextEntry = [_]TextEntry{.{}} ** text_cache_cap;
var text_clock: u64 = 0;

fn layoutFor(
    cr: ?*cairo.cairo_t,
    str: []const u8,
    px: f64,
    weight: c_uint,
    width: f64,
    mode: TextMode,
) ?*text.Layout {
    if (str.len == 0) return null;
    const px_q: i32 = @intFromFloat(@round(px * 16.0));
    const width_q: i32 = @intFromFloat(@round(width * 16.0));
    const hash = std.hash.Wyhash.hash(0, str);
    for (&text_cache) |*entry| {
        if (entry.layout.layout == null or entry.hash != hash or entry.mode != mode or
            entry.px_q != px_q or entry.weight != @as(u16, @intCast(weight)) or
            entry.width_q != width_q or entry.text.len != str.len) continue;
        if (!std.mem.eql(u8, entry.text, str)) continue;
        entry.last = text_clock;
        text_clock +%= 1;
        entry.layout.update(cr);
        return &entry.layout;
    }

    var victim: ?*TextEntry = null;
    for (&text_cache) |*entry| {
        if (entry.layout.layout == null) {
            victim = entry;
            break;
        }
        if (victim == null or entry.last < victim.?.last) victim = entry;
    }
    const entry = victim orelse return null;
    const owned = std.heap.page_allocator.dupe(u8, str) catch return null;
    if (entry.layout.layout != null) entry.layout.destroy();
    if (entry.text.len > 0) std.heap.page_allocator.free(entry.text);
    entry.* = .{
        .text = owned,
        .hash = hash,
        .mode = mode,
        .px_q = px_q,
        .weight = @intCast(weight),
        .width_q = width_q,
        .last = text_clock,
    };
    text_clock +%= 1;
    entry.layout = text.Layout.createForCairo(cr);
    if (entry.layout.layout == null) {
        std.heap.page_allocator.free(entry.text);
        entry.text = &.{};
        return null;
    }
    applyFont(&entry.layout, px, weight);
    entry.layout.setText(str);
    switch (mode) {
        .plain => {},
        .ellipsis => {
            entry.layout.setWidthUnits(@intFromFloat(width * 1024.0));
            entry.layout.setEllipsize(text.ELLIPSIZE_END);
        },
        .wrap => {
            entry.layout.setWidthUnits(@intFromFloat(width * 1024.0));
            entry.layout.setWrap(text.WRAP_WORD_CHAR);
            entry.layout.setEllipsize(text.ELLIPSIZE_END);
        },
        .paragraph => {
            entry.layout.setWidthUnits(@intFromFloat(width * 1024.0));
            entry.layout.setWrap(text.WRAP_WORD_CHAR);
        },
        .center => {
            entry.layout.setWidthUnits(@intFromFloat(width * 1024.0));
            entry.layout.setAlignment(text.ALIGN_CENTER);
            entry.layout.setEllipsize(text.ELLIPSIZE_END);
        },
        .right => {
            entry.layout.setWidthUnits(@intFromFloat(width * 1024.0));
            entry.layout.setAlignment(text.ALIGN_RIGHT);
            entry.layout.setEllipsize(text.ELLIPSIZE_END);
        },
    }
    entry.layout.update(cr);
    return &entry.layout;
}

fn textWidth(cr: ?*cairo.cairo_t, str: []const u8, px: f64, weight: c_uint, maxw: f64) f64 {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    const l = layoutFor(cr, str, px, weight, maxw, if (maxw > 0) .ellipsis else .plain) orelse return 0;
    return @floatFromInt(l.pixelSize().w);
}

fn noteText(ns: u64, str: []const u8, px: f64) void {
    if (noteBudget(&st_text, ns)) {
        logz.log("perf: budget text {d:.2}ms px={d:.1} len={d} page={s} \"{s}\"", .{
            msFromNs(ns), px, str.len, @tagName(perf_current_page), str[0..@min(str.len, 64)],
        });
    } else if (traceSlow(ns)) {
        logz.log("perf: text {d:.0}us px={d:.1} len={d}", .{ ns / std.time.ns_per_us, px, str.len });
    }
}

// ---------------------------------------------------------------------------
// Label raster cache

// After the shaped-layout cache, the remaining label cost is pango
// re-rasterising the same glyphs every frame (~0.15ms per label). Rendered
// labels are cached as ARGB surfaces keyed by (string, font, colour,
// position), so a steady-state frame is small blits — the same pattern the
// icons, artwork and card glass already use.
const LabelTag = enum(u8) { plain, ellipsis, wrap, paragraph, center, right, box, cy, right_cy };

const LabelSlot = struct {
    key: u64 = 0,
    surface: ?*cairo.cairo_surface_t = null,
    /// Blit origin relative to the anchor (x, y) the label was drawn at.
    dx: f64 = 0,
    dy: f64 = 0,
    /// Layout pixel height, for wrap-style callers that return it.
    h: f64 = 0,
    scale: u32 = 1,
    last: u64 = 0,
};
const label_cache_cap = 192;
var label_cache: [label_cache_cap]LabelSlot = [_]LabelSlot{.{}} ** label_cache_cap;
var label_clock: u64 = 0;
var label_hits: u64 = 0;
var label_misses: u64 = 0;

fn labelKey(tag: LabelTag, str: []const u8, px: f64, weight: c_uint, width: f64, x: f64, y: f64, col: [3]f64, alpha: f64) u64 {
    var h = std.hash.Wyhash.init(0x7e111000 | @as(u64, @intFromEnum(tag)));
    h.update(str);
    mixHash(&h, @as(i32, @intFromFloat(@round(px * 16.0))));
    mixHash(&h, @as(u16, @intCast(weight)));
    mixHash(&h, @as(i32, @intFromFloat(@round(width * 16.0))));
    mixHash(&h, @as(i32, @intFromFloat(@round(x * 4.0))));
    mixHash(&h, @as(i32, @intFromFloat(@round(y * 4.0))));
    for (col) |v| mixHash(&h, v);
    mixHash(&h, alpha);
    return h.final();
}

/// Blit a cached label surface at (x, y) if one exists. Returns the slot so
/// wrap-style callers can hand back the stored layout height.
fn labelBlit(cr: ?*cairo.cairo_t, tag: LabelTag, str: []const u8, px: f64, weight: c_uint, width: f64, x: f64, y: f64, col: [3]f64, alpha: f64) ?*LabelSlot {
    const c = cr orelse return null;
    if (str.len == 0) return null;
    const key = labelKey(tag, str, px, weight, width, x, y, col, alpha);
    for (&label_cache) |*slot| {
        if (slot.surface == null or slot.key != key) continue;
        slot.last = label_clock;
        label_clock +%= 1;
        label_hits +%= 1;
        cairo.cairo_save(c);
        cairo.cairo_translate(c, std.math.round(x + slot.dx), std.math.round(y + slot.dy));
        const inv: f64 = 1.0 / @as(f64, @floatFromInt(slot.scale));
        cairo.cairo_scale(c, inv, inv);
        cairo.cairo_set_source_surface(c, slot.surface, 0, 0);
        cairo.cairo_paint(c);
        cairo.cairo_restore(c);
        return slot;
    }
    return null;
}

/// Rasterise the layout into a cache surface (pango bound to the cache
/// transform first, then painted like the direct path) and blit it once, so
/// the first draw and every repeat take the identical code path. `mvx/mvy` is
/// the move_to position the label painted at; `_ret_h` is the layout height
/// wrap callers return.
fn labelRaster(
    cr: ?*cairo.cairo_t,
    l: *text.Layout,
    tag: LabelTag,
    str: []const u8,
    px: f64,
    weight: c_uint,
    width: f64,
    x: f64,
    y: f64,
    mvx: f64,
    mvy: f64,
    col: [3]f64,
    alpha: f64,
    ret_h: f64,
) void {
    const c = cr orelse return;
    const key = labelKey(tag, str, px, weight, width, x, y, col, alpha);
    const scale = deviceScale(c);
    const sc: f64 = @floatFromInt(scale);
    const ink = l.pixelInk();
    const inkx: f64 = @floatFromInt(ink.x);
    const inky: f64 = @floatFromInt(ink.y);
    const inkw: f64 = @floatFromInt(ink.width);
    const inkh: f64 = @floatFromInt(ink.height);
    const pad: f64 = 2;
    const sw: i32 = @intFromFloat(@round((inkw + pad * 2) * sc));
    const sh: i32 = @intFromFloat(@round((inkh + pad * 2) * sc));
    if (sw <= 0 or sh <= 0) return;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, sw, sh);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return;
    }
    const rc = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(rc);
    cairo.cairo_scale(rc, sc, sc);
    l.update(rc); // bind the layout to the cache's resolution
    cairo.cairo_translate(rc, pad - inkx - mvx, pad - inky - mvy);
    cairo.cairo_move_to(rc, mvx, mvy);
    setColor(rc, col, alpha);
    l.show(rc);

    var victim: ?*LabelSlot = null;
    for (&label_cache) |*slot| {
        if (slot.surface == null) {
            victim = slot;
            break;
        }
        if (victim == null or slot.last < victim.?.last) victim = slot;
    }
    const slot = victim orelse {
        cairo.cairo_surface_destroy(surf);
        return;
    };
    if (slot.surface) |old| cairo.cairo_surface_destroy(old);
    slot.* = .{
        .key = key,
        .surface = surf,
        .dx = mvx + inkx - pad - x,
        .dy = mvy + inky - pad - y,
        .h = ret_h,
        .scale = scale,
        .last = label_clock,
    };
    label_clock +%= 1;
    label_misses +%= 1;

    // First draw goes through the exact same blit path as every repeat.
    cairo.cairo_save(c);
    cairo.cairo_translate(c, std.math.round(x + slot.dx), std.math.round(y + slot.dy));
    cairo.cairo_scale(c, 1.0 / sc, 1.0 / sc);
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
}

fn label(cr: ?*cairo.cairo_t, str: []const u8, x: f64, y: f64, px: f64, weight: c_uint, col: [3]f64, alpha: f64) void {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    if (labelBlit(cr, .plain, str, px, weight, 0, x, y, col, alpha) != null) return;
    const l = layoutFor(cr, str, px, weight, 0, .plain) orelse return;
    cairo.cairo_move_to(cr, x, y);
    setColor(cr, col, alpha);
    labelRaster(cr, l, .plain, str, px, weight, 0, x, y, x, y, col, alpha, 0);
}

fn labelW(cr: ?*cairo.cairo_t, str: []const u8, x: f64, y: f64, width: f64, px: f64, weight: c_uint, col: [3]f64, alpha: f64) void {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    if (labelBlit(cr, .ellipsis, str, px, weight, width, x, y, col, alpha) != null) return;
    const l = layoutFor(cr, str, px, weight, width, .ellipsis) orelse return;
    cairo.cairo_move_to(cr, x, y);
    setColor(cr, col, alpha);
    labelRaster(cr, l, .ellipsis, str, px, weight, width, x, y, x, y, col, alpha, 0);
}

fn labelWrap(cr: ?*cairo.cairo_t, str: []const u8, x: f64, y: f64, width: f64, px: f64, weight: c_uint, col: [3]f64, alpha: f64) f64 {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    if (labelBlit(cr, .wrap, str, px, weight, width, x, y, col, alpha)) |slot| {
        return slot.h;
    }
    const l = layoutFor(cr, str, px, weight, width, .wrap) orelse return 0;
    const h = @as(f64, @floatFromInt(l.pixelSize().h));
    cairo.cairo_move_to(cr, x, y);
    setColor(cr, col, alpha);
    labelRaster(cr, l, .wrap, str, px, weight, width, x, y, x, y, col, alpha, h);
    return h;
}

fn labelParagraph(cr: ?*cairo.cairo_t, str: []const u8, x: f64, y: f64, width: f64, px: f64, weight: c_uint, col: [3]f64, alpha: f64) f64 {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    if (labelBlit(cr, .paragraph, str, px, weight, width, x, y, col, alpha)) |slot| {
        return slot.h;
    }
    const l = layoutFor(cr, str, px, weight, width, .paragraph) orelse return 0;
    const h = @as(f64, @floatFromInt(l.pixelSize().h));
    cairo.cairo_move_to(cr, x, y);
    setColor(cr, col, alpha);
    labelRaster(cr, l, .paragraph, str, px, weight, width, x, y, x, y, col, alpha, h);
    return h;
}

fn labelCenter(cr: ?*cairo.cairo_t, str: []const u8, x: f64, y: f64, width: f64, px: f64, weight: c_uint, col: [3]f64, alpha: f64) void {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    if (labelBlit(cr, .center, str, px, weight, width, x, y, col, alpha) != null) return;
    const l = layoutFor(cr, str, px, weight, width, .center) orelse return;
    cairo.cairo_move_to(cr, x, y);
    setColor(cr, col, alpha);
    labelRaster(cr, l, .center, str, px, weight, width, x, y, x, y, col, alpha, 0);
}

fn labelRight(cr: ?*cairo.cairo_t, str: []const u8, x: f64, y: f64, width: f64, px: f64, weight: c_uint, col: [3]f64, alpha: f64) void {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    if (labelBlit(cr, .right, str, px, weight, width, x, y, col, alpha) != null) return;
    const l = layoutFor(cr, str, px, weight, width, .right) orelse return;
    cairo.cairo_move_to(cr, x, y);
    setColor(cr, col, alpha);
    labelRaster(cr, l, .right, str, px, weight, width, x, y, x, y, col, alpha, 0);
}

/// Draws `str` with its painted glyph box centered inside [x, y, w, h], so
/// pills stay optically balanced in any font instead of relying on a fixed
/// line-box height.
fn labelBox(cr: ?*cairo.cairo_t, str: []const u8, x: f64, y: f64, w: f64, h: f64, px: f64, weight: c_uint, col: [3]f64, alpha: f64) void {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    if (labelBlit(cr, .box, str, px, weight, 0, x, y, col, alpha) != null) return;
    const l = layoutFor(cr, str, px, weight, 0, .plain) orelse return;
    const ink = l.pixelInk();
    const mvx = x + (w - @as(f64, @floatFromInt(ink.width))) * 0.5 - @as(f64, @floatFromInt(ink.x));
    const mvy = y + (h - @as(f64, @floatFromInt(ink.height))) * 0.5 - @as(f64, @floatFromInt(ink.y));
    cairo.cairo_move_to(cr, mvx, mvy);
    setColor(cr, col, alpha);
    labelRaster(cr, l, .box, str, px, weight, 0, x, y, mvx, mvy, col, alpha, 0);
}

/// Left-anchored label whose ink is vertically centered on `cy` — for chips
/// and status rows that pair the text with a dot or icon.
fn labelCY(cr: ?*cairo.cairo_t, str: []const u8, x: f64, cy: f64, px: f64, weight: c_uint, col: [3]f64, alpha: f64) void {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    if (labelBlit(cr, .cy, str, px, weight, 0, x, cy, col, alpha) != null) return;
    const l = layoutFor(cr, str, px, weight, 0, .plain) orelse return;
    const ink = l.pixelInk();
    const mvy = cy - @as(f64, @floatFromInt(ink.height)) * 0.5 - @as(f64, @floatFromInt(ink.y));
    cairo.cairo_move_to(cr, x, mvy);
    setColor(cr, col, alpha);
    labelRaster(cr, l, .cy, str, px, weight, 0, x, cy, x, mvy, col, alpha, 0);
}

/// Right-aligned label whose ink is vertically centered on `cy`.
fn labelRightCY(cr: ?*cairo.cairo_t, str: []const u8, x: f64, width: f64, cy: f64, px: f64, weight: c_uint, col: [3]f64, alpha: f64) void {
    const t = nowNs();
    defer noteText(nowNs() -| t, str, px);
    if (labelBlit(cr, .right_cy, str, px, weight, width, x, cy, col, alpha) != null) return;
    const l = layoutFor(cr, str, px, weight, width, .right) orelse return;
    const ink = l.pixelInk();
    const mvy = cy - @as(f64, @floatFromInt(ink.height)) * 0.5 - @as(f64, @floatFromInt(ink.y));
    cairo.cairo_move_to(cr, x, mvy);
    setColor(cr, col, alpha);
    labelRaster(cr, l, .right_cy, str, px, weight, width, x, cy, x, mvy, col, alpha, 0);
}

fn icon(cr: ?*cairo.cairo_t, name: []const u8, cx: f64, cy: f64, px: f64, col: [3]f64, alpha: f64) void {
    const t = nowNs();
    defer {
        const ns = nowNs() -| t;
        if (noteBudget(&st_icon, ns)) {
            logz.log("perf: budget icon {d:.2}ms name={s} px={d:.0} page={s}", .{
                msFromNs(ns), name, px, @tagName(perf_current_page),
            });
        } else if (traceSlow(ns)) {
            logz.log("perf: icon {d:.0}us name={s} px={d:.0}", .{ ns / std.time.ns_per_us, name, px });
        }
    }
    _ = glyph.draw(cr, name, cx, cy, px, col[0], col[1], col[2], alpha);
}

fn chevron(cr: ?*cairo.cairo_t, cx: f64, cy: f64, s: f64, left: bool, col: [3]f64, alpha: f64) void {
    const d: f64 = if (left) -1.0 else 1.0;
    cairo.cairo_new_path(cr);
    cairo.cairo_move_to(cr, cx - s * 0.28 * d, cy - s * 0.45);
    cairo.cairo_line_to(cr, cx + s * 0.28 * d, cy);
    cairo.cairo_line_to(cr, cx - s * 0.28 * d, cy + s * 0.45);
    cairo.cairo_set_line_width(cr, 1.7);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_line_join(cr, cairo.CAIRO_LINE_JOIN_ROUND);
    setColor(cr, col, alpha);
    cairo.cairo_stroke(cr);
}

fn arrowUpRight(cr: ?*cairo.cairo_t, cx: f64, cy: f64, s: f64, col: [3]f64, alpha: f64) void {
    cairo.cairo_new_path(cr);
    cairo.cairo_move_to(cr, cx - s * 0.34, cy + s * 0.34);
    cairo.cairo_line_to(cr, cx + s * 0.34, cy - s * 0.34);
    cairo.cairo_move_to(cr, cx - s * 0.02, cy - s * 0.34);
    cairo.cairo_line_to(cr, cx + s * 0.34, cy - s * 0.34);
    cairo.cairo_line_to(cr, cx + s * 0.34, cy + s * 0.02);
    cairo.cairo_set_line_width(cr, 1.6);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_line_join(cr, cairo.CAIRO_LINE_JOIN_ROUND);
    setColor(cr, col, alpha);
    cairo.cairo_stroke(cr);
}

fn heart(cr: ?*cairo.cairo_t, cx: f64, cy: f64, s: f64, filled: bool, col: [3]f64, alpha: f64) void {
    cairo.cairo_new_path(cr);
    cairo.cairo_move_to(cr, cx, cy + s * 0.38);
    cairo.cairo_curve_to(cr, cx - s * 0.62, cy + s * 0.02, cx - s * 0.46, cy - s * 0.50, cx, cy - s * 0.16);
    cairo.cairo_curve_to(cr, cx + s * 0.46, cy - s * 0.50, cx + s * 0.62, cy + s * 0.02, cx, cy + s * 0.38);
    cairo.cairo_close_path(cr);
    if (filled) {
        setColor(cr, col, alpha);
        cairo.cairo_fill(cr);
    } else {
        cairo.cairo_set_line_width(cr, 1.5);
        cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
        setColor(cr, col, alpha);
        cairo.cairo_stroke(cr);
    }
}

fn spinner(cr: ?*cairo.cairo_t, cx: f64, cy: f64, r: f64, col: [3]f64, alpha: f64) void {
    const t = @as(f64, @floatFromInt(nowMs() % 1000)) / 1000.0 * std.math.tau;
    cairo.cairo_new_path(cr);
    cairo.cairo_arc(cr, cx, cy, r, t, t + 2.2);
    cairo.cairo_set_line_width(cr, 1.7);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    setColor(cr, col, alpha);
    cairo.cairo_stroke(cr);
}

fn toggleSwitch(cr: ?*cairo.cairo_t, x: f64, y: f64, on: bool, acc: [3]f64, ink: [3]f64, dim: [3]f64) void {
    const w: f64 = 30;
    const h: f64 = 17;
    fillRound(cr, x, y, w, h, h * 0.5, if (on) acc else [3]f64{ 0.20, 0.21, 0.24 }, if (on) 0.82 else 0.65);
    if (on) {
        cairo.cairo_set_source_rgba(cr, ink[0], ink[1], ink[2], 0.92);
        cairo.cairo_arc(cr, x + w - h * 0.5, y + h * 0.5, h * 0.36, 0, std.math.tau);
        cairo.cairo_fill(cr);
    } else {
        cairo.cairo_set_source_rgba(cr, dim[0], dim[1], dim[2], 0.8);
        cairo.cairo_arc(cr, x + h * 0.5, y + h * 0.5, h * 0.36, 0, std.math.tau);
        cairo.cairo_fill(cr);
    }
}

fn pillButton(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, str: []const u8, hovered: bool, active: bool, acc: [3]f64, ink: [3]f64) void {
    const fill = if (active) acc else ink;
    fillRound(cr, x, y, w, h, h * 0.5, fill, if (active) 0.16 else if (hovered) 0.10 else 0.055);
    strokeRound(cr, x, y, w, h, h * 0.5, if (active) acc else ink, if (active) 0.30 else if (hovered) 0.14 else 0.075, 1);
    if (str.len > 0)
        labelBox(cr, str, x, y, w, h, 10, text.WEIGHT_SEMIBOLD, ink, if (active) 0.98 else 0.82);
}

fn iconButton(cr: ?*cairo.cairo_t, cx: f64, cy: f64, r: f64, name: []const u8, hovered: bool, active: bool, acc: [3]f64, ink: [3]f64, base_alpha: f64) void {
    if (hovered or active) {
        fillRound(cr, cx - r, cy - r, r * 2, r * 2, r, if (active) acc else ink, if (active) 0.15 else 0.065);
    }
    icon(cr, name, cx, cy, r * 1.18, if (active) acc else ink, if (active) 0.95 else base_alpha);
}

fn chip(cr: ?*cairo.cairo_t, x: f64, y: f64, str: []const u8, acc: [3]f64, ink: [3]f64, dim: [3]f64, highlighted: bool) f64 {
    const tw = textWidth(cr, str, 9.2, text.WEIGHT_SEMIBOLD, 0);
    const w = tw + 24;
    fillRound(cr, x, y, w, 21, 10.5, if (highlighted) acc else ink, if (highlighted) 0.17 else 0.065);
    strokeRound(cr, x, y, w, 21, 10.5, if (highlighted) acc else ink, if (highlighted) 0.28 else 0.08, 1);
    cairo.cairo_arc(cr, x + 10, y + 10.5, 2.2, 0, std.math.tau);
    setColor(cr, if (highlighted) acc else dim, if (highlighted) 0.9 else 0.55);
    cairo.cairo_fill(cr);
    labelCY(cr, str, x + 17, y + 10.5, 9.2, text.WEIGHT_SEMIBOLD, if (highlighted) ink else dim, 0.92);
    return w;
}

fn panel(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, ink: [3]f64) void {
    fillRound(cr, x, y, w, h, r, ink, 0.045);
    strokeRound(cr, x, y, w, h, r, ink, 0.075, 1);
    // A soft top-left sheen keeps the nested glass from reading as a flat box.
    const pat = cairo.cairo_pattern_create_linear(x, y, x, y + h * 0.7);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0, 1, 1, 1, 0.035);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 1, 1, 1, 1, 0);
    roundRect(cr, x, y, w, h, r);
    cairo.cairo_set_source(cr, pat);
    cairo.cairo_fill(cr);
    cairo.cairo_pattern_destroy(pat);
}

// ---------------------------------------------------------------------------
// Theme + card

const Theme = struct {
    acc: [3]f64,
    overlay: f64,
    base: [3]f64,
    pal: [3][3]f64,
    ink: [3]f64,
    dim: [3]f64,
};

fn hashSeed(bytes: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x63696465);
    h.update(bytes);
    return h.final();
}

fn mix3(a: [3]f64, b: [3]f64, t: f64) [3]f64 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    };
}

fn wrap01(v: f64) f64 {
    var x = v;
    while (x < 0) x += 1;
    while (x >= 1) x -= 1;
    return x;
}

fn rgbToHsl(rgb: [3]f64) [3]f64 {
    const r = std.math.clamp(rgb[0], 0, 1);
    const g = std.math.clamp(rgb[1], 0, 1);
    const b = std.math.clamp(rgb[2], 0, 1);
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const l = (mx + mn) * 0.5;
    const d = mx - mn;
    if (d < 1e-9) return .{ 0, 0, l };
    const s = if (l > 0.5) d / (2.0 - mx - mn) else d / (mx + mn);
    var h: f64 = if (mx == r)
        (g - b) / d + @as(f64, if (g < b) 6.0 else 0.0)
    else if (mx == g)
        (b - r) / d + 2.0
    else
        (r - g) / d + 4.0;
    h /= 6.0;
    return .{ h, s, l };
}

fn hue2rgb(p: f64, q: f64, t0: f64) f64 {
    var t = t0;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

fn hslToRgb(h: f64, s: f64, l: f64) [3]f64 {
    if (s <= 1e-9) return .{ l, l, l };
    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    return .{
        hue2rgb(p, q, h + 1.0 / 3.0),
        hue2rgb(p, q, h),
        hue2rgb(p, q, h - 1.0 / 3.0),
    };
}

/// The card's ambient palette comes from the engine, not a fixed table:
/// `pal[0]` is the theme accent itself and `pal[1]`/`pal[2]` are hue-rotated
/// siblings, rotated a little further per track so the ambient glow still
/// shifts from song to song. A near-gray accent (the stock palette) keeps the
/// blobs a neutral depth ramp — the same accent treatment the rest of the
/// desktop widgets use — instead of inventing a hue the theme does not have.
fn paletteFor(acc: [3]f64, seed: u64) [3][3]f64 {
    const hsl = rgbToHsl(acc);
    if (hsl[1] < 0.06) {
        // Neutral accent (the stock palette): a three-step lightness ramp so
        // the blobs keep a little depth instead of one flat gray wash.
        return .{
            acc,
            hslToRgb(hsl[0], 0, std.math.clamp(hsl[2] * 0.86, 0.15, 0.95)),
            hslToRgb(hsl[0], 0, std.math.clamp(hsl[2] * 0.62, 0.12, 0.90)),
        };
    }
    const j = @as(f64, @floatFromInt(seed % 5));
    const rot1 = 0.055 + j * 0.009; // ≈ 20°..33° forward
    const rot2 = 0.105 + j * 0.011; // ≈ 38°..54° back
    const sat = std.math.clamp(hsl[1] * 1.15, 0.25, 1.0);
    const lit = std.math.clamp(hsl[2] * 1.30, 0.35, 0.80);
    return .{
        acc,
        hslToRgb(wrap01(hsl[0] + rot1), sat, lit),
        hslToRgb(wrap01(hsl[0] - rot2), sat * 0.95, std.math.clamp(lit * 1.30, 0.45, 0.88)),
    };
}

fn themeFor(ctx: widget.Ctx, seed: u64) Theme {
    // Everything the card paints comes out of `Ctx` (`chrome_colors.of`):
    // accent, base glass, ink/dim text and the derived ambient palette.
    const acc = [3]f64{ ctx.acc_r, ctx.acc_g, ctx.acc_b };
    const base = [3]f64{
        std.math.clamp(ctx.dock_fill_r * 0.42 + 0.025, 0.025, 0.14),
        std.math.clamp(ctx.dock_fill_g * 0.42 + 0.03, 0.025, 0.14),
        std.math.clamp(ctx.dock_fill_b * 0.42 + 0.045, 0.025, 0.15),
    };
    // Ink/dim follow the engine's text color; dim keeps the old contrast.
    const ink = [3]f64{ ctx.text_r, ctx.text_g, ctx.text_b };
    const dim = [3]f64{ ink[0] * 0.75, ink[1] * 0.765, ink[2] * 0.80 };
    return .{
        .acc = acc,
        .overlay = std.math.clamp(ctx.overlay_widget_card, 0, 1),
        .base = base,
        .pal = paletteFor(acc, seed),
        .ink = ink,
        .dim = dim,
    };
}

fn blob(cr: ?*cairo.cairo_t, cx: f64, cy: f64, radius: f64, col: [3]f64, alpha: f64) void {
    const pat = cairo.cairo_pattern_create_radial(cx, cy, 0, cx, cy, radius);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0, col[0], col[1], col[2], alpha);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0.55, col[0], col[1], col[2], alpha * 0.38);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 1, col[0], col[1], col[2], 0);
    cairo.cairo_set_source(cr, pat);
    cairo.cairo_arc(cr, cx, cy, radius, 0, std.math.tau);
    cairo.cairo_fill(cr);
    cairo.cairo_pattern_destroy(pat);
}

fn paintCard(cr: ?*cairo.cairo_t, th: Theme, seed: u64) void {
    _ = seed;
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const off = 7.0 + @as(f64, @floatFromInt(i)) * 2.4;
        fillRound(cr, 8, off, kw - 16, kh - off - 6, outer_r, .{ 0, 0, 0 }, 0.035);
    }

    cairo.cairo_save(cr);
    clipRound(cr, 0, 0, kw, kh, outer_r);
    cairo.cairo_set_source_rgba(cr, th.base[0], th.base[1], th.base[2], 0.90 * th.overlay);
    cairo.cairo_paint(cr);
    blob(cr, kw * 0.16, kh * 0.10, 470, th.pal[0], 0.34 * th.overlay);
    blob(cr, kw * 0.92, kh * 0.62, 400, th.pal[1], 0.26 * th.overlay);
    blob(cr, kw * 0.58, kh * 1.02, 360, th.pal[2], 0.14 * th.overlay);

    const veil = cairo.cairo_pattern_create_linear(0, kh * 0.18, 0, kh);
    cairo.cairo_pattern_add_color_stop_rgba(veil, 0, th.base[0] * 0.2, th.base[1] * 0.2, th.base[2] * 0.2, 0);
    cairo.cairo_pattern_add_color_stop_rgba(veil, 1, 0.01, 0.012, 0.018, 0.58 * th.overlay);
    cairo.cairo_set_source(cr, veil);
    cairo.cairo_paint(cr);
    cairo.cairo_pattern_destroy(veil);

    const sheen = cairo.cairo_pattern_create_linear(0, 0, 0, 150);
    cairo.cairo_pattern_add_color_stop_rgba(sheen, 0, 1, 1, 1, 0.085 * th.overlay);
    cairo.cairo_pattern_add_color_stop_rgba(sheen, 1, 1, 1, 1, 0);
    cairo.cairo_set_source(cr, sheen);
    cairo.cairo_paint(cr);
    cairo.cairo_pattern_destroy(sheen);
    cairo.cairo_restore(cr);

    strokeRound(cr, 0.5, 0.5, kw - 1, kh - 1, outer_r, th.ink, 0.14 * th.overlay + 0.03, 1);
    cairo.cairo_new_path(cr);
    cairo.cairo_move_to(cr, 26, 1.1);
    cairo.cairo_line_to(cr, kw - 26, 1.1);
    cairo.cairo_set_line_width(cr, 1.1);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_source_rgba(cr, 1, 1, 1, 0.32 * th.overlay + 0.05);
    cairo.cairo_stroke(cr);
}

// The card background is the most expensive thing in the widget: seven
// full-width drop-shadow fills, three large radial blobs, and two full-card
// gradients. None of it changes while a track is playing, so raster it once
// per theme and blit the cached surface on every animation frame.
const CardCache = struct {
    surface: ?*cairo.cairo_surface_t = null,
    key: u64 = 0,
    scale: u32 = 1,
};
var card_cache: CardCache = .{};

fn deviceScale(cr: ?*cairo.cairo_t) u32 {
    const c = cr orelse return 1;
    var ctm: cairo.cairo_matrix_t = undefined;
    cairo.cairo_get_matrix(c, &ctm);
    var s = @sqrt(ctm.xx * ctm.xx + ctm.yx * ctm.yx);
    if (!(s > 0) or !std.math.isFinite(s)) s = 1;
    return @intFromFloat(std.math.clamp(@ceil(s), 1, 4));
}

fn mixHash(h: *std.hash.Wyhash, value: anytype) void {
    h.update(std.mem.asBytes(&value));
}

fn cardKey(th: Theme, ctx: widget.Ctx, seed: u64) u64 {
    _ = seed; // `paintCard` uses the theme, not the track seed.
    var h = std.hash.Wyhash.init(0x63617264);
    for (th.acc) |v| mixHash(&h, v);
    for (th.base) |v| mixHash(&h, v);
    for (th.pal) |c| for (c) |v| mixHash(&h, v);
    mixHash(&h, th.overlay);
    mixHash(&h, ctx.ui_scale);
    return h.final();
}

fn paintCardCached(cr: ?*cairo.cairo_t, th: Theme, ctx: widget.Ctx, seed: u64) void {
    const card_t = nowNs();
    var rebuild_ns: u64 = 0;
    defer {
        const ns = nowNs() -| card_t;
        if (noteBudget(&st_card, ns)) {
            logz.log("perf: budget card {d:.2}ms rebuild={d:.2}ms page={s}", .{
                msFromNs(ns), msFromNs(rebuild_ns), @tagName(perf_current_page),
            });
        } else if (traceSlow(ns)) {
            logz.log("perf: card {d:.0}us", .{ns / std.time.ns_per_us});
        }
    }
    const c = cr orelse return;

    // Raster at the compositor's effective scale so the cached glass stays
    // crisp on HiDPI outputs instead of being upscaled from logical pixels.
    const scale = deviceScale(c);

    const key = cardKey(th, ctx, seed);
    if (card_cache.surface == null or card_cache.key != key or card_cache.scale != scale) {
        const rebuild_t = nowNs();
        defer {
            const ns = nowNs() -| rebuild_t;
            rebuild_ns = ns;
            if (noteBudget(&st_card_build, ns)) {
                logz.log("perf: budget card-build {d:.2}ms scale={d} page={s}", .{
                    msFromNs(ns), scale, @tagName(perf_current_page),
                });
            } else if (traceSlow(ns)) {
                logz.log("perf: card-build {d:.0}us scale={d}", .{ ns / std.time.ns_per_us, scale });
            }
        }
        card_rebuilds +%= 1;
        if (card_cache.surface) |old| cairo.cairo_surface_destroy(old);
        card_cache.surface = null;
        card_cache.key = key;
        card_cache.scale = scale;

        const surf = cairo.cairo_image_surface_create(
            cairo.CAIRO_FORMAT_ARGB32,
            @intFromFloat(kw * @as(f64, @floatFromInt(scale))),
            @intFromFloat(kh * @as(f64, @floatFromInt(scale))),
        );
        if (cairo.cairo_surface_status(surf) == cairo.CAIRO_STATUS_SUCCESS) {
            const cache_cr = cairo.cairo_create(surf);
            cairo.cairo_scale(cache_cr, @floatFromInt(scale), @floatFromInt(scale));
            cairo.cairo_set_operator(cache_cr, cairo.CAIRO_OPERATOR_SOURCE);
            cairo.cairo_set_source_rgba(cache_cr, 0, 0, 0, 0);
            cairo.cairo_paint(cache_cr);
            cairo.cairo_set_operator(cache_cr, cairo.CAIRO_OPERATOR_OVER);
            paintCard(cache_cr, th, seed);
            cairo.cairo_destroy(cache_cr);
            card_cache.surface = surf;
        } else {
            cairo.cairo_surface_destroy(surf);
            paintCard(c, th, seed);
            return;
        }
    }

    const surf = card_cache.surface orelse {
        paintCard(c, th, seed);
        return;
    };
    cairo.cairo_save(c);
    cairo.cairo_scale(c, 1.0 / @as(f64, @floatFromInt(scale)), 1.0 / @as(f64, @floatFromInt(scale)));
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
}

const HaloCache = struct {
    surface: ?*cairo.cairo_surface_t = null,
    key: u64 = 0,
    scale: u32 = 1,
    x: f64 = 0,
    y: f64 = 0,
    last: u64 = 0,
};

// Eight keyed slots: pages glow with different radii/colours, and a single
// cache thrashed (one ~2.7ms gradient rebuild per page switch). With slots,
// page flips alternate between cached blits.
var halo_slots: [8]HaloCache = [_]HaloCache{.{}} ** 8;
var halo_clock: u64 = 0;

fn haloCached(cr: ?*cairo.cairo_t, cx: f64, cy: f64, radius: f64, col: [3]f64, alpha: f64) void {
    const halo_t = nowNs();
    defer {
        const ns = nowNs() -| halo_t;
        if (noteBudget(&st_halo, ns)) {
            logz.log("perf: budget halo {d:.2}ms r={d:.0} page={s}", .{
                msFromNs(ns), radius, @tagName(perf_current_page),
            });
        } else if (traceSlow(ns)) {
            logz.log("perf: halo {d:.0}us r={d:.0}", .{ ns / std.time.ns_per_us, radius });
        }
    }
    const c = cr orelse return;
    var h = std.hash.Wyhash.init(0x68616c6f);
    mixHash(&h, radius);
    for (col) |v| mixHash(&h, v);
    mixHash(&h, alpha);
    const key = h.final();
    const scale = deviceScale(c);

    // Centred, scaled buffer: blit origin and surface size follow the
    // radius, so slots are keyed (and reused) independently of lx/y.
    const origin_x = cx - radius - 2;
    const origin_y = cy - radius - 2;

    for (&halo_slots) |*slot| {
        if (slot.surface != null and slot.key == key and slot.scale == scale and
            slot.x == origin_x and slot.y == origin_y)
        {
            slot.last = halo_clock;
            halo_clock +%= 1;
            const surf = slot.surface.?;
            cairo.cairo_save(c);
            cairo.cairo_translate(c, origin_x, origin_y);
            cairo.cairo_scale(c, 1.0 / @as(f64, @floatFromInt(scale)), 1.0 / @as(f64, @floatFromInt(scale)));
            cairo.cairo_set_source_surface(c, surf, 0, 0);
            cairo.cairo_paint(c);
            cairo.cairo_restore(c);
            return;
        }
    }

    halo_rebuilds +%= 1;
    var victim: ?*HaloCache = null;
    for (&halo_slots) |*slot| {
        if (slot.surface == null) {
            victim = slot;
            break;
        }
        if (victim == null or slot.last < victim.?.last) victim = slot;
    }
    const slot = victim orelse {
        blob(c, cx, cy, radius, col, alpha);
        return;
    };
    const pad: f64 = 2;
    const side = @ceil((radius + pad) * 2 * @as(f64, @floatFromInt(scale)));
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, @intFromFloat(side), @intFromFloat(side));
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        blob(c, cx, cy, radius, col, alpha);
        return;
    }
    if (slot.surface) |old| cairo.cairo_surface_destroy(old);
    const cache_cr = cairo.cairo_create(surf);
    cairo.cairo_set_operator(cache_cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cache_cr, 0, 0, 0, 0);
    cairo.cairo_paint(cache_cr);
    cairo.cairo_set_operator(cache_cr, cairo.CAIRO_OPERATOR_OVER);
    cairo.cairo_scale(cache_cr, @floatFromInt(scale), @floatFromInt(scale));
    cairo.cairo_translate(cache_cr, -origin_x, -origin_y);
    blob(cache_cr, cx, cy, radius, col, alpha);
    cairo.cairo_destroy(cache_cr);
    slot.* = .{ .surface = surf, .key = key, .scale = scale, .x = origin_x, .y = origin_y, .last = halo_clock };
    halo_clock +%= 1;
    cairo.cairo_save(c);
    cairo.cairo_translate(c, origin_x, origin_y);
    cairo.cairo_scale(c, 1.0 / @as(f64, @floatFromInt(scale)), 1.0 / @as(f64, @floatFromInt(scale)));
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
}

/// Placeholder cover for a track with no artwork: the theme's ambient
/// palette, picked per item so a list still reads as distinct covers.
fn fallbackArt(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, seed: u64, th: Theme) void {
    const i: usize = @intCast(seed % 3);
    const a = th.pal[i];
    const b = th.pal[(i + 1) % 3];
    linearFill(cr, x, y, w, h, r, a, 0.32, b, 0.18);
    cairo.cairo_save(cr);
    clipRound(cr, x, y, w, h, r);
    blob(cr, x + w * 0.22, y + h * 0.18, w * 0.62, a, 0.30);
    blob(cr, x + w * 0.88, y + h * 0.84, w * 0.60, b, 0.26);
    cairo.cairo_restore(cr);
    icon(cr, "music_note", x + w * 0.5, y + h * 0.5, @min(w, h) * 0.25, th.ink, 0.58);
    strokeRound(cr, x, y, w, h, r, th.ink, 0.14, 1);
}

/// A cached surface plus how it was served, for the per-element budget logs.
const SurfaceHit = struct {
    surf: *cairo.cairo_surface_t,
    /// True when the surface was already cached (a blit), false on a build.
    hit: bool,
    /// Rasterisation cost on a build, 0 for hits.
    build_ns: u64 = 0,
};

// Downscaling a 512px cover to a 26px row icon is surprisingly expensive in
// Cairo (roughly 0.5ms per image per frame). Cache the resized raster per
// (entry, generation, target size), then a frame is just eight small blits.
const ArtSurface = struct {
    surface: ?*cairo.cairo_surface_t = null,
    entry: ?*ArtEntry = null,
    gen: u32 = 0,
    pw: i32 = 0,
    ph: i32 = 0,
    last: u64 = 0,
};
var art_surfaces: [32]ArtSurface = [_]ArtSurface{.{}} ** 32;
var art_surface_clock: u64 = 0;

fn paintArtSurface(entry: *ArtEntry, w: f64, h: f64, scale: u32) ?SurfaceHit {
    const cover = entry.cover;
    if (!cover.present()) return null;
    const pw: i32 = @intFromFloat(@round(w * @as(f64, @floatFromInt(scale))));
    const ph: i32 = @intFromFloat(@round(h * @as(f64, @floatFromInt(scale))));
    if (pw <= 0 or ph <= 0) return null;

    var victim: ?*ArtSurface = null;
    for (&art_surfaces) |*slot| {
        if (slot.surface != null and slot.entry == entry and slot.gen == entry.gen and
            slot.pw == pw and slot.ph == ph)
        {
            slot.last = art_surface_clock;
            art_surface_clock +%= 1;
            art_hits +%= 1;
            return .{ .surf = slot.surface.?, .hit = true };
        }
        if (victim == null or slot.surface == null or slot.last < victim.?.last) victim = slot;
    }
    const slot = victim orelse return null;
    const build_t = nowNs();
    art_misses +%= 1;
    if (slot.surface) |old| cairo.cairo_surface_destroy(old);
    slot.* = .{ .entry = entry, .gen = entry.gen, .pw = pw, .ph = ph, .last = art_surface_clock };
    art_surface_clock +%= 1;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, pw, ph);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const cache_cr = cairo.cairo_create(surf);
    cairo.cairo_set_operator(cache_cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cache_cr, 0, 0, 0, 0);
    cairo.cairo_paint(cache_cr);
    cairo.cairo_set_operator(cache_cr, cairo.CAIRO_OPERATOR_OVER);
    cairo.cairo_scale(cache_cr, @floatFromInt(scale), @floatFromInt(scale));

    const src = cairo.cairo_image_surface_create_for_data(
        cover.pixels.ptr,
        cairo.CAIRO_FORMAT_ARGB32,
        cover.w,
        cover.h,
        cover.w * 4,
    );
    if (cairo.cairo_surface_status(src) == cairo.CAIRO_STATUS_SUCCESS) {
        const cw: f64 = @floatFromInt(cover.w);
        const ch: f64 = @floatFromInt(cover.h);
        const sc = @max(w / cw, h / ch);
        cairo.cairo_translate(cache_cr, (w - cw * sc) * 0.5, (h - ch * sc) * 0.5);
        cairo.cairo_scale(cache_cr, sc, sc);
        cairo.cairo_set_source_surface(cache_cr, src, 0, 0);
        cairo.cairo_pattern_set_extend(cairo.cairo_get_source(cache_cr), cairo.CAIRO_EXTEND_PAD);
        cairo.cairo_paint(cache_cr);
    }
    cairo.cairo_surface_destroy(src);
    cairo.cairo_destroy(cache_cr);
    slot.surface = surf;

    const build_ns = nowNs() -| build_t;
    if (noteBudget(&st_art_build, build_ns)) {
        logz.log("perf: budget art-build {d:.2}ms {d}x{d} page={s}", .{
            msFromNs(build_ns), pw, ph, @tagName(perf_current_page),
        });
    } else if (traceSlow(build_ns)) {
        logz.log("perf: art-build {d:.0}us {d}x{d}", .{ build_ns / std.time.ns_per_us, pw, ph });
    }
    return .{ .surf = surf.?, .hit = false, .build_ns = build_ns };
}

// Placeholder surfaces for tracks with no artwork. `fallbackArt` paints two
// radial blobs and a glyph — affordable once, but a queue page of art-less
// rows would redo that gradient maths every frame, so the placeholder is
// cached per (palette, size, radius, theme, scale) as well.
const FallbackSlot = struct {
    surface: ?*cairo.cairo_surface_t = null,
    key: u64 = 0,
    scale: u32 = 1,
    last: u64 = 0,
};
var fallback_slots: [8]FallbackSlot = [_]FallbackSlot{.{}} ** 8;
var fallback_clock: u64 = 0;

fn fallbackSurface(pal_idx: usize, w: f64, h: f64, r: f64, th: Theme, scale: u32) ?SurfaceHit {
    var key_hash = std.hash.Wyhash.init(0x66626172);
    mixHash(&key_hash, pal_idx);
    mixHash(&key_hash, w);
    mixHash(&key_hash, h);
    mixHash(&key_hash, r);
    for (th.pal) |c| for (c) |v| mixHash(&key_hash, v);
    for (th.ink) |v| mixHash(&key_hash, v);
    mixHash(&key_hash, scale);
    const key = key_hash.final();

    var victim: ?*FallbackSlot = null;
    for (&fallback_slots) |*slot| {
        if (slot.surface != null and slot.key == key and slot.scale == scale) {
            slot.last = fallback_clock;
            fallback_clock +%= 1;
            fallback_hits +%= 1;
            return .{ .surf = slot.surface.?, .hit = true };
        }
        if (victim == null or slot.surface == null or slot.last < victim.?.last) victim = slot;
    }
    const slot = victim orelse return null;
    if (slot.surface) |old| cairo.cairo_surface_destroy(old);
    slot.* = .{ .key = key, .scale = scale, .last = fallback_clock };
    fallback_clock +%= 1;
    fallback_misses +%= 1;

    const build_t = nowNs();
    const pw: i32 = @intFromFloat(@round(w * @as(f64, @floatFromInt(scale))));
    const ph: i32 = @intFromFloat(@round(h * @as(f64, @floatFromInt(scale))));
    if (pw <= 0 or ph <= 0) return null;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, pw, ph);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const cache_cr = cairo.cairo_create(surf);
    cairo.cairo_set_operator(cache_cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cache_cr, 0, 0, 0, 0);
    cairo.cairo_paint(cache_cr);
    cairo.cairo_set_operator(cache_cr, cairo.CAIRO_OPERATOR_OVER);
    cairo.cairo_scale(cache_cr, @floatFromInt(scale), @floatFromInt(scale));
    fallbackArt(cache_cr, 0, 0, w, h, r, pal_idx, th);
    cairo.cairo_destroy(cache_cr);
    slot.surface = surf;
    return .{ .surf = surf.?, .hit = false, .build_ns = nowNs() -| build_t };
}

fn paintArt(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, url: []const u8, seed: u64, th: Theme) void {
    const art_t = nowNs();
    var cache_kind: []const u8 = "miss";
    var build_ns: u64 = 0;
    defer {
        const ns = nowNs() -| art_t;
        paint_art_ns +|= ns;
        paint_art_calls +|= 1;
        if (noteBudget(&st_art, ns)) {
            logz.log("perf: budget art {d:.2}ms {d:.0}x{d:.0} cache={s} build={d:.2}ms page={s} url={s}", .{
                msFromNs(ns),              w,
                h,                         cache_kind,
                msFromNs(build_ns),        @tagName(perf_current_page),
                url[0..@min(url.len, 96)],
            });
        } else if (traceSlow(ns)) {
            logz.log("perf: art {d:.0}us {d:.0}x{d:.0} cache={s}", .{ ns / std.time.ns_per_us, w, h, cache_kind });
        }
    }
    if (artFind(url)) |entry| {
        if (entry.cover.present()) {
            const scale = deviceScale(cr);
            if (paintArtSurface(entry, w, h, scale)) |res| {
                cache_kind = if (res.hit) "hit" else "build";
                build_ns = res.build_ns;
                cairo.cairo_save(cr);
                clipRound(cr, x, y, w, h, r);
                cairo.cairo_translate(cr, x, y);
                cairo.cairo_scale(cr, 1.0 / @as(f64, @floatFromInt(scale)), 1.0 / @as(f64, @floatFromInt(scale)));
                cairo.cairo_set_source_surface(cr, res.surf, 0, 0);
                cairo.cairo_pattern_set_extend(cairo.cairo_get_source(cr), cairo.CAIRO_EXTEND_PAD);
                cairo.cairo_paint(cr);
                cairo.cairo_restore(cr);
                strokeRound(cr, x, y, w, h, r, th.ink, 0.16, 1);
                return;
            }
        }
    }
    const fb_t = nowNs();
    const scale = deviceScale(cr);
    if (fallbackSurface(@intCast(seed % 3), w, h, r, th, scale)) |fb| {
        cache_kind = if (fb.hit) "fallback-hit" else "fallback-build";
        build_ns = fb.build_ns;
        cairo.cairo_save(cr);
        cairo.cairo_translate(cr, x, y);
        cairo.cairo_scale(cr, 1.0 / @as(f64, @floatFromInt(scale)), 1.0 / @as(f64, @floatFromInt(scale)));
        cairo.cairo_set_source_surface(cr, fb.surf, 0, 0);
        cairo.cairo_paint(cr);
        cairo.cairo_restore(cr);
    } else {
        fallbackArt(cr, x, y, w, h, r, seed, th);
    }
    _ = noteBudget(&st_fallback, nowNs() -| fb_t);
}

fn sectionLabel(cr: ?*cairo.cairo_t, str: []const u8, x: f64, y: f64, acc: [3]f64, alpha: f64) void {
    label(cr, str, x, y, 8.2, text.WEIGHT_SEMIBOLD, acc, alpha);
}

fn divider(cr: ?*cairo.cairo_t, x1: f64, x2: f64, y: f64, col: [3]f64, alpha: f64) void {
    cairo.cairo_new_path(cr);
    cairo.cairo_move_to(cr, x1, y);
    cairo.cairo_line_to(cr, x2, y);
    cairo.cairo_set_line_width(cr, 1);
    cairo.cairo_set_source_rgba(cr, col[0], col[1], col[2], alpha);
    cairo.cairo_stroke(cr);
}

fn statusFor(st: *const store.Snapshot, th: Theme) struct { text: []const u8, col: [3]f64 } {
    if (st.auth_pending) return .{ .text = "Waiting…", .col = amber };
    return switch (st.link) {
        .connected => .{ .text = "Connected", .col = green },
        .checking => .{ .text = "Checking", .col = th.dim },
        .needs_token => .{ .text = "Access needed", .col = amber },
        .token_invalid => .{ .text = "Token revoked", .col = red },
        .offline => .{ .text = "Cider offline", .col = red },
        .unknown => .{ .text = "Cider", .col = th.dim },
    };
}

// ---------------------------------------------------------------------------
// Chrome

// The Cider app mark: a warm pink disc, black quality ring, and play glyph.
// Drawing it here avoids a generic music note standing in for the brand.
fn paintCiderMark(cr: ?*cairo.cairo_t, cx: f64, cy: f64, r: f64) void {
    cairo.cairo_arc(cr, cx, cy + 1.5, r + 0.5, 0, std.math.tau);
    setColor(cr, [3]f64{ 0, 0, 0 }, 0.22);
    cairo.cairo_fill(cr);

    const pat = cairo.cairo_pattern_create_linear(cx, cy - r, cx, cy + r);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0, 0.99, 0.34, 0.46, 1);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 1, 0.72, 0.01, 0.24, 1);
    cairo.cairo_arc(cr, cx, cy, r, 0, std.math.tau);
    cairo.cairo_set_source(cr, pat);
    cairo.cairo_fill(cr);
    cairo.cairo_pattern_destroy(pat);

    cairo.cairo_arc(cr, cx, cy, r * 0.67, 0, std.math.tau);
    setColor(cr, [3]f64{ 0.06, 0.01, 0.03 }, 0.94);
    cairo.cairo_set_line_width(cr, r * 0.17);
    cairo.cairo_stroke(cr);

    cairo.cairo_move_to(cr, cx - r * 0.17, cy - r * 0.25);
    cairo.cairo_line_to(cr, cx + r * 0.30, cy);
    cairo.cairo_line_to(cr, cx - r * 0.17, cy + r * 0.25);
    cairo.cairo_close_path(cr);
    setColor(cr, [3]f64{ 0.06, 0.01, 0.03 }, 0.96);
    cairo.cairo_fill(cr);
}

fn paintSidebar(s: *const State, cr: ?*cairo.cairo_t, th: Theme, v: *const View) void {
    fillRound(cr, sidebar_x, sidebar_y, sidebar_w, sidebar_h, 22, th.ink, 0.035);
    strokeRound(cr, sidebar_x, sidebar_y, sidebar_w, sidebar_h, 22, th.ink, 0.075, 1);
    linearFill(cr, sidebar_x + 1, sidebar_y + 1, sidebar_w - 2, 130, 20, th.ink, 0.055, th.ink, 0);

    const logo_x: f64 = 22;
    const logo_y: f64 = 20;
    paintCiderMark(cr, logo_x + 20, logo_y + 20, 18.5);
    labelCenter(cr, "C I D E R", sidebar_x, 66, sidebar_w, 6.4, text.WEIGHT_SEMIBOLD, th.dim, 0.42);

    const pages = [_]Page{ .now_playing, .queue, .library, .lyrics, .connect };
    const labels = [_][]const u8{ "Now", "Queue", "Library", "Lyrics", "Connect" };
    const icons = [_][]const u8{ "play_arrow", "library_music", "photo_library", "mic", "settings" };
    for (pages, 0..) |p, i| {
        const r = navRect(i);
        const active = s.page == p;
        const hovered = s.hover.kind == .nav and s.hover.index == i;
        if (active or hovered) {
            fillRound(cr, r.x, r.y, r.w, r.h, 15, if (active) th.acc else th.ink, if (active) 0.16 else 0.06);
            if (active) strokeRound(cr, r.x, r.y, r.w, r.h, 15, th.acc, 0.25, 1);
        }
        icon(cr, icons[i], r.x + r.w * 0.5, r.y + 17, 20, if (active) th.acc else th.ink, if (active) 0.98 else if (hovered) 0.78 else 0.48);
        labelCenter(cr, labels[i], r.x, r.y + 31, r.w, 7.1, text.WEIGHT_SEMIBOLD, if (active) th.ink else th.dim, if (active) 0.9 else if (hovered) 0.58 else 0.34);
    }

    const sr = Rect{ .x = 18, .y = 444, .w = 48, .h = 48 };
    const sh = s.hover.kind == .search;
    if (sh) fillRound(cr, sr.x, sr.y, sr.w, sr.h, 15, th.ink, 0.06);
    icon(cr, "search", sr.x + 24, sr.y + 21, 20, th.ink, if (sh) 0.85 else 0.45);
    labelCenter(cr, "Search", sr.x, sr.y + 32, sr.w, 6.8, text.WEIGHT_SEMIBOLD, th.dim, if (sh) 0.65 else 0.32);

    const status = statusFor(&v.st, th);
    cairo.cairo_arc(cr, 42, 519, 3.2, 0, std.math.tau);
    setColor(cr, status.col, 0.9);
    cairo.cairo_fill(cr);
    cairo.cairo_arc(cr, 42, 519, 7, 0, std.math.tau);
    setColor(cr, status.col, 0.12);
    cairo.cairo_fill(cr);
    var api_buf: [24]u8 = undefined;
    const api = if (v.st.version.len > 0)
        std.fmt.bufPrint(&api_buf, "API {s}", .{v.st.version}) catch "API v2"
    else
        "API v2";
    labelCenter(cr, api, sidebar_x + 4, 530, sidebar_w - 8, 6.0, text.WEIGHT_SEMIBOLD, th.dim, 0.34);
}

fn pageTitle(s: *const State) []const u8 {
    if (s.page == .library and s.frame.valid) return s.frame.nameText();
    return switch (s.page) {
        .now_playing => "Now Playing",
        .queue => "Queue",
        .library => "Library",
        .lyrics => "Lyrics",
        .connect => "Connect",
    };
}

fn pageSubtitle(s: *const State, v: *const View, buf: []u8) []const u8 {
    switch (s.page) {
        .now_playing => {
            if (!v.now.active) return "Waiting for Cider";
            return if (v.now.playing) "Playing from Cider" else "Paused · Cider";
        },
        .queue => {
            if (v.st.queue) |q| {
                const total = @max(q.total, @as(i64, @intCast(q.items.len)));
                const pos = std.math.clamp(q.position + 1, 0, total);
                return std.fmt.bufPrint(buf, "Track {d} of {d}", .{ pos, total }) catch "Queue";
            }
            if (v.st.link == .connected and !v.st.scopes.has(.queue)) return "Queue access is not granted";
            return if (v.st.link == .connected) "Reading Cider's queue" else "Connect Cider for the full queue";
        },
        .library => {
            if (s.frame.valid) {
                const unit: []const u8 = if (s.frame.kind == .artist_albums) "albums" else "songs";
                if (visibleLibrary(s, v)) |p| return std.fmt.bufPrint(buf, "{s} · {d} {s}", .{ s.frame.subtitleText(), p.total, unit }) catch unit;
                return s.frame.subtitleText();
            }
            const unit_label: []const u8 = switch (s.lib_tab) {
                .playlists => "playlists",
                .albums => "albums",
                .songs => "songs",
                else => "artists",
            };
            if (visibleLibrary(s, v)) |p| return std.fmt.bufPrint(buf, "{d} {s} · Apple Music", .{ p.total, unit_label }) catch unit_label;
            if (v.st.link == .connected and !v.st.scopes.has(.library)) return "Library access is not granted";
            return if (v.st.link == .connected) "Reading your Apple Music library" else "Connect Cider to browse your library";
        },
        .lyrics => {
            if (v.st.lyrics) |ly| {
                if (ly.lines.len == 0) return "No lyrics for this track";
                if (ly.provider.len > 0 and ly.timing.len > 0)
                    return std.fmt.bufPrint(buf, "{s} · {s} synced", .{ ly.provider, ly.timing }) catch "Synced from Cider";
                return "Synced from Cider";
            }
            if (v.st.link == .connected and !v.st.scopes.has(.lyrics)) return "Lyrics access is not granted";
            return if (v.st.link == .connected) "Looking for lyrics" else "Connect Cider for synced lyrics";
        },
        .connect => {
            if (v.st.version.len > 0) return std.fmt.bufPrint(buf, "Cider · local API {s}", .{v.st.version}) catch "Cider · local REST v2";
            return "Cider · local REST v2";
        },
    }
}

fn paintHeader(s: *const State, cr: ?*cairo.cairo_t, th: Theme, v: *const View) void {
    divider(cr, content_x, content_right, 78, th.ink, 0.075);
    var sub_buf: [192]u8 = undefined;
    const title_x: f64 = if (s.frame.valid and s.page == .library) 136 else content_x;
    if (s.frame.valid and s.page == .library) {
        const hov = s.hover.kind == .lib_back;
        if (hov) fillRound(cr, 104, 17, 28, 28, 9, th.ink, 0.07);
        chevron(cr, 118, 31, 12, true, th.ink, if (hov) 0.9 else 0.55);
    }
    labelW(cr, pageTitle(s), title_x, 18, 500, 21, text.WEIGHT_BOLD, th.ink, 0.97);
    labelW(cr, pageSubtitle(s, v, &sub_buf), title_x, 48, 520, 10.2, text.WEIGHT_NORMAL, th.dim, 0.62);

    const status = statusFor(&v.st, th);
    const pill_w: f64 = 112;
    const pill_x: f64 = 640;
    const pill_hover = s.hover.kind == .status_pill;
    fillRound(cr, pill_x, 22, pill_w, 24, 12, th.ink, if (pill_hover) 0.10 else 0.05);
    strokeRound(cr, pill_x, 22, pill_w, 24, 12, status.col, if (pill_hover) 0.34 else 0.16, 1);
    cairo.cairo_arc(cr, pill_x + 13, 34, 3.4, 0, std.math.tau);
    setColor(cr, status.col, 0.95);
    cairo.cairo_fill(cr);
    cairo.cairo_arc(cr, pill_x + 13, 34, 6.2, 0, std.math.tau);
    setColor(cr, status.col, 0.12);
    cairo.cairo_fill(cr);
    labelCY(cr, status.text, pill_x + 23, 34, 9.4, text.WEIGHT_SEMIBOLD, th.ink, if (pill_hover) 0.98 else 0.86);
    chevron(cr, 735, 34, 8, false, status.col, if (pill_hover) 0.9 else 0.38);

    if (s.page == .library and s.frame.valid) {
        const hov = s.hover.kind == .lib_play;
        pillButton(cr, 780, 20, 84, 28, "Play", hov, true, th.acc, th.ink);
        icon(cr, "play_arrow", 794, 34, 13, th.ink, 0.95);
    } else {
        const search_h = s.hover.kind == .header_search;
        if (search_h) fillRound(cr, 764, 22, 28, 28, 9, th.ink, 0.07);
        icon(cr, "search", 778, 36, 17, th.ink, if (search_h) 0.85 else 0.48);
        const open_h = s.hover.kind == .header_open;
        if (open_h) fillRound(cr, 800, 22, 28, 28, 9, th.ink, 0.07);
        arrowUpRight(cr, 814, 36, 15, th.ink, if (open_h) 0.85 else 0.48);
    }
}

fn paintPlayer(s: *const State, cr: ?*cairo.cairo_t, th: Theme, v: *const View) void {
    fillRound(cr, player_x, player_y, player_w, player_h, 17, th.ink, 0.05);
    strokeRound(cr, player_x, player_y, player_w, player_h, 17, th.ink, 0.09, 1);
    const sheen = cairo.cairo_pattern_create_linear(player_x, player_y, player_x, player_y + 26);
    cairo.cairo_pattern_add_color_stop_rgba(sheen, 0, 1, 1, 1, 0.045);
    cairo.cairo_pattern_add_color_stop_rgba(sheen, 1, 1, 1, 1, 0);
    roundRect(cr, player_x, player_y, player_w, player_h, 17);
    cairo.cairo_set_source(cr, sheen);
    cairo.cairo_fill(cr);
    cairo.cairo_pattern_destroy(sheen);

    // A hairline seek rail sits on the top edge, so the whole strip is a
    // scrubber without stealing height from the controls.
    const rail_x = player_x + 16;
    const rail_w = player_w - 32;
    cairo.cairo_new_path(cr);
    cairo.cairo_move_to(cr, rail_x, player_y + 0.8);
    cairo.cairo_line_to(cr, rail_x + rail_w, player_y + 0.8);
    cairo.cairo_set_line_width(cr, 2.2);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_source_rgba(cr, th.ink[0], th.ink[1], th.ink[2], 0.09);
    cairo.cairo_stroke(cr);
    var frac: f64 = 0;
    if (v.now.duration_ms > 0)
        frac = std.math.clamp(@as(f64, @floatFromInt(v.now.position_ms)) / @as(f64, @floatFromInt(v.now.duration_ms)), 0, 1);
    if (frac > 0) {
        cairo.cairo_new_path(cr);
        cairo.cairo_move_to(cr, rail_x, player_y + 0.8);
        cairo.cairo_line_to(cr, rail_x + rail_w * frac, player_y + 0.8);
        cairo.cairo_set_line_width(cr, 2.2);
        cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
        setColor(cr, th.acc, 0.9);
        cairo.cairo_stroke(cr);
        cairo.cairo_arc(cr, rail_x + rail_w * frac, player_y + 0.8, 2.8, 0, std.math.tau);
        setColor(cr, th.ink, 0.9);
        cairo.cairo_fill(cr);
    }

    paintArt(cr, player_x + 12, player_y + 8, 38, 38, 10, v.now.art, hashSeed(v.now.title), th);
    const mini_hover = s.hover.kind == .mini;
    labelW(cr, if (v.now.active) v.now.title else "Nothing playing", player_x + 60, player_y + 10, 176, 11.2, text.WEIGHT_SEMIBOLD, th.ink, if (mini_hover) 1.0 else 0.92);
    labelW(cr, if (v.now.active) v.now.artist else "Open Cider to start", player_x + 60, player_y + 27, 176, 9.0, text.WEIGHT_NORMAL, th.dim, 0.6);

    iconButton(cr, player_x + 254, player_y + 27, 13, "shuffle", s.hover.kind == .shuffle, v.now.shuffle, th.acc, th.ink, 0.46);
    iconButton(cr, player_x + 294, player_y + 27, 14, "skip_previous", s.hover.kind == .prev, false, th.acc, th.ink, 0.68);
    iconButton(cr, player_x + 374, player_y + 27, 14, "skip_next", s.hover.kind == .next, false, th.acc, th.ink, 0.68);
    iconButton(cr, player_x + 414, player_y + 27, 13, if (v.now.loop.len > 0 and !std.mem.eql(u8, v.now.loop, "None")) if (std.mem.eql(u8, v.now.loop, "Track")) "repeat_one" else "repeat" else "repeat", s.hover.kind == .repeat, v.now.loop.len > 0 and !std.mem.eql(u8, v.now.loop, "None"), th.acc, th.ink, 0.42);

    const play_cx = player_x + 334;
    const play_cy = player_y + 27;
    const play_hover = s.hover.kind == .play;
    cairo.cairo_arc(cr, play_cx, play_cy, 18.5, 0, std.math.tau);
    if (play_hover) {
        setColor(cr, th.acc, 0.98);
    } else {
        setColor(cr, th.acc, 0.88);
    }
    cairo.cairo_fill(cr);
    cairo.cairo_arc(cr, play_cx, play_cy, 18.5, 0, std.math.tau);
    cairo.cairo_set_source_rgba(cr, th.ink[0], th.ink[1], th.ink[2], 0.20);
    cairo.cairo_set_line_width(cr, 1);
    cairo.cairo_stroke(cr);
    icon(cr, if (v.now.playing) "pause" else "play_arrow", play_cx + @as(f64, if (v.now.playing) 0.0 else 1.2), play_cy, 19, [3]f64{ 0.06, 0.06, 0.08 }, 0.92);

    iconButton(cr, player_x + 586, player_y + 27, 14, "library_music", s.hover.kind == .queue_icon, s.page == .queue, th.acc, th.ink, 0.48);
    iconButton(cr, player_x + 624, player_y + 27, 14, "mic", s.hover.kind == .lyrics_icon, s.page == .lyrics, th.acc, th.ink, 0.48);
    iconButton(cr, player_x + 676, player_y + 27, 13, if (v.st.audio.volume > 0.5) "volume_up" else "volume_down", s.hover.kind == .volume_icon, false, th.acc, th.ink, 0.44);

    // Volume slider: the 802..862 hit strip in `targetAt` maps x onto 0..1, so
    // a filled track and knob read as a control instead of a level meter.
    const vol = std.math.clamp(v.st.audio.volume, 0, 1);
    const vs_x = player_x + 698;
    const vs_w: f64 = 60;
    const vs_cy = player_y + 27;
    fillRound(cr, vs_x, vs_cy - 2.5, vs_w, 5, 2.5, th.ink, 0.13);
    if (vol > 0.01) fillRound(cr, vs_x, vs_cy - 2.5, @max(vs_w * vol, 5), 5, 2.5, th.acc, 0.88);
    cairo.cairo_arc(cr, vs_x + vs_w * vol, vs_cy, 3.8, 0, std.math.tau);
    setColor(cr, th.ink, 0.95);
    cairo.cairo_fill(cr);
}

fn paintToast(s: *const State, cr: ?*cairo.cairo_t, th: Theme) void {
    if (s.toast_len == 0 or nowMs() >= s.toast_until) return;
    const msg = s.toast[0..s.toast_len];
    const tw = textWidth(cr, msg, 9.8, text.WEIGHT_SEMIBOLD, 480);
    const w = @min(tw + 44, 520);
    const x = (kw - w) * 0.5;
    const y = 470;
    const a = std.math.clamp(@as(f64, @floatFromInt(s.toast_until - nowMs())) / 500.0, 0, 1);
    fillRound(cr, x, y, w, 27, 13.5, [3]f64{ 0.04, 0.045, 0.06 }, 0.92 * a);
    strokeRound(cr, x, y, w, 27, 13.5, th.ink, 0.12 * a, 1);
    cairo.cairo_arc(cr, x + 15, y + 13.5, 2.6, 0, std.math.tau);
    setColor(cr, th.acc, 0.9 * a);
    cairo.cairo_fill(cr);
    labelW(cr, msg, x + 24, y + 6, w - 36, 9.8, text.WEIGHT_SEMIBOLD, th.ink, 0.9 * a);
}

// ---------------------------------------------------------------------------
// Pages

fn durationLabel(buf: []u8, ms: i64) []const u8 {
    if (ms <= 0) return "--:--";
    return bus.formatMmss(buf, ms * 1000, false);
}

fn lyricActiveFor(v: *const View) i32 {
    const ly = v.st.lyrics orelse return -1;
    if (ly.lines.len == 0) return -1;
    const pos = @as(f64, @floatFromInt(v.now.position_ms)) / 1000.0;
    var active: i32 = -1;
    for (ly.lines, 0..) |line, i| {
        if (line.start <= pos + 0.15) active = @intCast(i) else break;
    }
    return active;
}

fn paintEqualizer(cr: ?*cairo.cairo_t, cx: f64, cy: f64, col: [3]f64, active: bool) void {
    const t = @as(f64, @floatFromInt(nowMs() % 1200)) / 1200.0;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const phase = t * std.math.tau + @as(f64, @floatFromInt(i)) * 1.7;
        const h = if (active) 5.0 + (std.math.sin(phase) * 0.5 + 0.5) * 10.0 else 4.0;
        fillRound(cr, cx - 6 + @as(f64, @floatFromInt(i)) * 5, cy + 7 - h, 2.4, h, 1.2, col, 0.9);
    }
}

fn paintNowPage(s: *const State, cr: ?*cairo.cairo_t, th: Theme, v: *const View) void {
    const art = nowArtRect();
    const seed = hashSeed(v.now.title);

    // A soft halo under the cover lets the artwork tint the glass around it.
    // Rasterized once: a 480px radial was ~1ms of every animated frame.
    haloCached(cr, art.x + art.w * 0.5, art.y + art.h * 0.55, art.w * 0.86, th.pal[0], 0.10);
    paintArt(cr, art.x, art.y, art.w, art.h, 20, v.now.art, seed, th);

    const nl = nowTextLayout(v);
    sectionLabel(cr, if (v.now.active) "NOW PLAYING" else "CIDER", 384, 99, th.acc, 0.85);
    if (v.now.active) {
        cairo.cairo_save(cr);
        cairo.cairo_rectangle(cr, 384, 117, 288, 76);
        cairo.cairo_clip(cr);
        _ = labelWrap(cr, v.now.title, 384, 116, 288, 25, text.WEIGHT_BOLD, th.ink, 0.98);
        cairo.cairo_restore(cr);
        labelW(cr, v.now.artist, 384, nl.artist_y, 288, 13.5, 500, th.ink, 0.82);
        labelW(cr, v.now.album, 384, nl.album_y, 288, 10.2, text.WEIGHT_NORMAL, th.dim, 0.58);
    } else {
        labelW(cr, "Nothing playing", 384, 119, 288, 25, text.WEIGHT_BOLD, th.ink, 0.95);
        labelW(cr, "Start a track in Cider", 384, nl.artist_y, 288, 12.5, 500, th.dim, 0.68);
        labelW(cr, "This card follows Cider's player and library.", 384, nl.album_y + 3, 288, 9.8, text.WEIGHT_NORMAL, th.dim, 0.44);
    }

    var cx: f64 = 384;
    if (v.now.active) {
        const flavor = if (v.now.flavor.len > 0) v.now.flavor else "Cider";
        cx += chip(cr, cx, nl.chips_y, flavor, th.acc, th.ink, th.dim, false) + 6;
    }
    if (v.st.now.available and v.st.now.in_library) {
        _ = chip(cr, cx, nl.chips_y, "In Library", th.acc, th.ink, th.dim, false);
    } else if (v.now.active and v.st.now.available) {
        _ = chip(cr, cx, nl.chips_y, "Not in Library", th.acc, th.ink, th.dim, false);
    }

    const like_hover = s.hover.kind == .like;
    if (like_hover) fillRound(cr, 382, nl.actions_y - 2, 36, 36, 11, th.ink, 0.065);
    heart(cr, 400, nl.actions_y + 14, 16, v.st.now.available and v.st.now.rating == 1, if (v.st.now.rating == 1) th.acc else th.ink, if (v.now.active) 0.78 else 0.28);

    const add_hover = s.hover.kind == .add;
    if (add_hover) fillRound(cr, 422, nl.actions_y - 2, 36, 36, 11, th.ink, 0.065);
    icon(cr, if (v.st.now.available and v.st.now.in_library) "check" else "add", 440, nl.actions_y + 14, 18, if (v.st.now.available and v.st.now.in_library) th.acc else th.ink, if (v.now.active) 0.78 else 0.28);

    pillButton(cr, 464, nl.actions_y, 72, 32, "Lyrics", s.hover.kind == .lyrics_pill, s.page == .lyrics, th.acc, th.ink);
    pillButton(cr, 544, nl.actions_y, 68, 32, "Queue", s.hover.kind == .queue_pill, false, th.acc, th.ink);

    label(cr, "FROM", 384, nl.from_y, 7.8, text.WEIGHT_SEMIBOLD, th.dim, 0.8);
    var from_buf: [96]u8 = undefined;
    const from = if (v.now.active) std.fmt.bufPrint(&from_buf, "Cider · {s}", .{if (v.now.flavor.len > 0) v.now.flavor else "Apple Music"}) catch "Cider" else "Cider · local player";
    labelW(cr, from, 384, nl.from_y + 13, 288, 9.6, 500, th.dim, 0.58);

    // Up-next panel.
    const qp = nowQueuePanelRect();
    panel(cr, qp.x, qp.y, qp.w, qp.h, 18, th.ink);
    sectionLabel(cr, "UP NEXT", qp.x + 14, qp.y + 13, th.dim, 0.62);
    if (v.st.queue) |q| {
        const total = @max(q.total, @as(i64, @intCast(q.items.len)));
        var count_buf: [32]u8 = undefined;
        labelRight(cr, std.fmt.bufPrint(&count_buf, "{d} left", .{@max(total - q.position - 1, 0)}) catch "", qp.x, qp.y + 13, qp.w - 14, 8.0, 500, th.dim, 0.4);
        var j: usize = 0;
        const base: usize = @intCast(@max(q.position + 1, 0));
        while (j < 3) : (j += 1) {
            const idx = base + j;
            if (idx >= q.items.len) break;
            const item = q.items[idx];
            const rr = upNextRect(j);
            if (s.hover.kind == .upnext and s.hover.index == j) fillRound(cr, rr.x - 4, rr.y, rr.w + 8, rr.h, 9, th.ink, 0.055);
            paintArt(cr, rr.x, rr.y + 4, 26, 26, 7, item.art_url, hashSeed(item.title), th);
            labelW(cr, item.title, rr.x + 33, rr.y + 2, rr.w - 35, 8.7, text.WEIGHT_SEMIBOLD, th.ink, 0.78);
            labelW(cr, item.artist, rr.x + 33, rr.y + 16, rr.w - 35, 7.3, text.WEIGHT_NORMAL, th.dim, 0.48);
        }
        if (q.items.len <= base) {
            labelW(cr, if (q.items.len == 0) "Queue is empty" else "End of the queue", qp.x + 14, qp.y + 52, qp.w - 28, 9.5, 500, th.dim, 0.42);
        }
    } else {
        const connected = v.st.link == .connected;
        const allowed = v.st.scopes.has(.queue);
        _ = labelWrap(cr, if (connected and allowed)
            "Reading the queue…"
        else if (connected)
            "Queue access is not granted."
        else
            "Connect Cider to see the queue.", qp.x + 14, qp.y + 48, qp.w - 28, 9.3, text.WEIGHT_NORMAL, th.dim, 0.44);
    }
    const open_hover = s.hover.kind == .upnext_open;
    if (open_hover) fillRound(cr, qp.x + 8, qp.y + qp.h - 34, qp.w - 16, 26, 8, th.ink, 0.06);
    label(cr, "Open queue", qp.x + 14, qp.y + qp.h - 26, 8.8, text.WEIGHT_SEMIBOLD, th.acc, 0.85);
    chevron(cr, qp.x + qp.w - 18, qp.y + qp.h - 17, 10, false, th.acc, 0.7);

    // Lyrics strip.
    const lr = lyricsStripRect();
    panel(cr, lr.x, lr.y, lr.w, lr.h, 20, th.ink);
    linearFill(cr, lr.x + 1, lr.y + 1, lr.w - 2, lr.h - 2, 19, th.acc, 0.025, th.pal[1], 0.012);
    sectionLabel(cr, "LYRICS", lr.x + 18, lr.y + 15, th.acc, 0.72);
    if (v.st.lyrics) |ly| {
        if (ly.lines.len > 0) {
            const active = lyricActiveFor(v);
            const idx: usize = if (active >= 0) @intCast(active) else 0;
            labelW(cr, ly.lines[idx].text, lr.x + 18, lr.y + 38, lr.w - 180, 16.5, text.WEIGHT_SEMIBOLD, th.ink, 0.94);
            if (idx + 1 < ly.lines.len)
                labelW(cr, ly.lines[idx + 1].text, lr.x + 18, lr.y + 66, lr.w - 180, 12.0, text.WEIGHT_NORMAL, th.dim, 0.52);
            label(cr, "Open lyrics", lr.x + lr.w - 106, lr.y + 18, 8.8, text.WEIGHT_SEMIBOLD, th.acc, 0.82);
            chevron(cr, lr.x + lr.w - 22, lr.y + 25, 10, false, th.acc, 0.7);
        } else {
            labelW(cr, "No synced lyrics for this track", lr.x + 18, lr.y + 43, lr.w - 180, 13.0, 500, th.dim, 0.55);
        }
    } else {
        labelW(cr, if (v.st.link == .connected) "Looking for lyrics in Cider…" else "Connect Cider for synced lyrics.", lr.x + 18, lr.y + 43, lr.w - 180, 13.0, 500, th.dim, if (v.st.link == .connected) 0.50 else 0.42);
    }
}

fn paintQueuePage(s: *const State, cr: ?*cairo.cairo_t, th: Theme, v: *const View) void {
    const q = v.st.queue;
    if (q == null) {
        panel(cr, 112, 116, 764, 320, 22, th.ink);
        icon(cr, "library_music", 494, 226, 38, th.dim, 0.28);
        const connected = v.st.link == .connected;
        const allowed = v.st.scopes.has(.queue);
        const title = if (connected and allowed)
            "Reading Cider's queue"
        else if (connected)
            "Queue access is not granted"
        else
            "Queue unavailable";
        const subtitle = if (connected and allowed)
            "The queue will appear here in a moment."
        else if (connected)
            "Reconnect Cider with the queue scope to see what is next."
        else
            "Connect Cider to see what is playing next.";
        labelCenter(cr, title, 112, 256, 764, 18, text.WEIGHT_SEMIBOLD, th.ink, 0.8);
        labelCenter(cr, subtitle, 112, 284, 764, 10.5, text.WEIGHT_NORMAL, th.dim, 0.48);
        if (!connected)
            pillButton(cr, 409, 322, 82, 30, "Connect", s.hover.kind == .connect_cta, true, th.acc, th.ink);
        return;
    }
    const page = q.?;
    const start = s.queue_page * queue_rows;
    const total = queueLoadedTotal(page);
    if (page.items.len == 0) {
        panel(cr, 112, 116, 764, 320, 22, th.ink);
        icon(cr, "schedule", 494, 226, 38, th.dim, 0.28);
        labelCenter(cr, "The queue is empty", 112, 256, 764, 18, text.WEIGHT_SEMIBOLD, th.ink, 0.8);
        labelCenter(cr, "Play a track in Cider and it will show up here.", 112, 284, 764, 10.5, text.WEIGHT_NORMAL, th.dim, 0.48);
        return;
    }

    var i: usize = 0;
    while (i < queue_rows) : (i += 1) {
        const idx = start + i;
        if (idx >= page.items.len) break;
        const item = page.items[idx];
        const r = queueRowRect(i);
        const current = @as(i64, @intCast(idx)) == page.position;
        const hover = s.hover.kind == .queue_row and s.hover.index == i;
        if (current) {
            fillRound(cr, r.x, r.y, r.w, r.h, 13, th.acc, 0.11);
            strokeRound(cr, r.x, r.y, r.w, r.h, 13, th.acc, 0.20, 1);
            fillRound(cr, r.x, r.y + 10, 2.5, r.h - 20, 1.25, th.acc, 0.9);
        } else if (hover) {
            fillRound(cr, r.x, r.y, r.w, r.h, 13, th.ink, 0.05);
        }
        if (current) {
            paintEqualizer(cr, r.x + 22, r.y + 21, th.acc, v.now.playing);
        } else {
            var num_buf: [8]u8 = undefined;
            label(cr, std.fmt.bufPrint(&num_buf, "{d}", .{idx + 1}) catch "", r.x + 14, r.y + 15, 9.0, 500, th.dim, 0.38);
        }
        paintArt(cr, r.x + 38, r.y + 7, 30, 30, 8, item.art_url, hashSeed(item.title), th);
        labelW(cr, item.title, r.x + 78, r.y + 8, 300, 11.2, text.WEIGHT_SEMIBOLD, if (current) th.ink else th.ink, if (current) 0.96 else 0.78);
        labelW(cr, item.artist, r.x + 78, r.y + 24, 300, 8.8, text.WEIGHT_NORMAL, th.dim, 0.5);
        labelW(cr, item.album, r.x + 410, r.y + 15, 220, 9.4, text.WEIGHT_NORMAL, th.dim, 0.40);
        var dur_buf: [16]u8 = undefined;
        labelRight(cr, durationLabel(&dur_buf, item.duration_ms), r.x + r.w - 108, r.y + 15, 58, 9.2, 500, th.dim, 0.42);
        if (current) {
            label(cr, "NOW", r.x + r.w - 146, r.y + 15, 8.0, text.WEIGHT_SEMIBOLD, th.acc, 0.85);
        } else if (s.hover.kind == .queue_remove and s.hover.index == i) {
            fillRound(cr, r.x + r.w - 32, r.y + 8, 25, 25, 8, th.ink, 0.06);
            icon(cr, "close", r.x + r.w - 19, r.y + 21, 12, th.ink, 0.58);
        }
    }

    var range_buf: [64]u8 = undefined;
    const shown_end = @min(start + queue_rows, total);
    const more = page.total > @as(i64, @intCast(page.items.len));
    const range = if (more)
        std.fmt.bufPrint(&range_buf, "{d}–{d} of {d} · more in Cider", .{ start + 1, shown_end, total }) catch ""
    else
        std.fmt.bufPrint(&range_buf, "{d}–{d} of {d}", .{ start + 1, shown_end, total }) catch "";
    label(cr, range, 112, 453, 9.6, 500, th.dim, 0.48);
    const prev_hover = s.hover.kind == .qprev;
    const next_hover = s.hover.kind == .qnext;
    if (prev_hover) fillRound(cr, 808, 442, 28, 28, 9, th.ink, 0.06);
    if (next_hover) fillRound(cr, 844, 442, 28, 28, 9, th.ink, 0.06);
    chevron(cr, 822, 456, 12, true, th.ink, if (s.queue_page > 0) 0.58 else 0.18);
    const pages = queuePages(page);
    chevron(cr, 858, 456, 12, false, th.ink, if (s.queue_page + 1 < pages) 0.58 else 0.18);
}

fn paintLibraryPage(s: *const State, cr: ?*cairo.cairo_t, th: Theme, v: *const View) void {
    const page = visibleLibrary(s, v);

    if (!s.frame.valid) {
        const tabs = [_][]const u8{ "Playlists", "Albums", "Songs", "Artists" };
        const kinds = [_]cider.LibraryKind{ .playlists, .albums, .songs, .artists };
        for (tabs, 0..) |name, i| {
            const r = libTabRect(i);
            const active = s.lib_tab == kinds[i];
            const hover = s.hover.kind == .lib_tab and s.hover.index == i;
            if (active) {
                fillRound(cr, r.x, r.y, r.w, r.h, 9, th.acc, 0.16);
                strokeRound(cr, r.x, r.y, r.w, r.h, 9, th.acc, 0.26, 1);
            } else if (hover) {
                fillRound(cr, r.x, r.y, r.w, r.h, 9, th.ink, 0.05);
            }
            labelCenter(cr, name, r.x, r.y + 7, r.w, 9.4, text.WEIGHT_SEMIBOLD, if (active) th.ink else th.dim, if (active) 0.92 else 0.55);
        }
    }

    if (page == null) {
        panel(cr, 112, if (s.frame.valid) 94 else 132, 764, if (s.frame.valid) 340 else 300, 22, th.ink);
        icon(cr, "photo_library", 494, 230, 36, th.dim, 0.28);
        const connected = v.st.link == .connected;
        const allowed = v.st.scopes.has(.library);
        const title = if (connected and allowed)
            "Reading your library"
        else if (connected)
            "Library access is not granted"
        else
            "Library unavailable";
        const subtitle = if (connected and allowed)
            "Apple Music is answering through Cider."
        else if (connected)
            "Reconnect Cider with the library scope to browse Apple Music."
        else
            "Connect Cider to browse Apple Music.";
        labelCenter(cr, title, 112, 260, 764, 17, text.WEIGHT_SEMIBOLD, th.ink, 0.78);
        labelCenter(cr, subtitle, 112, 286, 764, 10.5, text.WEIGHT_NORMAL, th.dim, 0.48);
        if (!connected) pillButton(cr, 409, 322, 82, 30, "Connect", s.hover.kind == .connect_cta, true, th.acc, th.ink);
        return;
    }
    const p = page.?;
    if (p.items.len == 0) {
        panel(cr, 112, if (s.frame.valid) 94 else 132, 764, if (s.frame.valid) 340 else 300, 22, th.ink);
        icon(cr, "search", 494, 230, 34, th.dim, 0.26);
        labelCenter(cr, "Nothing here yet", 112, 260, 764, 17, text.WEIGHT_SEMIBOLD, th.ink, 0.78);
        labelCenter(cr, "This collection is empty in Apple Music.", 112, 286, 764, 10.5, text.WEIGHT_NORMAL, th.dim, 0.48);
        return;
    }

    const songs = activeKind(s).isSongs();
    const start = s.lib_page * libPageSize(s);
    const count = libRowCount(s);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx = start + i;
        if (idx >= p.items.len) break;
        const item = p.items[idx];
        const r = libRowRect(s, i);
        const hover_row = s.hover.kind == .lib_row and s.hover.index == i;
        const hover_add = s.hover.kind == .lib_add and s.hover.index == i;
        if (hover_row or hover_add) fillRound(cr, r.x, r.y, r.w, r.h, 12, th.ink, 0.05);
        paintArt(cr, r.x + 10, r.y + 6, 30, 30, if (activeKind(s) == .artists) 15 else 8, item.art_url, hashSeed(item.name), th);
        labelW(cr, item.name, r.x + 52, r.y + 7, 420, 11.2, text.WEIGHT_SEMIBOLD, th.ink, 0.82);
        labelW(cr, item.subtitle, r.x + 52, r.y + 23, 420, 8.8, text.WEIGHT_NORMAL, th.dim, 0.48);
        if (songs) {
            var dur_buf: [16]u8 = undefined;
            labelRight(cr, durationLabel(&dur_buf, item.duration_ms), r.x + r.w - 148, r.y + 14, 72, 9.2, 500, th.dim, 0.40);
            if (hover_add or (s.hover.kind == .lib_add and s.hover.index == i)) {
                fillRound(cr, r.x + r.w - 40, r.y + 7, 28, 28, 9, th.ink, 0.07);
                icon(cr, "add", r.x + r.w - 26, r.y + 21, 14, th.acc, 0.9);
            } else {
                icon(cr, "add", r.x + r.w - 26, r.y + 21, 13, th.dim, if (hover_row) 0.55 else 0.18);
            }
        } else {
            labelRight(cr, item.extra, r.x + r.w - 154, r.y + 14, 116, 9.0, text.WEIGHT_NORMAL, th.dim, 0.38);
            chevron(cr, r.x + r.w - 20, r.y + 21, 11, false, th.ink, if (hover_row) 0.60 else 0.24);
        }
    }

    var range_buf: [64]u8 = undefined;
    const total = libLoadedTotal(p);
    const shown_end = @min(start + count, total);
    const more = p.total > @as(i64, @intCast(p.items.len));
    const range = if (more)
        std.fmt.bufPrint(&range_buf, "{d}–{d} of {d} · more in Cider", .{ start + 1, shown_end, total }) catch ""
    else
        std.fmt.bufPrint(&range_buf, "{d}–{d} of {d}", .{ start + 1, shown_end, total }) catch "";
    if (s.frame.valid) {
        label(cr, range, 112, 466, 9.4, 500, th.dim, 0.42);
        if (s.hover.kind == .lib_prev) fillRound(cr, 808, 458, 28, 28, 9, th.ink, 0.06);
        if (s.hover.kind == .lib_next) fillRound(cr, 844, 458, 28, 28, 9, th.ink, 0.06);
        chevron(cr, 822, 472, 11, true, th.ink, if (s.lib_page > 0) 0.56 else 0.18);
        const pages = libPages(s, p);
        chevron(cr, 858, 472, 11, false, th.ink, if (s.lib_page + 1 < pages) 0.56 else 0.18);
    } else {
        labelRight(cr, range, 640, 98, 138, 9.0, 500, th.dim, 0.42);
        if (s.hover.kind == .lib_prev) fillRound(cr, 786, 90, 28, 28, 9, th.ink, 0.06);
        if (s.hover.kind == .lib_next) fillRound(cr, 822, 90, 28, 28, 9, th.ink, 0.06);
        chevron(cr, 800, 104, 11, true, th.ink, if (s.lib_page > 0) 0.56 else 0.18);
        const pages = libPages(s, p);
        chevron(cr, 836, 104, 11, false, th.ink, if (s.lib_page + 1 < pages) 0.56 else 0.18);
    }
}

fn paintLyricsPage(_: *const State, cr: ?*cairo.cairo_t, th: Theme, v: *const View) void {
    const ly = v.st.lyrics;
    if (ly == null or ly.?.lines.len == 0) {
        icon(cr, "mic", 494, 252, 40, th.dim, 0.24);
        const connected = v.st.link == .connected;
        const allowed = v.st.scopes.has(.lyrics);
        const title = if (ly == null and connected and allowed)
            "Looking for lyrics"
        else if (connected and !allowed)
            "Lyrics access is not granted"
        else
            "No synced lyrics";
        const subtitle = if (ly == null and connected and allowed)
            "Cider is checking Apple Music for this track."
        else if (connected and !allowed)
            "Reconnect Cider with the lyrics scope for timed lyrics."
        else
            "Cider found this track but no timed lyrics are available.";
        labelCenter(cr, title, 112, 294, 764, 20, text.WEIGHT_SEMIBOLD, th.ink, 0.82);
        labelCenter(cr, subtitle, 112, 324, 764, 10.8, text.WEIGHT_NORMAL, th.dim, 0.50);
        return;
    }
    const lines = ly.?.lines;
    const active = lyricActiveFor(v);
    const idx: usize = if (active >= 0) @intCast(active) else 0;
    haloCached(cr, 494, 286, 340, th.acc, 0.055);

    var off: i32 = -3;
    while (off <= 3) : (off += 1) {
        const absolute = @as(i64, @intCast(idx)) + off;
        if (absolute < 0 or absolute >= @as(i64, @intCast(lines.len))) continue;
        const line = lines[@intCast(absolute)];
        if (line.text.len == 0) continue;
        const y = 286 + @as(f64, @floatFromInt(off)) * 46;
        if (off == 0) {
            // iOS-style lyrics: the current line is the only emphasis. No
            // capsule or border — size, weight and brightness carry it while
            // the neighbouring lines recede.
            labelCenter(cr, line.text, 112, y - 13, 764, 27, text.WEIGHT_BOLD, th.ink, 1.0);
        } else {
            const font_px: f64 = switch (@abs(off)) {
                1 => 18.0,
                2 => 15.0,
                else => 13.0,
            };
            const alpha: f64 = switch (@abs(off)) {
                1 => 0.58,
                2 => 0.30,
                else => 0.16,
            };
            labelCenter(cr, line.text, 112, y - font_px * 0.55, 764, font_px, if (@abs(off) == 1) 500 else text.WEIGHT_NORMAL, th.ink, alpha);
        }
    }
}

fn audioRow(cr: ?*cairo.cairo_t, s: *const State, th: Theme, x: f64, y: f64, label_text: []const u8, on: bool, idx: usize, enabled: bool) void {
    const hover = s.hover.kind == .audio_row and s.hover.index == idx;
    if (hover) fillRound(cr, x - 8, y - 5, 336, 28, 8, th.ink, 0.04);
    label(cr, label_text, x, y, 10.2, 500, if (enabled) th.ink else th.dim, if (enabled) 0.72 else 0.30);
    toggleSwitch(cr, x + 296, y - 1, on and enabled, if (enabled) th.acc else th.dim, th.ink, th.dim);
}

fn audioChoiceRow(cr: ?*cairo.cairo_t, s: *const State, th: Theme, x: f64, y: f64, label_text: []const u8, value: []const u8, enabled: bool) void {
    const hover = s.hover.kind == .audio_listen;
    if (hover and enabled) fillRound(cr, x - 8, y - 5, 336, 26, 8, th.ink, 0.04);
    label(cr, label_text, x, y, 10.2, 500, if (enabled) th.ink else th.dim, if (enabled) 0.72 else 0.30);
    labelRight(cr, value, x + 206, y, 88, 9.4, 500, if (enabled) th.acc else th.dim, if (enabled) 0.86 else 0.30);
    chevron(cr, x + 306, y + 6, 9, false, if (enabled) th.acc else th.dim, if (enabled) 0.55 else 0.22);
}

fn paintConnectPage(s: *const State, cr: ?*cairo.cairo_t, th: Theme, v: *const View) void {
    // API card.
    panel(cr, 112, 92, 372, 200, 20, th.ink);
    icon(cr, if (v.st.link == .connected) "wifi" else "cloud", 134, 116, 18, if (v.st.link == .connected) green else th.dim, 0.82);
    label(cr, "Cider API", 152, 105, 13.5, text.WEIGHT_SEMIBOLD, th.ink, 0.9);
    const status = statusFor(&v.st, th);
    cairo.cairo_arc(cr, 456, 114, 3.2, 0, std.math.tau);
    setColor(cr, status.col, 0.95);
    cairo.cairo_fill(cr);
    labelRightCY(cr, status.text, 330, 100, 114, 9.0, text.WEIGHT_SEMIBOLD, status.col, 0.9);

    const line = switch (v.st.link) {
        .connected => "Connected to Cider on 127.0.0.1:10767",
        .needs_token => "Cider is running, but this widget has no token.",
        .token_invalid => "The saved token was revoked by Cider.",
        .offline => "Cider is not answering on port 10767.",
        .checking => "Checking the local Cider API…",
        .unknown => "Looking for a Cider token and a local player.",
    };
    labelW(cr, line, 128, 136, 340, 9.6, text.WEIGHT_NORMAL, th.dim, 0.58);

    label(cr, "TOKEN", 128, 164, 7.4, text.WEIGHT_SEMIBOLD, th.dim, 0.75);
    const token_text = if (!v.st.has_token)
        "No token saved"
    else if (v.st.token_name.len > 0)
        v.st.token_name
    else
        "Saved token";
    labelW(cr, token_text, 176, 161, 190, 9.4, 500, th.ink, if (v.st.has_token) 0.70 else 0.38);
    const scopes = v.st.scopes;
    label(cr, "SCOPES", 128, 184, 7.4, text.WEIGHT_SEMIBOLD, th.dim, 0.75);
    var scope_buf: [96]u8 = undefined;
    const scope_text = if (!v.st.has_token)
        "Request access to choose scopes"
    else if (!scopes.known)
        "Full access · legacy token"
    else if (scopes.full())
        "Full access · all five scopes"
    else
        std.fmt.bufPrint(&scope_buf, "{d} of 5 scopes available", .{scopes.count()}) catch "Partial access";
    labelW(cr, scope_text, 176, 181, 292, 9.4, 500, th.dim, 0.52);

    const auth_hover = s.hover.kind == .auth;
    if (v.st.link == .connected) {
        pillButton(cr, 124, 212, 148, 30, if (v.st.auth_pending) "Waiting…" else "Re-check", auth_hover, false, th.acc, th.ink);
        icon(cr, "check", 140, 227, 13, green, 0.85);
        pillButton(cr, 282, 212, 96, 30, "Open", s.hover.kind == .open_cider, false, th.acc, th.ink);
    } else {
        pillButton(cr, 124, 212, 148, 30, if (v.st.auth_pending) "Waiting…" else "Request access", auth_hover, true, th.acc, th.ink);
        if (v.st.auth_pending) spinner(cr, 142, 227, 7, th.ink, 0.85) else icon(cr, "lock", 142, 227, 13, th.ink, 0.85);
        pillButton(cr, 282, 212, 96, 30, "Open", s.hover.kind == .open_cider, false, th.acc, th.ink);
    }
    if (v.st.auth_message.len > 0) {
        labelW(cr, v.st.auth_message, 128, 254, 340, 8.6, text.WEIGHT_NORMAL, if (v.st.auth_is_error) red else th.dim, 0.66);
    } else {
        labelW(cr, if (v.st.auth_pending) "Approve the request in Cider to grant playback access." else "Auto-detects tokens from spa-config.yml.", 128, 254, 340, 8.6, text.WEIGHT_NORMAL, th.dim, 0.36);
    }

    // Audio card.
    panel(cr, 500, 92, 372, 200, 20, th.ink);
    icon(cr, "headphones", 522, 116, 18, th.acc, 0.82);
    label(cr, "Audio", 540, 105, 13.5, text.WEIGHT_SEMIBOLD, th.ink, 0.9);
    labelRight(cr, if (v.st.audio.available) "Live" else "Unavailable", 680, 106, 176, 8.8, 500, if (v.st.audio.available) green else th.dim, 0.7);
    const audio_enabled = v.st.audio.available and v.st.scopes.has(.audio);
    audioRow(cr, s, th, 536, 132, "Crossfade", v.st.audio.crossfade, 0, audio_enabled);
    audioRow(cr, s, th, 536, 158, "Automix", v.st.audio.automix, 1, audio_enabled);
    audioRow(cr, s, th, 536, 184, "Sound Check", v.st.audio.normalization, 2, audio_enabled);
    audioRow(cr, s, th, 536, 210, "Dolby Atmos", v.st.audio.atmos, 3, audio_enabled);
    audioChoiceRow(cr, s, th, 536, 236, "Listening", switch (v.st.audio.listening) {
        .off => "Off",
        .game => "Game",
        .antifatigue => "Anti-fatigue",
    }, audio_enabled);
    label(cr, "VOLUME", 536, 261, 7.4, text.WEIGHT_SEMIBOLD, th.dim, 0.75);
    // Slider spans 640..840 — the same strip `targetAt` maps to 0..1.
    const vol = std.math.clamp(v.st.audio.volume, 0, 1);
    const cv_x: f64 = 640;
    const cv_w: f64 = 200;
    const cv_cy: f64 = 267;
    fillRound(cr, cv_x, cv_cy - 3, cv_w, 6, 3, th.ink, 0.13);
    if (vol > 0.01) fillRound(cr, cv_x, cv_cy - 3, @max(cv_w * vol, 6), 6, 3, th.acc, 0.85);
    cairo.cairo_arc(cr, cv_x + cv_w * vol, cv_cy, 5, 0, std.math.tau);
    setColor(cr, th.ink, 0.95);
    cairo.cairo_fill(cr);
    if (!audio_enabled)
        labelW(cr, "Reconnect with the audio scope to change these.", 536, 278, 320, 8.2, text.WEIGHT_NORMAL, th.dim, 0.38);

    // Parties card.
    panel(cr, 112, 304, 372, 182, 20, th.ink);
    icon(cr, "radio", 134, 330, 18, th.pal[1], 0.85);
    label(cr, "Parties", 152, 319, 13.5, text.WEIGHT_SEMIBOLD, th.ink, 0.9);
    _ = labelParagraph(cr, "Cider hosts the session, so this card hands off instead of pretending to be a remote.", 128, 350, 338, 9.5, text.WEIGHT_NORMAL, th.dim, 0.54);
    labelW(cr, "Remote v1 · start or join from the Cider app", 128, 386, 338, 8.6, 500, th.dim, 0.46);
    pillButton(cr, 124, 416, 132, 32, "Open Cider", s.hover.kind == .party, false, th.acc, th.ink);

    // Search handoff.
    panel(cr, 500, 304, 372, 182, 20, th.ink);
    icon(cr, "search", 522, 330, 18, th.pal[2], 0.85);
    label(cr, "Search Apple Music", 540, 319, 13.5, text.WEIGHT_SEMIBOLD, th.ink, 0.9);
    _ = labelParagraph(cr, "Text entry belongs in Cider. Search, party codes, and manual token entry all use the app's real keyboard.", 512, 350, 338, 9.5, text.WEIGHT_NORMAL, th.dim, 0.54);
    pillButton(cr, 512, 416, 140, 32, "Search in Cider", s.hover.kind == .search_cider, false, th.acc, th.ink);
}

// ---------------------------------------------------------------------------
// Entry points

pub fn paintView(s: *const State, cr: ?*cairo.cairo_t, ctx: widget.Ctx, v: *const View) void {
    perf_current_page = s.page;
    var h = std.hash.Wyhash.init(0x63696465);
    h.update(v.now.title);
    h.update(v.now.artist);
    h.update(v.now.album);
    const seed = h.final();
    const th = themeFor(ctx, seed);
    var t = nowNs();
    paintCardCached(cr, th, ctx, seed);
    setPerfSection(perf_card, t);

    t = nowNs();
    paintSidebar(s, cr, th, v);
    setPerfSection(perf_sidebar, t);

    t = nowNs();
    paintHeader(s, cr, th, v);
    setPerfSection(perf_header, t);

    t = nowNs();
    switch (s.page) {
        .now_playing => paintNowPage(s, cr, th, v),
        .queue => paintQueuePage(s, cr, th, v),
        .library => paintLibraryPage(s, cr, th, v),
        .lyrics => paintLyricsPage(s, cr, th, v),
        .connect => paintConnectPage(s, cr, th, v),
    }
    setPerfSection(perf_page, t);

    t = nowNs();
    paintPlayer(s, cr, th, v);
    setPerfSection(perf_player, t);

    t = nowNs();
    paintToast(s, cr, th);
    setPerfSection(perf_toast, t);
}

pub fn paint(s: *const State, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    ensureWatchdog();
    setPhase(perf_paint);
    defer clearPhase();
    perf_current_page = s.page;
    const perf_t = paintStarted();
    defer paintFinished(s.page, perf_t);
    const view_t = nowNs();
    const v = viewFor(@constCast(s));
    {
        const ns = nowNs() -| view_t;
        if (noteBudget(&st_view, ns)) {
            logz.log("perf: budget view {d:.2}ms page={s}", .{ msFromNs(ns), @tagName(s.page) });
        } else if (traceSlow(ns)) {
            logz.log("perf: view {d:.0}us page={s}", .{ ns / std.time.ns_per_us, @tagName(s.page) });
        }
    }
    paintView(s, cr, ctx, &v);
}

test "cider-ui: header and handoff hitboxes follow the painted card" {
    var s = State{};

    s.page = .library;
    s.frame.valid = true;
    try std.testing.expectEqual(Target.Kind.lib_play, targetAt(&s, 800, 34).kind);
    try std.testing.expectEqual(Target.Kind.lib_back, targetAt(&s, 118, 30).kind);

    s.page = .queue;
    try std.testing.expectEqual(Target.Kind.header_search, targetAt(&s, 778, 34).kind);
    try std.testing.expectEqual(Target.Kind.header_open, targetAt(&s, 814, 34).kind);

    s.page = .connect;
    try std.testing.expectEqual(Target.Kind.auth, targetAt(&s, 150, 220).kind);
    try std.testing.expectEqual(Target.Kind.open_cider, targetAt(&s, 300, 220).kind);
    try std.testing.expectEqual(Target.Kind.party, targetAt(&s, 150, 430).kind);
    try std.testing.expectEqual(Target.Kind.search_cider, targetAt(&s, 550, 430).kind);
}

test "cider-ui: connect pill and empty-state CTA open Connect" {
    store.reset();
    defer store.reset();

    var s = State{ .io_ready = true };

    s.page = .queue;
    try std.testing.expectEqual(Target.Kind.connect_cta, targetAt(&s, 450, 337).kind);
    motion(&s, 450, 337);
    try std.testing.expectEqual(Target.Kind.connect_cta, s.hover.kind);
    try std.testing.expect(click(&s, 450, 337));
    try std.testing.expectEqual(Page.connect, s.page);

    s.page = .library;
    s.frame.valid = false;
    try std.testing.expectEqual(Target.Kind.connect_cta, targetAt(&s, 450, 337).kind);
    try std.testing.expect(click(&s, 450, 337));
    try std.testing.expectEqual(Page.connect, s.page);

    s.page = .now_playing;
    try std.testing.expectEqual(Target.Kind.status_pill, targetAt(&s, 700, 34).kind);
    try std.testing.expect(click(&s, 700, 34));
    try std.testing.expectEqual(Page.connect, s.page);
}

// ---------------------------------------------------------------------------
// Offscreen preview / paint smoke test

extern fn cairo_surface_write_to_png(surface: ?*cairo.cairo_surface_t, filename: [*c]const u8) c_int;

const demo_queue_json =
    \\{"data":{"items":[
    \\{"track":{"id":"t1","type":"songs","attributes":{"name":"Blue Hour","artistName":"The Midnight","albumName":"Endless Summer","durationInMillis":248000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t2","type":"songs","attributes":{"name":"Neon Sky","artistName":"Aurora Lane","albumName":"Night Drive","durationInMillis":213000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t3","type":"songs","attributes":{"name":"Glasshouse","artistName":"Mira Vale","albumName":"Soft Focus","durationInMillis":197000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t4","type":"songs","attributes":{"name":"Afterglow","artistName":"The Midnight","albumName":"Endless Summer","durationInMillis":241000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t5","type":"songs","attributes":{"name":"Slow Motion","artistName":"June & The Pines","albumName":"Long Way Home","durationInMillis":226000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t6","type":"songs","attributes":{"name":"Paper Moon","artistName":"Iris North","albumName":"Little Cinema","durationInMillis":185000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t7","type":"songs","attributes":{"name":"Violet Hour","artistName":"Sable","albumName":"Low Light","durationInMillis":264000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t8","type":"songs","attributes":{"name":"Satellite","artistName":"The Midnight","albumName":"Endless Summer","durationInMillis":232000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t9","type":"songs","attributes":{"name":"Warm Static","artistName":"Nova Grey","albumName":"Receiver","durationInMillis":209000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t10","type":"songs","attributes":{"name":"Last Train","artistName":"Aurora Lane","albumName":"Night Drive","durationInMillis":238000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t11","type":"songs","attributes":{"name":"Harbor Lights","artistName":"Mira Vale","albumName":"Soft Focus","durationInMillis":221000,"artwork":{"url":""}}}},
    \\{"track":{"id":"t12","type":"songs","attributes":{"name":"Morning Air","artistName":"June & The Pines","albumName":"Long Way Home","durationInMillis":194000,"artwork":{"url":""}}}}
    \\],"position":1},"meta":{"total":12}}
;

const demo_library_json =
    \\{"data":{"items":[
    \\{"id":"p1","attributes":{"name":"Late Night","artistName":"Cider Radio","trackCount":24}},
    \\{"id":"p2","attributes":{"name":"Soft Focus","artistName":"Mira Vale","trackCount":10}},
    \\{"id":"p3","attributes":{"name":"Night Drive","artistName":"Aurora Lane","trackCount":12}},
    \\{"id":"p4","attributes":{"name":"Endless Summer","artistName":"The Midnight","trackCount":14}},
    \\{"id":"p5","attributes":{"name":"Long Way Home","artistName":"June & The Pines","trackCount":9}},
    \\{"id":"p6","attributes":{"name":"Little Cinema","artistName":"Iris North","trackCount":11}},
    \\{"id":"p7","attributes":{"name":"Receiver","artistName":"Nova Grey","trackCount":8}},
    \\{"id":"p8","attributes":{"name":"Golden Hour","artistName":"Sable","trackCount":16}}
    \\]},"meta":{"total":42}}
;

const demo_songs_json =
    \\{"data":{"items":[
    \\{"id":"s1","attributes":{"name":"Blue Hour","artistName":"The Midnight","albumName":"Endless Summer","durationInMillis":248000}},
    \\{"id":"s2","attributes":{"name":"Neon Sky","artistName":"Aurora Lane","albumName":"Night Drive","durationInMillis":213000}},
    \\{"id":"s3","attributes":{"name":"Glasshouse","artistName":"Mira Vale","albumName":"Soft Focus","durationInMillis":197000}},
    \\{"id":"s4","attributes":{"name":"Afterglow","artistName":"The Midnight","albumName":"Endless Summer","durationInMillis":241000}},
    \\{"id":"s5","attributes":{"name":"Slow Motion","artistName":"June & The Pines","albumName":"Long Way Home","durationInMillis":226000}},
    \\{"id":"s6","attributes":{"name":"Paper Moon","artistName":"Iris North","albumName":"Little Cinema","durationInMillis":185000}},
    \\{"id":"s7","attributes":{"name":"Violet Hour","artistName":"Sable","albumName":"Low Light","durationInMillis":264000}},
    \\{"id":"s8","attributes":{"name":"Satellite","artistName":"The Midnight","albumName":"Endless Summer","durationInMillis":232000}}
    \\]},"meta":{"total":8}}
;

const demo_lyrics_json =
    \\{"data":{"lines":[
    \\{"start":0,"text":"Streetlights running through the rain"},
    \\{"start":8,"text":"Every window wears a different name"},
    \\{"start":16,"text":"We were only passing through"},
    \\{"start":24,"text":"Blue hour, holding on to you"},
    \\{"start":32,"text":"Static on the radio"},
    \\{"start":40,"text":"Half a mile and nowhere left to go"},
    \\{"start":48,"text":"If the morning finds us here"},
    \\{"start":56,"text":"We can disappear"}
    \\],"source":{"provider":"Apple Music","timingType":"Line"}}}
;

fn clearPreview(cr: ?*cairo.cairo_t) void {
    cairo.cairo_save(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
    cairo.cairo_restore(cr);
}

fn writePreview(cr: ?*cairo.cairo_t, name: []const u8) void {
    if (std.c.getenv("EH_CIDER_PREVIEW") == null) return;
    std.Io.Dir.cwd().createDirPath(std.testing.io, "/tmp/opencode/cider-preview") catch return;
    var path: [128]u8 = undefined;
    const z = std.fmt.bufPrintZ(&path, "/tmp/opencode/cider-preview/{s}.png", .{name}) catch return;
    const surf = cairo.cairo_get_target(cr);
    _ = cairo_surface_write_to_png(surf, z.ptr);
}

test "cider-ui: unrelated MPRIS playback does not animate" {
    const edge = bus.Snapshot{
        .have_player = true,
        .bus_name = "org.mpris.MediaPlayer2.edge.instance1",
        .title = "Anime",
        .status = "Playing",
    };
    try std.testing.expect(!animFollowsCider(edge, false));
    try std.testing.expect(animFollowsCider(edge, true));

    const cider_playing = bus.Snapshot{
        .have_player = true,
        .bus_name = "org.mpris.MediaPlayer2.cider",
        .title = "Blue Hour",
        .status = "Playing",
    };
    try std.testing.expect(animFollowsCider(cider_playing, false));

    const cider_paused = bus.Snapshot{
        .have_player = true,
        .bus_name = "org.mpris.MediaPlayer2.cider",
        .title = "Blue Hour",
        .status = "Paused",
    };
    try std.testing.expect(!animFollowsCider(cider_paused, false));
}

test "cider-ui: paint every page offscreen" {
    var q = try cider.parseQueue(std.testing.allocator, demo_queue_json);
    defer q.deinit();
    var lib = try cider.parseLibrary(std.testing.allocator, demo_library_json, .playlists);
    defer lib.deinit();
    var songs = try cider.parseLibrary(std.testing.allocator, demo_songs_json, .playlist_songs);
    defer songs.deinit();
    var ly = try cider.parseLyrics(std.testing.allocator, demo_lyrics_json);
    defer ly.deinit();

    const st = store.Snapshot{
        .link = .connected,
        .version = "2.0.0",
        .has_token = true,
        .token_name = "Event Horizon",
        .scopes = .{ .bits = 0x1f, .known = true },
        .queue = &q,
        .library = &lib,
        .lyrics = &ly,
        .audio = .{ .available = true, .crossfade = true, .automix = false, .atmos = true, .normalization = true, .volume = 0.68, .has_volume = true },
        .now = .{ .available = true, .in_library = true, .rating = 1 },
        .library_kind = .playlists,
        .library_id = "",
    };
    var v = View{
        .st = st,
        .now = .{
            .active = true,
            .playing = true,
            .title = "Blue Hour",
            .artist = "The Midnight",
            .album = "Endless Summer",
            .position_ms = 44000,
            .duration_ms = 248000,
            .flavor = "Lossless",
            .from_mpris = true,
            .shuffle = true,
            .loop = "Playlist",
        },
    };
    const ctx = widget.Ctx{
        .io = undefined,
        .acc_r = 0.38,
        .acc_g = 0.72,
        .acc_b = 1.0,
        .overlay_widget_card = 1.0,
    };

    var state = State{};
    state.page = .now_playing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 900, 580);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    // Cold pass: every cache builds. Warm pass: the steady-state frame the
    // app repaints at ~10Hz. Stats reset between the two so the report shows
    // both profiles, and the `-warm` PNGs must match the cold ones byte for
    // byte (the label blit path has to reproduce the direct raster). Time is
    // frozen so animated painters (equalizer/spinner) don't defeat the check.
    frozen_now_ms = 42_000;
    defer frozen_now_ms = 0;
    paintPreviewSequence(&state, cr, ctx, &v, &songs, &lib, "");
    if (std.c.getenv("EH_CIDER_PERF") != null) printCiderPerf("cold");
    resetElementStats();
    paintPreviewSequence(&state, cr, ctx, &v, &songs, &lib, "-warm");
    if (std.c.getenv("EH_CIDER_PERF") != null) printCiderPerf("warm");
}

fn paintPreviewSequence(
    state: *State,
    cr: ?*cairo.cairo_t,
    ctx: widget.Ctx,
    v: *View,
    songs: *cider.LibraryPage,
    lib: *cider.LibraryPage,
    comptime tag: []const u8,
) void {
    clearPreview(cr);
    state.page = .now_playing;
    paintView(state, cr, ctx, v);
    writePreview(cr, "01-now-playing" ++ tag);

    // Within-pass repeat: same page painted again with caches now populated.
    // If 07 differs from 01, the paint itself is cache/pass-order dependent;
    // if they match, cold-vs-warm deltas come from cross-pass state.
    clearPreview(cr);
    paintView(state, cr, ctx, v);
    writePreview(cr, "07-now-repeat" ++ tag);

    clearPreview(cr);
    state.page = .queue;
    paintView(state, cr, ctx, v);
    writePreview(cr, "02-queue" ++ tag);

    clearPreview(cr);
    state.page = .library;
    paintView(state, cr, ctx, v);
    writePreview(cr, "03-library" ++ tag);

    clearPreview(cr);
    state.page = .library;
    state.frame.set(.playlist_songs, "p1", "Late Night", "Playlist");
    v.st.library = songs;
    v.st.library_kind = .playlist_songs;
    v.st.library_id = "p1";
    paintView(state, cr, ctx, v);
    writePreview(cr, "04-library-collection" ++ tag);

    clearPreview(cr);
    state.frame.valid = false;
    state.page = .lyrics;
    v.st.library = lib;
    v.st.library_kind = .playlists;
    v.st.library_id = "";
    paintView(state, cr, ctx, v);
    writePreview(cr, "05-lyrics" ++ tag);

    clearPreview(cr);
    state.page = .connect;
    paintView(state, cr, ctx, v);
    writePreview(cr, "06-connect" ++ tag);
}
