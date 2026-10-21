const std = @import("std");
const linux = std.os.linux;
const spawn_mod = @import("spawn.zig");
const logz = @import("../logz.zig");

/// Child-process supervisor: keeps the always-on components from `spawn.zig`
/// alive as children of the EventHorizon process.
///
/// Only binaries sitting next to the supervisor executable are started, so a
/// ported component never accidentally launches a system-wide copy of the
/// same name (the two would fight over one layer surface). A component that
/// is already running somewhere else is left alone instead of doubled up.
const wait_nohang: u32 = 1;
const exe_buf_len: usize = 4096;

const State = enum {
    /// Nothing to do yet / ready for a (re)start.
    idle,
    running,
    /// Waiting out a restart backoff.
    cooling,
    /// No such binary beside the supervisor.
    missing,
    /// Some other process already owns this component.
    external,
};

pub const Supervisor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Directory holding this executable; component binaries are resolved
    /// against it. Never PATH.
    exe_dir: []u8,
    states: [spawn_mod.table.len]State = .{.idle} ** spawn_mod.table.len,
    pids: [spawn_mod.table.len]std.posix.pid_t = .{0} ** spawn_mod.table.len,
    restarts: [spawn_mod.table.len]u32 = .{0} ** spawn_mod.table.len,
    retry_at_ms: [spawn_mod.table.len]i64 = .{0} ** spawn_mod.table.len,
    /// Settings-suppressed components (gated off): never spawned, and
    /// stopped when the gate closes under a running child.
    suppressed: [spawn_mod.table.len]bool = .{false} ** spawn_mod.table.len,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Supervisor {
        const dir = resolveExeDir(gpa) catch null;
        const exe_dir = dir orelse try gpa.dupe(u8, ".");
        if (dir == null) {
            logz.log("supervisor: cannot resolve own path, components resolve against cwd", .{});
        }
        return .{ .gpa = gpa, .io = io, .exe_dir = exe_dir };
    }

    pub fn deinit(self: *Supervisor) void {
        if (self.exe_dir.len > 0) self.gpa.free(self.exe_dir);
        self.exe_dir = "";
    }

    /// Start every `.always` component whose binary exists beside us,
    /// skipping settings-suppressed ones.
    pub fn startAlways(self: *Supervisor) void {
        for (spawn_mod.table, 0..) |c, i| {
            if (c.policy == .always and !self.suppressed[i]) self.spawn(i);
        }
    }

    /// Apply one settings gate: suppress (and SIGTERM when running) or
    /// release back to `.always` duty. Returns true when the gate is open.
    pub fn setWanted(self: *Supervisor, name: []const u8, want: bool) bool {
        const i = spawn_mod.indexOf(name) orelse return true;
        self.suppressed[i] = !want;
        if (!want) {
            if (self.states[i] == .running) self.stop(i);
            self.states[i] = .idle;
            self.pids[i] = 0;
        }
        return want;
    }

    /// Apply both bar gates at once (dock/taskbar).
    pub fn applyGates(self: *Supervisor, gates: spawn_mod.Gates) void {
        _ = self.setWanted("dock", spawn_mod.wanted("dock", gates));
        _ = self.setWanted("taskbar", spawn_mod.wanted("taskbar", gates));

    }

    pub fn runningCount(self: *const Supervisor) usize {
        var n: usize = 0;
        for (self.states) |s| {
            if (s == .running) n += 1;
        }
        return n;
    }

    /// Reap dead children and restart the ones the policy wants alive.
    /// Call from the periodic supervisor tick.
    pub fn tick(self: *Supervisor) void {
        const now = nowMs();
        for (spawn_mod.table, 0..) |c, i| {
            switch (self.states[i]) {
                .running => {
                    if (!self.reap(i)) continue;
                    const policy = c.policy;
                    self.restarts[i] += 1;
                    if (policy == .on_demand) {
                        self.states[i] = .idle;
                        continue;
                    }
                    const backoff: i64 = @intCast(spawn_mod.nextBackoffMs(self.restarts[i]));
                    if (backoff > 0) {
                        self.states[i] = .cooling;
                        self.retry_at_ms[i] = now + backoff;
                    } else {
                        self.states[i] = .idle;
                    }
                },
                .cooling => {
                    if (now >= self.retry_at_ms[i]) self.states[i] = .idle;
                },
                .idle => {
                    if (c.policy == .always and !self.suppressed[i]) self.spawn(i);
                },
                .missing, .external => {},
            }
        }
    }

    /// Ask every child to exit (SIGTERM, honouring their own handlers).
    pub fn shutdown(self: *Supervisor) void {
        self.signalAll(linux.SIG.TERM);
    }

    /// Reap without restarting anything — the shutdown path, where a dead
    /// `.always` child must stay dead.
    pub fn reapAll(self: *Supervisor) void {
        for (spawn_mod.table, 0..) |_, i| {
            if (self.states[i] != .running) continue;
            if (self.reap(i)) self.states[i] = .idle;
        }
    }

    pub fn anyRunning(self: *const Supervisor) bool {
        for (self.states) |s| {
            if (s == .running) return true;
        }
        return false;
    }

    /// Last resort for children that ignored `shutdown`.
    pub fn killAll(self: *Supervisor) void {
        self.signalAll(linux.SIG.KILL);
    }

    fn signalAll(self: *Supervisor, sig: linux.SIG) void {
        for (spawn_mod.table, 0..) |_, i| {
            if (self.states[i] != .running) continue;
            _ = linux.kill(self.pids[i], sig);
        }
    }

    /// Ask one child to exit (SIGTERM, honouring its own handler). The
    /// shutdown/reap path collects it; callers clear state themselves when
    /// the stop is a settings gate rather than a shutdown.
    fn stop(self: *Supervisor, i: usize) void {
        if (self.states[i] != .running) return;
        _ = linux.kill(self.pids[i], linux.SIG.TERM);
        logz.log("supervisor: stopping {s} pid={d} (settings gate closed)", .{ spawn_mod.table[i].argv0, self.pids[i] });
    }

    /// Poll one child. Returns true when it has exited (state cleared).
    fn reap(self: *Supervisor, i: usize) bool {
        var status: u32 = 0;
        const rc = linux.wait4(self.pids[i], &status, wait_nohang, null);
        const got: isize = @bitCast(rc);
        if (got == 0) return false; // still alive
        const name = spawn_mod.table[i].argv0;
        if (got < 0) {
            // ECHILD: it was never our child (or already reaped).
            self.pids[i] = 0;
            self.states[i] = .idle;
            return false;
        }
        logz.log("supervisor: {s} (pid {d}) exited status=0x{x}", .{ name, self.pids[i], status });
        self.pids[i] = 0;
        return true;
    }

    fn spawn(self: *Supervisor, i: usize) void {
        const comp = spawn_mod.table[i];
        if (self.pids[i] != 0) return;
        if (self.states[i] == .missing or self.states[i] == .external) return;

        var path_buf: [exe_buf_len]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.exe_dir, comp.argv0 }) catch return;
        if (!self.isExecutable(path)) {
            self.states[i] = .missing;
            return;
        }
        if (self.runningElsewhere(comp.argv0)) {
            self.states[i] = .external;
            logz.log("supervisor: {s} already running elsewhere, skipping", .{comp.argv0});
            return;
        }

        var argv_buf: [8][]const u8 = undefined;
        argv_buf[0] = path;
        const extra = comp.extra_args;
        if (extra.len + 1 > argv_buf.len) return;
        @memcpy(argv_buf[1 .. 1 + extra.len], extra);
        const argv = argv_buf[0 .. 1 + extra.len];

        const child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |e| {
            logz.err("supervisor: spawn {s} failed: {s}", .{ comp.argv0, @errorName(e) });
            return;
        };
        const pid: std.posix.pid_t = if (child.id) |p| p else 0;
        if (pid == 0) return;
        self.pids[i] = pid;
        self.states[i] = .running;
        logz.log("supervisor: started {s} pid={d}", .{ comp.argv0, pid });
    }

    /// True when `path` exists and is executable by us.
    fn isExecutable(self: *Supervisor, path: []const u8) bool {
        const z = self.gpa.dupeZ(u8, path) catch return false;
        defer self.gpa.free(z);
        return linux.access(z, linux.X_OK) == 0;
    }

    /// True when a process with this exact argv[0] basename is already up.
    fn runningElsewhere(self: *Supervisor, argv0: []const u8) bool {
        const io = self.io;
        const dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return false;
        defer dir.close(io);
        var it = dir.iterate();
        const me = linux.getpid();
        while (true) {
            const entry = it.next(io) catch break;
            const e = entry orelse break;
            const pid = parsePid(e.name) orelse continue;
            if (pid == me) continue;
            var pbuf: [64]u8 = undefined;
            const rel = std.fmt.bufPrint(&pbuf, "{s}/cmdline", .{e.name}) catch continue;
            var buf: [exe_buf_len]u8 = undefined;
            const cmd = dir.readFile(io, rel, &buf) catch continue;
            if (cmd.len == 0) continue;
            const end = std.mem.indexOfScalar(u8, cmd, 0) orelse cmd.len;
            if (std.mem.eql(u8, std.fs.path.basename(cmd[0..end]), argv0)) return true;
        }
        return false;
    }
};

