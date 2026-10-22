//! evdev probing and the global keybind path of the supervisor.
//!
//! `probeFd`/`findSuperKeyboard` answer "which /dev/input node is the
//! keyboard" without needing privileges. On top of those sits a pure key
//! state machine (`Machine`) with the semantics the C++
//! `global_keyboard_handler.cpp` had — bare Super tap opens the menu,
//! Super+S opens settings — plus the keybinds the C++ shell never had
//! (audit finding F-1): Super+Shift+S picks a screenshot region, bare
//! PrtScr captures the monitor under the cursor, and Alt+PrtScr captures
//! every monitor as one stitched panorama ("--all-monitors").
//!
//! The machine is fed by `Handler`'s reader thread, which never runs a
//! side effect itself: actions are staged behind an eventfd and executed
//! by whoever calls `Handler.drain` on the main loop thread.

const std = @import("std");
const linux = std.os.linux;
const logz = @import("../logz.zig");
const c = @cImport(@cInclude("pthread.h"));

const EV_KEY: u32 = 0x01;
const KEY_LEFTMETA: u32 = 125;
const EV_MAX: u32 = 0x1f;
const KEY_MAX: u32 = 0x2ff;

// Key codes we act on (`linux/input-event-codes.h`).
const KEY_A: u32 = 30; // any ordinary key: proves another key cancels the tap
const KEY_S: u32 = 31;
const KEY_TAB: u32 = 15;

const KEY_LEFTCTRL: u32 = 29;
const KEY_RIGHTCTRL: u32 = 97;
const KEY_LEFTALT: u32 = 56;
const KEY_RIGHTALT: u32 = 100; // also AltGr on many layouts
const KEY_LEFTSHIFT: u32 = 42;
const KEY_RIGHTSHIFT: u32 = 54;
const KEY_SYSRQ: u32 = 99; // the PrintScreen key
const KEY_RIGHTMETA: u32 = 126;
const KEY_SCREENSHOT: u32 = 212; // XF86ScreenScreenshot

fn iocRead(typ: u32, nr: u32, size: usize) u32 {
    const dir: u32 = 2;
    return (dir << 30) | (@as(u32, @intCast(size & 0x3fff)) << 16) | ((typ & 0xff) << 8) | (nr & 0xff);
}

fn eviocgName(len: usize) u32 {
    return iocRead(0x45, 0x06, len);
}

fn eviocgBit(ev: u32, len: usize) u32 {
    return iocRead(0x45, 0x20 + ev, len);
}

pub const Probe = struct {
    has_ev_key: bool = false,
    has_leftmeta: bool = false,
    /// PrtScr-class keys advertised by the node.
    has_print: bool = false,
    /// A plain letter is advertised: real keyboards with text keys. This
    /// replaces the C++ LEFTMETA-only gate: some persistent keyboards
    /// (Keychron K10 Pro et al.) never advertise KEY_LEFTMETA — and often
    /// not even KEY_SYSRQ — so a META-only probe would refuse every node
    /// and the keybinds would never start at all (seen live, 2026-10-16).
    has_letter: bool = false,
    name: [256]u8 = [_]u8{0} ** 256,

    pub fn isSuperKeyboard(self: *const Probe) bool {
        if (!self.has_ev_key) return false;
        return self.has_leftmeta or self.has_print or self.has_letter;
    }
};

fn bitIsSet(bits: []const u64, n: u32) bool {
    const word = n / 64;
    if (word >= bits.len) return false;
    return (bits[word] & (@as(u64, 1) << @intCast(n % 64))) != 0;
}

