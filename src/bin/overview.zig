//! `horizon-overview` — the workspace overview and launchpad as its own
//! process. Single-shot: opens on launch, exits on dismiss. The dock (or a
//! key binding) spawns it; toggling kills the running copy.
//!
//! Everything the surface needs is fetched up front: config for theme and
//! wallpaper, Hyprland workspaces plus clients for the cards, the icon
//! theme path for tiles and grid. Nothing here talks to the dock.

const std = @import("std");
const linux = std.os.linux;
const c = @cImport(@cInclude("stdlib.h"));

const wl = @import("../wl/c.zig").wl;
const conn_mod = @import("../wl/connection.zig");
const seat_mod = @import("../wl/seat.zig");
const pump = @import("../wl/pump.zig");
const loop_mod = @import("../loop.zig");
const logz = @import("../logz.zig");
const config = @import("../config.zig");
const overlay = @import("../config/overlay.zig");
const palette_sync = @import("../color/palette_sync.zig");
const parent_guard = @import("../parent_guard.zig");

const app_launch = @import("../services/app_launch.zig");
const pin_store = @import("../config/pin_store.zig");
const section_store = @import("../config/section_store.zig");
const paths = @import("../desktop_shell/common/paths.zig");
const icon_cache = @import("../desktop_shell/common/icon_cache.zig");
const icon_themes = @import("../desktop_shell/common/icon_themes.zig");

const chrome_colors = @import("../desktop_shell/widgets/shared/chrome_colors.zig");
const wset = @import("../desktop_shell/widgets/shared/widget_settings.zig");
const ws_paint = @import("../desktop_shell/widgets/workspaces/workspaces_paint.zig");

const ov_host = @import("../desktop_shell/overview/host.zig");
const ov_pick = @import("../desktop_shell/overview/pick.zig");
const ov_types = @import("../desktop_shell/overview/types.zig");
const ov_tiles = @import("../desktop_shell/overview/tiles.zig");
const ov_ws = @import("../desktop_shell/overview/ws.zig");
const ov_capture = @import("../desktop_shell/overview/capture.zig");
const hypr_ipc = @import("../backends/hyprland_ipc.zig");
const ov_reveal = @import("../desktop_shell/overview/reveal.zig");
const ov_shots = @import("../desktop_shell/overview/shots.zig");
const ov_launch = @import("../desktop_shell/overview/launch.zig");
const shot_cache = @import("../wl/capture/shot_cache.zig");

fn getenvStr(key: [:0]const u8) ?[]const u8 {
    const p = c.getenv(key) orelse return null;
    return std.mem.span(p);
}

fn clampf(v: f64, lo: f64, hi: f64) f64 {
    return @min(hi, @max(lo, v));
}

