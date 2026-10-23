//! Continuous per-window frame streaming over Hyprland's toplevel-export
//! protocol. One session per window: a capture request goes out, the
//! compositor hands back shm parameters, we copy into a private pool,
//! decode + box-filter down to `max_dim`, and pass the premultiplied BGRA
//! frame to the owner (which takes ownership of the slice). Re-requests
//! pace themselves to ~60Hz so an idle window whose copy completes
//! instantly cannot spin the dispatch thread; `tick` releases the deferred
//! requests from the paint loop.

const std = @import("std");
const wl = @import("../c.zig").wl;
const linux = std.os.linux;

/// A completed frame of one toplevel. `bgra` is 8-bit premultiplied
/// BGRA in CAIRO_FORMAT_ARGB32 order, top-down, owned by the receiver.
pub const Frame = struct {
    window_id: u32,
    width: i32,
    height: i32,
    bgra: []u8,
};

pub const Callback = *const fn (ctx: *anyopaque, frame: Frame) void;

/// Re-requests for a window are held back until this long since the last
/// one began — an unchanged window finishes its copy immediately.
const kMinCaptureIntervalMs: u64 = 16;
/// An attempt still unanswered this long after its request never will be:
/// the frame is torn down so the attempt can start over.
const kAttemptTimeoutMs: u64 = 2000;
/// A failed attempt waits this long before the next one, so a compositor
/// refusing the capture cannot be spun in a tight loop.
const kRetryBackoffMs: u64 = 750;
/// Attempts per window before the window stays transparent for good.
const kMaxTries: u32 = 3;

fn nowMs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

/// Bytes per pixel for the shm formats a copy may arrive in, null when
/// the format is not understood.
pub fn fmtBpp(fmt: u32) ?u32 {
    return switch (fmt) {
        wl.WL_SHM_FORMAT_ARGB8888,
        wl.WL_SHM_FORMAT_XRGB8888,
        wl.WL_SHM_FORMAT_ABGR8888,
        wl.WL_SHM_FORMAT_XBGR8888,
        wl.WL_SHM_FORMAT_RGBA8888,
        wl.WL_SHM_FORMAT_BGRA8888,
        wl.WL_SHM_FORMAT_RGBX8888,
        wl.WL_SHM_FORMAT_BGRX8888,
        wl.WL_SHM_FORMAT_XRGB2101010,
        wl.WL_SHM_FORMAT_XBGR2101010,
        wl.WL_SHM_FORMAT_ARGB2101010,
        wl.WL_SHM_FORMAT_ABGR2101010,
        => 4,
        wl.WL_SHM_FORMAT_XRGB16161616,
        wl.WL_SHM_FORMAT_XBGR16161616,
        wl.WL_SHM_FORMAT_ARGB16161616,
        wl.WL_SHM_FORMAT_ABGR16161616,
        => 8,
        else => null,
    };
}

