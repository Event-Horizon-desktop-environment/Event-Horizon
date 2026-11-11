//! The Event Horizon update worker.
//!
//! The settings window cannot do any of this on the input thread: checking
//! GitHub is an HTTPS round trip, the package can be tens of megabytes, and
//! `pkexec` blocks until the user types a password in the polkit dialog. So
//! one worker thread runs one job at a time, exactly like `bing_service`, and
//! the UI learns what happened through single-slot result fields it drains
//! once each. The worker wakes the event loop through the eventfd the window
//! already watches (`Win.updWakeFd`).
//!
//! Flow, matching the design in `Updater/event-horizon-updates.html`:
//!
//!     check    → latest GitHub release, the asset that matches this distro,
//!                the version compare against `version.zig`, the release body
//!     download → streamed to ~/.cache/event-horizon/updates/, hashed with
//!                SHA-256 as it lands, compared against the release `digest`
//!     install  → `pkexec` + the distro's package manager
//!     restart  → a detached shell stops the supervisor and starts it again
//!
//! Results are POD structs with fixed-size buffers. A slot behind one mutex
//! that the UI reads once never needs an allocator, and cannot be double
//! freed by a confused caller.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c_pthread");
const bing = @import("../../services/bing.zig");
const version = @import("../../version.zig");

/// The API endpoint the check uses. The HTML links the user at `releases_page`
/// when they want to read a release on the web.
pub const releases_api = "https://api.github.com/repos/Event-Horizon-desktop-environment/Event-Horizon/releases/latest";
pub const releases_page = "https://github.com/Event-Horizon-desktop-environment/Event-Horizon/releases";

/// The release document is a few kilobytes; the cap only exists so a hijacked
/// URL cannot exhaust the heap.
pub const release_json_max: usize = 1 << 20;
/// The largest package we accept. The real ones are ~10–40 MB.
pub const package_max: usize = 512 << 20;

pub const notes_cap: usize = 4096;
const path_cap = 1024;
const name_cap = 256;
const url_cap = 1024;
const digest_cap = 80;
const msg_cap = 256;
const version_cap = 32;

/// Which package format this machine installs.
pub const PackageKind = enum {
    arch,
    deb,
    rpm,

    /// The word the page's footer and status text use.
    pub fn label(self: PackageKind) []const u8 {
        return switch (self) {
            .arch => "Arch package (.pkg.tar.zst)",
            .deb => "Debian package (.deb)",
            .rpm => "RPM package (.rpm)",
        };
    }

    pub fn shortLabel(self: PackageKind) []const u8 {
        return switch (self) {
            .arch => "pacman",
            .deb => "apt",
            .rpm => "dnf",
        };
    }
};

/// A parsed `major.minor.patch`. Pre-release suffixes are ignored, which is
/// what the release tags use (`0.1.4`).
pub const Version = struct { major: u32 = 0, minor: u32 = 0, patch: u32 = 0 };

/// Parse `"v1.2.3"`, `"1.2"` or `"1.2.3-beta"`. Returns null when the first
/// component is not a number.
pub fn parseVersion(s: []const u8) ?Version {
    var t = s;
    while (t.len > 0 and (t[0] == 'v' or t[0] == 'V' or t[0] == ' ')) t = t[1..];
    var out: Version = .{};
    var field: usize = 0;
    var it = std.mem.splitScalar(u8, t, '.');
    while (it.next()) |raw| {
        // A suffix on the last component (`4-rc1`) still counts as the number
        // before it.
        var end: usize = 0;
        while (end < raw.len and std.ascii.isDigit(raw[end])) end += 1;
        if (end == 0) break;
        const n = std.fmt.parseInt(u32, raw[0..end], 10) catch break;
        switch (field) {
            0 => out.major = n,
            1 => out.minor = n,
            else => out.patch = n,
        }
        field += 1;
        if (field == 3) break;
    }
    if (field == 0) return null;
    return out;
}

