//! mango workspace state: the two tables the `watch all-monitors` stream feeds
//! and the JSON probes that read a payload without trusting it.
//!
//! Socket-free decoding and ownership half, split out so the
//! decoding and the ownership rules can be pinned by tests with no compositor
//! anywhere near them. `mango_ws_events.zig` mutates these tables,
//! `mango_ws_query.zig` reads them back out for the interface.
//!
//! The shared JSON helpers
//! `desk.jsonStr`/`desk.jsonBoolOr`/`desk.jsonArr` cover the common probes; `intField` and
//! `tagArray` are mango-specific and are written out below.

const std = @import("std");
const desk = @import("desk.zig");

/// `strField`: absent key or a non-string value reads as `""`.
pub const strField = desk.jsonStr;

/// `intField`: absent key or a value outside `int32` reads as `0`. Unsigned
/// payloads widen without wrapping,
/// which wrapped instead; mango's payload is monitor geometry and tag numbers,
/// so wrapping would only turn a broken reading into a different broken one.
pub fn intField(o: std.json.Value, key: []const u8) i32 {
    return desk.jsonInt(o, key, i32, 0);
}

/// `boolField`: only a real `true` counts.
pub const boolField = desk.jsonBoolOr;

/// One `tags[]` entry of a monitor.
pub const Tag = struct {
    index: u32 = 0,
    active: bool = false,
    urgent: bool = false,
    occupied: bool = false,
    /// Derived rather than decoded: the tag the focused client sits on.
    focused: bool = false,
};

/// One monitor, as `watch all-monitors` described it. Strings are owned by the
/// `Tables` holding it; `name` doubles as the table's key, so it is freed once
/// through the value and never through the key.
pub const Out = struct {
    name: []const u8 = "",
    active: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    client_title: []const u8 = "",
    client_app_id: []const u8 = "",
    tags: []const Tag = &.{},
};

/// One row of `get all-clients`. A client on several tags appears once here
/// and once per tag wherever the caller asks per-tag.
pub const Client = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    app_id: []const u8 = "",
    out_name: []const u8 = "",
    tags: []const u32 = &.{},
    focused: bool = false,
    x: i32 = 0,
    y: i32 = 0,
};

/// Monitor name -> that monitor. Insertion-ordered, so `allRegions` and
/// `selectedOutput` walk the event's own order — same members, one
/// repeatable answer.
pub const OutMap = std.array_hash_map.String(Out);

pub const Tables = struct {
    alloc: std.mem.Allocator,
    outputs: OutMap = .empty,
    clients: std.ArrayList(Client) = .empty,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
        self.outputs.deinit(self.alloc);
        self.clients.deinit(self.alloc);
    }

    /// Leaves nothing for the next session to find.
    pub fn clear(self: *Self) void {
        var it = self.outputs.iterator();
        while (it.next()) |e| freeOut(self.alloc, e.value_ptr.*);
        self.outputs.clearRetainingCapacity();
        freeClientList(self.alloc, &self.clients);
    }

    /// Takes the monitor table wholesale: the caller built it, compared it,
    /// then hands it over so the old rows are freed exactly once. After this
    /// `next` is empty, which is why the caller's cleanup of `next` is safe to
    /// run unconditionally.
    pub fn adoptOutputs(self: *Self, next: *OutMap) void {
        var it = self.outputs.iterator();
        while (it.next()) |e| freeOut(self.alloc, e.value_ptr.*);
        self.outputs.deinit(self.alloc);
        self.outputs = next.*;
        next.* = .empty;
    }

    pub fn adoptClients(self: *Self, next: *std.ArrayList(Client)) void {
        freeClientList(self.alloc, &self.clients);
        // `freeClientList` deliberately keeps the buffer for the next batch a
        // `clear` leaves behind; overwriting the field here would strand it.
        self.clients.deinit(self.alloc);
        self.clients = next.*;
        next.* = .empty;
    }

    pub fn byName(self: *const Self, name: []const u8) ?*const Out {
        return self.outputs.getPtr(name);
    }

    /// The monitor the shell should treat as the front one: the first that
    /// says it is active, else simply the first in the event, else nothing.
    pub fn currentOutput(self: *const Self) ?*const Out {
        const vals = self.outputs.values();
        for (vals) |*out| {
            if (out.active) return out;
        }
        if (vals.len == 0) return null;
        return &vals[0];
    }
};

