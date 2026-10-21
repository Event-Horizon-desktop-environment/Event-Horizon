//! ClipStack history store — the on-disk half of the clipboard history.
//!
//! Layout: one file per entry inside a single directory
//! (`$XDG_DATA_HOME/event-horizon/clipstack`, see `defaultDir`), named
//! `entry-<id>` with `<id>` a zero-padded monotonic counter. One file per
//! entry keeps every write atomic (write `….tmp`, rename over the final
//! name), makes pruning a plain unlink, and needs no lock file: only the
//! ClipStack daemon appends; the picker only reads and unlinks.
//!
//! Entry file format, little-endian throughout:
//!
//!     off  size  field
//!     0    4     magic "EHC1"
//!     4    1     format version (1)
//!     5    1     kind (0 text, 1 files, 2 image, 3 other)
//!     6    2     reserved, zero
//!     8    8     captured_ms (i64, unix epoch milliseconds)
//!     16   8     digest (Wyhash over every payload's mime+data)
//!     24   2     payload count
//!     26   6     reserved, zero
//!     32   —     payload headers, then payload data:
//!                   u16 mime length, mime bytes, u64 data length
//!                 every payload's header first, then the data blocks in
//!                 the same order.
//!
//! `list()` reads only the fixed header, the payload headers and the first
//! `limits.preview_bytes` of the first payload, so opening the picker never
//! pulls image blobs off disk. `load()` is the only path that reads content.

const std = @import("std");

pub const magic = "EHC1";
pub const version: u8 = 1;
pub const header_bytes: usize = 32;
pub const max_payloads: usize = 8;

pub const Kind = enum(u8) {
    text = 0,
    files = 1,
    image = 2,
    other = 3,

    pub fn tag(self: Kind) []const u8 {
        return switch (self) {
            .text => "text",
            .files => "files",
            .image => "image",
            .other => "other",
        };
    }

    pub fn fromByte(b: u8) ?Kind {
        return switch (b) {
            0 => .text,
            1 => .files,
            2 => .image,
            3 => .other,
            else => null,
        };
    }
};

pub const limits = struct {
    /// Reject entries larger than this (payload bytes + headers).
    pub const entry_bytes: usize = 64 * 1024 * 1024;
    /// Prune beyond this many entries…
    pub const max_entries: usize = 256;
    /// …and beyond this many total bytes on disk.
    pub const total_bytes: u64 = 512 * 1024 * 1024;
    /// Preview bytes kept in `Meta.preview`.
    pub const preview_bytes: usize = 160;
};

/// One mime payload of an entry. On `insert` the slices are caller-owned and
/// only borrowed for the call; in a loaded `Entry` they are owned by the
/// entry and released by `Entry.deinit`.
pub const Payload = struct {
    mime: []const u8,
    data: []const u8,
};

pub const Entry = struct {
    id: u64 = 0,
    kind: Kind = .other,
    captured_ms: i64 = 0,
    digest: u64 = 0,
    payloads: []Payload = &.{},

    pub fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        for (self.payloads) |p| {
            alloc.free(@constCast(p.mime));
            alloc.free(@constCast(p.data));
        }
        alloc.free(self.payloads);
        self.payloads = &.{};
    }

    pub fn dataFor(self: *const Entry, mime: []const u8) ?[]const u8 {
        for (self.payloads) |p| {
            if (std.mem.eql(u8, p.mime, mime)) return p.data;
        }
        return null;
    }

    /// The biggest payload — what the picker saves for "save image".
    pub fn largest(self: *const Entry) ?Payload {
        var best: ?Payload = null;
        for (self.payloads) |p| {
            if (best == null or p.data.len > best.?.data.len) best = p;
        }
        return best;
    }
};

/// Everything the picker needs to paint a row without touching the payload.
pub const Meta = struct {
    id: u64 = 0,
    kind: Kind = .other,
    captured_ms: i64 = 0,
    digest: u64 = 0,
    /// Entry file size in bytes, for display.
    size: u64 = 0,
    payload_count: u16 = 0,
    first_mime: []u8 = &.{},
    /// Single-line preview: text head, first file URI, or "WxH" for images.
    preview: []u8 = &.{},

    pub fn deinit(self: *Meta, alloc: std.mem.Allocator) void {
        alloc.free(self.first_mime);
        alloc.free(self.preview);
        self.first_mime = &.{};
        self.preview = &.{};
    }
};

