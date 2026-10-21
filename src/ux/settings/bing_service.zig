//! The Bing wallpaper worker — the Zig port of
//! `src/services/bing/bing_wallpaper.cpp`.
//!
//! Every operation here is a network round trip to GitHub plus, for a
//! download, one per image. None of that can happen on the input thread: the
//! settings window would freeze for as long as the fetch took. So one worker
//! thread runs one job at a time, exactly as the C++ `ThreadPool` enqueue does,
//! and the UI learns what happened through single-slot result fields it drains
//! once each.
//!
//! The worker wakes the event loop through an eventfd the window already
//! watches (`Win.bingWakeFd`), which is the same hand-off the wallpaper
//! thumbnail service uses. Like that service the queues are bounded and
//! guarded by a pthread mutex + condvar, and — as in the C++ — only one job
//! may be in flight: `checkUpdates`, `download` and `daily` each refuse to
//! start while another is running, which is what stops two downloads racing
//! on the same file.
//!
//! Results are plain structs with fixed-size string fields rather than owned
//! slices. A slot guarded by one mutex and read once by the UI never needs an
//! allocator, and a POD result cannot be double-freed by a confused caller.

const std = @import("std");
const linux = std.os.linux;
const c = @cImport(@cInclude("pthread.h"));
const bing = @import("../../services/bing.zig");
const archive = @import("../../services/bing_archive.zig");

/// The upstream README is a few hundred kilobytes of markdown; the cap only
/// exists so a hijacked URL cannot exhaust the heap.
pub const readme_max_bytes: usize = 8 << 20;
/// A UHD image is 1–3 MB. The cap bounds one job's peak, since the body is
/// held in memory while it is written out.
pub const image_max_bytes: usize = 24 << 20;

const path_cap = 1024;
const name_cap = 512;
const msg_cap = 256;
/// The block list travels with the job so the worker never reads state the
/// UI thread might be rewriting.
const keywords_cap = 4096;

pub const Kind = enum { check_updates, download, daily };

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// "How many wallpapers are missing" — `Check Now`.
pub const UpdatesResult = struct {
    ok: bool = false,
    new_count: i32 = 0,
    err: [msg_cap]u8 = undefined,
    err_len: u16 = 0,

    pub fn errorMsg(self: *const UpdatesResult) []const u8 {
        return self.err[0..self.err_len];
    }
};

/// One tick of a download, published after every file so the bar advances
/// live rather than at the end.
pub const ProgressResult = struct {
    current: i32 = 0,
    total: i32 = 0,
    found: i32 = 0,
    /// Name of the file that just landed, empty on the opening tick.
    last: [name_cap]u8 = undefined,
    last_len: u16 = 0,
    /// Only filled in when the selection matched nothing, so the user can see
    /// how recent the archive actually is.
    newest: [16]u8 = undefined,
    newest_len: u16 = 0,

    pub fn lastDownloaded(self: *const ProgressResult) []const u8 {
        return self.last[0..self.last_len];
    }

    pub fn newestAvailable(self: *const ProgressResult) []const u8 {
        return self.newest[0..self.newest_len];
    }
};

/// The tally once a download finishes.
pub const DoneResult = struct {
    ok: bool = false,
    downloaded: i32 = 0,
    skipped: i32 = 0,
    failed: i32 = 0,
};

/// The daily fetch: either the path of an image now on disk, or why not.
pub const DailyResult = struct {
    ok: bool = false,
    path: [path_cap]u8 = undefined,
    path_len: u16 = 0,
    err: [msg_cap]u8 = undefined,
    err_len: u16 = 0,

    pub fn localPath(self: *const DailyResult) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn errorMsg(self: *const DailyResult) []const u8 {
        return self.err[0..self.err_len];
    }
};

fn setMsg(buf: []u8, len: *u16, s: []const u8) void {
    const n: u16 = @intCast(@min(s.len, buf.len));
    @memcpy(buf[0..n], s[0..n]);
    len.* = n;
}

