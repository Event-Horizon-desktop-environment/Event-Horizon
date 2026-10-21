//! The Bing wallpaper catalogue, read out of the upstream project's README.
//!
//! `v5tech/bing-wallpaper` publishes every image it has ever mirrored as a
//! markdown table of `[download 4k](URL)` links, and that README *is* the
//! index the settings app works from — there is no JSON endpoint to ask
//! instead. So this module parses/filters markdown into
//! entries, decide which ones a request wants, and keep a JSON cache of the
//! last parse so a daily fetch does not have to hit GitHub at all.
//!
//! Everything here is pure — no threads, no sockets, no UI — so it is the
//! half that carries tests. The service in `ux/settings2/bing_service.zig`
//! owns the worker thread and the downloads; the tab owns the widgets.

const std = @import("std");
const local_time = @import("../desktop_shell/desktop/local_time.zig");

pub const readme_url =
    "https://raw.githubusercontent.com/v5tech/bing-wallpaper/refs/heads/main/README.md";

/// The marker every standard row in the README is built around.
pub const k_marker = "[download 4k](";
/// The looser fallback: bare `cn.bing.com` links with no marker at all.
pub const k_cn_prefix = "https://cn.bing.com/th?id=";
/// How far before a loose link the date is allowed to sit.
const k_ctx_bytes: usize = 200;
/// A downloaded file is this long by construction (`…_UHD.jpg`).
const k_uhd_suffix = "_UHD.jpg";

pub const Filter = enum {
    all,
    current,
    last,
    custom,
};

/// One catalogue row. Every string is owned by the allocator that produced
/// the entry; `freeEntries` returns the whole set.
pub const Entry = struct {
    date: []u8,
    month: []u8,
    title: []u8,
    url: []u8,
    filename: []u8,
    local_path: []u8,
};

pub fn freeEntry(alloc: std.mem.Allocator, e: *Entry) void {
    alloc.free(e.date);
    alloc.free(e.month);
    alloc.free(e.title);
    alloc.free(e.url);
    alloc.free(e.filename);
    alloc.free(e.local_path);
    e.* = undefined;
}

pub fn freeEntries(alloc: std.mem.Allocator, items: []Entry) void {
    for (items) |*e| freeEntry(alloc, e);
    alloc.free(items);
}

// Filenames

/// Keep only `[A-Za-z0-9._-]`; everything else becomes `_`. Bing's ids are
/// already tame, but the README is user-authored markdown and a stray `?` in
/// a URL must not reach the filesystem.
pub fn sanitiseFilename(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |ch, i| {
        const keep = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '.' or ch == '_' or ch == '-';
        out[i] = if (keep) ch else '_';
    }
    return out;
}

/// Pull the stable id out of a download URL. It lives after `?id=` when the
/// URL has one (truncated at the next `&` or `)`, since the markdown can leak
/// a trailing paren into the link), else it is the last path segment with any
/// query stripped. Too short to be an id means the row is dropped.
fn idFromUrl(url: []const u8) ?[]const u8 {
    var id: []const u8 = "";
    if (std.mem.indexOf(u8, url, "?id=")) |p| {
        const begin = p + 4;
        var end = url.len;
        if (std.mem.indexOfScalarPos(u8, url, begin, '&')) |a| end = @min(end, a);
        if (std.mem.indexOfScalarPos(u8, url, begin, ')')) |r| end = @min(end, r);
        if (end > begin) id = url[begin..end];
    }
    if (id.len == 0) {
        const begin = if (std.mem.lastIndexOfScalar(u8, url, '/')) |sl| sl + 1 else 0;
        var end = url.len;
        if (std.mem.indexOfScalarPos(u8, url, begin, '?')) |q| end = @min(end, q);
        if (end > begin) id = url[begin..end];
    }
    if (id.len < 8) return null;
    return id;
}

