//! `horizon-idle` — idle listeners that lock, blank the display, suspend or
//! hibernate the machine.
//!
//! The listeners come from `ext-idle-notify-v1` (the compositor measures
//! inactivity; this process only says what to do after N seconds). Actions
//! are the same strings the settings file already uses under
//! `[idle.behavior.<name>]`:
//!
//!     command = "lock" | "suspend" | "hibernate"
//!             | "dpms:off" | "dpms:on" | "dpms:standby" | "dpms:suspend"
//!             | any shell command
//!
//! With no explicit behaviour entries, the `[power]` timeouts are used: the
//! display blanks first and the machine suspends later. Both paths lock the
//! session before they sleep.
//!
//! logind's `PrepareForSleep` signal is watched on the system bus so a
//! suspend requested from anywhere (lid, menu, `systemctl`) still gets the
//! lock screen on screen before the machine goes down.

const std = @import("std");
const linux = std.os.linux;
const eh = @import("eh");
const app = @import("app.zig");
const config = eh.config;
const session = eh.wl_session;
const dbus_conn = eh.dbus_conn;
const dbus_wire = eh.dbus_wire;
const parent_guard = eh.parent_guard;
const logz = eh.logz;
const lock_state = eh.lockscreen_state;

const kMaxBehaviors = 24;
const kLockBin = "horizon-lock";
/// How long a sleep waits for the lock screen to report itself up. logind's
/// own delay-inhibitor cap is 5s (InhibitDelayMaxUSec), so stay under it.
const kLockWaitMs: u32 = 4000;

const Kind = enum {
    lock,
    do_suspend,
    do_hibernate,
    dpms_off,
    dpms_on,
    dpms_standby,
    dpms_suspend,
    shell,
    none,
};

const Slot = struct {
    idle: *Idle,
    kind: Kind,
    resume_kind: Kind,
    command: []u8 = &.{},
    resume_command: []u8 = &.{},
    name: []u8 = &.{},
    enabled: bool = true,
    fired: bool = false,

    fn deinit(self: *Slot, alloc: std.mem.Allocator) void {
        if (self.command.len > 0) alloc.free(self.command);
        if (self.resume_command.len > 0) alloc.free(self.resume_command);
        if (self.name.len > 0) alloc.free(self.name);
        alloc.destroy(self);
    }
};

