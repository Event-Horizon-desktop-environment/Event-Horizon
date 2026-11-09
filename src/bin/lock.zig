//! `horizon-lock` — an ext-session-lock-v1 lock screen.
//!
//! One lock object, one lock surface per output, and a PAM worker for the
//! password. The compositor sends `locked` only after the first locked frame
//! has been presented on every output, which is why `horizon-idle` waits for
//! that event before it suspends.
//!
//! No configuration file is required: the wallpaper comes from the normal
//! `[wallpaper]` settings so the lock screen matches the desktop, and the
//! PAM service defaults to `login` (`EH_LOCK_PAM_SERVICE` overrides it).

const std = @import("std");
const linux = std.os.linux;
const eh = @import("eh");
const app = @import("app.zig");
const wl = eh.wl_c.wl;
const shm_mod = eh.wl_shm;
const cairo = shm_mod.cairo;
const session = eh.lockscreen_session;
const wl_session = eh.wl_session;
const auth_mod = eh.lockscreen_auth;
const paint = eh.lockscreen_paint;
const lock_state = eh.lockscreen_state;
const config = eh.config;
const local_time = eh.desktop_local_time;
const decode = eh.wp_decode;
const blit = eh.wp_blit;
const parent_guard = eh.parent_guard;
const logz = eh.logz;
const Loop = eh.loop.Loop;

const kTimerMs: u32 = 1000;

const LockSurface = struct {
    owner: ?*Lock = null,
    /// The output this surface is pinned to. A hotplugged monitor needs a new
    /// surface; `reconcileSurfaces` compares this to the bound output list.
    output: ?*wl.wl_output = null,
    surface: ?*wl.wl_surface = null,
    lock_surface: ?*wl.ext_session_lock_surface_v1 = null,
    /// Two buffers, like every other surface in the shell. A single buffer
    /// makes every frame that arrives before the compositor releases the
    /// previous one a no-op — which is how the wallpaper load and each
    /// keystroke disappeared while the clock (redrawn by the timer) survived.
    shm: shm_mod.ShmPair,
    w: i32 = 0,
    h: i32 = 0,
    configured: bool = false,
    /// The buffer pool skipped a frame because the compositor still held all
    /// of it. Logged once so a stuck pool is visible in the log instead of
    /// looking like a drawing bug.
    starved: bool = false,
    /// A repaint was requested while the compositor still held every buffer.
    /// The release callback turns this into exactly one more frame instead of
    /// dropping the update.
    dirty: bool = false,
    /// The first frame that carried the wallpaper. Logged once per surface so
    /// the log answers "did the wallpaper reach the screen" directly.
    painted_wallpaper: bool = false,
    /// Buffer releases seen. A compositor that never releases is otherwise
    /// indistinguishable from a paint bug in the log.
    releases: u32 = 0,

    fn onConfigure(
        data: ?*anyopaque,
        lock_surface: ?*wl.ext_session_lock_surface_v1,
        serial: u32,
        width: u32,
        height: u32,
    ) callconv(.c) void {
        const self: *LockSurface = @ptrCast(@alignCast(data orelse return));
        if (lock_surface) |ls| wl.ext_session_lock_surface_v1_ack_configure(ls, serial);
        self.w = @intCast(width);
        self.h = @intCast(height);
        self.configured = true;
        if (self.owner) |owner| owner.repaintAfterConfigure(self);
    }

    const listener = wl.ext_session_lock_surface_v1_listener{
        .configure = onConfigure,
    };
};

