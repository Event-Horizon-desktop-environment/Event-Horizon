//! Live media behind the control-center card: MPRIS over the session bus.
//! Picks the first Playing/Paused player, else the first listed one.
//! Transport calls are argument-free method calls; art URLs are returned
//! raw (`file://` is rasterized by the dock, remote URLs show the note).

const std = @import("std");
const live = @import("live.zig");
const wire = @import("../../dbus/wire.zig");
const conn_mod = @import("../../dbus/connection.zig");

pub const mpris_prefix = "org.mpris.MediaPlayer2.";
pub const player_iface = "org.mpris.MediaPlayer2.Player";
pub const root_iface = "org.mpris.MediaPlayer2";
pub const props_iface = "org.freedesktop.DBus.Properties";

pub const Snapshot = struct {
    have_player: bool = false,
    bus_name: []const u8 = "",
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    art_url: []const u8 = "",
    /// The page the track plays from (`xesam:url`): a player with no cover
    /// of its own still offers one through it.
    track_url: []const u8 = "",
    length_us: i64 = 0,
    playing: bool = false,
    can_go_previous: bool = false,
    can_go_next: bool = false,
    can_play_pause: bool = false,
};

fn getProp(conn: *conn_mod.Conn, alloc: std.mem.Allocator, dest: []const u8, path: []const u8, prop: []const u8) ?wire.Value {
    // Clone straight into the caller's allocator (the query's `barena`, alive
    // for the whole query). A local arena here would die on return and the
    // value would dangle again.
    return live.propGet(conn, alloc, dest, path, player_iface, prop) catch null;
}

pub const Queried = struct {
    alloc: std.mem.Allocator,
    snap: Snapshot = .{},

    pub fn init(alloc: std.mem.Allocator) Queried {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Queried) void {
        if (self.snap.bus_name.len > 0) self.alloc.free(self.snap.bus_name);
        if (self.snap.title.len > 0) self.alloc.free(self.snap.title);
        if (self.snap.artist.len > 0) self.alloc.free(self.snap.artist);
        if (self.snap.album.len > 0) self.alloc.free(self.snap.album);
        if (self.snap.art_url.len > 0) self.alloc.free(self.snap.art_url);
        if (self.snap.track_url.len > 0) self.alloc.free(self.snap.track_url);
        self.snap = .{};
    }
};

pub fn query(alloc: std.mem.Allocator) ?Queried {
    var conn = live.openBus(alloc, .session) orelse return null;
    defer conn.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var p = conn.call(.{
        .mtype = .method_call,
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "ListNames",
        .destination = "org.freedesktop.DBus",
    }, 3000) catch return null;
    defer p.deinit();
    if (p.body_vals.len < 1 or p.body_vals[0] != .array) return null;
    // Prefer a Playing player, then Paused, then the firstAdvertised one.
    var first: []const u8 = "";
    var paused: []const u8 = "";
    var playing: []const u8 = "";
    for (p.body_vals[0].array.items) |n| {
        if (n != .string) continue;
        if (!std.mem.startsWith(u8, n.string, mpris_prefix)) continue;
        if (first.len == 0) first = n.string;
        var qarena = std.heap.ArenaAllocator.init(alloc);
        defer qarena.deinit();
        const v = live.propGet(&conn, qarena.allocator(), n.string, "/org/mpris/MediaPlayer2", player_iface, "PlaybackStatus") catch continue;
        const val = v orelse continue;
        if (val != .string) continue;
        if (std.mem.eql(u8, val.string, "Playing")) {
            playing = n.string;
            break;
        }
        if (paused.len == 0 and std.mem.eql(u8, val.string, "Paused")) paused = n.string;
    }
    const chosen = if (playing.len > 0) playing else if (paused.len > 0) paused else first;
    if (chosen.len == 0) return null;
    var q = Queried.init(alloc);
    errdefer q.deinit();
    q.snap.have_player = true;
    q.snap.bus_name = alloc.dupe(u8, chosen) catch return null;

    var barena = std.heap.ArenaAllocator.init(alloc);
    defer barena.deinit();
    const ba = barena.allocator();
    if (getProp(&conn, ba, chosen, "/org/mpris/MediaPlayer2", "PlaybackStatus")) |v| {
        q.snap.playing = v == .string and std.mem.eql(u8, v.string, "Playing");
    }
    if (getProp(&conn, ba, chosen, "/org/mpris/MediaPlayer2", "CanGoNext")) |v| q.snap.can_go_next = live.asBool(v);
    if (getProp(&conn, ba, chosen, "/org/mpris/MediaPlayer2", "CanGoPrevious")) |v| q.snap.can_go_previous = live.asBool(v);
    var can_play = false;
    var can_pause = false;
    if (getProp(&conn, ba, chosen, "/org/mpris/MediaPlayer2", "CanPlay")) |v| can_play = live.asBool(v);
    if (getProp(&conn, ba, chosen, "/org/mpris/MediaPlayer2", "CanPause")) |v| can_pause = live.asBool(v);
    q.snap.can_play_pause = can_play or can_pause;

    // The media widget derives its cover address from these same fields — a
    // private-cache marker is a hash over them — so the caps have to match
    // the media client's (512 text / 2048 URL) or the two sides would spell
    // different addresses for the same track.
    if (getProp(&conn, ba, chosen, "/org/mpris/MediaPlayer2", "Metadata")) |v| {
        if (v == .array) {
            if (live.dictFind(v, "xesam:title")) |t| {
                const s = live.asString(t);
                if (s.len > 0) q.snap.title = alloc.dupe(u8, s[0..@min(s.len, 512)]) catch "";
            }
            if (live.dictFind(v, "xesam:artist")) |a| {
                var tmp: [1024]u8 = undefined;
                const s = live.strListInto(a, &tmp);
                if (s.len > 0) q.snap.artist = alloc.dupe(u8, s[0..@min(s.len, 512)]) catch "";
            }
            if (live.dictFind(v, "mpris:artUrl")) |a| {
                const s = live.asString(a);
                if (s.len > 0) q.snap.art_url = alloc.dupe(u8, s[0..@min(s.len, 2048)]) catch "";
            }
            if (live.dictFind(v, "xesam:album")) |a| {
                const s = live.asString(a);
                if (s.len > 0) q.snap.album = alloc.dupe(u8, s[0..@min(s.len, 512)]) catch "";
            }
            if (live.dictFind(v, "xesam:url")) |u| {
                const s = live.asString(u);
                if (s.len > 0) q.snap.track_url = alloc.dupe(u8, s[0..@min(s.len, 2048)]) catch "";
            }
            if (live.dictFind(v, "mpris:length")) |l| {
                q.snap.length_us = switch (l) {
                    .int64 => |x| x,
                    .uint64 => |x| if (x > std.math.maxInt(i64)) 0 else @intCast(x),
                    else => 0,
                };
            }
        }
    }
    return q;
}

