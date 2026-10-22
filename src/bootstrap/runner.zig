const std = @import("std");
const linux = std.os.linux;
const loop_mod = @import("../loop.zig");
const logz = @import("../logz.zig");
const version = @import("../version.zig");
const ipc_server = @import("../ipc_server.zig");
const ipc_client = @import("../ipc_client.zig");
const sock = @import("../sock.zig");
const supervisor_mod = @import("supervisor.zig");
const spawn_mod = @import("spawn.zig");
const config = @import("../config.zig");
const schema2 = @import("../config/schema2.zig");
const watch_mod = @import("../config/watch.zig");
const wl_conn = @import("../wl/connection.zig");
const wl_pump = @import("../wl/pump.zig");
const nightlight = @import("../wl/color/nightlight.zig");
const gkbd = @import("../services/global_keyboard.zig");
const ov_launch = @import("../desktop_shell/overview/launch.zig");
const builtin = @import("builtin");

/// `<spawn.h>` with GNU extensions so `POSIX_SPAWN_SETSID` is visible.
/// Screenshot children are spawned through `posix_spawnp` from here — an
/// argv array, never `system()` or a shell (audit F-4) — with their own
/// session, exactly like the C++ helper in control_center_pear_layout.cpp.
const spawn_c = @cImport({
    @cDefine("_GNU_SOURCE", "");
    @cInclude("spawn.h");
});

/// Supervisor run loop: keeps the component children alive, serves the
/// eh-ipc socket, and drives both off one periodic timer tick.
const tick_ns: i64 = 25_000_000; // 25ms
/// How long children get between SIGTERM and SIGKILL on the way out.
const stop_grace_ms: i64 = 1500;

var g_supervisor: ?*supervisor_mod.Supervisor = null;

/// Screenshot children spawned but not reaped yet. `posix_spawnp` children
/// are ours, so without a wait(2) a burst of PrtScr keys would pile up
/// zombies; the table is drained on every supervisor tick. Main loop
/// thread only.
var screenshot_pids: [8]std.posix.pid_t = .{0} ** 8;

/// Overview children spawned by IPC or Super+Tab, reaped like screenshots.
var overview_pids: [4]std.posix.pid_t = .{0} ** 4;

/// Two triggers for one physical Win+Tab (our evdev path plus a leftover
/// Hyprland `eh-ipc overview-toggle` bind) land milliseconds apart. The
/// overview's lock toggles, so the second would close what the first opened.
/// Collapse near-simultaneous toggles; explicit open/close are idempotent
/// and never guarded.
var last_overview_toggle_ms: i64 = 0;
const overview_toggle_guard_ms: i64 = 250;

const Shell = struct {
    sup: *supervisor_mod.Supervisor,
    ipc: *ipc_server.Service,
    gpa: std.mem.Allocator,
    io: std.Io,
    xdg_config: ?[]const u8,
    home: ?[]const u8,
    watcher: *watch_mod.Watcher,
    ticks: u64,
    /// Global keybind reader; its eventfd is watched on this loop and the
    /// actions are run here (see `onGlobalKey`), never on the reader thread.
    kbd: *gkbd.Handler,
    night: NightHost,
};

/// The supervisor's night-light seat: the one `zwlr_gamma_control_v1` client
/// of the session, on its own Wayland connection — the shape the C++ session
/// kept (`gamma_conn_` + one `GammaService`). The bars and the settings child
/// only write `[nightlight] enabled`; this is what pushes it onto the display,
/// so a toggle reaches the backlight without any of them owning gamma.
const NightHost = struct {
    conn: wl_conn.Connection,
    bound: wl_conn.Connection.Bound = .{},
    gamma: nightlight.GammaService,
    /// The display connection came up, so `deinit` owes it a teardown.
    connected: bool = false,

    fn init(gpa: std.mem.Allocator) NightHost {
        var host = NightHost{
            .conn = wl_conn.Connection.init(gpa),
            .gamma = nightlight.GammaService.init(gpa),
        };
        if (!host.conn.connect(null)) {
            logz.log("nightlight: no display connection, gamma off", .{});
            return host;
        }
        host.connected = true;
        host.conn.bindAll(&host.bound);
        if (!host.conn.roundtrip()) return host;
        const mgr = host.bound.gamma_manager orelse {
            logz.log("nightlight: compositor has no gamma control manager", .{});
            return host;
        };
        host.gamma.manager = mgr;
        for (host.bound.outputs.items) |o| host.gamma.addOutput(o.obj) catch {};
        return host;
    }

    fn deinit(self: *NightHost) void {
        if (self.connected) {
            self.conn.freeBound(&self.bound);
            self.conn.deinit();
            self.connected = false;
        }
        self.gamma.deinit();
    }

    /// Push the stored `[nightlight]` settings onto the display — the C++
    /// `apply_nightlight_config`: enable/disable only on an actual state
    /// change (an unrelated config write must not restart the warm-up), and
    /// the night temperature whenever it is on.
    fn apply(self: *NightHost, nl: schema2.NightLightSettings, now_ms: i64) void {
        if (!self.connected) return;
        if (self.gamma.enabled != nl.enabled) self.gamma.setEnabled(nl.enabled, now_ms);
        if (nl.enabled) self.gamma.setTemperature(nl.night_temperature, true, now_ms);
        _ = self.conn.flush();
    }

    /// The 25 ms supervisor tick: walk an in-flight transition (the ramp is
    /// a new frame on every step) and send it.
    fn tick(self: *NightHost, now_ms: i64) void {
        if (!self.connected or !self.gamma.in_transition) return;
        self.gamma.onTimerTick(now_ms);
        _ = self.conn.flush();
    }
};

