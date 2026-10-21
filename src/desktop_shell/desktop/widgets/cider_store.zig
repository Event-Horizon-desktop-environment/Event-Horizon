//! State and background I/O for the desktop Cider widget.
//!
//! The widget paint path must never block on a socket, so Cider's REST
//! reads run on one worker at a time and publish a `Result` through an
//! atomic phase word (the same shape as `cover_worker`). The shell thread
//! drains that result on its service tick, swaps the owned pages into this
//! module's store, and paints from stable slices.
//!
//! One Cider widget is expected per desktop, but all of its configs share the
//! store: the data is the same regardless of which card is on screen.

const std = @import("std");
const cider = @import("../../../services/cider_client.zig");
const logz = @import("../../../logz.zig");

pub const Link = cider.Link;
pub const AuthResult = cider.AuthResult;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * std.time.ns_per_s +
        @as(u64, @intCast(@max(ts.nsec, 0)));
}

fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
        @divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), 1_000_000);
}

// ---------------------------------------------------------------------------
// Store

var token: ?cider.Token = null;
var queue_page: ?cider.QueuePage = null;
var library_page: ?cider.LibraryPage = null;
var lyrics_page: ?cider.LyricsPage = null;
var audio_state: cider.AudioState = .{};
var playback_state: cider.PlaybackState = .{};
var playback_at_ms: i64 = 0;
var now_state: cider.NowStatus = .{};

var link: Link = .unknown;
var probe_http: u16 = 0;
var version_buf: [32]u8 = undefined;
var version_len: u8 = 0;

var wanted_library_kind: cider.LibraryKind = .playlists;
var wanted_library_id: [160]u8 = undefined;
var wanted_library_id_len: u8 = 0;
var wanted_library_valid: bool = false;

var loaded_library_kind: cider.LibraryKind = .playlists;
var loaded_library_id: [160]u8 = undefined;
var loaded_library_id_len: u8 = 0;

var queue_loaded = false;
var lyrics_loaded = false;
var library_loaded = false;

var auth_pending = false;
var auth_buf: [128]u8 = undefined;
var auth_len: usize = 0;
var auth_is_error = false;

var next_token_ms: i64 = 0;
var next_probe_ms: i64 = 0;
var next_queue_ms: i64 = 0;
var next_library_ms: i64 = 0;
var next_lyrics_ms: i64 = 0;
var next_audio_ms: i64 = 0;
var next_playback_ms: i64 = 0;
var next_now_ms: i64 = 0;
var busy_since_ms: i64 = 0;
var next_busy_log_ms: i64 = 0;

pub const Snapshot = struct {
    link: Link = .unknown,
    probe_http: u16 = 0,
    version: []const u8 = "",
    has_token: bool = false,
    token_name: []const u8 = "",
    scopes: cider.ScopeSet = .{},
    queue: ?*const cider.QueuePage = null,
    library: ?*const cider.LibraryPage = null,
    lyrics: ?*const cider.LyricsPage = null,
    audio: cider.AudioState = .{},
    playback: cider.PlaybackState = .{},
    now: cider.NowStatus = .{},
    playback_at_ms: i64 = 0,
    queue_loaded: bool = false,
    library_loaded: bool = false,
    lyrics_loaded: bool = false,
    library_kind: cider.LibraryKind = .playlists,
    library_id: []const u8 = "",
    auth_pending: bool = false,
    auth_message: []const u8 = "",
    auth_is_error: bool = false,
    busy: bool = false,
    busy_kind: ?JobKind = null,
};

pub fn snapshot() Snapshot {
    return .{
        .link = link,
        .probe_http = probe_http,
        .version = version_buf[0..version_len],
        .has_token = token != null,
        .token_name = if (token) |t| t.name else "",
        .scopes = if (token) |t| t.scopes else .{},
        .queue = if (queue_page) |*p| p else null,
        .library = if (library_page) |*p| p else null,
        .lyrics = if (lyrics_page) |*p| p else null,
        .audio = audio_state,
        .playback = playback_state,
        .now = now_state,
        .playback_at_ms = playback_at_ms,
        .queue_loaded = queue_loaded,
        .library_loaded = library_loaded,
        .lyrics_loaded = lyrics_loaded,
        .library_kind = loaded_library_kind,
        .library_id = loaded_library_id[0..loaded_library_id_len],
        .auth_pending = auth_pending,
        .auth_message = auth_buf[0..auth_len],
        .auth_is_error = auth_is_error,
        .busy = worker_phase.load(.acquire) != k_idle,
        .busy_kind = active_kind,
    };
}

