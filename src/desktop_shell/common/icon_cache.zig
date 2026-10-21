//! In-process icon cache.
//!
//! The old Zig path resolved every icon by *probing the filesystem* —
//! `icon_lookup.lookupAny` walks a ladder of ~40 sizes × 11 contexts × 3
//! inherited themes × 6 data dirs, each step an `access()` syscall. Measured
//! on this machine that is ~109ms per hit and ~248ms per miss, on the UI
//! thread, on every strip rebuild. That is why the dock logged
//! `phases: ... icons=2045ms` at startup and re-resolved every missing icon
//! every few seconds.
//!
//! Index each theme directory once and
//! then answers lookups from memory. This module does the same:
//!
//!   * `Index`   — one hash map per theme directory, `name -> []Candidate`,
//!                 built by scanning the directory tree a single time.
//!   * `Cache`   — decoded pixels keyed by (kind, name, px), LRU-evicted by
//!                 byte budget, so a name is rasterized once per theme.
//!   * negative  — a name that failed is remembered size-independently and
//!                 rejected in O(1) instead of re-walking the ladder.
//!   * generation — a theme change bumps a counter and drops everything.
//!   * worker    — a background thread that rasterizes queued names so the
//!                 UI thread finds pixels already waiting.
//!
//! Everything is keyed by the *theme chain* (the configured theme, everything
//! it inherits, then `hicolor`), expanded across the XDG icon bases in
//! priority order: theme, its inheritance chain, then `hicolor`, across every XDG base.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const logz = @import("../../logz.zig");
const icon_disk = @import("icon_disk.zig");
const icon_lookup = @import("icon_lookup.zig");
const icon_raster = @import("icon_raster.zig");
const icon_themes = @import("icon_themes.zig");

/// Index cache file: magic + a version. Bump the version when the on-disk
/// shape changes; old files then fail the magic check and are rebuilt.
const k_index_magic = "EHII03";

// Ranking — best size match wins, with symbolic fallback.

/// SVG in a resolution-independent (`scalable`) directory outranks any
/// bitmap, no matter how close the bitmap is to the requested size.
const k_svg_rank: i64 = 0;
/// A bitmap at least as large as asked, ranked by smallest overshoot.
const k_overshoot_base: i64 = 1_000_000;
/// A bitmap smaller than asked (or an SVG in a fixed-size dir), ranked by
/// largest undershoot.
const k_undershoot_base: i64 = 2_000_000;
/// Per search-directory priority step: an earlier directory in the theme
/// chain always beats a later one, regardless of per-candidate rank.
const k_prio_span: i64 = 20_000_000;
/// Cap on the depth of one theme directory's tree, root included.
const k_max_depth: u32 = 6;
/// Cap on directories visited while indexing one theme (a pathological tree
/// must not stall the shell).
const k_max_dirs: usize = 8192;
/// Default LRU budget; overridable with `EH_ICON_CACHE_MB` (2..1024).
const k_default_cache_mb: usize = 96;

/// One file that could satisfy a name, with the nominal size of the directory
/// it was found in (0 = scalable/symbolic/root).
pub const Candidate = struct {
    path: []const u8,
    dir_size: u16,
    svg: bool,
};

// Index

/// One theme directory's `name -> candidates` map. Strings are owned by the
/// index arena and live as long as the index does.
pub const DirIndex = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMap(std.ArrayListUnmanaged(Candidate)),

    const Self = @This();

    pub fn init(backing: std.mem.Allocator) Self {
        return .{
            .backing = backing,
            .arena = std.heap.ArenaAllocator.init(backing),
            .map = std.StringHashMap(std.ArrayListUnmanaged(Candidate)).init(backing),
        };
    }

    pub fn deinit(self: *Self) void {
        self.map.deinit();
        self.arena.deinit();
    }

    fn put(self: *Self, name: []const u8, cand: Candidate) !void {
        const a = self.arena.allocator();
        const owned = try a.dupe(u8, name);
        const gop = try self.map.getOrPut(owned);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, cand);
    }

    /// Insert without copying `name`: the loader points it straight into the
    /// index file it keeps alive, so a load touches no per-name allocation.
    fn putBorrowed(self: *Self, name: []const u8, cand: Candidate) !void {
        const gop = try self.map.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.arena.allocator(), cand);
    }

    /// Best candidate for `name` at `px`, by size proximity. Falls back to
    /// the `-symbolic` spelling when the bare name is absent.
    fn lookup(self: *Self, name: []const u8, px: i64) ?Candidate {
        if (self.map.get(name)) |list| {
            if (bestOf(list.items, px)) |c| return c;
        }
        var buf: [256]u8 = undefined;
        const sym = std.fmt.bufPrint(&buf, "{s}-symbolic", .{name}) catch return null;
        if (self.map.get(sym)) |list| return bestOf(list.items, px);
        return null;
    }

    fn bestOf(cands: []const Candidate, px: i64) ?Candidate {
        var best: ?Candidate = null;
        var best_rank: i64 = std.math.maxInt(i64);
        for (cands) |c| {
            const r = rankOf(c, px);
            if (best == null or r < best_rank) {
                best = c;
                best_rank = r;
            }
        }
        return best;
    }

    fn rankOf(c: Candidate, px: i64) i64 {
        // Only a vector in a resolution-independent directory gets the vector
        // rank: some themes ship SVGs inside fixed-size dirs that are really
        // monochrome placeholders and must not beat real scalable artwork.
        if (c.dir_size == 0) {
            return if (c.svg) k_svg_rank else k_undershoot_base + px;
        }
        const s: i64 = c.dir_size;
        if (s >= px) return k_overshoot_base + (s - px);
        return k_undershoot_base + (px - s);
    }
};

/// One directory that contributed files to the index, with the mtime it had
/// when it was scanned. Loading a saved index re-stats these (one syscall
/// each, no directory walks) and rebuilds when any of them changed — so a
/// newly installed icon is picked up, while an unchanged theme loads in a few
/// milliseconds instead of re-walking every size/context directory.
pub const Watch = struct {
    path: []const u8,
    mtime_ns: i64,
};

