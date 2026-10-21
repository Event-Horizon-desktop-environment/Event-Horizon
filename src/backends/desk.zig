const std = @import("std");

/// Value types shared by every workspace backend; strings are
/// borrowed from whatever produced the region, except where a helper says
/// otherwise.
/// Change notification: a function pointer
/// plus its context. Nothing behind it captures state, so a record is all it
/// ever needed. Shared, because every backend registers the same shape.
pub const Notify = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque) void,

    pub fn run(self: Notify) void {
        self.call(self.ctx);
    }
};

pub const TaskbarMode = enum { generic, workspace_occurrence_title };

/// `IOutputNameLookup::Resolver`: an opaque output handle → the compositor's
/// name for it. The handle is `?*anyopaque` so no backend has to know what a
/// `wl_output` is, and the returned slice is borrowed from whatever the
/// resolver stored — it only has to outlive the call. Shared, because Hyprland
/// and mango both install one and neither owns the idea.
pub const Resolver = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, output: ?*anyopaque) []const u8,

    pub fn name(self: Resolver, output: ?*anyopaque) []const u8 {
        return self.call(self.ctx, output);
    }
};

pub const Region = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    coordinates: []const u32 = &.{},
    index: u32 = 0,
    active: bool = false,
    urgent: bool = false,
    occupied: bool = false,
};

pub const Win = struct {
    window_id: []const u8 = "",
    desk_key: []const u8 = "",
    app_id: []const u8 = "",
    title: []const u8 = "",
    x: i32 = 0,
    y: i32 = 0,
};

pub const TaskbarEntry = struct {
    handle_key: usize = 0,
    app_ids: []const []const u8 = &.{},
    title: []const u8 = "",
};

/// Deep copy of a region: `allRegions`/`regionsOnOutput` hand back values the
/// caller owns outright, including every string inside.
pub fn dupRegion(alloc: std.mem.Allocator, r: Region) !Region {
    var out = r;
    out.id = try alloc.dupe(u8, r.id);
    errdefer alloc.free(out.id);
    out.name = try alloc.dupe(u8, r.name);
    errdefer alloc.free(out.name);
    out.coordinates = try alloc.dupe(u32, r.coordinates);
    return out;
}

pub fn freeRegionList(alloc: std.mem.Allocator, list: []Region) void {
    freeRegionElems(alloc, list);
    alloc.free(list);
}

/// Frees a region's strings but not the slot it sits in — used while a list is
/// still being built by an `errdefer` (the backing array is not owned yet).
pub fn freeRegionElems(alloc: std.mem.Allocator, list: []Region) void {
    for (list) |r| freeRegion(alloc, r);
}

/// Frees one region's strings. For the values that live in a map rather than a
/// list — `ext_workspace` keeps its regions keyed by handle.
pub fn freeRegion(alloc: std.mem.Allocator, r: Region) void {
    alloc.free(r.id);
    alloc.free(r.name);
    alloc.free(r.coordinates);
}

/// Replaces `*slot` with a deep copy of `list`, freeing whatever was there.
/// The region lists are rebuilt on every state change, so the old ones have to
/// go before the new ones land.
pub fn replaceRegions(alloc: std.mem.Allocator, slot: *[]Region, list: []const Region) !void {
    var fresh: std.ArrayList(Region) = .empty;
    errdefer {
        freeRegionElems(alloc, fresh.items);
        fresh.deinit(alloc);
    }
    for (list) |r| try fresh.append(alloc, try dupRegion(alloc, r));
    freeRegionList(alloc, slot.*);
    slot.* = try fresh.toOwnedSlice(alloc);
}

/// Frees one window row's strings. The rows `windowsOnDesk` hands back are
/// owned copies — of the ids, the desk key and both text fields — so they need
/// the same treatment a region gets.
pub fn freeWin(alloc: std.mem.Allocator, w: Win) void {
    alloc.free(w.window_id);
    alloc.free(w.desk_key);
    alloc.free(w.app_id);
    alloc.free(w.title);
}

