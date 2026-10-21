//! Live VPN connections behind the dock/panel VPN card: read from
//! NetworkManager through `nmcli`, written back through `nmcli`.
//!
//! VPN half: refresh, activate, deactivate,
//! remove. A worker thread with a
//! periodic refresh; here the dock owns the poll and the card is the only
//! consumer, so the two `nmcli` reads run on the caller's thread behind the
//! dock's own throttle, and every *write* runs in a detached thread — a VPN
//! that takes 10 s to come up must never stall the Wayland loop.
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
/// selects what the fourth field means: the active read prints STATE, the
/// saved read AUTOCONNECT.
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
        try out.append(alloc, .{
            .uuid = try alloc.dupe(u8, f.uuid),
            .name = try alloc.dupe(u8, f.name),
            .autoconnect = tail_is_autoconnect and std.mem.eql(u8, f.tail, "yes"),
            .active = active,
        });
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeConnections(alloc: std.mem.Allocator, conns: []Connection) void {
    for (conns) |*c| {
        alloc.free(c.uuid);
        alloc.free(c.name);
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

/// `do_refresh_vpn`: the active list first (its uuids mark the saved list),
/// then the saved list itself. Active-first, then by name — the card's row
/// order. Null when nmcli is missing or either read failed; the caller keeps
/// what it had.
pub fn query(alloc: std.mem.Allocator, io: std.Io) ?[]Connection {
    const active_text = runNmcli(io, &.{
        "nmcli", "-t", "-f", "NAME,UUID,TYPE,STATE", "connection", "show", "--active",
    }) orelse return null;
    defer std.heap.page_allocator.free(active_text);

    // uuids of live VPN/WireGuard rows, page-allocated: this is a lookup
    // table that dies with the function, never handed out.
    var active_uuids = std.ArrayList([]const u8).empty;
    defer {
        for (active_uuids.items) |u| std.heap.page_allocator.free(u);
        active_uuids.deinit(std.heap.page_allocator);
    }
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
            };
        }
    }

    const all_text = runNmcli(io, &.{
        "nmcli", "-t", "-f", "NAME,UUID,TYPE,AUTOCONNECT", "connection", "show",
    }) orelse return null;
    defer std.heap.page_allocator.free(all_text);

    const conns = parseNmcli(alloc, all_text, active_uuids.items, true) catch return null;
    // Sort on active-then-name.
    std.mem.sort(Connection, conns, {}, struct {
        fn lt(_: void, a: Connection, b: Connection) bool {
            if (a.active != b.active) return a.active;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return conns;
}

// Verbs — every one in a detached thread, page allocator only

const VerbKind = enum { up, down, delete };

const VerbArgs = struct {
    io: std.Io,
    uuid: []u8,
    kind: VerbKind,

    fn run(self: *VerbArgs) void {
        const pa = std.heap.page_allocator;
        defer pa.free(self.uuid);
        defer pa.destroy(self);
        switch (self.kind) {
            // Activate the connection.
            .up => _ = runNmcli(self.io, &.{ "nmcli", "connection", "up", "uuid", self.uuid }),
            // `deactivateVpnConnection`: down, then autoconnect off — a
            // manual disconnect must stick, or NM re-dials the VPN the
            // moment it is taken down.
            .down => {
                _ = runNmcli(self.io, &.{ "nmcli", "connection", "down", "uuid", self.uuid });
                _ = runNmcli(self.io, &.{ "nmcli", "connection", "modify", "uuid", self.uuid, "connection.autoconnect", "no" });
            },
            // `removeVpnConnection`.
            .delete => _ = runNmcli(self.io, &.{ "nmcli", "connection", "delete", "uuid", self.uuid }),
        }
    }
};

fn verbThread(io: std.Io, uuid: []const u8, kind: VerbKind) void {
    const pa = std.heap.page_allocator;
    const args = pa.create(VerbArgs) catch return;
    args.* = .{
        .io = io,
        .uuid = pa.dupe(u8, uuid) catch {
            pa.destroy(args);
            return;
        },
        .kind = kind,
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
    verbThread(io, uuid, .up);
}

pub fn deactivateThread(io: std.Io, uuid: []const u8) void {
    if (uuid.len == 0) return;
    verbThread(io, uuid, .down);
}

pub fn removeThread(io: std.Io, uuid: []const u8) void {
    if (uuid.len == 0) return;
    verbThread(io, uuid, .delete);
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

test "live-vpn: an active read without a tail marks nothing autoconnect" {
    const t = std.testing;
    const doc = "up:12345678-1234-1234-1234-123456789abc:vpn:activated";
    const conns = try parseNmcli(t.allocator, doc, null, false);
    defer freeConnections(t.allocator, conns);
    try t.expectEqual(@as(usize, 1), conns.len);
    try t.expect(!conns[0].active);
    try t.expect(!conns[0].autoconnect);
}
