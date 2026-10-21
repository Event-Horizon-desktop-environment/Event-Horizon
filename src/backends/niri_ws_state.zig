//! niri workspace state: the two tables the event stream feeds, their
//! mutations, and the JSON probes that read a payload without trusting it.
//!
//! Socket-free parsing and ownership half, split out so the parsing
//! and the equality rules can be pinned by tests with no compositor anywhere
//! near them. `niri_ws_events.zig` mutates these tables, `niri_ws_query.zig`
//! reads them back out for the interface.
//!
//! The shared JSON helpers live in `desk.zig` (`jsonStr`/`jsonArr`/`jsonObj`
//! and `u64FromJson`). `jsonI32`, `optU64` and
//! `optBool` are niri-specific and are written out below.

const std = @import("std");
const desk = @import("desk.zig");

/// Aliased rather than re-implemented — see the note above.
pub const optStr = desk.jsonStr;
pub const asArray = desk.jsonArr;
pub const asObject = desk.jsonObj;
pub const jsonU64 = desk.u64FromJson;

/// One entry of niri's workspace list. `idx` is a `u8` (narrowed from `u64`); a workspace numbered above
/// 255 therefore wraps, and `claimMatching` has to compare it in wrapped form
/// to keep matching the same rows it used to.
pub const WsState = struct {
    id: u64 = 0,
    idx: u8 = 0,
    name: []const u8 = "",
    output: []const u8 = "",
};

/// One entry of niri's window list. `ws_id` is optional because a window can
/// sit on no workspace at all — niri sends `workspace_id: null` for one that
/// is being closed or is not placed yet.
pub const WinState = struct {
    ws_id: ?u64 = null,
    app_id: []const u8 = "",
    title: []const u8 = "",
    x: i32 = 0,
    y: i32 = 0,
};

pub const WsMap = std.array_hash_map.Auto(u64, WsState);
pub const WinMap = std.array_hash_map.Auto(u64, WinState);
pub const OccMap = std.array_hash_map.Auto(u64, usize);

pub const Tables = struct {
    alloc: std.mem.Allocator,
    workspaces: WsMap = .empty,
    windows: WinMap = .empty,
    /// Window count per workspace id, rebuilt whenever membership moves. The
    /// region `occupied` flag is derived from this and nothing else.
    occupancy: OccMap = .empty,
    known_overview: bool = false,
    overview_open: bool = false,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
        self.workspaces.deinit(self.alloc);
        self.windows.deinit(self.alloc);
        self.occupancy.deinit(self.alloc);
    }

    /// Leaves nothing for the next session to find. `teardown` reads the
    /// overview flags *before* calling this, because dropping them is what
    /// makes the overview look closed again.
    pub fn clear(self: *Self) void {
        var wit = self.workspaces.iterator();
        while (wit.next()) |e| freeWs(self.alloc, e.value_ptr.*);
        self.workspaces.clearRetainingCapacity();
        var vit = self.windows.iterator();
        while (vit.next()) |e| freeWin(self.alloc, e.value_ptr.*);
        self.windows.clearRetainingCapacity();
        self.occupancy.clearRetainingCapacity();
        self.known_overview = false;
        self.overview_open = false;
    }

    pub fn refreshOccupancy(self: *Self) void {
        self.occupancy.clearRetainingCapacity();
        for (self.windows.values()) |win| {
            const ws = win.ws_id orelse continue;
            const gop = self.occupancy.getOrPut(self.alloc, ws) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    pub fn occupied(self: *const Self, ws_id: u64) bool {
        const n = self.occupancy.get(ws_id) orelse return false;
        return n > 0;
    }

    /// Takes the workspace table wholesale: build the replacement elsewhere,
    /// compare it, then hand it over so the old rows are freed exactly once.
    pub fn adoptWorkspaces(self: *Self, next: *WsMap) void {
        var wit = self.workspaces.iterator();
        while (wit.next()) |e| freeWs(self.alloc, e.value_ptr.*);
        self.workspaces.deinit(self.alloc);
        self.workspaces = next.*;
        next.* = .empty;
    }

    pub fn adoptWindows(self: *Self, next: *WinMap) void {
        var vit = self.windows.iterator();
        while (vit.next()) |e| freeWin(self.alloc, e.value_ptr.*);
        self.windows.deinit(self.alloc);
        self.windows = next.*;
        next.* = .empty;
    }
};

// Ownership

/// Every string in these tables comes from `dupe`, never from a literal, so
/// the empty-string early return in `free` is the only special case worth
/// spelling out.
pub fn freeStr(alloc: std.mem.Allocator, s: []const u8) void {
    if (s.len != 0) alloc.free(s);
}

pub fn freeWs(alloc: std.mem.Allocator, ws: WsState) void {
    freeStr(alloc, ws.name);
    freeStr(alloc, ws.output);
}

pub fn freeWin(alloc: std.mem.Allocator, win: WinState) void {
    freeStr(alloc, win.app_id);
    freeStr(alloc, win.title);
}

/// Frees every row in a map that never made it into the tables — a parse that
/// failed halfway through an array has to give back what it already built.
pub fn freeWsMap(alloc: std.mem.Allocator, map: *WsMap) void {
    var it = map.iterator();
    while (it.next()) |e| freeWs(alloc, e.value_ptr.*);
    map.deinit(alloc);
    map.* = .empty;
}

pub fn freeWinMap(alloc: std.mem.Allocator, map: *WinMap) void {
    var it = map.iterator();
    while (it.next()) |e| freeWin(alloc, e.value_ptr.*);
    map.deinit(alloc);
    map.* = .empty;
}

fn dupeInto(alloc: std.mem.Allocator, slot: *[]const u8, fresh: []const u8) !void {
    const copy = try alloc.dupe(u8, fresh);
    freeStr(alloc, slot.*);
    slot.* = copy;
}

// Equality — field-by-field comparison for both structs

pub fn sameWs(a: WsState, b: WsState) bool {
    return a.id == b.id and a.idx == b.idx and
        std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.output, b.output);
}