/// Numeric ordering, not string ordering: 0.10.0 is newer than 0.9.0.
pub fn compareVersions(a: Version, b: Version) std.math.Order {
    if (a.major != b.major) return if (a.major < b.major) .lt else .gt;
    if (a.minor != b.minor) return if (a.minor < b.minor) .lt else .gt;
    if (a.patch != b.patch) return if (a.patch < b.patch) .lt else .gt;
    return .eq;
}

/// True when `remote` is a newer release than `local`.
pub fn isNewer(local: []const u8, remote: []const u8) bool {
    const l = parseVersion(local) orelse return false;
    const r = parseVersion(remote) orelse return false;
    return compareVersions(l, r) == .lt;
}

/// Map an asset filename to the package format it carries. `.tar.gz` matches
/// nothing: it is the portable tarball, not something a package manager owns.
pub fn assetKind(name: []const u8) ?PackageKind {
    if (std.mem.endsWith(u8, name, ".pkg.tar.zst")) return .arch;
    if (std.mem.endsWith(u8, name, ".deb")) return .deb;
    if (std.mem.endsWith(u8, name, ".rpm")) return .rpm;
    return null;
}

fn tokenMatches(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) continue;
        return true;
    }
    return false;
}

/// Detect the package format from an `/etc/os-release` document. `ID` and
/// `ID_LIKE` are enough: Fedora/RHEL and their children use `rpm`, Arch and
/// Manjaro `pacman`, and everything else falls back to `.deb`, which is what
/// the design asks for ("Debian and others").
pub fn packageKindFromOsRelease(text: []const u8) PackageKind {
    var rpm = false;
    var arch = false;
    var deb = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        if (!std.mem.eql(u8, key, "ID") and !std.mem.eql(u8, key, "ID_LIKE")) continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'')) value = value[1 .. value.len - 1];
        if (tokenMatches(value, "fedora") or
            tokenMatches(value, "rhel") or
            tokenMatches(value, "centos") or
            tokenMatches(value, "rocky") or
            tokenMatches(value, "almalinux") or
            tokenMatches(value, "suse"))
        {
            rpm = true;
        }
        if (tokenMatches(value, "arch") or tokenMatches(value, "manjaro")) arch = true;
        if (tokenMatches(value, "debian") or tokenMatches(value, "ubuntu")) deb = true;
    }
    // A distro whose ID_LIKE names both (EndeavourOS says "arch") still gets
    // one answer; rpm wins because no RPM distro also claims Arch.
    if (rpm) return .rpm;
    if (arch) return .arch;
    if (deb) return .deb;
    return .deb;
}

/// Read `/etc/os-release` (falling back to `/usr/lib/os-release`) and map it.
pub fn detectKind(io: std.Io, alloc: std.mem.Allocator) PackageKind {
    const cwd = std.Io.Dir.cwd();
    const paths = [_][]const u8{ "/etc/os-release", "/usr/lib/os-release" };
    for (paths) |p| {
        if (cwd.readFileAlloc(io, p, alloc, .limited(1 << 16))) |text| {
            defer alloc.free(text);
            return packageKindFromOsRelease(text);
        } else |_| {}
    }
    return .deb;
}

/// One asset out of a release document, copied into fixed buffers.
pub const Asset = struct {
    name: [name_cap]u8 = undefined,
    name_len: u16 = 0,
    url: [url_cap]u8 = undefined,
    url_len: u16 = 0,
    digest: [digest_cap]u8 = undefined,
    digest_len: u16 = 0,
    size: u64 = 0,
    kind: PackageKind = .deb,

    pub fn nameSlice(self: *const Asset) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn urlSlice(self: *const Asset) []const u8 {
        return self.url[0..self.url_len];
    }
    pub fn digestSlice(self: *const Asset) []const u8 {
        return self.digest[0..self.digest_len];
    }
};