pub fn connected() bool {
    return link == .connected and token != null;
}

pub fn tokenScopes() cider.ScopeSet {
    return if (token) |t| t.scopes else .{};
}

pub fn tokenValue() []const u8 {
    return if (token) |t| t.value else "";
}

/// Stable pointer to the last playback snapshot. The text slices in
/// `PlaybackState` point into these buffers, so widget views must borrow this
/// global rather than a stack copy of `Snapshot.playback`.
pub fn playbackState() *const cider.PlaybackState {
    return &playback_state;
}

pub fn libraryMatches(kind: cider.LibraryKind, id: []const u8) bool {
    if (!library_loaded) return false;
    if (loaded_library_kind != kind) return false;
    return std.mem.eql(u8, loaded_library_id[0..loaded_library_id_len], id);
}

pub fn authMessage() []const u8 {
    return auth_buf[0..auth_len];
}

fn setAuthMessage(msg: []const u8, is_error: bool) void {
    const n = @min(msg.len, auth_buf.len);
    @memcpy(auth_buf[0..n], msg[0..n]);
    auth_len = n;
    auth_is_error = is_error;
}

fn setAuthFmt(comptime fmt: []const u8, args: anytype, is_error: bool) void {
    const s = std.fmt.bufPrint(&auth_buf, fmt, args) catch {
        setAuthMessage("Cider request failed", is_error);
        return;
    };
    auth_len = s.len;
    auth_is_error = is_error;
}

fn installToken(next: cider.Token) void {
    if (token) |*old| old.deinit(std.heap.page_allocator);
    token = next;
    version_len = 0;
    link = .checking;
    next_probe_ms = 0;
    queue_loaded = false;
    library_loaded = false;
    lyrics_loaded = false;
    next_queue_ms = 0;
    next_library_ms = 0;
    next_lyrics_ms = 0;
    next_audio_ms = 0;
    next_playback_ms = 0;
    next_now_ms = 0;
}

// ---------------------------------------------------------------------------
// Worker

const k_idle: u8 = 0;
const k_running: u8 = 1;
const k_ready: u8 = 2;

const JobKind = enum { probe, auth, queue, library, lyrics, audio, playback, now_status };

const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    kind: JobKind,
    token: []u8 = &.{},
    id: []u8 = &.{},
    lib_kind: cider.LibraryKind = .playlists,
    offset: i64 = 0,
    started_ns: u64 = 0,
    limit: i64 = 0,

    fn free(self: *Job) void {
        if (self.token.len > 0) self.alloc.free(self.token);
        if (self.id.len > 0) self.alloc.free(self.id);
        self.alloc.destroy(self);
    }

    fn run(self: *Job) void {
        self.started_ns = nowNs();
        var r = Result{ .kind = self.kind, .lib_kind = self.lib_kind };
        r.library_id_len = @intCast(@min(self.id.len, r.library_id.len));
        @memcpy(r.library_id[0..r.library_id_len], self.id[0..r.library_id_len]);
        switch (self.kind) {
            .probe => r.probe = cider.probe(self.alloc, self.io, if (self.token.len > 0) self.token else null),
            .auth => {
                r.auth = cider.requestAuth(self.alloc, self.io) catch .{ .http = 0 };
            },
            .queue => {
                if (self.token.len > 0) {
                    if (cider.fetchQueue(self.alloc, self.io, self.token, self.offset, self.limit)) |p| {
                        r.queue = p;
                        r.ok = true;
                    } else |_| {}
                }
            },
            .library => {
                if (self.token.len > 0) {
                    if (cider.fetchLibrary(self.alloc, self.io, self.token, self.lib_kind, self.id, self.offset, self.limit)) |p| {
                        r.library = p;
                        r.ok = true;
                    } else |_| {}
                }
            },
            .lyrics => {
                if (self.token.len > 0) {
                    if (cider.fetchLyrics(self.alloc, self.io, self.token)) |p| {
                        r.lyrics = p;
                        r.ok = true;
                    } else |_| {}
                }
            },
            .audio => {
                if (self.token.len > 0) {
                    r.audio = cider.fetchAudio(self.alloc, self.io, self.token);
                    r.ok = true;
                }
            },
            .playback => {
                if (self.token.len > 0) {
                    r.playback = cider.fetchPlayback(self.alloc, self.io, self.token);
                    r.ok = true;
                }
            },
            .now_status => {
                if (self.token.len > 0) {
                    r.now = cider.fetchNowStatus(self.alloc, self.io, self.token);
                    r.ok = true;
                }
            },
        }
        r.elapsed_ns = nowNs() -| self.started_ns;
        self.free();
        result = r;
        worker_phase.store(k_ready, .release);
    }
};