pub fn sameWin(a: WinState, b: WinState) bool {
    return a.ws_id == b.ws_id and
        std.mem.eql(u8, a.app_id, b.app_id) and
        std.mem.eql(u8, a.title, b.title) and a.x == b.x and a.y == b.y;
}

/// `sameWindowMembership(WinState, WinState)`: only the workspace and the app
/// id decide whether a change is a *membership* change. A title edit or a
/// scroll position move must not shake the taskbar.
pub fn sameMembership(a: WinState, b: WinState) bool {
    return a.ws_id == b.ws_id and std.mem.eql(u8, a.app_id, b.app_id);
}

pub fn sameMembershipMaps(a: *const WinMap, b: *const WinMap) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        const other = b.get(e.key_ptr.*) orelse return false;
        if (!sameMembership(e.value_ptr.*, other)) return false;
    }
    return true;
}

pub fn sameWsMaps(a: *const WsMap, b: *const WsMap) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        const other = b.get(e.key_ptr.*) orelse return false;
        if (!sameWs(e.value_ptr.*, other)) return false;
    }
    return true;
}

pub fn sameWinMaps(a: *const WinMap, b: *const WinMap) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        const other = b.get(e.key_ptr.*) orelse return false;
        if (!sameWin(e.value_ptr.*, other)) return false;
    }
    return true;
}

// JSON probes

pub fn optU64(o: std.json.Value, key: []const u8) ?u64 {
    if (o != .object) return null;
    const v = o.object.get(key) orelse return null;
    if (v == .null) return null;
    return jsonU64(v);
}

/// Narrowing read for the two-element layout positions, throwing on
/// anything out of range; this
/// returns null instead and the caller leaves the coordinate alone.
pub fn jsonI32(v: std.json.Value) ?i32 {
    return switch (v) {
        .integer => |i| std.math.cast(i32, i),
        else => null,
    };
}

/// `optBool`: a boolean, or one of the handful of words niri has used for one.
pub fn optBool(o: std.json.Value, key: []const u8) ?bool {
    if (o != .object) return null;
    const v = o.object.get(key) orelse return null;
    switch (v) {
        .bool => |b| return b,
        .string => |s| {
            for ([_][]const u8{ "open", "opened", "true" }) |w| {
                if (std.mem.eql(u8, s, w)) return true;
            }
            for ([_][]const u8{ "closed", "false" }) |w| {
                if (std.mem.eql(u8, s, w)) return false;
            }
            return null;
        },
        else => return null,
    }
}

// Parsing

