//! Live audio behind the control-center cards: query + set through
//! `pactl` (PulseAudio-compat, present on PipeWire systems), with `wpctl`
//! as the full fallback — not just for the two default volumes but for the
//! device and stream tables too. Without that second half a `pactl`-less
//! box renders an empty output/input dropdown and an empty mixer, because
//! `pactl list sinks|sources|sink-inputs` is what feeds them. On that path
//! the source rows come from one `pw-dump`: the `wpctl status` `Sources:`
//! table hides filter-chain mics under `Filters:` and lists raw
//! `Audio/Source/Internal` nodes that `set-default` refuses.
//!
//! Parsing is pure and fixture-tested; only `query`/`set*` spawn. Any
//! failure (no server, no tool) returns `null`/`false` and the dock keeps
//! its cached snapshot — the cards still move under the pointer via the
//! suppress-window state.
//!
//! `query`'s `detail` flag gates the per-stream `wpctl get-volume` spawns
//! (one each): the pill poll runs every second with the popup closed and
//! only needs the defaults, while the open mixer needs every row's level.

const std = @import("std");
const live = @import("live.zig");

pub const Device = struct {
    id: u32 = 0,
    name: []const u8 = "",
    description: []const u8 = "",
    volume_pct: i32 = 100,
    muted: bool = false,
    is_default: bool = false,
};

pub const Stream = struct {
    id: i32 = -1,
    app_name: []const u8 = "",
    icon_name: []const u8 = "",
    app_id: []const u8 = "",
    process_binary: []const u8 = "",
    /// `node.description` off `wpctl inspect` — the last identity tried
    /// before the raw application name stands.
    description: []const u8 = "",
    /// `node.name` — the stream-side key the Sound page's route combos
    /// match against the `pw-link -l` blob (`volume_mixer.playbackSinkForStream`
    /// / `captureSourceForStream`).
    node_name: []const u8 = "",
    volume_pct: i32 = 100,
    muted: bool = false,
};

pub const Snapshot = struct {
    have_server: bool = false,
    out: Device = .{},
    in: Device = .{},
    sinks: []const Device = &.{},
    sources: []const Device = &.{},
    out_streams: []const Stream = &.{},
    in_streams: []const Stream = &.{},
};

/// First `NN%` in `s` (pactl prints one per channel; they agree). -1 when
/// absent.
pub fn firstPct(s: []const u8) i32 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') continue;
        var j = i;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {}
        if (j < s.len and s[j] == '%') {
            return std.fmt.parseInt(i32, s[i..j], 10) catch -1;
        }
        i = j;
    }
    return -1;
}

pub fn parseMute(s: []const u8) bool {
    // "Mute: yes" / "Mute: no" (case-insensitive, trailing whitespace ok).
    if (std.ascii.indexOfIgnoreCase(s, "mute: yes") != null) return true;
    return false;
}

/// `wpctl get-volume` prints `Volume: 0.80`. Returns 0..100, -1 when absent.
pub fn parseWpctlVolume(s: []const u8) i32 {
    const idx = std.mem.indexOf(u8, s, "Volume:") orelse return -1;
    const rest = std.mem.trim(u8, s[idx + 7 ..], " \t");
    var end: usize = 0;
    while (end < rest.len and (rest[end] == '.' or (rest[end] >= '0' and rest[end] <= '9'))) : (end += 1) {}
    if (end == 0) return -1;
    const f = std.fmt.parseFloat(f64, rest[0..end]) catch return -1;
    return @intFromFloat(@round(f * 100.0));
}

/// `wpctl get-volume` prints `Volume: 0.80 [MUTED]` and `wpctl status`
/// prints ` [vol: 1.00] [MUTED]` when the node is muted.
pub fn parseWpctlMuted(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "[MUTED]") != null;
}

fn trimLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Parse one `pactl list sinks|sources` dump into `out`. Block headers look
/// like `Sink #46`; fields are `Key: value`. `default_name` marks the
/// default. Strings borrow from `text`, so the caller must keep it alive
/// (the dock moves them into the host arena right after).
pub fn parseDeviceList(text: []const u8, want_sink: bool, default_name: []const u8, out: *std.ArrayList(Device), alloc: std.mem.Allocator) void {
    var cur: ?Device = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0) {
            if (cur) |d| {
                out.append(alloc, d) catch {};
                cur = null;
            }
            continue;
        }
        const is_header = (want_sink and std.mem.startsWith(u8, line, "Sink #")) or
            (!want_sink and std.mem.startsWith(u8, line, "Source #"));
        if (is_header) {
            if (cur) |d| out.append(alloc, d) catch {};
            const hash = std.mem.indexOfScalar(u8, line, '#') orelse continue;
            const id = std.fmt.parseInt(u32, trimLine(line[hash + 1 ..]), 10) catch 0;
            cur = .{ .id = id };
            continue;
        }
        // A foreign block (e.g. "Source #.." inside a sinks dump) ends ours.
        if (std.mem.startsWith(u8, line, "Sink #") or std.mem.startsWith(u8, line, "Source #") or
            std.mem.startsWith(u8, line, "Sink Input #") or std.mem.startsWith(u8, line, "Source Output #"))
        {
            if (cur) |d| {
                out.append(alloc, d) catch {};
                cur = null;
            }
            continue;
        }
        if (cur == null) continue;
        if (std.mem.startsWith(u8, line, "Name:")) {
            cur.?.name = trimLine(line[5..]);
        } else if (std.mem.startsWith(u8, line, "Description:")) {
            cur.?.description = trimLine(line[12..]);
        } else if (std.mem.startsWith(u8, line, "Volume:")) {
            const p = firstPct(line);
            if (p >= 0) cur.?.volume_pct = p;
        } else if (std.mem.startsWith(u8, line, "Mute:")) {
            cur.?.muted = parseMute(line);
        }
    }
    if (cur) |d| out.append(alloc, d) catch {};
    for (out.items) |*d| {
        if (d.name.len > 0 and std.mem.eql(u8, d.name, default_name)) d.is_default = true;
    }
    // No name matched (older pactl without get-default-*): first device wins,
    // mirroring the "first sink is default" fallback.
    if (default_name.len == 0) {
        var marked = false;
        for (out.items) |*d| {
            if (!marked) {
                d.is_default = true;
                marked = true;
            }
        }
    }
}

fn propVal(block_line: []const u8, key: []const u8) []const u8 {
    // `\t\tapplication.name = "foo"` (quotes optional in the wild).
    const line = trimLine(block_line);
    if (!std.mem.startsWith(u8, line, key)) return "";
    const rest = trimLine(line[key.len..]);
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return "";
    var v = trimLine(rest[eq + 1 ..]);
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
    return v;
}

/// Parse `pactl list sink-inputs|source-outputs`. `want_input` selects the
/// `Source Output #` header.
pub fn parseStreamList(text: []const u8, want_input: bool, out: *std.ArrayList(Stream), alloc: std.mem.Allocator) void {
    var cur: ?Stream = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0) {
            if (cur) |s| {
                if (s.app_name.len == 0) {
                    var named = s;
                    named.app_name = "Unknown App";
                    out.append(alloc, named) catch {};
                } else out.append(alloc, s) catch {};
                cur = null;
            }
            continue;
        }
        const is_header = (!want_input and std.mem.startsWith(u8, line, "Sink Input #")) or
            (want_input and std.mem.startsWith(u8, line, "Source Output #"));
        if (is_header) {
            if (cur) |s| out.append(alloc, s) catch {};
            const hash = std.mem.indexOfScalar(u8, line, '#') orelse continue;
            const id = std.fmt.parseInt(i32, trimLine(line[hash + 1 ..]), 10) catch -1;
            cur = .{ .id = id };
            continue;
        }
        if (cur == null) continue;
        if (std.mem.startsWith(u8, line, "Volume:")) {
            const p = firstPct(line);
            if (p >= 0) cur.?.volume_pct = p;
        } else if (std.mem.startsWith(u8, line, "Mute:")) {
            cur.?.muted = parseMute(line);
        } else if (propVal(line, "application.name").len > 0) {
            cur.?.app_name = propVal(line, "application.name");
        } else if (propVal(line, "application.icon_name").len > 0) {
            cur.?.icon_name = propVal(line, "application.icon_name");
        } else if (propVal(line, "application.id").len > 0) {
            cur.?.app_id = propVal(line, "application.id");
        } else if (propVal(line, "application.process.binary").len > 0) {
            cur.?.process_binary = propVal(line, "application.process.binary");
        } else if (propVal(line, "node.name").len > 0) {
            cur.?.node_name = propVal(line, "node.name");
        }
    }
    if (cur) |s| {
        if (s.app_name.len == 0) {
            var named = s;
            named.app_name = "Unknown App";
            out.append(alloc, named) catch {};
        } else out.append(alloc, s) catch {};
    }
}

/// Full query. `detail` fetches each stream's level (one spawn per row) for
/// the mixer; the pill poll runs every second with the popup closed and only
/// needs the defaults. Returns `null` when no audio server answers — the dock
/// then keeps its cache. All strings borrow from an internal buffer the
/// caller must free with `free`.
pub fn query(alloc: std.mem.Allocator, io: std.Io, detail: bool) ?Queried {
    var q = Queried.init(alloc);
    errdefer q.deinit();
    // No fork when pactl is absent (see toolPath): the exec-failed probe
    // children are never reaped, so a missing binary would leak two zombies
    // per poll until PID exhaustion.
    var pbuf: [64]u8 = undefined;
    const pactl_exe = toolPath(&pbuf, "pactl");
    const def_sink = if (pactl_exe) |exe| live.runCapture(alloc, io, &.{ exe, "get-default-sink" }) else null;
    defer if (def_sink) |s| alloc.free(s);
    const def_source = if (pactl_exe) |exe| live.runCapture(alloc, io, &.{ exe, "get-default-source" }) else null;
    defer if (def_source) |s| alloc.free(s);
    if (def_sink == null and def_source == null) {
        if (!queryWpctl(&q, alloc, io, detail)) return null;
        return q;
    }
    // At least one pactl probe answered, so the binary exists.
    const exe = pactl_exe.?;
    q.snap.have_server = true;
    const sinks_text = live.runCapture(alloc, io, &.{ exe, "list", "sinks" });
    defer if (sinks_text) |s| alloc.free(s);
    const sources_text = live.runCapture(alloc, io, &.{ exe, "list", "sources" });
    defer if (sources_text) |s| alloc.free(s);
    const in_text = live.runCapture(alloc, io, &.{ exe, "list", "sink-inputs" });
    defer if (in_text) |s| alloc.free(s);
    const out_text = live.runCapture(alloc, io, &.{ exe, "list", "source-outputs" });
    defer if (out_text) |s| alloc.free(s);
    // Keep raw texts alive inside Queried; parsed slices borrow them.
    q.sinks_text = sinks_text;
    q.sources_text = sources_text;
    q.in_text = in_text;
    q.out_text = out_text;
    const ds = if (def_sink) |s| trimLine(s) else "";
    const dso = if (def_source) |s| trimLine(s) else "";
    if (sinks_text) |t| parseDeviceList(t, true, ds, &q.sink_list, alloc);
    if (sources_text) |t| parseDeviceList(t, false, dso, &q.source_list, alloc);
    if (in_text) |t| parseStreamList(t, false, &q.out_stream_list, alloc);
    if (out_text) |t| parseStreamList(t, true, &q.in_stream_list, alloc);
    q.snap.sinks = q.sink_list.items;
    q.snap.sources = q.source_list.items;
    q.snap.out_streams = q.out_stream_list.items;
    q.snap.in_streams = q.in_stream_list.items;
    q.snap.out = pickDefault(q.snap.sinks);
    q.snap.in = pickDefault(q.snap.sources);
    return q;
}

/// `pactl`-less path. One `wpctl status` carries the whole table — the sink
/// and source ids (which is what `wpctl set-default` takes), friendly names,
/// the `*` default marker and each node's level — plus the stream rows the
/// mixer needs. Without it a `pactl`-less box renders an empty device
/// dropdown and an empty mixer, because `pactl list …` is what feeds them.
fn queryWpctl(q: *Queried, alloc: std.mem.Allocator, io: std.Io, detail: bool) bool {
    // No fork when wpctl is absent (see toolPath): same zombie-leak class
    // as the pactl probes. Helpers below only run after a probe answered,
    // which proves the binary exists.
    var wbuf: [64]u8 = undefined;
    const wpctl_exe = toolPath(&wbuf, "wpctl") orelse return false;
    const status_text = live.runCapture(alloc, io, &.{ wpctl_exe, "status" });
    if (status_text == null) {
        // Bare pipewire without `status` (or a broken install): the two
        // default levels still move the cards.
        const vs = live.runCapture(alloc, io, &.{ wpctl_exe, "get-volume", "@DEFAULT_AUDIO_SINK@" });
        defer if (vs) |s| alloc.free(s);
        const vi = live.runCapture(alloc, io, &.{ wpctl_exe, "get-volume", "@DEFAULT_AUDIO_SOURCE@" });
        defer if (vi) |s| alloc.free(s);
        if (vs == null and vi == null) return false;
        q.snap.have_server = true;
        if (vs) |s| {
            const p = parseWpctlVolume(s);
            if (p >= 0) q.snap.out.volume_pct = p;
            q.snap.out.muted = parseWpctlMuted(s);
        }
        q.snap.out.is_default = true;
        if (vi) |s| {
            const p = parseWpctlVolume(s);
            if (p >= 0) q.snap.in.volume_pct = p;
            q.snap.in.muted = parseWpctlMuted(s);
        }
        q.snap.in.is_default = true;
        return true;
    }
    q.status_text = status_text;
    q.snap.have_server = true;
    const info = parseWpctlStatus(status_text.?, q, alloc);
    // The status table prints app rows without their media class, so one
    // `wpctl inspect` per stream (detail only — the mixer's input section is
    // painted only by an open popup) sorts recording streams out of the
    // output list and keeps the identity props the desktop-name cascade
    // reads. Must run before the snap slices below: it moves list items.
    if (detail) classifyStreams(q, alloc, io);
    // The `Sources:` table misses filter-chain mics (they print under
    // `Filters:`) and lists `Audio/Source/Internal` rows that `wpctl
    // set-default` rejects. Enumerate the real source nodes via one
    // `pw-dump`; the status table remains the fallback.
    replaceSourcesFromPwDump(q, alloc, io, info);
    q.snap.sinks = q.sink_list.items;
    q.snap.sources = q.source_list.items;
    q.snap.out_streams = q.out_stream_list.items;
    q.snap.in_streams = q.in_stream_list.items;
    q.snap.out = wpctlDefaultSink(q, alloc, io);
    q.snap.in = wpctlDefaultSource(q, alloc, io, info);
    if (detail) wpctlStreamLevels(q, alloc, io);
    return true;
}