const Lock = struct {
    app: *app.App,
    session_lock: wl_session.SessionLock = .{},
    state: session.Session = .{},
    surfaces: std.ArrayList(*LockSurface) = .empty,
    /// The connection's shared seat, not a private one. `wl_seat.capabilities`
    /// is sent exactly once when the seat is bound, which happens during
    /// `App.init`'s roundtrip; a Seat bound later never sees it and therefore
    /// never creates a wl_keyboard (the "cannot type" bug).
    seat: ?*eh.wl_seat.Seat = null,
    auth: auth_mod.Worker = .{},
    password: [256]u8 = @as([256]u8, @splat(0)),
    password_len: usize = 0,
    user: []u8 = &.{},
    service: []u8 = &.{},
    wallpaper: ?decode.Image = null,
    wallpaper_path: []u8 = &.{},
    /// The account photo (`[general] avatar_path`, then `~/.face`, then
    /// AccountsService), decoded once. Null falls back to the initial.
    avatar: ?*cairo.cairo_surface_t = null,
    avatar_path: []u8 = &.{},
    timer_fd: i32 = -1,
    message: [80]u8 = @as([80]u8, @splat(0)),
    message_len: usize = 0,
    exiting: bool = false,
    /// True once this client published the runtime marker in `onLocked`.
    /// A refused second client must not clear the real lock's marker on exit.
    marked: bool = false,

    fn init(self: *Lock) bool {
        self.session_lock.setManager(self.app.bound.session_lock_manager);
        self.session_lock.on_locked = onLocked;
        self.session_lock.on_finished = onFinished;
        self.session_lock.ctx = self;

        self.user = userName(self.app.gpa) orelse self.app.gpa.dupe(u8, "user") catch return false;
        const env_service = std.c.getenv("EH_LOCK_PAM_SERVICE");
        self.service = if (env_service) |v|
            self.app.gpa.dupe(u8, std.mem.span(v)) catch return false
        else
            self.app.gpa.dupe(u8, auth_mod.kDefaultService) catch return false;

        if (self.app.bound.seat_obj) |s| {
            self.seat = s;
            s.on_key = onKey;
            s.cb_ctx = self;
            logz.log("lock: keyboard seat attached", .{});
        } else {
            logz.err("lock: no wl_seat; the password field cannot be typed", .{});
        }

        // `Session` starts unlocked. Without this the state never reaches
        // `.locked`, and `onKey` would discard every keystroke.
        self.state.requestLock();
        if (!self.session_lock.lock()) {
            logz.err("lock: ext_session_lock_manager_v1 missing or lock request failed", .{});
            return false;
        }
        // The compositor sends `finished` immediately when it will not grant
        // the lock (another client already holds it). Seeing that before any
        // surface exists keeps us from committing on a refused lock.
        _ = self.app.conn.roundtrip();
        if (self.session_lock.finished_event) {
            logz.log("lock: compositor refused the lock (another lock client?)", .{});
            return false;
        }
        // Decode before the first surface frame. Waiting for a later repaint
        // meant a compositor that never handed a buffer back could only ever
        // display the plate painted by the configure callback.
        self.reloadWallpaper();
        self.reloadAvatar();
        if (!self.createSurfaces()) {
            logz.err("lock: no lock surface could be created", .{});
            self.session_lock.unlock();
            return false;
        }
        _ = self.app.conn.roundtrip();
        if (!self.session_lock.isLocked()) {
            logz.err("lock: compositor refused the lock request", .{});
            return false;
        }
        self.paintAll();

        self.timer_fd = timerFd(kTimerMs) orelse -1;
        if (self.timer_fd >= 0) {
            self.app.loop.watchFd(self.timer_fd, std.posix.POLL.IN, onTimer, self) catch {
                _ = linux.close(self.timer_fd);
                self.timer_fd = -1;
            };
        }
        if (self.timer_fd < 0) logz.err("lock: timerfd unavailable; repaints rely on input", .{});
        return true;
    }

    fn deinit(self: *Lock) void {
        self.exiting = true;
        if (self.marked) {
            lock_state.clear(self.app.io, self.app.gpa, runtimeDir());
            self.marked = false;
        }
        if (self.auth.isRunning()) _ = self.auth.finish();
        if (self.timer_fd >= 0) {
            self.app.loop.unwatch(self.timer_fd);
            _ = linux.close(self.timer_fd);
            self.timer_fd = -1;
        }
        if (self.session_lock.isLocked()) {
            // SIGTERM/INT stops the loop and lands here while the session is
            // still locked. Queueing unlock_and_destroy is not enough: the
            // protocol requires a sync before the client exits, otherwise the
            // request can be lost when the display connection closes and
            // Hyprland renders its lockdead frame instead of unlocking.
            //
            // Unlock before destroying the surfaces. Hyprland's
            // `misc:lockdead_screen_delay` is often 0, and a frame that sees
            // the surfaces gone while the lock still exists is rendered as
            // lockdead2. unlock_and_destroy keeps the lock-surface objects
            // valid, so they can still be destroyed below.
            logz.log("lock: terminating while locked; unlocking before exit", .{});
            self.session_lock.unlock();
            _ = self.app.conn.flush();
            _ = self.app.conn.roundtrip();
        }
        for (self.surfaces.items) |ls| {
            if (ls.lock_surface) |s| wl.ext_session_lock_surface_v1_destroy(s);
            if (ls.surface) |s| wl.wl_surface_destroy(s);
            ls.shm.deinit();
            self.app.gpa.destroy(ls);
        }
        self.surfaces.deinit(self.app.gpa);
        if (self.seat) |s| {
            s.on_key = null;
            s.cb_ctx = undefined;
            self.seat = null;
        }
        freeImage(self);
        if (self.wallpaper_path.len > 0) self.app.gpa.free(self.wallpaper_path);
        freeAvatar(self);
        if (self.user.len > 0) self.app.gpa.free(self.user);
        if (self.service.len > 0) self.app.gpa.free(self.service);
        @memset(&self.password, 0);
        self.password_len = 0;
    }

    fn freeImage(self: *Lock) void {
        if (self.wallpaper) |*im| im.free(self.app.gpa);
        self.wallpaper = null;
    }

    fn freeAvatar(self: *Lock) void {
        if (self.avatar) |s| cairo.cairo_surface_destroy(s);
        self.avatar = null;
        if (self.avatar_path.len > 0) self.app.gpa.free(self.avatar_path);
        self.avatar_path = &.{};
    }

    /// The account photo, in the same order the Accounts settings page uses:
    /// an explicit `[general] avatar_path`, then `~/.face`, then
    /// AccountsService. The lock keeps the image the desktop already shows.
    fn reloadAvatar(self: *Lock) void {
        var home_buf: [1024]u8 = undefined;
        var service_buf: [1024]u8 = undefined;
        const cfg = &self.app.loaded.cfg;

        const cfg_path: ?[]const u8 = if (cfg.avatar_path.len > 0) cfg.avatar_path else null;
        const home_path: ?[]const u8 = if (self.app.home) |home|
            std.fmt.bufPrint(&home_buf, "{s}/.face", .{home}) catch null
        else
            null;
        const service_path: ?[]const u8 = std.fmt.bufPrint(
            &service_buf,
            "/var/lib/AccountsService/icons/{s}",
            .{self.user},
        ) catch null;

        for ([_]?[]const u8{ cfg_path, home_path, service_path }) |maybe| {
            const path = maybe orelse continue;
            if (self.avatar != null and std.mem.eql(u8, self.avatar_path, path)) return;
            const surf = paint.loadAvatar(self.app.gpa, path) orelse continue;
            self.freeAvatar();
            self.avatar = surf;
            self.avatar_path = self.app.gpa.dupe(u8, path) catch &.{};
            logz.log("lock: avatar loaded: {s}", .{path});
            return;
        }
        // No photo on disk is a normal state, not an error: the initial keeps
        // the cluster complete.
        if (self.avatar == null) logz.log("lock: no account photo; using the initial", .{});
    }

    fn reloadWallpaper(self: *Lock) void {
        const cfg = &self.app.loaded.cfg;
        // The lock screen always shows the desktop wallpaper. `enabled` is a
        // wallpaper-component switch, not a reason to substitute artwork
        // here: `image` is the picture the desktop is configured to show.
        if (cfg.wallpaper_image.len == 0) {
            self.freeImage();
            logz.err("lock: no wallpaper image configured", .{});
            return;
        }
        if (self.wallpaper_path.len > 0 and std.mem.eql(u8, self.wallpaper_path, cfg.wallpaper_image)) return;
        const next = decode.loadRgba(self.app.gpa, cfg.wallpaper_image) orelse {
            logz.err("lock: wallpaper decode failed: {s}", .{cfg.wallpaper_image});
            return;
        };
        self.freeImage();
        self.wallpaper = next;
        if (self.wallpaper_path.len > 0) self.app.gpa.free(self.wallpaper_path);
        self.wallpaper_path = self.app.gpa.dupe(u8, cfg.wallpaper_image) catch &.{};
        logz.log("lock: wallpaper loaded {d}x{d}: {s}", .{ next.w, next.h, cfg.wallpaper_image });
    }

    fn createSurfaces(self: *Lock) bool {
        const lock_obj = self.session_lock.lock_obj orelse return false;
        const compositor = self.app.bound.compositor orelse return false;
        for (self.app.bound.outputs.items) |o| {
            const wl_out = o.obj orelse continue;
            var already = false;
            for (self.surfaces.items) |existing| {
                if (existing.output == wl_out) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            const ls = self.app.gpa.create(LockSurface) catch continue;
            ls.* = .{
                .owner = self,
                .output = wl_out,
                .shm = shm_mod.ShmPair.init(self.app.gpa),
            };
            ls.surface = wl.wl_compositor_create_surface(compositor);
            if (ls.surface == null) {
                self.app.gpa.destroy(ls);
                continue;
            }
            ls.lock_surface = wl.ext_session_lock_v1_get_lock_surface(lock_obj, ls.surface, wl_out);
            if (ls.lock_surface == null) {
                wl.wl_surface_destroy(ls.surface.?);
                self.app.gpa.destroy(ls);
                continue;
            }
            _ = wl.ext_session_lock_surface_v1_add_listener(ls.lock_surface, &LockSurface.listener, ls);
            self.surfaces.append(self.app.gpa, ls) catch {
                wl.ext_session_lock_surface_v1_destroy(ls.lock_surface.?);
                wl.wl_surface_destroy(ls.surface.?);
                self.app.gpa.destroy(ls);
                continue;
            };
        }
        return self.surfaces.items.len > 0;
    }

    fn setMessage(self: *Lock, text: []const u8) void {
        const n = @min(text.len, self.message.len);
        @memcpy(self.message[0..n], text[0..n]);
        self.message_len = n;
    }

    fn clearPassword(self: *Lock) void {
        @memset(&self.password, 0);
        self.password_len = 0;
    }

    fn appendPassword(self: *Lock, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (self.password_len + bytes.len > self.password.len) return;
        @memcpy(self.password[self.password_len..][0..bytes.len], bytes);
        self.password_len += bytes.len;
    }

    fn paintSurface(self: *Lock, ls: *LockSurface) void {
        if (!ls.configured or ls.w <= 0 or ls.h <= 0) return;
        if (!ls.shm.ensure(self.app.bound.shm, "horizon-lock", ls.w, ls.h)) return;
        ls.shm.setReleaseHook(onBufferRelease, ls);
        // The compositor may still hold every buffer for a moment; dropping
        // the frame is fine as long as the release hook schedules one more.
        const buf = ls.shm.acquire() orelse {
            ls.dirty = true;
            if (!ls.starved) {
                ls.starved = true;
                logz.err("lock: no free shm buffer yet; waiting for a release", .{});
            }
            return;
        };
        ls.starved = false;
        ls.dirty = false;
        var have_backdrop = false;
        if (self.wallpaper) |*im| {
            if (buf.data) |data| {
                const pixels: [*]u32 = @ptrCast(@alignCast(data));
                const stride_px: usize = @intCast(@divTrunc(buf.stride, 4));
                blit.blitCoverStride(pixels, stride_px, ls.w, ls.h, im.pixels, im.w, im.h, .fill);
                if (buf.cairo_surface) |surf| cairo.cairo_surface_mark_dirty(surf);
                have_backdrop = true;
            }
        }

        const cfg_time = &self.app.loaded.cfg.time;
        const now = local_time.now();
        var date_buf: [64]u8 = undefined;
        const clock_text = eh.clock_fmt.formatTime(
            self.app.gpa,
            now.hour,
            now.minute,
            now.second,
            cfg_time.use_24h,
            cfg_time.show_seconds,
        ) catch "";
        defer if (clock_text.len > 0) self.app.gpa.free(clock_text);
        const date_text = if (cfg_time.show_date)
            formatLockDate(&date_buf, now.date)
        else
            "";

        paint.paintLock(buf.cr, ls.w, ls.h, .{
            .clock = clock_text,
            .date = date_text,
            .user = self.user,
            .message = self.message[0..self.message_len],
            .password_len = self.password_len,
            .failed = self.state.failures > 0,
            .auth_pending = self.state.auth_pending,
            .have_backdrop = have_backdrop,
            .avatar = self.avatar,
        });
        if (buf.cairo_surface) |surf| _ = cairo.cairo_surface_flush(surf);
        if (ls.surface) |s| {
            wl.wl_surface_attach(s, buf.wlBuffer(), 0, 0);
            wl.wl_surface_damage_buffer(s, 0, 0, ls.w, ls.h);
            buf.markBusy();
            wl.wl_surface_commit(s);
        }
        if (have_backdrop and !ls.painted_wallpaper) {
            ls.painted_wallpaper = true;
            logz.log("lock: first frame with wallpaper ({d}x{d})", .{ ls.w, ls.h });
        }
    }

    /// One deferred frame per surface: a repaint asked for while the pool was
    /// wholly on screen is painted as soon as a buffer comes back, so the
    /// wallpaper decode and the last keystroke are never lost.
    fn onBufferRelease(ctx: *anyopaque) void {
        const ls: *LockSurface = @ptrCast(@alignCast(ctx));
        const owner = ls.owner orelse return;
        ls.releases += 1;
        if (ls.releases == 1 or ls.releases % 60 == 0) {
            logz.log("lock: buffer release #{d} (dirty={})", .{ ls.releases, ls.dirty });
        }
        if (!ls.dirty or owner.exiting) return;
        owner.paintSurface(ls);
        _ = owner.app.conn.flush();
    }

    /// A monitor plugged in while locked needs its own lock surface before
    /// the compositor shows anything on it. Cheap: usually a no-op.
    fn reconcileSurfaces(self: *Lock) void {
        if (!self.session_lock.isLocked() or self.session_lock.finished_event) return;
        const before = self.surfaces.items.len;
        _ = self.createSurfaces();
        if (self.surfaces.items.len != before) _ = self.app.conn.flush();
    }

    fn paintAll(self: *Lock) void {
        for (self.surfaces.items) |ls| self.paintSurface(ls);
        _ = self.app.conn.flush();
    }

    fn repaintAfterConfigure(self: *Lock, ls: *LockSurface) void {
        self.paintSurface(ls);
        _ = self.app.conn.flush();
    }

    fn submit(self: *Lock) void {
        if (self.state.auth_pending or self.state.state != .locked) return;
        if (!self.auth.start(self.service, self.user, self.password[0..self.password_len])) {
            self.setMessage("Authentication is unavailable");
            self.state.failures += 1;
            self.paintAll();
            return;
        }
        const fd = self.auth.fd();
        self.app.loop.watchFd(fd, std.posix.POLL.IN, onAuthFd, self) catch {
            _ = self.auth.finish();
            self.setMessage("Authentication is unavailable");
            self.paintAll();
            return;
        };
        self.state.authBegin();
        self.paintAll();
    }

    fn unlockNow(self: *Lock) void {
        if (self.exiting) return;
        self.exiting = true;
        self.clearPassword();
        self.session_lock.unlock();
        _ = self.app.conn.flush();
        _ = self.app.conn.roundtrip();
        Loop.requestStop();
    }

    fn onLocked(ctx: *anyopaque) void {
        const self: *Lock = @ptrCast(@alignCast(ctx));
        self.state.lockShown();
        // The protocol guarantees this arrives only after a locked frame has
        // been presented on every output, so it is the moment the idle daemon
        // may release its sleep delay inhibitor.
        lock_state.markLocked(self.app.io, self.app.gpa, runtimeDir());
        self.marked = true;
        logz.log("lock: compositor accepted the lock ({d} output(s))", .{self.surfaces.items.len});
        self.paintAll();
    }

    fn onFinished(ctx: *anyopaque) void {
        const self: *Lock = @ptrCast(@alignCast(ctx));
        logz.log("lock: compositor finished the lock object", .{});
        if (self.session_lock.locked_event) {
            self.unlockNow();
        } else {
            self.exiting = true;
            Loop.requestStop();
        }
    }

    fn onTimer(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = revents;
        const self: *Lock = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        self.reconcileSurfaces();
        self.paintAll();
    }

    fn onAuthFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = revents;
        const self: *Lock = @ptrCast(@alignCast(ctx));
        self.app.loop.unwatch(fd);
        const result = self.auth.finish();
        self.clearPassword();
        switch (result) {
            .ok => {
                self.state.authResult(true);
                logz.log("lock: authenticated, unlocking", .{});
                self.unlockNow();
            },
            .denied => {
                self.state.authResult(false);
                self.setMessage("Incorrect password");
                logz.log("lock: authentication failed (attempt {d})", .{self.state.failures});
                self.paintAll();
            },
            .unavailable => {
                self.state.authResult(false);
                self.setMessage("Authentication is unavailable");
                self.paintAll();
            },
        }
    }

    fn onKey(ctx: *anyopaque, ev: *const eh.wl_seat.KeyEvent) void {
        const self: *Lock = @ptrCast(@alignCast(ctx));
        if (ev.state != wl.WL_KEYBOARD_KEY_STATE_PRESSED) return;
        if (self.state.state != .locked or self.state.auth_pending) return;
        switch (ev.sym) {
            eh.wl_seat.xkb.XKB_KEY_Return, eh.wl_seat.xkb.XKB_KEY_KP_Enter => self.submit(),
            eh.wl_seat.xkb.XKB_KEY_BackSpace => {
                if (self.password_len > 0) {
                    var n = self.password_len - 1;
                    while (n > 0 and (self.password[n] & 0xC0) == 0x80) n -= 1;
                    @memset(self.password[n..self.password_len], 0);
                    self.password_len = n;
                    self.state.failures = 0;
                    self.message_len = 0;
                    self.paintAll();
                }
            },
            eh.wl_seat.xkb.XKB_KEY_Escape => {
                self.clearPassword();
                self.state.failures = 0;
                self.message_len = 0;
                self.paintAll();
            },
            else => {
                if (ev.ctrl or ev.alt or ev.meta or ev.utf8_len == 0) return;
                self.appendPassword(ev.utf8[0..ev.utf8_len]);
                self.state.failures = 0;
                self.message_len = 0;
                self.paintAll();
            },
        }
    }

    fn onReload(ctx: *anyopaque) void {
        const self: *Lock = @ptrCast(@alignCast(ctx));
        self.reloadWallpaper();
        self.reloadAvatar();
        self.paintAll();
    }
};