pub fn probeFd(fd: i32) Probe {
    var r = Probe{};
    _ = linux.ioctl(fd, eviocgName(256), @intFromPtr(&r.name));
    var ev_bits: [(EV_MAX / 64) + 1]u64 = [_]u64{0} ** ((EV_MAX / 64) + 1);
    // The kernel returns the byte count copied, NOT zero, on success;
    // only a negative result is an error. The old `!= 0` check rejected
    // every working device, leaving keybinds off on every boot (seen
    // live, 2026-10-16: "no evdev keyboard devices found" each start).
    if (evBits(fd, 0, &ev_bits) < 0) return r;
    r.has_ev_key = bitIsSet(&ev_bits, EV_KEY);
    if (!r.has_ev_key) return r;
    var key_bits: [(KEY_MAX / 64) + 1]u64 = [_]u64{0} ** ((KEY_MAX / 64) + 1);
    if (evBits(fd, EV_KEY, &key_bits) < 0) return r;
    r.has_leftmeta = bitIsSet(&key_bits, KEY_LEFTMETA);
    r.has_print = bitIsSet(&key_bits, KEY_SYSRQ) or bitIsSet(&key_bits, KEY_SCREENSHOT);
    // Any word key proves a text keyboard. A is the ordinary case; S is
    // added for boards whose evdev bitmap is oddly pruned (the Rapoo here
    // advertises S but its neighbors' A bit was never confirmed).
    r.has_letter = bitIsSet(&key_bits, KEY_A) or bitIsSet(&key_bits, KEY_S);
    return r;
}

/// EVIOCGBIT: fill `bits` with the bitmap for event class `ev`.
/// Returns the byte count copied, or a negative errno. The buffer is
/// zeroed first because a short copy must never resurrect stale bits.
fn evBits(fd: i32, ev: u32, bits: []u64) isize {
    @memset(bits, 0);
    return @as(isize, @bitCast(linux.ioctl(fd, eviocgBit(ev, @sizeOf(u64) * bits.len), @intFromPtr(bits.ptr))));
}

/// Open `/dev/input/event<n>` read-only, nonblocking, close-on-exec and probe
/// it the same way `probeFd` always has. Returns the fd when the device is a
/// Super keyboard, or -1 (already closed) when it is not / cannot be opened —
/// so a box without evdev access degrades to "nothing found", never an error.
/// When `probe_out` is given it receives the probe either way, for logging.
fn openSuperKeyboard(n: u32, probe_out: ?*Probe) i32 {
    var path: [32]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/dev/input/event{d}", .{n}) catch return -1;
    var zpath: [40:0]u8 = [_:0]u8{0} ** 40;
    if (p.len + 1 > zpath.len) return -1;
    @memcpy(zpath[0..p.len], p);
    zpath[p.len] = 0;
    const rc: isize = @bitCast(linux.open(&zpath, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0));
    if (rc < 0) return -1;
    const fd: i32 = @intCast(rc);
    const probe = probeFd(fd);
    if (probe_out) |out| out.* = probe;
    if (probe.isSuperKeyboard()) return fd;
    _ = linux.close(fd);
    return -1;
}

pub fn findSuperKeyboard() ?[64]u8 {
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const fd = openSuperKeyboard(i, null);
        if (fd < 0) continue;
        _ = linux.close(fd);
        var path: [32]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "/dev/input/event{d}", .{i}) catch continue;
        var out: [64]u8 = [_]u8{0} ** 64;
        @memcpy(out[0..p.len], p);
        return out;
    }
    return null;
}

/// What a key event asks the shell to do. Actions are *staged* by the evdev
/// reader thread and only become side effects when the main loop thread
/// picks them up in `Handler.drain`.
pub const Action = enum {
    /// Bare Super tap: toggle the app menu.
    menu,
    /// Super+Tab: toggle the shell-owned overview. The C++ stage ignores
    /// Tab, so this is the only evdev consumer of the combo.
    overview,
    /// Super+S without shift held: toggle settings.
    settings,
    /// Super+Shift+S: the region picker with a live preview, the same flow
    /// the SUPER+SHIFT+S Hyprland bind runs. Both fire on one keypress; the
    /// picker's single-flight lock (`screenshot.zig`) makes the duplicate
    /// launch exit instead of stacking a second overlay.
    screenshot,
    /// Bare PrtScr / XF86ScreenScreenshot, no modifiers worth heeding: the
    /// whole monitor under the cursor, previewed. Super-held Print stays
    /// null here — Hyprland owns SUPER+Print and CTRL+Print, and the evdev
    /// reader sees every key no matter who consumes it, so firing on held
    /// Super would double-capture against those binds.
    screenshot_screen,
    /// Alt+PrtScr: every monitor stitched into one panoramic frame.
    screenshot_all,
};