const Result = struct {
    kind: JobKind = .probe,
    ok: bool = false,
    probe: cider.Probe = .{},
    auth: ?AuthResult = null,
    queue: ?cider.QueuePage = null,
    library: ?cider.LibraryPage = null,
    lyrics: ?cider.LyricsPage = null,
    audio: cider.AudioState = .{},
    playback: cider.PlaybackState = .{},
    now: cider.NowStatus = .{},
    lib_kind: cider.LibraryKind = .playlists,
    library_id: [160]u8 = undefined,
    library_id_len: u8 = 0,
    elapsed_ns: u64 = 0,

    fn deinit(self: *Result) void {
        if (self.auth) |*a| {
            switch (a.*) {
                .token => |*t| t.deinit(std.heap.page_allocator),
                else => {},
            }
            self.auth = null;
        }
        if (self.queue) |*p| p.deinit();
        if (self.library) |*p| p.deinit();
        if (self.lyrics) |*p| p.deinit();
        self.queue = null;
        self.library = null;
        self.lyrics = null;
    }
};

var worker_phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(k_idle);
var result: Result = .{};
var worker: ?std.Thread = null;
var active_kind: ?JobKind = null;

const dirty_now: u8 = 1 << 0;
const dirty_queue: u8 = 1 << 1;
const dirty_audio: u8 = 1 << 2;
var action_dirty: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

fn markDirty(bits: u8) void {
    _ = action_dirty.fetchOr(bits, .acq_rel);
}

fn drainDirty() void {
    const bits = action_dirty.swap(0, .acquire);
    if (bits & dirty_now != 0) {
        next_now_ms = 0;
        next_playback_ms = 0;
    }
    if (bits & dirty_queue != 0) next_queue_ms = 0;
    if (bits & dirty_audio != 0) next_audio_ms = 0;
}

fn startJob(io: std.Io, kind: JobKind, token_bytes: []const u8, id: []const u8, lib_kind: cider.LibraryKind, offset: i64, limit: i64) bool {
    if (worker_phase.load(.acquire) != k_idle) return false;
    if (worker) |w| {
        w.join();
        worker = null;
    }
    const alloc = std.heap.page_allocator;
    const job = alloc.create(Job) catch return false;
    job.* = .{
        .alloc = alloc,
        .io = io,
        .kind = kind,
        .lib_kind = lib_kind,
        .offset = offset,
        .limit = limit,
    };
    if (token_bytes.len > 0) job.token = alloc.dupe(u8, token_bytes) catch {
        alloc.destroy(job);
        return false;
    };
    if (id.len > 0) job.id = alloc.dupe(u8, id) catch {
        job.free();
        return false;
    };
    active_kind = kind;
    worker_phase.store(k_running, .release);
    if (kind == .auth) auth_pending = true;
    worker = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        worker_phase.store(k_idle, .release);
        active_kind = null;
        if (kind == .auth) auth_pending = false;
        job.free();
        return false;
    };
    return true;
}

fn takeResult(out: *Result) bool {
    if (worker_phase.load(.acquire) != k_ready) return false;
    out.* = result;
    result = .{};
    worker_phase.store(k_idle, .release);
    active_kind = null;
    return true;
}