/// `$XDG_RUNTIME_DIR`, borrowed from the environment for the process lifetime.
fn runtimeDir() ?[]const u8 {
    const v = std.c.getenv("XDG_RUNTIME_DIR") orelse return null;
    const s = std.mem.span(v);
    return if (s.len > 0) s else null;
}

fn userName(alloc: std.mem.Allocator) ?[]u8 {
    if (std.c.getpwuid(std.c.getuid())) |pw| {
        if (pw.name) |n| {
            const s = std.mem.span(n);
            if (s.len > 0) return alloc.dupe(u8, s) catch null;
        }
    }
    if (std.c.getenv("USER")) |v| {
        const s = std.mem.span(v);
        if (s.len > 0) return alloc.dupe(u8, s) catch null;
    }
    return null;
}

/// The lock screen uses the long form macOS shows ("Monday, November 9")
/// rather than the desktop clock's compact style; the year is omitted because
/// a lock screen is about right now.
fn formatLockDate(buf: []u8, d: local_time.Date) []const u8 {
    const days = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const months = [_][]const u8{
        "January", "February", "March",     "April",   "May",      "June",
        "July",    "August",   "September", "October", "November", "December",
    };
    const wday = weekday(d);
    const day = if (wday < days.len) days[wday] else "";
    const month = if (d.month >= 1 and d.month <= 12) months[d.month - 1] else "";
    return std.fmt.bufPrint(buf, "{s}, {s} {d}", .{ day, month, d.day }) catch "";
}

