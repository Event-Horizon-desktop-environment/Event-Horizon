//! Cider 4 local REST client for the desktop Cider widget.
//!
//! Cider's v2 API lives on `127.0.0.1:10767` and gates most routes behind an
//! `apptoken` header. Tokens are kept in plain text in Cider's
//! `spa-config.yml`, so the widget can reuse an existing `Event Horizon`
//! token without asking the user to paste anything. When none exists, the
//! unauthenticated `POST /api/v2/auth/request` route opens Cider's consent
//! dialog and returns a scoped token after approval.
//!
//! Everything here is allocation-explicit and thread-safe: workers build
//! values with a caller allocator, the shell thread takes ownership, and no
//! module-level mutable state lives in this file. The widget's store owns
//! the snapshot lifecycle.

const std = @import("std");
const reflection = @import("../compat/reflection.zig");

pub const base_url = "http://127.0.0.1:10767";
pub const app_name = "Event Horizon";

/// The scopes the widget asks for. `account`, `plugins`, and `config` are
/// deliberately absent: they expose credentials or settings the widget does
/// not need.
pub const requested_scopes = [_][]const u8{
    "playback", "queue", "library", "lyrics", "audio",
};

pub const Scope = enum { playback, queue, library, lyrics, audio, account, plugins, config };

pub const ScopeSet = struct {
    bits: u16 = 0,
    /// A token saved before Cider introduced scopes has none in the file and
    /// is grandfathered to every scope.
    known: bool = false,

    pub fn has(self: ScopeSet, s: Scope) bool {
        if (!self.known) return true;
        return (self.bits & bit(s)) != 0;
    }

    pub fn add(self: *ScopeSet, s: Scope) void {
        self.bits |= bit(s);
    }

    pub fn count(self: ScopeSet) u8 {
        if (!self.known) return @intCast(requested_scopes.len);
        return @popCount(self.bits & all_requested_bits);
    }

    pub fn full(self: ScopeSet) bool {
        return (self.bits & all_requested_bits) == all_requested_bits;
    }
};

const all_requested_bits: u16 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4);

fn bit(s: Scope) u16 {
    return @as(u16, 1) << @intCast(@intFromEnum(s));
}

fn scopeFromName(s: []const u8) ?Scope {
    inline for (reflection.enumFields(Scope)) |f| {
        if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// One token as it appears in Cider's config or in an auth response. All
/// slices are owned by the allocator passed to the parser/detector.
pub const Token = struct {
    value: []u8 = &.{},
    name: []u8 = &.{},
    method: []u8 = &.{},
    scopes: ScopeSet = .{ .known = false },
    remote: bool = false,

    pub fn deinit(self: *Token, alloc: std.mem.Allocator) void {
        if (self.value.len > 0) alloc.free(self.value);
        if (self.name.len > 0) alloc.free(self.name);
        if (self.method.len > 0) alloc.free(self.method);
        self.* = .{};
    }

    pub fn has(self: Token, s: Scope) bool {
        return self.scopes.has(s);
    }
};

pub fn freeTokens(alloc: std.mem.Allocator, tokens: []Token) void {
    for (tokens) |*t| t.deinit(alloc);
    alloc.free(tokens);
}

/// Candidate config locations, in preference order. The Flatpak path is the
/// live one on this machine; the others cover native installs and a custom
/// XDG config root.
fn configPath(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    var candidates: [3]?[]u8 = .{ null, null, null };
    if (std.c.getenv("XDG_CONFIG_HOME")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) candidates[0] = std.fmt.allocPrint(alloc, "{s}/sh.cider.genten/spa-config.yml", .{s}) catch null;
    }
    if (std.c.getenv("HOME")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) {
            if (candidates[0] == null)
                candidates[0] = std.fmt.allocPrint(alloc, "{s}/.config/sh.cider.genten/spa-config.yml", .{s}) catch null;
            candidates[1] = std.fmt.allocPrint(alloc, "{s}/.var/app/sh.cider.Cider/config/sh.cider.genten/spa-config.yml", .{s}) catch null;
        }
    }
    defer {
        if (candidates[0]) |p| alloc.free(p);
        if (candidates[1]) |p| alloc.free(p);
        if (candidates[2]) |p| alloc.free(p);
    }
    const cwd = std.Io.Dir.cwd();
    for (candidates) |maybe| {
        const p = maybe orelse continue;
        if (cwd.readFileAlloc(io, p, alloc, .limited(1 << 20))) |bytes| {
            alloc.free(bytes);
            return alloc.dupe(u8, p) catch null;
        } else |_| {}
    }
    return null;
}

/// Read Cider's config and choose the best usable token. Returns null when
/// Cider's config is absent, unreadable, or has no non-remote token.
pub fn detectToken(alloc: std.mem.Allocator, io: std.Io) ?Token {
    const path = configPath(alloc, io) orelse return null;
    defer alloc.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(data);
    const tokens = parseConfigTokens(alloc, data) catch return null;
    defer freeTokens(alloc, tokens);

    var best: ?usize = null;
    var best_score: i32 = -1;
    for (tokens, 0..) |t, i| {
        if (t.value.len == 0) continue;
        if (t.remote) continue;
        if (std.ascii.eqlIgnoreCase(t.method, "lan") or std.ascii.eqlIgnoreCase(t.method, "tunnel")) continue;
        var score: i32 = 0;
        if (t.has(.playback)) score += 8 else continue;
        if (t.has(.queue)) score += 4;
        if (t.has(.library)) score += 4;
        if (t.has(.lyrics)) score += 4;
        if (t.has(.audio)) score += 2;
        if (std.ascii.eqlIgnoreCase(t.name, app_name)) score += 3;
        if (score > best_score) {
            best_score = score;
            best = i;
        }
    }
    const idx = best orelse return null;
    const out = tokens[idx];
    tokens[idx] = .{};
    return out;
}

