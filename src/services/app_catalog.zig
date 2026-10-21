//! The launchable-application catalog: every `.desktop` entry under the XDG
//! search path, parsed, de-duplicated, grouped into the seven launcher
//! buckets and ordered by name. The start menu rebuilds it on every open, so
//! a package installed while the menu was closed shows up on the next one.

const std = @import("std");
const app_launch = @import("app_launch.zig");

pub const Bucket = enum(u8) { productivity, creativity, media, games, developer, utilities, other };

pub const bucket_count: usize = 7;

pub const bucket_labels = [bucket_count][]const u8{
    "Productivity",
    "Creativity",
    "Media",
    "Games",
    "Developer",
    "Utilities",
    "Other",
};

/// Freedesktop categories, in the order they are scanned, that put an entry
/// into each bucket. A category that appears in no list simply does not
/// decide, so `Network;WebBrowser;` keeps looking and lands in `other`.
const bucket_words = [bucket_count][]const []const u8{
    &.{
        "office",       "education",       "texteditor", "wordprocessor", "spreadsheet",
        "presentation", "projectmanagement", "calendar", "database",      "invoice",
    },
    &.{
        "graphics",     "photography",  "2dgraphics", "3dgraphics", "rastergraphics",
        "vectorgraphics", "imagedesign", "publishing",
    },
    &.{ "audiovideo", "audio", "video", "player", "recorder", "mixer", "tv", "streaming" },
    &.{
        "game",         "games",         "arcadegame",    "boardgame",
        "firstpersongame", "roleplayinggame", "strategygame",
    },
    &.{
        "development",  "ide",           "debugger",      "compilers",
        "hexeditor",    "revisioncontrol", "building",
    },
    &.{
        "utility",      "utilities",     "settings",      "system",         "filetools",
        "filemanager",  "archiving",     "compression",   "terminalemulator",
        "accessibility", "monitoring",   "screensaver",
    },
    &.{},
};

pub const Entry = struct {
    /// The file's stem, which is also the id a launcher looks an entry up by.
    id: []const u8 = "",
    path: []const u8 = "",
    name: []const u8 = "",
    generic: []const u8 = "",
    comment: []const u8 = "",
    keywords: []const u8 = "",
    categories: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    /// `name` folded to lower case, so the sort and the first-match search do
    /// not have to re-fold it per comparison.
    fold: []const u8 = "",
    /// `categories` folded to lower case for the default-apps role matcher.
    cats_l: []const u8 = "",
    /// `MimeType` folded to lower case, same reason.
    mimes_l: []const u8 = "",
    bucket: Bucket = .other,
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry = &.{},

    pub fn deinit(self: *Catalog) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(gpa);
        self.entries = &.{};
    }

    /// The per-bucket tallies behind the launcher's category pills, plus the
    /// grand total the "All" pill shows.
    pub fn counts(self: *const Catalog) struct { buckets: [bucket_count]u32, total: u32 } {
        var buckets = [_]u32{0} ** bucket_count;
        var total: u32 = 0;
        for (self.entries) |e| {
            buckets[@intFromEnum(e.bucket)] += 1;
            total += 1;
        }
        return .{ .buckets = buckets, .total = total };
    }
};

fn env(name: [:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    const s = std.mem.span(p);
    return if (s.len == 0) null else s;
}

/// How deep the scan descends below an applications directory. Real installs
/// are flat or one level down (`kde/…`); a bound keeps a directory of
/// directories from turning the scan into a walk of the whole data dir.
const max_depth: u8 = 3;

fn walk(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    depth: u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (depth > max_depth) return;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .directory) {
            const sub = try std.fs.path.join(alloc, &.{ root, e.name });
            defer alloc.free(sub);
            try walk(alloc, io, sub, depth + 1, out);
        } else if (e.kind == .file or e.kind == .sym_link) {
            // A link counts as a file here: Flatpak exports its desktop files
            // as symlinks into the deployment
            // (`sh.cider.Cider.desktop -> ../../../app/…/sh.cider.Cider.desktop`),
            // so a scan that only accepts plain files silently leaves every
            // Flatpak application out of the menu. A link to a directory, or a
            // dangling one, is dropped further down when nothing reads it.
            if (!std.mem.endsWith(u8, e.name, ".desktop")) continue;
            try out.append(alloc, try std.fs.path.join(alloc, &.{ root, e.name }));
        }
    }
}

const Parsed = struct {
    kind: []const u8 = "",
    name: []const u8 = "",
    generic: []const u8 = "",
    comment: []const u8 = "",
    keywords: []const u8 = "",
    categories: []const u8 = "",
    mimes: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    hidden: bool = false,
    no_display: bool = false,
};