pub const Release = struct {
    tag: [version_cap]u8 = undefined,
    tag_len: u16 = 0,
    notes: [notes_cap]u8 = undefined,
    notes_len: u16 = 0,

    pub fn tagSlice(self: *const Release) []const u8 {
        return self.tag[0..self.tag_len];
    }
    pub fn notesSlice(self: *const Release) []const u8 {
        return self.notes[0..self.notes_len];
    }
};

fn setMsg(buf: []u8, len: *u16, s: []const u8) void {
    const n: u16 = @intCast(@min(s.len, buf.len));
    @memcpy(buf[0..n], s[0..n]);
    len.* = n;
}

fn textField(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(key) orelse return "";
    if (f != .string) return "";
    return f.string;
}

/// Parse the `releases/latest` document into the two things the page needs:
/// the tag/body, and the one asset matching `kind`.
pub fn parseRelease(alloc: std.mem.Allocator, json_text: []const u8, kind: PackageKind) !struct { release: Release, asset: ?Asset } {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.BadJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.BadJson;

    var out = struct { release: Release, asset: ?Asset }{ .release = .{}, .asset = null };
    const tag = textField(root, "tag_name");
    if (tag.len == 0) return error.NoTag;
    setMsg(&out.release.tag, &out.release.tag_len, tag);

    const body = textField(root, "body");
    if (body.len > 0) {
        // The body is markdown written for GitHub. Keep it as-is; the page
        // strips list markers when it draws.
        setMsg(&out.release.notes, &out.release.notes_len, body);
    }

    const assets = root.object.get("assets") orelse return .{ .release = out.release, .asset = null };
    if (assets != .array) return .{ .release = out.release, .asset = null };
    for (assets.array.items) |item| {
        if (item != .object) continue;
        const name = textField(item, "name");
        const k = assetKind(name) orelse continue;
        if (k != kind) continue;
        const url = textField(item, "browser_download_url");
        if (url.len == 0) continue;
        var a: Asset = .{ .kind = k };
        setMsg(&a.name, &a.name_len, name);
        setMsg(&a.url, &a.url_len, url);
        const digest = textField(item, "digest");
        if (digest.len > 0) setMsg(&a.digest, &a.digest_len, digest);
        if (item.object.get("size")) |sz| {
            if (sz == .integer and sz.integer > 0) a.size = @intCast(sz.integer);
        }
        out.asset = a;
        break;
    }
    return .{ .release = out.release, .asset = out.asset };
}

