//! horizon-polkit-agent — the polkit session agent as its own process.
//!
//! Port of `src/services/polkit/standalone/polkit_agent_standalone.cpp` onto
//! the Zig shell's stack: an owned Wayland connection for the auth card (layer
//! surface, namespace `event-horizon-polkit`, overlay layer, exclusive
//! keyboard grab), a system-bus connection that owns the agent registration
//! lifecycle, and the setuid helper session from `services/polkit/session.zig`
//! (no GLib, no libpolkit-agent).
//!
//! Registration and reply semantics live in `services/polkit/agent.zig`; the
//! card is drawn by `widgets/polkit_dialog_paint.zig`. This file is the glue:
//! protocol dispatch, the surface/shm lifecycle, input, and config reload.
//!
//! Lifecycle (matches the C++ pair):
//!   * connect Wayland, bind globals, wire the seat *before* registering;
//!   * connect the system bus, `Hello`, watch `NameOwnerChanged`;
//!   * `RegisterAuthenticationAgent` blocking, retried at startup and then on
//!     a self-scheduled backoff timer, so a live-but-unregistered agent can
//!     never happen (the one state that reads as "auth is broken");
//!   * `BeginAuthentication` starts a helper and defers its reply until the
//!     session ends; `CancelAuthentication` answers immediately;
//!   * polkitd restart (owner re-appearance) re-registers.

const std = @import("std");
const linux = std.os.linux;

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
const seat_mod = @import("../wl/seat.zig");
const watch_mod = @import("../config/watch.zig");
const dbus_conn = @import("../dbus/connection.zig");
const wire = @import("../dbus/wire.zig");
const polkit_agent = @import("../services/polkit/agent.zig");
const icon_lookup = @import("../desktop_shell/common/icon_lookup.zig");
const icon_raster = @import("../desktop_shell/common/icon_raster.zig");
const icon_themes = @import("../desktop_shell/common/icon_themes.zig");
const chrome_colors = @import("../desktop_shell/widgets/shared/chrome_colors.zig");
const ns = @import("../desktop_shell/common/namespaces.zig");
const dlg_paint = @import("../desktop_shell/widgets/polkit_dialog_paint.zig");

const cairo = shm_mod.cairo;
const xkb = seat_mod.xkb;

/// polkitd's well-known name and the authority object we register with.
const polkit_bus = "org.freedesktop.PolicyKit1";
const authority_path = "/org/freedesktop/PolicyKit1/Authority";
const authority_iface = "org.freedesktop.PolicyKit1.Authority";
const dbus_iface = "org.freedesktop.DBus";
const err_invalid_args = "org.freedesktop.DBus.Error.InvalidArgs";
const err_unknown_method = "org.freedesktop.DBus.Error.UnknownMethod";
const err_unknown_iface = "org.freedesktop.DBus.Error.UnknownInterface";

/// Layer-surface keyboard_interactivity value; the security prompt needs the
/// exclusive keyboard grab.
const kb_exclusive: u32 = 1;

/// Initial surface size before the first configure (the C++ used cardW × 300).
const initial_h: u32 = 300;

/// shm buffer tag, same convention as the other shell surfaces.
const shm_tag = "polkit";

/// The password buffer is wiped on submit/cancel; this only stops a stuck key
/// from growing it without bound.
const field_cap: usize = 4096;

/// Pointer button code for BTN_LEFT (Linux input-event code, not 1/2/3).
const btn_left: u32 = 0x110;

const Img = struct {
    /// Premultiplied ARGB32 bytes the cairo surface wraps; `loadSvg`/`loadPng`
    /// lay them out the way `CAIRO_FORMAT_ARGB32` reads them.
    data: []u8 = &.{},
    surf: ?*cairo.cairo_surface_t = null,
    w: i32 = 0,
    h: i32 = 0,
};

fn napMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

fn strOf(v: wire.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .object_path => |s| s,
        else => null,
    };
}