/// Decode one source pixel to straight 8-bit RGBA. 10- and 16-bit formats
/// are rescaled to 8 so a high-depth copy never reads as near-transparent.
pub fn pixelRgba(fmt: u32, p: []const u8) ?[4]u8 {
    const w4 = @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    var a: u8 = 255;
    switch (fmt) {
        wl.WL_SHM_FORMAT_ARGB8888, wl.WL_SHM_FORMAT_BGRA8888 => {
            b = @truncate(w4);
            g = @truncate(w4 >> 8);
            r = @truncate(w4 >> 16);
            a = @truncate(w4 >> 24);
        },
        wl.WL_SHM_FORMAT_XRGB8888, wl.WL_SHM_FORMAT_BGRX8888 => {
            b = @truncate(w4);
            g = @truncate(w4 >> 8);
            r = @truncate(w4 >> 16);
        },
        wl.WL_SHM_FORMAT_ABGR8888, wl.WL_SHM_FORMAT_RGBA8888 => {
            r = @truncate(w4);
            g = @truncate(w4 >> 8);
            b = @truncate(w4 >> 16);
            a = @truncate(w4 >> 24);
        },
        wl.WL_SHM_FORMAT_XBGR8888, wl.WL_SHM_FORMAT_RGBX8888 => {
            r = @truncate(w4);
            g = @truncate(w4 >> 8);
            b = @truncate(w4 >> 16);
        },
        wl.WL_SHM_FORMAT_XRGB2101010, wl.WL_SHM_FORMAT_ARGB2101010 => {
            b = scale10(@truncate(w4 & 0x3ff));
            g = scale10(@truncate((w4 >> 10) & 0x3ff));
            r = scale10(@truncate((w4 >> 20) & 0x3ff));
            if (fmt == wl.WL_SHM_FORMAT_ARGB2101010) a = scale2(@truncate((w4 >> 30) & 0x3));
        },
        wl.WL_SHM_FORMAT_XBGR2101010, wl.WL_SHM_FORMAT_ABGR2101010 => {
            r = scale10(@truncate(w4 & 0x3ff));
            g = scale10(@truncate((w4 >> 10) & 0x3ff));
            b = scale10(@truncate((w4 >> 20) & 0x3ff));
            if (fmt == wl.WL_SHM_FORMAT_ABGR2101010) a = scale2(@truncate((w4 >> 30) & 0x3));
        },
        wl.WL_SHM_FORMAT_XBGR16161616, wl.WL_SHM_FORMAT_ABGR16161616 => {
            if (p.len < 8) return null;
            const w8 = w8From(p);
            r = scale16(@truncate(w8));
            g = scale16(@truncate((w8 >> 16) & 0xffff));
            b = scale16(@truncate((w8 >> 32) & 0xffff));
            if (fmt == wl.WL_SHM_FORMAT_ABGR16161616) a = scale16(@truncate((w8 >> 48) & 0xffff));
        },
        wl.WL_SHM_FORMAT_XRGB16161616, wl.WL_SHM_FORMAT_ARGB16161616 => {
            if (p.len < 8) return null;
            const w8 = w8From(p);
            b = scale16(@truncate(w8));
            g = scale16(@truncate((w8 >> 16) & 0xffff));
            r = scale16(@truncate((w8 >> 32) & 0xffff));
            if (fmt == wl.WL_SHM_FORMAT_ARGB16161616) a = scale16(@truncate((w8 >> 48) & 0xffff));
        },
        else => return null,
    }
    return .{ r, g, b, a };
}

fn scale10(v: u32) u8 {
    return @intCast(@min(255, (v * 255) / 1023));
}

fn w8From(p: []const u8) u64 {
    return @as(u64, p[0]) | (@as(u64, p[1]) << 8) | (@as(u64, p[2]) << 16) | (@as(u64, p[3]) << 24) |
        (@as(u64, p[4]) << 32) | (@as(u64, p[5]) << 40) | (@as(u64, p[6]) << 48) | (@as(u64, p[7]) << 56);
}

fn scale16(v: u64) u8 {
    return @intCast(@min(255, (v * 255) / 65535));
}

fn scale2(v: u32) u8 {
    return @intCast((v * 255) / 3);
}

/// Output dimensions for a source at `max_dim` on the long side, and the
/// sample block size for that shrink.
pub fn targetDims(width: i32, height: i32, max_dim: i32) [2]i32 {
    const long_side: f64 = @floatFromInt(@max(width, height));
    const cap: f64 = @floatFromInt(max_dim);
    const scale: f64 = if (long_side > cap) long_side / cap else 1.0;
    const tw = @max(1, @round(@as(f64, @floatFromInt(width)) / scale));
    const th = @max(1, @round(@as(f64, @floatFromInt(height)) / scale));
    return .{ @intFromFloat(tw), @intFromFloat(th) };
}

