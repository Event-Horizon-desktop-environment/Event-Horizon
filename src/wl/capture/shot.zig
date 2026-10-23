//! Screenshot capture: one synchronous frame of an output, a region of an
//! output, or a toplevel, decoded to straight 8-bit RGBA in memory for the
//! caller to crop, encode, or hand to the clipboard.
//!
//! Two backends, in the order the C++ `screencopy_png.cpp` documented:
//! ext-image-copy-capture first (a session per source, cursor painting and
//! buffer constraints decided once), zwlr-screencopy as the fallback older
//! compositors still speak. Every wait is bounded — a compositor that never
//! answers costs one timeout, not a hung shell.
//!
//! HDR is deliberately absent: both paths read 8-bit buffers only, so a
//! capture on an HDR output lands in SDR range. The C++ side reached for
//! jxl/png-16 to keep the extra range; until that decision is made here, a
//! session offering only half-float formats is reported as unsupported and
//! the caller falls through to the other backend.
//!
//! `output_copy.zig` is the shell's *live* capture path (throttled, boxed
//! down to a thumbnail, premultiplied BGRA). This file is the screenshot
//! path: full resolution, straight alpha, one frame per call. They share
//! only the format table in `toplevel_stream.zig`.

const std = @import("std");
const wl = @import("../c.zig").wl;
const linux = std.os.linux;
const wait = @import("wait.zig");
const stream = @import("toplevel_stream.zig");

/// stb_image_write: declarations from the header, implementation in
/// `src/c/stb_write.c` — its own translation unit so the writer symbols
/// stay extern and linkable from Zig.
extern fn eh_write_png(path: [*:0]const u8, w: c_int, h: c_int, data: [*]const u8, stride: c_int, exclusive: c_int) c_int;

/// One attempt per backend. Long enough for a busy compositor, short enough
/// that a dead one fails the screenshot instead of wedging the shell.
const kWaitMs: u64 = 10_000;

/// One captured frame in straight 8-bit RGBA, top-down.
pub const Image = struct {
    width: i32 = 0,
    height: i32 = 0,
    /// `width*height*4` bytes, non-premultiplied (what a PNG wants).
    rgba: []u8 = &.{},

    pub fn init(alloc: std.mem.Allocator, width: i32, height: i32) !Image {
        if (width <= 0 or height <= 0) return error.BadDimensions;
        const w: usize = @intCast(width);
        const h: usize = @intCast(height);
        return .{ .width = width, .height = height, .rgba = try alloc.alloc(u8, w * h * 4) };
    }

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        if (self.rgba.len != 0) alloc.free(self.rgba);
        self.* = .{};
    }

    /// Output-local rectangle crop. A box that would leave the frame is an
    /// error, not a clamp: a region computed against a stale output layout
    /// should fail loudly rather than quietly ship the wrong pixels.
    pub fn crop(self: *const Image, alloc: std.mem.Allocator, x: i32, y: i32, w: i32, h: i32) !Image {
        if (w <= 0 or h <= 0) return error.BadDimensions;
        if (x < 0 or y < 0) return error.OutOfBounds;
        if (x + w > self.width or y + h > self.height) return error.OutOfBounds;
        const w_us: usize = @intCast(w);
        const h_us: usize = @intCast(h);
        const src_w: usize = @intCast(self.width);
        const x_us: usize = @intCast(x);
        const y_us: usize = @intCast(y);
        var out = try Image.init(alloc, w, h);
        errdefer out.deinit(alloc);
        const row = w_us * 4;
        for (0..h_us) |y0| {
            const off = ((y_us + y0) * src_w + x_us) * 4;
            @memcpy(out.rgba[y0 * row ..][0..row], self.rgba[off..][0..row]);
        }
        return out;
    }
};

/// Every capture manager a caller happens to have bound. A null member just
/// drops that backend — `captureOutput` reports `error.NoBackend` only when
/// nothing at all could serve the request.
pub const Backends = struct {
    display: ?*wl.wl_display = null,
    shm: ?*wl.wl_shm = null,
    ext_copy: ?*wl.ext_image_copy_capture_manager_v1 = null,
    ext_output_source: ?*wl.ext_output_image_capture_source_manager_v1 = null,
    ext_toplevel_source: ?*wl.ext_foreign_toplevel_image_capture_source_manager_v1 = null,
    wlr: ?*wl.zwlr_screencopy_manager_v1 = null,
};

