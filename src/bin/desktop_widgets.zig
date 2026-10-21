//! `horizon-desktop-widgets` — the desktop widget layer process.
//!
//! One transparent
//! `event-horizon-desktop-widgets` layer surface per output (BOTTOM, full
//! output), the widget `Host` fed from `desktop_widgets_layout.txt`,
//! left-drag to move, right-drag to scale, clicks to widgets first, a 1s
//! service tick plus a 33ms animation tick while any widget needs it, and
//! inotify reloads when the settings tab saves.
//!
//! Same design as `horizon-wallpaper` (layer surfaces + `App` config/loop)
//! with the dock's seat/timerfd input pattern.

const std = @import("std");
const eh = @import("eh");
const app = @import("app.zig");
const layer = eh.wl_layer;
const ns = eh.ns;
const shm_mod = eh.wl_shm;
const config = eh.config;
const parent_guard = eh.parent_guard;
const logz = eh.logz;
const linux = std.os.linux;
const cairo = shm_mod.cairo;
const wlayer = eh.desktop_widgets_layer;
const wdata = eh.desktop_widgets_data;
const wpersist = eh.desktop_widgets_persist;
const wctx = eh.desktop_widgets_ctx;
const mpris = eh.mpris_client;
const weather = eh.weather;
const wset = eh.widget_settings;
const media_bus = eh.desktop_widgets_media_bus;
const watch_mod = eh.config_watch;

const Surface = struct {
    layer: layer.Surface = .{},
    /// Rotating buffers: a repaint that landed while the compositor still
    /// held the last frame is what flicker is (see `ShmPair.acquire`).
    /// A single buffer repainted at 33ms paints under the screen.
    ///
    /// Heap-pinned: `wl_buffer_add_listener` captures the `ShmBuffer`
    /// address, and `surfaces.append` reallocations move `Surface` values —
    /// a moved pool leaves `onRelease` clearing freed memory while the live
    /// flags stay busy forever (every later frame drops). The pool must
    /// never move after `ensure`.
    shm: *shm_mod.ShmPair,
    w: i32 = 0,
    h: i32 = 0,
    output_name: []const u8 = "",
};