// Ownership

/// Every string in these tables comes from `dupe`, never from a literal, so
/// the empty-string early return in `free` is the only special case worth
/// spelling out.
pub fn freeStr(alloc: std.mem.Allocator, s: []const u8) void {
    if (s.len != 0) alloc.free(s);
}

pub fn freeOut(alloc: std.mem.Allocator, out: Out) void {
    freeStr(alloc, out.name);
    freeStr(alloc, out.client_title);
    freeStr(alloc, out.client_app_id);
    alloc.free(out.tags);
}

pub fn freeClient(alloc: std.mem.Allocator, c: Client) void {
    freeStr(alloc, c.id);
    freeStr(alloc, c.title);
    freeStr(alloc, c.app_id);
    freeStr(alloc, c.out_name);
    alloc.free(c.tags);
}

/// Frees every row of a map that never made it into the tables — a parse that
/// failed halfway through an array has to give back what it already built.
pub fn freeOutMap(alloc: std.mem.Allocator, map: *OutMap) void {
    var it = map.iterator();
    while (it.next()) |e| freeOut(alloc, e.value_ptr.*);
    map.deinit(alloc);
    map.* = .empty;
}

pub fn freeClientList(alloc: std.mem.Allocator, list: *std.ArrayList(Client)) void {
    for (list.items) |c| freeClient(alloc, c);
    list.clearRetainingCapacity();
}

// Decoding

/// Installs `out` under its own name, keeping the
/// first monitor to claim a name and dropped the rest, so a duplicated name
/// hands its row straight back rather than overwriting what is there.
pub fn putOut(alloc: std.mem.Allocator, map: *OutMap, out: Out) void {
    const gop = map.getOrPut(alloc, out.name) catch {
        freeOut(alloc, out);
        return;
    };
    if (gop.found_existing) {
        freeOut(alloc, out);
        return;
    }
    gop.key_ptr.* = out.name;
    gop.value_ptr.* = out;
}