/// Read the layered config and forward `[nightlight]` to the gamma client.
/// Shares the gates' watch and backstop cadence; a failed load keeps the
/// last state (the C++ hook returned without touching gamma the same way).
fn applyNight(sh: *Shell) void {
    if (!sh.night.connected) return;
    var loaded = config.loadDefault(sh.gpa, sh.io, sh.xdg_config, sh.home) catch return;
    defer loaded.deinit();
    sh.night.apply(loaded.cfg.night_light, supervisor_mod.nowMs());
}

/// Read the bar gates out of the layered config. A failed load fails open
/// with the schema defaults (dock on, taskbar off) — the supervisor
/// must never strand the bars because a TOML file had a typo.
fn readGates(gpa: std.mem.Allocator, io: std.Io, xdg_config: ?[]const u8, home: ?[]const u8) spawn_mod.Gates {
    var loaded = config.loadDefault(gpa, io, xdg_config, home) catch return .{};
    defer loaded.deinit();
    return .{
        .dock_show = loaded.cfg.dock.dock_show_dock,
        .taskbar_enabled = loaded.cfg.taskbar.enabled,
    };
}

pub fn run(io: std.Io, eh_ipc_socket: ?[]const u8, xdg_runtime: ?[]const u8, xdg_config: ?[]const u8, home: ?[]const u8) u8 {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var sup = supervisor_mod.Supervisor.init(gpa, io) catch |e| {
        logz.err("supervisor: init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer sup.deinit();
    g_supervisor = &sup;

    var ipc = ipc_server.Service.init(gpa);
    defer {
        ipc.deinit();
        g_supervisor = null;
    }
    startIpc(&ipc, gpa, eh_ipc_socket, xdg_runtime);
    registerHandlers(&ipc);

    var config_watcher = watch_mod.Watcher{};
    defer config_watcher.close();
    var kbd = gkbd.Handler{};
    defer kbd.deinit();
    var sh = Shell{
        .sup = &sup,
        .ipc = &ipc,
        .gpa = gpa,
        .io = io,
        .xdg_config = xdg_config,
        .home = home,
        .watcher = &config_watcher,
        .ticks = 0,
        .kbd = &kbd,
        .night = NightHost.init(gpa),
    };
    defer sh.night.deinit();

    var shell_loop = loop_mod.Loop.init(gpa) catch |e| {
        logz.err("supervisor: loop init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer shell_loop.deinit();
    loop_mod.Loop.installSignalHandlers();

    // One timer drives everything: reap + restart children, pump the IPC
    // socket. The poll loop has no other fds of its own.
    const timer_fd = makeTickTimer() orelse {
        logz.err("supervisor: cannot create tick timer", .{});
        return 1;
    };
    shell_loop.watchFd(timer_fd, std.posix.POLL.IN, onTick, @ptrCast(&sh)) catch |e| {
        logz.err("supervisor: watch tick failed: {s}", .{@errorName(e)});
        _ = linux.close(timer_fd);
        return 1;
    };

    logz.log("supervisor: watching {d} component(s)", .{supervisor_table_len});
    // Bar gates from the layered config (dock/taskbar): a bar that is
    // off in settings never spawns.
    {
        const gates = readGates(gpa, io, xdg_config, home);
        sup.applyGates(gates);
        logz.log("supervisor: gates dock={d} taskbar={d}", .{
            @as(u8, @intFromBool(spawn_mod.wanted("dock", gates))),
            @as(u8, @intFromBool(spawn_mod.wanted("taskbar", gates))),
        });
    }
    // Live reload: settings edits re-apply the gates so toggling a bar
    // on starts the child and toggling it off stops it. inotify is not
    // recursive, so the component subdirs (where the settings app actually
    // writes, e.g. `taskbar/taskbar.toml`) get their own watches; without
    // them a toggle would sit unnoticed until the next restart.
    if (config.settingsDir(gpa, xdg_config, home)) |dir| {
        defer gpa.free(dir);
        if (config_watcher.watchConfigDir(dir)) {
            for (config.kComponents) |comp| {
                if (config.componentDir(gpa, xdg_config, home, comp)) |subdir| {
                    defer gpa.free(subdir);
                    _ = config_watcher.watchExtraDir(subdir);
                } else |_| {}
            }
            shell_loop.watchFd(config_watcher.pollFd(), std.posix.POLL.IN, onConfigFd, @ptrCast(&sh)) catch {};
        }
    } else |_| {}
    // Night light: the display fd of the gamma connection carries the
    // gamma_size handshakes, and the stored config is applied once at
    // startup (a session that booted with night mode on warms up here, not
    // on the first settings write).
    if (sh.night.connected) {
        shell_loop.watchFd(sh.night.conn.displayFd(), std.posix.POLL.IN, wl_pump.displayCallback, @ptrCast(sh.night.conn.display.?)) catch |e| {
            logz.err("supervisor: watch gamma display failed: {s}", .{@errorName(e)});
        };
        applyNight(&sh);
    }
    // Global keybinds: bare Super → menu, Super+S → settings, Super+Shift+S
    // → region picker, bare PrtScr → the cursor's monitor, Alt+PrtScr → all
    // monitors. The evdev reader runs on its own thread and only stages
    // actions behind its eventfd; they are executed on this loop thread by
    // `onGlobalKey`. Without evdev access `start` logs and stays stopped, so
    // the supervisor comes up either way.
    if (kbd.start(gpa)) {
        shell_loop.watchFd(kbd.pendingFd(), std.posix.POLL.IN, onGlobalKey, @ptrCast(&sh)) catch |e| {
            logz.err("supervisor: watch global-keyboard wake failed: {s}", .{@errorName(e)});
        };
    }
    sup.startAlways();
    shell_loop.run();

    // The loop is gone: stop the reader now rather than after the child
    // shutdown below (the deferred `kbd.deinit()` is idempotent).
    kbd.deinit();
    _ = linux.close(timer_fd);
    stopChildren(&sup);
    return 0;
}

fn stopChildren(sup: *supervisor_mod.Supervisor) void {
    sup.shutdown();
    const deadline = supervisor_mod.nowMs() + stop_grace_ms;
    while (supervisor_mod.nowMs() < deadline) {
        sup.reapAll();
        if (!sup.anyRunning()) break;
        var ts: linux.timespec = .{ .sec = 0, .nsec = 20_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    if (sup.anyRunning()) {
        logz.log("supervisor: children ignored SIGTERM, killing", .{});
        sup.killAll();
        const hard = supervisor_mod.nowMs() + 500;
        while (supervisor_mod.nowMs() < hard) {
            sup.reapAll();
            if (!sup.anyRunning()) break;
            var ts: linux.timespec = .{ .sec = 0, .nsec = 20_000_000 };
            _ = linux.nanosleep(&ts, null);
        }
    }
}

fn onTick(fd: i32, revents: i16, ctx: *anyopaque) void {
    const sh: *Shell = @ptrCast(@alignCast(ctx));
    var buf: [8]u8 = undefined;
    _ = linux.read(fd, &buf, buf.len);
    _ = revents;
    sh.ticks += 1;
    // Backstop for anything inotify missed (a subdir created after the
    // watches were installed, an overflowed queue): re-read the gates every
    // ~8 s so a toggled bar always converges within seconds.
    if (sh.ticks % 320 == 0) {
        sh.sup.applyGates(readGates(sh.gpa, sh.io, sh.xdg_config, sh.home));
        applyNight(sh);
    }
    reapScreenshotChildren();
    reapOverviewChildren();
    sh.sup.tick();
    sh.night.tick(supervisor_mod.nowMs());
    if (sh.ipc.running()) sh.ipc.pumpOnce(0);
}

/// The keybind reader's eventfd fired: pull its queue and run the actions
/// here, on the loop thread. Shell-facing side effects (spawning, IPC
/// publish) never run on the evdev thread — see `gkbd.Handler.drain`.
fn onGlobalKey(fd: i32, revents: i16, ctx: *anyopaque) void {
    _ = fd;
    _ = revents;
    const sh: *Shell = @ptrCast(@alignCast(ctx));
    var actions: std.ArrayList(gkbd.Action) = .empty;
    defer actions.deinit(std.heap.page_allocator);
    sh.kbd.drain(std.heap.page_allocator, &actions);
    for (actions.items) |action| runKeyAction(sh, action);
}

/// Side effects of the keybind actions, main loop thread only.
fn runKeyAction(sh: *Shell, action: gkbd.Action) void {
    switch (action) {
        .screenshot => {
            // Super+Shift+S: the region picker with a live preview, same
            // flags the C++ pear-layout helper passed.
            const pid = spawnScreenshot(sh.gpa, &.{ "--select", "--preview" });
            if (pid > 0) {
                trackScreenshotPid(@intCast(pid));
                logz.log("global-keyboard: screenshot pid={d}", .{pid});
            } else {
                logz.err("global-keyboard: screenshot spawn failed errno={d}", .{-pid});
            }
        },
        .screenshot_screen => {
            // Bare PrtScr: the monitor under the cursor, no region picker.
            const pid = spawnScreenshot(sh.gpa, &.{"--preview"});
            if (pid > 0) {
                trackScreenshotPid(@intCast(pid));
                logz.log("global-keyboard: screen capture pid={d}", .{pid});
            } else {
                logz.err("global-keyboard: screen capture spawn failed errno={d}", .{-pid});
            }
        },
        .screenshot_all => {
            // Alt+PrtScr: every monitor stitched into one panoramic frame.
            const pid = spawnScreenshot(sh.gpa, &.{ "--all-monitors", "--preview" });
            if (pid > 0) {
                trackScreenshotPid(@intCast(pid));
                logz.log("global-keyboard: all-monitors capture pid={d}", .{pid});
            } else {
                logz.err("global-keyboard: all-monitors spawn failed errno={d}", .{-pid});
            }
        },
        .overview => {
            // Win+Tab: the same spawn path as `eh-ipc overview-toggle`,
            // so the shell owns the combo even when no Hyprland bind is
            // configured.
            const pid = requestOverview(.toggle);
            if (pid > 0) {
                logz.log("global-keyboard: overview pid={d}", .{pid});
            } else if (pid < 0) {
                logz.err("global-keyboard: overview spawn failed errno={d}", .{-pid});
            }
        },
        // Existing topic/payload pair on the eh-ipc bus — the same one the
        // C++ session publishes (unified_shell_session.cpp), so no new
        // protocol: the taskbar child toggles its launcher on the first,
        // and a running settings window toggles on the second.
        .menu => {
            logz.log("global-keyboard: menu action (publish taskbar.menu.toggle)", .{});
            sh.ipc.publish("command.request", "taskbar.menu.toggle", &[_]i32{});
        },
        .settings => {
            logz.log("global-keyboard: settings action (publish settings.toggle)", .{});
            sh.ipc.publish("command.request", "settings.toggle", &[_]i32{});
        },
    }
}

/// Longest /proc/self/exe path we handle when resolving the sibling binary
/// (the C++ helper used a 4096-byte buffer too).
const eh_exe_buf: usize = 4096;
/// bin + "--eh-screenshot" + caller args + the NULL terminator.
const screenshot_argv_cap: usize = 24;
const screenshot_flag = "--eh-screenshot";

/// Kernel marker on a /proc/self/exe readback whose file was unlinked. A
/// rebuild renames the fresh binary over the running one, so the readback
/// becomes `<path> (deleted)` — and spawning that literal path ENOENTs even
/// though the new build sits at the same path.
const deleted_marker = " (deleted)";

fn stripDeletedMarker(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, deleted_marker)) {
        return path[0 .. path.len - deleted_marker.len];
    }
    return path;
}

fn exeIsExecutable(path: [:0]const u8) bool {
    return linux.access(path, linux.X_OK) == 0;
}

/// Pick the spawn target for `<self> --eh-screenshot`: this executable's own
/// path when it still exists (build dir / uninstalled tree), else plain
/// `EventHorizon` for posix_spawnp to find on PATH (installed tree).
/// `is_executable` is injected so the decision is testable without touching
/// the real process image.
fn chooseSpawnTarget(
    buf: *[eh_exe_buf]u8,
    self_exe: []const u8,
    is_executable: *const fn ([:0]const u8) bool,
) [:0]const u8 {
    const exe = stripDeletedMarker(self_exe);
    if (exe.len > 0 and exe.len < buf.len) {
        @memcpy(buf[0..exe.len], exe);
        buf[exe.len] = 0;
        if (is_executable(buf[0..exe.len :0])) return buf[0..exe.len :0];
    }
    // Exotic fallback: unusable or vanished /proc/self/exe → PATH lookup
    // (C++ tree).
    const fallback = "EventHorizon";
    @memcpy(buf[0..fallback.len], fallback);
    buf[fallback.len] = 0;
    return buf[0..fallback.len :0];
}

/// Resolve the EventHorizon binary: the copy next to this executable when it
/// exists and is executable (build dir / uninstalled tree), else plain
/// `EventHorizon` for posix_spawnp to find on PATH (installed tree).
/// F-5: never hardcode `/usr/bin/EventHorizon` — a prefixless install must
/// keep working. Writes a NUL-terminated path into `buf`.
fn resolveEventHorizon(buf: *[eh_exe_buf]u8) [:0]const u8 {
    // This process *is* EventHorizon: main.zig routes `--eh-screenshot`, so
    // spawning ourselves runs the Zig capture mode (frozen backdrop,
    // in-memory PNG) instead of accidentally exec'ing an unrelated
    // `EventHorizon` found beside us or on PATH (F-5).
    var self: [eh_exe_buf]u8 = undefined;
    const n = linux.readlink("/proc/self/exe", &self, self.len);
    const got: isize = @bitCast(n);
    const readback: []const u8 = if (got > 0 and got < @as(isize, @intCast(self.len)))
        self[0..@intCast(got)]
    else
        "";
    return chooseSpawnTarget(buf, readback, exeIsExecutable);
}

/// Spawn `<self> --eh-screenshot <args...>` detached in its own
/// session. `posix_spawnp` with `POSIX_SPAWN_SETSID` mirrors the C++
/// `pear_spawn_screenshot_select` helper; the argv array keeps every
/// argument literal — IPC text never reaches a command line where a shell
/// could re-interpret it (F-4: the C++ path concatenated into `system()`).
/// Returns the child pid, or a negative errno.
fn spawnScreenshot(alloc: std.mem.Allocator, args: []const []const u8) i64 {
    var path_buf: [eh_exe_buf]u8 = undefined;
    const bin = resolveEventHorizon(&path_buf);
    if (args.len + 3 > screenshot_argv_cap) return -@as(i64, @intFromEnum(linux.E.@"2BIG"));

    // The caller's slices (IPC tokens) are not NUL-terminated, so each one
    // is copied; the copies live until posix_spawnp has returned, which is
    // after the child has been forked out of us.
    var argv: [screenshot_argv_cap][*c]u8 = undefined;
    // Sentinel-typed on purpose: `dupeZ` allocates n+1 bytes (the NUL) and
    // `free` counts a sentinel slice's terminator too — a plain `[]const u8`
    // frees n bytes and the safety-checked allocator abort()s the whole
    // shell on the size mismatch. That bug killed the shell right after
    // every IPC/keybind screenshot: capture worked once, then the process
    // was gone and nothing could trigger again.
    var owned: [screenshot_argv_cap][:0]const u8 = undefined;
    var owned_len: usize = 0;
    defer for (owned[0..owned_len]) |o| alloc.free(o);

    argv[0] = @constCast(bin.ptr);
    argv[1] = @constCast(screenshot_flag.ptr);
    for (args, 0..) |a, i| {
        const z = alloc.dupeZ(u8, a) catch return -@as(i64, @intFromEnum(linux.E.NOMEM));
        owned[owned_len] = z;
        owned_len += 1;
        argv[2 + i] = @constCast(z.ptr);
    }
    argv[2 + args.len] = null;

    // Tests exercise exactly this argv/dupeZ/defer-free path (the part that
    // used to abort the shell) but must not exec — the test binary running as
    // `--eh-screenshot` would re-enter the runner. Production always spawns.
    if (builtin.is_test) return 0;

    var pid: std.posix.pid_t = 0;
    var rc: c_int = 0;
    {
        var attr: spawn_c.posix_spawnattr_t = undefined;
        if (spawn_c.posix_spawnattr_init(&attr) != 0) {
            rc = @intFromEnum(linux.E.NOMEM);
        } else {
            defer _ = spawn_c.posix_spawnattr_destroy(&attr);
            if (spawn_c.posix_spawnattr_setflags(&attr, spawn_c.POSIX_SPAWN_SETSID) != 0) {
                rc = @intFromEnum(linux.E.INVAL);
            } else {
                rc = spawn_c.posix_spawnp(&pid, bin.ptr, null, &attr, &argv, std.c.environ);
                if (rc != 0) pid = 0; // posix_spawnp returns the errno, not a pid
            }
        }
    }
    if (rc != 0) return -@as(i64, rc);
    return pid;
}

/// Remember a screenshot child so it can be reaped later. Reaps whatever
/// already exited first, so the table rarely fills.
fn trackScreenshotPid(pid: std.posix.pid_t) void {
    reapScreenshotChildren();
    for (&screenshot_pids) |*slot| {
        if (slot.* == 0) {
            slot.* = pid;
            return;
        }
    }
    logz.err("global-keyboard: {d} screenshot children already unreaped, dropping pid {d} tracking", .{ screenshot_pids.len, pid });
}

/// Non-blocking reap of the screenshot children (WNOHANG; a pid that is
/// already gone also clears its slot). Cheap early-out: no syscall unless
/// something is actually outstanding.
fn reapScreenshotChildren() void {
    for (screenshot_pids) |p| {
        if (p != 0) break;
    } else return;
    for (&screenshot_pids) |*slot| {
        if (slot.* == 0) continue;
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.wait4(slot.*, &status, linux.W.NOHANG, null));
        if (rc == slot.* or rc < 0) slot.* = 0; // reaped, or not ours anymore
    }
}

/// Resolve the standalone overview beside this executable. The installed
/// tree puts both binaries in `/usr/bin`; the build tree puts both in
/// `zig-out/bin`, so the sibling always matches the supervisor that spawned
/// it. A PATH fallback covers an exotic `/proc/self/exe` failure.
fn chooseOverviewTarget(buf: *[eh_exe_buf]u8, self_exe: []const u8) [:0]const u8 {
    const exe = stripDeletedMarker(self_exe);
    if (exe.len > 0) {
        if (std.fs.path.dirname(exe)) |dir| {
            return std.fmt.bufPrintZ(buf, "{s}/horizon-overview", .{dir}) catch "horizon-overview";
        }
    }
    return "horizon-overview";
}

/// Ask the standalone overview for `mode`. Returns its pid, 0 when the
/// duplicate-toggle guard swallowed the request (or under test), or a
/// negative errno. Main loop thread only — the guard timestamp is plain
/// state, and every caller runs there.
fn requestOverview(mode: ov_launch.Mode) i64 {
    if (mode == .toggle and !builtin.is_test) {
        const now = supervisor_mod.nowMs();
        if (last_overview_toggle_ms != 0 and now - last_overview_toggle_ms < overview_toggle_guard_ms) {
            logz.log("overview: duplicate toggle within {d}ms ignored", .{overview_toggle_guard_ms});
            return 0;
        }
        const pid = spawnOverview(mode);
        if (pid > 0) {
            last_overview_toggle_ms = now;
            trackOverviewPid(@intCast(pid));
        }
        return pid;
    }
    const pid = spawnOverview(mode);
    if (pid > 0) trackOverviewPid(@intCast(pid));
    return pid;
}

/// Spawn `horizon-overview --<mode>` detached in its own session.
/// `posix_spawnp` with an argv array: no shell, and the mode is a literal
/// flag chosen here, never IPC text.
fn spawnOverview(mode: ov_launch.Mode) i64 {
    var self_buf: [eh_exe_buf]u8 = undefined;
    const self = resolveEventHorizon(&self_buf);
    var ov_buf: [eh_exe_buf]u8 = undefined;
    const bin = chooseOverviewTarget(&ov_buf, self);
    const mode_flag = ov_launch.flag(mode);

    var argv: [3][*c]u8 = undefined;
    argv[0] = @constCast(bin.ptr);
    argv[1] = @constCast(mode_flag.ptr);
    argv[2] = null;

    // Tests exercise the target/flag construction but must not exec a real
    // overview surface.
    if (builtin.is_test) return 0;

    var pid: std.posix.pid_t = 0;
    var rc: c_int = 0;
    {
        var attr: spawn_c.posix_spawnattr_t = undefined;
        if (spawn_c.posix_spawnattr_init(&attr) != 0) {
            rc = @intFromEnum(linux.E.NOMEM);
        } else {
            defer _ = spawn_c.posix_spawnattr_destroy(&attr);
            if (spawn_c.posix_spawnattr_setflags(&attr, spawn_c.POSIX_SPAWN_SETSID) != 0) {
                rc = @intFromEnum(linux.E.INVAL);
            } else {
                rc = spawn_c.posix_spawnp(&pid, bin.ptr, null, &attr, &argv, std.c.environ);
                if (rc != 0) pid = 0; // posix_spawnp returns the errno, not a pid
            }
        }
    }
    if (rc != 0) return -@as(i64, rc);
    return pid;
}

/// Remember an overview child so it can be reaped later. Reaps whatever
/// already exited first, so the table rarely fills.
fn trackOverviewPid(pid: std.posix.pid_t) void {
    reapOverviewChildren();
    for (&overview_pids) |*slot| {
        if (slot.* == 0) {
            slot.* = pid;
            return;
        }
    }
    logz.err("overview: {d} children already unreaped, dropping pid {d} tracking", .{ overview_pids.len, pid });
}

/// Non-blocking reap of the overview children (WNOHANG; a pid that is
/// already gone also clears its slot).
fn reapOverviewChildren() void {
    for (overview_pids) |p| {
        if (p != 0) break;
    } else return;
    for (&overview_pids) |*slot| {
        if (slot.* == 0) continue;
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.wait4(slot.*, &status, linux.W.NOHANG, null));
        if (rc == slot.* or rc < 0) slot.* = 0; // reaped, or not ours anymore
    }
}

/// Settings-dir change: reload the layered config and re-apply the bar
/// gates. A newly-enabled bar spawns on the next tick; a newly-disabled
/// one is SIGTERMed here. The same pass carries nightlight edits to the
/// gamma client, so a drawer toggle or a settings pick warms (or cools)
/// the display.
fn onConfigFd(fd: i32, revents: i16, ctx: *anyopaque) void {
    _ = revents;
    const sh: *Shell = @ptrCast(@alignCast(ctx));
    if (fd != sh.watcher.pollFd()) return;
    if (!sh.watcher.drainAnyToml()) return;
    const gates = readGates(sh.gpa, sh.io, sh.xdg_config, sh.home);
    sh.sup.applyGates(gates);
    applyNight(sh);
    logz.log("supervisor: gates re-applied dock={d} taskbar={d}", .{
        @as(u8, @intFromBool(spawn_mod.wanted("dock", gates))),
        @as(u8, @intFromBool(spawn_mod.wanted("taskbar", gates))),
    });
}

fn makeTickTimer() ?i32 {
    const rc: isize = @bitCast(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
    if (rc < 0) return null;
    const fd: i32 = @intCast(rc);
    const spec = linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = tick_ns },
        .it_value = .{ .sec = 0, .nsec = tick_ns },
    };
    if (linux.timerfd_settime(fd, .{}, &spec, null) != 0) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// Bind the eh-ipc socket — unless something is already listening on it, in
/// which case that process owns the endpoint and we stay out of its way.
fn startIpc(
    svc: *ipc_server.Service,
    gpa: std.mem.Allocator,
    eh_ipc_socket: ?[]const u8,
    xdg_runtime: ?[]const u8,
) void {
    const path = ipc_client.socketPathFor(gpa, eh_ipc_socket, xdg_runtime) catch |e| {
        logz.err("ipc: cannot resolve socket path: {s}", .{@errorName(e)});
        return;
    };
    defer gpa.free(path);

    if (someoneIsListening(path)) {
        logz.log("ipc: {s} already served elsewhere, leaving it alone", .{path});
        return;
    }
    svc.start(path) catch |e| {
        logz.err("ipc: listen on {s} failed: {s}", .{ path, @errorName(e) });
        return;
    };
    logz.log("ipc: listening on {s}", .{svc.socket_path});
}

fn someoneIsListening(path: []const u8) bool {
    const fd = sock.createStream(true) catch return false;
    defer sock.closeFd(fd);
    return sock.connectPath(fd, path) == null;
}

const supervisor_table_len = spawn_mod.table.len;

fn registerHandlers(svc: *ipc_server.Service) void {
    svc.registerHandler("ping", pingHandler) catch {};
    svc.registerHandler("version", versionHandler) catch {};
    svc.registerHandler("status", statusHandler) catch {};
    svc.registerHandler("help", helpHandler) catch {};
    svc.registerHandler("screenshot", screenshotHandler) catch {};
    svc.registerHandler("overview", overviewHandler) catch {};
    svc.registerHandler("overview-toggle", overviewToggleHandler) catch {};
    svc.registerHandler("overview-open", overviewOpenHandler) catch {};
    svc.registerHandler("overview-close", overviewCloseHandler) catch {};
}

fn pingHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    _ = args;
    return alloc.dupe(u8, "pong");
}

fn versionHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    _ = args;
    return alloc.dupe(u8, version.string);
}