/// Frees every row's strings but not the slot it sits in — used while a list is
/// still being built by an `errdefer`.
pub fn freeWinElems(alloc: std.mem.Allocator, list: []Win) void {
    for (list) |w| freeWin(alloc, w);
}

/// Frees a window list whole: the rows, then the backing array.
pub fn freeWinList(alloc: std.mem.Allocator, list: []Win) void {
    freeWinElems(alloc, list);
    alloc.free(list);
}

/// deskKey -> app ids, the shape `appsByDesk` hands back everywhere. Keys *and*
/// app ids are owned: a backend that returned borrowed slices would hand back
/// pointers into a window table that the next state change frees underneath the
/// caller, so every map hands back copies.
pub const AppMap = std.StringHashMap(std.ArrayList([]const u8));

pub fn freeAppMap(alloc: std.mem.Allocator, map: *AppMap) void {
    var it = map.iterator();
    while (it.next()) |e| {
        alloc.free(e.key_ptr.*);
        for (e.value_ptr.*.items) |app| alloc.free(app);
        e.value_ptr.*.deinit(alloc);
    }
    map.deinit();
}

/// Lexicographic `u32` comparison: element by element, shorter-is-less on a shared prefix.
pub fn coordLess(a: []const u32, b: []const u32) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (x != y) return x < y;
    }
    return a.len < b.len;
}

/// Drops trailing zeroes (coordinates arrive as `[N,0,0]` for a flat workspace list).
pub fn trimZeros(coords: []const u32) []const u32 {
    var end = coords.len;
    while (end > 0 and coords[end - 1] == 0) end -= 1;
    return coords[0..end];
}

/// Compares trimmed coordinate vectors.
pub fn trimmedCoordLess(a: []const u32, b: []const u32) bool {
    return coordLess(trimZeros(a), trimZeros(b));
}

// JSON field access with defaults: a missing key or a wrong-typed value
// yields the default, so a hostile or partially-typed payload degrades
// instead of throwing.

pub fn jsonStr(o: std.json.Value, key: []const u8) []const u8 {
    if (o != .object) return "";
    const v = o.object.get(key) orelse return "";
    if (v != .string) return "";
    return v.string;
}

pub fn jsonInt(o: std.json.Value, key: []const u8, comptime T: type, dflt: T) T {
    if (o != .object) return dflt;
    const v = o.object.get(key) orelse return dflt;
    return switch (v) {
        .integer => |i| if (i >= std.math.minInt(T) and i <= std.math.maxInt(T)) @intCast(i) else dflt,
        // A number too large for i64 lands here; treat it as out of range.
        .number_string => dflt,
        else => dflt,
    };
}

pub fn jsonBoolOr(o: std.json.Value, key: []const u8, dflt: bool) bool {
    if (o != .object) return dflt;
    const v = o.object.get(key) orelse return dflt;
    if (v != .bool) return dflt;
    return v.bool;
}

/// Finds the object holding a window/window-like payload: either the object
/// itself under `key`, or a bare object carrying an `id`.
pub fn jsonObj(o: std.json.Value, key: []const u8) ?std.json.Value {
    if (o == .object) {
        if (o.object.get(key)) |inner| {
            if (inner == .object) return inner;
            return null;
        }
        if (o.object.contains("id")) return o;
    }
    return null;
}

/// Returns the array at `key`, or the value itself when it already is one.
pub fn jsonArr(o: std.json.Value, key: []const u8) ?std.json.Array {
    if (o == .array) return o.array;
    if (o != .object) return null;
    const v = o.object.get(key) orelse return null;
    if (v != .array) return null;
    return v.array;
}

pub fn u64FromJson(v: std.json.Value) ?u64 {
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// Collapses a window title onto a single line: runs of whitespace become one
/// space and the result is trimmed.
pub fn titleOneLine(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and isGap(text[i])) i += 1;
        if (i == text.len) break;
        const word = i;
        while (i < text.len and !isGap(text[i])) i += 1;
        if (out.items.len > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, text[word..i]);
    }
    return out.toOwnedSlice(alloc);
}

