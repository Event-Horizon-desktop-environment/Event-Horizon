const std = @import("std");
const wire = @import("../dbus/wire.zig");

pub const PlayerState = enum { stopped, playing, paused };

pub fn parsePlaybackStatus(s: []const u8) PlayerState {
    if (std.mem.eql(u8, s, "Playing")) return .playing;
    if (std.mem.eql(u8, s, "Paused")) return .paused;
    return .stopped;
}

pub const Track = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    art_url: []const u8 = "",
    length_us: i64 = 0,
};

pub fn trackString(map: []const wire.Value, key: []const u8) []const u8 {
    for (map) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        if (v.variant.val.* == .string) return v.variant.val.string;
    }
    return "";
}

pub fn trackStringList(map: []const wire.Value, key: []const u8, buf: []u8) []const u8 {
    for (map) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, key)) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        if (v.variant.val.* == .array) {
            var pos: usize = 0;
            for (v.variant.val.array.items) |item| {
                if (item != .string) continue;
                if (pos > 0 and pos < buf.len) {
                    buf[pos] = ',';
                    pos += 1;
                }
                const n = @min(item.string.len, buf.len - pos);
                @memcpy(buf[pos .. pos + n], item.string[0..n]);
                pos += n;
                if (pos >= buf.len) break;
            }
            return buf[0..pos];
        }
    }
    return "";
}

pub fn trackLength(map: []const wire.Value) i64 {
    for (map) |entry| {
        if (entry != .structure or entry.structure.len != 2) continue;
        if (entry.structure[0] != .string) continue;
        if (!std.mem.eql(u8, entry.structure[0].string, "mpris:length")) continue;
        const v = entry.structure[1];
        if (v != .variant) continue;
        if (v.variant.val.* == .int64) return v.variant.val.int64;
        if (v.variant.val.* == .uint64) return @intCast(v.variant.val.uint64);
    }
    return 0;
}

pub const Player = struct {
    bus_name: []const u8 = "",
    state: PlayerState = .stopped,
    track: Track = .{},
    position_us: i64 = 0,
};

test "mpris: metadata helpers" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const mkv = struct {
        fn v(a: std.mem.Allocator, s: []const u8, val: wire.Value) !wire.Value {
            const p = try a.alloc(wire.Value, 2);
            p[0] = .{ .string = s };
            const b = try a.create(wire.Value);
            b.* = val;
            const sig: []const u8 = switch (val) {
                .string => "s",
                .int64 => "x",
                else => "v",
            };
            p[1] = .{ .variant = .{ .sig = sig, .val = b } };
            return .{ .structure = p };
        }
    };
    const artists = try aa.alloc(wire.Value, 1);
    artists[0] = .{ .string = "A" };
    const ab = try aa.create(wire.Value);
    ab.* = .{ .array = .{ .elem = "s", .items = artists } };
    const ap = try aa.alloc(wire.Value, 2);
    ap[0] = .{ .string = "xesam:artist" };
    ap[1] = .{ .variant = .{ .sig = "as", .val = ab } };
    const map = try aa.alloc(wire.Value, 3);
    map[0] = try mkv.v(aa, "xesam:title", .{ .string = "Song" });
    map[1] = .{ .structure = ap };
    map[2] = try mkv.v(aa, "mpris:length", .{ .int64 = 180000000 });
    try t.expectEqualStrings("Song", trackString(map, "xesam:title"));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("A", trackStringList(map, "xesam:artist", &buf));
    try t.expectEqual(@as(i64, 180000000), trackLength(map));
    try t.expectEqual(PlayerState.playing, parsePlaybackStatus("Playing"));
    try t.expectEqual(PlayerState.stopped, parsePlaybackStatus("Stopped"));
}
