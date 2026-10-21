//! One synchronous output snapshot over wlr-screencopy, SHM path only.
//!
//! The frame offers shm parameters, we copy into a private mapping, and
//! the finished rows become premultiplied BGRA — the pixel shape the
//! overview's tiles and rail thumbs already paint. Every wait is bounded:
//! a compositor that never answers costs one timeout, not a hung shell.

const std = @import("std");
const wl = @import("../c.zig").wl;
const linux = std.os.linux;
const wait = @import("wait.zig");
const stream = @import("toplevel_stream.zig");

/// One captured output: premultiplied BGRA, top-down, owned by the holder.
pub const Shot = struct {
    width: i32 = 0,
    height: i32 = 0,
    bgra: []u8 = &.{},
    /// Source generation, assigned by the owning store: paint caches key
    /// on this so a replaced shot can never paint stale.
    gen: u64 = 0,

    pub fn deinit(self: *Shot, alloc: std.mem.Allocator) void {
        alloc.free(self.bgra);
        self.* = .{};
    }
};

/// Per-frame capture state, filled by the frame listener.
const Info = struct {
    fmt: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    listed: bool = false,
    ready: bool = false,
    failed: bool = false,
    y_invert: bool = false,
    /// v1/v2 announce the buffer through `buffer` itself; v3 lists the
    /// offer and closes it with `buffer_done`.
    v3: bool = false,
};

const kWaitMs: u64 = 1000;

fn listed(i: *Info) bool {
    return i.listed or i.failed;
}

fn finished(i: *Info) bool {
    return i.ready or i.failed;
}

fn onBuffer(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, format: u32, width: u32, height: u32, stride: u32) callconv(.c) void {
    const self: *Info = @ptrCast(@alignCast(data orelse return));
    if (self.failed) return;
    self.fmt = format;
    self.width = width;
    self.height = height;
    self.stride = stride;
    if (!self.v3) self.listed = true;
}

fn onFlags(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, flags: u32) callconv(.c) void {
    const self: *Info = @ptrCast(@alignCast(data orelse return));
    self.y_invert = (flags & 1) != 0;
}

