//! IANA tz database reader for the world clock: the UTC offset of a named
//! zone at an instant, the local zone's id, and the civil-time math the
//! clock rows need.
//!
//! Offsets come straight out of the system TZif files
//! (`/usr/share/zoneinfo/<id>`, `/etc/localtime`), so daylight saving,
//! half-hour and 45-minute zones are all correct. Parsing is pure over a
//! byte slice (unit-testable with a hand-built block) and the store only
//! caches parsed zones; a missing or unreadable database degrades to UTC
//! offsets instead of failing.

const std = @import("std");

/// Wall-clock fields for one instant in one zone. `wday` is 0 = Sunday.
pub const Civil = struct {
    y: i32,
    mo: u32,
    d: u32,
    h: u32,
    mi: u32,
    s: u32,
    wday: u32,
};

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
pub fn daysFromCivil(y_in: i32, mo: u32, d: u32) i64 {
    var y: i64 = y_in;
    const m: i64 = mo;
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @intCast(if (m > 2) m - 3 else m + 9);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_in: i64) struct { y: i32, mo: u32, d: u32 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else -9);
    if (m <= 2) y += 1;
    return .{ .y = @intCast(y), .mo = @intCast(m), .d = @intCast(d) };
}

/// The civil fields an epoch second names once a zone offset is added.
pub fn civilFromEpoch(epoch_sec: i64) Civil {
    const days = @divFloor(epoch_sec, 86400);
    const sod: i64 = @mod(epoch_sec, 86400);
    const c = civilFromDays(days);
    const su: u32 = @intCast(sod);
    return .{
        .y = c.y,
        .mo = c.mo,
        .d = c.d,
        .h = su / 3600,
        .mi = (su / 60) % 60,
        .s = su % 60,
        .wday = @intCast(@mod(days + 4, 7)),
    };
}

/// One parsed TZif block: the transition list and the offsets it points at.
pub const Zone = struct {
    trans_times: []i64 = &.{},
    trans_types: []u8 = &.{},
    offsets: []i32 = &.{},
    /// Offset in force before the first transition (and for zones with no
    /// transitions): the first non-DST type, else type 0, else UTC.
    default_off: i32 = 0,

    pub fn deinit(self: *Zone, alloc: std.mem.Allocator) void {
        if (self.trans_times.len > 0) alloc.free(self.trans_times);
        if (self.trans_types.len > 0) alloc.free(self.trans_types);
        if (self.offsets.len > 0) alloc.free(self.offsets);
        self.* = .{};
    }

    pub fn offsetAt(self: *const Zone, epoch: i64) i32 {
        if (self.trans_times.len == 0) return self.default_off;
        var lo: usize = 0;
        var hi: usize = self.trans_times.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.trans_times[mid] <= epoch) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return self.default_off;
        const ti = self.trans_types[lo - 1];
        if (ti < self.offsets.len) return self.offsets[ti];
        return self.default_off;
    }
};

const Counts = struct {
    isutcnt: u32 = 0,
    isstdcnt: u32 = 0,
    leapcnt: u32 = 0,
    timecnt: u32 = 0,
    typecnt: u32 = 0,
    charcnt: u32 = 0,

    fn read(b: []const u8) Counts {
        return .{
            .isutcnt = std.mem.readInt(u32, b[20..24], .big),
            .isstdcnt = std.mem.readInt(u32, b[24..28], .big),
            .leapcnt = std.mem.readInt(u32, b[28..32], .big),
            .timecnt = std.mem.readInt(u32, b[32..36], .big),
            .typecnt = std.mem.readInt(u32, b[36..40], .big),
            .charcnt = std.mem.readInt(u32, b[40..44], .big),
        };
    }

    fn valid(self: *const Counts) bool {
        return self.timecnt <= 100_000 and self.typecnt <= 300 and
            self.charcnt <= 65_536 and self.leapcnt <= 10_000 and
            self.isutcnt <= 300 and self.isstdcnt <= 300;
    }

    fn blockLen(self: *const Counts, time_size: usize) usize {
        return @as(usize, self.timecnt) * time_size + self.timecnt +
            @as(usize, self.typecnt) * 6 + self.charcnt +
            @as(usize, self.leapcnt) * (time_size + 4) +
            self.isstdcnt + self.isutcnt;
    }
};

