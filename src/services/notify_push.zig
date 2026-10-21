//! Outbound `notify.push` — the producer half of the notification IPC
//! contract. Consumers (the dock's media
//! poll, the settings test button path) publish framed payloads; the
//! `horizon-notifications` daemon owns the authoritative state.
//!
//! Payloads: fields joined with `\x1e`; composite keys with `\x1f` (a raw
//! art tail may contain `\x1e`, so the daemon parses it positionally).
//! Cover art goes out box-downscaled to `art_max_dim` with a 32-byte
//! little-endian header, because client→server SCM_RIGHTS is not
//! implemented and frames cap at 1 MiB.
//!
//! The dock's covers are cairo-premultiplied B,G,R,A; the blob carries
//! straight R,G,B,A, so encode un-premultiplies (+BGR→RGB swap) while
//! sampling. eh-free: the dock and the settings app both use this.

const std = @import("std");
const ipc_client = @import("../ipc_client.zig");

pub const push_topic = "notify.push";
pub const field_sep: u8 = 0x1e;
pub const key_sep: u8 = 0x1f;
pub const art_max_dim: i32 = 160;

/// `bus_name\x1ftitle\x1fartist` — the daemon's entry key.
pub fn trackKey(alloc: std.mem.Allocator, bus: []const u8, title: []const u8, artist: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\x1f{s}\x1f{s}", .{ bus, title, artist });
}

pub fn encodeInternal(alloc: std.mem.Allocator, app: []const u8, summary: []const u8, body: []const u8, urgency: i32) ![]u8 {
    return std.fmt.allocPrint(alloc, "internal\x1e{s}\x1e{s}\x1e{s}\x1e{d}", .{ app, summary, body, urgency });
}

pub fn encodeMpris(alloc: std.mem.Allocator, key: []const u8, summary: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "mpris\x1e{s}\x1e{s}\x1e{s}", .{ key, summary, body });
}

fn writeI32(dst: []u8, off: usize, v: i32) void {
    std.mem.writeInt(i32, dst[off..][0..4], v, .little);
}

/// Decoded blob, pixels owned. Mirrors the daemon's read side exactly.
pub const RawBlob = struct {
    width: i32,
    height: i32,
    stride: i32,
    has_alpha: bool,
    channels: i32,
    pixels: []u8,
};

/// Validate + copy a blob the daemon (or a test) received. Null on short
/// headers, absurd dimensions, non-8-bit or non-RGB(A) data, or a length
/// overrun — never a partial image.
pub fn deserializeBlob(alloc: std.mem.Allocator, blob: []const u8) ?RawBlob {
    if (blob.len < 32) return null;
    const w = std.mem.readInt(i32, blob[0..][0..4], .little);
    const h = std.mem.readInt(i32, blob[4..][0..4], .little);
    const stride = std.mem.readInt(i32, blob[8..][0..4], .little);
    const has_alpha = std.mem.readInt(i32, blob[12..][0..4], .little) != 0;
    const bps = std.mem.readInt(i32, blob[16..][0..4], .little);
    const ch = std.mem.readInt(i32, blob[20..][0..4], .little);
    const len = std.mem.readInt(u64, blob[24..][0..8], .little);
    if (w <= 0 or h <= 0 or w > art_max_dim * 4 or h > art_max_dim * 4) return null;
    if (bps != 8 or (ch != 3 and ch != 4)) return null;
    if (len > blob.len - 32) return null;
    const px = alloc.dupe(u8, blob[32 .. 32 + len]) catch return null;
    return .{ .width = w, .height = h, .stride = stride, .has_alpha = has_alpha, .channels = ch, .pixels = px };
}

pub const SmallImage = struct {
    width: i32,
    height: i32,
    pixels: []u8, // packed straight RGBA, owned
};

