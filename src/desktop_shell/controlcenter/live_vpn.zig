//! Live VPN connections behind the dock/panel VPN card: read from
//! NetworkManager through `nmcli`, written back through `nmcli`.
//!
//! VPN half: refresh, activate, deactivate,
//! remove. Activation is exclusive: bringing a VPN up first takes every other
//! live VPN down, so there is only ever one connected at a time. A worker
//! thread with a periodic refresh; here the dock owns the poll and the card is
//! the only consumer, so the two `nmcli` reads run on the caller's thread
//! behind the dock's own throttle, and every *write* runs in a detached
//! thread — a VPN that takes 10 s to come up must never stall the Wayland
//! loop.
//!
//! Parsing is a uuid-anchored split: `nmcli -t`
//! escapes ':' inside a field, but a name containing a colon still lands in
//! the same shape, so the uuid token (always 36 chars, always hex-and-dash)
//! is found rather than split to. Any failure — no nmcli, no NM — yields
//! `null`/nothing and the caller keeps its previous list.

const std = @import("std");

/// The two connection types the card shows. WireGuard counts as a VPN here,
/// exactly as the filter does.
const vpn_types = [_][]const u8{ "vpn", "wireguard" };

pub const Connection = struct {
    uuid: []const u8 = "",
    name: []const u8 = "",
    /// `connection.autoconnect` as nmcli printed it (`yes`/`no`).
    autoconnect: bool = false,
    active: bool = false,
    /// Network interface while active (`airvpn_canada_u`, `wg0`, `tun0`).
    device: []const u8 = "",
    /// First active local address, prefix stripped. Fits an IPv6 literal.
    tunnel_ip: []const u8 = "",
    /// `connection.timestamp` (unix seconds): activation time for a live row.
    timestamp: i64 = 0,
    /// Interface counters sampled on the same read as the roster.
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
};

