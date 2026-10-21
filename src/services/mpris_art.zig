//! Cover art for the media widget: turning whatever a player advertises into
//! pixels the pill and its popup can draw.
//!
//! A player hands over a URL, which may be a local file, an http image, or a
//! hint the shell has to translate into something usable. Resolution is pure
//! string work and is what decides *where* the bytes come from; decoding is
//! bounded by `max_edge` so one enormous cover cannot pin a large allocation
//! for the life of the dock.

const std = @import("std");

pub const Scheme = enum { file, http, https, data, unknown };

pub const max_art_bytes: usize = 8 << 20;
const max_edge: i32 = 512;
/// No cover the shell keeps decodes past this many pixels; an image whose
/// header claims more is not one worth holding on to.
const max_pixels: i64 = 4 * 1024 * 1024;

pub fn schemeOf(url: []const u8) Scheme {
    if (std.mem.startsWith(u8, url, "file://")) return .file;
    if (std.mem.startsWith(u8, url, "https://")) return .https;
    if (std.mem.startsWith(u8, url, "http://")) return .http;
    if (std.mem.startsWith(u8, url, "data:")) return .data;
    return .unknown;
}

/// Stable file name for a cover URL. The disk cache writes under this name
/// and every reader finds it again by recomputing it, so the spelling lives
/// here, once.
pub fn cacheName(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{x:0>16}.bin", .{std.hash.Wyhash.hash(0, url)});
}

extern fn stbi_load_from_memory(
    buffer: [*c]const u8,
    len: c_int,
    x: [*c]c_int,
    y: [*c]c_int,
    channels: [*c]c_int,
    req_channels: c_int,
) ?[*]u8;
extern fn stbi_image_free(data: ?*anyopaque) void;
// WebP is beyond what the vendored stb decoder reads, and it is exactly the
// format the thumbnail stores hand out; libwebp is already linked for the
// wallpaper thumbnails.
extern fn WebPGetInfo(data: [*]const u8, len: usize, w: *c_int, h: *c_int) c_int;
extern fn WebPDecodeRGBA(data: [*]const u8, len: usize, w: *c_int, h: *c_int) ?[*]u8;
extern fn WebPFree(ptr: ?*anyopaque) void;

/// Decoded cover pixels, already in cairo's own premultiplied B,G,R,A byte
/// order. `deinit` releases the buffer; the struct is a plain value so it can
/// be handed straight to the pill's `Art`.
pub const Cover = struct {
    w: i32 = 0,
    h: i32 = 0,
    pixels: []u8 = &.{},

    pub fn present(self: Cover) bool {
        return self.pixels.len > 0 and self.w > 0 and self.h > 0;
    }

    pub fn deinit(self: *Cover, alloc: std.mem.Allocator) void {
        if (self.pixels.len > 0) alloc.free(self.pixels);
        self.* = .{};
    }
};

// Resolution

/// Turn a player's advertised URL into something loadable: a local path or an
/// http URL. Returns null for anything the shell cannot read.
pub fn resolve(alloc: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    var path = trim(raw);
    if (path.len == 0) return null;

    // The decoded form only lives as long as this call does; everything
    // returned is a fresh copy.
    var decoded: ?[]u8 = null;
    defer if (decoded) |d| alloc.free(d);
    if (startsWithCi(path, "file://")) {
        path = path["file://".len..];
        if (startsWithCi(path, "localhost")) path = path["localhost".len..];
        decoded = percentDecode(alloc, path) catch null;
        if (decoded) |d| path = d;
    }

    // One player leaves its covers in a runtime directory that belongs to a
    // different sandbox than the one it reports.
    if (std.mem.indexOf(u8, path, ".org.chromium.Chromium") != null and
        startsWithCi(path, "/var/tmp/"))
    {
        const name = lastSegment(path);
        if (name.len > 0) {
            if (envStr("HOME")) |home| {
                return std.fs.path.join(alloc, &.{ home, ".var/app/sh.cider.Cider/cache/tmp", name }) catch null;
            }
        }
    }

    if (startsWithCi(path, "cider-cache://")) return alloc.dupe(u8, path) catch null;
    if (startsWithCi(path, "http")) return alloc.dupe(u8, path) catch null;
    if (path.len > 0 and path[0] == '/') return alloc.dupe(u8, path) catch null;
    return null;
}

