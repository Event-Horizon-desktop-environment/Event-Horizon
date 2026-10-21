const std = @import("std");
const linux = std.os.linux;

/// Files beside the toml stack that still feed a live view, so a save has to
/// wake the same reload a toml save does: the world-clock lists.
/// `<leaf>/world_clock.json` is the dock/taskbar widget's store (their own
/// popup saves it too), `<leaf>/WorldClock` the desktop widget's; Settings >
/// Time writes both. Neither carries a `.toml` suffix, so `drainAnyToml`
/// alone would swallow the event — see `drainAnyLive`.
pub const live_extra_names = [_][]const u8{ "world_clock.json", "WorldClock" };

pub const Watcher = struct {
    fd: i32 = -1,
    wd: i32 = -1,

    pub fn watchConfigDir(self: *Watcher, dir_path: []const u8) bool {
        self.close();
        var zbuf: [512:0]u8 = [_:0]u8{0} ** 512;
        if (dir_path.len + 1 > zbuf.len) return false;
        @memcpy(zbuf[0..dir_path.len], dir_path);
        const fd_rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        if (linux.errno(fd_rc) != .SUCCESS) return false;
        const fd: i32 = @intCast(fd_rc);
        const wd_rc = linux.inotify_add_watch(fd, &zbuf, linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVE | linux.IN.IGNORED);
        if (linux.errno(wd_rc) != .SUCCESS) {
            _ = linux.close(fd);
            return false;
        }
        self.fd = fd;
        self.wd = @intCast(wd_rc);
        return true;
    }

    pub fn pollFd(self: *const Watcher) i32 {
        return self.fd;
    }

    /// Adds one more directory to an already-watching fd. inotify is not
    /// recursive, so component subdirs (`<settings>/taskbar`, ...) need
    /// their own watches or edits inside them are never reported. Missing
    /// dirs are skipped (the settings app creates them on first save).
    /// Events from every watched dir drain through `drainAnyToml` together.
    pub fn watchExtraDir(self: *Watcher, dir_path: []const u8) bool {
        if (self.fd < 0) return false;
        var zbuf: [1024:0]u8 = [_:0]u8{0} ** 1024;
        if (dir_path.len + 1 > zbuf.len) return false;
        @memcpy(zbuf[0..dir_path.len], dir_path);
        const wd_rc = linux.inotify_add_watch(self.fd, &zbuf, linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVE | linux.IN.IGNORED);
        return linux.errno(wd_rc) == .SUCCESS;
    }

    /// True when any event fires that mentions `target_basename`, or a
    /// nameless directory event (the watch itself going away).
    pub fn drainChanged(self: *Watcher, target_basename: []const u8) bool {
        return self.drainMatching(&.{target_basename}, null);
    }

    /// True when any event fires that names one of `target_basenames`
    /// (nameless events count too). One pass over the queue: two back-to-back
    /// `drainChanged` calls would let the first swallow the other's events,
    /// since every drain empties the whole queue.
    pub fn drainAnyOf(self: *Watcher, target_basenames: []const []const u8) bool {
        return self.drainMatching(target_basenames, null);
    }

    /// True when any watched `*.toml` changed, or on a nameless event.
    /// Used for layered-config reloads, where many files can feed one load.
    pub fn drainAnyToml(self: *Watcher) bool {
        return self.drainMatching(null, ".toml");
    }

    /// True when any watched `*.toml` changed, any file named in `extra`
    /// changed, or a nameless event fires: the reload the layered config
    /// needs plus the hand-rolled stores that live beside the tomls.
    pub fn drainAnyLive(self: *Watcher, extra: []const []const u8) bool {
        return self.drainMatching(extra, ".toml");
    }

    /// Drains the inotify queue. Names with the suffix `ext` count as hits
    /// when `ext` is non-null, names equal to one of `targets` when `targets`
    /// is non-null; both may be given at once (`drainAnyLive`). A nameless
    /// event always counts: it means the watch was removed.
    fn drainMatching(self: *Watcher, targets: ?[]const []const u8, ext: ?[]const u8) bool {
        if (self.fd < 0) return false;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var hit = false;
        while (true) {
            const n: usize = linux.read(self.fd, &buf, buf.len);
            const s: isize = @bitCast(n);
            if (s <= 0) break;
            var off: usize = 0;
            const got: usize = @intCast(s);
            while (off + @sizeOf(linux.inotify_event) <= got) {
                var ev: linux.inotify_event = undefined;
                @memcpy(std.mem.asBytes(&ev), buf[off..][0..@sizeOf(linux.inotify_event)]);
                const name_len: usize = ev.len;
                if (name_len > 0 and off + @sizeOf(linux.inotify_event) + name_len <= got) {
                    const raw = buf[off + @sizeOf(linux.inotify_event) ..][0..name_len];
                    const name = std.mem.sliceTo(raw, 0);
                    if (ext) |e| {
                        if (std.mem.endsWith(u8, name, e)) hit = true;
                    }
                    if (targets) |list| {
                        for (list) |want| {
                            if (std.mem.eql(u8, name, want)) {
                                hit = true;
                                break;
                            }
                        }
                    }
                } else if (name_len == 0) {
                    hit = true;
                }
                const step = @sizeOf(linux.inotify_event) + name_len;
                if (step == 0) break;
                off += step;
            }
        }
        return hit;
    }

    pub fn close(self: *Watcher) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
            self.wd = -1;
        }
    }
};