/// A workspace row needs both `id` and `idx`; anything else is a row niri
/// added that we have no business inventing an id for.
pub fn decodeWorkspace(alloc: std.mem.Allocator, j: std.json.Value) !?WsState {
    if (j != .object) return null;
    const id = optU64(j, "id") orelse return null;
    const idx = optU64(j, "idx") orelse return null;
    var out = WsState{ .id = id, .idx = @truncate(idx) };
    errdefer freeWs(alloc, out);
    out.name = try alloc.dupe(u8, optStr(j, "name"));
    out.output = try alloc.dupe(u8, optStr(j, "output"));
    return out;
}

pub const ParsedWin = struct {
    id: u64,
    st: WinState,
};

/// A window row needs an `id`. The fields it does carry are applied even when
/// some of them are missing, which is what lets a partial
/// `WindowOpenedOrChanged` land on top of what we already know.
pub fn decodeWindow(alloc: std.mem.Allocator, j: std.json.Value) !?ParsedWin {
    if (j != .object) return null;
    const id = optU64(j, "id") orelse return null;
    var st = WinState{};
    errdefer freeWin(alloc, st);
    _ = try mergeWindowFields(alloc, j, &st);
    return .{ .id = id, .st = st };
}

/// Applies whichever of the fields are present. Returns whether anything moved
/// — a caller that only cares about membership still needs to know the window
/// is a *new* one, so `false` means "this was already the state".
pub fn mergeWindowFields(alloc: std.mem.Allocator, j: std.json.Value, st: *WinState) !bool {
    if (j != .object) return false;

    var changed = false;

    if (j.object.contains("workspace_id")) {
        if (optU64(j, "workspace_id")) |ws| {
            st.ws_id = ws;
            changed = true;
        }
    }

    if (j.object.contains("app_id") or j.object.contains("class")) {
        var app = optStr(j, "app_id");
        if (app.len == 0) app = optStr(j, "class");
        try dupeInto(alloc, &st.app_id, app);
        changed = true;
    }

    if (j.object.contains("title")) {
        const flat = try desk.titleOneLine(alloc, optStr(j, "title"));
        defer alloc.free(flat);
        try dupeInto(alloc, &st.title, flat);
        changed = true;
    }

    if (j.object.contains("layout")) {
        const layout = j.object.get("layout").?;
        if (layout == .object) {
            if (layout.object.get("pos_in_scrolling_layout")) |pos| {
                if (pos == .array and pos.array.items.len >= 2) {
                    if (jsonI32(pos.array.items[0])) |xv| {
                        if (jsonI32(pos.array.items[1])) |yv| {
                            st.x = xv;
                            st.y = yv;
                            changed = true;
                        }
                    }
                }
            }
        }
    }

    return changed;
}

// Three small whole-string parsers

/// Whole-string unsigned decimal: no sign, no
/// surrounding space, nothing left over, and overflow is an error rather than
/// a wrap.
pub fn parseUint(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, ch - '0') catch return null;
    }
    return v;
}

/// Leading run of digits, and only if it is non-zero: `"2foo"` is 2, `"0"` is
/// nothing at all. Multiplication has no overflow guard, so a
/// pathological 40-digit prefix wraps rather than failing — `%` operators
/// reproduce that without the undefined behaviour.
pub fn parseLeadingDigits(s: []const u8) ?usize {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;
    var v: usize = 0;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        v = v *% 10 +% @as(usize, s[i] - '0');
    }
    return if (v > 0) v else null;
}

/// The desk key a region is filed under: position first, then the raw niri id.
/// The result is owned — `deskKeys` hands out a list of these and the caller
/// frees them — and empty when the workspace has neither.
pub fn regionKey(alloc: std.mem.Allocator, ws: WsState) ![]u8 {
    if (ws.idx > 0) return std.fmt.allocPrint(alloc, "{d}", .{ws.idx});
    if (ws.id > 0) return std.fmt.allocPrint(alloc, "{d}", .{ws.id});
    return alloc.alloc(u8, 0);
}

// Tests

fn parseDoc(alloc: std.mem.Allocator, doc: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, doc, .{});
}

