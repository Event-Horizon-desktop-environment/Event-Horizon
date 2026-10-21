const std = @import("std");
const app_mod = @import("app.zig");
const common = @import("common.zig");
const embed = @import("embed.zig");
const scroll_mod = @import("scroll.zig");
const ui_sidebar_mod = @import("ui_sidebar.zig");
const ui_content_mod = @import("ui_content.zig");
const search = @import("search.zig");
const config = @import("../../config.zig");
const ns = @import("../../desktop_shell/common/namespaces.zig");
const dock_persist = @import("dock_persist.zig");
const shell_persist = @import("shell_persist.zig");
const general_persist = @import("general_persist.zig");
const appearance_persist = @import("appearance_persist.zig");
const launcher_persist = @import("launcher_persist.zig");
const taskbar_persist = @import("taskbar_persist.zig");
const panel_persist = @import("panel_persist.zig");
const widget_persist = @import("widget_persist.zig");
const widget_lists = @import("widget_lists.zig");
const widget_add = @import("widget_add.zig");
const ui_paint = @import("ui_paint.zig");
const mon_state = @import("monitors_state.zig");
const mon_tab = @import("monitors_tab_helpers.zig");
const mon_page = @import("monitors_page.zig");
const wallpaper_tab = @import("wallpaper_tab.zig");
const wallpaper_persist = @import("wallpaper_persist.zig");
const bing_tab = @import("bing_tab.zig");
const icons_themes_tab = @import("icons_themes_tab.zig");
const bluetooth_tab = @import("bluetooth_tab.zig");
const desktop_widgets_persist = @import("desktop_widgets_persist.zig");
const desktop_widgets_tab = @import("desktop_widgets_tab.zig");
const notifications_persist = @import("notifications_persist.zig");
const display_picker = @import("display_picker.zig");
const dw_data = @import("desktop_widgets_data.zig");
const hyprland_data = @import("hyprland_data.zig");
const hyprland_tab = @import("hyprland_tab.zig");
const hyprland_anim_popup = @import("hyprland_anim_popup.zig");
const hyprland_bezier = @import("hyprland_bezier.zig");
const section_store = @import("../../config/section_store.zig");
const icon_themes = @import("../../desktop_shell/common/icon_themes.zig");
const refresh = @import("../../color/refresh.zig");
const logz = @import("../../logz.zig");
const wl_conn = @import("../../wl/connection.zig");
const wl_loop = @import("../../loop.zig");
const wl_pump = @import("../../wl/pump.zig");
const wl_seat = @import("../../wl/seat.zig");
const xdg = @import("../../wl/surface/xdg.zig");
const shm_mod = @import("../../wl/buffer/shm.zig");
const cairo = shm_mod.cairo;
const linux = std.os.linux;

// The settings window — Wayland plumbing for the ported UX. The surface is a
// real xdg-toplevel (wl/surface/xdg.zig), so the compositor places, moves,
// stacks and decorates it like any other window; paint/input/scroll all live
// in ui_sidebar.zig / ui_content.zig / scroll.zig.
//
// Frames are gated on wl_buffer.release: the single SHM buffer is only
// rewritten once the compositor has released it (otherwise we scribble on a
// buffer it is still scanning out — that was the flicker). `repaint()` marks
// `pending_redraw` instead when busy, and the release hook draws that frame.

const wheel_scale: f64 = 4.0; // libinput notch (~15px) -> 60px, like C++
const xkb = wl_seat.xkb;

/// The Dock tab's `tab_id` — `app_mod.panels_ui_subs[0]`.
const kDockTab: i32 = 0;
const kDesktopTab: i32 = 29;
const kDesktopWidgetsTab: i32 = 27;
const kLauncherTab: i32 = 9;
const kNotificationsTab: i32 = 5;

/// The two dialog commands `wallpaper_apply.cpp` prefers, verbatim.
const kdialog_cmd = "kdialog --getexistingdirectory . --title \"Wallpaper folder\"";
const qarma_cmd = "qarma --file-selection --directory --title=\"Wallpaper folder\"";

/// True when `path` exists and is executable by us (`access(X_OK)`).
fn isExecutable(path: []const u8) bool {
    const z = std.heap.page_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.page_allocator.free(z);
    return linux.access(z, linux.X_OK) == 0;
}

/// Wrap `s` in single quotes for `/bin/sh`, escaping the quotes it contains.
/// Single-quoted shell strings cannot contain a single quote at all, so each
/// one becomes the four characters `'\''` (close the quote, a literal
/// escaped quote, reopen). Returns null if `out` is too small.
fn shellQuote(out: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    if (n >= out.len) return null;
    out[n] = '\'';
    n += 1;
    for (s) |ch| {
        if (ch == '\'') {
            if (n + 4 > out.len) return null;
            @memcpy(out[n .. n + 4], "'\\''");
            n += 4;
        } else {
            if (n + 1 > out.len) return null;
            out[n] = ch;
            n += 1;
        }
    }
    if (n >= out.len) return null;
    out[n] = '\'';
    n += 1;
    return out[0..n];
}

fn envStr(key: [*:0]const u8) ?[]const u8 {
    const p = getenv(key) orelse return null;
    return std.mem.span(p);
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
/// Slowest rate a slider drag rewrites the dock file: a motion event can fire
/// every millisecond, and every write trips the dock's inotify watcher into a
/// full model rebuild (including icon lookup), so uncapped dragging would
/// rebuild the dock hundreds of times a second.
const kLiveFlushNs: u64 = 120_000_000;

/// Monotonic now in nanoseconds for the live-flush throttle. Same clock the
/// dock's animation tweens run on (`dock/anim.zig`), via `clock_gettime`.
fn liveNowNs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const s: u64 = @intCast(@max(ts.sec, 0));
    const n: u64 = @intCast(@max(ts.nsec, 0));
    return s * std.time.ns_per_s + n;
}

