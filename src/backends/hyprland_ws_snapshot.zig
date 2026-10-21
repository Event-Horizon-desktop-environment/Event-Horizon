//! Snapshot loading for the Hyprland workspace manager: the three `j/…`
//! documents that `reloadSnapshot` pulls in, parsed straight into the tables
//! `hyprland_ws_state.zig` owns.
//!
//! Workspace/monitor snapshot loading:
//! loadClients`. Each one takes the raw reply as text rather than asking for it
//! — the caller owns the socket, so the recorded fixtures under
//! `testdata/backends/hyprland/` replay through exactly this code.

const std = @import("std");
const desk = @import("desk.zig");
const codec = @import("hyprland_ws_codec.zig");
const ws_state = @import("hyprland_ws_state.zig");
/// Recorded replies, wired in by the build (see `testdata/root.zig`).
const testdata = @import("testdata");

const State = ws_state.State;

/// Parses a reply as the JSON array every `j/…` command returns, or nothing
/// when the bytes are not an array — which covers "no answer at all".
fn asArray(state: *State, text: []const u8) ?std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, state.alloc, text, .{}) catch return null;
    if (parsed.value != .array) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

/// Replaces the workspace table. Negative ids are the special workspaces
/// Hyprland keeps off every taskbar, so they never make it into the list.
///
/// A reply that is not an array leaves the previous table alone.
/// was `if (!json || !json->is_array()) return;`. Running out of memory half
/// way through does the same, so a stalled compositor never costs the shell its
/// last known-good snapshot.
pub fn loadWorkspaces(self: *State, text: []const u8) void {
    loadWorkspacesFallible(self, text) catch {};
}

fn loadWorkspacesFallible(self: *State, text: []const u8) !void {
    var parsed = asArray(self, text) orelse return;
    defer parsed.deinit();

    var next: std.ArrayList(ws_state.Space) = .empty;
    errdefer {
        for (next.items) |ws| ws_state.freeSpace(self.alloc, ws);
        next.deinit(self.alloc);
    }
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id = desk.jsonInt(item, "id", i32, -1);
        if (id < 0) continue;
        const name = try self.alloc.dupe(u8, desk.jsonStr(item, "name"));
        errdefer self.alloc.free(name);
        const monitor = try self.alloc.dupe(u8, desk.jsonStr(item, "monitor"));
        errdefer self.alloc.free(monitor);
        try next.append(self.alloc, .{ .id = id, .name = name, .monitor = monitor });
    }

    for (self.spaces.items) |ws| ws_state.freeSpace(self.alloc, ws);
    self.spaces.deinit(self.alloc);
    self.spaces = next;
}

/// Records which workspace each monitor has focused. A document with no usable
/// pairing is ignored rather than wiping what we knew — losing the mapping would
/// leave every workspace looking inactive.
///
/// Only a real integer under `activeWorkspace.id` counts: `activeWorkspaceID`
/// and friends are different fields, and a string id would point the taskbar at
/// the wrong workspace without anyone noticing.
pub fn loadMonitors(self: *State, text: []const u8) void {
    var parsed = asArray(self, text) orelse return;
    defer parsed.deinit();

    var by_mon = std.StringHashMap(i32).init(self.alloc);
    // Adopting hands the whole map over, so the deferred release has to be
    // skipped entirely: freeing the buckets would leave `active_map` — a copy of
    // the same struct — pointing at reclaimed memory.
    var adopted = false;
    defer {
        if (!adopted) {
            freeKeys(self, &by_mon);
            by_mon.deinit();
        }
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const name = desk.jsonStr(item, "name");
        if (name.len == 0) continue;
        const active = item.object.get("activeWorkspace") orelse continue;
        if (active != .object) continue;
        const ws_id = switch (active.object.get("id") orelse continue) {
            .integer => |n| n,
            else => continue,
        };
        if (ws_id < std.math.minInt(i32) or ws_id > std.math.maxInt(i32)) continue;

        const gop = by_mon.getOrPut(name) catch continue;
        if (gop.found_existing) {
            gop.value_ptr.* = @intCast(ws_id);
            continue;
        }
        gop.key_ptr.* = self.alloc.dupe(u8, name) catch {
            _ = by_mon.remove(name);
            continue;
        };
        gop.value_ptr.* = @intCast(ws_id);
    }

    if (by_mon.count() == 0) return;
    // Release the outgoing table completely. `freeActiveMap` only empties it, so
    // the buckets it retains would be stranded by the overwrite below; deiniting
    // straight afterwards frees them and marks the map undefined, which the
    // assignment immediately repairs.
    self.freeActiveMap();
    self.active_map.deinit();
    self.active_map = by_mon;
    adopted = true;
}