/// Tests only: wait for any worker and drain the result.
pub fn reset() void {
    if (worker) |w| {
        w.join();
        worker = null;
    }
    var stale: Result = .{};
    if (takeResult(&stale)) stale.deinit();
    active_kind = null;
    _ = action_dirty.swap(0, .release);
    if (token) |*t| t.deinit(std.heap.page_allocator);
    token = null;
    if (queue_page) |*p| p.deinit();
    if (library_page) |*p| p.deinit();
    if (lyrics_page) |*p| p.deinit();
    queue_page = null;
    library_page = null;
    lyrics_page = null;
    queue_loaded = false;
    library_loaded = false;
    lyrics_loaded = false;
    link = .unknown;
    version_len = 0;
    auth_pending = false;
    auth_len = 0;
    audio_state = .{};
    playback_state = .{};
    playback_at_ms = 0;
    now_state = .{};
    next_token_ms = 0;
    next_probe_ms = 0;
    next_queue_ms = 0;
    next_library_ms = 0;
    next_lyrics_ms = 0;
    next_audio_ms = 0;
    next_playback_ms = 0;
    next_now_ms = 0;
    wanted_library_valid = false;
}

fn apply(io: std.Io, res: *Result) void {
    _ = io;
    if (res.elapsed_ns >= 250 * std.time.ns_per_ms) {
        logz.log("perf: job {s} took {d:.1}ms ok={}", .{
            @tagName(res.kind),
            @as(f64, @floatFromInt(res.elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)),
            res.ok,
        });
    }
    switch (res.kind) {
        .probe => {
            probe_http = res.probe.http;
            link = res.probe.link;
            const v = res.probe.versionText();
            const n = @min(v.len, version_buf.len);
            @memcpy(version_buf[0..n], v[0..n]);
            version_len = @intCast(n);
            if (link == .connected) {
                next_probe_ms = nowMs() + 30_000;
            } else {
                next_probe_ms = nowMs() + 10_000;
            }
        },
        .auth => {
            auth_pending = false;
            if (res.auth) |*a| {
                switch (a.*) {
                    .token => |*t| {
                        const moved = t.*;
                        t.* = .{};
                        installToken(moved);
                        setAuthMessage("Connected to Cider", false);
                    },
                    .denied => {
                        setAuthMessage("Access was denied in Cider", true);
                        next_token_ms = nowMs() + 30_000;
                    },
                    .timeout => {
                        setAuthMessage("Cider did not answer the request", true);
                        next_token_ms = nowMs() + 15_000;
                    },
                    .busy => setAuthMessage("Another Cider approval is already open", true),
                    .cooldown => setAuthMessage("Cider is cooling down; try again shortly", true),
                    .banned => setAuthMessage("Cider blocked requests for 15 minutes", true),
                    .http => |code| {
                        if (code == 0)
                            setAuthMessage("Could not reach Cider", true)
                        else
                            setAuthFmt("Cider returned HTTP {d}", .{code}, true);
                    },
                }
            } else {
                setAuthMessage("Could not reach Cider", true);
            }
        },
        .queue => {
            if (res.queue) |*p| {
                if (queue_page) |*old| old.deinit();
                queue_page = p.*;
                res.queue = null;
                queue_loaded = true;
                next_queue_ms = nowMs() + 8_000;
            } else {
                next_queue_ms = nowMs() + 8_000;
            }
        },
        .library => {
            if (res.ok and res.library != null and res.lib_kind == wanted_library_kind and
                libraryIdMatches(res.library_id[0..res.library_id_len]))
            {
                const p = res.library.?;
                res.library = null;
                if (library_page) |*old| old.deinit();
                library_page = p;
                loaded_library_kind = res.lib_kind;
                const n = @min(res.library_id_len, loaded_library_id.len);
                @memcpy(loaded_library_id[0..n], res.library_id[0..n]);
                loaded_library_id_len = @intCast(n);
                library_loaded = true;
                next_library_ms = nowMs() + 20_000;
            } else {
                next_library_ms = nowMs() + 4_000;
            }
        },
        .lyrics => {
            if (res.lyrics) |*p| {
                if (lyrics_page) |*old| old.deinit();
                lyrics_page = p.*;
                res.lyrics = null;
                lyrics_loaded = true;
                next_lyrics_ms = nowMs() + 8_000;
            } else {
                // No current lyrics; keep the page blank rather than stale.
                if (lyrics_page) |*old| old.deinit();
                lyrics_page = null;
                lyrics_loaded = true;
                next_lyrics_ms = nowMs() + 10_000;
            }
        },
        .audio => {
            if (res.ok) {
                // Keep a fetched volume when the audio endpoint set has no
                // volume (volume lives on the playback snapshot).
                const old_volume = audio_state.volume;
                const had_volume = audio_state.has_volume;
                audio_state = res.audio;
                if (!audio_state.has_volume and had_volume) {
                    audio_state.volume = old_volume;
                    audio_state.has_volume = true;
                }
                next_audio_ms = nowMs() + 20_000;
            } else {
                next_audio_ms = nowMs() + 10_000;
            }
        },
        .playback => {
            if (res.ok) {
                playback_state = res.playback;
                playback_at_ms = nowMs();
                if (res.playback.has_volume) {
                    audio_state.volume = res.playback.volume;
                    audio_state.has_volume = true;
                }
                next_playback_ms = nowMs() + 4_000;
            } else {
                next_playback_ms = nowMs() + 6_000;
            }
        },
        .now_status => {
            if (res.ok) now_state = res.now;
            next_now_ms = nowMs() + 4_000;
        },
    }
}

