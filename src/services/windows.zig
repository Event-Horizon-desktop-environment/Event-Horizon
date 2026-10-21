const std = @import("std");

pub const topic_created = "toplevel.created";
pub const topic_updated = "toplevel.updated";
pub const topic_closed = "toplevel.closed";
pub const cmd_list = "toplevel.list";

pub const Flag = struct {
    pub const activated: u32 = 1 << 0;
    pub const minimized: u32 = 1 << 1;
    pub const maximized: u32 = 1 << 2;
    pub const fullscreen: u32 = 1 << 3;
};

pub const max_list_records: u64 = 4096;

pub const Record = struct {
    key: []const u8 = "",
    id: u64 = 0,
    app_id: []const u8 = "",
    title: []const u8 = "",
    flags: u32 = 0,
};

pub const DecodeError = error{
    Malformed,
    Overflow,
    TooMany,
    OutOfMemory,
};

fn appendNum(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u64) !void {
    if (v == 0) {
        try out.append(alloc, '0');
        return;
    }
    var buf: [24]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0) : (n += 1) {
        buf[n] = @intCast('0' + (x % 10));
        x /= 10;
    }
    while (n > 0) {
        n -= 1;
        try out.append(alloc, buf[n]);
    }
}

fn parseNum(data: []const u8, pos: *usize, term: u8) DecodeError!u64 {
    if (pos.* >= data.len) return DecodeError.Malformed;
    const start = pos.*;
    var v: u64 = 0;
    while (pos.* < data.len and data[pos.*] != term) : (pos.* += 1) {
        const ch = data[pos.*];
        if (ch < '0' or ch > '9') return DecodeError.Malformed;
        const d: u64 = @intCast(ch - '0');
        if (v > (std.math.maxInt(u64) - d) / 10) return DecodeError.Overflow;
        v = v * 10 + d;
    }
    if (pos.* >= data.len or pos.* == start) return DecodeError.Malformed;
    pos.* += 1;
    return v;
}

pub fn encodeRecord(alloc: std.mem.Allocator, r: Record) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendNum(&out, alloc, r.id);
    try out.append(alloc, ';');
    try appendNum(&out, alloc, r.flags);
    try out.append(alloc, ';');
    try appendNum(&out, alloc, r.app_id.len);
    try out.append(alloc, ';');
    try out.appendSlice(alloc, r.app_id);
    try appendNum(&out, alloc, r.title.len);
    try out.append(alloc, ';');
    try out.appendSlice(alloc, r.title);
    return out.toOwnedSlice(alloc);
}

pub const Decoded = struct {
    record: Record,
    consumed: usize,
};

pub fn decodeRecord(alloc: std.mem.Allocator, data: []const u8, offset: usize) DecodeError!Decoded {
    var pos = offset;
    const id = try parseNum(data, &pos, ';');
    const flags = try parseNum(data, &pos, ';');
    const app_len = try parseNum(data, &pos, ';');
    if (flags > 0xFFFFFFFF) return DecodeError.Malformed;
    if (pos + app_len > data.len) return DecodeError.Malformed;
    const app_id = data[pos .. pos + app_len];
    pos += app_len;
    const title_len = try parseNum(data, &pos, ';');
    if (pos + title_len > data.len) return DecodeError.Malformed;
    const title = data[pos .. pos + title_len];
    pos += title_len;
    const r = Record{
        .id = id,
        .flags = @intCast(flags),
        .app_id = alloc.dupe(u8, app_id) catch return DecodeError.OutOfMemory,
        .title = alloc.dupe(u8, title) catch return DecodeError.OutOfMemory,
    };
    errdefer {
        alloc.free(r.app_id);
        alloc.free(r.title);
    }
    return .{ .record = r, .consumed = pos - offset };
}

pub fn freeRecord(alloc: std.mem.Allocator, r: *Record) void {
    if (r.app_id.len > 0) alloc.free(r.app_id);
    if (r.title.len > 0) alloc.free(r.title);
    r.* = .{};
}

pub fn encodeList(alloc: std.mem.Allocator, list: []const Record) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendNum(&out, alloc, list.len);
    try out.append(alloc, '\n');
    for (list) |r| {
        const enc = try encodeRecord(alloc, r);
        defer alloc.free(enc);
        try out.appendSlice(alloc, enc);
    }
    return out.toOwnedSlice(alloc);
}