/// Build a catalogue row from a URL, or null when the URL carries no usable
/// id. `month` is the first seven characters of `date` — the `YYYY-MM` the
/// archive-download filter keys on.
pub fn makeEntry(alloc: std.mem.Allocator, url: []const u8, date: []const u8, dir: []const u8) !?Entry {
    const id = idFromUrl(url) orelse return null;

    var filename = try sanitiseFilename(alloc, id);
    errdefer alloc.free(filename);
    if (!std.mem.endsWith(u8, filename, k_uhd_suffix)) {
        const grown = try std.fmt.allocPrint(alloc, "{s}{s}", .{ filename, k_uhd_suffix });
        alloc.free(filename);
        filename = grown;
    }

    const month_src: []const u8 = if (date.len >= 7 and !std.mem.eql(u8, date, "unknown"))
        date[0..7]
    else
        "unknown";
    const month = try alloc.dupe(u8, month_src);
    errdefer alloc.free(month);
    const local_path = try std.fs.path.join(alloc, &.{ dir, filename });
    errdefer alloc.free(local_path);

    return .{
        .date = try alloc.dupe(u8, date),
        .month = month,
        .title = &.{},
        .url = try alloc.dupe(u8, url),
        .filename = filename,
        .local_path = local_path,
    };
}

// README parsing

/// Find the first `YYYY-MM-DD` in `md[begin..end)`: scan for a `-`
/// at offset 4 and 7 with digits everywhere else — a shape no other run of
/// ten characters in the table has.
pub fn findDate(md: []const u8, begin: usize, end: usize) ?usize {
    if (end < 10) return null;
    const stop = @min(end, md.len);
    var i = begin;
    // `i + 10 < stop`: the candidate has to sit entirely before the marker.
    while (i + 10 < stop) : (i += 1) {
        if (md[i + 4] != '-' or md[i + 7] != '-') continue;
        var digits = true;
        inline for (0..10) |k| {
            if (k == 4 or k == 7) continue;
            if (md[i + k] < '0' or md[i + k] > '9') {
                digits = false;
                break;
            }
        }
        if (digits) return i;
    }
    return null;
}

/// Title from the `![alt](…)` that precedes a download link on its own line.
/// Returns an empty slice when the line carries no image alt text.
fn titleBefore(md: []const u8, line_start: usize, marker: usize) []const u8 {
    const img = std.mem.lastIndexOf(u8, md[0..marker], "![") orelse return "";
    if (img < line_start) return "";
    const close = std.mem.indexOfScalarPos(u8, md, img + 2, ']') orelse return "";
    if (close >= marker) return "";
    if (close < img + 2) return "";
    return md[img + 2 .. close];
}

fn lineStart(md: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and md[i - 1] != '\n') i -= 1;
    return i;
}