test "watch: extra dirs share the fd" {
    const t = std.testing;
    var w = Watcher{};
    defer w.close();
    // No fd yet: extra watch is refused, never a crash.
    try t.expect(!w.watchExtraDir("/tmp"));
}

test "watch: drain on unwatched is quiet" {
    const t = std.testing;
    var w = Watcher{};
    defer w.close();
    try t.expect(!w.drainChanged("config.toml"));
    try t.expectEqual(@as(i32, -1), w.pollFd());
}

test "watch: detects file write" {
    const t = std.testing;
    const dir_path = "/tmp/eh-watch-test";
    var zdir: [64:0]u8 = [_:0]u8{0} ** 64;
    @memcpy(zdir[0..dir_path.len], dir_path);
    _ = std.os.linux.mkdir(&zdir, 0o755);
    defer {
        var fz: [128:0]u8 = [_:0]u8{0} ** 128;
        @memcpy(fz[0..dir_path.len], dir_path);
        @memcpy(fz[dir_path.len .. dir_path.len + 12], "/config.toml");
        _ = std.os.linux.unlink(&fz);
        _ = std.os.linux.rmdir(&zdir);
    }
    var w = Watcher{};
    defer w.close();
    try t.expect(w.watchConfigDir(dir_path));
    var fz2: [128:0]u8 = [_:0]u8{0} ** 128;
    @memcpy(fz2[0..dir_path.len], dir_path);
    @memcpy(fz2[dir_path.len .. dir_path.len + 12], "/config.toml");
    const cfd = std.os.linux.open(&fz2, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    if (std.os.linux.errno(cfd) == .SUCCESS) _ = std.os.linux.close(@intCast(cfd));
    var ticks: u32 = 0;
    var seen = false;
    while (ticks < 50 and !seen) : (ticks += 1) {
        if (w.drainChanged("config.toml")) seen = true;
        _ = std.posix.poll(&[_]std.posix.pollfd{}, 20) catch 0;
    }
    try t.expect(seen);
}

/// Create (recreate) `path` inside the watched dir and drain until one of
/// `targets` names it; false after ~1s of quiet — the unlisted-name case.
fn createThenDrain(w: *Watcher, path: [*:0]const u8, targets: []const []const u8) bool {
    _ = std.os.linux.unlink(path);
    const cfd = std.os.linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    if (std.os.linux.errno(cfd) == .SUCCESS) _ = std.os.linux.close(@intCast(cfd));
    var ticks: u32 = 0;
    while (ticks < 50) : (ticks += 1) {
        if (w.drainAnyOf(targets)) return true;
        _ = std.posix.poll(&[_]std.posix.pollfd{}, 20) catch 0;
    }
    return false;
}

/// Create (recreate) `path` inside the watched dir and drain until
/// `drainAnyLive` takes it; false after ~1s of quiet.
fn createThenDrainLive(w: *Watcher, path: [*:0]const u8) bool {
    _ = std.os.linux.unlink(path);
    const cfd = std.os.linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    if (std.os.linux.errno(cfd) == .SUCCESS) _ = std.os.linux.close(@intCast(cfd));
    var ticks: u32 = 0;
    while (ticks < 50) : (ticks += 1) {
        if (w.drainAnyLive(&live_extra_names)) return true;
        _ = std.posix.poll(&[_]std.posix.pollfd{}, 20) catch 0;
    }
    return false;
}

test "watch: drainAnyLive takes tomls and the named stores" {
    const t = std.testing;
    const dir_path = "/tmp/eh-watch-live-test";
    const other = dir_path ++ "/notes.txt";
    const toml = dir_path ++ "/dock.toml";
    const json = dir_path ++ "/world_clock.json";
    var zdir: [64:0]u8 = [_:0]u8{0} ** 64;
    @memcpy(zdir[0..dir_path.len], dir_path);
    _ = std.os.linux.mkdir(&zdir, 0o755);
    var zother: [96:0]u8 = [_:0]u8{0} ** 96;
    @memcpy(zother[0..other.len], other);
    var ztoml: [96:0]u8 = [_:0]u8{0} ** 96;
    @memcpy(ztoml[0..toml.len], toml);
    var zjson: [96:0]u8 = [_:0]u8{0} ** 96;
    @memcpy(zjson[0..json.len], json);
    defer {
        _ = std.os.linux.unlink(&zother);
        _ = std.os.linux.unlink(&ztoml);
        _ = std.os.linux.unlink(&zjson);
        _ = std.os.linux.rmdir(&zdir);
    }
    var w = Watcher{};
    defer w.close();
    try t.expect(w.watchConfigDir(dir_path));
    // A name that feeds nothing is drained and ignored; the toml stack and
    // the world-clock store both count.
    try t.expect(!createThenDrainLive(&w, &zother));
    try t.expect(createThenDrainLive(&w, &ztoml));
    try t.expect(createThenDrainLive(&w, &zjson));
}

test "watch: drainAnyOf hits only the listed names" {
    const t = std.testing;
    const dir_path = "/tmp/eh-watch-any-test";
    const other = dir_path ++ "/unlisted.toml";
    const wanted = dir_path ++ "/desktop_widgets.toml";
    var zdir: [64:0]u8 = [_:0]u8{0} ** 64;
    @memcpy(zdir[0..dir_path.len], dir_path);
    _ = std.os.linux.mkdir(&zdir, 0o755);
    var zother: [96:0]u8 = [_:0]u8{0} ** 96;
    @memcpy(zother[0..other.len], other);
    var zwant: [96:0]u8 = [_:0]u8{0} ** 96;
    @memcpy(zwant[0..wanted.len], wanted);
    defer {
        _ = std.os.linux.unlink(&zother);
        _ = std.os.linux.unlink(&zwant);
        _ = std.os.linux.rmdir(&zdir);
    }
    var w = Watcher{};
    defer w.close();
    try t.expect(w.watchConfigDir(dir_path));
    const targets = [_][]const u8{"desktop_widgets.toml"};
    // One queue, one pass: an unlisted name is drained and ignored, the
    // listed one hits. Two separate `drainChanged` calls could not tell
    // them apart — the first would eat the second's event.
    try t.expect(!createThenDrain(&w, &zother, &targets));
    try t.expect(createThenDrain(&w, &zwant, &targets));
}