/// One `tags[]` entry list. Missing or non-array reads as empty;
/// a non-object element is skipped rather than counted.
pub fn parseTags(alloc: std.mem.Allocator, items: []const std.json.Value) ?[]const Tag {
    var list: std.ArrayList(Tag) = .empty;
    defer list.deinit(alloc);
    for (items) |it| {
        if (it != .object) continue;
        list.append(alloc, .{
            .index = @bitCast(intField(it, "index")),
            .active = boolField(it, "is_active", false),
            .urgent = boolField(it, "is_urgent", false),
            .occupied = intField(it, "client_count") > 0,
        }) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// One `active_tags`/`tags` list of tag numbers. Unsigned payloads truncate and
/// a signed one that is not positive is thrown away, so
/// signed one that was not positive, so a literal `0` is kept as `0` and `-1`
/// never lands.
pub fn tagArray(alloc: std.mem.Allocator, o: std.json.Value, key: []const u8) ?[]const u32 {
    const arr = desk.jsonArr(o, key) orelse return &.{};
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(alloc);
    for (arr.items) |item| {
        const n = switch (item) {
            .integer => |v| v,
            else => continue,
        };
        if (n < 0) continue;
        list.append(alloc, @truncate(@as(u64, @intCast(n)))) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// One monitor entry. Returns `null` when the entry is not an object or has
/// no name — a monitor nobody can address is not a monitor worth keeping.
pub fn decodeMonitor(alloc: std.mem.Allocator, j: std.json.Value) ?Out {
    if (j != .object) return null;
    const raw_name = strField(j, "name");
    if (raw_name.len == 0) return null;

    var out: Out = .{
        .active = boolField(j, "active", false),
        .x = intField(j, "x"),
        .y = intField(j, "y"),
        .width = intField(j, "width"),
        .height = intField(j, "height"),
    };
    // From here on every early return has to give the row back; the flag is
    // what separates "built" from "still mine".
    var keep = false;
    defer if (!keep) freeOut(alloc, out);

    out.name = alloc.dupe(u8, raw_name) catch return null;

    var ac: ?std.json.Value = null;
    if (j.object.get("active_client")) |v| {
        if (v == .object) ac = v;
    }
    if (ac) |client| {
        out.client_title = alloc.dupe(u8, strField(client, "title")) catch return null;
        out.client_app_id = alloc.dupe(u8, strField(client, "appid")) catch return null;
    }

    if (j.object.get("tags")) |tg| {
        if (tg == .array) {
            out.tags = parseTags(alloc, tg.array.items) orelse return null;
        }
    }
    // The field is declared `[]const Tag` so the "no tags" default can be a
    // literal; these two passes are the only writers, and they own the row
    // until `keep` says otherwise.
    const tags: []Tag = @constCast(out.tags);

    // `active_tags` supersedes each tag's own `is_active`, unless it is absent
    // or carries no selection: mango reports "nothing selected" as a lone
    // zero entry, which leaves the per-tag flags alone.
    if (tagArray(alloc, j, "active_tags")) |at| {
        defer if (at.len != 0) alloc.free(at);
        const nothing_selected = at.len == 1 and at[0] == 0;
        if (at.len > 0 and !nothing_selected) {
            for (tags) |*tag| {
                tag.active = std.mem.indexOfScalar(u32, at, tag.index) != null;
            }
        }
    }

    // `focused` is derived, and only from a monitor that actually has a
    // focused client: no client means no tag can be the one it is on.
    for (tags) |*tag| tag.focused = false;
    if (ac != null) {
        for (tags) |*tag| {
            if (tag.active) {
                tag.focused = true;
                break;
            }
        }
    }

    keep = true;
    return out;
}

/// One `clients[]` entry. An absent, non-numeric, non-string, or empty id is
/// dropped — there is nothing to name the row by.
pub fn decodeClient(alloc: std.mem.Allocator, j: std.json.Value) ?Client {
    if (j != .object) return null;

    var num_buf: [24]u8 = undefined;
    var id: []const u8 = "";
    if (j.object.get("id")) |v| {
        switch (v) {
            .integer => |n| id = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch return null,
            .string => |s| id = s,
            else => {},
        }
    }
    if (id.len == 0) return null;

    var c: Client = .{
        .focused = boolField(j, "is_focused", false),
        .x = intField(j, "x"),
        .y = intField(j, "y"),
    };
    var keep = false;
    defer if (!keep) freeClient(alloc, c);

    c.id = alloc.dupe(u8, id) catch return null;
    c.title = alloc.dupe(u8, strField(j, "title")) catch return null;
    c.app_id = alloc.dupe(u8, strField(j, "appid")) catch return null;
    c.out_name = alloc.dupe(u8, strField(j, "monitor")) catch return null;
    c.tags = tagArray(alloc, j, "tags") orelse return null;

    keep = true;
    return c;
}

// Ids

/// mango numbers its tags from 1; the shell counts from 0. `""`, anything
/// `from_chars` would not consume whole, and `0` itself are all "no tag" —
/// which is what keeps a region whose id was never filled in from resolving to
/// tag one.
pub fn parseIdx(id: []const u8) ?usize {
    if (id.len == 0) return null;
    const val = std.fmt.parseInt(usize, id, 10) catch return null;
    if (val == 0) return null;
    return val - 1;
}

/// The zero-based tag a region points at: its coordinate when it has one, else
/// its id, else its name.
pub fn idxFromRegion(ws: desk.Region) ?usize {
    if (ws.coordinates.len != 0) return ws.coordinates[0];
    if (ws.id.len != 0) return parseIdx(ws.id);
    return parseIdx(ws.name);
}

// Tests

const t = std.testing;

const monitors_doc =
    \\{"monitors":[
    \\ {"name":"DP-1","active":true,"x":0,"y":0,"width":2560,"height":1440,
    \\  "active_client":{"title":"Terminal","appid":"otter-term"},
    \\  "tags":[
    \\    {"index":1,"is_active":false,"is_urgent":false,"client_count":2},
    \\    {"index":2,"is_active":true,"is_urgent":true,"client_count":1},
    \\    {"index":3,"is_active":false,"is_urgent":false,"client_count":0}
    \\  ]},
    \\ {"name":"HDMI-A-1","active":false,"x":2560,"y":0,"width":1920,"height":1080,
    \\  "tags":[{"index":1,"is_active":true,"client_count":1}]},
    \\ {"active":true,"tags":[]},
    \\ {"name":"DP-1","active":false,"tags":[]},
    \\ {"name":"","active":true}
    \\]}
;

fn parsedDoc(doc: []const u8) std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, t.allocator, doc, .{}) catch unreachable;
}

test "mango-ws-state: a monitor entry decodes, and one without a name does not" {
    const doc = parsedDoc(monitors_doc);
    defer doc.deinit();
    const arr = doc.value.object.get("monitors").?.array.items;

    const first = decodeMonitor(t.allocator, arr[0]).?;
    defer freeOut(t.allocator, first);
    try t.expectEqualStrings("DP-1", first.name);
    try t.expect(first.active);
    try t.expectEqual(@as(i32, 2560), first.width);
    try t.expectEqualStrings("Terminal", first.client_title);
    try t.expectEqualStrings("otter-term", first.client_app_id);
    try t.expectEqual(@as(usize, 3), first.tags.len);
    try t.expectEqual(@as(u32, 2), first.tags[1].index);
    try t.expect(first.tags[1].active);
    try t.expect(first.tags[1].urgent);
    try t.expect(first.tags[1].occupied);
    try t.expect(!first.tags[2].occupied);
    // No `active_tags`, so `is_active` stands and the focused tag follows the
    // client: tag 2 is the active one, so it is also the focused one.
    try t.expect(!first.tags[0].focused);
    try t.expect(first.tags[1].focused);

    const second = decodeMonitor(t.allocator, arr[1]).?;
    defer freeOut(t.allocator, second);
    try t.expectEqualStrings("HDMI-A-1", second.name);
    try t.expect(!second.active);
    try t.expectEqualStrings("", second.client_title);

    // Not an object, no name, empty name: all three are "not a monitor".
    try t.expect(decodeMonitor(t.allocator, .{ .integer = 4 }) == null);
    try t.expect(decodeMonitor(t.allocator, arr[2]) == null);
    try t.expect(decodeMonitor(t.allocator, arr[4]) == null);

    // A second monitor claiming a name already used is dropped by `putOut`,
    // keeping the first — `emplace` semantics. Decoded afresh so the row
    // belongs to the map and to nothing else.
    var map: OutMap = .empty;
    defer freeOutMap(t.allocator, &map);
    putOut(t.allocator, &map, decodeMonitor(t.allocator, arr[0]).?);
    putOut(t.allocator, &map, decodeMonitor(t.allocator, arr[3]).?);
    try t.expectEqual(@as(usize, 1), map.count());
    try t.expect(map.get("DP-1").?.active);
}

test "mango-ws-state: active_tags overrides is_active, but not for a lone zero" {
    const override_doc =
        \\{"name":"DP-1","active":true,
        \\ "active_client":{"title":"T","appid":"a"},
        \\ "tags":[{"index":1,"is_active":true},{"index":2,"is_active":false},{"index":3,"is_active":false}]}
    ;
    const doc = parsedDoc(override_doc);
    defer doc.deinit();
    const m = decodeMonitor(t.allocator, doc.value).?;
    defer freeOut(t.allocator, m);
    // `active_tags` absent: `is_active` survives untouched.
    try t.expect(m.tags[0].active);
    try t.expect(!m.tags[1].active);
    try t.expect(m.tags[0].focused);

    const zero_doc =
        \\{"name":"DP-1","active":true,"active_tags":[0],
        \\ "tags":[{"index":1,"is_active":true},{"index":2,"is_active":false}]}
    ;
    const zd = parsedDoc(zero_doc);
    defer zd.deinit();
    const z = decodeMonitor(t.allocator, zd.value).?;
    defer freeOut(t.allocator, z);
    // A lone `0` means "nothing selected": the flags stay as they were.
    try t.expect(z.tags[0].active);

    // An explicitly empty list reads as absent.
    const empty_doc =
        \\{"name":"DP-1","active":true,"active_tags":[],
        \\ "tags":[{"index":1,"is_active":true},{"index":2,"is_active":false}]}
    ;
    const ed = parsedDoc(empty_doc);
    defer ed.deinit();
    const e = decodeMonitor(t.allocator, ed.value).?;
    defer freeOut(t.allocator, e);
    try t.expect(e.tags[0].active);
    try t.expect(!e.tags[1].active);

    const sel_doc =
        \\{"name":"DP-1","active":true,"active_client":{"title":"T","appid":"a"},
        \\ "active_tags":[3],
        \\ "tags":[{"index":1,"is_active":true},{"index":2,"is_active":false},{"index":3,"is_active":false}]}
    ;
    const sd = parsedDoc(sel_doc);
    defer sd.deinit();
    const s = decodeMonitor(t.allocator, sd.value).?;
    defer freeOut(t.allocator, s);
    // …and a real list rewrites every flag the payload already carried.
    try t.expect(!s.tags[0].active);
    try t.expect(!s.tags[1].active);
    try t.expect(s.tags[2].active);
    try t.expect(!s.tags[0].focused);
    try t.expect(s.tags[2].focused);

    // Several active tags: focus goes to the first of them, not the last.
    const many_doc =
        \\{"name":"DP-1","active":true,"active_client":{"title":"T","appid":"a"},
        \\ "active_tags":[3,1],
        \\ "tags":[{"index":1,"is_active":false},{"index":2,"is_active":false},{"index":3,"is_active":false}]}
    ;
    const md = parsedDoc(many_doc);
    defer md.deinit();
    const m2 = decodeMonitor(t.allocator, md.value).?;
    defer freeOut(t.allocator, m2);
    try t.expect(m2.tags[0].active);
    try t.expect(m2.tags[2].active);
    try t.expect(m2.tags[0].focused);
    try t.expect(!m2.tags[2].focused);

    // No client at all means no tag can be the one it sits on.
    const alone_doc = "{\"name\":\"DP-1\",\"tags\":[{\"index\":1,\"is_active\":true}]}";
    const ad = parsedDoc(alone_doc);
    defer ad.deinit();
    const a = decodeMonitor(t.allocator, ad.value).?;
    defer freeOut(t.allocator, a);
    try t.expect(a.tags[0].active);
    try t.expect(!a.tags[0].focused);
}

test "mango-ws-state: a client needs an id and keeps only the fields mango sent" {
    const doc = parsedDoc(
        \\{"clients":[
        \\ {"id":17,"title":"One","appid":"foot","monitor":"DP-1","tags":[0,1,3],"is_focused":true,"x":4,"y":8},
        \\ {"id":"0x2f","title":"Two","appid":"ff","monitor":"HDMI-A-1","tags":[-2,2]},
        \\ {"id":-9,"title":"Neg","appid":"n","monitor":"","tags":[]},
        \\ {"title":"no id","tags":[1]},
        \\ {"id":"","title":"empty","tags":[1]},
        \\ 5,
        \\ {"id":7,"title":"nofields"}
        \\]}
    );
    defer doc.deinit();
    const arr = doc.value.object.get("clients").?.array.items;

    const c = decodeClient(t.allocator, arr[0]).?;
    defer freeClient(t.allocator, c);
    try t.expectEqualStrings("17", c.id);
    try t.expectEqualStrings("foot", c.app_id);
    try t.expectEqualStrings("DP-1", c.out_name);
    try t.expect(c.focused);
    try t.expectEqual(@as(i32, 4), c.x);
    // `0` is a real (untagged) entry and stays; the negative one never lands.
    try t.expectEqualSlices(u32, &.{ 0, 1, 3 }, c.tags);

    const s = decodeClient(t.allocator, arr[1]).?;
    defer freeClient(t.allocator, s);
    try t.expectEqualStrings("0x2f", s.id);
    try t.expectEqualSlices(u32, &.{2}, s.tags);

    const n = decodeClient(t.allocator, arr[2]).?;
    defer freeClient(t.allocator, n);
    try t.expectEqualStrings("-9", n.id);

    // No id, empty id, and a non-object: all dropped, none of them crash.
    try t.expect(decodeClient(t.allocator, arr[3]) == null);
    try t.expect(decodeClient(t.allocator, arr[4]) == null);
    try t.expect(decodeClient(t.allocator, arr[5]) == null);
    // A sparse entry still decodes: everything it left out is the default.
    const sparse = decodeClient(t.allocator, arr[6]).?;
    defer freeClient(t.allocator, sparse);
    try t.expectEqualStrings("", sparse.out_name);
    try t.expectEqual(@as(usize, 0), sparse.tags.len);
}

test "mango-ws-state: tag ids are one-based everywhere they leave mango" {
    try t.expectEqual(@as(?usize, 0), parseIdx("1"));
    try t.expectEqual(@as(?usize, 4), parseIdx("005"));
    try t.expect(parseIdx("") == null);
    try t.expect(parseIdx("0") == null);
    try t.expect(parseIdx("-1") == null);
    try t.expect(parseIdx(" 1") == null);
    try t.expect(parseIdx("1 ") == null);
    try t.expect(parseIdx("x") == null);
    try t.expect(parseIdx("12x") == null);

    // The coordinate wins when there is one, and it is already zero-based.
    try t.expectEqual(@as(?usize, 6), idxFromRegion(.{ .coordinates = &[_]u32{6} }));
    try t.expectEqual(@as(?usize, 0), idxFromRegion(.{ .id = "1" }));
    try t.expectEqual(@as(?usize, 2), idxFromRegion(.{ .name = "3" }));
    // An id of `""` falls through to the name; both empty is no tag at all.
    try t.expectEqual(@as(?usize, 4), idxFromRegion(.{ .name = "5" }));
    try t.expect(idxFromRegion(.{}) == null);
    try t.expect(idxFromRegion(.{ .coordinates = &[_]u32{} }) == null);
}

test "mango-ws-state: the tables take a whole new monitor list at once" {
    var tables = Tables.init(t.allocator);
    defer tables.deinit();

    const doc = parsedDoc(monitors_doc);
    defer doc.deinit();
    const arr = doc.value.object.get("monitors").?.array.items;

    var next: OutMap = .empty;
    putOut(t.allocator, &next, decodeMonitor(t.allocator, arr[0]).?);
    putOut(t.allocator, &next, decodeMonitor(t.allocator, arr[1]).?);
    tables.adoptOutputs(&next);
    // The caller's map is emptied by the hand-over, so its cleanup is a no-op
    // rather than a double free.
    defer freeOutMap(t.allocator, &next);
    try t.expectEqual(@as(usize, 2), tables.outputs.count());
    try t.expect(tables.byName("DP-1").?.active);
    try t.expect(tables.currentOutput().?.active);
    try t.expectEqualStrings("DP-1", tables.currentOutput().?.name);

    // A monitor list with nothing active still has a front one: the first.
    tables.outputs.values()[0].active = false;
    tables.outputs.values()[1].active = false;
    try t.expectEqualStrings("DP-1", tables.currentOutput().?.name);

    tables.clear();
    try t.expectEqual(@as(usize, 0), tables.outputs.count());
    try t.expect(tables.currentOutput() == null);
}
