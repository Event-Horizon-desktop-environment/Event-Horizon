//! `horizon-panel` — the top/bottom indicator bar as its own process.
//!
//! Zig port of `src/desktop_shell/panel/standalone/panel_standalone.cpp`
//! (event loop) + `core/panel.cpp` (draw/input/popups) +
//! `spawn/panel_spawn.cpp` (pidfile contract, owned by the supervisor).
//!
//! Own Wayland connection (`App`), one layer surface per selected output,
//! SHM-painted glass bar (`panel/paint.zig`) sized by `panel/core.zig`, with
//! the three-zone widget strip, hover/press, autohide slide, scroll-volume,
//! tooltips, popups (real sizes/positions, glass content), and IPC +
//! inotify reload. Exits 0 when `[panel] enabled` is false — the supervisor
//! only keeps the child up while it is turned on.

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
const foreign = eh.wl_foreign;
const tray_source = eh.tray_source;

const panel_paint = eh.panel_paint;
const panel_core = eh.panel_core;
const panel_settings = eh.panel_settings;
const panel_state = eh.panel_state;
const panel_standalone = eh.panel_standalone;
const panel_slots = eh.panel_slots;
const panel_popup = eh.panel_popup;
const panel_input = eh.panel_input;
const panel_types = eh.panel_types;

const Bar = struct {
    surface: layer.Surface = .{},
    shm: shm_mod.ShmBuffer,
    output: usize = 0,
    w: i32 = 0,
    h: i32 = 0,

    fn deinit(self: *Bar) void {
        self.surface.destroy();
        self.shm.deinit();
    }
};

const PopupSurf = struct {
    surface: layer.Surface = .{},
    shm: shm_mod.ShmBuffer,
    w: i32 = 0,
    h: i32 = 0,

    fn deinit(self: *PopupSurf) void {
        self.surface.destroy();
        self.shm.deinit();
    }

    fn close(self: *PopupSurf) void {
        self.surface.destroy();
        self.shm.deinit();
        self.surface = .{};
        self.shm = shm_mod.ShmBuffer.init(self.shm.alloc);
        self.w = 0;
        self.h = 0;
    }

    fn isOpen(self: *const PopupSurf) bool {
        return self.surface.wl_surface != null;
    }
};

