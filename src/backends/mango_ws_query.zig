//! mango workspace queries: reading the two tables back out for
//! the shell and for the two mango-only hooks `power_actions` takes.
//!
//! Socket-free half of `MangoWorkspaceManager`
//! Everything here takes
//! plain slices and an optional resolver, so the hand-authored fixtures below
//! can drive it without a compositor anywhere near them.

const std = @import("std");
const desk = @import("desk.zig");
const st = @import("mango_ws_state.zig");

/// The compositor's name for an output handle. No resolver, a null handle, or
/// a resolver that does not recognise the handle all read as "no name" — which
/// every caller below reads as "no filter", not as "no results".
pub fn resolveName(resolver: ?desk.Resolver, output: ?*anyopaque) []const u8 {
    const r = resolver orelse return "";
    if (output == null) return "";
    return r.name(output);
}

pub fn findOutput(
    tables: *const st.Tables,
    resolver: ?desk.Resolver,
    output: ?*anyopaque,
) ?*const st.Out {
    const name = resolveName(resolver, output);
    if (name.len == 0) return null;
    return tables.byName(name);
}

/// Which tag a monitor is showing: the only active one, else the first active
/// one that also carries the focused client, else simply the first active one.
/// None at all is a monitor with nothing selected, and stays `null`.
pub fn activeTagIdx(tags: []const st.Tag) ?usize {
    var count: usize = 0;
    var first: ?usize = null;
    var focused: ?usize = null;
    for (tags, 0..) |tag, i| {
        if (!tag.active) continue;
        count += 1;
        if (first == null) first = i;
        if (tag.focused and focused == null) focused = i;
    }
    if (first == null) return null;
    if (count == 1) return first;
    return focused orelse first;
}

/// One region per tag. `id` and `name` are both the tag number as text and
/// `coordinates` is its single, already zero-based value — mango counts tags
/// from one, the shell from zero, and this is the only place that crosses over.
pub fn buildRegion(alloc: std.mem.Allocator, tag: st.Tag, shell_active: bool) !desk.Region {
    const id = try std.fmt.allocPrint(alloc, "{d}", .{tag.index});
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, id);
    errdefer alloc.free(name);
    const first: u32 = if (tag.index > 0) tag.index - 1 else 0;
    const coords = try alloc.dupe(u32, &[_]u32{first});
    return .{
        .id = id,
        .name = name,
        .coordinates = coords,
        .index = tag.index,
        .active = shell_active,
        .urgent = tag.urgent,
        .occupied = tag.occupied,
    };
}

/// Every tag worth showing, from every monitor, deduplicated by tag number and
/// sorted by it. dwl gives each monitor its own run of tags, so two monitors
/// both report tag 1; the event's
/// own monitor order decides, so the same payload always yields the same row.
pub fn allRegions(alloc: std.mem.Allocator, tables: *const st.Tables) ![]desk.Region {
    var slots: std.array_hash_map.Auto(u32, usize) = .empty;
    defer slots.deinit(alloc);

    var list: std.ArrayList(desk.Region) = .empty;
    defer {
        desk.freeRegionElems(alloc, list.items);
        list.deinit(alloc);
    }

    for (tables.outputs.values()) |out| {
        const si = activeTagIdx(out.tags);
        for (out.tags, 0..) |tag, i| {
            if (!tag.occupied and !tag.active) continue;
            const region = try buildRegion(alloc, tag, si != null and i == si.?);
            const gop = slots.getOrPut(alloc, tag.index) catch {
                desk.freeRegion(alloc, region);
                continue;
            };
            if (!gop.found_existing) {
                list.append(alloc, region) catch {
                    _ = slots.fetchOrderedRemove(tag.index);
                    desk.freeRegion(alloc, region);
                    continue;
                };
                gop.value_ptr.* = list.items.len - 1;
                continue;
            }
            // The index is already on the list: this monitor's row replaces the
            // one before it, and the one before it goes with it.
            desk.freeRegion(alloc, list.items[gop.value_ptr.*]);
            list.items[gop.value_ptr.*] = region;
        }
    }

    std.mem.sort(desk.Region, list.items, {}, lessByIndex);
    return list.toOwnedSlice(alloc);
}

fn lessByIndex(_: void, a: desk.Region, b: desk.Region) bool {
    return a.index < b.index;
}

