const std = @import("std");
const linux = std.os.linux;
const decode = @import("../../wallpaper/decode.zig");
const disk = @import("wallpaper_thumb_disk.zig");
const c = @import("c_pthread");

// Wallpaper gallery thumbnails — the Zig port of
// `eh::wallpaper::WallpaperThumbnailService`. The settings window must never
// decode an image on the UI thread: a 4K photo is tens of milliseconds of
// stb_image plus a scale, which would drop frames all over the tab. So one
// worker thread owns every decode, and the UI hands it work through a queue
// and gets results back through another, waking on an eventfd the window
// already watches (`Win.wallWakeFd`).
//
// Both queues are bounded ring buffers guarded by a pthread mutex + condvar
// (the same pair `src/loop.zig` uses), so the worker allocates nothing per
// job except the result itself, and a folder of 4000 images degrades to "the
// visible ones keep being re-requested" instead of unbounded growth.
//
// Every job carries the generation it was queued in; `releaseAll` bumps the
// generation, drops both queues and forgets the request set, and any job the
// worker was already decoding discards its result. That is what makes a
// folder switch immediate: stale thumbnails from the old folder can never
// land in the new one's cache.

pub const path_cap = 1024;
pub const pend_cap = 128;
pub const done_cap = 32;

/// One rendered thumbnail, handed to the caller. `path` and `pixels` are
/// owned by whoever the result is handed to (`Page.cachePut` / `freeResult`).
pub const Result = struct {
    path: []u8,
    ok: bool,
    w: i32 = 0,
    h: i32 = 0,
    /// ARGB32, premultiplied, row-major — cairo's native layout, so the
    /// cache can wrap it in an image surface without a copy.
    pixels: []u32 = &.{},
};

const Job = struct {
    path: [path_cap]u8 = undefined,
    path_len: u16 = 0,
    /// Longest side of the render, in pixels.
    px: u16 = 256,
};

