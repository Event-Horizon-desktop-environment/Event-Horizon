//! `horizon-notifications` — the split-out notification child.
//!
//! Owns a `NotificationManager`, the `org.freedesktop.Notifications` D-Bus
//! service, and the toast layer surface on one Wayland connection; serves
//! `notify.push` (internal / mpris / mpris-art) over eh-ipc; repaints and
//! expires on a timerfd. Deliberately `eh`-free (like `overview_bin`) so
//! neighbours' breakage cannot block it.
//!
//! Single-threaded event loop: Wayland display fd, D-Bus fd, IPC fd,
//! timerfd and the config watcher all ride `loop.zig`. Name ownership is
//! checked first — when another daemon already owns
//! the bus name this process keeps serving IPC + toasts and defers D-Bus.

const std = @import("std");
const config = @import("../config.zig");
const loop_mod = @import("../loop.zig");
const logz = @import("../logz.zig");
const parent_guard = @import("../parent_guard.zig");
const palette_sync = @import("../color/palette_sync.zig");
const wl = @import("../wl/c.zig").wl;
const conn_mod = @import("../wl/connection.zig");
const pump = @import("../wl/pump.zig");
const layer_mod = @import("../wl/surface/layer.zig");
const shm_mod = @import("../wl/buffer/shm.zig");
const watch_mod = @import("../config/watch.zig");
const dbus_conn = @import("../dbus/connection.zig");
const dbus_object = @import("../dbus/object.zig");
const ipc_client = @import("../ipc_client.zig");
const notify_manager = @import("../services/notify_manager.zig");
const notify_service = @import("../services/notify_service.zig");
const notify_push = @import("../services/notify_push.zig");
const notify_stats = @import("../services/notify_stats.zig");
const toast_cards = @import("../desktop_shell/notifications/toast_cards.zig");
const chrome_colors = @import("../desktop_shell/widgets/shared/chrome_colors.zig");
const ns = @import("../desktop_shell/common/namespaces.zig");
const overlay = @import("../config/overlay.zig");
const linux = std.os.linux;

const Manager = notify_manager.Manager;
const kPushTopic = "notify.push";
const kConfigTopic = "config.applied";
const kFieldSep: u8 = 0x1e;
const kb_none: u32 = 0; // zwlr keyboard_interactivity.none (exclusive=2)
const kAnimTickMs: i64 = 16;
const kIdlePollMs: i64 = 30_000;

fn monoMs() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const s: i64 = @intCast(@max(ts.sec, 0));
    const n: i64 = @intCast(@max(ts.nsec, 0));
    return s * 1000 + @divTrunc(n, 1_000_000);
}

const MprisEntry = struct {
    id: u32 = 0,
    summary: []const u8 = "",
    body: []const u8 = "",
    text_rx_ms: i64 = 0,
    art_rx_ms: i64 = 0,
    art_logged: bool = false,
};

const PendingPaint = struct {
    id: u32,
    rx_ms: i64,
};