/// The whole search path: the theme chain expanded across XDG bases, each
/// entry indexed once. Built lazily, dropped on a theme change.
pub const Index = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Priority-ordered theme directories, e.g.
    /// `~/.local/share/icons/MacTahoe-dark`, `.../hicolor`, `/usr/share/icons/hicolor`.
    dirs: std.ArrayListUnmanaged([]const u8) = .empty,
    /// One index per entry in `dirs`.
    indexes: std.ArrayListUnmanaged(DirIndex) = .empty,
    /// Directories whose mtimes gate the on-disk copy of this index.
    watch: std.ArrayListUnmanaged(Watch) = .empty,
    /// Raw contents of the index file when this index came off disk. The
    /// names/paths inside the maps point into it, so it must outlive them.
    data: ?[]u8 = null,
    built: bool = false,

    const Self = @This();

    pub fn init(backing: std.mem.Allocator) Self {
        return .{ .backing = backing, .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Self) void {
        // Everything the scan allocated lives in `arena` (freed wholesale
        // below); a loaded index's strings borrow from `data`. Neither path
        // owns per-string allocations to free here.
        if (self.data) |d| {
            self.backing.free(d);
            self.data = null;
        }
        for (self.indexes.items) |*ix| ix.deinit();
        self.indexes.deinit(self.backing);
        self.dirs.deinit(self.backing);
        self.watch.deinit(self.backing);
        self.arena.deinit();
        self.built = false;
    }

    /// Scan and append one theme directory at the lowest current priority.
    pub fn addDir(self: *Self, io: std.Io, root: []const u8) !void {
        const a = self.arena.allocator();
        const owned = try a.dupe(u8, root);
        try self.dirs.append(self.backing, owned);
        errdefer _ = self.dirs.pop();
        var ix = DirIndex.init(self.backing);
        errdefer ix.deinit();
        // The watch list's metadata comes from the backing allocator (so
        // `deinit` can free it); the paths inside it live in the arena.
        try scanThemeTree(io, root, &ix, &self.watch, self.backing, a);
        try self.indexes.append(self.backing, ix);
    }

    /// Best candidate for `name` at `px` across the whole chain, honouring
    /// theme priority.
    fn find(self: *Self, name: []const u8, px: i64) ?Candidate {
        var best: ?Candidate = null;
        var best_total: i64 = std.math.maxInt(i64);
        for (self.indexes.items, 0..) |*ix, i| {
            const cand = ix.lookup(name, px) orelse continue;
            const total = DirIndex.rankOf(cand, px) + @as(i64, @intCast(i)) * k_prio_span;
            if (best == null or total < best_total) {
                best = cand;
                best_total = total;
            }
        }
        return best;
    }

    // -- on-disk copy ------------------------------------------------------

    /// Load a previously saved index, but only if every directory it was
    /// scanned from still has the mtime it had then. Returns false (leaving
    /// the index empty) on a missing/corrupt file or any changed directory,
    /// so the caller falls back to a scan.
    pub fn load(self: *Self, io: std.Io, path: []const u8) bool {
        const t0 = nowNs();
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, self.backing, std.Io.Limit.limited(64 << 20)) catch return false;
        const t1 = nowNs();
        if (!watchesMatch(io, data)) {
            self.backing.free(data);
            return false;
        }
        const t2 = nowNs();
        self.data = data;
        logz.log("icons: index load read={d:.1}ms watch={d:.1}ms bytes={d}", .{
            @as(f64, @floatFromInt(t1 - t0)) / @as(f64, std.time.ns_per_ms),
            @as(f64, @floatFromInt(t2 - t1)) / @as(f64, std.time.ns_per_ms),
            data.len,
        });
        self.populate(data) catch {
            self.deinit();
            self.* = init(self.backing);
            return false;
        };
        return true;
    }

    /// Every watched directory still matches its recorded mtime?
    fn watchesMatch(io: std.Io, data: []const u8) bool {
        var cur = Cur{ .d = data };
        if (!std.mem.eql(u8, cur.take(6) orelse return false, k_index_magic)) return false;
        const n = cur.readU32() orelse return false;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const p = cur.str() orelse return false;
            const mt = cur.readI64() orelse return false;
            const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
            if (@as(i64, @truncate(st.mtime.nanoseconds)) != mt) return false;
        }
        return true;
    }

    /// Rebuild the maps from a loaded file. Every string borrows from `data`
    /// (which the caller stores in `self.data`), so the only allocations are
    /// the map tables themselves.
    fn populate(self: *Self, data: []const u8) !void {
        var cur = Cur{ .d = data };
        if (!std.mem.eql(u8, cur.take(6) orelse return error.Bad, k_index_magic)) return error.Bad;
        // Watches (kept for the next save).
        const nwatch = cur.readU32() orelse return error.Bad;
        var wi: u32 = 0;
        while (wi < nwatch) : (wi += 1) {
            const p = cur.str() orelse return error.Bad;
            const mt = cur.readI64() orelse return error.Bad;
            try self.watch.append(self.backing, .{ .path = p, .mtime_ns = mt });
        }
        const ndirs = cur.readU32() orelse return error.Bad;
        var di: u32 = 0;
        while (di < ndirs) : (di += 1) {
            const dp = cur.str() orelse return error.Bad;
            try self.dirs.append(self.backing, dp);
            errdefer _ = self.dirs.pop();
            var ix = DirIndex.init(self.backing);
            errdefer ix.deinit();
            const nentries = cur.readU32() orelse return error.Bad;
            var ei: u32 = 0;
            while (ei < nentries) : (ei += 1) {
                const name = cur.str() orelse return error.Bad;
                const ncand = cur.readU32() orelse return error.Bad;
                var ci: u32 = 0;
                while (ci < ncand) : (ci += 1) {
                    const dsz = cur.readU16() orelse return error.Bad;
                    const svg = (cur.take(1) orelse return error.Bad)[0] != 0;
                    const cpath = cur.str() orelse return error.Bad;
                    try ix.putBorrowed(name, .{
                        .path = cpath,
                        .dir_size = dsz,
                        .svg = svg,
                    });
                }
            }
            try self.indexes.append(self.backing, ix);
        }
    }

    /// Write the index (and its watch table) atomically enough: a truncated
    /// or half-written file fails `load` and costs one scan.
    pub fn save(self: *Self, io: std.Io, path: []const u8) void {
        if (self.watch.items.len == 0 or self.indexes.items.len == 0) return;
        const cwd = std.Io.Dir.cwd();
        const file = cwd.createFile(io, path, .{}) catch return;
        var buf: [64 * 1024]u8 = undefined;
        var wr = file.writer(io, &buf);
        saveTo(self, &wr.interface) catch {
            wr.end() catch {};
            file.close(io);
            return;
        };
        wr.end() catch {};
        file.close(io);
    }

    fn saveTo(self: *Self, w: *std.Io.Writer) !void {
        try w.writeAll(k_index_magic);
        try w.writeInt(u32, @intCast(self.watch.items.len), .little);
        for (self.watch.items) |e| {
            try w.writeInt(u32, @intCast(e.path.len), .little);
            try w.writeAll(e.path);
            try w.writeInt(i64, e.mtime_ns, .little);
        }
        try w.writeInt(u32, @intCast(self.indexes.items.len), .little);
        for (self.indexes.items, self.dirs.items) |*ix, dir| {
            try w.writeInt(u32, @intCast(dir.len), .little);
            try w.writeAll(dir);
            var total: u32 = 0;
            var it = ix.map.iterator();
            while (it.next()) |_| total += 1;
            try w.writeInt(u32, total, .little);
            var it2 = ix.map.iterator();
            while (it2.next()) |en| {
                const name = en.key_ptr.*;
                try w.writeInt(u32, @intCast(name.len), .little);
                try w.writeAll(name);
                const cands = en.value_ptr.items;
                try w.writeInt(u32, @intCast(cands.len), .little);
                for (cands) |c| {
                    try w.writeInt(u16, c.dir_size, .little);
                    try w.writeByte(@intFromBool(c.svg));
                    try w.writeInt(u32, @intCast(c.path.len), .little);
                    try w.writeAll(c.path);
                }
            }
        }
    }
};

/// Little-endian cursor over a loaded index file.
const Cur = struct {
    d: []const u8,
    i: usize = 0,

    fn take(self: *Cur, n: usize) ?[]const u8 {
        if (self.i + n > self.d.len) return null;
        const s = self.d[self.i .. self.i + n];
        self.i += n;
        return s;
    }
    fn readU16(self: *Cur) ?u16 {
        const b = self.take(2) orelse return null;
        return std.mem.readInt(u16, b[0..2], .little);
    }
    fn readU32(self: *Cur) ?u32 {
        const b = self.take(4) orelse return null;
        return std.mem.readInt(u32, b[0..4], .little);
    }
    fn readI64(self: *Cur) ?i64 {
        const b = self.take(8) orelse return null;
        return std.mem.readInt(i64, b[0..8], .little);
    }
    fn str(self: *Cur) ?[]const u8 {
        const n = self.readU32() orelse return null;
        if (n > 8192) return null;
        return self.take(n);
    }
};

// Public cache

/// Which kind of key this is; it only affects the cache key and the
/// negative-cache shape, not the lookup itself.
pub const Kind = enum { app, tray };

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    negative_hits: u64 = 0,
    rasters: u64 = 0,
    /// Decodes that never ran because the pixels came off disk.
    disk_hits: u64 = 0,
    index_builds: u64 = 0,
    enqueued: u64 = 0,
};

/// An owned copy of decoded pixels, in cairo ARGB32 (premultiplied BGRA).
/// This is what callers hand to their own model; the cache keeps its own
/// copy too, so the next request for the same name is free.
pub const Owned = struct {
    pixels: []u8,
    w: i32,
    h: i32,

    pub fn deinit(self: *Owned, gpa: std.mem.Allocator) void {
        if (self.pixels.len > 0) gpa.free(self.pixels);
        self.* = .{ .pixels = &.{}, .w = 0, .h = 0 };
    }
};

/// A decoded, cached icon. `pixels` is owned by the cache; a consumer borrows
/// it and must not free it.
pub const Entry = struct {
    pixels: []u8,
    w: i32,
    h: i32,
    bytes: usize,
    /// Theme generation this entry was decoded under; a stale one is dropped
    /// rather than served after a theme switch.
    gen: u64,
    /// LRU links (intrusive doubly-linked list, head = most recent).
    prev: ?*Entry = null,
    next: ?*Entry = null,
};

const Pending = struct {
    key: []u8,
    name: []u8,
    px: i32,
    gen: u64,
};