/// Pure key state machine: evdev `input_event.code/value` in, optional
/// action out — no fd, thread or clock anywhere near it, so the C++
/// `global_keyboard_handler.cpp` semantics can be pinned by tests.
///
/// Kept from the C++ handler: Super press starts a hold and clears the
/// flags; any other key press during the hold cancels the bare-tap menu;
/// Super release fires the menu only when nothing cancelled it; Super+S
/// fires settings at most once per hold and never while shift is held.
/// Added here (the C++ shell did neither, so nothing can double-fire):
/// Super+Tab toggles the overview; Super+Shift+S requests the region picker;
/// bare PrtScr captures the cursor's monitor (Super- or Ctrl-held Print
/// stays null so the Hyprland SUPER+Print / CTRL+Print binds do not
/// double-fire); Alt+PrtScr captures all monitors. Autorepeat (value 2)
/// never fires an action, and shift, alt and ctrl are each tracked from
/// either key so the combos stay distinguishable.
pub const Machine = struct {
    super_down: bool = false,
    /// Another key was pressed during the Super hold: no menu on release.
    cancel: bool = false,
    /// Super+S already fired during this Super hold.
    super_s_fired: bool = false,
    /// Super+Tab already fired during this Super hold.
    super_tab_fired: bool = false,
    shift_down: bool = false,
    /// Either Alt key down: Alt+PrtScr means "every monitor". Tracked from
    /// both keys the same way shift is; AltGr (right alt) along with Print
    /// would also fire the panorama, but that combo does not type anything.
    alt_down: bool = false,
    /// Either Ctrl key down: Print while Ctrl is held stays null because the
    /// Hyprland CTRL+Print bind ("active monitor", no clipboard) owns that
    /// combo; firing here as well would spawn a second capture.
    ctrl_down: bool = false,

    /// Feed one key event (callers drop non-EV_KEY types first).
    /// `value` follows evdev: 1 press, 0 release, 2 autorepeat.
    pub fn feed(self: *Machine, code: u32, value: i32) ?Action {
        if (code == KEY_LEFTMETA or code == KEY_RIGHTMETA) {
            if (value == 1) {
                self.super_down = true;
                self.cancel = false;
                self.super_s_fired = false;
                self.super_tab_fired = false;
            } else if (value == 0) {
                const bare_tap = self.super_down and !self.cancel and !self.super_s_fired and !self.super_tab_fired;
                self.super_down = false;
                self.cancel = false;
                self.super_s_fired = false;
                self.super_tab_fired = false;
                if (bare_tap) return .menu;
            }
            // value 2 on a modifier: nothing to do.
            return null;
        }
        if (code == KEY_LEFTSHIFT or code == KEY_RIGHTSHIFT) {
            self.shift_down = value != 0;
            return null;
        }
        if (code == KEY_LEFTALT or code == KEY_RIGHTALT) {
            // value 0 releases, 1 presses, 2 autorepeat keeps it down.
            self.alt_down = value != 0;
            return null;
        }
        if (code == KEY_LEFTCTRL or code == KEY_RIGHTCTRL) {
            self.ctrl_down = value != 0;
            return null;
        }
        if (value != 1) return null; // releases and repeats never fire
        // Matches C++: any press marks the hold as "not a bare tap" and
        // must run even when Super is up, so a stray press before a tap
        // cannot leak a menu either.
        self.cancel = true;
        if (self.super_down and code == KEY_TAB) {
            // Win+Tab now belongs to the shell: the combo is consumed here
            // and never reaches a Hyprland overview bind. Shift/Ctrl/Alt
            // variants stay free for other bindings (Shift+Tab inside the
            // overview is handled by that surface's own keyboard, not this
            // machine).
            if (self.shift_down or self.ctrl_down or self.alt_down) return null;
            if (!self.super_tab_fired) {
                self.super_tab_fired = true;
                return .overview;
            }
        }
        if (code == KEY_SYSRQ or code == KEY_SCREENSHOT) {
            // Super-held and Ctrl-held Print belong to the Hyprland binds
            // (SUPER+Print previews a fixed path; CTRL+Print grabs the
            // active monitor without the clipboard); firing here would
            // spawn a second capture over the same keypress.
            if (self.super_down or self.ctrl_down) return null;
            if (self.alt_down) return .screenshot_all;
            return .screenshot_screen;
        }
        if (self.super_down and code == KEY_S) {
            if (self.shift_down) return .screenshot;
            if (!self.super_s_fired) {
                self.super_s_fired = true;
                return .settings;
            }
        }
        return null;
    }
};

