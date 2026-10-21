//! The volume-mixer card's data path: one worker that reads PipeWire through
//! the same CLI tools `cc_live_audio` uses and lands a single owned snapshot
//! for the card — the device and stream tables, per-stream routing off a
//! `pw-link` blob, the footer's engine/DSP readouts and the card profiles
//! behind the master and per-stream dropdowns.
//!
//! The card is a wall of subprocess reads (`wpctl status`, one `wpctl inspect`
//! per node, `pw-link -l`, `pw-top -b -n 2`): tens of milliseconds with a
//! handful of apps playing, which is an input stall on the thread that also
//! dispatches clicks. So the reads run on a worker exactly the way
//! `live_vpn`'s `nmcli` read does — `request` starts one, `take` adopts what
//! landed, and the host owns the cadence.
//!
//! Everything the card draws is borrowed from one arena per landing: the
//! paint reads `Data.snap` while the next read builds its own copy beside it,
//! and `Data.deinit` drops the lot in one call.

const std = @import("std");
const live = @import("live.zig");
const live_audio = @import("live_audio.zig");
const mixer = @import("../widgets/volume_mixer.zig");

/// One finished read. Every string and row below is borrowed from `arena`,
/// so the host can hold this while the next read builds its own copy and a
/// single `deinit` releases everything.
pub const Data = struct {
    /// The allocator the arena was made with — the one that owns `self`.
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// A backend answered. Without it the card draws its empty state rather
    /// than a stale one: "the server went away" has to be visible.
    ok: bool = false,
    snap: mixer.Snapshot = .{},
    cards: []mixer.CardProfiles = &.{},
    engine: mixer.EngineSettings = .{},
    top: mixer.TopSample = .{},

    pub fn deinit(self: *Data) void {
        const alloc = self.alloc;
        self.arena.deinit();
        alloc.destroy(self);
    }
};

const kIdle: u8 = 0;
const kRunning: u8 = 1;
const kReady: u8 = 2;

var phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(kIdle);
/// What a finished read published, written before the release store that
/// marks it ready and read after the matching acquire — the phase machine is
/// the whole hand-off, as it is in `live_vpn` and `services/weather.zig`.
var landed: ?*Data = null;
var worker: ?std.Thread = null;

/// True when no read is in flight, i.e. `request` would start one.
pub fn idle() bool {
    return phase.load(.acquire) == kIdle;
}

/// Start a read unless one is already running. The host owns the deadline,
/// so a spawn that failed once cannot be retried in a tight loop.
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

/// Move a finished read into `out`; the caller owns it outright and frees it
/// with `Data.deinit`. False when nothing has landed.
pub fn take(out: *?*Data) bool {
    if (phase.load(.acquire) != kReady) return false;
    out.* = landed.?;
    landed = null;
    phase.store(kIdle, .release);
    return true;
}

/// Drain the worker and drop whatever it published. Called on teardown —
/// and therefore *before* the allocator the worker is borrowing goes away —
/// and by tests that need a clean slate.
pub fn shutdown() void {
    if (worker) |w| {
        w.join();
        worker = null;
    }
    if (landed) |d| {
        d.deinit();
        landed = null;
    }
    phase.store(kIdle, .release);
}

const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,

    fn run(self: *Job) void {
        defer self.alloc.destroy(self);
        // A build that cannot even allocate publishes nothing: there is no
        // reading to adopt, and the host's retry deadline covers it.
        const data = build(self.alloc, self.io) orelse {
            phase.store(kIdle, .release);
            return;
        };
        landed = data;
        phase.store(kReady, .release);
    }
};

// The build: query, then the enrichments only this card needs