fn libraryIdMatches(id: []const u8) bool {
    if (!wanted_library_valid) return false;
    return std.mem.eql(u8, wanted_library_id[0..wanted_library_id_len], id);
}

/// Drain a finished request and run the cheap periodic housekeeping. Called
/// once per desktop service tick.
pub fn poll(io: std.Io) void {
    var res: Result = .{};
    if (takeResult(&res)) {
        apply(io, &res);
        res.deinit();
    }
    drainDirty();
    const now = nowMs();
    if (worker_phase.load(.acquire) == k_idle) {
        busy_since_ms = 0;
    } else if (busy_since_ms == 0) {
        busy_since_ms = now;
        next_busy_log_ms = now + 2_000;
    } else if (now >= next_busy_log_ms) {
        next_busy_log_ms = now + 2_000;
        logz.log("perf: job still busy {d}ms kind={s}", .{
            now - busy_since_ms,
            if (active_kind) |k| @tagName(k) else "?",
        });
    }
    if (token == null and !auth_pending and now >= next_token_ms) {
        if (cider.detectToken(std.heap.page_allocator, io)) |t| {
            installToken(t);
            setAuthMessage("Cider token found", false);
        } else {
            next_token_ms = now + 4_000;
        }
    }
    if (!auth_pending and (link == .unknown or link == .checking or now >= next_probe_ms)) {
        if (worker_phase.load(.acquire) == k_idle) {
            next_probe_ms = now + 10_000;
            const tv = if (token) |t| t.value else "";
            _ = startJob(io, .probe, tv, "", .playlists, 0, 0);
        }
    }
}

/// Ask for the queue unless the last read is still fresh. The worker is
/// single-flight, so a refused call simply retries on the next tick.
pub fn ensureQueue(io: std.Io) void {
    if (!connected()) return;
    if (!tokenScopes().has(.queue)) return;
    const now = nowMs();
    if (queue_loaded and now < next_queue_ms) return;
    if (now < next_queue_ms) return;
    if (!startJob(io, .queue, token.?.value, "", .playlists, 0, 100)) return;
    next_queue_ms = now + 8_000;
}

/// `id` is empty for the top-level tabs; collection tabs pass the playlist,
/// album, or artist id.
pub fn ensureLibrary(io: std.Io, kind: cider.LibraryKind, id: []const u8) void {
    if (!connected()) return;
    if (!tokenScopes().has(.library)) return;
    if (!wanted_library_valid or wanted_library_kind != kind or
        !std.mem.eql(u8, wanted_library_id[0..wanted_library_id_len], id))
    {
        wanted_library_valid = true;
        wanted_library_kind = kind;
        const n = @min(id.len, wanted_library_id.len);
        @memcpy(wanted_library_id[0..n], id[0..n]);
        wanted_library_id_len = @intCast(n);
        next_library_ms = 0;
    }
    const now = nowMs();
    if (now < next_library_ms) return;
    if (libraryMatches(kind, id)) {
        next_library_ms = now + 20_000;
        return;
    }
    if (!startJob(io, .library, token.?.value, id, kind, 0, 100)) return;
    next_library_ms = now + 6_000;
}