pub fn freeMetas(alloc: std.mem.Allocator, metas: []Meta) void {
    for (metas) |*m| m.deinit(alloc);
    alloc.free(metas);
}

/// Wyhash over `mime ‖ data` for every payload, in order. Used for the
/// store's duplicate check (same digest as the newest entry ⇒ don't append).
pub fn digestPayloads(payloads: []const Payload) u64 {
    var h = std.hash.Wyhash.init(0);
    for (payloads) |p| {
        h.update(p.mime);
        h.update(p.data);
    }
    return h.final();
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

/// `$XDG_DATA_HOME/event-horizon/clipstack`, falling back to
/// `$HOME/.local/share/…`. Null when neither variable is usable (or on
/// allocation failure) — the caller reports and exits.
pub fn defaultDir(alloc: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8) ?[]u8 {
    if (nonEmpty(xdg_data_home)) |base| {
        return std.fs.path.join(alloc, &.{ base, "event-horizon", "clipstack" }) catch null;
    }
    const h = nonEmpty(home) orelse return null;
    return std.fs.path.join(alloc, &.{ h, ".local", "share", "event-horizon", "clipstack" }) catch null;
}

/// Width×height from a PNG's IHDR chunk, or null when the bytes are not a
/// PNG header. The daemon stores the result as the entry preview, and the
/// picker uses it to label image rows without decoding.
pub fn pngSize(data: []const u8) ?[2]u32 {
    if (data.len < 24) return null;
    if (!std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return null;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, data[16..20], .big);
    const h = std.mem.readInt(u32, data[20..24], .big);
    if (w == 0 or h == 0) return null;
    return .{ w, h };
}

/// Copy up to `out.len` bytes of `raw` into `out`, replacing control bytes
/// with spaces so a preview can never move the cursor or break the row
/// layout. Multi-byte UTF-8 passes through untouched.
pub fn sanitizePreview(out: []u8, raw: []const u8) []u8 {
    const n = @min(out.len, raw.len);
    for (raw[0..n], 0..) |ch, i| {
        out[i] = if (ch < 0x20 or ch == 0x7f) ' ' else ch;
    }
    return out[0..n];
}

pub const Store = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    dir_path: []u8,
    dir: std.Io.Dir,
    next_id: u64 = 1,

    pub fn open(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) !Store {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, dir_path);
        var dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
        errdefer dir.close(io);
        const path = try alloc.dupe(u8, dir_path);
        errdefer alloc.free(path);
        var st = Store{
            .alloc = alloc,
            .io = io,
            .dir_path = path,
            .dir = dir,
        };
        st.next_id = if (st.maxId() catch null) |m| m + 1 else 1;
        return st;
    }

    pub fn deinit(self: *Store) void {
        self.dir.close(self.io);
        self.alloc.free(self.dir_path);
        self.* = undefined;
    }

    fn entryName(buf: *[24]u8, id: u64, tmp: bool) []const u8 {
        return std.fmt.bufPrint(buf, "entry-{d:0>12}{s}", .{ id, if (tmp) ".tmp" else "" }) catch unreachable;
    }

    fn parseId(name: []const u8) ?u64 {
        if (!std.mem.startsWith(u8, name, "entry-")) return null;
        const digits = name["entry-".len..];
        if (digits.len == 0) return null;
        for (digits) |ch| {
            if (ch < '0' or ch > '9') return null;
        }
        return std.fmt.parseInt(u64, digits, 10) catch null;
    }

    /// Highest entry id on disk, or null when the store is empty.
    pub fn maxId(self: *Store) !?u64 {
        var it = self.dir.iterate();
        var best: ?u64 = null;
        while (try it.next(self.io)) |e| {
            if (e.kind != .file) continue;
            const id = parseId(e.name) orelse continue;
            if (best == null or id > best.?) best = id;
        }
        return best;
    }

    /// Append one entry. Returns the new id, or null when the entry is empty
    /// or larger than `limits.entry_bytes` (the caller then owns the
    /// selection but keeps no history for it). `payloads` are borrowed.
    pub fn insert(self: *Store, kind: Kind, captured_ms: i64, payloads: []const Payload) !?u64 {
        if (payloads.len == 0 or payloads.len > max_payloads) return null;
        var total: usize = header_bytes;
        for (payloads) |p| {
            if (p.mime.len > std.math.maxInt(u16)) return null;
            total += 2 + p.mime.len + 8;
            total += p.data.len;
        }
        if (total > limits.entry_bytes) return null;

        const digest = digestPayloads(payloads);
        const id = self.next_id;
        var nbuf: [24]u8 = undefined;
        var tbuf: [24]u8 = undefined;
        const final = entryName(&nbuf, id, false);
        const tmp = entryName(&tbuf, id, true);

        const file = try self.dir.createFile(self.io, tmp, .{});
        var keep: bool = false;
        defer if (!keep) self.dir.deleteFile(self.io, tmp) catch {};

        var hdr: [header_bytes]u8 = [_]u8{0} ** header_bytes;
        @memcpy(hdr[0..4], magic);
        hdr[4] = version;
        hdr[5] = @intFromEnum(kind);
        std.mem.writeInt(i64, hdr[8..16], captured_ms, .little);
        std.mem.writeInt(u64, hdr[16..24], digest, .little);
        std.mem.writeInt(u16, hdr[24..26], @intCast(payloads.len), .little);

        var wbuf: [64 * 1024]u8 = undefined;
        var wr = file.writer(self.io, &wbuf);
        wr.interface.writeAll(&hdr) catch {
            file.close(self.io);
            return error.WriteFailed;
        };
        for (payloads) |p| {
            var plen: [2]u8 = undefined;
            std.mem.writeInt(u16, &plen, @intCast(p.mime.len), .little);
            wr.interface.writeAll(&plen) catch {
                file.close(self.io);
                return error.WriteFailed;
            };
            wr.interface.writeAll(p.mime) catch {
                file.close(self.io);
                return error.WriteFailed;
            };
            var dlen: [8]u8 = undefined;
            std.mem.writeInt(u64, &dlen, p.data.len, .little);
            wr.interface.writeAll(&dlen) catch {
                file.close(self.io);
                return error.WriteFailed;
            };
        }
        for (payloads) |p| {
            wr.interface.writeAll(p.data) catch {
                file.close(self.io);
                return error.WriteFailed;
            };
        }
        wr.end() catch {
            file.close(self.io);
            return error.WriteFailed;
        };
        file.close(self.io);
        try self.dir.rename(tmp, self.dir, final, self.io);
        keep = true;
        self.next_id = id + 1;
        return id;
    }

    const Head = struct {
        kind: Kind,
        captured_ms: i64,
        digest: u64,
        count: u16,
    };

    fn readAt(file: std.Io.File, io: std.Io, off: u64, out: []u8) !void {
        var done: usize = 0;
        while (done < out.len) {
            const n = try file.readPositionalAll(io, out[done..], off + done);
            if (n == 0) return error.ShortRead;
            done += n;
        }
    }

    fn parseHead(buf: *const [header_bytes]u8) ?Head {
        if (!std.mem.eql(u8, buf[0..4], magic)) return null;
        if (buf[4] != version) return null;
        const kind = Kind.fromByte(buf[5]) orelse return null;
        return .{
            .kind = kind,
            .captured_ms = std.mem.readInt(i64, buf[8..16], .little),
            .digest = std.mem.readInt(u64, buf[16..24], .little),
            .count = std.mem.readInt(u16, buf[24..26], .little),
        };
    }

    /// Open `entry-<id>` and read a `Meta` without pulling payload blocks.
    fn readMeta(self: *Store, alloc: std.mem.Allocator, id: u64, size: u64) !Meta {
        var nbuf: [24]u8 = undefined;
        const name = entryName(&nbuf, id, false);
        const file = try self.dir.openFile(self.io, name, .{});
        defer file.close(self.io);

        var hbuf: [header_bytes]u8 = undefined;
        try readAt(file, self.io, 0, &hbuf);
        const head = parseHead(&hbuf) orelse return error.BadEntry;
        if (head.count == 0 or head.count > max_payloads) return error.BadEntry;

        // Payload headers, then the first data block's offset.
        var mime_buf: [256]u8 = undefined;
        var off: u64 = header_bytes;
        var first_mime: []const u8 = &.{};
        var first_data_len: u64 = 0;
        var i: usize = 0;
        while (i < head.count) : (i += 1) {
            var lb: [2]u8 = undefined;
            try readAt(file, self.io, off, &lb);
            const mlen: usize = std.mem.readInt(u16, &lb, .little);
            off += 2;
            if (mlen > mime_buf.len) return error.BadEntry;
            try readAt(file, self.io, off, mime_buf[0..mlen]);
            off += mlen;
            var db: [8]u8 = undefined;
            try readAt(file, self.io, off, &db);
            const dlen = std.mem.readInt(u64, &db, .little);
            off += 8;
            if (i == 0) {
                first_mime = mime_buf[0..mlen];
                first_data_len = dlen;
            }
        }

        var meta = Meta{
            .id = id,
            .kind = head.kind,
            .captured_ms = head.captured_ms,
            .digest = head.digest,
            .size = size,
            .payload_count = head.count,
            .first_mime = try alloc.dupe(u8, first_mime),
        };
        errdefer alloc.free(meta.first_mime);

        const pv_len: usize = @intCast(@min(@as(u64, limits.preview_bytes), first_data_len));
        var pv_raw: [limits.preview_bytes]u8 = undefined;
        try readAt(file, self.io, off, pv_raw[0..pv_len]);
        if (head.kind == .image) {
            if (pngSize(pv_raw[0..pv_len])) |wh| {
                meta.preview = try std.fmt.allocPrint(alloc, "{d}x{d}", .{ wh[0], wh[1] });
            } else {
                meta.preview = try alloc.dupe(u8, "image");
            }
        } else {
            const clean = sanitizePreview(pv_raw[0..pv_len], pv_raw[0..pv_len]);
            meta.preview = try alloc.dupe(u8, clean);
        }
        return meta;
    }

    /// All entries newest-first. Corrupt or half-written files are skipped,
    /// not fatal: a power cut mid-`insert` must never wedge the picker.
    pub fn list(self: *Store, alloc: std.mem.Allocator) ![]Meta {
        const IdSize = struct { id: u64, size: u64 };
        var ids: std.ArrayList(IdSize) = .empty;
        defer ids.deinit(alloc);

        var it = self.dir.iterate();
        while (try it.next(self.io)) |e| {
            if (e.kind != .file) continue;
            const id = parseId(e.name) orelse continue;
            const st = self.dir.statFile(self.io, e.name, .{}) catch continue;
            try ids.append(alloc, .{ .id = id, .size = st.size });
        }
        std.mem.sort(IdSize, ids.items, {}, struct {
            fn newer(_: void, a: IdSize, b: IdSize) bool {
                return a.id > b.id;
            }
        }.newer);

        var metas: std.ArrayList(Meta) = .empty;
        errdefer {
            for (metas.items) |*m| m.deinit(alloc);
            metas.deinit(alloc);
        }
        for (ids.items) |rec| {
            const m = self.readMeta(alloc, rec.id, rec.size) catch continue;
            try metas.append(alloc, m);
        }
        return metas.toOwnedSlice(alloc);
    }

    pub fn newestMeta(self: *Store, alloc: std.mem.Allocator) !?Meta {
        const id = (try self.maxId()) orelse return null;
        var nbuf: [24]u8 = undefined;
        const name = entryName(&nbuf, id, false);
        const st = self.dir.statFile(self.io, name, .{}) catch return null;
        return self.readMeta(alloc, id, st.size) catch null;
    }

    /// Read one full entry. Caller frees with `Entry.deinit`.
    pub fn load(self: *Store, alloc: std.mem.Allocator, id: u64) !Entry {
        var nbuf: [24]u8 = undefined;
        const name = entryName(&nbuf, id, false);
        const data = try self.dir.readFileAlloc(self.io, name, alloc, .limited(limits.entry_bytes + 4096));
        defer alloc.free(data);
        if (data.len < header_bytes) return error.BadEntry;

        var hbuf: [header_bytes]u8 = undefined;
        @memcpy(&hbuf, data[0..header_bytes]);
        const head = parseHead(&hbuf) orelse return error.BadEntry;
        if (head.count == 0 or head.count > max_payloads) return error.BadEntry;

        var payloads = try alloc.alloc(Payload, head.count);
        errdefer alloc.free(payloads);

        var off: usize = header_bytes;
        var mimes: std.ArrayList([]const u8) = .empty;
        defer mimes.deinit(alloc);
        var lens: std.ArrayList(u64) = .empty;
        defer lens.deinit(alloc);
        errdefer {
            for (mimes.items) |m| alloc.free(@constCast(m));
        }
        var i: usize = 0;
        while (i < head.count) : (i += 1) {
            if (off + 2 > data.len) return error.BadEntry;
            const mlen: usize = std.mem.readInt(u16, data[off..][0..2], .little);
            off += 2;
            if (off + mlen + 8 > data.len) return error.BadEntry;
            const mime = try alloc.dupe(u8, data[off .. off + mlen]);
            errdefer alloc.free(mime);
            try mimes.append(alloc, mime);
            off += mlen;
            const dlen = std.mem.readInt(u64, data[off..][0..8], .little);
            off += 8;
            try lens.append(alloc, dlen);
        }
        for (mimes.items, 0..) |mime, j| {
            const dlen: usize = @intCast(lens.items[j]);
            if (off + dlen > data.len) return error.BadEntry;
            payloads[j] = .{
                .mime = mime,
                .data = try alloc.dupe(u8, data[off .. off + dlen]),
            };
            off += dlen;
        }
        return .{
            .id = id,
            .kind = head.kind,
            .captured_ms = head.captured_ms,
            .digest = head.digest,
            .payloads = payloads,
        };
    }

    pub fn remove(self: *Store, id: u64) void {
        var nbuf: [24]u8 = undefined;
        self.dir.deleteFile(self.io, entryName(&nbuf, id, false)) catch {};
    }

    /// Exclusive run-lock for the watching daemon. `flock` keeps a second
    /// `horizon-clipstack` from watching the same store: two watchers would
    /// each see the other's re-publish as a foreign selection and re-own it
    /// again, ping-ponging forever (found live — two daemons produced
    /// hundreds of duplicate log lines per second). Returns the open lock
    /// file; hold it for the process lifetime. Null when another daemon
    /// already holds it or the file cannot be locked.
    pub fn tryRunLock(self: *Store) ?std.Io.File {
        const file = self.dir.createFile(self.io, ".lock", .{ .truncate = false }) catch return null;
        const rc = std.os.linux.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
        if (std.os.linux.errno(rc) != .SUCCESS) {
            file.close(self.io);
            return null;
        }
        return file;
    }

    /// Delete every entry. Returns how many files were unlinked.
    pub fn wipe(self: *Store) usize {
        var count: usize = 0;
        var it = self.dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            if (parseId(e.name) == null) continue;
            self.dir.deleteFile(self.io, e.name) catch continue;
            count += 1;
        }
        return count;
    }

    /// Enforce the entry-count and byte caps, oldest first. The newest entry
    /// is never pruned, even if it alone exceeds the byte cap.
    pub fn prune(self: *Store, max_entries: usize, total_bytes: u64) void {
        const Rec = struct { id: u64, size: u64 };
        var recs: [512]Rec = undefined;
        var n: usize = 0;
        var it = self.dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            const id = parseId(e.name) orelse continue;
            if (n >= recs.len) break;
            const st = self.dir.statFile(self.io, e.name, .{}) catch continue;
            recs[n] = .{ .id = id, .size = st.size };
            n += 1;
        }
        const recs_slice = recs[0..n];
        std.mem.sort(Rec, recs_slice, {}, struct {
            fn newer(_: void, a: Rec, b: Rec) bool {
                return a.id > b.id;
            }
        }.newer);

        var bytes: u64 = 0;
        var nbuf: [24]u8 = undefined;
        for (recs_slice, 0..) |rec, i| {
            bytes += rec.size;
            if (i < max_entries and (bytes <= total_bytes or i == 0)) continue;
            self.dir.deleteFile(self.io, entryName(&nbuf, rec.id, false)) catch {};
        }
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn testDir(t: *testing.TmpDir) []const u8 {
    return &t.sub_path;
}