fn isVpnType(t: []const u8) bool {
    for (vpn_types) |k| {
        if (std.mem.eql(u8, t, k)) return true;
    }
    return false;
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// `is_uuid_token` — 8-4-4-4-12 hex with dashes at 8, 13, 18, 23.
fn uuidAt(line: []const u8, i: usize) bool {
    if (i + 36 > line.len) return false;
    const t = line[i .. i + 36];
    for ([_]usize{ 8, 13, 18, 23 }) |d| {
        if (t[d] != '-') return false;
    }
    for (t, 0..) |c, j| {
        if (c == '-') continue;
        if (j == 8 or j == 13 or j == 18 or j == 23) return false;
        if (!isHex(c)) return false;
    }
    return true;
}

/// `split_vpn_line` — the uuid is *found*, not split to: a name with a colon
/// in it would otherwise shift every field. Answers the field slices into
/// `line` (borrowed).
fn splitVpnLine(line: []const u8) ?struct { name: []const u8, uuid: []const u8, type: []const u8, tail: []const u8 } {
    var i: usize = 0;
    while (i + 36 <= line.len) : (i += 1) {
        if (!uuidAt(line, i)) continue;
        if (i > 0 and line[i - 1] != ':') continue;
        if (i + 36 < line.len and line[i + 36] != ':') continue;
        const name = if (i == 0) "" else line[0 .. i - 1];
        const rest = if (i + 36 < line.len) line[i + 37 ..] else "";
        if (std.mem.indexOfScalar(u8, rest, ':')) |c| {
            return .{ .name = name, .uuid = line[i .. i + 36], .type = rest[0..c], .tail = rest[c + 1 ..] };
        }
        return .{ .name = name, .uuid = line[i .. i + 36], .type = rest, .tail = "" };
    }
    return null;
}

/// Parse one `nmcli -t` document (NAME:UUID:TYPE:…) into owned rows, keeping
/// only the VPN/WireGuard types. `active_uuids` marks rows live; when null,
/// every row is inactive (the saved-connections read). `tail_is_autoconnect`
/// selects what the fourth field means: the active read prints DEVICE:STATE,
/// the saved read AUTOCONNECT[:TIMESTAMP].
pub fn parseNmcli(
    alloc: std.mem.Allocator,
    text: []const u8,
    active_uuids: ?[]const []const u8,
    tail_is_autoconnect: bool,
) ![]Connection {
    var out: std.ArrayList(Connection) = .empty;
    errdefer {
        for (out.items) |*c| {
            alloc.free(c.uuid);
            alloc.free(c.name);
        }
        out.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const f = splitVpnLine(line) orelse continue;
        if (!isVpnType(f.type)) continue;
        var active = false;
        if (active_uuids) |list| {
            for (list) |u| {
                if (std.mem.eql(u8, u, f.uuid)) {
                    active = true;
                    break;
                }
            }
        }
        var autoconnect = false;
        var timestamp: i64 = 0;
        if (tail_is_autoconnect) {
            var t = std.mem.splitScalar(u8, f.tail, ':');
            autoconnect = std.mem.eql(u8, t.next() orelse "", "yes");
            if (t.next()) |stamp| timestamp = std.fmt.parseInt(i64, std.mem.trim(u8, stamp, " \t\r"), 10) catch 0;
        }
        try out.append(alloc, .{
            .uuid = try alloc.dupe(u8, f.uuid),
            .name = try alloc.dupe(u8, f.name),
            .autoconnect = autoconnect,
            .active = active,
            .timestamp = timestamp,
        });
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeConnections(alloc: std.mem.Allocator, conns: []Connection) void {
    for (conns) |*c| {
        alloc.free(c.uuid);
        alloc.free(c.name);
        if (c.device.len > 0) alloc.free(c.device);
        if (c.tunnel_ip.len > 0) alloc.free(c.tunnel_ip);
    }
    alloc.free(conns);
}

fn runNmcli(io: std.Io, argv: []const []const u8) ?[]u8 {
    const res = std.process.run(std.heap.page_allocator, io, .{ .argv = argv }) catch return null;
    defer std.heap.page_allocator.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        std.heap.page_allocator.free(res.stdout);
        return null;
    }
    return res.stdout;
}

/// Stable presentation order: name, then uuid as a tie-breaker. Deliberately
/// independent of `active` — a row that connects must stay where it was.
fn sortConnections(conns: []Connection) void {
    std.mem.sort(Connection, conns, {}, struct {
        fn lt(_: void, a: Connection, b: Connection) bool {
            if (!std.mem.eql(u8, a.name, b.name)) return std.mem.lessThan(u8, a.name, b.name);
            return std.mem.lessThan(u8, a.uuid, b.uuid);
        }
    }.lt);
}

/// Parsed `NAME:UUID:TYPE:DEVICE:STATE` tail. The state token is not used
/// (the active read only returns live rows) but device is the interface the
/// tunnel owns.
const ActiveMeta = struct { uuid: []const u8, device: []const u8 };

/// First address line of `nmcli -t -f IP4.ADDRESS,IP6.ADDRESS device show`.
/// IPv4 wins; a non-link-local IPv6 is the fallback. The returned slice
/// borrows `text`, with the `/prefix` suffix removed.
fn tunnelFromNmcli(text: []const u8) ?[]const u8 {
    var v6: ?[]const u8 = null;
    var v6_global: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (value.len == 0) continue;
        const slash = std.mem.indexOfScalar(u8, value, '/') orelse value.len;
        const addr = value[0..slash];
        if (std.mem.startsWith(u8, key, "IP4.ADDRESS")) return addr;
        if (std.mem.startsWith(u8, key, "IP6.ADDRESS")) {
            if (v6 == null) v6 = addr;
            if (v6_global == null and !std.ascii.startsWithIgnoreCase(addr, "fe80:")) v6_global = addr;
        }
    }
    return v6_global orelse v6;
}

fn readTunnelIp(alloc: std.mem.Allocator, io: std.Io, device: []const u8) ?[]u8 {
    const text = runNmcli(io, &.{
        "nmcli", "-t", "-f", "IP4.ADDRESS,IP6.ADDRESS", "device", "show", device,
    }) orelse return null;
    defer std.heap.page_allocator.free(text);
    const addr = tunnelFromNmcli(text) orelse return null;
    return alloc.dupe(u8, addr) catch null;
}

fn readNetStat(io: std.Io, device: []const u8, comptime stat: []const u8) u64 {
    var path_buf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/class/net/{s}/statistics/{s}", .{ device, stat }) catch return 0;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(64)) catch return 0;
    defer std.heap.page_allocator.free(data);
    return std.fmt.parseInt(u64, std.mem.trim(u8, data, " \t\r\n"), 10) catch 0;
}

/// `do_refresh_vpn`: the active list first (its uuids mark the saved list and
/// carry the tunnel device), then the saved list itself. Rows keep a stable
/// name order whether or not they are connected, so a connection never jumps
/// to the top of the card. Null when nmcli is missing or either read failed;
/// the caller keeps what it had.
pub fn query(alloc: std.mem.Allocator, io: std.Io) ?[]Connection {
    const active_text = runNmcli(io, &.{
        "nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE,STATE", "connection", "show", "--active",
    }) orelse return null;
    defer std.heap.page_allocator.free(active_text);

    // uuids of live VPN/WireGuard rows, page-allocated: this is a lookup
    // table that dies with the function, never handed out. The active meta
    // borrows `active_text` and carries the interface for the live reads.
    var active_uuids = std.ArrayList([]const u8).empty;
    defer {
        for (active_uuids.items) |u| std.heap.page_allocator.free(u);
        active_uuids.deinit(std.heap.page_allocator);
    }
    var active_meta = std.ArrayList(ActiveMeta).empty;
    defer active_meta.deinit(std.heap.page_allocator);
    {
        var it = std.mem.splitScalar(u8, active_text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const f = splitVpnLine(line) orelse continue;
            if (!isVpnType(f.type)) continue;
            const u = std.heap.page_allocator.dupe(u8, f.uuid) catch continue;
            active_uuids.append(std.heap.page_allocator, u) catch {
                std.heap.page_allocator.free(u);
                continue;
            };
            const dev_colon = std.mem.indexOfScalar(u8, f.tail, ':') orelse f.tail.len;
            const device = std.mem.trim(u8, f.tail[0..dev_colon], " \t\r");
            active_meta.append(std.heap.page_allocator, .{ .uuid = f.uuid, .device = device }) catch {};
        }
    }

    const all_text = runNmcli(io, &.{
        "nmcli", "-t", "-f", "NAME,UUID,TYPE,AUTOCONNECT,TIMESTAMP", "connection", "show",
    }) orelse return null;
    defer std.heap.page_allocator.free(all_text);

    const conns = parseNmcli(alloc, all_text, active_uuids.items, true) catch return null;
    for (conns) |*c| {
        if (!c.active) continue;
        for (active_meta.items) |m| {
            if (!std.mem.eql(u8, m.uuid, c.uuid)) continue;
            if (m.device.len > 0) c.device = alloc.dupe(u8, m.device) catch "";
            break;
        }
        if (c.device.len > 0) {
            c.tunnel_ip = readTunnelIp(alloc, io, c.device) orelse "";
            c.rx_bytes = readNetStat(io, c.device, "rx_bytes");
            c.tx_bytes = readNetStat(io, c.device, "tx_bytes");
        }
    }
    sortConnections(conns);
    return conns;
}

// Verbs — every one in a detached thread, page allocator only

pub const VerbKind = enum { up, down, cancel, auto, delete };

/// Outcome of one detached verb, consumed by the settings page. Failures
/// carry nmcli's first stderr line so the row can show a human-readable
/// "Failed: …" status instead of a generic timeout.
pub const VerbResult = struct {
    uuid: [64]u8 = undefined,
    uuid_len: usize = 0,
    kind: VerbKind = .up,
    ok: bool = false,
    msg: [160]u8 = undefined,
    msg_len: usize = 0,

    pub fn uuidText(self: *const VerbResult) []const u8 {
        return self.uuid[0..self.uuid_len];
    }

    pub fn msgText(self: *const VerbResult) []const u8 {
        return self.msg[0..self.msg_len];
    }
};

const verb_result_slots = 8;
var verb_results: [verb_result_slots]VerbResult = undefined;
var verb_results_head: usize = 0;
var verb_results_len: usize = 0;
var verb_results_mutex: std.atomic.Mutex = .unlocked;

fn postVerbResult(uuid: []const u8, kind: VerbKind, ok: bool, msg: []const u8) void {
    verbLockMutex(&verb_results_mutex);
    defer verb_results_mutex.unlock();
    if (verb_results_len == verb_result_slots) {
        verb_results_head = (verb_results_head + 1) % verb_result_slots;
        verb_results_len -= 1;
    }
    const idx = (verb_results_head + verb_results_len) % verb_result_slots;
    const r = &verb_results[idx];
    const un = @min(uuid.len, r.uuid.len);
    @memcpy(r.uuid[0..un], uuid[0..un]);
    r.uuid_len = un;
    r.kind = kind;
    r.ok = ok;
    const mn = @min(msg.len, r.msg.len);
    @memcpy(r.msg[0..mn], msg[0..mn]);
    r.msg_len = mn;
    verb_results_len += 1;
}

/// Pop the oldest verb outcome, copying it out of the shared ring.
pub fn takeVerbResult() ?VerbResult {
    verbLockMutex(&verb_results_mutex);
    defer verb_results_mutex.unlock();
    if (verb_results_len == 0) return null;
    const out = verb_results[verb_results_head];
    verb_results_head = (verb_results_head + 1) % verb_result_slots;
    verb_results_len -= 1;
    return out;
}

/// Serializes the verbs. Exclusivity is a read-then-write ("which VPNs are
/// live?" then "down them, then up this one"), so two quick Connect clicks
/// must not interleave and leave both VPNs live.
var verb_lock: std.atomic.Mutex = .unlocked;

fn verbLock() void {
    verbLockMutex(&verb_lock);
}

fn verbLockMutex(m: *std.atomic.Mutex) void {
    var spins: u32 = 0;
    while (!m.tryLock()) {
        spins +%= 1;
        if (spins < 64) {
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
        }
    }
}

fn copyFirstLine(out: *[160]u8, raw: []const u8) usize {
    const line = firstLine(raw);
    const n = @min(line.len, out.len);
    @memcpy(out[0..n], line[0..n]);
    if (n < out.len) out[n] = 0;
    return n;
}

/// Run one nmcli verb and keep the first stderr line on failure. The caller
/// owns postVerbResult; query reads still use the quieter `runNmcli`.
fn runNmcliCapture(io: std.Io, argv: []const []const u8, reason: *[160]u8) bool {
    @memset(reason, 0);
    const res = std.process.run(std.heap.page_allocator, io, .{ .argv = argv }) catch {
        const n = copyFirstLine(reason, "nmcli could not be run");
        _ = n;
        return false;
    };
    defer std.heap.page_allocator.free(res.stdout);
    defer std.heap.page_allocator.free(res.stderr);
    if (res.term == .exited and res.term.exited == 0) return true;
    const raw = if (res.stderr.len > 0) res.stderr else res.stdout;
    const n = copyFirstLine(reason, raw);
    if (n == 0) _ = copyFirstLine(reason, "nmcli failed");
    return false;
}

/// Deactivate a VPN and stop NetworkManager from re-dialling it: down, then
/// autoconnect off. A manual disconnect must stick, and the VPN displaced by
/// another activation has to stay down rather than racing it for the tunnel.
fn deactivateVpn(io: std.Io, uuid: []const u8) void {
    _ = runNmcli(io, &.{ "nmcli", "connection", "down", "uuid", uuid });
    _ = runNmcli(io, &.{ "nmcli", "connection", "modify", "uuid", uuid, "connection.autoconnect", "no" });
}

/// The uuids of every live VPN/WireGuard row in an active `nmcli` read,
/// except `keep_uuid`. The returned slices borrow `text`.
fn otherActiveVpnUuids(alloc: std.mem.Allocator, text: []const u8, keep_uuid: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const f = splitVpnLine(line) orelse continue;
        if (!isVpnType(f.type)) continue;
        if (std.mem.eql(u8, f.uuid, keep_uuid)) continue;
        try out.append(alloc, f.uuid);
    }
    return out.toOwnedSlice(alloc);
}