pub const Service = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// eventfd the window watches; the worker writes 1 when a result lands.
    wake_fd: i32 = -1,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    thread: ?std.Thread = null,
    ready: bool = false,

    pend: [pend_cap]Job = undefined,
    pend_head: usize = 0,
    pend_len: usize = 0,

    done: [done_cap]Result = undefined,
    done_head: usize = 0,
    done_len: usize = 0,

    /// Paths already queued or rendered — dedupe so a paint loop does not
    /// re-request the same tile every frame.
    requested: std.StringHashMap(void),
    generation: u64 = 0,
    stop: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Service {
        var self = Service{
            .alloc = alloc,
            .io = io,
            .requested = std.StringHashMap(void).init(alloc),
        };
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
        self.lock();
        while (self.done_len > 0) {
            const r = self.popDoneLocked();
            self.unlock();
            freeResult(self.alloc, r);
            self.lock();
        }
        self.pend_len = 0;
        self.pend_head = 0;
        self.unlock();
        freeRequested(self);
        self.requested.deinit();
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

    /// The fd the event loop polls for completed thumbnails.
    pub fn wakeFd(self: *const Service) i32 {
        return self.wake_fd;
    }

    /// Queue `path` for a render at `px` (longest side). Returns false when
    /// it is already queued/rendered, the path is unusable, or the queue is
    /// full — the caller retries on a later frame, which is exactly the C++
    /// paint path's behaviour.
    pub fn request(self: *Service, path: []const u8, px: u32) bool {
        if (path.len == 0 or path.len >= path_cap) return false;
        if (px == 0) return false;
        self.lock();
        defer self.unlock();
        if (self.requested.contains(path)) return false;
        if (self.pend_len >= pend_cap) return false;
        if (self.thread == null) {
            self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
            if (self.thread == null) return false;
        }
        var job: Job = .{};
        @memcpy(job.path[0..path.len], path);
        job.path_len = @intCast(path.len);
        job.px = @intCast(@min(px, 4096));
        const idx = (self.pend_head + self.pend_len) % pend_cap;
        self.pend[idx] = job;
        self.pend_len += 1;
        const owned = self.alloc.dupe(u8, path) catch {
            // Roll the push back rather than leak the slot.
            self.pend_len -= 1;
            return false;
        };
        self.requested.put(owned, {}) catch {
            self.alloc.free(owned);
            self.pend_len -= 1;
            return false;
        };
        return true;
    }

    /// Move every finished result into `out` (which takes ownership).
    pub fn drain(self: *Service, out: *std.ArrayList(Result)) void {
        self.lock();
        while (self.done_len > 0) {
            const r = self.popDoneLocked();
            out.append(self.alloc, r) catch {
                self.unlock();
                freeResult(self.alloc, r);
                self.lock();
            };
        }
        self.unlock();
        if (self.wake_fd >= 0) {
            var buf: [8]u8 = @as([8]u8, @splat(0));
            _ = linux.read(self.wake_fd, &buf, buf.len);
        }
    }

    /// Forget everything: pending work, finished work, and the request set.
    /// Called on a folder change so the new gallery starts from an empty
    /// cache and the old one's decodes cannot land in it.
    pub fn releaseAll(self: *Service) void {
        self.lock();
        self.generation +%= 1;
        self.pend_head = 0;
        self.pend_len = 0;
        while (self.done_len > 0) {
            const r = self.popDoneLocked();
            self.unlock();
            freeResult(self.alloc, r);
            self.lock();
        }
        self.unlock();
        freeRequested(self);
    }

    /// Let one path be requested again. The cache evicts by LRU while the
    /// request set only ever grows, so without this an evicted tile could
    /// never be decoded a second time and its grid cell stayed blank forever.
    pub fn forget(self: *Service, path: []const u8) void {
        self.lock();
        defer self.unlock();
        // The key stored in the set is the dupe `request` made, so pull it
        // out by lookup rather than free the caller's slice.
        if (self.requested.fetchRemove(path)) |kv| self.alloc.free(kv.key);
    }

    /// True when a result is waiting to be picked up — the frame that finishes
    /// a tile schedules the follow-up repaint (`wallpaper_thumb_needs_followup_frame`).
    pub fn hasCompleted(self: *Service) bool {
        self.lock();
        const n = self.done_len > 0;
        self.unlock();
        return n;
    }

    fn popDoneLocked(self: *Service) Result {
        const r = self.done[self.done_head];
        self.done_head = (self.done_head + 1) % done_cap;
        self.done_len -= 1;
        return r;
    }

    fn lock(self: *Service) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }

    fn unlock(self: *Service) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn signalWake(self: *Service) void {
        if (self.wake_fd < 0) return;
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    fn run(self: *Service) void {
        while (true) {
            self.lock();
            while (self.pend_len == 0 and !self.stop) {
                _ = c.pthread_cond_wait(&self.cond, &self.mutex);
            }
            if (self.stop) {
                self.unlock();
                return;
            }
            const job = self.pend[self.pend_head];
            self.pend_head = (self.pend_head + 1) % pend_cap;
            self.pend_len -= 1;
            const gen = self.generation;
            self.unlock();

            const res = render(self.alloc, self.io, job) orelse continue;

            self.lock();
            if (gen != self.generation or self.stop) {
                self.unlock();
                freeResult(self.alloc, res);
                continue;
            }
            if (self.done_len >= done_cap) {
                self.unlock();
                freeResult(self.alloc, res);
                continue;
            }
            const idx = (self.done_head + self.done_len) % done_cap;
            self.done[idx] = res;
            self.done_len += 1;
            self.signalWake();
            self.unlock();
        }
    }
};

fn freeRequested(self: *Service) void {
    var it = self.requested.keyIterator();
    while (it.next()) |k| self.alloc.free(k.*);
    self.requested.clearRetainingCapacity();
}

pub fn freeResult(alloc: std.mem.Allocator, r: Result) void {
    if (r.path.len > 0) alloc.free(r.path);
    if (r.pixels.len > 0) alloc.free(r.pixels);
}