/// Error details captured from a bus error reply (fixed buffers: the reply's
/// arena dies before the caller logs).
const CallError = struct {
    name_buf: [96]u8 = @as([96]u8, @splat(0)),
    text_buf: [192]u8 = @as([192]u8, @splat(0)),
    name_len: usize = 0,
    text_len: usize = 0,

    fn set(self: *CallError, err_name: []const u8, err_text: []const u8) void {
        self.name_len = @min(err_name.len, self.name_buf.len);
        @memcpy(self.name_buf[0..self.name_len], err_name[0..self.name_len]);
        self.text_len = @min(err_text.len, self.text_buf.len);
        @memcpy(self.text_buf[0..self.text_len], err_text[0..self.text_len]);
    }

    fn name(self: *const CallError) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn text(self: *const CallError) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

const Daemon = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    xdg_config: ?[]const u8,
    home: ?[]const u8,
    lang: ?[]const u8,
    session_id: ?[]const u8,

    // Borrowed from main (single deinit each, at exit).
    conn: conn_mod.Connection,
    bound: conn_mod.Connection.Bound,
    loop: *loop_mod.Loop,

    loaded: config.Loaded,
    palette: palette_sync.Sync,
    watcher: watch_mod.Watcher = .{},

    /// Place-first init (self-referential session callbacks); never move the
    /// Daemon after `agent.init`.
    agent: polkit_agent.Agent = undefined,

    bus: dbus_conn.Conn = undefined,
    bus_live: bool = false,
    /// Set when a connection the agent cannot function without has died
    /// (Wayland display or system bus). The loop is asked to stop and main
    /// exits nonzero so the supervisor respawns a fresh agent instead of
    /// leaving a zombie that spins and never shows a dialog again.
    fatal_exit: bool = false,
    registered: bool = false,
    registering: bool = false,
    /// Registration retry timer (one-shot timerfd, armed lazily): a failed
    /// (re)registration must not leave a live-but-unregistered agent behind.
    /// Covers a late polkitd at login, polkitd restarts, and a predecessor
    /// agent whose registration polkitd has not dropped yet (`already
    /// exists` at shell handover).
    reg_retry_fd: i32 = -1,
    reg_retry_ms: u64 = 0,
    reg_retry_pending: bool = false,

    layer: layer_mod.Surface = .{},
    shm: shm_mod.ShmPair = undefined,
    visible: bool = false,
    surface_live: bool = false,
    surface_w: i32 = 0,
    surface_h: i32 = 0,
    /// Last size requested from the compositor (guards against re-requesting
    /// the same size every frame while waiting for the configure).
    last_req_w: u32 = 0,
    last_req_h: u32 = 0,

    /// Loop-watch bookkeeping. `watchFd`/`unwatch` mutate the loop's fd table,
    /// which the loop iterates while dispatching, so mutations from inside a
    /// callback (the helper stopping) are applied on the next tick instead.
    loop_running: bool = false,
    helper_fd: i32 = -1,
    helper_stop_fd: i32 = -1,
    helper_apply_queued: bool = false,
    shutting_down: bool = false,

    // Dialog state (the C++ `Impl` fields).
    field: std.ArrayList(u8) = .empty,
    shown_cookie: []u8 = &.{},
    geo: dlg_paint.Geo = .{},
    hover: dlg_paint.Hit = .none,
    press: dlg_paint.Hit = .none,

    // Icon cache for the action's themed icon.
    icons: std.StringHashMap(Img) = undefined,
    icon_dirs: [][]const u8 = &.{},
    icon_theme: []u8 = &.{},

    fn deinit(self: *Daemon) void {
        self.shutting_down = true;
        self.clearIcons();
        self.icons.deinit();
        if (self.icon_dirs.len > 0) icon_lookup.freeDirs(self.gpa, self.icon_dirs);
        if (self.icon_theme.len > 0) self.gpa.free(self.icon_theme);
        if (self.shown_cookie.len > 0) self.gpa.free(self.shown_cookie);
        self.field.deinit(self.gpa);
        if (self.helper_fd >= 0) {
            self.loop.unwatch(self.helper_fd);
            self.helper_fd = -1;
        }
        if (self.reg_retry_fd >= 0) {
            self.loop.unwatch(self.reg_retry_fd);
            _ = linux.close(self.reg_retry_fd);
            self.reg_retry_fd = -1;
        }
        self.agent.deinit();
        self.shm.deinit();
        self.layer.destroy();
        self.watcher.close();
        self.bus.deinit();
        self.palette.deinit();
        self.loaded.deinit();
    }

    fn flush(self: *Daemon) void {
        _ = self.conn.flush();
    }

    // -- config -------------------------------------------------------------

    fn applyConfig(self: *Daemon) void {
        // The C++ applied `dock.iconTheme` once, at first paint; re-resolving
        // on every config apply keeps a mid-session theme change honest, and
        // the shell's detect-when-empty fallback covers an unset option.
        const theme = self.loaded.cfg.dock.icon_theme;
        const resolved: []const u8 = if (theme.len > 0)
            theme
        else
            (icon_themes.detectSystemIconTheme(self.io) orelse "hicolor");
        if (!std.mem.eql(u8, resolved, self.icon_theme)) {
            if (self.icon_theme.len > 0) self.gpa.free(self.icon_theme);
            self.icon_theme = self.gpa.dupe(u8, resolved) catch &.{};
            self.clearIcons();
            logz.log("dlg icon: theme '{s}'", .{self.icon_theme});
        }
    }

    fn onConfigFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = fd;
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const interesting = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if ((revents & interesting) == 0) return;
        if (self.watcher.drainAnyToml()) self.reloadCfg();
    }

    fn reloadCfg(self: *Daemon) void {
        const fresh = config.loadStacked(self.gpa, self.io, self.xdg_config, self.home) catch {
            logz.log("config: reload failed, keeping live config", .{});
            return;
        };
        self.loaded.deinit();
        self.loaded = fresh;
        self.palette.run(&self.loaded.cfg);
        self.applyConfig();
        logz.log("config: reloaded", .{});
        if (self.visible) self.paint();
    }

    // -- system bus ---------------------------------------------------------

    fn connectBus(self: *Daemon, system_env: ?[]const u8) void {
        const addr = dbus_conn.addressFor(.system, null, system_env) orelse {
            logz.log("c system bus: no address", .{});
            return;
        };
        self.bus.connect(addr) catch |e| {
            logz.log("c system bus: connect failed: {s}", .{@errorName(e)});
            return;
        };
        self.bus.hello() catch |e| {
            logz.log("c system bus: Hello failed: {s}", .{@errorName(e)});
            return;
        };
        self.bus_live = true;
        // polkitd restart: the name comes back and we re-register. A match
        // rule keeps the signal flowing even while an unrelated traffic burst
        // has our socket busy.
        self.bus.addMatch(
            "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus'," ++
                "member='NameOwnerChanged',arg0='org.freedesktop.PolicyKit1'",
            5_000,
        ) catch |e| {
            logz.log("c system bus: NameOwnerChanged match failed: {s}", .{@errorName(e)});
        };
        self.loop.watchFd(self.bus.fd, std.posix.POLL.IN, Daemon.onBusFd, self) catch |e| {
            logz.log("c system bus: watch failed: {s}", .{@errorName(e)});
            self.bus_live = false;
            return;
        };
        self.initRegRetry();
        logz.log("c system bus: connected fd={d} name={s}", .{ self.bus.fd, self.bus.unique_name });
    }

    /// See `pump.displayCallback` for the dispatch dance; this wrapper adds
    /// connection-death detection. A compositor that dropped our connection
    /// leaves the socket readable (POLLHUP) forever: the loop would hot-spin
    /// on it, and because such a poll never sleeps, SIGTERM would never be
    /// delivered either — an unkillable zombie agent that answers nothing.
    /// Without Wayland there is no dialog at all, so exit for respawn.
    fn onDisplayFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const d = self.conn.display orelse return;
        pump.displayCallback(fd, revents, @ptrCast(d));
        const hangup = (revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0;
        if (hangup or wl.wl_display_get_error(d) != 0) {
            logz.err("display connection lost (revents=0x{x}); exiting for supervisor respawn", .{revents});
            self.fatal_exit = true;
            loop_mod.Loop.requestStop();
        }
    }

    fn onBusFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = fd;
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const interesting = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if ((revents & interesting) == 0) return;
        while (true) {
            const maybe = self.bus.recvNow() catch |e| {
                logz.log("c bus read failed: {s}", .{@errorName(e)});
                break;
            };
            var p = maybe orelse break;
            defer p.deinit();
            self.dispatch(p.msg, p.body_vals);
        }
        if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            // The system bus hung up (broker restart, forced teardown). Socket
            // D-Bus has no reconnect on the same fd, and without the bus the
            // agent can neither stay registered nor receive auth requests:
            // exit so the supervisor hands us a fresh connection.
            logz.err("system bus connection lost (revents=0x{x}); exiting for supervisor respawn", .{revents});
            self.fatal_exit = true;
            loop_mod.Loop.requestStop();
        }
    }

    /// Non-blocking sweep: everything already queued (stashed replies included)
    /// is dispatched now. Used after startup calls so nothing waits for poll.
    fn drainBus(self: *Daemon) void {
        while (true) {
            const maybe = self.bus.recvNow() catch return;
            var p = maybe orelse return;
            defer p.deinit();
            self.dispatch(p.msg, p.body_vals);
        }
    }

    /// Blocking call that keeps the world turning: messages that are not the
    /// reply are dispatched instead of parked (only startup and polkitd
    /// restarts use this, but a BeginAuthentication can already be in flight).
    fn callWithDispatch(self: *Daemon, msg: wire.Message, timeout_ms: i64, err: ?*CallError) ?wire.Parsed {
        const serial = self.bus.sendMessage(msg) catch |e| {
            if (err) |eo| eo.set("org.freedesktop.DBus.Error.Disconnected", @errorName(e));
            return null;
        };
        while (true) {
            var p = self.bus.recvMessage(timeout_ms) catch |e| {
                if (err) |eo| eo.set("org.freedesktop.DBus.Error.Timeout", @errorName(e));
                return null;
            };
            if (p.msg.reply_serial) |rs| {
                if (rs == serial) {
                    if (p.msg.mtype == .@"error") {
                        if (err) |eo| {
                            eo.set(
                                p.msg.err_name orelse "org.freedesktop.DBus.Error.Failed",
                                if (p.body_vals.len > 0) (strOf(p.body_vals[0]) orelse "") else "",
                            );
                        }
                        p.deinit();
                        return null;
                    }
                    return p;
                }
            }
            self.dispatch(p.msg, p.body_vals);
            p.deinit();
        }
    }

    fn dispatch(self: *Daemon, msg: wire.Message, body: []const wire.Value) void {
        switch (msg.mtype) {
            .signal => {
                self.onSignal(msg, body);
                return;
            },
            .method_call => {},
            else => return,
        }
        const path = msg.path orelse return;
        if (!std.mem.eql(u8, path, polkit_agent.agent_object_path)) return;
        const iface = msg.interface orelse "";
        if (iface.len > 0 and !std.mem.eql(u8, iface, polkit_agent.agent_interface)) {
            self.replyErr(msg, err_unknown_iface, "Unknown interface");
            return;
        }
        const member = msg.member orelse return;
        if (std.mem.eql(u8, member, "BeginAuthentication")) {
            if (!std.mem.eql(u8, msg.signature, polkit_agent.begin_in_sig)) {
                self.replyErr(msg, err_invalid_args, "BeginAuthentication expects 'sssa{ss}sa(sa{sv})'");
                return;
            }
            switch (self.agent.handleBegin(body, msg.serial, msg.sender orelse "")) {
                .accepted => {},
                .rejected => |reason| self.replyErr(msg, polkit_agent.error_failed, reason),
            }
            self.deferApplyHelperWatch();
        } else if (std.mem.eql(u8, member, "CancelAuthentication")) {
            if (!std.mem.eql(u8, msg.signature, polkit_agent.cancel_in_sig) or body.len < 1) {
                self.replyErr(msg, err_invalid_args, "CancelAuthentication expects 's'");
                return;
            }
            const cookie = strOf(body[0]) orelse "";
            switch (self.agent.handleCancel(cookie)) {
                .accepted => self.replyOk(msg, "", &.{}),
                .rejected => |reason| self.replyErr(msg, polkit_agent.error_failed, reason),
            }
            self.deferApplyHelperWatch();
        } else {
            self.replyErr(msg, err_unknown_method, "Unknown method");
        }
    }

    fn onSignal(self: *Daemon, msg: wire.Message, body: []const wire.Value) void {
        if (!std.mem.eql(u8, msg.interface orelse "", dbus_iface)) return;
        if (!std.mem.eql(u8, msg.member orelse "", "NameOwnerChanged")) return;
        if (body.len < 3) return;
        const name = strOf(body[0]) orelse return;
        if (!std.mem.eql(u8, name, polkit_bus)) return;
        const old_owner = strOf(body[1]) orelse "";
        const new_owner = strOf(body[2]) orelse "";
        logz.log("c NameOwnerChanged '{s}' -> '{s}'", .{ old_owner, new_owner });
        if (new_owner.len == 0) {
            self.registered = false;
            return;
        }
        if (!self.registered and !self.registering) {
            if (!self.attemptRegister()) self.scheduleRegisterRetry();
        }
    }

    fn replyOk(self: *Daemon, req: wire.Message, signature: []const u8, vals: []const wire.Value) void {
        const dest = req.sender orelse return;
        if (dest.len == 0) return;
        _ = self.bus.sendMessage(.{
            .mtype = .method_return,
            .reply_serial = req.serial,
            .destination = dest,
            .signature = signature,
            .body = vals,
        }) catch |e| logz.log("c reply failed: {s}", .{@errorName(e)});
    }

    fn replyErr(self: *Daemon, req: wire.Message, name: []const u8, text: []const u8) void {
        const dest = req.sender orelse return;
        if (dest.len == 0) return;
        const vals = [_]wire.Value{.{ .string = text }};
        _ = self.bus.sendMessage(.{
            .mtype = .@"error",
            .reply_serial = req.serial,
            .destination = dest,
            .err_name = name,
            .signature = "s",
            .body = &vals,
        }) catch |e| logz.log("c error reply failed: {s}", .{@errorName(e)});
    }

    /// The deferred BeginAuthentication reply, sent when the session ended
    /// (success, failure or user cancel — all answered the same way).
    fn onBeginReply(ctx: *anyopaque, serial: u32, sender: []const u8) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (sender.len == 0) return;
        _ = self.bus.sendMessage(.{
            .mtype = .method_return,
            .reply_serial = serial,
            .destination = sender,
            .signature = "",
            .body = &.{},
        }) catch |e| logz.log("c begin reply failed: {s}", .{@errorName(e)});
        logz.log("c initiate_authentication: replied serial={d}", .{serial});
    }

    // -- registration -------------------------------------------------------

    /// One-shot timerfd behind `scheduleRegisterRetry`. Created once; watchers
    /// on it are harmless while it is disarmed.
    fn initRegRetry(self: *Daemon) void {
        const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
        if (rc < 0) {
            logz.log("c register: retry timer unavailable", .{});
            return;
        }
        self.reg_retry_fd = @intCast(rc);
        self.loop.watchFd(self.reg_retry_fd, std.posix.POLL.IN, Daemon.onRegRetryFd, self) catch {
            _ = linux.close(self.reg_retry_fd);
            self.reg_retry_fd = -1;
        };
    }

    /// Arm the next registration attempt with capped exponential backoff
    /// (1 s → 8 s). Called after any failed attempt; a successful
    /// `attemptRegister` resets the ladder.
    fn scheduleRegisterRetry(self: *Daemon) void {
        if (self.shutting_down or self.reg_retry_fd < 0) return;
        self.reg_retry_ms = if (self.reg_retry_ms == 0) 1000 else @min(self.reg_retry_ms * 2, 8000);
        const ms = self.reg_retry_ms;
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{
                .sec = @intCast(@divTrunc(ms, 1000)),
                .nsec = @intCast(@mod(ms, 1000) * std.time.ns_per_ms),
            },
        };
        _ = linux.timerfd_settime(self.reg_retry_fd, .{}, &its, null);
        self.reg_retry_pending = true;
        logz.log("c register: retrying in {d}ms", .{ms});
    }

    fn onRegRetryFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const interesting = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if ((revents & interesting) == 0) return;
        var drain: [8]u8 = undefined;
        _ = linux.read(fd, &drain, drain.len);
        self.reg_retry_pending = false;
        if (self.shutting_down or self.registered) return;
        if (!self.attemptRegister()) self.scheduleRegisterRetry();
    }

    /// Session id first (logind-backed, survives pid reuse), else the
    /// unix-process fallback with the start time the kernel reports.
    fn buildSubject(self: *Daemon, alloc: std.mem.Allocator) ?wire.Value {
        if (self.session_id) |sid| {
            if (sid.len > 0) return polkit_agent.unixSessionSubject(alloc, sid) catch null;
        }
        const pid: u32 = @intCast(linux.getpid());
        const start = polkit_agent.processStartTime(self.io) orelse return null;
        return polkit_agent.unixProcessSubject(alloc, pid, start) catch null;
    }

    fn attemptRegister(self: *Daemon) bool {
        if (self.registering) return false;
        self.registering = true;
        defer self.registering = false;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const subject = self.buildSubject(a) orelse {
            logz.log("c register: no subject id available", .{});
            return false;
        };
        const args = polkit_agent.registerArgs(a, subject, polkit_agent.localeFor(self.lang), polkit_agent.agent_object_path) catch return false;
        var err = CallError{};
        var p = self.callWithDispatch(.{
            .mtype = .method_call,
            .path = authority_path,
            .interface = authority_iface,
            .member = "RegisterAuthenticationAgent",
            .destination = polkit_bus,
            .signature = polkit_agent.register_sig,
            .body = args,
        }, 10_000, &err) orelse {
            logz.log("c register: failed: {s}: {s}", .{ err.name(), err.text() });
            self.registered = false;
            return false;
        };
        p.deinit();
        self.registered = true;
        self.reg_retry_ms = 0;
        logz.log("c register: agent registered at {s}", .{polkit_agent.agent_object_path});
        return true;
    }

    fn unregister(self: *Daemon) void {
        if (!self.bus_live) {
            self.registered = false;
            return;
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const subject = self.buildSubject(a) orelse {
            self.registered = false;
            return;
        };
        const args = polkit_agent.unregisterArgs(a, subject, polkit_agent.agent_object_path) catch {
            self.registered = false;
            return;
        };
        var err = CallError{};
        var p = self.callWithDispatch(.{
            .mtype = .method_call,
            .path = authority_path,
            .interface = authority_iface,
            .member = "UnregisterAuthenticationAgent",
            .destination = polkit_bus,
            .signature = polkit_agent.unregister_sig,
            .body = args,
        }, 2_000, &err) orelse {
            logz.log("c unregister: {s}: {s}", .{ err.name(), err.text() });
            self.registered = false;
            return;
        };
        p.deinit();
        self.registered = false;
        logz.log("c unregister: done", .{});
    }

    // -- helper session watch ----------------------------------------------

    fn deferApplyHelperWatch(self: *Daemon) void {
        if (self.helper_apply_queued) return;
        if (!self.loop_running) {
            self.applyHelperWatch();
            return;
        }
        self.helper_apply_queued = true;
        self.loop.callLater(Daemon.onApplyHelperWatch, self) catch {
            self.helper_apply_queued = false;
            self.applyHelperWatch();
        };
    }

    fn onApplyHelperWatch(ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.helper_apply_queued = false;
        self.applyHelperWatch();
    }

    /// Reconcile the loop's watch table with the session's current fd. A
    /// session that stopped may already have closed its fd, so the unwatch is
    /// recorded by the `fd_stopped` hook and applied here, never mid-iteration.
    fn applyHelperWatch(self: *Daemon) void {
        if (self.helper_stop_fd >= 0) {
            self.loop.unwatch(self.helper_stop_fd);
            if (self.helper_fd == self.helper_stop_fd) self.helper_fd = -1;
            self.helper_stop_fd = -1;
        }
        if (self.shutting_down) {
            if (self.helper_fd >= 0) {
                self.loop.unwatch(self.helper_fd);
                self.helper_fd = -1;
            }
            return;
        }
        const fd = self.agent.sessionOf().pollFd();
        if (fd < 0) {
            if (self.helper_fd >= 0) {
                self.loop.unwatch(self.helper_fd);
                self.helper_fd = -1;
            }
            return;
        }
        if (fd == self.helper_fd) return;
        self.loop.watchFd(fd, std.posix.POLL.IN, Daemon.onHelperFd, self) catch |e| {
            logz.log("dlg helper: watch failed: {s}", .{@errorName(e)});
            return;
        };
        if (self.helper_fd >= 0) self.loop.unwatch(self.helper_fd);
        self.helper_fd = fd;
        logz.log("dlg helper: watching fd={d}", .{fd});
    }

    fn onHelperStopped(ctx: *anyopaque, fd: i32) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.helper_stop_fd = fd;
        self.deferApplyHelperWatch();
    }

    fn onHelperFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = fd;
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        const interesting = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        if ((revents & interesting) == 0) return;
        self.agent.sessionOf().onReadable();
        self.deferApplyHelperWatch();
    }

    // -- dialog show/hide/paint --------------------------------------------

    fn onAgentChanged(ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (self.agent.shouldShow()) self.show() else self.hide();
    }

    fn pickOutput(self: *Daemon) ?*wl.wl_output {
        for (self.bound.outputs.items) |o| {
            if (o.obj != null) return o.obj;
        }
        return null;
    }

    fn setShownCookie(self: *Daemon, cookie: []const u8) void {
        if (self.shown_cookie.len > 0) self.gpa.free(self.shown_cookie);
        self.shown_cookie = if (cookie.len == 0) &.{} else (self.gpa.dupe(u8, cookie) catch &.{});
    }

    fn wipeField(self: *Daemon) void {
        // Zero before dropping the length: the buffer may have held a password.
        @memset(self.field.allocatedSlice(), 0);
        self.field.clearRetainingCapacity();
    }

    fn onLayerConfigure(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (w > 0) self.surface_w = @intCast(w);
        if (h > 0) self.surface_h = @intCast(h);
        self.paint();
    }

    fn onLayerClosed(ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        logz.log("dlg: compositor closed the surface; recreating on next show", .{});
        self.dropSurface();
    }

    /// Tear the layer surface down completely. Attaching a null buffer and
    /// keeping the surface alive is not enough on every compositor: after the
    /// unmap the surface never re-mapped on the next buffer commit under
    /// Hyprland (it vanished from `hyprctl layers`, so no key or click could
    /// reach the dialog), while a freshly created surface always maps. The
    /// next `show` recreates, which also re-arms the EXCLUSIVE grab from a
    /// clean state instead of toggling interactivity on a mapped surface.
    fn dropSurface(self: *Daemon) void {
        self.layer.destroy();
        self.surface_live = false;
        self.surface_w = 0;
        self.surface_h = 0;
        self.last_req_w = 0;
        self.last_req_h = 0;
    }

    fn onLayerScale(ctx: *anyopaque, scale: i32) void {
        _ = scale;
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (self.visible) self.paint();
    }

    fn show(self: *Daemon) void {
        const snap = self.agent.snapshot();
        self.visible = true;
        if (!self.surface_live) {
            logz.log("dlg show: creating surface", .{});
            if (self.bound.compositor == null or self.bound.layer_shell == null) {
                logz.log("dlg show: no compositor/layer-shell", .{});
                return;
            }
            if (!self.layer.create(self.bound.compositor, self.bound.layer_shell, self.pickOutput(), .overlay, ns.polkit)) {
                logz.log("dlg show: create_layer_surface failed", .{});
                return;
            }
            self.layer.on_configure = Daemon.onLayerConfigure;
            self.layer.on_closed = Daemon.onLayerClosed;
            self.layer.on_scale = Daemon.onLayerScale;
            self.layer.ctx = self;
            // Unanchored + explicit size: the compositor centers a tight box
            // around the card (no scrim, no fullscreen blur smear).
            self.layer.setAnchor(0);
            self.layer.setExclusiveZone(0);
            self.layer.setKeyboardInteractivity(kb_exclusive);
            self.layer.setSize(@intFromFloat(dlg_paint.k_card_w), initial_h);
            self.surface_live = true;
            self.last_req_w = 0;
            self.last_req_h = 0;
            self.layer.commit();
            self.flush();
        } else {
            // Already visible (a later prompt or info line in the same
            // session): just repaint.
            logz.log("dlg show: surface already live; repainting", .{});
            self.layer.setKeyboardInteractivity(kb_exclusive);
            self.paint();
        }
        // A new request (new cookie) or a failed attempt clears the field. Any
        // other notification (identity/prompt/info arriving mid-dialog) must
        // not: the user may already be typing.
        if (!std.mem.eql(u8, snap.cookie, self.shown_cookie) or snap.phase == .failed) {
            self.setShownCookie(snap.cookie);
            self.wipeField();
        }
    }

    fn hide(self: *Daemon) void {
        logz.log("dlg hide", .{});
        self.visible = false;
        self.setShownCookie("");
        self.wipeField();
        self.hover = .none;
        self.press = .none;
        self.shm.deinit();
        self.shm = shm_mod.ShmPair.init(self.gpa);
        // Destroy instead of null-attach: a kept-alive surface that was
        // unmapped does not reliably map again (see `dropSurface`), and the
        // EXCLUSIVE keyboard grab must be dropped deterministically — if this
        // surface ever stayed mapped, the compositor must not keep routing
        // all keys here. `show` recreates it.
        self.dropSurface();
        self.flush();
    }

    fn iconEntry(self: *Daemon, name: []const u8) ?*Img {
        if (self.icons.getPtr(name)) |e| {
            if (e.data.len == 0) return null; // known miss: stop probing
            return e;
        }
        var px: ?icon_raster.Pixels = null;
        if (icon_lookup.lookupAny(self.gpa, self.io, self.icon_dirs, self.icon_theme, name, dlg_paint.k_icon_raster)) |found| {
            defer icon_lookup.freeFound(self.gpa, found);
            px = switch (found.format) {
                .svg => icon_raster.loadSvg(self.gpa, found.path, @intCast(dlg_paint.k_icon_raster)),
                .png => icon_raster.loadPng(self.gpa, found.path),
                .unknown => null,
            };
        }
        if (px == null) {
            logz.log("dlg icon: '{s}' not found in theme '{s}'", .{ name, self.icon_theme });
            const key = self.gpa.dupe(u8, name) catch return null;
            self.icons.put(key, .{}) catch self.gpa.free(key);
            return null;
        }
        const p = px.?;
        const surf = cairo.cairo_image_surface_create_for_data(p.data.ptr, cairo.CAIRO_FORMAT_ARGB32, p.w, p.h, p.w * 4);
        if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(surf);
            self.gpa.free(p.data);
            return null;
        }
        const key = self.gpa.dupe(u8, name) catch {
            cairo.cairo_surface_destroy(surf);
            self.gpa.free(p.data);
            return null;
        };
        self.icons.put(key, .{ .data = p.data, .surf = surf, .w = p.w, .h = p.h }) catch {
            cairo.cairo_surface_destroy(surf);
            self.gpa.free(p.data);
            self.gpa.free(key);
            return null;
        };
        logz.log("dlg icon: '{s}' {d}x{d}", .{ name, p.w, p.h });
        return self.icons.getPtr(name);
    }

    fn clearIcons(self: *Daemon) void {
        var it = self.icons.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.surf) |s| cairo.cairo_surface_destroy(s);
            if (e.value_ptr.data.len > 0) self.gpa.free(e.value_ptr.data);
            self.gpa.free(e.key_ptr.*);
        }
        self.icons.clearRetainingCapacity();
    }

    fn iconFor(self: *Daemon, name: []const u8) dlg_paint.Icon {
        if (name.len == 0) return .{};
        const e = self.iconEntry(name) orelse return .{};
        if (e.surf == null or e.w <= 0 or e.h <= 0) return .{};
        return .{ .surface = e.surf, .w = e.w, .h = e.h };
    }

    fn paint(self: *Daemon) void {
        if (!self.visible or !self.surface_live or !self.layer.configured) return;
        if (self.surface_w <= 0 or self.surface_h <= 0) return;
        const scale: i32 = if (self.layer.scale > 0) self.layer.scale else 1;
        if (!self.shm.ensure(self.bound.shm, shm_tag, self.surface_w * scale, self.surface_h * scale)) {
            logz.log("dlg paint: shm buffer unavailable", .{});
            return;
        }
        const buf = self.shm.acquire() orelse return;
        const cr = buf.cr orelse return;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const snap = self.agent.snapshot();
        // Note precedence: supplementary error > info > failed attempt.
        var note: []const u8 = "";
        var note_is_error = false;
        if (snap.err.len > 0) {
            note = snap.err;
            note_is_error = true;
        } else if (snap.info.len > 0) {
            note = snap.info;
        } else if (snap.phase == .failed) {
            note = "Authentication failed — try again";
            note_is_error = true;
        }
        const view = dlg_paint.View{
            .identity = polkit_agent.identitySubtitle(a, snap.identity),
            .action_id = snap.action_id,
            .message = snap.message,
            .details = snap.details,
            .note = note,
            .note_is_error = note_is_error,
            .prompt_label = snap.prompt,
            .field = self.field.items,
            .echo_on = snap.echo_on,
            .can_submit = snap.phase == .active and snap.prompt.len > 0 and
                (snap.echo_on or self.field.items.len > 0),
            .hover = self.hover,
            .press = self.press,
        };
        const ch = chrome_colors.of(&self.loaded.cfg);
        const icon = self.iconFor(snap.icon_name);

        // Device pixels: draw in logical coordinates, rasterize at scale.
        cairo.cairo_identity_matrix(cr);
        cairo.cairo_scale(cr, @floatFromInt(scale), @floatFromInt(scale));
        const geo = dlg_paint.paint(
            a,
            cr,
            @floatFromInt(self.surface_w),
            @floatFromInt(self.surface_h),
            view,
            ch,
            icon,
        );
        self.geo = geo;

        // Tighten the surface to the card; requested once per size, the
        // configure round-trip converges immediately.
        const want_w: u32 = @intFromFloat(@ceil(geo.card_w + 2.0 * dlg_paint.k_surf_pad));
        const want_h: u32 = @intFromFloat(@ceil(geo.card_h + 2.0 * dlg_paint.k_surf_pad));
        if (want_w != self.last_req_w or want_h != self.last_req_h) {
            self.last_req_w = want_w;
            self.last_req_h = want_h;
            self.layer.setSize(want_w, want_h);
        }
        self.layer.setKeyboardInteractivity(kb_exclusive);
        self.layer.setBufferScale(scale);
        self.layer.attach(buf.wlBuffer(), 0, 0);
        self.layer.damage(0, 0, self.surface_w, self.surface_h);
        buf.markBusy();
        self.layer.commit();
        self.flush();
    }

    // -- input --------------------------------------------------------------

    // The seat belongs to this process and the dialog is its only surface:
    // every pointer/key event that arrives is for the card, exactly as the
    // C++ dialog saw the shell's routed events.

    fn onMotionEv(ctx: *anyopaque, x: f64, y: f64) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.onMotion(x, y);
    }

    fn onMotion(self: *Daemon, x: f64, y: f64) void {
        if (!self.visible) return;
        const hit = self.geo.hitTest(x, y);
        if (hit != self.hover) {
            self.hover = hit;
            self.paint();
        }
    }

    fn onLeaveEv(ctx: *anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (self.hover != .none) {
            self.hover = .none;
            self.paint();
        }
    }

    fn onButtonEv(ctx: *anyopaque, button: u32, state: u32) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.onButton(button, state);
    }

    fn onButton(self: *Daemon, button: u32, state: u32) void {
        if (button != btn_left) return;
        if (!self.visible) return;
        const snap = self.agent.snapshot();
        if (!snap.has_request) return;
        const seat = self.bound.seat_obj orelse return;
        const x = seat.pointer_x;
        const y = seat.pointer_y;
        const hit = self.geo.hitTest(x, y);

        if (state == 1) { // WL_POINTER_BUTTON_STATE_PRESSED
            var btn: dlg_paint.Hit = .none;
            if (hit == .close or hit == .cancel) {
                btn = .cancel;
            } else if (hit == .auth) {
                btn = .auth;
            }
            if (btn != .none) {
                self.press = btn;
                self.paint();
            }
            return;
        }
        if (state != 0 or self.press == .none) return; // RELEASED
        const btn = self.press;
        self.press = .none;
        if (btn == .cancel and (hit == .close or hit == .cancel)) {
            logz.log("dlg click: Cancel/close", .{});
            self.agent.cancelUser();
            self.paint();
        } else if (btn == .auth and hit == .auth) {
            // An empty password is never valid for a hidden prompt: submitting
            // one burns a polkit attempt for a mis-click. Echo-on prompts
            // (visible Q&A) still submit.
            if (self.field.items.len == 0 and !snap.echo_on) {
                logz.log("dlg click: Confirm on empty field -> ignored", .{});
                self.paint();
            } else {
                logz.log("dlg click: Confirm -> submit", .{});
                self.agent.submit(self.field.items);
                self.wipeField();
                self.paint();
            }
        } else {
            self.paint();
        }
    }

    fn onKeyEv(ctx: *anyopaque, ev: *const seat_mod.KeyEvent) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.onKey(ev);
    }

    fn onKey(self: *Daemon, ev: *const seat_mod.KeyEvent) void {
        if (!self.visible) return;
        const snap = self.agent.snapshot();
        if (!snap.has_request) return;
        if (ev.state != 1) return; // presses only (repeats arrive as presses)

        const sym = ev.sym;
        if (sym == xkb_sym_escape) {
            logz.log("dlg key: Escape -> cancel", .{});
            self.agent.cancelUser();
            return;
        }
        if (sym == xkb_sym_return or sym == xkb_sym_kp_enter) {
            if (self.field.items.len == 0 and !snap.echo_on) {
                logz.log("dlg key: Return on empty field -> ignored", .{});
                return;
            }
            logz.log("dlg key: Return -> submit", .{});
            self.agent.submit(self.field.items);
            self.wipeField();
            return;
        }
        if (sym == xkb_sym_backspace) {
            if (self.field.items.len > 0) {
                // Pop one UTF-8 character: trailing continuation bytes first.
                var n = self.field.items.len - 1;
                while (n > 0 and (self.field.items[n] & 0xC0) == 0x80) n -= 1;
                self.field.shrinkRetainingCapacity(n);
                self.paint();
            }
            return;
        }
        // `xkb_state_key_get_utf8` may count a trailing NUL; never append it.
        var len = ev.utf8_len;
        if (len > 0 and ev.utf8[len - 1] == 0) len -= 1;
        if (len == 0) return;
        if (self.field.items.len + len > field_cap) return;
        self.field.appendSlice(self.gpa, ev.utf8[0..len]) catch return;
        self.paint();
    }
};