/// Parse one TZif file (version 1, 2, 3 or 4). Prefers the 64-bit block when
/// the file has one; allocates the transition arrays with `alloc`.
pub fn parseZone(alloc: std.mem.Allocator, bytes: []const u8) !Zone {
    if (bytes.len < 44) return error.BadTzif;
    if (!std.mem.eql(u8, bytes[0..4], "TZif")) return error.BadTzif;
    const version = bytes[4];
    var counts = Counts.read(bytes[0..44]);
    if (!counts.valid()) return error.BadTzif;
    var header_pos: usize = 0;
    var time_size: usize = 4;
    if (version == '2' or version == '3' or version == '4') {
        const end1 = 44 + counts.blockLen(4);
        if (end1 + 44 > bytes.len) return error.BadTzif;
        if (!std.mem.eql(u8, bytes[end1..][0..4], "TZif")) return error.BadTzif;
        header_pos = end1;
        counts = Counts.read(bytes[header_pos..][0..44]);
        if (!counts.valid()) return error.BadTzif;
        time_size = 8;
    }

    const n: usize = counts.timecnt;
    const types_n: usize = counts.typecnt;
    var pos = header_pos + 44;

    if (pos + n * time_size + n + types_n * 6 > bytes.len) return error.BadTzif;
    var times = try alloc.alloc(i64, n);
    errdefer if (times.len > 0) alloc.free(times);
    for (0..n) |i| {
        const at = pos + i * time_size;
        times[i] = if (time_size == 8)
            std.mem.readInt(i64, bytes[at..][0..8], .big)
        else
            std.mem.readInt(i32, bytes[at..][0..4], .big);
    }
    pos += n * time_size;

    const ttypes = try alloc.alloc(u8, n);
    errdefer if (ttypes.len > 0) alloc.free(ttypes);
    @memcpy(ttypes, bytes[pos..][0..n]);
    pos += n;

    var offsets = try alloc.alloc(i32, types_n);
    errdefer if (offsets.len > 0) alloc.free(offsets);
    for (0..types_n) |i| {
        offsets[i] = std.mem.readInt(i32, bytes[pos + i * 6 ..][0..4], .big);
    }

    var zone = Zone{ .trans_times = times, .trans_types = ttypes, .offsets = offsets };
    zone.default_off = if (types_n == 0) 0 else offsets[0];
    for (0..types_n) |i| {
        if (bytes[pos + i * 6 + 4] == 0) {
            zone.default_off = offsets[i];
            break;
        }
    }
    return zone;
}

/// Max zones cached per session; the working list is far smaller.
pub const max_cached = 40;
const max_file = 1 << 22;

/// A path-safe zone id for `/usr/share/zoneinfo`, or null when it is empty,
/// absolute, contains `..` or has characters a zone id never has.
pub fn zonePath(buf: []u8, id: []const u8) ?[]const u8 {
    if (id.len == 0 or id.len > 128) return null;
    if (id[0] == '/') return null;
    if (std.mem.indexOf(u8, id, "..") != null) return null;
    var prev_slash = true;
    for (id) |ch| {
        const ok = switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '+', '-', '.', '/' => true,
            else => false,
        };
        if (!ok) return null;
        if (ch == '/' and prev_slash) return null;
        prev_slash = ch == '/';
    }
    const prefix = "/usr/share/zoneinfo/";
    if (prefix.len + id.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..id.len], id);
    return buf[0 .. prefix.len + id.len];
}