/// Bring down every live VPN except `keep_uuid`, so only one is ever
/// connected. The active read is the same shape `query` uses, filtered to the
/// VPN types.
fn deactivateOtherVpns(io: std.Io, keep_uuid: []const u8) void {
    const pa = std.heap.page_allocator;
    const text = runNmcli(io, &.{
        "nmcli", "-t", "-f", "NAME,UUID,TYPE,STATE", "connection", "show", "--active",
    }) orelse return;
    defer pa.free(text);
    const others = otherActiveVpnUuids(pa, text, keep_uuid) catch return;
    defer pa.free(others);
    for (others) |uuid| deactivateVpn(io, uuid);
}

const VerbArgs = struct {
    io: std.Io,
    uuid: []u8,
    kind: VerbKind,
    enabled: bool = false,

    fn run(self: *VerbArgs) void {
        const pa = std.heap.page_allocator;
        // LIFO: free the uuid while `self` is still readable, then the struct.
        defer pa.destroy(self);
        defer pa.free(self.uuid);
        verbLock();
        defer verb_lock.unlock();
        var reason: [160]u8 = undefined;
        var ok = false;
        switch (self.kind) {
            // Activate the connection, exclusive: any other live VPN is
            // taken down first.
            .up => {
                deactivateOtherVpns(self.io, self.uuid);
                ok = runNmcliCapture(self.io, &.{ "nmcli", "connection", "up", "uuid", self.uuid }, &reason);
            },
            // `deactivateVpnConnection`: down, then autoconnect off — a
            // manual disconnect must stick, or NM re-dials the VPN the
            // moment it is taken down.
            .down => {
                ok = runNmcliCapture(self.io, &.{ "nmcli", "connection", "down", "uuid", self.uuid }, &reason);
                _ = runNmcli(self.io, &.{ "nmcli", "connection", "modify", "uuid", self.uuid, "connection.autoconnect", "no" });
            },
            // Cancel leaves autoconnect alone: the user only abandoned this
            // activation attempt, they did not ask to disable the profile.
            .cancel => {
                ok = runNmcliCapture(self.io, &.{ "nmcli", "connection", "down", "uuid", self.uuid }, &reason);
            },
            .auto => {
                ok = runNmcliCapture(self.io, &.{
                    "nmcli", "connection", "modify", "uuid", self.uuid, "connection.autoconnect", if (self.enabled) "yes" else "no",
                }, &reason);
            },
            // `removeVpnConnection`.
            .delete => {
                ok = runNmcliCapture(self.io, &.{ "nmcli", "connection", "delete", "uuid", self.uuid }, &reason);
            },
        }
        postVerbResult(self.uuid, self.kind, ok, reason[0..copyFirstLineLen(&reason)]);
    }
};

fn copyFirstLineLen(buf: *[160]u8) usize {
    var n: usize = 0;
    while (n < buf.len and buf[n] != 0) n += 1;
    return n;
}

fn verbThread(io: std.Io, uuid: []const u8, kind: VerbKind, enabled: bool) void {
    const pa = std.heap.page_allocator;
    const args = pa.create(VerbArgs) catch return;
    args.* = .{
        .io = io,
        .uuid = pa.dupe(u8, uuid) catch {
            pa.destroy(args);
            return;
        },
        .kind = kind,
        .enabled = enabled,
    };
    const t = std.Thread.spawn(.{}, VerbArgs.run, .{args}) catch {
        pa.free(args.uuid);
        pa.destroy(args);
        return;
    };
    t.detach();
}

pub fn activateThread(io: std.Io, uuid: []const u8) void {
    if (uuid.len == 0) return;
    verbThread(io, uuid, .up, false);
}

pub fn deactivateThread(io: std.Io, uuid: []const u8) void {
    if (uuid.len == 0) return;
    verbThread(io, uuid, .down, false);
}

pub fn cancelThread(io: std.Io, uuid: []const u8) void {
    if (uuid.len == 0) return;
    verbThread(io, uuid, .cancel, false);
}

pub fn removeThread(io: std.Io, uuid: []const u8) void {
    if (uuid.len == 0) return;
    verbThread(io, uuid, .delete, false);
}