fn isGap(ch: u8) bool {
    return switch (ch) {
        // space, LF, CR, tab, vertical tab, form feed — the whitespace set
        // `titleOneLine` collapses.
        ' ', '\n', '\r', '\t', 0x0b, 0x0c => true,
        else => std.ascii.isWhitespace(ch),
    };
}

test "desk: coordinate ordering and zero trimming" {
    const t = std.testing;
    try t.expect(coordLess(&.{ 1, 2 }, &.{ 1, 3 }));
    try t.expect(coordLess(&.{1}, &.{ 1, 0 }));
    try t.expect(!coordLess(&.{ 2 }, &.{ 1, 9 }));
    try t.expect(trimZeros(&.{ 2, 0, 0 }).len == 1);
    try t.expect(trimZeros(&.{ 0, 0 }).len == 0);
    try t.expect(trimmedCoordLess(&.{ 1, 0 }, &.{ 2, 0 }));
    try t.expect(!trimmedCoordLess(&.{ 0 }, &.{ 0 }));
}

test "desk: tolerant JSON field reads" {
    const t = std.testing;
    const doc =
        \\{"id":7,"name":"dev","monitor":"DP-1","urgent":true,"windows":"nope"}
    ;
    const p = try std.json.parseFromSlice(std.json.Value, t.allocator, doc, .{});
    defer p.deinit();
    const o = p.value;
    try t.expectEqualStrings("dev", jsonStr(o, "name"));
    try t.expectEqualStrings("", jsonStr(o, "missing"));
    try t.expectEqual(@as(i64, 7), jsonInt(o, "id", i64, -1));
    try t.expectEqual(@as(i64, -1), jsonInt(o, "windows", i64, -1));
    try t.expect(jsonBoolOr(o, "urgent", false));
    try t.expect(!jsonBoolOr(o, "missing", false));
    // `asObject` semantics: a bare object carrying `id` is its own container,
    // so a missing key still resolves.
    try t.expectEqualStrings("dev", jsonStr(jsonObj(o, "nested").?, "name"));
}

test "desk: title collapses to one line" {
    const t = std.testing;
    const s = try titleOneLine(t.allocator, "  hello\n\tworld  ");
    defer t.allocator.free(s);
    try t.expectEqualStrings("hello world", s);
    const empty = try titleOneLine(t.allocator, "   \n ");
    defer t.allocator.free(empty);
    try t.expectEqualStrings("", empty);
}

test "desk: region deep copy and replace" {
    const t = std.testing;
    const coords = [_]u32{ 1, 0 };
    const src = [_]Region{
        .{ .id = "1", .name = "one", .coordinates = &coords, .index = 1, .active = true },
        .{ .id = "2", .name = "two" },
    };
    var slot: []Region = try dupRegionList(t.allocator, &src);
    defer freeRegionList(t.allocator, slot);
    try t.expectEqual(@as(usize, 2), slot.len);
    try t.expectEqualStrings("one", slot[0].name);
    try t.expectEqual(@as(u32, 1), slot[0].coordinates[0]);

    // Replacing must free the previous copy; LeakSanitizer enforces it.
    const fresh = [_]Region{.{ .id = "9", .name = "nine" }};
    try replaceRegions(t.allocator, &slot, &fresh);
    try t.expectEqual(@as(usize, 1), slot.len);
    try t.expectEqualStrings("nine", slot[0].name);
}

pub fn dupRegionList(alloc: std.mem.Allocator, list: []const Region) ![]Region {
    var out: std.ArrayList(Region) = .empty;
    errdefer {
        freeRegionElems(alloc, out.items);
        out.deinit(alloc);
    }
    for (list) |r| try out.append(alloc, try dupRegion(alloc, r));
    return out.toOwnedSlice(alloc);
}