// ---------------------------------------------------------------------------
// Job
// ---------------------------------------------------------------------------

const Job = struct {
    kind: Kind = .check_updates,
    dir: [path_cap]u8 = undefined,
    dir_len: u16 = 0,
    filter: archive.Filter = .all,
    /// `YYYY-MM` for `Filter.custom`.
    month: [7]u8 = undefined,
    month_len: u8 = 0,
    use_cache: bool = true,
    keywords: [keywords_cap]u8 = undefined,
    keywords_len: u16 = 0,
};

pub const Service = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// eventfd the window watches; written once a job publishes something.
    wake_fd: i32 = -1,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    thread: ?std.Thread = null,
    ready: bool = false,

    stop: bool = false,
    /// Set by the launcher, cleared by the worker — so `busy()` is true the
    /// moment a button is pressed, not one scheduling round later.
    running: bool = false,
    pending: ?Job = null,

    updates: ?UpdatesResult = null,
    progress: ?ProgressResult = null,
    done: ?DoneResult = null,
    daily: ?DailyResult = null,

    /// The raw comma-separated keyword list, owned and replaced wholesale by
    /// the UI thread. Copied into each job so the worker holds its own copy.
    keywords_raw: []u8 = &.{},

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Service {
        var self = Service{ .alloc = alloc, .io = io };
        _ = c.pthread_mutex_init(&self.mutex, null);
        _ = c.pthread_cond_init(&self.cond, null);
        self.ready = true;
        const rc: isize = @bitCast(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        if (rc >= 0) self.wake_fd = @intCast(rc);
        return self;
    }

    pub fn deinit(self: *Service) void {
        if (self.thread) |t| {
            self.lock();
            self.stop = true;
            _ = c.pthread_cond_signal(&self.cond);
            self.unlock();
            t.join();
            self.thread = null;
        }
        if (self.keywords_raw.len > 0) self.alloc.free(self.keywords_raw);
        self.keywords_raw = &.{};
        if (self.wake_fd >= 0) {
            _ = linux.close(self.wake_fd);
            self.wake_fd = -1;
        }
        if (self.ready) {
            _ = c.pthread_cond_destroy(&self.cond);
            _ = c.pthread_mutex_destroy(&self.mutex);
            self.ready = false;
        }
    }

    fn lock(self: *Service) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }

    fn unlock(self: *Service) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    /// The fd the event loop polls for a finished (or part-finished) job.
    pub fn wakeFd(self: *const Service) i32 {
        return self.wake_fd;
    }

    /// Consume the wake counter. The results themselves are read by the
    /// `take*` methods; this only says "there is something new".
    pub fn drainWake(self: *const Service) void {
        if (self.wake_fd < 0) return;
        var buf: [8]u8 = undefined;
        while (true) {
            const n: usize = linux.read(self.wake_fd, &buf, buf.len);
            // `linux.read` encodes an errno as a very large *unsigned* value,
            // so a `> 0` guard never fires on EAGAIN — and the fd is
            // non-blocking, so an empty counter is exactly that. Stop on
            // anything that is not a whole eventfd record instead.
            if (n != buf.len) return;
        }
    }

    fn ping(self: *Service) void {
        self.lock();
        defer self.unlock();
        self.pingLocked();
    }

    fn pingLocked(self: *Service) void {
        if (self.wake_fd < 0) return;
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, @ptrCast(&one), @sizeOf(u64));
    }

    // -- UI-facing state ----------------------------------------------------

    /// True while a job is queued or running — what every button's disabled
    /// state keys on.
    pub fn busy(self: *Service) bool {
        self.lock();
        defer self.unlock();
        return self.running or self.pending != null;
    }

    /// Replace the block list. An empty string clears it.
    pub fn setKeywords(self: *Service, raw: []const u8) void {
        self.lock();
        defer self.unlock();
        if (self.keywords_raw.len > 0) self.alloc.free(self.keywords_raw);
        self.keywords_raw = self.alloc.dupe(u8, raw) catch &.{};
    }

    pub fn takeUpdates(self: *Service) ?UpdatesResult {
        self.lock();
        defer self.unlock();
        const r = self.updates;
        self.updates = null;
        return r;
    }

    pub fn takeProgress(self: *Service) ?ProgressResult {
        self.lock();
        defer self.unlock();
        const r = self.progress;
        self.progress = null;
        return r;
    }

    pub fn takeDone(self: *Service) ?DoneResult {
        self.lock();
        defer self.unlock();
        const r = self.done;
        self.done = null;
        return r;
    }

    pub fn takeDaily(self: *Service) ?DailyResult {
        self.lock();
        defer self.unlock();
        const r = self.daily;
        self.daily = null;
        return r;
    }

    // -- Launchers ----------------------------------------------------------

    pub fn checkUpdatesAsync(self: *Service, dir: []const u8) bool {
        return self.launch(.{ .kind = .check_updates }, dir);
    }

    pub fn downloadAsync(self: *Service, dir: []const u8, filter: archive.Filter, month: []const u8) bool {
        var job: Job = .{ .kind = .download, .filter = filter };
        const n: u8 = @intCast(@min(month.len, job.month.len));
        @memcpy(job.month[0..n], month[0..n]);
        job.month_len = n;
        return self.launch(job, dir);
    }

    pub fn dailyAsync(self: *Service, dir: []const u8, use_cache: bool) bool {
        return self.launch(.{ .kind = .daily, .use_cache = use_cache }, dir);
    }

    fn launch(self: *Service, template: Job, dir: []const u8) bool {
        self.lock();
        defer self.unlock();
        if (self.running or self.pending != null) return false;

        var job = template;
        const n: u16 = @intCast(@min(dir.len, job.dir.len));
        @memcpy(job.dir[0..n], dir[0..n]);
        job.dir_len = n;
        const kw: u16 = @intCast(@min(self.keywords_raw.len, job.keywords.len));
        @memcpy(job.keywords[0..kw], self.keywords_raw[0..kw]);
        job.keywords_len = kw;

        self.running = true;
        self.pending = job;
        if (self.thread == null) {
            self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
            if (self.thread == null) {
                self.running = false;
                self.pending = null;
                return false;
            }
        }
        _ = c.pthread_cond_signal(&self.cond);
        return true;
    }

    // -- Worker -------------------------------------------------------------

    fn run(self: *Service) void {
        while (true) {
            self.lock();
            while (self.pending == null and !self.stop) {
                _ = c.pthread_cond_wait(&self.cond, &self.mutex);
            }
            if (self.stop) {
                self.unlock();
                return;
            }
            const job = self.pending.?;
            self.pending = null;
            self.unlock();

            self.exec(job);

            self.lock();
            self.running = false;
            self.unlock();
            self.ping();
        }
    }

    fn exec(self: *Service, job: Job) void {
        // Everything the job allocates dies here: the parsed catalogue, the
        // filter's subsets, the keyword split and each downloaded body.
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const dir = job.dir[0..job.dir_len];
        const keywords = archive.splitKeywords(a, job.keywords[0..job.keywords_len]) catch @as([][]u8, &.{});

        switch (job.kind) {
            .check_updates => {
                var r: UpdatesResult = .{};
                self.doCheckUpdates(a, dir, keywords, &r);
                self.lock();
                self.updates = r;
                self.unlock();
            },
            .download => {
                const r = self.doDownload(a, dir, job.filter, job.month[0..job.month_len], keywords);
                self.lock();
                self.done = r;
                self.unlock();
            },
            .daily => {
                const r = self.doDaily(a, dir, job.use_cache, keywords);
                self.lock();
                self.daily = r;
                self.unlock();
            },
        }
    }

    // -- Operations ---------------------------------------------------------

    /// `mode_check_updates`: always re-fetch the README, cache the result, and
    /// count the entries that are not on disk yet.
    fn doCheckUpdates(
        self: *Service,
        a: std.mem.Allocator,
        dir: []const u8,
        keywords: []const []const u8,
        out: *UpdatesResult,
    ) void {
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};

        const md = bing.fetchText(a, self.io, archive.readme_url, readme_max_bytes) catch {
            setMsg(&out.err, &out.err_len, "Failed to fetch README from GitHub");
            return;
        };
        if (md.len == 0) {
            setMsg(&out.err, &out.err_len, "Failed to fetch README from GitHub");
            return;
        }
        const items = archive.parseReadme(a, md, dir) catch {
            setMsg(&out.err, &out.err_len, "Failed to parse the archive README");
            return;
        };
        self.saveCacheQuietly(a, items);

        var on_disk = archive.localFilenames(a, self.io, dir) catch blk: {
            break :blk std.StringHashMapUnmanaged(void){};
        };
        defer on_disk.deinit(a);

        var count: i32 = 0;
        for (items) |*e| {
            if (archive.matchesBlocklist(e, keywords)) continue;
            if (!on_disk.contains(e.filename)) count += 1;
        }
        out.new_count = count;
        out.ok = true;
    }

    /// `mode_download`: fetch (or fall back to the cache), narrow to the
    /// filter, drop anything blocked, and pull down what is missing. Progress
    /// is published after every file so the bar moves in real time.
    fn doDownload(
        self: *Service,
        a: std.mem.Allocator,
        dir: []const u8,
        filter: archive.Filter,
        month: []const u8,
        keywords: []const []const u8,
    ) DoneResult {
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};

        var fetch_failed = false;
        var items: []archive.Entry = &.{};
        if (bing.fetchText(a, self.io, archive.readme_url, readme_max_bytes)) |md| {
            if (md.len > 0) {
                items = archive.parseReadme(a, md, dir) catch @as([]archive.Entry, &.{});
                self.saveCacheQuietly(a, items);
            } else fetch_failed = true;
        } else |_| fetch_failed = true;
        if (fetch_failed) {
            items = archive.loadCache(a, self.io, self.cachePath(a), dir) catch null orelse
                @as([]archive.Entry, &.{});
        }

        const selected = archive.filterEntries(a, items, filter, month) catch @as([]archive.Entry, &.{});
        var on_disk = archive.localFilenames(a, self.io, dir) catch blk: {
            break :blk std.StringHashMapUnmanaged(void){};
        };
        defer on_disk.deinit(a);

        var filtered: std.ArrayList(*const archive.Entry) = .empty;
        for (selected) |*e| {
            if (!archive.matchesBlocklist(e, keywords)) filtered.append(a, e) catch {};
        }

        var to_fetch: std.ArrayList(*const archive.Entry) = .empty;
        for (filtered.items) |e| {
            if (!on_disk.contains(e.filename)) to_fetch.append(a, e) catch {};
        }

        const total: i32 = @intCast(to_fetch.items.len);
        const already: i32 = @as(i32, @intCast(filtered.items.len)) - total;
        const found: i32 = @intCast(filtered.items.len);

        // Opening tick: the totals, and — when the filter matched nothing —
        // how new the archive is, which is the only clue the user gets.
        {
            var pr: ProgressResult = .{ .current = 0, .total = total, .found = found };
            if (found == 0 and items.len > 0) {
                setMsg(&pr.newest, &pr.newest_len, items[0].date);
            }
            self.lock();
            self.progress = pr;
            self.unlock();
            self.ping();
        }

        if (total == 0) {
            return .{
                .ok = !fetch_failed,
                .downloaded = 0,
                .skipped = already,
                .failed = 0,
            };
        }

        var downloaded: i32 = 0;
        var skipped: i32 = 0;
        var failed: i32 = 0;
        var i: i32 = 0;
        while (i < total) : (i += 1) {
            const e = to_fetch.items[@intCast(i)];
            const existed = exists(self.io, e.local_path);
            var ok = false;
            if (existed) {
                skipped += 1;
                ok = true;
            } else {
                ok = self.downloadOne(a, e.url, e.local_path);
                if (ok) downloaded += 1 else failed += 1;
            }

            var pr: ProgressResult = .{
                .current = i + 1,
                .total = total,
                .found = found,
            };
            if (ok and !existed) setMsg(&pr.last, &pr.last_len, e.filename);
            self.lock();
            self.progress = pr;
            self.unlock();
            self.ping();
        }

        return .{
            .ok = failed == 0,
            .downloaded = downloaded,
            .skipped = skipped,
            .failed = failed,
        };
    }

    /// `mode_daily`: the newest non-blocked entry, downloaded if it is not
    /// already there. `use_cache` lets the daily timer skip GitHub when the
    /// cached catalogue already covers this month.
    fn doDaily(
        self: *Service,
        a: std.mem.Allocator,
        dir: []const u8,
        use_cache: bool,
        keywords: []const []const u8,
    ) DailyResult {
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};

        const cache_path = self.cachePath(a);
        var items: []archive.Entry = &.{};
        var loaded = false;

        if (use_cache) {
            if (archive.loadCache(a, self.io, cache_path, dir) catch null) |cached| {
                items = cached;
                loaded = true;
                // The catalogue is sorted newest-first, so a cache that has
                // no entry from this month is stale.
                if (items.len > 0) {
                    var cur: [7]u8 = undefined;
                    if (!std.mem.eql(u8, items[0].month, archive.currentYm(&cur))) {
                        items = &.{};
                        loaded = false;
                    }
                } else loaded = false;
            }
        }
        if (!loaded or items.len == 0) {
            const md = bing.fetchText(a, self.io, archive.readme_url, readme_max_bytes) catch {
                var r: DailyResult = .{};
                setMsg(&r.err, &r.err_len, "Failed to fetch README");
                return r;
            };
            if (md.len == 0) {
                var r: DailyResult = .{};
                setMsg(&r.err, &r.err_len, "Failed to fetch README");
                return r;
            }
            items = archive.parseReadme(a, md, dir) catch @as([]archive.Entry, &.{});
            self.saveCacheQuietly(a, items);
        }
        if (items.len == 0) {
            var r: DailyResult = .{};
            setMsg(&r.err, &r.err_len, "No wallpapers in cache");
            return r;
        }

        var chosen: ?*const archive.Entry = null;
        for (items) |*e| {
            if (!archive.matchesBlocklist(e, keywords)) {
                chosen = e;
                break;
            }
        }
        const entry = chosen orelse {
            var r: DailyResult = .{};
            setMsg(&r.err, &r.err_len, "No non-blocked wallpapers available");
            return r;
        };

        if (!exists(self.io, entry.local_path) and !self.downloadOne(a, entry.url, entry.local_path)) {
            var r: DailyResult = .{};
            var msg_buf: [msg_cap]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Download failed for {s}", .{entry.filename}) catch
                "Download failed";
            setMsg(&r.err, &r.err_len, msg);
            return r;
        }
        var ok: DailyResult = .{ .ok = true };
        setMsg(&ok.path, &ok.path_len, entry.local_path);
        return ok;
    }

    // -- Primitives ---------------------------------------------------------

    fn cachePath(_: *Service, a: std.mem.Allocator) []const u8 {
        const xdg: ?[]const u8 = env("XDG_CACHE_HOME");
        const home: ?[]const u8 = env("HOME");
        return archive.cacheFilePath(a, xdg, home) catch "";
    }

    fn saveCacheQuietly(self: *Service, a: std.mem.Allocator, items: []const archive.Entry) void {
        const path = self.cachePath(a);
        if (path.len == 0) return;
        archive.saveCache(a, self.io, path, items) catch {};
    }

    /// Pull one image down to `dest`. Mirrors `curl_download_file`: a symlink
    /// at the destination is unlinked rather than written through, and the
    /// file lands owner-only.
    fn downloadOne(self: *Service, a: std.mem.Allocator, url: []const u8, dest: []const u8) bool {
        if (url.len == 0 or dest.len == 0) return false;
        // `readLink` succeeding is exactly "this path is a symlink", which is
        // what the C++'s `lstat` + `S_ISLNK` check looks for.
        var probe: [8]u8 = undefined;
        if (std.Io.Dir.cwd().readLink(self.io, dest, &probe)) |_| {
            std.Io.Dir.cwd().deleteFile(self.io, dest) catch return false;
        } else |_| {}

        const body = bing.fetchText(a, self.io, url, image_max_bytes) catch return false;
        if (body.len == 0) return false;

        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = dest,
            .data = body,
            .flags = .{
                .truncate = true,
                .permissions = std.Io.File.Permissions.fromMode(0o600),
            },
        }) catch return false;
        return true;
    }
};

