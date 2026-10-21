//! `horizon-taskbar` — the taskbar bar + app drawer + popups as its own
//! process (mirrors `run_taskbar_standalone` in the C++).
//!
//! Own Wayland connection, layer surface(s) per the `[taskbar] output`
//! assignment, own foreign-toplevel tracking (observe via `foreign.Tracker`,
//! act via `ftl.ForeignToplevels`), tray host, 1 s poll timer, settings
//! inotify, and IPC `config.applied` / `command.request` handling.
//!
//! The strip (pinned + running + tray + widgets) is built by
//! `taskbar/strip.zig`, measured with the taskbar metrics, and painted with
//! the shared dock widget painters, so faces match the dock by construction.

const std = @import("std");
const eh = @import("eh");
const app = @import("app.zig");
const layer = eh.wl_layer;
const ns = eh.ns;
const shm_mod = eh.wl_shm;
const config = eh.config;
const pear_prefs = eh.pear_prefs;
const parent_guard = eh.parent_guard;
const logz = eh.logz;
const linux = std.os.linux;
const wl = eh.wl_c.wl;

const tb_settings = eh.taskbar_settings;
const tb_standalone = eh.taskbar_standalone;
const tb_slots = eh.taskbar_slots;
const tb_paint = eh.taskbar_paint;
const tb_input = eh.taskbar_input;
const tb_state = eh.taskbar_state;
const tb_layout = eh.taskbar_layout;
const tb_types = eh.taskbar_types;
const tb_strip = eh.taskbar_strip;
const tb_pin_drag = eh.taskbar_pin_drag;
const tb_pinned = eh.taskbar_pinned;
const foreign = eh.wl_foreign;
const ftl = eh.wl_foreign_toplevels;
const dw = eh.dock_widgets;
const dwp = eh.dock_widgets_paint;
const popup_mod = eh.dock_popup;
const tray_source = eh.tray_source;
const tray_menu = eh.tray_menu;
const icon_cache = eh.icon_cache;
const paths = eh.shell_paths;
const app_launch = eh.app_launch;
const autostart = eh.autostart;
const desktop_actions = eh.desktop_actions;
const chrome = eh.widget_chrome_colors;
const overlay_m = eh.overlay;
const local_time = eh.desktop_local_time;
const pin_store = eh.pin_store;
const ipc_client = eh.ipc_client;
const tb_position = eh.taskbar_position;
const cairo_helpers = eh.cairo_helpers;
const clock_paint = eh.widget_clock_paint;
const weather_paint = eh.widget_weather_paint;
const widget_pill = eh.widget_pill;
const ws_paint = eh.widget_workspaces_paint;
const cc_slot = eh.cc_slot;
const battery_paint = eh.widget_battery_paint;
const bt_paint = eh.widget_bluetooth_paint;
const layout_paint = eh.widget_layout_paint;
const world_clock_paint = eh.widget_world_clock_paint;
const wc_session = eh.widget_world_clock_session;
const wc_face = eh.widget_world_clock_face;
const wc_panel = eh.widget_world_clock_panel;
const text_layout = eh.text_layout;
const ov_ws = eh.overview_ws;
const svg_icons = eh.svg_icons;
const os_logo = eh.os_logo;
const cc_host = eh.cc_host;
const cc_data = eh.cc_data;
const cc_live_audio = eh.cc_live_audio;
const cc_apply = eh.cc_apply;
const cc_live_network = eh.cc_live_network;
const cc_live_bluetooth = eh.cc_live_bluetooth;
const cc_live_vpn = eh.cc_live_vpn;
const cc_live_mixer = eh.cc_live_mixer;
const cc_live_media = eh.cc_live_media;
const cc_live_upower = eh.cc_live_upower;
const cc_position = eh.cc_position;
const pear_host = eh.pear_host;
const pear_slot = eh.pear_slot;
const pear_config = eh.pear_config;
const pear_brightness = eh.pear_brightness;
const wl_session = eh.wl_session;
const launcher_menu = eh.dock_launcher_menu;
const mpris_client = eh.mpris_client;
const media_paint = eh.widget_media_paint;
const vpn_popup = eh.widget_vpn_popup;
const mixer_card = eh.widget_volume_mixer;
const anim_mod = eh.dock_anim;
const seat_mod = eh.wl_seat;
const app_catalog = eh.app_catalog;
const spot_query = eh.spot_query;
const cover_worker = eh.cover_worker;
const notify_push = eh.notify_push;
const mpris_art = eh.mpris_art;
const cover_cache = eh.cover_cache;
const weather_svc = eh.weather;
const wpaint = eh.widget_weather_paint;
const wset = eh.widget_settings;

fn nowMs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 + @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

/// Wall-clock milliseconds. The world clock reads real time-of-day out of
/// this (`nowMs` is monotonic and its seconds are uptime, not 1970 seconds),
/// so every value fed to the world-clock session comes from one source and
/// its deltas stay monotonic like the animation timers expect.
fn epochMs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 + @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

/// Startup benchmarking: one `startup:` line per boot phase, each carrying the
/// monotonic milliseconds since `main` opened. Grep `startup:` and diff two
/// boots to see where time goes (tray discovery and icon indexing dominate).
fn bootMark(t0: u64, comptime name: []const u8) void {
    logz.log("startup: " ++ name ++ " t=+{d}ms", .{nowMs() -| t0});
}

fn getenvStr(key: [:0]const u8) ?[]const u8 {
    const c = @cImport(@cInclude("stdlib.h"));
    const p = c.getenv(key) orelse return null;
    return std.mem.span(p);
}

fn blitIconPx(c: *shm_mod.cairo.cairo_t, icon: dwp.IconPx, x: f64, y: f64, size: f64) void {
    if (icon.pixels.len == 0 or icon.w <= 0 or icon.h <= 0) return;
    const avail = @max(4.0, size);
    const s = avail / @as(f64, @floatFromInt(@max(1, @max(icon.w, icon.h))));
    const tw: i32 = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(icon.w)) * s))));
    const th: i32 = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(icon.h)) * s))));
    const tmp = shm_mod.cairo.cairo_image_surface_create_for_data(
        @constCast(icon.pixels.ptr),
        shm_mod.cairo.CAIRO_FORMAT_ARGB32,
        icon.w,
        icon.h,
        icon.w * 4,
    );
    defer shm_mod.cairo.cairo_surface_destroy(tmp);
    if (shm_mod.cairo.cairo_surface_status(tmp) != shm_mod.cairo.CAIRO_STATUS_SUCCESS) return;
    shm_mod.cairo.cairo_save(c);
    shm_mod.cairo.cairo_translate(c, x, y);
    shm_mod.cairo.cairo_scale(c, @as(f64, @floatFromInt(tw)) / @as(f64, @floatFromInt(icon.w)), @as(f64, @floatFromInt(th)) / @as(f64, @floatFromInt(icon.h)));
    shm_mod.cairo.cairo_set_source_surface(c, tmp, 0, 0);
    shm_mod.cairo.cairo_paint(c);
    shm_mod.cairo.cairo_restore(c);
}

/// Fit `icon` into its square cell with an even 6 px padding, centered on
/// both axes — the App-arm icon geometry (`pad2 = 6`).
fn paintCenteredIcon(c: *shm_mod.cairo.cairo_t, icon: dwp.IconPx, x: f64, y: f64, cell: f64) void {
    if (icon.pixels.len == 0 or icon.w <= 0 or icon.h <= 0) return;
    const avail = @max(4.0, cell - 12.0);
    const s = avail / @as(f64, @floatFromInt(@max(1, @max(icon.w, icon.h))));
    const dest_w = @as(f64, @floatFromInt(icon.w)) * s;
    const dest_h = @as(f64, @floatFromInt(icon.h)) * s;
    blitIconPx(c, icon, x + (cell - dest_w) * 0.5, y + (cell - dest_h) * 0.5, avail);
}

fn drawLucide(c: *shm_mod.cairo.cairo_t, name: []const u8, cx: f64, cy: f64, px: f64) void {
    const fg = eh.m3_tokens.Tokens.text;
    // Every name resolves through the vendored Lucide bank; a miss paints
    // nothing (the shell no longer loads the Material Symbols font).
    _ = svg_icons.draw(c, name, cx, cy, px, fg.r, fg.g, fg.b, 0.95, false);
}

const drag_threshold_px: f64 = 6.0;
const tooltip_delay_ms: u64 = 500;
const poll_interval_ns: u64 = 1_000_000_000;
const settings_app_id = "event-horizon-settings";

const Bar = struct {
    surface: layer.Surface = .{},
    shm: shm_mod.ShmPair,
    w: i32 = 0,
    h: i32 = 0,
    output: usize = 0,
    output_name: []u8 = &.{},
    margins: [4]i32 = .{ 0, 0, 0, 0 },
    /// Slot x/w per strip index, surface coords. Rebuilt with the model.
    xs: []f64 = &.{},
    ws: []f64 = &.{},
};

const ThumbWin = struct {
    serial: u64 = 0,
    title: []const u8 = "",
};

/// One row of the app context menu's window list. The strings live in the
/// menu arena, same lifetime as the popup that shows them.
const MenuWin = struct {
    serial: u64 = 0,
    title: []const u8 = "",
};

const SpotHit = struct {
    kind: enum { app, window } = .app,
    title: []const u8 = "",
    sub: []const u8 = "",
    app_id: []const u8 = "",
    exec: []const u8 = "",
    serial: u64 = 0,
};

const GlowCol = struct { r: f32 = 0.55, g: f32 = 0.75, b: f32 = 1.0, ok: bool = false };
const RunSpan = struct { start: usize = 0, len: usize = 0 };

/// One cached workspace-strip cell icon: copied ARGB bytes plus the cairo
/// surface drawn over them. The surface never borrows the strip's pixels, so
/// a later icon rebuild cannot strand it.
const WsSurf = struct {
    pixels: []u8 = &.{},
    surf: ?*shm_mod.cairo.cairo_surface_t = null,
};

/// One cached mixer row icon: themed name, pixels the cairo surface reads,
/// and that surface. Misses are cached too (null surface) so a name no
/// theme has is not re-resolved on every frame.
const MxIcon = struct {
    name: []const u8,
    pixels: []u8,
    surf: ?*shm_mod.cairo.cairo_surface_t,
};