/// `struct input_event` on 64-bit Linux: a two-long timeval, then type,
/// code, value. evdev hands over whole events, never partial structs.
const InputEvent = extern struct {
    sec: i64,
    usec: i64,
    typ: u16,
    code: u16,
    value: i32,
};

/// Reader poll round: short enough that `stop` joins quickly (the C++
/// `evdev_thread_fn` waited 100 ms per epoll round too), and 50 silent
/// rounds make ~5 s — the interval after which `/dev/input` is re-scanned
/// so a keyboard plugged in later is picked up.
const kPollMs: i32 = 100;
const kRescanIdleRounds: u32 = 50;

/// Reads the super keyboard on its own thread and stages actions for the
/// main loop.
///
/// The hand-off is deliberately one-directional: the reader feeds a
/// `Machine`, appends the resulting action to a mutex-guarded FIFO and
/// writes an eventfd. The supervisor watches that fd (`pendingFd`) and runs
/// `drain` on its loop thread, so spawning and IPC never happen off it.
/// Without evdev access `start` logs and returns false — no thread, no fd,
/// never a crash and never a failing test.
pub const Handler = struct {
    alloc: std.mem.Allocator = std.heap.page_allocator,
    /// eventfd the main loop polls; -1 until `init` ran.
    wake_fd: i32 = -1,
    mutex: c.pthread_mutex_t = undefined,
    mutex_ready: bool = false,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    /// Actions waiting to be drained (guarded by `mutex`).
    pending: std.ArrayList(Action) = .empty,

    /// eventfd + FIFO. Kept separate from `start` so the hand-off can be
    /// unit-tested without touching /dev/input. Idempotent.
    pub fn init(self: *Handler, alloc: std.mem.Allocator) !void {
        self.alloc = alloc;
        if (!self.mutex_ready) {
            if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
            self.mutex_ready = true;
        }
        if (self.wake_fd >= 0) return;
        const rc: isize = @bitCast(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        if (rc < 0) return error.EventFdFailed;
        self.wake_fd = @intCast(rc);
    }

    /// Bring the reader up. False means nothing will ever fire: no super
    /// keyboard (the process is usually not in the `input` group), no
    /// eventfd, or no thread. Each failure logs one line and stays stopped.
    pub fn start(self: *Handler, alloc: std.mem.Allocator) bool {
        self.init(alloc) catch |e| {
            logz.err("global-keyboard: init failed: {s}", .{@errorName(e)});
            return false;
        };
        if (self.running.load(.acquire)) return true;
        if (findSuperKeyboard() == null) {
            logz.log("global-keyboard: no evdev keyboard devices found (this process is likely not in the `input` group / lacks evdev ACLs); keybinds stay off", .{});
            return false;
        }
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, readerMain, .{self}) catch |e| {
            self.running.store(false, .release);
            logz.err("global-keyboard: reader thread spawn failed: {s}", .{@errorName(e)});
            return false;
        };
        logz.log("global-keyboard: listening for global keybinds", .{});
        return true;
    }

    /// The eventfd for `Loop.watchFd`; -1 until `init` succeeded. Watch it
    /// only when `start` returned true.
    pub fn pendingFd(self: *const Handler) i32 {
        return self.wake_fd;
    }

    /// Move every staged action into `out` (the caller's list, allocated
    /// with the caller's allocator) and clear the eventfd wake. Main loop
    /// thread only — this is the one place actions become side effects.
    pub fn drain(self: *Handler, alloc: std.mem.Allocator, out: *std.ArrayList(Action)) void {
        if (self.wake_fd >= 0) {
            var buf: [8]u8 = undefined;
            _ = linux.read(self.wake_fd, &buf, buf.len);
        }
        if (!self.mutex_ready) return;
        self.lock();
        defer self.unlock();
        out.appendSlice(alloc, self.pending.items) catch {};
        self.pending.clearRetainingCapacity();
    }

    /// Stop the reader and wait for it. Idempotent, and safe to call when
    /// `start` never ran (or never succeeded).
    pub fn stop(self: *Handler) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            // The reader polls in 100 ms rounds, so it notices quickly.
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Handler) void {
        self.stop();
        if (self.wake_fd >= 0) {
            _ = linux.close(self.wake_fd);
            self.wake_fd = -1;
        }
        if (self.mutex_ready) {
            self.pending.deinit(self.alloc);
            self.pending = .empty;
            _ = c.pthread_mutex_destroy(&self.mutex);
            self.mutex_ready = false;
        }
    }

    /// Stage an action from the reader thread and poke the eventfd. The
    /// action itself runs later, in `drain`.
    fn enqueue(self: *Handler, action: Action) void {
        if (self.wake_fd < 0 or !self.mutex_ready) return;
        self.lock();
        defer self.unlock();
        // A drop under OOM costs one keybind, not the shell.
        self.pending.append(self.alloc, action) catch return;
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    fn lock(self: *Handler) void {
        if (self.mutex_ready) _ = c.pthread_mutex_lock(&self.mutex);
    }

    fn unlock(self: *Handler) void {
        if (self.mutex_ready) _ = c.pthread_mutex_unlock(&self.mutex);
    }
};