/// Reads only the `[Desktop Entry]` group, first value per key wins, and
/// skips localized keys such as `Name[fr]=…`.
fn parseInto(alloc: std.mem.Allocator, data: []const u8) !Parsed {
    var p = Parsed{};
    var in_group = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        if (std.mem.indexOfScalar(u8, key, '[') != null) continue;
        const raw_val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Hidden")) {
            p.hidden = parseBool(raw_val);
            continue;
        }
        if (std.mem.eql(u8, key, "NoDisplay")) {
            p.no_display = parseBool(raw_val);
            continue;
        }
        const known: ?*[]const u8 = if (std.mem.eql(u8, key, "Type"))
            &p.kind
        else if (std.mem.eql(u8, key, "Name"))
            &p.name
        else if (std.mem.eql(u8, key, "GenericName"))
            &p.generic
        else if (std.mem.eql(u8, key, "Comment"))
            &p.comment
        else if (std.mem.eql(u8, key, "Keywords"))
            &p.keywords
        else if (std.mem.eql(u8, key, "Categories"))
            &p.categories
        else if (std.mem.eql(u8, key, "MimeType"))
            &p.mimes
        else if (std.mem.eql(u8, key, "Exec"))
            &p.exec
        else if (std.mem.eql(u8, key, "Icon"))
            &p.icon
        else
            null;
        const field = known orelse continue;
        if (field.*.len != 0) continue;
        field.* = try alloc.dupe(u8, raw_val);
    }
    return p;
}

fn parseBool(v: []const u8) bool {
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
}