fn helpHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    _ = args;
    return alloc.dupe(u8, "ok ping version status help screenshot overview overview-toggle overview-open overview-close");
}

/// `screenshot [args...]` → `EventHorizon --eh-screenshot <args...>`.
/// Same job as the C++ unified_shell_session handler, minus its audit
/// findings: no `system()` and no string concatenation, so an argument can
/// never be re-interpreted as shell syntax (F-4), and the binary is this
/// executable itself — PATH `EventHorizon` only as a fallback, never a
/// hardcoded `/usr/bin` (F-5). Spawn returns
/// immediately — the capture UI runs in its own session — so a successful
/// posix_spawnp answers `"ok"` right away, like the C++ thread-pool path.
fn screenshotHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    const r = spawnScreenshot(alloc, args);
    if (r > 0) {
        trackScreenshotPid(@intCast(r));
        return alloc.dupe(u8, "ok");
    }
    logz.err("ipc: screenshot spawn failed errno={d}", .{-r});
    return std.fmt.allocPrint(alloc, "error screenshot spawn failed errno={d}", .{-r});
}

/// `overview [toggle|open|close]` plus the C++ shell's hyphenated aliases
/// (`overview-toggle`, `overview-open`, `overview-close`). The standalone
/// `horizon-overview` next to this executable owns the singleton lock, so
/// this only has to spawn the requested mode and return immediately — the
/// surface builds in the child, exactly like the screenshot handlers.
fn overviewHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    if (args.len > 1) return alloc.dupe(u8, "error usage: overview [toggle|open|close]");
    const mode: ov_launch.Mode = if (args.len == 0)
        .toggle
    else
        ov_launch.fromWord(args[0]) orelse
            return alloc.dupe(u8, "error usage: overview [toggle|open|close]");
    return launchOverview(alloc, mode);
}

