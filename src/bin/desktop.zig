//! `horizon-desktop` — the desktop icon + widget-base layer process.
//!
//! Desktop process: one transparent BOTTOM layer surface per output,
//! desktop icons scanned from `~/Desktop` (+ drives + trash + computer),
//! grid layout from `desktop_icons_layout.txt`, left-click launch, drag to
//! move, marquee rubber-band select, workspace right-click menu
//! (View/Sort by/New) and icon right-click menu (Open/Open With/Compress/
//! Mount/…), with the mount dialog and "Open With" card.
//!
//! Own Wayland connection (`App`), 1s rescan tick, inotify reload.
//! Exits 0 when `[desktop] enabled` is false.

const std = @import("std");
const eh = @import("eh");
const app_mod = @import("app.zig");

const config = eh.config;
const layer = eh.wl_layer;
const ns = eh.ns;
const shm_mod = eh.wl_shm;
const cairo = shm_mod.cairo;
const parent_guard = eh.parent_guard;
const logz = eh.logz;
const linux = std.os.linux;

const desktop_prefs = eh.desktop_prefs;
const desktop_icons = eh.desktop_icon_item;
const desktop_entry_types = eh.desktop_entry_types;
const desktop_entries = eh.desktop_entries;
const desktop_menu = eh.desktop_menu;
const desktop_icon_menu = eh.desktop_icon_menu;
const desktop_marquee = eh.desktop_marquee;
const desktop_paint = eh.desktop_paint;
const desktop_app = eh.desktop_app_state;
const desktop_xdg = eh.desktop_xdg_ops;
const desktop_archive = eh.desktop_archive;
const desktop_open_with = eh.desktop_open_with;
const icon_lookup = eh.icon_lookup;
const icon_raster = eh.icon_raster;
const icon_cache = eh.icon_cache;
const app_launch = eh.app_launch;
const xdg_ops = eh.desktop_xdg_ops;
const wlayer = eh.desktop_widgets_layer;
const wdata = eh.desktop_widgets_data;
const wpersist = eh.desktop_widgets_persist;
const wctx = eh.desktop_widgets_ctx;
const wset = eh.widget_settings;
const mpris_mod = eh.mpris_client;
const udisks_mod = eh.udisks;
const weather_mod = eh.weather;
const media_bus = eh.desktop_widgets_media_bus;

// ---------------------------------------------------------------------------
// Perf instrumentation.
//
// `EH_DESKTOP_PERF=1` (or unset — the 5s summary is on while the desktop is
// being profiled; `EH_DESKTOP_PERF=0` silences it) logs one line per window
// with repaint frequency, per-layer phase costs, tick/rescan breakdown and
// input handling cost. Slow events (repaint > 12ms, tick > 20ms, rescan >
// 8ms, motion > 5ms, button > 10ms) are always logged, rate-limited so a
// consistently slow path cannot flood the log.

fn perfNowNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * std.time.ns_per_s +
        @as(u64, @intCast(@max(ts.nsec, 0)));
}