/// Normalize to packed straight RGBA (≤`art_max_dim`, box average). Used by
/// the sender before framing and by the daemon on receipt — one algorithm,
/// so both ends agree pixel for pixel.
pub fn toRgba(alloc: std.mem.Allocator, w: i32, h: i32, stride: i32, channels: i32, pixels: []const u8) ?SmallImage {
    if (w <= 0 or h <= 0) return null;
    const src_pb: usize = @intCast(channels);
    const src_stride: usize = if (stride > 0) @as(usize, @intCast(stride)) else @as(usize, @intCast(w)) * src_pb;
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    if (pixels.len < (sh - 1) * src_stride + sw * src_pb) return null;
    const scale: f64 = @min(
        @as(f64, @floatFromInt(art_max_dim)) / @as(f64, @floatFromInt(w)),
        @as(f64, @floatFromInt(art_max_dim)) / @as(f64, @floatFromInt(h)),
    );
    var dw: usize = sw;
    var dh: usize = sh;
    if (scale < 1.0) {
        dw = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale))));
        dh = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * scale))));
    }
    const out = alloc.alloc(u8, dw * dh * 4) catch return null;
    errdefer alloc.free(out);
    var y: usize = 0;
    while (y < dh) : (y += 1) {
        const y0 = (y * sh) / dh;
        const y1 = @max(y0 + 1, ((y + 1) * sh) / dh);
        var x: usize = 0;
        while (x < dw) : (x += 1) {
            const x0 = (x * sw) / dw;
            const x1 = @max(x0 + 1, ((x + 1) * sw) / dw);
            var r: u64 = 0;
            var g: u64 = 0;
            var b: u64 = 0;
            var al: u64 = 0;
            var sy: usize = y0;
            while (sy < y1) : (sy += 1) {
                var sx: usize = x0;
                while (sx < x1) : (sx += 1) {
                    const so = sy * src_stride + sx * src_pb;
                    r += pixels[so + 0];
                    g += pixels[so + 1];
                    b += pixels[so + 2];
                    al += if (src_pb >= 4) pixels[so + 3] else 255;
                }
            }
            const nn: u64 = @max(1, (y1 - y0) * (x1 - x0));
            const doff = (y * dw + x) * 4;
            out[doff + 0] = @intCast(r / nn);
            out[doff + 1] = @intCast(g / nn);
            out[doff + 2] = @intCast(b / nn);
            out[doff + 3] = @intCast(al / nn);
        }
    }
    return .{ .width = @intCast(dw), .height = @intCast(dh), .pixels = out };
}

/// Downscale cairo-premultiplied BGRA → straight RGBA blob (≤160px) with
/// the 32-byte header the daemon's deserializer reads. Null on empty or
/// absurd input; the caller then simply sends no art.
pub fn encodeMprisArt(alloc: std.mem.Allocator, key: []const u8, bgra: []const u8, w: i32, h: i32) ![]u8 {
    if (w <= 0 or h <= 0) return error.InvalidArt;
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    if (bgra.len < sw * sh * 4) return error.InvalidArt;
    const scale: f64 = @min(
        @as(f64, @floatFromInt(art_max_dim)) / @as(f64, @floatFromInt(w)),
        @as(f64, @floatFromInt(art_max_dim)) / @as(f64, @floatFromInt(h)),
    );
    var dw: usize = sw;
    var dh: usize = sh;
    if (scale < 1.0) {
        dw = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale))));
        dh = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * scale))));
    }
    const px = try alloc.alloc(u8, dw * dh * 4);
    errdefer alloc.free(px);
    var y: usize = 0;
    while (y < dh) : (y += 1) {
        const y0 = (y * sh) / dh;
        const y1 = @max(y0 + 1, ((y + 1) * sh) / dh);
        var x: usize = 0;
        while (x < dw) : (x += 1) {
            const x0 = (x * sw) / dw;
            const x1 = @max(x0 + 1, ((x + 1) * sw) / dw);
            var r: u64 = 0;
            var g: u64 = 0;
            var b: u64 = 0;
            var al: u64 = 0;
            var sy: usize = y0;
            while (sy < y1) : (sy += 1) {
                var sx: usize = x0;
                while (sx < x1) : (sx += 1) {
                    const so = (sy * sw + sx) * 4;
                    const sb = bgra[so + 0];
                    const sg = bgra[so + 1];
                    const sr = bgra[so + 2];
                    const sa = bgra[so + 3];
                    if (sa == 0) continue;
                    // Straighten + swap to RGB while averaging.
                    r += @as(u64, sr) * 255 / sa;
                    g += @as(u64, sg) * 255 / sa;
                    b += @as(u64, sb) * 255 / sa;
                    al += sa;
                }
            }
            const nn: u64 = @max(1, (y1 - y0) * (x1 - x0));
            const doff = (y * dw + x) * 4;
            // Average alpha first; premultiplied-then-straightened colors
            // average correctly against it.
            const aa: u64 = al / nn;
            px[doff + 0] = @intCast(if (nn == 0) 0 else r / nn);
            px[doff + 1] = @intCast(if (nn == 0) 0 else g / nn);
            px[doff + 2] = @intCast(if (nn == 0) 0 else b / nn);
            px[doff + 3] = @intCast(@min(aa, 255));
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "mpris-art\x1e");
    try out.appendSlice(alloc, key);
    try out.append(alloc, field_sep);
    const hdr_off = out.items.len;
    try out.appendNTimes(alloc, 0, 32);
    const hdr = out.items[hdr_off .. hdr_off + 32];
    writeI32(hdr, 0, @intCast(dw));
    writeI32(hdr, 4, @intCast(dh));
    writeI32(hdr, 8, @as(i32, @intCast(dw)) * 4);
    writeI32(hdr, 12, 1);
    writeI32(hdr, 16, 8);
    writeI32(hdr, 20, 4);
    std.mem.writeInt(u64, hdr[24..32], @intCast(px.len), .little);
    try out.appendSlice(alloc, px);
    alloc.free(px);
    return out.toOwnedSlice(alloc);
}