const Ov = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    conn: *conn_mod.Connection,
    bound: *conn_mod.Connection.Bound,
    loop: *loop_mod.Loop,
    host: ov_host.Host = undefined,
    capture: ?ov_capture.Capture = null,
    shots: ?ov_shots.Shots = null,
    /// Off-monitor reveal machine: parks uncopyable windows on-monitor
    /// just long enough to capture them, then restores focus.
    reveal: ov_reveal.Reveal = .{},
    /// Hyprland event socket: window/workspace events re-snapshot through
    /// the pulse (debounced) instead of polling.
    ev_fd: i32 = -1,
    ev_buf: [8192]u8 = [_]u8{0} ** 8192,
    ev_len: usize = 0,
    want_resnap: bool = false,
    last_resnap_ms: u64 = 0,
    /// Set when the outputs deserve a fresh screencopy pass; the pulse
    /// runs it at loop level, never inside the display's dispatch.
    want_shots: bool = false,
    snap: ?ov_ws.Snapshot = null,
    cfg: ?*const config.ShellConfig = null,
    theme: []const u8 = "hicolor",
    app_dirs: [][]const u8 = &.{},
    anim_fd: i32 = -1,
    /// Hyprland input focus whitelist: while this exists, only the overview
    /// surface receives pointer/keyboard events, so a game holding pointer
    /// lock or relative motion cannot keep driving from behind the overlay.
    focus_grab: ?*wl.hyprland_focus_grab_v1 = null,
    /// Last frame-callback timestamp, for scroll-glide dt.
    last_frame_ms: u32 = 0,
    /// Display refresh for the pulse: detected from the output we're on,
    /// so motion tracks 60/144/240Hz instead of a fixed 60fps tick.
    pulse_hz: u32 = 60,
    /// Last paint cost, so the pulse never schedules faster than painting
    /// sustains (a 5ms paint at 240Hz would otherwise queue forever).
    last_paint_ms: u64 = 0,
    xdg_config: ?[]const u8 = null,
    home: ?[]const u8 = null,

    const Self = @This();

    fn deinit(self: *Self) void {
        self.dropFocusGrab();
        if (self.anim_fd >= 0) _ = linux.close(self.anim_fd);
        if (self.ev_fd >= 0) _ = linux.close(self.ev_fd);
        if (self.capture) |*cap| cap.deinit();
        if (self.shots) |*s| s.deinit();
        if (self.snap) |*s| s.deinit();
        if (self.app_dirs.len > 0) app_launch.freeDirs(self.gpa, self.app_dirs);
        self.host.deinit();
    }

    /// Restrict compositor input focus to the overview. Hyprland-only; on
    /// other compositors the full-screen overlay already takes pointer focus
    /// normally. The protocol clears the grab if input lands on a surface
    /// outside the whitelist (for example another monitor); the next pointer
    /// enter re-arms it.
    fn takeInputFocus(self: *Self) void {
        if (self.focus_grab != null) return;
        const mgr = self.bound.focus_grab_manager orelse return;
        const surf = self.host.surface.wl_surface orelse return;
        const grab = wl.hyprland_focus_grab_manager_v1_create_grab(mgr) orelse return;
        wl.hyprland_focus_grab_v1_add_surface(grab, surf);
        _ = wl.hyprland_focus_grab_v1_add_listener(grab, &focus_grab_listener, self);
        wl.hyprland_focus_grab_v1_commit(grab);
        self.focus_grab = grab;
        logz.log("overview: input focus grabbed", .{});
    }

    fn dropFocusGrab(self: *Self) void {
        if (self.focus_grab) |grab| {
            wl.hyprland_focus_grab_v1_destroy(grab);
            self.focus_grab = null;
        }
    }

    fn onFocusGrabCleared(ctx: ?*anyopaque, grab: ?*wl.hyprland_focus_grab_v1) callconv(.c) void {
        _ = grab;
        const self: *Self = @ptrCast(@alignCast(ctx orelse return));
        // The compositor makes the object inert; drop our handle so the next
        // pointer enter can create a fresh grab.
        self.dropFocusGrab();
        logz.log("overview: input focus grab cleared", .{});
    }

    const focus_grab_listener = wl.hyprland_focus_grab_v1_listener{
        .cleared = onFocusGrabCleared,
    };

    /// Theme icon pixels for a window app id, through the shared grid
    /// cache: one disk-backed store for windows and grid alike, so a
    /// window never pays a resolve the grid already warmed.
    fn winIcon(ctx: *anyopaque, app_id: []const u8) ?ov_tiles.IconPx {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (app_id.len == 0) return null;
        const name = self.host.apps.iconNameForClass(app_id);
        if (name.len == 0) return null;
        // Paint-safe: cached pixels or null, never a synchronous decode.
        // The tick prefetcher warms whatever this misses.
        if (self.host.apps.icons.get(name)) |px| {
            if (px.data.len == 0) return null;
            return .{ .data = px.data, .w = px.w, .h = px.h };
        }
        self.host.apps.icon_pending = true;
        return null;
    }

    /// Paint-time answer for a window's captured frame. A miss leaves the
    /// tile tinted; the store fills in as frames land.
    fn winFrame(ctx: *anyopaque, addr: []const u8) ?ov_tiles.LiveFrame {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.capture) |*cap| return cap.frameFor(addr);
        return null;
    }

    /// Subscribe to the compositor's event socket: window and workspace
    /// changes re-snapshot through the pulse instead of polling. Silent
    /// when there is no socket (non-Hyprland) — actions still refresh.
    fn startEvents(self: *Self) void {
        var env = self.hyprEnv();
        defer env.deinit();
        const maybe = hypr_ipc.resolvePaths(self.gpa, self.io, &env) catch return;
        var socks = maybe orelse return;
        defer hypr_ipc.freePaths(self.gpa, &socks);
        if (socks.ev.len == 0) return;
        const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(fd) != .SUCCESS) return;
        var addr: linux.sockaddr.un = .{ .path = [_]u8{0} ** 108 };
        if (socks.ev.len >= addr.path.len) {
            _ = linux.close(@intCast(fd));
            return;
        }
        @memcpy(addr.path[0..socks.ev.len], socks.ev);
        const rc = linux.connect(@intCast(fd), @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
        const e = linux.errno(rc);
        if (e != .SUCCESS and e != .INPROGRESS) {
            _ = linux.close(@intCast(fd));
            return;
        }
        self.ev_fd = @intCast(fd);
        self.loop.watchFd(self.ev_fd, std.posix.POLL.IN, onEventFd, @ptrCast(self)) catch {
            _ = linux.close(self.ev_fd);
            self.ev_fd = -1;
            return;
        };
        logz.log("overview: event socket subscribed", .{});
    }

    /// Compositor events worth a re-snapshot. Anything else (cursor,
    /// clock, urgent hints) leaves the cards alone.
    fn eventInteresting(line: []const u8) bool {
        const names = [_][]const u8{
            "workspace>>",
            "createworkspace>>",
            "destroyworkspace>>",
            "moveworkspace>>",
            "renameworkspace>>",
            "openwindow>>",
            "closewindow>>",
            "movewindow>>",
            "changefloatingmode>>",
            "fullscreen>>",
            "focusedmon>>",
            "configreloaded",
        };
        for (names) |n| {
            if (line.len >= n.len and std.mem.eql(u8, line[0..n.len], n)) return true;
        }
        return false;
    }

    fn onEventFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if ((revents & std.posix.POLL.IN) == 0) return;
        var tmp: [2048]u8 = undefined;
        while (true) {
            const rc = linux.recvfrom(fd, &tmp, tmp.len, 0, null, null);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e == .AGAIN) break;
            if (e != .SUCCESS) {
                _ = linux.close(fd);
                self.ev_fd = -1;
                return;
            }
            if (rc == 0) {
                _ = linux.close(fd);
                self.ev_fd = -1;
                return;
            }
            const n: usize = @intCast(rc);
            for (tmp[0..n]) |b| {
                if (self.ev_len < self.ev_buf.len) {
                    self.ev_buf[self.ev_len] = b;
                    self.ev_len += 1;
                }
            }
            if (self.ev_len >= self.ev_buf.len) {
                self.ev_len = 0;
                continue;
            }
            var start: usize = 0;
            for (self.ev_buf[0..self.ev_len], 0..) |b, i| {
                if (b != '\n') continue;
                if (eventInteresting(self.ev_buf[start..i])) {
                    self.want_resnap = true;
                    self.armAnim();
                }
                start = i + 1;
            }
            if (start > 0) {
                std.mem.copyForwards(u8, self.ev_buf[0..], self.ev_buf[start..self.ev_len]);
                self.ev_len -= start;
            }
        }
    }

    /// Paint-time answer for a workspace's monitor shot. A miss leaves the
    /// card or thumb on its own fill; the store fills in on the next pass.
    fn monitorShot(ctx: *anyopaque, monitor: []const u8) ?ov_tiles.LiveFrame {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.shots) |*s| return s.frame(monitor);
        return null;
    }

    /// Reveal hooks: the machine finds overflow windows without frames,
    /// focuses them onto the monitor, forces a fresh capture, and puts
    /// the saved focus back. Empty focus restores are skipped — there is
    /// nothing to put back.
    fn revealCtx(self: *Self) ov_reveal.Ctx {
        return .{
            .ptr = self,
            .enabled = struct {
                fn f(p: *anyopaque) bool {
                    const s: *Self = @ptrCast(@alignCast(p));
                    if (s.capture == null or !s.capture.?.active()) return false;
                    if (!s.host.open or s.host.show_apps or s.host.drag_active) return false;
                    return true;
                }
            }.f,
            .find_target = struct {
                fn f(p: *anyopaque) ?ov_reveal.Target {
                    const s: *Self = @ptrCast(@alignCast(p));
                    const snap = &(s.snap orelse return null);
                    const cap = &(s.capture orelse return null);
                    for (snap.ws) |w| {
                        for (w.wins) |win| {
                            if (!win.overflow or win.addr.len == 0) continue;
                            if (cap.frameFor(win.addr) != null) continue;
                            var t = ov_reveal.Target{};
                            t.set(win.addr);
                            if (t.len == 0) continue;
                            return t;
                        }
                    }
                    return null;
                }
            }.f,
            .focused = struct {
                fn f(p: *anyopaque) ?ov_reveal.Target {
                    const s: *Self = @ptrCast(@alignCast(p));
                    const snap = &(s.snap orelse return null);
                    for (snap.ws) |w| {
                        for (w.wins) |win| {
                            if (!win.focused or win.addr.len == 0) continue;
                            var t = ov_reveal.Target{};
                            t.set(win.addr);
                            if (t.len == 0) continue;
                            return t;
                        }
                    }
                    return null;
                }
            }.f,
            .has_frame = struct {
                fn f(p: *anyopaque, addr: []const u8) bool {
                    const s: *Self = @ptrCast(@alignCast(p));
                    if (s.capture) |*cap| return cap.frameFor(addr) != null;
                    return false;
                }
            }.f,
            .focus = struct {
                fn f(p: *anyopaque, addr: []const u8) void {
                    if (addr.len == 0) return;
                    const s: *Self = @ptrCast(@alignCast(p));
                    var buf: [128]u8 = undefined;
                    const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.focus({{window = \"address:{s}\"}})", .{addr}) catch return;
                    _ = s.hyprSend(cmd);
                }
            }.f,
            .resync = struct {
                fn f(p: *anyopaque, addr: []const u8) void {
                    const s: *Self = @ptrCast(@alignCast(p));
                    if (s.capture) |*cap| _ = cap.retryWindow(addr);
                    s.syncCapture();
                }
            }.f,
        };
    }

    /// One bounded screencopy pass over every bound output. Loop level
    /// only — it dispatches on its own, which is never safe from inside
    /// the display's dispatch. The first pass runs before the loop starts,
    /// so the cards open on the desktop without the overlay in it.
    fn fillShots(self: *Self) u32 {
        self.want_shots = false;
        const display = self.conn.display orelse return 0;
        const shm = self.bound.shm orelse return 0;
        const mgr = self.bound.screencopy orelse return 0;
        const t0 = nowMs();
        if (self.shots == null) self.shots = ov_shots.Shots.init(self.gpa);
        const n = self.shots.?.fill(display, mgr, shm, self.bound.outputs.items);
        logz.log("overview: output shots={d} in {d}ms", .{ n, nowMs() - t0 });
        return n;
    }

    /// Called from the capture store during dispatch when a frame lands.
    /// Repaints through the vsync chain so the frame shows without delay.
    fn onCaptureFrame(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.refresh();
    }

    /// Ask the stream for the windows currently scrolled into view. Live
    /// mode keeps a one-card margin either side so a scroll lands on
    /// already-streamed neighbours; snapshot mode asks once for every
    /// window so off-screen cards are filled too.
    fn syncCapture(self: *Self) void {
        if (self.capture == null) return;
        const cap = &self.capture.?;
        if (!cap.active()) return;
        const live = self.liveUpdates();
        var addrs: std.ArrayList([]const u8) = .empty;
        defer addrs.deinit(self.gpa);
        if (live) {
            const lo, const hi = self.visibleCardRange();
            var ci = lo;
            while (ci <= hi) : (ci += 1) {
                if (ci < 0 or ci >= self.host.cards.len) continue;
                for (self.host.cards[@intCast(ci)].wins) |win| addrs.append(self.gpa, win.addr) catch break;
            }
        } else {
            for (self.host.cards) |card| {
                for (card.wins) |win| addrs.append(self.gpa, win.addr) catch break;
            }
        }
        cap.sync(addrs.items, self.captureMaxDim(), live);
    }

    /// Frames only ever draw at tile size, so request them near what a
    /// tile can show rather than native window resolution: a 4K window
    /// would otherwise arrive huge and burn CPU downsampling (inside the
    /// dispatch, stalling the open) just to be shrunk to a few hundred
    /// pixels. 0.75x of the card covers the biggest tile with headroom
    /// for the drag ghost; falls back to 512 before layout is known.
    fn captureMaxDim(self: *Self) i32 {
        const l = self.host.layout;
        const card_dim = @max(l.card_w, l.card_h);
        if (card_dim <= 0.0) return 512;
        return @intFromFloat(clampf(card_dim * 0.75 + 0.5, 256.0, 768.0));
    }

    /// Whether live streaming is on and the compositor offered the export
    /// protocol. Otherwise captures are one-shot snapshots.
    fn liveUpdates(self: *Self) bool {
        const cfg = self.cfg orelse return false;
        return cfg.appearance.overview_live_updates;
    }

    /// Card indices actually on screen, plus one of margin. From the
    /// strip's viewport: pitch slides cards against scroll, so only the
    /// cards crossing the viewport (and their neighbours) are worth
    /// streaming.
    fn visibleCardRange(self: *Self) struct { i32, i32 } {
        const n: i32 = @intCast(self.host.cards.len);
        if (n == 0) return .{ 0, -1 };
        const l = self.host.layout;
        const pitch: f64 = if (l.pitch > 0.0) l.pitch else 1.0;
        const viewport: f64 = if (l.axis == .vertical) l.h else l.w;
        const first = self.host.scroll / pitch;
        const last = (self.host.scroll + @max(viewport, pitch)) / pitch;
        const lo: i32 = @as(i32, @intFromFloat(@floor(first))) - 1;
        const hi: i32 = @as(i32, @intFromFloat(@ceil(last))) + 1;
        return .{ @max(0, @min(lo, n - 1)), @max(0, @min(hi, n - 1)) };
    }

    fn hyprEnv(self: *Self) std.process.Environ.Map {
        var env = std.process.Environ.Map.init(self.gpa);
        if (getenvStr("HYPRLAND_INSTANCE_SIGNATURE")) |v| env.put("HYPRLAND_INSTANCE_SIGNATURE", v) catch {};
        if (getenvStr("XDG_RUNTIME_DIR")) |v| env.put("XDG_RUNTIME_DIR", v) catch {};
        return env;
    }

    fn maxSlots(_: *Self, cfg: *const config.ShellConfig) i32 {
        const lists = [_][]const []const u8{ cfg.dock.left_widgets, cfg.dock.center_widgets, cfg.dock.right_widgets };
        for (lists) |list| {
            for (list) |id| {
                if (std.mem.eql(u8, wset.implementationType(cfg, id), "workspaces")) {
                    return ws_paint.maxSlotsFromSettings(cfg, id);
                }
            }
        }
        return 5;
    }

    fn reloadOverview(self: *Self, cfg: *const config.ShellConfig) void {
        var env = self.hyprEnv();
        defer env.deinit();
        if (env.get("HYPRLAND_INSTANCE_SIGNATURE") == null) return;
        var snap = ov_ws.fetch(self.gpa, self.io, &env) orelse return;
        errdefer snap.deinit();
        ov_ws.applyMaxSlots(self.gpa, &snap, self.maxSlots(cfg)) catch {
            snap.deinit();
            return;
        };
        if (self.snap) |*old| old.deinit();
        self.snap = snap;
        // The window set changed; ask the stream for the new one, and
        // re-shoot the outputs behind the cards on the next pulse.
        self.syncCapture();
        self.want_shots = true;
    }

    fn pushCards(self: *Self) void {
        const gpa = self.gpa;
        var cards: std.ArrayList(ov_host.Card) = .empty;
        defer {
            for (cards.items) |cc| gpa.free(cc.wins);
            cards.deinit(gpa);
        }
        // Manufactured placeholder workspaces carry no monitor of their
        // own; they show the active workspace's output until the
        // compositor gives them a real one.
        var fb_monitor: []const u8 = "";
        if (self.snap) |*snap| {
            for (snap.ws) |w| {
                if (w.active and w.monitor.len > 0) {
                    fb_monitor = w.monitor;
                    break;
                }
            }
            if (fb_monitor.len == 0) {
                for (snap.ws) |w| {
                    if (w.monitor.len > 0) {
                        fb_monitor = w.monitor;
                        break;
                    }
                }
            }
        }
        if (self.snap) |*snap| {
            for (snap.ws) |w| {
                const owned = gpa.alloc(ov_host.Win, w.wins.len) catch continue;
                errdefer gpa.free(owned);
                for (w.wins, 0..) |win, i| {
                    owned[i] = .{
                        .addr = win.addr,
                        .app_id = win.app_id,
                        .title = win.title,
                        .focused = win.focused,
                        .box = .{
                            .x = win.x,
                            .y = win.y,
                            .w = win.w,
                            .h = win.h,
                            .nx = win.nx,
                            .ny = win.ny,
                            .nw = win.nw,
                            .nh = win.nh,
                        },
                    };
                }
                cards.append(gpa, .{
                    .id = w.id,
                    .label = w.label,
                    .monitor = if (w.monitor.len > 0) w.monitor else fb_monitor,
                    .active = w.active,
                    .wins = owned,
                }) catch {
                    gpa.free(owned);
                    continue;
                };
            }
        }
        if (cards.items.len == 0) {
            const one = [_]ov_host.Card{.{ .id = 1, .label = "1", .active = true, .wins = &.{} }};
            self.host.setCards(&one);
            return;
        }
        self.host.setCards(cards.items);
    }

    fn hyprSend(self: *Self, cmd: []const u8) bool {
        var env = self.hyprEnv();
        defer env.deinit();
        const reply = ov_ws.send(self.gpa, self.io, &env, cmd) orelse return false;
        defer self.gpa.free(reply);
        return ov_ws.repliedOk(reply);
    }

    fn wsJump(self: *Self, id: i32) void {
        var buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.focus({{workspace = {d}}})", .{id}) catch return;
        if (!self.hyprSend(cmd)) {
            const plain = std.fmt.bufPrint(&buf, "dispatch workspace {d}", .{id}) catch return;
            _ = self.hyprSend(plain);
        }
    }

    fn runAction(self: *Self, a: ov_host.Action) void {
        switch (a) {
            .none => {},
            .refresh => self.refresh(),
            .dismiss => loop_mod.Loop.requestStop(),
            .focus => |flat| {
                if (self.host.flatLoc(flat)) |loc| {
                    const win = self.host.cards[loc[0]].wins[loc[1]];
                    if (win.addr.len > 0) {
                        var buf: [128]u8 = undefined;
                        const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.focus({{window = \"address:{s}\"}})", .{win.addr}) catch null;
                        if (cmd) |cc| {
                            if (self.hyprSend(cc)) {
                                loop_mod.Loop.requestStop();
                                return;
                            }
                        }
                    }
                }
                loop_mod.Loop.requestStop();
            },
            .close_win => |flat| {
                if (self.host.flatLoc(flat)) |loc| {
                    const win = self.host.cards[loc[0]].wins[loc[1]];
                    if (win.addr.len > 0) {
                        var buf: [128]u8 = undefined;
                        const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.window.close({{window = \"address:{s}\"}})", .{win.addr}) catch null;
                        if (cmd) |cc| {
                            if (self.hyprSend(cc)) {
                                logz.log("overview: closed '{s}'", .{win.title});
                                if (self.cfg) |cfg_ref| self.reloadOverview(cfg_ref);
                                self.pushCards();
                                self.refresh();
                                return;
                            }
                        }
                    }
                }
                logz.log("overview: close needs a window address", .{});
            },
            .select_ws => |id| {
                self.wsJump(id);
                loop_mod.Loop.requestStop();
            },
            .add_ws => {
                var top: i32 = 0;
                for (self.host.cards) |card| top = @max(top, card.id);
                self.wsJump(top + 1);
                loop_mod.Loop.requestStop();
            },
            .apps => {
                self.host.toggleApps(self.theme);
                self.refresh();
            },
            .launch_app => |cat_idx| {
                if (self.host.apps.catalogEntry(cat_idx)) |e| {
                    logz.log("overview: launching '{s}'", .{e.name});
                    if (!app_launch.launchExec(self.gpa, self.io, e.exec)) {
                        logz.err("overview: could not start '{s}'", .{e.name});
                    }
                }
                loop_mod.Loop.requestStop();
            },
            .launch_modal => |cat_idx| {
                if (self.host.apps.catalogEntry(cat_idx)) |e| {
                    logz.log("overview: launching '{s}'", .{e.name});
                    if (!app_launch.launchExec(self.gpa, self.io, e.exec)) {
                        logz.err("overview: could not start '{s}'", .{e.name});
                    }
                }
                loop_mod.Loop.requestStop();
            },
            .move_win => |m| {
                const addr = self.winAddr(m.flat) orelse {
                    logz.log("overview: move needs a window address", .{});
                    return;
                };
                const ws_id = self.wsIdForCard(m.ws);
                var buf: [160]u8 = undefined;
                const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.window.move({{workspace = {d}, window = \"address:{s}\"}})", .{ ws_id, addr }) catch return;
                if (self.hyprSend(cmd)) {
                    logz.log("overview: moved '{s}' to ws {d}", .{ addr, ws_id });
                    if (self.cfg) |cfg_ref| self.reloadOverview(cfg_ref);
                    self.pushCards();
                }
                self.refresh();
            },
            .move_win_new => |flat| {
                const addr = self.winAddr(flat) orelse {
                    logz.log("overview: move needs a window address", .{});
                    return;
                };
                // Always a brand-new id past the highest known one; the
                // compositor creates it on demand. Reusing an empty
                // placeholder would address a workspace that may not
                // exist, and the move silently goes nowhere.
                var top: i32 = 0;
                for (self.host.cards) |card| {
                    top = @max(top, card.id);
                }
                const target = top + 1;
                var buf: [160]u8 = undefined;
                const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.window.move({{workspace = {d}, window = \"address:{s}\"}})", .{ target, addr }) catch return;
                if (self.hyprSend(cmd)) {
                    logz.log("overview: moved '{s}' to new ws {d}", .{ addr, target });
                    if (self.cfg) |cfg_ref| self.reloadOverview(cfg_ref);
                    self.pushCards();
                }
                self.refresh();
            },
            .swap_wins => |sw| {
                const win_a = self.winAddr(sw.a) orelse {
                    logz.log("overview: swap needs window addresses", .{});
                    return;
                };
                const win_b = self.winAddr(sw.b) orelse {
                    logz.log("overview: swap needs window addresses", .{});
                    return;
                };
                var buf: [256]u8 = undefined;
                const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.window.swap({{window = \"address:{s}\", target = \"address:{s}\"}})", .{ win_a, win_b }) catch return;
                if (self.hyprSend(cmd)) {
                    logz.log("overview: swapped '{s}' <-> '{s}'", .{ win_a, win_b });
                    if (self.cfg) |cfg_ref| self.reloadOverview(cfg_ref);
                    self.pushCards();
                }
                self.refresh();
            },
            .ctx_menu => |m| {
                const dock_pin = self.dockPinned(m.path);
                const task_pin = self.taskbarPinned(m.path);
                self.host.apps.openCtx(m.x, m.y, @floatFromInt(self.host.buf_w), @floatFromInt(self.host.buf_h), self.host.layout.ui, m.path, dock_pin, task_pin);
                self.refresh();
            },
            .ctx_dock => |path| {
                self.toggleDockPin(path);
                self.refresh();
            },
            .ctx_taskbar => |path| {
                self.toggleTaskbarPin(path);
                self.refresh();
            },
        }
    }

    fn winAddr(self: *Self, flat: usize) ?[]const u8 {
        if (self.host.flatLoc(flat)) |loc| {
            return self.host.cards[loc[0]].wins[loc[1]].addr;
        }
        return null;
    }

    /// Workspace id for a card index (the drop target the strip picked).
    fn wsIdForCard(self: *Self, card_idx: i32) i32 {
        if (card_idx >= 0 and card_idx < self.host.cards.len) {
            return self.host.cards[@intCast(card_idx)].id;
        }
        return card_idx + 1;
    }

    fn dockPinned(self: *Self, path: []const u8) bool {
        if (path.len == 0) return false;
        const cfg = self.cfg orelse return false;
        for (cfg.dock.pinned_apps) |p| {
            if (paths.sameAppId(p, path)) return true;
        }
        return false;
    }

    fn taskbarPinned(self: *Self, path: []const u8) bool {
        if (path.len == 0) return false;
        const norm = paths.normalizeAppId(self.gpa, path) catch return false;
        defer self.gpa.free(norm);
        if (norm.len == 0 or std.mem.eql(u8, norm, "unknown")) return false;
        const cfg = self.cfg orelse return false;
        for (cfg.taskbar.pinned_apps) |p| {
            const pn = paths.normalizeAppId(self.gpa, p) catch continue;
            defer self.gpa.free(pn);
            if (std.mem.eql(u8, pn, norm)) return true;
        }
        return false;
    }

    fn toggleDockPin(self: *Self, path: []const u8) void {
        if (path.len == 0) return;
        const cfg = self.cfg orelse return;
        var next: std.ArrayList([]const u8) = .empty;
        defer {
            for (next.items) |p| self.gpa.free(p);
            next.deinit(self.gpa);
        }
        var removed = false;
        for (cfg.dock.pinned_apps) |p| {
            if (paths.sameAppId(p, path)) {
                removed = true;
                continue;
            }
            next.append(self.gpa, self.gpa.dupe(u8, p) catch continue) catch continue;
        }
        if (!removed) {
            next.append(self.gpa, self.gpa.dupe(u8, path) catch return) catch return;
        }
        logz.log("overview: {s} dock pin '{s}'", .{ if (removed) "unpin" else "pin", path });
        const settings = config.settingsDir(self.gpa, self.xdg_config, self.home) catch return;
        defer self.gpa.free(settings);
        const file = config.componentPath(self.gpa, settings, "dock") catch return;
        defer self.gpa.free(file);
        pin_store.save(self.gpa, self.io, file, next.items) catch |e| {
            logz.err("overview: cannot write {s}: {s}", .{ file, @errorName(e) });
        };
    }

    fn toggleTaskbarPin(self: *Self, path: []const u8) void {
        if (path.len == 0) return;
        const norm = paths.normalizeAppId(self.gpa, path) catch return;
        defer self.gpa.free(norm);
        if (norm.len == 0 or std.mem.eql(u8, norm, "unknown")) return;
        const cfg = self.cfg orelse return;
        var next: std.ArrayList([]const u8) = .empty;
        defer {
            for (next.items) |p| self.gpa.free(p);
            next.deinit(self.gpa);
        }
        var removed = false;
        for (cfg.taskbar.pinned_apps) |p| {
            const pn = paths.normalizeAppId(self.gpa, p) catch continue;
            defer self.gpa.free(pn);
            if (std.mem.eql(u8, pn, norm)) {
                removed = true;
                continue;
            }
            next.append(self.gpa, self.gpa.dupe(u8, p) catch continue) catch continue;
        }
        if (!removed) {
            next.append(self.gpa, self.gpa.dupe(u8, norm) catch return) catch return;
        }
        logz.log("overview: {s} taskbar pin '{s}'", .{ if (removed) "unpin" else "pin", norm });
        const settings = config.settingsDir(self.gpa, self.xdg_config, self.home) catch return;
        defer self.gpa.free(settings);
        const file = config.componentPath(self.gpa, settings, "taskbar") catch return;
        defer self.gpa.free(file);
        const entry = section_store.Entry{ .key = "pinned_apps", .value = section_store.arrayValue(self.gpa, next.items) catch return };
        defer self.gpa.free(entry.value);
        section_store.save(self.gpa, self.io, file, "taskbar", &.{entry}) catch |e| {
            logz.err("overview: cannot write {s}: {s}", .{ file, @errorName(e) });
        };
    }

    fn refresh(self: *Self) void {
        const t0 = nowMs();
        self.host.refresh();
        // Paint cost feeds the pulse interval: never tick faster than
        // painting sustains.
        self.last_paint_ms = nowMs() - t0;
        if (self.capture) |*cap| {
            // Deferred re-requests release here, on the paint cadence.
            cap.tick();
        }
        // The blocking screencopy pass cannot run in dispatch-nested
        // contexts (frame callbacks included) — it waits on the timer.
        if (self.want_shots) self.armAnim();
        if (!self.conn.flush()) logz.log("overview: flush failed after refresh", .{});
    }

    const k_anim_frame_ns: u64 = 16 * std.time.ns_per_ms;

    fn armAnim(self: *Self) void {
        if (self.anim_fd < 0) {
            const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
            if (rc < 0) return;
            self.anim_fd = @intCast(rc);
            self.loop.watchFd(self.anim_fd, std.posix.POLL.IN, onAnimTick, @ptrCast(self)) catch {
                _ = linux.close(self.anim_fd);
                self.anim_fd = -1;
                return;
            };
        }
        // One frame at the display's rate, but never faster than painting
        // sustains: the ease math is time-based, so a longer tick just
        // means bigger (still correct) steps.
        const hz: u64 = @max(1, self.pulse_hz);
        var interval_ms = @max(@as(u64, 4), 1000 / hz);
        interval_ms = @min(interval_ms, 16);
        interval_ms = @max(interval_ms, self.last_paint_ms + 1);
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = @as(isize, @intCast(interval_ms * std.time.ns_per_ms)) },
        };
        _ = linux.timerfd_settime(self.anim_fd, .{}, &its, null);
    }

    /// Vsync pulse: runs in the frame callback with the compositor's
    /// timestamp, so animations advance one real display interval per
    /// tick at whatever rate the panel runs. Blocking capture passes
    /// never run here (dispatch-nested) — they stay on the timer, which
    /// rejoins this chain with a repaint when done.
    fn frameTicked(ctx: *anyopaque, time_ms: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var paint = false;
        if (self.last_frame_ms == 0) {
            self.last_frame_ms = time_ms;
        }
        const dt_s: f64 = @min(0.1, @as(f64, @floatFromInt(time_ms -| self.last_frame_ms)) / 1000.0);
        self.last_frame_ms = time_ms;
        // A scroll glide settles through this same cadence.
        if (self.host.edgeScrollTick(dt_s)) paint = true;
        if (self.host.scrollTick(@max(dt_s, 1.0 / 480.0))) paint = true;
        // A lifted finger glide snaps to the nearest card once its
        // settle delay passes — unless motion already cancelled it.
        if (self.host.snap_at_ms != 0 and nowMs() >= self.host.snap_at_ms) {
            self.host.snap_at_ms = 0;
            if (self.host.snapTargets()) paint = true;
        }
        // Compositor events, debounced: a window or workspace change
        // re-snapshots through the pulse instead of polling.
        if (self.want_resnap and nowMs() -| self.last_resnap_ms >= 50) {
            self.want_resnap = false;
            self.last_resnap_ms = nowMs();
            if (self.cfg) |cfg| {
                self.reloadOverview(cfg);
                self.pushCards();
            }
            paint = true;
        }
        if (self.host.fillIcons()) paint = true;
        if (self.capture) |*cap| {
            cap.tick();
            if (cap.takeDirty()) paint = true;
            if (cap.needsWork()) paint = true;
        }
        if (self.reveal.tick(nowMs(), self.revealCtx())) paint = true;
        if (paint) self.refresh();
        // No re-arm here: refresh() commits and requests the next frame
        // exactly when it painted, so the chain sustains itself while
        // there is work and goes silent when idle.
    }

    fn onAnimTick(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        if ((revents & std.posix.POLL.IN) == 0) return;
        // Loop level only: the blocking screencopy pass. Afterwards the
        // repaint rejoins the vsync chain on its own.
        if (self.want_shots) {
            if (self.fillShots() > 0) self.refresh();
        }
    }

    fn onSurface(self: *Self) bool {
        const seat = self.bound.seat_obj orelse return false;
        const os = self.host.surface.wl_surface orelse return false;
        return seat.focus_surface != null and seat.focus_surface == os;
    }

    fn lastPointer(self: *Self) [2]f64 {
        const seat = self.bound.seat_obj orelse return .{ 0, 0 };
        return .{ seat.pointer_x, seat.pointer_y };
    }

    fn onEnter(ctx: *anyopaque, _: f64, _: f64) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // A grab that was cleared (input visited another surface) comes back
        // as soon as the pointer re-enters the overview.
        self.takeInputFocus();
    }

    fn onLeave(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.host.motion(-1, -1)) self.refresh();
    }

    fn onMotion(ctx: *anyopaque, _: f64, _: f64) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.onSurface()) return;
        const pp = self.lastPointer();
        if (self.host.motion(pp[0], pp[1])) self.refresh();
    }

    fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.onSurface()) return;
        const pp = self.lastPointer();
        if (state == 1) self.host.drop_ctrl = self.ctrlHeld();
        self.runAction(self.host.press(pp[0], pp[1], button, state == 1));
    }

    /// Whether Ctrl is currently held, read from the seat's xkb state.
    fn ctrlHeld(self: *Self) bool {
        const xkb = seat_mod.xkb;
        const seat = self.bound.seat_obj orelse return false;
        const st = seat.xkb_state orelse return false;
        return xkb.xkb_state_mod_name_is_active(st, xkb.XKB_MOD_NAME_CTRL, xkb.XKB_STATE_MODS_EFFECTIVE) == 1;
    }

    fn onAxis(ctx: *anyopaque, axis: u32, delta: f64, steps: i32) void {
        _ = axis;
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.onSurface()) return;
        const seat = self.bound.seat_obj orelse return;
        const pp = self.lastPointer();
        const over_rail = ov_pick.stripContains(&self.host.layout.strip, pp[0], pp[1]);
        if (seat.axis_source == wl.WL_POINTER_AXIS_SOURCE_FINGER) {
            // Trackpad glide: 1:1 motion onto the target, snap on lift.
            // Over the rail the fingers scroll the rail instead.
            if (over_rail) {
                if (self.host.panRail(delta)) self.refresh();
                return;
            }
            if (self.host.panFinger(delta)) {
                self.syncCapture();
                self.refresh();
            }
            return;
        }
        // Prefer the compositor's physical detent count: one wheel notch is
        // one card no matter what raw axis unit the compositor uses.
        if (over_rail) {
            const moved = if (steps != 0) self.host.wheelRailSteps(steps) else self.host.wheelRail(delta);
            if (moved) self.refresh();
            return;
        }
        const moved = if (steps != 0) self.host.wheelSteps(steps) else self.host.wheel(delta);
        if (moved) {
            // Live mode streams the on-screen cards, so a scroll that
            // brings new ones into view asks the stream for them.
            self.syncCapture();
            self.refresh();
        }
    }

    fn onAxisStop(ctx: *anyopaque, axis: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.onSurface()) return;
        if (axis != wl.WL_POINTER_AXIS_VERTICAL_SCROLL) return;
        if (self.host.axisStop(nowMs())) self.refresh();
    }

    fn onKey(ctx: *anyopaque, ev: *const seat_mod.KeyEvent) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const text = if (ev.utf8_len > 0) ev.utf8[0..@min(@as(usize, ev.utf8_len), ev.utf8.len)] else "";
        self.runAction(self.host.key(ev.sym, ev.state == 1, text));
    }

    fn onConfigure(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        logz.log("configure: {d}x{d} cards={d}", .{ w, h, self.host.cards.len });
        self.pushCards();
        self.host.configured(self.bound.shm, @intCast(w), @intCast(h));
        // Layout is known now; ask the stream for what the strip shows.
        // The pulse repaints while frames are outstanding, which keeps
        // the compositor committing so the copies complete quickly.
        self.syncCapture();
        self.armAnim();
        if (!self.conn.flush()) logz.log("overview: flush failed after configure", .{});
    }

    fn noteClosed(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        logz.log("overview: closed by the compositor", .{});
        self.dropFocusGrab();
        self.host.reset();
        loop_mod.Loop.requestStop();
    }
};