pub fn ensureLyrics(io: std.Io) void {
    if (!connected()) return;
    if (!tokenScopes().has(.lyrics)) return;
    const now = nowMs();
    if (now < next_lyrics_ms) return;
    if (!startJob(io, .lyrics, token.?.value, "", .playlists, 0, 0)) return;
    next_lyrics_ms = now + 8_000;
}

pub fn ensureAudio(io: std.Io) void {
    if (!connected()) return;
    if (!tokenScopes().has(.audio)) return;
    const now = nowMs();
    if (now < next_audio_ms) return;
    if (!startJob(io, .audio, token.?.value, "", .playlists, 0, 0)) return;
    next_audio_ms = now + 20_000;
}

pub fn ensurePlayback(io: std.Io) void {
    if (!connected()) return;
    if (!tokenScopes().has(.playback)) return;
    const now = nowMs();
    if (now < next_playback_ms) return;
    if (!startJob(io, .playback, token.?.value, "", .playlists, 0, 0)) return;
    next_playback_ms = now + 4_000;
}

pub fn ensureNowStatus(io: std.Io) void {
    if (!connected()) return;
    if (!tokenScopes().has(.library)) return;
    const now = nowMs();
    if (now < next_now_ms) return;
    if (!startJob(io, .now_status, token.?.value, "", .playlists, 0, 0)) return;
    next_now_ms = now + 4_000;
}

pub fn requestAuth(io: std.Io) bool {
    if (auth_pending) return false;
    auth_pending = true;
    setAuthMessage("Waiting for approval in Cider…", false);
    if (startJob(io, .auth, "", "", .playlists, 0, 0)) return true;
    auth_pending = false;
    setAuthMessage("Could not start the Cider request", true);
    return false;
}

pub fn invalidateQueue() void {
    next_queue_ms = 0;
}

pub fn invalidateLibrary() void {
    next_library_ms = 0;
}

pub fn invalidateAudio() void {
    next_audio_ms = 0;
}

/// Put the connection pill back into "checking" and probe on the next tick.
pub fn recheck(io: std.Io) void {
    _ = io;
    link = .checking;
    next_probe_ms = 0;
}

pub fn invalidateLyrics() void {
    next_lyrics_ms = 0;
}

pub fn invalidateNow() void {
    next_now_ms = 0;
    next_playback_ms = 0;
}

fn canWrite() bool {
    return connected();
}

// ---------------------------------------------------------------------------
// Controls. Each action copies what it needs and runs detached so a click
// never waits on Cider. Actions deliberately do not publish results; the
// next poll refreshes the affected page.