test "niri-ws-state: a workspace row needs an id and an idx" {
    const t = std.testing;
    const alloc = t.allocator;

    {
        const p = try parseDoc(alloc,
            \\{"id":7,"idx":3,"name":"dev","output":"DP-1"}
        );
        defer p.deinit();
        const good = try decodeWorkspace(alloc, p.value);
        try t.expect(good != null);
        const ws = good.?;
        defer freeWs(alloc, ws);
        try t.expectEqual(@as(u64, 7), ws.id);
        try t.expectEqual(@as(u8, 3), ws.idx);
        try t.expectEqualStrings("dev", ws.name);
        try t.expectEqualStrings("DP-1", ws.output);
    }

    // A null name is an empty string, not a missing key.
    {
        const p = try parseDoc(alloc, "{\"id\":1,\"idx\":1,\"name\":null}");
        defer p.deinit();
        const unnamed = (try decodeWorkspace(alloc, p.value)).?;
        defer freeWs(alloc, unnamed);
        try t.expectEqualStrings("", unnamed.name);
    }

    // Either key missing and the row is dropped rather than defaulted.
    for ([_][]const u8{
        "{\"idx\":1}",
        "{\"id\":1}",
        "[1,2]",
        "{\"id\":\"1\",\"idx\":1}",
        "{\"id\":-1,\"idx\":1}",
        "null",
    }) |doc| {
        const p = try parseDoc(alloc, doc);
        defer p.deinit();
        try t.expect((try decodeWorkspace(alloc, p.value)) == null);
    }

    // idx arrives as a u64 and is truncated to a u8; values past 255 wrap.
    {
        const p = try parseDoc(alloc, "{\"id\":1,\"idx\":300}");
        defer p.deinit();
        const wide = (try decodeWorkspace(alloc, p.value)).?;
        defer freeWs(alloc, wide);
        try t.expectEqual(@as(u8, 44), wide.idx);
    }
}

test "niri-ws-state: regionKey prefers the position over the id" {
    const t = std.testing;
    const alloc = t.allocator;

    const numbered = try regionKey(alloc, .{ .id = 42, .idx = 3 });
    defer alloc.free(numbered);
    try t.expectEqualStrings("3", numbered);

    const by_id = try regionKey(alloc, .{ .id = 42, .idx = 0 });
    defer alloc.free(by_id);
    try t.expectEqualStrings("42", by_id);

    const neither = try regionKey(alloc, .{});
    defer alloc.free(neither);
    try t.expectEqualStrings("", neither);
}

test "niri-ws-state: window fields only move when the key is there" {
    const t = std.testing;
    const alloc = t.allocator;

    var st = WinState{};
    defer freeWin(alloc, st);

    // A title arrives collapsed onto one line before it is stored. The literal
    // is a `\\` string, so `\n` and `\t` reach the JSON parser as escapes.
    const full =
        \\{"workspace_id":2,"app_id":"Alacritty","title":"a\n b\tc","layout":{"pos_in_scrolling_layout":[12,-4]}}
    ;
    {
        const p = try parseDoc(alloc, full);
        defer p.deinit();
        try t.expect(try mergeWindowFields(alloc, p.value, &st));
    }
    try t.expectEqual(@as(?u64, 2), st.ws_id);
    try t.expectEqualStrings("Alacritty", st.app_id);
    try t.expectEqualStrings("a b c", st.title);
    try t.expectEqual(@as(i32, 12), st.x);
    try t.expectEqual(@as(i32, -4), st.y);

    // `mergeWindowFields` reports "a field I know about was present", not
    // "the value differs" — the manager's own
    // equality check further down is what decides whether anything actually
    // moved. Re-sending the same row still counts as a hit here, and the
    // strings it re-dupes replace the old ones — LeakSanitizer is what proves
    // those frees happened.
    {
        const p = try parseDoc(alloc, full);
        defer p.deinit();
        try t.expect(try mergeWindowFields(alloc, p.value, &st));
    }

    // A payload carrying only an id touches nothing and reports nothing, so
    // `WindowOpenedOrChanged` never resurrects a window it cannot fill in.
    {
        const p = try parseDoc(alloc, "{\"id\":5}");
        defer p.deinit();
        try t.expect(!(try mergeWindowFields(alloc, p.value, &st)));
    }
    try t.expectEqualStrings("Alacritty", st.app_id);

    // `class` stands in for a missing `app_id`; an explicit empty `app_id`
    // still falls through to it.
    for ([_][]const u8{
        "{\"class\":\"foot\"}",
        "{\"app_id\":\"\",\"class\":\"foot\"}",
    }) |doc| {
        const p = try parseDoc(alloc, doc);
        defer p.deinit();
        try t.expect(try mergeWindowFields(alloc, p.value, &st));
        try t.expectEqualStrings("foot", st.app_id);
    }

    // An absent key leaves the value alone rather than blanking it.
    {
        const p = try parseDoc(alloc, "{\"title\":\"next\"}");
        defer p.deinit();
        try t.expect(try mergeWindowFields(alloc, p.value, &st));
    }
    try t.expectEqualStrings("foot", st.app_id);
    try t.expectEqualStrings("next", st.title);

    // A layout position that does not fit an i32 is ignored, not thrown on.
    {
        const p = try parseDoc(alloc, "{\"layout\":{\"pos_in_scrolling_layout\":[99999999999,1]}}");
        defer p.deinit();
        try t.expect(!(try mergeWindowFields(alloc, p.value, &st)));
    }
    try t.expectEqual(@as(i32, 12), st.x);

    // A non-object payload changes nothing and reports nothing.
    {
        const p = try parseDoc(alloc, "[1,2]");
        defer p.deinit();
        try t.expect(!(try mergeWindowFields(alloc, p.value, &st)));
    }
}