/// `wpctl status` prints every top-level stream row the same way regardless
/// of direction, so the mixer's Input section needs one `wpctl inspect` per
/// row to tell `Stream/Input/Audio` from `Stream/Output/Audio`. Inspecting also yields the identity
/// props the dock's desktop-name cascade tries ahead of the raw application
/// name: process binary, app id, `node.description`.
fn classifyStreams(q: *Queried, alloc: std.mem.Allocator, io: std.Io) void {
    var i: usize = 0;
    while (i < q.out_stream_list.items.len) {
        const s = q.out_stream_list.items[i];
        var idbuf: [16]u8 = undefined;
        const id_text = std.fmt.bufPrint(&idbuf, "{d}", .{s.id}) catch break;
        const text = live.runCapture(alloc, io, &.{ "wpctl", "inspect", id_text }) orelse {
            i += 1;
            continue;
        };
        // The inspect text outlives the row: every prop below borrows it.
        q.inspect_more.append(alloc, text) catch {
            alloc.free(text);
            i += 1;
            continue;
        };
        const binary = inspectField(text, "application.process.binary");
        const app_id = inspectField(text, "application.id");
        const desc = inspectField(text, "node.description");
        var icon = inspectField(text, "application.icon-name");
        if (icon.len == 0) icon = inspectField(text, "application.icon_name");
        if (inspectIsInputStream(text)) {
            var moved = q.out_stream_list.orderedRemove(i);
            moved.process_binary = binary;
            moved.app_id = app_id;
            moved.description = desc;
            moved.icon_name = icon;
            q.in_stream_list.append(alloc, moved) catch {};
        } else {
            const t = &q.out_stream_list.items[i];
            t.process_binary = binary;
            t.app_id = app_id;
            t.description = desc;
            t.icon_name = icon;
            i += 1;
        }
    }
}

/// Recording streams paint under the mixer's Input header.
fn inspectIsInputStream(text: []const u8) bool {
    return std.mem.startsWith(u8, inspectField(text, "media.class"), "Stream/Input");
}

/// The `*`-marked sink row, i.e. `@DEFAULT_AUDIO_SINK@` in table form. When
/// WirePlumber has no default yet the levels still come from `wpctl
/// get-volume`, and the first listed sink at least keeps the combo populated.
fn wpctlDefaultSink(q: *Queried, alloc: std.mem.Allocator, io: std.Io) Device {
    for (q.sink_list.items) |d| if (d.is_default) return d;
    var dev: Device = if (q.sink_list.items.len > 0) q.sink_list.items[0] else .{};
    dev.is_default = true;
    const t = live.runCapture(alloc, io, &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }) orelse return dev;
    defer alloc.free(t);
    const p = parseWpctlVolume(t);
    if (p >= 0) dev.volume_pct = p;
    dev.muted = parseWpctlMuted(t);
    return dev;
}

/// Replace the `wpctl status` source rows with the real `Audio/Source`
/// nodes from one `pw-dump`. The status table hides filter-chain mics
/// (the usual default: "… Input 1") under `Filters:` and lists raw
/// `Audio/Source/Internal` hw nodes under `Sources:` — and
/// `wpctl set-default` rejects the latter (`not a device node`), which is
/// why picking from that table could never change the default input.
/// Levels still come from the status rows by node id.
fn replaceSourcesFromPwDump(q: *Queried, alloc: std.mem.Allocator, io: std.Io, info: StatusInfo) void {
    var ebuf: [64]u8 = undefined;
    const exe = toolPath(&ebuf, "pw-dump") orelse return;
    const text = live.runCapture(alloc, io, &.{exe}) orelse return;
    // The parsed rows copy their name/description strings, so the raw dump
    // dies right after the parse (every poll would otherwise leak it).
    defer alloc.free(text);
    const default_id: u32 = if (info.filters_default_source_id > 0)
        @intCast(info.filters_default_source_id)
    else if (info.source_marked_id > 0)
        @intCast(info.source_marked_id)
    else
        0;

    var list: std.ArrayList(Device) = .empty;
    parsePwDumpSources(alloc, text, q.source_list.items, default_id, &list) catch {
        freeDeviceItems(alloc, list.items);
        list.deinit(alloc);
        return;
    };
    if (list.items.len == 0) {
        list.deinit(alloc);
        return;
    }
    if (q.sources_owned) freeDeviceItems(alloc, q.source_list.items);
    q.source_list.deinit(alloc);
    q.source_list = list;
    q.sources_owned = true;
}

/// Pure `pw-dump` source-node parse (fixture-tested). Every node whose
/// `media.class` is exactly `Audio/Source` is capture-capable *and*
/// defaultable; `Audio/Source/Internal` rows (raw ALSA hw nodes shown in
/// the `wpctl status` `Sources:` table) are skipped because
/// `wpctl set-default` rejects them. `levels` supplies the volume/mute the
/// status table already parsed for the same ids. The appended rows own
/// copies of their name/description (the JSON parse arena dies here), so
/// free them with `freeDeviceItems`.
fn parsePwDumpSources(
    alloc: std.mem.Allocator,
    text: []const u8,
    levels: []const Device,
    default_id: u32,
    out: *std.ArrayList(Device),
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{
        // `pw-dump` repeats `"info"` keys inside `params.Tag` entries.
        .duplicate_field_behavior = .use_last,
    }) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return;
    for (root.array.items) |obj| {
        if (out.items.len >= 16) break;
        if (obj != .object) continue;
        const typ = obj.object.get("type") orelse continue;
        if (typ != .string or !std.mem.eql(u8, typ.string, "PipeWire:Interface:Node")) continue;
        const info_v = obj.object.get("info") orelse continue;
        if (info_v != .object) continue;
        const props = info_v.object.get("props") orelse continue;
        if (props != .object) continue;
        const cls = jsonStr(props, "media.class") orelse continue;
        if (!std.mem.eql(u8, cls, "Audio/Source")) continue;
        const id_v = obj.object.get("id") orelse continue;
        if (id_v != .integer or id_v.integer <= 0 or id_v.integer > 0xffff_ffff) continue;
        const id: u32 = @intCast(id_v.integer);
        const nname = jsonStr(props, "node.name") orelse continue;
        if (nname.len == 0) continue;
        var desc = nname;
        if (jsonStr(props, "node.description")) |d| {
            if (d.len > 0) desc = d;
        } else if (jsonStr(props, "node.nick")) |d| {
            if (d.len > 0) desc = d;
        }
        var vol: i32 = 100;
        var muted = false;
        for (levels) |s| {
            if (s.id == id) {
                vol = s.volume_pct;
                muted = s.muted;
            }
        }
        const name_copy = try alloc.dupe(u8, nname);
        const desc_copy = alloc.dupe(u8, desc) catch |e| {
            alloc.free(name_copy);
            return e;
        };
        out.append(alloc, .{
            .id = id,
            .name = name_copy,
            .description = desc_copy,
            .volume_pct = vol,
            .muted = muted,
            .is_default = id == default_id,
        }) catch |e| {
            alloc.free(name_copy);
            alloc.free(desc_copy);
            return e;
        };
    }
}

/// Free the strings `parsePwDumpSources` copied for its rows.
fn freeDeviceItems(alloc: std.mem.Allocator, items: []Device) void {
    for (items) |d| {
        if (d.name.len > 0) alloc.free(d.name);
        if (d.description.len > 0) alloc.free(d.description);
    }
}

/// The default source is not always in the status `Sources:` table —
/// WirePlumber parks it on a filter node printed under `Filters:` (its `*`
/// row carries the `[Audio/Source]` tag). Prefer the node `pw-dump` found
/// (id + description + real `Audio/Source` class); otherwise keep the
/// filter row's id/name so the combo is populated and its slider works.
fn wpctlDefaultSource(q: *Queried, alloc: std.mem.Allocator, io: std.Io, info: StatusInfo) Device {
    var dev: Device = .{};
    var have = false;
    for (q.source_list.items) |d| {
        const is_filter_default = info.filters_default_source_id > 0 and
            d.id == @as(u32, @intCast(info.filters_default_source_id));
        if (d.is_default or is_filter_default) {
            dev = d;
            have = true;
            break;
        }
    }
    if (!have and info.filters_default_source_id > 0) {
        dev = .{
            .id = @intCast(info.filters_default_source_id),
            .name = info.filters_default_source,
        };
        dev.description = inspectNodeName(q, alloc, io, info.filters_default_source_id, info.filters_default_source);
        have = true;
    }
    if (!have and q.source_list.items.len > 0) {
        dev = q.source_list.items[0];
    }
    // Status prints no level for mics parked on a filter, so always take
    // the level from the default alias.
    const t = live.runCapture(alloc, io, &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@" }) orelse return dev;
    defer alloc.free(t);
    const p = parseWpctlVolume(t);
    if (p >= 0) dev.volume_pct = p;
    dev.muted = parseWpctlMuted(t);
    dev.is_default = true;
    return dev;
}

/// A filter node's `Filters:` row carries its raw `node.name`; the human
/// label lives one `wpctl inspect <id>` away, trying
/// `description`, then `nick`, then `name`. The capture stays in
/// `q.inspect_text` (the returned slice borrows it); a failed inspect just
/// keeps `fallback`.
fn inspectNodeName(q: *Queried, alloc: std.mem.Allocator, io: std.Io, id: i32, fallback: []const u8) []const u8 {
    if (id <= 0) return fallback;
    var buf: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&buf, "{d}", .{id}) catch return fallback;
    const t = live.runCapture(alloc, io, &.{ "wpctl", "inspect", ids }) orelse return fallback;
    if (q.inspect_text) |old| alloc.free(old);
    q.inspect_text = t;
    for ([_][]const u8{ "node.description", "node.nick", "node.name" }) |k| {
        const v = inspectField(t, k);
        if (v.len > 0) return v;
    }
    return fallback;
}

/// One `  * node.description = "UMC202HD 192k Input 1"` line out of
/// `wpctl inspect`: strip the box art and the `*` marker, match the key at
/// a word boundary, drop the quotes.
fn inspectField(text: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "*")) line = std.mem.trimStart(u8, line[1..], " \t");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = line[key.len..];
        if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '=')) continue;
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        const val = std.mem.trim(u8, rest[eq + 1 ..], " \t\r");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') return val[1 .. val.len - 1];
        return val;
    }
    return "";
}

/// The mixer shows at most four output rows; `wpctl status` prints no level
/// for streams, so each row costs one `wpctl get-volume <id>`.
fn wpctlStreamLevels(q: *Queried, alloc: std.mem.Allocator, io: std.Io) void {
    // Caps mirror what the expanded mixer can show: four output rows, three
    // input rows (`mix_show_out` / `mix_show_in` in the layout).
    var n: usize = 0;
    for (q.out_stream_list.items) |*s| {
        if (n >= 4) break;
        fetchStreamLevel(s, alloc, io);
        n += 1;
    }
    var m: usize = 0;
    for (q.in_stream_list.items) |*s| {
        if (m >= 3) break;
        fetchStreamLevel(s, alloc, io);
        m += 1;
    }
}

fn fetchStreamLevel(s: *Stream, alloc: std.mem.Allocator, io: std.Io) void {
    var buf: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{d}", .{s.id}) catch return;
    const t = live.runCapture(alloc, io, &.{ "wpctl", "get-volume", id }) orelse return;
    defer alloc.free(t);
    const p = parseWpctlVolume(t);
    if (p >= 0) s.volume_pct = p;
    s.muted = parseWpctlMuted(t);
}

const StatusSection = enum { none, sinks, sources, streams, filters };

pub const StatusInfo = struct {
    /// A `*`-marked row exists in `Sources:`.
    source_marked: bool = false,
    /// Node id of that `*`-marked `Sources:` row.
    source_marked_id: i32 = 0,
    /// Name of the `*`-marked `[…/Audio/Source]` row under `Filters:`.
    filters_default_source: []const u8 = "",
    /// Node id of that same row — what `wpctl inspect` takes to fetch the
    /// human name the status table does not print for filter nodes.
    filters_default_source_id: i32 = 0,
};

const StatusEntry = struct {
    id: i32,
    id_text: []const u8,
    rest: []const u8,
    marked: bool,
    /// Leading whitespace of the raw line: `Streams:` children sit four
    /// columns deeper than the app row above them, and only the indent
    /// (not the text) tells the two apart.
    indent: usize = 0,
};

/// One `│  *  148. Heavys H1H  [vol: 1.00]` line: skip the box art, an
/// optional default marker, then `<id>. <rest>`. Null for section headers
/// and box rules (neither starts with digits).
fn parseStatusEntry(line: []const u8) ?StatusEntry {
    var indent: usize = 0;
    while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
    var i: usize = 0;
    var marked = false;
    while (i < line.len) {
        const ch = line[i];
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            i += 1;
        } else if (ch == '*') {
            marked = true;
            i += 1;
        } else if (ch == '-' or ch == '|') {
            i += 1;
        } else if (ch == 0xE2) {
            // A three-byte box-drawing rune (`│ ├ └ ─`).
            i += @min(3, line.len - i);
        } else break;
    }
    const start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    const id_text = line[start..i];
    if (i >= line.len or line[i] != '.') return null;
    i += 1;
    if (i < line.len and line[i] == ' ') i += 1;
    return .{
        .id = std.fmt.parseInt(i32, id_text, 10) catch return null,
        .id_text = id_text,
        .rest = line[i..],
        .marked = marked,
        .indent = indent,
    };
}

/// Split the trailing ` [vol: 0.40]` and ` [MUTED]` off a status line;
/// returns the bare name. Descriptions can carry their own brackets
/// (`GB203 … (HDMI) [MAG 272Q X24]`), so only the metadata markers cut.
fn splitStatusMeta(rest: []const u8, vol: *f64, muted: *bool) []const u8 {
    var name = rest;
    // `[MUTED]` sits *after* the volume bracket, so it is looked up on the
    // whole line — cutting at `[vol: ` would lose it.
    if (std.mem.indexOf(u8, rest, "[MUTED]") != null) muted.* = true;
    if (std.mem.indexOf(u8, rest, "[vol: ")) |k| {
        name = rest[0..k];
        const after = rest[k + 6 ..];
        const end = std.mem.indexOfScalar(u8, after, ']') orelse after.len;
        vol.* = std.fmt.parseFloat(f64, after[0..end]) catch -1;
    }
    return std.mem.trim(u8, std.mem.trimEnd(u8, name, " \t"), " \t");
}

