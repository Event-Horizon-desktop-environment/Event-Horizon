const std = @import("std");
const linux = std.os.linux;
const wl = @import("../c.zig").wl;

pub const mime_utf8 = "text/plain;charset=utf-8";
pub const mime_plain = "text/plain";
pub const mime_utf8_string = "UTF8_STRING";
pub const mime_gnome_files = "x-special/gnome-copied-files";
pub const mime_uri_list = "text/uri-list";

pub const Backend = enum { ext, wlr };

pub fn backendForInterface(interface: []const u8) ?Backend {
    if (std.mem.eql(u8, interface, "ext_data_control_manager_v1")) return .ext;
    if (std.mem.eql(u8, interface, "zwlr_data_control_manager_v1")) return .wlr;
    return null;
}

pub fn preferredMime(mimes: []const []const u8) ?[]const u8 {
    for ([_][]const u8{ mime_utf8, mime_plain, mime_utf8_string }) |want| {
        for (mimes) |m| {
            if (std.mem.eql(u8, m, want)) return m;
        }
    }
    if (mimes.len > 0) return mimes[0];
    return null;
}

pub fn fileUriForPath(alloc: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (abs_path) |ch| {
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(alloc, ch);
        } else if (ch == ' ') {
            try out.appendSlice(alloc, "%20");
        } else {
            var buf: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "%{X:0>2}", .{ch}) catch unreachable;
            try out.appendSlice(alloc, &buf);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn hexVal(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

pub fn pathFromFileUri(uri: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return "";
    var p = uri[7..];
    if (p.len == 0) return "";
    if (p[0] != '/') {
        if (std.mem.indexOfScalar(u8, p, '/')) |slash| {
            p = p[slash..];
        } else return "";
    }
    return p;
}

pub fn pathDecode(alloc: std.mem.Allocator, enc: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < enc.len) {
        if (enc[i] == '%' and i + 2 < enc.len) {
            const hi = hexVal(enc[i + 1]);
            const lo = hexVal(enc[i + 2]);
            if (hi != null and lo != null) {
                try out.append(alloc, (hi.? << 4) | lo.?);
                i += 3;
                continue;
            }
        }
        try out.append(alloc, enc[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// The `std::filesystem::weakly_canonical` shape without symlink
/// resolution: fold `.` / `..`, collapse separators, require nothing on
/// disk. The C++ `canonical_abs_path` (clipboard.cpp:226-231) uses
/// `weakly_canonical` and falls back to `absolute`; clipboard payloads
/// routinely name files that no longer exist (existence is checked by the
/// caller afterwards), and this Zig toolchain has no `realpath`, so the
/// lexical shape is the faithful residual behavior (the same limitation
/// `color/apply.zig` records for wallpaper paths).
///
/// Absolute inputs only: every producer this module parses
/// (gnome-copied-files, text/uri-list, plain lines) admits absolute paths
/// alone — the C++ reader guards each fallback with `line[0] == '/'` and
/// `file://` URIs decode to absolute paths by construction.
pub fn canonicalAbsolutePath(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (path.len == 0 or path[0] != '/') return null;
    return std.fs.path.resolve(alloc, &.{path}) catch null;
}

/// `ClipboardFiles` (clipboard.hpp:40-43): a parsed file selection.
pub const FileList = struct {
    is_cut: bool = false,
    paths: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *FileList, alloc: std.mem.Allocator) void {
        for (self.paths.items) |p| alloc.free(p);
        self.paths.deinit(alloc);
    }
};

/// One clipboard line → canonical absolute path, or null when the line is
/// neither a `file://` URI nor an absolute path (the C++ pair:
/// `path_from_file_uri`, then the `line[0] == '/'` raw-path fallback).
pub fn pathFromUriOrPath(alloc: std.mem.Allocator, line: []const u8) ?[]u8 {
    if (std.mem.startsWith(u8, line, "file://")) {
        const raw = pathFromFileUri(line);
        if (raw.len == 0) return null;
        const dec = pathDecode(alloc, raw) catch return null;
        defer alloc.free(dec);
        return canonicalAbsolutePath(alloc, dec);
    }
    if (line.len > 0 and line[0] == '/') return canonicalAbsolutePath(alloc, line);
    return null;
}

/// The inline trim of the C++ uri-list and plain-line readers
/// (clipboard.cpp:627-632 and 648-653): strip space/tab/CR from both ends.
/// Lines cannot contain LF (both sides split on it first), so the trim set
/// is exactly the C++ one.
pub fn trimWs(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r')) a += 1;
    var b: usize = s.len;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\r')) b -= 1;
    return s[a..b];
}

/// Parse `x-special/gnome-copied-files` (clipboard.cpp:594-617): optional
/// `x-special/nautilus-clipboard` first line, then `cut`/`copy`, then one
/// URI (or raw absolute path) per line; a trailing `\r` per line is
/// tolerated (GNOME writes `\r\n`). Returns null when the header line is
/// malformed; an empty `paths` is a valid result — the C++ caller falls
/// through to `text/uri-list` in that case while keeping `is_cut`.
pub fn parseGnomeFilesBody(alloc: std.mem.Allocator, raw: []const u8) ?FileList {
    var result = FileList{};
    var first = true;
    var have_kind = false;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (first) {
            first = false;
            if (std.mem.eql(u8, line, "x-special/nautilus-clipboard")) continue;
        }
        if (!have_kind) {
            if (std.mem.eql(u8, line, "cut")) {
                result.is_cut = true;
                have_kind = true;
                continue;
            }
            if (std.mem.eql(u8, line, "copy")) {
                have_kind = true;
                continue;
            }
            result.deinit(alloc);
            return null;
        }
        if (line.len == 0) continue;
        const p = pathFromUriOrPath(alloc, line) orelse continue;
        result.paths.append(alloc, p) catch alloc.free(p);
    }
    if (!have_kind) {
        result.deinit(alloc);
        return null;
    }
    return result;
}

/// Append every path line of `raw` (text/uri-list and text/plain formats):
/// trim whitespace, skip blanks, optionally skip `#` comment lines (the
/// uri-list branch of the C++ `read_files` does; the text/plain branch
/// does not — clipboard.cpp:621-660).
pub fn appendUriLines(alloc: std.mem.Allocator, raw: []const u8, out: *std.ArrayList([]u8), skip_comments: bool) void {
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |raw_line| {
        const line = trimWs(raw_line);
        if (line.len == 0) continue;
        if (skip_comments and line[0] == '#') continue;
        const p = pathFromUriOrPath(alloc, line) orelse continue;
        out.append(alloc, p) catch alloc.free(p);
    }
}

/// One entry of the owned payload store — the Zig shape of
/// `outgoingData_[mime] = bytes` (clipboard.hpp:158).
const OwnedItem = struct { mime: []u8, data: []u8 };

const Offer = struct {
    ptr: *anyopaque,
    primary: bool,
    mimes: std.ArrayList([]const u8),
    svc: *Service,
};

pub const DataProvider = *const fn (ctx: *anyopaque, mime: []const u8, alloc: std.mem.Allocator) ?[]u8;

pub const Service = struct {
    alloc: std.mem.Allocator,
    backend: Backend = .ext,
    manager: ?*anyopaque = null,
    device: ?*anyopaque = null,
    seat: ?*wl.wl_seat = null,
    /// Display handle, for the flush after a selection write
    /// (clipboard.cpp:444-446: "so the new selection is visible to other
    /// clients immediately, even if the caller's event loop hasn't
    /// dispatched yet"). Optional; the C++ `bind` takes it as a 4th arg.
    display: ?*wl.wl_display = null,
    offers: std.ArrayList(*Offer),
    current: ?usize = null,
    current_primary: ?usize = null,
    source: ?*anyopaque = null,
    source_mimes: std.ArrayList([]const u8),
    /// Owned payload store: the Zig shape of `outgoingData_`
    /// (clipboard.hpp:158). Populated by `copyData` / `copyDataMulti` /
    /// `copyText` / `copyFiles`; handed to the compositor by `provideOwned`.
    owned: std.ArrayList(OwnedItem) = .empty,
    provider: ?DataProvider = null,
    provider_ctx: *anyopaque = undefined,
    on_changed: ?*const fn (ctx: *anyopaque) void = null,
    changed_ctx: *anyopaque = undefined,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Service {
        return .{ .alloc = alloc, .offers = .empty, .source_mimes = .empty, .owned = .empty };
    }

    pub fn deinit(self: *Service) void {
        self.cleanup();
        self.offers.deinit(self.alloc);
        self.source_mimes.deinit(self.alloc);
        self.owned.deinit(self.alloc);
    }

    pub fn cleanup(self: *Service) void {
        self.clearSource();
        for (self.offers.items) |o| {
            self.destroyOfferPtr(o.ptr);
            for (o.mimes.items) |m| self.alloc.free(m);
            o.mimes.deinit(self.alloc);
            self.alloc.destroy(o);
        }
        self.offers.clearRetainingCapacity();
        self.current = null;
        self.current_primary = null;
        if (self.device) |_| {
            self.destroyDevicePtr();
            self.device = null;
        }
        self.manager = null;
        self.seat = null;
        self.display = null;
    }

    fn destroyOfferPtr(self: *Service, ptr: *anyopaque) void {
        switch (self.backend) {
            .ext => wl.ext_data_control_offer_v1_destroy(@ptrCast(ptr)),
            .wlr => wl.zwlr_data_control_offer_v1_destroy(@ptrCast(ptr)),
        }
    }

    fn destroyDevicePtr(self: *Service) void {
        switch (self.backend) {
            .ext => wl.ext_data_control_device_v1_destroy(@ptrCast(@alignCast(self.device))),
            .wlr => wl.zwlr_data_control_device_v1_destroy(@ptrCast(@alignCast(self.device))),
        }
    }

    /// Destroy the outgoing source and its offer bookkeeping but leave the
    /// owned payload store alone — the C++ `build_source_and_set_selection`
    /// "destroy the previous outgoing source without touching
    /// outgoingData_" (clipboard.cpp:415-419). A cancelled source goes
    /// through `clearSource` instead, which also drops the payload
    /// (`handle_source_cancelled`, clipboard.cpp:403-410).
    fn destroySourceOnly(self: *Service) void {
        if (self.source) |s| {
            switch (self.backend) {
                .ext => wl.ext_data_control_source_v1_destroy(@ptrCast(s)),
                .wlr => wl.zwlr_data_control_source_v1_destroy(@ptrCast(s)),
            }
            self.source = null;
        }
        for (self.source_mimes.items) |m| self.alloc.free(m);
        self.source_mimes.clearRetainingCapacity();
        self.provider = null;
    }

    fn clearOwned(self: *Service) void {
        for (self.owned.items) |it| {
            self.alloc.free(it.mime);
            self.alloc.free(it.data);
        }
        self.owned.clearRetainingCapacity();
    }

    fn clearSource(self: *Service) void {
        self.destroySourceOnly();
        self.clearOwned();
    }

    pub fn bind(self: *Service, manager: *anyopaque, backend: Backend, seat: ?*wl.wl_seat, display: ?*wl.wl_display) bool {
        self.cleanup();
        if (seat == null) return false;
        self.manager = manager;
        self.backend = backend;
        self.seat = seat;
        self.display = display;
        const dev: ?*anyopaque = switch (backend) {
            .ext => blk: {
                const d = wl.ext_data_control_manager_v1_get_data_device(@ptrCast(@alignCast(manager)), seat);
                break :blk if (d != null) @ptrCast(d) else null;
            },
            .wlr => blk: {
                const d = wl.zwlr_data_control_manager_v1_get_data_device(@ptrCast(@alignCast(manager)), seat);
                break :blk if (d != null) @ptrCast(d) else null;
            },
        };
        if (dev == null) {
            self.cleanup();
            return false;
        }
        self.device = dev;
        switch (backend) {
            .ext => _ = wl.ext_data_control_device_v1_add_listener(@ptrCast(@alignCast(dev)), &ext_device_listener, self),
            .wlr => _ = wl.zwlr_data_control_device_v1_add_listener(@ptrCast(@alignCast(dev)), &wlr_device_listener, self),
        }
        self.notifyChanged();
        return true;
    }

    fn notifyChanged(self: *Service) void {
        if (self.on_changed) |h| h(self.changed_ctx);
    }

    fn onDataOffer(self: *Service, offer_ptr: *anyopaque) void {
        const o = self.alloc.create(Offer) catch {
            self.destroyOfferPtr(offer_ptr);
            return;
        };
        o.* = .{ .ptr = offer_ptr, .primary = false, .mimes = .empty, .svc = self };
        errdefer self.alloc.destroy(o);
        self.offers.append(self.alloc, o) catch {
            self.destroyOfferPtr(offer_ptr);
            return;
        };
        switch (self.backend) {
            .ext => _ = wl.ext_data_control_offer_v1_add_listener(@ptrCast(offer_ptr), &ext_offer_listener, o),
            .wlr => _ = wl.zwlr_data_control_offer_v1_add_listener(@ptrCast(offer_ptr), &wlr_offer_listener, o),
        }
    }

    fn onSelection(self: *Service, offer_ptr: ?*anyopaque, primary: bool) void {
        if (offer_ptr == null) {
            if (primary) {
                self.current_primary = null;
            } else {
                self.current = null;
            }
            self.notifyChanged();
            return;
        }
        for (self.offers.items, 0..) |o, i| {
            if (o.*.ptr == offer_ptr) {
                o.*.primary = primary;
                if (primary) {
                    self.current_primary = i;
                } else {
                    self.current = i;
                }
                self.notifyChanged();
                return;
            }
        }
    }

    fn onOfferMime(self: *Service, offer_ptr: *anyopaque, mime: []const u8) void {
        for (self.offers.items) |o| {
            if (o.*.ptr == offer_ptr) {
                o.*.mimes.append(self.alloc, self.alloc.dupe(u8, mime) catch return) catch return;
                return;
            }
        }
    }

    fn onSourceSend(self: *Service, mime_ptr: [*c]const u8, fd: i32) void {
        defer _ = std.os.linux.close(fd);
        const mime = if (mime_ptr != null) std.mem.span(mime_ptr) else return;
        const provider = self.provider orelse return;
        const data = provider(self.provider_ctx, mime, self.alloc) orelse return;
        defer self.alloc.free(data);
        var off: usize = 0;
        while (off < data.len) {
            const rc = linux.write(fd, data[off..].ptr, data.len - off);
            const e = linux.errno(rc);
            if (e != .SUCCESS) {
                if (e == .INTR) continue;
                return;
            }
            const n: usize = @intCast(rc);
            if (n == 0) return;
            off += n;
        }
    }

    fn onSourceCancelled(self: *Service) void {
        self.clearSource();
        self.notifyChanged();
    }

    /// C++ `handle_device_finished` (clipboard.cpp:373-376): the data-control
    /// device went away — drop everything it owned and notify. This is the
    /// signal a daemon's hold loop watches: `ownsSelection` flips false and
    /// the process exits.
    fn onDeviceFinished(self: *Service) void {
        self.cleanup();
        self.notifyChanged();
    }

    /// C++ `is_available`: seat + ops + device all present.
    pub fn isAvailable(self: *Service) bool {
        return self.seat != null and self.manager != null and self.device != null;
    }

    /// C++ `owns_selection`.
    pub fn ownsSelection(self: *Service) bool {
        return self.source != null;
    }

    pub fn currentMimes(self: *Service, primary: bool) []const []const u8 {
        const idx = if (primary) self.current_primary else self.current;
        if (idx) |i| {
            if (i < self.offers.items.len) return self.offers.items[i].mimes.items;
        }
        return &.{};
    }

    pub fn receive(self: *Service, mime: []const u8, primary: bool, timeout_ms: i64) ?[]u8 {
        return self.receivePump(mime, primary, timeout_ms, null, undefined);
    }

    /// C++ `receive_offer_as_mime` (clipboard.cpp:544-571): hand the
    /// compositor one end of an `O_CLOEXEC` pipe and drain the other.
    /// Semantics preserved:
    ///  * `timeout_ms` is the per-read stall budget, exactly like the C++
    ///    hardcoded `poll(..., 5000)`: a stall or read error returns
    ///    whatever arrived before it, not a failure;
    ///  * the drain stops at an EOF, a stall, or once the collected bytes
    ///    exceed 4 MiB (the C++ ceiling).
    /// The pipe read end is always closed; the write end is closed right
    /// after the receive request is queued (the compositor holds its own
    /// reference).
    /// The C++ ceiling `receivePump` preserves: stop once more than 4 MiB
    /// has been collected.
    pub const receive_ceiling: usize = 4 * 1024 * 1024;

    pub fn receivePump(self: *Service, mime: []const u8, primary: bool, timeout_ms: i64, pump: ?*const fn (*anyopaque) void, pump_ctx: *anyopaque) ?[]u8 {
        return self.receiveCapped(mime, primary, timeout_ms, receive_ceiling, pump, pump_ctx);
    }

    /// `receivePump` with a caller-chosen byte ceiling. ClipStack capture
    /// raises it to 64 MiB: a screenshot PNG is routinely larger than
    /// 4 MiB, and a truncated PNG is a broken image. Every other caller
    /// goes through `receivePump` and keeps the C++ behavior.
    pub fn receiveCapped(self: *Service, mime: []const u8, primary: bool, timeout_ms: i64, cap: usize, pump: ?*const fn (*anyopaque) void, pump_ctx: *anyopaque) ?[]u8 {
        const idx = if (primary) self.current_primary else self.current;
        const i = idx orelse return null;
        if (i >= self.offers.items.len) return null;
        const offer = self.offers.items[i];
        var has_mime = false;
        for (offer.mimes.items) |m| {
            if (std.mem.eql(u8, m, mime)) {
                has_mime = true;
                break;
            }
        }
        if (!has_mime) return null;

        var zbuf: [256:0]u8 = [_:0]u8{0} ** 256;
        if (mime.len >= zbuf.len) return null;
        @memcpy(zbuf[0..mime.len], mime);
        var pfds: [2]i32 = .{ -1, -1 };
        if (linux.pipe2(&pfds, .{ .CLOEXEC = true }) != 0) return null;
        switch (self.backend) {
            .ext => wl.ext_data_control_offer_v1_receive(@ptrCast(@alignCast(offer.ptr)), &zbuf, pfds[1]),
            .wlr => wl.zwlr_data_control_offer_v1_receive(@ptrCast(@alignCast(offer.ptr)), &zbuf, pfds[1]),
        }
        _ = std.os.linux.close(pfds[1]);
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (pump) |p| p(pump_ctx);
            var pfd = std.posix.pollfd{ .fd = pfds[0], .events = std.posix.POLL.IN, .revents = 0 };
            const ms: i32 = @intCast(@max(0, @min(timeout_ms, std.math.maxInt(i32))));
            const r = std.posix.poll((&pfd)[0..1], ms) catch break;
            if (r == 0) break;
            var chunk: [65536]u8 = undefined;
            const n: usize = linux.read(pfds[0], &chunk, chunk.len);
            const s: isize = @bitCast(n);
            if (s <= 0) break;
            out.appendSlice(self.alloc, chunk[0..@intCast(s)]) catch break;
            if (out.items.len > cap) break;
        }
        _ = std.os.linux.close(pfds[0]);
        return out.toOwnedSlice(self.alloc) catch null;
    }

    pub fn setSelection(self: *Service, mimes: []const []const u8, provider: DataProvider, ctx: *anyopaque, primary: bool) bool {
        const mgr = self.manager orelse return false;
        self.clearSource();
        const src: ?*anyopaque = switch (self.backend) {
            .ext => blk: {
                const s = wl.ext_data_control_manager_v1_create_data_source(@ptrCast(@alignCast(mgr)));
                break :blk if (s != null) @ptrCast(s) else null;
            },
            .wlr => blk: {
                const s = wl.zwlr_data_control_manager_v1_create_data_source(@ptrCast(@alignCast(mgr)));
                break :blk if (s != null) @ptrCast(s) else null;
            },
        };
        if (src == null) return false;
        self.source = src;
        for (mimes) |m| {
            const owned = self.alloc.dupe(u8, m) catch {
                self.clearSource();
                return false;
            };
            self.source_mimes.append(self.alloc, owned) catch {
                self.alloc.free(owned);
                self.clearSource();
                return false;
            };
            var zbuf: [256:0]u8 = [_:0]u8{0} ** 256;
            if (m.len >= zbuf.len) continue;
            @memcpy(zbuf[0..m.len], m);
            switch (self.backend) {
                .ext => wl.ext_data_control_source_v1_offer(@ptrCast(src.?), &zbuf),
                .wlr => wl.zwlr_data_control_source_v1_offer(@ptrCast(src.?), &zbuf),
            }
        }
        switch (self.backend) {
            .ext => _ = wl.ext_data_control_source_v1_add_listener(@ptrCast(src.?), &ext_source_listener, self),
            .wlr => _ = wl.zwlr_data_control_source_v1_add_listener(@ptrCast(src.?), &wlr_source_listener, self),
        }
        self.provider = provider;
        self.provider_ctx = ctx;
        if (self.device) |d| {
            switch (self.backend) {
                .ext => if (primary) {
                    wl.ext_data_control_device_v1_set_primary_selection(@ptrCast(@alignCast(d)), @ptrCast(src.?));
                } else {
                    wl.ext_data_control_device_v1_set_selection(@ptrCast(@alignCast(d)), @ptrCast(src.?));
                },
                .wlr => if (primary) {
                    wl.zwlr_data_control_device_v1_set_primary_selection(@ptrCast(@alignCast(d)), @ptrCast(src.?));
                } else {
                    wl.zwlr_data_control_device_v1_set_selection(@ptrCast(@alignCast(d)), @ptrCast(src.?));
                },
            }
        }
        return true;
    }

    // ---- C++-shaped surface (ClipboardService) ---------------------------
    // `setSelection` above is the generic Zig primitive; the block below
    // ports the concrete copy/read operations of clipboard.{hpp,cpp} so
    // consumers (the daemon, settings-style paste) work the way they did in
    // C++. Payloads live in `owned` — the `outgoingData_` analogue — and
    // `buildOwnedSourceBoth` is `build_source_and_set_selection`.

    /// One (mime, data) pair for `copyDataMulti` — the Zig spelling of the
    /// C++ `std::vector<std::pair<std::string, std::string>>`.
    pub const DataItem = struct { mime: []const u8, data: []const u8 };

    /// C++ `copy_data` (clipboard.cpp:453-461). Two quirks preserved:
    ///  * it does NOT clear other mimes — only a same-name mime is
    ///    replaced, so successive calls accumulate offers;
    ///  * it selects the clipboard *and* the primary selection to the same
    ///    source (`build_source_and_set_selection`, clipboard.cpp:414-449).
    pub fn copyData(self: *Service, mime: []const u8, data: []const u8) bool {
        if (!self.isAvailable()) return false;
        if (!self.upsertOwned(mime, data)) return false;
        return self.buildOwnedSourceBoth();
    }

    /// C++ `copy_data_multi` (clipboard.cpp:463-473): replaces every
    /// previously stored mime first.
    pub fn copyDataMulti(self: *Service, items: []const DataItem) bool {
        if (!self.isAvailable()) return false;
        self.clearOwned();
        for (items) |it| {
            if (!self.upsertOwned(it.mime, it.data)) return false;
        }
        return self.buildOwnedSourceBoth();
    }

    /// C++ `copy_text` (clipboard.cpp:475-485): offers
    /// `text/plain;charset=utf-8` and `text/plain` with the same bytes,
    /// clearing previous mimes.
    pub fn copyText(self: *Service, text: []const u8) bool {
        if (!self.isAvailable()) return false;
        self.clearOwned();
        if (!self.upsertOwned(mime_utf8, text)) return false;
        if (!self.upsertOwned(mime_plain, text)) return false;
        return self.buildOwnedSourceBoth();
    }

    /// C++ `copy_files` (clipboard.cpp:487-515). Byte formats, exactly:
    ///  * `x-special/gnome-copied-files`: `cut\n`|`copy\n`, then one
    ///    `file://…\n` per path. No `x-special/nautilus-clipboard` header
    ///    here — that header only exists in the desktop icon menu's
    ///    shell-out producer (`desktop.zig`); the reader accepts both
    ///    spellings;
    ///  * `text/uri-list`: one `file://…\r\n` per path;
    ///  * `text/plain`: canonical paths joined by `\n`, no trailing
    ///    newline.
    pub fn copyFiles(self: *Service, cut: bool, abs_paths: []const []const u8) bool {
        if (!self.isAvailable() or abs_paths.len == 0) return false;

        var gnome: std.ArrayList(u8) = .empty;
        defer gnome.deinit(self.alloc);
        var uri_list: std.ArrayList(u8) = .empty;
        defer uri_list.deinit(self.alloc);
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(self.alloc);

        gnome.appendSlice(self.alloc, if (cut) "cut\n" else "copy\n") catch return false;
        for (abs_paths) |p| {
            const canon = canonicalAbsolutePath(self.alloc, p) orelse continue;
            defer self.alloc.free(canon);
            const uri = fileUriForPath(self.alloc, canon) catch continue;
            defer self.alloc.free(uri);
            gnome.appendSlice(self.alloc, uri) catch return false;
            gnome.append(self.alloc, '\n') catch return false;
            uri_list.appendSlice(self.alloc, uri) catch return false;
            uri_list.appendSlice(self.alloc, "\r\n") catch return false;
            if (plain.items.len > 0) plain.append(self.alloc, '\n') catch return false;
            plain.appendSlice(self.alloc, canon) catch return false;
        }
        // C++ sanity gates (clipboard.cpp:503-506): header-only payloads are
        // refused (some producers set just `cut\n` / `copy\n` and nothing
        // else). The C++ first gate also tests `gnome[0] != '/'`, which can
        // never be false — `gnome` always starts with `c` — so it reduces
        // to "no path appended on a multi-path call".
        if (gnome.items.len <= 4 and abs_paths.len > 1) return false;
        if (gnome.items.len < 6) return false;

        self.clearOwned();
        if (!self.upsertOwned(mime_gnome_files, gnome.items)) return false;
        if (!self.upsertOwned(mime_uri_list, uri_list.items)) return false;
        if (!self.upsertOwned(mime_plain, plain.items)) return false;
        return self.buildOwnedSourceBoth();
    }

    /// C++ `selection_has_mime` (clipboard.cpp:526-531), over the current
    /// clipboard selection.
    pub fn selectionHasMime(self: *Service, mime: []const u8) bool {
        for (self.currentMimes(false)) |m| {
            if (std.mem.eql(u8, m, mime)) return true;
        }
        return false;
    }

    /// C++ `selection_supports_text` (clipboard.cpp:519-524).
    pub fn selectionSupportsText(self: *Service) bool {
        for (self.currentMimes(false)) |m| {
            if (std.mem.eql(u8, m, mime_utf8) or std.mem.eql(u8, m, mime_plain) or std.mem.eql(u8, m, mime_utf8_string)) return true;
        }
        return false;
    }

    /// C++ `receive_offer_as_text` (clipboard.cpp:533-542): prefer
    /// `text/plain;charset=utf-8`; otherwise the FIRST offered mime
    /// verbatim — even a non-text one, as long as one of the three text
    /// types is somewhere in the list (the C++ picks `selectionMimes_.front()`
    /// with the same disregard).
    fn receiveOfferAsText(self: *Service, pump: ?*const fn (*anyopaque) void, pump_ctx: *anyopaque) ?[]u8 {
        if (!self.selectionSupportsText()) return null;
        const mimes = self.currentMimes(false);
        var mime: []const u8 = mime_utf8;
        var has_utf8 = false;
        for (mimes) |m| {
            if (std.mem.eql(u8, m, mime_utf8)) {
                has_utf8 = true;
                break;
            }
        }
        if (!has_utf8 and mimes.len > 0) mime = mimes[0];
        return self.receivePump(mime, false, 5000, pump, pump_ctx);
    }

    /// C++ `read_selection_text` (clipboard.cpp:573-575).
    pub fn readSelectionText(self: *Service, pump: ?*const fn (*anyopaque) void, pump_ctx: *anyopaque) ?[]u8 {
        return self.receiveOfferAsText(pump, pump_ctx);
    }

    /// C++ `read_data` (clipboard.cpp:577-580): refuses when the mime is
    /// not on offer.
    pub fn readData(self: *Service, mime: []const u8, pump: ?*const fn (*anyopaque) void, pump_ctx: *anyopaque) ?[]u8 {
        if (!self.selectionHasMime(mime)) return null;
        return self.receivePump(mime, false, 5000, pump, pump_ctx);
    }

    /// C++ `read_files` (clipboard.cpp:582-663): gnome-copied-files first
    /// (header optional — the reader tolerates the nautilus spelling the
    /// desktop icon menu produces), then text/uri-list, then text/plain.
    /// The first format yielding any path wins; `is_cut` survives a gnome
    /// parse that produced no paths, exactly like the C++ keeps it.
    ///
    /// The C++ pre-flushes and dispatches pending events so the mime list
    /// is populated before the checks; here the caller's `pump` (one
    /// dispatch, e.g. `Connection.roundtrip`) stands in for that — a
    /// blocking roundtrip is a superset of the non-blocking
    /// `dispatch_pending` the C++ uses.
    pub fn readFiles(self: *Service, alloc: std.mem.Allocator, pump: ?*const fn (*anyopaque) void, pump_ctx: *anyopaque) FileList {
        var result = FileList{};
        if (pump) |p| p(pump_ctx);

        if (self.selectionHasMime(mime_gnome_files)) {
            if (self.receivePump(mime_gnome_files, false, 5000, pump, pump_ctx)) |raw| {
                defer alloc.free(raw);
                if (raw.len > 0) {
                    if (parseGnomeFilesBody(alloc, raw)) |parsed| {
                        result.deinit(alloc);
                        result = parsed;
                        if (result.paths.items.len > 0) return result;
                    }
                }
            }
        }
        if (self.selectionHasMime(mime_uri_list)) {
            if (self.receivePump(mime_uri_list, false, 5000, pump, pump_ctx)) |raw| {
                defer alloc.free(raw);
                if (raw.len > 0) {
                    appendUriLines(alloc, raw, &result.paths, true);
                    if (result.paths.items.len > 0) return result;
                }
            }
        }
        if (self.receiveOfferAsText(pump, pump_ctx)) |raw| {
            defer alloc.free(raw);
            if (raw.len > 0) appendUriLines(alloc, raw, &result.paths, false);
        }
        return result;
    }

    /// `outgoingData_[mime] = data`, with the replace-in-place semantics of
    /// `operator[]`; the C++ `copy_data` does not clear the map, which is
    /// why this is an upsert rather than an append.
    fn upsertOwned(self: *Service, mime: []const u8, data: []const u8) bool {
        for (self.owned.items) |*it| {
            if (std.mem.eql(u8, it.mime, mime)) {
                const d = self.alloc.dupe(u8, data) catch return false;
                self.alloc.free(it.data);
                it.data = d;
                return true;
            }
        }
        const m = self.alloc.dupe(u8, mime) catch return false;
        const d = self.alloc.dupe(u8, data) catch {
            self.alloc.free(m);
            return false;
        };
        self.owned.append(self.alloc, .{ .mime = m, .data = d }) catch {
            self.alloc.free(m);
            self.alloc.free(d);
            return false;
        };
        return true;
    }

    /// The provider handed to the compositor for owned payloads: the Zig
    /// read side of `handle_source_send`'s `outgoingData_.find(mime)`
    /// lookup. Unknown mime → null → nothing written, fd still closed.
    fn provideOwned(ctx: *anyopaque, mime: []const u8, alloc: std.mem.Allocator) ?[]u8 {
        const self: *Service = @ptrCast(@alignCast(ctx));
        for (self.owned.items) |it| {
            if (std.mem.eql(u8, it.mime, mime)) return alloc.dupe(u8, it.data) catch null;
        }
        return null;
    }

    /// C++ `build_source_and_set_selection` (clipboard.cpp:414-449): one
    /// source, every stored mime offered, then BOTH selections (clipboard
    /// and primary) pointed at it, then a flush when a display is attached,
    /// then the change notification. A failed data-source creation leaves
    /// `owned` intact — the C++ does not clear `outgoingData_` there
    /// either.
    fn buildOwnedSourceBoth(self: *Service) bool {
        const mgr = self.manager orelse return false;
        self.destroySourceOnly();
        const src: ?*anyopaque = switch (self.backend) {
            .ext => blk: {
                const s = wl.ext_data_control_manager_v1_create_data_source(@ptrCast(@alignCast(mgr)));
                break :blk if (s != null) @ptrCast(s) else null;
            },
            .wlr => blk: {
                const s = wl.zwlr_data_control_manager_v1_create_data_source(@ptrCast(@alignCast(mgr)));
                break :blk if (s != null) @ptrCast(s) else null;
            },
        };
        if (src == null) return false;
        self.source = src;
        switch (self.backend) {
            .ext => _ = wl.ext_data_control_source_v1_add_listener(@ptrCast(src.?), &ext_source_listener, self),
            .wlr => _ = wl.zwlr_data_control_source_v1_add_listener(@ptrCast(src.?), &wlr_source_listener, self),
        }
        for (self.owned.items) |it| {
            const owned_mime = self.alloc.dupe(u8, it.mime) catch {
                self.destroySourceOnly();
                return false;
            };
            self.source_mimes.append(self.alloc, owned_mime) catch {
                self.alloc.free(owned_mime);
                self.destroySourceOnly();
                return false;
            };
            var zbuf: [256:0]u8 = [_:0]u8{0} ** 256;
            if (it.mime.len >= zbuf.len) continue;
            @memcpy(zbuf[0..it.mime.len], it.mime);
            switch (self.backend) {
                .ext => wl.ext_data_control_source_v1_offer(@ptrCast(src.?), &zbuf),
                .wlr => wl.zwlr_data_control_source_v1_offer(@ptrCast(src.?), &zbuf),
            }
        }
        self.provider = provideOwned;
        self.provider_ctx = self;
        if (self.device) |d| {
            switch (self.backend) {
                .ext => {
                    wl.ext_data_control_device_v1_set_selection(@ptrCast(@alignCast(d)), @ptrCast(src.?));
                    wl.ext_data_control_device_v1_set_primary_selection(@ptrCast(@alignCast(d)), @ptrCast(src.?));
                },
                .wlr => {
                    wl.zwlr_data_control_device_v1_set_selection(@ptrCast(@alignCast(d)), @ptrCast(src.?));
                    wl.zwlr_data_control_device_v1_set_primary_selection(@ptrCast(@alignCast(d)), @ptrCast(src.?));
                },
            }
        }
        if (self.display) |disp| _ = wl.wl_display_flush(disp);
        self.notifyChanged();
        return true;
    }

    fn extDataOffer(data: ?*anyopaque, dev: ?*wl.ext_data_control_device_v1, id: ?*wl.ext_data_control_offer_v1) callconv(.c) void {
        _ = dev;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (id) |o| self.onDataOffer(@ptrCast(o));
    }
    fn extSelection(data: ?*anyopaque, dev: ?*wl.ext_data_control_device_v1, id: ?*wl.ext_data_control_offer_v1) callconv(.c) void {
        _ = dev;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onSelection(if (id) |o| @ptrCast(o) else null, false);
    }
    fn extPrimary(data: ?*anyopaque, dev: ?*wl.ext_data_control_device_v1, id: ?*wl.ext_data_control_offer_v1) callconv(.c) void {
        _ = dev;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onSelection(if (id) |o| @ptrCast(o) else null, true);
    }
    fn extFinished(data: ?*anyopaque, dev: ?*wl.ext_data_control_device_v1) callconv(.c) void {
        _ = dev;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onDeviceFinished();
    }
    fn extSend(data: ?*anyopaque, src: ?*wl.ext_data_control_source_v1, mime: [*c]const u8, fd: i32) callconv(.c) void {
        _ = src;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onSourceSend(mime, fd);
    }
    fn extCancelled(data: ?*anyopaque, src: ?*wl.ext_data_control_source_v1) callconv(.c) void {
        _ = src;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onSourceCancelled();
    }

    fn wlrDataOffer(data: ?*anyopaque, dev: ?*wl.zwlr_data_control_device_v1, id: ?*wl.zwlr_data_control_offer_v1) callconv(.c) void {
        _ = dev;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (id) |o| self.onDataOffer(@ptrCast(o));
    }
    fn wlrSelection(data: ?*anyopaque, dev: ?*wl.zwlr_data_control_device_v1, id: ?*wl.zwlr_data_control_offer_v1) callconv(.c) void {
        _ = dev;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onSelection(if (id) |o| @ptrCast(o) else null, false);
    }
    fn wlrFinished(data: ?*anyopaque, dev: ?*wl.zwlr_data_control_device_v1) callconv(.c) void {
        _ = dev;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onDeviceFinished();
    }
    fn wlrSend(data: ?*anyopaque, src: ?*wl.zwlr_data_control_source_v1, mime: [*c]const u8, fd: i32) callconv(.c) void {
        _ = src;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onSourceSend(mime, fd);
    }
    fn wlrCancelled(data: ?*anyopaque, src: ?*wl.zwlr_data_control_source_v1) callconv(.c) void {
        _ = src;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onSourceCancelled();
    }

    const ext_device_listener = wl.ext_data_control_device_v1_listener{
        .data_offer = extDataOffer,
        .selection = extSelection,
        .finished = extFinished,
        .primary_selection = extPrimary,
    };
    const ext_offer_listener = wl.ext_data_control_offer_v1_listener{
        .offer = extOfferMimeReal,
    };
    const ext_source_listener = wl.ext_data_control_source_v1_listener{
        .send = extSend,
        .cancelled = extCancelled,
    };
    const wlr_device_listener = wl.zwlr_data_control_device_v1_listener{
        .data_offer = wlrDataOffer,
        .selection = wlrSelection,
        .finished = wlrFinished,
        .primary_selection = wlrPrimaryReal,
    };
    const wlr_offer_listener = wl.zwlr_data_control_offer_v1_listener{
        .offer = wlrOfferMimeReal,
    };
    const wlr_source_listener = wl.zwlr_data_control_source_v1_listener{
        .send = wlrSend,
        .cancelled = wlrCancelled,
    };

    fn extOfferMimeReal(data: ?*anyopaque, offer: ?*wl.ext_data_control_offer_v1, mime: [*c]const u8) callconv(.c) void {
        const o: *Offer = @ptrCast(@alignCast(data orelse return));
        if (mime == null) return;
        o.svc.onOfferMime(@ptrCast(offer orelse return), std.mem.span(mime));
    }
    fn wlrOfferMimeReal(data: ?*anyopaque, offer: ?*wl.zwlr_data_control_offer_v1, mime: [*c]const u8) callconv(.c) void {
        const o: *Offer = @ptrCast(@alignCast(data orelse return));
        if (mime == null) return;
        o.svc.onOfferMime(@ptrCast(offer orelse return), std.mem.span(mime));
    }
    fn wlrPrimaryReal(data: ?*anyopaque, dev: ?*wl.zwlr_data_control_device_v1, id: ?*wl.zwlr_data_control_offer_v1) callconv(.c) void {
        _ = dev;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.onSelection(if (id) |o| @ptrCast(o) else null, true);
    }
};

test "clipboard: mime preference order" {
    const t = std.testing;
    const m = [_][]const u8{ "text/uri-list", "text/plain", "text/plain;charset=utf-8" };
    try t.expectEqualStrings(mime_utf8, preferredMime(&m).?);
    const m2 = [_][]const u8{"application/x-y"};
    try t.expectEqualStrings("application/x-y", preferredMime(&m2).?);
    try t.expect(preferredMime(&[_][]const u8{}) == null);
    try t.expectEqual(Backend.ext, backendForInterface("ext_data_control_manager_v1").?);
    try t.expectEqual(Backend.wlr, backendForInterface("zwlr_data_control_manager_v1").?);
    try t.expect(backendForInterface("wl_compositor") == null);
}

test "clipboard: file uri round trip" {
    const t = std.testing;
    const u = try fileUriForPath(t.allocator, "/home/u/My Docs/a b.txt");
    defer t.allocator.free(u);
    try t.expectEqualStrings("file:///home/u/My%20Docs/a%20b.txt", u);
    const dec = try pathDecode(t.allocator, pathFromFileUri(u));
    defer t.allocator.free(dec);
    try t.expectEqualStrings("/home/u/My Docs/a b.txt", dec);
    try t.expectEqualStrings("", pathFromFileUri("https://x"));
}

test "clipboard: gnome-copied-files parse" {
    const t = std.testing;
    const raw = "x-special/nautilus-clipboard\ncut\nfile:///home/u/a%20b.txt\n/home/u/plain\n";
    var fl = parseGnomeFilesBody(t.allocator, raw).?;
    defer fl.deinit(t.allocator);
    try t.expect(fl.is_cut);
    try t.expectEqual(@as(usize, 2), fl.paths.items.len);
    try t.expectEqualStrings("/home/u/a b.txt", fl.paths.items[0]);
    try t.expectEqualStrings("/home/u/plain", fl.paths.items[1]);

    // Header-less spelling (what `copyFiles` writes) with CRLF endings.
    var fl2 = parseGnomeFilesBody(t.allocator, "copy\r\nfile:///x\r\n").?;
    defer fl2.deinit(t.allocator);
    try t.expect(!fl2.is_cut);
    try t.expectEqualStrings("/x", fl2.paths.items[0]);

    // Malformed first line → null (the caller falls through to uri-list).
    try t.expect(parseGnomeFilesBody(t.allocator, "hello\ncut\nfile:///x\n") == null);
    try t.expect(parseGnomeFilesBody(t.allocator, "") == null);

    // Header only: valid parse, no paths, flag kept — mirrors the C++ which
    // returns the flag to the uri-list branch in this case.
    var fl3 = parseGnomeFilesBody(t.allocator, "cut\n").?;
    defer fl3.deinit(t.allocator);
    try t.expect(fl3.is_cut and fl3.paths.items.len == 0);
}

test "clipboard: uri-list lines, plain lines, canonical path" {
    const t = std.testing;
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |p| t.allocator.free(p);
        out.deinit(t.allocator);
    }
    appendUriLines(t.allocator, "# comment\r\nfile:///a\r\n  file:///b%41  \r\n\n", &out, true);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqualStrings("/a", out.items[0]);
    try t.expectEqualStrings("/bA", out.items[1]);

    // `#` lines parse as no path either way — the C++ skip is dead code,
    // kept in the port for shape; non-path lines are dropped regardless.
    appendUriLines(t.allocator, "#x\nrelative-skip\n/tmp\n", &out, false);
    try t.expectEqual(@as(usize, 3), out.items.len);
    try t.expectEqualStrings("/tmp", out.items[2]);

    try t.expect(canonicalAbsolutePath(t.allocator, "relative/x") == null);
    const c = canonicalAbsolutePath(t.allocator, "/a/./b/../c").?;
    defer t.allocator.free(c);
    try t.expectEqualStrings("/a/c", c);
}

const LiveProv = struct {
    var payload: []const u8 = "zig-clipboard-live-probe";
    fn provide(ctx: *anyopaque, mime: []const u8, alloc: std.mem.Allocator) ?[]u8 {
        _ = ctx;
        _ = mime;
        return alloc.dupe(u8, payload) catch null;
    }
    fn pumpConn(ctx: *anyopaque) void {
        const conn: *@import("../connection.zig").Connection = @ptrCast(@alignCast(ctx));
        _ = conn.roundtrip();
    }
};

/// True when the current clipboard offer carries `mime`. Used after a copy
/// to confirm the compositor echoed our new selection as a fresh offer
/// before the test reads it back — reading through a stale offer would ask
/// the compositor to receive from an object it already destroyed.
fn offerHasMime(svc: *Service, mime: []const u8) bool {
    for (svc.currentMimes(false)) |m| {
        if (std.mem.eql(u8, m, mime)) return true;
    }
    return false;
}

test "clipboard: live set + receive round trip" {
    // Opt-in only. This test takes ownership of the session clipboard and
    // publishes the probe payloads below. Running it from a normal
    // `zig build test` makes ClipStack record those probes and can leave one
    // as the active selection (or restore one after a daemon restart), which
    // looks like copy/paste corruption to the person using the desktop.
    // Set EH_CLIPBOARD_LIVE_TEST=1 only on an isolated compositor or when
    // deliberately testing the live clipboard.
    const opt_in = std.c.getenv("EH_CLIPBOARD_LIVE_TEST") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(opt_in), "1")) return error.SkipZigTest;

    const t = std.testing;
    const Conn = @import("../connection.zig").Connection;
    var conn = Conn.init(t.allocator);
    defer conn.deinit();
    if (!conn.connect(null)) return error.SkipZigTest;
    var bound = Conn.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    const seat = bound.seat orelse return error.SkipZigTest;
    const backend: Backend = if (bound.ext_data_control != null) .ext else if (bound.wlr_data_control != null) .wlr else return error.SkipZigTest;
    const mgr = if (backend == .ext) bound.ext_data_control.? else bound.wlr_data_control.?;

    var svc = Service.init(t.allocator);
    defer svc.deinit();
    try t.expect(svc.bind(mgr, backend, seat, conn.display));
    try t.expect(svc.isAvailable());
    try t.expect(!svc.ownsSelection());
    try t.expect(svc.setSelection(&[_][]const u8{mime_plain}, LiveProv.provide, undefined, false));
    try t.expect(svc.ownsSelection());

    var ticks: u32 = 0;
    var seen = false;
    while (ticks < 100 and !seen) : (ticks += 1) {
        if (!conn.roundtrip()) break;
        if (svc.currentMimes(false).len > 0) seen = true;
    }
    try t.expect(seen);
    const mime = preferredMime(svc.currentMimes(false)) orelse return error.SkipZigTest;
    const data = svc.receivePump(mime, false, 5000, LiveProv.pumpConn, &conn) orelse return error.SkipZigTest;
    defer t.allocator.free(data);
    try t.expectEqualStrings(LiveProv.payload, data);

    // copy_text round trip: owned payload, both text mimes, clipboard and
    // primary selection on the same source.
    try t.expect(svc.copyText("zig clipboard text probe"));
    _ = conn.roundtrip();
    if (!offerHasMime(&svc, mime_utf8)) return error.SkipZigTest; // compositor that does not echo our selection
    const text = svc.readSelectionText(LiveProv.pumpConn, &conn) orelse return error.SkipZigTest;
    defer t.allocator.free(text);
    try t.expectEqualStrings("zig clipboard text probe", text);

    // copy_files round trip through the read_files ladder.
    try t.expect(svc.copyFiles(true, &[_][]const u8{"/tmp"}));
    _ = conn.roundtrip();
    if (!offerHasMime(&svc, mime_gnome_files)) return error.SkipZigTest;
    var fl = svc.readFiles(t.allocator, LiveProv.pumpConn, &conn);
    defer fl.deinit(t.allocator);
    try t.expect(fl.is_cut);
    try t.expectEqual(@as(usize, 1), fl.paths.items.len);
    try t.expectEqualStrings("/tmp", fl.paths.items[0]);

    // copy_data upsert quirk: a second mime joins the first on the same
    // source instead of replacing it.
    try t.expect(svc.copyData("image/png", "\x89PNG-probe"));
    _ = conn.roundtrip();
    if (!offerHasMime(&svc, "image/png")) return error.SkipZigTest;
    try t.expect(svc.selectionHasMime(mime_gnome_files));
    try t.expect(svc.selectionHasMime("image/png"));
    const png = svc.readData("image/png", LiveProv.pumpConn, &conn) orelse return error.SkipZigTest;
    defer t.allocator.free(png);
    try t.expectEqualStrings("\x89PNG-probe", png);

    // wlr fallback, live: when the compositor also advertises
    // wlr-data-control (Hyprland does, at v2, next to ext), run the same
    // set → echo → receive ladder on a second service bound to the wlr
    // manager. The ext service above is the preferred path; this is the one
    // compositors without ext-data-control use, and it exercises every wlr
    // thunk (device/offer/source listeners, receive, set_selection,
    // set_primary_selection). Silently skipped when wlr is not advertised.
    if (bound.wlr_data_control) |wmgr| {
        var wsvc = Service.init(t.allocator);
        defer wsvc.deinit();
        try t.expect(wsvc.bind(wmgr, .wlr, seat, conn.display));
        try t.expect(wsvc.isAvailable());
        try t.expect(wsvc.setSelection(&[_][]const u8{mime_plain}, LiveProv.provide, undefined, false));
        try t.expect(wsvc.ownsSelection());

        var wticks: u32 = 0;
        var wseen = false;
        while (wticks < 100 and !wseen) : (wticks += 1) {
            if (!conn.roundtrip()) break;
            if (wsvc.currentMimes(false).len > 0) wseen = true;
        }
        try t.expect(wseen);
        const wmime = preferredMime(wsvc.currentMimes(false)) orelse return error.SkipZigTest;
        const wdata = wsvc.receivePump(wmime, false, 5000, LiveProv.pumpConn, &conn) orelse return error.SkipZigTest;
        defer t.allocator.free(wdata);
        try t.expectEqualStrings(LiveProv.payload, wdata);

        // copy_files on wlr sets clipboard + primary on one source; the read
        // ladder then walks the wlr offer thunks.
        try t.expect(wsvc.copyFiles(false, &[_][]const u8{"/tmp"}));
        _ = conn.roundtrip();
        if (!offerHasMime(&wsvc, mime_gnome_files)) return error.SkipZigTest;
        var wfl = wsvc.readFiles(t.allocator, LiveProv.pumpConn, &conn);
        defer wfl.deinit(t.allocator);
        try t.expect(!wfl.is_cut);
        try t.expectEqual(@as(usize, 1), wfl.paths.items.len);
        try t.expectEqualStrings("/tmp", wfl.paths.items[0]);
    }
}