/// Everything the README lists, newest first. Two passes: the standard
/// `[download 4k](…)` rows, then loose `cn.bing.com` links that never got a
/// marker. Both dedupe by URL, so a row that appears twice is downloaded once.
pub fn parseReadme(alloc: std.mem.Allocator, md: []const u8, dir: []const u8) ![]Entry {
    var items: std.ArrayList(Entry) = .empty;
    errdefer {
        for (items.items) |*e| freeEntry(alloc, e);
        items.deinit(alloc);
    }
    // Keys point into `md`, which outlives this call, so the set needs no
    // per-key free — with the same URL dedupe.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);

    // Pass 1 — the standard marker.
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, md, pos, k_marker)) |start| {
        const url_begin = start + k_marker.len;
        const url_end = std.mem.indexOfScalarPos(u8, md, url_begin, ')') orelse break;
        const url = md[url_begin..url_end];

        const ls = lineStart(md, start);
        var date_buf: [10]u8 = undefined;
        const date: []const u8 = if (findDate(md, ls, start)) |dpos|
            blk: {
                @memcpy(&date_buf, md[dpos..][0..10]);
                break :blk date_buf[0..10];
            }
        else
            "unknown";
        const title = titleBefore(md, ls, start);

        const gop = try seen.getOrPut(alloc, url);
        if (!gop.found_existing) {
            gop.key_ptr.* = url;
            if (try makeEntry(alloc, url, date, dir)) |e| {
                var entry = e;
                entry.title = try alloc.dupe(u8, title);
                try items.append(alloc, entry);
            }
        }
        pos = url_end + 1;
    }

    // Pass 2 — loose links, only accepted when they are already UHD.
    pos = 0;
    while (std.mem.indexOfPos(u8, md, pos, k_cn_prefix)) |start| {
        var ue = start + k_cn_prefix.len;
        while (ue < md.len and !isUrlStop(md[ue])) : (ue += 1) {}
        const url = md[start..ue];

        const ctx_begin = if (start > k_ctx_bytes) start - k_ctx_bytes else 0;
        var date_buf: [10]u8 = undefined;
        var date: []const u8 = "unknown";
        if (findDate(md, ctx_begin, start)) |dpos| {
            @memcpy(&date_buf, md[dpos..][0..10]);
            date = date_buf[0..10];
        }

        if (url.len >= k_uhd_suffix.len and
            std.mem.endsWith(u8, url, k_uhd_suffix) and
            !seen.contains(url))
        {
            const gop = try seen.getOrPut(alloc, url);
            if (!gop.found_existing) {
                gop.key_ptr.* = url;
                if (try makeEntry(alloc, url, date, dir)) |e| try items.append(alloc, e);
            }
        }
        pos = start + 1;
    }

    std.mem.sort(Entry, items.items, {}, newestFirst);
    return items.toOwnedSlice(alloc);
}

fn isUrlStop(ch: u8) bool {
    return ch == ')' or ch == ' ' or ch == '\n' or ch == '\r' or ch == '"' or ch == '\'';
}

/// Newest date first. An undated row sorts as year zero, so it lands last
/// instead of fighting its neighbours for the top.
fn newestFirst(_: void, a: Entry, b: Entry) bool {
    const da: []const u8 = if (std.mem.eql(u8, a.date, "unknown")) "0000-00-00" else a.date;
    const db: []const u8 = if (std.mem.eql(u8, b.date, "unknown")) "0000-00-00" else b.date;
    return std.mem.order(u8, da, db) == .gt;
}

// Selection

/// A calendar year as an unsigned value: `{d}` on a signed integer prints a
/// sign, and "2026" must stay four characters to compare against a README
/// date slice.
fn ymYear(year: i32) u16 {
    return @intCast(@max(0, @min(year, 9999)));
}

/// `YYYY-MM` for the machine's current local month, written into `buf`
/// (seven bytes: `2026-10`).
pub fn currentYm(buf: *[7]u8) []const u8 {
    const d = local_time.today();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ ymYear(d.year), d.month }) catch "0000-00";
}

/// The month before `year`/`month` (1-based). December rolls back into the
/// previous year — month arithmetic with a day of
/// subtraction to get.
pub fn previousMonth(year: i32, month: u8) struct { year: i32, month: u8 } {
    if (month <= 1) return .{ .year = year - 1, .month = 12 };
    return .{ .year = year, .month = month - 1 };
}

/// `YYYY-MM` for the month before the current one.
pub fn lastMonthYm(buf: *[7]u8) []const u8 {
    const d = local_time.today();
    const prev = previousMonth(d.year, d.month);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ ymYear(prev.year), prev.month }) catch "0000-00";
}

/// The subset a filter selects. `all` takes everything; the rest key on the
/// entry's `YYYY-MM`, so the archive downloader can ask for one month.
pub fn filterEntries(
    alloc: std.mem.Allocator,
    items: []const Entry,
    filter: Filter,
    custom_month: []const u8,
) ![]Entry {
    if (filter == .all) {
        const out = try alloc.alloc(Entry, items.len);
        @memcpy(out, items);
        return out;
    }
    var cur_buf: [7]u8 = undefined;
    var last_buf: [7]u8 = undefined;
    const target: []const u8 = switch (filter) {
        .current => currentYm(&cur_buf),
        .last => lastMonthYm(&last_buf),
        .custom => custom_month,
        .all => unreachable,
    };
    if (target.len == 0) return try alloc.alloc(Entry, 0);

    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(alloc);
    for (items) |e| {
        if (std.mem.eql(u8, e.month, target)) try out.append(alloc, e);
    }
    return out.toOwnedSlice(alloc);
}