/// A page a browser-style player is showing usually has a still on offer from
/// the video host, which reads better than no art at all.
pub fn youtubeThumb(alloc: std.mem.Allocator, source: []const u8) ?[]const u8 {
    if (source.len == 0) return null;

    var id: []const u8 = "";
    if (indexOfCi(source, "youtube.com/watch") != null) {
        id = queryParam(source, "v") orelse "";
    } else if (indexOfCi(source, "youtu.be/") != null) {
        id = afterMarker(source, "youtu.be/");
    } else if (indexOfCi(source, "youtube.com/shorts/") != null) {
        id = afterMarker(source, "youtube.com/shorts/");
    } else return null;

    id = trim(id);
    if (id.len == 0) return null;
    return std.fmt.allocPrint(alloc, "https://i.ytimg.com/vi/{s}/hqdefault.jpg", .{id}) catch null;
}

/// The fields that decide where a track's cover has to come from.
pub const Source = struct {
    bus_name: []const u8 = "",
    art_url: []const u8 = "",
    track_url: []const u8 = "",
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
};

/// Pick the address to find this track's cover at. A player that advertises
/// an image is believed; one with none gets the still from its video page;
/// and a player whose covers live in a sandbox-private cache — where no
/// file path exists to hand out — gets a marker naming the track, which the
/// loader turns into a search of that cache. Owned by the caller.
pub fn sourceFor(alloc: std.mem.Allocator, s: Source) ?[]const u8 {
    if (indexOfCi(s.bus_name, "cider") != null and ciderArtMissing(s.art_url)) {
        var h = std.hash.Wyhash.init(0);
        for ([_][]const u8{ s.title, s.artist, s.album, s.track_url, s.art_url }) |part| {
            h.update(part);
            h.update("|");
        }
        return std.fmt.allocPrint(alloc, "cider-cache://{x:0>16}", .{h.final()}) catch null;
    }
    if (s.art_url.len > 0) return alloc.dupe(u8, s.art_url) catch null;
    return youtubeThumb(alloc, s.track_url);
}

/// A player that has published no usable cover: either nothing at all, or a
/// path inside a sandbox the shell cannot read.
fn ciderArtMissing(art_url: []const u8) bool {
    return art_url.len == 0 or std.mem.indexOf(u8, art_url, ".org.chromium.Chromium") != null;
}

/// Does this address ask for a search of the player's private cache?
pub fn isCiderCache(url: []const u8) bool {
    return startsWithCi(url, "cider-cache://");
}

fn afterMarker(source: []const u8, marker: []const u8) []const u8 {
    const at = indexOfCi(source, marker) orelse return "";
    const start = at + marker.len;
    if (start >= source.len) return "";
    var end = source.len;
    for ("?#&/") |stop| {
        if (std.mem.indexOfScalarPos(u8, source, start, stop)) |i| {
            if (i < end) end = i;
        }
    }
    return source[start..end];
}

fn queryParam(url: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var rest = url[q + 1 ..];
    while (rest.len > 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&');
        const pair = if (amp) |i| rest[0..i] else rest;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const k = if (eq) |i| pair[0..i] else pair;
        if (std.mem.eql(u8, k, key)) {
            if (eq == null or eq.? + 1 >= pair.len) return null;
            return pair[eq.? + 1 ..];
        }
        if (amp == null) break;
        rest = rest[amp.? + 1 ..];
    }
    return null;
}

