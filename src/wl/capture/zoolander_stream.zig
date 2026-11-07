//! Continuous per-window frame streaming over ext-image-copy-capture protocol
//! (used by Zoolander and other compositors). Uses ext-foreign-toplevel-image-
//! capture-source to create sources, then ext-image-copy-capture-manager to
//! stream frames. Mirrors the Hyprland toplevel-export stream API.

const std = @import("std");
const wl = @import("../c.zig").wl;
const linux = std.os.linux;
const stream_mod = @import("toplevel_stream.zig");

/// A completed frame of one toplevel. `bgra` is 8-bit premultiplied
/// BGRA in CAIRO_FORMAT_ARGB32 order, top-down, owned by the receiver.
pub const Frame = stream_mod.Frame;

pub const Callback = stream_mod.Callback;

/// Bytes per pixel for the shm formats a copy may arrive in.
pub fn fmtBpp(fmt: u32) ?u32 {
    return stream_mod.fmtBpp(fmt);
}

/// Decode one source pixel to straight 8-bit RGBA.
pub fn pixelRgba(fmt: u32, p: []const u8) ?[4]u8 {
    return stream_mod.pixelRgba(fmt, p);
}

/// Output dimensions for a source at `max_dim` on the long side.
pub fn targetDims(width: i32, height: i32, max_dim: i32) [2]i32 {
    return stream_mod.targetDims(width, height, max_dim);
}

/// Box-filtered shrink into premultiplied BGRA.
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
    return stream_mod.downsample(alloc, src, width, height, stride, fmt, y_invert, max_dim);
}

const kMinCaptureIntervalMs: u64 = 16;
const kAttemptTimeoutMs: u64 = 2000;
const kRetryBackoffMs: u64 = 750;
const kMaxTries: u32 = 3;

fn nowMs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