/// One full output, cursor painted in when asked. ext first (the backend the
/// usage text promises), wlr behind it.
pub fn captureOutput(
    alloc: std.mem.Allocator,
    b: *const Backends,
    output: ?*wl.wl_output,
    cursor: bool,
) !Image {
    if (try extOutputOnce(alloc, b, output, cursor)) |img| return img;
    if (b.wlr != null) return wlrCapture(alloc, b, output, cursor, null);
    return error.NoBackend;
}

/// One region of an output in OUTPUT-LOCAL logical pixels. ext-image-copy-
/// capture has no region request, so that path grabs the whole output and
/// crops — matching the C++ flow, minus its bug of passing global
/// coordinates where zwlr's region request wants output-local ones.
pub fn captureRegion(
    alloc: std.mem.Allocator,
    b: *const Backends,
    output: ?*wl.wl_output,
    lx: i32,
    ly: i32,
    lw: i32,
    lh: i32,
    cursor: bool,
) !Image {
    if (lw <= 0 or lh <= 0) return error.BadDimensions;
    if (try extOutputOnce(alloc, b, output, cursor)) |full| {
        var owned = full;
        defer owned.deinit(alloc);
        return try owned.crop(alloc, lx, ly, lw, lh);
    }
    if (b.wlr != null) return wlrCapture(alloc, b, output, cursor, .{ lx, ly, lw, lh });
    return error.NoBackend;
}

/// One toplevel. ext-foreign-toplevel capture sources are the only route;
/// `handle` comes from an `ext_foreign_toplevel_list_v1` dump.
pub fn captureToplevel(
    alloc: std.mem.Allocator,
    b: *const Backends,
    handle: ?*wl.ext_foreign_toplevel_handle_v1,
    cursor: bool,
) !Image {
    const copy = b.ext_copy orelse return error.NoBackend;
    const mgr = b.ext_toplevel_source orelse return error.NoBackend;
    const h = handle orelse return error.NoWindow;
    const src = wl.ext_foreign_toplevel_image_capture_source_manager_v1_create_source(mgr, h);
    if (src == null) return error.CaptureFailed;
    defer wl.ext_image_capture_source_v1_destroy(src);
    return extCapture(alloc, b.display, b.shm, copy, src, cursor);
}

/// Write an 8-bit RGBA PNG. The path is copied into a fixed buffer because
/// the C writer takes a NUL-terminated one. Temporary captures use exclusive
/// creation; explicitly named destinations can be overwritten.
pub fn writePng(path: []const u8, img: *const Image, exclusive: bool) !void {
    if (img.width <= 0 or img.height <= 0 or img.rgba.len == 0) return error.BadDimensions;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    const zpath = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return error.PathTooLong;
    const rc = eh_write_png(
        zpath.ptr,
        @intCast(img.width),
        @intCast(img.height),
        img.rgba.ptr,
        @intCast(img.width * 4),
        @intFromBool(exclusive),
    );
    if (rc == 0) return error.WriteFailed;
}

/// Decode a captured mapping into straight RGBA8, honoring the source's
/// y-inversion. `stride` is bytes per source row.
pub fn decodeRgba(
    alloc: std.mem.Allocator,
    map: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    fmt: u32,
    y_invert: bool,
) !Image {
    const w_us: usize = width;
    const h_us: usize = height;
    const st: usize = stride;
    const bpp: usize = @intCast(stream.fmtBpp(fmt) orelse return error.UnsupportedFormat);
    if (w_us == 0 or h_us == 0 or st < w_us * bpp) return error.BadDimensions;
    if (map.len < (h_us - 1) * st + w_us * bpp) return error.BadDimensions;

    var img = try Image.init(alloc, @intCast(width), @intCast(height));
    errdefer img.deinit(alloc);
    for (0..h_us) |y| {
        const sy = if (y_invert) h_us - 1 - y else y;
        const row = map[sy * st ..];
        var x: usize = 0;
        while (x < w_us) : (x += 1) {
            const px = stream.pixelRgba(fmt, row[x * bpp ..][0..bpp]) orelse return error.UnsupportedFormat;
            const o = (y * w_us + x) * 4;
            @memcpy(img.rgba[o .. o + 4], px[0..4]);
        }
    }
    return img;
}

// zwlr-screencopy