/// Decode `job.path` and downscale it to its longest side. Returns null only
/// when the allocator failed — an undecodable file is a result with
/// `ok = false`, which the cache keeps as a tombstone so the paint loop stops
/// asking for it every frame.
///
/// The scaled straight-RGBA bytes are persisted to the disk cache before
/// premultiplying, and the next cold open loads them back instead of decoding
/// the source again.
fn render(alloc: std.mem.Allocator, io: std.Io, job: Job) ?Result {
    const path = job.path[0..job.path_len];
    const owned = alloc.dupe(u8, path) catch return null;
    errdefer alloc.free(owned);
    const px: u32 = job.px;

    if (diskHit(alloc, io, path, px)) |h| {
        defer alloc.free(h.pixels);
        const out = alloc.alloc(u32, @as(usize, @intCast(h.w * h.h))) catch return null;
        errdefer alloc.free(out);
        disk.premultInto(out, h.pixels);
        return .{ .path = owned, .ok = true, .w = h.w, .h = h.h, .pixels = out };
    }

    var img = decode.loadRgba(alloc, path) orelse {
        return .{ .path = owned, .ok = false };
    };
    defer img.free(alloc);

    if (img.w <= 0 or img.h <= 0) return .{ .path = owned, .ok = false };

    // Aspect-preserving box downscale to the longest side, never upscaling:
    // the page paints the surface with a cairo scale, so a small source just
    // costs less memory and looks the same.
    const long_src: i32 = @max(img.w, img.h);
    const short_src: i32 = @min(img.w, img.h);
    const long_dst: i32 = @min(@as(i32, @intCast(px)), long_src);
    const short_dst: i32 = @max(1, @divTrunc(short_src * long_dst, long_src));
    const tw: i32 = if (img.w >= img.h) long_dst else short_dst;
    const th: i32 = if (img.w >= img.h) short_dst else long_dst;
    if (tw <= 0 or th <= 0) return .{ .path = owned, .ok = false };

    const scaled = alloc.alloc(u8, @as(usize, @intCast(tw * th)) * 4) catch return null;
    defer alloc.free(scaled);
    disk.scaleStraight(scaled, tw, th, img.pixels, img.w, img.h);

    const out = alloc.alloc(u32, @as(usize, @intCast(tw * th))) catch return null;
    errdefer alloc.free(out);
    // tw/th already carry the source aspect, so a stretch is a pure box
    // scale — no crop, no letterbox, no untouched padding bytes.
    disk.premultInto(out, scaled);
    storeFor(io, path, px, tw, th, scaled);

    return .{ .path = owned, .ok = true, .w = tw, .h = th, .pixels = out };
}

/// A previous run's (or the C++ app's) thumbnail for this exact source
/// revision, or null. The entry was keyed for this `px`, so its long side
/// already fits — anything else is a corrupt file wearing a good name.
fn diskHit(alloc: std.mem.Allocator, io: std.Io, path: []const u8, px: u32) ?disk.Loaded {
    const ss = disk.statSource(io, path) orelse return null;
    var dirb: [512]u8 = undefined;
    const dir = disk.cacheDirBuf(&dirb) orelse return null;
    var pb: [1024]u8 = undefined;
    const cp = disk.cachePathFor(&pb, dir, path, ss.size, ss.mtime_ns, px) orelse return null;
    const hit = disk.load(alloc, io, cp) orelse return null;
    errdefer alloc.free(hit.pixels);
    if (hit.w <= 0 or hit.h <= 0) {
        alloc.free(hit.pixels);
        return null;
    }
    if (@max(hit.w, hit.h) > @as(i32, @intCast(px))) {
        alloc.free(hit.pixels);
        return null;
    }
    if (hit.pixels.len != @as(usize, @intCast(hit.w)) * @as(usize, @intCast(hit.h)) * 4) {
        alloc.free(hit.pixels);
        return null;
    }
    return hit;
}

fn storeFor(io: std.Io, path: []const u8, px: u32, w: i32, h: i32, rgba: []const u8) void {
    const ss = disk.statSource(io, path) orelse return;
    var dirb: [512]u8 = undefined;
    const dir = disk.cacheDirBuf(&dirb) orelse return;
    var pb: [1024]u8 = undefined;
    const cp = disk.cachePathFor(&pb, dir, path, ss.size, ss.mtime_ns, px) orelse return;
    disk.store(io, cp, w, h, rgba);
}