/// `%XX` escapes become their byte; anything not a valid escape is kept as-is
/// rather than dropped, so a path with a stray `%` still resolves.
pub fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(alloc, s[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(alloc, s[i]);
                i += 1;
                continue;
            };
            try out.append(alloc, hi * 16 + lo);
            i += 3;
            continue;
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// Decoding

/// Decode image bytes and, if either side is larger than the cap, reduce them
/// with a box filter so the cover keeps its aspect ratio. WebP is read with
/// libwebp — the format thumbnail stores hand out — and everything else with
/// the vendored stb decoder.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) ?Cover {
    if (bytes.len == 0 or bytes.len > max_art_bytes) return null;
    if (bytes.len > std.math.maxInt(c_int)) return null;
    if (isWebp(bytes)) return decodeWebp(alloc, bytes);
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const data = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &ch, 4) orelse return null;
    defer stbi_image_free(data);
    if (w <= 0 or h <= 0) return null;
    const total: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    return fromRgba(alloc, @intCast(w), @intCast(h), data[0..total]);
}

fn isWebp(bytes: []const u8) bool {
    return bytes.len >= 12 and
        std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP");
}

/// Header-only geometry of a WebP body: a search that ranges over cached
/// images needs their shape without paying for a decode of each.
pub fn webpInfo(bytes: []const u8) ?struct { w: i32, h: i32 } {
    if (!isWebp(bytes)) return null;
    var w: c_int = 0;
    var h: c_int = 0;
    if (WebPGetInfo(bytes.ptr, bytes.len, &w, &h) == 0) return null;
    if (w <= 0 or h <= 0) return null;
    if (@as(i64, w) * @as(i64, h) > max_pixels) return null;
    return .{ .w = w, .h = h };
}

fn decodeWebp(alloc: std.mem.Allocator, bytes: []const u8) ?Cover {
    const dims = webpInfo(bytes) orelse return null;
    var w: c_int = dims.w;
    var h: c_int = dims.h;
    const rgba = WebPDecodeRGBA(bytes.ptr, bytes.len, &w, &h) orelse return null;
    defer WebPFree(rgba);
    if (w <= 0 or h <= 0) return null;
    const total: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    return fromRgba(alloc, @intCast(w), @intCast(h), rgba[0..total]);
}

/// Read a cover straight off disk.
pub fn loadFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?Cover {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_art_bytes)) catch return null;
    defer alloc.free(bytes);
    return decode(alloc, bytes);
}

/// Pull a cover down over the network. This waits on a socket, so it belongs
/// on a worker thread and never on the shell's own; the bytes come back owned
/// by the caller.
pub fn fetchBytes(alloc: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const res = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });
    if (res.status != .ok) return error.HttpStatus;
    const body = try aw.toOwnedSlice();
    if (body.len > max_art_bytes) {
        alloc.free(body);
        return error.TooLarge;
    }
    return body;
}

const Reduced = struct { w: i32, h: i32, pixels: []u8 };

/// Straight R,G,B,A rows at `w`x`h` reduced under the edge cap and left in
/// cairo's premultiplied byte order. Both decoders meet here so the reduce
/// and reorder steps exist once.
pub fn fromRgba(alloc: std.mem.Allocator, w: i32, h: i32, rgba: []const u8) ?Cover {
    if (w <= 0 or h <= 0) return null;
    if (rgba.len != @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) return null;
    const scaled = reduce(alloc, w, h, rgba) catch return null;
    const cover = Cover{ .w = scaled.w, .h = scaled.h, .pixels = scaled.pixels };
    toCairoOrder(cover.pixels);
    return cover;
}