/// One `wpctl status` run. Fills the sink/source/stream tables; strings
/// borrow from `text`, so the caller must keep it alive (it stays in
/// `q.status_text`).
pub fn parseWpctlStatus(text: []const u8, q: *Queried, alloc: std.mem.Allocator) StatusInfo {
    var info: StatusInfo = .{};
    var section: StatusSection = .none;
    // `Video` repeats the same `Sinks:`/`Sources:` headers, so entries are
    // only accepted inside the `Audio` tree.
    var in_audio = false;
    // Indent of the first top-level `Streams:` row — the children below it
    // (port links, grouped nodes) sit deeper and are not streams.
    var streams_indent: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, t, "Audio")) {
            in_audio = true;
            section = .none;
            continue;
        }
        if (std.mem.eql(u8, t, "Video") or std.mem.eql(u8, t, "Settings")) {
            in_audio = false;
            section = .none;
            continue;
        }
        if (!in_audio) continue;
        if (std.mem.indexOf(u8, raw, "Sinks:") != null) {
            section = .sinks;
            continue;
        }
        if (std.mem.indexOf(u8, raw, "Sources:") != null) {
            section = .sources;
            continue;
        }
        if (std.mem.indexOf(u8, raw, "Streams:") != null or std.mem.indexOf(u8, raw, "Apps:") != null) {
            section = .streams;
            continue;
        }
        if (std.mem.indexOf(u8, raw, "Filters:") != null) {
            section = .filters;
            continue;
        }
        if (std.mem.indexOf(u8, raw, "Devices:") != null or std.mem.indexOf(u8, raw, "Clients:") != null) {
            section = .none;
            continue;
        }
        const e = parseStatusEntry(raw) orelse continue;
        switch (section) {
            .sinks, .sources => {
                var vol: f64 = -1;
                var muted = false;
                const name = splitStatusMeta(e.rest, &vol, &muted);
                const dev: Device = .{
                    .id = if (e.id > 0) @intCast(e.id) else 0,
                    // The numeric node id is what `wpctl set-default` takes;
                    // a pactl-style name never appears on this path.
                    .name = e.id_text,
                    .description = name,
                    .volume_pct = if (vol >= 0) @intFromFloat(@round(vol * 100.0)) else 100,
                    .muted = muted,
                    .is_default = e.marked,
                };
                if (section == .sinks) {
                    q.sink_list.append(alloc, dev) catch {};
                } else {
                    if (e.marked) {
                        info.source_marked = true;
                        info.source_marked_id = e.id;
                    }
                    q.source_list.append(alloc, dev) catch {};
                }
            },
            .streams => {
                // Port rows are children: deeper-indented than the app row
                // above them, and — when linked — marked with `>` (to a
                // playback port) or `<` (to a capture port). None of them
                // is a stream; only the top-level app rows are.
                if (std.mem.indexOf(u8, e.rest, ">") != null or std.mem.indexOf(u8, e.rest, "<") != null) continue;
                if (streams_indent) |base| {
                    if (e.indent > base) continue;
                } else streams_indent = e.indent;
                const name = std.mem.trim(u8, e.rest, " \t");
                q.out_stream_list.append(alloc, .{
                    .id = e.id,
                    .app_name = if (name.len > 0) name else "Unknown App",
                }) catch {};
            },
            .filters => {
                if (e.marked and std.mem.endsWith(u8, e.rest, "[Audio/Source]")) {
                    var vol: f64 = -1;
                    var muted = false;
                    var name = splitStatusMeta(e.rest, &vol, &muted);
                    // Strip the trailing `[Audio/Source]` media-class tag.
                    if (std.mem.endsWith(u8, name, "]")) {
                        if (std.mem.lastIndexOfScalar(u8, name, '[')) |k| name = std.mem.trimEnd(u8, name[0..k], " \t");
                    }
                    info.filters_default_source = name;
                    info.filters_default_source_id = e.id;
                }
            },
            .none => {},
        }
    }
    return info;
}

pub const Queried = struct {
    alloc: std.mem.Allocator,
    snap: Snapshot = .{},
    sink_list: std.ArrayList(Device) = .empty,
    source_list: std.ArrayList(Device) = .empty,
    out_stream_list: std.ArrayList(Stream) = .empty,
    in_stream_list: std.ArrayList(Stream) = .empty,
    sinks_text: ?[]u8 = null,
    sources_text: ?[]u8 = null,
    in_text: ?[]u8 = null,
    out_text: ?[]u8 = null,
    /// Raw `wpctl status` (the wpctl path keeps its table alive here).
    status_text: ?[]u8 = null,
    /// Raw `wpctl inspect` for a filter-parked default source (its friendly
    /// name borrows from this).
    inspect_text: ?[]u8 = null,
    /// One `wpctl inspect` per stream row (detail pass): each row's media
    /// class and identity props borrow from these, so they live here.
    inspect_more: std.ArrayList([]u8) = .empty,
    /// True when `source_list` rows own their name/description strings
    /// (the `pw-dump` path copies them out of its parse arena).
    sources_owned: bool = false,

    pub fn init(alloc: std.mem.Allocator) Queried {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Queried) void {
        self.sink_list.deinit(self.alloc);
        self.out_stream_list.deinit(self.alloc);
        self.in_stream_list.deinit(self.alloc);
        if (self.sinks_text) |s| self.alloc.free(s);
        if (self.sources_text) |s| self.alloc.free(s);
        if (self.in_text) |s| self.alloc.free(s);
        if (self.out_text) |s| self.alloc.free(s);
        if (self.status_text) |s| self.alloc.free(s);
        if (self.inspect_text) |s| self.alloc.free(s);
        for (self.inspect_more.items) |s| self.alloc.free(s);
        self.inspect_more.deinit(self.alloc);
        if (self.sources_owned) freeDeviceItems(self.alloc, self.source_list.items);
        self.source_list.deinit(self.alloc);
    }
};

fn pickDefault(devs: []const Device) Device {
    for (devs) |d| if (d.is_default) return d;
    if (devs.len > 0) return devs[0];
    return .{};
}

fn pctArg(buf: []u8, pct: i32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}%", .{@max(0, @min(150, pct))}) catch "100%";
}

fn runSet(io: std.Io, argv: []const []const u8) bool {
    const res = std.process.run(std.heap.page_allocator, io, .{ .argv = argv }) catch return false;
    defer std.heap.page_allocator.free(res.stdout);
    defer std.heap.page_allocator.free(res.stderr);
    return res.term == .exited and res.term.exited == 0;
}

pub fn setSinkVolume(io: std.Io, pct: i32) bool {
    var buf: [16]u8 = undefined;
    const argp = pctArg(&buf, pct);
    if (runSet(io, &.{ "pactl", "set-sink-volume", "@DEFAULT_SINK@", argp })) return true;
    var fbuf: [16]u8 = undefined;
    const f = std.fmt.bufPrint(&fbuf, "{d:.2}", .{@as(f64, @floatFromInt(@max(0, @min(150, pct)))) / 100.0}) catch return false;
    return runSet(io, &.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f });
}

pub fn setSinkMute(io: std.Io, muted: bool) bool {
    if (runSet(io, &.{ "pactl", "set-sink-mute", "@DEFAULT_SINK@", if (muted) "1" else "0" })) return true;
    return runSet(io, &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", if (muted) "1" else "0" });
}

pub fn setSourceVolume(io: std.Io, pct: i32) bool {
    var buf: [16]u8 = undefined;
    const argp = pctArg(&buf, pct);
    if (runSet(io, &.{ "pactl", "set-source-volume", "@DEFAULT_SOURCE@", argp })) return true;
    var fbuf: [16]u8 = undefined;
    const f = std.fmt.bufPrint(&fbuf, "{d:.2}", .{@as(f64, @floatFromInt(@max(0, @min(150, pct)))) / 100.0}) catch return false;
    return runSet(io, &.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SOURCE@", f });
}

pub fn setSourceMute(io: std.Io, muted: bool) bool {
    if (runSet(io, &.{ "pactl", "set-source-mute", "@DEFAULT_SOURCE@", arg(muted) })) return true;
    return runSet(io, &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", if (muted) "1" else "0" });
}

fn arg(muted: bool) []const u8 {
    return if (muted) "1" else "0";
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// `wpctl set-volume <node> <0.00..1.50>` against any node wpctl can name —
/// the numeric id the wpctl path reads, or a pactl-style name.
fn wpctlSetVolume(io: std.Io, target: []const u8, pct: i32) bool {
    if (target.len == 0) return false;
    var fbuf: [16]u8 = undefined;
    const f = std.fmt.bufPrint(&fbuf, "{d:.2}", .{@as(f64, @floatFromInt(@max(0, @min(150, pct)))) / 100.0}) catch return false;
    return runSet(io, &.{ "wpctl", "set-volume", target, f });
}

/// The mixer card's device rows: *one* sink or source, never the default one
/// — which is all `setSinkVolume`/`setSourceVolume` can reach. `raw` is the
/// row's own name (a pactl sink name on the pactl path, a numeric node id on
/// the wpctl one) and `id` covers whichever of the two the row did not carry.
pub fn setDeviceVolume(io: std.Io, raw: []const u8, id: u32, is_input: bool, pct: i32) bool {
    if (raw.len > 0 and !allDigits(raw)) {
        var buf: [16]u8 = undefined;
        const argp = pctArg(&buf, pct);
        if (runSet(io, &.{ "pactl", if (is_input) "set-source-volume" else "set-sink-volume", raw, argp })) return true;
    }
    if (id > 0) {
        var ibuf: [16]u8 = undefined;
        if (std.fmt.bufPrint(&ibuf, "{d}", .{id})) |ids| {
            if (wpctlSetVolume(io, ids, pct)) return true;
        } else |_| {}
    }
    if (wpctlSetVolume(io, raw, pct)) return true;
    return if (is_input) setSourceVolume(io, pct) else setSinkVolume(io, pct);
}

/// The mute half of `setDeviceVolume`, same node-local targeting.
pub fn setDeviceMute(io: std.Io, raw: []const u8, id: u32, is_input: bool, muted: bool) bool {
    const on = arg(muted);
    if (raw.len > 0 and !allDigits(raw)) {
        if (runSet(io, &.{ "pactl", if (is_input) "set-source-mute" else "set-sink-mute", raw, on })) return true;
    }
    if (id > 0) {
        var ibuf: [16]u8 = undefined;
        if (std.fmt.bufPrint(&ibuf, "{d}", .{id})) |ids| {
            if (runSet(io, &.{ "wpctl", "set-mute", ids, on })) return true;
        } else |_| {}
    }
    if (raw.len > 0 and runSet(io, &.{ "wpctl", "set-mute", raw, on })) return true;
    return if (is_input) setSourceMute(io, muted) else setSinkMute(io, muted);
}

/// `set-sink-input-mute` / `set-source-output-mute` — the per-stream mute the
/// volume form already has (`setStreamVolume`), in the same pactl-first,
/// `wpctl set-mute <id>` fallback shape.
pub fn setStreamMute(io: std.Io, id: i32, is_input: bool, muted: bool) bool {
    if (id < 0) return false;
    var idbuf: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch return false;
    const on = arg(muted);
    if (!is_input) {
        if (runSet(io, &.{ "pactl", "set-sink-input-mute", ids, on })) return true;
        return runSet(io, &.{ "wpctl", "set-mute", ids, on });
    }
    if (runSet(io, &.{ "pactl", "set-source-output-mute", ids, on })) return true;
    return runSet(io, &.{ "wpctl", "set-mute", ids, on });
}

pub fn setDefaultSink(io: std.Io, name: []const u8) bool {
    if (name.len == 0) return false;
    if (runSet(io, &.{ "pactl", "set-default-sink", name })) return true;
    return wpctlSetDefault(io, name);
}

pub fn setDefaultSource(io: std.Io, name: []const u8) bool {
    if (name.len == 0) return false;
    if (runSet(io, &.{ "pactl", "set-default-source", name })) return true;
    return wpctlSetDefault(io, name);
}

/// `wpctl set-default` takes only a numeric node id — it rejects names with
/// `is not a valid number`. The pactl-less snapshot carries `node.name` in
/// `Device.name` (that is what route matching wants), so non-numeric names
/// resolve through one `pw-dump` first. Click-time only.
fn wpctlSetDefault(io: std.Io, name: []const u8) bool {
    if (allDigits(name)) return runSet(io, &.{ "wpctl", "set-default", name });
    const alloc = std.heap.page_allocator;
    var ebuf: [64]u8 = undefined;
    const exe = toolPath(&ebuf, "pw-dump") orelse return false;
    const text = live.runCapture(alloc, io, &.{exe}) orelse return false;
    defer alloc.free(text);
    const id = pwDumpNodeIdByName(alloc, text, name) orelse return false;
    var ibuf: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&ibuf, "{d}", .{id}) catch return false;
    return runSet(io, &.{ "wpctl", "set-default", ids });
}

/// Pure `pw-dump` lookup: node id of the `PipeWire:Interface:Node` whose
/// `node.name` matches (fixture-tested).
fn pwDumpNodeIdByName(alloc: std.mem.Allocator, text: []const u8, name: []const u8) ?u32 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{
        .duplicate_field_behavior = .use_last,
    }) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return null;
    for (root.array.items) |obj| {
        if (obj != .object) continue;
        const typ = obj.object.get("type") orelse continue;
        if (typ != .string or !std.mem.eql(u8, typ.string, "PipeWire:Interface:Node")) continue;
        const info_v = obj.object.get("info") orelse continue;
        if (info_v != .object) continue;
        const props = info_v.object.get("props") orelse continue;
        const nname = jsonStr(props, "node.name") orelse continue;
        if (!std.mem.eql(u8, nname, name)) continue;
        const id_v = obj.object.get("id") orelse continue;
        if (id_v != .integer or id_v.integer <= 0 or id_v.integer > 0xffff_ffff) continue;
        return @intCast(id_v.integer);
    }
    return null;
}

pub fn setStreamVolume(io: std.Io, id: i32, is_input: bool, pct: i32) bool {
    if (id < 0) return false;
    var idbuf: [16]u8 = undefined;
    var pctbuf: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch return false;
    const argp = pctArg(&pctbuf, pct);
    if (!is_input) {
        if (runSet(io, &.{ "pactl", "set-sink-input-volume", ids, argp })) return true;
        return runSet(io, &.{ "wpctl", "set-volume", ids, argp });
    }
    if (runSet(io, &.{ "pactl", "set-source-output-volume", ids, argp })) return true;
    return runSet(io, &.{ "wpctl", "set-volume", ids, argp });
}

/// `pactl move-sink-input <stream> <sink>` — per-app output routing. The
/// Ports relink directly (`pw-link -d/-w`); the pactl form is the same
/// operation through the PulseAudio-compat layer.
pub fn moveSinkInput(io: std.Io, stream_id: u32, sink_name: []const u8) bool {
    if (sink_name.len == 0) return false;
    var idbuf: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&idbuf, "{d}", .{stream_id}) catch return false;
    return runSet(io, &.{ "pactl", "move-sink-input", ids, sink_name });
}

/// `pactl move-source-output <stream> <source>` — per-app input routing.
pub fn moveSourceOutput(io: std.Io, stream_id: u32, source_name: []const u8) bool {
    if (source_name.len == 0) return false;
    var idbuf: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&idbuf, "{d}", .{stream_id}) catch return false;
    return runSet(io, &.{ "pactl", "move-source-output", ids, source_name });
}