// Public exit-address lookup ───────────────────────────────────────────────
//
// This is the one outbound request the VPN page makes: after a tunnel comes
// up it asks a configurable HTTPS endpoint for the address the world sees.
// The page owns the off switch and endpoint, and only calls this while a
// connection is Connected. One lookup can be in flight at a time; the result
// is matched by uuid so a stale lookup cannot paint the wrong row.

const kExitIdle: u8 = 0;
const kExitRunning: u8 = 1;
const kExitReady: u8 = 2;

var exit_phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(kExitIdle);
var exit_uuid: [64]u8 = undefined;
var exit_uuid_len: usize = 0;
var exit_text: [64]u8 = undefined;
var exit_text_len: usize = 0;
var exit_ok: bool = false;

pub const ExitIpResult = struct {
    uuid: [64]u8 = undefined,
    uuid_len: usize = 0,
    text: [64]u8 = undefined,
    text_len: usize = 0,
    ok: bool = false,

    pub fn uuidText(self: *const ExitIpResult) []const u8 {
        return self.uuid[0..self.uuid_len];
    }

    pub fn textText(self: *const ExitIpResult) []const u8 {
        return self.text[0..self.text_len];
    }
};

const ExitArgs = struct {
    io: std.Io,
    url: []u8,

    fn run(self: *ExitArgs) void {
        const pa = std.heap.page_allocator;
        defer {
            pa.free(self.url);
            pa.destroy(self);
        }
        const body = fetchExitText(self.io, self.url) orelse {
            exit_ok = false;
            exit_text_len = 0;
            exit_phase.store(kExitReady, .release);
            return;
        };
        defer pa.free(body);
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        const n = @min(trimmed.len, exit_text.len);
        @memcpy(exit_text[0..n], trimmed[0..n]);
        exit_text_len = n;
        exit_ok = n > 0;
        exit_phase.store(kExitReady, .release);
    }
};

fn fetchExitText(io: std.Io, url: []const u8) ?[]u8 {
    const pa = std.heap.page_allocator;
    var client = std.http.Client{ .allocator = pa, .io = io };
    defer client.deinit();
    var aw = std.Io.Writer.Allocating.init(pa);
    defer aw.deinit();
    const res = client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    }) catch return null;
    if (res.status != .ok) return null;
    const body = aw.toOwnedSlice() catch return null;
    if (body.len > 4096) {
        pa.free(body);
        return null;
    }
    return body;
}

/// Start one lookup. Returns false when a lookup is already running, the
/// endpoint is empty (the off switch), or the thread could not spawn.
pub fn requestExitIp(io: std.Io, uuid: []const u8, url: []const u8) bool {
    if (url.len == 0 or uuid.len == 0) return false;
    if (exit_phase.load(.acquire) != kExitIdle) return false;
    const n = @min(uuid.len, exit_uuid.len);
    @memcpy(exit_uuid[0..n], uuid[0..n]);
    exit_uuid_len = n;
    exit_text_len = 0;
    exit_ok = false;
    exit_phase.store(kExitRunning, .release);

    const pa = std.heap.page_allocator;
    const args = pa.create(ExitArgs) catch {
        exit_phase.store(kExitIdle, .release);
        return false;
    };
    args.* = .{
        .io = io,
        .url = pa.dupe(u8, url) catch {
            pa.destroy(args);
            exit_phase.store(kExitIdle, .release);
            return false;
        },
    };
    const t = std.Thread.spawn(.{}, ExitArgs.run, .{args}) catch {
        pa.free(args.url);
        pa.destroy(args);
        exit_phase.store(kExitIdle, .release);
        return false;
    };
    t.detach();
    return true;
}

/// Pop a finished lookup. Safe to call every paint; a miss is one atomic load.
pub fn takeExitIp() ?ExitIpResult {
    if (exit_phase.load(.acquire) != kExitReady) return null;
    var out = ExitIpResult{};
    @memcpy(out.uuid[0..exit_uuid_len], exit_uuid[0..exit_uuid_len]);
    out.uuid_len = exit_uuid_len;
    out.text_len = exit_text_len;
    @memcpy(out.text[0..exit_text_len], exit_text[0..exit_text_len]);
    out.ok = exit_ok;
    exit_phase.store(kExitIdle, .release);
    return out;
}

// The read, off the Wayland thread

const kIdle: u8 = 0;
const kRunning: u8 = 1;
const kReady: u8 = 2;

var phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(kIdle);
/// What a finished read published, plus the allocator it borrowed. Written
/// before the release store that marks it ready, read after the matching
/// acquire — the phase state machine is the whole hand-off, exactly as
/// `services/weather.zig` does it.
var landed: ?Landed = null;
var worker: ?std.Thread = null;

pub const Landed = struct {
    alloc: std.mem.Allocator,
    rows: []Connection,
};

/// True when no read is in flight, i.e. `request` would start one.
pub fn idle() bool {
    return phase.load(.acquire) == kIdle;
}

/// Start a read unless one is already running. `nmcli` is a process spawn
/// with a D-Bus round trip behind it — tens of milliseconds, sometimes
/// hundreds — which is an input stall on the thread that also dispatches
/// clicks, so it runs on a worker thread.
/// to its own thread. The *host* owns the deadline, so a spawn that failed
/// once cannot be retried in a tight loop.
pub fn request(alloc: std.mem.Allocator, io: std.Io) bool {
    if (phase.load(.acquire) != kIdle) return false;
    // A worker only ever falls back to idle after publishing, so joining
    // here cannot block on a read that is still running.
    if (worker) |w| {
        w.join();
        worker = null;
    }
    const job = alloc.create(Job) catch return false;
    job.* = .{ .alloc = alloc, .io = io };
    phase.store(kRunning, .release);
    worker = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        phase.store(kIdle, .release);
        alloc.destroy(job);
        return false;
    };
    return true;
}

/// Move a finished list into `out`; the caller owns the rows outright and
/// frees them with `freeConnections`. False when nothing has landed.
pub fn take(out: *?[]Connection) bool {
    if (phase.load(.acquire) != kReady) return false;
    const l = landed.?;
    out.* = l.rows;
    landed = null;
    phase.store(kIdle, .release);
    return true;
}

/// Drain the worker and drop whatever it published. Called on teardown — and
/// therefore *before* the allocator the worker is borrowing goes away — and
/// by tests that need a clean slate.
pub fn shutdown() void {
    if (worker) |w| {
        w.join();
        worker = null;
    }
    if (landed) |l| {
        freeConnections(l.alloc, l.rows);
        landed = null;
    }
    phase.store(kIdle, .release);
}

const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,

    fn run(self: *Job) void {
        defer self.alloc.destroy(self);
        const rows = query(self.alloc, self.io);
        // A failed read publishes `null` too: the host has to learn that the
        // backend went away, and keeping the old list forever would be a lie.
        landed = if (rows) |r| .{ .alloc = self.alloc, .rows = r } else null;
        phase.store(if (rows != null) kReady else kIdle, .release);
    }
};