/// `sha256:<hex>` → the 32 raw bytes. Anything else yields null, which the
/// caller treats as "no digest published, skip verification".
pub fn parseDigestHex(s: []const u8) ?[32]u8 {
    var hex = s;
    if (std.mem.startsWith(u8, hex, "sha256:")) hex = hex["sha256:".len..];
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = std.fmt.charToDigit(hex[i * 2], 16) catch return null;
        const lo = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

/// Build the argv for the install step. The path is a single argv element, so
/// no shell is involved and a filename cannot inject anything.
pub fn installArgv(kind: PackageKind, path: []const u8, buf: *[8][]const u8) []const []const u8 {
    switch (kind) {
        .arch => {
            buf[0] = "pkexec";
            buf[1] = "pacman";
            buf[2] = "-U";
            buf[3] = "--noconfirm";
            buf[4] = path;
            return buf[0..5];
        },
        .deb => {
            buf[0] = "pkexec";
            buf[1] = "apt-get";
            buf[2] = "install";
            buf[3] = "-y";
            buf[4] = path;
            return buf[0..5];
        },
        .rpm => {
            buf[0] = "pkexec";
            buf[1] = "dnf";
            buf[2] = "install";
            buf[3] = "-y";
            buf[4] = path;
            return buf[0..5];
        },
    }
}

// Results

pub const CheckResult = struct {
    ok: bool = false,
    has_update: bool = false,
    current: [version_cap]u8 = undefined,
    current_len: u16 = 0,
    latest: [version_cap]u8 = undefined,
    latest_len: u16 = 0,
    notes: [notes_cap]u8 = undefined,
    notes_len: u16 = 0,
    asset: Asset = .{},
    has_asset: bool = false,
    err: [msg_cap]u8 = undefined,
    err_len: u16 = 0,

    pub fn errorMsg(self: *const CheckResult) []const u8 {
        return self.err[0..self.err_len];
    }
};

pub const ProgressResult = struct {
    got: u64 = 0,
    total: u64 = 0,
};

pub const DownloadResult = struct {
    ok: bool = false,
    path: [path_cap]u8 = undefined,
    path_len: u16 = 0,
    got: u64 = 0,
    err: [msg_cap]u8 = undefined,
    err_len: u16 = 0,

    pub fn localPath(self: *const DownloadResult) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn errorMsg(self: *const DownloadResult) []const u8 {
        return self.err[0..self.err_len];
    }
};

pub const InstallResult = struct {
    ok: bool = false,
    err: [msg_cap]u8 = undefined,
    err_len: u16 = 0,

    pub fn errorMsg(self: *const InstallResult) []const u8 {
        return self.err[0..self.err_len];
    }
};

// Job

const Kind = enum { check, download, install };

const Job = struct {
    kind: Kind = .check,
    pkg: PackageKind = .deb,
    url: [url_cap]u8 = undefined,
    url_len: u16 = 0,
    dest: [path_cap]u8 = undefined,
    dest_len: u16 = 0,
    digest: [digest_cap]u8 = undefined,
    digest_len: u16 = 0,
    size: u64 = 0,
    path: [path_cap]u8 = undefined,
    path_len: u16 = 0,
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
    /// Set by the launcher, cleared by the worker, so `busy()` is true the
    /// moment a button is pressed.
    running: bool = false,
    pending: ?Job = null,

    check: ?CheckResult = null,
    progress: ?ProgressResult = null,
    download: ?DownloadResult = null,
    install: ?InstallResult = null,

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

    pub fn wakeFd(self: *const Service) i32 {
        return self.wake_fd;
    }

    pub fn drainWake(self: *const Service) void {
        if (self.wake_fd < 0) return;
        var buf: [8]u8 = undefined;
        while (true) {
            const n: usize = linux.read(self.wake_fd, &buf, buf.len);
            // Non-blocking eventfd: anything other than a whole record is
            // EAGAIN, including the encoded errno.
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

    pub fn busy(self: *Service) bool {
        self.lock();
        defer self.unlock();
        return self.running or self.pending != null;
    }

    pub fn takeCheck(self: *Service) ?CheckResult {
        self.lock();
        defer self.unlock();
        const r = self.check;
        self.check = null;
        return r;
    }

    pub fn takeProgress(self: *Service) ?ProgressResult {
        self.lock();
        defer self.unlock();
        const r = self.progress;
        self.progress = null;
        return r;
    }

    pub fn takeDownload(self: *Service) ?DownloadResult {
        self.lock();
        defer self.unlock();
        const r = self.download;
        self.download = null;
        return r;
    }

    pub fn takeInstall(self: *Service) ?InstallResult {
        self.lock();
        defer self.unlock();
        const r = self.install;
        self.install = null;
        return r;
    }

    // -- Launchers ----------------------------------------------------------

    pub fn checkAsync(self: *Service, pkg: PackageKind) bool {
        return self.launch(.{ .kind = .check, .pkg = pkg });
    }

    pub fn downloadAsync(self: *Service, url: []const u8, dest: []const u8, digest: []const u8, size: u64) bool {
        var job: Job = .{ .kind = .download, .size = size };
        const un: u16 = @intCast(@min(url.len, job.url.len));
        @memcpy(job.url[0..un], url[0..un]);
        job.url_len = un;
        const dn: u16 = @intCast(@min(dest.len, job.dest.len));
        @memcpy(job.dest[0..dn], dest[0..dn]);
        job.dest_len = dn;
        const gn: u16 = @intCast(@min(digest.len, job.digest.len));
        @memcpy(job.digest[0..gn], digest[0..gn]);
        job.digest_len = gn;
        return self.launch(job);
    }

    pub fn installAsync(self: *Service, pkg: PackageKind, path: []const u8) bool {
        var job: Job = .{ .kind = .install, .pkg = pkg };
        const n: u16 = @intCast(@min(path.len, job.path.len));
        @memcpy(job.path[0..n], path[0..n]);
        job.path_len = n;
        return self.launch(job);
    }

    fn launch(self: *Service, job: Job) bool {
        self.lock();
        defer self.unlock();
        if (self.running or self.pending != null) return false;
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
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        switch (job.kind) {
            .check => {
                const r = self.doCheck(arena.allocator(), job.pkg);
                self.lock();
                self.check = r;
                self.unlock();
            },
            .download => {
                const r = self.doDownload(arena.allocator(), job);
                self.lock();
                self.download = r;
                self.unlock();
            },
            .install => {
                const r = self.doInstall(job);
                self.lock();
                self.install = r;
                self.unlock();
            },
        }
    }

    // -- Operations ---------------------------------------------------------

    fn doCheck(self: *Service, a: std.mem.Allocator, pkg: PackageKind) CheckResult {
        var r: CheckResult = .{};
        setMsg(&r.current, &r.current_len, version.string);

        const body = bing.fetchText(a, self.io, releases_api, release_json_max) catch {
            setMsg(&r.err, &r.err_len, "Could not reach api.github.com. Check your connection.");
            return r;
        };
        defer a.free(body);

        const parsed = parseRelease(a, body, pkg) catch {
            setMsg(&r.err, &r.err_len, "Could not read the latest release from GitHub.");
            return r;
        };
        const rel = parsed.release;
        setMsg(&r.latest, &r.latest_len, rel.tagSlice());
        setMsg(&r.notes, &r.notes_len, rel.notesSlice());

        if (parsed.asset) |asset| {
            r.asset = asset;
            r.has_asset = true;
        }
        r.ok = true;
        r.has_update = isNewer(version.string, rel.tagSlice());
        if (r.has_update and !r.has_asset) {
            // A newer tag with no package for this distro is still "no
            // update we can apply", and saying so is better than a download
            // button that fails.
            setMsg(&r.err, &r.err_len, "The release has no package for this system's package manager.");
            r.ok = false;
        }
        return r;
    }

    fn doDownload(self: *Service, a: std.mem.Allocator, job: Job) DownloadResult {
        var r: DownloadResult = .{};
        const url = job.url[0..job.url_len];
        const dest = job.dest[0..job.dest_len];
        if (url.len == 0 or dest.len == 0) {
            setMsg(&r.err, &r.err_len, "Nothing to download");
            return r;
        }
        if (std.fs.path.dirname(dest)) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        }

        {
            const pr: ProgressResult = .{ .got = 0, .total = job.size };
            self.lock();
            self.progress = pr;
            self.unlock();
            self.ping();
        }

        // A `.part` sibling is written and renamed into place, so a partial
        // file never sits at the name the install step uses.
        const tmp = std.fmt.allocPrint(a, "{s}.part", .{dest}) catch {
            setMsg(&r.err, &r.err_len, "Out of memory");
            return r;
        };
        defer a.free(tmp);

        var file = std.Io.Dir.cwd().createFile(self.io, tmp, .{
            .truncate = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch {
            setMsg(&r.err, &r.err_len, "Cannot write to the download folder");
            return r;
        };
        var closed = false;
        defer if (!closed) file.close(self.io);

        var sink: DlSink = .{
            .writer = .{ .vtable = &DlSink.vtable, .buffer = &.{} },
            .file = file,
            .io = self.io,
            .total = job.size,
            .svc = self,
        };

        var client = std.http.Client{ .allocator = a, .io = self.io };
        defer client.deinit();
        const res = client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .response_writer = &sink.writer,
        }) catch {
            file.close(self.io);
            closed = true;
            std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
            setMsg(&r.err, &r.err_len, "Download failed. Check your connection.");
            return r;
        };
        if (res.status != .ok) {
            file.close(self.io);
            closed = true;
            std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
            setMsg(&r.err, &r.err_len, "GitHub refused the download");
            return r;
        }
        // The response writer is drained by `fetch`, but our sink has no
        // buffer, so there is nothing left to flush.
        sink.writer.flush() catch {
            file.close(self.io);
            closed = true;
            std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
            setMsg(&r.err, &r.err_len, "Could not write the package to disk");
            return r;
        };

        file.close(self.io);
        closed = true;

        // Verify before the file is visible under its real name.
        if (parseDigestHex(job.digest[0..job.digest_len])) |want| {
            const got = sink.hasher.finalResult();
            if (!std.mem.eql(u8, &got, &want)) {
                std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
                setMsg(&r.err, &r.err_len, "Checksum mismatch: the download was corrupted");
                return r;
            }
        }

        std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), dest, self.io) catch {
            std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
            setMsg(&r.err, &r.err_len, "Could not move the package into place");
            return r;
        };

        r.ok = true;
        r.got = sink.written;
        setMsg(&r.path, &r.path_len, dest);
        {
            const pr: ProgressResult = .{ .got = sink.written, .total = sink.written };
            self.lock();
            self.progress = pr;
            self.unlock();
            self.ping();
        }
        return r;
    }

    fn doInstall(self: *Service, job: Job) InstallResult {
        var r: InstallResult = .{};
        const path = job.path[0..job.path_len];
        if (path.len == 0) {
            setMsg(&r.err, &r.err_len, "No package to install");
            return r;
        }
        var argv_buf: [8][]const u8 = undefined;
        const argv = installArgv(job.pkg, path, &argv_buf);
        const res = std.process.run(self.alloc, self.io, .{ .argv = argv }) catch |e| {
            const msg = switch (e) {
                error.FileNotFound => "pkexec was not found. Install polkit to apply updates.",
                else => "Could not start the package manager.",
            };
            setMsg(&r.err, &r.err_len, msg);
            return r;
        };
        defer self.alloc.free(res.stdout);
        defer self.alloc.free(res.stderr);
        if (res.term == .exited and res.term.exited == 0) {
            r.ok = true;
            return r;
        }
        // The package manager's own last line is more useful than "failed".
        const detail = lastLine(res.stderr);
        if (detail.len > 0) {
            setMsg(&r.err, &r.err_len, detail);
        } else {
            setMsg(&r.err, &r.err_len, "The package manager reported an error.");
        }
        return r;
    }
};