/// `pactl set-card-profile <idx> <profile>` — card codec/preset switch. For
/// Bluetooth vendor codecs first apply `off` to force an A2DP
/// renegotiation (`apply_card_profile`); `force_off_first` selects that.
/// pactl-less boxes go through `wpctl set-profile <dev> <index>`, with the
/// index resolved from the card's own `pw-dump` `EnumProfile` (the compat
/// CLI is what is absent there, never the daemon).
pub fn setCardProfile(io: std.Io, card_index: u32, profile: []const u8, force_off_first: bool) bool {
    if (profile.len == 0) return false;
    var ebuf: [64]u8 = undefined;
    if (toolPath(&ebuf, "pactl")) |exe| {
        var idxbuf: [16]u8 = undefined;
        const idx = std.fmt.bufPrint(&idxbuf, "{d}", .{card_index}) catch return false;
        if (force_off_first) {
            if (!runSet(io, &.{ exe, "set-card-profile", idx, "off" })) return false;
        }
        return runSet(io, &.{ exe, "set-card-profile", idx, profile });
    }
    return wpctlSetProfile(io, card_index, profile, force_off_first);
}

/// EnumProfile index for a profile name on one card (matched by device id)
/// in a `pw-dump` document. Pure; fixture-tested.
fn pwDumpProfileIndex(alloc: std.mem.Allocator, text: []const u8, card_index: u32, name: []const u8) ?i32 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{
        // `pw-dump` repeats `"info"` keys inside `params.Tag` entries.
        .duplicate_field_behavior = .use_last,
    }) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return null;
    for (root.array.items) |obj| {
        if (obj != .object) continue;
        const id_v = obj.object.get("id") orelse continue;
        if (id_v != .integer or id_v.integer <= 0 or id_v.integer > 0xffff_ffff) continue;
        if (@as(u32, @intCast(id_v.integer)) != card_index) continue;
        const info_v = obj.object.get("info") orelse continue;
        if (info_v != .object) continue;
        const params_v = info_v.object.get("params") orelse continue;
        if (params_v != .object) continue;
        const ev = params_v.object.get("EnumProfile") orelse continue;
        if (ev != .array) continue;
        for (ev.array.items) |pitem| {
            if (pitem != .object) continue;
            const pname = jsonStr(pitem, "name") orelse continue;
            if (!std.mem.eql(u8, pname, name)) continue;
            const pidx = pitem.object.get("index") orelse continue;
            if (pidx != .integer or pidx.integer < 0 or pidx.integer > std.math.maxInt(i32)) continue;
            return @intCast(pidx.integer);
        }
    }
    return null;
}

/// `wpctl set-profile <device-id> <enum-index>` — the native switch for
/// pactl-less boxes. Dumps the single Device object (a few ms) to map the
/// profile name onto its index; vendor-codec switches re-apply `off`
/// first, exactly like the pactl path.
fn wpctlSetProfile(io: std.Io, card_index: u32, profile: []const u8, force_off_first: bool) bool {
    var wbuf: [64]u8 = undefined;
    const exe = toolPath(&wbuf, "wpctl") orelse return false;
    var idbuf: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&idbuf, "{d}", .{card_index}) catch return false;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var pbuf: [64]u8 = undefined;
    const pdex = toolPath(&pbuf, "pw-dump") orelse return false;
    const dump = live.runCapture(alloc, io, &.{ pdex, id }) orelse return false;
    const target = pwDumpProfileIndex(alloc, dump, card_index, profile) orelse return false;
    if (force_off_first) {
        if (pwDumpProfileIndex(alloc, dump, card_index, "off")) |off_index| {
            var obuf: [16]u8 = undefined;
            const off = std.fmt.bufPrint(&obuf, "{d}", .{off_index}) catch null;
            if (off) |o| _ = runSet(io, &.{ exe, "set-profile", id, o });
        }
    }
    var tbuf: [16]u8 = undefined;
    const ti = std.fmt.bufPrint(&tbuf, "{d}", .{target}) catch return false;
    return runSet(io, &.{ exe, "set-profile", id, ti });
}

/// Whether a card key names a Bluetooth card (vendor-codec `off`-first
/// renegotiation applies).
pub fn isBluetoothCard(card_key: []const u8) bool {
    return std.mem.startsWith(u8, card_key, "bluez_card.");
}

/// Whether a profile key selects a vendor codec (aptX/LDAC/FastStream…),
/// detected by codec id ≥ 6 for the `off`-first dance. Exact
/// id parsing needs the card dump; name matching covers the common keys.
pub fn isVendorCodecProfile(profile_key: []const u8) bool {
    var low_buf: [128]u8 = undefined;
    const n = @min(profile_key.len, low_buf.len);
    for (profile_key[0..n], 0..) |c, i| low_buf[i] = std.ascii.toLower(c);
    const low = low_buf[0..n];
    for ([_][]const u8{ "aptx", "ldac", "faststream", "sco", "aac" }) |k| {
        if (std.mem.indexOf(u8, low, k) != null) return true;
    }
    return false;
}

// Query spawns for the mixer popup (pure parsers live beside their tests)

/// `pw-link -l` blob capture. The popup batches one capture per frame and
/// shares it across streams (`playbackSinkForStream` /
/// `captureSourceForStream` in the widget parse it).
pub fn capturePwLinkBlob(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    return live.runCapture(alloc, io, &.{ "pw-link", "-l" });
}

/// PipeWire/audio binary resolution (`/usr/local/bin` → `/usr/bin` →
/// `/usr/sbin` → `/bin`). Returns null when the tool is absent so callers
/// skip the spawn entirely: forking a probe for a missing binary every poll
/// leaks an unreaped zombie per attempt (the exec-failed child is never
/// waited on) and marches toward PID exhaustion.
fn toolPath(buf: []u8, name: []const u8) ?[]const u8 {
    const linux = std.os.linux;
    for ([_][]const u8{ "/usr/local/bin/", "/usr/bin/", "/usr/sbin/", "/bin/" }) |dir| {
        if (dir.len + name.len + 1 > buf.len) continue;
        @memcpy(buf[0..dir.len], dir);
        @memcpy(buf[dir.len .. dir.len + name.len], name);
        buf[dir.len + name.len] = 0;
        if (linux.access(buf[0 .. dir.len + name.len :0], linux.X_OK) == 0)
            return buf[0 .. dir.len + name.len];
    }
    return null;
}

pub const EngineSettings = struct {
    available: bool = false,
    clock_rate_hz: i32 = 48000,
    clock_force_rate_hz: i32 = 0,
    allowed_rates_hz: []i32 = &.{},
    clock_quantum: i32 = 0,
    clock_force_quantum: i32 = 0,
};

pub fn freeEngineSettings(alloc: std.mem.Allocator, es: *EngineSettings) void {
    alloc.free(es.allowed_rates_hz);
    es.allowed_rates_hz = &.{};
}

/// `key:'name' … value:'val'` extraction from `pw-metadata` lines.
/// The value borrows `line`, which the caller keeps alive.
fn metaQuotedValue(line: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "key:'{s}'", .{key}) catch return null;
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    const rest = line[at + needle.len ..];
    const vs = std.mem.indexOf(u8, rest, "value:'") orelse return null;
    const start = vs + "value:'".len;
    const tail = rest[start..];
    const end = std.mem.indexOfScalar(u8, tail, '\'') orelse return null;
    return tail[0..end];
}

fn parsePositiveInt(s: []const u8, fallback: i32) i32 {
    const v = std.fmt.parseInt(i32, std.mem.trim(u8, s, " "), 10) catch return fallback;
    return if (v > 0) v else fallback;
}

fn parseNonnegInt(s: []const u8, fallback: i32) i32 {
    const v = std.fmt.parseInt(i32, std.mem.trim(u8, s, " "), 10) catch return fallback;
    return if (v >= 0) v else fallback;
}

/// All digit runs in `0 < v < 2M`, sorted and deduped (`[ 44100 48000 ]`).
fn parseIntBracketList(alloc: std.mem.Allocator, s: []const u8) ![]i32 {
    var out = std.ArrayList(i32).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] < '0' or s[i] > '9')) i += 1;
        if (i >= s.len) break;
        var j = i;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') j += 1;
        const v = std.fmt.parseInt(i32, s[i..j], 10) catch {
            i = j;
            continue;
        };
        if (v > 0 and v < 2000000) try out.append(alloc, v);
        i = j;
    }
    std.mem.sort(i32, out.items, {}, std.sort.asc(i32));
    var w: usize = 0;
    for (out.items) |v| {
        if (w == 0 or out.items[w - 1] != v) {
            out.items[w] = v;
            w += 1;
        }
    }
    out.shrinkRetainingCapacity(w);
    return out.toOwnedSlice(alloc);
}

/// `query_engine_settings` — `pw-metadata -n settings`, no TTL here (the
/// popup holds refreshes 5 s and off drags).
pub fn queryEngineSettings(alloc: std.mem.Allocator, io: std.Io) EngineSettings {
    var out = EngineSettings{};
    errdefer freeEngineSettings(alloc, &out);
    var ebuf: [64]u8 = undefined;
    const exe = toolPath(&ebuf, "pw-metadata") orelse return out;
    const argv = [_][]const u8{ exe, "-n", "settings" };
    const text = live.runCapture(alloc, io, &argv) orelse return out;
    defer alloc.free(text);
    var rate: []const u8 = "";
    var force_rate: []const u8 = "";
    var rates: []const u8 = "";
    var quantum: []const u8 = "";
    var force_quantum: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    var found: usize = 0;
    while (it.next()) |line| {
        if (found >= 5) break;
        if (rate.len == 0) {
            if (metaQuotedValue(line, "clock.rate")) |v| {
                rate = v;
                found += 1;
            }
        }
        if (force_rate.len == 0) {
            if (metaQuotedValue(line, "clock.force-rate")) |v| {
                force_rate = v;
                found += 1;
            }
        }
        if (rates.len == 0) {
            if (metaQuotedValue(line, "clock.allowed-rates")) |v| {
                rates = v;
                found += 1;
            }
        }
        if (quantum.len == 0) {
            if (metaQuotedValue(line, "clock.quantum")) |v| {
                quantum = v;
                found += 1;
            }
        }
        if (force_quantum.len == 0) {
            if (metaQuotedValue(line, "clock.force-quantum")) |v| {
                force_quantum = v;
                found += 1;
            }
        }
    }
    if (rate.len == 0) return out;
    out.available = true;
    out.clock_rate_hz = parsePositiveInt(rate, 48000);
    out.clock_force_rate_hz = parseNonnegInt(force_rate, 0);
    out.allowed_rates_hz = parseIntBracketList(alloc, rates) catch &.{};
    out.clock_quantum = parseNonnegInt(quantum, 0);
    out.clock_force_quantum = parseNonnegInt(force_quantum, 0);
    return out;
}

pub const PwTopNode = struct {
    node_id: u32 = 0,
    name: []const u8 = "",
    quantum: i32 = 0,
    rate_hz: i32 = 0,
    wait_us: f64 = 0,
    busy_us: f64 = 0,
    errors: i64 = 0,
};

pub const PwTopSample = struct {
    available: bool = false,
    reference_name: []const u8 = "",
    reference_quantum: i32 = 0,
    reference_rate_hz: i32 = 0,
    dsp_load_pct: f64 = 0,
    xruns_total: i64 = 0,
    active_nodes: i32 = 0,
};

fn pwTopUs(s: []const u8) f64 {
    const t = std.mem.trim(u8, s, " ");
    if (t.len == 0 or std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "???")) return 0;
    return std.fmt.parseFloat(f64, t) catch 0;
}

fn pwTopErr(s: []const u8) i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch 0;
}

/// `pw_parse_pw_top_batch` — keeps the last complete block (`-n 2` frames
/// with the first always idle), drops idle nodes, busiest-first.
pub fn parsePwTopBatch(text: []const u8) PwTopSample {
    var sample = PwTopSample{};
    var name_col: ?usize = null;
    var nodes_buf: [256]PwTopNode = undefined;
    var nnodes: usize = 0;
    var last_nodes: [256]PwTopNode = undefined;
    var nlast: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, "QUANT") != null and std.mem.indexOf(u8, line, "RATE") != null and
            std.mem.indexOf(u8, line, "BUSY") != null and std.mem.indexOf(u8, line, "NAME") != null)
        {
            // New block: the previous one is complete.
            @memcpy(last_nodes[0..nnodes], nodes_buf[0..nnodes]);
            nlast = nnodes;
            nnodes = 0;
            name_col = std.mem.indexOf(u8, line, "NAME");
            continue;
        }
        const nc = name_col orelse continue;
        if (line.len <= nc) continue;
        var cols: [12][]const u8 = undefined;
        var ncols: usize = 0;
        var lit = std.mem.tokenizeScalar(u8, line[0..nc], ' ');
        while (lit.next()) |tok| {
            if (ncols >= cols.len) break;
            cols[ncols] = tok;
            ncols += 1;
        }
        if (ncols < 9) continue;
        var all_digits = cols[1].len > 0;
        for (cols[1]) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (!all_digits or nnodes >= nodes_buf.len) continue;
        nodes_buf[nnodes] = .{
            .node_id = std.fmt.parseInt(u32, cols[1], 10) catch continue,
            .quantum = std.fmt.parseInt(i32, cols[2], 10) catch 0,
            .rate_hz = std.fmt.parseInt(i32, cols[3], 10) catch 0,
            .wait_us = pwTopUs(cols[4]),
            .busy_us = pwTopUs(cols[5]),
            .errors = pwTopErr(cols[8]),
        };
        nnodes += 1;
    }
    if (nlast == 0) return sample;
    sample.available = true;
    var best: f64 = -1;
    for (last_nodes[0..nlast]) |*nd| {
        if (nd.quantum == 0 and nd.busy_us == 0) continue;
        sample.xruns_total += nd.errors;
        if (nd.quantum > 0) sample.active_nodes += 1;
        if (nd.quantum > 0 and nd.rate_hz > 0 and nd.busy_us > 0) {
            const cycle = @as(f64, @floatFromInt(nd.quantum)) * 1000000.0 / @as(f64, @floatFromInt(nd.rate_hz));
            if (cycle > 0) {
                const load = nd.busy_us / cycle * 100.0;
                if (load > best) {
                    best = load;
                    sample.reference_quantum = nd.quantum;
                    sample.reference_rate_hz = nd.rate_hz;
                    sample.dsp_load_pct = load;
                }
            }
        }
    }
    return sample;
}

/// `query_pw_top_batch` — `pw-top -b -n 2`, no TTL here (popup: 5 s).
pub fn queryPwTop(alloc: std.mem.Allocator, io: std.Io) PwTopSample {
    var ebuf: [64]u8 = undefined;
    const exe = toolPath(&ebuf, "pw-top") orelse return .{};
    const argv = [_][]const u8{ exe, "-b", "-n", "2" };
    const text = live.runCapture(alloc, io, &argv) orelse return .{};
    defer alloc.free(text);
    return parsePwTopBatch(text);
}