const Taskbar = struct {
    app: *app.App,
    bars: std.ArrayList(Bar) = .empty,
    hover: i32 = -1,
    pressed: i32 = -1,
    /// The press under way already did its job (opened previews, the
    /// chevron list, or toggled one closed): the release must not click.
    press_consumed: bool = false,
    press_button: u32 = 0,
    toplevels: foreign.Tracker = undefined,
    toplevels_init: bool = false,
    ft: ftl.ForeignToplevels = undefined,
    ft_init: bool = false,
    dirty: bool = true,

    tray: tray_source.Source = undefined,
    tray_init: bool = false,
    popup: popup_mod.Host = undefined,
    popup_init: bool = false,
    popup_slot: i32 = -1,

    thumbs: layer.Surface = .{},
    thumbs_shm: shm_mod.ShmBuffer,
    thumbs_open: bool = false,
    thumbs_group: []u8 = &.{},
    /// The group's app id frozen at open time: the card icon must survive the
    /// pointer leaving the bar (hover goes -1 but the popup stays up).
    thumbs_icon_key: []u8 = &.{},
    thumbs_wins: []ThumbWin = &.{},
    thumbs_anchor: i32 = 0,
    thumbs_hover: i32 = -1,
    thumbs_close_hover: bool = false,
    thumbs_list_mode: bool = false,

    tooltip: layer.Surface = .{},
    tooltip_shm: shm_mod.ShmBuffer,
    tooltip_open: bool = false,
    tooltip_slot: i32 = -1,
    tooltip_start_ms: u64 = 0,

    // Current model (owned). Rebuilt by `rebuild`.
    pins: []tb_strip.Pin = &.{},
    pin_strings: [][]u8 = &.{},
    /// Set while a rebuild pass re-runs with grouping forced because an
    /// ungrouped strip overflowed even the widest bar (C++ `effGrouped`
    /// fallback in `taskbar.cpp:4617`).
    group_force: bool = false,
    groups: []tb_strip.Group = &.{},
    group_strings: [][]u8 = &.{},
    tray_keys: [][]const u8 = &.{},
    sections: tb_strip.Sections = .{},
    widths: []f64 = &.{},
    icons: []dwp.IconPx = &.{},
    icon_owned: []icon_cache.Owned = &.{},
    icons_fp: u64 = 0,
    // Per-slot Win7 hot-track glow (computed at rebuild from icon pixels).
    glow: []GlowCol = &.{},
    // Pre-trimmed labels per strip index (ellipsis at rebuild, not per frame).
    slot_labels: [][]u8 = &.{},
    // Shared-pill runs {start, len} computed at rebuild (tray always shares,
    // app runs share when their pill flag is on).
    runs: []RunSpan = &.{},
    // Overflow chevron windows (hidden running buttons, titles borrowed).
    chev_wins: []ThumbWin = &.{},
    // Trash state (dir poll, cheap cadence).
    trash_full: bool = false,
    trash_next_ms: u64 = 0,
    distro_pixels: []u8 = &.{},
    distro_w: i32 = 0,
    distro_h: i32 = 0,
    eff_show_labels: bool = false,
    eff_label_max_w: f64 = 0,

    // App context menu model (rebuilt on open, freed when the popup closes):
    // the normalized key, the chosen window, the desktop entry's exec and
    // actions, and the window rows. All slices live in `menu_arena`.
    menu_arena: ?std.heap.ArenaAllocator = null,
    menu_app_key: []const u8 = "",
    menu_app_raw: []const u8 = "",
    menu_app_serial: u64 = 0,
    menu_app_exec: []const u8 = "",
    menu_app_actions: []const desktop_actions.Action = &.{},
    menu_app_windows: []MenuWin = &.{},

    // Scratch cairo context for label measuring (C++ labelMeasureCr).
    measure_surf: ?*cairo.cairo_surface_t = null,
    measure_cr: ?*cairo.cairo_t = null,

    // Pin drag state.
    drag_candidate: bool = false,
    drag_dragging: bool = false,
    drag_start_x: f64 = 0,
    drag_start_y: f64 = 0,
    drag_key_norm: []u8 = &.{},
    drag_key_raw: []u8 = &.{},
    drag_insert: i32 = -1,
    drag_snapshot: [][]const u8 = &.{},
    drag_order: [][]const u8 = &.{},
    drag_rects: []tb_pin_drag.Drag.Rect = &.{},

    // Launch bounce.
    bounce_key: []u8 = &.{},
    bounce_start_ms: u64 = 0,

    // Autohide reveal.
    reveal: bool = true,
    warned_disabled: bool = false,
    warned_hidden: bool = false,
    // Strip index whose click opened the current popup/thumbs/CC (toggle).
    open_origin: i32 = -1,

    ipc: ipc_client.Client = undefined,
    ipc_init: bool = false,
    ipc_ok: bool = false,
    timer_fd: i32 = -1,
    anim_fd: i32 = -1,

    // Workspaces strip: the dock's Hyprland snapshot plumbing, plus the pid
    // of the overview copy this bar spawned for its toggle.
    ws_snap: ?ov_ws.Snapshot = null,
    ws_fetched_ms: u64 = 0,
    ws_entries: []ws_paint.Entry = &.{},
    ws_anim: ws_paint.AnimState = .{},
    ov_pid: ?i32 = null,
    /// Per-cell workspace app icons: copied pixels + the surface over them,
    /// keyed by app id. Rebuilt whenever the strip's icons re-resolve.
    ws_surfs: std.StringHashMap(WsSurf) = undefined,
    ws_surfs_init: bool = false,

    // Control center (mirrors the dock's live stack, trimmed: no pear, no
    // mixer art, no stream display names — parties nobody looks at twice).
    cc: cc_host.Host = undefined,
    cc_init: bool = false,
    cc_audio: ?cc_live_audio.Queried = null,
    cc_net: ?cc_live_network.Queried = null,
    cc_bt: ?cc_live_bluetooth.Queried = null,
    cc_media: ?cc_live_media.Queried = null,
    cc_snap_aps: [8]cc_data.WifiAp = @splat(.{}),
    cc_snap_bt: [8]cc_data.BluetoothDevice = @splat(.{}),
    cc_snap_outdev: [12]cc_data.OutputDevice = @splat(.{}),
    cc_snap_indev: [12]cc_data.InputDevice = @splat(.{}),
    cc_snap_outs: [8]cc_data.MixerStream = @splat(.{}),
    cc_snap_ins: [8]cc_data.MixerStream = @splat(.{}),
    cc_next_live_ms: u64 = 0,
    cc_settle_ms: u64 = 0,
    cc_wifi_err: [96]u8 = undefined,
    cc_wifi_err_len: usize = 0,
    cc_days: [5]cc_data.ForecastDay = @splat(.{}),

    // Pear center — a fully separate widget: own host, own runtime, own
    // popup. Shares the live backends with the control center, never state.
    pear: pear_host.Host = undefined,
    pear_init: bool = false,
    pear_rt: pear_slot.Runtime = .{},
    pear_sig: i64 = 0,
    // Clock-family tick signatures: the whole-second repaint governance for
    // the strip's clocks (see `tickClocks`). One signature covers each
    // family — a strip-wide rule, not a per-instance one.
    clock_tick_sig: i32 = 0,
    pear_backlight: pear_brightness.Backlight = .{},
    redeye_inhibit: wl_session.Inhibitor = .{},
    redeye_on: bool = false,

    // World clock — its own widget face plus its own popup surface (a
    // sibling of the spotlight palette: taskbar-owned layer surface,
    // bottom|right anchored). All state lives in the session under
    // `widgets/world_clock/`; this file only wires events and the surface.
    wc: wc_session.Session = undefined,
    wc_init: bool = false,
    wc_surface: layer.Surface = .{},
    wc_shm: shm_mod.ShmBuffer,
    wc_open: bool = false,
    wc_geom: wc_panel.Geom = .{},
    wc_slot: usize = 0,
    /// Panel transition frames: one extra paint lands when an animation ends.
    wc_anim_prev: bool = false,
    /// Shift is not in the seat's key event; the keycodes carry it (42/54).
    wc_shift_down: bool = false,

    // Battery (UPower, 5 s cadence — feeds the slot face + CC snapshot).
    bat_reading: cc_live_upower.Reading = .{},
    bat_next_ms: u64 = 0,

    // Weather (worker-backed, 15 min cadence — feeds the slot face, the
    // weather card and the CC snapshot, like the dock).
    wx_reading: weather_svc.Reading = .{},
    wx_glyph: [32]u8 = undefined,
    wx_glyph_len: u8 = 0,
    wx_next_ms: i64 = 0,

    // Media player (MPRIS, 400 ms cadence).
    media: mpris_client.Client = undefined,
    media_init: bool = false,
    media_next_ms: u64 = 0,
    media_title_buf: [512]u8 = undefined,
    media_artist_buf: [512]u8 = undefined,
    media_loop_buf: [16]u8 = undefined,
    media_pos: media_paint.Position = .{},
    // Full media pill (dock parity): the width card the slot is sized from,
    // the transport-row width, and the two frame tickers the paint reports —
    // marquee while a row scrolls, progress while the border is drawn.
    media_measured: media_paint.Measured = .{},
    media_ctrl_w: f64 = 0.0,
    media_wants_marquee: bool = false,
    media_progress_tick: bool = false,
    // Cover art for the media card (worker-backed) + now-playing push.
    media_art_pixels: []u8 = &.{},
    media_art_w: i32 = 0,
    media_art_h: i32 = 0,
    media_art_track: []u8 = &.{},
    /// The address the disk cache and worker were last consulted for; a new
    /// one gets one cache find before the worker is asked.
    media_art_src: []u8 = &.{},
    media_art_misses: u8 = 0,
    media_art_retry_ms: u64 = 0,
    notif_push: notify_push.Publisher = undefined,
    notif_init: bool = false,
    notif_last_key: []u8 = &.{},

    // Bluetooth widget rows (borrow the cc_bt query, like the dock).
    bt_devs: []bt_paint.Device = &.{},
    bt_snap: bt_paint.Snapshot = .{},
    bt_card_slot: i32 = -1,

    // VPN list (worker-backed, warmed while a slot exists).
    vpn_store: vpn_popup.Store = undefined,
    vpn_store_init: bool = false,
    vpn_conns: []vpn_popup.Connection = &.{},
    vpn_next_ms: u64 = 0,
    vpn_card_slot: i32 = -1,

    // Mixer landing (worker-backed, only while its card is up).
    mx_data: ?*cc_live_mixer.Data = null,
    mx_next_ms: u64 = 0,
    mx_hold_ms: u64 = 0,

    mx_icons: std.ArrayListUnmanaged(MxIcon) = .empty,

    // Spotlight palette (type to filter, arrows to pick, Enter to run).
    spot_open: bool = false,
    spot_surface: layer.Surface = .{},
    spot_shm: shm_mod.ShmBuffer,
    spot_query: [256]u8 = undefined,
    spot_len: usize = 0,
    spot_hits: []SpotHit = &.{},
    spot_icons: []dwp.IconPx = &.{},
    spot_owned: []icon_cache.Owned = &.{},
    spot_sel: i32 = -1,
    spot_catalog: app_catalog.Catalog = undefined,
    spot_cat_loaded: bool = false,

    // App drawer (full launcher grid, catalog scanned on open).
    launcher: launcher_menu.Menu = undefined,
    launcher_init: bool = false,
    launcher_theme: ?[]const u8 = null,
    launcher_home: ?[]const u8 = null,
    launcher_dirs_env: ?[]const u8 = null,
    /// Set while the launcher's own Reload-shell / Toggle-theme buttons ask
    /// for a reload: the config watcher closes every popup on a reload, and
    /// those two promise to stay up.
    reload_keep_popup: bool = false,

    // Slider-drag paint gate (16 ms motion coalescing, like the dock).
    drag_next_paint_ms: u64 = 0,
    drag_motion_paint_off: bool = false,
    // Autohide slide (200 ms ease; zone snaps, pixels glide).
    slide_off_px: f64 = 0,
    slide_from_px: f64 = 0,
    slide_start_ms: u64 = 0,
    slide_active: bool = false,
    // Vsync pacer: one frame callback rearmed while anything animates.
    frame_pending: bool = false,
    /// Pointer moved inside an already-hovered running button: the pending
    /// frame callback repaints so the hot-track glow follows (taskbar.cpp:3418).
    hot_follow_dirty: bool = false,
    // Perf bench (slow frames get a log line, like the C++ motion bench).
    motion_max_ms: u64 = 0,
    draw_max_ms: u64 = 0,
    /// Monotonic stamp captured in `main` right after the logger opens;
    /// `startup:` marks and the one-shot first-frame log measure from it.
    boot_t0: u64 = 0,
    /// One-shot: the first committed frame logs total boot + paint time.
    first_frame_logged: bool = false,

    const cairo = shm_mod.cairo;

    fn deinit(self: *Taskbar) void {
        const gpa = self.app.gpa;
        self.freeModel();
        self.destroyBars();
        self.bars.deinit(gpa);
        self.ws_anim.deinit();
        if (self.ws_snap) |*snap| snap.deinit();
        self.freeWsEntries();
        self.clearWsSurfs();
        self.freeMxIcons();
        if (self.ws_surfs_init) self.ws_surfs.deinit();
        if (self.toplevels_init) self.toplevels.deinit();
        if (self.ft_init) self.ft.deinit();
        if (self.tray_init) self.tray.deinit();
        if (self.popup_init) self.popup.deinit();
        if (self.thumbs_open or self.thumbs.wl_surface != null) self.thumbs.destroy();
        self.thumbs_shm.deinit();
        if (self.tooltip_open or self.tooltip.wl_surface != null) self.tooltip.destroy();
        self.tooltip_shm.deinit();
        self.spotClose();
        if (self.thumbs_wins.len > 0) gpa.free(self.thumbs_wins);
        if (self.thumbs_group.len > 0) gpa.free(self.thumbs_group);
        if (self.thumbs_icon_key.len > 0) gpa.free(self.thumbs_icon_key);
        if (self.drag_key_norm.len > 0) gpa.free(self.drag_key_norm);
        if (self.drag_key_raw.len > 0) gpa.free(self.drag_key_raw);
        if (self.bounce_key.len > 0) gpa.free(self.bounce_key);
        if (self.measure_cr) |cr| cairo.cairo_destroy(cr);
        if (self.measure_surf) |s| cairo.cairo_surface_destroy(s);
        if (self.ipc_init) self.ipc.deinit();
        if (self.timer_fd >= 0) {
            self.app.loop.unwatch(self.timer_fd);
            _ = linux.close(self.timer_fd);
        }
        if (self.anim_fd >= 0) {
            self.app.loop.unwatch(self.anim_fd);
            _ = linux.close(self.anim_fd);
        }
        if (self.cc_init) self.cc.deinit();
        if (self.pear_init) self.pear.deinit();
        if (self.wc_init) {
            self.wc.deinit();
            self.wc_open = false;
            self.wc_surface.destroy();
            self.wc_shm.deinit();
        }
        self.pear_backlight.deinit(gpa);
        self.redeye_inhibit.deinit();
        self.freeCcLive();
        if (self.media_init) self.media.deinit();
        if (self.bt_devs.len > 0) gpa.free(self.bt_devs);
        self.freeVpnConns();
        if (self.mx_data) |d| d.deinit();
        if (self.launcher_init) self.launcher.deinit();
        if (self.distro_pixels.len > 0) gpa.free(self.distro_pixels);
        self.distro_pixels = &.{};
        if (self.media_art_pixels.len > 0) gpa.free(self.media_art_pixels);
        if (self.media_art_track.len > 0) gpa.free(self.media_art_track);
        if (self.media_art_src.len > 0) gpa.free(self.media_art_src);
        // The cover worker allocates from this same allocator and may still
        // be running; this drain waits it out briefly and abandons a pick
        // that is stuck on a dead network read, so exit can never wedge.
        cover_worker.resetWithin(gpa, 1500);
        if (self.notif_init) self.notif_push.deinit();
        if (self.notif_last_key.len > 0) gpa.free(self.notif_last_key);
        self.freeIcons();
        if (self.vpn_store_init) self.vpn_store.deinit();
        if (self.launcher_theme) |t| gpa.free(t);
        if (self.menu_arena) |*ar| ar.deinit();
        self.menu_arena = null;
    }

    fn freeCcAudio(self: *Taskbar) void {
        if (self.cc_audio) |*q| {
            q.deinit();
            self.cc_audio = null;
        }
    }

    fn freeCcNet(self: *Taskbar) void {
        if (self.cc_net) |*q| {
            q.deinit();
            self.cc_net = null;
        }
    }

    fn freeCcBt(self: *Taskbar) void {
        if (self.popup_init and self.popup.kind == .bluetooth) {
            self.popup.bt_snap = .{};
            self.popup.bt_devs = &.{};
        }
        if (self.bt_devs.len > 0) self.app.gpa.free(self.bt_devs);
        self.bt_devs = &.{};
        self.bt_snap = .{};
        if (self.cc_bt) |*q| {
            q.deinit();
            self.cc_bt = null;
        }
    }

    fn freeCcMedia(self: *Taskbar) void {
        if (self.cc_media) |*q| {
            q.deinit();
            self.cc_media = null;
        }
    }

    fn freeCcLive(self: *Taskbar) void {
        self.freeCcAudio();
        self.freeCcNet();
        self.freeCcBt();
        self.freeCcMedia();
    }

    fn freeIcons(self: *Taskbar) void {
        // Icon pixels are owned through icon_owned; the IconPx views borrow them.
        const gpa = self.app.gpa;
        for (self.icon_owned) |*o| o.deinit(gpa);
        if (self.icon_owned.len > 0) gpa.free(self.icon_owned);
        if (self.icons.len > 0) gpa.free(self.icons);
        self.icons = &.{};
        self.icon_owned = &.{};
        self.icons_fp = 0;
    }

    /// Fingerprint of everything icon resolution reads, so a quiet second
    /// keeps its pixels instead of re-decoding the whole strip (the churn
    /// that read as flicker on the 1 s tick).
    fn iconFingerprint(self: *Taskbar, icon_px: i32) u64 {
        const cfg = &self.app.loaded.cfg;
        var h = std.hash.Wyhash.init(0x7461736b626172);
        var ib: [9]u8 = undefined;
        std.mem.writeInt(i32, ib[0..4], icon_px, .little);
        std.mem.writeInt(i32, ib[4..8], @intFromFloat(@round(self.uiScale() * 1000.0)), .little);
        ib[8] = if (self.trash_full) 1 else 0;
        h.update(&ib);
        h.update(cfg.taskbar.icon_theme);
        for (self.pins) |p| h.update(p.norm);
        for (self.groups) |g| {
            h.update(g.key);
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, g.serial, .little);
            h.update(&b);
        }
        for (self.tray_keys) |k| h.update(k);
        for (self.sections.all) |*sl| h.update(@tagName(sl.kind));
        return h.final();
    }

    fn freeVpnConns(self: *Taskbar) void {
        const gpa = self.app.gpa;
        for (self.vpn_conns) |*c| {
            gpa.free(c.uuid);
            gpa.free(c.name);
        }
        if (self.vpn_conns.len > 0) gpa.free(self.vpn_conns);
        self.vpn_conns = &.{};
    }

    fn freeModel(self: *Taskbar) void {
        const gpa = self.app.gpa;
        for (self.pin_strings) |s| gpa.free(s);
        if (self.pin_strings.len > 0) gpa.free(self.pin_strings);
        if (self.pins.len > 0) gpa.free(self.pins);
        for (self.group_strings) |s| gpa.free(s);
        if (self.group_strings.len > 0) gpa.free(self.group_strings);
        if (self.groups.len > 0) gpa.free(self.groups);
        for (self.tray_keys) |k| gpa.free(k);
        if (self.tray_keys.len > 0) gpa.free(self.tray_keys);
        self.sections.deinit(gpa);
        if (self.widths.len > 0) gpa.free(self.widths);
        if (self.glow.len > 0) gpa.free(self.glow);
        for (self.slot_labels) |l| gpa.free(l);
        if (self.slot_labels.len > 0) gpa.free(self.slot_labels);
        if (self.runs.len > 0) gpa.free(self.runs);
        if (self.chev_wins.len > 0) gpa.free(self.chev_wins);
        self.glow = &.{};
        self.slot_labels = &.{};
        self.runs = &.{};
        self.chev_wins = &.{};
        // NOTE: distro_pixels is NOT freed here: icons[] may keep borrowing
        // it across fingerprint-kept rebuilds. It is freed only when icons
        // re-resolve, and at shutdown.
        self.pins = &.{};
        self.pin_strings = &.{};
        self.groups = &.{};
        self.group_strings = &.{};
        self.tray_keys = &.{};
        self.sections = .{};
        self.widths = &.{};
        self.freeDrag();
    }

    fn freeDrag(self: *Taskbar) void {
        const gpa = self.app.gpa;
        for (self.drag_snapshot) |s| gpa.free(s);
        if (self.drag_snapshot.len > 0) gpa.free(self.drag_snapshot);
        for (self.drag_order) |s| gpa.free(s);
        if (self.drag_order.len > 0) gpa.free(self.drag_order);
        if (self.drag_rects.len > 0) gpa.free(self.drag_rects);
        self.drag_snapshot = &.{};
        self.drag_order = &.{};
        self.drag_rects = &.{};
        self.drag_candidate = false;
        self.drag_dragging = false;
        self.drag_insert = -1;
    }

    fn uiScale(self: *Taskbar) f64 {
        const cfg = &self.app.loaded.cfg;
        return tb_slots.uiScale(cfg.taskbar.scale, cfg.dock.shell_ui_scale);
    }

    /// Fit-to-output factor for the given output (output height / 1440,
    /// clamped) — same reference the dock/widgets use. Popups scale by it so a
    /// shorter output gets a smaller control center.
    fn fitForOutput(self: *Taskbar, out_idx: usize) f64 {
        var h: i32 = 0;
        if (out_idx < self.app.bound.outputs.items.len) {
            const o = self.app.bound.outputs.items[out_idx];
            h = if (o.have_logical and o.logical_h > 0) o.logical_h else @divTrunc(o.height, @max(1, o.scale));
        }
        return if (h > 0) std.math.clamp(@as(f64, @floatFromInt(h)) / 1440.0, 0.5, 2.0) else 1.0;
    }

    fn barHeight(self: *Taskbar) i32 {
        const cfg = &self.app.loaded.cfg;
        const s = tb_settings.Settings{
            .height = cfg.taskbar.height,
            .icon_size = cfg.taskbar.icon_size,
            .scale = cfg.taskbar.scale,
        };
        return tb_settings.effectiveHeightPx(&s, cfg.dock.shell_ui_scale);
    }

    fn iconPx(self: *Taskbar, box_h: f64) f64 {
        const cfg = &self.app.loaded.cfg;
        return tb_slots.clampIcon(@as(f64, @floatFromInt(cfg.taskbar.icon_size)) * self.uiScale(), box_h);
    }

    /// Scratch context for text measurement. Pointer extents used to run on
    /// a 1×1 placeholder; the pango layouts the measured slots need a real
    /// ARGB32 target, so the surface is the dock's 512×64.
    fn ensureMeasure(self: *Taskbar) ?*cairo.cairo_t {
        if (self.measure_cr) |cr| return cr;
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
        self.measure_surf = surf;
        self.measure_cr = cr;
        return cr;
    }

    fn measureLabel(self: *Taskbar, text: []const u8, font_px: f64) f64 {
        if (text.len == 0 or font_px <= 0) return 0;
        const cr = self.ensureMeasure() orelse return 0;
        cairo.cairo_select_font_face(cr, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(cr, font_px);
        var buf: [512]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
        cairo.cairo_text_extents(cr, @ptrCast(&buf), &ex);
        return @max(0.0, ex.x_advance);
    }

    /// Pango advance for `text`, the same font string the paint paths lay
    /// out with — `dw.Measured` wants pango's answer, not the toy API's.
    fn measureText(self: *Taskbar, text: []const u8, font_px: f64) f64 {
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

    /// Live widths for the measured widgets, so `dw.slotWidth` sizes the
    /// clock/weather/control-center/workspaces/world-clock slots to what the
    /// paint will draw. Without these every one of them falls back to its
    /// minimum and the neighbouring pills paint over the text (the weather
    /// sun over the clock's leading digit, the gear over its last).
    fn liveMeasured(self: *Taskbar, icon: f64, box_h: f64) dw.Measured {
        const cfg = &self.app.loaded.cfg;
        var out = dw.Measured{};
        var media_done = false;
        for (self.sections.all) |*s| {
            switch (s.kind) {
                .clock => {
                    if (out.clock_max_w == 0) {
                        // `dockClockSlotWidth` is the final slot width; the
                        // measured value is that run without its 10 px pads.
                        const w = clock_paint.dockClockSlotWidth(self.measure_cr, cfg, s.key, icon, box_h);
                        out.clock_max_w = @max(0.0, w - 20.0);
                    }
                },
                .weather => {
                    if (out.weather_inner == 0)
                        out.weather_inner = weather_paint.weatherInnerWidth(self.measure_cr, cfg, s.key, icon);
                },
                .control_center => {
                    if (out.cc_icons == 0) {
                        const ccfg = cc_slot.loadCfg(cfg, s.key);
                        var gbuf: [4]cc_slot.Glyph = undefined;
                        out.cc_icons = @intCast(@min(cc_slot.glyphs(ccfg, cc_slot.Runtime{}, &gbuf).len, 255));
                    }
                },
                .workspaces => {
                    if (out.workspace_count == 0 and self.ws_entries.len > 0) {
                        out.workspace_count = self.ws_entries.len;
                        out.workspace_w = ws_paint.dockWorkspacesSlotWidth(self.measure_cr, cfg, s.key, icon, box_h, self.ws_entries);
                    }
                },
                .world_clock => {
                    if (out.world_clock_inner == 0 and self.wc_init) {
                        // The face's own measured width: name block (widest
                        // city, capped), dots and paddings — the final slot
                        // clamps on top of it in `dock/widgets.zig`.
                        const us = wc_face.scaleOf(icon);
                        out.world_clock_inner = wc_face.slotWidth(&self.wc, self.measure_cr, us);
                    }
                },
                .media => {
                    if (!media_done) {
                        media_done = true;
                        if (self.media_init) {
                            // Same measure the paint runs: title/artist are
                            // pango's answer, compact hides the text row, and
                            // the button row only exists while a player is up.
                            const mx = media_paint.measure(
                                self.ensureMeasure(),
                                cfg,
                                s.key,
                                icon,
                                self.media.snap,
                                cfg.taskbar.compact_media,
                            );
                            self.media_measured = mx;
                            self.media_ctrl_w = if (self.media.snap.realActive())
                                media_paint.ctrlRowWidth(media_paint.scaleOf(icon))
                            else
                                0.0;
                            out.media_text_w = mx.text_w;
                            out.media_ctrl_w = self.media_ctrl_w;
                        }
                    }
                },
                else => {},
            }
        }
        return out;
    }

    fn wsSlotPresent(self: *Taskbar) bool {
        for (self.sections.all) |*s| {
            if (s.kind == .workspaces) return true;
        }
        return false;
    }

    fn hyprEnv(self: *Taskbar) std.process.Environ.Map {
        var env = std.process.Environ.Map.init(self.app.gpa);
        if (getenvStr("HYPRLAND_INSTANCE_SIGNATURE")) |v| env.put("HYPRLAND_INSTANCE_SIGNATURE", v) catch {};
        if (getenvStr("XDG_RUNTIME_DIR")) |v| env.put("XDG_RUNTIME_DIR", v) catch {};
        return env;
    }

    /// `max_workspaces` for the first workspaces slot in the model,
    /// defaulting to 5 like the settings tab does.
    fn wsMaxSlots(self: *Taskbar) i32 {
        const cfg = &self.app.loaded.cfg;
        for (self.sections.all) |*s| {
            if (s.kind != .workspaces) continue;
            return ws_paint.maxSlotsFromSettings(cfg, s.key);
        }
        return 5;
    }

    fn freeWsEntries(self: *Taskbar) void {
        if (self.ws_entries.len == 0) return;
        ws_paint.freeEntries(self.app.gpa, self.ws_entries);
        self.ws_entries = &.{};
    }

    /// Strip entries from the snapshot: ids, labels, state, and the client
    /// classes as app keys. Every string is owned; a failed allocation drops
    /// the workspace instead of leaving anything static for the release path.
    fn rebuildWsEntries(self: *Taskbar) void {
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

    /// Cheap content hash of the drawn cells — the tick refreshes the
    /// snapshot every few seconds and only a real change should repaint.
    fn wsEntrySig(entries: []const ws_paint.Entry) u64 {
        var h: u64 = 1469598103934665603;
        for (entries) |e| {
            h = (h ^ @as(u64, @bitCast(@as(i64, e.id)))) *% 1099511628211;
            for (e.label) |b| h = (h ^ b) *% 1099511628211;
            if (e.active) h = (h ^ 1) *% 1099511628211;
            if (e.occupied) h = (h ^ 2) *% 1099511628211;
            for (e.app_keys) |k| {
                for (k) |b| h = (h ^ b) *% 1099511628211;
                h = (h ^ 3) *% 1099511628211;
            }
            h = (h ^ 4) *% 1099511628211;
        }
        return h;
    }

    /// Refetch the Hyprland snapshot, throttled unless forced. Answers
    /// whether the drawn cells changed.
    fn reloadWorkspaces(self: *Taskbar, force: bool) bool {
        const now = nowMs();
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
        const before = wsEntrySig(self.ws_entries);
        self.rebuildWsEntries();
        if (wsEntrySig(self.ws_entries) != before) {
            // Cell art keys off the entries' app ids. The snapshot can land
            // after icon resolution (boot order), so rebuild the per-cell
            // surfaces here too; refreshWsIcons is a no-op when empty.
            self.refreshWsIcons();
            return true;
        }
        return false;
    }

    /// Fire-and-forget compositor command; `true` when the reply starts `ok`.
    fn hyprSend(self: *Taskbar, cmd: []const u8) bool {
        var env = self.hyprEnv();
        defer env.deinit();
        const reply = ov_ws.send(self.app.gpa, self.app.io, &env, cmd) orelse return false;
        defer self.app.gpa.free(reply);
        return ov_ws.repliedOk(reply);
    }

    /// Focus a workspace by id; Hyprland creates a missing one on demand.
    fn wsJump(self: *Taskbar, id: i32) void {
        var buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.focus({{workspace = {d}}})", .{id}) catch return;
        if (!self.hyprSend(cmd)) {
            const plain = std.fmt.bufPrint(&buf, "dispatch workspace {d}", .{id}) catch return;
            _ = self.hyprSend(plain);
        }
    }

    /// Jump to the workspace cell under the pointer — the C++
    /// `workspace_activate_entry` path, left press.
    fn focusWorkspace(self: *Taskbar, b: *Bar, idx: usize, pointer_x: f64) void {
        if (idx >= self.sections.all.len or idx >= b.xs.len or idx >= b.ws.len) return;
        const s = &self.sections.all[idx];
        if (s.kind != .workspaces) return;
        const icon = self.iconPx(@floatFromInt(@max(1, self.barHeight())));
        const pick = ws_paint.pickIndex(self.app.gpa, pointer_x - b.xs[idx], b.ws[idx], &self.app.loaded.cfg, s.key, icon, self.ws_entries) catch -1;
        if (pick < 0 or pick >= self.ws_entries.len) return;
        var buf: [12]u8 = undefined;
        const target = ws_paint.activateTarget(&self.ws_entries[@intCast(pick)], &buf) orelse return;
        const id = std.fmt.parseInt(i32, target, 10) catch return;
        self.wsJump(id);
    }

    /// Window title for a running slot's chosen serial, or "".
    fn titleForSerial(self: *Taskbar, serial: u64) []const u8 {
        if (serial == 0) return "";
        if (!self.ft_init) return "";
        for (self.ft.list()) |tl| {
            if (tl.closed or tl.serial != serial) continue;
            return tl.title;
        }
        return "";
    }

    /// Rebuild the whole model from config + trackers. Called on reload,
    /// toplevel/tray changes, and the 1 s tick when dirty.
    /// Rebuild the model. An ungrouped running strip that overflows even the
    /// widest bar falls back to grouped buttons when `collapse_when_full` is
    /// on (C++ `taskbar.cpp:4617`), so the pass may run a second time.
    fn rebuild(self: *Taskbar) void {
        self.group_force = false;
        defer self.group_force = false;
        if (!self.rebuildPass()) return;
        self.group_force = true;
        _ = self.rebuildPass();
    }

    /// One model rebuild. Returns true when the pass should be retried with
    /// forced grouping (asked only while `group_force` is still off).
    fn rebuildPass(self: *Taskbar) bool {
        const gpa = self.app.gpa;
        const cfg = &self.app.loaded.cfg;
        self.freeModel();
        self.dirty = false;

        // Pins (normalized + raw for identity).
        var pin_list: std.ArrayList(tb_strip.Pin) = .empty;
        errdefer pin_list.deinit(gpa);
        var pin_strs: std.ArrayList([]u8) = .empty;
        errdefer {
            for (pin_strs.items) |s| gpa.free(s);
            pin_strs.deinit(gpa);
        }
        for (cfg.taskbar.pinned_apps) |p| {
            const norm = paths.normalizeAppId(gpa, p) catch continue;
            const raw = gpa.dupe(u8, p) catch {
                gpa.free(norm);
                continue;
            };
            pin_strs.append(gpa, norm) catch {
                gpa.free(norm);
                gpa.free(raw);
                continue;
            };
            pin_strs.append(gpa, raw) catch {
                // `norm` already lives in the list; only `raw` still needs
                // dropping.
                gpa.free(raw);
                continue;
            };
            pin_list.append(gpa, .{ .raw = raw, .norm = norm }) catch continue;
        }
        self.pin_strings = pin_strs.toOwnedSlice(gpa) catch &.{};
        self.pins = pin_list.toOwnedSlice(gpa) catch &.{};

        // Running groups from the ext-toplevel tracker.
        var groups: std.ArrayList(tb_strip.Group) = .empty;
        errdefer groups.deinit(gpa);
        var group_strs: std.ArrayList([]u8) = .empty;
        errdefer {
            for (group_strs.items) |s| gpa.free(s);
            group_strs.deinit(gpa);
        }
        const have_ft = self.ft_init and self.ft.list().len > 0;
        const grouped = cfg.taskbar.group_apps or self.group_force;
        if (have_ft) {
            if (grouped) {
                var seen: std.ArrayList([]const u8) = .empty;
                defer seen.deinit(gpa);
                for (self.ft.list()) |tl| {
                    if (tl.closed or tl.handle == null or tl.app_id.len == 0) continue;
                    const norm = paths.normalizeAppId(gpa, tl.app_id) catch continue;
                    if (std.mem.eql(u8, norm, settings_app_id)) {
                        gpa.free(norm);
                        continue;
                    }
                    var known: ?usize = null;
                    for (seen.items, 0..) |s, i| {
                        if (paths.sameAppId(s, norm)) {
                            known = i;
                            break;
                        }
                    }
                    if (known) |gi| {
                        gpa.free(norm);
                        // The newest window is the group's chosen one; a
                        // single activated window lights the whole button.
                        var g = &groups.items[gi];
                        if (tl.serial > g.serial) g.serial = tl.serial;
                        g.active = g.active or tl.activated;
                    } else {
                        const owned = gpa.dupe(u8, norm) catch {
                            gpa.free(norm);
                            continue;
                        };
                        gpa.free(norm);
                        group_strs.append(gpa, owned) catch {
                            gpa.free(owned);
                            continue;
                        };
                        seen.append(gpa, group_strs.items[group_strs.items.len - 1]) catch continue;
                        const icon_owned = gpa.dupe(u8, tl.app_id) catch continue;
                        group_strs.append(gpa, icon_owned) catch {
                            gpa.free(icon_owned);
                            continue;
                        };
                        groups.append(gpa, .{
                            .key = group_strs.items[group_strs.items.len - 2],
                            .icon_id = group_strs.items[group_strs.items.len - 1],
                            .serial = tl.serial,
                            .active = tl.activated,
                        }) catch continue;
                    }
                }
            } else {
                // Grouping off: one slot per window, keyed by its own serial
                // (`__eh_tl_<serial>`), in serial order.
                for (self.ft.list()) |tl| {
                    if (tl.closed or tl.handle == null) continue;
                    const norm = paths.normalizeAppId(gpa, tl.app_id) catch continue;
                    defer gpa.free(norm);
                    if (std.mem.eql(u8, norm, settings_app_id)) continue;
                    const key = std.fmt.allocPrint(gpa, "__eh_tl_{d}", .{tl.serial}) catch continue;
                    group_strs.append(gpa, key) catch {
                        gpa.free(key);
                        continue;
                    };
                    const icon2 = gpa.dupe(u8, tl.app_id) catch continue;
                    group_strs.append(gpa, icon2) catch {
                        gpa.free(icon2);
                        continue;
                    };
                    groups.append(gpa, .{
                        .key = group_strs.items[group_strs.items.len - 2],
                        .icon_id = group_strs.items[group_strs.items.len - 1],
                        .serial = tl.serial,
                        .active = tl.activated,
                    }) catch continue;
                }
            }
        } else if (self.toplevels_init) {
            // No zwlr manager: the ext tracker still answers "running", but
            // serials stay 0 (no previews, no per-window activation).
            if (grouped) {
                var seen: std.ArrayList([]const u8) = .empty;
                defer seen.deinit(gpa);
                for (self.toplevels.windows.items) |w| {
                    if (w.closed or w.app_id.len == 0) continue;
                    const norm = paths.normalizeAppId(gpa, w.app_id) catch continue;
                    var known: ?usize = null;
                    for (seen.items, 0..) |s, i| {
                        if (paths.sameAppId(s, norm)) {
                            known = i;
                            break;
                        }
                    }
                    if (known == null) {
                        const owned = gpa.dupe(u8, norm) catch {
                            gpa.free(norm);
                            continue;
                        };
                        gpa.free(norm);
                        group_strs.append(gpa, owned) catch {
                            gpa.free(owned);
                            continue;
                        };
                        seen.append(gpa, group_strs.items[group_strs.items.len - 1]) catch continue;
                        const icon_owned = gpa.dupe(u8, w.app_id) catch continue;
                        group_strs.append(gpa, icon_owned) catch {
                            gpa.free(icon_owned);
                            continue;
                        };
                        groups.append(gpa, .{
                            .key = group_strs.items[group_strs.items.len - 2],
                            .icon_id = group_strs.items[group_strs.items.len - 1],
                            .serial = 0,
                            .active = w.active,
                        }) catch continue;
                    } else {
                        gpa.free(norm);
                    }
                }
            } else {
                for (self.toplevels.windows.items, 0..) |w, i| {
                    if (w.closed) continue;
                    const key = std.fmt.allocPrint(gpa, "__eh_tl_{d}", .{i}) catch continue;
                    group_strs.append(gpa, key) catch {
                        gpa.free(key);
                        continue;
                    };
                    const icon2 = gpa.dupe(u8, w.app_id) catch continue;
                    group_strs.append(gpa, icon2) catch {
                        gpa.free(icon2);
                        continue;
                    };
                    groups.append(gpa, .{
                        .key = group_strs.items[group_strs.items.len - 2],
                        .icon_id = group_strs.items[group_strs.items.len - 1],
                        .serial = 0,
                        .active = w.active,
                    }) catch continue;
                }
            }
        }
        self.group_strings = group_strs.toOwnedSlice(gpa) catch &.{};
        self.groups = groups.toOwnedSlice(gpa) catch &.{};

        // Tray keys.
        if (self.tray_init) {
            self.tray_keys = self.tray.keys(gpa) catch &.{};
        }

        const ctx = tb_strip.Ctx{
            .pinned = self.pins,
            .running = self.groups,
            .tray_keys = self.tray_keys,
        };
        self.sections = tb_strip.buildAll(gpa, cfg, &ctx) catch .{};
        // Metrics first (widths need them; icon px feeds the fingerprint).
        const ui = self.uiScale();
        const box_h: f64 = @floatFromInt(@max(1, self.barHeight()));
        const icon = self.iconPx(box_h);
        const gap: f64 = @as(f64, @floatFromInt(cfg.taskbar.icon_spacing)) * ui;
        const strip_pad = tb_settings.stripPadPx(ui);
        self.eff_show_labels = cfg.taskbar.show_labels;
        self.eff_label_max_w = 0;
        self.syncWidths();
        self.measureWidths(icon, gap, ui);
        // Overflow against the narrowest bar decides the label budget.
        var narrowest: f64 = std.math.floatMax(f64);
        for (self.bars.items) |*b| {
            if (b.w > 0) narrowest = @min(narrowest, @as(f64, @floatFromInt(b.w)));
        }
        if (narrowest == std.math.floatMax(f64)) narrowest = 1200;
        const inner = strip_pad * 2.0;
        const avail = @max(0.0, narrowest - inner);
        // Global regroup fallback (`taskbar.cpp:4617`): an UNGROUPED strip
        // that overflows even the widest bar re-groups its windows first,
        // then the whole pass re-runs on the grouped buttons. Only multi-
        // window apps are worth the retry — single-window groups look the
        // same either way.
        if (!cfg.taskbar.group_apps and !self.group_force and cfg.taskbar.collapse_when_full and
            self.totalWidth(gap) > avail and self.hasMultiWindowApp())
        {
            var widest: f64 = 0;
            for (self.bars.items) |*b| {
                if (b.w > 0) widest = @max(widest, @as(f64, @floatFromInt(b.w)));
            }
            if (widest > 0 and self.totalWidth(gap) > @max(0.0, widest - inner)) return true;
        }
        // Collapse when full (`taskbar.cpp:4715`): an overflowing labeled
        // strip drops every label and falls back to icon-only buttons. This
        // runs BEFORE the shrink/chevron passes, so a collapsed strip never
        // shows the shrunken labels or the overflow chevron either.
        if (self.eff_show_labels and cfg.taskbar.collapse_when_full and self.totalWidth(gap) > avail) {
            self.eff_show_labels = false;
            self.eff_label_max_w = 0;
            self.measureWidths(icon, gap, ui);
        }
        // Shrink-to-fit (`taskbar_paint.cpp:1129`): narrow labels toward the
        // minimum width; buttons that still don't fit hide behind the chevron.
        const total = self.totalWidth(gap);
        if (self.eff_show_labels and total > avail) {
            var n_labeled: usize = 0;
            for (self.sections.all) |*sl| {
                if (sl.kind == .app and self.titleForSerial(sl.chosen_serial).len > 0) n_labeled += 1;
            }
            if (n_labeled > 0) {
                const overflow = total - avail;
                self.eff_label_max_w = tb_slots.shrinkLabelMaxW(
                    tb_slots.labelMaxW(ui, 0),
                    tb_slots.labelMinW(ui),
                    overflow,
                    n_labeled,
                );
                self.measureWidths(icon, gap, ui);
            }
        }
        // Overflow chevron: hide trailing running buttons behind a chevron
        // instead of hiding every label (taskbar_paint.cpp:1171). May mutate
        // sections, so every parallel array re-syncs after it.
        if (self.eff_show_labels) self.applyChevron(icon, gap, ui, avail);
        self.syncWidths();
        self.measureWidths(icon, gap, ui);
        // Icons, labels, glow, runs: all keyed to the FINAL sections.
        // (Trash resolves inside syncIcons: overwriting outside the guarded
        // resolve leaked one decode per rebuild.)
        self.syncIcons(icon);
        self.trimLabels(ui);
        self.syncGlow();
        self.computeRuns(gap);
        // Per-bar placements (sections anchored with inner padding).
        for (self.bars.items) |*b| {
            self.placeBar(b, gap, ui);
        }
        self.hover = -1;
        self.pressed = -1;
        return false;
    }

    /// True when at least one app owns two or more live windows — the only
    /// case where re-grouping an ungrouped strip changes the buttons.
    fn hasMultiWindowApp(self: *Taskbar) bool {
        if (!self.ft_init) return false;
        const list = self.ft.list();
        for (list, 0..) |tl, i| {
            if (tl.closed or tl.handle == null) continue;
            for (list[i + 1 ..]) |tl2| {
                if (tl2.closed or tl2.handle == null) continue;
                if (paths.sameAppId(tl.app_id, tl2.app_id)) return true;
            }
        }
        return false;
    }

    /// Reallocate every section-parallel array to the CURRENT sections
    /// length. Must run after any mutation (chevron) and before anything
    /// indexes by slot — stale lengths were an out-of-bounds crash.
    fn syncWidths(self: *Taskbar) void {
        const gpa = self.app.gpa;
        const n = self.sections.all.len;
        if (self.widths.len != n) {
            if (self.widths.len > 0) gpa.free(self.widths);
            self.widths = gpa.alloc(f64, n) catch &.{};
        }
    }

    /// Re-resolve icons only when their inputs moved (fingerprint over keys,
    /// order, icon px, theme, trash state). Quiet seconds keep pixels.
    fn syncIcons(self: *Taskbar, icon: f64) void {
        const gpa = self.app.gpa;
        const n = self.sections.all.len;
        const icon_px: i32 = @intFromFloat(@round(@max(16.0, icon * 2.0)));
        const fp = self.iconFingerprint(icon_px);
        if (fp == self.icons_fp and self.icons.len == n and self.icon_owned.len == n) return;
        self.freeIcons();
        self.icons = gpa.alloc(dwp.IconPx, n) catch &.{};
        self.icon_owned = gpa.alloc(icon_cache.Owned, n) catch &.{};
        for (self.icon_owned) |*o| o.* = .{ .pixels = &.{}, .w = 0, .h = 0 };
        // Every slot starts empty: only app/tray/logo/trash arms resolve
        // below, but the menu/drawer/overview arms READ their slot — an
        // uninitialized IconPx reads as a garbage slice and cairo faults.
        for (self.icons) |*ic| ic.* = .{};
        self.icons_fp = fp;
        // Logo follows icon px: this path runs only when icons re-resolve,
        // so free the old raster and reload — no view may dangle.
        if (self.distro_pixels.len > 0) gpa.free(self.distro_pixels);
        self.distro_pixels = &.{};
        self.distro_w = 0;
        self.distro_h = 0;
        {
            // Logo size follows icon px: free the old raster whenever icons
            // re-resolve so no IconPx view ever dangles (the pixman crash).
            const logo_px: i32 = @intFromFloat(@round(@max(16.0, icon * 2.0)));
            if (os_logo.loadDistroLogo(gpa, self.app.io, logo_px)) |px| {
                self.distro_pixels = px.data;
                self.distro_w = px.w;
                self.distro_h = px.h;
            }
        }
        if (icon_cache.shared() == null) return;
        for (self.sections.all, 0..) |*sl, i| {
            if (i >= self.icons.len) break;
            if (sl.kind == .app) {
                self.icons[i] = self.resolveAppIcon(sl.icon_id, icon_px);
            } else if (sl.kind == .tray) {
                self.icons[i] = self.resolveTrayIcon(sl.key);
            } else if (sl.kind == .smenu or sl.kind == .spotlight or sl.kind == .app_drawer or sl.kind == .app_menu) {
                // Spotlight/AppDrawer/Smenu/AppMenu all wear the distribution
                // mark (taskbar_paint.cpp:1362 + 1433). The App menu's button
                // is the launcher in list mode, so it takes the same face.
                if (self.distro_pixels.len > 0) {
                    self.icons[i] = .{ .pixels = self.distro_pixels, .w = self.distro_w, .h = self.distro_h };
                }
            } else if (sl.kind == .trash) {
                // Theme trash state (the fingerprint includes trash_full, so
                // a toggle re-resolves exactly once, right here).
                const name = if (self.trash_full) "user-trash-full" else "user-trash";
                const tpx: i32 = @intFromFloat(@round(@max(16.0, icon * 2.0)));
                self.icons[i] = self.resolveAppIcon(name, tpx);
            } else if (sl.kind == .audio_center) {
                // Shell component art (the icon installed from
                // `src/resources/icons/audio-center.svg`), same naming rule
                // the dock uses for the settings gear.
                const tpx: i32 = @intFromFloat(@round(@max(16.0, icon * 2.0)));
                self.icons[i] = self.resolveAppIcon("event-horizon-audio-center", tpx);
            }
        }
        // Workspace cells copy from these pixels; refresh the per-cell
        // surfaces here, where the icon table is known complete.
        self.refreshWsIcons();
    }

    fn syncGlow(self: *Taskbar) void {
        const gpa = self.app.gpa;
        const n = self.sections.all.len;
        if (self.glow.len != n) {
            if (self.glow.len > 0) gpa.free(self.glow);
            self.glow = gpa.alloc(GlowCol, n) catch &.{};
            for (self.glow) |*g| g.* = .{};
        }
        self.computeGlow();
    }

    fn applyChevron(self: *Taskbar, icon: f64, gap: f64, ui: f64, avail: f64) void {
        const gpa = self.app.gpa;
        if (avail <= 0) return;
        if (self.totalWidth(gap) <= avail) return;
        // Only labeled running buttons are candidates (C++ drops trailing
        // App slots with a live window, pinned-or-not).
        var candidates = false;
        for (self.sections.all) |*sl| {
            if (sl.kind == .app and sl.chosen_serial != 0 and !std.mem.eql(u8, sl.key, tb_types.chevron_key)) {
                candidates = true;
                break;
            }
        }
        if (!candidates) return;
        const chev_w = icon;
        var kept: std.ArrayList(tb_types.PaintSlot) = .empty;
        errdefer kept.deinit(gpa);
        // Widths stay parallel to `kept` so the overflow math never reads a
        // stale index after a removal.
        var kept_w: std.ArrayList(f64) = .empty;
        defer kept_w.deinit(gpa);
        for (self.sections.all, 0..) |sl, wi| {
            kept.append(gpa, sl) catch return;
            kept_w.append(gpa, if (wi < self.widths.len) self.widths[wi] else icon) catch return;
        }
        var hidden_groups: std.ArrayList([]ThumbWin) = .empty;
        defer {
            for (hidden_groups.items) |grp| gpa.free(grp);
            hidden_groups.deinit(gpa);
        }
        var total = self.totalWidth(gap);
        while (kept.items.len > 1 and total + gap + chev_w > avail) {
            var drop: ?usize = null;
            var k: usize = kept.items.len;
            while (k > 0) {
                k -= 1;
                const sl = kept.items[k];
                if (sl.kind == .app and sl.chosen_serial != 0 and !std.mem.eql(u8, sl.key, tb_types.chevron_key)) {
                    drop = k;
                    break;
                }
            }
            const di = drop orelse break;
            const sl = kept.items[di];
            var grp: std.ArrayList(ThumbWin) = .empty;
            if (self.ft_init) {
                for (self.ft.list()) |tl| {
                    if (tl.closed or tl.handle == null) continue;
                    if (sl.key.len > 0 and sl.key[0] == '_' and std.mem.startsWith(u8, sl.key, "__eh_tl_")) {
                        if (tl.serial == sl.chosen_serial) grp.append(gpa, .{ .serial = tl.serial }) catch break;
                    } else if (paths.sameAppId(sl.key, tl.app_id)) {
                        grp.append(gpa, .{ .serial = tl.serial }) catch break;
                    }
                }
            }
            const grp_slice = grp.toOwnedSlice(gpa) catch {
                grp.deinit(gpa);
                break;
            };
            hidden_groups.append(gpa, grp_slice) catch {
                gpa.free(grp_slice);
                break;
            };
            _ = kept.orderedRemove(di);
            _ = kept_w.orderedRemove(di);
            total = 0;
            for (kept.items, 0..) |*a, ai| {
                total += kept_w.items[ai];
                if (ai + 1 < kept.items.len) total += self.slotGap(a, &kept.items[ai + 1], gap);
            }
        }
        var hidden: std.ArrayList(ThumbWin) = .empty;
        errdefer hidden.deinit(gpa);
        {
            // C++ order: groups in reverse drop order (leftmost dropped
            // group first), windows in serial order inside each group.
            var gi = hidden_groups.items.len;
            while (gi > 0) {
                gi -= 1;
                for (hidden_groups.items[gi]) |w| hidden.append(gpa, w) catch break;
            }
        }
        if (hidden.items.len == 0) return;
        kept.append(gpa, .{ .kind = .app, .key = tb_types.chevron_key, .is_pinned = false }) catch return;
        // Rebuild all parallel arrays around the kept list (centered). The
        // section slices keep SEPARATE backings: Sections.deinit frees each.
        const was_win7 = self.sections.win7;
        self.sections.deinit(gpa);
        const all = kept.toOwnedSlice(gpa) catch return;
        errdefer gpa.free(all);
        const center = gpa.dupe(tb_types.PaintSlot, all) catch return;
        self.sections = .{
            .left = &.{},
            .center = center,
            .right = &.{},
            .all = all,
            .win7 = was_win7,
        };
        if (self.chev_wins.len > 0) gpa.free(self.chev_wins);
        self.chev_wins = hidden.toOwnedSlice(gpa) catch &.{};
        self.measureWidths(icon, gap, ui);
    }

    fn trimLabels(self: *Taskbar, ui: f64) void {
        const gpa = self.app.gpa;
        for (self.slot_labels) |l| gpa.free(l);
        if (self.slot_labels.len > 0) gpa.free(self.slot_labels);
        const n = self.sections.all.len;
        self.slot_labels = gpa.alloc([]u8, n) catch &.{};
        for (self.slot_labels) |*l| l.* = &.{};
        if (!self.eff_show_labels) return;
        const font_px = tb_slots.labelFontPx(ui);
        const max_w = tb_slots.labelMaxW(ui, self.eff_label_max_w);
        for (self.sections.all, 0..) |*sl, i| {
            if (sl.kind != .app) continue;
            const title = self.titleForSerial(sl.chosen_serial);
            if (title.len == 0) continue;
            self.slot_labels[i] = self.trimOne(title, font_px, max_w) catch &.{};
        }
    }

    fn trimOne(self: *Taskbar, text: []const u8, font_px: f64, max_w: f64) ![]u8 {
        const gpa = self.app.gpa;
        if (self.measureLabel(text, font_px) <= max_w) return gpa.dupe(u8, text);
        const ell = "…";
        const ell_w = self.measureLabel(ell, font_px);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        while (i < text.len) {
            var len: usize = 1;
            const c0: u8 = text[i];
            if ((c0 & 0x80) == 0) len = 1 else if ((c0 & 0xE0) == 0xC0) len = 2 else if ((c0 & 0xF0) == 0xE0) len = 3 else if ((c0 & 0xF8) == 0xF0) len = 4;
            if (i + len > text.len) break;
            try out.appendSlice(gpa, text[i .. i + len]);
            i += len;
            if (self.measureLabel(out.items, font_px) + ell_w > max_w) {
                out.items.len -= len;
                while (out.items.len > 0 and self.measureLabel(out.items, font_px) + ell_w > max_w) {
                    var e = out.items.len - 1;
                    while (e > 0 and (out.items[e] & 0xC0) == 0x80) e -= 1;
                    out.items.len = e;
                }
                break;
            }
        }
        try out.appendSlice(gpa, ell);
        return out.toOwnedSlice(gpa);
    }

    fn computeGlow(self: *Taskbar) void {
        const gpa = self.app.gpa;
        const n = self.sections.all.len;
        if (self.glow.len != n) {
            if (self.glow.len > 0) gpa.free(self.glow);
            self.glow = gpa.alloc(GlowCol, n) catch &.{};
            for (self.glow) |*g| g.* = .{};
        }
        for (self.sections.all, 0..) |*sl, i| {
            if (i >= self.glow.len or i >= self.icons.len) break;
            if (sl.kind != .app) continue;
            const ic = self.icons[i];
            if (ic.pixels.len == 0 or ic.w <= 0 or ic.h <= 0) continue;
            if (tb_paint.hotTrack(ic.pixels, @intCast(ic.w), @intCast(ic.h), @intCast(ic.w * 4))) |c| {
                self.glow[i] = .{ .r = c.r, .g = c.g, .b = c.b, .ok = true };
            }
        }
    }

    /// Cairo surface for one workspace cell's app key. Borrowed for the
    /// paint only; the cache owns both the bytes and the surface.
    fn wsIconSurf(ctx: *anyopaque, key: []const u8) ?*cairo.cairo_surface_t {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        const e = self.ws_surfs.get(key) orelse return null;
        return e.surf;
    }

    fn clearWsSurfs(self: *Taskbar) void {
        if (!self.ws_surfs_init) return;
        var it = self.ws_surfs.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.surf) |sf| cairo.cairo_surface_destroy(sf);
            self.app.gpa.free(e.value_ptr.pixels);
            self.app.gpa.free(e.key_ptr.*);
        }
        self.ws_surfs.clearRetainingCapacity();
    }

    /// `StreamIcons.get` for the volume-mixer card: themed name to a cached
    /// cairo surface. The widget's cascade falls back to its gray glyph when
    /// this returns null, so misses are memoized instead of re-walked.
    fn mxIconSurf(ctx: *anyopaque, name: []const u8) ?*cairo.cairo_surface_t {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        if (name.len == 0) return null;
        const gpa = self.app.gpa;
        for (self.mx_icons.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.surf;
        }
        if (self.mx_icons.items.len >= 32) return null;
        var owned: icon_cache.Owned = .{ .pixels = &.{}, .w = 0, .h = 0 };
        if (icon_cache.shared()) |ic| {
            if (ic.getOwned(.app, name, 32)) |o| owned = o;
        }
        const owned_name = gpa.dupe(u8, name) catch {
            var o = owned;
            o.deinit(gpa);
            return null;
        };
        var surf: ?*cairo.cairo_surface_t = null;
        if (owned.pixels.len > 0 and owned.w > 0 and owned.h > 0) {
            const s = cairo.cairo_image_surface_create_for_data(
                owned.pixels.ptr,
                cairo.CAIRO_FORMAT_ARGB32,
                owned.w,
                owned.h,
                owned.w * 4,
            );
            if (cairo.cairo_surface_status(s) == cairo.CAIRO_STATUS_SUCCESS) {
                surf = s;
            } else {
                cairo.cairo_surface_destroy(s);
            }
        }
        self.mx_icons.append(gpa, .{
            .name = owned_name,
            .pixels = owned.pixels,
            .surf = surf,
        }) catch {
            gpa.free(owned_name);
            if (surf) |s| cairo.cairo_surface_destroy(s);
            var o = owned;
            o.deinit(gpa);
            return null;
        };
        return surf;
    }

    fn freeMxIcons(self: *Taskbar) void {
        const gpa = self.app.gpa;
        for (self.mx_icons.items) |e| {
            if (e.surf) |s| cairo.cairo_surface_destroy(s);
            gpa.free(e.name);
            if (e.pixels.len > 0) gpa.free(e.pixels);
        }
        self.mx_icons.deinit(gpa);
        self.mx_icons = .empty;
    }

    /// Rebuild the workspace-cell surfaces from the resolved strip pixels.
    /// Runs at the end of icon resolution so the cells never point at freed
    /// art: every surface copies the bytes it shows.
    fn refreshWsIcons(self: *Taskbar) void {
        if (!self.ws_surfs_init) return;
        self.clearWsSurfs();
        if (self.ws_entries.len == 0) return;
        const gpa = self.app.gpa;
        var kept: usize = 0;
        for (self.ws_entries) |e| {
            for (e.app_keys) |key| {
                if (kept >= 40) return;
                if (self.ws_surfs.contains(key)) continue;
                for (self.sections.all, 0..) |sl, i| {
                    if (sl.kind != .app or i >= self.icons.len) continue;
                    if (!eh.shell_paths.sameAppId(key, sl.key)) continue;
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

    fn computeRuns(self: *Taskbar, gap: f64) void {
        const gpa = self.app.gpa;
        const cfg = &self.app.loaded.cfg;
        if (self.runs.len > 0) gpa.free(self.runs);
        self.runs = &.{};
        var list: std.ArrayList(RunSpan) = .empty;
        errdefer list.deinit(gpa);
        _ = gap;
        var i: usize = 0;
        while (i < self.sections.all.len) {
            const sl = self.sections.all[i];
            var len: usize = 0;
            if (sl.kind == .tray) {
                len = 1;
                while (i + len < self.sections.all.len and self.sections.all[i + len].kind == .tray) : (len += 1) {}
            } else if (sl.kind == .app and sl.is_pinned and !sl.win7 and cfg.taskbar.pinned_apps_tray_pill) {
                len = 1;
                while (i + len < self.sections.all.len) {
                    const t = self.sections.all[i + len];
                    if (t.kind != .app or !t.is_pinned or t.win7) break;
                    len += 1;
                }
            } else if (sl.kind == .app and !sl.is_pinned and !sl.win7 and cfg.taskbar.running_apps_tray_pill) {
                len = 1;
                while (i + len < self.sections.all.len) {
                    const t = self.sections.all[i + len];
                    if (t.kind != .app or t.is_pinned or t.win7) break;
                    len += 1;
                }
            }
            if (len > 1) list.append(gpa, .{ .start = i, .len = len }) catch break;
            i += @max(len, 1);
        }
        self.runs = list.toOwnedSlice(gpa) catch &.{};
    }

    fn pollTrashFs(self: *Taskbar, now_ms: u64) bool {
        if (now_ms < self.trash_next_ms) return false;
        self.trash_next_ms = now_ms + 5000;
        var full = false;
        const home = self.app.home orelse "/tmp";
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&path_buf, "{s}/.local/share/Trash/files", .{home}) catch "";
        if (dir_path.len > 0) {
            var dir = std.Io.Dir.openDirAbsolute(self.app.io, dir_path, .{ .iterate = true }) catch null;
            if (dir != null) {
                defer dir.?.close(self.app.io);
                var it = dir.?.iterate();
                while (it.next(self.app.io) catch null) |e| {
                    if (e.name.len > 0) {
                        full = true;
                        break;
                    }
                }
            }
        }
        if (full == self.trash_full) return false;
        self.trash_full = full;
        return true;
    }

    fn slotGap(self: *Taskbar, a: *const tb_types.PaintSlot, b: *const tb_types.PaintSlot, gap: f64) f64 {
        const cfg = &self.app.loaded.cfg;
        if (a.kind == .tray and b.kind == .tray) return 0;
        if (a.kind == .app and a.is_pinned and b.kind == .app and b.is_pinned)
            return if (cfg.taskbar.pinned_apps_tray_pill) 0 else gap;
        if (a.kind == .app and !a.is_pinned and b.kind == .app and !b.is_pinned)
            return if (cfg.taskbar.running_apps_tray_pill) 0 else gap;
        return gap;
    }

    fn appLabelExtra(self: *Taskbar, serial: u64, ui: f64) f64 {
        if (!self.eff_show_labels) return 0;
        const title = self.titleForSerial(serial);
        if (title.len == 0) return 0;
        const font_px = tb_slots.labelFontPx(ui);
        const max_w = tb_slots.labelMaxW(ui, self.eff_label_max_w);
        const w = @min(self.measureLabel(title, font_px), max_w);
        return tb_slots.labelExtraW(w, ui);
    }

    fn toDockKind(kind: tb_types.SlotKind) dw.Kind {
        return switch (kind) {
            .app => .app,
            .tray => .tray,
            .settings => .settings,
            .audio_center => .audio_center,
            .spotlight => .spotlight,
            .app_menu => .app_menu,
            .app_drawer => .app_drawer,
            .clock => .clock,
            .weather => .weather,
            .media => .media,
            .workspaces => .workspaces,
            .control_center => .control_center,
            .pear_center => .pear_center,
            .trash => .trash,
            .volume_mixer => .volume_mixer,
            .battery => .battery,
            .bluetooth => .bluetooth,
            .vpn => .vpn,
            .layout => .layout,
            .world_clock => .world_clock,
            .overview => .overview,
            .clipstack => .clipstack,
            .separator => .clock,
            .smenu => .smenu,
        };
    }

    fn measureWidths(self: *Taskbar, icon: f64, gap: f64, ui: f64) void {
        const cfg = &self.app.loaded.cfg;
        const box_h: f64 = @floatFromInt(@max(1, self.barHeight()));
        const m = dw.Metrics{
            .icon = icon,
            .gap = gap,
            .bar_h = box_h,
            .ui_scale = ui,
            .strip_inner = tb_settings.stripPadPx(ui),
            .pill_x = 0,
            .box_w = 1000,
        };
        const meas = self.liveMeasured(icon, box_h);
        for (self.sections.all, 0..) |*s, i| {
            if (i >= self.widths.len) break;
            if (s.kind == .app) {
                self.widths[i] = icon + self.appLabelExtra(s.chosen_serial, ui);
            } else if (s.kind == .separator) {
                self.widths[i] = @max(4.0, 6.0 * ui);
            } else if (s.kind == .tray) {
                self.widths[i] = icon;
            } else if (s.kind == .battery) {
                self.widths[i] = self.batteryWidth(icon, ui);
            } else if (s.kind == .pear_center) {
                // Own pill with the control center's shape (`pear_slot`),
                // fed this bar's live runtime so the width follows the
                // glyph count the same way the paint does.
                const pcfg = pear_slot.loadCfg(cfg, s.key);
                self.widths[i] = pear_slot.slotWidth(icon, box_h, pear_slot.iconCount(pcfg, self.pear_rt));
            } else {
                const ds = dw.Slot{ .kind = toDockKind(s.kind), .key = s.key };
                self.widths[i] = dw.slotWidth(cfg, ds, m, meas);
            }
        }
    }

    fn totalWidth(self: *Taskbar, gap: f64) f64 {
        var total: f64 = 0;
        for (self.sections.all, 0..) |*s, i| {
            total += self.widths[i];
            if (i + 1 < self.sections.all.len) total += self.slotGap(s, &self.sections.all[i + 1], gap);
        }
        return total;
    }

    fn placeBar(self: *Taskbar, b: *Bar, gap: f64, ui: f64) void {
        const gpa = self.app.gpa;
        const box_w: f64 = @floatFromInt(@max(1, b.w));
        const n = self.sections.all.len;
        if (b.xs.len != n) {
            if (b.xs.len > 0) gpa.free(b.xs);
            if (b.ws.len > 0) gpa.free(b.ws);
            b.xs = gpa.alloc(f64, n) catch &.{};
            b.ws = gpa.alloc(f64, n) catch &.{};
        }
        if (n == 0) return;
        const strip_pad = tb_settings.stripPadPx(ui);
        const sec_gap = tb_settings.sectionGapPx(ui);
        // Section widths.
        var lw: f64 = 0;
        var cw: f64 = 0;
        var rw: f64 = 0;
        const left_n = self.sections.left.len;
        const center_n = self.sections.center.len;
        for (self.sections.all, 0..) |*s, i| {
            if (i < left_n) {
                lw += self.widths[i];
                if (i + 1 < left_n) lw += self.slotGap(s, &self.sections.all[i + 1], gap);
            } else if (i < left_n + center_n) {
                cw += self.widths[i];
                if (i + 1 < left_n + center_n) cw += self.slotGap(s, &self.sections.all[i + 1], gap);
            } else {
                rw += self.widths[i];
                if (i + 1 < n) rw += self.slotGap(s, &self.sections.all[i + 1], gap);
            }
        }
        // Anchored strip: left at the padded start, right at the padded end,
        // and the center balanced in the free run between them. This is the
        // layout whenever the three sections, their padding and the
        // inter-section gaps fit inside the bar end to end — the sides never
        // move and the center cannot touch either one because its box is
        // placed inside that free run. (The old rule also demanded the
        // screen-centered center not reach the anchored sides, which tripped
        // on lopsided sections — a wide right group and a narrow left one —
        // and dumped a bar that easily fit into the centered strip below.)
        // Only a strip that genuinely cannot fit falls through to the
        // centered (and, when needed, compressed) strip.
        const right_n = self.sections.right.len;
        var need = strip_pad * 2.0;
        var present: usize = 0;
        if (left_n > 0) {
            need += lw;
            present += 1;
        }
        if (center_n > 0) {
            need += cw;
            present += 1;
        }
        if (right_n > 0) {
            need += rw;
            present += 1;
        }
        if (present > 1) need += sec_gap * @as(f64, @floatFromInt(present - 1));
        if (need <= box_w + 1e-9) {
            // Side anchors are unconditional: the left group keeps the padded
            // start and the right group the padded end, empty center or not.
            const anchors = tb_slots.sideAnchors(box_w, strip_pad, rw);
            const lc = anchors.left_x;
            const rc = anchors.right_x;
            // The free run between the anchored ends — the bar's own center
            // when neither side is present. `need` above proves it is at
            // least `cw` wide.
            const zone_lo = if (left_n > 0) lc + lw + sec_gap else strip_pad;
            const zone_hi = if (right_n > 0) rc - sec_gap else box_w - strip_pad;
            const cc = (zone_lo + zone_hi - cw) * 0.5;
            for (self.sections.all, 0..) |*s, i| {
                if (i < left_n) {
                    b.xs[i] = lc + self.offsetIn(self.sections.all[0..left_n], i, gap);
                } else if (i < left_n + center_n) {
                    b.xs[i] = cc + self.offsetIn(self.sections.all[left_n .. left_n + center_n], i - left_n, gap);
                } else {
                    b.xs[i] = rc + self.offsetIn(self.sections.all[left_n + center_n ..], i - left_n - center_n, gap);
                }
                b.ws[i] = self.widths[i];
                _ = s;
            }
            return;
        }
        // Centered strip when nothing else fits.
        const total = self.totalWidth(gap);
        const hscale = tb_slots.stripHScale(box_w, total, strip_pad * 2.0);
        const mid = box_w * 0.5;
        var lx: f64 = (box_w - total) * 0.5;
        for (self.sections.all, 0..) |*s, i| {
            b.xs[i] = mid + (lx - mid) * hscale;
            b.ws[i] = self.widths[i] * hscale;
            lx += self.widths[i];
            if (i + 1 < n) lx += self.slotGap(s, &self.sections.all[i + 1], gap);
        }
    }

    fn offsetIn(self: *Taskbar, slots: []const tb_types.PaintSlot, idx: usize, gap: f64) f64 {
        var x: f64 = 0;
        var i: usize = 0;
        while (i < idx) : (i += 1) {
            x += self.widths[self.indexOf(slots[i])];
            if (i + 1 < slots.len) x += self.slotGap(&slots[i], &slots[i + 1], gap);
        }
        return x;
    }

    fn indexOf(self: *Taskbar, slot: tb_types.PaintSlot) usize {
        for (self.sections.all, 0..) |*s, i| {
            if (s.key.ptr == slot.key.ptr and s.kind == slot.kind) return i;
        }
        return 0;
    }

    fn resolveAppIcon(self: *Taskbar, key: []const u8, icon_px: i32) dwp.IconPx {
        const ic = icon_cache.shared() orelse return .{};
        const idx = self.iconIndexForSlot();
        if (ic.getOwned(.app, key, icon_px)) |*o| {
            self.icon_owned[idx] = o.*;
            return .{ .pixels = self.icon_owned[idx].pixels, .w = self.icon_owned[idx].w, .h = self.icon_owned[idx].h };
        }
        return .{};
    }

    fn iconIndexForSlot(self: *Taskbar) usize {
        // Linear probe for the first empty icon slot (rebuild fills in order).
        for (self.icon_owned, 0..) |*o, i| {
            if (o.pixels.len == 0) return i;
        }
        return 0;
    }

    fn resolveTrayIcon(self: *Taskbar, key: []const u8) dwp.IconPx {
        if (self.tray_init) {
            if (self.tray.itemForKey(key)) |it| {
                if (it.pixels.len > 0 and it.pw > 0 and it.ph > 0) {
                    // Copy: the tray store frees pixmaps on re-sync while
                    // icons[] keeps pointing at them (the spawn-loop crash).
                    const gpa = self.app.gpa;
                    const owned = gpa.dupe(u8, it.pixels) catch return .{};
                    errdefer gpa.free(owned);
                    const idx = self.iconIndexForSlot();
                    if (idx < self.icon_owned.len and self.icon_owned[idx].pixels.len == 0) {
                        self.icon_owned[idx] = .{ .pixels = owned, .w = it.pw, .h = it.ph };
                        return .{ .pixels = owned, .w = it.pw, .h = it.ph };
                    }
                    gpa.free(owned);
                    return .{};
                }
                if (it.icon_name.len > 0) {
                    if (icon_cache.shared()) |ic| {
                        const idx = self.iconIndexForSlot();
                        if (ic.getOwned(.tray, it.icon_name, 48)) |*o| {
                            self.icon_owned[idx] = o.*;
                            return .{ .pixels = self.icon_owned[idx].pixels, .w = self.icon_owned[idx].w, .h = self.icon_owned[idx].h };
                        }
                    }
                }
            }
        }
        return .{};
    }

    fn serialForApp(self: *Taskbar, app_id: []const u8) u64 {
        if (!self.ft_init) return 0;
        for (self.ft.list()) |tl| {
            if (tl.closed or tl.handle == null) continue;
            if (paths.sameAppId(app_id, tl.app_id)) return tl.serial;
        }
        return 0;
    }

    fn activeForApp(self: *Taskbar, app_id: []const u8) bool {
        if (!self.ft_init) return false;
        for (self.ft.list()) |tl| {
            if (tl.closed) continue;
            if (paths.sameAppId(app_id, tl.app_id) and tl.activated) return true;
        }
        return false;
    }

    fn focusExisting(self: *Taskbar, target: []const u8) bool {
        if (!self.ft_init) return false;
        const seat = self.app.bound.seat;
        // A per-window key (`__eh_tl_<serial>`) targets exactly its window.
        if (std.mem.startsWith(u8, target, "__eh_tl_")) {
            const serial = std.fmt.parseInt(u64, target["__eh_tl_".len..], 10) catch return false;
            for (self.ft.list()) |tl| {
                if (tl.closed or tl.handle == null or tl.serial != serial) continue;
                if (!self.ft.raiseToplevel(&tl, seat)) break;
                _ = self.app.conn.flush();
                return true;
            }
            return false;
        }
        for (self.ft.list()) |tl| {
            if (tl.closed or tl.handle == null) continue;
            if (!paths.sameAppId(target, tl.app_id)) continue;
            if (!self.ft.raiseToplevel(&tl, seat)) break;
            _ = self.app.conn.flush();
            return true;
        }
        return false;
    }

    fn launchSlot(self: *Taskbar, target: []const u8) void {
        const gpa = self.app.gpa;
        const dirs = app_launch.applicationsDirs(gpa, getenvStr("XDG_DATA_HOME"), getenvStr("HOME"), getenvStr("XDG_DATA_DIRS")) catch return;
        defer app_launch.freeDirs(gpa, dirs);
        if (app_launch.launch(gpa, self.app.io, dirs, target)) {
            self.startBounce(target, false);
        } else {
            logz.err("activate: failed to launch '{s}'", .{target});
        }
    }

    fn activateSlot(self: *Taskbar, slot: *const tb_types.PaintSlot) void {
        if (slot.kind == .app) {
            const per_window = std.mem.startsWith(u8, slot.key, "__eh_tl_");
            const target = if (slot.icon_id.len > 0) slot.icon_id else slot.key;
            if (slot.chosen_serial != 0) {
                const focus_target = if (per_window) slot.key else target;
                if (self.focusExisting(focus_target)) {
                    self.startBounce(slot.key, false);
                    return;
                }
                // A dead per-window button is not a launch (the app is
                // running, the window is gone).
                if (per_window) return;
            } else if (!per_window and self.focusExisting(target)) {
                // Stale strip: the group saw no window at build time but one
                // is live now.
                self.startBounce(slot.key, false);
                return;
            }
            // C++ launches from cold only for pins; a stale unpinned group
            // does nothing.
            if (!slot.is_pinned) return;
            self.launchSlot(target);
            self.startBounce(slot.key, true);
        } else if (slot.kind == .settings) {
            // The gear is a shell component, not a desktop file: the copy
            // next to this taskbar wins (the redesigned app ships as
            // `horizon-settings` there). Only a miss falls through to the
            // desktop entry — whose `Exec=horizon-settings` resolves to
            // whichever build PATH finds, typically the old one.
            if (std.mem.eql(u8, slot.key, "rail_settings") and self.launchSibling("settings")) return;
            if (self.launchSibling("horizon-settings")) return;
            self.launchSlot("event-horizon-settings");
        } else if (slot.kind == .audio_center) {
            // Same rule for the mixer: focus a live window (by app id), else
            // the `horizon-audio-center` sitting next to this taskbar.
            if (self.focusExisting("event-horizon-audio-center")) {
                self.startBounce(slot.key, false);
                return;
            }
            if (self.launchSibling("horizon-audio-center")) {
                self.startBounce(slot.key, true);
                return;
            }
            self.launchSlot("event-horizon-audio-center");
            self.startBounce(slot.key, true);
        }
    }

    /// Click-equivalent for a key without a slot (pin-drag release): focus a
    /// matching window, else launch the pinned entry.
    fn activateKey(self: *Taskbar, norm: []const u8, raw: []const u8) void {
        if (self.focusExisting(norm)) {
            self.startBounce(norm, false);
            return;
        }
        self.launchSlot(if (raw.len > 0) raw else norm);
        self.startBounce(norm, true);
    }

    fn startBounce(self: *Taskbar, key: []const u8, cold: bool) void {
        const gpa = self.app.gpa;
        if (self.bounce_key.len > 0) gpa.free(self.bounce_key);
        self.bounce_key = gpa.dupe(u8, key) catch &.{};
        self.bounce_start_ms = nowMs();
        _ = cold;
    }

    fn bounceLiftFor(self: *Taskbar, key: []const u8) f64 {
        if (self.bounce_key.len == 0 or !std.mem.eql(u8, self.bounce_key, key)) return 0;
        return tb_state.bounceLift(@floatFromInt(nowMs() -| self.bounce_start_ms), false);
    }

    /// The launch bounce is one-shot: past its window `bounceLift` is 0 for
    /// good, so drop the key. Leaving it set kept `animated()` true and the
    /// anim timer / frame chain repainting at 60 Hz for the life of the
    /// process (a steady frame stream nobody asked for). 700 ms covers the
    /// longest window (`bounceLift`'s cold-start duration).
    fn bounceRetire(self: *Taskbar) void {
        if (self.bounce_key.len == 0) return;
        if (nowMs() -| self.bounce_start_ms < 700) return;
        const gpa = self.app.gpa;
        gpa.free(self.bounce_key);
        self.bounce_key = &.{};
    }

    // -- paint --------------------------------------------------------

    fn paintBackground(self: *Taskbar, cr: ?*cairo.cairo_t, w: i32, h: i32) void {
        const cfg = &self.app.loaded.cfg;
        const c = cr orelse return;
        const alpha: f64 = @as(f64, @floatFromInt(@max(0, @min(100, cfg.taskbar.opacity)))) / 100.0;
        const radius: f64 = @floatFromInt(@max(0, cfg.taskbar.radius));
        cairo_helpers.paintBar(cr, w, h, radius, alpha);
        if (cfg.taskbar.border and cfg.taskbar.border_size > 0) {
            const bw: f64 = @floatFromInt(cfg.taskbar.border_size);
            cairo_helpers.roundedRect(c, bw * 0.5, bw * 0.5, @as(f64, @floatFromInt(w)) - bw, @as(f64, @floatFromInt(h)) - bw, @max(0, radius - bw * 0.5));
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.14 * alpha + 0.02);
            cairo.cairo_set_line_width(c, bw);
            cairo.cairo_stroke(c);
        }
    }

    fn slotDraw(self: *Taskbar, cr: ?*cairo.cairo_t, slot: *const tb_types.PaintSlot, idx: usize, x: f64, y: f64, w: f64, h: f64, icon_px: f64, ui: f64) void {
        const c = cr orelse return;
        const hovered = @as(i32, @intCast(idx)) == self.hover;
        const pressed = @as(i32, @intCast(idx)) == self.pressed;
        const is_app = slot.kind == .app;
        // App slots lift on hover and dip on press; widget slots paint their
        // own feedback instead.
        const lift: f64 = if (hovered and is_app) 5.0 else 0.0;
        const press_lift: f64 = if (pressed and is_app) 2.0 else 0.0;
        const bounce = self.bounceLiftFor(slot.key);
        if (is_app) {
            self.paintAppSlot(c, slot, idx, x, y, w, h, icon_px, ui, hovered, pressed, lift + press_lift + bounce);
            return;
        }
        var d = dwp.Draw{
            .kind = dw.Kind.app,
            .hover = hovered,
            .press = pressed,
            .lift = lift + bounce,
            // Same rule as the dock's strip: the arms below paint through
            // `paintSlot`, and exactly the kinds that own a pill get one
            // (smenu, trash, overview, settings, …). App and tray are
            // covered by their run pill instead; spotlight, app_drawer and
            // app_menu stay on the bare bar.
            .pill = dw.ownsPill(toDockKind(slot.kind)),
        };
        switch (slot.kind) {
            .app => {},
            .tray => {
                d.kind = .tray;
                d.icon = self.icons[idx];
                dwp.paintSlot(cr, x, y, w, h, icon_px, d);
            },
            .settings => {
                d.kind = .settings;
                d.icon = null;
                d.lucide = if (std.mem.eql(u8, slot.key, "rail_settings")) "view_sidebar" else "settings";
                dwp.paintSlot(cr, x, y, w, h, icon_px, d);
            },
            .audio_center => {
                // Themed art owns the slot (resolved in the icon pass); the
                // slider glyph is the fallback when the icon is not installed.
                d.kind = .audio_center;
                d.icon = self.icons[idx];
                if (d.icon == null or d.icon.?.pixels.len == 0) d.lucide = "tune";
                dwp.paintSlot(cr, x, y, w, h, icon_px, d);
            },
            .spotlight => {
                d.kind = .spotlight;
                d.icon = self.icons[idx];
                if (d.icon == null or d.icon.?.pixels.len == 0) d.lucide = "search";
                dwp.paintSlot(cr, x, y, w, h, icon_px, d);
            },
            .app_menu => {
                d.kind = .app_menu;
                d.icon = self.icons[idx];
                if (d.icon == null or d.icon.?.pixels.len == 0) d.dots = 3;
                dwp.paintSlot(cr, x, y, w, h, icon_px, d);
            },
            .app_drawer, .smenu => {
                d.kind = if (slot.kind == .app_drawer) .app_drawer else .smenu;
                d.icon = self.icons[idx];
                if (d.icon == null or d.icon.?.pixels.len == 0) d.lucide = "apps";
                dwp.paintSlot(cr, x, y, w, h, icon_px, d);
            },
            .trash => {
                d.kind = .trash;
                d.icon = self.icons[idx];
                if (d.icon == null or d.icon.?.pixels.len == 0) d.lucide = "delete";
                dwp.paintSlot(cr, x, y, w, h, icon_px, d);
            },
            .overview => {
                d.kind = .overview;
                d.lucide = "dashboard";
                dwp.paintSlot(cr, x, y, w, h, icon_px, d);
            },
            .clock => self.paintWidgetFace(c, slot, .clock, x, y, w, h, icon_px, hovered, pressed),
            .clipstack => self.paintWidgetFace(c, slot, .clipstack, x, y, w, h, icon_px, hovered, pressed),
            .weather => self.paintWidgetFace(c, slot, .weather, x, y, w, h, icon_px, hovered, pressed),
            .media => self.paintWidgetFace(c, slot, .media, x, y, w, h, icon_px, hovered, pressed),
            .workspaces => self.paintWidgetFace(c, slot, .workspaces, x, y, w, h, icon_px, hovered, pressed),
            .control_center => self.paintWidgetFace(c, slot, .control_center, x, y, w, h, icon_px, hovered, pressed),
            .pear_center => self.paintWidgetFace(c, slot, .pear_center, x, y, w, h, icon_px, hovered, pressed),
            .battery => self.paintWidgetFace(c, slot, .battery, x, y, w, h, icon_px, hovered, pressed),
            .bluetooth => self.paintWidgetFace(c, slot, .bluetooth, x, y, w, h, icon_px, hovered, pressed),
            .vpn => self.paintWidgetFace(c, slot, .vpn, x, y, w, h, icon_px, hovered, pressed),
            .layout => self.paintWidgetFace(c, slot, .layout, x, y, w, h, icon_px, hovered, pressed),
            .world_clock => self.paintWidgetFace(c, slot, .world_clock, x, y, w, h, icon_px, hovered, pressed),
            .volume_mixer => {
                d.kind = .volume_mixer;
                d.lucide = "volume_up";
                d.pill = true;
                dwp.paintSlot(cr, x, y, w, h, icon_px, d);
            },
            .separator => {
                cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.25);
                cairo.cairo_set_line_width(c, 1.0);
                cairo.cairo_move_to(c, x + w / 2.0, y + 4.0);
                cairo.cairo_line_to(c, x + w / 2.0, y + h - 4.0);
                cairo.cairo_stroke(c);
            },
        }
    }

    /// Win7 tasklist button: layered window sheets, glass face while open,
    /// cursor-centered hot-track on hover, centered icon + label,
    /// window-count badge, run dot, and the three-dot overflow chevron.
    fn paintAppSlot(self: *Taskbar, c: *cairo.cairo_t, slot: *const tb_types.PaintSlot, idx: usize, x: f64, y: f64, w: f64, h: f64, icon: f64, ui: f64, hovered: bool, pressed: bool, lift: f64) void {
        const ty = y - lift;
        const nwin = self.windowsForApp(slot.key);
        // The press outline sits outside the press scale; everything else on
        // the button shrinks and dips with it, chevron included.
        const use_press = pressed;
        if (use_press) {
            // Press feedback hugs the icon square, labeled or not.
            cairo_helpers.roundedRect(c, x - 2.0, ty - 2.0, icon + 4.0, icon + 4.0, 14.0);
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.12);
            cairo.cairo_fill_preserve(c);
            cairo.cairo_set_source_rgba(c, 0.55, 0.80, 1.00, 0.58);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_stroke(c);
            const pcx = x + w * 0.5;
            const pcy = ty + icon * 0.5;
            cairo.cairo_save(c);
            cairo.cairo_translate(c, pcx, pcy);
            cairo.cairo_scale(c, anim_mod.kPressIconScale, anim_mod.kPressIconScale);
            cairo.cairo_translate(c, -pcx, -pcy);
        }
        if (std.mem.eql(u8, slot.key, tb_types.chevron_key)) {
            self.paintThemePill(c, x, ty, w, h);
            if (hovered) dwp.paintHoverOverlay(c, x, ty, w, h);
            tb_paint.paintChevronDots(c, x, ty, w, h);
            if (use_press) cairo.cairo_restore(c);
            return;
        }
        tb_paint.paintStackSheets(c, x, ty, w, h, tb_paint.stackSheetsFor(nwin), ui);
        if (slot.win7 and slot.chosen_serial != 0) {
            // Open apps wear the glass face; unopened pins stay bare.
            tb_paint.paintWin7Face(c, x, ty, w, h, slot.any_activated, self.heatFor(idx));
        }
        if (hovered) {
            if (slot.chosen_serial != 0) {
                tb_paint.paintHotTrack(c, x, ty, w, h, self.pointerXOr(x + w * 0.5), self.heatFor(idx));
            } else if (slot.win7) {
                dwp.paintHoverOverlay(c, x, ty, w, h);
            } else if (!slot.is_pinned) {
                cairo_helpers.roundedRect(c, x, ty, h, h, widget_pill.cornerRadius(h, h));
                widget_pill.setFillForState(c, true, false);
                cairo.cairo_fill(c);
            }
        }
        var drew = false;
        const ic = self.icons[idx];
        if (ic.pixels.len > 0 and ic.w > 0 and ic.h > 0) {
            paintCenteredIcon(c, ic, x, ty, icon);
            drew = true;
        }
        const title = if (idx < self.slot_labels.len and self.slot_labels[idx].len > 0) self.slot_labels[idx] else self.titleForSerial(slot.chosen_serial);
        if (self.eff_show_labels and title.len > 0) {
            self.paintSlotLabel(c, title, x, ty, icon, ui);
            drew = true;
        }
        if (slot.win7) tb_paint.paintWindowBadge(c, x, ty, w, ui, nwin);
        if (!drew) {
            cairo_helpers.roundedRect(c, x, ty, w, h, 12.0);
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.06);
            cairo.cairo_fill(c);
        }
        if (use_press) cairo.cairo_restore(c);
        if (!slot.win7 and slot.chosen_serial != 0) {
            tb_paint.paintRunDot(c, x + w * 0.5, tb_paint.runDotY(ty + icon, icon + 2.0 * y), slot.any_activated);
        }
    }

    fn paintThemePill(self: *Taskbar, c: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
        const cfg = &self.app.loaded.cfg;
        const mc = chrome.of(cfg);
        dwp.paintPill(c, x, y, w, h, .{
            .r = mc.dock_fill.r * 0.6 + mc.accent.r * 0.15,
            .g = mc.dock_fill.g * 0.6 + mc.accent.g * 0.15,
            .b = mc.dock_fill.b * 0.6 + mc.accent.b * 0.15,
        }, pillAlpha(cfg), true);
    }

    fn paintSlotLabel(self: *Taskbar, c: *cairo.cairo_t, title: []const u8, x: f64, ty: f64, icon: f64, ui: f64) void {
        _ = self;
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, tb_slots.labelFontPx(ui));
        var tbuf: [512]u8 = undefined;
        const n = @min(title.len, tbuf.len - 1);
        @memcpy(tbuf[0..n], title[0..n]);
        tbuf[n] = 0;
        var te: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
        cairo.cairo_text_extents(c, @ptrCast(&tbuf), &te);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.92);
        cairo.cairo_move_to(c, x + icon + 6.0 * ui - te.x_bearing, ty + (icon - te.height) / 2.0 - te.y_bearing);
        cairo.cairo_show_text(c, @ptrCast(&tbuf));
    }

    fn heatFor(self: *Taskbar, idx: usize) tb_paint.Heat {
        if (idx < self.glow.len and self.glow[idx].ok) {
            return .{ .r = self.glow[idx].r, .g = self.glow[idx].g, .b = self.glow[idx].b };
        }
        return .{};
    }

    fn pointerXOr(self: *Taskbar, fallback: f64) f64 {
        const seat = self.app.bound.seat_obj orelse return fallback;
        return seat.pointer_x;
    }

    fn pointerYOr(self: *Taskbar, fallback: f64) f64 {
        const seat = self.app.bound.seat_obj orelse return fallback;
        return seat.pointer_y;
    }

    /// Which of the media pill's own zones a press landed in, or -1. Pointer
    /// in surface coordinates, slot box in the same logical units the paint
    /// uses (dock parity).
    fn mediaZone(self: *Taskbar, b: *Bar, idx: usize) i32 {
        if (!self.media_init) return -1;
        if (idx >= b.xs.len or idx >= b.ws.len) return -1;
        if (b.ws[idx] <= 1.0) return -1;
        const icon = self.iconPx(@floatFromInt(@max(1, self.barHeight())));
        return media_paint.hitZone(self.pointerXOr(b.xs[idx] + b.ws[idx] * 0.5) - b.xs[idx], b.ws[idx], icon);
    }

    fn paintWidgetFace(self: *Taskbar, c: *cairo.cairo_t, slot: *const tb_types.PaintSlot, kind: dw.Kind, x: f64, y: f64, w: f64, h: f64, icon_px: f64, hovered: bool, pressed: bool) void {
        const cfg = &self.app.loaded.cfg;
        switch (kind) {
            // The faces below own their pill and their content. Their painters
            // take `(hovered, pressed)` and paint no hover feedback of their
            // own, so the shared accent wash goes on after the face — the same
            // order the dock's strip paints every widget slot in.
            .clock => {
                clock_paint.paintClockSlot(c, cfg, slot.key, x, y, w, icon_px, icon_px, false, false);
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
            },
            .weather => {
                weather_paint.paintWeatherSlot(c, cfg, slot.key, x, y, w, icon_px, icon_px, false, false);
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
            },
            .media => {
                // The full dock media pill: artwork disc, title/artist run,
                // transport row and progress border. `compact_media` drops
                // the text row; the pill itself stays. This replaces the
                // generic painter, so no hover wash — the pill's own button
                // ring is the feedback (same as the dock).
                if (self.media_init) {
                    const ptr_x = self.pointerXOr(x + w * 0.5);
                    const ptr_y = self.pointerYOr(y + h * 0.5);
                    const btn = if (hovered) media_paint.hitZone(ptr_x - x, w, icon_px) else -1;
                    const now_ns: i64 = @intCast(anim_mod.monotonicNs());
                    const res = media_paint.paint(
                        c,
                        .{ .x = x, .y = y, .slot_w = w, .slot_h = h, .icon_px = icon_px },
                        .{
                            .snap = self.media.snap,
                            .art = .{ .pixels = self.media_art_pixels, .w = self.media_art_w, .h = self.media_art_h },
                            .measured = self.media_measured,
                            .hover_btn = btn,
                            .pointer_x = if (hovered) ptr_x - x else -1.0,
                            .pointer_y = if (hovered) ptr_y - y else -1.0,
                            .show_text = !cfg.taskbar.compact_media and dw.settingBool(cfg, slot.key, "show_text", true),
                            .title_scale = media_paint.titleScaleLimit(cfg, slot.key),
                            .now_sec = @as(f64, @floatFromInt(now_ns)) / 1e9,
                            .now_ns = now_ns,
                        },
                        &self.media_pos,
                    );
                    self.media_wants_marquee = res.wants_marquee;
                    self.media_progress_tick = res.progress_tick;
                } else {
                    widget_pill.paintPill(c, x, y, w, icon_px);
                    if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
                    drawLucide(c, "album", x + w * 0.5, y + icon_px * 0.5, icon_px * 0.5);
                }
            },
            .workspaces => {
                _ = ws_paint.paintWorkspacesSlot(self.app.gpa, c, cfg, slot.key, x, y, w, icon_px, icon_px, self.ws_entries, false, false, ws_paint.Icons{ .ctx = self, .get = wsIconSurf }, &self.ws_anim, nowMs()) catch {};
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
            },
            .control_center => {
                const rt = cc_slot.Runtime{};
                const ccfg = cc_slot.loadCfg(cfg, slot.key);
                var buf: [4]cc_slot.Glyph = undefined;
                const list = cc_slot.glyphs(ccfg, rt, &buf);
                const mc = chrome.of(cfg);
                cc_slot.paintSlot(c, x, y, w, icon_px, icon_px, list, .{ .r = mc.dock_fill.r, .g = mc.dock_fill.g, .b = mc.dock_fill.b }, pillAlpha(cfg));
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
            },
            .pear_center => {
                // Same pill, same live sources, pear's own runtime — the
                // pill is fed `self.pear_rt` (refreshed by the 2 s poll)
                // and gets the shared accent wash on hover.
                const pcfg = pear_slot.loadCfg(cfg, slot.key);
                var buf: [4]pear_slot.Glyph = undefined;
                const list = pear_slot.glyphs(pcfg, self.pear_rt, &buf);
                const mc = chrome.of(cfg);
                pear_slot.paintSlot(c, x, y, w, icon_px, icon_px, list, .{ .r = mc.dock_fill.r, .g = mc.dock_fill.g, .b = mc.dock_fill.b }, pillAlpha(cfg));
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
            },
            .battery => {
                // The pill fill ignores hover/press: fed `false, false` and
                // given the shared wash afterwards, so its hover reads like
                // every other widget slot's (dock parity).
                battery_paint.paintBatterySlot(c, cfg, slot.key, x, y, w, icon_px, icon_px, false, false);
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
            },
            .bluetooth => {
                // Live state: the poll fills bt_snap/bt_devs each tick; the
                // face must paint those, not an empty default snapshot. Its
                // built-in white wash is skipped (false, false) in favour of
                // the shared accent wash — the same trade the dock's strip
                // makes for the same widget.
                bt_paint.paintBluetoothSlot(c, cfg, slot.key, x, y, w, icon_px, icon_px, &self.bt_snap, self.bt_devs, false, false);
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
            },
            .vpn => {
                widget_pill.paintPill(c, x, y, w, icon_px);
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
                drawLucide(c, "vpn_key", x + w * 0.5, y + icon_px * 0.5, icon_px * 0.5);
            },
            .clipstack => {
                // Same feel as the VPN slot: frosted pill + Lucide glyph.
                // Click launches the picker overlay (toggle via its lock).
                widget_pill.paintPill(c, x, y, w, icon_px);
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
                drawLucide(c, "content_paste", x + w * 0.5, y + icon_px * 0.5, icon_px * 0.5);
            },
            .layout => {
                // The painter's inline ring is disabled (false, false): the
                // shared accent wash is the hover, like every widget slot.
                layout_paint.paintLayoutSlot(c, cfg, slot.key, x, y, w, icon_px, icon_px, false, false);
                if (hovered) dwp.paintHoverOverlay(c, x, y, w, icon_px);
            },
            .world_clock => {
                // The face owns its pill and content (pager dots, the 5 s
                // slide); hover — and the popup-open state — get the shared
                // accent wash on top, like every other widget slot.
                if (self.wc_init)
                    wc_face.paint(c, &self.wc, x, y, w, h, icon_px, hovered, epochMs(), chrome.of(cfg));
                if (hovered or self.wc_open) dwp.paintHoverOverlay(c, x, y, w, icon_px);
            },
            else => {
                var d = dwp.Draw{ .kind = kind, .hover = hovered, .press = pressed, .pill = dw.ownsPill(kind) };
                const cands = dwp.iconCandidates(kind);
                d.lucide = if (cands.len > 0) cands[0] else "circle";
                dwp.paintSlot(c, x, y, w, h, icon_px, d);
            },
        }
    }

    fn paintRunPills(self: *Taskbar, cr: *cairo.cairo_t, b: *Bar, y: f64, h: f64) void {
        if (self.runs.len == 0) return;
        const cfg = &self.app.loaded.cfg;
        const mc = chrome.of(cfg);
        for (self.runs) |r| {
            if (r.start + r.len > b.xs.len) continue;
            const x0 = b.xs[r.start];
            const x1 = b.xs[r.start + r.len - 1] + b.ws[r.start + r.len - 1];
            dwp.paintPill(cr, x0, y, x1 - x0, h, .{ .r = mc.dock_fill.r * 0.6 + mc.accent.r * 0.15, .g = mc.dock_fill.g * 0.6 + mc.accent.g * 0.15, .b = mc.dock_fill.b * 0.6 + mc.accent.b * 0.15 }, pillAlpha(cfg), true);
        }
    }

    /// The slot-pill fill alpha: the `slot_pill_opacity` setting straight
    /// (0 = fully transparent, 100 = fully opaque), through the shared
    /// helper the dock uses. A stray halving here is what kept the run
    /// pills, the theme pill and the control-center slot from ever reaching
    /// opaque at 100%.
    fn pillAlpha(cfg: *const config.ShellConfig) f64 {
        return widget_pill.settingAlpha(cfg.taskbar.slot_pill_opacity);
    }

    /// Output scale changed: logical geometry is untouched, but every bar's
    /// buffer must be re-allocated at the new device size. `ctx` is the
    /// owning Taskbar; each bar's surface listener points here.
    fn onScale(ctx: *anyopaque, scale: i32) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        _ = scale; // already stored on each surface by the listener
        for (self.bars.items) |*b| {
            if (b.w <= 0 or b.h <= 0) continue;
            if (!b.shm.ensure(self.app.bound.shm, "taskbar", b.w * b.surface.scale, b.h * b.surface.scale)) continue;
        }
        self.repaint();
    }

    fn repaint(self: *Taskbar) void {
        const t0 = nowMs();
        const cfg = &self.app.loaded.cfg;
        // The layout slot asks the compositor which layout is running, which
        // is an IPC round trip; `setContext` is what lets
        // `layout_paint.current()` reach it, and the one-second answer it
        // caches keeps the round trip off the paint path. Idempotent, and
        // free when no layout slot is in the strip.
        layout_paint.setContext(self.app.gpa, self.app.io);
        // Shared pill globals: clock/weather/etc. paint through
        // `widget_pill.paintPill`, which reads these — without this every
        // shared pill paints the Style default of solid white.
        {
            const mc = chrome.of(cfg);
            const alpha = pillAlpha(cfg);
            widget_pill.style.pill_r = mc.dock_fill.r * 0.6 + mc.accent.r * 0.15;
            widget_pill.style.pill_g = mc.dock_fill.g * 0.6 + mc.accent.g * 0.15;
            widget_pill.style.pill_b = mc.dock_fill.b * 0.6 + mc.accent.b * 0.15;
            widget_pill.style.opacity_scale = alpha;
            widget_pill.style.hover_accent_r = mc.accent.r;
            widget_pill.style.hover_accent_g = mc.accent.g;
            widget_pill.style.hover_accent_b = mc.accent.b;
        }
        if (!cfg.taskbar.enabled) {
            if (!self.warned_disabled) {
                self.warned_disabled = true;
                logz.err("repaint: suspended — [taskbar] enabled=false (not painting)", .{});
            }
            self.media_wants_marquee = false;
            self.media_progress_tick = false;
            return;
        }
        const ui = self.uiScale();
        const box_h: f64 = @floatFromInt(@max(1, self.barHeight()));
        const icon = self.iconPx(box_h);
        const hidden = cfg.taskbar.auto_hide and !self.reveal;
        if (hidden and !self.warned_hidden) {
            self.warned_hidden = true;
            logz.log("repaint: hidden by auto_hide (reveal on pointer enter)", .{});
        }
        // The media pill re-arms these from scratch on every frame; a strip
        // with no media slot (or a bar that skipped painting) must not keep
        // the frame chain alive off a stale value.
        self.media_wants_marquee = false;
        self.media_progress_tick = false;
        for (self.bars.items, 0..) |*b, bi| {
            if (b.w <= 0 or b.h <= 0) {
                logz.err("repaint: bar {d} has no size ({d}x{d}), skipping", .{ bi, b.w, b.h });
                continue;
            }
            // Double-buffered: never paint into memory the compositor still
            // holds (that tore). A starved frame drops; the next event
            // repaints instead of painting under the screen.
            const buf = b.shm.acquire() orelse continue;
            const cr = buf.cr orelse continue;
            cairo.cairo_save(cr);
            cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
            cairo.cairo_paint(cr);
            cairo.cairo_restore(cr);
            // Scale the frame to the output's device pixels. Every paint site
            // below keeps drawing in logical coordinates (b.w/b.h); cairo
            // rasterises at the buffer's native resolution so 2x HiDPI is
            // crisp instead of the compositor up-scaling a 1x buffer.
            cairo.cairo_identity_matrix(cr);
            const tsc: f64 = @floatFromInt(b.surface.scale);
            cairo.cairo_scale(cr, tsc, tsc);
            cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
            if (!hidden) {
                self.paintBackground(cr, b.w, b.h);
                const y = (box_h - icon) * 0.5;
                self.paintRunPills(cr, b, y, icon);
                for (self.sections.all, 0..) |*s, i| {
                    if (i >= b.xs.len) break;
                    self.slotDraw(cr, s, i, b.xs[i], y, b.ws[i], icon, icon, ui);
                }
                // Pin-drag ghost at the pointer (`cachedFloatingPinLookup`):
                // the pin's own icon in a lifted outline, plus its run dot.
                if (self.drag_dragging and self.drag_key_norm.len > 0) {
                    const seat = self.app.bound.seat_obj;
                    if (seat) |sq| {
                        const fx = @max(4.0, @min(b.w - icon - 4.0, sq.pointer_x - icon * 0.5));
                        const fy = y - 4.0;
                        cairo_helpers.roundedRect(cr, fx - 2.0, fy - 2.0, icon + 4.0, icon + 4.0, 14.0);
                        cairo.cairo_set_source_rgba(cr, 1.00, 1.00, 1.00, 0.12);
                        cairo.cairo_fill_preserve(cr);
                        cairo.cairo_set_source_rgba(cr, 0.55, 0.80, 1.00, 0.65);
                        cairo.cairo_set_line_width(cr, 1.0);
                        cairo.cairo_stroke(cr);
                        for (self.sections.all, 0..) |*s, si| {
                            if (s.kind != .app or !s.is_pinned) continue;
                            if (!std.mem.eql(u8, s.key, self.drag_key_norm)) continue;
                            if (si < self.icons.len) paintCenteredIcon(cr, self.icons[si], fx, fy, icon);
                            break;
                        }
                        if (self.windowsForApp(self.drag_key_norm) > 0) {
                            tb_paint.paintRunDot(cr, fx + icon * 0.5, fy + icon + 3.0, self.activeForApp(self.drag_key_norm));
                        }
                    }
                }
            }
            b.surface.attach(buf.wlBuffer(), 0, 0);
            b.surface.setBufferScale(b.surface.scale);
            b.surface.damage(0, 0, b.w, b.h);
            buf.markBusy();
            b.surface.commit();
        }
        _ = self.app.conn.flush();
        const dt = nowMs() -| t0;
        if (dt > self.draw_max_ms) {
            self.draw_max_ms = dt;
            if (dt > 25) logz.log("perf: slow repaint {d}ms", .{dt});
        }
        if (self.boot_t0 != 0 and !self.first_frame_logged and self.bars.items.len > 0) {
            self.first_frame_logged = true;
            logz.log("startup: first_frame paint={d}ms t=+{d}ms", .{ dt, nowMs() -| self.boot_t0 });
        }
        if (self.animated()) self.requestFrame();
    }

    /// Startup banner: everything that decides blank-vs-painted in one
    /// place, on both the log and stderr (manual runs show it live).
    fn banner(self: *Taskbar) void {
        const cfg = &self.app.loaded.cfg;
        var icons_hit: usize = 0;
        var icons_miss: usize = 0;
        for (self.sections.all, 0..) |*s, i| {
            if (s.kind != .app and s.kind != .tray) continue;
            if (i < self.icons.len and self.icons[i].pixels.len > 0) {
                icons_hit += 1;
            } else {
                icons_miss += 1;
            }
        }
        logz.log("banner: enabled={d} auto_hide={d} top={d} h={d} iconsz={d} scale={d} outputs={d} bars={d} slots={d} icons={d}/{d} shm={s}", .{
            @as(u8, @intFromBool(cfg.taskbar.enabled)),
            @as(u8, @intFromBool(cfg.taskbar.auto_hide)),
            @as(u8, @intFromBool(cfg.taskbar.position_top)),
            cfg.taskbar.height,
            cfg.taskbar.icon_size,
            @as(i32, @intFromFloat(@round(cfg.taskbar.scale * 100.0))),
            self.app.bound.outputs.items.len,
            self.bars.items.len,
            self.sections.all.len,
            icons_hit,
            icons_hit + icons_miss,
            if (self.app.bound.shm != null) "yes" else "NO",
        });
        std.debug.print("horizon-taskbar: enabled={} bars={} slots={} icons={}/{} shm={s}\n", .{
            cfg.taskbar.enabled,
            self.bars.items.len,
            self.sections.all.len,
            icons_hit,
            icons_hit + icons_miss,
            if (self.app.bound.shm != null) "yes" else "NO",
        });
        if (!cfg.taskbar.enabled) {
            std.debug.print("horizon-taskbar: [taskbar] enabled=false — nothing will paint (toggle it in Settings > Taskbar)\n", .{});
        }
        if (self.app.bound.shm == null) {
            std.debug.print("horizon-taskbar: no wl_shm from the compositor — buffers cannot be allocated\n", .{});
        }
        for (self.bars.items, 0..) |*b, i| {
            logz.log("banner: bar {d} {d}x{d} buf={s}", .{ i, b.w, b.h, if (b.shm.ready()) "yes" else "NO" });
        }
    }

    fn onReload(ctx: *anyopaque) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        // The launcher's own Reload-shell and Toggle-theme buttons promise to
        // stay up across the reload they ask for; every other popup is stale
        // the moment the config changes under it.
        const keep = self.reload_keep_popup;
        self.reload_keep_popup = false;
        self.hover = -1;
        self.pressed = -1;
        if (keep and self.popup_init and self.popup.kind == .launcher) {
            self.launcher.setColors(chrome.of(&self.app.loaded.cfg));
            self.launcher.setNight(self.app.loaded.cfg.night_light.enabled);
        } else {
            self.closePopup();
        }
        self.thumbsDismiss();
        self.tooltipHide();
        self.spotClose();
        // Keep the drawer model in step with the config it reads; an open
        // one was just closed, so the next open is enough. The rail is
        // list-only, so the mode only reaches the reference panel.
        if (self.launcher.style == .classic) {
            self.launcher.setListMode(self.app.loaded.cfg.appearance.launchpad_view_mode == 1);
        }
        self.launcher.setNight(self.app.loaded.cfg.night_light.enabled);
        // The world-clock list lives in `<leaf>/world_clock.json`, inside the
        // settings dir this reload was triggered by, so a save from
        // Settings > Time must land in the bar's widget too. `reload` keeps
        // the session's *own* save (a popup switch, back through the same
        // watcher) a no-op, so an open card is only re-presented when the list
        // really moved.
        if (self.wc_init and self.wc.reload()) {
            if (self.wc_open) {
                if (self.bars.items.len > 0) self.wcRelayout(&self.bars.items[0]);
                self.wcRefresh();
            }
        }
        self.rebuild();
        self.repaint();
    }

    // -- pointer ------------------------------------------------------

    fn barAt(self: *Taskbar, surf: ?*wl.wl_surface) ?*Bar {
        const s = surf orelse return null;
        for (self.bars.items) |*b| {
            if (b.surface.wl_surface == s) return b;
        }
        return null;
    }

    fn slotAt(self: *Taskbar, b: *Bar, px: f64, py: f64) ?usize {
        _ = py;
        for (self.sections.all, 0..) |_, i| {
            if (i >= b.xs.len) break;
            if (px >= b.xs[i] and px < b.xs[i] + b.ws[i]) return i;
        }
        return null;
    }

    fn onEnter(ctx: *anyopaque, _: f64, _: f64) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        // Hover previews survive bar<->popup transitions; landing anywhere
        // else (any other surface this client owns) closes them
        // (`taskbar_pointer_enter`).
        if (!self.thumbs_open or self.thumbs.wl_surface == null) return;
        const seat = self.app.bound.seat_obj orelse return;
        const focus = seat.focus_surface orelse return;
        for (self.bars.items) |*b| {
            if (b.surface.wl_surface) |bs| {
                if (bs == focus) return;
            }
        }
        if (self.onThumbsSurface()) return;
        self.thumbsDismiss();
        self.repaint();
    }

    fn onLeave(ctx: *anyopaque) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        self.hover = -1;
        self.syncWcHover();
        self.pressed = -1;
        self.drag_candidate = false;
        if (!self.drag_dragging) self.tooltipHide();
        self.repaint();
    }

    fn onMotion(ctx: *anyopaque, _: f64, _: f64) void {
        const t0 = nowMs();
        defer {
            const dt = nowMs() -| t0;
            const self_: *Taskbar = @ptrCast(@alignCast(ctx));
            if (dt > self_.motion_max_ms) {
                self_.motion_max_ms = dt;
                if (dt > 25) logz.log("perf: slow motion {d}ms", .{dt});
            }
        }
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        const seat = self.app.bound.seat_obj orelse return;
        // Pear surface first, then the control-center surface (own
        // surfaces, own gestures).
        if (self.pear_init and self.pear.open and self.onPearSurface()) {
            if (self.pearDragging()) {
                if (self.pear.dragTo(seat.pointer_x)) |a| {
                    self.drag_motion_paint_off = !self.dragFrameDue(nowMs());
                    self.runPearAction(a);
                    self.drag_motion_paint_off = false;
                }
                return;
            }
            if (self.pear.motion(seat.pointer_x, seat.pointer_y)) self.pearRefresh();
            return;
        }
        if (self.onCcSurface()) {
            if (self.ccDragging()) {
                if (self.cc.dragTo(seat.pointer_x)) |a| {
                    self.drag_motion_paint_off = !self.dragFrameDue(nowMs());
                    self.runCcAction(a);
                    self.drag_motion_paint_off = false;
                }
                return;
            }
            if (self.cc.motion(seat.pointer_x, seat.pointer_y)) self.ccRefresh();
            return;
        }
        // World clock popup: its own surface, hover only.
        if (self.wc_open and self.onWcSurface()) {
            const out = self.wcMotion(seat.pointer_x, seat.pointer_y);
            if (out.repaint) self.wcRefresh();
            return;
        }
        // Popup surface motion first.
        if (self.popup_init and self.popup.kind != .none) {
            if (self.onPopupSurface()) {
                self.popupMotion();
                return;
            }
        }
        if (self.thumbs_open and self.onThumbsSurface()) {
            self.thumbsMotion();
            return;
        }
        if (self.spot_open and self.onSpotSurface()) {
            const row = self.spotRowAt(seat.pointer_y);
            if (row != self.spot_sel) {
                self.spot_sel = row;
                self.paintSpot();
                _ = self.app.conn.flush();
            }
            return;
        }
        const bar = self.barAt(seat.focus_surface) orelse return;
        if (!self.reveal) self.setReveal(true);
        const hov: i32 = if (self.slotAt(bar, seat.pointer_x, seat.pointer_y)) |i| @intCast(i) else -1;
        if (hov != self.hover) {
            self.hover = hov;
            self.syncWcHover();
            self.tooltipHide();
            self.tooltip_start_ms = nowMs();
            self.tooltip_slot = hov;
            if (!self.drag_dragging) self.hoverGroupChanged();
            self.repaint();
        } else if (self.drag_dragging) {
            self.dragMotion();
        } else if (self.popup_init and self.popup.kind != .none) {
            self.popupMotion();
        } else if (hov >= 0 and @as(usize, @intCast(hov)) < self.sections.all.len and
            self.sections.all[@intCast(hov)].kind == .app and
            self.sections.all[@intCast(hov)].chosen_serial != 0)
        {
            // Color hot-track tracking: the same running button, pointer
            // moved. Repaint coalesced to the next frame instead of a full
            // draw per motion event, so the glow follows at display rate
            // (taskbar.cpp:3418). Without this the glow stayed pinned to
            // wherever the pointer entered the button.
            if (self.frame_pending) {
                self.hot_follow_dirty = true;
            } else {
                self.repaint();
                self.requestFrame();
            }
        }
        if (!self.drag_dragging) self.hoverTick();
    }

    fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        const seat = self.app.bound.seat_obj orelse return;
        const down = state == 1;
        if (self.pear_init and self.pear.open and self.onPearSurface()) {
            if (down) {
                self.pearClick();
            } else {
                self.releasePear();
            }
            return;
        }
        if (!down and self.pearDragging()) {
            self.releasePear();
            return;
        }
        if (self.onCcSurface()) {
            if (down) {
                self.ccClick();
            } else {
                self.releaseCc();
            }
            return;
        }
        if (!down and self.ccDragging()) {
            self.releaseCc();
            return;
        }
        // World clock: its own popup surface, then a slider drag that ends
        // anywhere.
        if (!down and self.wc_init and self.wc.p.dragging_slider) {
            _ = wc_panel.release(&self.wc);
            return;
        }
        if (self.wc_open and self.onWcSurface()) {
            if (down) {
                self.applyWcOutcome(self.wcPress(seat.pointer_x, seat.pointer_y));
            } else {
                self.applyWcOutcome(wc_panel.release(&self.wc));
            }
            return;
        }
        if (!down and self.mixerRelease()) {
            self.repaint();
            return;
        }
        if (self.popup_init and self.popup.kind != .none and self.onPopupSurface()) {
            if (down) {
                self.popupPress(button);
            } else {
                self.popupRelease(button);
            }
            return;
        }
        if (self.thumbs_open and self.onThumbsSurface()) {
            if (!down) self.thumbsClick(button);
            return;
        }
        if (self.spot_open and self.onSpotSurface()) {
            if (!down and button == 272) {
                const row = self.spotRowAt(seat.pointer_y);
                if (row >= 0) {
                    self.runSpotHit(@intCast(row));
                    return;
                }
                self.spotClose();
                self.repaint();
            }
            return;
        }
        const bar = self.barAt(seat.focus_surface) orelse {
            if (!down) {
                self.closePopup();
                self.thumbsDismiss();
                self.spotClose();
                self.closeWorldClock();
            }
            return;
        };
        const idx: i32 = if (self.slotAt(bar, seat.pointer_x, seat.pointer_y)) |i| @intCast(i) else -1;
        if (button == 272) {
            if (down) {
                self.pressed = idx;
                self.press_consumed = false;
                // A left press on the bar dismisses any open popup
                // (`taskbar_popup_close` on left press). Pressing the slot
                // that owns it consumes the click, so the release cannot
                // reopen what the press just closed.
                const own = idx >= 0 and @as(i32, @intCast(idx)) == self.open_origin;
                if ((self.popup_init and self.popup.kind != .none) or
                    (self.cc_init and self.cc.open) or
                    (self.pear_init and self.pear.open) or self.spot_open or self.wc_open)
                {
                    self.closePopup();
                    self.closeCc();
                    self.closePear();
                    self.spotClose();
                    self.closeWorldClock();
                    if (own) self.press_consumed = true;
                }
                if (idx >= 0 and !self.press_consumed) self.pressBegin(bar, @intCast(idx));
                self.repaint();
            } else {
                const was = self.pressed;
                const consumed = self.press_consumed;
                self.pressed = -1;
                self.press_consumed = false;
                if (self.drag_dragging or self.drag_candidate) {
                    self.dragRelease(true, consumed);
                } else if (was >= 0 and was == idx) {
                    if (!consumed) self.clickSlot(bar, @intCast(was));
                } else if (idx < 0) {
                    self.closePopup();
                    self.thumbsDismiss();
                    self.closeCc();
                    self.closePear();
                    self.spotClose();
                    self.closeWorldClock();
                }
                self.repaint();
            }
        } else if ((button == 273 or button == 274 or button == 275) and down) {
            // Right / middle / side press opens the slot's context menu —
            // the C++ owner treats 0x111..0x113 alike (`right`). The
            // workspaces widget keeps its other C++ affordance: a middle
            // press opens the overview.
            if (idx >= 0 and button == 274 and @as(usize, @intCast(idx)) < self.sections.all.len and
                self.sections.all[@intCast(idx)].kind == .workspaces)
            {
                self.requestOverviewToggle();
            } else if (idx >= 0) self.openMenuFor(bar, @intCast(idx));
        }
    }

    /// Press policy for app buttons (`taskbar_button_press` App arms): the
    /// chevron opens the hidden-window list, a grouped button opens its
    /// window previews — pressing the same button again just closes them —
    /// and pinned buttons arm the pin drag. Returns true when the press
    /// already did the button's job and the release must not click.
    fn appPressPolicy(self: *Taskbar, b: *Bar, idx: usize) bool {
        const s = &self.sections.all[idx];
        // A left press on the bar closes any open popup; remember whether it
        // was this button's own popup, which makes the press a toggle-close.
        const same_popup = self.thumbs_open and std.mem.eql(u8, self.thumbs_group, s.key);
        if (self.thumbs_open) self.thumbsDismiss();
        if (std.mem.eql(u8, s.key, tb_types.chevron_key)) {
            if (same_popup) return true;
            const cx = self.slotCentreX(b, idx) orelse return false;
            self.openChevronOverflow(cx);
            return true;
        }
        if (self.windowsForApp(s.key) > 1) {
            if (!same_popup) {
                const cx = self.slotCentreX(b, idx) orelse return false;
                self.open_origin = @intCast(idx);
                self.openThumbs(s.key, s.icon_id, cx);
            }
            return true;
        }
        return false;
    }

    fn pressBegin(self: *Taskbar, b: *Bar, idx: usize) void {
        const s = &self.sections.all[idx];
        if (s.kind == .app and self.appPressPolicy(b, idx)) {
            self.press_consumed = true;
            // Grouped pinned buttons stay draggable; crossing the threshold
            // dismisses the previews the press just opened.
            if (!s.is_pinned) return;
        }
        if (s.kind == .app and s.is_pinned) {
            // Arm a pin-drag candidate (threshold promotes it in motion).
            self.drag_candidate = true;
            self.drag_dragging = false;
            self.drag_insert = -1;
            const seat = self.app.bound.seat_obj orelse return;
            self.drag_start_x = seat.pointer_x;
            self.drag_start_y = seat.pointer_y;
            const gpa = self.app.gpa;
            if (self.drag_key_norm.len > 0) gpa.free(self.drag_key_norm);
            if (self.drag_key_raw.len > 0) gpa.free(self.drag_key_raw);
            self.drag_key_norm = gpa.dupe(u8, s.key) catch &.{};
            self.drag_key_raw = gpa.dupe(u8, s.icon_id) catch &.{};
            // Snapshot pinned geometry from this bar's hits.
            self.freeDragRects();
            var rects: std.ArrayList(tb_pin_drag.Drag.Rect) = .empty;
            errdefer rects.deinit(gpa);
            for (self.sections.all, 0..) |*h, i| {
                if (h.kind != .app or !h.is_pinned) continue;
                if (i >= b.xs.len) break;
                rects.append(gpa, .{ .x = b.xs[i], .w = b.ws[i] }) catch break;
            }
            self.drag_rects = rects.toOwnedSlice(gpa) catch &.{};
        }
    }

    fn freeDragRects(self: *Taskbar) void {
        if (self.drag_rects.len > 0) self.app.gpa.free(self.drag_rects);
        self.drag_rects = &.{};
    }

    fn freeDragOrder(self: *Taskbar) void {
        const gpa = self.app.gpa;
        for (self.drag_snapshot) |s| gpa.free(s);
        if (self.drag_snapshot.len > 0) gpa.free(self.drag_snapshot);
        for (self.drag_order) |s| gpa.free(s);
        if (self.drag_order.len > 0) gpa.free(self.drag_order);
        self.drag_snapshot = &.{};
        self.drag_order = &.{};
    }

    fn dragMotion(self: *Taskbar) void {
        if (!self.drag_candidate and !self.drag_dragging) return;
        const seat = self.app.bound.seat_obj orelse return;
        const gpa = self.app.gpa;
        if (self.drag_candidate and !self.drag_dragging) {
            if (!tb_pin_drag.pastThreshold(self.drag_start_x, self.drag_start_y, seat.pointer_x, seat.pointer_y)) return;
            self.drag_dragging = true;
            self.thumbsDismiss();
            // Snapshot settings pins (owned).
            const cfg = &self.app.loaded.cfg;
            var snap: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (snap.items) |s| gpa.free(s);
                snap.deinit(gpa);
            }
            for (cfg.taskbar.pinned_apps) |p| snap.append(gpa, gpa.dupe(u8, p) catch continue) catch break;
            self.freeDragOrder();
            self.drag_snapshot = snap.toOwnedSlice(gpa) catch &.{};
            logz.log("pin-drag: start key='{s}'", .{self.drag_key_norm});
        }
        if (!self.drag_dragging or self.drag_key_norm.len == 0) return;
        // Live rects minus the dragged pin.
        var rects: std.ArrayList(tb_pin_drag.Drag.Rect) = .empty;
        defer rects.deinit(gpa);
        for (self.drag_rects) |r| rects.append(gpa, r) catch break;
        // Remove the dragged pin's own rect (match by order is unreliable;
        // use count: reduced = total pinned - 1).
        if (rects.items.len > 0) {
            // Find dragged index in snapshot order among pinned slots.
            var pin_idx: usize = 0;
            var found = false;
            for (self.sections.all, 0..) |*s, i| {
                if (s.kind != .app or !s.is_pinned) continue;
                if (std.mem.eql(u8, s.key, self.drag_key_norm)) {
                    pin_idx = i;
                    found = true;
                    break;
                }
            }
            if (found) {
                // Map strip index → rect index (pinned-only order).
                var ri: usize = 0;
                for (self.sections.all[0..pin_idx]) |*s| {
                    if (s.kind == .app and s.is_pinned) ri += 1;
                }
                if (ri < rects.items.len) _ = rects.orderedRemove(ri);
            }
        }
        const bar = self.barAt(seat.focus_surface) orelse &self.bars.items[0];
        _ = bar;
        const first = if (rects.items.len > 0) rects.items[0].x else 0;
        const last_r = if (rects.items.len > 0) rects.items[rects.items.len - 1].x + rects.items[rects.items.len - 1].w else 0;
        const px = std.math.clamp(seat.pointer_x, first, last_r);
        const next = tb_pin_drag.motionInsert(rects.items, self.drag_insert, px);
        if (next != @as(usize, @intCast(@max(self.drag_insert, 0))) or self.drag_insert < 0) {
            self.drag_insert = @intCast(next);
            self.rebuildDragOrder();
        }
        self.repaint();
    }

    fn rebuildDragOrder(self: *Taskbar) void {
        const gpa = self.app.gpa;
        const snap: []const []const u8 = self.drag_snapshot;
        const order = tb_pinned.rebuildPaintOrder(gpa, snap, self.drag_key_norm, self.drag_insert) catch return;
        for (self.drag_order) |s| gpa.free(s);
        if (self.drag_order.len > 0) gpa.free(self.drag_order);
        self.drag_order = order orelse &.{};
    }

    fn dragRelease(self: *Taskbar, left: bool, consumed: bool) void {
        const outcome = tb_pin_drag.releaseOutcome(self.drag_dragging, self.drag_order.len > 0, left, self.drag_candidate, self.drag_key_norm);
        if (outcome) |o| {
            if (o.was_dragging and o.drag_dirty and self.drag_order.len > 0) {
                self.persistPins(self.drag_order);
            }
            // A candidate that ended without dragging is a click: focus a
            // matching window, or launch the pinned entry when none is up.
            // Presses that already opened previews act on those instead.
            if (o.was_click and !consumed and self.drag_key_norm.len > 0) {
                self.activateKey(self.drag_key_norm, self.drag_key_raw);
            }
        }
        self.freeDragOrder();
        self.freeDragRects();
        self.drag_candidate = false;
        self.drag_dragging = false;
        self.drag_insert = -1;
    }

    fn persistPins(self: *Taskbar, order: []const []const u8) void {
        const gpa = self.app.gpa;
        const settings = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch return;
        defer gpa.free(settings);
        const path = config.componentPath(gpa, settings, "taskbar") catch return;
        defer gpa.free(path);
        pin_store.save(gpa, self.app.io, path, order) catch |e| {
            logz.err("pin-drag: cannot write {s}: {s}", .{ path, @errorName(e) });
            return;
        };
        logz.log("pin-drag: saved {d} pins", .{order.len});
        if (!self.app.reload()) logz.log("pin-drag: reload deferred", .{});
        self.rebuild();
    }

    fn togglePin(self: *Taskbar, raw: []const u8) void {
        const gpa = self.app.gpa;
        const cfg = &self.app.loaded.cfg;
        const norm = paths.normalizeAppId(gpa, raw) catch return;
        defer gpa.free(norm);
        if (norm.len == 0 or std.mem.eql(u8, norm, "unknown")) return;
        var next: std.ArrayList([]const u8) = .empty;
        defer {
            for (next.items) |p| gpa.free(p);
            next.deinit(gpa);
        }
        var removed = false;
        for (cfg.taskbar.pinned_apps) |p| {
            const pn = paths.normalizeAppId(gpa, p) catch continue;
            defer gpa.free(pn);
            if (std.mem.eql(u8, pn, norm)) {
                removed = true;
                continue;
            }
            next.append(gpa, gpa.dupe(u8, p) catch continue) catch continue;
        }
        if (!removed) next.append(gpa, gpa.dupe(u8, norm) catch return) catch return;
        self.persistPins(next.items);
    }

    fn clickSlot(self: *Taskbar, b: *Bar, idx: usize) void {
        // Toggle: clicking the slot that opened the current popup dismisses.
        if (@as(i32, @intCast(idx)) == self.open_origin) {
            const any_open = (self.popup_init and self.popup.kind != .none) or self.thumbs_open or (self.cc_init and self.cc.open) or (self.pear_init and self.pear.open) or self.spot_open or self.wc_open;
            if (any_open) {
                self.closePopup();
                self.thumbsDismiss();
                self.closeCc();
                self.closePear();
                self.spotClose();
                self.closeWorldClock();
                self.repaint();
                return;
            }
        }
        self.open_origin = @intCast(idx);
        const s = &self.sections.all[idx];
        const cx: i32 = if (idx < b.xs.len) @intFromFloat(@round(b.xs[idx] + b.ws[idx] * 0.5)) else 0;
        switch (s.kind) {
            .app => {
                // Previews and the chevron list open at press; what reaches
                // the release is a plain activation (or nothing, for a
                // consumed press).
                self.activateSlot(s);
            },
            .tray => {
                if (self.tray_init) self.tray.activate(s.key, cx, @intCast(b.h));
            },
            .settings => self.activateSlot(s),
            .audio_center => self.activateSlot(s),
            .spotlight => {
                if (self.spot_open) {
                    self.spotClose();
                } else {
                    self.openSpotlight(cx);
                }
            },
            .app_menu => self.showLauncherList(idx),
            .app_drawer, .smenu => {
                // Grid or one-row-per-app list, from Appearance → Launchpad
                // view mode. The App menu keeps its own rail panel (see
                // `showLauncherList`).
                self.showLauncher(idx, .classic);
            },
            .clock => self.openCard(.calendar, cx),
            .weather => self.openCard(.weather, cx),
            .media => {
                // Presses on the pill's own transport row act in place;
                // anywhere else opens the media card (dock parity).
                const zone = self.mediaZone(b, idx);
                if (zone == 0) {
                    _ = self.media.act(.previous);
                    self.repaint();
                } else if (zone == 1) {
                    _ = self.media.act(.play_pause);
                    self.repaint();
                } else if (zone == 2) {
                    _ = self.media.act(.next);
                    self.repaint();
                } else {
                    self.showMediaPlayer(idx);
                }
            },
            .workspaces => self.focusWorkspace(b, idx, self.pointerXOr(@floatFromInt(cx))),
            .control_center => self.showControlCenter(idx),
            .pear_center => self.showPear(idx),
            .volume_mixer => self.showVolumeMixer(idx),
            .battery => {},
            .bluetooth => self.showBluetoothCard(idx, cx),
            .vpn => self.showVpn(idx),
            .clipstack => {
                // The bar's PATH does not carry the install dir: resolve the
                // picker next to /proc/self/exe like the other self-launches.
                if (!self.launchSibling("horizon-clipstack-pick")) {
                    logz.err("activate: horizon-clipstack-pick not found beside the taskbar binary", .{});
                }
            },
            .layout => self.openCard(.layout, cx),
            .world_clock => {
                if (self.wc_open) {
                    self.closeWorldClock();
                } else {
                    self.openWorldClock(b, idx);
                }
            },
            .overview => self.requestOverviewToggle(),
            .trash => self.openTrash(),
            else => {},
        }
    }

    // -- world clock popup --------------------------------------------------
    //
    // A taskbar-owned overlay surface, a sibling of the spotlight palette:
    // bottom|right anchored (top|right when the bar sits on top), a 360 px
    // card at the face scale, with a transparent 24 px margin that carries
    // its shadow. All of the logic lives in the session under
    // `widgets/world_clock/`; this section owns the surface and routes
    // pointer, key and scroll events into the panel.

    fn onWcSurface(self: *Taskbar) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const focus = seat.focus_surface orelse return false;
        if (self.wc_surface.wl_surface) |ws| return focus == ws;
        return false;
    }

    fn wcSlotHovered(self: *Taskbar) bool {
        if (self.hover < 0) return false;
        const idx: usize = @intCast(self.hover);
        if (idx >= self.sections.all.len) return false;
        return self.sections.all[idx].kind == .world_clock;
    }

    /// Pointer on the widget pauses the rotation and resets its accumulator;
    /// leaving resumes it from zero (spec: hover/scroll pause).
    fn syncWcHover(self: *Taskbar) void {
        if (!self.wc_init) return;
        const on = self.wcSlotHovered();
        if (on == self.wc.hover) return;
        self.wc.hover = on;
        self.wc.acc = 0;
    }

    fn wcUiScale(self: *Taskbar) f64 {
        const box_h: f64 = @floatFromInt(@max(1, self.barHeight()));
        return wc_face.scaleOf(self.iconPx(box_h));
    }

    /// Logical screen height of the bar's output, minus the spec's 120 px
    /// (their px, our natural px).
    fn wcMaxHeight(self: *Taskbar, bar: *const Bar) f64 {
        var h: i32 = 0;
        const oi: usize = @intCast(bar.output);
        if (oi < self.app.bound.outputs.items.len) {
            const o = self.app.bound.outputs.items[oi];
            h = if (o.have_logical and o.logical_h > 0) o.logical_h else @divTrunc(o.height, @max(1, o.scale));
        }
        if (h <= 0) h = 1440;
        return @as(f64, @floatFromInt(h)) - 120.0;
    }

    fn wcGeom(self: *Taskbar, bar: *const Bar) wc_panel.Geom {
        const us = self.wcUiScale();
        var g = wc_panel.compute(&self.wc, self.wcMaxHeight(bar) / us);
        // Never wider than the screen minus 32 px.
        g.w = @max(200.0, @min(g.w, @as(f64, @floatFromInt(bar.w)) / us - 32.0));
        return g;
    }

    fn wcRefresh(self: *Taskbar) void {
        if (!self.wc_open) return;
        const cr = self.wc_shm.cr orelse return;
        cairo.cairo_save(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        cairo.cairo_restore(cr);
        // Natural (card) coordinates: the card plus its shadow margin is
        // scaled by the face scale times the surface scale.
        cairo.cairo_identity_matrix(cr);
        const ssc: f64 = @floatFromInt(self.wc_surface.scale);
        const sc = ssc * self.wcUiScale();
        cairo.cairo_scale(cr, sc, sc);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        // Same knob as the dock's copy of this panel: Appearance → Opacity
        // "World clock" is the single authority for the plate's alpha.
        wc_panel.paint(cr, &self.wc, &self.wc_geom, chrome.of(&self.app.loaded.cfg), overlay_m.scale(&self.app.loaded.cfg.appearance, .world_clock), epochMs());
        const w: i32 = @intCast(self.wc_surface.configured_width);
        const h: i32 = @intCast(self.wc_surface.configured_height);
        self.wc_surface.attach(self.wc_shm.wlBuffer(), 0, 0);
        self.wc_surface.setBufferScale(self.wc_surface.scale);
        self.wc_surface.damage(0, 0, w, h);
        self.wc_shm.markBusy();
        self.wc_surface.commit();
    }

    /// Create, place and map the popup surface for the session's current
    /// state. Returns false when the surface never came up.
    fn presentWcSurface(self: *Taskbar, bar: *Bar, slot_idx: usize) bool {
        const cfg = &self.app.loaded.cfg;
        const g = self.wcGeom(bar);
        const us = self.wcUiScale();
        const pad_px: i32 = @intFromFloat(@round(wc_panel.k_shadow_pad * us));
        const sw: i32 = @as(i32, @intFromFloat(@ceil(g.w * us))) + 2 * pad_px;
        const sh: i32 = @as(i32, @intFromFloat(@ceil(g.total_h * us))) + 2 * pad_px;
        const box_h: f64 = @floatFromInt(@max(1, self.barHeight()));
        const icon = self.iconPx(box_h);
        // The card's right edge sticks 6 px past the widget's (the mockup's
        // `right: -6px`).
        const slot_right: f64 = if (slot_idx < bar.xs.len)
            bar.xs[slot_idx] + bar.ws[slot_idx]
        else
            @as(f64, @floatFromInt(bar.w));
        const margin_right: i32 = @intFromFloat(@round(@max(0.0, @as(f64, @floatFromInt(bar.w)) - slot_right - 6.0 * us - @as(f64, @floatFromInt(pad_px)))));
        const clearance = tb_settings.popupBottomClearancePx(&tb_settings.Settings{
            .height = cfg.taskbar.height,
            .width_mode = cfg.taskbar.width_mode,
            .floating_amount = cfg.taskbar.floating_amount,
            .edge_gap = cfg.taskbar.edge_gap,
        });
        // 16 px off the widget's near edge (the mockup's `bottom: 16px`).
        const edge: i32 = @intFromFloat(@round(@max(0.0, @as(f64, @floatFromInt(clearance)) - (box_h - icon) * 0.5 + 16.0 * us - @as(f64, @floatFromInt(pad_px)))));
        if (!self.wc_surface.create(self.app.bound.compositor, self.app.bound.layer_shell, null, .overlay, ns.popup)) return false;
        const top = cfg.taskbar.position_top;
        self.wc_surface.setAnchor(if (top)
            layer.Anchor.top | layer.Anchor.right
        else
            layer.Anchor.bottom | layer.Anchor.right);
        self.wc_surface.setExclusiveZone(-1);
        self.wc_surface.setSize(@intCast(sw), @intCast(sh));
        if (top) {
            self.wc_surface.setMargins(edge, margin_right, 0, 0);
        } else {
            self.wc_surface.setMargins(0, margin_right, edge, 0);
        }
        self.wc_surface.commit();
        var ticks: u32 = 0;
        while (ticks < 60 and !self.wc_surface.configured) : (ticks += 1) {
            if (!self.app.conn.roundtrip()) break;
        }
        if (!self.wc_surface.configured) {
            self.wc_surface.destroy();
            return false;
        }
        const w: i32 = @intCast(self.wc_surface.configured_width);
        const h: i32 = @intCast(self.wc_surface.configured_height);
        // `w`/`h` stay logical (the paint draws in them); only the buffer is
        // allocated at device pixels.
        if (!self.wc_shm.ensure(self.app.bound.shm, "taskbar-wcpop", w * self.wc_surface.scale, h * self.wc_surface.scale)) {
            self.wc_surface.destroy();
            return false;
        }
        self.wc_open = true;
        self.wc_slot = slot_idx;
        self.wc_geom = g;
        self.wc_anim_prev = true;
        self.setBarKeyboard(2);
        self.wcRefresh();
        if (!self.app.conn.flush()) logz.log("world-clock: flush failed", .{});
        return true;
    }

    fn openWorldClock(self: *Taskbar, bar: *Bar, slot_idx: usize) void {
        if (!self.wc_init or self.wc_open) return;
        self.closePopup();
        self.thumbsDismiss();
        self.closeCc();
        self.closePear();
        self.spotClose();
        const now_ms = epochMs();
        self.wc.openPopup(now_ms);
        _ = self.wc.tick(now_ms); // fresh offsets, fresh index, no stale acc
        if (!self.presentWcSurface(bar, slot_idx)) {
            self.wc.closePopup();
            logz.err("world-clock: surface failed, popup not shown", .{});
            return;
        }
        // The closers above reset `open_origin`: keep the toggle anchor on
        // the widget so a second click on it dismisses.
        self.open_origin = @intCast(slot_idx);
        self.armAnim();
        self.repaint();
    }

    fn closeWorldClock(self: *Taskbar) void {
        if (!self.wc_init) return;
        if (!self.wc_open and self.wc_surface.wl_surface == null) return;
        self.wc_open = false;
        self.wc_anim_prev = false;
        self.wc_surface.destroy();
        self.wc_shm.deinit();
        self.wc_shm = shm_mod.ShmBuffer.init(self.app.gpa);
        self.wc.closePopup();
        self.open_origin = -1;
        self.setBarKeyboard(0);
        if (!self.app.conn.flush()) logz.log("world-clock: flush failed on close", .{});
        self.repaint();
    }

    fn wcRelayout(self: *Taskbar, bar: *Bar) void {
        if (!self.wc_open) return;
        const g = self.wcGeom(bar);
        if (@abs(g.total_h - self.wc_geom.total_h) > 0.5 or @abs(g.w - self.wc_geom.w) > 0.5) {
            // The height drives the surface size: same discipline as pear,
            // a new surface on a changed height, session state kept.
            self.wc_surface.destroy();
            self.wc_open = false;
            self.wc_shm.deinit();
            self.wc_shm = shm_mod.ShmBuffer.init(self.app.gpa);
            if (!self.presentWcSurface(bar, self.wc_slot)) {
                self.wc.closePopup();
                logz.err("world-clock: relayout surface failed", .{});
            }
        } else {
            self.wc_geom = g;
        }
    }

    /// Apply a panel outcome: save, relayout, refresh the face and/or the
    /// popup, or close.
    fn applyWcOutcome(self: *Taskbar, out: wc_panel.Outcome) void {
        if (out.close) {
            self.closeWorldClock();
            return;
        }
        if (out.saved) self.wc.save();
        if (out.relayout and self.wc_open) {
            if (self.bars.items.len > 0) self.wcRelayout(&self.bars.items[0]);
        }
        if (out.face) {
            // The slot width follows the dots and the 12-hour suffix: rebuild
            // the strip model so the widget re-measures.
            self.dirty = true;
            self.rebuild();
            self.repaint();
        }
        if (self.wc_open and (out.repaint or out.face)) self.wcRefresh();
    }

    fn wcNatural(self: *Taskbar, x: f64, y: f64) struct { x: f64, y: f64 } {
        const us = self.wcUiScale();
        return .{ .x = x / us, .y = y / us };
    }

    fn wcPress(self: *Taskbar, x: f64, y: f64) wc_panel.Outcome {
        const p = self.wcNatural(x, y);
        const pad = wc_panel.k_shadow_pad;
        if (p.x < pad or p.y < pad or p.x > pad + self.wc_geom.w or p.y > pad + self.wc_geom.total_h) {
            // The shadow margin is surface, not card: a press there counts
            // as outside the popup.
            return .{ .handled = true, .close = true };
        }
        return wc_panel.press(&self.wc, &self.wc_geom, p.x, p.y, epochMs());
    }

    fn wcMotion(self: *Taskbar, x: f64, y: f64) wc_panel.Outcome {
        const p = self.wcNatural(x, y);
        return wc_panel.motion(&self.wc, &self.wc_geom, p.x, p.y, epochMs());
    }

    fn windowsForApp(self: *Taskbar, key: []const u8) usize {
        if (!self.ft_init) return 0;
        // A per-window key (`__eh_tl_<serial>`) counts once, while its window
        // is live.
        if (std.mem.startsWith(u8, key, "__eh_tl_")) {
            const serial = std.fmt.parseInt(u64, key["__eh_tl_".len..], 10) catch return 0;
            for (self.ft.list()) |tl| {
                if (!tl.closed and tl.handle != null and tl.serial == serial) return 1;
            }
            return 0;
        }
        var n: usize = 0;
        for (self.ft.list()) |tl| {
            if (tl.closed or tl.handle == null) continue;
            if (paths.sameAppId(key, tl.app_id)) n += 1;
        }
        return n;
    }

    // -- menus --------------------------------------------------------

    fn slotCentreX(_: *Taskbar, b: *Bar, idx: usize) ?i32 {
        if (idx >= b.xs.len) return null;
        return @intFromFloat(@round(b.xs[idx] + b.ws[idx] * 0.5));
    }

    fn openMenuFor(self: *Taskbar, b: *Bar, idx: usize) void {
        const s = &self.sections.all[idx];
        const cx = self.slotCentreX(b, idx) orelse return;
        if (s.kind == .tray) {
            self.openTrayMenu(s.key, cx);
        } else if (s.kind == .app) {
            self.openAppMenu(s, cx);
        } else if (s.kind == .trash) {
            self.openTrashMenu(cx);
        }
    }

    /// App context menu (`show_app_menu`): the desktop entry's action rows,
    /// Pin/Unpin, per-window rows, minimize/close, and New Window.
    fn openAppMenu(self: *Taskbar, s: *const tb_types.PaintSlot, cx: i32) void {
        if (!self.popup_init) return;
        self.menuReset();
        self.popup.reset();
        const alloc = self.menuAlloc();
        self.popup.kind = .app;
        // Appearance → Opacity: the app context menu follows the dock-menu
        // knob, like the dock's own app menu does (the C++ taskbar hard-coded
        // its menu alpha; this bar shares the dock popup, so the slider
        // reaches it here too). 1.0 at defaults.
        self.popup.menu_alpha = overlay_m.scale(&self.app.loaded.cfg.appearance, .dock_menu);
        self.menu_app_serial = s.chosen_serial;
        // Per-window buttons key off `__eh_tl_<serial>`; the menu works on
        // the app's group id so window rows and Close-all cover every window
        // of the app, exactly like the grouped button does.
        const per_window = std.mem.startsWith(u8, s.key, "__eh_tl_");
        self.menu_app_key = if (per_window and s.icon_id.len > 0)
            paths.normalizeAppId(alloc, s.icon_id) catch alloc.dupe(u8, s.key) catch ""
        else
            alloc.dupe(u8, s.key) catch "";
        self.menu_app_raw = alloc.dupe(u8, if (s.icon_id.len > 0) s.icon_id else s.key) catch "";

        // The desktop entry lookup prefers the chosen window's own app id,
        // which is the raw id for a per-window button.
        var lookup_buf: [512]u8 = undefined;
        var lookup: []const u8 = if (s.icon_id.len > 0) s.icon_id else s.key;
        if (s.chosen_serial != 0 and self.ft_init) {
            for (self.ft.list()) |tl| {
                if (tl.serial != s.chosen_serial or tl.handle == null or tl.closed) continue;
                lookup = std.fmt.bufPrint(&lookup_buf, "{s}", .{tl.app_id}) catch lookup;
                break;
            }
        }
        if (lookup.len > 0 and !std.mem.eql(u8, lookup, settings_app_id)) {
            const gpa = self.app.gpa;
            const dirs = app_launch.applicationsDirs(
                gpa,
                getenvStr("XDG_DATA_HOME"),
                getenvStr("HOME"),
                getenvStr("XDG_DATA_DIRS"),
            ) catch null;
            defer if (dirs) |d| app_launch.freeDirs(gpa, d);
            const info = desktop_actions.forAppId(alloc, self.app.io, dirs orelse &.{}, lookup);
            self.menu_app_exec = info.exec;
            self.menu_app_actions = info.actions;
        }

        // Every live window of the group: normalized key match, or the raw
        // id of the chosen window (per-window buttons list their app).
        var wins: std.ArrayList(MenuWin) = .empty;
        if (self.ft_init) {
            for (self.ft.list()) |tl| {
                if (tl.closed or tl.handle == null) continue;
                const norm = paths.normalizeAppId(alloc, tl.app_id) catch continue;
                if (!std.mem.eql(u8, norm, self.menu_app_key) and !std.mem.eql(u8, norm, lookup)) continue;
                wins.append(alloc, .{
                    .serial = tl.serial,
                    .title = alloc.dupe(u8, tl.title) catch "",
                }) catch break;
            }
        }
        self.menu_app_windows = wins.toOwnedSlice(alloc) catch &.{};

        for (self.menu_app_actions, 0..) |a, i| {
            const label = if (a.name.len > 0) a.name else a.id;
            self.popup.push(label, 1000 + @as(i32, @intCast(i)), a.exec.len > 0) catch break;
        }
        if (self.menu_app_actions.len > 0) self.popup.pushSeparator() catch {};
        const pin_ok = self.menu_app_key.len > 0 and
            !std.mem.eql(u8, self.menu_app_key, "unknown") and
            !std.mem.eql(u8, self.menu_app_key, settings_app_id) and
            (!per_window or s.icon_id.len > 0);
        self.popup.push(if (self.isPinned(self.menu_app_key)) "Unpin" else "Pin", 9001, pin_ok) catch {};
        self.popup.pushSeparator() catch {};
        if (s.chosen_serial != 0) {
            self.popup.push("Minimize window", 9002, true) catch {};
            self.popup.push("Close window", 9003, true) catch {};
            self.popup.push("Close all windows", 9004, true) catch {};
            self.popup.pushSeparator() catch {};
        }
        for (self.menu_app_windows, 0..) |w, i| {
            const label = if (w.title.len > 0) w.title else "(untitled)";
            self.popup.push(label, 2000 + @as(i32, @intCast(i)), w.serial != 0) catch break;
        }
        if (self.menu_app_windows.len > 0) self.popup.pushSeparator() catch {};
        if (self.menu_app_exec.len > 0) {
            self.popup.push("New Window", 3000, true) catch {};
            self.popup.pushSeparator() catch {};
        }
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        if (!self.popup.present(self.app.bound.compositor, self.app.bound.layer_shell, bar.w, bar.h, cx, bar.h, self.uiScale() * self.fitForOutput(bar.output))) {
            self.popup.reset();
            self.menuReset();
            return;
        }
        self.popup_slot = self.hover;
        if (!self.app.conn.flush()) logz.log("menu: flush failed", .{});
    }

    /// Right click on the trash widget: Open Trash / Empty Trash, with Empty
    /// disabled while the trash is empty (C++ `taskbar.cpp` 8001/8002).
    fn openTrashMenu(self: *Taskbar, cx: i32) void {
        if (!self.popup_init) return;
        self.popup.reset();
        self.popup.kind = .app;
        self.closeWorldClock();
        self.popup.menu_alpha = overlay_m.scale(&self.app.loaded.cfg.appearance, .dock_menu);
        self.popup.push("Open Trash", 8001, true) catch {};
        self.popup.pushSeparator() catch {};
        self.popup.push("Empty Trash", 8002, self.trash_full) catch {};
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        if (!self.popup.present(self.app.bound.compositor, self.app.bound.layer_shell, bar.w, bar.h, cx, bar.h, self.uiScale() * self.fitForOutput(bar.output))) {
            logz.err("menu: trash present failed", .{});
            self.popup.reset();
            return;
        }
        self.popup_slot = self.hover;
        if (!self.app.conn.flush()) logz.log("menu: flush failed", .{});
    }

    /// Left click (and the menu's Open Trash row): the same `xdg-open
    /// trash:///` the C++ widget's click runs (`taskbar.cpp`).
    fn openTrash(self: *Taskbar) void {
        if (!app_launch.launchExec(self.app.gpa, self.app.io, "xdg-open trash:///")) {
            logz.err("trash: could not start xdg-open", .{});
        }
    }

    /// The trash menu's two actions. Empty runs detached (no shell quoting);
    /// the icon flips immediately like the C++ bar and the five-second fs
    /// poll settles it either way.
    fn runTrashMenuAction(self: *Taskbar, id: i32) void {
        if (id == 8001) {
            self.openTrash();
            return;
        }
        const home = self.app.home orelse return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const trash_path = std.fmt.bufPrint(&path_buf, "{s}/.local/share/Trash", .{home}) catch return;
        autostart.spawnDetached(self.app.io, &.{ "gio", "trash", "--empty", trash_path }) catch {
            logz.err("trash: gio trash --empty failed to spawn", .{});
            return;
        };
        self.trash_full = false;
        self.trash_next_ms = 0;
        self.dirty = true;
    }

    fn isPinned(self: *Taskbar, key: []const u8) bool {
        for (self.pins) |p| {
            if (paths.sameAppId(p.norm, key)) return true;
        }
        return false;
    }

    fn openTrayMenu(self: *Taskbar, key: []const u8, cx: i32) void {
        if (!self.popup_init) return;
        // Prefer the item's own D-Bus menu; fall back to Activate/Quit rows.
        if (self.tray_init) {
            if (self.tray.itemForKey(key)) |it| {
                const gpa = self.app.gpa;
                if (tray_menu.menuPath(gpa, &self.tray.conn, it.service, it.path)) |mpath| {
                    defer gpa.free(mpath);
                    const entries = tray_menu.fetchTopLevel(gpa, &self.tray.conn, it.service, mpath);
                    defer gpa.free(entries);
                    if (entries.len > 0) {
                        self.popup.reset();
                        self.popup.kind = .tray;
                        self.popup.menu_alpha = overlay_m.scale(&self.app.loaded.cfg.appearance, .tray_menu);
                        for (entries) |e| {
                            if (tray_menu.isSeparator(e)) {
                                self.popup.pushSeparator() catch break;
                            } else {
                                self.popup.push(e.label, e.id, e.enabled) catch break;
                            }
                        }
                        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
                        if (self.popup.present(self.app.bound.compositor, self.app.bound.layer_shell, bar.w, bar.h, cx, bar.h, self.uiScale() * self.fitForOutput(bar.output))) {
                            if (!self.app.conn.flush()) logz.log("menu: flush failed", .{});
                            return;
                        }
                        self.popup.reset();
                    }
                }
            }
        }
        self.popup.reset();
        self.popup.kind = .tray;
        self.popup.menu_alpha = overlay_m.scale(&self.app.loaded.cfg.appearance, .tray_menu);
        self.popup.push("Activate", 10, true) catch return;
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        if (!self.popup.present(self.app.bound.compositor, self.app.bound.layer_shell, bar.w, bar.h, cx, bar.h, self.uiScale() * self.fitForOutput(bar.output))) {
            self.popup.reset();
        }
        if (!self.app.conn.flush()) logz.log("menu: flush failed", .{});
    }

    fn closePopup(self: *Taskbar) void {
        if (!self.popup_init) return;
        if (self.popup.kind == .launcher) self.closeLauncher();
        self.popup.reset();
        self.popup_slot = -1;
        self.open_origin = -1;
        self.menuReset();
    }

    /// Drop the app-menu model. Called when the menu closes (after the click
    /// that consumed it), and before rebuilding it on the next open.
    fn menuReset(self: *Taskbar) void {
        if (self.menu_arena) |*ar| ar.deinit();
        self.menu_arena = null;
        self.menu_app_key = "";
        self.menu_app_raw = "";
        self.menu_app_serial = 0;
        self.menu_app_exec = "";
        self.menu_app_actions = &.{};
        self.menu_app_windows = &.{};
    }

    fn menuAlloc(self: *Taskbar) std.mem.Allocator {
        if (self.menu_arena == null) self.menu_arena = std.heap.ArenaAllocator.init(self.app.gpa);
        return self.menu_arena.?.allocator();
    }

    fn onPopupSurface(self: *Taskbar) bool {
        if (!self.popup_init) return false;
        const seat = self.app.bound.seat_obj orelse return false;
        if (seat.focus_surface == null) return false;
        if (self.popup.surface.wl_surface) |ps| {
            if (seat.focus_surface == ps) return true;
        }
        return false;
    }

    fn popupMotion(self: *Taskbar) void {
        if (!self.popup_init) return;
        const seat = self.app.bound.seat_obj orelse return;
        if (self.popup.kind == .launcher and self.launcher_init) {
            if (self.launcher.hoverAt(seat.pointer_x, seat.pointer_y)) self.popupRefresh();
            return;
        }
        if (self.popup.kind == .volume_mixer) {
            if (self.mixerDragMotion()) return;
        }
        if (self.popup.hoverAt(@intFromFloat(@round(seat.pointer_x)), @intFromFloat(@round(seat.pointer_y)), self.uiScale())) {
            self.popupRefresh();
        }
    }

    fn popupPress(self: *Taskbar, button: u32) void {
        if (!self.popup_init) return;
        if (self.popup.kind == .launcher) {
            self.launcherPress(button);
            return;
        }
        self.popupMotion();
    }

    fn popupRelease(self: *Taskbar, button: u32) void {
        if (!self.popup_init) return;
        if (button != 272) return;
        switch (self.popup.kind) {
            .launcher => return,
            .calendar => {
                const seat = self.app.bound.seat_obj orelse return;
                const x: i32 = @intFromFloat(@round(seat.pointer_x));
                const y: i32 = @intFromFloat(@round(seat.pointer_y));
                // Month steps repaint in place; anything else dismisses.
                switch (self.popup.cardClick(x, y)) {
                    .prev_month => {
                        self.popup.stepMonth(-1);
                        self.popupRefresh();
                        return;
                    },
                    .next_month => {
                        self.popup.stepMonth(1);
                        self.popupRefresh();
                        return;
                    },
                    else => {},
                }
                self.closePopup();
                self.repaint();
                return;
            },
            .bluetooth => {
                if (!self.runBluetoothPopupClick()) self.closePopup();
                self.repaint();
                return;
            },
            .vpn => {
                if (!self.runVpnPopupClick()) self.closePopup();
                self.repaint();
                return;
            },
            .layout => {
                if (!self.runLayoutPopupClick()) self.closePopup();
                self.repaint();
                return;
            },
            .volume_mixer => {
                if (self.mixerRelease()) {
                    self.repaint();
                    return;
                }
                if (!self.runVolumeMixerPopupClick()) self.closePopup();
                self.repaint();
                return;
            },
            .media_player => {
                if (!self.runMediaPopupClick()) self.closePopup();
                self.repaint();
                return;
            },
            .weather => {
                // The card has no controls of its own: any click on it
                // closes it.
                self.closePopup();
                self.repaint();
                return;
            },
            else => {},
        }
        const seat = self.app.bound.seat_obj orelse return;
        const px: i32 = @intFromFloat(@round(seat.pointer_x));
        const py: i32 = @intFromFloat(@round(seat.pointer_y));
        if (self.popup.rowAt(px, py, self.uiScale())) |idx| {
            const row = self.popup.items.items[idx];
            if (!popup_mod.isSeparator(row) and row.enabled) self.runMenuAction(row.id);
            self.closePopup();
            self.repaint();
        }
    }

    fn runMenuAction(self: *Taskbar, id: i32) void {
        // Trash menu ids (C++ `taskbar.cpp` 8001/8002), gated on the app-menu
        // kind: a tray item's D-Bus ids share the integer space and must not
        // land here.
        if (self.popup.kind == .app and (id == 8001 or id == 8002)) {
            self.runTrashMenuAction(id);
            return;
        }
        // App context menu ids: desktop actions (1000+), window rows
        // (2000+), New Window (3000), Pin/Minimize/Close (9001-9004).
        if (id >= 1000 and self.popup.kind == .app) {
            self.runAppMenuAction(id);
            return;
        }
        const slot_idx = if (self.popup_slot >= 0) self.popup_slot else self.hover;
        switch (id) {
            10 => {
                if (slot_idx >= 0 and @as(usize, @intCast(slot_idx)) < self.sections.all.len) {
                    const s = &self.sections.all[@intCast(slot_idx)];
                    if (s.kind == .tray and self.tray_init) self.tray.activate(s.key, 0, 0);
                }
            },
            else => {
                // Tray D-Bus menu entry: forward to the item.
                if (slot_idx >= 0 and @as(usize, @intCast(slot_idx)) < self.sections.all.len) {
                    const s = &self.sections.all[@intCast(slot_idx)];
                    if (s.kind == .tray and self.tray_init) {
                        if (self.tray.itemForKey(s.key)) |it| {
                            const gpa = self.app.gpa;
                            if (tray_menu.menuPath(gpa, &self.tray.conn, it.service, it.path)) |mpath| {
                                defer gpa.free(mpath);
                                tray_menu.activate(&self.tray.conn, it.service, mpath, id);
                            }
                        }
                    }
                }
            },
        }
    }

    /// `TaskbarPopupKind::App` action arm: desktop-file actions, per-window
    /// activate, New Window, Pin/Unpin, minimize/close, close-all.
    fn runAppMenuAction(self: *Taskbar, id: i32) void {
        if (id >= 1000 and id < 2000) {
            const i: usize = @intCast(id - 1000);
            if (i < self.menu_app_actions.len) {
                const exec = self.menu_app_actions[i].exec;
                if (exec.len > 0) _ = app_launch.launchExec(self.app.gpa, self.app.io, exec);
            }
            return;
        }
        if (id >= 2000 and id < 3000) {
            const i: usize = @intCast(id - 2000);
            if (i < self.menu_app_windows.len) self.focusSerial(self.menu_app_windows[i].serial);
            return;
        }
        switch (id) {
            3000 => {
                if (self.menu_app_exec.len > 0) {
                    _ = app_launch.launchExec(self.app.gpa, self.app.io, self.menu_app_exec);
                }
            },
            9001 => {
                if (self.menu_app_key.len > 0 and
                    self.menu_app_raw.len > 0 and
                    !std.mem.startsWith(u8, self.menu_app_raw, "__eh_tl_") and
                    !std.mem.eql(u8, self.menu_app_key, "unknown") and
                    !std.mem.eql(u8, self.menu_app_key, settings_app_id))
                {
                    self.togglePin(self.menu_app_raw);
                }
            },
            9002 => self.minimizeSerial(self.menu_app_serial),
            9003 => self.closeSerial(self.menu_app_serial),
            9004 => {
                if (self.ft_init) {
                    const gpa = self.app.gpa;
                    for (self.ft.list()) |tl| {
                        if (tl.closed or tl.handle == null) continue;
                        const norm = paths.normalizeAppId(gpa, tl.app_id) catch continue;
                        defer gpa.free(norm);
                        if (!std.mem.eql(u8, norm, self.menu_app_key)) continue;
                        wl.zwlr_foreign_toplevel_handle_v1_close(tl.handle);
                    }
                    _ = self.app.conn.flush();
                }
            },
            else => {},
        }
    }

    fn focusSerial(self: *Taskbar, serial: u64) void {
        if (!self.ft_init or serial == 0) return;
        for (self.ft.list()) |tl| {
            if (tl.serial != serial or tl.handle == null or tl.closed) continue;
            _ = self.ft.raiseToplevel(&tl, self.app.bound.seat);
            _ = self.app.conn.flush();
            return;
        }
    }

    fn closeSerial(self: *Taskbar, serial: u64) void {
        if (!self.ft_init or serial == 0) return;
        for (self.ft.list()) |tl| {
            if (tl.serial != serial or tl.handle == null or tl.closed) continue;
            wl.zwlr_foreign_toplevel_handle_v1_close(tl.handle);
            _ = self.app.conn.flush();
            return;
        }
    }

    fn minimizeSerial(self: *Taskbar, serial: u64) void {
        if (!self.ft_init or serial == 0) return;
        for (self.ft.list()) |tl| {
            if (tl.serial != serial or tl.handle == null or tl.closed) continue;
            wl.zwlr_foreign_toplevel_handle_v1_set_minimized(tl.handle);
            _ = self.app.conn.flush();
            return;
        }
    }

    fn popupRefresh(self: *Taskbar) void {
        if (!self.popup_init) return;
        self.popup.refresh();
        if (!self.app.conn.flush()) logz.log("popup: flush failed", .{});
    }

    fn onPopupConfigure(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        if (!self.popup_init) return;
        if (self.popup.kind == .launcher and w > 0 and h > 0) {
            // The surface is `fit` smaller than the natural `geo`; convert the
            // granted size back so the layout constants stay undisturbed.
            const f = self.launcher.fit;
            self.launcher.sizeTo(@as(f64, @floatFromInt(w)) / f, @as(f64, @floatFromInt(h)) / f);
        }
        self.popup.configured(self.app.bound.shm);
        if (!self.app.conn.flush()) logz.log("popup: flush failed after configure", .{});
    }

    fn onPopupClosed(ctx: *anyopaque) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        if (!self.popup_init) return;
        if (self.popup.kind == .launcher) self.closeLauncher();
        self.popup.reset();
        self.popup_slot = -1;
    }

    // -- hover previews -------------------------------------------------

    fn onThumbsSurface(self: *Taskbar) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        if (seat.focus_surface == null) return false;
        if (self.thumbs.wl_surface) |ts| {
            if (seat.focus_surface == ts) return true;
        }
        return false;
    }

    /// Tear down the preview *surface* only: `openThumbsList` is about to
    /// rebuild it from a freshly collected window list, so the list and the
    /// group key must survive.
    fn thumbsCloseSurface(self: *Taskbar) void {
        if (self.thumbs_open or self.thumbs.wl_surface != null) {
            self.thumbs_shm.deinit();
            self.thumbs_shm = shm_mod.ShmBuffer.init(self.app.gpa);
            self.thumbs.destroy();
        }
        self.thumbs_open = false;
        self.thumbs_hover = -1;
        self.thumbs_close_hover = false;
    }

    fn thumbsDismiss(self: *Taskbar) void {
        self.thumbsCloseSurface();
        self.open_origin = -1;
        const gpa = self.app.gpa;
        if (self.thumbs_wins.len > 0) gpa.free(self.thumbs_wins);
        self.thumbs_wins = &.{};
        if (self.thumbs_group.len > 0) gpa.free(self.thumbs_group);
        self.thumbs_group = &.{};
        if (self.thumbs_icon_key.len > 0) gpa.free(self.thumbs_icon_key);
        self.thumbs_icon_key = &.{};
    }

    /// True when hovering slot `idx` should open window previews instead of
    /// the text tooltip: a running app button with thumbnails enabled.
    fn slotPreviewsOnHover(self: *Taskbar, idx: i32) bool {
        if (idx < 0 or @as(usize, @intCast(idx)) >= self.sections.all.len) return false;
        if (!self.app.loaded.cfg.taskbar.thumbnails_enabled) return false;
        const s = &self.sections.all[@intCast(idx)];
        if (s.kind != .app) return false;
        if (std.mem.eql(u8, s.key, tb_types.chevron_key)) return false;
        return self.windowsForApp(s.key) > 0;
    }

    /// Hover clock: after the tooltip delay a running app button opens (or
    /// refreshes) its window previews and never shows the text tooltip;
    /// everything else falls through to the tooltip. Mirrors
    /// `taskbar_tooltip_tick`.
    fn hoverTick(self: *Taskbar) void {
        if (self.hover < 0 or @as(usize, @intCast(self.hover)) >= self.sections.all.len) {
            // The pointer may simply be on the previews themselves; that
            // transition keeps the popup (C++ leave handler policy).
            if (self.thumbs_open and !self.onThumbsSurface()) self.thumbsDismiss();
            return;
        }
        const now = nowMs();
        if (self.slotPreviewsOnHover(self.hover)) {
            // Previews own this slot: no text tooltip, ever.
            self.tooltip_slot = self.hover;
            const s = &self.sections.all[@intCast(self.hover)];
            if (self.thumbs_open) {
                if (std.mem.eql(u8, self.thumbs_group, s.key)) {
                    self.tooltipHide();
                    self.thumbsTick();
                }
                return;
            }
            if (now -| self.tooltip_start_ms >= tb_state.tooltip_delay_ms) {
                const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
                const cx = self.slotCentreX(bar, @intCast(self.hover)) orelse return;
                self.tooltipHide();
                self.open_origin = self.hover;
                self.openThumbs(s.key, s.icon_id, cx);
            }
            return;
        }
        if (self.thumbs_open) {
            self.thumbsDismiss();
            return;
        }
        if (!self.tooltip_open and self.tooltip_slot == self.hover and
            tb_state.tooltipDue(self.hover, self.tooltip_start_ms, -1, now, self.app.loaded.cfg.taskbar.tooltips_enabled))
        {
            self.tooltipShow();
        }
    }

    /// Dismiss previews when the hover group changes (`thumbs` popup policy).
    fn hoverGroupChanged(self: *Taskbar) void {
        if (!self.thumbs_open) return;
        const key = if (self.hover < 0 or @as(usize, @intCast(self.hover)) >= self.sections.all.len)
            ""
        else
            self.sections.all[@intCast(self.hover)].key;
        if (std.mem.eql(u8, self.thumbs_group, key)) return;
        self.thumbsDismiss();
    }

    fn freeThumbWins(self: *Taskbar) void {
        const gpa = self.app.gpa;
        for (self.thumbs_wins) |tw| {
            if (tw.title.len > 0) gpa.free(tw.title);
        }
        if (self.thumbs_wins.len > 0) gpa.free(self.thumbs_wins);
        self.thumbs_wins = &.{};
    }

    fn collectThumbWins(self: *Taskbar, key: []const u8) void {
        const gpa = self.app.gpa;
        self.freeThumbWins();
        if (!self.ft_init) return;
        var list: std.ArrayList(ThumbWin) = .empty;
        errdefer {
            for (list.items) |tw| {
                if (tw.title.len > 0) gpa.free(tw.title);
            }
            list.deinit(gpa);
        }
        // A per-window key (`__eh_tl_<serial>`) previews exactly its own
        // window; an app key previews every live window of that app.
        const single = std.mem.startsWith(u8, key, "__eh_tl_");
        const single_serial: u64 = if (single)
            (std.fmt.parseInt(u64, key["__eh_tl_".len..], 10) catch 0)
        else
            0;
        for (self.ft.list()) |tl| {
            if (tl.closed or tl.handle == null) continue;
            if (single) {
                if (tl.serial != single_serial) continue;
            } else if (!paths.sameAppId(key, tl.app_id)) continue;
            const owned = gpa.dupe(u8, tl.title) catch continue;
            errdefer gpa.free(owned);
            list.append(gpa, .{ .serial = tl.serial, .title = owned }) catch {
                gpa.free(owned);
                break;
            };
            if (single) break;
        }
        // Stable order by serial.
        std.mem.sort(ThumbWin, list.items, {}, struct {
            fn lt(_: void, a: ThumbWin, b: ThumbWin) bool {
                return a.serial < b.serial;
            }
        }.lt);
        self.thumbs_wins = list.toOwnedSlice(gpa) catch &.{};
    }

    fn openThumbs(self: *Taskbar, key: []const u8, icon_id: []const u8, anchor_x: i32) void {
        self.collectThumbWins(key);
        if (self.thumbs_wins.len == 0) return;
        const gpa = self.app.gpa;
        if (self.thumbs_group.len > 0) gpa.free(self.thumbs_group);
        self.thumbs_group = gpa.dupe(u8, key) catch &.{};
        if (self.thumbs_icon_key.len > 0) gpa.free(self.thumbs_icon_key);
        self.thumbs_icon_key = gpa.dupe(u8, icon_id) catch &.{};
        self.openThumbsList(anchor_x);
    }

    /// Open the preview surface for whatever is already in thumbs_wins
    /// (app group or chevron overflow). Caller owns the group bookkeeping.
    /// The chevron's hidden-window list is always a list (C++ sets
    /// `thumbListMode = true` for it); app groups pick their mode from the
    /// window count.
    fn openThumbsList(self: *Taskbar, anchor_x: i32) void {
        if (self.thumbs_wins.len == 0) return;
        const cfg = &self.app.loaded.cfg;
        const force_list = std.mem.eql(u8, self.thumbs_group, tb_types.chevron_key);
        const list_mode = force_list or tb_state.ThumbState.decideListMode(self.thumbs_wins.len, cfg.taskbar.thumbnail_threshold);
        const g = tb_types.thumbsGeom(self.thumbs_wins.len, list_mode);
        const pw: i32 = @intFromFloat(@ceil(g.w));
        const ph: i32 = @intFromFloat(@ceil(g.h));
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        const pos = tb_position.computePopupPosition(anchor_x, pw, bar.w, &tb_settings.Settings{
            .height = cfg.taskbar.height,
            .width_mode = cfg.taskbar.width_mode,
            .floating_amount = cfg.taskbar.floating_amount,
            .edge_gap = cfg.taskbar.edge_gap,
        });
        _ = pos;
        // Replace the surface, not the model (wins/group stay).
        self.closeWorldClock();
        self.thumbsCloseSurface();
        if (!self.thumbs.create(self.app.bound.compositor, self.app.bound.layer_shell, null, .overlay, ns.popup)) return;
        self.thumbs.setAnchor(layer.Anchor.bottom | layer.Anchor.left);
        self.thumbs.setExclusiveZone(-1);
        self.thumbs.setSize(@intCast(pw), @intCast(ph));
        // Reuse the popup margin math: left offset centers on the anchor.
        const want_left = @as(f64, @floatFromInt(anchor_x)) - @as(f64, @floatFromInt(pw)) * 0.5;
        const margin_left: i32 = @intFromFloat(@round(@max(0.0, @min(want_left, @max(0.0, @as(f64, @floatFromInt(bar.w)) - @as(f64, @floatFromInt(pw)))))));
        const clearance = tb_settings.popupBottomClearancePx(&tb_settings.Settings{
            .height = cfg.taskbar.height,
            .width_mode = cfg.taskbar.width_mode,
            .floating_amount = cfg.taskbar.floating_amount,
            .edge_gap = cfg.taskbar.edge_gap,
        });
        if (cfg.taskbar.position_top) {
            self.thumbs.setAnchor(layer.Anchor.top | layer.Anchor.left);
            self.thumbs.setMargins(clearance, 0, 0, margin_left);
        } else {
            self.thumbs.setMargins(0, 0, clearance, margin_left);
        }
        self.thumbs.commit();
        var ticks: u32 = 0;
        while (ticks < 60 and !self.thumbs.configured) : (ticks += 1) {
            if (!self.app.conn.roundtrip()) break;
        }
        if (!self.thumbs.configured) {
            self.thumbs.destroy();
            return;
        }
        const w: i32 = @intCast(self.thumbs.configured_width);
        const h: i32 = @intCast(self.thumbs.configured_height);
        // `w`/`h` stay logical (paintThumbs draws in them); only the buffer is
        // allocated at device pixels.
        if (!self.thumbs_shm.ensure(self.app.bound.shm, "taskbar-thumbs", w * self.thumbs.scale, h * self.thumbs.scale)) {
            self.thumbs.destroy();
            return;
        }
        self.thumbs_open = true;
        self.thumbs_anchor = anchor_x;
        self.thumbs_hover = -1;
        self.thumbs_list_mode = list_mode;
        self.paintThumbs();
        if (!self.app.conn.flush()) logz.log("thumbs: flush failed", .{});
    }

    fn openChevronOverflow(self: *Taskbar, anchor_x: i32) void {
        const gpa = self.app.gpa;
        if (self.thumbs_wins.len > 0) gpa.free(self.thumbs_wins);
        self.thumbs_wins = &.{};
        if (self.thumbs_group.len > 0) gpa.free(self.thumbs_group);
        self.thumbs_group = gpa.dupe(u8, tb_types.chevron_key) catch &.{};
        var list: std.ArrayList(ThumbWin) = .empty;
        errdefer list.deinit(gpa);
        for (self.chev_wins) |cw| {
            if (!self.ft_init) continue;
            for (self.ft.list()) |tl| {
                if (!tl.closed and tl.handle != null and tl.serial == cw.serial) {
                    const owned = gpa.dupe(u8, tl.title) catch break;
                    errdefer gpa.free(owned);
                    list.append(gpa, .{ .serial = cw.serial, .title = owned }) catch {
                        gpa.free(owned);
                        break;
                    };
                    break;
                }
            }
        }
        std.mem.sort(ThumbWin, list.items, {}, struct {
            fn lt(_: void, a: ThumbWin, b: ThumbWin) bool {
                return a.serial < b.serial;
            }
        }.lt);
        self.thumbs_wins = list.toOwnedSlice(gpa) catch &.{};
        // Freeze the icon key at open time; `self.hover` is -1 once the
        // pointer moves onto the popup. (C++ keeps `thumbIconId` too.)
        if (self.thumbs_icon_key.len > 0) gpa.free(self.thumbs_icon_key);
        self.thumbs_icon_key = &.{};
        if (self.hover >= 0 and @as(usize, @intCast(self.hover)) < self.sections.all.len) {
            self.thumbs_icon_key = gpa.dupe(u8, self.sections.all[@intCast(self.hover)].icon_id) catch &.{};
        }
        self.openThumbsList(anchor_x);
    }

    fn paintThumbs(self: *Taskbar) void {
        if (!self.thumbs_open) return;
        const cr = self.thumbs_shm.cr orelse return;
        const w: i32 = @intCast(self.thumbs.configured_width);
        const h: i32 = @intCast(self.thumbs.configured_height);
        cairo.cairo_save(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        cairo.cairo_restore(cr);
        // Scale to the output's device pixels; paintThumbs draws in logical
        // coordinates (w/h from the configure).
        cairo.cairo_identity_matrix(cr);
        const thsc: f64 = @floatFromInt(self.thumbs.scale);
        cairo.cairo_scale(cr, thsc, thsc);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        const gpa = self.app.gpa;
        var items = gpa.alloc(tb_paint.ThumbItem, self.thumbs_wins.len) catch return;
        defer gpa.free(items);
        // The card icon is the group's app icon, frozen at open time:
        // `self.hover` goes -1 when the pointer moves off the bar onto the
        // popup, but the popup keeps painting the same glyph.
        var hov_icon = dwp.IconPx{};
        if (self.thumbs_icon_key.len > 0) {
            const box_h: f64 = @floatFromInt(@max(1, self.barHeight()));
            const icon_px: i32 = @intFromFloat(@round(@max(16.0, self.iconPx(box_h) * 2.0)));
            hov_icon = self.resolveAppIcon(self.thumbs_icon_key, icon_px);
        }
        for (self.thumbs_wins, 0..) |tw, i| {
            var active = false;
            if (self.ft_init) {
                for (self.ft.list()) |tl| {
                    if (tl.serial == tw.serial) {
                        active = tl.activated;
                        break;
                    }
                }
            }
            items[i] = .{
                .title = tw.title,
                .icon = .{ .pixels = hov_icon.pixels, .w = hov_icon.w, .h = hov_icon.h },
                .active = active,
            };
        }
        tb_paint.paintThumbs(cr, items, self.thumbs_list_mode, self.thumbs_hover, self.thumbs_close_hover, self.app.loaded.cfg.taskbar.thumbnail_peek_enabled);
        self.thumbs.attach(self.thumbs_shm.wlBuffer(), 0, 0);
        self.thumbs.setBufferScale(self.thumbs.scale);
        self.thumbs.damage(0, 0, w, h);
        self.thumbs_shm.markBusy();
        self.thumbs.commit();
    }

    fn thumbsMotion(self: *Taskbar) void {
        const seat = self.app.bound.seat_obj orelse return;
        const g = tb_types.thumbsGeom(self.thumbs_wins.len, self.thumbs_list_mode);
        // Popup-local coords: layer surface origin; use pointer relative to
        // the surface (seat reports surface-local).
        const px = seat.pointer_x;
        const py = seat.pointer_y;
        const row = tb_types.thumbsRowAt(&g, self.thumbs_wins.len, px, py);
        const close_hov = if (row >= 0) tb_types.thumbsPointInClose(&g, @intCast(row), px, py) else false;
        if (row != self.thumbs_hover or close_hov != self.thumbs_close_hover) {
            self.thumbs_hover = row;
            self.thumbs_close_hover = close_hov;
            self.paintThumbs();
            _ = self.app.conn.flush();
        }
    }

    fn thumbsClick(self: *Taskbar, button: u32) void {
        if (button != 272) return;
        const seat = self.app.bound.seat_obj orelse return;
        const g = tb_types.thumbsGeom(self.thumbs_wins.len, self.thumbs_list_mode);
        const row = tb_types.thumbsRowAt(&g, self.thumbs_wins.len, seat.pointer_x, seat.pointer_y);
        if (row < 0 or @as(usize, @intCast(row)) >= self.thumbs_wins.len) {
            self.thumbsDismiss();
            return;
        }
        const tw = self.thumbs_wins[@intCast(row)];
        if (tb_types.thumbsPointInClose(&g, @intCast(row), seat.pointer_x, seat.pointer_y)) {
            if (self.ft_init) {
                for (self.ft.list()) |tl| {
                    if (tl.serial == tw.serial and tl.handle != null and !tl.closed) {
                        wl.zwlr_foreign_toplevel_handle_v1_close(tl.handle);
                        break;
                    }
                }
                _ = self.app.conn.flush();
            }
            self.thumbsDismiss();
            self.dirty = true;
            return;
        }
        if (self.ft_init) {
            for (self.ft.list()) |tl| {
                if (tl.serial == tw.serial and tl.handle != null and !tl.closed) {
                    _ = self.ft.raiseToplevel(&tl, self.app.bound.seat);
                    _ = self.app.conn.flush();
                    break;
                }
            }
        }
        self.thumbsDismiss();
    }

    fn thumbsTick(self: *Taskbar) void {
        if (!self.thumbs_open) return;
        // Thumbnails turned off while the previews were up: close them
        // (`taskbar_thumbs_refresh`).
        if (!self.app.loaded.cfg.taskbar.thumbnails_enabled) {
            self.thumbsDismiss();
            return;
        }
        // Re-resolve titles; close when nothing remains.
        const before = self.thumbs_wins.len;
        if (std.mem.eql(u8, self.thumbs_group, tb_types.chevron_key)) {
            const anchor = self.thumbs_anchor;
            const gpa = self.app.gpa;
            var list: std.ArrayList(ThumbWin) = .empty;
            defer list.deinit(gpa);
            for (self.chev_wins) |cw| {
                if (!self.ft_init) continue;
                for (self.ft.list()) |tl| {
                    if (!tl.closed and tl.handle != null and tl.serial == cw.serial) {
                        const owned = gpa.dupe(u8, tl.title) catch break;
                        errdefer gpa.free(owned);
                        list.append(gpa, .{ .serial = cw.serial, .title = owned }) catch {
                            gpa.free(owned);
                            break;
                        };
                        break;
                    }
                }
            }
            self.freeThumbWins();
            self.thumbs_wins = list.toOwnedSlice(gpa) catch &.{};
            if (self.thumbs_wins.len == 0) {
                self.thumbsDismiss();
                return;
            }
            if (!self.thumbs_list_mode or self.thumbs_wins.len != before) {
                const anchor_keep = anchor;
                self.openThumbsList(anchor_keep);
                return;
            }
            self.paintThumbs();
            return;
        }
        self.collectThumbWins(self.thumbs_group);
        if (self.thumbs_wins.len == 0) {
            self.thumbsDismiss();
            return;
        }
        const cfg = &self.app.loaded.cfg;
        const list_mode = tb_state.ThumbState.decideListMode(self.thumbs_wins.len, cfg.taskbar.thumbnail_threshold);
        if (list_mode != self.thumbs_list_mode or self.thumbs_wins.len != before) {
            // `openThumbs` re-dupes both keys, so hand it copies that
            // outlive the frees inside.
            const anchor = self.thumbs_anchor;
            var group_buf: [256]u8 = undefined;
            const group = std.fmt.bufPrint(&group_buf, "{s}", .{self.thumbs_group}) catch "";
            var icon_buf: [256]u8 = undefined;
            const icon = std.fmt.bufPrint(&icon_buf, "{s}", .{self.thumbs_icon_key}) catch group;
            self.openThumbs(group, icon, anchor);
            return;
        }
        self.paintThumbs();
    }

    // -- tooltip ------------------------------------------------------

    /// Tooltip text policy, `tb_tooltip_text`: chevron, overview and layout
    /// labels, a per-window button's full title, the app's desktop-entry
    /// name, then the raw slot key.
    fn tooltipText(self: *Taskbar, s: *const tb_types.PaintSlot, buf: *[512]u8) []const u8 {
        if (std.mem.eql(u8, s.key, tb_types.chevron_key)) return "More windows";
        const impl = dw.implType(&self.app.loaded.cfg, s.key);
        if (std.mem.eql(u8, impl, "overview")) return "Overview";
        if (std.mem.eql(u8, impl, "layout")) {
            return std.fmt.bufPrint(buf, "Window Layout: {s}", .{layout_paint.titleFor(layout_paint.current())}) catch "Window Layout";
        }
        if (s.kind == .app) {
            if (std.mem.startsWith(u8, s.key, "__eh_tl_")) {
                const t = self.titleForSerial(s.chosen_serial);
                if (t.len > 0) return t;
            }
            const gpa = self.app.gpa;
            const target = if (s.icon_id.len > 0) s.icon_id else s.key;
            const dirs = app_launch.applicationsDirs(
                gpa,
                getenvStr("XDG_DATA_HOME"),
                getenvStr("HOME"),
                getenvStr("XDG_DATA_DIRS"),
            ) catch null;
            defer if (dirs) |d| app_launch.freeDirs(gpa, d);
            if (app_launch.desktopName(gpa, self.app.io, dirs orelse &.{}, target)) |name| {
                defer gpa.free(name);
                const n = @min(name.len, buf.len);
                @memcpy(buf[0..n], name[0..n]);
                return buf[0..n];
            }
        }
        return s.key;
    }

    fn tooltipShow(self: *Taskbar) void {
        if (self.tooltip_open) return;
        if (self.hover < 0 or @as(usize, @intCast(self.hover)) >= self.sections.all.len) return;
        const s = &self.sections.all[@intCast(self.hover)];
        var text_buf: [512]u8 = undefined;
        const text = self.tooltipText(s, &text_buf);
        if (text.len == 0) return;
        const font_px: f64 = 12.0;
        const tw = self.measureLabel(text, font_px) + 16.0;
        const th: f64 = 28.0;
        const w: i32 = @intFromFloat(@ceil(tw));
        const h: i32 = @intFromFloat(th);
        if (!self.tooltip.create(self.app.bound.compositor, self.app.bound.layer_shell, null, .overlay, ns.popup)) return;
        self.tooltip.setAnchor(layer.Anchor.bottom | layer.Anchor.left);
        self.tooltip.setExclusiveZone(-1);
        self.tooltip.setSize(@intCast(w), @intCast(h));
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        const sx: f64 = if (self.hover >= 0 and @as(usize, @intCast(self.hover)) < bar.xs.len) bar.xs[@intCast(self.hover)] + bar.ws[@intCast(self.hover)] * 0.5 else 0;
        const margin_left: i32 = @intFromFloat(@round(@max(0.0, @min(sx - @as(f64, @floatFromInt(w)) * 0.5, @as(f64, @floatFromInt(bar.w)) - @as(f64, @floatFromInt(w))))));
        const clearance = tb_settings.popupBottomClearancePx(&tb_settings.Settings{
            .height = self.app.loaded.cfg.taskbar.height,
            .width_mode = self.app.loaded.cfg.taskbar.width_mode,
            .floating_amount = self.app.loaded.cfg.taskbar.floating_amount,
            .edge_gap = self.app.loaded.cfg.taskbar.edge_gap,
        }) + @as(i32, @intCast(bar.h));
        self.tooltip.setMargins(0, 0, clearance, margin_left);
        self.tooltip.commit();
        var ticks: u32 = 0;
        while (ticks < 60 and !self.tooltip.configured) : (ticks += 1) {
            if (!self.app.conn.roundtrip()) break;
        }
        if (!self.tooltip.configured) {
            self.tooltip.destroy();
            return;
        }
        if (!self.tooltip_shm.ensure(self.app.bound.shm, "taskbar-tip", w * self.tooltip.scale, h * self.tooltip.scale)) {
            self.tooltip.destroy();
            return;
        }
        const cr = self.tooltip_shm.cr orelse {
            self.tooltip.destroy();
            return;
        };
        cairo.cairo_save(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        cairo.cairo_restore(cr);
        // Scale to the output's device pixels; paintTooltip draws in logical
        // coordinates (w/h).
        cairo.cairo_identity_matrix(cr);
        const tlsc: f64 = @floatFromInt(self.tooltip.scale);
        cairo.cairo_scale(cr, tlsc, tlsc);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        tb_paint.paintTooltip(cr, text, @floatFromInt(w), @floatFromInt(h), overlay_m.scale(&self.app.loaded.cfg.appearance, .tooltip));
        self.tooltip.attach(self.tooltip_shm.wlBuffer(), 0, 0);
        self.tooltip.setBufferScale(self.tooltip.scale);
        self.tooltip.damage(0, 0, w, h);
        self.tooltip_shm.markBusy();
        self.tooltip.commit();
        self.tooltip_open = true;
        self.tooltip_slot = self.hover;
        _ = self.app.conn.flush();
    }

    fn tooltipHide(self: *Taskbar) void {
        if (self.tooltip_open or self.tooltip.wl_surface != null) {
            self.tooltip_shm.deinit();
            self.tooltip_shm = shm_mod.ShmBuffer.init(self.app.gpa);
            self.tooltip.destroy();
        }
        self.tooltip_open = false;
        self.tooltip_slot = -1;
    }

    // -- widget cards -------------------------------------------------

    fn openCard(self: *Taskbar, kind: tb_types.PopupKind, cx: i32) void {
        if (!self.popup_init) return;
        self.closeWorldClock();
        const cfg = &self.app.loaded.cfg;
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        self.popup.reset();
        // Hand the card the live config: without it the layout card's paint
        // bails on the null widget config and its surface stays blank.
        self.popup.widget_cfg = cfg;
        const fit = self.fitForOutput(bar.output);
        const ok = switch (kind) {
            .calendar => self.popup.openCalendar(
                self.app.bound.compositor,
                self.app.bound.layer_shell,
                bar.w,
                bar.h,
                cx,
                local_time.today(),
                chrome.of(cfg),
                // The calendar knob alone: an advanced-mode slider is the
                // single authority for its surface (0% nothing, 100% solid).
                overlay_m.scale(&cfg.appearance, .calendar),
                fit,
            ),
            .weather => self.popup.openWeather(
                self.app.bound.compositor,
                self.app.bound.layer_shell,
                bar.w,
                bar.h,
                cx,
                chrome.of(cfg),
                // Same as the calendar: the weather knob alone.
                overlay_m.scale(&cfg.appearance, .weather),
                fit,
            ),
            .bluetooth => self.popup.openBluetooth(
                self.app.bound.compositor,
                self.app.bound.layer_shell,
                bar.w,
                bar.h,
                cx,
                cfg,
                &bt_paint.Snapshot{},
                &.{},
                fit,
            ),
            .layout => self.popup.openLayout(
                self.app.bound.compositor,
                self.app.bound.layer_shell,
                bar.w,
                bar.h,
                cx,
                fit,
            ),
            .vpn => self.popup.openVpn(
                self.app.bound.compositor,
                self.app.bound.layer_shell,
                bar.w,
                bar.h,
                cx,
                0,
                fit,
            ),
            .volume_mixer => self.popup.openVolumeMixer(
                self.app.bound.compositor,
                self.app.bound.layer_shell,
                bar.w,
                bar.h,
                cx,
                fit,
            ),
            .media_player => self.popup.openMediaPlayer(
                self.app.bound.compositor,
                self.app.bound.layer_shell,
                bar.w,
                bar.h,
                cx,
                chrome.of(cfg),
                fit,
            ),
            else => false,
        };
        if (!ok) {
            self.popup.reset();
            return;
        }
        self.popup_slot = self.hover;
        if (!self.app.conn.flush()) logz.log("card: flush failed", .{});
    }

    /// Toggle the standalone `horizon-overview`: our own copy is reaped or
    /// signalled off, otherwise the sibling next to this binary is spawned.
    /// The overview itself is a singleton (runtime lock), so a copy another
    /// bar spawned toggles closed instead of opening a second window.
    fn requestOverviewToggle(self: *Taskbar) void {
        if (self.ov_pid) |pid| {
            var status: u32 = 0;
            const rc: isize = @bitCast(linux.wait4(pid, &status, linux.W.NOHANG, null));
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

    // -- control center (dock parity) -----------------------------------

    fn ccDragging(self: *Taskbar) bool {
        if (!self.cc_init) return false;
        return self.cc.dragging_output or self.cc.dragging_input or self.cc.dragging_mixer;
    }

    fn dragFrameDue(self: *Taskbar, now_ms: u64) bool {
        if (now_ms < self.drag_next_paint_ms) return false;
        self.drag_next_paint_ms = now_ms + 16;
        return true;
    }

    fn pollCcLive(self: *Taskbar, now_ms: u64, force: bool) bool {
        if (!force and now_ms < self.cc_next_live_ms) return false;
        // A slider drag is writing the backend right now: defer the poll or
        // a read runs on the pointer thread mid-drag and shows stale values.
        if (self.ccDragging() or self.pearDragging()) return false;
        const step: u64 = if (self.cc.open or (self.pear_init and self.pear.open)) 1000 else 2000;
        self.cc_next_live_ms = now_ms + step;
        const gpa = self.app.gpa;
        const detail = force or self.cc.open or (self.pear_init and self.pear.open);
        if (cc_live_audio.query(gpa, self.app.io, detail)) |queried| {
            self.freeCcAudio();
            self.cc_audio = queried;
            if (self.cc_audio) |*qc| cc_apply.suppressEcho(now_ms, &qc.snap);
        }
        if (cc_live_network.query(gpa)) |q| {
            self.freeCcNet();
            self.cc_net = q;
            self.cc_wifi_err_len = 0;
        }
        var bt_changed = false;
        if (cc_live_bluetooth.query(gpa)) |fresh| {
            var devs: []bt_paint.Device = &.{};
            var snap: bt_paint.Snapshot = .{};
            devs = bt_paint.devicesFromQueried(gpa, &fresh) catch &.{};
            snap = bt_paint.snapshotFromQueried(&fresh, devs);
            bt_changed = !std.meta.eql(self.bt_snap, snap);
            if (!bt_changed) {
                if (self.bt_devs.len != devs.len) {
                    bt_changed = true;
                } else {
                    for (self.bt_devs, devs) |a, b| {
                        if (a.kind != b.kind or a.paired != b.paired or a.connected != b.connected) {
                            bt_changed = true;
                            break;
                        }
                        if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.alias, b.alias)) {
                            bt_changed = true;
                            break;
                        }
                    }
                }
            }
            self.freeCcBt();
            self.cc_bt = fresh;
            self.bt_devs = devs;
            self.bt_snap = snap;
            if (self.popup_init and self.popup.kind == .bluetooth) {
                self.popup.bt_snap = self.bt_snap;
                self.popup.bt_devs = self.bt_devs;
            }
        }
        if (cc_live_media.query(gpa)) |q| {
            self.freeCcMedia();
            self.cc_media = q;
        }
        const pear_changed = self.refreshPearRuntime();
        if (self.popup_init and self.popup.kind == .bluetooth and bt_changed) {
            if (self.settleWidgetCard()) {} else self.popupRefresh();
        }
        if (self.cc.open) {
            const snap = self.buildCcSnapshot();
            self.cc.setSnapshot(snap);
            self.cc.relayout(now_ms, false);
            self.ccSettleResize(now_ms);
            self.ccRefresh();
            return true;
        }
        if (self.pear_init and self.pear.open) {
            self.refreshPearPopup();
            return true;
        }
        return bt_changed or pear_changed;
    }

    fn buildCcSnapshot(self: *Taskbar) cc_data.Snapshot {
        var snap = cc_data.Snapshot{};
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
        var paired_count: i32 = 0;
        if (self.cc_bt) |*q| {
            snap.bt = .{ .powered = q.snap.powered, .connected = false, .discovering = q.snap.discovering };
            var n: usize = 0;
            for (q.device_list.items) |d| {
                if (d.paired) paired_count += 1;
                if (d.connected) snap.bt.connected = true;
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
        }
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
            for (q.snap.out_streams) |st| {
                if (so >= self.cc_snap_outs.len) break;
                self.cc_snap_outs[so] = .{
                    .sink_input_id = st.id,
                    .volume_pct = st.volume_pct,
                    .muted = st.muted,
                    .app_name = if (st.app_name.len > 0) st.app_name else "Unknown App",
                };
                so += 1;
            }
            snap.out_streams = self.cc_snap_outs[0..so];
            var si: usize = 0;
            for (q.snap.in_streams) |st| {
                if (si >= self.cc_snap_ins.len) break;
                self.cc_snap_ins[si] = .{
                    .sink_input_id = st.id,
                    .volume_pct = st.volume_pct,
                    .muted = st.muted,
                    .app_name = if (st.app_name.len > 0) st.app_name else "Unknown App",
                };
                si += 1;
            }
            snap.in_streams = self.cc_snap_ins[0..si];
        } else {
            snap.out = .{ .volume_pct = 100, .device_name = "Default Sink" };
            snap.in = .{ .volume_pct = 100, .muted = true, .device_name = "Default Source" };
        }
        if (self.cc_media) |*q| {
            snap.media = .{
                .active = q.snap.have_player and (q.snap.title.len > 0 or q.snap.artist.len > 0),
                .title = q.snap.title,
                .artist = q.snap.artist,
                .playing = q.snap.playing,
                .can_go_previous = q.snap.can_go_previous,
                .can_go_next = q.snap.can_go_next,
                .can_play_pause = q.snap.can_play_pause,
            };
        }
        if (self.cc_wifi_err_len > 0) snap.wifi_error = self.cc_wifi_err[0..self.cc_wifi_err_len];
        if (self.wx_reading.available) {
            var n_days: usize = 0;
            const wdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
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
            snap.weather = .{
                .available = true,
                .location = self.wx_reading.placeName(),
                .temp = self.wx_reading.temp,
                .feels_like = self.wx_reading.feels_like,
                .humidity_pct = self.wx_reading.humidity_pct,
                .wind_kmh = self.wx_reading.wind_kmh,
                .visibility_m = self.wx_reading.visibility_m,
                .icon = self.wx_glyph[0..self.wx_glyph_len],
                .fahrenheit = self.wx_reading.fahrenheit,
                .forecast = self.cc_days[0..n_days],
            };
        }
        return snap;
    }

    fn showControlCenter(self: *Taskbar, slot_idx: usize) void {
        if (!self.cc_init) return;
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        self.closePopup();
        self.thumbsDismiss();
        self.closePear();
        self.closeWorldClock();
        const now_ms = nowMs();
        _ = self.pollCcLive(now_ms, true);
        const snap = self.buildCcSnapshot();
        const cfg = &self.app.loaded.cfg;
        const us = tb_slots.uiScale(cfg.taskbar.scale, cfg.dock.shell_ui_scale);
        const width: i32 = @max(200, @as(i32, @intFromFloat(@round(620.0 * us))));
        const cx: i32 = if (slot_idx < bar.xs.len) @intFromFloat(@round(bar.xs[slot_idx] + bar.ws[slot_idx] * 0.5)) else @divTrunc(bar.w, 2);
        const dock_w = bar.w;
        const out_w = bar.w;
        const origin_x = cc_position.layerOriginX(out_w, dock_w);
        const gap: i32 = @intFromFloat(@round(6.0 * us));
        const extra: i32 = @intFromFloat(@round(2.0 * us));
        const pos = cc_position.computeMargins(.{
            .anchor_x = cx,
            .popup_w = width,
            .popup_h = 0,
            .output_w = out_w,
            .layer_w = dock_w,
            .layer_origin_x = origin_x,
            .bottom_clearance = 0,
        });
        const margin_bottom = @max(0, bar.h + gap) + extra;
        const out_obj = if (@as(usize, @intCast(bar.output)) < self.app.bound.outputs.items.len)
            self.app.bound.outputs.items[@intCast(bar.output)].obj
        else
            null;
        const ok = self.cc.openControlCenter(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            out_obj,
            bar.w,
            bar.h,
            width,
            pos.margin_left + extra,
            margin_bottom,
            self.fitForOutput(bar.output),
            cfg,
            snap,
            now_ms,
        );
        if (!ok) {
            logz.log("control-center: present failed", .{});
            self.cc.reset();
            return;
        }
        if (!self.app.conn.flush()) logz.log("control-center: flush failed", .{});
    }

    fn closeCc(self: *Taskbar) void {
        if (!self.cc_init or !self.cc.open) return;
        self.open_origin = -1;
        self.cc.reset();
        if (!self.app.conn.flush()) logz.log("control-center: flush failed on close", .{});
    }

    fn ccRefresh(self: *Taskbar) void {
        if (!self.cc_init) return;
        self.cc.refresh();
        if (!self.app.conn.flush()) logz.log("control-center: flush failed after refresh", .{});
    }

    fn ccResize(self: *Taskbar, now_ms: u64) void {
        if (!self.cc_init) return;
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

    fn ccSettleResize(self: *Taskbar, now_ms: u64) void {
        if (!self.cc_init or !self.cc.open) return;
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

    fn runCcAction(self: *Taskbar, a: cc_host.Action) void {
        const gpa = self.app.gpa;
        const now_ms = nowMs();
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
                cc_apply.requestSink(now_ms, self.app.io, pct);
                self.cc.snap.out.volume_pct = pct;
                self.cc.snap.out.fill_t_override = t;
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
                if (self.cc_audio) |*q| q.snap.out.muted = muted;
                self.ccRefresh();
                self.repaint();
            },
            .toggle_input_mute => {
                const muted = !self.cc.snap.in.muted;
                if (!cc_live_audio.setSourceMute(self.app.io, muted)) logz.log("control-center: set-source-mute failed", .{});
                self.cc.snap.in.muted = muted;
                if (self.cc_audio) |*q| q.snap.in.muted = muted;
                self.ccRefresh();
            },
            .set_mixer_volume => |m| {
                const pct: i32 = @intFromFloat(@round(m.t * 100.0));
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
                            self.cc.promptPassword(ap.ssid);
                            self.ccResize(now_ms);
                            self.ccRefresh();
                        } else {
                            self.cc.cancelPassword();
                            cc_live_network.connectThread(self.app.io, ap.ssid, "");
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
                        } else if (d.paired) {
                            cc_live_bluetooth.deviceVerbThread(d.path, "Connect", q.snap.adapter_path);
                        } else {
                            cc_live_bluetooth.deviceVerbThread(d.path, "Pair", q.snap.adapter_path);
                        }
                    }
                }
            },
            .forget_bluetooth_row => |i| {
                if (self.cc_bt) |*q| {
                    if (i >= 0 and @as(usize, @intCast(i)) < q.device_list.items.len) {
                        const d = q.device_list.items[@intCast(i)];
                        if (cc_live_bluetooth.removeDevice(gpa, q.snap.adapter_path, d.path)) {
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

    fn releaseCc(self: *Taskbar) void {
        if (!self.cc_init) return;
        self.cc.release();
        self.ccRefresh();
    }

    fn onCcSurface(self: *Taskbar) bool {
        if (!self.cc_init or !self.cc.open) return false;
        const seat = self.app.bound.seat_obj orelse return false;
        if (seat.focus_surface == null) return false;
        if (self.cc.surface.wl_surface) |cs| {
            if (seat.focus_surface == cs) return true;
        }
        return false;
    }

    fn onCcConfigure(ctx: *anyopaque, w: u32, h: u32) void {
        _ = w;
        _ = h;
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        if (!self.cc_init) return;
        self.cc.configured(self.app.bound.shm);
        if (!self.app.conn.flush()) logz.log("control-center: flush failed after configure", .{});
    }

    fn onCcClosed(ctx: *anyopaque) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        if (!self.cc_init) return;
        self.cc.reset();
    }

    fn ccClick(self: *Taskbar) void {
        if (!self.cc_init) return;
        const seat = self.app.bound.seat_obj orelse return;
        const a = self.cc.press(seat.pointer_x, seat.pointer_y);
        self.runCcAction(a);
    }

    // -- pear center (dock parity) --------------------------------------

    /// Same live sources as the control center, mapped onto pear's own
    /// runtime struct (identical shape, separate type — the widgets share
    /// backends, never state).
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

    fn pollCcRuntime(self: *Taskbar) cc_slot.Runtime {
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

    /// Update the pear pill's runtime; true when its signature moved (the
    /// glyph count drives the slot width, so the bar has to re-measure).
    fn refreshPearRuntime(self: *Taskbar) bool {
        if (!self.pear_init) return false;
        const rt = pearRuntime(self.pollCcRuntime());
        self.pear_rt = rt;
        const cfg = &self.app.loaded.cfg;
        for (self.sections.all) |*s| {
            if (s.kind != .pear_center) continue;
            const pcfg = pear_slot.loadCfg(cfg, s.key);
            return pear_slot.signatureChanged(&self.pear_sig, pcfg, rt);
        }
        return false;
    }

    fn pearDragging(self: *Taskbar) bool {
        if (!self.pear_init) return false;
        return self.pear.dragging_vol or self.pear.dragging_in or self.pear.dragging_bri;
    }

    fn onPearSurface(self: *Taskbar) bool {
        if (!self.pear_init or !self.pear.open) return false;
        const seat = self.app.bound.seat_obj orelse return false;
        if (seat.focus_surface == null) return false;
        if (self.pear.surface.wl_surface) |ps| {
            if (seat.focus_surface == ps) return true;
        }
        return false;
    }

    fn closePear(self: *Taskbar) void {
        if (!self.pear_init or !self.pear.open) return;
        self.open_origin = -1;
        // A scan started by the bluetooth page must not outlive the popup,
        // and a reopen lands on the main page rather than a stale device
        // list.
        if (self.pear.state.bt_overlay) {
            if (self.cc_bt) |*q| cc_live_bluetooth.setDiscovery(self.app.gpa, q.snap.adapter_path, false);
            self.pear.state.bt_overlay = false;
        }
        self.pear.reset();
        if (!self.app.conn.flush()) logz.log("pear: flush failed on close", .{});
    }

    fn pearRefresh(self: *Taskbar) void {
        if (!self.pear_init) return;
        self.pear.refresh();
        if (!self.app.conn.flush()) logz.log("pear: flush failed after refresh", .{});
    }

    /// View flags behind one pear frame: config toggles + redeye + backlight.
    fn pearFlags(self: *Taskbar) pear_host.Host.Flags {
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
        const ch = chrome.of(cfg);
        const lum = 0.2126 * ch.dock_fill.r + 0.7152 * ch.dock_fill.g + 0.0722 * ch.dock_fill.b;
        return lum <= 0.4;
    }

    /// Rebuild the pear snapshot + layout + paint after a state change.
    fn refreshPearPopup(self: *Taskbar) void {
        const snap = self.buildCcSnapshot();
        self.pear.setSnapshot(snap);
        self.pear.setFlags(self.pearFlags());
        self.pear.relayout(self.pearUiScale(), self.pear_backlight.available());
        self.pearRefresh();
    }

    fn pearUiScale(self: *Taskbar) f64 {
        const cfg = &self.app.loaded.cfg;
        return tb_slots.uiScale(cfg.taskbar.scale, cfg.dock.shell_ui_scale);
    }

    /// Relayout + recreate the surface after a height change (overlay,
    /// device panels), then repaint.
    fn pearResize(self: *Taskbar, now_ms: u64) void {
        _ = now_ms;
        self.refreshPearPopup();
        if (!self.pear.place()) {
            logz.log("pear: resize failed, closing", .{});
            self.closePear();
        } else if (!self.app.conn.flush()) {
            logz.log("pear: flush failed after resize", .{});
        }
    }

    /// Open the pear popup above its slot. Same placement discipline as the
    /// control center (bottom|left + slot-anchored margins), at the compact
    /// 360 x combined-scale width.
    fn showPear(self: *Taskbar, idx: usize) void {
        if (!self.pear_init or idx >= self.sections.all.len) return;
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        self.closePopup();
        self.thumbsDismiss();
        self.closeCc();
        self.closeWorldClock();
        const now_ms = nowMs();
        _ = self.pollCcLive(now_ms, true);
        self.pear_backlight.scan(self.app.gpa, self.app.io);
        const slot = &self.sections.all[idx];
        const pcfg = pear_config.load(&self.app.loaded.cfg, slot.key);
        const us = @max(0.5, self.pearUiScale() * pear_config.scaleOf(pcfg));
        const width: i32 = @max(200, @as(i32, @intFromFloat(@round(360.0 * us))));
        const snap = self.buildCcSnapshot();
        const cx: i32 = if (idx < bar.xs.len) @intFromFloat(@round(bar.xs[idx] + bar.ws[idx] * 0.5)) else @divTrunc(bar.w, 2);
        const dock_w = bar.w;
        const out_w = bar.w;
        const origin_x = cc_position.layerOriginX(out_w, dock_w);
        const gap: i32 = @intFromFloat(@round(6.0 * us));
        const extra: i32 = @intFromFloat(@round(2.0 * us));
        const pos = cc_position.computeMargins(.{
            .anchor_x = cx,
            .popup_w = width,
            .popup_h = 0,
            .output_w = out_w,
            .layer_w = dock_w,
            .layer_origin_x = origin_x,
            .bottom_clearance = 0,
        });
        const margin_bottom = @max(0, bar.h + gap) + extra;
        const out_obj = if (@as(usize, @intCast(bar.output)) < self.app.bound.outputs.items.len)
            self.app.bound.outputs.items[@intCast(bar.output)].obj
        else
            null;
        const ok = self.pear.openPear(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            out_obj,
            bar.w,
            bar.h,
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

    fn pearClick(self: *Taskbar) void {
        if (!self.pear_init) return;
        const seat = self.app.bound.seat_obj orelse return;
        const a = self.pear.press(seat.pointer_x, seat.pointer_y);
        self.runPearAction(a);
    }

    fn releasePear(self: *Taskbar) void {
        if (!self.pear_init) return;
        self.pear.release();
        self.pearRefresh();
    }

    fn onPearConfigure(ctx: *anyopaque, w: u32, h: u32) void {
        _ = w;
        _ = h;
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        if (!self.pear_init) return;
        self.pear.configured(self.app.bound.shm);
        if (!self.app.conn.flush()) logz.log("pear: flush failed after configure", .{});
    }

    fn onPearClosed(ctx: *anyopaque) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        if (!self.pear_init) return;
        self.pear.reset();
    }

    /// Fire-and-forget `sh -c` spawn for pear commands (device link, cmd
    /// buttons, custom camera command). Tracked for reaping via
    /// `autostart.spawnDetached`.
    fn spawnShell(self: *Taskbar, cmd: []const u8) void {
        if (cmd.len == 0) return;
        autostart.spawnDetached(self.app.io, &.{ "sh", "-c", cmd }) catch {
            logz.log("pear: spawn failed '{s}'", .{cmd});
            return;
        };
        logz.log("pear: spawned '{s}'", .{cmd});
    }

    /// Apply one pear action — the dock's pear switch on this bar's live
    /// stack. Volume/input/device/media/wifi/bt write through to the same
    /// backends the control center uses; toggles flip persisted config keys
    /// (with an instant reload so the paint follows without waiting for
    /// inotify).
    fn runPearAction(self: *Taskbar, a: pear_host.Action) void {
        const gpa = self.app.gpa;
        const now_ms = nowMs();
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
                // Scanning starts with the page, as in the control center's
                // bluetooth section.
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
                if (!self.focusExisting(settings_app_id)) {
                    if (!self.launchSibling("horizon-settings")) self.launchSlot(settings_app_id);
                }
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
                    // Zig screenshot mode is unimplemented; there is nothing
                    // to run when no command is configured.
                    logz.log("pear: camera has no command configured", .{});
                }
            },
            .toggle_redeye => {
                const on = !self.redeye_on;
                self.redeye_on = on;
                if (self.bars.items.len > 0) {
                    self.redeye_inhibit.setInhibited(self.bars.items[0].surface.wl_surface, on);
                }
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

    // -- autohide -----------------------------------------------------

    fn applyAutohide(self: *Taskbar) void {
        const cfg = &self.app.loaded.cfg;
        const h = self.barHeight();
        for (self.bars.items) |*b| {
            if (!cfg.taskbar.auto_hide) {
                b.surface.setExclusiveZone(h + cfg.taskbar.exclusive_zone_gap);
            } else if (self.reveal) {
                b.surface.setExclusiveZone(h + cfg.taskbar.exclusive_zone_gap);
            } else {
                b.surface.setExclusiveZone(0);
            }
            b.surface.commit();
        }
        _ = self.app.conn.flush();
    }

    // -- live backends (battery/media/bt/vpn/mixer, dock parity) --------

    fn pollBattery(self: *Taskbar, now_ms: u64) bool {
        if (now_ms < self.bat_next_ms) return false;
        self.bat_next_ms = now_ms + 5000;
        const r = cc_live_upower.query(self.app.gpa);
        const changed = !std.meta.eql(self.bat_reading, r);
        self.bat_reading = r;
        battery_paint.state = .{
            .percentage = r.percentage,
            .state = battery_paint.BatteryState.fromRaw(r.state),
            .is_present = r.is_present,
            .on_battery = r.on_battery,
        };
        return changed;
    }

    /// Battery slot width follows the live reading (bare glyph vs glyph +
    /// `NN%`), mirroring the dock's re-measure.
    fn batteryWidth(self: *Taskbar, icon: f64, ui: f64) f64 {
        const cfg = &self.app.loaded.cfg;
        const show_pct = dw.settingBool(cfg, "battery", "show_percent", true);
        if (!show_pct) return icon + 4.0 * ui;
        if (!self.bat_reading.is_present) return icon + 4.0 * ui;
        const us = ui;
        const pad_x = 6.0 * us;
        const gap = 6.0 * us;
        const text_w = self.measureLabel("100%", 12.0 * ui);
        const min_w = @max(icon * 1.25, 40.0 * us);
        return @max(min_w, icon + gap + text_w + pad_x * 2.0);
    }

    fn weatherSlotKey(self: *Taskbar) ?[]const u8 {
        for (self.sections.all) |*sl| {
            if (sl.kind == .weather) return sl.key;
        }
        return null;
    }

    fn weatherRequest(self: *Taskbar) weather_svc.Request {
        const cfg = &self.app.loaded.cfg;
        const id = self.weatherSlotKey() orelse return .{};
        const unit = wset.widgetSetting(cfg, id, "weather_unit");
        return .{
            .lat = wset.widgetSetting(cfg, id, "weather_lat"),
            .lon = wset.widgetSetting(cfg, id, "weather_lon"),
            .city = wset.widgetSetting(cfg, id, "weather_city"),
            .fahrenheit = unit.len > 0 and (unit[0] == 'f' or unit[0] == 'F'),
        };
    }

    fn applyWeather(self: *Taskbar, rd: *const weather_svc.Reading) void {
        const n = @min(rd.glyph.len, self.wx_glyph.len);
        if (n > 0) @memcpy(self.wx_glyph[0..n], rd.glyph[0..n]);
        self.wx_glyph_len = @intCast(n);
        wpaint.state = .{
            .available = true,
            .temp = rd.temp,
            .fahrenheit = rd.fahrenheit,
            .icon = self.wx_glyph[0..self.wx_glyph_len],
        };
        self.wx_reading = rd.*;
    }

    fn pollWeather(self: *Taskbar, now_ms: u64) bool {
        const now_i: i64 = @intCast(now_ms);
        var rd: weather_svc.Reading = .{};
        if (weather_svc.take(&rd)) {
            if (rd.available) {
                self.applyWeather(&rd);
                self.wx_next_ms = now_i + 15 * 60 * 1000;
                logz.log("weather: {d}° {s}", .{ rd.temp, rd.glyph });
            } else {
                self.wx_next_ms = now_i + 60 * 1000;
            }
            if (self.weatherSlotKey() == null) return false;
            return rd.available;
        }
        if (self.weatherSlotKey() == null) return false;
        if (now_i < self.wx_next_ms) return false;
        if (weather_svc.request(self.app.gpa, self.app.io, self.weatherRequest())) {
            self.wx_next_ms = now_i + 15 * 60 * 1000;
        } else {
            self.wx_next_ms = now_i + 60 * 1000;
        }
        return false;
    }

    fn pollMedia(self: *Taskbar, now_ms: u64) bool {
        if (!self.media_init) return false;
        if (now_ms < self.media_next_ms) return false;
        self.media_next_ms = now_ms + 400;
        const changed = self.media.poll();
        self.pushMprisTrack();
        // A cover landing changes the pill's disc, not the snapshot: the
        // strip has to repaint for it.
        const art = self.stepCoverArt();
        return changed or art;
    }

    fn mediaTrackId(self: *Taskbar) []const u8 {
        const snap = self.media.snap;
        return if (snap.track_id.len > 0) snap.track_id else snap.title;
    }

    fn pushMprisTrack(self: *Taskbar) void {
        if (!self.notif_init) return;
        const snap = self.media.snap;
        if (!snap.have_player or snap.title.len == 0) return;
        const gpa = self.app.gpa;
        const key = notify_push.trackKey(gpa, snap.bus_name, snap.title, snap.artist) catch return;
        defer gpa.free(key);
        if (self.notif_last_key.len > 0 and std.mem.eql(u8, self.notif_last_key, key)) return;
        if (self.notif_last_key.len > 0) gpa.free(self.notif_last_key);
        self.notif_last_key = gpa.dupe(u8, key) catch &.{};
        _ = self.notif_push.pushMpris(
            @as(i64, @intCast(nowMs())),
            getenvStr("EH_IPC_SOCKET"),
            getenvStr("XDG_RUNTIME_DIR"),
            key,
            snap.title,
            snap.artist,
        );
    }

    /// Ask for this track's cover; take delivery of finished ones. The budget
    /// belongs to the track (same URL on the next track retries). Mirrors the
    /// dock: ask only while the current source has nothing on screen, and
    /// drop an answer whose URL no longer matches — the player can move on
    /// while the fetch is still running.
    fn stepCoverArt(self: *Taskbar) bool {
        const gpa = self.app.gpa;
        const snap = self.media.snap;
        const id = self.mediaTrackId();
        if (self.media_art_track.len == 0 or !std.mem.eql(u8, self.media_art_track, id)) {
            if (self.media_art_track.len > 0) gpa.free(self.media_art_track);
            self.media_art_track = gpa.dupe(u8, id) catch &.{};
            if (self.media_art_pixels.len > 0) gpa.free(self.media_art_pixels);
            self.media_art_pixels = &.{};
            if (self.media_art_src.len > 0) gpa.free(self.media_art_src);
            self.media_art_src = &.{};
            self.media_art_misses = 0;
            self.media_art_retry_ms = 0;
        }
        if (id.len == 0) return false;
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
        // A source not consulted yet: a cover decoded before — this session
        // or a stored one — is on disk as pixels, so find it before the
        // worker is bothered. One look per source; a miss goes to the
        // worker and its budget instead of re-reading on every tick.
        const fresh_src = want.len > 0 and
            (self.media_art_src.len == 0 or !std.mem.eql(u8, self.media_art_src, want));
        if (fresh_src) {
            if (self.media_art_src.len > 0) gpa.free(self.media_art_src);
            self.media_art_src = &.{};
            if (cover_cache.find(gpa, self.app.io, want)) |cv| {
                if (self.media_art_pixels.len > 0) gpa.free(self.media_art_pixels);
                self.media_art_pixels = cv.pixels;
                self.media_art_w = cv.w;
                self.media_art_h = cv.h;
                self.media_art_misses = 0;
                self.media_art_retry_ms = 0;
                self.pushMprisArt();
                self.syncMediaPopup();
                return true;
            }
            self.media_art_src = gpa.dupe(u8, want) catch &.{};
        }
        if (want.len > 0 and self.media_art_pixels.len == 0 and
            self.media_art_misses < 6 and nowMs() >= self.media_art_retry_ms)
        {
            // The worker refuses while busy; the next tick asks again. No
            // backoff is latched on a refusal — only on a produced nothing.
            _ = cover_worker.request(gpa, self.app.io, want);
        }
        var res: cover_worker.Result = .{};
        if (!cover_worker.take(&res)) return false;
        defer res.deinit(gpa);
        const got = res.url orelse "";
        if (!std.mem.eql(u8, got, want)) return false;
        if (!res.cover.present()) {
            self.media_art_misses += 1;
            self.media_art_retry_ms = nowMs() + 2000 * @as(u64, @intCast(@min(self.media_art_misses, 5)));
            return false;
        }
        self.media_art_misses = 0;
        self.media_art_retry_ms = 0;
        if (self.media_art_pixels.len > 0) gpa.free(self.media_art_pixels);
        self.media_art_pixels = gpa.dupe(u8, res.cover.pixels) catch &.{};
        self.media_art_w = res.cover.w;
        self.media_art_h = res.cover.h;
        self.pushMprisArt();
        self.syncMediaPopup();
        return true;
    }

    fn pushMprisArt(self: *Taskbar) void {
        if (!self.notif_init or self.media_art_pixels.len == 0) return;
        const snap = self.media.snap;
        if (!snap.have_player or snap.title.len == 0) return;
        const gpa = self.app.gpa;
        const key = notify_push.trackKey(gpa, snap.bus_name, snap.title, snap.artist) catch return;
        defer gpa.free(key);
        _ = self.notif_push.pushMprisArt(
            @as(i64, @intCast(nowMs())),
            getenvStr("EH_IPC_SOCKET"),
            getenvStr("XDG_RUNTIME_DIR"),
            key,
            self.media_art_pixels,
            self.media_art_w,
            self.media_art_h,
        );
    }

    fn ownText(buf: []u8, src: []const u8) []const u8 {
        var n = @min(src.len, buf.len);
        if (n < src.len) {
            while (n > 0) {
                if ((src[n] & 0xC0) != 0x80) break;
                n -= 1;
            }
        }
        @memcpy(buf[0..n], src[0..n]);
        return buf[0..n];
    }

    fn syncMediaPopup(self: *Taskbar) void {
        if (!self.media_init) return;
        if (!self.popup_init or self.popup.kind != .media_player) return;
        const snap = self.media.snap;
        self.popup.media = .{
            .active = snap.realActive(),
            .art = if (self.media_art_pixels.len > 0) .{ .pixels = self.media_art_pixels, .w = self.media_art_w, .h = self.media_art_h } else null,
            .title = ownText(&self.media_title_buf, snap.title),
            .artist = ownText(&self.media_artist_buf, snap.artist),
            .position_us = self.media_pos.project(snap, @as(i64, @intCast(anim_mod.monotonicNs()))),
            .duration_us = snap.duration_us,
            .playing = snap.playing(),
            .can_play = snap.can_play,
            .can_pause = snap.can_pause,
            .can_prev = snap.can_go_previous,
            .can_next = snap.can_go_next,
            .shuffle = snap.shuffle,
            .loop_status = ownText(&self.media_loop_buf, snap.loop_status),
            .t_sec = @as(f64, @floatFromInt(anim_mod.monotonicNs())) / 1e9,
            .hover = self.popup.media_hover,
        };
    }

    fn runMediaPopupClick(self: *Taskbar) bool {
        if (!self.media_init) return false;
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
                _ = self.media.seek(@as(i64, @intCast(@as(u64, @intFromFloat(self.popup.media_seek_frac * @as(f64, @floatFromInt(@max(1, self.popup.media.duration_us))))))));
            },
            .dismiss => return false,
            else => {},
        }
        self.syncMediaPopup();
        self.popupRefresh();
        return true;
    }

    fn adoptVpnRows(self: *Taskbar, rows: []cc_live_vpn.Connection) bool {
        const gpa = self.app.gpa;
        const out = gpa.alloc(vpn_popup.Connection, rows.len) catch {
            cc_live_vpn.freeConnections(gpa, rows);
            return false;
        };
        for (rows, 0..) |r, i| out[i] = .{ .uuid = r.uuid, .name = r.name, .active = r.active };
        gpa.free(rows);
        var changed = out.len != self.vpn_conns.len;
        if (!changed) {
            for (out, self.vpn_conns) |a, b| {
                if (a.active != b.active or !std.mem.eql(u8, a.uuid, b.uuid) or !std.mem.eql(u8, a.name, b.name)) {
                    changed = true;
                    break;
                }
            }
        }
        self.freeVpnConns();
        self.vpn_conns = out;
        self.vpn_store.syncEntries(self.vpn_conns, vpn_popup.monotonicNs()) catch {};
        if (self.popup_init and self.popup.kind == .vpn) {
            self.popup.vpn_conns = self.vpn_conns;
        }
        return changed;
    }

    fn takeVpnRows(self: *Taskbar) bool {
        var rows: ?[]cc_live_vpn.Connection = null;
        if (!cc_live_vpn.take(&rows)) return false;
        return self.adoptVpnRows(rows.?);
    }

    fn hasVpnSlot(self: *Taskbar) bool {
        for (self.sections.all) |*s| {
            if (s.kind == .vpn) return true;
        }
        return false;
    }

    fn pollVpn(self: *Taskbar, now_ms: u64) void {
        if (!self.hasVpnSlot()) return;
        if (now_ms < self.vpn_next_ms) return;
        const open = self.popup_init and self.popup.kind == .vpn;
        if (!cc_live_vpn.request(self.app.gpa, self.app.io)) {
            if (!cc_live_vpn.idle()) return;
            self.vpn_next_ms = now_ms + 5000;
            return;
        }
        self.vpn_next_ms = now_ms + (if (open) @as(u64, 2000) else @as(u64, 30000));
    }

    fn openVpnCard(self: *Taskbar, idx: usize, cx: i32) void {
        if (!self.popup_init) return;
        self.closeWorldClock();
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        self.popup.reset();
        self.popup.widget_cfg = &self.app.loaded.cfg;
        self.popup.vpn_store = &self.vpn_store;
        self.popup.vpn_conns = self.vpn_conns;
        const ok = self.popup.openVpn(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            bar.w,
            bar.h,
            cx,
            self.vpn_store.count(),
            self.fitForOutput(bar.output),
        );
        if (!ok) {
            self.popup.reset();
            return;
        }
        self.popup_slot = @intCast(idx);
        self.vpn_card_slot = @intCast(idx);
        if (!self.app.conn.flush()) logz.log("vpn card: flush failed", .{});
    }

    fn settleWidgetCard(self: *Taskbar) bool {
        const cfg = &self.app.loaded.cfg;
        if (!self.popup_init) return false;
        if (self.popup.kind == .bluetooth) {
            if (self.bt_card_slot < 0) return false;
            const want: i32 = @intFromFloat(@round(bt_paint.popupHeight(self.app.gpa, cfg, &self.bt_snap, self.bt_devs) catch return false));
            if (want == self.popup.card_h) return false;
            const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return false;
            const cx = self.slotCentreX(bar, @intCast(self.bt_card_slot)) orelse return false;
            self.popup.reset();
            self.popup.widget_cfg = cfg;
            self.popup.bt_snap = self.bt_snap;
            self.popup.bt_devs = self.bt_devs;
            if (!self.popup.openBluetooth(self.app.bound.compositor, self.app.bound.layer_shell, bar.w, bar.h, cx, cfg, &self.bt_snap, self.bt_devs, self.fitForOutput(bar.output))) {
                self.popup.reset();
                return false;
            }
            if (!self.app.conn.flush()) logz.log("bluetooth card: flush failed", .{});
            return true;
        }
        if (self.popup.kind == .vpn) {
            if (self.vpn_card_slot < 0) return false;
            const want: i32 = @intFromFloat(@round(vpn_popup.heightFor(self.vpn_store.count())));
            if (want == self.popup.card_h) return false;
            const cx = self.popup.card_cx;
            const idx: usize = @intCast(self.vpn_card_slot);
            self.openVpnCard(idx, cx);
            return true;
        }
        return false;
    }

    fn pushMixerToCard(self: *Taskbar) void {
        if (!self.popup_init or self.popup.kind != .volume_mixer) return;
        const d = self.mx_data orelse return;
        self.popup.mx_snap = &d.snap;
        self.popup.mx_cards = d.cards;
        self.popup.mx_engine = d.engine;
        self.popup.mx_top = d.top;
    }

    fn takeMixer(self: *Taskbar, now_ms: u64) bool {
        var d: ?*cc_live_mixer.Data = null;
        if (!cc_live_mixer.take(&d)) return false;
        const data = d.?;
        if (self.popup_init and self.popup.kind == .volume_mixer and
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

    fn pollMixer(self: *Taskbar, now_ms: u64) void {
        if (!self.popup_init or self.popup.kind != .volume_mixer) return;
        if (now_ms < self.mx_next_ms) return;
        if (self.popup.mx_ui.drag_active or now_ms < self.mx_hold_ms) return;
        if (!cc_live_mixer.request(self.app.gpa, self.app.io)) {
            if (!cc_live_mixer.idle()) return;
            self.mx_next_ms = now_ms + 3000;
            return;
        }
        self.mx_next_ms = now_ms + 1000;
    }

    const MixerNode = struct {
        raw: []const u8 = "",
        id: u32 = 0,
        is_stream: bool = false,
        is_input: bool = false,
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
        for (snap.out_streams) |st| {
            if (st.node_id == node_id) return .{ .id = st.node_id, .is_stream = true };
        }
        for (snap.in_streams) |st| {
            if (st.node_id == node_id) return .{ .id = st.node_id, .is_stream = true, .is_input = true };
        }
        return .{};
    }

    fn runMixerEffect(self: *Taskbar, e: mixer_card.Effect) bool {
        const io = self.app.io;
        const d = self.mx_data orelse return false;
        switch (e.verb) {
            .none => return false,
            .launch_settings => return self.launchSibling("horizon-settings"),
            .apply_card_profile => {
                if (e.card_index >= d.cards.len) return false;
                const card = d.cards[e.card_index];
                const force_off = cc_live_audio.isBluetoothCard(card.card_key) and
                    cc_live_audio.isVendorCodecProfile(e.profile_key);
                const ok = cc_live_audio.setCardProfile(io, e.card_index, e.profile_key, force_off);
                if (ok) self.mx_hold_ms = nowMs() + 1200;
                return ok;
            },
            else => {},
        }
        const n = mixerNode(d, e.node_id);
        if (n.id == 0) return false;
        const sid: i32 = @intCast(n.id);
        const ok = switch (e.verb) {
            .set_volume => blk: {
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
        if (ok and e.verb != .none) self.mx_hold_ms = nowMs() + 1200;
        return ok;
    }

    fn launchSibling(self: *Taskbar, name: []const u8) bool {
        const gpa = self.app.gpa;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.readLinkAbsolute(self.app.io, "/proc/self/exe", &buf) catch return false;
        const dir = std.fs.path.dirname(buf[0..n]) orelse return false;
        const exe = std.fs.path.join(gpa, &.{ dir, name }) catch return false;
        defer gpa.free(exe);
        if (!app_launch.launchPath(self.app.io, exe)) return false;
        logz.log("activate: spawned sibling '{s}'", .{exe});
        return true;
    }

    fn mixerLocal(self: *Taskbar) struct { x: f64, y: f64 } {
        const seat = self.app.bound.seat_obj orelse return .{ .x = 0, .y = 0 };
        // Same transform as the popup's own `cardLocal`: the card draws inside
        // a `cairo_scale(fit)` frame centred on `card_cx`, so the wheel/drag
        // position has to be re-read in natural card coordinates too.
        const fit = self.popup.fit;
        const left: f64 = @as(f64, @floatFromInt(self.popup.card_cx)) - mixer_card.popup_w * fit * 0.5;
        return .{ .x = (seat.pointer_x - left) / fit, .y = seat.pointer_y / fit };
    }

    fn mixerDragMotion(self: *Taskbar) bool {
        if (!self.popup_init) return false;
        const ui = &self.popup.mx_ui;
        if (!ui.drag_active) return false;
        const gpa = self.app.gpa;
        const loc = self.mixerLocal();
        const now = nowMs();
        var lay = mixer_card.computeLayout(gpa, self.popup.mx_snap, self.popup.mx_cards, ui.view_output, ui.router_stream, ui.master_picker, ui.scroll_px) catch return true;
        defer mixer_card.freeLayout(gpa, &lay);
        var hold: i64 = 0;
        if (mixer_card.motionAt(ui, self.popup.mx_snap, &lay, loc.x, loc.y, @intCast(now), &hold)) |eff| {
            _ = self.runMixerEffect(eff);
            self.mx_hold_ms = now + 1200;
        }
        if (hold > 0) self.mx_hold_ms = @max(self.mx_hold_ms, @as(u64, @intCast(hold)));
        if (self.dragFrameDue(now)) self.popupRefresh();
        return true;
    }

    fn mixerRelease(self: *Taskbar) bool {
        if (!self.popup_init or self.popup.kind != .volume_mixer) return false;
        if (!self.popup.mx_ui.drag_active) return false;
        const loc = self.mixerLocal();
        if (mixer_card.releaseAt(&self.popup.mx_ui, loc.x)) |eff| {
            _ = self.runMixerEffect(eff);
            self.mx_hold_ms = nowMs() + 1200;
        }
        self.mx_next_ms = self.mx_hold_ms;
        self.popupRefresh();
        return true;
    }

    fn mixerAxis(self: *Taskbar, delta: f64) bool {
        if (!self.popup_init or self.popup.kind != .volume_mixer) return false;
        const gpa = self.app.gpa;
        const ui = &self.popup.mx_ui;
        const loc = self.mixerLocal();
        var lay = mixer_card.computeLayout(gpa, self.popup.mx_snap, self.popup.mx_cards, ui.view_output, ui.router_stream, ui.master_picker, ui.scroll_px) catch return false;
        defer mixer_card.freeLayout(gpa, &lay);
        const h = mixer_card.hitTest(&lay, self.popup.mx_snap, loc.x, loc.y);
        const out = mixer_card.axisAt(ui, self.popup.mx_snap, &lay, h, loc.x, loc.y, delta);
        if (out.effect.verb != .none) {
            _ = self.runMixerEffect(out.effect);
            self.mx_hold_ms = nowMs() + 1200;
        }
        if (out.consumed) self.popupRefresh();
        return out.consumed;
    }

    fn runVolumeMixerPopupClick(self: *Taskbar) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const x: i32 = @intFromFloat(@round(seat.pointer_x));
        const y: i32 = @intFromFloat(@round(seat.pointer_y));
        switch (self.popup.cardClick(x, y)) {
            .dismiss => return false,
            .volume_mixer => {},
            else => return true,
        }
        const out = self.popup.mx_click;
        _ = self.runMixerEffect(out.effect);
        self.popupRefresh();
        return true;
    }

    // -- widget cards (dock parity: live data in, verbs out) ---------------

    fn showBluetoothCard(self: *Taskbar, idx: usize, cx: i32) void {
        if (!self.popup_init) return;
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        const cfg = &self.app.loaded.cfg;
        _ = self.takeVpnRows();
        _ = self.pollCcLive(nowMs(), false);
        self.closeWorldClock();
        self.popup.reset();
        self.popup.widget_cfg = cfg;
        self.popup.bt_snap = self.bt_snap;
        self.popup.bt_devs = self.bt_devs;
        const ok = self.popup.openBluetooth(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            bar.w,
            bar.h,
            cx,
            cfg,
            &self.bt_snap,
            self.bt_devs,
            self.fitForOutput(bar.output),
        );
        if (!ok) {
            self.popup.reset();
            return;
        }
        self.popup_slot = @intCast(idx);
        self.bt_card_slot = @intCast(idx);
        if (!self.app.conn.flush()) logz.log("bluetooth card: flush failed", .{});
    }

    fn runBluetoothPopupClick(self: *Taskbar) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const x: i32 = @intFromFloat(@round(seat.pointer_x));
        const y: i32 = @intFromFloat(@round(seat.pointer_y));
        switch (self.popup.cardClick(x, y)) {
            .dismiss => return false,
            .bluetooth => {},
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

    fn showVpn(self: *Taskbar, idx: usize) void {
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        const cx = self.slotCentreX(bar, idx) orelse return;
        _ = self.takeVpnRows();
        self.openVpnCard(idx, cx);
        self.vpn_next_ms = 0;
        self.pollVpn(nowMs());
    }

    fn runVpnPopupClick(self: *Taskbar) bool {
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
        self.vpn_next_ms = 0;
        self.pollVpn(nowMs());
        return true;
    }

    fn runLayoutPopupClick(self: *Taskbar) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        const x: i32 = @intFromFloat(@round(seat.pointer_x));
        const y: i32 = @intFromFloat(@round(seat.pointer_y));
        return switch (self.popup.cardClick(x, y)) {
            .dismiss => false,
            else => true,
        };
    }

    fn showVolumeMixer(self: *Taskbar, idx: usize) void {
        if (!self.popup_init) return;
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        const cx = self.slotCentreX(bar, idx) orelse return;
        self.closeWorldClock();
        self.popup.reset();
        self.popup.widget_cfg = &self.app.loaded.cfg;
        self.popup.mx_icons = .{ .ctx = self, .get = mxIconSurf };
        const ok = self.popup.openVolumeMixer(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            bar.w,
            bar.h,
            cx,
            self.fitForOutput(bar.output),
        );
        if (!ok) {
            self.popup.reset();
            return;
        }
        self.pushMixerToCard();
        self.popup_slot = @intCast(idx);
        self.mx_next_ms = nowMs();
        self.pollMixer(nowMs());
        if (!self.app.conn.flush()) logz.log("volume_mixer card: flush failed", .{});
    }

    fn showMediaPlayer(self: *Taskbar, idx: usize) void {
        if (!self.popup_init or !self.media_init) return;
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        const cx = self.slotCentreX(bar, idx) orelse return;
        self.closeWorldClock();
        self.popup.reset();
        // The media card reads the widget-card scale off the config, like the
        // other widget popups, so push this frame's config before opening.
        self.popup.widget_cfg = &self.app.loaded.cfg;
        const ok = self.popup.openMediaPlayer(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            bar.w,
            bar.h,
            cx,
            chrome.of(&self.app.loaded.cfg),
            self.fitForOutput(bar.output),
        );
        if (!ok) {
            self.popup.reset();
            return;
        }
        self.popup_slot = @intCast(idx);
        self.syncMediaPopup();
        self.armAnim();
        if (!self.app.conn.flush()) logz.log("media card: flush failed", .{});
    }

    // -- app drawer (full launcher grid, dock parity) ----------------------

    fn refreshLauncherIcons(self: *Taskbar) void {
        const gpa = self.app.gpa;
        const cfg = &self.app.loaded.cfg;
        const theme: []const u8 = if (cfg.taskbar.icon_theme.len > 0)
            cfg.taskbar.icon_theme
        else if (cfg.dock.icon_theme.len > 0)
            cfg.dock.icon_theme
        else
            eh.icon_themes.detectSystemIconTheme(self.app.io) orelse "hicolor";
        const home = getenvStr("XDG_DATA_HOME");
        const dirs_env = getenvStr("XDG_DATA_DIRS");
        if (self.launcher_theme) |last| {
            if (std.mem.eql(u8, last, theme) and sameOptStr(self.launcher_home, home) and sameOptStr(self.launcher_dirs_env, dirs_env)) {
                return;
            }
        }
        const dirs = eh.icon_lookup.dataDirs(gpa, home, getenvStr("HOME"), dirs_env) catch return;
        self.launcher.res.icons.setPath(dirs, theme);
        if (self.launcher_theme) |last| gpa.free(last);
        self.launcher_theme = gpa.dupe(u8, theme) catch null;
        self.launcher_home = home;
        self.launcher_dirs_env = dirs_env;
    }

    fn sameOptStr(a: ?[]const u8, b: ?[]const u8) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return x.ptr == y.ptr and x.len == y.len;
    }

    /// The App-menu widget's face for the launcher: the App menu's own rail
    /// panel — the categories down a 52 px rail, one 38 px row per app and the
    /// highlighted app's description along the bottom.
    fn showLauncherList(self: *Taskbar, idx: usize) void {
        self.showLauncher(idx, .rail);
    }

    fn showLauncher(self: *Taskbar, idx: usize, style: launcher_menu.Style) void {
        if (!self.popup_init or !self.launcher_init) return;
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        self.popup.reset();
        self.closeCc();
        self.closeWorldClock();
        self.launcher.setColors(chrome.of(&self.app.loaded.cfg));
        // Fresh on every open, like the dock's drawer: the view mode from
        // the launcher settings and the nightlight state for the footer. The
        // rail is list-only, so the mode only reaches the reference panel.
        self.launcher.setStyle(style);
        if (style == .classic) {
            self.launcher.setListMode(self.app.loaded.cfg.appearance.launchpad_view_mode == 1);
        }
        self.launcher.setNight(self.app.loaded.cfg.night_light.enabled);
        self.refreshLauncherIcons();
        self.launcher.open();
        const layer_w: f64 = @floatFromInt(@max(1, bar.w));
        const centre: i32 = self.slotCentreX(bar, idx) orelse @divTrunc(@as(i32, @intFromFloat(layer_w)), 2);
        const out_obj = if (@as(usize, @intCast(bar.output)) < self.app.bound.outputs.items.len)
            self.app.bound.outputs.items[@intCast(bar.output)].obj
        else
            null;
        const placed = self.popup.openLauncher(
            self.app.bound.compositor,
            self.app.bound.layer_shell,
            out_obj,
            .{
                .anchor_x = @floatFromInt(centre),
                .layer_w = layer_w,
                .layer_origin_x = 0,
                .output_w = layer_w,
                .dock_h = bar.h,
            },
            &self.launcher,
            // The drawer's own slider is the whole knob (see the dock).
            overlay_m.scale(&self.app.loaded.cfg.appearance, .app_drawer),
            // The output's fit factor, same as the dock's drawer.
            self.fitForOutput(bar.output),
        );
        if (placed == null) {
            logz.log("launcher: present failed", .{});
            self.popup.reset();
            return;
        }
        self.popup_slot = @intCast(idx);
        self.armAnim();
        if (!self.app.conn.flush()) logz.log("launcher: flush failed", .{});
    }

    fn closeLauncher(self: *Taskbar) void {
        if (!self.launcher_init) return;
        self.launcher.reset();
    }

    fn applyLauncher(self: *Taskbar, d: launcher_menu.Decision) void {
        switch (d.op) {
            .none => {},
            .close => {
                self.closeLauncher();
                self.closePopup();
            },
            .launch => {
                if (self.launcher.hitEntry(d.hit)) |e| {
                    logz.log("launcher: launching '{s}'", .{e.name});
                    if (!app_launch.launchExec(self.app.gpa, self.app.io, e.exec)) {
                        logz.err("launcher: could not start '{s}'", .{e.name});
                    }
                }
                self.closeLauncher();
                self.closePopup();
            },
            .launch_keep => {
                // `Ctrl+Enter`: start it and leave the panel up, with the
                // model's own "Opening …" note in the footer.
                if (self.launcher.hitEntry(d.hit)) |e| {
                    logz.log("launcher: launching '{s}'", .{e.name});
                    if (!app_launch.launchExec(self.app.gpa, self.app.io, e.exec)) {
                        logz.err("launcher: could not start '{s}'", .{e.name});
                    }
                }
                self.popupRefresh();
            },
            .run_power => {
                self.closeLauncher();
                self.closePopup();
                launcher_menu.Menu.runPower(self.app.io, d.hit);
            },
            .toggle_night => {
                // Same key the pear tile writes; the supervisor's gamma
                // client is what warms the display.
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
                if (self.launcher.hitEntry(d.hit)) |e| {
                    self.togglePin(e.id);
                }
                self.popupRefresh();
            },
            .reload_shell => {
                // The settings app's own "config changed" path, with the one
                // promise this panel adds: it stays up across the reload so
                // the note underneath is read where it was written.
                self.reload_keep_popup = true;
                const ok = self.app.reload();
                self.reload_keep_popup = false;
                if (!ok) logz.log("launcher: reload deferred", .{});
                self.launcher.note("Shell reloaded");
                self.popupRefresh();
            },
            .toggle_theme => {
                // The pear tile's own switch: write `matugen_mode` and let
                // the reload hand the new palette to every surface. The panel
                // takes the new chrome colours rather than being rebuilt.
                const dark = !std.ascii.eqlIgnoreCase(self.app.loaded.cfg.appearance.matugen_mode, "dark");
                const gpa = self.app.gpa;
                const st = config.settingsDir(gpa, self.app.xdg_config, self.app.home) catch "";
                defer if (st.len > 0) gpa.free(st);
                if (st.len > 0 and pear_prefs.setThemeMode(gpa, self.app.io, st, dark)) {
                    self.reload_keep_popup = true;
                    const ok = self.app.reload();
                    self.reload_keep_popup = false;
                    if (!ok) logz.log("launcher: theme saved, reload deferred", .{});
                    self.launcher.note(if (dark) "Dark theme" else "Light theme");
                } else logz.log("launcher: theme write failed", .{});
                self.popupRefresh();
            },
            .repaint, .focus_field, .ask_power => self.popupRefresh(),
        }
    }

    fn launcherPress(self: *Taskbar, button: u32) void {
        if (!self.launcher_init) return;
        const seat = self.app.bound.seat_obj orelse return;
        const btn: u8 = switch (button) {
            272 => 1,
            273 => 2,
            274 => 3,
            else => return,
        };
        var pinned = false;
        if (btn == 3) {
            if (self.launcher.indexAt(seat.pointer_x, seat.pointer_y)) |row| {
                if (self.launcher.hitEntry(row)) |e| pinned = self.isPinned(e.id);
            }
        }
        self.applyLauncher(self.launcher.click(seat.pointer_x, seat.pointer_y, .{ .btn = btn, .pinned = pinned }));
    }

    // -- spotlight palette (C++ taskbar spotlight) --------------------------

    fn spotClose(self: *Taskbar) void {
        if (!self.spot_open and self.spot_surface.wl_surface == null) return;
        self.spot_open = false;
        self.open_origin = -1;
        self.spot_shm.deinit();
        self.spot_shm = shm_mod.ShmBuffer.init(self.app.gpa);
        self.spot_surface.destroy();
        const gpa = self.app.gpa;
        if (self.spot_hits.len > 0) gpa.free(self.spot_hits);
        self.spot_hits = &.{};
        for (self.spot_owned) |*o| o.deinit(gpa);
        if (self.spot_owned.len > 0) gpa.free(self.spot_owned);
        if (self.spot_icons.len > 0) gpa.free(self.spot_icons);
        self.spot_owned = &.{};
        self.spot_icons = &.{};
        if (self.spot_cat_loaded) self.spot_catalog.deinit();
        self.spot_cat_loaded = false;
        self.spot_len = 0;
        self.spot_sel = -1;
        self.setBarKeyboard(0); // NONE
        self.open_origin = -1;
        if (!self.app.conn.flush()) logz.log("spotlight: flush failed on close", .{});
    }

    fn setBarKeyboard(self: *Taskbar, mode: u32) void {
        for (self.bars.items) |*b| {
            if (b.surface.layer_surface) |ls| {
                _ = ls;
                b.surface.setKeyboardInteractivity(mode);
                b.surface.commit();
            }
        }
        _ = self.app.conn.flush();
    }

    fn onSpotSurface(self: *Taskbar) bool {
        const seat = self.app.bound.seat_obj orelse return false;
        if (seat.focus_surface == null) return false;
        if (self.spot_surface.wl_surface) |ss| {
            if (seat.focus_surface == ss) return true;
        }
        return false;
    }

    fn openSpotlight(self: *Taskbar, anchor_x: i32) void {
        const gpa = self.app.gpa;
        const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
        self.closePopup();
        self.thumbsDismiss();
        self.closeCc();
        self.closeWorldClock();
        if (!self.spot_cat_loaded) {
            self.spot_catalog = app_catalog.load(gpa, self.app.io) catch {
                logz.err("spotlight: catalog scan failed", .{});
                return;
            };
            self.spot_cat_loaded = true;
        }
        self.spot_len = 0;
        self.spot_sel = -1;
        self.refreshSpot();
        const rows: usize = @min(self.spot_hits.len, 9);
        const pw: i32 = 520;
        const ph: i32 = @intCast(64 + rows * 46 + 16);
        if (!self.spot_surface.create(self.app.bound.compositor, self.app.bound.layer_shell, null, .overlay, ns.popup)) return;
        self.spot_surface.setAnchor(layer.Anchor.bottom | layer.Anchor.left);
        self.spot_surface.setExclusiveZone(-1);
        self.spot_surface.setSize(@intCast(pw), @intCast(ph));
        const want_left = @as(f64, @floatFromInt(anchor_x)) - @as(f64, @floatFromInt(pw)) * 0.5;
        const margin_left: i32 = @intFromFloat(@round(@max(0.0, @min(want_left, @max(0.0, @as(f64, @floatFromInt(bar.w)) - @as(f64, @floatFromInt(pw)))))));
        const clearance = tb_settings.popupBottomClearancePx(&tb_settings.Settings{
            .height = self.app.loaded.cfg.taskbar.height,
            .width_mode = self.app.loaded.cfg.taskbar.width_mode,
            .floating_amount = self.app.loaded.cfg.taskbar.floating_amount,
            .edge_gap = self.app.loaded.cfg.taskbar.edge_gap,
        });
        self.spot_surface.setMargins(0, 0, clearance, margin_left);
        self.spot_surface.commit();
        var ticks: u32 = 0;
        while (ticks < 60 and !self.spot_surface.configured) : (ticks += 1) {
            if (!self.app.conn.roundtrip()) break;
        }
        if (!self.spot_surface.configured) {
            self.spot_surface.destroy();
            return;
        }
        const w: i32 = @intCast(self.spot_surface.configured_width);
        const h: i32 = @intCast(self.spot_surface.configured_height);
        // `w`/`h` stay logical (paintSpot draws in them); only the buffer is
        // allocated at device pixels.
        if (!self.spot_shm.ensure(self.app.bound.shm, "taskbar-spot", w * self.spot_surface.scale, h * self.spot_surface.scale)) {
            self.spot_surface.destroy();
            return;
        }
        self.spot_open = true;
        // Keyboard focus for typing: wlroots grants it to an on-demand layer
        // surface under the pointer on commit (same trick as the dock).
        self.setBarKeyboard(2);
        self.paintSpot();
        if (!self.app.conn.flush()) logz.log("spotlight: flush failed", .{});
    }

    /// Rebuild hits from the query: running windows first, then catalog apps.
    fn freeSpotHits(self: *Taskbar) void {
        const gpa = self.app.gpa;
        for (self.spot_hits) |h| {
            if (h.title.len > 0) gpa.free(h.title);
            if (h.sub.len > 0) gpa.free(h.sub);
            if (h.app_id.len > 0) gpa.free(h.app_id);
            if (h.exec.len > 0) gpa.free(h.exec);
        }
        if (self.spot_hits.len > 0) gpa.free(self.spot_hits);
        self.spot_hits = &.{};
    }

    fn dupeSpot(self: *Taskbar, s: []const u8) []const u8 {
        if (s.len == 0) return "";
        return self.app.gpa.dupe(u8, s) catch "";
    }

    fn refreshSpot(self: *Taskbar) void {
        const gpa = self.app.gpa;
        self.freeSpotHits();
        for (self.spot_owned) |*o| o.deinit(gpa);
        if (self.spot_owned.len > 0) gpa.free(self.spot_owned);
        if (self.spot_icons.len > 0) gpa.free(self.spot_icons);
        self.spot_owned = &.{};
        self.spot_icons = &.{};
        const q = self.spot_query[0..self.spot_len];
        var hits: std.ArrayList(SpotHit) = .empty;
        errdefer hits.deinit(gpa);
        // Running windows match by title or app id.
        if (self.ft_init) {
            for (self.ft.list()) |tl| {
                if (tl.closed or tl.handle == null) continue;
                if (q.len > 0 and !containsFold(tl.title, q) and !containsFold(tl.app_id, q)) continue;
                hits.append(gpa, .{
                    .kind = .window,
                    .title = self.dupeSpot(tl.title),
                    .sub = self.dupeSpot(tl.app_id),
                    .app_id = self.dupeSpot(tl.app_id),
                    .serial = tl.serial,
                }) catch break;
                if (hits.items.len >= 5) break;
            }
        }
        // Installed apps match by name/generic/keywords.
        if (self.spot_cat_loaded and hits.items.len < 9) {
            for (self.spot_catalog.entries) |*e| {
                if (hits.items.len >= 9) break;
                if (q.len > 0 and !containsFold(e.name, q) and !containsFold(e.generic, q) and !containsFold(e.keywords, q)) continue;
                var dup = false;
                for (hits.items) |h| {
                    if (h.kind == .app and std.mem.eql(u8, h.exec, e.exec)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                hits.append(gpa, .{
                    .kind = .app,
                    .title = self.dupeSpot(e.name),
                    .sub = self.dupeSpot(e.generic),
                    .app_id = self.dupeSpot(e.id),
                    .exec = self.dupeSpot(e.exec),
                }) catch break;
            }
        }
        // Empty query: pinned apps so the palette is never a blank box.
        if (q.len == 0 and hits.items.len == 0) {
            for (self.pins) |p| {
                if (hits.items.len >= 9) break;
                hits.append(gpa, .{
                    .kind = .app,
                    .title = self.dupeSpot(p.raw),
                    .sub = self.dupeSpot("Pinned"),
                    .app_id = self.dupeSpot(p.norm),
                    .exec = self.dupeSpot(p.raw),
                }) catch break;
            }
        }
        self.spot_hits = hits.toOwnedSlice(gpa) catch &.{};
        if (self.spot_sel >= @as(i32, @intCast(self.spot_hits.len))) self.spot_sel = -1;
        // Icons for app rows.
        if (icon_cache.shared() != null and self.spot_hits.len > 0) {
            self.spot_icons = gpa.alloc(dwp.IconPx, self.spot_hits.len) catch &.{};
            self.spot_owned = gpa.alloc(icon_cache.Owned, self.spot_hits.len) catch &.{};
            for (self.spot_owned) |*o| o.* = .{ .pixels = &.{}, .w = 0, .h = 0 };
            if (icon_cache.shared()) |ic| {
                for (self.spot_hits, 0..) |*h, i| {
                    if (h.kind != .app) continue;
                    const key = if (h.app_id.len > 0) h.app_id else h.title;
                    if (ic.getOwned(.app, key, 64)) |*o| {
                        self.spot_owned[i] = o.*;
                        self.spot_icons[i] = .{ .pixels = self.spot_owned[i].pixels, .w = self.spot_owned[i].w, .h = self.spot_owned[i].h };
                    }
                }
            }
        }
    }

    fn containsFold(hay: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > hay.len) return false;
        var i: usize = 0;
        while (i + needle.len <= hay.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
            // eqlIgnoreCase needs equal lengths — compare bytewise folded.
            var ok = true;
            for (needle, 0..) |nc, k| {
                if (std.ascii.toLower(hay[i + k]) != std.ascii.toLower(nc)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    fn paintSpot(self: *Taskbar) void {
        if (!self.spot_open) return;
        const cr = self.spot_shm.cr orelse return;
        const w: i32 = @intCast(self.spot_surface.configured_width);
        const h: i32 = @intCast(self.spot_surface.configured_height);
        cairo.cairo_save(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        cairo.cairo_restore(cr);
        // Scale to the output's device pixels; paintSpot draws in logical
        // coordinates (w/h from the configure).
        cairo.cairo_identity_matrix(cr);
        const ssc: f64 = @floatFromInt(self.spot_surface.scale);
        cairo.cairo_scale(cr, ssc, ssc);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        tb_paint.roundedRect(cr, 0.5, 0.5, @as(f64, @floatFromInt(w)) - 1.0, @as(f64, @floatFromInt(h)) - 1.0, 12.0);
        cairo.cairo_set_source_rgba(cr, 0.12, 0.12, 0.14, 0.97);
        cairo.cairo_fill(cr);
        // Search field.
        tb_paint.roundedRect(cr, 10, 10, @as(f64, @floatFromInt(w)) - 20.0, 44.0, 8.0);
        cairo.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
        cairo.cairo_fill(cr);
        cairo.cairo_select_font_face(cr, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(cr, 15.0);
        cairo.cairo_set_source_rgba(cr, 1, 1, 1, if (self.spot_len > 0) 0.92 else 0.4);
        cairo.cairo_move_to(cr, 24.0, 38.0);
        if (self.spot_len > 0) {
            var tbuf: [260]u8 = undefined;
            @memcpy(tbuf[0..self.spot_len], self.spot_query[0..self.spot_len]);
            tbuf[self.spot_len] = 0;
            cairo.cairo_show_text(cr, @ptrCast(&tbuf));
        } else {
            cairo.cairo_show_text(cr, "Search apps and windows");
        }
        // Rows.
        var yy: f64 = 64.0;
        for (self.spot_hits, 0..) |*hit, i| {
            if (i >= 9) break;
            const hov = @as(i32, @intCast(i)) == self.spot_sel;
            if (hov) {
                tb_paint.roundedRect(cr, 10, yy, @as(f64, @floatFromInt(w)) - 20.0, 44.0, 8.0);
                cairo.cairo_set_source_rgba(cr, 0.35, 0.55, 1.0, 0.18);
                cairo.cairo_fill(cr);
            }
            if (i < self.spot_icons.len) {
                const ic = self.spot_icons[i];
                if (ic.pixels.len > 0) blitIconPx(cr, ic, 22.0, yy + 6.0, 32.0);
            }
            cairo.cairo_set_source_rgba(cr, 1, 1, 1, 0.92);
            cairo.cairo_set_font_size(cr, 13.0);
            cairo.cairo_move_to(cr, 62.0, yy + 19.0);
            showClipped(cr, hit.title, 200);
            cairo.cairo_set_source_rgba(cr, 1, 1, 1, 0.55);
            cairo.cairo_set_font_size(cr, 11.0);
            cairo.cairo_move_to(cr, 62.0, yy + 34.0);
            showClipped(cr, hit.sub, 200);
            yy += 46.0;
        }
        self.spot_surface.attach(self.spot_shm.wlBuffer(), 0, 0);
        self.spot_surface.setBufferScale(self.spot_surface.scale);
        self.spot_surface.damage(0, 0, w, h);
        self.spot_shm.markBusy();
        self.spot_surface.commit();
    }

    fn showClipped(cr: *cairo.cairo_t, text: []const u8, max: usize) void {
        var tbuf: [256]u8 = undefined;
        const n = @min(text.len, @min(max, tbuf.len - 1));
        @memcpy(tbuf[0..n], text[0..n]);
        tbuf[n] = 0;
        cairo.cairo_show_text(cr, @ptrCast(&tbuf));
    }

    fn spotRowAt(self: *Taskbar, py: f64) i32 {
        var yy: f64 = 64.0;
        var i: i32 = 0;
        while (@as(usize, @intCast(i)) < self.spot_hits.len and i < 9) : ({
            i += 1;
            yy += 46.0;
        }) {
            if (py >= yy and py < yy + 44.0) return i;
        }
        return -1;
    }

    fn runSpotHit(self: *Taskbar, idx: usize) void {
        if (idx >= self.spot_hits.len) return;
        const hit = self.spot_hits[idx];
        if (hit.kind == .window) {
            if (self.ft_init) {
                for (self.ft.list()) |tl| {
                    if (!tl.closed and tl.handle != null and tl.serial == hit.serial) {
                        _ = self.ft.raiseToplevel(&tl, self.app.bound.seat);
                        _ = self.app.conn.flush();
                        break;
                    }
                }
            }
        } else if (hit.exec.len > 0) {
            if (!app_launch.launchExec(self.app.gpa, self.app.io, hit.exec)) {
                self.launchSlot(if (hit.app_id.len > 0) hit.app_id else hit.title);
            }
        }
        self.spotClose();
        self.repaint();
    }

    /// Spotlight keyboard: type to filter, arrows to pick, Enter to run.
    /// Returns true when the key was consumed.
    fn spotKey(self: *Taskbar, sym: u32, text: []const u8, pressed: bool) bool {
        if (!self.spot_open) return false;
        if (!pressed) return true;
        switch (sym) {
            0xff1b => { // Escape
                self.spotClose();
                self.repaint();
                return true;
            },
            0xff08 => { // BackSpace
                if (self.spot_len > 0) {
                    self.spot_len -= 1;
                    while (self.spot_len > 0 and (self.spot_query[self.spot_len] & 0xC0) == 0x80) self.spot_len -= 1;
                    self.refreshSpot();
                    self.paintSpot();
                    _ = self.app.conn.flush();
                }
                return true;
            },
            0xff52 => { // Up
                if (self.spot_hits.len > 0) {
                    self.spot_sel = if (self.spot_sel <= 0) @intCast(self.spot_hits.len - 1) else self.spot_sel - 1;
                    self.paintSpot();
                    _ = self.app.conn.flush();
                }
                return true;
            },
            0xff54 => { // Down
                if (self.spot_hits.len > 0) {
                    if (self.spot_sel < 0) {
                        self.spot_sel = 0;
                    } else if (self.spot_sel >= @as(i32, @intCast(self.spot_hits.len)) - 1) {
                        self.spot_sel = 0;
                    } else {
                        self.spot_sel += 1;
                    }
                    self.paintSpot();
                    _ = self.app.conn.flush();
                }
                return true;
            },
            0xff0d, 0xff8d => { // Return / KP_Enter
                if (self.spot_sel >= 0) {
                    self.runSpotHit(@intCast(self.spot_sel));
                } else if (self.spot_hits.len > 0) {
                    self.runSpotHit(0);
                }
                return true;
            },
            else => {},
        }
        if (text.len > 0 and self.spot_len < self.spot_query.len) {
            const room = self.spot_query.len - self.spot_len;
            const n = @min(text.len, room);
            // Only printable ASCII + UTF-8 continuation flow; control out.
            var clean: usize = 0;
            for (text[0..n]) |c| {
                if (c < 0x20) continue;
                self.spot_query[self.spot_len + clean] = c;
                clean += 1;
            }
            if (clean > 0) {
                self.spot_len += clean;
                self.spot_sel = -1;
                self.refreshSpot();
                self.paintSpot();
                _ = self.app.conn.flush();
            }
            return true;
        }
        return false;
    }

    // -- IPC ----------------------------------------------------------

    fn ipcEvent(ctx: *anyopaque, topic: []const u8, payload: []const u8, fds: []i32) void {
        _ = fds;
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        switch (tb_standalone.routeIpc(topic, payload)) {
            .reload_config => {
                if (self.app.reload()) {
                    // An `output` change lands through the rebind path, which
                    // already rebuilds/repaints when it moves a bar.
                    if (!self.syncOutputs()) {
                        self.rebuild();
                        self.applyAutohide();
                        self.repaint();
                    }
                }
            },
            .toggle_menu => {
                if (self.popup_init and self.popup.kind == .launcher) {
                    self.closePopup();
                } else {
                    // The IPC menu toggle has no widget to take its face from,
                    // so it keeps the reference panel and the configured view
                    // mode; the App menu's own button opens the rail.
                    self.showLauncher(0, .classic);
                }
                self.repaint();
            },
            .ignore_settings_toggle, .none => {},
        }
    }

    fn ipcConnect(self: *Taskbar, eh_ipc_socket: ?[]const u8, xdg_runtime: ?[]const u8) void {
        if (self.ipc_init) return;
        self.ipc = ipc_client.Client.init(self.app.gpa);
        self.ipc_init = true;
        const path = ipc_client.socketPathFor(self.app.gpa, eh_ipc_socket, xdg_runtime) catch return;
        defer self.app.gpa.free(path);
        if (self.ipc.connect(path, 3)) {
            self.ipc.setEventHandler(ipcEvent, @ptrCast(self));
            self.ipc_ok = self.ipc.subscribe("config.applied", 1000) and self.ipc.subscribe("command.request", 1000);
        }
    }

    fn onIpcFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = revents;
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        _ = fd;
        if (self.ipc_init) self.ipc.onFdReady(self.ipc.fd);
    }

    // -- tick ---------------------------------------------------------

    fn onKey(ctx: *anyopaque, ev: *const seat_mod.KeyEvent) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        if (self.spot_open) {
            const pressed = ev.state == 1;
            const text = if (ev.utf8_len > 0) ev.utf8[0..@min(@as(usize, ev.utf8_len), ev.utf8.len)] else "";
            if (self.spotKey(ev.sym, text, pressed)) return;
            if (pressed) return;
        }
        if (self.cc_init and self.cc.open) {
            const pressed = ev.state == 1;
            const text = if (ev.utf8_len > 0) ev.utf8[0..@min(@as(usize, ev.utf8_len), ev.utf8.len)] else "";
            if (self.cc.key(ev.sym, text, pressed)) |a| {
                self.runCcAction(a);
                return;
            }
            if (pressed) return;
        }
        // Same for pear's overlay password prompt.
        if (self.pear_init and self.pear.open) {
            const pressed = ev.state == 1;
            const text = if (ev.utf8_len > 0) ev.utf8[0..@min(@as(usize, ev.utf8_len), ev.utf8.len)] else "";
            if (self.pear.key(ev.sym, text, pressed)) |a| {
                self.runPearAction(a);
                return;
            }
            if (pressed) return;
        }
        // World clock popup: full keyboard support. The shift bit is not part
        // of the seat's event, so the modifier keycodes carry it.
        if (self.wc_open and self.wc_init) {
            const pressed = ev.state == 1;
            if (ev.keycode == 42 or ev.keycode == 54) self.wc_shift_down = pressed;
            const text = if (ev.utf8_len > 0) ev.utf8[0..@min(@as(usize, ev.utf8_len), ev.utf8.len)] else "";
            self.applyWcOutcome(wc_panel.key(&self.wc, &self.wc_geom, ev.sym, text, pressed, self.wc_shift_down, epochMs()));
            return;
        }
        // With the bar itself holding keyboard, the strip's world clock
        // answers arrows and activation like the reference widget button.
        if (self.wc_init and self.wcSlotHovered() and ev.state == 1) {
            const bar = if (self.bars.items.len > 0) &self.bars.items[0] else return;
            switch (ev.sym) {
                0xff51, 0xff52 => { // Left / Up
                    if (self.wc.go(-1, true, epochMs())) {
                        self.armAnim();
                        self.repaint();
                    }
                    return;
                },
                0xff53, 0xff54 => { // Right / Down
                    if (self.wc.go(1, true, epochMs())) {
                        self.armAnim();
                        self.repaint();
                    }
                    return;
                },
                0xff0d, 0xff8d, 0x20 => { // Return / KP_Enter / Space
                    self.openWorldClock(bar, @intCast(self.hover));
                    return;
                },
                else => {},
            }
        }
        if (!self.popup_init or self.popup.kind != .launcher) return;
        self.applyLauncher(self.launcher.key(ev));
    }

    fn onAxis(ctx: *anyopaque, delta: f64) void {
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        if (self.cc_init and self.cc.open and self.onCcSurface()) {
            const seat = self.app.bound.seat_obj orelse return;
            if (self.cc.scroll(seat.pointer_x, seat.pointer_y, delta)) |a| self.runCcAction(a);
            return;
        }
        // Same over the pear popup.
        if (self.pear_init and self.pear.open and self.onPearSurface()) {
            const seat = self.app.bound.seat_obj orelse return;
            if (self.pear.scroll(seat.pointer_x, seat.pointer_y, delta)) |a| self.runPearAction(a);
            return;
        }
        // World clock popup: scrolls the city list (or the add-pane results).
        if (self.wc_open and self.onWcSurface()) {
            const out = wc_panel.scroll(&self.wc, &self.wc_geom, delta);
            if (out.repaint) self.wcRefresh();
            return;
        }
        // Over the widget itself a wheel step moves between cities and never
        // reaches anything behind it.
        if (self.wc_init and self.wcSlotHovered()) {
            const dir: i32 = if (delta < 0) -1 else 1;
            if (self.wc.go(dir, true, epochMs())) {
                self.armAnim();
                self.repaint();
            }
            return;
        }
        if (self.mixerAxis(delta)) return;
        if (!self.popup_init or self.popup.kind != .launcher) return;
        const step = std.math.clamp(delta * 4.0, -240.0, 240.0);
        if (self.launcher.axis(step)) self.popupRefresh();
    }

    fn armAnim(self: *Taskbar) void {
        if (self.anim_fd >= 0) return;
        const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }));
        if (rc < 0) return;
        self.anim_fd = @intCast(rc);
        self.app.loop.watchFd(self.anim_fd, std.posix.POLL.IN, onAnimTick, @ptrCast(self)) catch {
            _ = linux.close(self.anim_fd);
            self.anim_fd = -1;
            return;
        };
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 16_000_000 },
            .it_value = .{ .sec = 0, .nsec = 16_000_000 },
        };
        _ = linux.timerfd_settime(self.anim_fd, .{}, &spec, null);
    }

    fn onAnimTick(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = revents;
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        // A closed animation timer used to leave its watch entry behind. If
        // the number was reused, this callback read whatever object owned it
        // now — including a blocking read on a socket that froze the loop.
        // A stale entry names an fd that is not ours any more: drop it.
        if (fd != self.anim_fd) {
            self.app.loop.unwatch(fd);
            return;
        }
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        var work = false;
        if (self.cc_init and self.cc.open and self.cc.animActive()) {
            self.ccRefresh();
            work = true;
        }
        if (self.popup_init and self.popup.kind == .launcher and self.launcher_init) {
            if (self.launcher.tick()) self.popupRefresh();
            // Same contract as the dock: paints never decode, this tick does,
            // and only frames that landed an icon are worth drawing again.
            if (self.launcher.prefetchIcons(8)) self.popupRefresh();
            work = true;
        }
        if (self.popup_init and self.popup.kind == .media_player) {
            self.syncMediaPopup();
            self.popupRefresh();
            work = true;
        }
        if (self.wc_init) {
            // World-clock state is fed epoch milliseconds; see `epochMs`.
            const now = epochMs();
            if (self.wc.slide.active) {
                const still = self.wc.tickAnim(now);
                self.repaint();
                if (still) work = true;
            }
            if (self.wc_open) {
                const anim = wc_panel.animActive(&self.wc, now);
                if (anim or self.wc_anim_prev) {
                    // The last frame lands when the transition ends: the open
                    // scale/alpha must end exactly at rest.
                    self.wcRefresh();
                    self.wc_anim_prev = anim;
                    if (anim) work = true;
                }
            } else {
                self.wc_anim_prev = false;
            }
        }
        if (self.bounce_key.len > 0) {
            self.repaint();
            work = true;
        }
        if (!work) {
            self.app.loop.unwatch(self.anim_fd);
            _ = linux.close(self.anim_fd);
            self.anim_fd = -1;
        }
    }

    /// Whole-second repaint governance for the clock-family slots. The world
    /// clock ticks every second — its face carries a seconds hand and rotates
    /// every 30 s — while the plain clock ticks every second only while some
    /// instance shows seconds and once a minute otherwise: a face without a
    /// seconds hand changes only on minute boundaries. Presence *and*
    /// granularity are both read off the current strip, so an empty strip
    /// costs one loop and nothing else.
    fn tickClocks(self: *Taskbar) bool {
        const cfg = &self.app.loaded.cfg;
        var any_clock = false;
        var show_seconds = false;
        var any_world = false;
        for (self.sections.all) |*s| {
            switch (s.kind) {
                .clock => {
                    any_clock = true;
                    if (!show_seconds and clock_paint.optionsFor(cfg, s.key).show_seconds) show_seconds = true;
                },
                .world_clock => any_world = true,
                else => {},
            }
        }
        var due = false;
        if (any_world and self.wc_init) {
            // Every whole second: the face advances its 5 s rotation, its
            // slides and, while the popup is open, the popup's own clock
            // (the seconds switch included). The strip repaints only when
            // its text changes — the popup owns its own surface.
            const now = epochMs();
            const tr = self.wc.tick(now);
            if (tr.face or tr.minute) due = true;
            if (tr.second and self.wc_open) self.wcRefresh();
            if (self.wc.slide.active) self.armAnim();
        }
        if (any_clock) {
            const now_sec = clock_paint.nowSeconds();
            const sig: i32 = if (show_seconds) @truncate(now_sec) else @truncate(@divTrunc(now_sec, 60));
            if (sig != self.clock_tick_sig) {
                self.clock_tick_sig = sig;
                due = true;
            }
        }
        return due;
    }

    fn onTimer(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = revents;
        const self: *Taskbar = @ptrCast(@alignCast(ctx));
        var exp: [8]u8 = undefined;
        _ = linux.read(fd, &exp, exp.len);
        if (self.tray_init) {
            if (self.tray.pump(@as(i64, @intCast(nowMs())))) self.dirty = true;
        }
        if (self.ft_init) self.ft.pruneClosed();
        const now = nowMs();
        if (getenvStr("TB_NOCC") != null) {
            if (self.syncOutputs()) self.dirty = true;
        } else {
            if (self.syncOutputs()) self.dirty = true;
            if (self.pollCcLive(now, false)) self.dirty = true;
        }
        if (self.pollBattery(now)) self.dirty = true;
        if (self.pollTrashFs(now)) self.dirty = true;
        if (self.pollWeather(now)) self.dirty = true;
        if (self.pollCcLive(now, false)) self.dirty = true;
        if (self.takeVpnRows()) self.dirty = true;
        self.pollVpn(now);
        if (self.wsSlotPresent() and self.reloadWorkspaces(false)) self.dirty = true;
        if (self.takeMixer(now)) self.dirty = true;
        self.pollMixer(now);
        if (self.pollMedia(now)) {
            self.dirty = true;
            self.syncMediaPopup();
        }
        const clock_tick = self.tickClocks();
        if (clock_tick) self.dirty = true;
        if (self.dirty) {
            self.rebuild();
            self.repaint();
        } else {
            // Bounce animation advances on its own clock.
            if (self.bounce_key.len > 0) self.repaint();
        }
        self.thumbsTick();
        if (self.popup_init and self.popup.kind == .media_player) {
            self.syncMediaPopup();
            self.popupRefresh();
        }
        // The strip's world clock runs its own tick (see `tickClocks`), and
        // the popup owns its surface.
        if (self.popup_init and self.popup.kind == .launcher and self.launcher_init) {
            if (self.launcher.tick()) self.popupRefresh();
        }
        if (self.cc_init and self.cc.open and self.cc.animActive()) self.armAnim();
        if (self.popup_init and self.popup.kind == .launcher) self.armAnim();
        if (self.wc_open and self.wc_init and wc_panel.animActive(&self.wc, epochMs())) self.armAnim();
    }

    fn destroyBars(self: *Taskbar) void {
        const gpa = self.app.gpa;
        for (self.bars.items) |*b| {
            if (b.xs.len > 0) gpa.free(b.xs);
            if (b.ws.len > 0) gpa.free(b.ws);
            if (b.output_name.len > 0) gpa.free(b.output_name);
            b.surface.destroy();
            b.shm.deinit();
        }
        self.bars.clearRetainingCapacity();
    }

    /// Resolve `[taskbar] output` to the indices of the outputs the bar(s)
    /// belong on. `createBars` and `syncOutputs` share this so both agree on
    /// what the current layout is. Comparing every live output against the
    /// bars instead made a single-bar config (Auto / a named output) on a
    /// multi-output desktop re-bind on every poll tick — the surface unmapped
    /// and the compositor replayed its map fade once a second (the flicker).
    fn targetOutputIndices(self: *Taskbar, targets: *std.ArrayList(usize)) void {
        const gpa = self.app.gpa;
        const a = self.app;
        const assign = tb_standalone.classifyOutput(a.loaded.cfg.taskbar.output_name);
        switch (assign.kind) {
            .all => for (a.bound.outputs.items, 0..) |_, i| targets.append(gpa, i) catch break,
            .auto => {
                if (a.bound.outputs.items.len > 0) targets.append(gpa, 0) catch {};
            },
            .named => {
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(gpa);
                for (a.bound.outputs.items) |o| names.append(gpa, o.name) catch break;
                var xs_buf: [1]i32 = .{0};
                var ys_buf: [1]i32 = .{0};
                const xs = gpa.alloc(i32, a.bound.outputs.items.len) catch xs_buf[0..0];
                defer if (xs.ptr != xs_buf[0..0].ptr) gpa.free(xs);
                const ys = gpa.alloc(i32, a.bound.outputs.items.len) catch ys_buf[0..0];
                defer if (ys.ptr != ys_buf[0..0].ptr) gpa.free(ys);
                if (tb_standalone.pickSingleOutput(names.items, assign.name, xs, ys)) |idx| {
                    targets.append(gpa, idx) catch {};
                } else if (a.bound.outputs.items.len > 0) targets.append(gpa, 0) catch {};
            },
        }
        if (targets.items.len == 0 and a.bound.outputs.items.len > 0) targets.append(gpa, 0) catch {};
    }

    /// (Re)create one layer surface per target output. Returns false when no
    /// surface came up.
    fn createBars(self: *Taskbar) bool {
        const gpa = self.app.gpa;
        const a = self.app;
        const cfg = &a.loaded.cfg;
        const height = self.barHeight();
        var targets: std.ArrayList(usize) = .empty;
        defer targets.deinit(gpa);
        self.targetOutputIndices(&targets);
        const floating = cfg.taskbar.width_mode == 0;
        const top = cfg.taskbar.position_top;
        // Reserve up front: the layer-surface listener is registered against
        // the in-array element, and a realloc mid-loop would dangle every
        // previously registered ctx pointer (late configures then corrupt
        // memory — the dispatch crash).
        self.bars.ensureTotalCapacity(gpa, targets.items.len) catch {};
        for (targets.items) |oi| {
            const o = a.bound.outputs.items[oi];
            const want_w: i32 = if (o.width > 0) o.width else 1200;
            self.bars.append(gpa, Bar{ .shm = shm_mod.ShmPair.init(gpa), .w = want_w, .h = height, .output = oi }) catch break;
            const b = &self.bars.items[self.bars.items.len - 1];
            b.output_name = gpa.dupe(u8, o.name) catch &.{};
            const anchor: u32 = if (top)
                layer.Anchor.top | layer.Anchor.left | layer.Anchor.right
            else
                layer.Anchor.bottom | layer.Anchor.left | layer.Anchor.right;
            // TOP, matching the C++ taskbar. The desktop is BOTTOM and is
            // recreated after us on restart; same-layer ordering would put
            // the desktop's full-screen input region above the bar.
            if (!b.surface.create(a.bound.compositor, a.bound.layer_shell, o.obj, .top, ns.taskbar)) {
                self.dropBar(b);
                continue;
            }
            b.surface.setAnchor(anchor);
            b.surface.on_scale = Taskbar.onScale;
            b.surface.ctx = self;
            if (cfg.taskbar.auto_hide) {
                b.surface.setExclusiveZone(0);
                self.reveal = false;
            } else {
                b.surface.setExclusiveZone(height + cfg.taskbar.exclusive_zone_gap);
            }
            b.surface.setSize(@intCast(want_w), @intCast(height));
            var mt: i32 = 0;
            var mr: i32 = 0;
            var mb: i32 = 0;
            var ml: i32 = 0;
            if (floating) {
                mr = cfg.taskbar.floating_amount;
                ml = cfg.taskbar.floating_amount;
            }
            if (cfg.taskbar.edge_gap > 0) {
                if (top) {
                    mt = cfg.taskbar.edge_gap;
                } else {
                    mb = cfg.taskbar.edge_gap;
                }
            }
            b.margins = .{ mt, mr, mb, ml };
            b.surface.setMargins(mt, mr, mb, ml);
            b.surface.commit();
            var ticks: u32 = 0;
            while (ticks < 100 and !b.surface.configured) : (ticks += 1) {
                if (!a.conn.roundtrip()) break;
            }
            if (!b.surface.configured) {
                logz.err("surface never configured for output {d}", .{oi});
                self.dropBar(b);
                continue;
            }
            b.w = @intCast(b.surface.configured_width);
            b.h = @intCast(b.surface.configured_height);
            // `b.w`/`b.h` stay logical (paint and layout use them as such);
            // only the buffer itself is allocated at device pixels.
            if (!b.shm.ensure(a.bound.shm, "taskbar", b.w * b.surface.scale, b.h * b.surface.scale)) {
                logz.err("shm ensure failed for output {d}", .{oi});
                self.dropBar(b);
                continue;
            }
        }
        return self.bars.items.len > 0;
    }

    /// Remove the last-appended bar (createBars failure path): the surface
    /// listener was registered against the in-array element, so only pop.
    fn dropBar(self: *Taskbar, b: *Bar) void {
        const gpa = self.app.gpa;
        b.surface.destroy();
        b.shm.deinit();
        if (b.output_name.len > 0) gpa.free(b.output_name);
        if (self.bars.items.len > 0 and &self.bars.items[self.bars.items.len - 1] == b) {
            _ = self.bars.pop();
        }
    }

    /// Output hotplug (`pendingOutputRebind`): compare live outputs against
    /// bar outputs; rebuild surfaces when the set moved.
    fn syncOutputs(self: *Taskbar) bool {
        const gpa = self.app.gpa;
        var targets: std.ArrayList(usize) = .empty;
        defer targets.deinit(gpa);
        self.targetOutputIndices(&targets);
        if (targets.items.len == self.bars.items.len) {
            var same = true;
            for (targets.items, 0..) |oi, i| {
                const o = self.app.bound.outputs.items[oi];
                if (!std.mem.eql(u8, o.name, self.bars.items[i].output_name)) {
                    same = false;
                    break;
                }
            }
            if (same) return false;
        }
        logz.log("outputs changed ({d} targets, {d} bars): rebinding", .{ targets.items.len, self.bars.items.len });
        self.closePopup();
        self.thumbsDismiss();
        self.tooltipHide();
        self.closeCc();
        self.spotClose();
        self.destroyBars();
        if (!self.createBars()) {
            logz.err("output rebind: no surfaces", .{});
            return true;
        }
        self.rebuild();
        self.applyAutohide();
        self.repaint();
        return true;
    }

    fn setReveal(self: *Taskbar, reveal: bool) void {
        if (reveal == self.reveal and !self.slide_active) return;
        self.reveal = reveal;
        self.slide_from_px = self.slide_off_px;
        self.slide_start_ms = nowMs();
        self.slide_active = true;
        self.applyAutohide();
        self.armAnim();
    }

    /// 200 ms ease for the autohide slide; the exclusive zone snaps at once
    /// (windows move now) while pixels glide.
    fn tickSlide(self: *Taskbar) bool {
        if (!self.slide_active) return false;
        const target: f64 = if (self.reveal) 0 else @as(f64, @floatFromInt(@max(1, self.barHeight())));
        const el: f64 = @floatFromInt(nowMs() -| self.slide_start_ms);
        const t = @min(1.0, el / 200.0);
        const e = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t);
        self.slide_off_px = self.slide_from_px + (target - self.slide_from_px) * e;
        if (t >= 1.0) {
            self.slide_off_px = target;
            self.slide_active = false;
        }
        const off: i32 = @intFromFloat(@round(self.slide_off_px));
        const top = self.app.loaded.cfg.taskbar.position_top;
        for (self.bars.items) |*b| {
            const m = b.margins;
            if (top) {
                b.surface.setMargins(m[0] + off, m[1], m[2], m[3]);
            } else {
                b.surface.setMargins(m[0], m[1], m[2] + off, m[3]);
            }
            b.surface.commit();
        }
        _ = self.app.conn.flush();
        return true;
    }

    /// A hover decision (preview popup or tooltip) is still on the 500 ms
    /// clock, so the frame chain must keep ticking until it fires.
    fn hoverPending(self: *Taskbar) bool {
        if (self.hover < 0) return false;
        if (self.thumbs_open or self.tooltip_open) return false;
        if (self.tooltip_slot != self.hover) return false;
        const cfg = &self.app.loaded.cfg;
        if (!self.slotPreviewsOnHover(self.hover) and !cfg.taskbar.tooltips_enabled) return false;
        return nowMs() -| self.tooltip_start_ms < tb_state.tooltip_delay_ms;
    }

    fn animated(self: *Taskbar) bool {
        self.bounceRetire();
        if (self.bounce_key.len > 0) return true;
        if (self.slide_active) return true;
        if (self.hoverPending()) return true;
        if (self.ccDragging()) return true;
        if (self.cc_init and self.cc.open and self.cc.animActive()) return true;
        if (self.popup_init and self.popup.kind == .launcher) return true;
        if (self.popup_init and self.popup.kind == .media_player) return true;
        // The media pill's marquee and progress border (dock parity):
        // `paint` re-arms these every frame, so the chain dies the moment
        // the row stops scrolling or the track stops.
        if (self.media_wants_marquee or self.media_progress_tick) return true;
        return false;
    }

    fn requestFrame(self: *Taskbar) void {
        if (self.frame_pending) return;
        if (self.bars.items.len == 0) return;
        const surf = self.bars.items[0].surface.wl_surface orelse return;
        const cb = wl.wl_surface_frame(surf) orelse return;
        _ = wl.wl_callback_add_listener(cb, &frame_listener, self);
        self.frame_pending = true;
        _ = self.app.conn.flush();
    }

    fn frameDone(data: ?*anyopaque, cb: ?*wl.wl_callback, time: u32) callconv(.c) void {
        _ = time;
        const self: *Taskbar = @ptrCast(@alignCast(data orelse return));
        if (cb) |c| wl.wl_callback_destroy(c);
        self.frame_pending = false;
        if (self.hot_follow_dirty) {
            self.hot_follow_dirty = false;
            self.repaint();
        }
        if (self.tickSlide()) self.repaint();
        self.hoverTick();
        if (self.animated()) {
            self.repaint();
            self.requestFrame();
        }
    }

    const frame_listener = wl.wl_callback_listener{ .done = frameDone };
};

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;
    logz.init(io, init.environ_map.get("HOME"), "horizon-taskbar-zig");
    defer logz.deinit();
    logz.log("boot: pid={d}", .{linux.getpid()});
    const boot_t0 = nowMs();

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch &.{};
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("usage: horizon-taskbar   run the taskbar bar\n       horizon-taskbar --check  diagnose config/strip/icons without Wayland\n", .{});
            return 0;
        }
        if (std.mem.eql(u8, a, "--check")) {
            return runCheck(gpa, io, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME"));
        }
    }

    var a = app.App.init(gpa, io, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME")) catch |e| {
        logz.err("init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer a.deinit();
    bootMark(boot_t0, "app");

    icon_cache.initGlobal(gpa, io);
    defer icon_cache.deinitGlobal();
    if (icon_cache.shared()) |ic| {
        ic.setTheme(if (a.loaded.cfg.taskbar.icon_theme.len > 0)
            a.loaded.cfg.taskbar.icon_theme
        else
            eh.icon_themes.detectSystemIconTheme(io) orelse "hicolor");
    }
    bootMark(boot_t0, "icon_theme");

    var tb = Taskbar{
        .app = &a,
        .thumbs_shm = shm_mod.ShmBuffer.init(gpa),
        .tooltip_shm = shm_mod.ShmBuffer.init(gpa),
        .spot_shm = shm_mod.ShmBuffer.init(gpa),
        .wc_shm = shm_mod.ShmBuffer.init(gpa),
    };
    defer tb.deinit();
    tb.toplevels = foreign.Tracker.init(gpa);
    tb.toplevels_init = true;
    tb.toplevels.on_changed = onToplevelChanged;
    tb.toplevels.changed_ctx = &tb;
    tb.ws_surfs = std.StringHashMap(WsSurf).init(gpa);
    tb.ws_surfs_init = true;
    // Both protocols announce the windows that already exist exactly once,
    // right after they are bound — and `App.init`'s roundtrip already spent
    // that dump before this process had a listener. Rebind so the whole list
    // lands on live listeners (the dock does the same); without it the strip
    // stays empty no matter how many windows are open.
    a.conn.rebindToplevelList(&a.bound);
    if (a.bound.foreign_toplevel_list) |list| tb.toplevels.bindExt(list);
    tb.ft = ftl.ForeignToplevels.init(gpa);
    tb.ft_init = true;
    a.conn.rebindForeignToplevelManager(&a.bound);
    if (a.bound.foreign_toplevel_manager) |mgr| tb.ft.attach(mgr, a.conn.display);
    if (!a.conn.roundtrip()) logz.log("taskbar: toplevel roundtrip failed; previews and activation fall back", .{});
    logz.log("taskbar: toplevels {d} known (zwlr {s}, ext {s})", .{
        tb.ft.size(),
        if (a.bound.foreign_toplevel_manager != null) "bound" else "MISSING",
        if (a.bound.foreign_toplevel_list != null) "bound" else "MISSING",
    });
    bootMark(boot_t0, "toplevels");
    tb.tray = tray_source.Source.init(gpa);
    tb.tray_init = true;
    tb.popup = popup_mod.Host.init(gpa);
    tb.popup_init = true;
    tb.popup.surface.on_configure = Taskbar.onPopupConfigure;
    tb.popup.surface.on_closed = Taskbar.onPopupClosed;
    tb.popup.surface.ctx = &tb;
    tb.cc = cc_host.Host.init(gpa);
    tb.cc_init = true;
    tb.cc.surface.on_configure = Taskbar.onCcConfigure;
    tb.cc.surface.on_closed = Taskbar.onCcClosed;
    tb.cc.surface.ctx = &tb;
    tb.pear = pear_host.Host.init(gpa);
    tb.pear_init = true;
    tb.pear.surface.on_configure = Taskbar.onPearConfigure;
    tb.pear.surface.on_closed = Taskbar.onPearClosed;
    tb.pear.surface.ctx = &tb;
    // World clock: own session (own settings file), no shared state with the
    // dock's module. Reduced motion follows the environment knob the shell
    // already uses.
    tb.wc = wc_session.Session.init(gpa, io);
    tb.wc_init = true;
    tb.wc.reduce_motion = if (getenvStr("EH_REDUCED_MOTION")) |v| !std.mem.eql(u8, v, "0") else false;
    tb.wc.load();
    tb.redeye_inhibit.setManager(a.bound.idle_inhibit_manager);
    tb.media = mpris_client.Client.init(gpa);
    tb.media_init = true;
    tb.notif_push = notify_push.Publisher.init(gpa);
    tb.notif_init = true;
    tb.launcher = launcher_menu.Menu.init(gpa, io);
    tb.launcher_init = true;
    tb.vpn_store = vpn_popup.Store.init(gpa);
    tb.vpn_store_init = true;

    a.on_reload = Taskbar.onReload;
    a.reload_ctx = &tb;

    const cfg = &a.loaded.cfg;
    if (!cfg.taskbar.enabled) logz.log("taskbar disabled in config; running anyway (manual start)", .{});

    if (!tb.createBars()) {
        logz.err("no taskbar surfaces", .{});
        return 1;
    }
    bootMark(boot_t0, "bars");
    if (a.bound.seat_obj) |seat| {
        seat.on_pointer_enter = Taskbar.onEnter;
        seat.on_pointer_leave = Taskbar.onLeave;
        seat.on_pointer_motion = Taskbar.onMotion;
        seat.on_pointer_button = Taskbar.onButton;
        seat.on_pointer_axis = Taskbar.onAxis;
        seat.on_key = Taskbar.onKey;
        seat.cb_ctx = &tb;
    }
    // 250 ms poll timer: the media poll and cover pick-up run on the tick
    // (a 1 s cadence made covers land seconds after a track change, and the
    // dock feels instant at 400 ms). Tray pump, toplevel reap and the other
    // upkeep calls are gated by their own next-ms fields, so the faster tick
    // only costs an extra wakeup.
    {
        const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
        if (rc >= 0) {
            tb.timer_fd = @intCast(rc);
            const spec = linux.itimerspec{
                .it_interval = .{ .sec = 0, .nsec = 250_000_000 },
                .it_value = .{ .sec = 0, .nsec = 250_000_000 },
            };
            if (linux.timerfd_settime(tb.timer_fd, .{}, &spec, null) != 0) {
                _ = linux.close(tb.timer_fd);
                tb.timer_fd = -1;
            } else {
                a.loop.watchFd(tb.timer_fd, std.posix.POLL.IN, Taskbar.onTimer, @ptrCast(&tb)) catch {
                    _ = linux.close(tb.timer_fd);
                    tb.timer_fd = -1;
                };
            }
        }
    }
    tb.ipcConnect(init.environ_map.get("EH_IPC_SOCKET"), init.environ_map.get("XDG_RUNTIME_DIR"));
    if (tb.ipc_ok) {
        const cfd = tb.ipc.fd;
        if (cfd >= 0) a.loop.watchFd(cfd, std.posix.POLL.IN, Taskbar.onIpcFd, @ptrCast(&tb)) catch {};
    }
    bootMark(boot_t0, "ipc");

    tb.boot_t0 = boot_t0;
    tb.rebuild();
    bootMark(boot_t0, "rebuild");
    tb.banner();
    tb.repaint();
    logz.log("running bars={d} slots={d}", .{ tb.bars.items.len, tb.sections.all.len });

    // Late tray start, dock parity: discovery rides out its probe budget
    // (names that never answer expire together — ~1.5 s) and the watcher
    // snapshot can eat another second, so the first frame goes out without
    // the tray and the strip fills on the rebuild below.
    if (tb.tray.start()) {
        if (tb.tray.conn.fd >= 0) {
            a.loop.watchFd(tb.tray.conn.fd, std.posix.POLL.IN, onTrayFd, @ptrCast(&tb)) catch {};
        }
        if (tb.tray.itemCount() > 0) {
            tb.rebuild();
            tb.repaint();
        }
    }
    bootMark(boot_t0, "tray_late");
    // inotify is not recursive: watch the taskbar component dir plus the
    // `appearance` subdir (every Appearance → Opacity knob — tooltip alpha
    // included), so a settings save lands without a restart.
    var watch_owned: [2][]u8 = undefined;
    var watch_dirs: [2][]const u8 = undefined;
    var n_watch: usize = 0;
    for ([_][]const u8{ "taskbar", "appearance" }) |comp| {
        if (config.componentDir(gpa, a.xdg_config, a.home, comp)) |dir| {
            if (std.mem.eql(u8, comp, "appearance")) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            watch_owned[n_watch] = dir;
            watch_dirs[n_watch] = dir;
            n_watch += 1;
        } else |_| {}
    }
    defer for (watch_owned[0..n_watch]) |p| gpa.free(p);
    a.startWatching(watch_dirs[0..n_watch]);
    a.run();
    return 0;
}

fn onToplevelChanged(ctx: *anyopaque) void {
    const tb: *Taskbar = @ptrCast(@alignCast(ctx));
    tb.dirty = true;
}

/// Headless diagnostic: config → strip → icons, no Wayland needed. Prints
/// exactly why a bar would come up blank (disabled, empty strip, no icons).
fn runCheck(gpa: std.mem.Allocator, io: std.Io, xdg_config: ?[]const u8, home: ?[]const u8) u8 {
    var loaded = config.loadDefault(gpa, io, xdg_config, home) catch |e| {
        std.debug.print("check: config load failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer loaded.deinit();
    const cfg = &loaded.cfg;
    std.debug.print("check: enabled={} height={} icon_size={} scale={} opacity={} top={} auto_hide={} labels={} widgets={}\n", .{
        cfg.taskbar.enabled,         cfg.taskbar.height,       cfg.taskbar.icon_size, cfg.taskbar.scale,
        cfg.taskbar.opacity,         cfg.taskbar.position_top, cfg.taskbar.auto_hide, cfg.taskbar.show_labels,
        cfg.taskbar.widgets_enabled,
    });
    std.debug.print("check: left={d} center={d} right={d} pins={d} theme='{s}'\n", .{
        cfg.taskbar.left_widgets.len, cfg.taskbar.center_widgets.len, cfg.taskbar.right_widgets.len,
        cfg.taskbar.pinned_apps.len,  cfg.taskbar.icon_theme,
    });
    for (cfg.taskbar.pinned_apps, 0..) |p, i| {
        std.debug.print("check: pin[{d}] '{s}'\n", .{ i, p });
    }
    var pin_list: std.ArrayList(tb_strip.Pin) = .empty;
    defer pin_list.deinit(gpa);
    var pin_strs: std.ArrayList([]u8) = .empty;
    defer {
        for (pin_strs.items) |s| gpa.free(s);
        pin_strs.deinit(gpa);
    }
    for (cfg.taskbar.pinned_apps) |p| {
        const norm = paths.normalizeAppId(gpa, p) catch continue;
        const raw = gpa.dupe(u8, p) catch {
            gpa.free(norm);
            continue;
        };
        pin_strs.append(gpa, norm) catch {
            gpa.free(norm);
            gpa.free(raw);
            continue;
        };
        pin_strs.append(gpa, raw) catch continue;
        pin_list.append(gpa, .{ .raw = pin_strs.items[pin_strs.items.len - 1], .norm = pin_strs.items[pin_strs.items.len - 2] }) catch continue;
    }
    const ctx = tb_strip.Ctx{ .pinned = pin_list.items };
    var sec = tb_strip.buildAll(gpa, cfg, &ctx) catch {
        std.debug.print("check: strip build failed (out of memory)\n", .{});
        return 1;
    };
    defer sec.deinit(gpa);
    std.debug.print("check: strip slots={d} (win7={})\n", .{ sec.all.len, sec.win7 });
    icon_cache.initGlobal(gpa, io);
    defer icon_cache.deinitGlobal();
    if (icon_cache.shared()) |ic| {
        ic.setTheme(if (cfg.taskbar.icon_theme.len > 0)
            cfg.taskbar.icon_theme
        else
            eh.icon_themes.detectSystemIconTheme(io) orelse "hicolor");
    }
    var hit: usize = 0;
    var miss: usize = 0;
    for (sec.all, 0..) |*s, i| {
        var icon: []const u8 = "";
        if (s.kind == .app) {
            if (icon_cache.shared()) |ic| {
                if (ic.getOwned(.app, s.icon_id, 64)) |oo| {
                    var owned = oo;
                    defer owned.deinit(gpa);
                    icon = "found";
                    hit += 1;
                } else {
                    icon = "MISSING";
                    miss += 1;
                }
            }
        }
        std.debug.print("check: slot[{d}] {s} '{s}' {s}\n", .{ i, @tagName(s.kind), s.key, icon });
    }
    std.debug.print("check: icons {d}/{d}\n", .{ hit, hit + miss });
    if (!cfg.taskbar.enabled) std.debug.print("check: BLANK CAUSE: [taskbar] enabled=false — set it in Settings > Taskbar\n", .{});
    if (sec.all.len == 0) std.debug.print("check: BLANK CAUSE: strip is empty — no widgets, pins or running apps\n", .{});
    if (sec.all.len > 0 and hit + miss > 0 and hit == 0) std.debug.print("check: all icons missing — check icon_theme / installed themes\n", .{});
    return 0;
}

fn onTrayFd(fd: i32, revents: i16, ctx: *anyopaque) void {
    _ = fd;
    _ = revents;
    const tb: *Taskbar = @ptrCast(@alignCast(ctx));
    if (tb.tray_init) {
        // Drain the bus here: leaving the socket readable would spin the
        // event loop at full speed until the 1 s tick pumps it. The tick
        // pump stays as the safety net.
        if (tb.tray.pump(@as(i64, @intCast(nowMs())))) tb.dirty = true;
    }
}