/// One monitor's tags, in the order the payload listed them, with no
/// deduplication and no sort — a caller that asked about *this* output wants
/// what that output has. An output nobody can name or nobody has seen falls
/// back to everything, so an unresolvable output still gets a taskbar rather
/// than a blank one.
pub fn regionsOnOutput(
    alloc: std.mem.Allocator,
    tables: *const st.Tables,
    resolver: ?desk.Resolver,
    output: ?*anyopaque,
) ![]desk.Region {
    const out = findOutput(tables, resolver, output) orelse return allRegions(alloc, tables);
    const si = activeTagIdx(out.tags);

    var list: std.ArrayList(desk.Region) = .empty;
    defer {
        desk.freeRegionElems(alloc, list.items);
        list.deinit(alloc);
    }
    for (out.tags, 0..) |tag, i| {
        if (!tag.occupied and !tag.active) continue;
        const region = try buildRegion(alloc, tag, si != null and i == si.?);
        list.append(alloc, region) catch |err| {
            desk.freeRegion(alloc, region);
            return err;
        };
    }
    return list.toOwnedSlice(alloc);
}

/// desk key -> the app ids seen on it. Two windows of the same app on one tag
/// contribute it once, and an app id nobody reported contributes nothing.
pub fn appsByDesk(
    alloc: std.mem.Allocator,
    tables: *const st.Tables,
    resolver: ?desk.Resolver,
    output: ?*anyopaque,
) !desk.AppMap {
    const out = findOutput(tables, resolver, output);
    const filter = if (out) |o| o.name else "";

    var result = desk.AppMap.init(alloc);
    errdefer desk.freeAppMap(alloc, &result);

    for (tables.clients.items) |c| {
        if (filter.len != 0 and !std.mem.eql(u8, c.out_name, filter)) continue;
        if (c.app_id.len == 0) continue;
        for (c.tags) |tag| {
            if (tag == 0) continue;
            const key = std.fmt.allocPrint(alloc, "{d}", .{tag}) catch continue;
            const gop = result.getOrPut(key) catch {
                alloc.free(key);
                continue;
            };
            if (gop.found_existing) {
                // The map already owns a key of its own; ours is a duplicate.
                alloc.free(key);
                var already = false;
                for (gop.value_ptr.*.items) |a| {
                    if (std.mem.eql(u8, a, c.app_id)) {
                        already = true;
                        break;
                    }
                }
                if (already) continue;
            } else {
                gop.value_ptr.* = .empty;
            }
            const copy = alloc.dupe(u8, c.app_id) catch continue;
            gop.value_ptr.*.append(alloc, copy) catch alloc.free(copy);
        }
    }
    return result;
}

/// One row per (window, tag) pair — a window on three tags is three rows,
/// because each tag's taskbar has to show it. Tag `0` is mango's "no tag" and
/// belongs to no taskbar.
pub fn windowsOnDesk(
    alloc: std.mem.Allocator,
    tables: *const st.Tables,
    resolver: ?desk.Resolver,
    output: ?*anyopaque,
) ![]desk.Win {
    const out = findOutput(tables, resolver, output);
    const filter = if (out) |o| o.name else "";

    var list: std.ArrayList(desk.Win) = .empty;
    defer {
        desk.freeWinElems(alloc, list.items);
        list.deinit(alloc);
    }

    for (tables.clients.items) |c| {
        if (filter.len != 0 and !std.mem.eql(u8, c.out_name, filter)) continue;
        for (c.tags) |tag| {
            if (tag == 0) continue;
            const w = try dupWin(alloc, c, tag);
            list.append(alloc, w) catch |err| {
                desk.freeWin(alloc, w);
                return err;
            };
        }
    }
    return list.toOwnedSlice(alloc);
}

fn dupWin(alloc: std.mem.Allocator, c: st.Client, tag: u32) !desk.Win {
    const key = try std.fmt.allocPrint(alloc, "{d}", .{tag});
    errdefer alloc.free(key);
    const window_id = try alloc.dupe(u8, c.id);
    errdefer alloc.free(window_id);
    const app_id = try alloc.dupe(u8, c.app_id);
    errdefer alloc.free(app_id);
    const title = try alloc.dupe(u8, c.title);
    return .{
        .window_id = window_id,
        .desk_key = key,
        .app_id = app_id,
        .title = title,
        .x = c.x,
        .y = c.y,
    };
}

/// The output the shell considers selected: the active monitor, matched back
/// against the outputs the Wayland binding told us about. With two active
/// monitors the answer follows the event's order,
/// arbitrary; here it is the event's order.
pub fn selectedOutput(
    tables: *const st.Tables,
    known: []const ?*anyopaque,
    resolver: ?desk.Resolver,
) ?*anyopaque {
    for (tables.outputs.values()) |out| {
        if (!out.active) continue;
        for (known) |o| {
            if (std.mem.eql(u8, resolveName(resolver, o), out.name)) return o;
        }
    }
    return null;
}