const DesktopWidgets = struct {
    app: *app.App,
    layer: wlayer.Layer = .{},
    surfaces: std.ArrayList(Surface) = .empty,
    mpris: mpris.Client = undefined,
    mpris_inited: bool = false,
    timer_fd: i32 = -1,
    anim_fd: i32 = -1,
    anim_interval_ms: u32 = 0,
    layout_watch: watch_mod.Watcher = .{},
    weather_last_ms: i64 = 0,
    last_drop_ms: i64 = 0,
    tick_n: u64 = 0,
    commit_n: u64 = 0,
    release_n: u64 = 0,

    fn onRelease(ctx: *anyopaque) void {
        const self: *DesktopWidgets = @ptrCast(@alignCast(ctx));
        self.release_n += 1;
    }

    fn deinit(self: *DesktopWidgets) void {
        for (self.surfaces.items) |*s| {
            s.layer.destroy();
            s.shm.deinit();
            self.app.gpa.destroy(s.shm);
            if (s.output_name.len > 0) self.app.gpa.free(s.output_name);
        }
        self.surfaces.deinit(self.app.gpa);
        if (self.mpris_inited) self.mpris.deinit();
        if (self.timer_fd >= 0) _ = linux.close(self.timer_fd);
        if (self.anim_fd >= 0) _ = linux.close(self.anim_fd);
        self.layout_watch.close();
        self.layer.deinit();
    }

    fn outputNameFor(self: *DesktopWidgets, surf: ?*anyopaque) []const u8 {
        const ws = surf orelse return "";
        for (self.surfaces.items) |*s| {
            if (@as(?*anyopaque, s.layer.wl_surface) == ws) return s.output_name;
        }
        return "";
    }

    fn paintAll(self: *DesktopWidgets) void {
        const ctx = wctx.Ctx.fromSchema(&self.app.loaded.cfg, self.app.io);
        for (self.surfaces.items) |*s| {
            if (s.w <= 0 or s.h <= 0) continue;
            if (!s.shm.ensure(self.app.bound.shm, "desktop-widgets", s.w, s.h)) continue;
            // Drawn into a buffer the compositor has already let go of.
            // When it still holds them all, the frame waits for the next
            // event instead of landing under the screen.
            const buf = s.shm.acquire() orelse {
                // Said at most once a second: drops are bursty by nature
                // (one per surface per tick while wedged).
                const now_ms: i64 = @intCast(wctx.monotonicMs());
                if (now_ms - self.last_drop_ms > 1000) {
                    self.last_drop_ms = now_ms;
                    logz.log("paint: dropped frame, buffers busy", .{});
                }
                continue;
            };
            const cr = buf.cr orelse continue;
            cairo.cairo_save(cr);
            cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
            cairo.cairo_paint(cr);
            cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
            self.layer.paintWidgets(cr, s.w, s.h, s.output_name, ctx);
            cairo.cairo_restore(cr);
            s.layer.attach(buf.wlBuffer(), 0, 0);
            // The buffer is allocated at the output's physical pixels and the
            // widgets draw in those same physical coordinates, so declare the
            // scale — the compositor then maps it to the correct logical
            // surface size instead of treating a 2x buffer as 2x too large.
            s.layer.setBufferScale(s.layer.scale);
            s.layer.damage(0, 0, s.w, s.h);
            buf.markBusy();
            s.layer.commit();
            self.commit_n += 1;
        }
        _ = self.app.conn.flush();
    }

    /// Settings root for the component toml. Must use the app's own env
    /// copies — nulls fall through to `/tmp/<leaf>` and the toml silently
    /// reads as empty (every toggle then looks broken).
    fn stateDir(self: *DesktopWidgets) ?[]u8 {
        return config.settingsDir(self.app.gpa, self.app.xdg_config, self.app.home) catch null;
    }

    /// `App.on_reload` — the layout file or the component toml changed
    /// under inotify (usually the settings tab saving), so re-read
    /// everything and repaint.
    fn onReload(ctx: *anyopaque) void {
        const self: *DesktopWidgets = @ptrCast(@alignCast(ctx));
        self.reloadWidgets();
    }

    fn reloadWidgets(self: *DesktopWidgets) void {
        const dir = self.stateDir() orelse return;
        defer self.app.gpa.free(dir);
        const slots = wpersist.loadShellSlots(self.app.gpa, self.app.io, dir);
        defer {
            if (slots.output_name.len > 0) self.app.gpa.free(slots.output_name);
            for (slots.disabled) |d| self.app.gpa.free(d);
            if (slots.disabled.len > 0) self.app.gpa.free(slots.disabled);
        }
        self.layer.reload(self.app.io, self.app.gpa, slots.disabled);
        logz.log("reload: {d} widgets, {d} slots disabled", .{ self.layer.host.instanceCount(), slots.disabled.len });
        self.paintAll();
    }

    fn weatherRequest(self: *DesktopWidgets) weather.Request {
        // First weather-family instance carries the unit/geo keys, like the
        // dock's `weatherRequest` (per-instance `[widget.<id>]` settings).
        const cfg = &self.app.loaded.cfg;
        for (self.layer.host.instances.items) |*inst| {
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

    fn onTimer(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *DesktopWidgets = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        // 1s service tick: MPRIS polls first so the widgets' second-tick
        // refresh reads this tick's snapshot; the bus publishes
        // unconditionally because a moving position alone never changes the
        // poll signature (see media_bus's position projection).
        if (self.mpris_inited) {
            _ = self.mpris.poll();
            media_bus.publish(self.mpris.snap);
        }
        _ = self.layer.tickSecond(self.app.io);
        const now_ms: i64 = @intCast(wctx.monotonicMs());
        if (now_ms - self.weather_last_ms > 10 * 60 * 1000) {
            self.weather_last_ms = now_ms;
            _ = weather.request(self.app.gpa, self.app.io, self.weatherRequest());
        }
        self.paintAll();
        self.armAnim();
        self.tick_n += 1;
        if (self.tick_n % 10 == 0) {
            var busy: usize = 0;
            var total: usize = 0;
            for (self.surfaces.items) |*sf| {
                for (sf.shm.bufs[0..sf.shm.count]) |*b| {
                    total += 1;
                    if (b.busy) busy += 1;
                }
            }
            logz.log("tick {d}: commits={d} releases={d} buffers busy {d}/{d}", .{ self.tick_n, self.commit_n, self.release_n, busy, total });
        }
    }

    fn onLayoutFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *DesktopWidgets = @ptrCast(@alignCast(ctx));
        _ = fd;
        if ((revents & std.posix.POLL.IN) == 0) return;
        // The layout file is `.txt`, which the app's toml watcher ignores
        // — this dedicated watch is what picks up tab saves.
        if (self.layout_watch.drainChanged("desktop_widgets_layout.txt")) {
            self.reloadWidgets();
        }
    }

    fn onAnimTick(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *DesktopWidgets = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        self.paintAll();
        self.armAnim();
    }

    fn armAnim(self: *DesktopWidgets) void {
        const want = self.layer.host.animIntervalMs();
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
        self.app.loop.watchFd(fd, std.posix.POLL.IN, onAnimTick, @ptrCast(self)) catch {
            _ = linux.close(fd);
            return;
        };
        self.anim_fd = fd;
        self.anim_interval_ms = want;
    }

    fn onMotion(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *DesktopWidgets = @ptrCast(@alignCast(ctx));
        const seat = self.app.bound.seat_obj orelse return;
        if (self.layer.motion(x, y, self.outputNameFor(seat.focus_surface))) self.paintAll();
    }

    fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
        const self: *DesktopWidgets = @ptrCast(@alignCast(ctx));
        const seat = self.app.bound.seat_obj orelse return;
        const out = self.outputNameFor(seat.focus_surface);
        const x = seat.pointer_x;
        const y = seat.pointer_y;
        if (state == 0) {
            if (button == 0x110) {
                if (self.layer.release(true, false, self.app.gpa)) |configs| {
                    _ = wdata.save(self.app.gpa, self.app.io, configs);
                    self.paintAll();
                }
            } else if (button == 0x111) {
                if (self.layer.release(false, true, self.app.gpa)) |configs| {
                    _ = wdata.save(self.app.gpa, self.app.io, configs);
                    self.paintAll();
                }
            }
            return;
        }
        if (button == 0x110) {
            _ = self.layer.press(x, y, out, false, self.app.gpa);
        } else if (button == 0x111) {
            _ = self.layer.press(x, y, out, true, self.app.gpa);
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;

    logz.init(io, init.environ_map.get("HOME"), "horizon-desktop-widgets-zig");
    defer logz.deinit();
    logz.log("boot: pid={d}", .{linux.getpid()});

    var a = app.App.init(gpa, io, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME")) catch |e| {
        logz.err("init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer a.deinit();

    var dw = DesktopWidgets{ .app = &a };
    defer dw.deinit();
    dw.layer.init(gpa);
    a.on_reload = DesktopWidgets.onReload;
    a.reload_ctx = &dw;
    dw.mpris = mpris.Client.init(gpa);
    dw.mpris_inited = true;
    media_bus.setHandler(.{ .ctx = @ptrCast(&dw), .act = handleMediaAction });

    dw.reloadWidgets();
    if (dw.layer.host.instanceCount() == 0) {
        logz.log("no widgets configured", .{});
    }

    for (a.bound.outputs.items) |o| {
        if (o.width <= 0 or o.height <= 0) continue;
        const pool = gpa.create(shm_mod.ShmPair) catch break;
        pool.* = shm_mod.ShmPair.init(gpa);
        var s = Surface{ .shm = pool, .w = o.width, .h = o.height };
        s.output_name = gpa.dupe(u8, o.name) catch "";
        if (!s.layer.create(a.bound.compositor, a.bound.layer_shell, o.obj, .bottom, ns.desktop_widgets)) continue;
        s.layer.setAnchor(layer.Anchor.top | layer.Anchor.bottom | layer.Anchor.left | layer.Anchor.right);
        s.layer.setExclusiveZone(0);
        s.layer.setSize(@intCast(o.width), @intCast(o.height));
        s.layer.commit();
        var ticks: u32 = 0;
        while (ticks < 100 and !s.layer.configured) : (ticks += 1) {
            if (!a.conn.roundtrip()) break;
        }
        if (!s.layer.configured) {
            s.layer.destroy();
            s.shm.deinit();
            gpa.destroy(pool);
            continue;
        }
        logz.log("surface: {s} output {d}x{d} scale {} -> configured {d}x{d} buffer {d}x{d}", .{
            s.output_name,
            o.width,
            o.height,
            s.layer.scale,
            s.layer.configured_width,
            s.layer.configured_height,
            o.width,
            o.height,
        });
        if (!s.shm.ensure(a.bound.shm, "desktop-widgets", o.width, o.height)) {
            s.layer.destroy();
            s.shm.deinit();
            gpa.destroy(pool);
            continue;
        }
        s.shm.setReleaseHook(DesktopWidgets.onRelease, @ptrCast(&dw));
        dw.surfaces.append(gpa, s) catch {
            s.layer.destroy();
            s.shm.deinit();
            gpa.destroy(pool);
            break;
        };
    }
    if (dw.surfaces.items.len == 0) {
        logz.err("no outputs painted", .{});
        return 1;
    }
    dw.paintAll();

    if (a.bound.seat_obj) |seat| {
        seat.on_pointer_motion = DesktopWidgets.onMotion;
        seat.on_pointer_button = DesktopWidgets.onButton;
        seat.cb_ctx = &dw;
        logz.log("input: pointer handlers installed", .{});
    } else {
        logz.err("input: no wl_seat bound, widgets will be static", .{});
    }

    // 1s service tick.
    {
        const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
        if (rc >= 0) {
            const fd: i32 = @intCast(rc);
            const its = linux.itimerspec{
                .it_interval = .{ .sec = 1, .nsec = 0 },
                .it_value = .{ .sec = 1, .nsec = 0 },
            };
            if (linux.timerfd_settime(fd, .{}, &its, null) == 0) {
                a.loop.watchFd(fd, std.posix.POLL.IN, DesktopWidgets.onTimer, @ptrCast(&dw)) catch {
                    _ = linux.close(fd);
                };
                dw.timer_fd = fd;
            } else _ = linux.close(fd);
        }
    }
    dw.armAnim();

    // Watch the widget layout file + the settings component dir so tab
    // saves reload without a restart.
    if (wdata.layoutPath(gpa)) |lp| {
        defer if (lp) |p| gpa.free(p);
        if (lp) |p| {
            if (std.fs.path.dirname(p)) |dir| a.startWatching(&.{dir});
        }
    } else |_| {}
    if (config.componentDir(gpa, a.xdg_config, a.home, "desktop_widgets")) |dir| {
        defer gpa.free(dir);
        // Created by the settings tab's first save; make it up front so the
        // watch cannot be lost against a missing dir (slot toggles then only
        // land on restart).
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        a.startWatching(&.{dir});
    } else |_| {}
    // Dedicated watch for the layout `.txt` (see `onLayoutFd`).
    if (wdata.layoutPath(gpa)) |lp| {
        defer if (lp) |pp| gpa.free(pp);
        if (lp) |pp| {
            if (std.fs.path.dirname(pp)) |dir| {
                if (dw.layout_watch.watchConfigDir(dir)) {
                    a.loop.watchFd(dw.layout_watch.pollFd(), std.posix.POLL.IN, DesktopWidgets.onLayoutFd, @ptrCast(&dw)) catch {
                        dw.layout_watch.close();
                    };
                }
            }
        }
    } else |_| {}

    a.run();
    return 0;
}

/// MPRIS bus actions drive the owned client (see `media_bus.Handler`).
fn handleMediaAction(ptr: *anyopaque, what: media_bus.Action, pos_us: i64) bool {
    const dw: *DesktopWidgets = @ptrCast(@alignCast(ptr));
    if (!dw.mpris_inited) return false;
    switch (what) {
        .play_pause => return dw.mpris.act(.play_pause),
        .next => return dw.mpris.act(.next),
        .previous => return dw.mpris.act(.previous),
        .shuffle => {
            _ = dw.mpris.poll();
            return dw.mpris.setShuffle(!dw.mpris.snap.shuffle);
        },
        .loop => return dw.mpris.cycleLoop(),
        .seek => return dw.mpris.seek(pos_us),
    }
}