pub const IconCache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    mu: std.Io.Mutex = std.Io.Mutex.init,
    cv: std.Io.Condition = std.Io.Condition.init,

    /// Ordered search directories (theme chain × bases) + one map each.
    index: Index,
    /// The concrete theme this index was built for ("" until first set).
    theme: []const u8 = "",
    /// Set while a scan runs so a second caller does not repeat it.
    building: bool = false,

    /// StartupWMClass → desktop file, built on the first app id that needs
    /// it. Desktop files do not follow the icon theme, so a theme switch
    /// leaves this alone.
    wm_index: ?*WmIndex = null,
    wm_built: bool = false,
    wm_building: bool = false,

    /// key -> entry.
    map: std.StringHashMap(*Entry),
    /// LRU list head (most recently used) / tail (eviction candidate).
    lru_head: ?*Entry = null,
    lru_tail: ?*Entry = null,
    total_bytes: usize = 0,
    /// Names that failed, keyed size-independently, for O(1) rejection.
    negative: std.StringHashMap(void),
    max_bytes: usize,

    /// Decoded pixels survive process restarts, shared with the overview and
    /// the launcher (one directory, keyed by theme + path stat + px).
    disk: icon_disk.Disk,

    /// Bumped whenever an entry lands. A UI that asked for a background
    /// decode compares this with the value it last saw to know new pixels are
    /// ready — no blocking wait, no polling of individual names.
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Global generation, bumped by every theme change. Entries and queued
    /// jobs carry the generation they were made under.
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Background rasterizer.
    queue: std.ArrayListUnmanaged(Pending) = .empty,
    queued: std.StringHashMap(void),
    worker: ?std.Thread = null,
    quit: bool = false,
    in_flight: u32 = 0,

    stats: Stats = .{},

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Self {
        return .{
            .gpa = gpa,
            .io = io,
            .index = Index.init(gpa),
            .map = std.StringHashMap(*Entry).init(gpa),
            .negative = std.StringHashMap(void).init(gpa),
            .queued = std.StringHashMap(void).init(gpa),
            .max_bytes = cacheBudget(),
            .disk = icon_disk.Disk.init(gpa, io),
        };
    }

    pub fn deinit(self: *Self) void {
        stopWorker(self);
        self.mu.lockUncancelable(self.io);
        self.clearLocked();
        self.mu.unlock(self.io);
        self.map.deinit();
        self.negative.deinit();
        self.queued.deinit();
        self.queue.deinit(self.gpa);
        self.index.deinit();
        self.disk.deinit();
        self.gpa.free(self.theme);
        if (self.wm_index) |ix| {
            ix.arena.deinit();
            self.gpa.destroy(ix);
        }
        self.* = undefined;
    }

    fn cacheBudget() usize {
        const c = @cImport(@cInclude("stdlib.h"));
        if (c.getenv("EH_ICON_CACHE_MB")) |p| {
            const s = std.mem.span(p);
            if (std.fmt.parseInt(usize, s, 10)) |mb| {
                if (mb >= 2 and mb <= 1024) return mb << 20;
            } else |_| {}
        }
        return k_default_cache_mb << 20;
    }

    // -- theme -------------------------------------------------------------

    /// Point the cache at a concrete theme. Everything tied to the previous
    /// theme is dropped and the generation bumps, so any in-flight worker job
    /// discards its stale result instead of poisoning the fresh cache.
    pub fn setTheme(self: *Self, theme: []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (std.mem.eql(u8, self.theme, theme)) return;
        const owned = self.gpa.dupe(u8, theme) catch return;
        self.gpa.free(self.theme);
        self.theme = owned;
        _ = self.generation.fetchAdd(1, .release);
        self.clearLocked();
        logz.log("icons: theme_switch to '{s}'", .{theme});
    }

    // -- lookup ------------------------------------------------------------

    /// Resolve `name` to pixels, rasterizing only on the first miss. Returns
    /// an owned copy so the caller keeps the ownership model it had before
    /// the cache existed (`loadIconFrom` handed out owned buffers).
    pub fn getOwned(self: *Self, kind: Kind, name: []const u8, px: i32) ?Owned {
        const key = self.keyFor(kind, name, px) orelse return null;
        defer self.gpa.free(key);
        if (self.copyOut(key, true)) |o| return o;
        // A miss that was already negative-cached answers null immediately;
        // otherwise this is the first time, so resolve and populate.
        if (self.negative.contains(negativeKey(key))) return null;
        _ = self.resolve(kind, key, name, px);
        return self.copyOut(key, true);
    }

    /// Cache-only lookup: never rasterizes, never builds the index. A paint
    /// loop that already called `enqueue` uses this so a cold icon costs a
    /// placeholder for a few milliseconds instead of a frame-long stall.
    pub fn peek(self: *Self, kind: Kind, name: []const u8, px: i32) ?Owned {
        const key = self.keyFor(kind, name, px) orelse return null;
        defer self.gpa.free(key);
        return self.copyOut(key, false);
    }

    /// Monotonic count of cache inserts (rasterized or disk-loaded). Compare
    /// with the last seen value to discover that a background decode landed.
    pub fn completions(self: *Self) u64 {
        return self.completed.load(.acquire);
    }

    /// Bumped by every theme switch. A caller that asked for icons can notice
    /// that the pixels it is waiting for belong to a superseded theme (every
    /// in-flight result is dropped) and ask again instead of waiting forever.
    pub fn currentGeneration(self: *Self) u64 {
        return self.generation.load(.acquire);
    }

    /// Resolve `name` to a file path through the theme-directory index,
    /// without decoding. The returned slice is borrowed from the index and
    /// lives as long as the cache does (i.e. the process). This is what a
    /// caller that keeps its *own* decode/disk cache — the overview — uses to
    /// skip the ~109ms filesystem probe while retaining its storage layer.
    /// `kind` is accepted for signature parity with `getOwned`/`enqueue` but
    /// unused: the index is keyed by icon name alone.
    pub fn pathFor(self: *Self, kind: Kind, name: []const u8, px: i32) ?[]const u8 {
        _ = kind;
        if (name.len == 0) return null;
        // `Icon=/abs/path.svg` is legal in a desktop file and is used as-is.
        if (std.fs.path.isAbsolute(name)) return name;
        self.ensureIndex();
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const c = self.index.find(name, px) orelse return null;
        return c.path;
    }

    /// Ask the worker to decode `name` in the background. A hit or an
    /// already-queued/negative name is a no-op, so this is cheap to call
    /// every rebuild.
    pub fn enqueue(self: *Self, kind: Kind, name: []const u8, px: i32) void {
        if (name.len == 0) return;
        const key = self.keyFor(kind, name, px) orelse return;
        defer self.gpa.free(key);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.map.get(key) != null) return;
        if (self.negative.contains(negativeKey(key))) return;
        if (self.queued.contains(key)) return;
        const owned_key = self.gpa.dupe(u8, key) catch return;
        self.queued.put(owned_key, {}) catch {
            self.gpa.free(owned_key);
            return;
        };
        const owned_name = self.gpa.dupe(u8, name) catch {
            _ = self.queued.remove(owned_key);
            self.gpa.free(owned_key);
            return;
        };
        self.queue.append(self.gpa, .{
            .key = owned_key,
            .name = owned_name,
            .px = px,
            .gen = self.generation.load(.acquire),
        }) catch {
            _ = self.queued.remove(owned_key);
            self.gpa.free(owned_key);
            self.gpa.free(owned_name);
            return;
        };
        self.stats.enqueued += 1;
        startWorkerLocked(self);
        self.cv.signal(self.io);
    }

    pub fn statsOf(self: *Self) Stats {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.stats;
    }

    /// Tests/teardown: block until the queue is empty and no job is decoding.
    pub fn waitIdle(self: *Self) void {
        self.mu.lockUncancelable(self.io);
        while (self.queue.items.len > 0 or self.in_flight > 0) {
            self.cv.waitUncancelable(self.io, &self.mu);
        }
        self.mu.unlock(self.io);
    }

    // -- internals ---------------------------------------------------------

    fn keyFor(self: *Self, kind: Kind, name: []const u8, px: i32) ?[]u8 {
        if (name.len == 0) return null;
        return std.fmt.allocPrint(self.gpa, "{s}:{s}@{d}", .{ @tagName(kind), name, px }) catch null;
    }

    /// A miss is remembered without its size or extension so one rejection
    /// covers every pixel size.
    /// Copy the cached pixels out under the lock (so they cannot be evicted
    /// mid-copy) and touch the entry. Reports the hit/miss/negative stat.
    /// Copy the cached pixels out under the lock (so they cannot be evicted
    /// mid-copy) and touch the entry. `count` reports hit/miss stats; a
    /// non-blocking `peek` from a paint loop passes false so retries do not
    /// look like misses in the telemetry.
    fn copyOut(self: *Self, key: []const u8, count: bool) ?Owned {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const e = self.map.get(key) orelse {
            if (count) {
                if (self.negative.contains(negativeKey(key))) {
                    self.stats.negative_hits += 1;
                } else {
                    self.stats.misses += 1;
                }
            }
            return null;
        };
        if (count) self.stats.hits += 1;
        self.touch(e);
        const copy = self.gpa.dupe(u8, e.pixels) catch return null;
        return .{ .pixels = copy, .w = e.w, .h = e.h };
    }

    /// Rasterize on a miss and insert. Caller must NOT hold the mutex.
    fn resolve(self: *Self, kind: Kind, key: []const u8, name: []const u8, px: i32) ?*Entry {
        self.ensureIndex();
        const gen = self.generation.load(.acquire);
        if (self.findCandidate(kind, name, px)) |c| return self.decodeAndInsert(key, name, c.path, px, gen);
        self.markNegative(key);
        return null;
    }

    // -- app ids -----------------------------------------------------------

    /// Best candidate for `name` at `px`. A window class rarely equals its
    /// themed icon name — `horizon-files` ships its art as `horizon-filesv2`
    /// and Proton VPN's `proton.vpn.app.gtk` class hides behind a flatpak
    /// desktop id — so app lookups run the desktop-file chain first
    /// (`desktopIconName`), then the strict → broad → generic candidate
    /// ladder the C++ `resolve_and_insert` uses, so a class the theme cannot
    /// name still gets artwork. An absolute `Icon=` path is used as-is.
    ///
    /// Caller must NOT hold the mutex. The returned path points into the
    /// index (or at `name` for an absolute path) and stays valid for the
    /// caller's next use.
    fn findCandidate(self: *Self, kind: Kind, name: []const u8, px: i64) ?Candidate {
        if (std.fs.path.isAbsolute(name)) {
            return .{ .path = name, .dir_size = 0, .svg = std.mem.endsWith(u8, name, ".svg") };
        }
        if (kind == .tray) return self.indexFind(name, px);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const resolved = desktopIconName(self, a, name) orelse name;

        // Strict: the name itself (its `-symbolic` spelling is the index's
        // own fallback), the lowercased form, and the alias table.
        if (self.indexFind(resolved, px)) |c| return c;
        var strict: std.ArrayListUnmanaged([]const u8) = .empty;
        pushLower(&strict, a, resolved);
        pushAliases(&strict, a, resolved);
        for (strict.items) |cand| if (self.indexFind(cand, px)) |c| return c;

        // Broad: the decorated spellings — `short` segment, vendor prefixes.
        var broad: std.ArrayListUnmanaged([]const u8) = .empty;
        pushVariants(&broad, a, resolved);
        for (broad.items) |cand| if (self.indexFind(cand, px)) |c| return c;

        // Generic: a plain "application" glyph beats an empty button.
        for (k_generic_icons) |fb| if (self.indexFind(fb, px)) |c| return c;
        return null;
    }

    /// `Index.find` under the cache lock.
    fn indexFind(self: *Self, name: []const u8, px: i64) ?Candidate {
        if (name.len == 0) return null;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.index.find(name, px);
    }

    /// The icon name the application directories advertise for `app_id`:
    /// first by desktop-id candidates, then through the StartupWMClass index,
    /// using the file's `Icon=` value. Owned by `gpa` (the caller's arena).
    fn desktopIconName(self: *Self, gpa: std.mem.Allocator, app_id: []const u8) ?[]u8 {
        var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer freeStringList(gpa, &dirs);
        appDirs(gpa, &dirs);

        var bases: std.ArrayListUnmanaged([]const u8) = .empty;
        defer freeStringList(gpa, &bases);
        desktopIdCandidates(&bases, gpa, app_id);

        var pbuf: [1024]u8 = undefined;
        for (dirs.items) |dir| {
            for (bases.items) |b| {
                if (dir.len + b.len + 10 > pbuf.len) continue;
                const p = std.fmt.bufPrint(&pbuf, "{s}/{s}.desktop", .{ dir, b }) catch continue;
                if (!fileExists(self.io, p)) continue;
                if (readDesktopEntryKey(gpa, self.io, p, "Icon=")) |ic| return ic;
            }
        }
        if (self.wmDesktopFor(app_id)) |path| {
            if (readDesktopEntryKey(gpa, self.io, path, "Icon=")) |ic| return ic;
        }
        return null;
    }

    /// Build the StartupWMClass index once. The scan holds no cache lock; a
    /// second caller waits for the first instead of repeating it. A failed
    /// scan is remembered too — repeating it per lookup would be worse than
    /// living without it.
    fn ensureWmIndex(self: *Self) void {
        self.mu.lockUncancelable(self.io);
        if (self.wm_built) {
            self.mu.unlock(self.io);
            return;
        }
        while (self.wm_building) self.cv.waitUncancelable(self.io, &self.mu);
        if (self.wm_built) {
            self.mu.unlock(self.io);
            return;
        }
        self.wm_building = true;
        self.mu.unlock(self.io);

        const built = buildWmIndex(self.gpa, self.io);

        self.mu.lockUncancelable(self.io);
        self.wm_building = false;
        self.wm_built = true;
        if (built) |ix| self.wm_index = ix;
        self.cv.broadcast(self.io);
        self.mu.unlock(self.io);
    }

    /// The desktop file whose `StartupWMClass=` names this app id, if any.
    fn wmDesktopFor(self: *Self, app_id: []const u8) ?[]const u8 {
        self.ensureWmIndex();
        var kbuf: [256]u8 = undefined;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const ix = self.wm_index orelse return null;
        if (wmclassKey(&kbuf, app_id)) |k| if (ix.map.get(k)) |p| return p;
        if (wmclassKey(&kbuf, std.fs.path.basename(app_id))) |k2| if (ix.map.get(k2)) |p| return p;
        return null;
    }

    fn decodeAndInsert(self: *Self, key: []const u8, name: []const u8, path: []const u8, px: i32, gen: u64) ?*Entry {
        const decoded = self.pixelsFor(name, path, px) orelse {
            self.markNegative(key);
            return null;
        };
        return self.insert(key, decoded, gen);
    }

    /// `self.theme` under the lock, copied into `buf` — theme ids are short and
    /// callers must not race a `setTheme` that frees the old string.
    fn themeLocked(self: *Self, buf: []u8) []const u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const n = @min(self.theme.len, buf.len);
        @memcpy(buf[0..n], self.theme[0..n]);
        return buf[0..n];
    }

    /// Pixels for one resolved candidate: disk cache first, rasterize and
    /// write back on a miss. Both the inline path and the worker go through
    /// here, so neither can bypass the persistent cache. Caller must NOT hold
    /// the mutex; the returned pixels are owned by the caller.
    fn pixelsFor(self: *Self, name: []const u8, path: []const u8, px: i32) ?icon_raster.Pixels {
        var tbuf: [64]u8 = undefined;
        var kbuf: [16]u8 = undefined;
        const dkey = self.disk.key(self.themeLocked(&tbuf), name, path, px, &kbuf);
        if (dkey) |k| {
            if (self.disk.load(k)) |got| {
                self.mu.lockUncancelable(self.io);
                self.stats.disk_hits += 1;
                self.mu.unlock(self.io);
                return .{ .data = got.pixels, .w = got.w, .h = got.h };
            }
        }
        const t0 = nowNs();
        const decoded = decodeOwned(self.gpa, path, px) orelse return null;
        const dt = nowNs() - t0;
        if (dt > 200 * std.time.ns_per_us) {
            logz.log("icon: decode {s} @{d}px in {d:.2}ms", .{
                name,
                px,
                @as(f64, @floatFromInt(dt)) / @as(f64, std.time.ns_per_ms),
            });
        }
        self.mu.lockUncancelable(self.io);
        self.stats.rasters += 1;
        self.mu.unlock(self.io);
        if (dkey) |k| self.disk.save(k, decoded.data, decoded.w, decoded.h);
        return decoded;
    }

    fn markNegative(self: *Self, key: []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const nk = negativeKey(key);
        const owned = self.gpa.dupe(u8, nk) catch return;
        self.negative.put(owned, {}) catch self.gpa.free(owned);
    }

    /// Store decoded pixels. Takes ownership of `px.data`, and either keeps
    /// it (returning the entry) or frees it (returning null / a rival entry).
    /// Caller must not hold the mutex.
    fn insert(self: *Self, key: []const u8, px: icon_raster.Pixels, gen: u64) ?*Entry {
        const e = self.gpa.create(Entry) catch {
            self.gpa.free(px.data);
            return null;
        };
        e.* = .{ .pixels = px.data, .w = px.w, .h = px.h, .bytes = px.data.len, .gen = gen };
        const owned_key = self.gpa.dupe(u8, key) catch {
            self.gpa.free(px.data);
            self.gpa.destroy(e);
            return null;
        };

        // `kept` is set only when `e` is now owned by the map; anything else
        // (stale generation, a rival that won, an allocation failure) must
        // free `e` and step aside.
        var rival: ?*Entry = null;
        var kept = false;
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            // A theme switch landed while we decoded: drop the stale result.
            if (self.generation.load(.acquire) == gen) {
                if (self.map.getOrPut(owned_key)) |gop| {
                    if (gop.found_existing) {
                        // Another caller won the race; keep theirs.
                        rival = gop.value_ptr.*;
                    } else {
                        gop.value_ptr.* = e;
                        self.pushFront(e);
                        self.total_bytes += e.bytes;
                        self.evictLocked(e);
                        kept = true;
                    }
                } else |_| {}
            }
        }
        // Mutex is free here: release whatever we did not keep. `owned_key`
        // is handed to the map only on the insert path, so it must survive
        // `kept` — freeing it there would leave the map reading a dangling
        // key on the very next lookup.
        if (kept) {
            _ = self.completed.fetchAdd(1, .release);
            return e;
        }
        self.gpa.free(owned_key);
        self.gpa.free(e.pixels);
        self.gpa.destroy(e);
        return rival;
    }

    // -- LRU ---------------------------------------------------------------

    fn pushFront(self: *Self, e: *Entry) void {
        e.prev = null;
        e.next = self.lru_head;
        if (self.lru_head) |h| h.prev = e;
        self.lru_head = e;
        if (self.lru_tail == null) self.lru_tail = e;
    }

    fn unlink(self: *Self, e: *Entry) void {
        if (e.prev) |p| p.next = e.next else self.lru_head = e.next;
        if (e.next) |n| n.prev = e.prev else self.lru_tail = e.prev;
        e.prev = null;
        e.next = null;
    }

    fn touch(self: *Self, e: *Entry) void {
        if (self.lru_head == e) return;
        self.unlink(e);
        self.pushFront(e);
    }

    /// Caller holds the mutex. `protect` is the entry just inserted, which
    /// must never be the one evicted (it would be freed before being handed
    /// back to the caller).
    fn evictLocked(self: *Self, protect: *Entry) void {
        while (self.total_bytes > self.max_bytes) {
            const tail = self.lru_tail orelse break;
            if (tail == protect) break;
            self.unlink(tail);
            self.total_bytes -|= tail.bytes;
            // Erase from the map by matching the pointer value.
            var it = self.map.iterator();
            while (it.next()) |en| {
                if (en.value_ptr.* == tail) {
                    const k = en.key_ptr.*;
                    _ = self.map.remove(k);
                    self.gpa.free(k);
                    break;
                }
            }
            self.gpa.free(tail.pixels);
            self.gpa.destroy(tail);
        }
    }

    /// Caller holds the mutex.
    fn clearLocked(self: *Self) void {
        var it = self.map.iterator();
        while (it.next()) |en| {
            const e = en.value_ptr.*;
            self.gpa.free(e.pixels);
            self.gpa.destroy(e);
            self.gpa.free(en.key_ptr.*);
        }
        self.map.clearRetainingCapacity();
        var nit = self.negative.keyIterator();
        while (nit.next()) |k| self.gpa.free(k.*);
        self.negative.clearRetainingCapacity();
        self.lru_head = null;
        self.lru_tail = null;
        self.total_bytes = 0;
        self.index.deinit();
        self.index = Index.init(self.gpa);
    }

    // -- index build -------------------------------------------------------

    /// Build the search dirs and scan every theme directory, once. Cheap to
    /// call repeatedly after the first.
    fn ensureIndex(self: *Self) void {
        self.mu.lockUncancelable(self.io);
        if (self.index.built) {
            self.mu.unlock(self.io);
            return;
        }
        if (self.building) {
            // Another caller is scanning; wait for it rather than repeat it.
            while (self.building) self.cv.waitUncancelable(self.io, &self.mu);
            self.mu.unlock(self.io);
            return;
        }
        self.building = true;
        const theme = self.gpa.dupe(u8, self.theme) catch {
            self.building = false;
            self.mu.unlock(self.io);
            return;
        };
        self.mu.unlock(self.io);

        const t0 = nowMs();
        buildDirsAndScan(self, theme) catch |err| {
            logz.log("icons: index build failed: {}", .{err});
        };
        self.gpa.free(theme);

        self.mu.lockUncancelable(self.io);
        self.building = false;
        self.index.built = true;
        self.stats.index_builds += 1;
        self.cv.broadcast(self.io);
        self.mu.unlock(self.io);
        logz.log("icons: indexed {d} theme dirs in {d}ms", .{ self.index.dirs.items.len, nowMs() -| t0 });
    }
};