// ------------------------------------------------------------------ tests --

/// A 2x2 24-bit BMP with a solid red bottom row — small enough to write out
/// by hand and enough to prove the decode → downscale → premultiply path.
fn writeTestBmp(alloc: std.mem.Allocator, path: []const u8) !void {
    var b: [70]u8 = @as([70]u8, @splat(0));
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(u32, b[2..6], 70, .little);
    std.mem.writeInt(u32, b[10..14], 54, .little);
    std.mem.writeInt(u32, b[14..18], 40, .little);
    std.mem.writeInt(u32, b[18..22], 2, .little); // width
    std.mem.writeInt(u32, b[22..26], 2, .little); // height (bottom-up)
    std.mem.writeInt(u16, b[26..28], 1, .little); // planes
    std.mem.writeInt(u16, b[28..30], 24, .little); // bpp
    std.mem.writeInt(u32, b[34..38], 16, .little); // image size
    // Two 8-byte rows (6 px bytes + 2 pad), BGR. BMP stores bottom-up, so the
    // first row here is the bottom of the image and stb_image emits the
    // second row first: decoded top-left is green.
    // bottom row: cyan, red
    b[54] = 255;
    b[55] = 255;
    b[56] = 0;
    b[57] = 0;
    b[58] = 0;
    b[59] = 255;
    // top row: green, blue
    b[62] = 0;
    b[63] = 255;
    b[64] = 0;
    b[65] = 255;
    b[66] = 0;
    b[67] = 0;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &b });
    _ = alloc;
}

test "wallpaper-thumbs: a missing file is a cached miss, not a retry loop" {
    const t = std.testing;
    const alloc = t.allocator;
    const path = "/nonexistent-wallpaper-xyz.png";
    var job: Job = .{};
    @memcpy(job.path[0..path.len], path);
    job.path_len = @intCast(path.len);
    const r = render(alloc, std.testing.io, job).?;
    defer freeResult(alloc, r);
    try t.expect(!r.ok);
    try t.expectEqualStrings(path, r.path);
}

test "wallpaper-thumbs: service queues, renders and drains a real image" {
    const t = std.testing;
    const alloc = t.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    const pic = try std.fs.path.join(alloc, &.{ root, "px.bmp" });
    defer alloc.free(pic);
    try writeTestBmp(alloc, pic);

    var svc = Service.init(alloc, std.testing.io);
    defer svc.deinit();
    try t.expect(svc.request(pic, 128));
    // A second request for the same path is deduped.
    try t.expect(!svc.request(pic, 128));

    var out: std.ArrayList(Result) = .empty;
    defer {
        for (out.items) |r| freeResult(alloc, r);
        out.deinit(alloc);
    }
    // Wait for the worker (bounded).
    var spins: usize = 0;
    while (out.items.len == 0 and spins < 2000) : (spins += 1) {
        svc.drain(&out);
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    try t.expectEqual(@as(usize, 1), out.items.len);
    try t.expect(out.items[0].ok);
    try t.expectEqual(@as(i32, 2), out.items[0].w);
    try t.expectEqual(@as(i32, 2), out.items[0].h);
    // The BMP stores its bottom row first, so decoded row 0 is the green one.
    try t.expectEqual(@as(u32, 0xFF00FF00), out.items[0].pixels[0]);

    // After a drain the path is known: a re-request is refused.
    try t.expect(!svc.request(pic, 128));
    svc.releaseAll();
    try t.expect(svc.request(pic, 128));
}

test "wallpaper-thumbs: releaseAll drops the request set" {
    const t = std.testing;
    var svc = Service.init(t.allocator, std.testing.io);
    defer svc.deinit();
    try t.expect(svc.request("/tmp/whatever.png", 64));
    svc.releaseAll();
    try t.expectEqual(@as(usize, 0), svc.requested.count());
}