/// Nearest-divisor box reduction: the source is averaged into `out_w x out_h`
/// bins, which keeps straight edges clean at the sizes a thumbnail needs.
fn reduce(alloc: std.mem.Allocator, w: i32, h: i32, rgba: []const u8) !Reduced {
    if (w <= max_edge and h <= max_edge) return .{ .w = w, .h = h, .pixels = try alloc.dupe(u8, rgba) };
    const sc = @as(f64, @floatFromInt(@max(w, h))) / @as(f64, @floatFromInt(max_edge));
    const out_w: i32 = @max(1, @as(i32, @intFromFloat(@as(f64, @floatFromInt(w)) / sc)));
    const out_h: i32 = @max(1, @as(i32, @intFromFloat(@as(f64, @floatFromInt(h)) / sc)));
    var out = try alloc.alloc(u8, @as(usize, @intCast(out_w)) * @as(usize, @intCast(out_h)) * 4);

    var oy: i32 = 0;
    while (oy < out_h) : (oy += 1) {
        const y0 = @as(usize, @intCast(@divTrunc(@as(i64, oy) * h, out_h)));
        const y1 = @max(y0 + 1, @as(usize, @intCast(@divTrunc(@as(i64, oy + 1) * h, out_h))));
        var ox: i32 = 0;
        while (ox < out_w) : (ox += 1) {
            const x0 = @as(usize, @intCast(@divTrunc(@as(i64, ox) * w, out_w)));
            const x1 = @max(x0 + 1, @as(usize, @intCast(@divTrunc(@as(i64, ox + 1) * w, out_w))));
            var sum = [4]u32{ 0, 0, 0, 0 };
            var n: u32 = 0;
            var yy: usize = y0;
            while (yy < y1) : (yy += 1) {
                var xx: usize = x0;
                while (xx < x1) : (xx += 1) {
                    const o = (yy * @as(usize, @intCast(w)) + xx) * 4;
                    sum[0] += rgba[o];
                    sum[1] += rgba[o + 1];
                    sum[2] += rgba[o + 2];
                    sum[3] += rgba[o + 3];
                    n += 1;
                }
            }
            const d = (@as(usize, @intCast(oy)) * @as(usize, @intCast(out_w)) + @as(usize, @intCast(ox))) * 4;
            const div: u32 = @max(1, n);
            out[d] = @intCast(sum[0] / div);
            out[d + 1] = @intCast(sum[1] / div);
            out[d + 2] = @intCast(sum[2] / div);
            out[d + 3] = @intCast(sum[3] / div);
        }
    }
    return .{ .w = out_w, .h = out_h, .pixels = out };
}

/// stb hands back straight R,G,B,A; cairo wants a native-endian AARRGGBB word
/// with the colour channels already multiplied down by alpha.
fn toCairoOrder(px: []u8) void {
    var i: usize = 0;
    while (i + 3 < px.len) : (i += 4) {
        const a: u32 = px[i + 3];
        const r: u32 = px[i];
        const g: u32 = px[i + 1];
        const b: u32 = px[i + 2];
        if (a == 0) {
            px[i] = 0;
            px[i + 1] = 0;
            px[i + 2] = 0;
            continue;
        }
        if (a < 255) {
            px[i] = @intCast((b * a + 127) / 255);
            px[i + 1] = @intCast((g * a + 127) / 255);
            px[i + 2] = @intCast((r * a + 127) / 255);
        } else {
            px[i] = @intCast(b);
            px[i + 1] = @intCast(g);
            px[i + 2] = @intCast(r);
        }
    }
}

// Small helpers