fn openTestStore(t: *testing.TmpDir) !Store {
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/clipstack", .{testDir(t)}) catch unreachable;
    return Store.open(testing.io, testing.allocator, path);
}

const sample_png_prefix = [_]u8{
    0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
    0,    0,    0,    13,   'I',  'H',  'D',  'R',
    0x00, 0x00, 0x07, 0x80, 0x00, 0x00, 0x04, 0x38,
};

test "clipstack store: text entry round-trips" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var st = try openTestStore(&tmp);
    defer st.deinit();

    const payloads = [_]Payload{
        .{ .mime = "text/plain;charset=utf-8", .data = "hello clipboard" },
        .{ .mime = "text/plain", .data = "hello clipboard" },
    };
    const id = (try st.insert(.text, 1700000000000, &payloads)).?;
    try t.expectEqual(@as(u64, 1), id);

    const metas = try st.list(t.allocator);
    defer freeMetas(t.allocator, metas);
    try t.expectEqual(@as(usize, 1), metas.len);
    try t.expectEqual(Kind.text, metas[0].kind);
    try t.expectEqual(@as(u16, 2), metas[0].payload_count);
    try t.expectEqualStrings("hello clipboard", metas[0].preview);
    try t.expectEqualStrings("text/plain;charset=utf-8", metas[0].first_mime);

    var entry = try st.load(t.allocator, id);
    defer entry.deinit(t.allocator);
    try t.expectEqualStrings("hello clipboard", entry.dataFor("text/plain").?);
    try t.expectEqualStrings("hello clipboard", entry.dataFor("text/plain;charset=utf-8").?);
    try t.expect(entry.captured_ms == 1700000000000);
    try t.expectEqual(metas[0].digest, entry.digest);
}