fn build(alloc: std.mem.Allocator, io: std.Io) ?*Data {
    const d = alloc.create(Data) catch return null;
    d.* = .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc) };
    const a = d.arena.allocator();
    var q = live_audio.query(a, io, false) orelse return d;
    d.ok = q.snap.have_server;
    if (!d.ok) return d;
    // `wpctl status` prints no level for stream rows, and the shared query's
    // detail pass stops at four of them ("the mixer shows at most four") —
    // this card paints every row, so it runs its own uncapped pass.
    if (q.status_text != null) streamLevels(a, io, &q);
    const blob = live_audio.capturePwLinkBlob(a, io);
    d.snap = buildSnapshot(a, io, &q, blob);
    d.cards = buildCards(a, io);
    d.engine = mapEngine(live_audio.queryEngineSettings(a, io));
    d.top = mapTop(live_audio.queryPwTop(a, io));
    return d;
}

fn mapEngine(e: live_audio.EngineSettings) mixer.EngineSettings {
    return .{
        .available = e.available,
        .clock_rate_hz = e.clock_rate_hz,
        .clock_force_rate_hz = e.clock_force_rate_hz,
        .clock_quantum = e.clock_quantum,
        .clock_force_quantum = e.clock_force_quantum,
    };
}

fn mapTop(t: live_audio.PwTopSample) mixer.TopSample {
    return .{
        .available = t.available,
        .dsp_load_pct = t.dsp_load_pct,
        .xruns_total = t.xruns_total,
    };
}

/// `wpctl get-volume <id>` for every stream row. Same spawn as the shared
/// query's detail pass, minus its four-row cap.
fn streamLevels(alloc: std.mem.Allocator, io: std.Io, q: *live_audio.Queried) void {
    for (q.out_stream_list.items) |*s| {
        var buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "{d}", .{s.id}) catch continue;
        const t = live.runCapture(alloc, io, &.{ "wpctl", "get-volume", id }) orelse continue;
        const p = live_audio.parseWpctlVolume(t);
        if (p >= 0) s.volume_pct = p;
        s.muted = live_audio.parseWpctlMuted(t);
    }
}

fn buildSnapshot(
    alloc: std.mem.Allocator,
    io: std.Io,
    q: *live_audio.Queried,
    blob: ?[]const u8,
) mixer.Snapshot {
    // The pactl path carries pactl sink names — which is what the blob names
    // nodes by, so routing resolves straight off `raw_name`. The wpctl path
    // prints a numeric id there and hides the `node.name` one inspect away,
    // which is why its devices are looked up.
    const wpctl_path = q.status_text != null;
    const sinks = buildDevices(alloc, io, q.sink_list.items, wpctl_path);
    const sources = buildDevices(alloc, io, q.source_list.items, wpctl_path);
    return .{
        .sinks = sinks.rows,
        .sources = sources.rows,
        .out_streams = buildStreams(alloc, io, q.out_stream_list.items, blob, false, sinks),
        .in_streams = buildStreams(alloc, io, q.in_stream_list.items, blob, true, sources),
    };
}

/// A device table plus the `node.name` each row answers to. The blob (and
/// therefore `routed_raw`) speaks node names, which on the wpctl path are
/// neither the row's name nor its raw name — so they ride beside the rows
/// until the route display is worked out.
const DevTab = struct {
    rows: []const mixer.DeviceInfo = &.{},
    nodes: []const []const u8 = &.{},
};

fn buildDevices(
    alloc: std.mem.Allocator,
    io: std.Io,
    devs: []const live_audio.Device,
    wpctl_path: bool,
) DevTab {
    if (devs.len == 0) return .{};
    const rows = alloc.alloc(mixer.DeviceInfo, devs.len) catch return .{};
    const nodes = alloc.alloc([]const u8, devs.len) catch {
        alloc.free(rows);
        return .{};
    };
    for (devs, 0..) |d, i| {
        var node = d.name;
        var label = d.description;
        if (wpctl_path) {
            // `Device.name` is the numeric node id on this path; `wpctl
            // set-default` takes exactly that, so it stays `raw_name`.
            const m = inspectNode(alloc, io, @intCast(d.id));
            if (m.node.len > 0) node = m.node;
            if (label.len == 0) label = if (m.desc.len > 0) m.desc else m.node;
        }
        if (label.len == 0) label = d.name;
        rows[i] = .{
            .node_id = d.id,
            .name = label,
            .raw_name = d.name,
            .is_default = d.is_default,
            .muted = d.muted,
            .volume_pct = d.volume_pct,
        };
        nodes[i] = node;
    }
    return .{ .rows = rows, .nodes = nodes };
}