const WlrCtx = struct {
    fmt: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    listed: bool = false,
    ready: bool = false,
    failed: bool = false,
    y_invert: bool = false,
    /// v3 replaced the per-buffer `buffer` event with a `buffer_done`
    /// batch terminator; pre-v3 compositors announce each buffer inline.
    v3: bool = false,

    fn paramsDone(self: *const WlrCtx) bool {
        return self.listed or self.failed;
    }
};

/// The buffer's release is tracked separately from the frame: `ready` means
/// the compositor finished writing, `release` means it is done with the
/// buffer. The C++ path waits for both before reading the mapping.
const ReleaseFlag = struct {
    released: bool = false,

    fn onRelease(data: ?*anyopaque, _: ?*wl.wl_buffer) callconv(.c) void {
        const f: *ReleaseFlag = @ptrCast(@alignCast(data orelse return));
        f.released = true;
    }

    const listener = wl.wl_buffer_listener{ .release = onRelease };
};

const WlrWait = struct {
    ctx: *const WlrCtx,
    release: *const ReleaseFlag,

    fn copyDone(self: *const WlrWait) bool {
        const settled = self.ctx.ready or self.ctx.failed;
        // A compositor may legally never send `release` for a buffer it
        // handed out and immediately dropped, so only `ready` is required.
        return settled and (self.release.released or !self.ctx.ready);
    }
};

fn wlrOnBuffer(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, format: u32, w: u32, h: u32, stride: u32) callconv(.c) void {
    const self: *WlrCtx = @ptrCast(@alignCast(data orelse return));
    self.fmt = format;
    self.width = w;
    self.height = h;
    self.stride = stride;
    if (!self.v3) self.listed = true;
}

fn wlrOnFlags(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, flags: u32) callconv(.c) void {
    const self: *WlrCtx = @ptrCast(@alignCast(data orelse return));
    self.y_invert = (flags & 1) != 0;
}