fn overviewToggleHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    _ = args;
    return launchOverview(alloc, .toggle);
}

fn overviewOpenHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    _ = args;
    return launchOverview(alloc, .open);
}

fn overviewCloseHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    _ = args;
    return launchOverview(alloc, .close);
}

fn launchOverview(alloc: std.mem.Allocator, mode: ov_launch.Mode) anyerror![]u8 {
    const pid = requestOverview(mode);
    if (pid > 0) {
        logz.log("ipc: overview {s} pid={d}", .{ @tagName(mode), pid });
        return alloc.dupe(u8, "ok");
    }
    if (pid == 0) return alloc.dupe(u8, "ok"); // test mode or duplicate guard
    logz.err("ipc: overview {s} spawn failed errno={d}", .{ @tagName(mode), -pid });
    return std.fmt.allocPrint(alloc, "error overview spawn failed errno={d}", .{-pid});
}

fn statusHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    _ = args;
    const sup = g_supervisor orelse return alloc.dupe(u8, "error supervisor not running");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (spawn_mod.table, 0..) |c, i| {
        if (i > 0) try out.appendSlice(alloc, " ");
        try out.appendSlice(alloc, c.argv0);
        try out.appendSlice(alloc, "=");
        if (sup.suppressed[i]) {
            try out.appendSlice(alloc, "disabled");
        } else try out.appendSlice(alloc, switch (sup.states[i]) {
            .running => "running",
            .idle => "idle",
            .cooling => "restarting",
            .missing => "not-installed",
            .external => "external",
        });
    }
    return out.toOwnedSlice(alloc);
}