const ActionJob = struct {
    io: std.Io,
    token: []u8,
    typ: []u8 = &.{},
    id: []u8 = &.{},
    path: []u8 = &.{},
    body: []u8 = &.{},
    action: Action = .none,
    on: bool = false,
    index: i64 = 0,
    seconds: f64 = 0,
    kind_str: []u8 = &.{},

    const Action = enum {
        none,
        play_item,
        play_collection,
        queue_jump,
        queue_remove,
        add_next,
        love,
        add_library,
        audio_bool,
        listening,
        volume,
        playback_toggle,
        playback_next,
        playback_previous,
        playback_seek,
        playback_shuffle,
        playback_repeat,
    };

    fn free(self: *ActionJob) void {
        const a = std.heap.page_allocator;
        a.free(self.token);
        if (self.typ.len > 0) a.free(self.typ);
        if (self.id.len > 0) a.free(self.id);
        if (self.path.len > 0) a.free(self.path);
        if (self.body.len > 0) a.free(self.body);
        if (self.kind_str.len > 0) a.free(self.kind_str);
        a.destroy(self);
    }

    fn run(self: *ActionJob) void {
        defer self.free();
        const a = std.heap.page_allocator;
        switch (self.action) {
            .none => {},
            .play_item => _ = cider.playItem(a, self.io, self.token, self.typ, self.id),
            .play_collection => _ = cider.playCollection(a, self.io, self.token, self.typ, self.id),
            .queue_jump => _ = cider.queueJump(a, self.io, self.token, self.index),
            .queue_remove => _ = cider.queueRemove(a, self.io, self.token, self.index),
            .add_next => _ = cider.queueAddNext(a, self.io, self.token, self.typ, self.id),
            .love => _ = cider.loveCurrent(a, self.io, self.token, self.on),
            .add_library => _ = cider.addCurrent(a, self.io, self.token, self.on),
            .audio_bool => _ = cider.setAudioBool(a, self.io, self.token, self.kind_str, self.on),
            .listening => _ = cider.setListeningMode(a, self.io, self.token, self.kind_str),
            .volume => {
                const v = @as(f64, @floatFromInt(self.index)) / 1000.0;
                _ = cider.setVolume(a, self.io, self.token, v);
            },
            .playback_toggle => _ = cider.playbackToggle(a, self.io, self.token),
            .playback_next => _ = cider.playbackNext(a, self.io, self.token),
            .playback_previous => _ = cider.playbackPrevious(a, self.io, self.token),
            .playback_seek => _ = cider.playbackSeek(a, self.io, self.token, self.seconds),
            .playback_shuffle => _ = cider.playbackShuffleToggle(a, self.io, self.token),
            .playback_repeat => _ = cider.playbackRepeatToggle(a, self.io, self.token),
        }
        switch (self.action) {
            .play_item, .play_collection, .queue_jump, .queue_remove, .add_next => markDirty(dirty_now | dirty_queue),
            .love, .add_library, .playback_toggle, .playback_seek => markDirty(dirty_now),
            .audio_bool, .listening, .volume => markDirty(dirty_now | dirty_audio),
            .playback_next, .playback_previous => markDirty(dirty_now | dirty_queue),
            .none => {},
            .playback_shuffle, .playback_repeat => markDirty(dirty_now),
        }
    }
};

fn actionBase(io: std.Io) ?*ActionJob {
    if (!canWrite()) return null;
    const a = std.heap.page_allocator;
    const job = a.create(ActionJob) catch return null;
    job.* = .{ .io = io, .token = a.dupe(u8, token.?.value) catch {
        a.destroy(job);
        return null;
    } };
    return job;
}

fn finishAction(job: *ActionJob) bool {
    var th = std.Thread.spawn(.{}, ActionJob.run, .{job}) catch {
        job.free();
        return false;
    };
    th.detach();
    return true;
}

pub fn actionPlayItem(io: std.Io, typ: []const u8, id: []const u8) bool {
    const job = actionBase(io) orelse return false;
    const a = std.heap.page_allocator;
    job.action = .play_item;
    job.typ = a.dupe(u8, typ) catch {
        job.free();
        return false;
    };
    job.id = a.dupe(u8, id) catch {
        job.free();
        return false;
    };
    return finishAction(job);
}

pub fn actionPlayCollection(io: std.Io, typ: []const u8, id: []const u8) bool {
    const job = actionBase(io) orelse return false;
    const a = std.heap.page_allocator;
    job.action = .play_collection;
    job.typ = a.dupe(u8, typ) catch {
        job.free();
        return false;
    };
    job.id = a.dupe(u8, id) catch {
        job.free();
        return false;
    };
    invalidateQueue();
    invalidateNow();
    return finishAction(job);
}

pub fn actionQueueJump(io: std.Io, index: i64) bool {
    const job = actionBase(io) orelse return false;
    job.action = .queue_jump;
    job.index = index;
    invalidateQueue();
    invalidateNow();
    return finishAction(job);
}

pub fn actionQueueRemove(io: std.Io, index: i64) bool {
    const job = actionBase(io) orelse return false;
    job.action = .queue_remove;
    job.index = index;
    invalidateQueue();
    return finishAction(job);
}

pub fn actionAddNext(io: std.Io, typ: []const u8, id: []const u8) bool {
    const job = actionBase(io) orelse return false;
    const a = std.heap.page_allocator;
    job.action = .add_next;
    job.typ = a.dupe(u8, typ) catch {
        job.free();
        return false;
    };
    job.id = a.dupe(u8, id) catch {
        job.free();
        return false;
    };
    invalidateQueue();
    return finishAction(job);
}

pub fn actionLove(io: std.Io, on: bool) bool {
    const job = actionBase(io) orelse return false;
    job.action = .love;
    job.on = on;
    invalidateNow();
    return finishAction(job);
}