pub const AudioCardProfile = struct {
    key: []const u8 = "",
    description: []const u8 = "",
    /// `EnumProfile` index for the native (`wpctl set-profile`) path;
    /// -1 on the pactl path (profile switches go by name there).
    index: i32 = -1,
};

pub const AudioCard = struct {
    card_index: u32 = 0,
    card_key: []const u8 = "",
    card_name: []const u8 = "",
    active_profile_key: []const u8 = "",
    profiles: []AudioCardProfile = &.{},
};

fn jsonQuotedField(obj: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, obj, needle) orelse return null;
    const rest = obj[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn jsonUintField(obj: []const u8, key: []const u8) ?u32 {
    var kbuf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, obj, needle) orelse return null;
    var rest = obj[at + needle.len ..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    var i: usize = 0;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') i += 1;
    if (i == 0) return null;
    return std.fmt.parseInt(u32, rest[0..i], 10) catch null;
}

/// Inner JSON of `"profiles":{…}` by brace depth.
fn cardProfilesInner(card: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, card, "\"profiles\":{") orelse return null;
    var depth: i32 = 0;
    var i = at + "\"profiles\":".len;
    const start = i;
    while (i < card.len) : (i += 1) {
        if (card[i] == '{') depth += 1 else if (card[i] == '}') {
            depth -= 1;
            if (depth == 0) return card[start..][0 .. i - start + 1];
        }
    }
    return null;
}

/// `query_audio_cards` — `pactl -f json list cards`, at most 6 cards.
/// `bluetooth_only` selects the BlueZ subset (the popup queries twice).
/// The PulseAudio-compat tool is used when present; a pactl-less box
/// (PipeWire without pipewire-pulse) falls back to the native `pw-dump`.
pub fn queryAudioCards(alloc: std.mem.Allocator, io: std.Io, bluetooth_only: bool) ![]AudioCard {
    var ebuf: [64]u8 = undefined;
    if (toolPath(&ebuf, "pactl")) |exe| {
        const argv = [_][]const u8{ exe, "-f", "json", "list", "cards" };
        const text = live.runCapture(alloc, io, &argv) orelse return &.{};
        defer alloc.free(text);
        return parsePactlCardsJson(alloc, text, bluetooth_only);
    }
    return queryPwDumpCards(alloc, io, bluetooth_only);
}

/// Pure `pactl -f json list cards` parse (fixture-tested).
fn parsePactlCardsJson(alloc: std.mem.Allocator, text: []const u8, bluetooth_only: bool) ![]AudioCard {
    var out = std.ArrayList(AudioCard).empty;
    errdefer {
        freeCardItems(alloc, out.items);
        out.deinit(alloc);
    }
    var rest = text;
    while (out.items.len < 6) {
        const at = std.mem.indexOf(u8, rest, "{\"index\":") orelse break;
        var depth: i32 = 0;
        var i = at;
        var end: ?usize = null;
        while (i < rest.len) : (i += 1) {
            if (rest[i] == '{') depth += 1 else if (rest[i] == '}') {
                depth -= 1;
                if (depth == 0) {
                    end = i + 1;
                    break;
                }
            }
        }
        const e = end orelse break;
        const card = rest[at..e];
        rest = rest[e..];
        const driver = jsonQuotedField(card, "driver") orelse "";
        var dlow: [128]u8 = undefined;
        const dn = @min(driver.len, dlow.len);
        for (driver[0..dn], 0..) |c, k| dlow[k] = std.ascii.toLower(c);
        const is_bt = std.mem.indexOf(u8, dlow[0..dn], "bluez") != null;
        if (is_bt != bluetooth_only) continue;
        const index = jsonUintField(card, "index") orelse continue;
        const key = jsonQuotedField(card, "name") orelse continue;
        var cname: []const u8 = "Audio card";
        if (jsonQuotedField(card, "device.description")) |d| {
            if (d.len > 0) cname = d;
        } else if (jsonQuotedField(card, "device.name")) |d| {
            if (d.len > 0) cname = d;
        }
        const active = jsonQuotedField(card, "active_profile") orelse "";
        var profs = std.ArrayList(AudioCardProfile).empty;
        errdefer {
            for (profs.items) |*p| {
                alloc.free(p.key);
                alloc.free(p.description);
            }
            profs.deinit(alloc);
        }
        if (cardProfilesInner(card)) |inner| {
            // Profile objects (`"key":{…}`) at depth 0; scalar keys are
            // skipped, descriptions read naively (no escape
            // handling in `pactl -f json` output either).
            var pr = inner;
            while (true) {
                const q = std.mem.indexOfScalar(u8, pr, '"') orelse break;
                pr = pr[q + 1 ..];
                const q2 = std.mem.indexOfScalar(u8, pr, '"') orelse break;
                const pkey = pr[0..q2];
                pr = pr[q2 + 1 ..];
                if (pkey.len == 0) continue;
                // A profile key is followed by `{`; anything else is a
                // scalar (e.g. a description value) — skip it.
                var j: usize = 0;
                while (j < pr.len and (pr[j] == ':' or pr[j] == ' ' or pr[j] == '\t' or pr[j] == '\n' or pr[j] == '\r')) j += 1;
                if (j >= pr.len or pr[j] != '{') continue;
                // Balanced object substring for the description hunt.
                var pdepth: i32 = 0;
                var k: usize = j;
                var obj_end: ?usize = null;
                while (k < pr.len) : (k += 1) {
                    if (pr[k] == '{') pdepth += 1 else if (pr[k] == '}') {
                        pdepth -= 1;
                        if (pdepth == 0) {
                            obj_end = k;
                            break;
                        }
                    }
                }
                const oe = obj_end orelse break;
                const obj = pr[j .. oe + 1];
                var pdesc: []const u8 = "";
                if (std.mem.indexOf(u8, obj, "\"description\":\"")) |dd| {
                    const ds = obj[dd + "\"description\":\"".len ..];
                    if (std.mem.indexOfScalar(u8, ds, '"')) |de| pdesc = ds[0..de];
                }
                try profs.append(alloc, .{
                    .key = try alloc.dupe(u8, pkey),
                    .description = try alloc.dupe(u8, pdesc),
                });
                pr = pr[oe + 1 ..];
            }
        }
        if (profs.items.len == 0) {
            for (profs.items) |*p| {
                alloc.free(p.key);
                alloc.free(p.description);
            }
            profs.deinit(alloc);
            continue;
        }
        try out.append(alloc, .{
            .card_index = index,
            .card_key = try alloc.dupe(u8, key),
            .card_name = try alloc.dupe(u8, cname),
            .active_profile_key = try alloc.dupe(u8, active),
            .profiles = try profs.toOwnedSlice(alloc),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Native `query_audio_cards` for pactl-less systems: one `pw-dump` pass.
fn queryPwDumpCards(alloc: std.mem.Allocator, io: std.Io, bluetooth_only: bool) ![]AudioCard {
    var ebuf: [64]u8 = undefined;
    const exe = toolPath(&ebuf, "pw-dump") orelse return &.{};
    const text = live.runCapture(alloc, io, &.{exe}) orelse return &.{};
    defer alloc.free(text);
    return parsePwDumpCards(alloc, text, bluetooth_only);
}

/// One JSON string field off an object value, null when absent/not a
/// string.
fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .string) return null;
    return f.string;
}

/// Pure `pw-dump` parse (fixture-tested). Device objects with
/// `media.class = Audio/Device`: the bluez5 ones are the Bluetooth subset,
/// the rest feed the card-profiles page — the same split the pactl
/// `driver` scan does, so the pages cannot tell the two parsers apart.
fn parsePwDumpCards(alloc: std.mem.Allocator, text: []const u8, bluetooth_only: bool) ![]AudioCard {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{
        // `pw-dump` repeats `"info"` keys inside `params.Tag` entries.
        .duplicate_field_behavior = .use_last,
    }) catch return &.{};
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return &.{};
    var out = std.ArrayList(AudioCard).empty;
    errdefer {
        freeCardItems(alloc, out.items);
        out.deinit(alloc);
    }
    for (root.array.items) |obj| {
        if (out.items.len >= 6) break;
        if (obj != .object) continue;
        const typ = obj.object.get("type") orelse continue;
        if (typ != .string or !std.mem.eql(u8, typ.string, "PipeWire:Interface:Device")) continue;
        const info_v = obj.object.get("info") orelse continue;
        if (info_v != .object) continue;
        const props_v = info_v.object.get("props") orelse continue;
        if (props_v != .object) continue;
        const media_class = jsonStr(props_v, "media.class") orelse continue;
        if (!std.mem.eql(u8, media_class, "Audio/Device")) continue;
        const api = jsonStr(props_v, "device.api") orelse "";
        const is_bt = std.mem.eql(u8, api, "bluez5");
        if (is_bt != bluetooth_only) continue;
        const id_v = obj.object.get("id") orelse continue;
        if (id_v != .integer or id_v.integer <= 0 or id_v.integer > 0xffff_ffff) continue;
        const key = jsonStr(props_v, "device.name") orelse continue;
        if (key.len == 0) continue;
        var cname: []const u8 = "Audio card";
        if (jsonStr(props_v, "device.description")) |d| {
            if (d.len > 0) cname = d;
        } else if (key.len > 0) {
            cname = key;
        }
        // Active profile + the full EnumProfile list, both off the device's
        // own `params` (pw-dump carries them inline; no second spawn).
        var active: []const u8 = "";
        var profs = std.ArrayList(AudioCardProfile).empty;
        errdefer {
            for (profs.items) |*p| {
                alloc.free(p.key);
                alloc.free(p.description);
            }
            profs.deinit(alloc);
        }
        if (info_v.object.get("params")) |params_v| {
            if (params_v == .object) {
                if (params_v.object.get("Profile")) |pv| {
                    if (pv == .array and pv.array.items.len > 0) {
                        active = jsonStr(pv.array.items[0], "name") orelse "";
                    }
                }
                if (params_v.object.get("EnumProfile")) |ev| {
                    if (ev == .array) {
                        for (ev.array.items) |pitem| {
                            if (pitem != .object) continue;
                            const pkey = jsonStr(pitem, "name") orelse continue;
                            if (pkey.len == 0) continue;
                            const pdesc = jsonStr(pitem, "description") orelse "";
                            const pidx = pitem.object.get("index") orelse continue;
                            if (pidx != .integer or pidx.integer < 0) continue;
                            try profs.append(alloc, .{
                                .key = try alloc.dupe(u8, pkey),
                                .description = try alloc.dupe(u8, pdesc),
                                .index = @intCast(pidx.integer),
                            });
                        }
                    }
                }
            }
        }
        if (profs.items.len == 0) {
            // A card mid-rescan can briefly report no profiles; still list
            // the device (the page simply has no profile combo for it).
            profs.deinit(alloc);
            try out.append(alloc, .{
                .card_index = @intCast(id_v.integer),
                .card_key = try alloc.dupe(u8, key),
                .card_name = try alloc.dupe(u8, cname),
                .active_profile_key = try alloc.dupe(u8, active),
                .profiles = &.{},
            });
            continue;
        }
        try out.append(alloc, .{
            .card_index = @intCast(id_v.integer),
            .card_key = try alloc.dupe(u8, key),
            .card_name = try alloc.dupe(u8, cname),
            .active_profile_key = try alloc.dupe(u8, active),
            .profiles = try profs.toOwnedSlice(alloc),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Per-card string frees only — the slice itself stays with its owner
/// (an `ArrayList` buffer or `freeAudioCards`).
fn freeCardItems(alloc: std.mem.Allocator, cards: []AudioCard) void {
    for (cards) |*c| {
        alloc.free(c.card_key);
        alloc.free(c.card_name);
        alloc.free(c.active_profile_key);
        for (c.profiles) |*p| {
            alloc.free(p.key);
            alloc.free(p.description);
        }
        alloc.free(c.profiles);
    }
}

pub fn freeAudioCards(alloc: std.mem.Allocator, cards: []AudioCard) void {
    freeCardItems(alloc, cards);
    alloc.free(cards);
}

/// Remember a manual sink/source choice (`cc_save_sink/source`): two lines
/// in the settings dir (`~/.config/Event-Horizon`). Best-effort; failures are silent.
pub fn savePrefs(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8, sink: []const u8, source: []const u8) void {
    const path = std.fs.path.join(alloc, &.{ state_dir, "controlcenter_audio_prefs" }) catch return;
    defer alloc.free(path);
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}\n{s}\n", .{ sink, source }) catch return;
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

/// Load the remembered choice. Returns owned strings (empty when none).
pub fn loadPrefs(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8) struct { sink: []u8, source: []u8 } {
    const path = std.fs.path.join(alloc, &.{ state_dir, "controlcenter_audio_prefs" }) catch return .{ .sink = &.{}, .source = &.{} };
    defer alloc.free(path);
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, alloc, .limited(512)) catch return .{ .sink = &.{}, .source = &.{} };
    defer alloc.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    const sink = alloc.dupe(u8, trimLine(it.next() orelse "")) catch &.{};
    const source = alloc.dupe(u8, trimLine(it.next() orelse "")) catch &.{};
    return .{ .sink = sink, .source = source };
}

test "live-audio: firstPct + mute + wpctl" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 80), firstPct("front-left: 52428 /  80% / -5.77 dB"));
    try t.expectEqual(@as(i32, 100), firstPct("Volume: 100%"));
    try t.expectEqual(@as(i32, -1), firstPct("no percent here"));
    try t.expect(parseMute("Mute: yes"));
    try t.expect(parseMute("Mute: Yes\n"));
    try t.expect(!parseMute("Mute: no"));
    try t.expectEqual(@as(i32, 80), parseWpctlVolume("Volume: 0.80\n"));
    try t.expectEqual(@as(i32, 0), parseWpctlVolume("Volume: 0.00"));
    try t.expectEqual(@as(i32, -1), parseWpctlVolume("garbage"));
}

test "live-audio: pactl device list" {
    const t = std.testing;
    const text =
        "Sink #46\n" ++
        "\tState: RUNNING\n" ++
        "\tName: alsa_output.pci-stereo\n" ++
        "\tDescription: Built-in Audio Analog Stereo\n" ++
        "\tVolume: front-left: 52428 /  80% / -5.77 dB\n" ++
        "\tMute: no\n" ++
        "\n" ++
        "Sink #47\n" ++
        "\tState: IDLE\n" ++
        "\tName: bluez_output.headset\n" ++
        "\tDescription: Heavys H1H\n" ++
        "\tVolume: front-left: 65536 / 100% / 0.00 dB\n" ++
        "\tMute: yes\n" ++
        "\n";
    var list: std.ArrayList(Device) = .empty;
    defer list.deinit(t.allocator);
    parseDeviceList(text, true, "bluez_output.headset", &list, t.allocator);
    try t.expectEqual(@as(usize, 2), list.items.len);
    try t.expectEqual(@as(u32, 46), list.items[0].id);
    try t.expectEqual(@as(i32, 80), list.items[0].volume_pct);
    try t.expect(!list.items[0].muted);
    try t.expect(!list.items[0].is_default);
    try t.expect(list.items[1].is_default);
    try t.expect(list.items[1].muted);
    try t.expectEqualStrings("Heavys H1H", list.items[1].description);
}

// ---------------------------------------------------------------------------
// Sound settings page backend — the Audio Center's Engine / Devices writes
// (ported from `PipeWireService::apply_engine_*`, `apply_compat_*`,
// `restart_services` and `sound_test_speakers`).
// ---------------------------------------------------------------------------

/// `pw-metadata -n settings 0 <key> <value>` — one engine clock write.
fn pwMetaSet(io: std.Io, key: []const u8, value: []const u8) bool {
    var ebuf: [64]u8 = undefined;
    const exe = toolPath(&ebuf, "pw-metadata") orelse return false;
    return runSet(io, &.{ exe, "-n", "settings", "0", key, value });
}

/// `"[ 44100 48000 ]"` — the metadata list format the engine selectors write.
fn formatRateList(buf: []u8, rates: []const i32) ?[]const u8 {
    var n: usize = 0;
    {
        const w = std.fmt.bufPrint(buf, "[ ", .{}) catch return null;
        n += w.len;
    }
    for (rates, 0..) |r, i| {
        const w = (if (i == 0)
            std.fmt.bufPrint(buf[n..], "{d}", .{r})
        else
            std.fmt.bufPrint(buf[n..], " {d}", .{r})) catch return null;
        n += w.len;
    }
    {
        const w = std.fmt.bufPrint(buf[n..], " ]", .{}) catch return null;
        n += w.len;
    }
    return buf[0..n];
}

/// Sorted, deduped, range-filtered copy of `rates` plus `extra` — the merge
/// `apply_engine_clock_rate_hz` performs before writing the allowed list.
fn mergeRates(out: []i32, rates: []const i32, extra: i32) []i32 {
    var n: usize = 0;
    for (rates) |r| {
        if (r <= 0 or r > 2000000 or n >= out.len) continue;
        out[n] = r;
        n += 1;
    }
    if (extra > 0 and extra <= 2000000 and n < out.len) {
        out[n] = extra;
        n += 1;
    }
    std.mem.sort(i32, out[0..n], {}, std.sort.asc(i32));
    var w: usize = 0;
    for (out[0..n]) |r| {
        if (w == 0 or out[w - 1] != r) {
            out[w] = r;
            w += 1;
        }
    }
    return out[0..w];
}

/// `apply_engine_clock_rate_hz` — the picked rate joins the allowed list,
/// then `clock.rate` moves the graph.
pub fn applyEngineClockRateHz(io: std.Io, hz: i32) bool {
    if (hz <= 0 or hz > 2000000) return false;
    const aa = std.heap.page_allocator;
    var es = queryEngineSettings(aa, io);
    defer freeEngineSettings(aa, &es);
    var rates_buf: [24]i32 = undefined;
    const merged = mergeRates(&rates_buf, es.allowed_rates_hz, hz);
    if (merged.len == 0) return false;
    var list_buf: [256]u8 = undefined;
    const list = formatRateList(&list_buf, merged) orelse return false;
    if (!pwMetaSet(io, "clock.allowed-rates", list)) return false;
    var hz_buf: [16]u8 = undefined;
    const hz_s = std.fmt.bufPrint(&hz_buf, "{d}", .{hz}) catch return false;
    return pwMetaSet(io, "clock.rate", hz_s);
}

/// `apply_engine_allowed_rates_hz` — the preset rows write the allowed list.
pub fn applyEngineAllowedRatesHz(io: std.Io, rates: []const i32) bool {
    var rates_buf: [24]i32 = undefined;
    const merged = mergeRates(&rates_buf, rates, 0);
    if (merged.len == 0) return false;
    var list_buf: [256]u8 = undefined;
    const list = formatRateList(&list_buf, merged) orelse return false;
    return pwMetaSet(io, "clock.allowed-rates", list);
}

/// `apply_engine_force_rate_hz` — 0 clears the force ("Auto").
pub fn applyEngineForceRateHz(io: std.Io, hz: i32) bool {
    if (hz < 0 or hz > 2000000) return false;
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{hz}) catch return false;
    return pwMetaSet(io, "clock.force-rate", s);
}

