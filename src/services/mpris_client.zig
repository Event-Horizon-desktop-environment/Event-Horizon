//! Which media player is speaking for the dock, what it is playing, and the
//! calls that drive it. One persistent session bus connection is kept open
//! and reused across polls, so the 400 ms cadence the media widget needs
//! costs a handful of round trips rather than a fresh socket handshake.
//!
//! Everything another program writes is copied through a fixed-size lens
//! before it reaches the shell: a badly behaved player must not be able to
//! make the shell allocate without bound.

const std = @import("std");
const conn_mod = @import("../dbus/connection.zig");
const wire = @import("../dbus/wire.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const service_prefix = "org.mpris.MediaPlayer2.";
pub const player_path = "/org/mpris/MediaPlayer2";
pub const root_iface = "org.mpris.MediaPlayer2";
pub const player_iface = "org.mpris.MediaPlayer2.Player";
pub const props_iface = "org.freedesktop.DBus.Properties";

const cap_text: usize = 512;
const cap_url: usize = 2048;
const cap_status: usize = 24;
const max_players: usize = 16;
const max_name: usize = 256;

/// What the dock needs to know about one player. Every string borrows from
/// the `Client` it came from and is dropped when the next poll replaces it.
pub const Snapshot = struct {
    have_player: bool = false,
    bus_name: []const u8 = "",
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    art_url: []const u8 = "",
    track_url: []const u8 = "",
    track_id: []const u8 = "",
    status: []const u8 = "",
    loop_status: []const u8 = "",
    can_go_next: bool = false,
    can_go_previous: bool = false,
    can_play: bool = false,
    can_pause: bool = false,
    shuffle: bool = false,
    position_us: i64 = 0,
    duration_us: i64 = 0,

    pub fn playing(self: *const Snapshot) bool {
        return std.mem.eql(u8, self.status, "Playing");
    }

    pub fn paused(self: *const Snapshot) bool {
        return std.mem.eql(u8, self.status, "Paused");
    }

    /// Whether the pill has a track to describe. A player with neither a
    /// title nor an artist leaves the pill in its resting shape.
    pub fn realActive(self: *const Snapshot) bool {
        return self.have_player and (self.title.len > 0 or self.artist.len > 0);
    }

    /// The position is live between polls, so it is deliberately kept out of
    /// the change signature: a moving track must not reflow the dock strip.
    pub fn signature(self: *const Snapshot) u64 {
        var h = std.hash.Wyhash.init(0x5eed);
        feed(&h, self.bus_name);
        feed(&h, self.title);
        feed(&h, self.artist);
        feed(&h, self.album);
        feed(&h, self.art_url);
        feed(&h, self.track_id);
        feed(&h, self.status);
        feed(&h, self.loop_status);
        feed(&h, std.mem.asBytes(&self.can_go_next));
        feed(&h, std.mem.asBytes(&self.can_go_previous));
        feed(&h, std.mem.asBytes(&self.can_play));
        feed(&h, std.mem.asBytes(&self.can_pause));
        feed(&h, std.mem.asBytes(&self.shuffle));
        feed(&h, std.mem.asBytes(&self.duration_us));
        return h.final();
    }
};

pub const Action = enum { play_pause, next, previous };

pub const Client = struct {
    alloc: std.mem.Allocator,
    conn: conn_mod.Conn,
    /// Backing store for the strings in `snap`, dropped and rebuilt on every
    /// poll that changes something.
    store: std.heap.ArenaAllocator,
    snap: Snapshot = .{},
    sig: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) Client {
        return .{
            .alloc = alloc,
            .conn = conn_mod.Conn.init(alloc),
            .store = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Client) void {
        self.conn.deinit();
        self.store.deinit();
        self.snap = .{};
    }

    /// Refresh `snap` from the bus. Returns true when anything the widgets
    /// size themselves from changed since the previous poll, which is the
    /// signal for the dock to re-measure and redraw.
    pub fn poll(self: *Client) bool {
        var names: [max_players][max_name]u8 = undefined;
        var name_lens: [max_players]usize = undefined;
        const count = self.listPlayers(&names, &name_lens);
        if (count == 0) return self.publish(.{});
        if (!self.ensure()) return false;

        var best: usize = 0;
        var best_rank: i32 = -1;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const rank = self.statusRank(names[i][0..name_lens[i]]);
            if (rank > best_rank) {
                best_rank = rank;
                best = i;
            }
            if (best_rank >= 2) break;
        }

        self.store.deinit();
        self.store = std.heap.ArenaAllocator.init(self.alloc);
        self.snap = .{};
        self.snap.have_player = true;
        self.snap.bus_name = self.store.allocator().dupe(u8, names[best][0..name_lens[best]]) catch return false;
        self.absorbPlayer();

        const sig = self.snap.signature();
        const changed = sig != self.sig;
        self.sig = sig;
        return changed;
    }

    /// Hand back an empty snapshot, e.g. when the last player went away.
    fn publish(self: *Client, fresh: Snapshot) bool {
        self.store.deinit();
        self.store = std.heap.ArenaAllocator.init(self.alloc);
        self.snap = fresh;
        const sig = self.snap.signature();
        const changed = sig != self.sig;
        self.sig = sig;
        return changed;
    }

    fn ensure(self: *Client) bool {
        if (self.conn.fd >= 0) return true;
        var addr_buf: [512]u8 = undefined;
        const address: []const u8 = blk: {
            if (envStr("DBUS_SESSION_BUS_ADDRESS")) |a| break :blk a;
            break :blk std.fmt.bufPrint(&addr_buf, "unix:path=/run/user/{d}/bus", .{std.os.linux.getuid()}) catch "";
        };
        if (address.len == 0) return false;
        self.conn.connect(address) catch return false;
        self.conn.hello() catch {
            self.conn.deinit();
            self.conn = conn_mod.Conn.init(self.alloc);
            return false;
        };
        return true;
    }

    fn listPlayers(
        self: *Client,
        names: *[max_players][max_name]u8,
        name_lens: *[max_players]usize,
    ) usize {
        if (!self.ensure()) return 0;
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "ListNames",
            .destination = "org.freedesktop.DBus",
        }, 1500) catch return 0;
        defer p.deinit();
        if (p.body_vals.len < 1 or p.body_vals[0] != .array) return 0;
        var count: usize = 0;
        for (p.body_vals[0].array.items) |v| {
            if (v != .string) continue;
            if (!std.mem.startsWith(u8, v.string, service_prefix)) continue;
            if (v.string.len >= max_name) continue;
            if (count >= max_players) break;
            @memcpy(names[count][0..v.string.len], v.string);
            name_lens[count] = v.string.len;
            count += 1;
        }
        return count;
    }

    /// 2 while Playing, 1 while Paused, 0 for any other state, -1 when the
    /// player did not answer.
    fn statusRank(self: *Client, dest: []const u8) i32 {
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = player_path,
            .interface = props_iface,
            .member = "Get",
            .destination = dest,
            .signature = "ss",
            .body = &.{ .{ .string = player_iface }, .{ .string = "PlaybackStatus" } },
        }, 1200) catch return -1;
        defer p.deinit();
        if (p.body_vals.len < 1 or p.body_vals[0] != .variant) return -1;
        const v = p.body_vals[0].variant.val.*;
        if (v != .string) return -1;
        if (std.mem.eql(u8, v.string, "Playing")) return 2;
        if (std.mem.eql(u8, v.string, "Paused")) return 1;
        return 0;
    }

    /// Pull the whole player property block in one round trip and fold it
    /// into `snap`. `p` stays alive for the whole copy, so nothing escapes
    /// into freed reply memory.
    fn absorbPlayer(self: *Client) void {
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = player_path,
            .interface = props_iface,
            .member = "GetAll",
            .destination = self.snap.bus_name,
            .signature = "s",
            .body = &.{.{ .string = player_iface }},
        }, 2000) catch return;
        defer p.deinit();
        if (p.body_vals.len < 1 or p.body_vals[0] != .array) return;
        const sa = self.store.allocator();
        for (p.body_vals[0].array.items) |entry| {
            if (entry != .structure or entry.structure.len < 2) continue;
            const key_v = entry.structure[0];
            if (key_v != .string or key_v.string.len == 0) continue;
            const val = entry.structure[1];
            if (val != .variant) continue;
            const inner = val.variant.val.*;
            const key = key_v.string;
            if (std.mem.eql(u8, key, "Metadata")) {
                absorbMetadata(&self.snap, sa, inner);
            } else if (std.mem.eql(u8, key, "PlaybackStatus")) {
                self.snap.status = takeText(sa, inner, cap_status);
            } else if (std.mem.eql(u8, key, "LoopStatus")) {
                self.snap.loop_status = takeText(sa, inner, cap_status);
            } else if (std.mem.eql(u8, key, "CanGoNext")) {
                self.snap.can_go_next = takeBool(inner);
            } else if (std.mem.eql(u8, key, "CanGoPrevious")) {
                self.snap.can_go_previous = takeBool(inner);
            } else if (std.mem.eql(u8, key, "CanPlay")) {
                self.snap.can_play = takeBool(inner);
            } else if (std.mem.eql(u8, key, "CanPause")) {
                self.snap.can_pause = takeBool(inner);
            } else if (std.mem.eql(u8, key, "Shuffle")) {
                self.snap.shuffle = takeBool(inner);
            } else if (std.mem.eql(u8, key, "Position")) {
                self.snap.position_us = takeInt(inner);
            }
        }
    }

    pub fn act(self: *Client, what: Action) bool {
        const member: []const u8 = switch (what) {
            .play_pause => "PlayPause",
            .next => "Next",
            .previous => "Previous",
        };
        return self.noArgs(member);
    }

    fn noArgs(self: *Client, member: []const u8) bool {
        if (!self.ensure()) return false;
        if (self.snap.bus_name.len == 0) return false;
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = player_path,
            .interface = player_iface,
            .member = member,
            .destination = self.snap.bus_name,
        }, 2000) catch return false;
        defer p.deinit();
        return p.msg.mtype == .method_return;
    }

    /// Jump the track to `us`, addressed by the current track's object path.
    pub fn seek(self: *Client, us: i64) bool {
        if (!self.ensure()) return false;
        if (self.snap.bus_name.len == 0 or self.snap.track_id.len == 0) return false;
        var body: [2]wire.Value = .{
            .{ .object_path = self.snap.track_id },
            .{ .int64 = us },
        };
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = player_path,
            .interface = player_iface,
            .member = "SetPosition",
            .destination = self.snap.bus_name,
            .signature = "ox",
            .body = &body,
        }, 2000) catch return false;
        defer p.deinit();
        return p.msg.mtype == .method_return;
    }

    pub fn setShuffle(self: *Client, on: bool) bool {
        return self.setProp("Shuffle", "b", .{ .boolean = on });
    }

    /// Walk the MPRIS loop states: None -> Playlist -> Track -> None.
    pub fn cycleLoop(self: *Client) bool {
        const next: []const u8 = if (std.mem.eql(u8, self.snap.loop_status, "Track"))
            "None"
        else if (std.mem.eql(u8, self.snap.loop_status, "Playlist"))
            "Track"
        else
            "Playlist";
        return self.setProp("LoopStatus", "s", .{ .string = next });
    }

    fn setProp(self: *Client, prop: []const u8, vsig: []const u8, v: wire.Value) bool {
        if (!self.ensure()) return false;
        if (self.snap.bus_name.len == 0) return false;
        var inner = v;
        var body: [3]wire.Value = .{
            .{ .string = player_iface },
            .{ .string = prop },
            .{ .variant = .{ .sig = vsig, .val = &inner } },
        };
        var p = self.conn.call(.{
            .mtype = .method_call,
            .path = player_path,
            .interface = props_iface,
            .member = "Set",
            .destination = self.snap.bus_name,
            .signature = "ssv",
            .body = &body,
        }, 2000) catch return false;
        defer p.deinit();
        return p.msg.mtype == .method_return;
    }
};