/// Parse the `connectivity.apiTokens` list out of Cider's YAML. This is a
/// deliberately small YAML reader: it understands the shapes Cider writes
/// (block lists, inline scope arrays, quoted strings) and ignores the rest
/// of the file, not a general YAML implementation.
pub fn parseConfigTokens(alloc: std.mem.Allocator, text: []const u8) ![]Token {
    var list: std.ArrayListUnmanaged(Token) = .empty;
    var current: ?Token = null;
    errdefer {
        if (current) |*t| t.deinit(alloc);
        for (list.items) |*t| t.deinit(alloc);
        list.deinit(alloc);
    }

    var in_connectivity = false;
    var in_tokens = false;
    var token_indent: usize = 0;
    var scopes_block = false;
    var scopes_indent: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = countIndent(line);

        if (!in_connectivity) {
            if (std.mem.eql(u8, trimmed, "connectivity:") and indent == 0) {
                in_connectivity = true;
                in_tokens = false;
            }
            continue;
        }
        if (!in_tokens and indent <= 0 and !std.mem.startsWith(u8, trimmed, "connectivity:")) {
            in_connectivity = false;
            continue;
        }
        if (!in_tokens) {
            if (std.mem.startsWith(u8, trimmed, "apiTokens:")) {
                in_tokens = true;
                token_indent = indent;
                scopes_block = false;
            }
            continue;
        }
        if (indent <= token_indent) {
            if (current) |*t| {
                try list.append(alloc, t.*);
                current = null;
            }
            in_tokens = false;
            scopes_block = false;
            continue;
        }

        const is_item = std.mem.startsWith(u8, trimmed, "-");
        if (is_item and (!scopes_block or indent <= scopes_indent)) {
            if (current) |*t| {
                try list.append(alloc, t.*);
                current = null;
            }
            scopes_block = false;
            current = .{};
            const rest = std.mem.trim(u8, trimmed[1..], " \t");
            if (rest.len > 0) try parseField(&current.?, rest, alloc);
            continue;
        }
        if (scopes_block and is_item and indent > scopes_indent) {
            const sv = unquote(std.mem.trim(u8, trimmed[1..], " \t"));
            if (current) |*t| {
                if (scopeFromName(sv)) |sc| t.scopes.add(sc);
            }
            continue;
        }
        if (current) |*t| {
            scopes_block = false;
            try parseField(t, trimmed, alloc);
            if (std.mem.startsWith(u8, trimmed, "scopes:")) {
                const rest = std.mem.trim(u8, trimmed["scopes:".len..], " \t");
                if (rest.len == 0) {
                    scopes_block = true;
                    scopes_indent = indent;
                }
            }
        }
    }
    if (current) |*t| {
        try list.append(alloc, t.*);
        current = null;
    }
    return list.toOwnedSlice(alloc);
}

fn parseField(t: *Token, text: []const u8, alloc: std.mem.Allocator) !void {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return;
    const key = std.mem.trim(u8, text[0..colon], " \t");
    const raw = std.mem.trim(u8, text[colon + 1 ..], " \t");
    const val = unquote(raw);
    if (std.ascii.eqlIgnoreCase(key, "name")) {
        if (t.name.len > 0) alloc.free(t.name);
        t.name = try alloc.dupe(u8, val);
    } else if (std.ascii.eqlIgnoreCase(key, "token")) {
        if (t.value.len > 0) alloc.free(t.value);
        t.value = try alloc.dupe(u8, val);
    } else if (std.ascii.eqlIgnoreCase(key, "method")) {
        if (t.method.len > 0) alloc.free(t.method);
        t.method = try alloc.dupe(u8, val);
    } else if (std.ascii.eqlIgnoreCase(key, "isRemote")) {
        t.remote = std.ascii.eqlIgnoreCase(val, "true");
    } else if (std.ascii.eqlIgnoreCase(key, "scopes")) {
        t.scopes.known = true;
        var rest = std.mem.trim(u8, val, " \t");
        if (rest.len >= 2 and rest[0] == '[' and rest[rest.len - 1] == ']') rest = rest[1 .. rest.len - 1];
        if (rest.len == 0) return;
        var it = std.mem.splitScalar(u8, rest, ',');
        while (it.next()) |part| {
            const name = unquote(std.mem.trim(u8, part, " \t"));
            if (scopeFromName(name)) |sc| t.scopes.add(sc);
        }
    }
}

fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |ch, i| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) return line[0..i];
    }
    return line;
}

fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) : (n += 1) {}
    return n;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0])
        return s[1 .. s.len - 1];
    return s;
}

// ---------------------------------------------------------------------------
// HTTP plumbing

pub const Reply = struct {
    status: u16,
    body: []u8,
};

pub fn http(
    alloc: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    path: []const u8,
    token: ?[]const u8,
    body: ?[]const u8,
    max_bytes: usize,
) !Reply {
    var url_buf: [1024]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base_url, path });
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var headers: [2]std.http.Header = undefined;
    var n: usize = 0;
    if (token) |t| {
        if (t.len > 0) {
            headers[n] = .{ .name = "apptoken", .value = t };
            n += 1;
        }
    }
    if (body != null) {
        headers[n] = .{ .name = "content-type", .value = "application/json" };
        n += 1;
    }
    const res = try client.fetch(.{
        .method = method,
        .location = .{ .url = url },
        .extra_headers = headers[0..n],
        .payload = body,
        .response_writer = &aw.writer,
    });
    const bytes = try aw.toOwnedSlice();
    if (bytes.len > max_bytes) {
        alloc.free(bytes);
        return error.TooLarge;
    }
    return .{ .status = @intFromEnum(res.status), .body = bytes };
}

pub const Link = enum { unknown, checking, connected, needs_token, token_invalid, offline };

pub const Probe = struct {
    link: Link = .unknown,
    http: u16 = 0,
    version: [32]u8 = undefined,
    version_len: u8 = 0,

    pub fn versionText(self: *const Probe) []const u8 {
        return self.version[0..self.version_len];
    }
};