/// Replaces the window table. `urgent` is not a field Hyprland always
/// populates in `j/clients`, so an absent (or mistyped) one inherits the value
/// the previous table held for the same address.
pub fn loadClients(self: *State, text: []const u8) void {
    loadClientsFallible(self, text) catch {};
}

fn loadClientsFallible(self: *State, text: []const u8) !void {
    var parsed = asArray(self, text) orelse return;
    defer parsed.deinit();

    var next: std.array_hash_map.Auto(u64, ws_state.Toplevel) = .empty;
    errdefer {
        var it = next.iterator();
        while (it.next()) |e| ws_state.freeToplevel(self.alloc, e.value_ptr.*);
        next.deinit(self.alloc);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const addr = codec.decodeHex(desk.jsonStr(item, "address")) orelse continue;
        if (next.contains(addr)) continue; // first listing wins, as `emplace` did

        var workspace_id: i32 = -1;
        if (item.object.get("workspace")) |ws| {
            if (ws == .object) workspace_id = desk.jsonInt(ws, "id", i32, -1);
        }
        var app_id = desk.jsonStr(item, "class");
        if (app_id.len == 0) app_id = desk.jsonStr(item, "initialClass");

        var urgent = false;
        if (self.windows.get(addr)) |previous| urgent = previous.urgent;
        if (item.object.get("urgent")) |flag| {
            if (flag == .bool) urgent = flag.bool;
        }

        const owned_app = try self.alloc.dupe(u8, app_id);
        errdefer self.alloc.free(owned_app);
        const owned_title = try self.alloc.dupe(u8, desk.jsonStr(item, "title"));
        errdefer self.alloc.free(owned_title);
        try next.put(self.alloc, addr, .{
            .workspace_id = workspace_id,
            .app_id = owned_app,
            .title = owned_title,
            .urgent = urgent,
        });
    }

    var it = self.windows.iterator();
    while (it.next()) |e| ws_state.freeToplevel(self.alloc, e.value_ptr.*);
    self.windows.deinit(self.alloc);
    self.windows = next;
}

fn freeKeys(self: *State, map: *std.StringHashMap(i32)) void {
    var it = map.iterator();
    while (it.next()) |e| self.alloc.free(e.key_ptr.*);
}

// Tests

test "hyprland-ws-snapshot: workspace document replaces the table and drops specials" {
    const t = std.testing;
    var s = State.init(t.allocator);
    defer s.deinit();

    // Seed one entry so we can prove a good reply really replaces it.
    loadWorkspaces(&s, "[{\"id\":99,\"name\":\"99\",\"monitor\":\"DP-9\"}]");
    try t.expectEqual(@as(usize, 1), s.spaces.items.len);

    const doc = testdata.hyprland.workspaces;
    loadWorkspaces(&s, doc);
    try t.expectEqual(@as(usize, 3), s.spaces.items.len);
    try t.expectEqualStrings("1", s.spaces.items[0].name);
    try t.expectEqualStrings("DP-2", s.spaces.items[1].monitor);
    try t.expectEqual(@as(i32, 3), s.spaces.items[2].id);

    // A reply that is not an array leaves the table untouched.
    loadWorkspaces(&s, "{\"id\":1}");
    loadWorkspaces(&s, "not json at all");
    try t.expectEqual(@as(usize, 3), s.spaces.items.len);

    // Special (negative) workspaces are filtered out, not stored.
    loadWorkspaces(&s, "[{\"id\":-99,\"name\":\"special\",\"monitor\":\"DP-1\"}]");
    try t.expectEqual(@as(usize, 0), s.spaces.items.len);
}