fn lowerAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn beforeName(_: void, a: Entry, b: Entry) bool {
    const ord = std.mem.order(u8, a.fold, b.fold);
    if (ord != .eq) return ord == .lt;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn beforePath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Scan every applications directory, keep the first file seen for each stem,
/// and hand back the sorted catalog. Everything the entries point at lives in
/// the catalog's own arena, so one `deinit` retires the lot.
pub fn load(gpa: std.mem.Allocator, io: std.Io) !Catalog {
    var cat = Catalog{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer cat.deinit();

    const dirs = try app_launch.applicationsDirs(gpa, env("XDG_DATA_HOME"), env("HOME"), env("XDG_DATA_DIRS"));
    defer app_launch.freeDirs(gpa, dirs);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    for (dirs) |d| {
        const before = paths.items.len;
        try walk(gpa, io, d, 0, &paths);
        std.mem.sort([]const u8, paths.items[before..], {}, beforePath);
    }

    var seen = std.StringHashMapUnmanaged(void){};
    defer {
        var kit = seen.keyIterator();
        while (kit.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    var list: std.ArrayList(Entry) = .empty;
    for (paths.items) |p| {
        const stem = std.fs.path.stem(p);
        const key = lowerAlloc(gpa, stem) catch continue;
        const gop = seen.getOrPut(gpa, key) catch {
            gpa.free(key);
            continue;
        };
        if (gop.found_existing) {
            gpa.free(key);
            continue;
        }

        const data = readFile(gpa, io, p) orelse continue;
        const parsed = parseInto(cat.arena.allocator(), data) catch {
            gpa.free(data);
            continue;
        };
        gpa.free(data);
        if (parsed.name.len == 0 or parsed.exec.len == 0) continue;
        if (parsed.hidden or parsed.no_display) continue;
        if (parsed.kind.len > 0 and !std.mem.eql(u8, parsed.kind, "Application")) continue;

        const a = cat.arena.allocator();
        try list.append(a, .{
            .id = try a.dupe(u8, stem),
            .path = try a.dupe(u8, p),
            .name = parsed.name,
            .generic = parsed.generic,
            .comment = parsed.comment,
            .keywords = parsed.keywords,
            .categories = parsed.categories,
            .exec = parsed.exec,
            .icon = parsed.icon,
            .fold = try lowerAlloc(a, parsed.name),
            .cats_l = try lowerAlloc(a, parsed.categories),
            .mimes_l = try lowerAlloc(a, parsed.mimes),
            .bucket = bucketOf(parsed.categories),
        });
    }

    const entries = try list.toOwnedSlice(cat.arena.allocator());
    std.mem.sort(Entry, entries, {}, beforeName);
    cat.entries = entries;
    return cat;
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
}

/// The bucket an entry's `Categories=` line puts it in. Categories are tried
/// in the order the file lists them, and the first one that decides wins.
pub fn bucketOf(categories: []const u8) Bucket {
    var it = std.mem.splitScalar(u8, categories, ';');
    while (it.next()) |raw| {
        const c = std.mem.trim(u8, raw, " \t");
        if (c.len == 0) continue;
        var b: usize = 0;
        while (b < bucket_count - 1) : (b += 1) {
            for (bucket_words[b]) |w| {
                if (std.ascii.eqlIgnoreCase(c, w)) return @enumFromInt(b);
            }
        }
    }
    return .other;
}

fn isBreak(c: u8) bool {
    return switch (c) {
        ' ', '-', '_', '.', '/', '+', ':', ',', '&' => true,
        else => false,
    };
}

fn foldInto(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

/// How well `pattern` — already folded — covers one field of an entry. Zero
/// means "not a subsequence of it at all", which is the only rejection the
/// launcher needs: everything that scores anything is a candidate, and the
/// number just orders them.
///
/// A character that opens a word and a character that continues the previous
/// match both count for more than one that does neither, and the further the
/// first hit sits into the field the less it is worth. That is what makes
/// `calc` find "Calculator" before "PhotoCalc Batch Job" without anyone
/// having to spell out a word list.
fn fieldScore(pattern: []const u8, scratch: []u8, raw: []const u8, weight: u32) u32 {
    if (pattern.len == 0 or raw.len == 0) return 0;
    const hay = foldInto(scratch, raw);
    var points: u32 = 0;
    var hi: usize = 0;
    var last: i64 = -1;
    for (pattern, 0..) |pc, pi| {
        var hit: ?usize = null;
        var j = hi;
        while (j < hay.len) : (j += 1) {
            if (hay[j] == pc) {
                hit = j;
                break;
            }
        }
        const at = hit orelse return 0;
        if (at == 0) {
            points += 14;
        } else if (isBreak(hay[at - 1])) {
            points += 9;
        }
        if (@as(i64, @intCast(at)) == last + 1) points += 12;
        if (pi == 0) points += @as(u32, 30) -| @as(u32, @intCast(at));
        last = @intCast(at);
        hi = at + 1;
    }
    return weight * 100 + points;
}

/// The same, over every semicolon- or space-separated word in a field. A
/// category list is a set of words, not a sentence, so each one is matched on
/// its own rather than against the separators between them.
fn tokenScore(pattern: []const u8, scratch: []u8, raw: []const u8, weight: u32) u32 {
    var best: u32 = 0;
    var it = std.mem.tokenizeAny(u8, raw, ";, \t");
    while (it.next()) |tok| {
        best = @max(best, fieldScore(pattern, scratch, tok, weight));
    }
    return best;
}

/// The rank of one entry against a folded `pattern`, or 0 when it is not a
/// match at all. The name decides most often, then the generic name and the
/// comment, then the free-text keywords and the categories.
pub fn score(pattern: []const u8, e: *const Entry) u32 {
    if (pattern.len == 0) return 1;
    var scratch: [512]u8 = undefined;
    var best = fieldScore(pattern, &scratch, e.fold, 3);
    best = @max(best, fieldScore(pattern, &scratch, e.generic, 2));
    best = @max(best, fieldScore(pattern, &scratch, e.comment, 2));
    best = @max(best, tokenScore(pattern, &scratch, e.keywords, 1));
    best = @max(best, tokenScore(pattern, &scratch, e.categories, 1));
    return best;
}

test "app-catalog: bucket assignment follows the first deciding category" {
    const t = std.testing;
    try t.expectEqual(Bucket.productivity, bucketOf("Office;WordProcessor;"));
    try t.expectEqual(Bucket.games, bucketOf("Game;StrategyGame;"));
    try t.expectEqual(Bucket.developer, bucketOf("Development;IDE;"));
    try t.expectEqual(Bucket.media, bucketOf("AudioVideo;Player;"));
    try t.expectEqual(Bucket.other, bucketOf("Network;WebBrowser;"));
    try t.expectEqual(Bucket.other, bucketOf(""));
    // A category that maps nowhere does not stop the scan of the rest.
    try t.expectEqual(Bucket.utilities, bucketOf("Network;Utility;FileTools;"));
}

test "app-catalog: parsing is first-wins, group-scoped and locale-blind" {
    const t = std.testing;
    var gpa = std.heap.ArenaAllocator.init(t.allocator);
    defer gpa.deinit();
    const data =
        \\# a comment
        \\[Desktop Entry]
        \\Type=Application
        \\Name=First
        \\Name[fr]=Premier
        \\GenericName=Tool
        \\Comment=Does things
        \\Keywords=foo;bar;
        \\Categories=Utility;
        \\Exec=run %U
        \\Icon=tool
        \\Hidden=false
        \\
        \\[Desktop Action new]
        \\Name=Second
        \\Exec=run --new
    ;
    const p = try parseInto(gpa.allocator(), data);
    try t.expectEqualStrings("First", p.name);
    try t.expectEqualStrings("Tool", p.generic);
    try t.expectEqualStrings("Does things", p.comment);
    try t.expectEqualStrings("run %U", p.exec);
    try t.expectEqualStrings("tool", p.icon);
    try t.expectEqualStrings("Utility;", p.categories);
    try t.expect(!p.hidden and !p.no_display);

    const dup = try parseInto(gpa.allocator(), "[Desktop Entry]\nName=One\nName=Two\n");
    try t.expectEqualStrings("One", dup.name);
}

test "app-catalog: a linked desktop file is still an application" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);

    // The export directory and the deployment it links into, spelled the way
    // Flatpak spells them: the readable file lives in the deployment, and the
    // applications directory only ever holds a link to it.
    const deploy = try std.fs.path.join(t.allocator, &.{ root, "deploy" });
    defer t.allocator.free(deploy);
    try cwd.createDirPath(io, deploy);
    const real = try std.fs.path.join(t.allocator, &.{ deploy, "sh.cider.Cider.desktop" });
    defer t.allocator.free(real);
    try cwd.writeFile(io, .{ .sub_path = real, .data =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Cider
        \\Exec=flatpak run sh.cider.Cider
        \\
    });

    const apps = try std.fs.path.join(t.allocator, &.{ root, "applications" });
    defer t.allocator.free(apps);
    try cwd.createDirPath(io, apps);
    const link = try std.fs.path.join(t.allocator, &.{ apps, "sh.cider.Cider.desktop" });
    defer t.allocator.free(link);
    try cwd.symLink(io, "../deploy/sh.cider.Cider.desktop", link, .{});

    // An ordinary entry alongside it, and something that is not an entry.
    const plain = try std.fs.path.join(t.allocator, &.{ apps, "org.example.Plain.desktop" });
    defer t.allocator.free(plain);
    try cwd.writeFile(io, .{ .sub_path = plain, .data = "[Desktop Entry]\nType=Application\nName=Plain\nExec=plain\n" });
    const note = try std.fs.path.join(t.allocator, &.{ apps, "mimeinfo.cache" });
    defer t.allocator.free(note);
    try cwd.writeFile(io, .{ .sub_path = note, .data = "irrelevant\n" });

    var found: std.ArrayList([]const u8) = .empty;
    defer {
        for (found.items) |p| t.allocator.free(p);
        found.deinit(t.allocator);
    }
    try walk(t.allocator, io, apps, 0, &found);
    try t.expectEqual(@as(usize, 2), found.items.len);
    // `walk` hands back whatever the directory yielded; `load` is what sorts,
    // so the test sorts the same way before comparing.
    std.mem.sort([]const u8, found.items, {}, beforePath);
    try t.expectEqualStrings("org.example.Plain.desktop", std.fs.path.basename(found.items[0]));
    try t.expectEqualStrings("sh.cider.Cider.desktop", std.fs.path.basename(found.items[1]));
}

test "app-catalog: scoring orders name above comment, word start above word middle" {
    const t = std.testing;

    var browser = Entry{};
    browser.name = "Web Browser";
    browser.fold = "web browser";
    browser.comment = "Surf the internet";

    var net = Entry{};
    net.name = "Net Tools";
    net.fold = "net tools";
    net.comment = "The web is here";

    try t.expect(score("web", &browser) > score("web", &net));
    try t.expect(score("net", &net) > score("net", &browser));
    try t.expect(score("zzz", &browser) == 0);
    // Every entry answers the same thing to an empty query, so the catalog's
    // own order is what decides the listing.
    try t.expectEqual(@as(u32, 1), score("", &browser));

    var spaced = Entry{};
    spaced.name = "Fire Wall";
    spaced.fold = "fire wall";
    var joined = Entry{};
    joined.name = "Firewall";
    joined.fold = "firewall";
    try t.expect(score("wall", &spaced) > score("wall", &joined));

    // The keyword and category lists are matched word by word.
    var term = Entry{};
    term.name = "Terminal";
    term.fold = "terminal";
    term.keywords = "shell;prompt;console";
    term.categories = "Utility;TerminalEmulator;";
    try t.expect(score("shell", &term) > 0);
    try t.expect(score("terminal", &term) > score("shell", &term));
    try t.expect(score("emulator", &term) > 0);
}