/// The focused client's title and app id for an output. Both are borrowed from
/// the table, so a caller that wants them past the next event has to copy.
/// An output nobody can name falls back to the front monitor.
pub const Focused = struct {
    title: []const u8 = "",
    app_id: []const u8 = "",
};

pub fn focusedToplevel(
    tables: *const st.Tables,
    resolver: ?desk.Resolver,
    output: ?*anyopaque,
) ?Focused {
    const out = findOutput(tables, resolver, output) orelse tables.currentOutput() orelse return null;
    return .{ .title = out.client_title, .app_id = out.client_app_id };
}

// Tests

const t = std.testing;

const OutSpec = struct {
    name: []const u8,
    active: bool = false,
    client_title: []const u8 = "",
    client_app_id: []const u8 = "",
    tags: []const st.Tag = &.{},
};

fn addOut(tables: *st.Tables, spec: OutSpec) void {
    const alloc = tables.alloc;
    var out: st.Out = .{ .active = spec.active };
    var keep = false;
    defer if (!keep) st.freeOut(alloc, out);
    out.name = alloc.dupe(u8, spec.name) catch return;
    out.client_title = alloc.dupe(u8, spec.client_title) catch return;
    out.client_app_id = alloc.dupe(u8, spec.client_app_id) catch return;
    var list: std.ArrayList(st.Tag) = .empty;
    defer list.deinit(alloc);
    for (spec.tags) |tg| list.append(alloc, tg) catch return;
    out.tags = list.toOwnedSlice(alloc) catch return;
    keep = true;
    st.putOut(alloc, &tables.outputs, out);
}

const ClientSpec = struct {
    id: []const u8,
    app_id: []const u8 = "",
    title: []const u8 = "",
    out_name: []const u8 = "",
    tags: []const u32 = &.{},
};

fn addClient(tables: *st.Tables, spec: ClientSpec) void {
    const alloc = tables.alloc;
    var c: st.Client = .{};
    var keep = false;
    defer if (!keep) st.freeClient(alloc, c);
    c.id = alloc.dupe(u8, spec.id) catch return;
    c.app_id = alloc.dupe(u8, spec.app_id) catch return;
    c.title = alloc.dupe(u8, spec.title) catch return;
    c.out_name = alloc.dupe(u8, spec.out_name) catch return;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(alloc);
    for (spec.tags) |tg| list.append(alloc, tg) catch return;
    c.tags = list.toOwnedSlice(alloc) catch return;
    keep = true;
    tables.clients.append(alloc, c) catch st.freeClient(alloc, c);
}

/// Two monitors whose tag numbers overlap, which is what dwl's per-monitor tag
/// sets look like, plus four clients across them.
fn fixture() st.Tables {
    var tables = st.Tables.init(t.allocator);
    addOut(&tables, .{
        .name = "DP-1",
        .active = true,
        .client_title = "Terminal",
        .client_app_id = "otter-term",
        .tags = &.{
            .{ .index = 1, .occupied = true },
            .{ .index = 2, .active = true, .focused = true, .occupied = true },
            .{ .index = 3 },
        },
    });
    addOut(&tables, .{
        .name = "DP-2",
        .client_title = "Browser",
        .client_app_id = "ff",
        .tags = &.{.{ .index = 1, .active = true, .focused = true, .occupied = true }},
    });
    addClient(&tables, .{ .id = "1", .app_id = "foot", .title = "One", .out_name = "DP-1", .tags = &.{ 1, 2 } });
    addClient(&tables, .{ .id = "2", .app_id = "foot", .title = "Two", .out_name = "DP-1", .tags = &.{1} });
    addClient(&tables, .{ .id = "3", .title = "Three", .out_name = "DP-2", .tags = &.{ 2, 0 } });
    addClient(&tables, .{ .id = "4", .app_id = "browser", .title = "Four", .out_name = "DP-2", .tags = &.{1} });
    return tables;
}

fn fixedResolver(ctx: *anyopaque, _: ?*anyopaque) []const u8 {
    const name: *[]const u8 = @ptrCast(@alignCast(ctx));
    return name.*;
}