test "clipstack store: newest-first listing and monotonic ids" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var st = try openTestStore(&tmp);
    defer st.deinit();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "entry {d}", .{i});
        const p = [_]Payload{.{ .mime = "text/plain", .data = label }};
        _ = (try st.insert(.text, @intCast(1000 + i), &p)).?;
    }
    const metas = try st.list(t.allocator);
    defer freeMetas(t.allocator, metas);
    try t.expectEqual(@as(usize, 3), metas.len);
    try t.expectEqualStrings("entry 2", metas[0].preview);
    try t.expectEqualStrings("entry 0", metas[2].preview);
    try t.expect(metas[0].id > metas[1].id and metas[1].id > metas[2].id);

    const newest = (try st.newestMeta(t.allocator)).?;
    defer {
        var m = newest;
        m.deinit(t.allocator);
    }
    try t.expectEqual(metas[0].id, newest.id);
}

test "clipstack store: reopening keeps ids monotonic" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    {
        var st = try openTestStore(&tmp);
        defer st.deinit();
        const p = [_]Payload{.{ .mime = "text/plain", .data = "first" }};
        _ = (try st.insert(.text, 1, &p)).?;
    }
    var st2 = try openTestStore(&tmp);
    defer st2.deinit();
    const p2 = [_]Payload{.{ .mime = "text/plain", .data = "second" }};
    const id2 = (try st2.insert(.text, 2, &p2)).?;
    try t.expectEqual(@as(u64, 2), id2);
}