test "hyprland-ws-snapshot: monitor document maps each output to its focus" {
    const t = std.testing;
    var s = State.init(t.allocator);
    defer s.deinit();

    const doc = testdata.hyprland.monitors;
    loadMonitors(&s, doc);
    try t.expectEqual(@as(usize, 3), s.active_map.count());
    try t.expectEqual(@as(i32, 1), s.active_map.get("DP-1").?);
    try t.expectEqual(@as(i32, 2), s.active_map.get("DP-2").?);
    try t.expectEqual(@as(i32, 3), s.active_map.get("DP-3").?);

    // One bad monitor is skipped; the usable one is adopted as a whole map,
    // so the outputs it did not mention are gone — that is what
    // Replace the active map wholesale.
    loadMonitors(&s, "[{\"name\":\"DP-1\",\"activeWorkspace\":{\"id\":\"one\"}},{\"name\":\"DP-2\",\"activeWorkspace\":{\"id\":7}}]");
    try t.expectEqual(@as(usize, 1), s.active_map.count());
    try t.expectEqual(@as(i32, 7), s.active_map.get("DP-2").?);
    try t.expect(s.active_map.get("DP-1") == null);
    try t.expect(s.active_map.get("DP-3") == null);

    // Nothing usable at all: keep what we had instead of clearing it.
    loadMonitors(&s, "[{\"name\":\"\",\"activeWorkspace\":{\"id\":4}}]");
    try t.expectEqual(@as(usize, 1), s.active_map.count());
    loadMonitors(&s, "[]");
    try t.expectEqual(@as(usize, 1), s.active_map.count());
    loadMonitors(&s, "garbage");
    try t.expectEqual(@as(usize, 1), s.active_map.count());
}

test "hyprland-ws-snapshot: client document keys by address and carries urgency" {
    const t = std.testing;
    var s = State.init(t.allocator);
    defer s.deinit();

    const doc = testdata.hyprland.clients;
    loadClients(&s, doc);
    try t.expectEqual(@as(usize, 3), s.windows.count());
    try t.expectEqual(@as(i32, 2), s.windows.get(0x55dc86b61e60).?.workspace_id);
    try t.expectEqualStrings("otter-term", s.windows.get(0x55dc86b61e60).?.app_id);
    try t.expectEqual(@as(i32, 1), s.windows.get(0x55dc865a0340).?.workspace_id);
    try t.expect(!s.windows.get(0x55dc86b61e60).?.urgent); // field absent -> false

    // Re-listing with an explicit urgency takes it, and a second listing with
    // the field missing keeps the value rather than resetting it.
    loadClients(&s, "[{\"address\":\"0x55dc86b61e60\",\"class\":\"x\",\"title\":\"t\",\"urgent\":true,\"workspace\":{\"id\":2}}]");
    try t.expect(s.windows.get(0x55dc86b61e60).?.urgent);
    loadClients(&s, "[{\"address\":\"0x55dc86b61e60\",\"class\":\"x\",\"title\":\"t\",\"workspace\":{\"id\":2}}]");
    try t.expect(s.windows.get(0x55dc86b61e60).?.urgent);

    // Unparseable addresses and duplicate entries are skipped.
    loadClients(&s, "[{\"address\":\"nope\",\"class\":\"x\",\"title\":\"t\"},{\"address\":\"0x1\",\"class\":\"a\",\"title\":\"1\"},{\"address\":\"0x1\",\"class\":\"b\",\"title\":\"2\"}]");
    try t.expectEqual(@as(usize, 1), s.windows.count());
    try t.expectEqualStrings("a", s.windows.get(0x1).?.app_id);

    // A missing class falls back to initialClass.
    loadClients(&s, "[{\"address\":\"0x2\",\"initialClass\":\"fallback\",\"title\":\"t\"}]");
    try t.expectEqualStrings("fallback", s.windows.get(0x2).?.app_id);
}