pub fn decodeList(alloc: std.mem.Allocator, data: []const u8) DecodeError![]Record {
    var pos: usize = 0;
    const count = try parseNum(data, &pos, '\n');
    if (count > max_list_records) return DecodeError.TooMany;
    var out: std.ArrayList(Record) = .empty;
    errdefer {
        for (out.items) |*r| freeRecord(alloc, r);
        out.deinit(alloc);
    }
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const d = try decodeRecord(alloc, data, pos);
        pos += d.consumed;
        try out.append(alloc, d.record);
    }
    return out.toOwnedSlice(alloc);
}

test "windows: record round trip with hostile strings" {
    const t = std.testing;
    const recs = [_]Record{
        .{ .id = 7, .flags = Flag.activated | Flag.maximized, .app_id = "org.firefox", .title = "tab\twith\nnewline" },
        .{ .id = std.math.maxInt(u64), .flags = 0xFFFFFFFF, .app_id = "", .title = "" },
    };
    const enc = try encodeList(t.allocator, &recs);
    defer t.allocator.free(enc);
    const dec = try decodeList(t.allocator, enc);
    defer {
        for (dec) |*r| freeRecord(t.allocator, r);
        t.allocator.free(dec);
    }
    try t.expectEqual(@as(usize, 2), dec.len);
    try t.expectEqual(recs[0].id, dec[0].id);
    try t.expectEqual(recs[0].flags, dec[0].flags);
    try t.expectEqualStrings(recs[0].app_id, dec[0].app_id);
    try t.expectEqualStrings(recs[0].title, dec[0].title);
    try t.expectEqual(recs[1].id, dec[1].id);
    try t.expectEqual(recs[1].flags, dec[1].flags);
}

test "windows: malformed inputs rejected" {
    const t = std.testing;
    try t.expectError(DecodeError.Malformed, decodeList(t.allocator, ""));
    try t.expectError(DecodeError.Malformed, decodeList(t.allocator, "2\n1;0;1;a"));
    try t.expectError(DecodeError.Overflow, decodeList(t.allocator, "99999999999999999999999\n"));
    try t.expectError(DecodeError.TooMany, decodeList(t.allocator, "5000\n"));
    var pos: usize = 0;
    try t.expectError(DecodeError.Malformed, parseNum("12x", &pos, ';'));
}

pub const Snapshot = struct {
    alloc: std.mem.Allocator,
    records: std.ArrayList(Record),
    next_id: u64 = 1,

    pub fn init(alloc: std.mem.Allocator) Snapshot {
        return .{ .alloc = alloc, .records = .empty };
    }

    pub fn deinit(self: *Snapshot) void {
        for (self.records.items) |*r| {
            self.alloc.free(r.key);
            freeRecord(self.alloc, r);
        }
        self.records.deinit(self.alloc);
    }

    pub fn upsert(self: *Snapshot, key: []const u8, app_id: []const u8, title: []const u8, flags: u32) !u64 {
        for (self.records.items) |*r| {
            if (std.mem.eql(u8, r.key, key)) {
                if (!std.mem.eql(u8, r.app_id, app_id)) {
                    self.alloc.free(r.app_id);
                    r.app_id = try self.alloc.dupe(u8, app_id);
                }
                if (!std.mem.eql(u8, r.title, title)) {
                    self.alloc.free(r.title);
                    r.title = try self.alloc.dupe(u8, title);
                }
                r.flags = flags;
                return r.id;
            }
        }
        const id = self.next_id;
        self.next_id += 1;
        try self.records.append(self.alloc, .{
            .key = try self.alloc.dupe(u8, key),
            .id = id,
            .app_id = try self.alloc.dupe(u8, app_id),
            .title = try self.alloc.dupe(u8, title),
            .flags = flags,
        });
        return id;
    }

    pub fn remove(self: *Snapshot, key: []const u8) bool {
        for (self.records.items, 0..) |*r, i| {
            if (std.mem.eql(u8, r.key, key)) {
                self.alloc.free(r.key);
                freeRecord(self.alloc, r);
                _ = self.records.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn encodeAll(self: *Snapshot) ![]u8 {
        return encodeList(self.alloc, self.records.items);
    }
};

test "windows: snapshot upsert/remove/encode" {
    const t = std.testing;
    var s = Snapshot.init(t.allocator);
    defer s.deinit();
    const id1 = try s.upsert("k1", "firefox", "Tab 1", Flag.activated);
    const id2 = try s.upsert("k1", "firefox", "Tab 2", Flag.activated | Flag.maximized);
    try t.expectEqual(id1, id2);
    try t.expectEqual(@as(usize, 1), s.records.items.len);
    try t.expectEqualStrings("Tab 2", s.records.items[0].title);
    try t.expect(s.remove("k1"));
    try t.expect(!s.remove("k1"));
    const enc = try s.encodeAll();
    defer t.allocator.free(enc);
    try t.expectEqualStrings("0\n", enc);
}