/// Parsed-zone cache plus the local zone. One store per clock session.
pub const Store = struct {
    const Entry = struct {
        name: []u8,
        arena: std.heap.ArenaAllocator,
        zone: Zone,
    };

    gpa: std.mem.Allocator,
    io: std.Io,

    entries: [max_cached]Entry = undefined,
    n: usize = 0,

    local: ?Zone = null,
    local_tried: bool = false,
    local_id_buf: [160]u8 = undefined,
    local_id_len: usize = 0,
    local_id_tried: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Store {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Store) void {
        for (0..self.n) |i| {
            self.entries[i].arena.deinit();
        }
        self.n = 0;
        if (self.local) |*z| z.deinit(self.gpa);
        self.local = null;
        self.local_tried = false;
        self.local_id_tried = false;
        self.local_id_len = 0;
    }

    fn findEntry(self: *Store, id: []const u8) ?*Entry {
        for (0..self.n) |i| {
            if (std.mem.eql(u8, self.entries[i].name, id)) return &self.entries[i];
        }
        return null;
    }

    /// The offset of `id` at `epoch`. An empty id is the local zone; an
    /// unknown id falls back to the local offset so a stale stored zone
    /// still paints something sane.
    pub fn zoneOffset(self: *Store, id: []const u8, epoch: i64) i32 {
        if (id.len == 0) return self.localOffset(epoch);
        if (self.findEntry(id)) |e| return e.zone.offsetAt(epoch);
        var pathbuf: [256]u8 = undefined;
        const path = zonePath(&pathbuf, id) orelse return self.localOffset(epoch);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(max_file)) catch
            return self.localOffset(epoch);
        defer self.gpa.free(bytes);
        if (self.n == max_cached) {
            // Cache full (never in practice): answer without keeping it.
            var z = parseZone(self.gpa, bytes) catch return self.localOffset(epoch);
            defer z.deinit(self.gpa);
            return z.offsetAt(epoch);
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = arena.allocator();
        const name = a.dupe(u8, id) catch {
            arena.deinit();
            return self.localOffset(epoch);
        };
        const zone = parseZone(a, bytes) catch {
            arena.deinit();
            return self.localOffset(epoch);
        };
        self.entries[self.n] = .{ .name = name, .arena = arena, .zone = zone };
        self.n += 1;
        return zone.offsetAt(epoch);
    }

    /// Does the database know this zone id?
    pub fn zoneKnown(self: *Store, id: []const u8) bool {
        if (id.len == 0) return false;
        if (self.findEntry(id) != null) return true;
        var pathbuf: [256]u8 = undefined;
        const path = zonePath(&pathbuf, id) orelse return false;
        _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return true;
    }

    fn ensureLocal(self: *Store) void {
        if (self.local_tried) return;
        self.local_tried = true;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, "/etc/localtime", self.gpa, .limited(max_file)) catch return;
        defer self.gpa.free(bytes);
        self.local = parseZone(self.gpa, bytes) catch null;
    }

    pub fn localOffset(self: *Store, epoch: i64) i32 {
        self.ensureLocal();
        if (self.local) |z| return z.offsetAt(epoch);
        return 0; // UTC
    }

    /// The IANA id of the local zone (`TZ` env → `/etc/localtime` symlink →
    /// `/etc/timezone`), or "" when it cannot be told. Used only for display
    /// names and de-duplication, so "" is a safe answer.
    pub fn localId(self: *Store) []const u8 {
        if (self.local_id_tried) return self.local_id_buf[0..self.local_id_len];
        self.local_id_tried = true;

        if (std.c.getenv("TZ")) |tzz| {
            const tz = std.mem.span(tzz);
            if (idFromZoneTarget(tz, &self.local_id_buf)) |id| {
                self.local_id_len = id.len;
                return self.local_id_buf[0..self.local_id_len];
            }
        }
        var link_buf: [512]u8 = undefined;
        if (std.Io.Dir.cwd().readLink(self.io, "/etc/localtime", &link_buf)) |len| {
            if (len > 0) {
                if (idFromZoneTarget(link_buf[0..len], &self.local_id_buf)) |id| {
                    self.local_id_len = id.len;
                    return self.local_id_buf[0..self.local_id_len];
                }
            }
        } else |_| {}
        const tz_file = std.Io.Dir.cwd().readFileAlloc(self.io, "/etc/timezone", self.gpa, .limited(4096)) catch {
            return self.local_id_buf[0..self.local_id_len];
        };
        defer self.gpa.free(tz_file);
        const trimmed = std.mem.trim(u8, tz_file, " \t\r\n");
        if (idFromZoneTarget(trimmed, &self.local_id_buf)) |id| {
            self.local_id_len = id.len;
        }
        return self.local_id_buf[0..self.local_id_len];
    }
};