pub const Transport = enum { previous, toggle, next };

pub fn transport(alloc: std.mem.Allocator, bus_name: []const u8, what: Transport) bool {
    if (bus_name.len == 0) return false;
    var conn = live.openBus(alloc, .session) orelse return false;
    defer conn.deinit();
    const member: []const u8 = switch (what) {
        .previous => "Previous",
        .toggle => "PlayPause",
        .next => "Next",
    };
    return live.callNoArgs(&conn, bus_name, "/org/mpris/MediaPlayer2", player_iface, member, 3000);
}

/// `file://` art URL → filesystem path (percent-decoded), owned by caller.
/// Returns null for remote/odd schemes (the card keeps its note glyph).
pub fn artFilePath(alloc: std.mem.Allocator, url: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, url, "file://")) return null;
    var path = url[7..];
    // Strip a `localhost` host prefix.
    if (std.mem.startsWith(u8, path, "localhost/")) path = path[9..];
    const out = alloc.alloc(u8, path.len) catch return null;
    errdefer alloc.free(out);
    var n: usize = 0;
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '%' and i + 2 < path.len) {
            const hi = std.fmt.charToDigit(path[i + 1], 16) catch {
                out[n] = path[i];
                n += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(path[i + 2], 16) catch {
                out[n] = path[i];
                n += 1;
                i += 1;
                continue;
            };
            out[n] = hi * 16 + lo;
            n += 1;
            i += 3;
        } else {
            out[n] = path[i];
            n += 1;
            i += 1;
        }
    }
    // Shrink to the decoded length so the caller frees exactly this.
    if (alloc.realloc(out, n)) |exact| return exact else |_| {
        defer alloc.free(out);
        return alloc.dupe(u8, out[0..n]) catch null;
    }
}

test "live-media: art path decoding" {
    const t = std.testing;
    const p = artFilePath(t.allocator, "file:///home/u/Music/cover%20art.png") orelse return error.TestUnexpectedResult;
    defer t.allocator.free(p);
    try t.expectEqualStrings("/home/u/Music/cover art.png", p);
    try t.expect(artFilePath(t.allocator, "https://x/y.jpg") == null);
    const l = artFilePath(t.allocator, "file://localhost/home/u/a.png") orelse return error.TestUnexpectedResult;
    defer t.allocator.free(l);
    try t.expectEqualStrings("/home/u/a.png", l);
}