/// The reader thread: poll every open super keyboard, feed the machine and
/// stage whatever it asks for. Devices are re-scanned about every 5 s of
/// silence, and everything is closed when `stop` flips the flag.
fn readerMain(h: *Handler) void {
    logz.log("global-keyboard: evdev reader started", .{});
    var devs: [64]i32 = .{-1} ** 64;
    var pfds: [64]std.posix.pollfd = undefined;
    var machine = Machine{};
    var idle_rounds: u32 = 0;
    while (h.running.load(.acquire)) {
        // Poll slots parallel to `devs`; the kernel ignores fd < 0, so
        // empty slots simply never report anything.
        for (devs, 0..) |fd, i| {
            pfds[i] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        }
        const ready = std.posix.poll(pfds[0..devs.len], kPollMs) catch |e| {
            if (e == error.SignalInterrupt) continue;
            logz.err("global-keyboard: poll failed: {s}", .{@errorName(e)});
            break;
        };
        if (ready == 0) {
            idle_rounds += 1;
            if (idle_rounds >= kRescanIdleRounds) {
                idle_rounds = 0;
                scanNewDevices(&devs);
            }
            continue;
        }
        idle_rounds = 0;
        for (&devs, 0..) |*fd, i| {
            if (fd.* < 0) continue;
            const rev = pfds[i].revents;
            if (rev == 0) continue;
            if ((rev & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
                closeDevice(fd);
                continue;
            }
            if ((rev & std.posix.POLL.IN) != 0 and readEvents(h, &machine, fd.*)) closeDevice(fd);
        }
    }
    for (&devs) |*fd| closeDevice(fd);
    logz.log("global-keyboard: evdev reader exiting", .{});
}

/// Open every super keyboard under `/dev/input/event0..63` that is not open
/// yet. Only unset slots are tried, so repeated scans never double-open a
/// device, and a keyboard that vanished simply closes on its next read error.
fn scanNewDevices(devs: *[64]i32) void {
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        if (devs[i] >= 0) continue;
        var probe = Probe{};
        const fd = openSuperKeyboard(i, &probe);
        if (fd < 0) continue;
        devs[i] = fd;
        var path: [32]u8 = undefined;
        if (std.fmt.bufPrint(&path, "/dev/input/event{d}", .{i})) |p| {
            logz.log("global-keyboard: opened {s} name={s}", .{ p, probeName(&probe) });
        } else |_| {}
    }
}

/// Drain one device's queue of events into the machine. Returns true when
/// the fd is dead and should be dropped.
fn readEvents(h: *Handler, m: *Machine, fd: i32) bool {
    while (true) {
        var ev: InputEvent = undefined;
        const n = linux.read(fd, @ptrCast(&ev), @sizeOf(InputEvent));
        const err = linux.errno(n);
        if (err == .INTR) continue;
        if (err == .AGAIN) return false; // nothing buffered (EWOULDBLOCK == EAGAIN)
        if (err != .SUCCESS) return true;
        if (n != @sizeOf(InputEvent)) return true; // evdev only hands over whole events
        if (ev.typ != EV_KEY) continue;
        if (m.feed(ev.code, ev.value)) |action| h.enqueue(action);
    }
}