const Idle = struct {
    app: *app.App,
    service: session.IdleService,
    slots: std.ArrayList(*Slot) = .empty,
    bus: dbus_conn.Conn,
    bus_live: bool = false,
    notifier_missing_logged: bool = false,
    /// Spawned helpers are tracked by `autostart` for reaping; nothing else
    /// ticks in this daemon, so a slow timer collects them.
    reap_fd: i32 = -1,
    /// `$XDG_RUNTIME_DIR`, where `horizon-lock` publishes its state marker.
    runtime_dir: ?[]const u8 = null,
    /// The `systemd-inhibit` child that holds a logind sleep delay inhibitor
    /// while the session is unlocked. -1 when none is held.
    inhibit_pid: i32 = -1,
    /// A `PrepareForSleep(true)` is waiting for the lock screen. The ticker
    /// releases the inhibitor when the marker appears or this deadline passes.
    inhibitor_deadline: i64 = 0,
    inhibit_logged: bool = false,
    /// Backoff after a failed or unexpectedly dead inhibitor holder.
    inhibit_retry_ms: i64 = 0,

    fn init(self: *Idle) void {
        const notifier = self.app.bound.idle_notifier;
        self.service.setNotifier(notifier, self.app.bound.seat);
        if (notifier == null) {
            logz.err("idle: ext_idle_notifier_v1 missing; no idle timeouts will fire", .{});
            self.notifier_missing_logged = true;
        }
        self.rebuild();
    }

    fn deinit(self: *Idle) void {
        if (self.reap_fd >= 0) {
            self.app.loop.unwatch(self.reap_fd);
            _ = linux.close(self.reap_fd);
            self.reap_fd = -1;
        }
        self.service.reset();
        self.service.deinit();
        for (self.slots.items) |slot| slot.deinit(self.app.gpa);
        self.slots.deinit(self.app.gpa);
        if (self.bus_live) self.bus.deinit();
    }

    fn rebuild(self: *Idle) void {
        self.service.reset();
        for (self.slots.items) |slot| slot.deinit(self.app.gpa);
        self.slots.clearRetainingCapacity();

        const cfg = &self.app.loaded.cfg;
        // The listener stores a pointer into the service's list, so make the
        // capacity final before the notifications are armed.
        self.service.behaviors.ensureTotalCapacity(self.app.gpa, kMaxBehaviors) catch return;

        if (cfg.idle_behaviors.len > 0) {
            for (cfg.idle_behaviors) |b| {
                if (!b.enabled or b.timeout_sec <= 0) continue;
                self.add(b.name, @as(u32, @intCast(b.timeout_sec)), b.command, b.resume_command) catch continue;
            }
        } else {
            const power = &cfg.power;
            if (power.display_sleep and power.display_sleep_timeout_min > 0) {
                const t: u32 = @intCast(power.display_sleep_timeout_min * 60);
                self.add("display-sleep", t, "dpms:off", "dpms:on") catch {};
            }
            if (power.idle_suspend and power.idle_suspend_timeout_min > 0) {
                const t: u32 = @intCast(power.idle_suspend_timeout_min * 60);
                // Lock a few seconds early so the compositor has presented
                // the locked frame by the time suspend begins.
                const lock_at = if (t > 10) t - 5 else t;
                self.add("idle-lock", lock_at, "lock", "") catch {};
                self.add("idle-suspend", t, "suspend", "") catch {};
            }
        }
        logz.log("idle: rebuilt {d} listener(s)", .{self.slots.items.len});
    }

    fn add(
        self: *Idle,
        name: []const u8,
        timeout_sec: u32,
        command: []const u8,
        resume_command: []const u8,
    ) !void {
        if (self.slots.items.len >= kMaxBehaviors) return error.TooMany;
        const slot = try self.app.gpa.create(Slot);
        errdefer self.app.gpa.destroy(slot);
        slot.* = .{
            .idle = self,
            .kind = kindFor(name, command),
            .resume_kind = if (resume_command.len == 0) .none else kindFor(name, resume_command),
        };
        if (command.len > 0) slot.command = try self.app.gpa.dupe(u8, command);
        errdefer if (slot.command.len > 0) self.app.gpa.free(slot.command);
        if (resume_command.len > 0) slot.resume_command = try self.app.gpa.dupe(u8, resume_command);
        errdefer if (slot.resume_command.len > 0) self.app.gpa.free(slot.resume_command);
        slot.name = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(slot.name);
        try self.slots.append(self.app.gpa, slot);
        errdefer _ = self.slots.pop();

        try self.service.addBehavior(.{
            .timeout_sec = @min(timeout_sec, 30 * 24 * 3600),
            .on_idle = onIdle,
            .on_resume = onResume,
            .ctx = slot,
        });
    }

    fn fire(self: *Idle, slot: *Slot) void {
        if (!slot.enabled) return;
        slot.fired = true;
        logz.log("idle: '{s}' fired after timeout", .{slot.name});
        self.dispatch(slot.kind, slot.command);
    }

    fn noteResume(self: *Idle, slot: *Slot) void {
        if (!slot.fired) return;
        slot.fired = false;
        logz.log("idle: '{s}' resumed", .{slot.name});
        self.dispatch(slot.resume_kind, slot.resume_command);
    }

    fn dispatch(self: *Idle, kind: Kind, command: []const u8) void {
        switch (kind) {
            .none => {},
            .lock => self.runLock(),
            .do_suspend => self.runSleep(.do_suspend),
            .do_hibernate => self.runSleep(.do_hibernate),
            .dpms_off => self.runDpms(.off),
            .dpms_on => self.runDpms(.on),
            .dpms_standby => self.runDpms(.standby),
            .dpms_suspend => self.runDpms(.dpms_suspend),
            .shell => self.runShell(command),
        }
    }

    fn runLock(self: *Idle) void {
        // A locked session already has the frame on screen; spawning a second
        // client would only make the compositor refuse it.
        if (self.locked()) return;
        const path = self.toolPath(kLockBin) catch {
            logz.err("idle: cannot find {s}", .{kLockBin});
            return;
        };
        defer if (path) |p| self.app.gpa.free(p);
        const real = [_][]const u8{path orelse kLockBin};
        eh.autostart.spawnDetached(self.app.io, &real) catch |e| {
            logz.err("idle: cannot start {s}: {s}", .{ kLockBin, @errorName(e) });
        };
    }

    fn locked(self: *Idle) bool {
        return lock_state.lockedNow(self.app.io, self.app.gpa, self.runtime_dir);
    }

    /// Hold a logind/elogind sleep delay inhibitor while the session is unlocked.
    /// logind sends `PrepareForSleep(true)` and then checks for delay
    /// inhibitors *in the same call*, so an inhibitor taken from the signal
    /// handler is always too late. Holding one for as long as the desktop is
    /// visible is what buys the lock client time to present its first frame.
    ///
    /// On non-systemd systems, falls back to `elogind-inhibit` when available;
    /// if no inhibitor tool exists, sleep may race the lock (best-effort).
    fn ensureInhibitor(self: *Idle) void {
        if (self.inhibit_pid >= 0) {
            if (pidAlive(self.inhibit_pid)) return;
            self.inhibit_pid = -1;
            self.inhibit_retry_ms = nowMs() + 30_000;
            return;
        }
        if (nowMs() < self.inhibit_retry_ms) return;
        // The holder must not outlive this daemon: a stale inhibitor would
        // make every later suspend wait out logind's five second cap. The
        // watchdog exits once our pid disappears, including on SIGKILL.
        var watchdog_buf: [96]u8 = undefined;
        const watchdog = std.fmt.bufPrint(
            &watchdog_buf,
            "while kill -0 {d} 2>/dev/null; do sleep 10; done",
            .{linux.getpid()},
        ) catch "sleep infinity";

        const inhibit_bins = [_][]const u8{ "systemd-inhibit", "elogind-inhibit" };
        inline for (inhibit_bins) |bin| {
            const argv = [_][]const u8{
                bin,
                "--what=sleep",
                "--mode=delay",
                "--who=Event Horizon",
                "--why=Lock the session before sleeping",
                "/bin/sh",
                "-c",
                watchdog,
            };
            if (eh.autostart.spawnDetachedPid(self.app.io, &argv)) |pid| {
                if (pid) |p| {
                    self.inhibit_pid = p;
                    logz.log("idle: holding a sleep delay inhibitor via {s} (pid {d})", .{ bin, p });
                }
                return;
            } else |_| {}
        }

        self.inhibit_retry_ms = nowMs() + 30_000;
        if (!self.inhibit_logged) {
            self.inhibit_logged = true;
            logz.err("idle: cannot start systemd-inhibit/elogind-inhibit; sleep may race the lock", .{});
        }
    }

    fn releaseInhibitor(self: *Idle) void {
        if (self.inhibit_pid < 0) return;
        _ = linux.kill(self.inhibit_pid, linux.SIG.TERM);
        logz.log("idle: released the sleep delay inhibitor", .{});
        self.inhibit_pid = -1;
    }

    /// Reconcile the inhibitor with the lock marker. Runs once a second and
    /// after a sleep request, so the session is protected within a second of
    /// any lock/unlock.
    fn syncInhibitor(self: *Idle) void {
        if (self.locked()) {
            self.releaseInhibitor();
            return;
        }
        if (self.inhibitor_deadline != 0 and nowMs() >= self.inhibitor_deadline) {
            logz.err("idle: lock screen did not come up in time; letting the sleep proceed", .{});
            self.inhibitor_deadline = 0;
            self.releaseInhibitor();
            return;
        }
        self.ensureInhibitor();
    }

    /// Wait (bounded) for the lock client's marker. The caller holds the
    /// inhibitor, so logind is parked while this runs.
    fn waitLocked(self: *Idle) bool {
        var waited: u32 = 0;
        while (waited <= kLockWaitMs) : (waited += 50) {
            if (self.locked()) return true;
            var ts: linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
            _ = linux.nanosleep(&ts, null);
        }
        return self.locked();
    }

    const SleepOp = enum { do_suspend, do_hibernate };

    /// `CanHibernate` is "na" when there is no usable swap device (a zram
    /// swap cannot hold an image across power-off). Asking first avoids
    /// locking the session for an operation logind then refuses.
    fn canHibernate(self: *Idle) bool {
        if (!self.bus_live) return true;
        var reply = self.bus.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/login1",
            .interface = "org.freedesktop.login1.Manager",
            .member = "CanHibernate",
            .destination = "org.freedesktop.login1",
        }, 2000) catch return true;
        defer reply.deinit();
        if (reply.body_vals.len == 0) return true;
        const v = reply.body_vals[0];
        if (v != .string) return true;
        return !std.mem.eql(u8, v.string, "na") and !std.mem.eql(u8, v.string, "no");
    }

    fn runSleep(self: *Idle, op: SleepOp) void {
        if (op == .do_hibernate and !self.canHibernate()) {
            logz.err("idle: hibernate is unavailable (no swap device large enough); not locking", .{});
            return;
        }
        // A lock screen must be up before the framebuffer is saved. The
        // inhibitor bought us logind's InhibitDelayMaxUSec; the marker tells
        // us the compositor has actually presented the locked frame.
        self.runLock();
        if (self.waitLocked()) {
            logz.log("idle: lock screen is up; sleeping", .{});
        } else {
            logz.err("idle: lock screen did not report up within {d}ms; sleeping anyway", .{kLockWaitMs});
        }
        self.inhibitor_deadline = 0;
        self.releaseInhibitor();
        const cmd = switch (op) {
            .do_suspend => "suspend",
            .do_hibernate => "hibernate",
        };
        if (self.runFirst(&.{ "loginctl", cmd })) return;
        if (self.runFirst(&.{ "systemctl", cmd })) return;
        logz.err("idle: neither loginctl nor systemctl could {s}", .{cmd});
    }

    fn runDpms(self: *Idle, state: DpmsState) void {
        const verb = switch (state) {
            .off => "off",
            .on => "on",
            .standby => "standby",
            .dpms_suspend => "suspend",
        };
        const flag = switch (state) {
            .off => "--off",
            .on => "--on",
            .standby => "--standby",
            .dpms_suspend => "--suspend",
        };
        if (self.runFirst(&.{ "wlopm", flag, "*" })) return;
        if (self.runFirst(&.{ "hyprctl", "dispatch", "dpms", verb })) return;
        if (self.runFirst(&.{ "swaymsg", "output", "*", "dpms", verb })) return;
        logz.log("idle: no DPMS helper found (install wlopm)", .{});
    }

    const DpmsState = enum { off, on, standby, dpms_suspend };

    /// Spawn the first argv that exists; returns true when a child started.
    fn runFirst(self: *Idle, argv: []const []const u8) bool {
        eh.autostart.spawnDetached(self.app.io, argv) catch return false;
        logz.log("idle: ran '{s}'", .{argv[0]});
        return true;
    }

    fn runShell(self: *Idle, command: []const u8) void {
        if (command.len == 0) return;
        _ = self.runFirst(&.{ "/bin/sh", "-c", command });
    }

    /// Installed binaries are siblings. Fall back to null (PATH lookup) when
    /// the process cannot read its own executable path.
    fn toolPath(self: *Idle, name: []const u8) !?[]u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const rc = linux.readlink("/proc/self/exe", &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS) return null;
        const n: usize = @intCast(rc);
        if (n == 0) return null;
        const dir = std.fs.path.dirname(buf[0..n]) orelse return null;
        return try std.fs.path.join(self.app.gpa, &.{ dir, name });
    }

    fn installReapTimer(self: *Idle) void {
        const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
        if (rc < 0) return;
        const fd: i32 = @intCast(rc);
        // One second: fast enough to release the inhibitor the moment the lock
        // marker appears, and to collect a spawned helper promptly.
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 1, .nsec = 0 },
            .it_value = .{ .sec = 1, .nsec = 0 },
        };
        if (linux.timerfd_settime(fd, .{}, &spec, null) != 0) {
            _ = linux.close(fd);
            return;
        }
        self.app.loop.watchFd(fd, std.posix.POLL.IN, onReapTick, self) catch {
            _ = linux.close(fd);
            return;
        };
        self.reap_fd = fd;
    }

    fn onReapTick(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = revents;
        const self: *Idle = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(fd, &buf, buf.len);
        eh.autostart.reapChildren();
        self.syncInhibitor();
    }

    fn connectBus(self: *Idle) void {
        const system_env: ?[]const u8 = if (std.c.getenv("DBUS_SYSTEM_BUS_ADDRESS")) |v| std.mem.span(v) else null;
        const addr = dbus_conn.addressFor(.system, null, system_env) orelse return;
        self.bus.connect(addr) catch |e| {
            logz.log("idle: system bus connect failed: {s}", .{@errorName(e)});
            return;
        };
        self.bus.hello() catch |e| {
            logz.log("idle: system bus Hello failed: {s}", .{@errorName(e)});
            self.bus.deinit();
            return;
        };
        self.bus_live = true;
        self.bus.addMatch(
            "type='signal',sender='org.freedesktop.login1'," ++
                "interface='org.freedesktop.login1.Manager',member='PrepareForSleep'",
            3_000,
        ) catch |e| {
            logz.log("idle: PrepareForSleep match failed: {s}", .{@errorName(e)});
        };
        self.app.loop.watchFd(self.bus.fd, std.posix.POLL.IN, onBusFd, self) catch {
            logz.log("idle: cannot watch system bus", .{});
            self.bus.deinit();
            self.bus_live = false;
        };
    }

    fn onBusFd(fd: i32, revents: i16, ctx: *anyopaque) void {
        _ = fd;
        const self: *Idle = @ptrCast(@alignCast(ctx));
        if ((revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) == 0) return;
        while (true) {
            const maybe = self.bus.recvNow() catch break;
            var p = maybe orelse break;
            defer p.deinit();
            self.onBusMessage(p.msg, p.body_vals);
        }
    }

    fn onBusMessage(self: *Idle, msg: dbus_wire.Message, body: []const dbus_wire.Value) void {
        if (msg.mtype != .signal) return;
        if (!std.mem.eql(u8, msg.member orelse "", "PrepareForSleep")) return;
        if (body.len == 0 or body[0] != .boolean) return;
        if (!body[0].boolean) {
            logz.log("idle: logind resumed", .{});
            // The lock normally survives the sleep and is still up. If it is
            // gone (a compositor that drops session locks on resume, or a
            // crash), put it back before the desktop is ever visible.
            if (!self.locked()) self.runLock();
            return;
        }
        logz.log("idle: logind is preparing to sleep; locking", .{});
        self.ensureInhibitor();
        if (!self.locked()) {
            self.runLock();
            self.inhibitor_deadline = nowMs() + @as(i64, kLockWaitMs);
        }
    }

    fn onReload(ctx: *anyopaque) void {
        const self: *Idle = @ptrCast(@alignCast(ctx));
        self.rebuild();
    }
};