fn parsePid(name: []const u8) ?std.posix.pid_t {
    if (name.len == 0) return null;
    var v: std.posix.pid_t = 0;
    for (name) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + (ch - '0');
    }
    return v;
}

fn resolveExeDir(alloc: std.mem.Allocator) !?[]u8 {
    var buf: [exe_buf_len]u8 = undefined;
    const n = linux.readlink("/proc/self/exe", &buf, buf.len);
    const got: isize = @bitCast(n);
    if (got <= 0) return null;
    const exe = buf[0..@intCast(got)];
    const dir = std.fs.path.dirname(exe) orelse return null;
    return try alloc.dupe(u8, dir);
}

pub fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

test "supervisor: pid parsing rejects non-numeric entries" {
    const t = std.testing;
    try t.expectEqual(@as(?std.posix.pid_t, 1234), parsePid("1234"));
    try t.expect(parsePid("self") == null);
    try t.expect(parsePid("") == null);
    try t.expect(parsePid("12a") == null);
}

test "supervisor: fresh instance has nothing running" {
    const t = std.testing;
    var s = Supervisor.init(t.allocator, std.testing.io) catch return;
    defer s.deinit();
    try t.expectEqual(@as(usize, 0), s.runningCount());
    // Scanning /proc must not match a name nothing on the box can have.
    try t.expect(!s.runningElsewhere("event-horizon-no-such-component"));
}

test "supervisor: finds a live process by argv[0] basename" {
    const t = std.testing;
    var s = Supervisor.init(t.allocator, std.testing.io) catch return;
    defer s.deinit();

    const child = std.process.spawn(std.testing.io, .{
        .argv = &.{ "sleep", "10" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return; // no sleep(1) on this box: nothing to assert
    // Wait for exec to land before scanning.
    var ts: linux.timespec = .{ .sec = 0, .nsec = 30_000_000 };
    _ = linux.nanosleep(&ts, null);
    const found = s.runningElsewhere("sleep");
    var c = child;
    c.kill(std.testing.io);
    try t.expect(found);
}

test "supervisor: settings gate suppresses and releases" {
    const t = std.testing;
    var s = Supervisor.init(t.allocator, std.testing.io) catch return;
    defer s.deinit();
    const idx = spawn_mod.indexOf("taskbar").?;
    s.applyGates(.{ .dock_show = true, .taskbar_enabled = false });
    try t.expect(s.suppressed[idx]);
    s.applyGates(.{ .dock_show = true, .taskbar_enabled = true });
    try t.expect(!s.suppressed[idx]);
    try t.expect(s.setWanted("no-such-component", false));
}