/// `apply_engine_quantum` — 0 clears the default buffer size.
pub fn applyEngineQuantum(io: std.Io, quantum: i32) bool {
    if (quantum < 0 or quantum > 2000000) return false;
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{quantum}) catch return false;
    return pwMetaSet(io, "clock.quantum", s);
}

/// `apply_engine_force_quantum` — 0 clears the forced buffer size.
pub fn applyEngineForceQuantum(io: std.Io, quantum: i32) bool {
    if (quantum < 0 or quantum > 2000000) return false;
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{quantum}) catch return false;
    return pwMetaSet(io, "clock.force-quantum", s);
}

/// SPA format string for a 0..3 PCM choice (`compat_pcm_choice_wp_format`).
pub fn pcmChoiceFormat(choice: i32) ?[]const u8 {
    return switch (choice) {
        0 => "S16_LE",
        1 => "S24_LE",
        2 => "S32_LE",
        3 => "F32_LE",
        else => null,
    };
}

/// The 0..3 choice a sample spec / SPA format string names, else -1.
/// `s24_32le`, `float32le` and the `s16le 2ch 48000Hz` pactl forms all map.
pub fn pcmChoiceForFormat(fmt: []const u8) i32 {
    var low_buf: [64]u8 = undefined;
    const n = @min(fmt.len, low_buf.len);
    for (fmt[0..n], 0..) |c, i| low_buf[i] = std.ascii.toLower(c);
    const low = low_buf[0..n];
    if (std.mem.indexOf(u8, low, "float32") != null or std.mem.indexOf(u8, low, "f32") != null) return 3;
    if (std.mem.indexOf(u8, low, "s24") != null) return 1;
    if (std.mem.indexOf(u8, low, "s16") != null) return 0;
    if (std.mem.indexOf(u8, low, "s32") != null) return 2;
    return -1;
}

/// `51-eh-default-pcm.conf` — the WirePlumber drop-in the PCM-format combo
/// writes (`eh_wp_pcm_conf_path`).
fn pcmConfPath(buf: []u8) ?[]const u8 {
    var base: []const u8 = "";
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) base = s;
    }
    if (base.len == 0) {
        const home = std.c.getenv("HOME") orelse return null;
        const h = std.mem.span(home);
        if (h.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/.config/wireplumber/wireplumber.conf.d/51-eh-default-pcm.conf", .{h}) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}/wireplumber/wireplumber.conf.d/51-eh-default-pcm.conf", .{base}) catch null;
}

const CompatSink = struct {
    id: u32 = 0,
    name: []const u8 = "",
    /// 0..3 PCM choice from the live SPA/sample-spec format; -1 unknown.
    choice: i32 = -1,
    /// `device.api` (`alsa`, `bluez5`, …); only known on the inspect path.
    api: []const u8 = "",
};

/// `pactl list sinks short` row for `sink`:
/// `45  alsa_output…  PipeWire  s16le 2ch 48000Hz  SUSPENDED`.
fn pactlSinkSpec(list: []const u8, sink: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, '\t') != null) {
            // The real `list sinks short` columns are tab-separated; the
            // sample spec itself contains spaces (`s16le 2ch 48000Hz`).
            var cols = std.mem.splitScalar(u8, line, '\t');
            _ = cols.next() orelse continue; // index
            const name = std.mem.trim(u8, cols.next() orelse continue, " \t\r");
            if (!std.mem.eql(u8, name, sink)) continue;
            _ = cols.next() orelse continue; // driver
            return std.mem.trim(u8, cols.next() orelse continue, " \t\r");
        }
        // Whitespace-only fixture/older output: one token is still enough
        // for `pcmChoiceForFormat`.
        var cols = std.mem.tokenizeAny(u8, line, "\t ");
        _ = cols.next() orelse continue; // index
        const name = cols.next() orelse continue;
        if (!std.mem.eql(u8, name, sink)) continue;
        _ = cols.next() orelse continue; // driver
        return cols.next(); // sample spec
    }
    return null;
}

/// First id in a `wpctl inspect` header (`id 121, type …`).
fn inspectObjectId(text: []const u8) u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "id ")) continue;
        const rest = line[3..];
        const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return 0;
        return std.fmt.parseInt(u32, std.mem.trim(u8, rest[0..comma], " \t"), 10) catch 0;
    }
    return 0;
}

/// Pure `wpctl inspect @DEFAULT_AUDIO_SINK@` parse. ALSA nodes carry the
/// configured `audio.format`; bluez nodes do not (their negotiated format
/// lives in the node's `Format` param, read by `parsePwDumpNodeFormat`).
fn parseCompatSinkInspect(text: []const u8) ?CompatSink {
    const name = inspectField(text, "node.name");
    if (name.len == 0) return null;
    return .{
        .id = inspectObjectId(text),
        .name = name,
        .choice = pcmChoiceForFormat(inspectField(text, "audio.format")),
        .api = inspectField(text, "device.api"),
    };
}

/// Pure `pw-dump <node>` format parse: `info.props.audio.format` when the
/// node exposes it, else the first `info.params.Format[].format` (bluez
/// reports its negotiated codec transport here as `S16LE`). Returns the
/// 0..3 choice, or -1. Nothing is returned by reference: the JSON parse
/// arena dies here.
fn parsePwDumpNodeFormat(alloc: std.mem.Allocator, text: []const u8) i32 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{
        .duplicate_field_behavior = .use_last,
    }) catch return -1;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return -1;
    for (root.array.items) |obj| {
        if (obj != .object) continue;
        const typ = obj.object.get("type") orelse continue;
        if (typ != .string or !std.mem.eql(u8, typ.string, "PipeWire:Interface:Node")) continue;
        const info_v = obj.object.get("info") orelse continue;
        if (info_v != .object) continue;
        if (info_v.object.get("props")) |props| {
            if (jsonStr(props, "audio.format")) |f| {
                const c = pcmChoiceForFormat(f);
                if (c >= 0) return c;
            }
        }
        const params_v = info_v.object.get("params") orelse continue;
        if (params_v != .object) continue;
        const fmt_v = params_v.object.get("Format") orelse continue;
        if (fmt_v != .array) continue;
        for (fmt_v.array.items) |item| {
            if (jsonStr(item, "format")) |f| {
                const c = pcmChoiceForFormat(f);
                if (c >= 0) return c;
            }
        }
    }
    return -1;
}

/// One `pw-dump <id>` for a node whose inspect output lacks
/// `audio.format` (the bluez case).
fn pwDumpSinkChoice(alloc: std.mem.Allocator, io: std.Io, id: u32) i32 {
    if (id == 0) return -1;
    var ibuf: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&ibuf, "{d}", .{id}) catch return -1;
    var ebuf: [64]u8 = undefined;
    const exe = toolPath(&ebuf, "pw-dump") orelse return -1;
    const text = live.runCapture(alloc, io, &.{ exe, ids }) orelse return -1;
    return parsePwDumpNodeFormat(alloc, text);
}

/// `wpctl inspect @DEFAULT_AUDIO_SINK@` (plus one `pw-dump` only when the
/// node has no `audio.format` property, i.e. Bluetooth).
fn compatSinkInspect(alloc: std.mem.Allocator, io: std.Io) ?CompatSink {
    var ebuf: [64]u8 = undefined;
    const exe = toolPath(&ebuf, "wpctl") orelse return null;
    const text = live.runCapture(alloc, io, &.{ exe, "inspect", "@DEFAULT_AUDIO_SINK@" }) orelse return null;
    var out = parseCompatSinkInspect(text) orelse return null;
    if (out.choice < 0) out.choice = pwDumpSinkChoice(alloc, io, out.id);
    return out;
}

/// Whether the default sink accepts an `audio.format` ALSA rule. The pactl
/// path does not know `device.api`, so the well-known bluez node-name
/// prefix stands in for it.
fn sinkPcmCapable(sink: CompatSink) bool {
    if (sink.api.len > 0) return std.mem.eql(u8, sink.api, "alsa");
    return !std.mem.startsWith(u8, sink.name, "bluez_");
}

/// Default sink name and live PCM choice: pactl's `get-default-sink` +
/// `list sinks short` when that binary exists, the `wpctl`/`pw-dump` pair
/// otherwise (this machine has no pactl). Captures are allocated from
/// `alloc`; pass an arena.
fn compatDefaultSink(alloc: std.mem.Allocator, io: std.Io) ?CompatSink {
    var ebuf: [64]u8 = undefined;
    if (toolPath(&ebuf, "pactl")) |exe| {
        if (live.runCapture(alloc, io, &.{ exe, "get-default-sink" })) |def| {
            const sink = std.mem.trim(u8, def, " \t\r\n");
            if (sink.len > 0) {
                var out: CompatSink = .{ .name = sink };
                if (live.runCapture(alloc, io, &.{ exe, "list", "sinks", "short" })) |list| {
                    if (pactlSinkSpec(list, sink)) |spec| out.choice = pcmChoiceForFormat(spec);
                }
                if (out.choice >= 0) return out;
                // No matching short row: the wpctl path still knows the
                // node name/API and its format param.
                if (compatSinkInspect(alloc, io)) |ins| {
                    out.id = ins.id;
                    out.api = ins.api;
                    if (out.choice < 0) out.choice = ins.choice;
                }
                return out;
            }
        }
    }
    return compatSinkInspect(alloc, io);
}

const PcmConf = struct {
    node: []const u8 = "",
    choice: i32 = -1,
};

/// Parse the EH PCM drop-in: pinned node name + SPA format choice. Slices
/// borrow the file text, allocated from `alloc` (pass an arena).
fn readPcmConf(alloc: std.mem.Allocator, io: std.Io) PcmConf {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = pcmConfPath(&pbuf) orelse return .{};
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path, alloc, .limited(1 << 16)) catch return .{};
    var out: PcmConf = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "node.name")) |at| {
            if (quotedAfter(line, at)) |v| out.node = v;
        }
        if (std.mem.indexOf(u8, line, "audio.format")) |at| {
            if (quotedAfter(line, at)) |v| out.choice = pcmChoiceForFormat(v);
        }
    }
    return out;
}