/// Box-filtered shrink into premultiplied BGRA. Only ever shrinks; a
/// source already within `max_dim` is copied 1:1.
pub fn downsample(
    alloc: std.mem.Allocator,
    src: []const u8,
    width: i32,
    height: i32,
    stride: i32,
    fmt: u32,
    y_invert: bool,
    max_dim: i32,
) ![]u8 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const bpp = fmtBpp(fmt) orelse return error.UnsupportedFormat;
    if (src.len == 0 or w == 0 or h == 0) return error.BadDimensions;
    const long_side: f64 = @floatFromInt(@max(width, height));
    const cap: f64 = @floatFromInt(max_dim);
    const scale: f64 = if (long_side > cap) long_side / cap else 1.0;
    const dims = targetDims(width, height, max_dim);
    const tw: usize = @intCast(dims[0]);
    const th: usize = @intCast(dims[1]);
    const samples: usize = @intFromFloat(std.math.clamp(@round(scale), 1.0, 4.0));

    const out = try alloc.alloc(u8, tw * th * 4);
    errdefer alloc.free(out);
    @memset(out, 0);

    for (0..th) |ty| {
        const sy0: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(ty)) * scale));
        const dst_row = out[ty * tw * 4 ..][0 .. tw * 4];
        for (0..tw) |tx| {
            const sx0: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(tx)) * scale));
            var sum_r: u32 = 0;
            var sum_g: u32 = 0;
            var sum_b: u32 = 0;
            var sum_a: u32 = 0;
            var count: u32 = 0;
            var by: usize = 0;
            while (by < samples) : (by += 1) {
                const sy = sy0 + by;
                if (sy >= h) break;
                const fy = if (y_invert) h - 1 - sy else sy;
                const row = src[fy * @as(usize, @intCast(stride)) ..];
                var bx: usize = 0;
                while (bx < samples) : (bx += 1) {
                    const sx = sx0 + bx;
                    if (sx >= w) break;
                    const p = row[sx * bpp ..][0..bpp];
                    const px = pixelRgba(fmt, p) orelse continue;
                    sum_r += px[0];
                    sum_g += px[1];
                    sum_b += px[2];
                    sum_a += px[3];
                    count += 1;
                }
            }
            if (count == 0) continue;
            const a = sum_a / count;
            const r = sum_r / count;
            const g = sum_g / count;
            const b = sum_b / count;
            const o = tx * 4;
            dst_row[o + 0] = @intCast((b * a + 127) / 255);
            dst_row[o + 1] = @intCast((g * a + 127) / 255);
            dst_row[o + 2] = @intCast((r * a + 127) / 255);
            dst_row[o + 3] = @intCast(a);
        }
    }
    return out;
}

/// The hex window address as a 32-bit capture handle, matching what the
/// compositor accepted when the client advertised it.
pub fn handleFromAddr(addr: []const u8) u32 {
    var s = addr;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) s = s[2..];
    var v: u64 = 0;
    for (s) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => break,
        };
        v = (v << 4) | d;
    }
    return @truncate(v);
}