const Session = struct {
    id: u32,
    handle: *wl.ext_foreign_toplevel_handle_v1,
    source: ?*wl.ext_image_capture_source_v1 = null,
    owner: *Stream,
    session: ?*wl.ext_image_copy_capture_session_v1 = null,
    frame: ?*wl.ext_image_copy_capture_frame_v1 = null,
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
    tries: u32 = 0,
    fail_ms: u64 = 0,
    delivered: bool = false,
    size_limited: bool = false,

    fn failAttempt(self: *Session) void {
        if (self.stopped or self.failed) return;
        self.failed = true;
        self.fail_ms = nowMs();
        self.releaseFrame();
    }

    fn restart(self: *Session) void {
        if (self.stopped) return;
        self.tries += 1;
        self.failed = false;
        self.begin();
    }

    fn releaseFrame(self: *Session) void {
        if (self.frame) |f| {
            wl.ext_image_copy_capture_frame_v1_destroy(f);
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

    fn releaseSource(self: *Session) void {
        if (self.source) |s| {
            wl.ext_image_capture_source_v1_destroy(s);
            self.source = null;
        }
    }

    fn releaseSession(self: *Session) void {
        if (self.session) |s| {
            wl.ext_image_copy_capture_session_v1_destroy(s);
            self.session = null;
        }
    }

    fn begin(self: *Session) void {
        if (self.stopped or self.failed) return;
        const copy_mgr = self.owner.copy_mgr orelse return;
        const src_mgr = self.owner.src_mgr orelse return;
        self.rechain_pending = false;
        self.last_begin_ms = nowMs();
        self.fmt = wl.WL_SHM_FORMAT_ARGB8888;
        self.width = 0;
        self.height = 0;
        self.stride = 0;
        self.y_invert = false;

        // Create image capture source for this toplevel handle
        self.releaseSource();
        self.source = wl.ext_foreign_toplevel_image_capture_source_manager_v1_create_source(src_mgr, self.handle);
        if (self.source == null) {
            self.failAttempt();
            return;
        }

        // Create capture session from the source
        self.releaseSession();
        const opts: u32 = 0; // no cursor painting
        self.session = wl.ext_image_copy_capture_manager_v1_create_session(copy_mgr, self.source.?, opts);
        if (self.session == null) {
            self.failAttempt();
            return;
        }
        _ = wl.ext_image_copy_capture_session_v1_add_listener(self.session, &session_listener, self);

        // Zoolander scales the capture down itself, straight into our small
        // buffer, instead of handing over full size for us to shrink.
        self.size_limited = false;
        if (self.owner.size_mgr) |mgr| {
            if (wl.zoolander_image_copy_capture_size_manager_v1_get_session_size(mgr, self.session)) |sz| {
                const lim: u32 = @intCast(@max(1, self.max_dim));
                wl.zoolander_image_copy_capture_session_size_v1_set_max_size(sz, lim, lim);
                wl.zoolander_image_copy_capture_session_size_v1_destroy(sz);
                self.size_limited = true;
            }
        }
    }

    fn stop(self: *Session) void {
        self.stopped = true;
        self.releaseFrame();
        self.releaseBuffer();
        self.releaseSession();
        self.releaseSource();
    }

    fn bufferDone(self: *Session) void {
        if (self.stopped or self.failed) return;
        const fr = self.frame orelse return;
        const bpp = fmtBpp(self.fmt) orelse {
            self.failAttempt();
            return;
        };
        self.stride = self.width * bpp;
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
        wl.ext_image_copy_capture_frame_v1_attach_buffer(fr, self.buf);
        wl.ext_image_copy_capture_frame_v1_damage_buffer(fr, 0, 0, @intCast(self.width), @intCast(self.height));
        wl.ext_image_copy_capture_frame_v1_capture(fr);
    }

    fn ready(self: *Session) void {
        if (self.stopped or self.failed) return;
        self.emit();
        self.releaseFrame();
        if (self.stopped) return;
        if (self.one_shot) {
            if (self.delivered) self.stop() else self.failAttempt();
            return;
        }
        if (nowMs() - self.last_begin_ms >= kMinCaptureIntervalMs) {
            self.requestFrame();
        } else {
            self.rechain_pending = true;
        }
    }

    fn requestFrame(self: *Session) void {
        const sess = self.session orelse return;
        self.releaseFrame();
        self.frame = wl.ext_image_copy_capture_session_v1_create_frame(sess);
        if (self.frame == null) {
            self.failAttempt();
            return;
        }
        _ = wl.ext_image_copy_capture_frame_v1_add_listener(self.frame, &frame_listener, self);
        self.bufferDone();
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

    const session_listener = wl.ext_image_copy_capture_session_v1_listener{
        .buffer_size = onSessionBufferSize,
        .shm_format = onSessionShmFormat,
        .dmabuf_device = noopDmabufDevice,
        .dmabuf_format = noopDmabufFormat,
        .done = onSessionDone,
        .stopped = onSessionStopped,
    };

    fn onSessionBufferSize(
        data: ?*anyopaque,
        _: ?*wl.ext_image_copy_capture_session_v1,
        width: u32,
        height: u32,
    ) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        if (self.stopped or self.failed) return;
        self.width = width;
        self.height = height;
    }

    fn onSessionShmFormat(
        data: ?*anyopaque,
        _: ?*wl.ext_image_copy_capture_session_v1,
        format: u32,
    ) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        if (self.stopped or self.failed) return;
        // Sessions list every format they accept; keep one we can decode
        // (an HDR-first list would otherwise leave us on an unsupported one).
        if (fmtBpp(format) != null) self.fmt = format;
    }

    fn noopDmabufDevice(_: ?*anyopaque, _: ?*wl.ext_image_copy_capture_session_v1, _: [*c]wl.wl_array) callconv(.c) void {}
    fn noopDmabufFormat(_: ?*anyopaque, _: ?*wl.ext_image_copy_capture_session_v1, _: u32, _: [*c]wl.wl_array) callconv(.c) void {}

    fn onSessionDone(
        data: ?*anyopaque,
        _: ?*wl.ext_image_copy_capture_session_v1,
    ) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        if (self.stopped or self.failed) return;
        // After set_max_size the session first advertises full size, then the
        // fitted size; wait for the fitted one so no oversized buffer is made.
        if (self.size_limited) {
            const lim: u32 = @intCast(@max(1, self.max_dim));
            if (self.width > lim or self.height > lim) return;
        }
        self.requestFrame();
    }

    fn onSessionStopped(
        data: ?*anyopaque,
        _: ?*wl.ext_image_copy_capture_session_v1,
    ) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        self.failAttempt();
    }

    const frame_listener = wl.ext_image_copy_capture_frame_v1_listener{
        .transform = onFrameTransform,
        .damage = onFrameDamage,
        .ready = onFrameReady,
        .failed = onFrameFailed,
        .presentation_time = noopPresentationTime,
    };

    fn noopPresentationTime(_: ?*anyopaque, _: ?*wl.ext_image_copy_capture_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}

    fn onFrameTransform(
        data: ?*anyopaque,
        _: ?*wl.ext_image_copy_capture_frame_v1,
        transform: u32,
    ) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        if (self.stopped or self.failed) return;
        // Ignore transform for now - we assume unrotated
        _ = transform;
    }

    fn onFrameDamage(
        data: ?*anyopaque,
        _: ?*wl.ext_image_copy_capture_frame_v1,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        if (self.stopped or self.failed) return;
        // We read the whole buffer, so damage is not needed
        _ = x; _ = y; _ = width; _ = height;
    }

    fn onFrameReady(
        data: ?*anyopaque,
        _: ?*wl.ext_image_copy_capture_frame_v1,
    ) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        self.ready();
    }

    fn onFrameFailed(
        data: ?*anyopaque,
        _: ?*wl.ext_image_copy_capture_frame_v1,
        _: u32,
    ) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data orelse return));
        self.failAttempt();
    }

    const buf_release_listener = wl.wl_buffer_listener{ .release = noopRelease };

    fn noopRelease(_: ?*anyopaque, _: ?*wl.wl_buffer) callconv(.c) void {}
};