fn wlrOnReady(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {
    const self: *WlrCtx = @ptrCast(@alignCast(data orelse return));
    self.ready = true;
}

fn wlrOnFailed(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1) callconv(.c) void {
    const self: *WlrCtx = @ptrCast(@alignCast(data orelse return));
    self.failed = true;
}

fn wlrOnDamage(_: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}

fn wlrOnDmabuf(_: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}

fn wlrOnBufferDone(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1) callconv(.c) void {
    const self: *WlrCtx = @ptrCast(@alignCast(data orelse return));
    self.listed = true;
}

const wlr_listener = wl.zwlr_screencopy_frame_v1_listener{
    .buffer = wlrOnBuffer,
    .flags = wlrOnFlags,
    .ready = wlrOnReady,
    .failed = wlrOnFailed,
    .damage = wlrOnDamage,
    .linux_dmabuf = wlrOnDmabuf,
    .buffer_done = wlrOnBufferDone,
};

fn wlrCapture(
    alloc: std.mem.Allocator,
    b: *const Backends,
    output: ?*wl.wl_output,
    cursor: bool,
    region: ?[4]i32,
) !Image {
    const m = b.wlr orelse return error.NoBackend;
    const d = b.display orelse return error.NoDisplay;
    const s = b.shm orelse return error.NoShm;
    const out = output orelse return error.NoOutput;
    const flag: u8 = @intFromBool(cursor);

    const fr = if (region) |r|
        wl.zwlr_screencopy_manager_v1_capture_output_region(m, flag, out, r[0], r[1], r[2], r[3])
    else
        wl.zwlr_screencopy_manager_v1_capture_output(m, flag, out);
    if (fr == null) return error.CaptureFailed;
    defer wl.zwlr_screencopy_frame_v1_destroy(fr);

    var ctx = WlrCtx{ .v3 = wl.zwlr_screencopy_frame_v1_get_version(fr) >= 3 };
    _ = wl.zwlr_screencopy_frame_v1_add_listener(fr, &wlr_listener, &ctx);
    if (!wait.pumpUntil(d, &ctx, WlrCtx.paramsDone, kWaitMs)) return error.CaptureTimeout;
    if (ctx.failed or !ctx.listed or ctx.width == 0 or ctx.height == 0) return error.CaptureFailed;
    const bpp = stream.fmtBpp(ctx.fmt) orelse return error.UnsupportedFormat;
    if (ctx.stride < ctx.width * bpp) return error.CaptureFailed;

    var target = try ShmTarget.create(s, ctx.width, ctx.height, ctx.stride, ctx.fmt);
    defer target.deinit();
    _ = wl.zwlr_screencopy_frame_v1_copy(fr, target.buffer.?);

    const state = WlrWait{ .ctx = &ctx, .release = &target.release };
    if (!wait.pumpUntil(d, &state, WlrWait.copyDone, kWaitMs)) return error.CaptureTimeout;
    if (ctx.failed or !ctx.ready) return error.CaptureFailed;

    return decodeRgba(alloc, target.map.?[0..target.map_size], ctx.width, ctx.height, ctx.stride, ctx.fmt, ctx.y_invert);
}

// ext-image-copy-capture

const ExtCtx = struct {
    session: ?*wl.ext_image_copy_capture_session_v1 = null,
    frame: ?*wl.ext_image_copy_capture_frame_v1 = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Last offered shm format we can decode; the session lists each one it
    /// accepts, so the choice is ours.
    fmt: u32 = wl.WL_SHM_FORMAT_ARGB8888,
    have_constraints: bool = false,
    frame_done: bool = false,
    frame_ok: bool = false,
    failed: bool = false,

    fn constraintsDone(self: *const ExtCtx) bool {
        return self.have_constraints or self.failed;
    }

    fn frameArrived(self: *const ExtCtx) bool {
        return self.frame_done or self.failed;
    }
};

fn extOnBufferSize(data: ?*anyopaque, _: ?*wl.ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.c) void {
    const self: *ExtCtx = @ptrCast(@alignCast(data orelse return));
    self.width = w;
    self.height = h;
}

fn extOnShmFormat(data: ?*anyopaque, _: ?*wl.ext_image_copy_capture_session_v1, format: u32) callconv(.c) void {
    const self: *ExtCtx = @ptrCast(@alignCast(data orelse return));
    // Prefer any decodable format: an HDR-only session lists half-float
    // first and 8-bit second, and taking "the last one" would land us on a
    // buffer we refuse to turn into a PNG.
    if (stream.fmtBpp(format) != null) self.fmt = format;
}

fn extOnDmabufDevice(_: ?*anyopaque, _: ?*wl.ext_image_copy_capture_session_v1, _: ?*wl.wl_array) callconv(.c) void {}

fn extOnDmabufFormat(_: ?*anyopaque, _: ?*wl.ext_image_copy_capture_session_v1, _: u32, _: ?*wl.wl_array) callconv(.c) void {}

fn extOnDone(data: ?*anyopaque, _: ?*wl.ext_image_copy_capture_session_v1) callconv(.c) void {
    const self: *ExtCtx = @ptrCast(@alignCast(data orelse return));
    self.have_constraints = true;
}

fn extOnStopped(data: ?*anyopaque, _: ?*wl.ext_image_copy_capture_session_v1) callconv(.c) void {
    const self: *ExtCtx = @ptrCast(@alignCast(data orelse return));
    self.failed = true;
}

const ext_session_listener = wl.ext_image_copy_capture_session_v1_listener{
    .buffer_size = extOnBufferSize,
    .shm_format = extOnShmFormat,
    .dmabuf_device = extOnDmabufDevice,
    .dmabuf_format = extOnDmabufFormat,
    .done = extOnDone,
    .stopped = extOnStopped,
};

fn extOnTransform(_: ?*anyopaque, _: ?*wl.ext_image_copy_capture_frame_v1, _: u32) callconv(.c) void {}

fn extOnDamage(_: ?*anyopaque, _: ?*wl.ext_image_copy_capture_frame_v1, _: i32, _: i32, _: i32, _: i32) callconv(.c) void {}

fn extOnPresentation(_: ?*anyopaque, _: ?*wl.ext_image_copy_capture_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}

/// `ready` carries no arguments — the frame's contents are final as soon as
/// it arrives (timestamps come from the separate `presentation_time` event,
/// which nothing here needs).
fn extOnReady(data: ?*anyopaque, _: ?*wl.ext_image_copy_capture_frame_v1) callconv(.c) void {
    const self: *ExtCtx = @ptrCast(@alignCast(data orelse return));
    self.frame_done = true;
    self.frame_ok = true;
}

fn extOnFailed(data: ?*anyopaque, _: ?*wl.ext_image_copy_capture_frame_v1, _: u32) callconv(.c) void {
    const self: *ExtCtx = @ptrCast(@alignCast(data orelse return));
    self.frame_done = true;
}

const ext_frame_listener = wl.ext_image_copy_capture_frame_v1_listener{
    .transform = extOnTransform,
    .damage = extOnDamage,
    .presentation_time = extOnPresentation,
    .ready = extOnReady,
    .failed = extOnFailed,
};

/// The ext path for one already-created source: session, one frame, one
/// shm mapping, decode. The `transform` event is ignored the way the C++
/// side ignored it — a rotated output would come out unrotated, which is
/// the one case neither implementation covers.
fn extCapture(
    alloc: std.mem.Allocator,
    display: ?*wl.wl_display,
    shm: ?*wl.wl_shm,
    copy: ?*wl.ext_image_copy_capture_manager_v1,
    source: ?*wl.ext_image_capture_source_v1,
    cursor: bool,
) !Image {
    const d = display orelse return error.NoDisplay;
    const m = copy orelse return error.NoBackend;
    const src = source orelse return error.NoBackend;

    var ctx = ExtCtx{};
    const opts: u32 = if (cursor) @intCast(wl.EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_OPTIONS_PAINT_CURSORS) else 0;
    ctx.session = wl.ext_image_copy_capture_manager_v1_create_session(m, src, opts);
    if (ctx.session == null) return error.CaptureFailed;
    defer wl.ext_image_copy_capture_session_v1_destroy(ctx.session);
    _ = wl.ext_image_copy_capture_session_v1_add_listener(ctx.session, &ext_session_listener, &ctx);

    if (!wait.pumpUntil(d, &ctx, ExtCtx.constraintsDone, kWaitMs)) return error.CaptureTimeout;
    if (ctx.failed or ctx.width == 0 or ctx.height == 0) return error.CaptureFailed;

    const bpp: u32 = if (stream.fmtBpp(ctx.fmt)) |v| v else return error.UnsupportedFormat;
    var target = try ShmTarget.create(shm, ctx.width, ctx.height, ctx.width * bpp, ctx.fmt);
    defer target.deinit();

    ctx.frame = wl.ext_image_copy_capture_session_v1_create_frame(ctx.session);
    if (ctx.frame == null) return error.CaptureFailed;
    defer wl.ext_image_copy_capture_frame_v1_destroy(ctx.frame);
    _ = wl.ext_image_copy_capture_frame_v1_add_listener(ctx.frame, &ext_frame_listener, &ctx);

    _ = wl.ext_image_copy_capture_frame_v1_attach_buffer(ctx.frame, target.buffer.?);
    _ = wl.ext_image_copy_capture_frame_v1_capture(ctx.frame);
    if (!wait.pumpUntil(d, &ctx, ExtCtx.frameArrived, kWaitMs)) return error.CaptureTimeout;
    if (!ctx.frame_ok) return error.CaptureFailed;

    return decodeRgba(alloc, target.map.?[0..target.map_size], ctx.width, ctx.height, ctx.width * bpp, ctx.fmt, false);
}

/// One ext capture of an output source, or null when the backend is absent
/// or failed softly — the caller then falls through to wlr. Timeouts and
/// unknown formats still surface to the caller so the message says why.
fn extOutputOnce(
    alloc: std.mem.Allocator,
    b: *const Backends,
    output: ?*wl.wl_output,
    cursor: bool,
) !?Image {
    const copy = b.ext_copy orelse return null;
    const mgr = b.ext_output_source orelse return null;
    const out = output orelse return null;
    const src = wl.ext_output_image_capture_source_manager_v1_create_source(mgr, out);
    if (src == null) return null;
    defer wl.ext_image_capture_source_v1_destroy(src);
    if (extCapture(alloc, b.display, b.shm, copy, src, cursor)) |img| {
        return img;
    } else |e| {
        switch (e) {
            error.CaptureFailed, error.NoBackend, error.NoShm, error.UnsupportedFormat => return null,
            else => return e,
        }
    }
}

// shm plumbing

/// A private memfd mapping plus the wl_buffer the compositor writes into.
/// The fd stays open until `deinit`: the pool request carries it and only
/// libwayland's flush actually hands it over.
const ShmTarget = struct {
    fd: i32 = -1,
    map: ?[*]u8 = null,
    map_size: usize = 0,
    buffer: ?*wl.wl_buffer = null,
    release: ReleaseFlag = .{},

    fn create(shm: ?*wl.wl_shm, width: u32, height: u32, stride: u32, fmt: u32) !ShmTarget {
        const s = shm orelse return error.NoShm;
        if (width == 0 or height == 0 or stride < width) return error.BadDimensions;
        var t = ShmTarget{};
        errdefer t.deinit();

        const size: usize = @as(usize, stride) * @as(usize, height);
        var tag: [16:0]u8 = @as([16:0]u8, @splat(0));
        @memcpy(tag[0..7], "eh-shot");
        const fd_rc = linux.memfd_create(&tag, linux.MFD.CLOEXEC);
        if (linux.errno(fd_rc) != .SUCCESS) return error.NoShm;
        t.fd = @intCast(fd_rc);
        if (linux.errno(linux.ftruncate(t.fd, @intCast(size))) != .SUCCESS) return error.NoShm;

        const map_rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, t.fd, 0);
        if (linux.errno(map_rc) != .SUCCESS) return error.NoShm;
        t.map = @ptrFromInt(map_rc);
        t.map_size = size;

        const pool = wl.wl_shm_create_pool(s, t.fd, @intCast(size));
        if (pool == null) return error.NoShm;
        t.buffer = wl.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(stride), fmt);
        wl.wl_shm_pool_destroy(pool);
        if (t.buffer == null) return error.NoShm;
        _ = wl.wl_buffer_add_listener(t.buffer, &ReleaseFlag.listener, &t.release);
        return t;
    }

    fn deinit(self: *ShmTarget) void {
        if (self.buffer) |buf| wl.wl_buffer_destroy(buf);
        if (self.map) |m| _ = linux.munmap(m, self.map_size);
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.* = .{};
    }
};