// ---------------------------------------------------------------------------
// Settings-page verbs: autoconnect flip, plugin create, WireGuard create and
// file import. Every one runs detached; the Add dialog has closed by the time
// they finish, so failures land in the status mailbox the Network page polls.
// ---------------------------------------------------------------------------

/// Consume-once status line for the last finished write ("" = nothing new).
var status_lock: std.atomic.Mutex = .unlocked;
var status_text: [220]u8 = undefined;
var status_len: usize = 0;
var status_failed: bool = false;

fn statusLock() void {
    var spins: u32 = 0;
    while (!status_lock.tryLock()) {
        spins +%= 1;
        if (spins < 64) {
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
        }
    }
}

fn postStatus(msg: []const u8, failed: bool) void {
    statusLock();
    defer status_lock.unlock();
    const n = @min(msg.len, status_text.len);
    @memcpy(status_text[0..n], msg[0..n]);
    status_len = n;
    status_failed = failed;
}

fn postStatusFmt(comptime f: []const u8, args: anytype) void {
    var buf: [220]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, f, args) catch buf[0..0];
    postStatus(s, true);
}

/// Take the pending status line; null when nothing new since the last call.
pub fn takeStatus(out: *[220]u8, failed: *bool) ?usize {
    statusLock();
    defer status_lock.unlock();
    if (status_len == 0) return null;
    @memcpy(out[0..status_len], status_text[0..status_len]);
    failed.* = status_failed;
    const n = status_len;
    status_len = 0;
    return n;
}

/// Drop a pending line without showing it (tests, teardown).
pub fn clearStatus() void {
    statusLock();
    defer status_lock.unlock();
    status_len = 0;
}

/// `nmcli_added_name` — the profile name out of
/// `Connection 'NAME' (uuid) successfully added.`
pub fn addedName(out: []const u8) []const u8 {
    const marker = "Connection '";
    const p = std.mem.indexOf(u8, out, marker) orelse return "";
    const start = p + marker.len;
    const e = std.mem.indexOfScalarPos(u8, out, start, '\'') orelse return "";
    return out[start..e];
}

/// `wg_import_interface_name` — a WireGuard import source basename must be a
/// valid interface name (≤15 chars, [a-z0-9_-], no leading digit) or NM's
/// importer rejects the file outright, e.g. "AirVPN_NL-Alblasserdam_…".
pub fn wgImportName(base: []const u8, buf: *[15]u8) []const u8 {
    var n: usize = 0;
    for (base) |ch| {
        if (n >= buf.len) break;
        const c: u8 = if (std.ascii.isAlphanumeric(ch))
            std.ascii.toLower(ch)
        else if (ch == '_' or ch == '-')
            ch
        else
            '_';
        buf[n] = c;
        n += 1;
    }
    if (n == 0) {
        @memcpy(buf[0..8], "wgimport");
        return buf[0..8];
    }
    if (std.ascii.isDigit(buf[0])) {
        if (n < buf.len) {
            var i: usize = n;
            while (i > 0) : (i -= 1) buf[i] = buf[i - 1];
            buf[0] = 'w';
            n += 1;
        } else buf[0] = 'w';
    }
    return buf[0..n];
}

/// Basename without its final extension (what an imported profile is renamed
/// back to).
pub fn baseNoExt(path: []const u8) []const u8 {
    var base = path;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |i| base = base[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base = base[0..i];
    return base;
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.indexOfScalar(u8, t, '\n')) |i| return std.mem.trim(u8, t[0..i], " \t\r");
    return t;
}

/// One `argv`-spawning worker shape shared by every verb below: strings are
/// copied into page memory before the thread starts, and freed by it.
const ArgvArgs = struct {
    io: std.Io,
    argv: [][]u8,
    /// Connection name / subject for the status line; "" = stay silent.
    subject: []u8,
    /// "Added"/"Imported" template selector on success.
    imported: bool,

    fn run(self: *@This()) void {
        const pa = std.heap.page_allocator;
        defer {
            for (self.argv) |a| pa.free(a);
            pa.free(self.argv);
            pa.free(self.subject);
            pa.destroy(self);
        }
        const res = std.process.run(pa, self.io, .{ .argv = self.argv }) catch {
            if (self.subject.len > 0) postStatusFmt("Could not run nmcli for \"{s}\"", .{self.subject});
            return;
        };
        defer pa.free(res.stdout);
        defer pa.free(res.stderr);
        const ok = res.term == .exited and res.term.exited == 0;
        if (ok) {
            if (self.subject.len > 0) {
                if (self.imported) {
                    postStatusFmt("Imported \"{s}\".", .{self.subject});
                } else {
                    postStatusFmt("\"{s}\" added.", .{self.subject});
                }
            }
            return;
        }
        const line = blk: {
            const e = firstLine(res.stderr);
            if (e.len > 0) break :blk e;
            break :blk firstLine(res.stdout);
        };
        if (self.subject.len > 0) {
            if (self.imported) {
                postStatusFmt("Could not import \"{s}\": {s}", .{ self.subject, line });
            } else {
                postStatusFmt("Could not add \"{s}\": {s}", .{ self.subject, line });
            }
        }
    }
};

/// Run `argv` in a detached thread. `subject` "" = fire and forget,
/// otherwise the outcome is posted to the status mailbox.
fn spawnArgv(io: std.Io, argv: []const []const u8, subject: []const u8, imported: bool) void {
    const pa = std.heap.page_allocator;
    const args = pa.create(ArgvArgs) catch return;
    const list = pa.alloc([]u8, argv.len) catch {
        pa.destroy(args);
        return;
    };
    var n: usize = 0;
    while (n < argv.len) : (n += 1) {
        list[n] = pa.dupe(u8, argv[n]) catch break;
    }
    if (n != argv.len) {
        for (list[0..n]) |a| pa.free(a);
        pa.free(list);
        pa.destroy(args);
        return;
    }
    const subject_owned = pa.dupe(u8, subject) catch {
        for (list) |a| pa.free(a);
        pa.free(list);
        pa.destroy(args);
        return;
    };
    args.* = .{
        .io = io,
        .argv = list,
        .subject = subject_owned,
        .imported = imported,
    };
    const t = std.Thread.spawn(.{}, ArgvArgs.run, .{args}) catch {
        for (list) |a| pa.free(a);
        pa.free(list);
        pa.free(args.subject);
        pa.destroy(args);
        return;
    };
    t.detach();
}

/// `setVpnAutoconnect` — the card's auto toggle. Runs through the same
/// serialized verb worker as connect/disconnect so an auto write cannot
/// interleave with a profile update, and reports failure to the page.
pub fn setAutoconnectThread(io: std.Io, uuid: []const u8, enabled: bool) void {
    if (uuid.len == 0) return;
    verbThread(io, uuid, .auto, enabled);
}