pub const Win = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    conn: wl_conn.Connection = undefined,
    bound: wl_conn.Connection.Bound = .{},
    loop: wl_loop.Loop = undefined,
    surface: xdg.Toplevel = .{},
    shm: shm_mod.ShmBuffer = undefined,
    settings: app_mod.Settings = .{},
    /// Live monitors state — the one tab whose values live outside
    /// `Settings` (one string per output, plus the compositor caps table).
    monitors: mon_state.State = .{},
    /// Strings `Settings` points at — `Settings` carries plain slices with
    /// no lifetime of their own, so anything read off disk is copied here
    /// and released in one go. Null until `start` has an allocator.
    str_arena: ?std.heap.ArenaAllocator = null,
    /// `~/.config/Event-Horizon`, where every component file lives. Owned.
    state_dir: ?[]u8 = null,
    sidebar: ui_sidebar_mod.Sidebar = .{},
    content: ui_content_mod.Content = undefined,
    scroll: scroll_mod.ScrollController = .{},
    timer_fd: i32 = -1,
    /// Last `flushDockLive` write, monotonic ns. Zero means "never", which
    /// always allows the first drag write through.
    last_live_flush_ns: u64 = 0,
    running: bool = false,
    wl_ready: bool = false,
    loop_ready: bool = false,
    buf_ready: bool = false,
    pending_redraw: bool = false,
    win_w: i32 = app_mod.window_width,
    win_h: i32 = app_mod.window_height,
    ptr_x: f64 = -1,
    ptr_y: f64 = -1,
    /// Open add-widget popup, when a board's "+ Add widget" was pressed.
    picker: ?widget_add.State = null,
    /// The Wallpaper tab's page. Owns its gallery scan, thumbnail cache and
    /// session-only view state; `Content.wall` borrows it while tab 6 is up.
    wall: wallpaper_tab.Page = .{},
    /// The thumbnail worker's eventfd, watched so decoded results repaint.
    wall_wake_fd: i32 = -1,
    /// The Bing Wallpaper tab's page. Owns its worker service and session
    /// state; `Content.bing` borrows it while tab 16 is up.
    bing: bing_tab.Page = .{},
    /// The Bing worker's eventfd, watched so a finished job repaints.
    bing_wake_fd: i32 = -1,
    /// The Icons tab's page. Owns the theme list, the preview cache and the
    /// Apply/Cancel backup; `Content.icons` borrows it while tab 44 is up.
    icons: icons_themes_tab.Page = .{},
    /// The Desktop Widgets tab's page. Owns its config/popup arenas plus
    /// the display-dropdown and world-clock session state; `Content.dwt`
    /// borrows it while tab 27 is up.
    dwt: desktop_widgets_tab.Page = .{},
    /// The Bluetooth tab's page. Owns the live BlueZ query, the verb mailbox
    /// poll and the memory file; `Content.bt` borrows it while tab 47 is up.
    bt: bluetooth_tab.Page = .{},
    /// Wallpaper-palette refresher (mem + disk caches live here) plus the
    /// fingerprint of the inputs it last ran on. `syncPalette` re-runs it
    /// only when the wallpaper, toggles, scheme or mode move.
    palette_ref: refresh.Refresher = undefined,
    palette_inited: bool = false,
    palette_fp_image: []const u8 = "",
    palette_fp_scheme: []const u8 = "",
    palette_fp_mode: []const u8 = "",
    palette_fp_flags: u8 = 0,

    /// In-place init (content holds a pointer to `self.settings`).
    pub fn start(self: *Win, init: std.process.Init) !bool {
        self.gpa = init.gpa;
        self.io = init.io;
        self.str_arena = std.heap.ArenaAllocator.init(self.gpa);
        self.state_dir = config.settingsDir(
            self.gpa,
            init.environ_map.get("XDG_CONFIG_HOME"),
            init.environ_map.get("HOME"),
        ) catch null;
        // The bundled Material Symbols font must reach fontconfig before
        // the first paint: m3 buttons resolve glyphs ("add", "restart_alt")
        // purely through the font, and the lazy registration inside
        // `ui_paint.glyph` only fires on a Lucide miss — which never
        // happens, so without this every button glyph leaks its name as
        // literal text.
        ui_paint.registerMaterialFont();
        self.seedFromConfig(init);
        self.content = .{ .settings = &self.settings };
        self.monitors = .{};
        self.monitors.gpa = self.gpa;
        self.monitors.io = self.io;
        self.monitors.env = init.environ_map;
        self.content.mon = &self.monitors;
        // Wallpaper page: needs the arena for its gallery paths and the
        // loop for the thumbnail worker's wake eventfd (both set below).
        self.wall.init(self.gpa, self.io);
        self.content.wall = &self.wall;
        // Bing page: same deal — arena for its dialog strings, loop for the
        // worker's wake eventfd (set below).
        self.bing.init(self.gpa, self.io);
        self.content.bing = &self.bing;
        // Icons page: same deal — the theme list and preview rasterization
        // need the allocator and io, nothing else from the window.
        self.icons.init(self.gpa, self.io);
        self.content.icons = &self.icons;
        // Bluetooth page: same deal — it queries BlueZ on init (throttled
        // thereafter) and needs the allocator + io for its memory file.
        self.bt.init(self.gpa, self.io);
        self.content.bt = &self.bt;
        // Desktop Widgets page: config + world-clock popup arenas.
        self.dwt.init(self.gpa, self.io);
        self.content.dwt = &self.dwt;
        // Palette refresher: warmed on first paint by `syncPalette`.
        self.palette_ref = refresh.Refresher.init(self.gpa, self.io);
        self.palette_inited = true;
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
        // Thumbnail worker wake: a decoded result lands on this eventfd.
        {
            const wfd = self.wall.svc.wakeFd();
            if (wfd >= 0) {
                self.loop.watchFd(wfd, std.posix.POLL.IN, onWallWake, @ptrCast(self)) catch {};
                self.wall_wake_fd = wfd;
            }
        }

        // Bing worker wake: a job published a result (progress pings after
        // every file, so this fires a lot during a download).
        {
            const bfd = self.bing.svc.wakeFd();
            if (bfd >= 0) {
                self.loop.watchFd(bfd, std.posix.POLL.IN, onBingWake, @ptrCast(self)) catch {};
                self.bing_wake_fd = bfd;
            }
        }

        if (self.bound.xdg_wm_base == null or self.bound.compositor == null) {
            logz.err("settings: no xdg_wm_base global", .{});
            return false;
        }
        if (!self.surface.create(
            self.bound.compositor,
            self.bound.xdg_wm_base,
            self.win_w,
            self.win_h,
            "Settings",
            ns.settings_app_id,
        )) return false;
        self.surface.on_configure = onConfigure;
        self.surface.on_closed = noteClosed;
        self.surface.ctx = self;
        self.surface.setMinSize(700, 600);

        var ticks: u32 = 0;
        while (ticks < 100 and !self.surface.configured) : (ticks += 1) {
            if (!self.conn.roundtrip()) break;
        }
        if (!self.surface.configured) {
            logz.err("settings: surface never configured", .{}); //nolint
            return false;
        }
        if (!self.shm.ensure(
            self.bound.shm,
            "settings",
            self.win_w,
            self.win_h,
        )) {
            logz.err("settings: shm buffer alloc failed", .{});
            return false;
        }
        self.shm.setReleaseHook(onBufRelease, self);
        self.buf_ready = true;

        self.content.win_h = self.win_h;
        self.content.content_w = self.win_w - self.content.content_x - common.spacing_l;
        self.content.relayout();
        self.scroll.snapTo(0);
        self.sidebar.win_h = self.win_h;

        // Debug/testing: open straight onto a tab (EH_SETTINGS_TAB=<id>).
        if (std.c.getenv("EH_SETTINGS_TAB")) |v| {
            if (std.fmt.parseInt(i32, std.mem.span(v), 10) catch null) |tab| self.setActiveTab(tab);
        }
        // Debug/testing: pick the child tab (EH_SETTINGS_SUB=<n>).
        if (std.c.getenv("EH_SETTINGS_SUB")) |v| {
            if (std.fmt.parseInt(i32, std.mem.span(v), 10) catch null) |sub| {
                self.content.sub_for[@intCast(self.content.active_tab)] = sub;
                self.content.relayout();
            }
        }

        if (self.bound.seat_obj) |seat| {
            seat.on_pointer_enter = onEnter;
            seat.on_pointer_leave = onLeave;
            seat.on_pointer_motion = onMotion;
            seat.on_pointer_button = onButton;
            seat.on_pointer_axis = onAxis;
            seat.on_key = onKey;
            seat.cb_ctx = self;
        } else {
            logz.err("settings: no wl_seat — the window will be inert", .{});
        }
        self.running = true;
        return true;
    }

    pub fn deinit(self: *Win) void {
        if (self.timer_fd >= 0) _ = linux.close(self.timer_fd);
        self.icons.deinit();
        self.bt.deinit();
        self.bing.deinit();
        self.wall.deinit();
        if (self.palette_inited) {
            self.palette_ref.deinit();
            self.palette_inited = false;
        }
        self.monitors.deinit();
        self.surface.destroy();
        self.shm.deinit();
        if (self.state_dir) |p| {
            self.gpa.free(p);
            self.state_dir = null;
        }
        if (self.str_arena) |*a| {
            a.deinit();
            self.str_arena = null;
        }
        if (self.wl_ready) self.conn.freeBound(&self.bound);
        if (self.loop_ready) self.loop.deinit();
        if (self.wl_ready) self.conn.deinit();
    }

    /// Read the layered config once at startup and seed the Dock tab from
    /// it. The tab has to open showing what is on disk: without this the
    /// first save writes the struct's defaults over live values — the Display
    /// combo in particular defaults to "Auto" while `dock.toml` says 'DP-1',
    /// which would silently move the dock the moment anything was touched.
    fn seedFromConfig(self: *Win, init: std.process.Init) void {
        var loaded = config.loadDefault(
            self.gpa,
            self.io,
            init.environ_map.get("XDG_CONFIG_HOME"),
            init.environ_map.get("HOME"),
        ) catch |e| {
            logz.err("settings: config load failed ({s}); the Dock tab starts at its defaults", .{@errorName(e)});
            return;
        };
        defer loaded.deinit();
        if (self.str_arena) |*a| {
            dock_persist.load(a.allocator(), &self.settings, &loaded.cfg.dock);
            taskbar_persist.load(a.allocator(), &self.settings, &loaded.cfg.taskbar);
            panel_persist.load(a.allocator(), &self.settings, &loaded.cfg.panel);
            widget_persist.load(a.allocator(), &self.settings, loaded.cfg.widgets);
            shell_persist.load(&self.settings, loaded.cfg.renderer);
            general_persist.load(a.allocator(), &self.settings, loaded.cfg.dock.icon_theme);
            appearance_persist.load(&self.settings, &loaded.cfg.appearance);
            launcher_persist.loadSlotPill(&self.settings, &loaded.cfg.dock, &loaded.cfg.taskbar);
            launcher_persist.loadWorkspaces(&self.settings, loaded.cfg.widgets);
            // Wallpaper lives in its own component file — the same one the
            // apply path watches, so the tab opens on what is on disk.
            if (self.state_dir) |st| {
                wallpaper_persist.loadInto(a.allocator(), self.io, st, &self.settings);
            }
            // Desktop-widget output + disabled slots live in
            // `desktop_widgets/desktop_widgets.toml`.
            if (self.state_dir) |st| {
                desktop_widgets_persist.loadFile(a.allocator(), self.io, st, &self.settings);
            }
            // Bluetooth's auto-reconnect toggle lives in `bluetooth.toml`
            // (loaded by the config schema); seed it so the tab opens on the
            // persisted value.
            self.settings.bt_auto_reconnect = loaded.cfg.bluetooth.auto_reconnect;
            // Notifications seed from the decoded `[notifications]` section,
            // so the tab opens on what the daemon is actually serving.
            notifications_persist.load(a.allocator(), &self.settings, &loaded.cfg.notifications);
        }
    }

    /// Write the Dock tab back to `dock/dock.toml` (plus the renderer row to
    /// `shell/shell.toml` — that combo lives on the Dock page but decodes
    /// from `[shell]`). Only called from the Dock tab, and only after a
    /// control actually moved, so a stray click in another category does not
    /// trip the dock's inotify watcher. The dock reloads by itself from
    /// there — `src/bin/app.zig` watches the component directory and rebuilds
    /// on the change.
    fn flushDockTab(self: *Win) void {
        if (self.content.active_tab != kDockTab) return;
        const state = self.state_dir orelse return;
        dock_persist.save(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: dock settings save failed: {s}", .{@errorName(e)});
        };
        shell_persist.save(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: shell renderer save failed: {s}", .{@errorName(e)});
        };
    }

    /// A slider drag's throttled write: the same files as `flushDockTab`
    /// minus the renderer (a combo cannot move mid-drag), at most once per
    /// `kLiveFlushNs`. This is what makes a drag repaint the live dock
    /// instead of only landing on release.
    fn flushDockLive(self: *Win) void {
        if (self.content.active_tab != kDockTab) return;
        const now = liveNowNs();
        if (self.last_live_flush_ns != 0 and now - self.last_live_flush_ns < kLiveFlushNs) return;
        self.last_live_flush_ns = now;
        const state = self.state_dir orelse return;
        dock_persist.save(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: dock live save failed: {s}", .{@errorName(e)});
        };
    }

    /// Write the Desktop tab's Overview card back to
    /// `appearance/appearance.toml`. Only called from the Desktop tab, and
    /// only after a control actually moved — without this the toggles are
    /// write-only memory and the overview never sees them.
    fn flushDesktopTab(self: *Win) void {
        if (self.content.active_tab != kDesktopTab) return;
        const state = self.state_dir orelse return;
        appearance_persist.save(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: overview settings save failed: {s}", .{@errorName(e)});
        };
    }

    /// Write the Desktop Widgets tab (id 27) back to
    /// `desktop_widgets/desktop_widgets.toml`. Only called from that tab
    /// after a control actually moved.
    fn flushDesktopWidgetsTab(self: *Win) void {
        if (self.content.active_tab != kDesktopWidgetsTab) return;
        const state = self.state_dir orelse return;
        desktop_widgets_persist.save(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: desktop widgets save failed: {s}", .{@errorName(e)});
        };
    }

    /// Write the Launcher tab (id 9) back: launchpad + overview keys to
    /// `appearance/appearance.toml`, the Widget-opacity slider to both bar
    /// files, and the Workspaces child to `[widget.workspaces]`. Only called
    /// from the Launcher tab after a control actually moved.
    fn flushLauncherTab(self: *Win) void {
        if (self.content.active_tab != kLauncherTab) return;
        const state = self.state_dir orelse return;
        launcher_persist.saveAll(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: launcher settings save failed: {s}", .{@errorName(e)});
        };
    }

    /// Throttled live write for Launcher slider drags (same throttle as the
    /// dock so a drag repaints the live shell instead of only landing on
    /// release).
    fn flushLauncherLive(self: *Win) void {
        if (self.content.active_tab != kLauncherTab) return;
        const now = liveNowNs();
        if (self.last_live_flush_ns != 0 and now - self.last_live_flush_ns < kLiveFlushNs) return;
        self.last_live_flush_ns = now;
        const state = self.state_dir orelse return;
        launcher_persist.saveAll(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: launcher live save failed: {s}", .{@errorName(e)});
        };
    }

    /// Write the Notifications tab (id 5) back to
    /// `notifications/notifications.toml` (`[notifications]` +
    /// `[notifications.toast]`, same keys the schema decodes). Only called
    /// from that tab after a control actually moved — the daemon reloads
    /// from its inotify watch, so every write repaints live toasts.
    fn flushNotificationsTab(self: *Win) void {
        if (self.content.active_tab != kNotificationsTab) return;
        const state = self.state_dir orelse return;
        if (!notifications_persist.save(self.gpa, self.io, state, &self.settings)) {
            logz.err("settings: notifications settings save failed", .{});
        }
    }

    /// Throttled live write for Notifications slider drags.
    fn flushNotificationsLive(self: *Win) void {
        if (self.content.active_tab != kNotificationsTab) return;
        const now = liveNowNs();
        if (self.last_live_flush_ns != 0 and now - self.last_live_flush_ns < kLiveFlushNs) return;
        self.last_live_flush_ns = now;
        const state = self.state_dir orelse return;
        if (!notifications_persist.save(self.gpa, self.io, state, &self.settings)) {
            logz.err("settings: notifications live save failed", .{});
        }
    }

    /// Write the Icons page back to `general/general.toml`. The dock reads
    /// its icon theme from `[general]` (`icons_themes_tab.tab_id`, not the
    /// Dock tab), so without this the theme combo is a no-op and the dock
    /// never re-resolves its art.
    fn flushIconsTab(self: *Win) void {
        if (self.content.active_tab != icons_themes_tab.tab_id) return;
        const state = self.state_dir orelse return;
        general_persist.save(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: icon theme save failed: {s}", .{@errorName(e)});
        };
    }

    /// Write the active bar page's widget sections plus every per-instance
    /// enable state. Only widget-board controls edit those, so this is the
    /// one flush they need — the bar's own TOML and `widgets/widgets.toml`.
    fn flushWidgetsTab(self: *Win) void {
        const state = self.state_dir orelse return;
        const bar = widget_lists.barForTab(self.content.active_tab) orelse return;
        const res = switch (bar) {
            .dock => dock_persist.save(self.gpa, self.io, state, &self.settings),
            .taskbar => taskbar_persist.save(self.gpa, self.io, state, &self.settings),
            .panel => panel_persist.save(self.gpa, self.io, state, &self.settings),
        };
        res catch |e| {
            logz.err("settings: widget sections save failed: {s}", .{@errorName(e)});
        };
        widget_persist.save(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: widget states save failed: {s}", .{@errorName(e)});
        };
    }

    /// Write the Wallpaper tab back to `wallpaper/wallpaper.toml`. The apply
    /// path watches that file with inotify and rebuilds, so the save *is* the
    /// apply — there is no separate call to make here.
    fn flushWallpaperTab(self: *Win) void {
        const state = self.state_dir orelse return;
        wallpaper_persist.save(self.gpa, self.io, state, &self.settings) catch |e| {
            logz.err("settings: wallpaper save failed: {s}", .{@errorName(e)});
        };
    }

    /// Borrow this frame's wallpaper settings into the page (its geometry
    /// and paint read `snap`, not `Settings`, to stay free of a cycle).
    /// Resolve the active palette into `common.Theme` and refresh the
    /// wallpaper-derived payloads when their inputs move. The refresh is
    /// synchronous and cache-backed (mem, then the shared palette-cache
    /// files), so steady-state frames only pay the resolve math; a cold
    /// first run decodes once.
    fn syncPalette(self: *Win) void {
        // Unreachable before `start()` arms the refresher, but a paint
        // without one would run generation on garbage state.
        if (!self.palette_inited) return;
        const st = &self.settings;
        const flags: u8 = (if (st.matugen_enabled) @as(u8, 1) else 0) |
            (if (st.horizon_native) @as(u8, 2) else 0) |
            (if (st.color_theme_enabled) @as(u8, 4) else 0);
        if (!std.mem.eql(u8, self.palette_fp_image, st.wallpaper_image) or
            !std.mem.eql(u8, self.palette_fp_scheme, st.matugen_scheme) or
            !std.mem.eql(u8, self.palette_fp_mode, st.matugen_mode) or
            self.palette_fp_flags != flags)
        {
            if (self.str_arena) |*a| {
                const aa = a.allocator();
                self.palette_fp_image = aa.dupe(u8, st.wallpaper_image) catch "";
                self.palette_fp_scheme = aa.dupe(u8, st.matugen_scheme) catch "";
                self.palette_fp_mode = aa.dupe(u8, st.matugen_mode) catch "";
                self.palette_fp_flags = flags;
            }
            const state_dir = refresh.stateDir(self.gpa) catch null;
            if (state_dir) |dir| {
                defer self.gpa.free(dir);
                var matugen_set = refresh.ChromeSet{};
                var hc_set = refresh.ChromeSet{};
                self.palette_ref.refresh(
                    .{
                        .matugen_theming = st.matugen_enabled,
                        .horizon_native = st.horizon_native,
                        .scheme = st.matugen_scheme,
                        .mode = st.matugen_mode,
                    },
                    st.wallpaper_image,
                    dir,
                    &matugen_set,
                    &hc_set,
                );
                st.matugen_palette_ok = matugen_set.ok;
                st.matugen_accent = matugen_set.accent;
                st.matugen_text = matugen_set.text;
                st.matugen_surface = matugen_set.dock_fill;
                st.matugen_outline = matugen_set.outline;
                st.horizon_colors_ok = hc_set.ok;
                st.hc_accent = hc_set.accent;
                st.hc_text = hc_set.text;
                st.hc_surface = hc_set.dock_fill;
                st.hc_outline = hc_set.outline;
            }
        }
        const res = common.resolveColors(.{
            .custom_enabled = st.color_theme_enabled,
            .theme_primary = st.theme_primary,
            .theme_on_surface = st.theme_on_surface,
            .theme_surface = st.theme_surface,
            .theme_outline = st.theme_outline,
            .matugen_enabled = st.matugen_enabled,
            .matugen_ok = st.matugen_palette_ok,
            .matugen_accent = st.matugen_accent,
            .matugen_text = st.matugen_text,
            .matugen_surface = st.matugen_surface,
            .matugen_outline = st.matugen_outline,
            .horizon_enabled = st.horizon_native,
            .horizon_ok = st.horizon_colors_ok,
            .horizon_accent = st.hc_accent,
            .horizon_surface = st.hc_surface,
            .horizon_outline = st.hc_outline,
        });
        common.Theme.acc_r = @as(f64, res.colors.accent_r);
        common.Theme.acc_g = @as(f64, res.colors.accent_g);
        common.Theme.acc_b = @as(f64, res.colors.accent_b);
        common.Theme.text_r = @as(f64, res.colors.text_r);
        common.Theme.text_g = @as(f64, res.colors.text_g);
        common.Theme.text_b = @as(f64, res.colors.text_b);
        common.Theme.bg_r = @as(f64, res.colors.surface_r);
        common.Theme.bg_g = @as(f64, res.colors.surface_g);
        common.Theme.bg_b = @as(f64, res.colors.surface_b);
        common.Theme.outline_r = @as(f64, res.colors.outline_r);
        common.Theme.outline_g = @as(f64, res.colors.outline_g);
        common.Theme.outline_b = @as(f64, res.colors.outline_b);
    }

    fn syncWallpaper(self: *Win) void {
        self.wall.sync(.{
            .image = self.settings.wallpaper_image,
            .folder = self.settings.wallpaper_folder,
            .mode = self.settings.wallpaper_mode,
            .enabled = self.settings.wallpaper_enabled,
        });
    }

    /// Borrow this frame's Bing settings into the page and pull in anything
    /// the worker published. The C++ drains results inside `paint_bing_tab`,
    /// which means a daily fetch that lands on another tab never applies;
    /// doing it here (every frame, before relayout) closes that hole.
    ///
    /// Returns the local path of a just-fetched daily wallpaper when the
    /// caller should point the desktop at it.
    fn syncBing(self: *Win) ?[]const u8 {
        self.bing.sync(.{
            .enabled = self.settings.bing_enabled,
            .daily_enabled = self.settings.bing_daily_enabled,
            .download_path = self.settings.bing_download_path,
            .blocked_keywords = self.settings.bing_blocked_keywords,
        });
        const daily = self.bing.drain() orelse return null;
        // The C++ applies the file only when the toggle is on at the moment
        // the result lands, so a user who turned Daily off mid-fetch does not
        // get their wallpaper changed.
        if (!self.settings.bing_daily_enabled) return null;
        const alloc = if (self.str_arena) |*a| a.allocator() else return null;
        const owned = alloc.dupe(u8, daily) catch return null;
        self.settings.wallpaper_image = owned;
        self.settings.wallpaper_enabled = true;
        self.flushWallpaperTab();
        return null;
    }

    /// thumbnail worker eventfd: the results are ready, pull them in and
    /// repaint so the grid fills in without waiting for the next pointer move.
    fn onWallWake(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        self.wall.drainThumbs();
        self.repaint();
    }

    /// Bing worker eventfd: a job published a result. The results themselves
    /// are pulled in by `syncBing` on the repaint that follows.
    fn onBingWake(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        self.repaint();
    }

    /// `wallpaper_detect_folder_picker_cmd`: honour an explicit mode, else
    /// pick whichever of kdialog/qarma is actually installed (KDE first when
    /// the desktop says so). Empty means "no dialog tool here".
    fn detectFolderPickerCmd() []const u8 {
        var dlow_buf: [256]u8 = undefined;
        const desktop = envStr("XDG_CURRENT_DESKTOP") orelse "";
        const dlow = std.ascii.lowerString(
            dlow_buf[0..@min(desktop.len, dlow_buf.len)],
            desktop[0..@min(desktop.len, dlow_buf.len)],
        );
        const kde = std.mem.indexOf(u8, dlow, "kde") != null or
            std.mem.indexOf(u8, dlow, "plasma") != null;
        const have_kdialog = isExecutable("/usr/bin/kdialog") or isExecutable("/bin/kdialog");
        if (kde and have_kdialog) return kdialog_cmd;
        if (have_kdialog) return kdialog_cmd;
        if (isExecutable("/usr/bin/qarma") or isExecutable("/bin/qarma")) return qarma_cmd;
        return "";
    }

    /// Run the folder dialog (`pick_folder`) and take its stdout as the new
    /// folder. Blocking, like the C++ call — the dialog is modal anyway.
    fn pickWallpaperFolder(self: *Win) void {
        const cmd = switch (self.settings.wallpaper_folder_picker_mode) {
            1 => kdialog_cmd,
            2 => qarma_cmd,
            3 => "zenity --file-selection --directory --title=\"Wallpaper folder\"",
            else => detectFolderPickerCmd(),
        };
        if (cmd.len == 0) return;
        const alloc = if (self.str_arena) |*a| a.allocator() else return;
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
        }) catch |e| {
            logz.err("settings: folder picker failed: {s}", .{@errorName(e)});
            return;
        };
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return;
        const path = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (path.len == 0) return;
        // `Settings` points into the long-lived arena, not this call's buffer.
        const owned = alloc.dupe(u8, path) catch return;
        self.settings.wallpaper_folder = owned;
        self.flushWallpaperTab();
    }

    /// One wallpaper-tab press. The page has already moved its own session
    /// state; this is only what needs `Settings` and a save.
    fn onWallpaperAction(self: *Win, act: wallpaper_tab.Action) void {
        switch (act) {
            .repaint => {},
            .toggle_enabled => {
                self.settings.wallpaper_enabled = !self.settings.wallpaper_enabled;
                self.flushWallpaperTab();
            },
            .cycle => |delta| self.cycleWallpaperImage(delta),
            .set_mode => |mode| {
                self.settings.wallpaper_mode = std.math.clamp(mode, 0, 4);
                self.flushWallpaperTab();
            },
            .pick_folder => self.pickWallpaperFolder(),
            .select_image => |idx| {
                if (idx >= self.wall.gallery.entries.items.len) return;
                self.setWallpaperImage(self.wall.gallery.entries.items[idx].path);
            },
            .clear_image => {
                self.settings.wallpaper_image = "";
                self.settings.wallpaper_enabled = false;
                self.flushWallpaperTab();
            },
        }
        self.repaint();
    }

    /// One Bing-tab press. The page has already moved its own session state
    /// (busy flags, status text, dropdowns, the worker launches); this is
    /// only what needs `Settings` and a save, plus the two blocking dialogs.
    fn onBingAction(self: *Win, act: bing_tab.Action) void {
        switch (act) {
            .repaint => {},
            .toggle_enabled => {
                self.settings.bing_enabled = !self.settings.bing_enabled;
                self.flushWallpaperTab();
            },
            .toggle_daily => {
                self.settings.bing_daily_enabled = !self.settings.bing_daily_enabled;
                self.flushWallpaperTab();
            },
            .pick_folder => self.pickBingFolder(),
            .edit_keywords => self.editBingKeywords(),
        }
        self.repaint();
    }

    /// One Bluetooth-tab press. The page has already run the BlueZ writes
    /// (power/scan/verbs) and flipped its own auto-reconnect snap; this is
    /// only what needs `Settings` + persistence, mirroring `onBingAction`.
    fn onBluetoothAction(self: *Win, act: bluetooth_tab.Action) void {
        switch (act) {
            // Backend work already happened in the page; repaint is all.
            .repaint, .toggle_power, .toggle_scan, .forget, .verb => {},
            .toggle_reconnect => {
                // The page flipped its borrowed snap; read it back into
                // `Settings` and persist to `bluetooth.toml`.
                self.settings.bt_auto_reconnect = self.bt.auto_reconnect;
                self.saveBluetoothReconnect();
            },
        }
        self.repaint();
    }

    /// Write the Bluetooth tab's auto-reconnect flag back to
    /// `bluetooth/bluetooth.toml`. Only fires on a real toggle, so a stray
    /// click elsewhere cannot trip a component watcher.
    fn saveBluetoothReconnect(self: *Win) void {
        const state = self.state_dir orelse return;
        const path = config.componentPath(self.gpa, state, "bluetooth") catch return;
        defer self.gpa.free(path);
        section_store.save(self.gpa, self.io, path, "bluetooth", &.{
            .{ .key = "auto_reconnect", .value = section_store.boolValue(self.settings.bt_auto_reconnect) },
        }) catch |e| {
            logz.err("settings: bluetooth save failed: {s}", .{@errorName(e)});
        };
    }

    /// One Icons-tab press. The page has already moved its own session state
    /// (theme list refresh, backup init); this is only what needs `Settings`,
    /// a save, and the push out to GNOME/Qt/KDE.
    fn onIconsAction(self: *Win, act: icons_themes_tab.Action) void {
        switch (act) {
            // C++ `on_icon_theme_pick` — index into the page's theme list,
            // which was refreshed by the hit-test that produced this action.
            .pick_theme => |i| {
                if (i >= self.icons.themes.len) return;
                // `str_arena` is the window's long-lived arena; a dupe lives
                // until the window closes, so the slice stays valid for the
                // whole session (and matches how the other tabs set strings).
                if (self.str_arena) |*arena| {
                    const id = arena.allocator().dupe(u8, self.icons.themes[i].id) catch return;
                    self.settings.icon_theme = id;
                }
                // No save here (C++ parity): picking only re-themes the live
                // shell, Apply is what persists. The Zig settings app draws
                // no theme icons of its own, so there is nothing to
                // re-resolve in-process either — the dock reloads the config
                // when Apply writes it.
            },
            .apply => {
                const cur = self.settings.icon_theme;
                if (self.icons.hasChanges(cur)) {
                    // Same order as C++ Apply: persist to general.toml (the
                    // dock's config watcher picks the new theme up from
                    // there), then set gsettings + the toolkit ini files,
                    // then commit the backup.
                    self.flushIconsTab();
                    self.flushDesktopTab();
                    icon_themes.applyIconTheme(self.io, cur);
                    self.icons.backupCommit(cur);
                }
            },
            .cancel => {
                // Restore-only: the backup snapshot re-enters `Settings`
                // through the arena, exactly like a pick. With no changes
                // there is nothing to put back (and Apply was gated anyway).
                if (self.icons.hasChanges(self.settings.icon_theme)) {
                    if (self.str_arena) |*arena| {
                        const restored = arena.allocator().dupe(u8, self.icons.backup_theme) catch return;
                        self.settings.icon_theme = restored;
                    }
                }
            },
        }
        self.repaint();
    }

    /// Bing's Browse. Upstream sets `App::bingFolderPickerOpen` here and
    /// nothing reads it, so in the C++ the button is inert — this runs a real
    /// dialog instead. Unlike the Wallpaper tab's (which the user picks a
    /// backend for) this just takes whichever dialog tool exists, because
    /// Bing's path box has no way to show one.
    fn pickBingFolder(self: *Win) void {
        // Same three tools the Wallpaper tab detects, but with a title that
        // says what is actually being picked, and zenity as the floor so the
        // button has a command to run on a bare system too.
        const cmd: []const u8 = blk: {
            if (isExecutable("/usr/bin/kdialog") or isExecutable("/bin/kdialog")) {
                break :blk "kdialog --getexistingdirectory . --title \"Bing wallpaper folder\"";
            }
            if (isExecutable("/usr/bin/qarma") or isExecutable("/bin/qarma")) {
                break :blk "qarma --file-selection --directory --title=\"Bing wallpaper folder\"";
            }
            break :blk "zenity --file-selection --directory --title=\"Bing wallpaper folder\"";
        };
        self.runBingDialog(cmd, "bing download path");
    }

    /// Bing's Edit... : the keyword entry. Faithful to the C++, which shells
    /// out to `zenity --entry` through popen — with kdialog and qarma tried
    /// after zenity so the button is not a dead end without it.
    fn editBingKeywords(self: *Win) void {
        const alloc = if (self.str_arena) |*a| a.allocator() else return;
        // The current list is passed as the entry's prefilled value. A single
        // quote in it would otherwise close the shell's quoting — and a
        // `$(...)` sitting in a settings file would be run — so the whole
        // value goes into single quotes first.
        var esc: [16400]u8 = undefined;
        const quoted = shellQuote(&esc, self.settings.bing_blocked_keywords) orelse return;
        var cmd_buf: [17000]u8 = undefined;
        const cmd: []const u8 = blk: {
            if (isExecutable("/usr/bin/zenity") or isExecutable("/bin/zenity")) {
                break :blk std.fmt.bufPrint(
                    &cmd_buf,
                    "zenity --entry --title 'Blocked Keywords' " ++
                        "--text 'Enter keywords to block, comma-separated:' " ++
                        "--entry-text {s} 2>/dev/null",
                    .{quoted},
                ) catch return;
            }
            if (isExecutable("/usr/bin/kdialog") or isExecutable("/bin/kdialog")) {
                break :blk std.fmt.bufPrint(
                    &cmd_buf,
                    "kdialog --title 'Blocked Keywords' " ++
                        "--inputbox 'Enter keywords to block, comma-separated:' {s}",
                    .{quoted},
                ) catch return;
            }
            if (isExecutable("/usr/bin/qarma") or isExecutable("/bin/qarma")) {
                break :blk std.fmt.bufPrint(
                    &cmd_buf,
                    "qarma --title 'Blocked Keywords' " ++
                        "--inputbox 'Enter keywords to block, comma-separated:' {s}",
                    .{quoted},
                ) catch return;
            }
            return; // no entry tool on this machine
        };
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
        }) catch |e| {
            logz.err("settings: bing keyword dialog failed: {s}", .{@errorName(e)});
            return;
        };
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return;
        const answer = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (answer.len == 0) return;
        self.settings.bing_blocked_keywords = alloc.dupe(u8, answer) catch return;
        self.flushWallpaperTab();
    }

    /// Run a blocking shell dialog and hand back its stdout (trimmed) when it
    /// exits 0. Shared by the two Bing dialogs.
    fn runBingDialog(self: *Win, cmd: []const u8, what: []const u8) void {
        const alloc = if (self.str_arena) |*a| a.allocator() else return;
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
        }) catch |e| {
            logz.err("settings: {s} failed: {s}", .{ what, @errorName(e) });
            return;
        };
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return;
        const out = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (out.len == 0) return;
        self.settings.bing_download_path = alloc.dupe(u8, out) catch return;
        self.flushWallpaperTab();
    }

    /// Prev/next chevron: walk the selection through the scanned gallery.
    fn cycleWallpaperImage(self: *Win, delta: i32) void {
        const items = self.wall.gallery.entries.items;
        if (items.len == 0) return;
        const cur = self.wall.indexOfImage(self.settings.wallpaper_image);
        var idx: i32 = if (cur) |i| @intCast(i) else 0;
        idx += delta;
        if (idx < 0) idx = @intCast(items.len - 1);
        if (idx >= @as(i32, @intCast(items.len))) idx = 0;
        self.setWallpaperImage(items[@intCast(idx)].path);
    }

    /// Point the wallpaper at a gallery entry (arena-duped: the scan's
    /// entries are freed on the next rescan).
    fn setWallpaperImage(self: *Win, path: []const u8) void {
        const alloc = if (self.str_arena) |*a| a.allocator() else return;
        const owned = alloc.dupe(u8, path) catch return;
        self.settings.wallpaper_image = owned;
        self.settings.wallpaper_enabled = true;
        self.flushWallpaperTab();
    }

    /// Open the add-widget popup for one board column.
    fn openPicker(self: *Win, col: usize) void {
        const bar = widget_lists.barForTab(self.content.active_tab) orelse return;
        self.picker = .{ .bar = bar, .col = col };
    }

    fn paintPicker(self: *Win, cr: ?*cairo.cairo_t) void {
        if (self.picker == null) return;
        widget_add.paint(
            cr,
            &self.picker.?,
            &self.settings,
            self.ptr_x,
            self.ptr_y,
            self.win_w,
            self.win_h,
        );
    }

    /// Modal click: outside the card dismisses, a grid card appends the id
    /// to the column the popup was opened for.
    fn pickerClick(self: *Win, x: f64, y: f64) void {
        const st = &self.picker.?;
        const lay = widget_add.layoutFor(st, &self.settings, self.win_w, self.win_h);
        if (!common.pointInRect(x, y, lay.panelRect())) {
            self.picker = null;
            return;
        }
        // Outlined close button.
        if (common.pointInRect(x, y, lay.closeRect())) {
            self.picker = null;
            return;
        }
        // Search clear chip (only live when there is a filter to clear).
        if (st.filter_len > 0 and common.pointInRect(x, y, lay.clearRect())) {
            st.filter_len = 0;
            st.scroll_px = 0;
            return;
        }
        const idx = widget_add.hit(lay, st, &self.settings, x, y) orelse return;
        var out: [widget_add.max_candidates][]const u8 = undefined;
        const n = widget_add.collectInto(st, &self.settings, &out);
        if (idx >= n) return;
        // Desktop Add flow: append a fresh widget config (C++
        // `widgetPickerForDesktop` pick: `<id><N>` at (100, 100+N*150)).
        if (st.for_desktop) {
            const w = out[idx];
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const prev = dw_data.load(self.gpa, self.io, arena.allocator());
            var list: std.ArrayListUnmanaged(dw_data.WidgetConfig) = .empty;
            for (prev) |c| list.append(arena.allocator(), c) catch break;
            var idbuf: [64]u8 = undefined;
            const id = std.fmt.bufPrint(&idbuf, "{s}{d}", .{ w, list.items.len + 1 }) catch w;
            list.append(arena.allocator(), .{
                .wtype = dw_data.widgetTypeFromId(w),
                .id = id,
                .widget_id = w,
                .pos_x = 100,
                .pos_y = 100 + @as(i32, @intCast(list.items.len)) * 150,
            }) catch return;
            _ = dw_data.save(self.gpa, self.io, list.items);
            self.picker = null;
            self.content.relayout();
            self.repaint();
            return;
        }
        const alloc = if (self.str_arena) |*a| a.allocator() else return;
        if (!widget_lists.appendUnique(&self.settings, alloc, st.bar, st.col, out[idx])) return;
        self.flushWidgetsTab();
        self.content.relayout();
    }

    /// Enter in the popup: place the first match (the filter's top hit).
    fn pickerAddFirst(self: *Win) void {
        var out: [widget_add.max_candidates][]const u8 = undefined;
        const n = widget_add.collectInto(&self.picker.?, &self.settings, &out);
        if (n == 0) return;
        if (self.picker.?.for_desktop) {
            // Same as picking the top hit by pointer (see `pickerClick`).
            const w = out[0];
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const prev = dw_data.load(self.gpa, self.io, arena.allocator());
            var list: std.ArrayListUnmanaged(dw_data.WidgetConfig) = .empty;
            for (prev) |c| list.append(arena.allocator(), c) catch return;
            var idbuf: [64]u8 = undefined;
            const id = std.fmt.bufPrint(&idbuf, "{s}{d}", .{ w, list.items.len + 1 }) catch w;
            list.append(arena.allocator(), .{
                .wtype = dw_data.widgetTypeFromId(w),
                .id = id,
                .widget_id = w,
                .pos_x = 100,
                .pos_y = 100 + @as(i32, @intCast(list.items.len)) * 150,
            }) catch return;
            _ = dw_data.save(self.gpa, self.io, list.items);
            self.picker = null;
            self.content.relayout();
            self.repaint();
            return;
        }
        const alloc = if (self.str_arena) |*a| a.allocator() else return;
        const st = self.picker.?;
        if (!widget_lists.appendUnique(&self.settings, alloc, st.bar, st.col, out[0])) return;
        self.flushWidgetsTab();
        self.content.relayout();
    }

    /// Hyprland anim-popup speed field keys: Return commits a (0, 30]
    /// value, Escape cancels, Backspace edits, `-` leads, digits and one dot
    /// append — byte for byte the C++ speed-entry handler.
    fn hyprSpeedKey(self: *Win, ev: *const wl_seat.KeyEvent) void {
        const ei = hyprland_tab.anim_edit_idx;
        const name = if (ei >= 0 and ei < hyprland_data.k_anim_entries.len)
            hyprland_data.k_anim_entries[@intCast(ei)].name
        else
            return;
        switch (ev.sym) {
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                const buf = hyprland_tab.animSpeedSlice();
                if (std.fmt.parseFloat(f64, buf)) |val| {
                    if (val > 0.0 and val <= 30.0) {
                        hyprland_data.setAnimSpeed(name, val);
                        hyprland_data.commit(self.gpa, self.io);
                        self.content.relayout();
                    }
                } else |_| {}
                hyprland_tab.anim_speed_active = false;
            },
            xkb.XKB_KEY_Escape => {
                hyprland_tab.anim_speed_active = false;
            },
            xkb.XKB_KEY_BackSpace => {
                if (hyprland_tab.anim_speed_len > 0) hyprland_tab.anim_speed_len -= 1;
            },
            xkb.XKB_KEY_minus => {
                if (hyprland_tab.anim_speed_len == 0) hyprland_tab.setAnimSpeedBuf("-");
            },
            else => {
                if (ev.utf8_len > 0) {
                    const c = ev.utf8[0];
                    if ((c >= '0' and c <= '9') or c == '.') {
                        if (c == '.' and std.mem.indexOfScalar(u8, hyprland_tab.animSpeedSlice(), '.') != null) return;
                        var tmp: [33]u8 = undefined;
                        const cur = hyprland_tab.animSpeedSlice();
                        if (cur.len + 1 > tmp.len) return;
                        @memcpy(tmp[0..cur.len], cur);
                        tmp[cur.len] = c;
                        hyprland_tab.setAnimSpeedBuf(tmp[0 .. cur.len + 1]);
                    }
                }
            },
        }
    }

    /// Typing while the popup is up: characters filter, Backspace edits,
    /// Return places the top hit, Escape dismisses.
    fn pickerKey(self: *Win, ev: *const wl_seat.KeyEvent) void {
        const st = &self.picker.?;
        switch (ev.sym) {
            xkb.XKB_KEY_Escape => self.picker = null,
            xkb.XKB_KEY_BackSpace => {
                if (st.filter_len == 0) return;
                var end = st.filter_len - 1;
                while (end > 0 and (st.filter[end] & 0xC0) == 0x80) end -= 1;
                st.filter_len = end;
                st.scroll_px = 0;
            },
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => self.pickerAddFirst(),
            else => {
                if (ev.utf8_len == 0) return;
                const bytes = ev.utf8[0..ev.utf8_len];
                if (bytes[0] < 0x20) return;
                const room = st.filter.len - st.filter_len;
                const n = @min(room, bytes.len);
                @memcpy(st.filter[st.filter_len .. st.filter_len + n], bytes[0..n]);
                st.filter_len += n;
                st.scroll_px = 0;
            },
        }
    }

    fn setActiveTab(self: *Win, tab: i32) void {
        const t = embed.clampTab(tab);
        // Leaving (or re-entering) the Icons tab drops its preview cache and
        // Apply/Cancel backup — the C++ runs both on every tab activation
        // while tab 44 was the current one, sub-tab clicks included.
        if (self.content.active_tab == icons_themes_tab.tab_id) {
            self.icons.resetSession();
        }
        self.picker = null;
        self.sidebar.active_tab = t;
        self.content.active_tab = t;
        self.content.open_combo = null;
        self.scroll.snapTo(0);
        // First entry to the Monitors tab pulls the live output list (C++
        // `app.monitorsTabDidInitialRefresh`). Later entries keep whatever the
        // user has edited, so an unsaved scale or position survives a walk to
        // another tab and back.
        if (t == app_mod.TabId.monitors and !self.monitors.did_refresh) {
            self.monitors.refresh();
            self.content.relayout();
        }
        // Entering the Hyprland tab (re)reads the compositor files, unless
        // an edit is pending — the Zig side of C++ `draw()`'s per-frame
        // reload guarded by `hyprland_m3_has_active_slider`.
        if (t == kDesktopWidgetsTab) self.syncDesktopOutputs();
        if (t == hyprland_tab.tab_id and self.content.drag == null) {
            hyprland_data.ensureLoaded(self.io);
            self.content.relayout();
        }
        // Entering the Bluetooth tab starts its slow repaint tick (500 ms —
        // drives the throttled BlueZ refresh + busy spinner); leaving lets
        // the one-shot timer lapse, so the loop stops on its own.
        self.armTick();
    }

    /// Toolbar action `ix` on the Monitors tab.
    fn monitorsTool(self: *Win, ix: usize) void {
        switch (ix) {
            mon_page.tool_refresh => self.monitors.refresh(),
            mon_page.tool_portals => self.monitors.restartPortals(),
            mon_page.tool_apply => _ = self.monitors.saveAndReload(),
            mon_page.tool_revert => self.monitors.revertEdits(),
            else => return,
        }
        self.content.relayout();
        self.repaint();
    }

    /// Aux button `ix` under the arrange canvas.
    fn monitorsCanvasBtn(self: *Win, ix: usize) void {
        const box = self.content.canvas_box;
        switch (ix) {
            0 => mon_tab.centerCanvasView(&self.monitors, box.w, box.h),
            1 => mon_tab.alignAllTops(&self.monitors),
            else => return,
        }
        self.repaint();
    }

    /// Compositor-suggested resize: rebuild the buffer and relayout.
    fn applySize(self: *Win, w: i32, h: i32) void {
        if (w <= 0 or h <= 0) return;
        if (w == self.win_w and h == self.win_h) return;
        self.win_w = w;
        self.win_h = h;
        self.content.win_w = w;
        self.content.win_h = h;
        self.content.content_w = w - self.content.content_x - common.spacing_l;
        self.sidebar.win_h = h;
        self.sidebar.clampScroll();
        if (self.buf_ready) {
            if (self.shm.ensure(self.bound.shm, "settings", w, h)) {
                self.shm.setReleaseHook(onBufRelease, self);
                self.pending_redraw = false;
                self.repaint();
            } else {
                self.buf_ready = false;
            }
        }
    }

    /// Full frame: bg, sidebar, divider, content, popup, close affordance.
    pub fn repaint(self: *Win) void {
        if (!self.buf_ready) return;
        const cr = self.shm.cr orelse return;
        if (self.shm.busy) {
            // Compositor still owns the buffer — draw on release instead.
            self.pending_redraw = true;
            return;
        }

        // Content bounds feed the scroll controller before the frame draws.
        // Both custom pages read `snap`, so hand them this frame's values
        // first; `syncBing` first because a landed daily fetch writes the
        // wallpaper image the wallpaper page then borrows.
        _ = self.syncBing();
        self.syncPalette();
        self.syncWallpaper();
        // Borrow this frame's auto-reconnect flag into the Bluetooth page so
        // its toggle tracks `Settings` (the window owns persistence).
        self.bt.sync(self.settings.bt_auto_reconnect);
        // The gallery's tile hover pop only advances while the page paints, so
        // drop it the moment the tab changes rather than leaving `running` true
        // and the tick timer armed with nothing to animate.
        if (self.content.active_tab != wallpaper_tab.tab_id) self.wall.hover_pop.cancel();
        self.content.relayout();
        self.scroll.setMax(self.content.scrollMax());
        self.scroll.tick();
        self.content.scroll_px = self.scroll.currentPx();
        self.sidebar.clampScroll();

        cairo.cairo_identity_matrix(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
        cairo.cairo_set_source_rgba(
            cr,
            common.Theme.bg_r * 0.35,
            common.Theme.bg_g * 0.35,
            common.Theme.bg_b * 0.35,
            0.78,
        );
        cairo.cairo_paint(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);

        self.sidebar.pointer_x = self.ptr_x;
        self.sidebar.pointer_y = self.ptr_y;
        self.sidebar.paint(cr);

        // Hairline between sidebar and content (settings_app.cpp divider).
        const div_x: f64 = @floatFromInt(common.spacing_l + common.sidebar_w + common.spacing_s);
        cairo.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
        cairo.cairo_set_line_width(cr, 1.0);
        cairo.cairo_move_to(cr, div_x + 0.5, common.content_top);
        cairo.cairo_line_to(cr, div_x + 0.5, self.win_h - common.spacing_l);
        cairo.cairo_stroke(cr);

        self.content.setPointer(self.ptr_x, self.ptr_y);
        self.content.paint(cr);
        self.content.paintPopup(cr);
        // Hyprland editors paint above the page (bezier over anim popup).
        if (self.content.active_tab == hyprland_tab.tab_id) {
            if (hyprland_tab.bezier_open) {
                hyprland_bezier.paint(self.content.content_w, self.ptr_x, self.ptr_y, cr);
            } else if (hyprland_tab.anim_edit_idx >= 0) {
                hyprland_anim_popup.paint(self.content.content_x, self.content.content_w, self.ptr_x, self.ptr_y, cr);
            }
        }
        self.paintPicker(cr);
        // Wallpaper folder-picker modal: window space, above the page (the
        // page's own paint is clipped and scrolled).
        if (self.wall.picker_modal_open) {
            wallpaper_tab.paintPickerModal(
                cr,
                self.win_w,
                self.win_h,
                self.settings.wallpaper_folder_picker_mode,
                self.ptr_x,
                self.ptr_y,
            );
        }

        drawClose(cr, self.win_w);

        self.surface.attach(self.shm.wlBuffer(), 0, 0);
        self.surface.damage(0, 0, self.win_w, self.win_h);
        self.shm.markBusy();
        self.surface.commit();
        _ = self.conn.flush();
        // Repaint keeps every running tween ticking. Scroll decay and the
        // wallpaper gallery's tile hover pop both depend on this, since neither
        // is re-armed from the input handlers that start them.
        self.armTick();
    }

    /// Arms the 16 ms timer that drives every wall-clock animation the window
    /// runs: the scroll controller's easing and the wallpaper gallery's tile
    /// hover pop. Idempotent, and a no-op when nothing is animating, so an idle
    /// window never spins a timer.
    fn armTick(self: *Win) void {
        const animating = self.scroll.animating or self.wall.hover_pop.running();
        // The Bluetooth tab polls BlueZ and animates a busy spinner; keep a
        // slow tick alive while it is the active tab so refresh + paint run.
        const bt_live = self.content.active_tab == bluetooth_tab.tab_id;
        if (!animating and !bt_live) return;
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
        // 16 ms while animating (smooth motion); 500 ms to drive the
        // Bluetooth tab's throttled refresh + spinner when idle.
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = if (animating) 16_000_000 else 500_000_000 },
        };
        _ = linux.timerfd_settime(self.timer_fd, .{}, &its, null);
    }

    /// wl_buffer.release: safe to write again, and honour any deferred frame.
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
        self.repaint();
        self.armTick();
    }

    fn onConfigure(ctx: *anyopaque, w: i32, h: i32) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        self.applySize(w, h);
        self.repaint();
    }

    fn noteClosed(ctx: *anyopaque) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        self.running = false;
        wl_loop.Loop.requestStop();
    }

    fn onEnter(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        self.ptr_x = x;
        self.ptr_y = y;
        self.repaint();
    }

    fn onLeave(ctx: *anyopaque) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        self.ptr_x = -1;
        self.ptr_y = -1;
        self.repaint();
    }

    fn onMotion(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        self.ptr_x = x;
        self.ptr_y = y;
        self.content.setPointer(x, y);
        // World-clock dropdown hover (tab 27 only).
        if (self.content.active_tab == kDesktopWidgetsTab and self.dwt.wc.open) {
            if (self.dwt.wcMotion(self.win_w, self.win_h, x, y)) {
                self.repaint();
                return;
            }
        }
        // Hyprland bezier handle drag + anim dropdown hover (tab 33 only).
        if (self.content.active_tab == hyprland_tab.tab_id) {
            if (hyprland_bezier.motion(self.content.content_w, x, y)) {
                self.repaint();
                return;
            }
            if (hyprland_anim_popup.motion(self.content.content_x, self.content.content_w, x, y)) {
                self.repaint();
                return;
            }
        }
        if (self.content.drag) |d| {
            if (self.content.applyHit(.{ .slider = d }, x)) {
                self.flushDockLive();
                self.flushLauncherLive();
                self.flushNotificationsLive();
            }
        }
        // Widget-board drag: track the drop slot and the lifted card.
        if (self.content.widgetDragMotion()) {
            self.repaint();
            return;
        }
        // Wallpaper opacity preview drag (session-only, so no save here).
        if (self.wall.dragging_opacity) {
            self.wall.dragOpacity(self.content.wallGeo(), x);
            self.repaint();
            return;
        }
        // Arrange-canvas gesture: live-drag the output or follow the pan.
        if (self.content.monMotion()) {
            self.repaint();
            return;
        }
        self.repaint();
    }

    fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        const BTN_LEFT: u32 = 0x110;
        if (button != BTN_LEFT) return;
        if (state == 0) {
            // World-clock modal release resolves the armed item.
            if (self.content.active_tab == kDesktopWidgetsTab and self.dwt.wc.open) {
                if (self.dwt.wcUp(self.win_w, self.win_h, self.ptr_x, self.ptr_y)) {
                    self.repaint();
                    return;
                }
            }
            // Opacity preview drag: the value is session-only, so the release
            // just disarms the gesture.
            if (self.wall.dragging_opacity) self.wall.dragging_opacity = false;
            if (self.content.drag != null) {
                self.content.drag = null;
                // Final write of the drag: motion already flushed at most
                // every `kLiveFlushNs`, so this only lands the last step.
                self.flushDockTab();
                self.flushIconsTab();
                self.flushDesktopTab();
                self.flushLauncherTab();
                self.flushNotificationsTab();
                self.repaint();
            }
            // Hyprland tab: slider drags batch until release and toggle
            // clicks land on press — the release writes every pending edit
            // back and reloads the compositor (`hyprland_commit_cfg`).
            if (self.content.active_tab == hyprland_tab.tab_id) {
                if (hyprland_tab.bezier_drag >= 0) hyprland_tab.bezier_drag = -1;
                if (hyprland_data.isDirty()) {
                    hyprland_data.commit(self.gpa, self.io);
                    self.content.relayout();
                    self.repaint();
                }
            }
            // Widget-board release: commit the drop (reorder / cross-zone
            // move) and persist, or silently disarm a bare grip click.
            if (self.content.takeWidgetDragCommit()) |mc| {
                const bar = widget_lists.barForTab(self.content.active_tab) orelse return;
                const alloc = if (self.str_arena) |*a| a.allocator() else return;
                if (widget_lists.moveItem(&self.settings, alloc, bar, mc.src_col, mc.src_idx, mc.dst_col, mc.insert_before)) {
                    self.flushWidgetsTab();
                    self.content.relayout();
                }
                self.repaint();
            }
            // Arrange-canvas release: commit the drop (resolve collisions,
            // snap edges, normalise the origin) and unfreeze the fit.
            if (self.content.monRelease()) self.repaint();
            return;
        }
        self.content.setPointer(self.ptr_x, self.ptr_y);
        const x = self.ptr_x;
        const y = self.ptr_y;
        // 0a. Hyprland bezier editor: modal over tab 33 while open.
        if (self.content.active_tab == hyprland_tab.tab_id and hyprland_tab.bezier_open) {
            var do_commit = false;
            if (hyprland_bezier.hitDown(self.content.content_w, x, y, &do_commit)) {
                if (do_commit) {
                    hyprland_data.commit(self.gpa, self.io);
                    self.content.relayout();
                }
                self.repaint();
                return;
            }
        }
        // 0b. Hyprland animation editor: modal over tab 33 while an entry is
        // under edit (the bezier editor sits above it when both are open).
        if (self.content.active_tab == hyprland_tab.tab_id and !hyprland_tab.bezier_open and hyprland_tab.anim_edit_idx >= 0) {
            var do_commit = false;
            if (hyprland_anim_popup.hitDown(self.content.content_x, self.content.content_w, x, y, &do_commit)) {
                if (do_commit) {
                    hyprland_data.commit(self.gpa, self.io);
                    self.content.relayout();
                }
                self.repaint();
                return;
            }
        }
        // 0. add-widget popup: a modal, so it eats every click.
        if (self.picker != null) {
            self.pickerClick(x, y);
            self.repaint();
            return;
        }
        // 0b. wallpaper folder-picker modal: same deal. Picking a row only
        // stores the mode — the dialog command is used on the next Open.
        if (self.wall.picker_modal_open) {
            const row = wallpaper_tab.hitPickerModal(self.win_w, self.win_h, x, y);
            self.wall.picker_modal_open = false;
            if (row) |r| {
                if (r >= 0 and r < 4) {
                    self.settings.wallpaper_folder_picker_mode = r;
                    self.flushWallpaperTab();
                }
            }
            self.repaint();
            return;
        }
        // 1. window close affordance (top-right pill).
        if (inCloseRect(x, y, self.win_w)) {
            self.running = false;
            wl_loop.Loop.requestStop();
            return;
        }
        // 1b. World-clock modal: arms an item on tab 27 while open.
        if (self.content.active_tab == kDesktopWidgetsTab and self.dwt.wc.open) {
            if (self.dwt.wcDown(self.win_w, self.win_h, x, y)) {
                self.repaint();
                return;
            }
        }
        // 2. popup rows first — they float above everything.
        const h = self.content.hitTest(x, y);
        if (h == .combo_pick) {
            _ = self.content.selectComboIndex(h.combo_pick);
            self.flushDockTab();
            self.flushIconsTab();
            self.flushDesktopTab();
            self.flushLauncherTab();
            self.flushNotificationsTab();
            self.repaint();
            return;
        }
        // 3. sidebar: search bar, categories, subs, results.
        switch (self.sidebar.hitTest(x, y)) {
            .focus_search => {
                self.sidebar.search_focused = true;
                self.repaint();
                return;
            },
            .clear_search => {
                self.sidebar.setQuery("");
                self.sidebar.search_focused = true;
                self.repaint();
                return;
            },
            .pick_result => |ri| {
                const e = search.entries[@intCast(self.sidebar.results[ri])];
                self.sidebar.setQuery("");
                self.sidebar.search_focused = false;
                self.setActiveTab(e.tab);
                self.repaint();
                return;
            },
            .select_tab => |tab| {
                self.sidebar.search_focused = false;
                if (self.sidebar.searching()) self.sidebar.setQuery("");
                self.setActiveTab(tab);
                self.repaint();
                return;
            },
            .toggle_category => |ci| {
                self.sidebar.expanded[ci] = !self.sidebar.expanded[ci];
                self.sidebar.search_focused = false;
                self.repaint();
                return;
            },
            .none => {},
        }
        // 4. content rows. Single evaluation: `h` above already ran the
        // hit test once for the combo check, and page hit tests carry
        // side effects (the Bluetooth page runs its BlueZ writes inline,
        // like the C++ `consume_pointer_down`). Testing twice per press
        // double-fires every action — a Scan click starts *and* stops the
        // scan, so nothing is ever found.
        self.sidebar.search_focused = false;
        const ch = h;
        switch (ch) {
            .none => {
                if (self.content.open_combo != null) {
                    self.content.open_combo = null;
                }
            },
            // Opening a combo changes nothing — only its pick does, and that
            // is handled above.
            .combo => _ = self.content.applyHit(ch, x),
            .slider => |d| {
                self.content.drag = d;
                _ = self.content.applyHit(ch, x);
                self.flushDockTab();
                self.flushIconsTab();
                self.flushDesktopTab();
                self.flushLauncherTab();
                self.flushNotificationsTab();
            },
            // Widget board edits: mutate the live settings lists / enable
            // states, relayout (column lengths changed) and persist.
            .widget_toggle => |wr| {
                const bar = widget_lists.barForTab(self.content.active_tab) orelse return;
                const id = widget_lists.idAt(&self.settings, bar, wr.col, wr.idx) orelse return;
                if (self.str_arena) |*a| {
                    _ = widget_persist.toggle(&self.settings, a.allocator(), id);
                }
                self.flushWidgetsTab();
                self.content.relayout();
            },
            .widget_remove => |wr| {
                const bar = widget_lists.barForTab(self.content.active_tab) orelse return;
                const alloc = if (self.str_arena) |*a| a.allocator() else return;
                if (!widget_lists.removeAt(&self.settings, alloc, bar, wr.col, wr.idx)) return;
                self.flushWidgetsTab();
                self.content.relayout();
            },
            .widget_drag => |wr| {
                // Grip press: arm a reorder / cross-column move. Motion
                // tracks the drop slot, release commits it — see `onMotion`
                // and the release path in `onButton`.
                self.content.widgetDragArm(wr);
            },
            .widgets_reset => {
                const bar = widget_lists.barForTab(self.content.active_tab) orelse return;
                const alloc = if (self.str_arena) |*a| a.allocator() else return;
                if (!widget_lists.resetBar(&self.settings, alloc, bar)) return;
                self.flushWidgetsTab();
                self.content.relayout();
            },
            .widget_add => |col| {
                self.openPicker(col);
            },
            // Monitors: toolbar actions and the aux buttons are window-level
            // (they call into the state and repaint).
            .tool => |i| {
                self.monitorsTool(i);
                return;
            },
            .canvas_btn => |i| {
                self.monitorsCanvasBtn(i);
                return;
            },
            .canvas_mon => |i| {
                // Press on an output: select it and arm an arrangement drag.
                self.content.monSelect(i);
                self.repaint();
            },
            .canvas_pan => {
                self.content.monPanArm();
                self.repaint();
            },
            .wallpaper => |act| {
                self.onWallpaperAction(act);
                return;
            },
            .bing => |act| {
                self.onBingAction(act);
                return;
            },
            .bluetooth => |act| {
                self.onBluetoothAction(act);
                return;
            },
            .icons => |act| {
                self.onIconsAction(act);
                return;
            },
            .desktop_widgets => |act| {
                self.onDesktopWidgetsAction(act);
                return;
            },
            // The notifications test button fires a live `Notify` at the
            // daemon; every other button falls through to the generic
            // apply + persist path below.
            .button => |label| {
                if (std.mem.eql(u8, label, "Test notification")) {
                    if (!notifications_persist.sendTestNotification(self.gpa)) {
                        logz.log("settings: test notification failed (daemon down?)", .{});
                    }
                    self.repaint();
                    return;
                }
                _ = self.content.applyHit(ch, x);
                self.flushDockTab();
                self.flushIconsTab();
                self.flushDesktopTab();
                self.flushLauncherTab();
                self.flushNotificationsTab();
            },
            else => {
                _ = self.content.applyHit(ch, x);
                self.flushDockTab();
                self.flushIconsTab();
                self.flushDesktopTab();
                self.flushLauncherTab();
                self.flushNotificationsTab();
            },
        }
        self.repaint();
    }

    fn onAxis(ctx: *anyopaque, delta: f64) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        const step = delta * wheel_scale;
        if (self.picker) |*st| {
            const lay = widget_add.layoutFor(st, &self.settings, self.win_w, self.win_h);
            if (common.pointInRect(self.ptr_x, self.ptr_y, lay.panelRect())) {
                // Over the grid: scroll the content in pixels (the C++ scrolls
                // widgetPickerScrollPx only while the pointer is on the grid).
                if (common.pointInRect(self.ptr_x, self.ptr_y, lay.gridRect())) {
                    widget_add.scrollByPx(st, lay, @as(i32, @intFromFloat(@round(step))));
                }
                // Over the rest of the panel: absorb the wheel.
                self.repaint();
                return;
            }
        }
        // World-clock timezone list scrolls under the wheel.
        if (self.content.active_tab == kDesktopWidgetsTab and self.dwt.wc.open) {
            if (self.dwt.wcScroll(self.win_w, self.win_h, self.ptr_x, self.ptr_y, step)) {
                self.repaint();
                return;
            }
        }
        // Hyprland child-tab strip scrolls horizontally under the wheel
        // (C++ `hyprland_handle_tab_bar_scroll`, 6px hit pad included).
        if (self.content.active_tab == hyprland_tab.tab_id and
            hyprland_tab.pointInBarHit(self.ptr_x, self.ptr_y, self.content.content_x, self.content.content_w))
        {
            if (hyprland_tab.tabBarOverflowPx(self.content.content_w) > 0) {
                const tab_step: i32 = @intFromFloat(@round(step));
                if (tab_step != 0) {
                    hyprland_tab.tab_scroll_px = hyprland_tab.clampTabScroll(hyprland_tab.tab_scroll_px + tab_step, self.content.content_w);
                    self.repaint();
                    return;
                }
            }
        }
        if (self.ptr_x >= 0 and self.ptr_x < common.spacing_l + common.sidebar_w) {
            self.sidebar.scroll_px += @intFromFloat(@round(step));
            self.sidebar.clampScroll();
        } else {
            // Wheel over the arrange canvas zooms about the pointer instead
            // of scrolling the page (C++ `monitors_wheel_zoom_canvas`).
            self.content.setPointer(self.ptr_x, self.ptr_y);
            if (self.content.monWheel(step)) {
                self.repaint();
                return;
            }
            self.scroll.scrollBy(-step);
            self.armTick();
        }
        self.repaint();
    }

    /// Desktop Widgets tab press routing. Remove/toggle/display mutate
    /// the layout file or `Settings` and flush; Add opens the picker in
    /// desktop mode; the cog is handled inside the page (it opens the
    /// world-clock popup there).
    fn onDesktopWidgetsAction(self: *Win, act: desktop_widgets_tab.Action) void {
        switch (act) {
            .remove => |i| {
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                var list: std.ArrayListUnmanaged(dw_data.WidgetConfig) = .empty;
                for (dw_data.load(self.gpa, self.io, arena.allocator())) |c| {
                    list.append(arena.allocator(), c) catch break;
                }
                if (i < list.items.len) {
                    _ = list.orderedRemove(i);
                    _ = dw_data.save(self.gpa, self.io, list.items);
                }
                self.content.relayout();
            },
            .toggle => |i| {
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                const configs = dw_data.load(self.gpa, self.io, arena.allocator());
                if (i >= configs.len) return;
                const wid = dw_data.slotId(configs[i]);
                const alloc = if (self.str_arena) |*a| a.allocator() else return;
                const on = desktop_widgets_persist.slotEnabled(&self.settings, wid);
                desktop_widgets_persist.setSlotEnabled(alloc, &self.settings, wid, !on) catch return;
                self.flushDesktopWidgetsTab();
                self.content.relayout();
            },
            .add => {
                self.picker = .{ .for_desktop = true };
            },
            .display_trigger => {
                if (!self.dwt.display_open) self.syncDesktopOutputs();
                self.dwt.display_open = !self.dwt.display_open;
                self.dwt.display_hover = -1;
            },
            .display_pick => |row| {
                const outs = self.content.dwtOutputs();
                var dpick = display_picker.DisplayPicker{};
                const name = dpick.nameForRow(outs, row) orelse "";
                const alloc = if (self.str_arena) |*a| a.allocator() else return;
                self.settings.desktop_widgets_output_name = alloc.dupe(u8, name) catch name;
                self.dwt.display_open = false;
                self.dwt.display_hover = -1;
                self.flushDesktopWidgetsTab();
                self.content.relayout();
            },
        }
        self.repaint();
    }

    /// Fill the Desktop Widgets display names from the window's bound
    /// Wayland outputs (C++ `sync_dropdown` reads the same live list, and
    /// refreshes it on open — hence the roundtrip here).
    fn syncDesktopOutputs(self: *Win) void {
        _ = self.conn.roundtrip();
        var n: usize = 0;
        for (self.bound.outputs.items) |o| {
            if (n >= self.content.dwt_outputs.len) break;
            if (o.name.len == 0) continue;
            self.content.dwt_outputs[n] = o.name;
            n += 1;
        }
        self.content.dwt_outputs_len = n;
    }

    fn onKey(ctx: *anyopaque, ev: *const wl_seat.KeyEvent) void {
        const self: *Win = @ptrCast(@alignCast(ctx));
        if (ev.state != 1) return; // pressed only
        if (self.picker != null) {
            self.pickerKey(ev);
            self.repaint();
            return;
        }
        // World-clock timezone search (modal while open on tab 27).
        // `onKey` only sees presses (`ev.state == 1` guard above), so no
        // repeat flag ever arrives — same as every other key consumer here.
        if (self.content.active_tab == kDesktopWidgetsTab and self.dwt.wc.open) {
            if (self.dwt.wcKey(ev.sym, false, ev.utf8[0..ev.utf8_len])) {
                self.repaint();
                return;
            }
        }
        // Hyprland animation speed text entry (C++ `hyprlandAnimSpeedEdit*`).
        if (hyprland_tab.anim_speed_active and self.content.active_tab == hyprland_tab.tab_id and
            hyprland_tab.anim_edit_idx >= 0)
        {
            self.hyprSpeedKey(ev);
            self.repaint();
            return;
        }
        switch (ev.sym) {
            xkb.XKB_KEY_Escape => {
                if (self.content.open_combo != null) {
                    self.content.open_combo = null;
                } else if (self.sidebar.search_focused and self.sidebar.searching()) {
                    self.sidebar.setQuery("");
                } else if (self.sidebar.search_focused) {
                    self.sidebar.search_focused = false;
                } else {
                    self.running = false;
                    wl_loop.Loop.requestStop();
                    return;
                }
            },
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                if (self.sidebar.searching() and self.sidebar.results_len > 0) {
                    const e = search.entries[@intCast(self.sidebar.results[self.sidebar.search_sel])];
                    self.sidebar.setQuery("");
                    self.sidebar.search_focused = false;
                    self.setActiveTab(e.tab);
                }
            },
            xkb.XKB_KEY_Up => {
                if (self.sidebar.search_sel > 0) self.sidebar.search_sel -= 1;
            },
            xkb.XKB_KEY_Down => {
                if (self.sidebar.searching() and self.sidebar.search_sel + 1 < self.sidebar.results_len) {
                    self.sidebar.search_sel += 1;
                }
            },
            xkb.XKB_KEY_BackSpace => {
                if (!self.sidebar.search_focused) return;
                const q = self.sidebar.querySlice();
                if (q.len > 0) {
                    var end = q.len - 1;
                    while (end > 0 and (q[end] & 0xC0) == 0x80) end -= 1;
                    self.sidebar.query_len = end;
                    self.sidebar.recompute();
                }
            },
            else => {
                if (!self.sidebar.search_focused) return;
                if (ev.utf8_len == 0) return;
                const bytes = ev.utf8[0..ev.utf8_len];
                if (bytes[0] < 0x20) return;
                const room = self.sidebar.query.len - self.sidebar.query_len;
                const n = @min(room, bytes.len);
                @memcpy(self.sidebar.query[self.sidebar.query_len .. self.sidebar.query_len + n], bytes[0..n]);
                self.sidebar.query_len += n;
                self.sidebar.recompute();
                self.sidebar.search_sel = 0;
            },
        }
        self.repaint();
    }
};