pub fn probe(alloc: std.mem.Allocator, io: std.Io, token: ?[]const u8) Probe {
    const rep = http(alloc, io, .GET, "/api/v2/client/info", token, null, 32 * 1024) catch |err| {
        return .{ .link = switch (err) {
            error.ConnectionRefused, error.NetworkUnreachable => .offline,
            else => .offline,
        } };
    };
    defer alloc.free(rep.body);
    if (rep.status == 200) {
        var out = Probe{ .link = .connected, .http = rep.status };
        var vbuf: [32]u8 = undefined;
        const version = parseInfoVersion(rep.body, &vbuf);
        const n = @min(version.len, out.version.len);
        @memcpy(out.version[0..n], version[0..n]);
        out.version_len = @intCast(n);
        return out;
    }
    if (rep.status == 403) return .{
        .link = if (token != null) .token_invalid else .needs_token,
        .http = rep.status,
    };
    return .{ .link = .offline, .http = rep.status };
}

fn parseInfoVersion(text: []const u8, buf: []u8) []const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, text, .{}) catch return "";
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return "",
    };
    const data = root.get("data") orelse return "";
    if (data != .object) return "";
    const v = data.object.get("version") orelse return "";
    if (v != .string) return "";
    const n = @min(v.string.len, buf.len);
    @memcpy(buf[0..n], v.string[0..n]);
    return buf[0..n];
}

pub const AuthResult = union(enum) {
    token: Token,
    denied,
    timeout,
    busy,
    cooldown,
    banned,
    http: u16,
};

pub fn requestAuth(alloc: std.mem.Allocator, io: std.Io) !AuthResult {
    const body =
        \\{"app_name":"Event Horizon","scopes":["playback","queue","library","lyrics","audio"]}
    ;
    const rep = try http(alloc, io, .POST, "/api/v2/auth/request", null, body, 64 * 1024);
    defer alloc.free(rep.body);
    switch (rep.status) {
        200 => {
            const token = parseAuthToken(alloc, rep.body) catch return .{ .http = 200 };
            return .{ .token = token };
        },
        403 => return .denied,
        408 => return .timeout,
        409 => return .busy,
        429 => {
            if (std.mem.indexOf(u8, rep.body, "AUTH_REQUEST_BANNED") != null) return .banned;
            return .cooldown;
        },
        else => return .{ .http = rep.status },
    }
}