/// Rasterize a resolved path at the requested size. SVGs go through librsvg,
/// everything else through stb_image — same split `icon_lookup.formatOf`
/// used, decided by extension.
fn decodeOwned(gpa: std.mem.Allocator, path: []const u8, px: i32) ?icon_raster.Pixels {
    if (std.mem.endsWith(u8, path, ".svg")) return icon_raster.loadSvg(gpa, path, px);
    return icon_raster.loadPng(gpa, path);
}

/// A miss is remembered without its size or extension so one rejection
/// covers every pixel size.
fn negativeKey(key: []const u8) []const u8 {
    if (std.mem.startsWith(u8, key, "app:") or std.mem.startsWith(u8, key, "tray:")) {
        if (std.mem.lastIndexOfScalar(u8, key, '@')) |at| return key[0..at];
    }
    return key;
}

/// Scan the whole chain. Runs without the mutex held: the scan is the slow
/// part and must never block a paint thread that only wants a cache hit.
fn buildDirsAndScan(c: *IconCache, theme: []const u8) !void {
    const gpa = c.gpa;
    const io = c.io;

    const bases = try icon_lookup.dataDirs(
        gpa,
        getenv("XDG_DATA_HOME"),
        getenv("HOME"),
        getenv("XDG_DATA_DIRS"),
    );
    defer icon_lookup.freeDirs(gpa, bases);

    // An empty theme means "follow the desktop": the C++ load path resolves
    // it through `detect_system_icon_theme`, with hicolor only as the last
    // resort when even that probe comes up empty.
    const theme_id = if (theme.len > 0) theme else (icon_themes.detectSystemIconTheme(io) orelse "hicolor");

    // Fast path: a previous process saved this theme's index. Validating it
    // costs one stat per scanned directory; walking the tree costs ~100ms.
    const cache_path = indexCachePath(gpa, io, theme_id);
    defer if (cache_path) |p| gpa.free(p);
    if (cache_path) |p| {
        const t0 = nowMs();
        if (c.index.load(io, p)) {
            logz.log("icons: index cache hit in {d}ms ({d} theme dirs, {d} scanned dirs)", .{
                nowMs() -| t0,
                c.index.dirs.items.len,
                c.index.watch.items.len,
            });
            return;
        }
    }

    const chain = try themeChain(io, gpa, theme_id, bases);
    defer {
        for (chain) |p| gpa.free(p);
        gpa.free(chain);
    }

    for (chain) |theme_dir| try c.index.addDir(io, theme_dir);

    // Loose icons dropped straight into a base dir, and /usr/share/pixmaps,
    // are the last resort — the old probe ladder checked both.
    for (bases) |b| try c.index.addDir(io, b);
    try c.index.addDir(io, "/usr/share/pixmaps");

    if (cache_path) |p| {
        const t0 = nowMs();
        c.index.save(io, p);
        logz.log("icons: index saved in {d}ms ({d} theme dirs, {d} scanned dirs)", .{
            nowMs() -| t0,
            c.index.dirs.items.len,
            c.index.watch.items.len,
        });
    }
}