/// `addVpnConnection` — plugin-backed types (OpenVPN, strongSwan, L2TP, PPTP,
/// AnyConnect). `data`/`secrets` are "key=value" pairs, joined with commas.
pub const AddVpnParams = struct {
    name: []const u8,
    service_type: []const u8,
    data: []const []const u8 = &.{},
    secrets: []const []const u8 = &.{},
};

fn joinPairs(pa: std.mem.Allocator, pairs: []const []const u8) ?[]u8 {
    var total: usize = 0;
    for (pairs, 0..) |p, i| total += p.len + @as(usize, if (i > 0) 1 else 0);
    const buf = pa.alloc(u8, total) catch return null;
    var off: usize = 0;
    for (pairs, 0..) |p, i| {
        if (i > 0) {
            buf[off] = ',';
            off += 1;
        }
        @memcpy(buf[off .. off + p.len], p);
        off += p.len;
    }
    return buf;
}

pub fn addVpnThread(io: std.Io, params: AddVpnParams) void {
    if (params.name.len == 0 or params.service_type.len == 0) return;
    const pa = std.heap.page_allocator;
    const data_buf: ?[]u8 = if (params.data.len > 0) joinPairs(pa, params.data) else null;
    defer if (data_buf) |b| pa.free(b);
    const sec_buf: ?[]u8 = if (params.secrets.len > 0) joinPairs(pa, params.secrets) else null;
    defer if (sec_buf) |b| pa.free(b);

    var argv: [15][]const u8 = undefined;
    var n: usize = 0;
    argv[n] = "nmcli";
    n += 1;
    argv[n] = "connection";
    n += 1;
    argv[n] = "add";
    n += 1;
    argv[n] = "type";
    n += 1;
    argv[n] = "vpn";
    n += 1;
    argv[n] = "con-name";
    n += 1;
    argv[n] = params.name;
    n += 1;
    argv[n] = "vpn.service-type";
    n += 1;
    argv[n] = params.service_type;
    n += 1;
    argv[n] = "connection.autoconnect";
    n += 1;
    argv[n] = "no";
    n += 1;
    if (data_buf) |b| {
        argv[n] = "vpn.data";
        n += 1;
        argv[n] = b;
        n += 1;
    }
    if (sec_buf) |b| {
        argv[n] = "vpn.secrets";
        n += 1;
        argv[n] = b;
        n += 1;
    }
    spawnArgv(io, argv[0..n], params.name, false);
}

/// WireGuard create fields (`addWireguardConnection`).
pub const WireGuardCfg = struct {
    name: []const u8,
    private_key: []const u8,
    server_public_key: []const u8,
    endpoint: []const u8,
    allowed_ips: []const u8,
    client_ip: []const u8 = "",
    dns: []const u8 = "",
    keepalive: u32 = 25,
};

/// Wall clock in seconds — the same epoch the temp config name uses.
fn epochSeconds() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @intCast(@max(ts.sec, 0));
}

/// `$XDG_RUNTIME_DIR` (or /tmp) — where the 0600 temp configs live.
fn tmpDir(buf: *[256]u8) []const u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0 and s.len < buf.len) {
            @memcpy(buf[0..s.len], s);
            return buf[0..s.len];
        }
    }
    const def = "/tmp";
    @memcpy(buf[0..def.len], def);
    return buf[0..def.len];
}

/// Create a private (0600) file, exclusively; the write is retried to
/// completion. False when the path cannot be created or written.
fn writeFile0600(io: std.Io, path: []const u8, data: []const u8) bool {
    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, flags, 0o600) catch return false;
    var ok = true;
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data[off..].ptr, data.len - off);
        const e = std.os.linux.errno(rc);
        if (e != .SUCCESS) {
            if (e == .INTR) continue;
            ok = false;
            break;
        }
        if (rc == 0) {
            ok = false;
            break;
        }
        off += rc;
    }
    _ = std.os.linux.close(fd);
    if (!ok) std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return ok;
}

/// `nmcli connection import type wireguard file <tmp>` + rename to `wanted`
/// (+ autoconnect off when asked). Answers null on success, else the error
/// text copied into `err_out`.
fn importWireguardOnce(io: std.Io, tmp_path: []const u8, wanted: []const u8, autoconnect_off: bool, err_out: *[256]u8) ?[]const u8 {
    const pa = std.heap.page_allocator;
    const res = std.process.run(pa, io, .{
        .argv = &.{ "nmcli", "connection", "import", "type", "wireguard", "file", tmp_path },
    }) catch {
        return std.fmt.bufPrint(err_out, "nmcli could not be run", .{}) catch err_out;
    };
    defer pa.free(res.stdout);
    defer pa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        const line = blk: {
            const e = firstLine(res.stderr);
            if (e.len > 0) break :blk e;
            break :blk "nmcli import failed";
        };
        return std.fmt.bufPrint(err_out, "{s}", .{line}) catch err_out;
    }
    const added = addedName(res.stdout);
    if (added.len == 0) {
        return std.fmt.bufPrint(err_out, "imported, but the profile name could not be determined", .{}) catch err_out;
    }
    var name_buf: [128]u8 = undefined;
    if (added.len >= name_buf.len) {
        return std.fmt.bufPrint(err_out, "imported profile name is too long", .{}) catch err_out;
    }
    @memcpy(name_buf[0..added.len], added);
    const imported_name = name_buf[0..added.len];
    if (!std.mem.eql(u8, imported_name, wanted)) {
        const rn = std.process.run(pa, io, .{
            .argv = &.{ "nmcli", "connection", "modify", imported_name, "connection.id", wanted },
        }) catch {
            return std.fmt.bufPrint(err_out, "failed to rename connection", .{}) catch err_out;
        };
        defer pa.free(rn.stdout);
        defer pa.free(rn.stderr);
        if (rn.term != .exited or rn.term.exited != 0) {
            if (std.process.run(pa, io, .{
                .argv = &.{ "nmcli", "connection", "delete", imported_name },
            })) |r| {
                pa.free(r.stdout);
                pa.free(r.stderr);
            } else |_| {}
            return std.fmt.bufPrint(err_out, "failed to rename connection", .{}) catch err_out;
        }
    }
    if (autoconnect_off) {
        if (std.process.run(pa, io, .{
            .argv = &.{ "nmcli", "connection", "modify", wanted, "connection.autoconnect", "no" },
        })) |r| {
            pa.free(r.stdout);
            pa.free(r.stderr);
        } else |_| {}
    }
    return null;
}