fn onReady(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {
    const self: *Info = @ptrCast(@alignCast(data orelse return));
    self.ready = true;
}

fn onFailed(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1) callconv(.c) void {
    const self: *Info = @ptrCast(@alignCast(data orelse return));
    self.failed = true;
}

fn onDamage(_: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}

fn onDmabuf(_: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}

fn onBufferDone(data: ?*anyopaque, _: ?*wl.zwlr_screencopy_frame_v1) callconv(.c) void {
    const self: *Info = @ptrCast(@alignCast(data orelse return));
    self.listed = true;
}

const listener = wl.zwlr_screencopy_frame_v1_listener{
    .buffer = onBuffer,
    .flags = onFlags,
    .ready = onReady,
    .failed = onFailed,
    .damage = onDamage,
    .linux_dmabuf = onDmabuf,
    .buffer_done = onBufferDone,
};

const buf_release_listener = wl.wl_buffer_listener{ .release = onBufRelease };

fn onBufRelease(_: ?*anyopaque, _: ?*wl.wl_buffer) callconv(.c) void {}

/// One output's in-flight screencopy: the listener fills `info` while the
/// mapping and buffer below are built around whatever it offers.
const BatchSlot = struct {
    info: Info = .{},
    frame: ?*wl.zwlr_screencopy_frame_v1 = null,
    map: ?[*]u8 = null,
    map_size: usize = 0,
    fd: i32 = -1,
    buf: ?*wl.wl_buffer = null,
};

/// Capture one full output once, shrunk to `max_dim` on the long side
/// and converted to premultiplied BGRA. Cards and rail only ever paint a
/// few hundred pixels, so keeping the compositor-sized copy around would
/// burn memory and per-paint scaling time for nothing.
pub fn copyOutput(
    alloc: std.mem.Allocator,
    display: ?*wl.wl_display,
    mgr: ?*wl.zwlr_screencopy_manager_v1,
    shm: ?*wl.wl_shm,
    output: ?*wl.wl_output,
    max_dim: i32,
) !Shot {
    const outs = [_]?*wl.wl_output{output};
    const results = try copyOutputs(alloc, display, mgr, shm, &outs, max_dim);
    defer alloc.free(results);
    if (!results[0].ok) return error.CaptureFailed;
    // Ownership moves to the caller; the results shell frees nothing.
    return results[0].shot;
}

/// One batch slot: the shot when `ok`, empty otherwise (nothing to free).
pub const CopyResult = struct {
    shot: Shot = .{},
    ok: bool = false,
};

/// Capture every output in `outs` concurrently: all requests go out
/// together and each wait covers the whole batch, so three outputs cost
/// about one instead of three in a row. Results align with `outs` (a null
/// output yields `!ok`); the caller owns every `ok` shot.
pub fn copyOutputs(
    alloc: std.mem.Allocator,
    display: ?*wl.wl_display,
    mgr: ?*wl.zwlr_screencopy_manager_v1,
    shm: ?*wl.wl_shm,
    outs: []const ?*wl.wl_output,
    max_dim: i32,
) ![]CopyResult {
    const m = mgr orelse return error.NoManager;
    const s = shm orelse return error.NoShm;
    const d = display orelse return error.NoDisplay;
    const results = try alloc.alloc(CopyResult, outs.len);
    errdefer alloc.free(results);
    @memset(results, .{});

    const slots = try alloc.alloc(BatchSlot, outs.len);
    defer alloc.free(slots);
    @memset(slots, BatchSlot{});

    // Every request out before any wait: the compositor copies in parallel.
    for (outs, 0..) |o, i| {
        const out = o orelse continue;
        const fr = wl.zwlr_screencopy_manager_v1_capture_output(m, 0, out);
        if (fr == null) {
            slots[i].info.failed = true;
            continue;
        }
        slots[i].frame = fr;
        slots[i].info.v3 = wl.zwlr_screencopy_frame_v1_get_version(fr) >= 3;
        _ = wl.zwlr_screencopy_frame_v1_add_listener(fr, &listener, &slots[i].info);
    }
    defer {
        for (slots) |*sl| {
            if (sl.frame) |fr| wl.zwlr_screencopy_frame_v1_destroy(fr);
        }
    }
    _ = wl.wl_display_flush(d);
    if (!wait.pumpUntil(d, slots, allListed, outs.len * kWaitMs)) return error.CaptureTimeout;

    // One mapping and copy per listed output.
    for (slots) |*sl| {
        const info = &sl.info;
        if (info.failed or !info.listed) continue;
        if (info.width == 0 or info.height == 0) {
            info.failed = true;
            continue;
        }
        const bpp = stream.fmtBpp(info.fmt) orelse {
            info.failed = true;
            continue;
        };
        if (info.stride < info.width * bpp) {
            info.failed = true;
            continue;
        }
        const size: usize = @as(usize, info.stride) * @as(usize, info.height);
        var tag_buf: [16:0]u8 = [_:0]u8{0} ** 16;
        @memcpy(tag_buf[0..7], "eh-shot");
        const fd_rc = linux.memfd_create(&tag_buf, linux.MFD.CLOEXEC);
        if (linux.errno(fd_rc) != .SUCCESS) {
            info.failed = true;
            continue;
        }
        sl.fd = @intCast(fd_rc);
        if (linux.errno(linux.ftruncate(sl.fd, @intCast(size))) != .SUCCESS) {
            info.failed = true;
            continue;
        }
        const map_rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, sl.fd, 0);
        if (linux.errno(map_rc) != .SUCCESS) {
            info.failed = true;
            continue;
        }
        sl.map = @ptrFromInt(map_rc);
        sl.map_size = size;
        const pool = wl.wl_shm_create_pool(s, sl.fd, @intCast(size));
        if (pool == null) {
            info.failed = true;
            continue;
        }
        defer wl.wl_shm_pool_destroy(pool);
        sl.buf = wl.wl_shm_pool_create_buffer(pool, 0, @intCast(info.width), @intCast(info.height), @intCast(info.stride), info.fmt);
        if (sl.buf == null) {
            info.failed = true;
            continue;
        }
        _ = wl.wl_buffer_add_listener(sl.buf.?, &buf_release_listener, null);
        _ = wl.zwlr_screencopy_frame_v1_copy(sl.frame.?, sl.buf.?);
    }
    defer {
        for (slots) |*sl| {
            if (sl.buf) |b| wl.wl_buffer_destroy(b);
            if (sl.map) |mp| _ = linux.munmap(mp, sl.map_size);
            if (sl.fd >= 0) _ = linux.close(sl.fd);
        }
    }
    _ = wl.wl_display_flush(d);
    if (!wait.pumpUntil(d, slots, allFinished, outs.len * kWaitMs)) return error.CaptureTimeout;

    for (slots, 0..) |*sl, i| {
        const info = &sl.info;
        if (info.failed or !info.ready) continue;
        const bytes = sl.map.?[0..sl.map_size];
        const dims = stream.targetDims(@intCast(info.width), @intCast(info.height), max_dim);
        const bgra = stream.downsample(
            alloc,
            bytes,
            @intCast(info.width),
            @intCast(info.height),
            @intCast(info.stride),
            info.fmt,
            info.y_invert,
            max_dim,
        ) catch continue;
        results[i] = .{ .shot = .{ .width = dims[0], .height = dims[1], .bgra = bgra }, .ok = true };
    }
    return results;
}