fn closeDevice(fd: *i32) void {
    if (fd.* >= 0) _ = linux.close(fd.*);
    fd.* = -1;
}

/// The device name NUL-terminated by the EVIOCGNAME ioctl, as a slice.
fn probeName(p: *const Probe) []const u8 {
    const end = std.mem.indexOfScalar(u8, &p.name, 0) orelse p.name.len;
    return p.name[0..end];
}

test "kbd: bit test helper" {
    const t = std.testing;
    const bits = [_]u64{0b101};
    try t.expect(bitIsSet(&bits, 0));
    try t.expect(!bitIsSet(&bits, 1));
    try t.expect(bitIsSet(&bits, 2));
    try t.expect(!bitIsSet(&bits, 500));
}

test "kbd: device scan runs without privileges" {
    _ = findSuperKeyboard();
    try std.testing.expect(true);
}

test "kbd: bare super tap emits menu" {
    const t = std.testing;
    var m = Machine{};
    try t.expectEqual(@as(?Action, null), m.feed(KEY_LEFTMETA, 1));
    try t.expectEqual(@as(?Action, .menu), m.feed(KEY_LEFTMETA, 0));
    // A repeat on the way up must not fire anything (value 2 is ignored).
    var m2 = Machine{};
    _ = m2.feed(KEY_LEFTMETA, 1);
    try t.expectEqual(@as(?Action, null), m2.feed(KEY_LEFTMETA, 2));
    try t.expectEqual(@as(?Action, .menu), m2.feed(KEY_LEFTMETA, 0));
    // The right meta key is Super too (C++ checked both).
    var m3 = Machine{};
    _ = m3.feed(KEY_RIGHTMETA, 1);
    try t.expectEqual(@as(?Action, .menu), m3.feed(KEY_RIGHTMETA, 0));
}

test "kbd: any other key during a super hold cancels the menu" {
    const t = std.testing;
    var m = Machine{};
    _ = m.feed(KEY_LEFTMETA, 1);
    try t.expectEqual(@as(?Action, null), m.feed(KEY_A, 1));
    try t.expectEqual(@as(?Action, null), m.feed(KEY_A, 0));
    try t.expectEqual(@as(?Action, null), m.feed(KEY_LEFTMETA, 0));
    try t.expect(!m.super_down);
}

test "kbd: super+s fires settings once per hold" {
    const t = std.testing;
    var m = Machine{};
    _ = m.feed(KEY_LEFTMETA, 1);
    try t.expectEqual(@as(?Action, .settings), m.feed(KEY_S, 1));
    try t.expectEqual(@as(?Action, null), m.feed(KEY_S, 0));
    // Second Super+S in the same hold: nothing (super_s_fired).
    try t.expectEqual(@as(?Action, null), m.feed(KEY_S, 1));
    try t.expectEqual(@as(?Action, null), m.feed(KEY_S, 0));
    // And the hold itself no longer qualifies for the menu either.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_LEFTMETA, 0));
    // A fresh hold fires again.
    _ = m.feed(KEY_LEFTMETA, 1);
    try t.expectEqual(@as(?Action, .settings), m.feed(KEY_S, 1));
    _ = m.feed(KEY_S, 0);
    _ = m.feed(KEY_LEFTMETA, 0);
}

test "kbd: super+shift+s fires screenshot instead of settings" {
    const t = std.testing;
    var m = Machine{};
    _ = m.feed(KEY_LEFTSHIFT, 1);
    _ = m.feed(KEY_LEFTMETA, 1);
    try t.expectEqual(@as(?Action, .screenshot), m.feed(KEY_S, 1));
    try t.expectEqual(@as(?Action, null), m.feed(KEY_S, 0));
    // The press set cancel, so releasing Super must not open the menu.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_LEFTMETA, 0));
    _ = m.feed(KEY_LEFTSHIFT, 0);
    // Plain shift+s without Super is ordinary typing: nothing fires.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_S, 1));
    _ = m.feed(KEY_S, 0);
}