/// True when `path` is there for any reason other than "not found" — a
/// permission problem counts as present, matching how the C++ treats an
/// `fs::exists` that cannot be answered.
fn exists(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| return true else |e| return e != error.FileNotFound;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bing-service: results carry their strings without an allocator" {
    const t = std.testing;
    var p: ProgressResult = .{ .current = 3, .total = 12, .found = 40 };
    setMsg(&p.last, &p.last_len, "OHR.Sample_UHD.jpg");
    try t.expectEqualStrings("OHR.Sample_UHD.jpg", p.lastDownloaded());
    try t.expectEqual(@as(i32, 3), p.current);

    var d: DailyResult = .{};
    setMsg(&d.path, &d.path_len, "/home/u/Pictures/BingWallpaper/x_UHD.jpg");
    try t.expectEqualStrings("/home/u/Pictures/BingWallpaper/x_UHD.jpg", d.localPath());
}

test "bing-service: setMsg truncates rather than overflowing" {
    const t = std.testing;
    var buf: [4]u8 = undefined;
    var len: u16 = 0;
    setMsg(&buf, &len, "abcdefgh");
    try t.expectEqual(@as(u16, 4), len);
    try t.expectEqualStrings("abcd", buf[0..len]);
    // Overwrites in place and resets the length, so a second message does not
    // append to the first.
    setMsg(&buf, &len, "z");
    try t.expectEqual(@as(u16, 1), len);
    try t.expectEqualStrings("z", buf[0..len]);
}

test "bing-service: only one job may be in flight" {
    const t = std.testing;
    var svc = Service.init(t.allocator, std.testing.io);
    defer svc.deinit();
    // Point the dir somewhere real but harmless; nothing is fetched because
    // the second launch is refused before the worker can start.
    // Stand in for a running job so the guard is exercised without ever
    // spawning the worker — that would fetch the real README off GitHub.
    svc.running = true;
    try t.expect(svc.busy());
    try t.expect(!svc.checkUpdatesAsync("/tmp/x"));
    try t.expect(!svc.downloadAsync("/tmp/x", .all, ""));
    try t.expect(!svc.dailyAsync("/tmp/x", true));
    svc.running = false;
    try t.expect(!svc.busy());
}

test "bing-service: the block list survives being handed to a job" {
    const t = std.testing;
    var svc = Service.init(t.allocator, std.testing.io);
    defer svc.deinit();
    svc.setKeywords("cat, dog");
    try t.expectEqualStrings("cat, dog", svc.keywords_raw);
    svc.setKeywords("");
    try t.expectEqual(@as(usize, 0), svc.keywords_raw.len);
}