test "supervisor-run: tick timer shape" {
    const t = std.testing;
    try t.expect(tick_ns > 0);
    try t.expect(supervisor_table_len > 0);
    if (makeTickTimer()) |fd| {
        defer _ = linux.close(fd);
        try t.expect(fd >= 0);
    }
}

test "supervisor-run: screenshot spawn resolves our own exe, never hardcoded" {
    const t = std.testing;
    var buf: [eh_exe_buf]u8 = undefined;
    const bin = resolveEventHorizon(&buf);
    // Usable C string, and never a hardcoded /usr/bin/... (F-5).
    try t.expect(bin.ptr[bin.len] == 0);
    try t.expect(std.mem.indexOf(u8, bin, "/usr/bin/") == null);
    // Prefers /proc/self/exe — whatever this binary is called — with a bare
    // `EventHorizon` PATH name only when the /proc lookup is unavailable
    // (or the path it names is gone).
    var self: [eh_exe_buf]u8 = undefined;
    const got: isize = @bitCast(linux.readlink("/proc/self/exe", &self, self.len));
    if (got > 0 and got < @as(isize, @intCast(self.len))) {
        const want = stripDeletedMarker(self[0..@intCast(got)]);
        try t.expect(std.mem.eql(u8, bin, want) or std.mem.eql(u8, bin, "EventHorizon"));
    } else {
        try t.expectEqualStrings("EventHorizon", bin);
    }
    // The kernel's deleted-file marker must never reach posix_spawnp — that
    // was the "screenshot fires only until the next rebuild" bug.
    try t.expect(std.mem.indexOf(u8, bin, deleted_marker) == null);
    if (std.mem.indexOfScalar(u8, bin, '/')) |_| {
        try t.expect(linux.access(bin, linux.X_OK) == 0);
    }
}