// tests

test "wl-capture-shot: crop copies the requested box and rejects escapes" {
    const t = std.testing;
    var img = try Image.init(t.allocator, 3, 2);
    defer img.deinit(t.allocator);
    // Each pixel's red channel carries its index so the copy is checkable.
    for (0..6) |i| img.rgba[i * 4] = @intCast(i);

    var cut = try img.crop(t.allocator, 1, 0, 2, 2);
    defer cut.deinit(t.allocator);
    try t.expectEqual(@as(i32, 2), cut.width);
    try t.expectEqual(@as(i32, 2), cut.height);
    try t.expectEqual(@as(u8, 1), cut.rgba[0]);
    try t.expectEqual(@as(u8, 2), cut.rgba[4]);
    // Row 1 of the crop comes from source row 1 (indices 3 and 4 of a 3-wide
    // source, so 4 then 5 after the x=1 offset).
    try t.expectEqual(@as(u8, 4), cut.rgba[8]);
    try t.expectEqual(@as(u8, 5), cut.rgba[12]);

    try t.expectError(error.OutOfBounds, img.crop(t.allocator, -1, 0, 1, 1));
    try t.expectError(error.OutOfBounds, img.crop(t.allocator, 0, 0, 4, 1));
    try t.expectError(error.BadDimensions, img.crop(t.allocator, 0, 0, 0, 1));
}