pub const Daemon = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    xdg_config: ?[]const u8 = null,
    home: ?[]const u8 = null,
    eh_ipc_socket: ?[]const u8 = null,
    xdg_runtime: ?[]const u8 = null,

    conn: conn_mod.Connection,
    bound: conn_mod.Connection.Bound = .{},
    loop: loop_mod.Loop,
    loaded: config.Loaded,
    palette: palette_sync.Sync,
    watcher: watch_mod.Watcher = .{},

    mgr: Manager,
    dbus: dbus_conn.Conn,
    dbus_live: bool = false,
    tree: dbus_object.Tree = undefined,
    svc: ?*notify_service.Service = null,

    ipc: ipc_client.Client,
    ipc_live: bool = false,
    ipc_retry_ms: i64 = 0,

    timer_fd: i32 = -1,

    layer: layer_mod.Surface = .{},
    shm: shm_mod.ShmPair,
    surface_live: bool = false,
    surface_w: i32 = 0,
    surface_h: i32 = 0,
    want_paint: bool = false,
    toast_output: ?*wl.wl_output = null,

    measure_surf: ?*shm_mod.cairo.cairo_surface_t = null,
    measure_cr: ?*shm_mod.cairo.cairo_t = null,

    cards: [toast_cards.kMaxCards]toast_cards.Card = undefined,
    ncards: usize = 0,
    hover_close: u32 = 0,

    frame_cb: ?*wl.wl_callback = null,
    last_frame_ms: i64 = 0,
    /// Last actual paint. Caps the frame-callback chain at ~60 fps: the
    /// compositor can hand back frame-done well under the refresh interval,
    /// and done→paint→request unthrottled burns a core. When a callback
    /// lands inside the cap, the 16 ms animation timer paints instead.
    last_paint_ms: i64 = 0,

    mpris: std.StringHashMap(MprisEntry),

    /// Pipeline bench + per-id trigger stamps (Notify rx → first paint).
    stats: notify_stats.Stats,
    pending: std.ArrayList(PendingPaint) = .empty,
    bench_report_ms: i64 = 0,
    bench_serial: u64 = 0,
    bench_fail_seen: u64 = 0,

    pub fn deinit(self: *Daemon) void {
        // Daemon-created state only, plus the config (ownership moved in
        // from main: reloads swap it, so only the daemon may free it).
        // Wayland conn/loop/bound/palette stay with main's locals.
        self.loaded.deinit();
        self.stats.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        var kit = self.mpris.iterator();
        while (kit.next()) |kv| {
            self.gpa.free(@constCast(kv.key_ptr.*));
            if (kv.value_ptr.summary.len > 0) self.gpa.free(kv.value_ptr.summary);
            if (kv.value_ptr.body.len > 0) self.gpa.free(kv.value_ptr.body);
        }
        self.mpris.deinit();
        self.dbus.deinit();
        if (self.dbus_live) {
            if (self.svc) |svc| svc.deinit();
            self.tree.deinit();
        }
        self.mgr.deinit();
        self.ipc.deinit();
        self.shm.deinit();
        if (self.measure_cr) |cr| shm_mod.cairo.cairo_destroy(cr);
        if (self.measure_surf) |s| shm_mod.cairo.cairo_surface_destroy(s);
        if (self.timer_fd >= 0) _ = linux.close(self.timer_fd);
        self.watcher.close();
    }

    // -- config -----------------------------------------------------------

    fn applyConfig(self: *Daemon) void {
        const ncfg = self.loaded.cfg.notifications;
        self.mgr.setServerDefaultTimeoutMs(ncfg.default_timeout_ms);
        self.mgr.setQuietMode(ncfg.do_not_disturb);
        if (self.svc) |svc| svc.setRules(ncfg.rules);
        self.syncToast();
    }

    fn reloadCfg(self: *Daemon) void {
        const fresh = config.loadStacked(self.gpa, self.io, self.xdg_config, self.home) catch {
            logz.log("config: reload failed, keeping live config", .{});
            return;
        };
        self.loaded.deinit();
        self.loaded = fresh;
        self.palette.run(&self.loaded.cfg);
        logz.log("config: reloaded", .{});
        self.applyConfig();
        self.refresh();
    }

    // -- timers ------------------------------------------------------------

    fn armTimer(self: *Daemon) void {
        if (self.timer_fd < 0) return;
        var wait_ms = self.mgr.nextExpiryDelayMs();
        if (wait_ms < 0) wait_ms = kIdlePollMs;
        // A running countdown also drives the progress-bar animation.
        if (self.mgr.nextExpiryDelayMs() >= 0 and wait_ms > kAnimTickMs) wait_ms = kAnimTickMs;
        const clamped: i64 = @max(wait_ms, 1);
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{
                .sec = @intCast(@divTrunc(clamped, 1000)),
                .nsec = @intCast(@mod(clamped, 1000) * 1_000_000),
            },
        };
        _ = linux.timerfd_settime(self.timer_fd, .{}, &its, null);
    }

    fn onTimer(self: *Daemon) void {
        if (self.svc) |svc| svc.sweepExpired() else self.mgr.sweepExpired();
        self.armTimer();
        // Expiry closes fire manager events, which rebuild via refresh() —
        // so the tick itself only repaints the progress bars (no title
        // re-measure every 50 ms). A dead surface with live cards still needs
        // the full path to recreate it.
        if (self.frame_cb != null and monoMs() - self.last_frame_ms < 250) return;
        if (self.ncards > 0 and !self.surface_live) {
            self.refresh();
            return;
        }
        self.paint();
        // Bench report: counters + fresh failures, at most every 60 s and
        // only when something changed (at most every 60 s).
        {
            const now = monoMs();
            if (now - self.bench_report_ms > 60_000 and self.stats.serial() != self.bench_serial) {
                self.bench_report_ms = now;
                self.bench_serial = self.stats.serial();
                const sum = self.stats.receiverSummary(self.gpa);
                defer if (sum.len > 0) self.gpa.free(sum);
                if (sum.len > 0) logz.log("notify bench: {s}", .{sum});
                const fresh = self.stats.failuresSince(self.gpa, &self.bench_fail_seen);
                defer if (fresh.len > 0) self.gpa.free(fresh);
                if (fresh.len > 0) logz.log("notify bench failures:\n{s}", .{fresh});
            }
        }
        // Lazy IPC reconnect, throttled to every 30 s of timer wakes.
        if (!self.ipc_live) {
            const now = monoMs();
            if (now - self.ipc_retry_ms > 30_000) {
                self.ipc_retry_ms = now;
                self.ipcConnect();
            }
        }
    }

    // -- toast surface ------------------------------------------------------

    fn pickOutput(self: *Daemon) ?*wl.wl_output {
        const want = self.loaded.cfg.notifications.output_name;
        const trimmed = std.mem.trim(u8, want, " \t\n");
        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "auto") and !std.mem.eql(u8, trimmed, "all")) {
            for (self.bound.outputs.items) |o| {
                if (std.mem.eql(u8, o.name, trimmed)) return o.obj;
            }
        }
        if (self.bound.outputs.items.len > 0) return self.bound.outputs.items[0].obj;
        return null;
    }

    fn toastMetrics(self: *Daemon) toast_cards.Metrics {
        const t = self.loaded.cfg.notifications.toast;
        return .{
            .us = @as(f64, @floatFromInt(@max(50, @min(200, t.scale_pct)))) / 100.0,
            .card_radius = @as(f64, @floatFromInt(t.corner_radius_px)),
        };
    }

    /// Tear down when disabled or outputless. Creation is lazy (in
    /// `refresh`, after layout, with a valid size) — committing an unsized
    /// surface kills the client (anchor without left+right needs width).
    fn syncToast(self: *Daemon) void {
        const ncfg = self.loaded.cfg.notifications;
        if (!ncfg.toast.layer_shell_enabled) {
            self.teardownToast();
            return;
        }
        if (self.bound.compositor == null or self.bound.shm == null or self.bound.layer_shell == null) {
            logz.log("toast: waiting for compositor/shm/layer_shell", .{});
            self.teardownToast();
            return;
        }
        if (self.surface_live and self.pickOutput() != self.toast_output) {
            // Output changed under us: drop the surface; refresh rebuilds it.
            self.teardownToast();
        }
    }

    fn teardownToast(self: *Daemon) void {
        if (!self.surface_live) return;
        if (self.frame_cb) |cb| {
            wl.wl_callback_destroy(cb);
            self.frame_cb = null;
        }
        self.layer.destroy();
        self.shm.deinit();
        self.shm = shm_mod.ShmPair.init(self.gpa);
        self.surface_live = false;
        self.surface_w = 0;
        self.surface_h = 0;
        self.ncards = 0;
        self.toast_output = null;
    }

    fn onLayerConfigure(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.surface_w = @intCast(w);
        self.surface_h = @intCast(h);
        self.paint();
    }

    fn onLayerClosed(ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        logz.log("toast: compositor closed the surface; recreating on next refresh", .{});
        self.surface_live = false;
        self.surface_w = 0;
        self.surface_h = 0;
    }

    /// Rebuild cards from the manager and repaint. Empty selection hides the surface, and
    /// the surface is only ever created after layout hands it a real size.
    fn refresh(self: *Daemon) void {
        if (self.measure_cr == null) return; // scratch surface failed; no layout
        var ids = @as([toast_cards.kMaxCards]u32, @splat(0));
        const sel = toast_cards.selectCards(&self.mgr, &ids);
        self.ncards = sel.len;
        if (sel.len == 0) {
            self.hover_close = 0;
            if (self.surface_live) {
                if (self.layer.wl_surface) |s| {
                    wl.wl_surface_attach(s, null, 0, 0);
                    wl.wl_surface_commit(s);
                    self.flush();
                }
            }
            return;
        }
        const m = self.toastMetrics();
        const t = self.loaded.cfg.notifications.toast;
        const max_w: f64 = @floatFromInt(t.max_width_px);
        const lscope = notify_stats.scope(monoMs());
        const lay = toast_cards.layoutCards(
            self.measure_cr.?,
            sel,
            &self.mgr,
            m,
            t.position,
            max_w,
            &self.cards,
        );
        self.stats.noteLayout(lscope.ms(monoMs()));
        self.ncards = lay.cards.len;
        if (!self.surface_live) {
            const out = self.pickOutput() orelse {
                logz.log("toast: no outputs bound yet", .{});
                return;
            };
            if (!self.layer.create(self.bound.compositor, self.bound.layer_shell, out, .top, ns.notification_toast)) {
                logz.log("toast: layer surface create failed", .{});
                return;
            }
            self.layer.setAnchor(toast_cards.anchorFor(t.position));
            self.layer.setExclusiveZone(0);
            self.layer.setKeyboardInteractivity(kb_none);
            const mgn: i32 = @intCast(t.margin_px);
            self.layer.setMargins(mgn, mgn, mgn, mgn);
            self.layer.on_configure = onLayerConfigure;
            self.layer.ctx = self;
            self.layer.on_closed = onLayerClosed;
            self.surface_live = true;
            self.toast_output = out;
            self.layer.setSize(@intCast(lay.width), @intCast(lay.height));
            self.layer.commit();
            self.flush();
            // Paint lands on the configure event.
            return;
        }
        if (!self.layer.configured or lay.width != self.surface_w or lay.height != self.surface_h) {
            self.layer.setSize(@intCast(lay.width), @intCast(lay.height));
            self.layer.commit();
            self.flush();
            // Paint lands on the configure event.
            return;
        }
        self.paint();
    }

    fn paint(self: *Daemon) void {
        if (!self.surface_live or !self.layer.configured) return;
        if (self.ncards == 0) return;
        const w = self.surface_w;
        const h = self.surface_h;
        if (w <= 0 or h <= 0) return;
        // `w`/`h` stay logical (the toast cards draw in them); only the buffer
        // is allocated at device pixels.
        if (!self.shm.ensure(self.bound.shm, "toasts", w * self.layer.scale, h * self.layer.scale)) {
            logz.log("toast: shm alloc failed {d}x{d}", .{ w, h });
            return;
        }
        self.shm.setReleaseHook(Daemon.onShmRelease, self);
        // Double-buffered: draw into whichever buffer the compositor is not
        // holding, so a slow release throttles to frame drops instead of
        // wedging every paint behind a single busy buffer.
        const buf = self.shm.acquire() orelse {
            if (!self.want_paint) logz.log("toast paint: deferred, both buffers held", .{});
            self.want_paint = true;
            return;
        };
        self.want_paint = false;
        self.last_paint_ms = monoMs();
        const cr = buf.cr orelse return;
        const cairo = shm_mod.cairo;
        cairo.cairo_save(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        // Scale the whole frame to the output's device pixels. The toast cards
        // below draw in logical coordinates (w/h); cairo rasterises at the
        // buffer's native resolution so HiDPI stays crisp.
        cairo.cairo_identity_matrix(cr);
        const nsc: f64 = @floatFromInt(self.layer.scale);
        cairo.cairo_scale(cr, nsc, nsc);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        const ch = chrome_colors.of(&self.loaded.cfg);
        const m = self.toastMetrics();
        const alpha = overlay.scale(&self.loaded.cfg.appearance, .notifications);
        const now = monoMs();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const pscope = notify_stats.scope(now);
        for (self.cards[0..self.ncards]) |card| {
            const n = findLive(&self.mgr, card.id) orelse continue;
            toast_cards.paintCard(cr, arena.allocator(), card, n, ch, m, alpha, now, self.hover_close == card.id);
            self.notePainted(card.id, n, now);
        }
        self.stats.notePaint(pscope.ms(monoMs()));
        cairo.cairo_restore(cr);
        // Frame callback BEFORE the commit it belongs to (protocol order):
        // requested after, it would fire for the *next* commit and the
        // chain would idle at the timer rate instead of the refresh rate.
        if (self.mgr.nextExpiryDelayMs() >= 0) self.requestFrame();
        if (self.layer.wl_surface != null) {
            self.layer.attach(buf.wlBuffer(), 0, 0);
            self.layer.setBufferScale(self.layer.scale);
            self.layer.damage(0, 0, w, h);
            self.layer.commit();
            self.flush();
        }
        buf.markBusy();
    }

    fn requestFrame(self: *Daemon) void {
        if (self.frame_cb != null) return;
        const s = self.layer.wl_surface orelse return;
        const cb = wl.wl_surface_frame(s) orelse {
            logz.log("toast paint: frame request failed", .{});
            return;
        };
        _ = wl.wl_callback_add_listener(cb, &frame_listener, self);
        self.frame_cb = cb;
    }

    fn frameDone(data: ?*anyopaque, cb: ?*wl.wl_callback, time: u32) callconv(.c) void {
        _ = time;
        const self: *Daemon = @ptrCast(@alignCast(data orelse return));
        if (cb) |c| wl.wl_callback_destroy(c);
        self.frame_cb = null;
        self.last_frame_ms = monoMs();
        // The countdown bar is compositor-paced: paint and commit from the
        // frame callback, which requests the next one. If a callback lands
        // inside the ~60 fps cap, do NOT re-request one without committing —
        // with nothing new to present the compositor strands it and the bar
        // falls back to the (slow) timer. The 16 ms timer paints instead.
        if (self.ncards == 0 or self.mgr.nextExpiryDelayMs() < 0) return;
        if (monoMs() - self.last_paint_ms >= 16) self.paint();
    }

    const frame_listener = wl.wl_callback_listener{ .done = frameDone };

    /// Per painted card: log Notify→visible trigger latency once, and
    /// mpris-text→art-visible once, then forget the id.
    fn notePainted(self: *Daemon, id: u32, n: *const notify_manager.Notification, now_ms: i64) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].id == id) {
                const dt = now_ms - self.pending.items[i].rx_ms;
                logz.log("notify latency: trigger-to-paint id={d} {d}ms", .{ id, dt });
                _ = self.pending.orderedRemove(i);
            } else i += 1;
        }
        if (n.image != null) {
            var kit = self.mpris.iterator();
            while (kit.next()) |kv| {
                const e = kv.value_ptr;
                if (e.id == id and e.art_rx_ms > 0 and !e.art_logged) {
                    e.art_logged = true;
                    logz.log("notify latency: track-to-art-visible id={d} {d}ms (art rx {d}ms after text)", .{
                        id,
                        now_ms - e.text_rx_ms,
                        e.art_rx_ms - e.text_rx_ms,
                    });
                }
            }
        }
    }
    fn onShmRelease(ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (self.want_paint) {
            logz.log("toast paint: shm released, repainting", .{});
            self.paint();
        }
    }

    // -- input ---------------------------------------------------------------

    /// Push queued Wayland requests out. Commits without a flush sit in the
    /// client buffer until incidental display traffic sends them — which is
    /// exactly the stuck-bar syndrome (hover brings motion events, whose
    /// dispatch flushes; timer paints do not). Flush after every
    /// commit.
    fn flush(self: *Daemon) void {
        if (self.conn.display) |d| _ = wl.wl_display_flush(d);
    }

    fn toastFocused(self: *Daemon) bool {
        const seat = self.bound.seat_obj orelse return false;
        const surf = self.layer.wl_surface orelse return false;
        return seat.focus_surface == surf;
    }

    fn onMotion(self: *Daemon, x: f64, y: f64) void {
        if (!self.toastFocused()) {
            if (self.hover_close != 0) {
                self.hover_close = 0;
                self.paint();
            }
            return;
        }
        const want = toast_cards.hitClose(self.cards[0..self.ncards], self.toastMetrics(), x, y) orelse 0;
        if (want != self.hover_close) {
            self.hover_close = want;
            self.paint();
        }
    }

    fn onButton(self: *Daemon, button: u32, state: u32) void {
        if (button != 0x110 or state != 1) return; // left press only
        if (!self.toastFocused()) return;
        const seat = self.bound.seat_obj orelse return;
        const x = seat.pointer_x;
        const y = seat.pointer_y;
        const m = self.toastMetrics();
        const id = toast_cards.hitClose(self.cards[0..self.ncards], m, x, y) orelse
            blk: {
                const idx = toast_cards.hitCard(self.cards[0..self.ncards], x, y) orelse return;
                break :blk self.cards[idx].id;
            };
        logz.log("toast: dismiss id={d}", .{id});
        _ = self.mgr.close(id, .dismissed);
        // close() fires the manager event → refresh via the callback.
    }

    // -- manager events --------------------------------------------------------

    fn onMgrEvent(ctx: ?*anyopaque, n: *const notify_manager.Notification, ev: notify_manager.Event) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        // Trigger stamp: the next paint carrying this id logs Notify→visible.
        if (ev == .added) {
            if (self.pending.items.len >= 64) _ = self.pending.orderedRemove(0);
            self.pending.append(self.gpa, .{ .id = n.id, .rx_ms = monoMs() }) catch {};
        }
        self.armTimer();
        self.refresh();
    }

    fn onMgrState(ctx: ?*anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        // DND coming on clears the board.
        if (self.mgr.do_not_disturb) {
            const items = self.mgr.all();
            var ids: [64]u32 = undefined;
            var k: usize = 0;
            for (items) |it| {
                if (k >= ids.len) break;
                ids[k] = it.id;
                k += 1;
            }
            for (ids[0..k]) |id| _ = self.mgr.close(id, .dismissed);
        }
        self.armTimer();
        self.refresh();
    }

    // -- D-Bus ------------------------------------------------------------------

    fn onBusFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = fd;
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const interesting = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if ((revents & interesting) == 0) return;
        while (true) {
            var p = (self.dbus.recvNow() catch break) orelse break;
            defer p.deinit();
            _ = self.tree.dispatch(p.msg, p.body_vals) catch false;
        }
    }

    // -- IPC ---------------------------------------------------------------------

    fn ipcEvent(ctx: *anyopaque, topic: []const u8, payload: []const u8, fds: []i32) void {
        _ = fds;
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, topic, kConfigTopic)) {
            self.reloadCfg();
            return;
        }
        if (!std.mem.eql(u8, topic, kPushTopic)) return;
        self.handlePush(payload);
        self.armTimer();
        self.refresh();
    }

    fn onIpcFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = fd;
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const interesting = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if ((revents & interesting) == 0) return;
        self.ipc.onFdReady(self.ipc.fd);
        if (!self.ipc.connected()) {
            logz.log("ipc: connection lost", .{});
            self.ipc_live = false;
        }
    }

    fn ipcConnect(self: *Daemon) void {
        const path = ipc_client.socketPathFor(self.gpa, self.eh_ipc_socket, self.xdg_runtime) catch return;
        defer self.gpa.free(path);
        if (!self.ipc.connect(path, 3)) {
            self.ipc_live = false;
            return;
        }
        self.ipc.setEventHandler(ipcEvent, self);
        self.ipc_live = self.ipc.subscribe(kPushTopic, 3000) and self.ipc.subscribe(kConfigTopic, 3000);
        if (!self.ipc_live) return;
        self.loop.watchFd(self.ipc.fd, std.posix.POLL.IN, onIpcFd, self) catch {
            self.ipc_live = false;
            return;
        };
        logz.log("ipc: subscribed", .{});
    }

    fn handlePush(self: *Daemon, payload: []const u8) void {
        // `mpris-art` carries a raw RGBA tail that may contain the separator:
        // parse positionally, never tokenize.
        if (std.mem.startsWith(u8, payload, "mpris-art")) {
            const s1 = std.mem.indexOfScalar(u8, payload, kFieldSep) orelse return;
            const s2 = std.mem.indexOfScalarPos(u8, payload, s1 + 1, kFieldSep) orelse return;
            const key = payload[s1 + 1 .. s2];
            const blob = payload[s2 + 1 ..];
            self.handleMprisArt(key, blob);
            return;
        }
        var parts: [6][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, payload, kFieldSep);
        while (it.next()) |p| {
            if (n >= parts.len) break;
            parts[n] = p;
            n += 1;
        }
        if (n == 0) return;
        if (std.mem.eql(u8, parts[0], "internal")) {
            if (n < 5) return;
            const urg: i32 = std.fmt.parseInt(i32, parts[4], 10) catch 1;
            const urgency: notify_manager.Urgency = switch (@max(0, @min(2, urg))) {
                0 => .low,
                2 => .critical,
                else => .normal,
            };
            _ = self.mgr.addOrUpdate(0, .{
                .app_name = parts[1],
                .summary = parts[2],
                .body = parts[3],
                .urgency = urgency,
                .timeout_ms = self.mgr.server_default_timeout_ms,
                .origin = .internal,
            });
        } else if (std.mem.eql(u8, parts[0], "mpris")) {
            if (n < 4) return;
            self.handleMpris(parts[1], parts[2], parts[3]);
        }
    }

    fn handleMpris(self: *Daemon, key: []const u8, summary: []const u8, body: []const u8) void {
        // Entry strings are owned copies: the IPC frame is gone after
        // dispatch, but art can arrive ticks later (owned copies).
        const gop = self.mpris.getOrPut(key) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch {
                _ = self.mpris.remove(key);
                return;
            };
            gop.value_ptr.* = .{};
        }
        const e = gop.value_ptr;
        if (e.summary.len > 0) self.gpa.free(e.summary);
        if (e.body.len > 0) self.gpa.free(e.body);
        e.summary = self.gpa.dupe(u8, summary) catch "";
        e.body = self.gpa.dupe(u8, body) catch "";
        e.text_rx_ms = monoMs();
        e.art_rx_ms = 0;
        e.art_logged = false;
        e.id = self.mgr.addOrUpdate(e.id, .{
            .app_name = "Media",
            .summary = e.summary,
            .body = e.body,
            .urgency = .normal,
            .timeout_ms = notify_manager.kDefaultTimeoutMs,
            .origin = .internal,
        });
        self.stats.noteMprisRx();
    }

    fn handleMprisArt(self: *Daemon, key: []const u8, blob: []const u8) void {
        const entry = self.mpris.get(key) orelse {
            self.stats.noteDropNoEntry(self.gpa, monoMs());
            return;
        };
        if (entry.id == 0) {
            self.stats.noteDropNoEntry(self.gpa, monoMs());
            return; // art before the notification: drop
        }
        self.stats.noteArtRx(blob.len);
        const raw = notify_push.deserializeBlob(self.gpa, blob) orelse {
            self.stats.noteDropBlob(self.gpa, monoMs(), blob.len);
            return;
        };
        defer self.gpa.free(raw.pixels);
        const small = notify_push.toRgba(self.gpa, raw.width, raw.height, raw.stride, raw.channels, raw.pixels) orelse {
            self.stats.noteDropBlob(self.gpa, monoMs(), blob.len);
            return;
        };
        defer self.gpa.free(small.pixels);
        if (self.mpris.getPtr(key)) |ep| {
            ep.art_rx_ms = monoMs();
            ep.art_logged = false;
        }
        var e = entry;
        // Replace keeps the id, so the stored entry needs no update.
        e.id = self.mgr.addOrUpdate(e.id, .{
            .app_name = "Media",
            .summary = e.summary,
            .body = e.body,
            .urgency = .normal,
            .timeout_ms = notify_manager.kDefaultTimeoutMs,
            .origin = .internal,
            .image = .{
                .width = small.width,
                .height = small.height,
                .row_stride = small.width * 4,
                .has_alpha = true,
                .bits_per_sample = 8,
                .channels = 4,
                .pixels = small.pixels,
            },
        });
        if (e.id != 0) self.stats.noteArtAttached();
    }

    // -- misc fds ------------------------------------------------------------------

    fn onTimerFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        self.onTimer();
    }

    fn onConfigFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = fd;
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const interesting = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if ((revents & interesting) == 0) return;
        if (self.watcher.drainAnyToml()) self.reloadCfg();
    }

    fn onMotionEv(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.onMotion(x, y);
    }

    fn onButtonEv(ctx: *anyopaque, button: u32, state: u32) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.onButton(button, state);
    }
};