pub fn actionAddLibrary(io: std.Io, on: bool) bool {
    const job = actionBase(io) orelse return false;
    job.action = .add_library;
    job.on = on;
    invalidateNow();
    return finishAction(job);
}

pub fn actionAudioBool(io: std.Io, what: []const u8, on: bool) bool {
    const job = actionBase(io) orelse return false;
    const a = std.heap.page_allocator;
    job.action = .audio_bool;
    job.kind_str = a.dupe(u8, what) catch {
        job.free();
        return false;
    };
    job.on = on;
    // Optimistic: the switch feels immediate, the next audio poll confirms it.
    if (std.mem.eql(u8, what, "crossfade")) audio_state.crossfade = on;
    if (std.mem.eql(u8, what, "automix")) audio_state.automix = on;
    if (std.mem.eql(u8, what, "atmos")) audio_state.atmos = on;
    if (std.mem.eql(u8, what, "normalization")) audio_state.normalization = on;
    next_audio_ms = nowMs() + 1_500;
    return finishAction(job);
}

pub fn actionListening(io: std.Io, mode: cider.ListeningMode) bool {
    const job = actionBase(io) orelse return false;
    const a = std.heap.page_allocator;
    const text: []const u8 = switch (mode) {
        .off => "off",
        .game => "game",
        .antifatigue => "antifatigue",
    };
    job.action = .listening;
    job.kind_str = a.dupe(u8, text) catch {
        job.free();
        return false;
    };
    audio_state.listening = mode;
    next_audio_ms = nowMs() + 1_500;
    return finishAction(job);
}

pub fn actionVolume(io: std.Io, v: f64) bool {
    const job = actionBase(io) orelse return false;
    job.action = .volume;
    job.index = @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 1000.0);
    audio_state.volume = std.math.clamp(v, 0.0, 1.0);
    audio_state.has_volume = true;
    return finishAction(job);
}

pub fn actionPlaybackToggle(io: std.Io) bool {
    const job = actionBase(io) orelse return false;
    job.action = .playback_toggle;
    invalidateNow();
    return finishAction(job);
}

pub fn actionPlaybackNext(io: std.Io) bool {
    const job = actionBase(io) orelse return false;
    job.action = .playback_next;
    invalidateNow();
    invalidateQueue();
    return finishAction(job);
}

pub fn actionPlaybackPrevious(io: std.Io) bool {
    const job = actionBase(io) orelse return false;
    job.action = .playback_previous;
    invalidateNow();
    invalidateQueue();
    return finishAction(job);
}

pub fn actionPlaybackSeek(io: std.Io, seconds: f64) bool {
    const job = actionBase(io) orelse return false;
    job.action = .playback_seek;
    job.seconds = @max(seconds, 0.0);
    invalidateNow();
    return finishAction(job);
}

pub fn actionPlaybackShuffle(io: std.Io) bool {
    const job = actionBase(io) orelse return false;
    job.action = .playback_shuffle;
    return finishAction(job);
}

pub fn actionPlaybackRepeat(io: std.Io) bool {
    const job = actionBase(io) orelse return false;
    job.action = .playback_repeat;
    return finishAction(job);
}

// ---------------------------------------------------------------------------
// Tests

test "cider-store: empty snapshot is inert" {
    reset();
    const s = snapshot();
    try std.testing.expect(s.queue == null);
    try std.testing.expect(s.library == null);
    try std.testing.expect(!s.auth_pending);
    try std.testing.expectEqual(Link.unknown, s.link);
}

test "cider-store: library identity matches the requested collection" {
    reset();
    try std.testing.expect(!libraryMatches(.playlists, ""));
    wanted_library_valid = true;
    wanted_library_kind = .album_songs;
    const id = "l.123";
    @memcpy(wanted_library_id[0..id.len], id);
    wanted_library_id_len = id.len;
    loaded_library_kind = .album_songs;
    @memcpy(loaded_library_id[0..id.len], id);
    loaded_library_id_len = id.len;
    library_loaded = true;
    try std.testing.expect(libraryMatches(.album_songs, "l.123"));
    try std.testing.expect(!libraryMatches(.playlist_songs, "l.123"));
    try std.testing.expect(!libraryMatches(.album_songs, "l.999"));
    reset();
}