fn inCloseRect(x: f64, y: f64, win_w: i32) bool {
    return common.pointInRect(x, y, closeRect(win_w));
}

fn closeRect(win_w: i32) common.Rect {
    return .{
        .x = win_w - 44,
        .y = common.content_top,
        .w = 28,
        .h = 28,
    };
}

/// Close pill at the content's top-right corner.
fn drawClose(cr: ?*cairo.cairo_t, win_w: i32) void {
    const c = cr orelse return;
    const r = closeRect(win_w);
    const t = common.Theme;
    const cx = @as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) * 0.5;
    const cy = @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) * 0.5;
    const paint = @import("ui_paint.zig");
    paint.glassBox(
        c,
        @floatFromInt(r.x),
        @floatFromInt(r.y),
        @floatFromInt(r.w),
        @floatFromInt(r.h),
        @as(f64, @floatFromInt(r.w)) * 0.5,
        t.acc_r,
        t.acc_g,
        t.acc_b,
        0.35,
    );
    paint.glyph(c, cx, cy + 0.5, 15, "close", t.text_r, t.text_g, t.text_b, 0.95);
}

pub fn run(init: std.process.Init) !u8 {
    // Isolated testing dirs (`Event-Horizon-zig`); must precede `Win.start`'s
    // config seed and every settings save.
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    logz.init(init.io, init.environ_map.get("HOME"), "horizon-settings");
    defer logz.deinit();
    var win = Win{};
    defer win.deinit();
    if (!(try win.start(init))) {
        logz.err("settings: window start failed", .{});
        return 1;
    }
    win.repaint();
    _ = win.conn.roundtrip();
    logz.log(
        "settings window up: {d}x{d} tab={d}",
        .{ win.win_w, win.win_h, win.sidebar.active_tab },
    );
    win.loop.run();
    return 0;
}