/// Extract a zone id from a TZ value or symlink target: either a path under
/// a `zoneinfo/` directory (absolute or relative) or a bare dotted name.
fn idFromZoneTarget(target_in: []const u8, out: []u8) ?[]const u8 {
    var target = target_in;
    if (target.len > 0 and target[0] == ':') target = target[1..];
    if (target.len == 0 or target.len > 128) return null;
    if (std.mem.indexOf(u8, target, "zoneinfo/")) |at| {
        target = target[at + "zoneinfo/".len ..];
    } else if (target[0] == '/' or std.mem.startsWith(u8, target, ".")) {
        return null;
    }
    var prev_slash = true;
    var has_slash = false;
    for (target) |ch| {
        const ok = switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '+', '-', '.', '/' => true,
            else => false,
        };
        if (!ok) return null;
        if (ch == '/' and prev_slash) return null;
        if (ch == '/') has_slash = true;
        prev_slash = ch == '/';
    }
    if (!has_slash or target.len > out.len) return null;
    @memcpy(out[0..target.len], target);
    return out[0..target.len];
}

// Tests

test "tzdata: civil from epoch" {
    const t = std.testing;
    const a = civilFromEpoch(0);
    try t.expectEqual(@as(i32, 1970), a.y);
    try t.expectEqual(@as(u32, 1), a.mo);
    try t.expectEqual(@as(u32, 1), a.d);
    try t.expectEqual(@as(u32, 4), a.wday); // Thursday

    // 2026-10-18 00:00:00 UTC is a Sunday.
    const b = civilFromEpoch(1792281600);
    try t.expectEqual(@as(i32, 2026), b.y);
    try t.expectEqual(@as(u32, 10), b.mo);
    try t.expectEqual(@as(u32, 18), b.d);
    try t.expectEqual(@as(u32, 0), b.wday);

    // Negative epochs land before 1970 without wrapping.
    const c = civilFromEpoch(-1);
    try t.expectEqual(@as(i32, 1969), c.y);
    try t.expectEqual(@as(u32, 12), c.mo);
    try t.expectEqual(@as(u32, 31), c.d);
    try t.expectEqual(@as(u32, 23), c.h);
}

test "tzdata: days from civil round-trips" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try t.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    const d = daysFromCivil(2026, 10, 18);
    const c = civilFromEpoch(d * 86400);
    try t.expectEqual(@as(i32, 2026), c.y);
    try t.expectEqual(@as(u32, 10), c.mo);
    try t.expectEqual(@as(u32, 18), c.d);
}

fn putU32Be(b: []u8, v: u32) void {
    std.mem.writeInt(u32, b[0..4], v, .big);
}