/// Streaming sink: every byte `fetch` hands over is written to the package
/// file, hashed, and counted so the bar can advance.
const DlSink = struct {
    writer: std.Io.Writer,
    file: std.Io.File,
    io: std.Io,
    hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    written: u64 = 0,
    total: u64 = 0,
    svc: *Service,
    /// Publish a progress tick every this many bytes rather than on every
    /// socket read; the settings thread repaints per tick.
    last_ping_at: u64 = 0,

    const ping_every: u64 = 1 << 20;

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DlSink = @alignCast(@fieldParentPtr("writer", w));
        var consumed: usize = 0;
        for (data, 0..) |slice, i| {
            const times: usize = if (i + 1 == data.len) splat else 1;
            var k: usize = 0;
            while (k < times) : (k += 1) {
                self.absorb(slice) catch return error.WriteFailed;
                consumed += slice.len;
            }
        }
        return consumed;
    }

    fn absorb(self: *DlSink, bytes: []const u8) !void {
        if (self.written + bytes.len > package_max) return error.TooLarge;
        self.file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        self.hasher.update(bytes);
        self.written += bytes.len;
        if (self.written - self.last_ping_at >= ping_every) {
            self.last_ping_at = self.written;
            self.svc.lock();
            self.svc.progress = .{ .got = self.written, .total = self.total };
            self.svc.unlock();
            self.svc.ping();
        }
    }
};