/// True when any keyword appears in the entry's title or filename. The block
/// list is a plain substring match, case-insensitively — a user who types
/// "cat" is trying to hide cats, not the literal word boundary.
pub fn matchesBlocklist(entry: *const Entry, keywords: []const []const u8) bool {
    if (keywords.len == 0) return false;
    // Bounded concat of the two searched fields together. 4 KB is
    // far past any real title+filename pair, so truncation is a safety net
    // rather than a behaviour.
    var combined_buf: [4096]u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ entry.title, " ", entry.filename }) |part| {
        const take = @min(part.len, combined_buf.len - n);
        @memcpy(combined_buf[n .. n + take], part[0..take]);
        n += take;
    }
    const combined = combined_buf[0..n];
    if (combined.len == 0) return false;
    for (keywords) |kw| {
        if (kw.len == 0) continue;
        if (std.ascii.indexOfIgnoreCase(combined, kw) != null) return true;
    }
    return false;
}

/// Split a comma-separated keyword list:
/// does: leading spaces and commas are skipped, and a keyword runs to the
/// next comma.
pub fn splitKeywords(alloc: std.mem.Allocator, raw: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |k| alloc.free(k);
        out.deinit(alloc);
    }
    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and (raw[i] == ' ' or raw[i] == ',')) i += 1;
        if (i >= raw.len) break;
        const begin = i;
        while (i < raw.len and raw[i] != ',') i += 1;
        // Stop at the comma only, which leaves the space in
        // "cat, dog" inside the keyword — and `contains_ci` then fails to
        // match a lone "cat". Trimming the tail is the one place this port
        // departs from it, because a block list that silently does nothing
        // with the conventional separator is not a feature.
        var end = i;
        while (end > begin and (raw[end - 1] == ' ' or raw[end - 1] == '\t')) end -= 1;
        if (end == begin) continue;
        try out.append(alloc, try alloc.dupe(u8, raw[begin..end]));
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeKeywords(alloc: std.mem.Allocator, kws: [][]u8) void {
    for (kws) |k| alloc.free(k);
    alloc.free(kws);
}

// Disk

/// Image names already sitting in `dir`. Keys point into a buffer the caller
/// owns for as long as the set lives, so pair this with an arena rather than
/// freeing names one at a time.
pub fn localFilenames(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    errdefer set.deinit(alloc);

    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return set;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (!isImageName(e.name)) continue;
        const name = try alloc.dupe(u8, e.name);
        errdefer alloc.free(name);
        try set.put(alloc, name, {});
    }
    return set;
}

fn isImageName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".jpg") or
        std.mem.endsWith(u8, name, ".jpeg") or
        std.mem.endsWith(u8, name, ".png") or
        std.mem.endsWith(u8, name, ".webp");
}

/// Shared cache file, readable by both trees: one JSON
/// array of `{date, month, title, url, filename, local_path}`.
pub fn cacheFilePath(
    alloc: std.mem.Allocator,
    xdg_cache: ?[]const u8,
    home: ?[]const u8,
) ![]u8 {
    const base = if (xdg_cache) |c|
        try std.fs.path.join(alloc, &.{ c, ".cache" })
    else if (home) |h|
        try std.fs.path.join(alloc, &.{ h, ".cache" })
    else
        try alloc.dupe(u8, "/tmp");
    defer alloc.free(base);
    return std.fs.path.join(alloc, &.{ base, "event-horizon", "bingwall", "bing_wallpapers.json" });
}