test "clipstack store: image entries preview as WxH" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var st = try openTestStore(&tmp);
    defer st.deinit();

    try t.expectEqual([2]u32{ 1920, 1080 }, pngSize(&sample_png_prefix).?);
    try t.expect(pngSize("not a png at all, no sir") == null);

    const p = [_]Payload{.{ .mime = "image/png", .data = &sample_png_prefix }};
    _ = (try st.insert(.image, 5, &p)).?;
    const metas = try st.list(t.allocator);
    defer freeMetas(t.allocator, metas);
    try t.expectEqual(Kind.image, metas[0].kind);
    try t.expectEqualStrings("1920x1080", metas[0].preview);
}

test "clipstack store: files entries keep the first uri as preview" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var st = try openTestStore(&tmp);
    defer st.deinit();

    const body = "copy\nfile:///home/matt/Notes/todo.md\nfile:///home/matt/a b.txt\n";
    const p = [_]Payload{.{ .mime = "x-special/gnome-copied-files", .data = body }};
    _ = (try st.insert(.files, 7, &p)).?;
    const metas = try st.list(t.allocator);
    defer freeMetas(t.allocator, metas);
    try t.expectEqual(Kind.files, metas[0].kind);
    try t.expect(std.mem.indexOf(u8, metas[0].preview, "todo.md") != null);
    try t.expect(std.mem.indexOfScalar(u8, metas[0].preview, '\n') == null);
}