fn buildStreams(
    alloc: std.mem.Allocator,
    io: std.Io,
    streams: []const live_audio.Stream,
    blob: ?[]const u8,
    is_input: bool,
    devs: DevTab,
) []mixer.StreamInfo {
    if (streams.len == 0) return &.{};
    const out = alloc.alloc(mixer.StreamInfo, streams.len) catch return &.{};
    for (streams, 0..) |s, i| {
        const m = inspectNode(alloc, io, s.id);
        const node = m.node;
        const desc = if (m.media.len > 0) m.media else m.desc;
        const app_name = if (s.app_name.len > 0) s.app_name else if (m.app.len > 0) m.app else node;
        const icon = if (s.icon_name.len > 0) s.icon_name else m.icon;
        const app_id = if (s.app_id.len > 0) s.app_id else m.app_id;
        const bin = if (s.process_binary.len > 0) s.process_binary else m.bin;
        // The desktop-entry step needs a lookup the worker
        // cannot reach (the theme lives on the frame thread); everything it
        // could add rides in the raw fields above, and the widget's own
        // fallbacks pick from them.
        const fallback = mixer.ResolvedName{ .app_name = app_name, .icon_name = icon };
        const r = mixer.resolveStreamDisplay(alloc, app_name, icon, app_id, bin, node, desc, null) catch fallback;
        const routed: []const u8 = if (blob) |b|
            if (is_input) mixer.captureSourceForStream(b, node)
            else mixer.playbackSinkForStream(b, node)
        else
            "";
        out[i] = .{
            .node_id = if (s.id > 0) @intCast(s.id) else 0,
            .volume_pct = s.volume_pct,
            .muted = s.muted,
            .app_name = r.app_name,
            .icon_name = r.icon_name,
            .app_id = app_id,
            .process_binary = bin,
            .node_name = node,
            .description = desc,
            .routed_raw = routed,
            .routed_display = if (routed.len > 0) routeDisplay(routed, devs) else "",
        };
    }
    return out;
}

/// `sink_display` / `source_display`: the counterpart's
/// friendly name when the blob's node is in the table, the blob's own name
/// when it is not (a monitor, a hidden filter). The empty route — no link
/// found at all — is left to the widget, which calls it "Default output".
fn routeDisplay(raw: []const u8, devs: DevTab) []const u8 {
    for (devs.nodes, devs.rows) |n, *d| {
        if (n.len > 0 and std.mem.eql(u8, n, raw)) return d.name;
    }
    for (devs.rows) |d| {
        if (d.raw_name.len > 0 and std.mem.eql(u8, d.raw_name, raw)) return d.name;
    }
    return raw;
}

fn buildCards(alloc: std.mem.Allocator, io: std.Io) []mixer.CardProfiles {
    const list = live_audio.queryAudioCards(alloc, io, false) catch return &.{};
    if (list.len == 0) return &.{};
    const out = alloc.alloc(mixer.CardProfiles, list.len) catch return &.{};
    for (list, 0..) |c, i| {
        const profs = alloc.alloc(mixer.CardProfile, c.profiles.len) catch {
            out[i] = .{};
            continue;
        };
        for (c.profiles, 0..) |p, j| {
            profs[j] = .{ .key = p.key, .description = p.description };
        }
        out[i] = .{
            .card_index = c.card_index,
            .card_key = c.card_key,
            .profiles = profs,
            .active_profile_key = c.active_profile_key,
        };
    }
    return out;
}

// `wpctl inspect` — the one spawn per node that makes routing possible