test "supervisor-run: spawn target survives a rebuild (deleted-exe marker)" {
    const t = std.testing;
    const always = struct {
        fn f(_: [:0]const u8) bool {
            return true;
        }
    }.f;
    const never = struct {
        fn f(_: [:0]const u8) bool {
            return false;
        }
    }.f;
    var buf: [eh_exe_buf]u8 = undefined;
    // The real post-rebuild state: the old inode is unlinked so the readback
    // says `<path> (deleted)`, while the build renamed the fresh binary to
    // the same path — spawn that, never the marker-bearing literal.
    const rebuilt = chooseSpawnTarget(&buf, "/opt/horizon/horizon (deleted)", always);
    try t.expectEqualStrings("/opt/horizon/horizon", rebuilt);
    try t.expect(rebuilt.ptr[rebuilt.len] == 0);
    // A clean readback passes through untouched.
    const clean = chooseSpawnTarget(&buf, "/opt/horizon/horizon", always);
    try t.expectEqualStrings("/opt/horizon/horizon", clean);
    // Build dir really gone: PATH fallback, still never the marker literal.
    const gone = chooseSpawnTarget(&buf, "/opt/horizon/horizon (deleted)", never);
    try t.expectEqualStrings("EventHorizon", gone);
    // No usable readback at all.
    const none = chooseSpawnTarget(&buf, "", always);
    try t.expectEqualStrings("EventHorizon", none);
}