test "mango-ws-query: allRegions merges monitors by tag number and sorts" {
    var tables = fixture();
    defer tables.deinit();

    const all = try allRegions(t.allocator, &tables);
    defer desk.freeRegionList(t.allocator, all);

    // DP-1's tag 3 is neither occupied nor active, so it never appears; its
    // tag 1 loses to DP-2's, which is later in the event.
    try t.expectEqual(@as(usize, 2), all.len);
    try t.expectEqual(@as(u32, 1), all[0].index);
    try t.expect(all[0].active); // DP-2 is the one showing tag 1
    try t.expectEqualStrings("1", all[0].id);
    try t.expectEqualStrings("1", all[0].name);
    try t.expectEqualSlices(u32, &[_]u32{0}, all[0].coordinates);
    try t.expectEqual(@as(u32, 2), all[1].index);
    try t.expect(all[1].active); // DP-1's own focused tag survives: DP-2 has no tag 2
    try t.expect(all[1].occupied);
    try t.expectEqualSlices(u32, &[_]u32{1}, all[1].coordinates);

    // An empty monitor list has nothing to say.
    tables.clear();
    const nothing = try allRegions(t.allocator, &tables);
    defer desk.freeRegionList(t.allocator, nothing);
    try t.expectEqual(@as(usize, 0), nothing.len);
}

test "mango-ws-query: regionsOnOutput is per monitor unless the name means nothing" {
    var tables = fixture();
    defer tables.deinit();

    var name: []const u8 = "DP-1";
    const r = desk.Resolver{ .ctx = @ptrCast(&name), .call = fixedResolver };

    const on_dp1 = try regionsOnOutput(t.allocator, &tables, r, @ptrFromInt(0x1000));
    defer desk.freeRegionList(t.allocator, on_dp1);
    // Tag order, not sorted, and tag 3 filtered out for being empty.
    try t.expectEqual(@as(usize, 2), on_dp1.len);
    try t.expectEqual(@as(u32, 1), on_dp1[0].index);
    try t.expect(!on_dp1[0].active); // DP-1's focused tag is 2, not 1
    try t.expectEqual(@as(u32, 2), on_dp1[1].index);
    try t.expect(on_dp1[1].active);

    name = "DP-2";
    const on_dp2 = try regionsOnOutput(t.allocator, &tables, r, @ptrFromInt(0x1000));
    defer desk.freeRegionList(t.allocator, on_dp2);
    try t.expectEqual(@as(usize, 1), on_dp2.len);
    try t.expect(on_dp2[0].active);

    // No resolver, no handle, and a monitor nobody has heard of: all three
    // fall back to the whole list rather than to nothing.
    const no_resolver = try regionsOnOutput(t.allocator, &tables, null, @ptrFromInt(0x1000));
    defer desk.freeRegionList(t.allocator, no_resolver);
    try t.expectEqual(@as(usize, 2), no_resolver.len);

    name = "DP-9";
    const unknown = try regionsOnOutput(t.allocator, &tables, r, @ptrFromInt(0x1000));
    defer desk.freeRegionList(t.allocator, unknown);
    try t.expectEqual(@as(usize, 2), unknown.len);

    const no_output = try regionsOnOutput(t.allocator, &tables, r, null);
    defer desk.freeRegionList(t.allocator, no_output);
    try t.expectEqual(@as(usize, 2), no_output.len);
}

test "mango-ws-query: appsByDesk deduplicates and skips clients with no app" {
    var tables = fixture();
    defer tables.deinit();

    var name: []const u8 = "DP-1";
    const r = desk.Resolver{ .ctx = @ptrCast(&name), .call = fixedResolver };

    var all = try appsByDesk(t.allocator, &tables, null, null);
    defer desk.freeAppMap(t.allocator, &all);
    try t.expectEqual(@as(usize, 2), all.count());
    // `foot` is on tag 1 twice but listed once; `browser` joins it there and
    // tag 2 keeps its own.
    try t.expectEqual(@as(usize, 2), all.get("1").?.items.len);
    try t.expectEqualStrings("foot", all.get("1").?.items[0]);
    try t.expectEqualStrings("browser", all.get("1").?.items[1]);
    try t.expectEqual(@as(usize, 1), all.get("2").?.items.len);

    name = "DP-1";
    var on_dp1 = try appsByDesk(t.allocator, &tables, r, @ptrFromInt(0x1000));
    defer desk.freeAppMap(t.allocator, &on_dp1);
    // Both DP-1 clients run `foot`, so tag 1 still lists it once.
    try t.expectEqual(@as(usize, 2), on_dp1.count());
    try t.expectEqual(@as(usize, 1), on_dp1.get("1").?.items.len);
    try t.expectEqualStrings("foot", on_dp1.get("1").?.items[0]);

    name = "DP-2";
    var on_dp2 = try appsByDesk(t.allocator, &tables, r, @ptrFromInt(0x1000));
    defer desk.freeAppMap(t.allocator, &on_dp2);
    // Client 3 reported no app id, so it contributes nothing at all — not to
    // tag 1 and not to tag 2, which therefore never gets a key of its own.
    try t.expectEqual(@as(usize, 1), on_dp2.count());
    try t.expectEqual(@as(usize, 1), on_dp2.get("1").?.items.len);
    try t.expectEqualStrings("browser", on_dp2.get("1").?.items[0]);
    try t.expect(on_dp2.get("2") == null);
}