test "clipstack store: preview sanitizes control bytes, keeps utf-8" {
    const t = testing;
    var out: [8]u8 = undefined;
    const got = sanitizePreview(&out, "a\tb\r\nc\x7f");
    try t.expectEqualStrings("a b  c ", got);
    var out2: [16]u8 = undefined;
    const got2 = sanitizePreview(&out2, "héllo→wörld");
    try t.expectEqualStrings("héllo→wörld", got2);
}

test "clipstack store: oversize and empty entries are rejected" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var st = try openTestStore(&tmp);
    defer st.deinit();

    try t.expect((try st.insert(.text, 0, &.{})) == null);
    const huge = try t.allocator.alloc(u8, limits.entry_bytes + 1);
    defer t.allocator.free(huge);
    @memset(huge, 'x');
    const p = [_]Payload{.{ .mime = "text/plain", .data = huge }};
    try t.expect((try st.insert(.text, 0, &p)) == null);
    const metas = try st.list(t.allocator);
    defer freeMetas(t.allocator, metas);
    try t.expectEqual(@as(usize, 0), metas.len);
}

test "clipstack store: remove and wipe" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var st = try openTestStore(&tmp);
    defer st.deinit();

    var i: usize = 0;
    var ids: [3]u64 = undefined;
    while (i < 3) : (i += 1) {
        const p = [_]Payload{.{ .mime = "text/plain", .data = "x" }};
        ids[i] = (try st.insert(.text, @intCast(i), &p)).?;
    }
    st.remove(ids[1]);
    var metas = try st.list(t.allocator);
    try t.expectEqual(@as(usize, 2), metas.len);
    freeMetas(t.allocator, metas);

    try t.expectEqual(@as(usize, 2), st.wipe());
    metas = try st.list(t.allocator);
    defer freeMetas(t.allocator, metas);
    try t.expectEqual(@as(usize, 0), metas.len);
    try t.expect((try st.newestMeta(t.allocator)) == null);
}