test "supervisor-run: deleted-marker strip only eats the kernel suffix" {
    const t = std.testing;
    try t.expectEqualStrings("/a/b/horizon", stripDeletedMarker("/a/b/horizon (deleted)"));
    try t.expectEqualStrings("/a/b/horizon", stripDeletedMarker("/a/b/horizon"));
    try t.expectEqualStrings("/a/b/(deleted) horizon", stripDeletedMarker("/a/b/(deleted) horizon"));
    try t.expectEqualStrings("", stripDeletedMarker(" (deleted)"));
}

test "supervisor-run: overview target is this executable's sibling" {
    const t = std.testing;
    var buf: [eh_exe_buf]u8 = undefined;
    try t.expectEqualStrings("/opt/horizon/horizon-overview", chooseOverviewTarget(&buf, "/opt/horizon/horizon"));
    // The rebuild marker must not reach posix_spawnp (same bug class as
    // screenshots).
    try t.expectEqualStrings("/opt/horizon/horizon-overview", chooseOverviewTarget(&buf, "/opt/horizon/horizon (deleted)"));
    // No directory in the fallback name: let posix_spawnp use PATH.
    try t.expectEqualStrings("horizon-overview", chooseOverviewTarget(&buf, "horizon"));
    try t.expectEqualStrings("horizon-overview", chooseOverviewTarget(&buf, ""));
}