test "wl-capture-shot: decode honors y inversion and leaves alpha straight" {
    const t = std.testing;
    // 2x2 XRGB8888, little-endian (b,g,r,a): red/blue, then green/white.
    const src = [_]u8{
        0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0xff,
        0x00, 0xff, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff,
    };
    var straight = try decodeRgba(t.allocator, &src, 2, 2, 8, wl.WL_SHM_FORMAT_XRGB8888, false);
    defer straight.deinit(t.allocator);
    try t.expectEqual(@as(u8, 0xff), straight.rgba[0]);
    try t.expectEqual(@as(u8, 0x00), straight.rgba[2]);
    try t.expectEqual(@as(u8, 0xff), straight.rgba[3]);
    try t.expectEqual(@as(u8, 0xff), straight.rgba[6]);

    var flipped = try decodeRgba(t.allocator, &src, 2, 2, 8, wl.WL_SHM_FORMAT_XRGB8888, true);
    defer flipped.deinit(t.allocator);
    // Output row 0 now comes from source row 1: green first.
    try t.expectEqual(@as(u8, 0x00), flipped.rgba[0]);
    try t.expectEqual(@as(u8, 0xff), flipped.rgba[1]);
    try t.expectEqual(@as(u8, 0xff), flipped.rgba[6]);
}

test "wl-capture-shot: short mapping and unknown format are rejected" {
    const t = std.testing;
    const src = @as([8]u8, @splat(0));
    try t.expectError(error.BadDimensions, decodeRgba(t.allocator, &src, 4, 2, 8, wl.WL_SHM_FORMAT_XRGB8888, false));
    try t.expectError(error.UnsupportedFormat, decodeRgba(t.allocator, &src, 1, 2, 4, 0xdead, false));
}
