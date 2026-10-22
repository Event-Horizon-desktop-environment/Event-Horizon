const std = @import("std");
const linux = std.os.linux;
const wl = @import("../connection.zig").wl;

pub const cairo = @cImport(@cInclude("cairo/cairo.h"));

pub const ShmBuffer = struct {
    alloc: std.mem.Allocator,
    data: ?[*]u8 = null,
    size: usize = 0,
    width: i32 = 0,
    height: i32 = 0,
    stride: i32 = 0,
    busy: bool = false,
    /// A buffer attached for the first time must be damaged in full: the
    /// compositor has no previous surface content to combine a partial
    /// damage rect with.
    ever_attached: bool = false,
    buffer: ?*wl.wl_buffer = null,
    cairo_surface: ?*cairo.cairo_surface_t = null,
    cr: ?*cairo.cairo_t = null,
    hook: ?*const fn (ctx: *anyopaque) void = null,
    hook_ctx: *anyopaque = undefined,

    const Self = @This();

    fn onRelease(data: ?*anyopaque, buffer: ?*wl.wl_buffer) callconv(.c) void {
        _ = buffer;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.busy = false;
        if (self.hook) |h| h(self.hook_ctx);
    }

    const buffer_listener = wl.wl_buffer_listener{ .release = onRelease };

    pub fn init(alloc: std.mem.Allocator) ShmBuffer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *ShmBuffer) void {
        self.destroy();
    }

    pub fn setReleaseHook(self: *ShmBuffer, hook: *const fn (*anyopaque) void, ctx: *anyopaque) void {
        self.hook = hook;
        self.hook_ctx = ctx;
    }

    pub fn ensure(self: *ShmBuffer, shm: ?*wl.wl_shm, tag: []const u8, width: i32, height: i32) bool {
        if (width <= 0 or height <= 0) return false;
        if (self.buffer != null and self.width == width and self.height == height) return true;
        self.destroy();
        // 256-byte row alignment: compositors that import shm through udmabuf
        // need a page-multiple size and a driver-friendly stride to skip the
        // GPU upload copy; everywhere else cairo still gets an aligned stride.
        const stride: i32 = @intCast(std.mem.alignForward(usize, @as(usize, @intCast(width)) * 4, 256));
        const raw: usize = @intCast(@as(isize, stride) * @as(isize, height));
        const size: usize = std.mem.alignForward(usize, raw, std.heap.page_size_min);

        var tag_buf: [64:0]u8 = [_:0]u8{0} ** 64;
        const n = @min(tag.len, 63);
        @memcpy(tag_buf[0..n], tag[0..n]);
        const fd_rc = linux.memfd_create(&tag_buf, linux.MFD.CLOEXEC);
        if (linux.errno(fd_rc) != .SUCCESS) return false;
        const fd: i32 = @intCast(fd_rc);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return false;
        const map_rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(map_rc) != .SUCCESS) return false;
        const data: [*]u8 = @ptrFromInt(map_rc);
        errdefer _ = linux.munmap(data, size);

        // Pre-fault the mapping: without this the first frame painted after a
        // resize eats a minor fault per 4K page (14.7MB at 2560x1440 is ~3600
        // faults, ~2.8ms) — inside the frame. Touching one byte per page pays
        // it here instead, and HUGEPAGE lets the kernel hand out 2MB chunks so
        // the loop usually collapses to a handful of stores.
        _ = linux.madvise(data, size, linux.MADV.HUGEPAGE);
        var off: usize = 0;
        while (off < size) : (off += std.heap.page_size_min) data[off] = 0;

        const pool = wl.wl_shm_create_pool(shm, fd, @intCast(size));
        _ = linux.close(fd);
        if (pool == null) {
            _ = linux.munmap(data, size);
            return false;
        }
        defer wl.wl_shm_pool_destroy(pool);
        const buffer = wl.wl_shm_pool_create_buffer(pool, 0, width, height, stride, wl.WL_SHM_FORMAT_ARGB8888);
        if (buffer == null) {
            _ = linux.munmap(data, size);
            return false;
        }
        errdefer wl.wl_buffer_destroy(buffer);
        const surface = cairo.cairo_image_surface_create_for_data(data, cairo.CAIRO_FORMAT_ARGB32, width, height, stride);
        if (cairo.cairo_surface_status(surface) != cairo.CAIRO_STATUS_SUCCESS) {
            wl.wl_buffer_destroy(buffer);
            _ = linux.munmap(data, size);
            return false;
        }
        errdefer cairo.cairo_surface_destroy(surface);
        const cr = cairo.cairo_create(surface);
        if (cairo.cairo_status(cr) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_destroy(cr);
            return false;
        }
        _ = wl.wl_buffer_add_listener(buffer, &buffer_listener, self);
        self.data = data;
        self.size = size;
        self.width = width;
        self.height = height;
        self.stride = stride;
        self.buffer = buffer;
        self.cairo_surface = surface;
        self.cr = cr;
        self.busy = false;
        return true;
    }

    pub fn destroy(self: *ShmBuffer) void {
        if (self.cr) |cr| {
            cairo.cairo_destroy(cr);
            self.cr = null;
        }
        if (self.cairo_surface) |s| {
            cairo.cairo_surface_destroy(s);
            self.cairo_surface = null;
        }
        if (self.buffer) |b| {
            wl.wl_buffer_destroy(b);
            self.buffer = null;
        }
        if (self.data) |d| {
            _ = linux.munmap(d, self.size);
            self.data = null;
        }
        self.size = 0;
        self.width = 0;
        self.height = 0;
        self.stride = 0;
        self.busy = false;
        self.ever_attached = false;
    }

    pub fn markBusy(self: *ShmBuffer) void {
        self.busy = true;
    }

    pub fn wlBuffer(self: *ShmBuffer) ?*wl.wl_buffer {
        return self.buffer;
    }
};