/// `~/.cache/Event-Horizon/icon-index/<hash>.ehidx`, keyed by the theme and
/// the XDG search path (so a changed environment never reads a stale index).
fn indexCachePath(gpa: std.mem.Allocator, io: std.Io, theme: []const u8) ?[]u8 {
    const c = @cImport(@cInclude("stdlib.h"));
    const xdg = if (c.getenv("XDG_CACHE_HOME")) |p| std.mem.span(p) else null;
    const base_owned: ?[]u8 = if (xdg == null) blk: {
        const h = if (c.getenv("HOME")) |p| std.mem.span(p) else return null;
        break :blk std.fs.path.join(gpa, &.{ h, ".cache" }) catch return null;
    } else null;
    defer if (base_owned) |b| gpa.free(b);
    const base = xdg orelse base_owned.?;
    const iso = if (c.getenv("EH_ZIG_ISOLATED")) |p| std.mem.span(p).len > 0 else false;
    const dir = std.fs.path.join(gpa, &.{ base, if (iso) "Event-Horizon-zig" else "Event-Horizon", "icon-index" }) catch return null;
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch return null;

    var h = std.hash.Wyhash.init(0x1c0ffee);
    h.update(theme);
    inline for (.{ "XDG_DATA_HOME", "HOME", "XDG_DATA_DIRS" }) |name| {
        h.update(name);
        if (c.getenv(name)) |p| h.update(std.mem.span(p));
    }
    var hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{h.final()}) catch return null;
    return std.fmt.allocPrint(gpa, "{s}/{s}.ehidx", .{ dir, hex }) catch null;
}

/// `<base>/<theme>` for each theme in the inheritance chain, in priority
/// order, across every base that actually has it.
fn themeChain(io: std.Io, gpa: std.mem.Allocator, theme: []const u8, bases: []const []const u8) ![][]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    addUnique(&names, gpa, theme);
    var i: usize = 0;
    var guard: usize = 0;
    while (guard < 5) : (guard += 1) {
        if (i >= names.items.len) break;
        const cur = names.items[i];
        i += 1;
        if (readInherits(io, gpa, bases, cur)) |inh| {
            defer gpa.free(inh);
            var it = std.mem.splitScalar(u8, inh, ',');
            while (it.next()) |raw| {
                const t = std.mem.trim(u8, raw, " \t");
                if (t.len == 0) continue;
                addUnique(&names, gpa, t);
            }
        }
    }
    addUnique(&names, gpa, "hicolor");

    // Expand across bases: an earlier base wins, and a theme missing from a
    // base is simply skipped.
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |o| gpa.free(o);
        out.deinit(gpa);
    }
    for (names.items) |th| {
        for (bases) |b| {
            const p = try std.fs.path.join(gpa, &.{ b, th });
            if (dirExists(io, p)) {
                try out.append(gpa, p);
            } else {
                gpa.free(p);
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

fn addUnique(list: *std.ArrayListUnmanaged([]const u8), gpa: std.mem.Allocator, name: []const u8) void {
    if (name.len == 0 or name.len >= 48) return;
    for (list.items) |n| if (std.mem.eql(u8, n, name)) return;
    const owned = gpa.dupe(u8, name) catch return;
    list.append(gpa, owned) catch gpa.free(owned);
}

fn readInherits(io: std.Io, gpa: std.mem.Allocator, bases: []const []const u8, theme: []const u8) ?[]u8 {
    var pbuf: [1024]u8 = undefined;
    var buf: [8192]u8 = undefined;
    for (bases) |b| {
        const p = std.fmt.bufPrint(&pbuf, "{s}/{s}/index.theme", .{ b, theme }) catch continue;
        const cwd = std.Io.Dir.cwd();
        const data = cwd.readFile(io, p, &buf) catch continue;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "Inherits=")) continue;
            const v = std.mem.trim(u8, line["Inherits=".len..], " \t");
            if (v.len == 0) return null;
            return gpa.dupe(u8, v) catch null;
        }
    }
    return null;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    _ = cwd.statFile(io, path, .{}) catch return false;
    return true;
}

const StackNode = struct { path: []const u8, rel: []const u8, depth: u32 };

/// Walk one theme directory's tree (depth ≤ 6), indexing every svg/png/xpm
/// with the nominal size of the directory it sits in, subdirectories included.
fn scanThemeTree(io: std.Io, root: []const u8, ix: *DirIndex, watch: *std.ArrayListUnmanaged(Watch), wgpa: std.mem.Allocator, wa: std.mem.Allocator) !void {
    const gpa = ix.arena.allocator();
    const sizes = try themeDirSizes(io, root, gpa);

    var stack: std.ArrayListUnmanaged(StackNode) = .empty;
    defer {
        for (stack.items) |n| {
            gpa.free(n.path);
            gpa.free(n.rel);
        }
        stack.deinit(gpa);
    }
    try stack.append(gpa, .{ .path = try gpa.dupe(u8, root), .rel = try gpa.dupe(u8, ""), .depth = 0 });

    var visited: usize = 0;
    while (stack.items.len > 0) {
        if (visited > k_max_dirs) break;
        visited += 1;
        const node = stack.pop().?;
        defer {
            gpa.free(node.path);
            gpa.free(node.rel);
        }

        var dsize: u16 = 0;
        if (node.rel.len > 0) {
            if (sizes.get(node.rel)) |s| dsize = s;
            if (dsize == 0) dsize = dirSizeFromLeaf(node.rel);
        }
        try scanSubdir(io, node.path, dsize, ix, watch, wgpa, wa);
        if (node.depth >= k_max_depth) continue;
        try pushChildren(gpa, io, &stack, node.path, node.rel, node.depth);
    }
}