/// `query_compat_default_sink_format` — the live PCM choice for the default
/// sink (0..3), or -1 when unknown. The EH drop-in wins when it names the
/// sink (it is what the combo wrote); otherwise the live sample spec does.
/// A non-ALSA default (Bluetooth) has no PCM format of its own: the drop-in
/// then reports the ALSA target it pins, so the combo does not flip back to
/// the BT transport's fixed S16 after a selection.
pub fn queryCompatPcm(alloc: std.mem.Allocator, io: std.Io) i32 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sink = compatDefaultSink(a, io) orelse return -1;
    if (sink.name.len == 0) return -1;

    const conf = readPcmConf(a, io);
    if (conf.choice >= 0) {
        if (std.mem.eql(u8, conf.node, sink.name)) return conf.choice;
        if (!sinkPcmCapable(sink)) return conf.choice;
    }
    return sink.choice;
}

/// First `"…"` in `line` at or after `from`.
fn quotedAfter(line: []const u8, from: usize) ?[]const u8 {
    const q1 = std.mem.indexOfScalarPos(u8, line, from, '"') orelse return null;
    const rest = line[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..q2];
}

/// `apply_compat_default_sink_pcm_format` — pin the default sink's PCM
/// format through a WirePlumber drop-in so WirePlumber applies it on the
/// next device open. When the default sink is not ALSA (Bluetooth) the
/// drop-in keeps its existing ALSA target, because a rule keyed on a bluez
/// node can never match.
pub fn applyCompatPcm(alloc: std.mem.Allocator, io: std.Io, choice: i32) bool {
    const fmt = pcmChoiceFormat(choice) orelse return false;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sink = compatDefaultSink(a, io) orelse return false;
    if (sink.name.len == 0) return false;
    // Bluetooth's PCM format is codec-negotiated, so an ALSA rule keyed on
    // the bluez node never matches. Keep the drop-in's existing target (the
    // ALSA sink the user last pinned) instead of rewriting it to a dead
    // node; a BT-only box still gets a rule, it just cannot change A2DP.
    var target = sink.name;
    if (!sinkPcmCapable(sink)) {
        const conf = readPcmConf(a, io);
        if (conf.node.len > 0) target = conf.node;
    }
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = pcmConfPath(&pbuf) orelse return false;
    const body = std.fmt.allocPrint(
        a,
        "# Event Horizon: forced PCM format for the default ALSA sink.\n" ++
            "monitor.alsa.rules = [\n" ++
            "    {{\n" ++
            "        matches = [\n" ++
            "            {{\n" ++
            "                node.name = \"{s}\"\n" ++
            "            }}\n" ++
            "        ]\n" ++
            "        actions = {{\n" ++
            "            update-props = {{\n" ++
            "                audio.format = \"{s}\"\n" ++
            "            }}\n" ++
            "        }}\n" ++
            "    }}\n" ++
            "]\n",
        .{ target, fmt },
    ) catch return false;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch return false;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return false;
    cwd.writeFile(io, .{ .sub_path = tmp, .data = body }) catch return false;
    cwd.rename(tmp, cwd, path, io) catch {
        cwd.deleteFile(io, tmp) catch {};
        return false;
    };
    return true;
}

/// `restart_services` — `systemctl --user restart pipewire pipewire-pulse
/// wireplumber`; blocks for the couple of seconds the restart takes, like
/// the C++ engine row did.
pub fn restartServices(io: std.Io) bool {
    return runSet(io, &.{ "systemctl", "--user", "restart", "pipewire", "pipewire-pulse", "wireplumber" });
}

/// Fire-and-forget speaker test (`sound_test_speakers`): front-left then
/// front-right on the given sink (node name), falling back to the single
/// test signal. The two plays run through one shell so they serialize; the
/// returned pid is for the caller to reap (`wait4` with `WNOHANG`).
pub fn testSpeakers(io: std.Io, target: []const u8) ?i32 {
    if (target.len == 0 or target.len > 120) return null;
    const linux = std.os.linux;
    const left = "/usr/share/sounds/freedesktop/stereo/audio-channel-front-left.oga";
    const right = "/usr/share/sounds/freedesktop/stereo/audio-channel-front-right.oga";
    const fallback = "/usr/share/sounds/freedesktop/stereo/audio-test-signal.oga";
    const have_lr = linux.access(left, linux.R_OK) == 0 and linux.access(right, linux.R_OK) == 0;
    if (!have_lr and linux.access(fallback, linux.R_OK) != 0) return null;
    var cmd_buf: [512]u8 = undefined;
    const cmd = if (have_lr)
        std.fmt.bufPrint(&cmd_buf, "pw-play --target={s} {s}; pw-play --target={s} {s}", .{ target, left, target, right }) catch return null
    else
        std.fmt.bufPrint(&cmd_buf, "pw-play --target={s} {s}", .{ target, fallback }) catch return null;
    const child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;
    const id = child.id orelse return null;
    return id;
}

test "live-audio: pactl stream list" {
    const t = std.testing;
    const text =
        "Sink Input #123\n" ++
        "\tDriver: protocol-native.c\n" ++
        "\tSink: 46\n" ++
        "\tVolume: front-left: 58982 /  90% / -2.73 dB\n" ++
        "\tMute: no\n" ++
        "\tProperties:\n" ++
        "\t\tapplication.name = \"speech-dispatcher-dummy\"\n" ++
        "\t\tapplication.process.binary = \"sd_dummy\"\n" ++
        "\n" ++
        "Sink Input #124\n" ++
        "\tVolume: front-left: 32768 /  50% / -18.06 dB\n" ++
        "\tMute: no\n" ++
        "\n";
    var list: std.ArrayList(Stream) = .empty;
    defer list.deinit(t.allocator);
    parseStreamList(text, false, &list, t.allocator);
    try t.expectEqual(@as(usize, 2), list.items.len);
    try t.expectEqual(@as(i32, 123), list.items[0].id);
    try t.expectEqual(@as(i32, 90), list.items[0].volume_pct);
    try t.expectEqualStrings("speech-dispatcher-dummy", list.items[0].app_name);
    try t.expectEqualStrings("sd_dummy", list.items[0].process_binary);
    try t.expectEqualStrings("Unknown App", list.items[1].app_name);
}

test "live-audio: wpctl status table" {
    const t = std.testing;
    const text =
        \\PipeWire 'pipewire-0' [1.6.9, fedora, cookie:4266771793]
        \\ └─ Clients:
        \\ 33. uresourced                          [1.6.9, fedora, pid:4556]
        \\ 44. xdg-desktop-portal-hyprland         [1.6.9, fedora, pid:4513]
        \\Audio
        \\ ├─ Devices:
        \\ │      47. GB203 High Definition Audio Controller [MAG 272Q X24] [alsa]
        \\ │     137. bluez_card.A8_99_DC_57_EF_0D        [bluez5]
        \\ ├─ Sinks:
        \\ │      53. GB203 High Definition Audio Controller Digital Stereo (HDMI) [MAG 272Q X24] [vol: 0.40]
        \\ │     125. UMC202HD 192k Line A   [vol: 1.00] [MUTED]
        \\ │  *  148. Heavys H1H              [vol: 1.00]
        \\ ├─ Sources:
        \\ │      54. Insta360 Link 2 Mono [vol: 1.00]
        \\ │     124. UMC202HD 192k 0         [vol: 0.87]
        \\ ├─ Filters: ...
        \\ │  *  106. alsa_input.usb-BEHRINGER_UMC202HD_192k-00.HiFi__Mic1__source [Audio/Source]
        \\ │      97. alsa_input.usb-Insta360_Insta360_Link_2-02.mono-fallback [Stream/Input/Audio/Internal]
        \\ └─ Streams:
        \\       221. speech-dispatcher-dummy
        \\            212. output_FR       > Heavys H1H:playback_FR [init]
        \\            213. output_FL       > Heavys H1H:playback_FL [init]
        \\            214. monitor_MONO
        \\            215. input_MONO      < UMC202HD 192k:capture_MONO [active]
        \\       225. vesktop
        \\Video
        \\ ├─ Sinks:
        \\ │      60. Integrated Camera [vol: 1.00]
        \\ ├─ Sources:
        \\ │  *  61. Integrated Camera [vol: 1.00]
        \\Settings
    ;
    var q = Queried.init(t.allocator);
    defer q.deinit();
    const info = parseWpctlStatus(text, &q, t.allocator);
    // Sinks: three nodes, the `*` one is the default; ids double as the
    // name that `wpctl set-default` takes, and the level + mute come off
    // the line.
    try t.expectEqual(@as(usize, 3), q.sink_list.items.len);
    try t.expectEqualStrings("53", q.sink_list.items[0].name);
    try t.expectEqual(@as(i32, 40), q.sink_list.items[0].volume_pct);
    try t.expect(!q.sink_list.items[0].is_default);
    // The description carries its own brackets; only `[vol:`/`[MUTED]` cut.
    try t.expectEqualStrings(
        "GB203 High Definition Audio Controller Digital Stereo (HDMI) [MAG 272Q X24]",
        q.sink_list.items[0].description,
    );
    try t.expect(q.sink_list.items[1].muted);
    try t.expectEqual(@as(u32, 148), q.sink_list.items[2].id);
    try t.expectEqualStrings("Heavys H1H", q.sink_list.items[2].description);
    try t.expect(q.sink_list.items[2].is_default);
    // Sources: the default lives on a filter node, so no row is marked.
    try t.expectEqual(@as(usize, 2), q.source_list.items.len);
    try t.expect(!info.source_marked);
    try t.expectEqual(@as(i32, 87), q.source_list.items[1].volume_pct);
    try t.expectEqualStrings(
        "alsa_input.usb-BEHRINGER_UMC202HD_192k-00.HiFi__Mic1__source",
        info.filters_default_source,
    );
    // The id rides along so the card label can be resolved via
    // `wpctl inspect` instead of the raw printed name.
    try t.expectEqual(@as(i32, 106), info.filters_default_source_id);
    // Streams: the top-level app rows only — deeper-indented children (port
    // links marked `>`/`<`, markerless grouped nodes) are not streams, and
    // the Video tree's own Sinks:/Sources: never reach the tables.
    try t.expectEqual(@as(usize, 2), q.out_stream_list.items.len);
    try t.expectEqual(@as(i32, 221), q.out_stream_list.items[0].id);
    try t.expectEqualStrings("speech-dispatcher-dummy", q.out_stream_list.items[0].app_name);
    try t.expectEqual(@as(i32, 225), q.out_stream_list.items[1].id);
    try t.expectEqualStrings("vesktop", q.out_stream_list.items[1].app_name);
    // The Video tree's own Sinks:/Sources: (ids 60/61) never reach the tables.
    for (q.sink_list.items) |d| try t.expect(d.id != 60);
    for (q.source_list.items) |d| try t.expect(d.id != 60 and d.id != 61);
}

test "live-audio: wpctl inspect field parsing" {
    const t = std.testing;
    const text =
        \\* object.serial = "1712"
        \\    * node.description = "UMC202HD 192k Input 1"
        \\      node.nick = "UMC202HD Mic1"
        \\      node.name = "alsa_input.usb-BEHRINGER_UMC202HD_192k-00.HiFi__Mic1__source"
        \\      device.description = "UMC202HD, USB Audio"
        \\      node.description = ""
    ;
    // Starred or not, quoted or not; the key must match at a word
    // boundary (`device.description` is not `node.description`).
    try t.expectEqualStrings("UMC202HD 192k Input 1", inspectField(text, "node.description"));
    try t.expectEqualStrings("UMC202HD Mic1", inspectField(text, "node.nick"));
    try t.expectEqualStrings(
        "alsa_input.usb-BEHRINGER_UMC202HD_192k-00.HiFi__Mic1__source",
        inspectField(text, "node.name"),
    );
    try t.expectEqualStrings("UMC202HD, USB Audio", inspectField(text, "device.description"));
    try t.expectEqualStrings("", inspectField(text, "media.class"));
    // An empty quoted value reads as empty, so the caller falls through.
    try t.expectEqualStrings("", inspectField("node.description = \"\"\n", "node.description"));
}

test "live-audio: media.class splits mixer in/out streams" {
    const t = std.testing;
    const in_text =
        \\  * media.class = "Stream/Input/Audio"
        \\  * application.name = "vesktop"
        \\    application.process.binary = "vesktop"
    ;
    const out_text = "  * media.class = \"Stream/Output/Audio\"\n";
    try t.expect(inspectIsInputStream(in_text));
    try t.expect(!inspectIsInputStream(out_text));
    try t.expect(!inspectIsInputStream(""));
    try t.expectEqualStrings("vesktop", inspectField(in_text, "application.process.binary"));
}

test "live-audio: engine metadata parsing" {
    const t = std.testing;
    const line = "id: 0, key:'clock.rate', type:'', value:'48000', user:'pipewire'";
    try t.expectEqualStrings("48000", metaQuotedValue(line, "clock.rate").?);
    try t.expect(metaQuotedValue(line, "clock.quantum") == null);
    try t.expectEqual(@as(i32, 48000), parsePositiveInt("48000", 0));
    try t.expectEqual(@as(i32, 7), parsePositiveInt("0", 7));
    try t.expectEqual(@as(i32, 7), parsePositiveInt("xx", 7));
    try t.expectEqual(@as(i32, 0), parseNonnegInt("0", 9));
    try t.expectEqual(@as(i32, 9), parseNonnegInt("-3", 9));
    const rates = try parseIntBracketList(t.allocator, "[ 44100 48000 48000 0 3000000 ]");
    defer t.allocator.free(rates);
    try t.expectEqualSlices(i32, &[_]i32{ 44100, 48000 }, rates);
}

test "live-audio: pw-top batch parsing keeps the last block" {
    const t = std.testing;
    // A header commits the block before it: live rows in block one win
    // over the dummy tail, which never commits (matches `-n 2` framing).
    const text =
        "S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q   ERRORS  NAME\n" ++
        "R   42   1024  48000  12.0    200.5   0.02  0.01      3   alsa_output\n" ++
        "S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q   ERRORS  NAME\n" ++
        "R   33      0      0  ---     ---   ---   ---     0   Dummy-Driver\n";
    const sample = parsePwTopBatch(text);
    try t.expect(sample.available);
    try t.expectEqual(@as(i64, 3), sample.xruns_total);
    try t.expectEqual(@as(i32, 1), sample.active_nodes);
    try t.expectEqual(@as(i32, 1024), sample.reference_quantum);
    try t.expectEqual(@as(i32, 48000), sample.reference_rate_hz);
    // 200.5µs of a 21333µs cycle ≈ 0.94%.
    try t.expect(sample.dsp_load_pct > 0.9 and sample.dsp_load_pct < 1.0);
    // Idle-only input stays unavailable.
    const idle = parsePwTopBatch(
        "S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q   ERRORS  NAME\n" ++
            "R   33      0      0  ---     ---   ---   ---     0   Dummy-Driver\n",
    );
    try t.expect(!idle.available);
    try t.expectEqual(@as(f64, 0), pwTopUs("---"));
    try t.expectEqual(@as(i64, 0), pwTopErr("???"));
}