fn indexOfCi(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn startsWithCi(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn lastSegment(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

fn envStr(key: [:0]const u8) ?[]const u8 {
    const p = getenv(key) orelse return null;
    return std.mem.span(p);
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

test "mpris-art: a local file URL becomes a decoded path" {
    const t = std.testing;
    const got = resolve(t.allocator, "file:///home/me/Art/cover.png") orelse return error.SkipZigTest;
    defer t.allocator.free(got);
    try t.expectEqualStrings("/home/me/Art/cover.png", got);

    const spaced = resolve(t.allocator, "file:///home/me/My%20Art/cover.png") orelse return error.SkipZigTest;
    defer t.allocator.free(spaced);
    try t.expectEqualStrings("/home/me/My Art/cover.png", spaced);
}

test "mpris-art: only readable schemes resolve" {
    const t = std.testing;
    const http = resolve(t.allocator, "https://x/cover.jpg") orelse return error.SkipZigTest;
    defer t.allocator.free(http);
    try t.expectEqualStrings("https://x/cover.jpg", http);
    const plain = resolve(t.allocator, "http://x/cover.jpg") orelse return error.SkipZigTest;
    defer t.allocator.free(plain);
    const cached = resolve(t.allocator, "cider-cache://covers/1") orelse return error.SkipZigTest;
    defer t.allocator.free(cached);
    try t.expect(resolve(t.allocator, "") == null);
    try t.expect(resolve(t.allocator, "   ") == null);
}

test "mpris-art: a watch page yields its thumbnail" {
    const t = std.testing;
    const a = youtubeThumb(t.allocator, "https://www.youtube.com/watch?v=abc123&t=30") orelse return error.SkipZigTest;
    defer t.allocator.free(a);
    try t.expectEqualStrings("https://i.ytimg.com/vi/abc123/hqdefault.jpg", a);

    const b = youtubeThumb(t.allocator, "https://youtu.be/xyz789") orelse return error.SkipZigTest;
    defer t.allocator.free(b);
    try t.expectEqualStrings("https://i.ytimg.com/vi/xyz789/hqdefault.jpg", b);

    const c = youtubeThumb(t.allocator, "https://www.youtube.com/shorts/short1") orelse return error.SkipZigTest;
    defer t.allocator.free(c);
    try t.expectEqualStrings("https://i.ytimg.com/vi/short1/hqdefault.jpg", c);

    try t.expect(youtubeThumb(t.allocator, "https://example.com/page") == null);
}

test "mpris-art: percent escapes decode and odd ones survive" {
    const t = std.testing;
    const a = try percentDecode(t.allocator, "a%20b%2Fc");
    defer t.allocator.free(a);
    try t.expectEqualStrings("a b/c", a);
    const b = try percentDecode(t.allocator, "100%");
    defer t.allocator.free(b);
    try t.expectEqualStrings("100%", b);
    const c = try percentDecode(t.allocator, "%zz");
    defer t.allocator.free(c);
    try t.expectEqualStrings("%zz", c);
}

test "mpris-art: a large cover is reduced without changing its shape" {
    const t = std.testing;
    // 8x2 solid white, asked to shrink: it comes back one quarter as wide and
    // every pixel still white.
    var src: [8 * 2 * 4]u8 = undefined;
    for (0..(8 * 2)) |i| {
        src[i * 4] = 255;
        src[i * 4 + 1] = 255;
        src[i * 4 + 2] = 255;
        src[i * 4 + 3] = 255;
    }
    const small = try reduce(t.allocator, 8, 2, &src);
    defer t.allocator.free(small.pixels);
    try t.expectEqual(@as(i32, 8), small.w);
    try t.expectEqual(@as(i32, 2), small.h);

    // A wide cover keeps its aspect ratio when squeezed under the cap.
    var wide: [64 * 8 * 4]u8 = undefined;
    @memset(&wide, 200);
    const got = try reduce(t.allocator, 64, 8, &wide);
    defer t.allocator.free(got.pixels);
    try t.expect(got.w <= max_edge and got.h <= max_edge);
    try t.expect(got.w > got.h);
}

test "mpris-art: garbage bytes do not decode" {
    const t = std.testing;
    try t.expect(decode(t.allocator, "") == null);
    try t.expect(decode(t.allocator, "not an image at all") == null);
}

/// A 3x2 teal WebP, encoded small enough to spell out.
const test_webp_b64 = "UklGRjgAAABXRUJQVlA4ICwAAACQAQCdASoDAAIAAQAcJaACdLoAA5gA/uuOX4oBSOHO//efP/vAn/vAn+jQAA==";

test "mpris-art: a webp body decodes, and its header alone does not" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    const n = try std.base64.standard.Decoder.calcSizeForSlice(test_webp_b64);
    try t.expect(n <= buf.len);
    try std.base64.standard.Decoder.decode(buf[0..n], test_webp_b64);
    var got = decode(t.allocator, buf[0..n]) orelse return error.TestUnexpectedResult;
    defer got.deinit(t.allocator);
    try t.expectEqual(@as(i32, 3), got.w);
    try t.expectEqual(@as(i32, 2), got.h);
    try t.expectEqual(@as(usize, 3 * 2 * 4), got.pixels.len);

    const dims = webpInfo(buf[0..n]) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(i32, 3), dims.w);
    try t.expectEqual(@as(i32, 2), dims.h);
    // A body cut off before its header finished is not an image.
    try t.expect(webpInfo(buf[0..11]) == null);
    try t.expect(decode(t.allocator, buf[0..11]) == null);
}

test "mpris-art: cache name is a pure function of the URL" {
    const t = std.testing;
    const a = try cacheName(t.allocator, "file:///m/cover.jpg");
    defer t.allocator.free(a);
    const b = try cacheName(t.allocator, "file:///m/cover.jpg");
    defer t.allocator.free(b);
    try t.expectEqualStrings(a, b);
    const c = try cacheName(t.allocator, "file:///m/other.jpg");
    defer t.allocator.free(c);
    try t.expect(!std.mem.eql(u8, a, c));
    // No player prefix, no spaces, no separators beyond the extension.
    try t.expect(std.mem.endsWith(u8, a, ".bin"));
    try t.expect(std.mem.indexOfScalar(u8, a, '/') == null);
}

test "mpris-art: the source a track is found at" {
    const t = std.testing;
    // A player with an image is believed as-is.
    const direct = sourceFor(t.allocator, .{
        .bus_name = "org.mpris.MediaPlayer2.spotify",
        .art_url = "file:///m/c.jpg",
        .track_url = "https://youtu.be/abc",
    }) orelse return error.SkipZigTest;
    defer t.allocator.free(direct);
    try t.expectEqualStrings("file:///m/c.jpg", direct);

    // No image, but a video page: its still.
    const thumb = sourceFor(t.allocator, .{
        .bus_name = "org.mpris.MediaPlayer2.firefox",
        .track_url = "https://www.youtube.com/watch?v=abc",
    }) orelse return error.SkipZigTest;
    defer t.allocator.free(thumb);
    try t.expectEqualStrings("https://i.ytimg.com/vi/abc/hqdefault.jpg", thumb);

    // The sandboxed player: a per-track marker, stable across calls and
    // different from one track to the next.
    const s: Source = .{
        .bus_name = "org.mpris.MediaPlayer2.sh.cider.Cider",
        .art_url = "file:///var/tmp/.org.chromium.Chromium.xyz/1",
        .title = "T",
        .artist = "A",
        .album = "L",
    };
    const m1 = sourceFor(t.allocator, s) orelse return error.SkipZigTest;
    defer t.allocator.free(m1);
    try t.expect(isCiderCache(m1));
    const m2 = sourceFor(t.allocator, s) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(m2);
    try t.expectEqualStrings(m1, m2);
    const m3 = sourceFor(t.allocator, .{
        .bus_name = s.bus_name,
        .art_url = s.art_url,
        .title = "U",
        .artist = "A",
        .album = "L",
    }) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(m3);
    try t.expect(!std.mem.eql(u8, m1, m3));

    // The same player with a readable URL is not diverted.
    const good = sourceFor(t.allocator, .{
        .bus_name = s.bus_name,
        .art_url = "https://mzstatic.com/x.webp",
        .title = "T",
    }) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(good);
    try t.expectEqualStrings("https://mzstatic.com/x.webp", good);
}