/// DPI-mirror variant: `apps@2x`, `steam@2x.png`, `foo@3x.svg`. Icon packs
/// ship these as hardlinks/2x rasters of the base art, and the old probe never
/// inserted them into a candidate path — indexing them would double the index
/// and, because they rank identically to the base file, silently redirect
/// lookups at a mirror for no benefit. Skipped at every level.
fn isDpiVariant(name: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, name, '@') orelse return false;
    var i = at + 1;
    while (i < name.len and name[i] >= '0' and name[i] <= '9') i += 1;
    return i > at + 1 and i < name.len and name[i] == 'x';
}

/// Index the files directly inside one directory (no recursion).
fn scanSubdir(io: std.Io, dir_path: []const u8, dsize: u16, ix: *DirIndex, watch: *std.ArrayListUnmanaged(Watch), wgpa: std.mem.Allocator, wa: std.mem.Allocator) !void {
    // Remember the directory's mtime: a saved index is only trusted while
    // every directory it read still looks untouched (one stat per directory
    // on load, instead of the walk).
    if (std.Io.Dir.cwd().statFile(io, dir_path, .{})) |st| {
        const owned = wa.dupe(u8, dir_path) catch null;
        if (owned) |p| {
            watch.append(wgpa, .{ .path = p, .mtime_ns = @truncate(st.mtime.nanoseconds) }) catch {};
        }
    } else |_| {}
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        // A link counts as a file here: themes symlink shared art across size dirs, and a scan
        // that accepts only plain files silently drops those icons (which is
        // how `steam`/`org.gnome.Ptyxis` fell through to `-symbolic` and
        // `hicolor`).
        if (e.kind != .file and e.kind != .sym_link) continue;
        if (e.name.len == 0 or e.name[0] == '.') continue;
        if (isDpiVariant(e.name)) continue;
        const dot = std.mem.lastIndexOfScalar(u8, e.name, '.') orelse continue;
        const ext = e.name[dot + 1 ..];
        const is_svg = std.mem.eql(u8, ext, "svg");
        if (!is_svg and !std.mem.eql(u8, ext, "png") and !std.mem.eql(u8, ext, "xpm")) continue;
        const stem = e.name[0..dot];
        const full = try std.fs.path.join(ix.arena.allocator(), &.{ dir_path, e.name });
        try ix.put(stem, .{ .path = full, .dir_size = dsize, .svg = is_svg });
    }
}

fn pushChildren(gpa: std.mem.Allocator, io: std.Io, stack: *std.ArrayListUnmanaged(StackNode), parent: []const u8, parent_rel: []const u8, depth: u32) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, parent, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.name.len == 0 or e.name[0] == '.') continue;
        if (isDpiVariant(e.name)) continue; // `apps@2x` is a mirror, not a size dir
        // A theme may symlink its whole size tree at another pack
        // (`apps/scalable -> ../../MacTahoe/apps/scalable`). Skipping links
        // here dropped every bare-name icon in those dirs, which is what sent
        // lookups to `-symbolic`/`hicolor`. A link is followed only when it
        // actually resolves to a directory, so icon-file links don't land on
        // the walk stack and burn depth/budget on a failed `openDir`.
        if (e.kind != .directory) {
            if (e.kind != .sym_link) continue;
            const child_probe = std.fs.path.join(gpa, &.{ parent, e.name }) catch continue;
            defer gpa.free(child_probe);
            const st = cwd.statFile(io, child_probe, .{}) catch continue;
            if (st.kind != .directory) continue;
        }
        const child = try std.fs.path.join(gpa, &.{ parent, e.name });
        errdefer gpa.free(child);
        const rel = if (parent_rel.len == 0)
            try gpa.dupe(u8, e.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ parent_rel, e.name });
        errdefer gpa.free(rel);
        try stack.append(gpa, .{ .path = child, .rel = rel, .depth = depth + 1 });
    }
}

/// Nominal size declared in `index.theme` for a relative directory path
/// (`"16"`, `"48x48/apps"`). First of Size/MinSize/MaxSize wins. Keys are
/// arena-allocated, so the whole map dies with the index.
fn themeDirSizes(io: std.Io, root: []const u8, alloc: std.mem.Allocator) !std.StringHashMap(u16) {
    var out = std.StringHashMap(u16).init(alloc);
    var pbuf: [1024]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/index.theme", .{root});
    var buf: [65536]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFile(io, p, &buf) catch return out;
    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }
        if (section.len == 0 or std.mem.eql(u8, section, "Icon Theme")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key, "Size") and
            !std.mem.eql(u8, key, "MinSize") and
            !std.mem.eql(u8, key, "MaxSize")) continue;
        if (out.contains(section)) continue;
        const v = std.fmt.parseInt(u16, std.mem.trim(u8, line[eq + 1 ..], " \t"), 10) catch continue;
        if (v > 0 and v <= 4096) {
            const owned = try alloc.dupe(u8, section);
            try out.put(owned, v);
        }
    }
    return out;
}

/// Parse a relative directory path for a nominal size: `"48"` or `"48x48"`,
/// including a numeric ancestor when the leaf is a context (`"48x48/apps"`).
fn dirSizeFromLeaf(rel: []const u8) u16 {
    if (rel.len == 0 or rel.len > 64) return 0;
    var it = std.mem.splitScalar(u8, rel, '/');
    var parts: [8][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |p| {
        if (p.len == 0 or n >= parts.len) continue;
        parts[n] = p;
        n += 1;
    }
    if (n == 0) return 0;
    // Leaf first, then walk up: a context dir carries no number but its
    // parent (`48x48`) does.
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (parseSizeToken(parts[i])) |s| return s;
    }
    return 0;
}

fn parseSizeToken(tok: []const u8) ?u16 {
    if (tok.len == 0 or tok.len > 16) return null;
    const x = std.mem.indexOfScalar(u8, tok, 'x') orelse {
        return std.fmt.parseInt(u16, tok, 10) catch null;
    };
    if (x == 0 or x + 1 >= tok.len) return null;
    const a = std.fmt.parseInt(u16, tok[0..x], 10) catch return null;
    if (a == 0 or a > 4096) return null;
    return a;
}

// App ids: window class → desktop `Icon=`

/// The names every theme is expected to carry; the C++ fell back to these so
/// a button whose app has no themed art still painted something.
const k_generic_icons = [_][]const u8{
    "application-x-executable", "application-default-icon", "system-run", "dialog-question",
};

const Alias = struct { key: []const u8, values: []const []const u8 };

/// Hand-written exceptions for launchers whose window class matches no themed
/// name (parity: the C++ `icon_aliases`).
const k_aliases = [_]Alias{
    .{ .key = "microsoft-edge-dev", .values = &.{ "microsoft-edge", "microsoft-edge-beta", "edge" } },
    .{ .key = "microsoft-edge", .values = &.{ "microsoft-edge-dev", "edge" } },
    .{ .key = "msedge", .values = &.{ "microsoft-edge", "microsoft-edge-stable", "com.microsoft.Edge", "edge" } },
    .{ .key = "steam", .values = &.{ "steam_icon", "steam-icon", "steam_client" } },
    .{ .key = "co.anysphere.cursor", .values = &.{ "cursor", "cursor-ide" } },
    .{ .key = "github-desktop", .values = &.{ "github", "github-client" } },
    .{ .key = "com.github.GitHubDesktop", .values = &.{"github-desktop"} },
    .{ .key = "org.gnome.Nautilus", .values = &.{ "system-file-manager", "nautilus" } },
    .{ .key = "nautilus", .values = &.{"system-file-manager"} },
    .{ .key = "system-file-manager", .values = &.{"nautilus"} },
    .{ .key = "org.gnome.Ptyxis", .values = &.{ "utilities-terminal", "terminal" } },
    .{ .key = "Cider", .values = &.{ "cider", "cider-music" } },
    .{ .key = "otter-term", .values = &.{ "utilities-terminal", "terminal" } },
};

/// StartupWMClass → desktop file, built once per cache and kept for the
/// process. Desktop files do not follow the icon theme, so a theme switch
/// leaves it alone.
const WmIndex = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
};

/// One scan of the application directories for `StartupWMClass=` labels
/// (parity: the C++ `ensure_wmclass_desktop_index_built`). Returns null when
/// the directories cannot be scanned; the caller records the attempt anyway.
fn buildWmIndex(gpa: std.mem.Allocator, io: std.Io) ?*WmIndex {
    const idx = gpa.create(WmIndex) catch return null;
    idx.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };

    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeStringList(gpa, &dirs);
    appDirs(gpa, &dirs);

    const a = idx.arena.allocator();
    var pbuf: [1280]u8 = undefined;
    for (dirs.items) |dir_path| {
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            // Links count: flatpak and distro packaging both symlink entries.
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (e.name.len < 9 or !std.mem.endsWith(u8, e.name, ".desktop")) continue;
            const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir_path, e.name }) catch continue;
            const wm = readDesktopEntryKey(gpa, io, p, "StartupWMClass=") orelse continue;
            defer gpa.free(wm);
            indexWmLabels(idx, a, wm, p);
        }
    }
    return idx;
}