fn nowMs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 + @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

fn uiScale(dock_scale: f64, shell_ui_scale: f64) f64 {
    return clampf(dock_scale, 0.5, 2.0) * clampf(shell_ui_scale, 0.5, 2.0);
}

/// Read the pid out of the lock file and SIGTERM that process. The caller
/// has already established that the flock is held, so the pid belongs to the
/// live overview. Failures are non-fatal: a close request with no readable
/// pid just means there is nothing to signal.
fn stopLockHolder(io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32)) catch return;
    defer gpa.free(bytes);
    var end: usize = 0;
    while (end < bytes.len and bytes[end] >= '0' and bytes[end] <= '9') : (end += 1) {}
    if (end == 0) return;
    const pid = std.fmt.parseInt(i32, bytes[0..end], 10) catch return;
    if (pid <= 1 or pid == linux.getpid()) return;
    std.posix.kill(pid, .TERM) catch return;
    logz.log("overview: closed running pid={d}", .{pid});
}

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch &.{};
    const launch_mode = ov_launch.fromArgs(args);

    logz.init(io, init.environ_map.get("HOME"), "horizon-overview");
    defer logz.deinit();
    const t_boot = nowMs();
    logz.log("boot: pid={d} mode={s}", .{ linux.getpid(), @tagName(launch_mode) });

    // One overview at a time. The lock file carries the holder's pid; the
    // kernel drops the flock when the holder dies, so the pid is only ever
    // read while the lock is held.
    //
    //   toggle (default, dock/taskbar spawn): a live copy is signalled off,
    //          otherwise this process becomes the surface.
    //   open:  leave a live copy alone and exit; otherwise become it.
    //   close: signal a live copy off and exit; otherwise just exit.
    //
    // The explicit modes are what the shell IPC and Super+Tab use, so
    // `overview-open` is idempotent and `overview-close` never flashes a
    // surface on the way out.
    var ov_lock: ?std.Io.File = null;
    defer if (ov_lock) |file| file.close(io);
    if (init.environ_map.get("XDG_RUNTIME_DIR")) |rt| {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/event-horizon-overview.lock", .{rt}) catch "";
        if (path.len > 0) {
            if (std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch null) |file| {
                const lrc = std.os.linux.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
                if (std.os.linux.errno(lrc) != .SUCCESS) {
                    file.close(io);
                    if (launch_mode == .open) {
                        logz.log("overview: --open, already open", .{});
                    } else {
                        stopLockHolder(io, gpa, path);
                    }
                    return 0;
                }
                if (launch_mode == .close) {
                    file.close(io);
                    return 0;
                }
                var lbuf: [16]u8 = undefined;
                const pid_line = std.fmt.bufPrint(&lbuf, "{d}\n", .{linux.getpid()}) catch "\n";
                var wr_buf: [64]u8 = undefined;
                var wr = file.writer(io, &wr_buf);
                wr.interface.writeAll(pid_line) catch {};
                wr.interface.flush() catch {};
                ov_lock = file;
            }
        }
    }
    // No lock path at all: `--close` still has nothing to do.
    if (launch_mode == .close) return 0;

    var loaded = config.loadStacked(gpa, io, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME")) catch |e| {
        logz.err("init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer loaded.deinit();
    const cfg = &loaded.cfg;
    logz.log("overview: open phases config={d}ms", .{nowMs() - t_boot});

    // Shared icon cache, keyed to this shell's icon theme. Installing it here
    // lets `iconFor` answer from the theme-directory index (an in-memory hash
    // hit) instead of probing the filesystem per icon, and remember misses so
    // a repeated paint is O(1). A no-op if a parent already installed one.
    icon_cache.initGlobal(gpa, io);
    defer icon_cache.deinitGlobal();
    if (icon_cache.shared()) |ic| {
        ic.setTheme(if (cfg.dock.icon_theme.len > 0)
            cfg.dock.icon_theme
        else
            icon_themes.detectSystemIconTheme(io) orelse "hicolor");
    }

    // Resolving the wallpaper palette is a *load* step, not a dock one: the
    // decoder leaves `horizon_colors_ok` / `matugen_palette_ok` false, so
    // without it `chrome_colors.of(cfg)` below hands every tile and pill the
    // stock defaults. Only the palette half runs here — the template renders
    // and the compositor border IPC belong to the long-lived shell, which
    // does them on its own load; re-running them from a process spawned per
    // key press would just duplicate work already done. See
    // `palette_sync.Sync.runPalette`.
    var palette = try palette_sync.Sync.init(gpa, io);
    defer palette.deinit();
    palette.runPalette(cfg);

    var conn = conn_mod.Connection.init(gpa);
    defer conn.deinit();
    if (!conn.connect(null)) {
        logz.err("no display", .{});
        return 1;
    }
    var bound = conn_mod.Connection.Bound{};
    conn.bindAll(&bound);
    defer conn.freeBound(&bound);
    if (!conn.roundtrip()) {
        logz.err("no roundtrip", .{});
        return 1;
    }
    logz.log("overview: open phases config+connect done at {d}ms", .{nowMs() - t_boot});

    var loop = loop_mod.Loop.init(gpa) catch |e| {
        logz.err("loop failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer loop.deinit();
    loop.watchFd(conn.displayFd(), std.posix.POLL.IN, pump.displayCallback, @ptrCast(conn.display.?)) catch {
        logz.err("cannot watch display", .{});
        return 1;
    };

    var ov = Ov{
        .gpa = gpa,
        .io = io,
        .conn = &conn,
        .bound = &bound,
        .loop = &loop,
    };
    defer ov.deinit();
    ov.cfg = cfg;
    ov.xdg_config = init.environ_map.get("XDG_CONFIG_HOME");
    ov.home = init.environ_map.get("HOME");
    ov.host = ov_host.Host.init(gpa, io);
    ov.host.icons = .{ .ctx = &ov, .call = Ov.winIcon };
    ov.host.frames = .{ .ctx = &ov, .call = Ov.winFrame };
    ov.host.shots = .{ .ctx = &ov, .call = Ov.monitorShot };
    ov.host.on_frame = Ov.frameTicked;
    ov.host.frame_ctx = &ov;
    ov.startEvents();
    ov.capture = ov_capture.Capture.init(gpa);
    if (ov.capture) |*cap| {
        cap.wake_ctx = &ov;
        cap.wake = Ov.onCaptureFrame;
        if (cap.start(bound.toplevel_export, bound.shm)) {
            logz.log("overview: capture stream ready (live={d})", .{@as(u8, @intFromBool(cfg.appearance.overview_live_updates))});
        } else {
            logz.log("overview: no toplevel export manager — tiles stay tinted", .{});
        }
    }
    ov.host.colors = ov_types.themeColors(chrome_colors.of(cfg));
    ov.host.axis = if (cfg.appearance.overview_axis == 1) .horizontal else .vertical;
    ov.host.card_scale = @as(f64, @floatFromInt(cfg.appearance.overview_card_scale_pct)) / 100.0;
    ov.host.card_gap = @floatFromInt(cfg.appearance.overview_card_gap_px);
    ov.host.close_sz = @floatFromInt(cfg.appearance.overview_close_btn_size_px);
    ov.host.search_w = @floatFromInt(cfg.appearance.overview_search_width_px);
    ov.host.scroll_delay_ms = @floatFromInt(cfg.appearance.overview_scroll_delay_ms);
    // Appearance → Opacity "Launchpad": the overview's apps page is the
    // launchpad, and this process is spawned per toggle — reading boot-time
    // config is enough for the slider to land.
    ov.host.launchpad_alpha = overlay.scale(&cfg.appearance, .launchpad);
    // Appearance → Opacity "Overview": the backdrop (capture + dim) paints
    // through it, so the slider reaches the whole page's cover. Its design is
    // already opaque, so the file's 1.0 = 100% = the ordinary look.
    ov.host.overview_alpha = overlay.scale(&cfg.appearance, .overview);
    const theme: []const u8 = if (cfg.dock.icon_theme.len > 0) cfg.dock.icon_theme else "hicolor";
    ov.theme = theme;
    ov.host.setAppTheme(theme);
    ov.app_dirs = app_launch.applicationsDirs(gpa, getenvStr("XDG_DATA_HOME"), getenvStr("HOME"), getenvStr("XDG_DATA_DIRS")) catch &.{};
    ov.host.apps.app_dirs = ov.app_dirs;

    ov.reloadOverview(cfg);
    logz.log("overview: open phases snapshot done at {d}ms", .{nowMs() - t_boot});
    var nwin: usize = 0;
    if (ov.snap) |*snap| {
        for (snap.ws) |w| nwin += w.wins.len;
        logz.log("snapshot: {d} workspace(s), {d} window(s)", .{ snap.ws.len, nwin });
    } else {
        logz.log("snapshot: no backend (placeholders only)", .{});
    }
    ov.pushCards();
    if (ov.shots == null) ov.shots = ov_shots.Shots.init(gpa);
    const cache_dir: ?[]u8 = shot_cache.dirPath(gpa, ov.io, getenvStr("XDG_CACHE_HOME"), getenvStr("HOME"));
    defer if (cache_dir) |d| gpa.free(d);
    var skip_live = false;
    if (cache_dir) |dir| {
        const cached = shot_cache.loadInto(&ov.shots.?, ov.io, dir, bound.outputs.items);
        if (cached > 0) logz.log("overview: shots cached={d}", .{cached});
        var named: u32 = 0;
        for (bound.outputs.items) |o| {
            if (o.obj != null and o.name.len > 0) named += 1;
        }
        const age = shot_cache.cacheAgeMs(ov.io, dir, bound.outputs.items);
        logz.log("overview: shots cache age={d}ms outputs={d}", .{ age, named });
        // Fresh dock cache: skip the blocking live pass; later window
        // changes re-arm it through the pulse.
        if (cached == named and named > 0 and age < shot_cache.kCacheFreshMs) {
            skip_live = true;
            ov.want_shots = false;
        }
    }
    if (skip_live) {
        logz.log("overview: shots fresh from cache, live pass deferred", .{});
    } else {
        // Shoot the outputs before the surface exists: cards and rail open
        // on the real desktop behind them, never with the overlay in it.
        _ = ov.fillShots();
    }
    if (ov.shots) |*s| {
        const wppath: []const u8 = if (cfg.wallpaper_enabled) cfg.wallpaper_image else "";
        const t0 = nowMs();
        if (s.loadWallpaper(ov.io, cache_dir, wppath)) {
            logz.log("overview: wallpaper backdrop ready in {d}ms", .{nowMs() - t0});
            ov.host.wallpaper_frame = s.wallpaperFrame();
        }
    }

    var out_obj: ?*wl.wl_output = null;
    const want = std.mem.trim(u8, cfg.dock.output_name, " \t\r\n");
    if (want.len > 0 and !std.ascii.eqlIgnoreCase(want, "Auto") and !std.ascii.eqlIgnoreCase(want, "All")) {
        for (bound.outputs.items) |o| {
            if (std.ascii.eqlIgnoreCase(o.name, want)) {
                out_obj = o.obj;
                break;
            }
        }
    }
    const ui = uiScale(cfg.dock.dock_scale, cfg.dock.shell_ui_scale);
    // Pulse at the display's own rate so glides track 60/144/240Hz.
    // Falls back to 60 when the output names no refresh.
    for (bound.outputs.items) |o| {
        if (out_obj != null and o.obj != out_obj) continue;
        if (o.refresh_mhz > 0) {
            ov.pulse_hz = @intCast(@max(30, @min(480, @divTrunc(o.refresh_mhz + 500, 1000))));
            break;
        }
    }
    logz.log("overview: pulse {d}Hz", .{ov.pulse_hz});
    // High-rate panels can hold two frames while the next one paints;
    // triple-buffer so the pulse never drops into a busy pool.
    if (ov.pulse_hz > 60) ov.host.shm.count = 3;
    const wallpaper: []const u8 = if (cfg.wallpaper_enabled) cfg.wallpaper_image else "";
    if (!ov.host.openHost(bound.compositor, bound.layer_shell, out_obj, ui, wallpaper)) {
        logz.err("layer surface create failed", .{});
        return 1;
    }
    ov.host.surface.on_configure = Ov.onConfigure;
    ov.host.surface.on_closed = Ov.noteClosed;
    ov.host.surface.ctx = &ov;
    // Grab input immediately, before the first frame is configured: a game
    // under the overlay must not keep receiving motion/clicks during the
    // ~60ms open path.
    ov.takeInputFocus();

    if (bound.seat_obj) |seat| {
        seat.on_pointer_enter = Ov.onEnter;
        seat.on_pointer_leave = Ov.onLeave;
        seat.on_pointer_motion = Ov.onMotion;
        seat.on_pointer_button = Ov.onButton;
        seat.on_pointer_axis_detail = Ov.onAxis;
        seat.on_pointer_axis_stop = Ov.onAxisStop;
        seat.on_key = Ov.onKey;
        seat.cb_ctx = &ov;
    } else {
        logz.err("no seat, inert", .{});
    }

    var ticks: u32 = 0;
    const t_wait = nowMs();
    while (ticks < 100 and !ov.host.surface.configured) : (ticks += 1) {
        if (!conn.roundtrip()) break;
    }
    logz.log("overview: configured after {d} roundtrips in {d}ms", .{ ticks, nowMs() - t_wait });
    if (!ov.host.surface.configured) {
        logz.err("surface never configured", .{});
        return 1;
    }
    // The configure handler painted through `configured`, so this is
    // keystroke-to-first-photon for the whole open path.
    logz.log("overview: open in {d}ms", .{nowMs() - t_boot});
    // First paint even before configure data lands twice: onConfigure
    // already painted through `configured`.
    if (!conn.flush()) logz.log("flush failed", .{});

    loop_mod.Loop.installSignalHandlers();
    loop.run();
    return 0;
}