const WireGuardArgs = struct {
    io: std.Io,
    name: []u8,
    private_key: []u8,
    server_public_key: []u8,
    endpoint: []u8,
    allowed_ips: []u8,
    client_ip: []u8,
    dns: []u8,
    keepalive: u32,

    fn run(self: *@This()) void {
        const pa = std.heap.page_allocator;
        defer {
            pa.free(self.name);
            pa.free(self.private_key);
            pa.free(self.server_public_key);
            pa.free(self.endpoint);
            pa.free(self.allowed_ips);
            pa.free(self.client_ip);
            pa.free(self.dns);
            pa.destroy(self);
        }

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(pa);
        const app = struct {
            fn add(b: *std.ArrayList(u8), s: []const u8) bool {
                b.appendSlice(std.heap.page_allocator, s) catch return false;
                return true;
            }
        };
        var ka_buf: [12]u8 = undefined;
        const ka: []const u8 = std.fmt.bufPrint(&ka_buf, "{d}", .{self.keepalive}) catch "25";
        const ok_build = app.add(&content, "[Interface]\nPrivateKey = ") and
            app.add(&content, self.private_key) and
            app.add(&content, "\n") and
            (self.client_ip.len == 0 or (app.add(&content, "Address = ") and app.add(&content, self.client_ip) and app.add(&content, "\n"))) and
            (self.dns.len == 0 or (app.add(&content, "DNS = ") and app.add(&content, self.dns) and app.add(&content, "\n"))) and
            app.add(&content, "\n[Peer]\nPublicKey = ") and
            app.add(&content, self.server_public_key) and
            app.add(&content, "\nEndpoint = ") and
            app.add(&content, self.endpoint) and
            app.add(&content, "\nAllowedIPs = ") and
            app.add(&content, self.allowed_ips) and
            app.add(&content, "\nPersistentKeepalive = ") and
            app.add(&content, ka) and
            app.add(&content, "\n");
        if (!ok_build) {
            postStatusFmt("Could not build the WireGuard config for \"{s}\"", .{self.name});
            return;
        }

        var dir_buf: [256]u8 = undefined;
        const dir = tmpDir(&dir_buf);
        var path_buf: [320]u8 = undefined;
        const now = epochSeconds();
        const path = std.fmt.bufPrint(&path_buf, "{s}/eh_wg_{d}_{d}.conf", .{ dir, std.os.linux.getpid(), now }) catch {
            postStatusFmt("Cannot create a temporary config for \"{s}\"", .{self.name});
            return;
        };
        if (!writeFile0600(self.io, path, content.items)) {
            postStatusFmt("Cannot write the temporary config for \"{s}\"", .{self.name});
            return;
        }

        var err_buf: [256]u8 = undefined;
        const err = importWireguardOnce(self.io, path, self.name, false, &err_buf);
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        if (err) |e| {
            postStatusFmt("Could not add \"{s}\": {s}", .{ self.name, e });
            return;
        }
        postStatusFmt("\"{s}\" added.", .{self.name});
    }
};

/// `addWireguardConnection` — write the config to a private temp file, import
/// it (the only nmcli path that carries WireGuard peers), rename the profile.
pub fn addWireguardThread(io: std.Io, cfg: WireGuardCfg) void {
    if (cfg.name.len == 0 or cfg.private_key.len == 0 or cfg.server_public_key.len == 0 or
        cfg.endpoint.len == 0 or cfg.allowed_ips.len == 0) return;
    const pa = std.heap.page_allocator;
    const args = pa.create(WireGuardArgs) catch return;
    args.* = .{
        .io = io,
        .name = pa.dupe(u8, cfg.name) catch {
            pa.destroy(args);
            return;
        },
        .private_key = pa.dupe(u8, cfg.private_key) catch {
            pa.free(args.name);
            pa.destroy(args);
            return;
        },
        .server_public_key = "",
        .endpoint = "",
        .allowed_ips = "",
        .client_ip = "",
        .dns = "",
        .keepalive = cfg.keepalive,
    };
    const rest = [_]struct { field: *[]u8, value: []const u8 }{
        .{ .field = &args.server_public_key, .value = cfg.server_public_key },
        .{ .field = &args.endpoint, .value = cfg.endpoint },
        .{ .field = &args.allowed_ips, .value = cfg.allowed_ips },
        .{ .field = &args.client_ip, .value = cfg.client_ip },
        .{ .field = &args.dns, .value = cfg.dns },
    };
    var done: usize = 0;
    const failed = for (rest) |r| {
        r.field.* = pa.dupe(u8, r.value) catch break true;
        done += 1;
    } else false;
    if (failed) {
        pa.free(args.name);
        pa.free(args.private_key);
        for (rest[0..done]) |r| pa.free(r.field.*);
        pa.destroy(args);
        return;
    }
    const t = std.Thread.spawn(.{}, WireGuardArgs.run, .{args}) catch {
        pa.free(args.name);
        pa.free(args.private_key);
        for (rest) |r| pa.free(r.field.*);
        pa.destroy(args);
        return;
    };
    t.detach();
}

const ImportArgs = struct {
    io: std.Io,
    /// Selected source path.
    path: []u8,
    /// Display name for the status line (file basename, extension stripped
    /// for WireGuard — the name the profile is renamed to).
    name: []u8,
    wireguard: bool,

    fn run(self: *@This()) void {
        const pa = std.heap.page_allocator;
        defer {
            pa.free(self.path);
            pa.free(self.name);
            pa.destroy(self);
        }
        if (self.path.len == 0) return;

        var err_buf: [256]u8 = undefined;
        if (self.wireguard) {
            // NM rejects a basename that is not a valid interface name
            // followed by ".conf" — import through a sanitized temp copy,
            // then rename the profile back to the original basename.
            var san_buf: [15]u8 = undefined;
            const san = wgImportName(self.name, &san_buf);
            var dir_buf: [256]u8 = undefined;
            const dir = tmpDir(&dir_buf);
            var path_buf: [320]u8 = undefined;
            const tmp = std.fmt.bufPrint(&path_buf, "{s}/{s}.conf", .{ dir, san }) catch {
                postStatusFmt("Cannot copy the config for \"{s}\"", .{self.name});
                return;
            };
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, pa, .limited(256 * 1024)) catch {
                postStatusFmt("Cannot read \"{s}\"", .{self.path});
                return;
            };
            defer pa.free(data);
            if (!writeFile0600(self.io, tmp, data)) {
                postStatusFmt("Cannot copy the config for \"{s}\"", .{self.name});
                return;
            }
            const err = importWireguardOnce(self.io, tmp, self.name, true, &err_buf);
            std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
            if (err) |e| {
                postStatusFmt("Could not import \"{s}\": {s}", .{ self.name, e });
                return;
            }
            postStatusFmt("Imported \"{s}\".", .{self.name});
            return;
        }

        const res = std.process.run(pa, self.io, .{
            .argv = &.{ "nmcli", "connection", "import", "type", "openvpn", "file", self.path },
        }) catch {
            postStatusFmt("Could not import \"{s}\": nmcli could not be run", .{self.name});
            return;
        };
        defer pa.free(res.stdout);
        defer pa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            const e = firstLine(res.stderr);
            const line = if (e.len > 0) e else "nmcli import failed";
            postStatusFmt("Could not import \"{s}\": {s}", .{ self.name, line });
            return;
        }
        const added = addedName(res.stdout);
        if (added.len > 0) {
            spawnArgv(self.io, &.{
                "nmcli", "connection", "modify", added, "connection.autoconnect", "no",
            }, "", false);
        }
        postStatusFmt("Imported \"{s}\".", .{self.name});
    }
};