fn lastLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return "";
    if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| {
        return std.mem.trim(u8, trimmed[i + 1 ..], " \t\r");
    }
    return trimmed;
}

pub fn env(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// Where packages land: `$XDG_CACHE_HOME/event-horizon/updates`.
pub fn downloadDir(alloc: std.mem.Allocator, xdg_cache: ?[]const u8, home: ?[]const u8) ![]u8 {
    if (xdg_cache) |cch| return std.fs.path.join(alloc, &.{ cch, "event-horizon", "updates" });
    if (home) |h| return std.fs.path.join(alloc, &.{ h, ".cache", "event-horizon", "updates" });
    return alloc.dupe(u8, "/tmp/event-horizon-updates");
}

/// Replace every running `horizon` supervisor with a fresh one.
///
/// The supervisor is normally started by the compositor, not by systemd, so
/// there is no unit to restart. A detached shell remembers the binary path,
/// stops the old supervisor (its loop catches SIGTERM and shuts its children
/// down), waits for it to leave, and starts the same binary again. `setsid`
/// makes the new copy a session leader so it outlives the settings window.
pub fn restartShell(io: std.Io) bool {
    const script =
        \\bin=$(readlink -f /proc/$(pgrep -o -x horizon)/exe 2>/dev/null)
        \\[ -x "$bin" ] || bin=$(command -v horizon 2>/dev/null)
        \\[ -x "$bin" ] || exit 1
        \\for p in $(pgrep -x horizon); do kill -TERM "$p" 2>/dev/null; done
        \\i=0
        \\while [ $i -lt 100 ]; do pgrep -x horizon >/dev/null 2>&1 || break; sleep 0.1; i=$((i+1)); done
        \\setsid "$bin" >/dev/null 2>&1 < /dev/null &
    ;
    const argv = [_][]const u8{ "/bin/sh", "-c", script };
    // Deliberately not waited on: the script outlives this process (it is
    // about to be stopped by the supervisor it signals) and `wait` would
    // block the input thread for the whole stop-and-start window.
    _ = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    return true;
}

/// Open the release page in the user's browser.
pub fn openReleasesPage(io: std.Io) bool {
    const argv = [_][]const u8{ "xdg-open", releases_page };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    _ = child.wait(io) catch {};
    return true;
}

// Tests

test "updater-service: version parse and ordering" {
    const t = std.testing;
    const a = parseVersion("v0.1.4").?;
    try t.expectEqual(@as(u32, 0), a.major);
    try t.expectEqual(@as(u32, 1), a.minor);
    try t.expectEqual(@as(u32, 4), a.patch);
    try t.expectEqual(@as(u32, 5), parseVersion("1.5").?.minor);
    try t.expect(parseVersion("nope") == null);
    try t.expect(isNewer("0.1.4", "0.1.5"));
    try t.expect(isNewer("0.1.4", "0.2.0"));
    try t.expect(!isNewer("0.1.4", "0.1.4"));
    try t.expect(!isNewer("0.1.10", "0.1.9"));
    // Numeric, not lexicographic: 0.10 sorts after 0.9.
    try t.expect(isNewer("0.9.0", "0.10.0"));
}

test "updater-service: package kind from os-release" {
    const t = std.testing;
    try t.expectEqual(PackageKind.arch, packageKindFromOsRelease(
        \\NAME="Arch Linux"
        \\ID=arch
        \\ID_LIKE=arch
    ));
    try t.expectEqual(PackageKind.rpm, packageKindFromOsRelease(
        \\NAME="Fedora Linux"
        \\ID=fedora
    ));
    try t.expectEqual(PackageKind.rpm, packageKindFromOsRelease(
        \\ID="rocky"
        \\ID_LIKE="rhel centos fedora"
    ));
    try t.expectEqual(PackageKind.deb, packageKindFromOsRelease(
        \\NAME="Ubuntu"
        \\ID=ubuntu
        \\ID_LIKE=debian
    ));
    try t.expectEqual(PackageKind.deb, packageKindFromOsRelease("ID=linuxmint"));
    try t.expectEqual(PackageKind.arch, packageKindFromOsRelease("ID=manjaro\nID_LIKE=arch"));
}

test "updater-service: asset selection by extension" {
    const t = std.testing;
    try t.expectEqual(PackageKind.arch, assetKind("event-horizon-de-0.1.4-1-x86_64.pkg.tar.zst").?);
    try t.expectEqual(PackageKind.rpm, assetKind("event-horizon-de-0.1.4-1.x86_64.rpm").?);
    try t.expectEqual(PackageKind.deb, assetKind("event-horizon-de_0.1.4_amd64.deb").?);
    try t.expect(assetKind("event-horizon-de-0.1.4-x86_64.tar.gz") == null);
}

test "updater-service: digest parsing" {
    const t = std.testing;
    const d = parseDigestHex("sha256:000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f").?;
    try t.expectEqual(@as(u8, 0), d[0]);
    try t.expectEqual(@as(u8, 0x1f), d[31]);
    try t.expect(parseDigestHex("sha256:zz") == null);
    try t.expect(parseDigestHex("") == null);
}

test "updater-service: release JSON picks the matching asset" {
    const t = std.testing;
    const doc =
        \\{"tag_name":"0.2.0","body":"- New thing","assets":[
        \\ {"name":"event-horizon-de-0.2.0-1-x86_64.pkg.tar.zst","browser_download_url":"https://ex/zst","size":10,"digest":"sha256:00"},
        \\ {"name":"event-horizon-de_0.2.0_amd64.deb","browser_download_url":"https://ex/deb","size":20,"digest":"sha256:11"},
        \\ {"name":"event-horizon-de-0.2.0-1.x86_64.rpm","browser_download_url":"https://ex/rpm","size":30,"digest":"sha256:22"}]}
    ;
    const parsed = try parseRelease(t.allocator, doc, .deb);
    try t.expectEqualStrings("0.2.0", parsed.release.tagSlice());
    try t.expectEqualStrings("- New thing", parsed.release.notesSlice());
    const asset = parsed.asset.?;
    try t.expectEqualStrings("event-horizon-de_0.2.0_amd64.deb", asset.nameSlice());
    try t.expectEqualStrings("https://ex/deb", asset.urlSlice());
    try t.expectEqual(@as(u64, 20), asset.size);
    try t.expect(parsed.asset.?.kind == .deb);
}

test "updater-service: install argv names the right package manager" {
    const t = std.testing;
    var buf: [8][]const u8 = undefined;
    const arch = installArgv(.arch, "/tmp/p.pkg.tar.zst", &buf);
    try t.expectEqualStrings("pkexec", arch[0]);
    try t.expectEqualStrings("pacman", arch[1]);
    try t.expectEqualStrings("/tmp/p.pkg.tar.zst", arch[4]);
    const deb = installArgv(.deb, "/tmp/p.deb", &buf);
    try t.expectEqualStrings("apt-get", deb[1]);
    const rpm = installArgv(.rpm, "/tmp/p.rpm", &buf);
    try t.expectEqualStrings("dnf", rpm[1]);
}

test "updater-service: only one job may be in flight" {
    const t = std.testing;
    var svc = Service.init(t.allocator, std.testing.io);
    defer svc.deinit();
    svc.running = true;
    try t.expect(svc.busy());
    try t.expect(!svc.checkAsync(.deb));
    try t.expect(!svc.downloadAsync("https://x", "/tmp/x", "", 0));
    try t.expect(!svc.installAsync(.deb, "/tmp/x"));
    svc.running = false;
    try t.expect(!svc.busy());
}