/// Persistent sender with lazy connect (30 s retry throttle). One per
/// process. A daemon restart is
/// survived: the next push reconnects.
pub const Publisher = struct {
    alloc: std.mem.Allocator,
    client: ipc_client.Client,
    sock_path: ?[]u8 = null,
    last_try_ms: i64 = 0,
    /// Payload bytes of the last successful publish (bench accounting).
    last_bytes: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) Publisher {
        return .{ .alloc = alloc, .client = ipc_client.Client.init(alloc) };
    }

    pub fn deinit(self: *Publisher) void {
        if (self.sock_path) |p| self.alloc.free(p);
        self.client.deinit();
    }

    fn ensure(self: *Publisher, now_ms: i64, eh_ipc_socket: ?[]const u8, xdg_runtime: ?[]const u8) bool {
        if (self.client.connected()) return true;
        if (now_ms - self.last_try_ms < 30_000) return false;
        self.last_try_ms = now_ms;
        if (self.sock_path == null) {
            self.sock_path = ipc_client.socketPathFor(self.alloc, eh_ipc_socket, xdg_runtime) catch return false;
        }
        return self.client.connect(self.sock_path.?, 2);
    }

    pub fn pushInternal(
        self: *Publisher,
        now_ms: i64,
        eh_ipc_socket: ?[]const u8,
        xdg_runtime: ?[]const u8,
        app: []const u8,
        summary: []const u8,
        body: []const u8,
        urgency: i32,
    ) bool {
        if (!self.ensure(now_ms, eh_ipc_socket, xdg_runtime)) return false;
        const payload = encodeInternal(self.alloc, app, summary, body, urgency) catch return false;
        defer self.alloc.free(payload);
        const ok = self.client.publish(push_topic, payload);
        if (ok) self.last_bytes = payload.len;
        return ok;
    }

    pub fn pushMpris(
        self: *Publisher,
        now_ms: i64,
        eh_ipc_socket: ?[]const u8,
        xdg_runtime: ?[]const u8,
        key: []const u8,
        summary: []const u8,
        body: []const u8,
    ) bool {
        if (!self.ensure(now_ms, eh_ipc_socket, xdg_runtime)) return false;
        const payload = encodeMpris(self.alloc, key, summary, body) catch return false;
        defer self.alloc.free(payload);
        const ok = self.client.publish(push_topic, payload);
        if (ok) self.last_bytes = payload.len;
        return ok;
    }

    pub fn pushMprisArt(
        self: *Publisher,
        now_ms: i64,
        eh_ipc_socket: ?[]const u8,
        xdg_runtime: ?[]const u8,
        key: []const u8,
        bgra: []const u8,
        w: i32,
        h: i32,
    ) bool {
        if (!self.ensure(now_ms, eh_ipc_socket, xdg_runtime)) return false;
        const payload = encodeMprisArt(self.alloc, key, bgra, w, h) catch return false;
        defer self.alloc.free(payload);
        const ok = self.client.publish(push_topic, payload);
        if (ok) self.last_bytes = payload.len;
        return ok;
    }
};