const xkb_sym_escape: u32 = xkb.XKB_KEY_Escape;
const xkb_sym_return: u32 = xkb.XKB_KEY_Return;
const xkb_sym_kp_enter: u32 = xkb.XKB_KEY_KP_Enter;
const xkb_sym_backspace: u32 = xkb.XKB_KEY_BackSpace;

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;

    logz.init(io, init.environ_map.get("HOME"), "horizon-polkit-agent-zig");
    defer logz.deinit();
    logz.log("boot: pid={d}", .{linux.getpid()});

    var loop = loop_mod.Loop.init(gpa) catch |e| {
        logz.err("loop init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer loop.deinit();
    loop_mod.Loop.installSignalHandlers();

    const xdg_config = init.environ_map.get("XDG_CONFIG_HOME");
    const home = init.environ_map.get("HOME");
    var loaded = config.loadStacked(gpa, io, xdg_config, home) catch |e| {
        logz.err("config load failed: {s}", .{@errorName(e)});
        return 1;
    };
    var palette = palette_sync.Sync.init(gpa, io) catch |e| {
        logz.err("palette init failed: {s}", .{@errorName(e)});
        loaded.deinit();
        return 1;
    };
    palette.run(&loaded.cfg);

    var conn = conn_mod.Connection.init(gpa);
    defer conn.deinit();
    if (!conn.connect(null)) {
        logz.err("WAYLAND_DISPLAY not set or compositor unavailable", .{});
        palette.deinit();
        loaded.deinit();
        return 1;
    }
    var bound: conn_mod.Connection.Bound = .{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    var ticks: u32 = 0;
    while (ticks < 30 and bound.outputs.items.len == 0) : (ticks += 1) {
        if (!conn.roundtrip()) break;
    }
    var daemon = Daemon{
        .gpa = gpa,
        .io = io,
        .xdg_config = xdg_config,
        .home = home,
        .lang = init.environ_map.get("LANG"),
        .session_id = init.environ_map.get("XDG_SESSION_ID"),
        .conn = conn,
        .bound = bound,
        .loop = &loop,
        .loaded = loaded,
        .palette = palette,
        .bus = dbus_conn.Conn.init(gpa),
        .shm = shm_mod.ShmPair.init(gpa),
    };
    // Place-first agent init: the session callbacks carry `&daemon`.
    daemon.agent.init(gpa, io);
    daemon.agent.hooks = .{
        .ctx = &daemon,
        .send_begin_reply = Daemon.onBeginReply,
        .changed = Daemon.onAgentChanged,
        .fd_stopped = Daemon.onHelperStopped,
    };
    // Display events go through the daemon so a dropped compositor connection
    // is noticed instead of hot-spinning the loop (see `onDisplayFd`).
    loop.watchFd(daemon.conn.displayFd(), std.posix.POLL.IN, Daemon.onDisplayFd, &daemon) catch {
        logz.err("cannot watch display", .{});
        palette.deinit();
        loaded.deinit();
        return 1;
    };
    daemon.icons = std.StringHashMap(Img).init(gpa);
    daemon.icon_dirs = icon_lookup.dataDirs(gpa, init.environ_map.get("XDG_DATA_HOME"), home, init.environ_map.get("XDG_DATA_DIRS")) catch &.{};
    daemon.applyConfig();

    // Seat input, wired before registering so a request that lands the instant
    // polkitd learns about us already has a dialog.
    if (daemon.bound.seat_obj) |seat| {
        seat.on_pointer_motion = Daemon.onMotionEv;
        seat.on_pointer_button = Daemon.onButtonEv;
        seat.on_pointer_leave = Daemon.onLeaveEv;
        seat.on_key = Daemon.onKeyEv;
        seat.cb_ctx = &daemon;
    }

    // Config watcher: colors and the icon theme are re-resolved on change.
    if (config.settingsDir(gpa, daemon.xdg_config, daemon.home)) |dir| {
        defer gpa.free(dir);
        var watching = daemon.watcher.watchConfigDir(dir);
        // inotify is not recursive: the `appearance` subdir needs its own
        // watch, created up front so the watch never targets a missing dir.
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

    // The system bus is the point of this process: without it there is nothing
    // to register with, so exit and let the supervisor respawn.
    daemon.connectBus(init.environ_map.get("DBUS_SYSTEM_BUS_ADDRESS"));
    if (!daemon.bus_live) {
        logz.err("system bus unavailable; exiting for supervisor respawn", .{});
        daemon.deinit();
        return 1;
    }

    // Registration: retried for the same aggregate budget as the C++
    // standalone (≈15 s — the system bus may still be bringing polkitd up).
    // If that budget runs out the agent keeps running and keeps retrying on
    // its own timer: polkitd arriving late, a polkitd restart, or a
    // predecessor agent polkitd has not dropped yet (`already exists` at
    // shell handover) all recover in place, and there is never a
    // live-but-unregistered agent answering nothing.
    var attempt: u32 = 1;
    while (!daemon.attemptRegister()) {
        if (attempt >= 7) break;
        napMs(@min(@as(u64, 250) << @intCast(attempt - 1), 8000));
        attempt += 1;
    }
    if (!daemon.registered) {
        daemon.scheduleRegisterRetry();
        if (!daemon.reg_retry_pending) {
            // Timer unavailable: fail fast so the supervisor respawns us
            // rather than sitting alive and answerless.
            logz.err("registration failed after {d} attempts; exiting for supervisor respawn", .{attempt});
            daemon.deinit();
            return 1;
        }
    }
    // Anything that arrived while we were blocked (early NameOwnerChanged,
    // even a BeginAuthentication) is dispatched now.
    daemon.drainBus();

    logz.log("running pid={d} bus={d}", .{ linux.getpid(), @intFromBool(daemon.bus_live) });
    daemon.loop_running = true;
    daemon.loop.run();
    daemon.loop_running = false;
    if (daemon.registered) daemon.unregister();
    daemon.deinit();
    if (daemon.fatal_exit) return 1; // loss already logged; supervisor respawns.
    logz.log("exit", .{});
    return 0;
}
