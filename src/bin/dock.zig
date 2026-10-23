const std = @import("std");
const eh = @import("eh");
const app = @import("app.zig");
const config = eh.config;
const linux = std.os.linux;

const c = @import("c_stdlib");

const layer = eh.wl_layer;
const ns = eh.ns;
const shm_mod = eh.wl_shm;
const cairo = shm_mod.cairo;
const dw = eh.dock_widgets;
const dwp = eh.dock_widgets_paint;
const dock_paint = eh.dock_paint;
const dock_input = eh.dock_input;
const anim = eh.dock_anim;
const pin_order = eh.dock_pin_order;
const foreign = eh.wl_foreign;
const ftl = eh.wl_foreign_toplevels;
const icon_lookup = eh.icon_lookup;
const icon_raster = eh.icon_raster;
const icon_cache = eh.icon_cache;
const os_logo = eh.os_logo;
const cairo_helpers = eh.cairo_helpers;
const tokens = eh.m3_tokens;
const parent_guard = eh.parent_guard;
const logz = eh.logz;
const app_launch = eh.app_launch;
const autostart_mod = eh.autostart;
const clock_paint = eh.widget_clock_paint;
const wc_session = eh.widget_world_clock_session;
const wc_face = eh.widget_world_clock_face;
const wc_panel = eh.widget_world_clock_panel;
const text_layout = eh.text_layout;
const paths = eh.shell_paths;
const shot_cache = eh.shot_cache;
const tray_source = eh.tray_source;
const tray_menu = eh.tray_menu;
const desktop_actions = eh.desktop_actions;
const popup_mod = eh.dock_popup;
const launcher_menu = eh.dock_launcher_menu;
const seat_mod = eh.wl_seat;
const cc_slot = eh.cc_slot;
const cc_host = eh.cc_host;
const cc_data = eh.cc_data;
const cc_live_audio = eh.cc_live_audio;
const cc_live_network = eh.cc_live_network;
const cc_live_bluetooth = eh.cc_live_bluetooth;
const cc_live_vpn = eh.cc_live_vpn;
const cc_live_mixer = eh.cc_live_mixer;
const mixer_card = eh.widget_volume_mixer;
const cc_live_media = eh.cc_live_media;
const cc_live_upower = eh.cc_live_upower;
const bat_paint = eh.widget_battery_paint;
const cc_apply = eh.cc_apply;
const cc_position = eh.cc_position;
const pear_config = eh.pear_config;
const pear_state = eh.pear_state;
const pear_brightness = eh.pear_brightness;
const pear_layout = eh.pear_layout;
const pear_data = eh.pear_data;
const pear_hit = eh.pear_hit;
const pear_paint = eh.pear_paint;
const pear_glyphs = eh.pear_glyphs;
const pear_slot = eh.pear_slot;
const pear_host = eh.pear_host;
const pear_prefs = eh.pear_prefs;
const ov_ws = eh.overview_ws;
const ws_paint = eh.widget_workspaces_paint;
const bt_paint = eh.widget_bluetooth_paint;
const vpn_popup = eh.widget_vpn_popup;
const lay_paint = eh.widget_layout_paint;
const lay_card = eh.widget_layout_popup;
/// Vendored Lucide SVGs for the widget glyphs — the shell's only glyph
/// source.
const svg_icons = eh.svg_icons;
const redeye_svc = eh.redeye;
const wl_session = eh.wl_session;
const chrome_colors = eh.widget_chrome_colors;
const overlay = eh.overlay;
const local_time = eh.desktop_local_time;
const pin_store = eh.pin_store;
const wpaint = eh.widget_weather_paint;
const fancy = eh.widget_weather_fancy_card;
const widget_pill = eh.widget_pill;
const media_paint = eh.widget_media_paint;
const media_perf = eh.media_perf;
const mpris_client = eh.mpris_client;
const notify_push = eh.notify_push;
const notify_stats = eh.notify_stats;
const mpris_art = eh.mpris_art;
const cover_worker = eh.cover_worker;
const cover_cache = eh.cover_cache;
const weather = eh.weather;
const wset = eh.widget_settings;
const wl = eh.wl_c.wl;
const out_mod = eh.wl_output;

/// Rasterized mixer stream icon keyed by stream id (dock-owned, freed with
/// the art list). Stream icons are memoized per stream id.
const MixerArt = struct {
    id: i32 = -1,
    is_input: bool = false,
    pixels: []u8 = &.{},
    w: i32 = 0,
    h: i32 = 0,
};

/// Dock-owned display name for one mixer stream — the desktop entry the
/// stream's identity resolves to (`vesktop` → "Vesktop"), keyed by stream id
/// and freed with the art list (same signature gate as `cc_mixer_sig`).
const StreamName = struct {
    id: i32 = -1,
    name: []u8 = &.{},
};

/// Settings app id constant.
const kSettingsAppId = "event-horizon-settings";
const kRailSettingsAppId = "event-horizon-rail-settings";
/// The Audio Center window's app id (`namespaces.audio_center_app_id`): the
/// launcher slot focuses a live window by this id before spawning.
const kAudioCenterAppId = "event-horizon-audio-center";

/// How often the media widget asks the player where it is. MPRIS reports
/// `Position` only when asked, so this is also the cadence the progress
/// border and the seekbar advance at.
const k_media_poll_ms: u64 = 400;
/// How stale the VPN list may get. While the card is up somebody is reading
/// it, so it is re-read often enough to notice a connection come or go; with
/// only the slot on screen it is warmed rarely, just so the first click does
/// not open onto an empty card. Both go through `live_vpn`'s worker — the
/// read is a `nmcli` spawn — and the retry is what a spawn that never
/// started waits out, so it cannot be attempted every tick.
const k_vpn_poll_open_ms: u64 = 2_000;
const k_vpn_poll_warm_ms: u64 = 30_000;
const k_vpn_poll_retry_ms: u64 = 5_000;
/// The mixer card's read cadence. Unlike the VPN list there is nothing else
/// to keep warm — the pill is a glyph, not a level — so every spawn (a
/// `wpctl status`, one `wpctl inspect` per node, `pw-link -l`, `pw-top -b -n
/// 2`) only happens while the card is up. The hold is what a write buys: a
/// read that started *before* the volume was set must not be adopted after
/// it, or the row snaps back to the value we just overwrote.
const k_mx_poll_ms: u64 = 1_000;
const k_mx_poll_retry_ms: u64 = 3_000;
const k_mx_hold_ms: u64 = 1_200;
/// Row icons the mixer card may memoize. Each is a theme walk plus a decode,
/// against a widget that asks for one per row per frame.
const k_mx_icon_px: i32 = 32;
const k_mx_icon_cap: usize = 32;
/// What to do when a cover source answers with nothing. At start-up the
/// session bus, the network and DNS are all still coming up, so the first
/// fetch fails for reasons that have nothing to do with the URL — the
/// attempt is backed off and made again instead of being taken as final.
/// A source that keeps missing is eventually left alone, so one that will
/// never answer cannot pull a download for the life of the session.
const k_cover_retry_base_ms: u64 = 2_000;
const k_cover_retry_max_ms: u64 = 30_000;
const k_cover_max_misses: u8 = 6;
/// One hover-lift frame, and one frame for anything else that moves on its
/// own: a scrolling marquee, a progress border, a playhead on an open card.
const k_anim_frame_ns: u64 = 16_000_000;
const k_media_frame_ms: u64 = 33;
const k_media_frame_ns: u64 = k_media_frame_ms * 1_000_000;
/// Progress-ring cadence: vsync-rate (60fps), measured affordable.
///
/// A whole-bar paint + commit costs ~2ms on this machine ([media-perf]
/// `paint:avg≈2us (ms) max≈9us` under the 22:31 session), so running the ring
/// at the frame cadence costs ~12% of the frame budget and keeps the dash
/// free of the visible 2fps stepping the ring used to have (500ms, the
/// cadence that read as "chunky"). The profiler's slow_frames counter is what
/// to watch if a low-end GPU ever disagrees: a full-bar repaint dropping
/// there means the next step is pill-only partial damage, not a slower tick.
const k_media_progress_ns: u64 = 16_000_000;

/// A libinput wheel notch arrives as about 15 axis units. Four times that is
/// the step the settings list scrolls by, and the launcher's body is the same
/// kind of scrollable list, so it shares the mapping — and the clamp that
/// keeps a touchpad fling from clearing the whole panel in one event.
const launcher_wheel_scale: f64 = 4.0;
const launcher_wheel_max: f64 = 240.0;

/// Comma-joins into `buf` without allocating, so one log line can carry a
/// list. Truncated at the buffer, never split mid-item.
fn joinList(buf: []u8, items: []const []const u8) []const u8 {
    var off: usize = 0;
    for (items, 0..) |it, i| {
        const sep: usize = if (i == 0) 0 else 1;
        if (off + sep + it.len > buf.len) break;
        if (sep != 0) {
            buf[off] = ',';
            off += 1;
        }
        @memcpy(buf[off..][0..it.len], it);
        off += it.len;
    }
    return buf[0..off];
}

fn getenvStr(key: [:0]const u8) ?[]const u8 {
    const p = c.getenv(key);
    if (p == null) return null;
    return std.mem.span(p);
}

/// Whether two optional strings are the same one. Compared by address, not by
/// content, and that is the point: both sides come from `getenv`, which hands
/// out the same pointer every time for the same variable, so equal addresses
/// mean equal values without walking the bytes.
fn sameStr(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x.ptr == y.ptr and x.len == y.len;
}

/// Resolves one themed name to rasterized pixels against an explicit search
/// path and size. `Dock.loadIcon` is the same thing pinned to the dock's own
/// `icon_px`; this variant exists for the tray's `IconThemePath`, where the
/// item ships a private directory that is not part of any theme.
fn loadIconFrom(
    gpa: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    theme: []const u8,
    name: []const u8,
    size: i32,
) ?dock_paint.IconPx {
    // `Icon=/path/to/icon.svg` is used as-is: the walk's absolute branch only
    // ever probes the name plus `.svg`/`.png` — three stats, no walk to avoid.
    if (std.fs.path.isAbsolute(name)) return loadIconFromWalk(gpa, io, dirs, theme, name, size);
    // The shared cache answers off the theme-directory index it builds once at
    // boot (every icon file in the chain, best size wins) and remembers
    // misses, so a name no theme has costs O(1) instead of the ~90-150 ms
    // filesystem walk — that walk is what stalled the control center's open
    // path for half a second. The mixer icon resolver
    // goes through the same cache, so a hit here matches what the shell draws.
    // Its pixels belong to the cache and are copied, because every caller of
    // this function frees what it gets back.
    if (icon_cache.shared()) |ic| {
        if (ic.getOwned(.app, name, size)) |o| {
            const px = gpa.dupe(u8, o.pixels) catch return null;
            return .{ .pixels = px, .w = o.w, .h = o.h };
        }
        // The index covered every icon directory; the walk's only probe
        // outside them was the flat `/usr/share/pixmaps`, one stat away.
        const found = icon_lookup.lookupPixmaps(gpa, name) orelse return null;
        defer icon_lookup.freeFound(gpa, found);
        return decodeFound(gpa, found, size);
    }
    return loadIconFromWalk(gpa, io, dirs, theme, name, size);
}

/// The original probe: walk every theme directory for `name`, then decode.
/// Kept for the absolute-path branch and for callers with no shared cache
/// (tests, boot before `initGlobal`).
fn loadIconFromWalk(
    gpa: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    theme: []const u8,
    name: []const u8,
    size: i32,
) ?dock_paint.IconPx {
    const found = icon_lookup.lookupAny(gpa, io, dirs, theme, name, @intCast(size)) orelse return null;
    defer icon_lookup.freeFound(gpa, found);
    return decodeFound(gpa, found, size);
}

/// A found icon file as ARGB32 pixels, owned by the caller.
fn decodeFound(gpa: std.mem.Allocator, found: icon_lookup.Found, size: i32) ?dock_paint.IconPx {
    if (found.format == .svg) {
        if (icon_raster.loadSvg(gpa, found.path, size)) |px| {
            return .{ .pixels = px.data, .w = px.w, .h = px.h };
        }
        return null;
    }
    const px = icon_raster.loadPng(gpa, found.path) orelse return null;
    return .{ .pixels = px.data, .w = px.w, .h = px.h };
}

/// Allocation-free fingerprint of the live `app_id` list. Closed windows and
/// windows that never reported an id are left out, so the last one closing is
/// still seen as a change even before `pruneClosed` reclaims the entry.
///
/// `ext_foreign_toplevel_list_v1` batches *every* property update — including
/// page titles — behind one `done`, so without this a browser tab change would
/// rebuild the whole strip (and re-resolve every icon) for nothing.
fn runningSignature(tr: *const foreign.Tracker) u64 {
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    for (tr.windows.items) |w| {
        if (w.closed or w.app_id.len == 0) continue;
        h.update(w.app_id);
        h.update(&[_]u8{0x1f});
    }
    return h.final();
}

const no_slot: usize = std.math.maxInt(usize);

/// One cached strip-cell icon: copied ARGB bytes plus the cairo surface
/// over them. The surface never borrows the strip's pixels, so rebuilds
/// cannot strand it.
const WsSurf = struct {
    pixels: []u8 = &.{},
    surf: ?*cairo.cairo_surface_t = null,
};

/// How many slot icons a strip rebuild carries over from the one it replaces.
/// The strip is a pinned list plus whatever is running, and 64 is well past
/// either; past it, the rest is simply re-resolved.
const k_carry_icons: usize = 64;

/// How far a press has to move before it is a drag rather than a click: six pixels.
const k_pin_drag_px: f64 = 6.0;

/// A press on a pinned app that then moves is a drag, not a launch: the icon
/// leaves the strip and follows the pointer, the run opens a gap where it
/// would drop, and the release rewrites the pin order in the config.
const PinDrag = struct {
    /// A press landed on a pinned app. Six pixels of motion turns this into
    /// `dragging`; a release before that is a plain click on the app.
    candidate: bool = false,
    dragging: bool = false,
    /// The slot being moved. Kept rather than looked up again because every
    /// reorder rebuilds the strip underneath the drag.
    slot: usize = no_slot,
    start_x: f64 = 0,
    start_y: f64 = 0,
    /// The pin's index in `pinned_apps`, before and during the drag.
    from: i32 = -1,
    insert: i32 = -1,
    /// How many pins the drag is over.
    count: usize = 0,
    /// The order the strip is showing, in the config's own spelling. Owned by
    /// the drag; null until something actually moved.
    order: ?[][]const u8 = null,

    fn deinit(self: *PinDrag, gpa: std.mem.Allocator) void {
        if (self.order) |o| {
            for (o) |s| gpa.free(s);
            gpa.free(o);
        }
        self.order = null;
        self.candidate = false;
        self.dragging = false;
        self.slot = no_slot;
        self.start_x = 0;
        self.start_y = 0;
        self.from = -1;
        self.insert = -1;
        self.count = 0;
    }

    /// Hands the preview over to the caller, which owns it from here. The
    /// strip on screen borrows those strings, so the caller has to let the
    /// model be rebuilt before releasing them.
    fn releasePreview(self: *PinDrag) ?[][]const u8 {
        const old = self.order;
        self.order = null;
        return old;
    }
};

/// Minimum spacing between two slider-drag frames: pointer motion arrives faster than the popup can be repainted.
const drag_frame_ms: u64 = 16;

/// Best-effort copy for fallback paths: returns an unowned empty slice on OOM
/// so the dock paints a shorter label instead of crashing.
fn dupText(gpa: std.mem.Allocator, s: []const u8) []u8 {
    if (s.len == 0) return &.{};
    return gpa.dupe(u8, s) catch &.{};
}

const Dock = struct {
    app: *app.App,
    surface: layer.Surface = .{},
    shm: shm_mod.ShmPair,
    /// The buffer the frame in progress is drawn into: picked by `repaint`,
    /// attached by `present`. Nothing else may hold one.
    frame_buf: ?*shm_mod.ShmBuffer = null,
    /// Frames the compositor would not take, and when they were last said
    /// out loud. A dropped frame is the flicker, so it is worth a log line.
    dropped_frames: u32 = 0,
    /// Temporary: the last `bg_alpha` a *completed* draw committed, so a
    /// settings change can be told apart from a paint that never happened.
    diag_last_alpha: f64 = -1.0,
    dropped_log_ms: u64 = 0,
    /// Frames actually put out since the last drag ended — the half of the
    /// picture the dropped count does not tell.
    paint_frames: u32 = 0,
    /// A frame is owed: the last `repaint` had to drop one because the
    /// compositor held both buffers. The release hook (`onShmRelease`) puts it
    /// out the moment a buffer comes back, so the dock never sits frozen
    /// waiting for an unrelated pointer or tick event to redraw.
    pending: bool = false,
    /// A `wl_display_flush` failed — almost always EAGAIN, the compositor has
    /// not drained the socket yet. The commit is then stuck in libwayland's
    /// client buffer, so the compositor never sees the buffer and therefore
    /// never releases it: without a retry that is a *permanent* freeze, not a
    /// dropped frame. The tick keeps pushing until the socket takes the
    /// backlog. This is what `paint: dropped N frame(s) — compositor still
    /// holds both buffers` repeating forever looks like from the inside.
    flush_pending: bool = false,

    /// Granted surface size; the buffer and pill geometry follow this, not the
    /// request, because the compositor is free to hand back something else.
    buf_w: i32 = 0,
    buf_h: i32 = 0,
    req_w: i32 = 0,
    req_h: i32 = 0,
    dock_h: i32 = 0,
    icon_px: i32 = 0,
    radius: i32 = 0,
    gap: i32 = 0,
    /// Output fit factor for sizing: the dock's base metrics (icon, bar
    /// height, radius, gap) are authored for a 1440-tall output, so they're
    /// multiplied by `output_logical_h / 1440` to keep the same fraction of
    /// the screen at any resolution (720p -> 0.5, 4K -> 1.5), in logical px.
    /// 1.0 until the output is known (matches the old fixed sizing).
    fit: f64 = 1.0,

    strip: dw.Strip = .{},
    /// Owned `running_apps` keys derived from the toplevel tracker. The
    /// strip's `Slot.key` borrows these, so they are freed *after*
    /// `strip.deinit`.
    running: [][]const u8 = &.{},
    /// Owned `system_tray` slot keys, same lifetime rule as `running`.
    tray_keys: [][]const u8 = &.{},
    /// Session-bus tray source: either hosts `org.kde.StatusNotifierWatcher`
    /// or attaches to the one that is already up.
    tray: tray_source.Source,
    /// Set when the toplevel set changed inside a Wayland listener; the
    /// rebuild itself does icon I/O, so it is deferred to the next 16 ms tick
    /// instead of running under the dispatch callback.
    dirty: bool = false,
    /// Hash of the live `app_id` list at the last rebuild. `done` fires for
    /// every title change too, so this is what stops a busy browser tab from
    /// rebuilding the whole strip ten times a second.
    running_sig: u64 = 0,
    /// Which checker marked the strip dirty last ("toplevels"/"tray"/
    /// "workspaces"); printed in the model line so a rebuild loop names its
    /// source instead of staying anonymous.
    dirty_src: []const u8 = "init",
    widths: []f64 = &.{},
    geom: ?dw.Geom = null,
    icons: []dock_paint.IconPx = &.{},
    /// What each icon was resolved for — `(kind, key)` and the resolution,
    /// hashed when the slot was built. The rebuild reads *these* instead of
    /// the slot keys, which by then may point into a preview or an arena that
    /// has already been released.
    icon_keys: []u64 = &.{},
    /// Icon buffers lifted out of the model that is being rebuilt. A rebuild
    /// runs on every window that opens or closes, and re-reading and
    /// re-decoding the whole strip's icons each time is what let a Steam
    /// window appearing make a click wait.
    carry_px: [k_carry_icons]dock_paint.IconPx = @splat(.{}),
    carry_sig: [k_carry_icons]u64 = @splat(0),
    carry_taken: [k_carry_icons]bool = @splat(false),
    carry_n: usize = 0,
    label: []u8 = &.{},
    clock_slot: usize = no_slot,
    clock_max_w: f64 = 0,

    // ---- world clock widget -------------------------------------------
    /// The widget's own session (cities, pin, 12/24 h, seconds). It reads the
    /// same settings file the taskbar's session does, so both bars show the
    /// same clocks; every wall-clock call goes through `Dock.epochMs()`,
    /// never the monotonic `nowMs()`.
    wc: wc_session.Session = undefined,
    wc_init: bool = false,
    /// The strip index the open popup belongs to, so the widget can keep its
    /// open-state wash and the settle pass can re-open on the right slot.
    wc_slot: usize = no_slot,
    /// Shift state for the popup's keyboard: the seat event carries no
    /// modifier bits, so the dock tracks the shift keycodes itself.
    wc_shift_down: bool = false,
    /// Whether the panel's transitions were still moving on the last frame:
    /// the frame a transition *ends* on has to be drawn too, or the switch
    /// would freeze mid-flip.
    wc_anim_prev: bool = false,

    /// Storage for the weather glyph `wpaint.state.icon` borrows. Paint runs
    /// every frame, so the slice it points at has to outlive them all without
    /// being reallocated underneath — this is that storage, and only
    /// `applyWeather` ever writes it.
    wx_glyph: [32]u8 = undefined,
    wx_glyph_len: u8 = 0,
    /// The last good reading, kept so the weather card's borrowed strings
    /// (`cityName`, `conditionText`) have somewhere to live.
    wx_reading: weather.Reading = .{},
    /// When `pollWeather` may next start a fetch, in `anim.monotonicNs`
    /// milliseconds. 0 means "on the first tick".
    wx_next_ms: i64 = 0,
    /// The `[dock] output` value the live layer surface was pinned to, owned
    /// so `onReload` can tell a real display change from any other config
    /// edit. Empty means nothing has bound it yet.
    output_want: []const u8 = "",
    /// The entry for the output that surface was created on, or null when
    /// `[dock] output` is `Auto` and the compositor chose one for us. Popups
    /// measure themselves back from the output's edges, so this is what lets
    /// the start menu sit over the slot that opened it rather than in the
    /// middle of the screen.
    output_entry: ?*out_mod.Output = null,

    measure: ?*cairo.cairo_t = null,
    measure_surf: ?*cairo.cairo_surface_t = null,

    // ---- media widget ------------------------------------------------
    /// The player the media slot speaks to. Kept open for the life of the
    /// dock so the 400 ms cadence costs a few round trips rather than a
    /// socket handshake every time.
    media: mpris_client.Client = undefined,
    /// Outbound `notify.push` sender (mpris now-playing + cover art for the
    /// notification daemon) and the last track key published through it.
    notif_push: notify_push.Publisher = undefined,
    notif_last_key: ?[]u8 = null,
    /// Pipeline bench (track→push, art load→attach). Logged on change.
    notif_stats: notify_stats.Stats = undefined,
    notif_stats_reported: u64 = 0,
    notif_stats_report_ms: u64 = 0,
    notif_fail_seen: u64 = 0,
    /// The text run the pill measured for the current track, and the width
    /// of its transport row. Both feed `slotWidth`, and both change only when
    /// the track does.
    media_measured: media_paint.Measured = .{},
    media_ctrl_w: f64 = 0.0,
    /// Playhead between two bus readings. MPRIS does not push positions, so
    /// the elapsed time is projected forward from the last one it gave.
    media_pos: media_paint.Position = .{},
    /// The decoded cover, and the source it was asked for. The source is what
    /// stops one URL being fetched twice — and, being set only once a job has
    /// actually started, lets a refused request be asked for again.
    media_art: media_paint.Art = .{},
    media_art_owner: ?[]u8 = null,
    /// Cover pixels the card was last shown with. A poll swaps new ones in
    /// without freeing the old ones, and `retireMediaArt` keeps them only
    /// while something can still be pointing at them.
    media_art_prev: ?[]u8 = null,
    media_art_key: ?[]u8 = null,
    /// Covers that came back empty for `media_art_key`, and the monotonic ms
    /// at which the next attempt may start: 0 means now, `maxInt` means the
    /// source has had its chances and is done.
    media_art_misses: u8 = 0,
    media_art_retry_ms: u64 = 0,
    /// The track the cover budget above belongs to.
    media_art_track: ?[]u8 = null,
    /// The card keeps its text between polls, but the client rebuilds its
    /// strings on every one, so the few it shows are copied into buffers the
    /// dock owns outright. `syncMediaPopup` hands the card a slice of these.
    media_title_buf: [512]u8 = undefined,
    media_artist_buf: [512]u8 = undefined,
    media_loop_buf: [16]u8 = undefined,
    /// What the last frame asked for: keep the marquee moving, keep the
    /// progress border ticking. Set by `repaint`, read by the tick.
    media_wants_marquee: bool = false,
    media_progress_tick: bool = false,
    /// When the next media poll is due, in `anim.monotonicNs` milliseconds.
    media_next_ms: u64 = 0,

    timer_fd: i32 = -1,
    /// Prefetch countdown: every fifth 1s tick refreshes the overview's
    /// warm screen shots, so opening never pays for the screencopy itself.
    shot_tick: u32 = 0,
    /// One-shot 16 ms timer armed only while `lift` is animating, so an idle
    /// dock never wakes up.
    anim_fd: i32 = -1,
    hover: usize = no_slot,
    /// Slot held at button-down, cleared on release. Only ever produces a
    /// visual on app slots.
    pressed: usize = no_slot,
    /// The pinned-app drag: a press that may still turn into one.
    pin_drag: PinDrag = .{},
    /// Hover lift: 5 px over 165 ms of ease-out-cubic.
    lift: anim.Tween = .{},
    /// Running windows from `ext_foreign_toplevel_list_v1`. Initialised in
    /// `main` before anything can dispatch to it, freed in `deinit`.
    toplevels: foreign.Tracker = undefined,
    /// The same windows through `zwlr_foreign_toplevel_manager_v1`. That
    /// protocol is the only one of the two which can *act* on a window — the
    /// ext list is observe-only — so clicking an app that is already open
    /// focuses it through the handles kept here instead of starting a second
    /// copy.
    ft: ftl.ForeignToplevels = undefined,

    /// The right-click menu — its rows, and the layer surface they are drawn
    /// on. Built fresh on each open, so `reset` is also how it closes.
    popup: popup_mod.Host = undefined,

    /// The start menu's model. The popup host borrows it while the launcher
    /// is up; the dock owns it because the catalog scan needs an allocator and
    /// a `std.Io`, and both live here.
    launcher: launcher_menu.Menu = undefined,
    /// What the launcher's icon search path was last built from. The theme is
    /// copied because the config it came out of is rebuilt on every reload;
    /// the environment is compared by address because a running process's
    /// `environ` never moves.
    launcher_theme: ?[]const u8 = null,
    launcher_home: ?[]const u8 = null,
    launcher_dirs_env: ?[]const u8 = null,

    /// The control-center popup (`controlcenter/host.zig`): the full
    /// quick-settings panel the control-center slot opens. Same surface
    /// discipline as the menu (bottom-anchored overlay as wide as the
    /// dock), own state/snapshot/layout so menu clicks never disturb it.
    cc: cc_host.Host = undefined,
    /// The pear popup (`pear/host.zig`): the compact panel behind the
    /// pear_center slot. Fully separated widget — own kind, own state, own
    /// surface — sharing only the live backend caches below.
    pear: pear_host.Host = undefined,
    /// PID of the running `horizon-overview` copy, if the slot spawned
    /// one that has not been reaped yet. Second click toggles it off.
    ov_pid: ?i32 = null,
    /// Last Hyprland workspace snapshot feeding the overview and the
    /// workspaces strip widget, plus when it was taken. Refreshed on
    /// overview open, on window-set changes and throttled on the tick.
    ws_snap: ?ov_ws.Snapshot = null,
    ws_fetched_ms: i64 = 0,
    /// Workspace strip entries for the dock's workspaces slot(s), rebuilt
    /// with the snapshot. Owned here because the paint path only borrows.
    ws_entries: []ws_paint.Entry = &.{},
    ws_anim: ws_paint.AnimState = .{},
    /// App-icon cairo surfaces for the strip cells, keyed by app id. Copied
    /// bytes (never the strip's own pixels), rebuilt with the icons.
    ws_surfs: std.StringHashMap(WsSurf) = undefined,
    ws_surfs_init: bool = false,
    /// Pear pill runtime + signature (same live sources as `cc_rt`).
    pear_rt: pear_slot.Runtime = .{},
    pear_sig: i64 = 0,
    /// Cached backlight scan (sysfs brightness for the pear row).
    pear_backlight: pear_brightness.Backlight = .{},
    /// Idle inhibitor behind the pear redeye toggle (manager bound at boot
    /// from the Wayland registry; the dock surface is inhibited while on).
    redeye_inhibit: wl_session.Inhibitor = .{},
    redeye_on: bool = false,
    /// Cached pill runtime (`controlcenter/slot.zig`): net/bt/audio/mic
    /// status behind the dock's control-center glyphs. Refreshed on the
    /// animation tick behind the 260 ms gate in `pollCcRuntime`.
    cc_rt: cc_slot.Runtime = .{},
    cc_sig: i64 = 0,
    /// Forecast columns for the control-center snapshot. `buildCcSnapshot`
    /// fills these (not stack memory — the host deep-copies the snapshot
    /// on open, but the slice must still be alive across the call).
    cc_days: [5]cc_data.ForecastDay = @splat(.{}),
    /// Live backend caches behind the popup (`controlcenter/live_*`). Each
    /// owns its strings; refreshed on the 1 s tick while throttled below,
    /// freed here. `null` means "no backend answered yet" and the snapshot
    /// falls back to neutral defaults.
    cc_audio: ?cc_live_audio.Queried = null,
    cc_net: ?cc_live_network.Queried = null,
    cc_bt: ?cc_live_bluetooth.Queried = null,
    cc_media: ?cc_live_media.Queried = null,
    /// Widget-side bluetooth state: the popup card's device rows plus the
    /// snapshot the slot label and the card both read. Derived from `cc_bt`
    /// (which the poll owns) — rebuilt whenever that is, so the borrowed
    /// strings can never outlive the query they point into.
    bt_devs: []bt_paint.Device = &.{},
    bt_snap: bt_paint.Snapshot = .{},
    /// Laptop battery reading (UPower) + when it was last read. The battery
    /// widget's paint reads the `battery_paint.state` global; the host is what
    /// fills it, on a slower cadence than the cc live poll (a battery does not
    /// move fast) — so the read happens here on the host tick instead of
    /// on a dedicated thread.
    bat_next_ms: u64 = 0,
    bat_reading: cc_live_upower.Reading = .{},
    /// Which slot opened each widget card. Only read while that card is up,
    /// which is what makes a *re*-open (its row count moved the height) able
    /// to find its way back to the slot it came from.
    bt_card_slot: usize = no_slot,
    vpn_card_slot: usize = no_slot,
    /// Widget-side VPN state: the card's entry cache (optimistic toggles,
    /// pending timeouts) and the authoritative connection list every frame
    /// reconciles against. The list is read off NetworkManager on the worker
    /// thread (`live_vpn`) — warm whenever a vpn slot exists, and every couple
    /// of seconds while the card is up.
    vpn_store: vpn_popup.Store,
    vpn_conns: []vpn_popup.Connection = &.{},
    /// When the next VPN read may start, and the state of the one in flight.
    /// The host owns both deadlines the way `wx_next_ms` does, so a backend
    /// that never answers cannot be asked again in a tight loop.
    vpn_next_ms: u64 = 0,
    /// The mixer card's landing: the whole card's worth of borrowed state —
    /// device and stream tables, the card/profile list, the footer readouts —
    /// built on the worker (`live_mixer`) and swapped in here in one piece.
    /// The popup borrows pointers into it, so this is what keeps them alive,
    /// and it survives the card closing so a reopen draws at once.
    mx_data: ?*cc_live_mixer.Data = null,
    /// When the next mixer read may start, and until when landings are
    /// refused (the write window described at `k_mx_hold_ms`).
    mx_next_ms: u64 = 0,
    mx_hold_ms: u64 = 0,
    /// The card's row icons, memoized under the names the widget asks for.
    mx_icons: std.ArrayListUnmanaged(MxIcon) = .empty,
    cc_next_live_ms: u64 = 0,
    /// Last time the open control-center surface was re-placed for a *row
    /// count* change — 800 ms settle debounce.
    cc_settle_ms: u64 = 0,
    /// Last Wi-Fi error line shown in the network panel (e.g. empty-password
    /// submit). Cleared on the next successful poll.
    cc_wifi_err: [96]u8 = undefined,
    cc_wifi_err_len: usize = 0,
    /// Mixer stream art, resolved from desktop entries + theme and keyed by
    /// stream id. Re-resolved only when the stream set changes (`cc_mixer_sig`).
    cc_mixer_art: std.ArrayList(MixerArt) = .empty,
    cc_mixer_sig: u64 = 0,
    /// Desktop-entry display names for the same stream set (same gate).
    cc_stream_names: std.ArrayList(StreamName) = .empty,
    /// Rasterized MPRIS `file://` art + the URL it came from (re-rasterized
    /// only when the track's art changes).
    cc_art_url: []const u8 = "",
    cc_art: dock_paint.IconPx = .{},
    /// Snapshot scratch rows for `buildCcSnapshot` (strings borrow the live
    /// caches; the host deep-copies on open/refresh, so these only need to
    /// survive the call).
    cc_snap_aps: [8]cc_data.WifiAp = @splat(.{}),
    cc_snap_bt: [8]cc_data.BluetoothDevice = @splat(.{}),
    cc_snap_outdev: [12]cc_data.OutputDevice = @splat(.{}),
    cc_snap_indev: [12]cc_data.InputDevice = @splat(.{}),
    cc_snap_outs: [8]cc_data.MixerStream = @splat(.{}),
    cc_snap_ins: [8]cc_data.MixerStream = @splat(.{}),

    /// Slider-drag frame gate (`dragFrameDue`): the earliest monotonic ms at
    /// which the next motion-driven drag frame may go out.
    drag_next_paint_ms: u64 = 0,
    /// Set only while a *motion-dispatched* drag action is being applied, so
    /// the 16 ms gate covers pointer motion and nothing else: the press that
    /// jumps the slider to the pointer, a scroll notch and the release that
    /// ends the drag all paint immediately.
    drag_motion_paint_off: bool = false,

    /// Which surface the pointer is on. `seat.focus_surface` answers the same
    /// question but is cleared *before* `onLeave` runs, so by the time the
    /// leave handler is in flight there is nothing left to ask.
    ptr_on: PointerSurface = .none,

    const PointerSurface = enum { none, dock, popup };

    /// Both the hover lift and the press scale skip the same exclusion list
    /// of widget kinds, which leaves only real app icons.
    fn liftEligible(kind: dw.Kind) bool {
        return kind == .app;
    }

    /// Control-center pill runtime (`controlcenter/slot.zig`). Derived from
    /// the live caches (`pollCcLive`): NetworkManager state, BlueZ power,
    /// PipeWire volumes. Before the first poll everything is neutral
    /// (disconnected, 100 unmuted, mic idle) — the same zero-initialized
    /// `Snapshot`s the services start from.
    fn pollCcRuntime(self: *Dock) cc_slot.Runtime {
        var rt = cc_slot.Runtime{};
        if (self.cc_net) |*q| {
            rt.net_up = q.snap.connected;
            rt.net_wifi = q.snap.wifi;
        }
        if (self.cc_bt) |*q| {
            rt.bt_powered = q.snap.powered;
            rt.bt_connected = false;
            for (q.device_list.items) |d| {
                if (d.connected) {
                    rt.bt_connected = true;
                    break;
                }
            }
        }
        if (self.cc_audio) |*q| {
            rt.sink_volume_pct = q.snap.out.volume_pct;
            rt.sink_muted = q.snap.out.muted;
            rt.mic_running = q.snap.out_streams.len > 0 or q.snap.in_streams.len > 0;
            rt.mic_muted = q.snap.in.muted;
        }
        return rt;
    }

    fn refreshCcRuntime(self: *Dock) bool {
        const rt = self.pollCcRuntime();
        self.cc_rt = rt;
        const cfg = &self.app.loaded.cfg;
        // Widths need the count for every control-center instance on the
        // strip; the first one decides (there is at most one in practice).
        for (self.strip.slots) |s| {
            if (s.kind != .control_center) continue;
            const ccfg = cc_slot.loadCfg(cfg, s.key);
            return cc_slot.signatureChanged(&self.cc_sig, ccfg, rt);
        }
        return false;
    }

    /// Same live sources as `pollCcRuntime`, mapped onto pear's own runtime
    /// struct (identical shape, separate type — the widgets share backends,
    /// never state).
    fn pearRuntime(rt: cc_slot.Runtime) pear_slot.Runtime {
        return .{
            .net_up = rt.net_up,
            .net_wifi = rt.net_wifi,
            .bt_connected = rt.bt_connected,
            .bt_powered = rt.bt_powered,
            .sink_muted = rt.sink_muted,
            .sink_volume_pct = rt.sink_volume_pct,
            .mic_running = rt.mic_running,
            .mic_muted = rt.mic_muted,
        };
    }

    fn refreshPearRuntime(self: *Dock) bool {
        const rt = pearRuntime(self.pollCcRuntime());
        self.pear_rt = rt;
        const cfg = &self.app.loaded.cfg;
        for (self.strip.slots) |s| {
            if (s.kind != .pear_center) continue;
            const pcfg = pear_slot.loadCfg(cfg, s.key);
            return pear_slot.signatureChanged(&self.pear_sig, pcfg, rt);
        }
        return false;
    }

    /// Any slider drag in flight, either popup. A drag writes the backend,
    /// so anything that would stall the loop behind child processes waits
    /// until it is over.
    fn dragging(self: *Dock) bool {
        return self.cc.dragging_output or self.cc.dragging_input or self.cc.dragging_mixer or
            self.pear.dragging_vol or self.pear.dragging_in or self.pear.dragging_bri or
            (self.popup.kind == .volume_mixer and self.popup.mx_ui.drag_active);
    }

    /// Pointer motion outruns painting, so a drag pushes at most one frame
    /// per `drag_frame_ms` — motion redraws gate the same way
    /// (16 ms). State updates are
    /// never gated; this only decides whether pixels go out *now*. A skipped
    /// frame is pushed by the next motion, or by the release that ends the
    /// drag, so the final value always lands.
    fn dragFrameDue(self: *Dock, now_ms: u64) bool {
        if (now_ms < self.drag_next_paint_ms) return false;
        self.drag_next_paint_ms = now_ms + drag_frame_ms;
        return true;
    }

    /// Live backend poll behind the pill + popup (`controlcenter/live_*`).
    /// Throttled (2 s idle, 1 s while the popup is open); every backend
    /// fails soft to its previous cache. Returns true when the pill needs a
    /// relayout (signature moved) or the open popup was refreshed.
    fn pollCcLive(self: *Dock, now_ms: u64, force: bool) bool {
        if (!force and now_ms < self.cc_next_live_ms) return false;
        // A slider drag is writing the backend right now: its query would
        // spawn children on the very pointer thread the drag is feeding, and
        // read back values the writes are about to replace. Defer the poll —
        // the suppress window keeps the popup showing what we wrote meanwhile,
        // and `cc_next_live_ms` was not advanced, so the first tick after the
        // release re-polls immediately.
        if (self.dragging()) return false;
        const step: u64 = if (self.cc.open or self.pear.open) 1000 else 2000;
        self.cc_next_live_ms = now_ms + step;
        const gpa = self.app.gpa;
        // The device/stream tables are only painted by an open popup; the
        // idle pill poll reads just the two defaults.
        const detail = force or self.cc.open or self.pear.open;
        if (cc_live_audio.query(gpa, self.app.io, detail)) |queried| {
            self.freeCcAudio();
            self.cc_audio = queried;
            // A write may still be in flight when the poll's reads ran: show
            // what we wrote until the backend has caught up (`audioIgnore…`).
            if (self.cc_audio) |*qc| cc_apply.suppressEcho(now_ms, &qc.snap);
        }
        if (cc_live_network.query(gpa)) |q| {
            self.freeCcNet();
            self.cc_net = q;
            self.cc_wifi_err_len = 0;
        }
        // A fresh reading for the pill *and* the card, swapped in as one:
        // both read the same rows, and only the swap can tell a real change
        // from a query that handed out new pointers.
        const bt_changed = self.installBtQuery(cc_live_bluetooth.query(gpa));
        if (cc_live_media.query(gpa)) |q| {
            self.freeCcMedia();
            self.cc_media = q;
        }
        self.resolveCcMixerArt();
        self.resolveCcMediaArt();
        var changed = self.refreshCcRuntime();
        changed = self.refreshPearRuntime() or changed;
        changed = bt_changed or changed;
        // The battery slot re-measures when its reading moved (an absent battery
        // reads a bare glyph, a present one the glyph + `NN%` label, so the slot
        // width itself depends on the reading).
        // The bluetooth card follows its own reading while it is up: a
        // redraw when the swap found something, and a re-open instead when
        // the row count moved the height the card was sized for.
        if (self.popup.kind == .bluetooth and bt_changed) {
            if (self.settleWidgetCard()) changed = true else self.popupRefresh();
        }
        if (self.cc.open) {
            const snap = self.buildCcSnapshot();
            self.cc.setSnapshot(snap);
            self.cc.relayout(now_ms, false);
            // Row counts move while the popup is open (a BT device appears,
            // a stream starts, an AP list lands): grow the surface the way
            // `popup_finish_draw` settles it, debounced so a count that
            // moves on every poll cannot thrash the surface.
            self.ccSettleResize(now_ms);
            self.ccRefresh();
            changed = true;
        }
        if (self.pear.open) {
            self.refreshPearPopup();
            changed = true;
        }
        return changed;
    }

    /// Read the laptop battery (UPower) and republish it as the widget paint's
    /// global state. On a ~5 s cadence — slower than the cc live poll, since a
    /// battery does not move fast — and returns whether the reading *changed*,
    /// so a stationary battery never forces a repaint. `battery_paint.state` is
    /// what the slot and the popup read; writing it here happens on the frame thread.
    fn pollBattery(self: *Dock, now_ms: u64) bool {
        if (now_ms < self.bat_next_ms) return false;
        self.bat_next_ms = now_ms + 5000;
        const r = cc_live_upower.query(self.app.gpa);
        const changed = !std.meta.eql(self.bat_reading, r);
        self.bat_reading = r;
        bat_paint.state = .{
            .percentage = r.percentage,
            .state = bat_paint.BatteryState.fromRaw(r.state),
            .is_present = r.is_present,
            .on_battery = r.on_battery,
        };
        return changed;
    }

    fn freeCcAudio(self: *Dock) void {
        if (self.cc_audio) |*q| {
            q.deinit();
            self.cc_audio = null;
        }
    }

    fn freeCcNet(self: *Dock) void {
        if (self.cc_net) |*q| {
            q.deinit();
            self.cc_net = null;
        }
    }

    fn freeCcBt(self: *Dock) void {
        // The widget's rows point into these strings, so they go with them.
        self.freeBtWidget();
        if (self.cc_bt) |*q| {
            q.deinit();
            self.cc_bt = null;
        }
    }

    fn freeCcMedia(self: *Dock) void {
        if (self.cc_media) |*q| {
            q.deinit();
            self.cc_media = null;
        }
    }

    fn freeCcLive(self: *Dock) void {
        self.freeCcAudio();
        self.freeCcNet();
        self.freeCcBt();
        self.freeCcMedia();
    }

    // -----------------------------------------------------------------
    // Bluetooth + VPN widget state — the pill's reading, and the two cards
    // -----------------------------------------------------------------

    /// Drop the widget's device rows. Only the array is ours: every string
    /// points into `cc_bt`, which is why this hangs off `freeCcBt` rather
    /// than off the card — the rows cannot outlive the query they were
    /// built from, whatever tears that down.
    fn freeBtWidget(self: *Dock) void {
        if (self.bt_devs.len > 0) self.app.gpa.free(self.bt_devs);
        self.bt_devs = &.{};
        self.bt_snap = .{};
    }

    /// Hand the current reading to the card, if one is up. Every caller has
    /// just changed `bt_devs`/`bt_snap`, so this is the single place that
    /// keeps the two in step.
    fn pushBtToCard(self: *Dock) void {
        if (self.popup.kind != .bluetooth) return;
        self.popup.bt_snap = self.bt_snap;
        self.popup.bt_devs = self.bt_devs;
    }

    /// Install a fresh BlueZ reading — `null` when no backend answered — and
    /// report whether the pill or the card would now draw something
    /// different.
    ///
    /// The new rows are built while the outgoing pair is still alive, which
    /// is the only moment both sets exist. Comparing them there is the only
    /// honest test: a query hands out fresh strings every time, so by
    /// *pointer* everything changes on every poll, and comparing after the
    /// swap would only ever measure the fresh rows against the empty state
    /// they were installed out of.
    fn installBtQuery(self: *Dock, fresh: ?cc_live_bluetooth.Queried) bool {
        const gpa = self.app.gpa;
        var devs: []bt_paint.Device = &.{};
        var snap: bt_paint.Snapshot = .{};
        if (fresh) |qp| {
            devs = bt_paint.devicesFromQueried(gpa, &qp) catch &.{};
            snap = bt_paint.snapshotFromQueried(&qp, devs);
        }
        const changed = !std.meta.eql(self.bt_snap, snap) or !btRowsEqual(self.bt_devs, devs);
        // Old rows and old query go together — the rows point into it — and
        // only then does the new pair take its place.
        self.freeCcBt();
        self.cc_bt = fresh;
        self.bt_devs = devs;
        self.bt_snap = snap;
        self.pushBtToCard();
        return changed;
    }

    /// Content equality for the device rows. The strings are re-duped on
    /// every poll, so only a value comparison can tell a real change from a
    /// query that merely handed out new pointers.
    fn btRowsEqual(a: []const bt_paint.Device, b: []const bt_paint.Device) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x.kind != y.kind or x.paired != y.paired or x.connected != y.connected or
                x.battery_pct != y.battery_pct) return false;
            if (!std.mem.eql(u8, x.path, y.path)) return false;
            if (!std.mem.eql(u8, x.address, y.address)) return false;
            if (!std.mem.eql(u8, x.alias, y.alias)) return false;
        }
        return true;
    }

    fn freeVpnConns(self: *Dock) void {
        const gpa = self.app.gpa;
        for (self.vpn_conns) |*conn| {
            gpa.free(conn.uuid);
            gpa.free(conn.name);
        }
        gpa.free(self.vpn_conns);
        self.vpn_conns = &.{};
    }

    /// Adopt a finished read as the card's authoritative list. The strings
    /// are *moved* — `live_vpn` duped them for exactly this — so only the
    /// container it carried is dropped: one list, one set of frees, no copy
    /// of every name and uuid. Answers whether the list changed.
    fn adoptVpnRows(self: *Dock, rows: []cc_live_vpn.Connection) bool {
        const gpa = self.app.gpa;
        const out = gpa.alloc(vpn_popup.Connection, rows.len) catch {
            cc_live_vpn.freeConnections(gpa, rows);
            return false;
        };
        for (rows, 0..) |r, i| out[i] = .{ .uuid = r.uuid, .name = r.name, .active = r.active };
        gpa.free(rows);
        const changed = !vpnRowsEqual(self.vpn_conns, out);
        self.freeVpnConns();
        self.vpn_conns = out;
        // Reconcile before anything measures: `heightFor(store.count())` has
        // to see the rows the next paint would, or a re-open would size to
        // the list underneath it rather than to the one on screen.
        self.vpn_store.syncEntries(self.vpn_conns, vpn_popup.monotonicNs()) catch {};
        return changed;
    }

    fn vpnRowsEqual(a: []const vpn_popup.Connection, b: []const vpn_popup.Connection) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x.active != y.active) return false;
            if (!std.mem.eql(u8, x.uuid, y.uuid)) return false;
            if (!std.mem.eql(u8, x.name, y.name)) return false;
        }
        return true;
    }

    /// Move whatever the VPN worker finished into the warm cache (and, if a
    /// card is up, in front of it). False when nothing has landed.
    fn takeVpnRows(self: *Dock) bool {
        var rows: ?[]cc_live_vpn.Connection = null;
        if (!cc_live_vpn.take(&rows)) return false;
        return self.adoptVpnRows(rows.?);
    }

    fn hasVpnSlot(self: *Dock) bool {
        for (self.strip.slots) |s| {
            if (s.kind == .vpn) return true;
        }
        return false;
    }

    /// Keep the VPN list warm. A slot that exists means somebody may click
    /// it, and an open card means somebody did — the card wants a fresh list
    /// every couple of seconds, the slot only enough of one that the first
    /// click does not land on an empty card. The read itself is a spawn, so
    /// it goes to `live_vpn`'s worker and the tick adopts the answer.
    fn pollVpn(self: *Dock, now_ms: u64) void {
        if (!self.hasVpnSlot()) return;
        if (now_ms < self.vpn_next_ms) return;
        const open = self.popup.kind == .vpn;
        if (!cc_live_vpn.request(self.app.gpa, self.app.io)) {
            if (!cc_live_vpn.idle()) return; // still in flight: not a failure
            // The spawn never started. Back off like a read that ran, or one
            // allocator problem would be retried every tick.
            self.vpn_next_ms = now_ms + k_vpn_poll_retry_ms;
            return;
        }
        self.vpn_next_ms = now_ms + if (open) k_vpn_poll_open_ms else k_vpn_poll_warm_ms;
    }

    /// A widget card was opened for the row count it had. When the live
    /// reading moves that count, the card is re-opened at its own slot rather
    /// than painted into a buffer sized for the old one — the settle the
    /// control centre does for its row growth, minus the debounce: this
    /// height only moves when rows do.
    fn settleWidgetCard(self: *Dock) bool {
        const cfg = &self.app.loaded.cfg;
        switch (self.popup.kind) {
            .bluetooth => {
                if (self.bt_card_slot == no_slot) return false;
                const want: i32 = @intFromFloat(@round(
                    bt_paint.popupHeight(self.app.gpa, cfg, &self.bt_snap, self.bt_devs) catch return false,
                ));
                if (want == self.popup.card_h) return false;
                self.showBluetooth(self.bt_card_slot);
                return true;
            },
            .vpn => {
                if (self.vpn_card_slot == no_slot) return false;
                const want: i32 = @intFromFloat(@round(vpn_popup.heightFor(self.vpn_store.count())));
                if (want == self.popup.card_h) return false;
                // Read the centre before the reset that re-opens it clears it.
                const cx = self.popup.card_cx;
                self.openVpnCard(self.vpn_card_slot, cx);
                return true;
            },
            else => return false,
        }
    }

    /// Open the window-layout card over its slot. Unlike the two status
    /// cards there is nothing to fetch first: the entries are the running
    /// compositor's own layout ids, read through `layout_paint` on every
    /// paint, so the card is complete the moment it is placed.
    fn showLayout(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        const cx = self.slotCentreX(idx) orelse return;
        self.popup.reset();
        self.popup.widget_cfg = &self.app.loaded.cfg;
        const ok = self.popup.openLayout(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            cx,
            self.fit,
        );
        if (!ok) {
            logz.log("layout card: present failed slot={d}", .{idx});
            self.popup.reset();
            return;
        }
        logz.log("layout card: open slot={d} at x={d}", .{ idx, cx });
        if (!self.app.conn.flush()) logz.log("layout card: flush failed", .{});
    }

    /// The bluetooth slot's card, on the same surface discipline as the
    /// calendar: centred on the slot, painted from the dock's own BlueZ
    /// reading, which the poll keeps refreshed for as long as it is up.
    fn showBluetooth(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        const cx = self.slotCentreX(idx) orelse return;
        // The cache may be a poll old — or from before the adapter came up —
        // so the card opens on a fresh reading rather than on whatever the
        // last tick happened to catch. A backend that is not there simply
        // installs `null`, which is the same empty card.
        _ = self.installBtQuery(cc_live_bluetooth.query(self.app.gpa));
        self.popup.reset();
        self.popup.widget_cfg = &self.app.loaded.cfg;
        self.popup.bt_snap = self.bt_snap;
        self.popup.bt_devs = self.bt_devs;
        const ok = self.popup.openBluetooth(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            cx,
            &self.app.loaded.cfg,
            &self.bt_snap,
            self.bt_devs,
            self.fit,
        );
        if (!ok) {
            logz.log("bluetooth card: present failed slot={d}", .{idx});
            self.popup.reset();
            return;
        }
        self.bt_card_slot = idx;
        logz.log(
            "bluetooth card: open slot={d} at x={d} rows={d} powered={}",
            .{ idx, self.popup.card_cx, self.bt_devs.len, self.bt_snap.powered },
        );
        if (!self.app.conn.flush()) logz.log("bluetooth card: flush failed", .{});
    }

    /// The vpn slot's card. The rows come from whatever the warm poll has
    /// already fetched — the read is a spawn, and a spawn on the click would
    /// be the stall the worker exists to avoid — so the card opens on the
    /// last answer and asks for a fresh one that lands a tick later.
    fn showVpn(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        const cx = self.slotCentreX(idx) orelse return;
        _ = self.takeVpnRows();
        self.openVpnCard(idx, cx);
        self.vpn_next_ms = 0;
        self.pollVpn(Dock.nowMs());
    }

    /// Place the vpn card at `cx`. Split from `showVpn` so a card whose row
    /// count moved can be re-opened without asking the backend anything.
    fn openVpnCard(self: *Dock, idx: usize, cx: i32) void {
        self.popup.reset();
        self.popup.widget_cfg = &self.app.loaded.cfg;
        self.popup.vpn_store = &self.vpn_store;
        self.popup.vpn_conns = self.vpn_conns;
        const ok = self.popup.openVpn(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            cx,
            self.vpn_store.count(),
            self.fit,
        );
        if (!ok) {
            logz.log("vpn card: present failed slot={d}", .{idx});
            self.popup.reset();
            return;
        }
        self.vpn_card_slot = idx;
        logz.log("vpn card: open slot={d} at x={d} rows={d}", .{ idx, cx, self.vpn_conns.len });
        if (!self.app.conn.flush()) logz.log("vpn card: flush failed", .{});
    }

    /// The card's own hit-test, then the verb it asked for. Every bus call
    /// here is one the widget named (`bluetooth_paint` → `live_bluetooth`),
    /// so the input path never decides what to send. Answers whether the card
    /// stays up: its own background leaves it there, the close box and the
    /// space around the card dismiss it.
    fn runBluetoothPopupClick(self: *Dock) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const x: i32 = @intFromFloat(@round(seat.pointer_x));
        const y: i32 = @intFromFloat(@round(seat.pointer_y));
        switch (self.popup.cardClick(x, y)) {
            .dismiss => return false,
            .bluetooth => {},
            // A press that hit the card but no control: nothing to do, and
            // nothing that should take the card away.
            else => return true,
        }
        const gpa = self.app.gpa;
        const r = self.popup.bt_click;
        const adapter: []const u8 = if (self.cc_bt) |*q| q.snap.adapter_path else "";
        switch (r.verb) {
            .none => {},
            .set_powered => _ = bt_paint.setPowered(gpa, r.power_on),
            .connect => if (r.index < self.bt_devs.len) bt_paint.connectDevice(self.bt_devs[r.index].path, adapter),
            .disconnect => if (r.index < self.bt_devs.len) {
                _ = bt_paint.disconnectDevice(gpa, self.bt_devs[r.index].path);
            },
            .pair => if (r.index < self.bt_devs.len) bt_paint.pairDevice(self.bt_devs[r.index].path, adapter),
            .forget => if (r.index < self.bt_devs.len) {
                _ = bt_paint.forgetDevice(gpa, adapter, self.bt_devs[r.index].path);
            },
            .start_discovery => bt_paint.setDiscovery(gpa, adapter, true),
            .stop_discovery => bt_paint.setDiscovery(gpa, adapter, false),
        }
        if (r.verb != .none) logz.log("bluetooth card: verb={s} idx={d}", .{ @tagName(r.verb), r.index });
        return true;
    }

    /// The layout card answers for itself: `clickAction` swaps the layout as
    /// part of resolving the click, so there
    /// is no verb to hand back — only "stay up" or "close".
    fn runLayoutPopupClick(self: *Dock) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const x: i32 = @intFromFloat(@round(seat.pointer_x));
        const y: i32 = @intFromFloat(@round(seat.pointer_y));
        return switch (self.popup.cardClick(x, y)) {
            .dismiss => false,
            // The layout card only ever answers `.none`/`.layout`; any other
            // card's verb reaching this handler isn't ours to act on, and only
            // `.dismiss` tears the popup down.
            else => true,
        };
    }

    /// Same shape for the vpn card. The verbs are `nmcli` in a thread — a VPN
    /// that takes ten seconds to dial must not hold the pointer — and the
    /// store already shows the optimistic answer, so all that is left here is
    /// asking for the list again to see the backend agree.
    fn runVpnPopupClick(self: *Dock) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const x: i32 = @intFromFloat(@round(seat.pointer_x));
        const y: i32 = @intFromFloat(@round(seat.pointer_y));
        switch (self.popup.cardClick(x, y)) {
            .dismiss => return false,
            .vpn => {},
            else => return true,
        }
        const r = self.popup.vpn_click;
        if (r.verb == .none) return true;
        if (r.index >= self.vpn_store.count()) return true;
        const uuid = self.vpn_store.uuid(r.index);
        switch (r.verb) {
            .none => unreachable,
            .activate => cc_live_vpn.activateThread(self.app.io, uuid),
            .deactivate => cc_live_vpn.deactivateThread(self.app.io, uuid),
            .remove => cc_live_vpn.removeThread(self.app.io, uuid),
        }
        logz.log("vpn card: verb={s} idx={d}", .{ @tagName(r.verb), r.index });
        self.vpn_next_ms = 0;
        self.pollVpn(Dock.nowMs());
        return true;
    }

    // -----------------------------------------------------------------
    // The volume-mixer card
    // -----------------------------------------------------------------

    /// One row icon: the name the widget asked for, the bytes cairo reads
    /// out of, and the surface over them. `StreamIcons.get` runs per row per
    /// frame and the lookup behind it walks the whole theme, so misses are
    /// memoized too — a name no theme has must not be searched every frame.
    const MxIcon = struct {
        name: []const u8,
        pixels: []u8,
        surf: ?*cairo.cairo_surface_t,
    };

    /// `StreamIcons.get` for the card: a themed name to a surface, cached.
    /// Empty result and all: the widget's own cascade falls back to its gray
    /// dot, which is the fallback when the theme search comes up empty.
    fn mxIconSurf(ctx: *anyopaque, name: []const u8) ?*cairo.cairo_surface_t {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        if (name.len == 0) return null;
        const gpa = self.app.gpa;
        for (self.mx_icons.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.surf;
        }
        if (self.mx_icons.items.len >= k_mx_icon_cap) return null;
        const cfg = &self.app.loaded.cfg;
        const theme: []const u8 = if (cfg.dock.icon_theme.len > 0) cfg.dock.icon_theme else "hicolor";
        var px: dock_paint.IconPx = .{};
        if (icon_lookup.dataDirs(gpa, getenvStr("XDG_DATA_HOME"), getenvStr("HOME"), getenvStr("XDG_DATA_DIRS"))) |dirs| {
            defer icon_lookup.freeDirs(gpa, dirs);
            px = loadIconFrom(gpa, self.app.io, dirs, theme, name, k_mx_icon_px) orelse .{};
        } else |_| {}
        defer if (px.pixels.len > 0) gpa.free(px.pixels);
        const owned_name = gpa.dupe(u8, name) catch return null;
        var pixels: []u8 = &.{};
        var surf: ?*cairo.cairo_surface_t = null;
        if (px.pixels.len > 0 and px.w > 0 and px.h > 0) {
            if (gpa.dupe(u8, px.pixels)) |copy| {
                const s = cairo.cairo_image_surface_create_for_data(
                    copy.ptr,
                    cairo.CAIRO_FORMAT_ARGB32,
                    px.w,
                    px.h,
                    px.w * 4,
                );
                if (cairo.cairo_surface_status(s) == cairo.CAIRO_STATUS_SUCCESS) {
                    pixels = copy;
                    surf = s;
                } else {
                    cairo.cairo_surface_destroy(s);
                    gpa.free(copy);
                }
            } else |_| {}
        }
        self.mx_icons.append(gpa, .{ .name = owned_name, .pixels = pixels, .surf = surf }) catch {
            gpa.free(owned_name);
            if (surf) |s| cairo.cairo_surface_destroy(s);
            gpa.free(pixels);
            return null;
        };
        return surf;
    }

    fn freeMxIcons(self: *Dock) void {
        const gpa = self.app.gpa;
        for (self.mx_icons.items) |e| {
            if (e.surf) |s| cairo.cairo_surface_destroy(s);
            gpa.free(e.pixels);
            gpa.free(e.name);
        }
        self.mx_icons.deinit(gpa);
        self.mx_icons = .empty;
    }

    /// Hand the current landing to the card, if one is up. Everything the
    /// widget draws — snapshot, card/profile table, footer readouts — is
    /// borrowed from `mx_data`, so this runs the moment a landing is adopted,
    /// before any frame that would read the one it replaced.
    fn pushMixerToCard(self: *Dock) void {
        if (self.popup.kind != .volume_mixer) return;
        const d = self.mx_data orelse return;
        self.popup.mx_snap = &d.snap;
        self.popup.mx_cards = d.cards;
        self.popup.mx_engine = d.engine;
        self.popup.mx_top = d.top;
    }

    /// Adopt what the worker finished. The outgoing landing goes in the same
    /// breath the incoming one takes its place: the card holds pointers into
    /// it, so the two must never overlap a frame.
    fn takeMixer(self: *Dock, now_ms: u64) bool {
        var d: ?*cc_live_mixer.Data = null;
        if (!cc_live_mixer.take(&d)) return false;
        const data = d.?;
        // A read that was already running when we wrote knows nothing about
        // what we wrote; adopting it would snap the row back under the
        // pointer. Dropping it also returns the worker to idle, which is what
        // lets the next read start.
        if (self.popup.kind == .volume_mixer and
            (self.popup.mx_ui.drag_active or now_ms < self.mx_hold_ms))
        {
            data.deinit();
            return false;
        }
        if (self.mx_data) |old| old.deinit();
        self.mx_data = data;
        self.pushMixerToCard();
        return true;
    }

    /// Keep the mixer reading — only while its card is up, since nothing else
    /// on screen shows a number this worker produces. Under a drag, or inside
    /// the window after a write, no read starts: the widget owns the figures
    /// on screen and a landing would fight it.
    fn pollMixer(self: *Dock, now_ms: u64) void {
        if (self.popup.kind != .volume_mixer) return;
        if (now_ms < self.mx_next_ms) return;
        if (self.popup.mx_ui.drag_active or now_ms < self.mx_hold_ms) return;
        if (!cc_live_mixer.request(self.app.gpa, self.app.io)) {
            if (!cc_live_mixer.idle()) return; // still in flight
            // The spawn never started: back off like a read that ran, or one
            // allocator problem would be retried every tick.
            self.mx_next_ms = now_ms + k_mx_poll_retry_ms;
            return;
        }
        self.mx_next_ms = now_ms + k_mx_poll_ms;
    }

    /// The mixer slot's card. Fixed 600×620 — the list inside it scrolls
    /// rather than growing it — so there is nothing to size from the data,
    /// but the data still has to be in front of the first frame: the last
    /// landing in `mx_data` does that, and the fresh read it asks for lands a
    /// tick later.
    fn showVolumeMixer(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        const cx = self.slotCentreX(idx) orelse return;
        self.popup.reset();
        self.popup.widget_cfg = &self.app.loaded.cfg;
        self.popup.mx_icons = .{ .ctx = self, .get = mxIconSurf };
        const ok = self.popup.openVolumeMixer(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            cx,
            self.fit,
        );
        if (!ok) {
            logz.log("volume_mixer card: present failed slot={d}", .{idx});
            self.popup.reset();
            return;
        }
        // The card is only a `kind` now, so this can reach it.
        self.pushMixerToCard();
        const streams: usize = if (self.mx_data) |d| d.snap.out_streams.len else 0;
        const sinks: usize = if (self.mx_data) |d| d.snap.sinks.len else 0;
        logz.log(
            "volume_mixer card: open slot={d} at x={d} streams={d} sinks={d}",
            .{ idx, self.popup.card_cx, streams, sinks },
        );
        if (!self.app.conn.flush()) logz.log("volume_mixer card: flush failed", .{});
        self.mx_next_ms = Dock.nowMs();
        self.pollMixer(Dock.nowMs());
    }

    /// Pointer position in card coordinates for the mixer's own input paths.
    /// `cardLocal` lives in the popup, but the drag paths need the floats the
    /// widget's `View` keeps rather than the rounded pair the hover cache does.
    fn mixerLocal(self: *Dock) struct { x: f64, y: f64 } {
        const pp = lastPointer(self);
        // Same transform as the popup's own `cardLocal`: the card draws inside
        // a `cairo_scale(fit)` frame centred on `card_cx`, so the wheel/drag
        // position has to be re-read in natural card coordinates too.
        const fit = self.popup.fit;
        const left = @as(f64, @floatFromInt(self.popup.card_cx)) - mixer_card.popup_w * fit * 0.5;
        return .{ .x = (pp[0] - left) / fit, .y = pp[1] / fit };
    }

    /// The mixer card's drag. Motion is the only path behind the 16 ms frame
    /// gate — the pear and the control centre ride it too — so state lands
    /// every event and pixels only when due. Answers whether the event was
    /// the card's, so the caller can leave the hover redraw alone.
    fn mixerDragMotion(self: *Dock) bool {
        const ui = &self.popup.mx_ui;
        if (!ui.drag_active) return false;
        const gpa = self.app.gpa;
        const loc = self.mixerLocal();
        const now = Dock.nowMs();
        var lay = mixer_card.computeLayout(
            gpa,
            self.popup.mx_snap,
            self.popup.mx_cards,
            ui.view_output,
            ui.router_stream,
            ui.master_picker,
            ui.scroll_px,
        ) catch return true;
        defer mixer_card.freeLayout(gpa, &lay);
        var hold: i64 = 0;
        if (mixer_card.motionAt(
            ui,
            self.popup.mx_snap,
            &lay,
            loc.x,
            loc.y,
            @intCast(now),
            &hold,
        )) |eff| {
            _ = self.runMixerEffect(eff);
            self.mx_hold_ms = now + k_mx_hold_ms;
        }
        // The engine hold the widget handed back keeps the footer's DSP
        // readout frozen while the pointer is in flight.
        if (hold > 0) self.mx_hold_ms = @max(self.mx_hold_ms, @as(u64, @intCast(hold)));
        if (self.dragFrameDue(now)) self.popupRefresh();
        return true;
    }

    /// The mixer card's release: the final volume the drag settled on, and
    /// the end of both holds — the widget clears its own drag here, the host
    /// its refusal window. Returns whether the card was up at all.
    fn mixerRelease(self: *Dock) bool {
        if (self.popup.kind != .volume_mixer) return false;
        if (!self.popup.mx_ui.drag_active) return false;
        const loc = self.mixerLocal();
        if (mixer_card.releaseAt(&self.popup.mx_ui, loc.x)) |eff| {
            _ = self.runMixerEffect(eff);
            self.mx_hold_ms = Dock.nowMs() + k_mx_hold_ms;
        }
        // Fresh numbers for the value we just wrote, after the window that
        // protects it: the read cannot start until then, so ask now that the
        // deadline is what it will be.
        self.mx_next_ms = self.mx_hold_ms;
        self.popupRefresh();
        return true;
    }

    /// The card's wheel: a slider bump writes, the viewport scrolls, and the
    /// rest is the widget's own state. `delta` is the scroll direction
    /// (positive away from the pointer), which is what `axisAt` expects.
    fn mixerAxis(self: *Dock, delta: f64) bool {
        if (self.popup.kind != .volume_mixer) return false;
        const gpa = self.app.gpa;
        const ui = &self.popup.mx_ui;
        const loc = self.mixerLocal();
        var lay = mixer_card.computeLayout(
            gpa,
            self.popup.mx_snap,
            self.popup.mx_cards,
            ui.view_output,
            ui.router_stream,
            ui.master_picker,
            ui.scroll_px,
        ) catch return false;
        defer mixer_card.freeLayout(gpa, &lay);
        const h = mixer_card.hitTest(&lay, self.popup.mx_snap, loc.x, loc.y);
        const out = mixer_card.axisAt(ui, self.popup.mx_snap, &lay, h, loc.x, loc.y, delta);
        if (out.effect.verb != .none) {
            _ = self.runMixerEffect(out.effect);
            self.mx_hold_ms = Dock.nowMs() + k_mx_hold_ms;
        }
        if (out.consumed) self.popupRefresh();
        return out.consumed;
    }

    /// Which row a node id came from. The same id is a device or a stream
    /// depending on which list drew it, and only that decides which call
    /// speaks for it — the widget's `Effect` carries nothing else about it.
    const MixerNode = struct {
        is_stream: bool = false,
        is_input: bool = false,
        raw: []const u8 = "",
        id: u32 = 0,
    };

    fn mixerNode(d: *cc_live_mixer.Data, node_id: u32) MixerNode {
        if (node_id == 0) return .{};
        const snap = &d.snap;
        for (snap.sinks) |dev| {
            if (dev.node_id == node_id) return .{ .raw = dev.raw_name, .id = dev.node_id };
        }
        for (snap.sources) |dev| {
            if (dev.node_id == node_id) return .{ .raw = dev.raw_name, .id = dev.node_id, .is_input = true };
        }
        for (snap.out_streams) |s| {
            if (s.node_id == node_id) return .{ .id = s.node_id, .is_stream = true };
        }
        for (snap.in_streams) |s| {
            if (s.node_id == node_id) return .{ .id = s.node_id, .is_stream = true, .is_input = true };
        }
        return .{};
    }

    /// One write the widget formulated. The verb names the operation, the
    /// landing's tables give it a node, and `live_audio` speaks it — pactl
    /// where a path needs it, `wpctl` everywhere it does. Answers whether
    /// anything was actually asked, which is what the log line reports.
    fn runMixerEffect(self: *Dock, e: mixer_card.Effect) bool {
        const io = self.app.io;
        const d = self.mx_data orelse return false;
        switch (e.verb) {
            .none => return false,
            .launch_settings => {
                // The card's footer button, which opens the same settings app
                // the shell's own components launch — a desktop entry here
                // would resolve to whichever build sits first on PATH.
                const ok = self.launchSibling("horizon-settings");
                logz.log("volume_mixer: verb=launch_settings ok={}", .{ok});
                return ok;
            },
            .apply_card_profile => {
                if (e.card_index >= d.cards.len) return false;
                const card = d.cards[e.card_index];
                const force_off = cc_live_audio.isBluetoothCard(card.card_key) and
                    cc_live_audio.isVendorCodecProfile(e.profile_key);
                const ok = cc_live_audio.setCardProfile(io, e.card_index, e.profile_key, force_off);
                logz.log(
                    "volume_mixer: verb=apply_card_profile card={d} profile={s} ok={}",
                    .{ e.card_index, e.profile_key, ok },
                );
                if (ok) self.mx_hold_ms = Dock.nowMs() + k_mx_hold_ms;
                return ok;
            },
            else => {},
        }
        const n = mixerNode(d, e.node_id);
        if (n.id == 0) return false;
        const sid: i32 = @intCast(n.id);
        const ok = switch (e.verb) {
            .set_volume => blk: {
                // `volume_t` is a 0..1.5 track fraction: 1.0 is full
                // scale, so a percent is the fraction times a hundred.
                const pct: i32 = @intFromFloat(@round(std.math.clamp(e.volume_t, 0.0, 1.5) * 100.0));
                break :blk if (n.is_stream)
                    cc_live_audio.setStreamVolume(io, sid, n.is_input, pct)
                else
                    cc_live_audio.setDeviceVolume(io, n.raw, n.id, n.is_input, pct);
            },
            .set_mute => if (n.is_stream)
                cc_live_audio.setStreamMute(io, sid, n.is_input, e.muted)
            else
                cc_live_audio.setDeviceMute(io, n.raw, n.id, n.is_input, e.muted),
            .set_default_sink => cc_live_audio.setDefaultSink(io, n.raw),
            .set_default_source => cc_live_audio.setDefaultSource(io, n.raw),
            .route_playback, .route_capture => blk: {
                const target = mixerNode(d, e.target_id);
                if (target.id == 0) break :blk false;
                break :blk if (e.verb == .route_capture)
                    cc_live_audio.moveSourceOutput(io, n.id, target.raw)
                else
                    cc_live_audio.moveSinkInput(io, n.id, target.raw);
            },
            else => false,
        };
        if (e.verb != .none) {
            logz.log("volume_mixer: verb={s} node={d} target={d} ok={}", .{
                @tagName(e.verb),
                e.node_id,
                e.target_id,
                ok,
            });
        }
        if (ok and e.verb != .none) self.mx_hold_ms = Dock.nowMs() + k_mx_hold_ms;
        return ok;
    }

    /// The card's click: its own hit test, then the write it asked for. The
    /// widget never touches the bus — it hands back an `Effect` and this runs
    /// it — and a card that asked for nothing simply stays up.
    fn runVolumeMixerPopupClick(self: *Dock) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const x: i32 = @intFromFloat(@round(seat.pointer_x));
        const y: i32 = @intFromFloat(@round(seat.pointer_y));
        switch (self.popup.cardClick(x, y)) {
            .dismiss => return false,
            .volume_mixer => {},
            // A press that hit the card but no control: nothing to do, and
            // nothing that should take the card away.
            else => return true,
        }
        const out = self.popup.mx_click;
        _ = self.runMixerEffect(out.effect);
        if (out.resized) {
            // The height never moves today — the card's viewport scrolls
            // inside a fixed 620 — but the widget answers for a growing card,
            // so one that ever grows finds its surface grown.
            _ = self.settleWidgetCard();
        }
        self.popupRefresh();
        return true;
    }

    fn freeCcMixerArt(self: *Dock) void {
        const gpa = self.app.gpa;
        for (self.cc_mixer_art.items) |a| {
            if (a.pixels.len > 0) gpa.free(a.pixels);
        }
        self.cc_mixer_art.deinit(gpa);
        self.cc_mixer_art = .empty;
        for (self.cc_stream_names.items) |n| gpa.free(n.name);
        self.cc_stream_names.deinit(gpa);
        self.cc_stream_names = .empty;
        self.cc_mixer_sig = 0;
    }

    /// Resolve one mixer stream to theme raster, trying in order: `application.icon_name`, the
    /// app id and its variants, the process binary, the theme hints for known
    /// apps, the app name's slug — then, only if none of those named an icon,
    /// the desktop-entry cross-reference. The candidate list is the widget's
    /// own `streamIconNames`, so a row here and a row in the volume-mixer card
    /// can never disagree about what an app is called.
    ///
    /// Empty pixels when nothing matched — paint draws the gray dot.
    fn resolveStreamArt(
        self: *Dock,
        dirs: []const []const u8,
        app_dirs: []const []const u8,
        theme: []const u8,
        s: *const cc_live_audio.Stream,
    ) dock_paint.IconPx {
        const gpa = self.app.gpa;
        const io = self.app.io;

        var names: [24][2][]const u8 = undefined;
        for (mixer_card.streamIconNames(&names, s.icon_name, s.app_id, s.process_binary, s.app_name)) |cand| {
            if (loadIconFrom(gpa, io, dirs, theme, cand[0], k_mx_icon_px)) |px| return px;
        }

        // The ids this stream could have been exported under, then that
        // entry's `Icon=` — how `fluxer-canary` (no theme name of its own in
        // the pack, only `Icon=` in its desktop file) and Edge (whose desktop
        // file is `com.microsoft.Edge.dev.desktop`) get their picture.
        var cands: [16][2][]const u8 = undefined;
        for (mixer_card.streamDesktopCandidates(&cands, s.app_id, s.process_binary, s.app_name, "", s.description)) |id| {
            const icon_name = app_launch.desktopIcon(gpa, io, app_dirs, id[0]) orelse continue;
            defer gpa.free(icon_name);
            if (loadIconFrom(gpa, io, dirs, theme, icon_name, k_mx_icon_px)) |px| return px;
        }
        return .{};
    }

    /// Re-resolve mixer art only when the stream set changed (id + name
    /// hash), so the 1 s live tick does no file IO in the common case.
    fn resolveCcMixerArt(self: *Dock) void {
        const gpa = self.app.gpa;
        var h = std.hash.Wyhash.init(0x51ab);
        var n: usize = 0;
        if (self.cc_audio) |*q| {
            for (q.snap.out_streams) |s| {
                h.update(std.mem.asBytes(&s.id));
                h.update(s.app_name);
                n += 1;
            }
            for (q.snap.in_streams) |s| {
                h.update(std.mem.asBytes(&s.id));
                h.update(s.app_name);
                n += 1;
            }
        }
        if (n == 0) {
            if (self.cc_mixer_art.items.len > 0) self.freeCcMixerArt();
            return;
        }
        if (h.final() == self.cc_mixer_sig and self.cc_mixer_art.items.len > 0) return;
        self.freeCcMixerArt();
        self.cc_mixer_sig = h.final();
        const cfg = &self.app.loaded.cfg;
        const theme: []const u8 = if (cfg.dock.icon_theme.len > 0) cfg.dock.icon_theme else "hicolor";
        const dirs = icon_lookup.dataDirs(gpa, getenvStr("XDG_DATA_HOME"), getenvStr("HOME"), getenvStr("XDG_DATA_DIRS")) catch return;
        defer icon_lookup.freeDirs(gpa, dirs);
        const app_dirs = app_launch.applicationsDirs(gpa, getenvStr("XDG_DATA_HOME"), getenvStr("HOME"), getenvStr("XDG_DATA_DIRS")) catch return;
        defer app_launch.freeDirs(gpa, app_dirs);
        if (self.cc_audio) |*q| {
            for (q.snap.out_streams) |*s| {
                const px = self.resolveStreamArt(dirs, app_dirs, theme, s);
                self.cc_mixer_art.append(gpa, .{
                    .id = s.id,
                    .is_input = false,
                    .pixels = if (px.pixels.len > 0) @constCast(px.pixels) else &.{},
                    .w = px.w,
                    .h = px.h,
                }) catch {
                    if (px.pixels.len > 0) gpa.free(px.pixels);
                };
            }
            for (q.snap.in_streams) |*s| {
                const px = self.resolveStreamArt(dirs, app_dirs, theme, s);
                self.cc_mixer_art.append(gpa, .{
                    .id = s.id,
                    .is_input = true,
                    .pixels = if (px.pixels.len > 0) @constCast(px.pixels) else &.{},
                    .w = px.w,
                    .h = px.h,
                }) catch {
                    if (px.pixels.len > 0) gpa.free(px.pixels);
                };
            }
            // Display names ride the same signature gate as the art above —
            // no desktop-file IO while the stream set stands.
            for (q.snap.out_streams) |s| self.resolveCcStreamName(gpa, app_dirs, s);
            for (q.snap.in_streams) |s| self.resolveCcStreamName(gpa, app_dirs, s);
        }
    }

    /// One stream's desktop-entry display name, trying: process binary (stem) →
    /// app id → application name → `node.description`, first entry hit
    /// wins, and generic runtime binaries never identify anything. Null
    /// keeps the raw application name standing.
    fn streamDisplayName(
        self: *const Dock,
        alloc: std.mem.Allocator,
        app_dirs: []const []const u8,
        s: cc_live_audio.Stream,
    ) ?[]u8 {
        const io = self.app.io;
        const raw = [_][]const u8{ s.process_binary, s.app_id, s.app_name, s.description };
        var seen: [4][]const u8 = undefined;
        var nseen: usize = 0;
        for (raw) |r| {
            if (r.len == 0) continue;
            var v = r;
            if (std.mem.lastIndexOfAny(u8, v, "/\\")) |sl| {
                if (sl + 1 < v.len) v = v[sl + 1 ..];
            }
            if (v.len == 0 or isGenericRuntimeBinary(v)) continue;
            var dup = false;
            for (seen[0..nseen]) |x| {
                if (std.ascii.eqlIgnoreCase(x, v)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (nseen >= seen.len) break;
            seen[nseen] = v;
            nseen += 1;
            if (app_launch.desktopName(alloc, io, app_dirs, v)) |name| return name;
        }
        return null;
    }

    fn resolveCcStreamName(self: *Dock, alloc: std.mem.Allocator, app_dirs: []const []const u8, s: cc_live_audio.Stream) void {
        const name = self.streamDisplayName(alloc, app_dirs, s) orelse return;
        self.cc_stream_names.append(alloc, .{ .id = s.id, .name = name }) catch alloc.free(name);
    }

    fn ccStreamName(self: *const Dock, id: i32) ?[]const u8 {
        for (self.cc_stream_names.items) |n| {
            if (n.id == id) return n.name;
        }
        return null;
    }

    /// Binaries that name a runtime, not an app — `electron`, `python`, …
    /// would otherwise identify every app hosting on them.
    fn isGenericRuntimeBinary(name: []const u8) bool {
        const k_generic = [_][]const u8{
            "chromium",      "chromium-browser", "chrome",
            "google-chrome", "chromium input",   "chromium output",
            "electron",      "electron32",       "electron31",
            "electron30",    "node",             "python",
            "python3",       "java",             "wine",
            "wineserver",
        };
        for (k_generic) |g| if (std.ascii.eqlIgnoreCase(name, g)) return true;
        return false;
    }

    fn mixerArtFor(self: *const Dock, id: i32, is_input: bool) ?MixerArt {
        for (self.cc_mixer_art.items) |a| {
            if (a.id == id and a.is_input == is_input) return a;
        }
        return null;
    }

    /// Cover pixels behind the control-center + pear media card.
    ///
    /// The media widget is the dock's one art loader, so its pixels for the
    /// *same* address are borrowed first. When it has none yet, the shared
    /// cover cache is asked — every cover decoded once is on disk as raw
    /// pixels, and a find there is a read, not a decode on the shell's
    /// thread. Nothing is decoded here any more; the card fills in on the
    /// next poll once the widget's worker lands.
    fn resolveCcMediaArt(self: *Dock) void {
        const gpa = self.app.gpa;
        const q = if (self.cc_media) |*m| m.snap else cc_live_media.Snapshot{};
        // The address the widget derives for this track: the private-cache
        // marker and the video still are only reachable through the same
        // fallbacks, and the borrow below compares against that spelling.
        const src = mpris_art.sourceFor(gpa, .{
            .bus_name = q.bus_name,
            .art_url = q.art_url,
            .track_url = q.track_url,
            .title = q.title,
            .artist = q.artist,
            .album = q.album,
        });
        defer if (src) |s| gpa.free(s);
        const url: []const u8 = src orelse "";
        // The media widget's decoded cover, but only for this exact address —
        // a cover left over from a previous track must not bleed in.
        const borrowed: ?media_paint.Art = blk: {
            const key = self.media_art_key orelse break :blk null;
            if (url.len == 0 or !std.mem.eql(u8, key, url)) break :blk null;
            if (!self.media_art.present()) break :blk null;
            break :blk self.media_art;
        };
        const same_url = std.mem.eql(u8, url, self.cc_art_url);
        // Pixels for this address already decoded: nothing left to do.
        if (same_url and self.cc_art.pixels.len > 0) return;
        if (!same_url) {
            if (self.cc_art.pixels.len > 0) gpa.free(self.cc_art.pixels);
            if (self.cc_art_url.len > 0) gpa.free(self.cc_art_url);
            self.cc_art = .{};
            self.cc_art_url = gpa.dupe(u8, url) catch "";
        }
        if (url.len == 0) return;
        if (borrowed) |art| {
            // Owned copy: the widget retires its pixels when the track
            // moves on, and this card may still be painting from them.
            const px = gpa.dupe(u8, art.pixels) catch return;
            self.cc_art = .{ .pixels = px, .w = art.w, .h = art.h };
            return;
        }
        // Not decoded yet: it is still on the widget's worker. Ask the disk
        // cache instead and leave the card to the next poll.
        if (cover_cache.find(gpa, self.app.io, url)) |cv| {
            self.cc_art = .{ .pixels = cv.pixels, .w = cv.w, .h = cv.h };
        }
    }

    /// Snapshot behind one control-center popup frame. Converted rows live
    /// in the `cc_snap_*` scratch arrays (strings borrow the live caches);
    /// the host deep-copies everything into its arena on open/refresh.
    fn buildCcSnapshot(self: *Dock) cc_data.Snapshot {
        // Cheap when the stream set stands (a hash over the rows); file IO
        // only when it moved — guarantees art + display names are fresh for
        // every caller, not just the poll path.
        self.resolveCcMixerArt();
        var snap = cc_data.Snapshot{};
        // Network.
        if (self.cc_net) |*q| {
            snap.net = .{
                .connected = q.snap.connected,
                .ethernet = q.snap.ethernet,
                .wifi = q.snap.wifi,
                .iface = q.snap.iface,
                .ssid = q.snap.ssid,
                .wifi_signal_pct = q.snap.signal_pct,
            };
            var n: usize = 0;
            for (q.ap_list.items) |ap| {
                if (n >= self.cc_snap_aps.len) break;
                self.cc_snap_aps[n] = .{
                    .active = ap.active,
                    .ssid = ap.ssid,
                    .signal_pct = ap.strength,
                    .needs_password = ap.secured and !ap.active,
                };
                n += 1;
            }
            snap.aps = self.cc_snap_aps[0..n];
        }
        // Bluetooth.
        var paired_count: i32 = 0;
        var lowest_bat: i32 = -1;
        if (self.cc_bt) |*q| {
            snap.bt = .{ .powered = q.snap.powered, .connected = false, .discovering = q.snap.discovering };
            var n: usize = 0;
            for (q.device_list.items) |d| {
                if (d.paired) paired_count += 1;
                if (d.connected) {
                    snap.bt.connected = true;
                    if (d.battery_pct >= 0 and (lowest_bat < 0 or d.battery_pct < lowest_bat)) lowest_bat = d.battery_pct;
                }
                if (n >= self.cc_snap_bt.len) continue;
                self.cc_snap_bt[n] = .{
                    .address = d.address,
                    .alias = d.name,
                    .paired = d.paired,
                    .connected = d.connected,
                    .battery_pct = d.battery_pct,
                };
                n += 1;
            }
            snap.bt_devs = self.cc_snap_bt[0..@min(n, self.cc_snap_bt.len)];
            snap.bt.paired_count = paired_count;
            snap.bt.battery_pct = lowest_bat;
        }
        // Audio devices.
        if (self.cc_audio) |*q| {
            snap.out = .{
                .muted = q.snap.out.muted,
                .volume_pct = q.snap.out.volume_pct,
                .device_name = if (q.snap.out.description.len > 0) q.snap.out.description else if (q.snap.out.name.len > 0) q.snap.out.name else "Default Sink",
            };
            snap.in = .{
                .muted = q.snap.in.muted,
                .volume_pct = q.snap.in.volume_pct,
                .device_name = if (q.snap.in.description.len > 0) q.snap.in.description else if (q.snap.in.name.len > 0) q.snap.in.name else "Default Source",
            };
            var no: usize = 0;
            for (q.snap.sinks) |d| {
                if (no >= self.cc_snap_outdev.len) break;
                self.cc_snap_outdev[no] = .{
                    .sink_name = d.name,
                    .display_name = if (d.description.len > 0) d.description else d.name,
                    .is_default = d.is_default,
                };
                no += 1;
            }
            snap.out_devs = self.cc_snap_outdev[0..no];
            var ni: usize = 0;
            for (q.snap.sources) |d| {
                if (ni >= self.cc_snap_indev.len) break;
                self.cc_snap_indev[ni] = .{
                    .source_name = d.name,
                    .display_name = if (d.description.len > 0) d.description else d.name,
                    .is_default = d.is_default,
                };
                ni += 1;
            }
            snap.in_devs = self.cc_snap_indev[0..ni];
            var so: usize = 0;
            for (q.snap.out_streams) |s| {
                if (so >= self.cc_snap_outs.len) break;
                const art = self.mixerArtFor(s.id, false);
                self.cc_snap_outs[so] = .{
                    .sink_input_id = s.id,
                    .volume_pct = s.volume_pct,
                    .muted = s.muted,
                    .app_name = self.ccStreamName(s.id) orelse (if (s.app_name.len > 0) s.app_name else "Unknown App"),
                    .icon_argb = if (art) |a| a.pixels else &.{},
                    .icon_w = if (art) |a| a.w else 0,
                    .icon_h = if (art) |a| a.h else 0,
                };
                so += 1;
            }
            snap.out_streams = self.cc_snap_outs[0..so];
            var si: usize = 0;
            for (q.snap.in_streams) |s| {
                if (si >= self.cc_snap_ins.len) break;
                const art = self.mixerArtFor(s.id, true);
                self.cc_snap_ins[si] = .{
                    .sink_input_id = s.id,
                    .volume_pct = s.volume_pct,
                    .muted = s.muted,
                    .app_name = self.ccStreamName(s.id) orelse (if (s.app_name.len > 0) s.app_name else "Unknown App"),
                    .icon_argb = if (art) |a| a.pixels else &.{},
                    .icon_w = if (art) |a| a.w else 0,
                    .icon_h = if (art) |a| a.h else 0,
                };
                si += 1;
            }
            snap.in_streams = self.cc_snap_ins[0..si];
        } else {
            snap.out = .{ .volume_pct = 100, .device_name = "Default Sink" };
            snap.in = .{ .volume_pct = 100, .muted = true, .device_name = "Default Source" };
        }
        // Media.
        if (self.cc_media) |*q| {
            snap.media = .{
                // A player with neither name is not a card yet —
                // gate on active with a non-empty title or artist
                // and reads "No Media" otherwise.
                .active = q.snap.have_player and (q.snap.title.len > 0 or q.snap.artist.len > 0),
                .title = q.snap.title,
                .artist = q.snap.artist,
                .playing = q.snap.playing,
                .can_go_previous = q.snap.can_go_previous,
                .can_go_next = q.snap.can_go_next,
                .can_play_pause = q.snap.can_play_pause,
                .has_art = self.cc_art.pixels.len > 0,
                .art_argb = self.cc_art.pixels,
                .art_w = self.cc_art.w,
                .art_h = self.cc_art.h,
            };
        }
        // Errors.
        if (self.cc_wifi_err_len > 0) snap.wifi_error = self.cc_wifi_err[0..self.cc_wifi_err_len];
        // Weather.
        var wx_icon: []const u8 = "cloud";
        var wx_loc: []const u8 = "";
        var wx_avail = false;
        var wx_temp: i32 = 0;
        var wx_feels: i32 = 0;
        var wx_hum: i32 = 0;
        var wx_wind: i32 = 0;
        var wx_vis: i32 = 0;
        if (self.wx_reading.available) {
            wx_avail = true;
            wx_icon = self.wx_reading.glyph;
            wx_loc = self.wx_reading.placeName();
            wx_temp = self.wx_reading.temp;
            wx_feels = self.wx_reading.feels_like;
            wx_hum = self.wx_reading.humidity_pct;
            wx_wind = self.wx_reading.wind_kmh;
            wx_vis = self.wx_reading.visibility_m;
        }
        // Forecast columns borrow the reading's day glyphs directly.
        const wdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        var n_days: usize = 0;
        if (wx_avail) {
            for (self.wx_reading.days[0..self.wx_reading.n_days], 0..) |d, i| {
                if (i >= self.cc_days.len) break;
                self.cc_days[i] = .{
                    .day = wdays[d.wday % 7],
                    .hi = d.hi,
                    .lo = d.lo,
                    .icon = d.glyph,
                };
                n_days += 1;
            }
        }
        snap.weather = .{
            .available = wx_avail,
            .location = wx_loc,
            .temp = wx_temp,
            .feels_like = wx_feels,
            .humidity_pct = wx_hum,
            .wind_kmh = wx_wind,
            .visibility_m = wx_vis,
            .icon = wx_icon,
            .fahrenheit = self.wx_reading.fahrenheit,
            .forecast = self.cc_days[0..n_days],
        };
        return snap;
    }

    fn deinit(self: *Dock) void {
        self.pin_drag.deinit(self.app.gpa);
        self.freeModel();
        self.dropCarried();
        if (self.measure) |cr| {
            cairo.cairo_destroy(cr);
            self.measure = null;
        }
        if (self.measure_surf) |s| {
            cairo.cairo_surface_destroy(s);
            self.measure_surf = null;
        }
        if (self.timer_fd >= 0) {
            _ = linux.close(self.timer_fd);
            self.timer_fd = -1;
        }
        if (self.anim_fd >= 0) {
            _ = linux.close(self.anim_fd);
            self.anim_fd = -1;
        }
        self.toplevels.deinit();
        self.ft.deinit();
        self.popup.deinit();
        self.launcher.deinit();
        if (self.launcher_theme) |t| self.app.gpa.free(t);
        if (self.wc_init) self.wc.deinit();
        self.cc.deinit();
        self.pear.deinit();
        self.freeWsEntries();
        if (self.ws_snap) |*snap| snap.deinit();
        self.ws_snap = null;
        self.ws_anim.deinit();
        self.clearWsSurfs();
        if (self.ws_surfs_init) self.ws_surfs.deinit();
        self.pear_backlight.deinit(self.app.gpa);
        self.redeye_inhibit.deinit();
        self.freeCcLive();
        // Join before the allocator goes: the VPN worker borrows it. The
        // widget rows it feeds went with `freeCcBt` a line above.
        cc_live_vpn.shutdown();
        self.freeVpnConns();
        self.vpn_store.deinit();
        // The mixer worker is joined for the same reason, and its landing is
        // dropped with it: every string and row the card was drawing came out
        // of that one arena.
        cc_live_mixer.shutdown();
        if (self.mx_data) |d| d.deinit();
        self.mx_data = null;
        self.freeMxIcons();
        self.freeCcMixerArt();
        if (self.cc_art.pixels.len > 0) self.app.gpa.free(self.cc_art.pixels);
        if (self.cc_art_url.len > 0) self.app.gpa.free(self.cc_art_url);
        self.cc_art = .{};
        self.cc_art_url = "";
        // The cover worker allocates from this same allocator and may still
        // be running; its answer is dropped here. The bounded drain keeps a
        // pick stuck on a dead network read from freezing this restart.
        cover_worker.resetWithin(self.app.gpa, 1500);
        self.freeMediaArt();
        self.media.deinit();
        self.notif_push.deinit();
        self.notif_stats.deinit(self.app.gpa);
        if (self.notif_last_key) |k| self.app.gpa.free(k);
        self.notif_last_key = null;
        // The bus fd is still in the loop's poll set at this point; the loop
        // itself is torn down by `App.deinit` right after, so closing the
        // connection here is enough.
        self.tray.deinit();
        self.surface.destroy();
        if (self.output_want.len > 0) {
            self.app.gpa.free(self.output_want);
            self.output_want = "";
        }
        self.shm.deinit();
    }

    fn freeModel(self: *Dock) void {
        const gpa = self.app.gpa;
        if (self.widths.len > 0) gpa.free(self.widths);
        self.widths = &.{};
        for (self.icons) |ic| {
            if (ic.pixels.len > 0) gpa.free(ic.pixels);
        }
        if (self.icons.len > 0) gpa.free(self.icons);
        self.icons = &.{};
        if (self.icon_keys.len > 0) gpa.free(self.icon_keys);
        self.icon_keys = &.{};
        if (self.label.len > 0) gpa.free(self.label);
        self.label = &.{};
        // `Slot.key` for a running-app slot points into `self.running`, and a
        // tray slot into `self.tray_keys`, so the strip has to go first.
        self.strip.deinit(gpa);
        if (self.running.len > 0) {
            for (self.running) |r| gpa.free(r);
            gpa.free(self.running);
        }
        self.running = &.{};
        if (self.tray_keys.len > 0) {
            for (self.tray_keys) |k| gpa.free(k);
            gpa.free(self.tray_keys);
        }
        self.tray_keys = &.{};
        self.dirty = false;
        self.geom = null;
        self.clock_slot = no_slot;
        self.clock_max_w = 0;
        self.hover = no_slot;
        self.pressed = no_slot;
        // A reload can renumber the slots, so any in-flight lift belongs to a
        // hover that no longer means anything.
        self.lift.jump(0.0);
    }

    // -----------------------------------------------------------------
    // Model
    // -----------------------------------------------------------------

    /// Fingerprint of the resolution the slot icons were decoded under. A
    /// rebuild that changes the pixel size or the theme starts from nothing
    /// rather than adopting art from the old one.
    fn iconSig(cfg: *const config.ShellConfig) u64 {
        var h = std.hash.Wyhash.init(0x1c0ffee);
        const px: i32 = dw.effectiveIcon(cfg);
        h.update(std.mem.asBytes(&px));
        const theme: []const u8 = if (cfg.dock.icon_theme.len > 0) cfg.dock.icon_theme else "hicolor";
        h.update(theme);
        return h.final();
    }

    /// What a slot's icon is *for*: the whole of the identity carry matching
    /// needs. The pixels' source path is deliberately not part of it — a theme
    /// file replaced on disk is not something the dock re-reads either.
    fn slotIconSignature(s: dw.Slot) u64 {
        var h = std.hash.Wyhash.init(0x1c0ffee5eed);
        const k: u32 = @intFromEnum(s.kind);
        h.update(std.mem.asBytes(&k));
        h.update(s.key);
        return h.final();
    }

    /// Lifts the icon buffers the strip that is coming will still want out of
    /// the model `freeModel` is about to tear down. Each buffer is matched by
    /// the fingerprint recorded when it was resolved, never by re-reading the
    /// slot: at this point the strip's keys may already point into a drag
    /// preview or a config arena that has been released.
    fn beginCarry(self: *Dock) void {
        self.dropCarried();
        self.carry_n = 0;
        self.carry_taken = @splat(false);
        for (self.strip.slots, 0..) |s, i| {
            if (self.carry_n >= self.carry_px.len) break;
            if (i >= self.icons.len or i >= self.icon_keys.len) break;
            // A tray item's art is whatever the client last shipped, so it is
            // the one slot a rebuild has to re-read rather than adopt.
            if (s.kind == .tray) continue;
            if (self.icons[i].pixels.len == 0) continue;
            self.carry_px[self.carry_n] = self.icons[i];
            self.carry_sig[self.carry_n] = self.icon_keys[i];
            self.carry_n += 1;
        }
        // The buffers are the carry's now, not the model's.
        for (self.icons) |*ic| ic.* = .{};
    }

    /// The buffer carried for this slot, if any. Each is handed out once, so
    /// two slots that happen to share a key cannot both own the same pixels.
    fn takeCarried(self: *Dock, s: dw.Slot, sig: u64) ?dock_paint.IconPx {
        if (self.carry_n == 0) return null;
        const want = slotIconSignature(s) ^ sig;
        for (0..self.carry_n) |i| {
            if (self.carry_taken[i]) continue;
            if (self.carry_sig[i] != want) continue;
            self.carry_taken[i] = true;
            return self.carry_px[i];
        }
        return null;
    }

    /// Frees whatever the rebuild did not take. A buffer that was handed out
    /// belongs to `self.icons` now, so only the untaken ones are released.
    fn dropCarried(self: *Dock) void {
        const gpa = self.app.gpa;
        for (0..self.carry_n) |i| {
            if (self.carry_taken[i]) continue;
            if (self.carry_px[i].pixels.len > 0) gpa.free(self.carry_px[i].pixels);
            self.carry_px[i] = .{};
        }
        self.carry_n = 0;
        self.carry_taken = @splat(false);
    }

    /// Rebuilds everything derived from the config. Called at startup and
    /// Recompute the output fit factor from the pinned output's logical
    /// height. Base dock metrics are authored for 1440; scaling them by
    /// `logical_h / 1440` keeps the dock the same fraction of the screen at
    /// any resolution. Logs only when the factor moves.
    fn syncFit(self: *Dock) void {
        var h: i32 = 0;
        if (self.output_entry) |o| {
            h = if (o.have_logical and o.logical_h > 0) o.logical_h else @divTrunc(o.height, @max(1, o.scale));
        }
        const f: f64 = if (h > 0) std.math.clamp(@as(f64, @floatFromInt(h)) / 1440.0, 0.5, 2.0) else 1.0;
        if (f != self.fit) {
            logz.log("dock: fit {:.2} -> {:.2} (output {}px / ref 1440px)", .{ self.fit, f, h });
            self.fit = f;
        }
    }

    /// after every reload — the old slices dangle once `App.reload` swaps
    /// `loaded` in, so nothing cached may survive across a reload.
    fn buildModel(self: *Dock) void {
        // Before the teardown, not after: the pixels worth keeping are in the
        // model that is going away, and `freeModel` frees them with the rest.
        const t0 = Dock.nowMs();
        self.beginCarry();
        self.freeModel();
        const gpa = self.app.gpa;
        const cfg = &self.app.loaded.cfg;

        self.icon_px = dw.effectiveIcon(cfg);
        self.dock_h = dw.effectiveBarHeight(cfg);
        self.radius = dw.effectiveRadius(cfg);
        self.gap = dw.effectiveGap(cfg);
        // Scale the base metrics to the output so the dock keeps the same
        // fraction of the screen at any resolution (authored for 1440).
        self.syncFit();
        if (self.fit != 1.0) {
            self.icon_px = @intFromFloat(@round(@as(f64, @floatFromInt(self.icon_px)) * self.fit));
            self.dock_h = @intFromFloat(@round(@as(f64, @floatFromInt(self.dock_h)) * self.fit));
            self.radius = @intFromFloat(@round(@as(f64, @floatFromInt(self.radius)) * self.fit));
            self.gap = @intFromFloat(@round(@as(f64, @floatFromInt(self.gap)) * self.fit));
        }
        // Control-center pill state first: widths depend on its glyph count.
        self.cc_rt = self.pollCcRuntime();
        self.cc_sig = 0;
        // Pear pill state: same live sources, own runtime struct.
        self.pear_rt = pearRuntime(self.cc_rt);
        self.pear_sig = 0;

        // `running_apps` was hard-wired empty until now, so the centre
        // section only ever showed pinned icons. Derive it from the
        // `ext_foreign_toplevel_list_v1` snapshot the tracker already keeps.
        self.running = collectRunning(gpa, &self.toplevels, cfg.dock.pinned_apps, cfg.dock.dock_group_apps) catch &.{};
        self.dirty = false;
        self.running_sig = runningSignature(&self.toplevels);
        // The tray source owns the item list; the strip only borrows the key
        // strings, so they are re-cut on every rebuild and released with it.
        self.tray_keys = self.tray.keys(gpa) catch &.{};

        // A drag in flight shows its own order; the config's is what everything
        // else reads until the drop writes one of them back.
        const pinned_src: []const []const u8 = if (self.pin_drag.order) |o| o else cfg.dock.pinned_apps;
        self.strip = dw.buildStrip(gpa, cfg, .{
            .pinned = pinned_src,
            .running = self.running,
            .tray = self.tray_keys,
        }) catch .{};
        const t_strip = Dock.nowMs();

        const n = self.strip.slots.len;
        self.icons = gpa.alloc(dock_paint.IconPx, n) catch &.{};
        self.icon_keys = gpa.alloc(u64, n) catch &.{};
        if (self.icon_keys.len == n) @memset(self.icon_keys, 0);
        self.widths = gpa.alloc(f64, n) catch &.{};

        self.clock_slot = no_slot;
        for (self.strip.slots, 0..) |s, i| {
            if (s.kind == .clock) {
                self.clock_slot = i;
                break;
            }
        }
        if (self.clock_slot != no_slot) {
            self.label = self.makeClockLabel();
            self.clock_max_w = self.measureText(self.label, dwp.clockFontPx(@floatFromInt(self.icon_px)));
        }

        self.computeWidths();
        const t_widths = Dock.nowMs();
        self.resolveIcons();
        const t_icons = Dock.nowMs();
        var resolved: usize = 0;
        for (self.icons) |ic| {
            if (ic.pixels.len > 0) resolved += 1;
        }
        // The indicator gate is `isRunning(key)`, so the keys have to be next
        // to the compositor's app_ids in the same log or a dot that stays dark
        // is undiagnosable.
        var keys: [24][]const u8 = undefined;
        var nkeys: usize = 0;
        for (self.strip.slots) |sl| {
            if (nkeys >= keys.len) break;
            if (sl.kind != .app or sl.key.len == 0) continue;
            keys[nkeys] = sl.key;
            nkeys += 1;
        }
        var keybuf: [700]u8 = undefined;
        var runbuf: [400]u8 = undefined;
        var traybuf: [400]u8 = undefined;
        logz.log(
            "model: {d} slots ({d} with art), clock={s}, icon_px={d}, theme={s}, cause={s}\n" ++
                "  app slots: {s}\n" ++
                "  running: {d} ({s})\n" ++
                "  tray: {d} {s}({s})\n" ++
                "  phases: strip={d}ms widths={d}ms icons={d}ms\n" ++
                "  flags: show={s} group={s} renderer={s}",
            .{
                self.strip.slots.len,
                resolved,
                if (self.clock_slot == no_slot) "none" else "set",
                self.icon_px,
                if (cfg.dock.icon_theme.len > 0) cfg.dock.icon_theme else "hicolor",
                self.dirty_src,
                joinList(&keybuf, keys[0..nkeys]),
                self.running.len,
                joinList(&runbuf, self.running),
                self.tray_keys.len,
                if (self.tray.hosting) "hosting" else "mirroring",
                joinList(&traybuf, self.tray_keys),
                t_strip - t0,
                t_widths - t_strip,
                t_icons - t_widths,
                if (cfg.dock.dock_show_dock) "on" else "off",
                if (cfg.dock.dock_group_apps) "on" else "off",
                @tagName(cfg.renderer),
            },
        );
    }

    /// `running_apps`: every live `app_id`, normalised
    /// the way `normalize_desktop_app_id` does, minus the ones the pinned
    /// section already owns (`dock_pinned_merge_running_slot` skips them) and
    /// minus two ids dropped outright.
    ///
    /// When `grouped` (the `group_apps` setting) several windows of one app
    /// are one dock slot; ungrouped, every window gets its own slot, so the
    /// toggle visibly splits and merges the strip.
    ///
    /// Returned strings are owned by the caller; the strip borrows them, so
    /// they must outlive the strip built from them.
    fn collectRunning(
        gpa: std.mem.Allocator,
        tr: *foreign.Tracker,
        pinned: []const []const u8,
        grouped: bool,
    ) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| gpa.free(s);
            out.deinit(gpa);
        }
        for (tr.windows.items) |w| {
            if (w.closed or w.app_id.len == 0) continue;
            const norm = paths.normalizeAppId(gpa, w.app_id) catch continue;
            defer gpa.free(norm);
            if (std.mem.eql(u8, norm, "unknown")) continue;
            if (std.mem.eql(u8, norm, kSettingsAppId) or
                std.mem.eql(u8, norm, kRailSettingsAppId)) continue;
            if (isPinnedId(norm, pinned)) continue;
            // Several windows of one app are one dock slot — unless grouping
            // is off, in which case each window keeps its own.
            var seen = false;
            if (grouped) {
                for (out.items) |s| {
                    if (std.ascii.eqlIgnoreCase(s, norm)) {
                        seen = true;
                        break;
                    }
                }
            }
            if (seen) continue;
            try out.append(gpa, try gpa.dupe(u8, norm));
        }
        return out.toOwnedSlice(gpa);
    }

    /// `dock_pin_identity_list_contains_toplevel_key` — the pinned list holds
    /// desktop-file ids (`sh.cider.Cider`) while the tracker holds whatever
    /// the compositor reports for the window (`cider`), and neither side is
    /// guaranteed to be spelled like the other. Normalising both and asking
    /// `paths.sameAppId` reconciles them on token boundaries only, so a pin
    /// claims its own window and nothing that merely ends the same way —
    /// `steam` still refuses `steam-native`.
    fn isPinnedId(norm: []const u8, pinned: []const []const u8) bool {
        if (norm.len == 0) return false;
        for (pinned) |p| {
            if (paths.sameAppId(p, norm)) return true;
        }
        return false;
    }

    fn makeClockLabel(self: *Dock) []u8 {
        const cfg = &self.app.loaded.cfg;
        const gpa = self.app.gpa;
        // The slot key is the widget instance id, which carries the
        // per-instance overrides (`clock_paint.optionsFor`); without a slot
        // the bare `clock` id reads the same global defaults.
        const instance: []const u8 = if (self.clock_slot < self.strip.slots.len and
            self.strip.slots[self.clock_slot].kind == .clock)
            self.strip.slots[self.clock_slot].key
        else
            "clock";
        const opts = clock_paint.optionsFor(cfg, instance);
        const tm = clock_paint.resolveTime(clock_paint.nowSeconds(), cfg.time.timezone) orelse
            return &.{};
        const lines = clock_paint.formatLines(gpa, tm, opts) catch
            return &.{};
        defer clock_paint.freeLines(gpa, lines);
        if (lines.len == 0) return &.{};
        if (lines.len == 1) return dupText(gpa, lines[0]);
        return std.mem.join(gpa, " ", lines) catch &.{};
    }

    /// Returns true when the clock text actually moved, so callers can skip
    /// the relayout on ticks where nothing changed.
    fn refreshLabel(self: *Dock) bool {
        if (self.clock_slot == no_slot) return false;
        const fresh = self.makeClockLabel();
        if (std.mem.eql(u8, self.label, fresh)) {
            self.app.gpa.free(fresh);
            return false;
        }
        if (self.label.len > 0) self.app.gpa.free(self.label);
        self.label = fresh;
        self.clock_max_w = self.measureText(self.label, dwp.clockFontPx(@floatFromInt(self.icon_px)));
        return true;
    }

    /// Re-run the width pass and resize the strip when the answer differs.
    /// Every live widget that can change its own width lands here rather than
    /// repeating the three lines.
    fn relayoutStrip(self: *Dock) void {
        self.computeWidths();
        const want = self.desiredSize();
        if (want.w != self.req_w or want.h != self.req_h) self.applySize();
        self.layout();
        // The media widget only ever hears about itself from the tick — it
        // has no event of its own — so switching it on has to start the clock
        // that will poll for a player.
        if (self.hasMediaSlot()) self.armAnim();
    }

    fn computeWidths(self: *Dock) void {
        if (self.widths.len != self.strip.slots.len) return;
        const cfg = &self.app.loaded.cfg;
        // Widths only need the dock-level metrics; the pill box does not enter.
        // `fit` goes in so a slot's floors and caps (icon * 1.25, bar_h * 6)
        // shrink with the output the same way the paint does — an unscaled
        // Metrics here is what left 1440-width slots full of 720-size icons.
        const m = dw.Metrics.of(cfg, 0, 0, self.fit);
        // The weather readout's inner run is measured through the same scratch
        // context the paint path uses, so the slot is exactly wide enough for
        // icon + temperature + unit pill instead of falling back to 72 px.
        // The control-center pill is 3 glyphs by default (net + audio + bt,
        // mic only while it runs) — `cc_slot.iconCount`, same rule as
        // `dock_control_center_slot_width`. Pear carries its own pill with
        // the same shape (`pear_slot.iconCount`).
        var cc_n: u8 = 0;
        var pear_n: u8 = 0;
        var media_meas = media_paint.Measured{};
        var media_ctrl: f64 = 0.0;
        var media_done = false;
        for (self.strip.slots) |s| {
            if (s.kind == .control_center and cc_n == 0) {
                const ccfg = cc_slot.loadCfg(cfg, s.key);
                cc_n = @intCast(cc_slot.iconCount(ccfg, self.cc_rt));
            } else if (s.kind == .pear_center and pear_n == 0) {
                const pcfg = pear_slot.loadCfg(cfg, s.key);
                pear_n = @intCast(pear_slot.iconCount(pcfg, self.pear_rt));
            }
            if (s.kind == .media and !media_done) {
                // The media pill measures the *track*, not the widget: the
                // title and artist widths are pango's answer and the button
                // row only exists while a player is speaking.
                media_done = true;
                const icon_px: f64 = @floatFromInt(self.icon_px);
                media_meas = media_paint.measure(
                    self.ensureMeasure(),
                    cfg,
                    s.key,
                    icon_px,
                    self.media.snap,
                    false,
                );
                media_ctrl = if (self.media.snap.realActive())
                    media_paint.ctrlRowWidth(media_paint.scaleOf(icon_px))
                else
                    0.0;
                // The pill paints from the dock's copy, not from this local:
                // the width pass and the paint have to agree, and only one of
                // them runs on every relayout.
                self.media_measured = media_meas;
                self.media_ctrl_w = media_ctrl;
            }
            if (cc_n != 0 and pear_n != 0 and media_done) break;
        }
        // Workspace cells measure from the live entries; a refresh here
        // is throttled, so the width pass usually just re-reads them.
        _ = self.reloadWorkspaces(false);
        var ws_count: usize = 0;
        var ws_w: f64 = 0;
        for (self.strip.slots) |s| {
            if (s.kind != .workspaces) continue;
            ws_count = self.ws_entries.len;
            if (ws_count > 0) {
                ws_w = ws_paint.dockWorkspacesSlotWidth(
                    self.measure,
                    cfg,
                    s.key,
                    m.icon,
                    m.bar_h,
                    self.ws_entries,
                );
            }
            break;
        }
        // World clock: the face's own measured width (the widest city name
        // capped, dots and paddings). The generic rule in `dock/widgets.zig`
        // clamps the final slot on top of it.
        var wc_inner: f64 = 0;
        if (self.wc_init) {
            for (self.strip.slots) |s| {
                if (s.kind != .world_clock) continue;
                const icon_px: f64 = @floatFromInt(self.icon_px);
                wc_inner = wc_face.slotWidth(&self.wc, self.ensureMeasure(), wc_face.scaleOf(icon_px));
                break;
            }
        }
        const meas = dw.Measured{
            .workspace_count = ws_count,
            .workspace_w = ws_w,
            .clock_max_w = self.clock_max_w,
            .world_clock_inner = wc_inner,
            .weather_inner = wpaint.weatherInnerWidth(
                self.measure,
                cfg,
                weatherWidgetKey(self.strip.slots),
                m.icon,
            ),
            .cc_icons = cc_n,
            .pear_icons = pear_n,
            .media_text_w = media_meas.text_w,
            .media_ctrl_w = media_ctrl,
        };
        for (self.strip.slots, 0..) |s, i| {
            self.widths[i] = dw.slotWidth(cfg, s, m, meas);
            if (s.kind == .battery) {
                // The battery slot draws its glyph + an optional `NN%` label, so
                // its width follows the live reading (an absent battery is a bare
                // glyph) — the widget measures that itself off `battery_paint.state`
                // the host just wrote.
                self.widths[i] = bat_paint.dockBatterySlotWidth(
                    self.measure,
                    cfg,
                    s.key,
                    m.icon,
                    m.bar_h,
                );
            } else if (s.kind == .bluetooth) {
                // The widget's own width hook: this slot goes to
                // `dock_bluetooth_slot_width` instead of to the
                // generic rule: the label it draws is not in `Measured`, and
                // without this it would spill out past icon + pad. The reading
                // that label is derived from is right here, so the width and
                // the pill can never disagree about what is on screen.
                self.widths[i] = bt_paint.dockBluetoothSlotWidth(
                    self.measure,
                    cfg,
                    s.key,
                    m.icon,
                    m.bar_h,
                    &self.bt_snap,
                    self.bt_devs,
                );
            } else if (s.kind == .layout) {
                // This slot goes to
                // `dock_layout_slot_width` the way it hands bluetooth to its
                // own: an icon-only pill whose pad follows the shell's UI
                // scale, and never the label blanket the generic rule would
                // give it.
                self.widths[i] = lay_paint.dockLayoutSlotWidth(
                    self.measure,
                    cfg,
                    s.key,
                    m.icon,
                    m.bar_h,
                );
            }
        }
        // Every slot has now said how wide it *wants* to be; fit the strip to
        // the output it has to live on (see `fitWidths`).
        self.fitWidths(m, meas);
    }

    /// What the strip itself may claim from its output: the width left after
    /// `contentWidth`'s padding on both sides, so a strip fitted to this
    /// budget produces exactly an output-wide request — which is the width
    /// that keeps the dock on screen (see `desiredSize`). 0 means the
    /// compositor has not named an output yet, and the fit pass stands down.
    fn fitBudget(self: *Dock) f64 {
        const out_w = self.outputLogicalW();
        if (out_w <= 0.0) return 0.0;
        const pad: f64 = @floatFromInt(dw.outerPad(&self.app.loaded.cfg, self.fit));
        return @max(0.0, out_w - 2.0 * pad);
    }

    /// The shrink pass — the other half of the width question. `computeWidths`
    /// answers "how wide does each slot *want* to be?"; this answers "how
    /// wide may the strip be?", and hands the difference back in the order
    /// widgets can least afford to lose it:
    ///
    ///  1. the media title — the one run on the strip that scrolls anyway (the
    ///     marquee takes over the moment its share shrinks, since the paint
    ///     path derives its text budget from the slot width) and the usual
    ///     reason a dock outgrows its screen in the first place;
    ///  2. the padding around the runs the text widgets draw, taken
    ///     proportionally — their labels are centred without being clipped,
    ///     so the run itself never goes;
    ///  3. nothing more: what is left over is the compression `computeGeom`'s
    ///     `h_scale` already performs, with the clamp in `desiredSize` as the
    ///     hard stop behind it. Both keep every slot on the output.
    ///
    /// `widths` is rebuilt from the config on every `computeWidths`, so
    /// nothing here can accumulate across relayouts.
    fn fitWidths(self: *Dock, m: dw.Metrics, meas: dw.Measured) void {
        if (self.widths.len != self.strip.slots.len) return;
        const cfg = &self.app.loaded.cfg;
        const budget = self.fitBudget();
        if (budget <= 0.0) return;
        const gap: f64 = @floatFromInt(self.gap);
        var total = dw.concatWidth(cfg, self.strip.slots, self.widths, gap, self.fit);
        if (total <= budget) return;

        // 1. The media pill gives up its title, down to `min0` — the pill
        //    with the art and the transport row still in it.
        for (self.strip.slots, 0..) |s, i| {
            if (s.kind != .media) continue;
            const floor = dw.mediaMinWidth(m.icon, m.bar_h, meas.media_ctrl_w, meas.media_text_w);
            const take = @min(@max(0.0, self.widths[i] - floor), total - budget);
            self.widths[i] -= take;
            total -= take;
            break;
        }

        // 2. The padding the text widgets keep around their run, every one
        //    of them in proportion to what it has spare.
        if (total > budget) {
            var slack: f64 = 0;
            for (self.strip.slots, 0..) |s, i| {
                slack += @max(0.0, self.widths[i] - dw.slotFloorWidth(cfg, s, m, meas, self.widths[i]));
            }
            if (slack > 0.0) {
                const share = @min(1.0, (total - budget) / slack);
                for (self.strip.slots, 0..) |s, i| {
                    const give = @max(0.0, self.widths[i] - dw.slotFloorWidth(cfg, s, m, meas, self.widths[i]));
                    self.widths[i] -= give * share;
                }
            }
        }
    }

    /// The key of the first weather slot, or a placeholder when the widget is
    /// off — the width pass still has to produce something finite.
    fn weatherWidgetKey(slots: []const dw.Slot) []const u8 {
        for (slots) |s| {
            if (s.kind == .weather) return s.key;
        }
        return "weather";
    }

    // -----------------------------------------------------------------
    // Media widget
    // -----------------------------------------------------------------

    fn nowMs() u64 {
        return @intCast(@divTrunc(anim.monotonicNs(), std.time.ns_per_ms));
    }

    /// Ask the player where it is and pick up anything it changed. Returns
    /// true when the strip must be re-measured: a track, a capability, a
    /// player arriving or leaving, or cover art landing. The position alone
    /// never counts — a moving playhead must not reflow the dock under the
    /// pointer.
    fn pollMedia(self: *Dock) bool {
        self.media_next_ms = nowMs() + k_media_poll_ms;
        const changed = self.media.poll();
        self.resetCoverBudgetOnTrackChange();
        // A new track (or first sight of one) publishes its mpris entry so
        // the notification daemon toasts it; the cover follows when it
        // lands in `stepCoverArt` below.
        self.pushMprisTrack();
        // Bench: sender summary + fresh failures, at most every 60 s and
        // only when something changed (at most the daemon's cadence).
        {
            const now = nowMs();
            if (now - self.notif_stats_report_ms > 60_000 and
                self.notif_stats.serial() != self.notif_stats_reported)
            {
                self.notif_stats_report_ms = now;
                self.notif_stats_reported = self.notif_stats.serial();
                const sum = self.notif_stats.senderSummary(self.app.gpa);
                defer if (sum.len > 0) self.app.gpa.free(sum);
                if (sum.len > 0) logz.log("notify bench: {s}", .{sum});
                const fresh = self.notif_stats.failuresSince(self.app.gpa, &self.notif_fail_seen);
                defer if (fresh.len > 0) self.app.gpa.free(fresh);
                if (fresh.len > 0) logz.log("notify bench failures:\n{s}", .{fresh});
            }
        }
        // The cover is stepped on every tick rather than only on a change: a
        // request the worker refused because one was already running has to
        // be asked for again, a finished one has to be collected, and a
        // source that missed once has to be tried again once its backoff is up.
        const landed = self.stepCoverArt();
        return changed or landed;
    }

    /// The cover budget belongs to the track, so a new one starts it over —
    /// even onto a source that has already been spent. Consecutive tracks of
    /// an album advertise the same URL, and one that failed must not silence
    /// every track that shares it. A status change alone does not reset it:
    /// asking again for the same address that just failed is pointless.
    fn resetCoverBudgetOnTrackChange(self: *Dock) void {
        const gpa = self.app.gpa;
        const snap = self.media.snap;
        const id: []const u8 = if (snap.track_id.len > 0) snap.track_id else snap.title;
        const same = if (self.media_art_track) |t| std.mem.eql(u8, t, id) else false;
        if (same) return;
        if (self.media_art_track) |t| gpa.free(t);
        self.media_art_track = gpa.dupe(u8, id) catch null;
        self.media_art_misses = 0;
        self.media_art_retry_ms = 0;
    }

    /// Ask for this track's cover when the source has moved on, and take
    /// delivery of anything the worker finished. Returns true when new pixels
    /// landed, which wants a repaint even though nothing re-measures.
    fn stepCoverArt(self: *Dock) bool {
        const gpa = self.app.gpa;
        const snap = self.media.snap;

        // What to ask for: whatever the player advertises, or — when it
        // advertises nothing usable — the still a video page has on offer,
        // or a marker naming the track for a player whose covers sit in a
        // sandbox-private cache. Owned here, freed with this call.
        const src = mpris_art.sourceFor(gpa, .{
            .bus_name = snap.bus_name,
            .art_url = snap.art_url,
            .track_url = snap.track_url,
            .title = snap.title,
            .artist = snap.artist,
            .album = snap.album,
        });
        defer if (src) |s| gpa.free(s);
        const want: []const u8 = src orelse "";

        const asked = if (self.media_art_key) |k| std.mem.eql(u8, k, want) else false;
        if (!asked) {
            // The old cover describes the track that has gone, so it goes
            // too — with the card pointed at whatever is current first, in
            // case it is still painting from it. The source is remembered as
            // soon as it is seen, whether or not the worker took it: the key
            // says what the pixels would be for, the backoff below says when
            // to ask for them.
            self.retireMediaArt();
            if (self.media_art_key) |k| gpa.free(k);
            self.media_art_key = gpa.dupe(u8, want) catch null;
            self.media_art_misses = 0;
            self.media_art_retry_ms = 0;
            // New source, new clock: the old load (if any) is abandoned.
            self.notif_stats.art_in_flight = false;
            self.notif_stats.art_kick_ms = 0;
            // A cover decoded before — this session or a previous one — is
            // on disk as raw pixels. Finding it is a read, and the art is
            // on screen before this tick ends; the worker is never asked.
            if (want.len > 0) {
                const t0 = anim.monotonicNs();
                if (cover_cache.find(gpa, self.app.io, want)) |cv| {
                    const us = @divTrunc(anim.monotonicNs() - t0, 1000);
                    self.media_art_owner = cv.pixels;
                    self.media_art = .{ .pixels = cv.pixels, .w = cv.w, .h = cv.h };
                    self.pushMprisArt();
                    if (self.popup.kind == .media_player) self.syncMediaPopup();
                    logz.log("cover: '{s}' found on disk in {d}us", .{ want, us });
                    return true;
                }
            }
        }

        // Ask while this source has nothing on screen and its backoff has
        // run out. The worker refuses while it is busy, which costs one
        // atomic load and is asked again on the next tick.
        if (want.len > 0 and !self.media_art.present() and nowMs() >= self.media_art_retry_ms) {
            // Kick once per source: retries must not restart the clock, or
            // the latency only ever measures the last attempt.
            if (!self.notif_stats.art_in_flight) {
                self.notif_stats.noteArtLoadKick();
                self.notif_stats.setArtKickMs(@as(i64, @intCast(nowMs())));
            }
            _ = cover_worker.request(gpa, self.app.io, want);
        }

        var res: cover_worker.Result = .{};
        if (!cover_worker.take(&res)) return false;
        defer res.deinit(gpa);
        const got = res.url orelse "";
        // An answer for a source this dock has already left behind is dropped:
        // the player can move on while the fetch is still running.
        const current = if (self.media_art_key) |k| std.mem.eql(u8, k, got) else false;
        if (!current) {
            self.notif_stats.noteArtLoadStale(gpa, @as(i64, @intCast(nowMs())));
            return false;
        }
        // Nothing usable. Rather than leaving this source blank until the
        // player happens to move on, back off and come back to it.
        if (!res.cover.present()) {
            self.missCover();
            _ = self.notif_stats.noteArtLoadDone(gpa, @as(i64, @intCast(nowMs())), false);
            logz.log("cover: source '{s}' produced nothing ({d}/{d} misses)", .{
                got,
                self.media_art_misses,
                k_cover_max_misses,
            });
            return false;
        }
        _ = self.notif_stats.noteArtLoadDone(gpa, @as(i64, @intCast(nowMs())), true);
        self.media_art_misses = 0;
        self.media_art_retry_ms = 0;

        self.media_art_owner = res.cover.pixels;
        self.media_art = .{ .pixels = res.cover.pixels, .w = res.cover.w, .h = res.cover.h };
        res.cover.pixels = &.{}; // the dock owns them from here
        self.pushMprisArt();
        if (self.popup.kind == .media_player) self.syncMediaPopup();
        return true;
    }

    /// Publish this track's mpris entry when it changes. The daemon keys on
    /// `bus+title+artist` and expires entries by timeout, so repeats are
    /// cheap and a re-poll never duplicates.
    fn pushMprisTrack(self: *Dock) void {
        const gpa = self.app.gpa;
        const snap = self.media.snap;
        if (!snap.have_player or snap.title.len == 0) return;
        const key = notify_push.trackKey(gpa, snap.bus_name, snap.title, snap.artist) catch return;
        defer gpa.free(key);
        if (self.notif_last_key) |old| {
            if (std.mem.eql(u8, old, key)) return;
            gpa.free(old);
            self.notif_last_key = null;
        }
        self.notif_last_key = gpa.dupe(u8, key) catch null;
        const now = @as(i64, @intCast(nowMs()));
        const ok = self.notif_push.pushMpris(
            now,
            getenvStr("EH_IPC_SOCKET"),
            getenvStr("XDG_RUNTIME_DIR"),
            key,
            snap.title,
            snap.artist,
        );
        if (ok) {
            self.notif_stats.notePushMpris();
        } else {
            self.notif_stats.notePushFailed(gpa, now, "mpris");
        }
        // No art source at all: this entry will never grow a cover.
        if (snap.art_url.len == 0) {
            const derived = mpris_art.youtubeThumb(gpa, snap.track_url);
            if (derived) |d| {
                gpa.free(d);
            } else {
                self.notif_stats.noteEmitNoArt();
            }
        }
    }

    /// Publish freshly landed cover art under the current track's key. The
    /// daemon drops art with no matching entry, so a key the entry push has
    /// not announced yet is harmless.
    fn pushMprisArt(self: *Dock) void {
        if (!self.media_art.present()) return;
        const snap = self.media.snap;
        if (!snap.have_player or snap.title.len == 0) return;
        const gpa = self.app.gpa;
        const key = notify_push.trackKey(gpa, snap.bus_name, snap.title, snap.artist) catch return;
        defer gpa.free(key);
        const now = @as(i64, @intCast(nowMs()));
        const ok = self.notif_push.pushMprisArt(
            now,
            getenvStr("EH_IPC_SOCKET"),
            getenvStr("XDG_RUNTIME_DIR"),
            key,
            self.media_art.pixels,
            self.media_art.w,
            self.media_art.h,
        );
        if (ok) {
            self.notif_stats.notePushArt(self.notif_push.last_bytes);
        } else {
            self.notif_stats.notePushFailed(gpa, now, "mpris-art");
        }
    }

    /// Make room for a new cover. The card reads pixels that are not the ones
    /// `media_art` currently names, so it is pointed at them first and the set
    /// it was holding is kept one round longer before it goes. Everything the
    /// card cannot have seen is freed immediately.
    fn retireMediaArt(self: *Dock) void {
        const gpa = self.app.gpa;
        const card_up = self.popup.kind == .media_player;
        if (card_up) self.syncMediaPopup();
        if (self.media_art_prev) |px| gpa.free(px);
        self.media_art_prev = null;
        if (self.media_art_owner) |px| {
            if (card_up) {
                self.media_art_prev = px;
            } else {
                gpa.free(px);
            }
        }
        self.media_art_owner = null;
        self.media_art = .{};
    }

    /// A source that answered with nothing. Wait before asking it again —
    /// the usual reason is a session that has only just come up — and stop
    /// asking altogether once it has had its chances.
    fn missCover(self: *Dock) void {
        self.media_art_misses += 1;
        const step: u6 = @intCast(@min(self.media_art_misses - 1, 5));
        const backoff = k_cover_retry_base_ms << step;
        self.media_art_retry_ms = if (self.media_art_misses >= k_cover_max_misses)
            std.math.maxInt(u64)
        else
            nowMs() + @min(backoff, k_cover_retry_max_ms);
    }

    fn freeMediaArt(self: *Dock) void {
        const gpa = self.app.gpa;
        if (self.media_art_owner) |px| gpa.free(px);
        self.media_art_owner = null;
        if (self.media_art_prev) |px| gpa.free(px);
        self.media_art_prev = null;
        self.media_art = .{};
        if (self.media_art_key) |k| gpa.free(k);
        self.media_art_key = null;
        if (self.media_art_track) |t| gpa.free(t);
        self.media_art_track = null;
        self.media_art_misses = 0;
        self.media_art_retry_ms = 0;
    }

    /// Whether the strip is showing the media widget at all. A dock without
    /// it has nothing to read off the bus and no reason to wake up for one.
    fn hasMediaSlot(self: *Dock) bool {
        for (self.strip.slots) |s| {
            if (s.kind == .media) return true;
        }
        return false;
    }

    /// Which of the pill's own zones a press landed in, or -1. The pointer is
    /// given in surface coordinates; the slot box is the same arithmetic
    /// `repaint` uses to put it there.
    fn mediaZone(self: *Dock, idx: usize, pointer_x: f64) i32 {
        const box = self.slotBox(idx);
        if (box[1] <= 1.0) return -1;
        const icon_px: f64 = @floatFromInt(self.icon_px);
        return media_paint.hitZone(pointer_x - box[0], box[1], icon_px);
    }

    /// Where a slot sits in surface coordinates, and how wide it is.
    fn slotBox(self: *Dock, idx: usize) [2]f64 {
        const g = self.geom orelse return .{ 0.0, 0.0 };
        if (idx >= self.strip.slots.len or idx >= g.widths.len) return .{ 0.0, 0.0 };
        const cfg = &self.app.loaded.cfg;
        const lx = dw.slotLayoutX(cfg, &g, idx);
        const sx = dw.layoutXToSurface(lx, g.mid_x, g.h_scale);
        return .{ sx, g.widths[idx] * g.h_scale };
    }

    /// The card the media slot opens. Like the calendar it is centred on the
    /// slot that asked for it, and unlike the pill it stays up while the
    /// player keeps talking.
    fn showMediaPlayer(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        const cx = self.slotCentreX(idx) orelse return;
        self.popup.reset();
        // The media card reads the widget-card scale off the config, like the
        // other widget popups, so push this frame's config before opening.
        self.popup.widget_cfg = &self.app.loaded.cfg;
        const ok = self.popup.openMediaPlayer(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            cx,
            chrome_colors.of(&self.app.loaded.cfg),
            self.fit,
        );
        if (!ok) {
            logz.log("media card: present failed slot={d}", .{idx});
            self.popup.reset();
            return;
        }
        self.syncMediaPopup();
        // The card has no event of its own either: without this the very
        // click that opens it could land on a dock whose tick had gone to
        // sleep, and the seekbar would sit at the position it was drawn with.
        self.armAnim();
        logz.log("media card: open slot={d} at x={d}", .{ idx, self.popup.card_cx });
        if (!self.app.conn.flush()) logz.log("media card: flush failed", .{});
    }

    /// Push the current track into the card. Called on open and on every
    /// media poll while it is up, so the card never holds a reading the dock
    /// has already moved past.
    fn syncMediaPopup(self: *Dock) void {
        if (self.popup.kind != .media_player) return;
        const snap = self.media.snap;
        const now_ns: i64 = @intCast(anim.monotonicNs());
        self.popup.media = .{
            .active = snap.realActive(),
            .art = self.media_art,
            .title = ownText(&self.media_title_buf, snap.title),
            .artist = ownText(&self.media_artist_buf, snap.artist),
            .position_us = self.media_pos.project(snap, now_ns),
            .duration_us = snap.duration_us,
            .playing = snap.playing(),
            .can_play = snap.can_play,
            .can_pause = snap.can_pause,
            .can_prev = snap.can_go_previous,
            .can_next = snap.can_go_next,
            .shuffle = snap.shuffle,
            .loop_status = ownText(&self.media_loop_buf, snap.loop_status),
            .t_sec = @as(f64, @floatFromInt(anim.monotonicNs())) / 1e9,
            .hover = self.popup.media_hover,
        };
    }

    /// Copy a reading into a buffer the dock owns outright. The client frees
    /// the strings it publishes on the next poll, so the card cannot keep a
    /// pointer into them; and a cut that lands mid-character would hand pango
    /// invalid UTF-8 to measure.
    fn ownText(buf: []u8, src: []const u8) []const u8 {
        var n = @min(src.len, buf.len);
        if (n < src.len) {
            // `src[n]` is the first byte left out; while it is a continuation
            // byte the cut fell inside a character, so back up to its start.
            while (n > 0) {
                if ((src[n] & 0xC0) != 0x80) break;
                n -= 1;
            }
        }
        @memcpy(buf[0..n], src[0..n]);
        return buf[0..n];
    }

    /// Turn a click on the media card into a call on the player. Returns true
    /// when the card should stay up, false when it dismissed itself.
    fn runMediaPopupClick(self: *Dock) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const x: i32 = @intFromFloat(@round(seat.pointer_x));
        const y: i32 = @intFromFloat(@round(seat.pointer_y));
        const what = self.popup.cardClick(x, y);
        switch (what) {
            .media_shuffle => _ = self.media.setShuffle(!self.popup.media.shuffle),
            .media_prev => _ = self.media.act(.previous),
            .media_play => _ = self.media.act(.play_pause),
            .media_next => _ = self.media.act(.next),
            .media_repeat => _ = self.media.cycleLoop(),
            .media_seek => {
                const dur = self.popup.media.duration_us;
                if (dur > 0) {
                    const us: i64 = @intFromFloat(@as(f64, @floatFromInt(dur)) * self.popup.media_seek_frac);
                    _ = self.media.seek(us);
                }
            },
            else => return false,
        }
        // Every answer above leaves the card up: the pointer is still on it,
        // and the next click should land on a control rather than dismiss.
        return true;
    }

    fn resolveIcons(self: *Dock) void {
        if (self.icons.len != self.strip.slots.len) return;
        const gpa = self.app.gpa;
        const cfg = &self.app.loaded.cfg;
        const theme: []const u8 = if (cfg.dock.icon_theme.len > 0) cfg.dock.icon_theme else "hicolor";
        const dirs = icon_lookup.dataDirs(
            gpa,
            getenvStr("XDG_DATA_HOME"),
            getenvStr("HOME"),
            getenvStr("XDG_DATA_DIRS"),
        ) catch return;
        defer icon_lookup.freeDirs(gpa, dirs);
        const io = self.app.io;
        const app_dirs = app_launch.applicationsDirs(
            gpa,
            getenvStr("XDG_DATA_HOME"),
            getenvStr("HOME"),
            getenvStr("XDG_DATA_DIRS"),
        ) catch null;
        defer if (app_dirs) |d| app_launch.freeDirs(gpa, d);
        const sig = iconSig(cfg);
        for (self.strip.slots, 0..) |s, i| {
            // An icon the strip that just went away already had is adopted
            // rather than read and decoded again: a rebuild happens on every
            // window that opens or closes, and that is on the input path.
            self.icons[i] = self.takeCarried(s, sig) orelse
                self.resolveSlotIcon(gpa, io, dirs, app_dirs, theme, s);
            // Recorded here, while the slot's key still belongs to something:
            // the *next* rebuild reads this rather than the string.
            if (i < self.icon_keys.len) self.icon_keys[i] = slotIconSignature(s) ^ sig;
            if (self.icons[i].pixels.len == 0) {
                logz.log("icon: no art for slot={d} kind={s} key='{s}'", .{ i, @tagName(s.kind), s.key });
            }
        }
        self.dropCarried();
        self.refreshWsIcons();
    }

    fn resolveSlotIcon(
        self: *Dock,
        gpa: std.mem.Allocator,
        io: std.Io,
        dirs: []const []const u8,
        app_dirs: ?[][]const u8,
        theme: []const u8,
        s: dw.Slot,
    ) dock_paint.IconPx {
        var names: [16][]const u8 = undefined;
        var n: usize = 0;
        // The start menu paints the *distribution's* mark. `start-here` in a
        // macOS-flavoured theme is an Apple logo, which is the wrong badge for
        // this box — resolved the same way. Spotlight and the app drawer wear
        // the same mark (dock_paint_widget_bar.cpp:680 + 740), and so does the
        // App menu: its button *is* the launcher, and the bar's nine-dot grid
        // is only the fallback for a box whose distribution ships no logo we
        // can find (buglisttaskbar.md #1, matching the taskbar's `.app_menu`).
        if (s.kind == .smenu or s.kind == .spotlight or s.kind == .app_drawer or s.kind == .app_menu) {
            if (os_logo.loadDistroLogo(gpa, io, @intCast(self.icon_px))) |px| {
                return .{ .pixels = px.data, .w = px.w, .h = px.h };
            }
        }
        // A tray item brings its own art, which is why `iconCandidates(.tray)`
        // is empty, preferring the pixmap the client shipped
        // over the theme name — Chromium has no `IconName` at all — and only
        // then falls back to the theme, where an item's `IconThemePath` (Steam
        // is the usual offender) is searched first.
        if (s.kind == .tray) {
            const it = self.tray.itemForKey(s.key) orelse return .{};
            if (it.pixels.len > 0 and it.pw > 0 and it.ph > 0) {
                // The dock's icon cache frees this itself, so the store keeps
                // its own copy and we take another.
                const copy = gpa.dupe(u8, it.pixels) catch return .{};
                return .{ .pixels = copy, .w = it.pw, .h = it.ph };
            }
            if (it.icon_name.len > 0) {
                if (it.icon_theme_path.len > 0) {
                    // Steam ships `<IconThemePath>/<name>.png` outside any
                    // theme, so the item's own directory goes in front of the
                    // shell's search path.
                    const extra = gpa.alloc([]const u8, dirs.len + 1) catch null;
                    if (extra) |ex| {
                        defer gpa.free(ex);
                        ex[0] = it.icon_theme_path;
                        @memcpy(ex[1..], dirs);
                        if (loadIconFrom(gpa, io, ex, theme, it.icon_name, @intCast(self.icon_px))) |px| return px;
                    }
                }
                if (self.loadIcon(gpa, dirs, theme, it.icon_name)) |px| return px;
            }
            logz.log(
                "tray: no art for '{s}' (IconName='{s}' IconThemePath='{s}' pixmap={d}B) title='{s}'",
                .{ s.key, it.icon_name, it.icon_theme_path, it.pixels.len, it.title },
            );
            return .{};
        }
        if (s.kind == .app) {
            if (s.key.len > 0) {
                names[n] = s.key;
                n += 1;
            }
        } else {
            for (dwp.iconCandidates(s.kind)) |cand| {
                if (n >= names.len) break;
                names[n] = cand;
                n += 1;
            }
            if (s.key.len > 0 and n < names.len) {
                names[n] = s.key;
                n += 1;
            }
        }
        for (names[0..n]) |nm| {
            if (nm.len == 0) continue;
            if (self.loadIcon(gpa, dirs, theme, nm)) |px| return px;
        }
        // The app id is often not the icon name (`horizon-files` ships its art
        // as `horizon-filesv2`, and `Icon=` may be an absolute path).
        if (s.kind == .app) {
            if (app_dirs) |adirs| {
                if (app_launch.desktopIcon(gpa, io, adirs, s.key)) |icon_name| {
                    defer gpa.free(icon_name);
                    if (self.loadIcon(gpa, dirs, theme, icon_name)) |px| return px;
                }
            }
        }
        return .{};
    }

    fn loadIcon(
        self: *Dock,
        gpa: std.mem.Allocator,
        dirs: []const []const u8,
        theme: []const u8,
        name: []const u8,
    ) ?dock_paint.IconPx {
        // The shared cache answers from its theme-directory index instead of
        // re-probing the filesystem, and remembers misses, so a name that has
        // no art costs O(1) on every rebuild rather than ~250ms.
        if (icon_cache.shared()) |ic| {
            if (ic.getOwned(.app, name, self.icon_px)) |o| {
                return .{ .pixels = o.pixels, .w = o.w, .h = o.h };
            }
            return null;
        }
        return loadIconFrom(gpa, self.app.io, dirs, theme, name, self.icon_px);
    }

    fn measureText(self: *Dock, text: []const u8, font_px: f64) f64 {
        if (text.len == 0) return 0;
        const cr = self.ensureMeasure() orelse return 0;
        var buf: [64]u8 = undefined;
        const fd = std.fmt.bufPrint(&buf, "Inter {d}", .{@as(i32, @intFromFloat(font_px))}) catch return 0;
        var l = text_layout.Layout.createForCairo(cr);
        defer l.destroy();
        l.setFont(fd);
        l.setText(text);
        return @floatFromInt(l.pixelSize().w);
    }

    fn ensureMeasure(self: *Dock) ?*cairo.cairo_t {
        if (self.measure) |cr| return cr;
        const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 512, 64);
        if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(surf);
            return null;
        }
        const cr = cairo.cairo_create(surf);
        if (cairo.cairo_status(cr) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_destroy(cr);
            cairo.cairo_surface_destroy(surf);
            return null;
        }
        self.measure = cr;
        self.measure_surf = surf;
        return cr;
    }

    // -----------------------------------------------------------------
    // Geometry
    // -----------------------------------------------------------------

    fn pill(self: *Dock) dw.Pill {
        const cfg = &self.app.loaded.cfg;
        return dw.pillGeometry(cfg, self.buf_w, self.buf_h, self.dock_h, 0, self.fit);
    }

    fn layout(self: *Dock) void {
        if (self.strip.slots.len == 0 or self.buf_w <= 0 or self.buf_h <= 0) {
            self.geom = null;
            return;
        }
        const cfg = &self.app.loaded.cfg;
        const p = self.pill();
        const m = dw.Metrics.of(cfg, p.x, p.box_w, self.fit);
        self.geom = dw.computeGeom(
            cfg,
            self.strip.slots,
            self.widths,
            self.strip.left_n,
            self.strip.center_n,
            self.strip.right_n,
            m,
        );
    }

    /// Layer surface size the current strip wants. `contentWidth` pads the
    /// strip on both sides and clamps.
    fn desiredSize(self: *Dock) struct { w: i32, h: i32 } {
        const cfg = &self.app.loaded.cfg;
        const total = dw.concatWidth(cfg, self.strip.slots, self.widths, @floatFromInt(self.gap), self.fit);
        var w = dw.contentWidth(cfg, total, self.fit);
        // The surface is anchored to one edge only, so the compositor centres
        // it: a request wider than the output is not pushed back on screen, it
        // is cut off at both ends. `fitWidths` is what makes this a formality
        // in practice; it stays as the hard stop for what the pass cannot see
        // — an output that reports late, or floors that will not give.
        const out_w = self.outputLogicalW();
        if (out_w > 0.0) w = @min(w, @max(1, @as(i32, @intFromFloat(@floor(out_w)))));
        return .{
            .w = w,
            .h = self.dock_h + dw.effectiveBottomGap(cfg),
        };
    }

    fn applySize(self: *Dock) void {
        const want = self.desiredSize();
        self.req_w = want.w;
        self.req_h = want.h;
        self.surface.setSize(@intCast(want.w), @intCast(want.h));
        self.syncExclusive();
        self.surface.commit();
        if (!self.app.conn.flush()) logz.log("flush failed after resize", .{});
    }

    /// Input region follows visibility: a hidden dock takes a 1x1 region so
    /// the screen edge stays clickable for real windows (mirroring
    /// `sync_input_region_layer`'s `!dockShowDock` branch); a shown dock gets
    /// NULL, i.e. the default full-surface region it has always had. Only
    /// called where visibility can change (boot, reload) — the request
    /// applies on the next commit, which both callers perform right after.
    fn syncInputRegion(self: *Dock) void {
        const surf = self.surface.wl_surface orelse return;
        if (self.app.loaded.cfg.dock.dock_show_dock) {
            wl.wl_surface_set_input_region(surf, null);
            return;
        }
        const comp = self.app.bound.compositor orelse return;
        const reg = wl.wl_compositor_create_region(comp) orelse return;
        wl.wl_region_add(reg, 0, 0, 1, 1);
        wl.wl_surface_set_input_region(surf, reg);
        wl.wl_region_destroy(reg);
    }

    /// The exclusive zone for the current config. A hidden dock reserves
    /// nothing (cleared to 0 when the dock hides, keeping the
    /// surface alive so flipping the toggle back on is instant); autohide
    /// takes -1; otherwise the bar height plus the configured gap.
    fn syncExclusive(self: *Dock) void {
        const cfg = &self.app.loaded.cfg;
        self.surface.setExclusiveZone(if (!cfg.dock.dock_show_dock)
            0
        else if (cfg.dock.dock_autohide)
            -1
        else
            self.req_h + cfg.dock.dock_exclusive_zone_gap);
    }

    // -----------------------------------------------------------------
    // Painting
    // -----------------------------------------------------------------

    /// Frame-phase bucket for a slot's painter: specialized widget faces
    /// (their own pill + content) bill "widgets"; the generic run through
    /// `paintPill`/`paintSlot` (app icons, tray, dots, clock) bills "icons".
    pub fn framePhaseBucket(p: *media_perf.Probe, kind: dw.Kind) void {
        switch (kind) {
            .weather,
            .media,
            .workspaces,
            .control_center,
            .pear_center,
            .volume_mixer,
            .vpn,
            .layout,
            .battery,
            .bluetooth,
            .overview,
            => p.frameMilestone(1, "widgets"),
            else => p.frameMilestone(2, "icons"),
        }
    }

    fn repaint(self: *Dock) void {
        if (self.buf_w <= 0 or self.buf_h <= 0) return;
        // The layout slot asks the compositor what it is running, which is an
        // IPC round trip; `setContext` is what lets `layout_paint.current()`
        // reach that IPC, and the one-second answer it caches is what keeps
        // the round trip off the paint path after the first frame. Idempotent,
        // and free when the slot is not in the strip.
        lay_paint.setContext(self.app.gpa, self.app.io);
        // A window opening mid-drag rebuilds the strip under it, so the slot
        // number the drag is holding is a guess until re-read. This is the
        // last place that can tell, before anything is drawn with it.
        if (self.pin_drag.dragging) self.pinDragLocate();
        // A media reason scheduled this frame; bill the whole repaint
        // (cairo draw + attach/damage/commit) when it presents.
        const perf = media_perf.get(.dock);
        if (perf.frame_reason) |r| perf.beginFrame(r);
        // Drawn into a buffer the compositor has already let go of. When it
        // still holds both, there is nothing safe to draw into and the frame
        // waits for the next event rather than landing under the screen —
        // which is what flicker is.
        const buf = self.shm.acquire() orelse {
            self.noteDroppedFrame();
            // Owed: drawn the instant a buffer comes back from the compositor
            // (`onShmRelease`) rather than whenever the next unrelated event
            // happens to trigger a repaint.
            self.pending = true;
            perf.cancelFrame();
            return;
        };
        self.pending = false;
        const cr = buf.cr orelse {
            perf.cancelFrame();
            return;
        };
        self.frame_buf = buf;
        const cfg = &self.app.loaded.cfg;
        const w: f64 = @floatFromInt(self.buf_w);
        const h: f64 = @floatFromInt(self.buf_h);

        // Clear with SOURCE, not the default OVER: a transparent fill under
        // OVER is a no-op, so the reused SHM buffer would keep the previous
        // frame's pixels and every repaint would compound its alpha on top —
        // the dock "fades in" over a dozen frames instead of painting fresh.
        // Same with `CAIRO_OPERATOR_CLEAR`.
        cairo.cairo_identity_matrix(cr);
        // Scale the whole frame to the output's device pixels. Every paint
        // site below keeps drawing in logical coordinates (buf_w/buf_h);
        // cairo rasterises at the buffer's native resolution so 2x HiDPI is
        // crisp instead of the compositor up-scaling a 1x buffer.
        const dsc: f64 = @floatFromInt(self.surface.scale);
        cairo.cairo_scale(cr, dsc, dsc);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
        cairo.cairo_rectangle(cr, 0, 0, w, h);
        cairo.cairo_fill(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);

        // `show_dock = false` leaves a transparent, input-free surface behind
        // rather than tearing the layer down, so the toggle back on needs no
        // rebind — the same reason the exclusive zone goes to 0, not -1.
        if (!cfg.dock.dock_show_dock) {
            self.present();
            return;
        }

        const p = self.pill();
        const r: f64 = @floatFromInt(self.radius);
        // Wallpaper-driven chrome (`derived_chrome_colors`): the pill
        // fill and accent follow the active palette, not static tokens.
        const chrome = chrome_colors.of(cfg);
        const bg = chrome.dock_fill;
        const accent = chrome.accent;
        // Whether a palette is actually driving
        // the bar, which picks accent-vs-static for the border, the glyphs
        // and the app-menu grid. The Zig schema has no `anyPaletteActive()`
        // helper (see the note in `workspaces_paint.zig`), so the three terms
        // are read inline the same way the vpn arm does below.
        const palette_on = (cfg.appearance.matugen_theming and cfg.appearance.matugen_palette_ok) or
            (cfg.appearance.horizon_colors_native and cfg.appearance.horizon_colors_ok) or
            cfg.appearance.custom_theme_enabled;
        // `bgAlpha`: the `opacity` setting as a fraction.
        const bg_alpha = dw.clampf(@as(f64, @floatFromInt(cfg.dock.dock_opacity)) / 100.0, 0.0, 1.0);

        const g = self.geom orelse return;

        // Background chrome: one rounded pill per run of slots, islands
        // included. The dock always draws its own fill, glass and border
        // behind a pill so an island never floats over bare wallpaper; the
        // widget-owned slot pill (weather, media, clock, …) or app/tray run
        // pill paints on top of it. With `[dock] islands` empty `pillBounds`
        // degenerates to the whole strip, so this paints exactly the single
        // bar it always has. A slotless strip keeps the plain band.
        const slot_count = self.strip.slots.len;
        var first: usize = 0;
        while (true) {
            var x0 = p.x;
            var x1 = p.x + p.box_w;
            if (slot_count > 0) {
                const pb = dw.pillBounds(cfg, &g, first);
                x0 = dw.layoutXToSurface(pb.x0, g.mid_x, g.h_scale);
                x1 = dw.layoutXToSurface(pb.x1, g.mid_x, g.h_scale);
                first = pb.last + 1;
            }
            const pill_w = @max(1.0, x1 - x0);

            // Deliberately no drop shadow around the bar. The surface is
            // only as tall as the bar plus the bottom gap (`desiredSize`),
            // and the bar hugs its top (`pillGeometry`), so a halo below
            // the bar lands *inside the margin strip* — with the dock
            // floating it reads as a dark smear under the bar instead of
            // depth, and none of it can fade past the surface edge into
            // the wallpaper anyway.

            // Base fill: surface-container at a third of its strength. The
            // opacity setting maps straight onto the fill's alpha — 100 is a
            // fully opaque pill ("zero transparent"), 0 leaves nothing of the
            // body. The old `bg_alpha * 0.78` cap over a near-black palette
            // colour capped the whole slider's visible range at a few percent.
            // `colored_glass` tints the fill toward the palette accent, so
            // the bar picks up the wallpaper's colour instead of staying
            // neutral — the switch was persisted but never painted before.
            var fr = bg.r * 0.35;
            var fg = bg.g * 0.35;
            var fb = bg.b * 0.35;
            if (cfg.dock.dock_colored_glass and palette_on) {
                const tt = 0.18;
                fr = fr * (1.0 - tt) + accent.r * tt;
                fg = fg * (1.0 - tt) + accent.g * tt;
                fb = fb * (1.0 - tt) + accent.b * tt;
            }
            cairo_helpers.roundedRect(cr, x0, p.y, pill_w, p.box_h, r);
            cairo.cairo_set_source_rgba(cr, fr, fg, fb, bg_alpha);
            cairo.cairo_fill(cr);

            if (cfg.dock.dock_liquid_glass) {
                dwp.paintGlassLayers(cr, x0, p.y, pill_w, p.box_h, bg_alpha, r);
            }

            if (cfg.dock.dock_border_enabled) {
                var bo = dw.clampf(@as(f64, @floatFromInt(cfg.dock.dock_border_opacity)) / 100.0, 0.0, 1.0);
                const raw: f64 = @floatFromInt(@min(@max(cfg.dock.dock_border_size, 1), 12));
                const bw = dw.clampf(raw * dw.uiScale(cfg), 1.0, 18.0);
                const inset = bw * 0.5;
                // Border arm: the palette's accent when one is
                // driving the bar (`anyPaletteActive`), the static `border_hue`
                // at 0.55/0.92 otherwise. Without the first half the rim stayed
                // sky-blue against a wallpaper-driven dock.
                const bc0 = if (palette_on) chrome.accent else dwp.hsvToRgb(@as(f64, @floatFromInt(cfg.dock.dock_border_hue)), 0.55, 0.92);
                // On a glass bar the border is a tint on the specular rim,
                // not a hard outline: blended toward white and eased back,
                // so even at `border_opacity = 100` it reads as a lit glass
                // edge instead of a sticker's die-cut outline.
                var bc = bc0;
                if (cfg.dock.dock_liquid_glass) {
                    const tt = 0.45;
                    bc = .{
                        .r = bc0.r * (1.0 - tt) + tt,
                        .g = bc0.g * (1.0 - tt) + tt,
                        .b = bc0.b * (1.0 - tt) + tt,
                    };
                    bo *= 0.65;
                }
                cairo.cairo_set_line_width(cr, bw);
                cairo_helpers.roundedRect(
                    cr,
                    x0 + inset,
                    p.y + inset,
                    @max(1.0, pill_w - bw),
                    @max(1.0, p.box_h - bw),
                    @max(0.0, r - inset),
                );
                cairo.cairo_set_source_rgba(cr, bc.r, bc.g, bc.b, bo);
                cairo.cairo_stroke(cr);
            }

            if (slot_count == 0 or first >= slot_count) break;
        }

        // Widget pill: surface-container plus a touch of accent, at the
        // `slot_pill_opacity` setting, folding
        // exactly these into `slot_pill_style::g_pill*` / `g_opacityScale`.
        const pill_rgb = tokens.Rgb{
            .r = bg.r * 0.6 + accent.r * 0.15,
            .g = bg.g * 0.6 + accent.g * 0.15,
            .b = bg.b * 0.6 + accent.b * 0.15,
        };
        const pill_alpha = widget_pill.settingAlpha(cfg.dock.slot_pill_opacity);

        // The shared slot-pill globals: `paintWeatherSlot` reads them through
        // `pill.paintPill`, and nothing else assigns them, so without this
        // every shared pill paints the Style default of solid white.
        widget_pill.style.pill_r = pill_rgb.r;
        widget_pill.style.pill_g = pill_rgb.g;
        widget_pill.style.pill_b = pill_rgb.b;
        widget_pill.style.opacity_scale = pill_alpha;
        // Hover accent comes from the palette accent — the
        // palette, not the static `m3` token. Every hover ring in the strip
        // is drawn from these, so without them the ring ignores the wallpaper.
        widget_pill.style.hover_accent_r = accent.r;
        widget_pill.style.hover_accent_g = accent.g;
        widget_pill.style.hover_accent_b = accent.b;
        const slot_h = @as(f64, @floatFromInt(self.icon_px));
        const slot_y = p.y + (p.box_h - slot_h) * 0.5;
        var last_kind: dw.Kind = self.strip.slots[0].kind;
        for (self.strip.slots, 0..) |s, i| {
            const lx = dw.slotLayoutX(cfg, &g, i);
            const sx = dw.layoutXToSurface(lx, g.mid_x, g.h_scale);
            const sw = g.widths[i] * g.h_scale;
            const hovered = self.hover == i;
            // Frame-phase billing: the span since the previous slot closes
            // into that slot's bucket (chrome up to here, then per slot),
            // and the per-slot argmax learns which painter ran long.
            const fperf = media_perf.get(.dock);
            if (fperf.frame_pending) {
                fperf.settleSlot(@tagName(last_kind));
                framePhaseBucket(fperf, s.kind);
            }
            last_kind = s.kind;

            if (s.kind == .weather) {
                // `paint_weather_slot` owns its own pill and its own text run
                // (glyph + temperature + unit pill), so it replaces the
                // generic painter instead of feeding it. It draws no hover of
                // its own — the wash goes on afterwards, like every other
                // slot that paints its own face.
                wpaint.paintWeatherSlot(
                    cr,
                    cfg,
                    s.key,
                    sx,
                    slot_y,
                    sw,
                    slot_h,
                    @floatFromInt(self.icon_px),
                    hovered,
                    self.pressed == i,
                );
                if (hovered) {
                    const rad = widget_pill.cornerRadius(slot_h, sw);
                    const a = chrome.accent;
                    cairo_helpers.roundedRect(cr, sx, slot_y, sw, slot_h, rad);
                    cairo.cairo_set_source_rgba(cr, a.r, a.g, a.b, 0.18);
                    cairo.cairo_fill_preserve(cr);
                    cairo.cairo_set_source_rgba(cr, a.r, a.g, a.b, 0.35);
                    cairo.cairo_set_line_width(cr, 1.0);
                    cairo.cairo_stroke(cr);
                }
                continue;
            }

            if (s.kind == .media) {
                // The media pill owns its entire face — art disc, scrolling
                // title and artist, progress border and transport row — so,
                // like the weather slot, it replaces the generic painter
                // instead of feeding it a shape to draw.
                const icon_px: f64 = @floatFromInt(self.icon_px);
                const ptr = lastPointer(self);
                const over = hovered;
                const local_x = ptr[0] - sx;
                const btn = if (over) media_paint.hitZone(local_x, sw, icon_px) else -1;
                const now_ns: i64 = @intCast(anim.monotonicNs());
                const res = media_paint.paint(
                    cr,
                    .{ .x = sx, .y = slot_y, .slot_w = sw, .slot_h = slot_h, .icon_px = icon_px },
                    .{
                        .snap = self.media.snap,
                        .art = self.media_art,
                        .measured = self.media_measured,
                        .hover_btn = btn,
                        .pointer_x = if (over) local_x else -1.0,
                        .pointer_y = if (over) ptr[1] - slot_y else -1.0,
                        .show_text = dw.settingBool(cfg, s.key, "show_text", true),
                        .title_scale = media_paint.titleScaleLimit(cfg, s.key),
                        .now_sec = @as(f64, @floatFromInt(now_ns)) / 1e9,
                        .now_ns = now_ns,
                    },
                    &self.media_pos,
                );
                self.media_wants_marquee = res.wants_marquee;
                self.media_progress_tick = res.progress_tick;
                // No pill-wide wash here: the media slot's hover feedback is
                // the ring `paint` puts on the button under the pointer, and
                // a wash on top of it would only muddy that.
                continue;
            }

            if (s.kind == .world_clock) {
                // The face owns its pill and content — one city at a time
                // rotating with the pager dots; hover and the popup-open
                // state get the shared accent wash, like the other widget
                // slots that paint their own faces.
                if (self.wc_init) {
                    wc_face.paint(
                        cr,
                        &self.wc,
                        sx,
                        slot_y,
                        sw,
                        slot_h,
                        @floatFromInt(self.icon_px),
                        hovered,
                        Dock.epochMs(),
                        chrome,
                    );
                }
                if (hovered or (self.popup.kind == .world_clock and self.wc_slot == i)) {
                    dwp.paintHoverOverlay(cr, sx, slot_y, sw, slot_h);
                }
                continue;
            }

            var d = dwp.Draw{
                // Which slots own a pill: Settings, VolumeMixer, Vpn and
                // Overview call `paint_pill` outright, and every widget whose
                // face a `paint_*_slot` owns paints one inside it. App and
                // tray never own one — their whole run does (`runPillLen`), so
                // a hovered cell gets the accent wash only; giving it a pill
                // of its own would composite over the run's and read as one
                // darker capsule in the middle of the bar. Smenu and the
                // trash take the generic `paintSlot` pill, so they read like
                // the widgets beside them; the bare logo slots (Spotlight,
                // AppDrawer, AppMenu) paint their face on the bar with the
                // hover wash behind it and nothing else.
                .pill = dw.ownsPill(s.kind),
                .kind = s.kind,
                // Icon frames are an app-icon treatment (`[dock] icon_frames`):
                // the logo slots keep their bare faces, and tray/localised
                // glyph widgets are not artwork to square off.
                .frame = cfg.dock.dock_icon_frames and s.kind == .app,
            };
            d.pill_rgb = pill_rgb;
            d.pill_alpha = pill_alpha;
            d.hover = hovered;
            d.lift = if (hovered and liftEligible(s.kind)) self.lift.value else 0.0;
            d.press = self.pressed == i and liftEligible(s.kind);
            // Resolved before the App menu's face decides: the button wears
            // the distribution mark like the smenu/Spotlight/AppDrawer slots
            // and the taskbar's App menu (buglisttaskbar.md #1). The nine-dot
            // launchpad grid is only the fallback for a box whose distribution
            // ships no logo we could find, and never the first letter of
            // `__app_menu__`.
            if (i < self.icons.len) d.icon = self.icons[i];
            if (s.kind == .app_menu and (d.icon == null or d.icon.?.pixels.len == 0)) {
                d.dots = 3;
                d.dot_rgb = if (palette_on) chrome.accent else .{ .r = 1.0, .g = 1.0, .b = 1.0 };
            }
            // One shared pill under a run of pinned apps, a run of running
            // apps, or a run of tray items — `firstPinnedInRun`,
            // `firstRunningInRun` and `firstTrayInRun`. It sits at the slot's
            // own `iconY` (no lift), so the cells glide over it.
            const rp = dw.runPillLen(cfg, self.strip.slots, i);
            if (rp > 0) {
                const px = dw.layoutXToSurface(dw.slotLayoutX(cfg, &g, i), g.mid_x, g.h_scale);
                const pw = dw.sectionWidth(cfg, self.strip.slots, self.widths, i, rp, g.m.gap, self.fit) * g.h_scale;
                dwp.paintPill(cr, px, slot_y, pw, slot_h, pill_rgb, pill_alpha, true);
            }
            if (s.kind == .app or s.kind == .settings or s.kind == .audio_center) {
                // A dot for running windows, never for pinned-but-closed:
                d.indicator = if (dw.launchTarget(s)) |tgt| self.toplevels.isRunning(tgt) else false;
            }
            if ((s.kind == .smenu or s.kind == .spotlight or s.kind == .app_drawer or s.kind == .app_menu) and palette_on) {
                // Pass `dockBarMatugen` and the
                // accent into `paint_logo_surface_scaled()` for the distro
                // mark, so the logo tracks the wallpaper's palette instead
                // of sitting at its shipped brand colour. Without this the
                // Fedora mark stayed a fixed sky-blue against a warm dock.
                // The App menu's mark rides the same rule.
                if (d.icon) |*ic| ic.tint = chrome.accent;
            }
            if (s.kind == .settings) {
                // The settings button draws the vendored Lucide gear, not
                // whatever the icon theme happens to call `preferences-system`
                // — themed glyphs for this one disagree wildly between themes
                // (a cog, a wrench-and-cog, a face), and the dock's own
                // identity is the Lucide set (`assets/UI/LICENSE-lucide.txt`).
                // `rail_settings` shares the kind and picks the panel-left
                // rail glyph below.
                d.icon = null;
            }
            const has_icon = if (d.icon) |ic| ic.pixels.len > 0 else false;
            if (i == self.clock_slot and self.label.len > 0) {
                d.label = self.label;
                d.icon = null;
            } else if (s.kind == .control_center) {
                // The quick-settings pill: network + audio + mic-while-running
                // + bluetooth status glyphs, not
                // a single icon. Painted here instead of the generic path so
                // the glyph row and its tints match the shared painter.
                var glyph_buf: [4]cc_slot.Glyph = undefined;
                const ccfg2 = cc_slot.loadCfg(cfg, s.key);
                const list = cc_slot.glyphs(ccfg2, self.cc_rt, &glyph_buf);
                cc_slot.paintSlot(cr, sx, slot_y, sw, slot_h, @floatFromInt(self.icon_px), list, pill_rgb, pill_alpha);
                if (d.hover) {
                    // Hover wash on top, same as every other widget slot —
                    // the wash alone, never the content pass.
                    dwp.paintHoverOverlay(cr, sx, slot_y, sw, slot_h);
                }
                continue;
            } else if (s.kind == .pear_center) {
                // Pear's own pill (`pear/slot.zig`): the same status-glyph shape
                // for both quick-settings widgets, drawn
                // from pear's standalone pill code.
                var pglyph_buf: [4]pear_slot.Glyph = undefined;
                const pcfg = pear_slot.loadCfg(cfg, s.key);
                const plist = pear_slot.glyphs(pcfg, self.pear_rt, &pglyph_buf);
                pear_slot.paintSlot(cr, sx, slot_y, sw, slot_h, @floatFromInt(self.icon_px), plist, pill_rgb, pill_alpha);
                if (d.hover) dwp.paintHoverOverlay(cr, sx, slot_y, sw, slot_h);
                continue;
            } else if (s.kind == .workspaces) {
                // The workspace strip: live cells from the Hyprland
                // snapshot, icons from the strip's own cache, animated
                // across resizes like the reference.
                const wicons = ws_paint.Icons{ .ctx = self, .get = wsIconSurf };
                const needs = ws_paint.paintWorkspacesSlot(
                    self.app.gpa,
                    cr,
                    cfg,
                    s.key,
                    sx,
                    slot_y,
                    sw,
                    slot_h,
                    @floatFromInt(self.icon_px),
                    self.ws_entries,
                    d.hover,
                    d.press,
                    wicons,
                    &self.ws_anim,
                    Dock.nowMs(),
                ) catch false;
                if (needs) self.armAnim();
                // The painter draws no hover of its own (`_ = hovered`); the
                // shared accent wash goes on after it, like every other slot
                // that owns its face.
                if (d.hover) dwp.paintHoverOverlay(cr, sx, slot_y, sw, slot_h);
                continue;
            } else if (s.kind == .battery) {
                // The battery widget's own painter — pill + glyph + optional
                // `NN%` label, coloured by charge state — replaces the generic
                // painter the way weather's, media's and bluetooth's do. Fed
                // `false, false` (pill fill ignores hover/press), then
                // the shared hover wash, so its hover reads like every other
                // widget slot.
                bat_paint.paintBatterySlot(
                    cr,
                    cfg,
                    s.key,
                    sx,
                    slot_y,
                    sw,
                    slot_h,
                    @floatFromInt(self.icon_px),
                    false,
                    false,
                );
                if (d.hover) dwp.paintHoverOverlay(cr, sx, slot_y, sw, slot_h);
                continue;
            } else if (s.kind == .bluetooth) {
                // The widget's own pill — status glyph, and the label the
                // width pass measured for it — replaces the generic painter
                // the way weather's and media's do. Fed `false, false` and
                // given the shared accent wash afterwards, matching
                // `paint_bluetooth_slot`, so its hover reads the same as
                // every other widget slot's.
                bt_paint.paintBluetoothSlot(
                    cr,
                    cfg,
                    s.key,
                    sx,
                    slot_y,
                    sw,
                    slot_h,
                    @floatFromInt(self.icon_px),
                    &self.bt_snap,
                    self.bt_devs,
                    false,
                    false,
                );
                if (d.hover) dwp.paintHoverOverlay(cr, sx, slot_y, sw, slot_h);
                continue;
            } else if (s.kind == .volume_mixer) {
                // VolumeMixer slot — the same
                // pill, wash and glyph the vpn slot draws, one name over:
                // `volume_up`, accent when a palette is driving the bar and
                // white when it is not. It resolves to Lucide's `volume-2`
                // through the vendored SVG bank.
                dwp.paintPill(cr, sx, slot_y, sw, slot_h, pill_rgb, pill_alpha, true);
                if (d.hover) {
                    dwp.paintSlot(cr, sx, slot_y, sw, slot_h, @floatFromInt(self.icon_px), .{
                        .pill = false,
                        .kind = s.kind,
                        .hover = true,
                    });
                }
                const icon_px: f64 = @floatFromInt(self.icon_px);
                // `palette_on` is frame-scoped, hoisted with the pill globals.
                const acc = chrome.accent;
                const gr = if (palette_on) acc.r else 1.0;
                const gg = if (palette_on) acc.g else 1.0;
                const gb = if (palette_on) acc.b else 1.0;
                const gx = sx + icon_px * 0.5;
                const gy = slot_y + icon_px * 0.5;
                _ = svg_icons.draw(cr, "volume_up", gx, gy, icon_px * 0.52, gr, gg, gb, 1.0, false);
                continue;
            } else if (s.kind == .vpn) {
                // Vpn slot: pill, the shared
                // wash, then `vpn_key` — the palette's accent when one is
                // actually driving the bar (`anyPaletteActive`), plain white
                // otherwise. The settings module maps `vpn_key` to Lucide's
                // `key-round`, which is what renders here.
                dwp.paintPill(cr, sx, slot_y, sw, slot_h, pill_rgb, pill_alpha, true);
                if (d.hover) dwp.paintHoverOverlay(cr, sx, slot_y, sw, slot_h);
                const icon_px: f64 = @floatFromInt(self.icon_px);
                // `palette_on` is frame-scoped, hoisted with the pill globals.
                const acc = chrome.accent;
                const gr = if (palette_on) acc.r else 1.0;
                const gg = if (palette_on) acc.g else 1.0;
                const gb = if (palette_on) acc.b else 1.0;
                const gx = sx + icon_px * 0.5;
                const gy = slot_y + icon_px * 0.5;
                _ = svg_icons.draw(cr, "vpn_key", gx, gy, icon_px * 0.52, gr, gg, gb, 1.0, false);
                continue;
            } else if (s.kind == .overview) {
                // Overview slot: the same pill-and-glyph shape the vpn arm
                // draws, with `dashboard` for the glyph — the mark the
                // C++ Overview arm paints (`draw_material_glyph` at
                // `icon * 0.52`): accent when a palette is driving the bar,
                // plain white otherwise. `dashboard` resolves to Lucide's
                // `layout-dashboard`, which is what renders here.
                dwp.paintPill(cr, sx, slot_y, sw, slot_h, pill_rgb, pill_alpha, true);
                if (d.hover) dwp.paintHoverOverlay(cr, sx, slot_y, sw, slot_h);
                const icon_px: f64 = @floatFromInt(self.icon_px);
                // `palette_on` is frame-scoped, hoisted with the pill globals.
                const acc = chrome.accent;
                const gr = if (palette_on) acc.r else 1.0;
                const gg = if (palette_on) acc.g else 1.0;
                const gb = if (palette_on) acc.b else 1.0;
                const gx = sx + icon_px * 0.5;
                const gy = slot_y + icon_px * 0.5;
                _ = svg_icons.draw(cr, "dashboard", gx, gy, icon_px * 0.52, gr, gg, gb, 1.0, false);
                continue;
            } else if (s.kind == .layout) {
                // Layout slot: the widget's own
                // painter draws the pill *and* the glyph of the layout it is
                // currently on, fed `false, false` and given the shared accent
                // wash after, so hover reads like every other widget slot's.
                // It asks the compositor what is running — which is the whole
                // point of the slot — through the one-second cache `repaint`
                // hands it a context for.
                lay_paint.paintLayoutSlot(
                    cr,
                    cfg,
                    s.key,
                    sx,
                    slot_y,
                    sw,
                    slot_h,
                    @floatFromInt(self.icon_px),
                    false,
                    false,
                );
                if (d.hover) dwp.paintHoverOverlay(cr, sx, slot_y, sw, slot_h);
                continue;
            } else if (!has_icon) {
                // Same for the other shape-identified slots: a letter is a
                // placeholder, not a glyph.
                if (s.kind == .media) {
                    d.lucide = "music_note";
                } else if (s.kind == .smenu or s.kind == .app_drawer) {
                    d.lucide = "apps";
                } else if (s.kind == .spotlight) {
                    d.lucide = "search";
                } else if (s.kind == .settings) {
                    d.lucide = if (std.mem.eql(u8, s.key, "rail_settings")) "view_sidebar" else "settings";
                } else if (s.kind == .audio_center) {
                    // The themed app icon owns the slot; the slider glyph is
                    // only the pre-install fallback.
                    d.lucide = "tune";
                } else if (s.kind == .clipstack) {
                    d.lucide = "content_paste";
                }
            }
            if (d.icon == null and d.label == null and d.dots == 0) {
                if (s.kind == .tray) {
                    // `__tray__<service><path>` is a key, never a name: use
                    // the first alnum of the item's title rather than paint a
                    // leading underscore.
                    if (self.tray.itemForKey(s.key)) |it| {
                        for (it.title, 0..) |ch, ci| {
                            const alnum = (ch >= 'A' and ch <= 'Z') or
                                (ch >= 'a' and ch <= 'z') or
                                (ch >= '0' and ch <= '9');
                            if (!alnum) continue;
                            d.letter = it.title[ci .. ci + 1];
                            break;
                        }
                    }
                } else if (s.key.len > 0 and s.key[0] < 0x80) {
                    d.letter = s.key[0..1];
                }
            }
            if (self.pin_drag.dragging and i == self.pin_drag.slot) {
                // The pin in the pointer's grip is painted below, where the
                // pointer is; this is the gap the run opens instead of it.
                d.icon = null;
                d.label = null;
                d.letter = null;
                d.lucide = "";
                d.dots = 0;
                d.indicator = false;
            }
            dwp.paintSlot(cr, sx, slot_y, sw, slot_h, @floatFromInt(self.icon_px), d);
        }
        if (self.pin_drag.dragging) self.paintDraggedIcon(cr, slot_y, slot_h);

        const fperf = media_perf.get(.dock);
        fperf.settleSlot(@tagName(last_kind));
        fperf.frameMilestone(3, "tail");
        fperf.frameMilestone(4, "present");

        // Temporary diagnostics: the draw reached the commit point, and it
        // is the first since `bg_alpha` moved — the settings → screen hand
        // off is only proven once a frame like this is on the wire.
        if (bg_alpha != self.diag_last_alpha) {
            self.diag_last_alpha = bg_alpha;
            eh.diag.log("paint: frame committed with bg_alpha={d:.2} (opacity={d})", .{ bg_alpha, cfg.dock.dock_opacity });
        }

        self.present();
    }

    /// The pin the pointer is holding: drawn where the pointer is, over the
    /// strip it came out of, with no pill of its own — the gap it left is what
    /// the run draws underneath it.
    fn paintDraggedIcon(self: *Dock, cr: ?*cairo.cairo_t, slot_y: f64, slot_h: f64) void {
        const slot = self.pin_drag.slot;
        if (slot >= self.icons.len or slot >= self.strip.slots.len) return;
        const px = self.icons[slot];
        if (px.pixels.len == 0) return;
        const g = self.geom orelse return;
        const sw = g.widths[slot] * g.h_scale;
        const x = lastPointer(self)[0];
        dwp.paintSlot(cr, x - sw * 0.5, slot_y, sw, slot_h, @floatFromInt(self.icon_px), .{
            .kind = .app,
            .icon = px,
            // Held above the strip the way a hover lifts an icon, so it reads
            // as taken out rather than as another slot in the run.
            .lift = 5.0,
        });
    }

    /// Attach, damage and push the SHM buffer. No roundtrip here on purpose —
    /// it would stall the event loop on a compositor round trip for every
    /// hover tick. The socket has to be pushed instead.
    fn present(self: *Dock) void {
        const buf = self.frame_buf orelse return;
        self.frame_buf = null;
        self.paint_frames += 1;
        self.surface.attach(buf.wlBuffer(), 0, 0);
        // The buffer carries `scale` device pixels per logical unit, so tell
        // the compositor before it scans the frame out.
        self.surface.setBufferScale(self.surface.scale);
        self.surface.damage(0, 0, self.buf_w, self.buf_h);
        buf.markBusy();
        self.surface.commit();
        // Bill the frame cost whether flush succeeded or not (the commit is
        // submitted either way; the retry path reuses the same surface state).
        media_perf.get(.dock).endFrame();
        if (self.app.conn.flush()) {
            self.flush_pending = false;
        } else {
            // The commit is now stuck in the client buffer: the compositor has
            // not taken it, so it will not release the buffer we just handed
            // it. Leave a flag and arm a short retry — if we simply moved on,
            // the pair would stay fully busy and every later frame would drop
            // forever (the freeze this recovers from).
            self.flush_pending = true;
            logz.log("flush failed after repaint", .{});
            self.armTick(k_anim_frame_ns);
        }
    }

    /// Counts frames the compositor would not take — it still held both
    /// buffers. Said at most once a second: the condition is bursty by
    /// nature, and the count is the part worth reading.
    fn noteDroppedFrame(self: *Dock) void {
        self.dropped_frames += 1;
        const now = Dock.nowMs();
        if (now < self.dropped_log_ms) return;
        self.dropped_log_ms = now + 1000;
        logz.log("paint: dropped {d} frame(s) — compositor still holds both buffers", .{self.dropped_frames});
        eh.diag.log("paint: DROPPED {d} frame(s), both buffers busy", .{self.dropped_frames});
        self.dropped_frames = 0;
    }

    /// A buffer came back from the compositor (`wl_buffer.release`). Two things
    /// can be waiting on it, and both are what keep the dock from freezing:
    ///
    ///   * a frame was owed because the pair was fully held — draw it now, or
    ///     the dock would sit blank/stale until some unrelated pointer or tick
    ///     event repaints it (the popup host does the same, `popup.zig`);
    ///   * a flush failed with EAGAIN and its commit is still sitting in the
    ///     client buffer — push it now. This is the permanent-freeze case: the
    ///     compositor only releases a buffer it has actually received, so a
    ///     commit stranded by a full socket is never retried on its own.
    fn onShmRelease(ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        if (self.flush_pending) {
            if (self.app.conn.flush()) {
                self.flush_pending = false;
            } else {
                // Still full: the release that got here freed a buffer, so
                // re-arm and try again rather than spin on this event.
                self.armTick(k_anim_frame_ns);
            }
        }
        if (!self.pending) return;
        self.pending = false;
        self.repaint();
    }

    // -----------------------------------------------------------------
    // Input
    // -----------------------------------------------------------------

    fn slotAt(self: *Dock, x: f64, y: f64) usize {
        const g = self.geom orelse return no_slot;
        const cfg = &self.app.loaded.cfg;
        const lx = dw.surfaceXToLayout(x, g.mid_x, g.h_scale);
        const i = dw.slotAtLayout(cfg, &g, lx) orelse return no_slot;
        const p = self.pill();
        const slot_h = @as(f64, @floatFromInt(self.icon_px));
        const slot_y = p.y + (p.box_h - slot_h) * 0.5;
        if (y < slot_y or y >= slot_y + slot_h) return no_slot;
        return i;
    }

    fn activate(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        const s = self.strip.slots[idx];
        // A tray icon is not an application: `org.kde.StatusNotifierItem`
        // handles the click itself, with the pointer position it happened at.
        if (s.kind == .tray) {
            const pos = lastPointer(self);
            logz.log("tray: activate '{s}'", .{s.key});
            self.tray.activate(
                s.key,
                @intFromFloat(@round(pos[0])),
                @intFromFloat(@round(pos[1])),
            );
            return;
        }
        // The settings gear is the one slot whose target is a shell component
        // rather than a desktop file: `Exec=horizon-settings` resolves to
        // whichever build PATH finds first, and this dock is part of the Zig
        // tree, so the copy sitting next to it wins. The `rail_settings`
        // variant launches the redesigned `settings` binary instead — same
        // app id, so focus-existing covers either settings window.
        if (s.kind == .settings) {
            if (std.mem.eql(u8, s.key, "rail_settings")) {
                // The rail variant owns the redesigned `settings` binary's
                // window: focus that one, launch the sibling build, and
                // degrade to the classic binary when only it is installed.
                if (self.focusExisting(kRailSettingsAppId)) return;
                if (self.launchSibling("settings")) return;
                logz.log("activate: no sibling settings, falling back", .{});
                if (self.launchSibling("horizon-settings")) return;
                logz.log("activate: no sibling horizon-settings either", .{});
            } else {
                if (self.focusExisting(kSettingsAppId)) return;
                if (self.launchSibling("horizon-settings")) return;
                logz.log("activate: no sibling horizon-settings, falling back to PATH", .{});
            }
        }
        // The Audio Center is a shell component in exactly that mould: a live
        // window gets focused (pavucontrol lets you open many, but one mixer
        // per screen is what the dot promises), and the copy next to this
        // dock is the one launched.
        if (s.kind == .audio_center) {
            if (self.focusExisting(kAudioCenterAppId)) return;
            if (self.launchSibling("horizon-audio-center")) return;
            logz.log("activate: no sibling horizon-audio-center, falling back to PATH", .{});
        }
        const target = dw.launchTarget(s) orelse {
            logz.log("activate: no launch target for {s} '{s}'", .{ @tagName(s.kind), s.key });
            return;
        };
        // A window that is already open gets focused, never relaunched — the
        // `dock_toplevel_by_serial` + `zwlr_foreign_toplevel_handle_v1_activate`
        // branch at the end of slot dispatch. Launching anyway is
        // what turns a click on a running app into a second copy of it.
        if (self.focusExisting(target)) return;
        self.launchSlot(target);
    }

    /// The half of `activate` that actually starts a process. Split out so
    /// "New Window" can ask for a second copy on purpose, which is the one
    /// case where focusing the existing one would be wrong.
    fn launchSlot(self: *Dock, target: []const u8) void {
        logz.log("activate: launch '{s}'", .{target});
        const gpa = self.app.gpa;
        const dirs = app_launch.applicationsDirs(
            gpa,
            getenvStr("XDG_DATA_HOME"),
            getenvStr("HOME"),
            getenvStr("XDG_DATA_DIRS"),
        ) catch return;
        defer app_launch.freeDirs(gpa, dirs);
        if (app_launch.launch(gpa, self.app.io, dirs, target)) {
            logz.log("activate: spawned '{s}'", .{target});
        } else {
            logz.err("activate: failed to launch '{s}'", .{target});
        }
    }

    /// Spawn `name` from the directory the running binary lives in. This is
    /// how the shell opens its *own* components — a desktop entry would
    /// resolve `horizon-settings` to a system-installed build instead.
    fn launchSibling(self: *Dock, name: []const u8) bool {
        const gpa = self.app.gpa;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.readLinkAbsolute(self.app.io, "/proc/self/exe", &buf) catch return false;
        const dir = std.fs.path.dirname(buf[0..n]) orelse return false;
        const exe = std.fs.path.join(gpa, &.{ dir, name }) catch return false;
        defer gpa.free(exe);
        if (!app_launch.launchPath(self.app.io, exe)) return false;
        logz.log("activate: spawned '{s}'", .{exe});
        return true;
    }

    /// Focus the window an app already has open instead of starting a second
    /// copy of it. Returns false when nothing matches, which is exactly when
    /// the caller should fall through to launching.
    fn focusExisting(self: *Dock, target: []const u8) bool {
        for (self.ft.list()) |*tl| {
            if (tl.closed or tl.handle == null) continue;
            if (!paths.sameAppId(target, tl.app_id)) continue;
            if (!self.ft.raiseToplevel(tl, self.app.bound.seat)) break;
            logz.log("activate: focused '{s}' (window app_id='{s}')", .{ target, tl.app_id });
            // The request has to leave the client buffer or nothing happens,
            // so flush right after the activate request.
            if (!self.app.conn.flush()) logz.log("activate: flush failed after focus", .{});
            return true;
        }
        return false;
    }

    // -----------------------------------------------------------------
    // Right-click menu
    // -----------------------------------------------------------------

    /// Rows are laid out at the same scale the dock's glyphs are, so a 2x
    /// dock does not get a 1x menu.
    fn menuScale(self: *Dock) f64 {
        // The right-click menu scales with the output the same way the strip
        // does: the config's UI scale times the output's fit factor, so a
        // 720p output gets a half-size menu instead of a 1440-sized one.
        return dw.uiScale(&self.app.loaded.cfg) * self.fit;
    }

    fn onPopupSurface(self: *Dock) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        if (seat.focus_surface == null) return false;
        if (self.popup.surface.wl_surface) |ps| {
            if (seat.focus_surface == ps) return true;
        }
        if (self.cc.surface.wl_surface) |cs| {
            if (seat.focus_surface == cs) return true;
        }
        return false;
    }

    fn onCcSurface(self: *Dock) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const cs = self.cc.surface.wl_surface orelse return false;
        return seat.focus_surface != null and seat.focus_surface == cs;
    }

    fn onPearSurface(self: *Dock) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const ps = self.pear.surface.wl_surface orelse return false;
        return seat.focus_surface != null and seat.focus_surface == ps;
    }

    /// A press inside the pear popup. Slider drags start here; everything
    /// else applies immediately and repaints.
    fn pearClick(self: *Dock) void {
        const seat = self.app.bound.seat_obj orelse return;
        const a = self.pear.press(seat.pointer_x, seat.pointer_y);
        self.runPearAction(a);
    }

    /// The `dock_handle_slot_press` right-button branch: build the menu for
    /// the slot under the pointer and put it on screen.
    fn showMenu(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        const s = self.strip.slots[idx];
        self.popup.reset();
        const built = switch (s.kind) {
            .app, .settings, .audio_center => blk: {
                self.buildAppMenu(s) catch |e| {
                    logz.err("menu: app build failed: {s}", .{@errorName(e)});
                    break :blk false;
                };
                break :blk true;
            },
            .tray => blk: {
                self.buildTrayMenu(s) catch |e| {
                    logz.err("menu: tray build failed: {s}", .{@errorName(e)});
                    break :blk false;
                };
                break :blk true;
            },
            else => false,
        };
        if (!built or self.popup.items.items.len == 0) {
            self.popup.reset();
            return;
        }

        // The chrome `dock_popup_paint_context_menu` reads: one derived
        // palette for both menus, and the overlay-opacity scale keyed on
        // which menu it is — the tray menu and the dock's context menu have
        // separate knobs in the config.
        const cfg = &self.app.loaded.cfg;
        self.popup.card_colors = chrome_colors.of(cfg);
        self.popup.menu_alpha = overlay.scale(&cfg.appearance, switch (s.kind) {
            .tray => .tray_menu,
            else => .dock_menu,
        });

        const us = self.menuScale();
        const pos = lastPointer(self);
        const ok = self.popup.present(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            @intFromFloat(@round(pos[0])),
            @intFromFloat(@round(pos[1])),
            us,
        );
        if (!ok) {
            logz.log("menu: present failed kind={s} key='{s}'", .{ @tagName(s.kind), s.key });
            self.popup.reset();
            return;
        }
        logz.log(
            "menu: open kind={s} key='{s}' rows={d} at x={d} size {d}x{d}",
            .{
                @tagName(self.popup.kind),
                s.key,
                self.popup.items.items.len,
                self.popup.menu_x,
                self.popup.menu_w,
                self.popup.menu_h,
            },
        );
        if (!self.app.conn.flush()) logz.log("menu: flush failed", .{});
    }

    /// `popup_open_for_app`. The entry the slot resolves to decides the two
    /// things the fixed rows cannot answer: the `[Desktop Action ...]` groups
    /// that go above everything else (Steam's Store / Library / Big Picture
    /// rows are these), and whether `New Window` is a row at all.
    fn buildAppMenu(self: *Dock, s: dw.Slot) !void {
        const gpa = self.app.gpa;
        const target = dw.launchTarget(s) orelse return;
        const p = &self.popup;
        const alloc = p.arena.allocator();
        p.kind = .app;
        p.app_key = try alloc.dupe(u8, target);

        // The settings gear is a shell component, not a desktop entry:
        // skip the lookup for it, and with no entry there are no action
        // rows and no `New Window` either.
        const info: desktop_actions.Info = if (std.mem.eql(u8, target, kSettingsAppId) or
            std.mem.eql(u8, target, kRailSettingsAppId) or
            std.mem.eql(u8, target, kAudioCenterAppId))
            .{}
        else
            self.desktopInfoFor(alloc, target);
        p.app_actions = info.actions;
        p.app_exec = info.exec;
        for (info.actions, 0..) |a, i| {
            const label = if (a.name.len > 0) a.name else a.id;
            try p.push(
                label,
                popup_mod.desktop_action_first + @as(i32, @intCast(i)),
                a.exec.len > 0,
            );
        }
        if (info.actions.len > 0) try p.pushSeparator();

        var handles: std.ArrayList(?*wl.zwlr_foreign_toplevel_handle_v1) = .empty;
        defer handles.deinit(gpa);
        for (self.ft.list()) |*tl| {
            const h = tl.handle orelse continue;
            if (tl.closed) continue;
            if (!paths.sameAppId(target, tl.app_id)) continue;
            try handles.append(gpa, h);
        }
        p.windows = try alloc.dupe(?*wl.zwlr_foreign_toplevel_handle_v1, handles.items);
        p.chosen = if (handles.items.len > 0) handles.items[0] else null;

        // `popupAppPinEnabled` — the settings gear is not something the user
        // pins, and neither is a slot with no id at all.
        const pin_ok = !std.mem.eql(u8, target, "unknown") and
            !std.mem.eql(u8, target, kSettingsAppId) and
            !std.mem.eql(u8, target, kRailSettingsAppId) and
            !std.mem.eql(u8, target, kAudioCenterAppId);
        const pinned = self.isPinned(target);
        try p.pushAction(if (pinned) "Unpin" else "Pin", .pin_toggle, pin_ok);
        try p.pushSeparator();

        if (p.chosen != null) {
            try p.pushAction("Minimize window", .minimize_one, true);
            try p.pushAction("Toggle maximize", .toggle_maximize, true);
            try p.pushAction("Toggle fullscreen", .toggle_fullscreen, true);
            try p.pushSeparator();
        }

        for (handles.items, 0..) |h, i| {
            const tl = if (h) |hh| self.ft.find(hh) else null;
            const title = if (tl) |t| t.title else "";
            try p.push(
                if (title.len == 0) "(untitled)" else title,
                popup_mod.window_first + @as(i32, @intCast(i)),
                true,
            );
        }
        if (handles.items.len > 0) try p.pushSeparator();

        // `popupAppDesktopExec` gates the row: with no entry there is no
        // second copy to ask for, which is what the settings gear and an id
        // like `steam_app_1234` both amount to.
        if (p.app_exec.len > 0) {
            try p.push("New Window", popup_mod.new_window, true);
            try p.pushSeparator();
        }
        try p.pushAction("Close window", .close_one, p.chosen != null);
        try p.pushAction("Close all windows", .close_all, handles.items.len > 0);
    }

    /// `find_desktop_file_for_appid` + `read_desktop_entry_info`, narrowed to
    /// the menu: the entry's `Exec` and its `[Desktop Action ...]` groups.
    /// Everything lands in `alloc`, the popup arena, so the record dies with
    /// the menu it built — the `free` calls inside are arena no-ops.
    fn desktopInfoFor(self: *Dock, alloc: std.mem.Allocator, target: []const u8) desktop_actions.Info {
        const gpa = self.app.gpa;
        const dirs = app_launch.applicationsDirs(
            gpa,
            getenvStr("XDG_DATA_HOME"),
            getenvStr("HOME"),
            getenvStr("XDG_DATA_DIRS"),
        ) catch return .{};
        defer app_launch.freeDirs(gpa, dirs);
        return desktop_actions.forAppId(alloc, self.app.io, dirs, target);
    }

    /// `popup_open_for_tray`: read the item's `com.canonical.dbusmenu`. A
    /// failure here is not an error — the item's own `ContextMenu` is the
    /// spec's answer to having no menu, and `buildTrayMenu` already fired it.
    fn buildTrayMenu(self: *Dock, s: dw.Slot) !void {
        const p = &self.popup;
        const gpa = self.app.gpa;
        const alloc = p.arena.allocator();
        const it = self.tray.itemForKey(s.key) orelse return;
        const pos = lastPointer(self);
        const px: i32 = @intFromFloat(@round(pos[0]));
        const py: i32 = @intFromFloat(@round(pos[1]));

        const menu_path = tray_menu.menuPath(gpa, &self.tray.conn, it.service, it.path) orelse {
            logz.log("tray menu: '{s}' has no DBusMenu; asking the item to open one", .{s.key});
            tray_menu.contextMenuFallback(&self.tray.conn, it.service, it.path, px, py);
            return;
        };
        defer gpa.free(menu_path);

        const entries = tray_menu.fetchTopLevel(alloc, &self.tray.conn, it.service, menu_path);
        if (entries.len == 0) {
            // Steam's DBusMenu is the usual reason: it only answers after a
            // stall long enough that `GetLayout` came back empty.
            logz.log("tray menu: '{s}' DBusMenu empty; asking the item instead", .{s.key});
            tray_menu.contextMenuFallback(&self.tray.conn, it.service, it.path, px, py);
            return;
        }
        p.kind = .tray;
        p.service = try alloc.dupe(u8, it.service);
        p.item_path = try alloc.dupe(u8, it.path);
        p.menu_path = try alloc.dupe(u8, menu_path);
        for (entries) |e| try p.pushBorrowed(e.label, e.id, e.enabled);
    }

    fn closeMenu(self: *Dock) void {
        if (self.popup.kind == .launcher) {
            // The model outlives the surface, so it has to be told: a query
            // typed into a launcher that the compositor closed underneath it
            // is not what the next one should open with.
            self.launcher.reset();
        }
        if (self.popup.kind == .world_clock) {
            if (self.wc_init) self.wc.closePopup();
            // The slot's open-state wash is a strip pixel: it goes with the
            // popup, whatever brought the close.
            self.repaint();
        }
        if (!self.popup.open and self.popup.items.items.len == 0) {
            self.closeCc();
            self.closePear();
            return;
        }
        self.popup.reset();
        self.closeCc();
        self.closePear();
        if (!self.app.conn.flush()) logz.log("menu: flush failed on close", .{});
    }

    /// Turn one of the launcher model's decisions into dock work. The model
    /// decides; this only owns the things it cannot reach — the surface, the
    /// launch, and the power commands.
    fn applyLauncher(self: *Dock, d: launcher_menu.Decision) void {
        switch (d.op) {
            .none => {},
            .close => self.closeMenu(),
            .launch => {
                // Read the entry before closing: `closeMenu` clears the query,
                // and the hit list that follows from it.
                if (self.launcher.hitEntry(d.hit)) |e| {
                    logz.log("launcher: launching '{s}' id='{s}'", .{ e.name, e.id });
                    if (!app_launch.launchExec(self.app.gpa, self.app.io, e.exec)) {
                        logz.err("launcher: could not start '{s}'", .{e.name});
                    }
                }
                self.closeMenu();
            },
            .run_power => {
                self.closeMenu();
                launcher_menu.Menu.runPower(self.app.io, d.hit);
            },
            .toggle_night => {
                // The drawer and the pear tile write the same key; the
                // supervisor's gamma client is what puts it on the display.
                const gpa = self.app.gpa;
                const on = !self.app.loaded.cfg.night_light.enabled;
                const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                defer if (st.len > 0) gpa.free(st);
                if (st.len > 0 and pear_prefs.setNightLight(gpa, self.app.io, st, on)) {
                    if (!self.app.reload()) logz.log("launcher: nightlight saved, reload deferred", .{});
                } else logz.log("launcher: nightlight write failed", .{});
                self.launcher.setNight(self.app.loaded.cfg.night_light.enabled);
                self.popupRefresh();
            },
            .ctx_pin => {
                // The menu is already gone from the model; the strip is what
                // changes underneath it.
                if (self.launcher.hitEntry(d.hit)) |e| {
                    self.togglePinKey(e.id);
                }
                self.popupRefresh();
            },
            // The App menu's rail is reachable now (the `app_menu` widget),
            // so the rail's own decisions must be real here too — the same
            // contract as the taskbar's page.
            .launch_keep => {
                if (self.launcher.hitEntry(d.hit)) |e| {
                    if (!app_launch.launchExec(self.app.gpa, self.app.io, e.exec)) {
                        logz.err("launcher: could not start '{s}'", .{e.name});
                    }
                }
                self.popupRefresh();
            },
            .reload_shell => {
                // The settings app's own "config changed" path. The dock
                // keeps an open popup across a reload (`onReload` refreshes
                // rather than closing it), so the note stays readable where
                // it was written.
                if (!self.app.reload()) logz.log("launcher: reload deferred", .{});
                self.launcher.note("Shell reloaded");
                self.popupRefresh();
            },
            .toggle_theme => {
                // The pear tile's own switch, through the same helper:
                // `matugen_mode` flips and the reload hands the new palette
                // to every surface. The panel takes the new chrome colours
                // rather than being rebuilt.
                const dark = !std.ascii.eqlIgnoreCase(self.app.loaded.cfg.appearance.matugen_mode, "dark");
                const gpa = self.app.gpa;
                const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                defer if (st.len > 0) gpa.free(st);
                if (st.len > 0 and pear_prefs.setThemeMode(gpa, self.app.io, st, dark)) {
                    if (!self.app.reload()) logz.log("launcher: theme saved, reload deferred", .{});
                    self.launcher.note(if (dark) "Dark theme" else "Light theme");
                } else logz.log("launcher: theme write failed", .{});
                self.popupRefresh();
            },
            // `.repaint`, `.focus_field` and `.ask_power` all leave the panel
            // up with different pixels under the same surface.
            .repaint, .focus_field, .ask_power => self.popupRefresh(),
        }
    }

    /// A press inside the control-center popup. Slider drags start here;
    /// everything else applies immediately and repaints.
    fn ccClick(self: *Dock) void {
        const seat = self.app.bound.seat_obj orelse return;
        const a = self.cc.press(seat.pointer_x, seat.pointer_y);
        self.runCcAction(a);
    }

    /// Repaint just the menu. Pointer motion can outrun it badly, so callers
    /// ask `hoverAt` first and only come here when something changed.
    fn popupRefresh(self: *Dock) void {
        self.popup.refresh();
        if (!self.app.conn.flush()) return;
    }

    fn runAppMenuAction(self: *Dock, id: i32) void {
        const p = &self.popup;
        if (id == popup_mod.new_window) {
            if (p.app_key.len > 0) self.launchSlot(p.app_key);
            return;
        }
        if (popup_mod.windowIndex(id)) |i| {
            const h = if (i < p.windows.len) p.windows[i] else null;
            const tl = if (h) |hh| self.ft.find(hh) else null;
            if (tl) |t| {
                if (self.ft.raiseToplevel(t, self.app.bound.seat)) {
                    logz.log("menu: focused window app_id='{s}'", .{t.app_id});
                }
                if (!self.app.conn.flush()) logz.log("menu: flush failed after focus", .{});
            }
            return;
        }
        // The `[Desktop Action ...]` band: row `desktop_action_first + i` runs
        // `app_actions[i].exec`, the same way the `1000 + i` branch
        // hands the exec to `launch_exec_command`.
        if (popup_mod.isDesktopActionId(id)) {
            const i: usize = @intCast(id - popup_mod.desktop_action_first);
            if (i >= p.app_actions.len) return;
            const act = p.app_actions[i];
            if (act.exec.len == 0) return;
            logz.log("menu: desktop action '{s}' → {s}", .{ act.id, act.exec });
            if (!app_launch.launchExec(self.app.gpa, self.app.io, act.exec)) {
                logz.err("menu: desktop action '{s}' did not launch", .{act.id});
            }
            return;
        }
        const a = popup_mod.actionFromId(id) orelse return;
        switch (a) {
            .pin_toggle => self.togglePin(),
            .close_one => {
                const h = p.chosen orelse return;
                wl.zwlr_foreign_toplevel_handle_v1_close(h);
                self.flushOrLog("menu: close");
            },
            .close_all => {
                var n: usize = 0;
                for (p.windows) |h| {
                    if (h == null) continue;
                    wl.zwlr_foreign_toplevel_handle_v1_close(h.?);
                    n += 1;
                }
                logz.log("menu: close all ({d} window(s))", .{n});
                self.flushOrLog("menu: close all");
            },
            .minimize_one => {
                const h = p.chosen orelse return;
                wl.zwlr_foreign_toplevel_handle_v1_set_minimized(h);
                self.flushOrLog("menu: minimize");
            },
            .minimize_all => {},
            .toggle_maximize => {
                const tl = self.chosenToplevel() orelse return;
                if (tl.maximized) {
                    wl.zwlr_foreign_toplevel_handle_v1_unset_maximized(tl.handle.?);
                } else {
                    wl.zwlr_foreign_toplevel_handle_v1_set_maximized(tl.handle.?);
                }
                self.flushOrLog("menu: maximize");
            },
            .toggle_fullscreen => {
                const tl = self.chosenToplevel() orelse return;
                if (tl.fullscreen) {
                    wl.zwlr_foreign_toplevel_handle_v1_unset_fullscreen(tl.handle.?);
                } else {
                    // The protocol wants an output here; `null` leaves
                    // the choice to the compositor.
                    wl.zwlr_foreign_toplevel_handle_v1_set_fullscreen(tl.handle.?, null);
                }
                self.flushOrLog("menu: fullscreen");
            },
        }
    }

    fn chosenToplevel(self: *Dock) ?*ftl.Toplevel {
        const h = self.popup.chosen orelse return null;
        return self.ft.find(h);
    }

    fn flushOrLog(self: *Dock, what: []const u8) void {
        if (!self.app.conn.flush()) logz.log("{s}: flush failed", .{what});
    }

    fn runMenuAction(self: *Dock, id: i32) void {
        const p = &self.popup;
        switch (p.kind) {
            .tray => {
                if (id < 0) return;
                logz.log("tray menu: '{s}' event id={d}", .{ p.service, id });
                tray_menu.activate(&self.tray.conn, p.service, p.menu_path, id);
                self.flushOrLog("tray menu");
            },
            .app => self.runAppMenuAction(id),
            else => {},
        }
    }

    /// A click on a menu row, or on the calendar card. Runs before the popup
    /// is torn down, because every action reads state the teardown frees.
    /// `btn` is the button that pressed, in the same numbering the dock's own
    /// slots use; a press the shell does not dispatch reaches this as null.
    fn popupClick(self: *Dock, btn: ?u8) void {
        const seat = self.app.bound.seat_obj orelse return;
        if (self.popup.kind == .launcher) {
            // The launcher's surface *is* the card, so surface coordinates
            // and the seat's pointer position are the same numbers.
            const x = seat.pointer_x;
            const y = seat.pointer_y;
            const button = btn orelse return;
            // The model does not read the dock's config, so whether the row a
            // right press is about is already pinned is answered here, where
            // both are to hand.
            var pinned = false;
            if (button == 3) {
                if (self.launcher.indexAt(x, y)) |row| {
                    if (self.launcher.hitEntry(row)) |e| pinned = self.isPinned(e.id);
                }
            }
            self.applyLauncher(self.launcher.click(x, y, .{ .btn = button, .pinned = pinned }));
            return;
        }
        if (self.popup.kind == .calendar) {
            const x: i32 = @intFromFloat(@round(seat.pointer_x));
            const y: i32 = @intFromFloat(@round(seat.pointer_y));
            const what = self.popup.cardClick(x, y);
            switch (what) {
                .prev_month, .next_month => {
                    self.popup.stepMonth(if (what == .prev_month) -1 else 1);
                    self.popupRefresh();
                    return;
                },
                else => {},
            }
            self.closeMenu();
            return;
        }
        if (self.popup.kind == .media_player) {
            if (self.runMediaPopupClick()) {
                // A transport call is synchronous on the bus, so reading the
                // player straight back is the cheapest way to show that it
                // heard us instead of waiting out the next 400 ms slot.
                const changed = self.pollMedia();
                if (changed) self.relayoutStrip();
                self.syncMediaPopup();
                self.popupRefresh();
                if (changed) self.repaint();
            } else {
                self.closeMenu();
            }
            return;
        }
        if (self.popup.kind == .bluetooth) {
            if (self.runBluetoothPopupClick()) {
                // The verbs are D-Bus: power, discovery and forget answer in
                // the call, connect and pair only queue with BlueZ — so
                // reading the backend straight back shows the first kind at
                // once and costs nothing but a call when the second has
                // nothing new yet. A list that changed can also have changed
                // the pill's label, which is the relayout media does too.
                const changed = self.installBtQuery(cc_live_bluetooth.query(self.app.gpa));
                if (changed) self.relayoutStrip();
                if (!self.settleWidgetCard()) self.popupRefresh();
                if (changed) self.repaint();
            } else {
                self.closeMenu();
            }
            return;
        }
        if (self.popup.kind == .vpn) {
            if (self.runVpnPopupClick()) {
                // The store already carries the optimistic answer the click
                // wrote into it; the list that confirms it is on its way from
                // the worker, and this is only the redraw of what we know.
                self.popupRefresh();
            } else {
                self.closeMenu();
            }
            return;
        }
        if (self.popup.kind == .layout) {
            if (self.runLayoutPopupClick()) {
                // The swap already went out from inside the widget's hit test.
                // Both surfaces need redrawing, because the *strip's* glyph
                // reads `layout_current` too and would otherwise keep showing
                // the layout the user just left.
                self.popupRefresh();
                self.repaint();
            } else {
                self.closeMenu();
            }
            return;
        }
        if (self.popup.kind == .volume_mixer) {
            // The write goes out under the pointer and the card redraws on
            // it; what the backend answers comes back through the worker,
            // inside the window the write just bought itself.
            if (self.runVolumeMixerPopupClick()) {
                self.popupRefresh();
            } else {
                self.closeMenu();
            }
            return;
        }
        const us = self.menuScale();
        const hit = self.popup.rowAt(@intFromFloat(@round(seat.pointer_x)), @intFromFloat(@round(seat.pointer_y)), us);
        const idx = hit orelse {
            self.closeMenu();
            return;
        };
        const row = self.popup.items.items[idx];
        defer self.closeMenu();
        if (popup_mod.isSeparator(row) or !row.enabled) return;
        self.runMenuAction(row.id);
    }

    /// The clock slot's calendar, centred on the slot and taking over the
    /// popup surface the right-click menu would otherwise be using.
    fn showCalendar(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        const cx = self.slotCentreX(idx) orelse return;
        self.popup.reset();
        const ok = self.popup.openCalendar(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            cx,
            local_time.today(),
            chrome_colors.of(&self.app.loaded.cfg),
            // Appearance → Opacity "Calendar" is the whole knob for this
            // card: an advanced-mode slider is the single authority for its
            // surface, so 0% leaves nothing and 100% is fully opaque.
            overlay.scale(&self.app.loaded.cfg.appearance, .calendar),
            self.fit,
        );
        if (!ok) {
            logz.log("calendar: present failed slot={d}", .{idx});
            self.popup.reset();
            return;
        }
        logz.log("calendar: open slot={d} at x={d} fit={d:.2} surf={d}x{d}", .{ idx, self.popup.card_cx, self.fit, self.popup.buf_w, self.popup.buf_h });
        if (!self.app.conn.flush()) logz.log("calendar: flush failed", .{});
    }

    /// The weather slot's card. Same surface, same dismiss rules; only the
    /// content and its height differ.
    fn showWeather(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        const cx = self.slotCentreX(idx) orelse return;
        self.popup.reset();
        const ok = self.popup.openWeather(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            cx,
            chrome_colors.of(&self.app.loaded.cfg),
            // Same as the calendar: the weather knob alone, and its 100% is
            // a fully opaque card.
            overlay.scale(&self.app.loaded.cfg.appearance, .weather),
            self.fit,
        );
        if (!ok) {
            logz.log("weather card: present failed slot={d}", .{idx});
            self.popup.reset();
            return;
        }
        logz.log("weather card: open slot={d} at x={d} fit={d:.2} surf={d}x{d}", .{ idx, self.popup.card_cx, self.fit, self.popup.buf_w, self.popup.buf_h });
        if (!self.app.conn.flush()) logz.log("weather card: flush failed", .{});
    }

    // ---- world clock -------------------------------------------------

    /// Wall-clock milliseconds. The dock's own `nowMs` is monotonic — uptime,
    /// not time — and everything around this widget (its header date, the row
    /// times, the 5 s rotation) is real time, so every path here goes through
    /// this rather than `nowMs`.
    fn epochMs() u64 {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        if (linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
        return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 + @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
    }

    /// The face's spec scale off the dock's icon box (38 px is 1.0).
    fn wcUiScale(self: *Dock) f64 {
        return wc_face.scaleOf(@floatFromInt(self.icon_px));
    }

    /// Logical output height minus the spec's 120 px — the same clamp the
    /// taskbar applies, so both bars open the same panel height.
    fn wcMaxHeight(self: *Dock) f64 {
        var h: i32 = 0;
        if (self.output_entry) |o| {
            h = if (o.have_logical and o.logical_h > 0) o.logical_h else @divTrunc(o.height, @max(1, o.scale));
        }
        if (h <= 0) h = 1440;
        return @as(f64, @floatFromInt(h)) - 120.0;
    }

    /// The world-clock panel (the spec's popup): the widget's own card on the
    /// dock's shared popup surface, centred on its slot and holding the
    /// keyboard while it is up (the search field). The session carries the
    /// state; this side only measures, places and routes.
    fn showWorldClock(self: *Dock, idx: usize) void {
        if (!self.wc_init or idx >= self.strip.slots.len) return;
        self.wc.openPopup(Dock.epochMs());
        self.presentWorldClock(idx);
        // The slot's open-state wash is a strip pixel: the click that opened
        // the panel has to draw it.
        self.repaint();
    }

    /// The widget slot box's top edge in surface coordinates — the line the
    /// world-clock card's 16px standoff is measured from.
    fn slotTopY(self: *Dock) i32 {
        const p = self.pill();
        const icon: f64 = @floatFromInt(self.icon_px);
        return @intFromFloat(@round(p.y + (p.box_h - icon) * 0.5));
    }

    /// Place (or re-place) the panel without touching the session — the
    /// settle path re-opens it on a changed height, and the user's add pane
    /// and search text have to survive that.
    fn presentWorldClock(self: *Dock, idx: usize) void {
        if (!self.wc_init or idx >= self.strip.slots.len) return;
        const cx = self.slotCentreX(idx) orelse return;
        const us = self.wcUiScale();
        self.popup.reset();
        // The punched-in config, same as the other widget cards: the panel
        // reads its Appearance → Opacity plate alpha off it at paint time,
        // so the settings slider moves a panel that is already up.
        self.popup.widget_cfg = &self.app.loaded.cfg;
        // The card is clamped to the *output*, not to the dock surface: a
        // widget near the dock's own end must still get its card centred
        // above it, hanging over the wallpaper beside the dock the way the
        // control center always has. `slot_cx` is dock-local, so the dock's
        // origin on the output comes along for the ride.
        const dock_w: i32 = @intCast(self.surface.configured_width);
        const out_w: i32 = @intFromFloat(@round(self.outputLogicalW()));
        const origin_x = cc_position.layerOriginX(out_w, dock_w);
        const ok = self.popup.openWorldClock(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            dock_w,
            @intCast(self.surface.configured_height),
            cx,
            self.slotTopY(),
            out_w,
            origin_x,
            &self.wc,
            us,
            self.wcMaxHeight() / us,
            chrome_colors.of(&self.app.loaded.cfg),
            self.fit,
        );
        if (!ok) {
            self.wc.closePopup();
            logz.log("world-clock: present failed slot={d}", .{idx});
            self.popup.reset();
            return;
        }
        self.wc_slot = idx;
        logz.log("world-clock: open slot={d} at x={d} fit={d:.2} surf={d}x{d}", .{ idx, self.popup.card_cx, self.fit, self.popup.buf_w, self.popup.buf_h });
        if (!self.app.conn.flush()) logz.log("world-clock: flush failed", .{});
    }

    /// Surface pixels back to the panel's own padded coordinates. The card is
    /// drawn inside `translate(card_cx) · scale(fit) · scale(us)`, so the
    /// inverse divides by both scales.
    fn wcNatural(self: *Dock, x: f64, y: f64) struct { x: f64, y: f64 } {
        const us = self.popup.wc_us;
        const cw = (self.popup.wc_geom.w + wc_panel.k_shadow_pad * 2.0) * us;
        const left = @as(f64, @floatFromInt(self.popup.card_cx)) - cw * self.fit * 0.5;
        const d = self.fit * us;
        return .{ .x = (x - left) / d, .y = y / d };
    }

    fn wcPress(self: *Dock, x: f64, y: f64) wc_panel.Outcome {
        const p = self.wcNatural(x, y);
        const g = &self.popup.wc_geom;
        const pad = wc_panel.k_shadow_pad;
        if (p.x < pad or p.y < pad or p.x > pad + g.w or p.y > pad + g.total_h) {
            // The margin is surface, not card: a press there counts as
            // outside the popup and closes it.
            return .{ .handled = true, .close = true };
        }
        return wc_panel.press(&self.wc, g, p.x, p.y, Dock.epochMs());
    }

    fn wcMotion(self: *Dock, x: f64, y: f64) wc_panel.Outcome {
        const p = self.wcNatural(x, y);
        return wc_panel.motion(&self.wc, &self.popup.wc_geom, p.x, p.y, Dock.epochMs());
    }

    /// Apply a panel outcome: save, re-measure, refresh the face and/or the
    /// popup, or close. The taskbar's version in dock terms — the strip
    /// re-runs its width pass instead of rebuilding its whole model.
    fn applyWcOutcome(self: *Dock, out: wc_panel.Outcome) void {
        if (out.close) {
            self.closeMenu();
            return;
        }
        if (out.saved) self.wc.save();
        if (out.relayout) self.wcSettle();
        if (out.face) self.relayoutStrip();
        if (self.popup.kind == .world_clock and (out.repaint or out.face)) self.popupRefresh();
    }

    /// The card geometry the session as it stands now wants: the panel's
    /// natural size, never wider than the screen it opens on.
    fn wcGeomNow(self: *Dock) wc_panel.Geom {
        const us = self.popup.wc_us;
        var g = wc_panel.compute(&self.wc, self.wcMaxHeight() / us);
        g.w = @max(200.0, @min(g.w, @as(f64, @floatFromInt(self.popup.buf_w)) / us - 32.0));
        return g;
    }

    /// The panel's height follows its content (rows, the add pane, the search
    /// results), so a change lands as a new surface on the new height with the
    /// session state kept — the discipline the bluetooth and vpn cards use.
    fn wcSettle(self: *Dock) void {
        if (self.popup.kind != .world_clock or self.wc_slot == no_slot) return;
        const g = self.wcGeomNow();
        if (@abs(g.total_h - self.popup.wc_geom.total_h) <= 0.5 and @abs(g.w - self.popup.wc_geom.w) <= 0.5) {
            self.popup.wc_geom = g;
            return;
        }
        self.presentWorldClock(self.wc_slot);
    }

    /// The card is up and something *else* rewrote the session (Settings >
    /// Time): present it again whatever the height does. `wcSettle` skips the
    /// present when the grid happens to be the same size, which would leave
    /// the old rows in the attached buffer.
    fn wcResettle(self: *Dock) void {
        if (self.popup.kind != .world_clock or self.wc_slot == no_slot) return;
        self.popup.wc_geom = self.wcGeomNow();
        self.presentWorldClock(self.wc_slot);
    }

    /// The widget's own second: the face rotates every 5 s and slides, and
    /// while the panel is up its clocks advance (the seconds switch included).
    /// Returns true when the strip has to be re-measured — the sliding city
    /// name and the 12-hour suffix both change the face's width.
    fn tickWorldClock(self: *Dock) bool {
        if (!self.wc_init) return false;
        var any_world = false;
        for (self.strip.slots) |s| {
            if (s.kind == .world_clock) any_world = true;
        }
        if (!any_world) return false;
        const now = Dock.epochMs();
        const tr = self.wc.tick(now);
        if (tr.second and self.popup.kind == .world_clock) self.popupRefresh();
        if (self.wc.slide.active) self.armAnim();
        return tr.face or tr.minute;
    }

    /// The start menu. Fixed size and centred on the output rather than on the
    /// slot, so its position does not depend on how many widgets are pinned;
    /// the surface then holds the keyboard while it is up. Pressing the slot
    /// again goes through the normal "a press closes an open popup" path, so
    /// one click toggles it.
    /// Bring up the launcher over the slot that asked for it.
    ///
    /// The panel is centred on the slot and then pushed back on screen, which
    /// is two separate ideas: a slot near the end of the dock would otherwise
    /// put half the panel off the display, and clamping the *slot* rather than
    /// the *panel* would slide it away from the thing that opened it. The
    /// arithmetic lives in `popup_position`; what is decided here is only what
    /// the arithmetic is told about.
    ///
    /// `style` picks which panel: `.rail` is the App menu (its own category
    /// rail), `.classic` the App drawer / start-menu card. The model keeps the
    /// last style, so every open pins it — the same contract as the taskbar's
    /// `showLauncher`.
    fn showLauncher(self: *Dock, slot: usize, style: launcher_menu.Style) void {
        self.popup.reset();
        self.launcher.setColors(chrome_colors.of(&self.app.loaded.cfg));
        // The panel reads these fresh on every open: which style the widget
        // asked for, the view mode from the launcher settings (classic only —
        // the rail is list-only, `setStyle` owns that bit), the nightlight
        // state so the footer toggle shows the side it is actually on (C++
        // re-read both too).
        self.launcher.setStyle(style);
        if (style == .classic) {
            self.launcher.setListMode(self.app.loaded.cfg.appearance.launchpad_view_mode == 1);
        }
        self.launcher.setNight(self.app.loaded.cfg.night_light.enabled);
        self.refreshLauncherIcons();
        self.launcher.open();

        const layer_w: f64 = @floatFromInt(@max(1, self.surface.configured_width));
        const centre: i32 = self.slotCentreX(slot) orelse @divTrunc(@as(i32, @intFromFloat(layer_w)), 2);
        const out_w = self.outputLogicalW();
        // Where the dock starts on that output. It has no left or right
        // anchor, so the compositor centres it — which means the one piece of
        // output geometry a client can derive rather than be told is this
        // offset. What it still cannot derive is *which* output it landed on;
        // see `positionOutput`.
        const origin: f64 = if (out_w > 0.0) @max(0.0, (out_w - layer_w) * 0.5) else 0.0;
        const entry = self.positionOutput();

        const placed = self.popup.openLauncher(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            if (entry) |e| e.obj else null,
            .{
                .anchor_x = @floatFromInt(centre),
                .layer_w = layer_w,
                .layer_origin_x = origin,
                .output_w = out_w,
                .dock_h = @intCast(self.surface.configured_height),
            },
            &self.launcher,
            // The drawer's own slider is the whole knob (the widget-card
            // family knob drives the cards that have no slider of their
            // own). The panel's backdrop is deliberately the thinnest glass
            // in the shell — blur does the colouring there.
            overlay.scale(&self.app.loaded.cfg.appearance, .app_drawer),
            // The output's fit factor: the panel shrinks with a short
            // output the same way the dock strip and cards do.
            self.fit,
        );
        const at = placed orelse {
            logz.log("launcher: present failed", .{});
            self.popup.reset();
            return;
        };
        logz.log(
            "launcher: open apps={d} hits={d} anchor={d} out={d:.0} origin={d:.0} margins=({d},{d})",
            .{
                self.launcher.total,
                self.launcher.hits.items.len,
                centre,
                out_w,
                origin,
                at.margin_left,
                at.margin_bottom,
            },
        );
        self.armAnim();
        if (!self.app.conn.flush()) logz.log("launcher: flush failed", .{});
    }

    /// Point the launcher's icon cache at the theme the dock is using. Checked
    /// on every open and rebuilt only when the theme or the environment
    /// actually differs from the last one — otherwise reopening the menu would
    /// re-decode every icon it had already decoded, which is the difference
    /// between the panel appearing and the panel *arriving*.
    fn refreshLauncherIcons(self: *Dock) void {
        const gpa = self.app.gpa;
        const cfg = &self.app.loaded.cfg;
        const theme: []const u8 = if (cfg.dock.icon_theme.len > 0) cfg.dock.icon_theme else "hicolor";
        const home = getenvStr("XDG_DATA_HOME");
        const dirs_env = getenvStr("XDG_DATA_DIRS");
        if (self.launcher_theme) |last| {
            if (std.mem.eql(u8, last, theme) and
                sameStr(self.launcher_home, home) and
                sameStr(self.launcher_dirs_env, dirs_env))
            {
                return;
            }
        }
        const dirs = icon_lookup.dataDirs(gpa, home, getenvStr("HOME"), dirs_env) catch return;
        // `setPath` takes ownership and drops whatever was cached behind the
        // path it is replacing.
        self.launcher.res.icons.setPath(dirs, theme);
        if (self.launcher_theme) |last| gpa.free(last);
        self.launcher_theme = gpa.dupe(u8, theme) catch null;
        self.launcher_home = home;
        self.launcher_dirs_env = dirs_env;
    }

    /// The control-center slot's panel: the full quick-settings popup
    /// (`controlcenter/host.zig`) with network + bluetooth tiles, output +
    /// input sliders, the volume mixer, media and weather. Closes any menu
    /// first — one popup surface at a time, always.
    fn showControlCenter(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        self.popup.reset();
        self.closePear();
        const now_ms: u64 = @intCast(@divTrunc(anim.monotonicNs(), std.time.ns_per_ms));
        // Fresh backends for every open (an AP that appeared a second ago
        // must be in the list), then the snapshot off the new cache.
        _ = self.pollCcLive(now_ms, true);
        const snap = self.buildCcSnapshot();
        // `control_center_popup_width_for`: 620 × ui-scale for legacy.
        const us = dw.uiScale(&self.app.loaded.cfg);
        const width: i32 = @max(200, @as(i32, @intFromFloat(@round(620.0 * us))));
        // Above the spawning slot (`dock_popup_compute_layer_margins` +
        // `compute_popup_position`): centered on the slot anchor, clamped to
        // the dock surface and the output — not screen-centered.
        const slot_cx = self.slotCentreX(idx) orelse @divTrunc(self.buf_w, 2);
        const dock_w = if (self.buf_w > 0) self.buf_w else self.req_w;
        const out_w: i32 = @intFromFloat(@round(self.outputLogicalW()));
        const origin_x = cc_position.layerOriginX(out_w, dock_w);
        const gap: i32 = @intFromFloat(@round(6.0 * us));
        const extra: i32 = @intFromFloat(@round(2.0 * us));
        // `openControlCenter` sizes the panel at `width × fit`, so the anchor
        // must centre *that* on the slot. Centring the natural `width` would
        // leave the panel `width × (1 − fit) / 2` to the left of its widget on
        // any output that is not 1440 tall (155px at fit 0.5) — which is why
        // the control center opened away from its slot on a short display.
        // The guard mirrors the host's own `fit > 0 else 1` on the size.
        const cc_fit: f64 = if (self.fit > 0.0) self.fit else 1.0;
        const popup_w: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(width)) * cc_fit))));
        const pos = cc_position.computeMargins(.{
            .anchor_x = slot_cx,
            .popup_w = popup_w,
            .popup_h = 0,
            .output_w = out_w,
            .layer_w = dock_w,
            .layer_origin_x = origin_x,
            .bottom_clearance = 0,
        });
        // Clearance above the dock plus +2 polish on
        // AppMenu/ControlCenter/Calendar/Weather kinds (`popup_extra_margin`).
        const margin_bottom = @max(0, self.req_h + gap) + extra;
        // Same output the dock bar lives on (`dock_popup_create_layer_surface`
        // uses the margin reference layer's output).
        const pos_out = self.positionOutput();
        const cc_output = if (pos_out) |e| e.obj else null;
        const ok = self.cc.openControlCenter(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            cc_output,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            width,
            pos.margin_left + extra,
            margin_bottom,
            self.fit,
            &self.app.loaded.cfg,
            snap,
            now_ms,
        );
        if (!ok) {
            logz.log("control-center: present failed slot={d}", .{idx});
            self.cc.reset();
            return;
        }
        logz.log("control-center: open slot={d} w={d} h={d} margin_left={d}", .{ idx, width, self.cc.layout.total_h, pos.margin_left });
        if (!self.app.conn.flush()) logz.log("control-center: flush failed", .{});
    }

    fn closeCc(self: *Dock) void {
        if (!self.cc.open) return;
        self.cc.reset();
        if (!self.app.conn.flush()) logz.log("control-center: flush failed on close", .{});
    }

    /// Snapshot the open windows for the overview: one card per workspace
    /// with its windows, padded to the widget's `max_workspaces`. Falls
    /// back to a single card from the toplevel tracker off Hyprland.
    /// `setCards` copies everything into its own arena, so every slice
    /// built here is freed before returning.
    fn hyprEnv(self: *Dock) std.process.Environ.Map {
        var env = std.process.Environ.Map.init(self.app.gpa);
        if (getenvStr("HYPRLAND_INSTANCE_SIGNATURE")) |v| env.put("HYPRLAND_INSTANCE_SIGNATURE", v) catch {};
        if (getenvStr("XDG_RUNTIME_DIR")) |v| env.put("XDG_RUNTIME_DIR", v) catch {};
        return env;
    }

    /// The widget's `max_workspaces` for the first workspaces slot on the
    /// strip, defaulting to 5 like the settings tab does.
    fn wsMaxSlots(self: *Dock) i32 {
        const cfg = &self.app.loaded.cfg;
        for (self.strip.slots) |sl| {
            if (sl.kind != .workspaces) continue;
            return ws_paint.maxSlotsFromSettings(cfg, sl.key);
        }
        return 5;
    }

    fn freeWsEntries(self: *Dock) void {
        if (self.ws_entries.len == 0) return;
        ws_paint.freeEntries(self.app.gpa, self.ws_entries);
        self.ws_entries = &.{};
    }

    /// Strip entries from the snapshot: ids, labels, state, and the client
    /// classes as app keys. The snapshot stays padded, so this converts.
    /// Every string is owned; a failed allocation drops the workspace
    /// instead of leaving anything static for the release path to free.
    fn rebuildWsEntries(self: *Dock) void {
        const gpa = self.app.gpa;
        self.freeWsEntries();
        const snap = self.ws_snap orelse return;
        var out: std.ArrayList(ws_paint.Entry) = .empty;
        errdefer {
            for (out.items) |*e| {
                gpa.free(e.label);
                for (e.app_keys) |k| gpa.free(k);
                gpa.free(e.app_keys);
            }
            out.deinit(gpa);
        }
        ws_loop: for (snap.ws) |w| {
            var keys: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (keys.items) |k| gpa.free(k);
                keys.deinit(gpa);
            }
            for (w.wins) |win| {
                const k = gpa.dupe(u8, win.app_id) catch {
                    for (keys.items) |kk| gpa.free(kk);
                    keys.deinit(gpa);
                    continue :ws_loop;
                };
                keys.append(gpa, k) catch {
                    gpa.free(k);
                    for (keys.items) |kk| gpa.free(kk);
                    keys.deinit(gpa);
                    continue :ws_loop;
                };
            }
            const owned_keys = keys.toOwnedSlice(gpa) catch continue :ws_loop;
            errdefer {
                for (owned_keys) |k| gpa.free(k);
                gpa.free(owned_keys);
            }
            const label = gpa.dupe(u8, w.label) catch {
                for (owned_keys) |k| gpa.free(k);
                gpa.free(owned_keys);
                continue :ws_loop;
            };
            out.append(gpa, .{
                .id = w.id,
                .label = label,
                .active = w.active,
                .occupied = w.occupied,
                .app_keys = owned_keys,
            }) catch {
                gpa.free(label);
                for (owned_keys) |k| gpa.free(k);
                gpa.free(owned_keys);
                continue :ws_loop;
            };
        }
        self.ws_entries = out.toOwnedSlice(gpa) catch &.{};
    }

    /// Refetch the Hyprland snapshot, throttled unless forced. Answers
    /// whether the entries changed.
    fn reloadWorkspaces(self: *Dock, force: bool) bool {
        const now: i64 = @intCast(Dock.nowMs());
        if (!force and self.ws_snap != null and now - self.ws_fetched_ms < 5000) return false;
        var env = self.hyprEnv();
        defer env.deinit();
        if (env.get("HYPRLAND_INSTANCE_SIGNATURE") == null) return false;
        const gpa = self.app.gpa;
        var snap = ov_ws.fetch(gpa, self.app.io, &env) orelse return false;
        errdefer snap.deinit();
        ov_ws.applyMaxSlots(gpa, &snap, self.wsMaxSlots()) catch {
            snap.deinit();
            return false;
        };
        if (self.ws_snap) |*old| old.deinit();
        self.ws_snap = snap;
        self.ws_fetched_ms = now;
        self.rebuildWsEntries();
        return true;
    }

    /// Fire-and-forget compositor command. Answers whether the reply starts
    /// with `ok`.
    fn hyprSend(self: *Dock, cmd: []const u8) bool {
        var env = self.hyprEnv();
        defer env.deinit();
        const reply = ov_ws.send(self.app.gpa, self.app.io, &env, cmd) orelse return false;
        defer self.app.gpa.free(reply);
        return ov_ws.repliedOk(reply);
    }

    /// Focus a workspace by id; Hyprland creates a missing one on demand.
    fn wsJump(self: *Dock, id: i32) void {
        var buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.focus({{workspace = {d}}})", .{id}) catch return;
        if (!self.hyprSend(cmd)) {
            const plain = std.fmt.bufPrint(&buf, "dispatch workspace {d}", .{id}) catch return;
            _ = self.hyprSend(plain);
        }
    }

    /// Cairo surface for a strip cell's app key. Borrowed for the
    /// paint only; the cache owns both bytes and surface.
    fn wsIconSurf(ctx: *anyopaque, key: []const u8) ?*cairo.cairo_surface_t {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        const e = self.ws_surfs.get(key) orelse return null;
        return e.surf;
    }

    fn clearWsSurfs(self: *Dock) void {
        if (!self.ws_surfs_init) return;
        var it = self.ws_surfs.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.surf) |sf| cairo.cairo_surface_destroy(sf);
            self.app.gpa.free(e.value_ptr.pixels);
            self.app.gpa.free(e.key_ptr.*);
        }
        self.ws_surfs.clearRetainingCapacity();
    }

    /// Rebuild the cell surfaces from the strip's resolved pixels. Runs at
    /// the end of icon resolution so the cells never point at freed art:
    /// every surface copies the bytes it shows.
    fn refreshWsIcons(self: *Dock) void {
        self.clearWsSurfs();
        if (self.ws_entries.len == 0) return;
        const gpa = self.app.gpa;
        var kept: usize = 0;
        for (self.ws_entries) |e| {
            for (e.app_keys) |key| {
                if (kept >= 40) return;
                if (self.ws_surfs.contains(key)) continue;
                for (self.strip.slots, 0..) |sl, i| {
                    if (sl.kind != .app or i >= self.icons.len) continue;
                    if (!paths.sameAppId(key, sl.key)) continue;
                    const px = self.icons[i];
                    if (px.pixels.len == 0 or px.w <= 0 or px.h <= 0) break;
                    const copy = gpa.dupe(u8, px.pixels) catch break;
                    errdefer gpa.free(copy);
                    const surf = cairo.cairo_image_surface_create_for_data(
                        copy.ptr,
                        cairo.CAIRO_FORMAT_ARGB32,
                        px.w,
                        px.h,
                        px.w * 4,
                    );
                    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
                        cairo.cairo_surface_destroy(surf);
                        gpa.free(copy);
                        break;
                    }
                    const owned_key = gpa.dupe(u8, key) catch {
                        cairo.cairo_surface_destroy(surf);
                        gpa.free(copy);
                        break;
                    };
                    self.ws_surfs.put(owned_key, .{ .pixels = copy, .surf = surf }) catch {
                        cairo.cairo_surface_destroy(surf);
                        gpa.free(copy);
                        gpa.free(owned_key);
                        break;
                    };
                    kept += 1;
                    break;
                }
            }
        }
    }

    /// Jump to a workspace id from the strip widget. The dock stays up;
    /// only the overview closes on a jump.
    fn focusWorkspace(self: *Dock, slot: usize, pointer_x: f64) void {
        if (slot >= self.strip.slots.len) return;
        const sl = self.strip.slots[slot];
        if (sl.kind != .workspaces) return;
        const box = self.slotBox(slot);
        const local_x = pointer_x - box[0];
        const idx = ws_paint.pickIndex(self.app.gpa, local_x, box[1], &self.app.loaded.cfg, sl.key, @floatFromInt(self.icon_px), self.ws_entries) catch -1;
        if (idx < 0 or idx >= self.ws_entries.len) return;
        var buf: [12]u8 = undefined;
        const target = ws_paint.activateTarget(&self.ws_entries[@intCast(idx)], &buf) orelse return;
        const id = std.fmt.parseInt(i32, target, 10) catch return;
        self.wsJump(id);
    }

    /// Toggle the standalone `horizon-overview` process. A live copy is
    /// signalled off (reaping it when it already exited); otherwise the
    /// sibling next to this binary is spawned and its pid remembered.
    fn showOverview(self: *Dock) void {
        if (self.ov_pid) |pid| {
            var status: u32 = 0;
            const rc: isize = @bitCast(linux.wait4(pid, @ptrCast(&status), linux.W.NOHANG, null));
            self.ov_pid = null;
            if (rc == 0) {
                // Still running: toggle it off.
                _ = linux.kill(pid, linux.SIG.TERM);
                return;
            }
            // Exited already (reaped, or gone): fall through and open fresh.
        }
        const gpa = self.app.gpa;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.readLinkAbsolute(self.app.io, "/proc/self/exe", &buf) catch return;
        const dir = std.fs.path.dirname(buf[0..n]) orelse return;
        const exe = std.fs.path.join(gpa, &.{ dir, "horizon-overview" }) catch return;
        defer gpa.free(exe);
        const argv = [_][]const u8{exe};
        const child = std.process.spawn(self.app.io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch {
            logz.log("overview: spawn failed", .{});
            return;
        };
        if (child.id) |pid| {
            self.ov_pid = pid;
            logz.log("overview: spawned pid={d}", .{pid});
        }
    }

    /// Apply one control-center action. Expansion toggles + drag visuals stay
    /// local and repaint; everything else writes through to the live backend
    /// (pactl/wpctl, nmcli, BlueZ, MPRIS) and the next poll reconciles. The
    /// sliders still move under the pointer either way — the suppress
    /// window stays up while a drag is in flight.
    fn runCcAction(self: *Dock, a: cc_host.Action) void {
        const gpa = self.app.gpa;
        const now_ms: u64 = @intCast(@divTrunc(anim.monotonicNs(), std.time.ns_per_ms));
        switch (a) {
            .none => {},
            .dismiss => self.closeCc(),
            .toggle_network_expanded => {
                self.cc.state.network_expanded = !self.cc.state.network_expanded;
                self.cc.state.net_anim_start_ms = now_ms;
                self.cc.state.net_anim_from_expanded = !self.cc.state.network_expanded;
                self.cc.state.net_anim_to_expanded = self.cc.state.network_expanded;
                if (self.cc.state.network_expanded) cc_live_network.rescanThread(self.app.io);
                self.ccResize(now_ms);
                self.ccRefresh();
                logz.log("control-center: network_expanded={s}", .{if (self.cc.state.network_expanded) "on" else "off"});
            },
            .toggle_bluetooth_expanded => {
                self.cc.state.bluetooth_expanded = !self.cc.state.bluetooth_expanded;
                self.cc.state.bt_anim_start_ms = now_ms;
                self.cc.state.bt_anim_from_expanded = !self.cc.state.bluetooth_expanded;
                self.cc.state.bt_anim_to_expanded = self.cc.state.bluetooth_expanded;
                if (self.cc_bt) |*q| {
                    cc_live_bluetooth.setDiscovery(gpa, q.snap.adapter_path, self.cc.state.bluetooth_expanded);
                }
                self.ccResize(now_ms);
                self.ccRefresh();
                logz.log("control-center: bluetooth_expanded={s}", .{if (self.cc.state.bluetooth_expanded) "on" else "off"});
            },
            .toggle_mixer_expanded => {
                self.cc.state.mixer_expanded = !self.cc.state.mixer_expanded;
                self.ccResize(now_ms);
                self.ccRefresh();
            },
            .toggle_output_devices => {
                self.cc.state.output_devices_expanded = !self.cc.state.output_devices_expanded;
                self.ccResize(now_ms);
                self.ccRefresh();
            },
            .toggle_input_devices => {
                self.cc.state.input_devices_expanded = !self.cc.state.input_devices_expanded;
                self.ccResize(now_ms);
                self.ccRefresh();
            },
            .set_output_volume => |t| {
                const pct: i32 = @intFromFloat(@round(t * 100.0));
                // Off-thread: this action fires on every pointer motion, and
                // a pactl/wpctl spawn here stalled the very drag it served.
                cc_apply.requestSink(now_ms, self.app.io, pct);
                self.cc.snap.out.volume_pct = pct;
                self.cc.snap.out.fill_t_override = t;
                self.cc_rt.sink_volume_pct = pct;
                self.cc_rt.sink_muted = pct <= 0;
                if (self.cc_audio) |*q| q.snap.out.volume_pct = pct;
                if (!self.drag_motion_paint_off) {
                    self.ccRefresh();
                    self.repaint();
                }
            },
            .set_input_volume => |t| {
                const pct: i32 = @intFromFloat(@round(t * 100.0));
                cc_apply.requestSource(now_ms, self.app.io, pct);
                self.cc.snap.in.volume_pct = pct;
                self.cc.snap.in.fill_t_override = t;
                if (self.cc_audio) |*q| q.snap.in.volume_pct = pct;
                if (!self.drag_motion_paint_off) self.ccRefresh();
            },
            .toggle_output_mute => {
                const muted = !self.cc.snap.out.muted;
                if (!cc_live_audio.setSinkMute(self.app.io, muted)) logz.log("control-center: set-sink-mute failed", .{});
                self.cc.snap.out.muted = muted;
                self.cc_rt.sink_muted = muted;
                if (self.cc_audio) |*q| q.snap.out.muted = muted;
                self.ccRefresh();
                self.repaint();
                logz.log("control-center: output_muted={s}", .{if (muted) "on" else "off"});
            },
            .toggle_input_mute => {
                const muted = !self.cc.snap.in.muted;
                if (!cc_live_audio.setSourceMute(self.app.io, muted)) logz.log("control-center: set-source-mute failed", .{});
                self.cc.snap.in.muted = muted;
                if (self.cc_audio) |*q| q.snap.in.muted = muted;
                self.ccRefresh();
                logz.log("control-center: input_muted={s}", .{if (muted) "on" else "off"});
            },
            .set_mixer_volume => |m| {
                const pct: i32 = @intFromFloat(@round(m.t * 100.0));
                // Like a drag override: the stream
                // list is backend-owned (const), so the in-drag value lives
                // in state and paint prefers it while the drag is active.
                cc_apply.requestStream(now_ms, self.app.io, m.stream_id, m.is_input, pct);
                self.cc.state.mixer_drag_active = true;
                self.cc.state.mixer_drag_is_input = m.is_input;
                self.cc.state.mixer_drag_stream_id = m.stream_id;
                self.cc.state.mixer_drag_visual_t = m.t;
                self.cc.state.mixer_drag_ui_pct = pct;
                if (!self.drag_motion_paint_off) self.ccRefresh();
            },
            .select_output_device => |i| {
                if (self.cc_audio) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.snap.sinks.len) {
                        const d = q.snap.sinks[@intCast(i)];
                        if (cc_live_audio.setDefaultSink(self.app.io, d.name)) {
                            const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                            defer if (st.len > 0) gpa.free(st);
                            if (st.len > 0) cc_live_audio.savePrefs(gpa, self.app.io, st, d.name, "");
                            logz.log("control-center: default sink '{s}'", .{d.name});
                            _ = self.pollCcLive(now_ms, true);
                        } else logz.log("control-center: set-default-sink failed", .{});
                    }
                }
            },
            .select_input_device => |i| {
                if (self.cc_audio) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.snap.sources.len) {
                        const d = q.snap.sources[@intCast(i)];
                        if (cc_live_audio.setDefaultSource(self.app.io, d.name)) {
                            const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                            defer if (st.len > 0) gpa.free(st);
                            if (st.len > 0) cc_live_audio.savePrefs(gpa, self.app.io, st, "", d.name);
                            logz.log("control-center: default source '{s}'", .{d.name});
                            _ = self.pollCcLive(now_ms, true);
                        } else logz.log("control-center: set-default-source failed", .{});
                    }
                }
            },
            .select_network_row => |i| {
                if (self.cc_net) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.ap_list.items.len) {
                        const ap = q.ap_list.items[@intCast(i)];
                        if (ap.active) return;
                        if (ap.secured) {
                            // Secured + not joined: prompt (or re-target the
                            // prompt when another row is picked).
                            self.cc.promptPassword(ap.ssid);
                            self.ccResize(now_ms);
                            self.ccRefresh();
                            logz.log("control-center: password prompt '{s}'", .{ap.ssid});
                        } else {
                            self.cc.cancelPassword();
                            cc_live_network.connectThread(self.app.io, ap.ssid, "");
                            logz.log("control-center: connecting '{s}'", .{ap.ssid});
                        }
                    }
                }
            },
            .submit_wifi_password => {
                const ssid = self.cc.pendingSsid();
                const pw = self.cc.pendingPassword();
                if (ssid.len == 0) return;
                if (pw.len == 0) {
                    const msg = "Password required";
                    @memcpy(self.cc_wifi_err[0..msg.len], msg);
                    self.cc_wifi_err_len = msg.len;
                    const snap = self.buildCcSnapshot();
                    self.cc.setSnapshot(snap);
                    self.ccResize(now_ms);
                    self.ccRefresh();
                    return;
                }
                cc_live_network.connectThread(self.app.io, ssid, pw);
                self.cc.cancelPassword();
                self.ccResize(now_ms);
                self.ccRefresh();
                logz.log("control-center: connecting '{s}' (password supplied)", .{ssid});
            },
            .cancel_wifi_password => {
                self.ccResize(now_ms);
                self.ccRefresh();
            },
            .select_bluetooth_row => |i| {
                if (self.cc_bt) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.device_list.items.len) {
                        const d = q.device_list.items[@intCast(i)];
                        if (d.connected) {
                            cc_live_bluetooth.deviceVerbThread(d.path, "Disconnect", q.snap.adapter_path);
                            logz.log("control-center: bt disconnect '{s}'", .{d.name});
                        } else if (d.paired) {
                            cc_live_bluetooth.deviceVerbThread(d.path, "Connect", q.snap.adapter_path);
                            logz.log("control-center: bt connect '{s}'", .{d.name});
                        } else {
                            cc_live_bluetooth.deviceVerbThread(d.path, "Pair", q.snap.adapter_path);
                            logz.log("control-center: bt pair '{s}'", .{d.name});
                        }
                    }
                }
            },
            .forget_bluetooth_row => |i| {
                if (self.cc_bt) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.device_list.items.len) {
                        const d = q.device_list.items[@intCast(i)];
                        if (cc_live_bluetooth.removeDevice(gpa, q.snap.adapter_path, d.path)) {
                            logz.log("control-center: bt forget '{s}'", .{d.name});
                            _ = self.pollCcLive(now_ms, true);
                        } else logz.log("control-center: bt forget failed '{s}'", .{d.name});
                    }
                }
            },
            .media_button => |i| {
                if (self.cc_media) |*q| {
                    const what: cc_live_media.Transport = switch (i) {
                        0 => .previous,
                        2 => .next,
                        else => .toggle,
                    };
                    if (!cc_live_media.transport(gpa, q.snap.bus_name, what)) {
                        logz.log("control-center: media transport failed", .{});
                    } else _ = self.pollCcLive(now_ms, true);
                }
            },
        }
    }

    /// End a control-center drag: `release` only clears state, so the final
    /// frame the 16 ms motion gate may have skipped is pushed here — without
    /// it the slider would sit one pointer sample behind until the next poll.
    fn releaseCc(self: *Dock) void {
        const was = self.cc.dragging_output or self.cc.dragging_input or self.cc.dragging_mixer;
        self.cc.release();
        if (was) {
            self.ccRefresh();
            self.repaint();
        }
    }

    /// The pear half of `releaseCc`.
    fn releasePear(self: *Dock) void {
        const was = self.pear.dragging_vol or self.pear.dragging_in or self.pear.dragging_bri;
        self.pear.release();
        if (was) {
            self.pearRefresh();
            self.repaint();
        }
    }

    fn ccRefresh(self: *Dock) void {
        self.cc.refresh();
        if (!self.app.conn.flush()) logz.log("control-center: flush failed after refresh", .{});
    }

    /// `cc_resize_popup`. The height the surface is asked for is the
    /// *resting* one — "Size with animations resolved
    /// to their targets so the surface is born at its resting height;
    /// paint/hit keep using the interpolated form" — so an expand is born
    /// tall enough for its 200 ms ease to play into it. Shrinking is the
    /// one exception: the taller surface is left standing so the collapse
    /// plays unclipped, and `ccSettleResize` downsizes it once it settles.
    fn ccResize(self: *Dock, now_ms: u64) void {
        if (self.cc.animActive()) self.armAnim();
        self.cc.relayout(now_ms, true);
        const want: i32 = @intFromFloat(@ceil(self.cc.layout.total_h));
        const cur = self.cc.surface.configured_height;
        if (want > 0 and cur > 0 and want < cur) {
            self.cc.relayout(now_ms, false);
            self.ccRefresh();
            if (!self.app.conn.flush()) logz.log("control-center: flush failed after resize", .{});
            return;
        }
        if (!self.cc.place(now_ms)) {
            logz.log("control-center: resize failed, closing", .{});
            self.closeCc();
            return;
        }
        if (!self.app.conn.flush()) logz.log("control-center: flush failed after resize", .{});
    }

    /// `popup_finish_draw`'s settle-resize: when the snapshot moved the
    /// wanted height (a device or stream appeared, an AP list landed), or
    /// an ease finished on a surface that was never re-placed (a collapse
    /// kept the taller one), re-place the surface — but at most once per
    /// 800 ms so streaming counts don't thrash it. Growth past the buffer
    /// is invisible, so this is what keeps rows that arrive *while open*
    /// reachable. Mid-ease the animated height is not the height the
    /// surface wants, so the ease is left to finish first.
    fn ccSettleResize(self: *Dock, now_ms: u64) void {
        if (!self.cc.open) return;
        if (self.cc.animActive()) return;
        self.cc.relayout(now_ms, true);
        const want: i32 = @intFromFloat(@ceil(self.cc.layout.total_h));
        const cur = self.cc.surface.configured_height;
        if (want <= 0 or cur <= 0 or want == cur) return;
        if (now_ms -% self.cc_settle_ms < 800) return;
        self.cc_settle_ms = now_ms;
        if (!self.cc.place(now_ms)) {
            logz.log("control-center: settle-resize failed, closing", .{});
            self.closeCc();
            return;
        }
        if (!self.app.conn.flush()) logz.log("control-center: flush failed after settle-resize", .{});
    }

    /// Fire-and-forget `sh -c` spawn for pear commands (device link, cmd
    /// buttons, custom camera command).
    /// Tracked for reaping via `autostart.spawnDetached` (a bare spawn would
    /// leak zombies — `reapChildren` only collects tracked pids).
    fn spawnShell(self: *Dock, cmd: []const u8) void {
        if (cmd.len == 0) return;
        autostart_mod.spawnDetached(self.app.io, &.{ "sh", "-c", cmd }) catch {
            logz.log("pear: spawn failed '{s}'", .{cmd});
            return;
        };
        logz.log("pear: spawned '{s}'", .{cmd});
    }

    /// Apply one pear action. Volume/input/device/media/wifi/bt write through
    /// to the same live backends as the legacy panel; toggles run their
    /// commands or flip persisted config keys (with an instant reload so the
    /// paint follows without waiting for inotify).
    fn runPearAction(self: *Dock, a: pear_host.Action) void {
        const gpa = self.app.gpa;
        const now_ms: u64 = @intCast(@divTrunc(anim.monotonicNs(), std.time.ns_per_ms));
        switch (a) {
            .none => {},
            .dismiss => self.closePear(),
            .open_networks_overlay => {
                self.pear.state.networks_overlay = true;
                cc_live_network.rescanThread(self.app.io);
                self.pearResize(now_ms);
                logz.log("pear: networks overlay open", .{});
            },
            .close_networks_overlay => {
                self.pear.state.networks_overlay = false;
                self.pear.cancelPassword();
                self.pearResize(now_ms);
            },
            .toggle_wifi => {
                const on = if (self.cc_net) |*q| !q.snap.wireless_enabled else true;
                if (!cc_live_network.setWifiEnabled(self.app.io, on)) logz.log("pear: wifi radio failed", .{});
            },
            .select_network_row => |i| {
                if (self.cc_net) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.ap_list.items.len) {
                        const ap = q.ap_list.items[@intCast(i)];
                        if (ap.active) return;
                        if (ap.secured) {
                            self.pear.promptPassword(ap.ssid);
                            self.pearResize(now_ms);
                            logz.log("pear: password prompt '{s}'", .{ap.ssid});
                        } else {
                            self.pear.cancelPassword();
                            cc_live_network.connectThread(self.app.io, ap.ssid, "");
                            logz.log("pear: connecting '{s}'", .{ap.ssid});
                        }
                    }
                }
            },
            .open_bt_overlay => {
                self.pear.state.bt_overlay = true;
                // Scanning starts with the page, as in the
                // panel's bluetooth section.
                if (self.cc_bt) |*q| cc_live_bluetooth.setDiscovery(gpa, q.snap.adapter_path, true);
                _ = self.pollCcLive(now_ms, true);
                self.pearResize(now_ms);
                logz.log("pear: bluetooth overlay open", .{});
            },
            .close_bt_overlay => {
                self.pear.state.bt_overlay = false;
                if (self.cc_bt) |*q| cc_live_bluetooth.setDiscovery(gpa, q.snap.adapter_path, false);
                self.pearResize(now_ms);
            },
            .select_bluetooth_row => |i| {
                if (self.cc_bt) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.device_list.items.len) {
                        const d = q.device_list.items[@intCast(i)];
                        if (d.connected) {
                            cc_live_bluetooth.deviceVerbThread(d.path, "Disconnect", q.snap.adapter_path);
                            logz.log("pear: bt disconnect '{s}'", .{d.name});
                        } else if (d.paired) {
                            cc_live_bluetooth.deviceVerbThread(d.path, "Connect", q.snap.adapter_path);
                            logz.log("pear: bt connect '{s}'", .{d.name});
                        } else {
                            cc_live_bluetooth.deviceVerbThread(d.path, "Pair", q.snap.adapter_path);
                            logz.log("pear: bt pair '{s}'", .{d.name});
                        }
                    }
                }
            },
            .forget_bluetooth_row => |i| {
                if (self.cc_bt) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.device_list.items.len) {
                        const d = q.device_list.items[@intCast(i)];
                        if (cc_live_bluetooth.removeDevice(gpa, q.snap.adapter_path, d.path)) {
                            logz.log("pear: bt forget '{s}'", .{d.name});
                            _ = self.pollCcLive(now_ms, true);
                        } else logz.log("pear: bt forget failed '{s}'", .{d.name});
                    }
                }
            },
            .submit_wifi_password => {
                const ssid = self.pear.pendingSsid();
                const pw = self.pear.pendingPassword();
                if (ssid.len == 0) return;
                if (pw.len == 0) {
                    const msg = "Password required";
                    @memcpy(self.cc_wifi_err[0..msg.len], msg);
                    self.cc_wifi_err_len = msg.len;
                    self.refreshPearPopup();
                    return;
                }
                cc_live_network.connectThread(self.app.io, ssid, pw);
                self.pear.cancelPassword();
                self.refreshPearPopup();
                logz.log("pear: connecting '{s}' (password supplied)", .{ssid});
            },
            .cancel_wifi_password => self.refreshPearPopup(),
            .toggle_bluetooth_power => {
                const on = if (self.cc_bt) |*q| !q.snap.powered else true;
                if (cc_live_bluetooth.setPowered(gpa, on)) {
                    if (on) {
                        if (self.cc_bt) |*q| cc_live_bluetooth.setDiscovery(gpa, q.snap.adapter_path, true);
                    }
                    _ = self.pollCcLive(now_ms, true);
                } else logz.log("pear: bluetooth power failed", .{});
            },
            .open_settings => {
                if (self.focusExisting(kSettingsAppId)) return;
                if (self.launchSibling("horizon-settings")) return;
                logz.log("pear: no sibling horizon-settings, falling back to PATH", .{});
            },
            .toggle_dnd => {
                const on = !self.app.loaded.cfg.notifications.do_not_disturb;
                const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                defer if (st.len > 0) gpa.free(st);
                if (st.len > 0 and pear_prefs.setDnd(gpa, self.app.io, st, on)) {
                    if (!self.app.reload()) logz.log("pear: dnd saved, reload deferred", .{});
                } else logz.log("pear: dnd write failed", .{});
            },
            .run_device_link => {
                const cmd = self.pear.pconfig.device_link_cmd;
                self.spawnShell(cmd);
            },
            .toggle_night_color => {
                const on = !self.app.loaded.cfg.night_light.enabled;
                const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                defer if (st.len > 0) gpa.free(st);
                if (st.len > 0 and pear_prefs.setNightLight(gpa, self.app.io, st, on)) {
                    if (!self.app.reload()) logz.log("pear: nightlight saved, reload deferred", .{});
                } else logz.log("pear: nightlight write failed", .{});
            },
            .toggle_color_scheme => {
                const dark = !std.ascii.eqlIgnoreCase(self.app.loaded.cfg.appearance.matugen_mode, "dark");
                const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                defer if (st.len > 0) gpa.free(st);
                if (st.len > 0 and pear_prefs.setThemeMode(gpa, self.app.io, st, dark)) {
                    if (!self.app.reload()) logz.log("pear: theme saved, reload deferred", .{});
                } else logz.log("pear: theme write failed", .{});
            },
            .run_camera => {
                const cmd = self.pear.pconfig.camera_cmd;
                if (cmd.len > 0) {
                    self.closePear();
                    self.spawnShell(cmd);
                } else {
                    // Zig screenshot mode is unimplemented; the fallback
                    // would run `EventHorizon --eh-screenshot --select`.
                    logz.log("pear: camera has no command configured", .{});
                }
            },
            .toggle_redeye => {
                const on = !self.redeye_on;
                self.redeye_on = on;
                self.redeye_inhibit.setInhibited(self.surface.wl_surface, on);
                if (!self.app.conn.flush()) logz.log("pear: flush failed after redeye", .{});
                self.pearRefresh();
                logz.log("pear: redeye {s}", .{if (on) "on" else "off"});
            },
            .run_cmd1 => self.spawnShell(self.pear.pconfig.cmd_run1),
            .run_cmd2 => self.spawnShell(self.pear.pconfig.cmd_run2),
            .set_output_volume => |t| {
                const pct: i32 = @intFromFloat(@round(t * 100.0));
                cc_apply.requestSink(now_ms, self.app.io, pct);
                self.pear.snap.out.volume_pct = pct;
                self.pear.snap.out.fill_t_override = t;
                self.cc_rt.sink_volume_pct = pct;
                if (self.cc_audio) |*q| q.snap.out.volume_pct = pct;
                if (!self.drag_motion_paint_off) {
                    self.pearRefresh();
                    self.repaint();
                }
            },
            .set_input_volume => |t| {
                const pct: i32 = @intFromFloat(@round(t * 100.0));
                cc_apply.requestSource(now_ms, self.app.io, pct);
                self.pear.snap.in.volume_pct = pct;
                self.pear.snap.in.fill_t_override = t;
                if (self.cc_audio) |*q| q.snap.in.volume_pct = pct;
                if (!self.drag_motion_paint_off) self.pearRefresh();
            },
            .set_brightness => |t| {
                const pct: i32 = @intFromFloat(@round(t * 100.0));
                // A sysfs write, not a spawn — cheap enough to stay inline.
                if (!self.pear_backlight.setPct(gpa, self.app.io, pct)) {
                    logz.log("pear: backlight write failed", .{});
                }
                self.pear.state.bri_drag_t = t;
                if (!self.drag_motion_paint_off) self.pearRefresh();
            },
            .toggle_output_mute => {
                const muted = !self.pear.snap.out.muted;
                if (!cc_live_audio.setSinkMute(self.app.io, muted)) logz.log("pear: set-sink-mute failed", .{});
                self.pear.snap.out.muted = muted;
                self.cc_rt.sink_muted = muted;
                if (self.cc_audio) |*q| q.snap.out.muted = muted;
                self.pearRefresh();
                self.repaint();
            },
            .toggle_input_mute => {
                const muted = !self.pear.snap.in.muted;
                if (!cc_live_audio.setSourceMute(self.app.io, muted)) logz.log("pear: set-source-mute failed", .{});
                self.pear.snap.in.muted = muted;
                if (self.cc_audio) |*q| q.snap.in.muted = muted;
                self.pearRefresh();
            },
            .toggle_output_devices => {
                self.pear.state.output_devices_expanded = !self.pear.state.output_devices_expanded;
                self.pearResize(now_ms);
            },
            .toggle_input_devices => {
                self.pear.state.input_devices_expanded = !self.pear.state.input_devices_expanded;
                self.pearResize(now_ms);
            },
            .select_output_device => |i| {
                if (self.cc_audio) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.snap.sinks.len) {
                        const d = q.snap.sinks[@intCast(i)];
                        if (cc_live_audio.setDefaultSink(self.app.io, d.name)) {
                            const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                            defer if (st.len > 0) gpa.free(st);
                            if (st.len > 0) cc_live_audio.savePrefs(gpa, self.app.io, st, d.name, "");
                            logz.log("pear: default sink '{s}'", .{d.name});
                            _ = self.pollCcLive(now_ms, true);
                        }
                    }
                }
            },
            .select_input_device => |i| {
                if (self.cc_audio) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.snap.sources.len) {
                        const d = q.snap.sources[@intCast(i)];
                        if (cc_live_audio.setDefaultSource(self.app.io, d.name)) {
                            const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                            defer if (st.len > 0) gpa.free(st);
                            if (st.len > 0) cc_live_audio.savePrefs(gpa, self.app.io, st, "", d.name);
                            logz.log("pear: default source '{s}'", .{d.name});
                            _ = self.pollCcLive(now_ms, true);
                        }
                    }
                }
            },
            .media_button => |i| {
                if (self.cc_media) |*q| {
                    const what: cc_live_media.Transport = switch (i) {
                        0 => .previous,
                        2 => .next,
                        else => .toggle,
                    };
                    if (!cc_live_media.transport(gpa, q.snap.bus_name, what)) {
                        logz.log("pear: media transport failed", .{});
                    } else _ = self.pollCcLive(now_ms, true);
                }
            },
        }
    }

    /// Relayout + recreate the surface after a height change (overlay,
    /// device panels), then repaint.
    fn pearResize(self: *Dock, now_ms: u64) void {
        _ = now_ms;
        self.refreshPearPopup();
        if (!self.pear.place()) {
            logz.log("pear: resize failed, closing", .{});
            self.closePear();
        } else if (!self.app.conn.flush()) {
            logz.log("pear: flush failed after resize", .{});
        }
    }

    fn closePear(self: *Dock) void {
        if (!self.pear.open) return;
        // A scan started by the bluetooth page must not outlive the popup,
        // and a reopen lands on the main page rather than a stale device list.
        if (self.pear.state.bt_overlay) {
            if (self.cc_bt) |*q| cc_live_bluetooth.setDiscovery(self.app.gpa, q.snap.adapter_path, false);
            self.pear.state.bt_overlay = false;
        }
        self.pear.reset();
        if (!self.app.conn.flush()) logz.log("pear: flush failed on close", .{});
    }

    fn pearRefresh(self: *Dock) void {
        self.pear.refresh();
        if (!self.app.conn.flush()) logz.log("pear: flush failed after refresh", .{});
    }

    /// View flags behind one pear frame: config toggles + redeye + backlight.
    fn pearFlags(self: *Dock) pear_host.Host.Flags {
        const cfg = &self.app.loaded.cfg;
        return .{
            .dnd = cfg.notifications.do_not_disturb,
            .night = cfg.night_light.enabled,
            .dark = pearIsDark(cfg, self.pear.pconfig),
            .redeye = self.redeye_on,
            .brightness_pct = self.pear_backlight.pct(self.app.gpa, self.app.io),
        };
    }

    /// Theme darkness: explicit `pear_is_dark_theme` wins, else auto from
    /// the chrome fill luminance (<= 0.4 counts as dark).
    fn pearIsDark(cfg: *const config.ShellConfig, pcfg: pear_config.Config) bool {
        if (pcfg.is_dark_theme != -1) return pcfg.is_dark_theme == 1;
        const ch = chrome_colors.of(cfg);
        const lum = 0.2126 * ch.dock_fill.r + 0.7152 * ch.dock_fill.g + 0.0722 * ch.dock_fill.b;
        return lum <= 0.4;
    }

    /// Rebuild the pear snapshot + layout + paint after a state change.
    fn refreshPearPopup(self: *Dock) void {
        const snap = self.buildCcSnapshot();
        self.pear.setSnapshot(snap);
        self.pear.setFlags(self.pearFlags());
        self.pear.relayout(self.pearUiScale(), self.pear_backlight.available());
        self.pearRefresh();
    }

    fn pearUiScale(self: *Dock) f64 {
        return dw.uiScale(&self.app.loaded.cfg);
    }

    /// Open the pear popup above its slot. Same placement discipline as the
    /// legacy panel (bottom|left + slot-anchored margins), at the compact
    /// 360 × combined-scale width.
    fn showPear(self: *Dock, idx: usize) void {
        if (idx >= self.strip.slots.len) return;
        self.popup.reset();
        self.closeCc();
        const now_ms: u64 = @intCast(@divTrunc(anim.monotonicNs(), std.time.ns_per_ms));
        _ = self.pollCcLive(now_ms, true);
        self.pear_backlight.scan(self.app.gpa, self.app.io);
        const slot = self.strip.slots[idx];
        const pcfg = pear_config.load(&self.app.loaded.cfg, slot.key);
        const us = @max(0.5, self.pearUiScale() * pear_config.scaleOf(pcfg));
        const width: i32 = @max(200, @as(i32, @intFromFloat(@round(360.0 * us))));
        const snap = self.buildCcSnapshot();
        const slot_cx = self.slotCentreX(idx) orelse @divTrunc(self.buf_w, 2);
        const dock_w = if (self.buf_w > 0) self.buf_w else self.req_w;
        const out_w: i32 = @intFromFloat(@round(self.outputLogicalW()));
        const origin_x = cc_position.layerOriginX(out_w, dock_w);
        const gap: i32 = @intFromFloat(@round(6.0 * us));
        const extra: i32 = @intFromFloat(@round(2.0 * us));
        const pos = cc_position.computeMargins(.{
            .anchor_x = slot_cx,
            .popup_w = width,
            .popup_h = 0,
            .output_w = out_w,
            .layer_w = dock_w,
            .layer_origin_x = origin_x,
            .bottom_clearance = 0,
        });
        const margin_bottom = @max(0, self.req_h + gap) + extra;
        const pos_out = self.positionOutput();
        const ok = self.pear.openPear(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            if (pos_out) |e| e.obj else null,
            @intCast(self.surface.configured_width),
            @intCast(self.surface.configured_height),
            width,
            pos.margin_left + extra,
            margin_bottom,
            &self.app.loaded.cfg,
            slot.key,
            snap,
            self.pearUiScale(),
            self.pear_backlight.available(),
        );
        if (!ok) {
            logz.log("pear: present failed slot={d}", .{idx});
            self.pear.reset();
            return;
        }
        self.pear.setFlags(self.pearFlags());
        logz.log("pear: open slot={d} w={d} h={d} margin_left={d}", .{ idx, width, self.pear.layout.total_h, pos.margin_left });
        if (!self.app.conn.flush()) logz.log("pear: flush failed", .{});
    }

    /// A slot's centre in *surface* pixels — the same space the popup buffer
    /// is addressed in, since the popup is built as wide as the dock.
    fn slotCentreX(self: *Dock, idx: usize) ?i32 {
        const g = self.geom orelse return null;
        const cfg = &self.app.loaded.cfg;
        const sx = dw.layoutXToSurface(dw.slotLayoutX(cfg, &g, idx), g.mid_x, g.h_scale);
        return @intFromFloat(@round(sx + g.widths[idx] * g.h_scale * 0.5));
    }

    fn isPinned(self: *Dock, norm: []const u8) bool {
        const cfg = &self.app.loaded.cfg;
        return isPinnedId(norm, cfg.dock.pinned_apps);
    }

    /// Pin and unpin are a config edit, and the config is arena-backed: the
    /// only safe way to change it is to write the file and let the loader
    /// rebuild `Loaded` from scratch, which is also what makes the change
    /// survive a restart. The watcher would do that on its own; reloading here
    /// too is what makes it happen in the same click.
    fn togglePin(self: *Dock) void {
        self.togglePinKey(self.popup.app_key);
    }

    /// Pin or unpin `target`. Both doors on this edit — the app's own menu and
    /// the start menu's row menu — go through here, so they can never disagree
    /// about what a pin is called.
    fn togglePinKey(self: *Dock, target: []const u8) void {
        const gpa = self.app.gpa;
        if (target.len == 0) return;
        const cfg = &self.app.loaded.cfg;

        // Entries that come from `cfg` are arena-owned and must not be freed
        // here; only the one this call allocates is ours to release.
        var next: std.ArrayList([]const u8) = .empty;
        defer next.deinit(gpa);
        var owned: ?[]const u8 = null;
        defer if (owned) |o| gpa.free(o);

        var removed = false;
        for (cfg.dock.pinned_apps) |raw| {
            // The pin is compared the way the strip compares it: the entry
            // may read `sh.cider.Cider` while the menu was opened on the
            // window's own `cider`, and unpining must find it either way or
            // the second pin lands beside the first.
            if (paths.sameAppId(raw, target)) {
                removed = true;
                continue;
            }
            next.append(gpa, raw) catch return;
        }
        if (removed) {
            logz.log("menu: unpin '{s}'", .{target});
        } else {
            const added = gpa.dupe(u8, target) catch return;
            owned = added;
            next.append(gpa, added) catch return;
            logz.log("menu: pin '{s}'", .{target});
        }

        const settings = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch return;
        defer gpa.free(settings);
        const path = config.componentPath(gpa, settings, "dock") catch return;
        defer gpa.free(path);
        pin_store.save(gpa, self.app.io, path, next.items) catch |e| {
            logz.err("menu: cannot write {s}: {s}", .{ path, @errorName(e) });
            return;
        };
        if (!self.app.reload()) logz.log("menu: pin saved, but the reload was deferred", .{});
    }

    // -----------------------------------------------------------------
    // The pinned drag
    // -----------------------------------------------------------------

    /// A press on a pinned app. Nothing happens until the pointer moves: a
    /// click still activates the app, on release, exactly as it did before.
    /// False when the drag cannot be trusted — the strip has to be the pin
    /// list, entry for entry, for the index it works in to mean anything.
    fn beginPinDrag(self: *Dock, slot: usize, x: f64, y: f64) bool {
        const cfg = &self.app.loaded.cfg;
        var from: i32 = -1;
        var n: usize = 0;
        for (self.strip.slots, 0..) |s, i| {
            if (s.kind != .app or !s.is_pinned) continue;
            if (i == slot) from = @intCast(n);
            n += 1;
        }
        // A second `pinned_apps` token in another section, or one the layout
        // filtered, would leave `from` naming something the config does not
        // have; the pin list then stays out of reach of the drag.
        if (from < 0 or n != cfg.dock.pinned_apps.len) return false;
        self.pin_drag.deinit(self.app.gpa);
        self.pin_drag = .{
            .candidate = true,
            .slot = slot,
            .start_x = x,
            .start_y = y,
            .from = from,
            .insert = from,
            .count = n,
        };
        return true;
    }

    /// Every motion while a press may still turn into a drag, and every motion
    /// after that. The drag owns hover from the moment it starts: the lift
    /// would otherwise track a slot that is shuffling under the pointer.
    fn pinDragMotion(self: *Dock, x: f64, y: f64) void {
        if (self.pin_drag.candidate and !self.pin_drag.dragging) {
            const dx = x - self.pin_drag.start_x;
            const dy = y - self.pin_drag.start_y;
            if (dx * dx + dy * dy < k_pin_drag_px * k_pin_drag_px) return;
            self.pin_drag.dragging = true;
            self.hover = no_slot;
            // The drag's own frame bookkeeping starts here, so its summary
            // line counts the drag and not the hover that came before it.
            self.paint_frames = 0;
            self.dropped_frames = 0;
            self.lift.begin(0.0, anim.monotonicNs(), anim.kHoverLiftNs);
            if (self.lift.running) self.armAnim();
            logz.log(
                "pin-drag: start slot={d} pin={d}/{d}",
                .{ self.pin_drag.slot, self.pin_drag.from, self.pin_drag.count },
            );
        }
        if (!self.pin_drag.dragging) return;
        // A window opening mid-drag rebuilds the strip; the number the pin was
        // at is only a guess until it has been re-read.
        self.pinDragLocate();
        const at = self.pinInsertAt(x);
        if (at >= 0 and at != self.pin_drag.insert) {
            self.pin_drag.insert = at;
            self.pinDragReorder();
        }
        // The dragged icon is painted where the pointer is, so a motion that
        // moved no other slot still owes a frame. Gated to 16 ms the way the
        // control-centre drags are: motion arrives faster than the strip can
        // be repainted, and a skipped frame is pushed by the next motion or by
        // the release, which repaints on its own.
        if (self.dragFrameDue(Dock.nowMs())) self.repaint();
    }

    /// The pin index the pointer is over, worked out from the run's own pitch.
    /// The slots are read as painted: widgets in front of the run move it, so
    /// assuming `icon + gap` would drift the further the drag went.
    fn pinInsertAt(self: *const Dock, x: f64) i32 {
        const g = self.geom orelse return -1;
        const cfg = &self.app.loaded.cfg;
        var first: f64 = 0;
        var prev: f64 = 0;
        var stride: f64 = 0;
        var icon: f64 = @floatFromInt(self.icon_px);
        var n: usize = 0;
        for (self.strip.slots, 0..) |s, i| {
            if (s.kind != .app or !s.is_pinned) continue;
            const sx = dw.layoutXToSurface(dw.slotLayoutX(cfg, &g, i), g.mid_x, g.h_scale);
            if (n == 0) first = sx else if (n == 1) stride = sx - prev;
            prev = sx;
            icon = g.widths[i] * g.h_scale;
            n += 1;
        }
        if (n == 0) return -1;
        if (n > 1 and stride <= 0) stride = (prev - first) / @as(f64, @floatFromInt(n - 1));
        if (stride <= 0) stride = icon;
        const idx: i32 = @intFromFloat(@round((x - (first + icon * 0.5)) / stride));
        const last: i32 = @intCast(n - 1);
        return @max(0, @min(idx, last));
    }

    /// Puts the dragged pin at `insert` and rebuilds the strip from that order,
    /// so the icons the pointer passes over slide aside while the drag is still
    /// going. The list keeps the config's own spelling — a pin saved as
    /// `sh.cider.Cider` has to still match on the next unpin.
    fn pinDragReorder(self: *Dock) void {
        const gpa = self.app.gpa;
        if (self.pin_drag.insert < 0) return;
        const owned = pin_order.moved(
            gpa,
            self.app.loaded.cfg.dock.pinned_apps,
            @intCast(self.pin_drag.from),
            @intCast(self.pin_drag.insert),
        ) catch |e| {
            logz.err("pin-drag: cannot work out the new order: {s}", .{@errorName(e)});
            return;
        } orelse return;

        // The strip on screen still borrows the preview it was built from, so
        // the old one is released only once the rebuild has replaced it.
        const stale = self.pin_drag.releasePreview();
        self.pin_drag.order = owned;
        self.dragRemodel();
        if (stale) |old| {
            for (old) |s| gpa.free(s);
            gpa.free(old);
        }
        self.pinDragLocate();
    }

    /// A rebuild the drag does on its own account. `buildModel` nulls the
    /// strip geometry on its way out, so without the `layout` after it the
    /// next motion would have nowhere to read the pin positions from.
    fn dragRemodel(self: *Dock) void {
        self.buildModel();
        self.layout();
    }

    /// Finds the slot the pin being dragged now sits in. Every reorder — and
    /// every window that opens while the drag is going — rebuilds the strip
    /// under it, so the slot number is only ever a guess until re-read.
    fn pinDragLocate(self: *Dock) void {
        const want: usize = @intCast(@max(self.pin_drag.insert, 0));
        var n: usize = 0;
        for (self.strip.slots, 0..) |s, i| {
            if (s.kind != .app or !s.is_pinned) continue;
            if (n == want) {
                self.pin_drag.slot = i;
                return;
            }
            n += 1;
        }
        self.pin_drag.slot = no_slot;
    }

    /// The release that ends a drag. A drop back where the pin started writes
    /// nothing: the config file is only touched when the order changed.
    fn pinDragDrop(self: *Dock) void {
        const gpa = self.app.gpa;
        const key = if (self.pin_drag.slot < self.strip.slots.len)
            self.strip.slots[self.pin_drag.slot].key
        else
            "";
        const changed = self.pin_drag.order != null and self.pin_drag.insert != self.pin_drag.from;
        if (!changed) {
            self.endPinDrag(false);
            return;
        }
        // Read before the rebuild below replaces the strip this came from.
        logz.log("pin-drag: '{s}' to {d}", .{ key, self.pin_drag.insert });
        const settings = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch |e| {
            logz.err("pin-drag: no settings dir: {s}", .{@errorName(e)});
            self.endPinDrag(false);
            return;
        };
        defer gpa.free(settings);
        const path = config.componentPath(gpa, settings, "dock") catch |e| {
            logz.err("pin-drag: no dock file: {s}", .{@errorName(e)});
            self.endPinDrag(false);
            return;
        };
        defer gpa.free(path);
        if (pin_store.save(gpa, self.app.io, path, self.pin_drag.order.?)) {
            // The watcher would pick the write up on its own; reloading here
            // is what makes the drop land in the same instant it happened.
            self.endPinDrag(true);
        } else |e| {
            logz.err("pin-drag: cannot write {s}: {s}", .{ path, @errorName(e) });
            self.endPinDrag(false);
        }
    }

    /// Puts the dock back to the config's pin order and lets go of the drag.
    /// The model is rebuilt *before* the preview is released: the strip on
    /// screen borrows the preview's strings, and nothing may read them once
    /// they are gone.
    fn endPinDrag(self: *Dock, reload: bool) void {
        const gpa = self.app.gpa;
        // What the drag cost in frames, in one line — flicker shows up here
        // as a `dropped` count that is not zero.
        if (self.paint_frames > 0 or self.dropped_frames > 0) {
            logz.log(
                "pin-drag: {d} frame(s) put out, {d} dropped",
                .{ self.paint_frames, self.dropped_frames },
            );
        }
        self.paint_frames = 0;
        self.dropped_frames = 0;
        const stale = self.pin_drag.releasePreview();
        self.pin_drag.deinit(gpa);
        defer if (stale) |old| {
            for (old) |s| gpa.free(s);
            gpa.free(old);
        };
        // A reload rebuilds through `onReload`; when it is deferred or not
        // wanted, the rebuild is this drag's own.
        if (reload and self.app.reload()) return;
        self.dragRemodel();
        self.repaint();
    }

    fn onMotion(ctx: *anyopaque, _: f64, _: f64) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        if (self.onPearSurface()) {
            self.ptr_on = .popup;
            const pp = lastPointer(self);
            if (self.pear.dragging_vol or self.pear.dragging_in or self.pear.dragging_bri) {
                if (self.pear.dragTo(pp[0])) |a| {
                    // Motion is the only path behind the 16 ms frame gate:
                    // state lands either way, pixels only when due.
                    self.drag_motion_paint_off = !self.dragFrameDue(Dock.nowMs());
                    self.runPearAction(a);
                    self.drag_motion_paint_off = false;
                }
                return;
            }
            if (self.pear.motion(pp[0], pp[1])) self.pearRefresh();
            return;
        }
        if (self.onCcSurface()) {
            self.ptr_on = .popup;
            const pp = lastPointer(self);
            if (self.cc.dragging_output or self.cc.dragging_input or self.cc.dragging_mixer) {
                if (self.cc.dragTo(pp[0])) |a| {
                    self.drag_motion_paint_off = !self.dragFrameDue(Dock.nowMs());
                    self.runCcAction(a);
                    self.drag_motion_paint_off = false;
                }
                return;
            }
            if (self.cc.motion(pp[0], pp[1])) self.ccRefresh();
            return;
        }
        if (self.popup.kind == .launcher and self.onPopupSurface()) {
            self.ptr_on = .popup;
            const pp = lastPointer(self);
            if (self.launcher.hoverAt(pp[0], pp[1])) self.popupRefresh();
            return;
        }
        if (self.popup.kind == .world_clock and self.onPopupSurface()) {
            self.ptr_on = .popup;
            const pp = lastPointer(self);
            self.applyWcOutcome(self.wcMotion(pp[0], pp[1]));
            return;
        }
        if (self.onPopupSurface()) {
            self.ptr_on = .popup;
            const pp = lastPointer(self);
            const x: i32 = @intFromFloat(@round(pp[0]));
            const y: i32 = @intFromFloat(@round(pp[1]));
            // The hover runs first either way: it is what keeps the mixer
            // card's `View` pointing at the pointer, and a drag reads it back
            // to decide where the handle sits.
            const changed = self.popup.hoverAt(x, y, self.menuScale());
            if (self.mixerDragMotion()) return;
            if (changed) self.popupRefresh();
            return;
        }
        self.ptr_on = .dock;
        const pos = lastPointer(self);
        // A press that may still be a drag takes the pointer whole: it decides
        // where the pin goes, and the hover it would otherwise set is a slot
        // that is shuffling underneath it.
        if (self.pin_drag.candidate or self.pin_drag.dragging) {
            self.pinDragMotion(pos[0], pos[1]);
            return;
        }
        const hit = self.slotAt(pos[0], pos[1]);
        if (hit == self.hover) return;
        self.hover = hit;
        if (hit == no_slot) {
            logz.log("hover: none", .{});
        } else {
            logz.log("hover: slot={d} kind={s}", .{ hit, @tagName(self.strip.slots[hit].kind) });
        }
        if (hit != no_slot and hit < self.strip.slots.len and liftEligible(self.strip.slots[hit].kind)) {
            // Snaps the lift to 0 on entry, so an icon pops
            // down before it rises rather than sliding in from its old height.
            self.lift.value = 0.0;
            self.lift.begin(anim.kHoverLiftPx, anim.monotonicNs(), anim.kHoverLiftNs);
        } else {
            self.lift.begin(0.0, anim.monotonicNs(), anim.kHoverLiftNs);
        }
        if (self.lift.running) self.armAnim();
        self.repaint();
    }

    fn onEnter(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        if (self.onPopupSurface()) {
            self.ptr_on = .popup;
            // A surface that appears under a still pointer gets an enter and
            // no motion at all, so the launcher's first hover — and the media
            // card's — has to be worked out here rather than waited for.
            if (self.popup.kind == .launcher or self.popup.kind == .media_player or self.popup.kind == .world_clock) {
                Dock.onMotion(ctx, x, y);
                return;
            }
            logz.log("pointer: enter menu ({d:.1},{d:.1})", .{ x, y });
            return;
        }
        logz.log("pointer: enter ({d:.1},{d:.1})", .{ x, y });
        Dock.onMotion(ctx, x, y);
    }

    fn onLeave(ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        logz.log("pointer: leave ({s})", .{@tagName(self.ptr_on)});
        // `seat.ptrLeave` clears `focus_surface` before this runs, so by now
        // the only record of *which* surface was left is `ptr_on`.
        if (self.ptr_on == .popup and self.popup.kind == .launcher) {
            if (self.launcher.clearHover()) self.popupRefresh();
            self.ptr_on = .none;
            return;
        }
        if (self.ptr_on == .popup) {
            if (self.popup.kind == .world_clock and self.wc_init and !self.wc.p.dragging_slider) {
                // Leaving the surface is a motion to nowhere: the panel's
                // hover fades, while a slider drag in progress is left alone
                // (the pointer is off the card, its value stays).
                const out = wc_panel.motion(&self.wc, &self.popup.wc_geom, -1.0, -1.0, Dock.epochMs());
                if (out.repaint) self.popupRefresh();
            }
            if (self.popup.clearHover()) self.popupRefresh();
            if (self.cc.motion(-1, -1)) self.ccRefresh();
            self.releaseCc();
            if (self.pear.motion(-1, -1)) self.pearRefresh();
            self.releasePear();
            self.ptr_on = .none;
            return;
        }
        self.ptr_on = .none;
        // The compositor stops sending motion once the surface is left, so
        // without this the last hovered icon stays lifted and clickable at a
        // position the pointer is no longer at.
        self.hover = no_slot;
        self.pressed = no_slot;
        // A drag in flight would freeze here and its release would turn up on
        // a surface the dock never hears about, so it drops where it is.
        if (self.pin_drag.dragging) {
            self.pinDragDrop();
        } else if (self.pin_drag.candidate) {
            self.endPinDrag(false);
        }
        self.lift.begin(0.0, anim.monotonicNs(), anim.kHoverLiftNs);
        if (self.lift.running) self.armAnim();
        self.repaint();
    }

    /// Wayland hands us the Linux input-event code (`BTN_LEFT` is 0x110), but
    /// `dock_input.press` speaks the button numbers its tests are written
    /// against: 1 left, 2 middle, 3 right, dropping every other code
    /// that is neither `0x110` nor `0x111..0x113`, so the unhandled ones here
    /// are the same set it discards.
    fn slotButton(button: u32) ?u8 {
        return switch (button) {
            0x110 => 1,
            0x111 => 3,
            0x112 => 2,
            0x113 => 3,
            else => null,
        };
    }

    fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        if (self.onPearSurface()) {
            if (state == 0) {
                self.releasePear();
                return;
            }
            logz.log("pointer: pear button=0x{x} state={d}", .{ button, state });
            self.pearClick();
            return;
        }
        if (self.onCcSurface()) {
            if (state == 0) {
                self.releaseCc();
                return;
            }
            logz.log("pointer: cc button=0x{x} state={d}", .{ button, state });
            self.ccClick();
            return;
        }
        if (self.onPopupSurface()) {
            if (self.popup.kind == .world_clock and self.wc_init) {
                // The panel acts on the way down (rows, switches, the add
                // pane, the search field) and settles on the way up: a slider
                // drag writes its value then, like the mixer's.
                if (state == 0) {
                    self.applyWcOutcome(wc_panel.release(&self.wc));
                    return;
                }
                logz.log("pointer: menu button=0x{x} state={d}", .{ button, state });
                const wpos = lastPointer(self);
                self.applyWcOutcome(self.wcPress(wpos[0], wpos[1]));
                return;
            }
            // Menus act on the way down, and the release that follows arrives
            // on a surface that has already been torn down by `popupClick`.
            if (state == 0) {
                // The mixer card's slider is the one thing here that settles
                // on the way up: the value it was dragged to is written then,
                // exactly as `mixer_release_at` does it.
                _ = self.mixerRelease();
                return;
            }
            logz.log("pointer: menu button=0x{x} state={d}", .{ button, state });
            self.popupClick(slotButton(button));
            return;
        }
        if (state == 0) {
            // Release only clears the press visual — every action
            // already fired on the way down. The one exception is a
            // pinned app, whose press only now decides what it was: a drag
            // that drops, or a click that launches.
            if (self.popup.kind == .world_clock and self.wc_init and self.wc.p.dragging_slider) {
                // A world-clock slider drag ends wherever the pointer
                // happens to be, not only over the panel.
                _ = wc_panel.release(&self.wc);
                self.popupRefresh();
                return;
            }
            if (self.cc.open) self.releaseCc();
            if (self.pear.open) self.releasePear();
            if (self.pin_drag.dragging) {
                self.pinDragDrop();
                self.repaint();
                return;
            }
            if (self.pin_drag.candidate) {
                const slot = self.pin_drag.slot;
                self.pressed = no_slot;
                // A window that opened between the press and the release
                // renumbers the strip, so only the app the press landed on —
                // still a pin, still where the press said — is worth
                // activating. That read happens before the drag state goes:
                // its keys may point into a preview it would otherwise free.
                if (slot < self.strip.slots.len and
                    self.strip.slots[slot].kind == .app and
                    self.strip.slots[slot].is_pinned)
                {
                    self.activate(slot);
                }
                self.endPinDrag(false);
                return;
            }
            if (self.pressed == no_slot) return;
            self.pressed = no_slot;
            self.repaint();
            return;
        }
        // `dock_handle_slot_press` closes an open popup before it dispatches
        // the press. One click therefore dismisses, and that same click does
        // *not* also fire whatever the slot underneath was asked to do —
        // otherwise reopening the calendar would need two clicks every time.
        if (self.pear.open) {
            self.closePear();
            return;
        }
        if (self.cc.open) {
            self.closeCc();
            return;
        }
        if (self.popup.open) {
            self.closeMenu();
            return;
        }
        // `@intCast` here was a panic waiting to happen: `button` is a u32
        // Linux code and `press` takes a u8, so 0x110 overflowed the cast the
        // moment the user actually clicked.
        const btn = slotButton(button) orelse {
            logz.log("pointer: ignoring button=0x{x} state={d}", .{ button, state });
            return;
        };
        const pos = lastPointer(self);
        const hit = self.slotAt(pos[0], pos[1]);
        if (hit == no_slot) {
            logz.log(
                "pointer: button=0x{x}({d}) state={d} pos=({d:.1},{d:.1}) slot=none",
                .{ button, btn, state, pos[0], pos[1] },
            );
            return;
        }
        logz.log(
            "pointer: button=0x{x}({d}) state={d} pos=({d:.1},{d:.1}) slot={d} kind={s}",
            .{ button, btn, state, pos[0], pos[1], hit, @tagName(self.strip.slots[hit].kind) },
        );
        const ev = dock_input.press(self.strip.slots.len, hit, btn, 500, 0);
        switch (ev.action) {
            .launch => {
                // The clock and weather slots' "launch" is their card.
                // The control-center slot opens the quick-settings
                // panel the same way.
                switch (self.strip.slots[ev.slot].kind) {
                    .clock => {
                        self.showCalendar(ev.slot);
                        return;
                    },
                    .weather => {
                        self.showWeather(ev.slot);
                        return;
                    },
                    .control_center => {
                        self.showControlCenter(ev.slot);
                        return;
                    },
                    .pear_center => {
                        self.showPear(ev.slot);
                        return;
                    },
                    .bluetooth => {
                        // Same deal as the cards above: only
                        // this slot paints here and the card belongs to the panel,
                        // but here the slot *is* the entry point, so it
                        // opens the widget's own card:
                        // bluetooth popup, driven by the dock's reading).
                        self.showBluetooth(ev.slot);
                        return;
                    },
                    .vpn => {
                        self.showVpn(ev.slot);
                        return;
                    },
                    .layout => {
                        // Same deal as the cards above: no
                        // `PickSlot::Kind::Layout` arm here at all —
                        // never mentions it, and the
                        // popup belongs to the *panel*:
                        // `PanelPaintSlot::Kind::Layout`, opening on
                        // `kLayoutPopupW` and `layout_popup_height()`). Here
                        // the slot is the only entry point there is, so it
                        // opens that same card, with those same dimensions.
                        self.showLayout(ev.slot);
                        return;
                    },
                    .world_clock => {
                        // The spec's popup: the widget's own panel, opened on
                        // the slot (the taskbar's world clock opens the same
                        // one).
                        self.showWorldClock(ev.slot);
                        return;
                    },
                    .volume_mixer => {
                        // `PickSlot::Kind::VolumeMixer`
                        // arm: the dock's own card, opened on the slot — the
                        // panel has the same one, and here the slot is the
                        // entry point either way.
                        self.showVolumeMixer(ev.slot);
                        return;
                    },
                    .clipstack => {
                        // Clipboard history: launches the standalone picker
                        // overlay — the same program the Super+V binding
                        // execs. No card here: the picker is its own layer
                        // surface, and its instance lock gives the launch
                        // toggle semantics (open → kill the open one).
                        if (!self.launchSibling("horizon-clipstack-pick")) {
                            logz.err("activate: horizon-clipstack-pick not found beside the dock binary", .{});
                        }
                        return;
                    },
                    .smenu => {
                        self.showLauncher(ev.slot, .classic);
                        return;
                    },
                    .app_drawer => {
                        // The reference card, same as the taskbar's App
                        // drawer: the grid (or list) of every application.
                        self.showLauncher(ev.slot, .classic);
                        return;
                    },
                    .app_menu => {
                        // The launchpad dots open the App menu's own rail
                        // panel — the same one the taskbar's App menu opens.
                        // Without this arm the press fell through to
                        // `activate`, which has no launch target for a widget
                        // that stands for a panel: the dots did nothing.
                        self.showLauncher(ev.slot, .rail);
                        return;
                    },
                    .spotlight => {
                        // Tahoe unification, as in the C++ dock: Spotlight
                        // *is* the Applications window, so its slot opens the
                        // same App menu panel.
                        self.showLauncher(ev.slot, .rail);
                        return;
                    },
                    .overview => {
                        self.showOverview();
                        return;
                    },
                    .workspaces => {
                        self.focusWorkspace(ev.slot, pos[0]);
                        return;
                    },
                    .media => {
                        // The pill's own transport row answers in place;
                        // anything else — the artwork, or empty space —
                        // opens the media card.
                        const zone = self.mediaZone(ev.slot, lastPointer(self)[0]);
                        if (zone == 0) {
                            _ = self.media.act(.previous);
                        } else if (zone == 1) {
                            _ = self.media.act(.play_pause);
                        } else if (zone == 2) {
                            _ = self.media.act(.next);
                        } else {
                            self.showMediaPlayer(ev.slot);
                        }
                        self.repaint();
                        return;
                    },
                    .app => {
                        // A pinned app's press starts a drag rather than
                        // activating: whether it is one waits for the pointer
                        // to move, and a click that never moves still launches
                        // — on the release.
                        if (self.strip.slots[ev.slot].is_pinned and
                            self.beginPinDrag(ev.slot, pos[0], pos[1]))
                        {
                            self.pressed = hit;
                            self.repaint();
                            return;
                        }
                    },
                    else => {},
                }
                self.pressed = hit;
                self.repaint();
                self.activate(ev.slot);
            },
            .show_menu => {
                logz.log("input: action=show_menu slot={d}", .{ev.slot});
                self.showMenu(ev.slot);
            },
            .begin_drag, .show_tooltip, .none => {
                logz.log("input: action={s} slot={d}", .{ @tagName(ev.action), ev.slot });
            },
        }
    }

    /// The launcher is the only thing in the dock that wants the keyboard, so
    /// this callback exists for it and ignores everything else. The seat is a
    /// global listener with no `wl_keyboard.enter` bookkeeping of its own,
    /// which is exactly what the launcher's exclusive `keyboard_interactivity`
    /// needs: the compositor has already decided who the keys belong to.
    fn onKey(ctx: *anyopaque, ev: *const seat_mod.KeyEvent) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        // The control-center password prompt takes keys while it is open
        // (typing, Enter to join, Esc to cancel); Esc with no prompt closes.
        if (self.cc.open) {
            const pressed = ev.state == 1;
            const text = if (ev.utf8_len > 0) ev.utf8[0..@min(@as(usize, ev.utf8_len), ev.utf8.len)] else "";
            if (self.cc.key(ev.sym, text, pressed)) |a| {
                self.runCcAction(a);
                return;
            }
            if (pressed) return;
        }
        // Same for pear's overlay password prompt.
        if (self.pear.open) {
            const pressed = ev.state == 1;
            const text = if (ev.utf8_len > 0) ev.utf8[0..@min(@as(usize, ev.utf8_len), ev.utf8.len)] else "";
            if (self.pear.key(ev.sym, text, pressed)) |a| {
                self.runPearAction(a);
                return;
            }
            if (pressed) return;
        }
        if (self.popup.kind == .world_clock and self.wc_init) {
            // The panel's keyboard: the search field, arrow navigation and
            // the two switches. The shift bit is not part of the seat's
            // event, so the modifier keycodes carry it.
            const pressed = ev.state == 1;
            if (ev.keycode == 42 or ev.keycode == 54) self.wc_shift_down = pressed;
            const text = if (ev.utf8_len > 0) ev.utf8[0..@min(@as(usize, ev.utf8_len), ev.utf8.len)] else "";
            self.applyWcOutcome(wc_panel.key(&self.wc, &self.popup.wc_geom, ev.sym, text, pressed, self.wc_shift_down, Dock.epochMs()));
            return;
        }
        if (self.popup.kind != .launcher) return;
        self.applyLauncher(self.launcher.key(ev));
    }

    /// The wheel over the launcher's list. The seat hands the raw axis value
    /// through; the settings window scales a notch by four and clamps it, and
    /// the launcher's body is the same kind of scrollable list, so it does
    /// the same rather than inventing a second feel for the same wheel.
    fn onAxis(ctx: *anyopaque, delta: f64) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        // The wheel over an open control-center popup nudges the slider
        // under the pointer (±5% axis handling).
        if (self.cc.open and self.onCcSurface()) {
            const pp = lastPointer(self);
            if (self.cc.scroll(pp[0], pp[1], delta)) |a| self.runCcAction(a);
            return;
        }
        // Same over the pear popup.
        if (self.pear.open and self.onPearSurface()) {
            const pp = lastPointer(self);
            if (self.pear.scroll(pp[0], pp[1], delta)) |a| self.runPearAction(a);
            return;
        }
        // And over the mixer card: the wheel bumps the slider under the
        // pointer and scrolls the list everywhere else inside it.
        if (self.mixerAxis(delta)) return;
        // The wheel over the world-clock panel scrolls its list (or the add
        // pane's results); over the widget itself it steps cities, the
        // taskbar's rule.
        if (self.popup.kind == .world_clock and self.onPopupSurface()) {
            self.applyWcOutcome(wc_panel.scroll(&self.wc, &self.popup.wc_geom, delta));
            return;
        }
        if (self.wc_init and self.hover != no_slot and self.hover < self.strip.slots.len and
            self.strip.slots[self.hover].kind == .world_clock)
        {
            const dir: i32 = if (delta < 0) -1 else 1;
            if (self.wc.go(dir, true, Dock.epochMs())) {
                self.armAnim();
                self.repaint();
            }
            return;
        }
        if (self.popup.kind != .launcher) return;
        const step = std.math.clamp(delta * launcher_wheel_scale, -launcher_wheel_max, launcher_wheel_max);
        if (self.launcher.axis(step)) self.popupRefresh();
    }

    /// Arms the one-shot 16 ms animation tick. Created lazily so a dock that
    /// is never hovered pays nothing.
    fn armAnim(self: *Dock) void {
        if (self.anim_fd < 0) {
            const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
            if (rc < 0) return;
            const fd: i32 = @intCast(rc);
            self.app.loop.watchFd(fd, std.posix.POLL.IN, onAnimTick, @ptrCast(self)) catch {
                _ = linux.close(fd);
                return;
            };
            self.anim_fd = fd;
        }
        self.armTick(k_anim_frame_ns);
    }

    /// Re-arm the one-shot tick to `nsec` from now. The nearest of the
    /// callers' deadlines wins, which is how the hover lift, the start menu
    /// and the media widget all share a single timerfd.
    fn armTick(self: *Dock, nsec: u64) void {
        if (self.anim_fd < 0) {
            const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
            if (rc < 0) return;
            const fd: i32 = @intCast(rc);
            self.app.loop.watchFd(fd, std.posix.POLL.IN, onAnimTick, @ptrCast(self)) catch {
                _ = linux.close(fd);
                return;
            };
            self.anim_fd = fd;
        }
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = @intCast(@max(1, @min(nsec, 999_999_999))) },
        };
        _ = linux.timerfd_settime(self.anim_fd, .{}, &its, null);
    }

    fn onAnimTick(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        // A `wl_display_flush` that failed with EAGAIN left a commit stranded
        // in the client buffer. The compositor never saw it, so it will never
        // send the `wl_buffer.release` that would free a slot — and with both
        // slots busy every later frame drops forever. That is the freeze, and
        // this retry is the way out: the tick that `present` armed is what
        // pushes the stuck bytes once the socket has drained. If the flush
        // still cannot go out, re-arm so the dock keeps trying on its own
        // rather than waiting for a pointer event that may never come.
        if (self.flush_pending) {
            if (self.app.conn.flush()) {
                self.flush_pending = false;
            } else {
                self.armTick(k_anim_frame_ns);
            }
        }
        // The start menu is the only thing that moves without being touched:
        // its caret blinks and its list eases toward where the wheel left it.
        // It therefore keeps the tick alive for as long as it is up, and it
        // repaints the *panel* rather than the strip — a dock that has not
        // changed has no reason to redraw 60 times a second.
        if (self.popup.kind == .launcher) {
            if (self.launcher.tick()) self.popupRefresh();
            // Icons the last paint could not answer from cache warm here,
            // off the keystroke path; the frames in which they arrive show
            // them pop in without a keypress ever paying for a decode.
            if (self.launcher.prefetchIcons(8)) self.popupRefresh();
            self.armAnim();
            if (self.rebuildIfDirty()) self.repaint();
            return;
        }

        const now_ns = anim.monotonicNs();
        const now_ms: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
        // Nearest re-arm deadline, in nanoseconds; 0 means "nothing wants the
        // tick again", which is what lets an idle dock go back to sleep.
        var next: u64 = 0;
        var dirty = false;
        var card_dirty = false;

        // The media widget keeps its own clock. MPRIS pushes `Position` only
        // when asked, so this 400 ms read is also what makes the progress
        // border and the seekbar advance; and the marquee has no event at
        // all, being a pure function of time. Neither can wait on the seat,
        // so both are driven from here and re-armed to the nearer deadline.
        // A dock with the widget switched off skips the lot and keeps its
        // right to sleep.
        if (self.hasMediaSlot()) {
            if (now_ms >= self.media_next_ms) {
                const changed = self.pollMedia();
                if (changed) {
                    self.relayoutStrip();
                    dirty = true;
                }
                // Note: animation frames (marquee/progress ring) are owned by
                // the tick arm below at their own cadence; forcing dirty here
                // too would double the repaint rate.
                // The read pushed its own deadline out, and that deadline is
                // a reason to wake on its own. Without this the tick would be
                // re-armed by nothing at all and the dock would sleep through
                // every later read — the playhead would then only appear to
                // move when a pointer event happened to repaint the strip, and
                // an open card would hold the position it was opened with.
                const due_ms = self.media_next_ms -| nowMs();
                next = @max(1, due_ms) * std.time.ns_per_ms;
            } else {
                next = (self.media_next_ms - now_ms) * std.time.ns_per_ms;
            }
        }

        if (self.lift.step(now_ns)) {
            next = if (next == 0) k_anim_frame_ns else @min(next, k_anim_frame_ns);
            dirty = true;
        }

        // The world clock: the face's slide runs on this tick, and so does
        // the panel's own easing (the open transition, the switch flips, the
        // row-hover fade). The frame a transition *ends* on is still drawn —
        // it is the one that lands at rest.
        if (self.wc_init) {
            const epoch = Dock.epochMs();
            if (self.wc.slide.active) {
                const still = self.wc.tickAnim(epoch);
                dirty = true;
                if (still) next = if (next == 0) k_anim_frame_ns else @min(next, k_anim_frame_ns);
            }
            if (self.popup.kind == .world_clock) {
                const moving = wc_panel.animActive(&self.wc, epoch);
                if (moving or self.wc_anim_prev) {
                    card_dirty = true;
                    self.wc_anim_prev = moving;
                    if (moving) next = if (next == 0) k_anim_frame_ns else @min(next, k_anim_frame_ns);
                }
            } else {
                self.wc_anim_prev = false;
            }
        }

        // The control-center panels ease open/closed over 200 ms, and a
        // pointer sitting still after the click generates no further event
        // to repaint them with — so the tick owns those frames, the way the
        // The frame pump picks up subsequent frames after a
        // toggle. The frame the ease runs out on is also the frame the
        // surface is re-placed at its resting height, matching
        // `popup_finish_draw` settling right behind the animation.
        if (self.cc.open and self.cc.animActive()) {
            self.cc.relayout(now_ms, false);
            self.ccRefresh();
            if (!self.cc.animActive()) self.ccSettleResize(now_ms);
            next = if (next == 0) k_anim_frame_ns else @min(next, k_anim_frame_ns);
        }

        const card_up = self.popup.kind == .media_player;
        if (card_up) {
            self.syncMediaPopup();
            card_dirty = true;
        }
        if (card_up or self.media_wants_marquee or self.media_progress_tick) {
            // Name why this frame happens; the profiler summary prints the
            // last reason next to the paint cost so cadence has a cause.
            const perf = media_perf.get(.dock);
            if (card_up) {
                perf.noteReason("card");
            } else if (self.media_wants_marquee) {
                perf.noteReason("marquee");
            } else {
                perf.noteReason("ring");
            }
            // The open card and scrolling text keep 30fps; the progress ring
            // runs at the 16ms frame cadence (measured whole-bar cost ~2ms,
            // see k_media_progress_ns) so the dash has no visible stepping.
            const frame_ns = if (self.media_progress_tick and !self.media_wants_marquee and !card_up)
                k_media_progress_ns
            else
                k_media_frame_ns;
            next = if (next == 0) frame_ns else @min(next, frame_ns);
            if (self.media_wants_marquee or self.media_progress_tick) dirty = true;
        }

        if (self.rebuildIfDirty()) dirty = true;
        if (card_dirty) self.popupRefresh();
        if (next > 0) self.armTick(next);
        if (dirty) self.repaint();
    }

    /// `ext_foreign_toplevel_list_v1` batches property updates behind `done`;
    /// a new window appearing is exactly when the dot should light up.
    fn onToplevelsChanged(ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        // `isRunning` compares these against the dock slot's key, so logging
        // them is how a dark indicator is diagnosed: if the ids never line up,
        // the dot can never light.
        var ids: [16][]const u8 = undefined;
        var n: usize = 0;
        for (self.toplevels.windows.items) |w| {
            if (n >= ids.len) break;
            if (w.closed or w.app_id.len == 0) continue;
            ids[n] = w.app_id;
            n += 1;
        }
        var joined: [600]u8 = undefined;
        logz.log(
            "toplevels: {d} known, {d} with an app_id: {s}",
            .{ self.toplevels.windowCount(), n, joinList(&joined, ids[0..n]) },
        );
        // The dot is answered at paint time by `isRunning`, so it lights in
        // this same frame. The *slot list* only changes when an app that is
        // not pinned starts (or the last one closes), and rebuilding that
        // does icon I/O — defer it to the 16 ms tick rather than doing file
        // work inside the dispatch callback. The signature check keeps title
        // churn from queuing rebuilds at all.
        const sig = runningSignature(&self.toplevels);
        if (sig != self.running_sig) {
            self.dirty_src = "toplevels";
            self.dirty = true;
            self.armAnim();
        }
        self.repaint();
    }

    /// Rebuilds the strip after a toplevel change. Returns true when the
    /// model actually changed, because that is the only case where the layer
    /// surface may have to resize.
    fn rebuildIfDirty(self: *Dock) bool {
        if (!self.dirty) return false;
        self.dirty = false;
        self.buildModel();
        const want = self.desiredSize();
        if (want.w != self.req_w or want.h != self.req_h) self.applySize();
        self.layout();
        // `freeModel` clears the hover, but the pointer is probably still
        // sitting on the same slot — re-pick it so the highlight does not
        // blink off every time a window opens.
        const pos = lastPointer(self);
        self.hover = self.slotAt(pos[0], pos[1]);
        if (self.hover != no_slot and self.hover < self.strip.slots.len and liftEligible(self.strip.slots[self.hover].kind)) {
            if (self.lift.value < anim.kHoverLiftPx) {
                self.lift.begin(anim.kHoverLiftPx, anim.monotonicNs(), anim.kHoverLiftNs);
                self.armAnim();
            }
        }
        return true;
    }

    fn lastPointer(self: *Dock) struct { f64, f64 } {
        if (self.app.bound.seat_obj) |seat| return .{ seat.pointer_x, seat.pointer_y };
        return .{ 0, 0 };
    }

    // -----------------------------------------------------------------
    // Event hooks
    // -----------------------------------------------------------------

    fn onConfigure(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        const nw: i32 = @intCast(w);
        const nh: i32 = @intCast(h);
        if (nw <= 0 or nh <= 0) return;
        if (nw == self.buf_w and nh == self.buf_h and self.shm.ready()) return;
        logz.log("configure: {d}x{d}", .{ nw, nh });
        self.buf_w = nw;
        self.buf_h = nh;
        // `buf_w`/`buf_h` stay logical (every paint site and the layout use
        // them as such); only the buffer itself is allocated at device pixels.
        if (!self.shm.ensure(self.app.bound.shm, "dock", nw * self.surface.scale, nh * self.surface.scale)) return;
        self.layout();
        self.repaint();
    }

    /// Output scale changed (surface moved to a different-DPI output). Logical
    /// geometry is untouched; re-allocate the buffer at the new device size and
    /// redraw.
    fn onScale(ctx: *anyopaque, scale: i32) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        _ = scale; // already stored on the surface by the listener
        if (self.buf_w <= 0 or self.buf_h <= 0) return;
        logz.log("dock: output scale changed -> {}x", .{self.surface.scale});
        if (!self.shm.ensure(self.app.bound.shm, "dock", self.buf_w * self.surface.scale, self.buf_h * self.surface.scale)) return;
        self.repaint();
    }

    /// The menu's own configure. `layer.Surface` acks before this runs, so the
    /// first call is the first moment a buffer the compositor will accept can
    /// exist — a layer surface has to commit without one to be configured at
    /// all.
    fn onPopupConfigure(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        // The launcher's geometry is derived, not baked: the card is as wide
        // and as tall as the surface the compositor actually granted, and its
        // hit tests read the same `Geo` the paint does. Asked-for and granted
        // sizes agree on a screen that has room, and disagree politely on one
        // that has not.
        if (self.popup.kind == .launcher and w > 0 and h > 0) {
            // The surface is `fit` smaller than the natural `geo`, so the
            // granted size is converted back before it reaches the model —
            // otherwise a 720p grant would shrink the layout constants too.
            const f = self.launcher.fit;
            self.launcher.sizeTo(@as(f64, @floatFromInt(w)) / f, @as(f64, @floatFromInt(h)) / f);
        }
        self.popup.configured(self.app.bound.shm);
        if (!self.app.conn.flush()) logz.log("menu: flush failed after configure", .{});
    }

    fn onCcConfigure(ctx: *anyopaque, _: u32, _: u32) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        self.cc.configured(self.app.bound.shm);
        if (!self.app.conn.flush()) logz.log("control-center: flush failed after configure", .{});
    }

    /// Hyprland refuses a layer surface that will not fit. Dropping `open`
    /// here keeps the input side from aiming clicks at a surface that is gone.
    fn onPopupClosed(ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        logz.log("menu: closed by the compositor", .{});
        // The model outlives the surface, and a close it did not ask for still
        // has to leave it in the state a fresh open starts from.
        if (self.popup.kind == .launcher) self.launcher.reset();
        self.popup.reset();
    }

    fn onCcClosed(ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        logz.log("control-center: closed by the compositor", .{});
        self.cc.reset();
    }

    fn onPearConfigure(ctx: *anyopaque, _: u32, _: u32) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        self.pear.configured(self.app.bound.shm);
        if (!self.app.conn.flush()) logz.log("pear: flush failed after configure", .{});
    }

    fn onPearClosed(ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        logz.log("pear: closed by the compositor", .{});
        self.pear.reset();
    }

    /// The `[dock] output` value as an entry rather than just a handle.
    /// `Auto`, `All`, and any name this machine does not have all collapse to
    /// null, which is what `zwlr_layer_shell_v1.get_layer_surface` takes to
    /// mean "the compositor picks" — `Auto` being what the Dock tab's Display
    /// row spells it as. `All` really is one surface today: the Zig dock is a
    /// dock, not one dock per display.
    ///
    /// The entry rather than the `wl_output` because a popup has to be
    /// positioned against the output's *geometry*, not merely created on it.
    fn outputEntryForName(outputs: []const *out_mod.Output, name: []const u8) ?*out_mod.Output {
        const want = std.mem.trim(u8, name, " \t\r\n");
        if (want.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(want, "Auto") or std.ascii.eqlIgnoreCase(want, "All")) return null;
        for (outputs) |o| {
            if (std.ascii.eqlIgnoreCase(o.name, want)) return o;
        }
        return null;
    }

    /// The output the popup layer is positioned against, which is wherever the
    /// dock itself landed. A pinned display gives the exact entry; `Auto` leaves
    /// the compositor to choose and tell nobody, so the first display it
    /// advertised stands in — right whenever there is only one, and a coin flip
    /// otherwise. The alternative is to not place the panel over its slot at
    /// all, which is wrong on *every* machine rather than on half of them.
    fn positionOutput(self: *Dock) ?*out_mod.Output {
        if (self.output_entry) |e| return e;
        const outs = self.app.bound.outputs.items;
        if (outs.len > 0) return outs[0];
        return null;
    }

    /// How wide that output is in the surface units popups are addressed in.
    /// `wl_output.mode` reports the mode in hardware pixels, so a scaled
    /// display's logical width is smaller than the number it sends — and the
    /// layer-shell margins a popup is placed with are logical. 0 means the
    /// compositor has not told us yet, which `popup_position` handles by
    /// clamping against the dock alone.
    fn outputLogicalW(self: *Dock) f64 {
        const o = self.positionOutput() orelse return 0;
        if (o.width <= 0 or o.scale <= 0) return 0;
        return @as(f64, @floatFromInt(o.width)) / @as(f64, @floatFromInt(o.scale));
    }

    /// Remember what the live surface was pinned to. Kept separate from the
    /// config because the config is the thing that *changes*: comparing
    /// against it is how `onReload` tells a display switch from any other
    /// edit without recreating the surface 60 times a session.
    fn setOutputWant(self: *Dock, name: []const u8) void {
        const gpa = self.app.gpa;
        const copy = gpa.dupe(u8, name) catch return;
        if (self.output_want.len > 0) gpa.free(self.output_want);
        self.output_want = copy;
    }

    /// Move the dock to whatever `[dock] output` now names. A layer surface
    /// cannot be retargeted, so this is a destroy-and-recreate with every
    /// boot-time setting reapplied — anchor, exclusive zone, size, configure
    /// handler — which is the same sequence `main` runs. The compositor then
    /// sends a fresh configure for the new output, and `onConfigure` resizes
    /// the buffer if that display is not the same size as the old one.
    fn rebindOutput(self: *Dock) void {
        const name = self.app.loaded.cfg.dock.output_name;
        if (std.mem.eql(u8, name, self.output_want)) return;
        const entry = Dock.outputEntryForName(self.app.bound.outputs.items, name);
        const obj = if (entry) |e| e.obj else null;
        self.output_entry = entry;
        self.setOutputWant(name);
        logz.log("output: moving the dock to '{s}'{s}", .{
            name,
            if (obj == null) " (compositor's choice)" else "",
        });
        // Rebuild against the new output: the fit factor (icon/bar/radius/
        // gap) is derived from `output_entry`'s logical height, so the model
        // must be recomputed or the dock keeps the old display's metrics.
        self.buildModel();

        self.surface.destroy();
        if (!self.surface.create(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            obj,
            // TOP, matching the C++ dock. The desktop is BOTTOM and
            // recreated after us when it restarts; keeping both on BOTTOM
            // put the desktop's full-screen input region above the dock.
            .top,
            ns.dock,
        )) {
            logz.err("output: could not recreate the layer surface", .{});
            return;
        }
        self.surface.setAnchor(layer.Anchor.bottom);
        self.surface.on_configure = Dock.onConfigure;
        self.surface.on_scale = Dock.onScale;
        self.surface.ctx = self;
        const size = self.desiredSize();
        self.req_w = size.w;
        self.req_h = size.h;
        self.syncExclusive();
        self.surface.setSize(@intCast(size.w), @intCast(size.h));
        self.surface.commit();

        var ticks: u32 = 0;
        while (ticks < 100 and !self.surface.configured) : (ticks += 1) {
            if (!self.app.conn.roundtrip()) break;
        }
        if (!self.surface.configured) {
            logz.err("output: the new layer surface was never configured", .{});
            return;
        }
        if (self.buf_w <= 0 or self.buf_h <= 0) {
            Dock.onConfigure(self, self.surface.configured_width, self.surface.configured_height);
        }
        // A fresh surface has no buffer attached even when its size is
        // unchanged, so this repaint is not conditional on the size moving.
        self.layout();
        self.repaint();
    }

    fn onReload(ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        logz.log("reload: config changed, rebuilding", .{});
        {
            const dcfg = &self.app.loaded.cfg.dock;
            eh.diag.log(
                "dock.on_reload: opacity={d} show_dock={} radius={d} icon_size={d} liquid_glass={} colored_glass={}",
                .{
                    dcfg.dock_opacity,
                    dcfg.dock_show_dock,
                    dcfg.dock_radius,
                    dcfg.dock_icon_size,
                    dcfg.dock_liquid_glass,
                    dcfg.dock_colored_glass,
                },
            );
        }
        // The icon theme may have changed; re-point the shared cache (a no-op
        // when it did not, and a full clear + generation bump when it did).
        if (icon_cache.shared()) |ic| {
            const cfg = &self.app.loaded.cfg;
            ic.setTheme(if (cfg.dock.icon_theme.len > 0)
                cfg.dock.icon_theme
            else
                eh.icon_themes.detectSystemIconTheme(self.app.io) orelse "hicolor");
        }
        // Whatever a drag in flight had worked out points at the pin list that
        // just went away; the drop would write an order for a config that no
        // longer exists. The new file is the truth now.
        self.pin_drag.deinit(self.app.gpa);
        // The world-clock list lives in `<leaf>/world_clock.json`, inside the
        // settings dir this reload was triggered by, so a save from
        // Settings > Time must land in the dock's widget too. `reload` keeps
        // the session's *own* save (a popup switch, back through the same
        // watcher) a no-op, so an open card is only re-presented when the list
        // really moved.
        if (self.wc_init and self.wc.reload() and self.popup.open and self.popup.kind == .world_clock) {
            self.wcResettle();
        }
        self.buildModel();
        self.rebindOutput();
        // A `show_dock`/`autohide` flip with an unchanged size still moves the
        // exclusive zone, and `applySize` below only runs when the size moved.
        self.syncExclusive();
        self.syncInputRegion();
        const want = self.desiredSize();
        if (want.w != self.req_w or want.h != self.req_h) self.applySize();
        self.layout();
        self.repaint();
        // The drawer's view mode and nightlight state come from the config:
        // a launcher that is up right now follows the change in place
        // instead of waiting for the next open. The rail is list-only, so
        // the mode only reaches the classic panel.
        if (self.launcher.style == .classic) {
            self.launcher.setListMode(self.app.loaded.cfg.appearance.launchpad_view_mode == 1);
        }
        self.launcher.setNight(self.app.loaded.cfg.night_light.enabled);
        if (self.popup.kind == .launcher) self.popupRefresh();
        // The settings app may have just rewritten `[weather]`/`[time]`, so
        // drop the 15-minute cache and refetch on the next tick rather than
        // showing a value from the old configuration.
        self.wx_next_ms = 0;
    }

    /// How often a healthy reading is refreshed, and how long a failed one
    /// waits before it is tried again. Weather does not move fast; a minute
    /// is enough to outlast "the network was not up yet" at login.
    const kWeatherIntervalMs: i64 = 15 * 60 * 1000;
    const kWeatherRetryMs: i64 = 60 * 1000;

    /// Drains the weather worker and starts the next fetch when one is due.
    /// The request itself runs on its own thread because `std.http.Client`
    /// blocks and this is the compositor's input path. Returns true when a
    /// reading landed, since the slot's width depends on how many digits the
    /// temperature has.
    fn pollWeather(self: *Dock) bool {
        const now_ms: i64 = @intCast(@divTrunc(anim.monotonicNs(), 1_000_000));
        var rd: weather.Reading = .{};
        if (weather.take(&rd)) {
            if (rd.available) {
                self.applyWeather(&rd);
                self.wx_next_ms = now_ms + kWeatherIntervalMs;
                logz.log("weather: {d}°{c} {s} ({s})", .{
                    rd.temp,
                    @as(u8, if (rd.fahrenheit) 'F' else 'C'),
                    rd.glyph,
                    rd.placeName(),
                });
            } else {
                self.wx_next_ms = now_ms + kWeatherRetryMs;
                logz.err("weather: fetch failed, next attempt in {d}s", .{@divTrunc(kWeatherRetryMs, 1000)});
            }
            if (self.weatherSlot() == null) return false;
            return rd.available;
        }
        if (self.weatherSlot() == null) return false;
        if (now_ms < self.wx_next_ms) return false;
        if (weather.request(self.app.gpa, self.app.io, self.weatherRequest())) {
            self.wx_next_ms = now_ms + kWeatherIntervalMs;
        } else {
            // A spawn failure would otherwise be retried every tick, which
            // turns one allocator problem into a log flood.
            self.wx_next_ms = now_ms + kWeatherRetryMs;
        }
        return false;
    }

    /// The four widget settings a fetch reads, snapshotted out of the
    /// arena-backed config *before* a thread can see it — `App.reload` frees
    /// that arena without asking anyone.
    fn weatherRequest(self: *Dock) weather.Request {
        const cfg = &self.app.loaded.cfg;
        const id = self.weatherSlot() orelse return .{};
        const unit = wset.widgetSetting(cfg, id, "weather_unit");
        return .{
            .lat = wset.widgetSetting(cfg, id, "weather_lat"),
            .lon = wset.widgetSetting(cfg, id, "weather_lon"),
            .city = wset.widgetSetting(cfg, id, "weather_city"),
            .fahrenheit = unit.len > 0 and (unit[0] == 'f' or unit[0] == 'F'),
        };
    }

    /// The first weather slot's key, which doubles as its widget instance id
    /// — the same string `widgetSetting` looks up.
    fn weatherSlot(self: *Dock) ?[]const u8 {
        for (self.strip.slots) |s| {
            if (s.kind == .weather) return s.key;
        }
        return null;
    }

    /// Push a finished reading into `weather_paint`'s host slot. The glyph is
    /// copied into `wx_glyph` first, because `State.icon` is borrowed and the
    /// paint pass reads it on every frame.
    fn applyWeather(self: *Dock, rd: *const weather.Reading) void {
        const n = @min(rd.glyph.len, self.wx_glyph.len);
        if (n > 0) @memcpy(self.wx_glyph[0..n], rd.glyph[0..n]);
        self.wx_glyph_len = @intCast(n);
        wpaint.state = .{
            .available = true,
            .temp = rd.temp,
            .fahrenheit = rd.fahrenheit,
            .icon = self.wx_glyph[0..self.wx_glyph_len],
        };
        // The card reads the same reading, but keeps the strings it borrows
        // in `wx_reading` so they outlive this call.
        self.wx_reading = rd.*;
        fancy.state = .{
            .available = true,
            .temp = rd.temp,
            .hi = rd.hi,
            .lo = rd.lo,
            .feels_like = rd.feels_like,
            .humidity_pct = rd.humidity_pct,
            .wind_kmh = rd.wind_kmh,
            .visibility_m = rd.visibility_m,
            .icon = self.wx_glyph[0..self.wx_glyph_len],
            .city = self.wx_reading.placeName(),
            .condition = self.wx_reading.conditionText(),
            .n_days = rd.n_days,
        };
        for (0..5) |i| {
            fancy.state.days[i] = .{
                .icon = rd.days[i].glyph,
                .hi = rd.days[i].hi,
                .lo = rd.days[i].lo,
                .wday = rd.days[i].wday,
            };
        }
    }

    fn onTimer(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        app_launch.reap();
        // Closed windows are only reclaimable outside a listener callback.
        self.toplevels.pruneClosed();
        self.ft.pruneClosed();
        // The bus fd is watched separately, but this tick is also where the
        // tray's periodic re-read of the registration list lands — it is the
        // safety net for signals that a blocking call may have swallowed.
        if (self.pumpTray()) {
            self.dirty_src = "tray";
            self.dirty = true;
        }
        // Workspaces follow the compositor on a throttle: a changed
        // snapshot rebuilds through the normal dirty path below.
        if (self.reloadWorkspaces(false)) {
            self.dirty_src = "workspaces";
            self.dirty = true;
        }
        // Safety net: the 16 ms animation tick should already have rebuilt,
        // but a queued rebuild must never be able to get stuck waiting.
        const rebuilt = self.rebuildIfDirty();
        // The world clock's own second, if the widget is on the strip: the
        // face rotates every 5 s, slides, and the panel (when up) advances.
        const wc_due = self.tickWorldClock();
        const wx_changed = self.pollWeather();
        const now_ms: u64 = @intCast(@divTrunc(anim.monotonicNs(), std.time.ns_per_ms));
        // Live backends (throttled inside) + `signatureChanged`: repaint the
        // pill only when its inputs moved; a width change needs a relayout.
        // An open popup refreshes its snapshot off the same poll.
        const cc_changed = self.pollCcLive(now_ms, false);
        const bat_changed = self.pollBattery(now_ms);
        // The VPN list rides its own worker. Taking the result *and* starting
        // the next read both live here rather than inside the cc poll above,
        // which has its own throttle and its own early returns: a read that
        // finished while it was holding off still has to be adopted. The card
        // is redrawn off the same adoption, or re-opened when the row count
        // moved the height it was sized for; the warm cache just updates.
        const vpn_changed = self.takeVpnRows();
        if (vpn_changed and self.popup.kind == .vpn) {
            if (!self.settleWidgetCard()) self.popupRefresh();
        }
        self.pollVpn(now_ms);
        // The mixer rides its own worker too, and for the same reason: every
        // reading is a handful of spawns. Adopting comes first — a read that
        // finished while the card was up has to be shown whatever the poll
        // below decides about the next one — and the redraw is the card's.
        if (self.takeMixer(now_ms)) {
            if (self.popup.kind == .volume_mixer) self.popupRefresh();
        }
        self.pollMixer(now_ms);
        if (!rebuilt and (wc_due or self.refreshLabel() or wx_changed or cc_changed or bat_changed)) {
            self.computeWidths();
            const want = self.desiredSize();
            if (want.w != self.req_w or want.h != self.req_h) self.applySize();
            self.layout();
        }
        // Warm screen shots for the overview, refreshed on a slow cadence:
        // opening then paints the cached thumbnails instantly while the
        // live pass replaces them with fresh captures. One pass costs
        // ~250ms of synchronous screencopy on the main thread, so it runs
        // every 8s (still under the 10s cache-freshness limit) and never
        // while the user is interacting with the bar.
        self.shot_tick +%= 1;
        if (self.shot_tick >= 8) {
            self.shot_tick = 0;
            const busy = self.ptr_on != .none or self.popup.kind != .none or
                self.pin_drag.dragging or self.lift.running or self.pending or
                self.cc.open or self.pear.open;
            if (!busy) self.prefetchShots();
        }
        // A live control-center popup follows the weather card the same way.
        if (self.cc.open and wx_changed and !cc_changed) {
            const snap = self.buildCcSnapshot();
            self.cc.setSnapshot(snap);
            self.cc.relayout(now_ms, false);
            self.ccRefresh();
        }
        self.repaint();
    }

    /// Reads everything the session bus has for us. Returns true when the
    /// tray item list changed, which is the only thing that needs a model
    /// rebuild — the caller turns that into `dirty`.
    fn pumpTray(self: *Dock) bool {
        if (!self.tray.live) return false;
        // Both sides are `CLOCK_MONOTONIC`: `anim.monotonicNs` and
        // `sock.nowMs` are the same clock in different units, which is what
        // the tray's resync deadline is measured against.
        const now_ms: i64 = @intCast(@divTrunc(anim.monotonicNs(), 1_000_000));
        return self.tray.pump(now_ms);
    }

    fn onBusFd(_: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Dock = @ptrCast(@alignCast(ctx));
        const interesting = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if ((revents & interesting) == 0) return;
        if (!self.pumpTray()) return;
        self.dirty_src = "tray-signal";
        self.dirty = true;
        // Same 16 ms deflection as a toplevel change: the rebuild resolves
        // every icon, and this can land between two pointer events.
        self.armAnim();
        self.repaint();
    }

    /// One warm-shot pass for the overview's cache: a thumbnail per output
    /// through wlr-screencopy, every wait bounded. Loop level only — the
    /// copies dispatch on their own — and silent unless something landed.
    fn prefetchShots(self: *Dock) void {
        const t0 = Dock.nowMs();
        const gpa = self.app.gpa;
        const dir = shot_cache.dirPath(gpa, self.app.io, getenvStr("XDG_CACHE_HOME"), getenvStr("HOME")) orelse return;
        defer gpa.free(dir);
        const n = shot_cache.prefetch(
            gpa,
            self.app.io,
            self.app.conn.display,
            self.app.bound.screencopy,
            self.app.bound.shm,
            self.app.bound.outputs.items,
            dir,
        );
        if (n > 0) logz.log("dock: overview shots prefetched={d} in {d}ms", .{ n, Dock.nowMs() - t0 });
    }

    fn startTimer(self: *Dock) void {
        const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
        if (rc < 0) return;
        const fd: i32 = @intCast(rc);
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 1, .nsec = 0 },
            .it_value = .{ .sec = 1, .nsec = 0 },
        };
        if (linux.timerfd_settime(fd, .{}, &its, null) != 0) {
            _ = linux.close(fd);
            return;
        }
        self.app.loop.watchFd(fd, std.posix.POLL.IN, onTimer, @ptrCast(self)) catch {
            _ = linux.close(fd);
            return;
        };
        self.timer_fd = fd;
        // The media widget has no event of its own to wait for: its first
        // poll is already due, so the shared one-shot starts the clock.
        self.armAnim();
    }
};

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    // `EH_ZIG_ISOLATED=1` points every settings path at `Event-Horizon-zig`
    // so testing never touches the live shell's files. Must run before any dir
    // resolution below (including `App.init`'s layered load).
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;

    logz.init(io, init.environ_map.get("HOME"), "horizon-dock-zig");
    defer logz.deinit();
    logz.log(
        "boot: pid={d} wayland={s} display={s}",
        .{
            linux.getpid(),
            if (init.environ_map.get("WAYLAND_DISPLAY")) |w| w else "?",
            if (init.environ_map.get("XDG_SESSION_TYPE")) |t| t else "?",
        },
    );

    var a = app.App.init(
        gpa,
        io,
        init.environ_map.get("XDG_CONFIG_HOME"),
        init.environ_map.get("HOME"),
    ) catch |e| {
        logz.err("init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer a.deinit();

    // The shared icon cache indexes every theme directory once and answers
    // later lookups from memory, so a strip rebuild never re-probes the
    // filesystem (which cost ~109ms per icon before). It is keyed to the
    // dock's icon theme; `onReload` re-points it if the theme changes.
    icon_cache.initGlobal(gpa, io);
    defer icon_cache.deinitGlobal();
    if (icon_cache.shared()) |ic| {
        const t: []const u8 = if (a.loaded.cfg.dock.icon_theme.len > 0)
            a.loaded.cfg.dock.icon_theme
        else
            eh.icon_themes.detectSystemIconTheme(io) orelse "hicolor";
        ic.setTheme(t);
    }

    var dock = Dock{
        .app = &a,
        .shm = shm_mod.ShmPair.init(gpa),
        .tray = tray_source.Source.init(gpa),
        .ft = ftl.ForeignToplevels.init(gpa),
        .popup = popup_mod.Host.init(gpa),
        .launcher = launcher_menu.Menu.init(gpa, io),
        .cc = cc_host.Host.init(gpa),
        .pear = pear_host.Host.init(gpa),
        .media = mpris_client.Client.init(gpa),
        .notif_push = notify_push.Publisher.init(gpa),
        .notif_stats = notify_stats.Stats.init(@as(i64, @intCast(Dock.nowMs()))),
        .vpn_store = vpn_popup.Store.init(gpa),
    };
    defer dock.deinit();
    // World clock: the widget's own session, loaded before the first strip
    // build so the first frame already has the user's cities (the taskbar's
    // session reads the same file, so both bars show the same clocks).
    dock.wc = wc_session.Session.init(gpa, io);
    dock.wc_init = true;
    dock.wc.load();
    // Idle-inhibit manager behind the pear redeye toggle.
    dock.redeye_inhibit.setManager(a.bound.idle_inhibit_manager);
    dock.toplevels = foreign.Tracker.init(gpa);
    dock.toplevels.on_changed = Dock.onToplevelsChanged;
    dock.toplevels.changed_ctx = &dock;
    dock.ws_anim = ws_paint.AnimState.init(gpa);
    dock.ws_surfs = std.StringHashMap(WsSurf).init(gpa);
    dock.ws_surfs_init = true;
    // `wl_buffer.release` is what tells us the compositor let a buffer go. It
    // drives two recoveries that otherwise leave the dock frozen: drawing a
    // frame that was owed because both buffers were held, and re-flushing a
    // commit that a full socket refused (see `Dock.onShmRelease`). The hook
    // lives on the buffer structs, so it survives the resize that recreates
    // them.
    dock.shm.setReleaseHook(Dock.onShmRelease, @ptrCast(&dock));
    // `ext_foreign_toplevel_list_v1` is what tells the dock an app is running.
    // The first dump went out during `App.init`'s roundtrip, before this
    // process had a listener, so ask for it again and only then attach one.
    a.conn.rebindToplevelList(&a.bound);
    if (a.bound.foreign_toplevel_list) |list| dock.toplevels.bindExt(list);
    logz.log(
        "globals: outputs={d} seat={s} foreign_toplevel_list={s}",
        .{
            a.bound.outputs.items.len,
            if (a.bound.seat_obj != null) "bound" else "MISSING (no pointer input)",
            if (a.bound.foreign_toplevel_list != null)
                "bound"
            else
                "MISSING (compositor has no ext_foreign_toplevel_list_v1, indicators cannot light)",
        },
    );

    // The wlr manager announces every window that already exists exactly once,
    // right after it is bound, and `App.init`'s roundtrip has already spent
    // that dump. Rebind so the whole list lands on a listener that exists —
    // the same trick `rebindToplevelList` uses above — then roundtrip so the
    // handles are in hand before the first click.
    a.conn.rebindForeignToplevelManager(&a.bound);
    if (a.bound.foreign_toplevel_manager) |mgr| dock.ft.attach(mgr, a.conn.display);
    if (!a.conn.roundtrip()) logz.log("focus: toplevel roundtrip failed; clicks fall back to launching", .{});
    logz.log(
        "focus: zwlr_foreign_toplevel_manager_v1 {s}, {d} window(s) known",
        .{
            if (a.bound.foreign_toplevel_manager != null)
                "bound"
            else
                "MISSING (clicking a running app relaunches it)",
            dock.ft.size(),
        },
    );

    a.on_reload = Dock.onReload;
    a.reload_ctx = &dock;

    // Resolve the target output *before* the first build: `buildModel`
    // derives the fit factor (icon/bar/radius/gap) from `output_entry`'s
    // logical height, so it must be set or the first frame sizes for 1440.
    const dock_entry = Dock.outputEntryForName(a.bound.outputs.items, a.loaded.cfg.dock.output_name);
    dock.output_entry = dock_entry;

    // The tray is a session-bus client whose startup can stall for seconds
    // on a busy bus, so it connects *after* the first frame is on screen
    // (see below): the model is built tray-less here and the section fills
    // in on the rebuild after the late start. No bus is not fatal — the
    // dock just runs with no tray section until the watcher answers.
    dock.buildModel();
    const want = dock.desiredSize();

    const dock_output = if (dock_entry) |e| e.obj else null;
    // TOP, matching the C++ dock. A restarted desktop recreates its BOTTOM
    // surfaces after us; same-layer ordering would put its full-screen input
    // region over the dock and make the bar unclickable.
    if (!dock.surface.create(a.bound.compositor, a.bound.layer_shell, dock_output, .top, ns.dock)) {
        logz.err("layer surface create failed", .{});
        return 1;
    }
    dock.setOutputWant(a.loaded.cfg.dock.output_name);
    logz.log("output: dock pinned to '{s}'{s}", .{
        a.loaded.cfg.dock.output_name,
        if (dock_output == null) " (compositor's choice)" else "",
    });
    // Bottom only: the compositor centres the unanchored horizontal axis, so
    // the surface's own width positions it — which is what the pill wants.
    dock.surface.setAnchor(layer.Anchor.bottom);
    dock.surface.on_configure = Dock.onConfigure;
    dock.surface.on_scale = Dock.onScale;
    dock.surface.ctx = &dock;
    dock.popup.surface.on_configure = Dock.onPopupConfigure;
    dock.popup.surface.on_closed = Dock.onPopupClosed;
    dock.popup.surface.ctx = &dock;
    dock.cc.surface.on_configure = Dock.onCcConfigure;
    dock.cc.surface.on_closed = Dock.onCcClosed;
    dock.cc.surface.ctx = &dock;
    dock.pear.surface.on_configure = Dock.onPearConfigure;
    dock.pear.surface.on_closed = Dock.onPearClosed;
    dock.pear.surface.ctx = &dock;
    dock.req_w = want.w;
    dock.req_h = want.h;
    dock.syncExclusive();
    dock.syncInputRegion();
    dock.surface.setSize(@intCast(want.w), @intCast(want.h));
    dock.surface.commit();

    var ticks: u32 = 0;
    while (ticks < 100 and !dock.surface.configured) : (ticks += 1) {
        if (!a.conn.roundtrip()) break;
    }
    if (!dock.surface.configured) {
        logz.err("surface never configured by the compositor", .{});
        return 1;
    }
    if (dock.buf_w <= 0 or dock.buf_h <= 0) {
        Dock.onConfigure(&dock, dock.surface.configured_width, dock.surface.configured_height);
    }
    if (!dock.shm.ready()) {
        logz.err("shm buffer alloc failed", .{});
        return 1;
    }
    dock.layout();
    dock.repaint();
    if (!a.conn.roundtrip()) return 1;

    // Late tray start: the bus answered slowly enough to dominate boot, so
    // the first frame went out without it. A non-empty tray rebuilds once
    // here (carried icons make it cheap); an empty one needs nothing, and
    // every later change heals through the watched fd and the 1 s tick.
    const t_tray = Dock.nowMs();
    if (dock.tray.start()) {
        if (dock.tray.conn.fd >= 0) {
            a.loop.watchFd(dock.tray.conn.fd, std.posix.POLL.IN, Dock.onBusFd, @ptrCast(&dock)) catch {
                logz.err("tray: cannot watch the bus fd; updates land on the 1 s tick only", .{});
            };
        }
        if (dock.tray.itemCount() > 0) {
            dock.buildModel();
            const want2 = dock.desiredSize();
            if (want2.w != dock.req_w or want2.h != dock.req_h) dock.applySize();
            dock.layout();
            dock.repaint();
            if (!a.conn.flush()) logz.log("tray: flush failed after late start", .{});
        }
    } else {
        logz.log("tray: no session bus reachable, the tray section stays empty", .{});
    }
    logz.log("tray: start took {d}ms", .{Dock.nowMs() - t_tray});

    if (a.bound.seat_obj) |seat| {
        seat.on_pointer_enter = Dock.onEnter;
        seat.on_pointer_leave = Dock.onLeave;
        seat.on_pointer_motion = Dock.onMotion;
        seat.on_pointer_button = Dock.onButton;
        seat.on_pointer_axis = Dock.onAxis;
        seat.on_key = Dock.onKey;
        seat.cb_ctx = &dock;
        logz.log("input: pointer and keyboard handlers installed", .{});
    } else {
        logz.err("input: no wl_seat bound, the dock will be inert", .{});
    }
    dock.startTimer();

    // inotify is not recursive: `startWatching` covers the settings and
    // legacy roots, and these are the component dirs underneath the settings
    // root (`~/.config/Event-Horizon`) that actually feed a reload (the paths
    // only need to outlive the call).
    // `shell` carries the renderer combo and `general` the icon theme — both
    // rows live on settings pages, so without these watches those saves would
    // never reach the dock.
    var owned: [5][]u8 = undefined;
    var nowned: usize = 0;
    defer {
        for (owned[0..nowned]) |p| gpa.free(p);
    }
    var extra: [5][]const u8 = undefined;
    var nextra: usize = 0;
    if (config.settingsDir(gpa, a.xdg_config, a.home)) |settings| {
        defer gpa.free(settings);
        // `appearance` carries every Appearance → Opacity knob (and the
        // star of the same name on the general page); without the watch the
        // controls would only land after a restart. Created up front, like
        // the desktop does for `desktop_widgets`, so the watch is never
        // installed against a missing dir.
        for ([_][]const u8{ "dock", "wallpaper", "shell", "general", "appearance" }) |comp| {
            if (nextra == extra.len) break;
            const dir = std.fs.path.join(gpa, &.{ settings, comp }) catch continue;
            if (std.mem.eql(u8, comp, "appearance")) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            owned[nowned] = dir;
            nowned += 1;
            extra[nextra] = dir;
            nextra += 1;
        }
    } else |_| {}
    {
        const d0 = &a.loaded.cfg.dock;
        eh.diag.log(
            "dock boot: opacity={d} show_dock={} radius={d} icon_size={d} liquid_glass={} colored_glass={}",
            .{
                d0.dock_opacity,
                d0.dock_show_dock,
                d0.dock_radius,
                d0.dock_icon_size,
                d0.dock_liquid_glass,
                d0.dock_colored_glass,
            },
        );
    }
    a.startWatching(extra[0..nextra]);

    a.run();
    return 0;
}