test "notify-push: encoders match the daemon parser shapes" {
    const t = std.testing;
    const a = t.allocator;
    const k = try trackKey(a, "bus", "Title", "Artist");
    defer a.free(k);
    try t.expectEqualStrings("bus\x1fTitle\x1fArtist", k);
    const p1 = try encodeInternal(a, "app", "s", "b", 2);
    defer a.free(p1);
    try t.expectEqualStrings("internal\x1eapp\x1es\x1eb\x1e2", p1);
    const p2 = try encodeMpris(a, k, "s", "b");
    defer a.free(p2);
    try t.expect(std.mem.startsWith(u8, p2, "mpris\x1e"));
    // 2x2 premult BGRA → 2x2 straight RGBA blob (no downscale at this size).
    var px = [_]u8{
        0, 0, 255, 255, 0, 255, 0, 255,
        255, 0, 0, 255, 0, 0, 0, 0,
    };
    const art = try encodeMprisArt(a, k, &px, 2, 2);
    defer a.free(art);
    try t.expect(std.mem.startsWith(u8, art, "mpris-art\x1e"));
    const sep = std.mem.indexOfScalar(u8, art, field_sep) orelse return error.TestUnexpectedResult;
    // Header sits 32 bytes after "key\x1e".
    const hstart = sep + 1 + k.len + 1;
    try t.expectEqual(@as(i32, 2), std.mem.readInt(i32, art[hstart..][0..4], .little));
    try t.expectEqual(@as(i32, 2), std.mem.readInt(i32, art[hstart..][4..8], .little));
    try t.expectEqual(@as(u64, 16), std.mem.readInt(u64, art[hstart..][24..32], .little));
    // First pixel: BGR(0,0,255,255) premult → RGB(255,0,0,255).
    const d0 = hstart + 32;
    try t.expectEqual(@as(u8, 255), art[d0]);
    try t.expectEqual(@as(u8, 0), art[d0 + 1]);
    try t.expectEqual(@as(u8, 0), art[d0 + 2]);
    try t.expectEqual(@as(u8, 255), art[d0 + 3]);
}

test "notify-push: art blob round-trips sender to receiver" {
    const t = std.testing;
    const a = t.allocator;
    // 4x4 straight RGBA (receiver-side format): red gradient + opaque.
    var straight = [_]u8{0} ** (4 * 4 * 4);
    for (0..16) |i| {
        straight[i * 4 + 0] = @intCast(i * 16);
        straight[i * 4 + 1] = 0;
        straight[i * 4 + 2] = 0;
        straight[i * 4 + 3] = 255;
    }
    // Frame it the way the daemon receives it: header + bytes.
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(a);
    try framed.appendNTimes(a, 0, 32);
    const hdr = framed.items[0..32];
    std.mem.writeInt(i32, hdr[0..][0..4], 4, .little);
    std.mem.writeInt(i32, hdr[4..][0..4], 4, .little);
    std.mem.writeInt(i32, hdr[8..][0..4], 16, .little);
    std.mem.writeInt(i32, hdr[12..][0..4], 1, .little);
    std.mem.writeInt(i32, hdr[16..][0..4], 8, .little);
    std.mem.writeInt(i32, hdr[20..][0..4], 4, .little);
    std.mem.writeInt(u64, hdr[24..][0..8], 64, .little);
    try framed.appendSlice(a, &straight);
    const raw = deserializeBlob(a, framed.items) orelse return error.TestUnexpectedResult;
    defer a.free(raw.pixels);
    try t.expectEqual(@as(i32, 4), raw.width);
    const small = toRgba(a, raw.width, raw.height, raw.stride, raw.channels, raw.pixels) orelse
        return error.TestUnexpectedResult;
    defer a.free(small.pixels);
    // No downscale at 4px: byte-identical passthrough.
    try t.expectEqual(@as(i32, 4), small.width);
    try t.expectEqualSlices(u8, &straight, small.pixels);
    // Malformed blobs die, never half-decode.
    try t.expect(deserializeBlob(a, framed.items[0..31]) == null);
    if (deserializeBlob(a, framed.items)) |ok| {
        defer a.free(ok.pixels);
    } else return error.TestUnexpectedResult;
    var bad = try a.dupe(u8, framed.items);
    defer a.free(bad);
    std.mem.writeInt(i32, bad[16..][0..4], 7, .little); // bps 7
    try t.expect(deserializeBlob(a, bad) == null);
}