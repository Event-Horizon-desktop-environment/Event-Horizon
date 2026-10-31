const std = @import("std");
const scan = @import("wallpaper_scan.zig");

// In-app folder browser for the Wallpaper tab — the data half.
// `wallpaper_browser_list_worker`: one detached thread per navigation opens
// the directory, collects the folders and raster images, stats each entry,
// sorts, and publishes a `Listing` in a single-slot mailbox (last one wins,
// guarded by `std.atomic.Mutex` with the codebase's spin-then-yield rule —
// there is no blocking mutex in Zig 0.16).
//
// The UI thread never touches the filesystem for a listing (a network
// mount can stall opendir for seconds); it drains the mailbox on a frame
// and takes over the arrays. The browser page owns the copies then.

/// One entry of a listing. `full` is the joined path (thumb cache key),
/// `name` is the display label; both owned by whatever holds them.
pub const DirEntry = struct {
    full: []u8,
    name: []u8,
    /// Last modification, nanoseconds. 0 when the stat failed.
    mtime_ns: i96 = 0,
    size: u64 = 0,
};

/// A finished listing. Arrays are page_allocator-backed; `freeListing`
/// releases everything so the UI can either adopt or drop it.
pub const Listing = struct {
    seq: u32 = 0,
    ok: bool = false,
    root: []u8 = &.{},
    dirs: []DirEntry = &.{},
    imgs: []DirEntry = &.{},

    pub fn freeListing(self: Listing) void {
        const pa = std.heap.page_allocator;
        if (self.root.len > 0) pa.free(self.root);
        for (self.dirs) |d| {
            pa.free(d.full);
            if (d.name.ptr != d.full.ptr) pa.free(d.name);
        }
        if (self.dirs.len > 0) pa.free(self.dirs);
        for (self.imgs) |d| {
            pa.free(d.full);
            if (d.name.ptr != d.full.ptr) pa.free(d.name);
        }
        if (self.imgs.len > 0) pa.free(self.imgs);
    }
};

// Single-slot mailbox.
var list_mu: std.atomic.Mutex = .unlocked;
var list_last: ?Listing = null;

fn listLock() void {
    var spins: u32 = 0;
    while (!list_mu.tryLock()) {
        spins +%= 1;
        if (spins < 64) {
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
        }
    }
}

const list_cap: usize = 2000;

const Args = struct {
    io: std.Io,
    root: []u8,
    show_hidden: bool,
    seq: u32,

    fn run(self: Args) void {
        var out = buildListing(self);
        // The root dupe is copied into the listing's header; the caller's
        // buffer dies here.
        const pa = std.heap.page_allocator;
        defer pa.free(self.root);
        out.seq = self.seq;
        listLock();
        defer list_mu.unlock();
        if (list_last) |old| old.freeListing();
        list_last = out;
    }
};

fn buildListing(a: Args) Listing {
    const pa = std.heap.page_allocator;
    var dirs: std.ArrayList(DirEntry) = .empty;
    var imgs: std.ArrayList(DirEntry) = .empty;
    blk: {
        var dir = std.Io.Dir.cwd().openDir(a.io, a.root, .{ .iterate = true }) catch {
            return Listing{ .root = pa.dupe(u8, a.root) catch &.{} };
        };
        defer dir.close(a.io);
        var it = dir.iterate();
        while (it.next(a.io) catch null) |e| {
            if (e.name.len == 0 or e.name[0] == '.' and !a.show_hidden) continue;
            const full = std.fs.path.join(pa, &.{ a.root, e.name }) catch continue;
            switch (e.kind) {
                .directory => {
                    if (dirs.items.len >= list_cap) {
                        pa.free(full);
                        continue;
                    }
                    appendEntry(pa, &dirs, full, a.io) catch {
                        pa.free(full);
                        continue;
                    };
                },
                .file, .sym_link => {
                    // Only raster images belong in a wallpaper browser.
                    if (!scan.isRasterName(e.name)) {
                        pa.free(full);
                        continue;
                    }
                    if (imgs.items.len >= list_cap) {
                        pa.free(full);
                        continue;
                    }
                    appendEntry(pa, &imgs, full, a.io) catch {
                        pa.free(full);
                        continue;
                    };
                },
                else => pa.free(full),
            }
        }
        // Dirs alphabetically, images newest-decoration-first (the gallery's
        // default order), path as the tie-break.
        std.sort.pdq(DirEntry, dirs.items, {}, lessName);
        std.sort.pdq(DirEntry, imgs.items, {}, lessMtimeDesc);
        return Listing{
            .root = pa.dupe(u8, a.root) catch {
                dirs.deinit(pa);
                imgs.deinit(pa);
                break :blk;
            },
            .ok = true,
            .dirs = dirs.toOwnedSlice(pa) catch &.{},
            .imgs = imgs.toOwnedSlice(pa) catch &.{},
        };
    }
    return Listing{ .root = pa.dupe(u8, a.root) catch &.{} };
}

/// Attach `full` to `list`, deriving the display name and statting the
/// entry. On stat failure the entry still appears (mtime 0) — a file manager
/// that hides unstatable entries looks broken.
fn appendEntry(
    pa: std.mem.Allocator,
    list: *std.ArrayList(DirEntry),
    full: []u8,
    io: std.Io,
) !void {
    const base = std.fs.path.basename(full);
    var e = DirEntry{ .full = full, .name = try pa.dupe(u8, base) };
    // The image cache keys off `full`; the name slice is redundant when the
    // basename is the whole path, so share it to keep one free site.
    if (e.full.len == base.len) e.name = e.full;
    if (std.Io.Dir.cwd().statFile(io, e.full, .{})) |st| {
        e.mtime_ns = st.mtime.nanoseconds;
        e.size = @intCast(@max(0, st.size));
    } else |_| {}
    try list.append(pa, e);
}

fn lessName(_: void, a: DirEntry, b: DirEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessMtimeDesc(_: void, a: DirEntry, b: DirEntry) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
    return std.mem.lessThan(u8, a.full, b.full);
}

/// Kick one listing in a detached thread. Never blocks the caller; the
/// result lands in the mailbox addressed by `seq` (the page drops stale
/// sequences itself).
pub fn requestListing(io: std.Io, root: []const u8, show_hidden: bool, seq: u32) void {
    const pa = std.heap.page_allocator;
    const owned = pa.dupe(u8, root) catch return;
    const t = std.Thread.spawn(.{}, Args.run, .{Args{
        .io = io,
        .root = owned,
        .show_hidden = show_hidden,
        .seq = seq,
    }}) catch {
        pa.free(owned);
        return;
    };
    t.detach();
}

/// Consume the newest listing, or null when none published yet. The caller
/// owns the returned arrays (or frees them with `freeListing`).
pub fn take() ?Listing {
    listLock();
    defer list_mu.unlock();
    const l = list_last orelse return null;
    list_last = null;
    return l;
}

test "browser: lessName sorts before stat order" {
    var one = DirEntry{ .full = @constCast("/a/b"), .name = @constCast("b") };
    var two = DirEntry{ .full = @constCast("/a/a"), .name = @constCast("a") };
    const arr = [_]DirEntry{ one, two };
    std.sort.pdq(DirEntry, @constCast(&arr), {}, lessName);
    try std.testing.expectEqualStrings("a", arr[0].name);
    _ = &one;
    _ = &two;
}