test "supervisor-run: overview IPC takes words and rejects junk" {
    const t = std.testing;
    const toggle = try overviewHandler(t.allocator, &.{});
    defer t.allocator.free(toggle);
    try t.expectEqualStrings("ok", toggle);
    const open = try overviewHandler(t.allocator, &.{"open"});
    defer t.allocator.free(open);
    try t.expectEqualStrings("ok", open);
    const close = try overviewHandler(t.allocator, &.{"close"});
    defer t.allocator.free(close);
    try t.expectEqualStrings("ok", close);
    const bad = try overviewHandler(t.allocator, &.{"sideways"});
    defer t.allocator.free(bad);
    try t.expect(std.mem.startsWith(u8, bad, "error usage:"));
    const extra = try overviewHandler(t.allocator, &.{ "open", "now" });
    defer t.allocator.free(extra);
    try t.expect(std.mem.startsWith(u8, extra, "error usage:"));
}

test "supervisor-run: screenshot argv dupes free at full sentinel size" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    // Pre-fix, `owned: []const u8` freed n bytes for an n+1 dupeZ and the
    // safety-checked allocator abort()ed — the shell died one screenshot in
    // ("triggered once, then never again").
    const r = spawnScreenshot(gpa_state.allocator(), &.{ "--select", "--preview" });
    try std.testing.expectEqual(@as(i64, 0), r); // test build skips the exec
    try std.testing.expect(gpa_state.deinit() == .ok); // nothing leaked either
}