fn findLive(mgr: *Manager, id: u32) ?*const notify_manager.Notification {
    for (mgr.all()) |*n| {
        if (n.id == id) return n;
    }
    return null;
}

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;

    logz.init(io, init.environ_map.get("HOME"), "horizon-notifications-zig");
    defer logz.deinit();
    logz.log("boot: pid={d}", .{linux.getpid()});

    var loop = loop_mod.Loop.init(gpa) catch |e| {
        logz.err("loop init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer loop.deinit();
    loop_mod.Loop.installSignalHandlers();

    var loaded = config.loadStacked(gpa, io, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME")) catch |e| {
        logz.err("config load failed: {s}", .{@errorName(e)});
        return 1;
    };
    // No defer: ownership moves to the daemon (reload swaps it).
    var palette = palette_sync.Sync.init(gpa, io) catch |e| {
        logz.err("palette init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer palette.deinit();
    palette.run(&loaded.cfg);

    var conn = conn_mod.Connection.init(gpa);
    defer conn.deinit();
    if (!conn.connect(null)) {
        logz.err("WAYLAND_DISPLAY not set or compositor unavailable", .{});
        return 1;
    }
    var bound: conn_mod.Connection.Bound = .{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    var ticks: u32 = 0;
    while (ticks < 30 and bound.outputs.items.len == 0) : (ticks += 1) {
        if (!conn.roundtrip()) break;
    }
    loop.watchFd(conn.displayFd(), std.posix.POLL.IN, pump.displayCallback, @ptrCast(conn.display.?)) catch {
        logz.err("cannot watch display", .{});
        return 1;
    };

    var daemon = Daemon{
        .gpa = gpa,
        .io = io,
        .xdg_config = init.environ_map.get("XDG_CONFIG_HOME"),
        .home = init.environ_map.get("HOME"),
        .eh_ipc_socket = init.environ_map.get("EH_IPC_SOCKET"),
        .xdg_runtime = init.environ_map.get("XDG_RUNTIME_DIR"),
        .conn = conn,
        .bound = bound,
        .loop = loop,
        .loaded = loaded,
        .palette = palette,
        .mgr = Manager.init(gpa),
        .stats = notify_stats.Stats.init(monoMs()),
        .dbus = dbus_conn.Conn.init(gpa),
        .ipc = ipc_client.Client.init(gpa),
        .shm = shm_mod.ShmPair.init(gpa),
        .mpris = std.StringHashMap(MprisEntry).init(gpa),
    };
    // conn/loop/bound/loaded/palette are shared by value with the locals
    // above (single deinit each via their defers at exit); the daemon only
    // borrows them for the run. Daemon.deinit covers daemon-created state.

    // Config watcher (inotify backup next to the `config.applied` broadcast).
    if (config.settingsDir(gpa, daemon.xdg_config, daemon.home)) |dir| {
        defer gpa.free(dir);
        var watching = daemon.watcher.watchConfigDir(dir);
        // inotify is not recursive: the `appearance` subdir (notifications
        // alpha among its knobs) needs its own watch. Created up front so
        // the watch is never installed against a missing dir.
        if (config.componentDir(gpa, daemon.xdg_config, daemon.home, "appearance")) |adir| {
            defer gpa.free(adir);
            std.Io.Dir.cwd().createDirPath(io, adir) catch {};
            if (watching) {
                _ = daemon.watcher.watchExtraDir(adir);
            } else watching = daemon.watcher.watchConfigDir(adir);
        } else |_| {}
        if (watching) {
            daemon.loop.watchFd(daemon.watcher.pollFd(), std.posix.POLL.IN, Daemon.onConfigFd, &daemon) catch {
                daemon.watcher.close();
            };
        }
    } else |_| {}

    daemon.mgr.now_fn = &realMono;
    daemon.applyConfig();
    _ = daemon.mgr.addEventCallback(Daemon.onMgrEvent, &daemon);
    daemon.mgr.setStateHandler(Daemon.onMgrState, &daemon);

    // D-Bus service (defer when another daemon owns the name).
    if (daemon.loaded.cfg.notifications.dbus_enabled) {
        const c_env = init.environ_map.get("DBUS_SESSION_BUS_ADDRESS");
        if (dbus_conn.addressFor(.session, c_env, null)) |addr| {
            daemon.dbus.connect(addr) catch {
                logz.log("dbus: connect failed; serving IPC + toasts only", .{});
            };
            if (daemon.dbus.fd >= 0) {
                daemon.dbus.hello() catch {
                    logz.log("dbus: hello failed; serving IPC + toasts only", .{});
                };
            }
            if (daemon.dbus.fd >= 0) {
                if (notify_service.claimBusName(&daemon.dbus)) {
                    daemon.tree = dbus_object.Tree.init(daemon.gpa, &daemon.dbus);
                    daemon.svc = notify_service.Service.init(daemon.gpa, &daemon.mgr, &daemon.tree);
                    daemon.svc.?.setRules(daemon.loaded.cfg.notifications.rules);
                    daemon.dbus_live = true;
                    daemon.loop.watchFd(daemon.dbus.fd, std.posix.POLL.IN, Daemon.onBusFd, &daemon) catch {
                        daemon.dbus_live = false;
                    };
                    logz.log("dbus: listening on org.freedesktop.Notifications", .{});
                } else {
                    logz.log("dbus: name owned — deferring to existing provider", .{});
                }
            }
        } else {
            logz.log("dbus: no session address; serving IPC + toasts only", .{});
        }
    } else {
        logz.log("dbus: disabled in config", .{});
    }

    // IPC (notify.push + config.applied).
    daemon.ipcConnect();

    // Expiry/animation timer.
    {
        const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
        if (rc >= 0) {
            daemon.timer_fd = @intCast(rc);
            daemon.loop.watchFd(daemon.timer_fd, std.posix.POLL.IN, Daemon.onTimerFd, &daemon) catch {
                _ = linux.close(daemon.timer_fd);
                daemon.timer_fd = -1;
            };
        }
    }

    // Pointer input on the toast surface.
    if (daemon.bound.seat_obj) |seat| {
        seat.on_pointer_motion = Daemon.onMotionEv;
        seat.on_pointer_button = Daemon.onButtonEv;
        seat.cb_ctx = &daemon;
    }

    // Scratch 1×1 surface for title measurement during layout.
    daemon.measure_surf = shm_mod.cairo.cairo_image_surface_create(shm_mod.cairo.CAIRO_FORMAT_ARGB32, 1, 1);
    if (daemon.measure_surf) |s| {
        daemon.measure_cr = shm_mod.cairo.cairo_create(s);
    }

    daemon.syncToast();
    daemon.armTimer();
    logz.log("running pid={d} dbus={d} toast={d} ipc={d}", .{
        linux.getpid(),
        @intFromBool(daemon.dbus_live),
        @intFromBool(daemon.surface_live),
        @intFromBool(daemon.ipc_live),
    });
    daemon.loop.run();
    daemon.deinit();
    logz.log("exit", .{});
    return 0;
}

fn realMono() i64 {
    return monoMs();
}