/// Signal 0 checks for existence and permission without delivering anything.
fn pidAlive(pid: i32) bool {
    if (pid <= 0) return false;
    const rc = linux.kill(pid, @enumFromInt(0));
    return linux.errno(rc) == .SUCCESS;
}

fn nowMs() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn kindFor(name: []const u8, command: []const u8) Kind {
    if (command.len > 0) return kindForCommand(command);
    return kindForCommand(name);
}

fn kindForCommand(s: []const u8) Kind {
    if (std.mem.eql(u8, s, "lock")) return .lock;
    if (std.mem.eql(u8, s, "suspend") or std.mem.eql(u8, s, "sleep")) return .do_suspend;
    if (std.mem.eql(u8, s, "hibernate")) return .do_hibernate;
    if (std.mem.eql(u8, s, "dpms:off")) return .dpms_off;
    if (std.mem.eql(u8, s, "dpms:on")) return .dpms_on;
    if (std.mem.eql(u8, s, "dpms:standby")) return .dpms_standby;
    if (std.mem.eql(u8, s, "dpms:suspend")) return .dpms_suspend;
    if (s.len == 0) return .none;
    return .shell;
}

fn onIdle(ctx: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(ctx));
    slot.idle.fire(slot);
}

fn onResume(ctx: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(ctx));
    slot.idle.noteResume(slot);
}

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;

    logz.init(io, init.environ_map.get("HOME"), "horizon-idle-zig");
    defer logz.deinit();
    logz.log("boot: pid={d}", .{linux.getpid()});

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch &.{};
    if (args.len >= 2) {
        const a = args[1];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "usage: horizon-idle\n" ++
                    "       reads [idle.behavior.*] and [power] from the shell config.\n",
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

    var idle = Idle{
        .app = &a,
        .service = session.IdleService.init(gpa),
        .bus = dbus_conn.Conn.init(gpa),
        .runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR"),
    };
    a.on_reload = Idle.onReload;
    a.reload_ctx = &idle;
    idle.init();
    idle.connectBus();
    idle.installReapTimer();
    // Start protecting the session immediately: a suspend can arrive before
    // the first tick.
    idle.ensureInhibitor();
    defer idle.deinit();

    if (config.componentDir(gpa, a.xdg_config, a.home, "idle")) |dir| {
        defer gpa.free(dir);
        a.startWatching(&.{dir});
    } else |_| {}

    a.run();
    return 0;
}

test "idle: command kinds" {
    const t = std.testing;
    try t.expectEqual(Kind.lock, kindForCommand("lock"));
    try t.expectEqual(Kind.do_suspend, kindForCommand("sleep"));
    try t.expectEqual(Kind.do_hibernate, kindForCommand("hibernate"));
    try t.expectEqual(Kind.dpms_off, kindForCommand("dpms:off"));
    try t.expectEqual(Kind.dpms_on, kindForCommand("dpms:on"));
    try t.expectEqual(Kind.shell, kindForCommand("notify-send hi"));
    try t.expectEqual(Kind.none, kindForCommand(""));
    try t.expectEqual(Kind.lock, kindFor("anything", "lock"));
}