/// `importVpnFile` — WireGuard (through the sanitized temp copy) or an
/// OpenVPN profile. The caller runs the file picker; this runs detached.
pub fn importThread(io: std.Io, path: []const u8, wireguard: bool) void {
    if (path.len == 0) return;
    const pa = std.heap.page_allocator;
    const args = pa.create(ImportArgs) catch return;
    args.* = .{
        .io = io,
        .path = pa.dupe(u8, path) catch {
            pa.destroy(args);
            return;
        },
        .name = pa.dupe(u8, baseNoExt(path)) catch {
            pa.free(args.path);
            pa.destroy(args);
            return;
        },
        .wireguard = wireguard,
    };
    const t = std.Thread.spawn(.{}, ImportArgs.run, .{args}) catch {
        pa.free(args.path);
        pa.free(args.name);
        pa.destroy(args);
        return;
    };
    t.detach();
}

// Tests — the parsers are the whole risk; the spawns are argv-shaped

test "live-vpn: uuid-anchored split survives a colon in the name" {
    const t = std.testing;
    const f = splitVpnLine("Work: VPN:12345678-1234-1234-1234-123456789abc:vpn:yes").?;
    try t.expectEqualStrings("Work: VPN", f.name);
    try t.expectEqualStrings("12345678-1234-1234-1234-123456789abc", f.uuid);
    try t.expectEqualStrings("vpn", f.type);
    try t.expectEqualStrings("yes", f.tail);
}

test "live-vpn: tail splits at the first colon only" {
    const t = std.testing;
    const f = splitVpnLine("wg0:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:wireguard:21").?;
    try t.expectEqualStrings("wg0", f.name);
    try t.expectEqualStrings("wireguard", f.type);
    try t.expectEqualStrings("21", f.tail);
    // No tail at all (a bare NAME:UUID:TYPE line).
    const g = splitVpnLine("tun0:11111111-2222-3333-4444-555555555555:vpn").?;
    try t.expectEqualStrings("", g.tail);
    try t.expect(splitVpnLine("not-a-uuid line") == null);
}

test "live-vpn: activation takes every other live VPN down" {
    const t = std.testing;
    const doc =
        \\home:12345678-1234-1234-1234-123456789abc:802-3-ethernet:activated
        \\Work VPN:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:vpn:activated
        \\wg0:99999999-8888-7777-6666-555555555555:wireguard:activated
    ;
    const others = try otherActiveVpnUuids(t.allocator, doc, "99999999-8888-7777-6666-555555555555");
    defer t.allocator.free(others);
    try t.expectEqual(@as(usize, 1), others.len);
    try t.expectEqualStrings("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", others[0]);
}

test "live-vpn: saved-list parse filters types and marks actives" {
    const t = std.testing;
    const doc =
        \\home:12345678-1234-1234-1234-123456789abc:802-3-ethernet:yes
        \\Work VPN:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:vpn:no
        \\wg0:99999999-8888-7777-6666-555555555555:wireguard:yes
        \\dead:beef
    ;
    const actives = [_][]const u8{"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"};
    const conns = try parseNmcli(t.allocator, doc, &actives, true);
    defer freeConnections(t.allocator, conns);
    try t.expectEqual(@as(usize, 2), conns.len);
    try t.expectEqualStrings("Work VPN", conns[0].name);
    try t.expect(conns[0].active);
    try t.expect(!conns[0].autoconnect);
    try t.expectEqualStrings("wg0", conns[1].name);
    try t.expect(!conns[1].active);
    try t.expect(conns[1].autoconnect);
}

test "live-vpn: rows keep name order when one connects" {
    const t = std.testing;
    var conns = [_]Connection{
        .{ .uuid = "bbbbbbbb-1111-2222-3333-444444444444", .name = "alpha", .active = false },
        .{ .uuid = "aaaaaaaa-1111-2222-3333-444444444444", .name = "zulu", .active = true },
    };
    sortConnections(&conns);
    try t.expectEqualStrings("alpha", conns[0].name);
    try t.expectEqualStrings("zulu", conns[1].name);
    // Equal names still have a deterministic order.
    var same = [_]Connection{
        .{ .uuid = "bbbbbbbb-1111-2222-3333-444444444444", .name = "same" },
        .{ .uuid = "aaaaaaaa-1111-2222-3333-444444444444", .name = "same" },
    };
    sortConnections(&same);
    try t.expectEqualStrings("aaaaaaaa-1111-2222-3333-444444444444", same[0].uuid);
}

test "live-vpn: wireguard import names are interface-shaped" {
    const t = std.testing;
    var buf: [15]u8 = undefined;
    try t.expectEqualStrings("airvpn_nl-albla", wgImportName("AirVPN_NL-Alblasserdam_Dalim_UDP-1637-Entry3", &buf));
    try t.expectEqualStrings("wgimport", wgImportName("", &buf));
    try t.expectEqualStrings("w123", wgImportName("123", &buf));
    // 15 chars already: the digit is replaced, not prefixed.
    try t.expectEqualStrings("w23456789012345", wgImportName("123456789012345", &buf));
    try t.expectEqualStrings("a_b_c-d", wgImportName("a b.c-d", &buf));
}

test "live-vpn: addedName reads the imported profile" {
    const t = std.testing;
    const doc = "Connection 'work_vpn' (12345678-1234-1234-1234-123456789abc) successfully added.";
    try t.expectEqualStrings("work_vpn", addedName(doc));
    try t.expectEqualStrings("", addedName("no marker here"));
}

test "live-vpn: baseNoExt strips directory and final extension" {
    const t = std.testing;
    try t.expectEqualStrings("AirVPN_NL", baseNoExt("/home/u/conf/AirVPN_NL.conf"));
    try t.expectEqualStrings("foo.tar", baseNoExt("foo.tar.conf"));
    try t.expectEqualStrings("plain", baseNoExt("plain"));
}

test "live-vpn: an active read without a tail marks nothing autoconnect" {
    const t = std.testing;
    const doc = "up:12345678-1234-1234-1234-123456789abc:vpn:activated";
    const conns = try parseNmcli(t.allocator, doc, null, false);
    defer freeConnections(t.allocator, conns);
    try t.expectEqual(@as(usize, 1), conns.len);
    try t.expect(!conns[0].active);
    try t.expect(!conns[0].autoconnect);
}