/// Two buffers for one surface. Painting into a buffer the compositor is
/// still reading is what shows up as flicker whenever frames arrive faster
/// than the display takes them — a pointer sweeping across the dock, or a
/// menu repainting under a moving cursor.
pub const ShmPair = struct {
    bufs: [3]ShmBuffer,
    /// Buffers in play: 2 by default, 3 on high-rate displays where the
    /// compositor can hold two frames while the next one paints.
    count: usize = 2,
    next: usize = 0,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .bufs = .{ ShmBuffer.init(alloc), ShmBuffer.init(alloc), ShmBuffer.init(alloc) } };
    }

    pub fn deinit(self: *Self) void {
        for (&self.bufs) |*b| b.deinit();
    }

    pub fn ensure(self: *Self, shm: ?*wl.wl_shm, tag: []const u8, width: i32, height: i32) bool {
        var ok = true;
        for (self.bufs[0..self.count]) |*b| {
            if (!b.ensure(shm, tag, width, height)) ok = false;
        }
        return ok;
    }

    pub fn setReleaseHook(self: *Self, hook: *const fn (*anyopaque) void, ctx: *anyopaque) void {
        for (self.bufs[0..self.count]) |*b| b.setReleaseHook(hook, ctx);
    }

    /// Whether there is anywhere to draw yet — after the first configure, and
    /// after every resize that has landed.
    pub fn ready(self: *const Self) bool {
        return self.bufs[0].cr != null;
    }

    /// The buffer to draw the next frame into. Rotates through the pool, so
    /// a steady frame rate does not keep reusing the same memory while the
    /// compositor still holds it. null when the compositor holds them all —
    /// that frame is dropped, and the next event puts it out instead.
    pub fn acquire(self: *Self) ?*ShmBuffer {
        const got = self.acquireIndexed() orelse return null;
        return got.buf;
    }

    pub const Acquired = struct {
        index: usize,
        buf: *ShmBuffer,
    };

    /// Same rotation as `acquire`, but also returns the pool slot. Incremental
    /// paint paths keep per-buffer damage state so a buffer that was last
    /// painted two frames ago is repaired from its own pixels, not the newest.
    pub fn acquireIndexed(self: *Self) ?Acquired {
        for (0..self.count) |step| {
            const i = (self.next + step) % self.count;
            if (self.bufs[i].busy) continue;
            self.next = (i + 1) % self.count;
            return .{ .index = i, .buf = &self.bufs[i] };
        }
        return null;
    }
};

test "shm-pair: a frame is never drawn into a buffer the compositor holds" {
    const t = std.testing;
    var p = ShmPair.init(t.allocator);
    defer p.deinit();

    const a = p.acquire().?;
    a.markBusy();
    const b = p.acquire().?;
    try t.expect(a != b);
    b.markBusy();

    // Both held: the frame is dropped rather than painted under the screen.
    try t.expect(p.acquire() == null);

    // Released one at a time, the pair keeps alternating rather than parking
    // on the same memory while the other is still held.
    a.busy = false;
    const c = p.acquire().?;
    try t.expect(c == a);
    b.busy = false;
    c.markBusy();
    try t.expect(p.acquire().? == b);

    // And when both are handed out again, the next frame has nowhere to go.
    b.busy = false;
    const e = p.acquire().?;
    e.markBusy();
    try t.expect(p.acquire() == null);
}

test "shm: invalid sizes rejected without wayland" {
    const t = std.testing;
    var b = ShmBuffer.init(t.allocator);
    defer b.deinit();
    try t.expect(!b.ensure(null, "test", 0, 10));
    try t.expect(!b.ensure(null, "test", 10, -1));
    try t.expect(!b.busy);
}