/// The set of windows to capture.
pub const Stream = struct {
    alloc: std.mem.Allocator,
    copy_mgr: ?*wl.ext_image_copy_capture_manager_v1 = null,
    src_mgr: ?*wl.ext_foreign_toplevel_image_capture_source_manager_v1 = null,
    shm: ?*wl.wl_shm = null,
    size_mgr: ?*wl.zoolander_image_copy_capture_size_manager_v1 = null,
    cb_ctx: *anyopaque = undefined,
    cb: ?Callback = null,
    one_shot: bool = false,
    sessions: std.ArrayList(*Session) = .empty,
    stalls: u32 = 0,
    retries: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) Stream {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Stream) void {
        self.stop();
        self.sessions.deinit(self.alloc);
    }

    /// Ready when both managers and shm are bound.
    pub fn start(
        self: *Stream,
        copy_mgr: ?*wl.ext_image_copy_capture_manager_v1,
        src_mgr: ?*wl.ext_foreign_toplevel_image_capture_source_manager_v1,
        shm: ?*wl.wl_shm,
        size_mgr: ?*wl.zoolander_image_copy_capture_size_manager_v1,
        ctx: *anyopaque,
        cb: Callback,
    ) bool {
        self.stop();
        if (copy_mgr == null or src_mgr == null or shm == null) return false;
        self.copy_mgr = copy_mgr;
        self.src_mgr = src_mgr;
        self.shm = shm;
        self.size_mgr = size_mgr;
        self.cb_ctx = ctx;
        self.cb = cb;
        return true;
    }

    pub fn active(self: *const Stream) bool {
        return self.copy_mgr != null and self.src_mgr != null;
    }

    pub fn setOneShot(self: *Stream, one_shot: bool) void {
        self.one_shot = one_shot;
    }

    /// Match the session set to `handles`.
    pub fn syncWindows(self: *Stream, handles: []const *wl.ext_foreign_toplevel_handle_v1, ids: []const u32, max_dim: i32) void {
        const dim: i32 = @max(64, max_dim);
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const s = self.sessions.items[i];
            if (!containsHandle(handles, s.handle)) {
                s.stop();
                _ = self.sessions.orderedRemove(i);
                self.alloc.destroy(s);
                continue;
            }
            i += 1;
        }
        for (handles, 0..) |h, hi| {
            if (self.sessionFor(h) != null) continue;
            if (hi >= ids.len) break;
            const s = self.alloc.create(Session) catch continue;
            s.* = .{ .id = ids[hi], .handle = h, .owner = self, .one_shot = self.one_shot, .max_dim = dim, .tries = 1 };
            self.sessions.append(self.alloc, s) catch {
                self.alloc.destroy(s);
                continue;
            };
            s.begin();
        }
    }

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
            if (s.frame != null and now - s.last_begin_ms >= kAttemptTimeoutMs) {
                self.stalls += 1;
                s.failAttempt();
                continue;
            }
            if (s.rechain_pending and now - s.last_begin_ms >= kMinCaptureIntervalMs) {
                s.requestFrame();
            }
        }
    }

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
        self.copy_mgr = null;
        self.src_mgr = null;
        self.shm = null;
        self.size_mgr = null;
        self.cb = null;
    }

    fn sessionFor(self: *Stream, h: *wl.ext_foreign_toplevel_handle_v1) ?*Session {
        for (self.sessions.items) |s| {
            if (s.handle == h) return s;
        }
        return null;
    }

    /// Reset one window's attempt budget for a forced fresh capture.
    /// `h` is the foreign toplevel handle from the tracker.
    pub fn retrySessionFor(self: *Stream, h: ?*wl.ext_foreign_toplevel_handle_v1) bool {
        const handle = h orelse return false;
        const s = self.sessionFor(handle) orelse return false;
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

fn containsHandle(handles: []const *wl.ext_foreign_toplevel_handle_v1, h: *wl.ext_foreign_toplevel_handle_v1) bool {
    for (handles) |x| {
        if (x == h) return true;
    }
    return false;
}

test "zoolander-capture: handle identity" {
    const t = std.testing;
    const h1 = @as(*wl.ext_foreign_toplevel_handle_v1, @ptrFromInt(0x1234));
    const h2 = @as(*wl.ext_foreign_toplevel_handle_v1, @ptrFromInt(0x5678));
    const handles = [_]*wl.ext_foreign_toplevel_handle_v1{h1, h2};
    try t.expect(containsHandle(&handles, h1));
    try t.expect(containsHandle(&handles, h2));
    try t.expect(!containsHandle(&handles, @as(*wl.ext_foreign_toplevel_handle_v1, @ptrFromInt(0x9abc))));
}