/// One-block (v1) TZif: two transitions, UTC then +1h DST.
fn testTzif(alloc: std.mem.Allocator) ![]u8 {
    var buf: [44 + 2 * 4 + 2 + 2 * 6 + 4]u8 = undefined;
    @memcpy(buf[0..4], "TZif");
    buf[4] = 0;
    @memset(buf[5..20], 0);
    putU32Be(buf[20..24], 0); // isutcnt
    putU32Be(buf[24..28], 0); // isstdcnt
    putU32Be(buf[28..32], 0); // leapcnt
    putU32Be(buf[32..36], 2); // timecnt
    putU32Be(buf[36..40], 2); // typecnt
    putU32Be(buf[40..44], 4); // charcnt
    var pos: usize = 44;
    std.mem.writeInt(i32, buf[pos..][0..4], 0, .big);
    pos += 4;
    std.mem.writeInt(i32, buf[pos..][0..4], 3600, .big);
    pos += 4;
    buf[pos] = 0;
    buf[pos + 1] = 1;
    pos += 2;
    // ttinfo: offset 0 (std), offset 3600 (dst)
    std.mem.writeInt(i32, buf[pos..][0..4], 0, .big);
    buf[pos + 4] = 0;
    buf[pos + 5] = 0;
    pos += 6;
    std.mem.writeInt(i32, buf[pos..][0..4], 3600, .big);
    buf[pos + 4] = 1;
    buf[pos + 5] = 1;
    pos += 6;
    @memcpy(buf[pos..][0..4], "UTC\x00");
    pos += 4;
    return alloc.dupe(u8, buf[0..pos]);
}

test "tzdata: parse zone and offset lookup" {
    const t = std.testing;
    const bytes = try testTzif(t.allocator);
    defer t.allocator.free(bytes);
    var z = try parseZone(t.allocator, bytes);
    defer z.deinit(t.allocator);
    try t.expectEqual(@as(i32, 0), z.offsetAt(-1));
    try t.expectEqual(@as(i32, 0), z.offsetAt(0));
    try t.expectEqual(@as(i32, 0), z.offsetAt(100)); // still the first type
    try t.expectEqual(@as(i32, 3600), z.offsetAt(3600)); // second transition
    try t.expectEqual(@as(i32, 3600), z.offsetAt(10_000_000));

    // Bad magic and truncated blocks are errors, not crashes.
    try t.expectError(error.BadTzif, parseZone(t.allocator, "TZif"));
    var bad = try t.allocator.dupe(u8, bytes);
    defer t.allocator.free(bad);
    bad[0] = 'X';
    try t.expectError(error.BadTzif, parseZone(t.allocator, bad));
}

test "tzdata: zone path validation" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(zonePath(&buf, "Asia/Tokyo") != null);
    try std.testing.expect(zonePath(&buf, "/etc/passwd") == null);
    try std.testing.expect(zonePath(&buf, "../evil") == null);
    try std.testing.expect(zonePath(&buf, "a//b") == null);
    try std.testing.expect(zonePath(&buf, "weird name") == null);
    try std.testing.expect(zonePath(&buf, "") == null);
}

test "tzdata: system database answers for well-known zones" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    var store = Store.init(t.allocator, threaded.io());
    defer store.deinit();

    // 2026-01-15: London is GMT (+0), Tokyo +9, Sydney +11 (DST).
    const winter = 1768435200;
    const london = store.zoneOffset("Europe/London", winter);
    const tokyo = store.zoneOffset("Asia/Tokyo", winter);
    const sydney = store.zoneOffset("Australia/Sydney", winter);
    try t.expectEqual(@as(i32, 0), london);
    try t.expectEqual(@as(i32, 9 * 3600), tokyo);
    try t.expectEqual(@as(i32, 11 * 3600), sydney);

    // 2026-07-15: London +1h (BST), Sydney +10 (AEST).
    const summer = 1784073600;
    try t.expectEqual(@as(i32, 3600), store.zoneOffset("Europe/London", summer));
    try t.expectEqual(@as(i32, 10 * 3600), store.zoneOffset("Australia/Sydney", summer));

    try t.expect(store.zoneKnown("Asia/Tokyo"));
    try t.expect(!store.zoneKnown("Not/AZone"));

    // Unknown ids fall back without crashing, and "" is the local zone.
    const bogus = store.zoneOffset("Not/AZone", summer);
    const local = store.zoneOffset("", summer);
    try t.expectEqual(local, bogus);
}