const Session = struct {
    id: u32,
    owner: *Stream,
    frame: ?*wl.hyprland_toplevel_export_frame_v1 = null,
    buf: ?*wl.wl_buffer = null,
    pool: ?*wl.wl_shm_pool = null,
    fd: i32 = -1,
    map: ?[*]u8 = null,
    map_size: usize = 0,
    fmt: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    buf_w: u32 = 0,
    buf_h: u32 = 0,
    y_invert: bool = false,
    failed: bool = false,
    stopped: bool = false,
    one_shot: bool = false,
    max_dim: i32 = 1024,
    last_begin_ms: u64 = 0,
    rechain_pending: bool = false,
    /// Capture attempts made for this window: the initial one plus each
    /// restart after a failure or timeout.
    tries: u32 = 0,
    fail_ms: u64 = 0,
    /// At least one frame reached the owner; no more retries are wanted.
    delivered: bool = false,

    /// Give up on the current attempt: the attempt ages out of the pulse
    /// loop's work set unless a restart still fits in `kMaxTries`.
    fn failAttempt(self: *Session) void {
        if (self.stopped or self.failed) return;
        self.failed = true;
        self.fail_ms = nowMs();
        self.releaseFrame();
    }

    /// Start the next attempt for the same window, backoff elapsed.
    fn restart(self: *Session) void {
        if (self.stopped) return;
        self.tries += 1;
        self.failed = false;
        self.begin();
    }

    fn releaseFrame(self: *Session) void {
        if (self.frame) |f| {
            wl.hyprland_toplevel_export_frame_v1_destroy(f);
            self.frame = null;
        }
    }

    fn releaseBuffer(self: *Session) void {
        if (self.buf) |b| {
            wl.wl_buffer_destroy(b);
            self.buf = null;
        }
        if (self.pool) |p| {
            wl.wl_shm_pool_destroy(p);
            self.pool = null;
        }
        if (self.map) |m| {
            _ = linux.munmap(m, self.map_size);
            self.map = null;
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    fn begin(self: *Session) void {
        if (self.stopped or self.failed) return;
        const mgr = self.owner.mgr orelse return;
        self.rechain_pending = false;
        self.last_begin_ms = nowMs();
        self.fmt = 0;
        self.width = 0;
        self.height = 0;
        self.stride = 0;
        self.y_invert = false;
        const fr = wl.hyprland_toplevel_export_manager_v1_capture_toplevel(mgr, 0, self.id);
        if (fr == null) {
            self.failAttempt();
            return;
        }
        self.frame = fr;
        _ = wl.hyprland_toplevel_export_frame_v1_add_listener(fr, &frame_listener, self);
    }

    fn stop(self: *Session) void {
        self.stopped = true;
        self.releaseFrame();
        self.releaseBuffer();
    }

    /// Buffer parameters arrived: (re)create the shm buffer when the
    /// window changed size, then ask for the copy.
    fn bufferDone(self: *Session) void {
        if (self.stopped or self.failed) return;
        const fr = self.frame orelse return;
        if (self.width == 0 or self.height == 0 or self.stride == 0) {
            self.failAttempt();
            return;
        }
        if (self.buf == null or self.buf_w != self.width or self.buf_h != self.height) {
            self.releaseBuffer();
            const size: usize = @as(usize, self.stride) * @as(usize, self.height);
            var tag_buf: [16:0]u8 = @as([16:0]u8, @splat(0));
            @memcpy(tag_buf[0..7], "eh-live");
            const fd_rc = linux.memfd_create(&tag_buf, linux.MFD.CLOEXEC);
            if (linux.errno(fd_rc) != .SUCCESS) {
                self.failAttempt();
                return;
            }
            self.fd = @intCast(fd_rc);
            if (linux.errno(linux.ftruncate(self.fd, @intCast(size))) != .SUCCESS) {
                _ = linux.close(self.fd);
                self.fd = -1;
                self.failAttempt();
                return;
            }
            const map_rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, self.fd, 0);
            if (linux.errno(map_rc) != .SUCCESS) {
                _ = linux.close(self.fd);
                self.fd = -1;
                self.failAttempt();
                return;
            }
            self.map = @ptrFromInt(map_rc);
            self.map_size = size;
            const shm = self.owner.shm orelse {
                self.releaseBuffer();
                self.failAttempt();
                return;
            };
            self.pool = wl.wl_shm_create_pool(shm, self.fd, @intCast(size));
            if (self.pool == null) {
                self.releaseBuffer();
                self.failAttempt();
                return;
            }
            self.buf = wl.wl_shm_pool_create_buffer(
                self.pool,
                0,
                @intCast(self.width),
                @intCast(self.height),
                @intCast(self.stride),
                self.fmt,
            );
            if (self.buf == null) {
                self.releaseBuffer();
                self.failAttempt();
                return;
            }
            _ = wl.wl_buffer_add_listener(self.buf, &buf_release_listener, null);
            self.buf_w = self.width;
            self.buf_h = self.height;
        }
        wl.hyprland_toplevel_export_frame_v1_copy(fr, self.buf, 1);
    }

    fn ready(self: *Session) void {
        if (self.stopped or self.failed) return;
        self.emit();
        self.releaseFrame();
        if (self.stopped) return;
        if (self.one_shot) {
            // Delivered: keep the frame as a tombstone. Not delivered —
            // the downsample or the owner refused — so the attempt counts
            // as failed and earns a retry from the pulse.
            if (self.delivered) self.stop() else self.failAttempt();
            return;
        }
        if (nowMs() - self.last_begin_ms >= kMinCaptureIntervalMs) {
            self.begin();
        } else {
            self.rechain_pending = true;
        }
    }

    fn emit(self: *Session) void {
        const map = self.map orelse return;
        if (self.width == 0 or self.height == 0) return;
        const size: usize = @as(usize, self.stride) * @as(usize, self.height);
        const bgra = downsample(
            self.owner.alloc,
            map[0..size],
            @intCast(self.width),
            @intCast(self.height),
            @intCast(self.stride),
            self.fmt,
            self.y_invert,
            self.max_dim,
        ) catch return;
        const cb = self.owner.cb orelse {
            self.owner.alloc.free(bgra);
            return;
        };
        const dims = targetDims(@intCast(self.width), @intCast(self.height), self.max_dim);
        cb(self.owner.cb_ctx, .{
            .window_id = self.id,
            .width = dims[0],
            .height = dims[1],
            .bgra = bgra,
        });
        self.delivered = true;
    }

    const frame_listener = wl.hyprland_toplevel_export_frame_v1_listener{
        .buffer = onBuffer,
        .damage = noopDamage,
        .flags = onFlags,
        .ready = onReady,
        .failed = onFailed,
        .linux_dmabuf = noopDmabuf,
        .buffer_done = onBufferDone,
    };

    fn onBuffer(
        data: ?*anyopaque,
        _: ?*wl.hyprland_toplevel_export_frame_v1,
        format: u32,
        width: u32,
        height: u32,
        stride: u32,
    ) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        if (self.stopped or self.failed) return;
        self.fmt = format;
        self.width = width;
        self.height = height;
        self.stride = stride;
    }

    fn noopDamage(_: ?*anyopaque, _: ?*wl.hyprland_toplevel_export_frame_v1, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}

    fn onFlags(data: ?*anyopaque, _: ?*wl.hyprland_toplevel_export_frame_v1, flags: u32) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        if (self.stopped or self.failed) return;
        self.y_invert = (flags & 1) != 0;
    }

    fn onReady(data: ?*anyopaque, _: ?*wl.hyprland_toplevel_export_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        self.ready();
    }

    fn onFailed(data: ?*anyopaque, _: ?*wl.hyprland_toplevel_export_frame_v1) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        self.failAttempt();
    }

    fn noopDmabuf(_: ?*anyopaque, _: ?*wl.hyprland_toplevel_export_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}

    fn onBufferDone(data: ?*anyopaque, _: ?*wl.hyprland_toplevel_export_frame_v1) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        self.bufferDone();
    }

    const buf_release_listener = wl.wl_buffer_listener{ .release = noopRelease };

    fn noopRelease(_: ?*anyopaque, _: ?*wl.wl_buffer) callconv(.c) void {}
};