test "niri-ws-state: membership compares workspace and app id only" {
    const t = std.testing;
    const a = WinState{ .ws_id = 1, .app_id = "a", .title = "one", .x = 5 };
    const b = WinState{ .ws_id = 1, .app_id = "a", .title = "two", .x = 9 };
    const c = WinState{ .ws_id = 2, .app_id = "a", .title = "one" };
    const d = WinState{ .ws_id = 1, .app_id = "b", .title = "one" };
    try t.expect(sameMembership(a, b));
    try t.expect(!sameMembership(a, c));
    try t.expect(!sameMembership(a, d));
    // The full comparison still notices the title and the position.
    try t.expect(!sameWin(a, b));
    try t.expect(sameWin(a, a));
}

test "niri-ws-state: id parsers respect the documented bounds" {
    const t = std.testing;
    try t.expectEqual(@as(?u64, 7), parseUint("7"));
    try t.expectEqual(@as(?u64, 0), parseUint("0"));
    try t.expect(parseUint("") == null);
    try t.expect(parseUint("+7") == null);
    try t.expect(parseUint("7 ") == null);
    try t.expect(parseUint(" 7") == null);
    try t.expect(parseUint("-1") == null);
    try t.expect(parseUint("1.5") == null);
    try t.expect(parseUint("99999999999999999999999999") == null);

    try t.expectEqual(@as(?usize, 2), parseLeadingDigits("2foo"));
    try t.expectEqual(@as(?usize, 12), parseLeadingDigits("12"));
    // Leading zeroes are digits like any other: the guard is on the finished
    // value, not on the first byte.
    try t.expectEqual(@as(?usize, 7), parseLeadingDigits("007"));
    try t.expect(parseLeadingDigits("0") == null);
    try t.expect(parseLeadingDigits("x1") == null);
    try t.expect(parseLeadingDigits("") == null);
}

test "niri-ws-state: occupancy counts windows per workspace" {
    const t = std.testing;
    const alloc = t.allocator;
    var tb = Tables.init(alloc);
    defer tb.deinit();

    for ([_][]const u8{
        \\{"id":10,"workspace_id":1,"app_id":"a"}
        , \\{"id":11,"workspace_id":1,"app_id":"b"}
        , \\{"id":12,"workspace_id":2,"app_id":"c"}
        , \\{"id":13,"app_id":"d"}
    }) |doc| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, doc, .{});
        defer parsed.deinit();
        const win = (try decodeWindow(alloc, parsed.value)).?;
        try tb.windows.put(alloc, win.id, win.st);
    }

    tb.refreshOccupancy();
    try t.expect(tb.occupied(1));
    try t.expect(tb.occupied(2));
    try t.expect(!tb.occupied(3));
    try t.expectEqual(@as(?usize, 2), tb.occupancy.get(1));

    // Clearing the tables drops the derived counts with them, and nothing is
    // left behind for the next session (the leak check is the assertion).
    tb.clear();
    try t.expectEqual(@as(usize, 0), tb.windows.count());
    try t.expect(!tb.occupied(1));
}