test "clipstack store: prune drops oldest by count and bytes" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var st = try openTestStore(&tmp);
    defer st.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const p = [_]Payload{.{ .mime = "text/plain", .data = "0123456789" }};
        _ = (try st.insert(.text, @intCast(i), &p)).?;
    }
    st.prune(3, std.math.maxInt(u64));
    var metas = try st.list(t.allocator);
    try t.expectEqual(@as(usize, 3), metas.len);
    try t.expectEqualStrings("0123456789", metas[0].preview);
    freeMetas(t.allocator, metas);

    // Byte cap: with 10-byte payloads plus ~44 bytes of per-entry overhead,
    // a 100-byte cap can hold exactly one entry — the newest one must stay.
    st.prune(100, 100);
    metas = try st.list(t.allocator);
    defer freeMetas(t.allocator, metas);
    try t.expectEqual(@as(usize, 1), metas.len);
    try t.expectEqual(@as(u64, 5), metas[0].id);
}

test "clipstack store: corrupt files are skipped, list stays healthy" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var st = try openTestStore(&tmp);
    defer st.deinit();

    const p = [_]Payload{.{ .mime = "text/plain", .data = "good" }};
    _ = (try st.insert(.text, 1, &p)).?;
    {
        const f = try st.dir.createFile(testing.io, "entry-000000000099", .{});
        defer f.close(testing.io);
        var wbuf: [64]u8 = undefined;
        var wr = f.writer(testing.io, &wbuf);
        try wr.interface.writeAll("EHC1garbage-not-a-real-entry-header");
        try wr.end();
    }
    const metas = try st.list(t.allocator);
    defer freeMetas(t.allocator, metas);
    try t.expectEqual(@as(usize, 1), metas.len);
    try t.expectEqualStrings("good", metas[0].preview);
}

test "clipstack store: run lock is exclusive and releases on close" {
    const t = testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var st = try openTestStore(&tmp);
    defer st.deinit();

    const first = st.tryRunLock().?;
    try t.expect(st.tryRunLock() == null);
    first.close(t.io);
    const third = st.tryRunLock().?;
    third.close(t.io);
}

test "clipstack store: defaultDir prefers XDG_DATA_HOME, falls back to HOME" {
    const t = testing;
    const a = defaultDir(t.allocator, "/xdg/data", "/home/u").?;
    defer t.allocator.free(a);
    try t.expectEqualStrings("/xdg/data/event-horizon/clipstack", a);
    const b = defaultDir(t.allocator, "", "/home/u").?;
    defer t.allocator.free(b);
    try t.expectEqualStrings("/home/u/.local/share/event-horizon/clipstack", b);
    try t.expect(defaultDir(t.allocator, null, null) == null);
}