/// The set of windows to capture: sessions are created and torn down to
/// match on every `syncWindows`, and `tick` paces deferred re-requests.
pub const Stream = struct {
    alloc: std.mem.Allocator,
    mgr: ?*wl.hyprland_toplevel_export_manager_v1 = null,
    shm: ?*wl.wl_shm = null,
    cb_ctx: *anyopaque = undefined,
    cb: ?Callback = null,
    one_shot: bool = false,
    sessions: std.ArrayList(*Session) = .empty,
    /// Stall and retry events since the stream started, for the owner's
    /// diagnostics: the numbers say why a tile is still empty.
    stalls: u32 = 0,
    retries: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) Stream {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Stream) void {
        self.stop();
        self.sessions.deinit(self.alloc);
    }

    /// Ready when both the manager and shm are bound; frames then arrive
    /// on the display's normal dispatch.
    pub fn start(self: *Stream, mgr: ?*wl.hyprland_toplevel_export_manager_v1, shm: ?*wl.wl_shm, ctx: *anyopaque, cb: Callback) bool {
        self.stop();
        if (mgr == null or shm == null) return false;
        self.mgr = mgr;
        self.shm = shm;
        self.cb_ctx = ctx;
        self.cb = cb;
        return true;
    }

    pub fn active(self: *const Stream) bool {
        return self.mgr != null;
    }

    pub fn setOneShot(self: *Stream, one_shot: bool) void {
        self.one_shot = one_shot;
    }

    /// Match the session set to `ids`: drop what is gone, then open a
    /// session for each window not yet covered. Failed sessions stay in
    /// the list as tombstones — `tick` restarts them within the attempt
    /// budget, and keeping them stops a burst of syncs from resetting the
    /// budget (or re-asking for a window the compositor refuses).
    pub fn syncWindows(self: *Stream, ids: []const u32, max_dim: i32) void {
        const dim: i32 = @max(64, max_dim);
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const s = self.sessions.items[i];
            if (!containsId(ids, s.id)) {
                s.stop();
                _ = self.sessions.orderedRemove(i);
                self.alloc.destroy(s);
                continue;
            }
            i += 1;
        }
        for (ids) |id| {
            if (self.sessionFor(id) != null) continue;
            const s = self.alloc.create(Session) catch continue;
            s.* = .{ .id = id, .owner = self, .one_shot = self.one_shot, .max_dim = dim, .tries = 1 };
            self.sessions.append(self.alloc, s) catch {
                self.alloc.destroy(s);
                continue;
            };
            s.begin();
        }
    }

    /// Run the session state machine once: give stalled attempts their
    /// timeout, restart failed ones whose backoff has elapsed, and release
    /// deferred re-requests whose pacing interval has passed. Call every
    /// paint frame while `needsWork` holds, and from the paint loop.
    pub fn tick(self: *Stream) void {
        const now = nowMs();
        for (self.sessions.items) |s| {
            if (s.stopped) continue;
            if (s.failed) {
                if (s.tries < kMaxTries and now - s.fail_ms >= kRetryBackoffMs) {
                    self.retries += 1;
                    s.restart();
                }
                continue;
            }
            // Requested but never answered: both the buffer listing and
            // the ready notification live behind this one deadline.
            if (s.frame != null and now - s.last_begin_ms >= kAttemptTimeoutMs) {
                self.stalls += 1;
                s.failAttempt();
                continue;
            }
            if (s.rechain_pending and now - s.last_begin_ms >= kMinCaptureIntervalMs) {
                s.begin();
            }
        }
    }

    /// True while any session still owes the owner a first frame (or a
    /// restart within its attempt budget). The pulse loop keeps ticking
    /// exactly this long, then goes quiet.
    pub fn needsWork(self: *const Stream) bool {
        for (self.sessions.items) |s| {
            if (s.stopped or s.delivered) continue;
            if (!s.failed or s.tries < kMaxTries) return true;
        }
        return false;
    }

    pub fn stop(self: *Stream) void {
        for (self.sessions.items) |s| {
            s.stop();
            self.alloc.destroy(s);
        }
        self.sessions.clearRetainingCapacity();
        self.mgr = null;
        self.shm = null;
        self.cb = null;
    }

    fn sessionFor(self: *Stream, id: u32) ?*Session {
        for (self.sessions.items) |s| {
            if (s.id == id) return s;
        }
        return null;
    }

    /// Reset one window's attempt budget so the reveal pass can force a
    /// fresh capture for it. False when no session covers the window.
    pub fn retrySessionFor(self: *Stream, id: u32) bool {
        const s = self.sessionFor(id) orelse return false;
        if (s.stopped) return false;
        s.tries = 0;
        s.failed = false;
        s.delivered = false;
        s.rechain_pending = false;
        s.releaseFrame();
        s.begin();
        return true;
    }
};