/// Where images land when the user has not chosen a folder.
pub fn defaultDownloadDir(alloc: std.mem.Allocator, home: ?[]const u8) ![]u8 {
    if (home) |h| return std.fs.path.join(alloc, &.{ h, "Pictures", "BingWallpaper" });
    return alloc.dupe(u8, "/tmp/BingWallpaper");
}

const CacheItem = struct {
    date: []const u8,
    month: []const u8,
    title: []const u8,
    url: []const u8,
    filename: []const u8,
    local_path: []const u8,
};

/// Read the cached catalogue. `local_path` is rebuilt from `dir` rather than
/// trusted from the file, so moving the download folder does not leave the
/// cache pointing at the old one.
pub fn loadCache(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    dir: []const u8,
) !?[]Entry {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 << 20)) catch return null;
    defer alloc.free(text);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;

    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |*e| freeEntry(alloc, e);
        out.deinit(alloc);
    }
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const url = jsonStr(item.object.get("url"));
        const filename = jsonStr(item.object.get("filename"));
        if (url.len == 0 or filename.len == 0) continue;
        const local_path = try std.fs.path.join(alloc, &.{ dir, filename });
        errdefer alloc.free(local_path);
        try out.append(alloc, .{
            .date = try alloc.dupe(u8, jsonStr(item.object.get("date"))),
            .month = try alloc.dupe(u8, jsonStr(item.object.get("month"))),
            .title = try alloc.dupe(u8, jsonStr(item.object.get("title"))),
            .url = try alloc.dupe(u8, url),
            .filename = try alloc.dupe(u8, filename),
            .local_path = local_path,
        });
    }
    if (out.items.len == 0) return null;
    return @as(?[]Entry, try out.toOwnedSlice(alloc));
}

fn jsonStr(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    if (val != .string) return "";
    return val.string;
}

/// Write the catalogue out atomically — a truncated cache would read back as
/// an empty archive, which is worse than no cache at all.
pub fn saveCache(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    items: []const Entry,
) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var owned = try alloc.alloc(CacheItem, items.len);
    defer alloc.free(owned);
    for (items, 0..) |e, i| {
        owned[i] = .{
            .date = e.date,
            .month = e.month,
            .title = e.title,
            .url = e.url,
            .filename = e.filename,
            .local_path = e.local_path,
        };
    }
    const body = try std.json.Stringify.valueAlloc(alloc, owned, .{ .whitespace = .indent_2 });
    defer alloc.free(body);

    const cwd = std.Io.Dir.cwd();
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = body });
    try cwd.rename(tmp, cwd, path, io);
}

// Tests

test "bing-archive: an id becomes a UHD filename" {
    const t = std.testing;
    var e = (try makeEntry(t.allocator, "https://cn.bing.com/th?id=OHR.En-US12345_EN-US12345", "2026-10-07", "/pics")) orelse
        return error.SkipZigTest;
    defer freeEntry(t.allocator, &e);
    try t.expectEqualStrings("2026-10-07", e.date);
    try t.expectEqualStrings("2026-10", e.month);
    try t.expectEqualStrings("OHR.En-US12345_EN-US12345_UHD.jpg", e.filename);
    try t.expectEqualStrings("/pics/OHR.En-US12345_EN-US12345_UHD.jpg", e.local_path);
}

test "bing-archive: the suffix is not appended twice" {
    const t = std.testing;
    var e = (try makeEntry(t.allocator, "https://cn.bing.com/th?id=abcdefgh_UHD.jpg", "unknown", "/p")) orelse
        return error.SkipZigTest;
    defer freeEntry(t.allocator, &e);
    try t.expectEqualStrings("abcdefgh_UHD.jpg", e.filename);
    // An undated row is month-tagged "unknown" so the month filter skips it.
    try t.expectEqualStrings("unknown", e.month);
}