test "live-audio: pactl json cards parsing" {
    const t = std.testing;
    const text =
        \\{"index":0,"name":"alsa_card.usb","driver":"alsa","device.description":"USB DAC","active_profile":"pro-a","profiles":{"off":{"description":"Off"},"pro-a":{"description":"Analog"}}}
        \\{"index":1,"name":"bluez_card.AA","driver":"bluez","active_profile":"a2dp","profiles":{"a2dp":{"description":"High Fidelity"}}}
    ;
    // Reach in through queryAudioCards by faking pactl? No — exercise the
    // inner parsers directly on the two objects.
    var rest: []const u8 = text;
    var ncards: usize = 0;
    while (std.mem.indexOf(u8, rest, "{\"index\":")) |at| {
        ncards += 1;
        rest = rest[at + 1 ..];
    }
    try t.expectEqual(@as(usize, 2), ncards);
    const first = text[0 .. std.mem.indexOf(u8, text, "\n") orelse text.len];
    try t.expectEqual(@as(u32, 0), jsonUintField(first, "index").?);
    try t.expectEqualStrings("alsa_card.usb", jsonQuotedField(first, "name").?);
    try t.expectEqualStrings("USB DAC", jsonQuotedField(first, "device.description").?);
    try t.expect(jsonQuotedField(first, "missing") == null);
    const inner = cardProfilesInner(first).?;
    try t.expect(std.mem.indexOf(u8, inner, "\"off\"") != null);
}

test "live-audio: pw-dump cards parsing" {
    const t = std.testing;
    const text =
        \\[
        \\ { "id": 41, "type": "PipeWire:Interface:Device", "info": { "props": { "device.api": "alsa", "media.class": "Audio/Device", "device.name": "alsa_card.pci-0000", "device.description": "Family 17h HD Audio" }, "params": { "Profile": [ { "index": 1, "name": "output:analog" } ], "EnumProfile": [ { "index": 1, "name": "output:analog", "description": "Analog Stereo" }, { "index": 2, "name": "off", "description": "Off" } ] } } },
        \\ { "id": 109, "type": "PipeWire:Interface:Device", "info": { "props": { "device.api": "bluez5", "media.class": "Audio/Device", "device.name": "bluez_card.AA", "device.description": "Heavys H1H" }, "params": { "Profile": [ { "index": 131074, "name": "a2dp-sink-sbc_xq" } ], "EnumProfile": [ { "index": 131074, "name": "a2dp-sink-sbc_xq", "description": "High Fidelity Playback (A2DP Sink, codec SBC-XQ)" }, { "index": 131073, "name": "off", "description": "Off" } ] } } },
        \\ { "id": 121, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Audio/Sink", "device.api": "bluez5" } } },
        \\ { "id": 200, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Stream/Output/Audio" }, "params": { "Tag": [ { "info": [ 1, "media.name", "Playback" ], "info": [ 1, "media.name", "Playback" ] } ] } } },
        \\ { "id": 55, "type": "PipeWire:Interface:Device", "info": { "props": { "device.api": "v4l2", "media.class": "Video/Device", "device.name": "v4l2_card" } } }
        \\]
    ;
    const all = try parsePwDumpCards(t.allocator, text, false);
    defer freeAudioCards(t.allocator, all);
    try t.expectEqual(@as(usize, 1), all.len);
    try t.expectEqual(@as(u32, 41), all[0].card_index);
    try t.expectEqualStrings("alsa_card.pci-0000", all[0].card_key);
    try t.expectEqualStrings("Family 17h HD Audio", all[0].card_name);
    try t.expectEqualStrings("output:analog", all[0].active_profile_key);
    try t.expectEqual(@as(usize, 2), all[0].profiles.len);
    try t.expectEqualStrings("output:analog", all[0].profiles[0].key);
    try t.expectEqualStrings("Analog Stereo", all[0].profiles[0].description);
    try t.expectEqual(@as(i32, 1), all[0].profiles[0].index);

    const bt = try parsePwDumpCards(t.allocator, text, true);
    defer freeAudioCards(t.allocator, bt);
    try t.expectEqual(@as(usize, 1), bt.len);
    try t.expectEqual(@as(u32, 109), bt[0].card_index);
    try t.expectEqualStrings("bluez_card.AA", bt[0].card_key);
    try t.expectEqualStrings("Heavys H1H", bt[0].card_name);
    try t.expectEqualStrings("a2dp-sink-sbc_xq", bt[0].active_profile_key);
    try t.expectEqual(@as(i32, 131074), bt[0].profiles[0].index);

    // A card with no `device.description` falls back to `device.name`.
    const bare =
        \\[ { "id": 7, "type": "PipeWire:Interface:Device", "info": { "props": { "device.api": "alsa", "media.class": "Audio/Device", "device.name": "alsa_card.bare" }, "params": { "EnumProfile": [ { "index": 3, "name": "off", "description": "Off" } ] } } } ]
    ;
    const one = try parsePwDumpCards(t.allocator, bare, false);
    defer freeAudioCards(t.allocator, one);
    try t.expectEqual(@as(usize, 1), one.len);
    try t.expectEqualStrings("alsa_card.bare", one[0].card_name);

    // A card with no `params` at all is still listed (just no profile
    // combo): a mid-rescan daemon must not hide connected headphones.
    const ghost =
        \\[ { "id": 61, "type": "PipeWire:Interface:Device", "info": { "props": { "device.api": "bluez5", "media.class": "Audio/Device", "device.name": "bluez_card.ghost", "device.description": "Ghost Buds" } } } ]
    ;
    const g = try parsePwDumpCards(t.allocator, ghost, true);
    defer freeAudioCards(t.allocator, g);
    try t.expectEqual(@as(usize, 1), g.len);
    try t.expectEqualStrings("Ghost Buds", g[0].card_name);
    try t.expectEqual(@as(usize, 0), g[0].profiles.len);

    // Garbage / non-array input yields no cards rather than erroring.
    const none = try parsePwDumpCards(t.allocator, "not json", false);
    defer freeAudioCards(t.allocator, none);
    try t.expectEqual(@as(usize, 0), none.len);

    // `wpctl set-profile` resolves the profile name to its EnumProfile
    // index, scoped to the card's own id (dumps carry every device).
    try t.expectEqual(@as(?i32, 131073), pwDumpProfileIndex(t.allocator, text, 109, "off"));
    try t.expectEqual(@as(?i32, 131074), pwDumpProfileIndex(t.allocator, text, 109, "a2dp-sink-sbc_xq"));
    try t.expectEqual(@as(?i32, 2), pwDumpProfileIndex(t.allocator, text, 41, "off"));
    try t.expectEqual(@as(?i32, null), pwDumpProfileIndex(t.allocator, text, 109, "missing"));
    try t.expectEqual(@as(?i32, null), pwDumpProfileIndex(t.allocator, text, 999, "off"));
}

test "live-audio: pw-dump source nodes parsing" {
    const t = std.testing;
    const text =
        \\[
        \\ { "id": 54, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Audio/Source", "node.name": "alsa_input.usb-Insta360-02.mono-fallback", "node.description": "Insta360 Link 2 Mono" } } },
        \\ { "id": 67, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Audio/Source/Internal", "node.name": "alsa_input.hw_U192k_0", "node.description": "UMC202HD 192k 0" } } },
        \\ { "id": 61, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Audio/Source", "node.name": "alsa_input.usb-BEHRINGER_UMC202HD_192k-00.HiFi__Mic2__source", "node.nick": "UMC202HD 192k Input 2" } } },
        \\ { "id": 64, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Audio/Source", "node.name": "alsa_input.usb-BEHRINGER_UMC202HD_192k-00.HiFi__Mic1__source", "node.description": "UMC202HD 192k Input 1" } } },
        \\ { "id": 116, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Audio/Source", "node.name": "bluez_input.A8_99_DC_57_EF_0D", "node.description": "Heavys H1H" } } },
        \\ { "id": 120, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Audio/Sink", "node.name": "alsa_output.hdmi" } } },
        \\ { "id": 200, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Stream/Input/Audio" }, "params": { "Tag": [ { "info": [ 1, "media.name", "Rec" ], "info": [ 1, "media.name", "Rec" ] } ] } } },
        \\ { "id": 201, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Audio/Source" } } },
        \\ { "id": 202, "type": "PipeWire:Interface:Device", "info": { "props": { "media.class": "Audio/Source", "node.name": "card-not-node" } } }
        \\]
    ;
    // Only id 54 has a level from the status table; the rest default to
    // 100%, and 64 is `@DEFAULT_AUDIO_SOURCE@` via the filter row id.
    const levels = [_]Device{
        .{ .id = 54, .volume_pct = 82 },
        .{ .id = 67, .volume_pct = 40 },
    };
    var out: std.ArrayList(Device) = .empty;
    defer {
        freeDeviceItems(t.allocator, out.items);
        out.deinit(t.allocator);
    }
    try parsePwDumpSources(t.allocator, text, &levels, 64, &out);

    try t.expectEqual(@as(usize, 4), out.items.len);
    try t.expectEqualStrings("alsa_input.usb-Insta360-02.mono-fallback", out.items[0].name);
    try t.expectEqualStrings("Insta360 Link 2 Mono", out.items[0].description);
    try t.expectEqual(@as(i32, 82), out.items[0].volume_pct);
    try t.expect(!out.items[0].is_default);
    // `node.nick` is the description fallback.
    try t.expectEqualStrings("UMC202HD 192k Input 2", out.items[1].description);
    // The `Audio/Source/Internal` hw row and the sink/stream/device rows
    // are not defaultable capture devices.
    try t.expectEqualStrings("alsa_input.usb-BEHRINGER_UMC202HD_192k-00.HiFi__Mic1__source", out.items[2].name);
    try t.expectEqualStrings("UMC202HD 192k Input 1", out.items[2].description);
    try t.expect(out.items[2].is_default);
    try t.expectEqual(@as(i32, 100), out.items[2].volume_pct);
    try t.expectEqualStrings("bluez_input.A8_99_DC_57_EF_0D", out.items[3].name);
    try t.expectEqualStrings("Heavys H1H", out.items[3].description);

    // Garbage input leaves the list untouched instead of erroring.
    try parsePwDumpSources(t.allocator, "not json", &levels, 64, &out);
    try t.expectEqual(@as(usize, 4), out.items.len);

    // `wpctl set-default` needs the numeric id, so rows carrying a
    // `node.name` resolve through the dump before the retry.
    try t.expectEqual(@as(?u32, 64), pwDumpNodeIdByName(t.allocator, text, "alsa_input.usb-BEHRINGER_UMC202HD_192k-00.HiFi__Mic1__source"));
    try t.expectEqual(@as(?u32, 116), pwDumpNodeIdByName(t.allocator, text, "bluez_input.A8_99_DC_57_EF_0D"));
    try t.expectEqual(@as(?u32, 67), pwDumpNodeIdByName(t.allocator, text, "alsa_input.hw_U192k_0"));
    try t.expectEqual(@as(?u32, null), pwDumpNodeIdByName(t.allocator, "not json", "x"));
}

test "live-audio: card/profile helpers" {
    const t = std.testing;
    try t.expect(isBluetoothCard("bluez_card.AA_BB"));
    try t.expect(!isBluetoothCard("alsa_card.usb"));
    try t.expect(isVendorCodecProfile("a2dp-sink-aptx"));
    try t.expect(isVendorCodecProfile("LDAC HQ"));
    try t.expect(!isVendorCodecProfile("a2dp-sink"));
    try t.expect(!isVendorCodecProfile("off"));
}

test "live-audio: compat PCM sink probes" {
    const t = std.testing;
    const short =
        "45\talsa_output.usb-UMC\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED\n" ++
        "121\tbluez_output.A8\tPipeWire\ts16le 2ch 48000Hz\tRUNNING\n";
    try t.expectEqualStrings("s16le 2ch 48000Hz", pactlSinkSpec(short, "bluez_output.A8").?);
    try t.expectEqualStrings("s16le 2ch 48000Hz", pactlSinkSpec(short, "alsa_output.usb-UMC").?);
    try t.expect(pactlSinkSpec(short, "missing") == null);

    try t.expect(sinkPcmCapable(.{ .name = "alsa_output.usb-UMC", .api = "alsa" }));
    try t.expect(!sinkPcmCapable(.{ .name = "bluez_output.A8", .api = "bluez5" }));
    // pactl path: api unknown, the bluez prefix is the fallback signal.
    try t.expect(!sinkPcmCapable(.{ .name = "bluez_output.A8" }));
    try t.expect(sinkPcmCapable(.{ .name = "alsa_output.usb-UMC" }));

    const inspect_alsa =
        \\id 66, type PipeWire:Interface:Node
        \\    audio.format = "S24_LE"
        \\    device.api = "alsa"
        \\  * media.class = "Audio/Sink"
        \\  * node.name = "alsa_output.usb-UMC"
    ;
    const alsa = parseCompatSinkInspect(inspect_alsa).?;
    try t.expectEqual(@as(u32, 66), alsa.id);
    try t.expectEqualStrings("alsa_output.usb-UMC", alsa.name);
    try t.expectEqual(@as(i32, 1), alsa.choice);
    try t.expectEqualStrings("alsa", alsa.api);

    const inspect_bt =
        \\id 121, type PipeWire:Interface:Node
        \\    device.api = "bluez5"
        \\  * media.class = "Audio/Sink"
        \\  * node.name = "bluez_output.A8"
    ;
    const bt = parseCompatSinkInspect(inspect_bt).?;
    try t.expectEqual(@as(u32, 121), bt.id);
    try t.expectEqualStrings("bluez_output.A8", bt.name);
    try t.expectEqual(@as(i32, -1), bt.choice);
    try t.expectEqualStrings("bluez5", bt.api);
    try t.expect(parseCompatSinkInspect("id 1, type X") == null);

    // Bluez: no audio.format prop, negotiated transport lives in Format.
    const dump_bt =
        \\[ { "id": 121, "type": "PipeWire:Interface:Node", "info": { "props": { "media.class": "Audio/Sink" }, "params": { "Format": [ { "mediaType": "audio", "mediaSubtype": "raw", "format": "S16LE", "rate": 48000, "channels": 2 } ] } } } ]
    ;
    try t.expectEqual(@as(i32, 0), parsePwDumpNodeFormat(t.allocator, dump_bt));
    // ALSA: the configured audio.format prop wins over the enum/param.
    const dump_alsa =
        \\[ { "id": 66, "type": "PipeWire:Interface:Node", "info": { "props": { "audio.format": "F32_LE" }, "params": { "Format": [ { "format": "S16LE" } ] } } } ]
    ;
    try t.expectEqual(@as(i32, 3), parsePwDumpNodeFormat(t.allocator, dump_alsa));
    try t.expectEqual(@as(i32, -1), parsePwDumpNodeFormat(t.allocator, "not json"));
    try t.expectEqual(@as(i32, -1), parsePwDumpNodeFormat(t.allocator, "[]"));
}