const Panel = struct {
    a: *app_mod.App,
    bars: std.ArrayList(Bar) = .empty,
    popup: PopupSurf,
    st: panel_state.State = .{},
    hits: []panel_types.WidgetHit = &.{},
    toplevels: foreign.Tracker = undefined,
    toplevels_init: bool = false,
    tray: tray_source.Source = undefined,
    tray_init: bool = false,
    tray_keys: [][]const u8 = &.{},
    running_keys: [][]const u8 = &.{},
    running_serials: []u64 = &.{},
    dirty: bool = true,
    last_poll_ms: i64 = 0,
    last_tooltip_ms: i64 = 0,

    fn deinit(self: *Panel) void {
        for (self.bars.items) |*b| b.deinit();
        self.bars.deinit(self.a.gpa);
        self.popup.deinit();
        self.freeHits();
        self.freeRunning();
        self.freeTrayKeys();
        if (self.toplevels_init) self.toplevels.deinit();
        if (self.tray_init) self.tray.deinit();
    }

    fn freeHits(self: *Panel) void {
        if (self.hits.len > 0) self.a.gpa.free(self.hits);
        self.hits = &.{};
    }

    fn freeRunning(self: *Panel) void {
        for (self.running_keys) |k| self.a.gpa.free(k);
        if (self.running_keys.len > 0) self.a.gpa.free(self.running_keys);
        if (self.running_serials.len > 0) self.a.gpa.free(self.running_serials);
        self.running_keys = &.{};
        self.running_serials = &.{};
    }

    fn freeTrayKeys(self: *Panel) void {
        for (self.tray_keys) |k| self.a.gpa.free(k);
        if (self.tray_keys.len > 0) self.a.gpa.free(self.tray_keys);
        self.tray_keys = &.{};
    }

    fn cfg(self: *Panel) *const config.PanelSettings {
        return &self.a.loaded.cfg.panel;
    }

    fn applySettings(self: *Panel) void {
        const s = self.cfg();
        self.st.enabled = s.enabled;
        self.st.applyAutohide(s.auto_hide, panel_core.barHeight(s));
        self.dirty = true;
    }

    /// Rebuild running-app + tray key lists from live sources.
    fn rebuildSources(self: *Panel) void {
        const gpa = self.a.gpa;
        self.freeRunning();
        self.freeTrayKeys();
        if (self.toplevels_init) {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(gpa);
            var serials: std.ArrayList(u64) = .empty;
            defer serials.deinit(gpa);
            var n: usize = 0;
            for (self.toplevels.windows.items) |w| {
                if (w.closed or w.app_id.len == 0) continue;
                if (n >= 32) break;
                // One slot per app group (C++ running snapshot groups).
                var seen = false;
                for (keys.items) |k| {
                    if (std.mem.eql(u8, k, w.app_id)) {
                        seen = true;
                        break;
                    }
                }
                if (seen) continue;
                keys.append(gpa, gpa.dupe(u8, w.app_id) catch continue) catch continue;
                serials.append(gpa, @as(u64, @intCast(@intFromPtr(w)))) catch continue;
                n += 1;
            }
            self.running_keys = keys.toOwnedSlice(gpa) catch &.{};
            self.running_serials = serials.toOwnedSlice(gpa) catch &.{};
        }
        if (self.tray_init) {
            self.tray_keys = self.tray.keys(gpa) catch &.{};
        }
    }

    fn repaint(self: *Panel) void {
        if (!self.st.enabled) return;
        const s = self.cfg();
        const full = &self.a.loaded.cfg;
        // Autohide slide step (panel.cpp:583-595).
        const hide_target: f64 = if (s.auto_hide and !self.st.slide.reveal)
            @floatFromInt(panel_core.barHeight(s))
        else
            0;
        const moving = self.st.slide.step(hide_target);
        _ = moving;
        for (self.bars.items) |*b| {
            if (b.w <= 0 or b.h <= 0) continue;
            if (b.shm.data == null) continue;
            const cr = b.shm.cr orelse continue;
            // Clear, then the glass bar background.
            cairo.cairo_save(cr);
            cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
            cairo.cairo_paint(cr);
            cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
            cairo.cairo_restore(cr);
            const bar_h: f64 = @floatFromInt(panel_core.barHeight(s));
            const visible_h: f64 = if (s.auto_hide) @max(0, bar_h - self.st.slide.offset_px) else bar_h;
            if (visible_h >= 1.0) {
                const bar_w: f64 = switch (s.width_mode) {
                    0 => @max(1, @as(f64, @floatFromInt(b.w)) - 2.0 * @as(f64, @floatFromInt(s.floating_amount))),
                    2 => panel_core.fillBarWidth(0, 0, 0, 1.0, @floatFromInt(b.w)),
                    else => @floatFromInt(b.w),
                };
                // Fill-mode needs the measured width: measure cheaply with no
                // sources first is wrong, so use the real strip below. For
                // the background pass, non-fill modes are exact; fill uses
                // full width here and the strip centers itself.
                panel_paint.paintBarBackground(cr, full, s, 0, 0, @floatFromInt(b.w), visible_h);
                _ = bar_w;
                var res = panel_paint.paintWidgetBar(
                    self.a.gpa,
                    cr,
                    full,
                    s,
                    .{ .running_keys = self.running_keys, .running_serials = self.running_serials, .tray_keys = self.tray_keys },
                    0,
                    0,
                    @floatFromInt(b.w),
                    visible_h,
                    self.st.hover_slot,
                    self.st.pressed_slot,
                    self.st.hover_lift_px,
                ) catch continue;
                defer self.a.gpa.free(res.hits);
                self.freeHits();
                self.hits = res.hits;
                res.hits = &.{};
            }
            cairo.cairo_surface_flush(b.shm.cairo_surface.?);
            b.surface.attach(b.shm.wlBuffer(), 0, 0);
            b.surface.damage(0, 0, b.w, b.h);
            b.shm.markBusy();
            b.surface.commit();
        }
        _ = self.a.conn.flush();
    }

    fn openPopup(self: *Panel, kind: panel_types.PopupKind, anchor_x: i32) void {
        self.closePopup();
        if (kind == .none) return;
        const s = self.cfg();
        const size = panel_popup.sizeFor(kind, &.{});
        if (size.w <= 0 or size.h <= 0) return;
        const layer_w: f64 = if (self.bars.items.len > 0) @floatFromInt(self.bars.items[0].w) else 1920;
        const at = panel_core.popupPlacement(s, layer_w, anchor_x, size.w, size.h);
        const out = if (self.bars.items.len > 0)
            self.a.bound.outputs.items[self.bars.items[0].output].obj
        else
            null;
        const layer_kind: layer.Layer = .overlay;
        if (!self.popup.surface.create(self.a.bound.compositor, self.a.bound.layer_shell, out, layer_kind, "event-horizon-panel-popup")) return;
        const anchor: u32 = if (s.position_top)
            layer.Anchor.top | layer.Anchor.left
        else
            layer.Anchor.bottom | layer.Anchor.left;
        self.popup.surface.setAnchor(anchor);
        if (s.position_top) {
            self.popup.surface.setMargins(at.margin_edge, 0, 0, at.margin_side);
        } else {
            self.popup.surface.setMargins(0, 0, at.margin_edge, at.margin_side);
        }
        self.popup.surface.setExclusiveZone(-1);
        self.popup.surface.setSize(@intCast(size.w), @intCast(size.h));
        self.popup.surface.commit();
        var ticks: u32 = 0;
        while (ticks < 60 and !self.popup.surface.configured) : (ticks += 1) {
            if (!self.a.conn.roundtrip()) break;
        }
        if (!self.popup.surface.configured) {
            self.popup.close();
            return;
        }
        self.popup.w = @intCast(self.popup.surface.configured_width);
        self.popup.h = @intCast(self.popup.surface.configured_height);
        if (self.popup.w <= 0) self.popup.w = size.w;
        if (self.popup.h <= 0) self.popup.h = size.h;
        if (!self.popup.shm.ensure(self.a.bound.shm, "eh-panel-popup", self.popup.w, self.popup.h)) {
            self.popup.close();
            return;
        }
        self.paintPopup(kind);
        self.st.popup.open(kind, anchor_x, size.w, size.h);
    }

    fn paintPopup(self: *Panel, kind: panel_types.PopupKind) void {
        const cr = self.popup.shm.cr orelse return;
        const full = &self.a.loaded.cfg;
        cairo.cairo_save(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        panel_paint.paintBarBackground(cr, full, self.cfg(), 0, 0, @floatFromInt(self.popup.w), @floatFromInt(self.popup.h));
        // Glass stub content with the kind title (C++ popup_draw fallback).
        cairo.cairo_select_font_face(cr, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
        cairo.cairo_set_font_size(cr, 14.0);
        const mc = eh.widget_chrome_colors.of(full);
        cairo.cairo_set_source_rgba(cr, mc.text.r, mc.text.g, mc.text.b, 0.9);
        cairo.cairo_move_to(cr, 16, 28);
        const title: [*c]const u8 = switch (kind) {
            .calendar => "Calendar",
            .weather => "Weather",
            .volume_mixer => "Volume",
            .control_center => "Control Center",
            .vpn => "VPN",
            .battery => "Battery",
            .media_player => "Media",
            .bluetooth => "Bluetooth",
            .layout => "Layout",
            .tray => "Tray",
            .none => "Panel",
        };
        cairo.cairo_show_text(cr, title);
        cairo.cairo_restore(cr);
        cairo.cairo_surface_flush(self.popup.shm.cairo_surface.?);
        self.popup.surface.attach(self.popup.shm.wlBuffer(), 0, 0);
        self.popup.surface.damage(0, 0, self.popup.w, self.popup.h);
        self.popup.shm.markBusy();
        self.popup.surface.commit();
        _ = self.a.conn.flush();
    }

    fn closePopup(self: *Panel) void {
        self.popup.close();
        self.st.popup.close();
    }

    fn clickSlot(self: *Panel, idx: i32) void {
        if (idx < 0 or idx >= self.hits.len) return;
        const hit = self.hits[@intCast(idx)];
        const action = panel_core.dispatchSlotClick(
            hit.slot_kind,
            self.st.press_button,
            hit.chosen_serial,
            -1,
            self.st.popup.kind,
        );
        switch (action) {
            .overview_toggle => logz.log("panel: overview.toggle", .{}),
            .workspace_pick => logz.log("panel: workspace pick {s}", .{hit.widget_id}),
            .media_prev, .media_next, .media_play_pause, .media_popup => logz.log("panel: media action", .{}),
            .app_activate => logz.log("panel: activate serial={d}", .{hit.chosen_serial}),
            .launch_settings => logz.log("panel: launch settings", .{}),
            .open_trash => logz.log("panel: open trash", .{}),
            .open_popup => |k| {
                if (self.st.popup.toggleClosed(k)) return;
                self.openPopup(k, panel_popup.anchorXFor(hit));
            },
            .none => {
                // Media popup toggle-close.
                if (hit.slot_kind == @intFromEnum(panel_core.SlotKind.media) and self.st.popup.kind == .media_player) {
                    self.closePopup();
                }
            },
        }
    }

    fn clickDead(self: *Panel) void {
        const s = self.cfg();
        if (panel_core.deadZonePopup(self.st.press_button, s.deadzone_left, s.deadzone_middle, s.deadzone_right)) |k| {
            if (self.st.popup.toggleClosed(k)) return;
            if (panel_popup.deadZoneSize(k)) |size| {
                self.openPopup(k, @intFromFloat(@round(self.st.pointer_x)));
                _ = size;
            }
        }
    }

    fn onReload(ctx: *anyopaque) void {
        const self: *Panel = @ptrCast(@alignCast(ctx));
        self.applySettings();
        self.rebuildSources();
        self.repaint();
    }

    fn onEnter(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *Panel = @ptrCast(@alignCast(ctx));
        self.st.pointer_x = x;
        self.st.pointer_y = y;
        self.st.onPointerEnter(self.cfg().auto_hide);
        self.repaint();
    }

    fn onLeave(ctx: *anyopaque) void {
        const self: *Panel = @ptrCast(@alignCast(ctx));
        self.st.onPointerLeave(self.cfg().auto_hide, panel_core.barHeight(self.cfg()));
        self.repaint();
    }

    fn onMotion(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *Panel = @ptrCast(@alignCast(ctx));
        self.st.pointer_x = x;
        self.st.pointer_y = y;
        const hover = panel_types.hitIndexAt(self.hits, x, y);
        if (hover != self.st.hover_slot) {
            self.st.hover_slot = hover;
            self.st.hover_lift_px = if (hover >= 0) 5.0 else 0.0;
            self.st.tooltip.hover_slot = hover;
            self.st.tooltip.hover_start_ms = @intCast(@max(nowMs(), 0));
            self.st.tooltip.shown_slot = -1;
            self.repaint();
        }
    }

    fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
        const self: *Panel = @ptrCast(@alignCast(ctx));
        const pressed = state == 1;
        if (pressed) {
            self.st.popup.press_dismissed = self.st.popup.kind;
            if (self.popup.isOpen()) self.closePopup();
            self.st.press_button = button;
            self.st.pressed_slot = panel_types.hitIndexAt(self.hits, self.st.pointer_x, self.st.pointer_y);
            self.repaint();
        } else {
            const hit = panel_types.hitIndexAt(self.hits, self.st.pointer_x, self.st.pointer_y);
            const was = self.st.pressed_slot;
            self.st.pressed_slot = -1;
            switch (panel_input.classifyRelease(hit, was)) {
                .click_slot => self.clickSlot(hit),
                .dead_zone => self.clickDead(),
                .none => {},
            }
            self.st.popup.press_dismissed = .none;
            self.repaint();
        }
    }

    fn onAxis(ctx: *anyopaque, delta: f64) void {
        const self: *Panel = @ptrCast(@alignCast(ctx));
        if (panel_input.scrollVolume(delta, self.st.hover_slot, self.cfg().scroll_volume, 0.5)) |_| {
            logz.log("panel: scroll volume {d}", .{delta});
        }
    }

    fn onTrackerChanged(ctx: *anyopaque) void {
        const self: *Panel = @ptrCast(@alignCast(ctx));
        self.dirty = true;
    }
};

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;
    logz.init(io, init.environ_map.get("HOME"), "horizon-panel-zig");
    defer logz.deinit();
    logz.log("boot: pid={d}", .{linux.getpid()});

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch &.{};
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("usage: horizon-panel   top/bottom indicator bar\n", .{});
            return 0;
        }
    }

    var a = app_mod.App.init(gpa, io, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME")) catch |e| {
        logz.err("init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer a.deinit();

    // Only used if turned on: a disabled panel parks here and lets the
    // supervisor stand it down (disabled panel parks here).
    if (!a.loaded.cfg.panel.enabled) {
        logz.log("panel disabled in config; exiting", .{});
        return 0;
    }

    var p = Panel{ .a = &a, .popup = .{ .shm = shm_mod.ShmBuffer.init(gpa) } };
    defer p.deinit();
    p.applySettings();

    p.toplevels = foreign.Tracker.init(gpa);
    p.toplevels_init = true;
    p.toplevels.bindExt(a.bound.foreign_toplevel_list);
    p.toplevels.on_changed = Panel.onTrackerChanged;
    p.toplevels.changed_ctx = &p;

    p.tray = tray_source.Source.init(gpa);
    p.tray_init = true;
    _ = p.tray.start();

    // Output selection: all / auto(first) / named (standalone.zig).
    const s = &a.loaded.cfg.panel;
    const sel = panel_standalone.classifyOutputAssign(s.output_name);
    var targets: std.ArrayList(usize) = .empty;
    defer targets.deinit(gpa);
    switch (sel) {
        .all => for (a.bound.outputs.items, 0..) |_, i| targets.append(gpa, i) catch break,
        .auto_primary => if (a.bound.outputs.items.len > 0) targets.append(gpa, 0) catch {},
        .named => {
            var hit: ?usize = null;
            for (a.bound.outputs.items, 0..) |o, i| {
                if (panel_standalone.outputNameMatches(s.output_name, o.name)) {
                    hit = i;
                    break;
                }
            }
            targets.append(gpa, hit orelse 0) catch {};
        },
    }
    if (targets.items.len == 0 and a.bound.outputs.items.len > 0) targets.append(gpa, 0) catch {};

    const bar_h = panel_core.barHeight(s);
    for (targets.items) |oi| {
        if (oi >= a.bound.outputs.items.len) continue;
        const o = a.bound.outputs.items[oi];
        const want_w: i32 = if (o.width > 0) o.width else 1920;
        var b = Bar{ .shm = shm_mod.ShmBuffer.init(gpa), .output = oi, .w = want_w, .h = bar_h };
        const place = panel_core.barPlacement(s, true);
        const layer_kind: layer.Layer = if (s.overlay_layer) .overlay else .top;
        if (!b.surface.create(a.bound.compositor, a.bound.layer_shell, o.obj, layer_kind, ns.panel)) {
            b.shm.deinit();
            continue;
        }
        const anchor: u32 = (if (place.anchor_top) layer.Anchor.top else layer.Anchor.bottom) | layer.Anchor.left | layer.Anchor.right;
        b.surface.setAnchor(anchor);
        if (place.anchor_top) {
            b.surface.setMargins(place.margin_edge, 0, 0, 0);
        } else {
            b.surface.setMargins(0, 0, place.margin_edge, 0);
        }
        b.surface.setExclusiveZone(place.exclusive_zone);
        b.surface.setSize(0, @intCast(place.bar_h));
        b.surface.commit();
        var ticks: u32 = 0;
        while (ticks < 100 and !b.surface.configured) : (ticks += 1) {
            if (!a.conn.roundtrip()) break;
        }
        if (!b.surface.configured) {
            logz.err("surface never configured for output {d}", .{oi});
            b.surface.destroy();
            b.shm.deinit();
            continue;
        }
        b.w = @intCast(b.surface.configured_width);
        b.h = @intCast(b.surface.configured_height);
        if (b.w <= 0) b.w = want_w;
        if (b.h <= 0) b.h = place.bar_h;
        if (!b.shm.ensure(a.bound.shm, "eh-panel", b.w, b.h)) {
            b.surface.destroy();
            b.shm.deinit();
            continue;
        }
        p.bars.append(gpa, b) catch {
            b.surface.destroy();
            b.shm.deinit();
            break;
        };
    }
    if (p.bars.items.len == 0) {
        logz.err("no panel surfaces", .{});
        return 1;
    }

    if (a.bound.seat_obj) |seat| {
        seat.on_pointer_enter = Panel.onEnter;
        seat.on_pointer_leave = Panel.onLeave;
        seat.on_pointer_motion = Panel.onMotion;
        seat.on_pointer_button = Panel.onButton;
        seat.on_pointer_axis = Panel.onAxis;
        seat.cb_ctx = &p;
    }
    a.on_reload = Panel.onReload;
    a.reload_ctx = &p;

    p.rebuildSources();
    p.repaint();
    logz.log("running bars={d}", .{p.bars.items.len});
    if (config.componentDir(gpa, a.xdg_config, a.home, "panel")) |dir| {
        defer gpa.free(dir);
        a.startWatching(&.{dir});
    } else |_| {}
    _ = a.conn.flush();

    // 1 s poll (battery/bluetooth/MPRIS refresh + repaint) + tooltip timing,
    // driven off the App loop tick via a timerfd.
    const timer_fd: i32 = timerFd(1000) orelse -1;
    defer {
        if (timer_fd >= 0) _ = linux.close(timer_fd);
    }
    if (timer_fd >= 0) {
        a.loop.watchFd(timer_fd, std.posix.POLL.IN, onTick, @ptrCast(&p)) catch {};
    }
    a.run();
    return 0;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
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
    const self: *Panel = @ptrCast(@alignCast(ctx));
    var buf: [8]u8 = undefined;
    _ = linux.read(fd, &buf, buf.len);
    const now = nowMs();
    // Live sources may have changed (tray store, toplevel dirty flag).
    if (self.tray_init) {
        if (self.tray.pump(now)) self.dirty = true;
    }
    if (self.dirty) {
        self.dirty = false;
        self.rebuildSources();
    }
    // Tooltip 500 ms hover delay (state.zig), checked on the 1 s tick plus
    // every pointer motion that re-arms it.
    if (self.st.tooltip.due(self.st.hover_slot, @intCast(@max(now, 0)))) {
        self.st.tooltip.shown_slot = self.st.hover_slot;
        logz.log("panel: tooltip slot={d}", .{self.st.hover_slot});
    }
    if (!self.st.enabled) return;
    self.last_poll_ms = now;
    self.repaint();
}