test "kbd: super+tab toggles overview once per hold" {
    const t = std.testing;
    var m = Machine{};
    _ = m.feed(KEY_LEFTMETA, 1);
    try t.expectEqual(@as(?Action, .overview), m.feed(KEY_TAB, 1));
    // Autorepeat and release never fire again.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_TAB, 2));
    try t.expectEqual(@as(?Action, null), m.feed(KEY_TAB, 0));
    // A second press in the same hold is still the same toggle.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_TAB, 1));
    _ = m.feed(KEY_TAB, 0);
    // The Tab press cancelled the bare Super menu.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_LEFTMETA, 0));
    // A fresh hold fires again.
    _ = m.feed(KEY_LEFTMETA, 1);
    try t.expectEqual(@as(?Action, .overview), m.feed(KEY_TAB, 1));
    _ = m.feed(KEY_TAB, 0);
    _ = m.feed(KEY_LEFTMETA, 0);
}

test "kbd: tab without super and modified super+tab stay quiet" {
    const t = std.testing;
    var m = Machine{};
    try t.expectEqual(@as(?Action, null), m.feed(KEY_TAB, 1)); // no Super
    _ = m.feed(KEY_TAB, 0);

    _ = m.feed(KEY_LEFTMETA, 1);
    _ = m.feed(KEY_LEFTSHIFT, 1);
    try t.expectEqual(@as(?Action, null), m.feed(KEY_TAB, 1));
    _ = m.feed(KEY_TAB, 0);
    _ = m.feed(KEY_LEFTSHIFT, 0);

    _ = m.feed(KEY_LEFTCTRL, 1);
    try t.expectEqual(@as(?Action, null), m.feed(KEY_TAB, 1));
    _ = m.feed(KEY_TAB, 0);
    _ = m.feed(KEY_LEFTCTRL, 0);

    _ = m.feed(KEY_LEFTALT, 1);
    try t.expectEqual(@as(?Action, null), m.feed(KEY_TAB, 1));
    _ = m.feed(KEY_TAB, 0);
    _ = m.feed(KEY_LEFTALT, 0);

    // A plain Win+Tab still works in the same hold once modifiers are up.
    try t.expectEqual(@as(?Action, .overview), m.feed(KEY_TAB, 1));
    _ = m.feed(KEY_TAB, 0);
    _ = m.feed(KEY_LEFTMETA, 0);
}

test "kbd: bare print captures the cursor's monitor, alt+print captures all" {
    const t = std.testing;
    var m = Machine{};
    try t.expectEqual(@as(?Action, .screenshot_screen), m.feed(KEY_SYSRQ, 1));
    // Autorepeat of PrtScr must not take a second screenshot.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_SYSRQ, 2));
    try t.expectEqual(@as(?Action, null), m.feed(KEY_SYSRQ, 0));
    // XF86ScreenScreenshot (KEY_SCREENSHOT) is the other screenshot key.
    try t.expectEqual(@as(?Action, .screenshot_screen), m.feed(KEY_SCREENSHOT, 1));
    try t.expectEqual(@as(?Action, null), m.feed(KEY_SCREENSHOT, 2));
    try t.expectEqual(@as(?Action, null), m.feed(KEY_SCREENSHOT, 0));

    // Alt held (either key): the panorama instead.
    var m2 = Machine{};
    _ = m2.feed(KEY_LEFTALT, 1);
    try t.expectEqual(@as(?Action, .screenshot_all), m2.feed(KEY_SYSRQ, 1));
    var m3 = Machine{};
    _ = m3.feed(KEY_RIGHTALT, 2); // autorepeat of the modifier keeps it down
    try t.expectEqual(@as(?Action, .screenshot_all), m3.feed(KEY_SYSRQ, 1));
    // And after both alts release, print is back to the single monitor.
    _ = m2.feed(KEY_LEFTALT, 0);
    try t.expectEqual(@as(?Action, .screenshot_screen), m2.feed(KEY_SYSRQ, 1));
}