fn weekday(d: local_time.Date) usize {
    const y: i64 = @intCast(d.year);
    const m: i64 = @intCast(d.month);
    const day: i64 = @intCast(d.day);
    // Zeller's congruence, adapted to a Sunday-first result.
    const yy: i64 = if (m < 3) y - 1 else y;
    const mm: i64 = if (m < 3) m + 12 else m;
    const k = @mod(yy, 100);
    const j = @divTrunc(yy, 100);
    const h = @mod(day + @divTrunc(13 * (mm + 1), 5) + k + @divTrunc(k, 4) + @divTrunc(j, 4) + 5 * j, 7);
    // h: 0=Saturday, 1=Sunday, ... 6=Friday.
    return @intCast(@mod(h + 6, 7));
}

fn timerFd(interval_ms: u32) ?i32 {
    const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
    if (rc < 0) return null;
    const fd: i32 = @intCast(rc);
    const spec = linux.itimerspec{
        .it_interval = .{ .sec = @intCast(interval_ms / 1000), .nsec = @intCast((interval_ms % 1000) * 1_000_000) },
        .it_value = .{ .sec = 1, .nsec = 0 },
    };
    if (linux.timerfd_settime(fd, .{}, &spec, null) != 0) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;

    logz.init(io, init.environ_map.get("HOME"), "horizon-lock-zig");
    defer logz.deinit();
    logz.log("boot: pid={d}", .{linux.getpid()});

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch &.{};
    if (args.len >= 2) {
        const a = args[1];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "usage: horizon-lock\n" ++
                    "       locks the current session and exits after a successful unlock.\n" ++
                    "       EH_LOCK_PAM_SERVICE selects the PAM service (default: login).\n",
                .{},
            );
            return 0;
        }
    }

    var a = app.App.init(gpa, io, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME")) catch |e| {
        logz.err("init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer a.deinit();

    var lk = Lock{ .app = &a };
    a.on_reload = Lock.onReload;
    a.reload_ctx = &lk;
    if (!lk.init()) {
        lk.deinit();
        return 1;
    }
    defer lk.deinit();

    if (config.componentDir(gpa, a.xdg_config, a.home, "wallpaper")) |dir| {
        defer gpa.free(dir);
        a.startWatching(&.{dir});
    } else |_| {}

    a.run();
    return 0;
}