/// Batch predicates for the bounded waits: every slot listed, then every
/// slot answered.
fn allListed(slots: []BatchSlot) bool {
    for (slots) |*sl| {
        if (!listed(&sl.info)) return false;
    }
    return true;
}

fn allFinished(slots: []BatchSlot) bool {
    for (slots) |*sl| {
        if (!finished(&sl.info)) return false;
    }
    return true;
}

/// Rows from one captured mapping into premultiplied BGRA, honoring the
/// compositor's y-inversion. `stride` is bytes per source row.
pub fn rowsToBgra(
    alloc: std.mem.Allocator,
    map: []const u8,
    width: i32,
    height: i32,
    stride: i32,
    fmt: u32,
    y_invert: bool,
    max_dim: i32,
) !Shot {
    // downsample trusts its mapping, so the bounds are checked here where
    // the compositor's numbers first meet our slice.
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const st: usize = @intCast(stride);
    const bpp: usize = @intCast(stream.fmtBpp(fmt) orelse return error.UnsupportedFormat);
    if (w == 0 or h == 0 or st < w * bpp) return error.BadDimensions;
    if (map.len < (h - 1) * st + w * bpp) return error.BadDimensions;
    const dims = stream.targetDims(width, height, max_dim);
    const bgra = try stream.downsample(alloc, map, width, height, stride, fmt, y_invert, max_dim);
    return .{ .width = dims[0], .height = dims[1], .bgra = bgra };
}

test "wl-capture-output: rows convert to premultiplied BGRA with y flip" {
    const t = std.testing;
    // 2x2 XRGB8888, stride 12 (row padding): row0 red, row1 blue, alpha
    // implied opaque so premultiplication is a no-op.
    const src = [_]u8{
        0x00, 0x00, 0xff, 0xff, 0x11, 0x22, 0x33, 0x44, 0xaa, 0xbb, 0xcc, 0xdd,
        0xff, 0x00, 0x00, 0xff, 0x55, 0x66, 0x77, 0x88, 0xee, 0xff, 0x00, 0x11,
    };
    const out = try rowsToBgra(t.allocator, &src, 2, 2, 12, wl.WL_SHM_FORMAT_XRGB8888, true, 64);
    defer t.allocator.free(out.bgra);
    try t.expectEqual(@as(i32, 2), out.width);
    try t.expectEqual(@as(i32, 2), out.height);
    try t.expectEqual(@as(usize, 16), out.bgra.len);
    // Flipped: output row0 comes from source row1. x0 is blue; x1 decodes
    // its bytes 0x55/0x66/0x77 as B/G/R (opaque = premultiply no-op).
    try t.expectEqual(@as(u8, 0xff), out.bgra[0]);
    try t.expectEqual(@as(u8, 0x00), out.bgra[2]);
    try t.expectEqual(@as(u8, 0xff), out.bgra[3]);
    try t.expectEqual(@as(u8, 0x55), out.bgra[4]);
    try t.expectEqual(@as(u8, 0x77), out.bgra[6]);
    // Output row1 comes from source row0: red at x0, alpha intact.
    try t.expectEqual(@as(u8, 0x00), out.bgra[8]);
    try t.expectEqual(@as(u8, 0xff), out.bgra[10]);
    try t.expectEqual(@as(u8, 0xff), out.bgra[11]);
}

test "wl-capture-output: short mapping and unknown format are rejected" {
    const t = std.testing;
    const src = [_]u8{0} ** 8;
    try t.expectError(error.BadDimensions, rowsToBgra(t.allocator, &src, 4, 1, 16, wl.WL_SHM_FORMAT_XRGB8888, false, 64));
    try t.expectError(error.UnsupportedFormat, rowsToBgra(t.allocator, &src, 1, 1, 4, 0xdead, false, 64));
}