fn feed(h: *std.hash.Wyhash, bytes: []const u8) void {
    h.update(bytes);
    h.update(&.{0xff});
}

fn absorbMetadata(snap: *Snapshot, into: std.mem.Allocator, v: wire.Value) void {
    if (v != .array) return;
    for (v.array.items) |m| {
        if (m != .structure or m.structure.len < 2) continue;
        const key_v = m.structure[0];
        if (key_v != .string or key_v.string.len == 0) continue;
        const val = m.structure[1];
        if (val != .variant) continue;
        const inner = val.variant.val.*;
        const key = key_v.string;
        if (std.mem.eql(u8, key, "xesam:title")) {
            snap.title = takeText(into, inner, cap_text);
        } else if (std.mem.eql(u8, key, "xesam:album")) {
            snap.album = takeText(into, inner, cap_text);
        } else if (std.mem.eql(u8, key, "xesam:artist")) {
            snap.artist = takeList(into, inner, cap_text);
        } else if (std.mem.eql(u8, key, "mpris:artUrl")) {
            snap.art_url = takeText(into, inner, cap_url);
        } else if (std.mem.eql(u8, key, "xesam:url")) {
            snap.track_url = takeText(into, inner, cap_url);
        } else if (std.mem.eql(u8, key, "mpris:trackid")) {
            snap.track_id = takeText(into, inner, cap_text);
        } else if (std.mem.eql(u8, key, "mpris:length")) {
            snap.duration_us = takeInt(inner);
        }
    }
}