fn perfMs(value_ns: u64) f64 {
    return @as(f64, @floatFromInt(value_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn perfAvgNs(sum_ns: u64, n: u64) f64 {
    return perfMs(sum_ns) / @as(f64, @floatFromInt(@max(n, 1)));
}

/// One line from `/proc/self/task/<tid>/<name>` (thread is always self).
fn procFile(tid: i32, name: []const u8, buf: []u8) []const u8 {
    var pathbuf: [64:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pathbuf, "/proc/self/task/{d}/{s}", .{ tid, name }) catch return "";
    const rc = std.os.linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return "";
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    const n = std.os.linux.read(fd, buf.ptr, buf.len);
    if (std.os.linux.errno(n) != .SUCCESS) return "";
    return std.mem.trimEnd(u8, buf[0..@intCast(n)], "\n");
}

/// Stall watchdog. The 1 s tick is an interval timer, so a healthy main loop
/// beats at least once a second even when fully idle; a longer gap means the
/// main thread is stuck somewhere. Freezes used to leave a silent hole in the
/// log, so this records what the main thread is blocked on — thread state,
/// syscall and kernel wait channel — once per stall interval.
fn stallWatch(d: *Desktop) void {
    var st_buf: [256]u8 = undefined;
    var sc_buf: [256]u8 = undefined;
    var wc_buf: [256]u8 = undefined;
    var last_report_ns: u64 = 0;
    const sec = linux.timespec{ .sec = 1, .nsec = 0 };
    while (!d.watchdog_stop.load(.monotonic)) {
        _ = linux.nanosleep(&sec, null);
        const last = d.beat_ns.load(.monotonic);
        if (last == 0) continue;
        const now = perfNowNs();
        const gap = now -% last;
        if (gap < 5 * std.time.ns_per_s) {
            last_report_ns = 0;
            continue;
        }
        if (last_report_ns != 0 and now -% last_report_ns < 3 * std.time.ns_per_s) continue;
        last_report_ns = now;
        // Thread state letter (R/S/D) lives after the comm field in `stat`.
        var state: u8 = '?';
        const st = procFile(d.main_tid, "stat", &st_buf);
        if (std.mem.lastIndexOfScalar(u8, st, ')')) |p| {
            if (p + 2 < st.len) state = st[p + 2];
        }
        logz.log("perf: STALL {d:.0}ms (no 1s tick) tid={d} state={c} syscall={s} wchan={s} cb={s}", .{
            perfMs(gap),
            d.main_tid,
            state,
            procFile(d.main_tid, "syscall", &sc_buf),
            procFile(d.main_tid, "wchan", &wc_buf),
            @tagName(d.perf.cb),
        });
    }
}

/// Which callback is on the stack when `repaint` runs: gives the summary a
/// "why" split without threading a reason through every call site.
const PerfCb = enum(u8) { none, startup, tick, anim, motion, enter, button, widget_fd, reconf, reload };

/// A repaint only needs the layers that actually changed: hover moves touch
/// icons, marquee frames touch widgets, menu hover touches the menu layer.
/// Repainting all three on every pointer move was the motion-storm cost.
const Layers = packed struct {
    icons: bool = false,
    widgets: bool = false,
    menu: bool = false,
};

const Perf = struct {
    enabled: bool = false,
    cb: PerfCb = .none,

    repaints: u64 = 0,
    repaint_ns: u64 = 0,
    repaint_max_ns: u64 = 0,
    repaint_gap_max_ns: u64 = 0,
    last_repaint_ns: u64 = 0,
    by_cb: [10]u64 = @splat(0),

    icons_ns: u64 = 0,
    icons_max_ns: u64 = 0,
    widgets_ns: u64 = 0,
    widgets_max_ns: u64 = 0,
    menu_ns: u64 = 0,
    menu_max_ns: u64 = 0,
    busy_drops: u64 = 0,

    ticks: u64 = 0,
    tick_ns: u64 = 0,
    tick_max_ns: u64 = 0,
    tick_mpris_ns: u64 = 0,
    tick_mpris_max_ns: u64 = 0,
    tick_widgets_ns: u64 = 0,
    tick_widgets_max_ns: u64 = 0,
    anim_ticks: u64 = 0,
    enters: u64 = 0,
    widget_fd_hits: u64 = 0,
    reconfs: u64 = 0,
    reloads: u64 = 0,

    rescans: u64 = 0,
    rescan_ns: u64 = 0,
    rescan_max_ns: u64 = 0,
    scan_ns: u64 = 0,
    scan_max_ns: u64 = 0,
    sort_ns: u64 = 0,
    sort_max_ns: u64 = 0,
    layout_ns: u64 = 0,
    layout_max_ns: u64 = 0,
    resolve_ns: u64 = 0,
    resolve_max_ns: u64 = 0,

    motions: u64 = 0,
    motion_ns: u64 = 0,
    motion_max_ns: u64 = 0,
    buttons: u64 = 0,
    button_ns: u64 = 0,
    button_max_ns: u64 = 0,

    last_summary_ns: u64 = 0,
    slow_repaint_log_ns: u64 = 0,
    slow_tick_log_ns: u64 = 0,
    slow_rescan_log_ns: u64 = 0,
    slow_motion_log_ns: u64 = 0,
    slow_button_log_ns: u64 = 0,

    const slow_repaint_ns: u64 = 12 * std.time.ns_per_ms;
    const slow_tick_ns: u64 = 20 * std.time.ns_per_ms;
    const slow_rescan_ns: u64 = 8 * std.time.ns_per_ms;
    const slow_motion_ns: u64 = 5 * std.time.ns_per_ms;
    const slow_button_ns: u64 = 10 * std.time.ns_per_ms;
    /// Slow events are rate-limited so a consistently slow path cannot turn
    /// every frame into a log line.
    const slow_log_interval_ns: u64 = 500 * std.time.ns_per_ms;

    fn resetWindow(self: *Perf) void {
        self.repaints = 0;
        self.repaint_ns = 0;
        self.repaint_max_ns = 0;
        self.repaint_gap_max_ns = 0;
        self.by_cb = @splat(0);
        self.icons_ns = 0;
        self.icons_max_ns = 0;
        self.widgets_ns = 0;
        self.widgets_max_ns = 0;
        self.menu_ns = 0;
        self.menu_max_ns = 0;
        self.busy_drops = 0;
        self.ticks = 0;
        self.tick_ns = 0;
        self.tick_max_ns = 0;
        self.tick_mpris_ns = 0;
        self.tick_mpris_max_ns = 0;
        self.tick_widgets_ns = 0;
        self.tick_widgets_max_ns = 0;
        self.anim_ticks = 0;
        self.enters = 0;
        self.widget_fd_hits = 0;
        self.reconfs = 0;
        self.reloads = 0;
        self.rescans = 0;
        self.rescan_ns = 0;
        self.rescan_max_ns = 0;
        self.scan_ns = 0;
        self.scan_max_ns = 0;
        self.sort_ns = 0;
        self.sort_max_ns = 0;
        self.layout_ns = 0;
        self.layout_max_ns = 0;
        self.resolve_ns = 0;
        self.resolve_max_ns = 0;
        self.motions = 0;
        self.motion_ns = 0;
        self.motion_max_ns = 0;
        self.buttons = 0;
        self.button_ns = 0;
        self.button_max_ns = 0;
    }

    /// Rate limiter for slow-path logs: true (and stamps `slot`) when the
    /// last log through this slot is older than `slow_log_interval_ns`.
    fn slowLogAllowed(slot: *u64, now: u64) bool {
        if (now -% slot.* < slow_log_interval_ns) return false;
        slot.* = now;
        return true;
    }
};

const Surf = struct {
    // Icon layer: event-horizon-desktop-shell (blur off in user rules).
    surface: layer.Surface = .{},
    // Pooled buffers: painting into a buffer the compositor still holds
    // shows up as flicker. Heap-pinned: the wl_buffer release listener
    // captures the ShmBuffer address, so the pair must never move.
    shm: *shm_mod.ShmPair = undefined,
    // Widget layer: event-horizon-desktop-widgets (blur on).
    wsurf: layer.Surface = .{},
    wshm: *shm_mod.ShmPair = undefined,
    // Menu layer: event-horizon-desktop-menus (blur on).
    msurf: layer.Surface = .{},
    mshm: *shm_mod.ShmPair = undefined,
    /// True when the menu surface shows an empty frame (avoids recommitting
    /// transparency every repaint; C++ detaches instead — same effect).
    menu_clear: bool = true,
    output: usize = 0,
    output_name: []const u8 = "",
    w: i32 = 0,
    h: i32 = 0,
    // Debounced reconfigure: `onLayerConfigure` only records the latest
    // size here (-1 = none); the settle timer adopts it. See `armReconf`.
    pend_w: i32 = -1,
    pend_h: i32 = -1,

    fn deinit(self: *Surf, gpa: std.mem.Allocator) void {
        self.surface.destroy();
        self.shm.deinit();
        gpa.destroy(self.shm);
        self.wsurf.destroy();
        self.wshm.deinit();
        gpa.destroy(self.wshm);
        self.msurf.destroy();
        self.mshm.deinit();
        gpa.destroy(self.mshm);
        if (self.output_name.len > 0) gpa.free(self.output_name);
    }
};

const Desktop = struct {
    a: *app_mod.App,
    surfs: std.ArrayList(Surf) = .empty,
    prefs_state: desktop_prefs.Prefs = .{},
    ui: desktop_app.AppState = .{},
    // Icon store (paths/names owned by arena, refreshed on rescan).
    arena: std.heap.ArenaAllocator,
    icons: std.ArrayList(desktop_icons.IconItem) = .empty,
    // Menu placement state (one open at a time). menu_x/menu_y is the menu
    // origin, written only when a menu opens. The live pointer lives in
    // ptr_x/ptr_y — never mix them or menus jump and hit tests break.
    menu_x: f64 = 0,
    menu_y: f64 = 0,
    ptr_x: f64 = -1,
    ptr_y: f64 = -1,
    hover_idx: i32 = -1,
    menu_layer: usize = 0,
    menu_hover: i32 = -1,
    menu_press: desktop_menu.Press = .{},
    menu_cascade: desktop_menu.Panel = .main,
    icons_env_disabled: bool = false,
    menu_anchor: i32 = 0,
    menu_sub_x: f64 = 0,
    menu_sub_y: f64 = 0,
    // Measured panel widths (C++ desktopMenuMainWidth / CascadeWidth /
    // iconCtxMenuW / iconCtxCompressCascadeW). Recomputed whenever a menu
    // opens or its cascade changes, then used by paint and hit tests alike.
    menu_w: f64 = 220,
    menu_sub_w: f64 = 220,
    icon_menu_w: f64 = 200,
    compress_w: f64 = 220,
    icon_menu_rows: []desktop_icon_menu.CtxRow = &.{},
    icon_menu_target: i32 = -1,
    icon_press: desktop_icon_menu.IconPress = .{},
    icon_action_names: std.ArrayList([]const u8) = .empty,
    // Mount dialog (C++ mountDialog* state, `desktop_icon_menu.cpp:562-590`
    // open + `:1157+` paint). `ui.mount_dialog_open` is the visible flag the
    // app routing reads; the rest is dialog-local data. Owned strings are
    // gpa'd so a rescan (arena reset) can't dangle them mid-dialog. Card
    // bounds are computed live by `mountBounds` (paint and hit tests share
    // it), so no x/y/w/h fields are stored.
    mount_dlg_layer: usize = 0,
    mount_object_path: []const u8 = "",
    mount_label: []const u8 = "",
    mount_device: []const u8 = "",
    mount_fstype: []const u8 = "",
    mount_uuid: []const u8 = "",
    mount_base: u8 = 0,
    mount_boot: bool = false,
    mount_readonly: bool = false,
    // GNOME Disks sub-options: only take effect while `mount_boot` is on
    // (Disks dims its grid while `User Session Defaults` is on).
    mount_startup: bool = true,
    mount_show_ui: bool = true,
    mount_require_auth: bool = false,
    mount_dropdown_open: bool = false,
    mount_hover_item: i32 = -1,
    mount_arm_item: i32 = -1,
    // Deferred menu action (Mount-fstab / Unmount) executed on the next tick
    // after the menu has fully closed (C++ `mountDialogDeferredKind`).
    mount_deferred: desktop_icon_menu.MountDeferred = .none,
    mount_deferred_path: []const u8 = "",
    // UDisks2 rescans left at ttl 0 after a mount/unmount, so the forked
    // udisksctl gets picked up as soon as it lands (C++ waits on its future).
    udisks_refresh_ticks: u8 = 0,
    selected: i32 = -1,
    press_idx: i32 = -1,
    press_x: f64 = 0,
    press_y: f64 = 0,
    press_moved: bool = false,
    last_click_ms: i64 = -10000,
    last_click_idx: i32 = -1,
    // Embedded widget layer (C++ DesktopApp.widgetHost): widgets live on
    // the desktop surface so they move/scale with it. Heavy feeds (MPRIS,
    // weather) mirror horizon-desktop-widgets.
    wlayer: wlayer.Layer = .{},
    w_inited: bool = false,
    mpris: mpris_mod.Client = undefined,
    mpris_inited: bool = false,
    // UDisks2 drive enumeration (mounted + unmounted). Cached behind a TTL so
    // the 1s rescan tick stays cheap; invalidated after mount/unmount.
    udisks: udisks_mod.Client = undefined,
    udisks_inited: bool = false,
    /// Last drive count written to the log (logs only on change, so the 1s
    /// rescan tick does not spam `EH-logs`).
    logged_drive_count: i32 = -1,
    weather_last_ms: i64 = 0,
    anim_fd: i32 = -1,
    anim_interval_ms: u32 = 0,
    widget_drop_ms: i64 = 0,
    /// Settle timer for layer reconfigures (one fd for the process lifetime;
    /// disarmed by zeroing it_value, never closed mid-run — see `armReconf`).
    reconf_fd: i32 = -1,
    /// Dedicated inotify for the widget state files: `desktop_widgets_layout.txt`
    /// (add / remove / drag) and `desktop_widgets/desktop_widgets.toml`
    /// (per-slot enable + display output). The App's own watchers only report
    /// `*.toml` directly inside the settings root and are not recursive, so
    /// neither file ever reached `onReload` — the layer kept its boot-time
    /// contents until the shell restarted. (Icons looked live for the
    /// opposite reason: the 1s tick rescans them.)
    widget_watch: config.watch.Watcher = .{},
    /// Owned copy of the configured widget output (all instances point at
    /// it after reload so they paint/hit on one display only).
    widget_output: []const u8 = "",
    marquee_sel: std.ArrayList(usize) = .empty,
    undo_paths: std.ArrayList([]const u8) = .empty,
    // Resolved icon art (themed walk, owned bytes + surfaces).
    icons_map: std.StringHashMap(IconArt) = undefined,
    icons_map_init: bool = false,
    // Photo thumbnails by absolute path, LRU cap 48 like C++
    // `kMaxRasterThumbsPerDock` (kept across rescans; eviction only).
    thumbs_map: std.StringHashMap(IconArt) = undefined,
    thumbs_map_init: bool = false,
    thumb_order: std.ArrayList([]const u8) = .empty,
    icon_px: i32 = 48,
    icon_theme: []const u8 = "",
    /// Signature of the icon-layer content at the last rescan: names, paths,
    /// art counts and theme. Ticks repaint icons only when it changes.
    icons_sig: u64 = 0,
    marquee: desktop_marquee.Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    // Perf counters + summary state (see `Perf` above).
    perf: Perf = .{},
    /// Stall watchdog (see `stallWatch`): last 1s-tick beat, main thread id.
    beat_ns: std.atomic.Value(u64) = .init(0),
    watchdog_stop: std.atomic.Value(bool) = .init(false),
    main_tid: i32 = 0,

    const IconArt = struct {
        pixels: []u8 = &.{},
        w: i32 = 0,
        h: i32 = 0,
        surf: ?*cairo.cairo_surface_t = null,
    };

    fn deinit(self: *Desktop) void {
        for (self.surfs.items) |*s| s.deinit(self.a.gpa);
        self.surfs.deinit(self.a.gpa);
        if (self.icon_menu_rows.len > 0) self.a.gpa.free(self.icon_menu_rows);
        for (self.icon_action_names.items) |n| self.a.gpa.free(n);
        self.icon_action_names.deinit(self.a.gpa);
        self.icons.deinit(self.a.gpa);
        self.marquee_sel.deinit(self.a.gpa);
        for (self.undo_paths.items) |p| self.a.gpa.free(p);
        self.undo_paths.deinit(self.a.gpa);
        if (self.widget_output.len > 0) self.a.gpa.free(self.widget_output);
        self.clearIconArt();
        self.clearThumbs();
        if (self.icon_theme.len > 0) self.a.gpa.free(self.icon_theme);
        self.icon_theme = "";
        if (self.w_inited) self.wlayer.deinit();
        if (self.mpris_inited) self.mpris.deinit();
        if (self.udisks_inited) self.udisks.deinit();
        self.closeMountDialog();
        if (self.anim_fd >= 0) _ = linux.close(self.anim_fd);
        if (self.reconf_fd >= 0) _ = linux.close(self.reconf_fd);
        self.widget_watch.close();
        self.arena.deinit();
    }

    fn clearIconArt(self: *Desktop) void {
        if (!self.icons_map_init) return;
        var it = self.icons_map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.surf) |sf| cairo.cairo_surface_destroy(sf);
            if (e.value_ptr.pixels.len > 0) self.a.gpa.free(e.value_ptr.pixels);
            self.a.gpa.free(e.key_ptr.*);
        }
        self.icons_map.clearRetainingCapacity();
    }

    fn clearThumbs(self: *Desktop) void {
        if (!self.thumbs_map_init) return;
        var it = self.thumbs_map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.surf) |sf| cairo.cairo_surface_destroy(sf);
            if (e.value_ptr.pixels.len > 0) self.a.gpa.free(e.value_ptr.pixels);
            self.a.gpa.free(e.key_ptr.*);
        }
        self.thumbs_map.clearRetainingCapacity();
        self.thumb_order.clearRetainingCapacity();
    }

    fn thumbTouch(self: *Desktop, key: []const u8) void {
        // Move the key to the most-recent end of the LRU order.
        for (self.thumb_order.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                _ = self.thumb_order.orderedRemove(i);
                self.thumb_order.append(self.a.gpa, key) catch return;
                return;
            }
        }
    }

    fn thumbEvict(self: *Desktop) void {
        // Cap 48 like C++; drop the least-recently-used entry.
        while (self.thumb_order.items.len >= 48) {
            const old = self.thumb_order.orderedRemove(0);
            if (self.thumbs_map.fetchRemove(old)) |kv| {
                if (kv.value.surf) |sf| cairo.cairo_surface_destroy(sf);
                if (kv.value.pixels.len > 0) self.a.gpa.free(kv.value.pixels);
                self.a.gpa.free(kv.key);
            }
        }
    }

    /// Downscaled photo thumbnail surface for an image file, or null.
    /// `max_px` caps the long side (C++ `clamp(icon_sz*1.25,32,160)`).
    fn thumbFor(self: *Desktop, abs_path: []const u8, max_px: i32) ?*cairo.cairo_surface_t {
        if (!self.thumbs_map_init or abs_path.len == 0) return null;
        if (self.thumbs_map.getPtr(abs_path)) |e| {
            if (self.thumbs_map.getKeyPtr(abs_path)) |kp| self.thumbTouch(kp.*);
            if (e.surf) |sf| return sf;
            return null;
        }
        const gpa = self.a.gpa;
        var img = eh.wp_decode.loadRgba(gpa, abs_path) orelse return null;
        defer img.free(gpa);
        if (img.w <= 0 or img.h <= 0) return null;
        if (@as(i64, img.w) * @as(i64, img.h) > 64 * 1024 * 1024) return null;
        const long: i32 = @max(img.w, img.h);
        if (long <= 0) return null;
        var tw: i32 = img.w;
        var th: i32 = img.h;
        if (long > max_px) {
            tw = @max(1, @divTrunc(img.w * max_px, long));
            th = @max(1, @divTrunc(img.h * max_px, long));
        }
        const out = gpa.alloc(u8, @intCast(tw * th * 4)) catch return null;
        errdefer gpa.free(out);
        // Nearest-neighbor downscale with premultiply for cairo ARGB32.
        var y: i32 = 0;
        while (y < th) : (y += 1) {
            const sy: i32 = @divTrunc(y * img.h, th);
            var x: i32 = 0;
            while (x < tw) : (x += 1) {
                const sx: i32 = @divTrunc(x * img.w, tw);
                const si: usize = @intCast((sy * img.w + sx) * 4);
                const di: usize = @intCast((y * tw + x) * 4);
                const a: u32 = img.pixels[si + 3];
                out[di] = @intCast((@as(u32, img.pixels[si]) * a + 127) / 255);
                out[di + 1] = @intCast((@as(u32, img.pixels[si + 1]) * a + 127) / 255);
                out[di + 2] = @intCast((@as(u32, img.pixels[si + 2]) * a + 127) / 255);
                out[di + 3] = img.pixels[si + 3];
            }
        }
        const sf = cairo.cairo_image_surface_create_for_data(out.ptr, cairo.CAIRO_FORMAT_ARGB32, tw, th, tw * 4);
        if (cairo.cairo_surface_status(sf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(sf);
            gpa.free(out);
            return null;
        }
        self.thumbEvict();
        const owned = gpa.dupe(u8, abs_path) catch {
            cairo.cairo_surface_destroy(sf);
            gpa.free(out);
            return null;
        };
        self.thumbs_map.put(owned, .{ .pixels = out, .w = tw, .h = th, .surf = sf }) catch {
            cairo.cairo_surface_destroy(sf);
            gpa.free(out);
            gpa.free(owned);
            return null;
        };
        self.thumb_order.append(gpa, owned) catch {};
        return sf;
    }

    fn iconArtFor(self: *Desktop, key: []const u8) ?*cairo.cairo_surface_t {
        if (!self.icons_map_init or key.len == 0) return null;
        const e = self.icons_map.getPtr(key) orelse return null;
        if (e.surf) |sf| return sf;
        if (e.pixels.len == 0 or e.w <= 0 or e.h <= 0) return null;
        const sf = cairo.cairo_image_surface_create_for_data(e.pixels.ptr, cairo.CAIRO_FORMAT_ARGB32, e.w, e.h, e.w * 4);
        if (cairo.cairo_surface_status(sf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(sf);
            return null;
        }
        e.surf = sf;
        return sf;
    }

    fn resolveIconArt(self: *Desktop, key: []const u8) void {
        if (!self.icons_map_init or key.len == 0) return;
        if (self.icons_map.getPtr(key) != null) return;
        if (self.icons_map.count() >= 256) return;
        const gpa = self.a.gpa;
        const theme = self.a.loaded.cfg.dock.icon_theme;
        const th = if (theme.len > 0) theme else "hicolor";
        var pixels: []u8 = &.{};
        var w: i32 = 0;
        var h: i32 = 0;
        if (icon_cache.shared()) |ic| {
            if (ic.getOwned(.app, key, self.icon_px)) |o| {
                pixels = gpa.dupe(u8, o.pixels) catch return;
                w = o.w;
                h = o.h;
            }
        }
        if (pixels.len == 0) {
            if (icon_lookup.lookupPixmaps(gpa, key)) |found| {
                defer icon_lookup.freeFound(gpa, found);
                if (found.format == .svg) {
                    if (icon_raster.loadSvg(gpa, found.path, self.icon_px)) |px| {
                        pixels = px.data;
                        w = px.w;
                        h = px.h;
                    }
                } else if (icon_raster.loadPng(gpa, found.path)) |px| {
                    pixels = px.data;
                    w = px.w;
                    h = px.h;
                }
            }
        }
        if (pixels.len == 0) {
            const stem = std.fs.path.stem(key);
            const keys = [_][]const u8{ key, stem };
            const dirs = icon_lookup.dataDirs(gpa, null, self.a.home, null) catch return;
            defer icon_lookup.freeDirs(gpa, dirs);
            for (keys) |k| {
                if (k.len == 0 or pixels.len != 0) continue;
                if (icon_lookup.lookupAny(gpa, self.a.io, dirs, th, k, @intCast(@max(self.icon_px, 1)))) |found| {
                    defer icon_lookup.freeFound(gpa, found);
                    if (found.format == .svg) {
                        if (icon_raster.loadSvg(gpa, found.path, self.icon_px)) |px| {
                            pixels = px.data;
                            w = px.w;
                            h = px.h;
                        }
                    } else if (icon_raster.loadPng(gpa, found.path)) |px| {
                        pixels = px.data;
                        w = px.w;
                        h = px.h;
                    }
                }
            }
        }
        if (pixels.len == 0) return;
        const owned = gpa.dupe(u8, key) catch {
            gpa.free(pixels);
            return;
        };
        self.icons_map.put(owned, .{ .pixels = pixels, .w = w, .h = h }) catch {
            gpa.free(owned);
            gpa.free(pixels);
        };
    }

    /// Identity of what the icon layer currently shows: list contents
    /// (name/path/art key/kind/layer/drive state), resolved-art counts, and
    /// the theme/size the art was rasterized at. The 1s tick repaints icons
    /// only when this changes — road-testing showed the old always-repaint
    /// costing a full-screen clear + commit per output per second.
    fn iconsSignature(self: *Desktop) u64 {
        var h: u64 = 0x9e3779b97f4a7c15;
        h = std.hash.Wyhash.hash(h, self.icon_theme);
        h +%= @as(u64, @intCast(@max(self.icon_px, 0))) *% 3;
        h +%= @as(u64, @intCast(self.icons.items.len)) *% 7919;
        for (self.icons.items) |ic| {
            h = std.hash.Wyhash.hash(h, ic.name);
            h = std.hash.Wyhash.hash(h, ic.desktop_path);
            h = std.hash.Wyhash.hash(h, ic.icon_key);
            h = std.hash.Wyhash.hash(h, ic.drive_device);
            h = std.hash.Wyhash.hash(h, ic.drive_uuid);
            h +%= @as(u64, @intFromEnum(ic.kind)) *% 977;
            h +%= @as(u64, @as(u32, @bitCast(ic.layer))) *% 131;
            if (!ic.drive_mounted) h +%= 1013;
        }
        if (self.icons_map_init) h +%= @as(u64, @intCast(self.icons_map.count())) *% 31;
        if (self.thumbs_map_init) h +%= @as(u64, @intCast(self.thumbs_map.count())) *% 17;
        h +%= if (self.iconsShown()) 2 else 5;
        return h;
    }

    fn resolveAllIcons(self: *Desktop) void {
        // Incremental: resolveIconArt skips keys already cached, so a
        // steady-state rescan costs nothing. Only a size/theme change
        // invalidates the whole map (rasterized at icon_px per theme).
        // Rasterize at the largest output's fit so the cached art downscales
        // (never upscales) on smaller surfaces — sharp across mixed setups.
        const m = self.metricsFit(self.maxFit());
        const px: i32 = @intFromFloat(@round(m.icon_sz));
        const theme = self.a.loaded.cfg.dock.icon_theme;
        if (px != self.icon_px or !std.mem.eql(u8, theme, self.icon_theme)) {
            self.clearIconArt();
            self.icon_px = px;
            const owned = self.a.gpa.dupe(u8, theme) catch null;
            if (self.icon_theme.len > 0) self.a.gpa.free(self.icon_theme);
            self.icon_theme = owned orelse "";
        }
        for (self.icons.items) |ic| self.resolveIconArt(ic.icon_key);
    }

    /// Fit-to-output factor for the desktop icon grid. The cells are authored
    /// for a 1440-tall logical desktop, so a shorter output shrinks them to
    /// match (1440p -> 1.0, 720p -> 0.5); a taller one grows them. Clamped so a
    /// tiny/huge output can't make the grid unusable. Sharpness comes from the
    /// HiDPI buffer scale — this only changes the logical grid size.
    fn fitForH(h: i32) f64 {
        if (h <= 0) return 1.0;
        return std.math.clamp(@as(f64, @floatFromInt(h)) / 1440.0, 0.5, 2.0);
    }

    /// Base icon metrics scaled by a fit factor (see `fitForH`).
    fn metricsFit(self: *Desktop, fit: f64) desktop_prefs.Metrics {
        const b = desktop_prefs.metricsFor(self.prefs_state.size);
        if (fit == 1.0) return b;
        return .{
            .icon_sz = b.icon_sz * fit,
            .cell_w = b.cell_w * fit,
            .cell_h = b.cell_h * fit,
            .fit = fit,
        };
    }

    /// Largest fit across every output. Icon art is rasterized once at this
    /// size (`resolveAllIcons`) so it downscales — never upscales — on each
    /// surface in `paintIcon`, staying sharp on mixed-resolution setups.
    fn maxFit(self: *Desktop) f64 {
        var f: f64 = 1.0;
        for (self.surfs.items) |*s| f = @max(f, fitForH(s.h));
        return f;
    }

    /// Fit of the focused (menu) output — pointer hit-tests and drags run
    /// against that layer's grid, so they must match its layout.
    fn menuFit(self: *Desktop) f64 {
        if (self.menu_layer < self.surfs.items.len) return fitForH(self.surfs.items[self.menu_layer].h);
        return 1.0;
    }

    /// Interaction metrics (hit-tests, drags, menus) — sized to the focused
    /// output's grid.
    fn metrics(self: *Desktop) desktop_prefs.Metrics {
        return self.metricsFit(self.menuFit());
    }

    /// One icon cell: selection plate, resolved glyph (or a fallback
    /// folder/file mark), and the centered single-line label.
    fn paintIcon(self: *Desktop, cr: ?*cairo.cairo_t, ic: desktop_icons.IconItem, idx: usize, m: desktop_prefs.Metrics) void {
        const c = cr orelse return;
        const x = ic.cell_x;
        const y = ic.cell_y;
        // Plates only for hover / press / selection, like paint_icon_item.
        // An always-on plate is the "ugly square" behind every icon.
        const ii: i32 = @intCast(idx);
        const hovered = self.hover_idx == ii and self.press_idx < 0;
        const pressed = self.press_idx == ii;
        // Unmounted drives paint their glyph at reduced opacity
        // (`paint_icon_item`, `:786` + `:814` + `:889`).
        const dim = ic.kind == .drive and !ic.drive_mounted;
        var marquee_sel = false;
        for (self.marquee_sel.items) |mi| {
            if (mi == idx) {
                marquee_sel = true;
                break;
            }
        }
        if (hovered) {
            cairo.cairo_save(c);
            cairo.cairo_set_source_rgba(c, 0.25, 0.45, 0.85, 0.15);
            cairo.cairo_rectangle(c, x + 1, y + 1, m.cell_w - 2, m.cell_h - 2);
            cairo.cairo_fill(c);
            cairo.cairo_restore(c);
        }
        if (pressed or marquee_sel or ii == self.selected) {
            cairo.cairo_save(c);
            cairo.cairo_set_source_rgba(c, 0.22, 0.42, 0.82, 0.2);
            cairo.cairo_rectangle(c, x + 1, y + 1, m.cell_w - 2, m.cell_h - 2);
            cairo.cairo_fill(c);
            cairo.cairo_set_source_rgba(c, 0.4, 0.62, 0.98, 0.65);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_rectangle(c, x + 1.5, y + 1.5, m.cell_w - 3, m.cell_h - 3);
            cairo.cairo_stroke(c);
            cairo.cairo_restore(c);
        }
        // Glyph: photo thumbnails first (files only), then themed art for
        // every kind, then the fallback mark. Each stage sets painted.
        // Unmounted drives draw into a group so the whole glyph can be
        // composited at reduced opacity below.
        const gsz = m.icon_sz;
        const gx = x + (m.cell_w - gsz) * 0.5;
        const gy = y + 6.0;
        if (dim) {
            cairo.cairo_save(c);
            const dim_pad = gsz * 0.25 + 4;
            cairo.cairo_rectangle(c, gx - dim_pad, gy - dim_pad, gsz + dim_pad * 2, gsz + dim_pad * 2);
            cairo.cairo_clip(c);
            cairo.cairo_push_group(c);
        }
        var painted = false;
        if (ic.kind == .file and desktop_icons.fileWantsRasterThumbnail(ic.desktop_path)) {
            const thumb_px: i32 = @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(gsz * 1.25))), 32, 160));
            if (self.thumbFor(ic.desktop_path, thumb_px)) |tsf| {
                const tw: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(tsf));
                const th: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(tsf));
                if (tw > 0 and th > 0) {
                    const k = @min(gsz / tw, gsz / th);
                    cairo.cairo_save(c);
                    cairo.cairo_translate(c, gx + (gsz - tw * k) * 0.5, gy + (gsz - th * k) * 0.5);
                    cairo.cairo_scale(c, k, k);
                    cairo.cairo_set_source_surface(c, tsf, 0, 0);
                    cairo.cairo_paint(c);
                    cairo.cairo_restore(c);
                    painted = true;
                }
            }
        }
        if (!painted) {
            if (self.iconArtFor(ic.icon_key)) |sf| {
                const sw: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(sf));
                const sh: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(sf));
                if (sw > 0 and sh > 0) {
                    const k = @min(gsz / sw, gsz / sh);
                    cairo.cairo_save(c);
                    cairo.cairo_translate(c, gx + (gsz - sw * k) * 0.5, gy + (gsz - sh * k) * 0.5);
                    cairo.cairo_scale(c, k, k);
                    cairo.cairo_set_source_surface(c, sf, 0, 0);
                    cairo.cairo_paint(c);
                    cairo.cairo_restore(c);
                    painted = true;
                }
            }
        }
        if (!painted) {
            // Fallback mark: folder triangle vs file sheet.
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.75);
            cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
            cairo.cairo_set_font_size(c, gsz * 0.6);
            const mark: [*c]const u8 = if (ic.kind == .folder or ic.kind == .drive) "▤" else "▦";
            var te: cairo.cairo_text_extents_t = undefined;
            cairo.cairo_text_extents(c, mark, &te);
            cairo.cairo_move_to(c, x + (m.cell_w - te.x_advance) * 0.5, gy + gsz * 0.7);
            cairo.cairo_show_text(c, mark);
        }
        if (dim) {
            cairo.cairo_pop_group_to_source(c);
            cairo.cairo_paint_with_alpha(c, 0.6);
            cairo.cairo_restore(c);
        }
        // Label: single centered line, truncated to fit. The font, the
        // per-character budget and the baseline are all authored in natural
        // px, so they scale by the metrics' fit — the glyph above already
        // scales through `gsz`.
        var lbuf: [64]u8 = undefined;
        const max_chars: usize = @intCast(@max(4, @min(24, @as(i32, @intFromFloat(m.cell_w / (7.0 * m.fit))))));
        const nl = @min(ic.name.len, @min(lbuf.len - 1, max_chars));
        @memcpy(lbuf[0..nl], ic.name[0..nl]);
        lbuf[nl] = 0;
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, 12.0 * m.fit);
        var te: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
        cairo.cairo_text_extents(c, lbuf[0..nl :0], &te);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.95);
        cairo.cairo_move_to(c, x + (m.cell_w - te.x_advance) * 0.5, y + m.cell_h - 8.0 * m.fit);
        cairo.cairo_show_text(c, lbuf[0..nl :0]);
    }

    /// Rounded-rect path at (x,y,w,h) with radius r — the C++ `Box` path
    /// builder (four quarter arcs, or a plain rect when r rounds away).
    fn cardPath(c: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r_in: f64) void {
        const cr = c orelse return;
        const r = @min(r_in, @min(w, h) * 0.5);
        if (r > 0) {
            cairo.cairo_new_path(cr);
            cairo.cairo_arc(cr, x + r, y + r, r, std.math.pi, 1.5 * std.math.pi);
            cairo.cairo_arc(cr, x + w - r, y + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
            cairo.cairo_arc(cr, x + w - r, y + h - r, r, 0.0, 0.5 * std.math.pi);
            cairo.cairo_arc(cr, x + r, y + h - r, r, 0.5 * std.math.pi, std.math.pi);
            cairo.cairo_close_path(cr);
        } else {
            cairo.cairo_rectangle(cr, x, y, w, h);
        }
    }

    /// Menu card body shared by both menus: a faithful port of the C++
    /// `m3::Box` glassy paint fed by `paint_glass_card` (chrome dock fill
    /// x0.35 at 0.78 alpha, radius 8). Soft drop shadow, translucent fill,
    /// milky white wash, rim gradient stroke (bright along the bottom) and
    /// faint outer glow. Translucent so the Hyprland blur layerrule on the
    /// menus namespace has something to blur — an opaque card hides it.
    fn menuBody(self: *Desktop, cr: ?*cairo.cairo_t, mx: f64, my: f64, mw: f64, mh: f64) void {
        const radius: f64 = desktop_menu.corner_radius * self.menuUs();
        self.cardBody(cr, mx, my, mw, mh, radius);
    }

    /// `menuBody` with an explicit radius (the mount dialog rounds at 10
    /// rather than the menu's 8 — `paint_mount_dialog` `radius = 10 * us`).
    fn cardBody(self: *Desktop, cr: ?*cairo.cairo_t, mx: f64, my: f64, mw: f64, mh: f64, radius: f64) void {
        const c = cr orelse return;
        const ov = self.menuOv();
        const chrome = eh.widget_chrome_colors.of(&self.a.loaded.cfg);
        const op: f64 = 0.78 * std.math.clamp(ov, 0.0, 1.0);
        cairo.cairo_save(c);

        // Soft drop shadow (Hyprland handles blur; offset fill reads as lift).
        cardPath(c, mx, my + 2.0, mw, mh, radius);
        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.22);
        cairo.cairo_fill(c);

        // Base fill.
        cardPath(c, mx, my, mw, mh, radius);
        cairo.cairo_set_source_rgba(c, chrome.dock_fill.r * 0.35, chrome.dock_fill.g * 0.35, chrome.dock_fill.b * 0.35, op);
        cairo.cairo_fill(c);

        // Milky lift — faint white wash so the fill reads frosted.
        cairo.cairo_save(c);
        cardPath(c, mx, my, mw, mh, radius);
        cairo.cairo_clip(c);
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.07 * op);
        cairo.cairo_rectangle(c, mx, my, mw, mh);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);

        // Edge light — inner 1px stroke, soft on top, bright along the bottom.
        const rim = cairo.cairo_pattern_create_linear(mx, my, mx, my + mh);
        cairo.cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.12 * op);
        cairo.cairo_pattern_add_color_stop_rgba(rim, 0.5, 1.0, 1.0, 1.0, 0.05 * op);
        cairo.cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.42 * op);
        cairo.cairo_set_source(c, rim);
        cairo.cairo_set_line_width(c, 1.0);
        cardPath(c, mx + 1.0, my + 1.0, mw - 2.0, mh - 2.0, radius - 1.0);
        cairo.cairo_stroke(c);
        cairo.cairo_pattern_destroy(rim);

        // Faint outer glow so the edge lifts off the wallpaper.
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.08 * op);
        cairo.cairo_set_line_width(c, 1.0);
        cardPath(c, mx + 0.5, my + 0.5, mw - 1.0, mh - 1.0, radius);
        cairo.cairo_stroke(c);

        cairo.cairo_restore(c);
    }

    /// `dock_ui_scale` — every menu dimension, font and offset scales by it
    /// (C++ multiplies each `k*` constant by `us`).
    fn menuUs(self: *Desktop) f64 {
        return eh.dock_widgets.uiScale(&self.a.loaded.cfg);
    }

    /// `overlay_surface_alpha_scale(..., DesktopContextMenu)` — the card,
    /// row highlights, separators and checks all thin out with it.
    fn menuOv(self: *Desktop) f64 {
        return eh.overlay.scale(&self.a.loaded.cfg.appearance, .desktop_menu);
    }

    /// Label advance in Inter at `font_px`, measured on a throwaway A8
    /// surface (C++ `cairo_utf8_advance` / `measure_panel_width`).
    fn textAdvance(label: []const u8, font_px: f64) f64 {
        const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_A8, 1, 1);
        defer cairo.cairo_surface_destroy(surf);
        const cr = cairo.cairo_create(surf);
        defer cairo.cairo_destroy(cr);
        cairo.cairo_select_font_face(cr, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(cr, font_px);
        var buf: [256]u8 = undefined;
        const n = @min(label.len, buf.len - 1);
        @memcpy(buf[0..n], label[0..n]);
        buf[n] = 0;
        var te: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
        cairo.cairo_text_extents(cr, buf[0..n :0], &te);
        return te.x_advance;
    }

    /// Workspace panel width for `panel` (C++ `measure_panel_width`, `:52-79`):
    /// widest non-separator row of `textLeft(= pad + 22*us) + advance + pad`,
    /// chevron rows add the chevron gap + `›`, floored at `min_menu_w*us`,
    /// plus the right pad.
    fn wsPanelWidth(self: *Desktop, panel: desktop_menu.Panel) f64 {
        const us = self.menuUs();
        const pad = desktop_menu.pad * us;
        const text_left = pad + desktop_menu.text_left_offset * us;
        var maxw = desktop_menu.min_menu_w * us;
        const n = desktop_menu.rowCount(panel);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const row: i32 = @intCast(i);
            if (desktop_menu.isSeparator(panel, row)) continue;
            const label = desktop_menu.rowLabel(panel, row);
            if (label.len == 0) continue;
            const adv = textAdvance(label, 13.0 * us);
            var row_w = text_left + adv + pad;
            if (desktop_menu.isSubmenuChevron(panel, row)) {
                const chev = textAdvance("›", 14.0 * us);
                row_w = text_left + adv + desktop_menu.chevron_gap * us + chev + pad;
            }
            maxw = @max(maxw, row_w);
        }
        return maxw + desktop_menu.menu_right_pad * us;
    }

    /// Icon context menu width (C++ `refresh_icon_menu_width`, `:380-409`):
    /// rows measure `pad + advance + pad` (labels sit at `pad` — no check
    /// column), compress-submenu rows add chevron gap + `›`.
    fn iconMenuWidth(self: *Desktop) f64 {
        const us = self.menuUs();
        const pad = desktop_icon_menu.pad * us;
        var maxw = desktop_icon_menu.min_icon_menu_w * us;
        for (self.icon_menu_rows) |r| {
            if (desktop_icon_menu.isSep(r)) continue;
            const label = self.iconCtxLabel(r);
            if (label.len == 0) continue;
            const adv = textAdvance(label, 13.0 * us);
            var row_w = pad + adv + pad;
            if (desktop_icon_menu.isCompressSubmenu(r)) {
                const chev = textAdvance("›", 14.0 * us);
                row_w = pad + adv + desktop_menu.chevron_gap * us + chev + pad;
            }
            maxw = @max(maxw, row_w);
        }
        return maxw + desktop_icon_menu.menu_right_pad * us;
    }

    /// Compress cascade width (C++ `refresh_compress_cascade_width`, `:69-90`).
    fn compressWidth(self: *Desktop) f64 {
        const us = self.menuUs();
        const pad = desktop_icon_menu.pad * us;
        var maxw = desktop_icon_menu.min_compress_w * us;
        for (0..desktop_icon_menu.compress_sub_rows) |k| {
            const adv = textAdvance(desktop_icon_menu.compressSubLabel(k), 13.0 * us);
            maxw = @max(maxw, pad + desktop_menu.text_left_offset * us + adv + pad);
        }
        return maxw + desktop_icon_menu.menu_right_pad * us;
    }

    /// One row of a menu panel: hover pill, label, optional chevron — the
    /// C++ `paint_menu_panel` row pass (`:413-477`), scaled by `us` and
    /// dimmed by the overlay alpha `ov`. `text_x` is the label offset from
    /// the card's left edge (workspace panels use `pad + 22*us` for the
    /// check column, icon panels plain `pad`).
    fn menuRow(
        self: *Desktop,
        cr: ?*cairo.cairo_t,
        mx: f64,
        ry: f64,
        mw: f64,
        label: []const u8,
        hovered: bool,
        dim: bool,
        text_x: f64,
        chevron: bool,
    ) void {
        const c = cr orelse return;
        const us = self.menuUs();
        const ov = self.menuOv();
        const rh = desktop_menu.row_h * us;
        if (hovered) {
            // Highlight pill: slate fill, inset 2*us, rounded hl radius.
            cairo.cairo_set_source_rgba(c, 0.18, 0.22, 0.3, 0.85 * ov);
            eh.cairo_helpers.roundedRect(c, mx + 2.0 * us, ry, mw - 4.0 * us, rh, desktop_menu.hl_radius * us);
            cairo.cairo_fill(c);
        }
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, 13.0 * us);
        if (dim)
            cairo.cairo_set_source_rgba(c, 0.45, 0.46, 0.48, 0.75)
        else
            cairo.cairo_set_source_rgba(c, 0.92, 0.93, 0.95, 0.95);
        cairo.cairo_move_to(c, mx + text_x, ry + rh * 0.72);
        var lbuf: [256]u8 = undefined;
        const n = @min(label.len, lbuf.len - 1);
        @memcpy(lbuf[0..n], label[0..n]);
        lbuf[n] = 0;
        if (n > 0) cairo.cairo_show_text(c, lbuf[0..n :0]);
        if (chevron) {
            // `›` at 14*us, right-aligned to `mw - pad - 14`, on the same
            // baseline and in the row's own colour (C++ keeps the source).
            cairo.cairo_set_font_size(c, 14.0 * us);
            cairo.cairo_move_to(c, mx + mw - desktop_menu.pad * us - 14.0 * us, ry + rh * 0.72);
            cairo.cairo_show_text(c, "›");
        }
    }

    /// Separator rule (`:432-441`): slate hairline across `pad .. mw - pad`
    /// at the row's mid-height.
    fn menuSep(cr: ?*cairo.cairo_t, mx: f64, ry: f64, mw: f64, us: f64, ov: f64) void {
        const rh = desktop_menu.row_h * us;
        desktop_paint.paintMenuSeparator(
            cr,
            mx + desktop_menu.pad * us,
            mx + mw - desktop_menu.pad * us,
            ry + rh * 0.5,
            ov,
        );
    }

    /// Workspace menu: main panel plus the View/SortBy/New cascade. Widths
    /// come from the measured panel widths (C++ `refresh_desktop_menu_widths`).
    fn paintDesktopMenu(self: *Desktop, cr: ?*cairo.cairo_t) void {
        const us = self.menuUs();
        const ov = self.menuOv();
        const mw = self.menu_w;
        const rows = desktop_menu.rowCount(.main);
        const mh = desktop_menu.menuHeight(.main, us);
        self.menuBody(cr, self.menu_x, self.menu_y, mw, mh);
        const text_x = (desktop_menu.pad + desktop_menu.text_left_offset) * us;
        var i: usize = 0;
        while (i < rows) : (i += 1) {
            const ry = self.menu_y + desktop_menu.pad * us + @as(f64, @floatFromInt(i)) * desktop_menu.row_h * us;
            const row: i32 = @intCast(i);
            if (desktop_menu.isSeparator(.main, row)) {
                menuSep(cr, self.menu_x, ry, mw, us, ov);
                continue;
            }
            const label = desktop_menu.rowLabel(.main, row);
            const dim = desktop_menu.isRowDisabled(.main, row, self.undo_paths.items.len == 0, self.marquee_sel.items.len == 0);
            const hov = row == self.menu_press.hover_main and !dim;
            self.menuRow(cr, self.menu_x, ry, mw, label, hov, dim, text_x, desktop_menu.isSubmenuChevron(.main, row));
        }
        if (self.menu_cascade == .main) return;
        const sw = self.menu_sub_w;
        const sh = desktop_menu.menuHeight(self.menu_cascade, us);
        self.menuBody(cr, self.menu_sub_x, self.menu_sub_y, sw, sh);
        const n = desktop_menu.rowCount(self.menu_cascade);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const ry = self.menu_sub_y + desktop_menu.pad * us + @as(f64, @floatFromInt(j)) * desktop_menu.row_h * us;
            const row: i32 = @intCast(j);
            if (desktop_menu.isSeparator(self.menu_cascade, row)) {
                menuSep(cr, self.menu_sub_x, ry, sw, us, ov);
                continue;
            }
            const label = desktop_menu.rowLabel(self.menu_cascade, row);
            const hov = row == self.menu_press.hover_sub;
            self.menuRow(cr, self.menu_sub_x, ry, sw, label, hov, false, text_x, false);
            const checked = switch (self.menu_cascade) {
                .view => desktop_menu.viewCheck(row, self.prefs_state.icons_visible, self.prefs_state.size),
                .sort_by => desktop_menu.sortCheck(row, self.prefs_state.arrangement, self.prefs_state.sort),
                else => false,
            };
            // Check mark sits in the 22*us column at pad, +6*us down
            // (`draw_check`).
            if (checked) desktop_paint.paintCheck(cr, self.menu_sub_x + desktop_menu.pad * us, ry + 6.0 * us, us, ov);
        }
    }

    /// Icon context menu rows with working-action labels.
    fn iconCtxLabel(self: *Desktop, r: desktop_icon_menu.CtxRow) []const u8 {
        return switch (r.kind) {
            .open => "Open",
            .open_with => "Open With",
            .desktop_action => if (r.action_index < self.icon_action_names.items.len)
                self.icon_action_names.items[r.action_index]
            else
                "Action",
            .open_location => "Open file location",
            .run_elevated => "Run as administrator",
            .pin_start => "Pin to Start menu",
            .pin_taskbar => "Pin to Dock",
            .cut => "Cut",
            .copy => "Copy",
            .create_shortcut => "Create shortcut",
            .delete => "Delete",
            .rename => "Rename",
            .properties => "Properties",
            .extract_archive => "Extract to folder",
            .compress_submenu => "Compress",
            .compress_zip => "Compress to ZIP",
            .compress_tar_gz => "Compress to tar.gz",
            .compress_tar => "Compress to tar",
            .compress_7z => "Compress to 7z",
            .mount => "Mount",
            .unmount => "Unmount",
            .empty_trash => "Empty Trash",
            .separator, .separator2 => "",
        };
    }

    fn paintIconMenuRows(self: *Desktop, cr: ?*cairo.cairo_t) void {
        const us = self.menuUs();
        const ov = self.menuOv();
        const mw = self.icon_menu_w;
        const rows = self.icon_menu_rows.len;
        const mh = desktop_icon_menu.menuHeight(rows, us);
        self.menuBody(cr, self.menu_x, self.menu_y, mw, mh);
        // Icon rows carry no check column: labels sit at plain `pad`.
        const text_x = desktop_icon_menu.pad * us;
        for (self.icon_menu_rows, 0..) |r, i| {
            const ry = self.menu_y + desktop_icon_menu.pad * us + @as(f64, @floatFromInt(i)) * desktop_icon_menu.row_h * us;
            if (desktop_icon_menu.isSep(r)) {
                menuSep(cr, self.menu_x, ry, mw, us, ov);
                continue;
            }
            const hov = @as(i32, @intCast(i)) == self.icon_press.hover_main;
            self.menuRow(
                cr,
                self.menu_x,
                ry,
                mw,
                self.iconCtxLabel(r),
                hov,
                false,
                text_x,
                desktop_icon_menu.isCompressSubmenu(r),
            );
        }
        if (!self.icon_press.cascade_open) return;
        const sw = self.compress_w;
        const sh = desktop_icon_menu.menuHeight(desktop_icon_menu.compress_sub_rows, us);
        self.menuBody(cr, self.menu_sub_x, self.menu_sub_y, sw, sh);
        for (0..desktop_icon_menu.compress_sub_rows) |k| {
            const ry = self.menu_sub_y + desktop_icon_menu.pad * us + @as(f64, @floatFromInt(k)) * desktop_icon_menu.row_h * us;
            const hov = @as(i32, @intCast(k)) == self.icon_press.hover_compress;
            self.menuRow(cr, self.menu_sub_x, ry, sw, desktop_icon_menu.compressSubLabel(k), hov, false, text_x, false);
        }
    }

    /// `cairo_move_to` + `cairo_show_text` from a borrowed slice. Cairo wants
    /// a NUL-terminated pointer, so the copy lives only for the call.
    fn showText(c: ?*cairo.cairo_t, x: f64, y: f64, text: []const u8) void {
        const cr = c orelse return;
        var buf: [1024]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        cairo.cairo_move_to(cr, x, y);
        if (n > 0) cairo.cairo_show_text(cr, buf[0..n :0]);
    }

    /// `cairo_text_extents` against the cr's currently selected font.
    fn textExtents(cr: ?*cairo.cairo_t, text: []const u8) cairo.cairo_text_extents_t {
        var te: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
        const c = cr orelse return te;
        var buf: [1024]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        if (n > 0) cairo.cairo_text_extents(c, buf[0..n :0], &te);
        return te;
    }

    /// C++ `paint_radio` (`desktop_icon_menu.cpp:1107-1127`): hover halo, then
    /// a filled disc when selected or a hollow ring otherwise.
    fn paintRadio(c: ?*cairo.cairo_t, x: f64, y: f64, us: f64, selected: bool, hover: bool) void {
        const cr = c orelse return;
        const cx = @floor(x) + 12.5 * us;
        const cy = @floor(y) + 12.5 * us;
        const ri: f64 = 6.0 * us;
        if (hover) {
            cairo.cairo_set_source_rgba(cr, 0.25, 0.45, 0.85, 0.3);
            cairo.cairo_arc(cr, cx, cy, ri + 3.0 * us, 0, 2.0 * std.math.pi);
            cairo.cairo_fill(cr);
        }
        if (selected) {
            cairo.cairo_set_source_rgba(cr, 0.3, 0.55, 0.95, 0.95);
            cairo.cairo_arc(cr, cx, cy, ri - 2.0 * us, 0, 2.0 * std.math.pi);
        } else {
            cairo.cairo_set_source_rgba(cr, 0.35, 0.38, 0.42, 0.5);
            cairo.cairo_arc(cr, cx, cy, ri - 1.0 * us, 0, 2.0 * std.math.pi);
        }
        cairo.cairo_fill(cr);
    }

    /// C++ `paint_checkbox` (`:1129-1155`): 14*us rounded box — tinted fill +
    /// check when on, hollow ring when off.
    fn paintCheckbox(c: ?*cairo.cairo_t, x: f64, y: f64, us: f64, checked: bool, hover: bool) void {
        const cr = c orelse return;
        const bx = @floor(x) + 5.5 * us;
        const by = @floor(y) + 8.5 * us;
        const s: f64 = 14.0 * us;
        if (hover) {
            cairo.cairo_set_source_rgba(cr, 0.25, 0.45, 0.85, 0.3);
            eh.cairo_helpers.roundedRect(cr, bx - 2.0 * us, by - 2.0 * us, s + 3.0 * us, s + 3.0 * us, 4.0 * us);
            cairo.cairo_fill(cr);
        }
        if (checked) {
            cairo.cairo_set_source_rgba(cr, 0.3, 0.55, 0.95, 0.3);
            eh.cairo_helpers.roundedRect(cr, bx, by, s - 1.0 * us, s - 1.0 * us, 3.0 * us);
            cairo.cairo_fill(cr);
            cairo.cairo_set_source_rgba(cr, 0.3, 0.55, 0.95, 0.95);
            cairo.cairo_set_line_width(cr, 2.0);
            cairo.cairo_move_to(cr, bx + 3.0 * us, by + 7.0 * us);
            cairo.cairo_line_to(cr, bx + 7.0 * us, by + 11.0 * us);
            cairo.cairo_line_to(cr, bx + 12.0 * us, by + 4.0 * us);
            cairo.cairo_stroke(cr);
        } else {
            cairo.cairo_set_source_rgba(cr, 0.35, 0.38, 0.42, 0.4);
            eh.cairo_helpers.roundedRect(cr, bx, by, s - 1.0 * us, s - 1.0 * us, 3.0 * us);
            cairo.cairo_fill(cr);
        }
    }

    /// Port of C++ `paint_mount_dialog` (`desktop_icon_menu.cpp:1157-1311`),
    /// restyled GNOME Disks-like: no full-layer dim (just the glass card, like
    /// every other menu — the dialog still claims all pointer input while
    /// open), then the title, the drive identity rows (device / filesystem /
    /// UUID), the mount-point combo with its open list, the "Mount at boot"
    /// master with the Disks sub-options (startup / show-in-UI / auth, dimmed
    /// while the master is off) plus "Read-only", and the Mount/Cancel
    /// buttons. Every item box comes from `icon_menu.mountItemRect`, so paint
    /// and `mountHit` cannot drift.
    fn paintMountDialog(self: *Desktop, cr: ?*cairo.cairo_t) void {
        const c = cr orelse return;
        if (!self.ui.mount_dialog_open) return;
        const us = self.menuUs();
        const b = self.mountBounds();
        const chrome = eh.widget_chrome_colors.of(&self.a.loaded.cfg);
        const user = mountUser();
        const lab = self.mount_label;

        // The three mount-point candidates (`compute_mount_path` `:672-682`).
        var c0: [520]u8 = undefined;
        var c1: [520]u8 = undefined;
        var c2: [520]u8 = undefined;
        const cand = [_][]const u8{
            std.fmt.bufPrint(&c0, "/run/media/{s}/{s}", .{ user, lab }) catch "",
            std.fmt.bufPrint(&c1, "/media/{s}", .{lab}) catch "",
            std.fmt.bufPrint(&c2, "/mnt/{s}", .{lab}) catch "",
        };

        cairo.cairo_save(c);

        // Glass card only — no screen-wide dim. The dialog is modal through
        // input routing (motion/press/release all return early while it is
        // open), so darkening the whole layer just reads as a huge background.
        self.cardBody(c, b.x, b.y, b.w, b.h, 10.0 * us);

        // Title "Mount Drive" (bold 15).
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
        cairo.cairo_set_font_size(c, 15.0 * us);
        cairo.cairo_set_source_rgba(c, 0.92, 0.93, 0.95, 1.0);
        showText(c, b.x + 16 * us, b.y + 24 * us, "Mount Drive");

        // Quoted label (13).
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, 13.0 * us);
        cairo.cairo_set_source_rgba(c, 0.75, 0.78, 0.82, 0.9);
        var dl: [540]u8 = undefined;
        const dl_txt = std.fmt.bufPrint(&dl, "\"{s}\"", .{lab}) catch lab;
        showText(c, b.x + 16 * us, b.y + 46 * us, dl_txt);

        // Drive identity rows, GNOME Disks "Details"-style (12px key/value).
        cairo.cairo_set_font_size(c, 12.0 * us);
        const dev_txt: []const u8 = if (self.mount_device.len > 0) self.mount_device else "—";
        const fs_txt: []const u8 = if (self.mount_fstype.len > 0) self.mount_fstype else "auto";
        const uuid_txt: []const u8 = if (self.mount_uuid.len > 0) self.mount_uuid else "—";
        const info = [_]struct { key: []const u8, val: []const u8 }{
            .{ .key = "Device", .val = dev_txt },
            .{ .key = "Filesystem", .val = fs_txt },
            .{ .key = "UUID", .val = uuid_txt },
        };
        for (info, 0..) |kv, i| {
            const iy = b.y + (70.0 + 20.0 * @as(f64, @floatFromInt(i))) * us;
            cairo.cairo_set_source_rgba(c, 0.65, 0.68, 0.72, 0.85);
            showText(c, b.x + 16 * us, iy, kv.key);
            cairo.cairo_set_source_rgba(c, 0.85, 0.87, 0.90, 1.0);
            showText(c, b.x + 116 * us, iy, kv.val);
        }

        // "Mount point:" hint (12).
        cairo.cairo_set_font_size(c, 12.0 * us);
        cairo.cairo_set_source_rgba(c, 0.65, 0.68, 0.72, 0.85);
        showText(c, b.x + 16 * us, b.y + 134 * us, "Mount point:");

        // Combo box: selected candidate + chevron.
        const combo = desktop_icon_menu.mountItemRect(desktop_icon_menu.mount_item_combo, b.x, b.y, b.w, self.mount_dropdown_open, us);
        const box_hov = self.mount_hover_item == desktop_icon_menu.mount_item_combo;
        cairo.cairo_set_source_rgba(c, if (box_hov) 0.25 else 0.15, if (box_hov) 0.28 else 0.18, if (box_hov) 0.35 else 0.24, 0.85);
        eh.cairo_helpers.roundedRect(c, combo.x, combo.y, combo.w, combo.h, 4.0 * us);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, chrome.outline.r, chrome.outline.g, chrome.outline.b, 0.25);
        cairo.cairo_set_line_width(c, 1.0);
        eh.cairo_helpers.roundedRect(c, combo.x + 0.5 * us, combo.y + 0.5 * us, combo.w - 1.0 * us, combo.h - 1.0 * us, 3.5 * us);
        cairo.cairo_stroke(c);
        cairo.cairo_set_source_rgba(c, 0.85, 0.87, 0.90, 1.0);
        showText(c, combo.x + 10 * us, combo.y + 18 * us, cand[self.mount_base]);

        const chev: []const u8 = if (self.mount_dropdown_open) "▴" else "▾";
        cairo.cairo_set_font_size(c, 10.0 * us);
        cairo.cairo_set_source_rgba(c, 0.6, 0.65, 0.7, 0.8);
        const ce = textExtents(c, chev);
        showText(c, combo.x + combo.w - 10.0 * us - ce.x_advance, combo.y + 18 * us, chev);
        cairo.cairo_set_font_size(c, 12.0 * us);

        // Open list: three radio rows over a slightly more opaque panel.
        if (self.mount_dropdown_open) {
            const list_top = combo.y + combo.h;
            const list_h = 3.0 * desktop_icon_menu.mount_row_h * us;
            cairo.cairo_set_source_rgba(c, 0.15, 0.18, 0.24, 0.95);
            eh.cairo_helpers.roundedRect(c, combo.x, list_top, combo.w, list_h, 4.0 * us);
            cairo.cairo_fill(c);
            for (0..3) |i| {
                const row = desktop_icon_menu.mountItemRect(@intCast(i + 1), b.x, b.y, b.w, true, us);
                const sel = self.mount_base == i;
                const hov = self.mount_hover_item == @as(i32, @intCast(i + 1));
                if (hov) {
                    cairo.cairo_set_source_rgba(c, 0.25, 0.45, 0.85, 0.25);
                    cairo.cairo_rectangle(c, row.x + 2 * us, row.y + 1 * us, row.w - 4 * us, row.h - 2 * us);
                    cairo.cairo_fill(c);
                }
                paintRadio(c, row.x, row.y, us, sel, false);
                cairo.cairo_set_source_rgba(c, 0.92, 0.93, 0.95, 1.0);
                showText(c, row.x + 26 * us, row.y + 16 * us, cand[i]);
            }
        }

        // "Mount at boot" + "Read-only" checkboxes with labels.
        const boot = desktop_icon_menu.mountItemRect(desktop_icon_menu.mount_item_boot, b.x, b.y, b.w, self.mount_dropdown_open, us);
        paintCheckbox(c, boot.x, boot.y, us, self.mount_boot, self.mount_hover_item == desktop_icon_menu.mount_item_boot);
        cairo.cairo_set_source_rgba(c, 0.92, 0.93, 0.95, 1.0);
        showText(c, boot.x + 26 * us, boot.y + 22 * us, "Mount at boot");
        const ro = desktop_icon_menu.mountItemRect(desktop_icon_menu.mount_item_readonly, b.x, b.y, b.w, self.mount_dropdown_open, us);
        paintCheckbox(c, ro.x, ro.y, us, self.mount_readonly, self.mount_hover_item == desktop_icon_menu.mount_item_readonly);
        cairo.cairo_set_source_rgba(c, 0.92, 0.93, 0.95, 1.0);
        showText(c, ro.x + 26 * us, ro.y + 22 * us, "Read-only");
        // GNOME Disks sub-options (`fstab-dialog` rows): only live while the
        // boot master is on — otherwise dimmed, like Disks' insensitive grid.
        const opts_on = self.mount_boot;
        paintMountOpt(c, b, us, self.mount_dropdown_open, self.mount_hover_item, desktop_icon_menu.mount_item_startup, self.mount_startup, opts_on, "Mount at system startup");
        paintMountOpt(c, b, us, self.mount_dropdown_open, self.mount_hover_item, desktop_icon_menu.mount_item_showui, self.mount_show_ui, opts_on, "Show in file manager");
        paintMountOpt(c, b, us, self.mount_dropdown_open, self.mount_hover_item, desktop_icon_menu.mount_item_auth, self.mount_require_auth, opts_on, "Require authorization to mount");

        // Mount / Cancel.
        const mount_r = desktop_icon_menu.mountItemRect(desktop_icon_menu.mount_item_mount, b.x, b.y, b.w, self.mount_dropdown_open, us);
        const cancel_r = desktop_icon_menu.mountItemRect(desktop_icon_menu.mount_item_cancel, b.x, b.y, b.w, self.mount_dropdown_open, us);
        self.paintDialogBtn(c, mount_r, "Mount", self.mount_hover_item == desktop_icon_menu.mount_item_mount, us);
        self.paintDialogBtn(c, cancel_r, "Cancel", self.mount_hover_item == desktop_icon_menu.mount_item_cancel, us);

        cairo.cairo_restore(c);
    }

    /// One Disks-style option row: checkbox + label, dimmed when `live` is
    /// false (the fstab-only rows while `Mount at boot` is off).
    fn paintMountOpt(c: ?*cairo.cairo_t, b: desktop_icon_menu.Rect, us: f64, dropdown_open: bool, hover_item: i32, item: i32, checked: bool, live: bool, label: []const u8) void {
        const cr = c orelse return;
        const r = desktop_icon_menu.mountItemRect(item, b.x, b.y, b.w, dropdown_open, us);
        paintCheckbox(cr, r.x, r.y, us, checked, live and hover_item == item);
        if (live)
            cairo.cairo_set_source_rgba(cr, 0.92, 0.93, 0.95, 1.0)
        else
            cairo.cairo_set_source_rgba(cr, 0.45, 0.46, 0.48, 0.75);
        showText(cr, r.x + 26 * us, r.y + 22 * us, label);
    }

    /// The dialog's 100x32 rounded button (`paint_btn` `:1290-1305`): accent
    /// fill on hover, base fill otherwise, label centred both ways.
    fn paintDialogBtn(self: *Desktop, c: ?*cairo.cairo_t, r: desktop_icon_menu.Rect, label: []const u8, hover: bool, us: f64) void {
        const cr = c orelse return;
        _ = self;
        if (hover)
            cairo.cairo_set_source_rgba(cr, 0.25, 0.45, 0.85, 0.9)
        else
            cairo.cairo_set_source_rgba(cr, 0.15, 0.18, 0.24, 0.85);
        eh.cairo_helpers.roundedRect(cr, r.x, r.y, r.w, r.h, 6.0 * us);
        cairo.cairo_fill(cr);
        cairo.cairo_set_font_size(cr, 12.0 * us);
        cairo.cairo_set_source_rgba(cr, 0.92, 0.93, 0.95, 1.0);
        const te = textExtents(cr, label);
        showText(cr, r.x + (r.w - te.x_advance) * 0.5, r.y + r.h * 0.5 + te.height * 0.3, label);
    }

    fn clearPass(cr: ?*cairo.cairo_t, scale: i32) void {
        const c = cr orelse return;
        cairo.cairo_save(c);
        cairo.cairo_set_operator(c, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(c);
        cairo.cairo_restore(c);
        // Scale the frame to the output's device pixels. Every paint site
        // draws in logical coordinates (s.w/s.h from the configure); cairo
        // rasterises at the buffer's native resolution so HiDPI stays crisp.
        cairo.cairo_identity_matrix(c);
        const s: f64 = @floatFromInt(@max(1, scale));
        cairo.cairo_scale(c, s, s);
    }

    fn commitSurf(surf: *layer.Surface, shm: *shm_mod.ShmBuffer, w: i32, h: i32) void {
        cairo.cairo_surface_flush(shm.cairo_surface.?);
        surf.attach(shm.wlBuffer(), 0, 0);
        surf.setBufferScale(surf.scale);
        surf.damage(0, 0, w, h);
        shm.markBusy();
        surf.commit();
    }

    /// Full repaint: all three layers, every output. Hot paths (hover,
    /// marquee frames, menu hover) call `repaintLayers` with just the layer
    /// that changed.
    fn repaint(self: *Desktop) void {
        self.repaintLayers(.{ .icons = true, .widgets = true, .menu = true });
    }

    /// Three layer surfaces per output, like the C++ (separate namespaces so
    /// Hyprland blur rules match): icons+marquee, widgets, menus. Each pass
    /// draws into a free pooled buffer and drops the frame when the
    /// compositor holds them all, instead of painting under the screen.
    fn repaintLayers(self: *Desktop, want: Layers) void {
        const P = &self.perf;
        const t_repaint = perfNowNs();
        // Phase sums live in locals: `perfSummary` below resets the shared
        // accumulators, so diffs against them would underflow.
        var sum_icons: u64 = 0;
        var sum_widgets: u64 = 0;
        var sum_menu: u64 = 0;
        var sum_drops: u64 = 0;
        defer {
            const dt = perfNowNs() -% t_repaint;
            P.repaints += 1;
            P.repaint_ns += dt;
            if (dt > P.repaint_max_ns) P.repaint_max_ns = dt;
            P.by_cb[@intFromEnum(P.cb)] += 1;
            if (P.last_repaint_ns != 0) {
                const gap = t_repaint -% P.last_repaint_ns;
                if (gap > P.repaint_gap_max_ns) P.repaint_gap_max_ns = gap;
            }
            P.last_repaint_ns = t_repaint;
            if (dt >= Perf.slow_repaint_ns and Perf.slowLogAllowed(&P.slow_repaint_log_ns, t_repaint)) {
                logz.log(
                    "perf: repaint {d:.1}ms cb={s} icons={d:.1}ms widgets={d:.1}ms menu={d:.1}ms drops={d}",
                    .{
                        perfMs(dt),
                        @tagName(P.cb),
                        perfMs(sum_icons),
                        perfMs(sum_widgets),
                        perfMs(sum_menu),
                        sum_drops,
                    },
                );
            }
            self.perfSummary(t_repaint);
        }
        for (self.surfs.items) |*s| {
            if (s.w <= 0 or s.h <= 0) continue;
            // Per-output fit: this surface's cells match its own resolution.
            const m = self.metricsFit(fitForH(s.h));
            // Icon layer.
            if (want.icons) {
                const t = perfNowNs();
                if (s.shm.acquire()) |buf| {
                    if (buf.cr) |cr| {
                        clearPass(cr, s.surface.scale);
                        // Icon cells with glyphs + labels (skipped when hidden,
                        // like C++ icons_visible).
                        if (self.iconsShown()) {
                            for (self.icons.items, 0..) |ic, i| {
                                if (ic.layer != @as(i32, @intCast(s.output))) continue;
                                self.paintIcon(cr, ic, i, m);
                            }
                        }
                        // Marquee.
                        if (self.ui.marquee_dragging) desktop_paint.paintMarquee(cr, self.marquee);
                        commitSurf(&s.surface, buf, s.w, s.h);
                    }
                } else {
                    P.busy_drops += 1;
                    sum_drops += 1;
                }
                const d = perfNowNs() -% t;
                P.icons_ns += d;
                sum_icons += d;
                if (d > P.icons_max_ns) P.icons_max_ns = d;
            }
            // Widget layer: instances from settings, movable by drag.
            if (want.widgets and self.w_inited) {
                const t = perfNowNs();
                if (s.wshm.acquire()) |wbuf| {
                    if (wbuf.cr) |wcr| {
                        clearPass(wcr, s.wsurf.scale);
                        const ctx = wctx.Ctx.fromSchema(&self.a.loaded.cfg, self.a.io);
                        self.wlayer.paintWidgets(wcr, s.w, s.h, s.output_name, ctx);
                        commitSurf(&s.wsurf, wbuf, s.w, s.h);
                    }
                } else {
                    P.busy_drops += 1;
                    sum_drops += 1;
                    const now_ms: i64 = @intCast(wctx.monotonicMs());
                    if (now_ms - self.widget_drop_ms > 1000) {
                        self.widget_drop_ms = now_ms;
                        logz.log("paint: widget buffer busy output={s}", .{s.output_name});
                    }
                }
                const d = perfNowNs() -% t;
                P.widgets_ns += d;
                sum_widgets += d;
                if (d > P.widgets_max_ns) P.widgets_max_ns = d;
            }
            // Menu layer: painted only while a menu is open on this output;
            // otherwise a single empty commit (C++ detaches — same effect).
            if (want.menu and s.output == self.menu_layer) {
                const t = perfNowNs();
                const want_menu = self.ui.desktop_menu_open or self.ui.icon_menu_open or self.ui.mount_dialog_open;
                if (want_menu) {
                    if (s.mshm.acquire()) |mbuf| {
                        if (mbuf.cr) |mcr| {
                            clearPass(mcr, s.msurf.scale);
                            if (self.ui.desktop_menu_open) self.paintDesktopMenu(mcr);
                            if (self.ui.icon_menu_open) self.paintIconMenuRows(mcr);
                            if (self.ui.mount_dialog_open) self.paintMountDialog(mcr);
                            commitSurf(&s.msurf, mbuf, s.w, s.h);
                            s.menu_clear = false;
                        }
                    }
                } else if (!s.menu_clear) {
                    if (s.mshm.acquire()) |mbuf| {
                        if (mbuf.cr) |mcr| {
                            clearPass(mcr, s.msurf.scale);
                            commitSurf(&s.msurf, mbuf, s.w, s.h);
                            s.menu_clear = true;
                        }
                    }
                }
                const d = perfNowNs() -% t;
                P.menu_ns += d;
                sum_menu += d;
                if (d > P.menu_max_ns) P.menu_max_ns = d;
            }
        }
        _ = self.a.conn.flush();
    }

    /// Emit the window summary when due. Called from `repaint`'s defer, so
    /// it runs at least once a second (the 1s tick always repaints).
    fn perfSummary(self: *Desktop, now: u64) void {
        const P = &self.perf;
        if (!P.enabled) return;
        if (P.last_summary_ns == 0) {
            P.last_summary_ns = now;
            return;
        }
        const win = now -% P.last_summary_ns;
        if (win < 5 * std.time.ns_per_s) return;
        const secs = @max(perfMs(win) / 1000.0, 0.001);
        const repaints_f: f64 = @floatFromInt(P.repaints);
        const by = P.by_cb;
        logz.log(
            "perf: {d:.0}s repaints={d} ({d:.1}/s) avg={d:.2}ms max={d:.1}ms gapmax={d:.0}ms | icons avg={d:.2} max={d:.1} | widgets avg={d:.2} max={d:.1} | menu avg={d:.2} max={d:.1} | drops={d} | by tick={d} anim={d} motion={d} enter={d} button={d} fd={d} other={d}",
            .{
                secs,
                P.repaints,
                repaints_f / secs,
                perfAvgNs(P.repaint_ns, P.repaints),
                perfMs(P.repaint_max_ns),
                perfMs(P.repaint_gap_max_ns),
                perfAvgNs(P.icons_ns, P.repaints),
                perfMs(P.icons_max_ns),
                perfAvgNs(P.widgets_ns, P.repaints),
                perfMs(P.widgets_max_ns),
                perfAvgNs(P.menu_ns, P.repaints),
                perfMs(P.menu_max_ns),
                P.busy_drops,
                by[@intFromEnum(PerfCb.tick)],
                by[@intFromEnum(PerfCb.anim)],
                by[@intFromEnum(PerfCb.motion)],
                by[@intFromEnum(PerfCb.enter)],
                by[@intFromEnum(PerfCb.button)],
                by[@intFromEnum(PerfCb.widget_fd)],
                by[@intFromEnum(PerfCb.reload)] + by[@intFromEnum(PerfCb.reconf)] + by[@intFromEnum(PerfCb.startup)] + by[@intFromEnum(PerfCb.none)],
            },
        );
        logz.log(
            "perf: {d:.0}s rescan n={d} avg={d:.2}ms max={d:.1}ms (scan {d:.2}/{d:.1} sort {d:.2}/{d:.1} layout {d:.2}/{d:.1} resolve {d:.2}/{d:.1}) | tick n={d} avg={d:.2} max={d:.1} (mpris {d:.2}/{d:.1} widgets {d:.2}/{d:.1}) | anim={d} fd={d} reload={d} | motion n={d} avg={d:.2}ms max={d:.1} | button n={d} avg={d:.2}ms max={d:.1}",
            .{
                secs,
                P.rescans,
                perfAvgNs(P.rescan_ns, P.rescans),
                perfMs(P.rescan_max_ns),
                perfAvgNs(P.scan_ns, P.rescans),
                perfMs(P.scan_max_ns),
                perfAvgNs(P.sort_ns, P.rescans),
                perfMs(P.sort_max_ns),
                perfAvgNs(P.layout_ns, P.rescans),
                perfMs(P.layout_max_ns),
                perfAvgNs(P.resolve_ns, P.rescans),
                perfMs(P.resolve_max_ns),
                P.ticks,
                perfAvgNs(P.tick_ns, P.ticks),
                perfMs(P.tick_max_ns),
                perfAvgNs(P.tick_mpris_ns, P.ticks),
                perfMs(P.tick_mpris_max_ns),
                perfAvgNs(P.tick_widgets_ns, P.ticks),
                perfMs(P.tick_widgets_max_ns),
                P.anim_ticks,
                P.widget_fd_hits,
                P.reloads,
                P.motions,
                perfAvgNs(P.motion_ns, P.motions),
                perfMs(P.motion_max_ns),
                P.buttons,
                perfAvgNs(P.button_ns, P.buttons),
                perfMs(P.button_max_ns),
            },
        );
        P.resetWindow();
        P.last_summary_ns = now;
    }

    fn onReload(ctx: *anyopaque) void {
        const self: *Desktop = @ptrCast(@alignCast(ctx));
        self.perf.reloads += 1;
        const prev_cb = self.perf.cb;
        self.perf.cb = .reload;
        defer self.perf.cb = prev_cb;
        self.rescan(.{ .icons = true, .widgets = true, .menu = true });
        self.reloadWidgets();
        self.repaint();
    }

    /// `widget_watch` fired: the settings tab rewrote the widget layout
    /// (Add / Remove / drag) or its component toml (slot enable / display
    /// output) — reload the layer now instead of keeping the boot-time
    /// contents until the next restart. The layout `.txt` needs its own
    /// drain: the App watcher only matches `*.toml`, and its component
    /// watches are not recursive.
    fn onWidgetFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Desktop = @ptrCast(@alignCast(ctx));
        _ = fd;
        if ((revents & std.posix.POLL.IN) == 0) return;
        if (!self.widget_watch.drainAnyOf(&.{ "desktop_widgets_layout.txt", "desktop_widgets.toml" })) return;
        self.perf.widget_fd_hits += 1;
        const prev_cb = self.perf.cb;
        self.perf.cb = .widget_fd;
        defer self.perf.cb = prev_cb;
        logz.log("widgets: state file changed, reloading", .{});
        self.reloadWidgets();
        // A freshly added widget may animate; without this the 1s tick arms
        // the timer instead of the next frame.
        self.armAnim();
    }

    /// Disk rescan; `want` names the layers the caller needs repainted (icons
    /// only when the scan changed them).
    fn rescan(self: *Desktop, want: Layers) void {
        const P = &self.perf;
        const t_rescan = perfNowNs();
        P.rescans += 1;
        // A selection highlight is cleared at the end of every rescan; repaint
        // icons for it even when the list itself is identical.
        const was_selected = self.selected >= 0;
        // Phase costs live in locals: `repaint` below can emit the window
        // summary and reset the accumulators, so deferred diffs against them
        // would underflow.
        var d_scan: u64 = 0;
        var d_sort: u64 = 0;
        var d_layout: u64 = 0;
        var d_resolve: u64 = 0;
        {
            const t = perfNowNs();
            self.scanFromDisk();
            d_scan = perfNowNs() -% t;
            P.scan_ns += d_scan;
            if (d_scan > P.scan_max_ns) P.scan_max_ns = d_scan;
        }
        {
            const t = perfNowNs();
            desktop_icons.sortIcons(self.icons.items, self.prefs_state.sort);
            d_sort = perfNowNs() -% t;
            P.sort_ns += d_sort;
            if (d_sort > P.sort_max_ns) P.sort_max_ns = d_sort;
        }
        {
            const t = perfNowNs();
            self.layoutAll();
            d_layout = perfNowNs() -% t;
            P.layout_ns += d_layout;
            if (d_layout > P.layout_max_ns) P.layout_max_ns = d_layout;
        }
        {
            const t = perfNowNs();
            self.resolveAllIcons();
            d_resolve = perfNowNs() -% t;
            P.resolve_ns += d_resolve;
            if (d_resolve > P.resolve_max_ns) P.resolve_max_ns = d_resolve;
        }
        self.selected = -1;
        // Icons repaint only when the scan (or the art the scan resolved)
        // actually changed something; `want.icons` says whether this caller
        // cares at all. `was_selected` repaints the cleared highlight.
        const sig = self.iconsSignature();
        const icons_changed = sig != self.icons_sig or was_selected;
        self.icons_sig = sig;
        self.repaintLayers(.{
            .icons = want.icons and icons_changed,
            .widgets = want.widgets,
            .menu = want.menu,
        });
        const dt = perfNowNs() -% t_rescan;
        P.rescan_ns += dt;
        if (dt > P.rescan_max_ns) P.rescan_max_ns = dt;
        if (dt >= Perf.slow_rescan_ns and Perf.slowLogAllowed(&P.slow_rescan_log_ns, t_rescan)) {
            logz.log(
                "perf: rescan {d:.1}ms scan={d:.1}ms sort={d:.1}ms layout={d:.1}ms resolve={d:.1}ms icons={d}",
                .{
                    perfMs(dt),
                    perfMs(d_scan),
                    perfMs(d_sort),
                    perfMs(d_layout),
                    perfMs(d_resolve),
                    self.icons.items.len,
                },
            );
        }
    }

    fn layoutAll(self: *Desktop) void {
        for (self.surfs.items) |*s| {
            desktop_icons.relayout(
                self.icons.items,
                @intCast(s.output),
                s.w,
                s.h,
                self.metricsFit(fitForH(s.h)),
                self.prefs_state.arrangement,
                self.prefs_state.sort,
                0,
                0,
            );
        }
    }

    fn outputNameFor(self: *Desktop, surf: ?*anyopaque) []const u8 {
        const ws = surf orelse return "";
        for (self.surfs.items) |*s| {
            if (@as(?*anyopaque, @ptrCast(s.surface.wl_surface)) == ws) return s.output_name;
        }
        return "";
    }

    fn stateDir(self: *Desktop) ?[]u8 {
        return config.settingsDir(self.a.gpa, self.a.xdg_config, self.a.home) catch null;
    }

    /// (Re)load widget instances from settings; called at startup and on
    /// config reload, mirroring horizon-desktop-widgets.
    fn reloadWidgets(self: *Desktop) void {
        if (!self.w_inited) return;
        const dir = self.stateDir() orelse return;
        defer self.a.gpa.free(dir);
        const slots = wpersist.loadShellSlots(self.a.gpa, self.a.io, dir);
        defer {
            if (slots.output_name.len > 0) self.a.gpa.free(slots.output_name);
            for (slots.disabled) |dd| self.a.gpa.free(dd);
            if (slots.disabled.len > 0) self.a.gpa.free(slots.disabled);
        }
        self.wlayer.reload(self.a.io, self.a.gpa, slots.disabled);
        // The output picker writes one global output_name; the layout rows
        // carry their own (usually empty = everywhere). Stamp the global
        // onto every instance so widgets show on that display only.
        if (slots.output_name.len > 0) {
            if (self.widget_output.len > 0) self.a.gpa.free(self.widget_output);
            self.widget_output = self.a.gpa.dupe(u8, slots.output_name) catch "";
            for (self.wlayer.host.instances.items) |*inst| {
                inst.config.output_name = self.widget_output;
            }
        }
        self.repaint();
    }

    fn weatherRequest(self: *Desktop) weather_mod.Request {
        const cfg = &self.a.loaded.cfg;
        for (self.wlayer.host.instances.items) |*inst| {
            const wid = wdata.slotId(inst.config);
            if (std.mem.eql(u8, wid, "weather") or std.mem.eql(u8, wid, "weather_fancy")) {
                const unit = wset.widgetSetting(cfg, inst.config.id, "weather_unit");
                return .{
                    .lat = wset.widgetSetting(cfg, inst.config.id, "weather_lat"),
                    .lon = wset.widgetSetting(cfg, inst.config.id, "weather_lon"),
                    .city = wset.widgetSetting(cfg, inst.config.id, "weather_city"),
                    .fahrenheit = unit.len > 0 and (unit[0] == 'f' or unit[0] == 'F'),
                };
            }
        }
        return .{};
    }

    fn armAnim(self: *Desktop) void {
        const want = self.wlayer.host.animIntervalMs();
        if (want == 0) {
            if (self.anim_fd >= 0) {
                _ = linux.close(self.anim_fd);
                self.anim_fd = -1;
            }
            self.anim_interval_ms = 0;
            return;
        }
        // Never repaint faster than the widgets asked for. Cider's clock and
        // equalizer only need ~10fps; the old hard-coded 33ms kept three
        // fullscreen surfaces busy while artwork was decoding.
        if (self.anim_fd >= 0) {
            if (self.anim_interval_ms != want) {
                const its = linux.itimerspec{
                    .it_interval = .{ .sec = 0, .nsec = @as(isize, @intCast(@as(u64, want) * std.time.ns_per_ms)) },
                    .it_value = .{ .sec = 0, .nsec = @as(isize, @intCast(@as(u64, want) * std.time.ns_per_ms)) },
                };
                if (linux.timerfd_settime(self.anim_fd, .{}, &its, null) == 0) self.anim_interval_ms = want;
            }
            return;
        }
        const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
        if (rc < 0) return;
        const fd: i32 = @intCast(rc);
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = @as(isize, @intCast(@as(u64, want) * std.time.ns_per_ms)) },
            .it_value = .{ .sec = 0, .nsec = @as(isize, @intCast(@as(u64, want) * std.time.ns_per_ms)) },
        };
        if (linux.timerfd_settime(fd, .{}, &its, null) != 0) {
            _ = linux.close(fd);
            return;
        }
        self.a.loop.watchFd(fd, std.posix.POLL.IN, onAnimTick, @ptrCast(self)) catch {
            _ = linux.close(fd);
            return;
        };
        self.anim_fd = fd;
        self.anim_interval_ms = want;
    }

    fn onAnimTick(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Desktop = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        self.perf.anim_ticks += 1;
        const prev_cb = self.perf.cb;
        self.perf.cb = .anim;
        defer self.perf.cb = prev_cb;
        self.repaint();
        self.armAnim();
    }

    /// (Re)arm the settle timer: one-shot 150 ms that applies every pending
    /// surface size (`onReconfTick`). The fd lives as long as the process and
    /// is only ever re-armed — closing it mid-run would leave a stale watch
    /// entry polling a dead fd.
    fn armReconf(self: *Desktop) void {
        if (self.reconf_fd < 0) {
            const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
            if (rc < 0) return;
            const fd: i32 = @intCast(rc);
            self.a.loop.watchFd(fd, std.posix.POLL.IN, onReconfTick, @ptrCast(self)) catch {
                _ = linux.close(fd);
                return;
            };
            self.reconf_fd = fd;
        }
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = 150_000_000 },
        };
        if (linux.timerfd_settime(self.reconf_fd, .{}, &its, null) != 0) return;
    }

    /// Full disk scan:
    /// `~/Desktop` entries (folders, `.desktop` apps, files) sorted by
    /// filename, plus `/proc/mounts` drives, Trash + My Computer.
    /// Strings owned by `arena` (reset each scan); `icons` holds the views.
    fn scanFromDisk(self: *Desktop) void {
        const gpa = self.a.gpa;
        const io = self.a.io;
        _ = self.arena.reset(.retain_capacity);
        self.icons.clearRetainingCapacity();
        const aa = self.arena.allocator();
        const cwd = std.Io.Dir.cwd();

        // Prefs (arrangement/sort/size/visible) from the layout file so the
        // menu checks and relayout match on every start. Grid slots
        // merge after the scan (icons must exist first).
        var grid: std.ArrayList(desktop_prefs.GridEntry) = .empty;
        defer {
            for (grid.items) |g| gpa.free(g.path);
            grid.deinit(gpa);
        }
        if (config.settingsDir(gpa, self.a.xdg_config, self.a.home)) |sdir| {
            defer gpa.free(sdir);
            const layout = std.fs.path.join(gpa, &.{ sdir, "desktop_icons_layout.txt" }) catch null;
            if (layout) |lp| {
                defer gpa.free(lp);
                desktop_prefs.loadFile(io, gpa, lp, &self.prefs_state, &grid) catch {};
            }
        } else |_| {}

        const home = self.a.home;
        var desk_buf: [1024]u8 = undefined;
        // A missing ~/Desktop must not hide drives/Trash/Computer: only the
        // directory iteration is conditional (missing ~/Desktop must not blank
        // the whole desktop on fresh installs).
        if (desktop_icons.userDesktopDir(null, home, &desk_buf)) |desk_dir| {
            if (cwd.openDir(io, desk_dir, .{ .iterate = true })) |dir| {
                var d = dir;
                defer d.close(io);
                self.scanDesktopDir(cwd, io, aa, desk_dir, &d);
            } else |_| {}
        }

        self.addDrives(aa);
        self.addSpecials();
        self.mergeGrid(grid.items);
    }

    fn scanDesktopDir(
        self: *Desktop,
        cwd: std.Io.Dir,
        io: std.Io,
        aa: std.mem.Allocator,
        desk_dir: []const u8,
        dir: *std.Io.Dir,
    ) void {
        const gpa = self.a.gpa;
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| aa.free(n);
            names.deinit(aa);
        }
        var it = dir.iterate();
        while (it.next(io) catch null) |ent| {
            if (desktop_icons.scanSkips(ent.name)) continue;
            names.append(aa, aa.dupe(u8, ent.name) catch continue) catch continue;
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        for (names.items) |fname| {
            const abs = std.fs.path.join(aa, &.{ desk_dir, fname }) catch continue;
            // Kind probe: iterate told us file vs dir via a second open?
            // Re-stat via Io: directory check first (folders win).
            const is_dir = blk: {
                var sub = cwd.openDir(io, abs, .{}) catch break :blk false;
                sub.close(io);
                break :blk true;
            };
            if (is_dir) {
                const item = desktop_icons.IconItem{
                    .desktop_path = abs,
                    .name = aa.dupe(u8, fname) catch continue,
                    .icon_key = "inode-directory",
                    .kind = .folder,
                };
                self.icons.append(gpa, item) catch continue;
                continue;
            }
            // Regular file (or missing -> skip).
            _ = cwd.statFile(io, abs, .{}) catch continue;
            if (std.mem.endsWith(u8, fname, ".desktop")) {
                const text = cwd.readFileAlloc(io, abs, aa, .limited(64 * 1024)) catch continue;
                const pd = desktop_icons.parseDesktopFile(text);
                var type_buf: [32]u8 = undefined;
                const tn: usize = @min(pd.entry_type.len, 32);
                for (0..tn) |i| type_buf[i] = std.ascii.toLower(pd.entry_type[i]);
                if (!std.mem.eql(u8, type_buf[0..tn], "application")) continue;
                if (pd.no_display or pd.hidden) continue;
                const exec_trim = desktop_entry_types.trimLine(pd.exec);
                if (exec_trim.len == 0) continue;
                const stripped = desktop_entry_types.stripExecFieldCodes(aa, exec_trim) catch continue;
                if (stripped.len == 0) continue;
                const disp_name = if (pd.name.len > 0) pd.name else std.fs.path.stem(fname);
                const leaf = desktop_entry_types.stripNamespaceLeaf(disp_name);
                const final_exec = if (pd.terminal)
                    std.fmt.allocPrint(aa, "x-terminal-emulator -e {s}", .{stripped}) catch continue
                else
                    aa.dupe(u8, stripped) catch continue;
                const icon_key = if (pd.icon.len > 0)
                    aa.dupe(u8, pd.icon) catch continue
                else
                    // No Icon= key: look up by file stem (C++ uses the
                    // desktop stem, never "foo.desktop" — the extension
                    // matches no theme entry).
                    aa.dupe(u8, std.fs.path.stem(fname)) catch continue;
                self.icons.append(gpa, .{
                    .desktop_path = abs,
                    .name = aa.dupe(u8, leaf) catch continue,
                    .exec = final_exec,
                    .icon_key = icon_key,
                    .kind = .application,
                }) catch continue;
            } else {
                const item = desktop_icons.IconItem{
                    .desktop_path = abs,
                    .name = aa.dupe(u8, fname) catch continue,
                    .icon_key = desktop_icons.iconKeyForFilePath(fname),
                    .kind = .file,
                };
                self.icons.append(gpa, item) catch continue;
            }
        }
    }

    /// Apply saved grid slots by path after a scan, before relayout
    /// (`merge_grid_from_prefs`). Unmatched icons keep -1 and get free slots.
    fn mergeGrid(self: *Desktop, grid: []const desktop_prefs.GridEntry) void {
        for (self.icons.items) |*ic| {
            ic.grid_col = -1;
            ic.grid_row = -1;
            ic.layer = 0;
            for (grid) |g| {
                if (std.mem.eql(u8, g.path, ic.desktop_path)) {
                    ic.grid_col = g.slot.col;
                    ic.grid_row = g.slot.row;
                    ic.layer = g.slot.layer;
                    break;
                }
            }
        }
    }

    /// Read a procfs file to completion. `std.Io.Dir.readFileAlloc` takes the
    /// positional path, and procfs advertises `st_size = 0`, so it returns an
    /// empty buffer — which silently emptied the desktop's drive list (C++
    /// reads `/proc/mounts` with `std::getline` until EOF). `readPositionalAll`
    /// loops on `pread` instead of trusting the size.
    fn readProcFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = try f.readPositionalAll(io, &buf, @intCast(out.items.len));
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
            if (n < buf.len) break;
        }
        return out.toOwnedSlice(gpa);
    }

    /// Desktop drives (`add_drive_icons`, `:545-630`): mounted volumes from
    /// `/proc/mounts` enriched with UDisks2 metadata, plus every unmounted
    /// UDisks2 filesystem drive. Unmounted drives keep their `/dev/...` node as
    /// `desktop_path` and `drive_mounted = false` so the menu offers Mount and
    /// paint dims them.
    fn addDrives(self: *Desktop, aa: std.mem.Allocator) void {
        const gpa = self.a.gpa;
        const io = self.a.io;

        // UDisks2 snapshot (cached behind a TTL by the client). The scan runs
        // on a 1s tick, so this stays a no-op unless drives actually changed —
        // except right after a mount/unmount, where `armUdisksRefresh` runs a
        // handful of ttl-0 queries until the forked operation lands.
        const now_ms: i64 = @intCast(wctx.monotonicMs());
        const ttl: i64 = if (self.udisks_refresh_ticks > 0) 0 else 4000;
        if (self.udisks_refresh_ticks > 0) self.udisks_refresh_ticks -= 1;
        const drives = self.udisks.drives(now_ms, ttl);

        var seen: [64][]const u8 = undefined;
        var seen_n: usize = 0;
        const seenDev = struct {
            fn f(list: []const []const u8, dev: []const u8) bool {
                for (list) |s| if (std.mem.eql(u8, s, dev)) return true;
                return false;
            }
        }.f;

        const text = readProcFile(gpa, io, "/proc/mounts") catch null;
        defer if (text) |t| gpa.free(t);
        if (text) |body| {
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                var parts = std.mem.splitScalar(u8, line, ' ');
                const dev = parts.next() orelse continue;
                const mnt_raw = parts.next() orelse continue;
                const fst = parts.next() orelse continue;
                const mnt_dec = desktop_entry_types.decodeMountEscapes(gpa, mnt_raw) catch continue;
                defer gpa.free(mnt_dec);
                const keep = desktop_icons.driveMountFilter(dev, mnt_dec, fst) orelse continue;
                if (seenDev(seen[0..seen_n], dev)) continue;
                const base = std.fs.path.basename(keep);
                if (base.len == 0 or base[0] == '.') continue;
                if (std.mem.eql(u8, base, "swap")) continue;
                if (seen_n < seen.len) {
                    seen[seen_n] = aa.dupe(u8, dev) catch break;
                    seen_n += 1;
                }
                // Attach UDisks2 metadata (object path / uuid / fstype) when this
                // device is known to the service, so Mount/Unmount can target it.
                var obj: []const u8 = "";
                var uuid: []const u8 = "";
                var ftype: []const u8 = "";
                var hfstab = false;
                for (drives) |d| {
                    if (!std.mem.eql(u8, d.device, dev)) continue;
                    obj = aa.dupe(u8, d.object_path) catch "";
                    uuid = aa.dupe(u8, d.uuid) catch "";
                    ftype = aa.dupe(u8, d.fstype) catch "";
                    hfstab = d.has_fstab;
                    break;
                }
                const canon = aa.dupe(u8, keep) catch continue;
                const name = aa.dupe(u8, base) catch continue;
                self.icons.append(gpa, .{
                    .desktop_path = canon,
                    .name = name,
                    .icon_key = "drive-harddisk",
                    .kind = .drive,
                    .drive_mounted = true,
                    .drive_device = aa.dupe(u8, dev) catch "",
                    .drive_object_path = obj,
                    .drive_uuid = uuid,
                    .drive_fstype = ftype,
                    .drive_has_fstab = hfstab,
                }) catch continue;
            }
        }

        // Unmounted UDisks2 drives (C++ appends these after the mounts pass).
        for (drives) |d| {
            if (d.mounted) continue;
            if (seenDev(seen[0..seen_n], d.device)) continue;
            if (d.label.len == 0 or d.label[0] == '.') continue;
            if (std.mem.eql(u8, d.label, "swap")) continue;
            if (seen_n < seen.len) {
                seen[seen_n] = aa.dupe(u8, d.device) catch break;
                seen_n += 1;
            }
            self.icons.append(gpa, .{
                .desktop_path = aa.dupe(u8, d.device) catch continue,
                .name = aa.dupe(u8, d.label) catch continue,
                .icon_key = "drive-harddisk",
                .kind = .drive,
                .drive_mounted = false,
                .drive_device = aa.dupe(u8, d.device) catch "",
                .drive_object_path = aa.dupe(u8, d.object_path) catch "",
                .drive_uuid = aa.dupe(u8, d.uuid) catch "",
                .drive_fstype = aa.dupe(u8, d.fstype) catch "",
                .drive_has_fstab = d.has_fstab,
            }) catch continue;
        }

        // Log only when the drive set changes (the tick rescans every second).
        var n_drives: i32 = 0;
        for (self.icons.items) |ic| {
            if (ic.kind == .drive) n_drives += 1;
        }
        if (n_drives != self.logged_drive_count) {
            self.logged_drive_count = n_drives;
            logz.log("drives: {d} (udisks={d})", .{ n_drives, drives.len });
        }
    }

    fn addSpecials(self: *Desktop) void {
        const gpa = self.a.gpa;
        const io = self.a.io;
        const cwd = std.Io.Dir.cwd();
        var has_files = false;
        if (self.a.home) |h| {
            const trash = std.fmt.allocPrint(gpa, "{s}/.local/share/Trash/files", .{h}) catch null;
            if (trash) |tp| {
                defer gpa.free(tp);
                var td = cwd.openDir(io, tp, .{ .iterate = true }) catch null;
                if (td) |*d| {
                    var tit = d.iterate();
                    if (tit.next(io) catch null) |_| has_files = true;
                    d.close(io);
                }
            }
        }
        self.icons.append(gpa, .{
            .desktop_path = "@trash",
            .name = "Trash",
            .icon_key = desktop_icons.trashIconKey(has_files),
            .kind = .trash,
        }) catch {};
        self.icons.append(gpa, .{
            .desktop_path = "@mycomputer",
            .name = "My Computer",
            .icon_key = "computer",
            .kind = .my_computer,
        }) catch {};
    }

    fn openWorkspaceMenu(self: *Desktop, x: f64, y: f64, layer_idx: usize) void {
        self.closeIconMenu();
        self.ui.desktop_menu_open = true;
        self.menu_cascade = .main;
        self.menu_anchor = 0;
        self.menu_press = .{};
        self.menu_hover = -1;
        self.menu_layer = layer_idx;
        var mx = x;
        var my = y;
        self.menu_w = self.wsPanelWidth(.main);
        const us = self.menuUs();
        const b = desktop_menu.mainBounds(mx, my, self.menu_w, us);
        const w: i32 = if (self.surfs.items.len > layer_idx) self.surfs.items[layer_idx].w else 1920;
        const h: i32 = if (self.surfs.items.len > layer_idx) self.surfs.items[layer_idx].h else 1080;
        desktop_menu.clampMain(&mx, &my, b.w, b.h, w, h, us);
        self.menu_x = mx;
        self.menu_y = my;
        self.repaint();
    }

    fn openIconMenu(self: *Desktop, target: usize, x: f64, y: f64, layer_idx: usize) void {
        const gpa = self.a.gpa;
        const io = self.a.io;
        const cwd = std.Io.Dir.cwd();
        // A fresh context menu replaces the modal dialog (C++
        // `desktop_icon_menu_open` closes any mount dialog first).
        self.closeMountDialog();
        if (self.icon_menu_rows.len > 0) {
            gpa.free(self.icon_menu_rows);
            self.icon_menu_rows = &.{};
        }
        for (self.icon_action_names.items) |n| gpa.free(n);
        self.icon_action_names.clearRetainingCapacity();
        if (target >= self.icons.items.len) return;
        const tic = self.icons.items[target];
        // Extract row needs at least one archive in the selection.
        var show_extract = false;
        {
            const one = [_][]const u8{tic.desktop_path};
            const F = struct {
                fn isFile(p: []const u8) bool {
                    _ = p;
                    return true;
                }
            };
            // Regular-file check via stat; dirs never extract.
            const is_file = cwd.statFile(io, tic.desktop_path, .{}) catch null;
            if (is_file != null) {
                const filt = desktop_archive.filterArchives(gpa, &one, &F.isFile) catch null;
                if (filt) |f| {
                    defer gpa.free(f);
                    show_extract = f.len > 0;
                }
            }
        }
        // Desktop Actions for Application icons (names cached gpa-owned;
        // the entry text is freed right after parsing).
        var action_count: usize = 0;
        if (tic.kind == .application) {
            const text = cwd.readFileAlloc(io, tic.desktop_path, gpa, .limited(64 * 1024)) catch null;
            if (text) |t| {
                defer gpa.free(t);
                const e = desktop_entries.readEntry(gpa, t) catch null;
                if (e) |entry| {
                    defer gpa.free(@constCast(entry.actions));
                    for (entry.actions) |a| {
                        const nm = gpa.dupe(u8, a.name) catch continue;
                        self.icon_action_names.append(gpa, nm) catch {
                            gpa.free(nm);
                            continue;
                        };
                    }
                    action_count = self.icon_action_names.items.len;
                }
            }
        }
        const kinds = [_]desktop_icons.IconKind{tic.kind};
        self.icon_menu_rows = desktop_icon_menu.rebuildRows(gpa, &kinds, tic.drive_mounted, show_extract, action_count) catch &.{};
        self.ui.icon_menu_open = true;
        self.closeWsMenu();
        self.icon_press = .{};
        self.menu_hover = -1;
        self.icon_menu_target = @intCast(target);
        self.menu_layer = layer_idx;
        var mx = x;
        var my = y;
        const us = self.menuUs();
        self.icon_menu_w = self.iconMenuWidth();
        self.compress_w = self.compressWidth();
        const mh = desktop_icon_menu.menuHeight(self.icon_menu_rows.len, us);
        const w: i32 = if (self.surfs.items.len > layer_idx) self.surfs.items[layer_idx].w else 1920;
        const h: i32 = if (self.surfs.items.len > layer_idx) self.surfs.items[layer_idx].h else 1080;
        desktop_menu.clampMain(&mx, &my, self.icon_menu_w, mh, w, h, us);
        self.menu_x = mx;
        self.menu_y = my;
        self.repaint();
    }

    /// Menu row under the pointer for the open menu, or -1.
    fn menuHoverAt(self: *Desktop, x: f64, y: f64) i32 {
        const us = self.menuUs();
        const rh = desktop_menu.row_h * us;
        const pad = desktop_menu.pad * us;
        if (self.ui.desktop_menu_open) {
            const rows: i32 = @intCast(desktop_menu.rowCount(self.menu_cascade));
            if (x < self.menu_x or x >= self.menu_x + self.menu_w) return -1;
            if (y < self.menu_y or y >= self.menu_y + pad * 2.0 + @as(f64, @floatFromInt(rows)) * rh) return -1;
            const row: i32 = @intFromFloat(@floor((y - self.menu_y - pad) / rh));
            if (row < 0 or row >= rows) return -1;
            if (desktop_menu.isSeparator(self.menu_cascade, row)) return -1;
            return row;
        }
        if (self.ui.icon_menu_open) {
            const rows: i32 = @intCast(self.icon_menu_rows.len);
            if (x < self.menu_x or x >= self.menu_x + self.icon_menu_w) return -1;
            if (y < self.menu_y or y >= self.menu_y + pad * 2.0 + @as(f64, @floatFromInt(rows)) * rh) return -1;
            const row: i32 = @intFromFloat(@floor((y - self.menu_y - pad) / rh));
            if (row < 0 or row >= rows) return -1;
            if (desktop_icon_menu.isSep(self.icon_menu_rows[@intCast(row)])) return -1;
            return row;
        }
        return -1;
    }

    /// Button events carry no coordinates, and a compositor may deliver
    /// enter+button with no motion in between: re-read the live seat state
    /// so menus open and hits test where the pointer actually is.
    fn syncPointer(self: *Desktop) void {
        if (self.a.bound.seat_obj) |seat| {
            self.ptr_x = seat.pointer_x;
            self.ptr_y = seat.pointer_y;
            if (seat.focus_surface) |fs| {
                if (self.surfaceIndexFor(@as(?*anyopaque, @ptrCast(fs)))) |idx| {
                    self.menu_layer = idx;
                }
            }
        }
    }

    fn surfaceIndexFor(self: *Desktop, fs: ?*anyopaque) ?usize {
        for (self.surfs.items, 0..) |*s, i| {
            const hit = @as(?*anyopaque, @ptrCast(s.surface.wl_surface)) == fs or
                @as(?*anyopaque, @ptrCast(s.wsurf.wl_surface)) == fs or
                @as(?*anyopaque, @ptrCast(s.msurf.wl_surface)) == fs;
            if (hit) return i;
        }
        return null;
    }

    fn onEnter(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *Desktop = @ptrCast(@alignCast(ctx));
        self.perf.enters += 1;
        const prev_cb = self.perf.cb;
        self.perf.cb = .enter;
        defer self.perf.cb = prev_cb;
        self.ptr_x = x;
        self.ptr_y = y;
        if (self.a.bound.seat_obj) |seat| {
            if (seat.focus_surface) |fs| {
                if (self.surfaceIndexFor(@as(?*anyopaque, @ptrCast(fs)))) |idx| {
                    self.menu_layer = idx;
                }
            }
        }
    }

    /// Workspace main-panel hit (-2 outside, -1 sep/pad, else row).
    fn wsMainHit(self: *Desktop, lx: f64, ly: f64) i32 {
        const us = self.menuUs();
        const b = desktop_menu.mainBounds(self.menu_x, self.menu_y, self.menu_w, us);
        return desktop_menu.hitRow(lx, ly, b.x, b.y, b.w, b.h, .main, us);
    }

    /// Workspace cascade hit (-2 when closed/outside, -1 sep/pad, else row).
    fn wsSubHit(self: *Desktop, lx: f64, ly: f64) i32 {
        if (self.menu_cascade == .main) return -2;
        const us = self.menuUs();
        const sh = desktop_menu.menuHeight(self.menu_cascade, us);
        return desktop_menu.hitRow(lx, ly, self.menu_sub_x, self.menu_sub_y, self.menu_sub_w, sh, self.menu_cascade, us);
    }

    fn wsInAny(self: *Desktop, lx: f64, ly: f64) bool {
        const us = self.menuUs();
        const b = desktop_menu.mainBounds(self.menu_x, self.menu_y, self.menu_w, us);
        const sh = desktop_menu.menuHeight(self.menu_cascade, us);
        return desktop_menu.inAnyBounds(lx, ly, b.x, b.y, b.w, b.h, self.menu_cascade != .main, self.menu_sub_x, self.menu_sub_y, self.menu_sub_w, sh);
    }

    /// Icon menu main hit. Separator lookup is inline (row count is small).
    fn iconMainHit(self: *Desktop, lx: f64, ly: f64) i32 {
        const us = self.menuUs();
        const rows = self.icon_menu_rows.len;
        const mh = desktop_icon_menu.menuHeight(rows, us);
        if (lx < self.menu_x or ly < self.menu_y or lx >= self.menu_x + self.icon_menu_w or ly >= self.menu_y + mh) return -2;
        const rel = ly - self.menu_y - desktop_icon_menu.pad * us;
        const row: i32 = @intFromFloat(@floor(rel / (desktop_icon_menu.row_h * us)));
        if (row < 0 or row >= @as(i32, @intCast(rows))) return -1;
        if (desktop_icon_menu.isSep(self.icon_menu_rows[@intCast(row)])) return -1;
        return row;
    }

    /// Compress cascade hit (-2 closed/outside, else row 0..3).
    fn iconCompressHit(self: *Desktop, lx: f64, ly: f64) i32 {
        if (!self.icon_press.cascade_open) return -2;
        const us = self.menuUs();
        const sh = desktop_icon_menu.menuHeight(desktop_icon_menu.compress_sub_rows, us);
        if (lx < self.menu_sub_x or ly < self.menu_sub_y or lx >= self.menu_sub_x + self.compress_w or ly >= self.menu_sub_y + sh) return -2;
        const rel = ly - self.menu_sub_y - desktop_icon_menu.pad * us;
        const row: i32 = @intFromFloat(@floor(rel / (desktop_icon_menu.row_h * us)));
        if (row < 0 or row >= @as(i32, @intCast(desktop_icon_menu.compress_sub_rows))) return -1;
        return row;
    }

    fn iconInAny(self: *Desktop, lx: f64, ly: f64) bool {
        const us = self.menuUs();
        const mh = desktop_icon_menu.menuHeight(self.icon_menu_rows.len, us);
        if (lx >= self.menu_x and ly >= self.menu_y and lx < self.menu_x + self.icon_menu_w and ly < self.menu_y + mh) return true;
        if (!self.icon_press.cascade_open) return false;
        const sh = desktop_icon_menu.menuHeight(desktop_icon_menu.compress_sub_rows, us);
        return lx >= self.menu_sub_x and ly >= self.menu_sub_y and lx < self.menu_sub_x + self.compress_w and ly < self.menu_sub_y + sh;
    }

    fn pointerOutput(self: *Desktop) []const u8 {
        if (self.menu_layer < self.surfs.items.len) return self.surfs.items[self.menu_layer].output_name;
        return "";
    }

    fn onMotion(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *Desktop = @ptrCast(@alignCast(ctx));
        const P = &self.perf;
        const prev_cb = P.cb;
        P.cb = .motion;
        const t_motion = perfNowNs();
        P.motions += 1;
        defer {
            P.cb = prev_cb;
            const dt = perfNowNs() -% t_motion;
            P.motion_ns += dt;
            if (dt > P.motion_max_ns) P.motion_max_ns = dt;
            if (dt >= Perf.slow_motion_ns and Perf.slowLogAllowed(&P.slow_motion_log_ns, t_motion)) {
                logz.log("perf: motion {d:.1}ms", .{perfMs(dt)});
            }
        }
        self.ptr_x = x;
        self.ptr_y = y;
        // Mount dialog hover first (C++ pointer_motion_marquee checks it
        // before both menus): the open dialog claims every motion.
        if (self.ui.mount_dialog_open) {
            const hit: i32 = blk: {
                const h = self.mountHit(x, y);
                // -2 (outside the card) reads as "no item", like -1. So do
                // the fstab-only rows while the boot master is off (Disks
                // leaves them insensitive — no hover wash, no arming).
                if (h < 0) break :blk -1;
                if (!self.mount_boot and desktop_icon_menu.mountItemNeedsBoot(h)) break :blk -1;
                break :blk h;
            };
            if (hit != self.mount_hover_item) {
                self.mount_hover_item = hit;
                self.repaint();
            }
            return;
        }
        // Menu hover wash with cascade auto-switch (C++ update_hover).
        if (self.ui.desktop_menu_open) {
            const prev_main = self.menu_press.hover_main;
            const prev_sub = self.menu_press.hover_sub;
            const prev_cascade = self.menu_cascade;
            const sub_row = self.wsSubHit(x, y);
            const main_row = self.wsMainHit(x, y);
            if (sub_row >= 0) {
                self.menu_press.hover_sub = sub_row;
                self.menu_press.hover_main = self.menu_anchor;
            } else if (main_row >= 0) {
                self.menu_press.hover_main = main_row;
                self.menu_press.hover_sub = -1;
                if (main_row == 0 or main_row == 1 or main_row == 13) {
                    const want: desktop_menu.Panel = if (main_row == 0) .view else if (main_row == 1) .sort_by else .add_new;
                    if (want != self.menu_cascade) {
                        self.menu_cascade = want;
                        self.menu_anchor = main_row;
                        self.layoutWsCascade();
                    }
                } else if (self.menu_cascade != .main) {
                    self.menu_cascade = .main;
                }
            } else {
                self.menu_press.hover_main = -1;
                self.menu_press.hover_sub = -1;
            }
            if (prev_main != self.menu_press.hover_main or prev_sub != self.menu_press.hover_sub or prev_cascade != self.menu_cascade) {
                self.repaint();
            }
            return;
        }
        // Widgets track drag/resize before icons do (C++ motion priority).
        // Hover state still updates inside motion; the icon path below
        // repaints when anything actually changed.
        if (self.w_inited and (self.wlayer.drag_idx >= 0 or self.wlayer.resize_idx >= 0)) {
            if (self.wlayer.motion(x, y, self.pointerOutput())) {
                self.repaint();
            }
            return;
        }
        if (self.w_inited) {
            _ = self.wlayer.motion(x, y, self.pointerOutput());
        }
        if (self.ui.icon_menu_open) {
            const prev_main = self.icon_press.hover_main;
            const prev_comp = self.icon_press.hover_compress;
            const was_open = self.icon_press.cascade_open;
            const sub_row = self.iconCompressHit(x, y);
            const main_row = self.iconMainHit(x, y);
            self.icon_press.motion(main_row, sub_row, self.icon_menu_rows);
            if (self.icon_press.cascade_open and !was_open) self.layoutIconCascade();
            if (prev_main != self.icon_press.hover_main or prev_comp != self.icon_press.hover_compress or was_open != self.icon_press.cascade_open) {
                self.repaint();
            }
            return;
        }
        // Icon drag with a 6 px threshold (icon_item.drag_threshold_px).
        if (self.ui.icon_dragging and self.press_idx >= 0) {
            const dx = x - self.press_x;
            const dy = y - self.press_y;
            if (!self.press_moved and dx * dx + dy * dy >= 36.0) self.press_moved = true;
            if (self.press_moved and self.press_idx < self.icons.items.len) {
                const m = self.metrics();
                const ic = &self.icons.items[@intCast(self.press_idx)];
                ic.cell_x = x - m.cell_w / 2.0;
                ic.cell_y = y - m.cell_h / 2.0;
                self.repaint();
            }
            return;
        }
        if (self.ui.marquee_dragging) {
            self.marquee.x1 = x;
            self.marquee.y1 = y;
            self.repaint();
            return;
        }
        // Plain hover: highlight the icon under the pointer (no buttons,
        // no menus — mirrors desktop_icons_pointer_motion).
        if (self.press_idx < 0 and self.iconsShown()) {
            const m = self.metrics();
            const layer_idx: i32 = @intCast(self.menu_layer);
            var hit: i32 = -1;
            if (desktop_icons.hitIndex(self.icons.items, layer_idx, x, y, m)) |idx| {
                hit = @intCast(idx);
            }
            if (hit != self.hover_idx) {
                self.hover_idx = hit;
                self.repaint();
            }
        }
    }

    /// Launch an icon: `.desktop` exec, folder/drive/file via xdg-open,
    /// trash and computer via their URIs.
    fn launchIcon(self: *Desktop, idx: usize) void {
        if (idx >= self.icons.items.len) return;
        const ic = self.icons.items[idx];
        switch (ic.kind) {
            .application => {
                if (ic.exec.len > 0) _ = app_launch.launchExec(self.a.gpa, self.a.io, ic.exec);
            },
            .trash => {
                _ = app_launch.launchExec(self.a.gpa, self.a.io, "xdg-open trash:///");
            },
            .my_computer => {
                _ = app_launch.launchExec(self.a.gpa, self.a.io, "xdg-open computer:///");
            },
            .folder, .drive, .file => {
                const cmd = xdg_ops.openPathCmd(self.a.gpa, ic.desktop_path) catch return;
                defer self.a.gpa.free(cmd);
                _ = app_launch.launchExec(self.a.gpa, self.a.io, cmd);
            },
        }
    }

    fn launchSibling(self: *Desktop, name: []const u8) bool {
        const gpa = self.a.gpa;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.readLinkAbsolute(self.a.io, "/proc/self/exe", &buf) catch return false;
        const dir = std.fs.path.dirname(buf[0..n]) orelse return false;
        const exe = std.fs.path.join(gpa, &.{ dir, name }) catch return false;
        defer gpa.free(exe);
        return app_launch.launchPath(self.a.io, exe);
    }

    /// Launch horizon-settings opened straight onto one tab id (Monitors=7
    /// for Display settings). The settings window honors EH_SETTINGS_TAB,
    /// so run it under /bin/sh with the variable set, preferring the
    /// sibling binary next to this one.
    fn launchSettingsTab(self: *Desktop, tab: i32) void {
        const gpa = self.a.gpa;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        var exe: []const u8 = "horizon-settings";
        if (std.Io.Dir.readLinkAbsolute(self.a.io, "/proc/self/exe", &buf)) |n| {
            if (std.fs.path.dirname(buf[0..n])) |dir| {
                exe = std.fmt.bufPrint(&exe_buf, "{s}/horizon-settings", .{dir}) catch exe;
            }
        } else |_| {}
        const q = desktop_xdg.shQuote(gpa, exe) catch return;
        defer gpa.free(q);
        const script = std.fmt.allocPrint(gpa, "EH_SETTINGS_TAB={d} {s}", .{ tab, q }) catch return;
        defer gpa.free(script);
        const argv = [_][]const u8{ "/bin/sh", "-lc", script };
        _ = std.process.spawn(self.a.io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch {};
        eh.autostart.reapChildren();
    }

    /// Delete an icon's file to the trash (xdg `trash` command).
    fn trashIcon(self: *Desktop, idx: usize) void {
        self.trashIconNoRescan(idx);
        self.rescan(.{ .icons = true, .widgets = true, .menu = true });
    }

    /// Indices the icon menu acts on: the marquee selection when the target
    /// is inside it, else the single target.
    fn runCapture(self: *Desktop, argv: []const []const u8) ?[]u8 {
        const res = std.process.run(self.a.gpa, self.a.io, .{ .argv = argv }) catch return null;
        defer self.a.gpa.free(res.stderr);
        return res.stdout;
    }

    fn iconSelection(self: *Desktop, target: usize, buf: []usize) []usize {
        var in_marquee = false;
        for (self.marquee_sel.items) |mi| {
            if (mi == target) {
                in_marquee = true;
                break;
            }
        }
        if (in_marquee) {
            const n = @min(buf.len, self.marquee_sel.items.len);
            @memcpy(buf[0..n], self.marquee_sel.items[0..n]);
            return buf[0..n];
        }
        if (buf.len == 0) return buf[0..0];
        buf[0] = target;
        return buf[0..1];
    }

    /// Real paths of a selection (special Trash/Computer rows excluded).
    fn selectionPaths(self: *Desktop, alloc: std.mem.Allocator, sel: []const usize) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(alloc);
        for (sel) |mi| {
            if (mi >= self.icons.items.len) continue;
            const ic = self.icons.items[mi];
            if (ic.kind == .trash or ic.kind == .my_computer) continue;
            if (std.mem.startsWith(u8, ic.desktop_path, "@")) continue;
            try out.append(alloc, ic.desktop_path);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Cut/copy the selection to the Wayland clipboard as a Nautilus
    /// file list (`x-special/nautilus-clipboard`).
    fn clipboardCopy(self: *Desktop, cut: bool, sel: []const usize) void {
        const gpa = self.a.gpa;
        const paths = self.selectionPaths(gpa, sel) catch return;
        defer gpa.free(paths);
        if (paths.len == 0) return;
        var uris: std.ArrayList([]const u8) = .empty;
        defer {
            for (uris.items) |u| gpa.free(u);
            uris.deinit(gpa);
        }
        for (paths) |p| {
            const u = desktop_xdg.fileUriForPath(gpa, p) catch continue;
            uris.append(gpa, u) catch {
                gpa.free(u);
                continue;
            };
        }
        if (uris.items.len == 0) return;
        const body = desktop_xdg.clipboardBody(gpa, cut, uris.items) catch return;
        defer gpa.free(body);
        // Pipe through wl-copy (xclip fallback) via a fixed temp file so no
        // stdin-pipe API is needed.
        const tmp = "/tmp/event-horizon-clipboard";
        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(self.a.io, .{ .sub_path = tmp, .data = body }) catch return;
        const q = desktop_xdg.shQuote(gpa, tmp) catch return;
        defer gpa.free(q);
        const script = std.fmt.allocPrint(gpa, "wl-copy --type 'x-special/nautilus-clipboard' < {s} 2>/dev/null || xclip -selection clipboard -t 'x-special/nautilus-clipboard' -i < {s}", .{ q, q }) catch return;
        defer gpa.free(script);
        _ = app_launch.launchExec(self.a.gpa, self.a.io, script);
    }

    /// Copy one directory tree (files via read/write, subdirs recursed;
    /// symlinks skipped). Used by paste.
    fn copyTree(self: *Desktop, src: []const u8, dst: []const u8) void {
        const io = self.a.io;
        const gpa = self.a.gpa;
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dst) catch {};
        var dir = cwd.openDir(io, src, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |ent| {
            if (ent.kind == .directory) {
                const s = std.fs.path.join(gpa, &.{ src, ent.name }) catch continue;
                defer gpa.free(s);
                const d = std.fs.path.join(gpa, &.{ dst, ent.name }) catch continue;
                defer gpa.free(d);
                self.copyTree(s, d);
            } else if (ent.kind == .file) {
                const s = std.fs.path.join(gpa, &.{ src, ent.name }) catch continue;
                defer gpa.free(s);
                const d = std.fs.path.join(gpa, &.{ dst, ent.name }) catch continue;
                defer gpa.free(d);
                const bytes = cwd.readFileAlloc(io, s, gpa, .limited(1 << 28)) catch continue;
                defer gpa.free(bytes);
                cwd.writeFile(io, .{ .sub_path = d, .data = bytes }) catch {};
            }
        }
    }

    fn existsPath(self: *Desktop, p: []const u8) bool {
        const cwd = std.Io.Dir.cwd();
        if (cwd.statFile(self.a.io, p, .{}) catch null) |_| return true;
        const od = cwd.openDir(self.a.io, p, .{}) catch null;
        if (od) |*d| {
            d.close(self.a.io);
            return true;
        }
        return false;
    }

    /// Paste the clipboard into the desktop dir: read wl-paste output,
    /// copy each uri to a unique dest, trash cut sources, remember undo.
    fn pasteClipboard(self: *Desktop) void {
        const gpa = self.a.gpa;
        const io = self.a.io;
        const cwd = std.Io.Dir.cwd();
        var desk_buf: [1024]u8 = undefined;
        const desk_dir = desktop_icons.userDesktopDir(null, self.a.home, &desk_buf) orelse return;
        // Try the Nautilus type first, then plain uri-list.
        var clip: ?[]u8 = self.runCapture(&.{ "wl-paste", "--no-newline", "--type", "x-special/nautilus-clipboard" });
        var cut = false;
        if (clip) |c| {
            if (c.len == 0) {
                gpa.free(c);
                clip = null;
            } else {
                var lines = std.mem.splitScalar(u8, c, '\n');
                _ = lines.next(); // header
                const mode = lines.next() orelse "";
                cut = std.mem.eql(u8, std.mem.trim(u8, mode, " \t\r"), "cut");
            }
        }
        if (clip == null) {
            clip = self.runCapture(&.{ "wl-paste", "--no-newline", "--type", "text/uri-list" });
        }
        const data = clip orelse return;
        defer gpa.free(data);
        const list = desktop_xdg.parseUriList(gpa, data) catch return;
        defer {
            for (list) |p| gpa.free(p);
            gpa.free(list);
        }
        if (list.len == 0) return;
        for (self.undo_paths.items) |p| gpa.free(p);
        self.undo_paths.clearRetainingCapacity();
        var created: usize = 0;
        for (list) |src| {
            if (src.len == 0) continue;
            if (desktop_xdg.isSelfCopy(src, desk_dir)) continue;
            const base = std.fs.path.basename(src);
            if (base.len == 0) continue;
            const Probe = struct {
                var probe_self: *Desktop = undefined;
                fn exists(p: []const u8) bool {
                    return probe_self.existsPath(p);
                }
            };
            Probe.probe_self = self;
            const dest = desktop_xdg.uniqueDest(gpa, desk_dir, base, &Probe.exists) catch continue;
            var is_dir = false;
            if (cwd.openDir(io, src, .{})) |*d| {
                d.close(io);
                is_dir = true;
            } else |_| {}
            if (is_dir) {
                self.copyTree(src, dest);
            } else {
                const bytes = cwd.readFileAlloc(io, src, gpa, .limited(1 << 28)) catch {
                    gpa.free(dest);
                    continue;
                };
                defer gpa.free(bytes);
                cwd.writeFile(io, .{ .sub_path = dest, .data = bytes }) catch {
                    gpa.free(dest);
                    continue;
                };
            }
            if (!cut) self.undo_paths.append(gpa, dest) catch {
                gpa.free(dest);
                continue;
            } else {
                gpa.free(dest);
            }
            created += 1;
            if (cut) {
                const cmd = desktop_xdg.trashCmd(gpa, src) catch continue;
                defer gpa.free(cmd);
                _ = app_launch.launchExec(self.a.gpa, self.a.io, cmd);
            }
        }
        if (created > 0) {
            if (cut) {
                for (self.undo_paths.items) |p| gpa.free(p);
                self.undo_paths.clearRetainingCapacity();
            }
            self.rescan(.{ .icons = true, .widgets = true, .menu = true });
        }
    }

    fn undoPaste(self: *Desktop) void {
        if (self.undo_paths.items.len == 0) return;
        const gpa = self.a.gpa;
        const cwd = std.Io.Dir.cwd();
        // Deepest first so nested pastes vanish cleanly.
        std.mem.sort([]const u8, self.undo_paths.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return a.len > b.len;
            }
        }.lt);
        for (self.undo_paths.items) |p| {
            cwd.deleteTree(self.a.io, p) catch {};
            gpa.free(p);
        }
        self.undo_paths.clearRetainingCapacity();
        self.rescan(.{ .icons = true, .widgets = true, .menu = true });
    }

    fn emptyTrash(self: *Desktop) void {
        const gpa = self.a.gpa;
        const io = self.a.io;
        const cwd = std.Io.Dir.cwd();
        if (self.a.home) |h| {
            for ([_][]const u8{ "files", "info" }) |leaf| {
                const p = std.fmt.allocPrint(gpa, "{s}/.local/share/Trash/{s}", .{ h, leaf }) catch continue;
                defer gpa.free(p);
                cwd.deleteTree(io, p) catch {};
                cwd.createDirPath(io, p) catch {};
            }
        }
        self.rescan(.{ .icons = true, .widgets = true, .menu = true });
    }

    fn doRename(self: *Desktop, target: usize) void {
        if (target >= self.icons.items.len) return;
        const gpa = self.a.gpa;
        const ic = self.icons.items[target];
        if (ic.kind == .trash or ic.kind == .my_computer or ic.kind == .drive) return;
        const initial = std.fs.path.basename(ic.desktop_path);
        const title = desktop_icon_menu.renameTitle(ic.kind);
        const qt = desktop_xdg.shQuote(gpa, title) catch return;
        defer gpa.free(qt);
        const qi = desktop_xdg.shQuote(gpa, initial) catch return;
        defer gpa.free(qi);
        const script = std.fmt.allocPrint(gpa, "zenity --entry --title {s} --entry-text {s} 2>/dev/null || kdialog --inputbox {s} {s} 2>/dev/null || yad --entry --title {s} --entry-text {s} 2>/dev/null", .{ qt, qi, qi, qi, qt, qi }) catch return;
        defer gpa.free(script);
        const out = self.runCapture(&.{ "/bin/sh", "-lc", script }) orelse return;
        defer gpa.free(out);
        const want = std.mem.trim(u8, out, " \t\r\n");
        if (want.len == 0 or std.mem.eql(u8, want, initial)) return;
        const safe = desktop_icon_menu.sanitizeRename(gpa, want) catch return;
        defer gpa.free(safe);
        if (safe.len == 0) return;
        const parent = std.fs.path.dirname(ic.desktop_path) orelse return;
        const dest = std.fs.path.join(gpa, &.{ parent, safe }) catch return;
        defer gpa.free(dest);
        if (self.existsPath(dest)) return;
        std.Io.Dir.renameAbsolute(ic.desktop_path, dest, self.a.io) catch return;
        self.rescan(.{ .icons = true, .widgets = true, .menu = true });
    }

    fn doShortcut(self: *Desktop, target: usize) void {
        if (target >= self.icons.items.len) return;
        const gpa = self.a.gpa;
        const io = self.a.io;
        const cwd = std.Io.Dir.cwd();
        const ic = self.icons.items[target];
        if (ic.kind != .application) return;
        const parent = std.fs.path.dirname(ic.desktop_path) orelse return;
        const stem = std.fs.path.stem(std.fs.path.basename(ic.desktop_path));
        const Probe = struct {
            var probe_self: *Desktop = undefined;
            fn exists(p: []const u8) bool {
                return probe_self.existsPath(p);
            }
        };
        Probe.probe_self = self;
        const dest = desktop_icon_menu.shortcutDest(gpa, parent, stem, &Probe.exists) catch return;
        defer gpa.free(dest);
        const bytes = cwd.readFileAlloc(io, ic.desktop_path, gpa, .limited(1 << 20)) catch return;
        defer gpa.free(bytes);
        cwd.writeFile(io, .{ .sub_path = dest, .data = bytes }) catch return;
        self.rescan(.{ .icons = true, .widgets = true, .menu = true });
    }

    fn doExtract(self: *Desktop, sel: []const usize) void {
        const gpa = self.a.gpa;
        const paths = self.selectionPaths(gpa, sel) catch return;
        defer gpa.free(paths);
        const F = struct {
            fn isFile(p: []const u8) bool {
                _ = p;
                return true;
            }
        };
        const filt = desktop_archive.filterArchives(gpa, paths, &F.isFile) catch return;
        defer gpa.free(filt);
        if (filt.len == 0) return;
        // One destination dir per archive next to it (unique), same chain
        // shells out with (7zz/7z/unzip/tar).
        for (filt) |ap| {
            const parent = std.fs.path.dirname(ap) orelse continue;
            const base = desktop_archive.archiveFolderBasename(std.fs.path.basename(ap));
            const Probe = struct {
                var probe_cwd: std.Io.Dir = undefined;
                var probe_io: std.Io = undefined;
                fn exists(p: []const u8) bool {
                    if (probe_cwd.statFile(probe_io, p, .{}) catch null) |_| return true;
                    return false;
                }
            };
            Probe.probe_cwd = std.Io.Dir.cwd();
            Probe.probe_io = self.a.io;
            const dest = desktop_archive.uniqueName(gpa, base, "", &Probe.exists) catch continue;
            defer gpa.free(dest);
            const full = std.fs.path.join(gpa, &.{ parent, dest }) catch continue;
            defer gpa.free(full);
            std.Io.Dir.cwd().createDirPath(self.a.io, full) catch continue;
            const script = blk: {
                const qarch = desktop_archive.shSingleQuote(gpa, ap) catch continue;
                defer gpa.free(qarch);
                const qdest = desktop_archive.shSingleQuote(gpa, full) catch continue;
                defer gpa.free(qdest);
                const tar = desktop_archive.isTarFamily(std.fs.path.basename(ap));
                const zip = std.mem.endsWith(u8, ap, ".zip");
                var s: std.ArrayList(u8) = .empty;
                errdefer s.deinit(gpa);
                s.appendSlice(gpa, "DEST=") catch continue;
                s.appendSlice(gpa, qdest) catch continue;
                s.appendSlice(gpa, "\nmkdir -p \"$DEST\" || true\n") catch continue;
                s.appendSlice(gpa, "if command -v 7zz >/dev/null 2>&1 && 7zz x -y ") catch continue;
                s.appendSlice(gpa, qarch) catch continue;
                s.appendSlice(gpa, " -o\"$DEST/\"; then :\n") catch continue;
                s.appendSlice(gpa, "elif command -v 7z >/dev/null 2>&1 && 7z x -y ") catch continue;
                s.appendSlice(gpa, qarch) catch continue;
                s.appendSlice(gpa, " -o\"$DEST/\"; then :\n") catch continue;
                if (zip) {
                    s.appendSlice(gpa, "elif command -v unzip >/dev/null 2>&1 && unzip -q -o ") catch continue;
                    s.appendSlice(gpa, qarch) catch continue;
                    s.appendSlice(gpa, " -d \"$DEST\"; then :\n") catch continue;
                }
                if (tar) {
                    s.appendSlice(gpa, "elif command -v tar >/dev/null 2>&1 && tar -xf ") catch continue;
                    s.appendSlice(gpa, qarch) catch continue;
                    s.appendSlice(gpa, " -C \"$DEST\"; then :\n") catch continue;
                }
                s.appendSlice(gpa, "fi\n") catch continue;
                break :blk s.toOwnedSlice(gpa) catch continue;
            };
            defer gpa.free(script);
            _ = app_launch.launchExec(self.a.gpa, self.a.io, script);
        }
    }

    fn doCompress(self: *Desktop, fmt: desktop_archive.CompressFormat, sel: []const usize) void {
        const gpa = self.a.gpa;
        const paths = self.selectionPaths(gpa, sel) catch return;
        defer gpa.free(paths);
        if (paths.len == 0) return;
        var desk_buf: [1024]u8 = undefined;
        const desk_dir = desktop_icons.userDesktopDir(null, self.a.home, &desk_buf) orelse return;
        const parent = if (paths.len > 0) std.fs.path.dirname(paths[0]) orelse desk_dir else desk_dir;
        var rts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.REALTIME, &rts);
        const stamp: i64 = @max(rts.sec, 0);
        const base = std.fmt.allocPrint(gpa, "Selection-{d}", .{stamp}) catch return;
        defer gpa.free(base);
        const Probe = struct {
            var probe_self: *Desktop = undefined;
            fn exists(p: []const u8) bool {
                return probe_self.existsPath(p);
            }
        };
        Probe.probe_self = self;
        const out_name = desktop_archive.uniqueName(gpa, base, desktop_archive.compressExtension(fmt), &Probe.exists) catch return;
        defer gpa.free(out_name);
        const out = std.fs.path.join(gpa, &.{ parent, out_name }) catch return;
        defer gpa.free(out);
        const script = desktop_archive.buildCompressScript(gpa, fmt, out, paths) catch return;
        defer gpa.free(script);
        _ = app_launch.launchExec(self.a.gpa, self.a.io, script);
    }

    fn launchDesktopAction(self: *Desktop, target: usize, action_index: u16) void {
        if (target >= self.icons.items.len) return;
        const gpa = self.a.gpa;
        const io = self.a.io;
        const ic = self.icons.items[target];
        const text = std.Io.Dir.cwd().readFileAlloc(io, ic.desktop_path, gpa, .limited(64 * 1024)) catch return;
        defer gpa.free(text);
        const e = desktop_entries.readEntry(gpa, text) catch return;
        defer gpa.free(@constCast(e.actions));
        if (action_index >= e.actions.len) return;
        const a = e.actions[action_index];
        const uri = desktop_xdg.fileUriForPath(gpa, ic.desktop_path) catch return;
        defer gpa.free(uri);
        const expanded = desktop_xdg.expandExecTokens(gpa, a.exec, ic.desktop_path, uri, ic.name) catch return;
        defer gpa.free(expanded);
        _ = app_launch.launchExec(self.a.gpa, self.a.io, expanded);
    }

    fn toggleDockPin(self: *Desktop, target: usize) void {
        if (target >= self.icons.items.len) return;
        const gpa = self.a.gpa;
        const ic = self.icons.items[target];
        if (ic.kind != .application) return;
        const stem = std.fs.path.stem(std.fs.path.basename(ic.desktop_path));
        const cur = self.a.loaded.cfg.dock.pinned_apps;
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(gpa);
        var found = false;
        for (cur) |id| {
            if (std.mem.eql(u8, id, stem)) {
                found = true;
                continue;
            }
            ids.append(gpa, id) catch continue;
        }
        if (!found) ids.append(gpa, stem) catch return;
        const sdir = config.settingsDir(gpa, self.a.xdg_config, self.a.home) catch return;
        defer gpa.free(sdir);
        const comp = config.componentPath(gpa, sdir, "dock") catch return;
        defer gpa.free(comp);
        eh.pin_store.save(gpa, self.a.io, comp, ids.items) catch {};
    }

    fn trashIconNoRescan(self: *Desktop, idx: usize) void {
        if (idx >= self.icons.items.len) return;
        const ic = self.icons.items[idx];
        if (ic.kind == .trash or ic.kind == .my_computer) return;
        if (std.mem.startsWith(u8, ic.desktop_path, "@")) return;
        const cmd = xdg_ops.trashCmd(self.a.gpa, ic.desktop_path) catch return;
        defer self.a.gpa.free(cmd);
        _ = app_launch.launchExec(self.a.gpa, self.a.io, cmd);
    }

    /// Close the workspace menu and reset all of its transient state.
    fn closeWsMenu(self: *Desktop) void {
        self.ui.desktop_menu_open = false;
        self.menu_cascade = .main;
        self.menu_anchor = 0;
        self.menu_press = .{};
        self.menu_hover = -1;
    }

    /// Close the icon menu and reset all of its transient state.
    fn closeIconMenu(self: *Desktop) void {
        self.ui.icon_menu_open = false;
        self.icon_press = .{};
        self.menu_hover = -1;
        self.closeMountDialog();
    }

    // ---- Mount dialog (C++ `paint_mount_dialog` `:1157+`, pointer `:747-925`) ----

    /// Release every gpa-owned dialog string and hide the card
    /// (`desktop_mount_dialog_close`, `:730-745`). The deferred action is a
    /// separate lifecycle — it survives a close because the menu that armed it
    /// is already gone.
    fn closeMountDialog(self: *Desktop) void {
        const gpa = self.a.gpa;
        if (!self.ui.mount_dialog_open and self.mount_object_path.len == 0) return;
        self.ui.mount_dialog_open = false;
        inline for (.{ "mount_object_path", "mount_label", "mount_device", "mount_fstype", "mount_uuid" }) |f| {
            const s = @field(self, f);
            if (s.len > 0) gpa.free(s);
            @field(self, f) = "";
        }
        self.mount_base = 0;
        self.mount_boot = false;
        self.mount_readonly = false;
        self.mount_startup = true;
        self.mount_show_ui = true;
        self.mount_require_auth = false;
        self.mount_dropdown_open = false;
        self.mount_hover_item = -1;
        self.mount_arm_item = -1;
    }

    /// Open the centered dialog for one drive (`desktop_icon_menu.cpp:569-583`).
    /// Strings are gpa-duped: a 1s rescan resets the icon arena underneath us.
    fn openMountDialog(self: *Desktop, target: usize) void {
        if (target >= self.icons.items.len) return;
        const ic = self.icons.items[target];
        if (ic.drive_object_path.len == 0) return;
        const gpa = self.a.gpa;
        self.closeMountDialog();
        self.mount_object_path = gpa.dupe(u8, ic.drive_object_path) catch "";
        self.mount_label = gpa.dupe(u8, ic.name) catch "";
        self.mount_device = gpa.dupe(u8, ic.drive_device) catch "";
        self.mount_fstype = gpa.dupe(u8, ic.drive_fstype) catch "";
        self.mount_uuid = gpa.dupe(u8, ic.drive_uuid) catch "";
        self.mount_base = 0;
        self.mount_boot = false;
        self.mount_readonly = false;
        self.mount_startup = true;
        self.mount_show_ui = true;
        self.mount_require_auth = false;
        self.mount_dropdown_open = false;
        self.mount_hover_item = -1;
        self.mount_arm_item = -1;
        self.mount_dlg_layer = self.menu_layer;
        self.ui.mount_dialog_open = true;
        self.ui.icon_menu_open = false;
        self.repaint();
    }

    /// Card bounds for the current dropdown state (the card grows when the
    /// list is open, so paint and hit tests must agree on the live size).
    fn mountBounds(self: *Desktop) desktop_icon_menu.Rect {
        const us = self.menuUs();
        const sz = desktop_icon_menu.mountDialogSize(self.mount_dropdown_open, us);
        const li = self.mount_dlg_layer;
        const lw: i32 = if (li < self.surfs.items.len) self.surfs.items[li].w else 1920;
        const lh: i32 = if (li < self.surfs.items.len) self.surfs.items[li].h else 1080;
        const p = desktop_icon_menu.mountDialogPos(lw, lh, sz.w, sz.h);
        return .{ .x = p.x, .y = p.y, .w = sz.w, .h = sz.h };
    }

    fn mountHit(self: *Desktop, lx: f64, ly: f64) i32 {
        if (!self.ui.mount_dialog_open) return -2;
        const b = self.mountBounds();
        const us = self.menuUs();
        return desktop_icon_menu.hitMountItem(lx, ly, b.x, b.y, b.w, b.h, self.mount_dropdown_open, us);
    }

    /// `$USER` for the `/run/media/$USER/<label>` candidate (`compute_mount_path`).
    fn mountUser() []const u8 {
        const p = std.c.getenv("USER") orelse return "user";
        const s = std.mem.span(p);
        return if (s.len == 0) "user" else s;
    }

    /// Execute a deferred menu action on the tick after the menu closed
    /// (`desktop_mount_dialog_process_deferred_action`, `:931-959`). `udisksctl`
    /// stands in for the C++ async D-Bus proxies — `launchExec` forks so the
    /// loop never blocks; `armUdisksRefresh` then keeps re-querying for a few
    /// ticks until the forked operation lands (the C++ rescans when its future
    /// completes instead).
    fn runMountDeferred(self: *Desktop) void {
        const kind = self.mount_deferred;
        if (kind == .none) return;
        self.mount_deferred = .none;
        const obj = self.mount_deferred_path;
        self.mount_deferred_path = "";
        defer if (obj.len > 0) self.a.gpa.free(obj);
        if (obj.len == 0) return;
        const verb: []const u8 = switch (kind) {
            .fstab_mount => "mount",
            .unmount => "unmount",
            else => return,
        };
        // `-p` is the object path (`-o` is mount *options* — passing the
        // path to `-o` silently misfires).
        const cmd = std.fmt.allocPrint(self.a.gpa, "udisksctl {s} -p {s}", .{ verb, obj }) catch return;
        defer self.a.gpa.free(cmd);
        _ = app_launch.launchExec(self.a.gpa, self.a.io, cmd);
        self.armUdisksRefresh();
    }

    /// A mount/unmount just left the building: drop the UDisks2 snapshot and
    /// force a re-query on each of the next few 1s rescans, so the icon flips
    /// as soon as the (forked, asynchronous) operation lands.
    fn armUdisksRefresh(self: *Desktop) void {
        self.udisks.invalidate();
        self.udisks_refresh_ticks = 8;
    }

    /// The dialog's Mount button (`desktop_icon_menu.cpp:881-909`): base 0 goes
    /// through UDisks2 — `udisksctl mount -p`, the stand-in for
    /// `svc.mount_async` — and, when "Mount at boot" is ticked, records the
    /// fstab entry via `AddConfigurationItem` (`add_fstab_async`). Bases 1/2
    /// `mkdir -p` + `mount` the raw device at the chosen path under pkexec,
    /// quoted through `sh -c` because `launchExec` spawns argv directly rather
    /// than through a shell. "Read-only" appends the `ro` mount option on both
    /// paths (and to the recorded fstab line).
    fn runMountDialogAction(self: *Desktop) void {
        const gpa = self.a.gpa;
        const io = self.a.io;
        if (self.mount_base == 0) {
            const cmd: ?[]const u8 = if (self.mount_object_path.len > 0)
                if (self.mount_readonly)
                    std.fmt.allocPrint(gpa, "udisksctl mount -p {s} --options ro", .{self.mount_object_path}) catch null
                else
                    std.fmt.allocPrint(gpa, "udisksctl mount -p {s}", .{self.mount_object_path}) catch null
            else if (self.mount_device.len > 0)
                if (self.mount_readonly)
                    std.fmt.allocPrint(gpa, "udisksctl mount -b {s} --options ro", .{self.mount_device}) catch null
                else
                    std.fmt.allocPrint(gpa, "udisksctl mount -b {s}", .{self.mount_device}) catch null
            else
                null;
            if (cmd) |c| {
                defer gpa.free(c);
                _ = app_launch.launchExec(gpa, io, c);
            }
            if (self.mount_boot) {
                const dir = desktop_icon_menu.mountCandidate(gpa, 0, mountUser(), self.mount_label) catch null;
                if (dir) |d| {
                    defer gpa.free(d);
                    var obuf: [64]u8 = undefined;
                    const opts = desktop_icon_menu.fstabOpts(&obuf, self.mount_readonly, self.mount_startup, self.mount_show_ui, self.mount_require_auth);
                    self.udisks.addFstab(self.mount_object_path, d, self.mount_fstype, self.mount_uuid, opts);
                }
            }
        } else {
            const dir = desktop_icon_menu.mountCandidate(gpa, self.mount_base, mountUser(), self.mount_label) catch null;
            if (dir) |d| {
                defer gpa.free(d);
                const qdir = shQuoteAlloc(gpa, d) catch null;
                if (qdir) |qd| {
                    defer gpa.free(qd);
                    const qdev = shQuoteAlloc(gpa, self.mount_device) catch null;
                    if (qdev) |qv| {
                        defer gpa.free(qv);
                        const sh_cmd = if (self.mount_readonly)
                            std.fmt.allocPrint(
                                gpa,
                                "sh -c \"pkexec mkdir -p {s} && pkexec mount -o ro {s} {s}\"",
                                .{ qd, qv, qd },
                            ) catch null
                        else
                            std.fmt.allocPrint(
                                gpa,
                                "sh -c \"pkexec mkdir -p {s} && pkexec mount {s} {s}\"",
                                .{ qd, qv, qd },
                            ) catch null;
                        if (sh_cmd) |c| {
                            defer gpa.free(c);
                            _ = app_launch.launchExec(gpa, io, c);
                        }
                    }
                }
            }
        }
        self.armUdisksRefresh();
        self.closeMountDialog();
        self.rescan(.{ .icons = true, .widgets = true, .menu = true });
    }

    /// Single-quote for an `sh -c` payload (C++ `sh_quote`): `'` becomes `'\''`.
    /// `launchExec`'s tokenizer only strips `"` around an argument, so the
    /// outer double quotes here survive into one `sh -c` argument while these
    /// single quotes protect paths with spaces from the inner shell parse.
    fn shQuoteAlloc(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.append(gpa, '\'');
        for (s) |ch| {
            if (ch == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, ch);
        }
        try out.append(gpa, '\'');
        return out.toOwnedSlice(gpa);
    }

    /// Stacked modes re-pack from scratch: drop saved slots like the C++
    /// `set_arrangement` does, so old grid positions can't pin icons.
    fn resetGridSlots(self: *Desktop) void {
        for (self.icons.items) |*ic| {
            ic.grid_col = -1;
            ic.grid_row = -1;
        }
    }

    /// Position the workspace cascade next to the main panel, flipping left
    /// on overflow and clamping vertically (C++ `layout_cascade_position`,
    /// which also refreshes both panel widths before placing).
    fn layoutWsCascade(self: *Desktop) void {
        const us = self.menuUs();
        self.menu_w = self.wsPanelWidth(.main);
        self.menu_sub_w = self.wsPanelWidth(self.menu_cascade);
        const b = desktop_menu.mainBounds(self.menu_x, self.menu_y, self.menu_w, us);
        const sub_h = desktop_menu.menuHeight(self.menu_cascade, us);
        const w: i32 = if (self.surfs.items.len > self.menu_layer) self.surfs.items[self.menu_layer].w else 1920;
        const h: i32 = if (self.surfs.items.len > self.menu_layer) self.surfs.items[self.menu_layer].h else 1080;
        const p = desktop_menu.cascadePos(b.x, b.y, b.w, self.menu_anchor, self.menu_sub_w, sub_h, w, h, us);
        self.menu_sub_x = p.x;
        self.menu_sub_y = p.y;
    }

    /// Position the compress cascade next to the icon menu
    /// (`layout_compress_cascade`, which refreshes its width first).
    fn layoutIconCascade(self: *Desktop) void {
        const us = self.menuUs();
        self.icon_menu_w = self.iconMenuWidth();
        self.compress_w = self.compressWidth();
        const sub_h = desktop_icon_menu.menuHeight(desktop_icon_menu.compress_sub_rows, us);
        const w: i32 = if (self.surfs.items.len > self.menu_layer) self.surfs.items[self.menu_layer].w else 1920;
        const h: i32 = if (self.surfs.items.len > self.menu_layer) self.surfs.items[self.menu_layer].h else 1080;
        const p = desktop_icon_menu.compressCascadePos(
            self.menu_x,
            self.menu_y,
            self.icon_menu_w,
            self.icon_press.anchor_row,
            self.compress_w,
            sub_h,
            w,
            h,
            us,
        );
        self.menu_sub_x = p.x;
        self.menu_sub_y = p.y;
    }

    /// Whether icon cells paint and hit-test at all (env kill-switch +
    /// persisted visible flag, like C++ `icons_visible`).
    fn iconsShown(self: *Desktop) bool {
        if (self.icons_env_disabled) return false;
        return self.prefs_state.icons_visible;
    }

    /// Workspace-menu action dispatch for an explicit panel: main releases
    /// pass .main, cascade releases pass the captured cascade (the stored
    /// field may already have moved on). Chevron rows switch the cascade
    /// and leave the menu open; everything else closes it.
    fn runDesktopMenuRow(self: *Desktop, panel: desktop_menu.Panel, row: i32) void {
        const m = self.metrics();
        _ = m;
        switch (panel) {
            .main => switch (row) {
                0 => {
                    self.menu_cascade = .view;
                    self.menu_anchor = 0;
                    self.menu_press = .{};
                    self.menu_hover = -1;
                    self.layoutWsCascade();
                    self.repaint();
                },
                1 => {
                    self.menu_cascade = .sort_by;
                    self.menu_anchor = 1;
                    self.menu_press = .{};
                    self.menu_hover = -1;
                    self.layoutWsCascade();
                    self.repaint();
                },
                3 => {
                    self.clipboardCopy(false, self.marquee_sel.items);
                    self.closeWsMenu();
                    self.repaint();
                },
                4 => {
                    self.pasteClipboard();
                    self.closeWsMenu();
                    self.repaint();
                },
                5 => {
                    self.undoPaste();
                    self.closeWsMenu();
                    self.repaint();
                },
                7 => {
                    // Delete the marquee selection (or the single selected icon).
                    if (self.marquee_sel.items.len > 0) {
                        for (self.marquee_sel.items) |mi| self.trashIconNoRescan(mi);
                        self.marquee_sel.clearRetainingCapacity();
                        self.rescan(.{ .icons = true, .widgets = true, .menu = true });
                    } else if (self.selected >= 0) {
                        self.trashIcon(@intCast(self.selected));
                    }
                    self.closeWsMenu();
                    self.repaint();
                },
                8 => self.rescan(.{ .icons = true, .widgets = true, .menu = true }),
                9 => {
                    // Display settings: settings app opened straight onto
                    // the Monitors tab (id 7), like C++ embed_show_tab(7).
                    self.launchSettingsTab(7);
                    self.closeWsMenu();
                    self.repaint();
                },
                10 => {
                    if (!self.launchSibling("horizon-settings")) {
                        _ = app_launch.launchExec(self.a.gpa, self.a.io, "horizon-settings");
                    }
                    self.closeWsMenu();
                    self.repaint();
                },
                11 => {
                    // Wallpaper: settings app opened straight onto the
                    // Wallpaper tab (id 6).
                    self.launchSettingsTab(6);
                    self.closeWsMenu();
                    self.repaint();
                },
                12 => {
                    if (!self.launchSibling("horizon-live-wallpaper")) {
                        _ = app_launch.launchExec(self.a.gpa, self.a.io, "horizon-live-wallpaper");
                    }
                    self.closeWsMenu();
                    self.repaint();
                },
                13 => {
                    self.menu_cascade = .add_new;
                    self.menu_anchor = 13;
                    self.menu_press = .{};
                    self.menu_hover = -1;
                    self.layoutWsCascade();
                    self.repaint();
                },
                else => {},
            },
            .view => switch (row) {
                0 => {
                    // Show desktop icons.
                    self.prefs_state.icons_visible = true;
                    self.savePrefs();
                    self.rescan(.{ .icons = true, .widgets = true, .menu = true });
                    self.closeWsMenu();
                    self.repaint();
                },
                1 => {
                    // Don't show: persist the flag; repaint skips the cells.
                    self.prefs_state.icons_visible = false;
                    self.savePrefs();
                    self.closeWsMenu();
                    self.repaint();
                },
                3 => {
                    self.prefs_state.size = .large;
                    self.savePrefs();
                    self.layoutAll();
                    self.resolveAllIcons();
                    self.closeWsMenu();
                    self.repaint();
                },
                4 => {
                    self.prefs_state.size = .medium;
                    self.savePrefs();
                    self.layoutAll();
                    self.resolveAllIcons();
                    self.closeWsMenu();
                    self.repaint();
                },
                5 => {
                    self.prefs_state.size = .small;
                    self.savePrefs();
                    self.layoutAll();
                    self.resolveAllIcons();
                    self.closeWsMenu();
                    self.repaint();
                },
                else => {},
            },
            .sort_by => switch (row) {
                0 => {
                    self.prefs_state.arrangement = .auto_arrange;
                    self.layoutAll();
                    self.savePrefs();
                    self.closeWsMenu();
                    self.repaint();
                },
                1 => {
                    self.prefs_state.arrangement = .align_to_grid;
                    self.layoutAll();
                    self.savePrefs();
                    self.closeWsMenu();
                    self.repaint();
                },
                2 => {
                    self.prefs_state.arrangement = .stacked;
                    self.resetGridSlots();
                    self.layoutAll();
                    self.savePrefs();
                    self.closeWsMenu();
                    self.repaint();
                },
                3 => {
                    self.prefs_state.arrangement = .stacked_right;
                    self.resetGridSlots();
                    self.layoutAll();
                    self.savePrefs();
                    self.closeWsMenu();
                    self.repaint();
                },
                5 => {
                    self.prefs_state.sort = .name;
                    desktop_icons.sortIcons(self.icons.items, .name);
                    self.layoutAll();
                    self.savePrefs();
                    self.closeWsMenu();
                    self.repaint();
                },
                6 => {
                    self.prefs_state.sort = .type;
                    desktop_icons.sortIcons(self.icons.items, .type);
                    self.layoutAll();
                    self.savePrefs();
                    self.closeWsMenu();
                    self.repaint();
                },
                else => {},
            },
            .add_new => switch (row) {
                0 => {
                    self.createDesktopFile("New Text Document.txt", false);
                    self.closeWsMenu();
                    self.rescan(.{ .icons = true, .widgets = true, .menu = true });
                },
                1 => {
                    self.createDesktopFile("New Folder", true);
                    self.closeWsMenu();
                    self.rescan(.{ .icons = true, .widgets = true, .menu = true });
                },
                else => {},
            },
        }
    }

    /// Create an empty file/folder on the desktop with a unique name.
    fn createDesktopFile(self: *Desktop, base: []const u8, is_dir: bool) void {
        const gpa = self.a.gpa;
        const io = self.a.io;
        const home = self.a.home orelse return;
        const dir = std.fmt.allocPrint(gpa, "{s}/Desktop", .{home}) catch return;
        defer gpa.free(dir);
        const cwd = std.Io.Dir.cwd();
        var n: usize = 0;
        while (n < 100) : (n += 1) {
            const name = if (n == 0)
                std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, base }) catch return
            else
                std.fmt.allocPrint(gpa, "{s}/{s} {d}", .{ dir, base, n }) catch return;
            defer gpa.free(name);
            if (cwd.statFile(io, name, .{})) |_| continue else |_| {}
            if (is_dir) {
                cwd.createDirPath(io, name) catch continue;
            } else {
                cwd.writeFile(io, .{ .sub_path = name, .data = "" }) catch continue;
            }
            break;
        }
    }

    fn savePrefs(self: *Desktop) void {
        const gpa = self.a.gpa;
        if (config.settingsDir(gpa, self.a.xdg_config, self.a.home)) |sdir| {
            defer gpa.free(sdir);
            const lp = std.fs.path.join(gpa, &.{ sdir, "desktop_icons_layout.txt" }) catch return;
            defer gpa.free(lp);
            var grid: std.ArrayList(desktop_prefs.GridEntry) = .empty;
            defer {
                for (grid.items) |g| gpa.free(g.path);
                grid.deinit(gpa);
            }
            for (self.icons.items) |ic| {
                const duped = gpa.dupe(u8, ic.desktop_path) catch continue;
                grid.append(gpa, .{
                    .path = duped,
                    .slot = .{ .col = ic.grid_col, .row = ic.grid_row, .layer = ic.layer },
                }) catch {
                    gpa.free(duped);
                    continue;
                };
            }
            desktop_prefs.saveFile(self.a.io, gpa, lp, self.prefs_state, grid.items) catch {};
        } else |_| {}
    }

    /// Icon-menu action dispatch for the target icon.
    /// Icon-menu action dispatch. Takes the resolved kind + action index so
    /// both main rows and compress-cascade rows funnel through one switch.
    /// Callers close the menu (or leave a cascade open) themselves.
    fn runIconMenuKind(self: *Desktop, kind: desktop_icon_menu.CtxKind, action_index: u16) void {
        if (self.icon_menu_target < 0 or self.icon_menu_target >= self.icons.items.len) return;
        const target: usize = @intCast(self.icon_menu_target);
        const row_kind = kind;
        const row_action = action_index;
        switch (row_kind) {
            .open => {
                self.launchIcon(target);
                self.closeIconMenu();
                self.repaint();
            },
            .open_location => {
                const ic = self.icons.items[target];
                const dir = std.fs.path.dirname(ic.desktop_path) orelse return;
                const cmd = xdg_ops.openPathCmd(self.a.gpa, dir) catch return;
                defer self.a.gpa.free(cmd);
                _ = app_launch.launchExec(self.a.gpa, self.a.io, cmd);
                self.closeIconMenu();
                self.repaint();
            },
            .mount, .unmount => {
                const ic = self.icons.items[target];
                const gpa = self.a.gpa;
                // Never a target: the drive lacks a UDisks2 identity.
                if (ic.drive_object_path.len == 0) return;
                if (kind == .unmount) {
                    // Deferred Unmount (`:583-588`): run on the next tick after
                    // the menu has closed (`mountDialogDeferredKind = Unmount`).
                    if (gpa.dupe(u8, ic.drive_object_path)) |obj| {
                        self.mount_deferred = .unmount;
                        self.mount_deferred_path = obj;
                    } else |_| {}
                    self.closeIconMenu();
                    self.repaint();
                    return;
                }
                // Mount: a drive with an fstab entry mounts straight away —
                // UDisks2 picks the fstab path up itself (`:562-568`,
                // `has_fstab_entry` → deferred FstabMount, no dialog).
                if (ic.drive_has_fstab) {
                    if (gpa.dupe(u8, ic.drive_object_path)) |obj| {
                        self.mount_deferred = .fstab_mount;
                        self.mount_deferred_path = obj;
                    } else |_| {}
                    self.closeIconMenu();
                    self.repaint();
                    return;
                }
                // Otherwise the centered dialog asks where to mount
                // (`:569-583`, `mountDialogOpen = true`). The menu closed
                // before this row ran, so the dialog is what stays on screen.
                self.openMountDialog(target);
            },
            .delete => {
                var sel_buf: [64]usize = undefined;
                const sel = self.iconSelection(target, &sel_buf);
                for (sel) |mi| self.trashIconNoRescan(mi);
                self.marquee_sel.clearRetainingCapacity();
                self.closeIconMenu();
                self.rescan(.{ .icons = true, .widgets = true, .menu = true });
            },
            .empty_trash => {
                self.emptyTrash();
                self.closeIconMenu();
                self.repaint();
            },
            .open_with => {
                // No picker UI in this pass: default-open when
                // the dialog is unavailable; the row stays for parity.
                self.launchIcon(target);
                self.closeIconMenu();
                self.repaint();
            },
            .desktop_action => {
                self.launchDesktopAction(target, row_action);
                self.closeIconMenu();
                self.repaint();
            },
            .run_elevated => {
                if (target < self.icons.items.len) {
                    const ic = self.icons.items[target];
                    if (ic.exec.len > 0) {
                        const inner = desktop_xdg.expandExecTokens(
                            self.a.gpa,
                            ic.exec,
                            ic.desktop_path,
                            ic.desktop_path,
                            ic.name,
                        ) catch null;
                        if (inner) |ex| {
                            defer self.a.gpa.free(ex);
                            const wrapped = desktop_xdg.pkexecWrap(self.a.gpa, ex) catch null;
                            if (wrapped) |w| {
                                defer self.a.gpa.free(w);
                                _ = app_launch.launchExec(self.a.gpa, self.a.io, w);
                            }
                        }
                    }
                }
                self.closeIconMenu();
                self.repaint();
            },
            .pin_taskbar => {
                self.toggleDockPin(target);
                self.closeIconMenu();
                self.repaint();
            },
            .pin_start => {
                logz.log("pin to Start menu is owned by the dock process", .{});
                self.closeIconMenu();
                self.repaint();
            },
            .cut => {
                var sel_buf: [64]usize = undefined;
                self.clipboardCopy(true, self.iconSelection(target, &sel_buf));
                self.closeIconMenu();
                self.repaint();
            },
            .copy => {
                var sel_buf: [64]usize = undefined;
                self.clipboardCopy(false, self.iconSelection(target, &sel_buf));
                self.closeIconMenu();
                self.repaint();
            },
            .create_shortcut => {
                self.doShortcut(target);
                self.closeIconMenu();
                self.repaint();
            },
            .rename => {
                self.doRename(target);
                self.closeIconMenu();
                self.repaint();
            },
            .properties => {
                if (target < self.icons.items.len) {
                    const ic = self.icons.items[target];
                    const parent = std.fs.path.dirname(ic.desktop_path) orelse ".";
                    const cmd = xdg_ops.openPathCmd(self.a.gpa, parent) catch null;
                    if (cmd) |c| {
                        defer self.a.gpa.free(c);
                        _ = app_launch.launchExec(self.a.gpa, self.a.io, c);
                    }
                }
                self.closeIconMenu();
                self.repaint();
            },
            .extract_archive => {
                var sel_buf: [64]usize = undefined;
                self.doExtract(self.iconSelection(target, &sel_buf));
                self.closeIconMenu();
                self.repaint();
            },
            .compress_zip => {
                var sel_buf: [64]usize = undefined;
                self.doCompress(.zip, self.iconSelection(target, &sel_buf));
                self.closeIconMenu();
                self.repaint();
            },
            .compress_tar_gz => {
                var sel_buf: [64]usize = undefined;
                self.doCompress(.tar_gz, self.iconSelection(target, &sel_buf));
                self.closeIconMenu();
                self.repaint();
            },
            .compress_tar => {
                var sel_buf: [64]usize = undefined;
                self.doCompress(.tar, self.iconSelection(target, &sel_buf));
                self.closeIconMenu();
                self.repaint();
            },
            .compress_7z => {
                var sel_buf: [64]usize = undefined;
                self.doCompress(.seven_z, self.iconSelection(target, &sel_buf));
                self.closeIconMenu();
                self.repaint();
            },
            else => {},
        }
    }

    fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
        const self: *Desktop = @ptrCast(@alignCast(ctx));
        const P = &self.perf;
        const prev_cb = P.cb;
        P.cb = .button;
        const t_button = perfNowNs();
        P.buttons += 1;
        defer {
            P.cb = prev_cb;
            const dt = perfNowNs() -% t_button;
            P.button_ns += dt;
            if (dt > P.button_max_ns) P.button_max_ns = dt;
            if (dt >= Perf.slow_button_ns and Perf.slowLogAllowed(&P.slow_button_log_ns, t_button)) {
                logz.log("perf: button {d:.1}ms", .{perfMs(dt)});
            }
        }
        self.syncPointer();
        const px = self.ptr_x;
        const py = self.ptr_y;
        const pressed = state == 1;
        if (button == 0x110) { // left
            if (pressed) {
                // Menu presses arm; the action fires on a matching release.
                if (self.ui.desktop_menu_open) {
                    const main_row = self.wsMainHit(px, py);
                    const sub_row = self.wsSubHit(px, py);
                    if (!self.menu_press.press(main_row, sub_row, self.wsInAny(px, py))) {
                        self.closeWsMenu();
                        self.repaint();
                    }
                    return;
                }
                if (self.ui.icon_menu_open) {
                    const main_row = self.iconMainHit(px, py);
                    const sub_row = self.iconCompressHit(px, py);
                    if (main_row == -2 and sub_row == -2) {
                        self.closeIconMenu();
                        self.repaint();
                        return;
                    }
                    self.icon_press.press(main_row, sub_row);
                    // Pressing the Compress row opens its cascade and stays open.
                    if (main_row >= 0 and main_row < self.icon_menu_rows.len and
                        desktop_icon_menu.isCompressSubmenu(self.icon_menu_rows[@intCast(main_row)]))
                    {
                        self.icon_press.cascade_open = true;
                        self.icon_press.anchor_row = main_row;
                        self.layoutIconCascade();
                        self.repaint();
                    }
                    return;
                }
                // Mount dialog press: arm the item under the cursor, or close
                // when the press lands outside the card
                // (`desktop_mount_dialog_handle_left_press`, checked after both
                // menus in the C++ press order).
                if (self.ui.mount_dialog_open) {
                    const item = self.mountHit(px, py);
                    if (item == -2) {
                        self.closeMountDialog();
                        self.repaint();
                    } else {
                        self.mount_arm_item = item;
                    }
                    return;
                }
                const m = self.metrics();
                const layer_idx: i32 = @intCast(self.menu_layer);
                // Widgets get first refusal on press (click/drag arm).
                if (self.w_inited) {
                    if (self.wlayer.press(px, py, self.pointerOutput(), false, self.a.gpa) != .ignored) {
                        self.repaint();
                        return;
                    }
                }
                const hit_opt = if (self.iconsShown())
                    desktop_icons.hitIndex(self.icons.items, layer_idx, px, py, m)
                else
                    null;
                if (hit_opt) |idx| {
                    self.selected = @intCast(idx);
                    self.press_idx = @intCast(idx);
                    self.press_x = px;
                    self.press_y = py;
                    self.press_moved = false;
                    self.ui.icon_dragging = true;
                    self.repaint();
                } else {
                    self.selected = -1;
                    self.last_click_idx = -1;
                    self.marquee_sel.clearRetainingCapacity();
                    self.ui.marquee_dragging = true;
                    self.marquee = .{ .x0 = px, .y0 = py, .x1 = px, .y1 = py };
                    self.repaint();
                }
            } else {
                // Mount dialog release comes first (C++ release priority:
                // open_with/world_clock aside, it precedes every menu). Press
                // must match release on the same item; a mismatch inside the
                // card just disarms, one outside closes the card.
                if (self.ui.mount_dialog_open) {
                    const armed = self.mount_arm_item;
                    self.mount_arm_item = -1;
                    const item = self.mountHit(px, py);
                    if (item != armed or item < 0) {
                        if (item == -2) self.closeMountDialog();
                        self.repaint();
                        return;
                    }
                    if (item == desktop_icon_menu.mount_item_combo) {
                        self.mount_dropdown_open = !self.mount_dropdown_open;
                    } else if (item >= 1 and item <= 3) {
                        self.mount_base = @intCast(item - 1);
                        self.mount_dropdown_open = false;
                    } else if (item == desktop_icon_menu.mount_item_boot) {
                        self.mount_boot = !self.mount_boot;
                        // Dropping the master disarms any hover on the
                        // sub-options (they read insensitive from here on).
                        if (!self.mount_boot and desktop_icon_menu.mountItemNeedsBoot(self.mount_hover_item))
                            self.mount_hover_item = -1;
                    } else if (item == desktop_icon_menu.mount_item_readonly) {
                        self.mount_readonly = !self.mount_readonly;
                    } else if (item == desktop_icon_menu.mount_item_startup or
                        item == desktop_icon_menu.mount_item_showui or
                        item == desktop_icon_menu.mount_item_auth)
                    {
                        // fstab-only sub-options: dead unless the master is on
                        // (Disks leaves its grid insensitive in that state).
                        if (self.mount_boot) {
                            if (item == desktop_icon_menu.mount_item_startup) self.mount_startup = !self.mount_startup;
                            if (item == desktop_icon_menu.mount_item_showui) self.mount_show_ui = !self.mount_show_ui;
                            if (item == desktop_icon_menu.mount_item_auth) self.mount_require_auth = !self.mount_require_auth;
                        }
                    } else if (item == desktop_icon_menu.mount_item_mount) {
                        self.runMountDialogAction();
                    } else {
                        self.closeMountDialog(); // Cancel
                    }
                    self.repaint();
                    return;
                }
                // Release with a menu open: press-must-match-release, else
                // the menu just closes (C++ left_release).
                if (self.ui.desktop_menu_open) {
                    const main_row = self.wsMainHit(px, py);
                    const sub_row = self.wsSubHit(px, py);
                    const armed_main = self.menu_press.arm_main;
                    const armed_sub = self.menu_press.arm_sub;
                    if (sub_row >= 0 and armed_sub >= 0 and sub_row == armed_sub) {
                        const cascade = self.menu_cascade;
                        self.closeWsMenu();
                        self.runDesktopMenuRow(cascade, sub_row);
                        return;
                    }
                    if (main_row >= 0 and armed_main >= 0 and main_row == armed_main and armed_sub < 0) {
                        if (desktop_menu.chevronPanel(main_row)) |next| {
                            self.menu_cascade = next;
                            self.menu_anchor = main_row;
                            self.menu_press = .{};
                            self.layoutWsCascade();
                            self.repaint();
                            return;
                        }
                        self.closeWsMenu();
                        self.runDesktopMenuRow(.main, main_row);
                        return;
                    }
                    self.closeWsMenu();
                    self.repaint();
                    return;
                }
                if (self.ui.icon_menu_open) {
                    const main_row = self.iconMainHit(px, py);
                    const sub_row = self.iconCompressHit(px, py);
                    const armed_main = self.icon_press.arm_main;
                    const armed_comp = self.icon_press.arm_compress;
                    if (sub_row >= 0 and armed_comp >= 0 and sub_row == armed_comp) {
                        const kinds = [_]desktop_icon_menu.CtxKind{ .compress_zip, .compress_tar_gz, .compress_tar, .compress_7z };
                        self.closeIconMenu();
                        self.runIconMenuKind(kinds[@intCast(sub_row)], 0);
                        return;
                    }
                    if (main_row >= 0 and armed_main >= 0 and main_row == armed_main and armed_comp < 0 and
                        main_row < self.icon_menu_rows.len)
                    {
                        const r = self.icon_menu_rows[@intCast(main_row)];
                        if (desktop_icon_menu.isCompressSubmenu(r)) {
                            self.icon_press.cascade_open = true;
                            self.icon_press.anchor_row = main_row;
                            self.icon_press.arm_main = -1;
                            self.layoutIconCascade();
                            self.repaint();
                            return;
                        }
                        self.closeIconMenu();
                        self.runIconMenuKind(r.kind, r.action_index);
                        return;
                    }
                    self.closeIconMenu();
                    self.repaint();
                    return;
                }
                // Release on the pressed icon without a drag: first click
                // selects, second click within 400ms launches (C++ double-click).
                // Widget drag/resize commits first (positions persist).
                if (self.w_inited) {
                    if (self.wlayer.release(true, false, self.a.gpa)) |configs| {
                        _ = wdata.save(self.a.gpa, self.a.io, configs);
                        self.repaint();
                    }
                }
                if (self.ui.icon_dragging and !self.press_moved and self.press_idx >= 0 and self.iconsShown()) {
                    const idx = self.press_idx;
                    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
                    _ = linux.clock_gettime(.MONOTONIC, &ts);
                    const now_ms: i64 = ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
                    if (idx == self.last_click_idx and now_ms - self.last_click_ms < 400) {
                        self.last_click_idx = -1;
                        self.last_click_ms = -10000;
                        self.launchIcon(@intCast(idx));
                    } else {
                        self.last_click_idx = idx;
                        self.last_click_ms = now_ms;
                        self.selected = idx;
                    }
                }
                if (self.ui.icon_dragging and self.press_moved and self.press_idx >= 0) {
                    // Settle the dragged icon: snap, swap with any occupant,
                    // resolve collisions, then persist the grid.
                    const idx: usize = @intCast(self.press_idx);
                    if (idx < self.icons.items.len) {
                        const m = self.metrics();
                        const w = if (self.surfs.items.len > 0) self.surfs.items[0].w else 1920;
                        const h = if (self.surfs.items.len > 0) self.surfs.items[0].h else 1080;
                        const layer_idx: i32 = @intCast(self.menu_layer);
                        _ = desktop_icons.finishSingleDrag(self.icons.items, idx, w, m, layer_idx, h, 0, 0);
                    }
                    self.savePrefs();
                }
                if (self.ui.marquee_dragging) {
                    self.ui.marquee_dragging = false;
                    var fx0 = @min(self.marquee.x0, self.marquee.x1);
                    var fy0 = @min(self.marquee.y0, self.marquee.y1);
                    var fx1 = @max(self.marquee.x0, self.marquee.x1);
                    var fy1 = @max(self.marquee.y0, self.marquee.y1);
                    const w = if (self.surfs.items.len > 0) self.surfs.items[0].w else 1920;
                    const h = if (self.surfs.items.len > 0) self.surfs.items[0].h else 1080;
                    desktop_marquee.normalizeFinalRect(&fx0, &fy0, &fx1, &fy1, w, h);
                    // Persist the rubber-band selection for copy/delete.
                    self.marquee_sel.clearRetainingCapacity();
                    const m = self.metrics();
                    const layer_idx: i32 = @intCast(self.menu_layer);
                    var buf: [256]usize = undefined;
                    const n = desktop_icons.selectInRect(self.icons.items, layer_idx, fx0, fy0, fx1, fy1, m, &buf);
                    for (buf[0..n]) |mi| self.marquee_sel.append(self.a.gpa, mi) catch break;
                }
                self.ui.icon_dragging = false;
                self.press_idx = -1;
                self.press_moved = false;
                self.repaint();
            }
        } else if (button == 0x111 and pressed) { // right
            // Widget resize arms first; otherwise replace (don't dismiss):
            // a right-click always opens the menu for what's under the pointer.
            if (self.w_inited) {
                if (self.wlayer.press(px, py, self.pointerOutput(), true, self.a.gpa) != .ignored) {
                    return;
                }
            }
            const m = self.metrics();
            const layer_idx: i32 = @intCast(self.menu_layer);
            const rhit = if (self.iconsShown())
                desktop_icons.hitIndex(self.icons.items, layer_idx, px, py, m)
            else
                null;
            if (rhit) |idx| {
                self.selected = @intCast(idx);
                self.openIconMenu(idx, px, py, self.menu_layer);
            } else {
                self.openWorkspaceMenu(px, py, self.menu_layer);
            }
        } else if (button == 0x111) { // right release: resize commit
            if (self.w_inited) {
                if (self.wlayer.release(false, true, self.a.gpa)) |configs| {
                    _ = wdata.save(self.a.gpa, self.a.io, configs);
                    self.repaint();
                }
            }
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;
    logz.init(io, init.environ_map.get("HOME"), "horizon-desktop-zig");
    defer logz.deinit();

    var a = app_mod.App.init(gpa, io, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME")) catch |e| {
        logz.err("init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer a.deinit();

    if (!a.loaded.cfg.desktop_enabled) {
        logz.log("desktop disabled in config; exiting", .{});
        return 0;
    }

    var d = Desktop{ .a = &a, .arena = std.heap.ArenaAllocator.init(gpa) };
    defer d.deinit();
    d.icons_map = std.StringHashMap(Desktop.IconArt).init(gpa);
    d.icons_map_init = true;
    d.thumbs_map = std.StringHashMap(Desktop.IconArt).init(gpa);
    d.thumbs_map_init = true;
    d.wlayer.init(gpa);
    d.w_inited = true;
    d.mpris = mpris_mod.Client.init(gpa);
    d.mpris_inited = true;
    d.udisks = udisks_mod.Client.init(gpa);
    d.udisks_inited = true;
    media_bus.setHandler(.{ .ctx = @ptrCast(&d), .act = handleMediaAction });
    icon_cache.initGlobal(gpa, io);
    defer icon_cache.deinitGlobal();
    a.on_reload = Desktop.onReload;
    a.reload_ctx = &d;

    // One BOTTOM surface triple per output (C++ desktop_layer: icon shell,
    // widgets, and menus each carry their own namespace so Hyprland blur
    // rules match; all anchor ALL, 0x0, exclusive -1 (full-output background
    // semantics — immune to other monitors' exclusive zones), keyboard NONE).
    // Buffer pairs are heap-pinned: the wl_buffer release listener captures
    // the ShmBuffer address, so pairs must never move after ensure.
    const surf_ctx = gpa.alloc(SurfCtx, @max(1, a.bound.outputs.items.len)) catch null;
    defer if (surf_ctx) |sc| gpa.free(sc);
    for (a.bound.outputs.items, 0..) |o, oi| {
        if (o.width <= 0 or o.height <= 0) continue;
        var s = Surf{ .output = oi, .w = o.width, .h = o.height };
        s.shm = gpa.create(shm_mod.ShmPair) catch continue;
        s.shm.* = shm_mod.ShmPair.init(gpa);
        s.wshm = gpa.create(shm_mod.ShmPair) catch {
            s.shm.deinit();
            gpa.destroy(s.shm);
            continue;
        };
        s.wshm.* = shm_mod.ShmPair.init(gpa);
        s.mshm = gpa.create(shm_mod.ShmPair) catch {
            s.wshm.deinit();
            gpa.destroy(s.wshm);
            s.shm.deinit();
            gpa.destroy(s.shm);
            continue;
        };
        s.mshm.* = shm_mod.ShmPair.init(gpa);
        // configure hook context: stable slot per output (surfaces move in
        // the list, this array does not).
        if (surf_ctx) |sc| {
            if (oi < sc.len) {
                sc[oi] = .{ .desktop = &d, .surf = d.surfs.items.len };
                s.surface.ctx = @ptrCast(&sc[oi]);
                s.wsurf.ctx = @ptrCast(&sc[oi]);
                s.msurf.ctx = @ptrCast(&sc[oi]);
            }
        }
        s.surface.on_configure = onLayerConfigure;
        s.wsurf.on_configure = onLayerConfigure;
        s.msurf.on_configure = onLayerConfigure;
        s.surface.on_configure = onLayerConfigure;
        s.wsurf.on_configure = onLayerConfigure;
        s.msurf.on_configure = onLayerConfigure;
        s.output_name = gpa.dupe(u8, o.name) catch "";
        if (!createLayerSurface(&a, o, ns.desktop_shell, &s.surface)) {
            s.deinit(gpa);
            continue;
        }
        if (!createLayerSurface(&a, o, ns.desktop_widgets, &s.wsurf)) {
            s.deinit(gpa);
            continue;
        }
        if (!createLayerSurface(&a, o, ns.desktop_menus, &s.msurf)) {
            s.deinit(gpa);
            continue;
        }
        s.w = @intCast(s.surface.configured_width);
        s.h = @intCast(s.surface.configured_height);
        if (s.w <= 0) s.w = o.width;
        if (s.h <= 0) s.h = o.height;
        // `s.w`/`s.h` stay logical (paint draws in them under cairo_scale);
        // the buffers are allocated at device pixels.
        const dsc: i32 = @max(1, s.surface.scale);
        logz.log("layer {d} ({s}) created {d}x{d} scale {} buffer {d}x{d} (output {d}x{d})", .{ oi, o.name, s.w, s.h, s.surface.scale, s.w * dsc, s.h * dsc, o.width, o.height });
        if (!s.shm.ensure(a.bound.shm, "eh-desktop", s.w * dsc, s.h * dsc) or
            !s.wshm.ensure(a.bound.shm, "eh-desktop-widgets", s.w * dsc, s.h * dsc) or
            !s.mshm.ensure(a.bound.shm, "eh-desktop-menus", s.w * dsc, s.h * dsc))
        {
            s.deinit(gpa);
            continue;
        }
        d.surfs.append(gpa, s) catch {
            s.deinit(gpa);
            break;
        };
    }
    if (d.surfs.items.len == 0) {
        logz.err("no desktop surfaces", .{});
        return 1;
    }

    if (a.bound.seat_obj) |seat| {
        seat.on_pointer_enter = Desktop.onEnter;
        seat.on_pointer_motion = Desktop.onMotion;
        seat.on_pointer_button = Desktop.onButton;
        seat.cb_ctx = &d;
    } else {
        logz.err("input: no wl_seat bound, desktop will be static", .{});
    }
    if (init.environ_map.get("EH_DISABLE_DESKTOP_ICONS")) |v| {
        d.icons_env_disabled = v.len > 0 and v[0] == '1';
    }
    // The 5s perf summary is on while the desktop is profiled; unset or any
    // value other than "0" keeps it, `EH_DESKTOP_PERF=0` silences it.
    d.perf.enabled = if (init.environ_map.get("EH_DESKTOP_PERF")) |v|
        !(v.len > 0 and v[0] == '0')
    else
        true;
    eh.desktop_widgets_cider.perf_force = d.perf.enabled;
    d.perf.cb = .startup;
    d.rescan(.{ .icons = true, .widgets = true, .menu = true });
    d.reloadWidgets();
    d.armAnim();
    d.repaint();
    d.perf.cb = .none;
    logz.log("running surfaces={d} widgets={d}", .{ d.surfs.items.len, d.wlayer.host.instanceCount() });
    {
        // inotify is not recursive: watch the desktop component dir and the
        // `appearance` subdir (widget-card and desktop-menu alphas) so a
        // settings save lands without a restart.
        var watch_owned: [2][]u8 = undefined;
        var watch_dirs: [2][]const u8 = undefined;
        var n_watch: usize = 0;
        for ([_][]const u8{ "desktop", "appearance" }) |comp| {
            if (config.componentDir(gpa, a.xdg_config, a.home, comp)) |dir| {
                if (std.mem.eql(u8, comp, "appearance")) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
                watch_owned[n_watch] = dir;
                watch_dirs[n_watch] = dir;
                n_watch += 1;
            } else |_| {}
        }
        defer for (watch_owned[0..n_watch]) |p| gpa.free(p);
        a.startWatching(watch_dirs[0..n_watch]);
    }
    // Widget state files, which the watch above cannot see: the layout `.txt`
    // is not a toml (its drain only matches `*.toml`), and
    // `desktop_widgets/desktop_widgets.toml` sits a level below the
    // non-recursive settings watch. One inotify fd carries both watches and
    // one callback reloads the layer — without them Add / Remove / the
    // per-slot toggle land on disk and the desktop keeps painting what it
    // read at boot.
    {
        var watching = false;
        if (d.stateDir()) |sdir| {
            defer gpa.free(sdir);
            watching = d.widget_watch.watchConfigDir(sdir);
        }
        if (config.componentDir(gpa, a.xdg_config, a.home, "desktop_widgets")) |dw_dir| {
            defer gpa.free(dw_dir);
            // `section_store` creates this dir on the tab's first save; make
            // it now so the watch is never installed against a missing dir.
            std.Io.Dir.cwd().createDirPath(io, dw_dir) catch {};
            if (watching) {
                _ = d.widget_watch.watchExtraDir(dw_dir);
            } else watching = d.widget_watch.watchConfigDir(dw_dir);
        } else |_| {}
        if (watching) {
            a.loop.watchFd(d.widget_watch.pollFd(), std.posix.POLL.IN, Desktop.onWidgetFd, @ptrCast(&d)) catch {
                d.widget_watch.close();
                logz.err("widgets: cannot watch widget state files; edits need a restart", .{});
            };
        } else logz.err("widgets: cannot watch widget state files; edits need a restart", .{});
    }
    _ = a.conn.flush();

    const timer_fd: i32 = timerFd(1000) orelse -1;
    defer {
        if (timer_fd >= 0) _ = linux.close(timer_fd);
    }
    if (timer_fd >= 0) a.loop.watchFd(timer_fd, std.posix.POLL.IN, onTick, @ptrCast(&d)) catch {};
    d.main_tid = linux.gettid();
    d.beat_ns.store(perfNowNs(), .monotonic);
    _ = std.Thread.spawn(.{}, stallWatch, .{&d}) catch null;
    a.run();
    d.watchdog_stop.store(true, .monotonic);
    return 0;
}

/// Stable per-output context for layer configure callbacks (surfaces move
/// in the list when it reallocates; this slot array does not).
const SurfCtx = struct {
    desktop: *Desktop,
    surf: usize,
};

/// Runtime reconfigure (taskbar/dock exclusive zones, hotplug): record the
/// latest size and adopt it once sizes settle (`armReconf`, 150 ms quiet).
/// Fires inside Wayland dispatch, including during startup roundtrips —
/// every step is guarded for a half-built surface.
///
/// Why debounced: at startup the compositor can flap a surface between two
/// sizes several times a second (seen live on DP-3: 1440 <-> 1362 seven
/// times in one second while the dock mapped). Adopting every intermediate
/// configure reallocates three fullscreen buffer pools, relayouts and
/// repaints each time — the whole desktop visibly grows and shrinks. A flap
/// that returns to the live size adopts nothing at all.
fn onLayerConfigure(ctx: *anyopaque, w: u32, h: u32) void {
    const sc: *SurfCtx = @ptrCast(@alignCast(ctx));
    const self = sc.desktop;
    if (sc.surf >= self.surfs.items.len) return;
    if (w == 0 or h == 0) return;
    const s = &self.surfs.items[sc.surf];
    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);
    if (s.w == iw and s.h == ih and s.pend_w < 0) return;
    s.pend_w = iw;
    s.pend_h = ih;
    self.armReconf();
}

fn onReconfTick(fd: i32, revents: i16, ctx: *anyopaque) void {
    const self: *Desktop = @ptrCast(@alignCast(ctx));
    var buf: [8]u8 = undefined;
    _ = linux.read(fd, &buf, buf.len);
    if ((revents & std.posix.POLL.IN) == 0) return;
    self.perf.reconfs += 1;
    const prev_cb = self.perf.cb;
    self.perf.cb = .reconf;
    defer self.perf.cb = prev_cb;
    var adopted = false;
    for (self.surfs.items) |*s| {
        if (s.pend_w < 0 or s.pend_h < 0) continue;
        const pw = s.pend_w;
        const ph = s.pend_h;
        s.pend_w = -1;
        s.pend_h = -1;
        if (s.w == pw and s.h == ph) continue;
        logz.log("layer {d} ({s}) configure {d}x{d} -> {d}x{d}", .{ s.output, s.output_name, s.w, s.h, pw, ph });
        s.w = pw;
        s.h = ph;
        if (pw > 0) logz.log("desktop: output {s} {d}x{d} icon fit {d:.2}", .{ s.output_name, pw, ph, Desktop.fitForH(ph) });
        // `s.w`/`s.h` stay logical (paint draws in them under cairo_scale);
        // the buffers are allocated at device pixels.
        const rsc: i32 = @max(1, s.surface.scale);
        if (!s.shm.ensure(self.a.bound.shm, "eh-desktop", s.w * rsc, s.h * rsc)) continue;
        if (!s.wshm.ensure(self.a.bound.shm, "eh-desktop-widgets", s.w * rsc, s.h * rsc)) continue;
        if (!s.mshm.ensure(self.a.bound.shm, "eh-desktop-menus", s.w * rsc, s.h * rsc)) continue;
        const m = self.metricsFit(Desktop.fitForH(s.h));
        desktop_icons.relayout(
            self.icons.items,
            @intCast(s.output),
            s.w,
            s.h,
            m,
            self.prefs_state.arrangement,
            self.prefs_state.sort,
            0,
            0,
        );
        adopted = true;
    }
    // A resolution change can move the max-fit raster size; re-resolve (no-op
    // unless icon_px/theme changed) so the cached art stays sharp, then repaint.
    if (adopted) {
        self.resolveAllIcons();
        self.repaint();
    }
}

fn createLayerSurface(a: *app_mod.App, o: anytype, namespace: []const u8, surf: *layer.Surface) bool {
    if (!surf.create(a.bound.compositor, a.bound.layer_shell, o.obj, .bottom, namespace)) return false;
    surf.setAnchor(layer.Anchor.top | layer.Anchor.bottom | layer.Anchor.left | layer.Anchor.right);
    // -1, not 0: a fullscreen background layer must ignore ALL exclusive
    // zones. With 0 the compositor kept sending DP-3 transient 1362px
    // configures (1440 - the DP-1 dock's 78px zone bleeding across outputs),
    // growing/shrinking the whole desktop every time the dock recommitted.
    // The wallpaper already uses -1 and never flaps. Reserves stay 0 in
    // `relayout` calls, so nothing else changes.
    surf.setExclusiveZone(-1);
    surf.setSize(0, 0);
    surf.commit();
    var ticks: u32 = 0;
    while (ticks < 100 and !surf.configured) : (ticks += 1) {
        if (!a.conn.roundtrip()) break;
    }
    return surf.configured;
}

fn timerFd(interval_ms: u32) ?i32 {
    const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
    if (rc < 0) return null;
    const fd: i32 = @intCast(rc);
    const spec = linux.itimerspec{
        .it_interval = .{ .sec = @intCast(interval_ms / 1000), .nsec = @intCast((interval_ms % 1000) * 1_000_000) },
        .it_value = .{ .sec = @intCast(interval_ms / 1000), .nsec = @intCast((interval_ms % 1000) * 1_000_000) },
    };
    if (linux.timerfd_settime(fd, .{}, &spec, null) != 0) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

fn onTick(fd: i32, revents: i16, ctx: *anyopaque) void {
    _ = revents;
    const self: *Desktop = @ptrCast(@alignCast(ctx));
    var buf: [8]u8 = undefined;
    _ = linux.read(fd, &buf, buf.len);
    self.beat_ns.store(perfNowNs(), .monotonic);
    const P = &self.perf;
    const prev_cb = P.cb;
    P.cb = .tick;
    const t_tick = perfNowNs();
    P.ticks += 1;
    defer {
        P.cb = prev_cb;
        const dt = perfNowNs() -% t_tick;
        P.tick_ns += dt;
        if (dt > P.tick_max_ns) P.tick_max_ns = dt;
        if (dt >= Perf.slow_tick_ns and Perf.slowLogAllowed(&P.slow_tick_log_ns, t_tick)) {
            logz.log("perf: tick {d:.1}ms", .{perfMs(dt)});
        }
    }
    eh.autostart.reapChildren();
    // Deferred mount/unmount fires on the tick after its menu closed (C++
    // `desktop_mount_dialog_process_deferred_action` in the standalone loop).
    // It only forks `udisksctl`, so it runs ahead of the drag/menu guards.
    self.runMountDeferred();
    // Widget second-ticks + feeds (MPRIS poll, 10-min weather).
    if (self.w_inited) {
        // Poll first so the widgets' second-tick refresh reads this tick's
        // snapshot; publish unconditionally because a moving position alone
        // never changes the poll signature (see media_bus).
        if (self.mpris_inited) {
            const t = perfNowNs();
            _ = self.mpris.poll();
            media_bus.publish(self.mpris.snap);
            const d = perfNowNs() -% t;
            P.tick_mpris_ns += d;
            if (d > P.tick_mpris_max_ns) P.tick_mpris_max_ns = d;
        }
        {
            const t = perfNowNs();
            _ = self.wlayer.tickSecond(self.a.io);
            const d = perfNowNs() -% t;
            P.tick_widgets_ns += d;
            if (d > P.tick_widgets_max_ns) P.tick_widgets_max_ns = d;
        }
        const now_ms: i64 = @intCast(wctx.monotonicMs());
        if (now_ms - self.weather_last_ms > 10 * 60 * 1000) {
            self.weather_last_ms = now_ms;
            _ = weather_mod.request(self.a.gpa, self.a.io, self.weatherRequest());
        }
        self.armAnim();
    }
    // Never yank the icon list mid-gesture: a tick rescan during a drag,
    // an open menu, or the modal mount dialog would teleport icons or bury
    // the card. The dialog owns gpa-duped strings, but the icons behind it
    // must still sit still.
    if (self.ui.icon_dragging or self.ui.marquee_dragging) return;
    if (self.ui.desktop_menu_open or self.ui.icon_menu_open or self.ui.mount_dialog_open) return;
    // Icons repaint only if the scan changed them; widgets carry the clock /
    // now-playing progress and always get the tick's paint.
    self.rescan(.{ .icons = true, .widgets = true });
}

/// MPRIS bus actions drive the owned client (see `media_bus.Handler`).
fn handleMediaAction(ptr: *anyopaque, what: media_bus.Action, pos_us: i64) bool {
    const self: *Desktop = @ptrCast(@alignCast(ptr));
    if (!self.mpris_inited) return false;
    switch (what) {
        .play_pause => return self.mpris.act(.play_pause),
        .next => return self.mpris.act(.next),
        .previous => return self.mpris.act(.previous),
        .shuffle => {
            _ = self.mpris.poll();
            return self.mpris.setShuffle(!self.mpris.snap.shuffle);
        },
        .loop => return self.mpris.cycleLoop(),
        .seek => return self.mpris.seek(pos_us),
    }
}