const Meta = struct {
    node: []const u8 = "",
    desc: []const u8 = "",
    media: []const u8 = "",
    app: []const u8 = "",
    app_id: []const u8 = "",
    bin: []const u8 = "",
    icon: []const u8 = "",
};

/// The handful of `key = "value"` lines a mixer row needs out of
/// `wpctl inspect <id>`. The leading `*` marks the value PipeWire took from
/// that node; everything before it (the id/type header, the box art) is not
/// a property line at all.
fn inspectMeta(text: []const u8) Meta {
    var m: Meta = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '*') line = std.mem.trimStart(u8, line[1..], " \t");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val = val[1 .. val.len - 1];
        if (std.mem.eql(u8, key, "node.name")) m.node = val
        else if (std.mem.eql(u8, key, "node.description")) m.desc = val
        else if (std.mem.eql(u8, key, "media.name")) m.media = val
        else if (std.mem.eql(u8, key, "application.name")) m.app = val
        else if (std.mem.eql(u8, key, "application.id")) m.app_id = val
        else if (std.mem.eql(u8, key, "application.process.binary")) m.bin = val
        else if (std.mem.eql(u8, key, "application.icon-name")) m.icon = val;
    }
    return m;
}

/// One node's properties. The capture stays in the landing's arena, since
/// everything `Meta` returns borrows from it.
fn inspectNode(alloc: std.mem.Allocator, io: std.Io, id: i32) Meta {
    if (id <= 0) return .{};
    var buf: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&buf, "{d}", .{id}) catch return .{};
    const text = live.runCapture(alloc, io, &.{ "wpctl", "inspect", ids }) orelse return .{};
    return inspectMeta(text);
}

// Tests — the parsers are the whole risk; the spawns are argv-shaped

test "live-mixer: inspect meta picks the lines a row needs" {
    const t = std.testing;
    const doc =
        \\id 113, type PipeWire:Interface:Node
        \\    adapt.follower.spa-node = ""
        \\  * application.name = "vesktop"
        \\    application.process.binary = "vesktop"
        \\  * media.name = "Playback"
        \\    node.description = "Vesktop audio"
        \\  * node.name = "vesktop"
        \\    application.icon-name = "vesktop"
        \\    application.id = "vesktop"
    ;
    const m = inspectMeta(doc);
    try t.expectEqualStrings("vesktop", m.node);
    try t.expectEqualStrings("Playback", m.media);
    try t.expectEqualStrings("vesktop", m.app);
    try t.expectEqualStrings("vesktop", m.app_id);
    try t.expectEqualStrings("vesktop", m.bin);
    try t.expectEqualStrings("vesktop", m.icon);
    try t.expectEqualStrings("Vesktop audio", m.desc);
}

test "live-mixer: inspect meta ignores headers and empty output" {
    const t = std.testing;
    try t.expectEqualStrings("", inspectMeta("").node);
    const m = inspectMeta("id 4, type PipeWire:Interface:Node\n");
    try t.expectEqualStrings("", m.node);
    // Unquoted values survive too.
    try t.expectEqualStrings("x", inspectMeta("node.name = x").node);
}

test "live-mixer: route display prefers the table, falls back to the blob" {
    const t = std.testing;
    const devs = DevTab{
        .rows = &[_]mixer.DeviceInfo{
            .{ .node_id = 1, .name = "Speakers", .raw_name = "97" },
            .{ .node_id = 2, .name = "HDMI", .raw_name = "53" },
        },
        .nodes = &[_][]const u8{ "bluez_output.A8_99.1", "alsa_output.pci-0000_01_00.1" },
    };
    try t.expectEqualStrings("Speakers", routeDisplay("bluez_output.A8_99.1", devs));
    // A raw name match still resolves when the node name was never read.
    try t.expectEqualStrings("HDMI", routeDisplay("53", devs));
    // Unknown counterpart: the blob's own name.
    try t.expectEqualStrings("alsa_output.other", routeDisplay("alsa_output.other", devs));
    try t.expectEqualStrings("", routeDisplay("", devs));
}