/// Copy one string-typed value into `into`, capped at `cap` bytes.
fn takeText(into: std.mem.Allocator, v: wire.Value, cap: usize) []const u8 {
    const s: []const u8 = switch (v) {
        .string => |s| s,
        .object_path => |s| s,
        else => "",
    };
    if (s.len == 0) return "";
    return into.dupe(u8, s[0..@min(s.len, cap)]) catch "";
}

/// Join a string array into one line, e.g. several artists on one track.
fn takeList(into: std.mem.Allocator, v: wire.Value, cap: usize) []const u8 {
    if (v != .array) return "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(into);
    var total: usize = 0;
    for (v.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        if (total >= cap) break;
        const piece = item.string[0..@min(item.string.len, cap - total)];
        if (out.items.len > 0) {
            out.append(into, ' ') catch break;
            out.append(into, '-') catch break;
            out.append(into, ' ') catch break;
        }
        out.appendSlice(into, piece) catch break;
        total += piece.len + 3;
    }
    return into.dupe(u8, out.items) catch "";
}

fn takeBool(v: wire.Value) bool {
    return switch (v) {
        .boolean => |b| b,
        else => false,
    };
}

fn takeInt(v: wire.Value) i64 {
    return switch (v) {
        .int64 => |i| i,
        .uint64 => |i| @intCast(i),
        .int32 => |i| i,
        .uint32 => |i| i,
        else => 0,
    };
}

fn envStr(key: [:0]const u8) ?[]const u8 {
    const p = getenv(key) orelse return null;
    return std.mem.span(p);
}

test "mpris client: an empty bus publishes a quiet snapshot" {
    const t = std.testing;
    var c = Client.init(t.allocator);
    defer c.deinit();
    _ = c.publish(.{});
    try t.expect(!c.snap.have_player);
    try t.expect(!c.snap.realActive());
    try t.expect(!c.snap.playing());
}