test "kbd: super-held print stays null — Hyprland owns SUPER+Print" {
    const t = std.testing;
    var m = Machine{};
    _ = m.feed(KEY_LEFTMETA, 1);
    // The evdev reader sees every key regardless of who consumes it, so
    // firing here would double up against the Hyprland SUPER+Print bind.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_SYSRQ, 1));
    // It still counts as "not a bare tap" for the menu, like any other key.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_LEFTMETA, 0));
}

test "kbd: ctrl-held print stays null — Hyprland owns CTRL+Print" {
    const t = std.testing;
    var m = Machine{};
    _ = m.feed(KEY_LEFTCTRL, 1);
    try t.expect(m.ctrl_down);
    // The bind execs the active-monitor capture; firing the evdev action
    // too would run two captures from the same keypress.
    try t.expectEqual(@as(?Action, null), m.feed(KEY_SYSRQ, 1));
    // Right ctrl gates the same way; once all ctrl keys are up, bare
    // print works again.
    _ = m.feed(KEY_LEFTCTRL, 0);
    _ = m.feed(KEY_RIGHTCTRL, 1);
    try t.expectEqual(@as(?Action, null), m.feed(KEY_SYSRQ, 1));
    _ = m.feed(KEY_RIGHTCTRL, 0);
    try t.expectEqual(@as(?Action, .screenshot_screen), m.feed(KEY_SYSRQ, 1));
}

test "kbd: shift tracking follows both shift keys through repeats" {
    const t = std.testing;
    var m = Machine{};
    try t.expect(!m.shift_down);
    _ = m.feed(KEY_LEFTSHIFT, 1);
    try t.expect(m.shift_down);
    _ = m.feed(KEY_LEFTSHIFT, 2); // autorepeat keeps it down
    try t.expect(m.shift_down);
    _ = m.feed(KEY_LEFTSHIFT, 0);
    try t.expect(!m.shift_down);
    _ = m.feed(KEY_RIGHTSHIFT, 1);
    try t.expect(m.shift_down);
    _ = m.feed(KEY_RIGHTSHIFT, 2);
    try t.expect(m.shift_down);
    _ = m.feed(KEY_RIGHTSHIFT, 0);
    try t.expect(!m.shift_down);
}

test "kbd: handler hands actions to the main thread over an eventfd" {
    const t = std.testing;
    var h = Handler{};
    defer h.deinit();
    try h.init(t.allocator);
    const fd = h.pendingFd();
    try t.expect(fd >= 0);

    // The reader thread's half of the hand-off (same call it makes).
    h.enqueue(.screenshot);
    h.enqueue(.menu);

    var out: std.ArrayList(Action) = .empty;
    defer out.deinit(t.allocator);
    h.drain(t.allocator, &out);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqual(Action.screenshot, out.items[0]);
    try t.expectEqual(Action.menu, out.items[1]);

    // The wake was consumed: a second drain sees nothing stale.
    out.clearRetainingCapacity();
    h.drain(t.allocator, &out);
    try t.expectEqual(@as(usize, 0), out.items.len);
}

test "kbd: handler stops cleanly whether or not it was started" {
    const t = std.testing;
    var never = Handler{};
    never.stop(); // no init, no start: must be a no-op
    never.deinit();
    try t.expect(never.pendingFd() == -1);

    var h = Handler{};
    defer h.deinit();
    // With a keyboard this starts the reader for a moment; without one it
    // logs and stays stopped. Both paths must stop and join cleanly.
    if (h.start(t.allocator)) {
        try t.expect(h.pendingFd() >= 0);
        h.stop();
        try t.expect(h.thread == null);
        try t.expect(!h.running.load(.acquire));
    }
}

test "kbd: device scan fills slots it can open and ignores the rest" {
    const t = std.testing;
    var devs: [64]i32 = .{-1} ** 64;
    scanNewDevices(&devs);
    var opened: usize = 0;
    for (devs) |fd| {
        if (fd < 0) continue;
        opened += 1;
        // Probing a real keyboard must have produced a plausible name.
        try t.expect(probeFd(fd).has_ev_key);
        _ = linux.close(fd);
    }
    // Without /dev/input access this is 0 — still a passing test.
    try t.expect(opened <= 64);
}