/// Index one `StartupWMClass=` label: the normalized key and, when it
/// differs, the lowercased spelling — the two shapes the C++ lookup tries.
/// First writer wins, so earlier directories keep priority.
fn indexWmLabels(idx: *WmIndex, a: std.mem.Allocator, label: []const u8, desktop_path: []const u8) void {
    var kbuf: [256]u8 = undefined;
    const key = wmclassKey(&kbuf, label) orelse return;
    putWm(idx, a, key, desktop_path);
    var lbuf: [256]u8 = undefined;
    const lower = lowerInto(&lbuf, label) orelse return;
    if (!std.mem.eql(u8, lower, key)) putWm(idx, a, lower, desktop_path);
}

fn putWm(idx: *WmIndex, a: std.mem.Allocator, key: []const u8, desktop_path: []const u8) void {
    if (key.len == 0 or idx.map.contains(key)) return;
    const k = a.dupe(u8, key) catch return;
    const v = a.dupe(u8, desktop_path) catch return;
    idx.map.put(a, k, v) catch {};
}

/// The value of a `[Desktop Entry]` key (`Icon=`, `StartupWMClass=`) in a
/// desktop file, trimmed, with comments and later sections ignored (parity:
/// the C++ `read_desktop_desktop_entry_key`). Ownership passes to the caller.
fn readDesktopEntryKey(gpa: std.mem.Allocator, io: std.Io, path: []const u8, key_prefix: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, gpa, std.Io.Limit.limited(256 * 1024)) catch return null;
    defer gpa.free(data);
    var in_entry = false;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry or !std.mem.startsWith(u8, line, key_prefix)) continue;
        const v = std.mem.trim(u8, line[key_prefix.len..], " \t\r");
        if (v.len == 0) return null;
        return gpa.dupe(u8, v) catch null;
    }
    return null;
}

/// Application directories in priority order: the user's, then each data
/// dir's (parity: the C++ `desktop_application_dirs`).
fn appDirs(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8)) void {
    if (getenv("XDG_DATA_HOME")) |d| {
        pushPath(gpa, out, &.{ d, "applications" });
    } else if (getenv("HOME")) |h| {
        pushPath(gpa, out, &.{ h, ".local", "share", "applications" });
    }
    if (getenv("XDG_DATA_DIRS")) |dirs| {
        var it = std.mem.splitScalar(u8, dirs, ':');
        while (it.next()) |d| {
            if (d.len == 0) continue;
            pushPath(gpa, out, &.{ d, "applications" });
        }
    } else {
        pushPath(gpa, out, &.{ "/usr/local/share", "applications" });
        pushPath(gpa, out, &.{ "/usr/share", "applications" });
    }
}

fn pushPath(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), parts: []const []const u8) void {
    const p = std.fs.path.join(gpa, parts) catch return;
    for (out.items) |x| {
        if (std.mem.eql(u8, x, p)) {
            gpa.free(p);
            return;
        }
    }
    out.append(gpa, p) catch gpa.free(p);
}

const Transform = enum { lower, spaces, underscores, hyphens, dots, slashes };

/// Desktop-file basenames to try for a window class (parity: the C++
/// `desktop_id_candidate_bases`): the id, its lowercase, its last dotted
/// segment, separator swaps of each, and the basename of a path-shaped id.
/// Temporary copies come from `gpa`, which the app path passes as an arena.
fn desktopIdCandidates(out: *std.ArrayListUnmanaged([]const u8), gpa: std.mem.Allocator, app_id: []const u8) void {
    var base = app_id;
    if (base.len > 8 and std.mem.endsWith(u8, base, ".desktop")) base = base[0 .. base.len - 8];
    if (base.len > 4 and std.mem.endsWith(u8, base, ".exe")) base = base[0 .. base.len - 4];
    if (base.len > 4 and std.mem.endsWith(u8, base, ".bin")) base = base[0 .. base.len - 4];

    const lower = lowerCopy(gpa, base) orelse return;
    defer gpa.free(lower);

    pushTransformed(out, gpa, base, null);
    pushTransformed(out, gpa, lower, null);
    pushTransformed(out, gpa, lastDotSegment(base), null);
    pushTransformed(out, gpa, lastDotSegment(lower), null);
    inline for (.{ Transform.spaces, Transform.underscores, Transform.hyphens, Transform.dots }) |t| {
        pushTransformed(out, gpa, base, t);
        pushTransformed(out, gpa, lower, t);
    }

    // Path-shaped ids (`C:\Program Files\App\app.exe`) keep their last
    // segment, with the Windows suffix off.
    const posix = transformCopy(gpa, base, .slashes) orelse return;
    defer gpa.free(posix);
    const slash = std.mem.lastIndexOfScalar(u8, posix, '/') orelse return;
    if (slash + 1 >= posix.len) return;
    const seg = posix[slash + 1 ..];
    pushTransformed(out, gpa, seg, null);
    pushTransformed(out, gpa, seg, .lower);
    if (seg.len > 4 and std.ascii.endsWithIgnoreCase(seg, ".exe")) {
        pushTransformed(out, gpa, seg[0 .. seg.len - 4], null);
        pushTransformed(out, gpa, seg[0 .. seg.len - 4], .lower);
    }
}

fn lastDotSegment(s: []const u8) []const u8 {
    const pos = std.mem.lastIndexOfScalar(u8, s, '.') orelse return &.{};
    if (pos + 1 >= s.len) return &.{};
    return s[pos + 1 ..];
}

/// The lookup key for a window class: trimmed, last path segment,
/// lowercased, `.exe` off (parity: the C++ `wmclass_lookup_key`).
fn wmclassKey(buf: []u8, s_in: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, s_in, " \t\r");
    if (s.len == 0 or s.len > buf.len) return null;
    var last_start: usize = 0;
    for (s, 0..) |ch, i| {
        const c = if (ch == '\\') '/' else ch;
        buf[i] = std.ascii.toLower(c);
        if (c == '/') last_start = i + 1;
    }
    var out = buf[0..s.len];
    if (last_start > 0 and last_start < out.len) out = out[last_start..];
    if (out.len > 4 and std.mem.endsWith(u8, out, ".exe")) out = out[0 .. out.len - 4];
    if (out.len == 0) return null;
    return out;
}

fn transformCopy(gpa: std.mem.Allocator, s: []const u8, t: Transform) ?[]u8 {
    const out = gpa.alloc(u8, s.len) catch return null;
    for (s, 0..) |ch, i| out[i] = switch (t) {
        .lower => std.ascii.toLower(ch),
        .spaces => if (ch == ' ' or ch == '\t') '-' else ch,
        .underscores => if (ch == '_') '-' else ch,
        .hyphens => if (ch == '-') '_' else ch,
        .dots => if (ch == '.') '-' else ch,
        .slashes => if (ch == '\\') '/' else ch,
    };
    return out;
}

/// Append one spelling of a candidate name, trimmed and deduplicated.
fn pushTransformed(out: *std.ArrayListUnmanaged([]const u8), gpa: std.mem.Allocator, s: []const u8, t: ?Transform) void {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0 or trimmed.len > 512) return;
    if (t) |kind| {
        const copy = transformCopy(gpa, trimmed, kind) orelse return;
        defer gpa.free(copy);
        pushName(out, gpa, copy);
    } else {
        pushName(out, gpa, trimmed);
    }
}

fn pushName(out: *std.ArrayListUnmanaged([]const u8), gpa: std.mem.Allocator, s: []const u8) void {
    if (s.len == 0) return;
    for (out.items) |x| if (std.mem.eql(u8, x, s)) return;
    const owned = gpa.dupe(u8, s) catch return;
    out.append(gpa, owned) catch gpa.free(owned);
}

fn pushLower(out: *std.ArrayListUnmanaged([]const u8), a: std.mem.Allocator, s: []const u8) void {
    const l = lowerCopy(a, s) orelse return;
    defer a.free(l);
    pushName(out, a, l);
}

fn pushAliases(out: *std.ArrayListUnmanaged([]const u8), a: std.mem.Allocator, name: []const u8) void {
    for (k_aliases) |al| {
        if (std.mem.eql(u8, al.key, name)) for (al.values) |v| pushName(out, a, v);
    }
    const lower = lowerCopy(a, name) orelse return;
    defer a.free(lower);
    for (k_aliases) |al| {
        if (std.mem.eql(u8, al.key, lower)) for (al.values) |v| pushName(out, a, v);
    }
}

/// The broad candidate pass (parity: the C++ `icon_name_variants`): the
/// lowercase, the `short` last-dot segment, the alias table, and the
/// vendor-prefix rewrites for launchers that version their icons.
fn pushVariants(out: *std.ArrayListUnmanaged([]const u8), a: std.mem.Allocator, name: []const u8) void {
    const lower = lowerCopy(a, name) orelse return;
    defer a.free(lower);
    pushName(out, a, lower);
    const short = lastDotSegment(name);
    if (short.len > 0) {
        pushTransformed(out, a, short, null);
        pushTransformed(out, a, short, .lower);
    }
    const short_lower = lastDotSegment(lower);
    if (short_lower.len > 0) pushName(out, a, short_lower);
    pushAliases(out, a, name);

    if (std.mem.startsWith(u8, lower, "steam_icon_")) {
        pushName(out, a, "steam");
        pushName(out, a, "steam-client");
    }
    if (std.mem.startsWith(u8, lower, "msedge-") or std.mem.startsWith(u8, lower, "microsoft-edge-")) {
        pushName(out, a, "microsoft-edge");
        pushName(out, a, "edge");
        pushName(out, a, "msedge");
    }
    if (std.mem.startsWith(u8, lower, "chrome-") or std.mem.startsWith(u8, lower, "google-chrome-")) {
        pushName(out, a, "google-chrome");
        pushName(out, a, "chrome-browser");
        pushName(out, a, "chromium-browser");
        pushName(out, a, "chromium");
    }
}