fn parseAuthToken(alloc: std.mem.Allocator, text: []const u8) !Token {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadResponse,
    };
    const data = root.get("data") orelse return error.BadResponse;
    if (data != .object) return error.BadResponse;
    const tok = data.object.get("token") orelse return error.BadResponse;
    if (tok != .string or tok.string.len == 0) return error.BadResponse;

    var out = Token{
        .value = try alloc.dupe(u8, tok.string),
        .name = try alloc.dupe(u8, app_name),
        .scopes = .{ .known = true },
    };
    errdefer out.deinit(alloc);
    if (data.object.get("scopes")) |sc| {
        if (sc == .array) {
            for (sc.array.items) |v| {
                if (v == .string) {
                    if (scopeFromName(v.string)) |s| out.scopes.add(s);
                }
            }
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Shared JSON helpers

fn jstr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn jint(v: std.json.Value) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

fn jfloat(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

fn jbool(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn objStr(v: std.json.Value, key: []const u8) []const u8 {
    return if (objGet(v, key)) |x| jstr(x) else "";
}

fn objInt(v: std.json.Value, key: []const u8) i64 {
    return if (objGet(v, key)) |x| jint(x) else 0;
}

fn objFloat(v: std.json.Value, key: []const u8) f64 {
    return if (objGet(v, key)) |x| jfloat(x) else 0;
}

fn objBool(v: std.json.Value, key: []const u8) bool {
    return if (objGet(v, key)) |x| jbool(x) else false;
}

fn dataOf(root: std.json.Value) ?std.json.Value {
    return objGet(root, "data");
}

fn artworkOf(attributes: std.json.Value, alloc: std.mem.Allocator) ![]u8 {
    const art = objGet(attributes, "artwork") orelse return &.{};
    const raw = objStr(art, "url");
    if (raw.len == 0) return &.{};
    return formatArtwork(alloc, raw);
}

/// v2 formulates artwork URLs already, but a few endpoints still hand back
/// MusicKit's `{w}` / `{h}` placeholders. Resolve them at a sensible size.
fn formatArtwork(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, raw, "{w}") == null and std.mem.indexOf(u8, raw, "{h}") == null)
        return alloc.dupe(u8, raw);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) {
        if (std.mem.startsWith(u8, raw[i..], "{w}")) {
            try out.appendSlice(alloc, "600");
            i += 3;
        } else if (std.mem.startsWith(u8, raw[i..], "{h}")) {
            try out.appendSlice(alloc, "600");
            i += 3;
        } else {
            try out.append(alloc, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn fmtDuration(alloc: std.mem.Allocator, ms: i64) ![]u8 {
    const total: u64 = @intCast(@divTrunc(@max(ms, 0), 1000));
    return std.fmt.allocPrint(alloc, "{d}:{d:0>2}", .{ total / 60, total % 60 });
}

// ---------------------------------------------------------------------------
// Queue

pub const QueueItem = struct {
    id: []u8 = &.{},
    type: []u8 = &.{},
    title: []u8 = &.{},
    artist: []u8 = &.{},
    album: []u8 = &.{},
    art_url: []u8 = &.{},
    duration_ms: i64 = 0,
};

pub const QueuePage = struct {
    arena: std.heap.ArenaAllocator,
    items: []QueueItem = &.{},
    position: i64 = 0,
    offset: i64 = 0,
    total: i64 = 0,

    pub fn deinit(self: *QueuePage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn fetchQueue(
    alloc: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    offset: i64,
    limit: i64,
) !QueuePage {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/api/v2/queue?offset={d}&limit={d}", .{ offset, limit });
    const rep = try http(alloc, io, .GET, path, token, null, 512 * 1024);
    defer alloc.free(rep.body);
    if (rep.status != 200) return error.HttpStatus;
    return parseQueue(alloc, rep.body);
}

pub fn parseQueue(alloc: std.mem.Allocator, text: []const u8) !QueuePage {
    var page = QueuePage{ .arena = std.heap.ArenaAllocator.init(alloc) };
    errdefer page.deinit();
    const a = page.arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const data = dataOf(parsed.value) orelse return error.BadResponse;
    const items_v = objGet(data, "items") orelse return error.BadResponse;
    if (items_v != .array) return error.BadResponse;

    var items: std.ArrayListUnmanaged(QueueItem) = .empty;
    errdefer items.deinit(a);
    for (items_v.array.items) |entry| {
        if (entry != .object) continue;
        const track = objGet(entry, "track") orelse entry;
        const attrs = objGet(track, "attributes") orelse track;
        const title = objStr(attrs, "name");
        const artist = objStr(attrs, "artistName");
        if (title.len == 0 and artist.len == 0) continue;
        try items.append(a, .{
            .id = try a.dupe(u8, objStr(track, "id")),
            .type = try a.dupe(u8, objStr(track, "type")),
            .title = try a.dupe(u8, if (title.len > 0) title else "Unknown Track"),
            .artist = try a.dupe(u8, artist),
            .album = try a.dupe(u8, objStr(attrs, "albumName")),
            .art_url = try artworkOf(attrs, a),
            .duration_ms = objInt(attrs, "durationInMillis"),
        });
    }
    page.items = try items.toOwnedSlice(a);
    page.position = objInt(data, "position");
    page.offset = if (objGet(parsed.value, "meta")) |m| objInt(m, "offset") else 0;
    page.total = if (objGet(parsed.value, "meta")) |m| objInt(m, "total") else @as(i64, @intCast(page.items.len));
    return page;
}

// ---------------------------------------------------------------------------
// Library

pub const LibraryKind = enum {
    playlists,
    albums,
    songs,
    artists,
    playlist_songs,
    album_songs,
    artist_albums,

    pub fn gridKind(self: LibraryKind) LibraryKind {
        return switch (self) {
            .playlist_songs, .album_songs => .songs,
            .artist_albums => .albums,
            else => self,
        };
    }

    pub fn isSongs(self: LibraryKind) bool {
        return switch (self) {
            .songs, .playlist_songs, .album_songs => true,
            else => false,
        };
    }
};

pub const LibraryItem = struct {
    id: []u8 = &.{},
    name: []u8 = &.{},
    subtitle: []u8 = &.{},
    extra: []u8 = &.{},
    art_url: []u8 = &.{},
    duration_ms: i64 = 0,
    track_count: i64 = 0,
};

pub const LibraryPage = struct {
    arena: std.heap.ArenaAllocator,
    items: []LibraryItem = &.{},
    kind: LibraryKind = .playlists,
    offset: i64 = 0,
    total: i64 = 0,

    pub fn deinit(self: *LibraryPage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn libraryPath(buf: []u8, kind: LibraryKind, id: []const u8, offset: i64, limit: i64) ![]const u8 {
    return switch (kind) {
        .playlists => std.fmt.bufPrint(buf, "/api/v2/library/playlists?offset={d}&limit={d}", .{ offset, limit }),
        .albums => std.fmt.bufPrint(buf, "/api/v2/library/albums?offset={d}&limit={d}", .{ offset, limit }),
        .songs => std.fmt.bufPrint(buf, "/api/v2/library/songs?offset={d}&limit={d}", .{ offset, limit }),
        .artists => std.fmt.bufPrint(buf, "/api/v2/library/artists?offset={d}&limit={d}", .{ offset, limit }),
        .playlist_songs => std.fmt.bufPrint(buf, "/api/v2/library/playlists/{s}/songs?offset={d}&limit={d}", .{ id, offset, limit }),
        .album_songs => std.fmt.bufPrint(buf, "/api/v2/library/albums/{s}/songs?offset={d}&limit={d}", .{ id, offset, limit }),
        .artist_albums => std.fmt.bufPrint(buf, "/api/v2/library/artists/{s}/albums?offset={d}&limit={d}", .{ id, offset, limit }),
    };
}

pub fn fetchLibrary(
    alloc: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    kind: LibraryKind,
    id: []const u8,
    offset: i64,
    limit: i64,
) !LibraryPage {
    var buf: [512]u8 = undefined;
    const path = try libraryPath(&buf, kind, id, offset, limit);
    const rep = try http(alloc, io, .GET, path, token, null, 1024 * 1024);
    defer alloc.free(rep.body);
    if (rep.status != 200) return error.HttpStatus;
    return parseLibrary(alloc, rep.body, kind);
}

pub fn parseLibrary(alloc: std.mem.Allocator, text: []const u8, kind: LibraryKind) !LibraryPage {
    var page = LibraryPage{ .arena = std.heap.ArenaAllocator.init(alloc), .kind = kind };
    errdefer page.deinit();
    const a = page.arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const data = dataOf(parsed.value) orelse return error.BadResponse;
    const items_v = objGet(data, "items") orelse return error.BadResponse;
    if (items_v != .array) return error.BadResponse;

    var items: std.ArrayListUnmanaged(LibraryItem) = .empty;
    errdefer items.deinit(a);
    for (items_v.array.items) |entry| {
        if (entry != .object) continue;
        const attrs = objGet(entry, "attributes") orelse entry;
        const name = objStr(attrs, "name");
        if (name.len == 0) continue;
        const artist = objStr(attrs, "artistName");
        const album = objStr(attrs, "albumName");
        const dur = objInt(attrs, "durationInMillis");
        const count = objInt(attrs, "trackCount");
        const subtitle = switch (kind) {
            .playlists => "Playlist",
            .albums, .artist_albums => artist,
            .songs, .playlist_songs, .album_songs => if (artist.len > 0 and album.len > 0)
                try std.fmt.allocPrint(a, "{s} — {s}", .{ artist, album })
            else if (artist.len > 0)
                try a.dupe(u8, artist)
            else
                try a.dupe(u8, album),
            .artists => "Artist",
        };
        const extra = switch (kind) {
            .playlists, .albums, .artist_albums => if (count > 0)
                try std.fmt.allocPrint(a, "{d} songs", .{count})
            else
                try a.dupe(u8, ""),
            .songs, .playlist_songs, .album_songs => try fmtDuration(a, dur),
            .artists => try a.dupe(u8, ""),
        };
        try items.append(a, .{
            .id = try a.dupe(u8, objStr(entry, "id")),
            .name = try a.dupe(u8, name),
            .subtitle = try a.dupe(u8, subtitle),
            .extra = try a.dupe(u8, extra),
            .art_url = try artworkOf(attrs, a),
            .duration_ms = dur,
            .track_count = count,
        });
    }
    page.items = try items.toOwnedSlice(a);
    page.offset = if (objGet(parsed.value, "meta")) |m| objInt(m, "offset") else 0;
    page.total = if (objGet(parsed.value, "meta")) |m| objInt(m, "total") else @as(i64, @intCast(page.items.len));
    return page;
}

// ---------------------------------------------------------------------------
// Lyrics

pub const LyricLine = struct {
    text: []u8 = &.{},
    start: f64 = 0,
    end: f64 = 0,
};

pub const LyricsPage = struct {
    arena: std.heap.ArenaAllocator,
    lines: []LyricLine = &.{},
    provider: []u8 = &.{},
    timing: []u8 = &.{},
    track_id: []u8 = &.{},

    pub fn deinit(self: *LyricsPage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn fetchLyrics(alloc: std.mem.Allocator, io: std.Io, token: []const u8) !LyricsPage {
    const rep = try http(alloc, io, .GET, "/api/v2/lyrics/current", token, null, 1024 * 1024);
    defer alloc.free(rep.body);
    if (rep.status == 404) return error.NoLyrics;
    if (rep.status != 200) return error.HttpStatus;
    return parseLyrics(alloc, rep.body);
}

pub fn parseLyrics(alloc: std.mem.Allocator, text: []const u8) !LyricsPage {
    var page = LyricsPage{ .arena = std.heap.ArenaAllocator.init(alloc) };
    errdefer page.deinit();
    const a = page.arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const data = dataOf(parsed.value) orelse return error.BadResponse;
    const lines_v = objGet(data, "lines") orelse return error.NoLyrics;
    if (lines_v != .array) return error.NoLyrics;

    var lines: std.ArrayListUnmanaged(LyricLine) = .empty;
    errdefer lines.deinit(a);
    for (lines_v.array.items) |entry| {
        if (entry != .object) continue;
        if (objBool(entry, "empty")) continue;
        const txt = objStr(entry, "text");
        if (txt.len == 0) continue;
        try lines.append(a, .{
            .text = try a.dupe(u8, txt),
            .start = objFloat(entry, "start"),
            .end = objFloat(entry, "end"),
        });
    }
    page.lines = try lines.toOwnedSlice(a);
    if (objGet(data, "source")) |src| {
        page.provider = try a.dupe(u8, objStr(src, "provider"));
        page.timing = try a.dupe(u8, objStr(src, "timingType"));
    }
    page.track_id = try a.dupe(u8, objStr(data, "id"));
    return page;
}

// ---------------------------------------------------------------------------
// Audio + playback state

pub const ListeningMode = enum { off, game, antifatigue };

pub const AudioState = struct {
    available: bool = false,
    crossfade: bool = false,
    automix: bool = false,
    atmos: bool = false,
    normalization: bool = false,
    listening: ListeningMode = .off,
    volume: f64 = 0.5,
    has_volume: bool = false,
};

fn getData(alloc: std.mem.Allocator, io: std.Io, token: []const u8, path: []const u8) ![]u8 {
    const rep = try http(alloc, io, .GET, path, token, null, 256 * 1024);
    defer alloc.free(rep.body);
    if (rep.status != 200) return error.HttpStatus;
    return alloc.dupe(u8, rep.body);
}

fn jsonData(alloc: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, text, .{});
}

pub fn fetchAudio(alloc: std.mem.Allocator, io: std.Io, token: []const u8) AudioState {
    var out = AudioState{};
    if (getData(alloc, io, token, "/api/v2/audio/crossfade")) |body| {
        defer alloc.free(body);
        if (jsonData(alloc, body)) |parsed| {
            defer parsed.deinit();
            if (dataOf(parsed.value)) |d| out.crossfade = objBool(d, "enabled");
            out.available = true;
        } else |_| {}
    } else |_| {}
    if (getData(alloc, io, token, "/api/v2/audio/automix")) |body| {
        defer alloc.free(body);
        if (jsonData(alloc, body)) |parsed| {
            defer parsed.deinit();
            if (dataOf(parsed.value)) |d| out.automix = objBool(d, "enabled");
            out.available = true;
        } else |_| {}
    } else |_| {}
    if (getData(alloc, io, token, "/api/v2/audio/atmos")) |body| {
        defer alloc.free(body);
        if (jsonData(alloc, body)) |parsed| {
            defer parsed.deinit();
            if (dataOf(parsed.value)) |d| out.atmos = objBool(d, "enabled");
            out.available = true;
        } else |_| {}
    } else |_| {}
    if (getData(alloc, io, token, "/api/v2/audio/normalization")) |body| {
        defer alloc.free(body);
        if (jsonData(alloc, body)) |parsed| {
            defer parsed.deinit();
            if (dataOf(parsed.value)) |d| out.normalization = objBool(d, "enabled");
            out.available = true;
        } else |_| {}
    } else |_| {}
    if (getData(alloc, io, token, "/api/v2/audio/listening-mode")) |body| {
        defer alloc.free(body);
        if (jsonData(alloc, body)) |parsed| {
            defer parsed.deinit();
            if (dataOf(parsed.value)) |d| {
                const mode = objStr(d, "mode");
                out.listening = if (std.mem.eql(u8, mode, "game"))
                    .game
                else if (std.mem.eql(u8, mode, "antifatigue"))
                    .antifatigue
                else
                    .off;
            }
            out.available = true;
        } else |_| {}
    } else |_| {}
    return out;
}

fn copyFixed(comptime N: usize, dst: *[N]u8, len: anytype, src: []const u8) void {
    const n = @min(src.len, N);
    @memcpy(dst[0..n], src[0..n]);
    len.* = @intCast(n);
}

/// Snapshot of Cider's own player. The fixed buffers keep this a plain value
/// that can cross the worker boundary without an allocator life story.
pub const PlaybackState = struct {
    available: bool = false,
    in_favorites: bool = false,
    in_library: bool = false,
    lossless: bool = false,
    flavor: [32]u8 = undefined,
    flavor_len: u8 = 0,
    flavor_label: [64]u8 = undefined,
    flavor_label_len: u8 = 0,
    title: [256]u8 = undefined,
    title_len: u8 = 0,
    artist: [160]u8 = undefined,
    artist_len: u8 = 0,
    album: [256]u8 = undefined,
    album_len: u8 = 0,
    art_url: [768]u8 = undefined,
    art_len: u16 = 0,
    state: [16]u8 = undefined,
    state_len: u8 = 0,
    position_ms: i64 = 0,
    duration_ms: i64 = 0,
    volume: f64 = 0.5,
    has_volume: bool = false,
    shuffle: bool = false,
    repeat: [12]u8 = undefined,
    repeat_len: u8 = 0,

    pub fn flavorText(self: *const PlaybackState) []const u8 {
        return self.flavor[0..self.flavor_len];
    }
    pub fn flavorLabelText(self: *const PlaybackState) []const u8 {
        return self.flavor_label[0..self.flavor_label_len];
    }
    pub fn titleText(self: *const PlaybackState) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn artistText(self: *const PlaybackState) []const u8 {
        return self.artist[0..self.artist_len];
    }
    pub fn albumText(self: *const PlaybackState) []const u8 {
        return self.album[0..self.album_len];
    }
    pub fn artText(self: *const PlaybackState) []const u8 {
        return self.art_url[0..self.art_len];
    }
    pub fn stateText(self: *const PlaybackState) []const u8 {
        return self.state[0..self.state_len];
    }
    pub fn repeatText(self: *const PlaybackState) []const u8 {
        return self.repeat[0..self.repeat_len];
    }
    pub fn playing(self: *const PlaybackState) bool {
        return std.mem.eql(u8, self.stateText(), "playing");
    }
};

pub fn fetchPlayback(alloc: std.mem.Allocator, io: std.Io, token: []const u8) PlaybackState {
    var out = PlaybackState{};
    const body = getData(alloc, io, token, "/api/v2/playback") catch return out;
    defer alloc.free(body);
    var parsed = jsonData(alloc, body) catch return out;
    defer parsed.deinit();
    const data = dataOf(parsed.value) orelse return out;
    out.available = true;
    out.in_library = objBool(data, "inLibrary");
    copyFixed(out.state.len, &out.state, &out.state_len, objStr(data, "state"));
    out.shuffle = objBool(data, "shuffleMode");
    copyFixed(out.repeat.len, &out.repeat, &out.repeat_len, objStr(data, "repeatMode"));
    if (objGet(data, "volume")) |v| {
        out.volume = jfloat(v);
        out.has_volume = true;
    }
    if (objGet(data, "time")) |time| {
        const current = objFloat(time, "currentTime");
        // v2 reports currentTime in seconds; tolerate a millisecond-shaped
        // value from older builds.
        out.position_ms = if (current > 100_000.0) @intFromFloat(current) else @intFromFloat(current * 1000.0);
        out.duration_ms = objInt(time, "durationInMillis");
    }
    if (objGet(data, "nowPlaying")) |np| {
        if (np == .object) {
            out.in_favorites = objBool(np, "inFavorites");
            out.in_library = objBool(np, "inLibrary");
            copyFixed(out.flavor.len, &out.flavor, &out.flavor_len, objStr(np, "flavor"));
            if (objGet(np, "audioTraits")) |traits| {
                if (traits == .array) {
                    for (traits.array.items) |trait| {
                        if (trait == .string and std.mem.indexOf(u8, trait.string, "lossless") != null) {
                            out.lossless = true;
                            break;
                        }
                    }
                }
            }
            copyFixed(out.title.len, &out.title, &out.title_len, objStr(np, "name"));
            copyFixed(out.artist.len, &out.artist, &out.artist_len, objStr(np, "artistName"));
            copyFixed(out.album.len, &out.album, &out.album_len, objStr(np, "albumName"));
            out.duration_ms = objInt(np, "durationInMillis");
            if (objGet(np, "artwork")) |art| {
                const raw = objStr(art, "url");
                if (raw.len > 0) {
                    const formatted = formatArtwork(alloc, raw) catch null;
                    defer if (formatted) |f| alloc.free(f);
                    copyFixed(out.art_url.len, &out.art_url, &out.art_len, formatted orelse raw);
                }
            }
        }
    }
    // The playback payload only carries the quality code (64, 256, atmos,
    // local_*). The companion endpoint has the human label, so prefer it and
    // keep the code as a fallback for older builds.
    if (getData(alloc, io, token, "/api/v2/playback/audio-quality")) |qbody| {
        defer alloc.free(qbody);
        if (jsonData(alloc, qbody)) |quality_json| {
            defer quality_json.deinit();
            if (dataOf(quality_json.value)) |d| {
                const label = objStr(d, "flavorLabel");
                copyFixed(out.flavor_label.len, &out.flavor_label, &out.flavor_label_len, label);
            }
        } else |_| {}
    } else |_| {}
    return out;
}

/// Turn Cider's audio-quality code into something a person can read. When a
/// build supplies an unprintable icon code instead of a label, fall back to
/// the track's lossless trait rather than letting the text renderer draw tofu.
pub fn qualityName(raw: []const u8, lossless: bool) []const u8 {
    if (raw.len == 0) return if (lossless) "Lossless" else "Cider";
    if (std.mem.eql(u8, raw, "64")) return "AAC 64kbps";
    if (std.mem.eql(u8, raw, "256")) return "AAC 256kbps";
    if (std.mem.eql(u8, raw, "bin_64")) return "Binaural 64kbps";
    if (std.mem.eql(u8, raw, "bin_256")) return "Binaural 256kbps";
    if (std.mem.eql(u8, raw, "atmos")) return "Dolby Atmos";
    if (std.mem.eql(u8, raw, "unk")) return "Audio";
    if (std.mem.startsWith(u8, raw, "local_")) return "Local file";
    if (std.mem.indexOf(u8, raw, "lossless") != null or std.mem.indexOf(u8, raw, "alac") != null)
        return "Lossless";
    for (raw) |ch| {
        if (ch < 0x20 or ch > 0x7e) return if (lossless) "Lossless" else "Apple Music";
    }
    return raw;
}

pub const NowStatus = struct {
    available: bool = false,
    in_library: bool = false,
    rating: i8 = 0,
};

pub fn fetchNowStatus(alloc: std.mem.Allocator, io: std.Io, token: []const u8) NowStatus {
    var out = NowStatus{};
    const body = getData(alloc, io, token, "/api/v2/library/now-playing/status") catch return out;
    defer alloc.free(body);
    var parsed = jsonData(alloc, body) catch return out;
    defer parsed.deinit();
    const data = dataOf(parsed.value) orelse return out;
    out.available = true;
    out.in_library = objBool(data, "inLibrary");
    const r = objInt(data, "rating");
    out.rating = @intCast(std.math.clamp(r, -1, 1));
    return out;
}

// ---------------------------------------------------------------------------
// Controls

fn okStatus(rep: Reply) bool {
    return rep.status >= 200 and rep.status < 300;
}

pub fn post(
    alloc: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    method: std.http.Method,
    path: []const u8,
    body: []const u8,
) bool {
    const rep = http(alloc, io, method, path, token, body, 64 * 1024) catch return false;
    defer alloc.free(rep.body);
    return okStatus(rep);
}

pub fn postNoBody(
    alloc: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    method: std.http.Method,
    path: []const u8,
) bool {
    const rep = http(alloc, io, method, path, token, null, 64 * 1024) catch return false;
    defer alloc.free(rep.body);
    return okStatus(rep);
}

pub fn playItem(alloc: std.mem.Allocator, io: std.Io, token: []const u8, typ: []const u8, id: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"type\":\"{s}\",\"id\":\"{s}\"}}", .{ typ, id }) catch return false;
    return post(alloc, io, token, .POST, "/api/v2/playback/play-item", body);
}

pub fn playCollection(alloc: std.mem.Allocator, io: std.Io, token: []const u8, typ: []const u8, id: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"type\":\"{s}\",\"id\":\"{s}\"}}", .{ typ, id }) catch return false;
    return post(alloc, io, token, .POST, "/api/v2/playback/play-collection", body);
}

pub fn queueJump(alloc: std.mem.Allocator, io: std.Io, token: []const u8, index: i64) bool {
    var buf: [96]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"index\":{d}}}", .{index}) catch return false;
    return post(alloc, io, token, .POST, "/api/v2/queue/jump", body);
}

pub fn queueRemove(alloc: std.mem.Allocator, io: std.Io, token: []const u8, index: i64) bool {
    var buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/api/v2/queue/items/{d}", .{index}) catch return false;
    return postNoBody(alloc, io, token, .DELETE, path);
}

pub fn queueAddNext(alloc: std.mem.Allocator, io: std.Io, token: []const u8, typ: []const u8, id: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"type\":\"{s}\",\"id\":\"{s}\"}}", .{ typ, id }) catch return false;
    return post(alloc, io, token, .POST, "/api/v2/queue/add-next", body);
}

pub fn loveCurrent(alloc: std.mem.Allocator, io: std.Io, token: []const u8, on: bool) bool {
    const path = if (on) "/api/v2/library/now-playing/love" else "/api/v2/library/now-playing/rating";
    const method: std.http.Method = if (on) .POST else .DELETE;
    return postNoBody(alloc, io, token, method, path);
}

pub fn addCurrent(alloc: std.mem.Allocator, io: std.Io, token: []const u8, on: bool) bool {
    const path = if (on) "/api/v2/library/now-playing/add" else "/api/v2/library/now-playing";
    const method: std.http.Method = if (on) .POST else .DELETE;
    return postNoBody(alloc, io, token, method, path);
}

pub fn setAudioBool(alloc: std.mem.Allocator, io: std.Io, token: []const u8, what: []const u8, on: bool) bool {
    var buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/api/v2/audio/{s}", .{what}) catch return false;
    const body = if (on) "{\"enabled\":true}" else "{\"enabled\":false}";
    return post(alloc, io, token, .PATCH, path, body);
}

pub fn setListeningMode(alloc: std.mem.Allocator, io: std.Io, token: []const u8, mode: []const u8) bool {
    var buf: [96]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"mode\":\"{s}\"}}", .{mode}) catch return false;
    return post(alloc, io, token, .PATCH, "/api/v2/audio/listening-mode", body);
}

pub fn setVolume(alloc: std.mem.Allocator, io: std.Io, token: []const u8, v: f64) bool {
    var buf: [128]u8 = undefined;
    const clamped = std.math.clamp(v, 0.0, 1.0);
    const body = std.fmt.bufPrint(&buf, "{{\"volume\":{d:.3}}}", .{clamped}) catch return false;
    return post(alloc, io, token, .PATCH, "/api/v2/audio/volume", body);
}

pub fn playbackToggle(alloc: std.mem.Allocator, io: std.Io, token: []const u8) bool {
    return postNoBody(alloc, io, token, .POST, "/api/v2/playback/toggle");
}

pub fn playbackNext(alloc: std.mem.Allocator, io: std.Io, token: []const u8) bool {
    return postNoBody(alloc, io, token, .POST, "/api/v2/playback/next");
}

pub fn playbackPrevious(alloc: std.mem.Allocator, io: std.Io, token: []const u8) bool {
    return postNoBody(alloc, io, token, .POST, "/api/v2/playback/previous");
}

pub fn playbackSeek(alloc: std.mem.Allocator, io: std.Io, token: []const u8, seconds: f64) bool {
    var buf: [96]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"position\":{d:.3}}}", .{@max(seconds, 0.0)}) catch return false;
    return post(alloc, io, token, .POST, "/api/v2/playback/seek", body);
}

pub fn playbackShuffleToggle(alloc: std.mem.Allocator, io: std.Io, token: []const u8) bool {
    return postNoBody(alloc, io, token, .POST, "/api/v2/playback/shuffle/toggle");
}

pub fn playbackRepeatToggle(alloc: std.mem.Allocator, io: std.Io, token: []const u8) bool {
    return postNoBody(alloc, io, token, .POST, "/api/v2/playback/repeat/toggle");
}

// ---------------------------------------------------------------------------
// Tests

test "cider-client: config token parsing handles block + inline scopes" {
    const t = std.testing;
    const yaml =
        \\connectivity:
        \\  playbackNotifications: true
        \\  apiTokens:
        \\    - name: "Event Horizon"
        \\      token: "abc123"
        \\      scopes:
        \\        - playback
        \\        - queue
        \\        - library
        \\      creationTime: 1
        \\      method: request-auth
        \\    - name: "Remote"
        \\      token: "remote"
        \\      isRemote: true
        \\      method: lan
        \\      scopes: [playback]
        \\    - name: "Legacy"
        \\      token: "old"
        \\discord:
        \\  enabled: false
    ;
    const tokens = try parseConfigTokens(t.allocator, yaml);
    defer freeTokens(t.allocator, tokens);
    try t.expectEqual(@as(usize, 3), tokens.len);
    try t.expectEqualStrings("Event Horizon", tokens[0].name);
    try t.expectEqualStrings("abc123", tokens[0].value);
    try t.expect(tokens[0].has(.library));
    try t.expect(!tokens[0].has(.lyrics));
    try t.expect(tokens[1].remote);
    try t.expect(tokens[1].has(.playback));
    try t.expect(!tokens[2].scopes.known);
    try t.expect(tokens[2].has(.lyrics));
}

test "cider-client: queue reply parses track attributes and position" {
    const t = std.testing;
    const body =
        \\{"data":{"items":[
        \\{"track":{"id":"i.1","type":"songs","attributes":{"name":"Blue Hour","artistName":"Aster","albumName":"Night","durationInMillis":215000,"artwork":{"url":"https://example/600x600.jpg"}}}},
        \\{"track":{"id":"i.2","type":"songs","attributes":{"name":"Low Tide","artistName":"Aster","durationInMillis":180000}}}],
        \\"position":3},"meta":{"offset":0,"limit":50,"total":12}}
    ;
    var page = try parseQueue(t.allocator, body);
    defer page.deinit();
    try t.expectEqual(@as(usize, 2), page.items.len);
    try t.expectEqual(@as(i64, 3), page.position);
    try t.expectEqual(@as(i64, 12), page.total);
    try t.expectEqualStrings("Blue Hour", page.items[0].title);
    try t.expectEqualStrings("Aster", page.items[0].artist);
    try t.expectEqualStrings("Night", page.items[0].album);
    try t.expectEqual(@as(i64, 215000), page.items[0].duration_ms);
    try t.expectEqualStrings("https://example/600x600.jpg", page.items[0].art_url);
}

test "cider-client: library summaries select the right subtitle" {
    const t = std.testing;
    const body =
        \\{"data":{"items":[
        \\{"id":"p.1","attributes":{"name":"Late Night","trackCount":24}},
        \\{"id":"p.2","attributes":{"name":"Morning","trackCount":8}}]},
        \\"meta":{"offset":0,"limit":50,"total":2}}
    ;
    var page = try parseLibrary(t.allocator, body, .playlists);
    defer page.deinit();
    try t.expectEqual(@as(usize, 2), page.items.len);
    try t.expectEqualStrings("Playlist", page.items[0].subtitle);
    try t.expectEqualStrings("24 songs", page.items[0].extra);
    try t.expectEqualStrings("Late Night", page.items[0].name);

    const songs =
        \\{"data":{"items":[{"id":"i.1","attributes":{"name":"Track","artistName":"Artist","albumName":"Album","durationInMillis":65000}}]},"meta":{"total":1}}
    ;
    var sp = try parseLibrary(t.allocator, songs, .songs);
    defer sp.deinit();
    try t.expectEqualStrings("Artist — Album", sp.items[0].subtitle);
    try t.expectEqualStrings("1:05", sp.items[0].extra);
}

test "cider-client: lyrics reply drops empty lines and keeps timestamps" {
    const t = std.testing;
    const body =
        \\{"data":{"id":"i.1","source":{"provider":"Apple Music","timingType":"Line"},"lines":[
        \\{"start":1.5,"end":3.0,"text":"First","empty":false},
        \\{"start":3.0,"end":4.0,"text":"","empty":true},
        \\{"start":4.0,"end":6.2,"text":"Second","empty":false}]}}
    ;
    var page = try parseLyrics(t.allocator, body);
    defer page.deinit();
    try t.expectEqual(@as(usize, 2), page.lines.len);
    try t.expectEqualStrings("First", page.lines[0].text);
    try t.expectApproxEqAbs(@as(f64, 4.0), page.lines[1].start, 0.0001);
    try t.expectEqualStrings("Apple Music", page.provider);
    try t.expectEqualStrings("Line", page.timing);
}

test "cider-client: artwork placeholders resolve" {
    const t = std.testing;
    const s = try formatArtwork(t.allocator, "https://example/{w}x{h}bb.jpg");
    defer t.allocator.free(s);
    try t.expectEqualStrings("https://example/600x600bb.jpg", s);
}

test "cider-client: duration formatting" {
    const t = std.testing;
    const s = try fmtDuration(t.allocator, 65_000);
    defer t.allocator.free(s);
    try t.expectEqualStrings("1:05", s);
}

test "cider-client: quality codes become readable labels" {
    const t = std.testing;
    try t.expectEqualStrings("AAC 256kbps", qualityName("256", false));
    try t.expectEqualStrings("Dolby Atmos", qualityName("atmos", false));
    try t.expectEqualStrings("Local file", qualityName("local_alac", false));
    try t.expectEqualStrings("Lossless", qualityName("\xee\xa2\x87\xee\xa5\xbf", true));
    try t.expectEqualStrings("Apple Music", qualityName("\xee\xa2\x87", false));
}