test "mango-ws-query: windowsOnDesk is one row per window and tag" {
    var tables = fixture();
    defer tables.deinit();

    var name: []const u8 = "DP-1";
    const r = desk.Resolver{ .ctx = @ptrCast(&name), .call = fixedResolver };

    const on_dp1 = try windowsOnDesk(t.allocator, &tables, r, @ptrFromInt(0x1000));
    defer desk.freeWinList(t.allocator, on_dp1);
    // Two clients, one of them on two tags: three rows.
    try t.expectEqual(@as(usize, 3), on_dp1.len);
    try t.expectEqualStrings("1", on_dp1[0].window_id);
    try t.expectEqualStrings("1", on_dp1[0].desk_key);
    try t.expectEqualStrings("foot", on_dp1[0].app_id);
    try t.expectEqualStrings("One", on_dp1[0].title);
    try t.expectEqualStrings("2", on_dp1[1].desk_key);
    try t.expectEqualStrings("2", on_dp1[2].window_id);

    const all = try windowsOnDesk(t.allocator, &tables, null, null);
    defer desk.freeWinList(t.allocator, all);
    // Client 3's tag 0 contributes nothing, so five rows remain.
    try t.expectEqual(@as(usize, 5), all.len);

    name = "DP-9";
    const unknown = try windowsOnDesk(t.allocator, &tables, r, @ptrFromInt(0x1000));
    defer desk.freeWinList(t.allocator, unknown);
    try t.expectEqual(@as(usize, 5), unknown.len);
}

/// Two monitor handles and the name each one resolves to, so the mango-only
/// hooks can be exercised without a Wayland binding around them.
const Pair = struct {
    a: *anyopaque,
    b: *anyopaque,
};

fn pairResolver(ctx: *anyopaque, output: ?*anyopaque) []const u8 {
    const self: *Pair = @ptrCast(@alignCast(ctx));
    if (output == self.a) return "DP-1";
    if (output == self.b) return "DP-2";
    return "";
}

test "mango-ws-query: the two mango-only hooks find an output and its client" {
    var tables = fixture();
    defer tables.deinit();

    const a: *anyopaque = @ptrFromInt(0x1000);
    const b: *anyopaque = @ptrFromInt(0x2000);
    var pair = Pair{ .a = a, .b = b };
    const resolver = desk.Resolver{ .ctx = @ptrCast(&pair), .call = pairResolver };
    const known = [_]?*anyopaque{ a, b };

    // DP-1 is the monitor that says it is active, and it is the first handle
    // whose resolved name matches it.
    try t.expect(selectedOutput(&tables, &known, resolver).? == a);

    tables.outputs.values()[0].active = false;
    tables.outputs.values()[1].active = true;
    try t.expect(selectedOutput(&tables, &known, resolver).? == b);

    // Nothing active means nothing selected.
    tables.outputs.values()[1].active = false;
    try t.expect(selectedOutput(&tables, &known, resolver) == null);

    // A known output answers with its own client…
    tables.outputs.values()[1].active = true;
    const on_b = focusedToplevel(&tables, resolver, b).?;
    try t.expectEqualStrings("Browser", on_b.title);
    try t.expectEqualStrings("ff", on_b.app_id);

    // …an unknown handle falls back to the front monitor, which is the first
    // one that claims to be active…
    tables.outputs.values()[0].active = true;
    const unknown = focusedToplevel(&tables, resolver, @ptrFromInt(0x3000)).?;
    try t.expectEqualStrings("Terminal", unknown.title);
    try t.expectEqualStrings("otter-term", unknown.app_id);

    // …and a table with no monitors can answer neither.
    tables.clear();
    try t.expect(focusedToplevel(&tables, resolver, b) == null);
    try t.expect(selectedOutput(&tables, &known, resolver) == null);
}

test "mango-ws-query: a tag numbered zero would still cross over correctly" {
    // `buildRegion` guards the subtraction, because a payload that reported
    // tag 0 would otherwise wrap to `maxInt(u32)`.
    const r = try buildRegion(t.allocator, .{ .index = 0 }, false);
    defer desk.freeRegion(t.allocator, r);
    try t.expectEqual(@as(u32, 0), r.coordinates[0]);
    try t.expectEqualStrings("0", r.id);
    try t.expectEqual(@as(?usize, null), activeTagIdx(&.{}));
}