fn freeStringList(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |s| gpa.free(s);
    list.deinit(gpa);
}

fn lowerCopy(gpa: std.mem.Allocator, s: []const u8) ?[]u8 {
    const out = gpa.alloc(u8, s.len) catch return null;
    for (s, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
}

fn lowerInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len == 0 or s.len > buf.len) return null;
    for (s, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..s.len];
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn nowMs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 + @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * std.time.ns_per_s + @as(u64, @intCast(@max(ts.nsec, 0)));
}

fn getenv(key: [:0]const u8) ?[]const u8 {
    const c = @cImport(@cInclude("stdlib.h"));
    const p = c.getenv(key) orelse return null;
    const s = std.mem.span(p);
    return if (s.len == 0) null else s;
}

// Worker

fn startWorkerLocked(self: *IconCache) void {
    if (self.worker != null) return;
    self.quit = false;
    self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch null;
}

fn workerMain(self: *IconCache) void {
    while (true) {
        self.mu.lockUncancelable(self.io);
        while (self.queue.items.len == 0 and !self.quit) {
            self.cv.waitUncancelable(self.io, &self.mu);
        }
        if (self.quit) {
            self.mu.unlock(self.io);
            return;
        }
        const job = self.queue.orderedRemove(0);
        _ = self.queued.remove(job.key);
        self.in_flight += 1;
        self.mu.unlock(self.io);

        // Decode with the mutex free: this is the slow part and a paint
        // thread asking for a *different* icon must not stall behind it.
        self.ensureIndex();
        const gen = self.generation.load(.acquire);
        const kind: Kind = if (std.mem.startsWith(u8, job.key, "app:")) .app else .tray;
        if (self.findCandidate(kind, job.name, job.px)) |c| {
            if (self.pixelsFor(job.name, c.path, job.px)) |px| {
                _ = self.insert(job.key, px, gen);
            } else {
                self.markNegative(job.key);
            }
        } else {
            self.markNegative(job.key);
        }

        self.mu.lockUncancelable(self.io);
        self.gpa.free(job.key);
        self.gpa.free(job.name);
        self.in_flight -|= 1;
        self.cv.broadcast(self.io);
        self.mu.unlock(self.io);
    }
}

fn stopWorker(self: *IconCache) void {
    self.mu.lockUncancelable(self.io);
    self.quit = true;
    self.cv.broadcast(self.io);
    const t = self.worker;
    self.worker = null;
    self.mu.unlock(self.io);
    // Join outside the lock: the worker needs the mutex to observe `quit`.
    if (t) |th| th.join();
}

// Process-wide singleton

var global: ?IconCache = null;

/// Install the shell's allocator/io for the shared cache. Idempotent, so the
/// dock and the overview can both call it without coordinating.
pub fn initGlobal(gpa: std.mem.Allocator, io: std.Io) void {
    if (global != null) return;
    global = IconCache.init(gpa, io);
}

/// The shared cache, or null before `initGlobal`. Callers must handle null so
/// a binary that never installs a cache still resolves icons the old way.
pub fn shared() ?*IconCache {
    return if (global) |*c| c else null;
}

/// Tear the shared cache down. Callers must stop using it first.
pub fn deinitGlobal() void {
    if (global) |*c| {
        c.deinit();
        global = null;
    }
}

// Tests

test "icon-cache: index finds a sized app icon without probing per size" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/eh-icc-test1";
    try makeTree(io, &.{
        base ++ "/icons/T/48x48/apps",
    });
    defer removeTree(io, &.{
        base ++ "/icons/T/48x48/apps/app.png",
        base ++ "/icons/T/48x48/apps",
        base ++ "/icons/T/48x48",
        base ++ "/icons/T",
        base ++ "/icons",
        base,
    });
    try touch(io, base ++ "/icons/T/48x48/apps/app.png");

    var ix = Index.init(t.allocator);
    defer ix.deinit();
    try ix.addDir(io, base ++ "/icons/T");

    // Requested 44, only a 48px bitmap exists — still resolves.
    const c = ix.find("app", 44);
    try t.expect(c != null);
    try t.expectEqualStrings(base ++ "/icons/T/48x48/apps/app.png", c.?.path);
    // A name nobody ships misses cleanly.
    try t.expect(ix.find("nope", 44) == null);
}

test "icon-cache: an SVG in scalable/ beats a closer bitmap" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/eh-icc-test2";
    try makeTree(io, &.{
        base ++ "/icons/T/scalable/apps",
        base ++ "/icons/T/48x48/apps",
    });
    defer removeTree(io, &.{
        base ++ "/icons/T/scalable/apps/dual.svg",
        base ++ "/icons/T/48x48/apps/dual.png",
        base ++ "/icons/T/scalable/apps",
        base ++ "/icons/T/48x48/apps",
        base ++ "/icons/T",
        base ++ "/icons",
        base,
    });
    try touch(io, base ++ "/icons/T/scalable/apps/dual.svg");
    try touch(io, base ++ "/icons/T/48x48/apps/dual.png");

    var ix = Index.init(t.allocator);
    defer ix.deinit();
    try ix.addDir(io, base ++ "/icons/T");

    const c = ix.find("dual", 48).?;
    try t.expect(c.svg);
    try t.expectEqualStrings(base ++ "/icons/T/scalable/apps/dual.svg", c.path);
}

test "icon-cache: theme priority beats per-candidate rank" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/eh-icc-test3";
    try makeTree(io, &.{
        base ++ "/icons/Primary/apps",
        base ++ "/icons/Fallback/apps",
    });
    defer removeTree(io, &.{
        base ++ "/icons/Primary/apps/pri.png",
        base ++ "/icons/Fallback/apps/pri.png",
        base ++ "/icons/Primary/apps",
        base ++ "/icons/Fallback/apps",
        base ++ "/icons/Primary",
        base ++ "/icons/Fallback",
        base ++ "/icons",
        base,
    });
    try touch(io, base ++ "/icons/Primary/apps/pri.png");
    try touch(io, base ++ "/icons/Fallback/apps/pri.png");

    var ix = Index.init(t.allocator);
    defer ix.deinit();
    // Primary indexed first, Fallback second.
    try ix.addDir(io, base ++ "/icons/Primary");
    try ix.addDir(io, base ++ "/icons/Fallback");

    const c = ix.find("pri", 48).?;
    try t.expectEqualStrings(base ++ "/icons/Primary/apps/pri.png", c.path);
}

test "icon-cache: a -symbolic spelling answers when the bare name is absent" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/eh-icc-test4";
    try makeTree(io, &.{base ++ "/icons/T/scalable/apps"});
    defer removeTree(io, &.{
        base ++ "/icons/T/scalable/apps/gear-symbolic.svg",
        base ++ "/icons/T/scalable/apps",
        base ++ "/icons/T",
        base ++ "/icons",
        base,
    });
    try touch(io, base ++ "/icons/T/scalable/apps/gear-symbolic.svg");

    var ix = Index.init(t.allocator);
    defer ix.deinit();
    try ix.addDir(io, base ++ "/icons/T");
    const c = ix.find("gear", 48).?;
    try t.expectEqualStrings(base ++ "/icons/T/scalable/apps/gear-symbolic.svg", c.path);
}

test "icon-cache: negative key drops the size suffix" {
    const t = std.testing;
    try t.expectEqualStrings("app:ghost", negativeKey("app:ghost@64"));
    try t.expectEqualStrings("tray:ghost", negativeKey("tray:ghost@64"));
    // A bare key is left alone.
    try t.expectEqualStrings("plain", negativeKey("plain"));
}

test "icon-cache: a miss is rejected in O(1) the second time" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    var c = IconCache.init(t.allocator, threaded.io());
    defer c.deinit();
    // Point at a theme that has nothing, so every lookup misses. Tray names
    // are looked up in the index alone; *app* names would keep resolving
    // through the generic `application-x-executable` fallback on any machine
    // whose themes ship one, and a negative-cache test needs a real miss.
    c.setTheme("DefinitelyNotATheme");

    // No icon by this name exists anywhere, so the first call indexes and
    // misses; the second must be served from the negative set.
    _ = c.getOwned(.tray, "com.example.NoSuchIcon", 44);
    const s1 = c.statsOf();
    _ = c.getOwned(.tray, "com.example.NoSuchIcon", 44);
    const s2 = c.statsOf();
    try t.expect(s1.misses >= 1);
    try t.expect(s2.negative_hits >= 1);
    // Every size of the same name shares one rejection.
    _ = c.getOwned(.tray, "com.example.NoSuchIcon", 128);
    const s3 = c.statsOf();
    try t.expect(s3.negative_hits >= 2);
    // The index really was built (this is the expensive-once part).
    try t.expect(s3.index_builds >= 1);
}

// -- tiny filesystem helpers for the tests ---------------------------------

fn makeTree(io: std.Io, dirs: []const []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    for (dirs) |d| try cwd.createDirPath(io, d);
}

fn removeTree(io: std.Io, entries: []const []const u8) void {
    const cwd = std.Io.Dir.cwd();
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        cwd.deleteFile(io, entries[i]) catch {
            cwd.deleteDir(io, entries[i]) catch {};
        };
    }
}

fn touch(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const f = try cwd.createFile(io, path, .{});
    f.close(io);
}