fn containsId(ids: []const u32, id: u32) bool {
    for (ids) |x| {
        if (x == id) return true;
    }
    return false;
}

test "toplevel-stream: addr handle truncates to 32 bits" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0xabc), handleFromAddr("0xabc"));
    try t.expectEqual(@as(u32, 0x90abcdef), handleFromAddr("0x1234567890abcdef"));
    try t.expectEqual(@as(u32, 0), handleFromAddr("zzz"));
}

test "toplevel-stream: unsupported format is rejected" {
    const t = std.testing;
    const buf = @as([16]u8, @splat(0));
    try t.expectError(error.UnsupportedFormat, downsample(t.allocator, &buf, 2, 2, 8, 0xdead, false, 256));
}

test "toplevel-stream: same-size source copies straight through" {
    const t = std.testing;
    // Two ARGB8888 pixels (byte order B,G,R,A): opaque red, blue at 0x80.
    const src = [_]u8{
        0x00, 0x00, 0xff, 0xff,
        0x80, 0x00, 0x00, 0x80,
    };
    const out = try downsample(t.allocator, &src, 2, 1, 8, wl.WL_SHM_FORMAT_ARGB8888, false, 256);
    defer t.allocator.free(out);
    try t.expectEqual(@as(usize, 8), out.len);
    // Opaque red survives as premultiplied BGRA: red channel full.
    try t.expectEqual(@as(u8, 0x00), out[0]);
    try t.expectEqual(@as(u8, 0xff), out[2]);
    try t.expectEqual(@as(u8, 0xff), out[3]);
    // Blue 0xff at alpha 0x80 premultiplies to (0x80*0x80+127)/255 = 0x40.
    try t.expectEqual(@as(u8, 0x40), out[4]);
    try t.expectEqual(@as(u8, 0x80), out[7]);
}

test "toplevel-stream: shrink averages the source block" {
    const t = std.testing;
    // 4x2 XRGB: left half black, right half white; shrink to 2x1.
    var src: [4 * 2 * 4]u8 = undefined;
    for (0..2) |y| {
        for (0..4) |x| {
            const v: u8 = if (x < 2) 0x00 else 0xff;
            const o = (y * 4 + x) * 4;
            src[o + 0] = v;
            src[o + 1] = v;
            src[o + 2] = v;
            src[o + 3] = 0xff;
        }
    }
    const out = try downsample(t.allocator, &src, 4, 2, 16, wl.WL_SHM_FORMAT_XRGB8888, false, 2);
    defer t.allocator.free(out);
    try t.expectEqual(@as(usize, 8), out.len);
    try t.expectEqual(@as(u8, 0x00), out[2]);
    try t.expectEqual(@as(u8, 0xff), out[6]);
}