test "bing-archive: too-short ids are dropped" {
    const t = std.testing;
    try t.expect((try makeEntry(t.allocator, "https://x/y?abc", "2026-01-01", "/p")) == null);
    try t.expect((try makeEntry(t.allocator, "https://x/y?abcdef", "2026-01-01", "/p")) == null);
}

test "bing-archive: trailing junk in a link does not reach the filename" {
    const t = std.testing;
    // A markdown typo can leak a `)` into the URL; the id stops at it.
    var e = (try makeEntry(t.allocator, "https://cn.bing.com/th?id=abcdefgh)extra", "2026-01-01", "/p")) orelse
        return error.SkipZigTest;
    defer freeEntry(t.allocator, &e);
    try t.expectEqualStrings("abcdefgh_UHD.jpg", e.filename);
}

test "bing-archive: sanitising keeps nothing but filename characters" {
    const t = std.testing;
    const s = try sanitiseFilename(t.allocator, "a b?c/d");
    defer t.allocator.free(s);
    try t.expectEqualStrings("a_b_c_d", s);
}

test "bing-archive: the README's two link shapes both parse" {
    const t = std.testing;
    const md =
        \\| 2026-10-07 | ![Dunes at dusk](https://cn.bing.com/th?id=OHR.Sample1_EN-US1234) | [download 4k](https://cn.bing.com/th?id=OHR.Sample1_EN-US12345) |
        \\
        \\A bare link with no marker: https://cn.bing.com/th?id=OHR.Loose1_EN-US12345_UHD.jpg
        \\
        \\![Dunes at dusk](https://cn.bing.com/th?id=OHR.Sample1_EN-US1234)
    ;
    const items = try parseReadme(t.allocator, md, "/p");
    defer freeEntries(t.allocator, items);
    try t.expectEqual(@as(usize, 2), items.len);
    // Newest first, and the marker row kept its alt text and date.
    try t.expectEqualStrings("OHR.Sample1_EN-US12345_UHD.jpg", items[0].filename);
    try t.expectEqualStrings("2026-10", items[0].month);
    try t.expectEqualStrings("Dunes at dusk", items[0].title);
    try t.expectEqualStrings("OHR.Loose1_EN-US12345_UHD.jpg", items[1].filename);
}

test "bing-archive: duplicate links are collapsed" {
    const t = std.testing;
    const url = "https://cn.bing.com/th?id=OHR.Dupe12345_EN-US12345";
    var buf: [512]u8 = undefined;
    const md = try std.fmt.bufPrint(
        &buf,
        "2026-10-01 | ![x]({s}) | [download 4k]({s}) |\n\n{s}\n",
        .{ url, url, url },
    );
    const items = try parseReadme(t.allocator, md, "/p");
    defer freeEntries(t.allocator, items);
    try t.expectEqual(@as(usize, 1), items.len);
}

test "bing-archive: the date scan ignores ordinary digits" {
    const t = std.testing;
    // No `YYYY-MM-DD` here: the hyphens are in the wrong places.
    try t.expect(findDate("abc-12-345678901", 0, 17) == null);
    try t.expectEqual(@as(usize, 4), findDate("abc-2026-10-07 rest", 0, 19).?);
    // A candidate must end before the marker it is scanning up to.
    try t.expect(findDate("2026-10-07 ab", 0, 10) == null);
}

test "bing-archive: month filters select whole months" {
    const t = std.testing;
    var oct = (try makeEntry(t.allocator, "https://cn.bing.com/th?id=OHR.October12345", "2026-10-07", "/p")) orelse
        return error.SkipZigTest;
    defer freeEntry(t.allocator, &oct);
    var sep = (try makeEntry(t.allocator, "https://cn.bing.com/th?id=OHR.Septembe12345", "2026-09-02", "/p")) orelse
        return error.SkipZigTest;
    defer freeEntry(t.allocator, &sep);
    const items = [_]Entry{ oct, sep };

    const custom = try filterEntries(t.allocator, &items, .custom, "2026-09");
    defer t.allocator.free(custom);
    try t.expectEqual(@as(usize, 1), custom.len);
    try t.expectEqualStrings("2026-09", custom[0].month);

    const all = try filterEntries(t.allocator, &items, .all, "");
    defer t.allocator.free(all);
    try t.expectEqual(@as(usize, 2), all.len);

    const none = try filterEntries(t.allocator, &items, .custom, "2020-01");
    defer t.allocator.free(none);
    try t.expectEqual(@as(usize, 0), none.len);
}

test "bing-archive: the block list matches title and filename, case-insensitively" {
    const t = std.testing;
    var e = (try makeEntry(t.allocator, "https://cn.bing.com/th?id=OHR.Catnap12345", "2026-10-07", "/p")) orelse
        return error.SkipZigTest;
    defer freeEntry(t.allocator, &e);
    // `freeEntry` owns every field, title included.
    e.title = try t.allocator.dupe(u8, "A Sleeping Tabby");

    const cats = try splitKeywords(t.allocator, " cat , ,dog ");
    defer freeKeywords(t.allocator, cats);
    try t.expectEqual(@as(usize, 2), cats.len);
    try t.expectEqualStrings("cat", cats[0]);
    try t.expectEqualStrings("dog", cats[1]);
    try t.expect(matchesBlocklist(&e, cats));

    const clean = try splitKeywords(t.allocator, "mountain, ocean");
    defer freeKeywords(t.allocator, clean);
    try t.expect(!matchesBlocklist(&e, clean));
    try t.expect(!matchesBlocklist(&e, &.{}));
}

test "bing-archive: the cache round-trips" {
    const t = std.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);
    const dir = try std.fs.path.join(t.allocator, &.{ root, "pics" });
    defer t.allocator.free(dir);
    const path = try std.fs.path.join(t.allocator, &.{ root, "bing_wallpapers.json" });
    defer t.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var e = (try makeEntry(t.allocator, "https://cn.bing.com/th?id=OHR.Cached12345", "2026-10-07", dir)) orelse
        return error.SkipZigTest;
    defer freeEntry(t.allocator, &e);
    // `freeEntry` owns every field, title included.
    e.title = try t.allocator.dupe(u8, "Quoted \"title\" with a \\ backslash");
    const items = [_]Entry{e};

    try saveCache(t.allocator, io, path, &items);
    const loaded = (try loadCache(t.allocator, io, path, dir)).?;
    defer freeEntries(t.allocator, loaded);
    try t.expectEqual(@as(usize, 1), loaded.len);
    try t.expectEqualStrings(e.filename, loaded[0].filename);
    try t.expectEqualStrings(e.title, loaded[0].title);
    try t.expectEqualStrings(dir, std.fs.path.dirname(loaded[0].local_path).?);
}

test "bing-archive: an unreadable cache is simply no cache" {
    const t = std.testing;
    const io = std.testing.io;
    try t.expect((try loadCache(t.allocator, io, "/nonexistent/bing.json", "/p")) == null);
}

test "bing-archive: current and last month are neighbours" {
    const t = std.testing;
    var cur_buf: [7]u8 = undefined;
    var last_buf: [7]u8 = undefined;
    const cur = currentYm(&cur_buf);
    const last = lastMonthYm(&last_buf);
    try t.expectEqual(@as(usize, 7), cur.len);
    try t.expectEqual(@as(usize, 7), last.len);
    try t.expect(!std.mem.eql(u8, cur, last));
    try t.expect(cur[4] == '-' and last[4] == '-');
    // December rolls back into the previous year.
    const dec = previousMonth(2026, 12);
    try t.expectEqual(@as(i32, 2026), dec.year);
    try t.expectEqual(@as(u8, 11), dec.month);
    const jan = previousMonth(2026, 1);
    try t.expectEqual(@as(i32, 2025), jan.year);
    try t.expectEqual(@as(u8, 12), jan.month);
}
