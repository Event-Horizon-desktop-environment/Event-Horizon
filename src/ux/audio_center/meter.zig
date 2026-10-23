//! Peak meters: one small capture stream per visible row.
//!
//! The mechanism mirrors what pavucontrol does through pulse. Each meter is
//! a record stream with `stream.monitor=true` (which libpipewire turns into
//! `resample.peaks`, so the adapter hands us per-sample peak magnitudes
//! instead of mixing audio) whose `target.object` is the node to watch: the
//! device node for sink/source rows, the stream node itself for
//! playback/recording rows. Sinks additionally need `stream.capture.sink`
//! so the link policy attaches to their monitor ports.
//!
//! All decoding happens in the stream's process callback, which the UI
//! thread drives through `Client.iterate`; the UI calls `tick()` once per
//! frame to decay the displayed level.

const std = @import("std");
const pw = @import("pipewire.zig");
const pod = @import("pod.zig");
const graph = @import("graph.zig");
const client_mod = @import("client.zig");

const log = std.log.scoped(.audio_center);

/// Time constant of a meter's falloff, in seconds: a bar drops to roughly a
/// tenth of a peak about a second after that audio stops.
const decay_tau: f32 = 0.45;

pub const Target = struct {
    id: u32,
    /// Capture a sink (its monitor mix); false captures a source or taps a
    /// stream node directly.
    sink: bool = false,
};

pub const Meter = struct {
    manager: *Manager,
    stream: *pw.pw_stream,
    target: Target,
    hook: pw.SpaHook = .{
        .link = .{ .next = null, .prev = null },
        .cb = .{ .funcs = null, .data = null },
        .removed = null,
        .priv = null,
    },
    fmt_buf: [256]u8 align(8) = undefined,
    /// Peak magnitudes seen since the last tick, accumulated at audio rate.
    raw: [2]f32 = .{ 0, 0 },
    /// Decayed level the UI should draw.
    level: [2]f32 = .{ 0, 0 },
    /// Negotiated stream format (Set Format pod).
    format: u32 = 0,
    rate: i32 = 0,
    channels: u32 = 0,
    warned_format: bool = false,
    debugged: bool = false,
};

pub const Manager = struct {
    alloc: std.mem.Allocator,
    client: *client_mod.Client,
    meters: std.ArrayList(*Meter),

    pub fn init(alloc: std.mem.Allocator, client: *client_mod.Client) Manager {
        return .{ .alloc = alloc, .client = client, .meters = .empty };
    }

    pub fn deinit(self: *Manager) void {
        for (self.meters.items) |m| self.destroyMeter(m);
        self.meters.deinit(self.alloc);
    }

    /// Create/destroy streams so exactly one meter exists per requested
    /// target. Returns true when the set changed (so the caller knows a
    /// frame of levels may be stale).
    pub fn setTargets(self: *Manager, targets: []const Target) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.meters.items.len) {
            const m = self.meters.items[i];
            if (!containsTarget(targets, m.target)) {
                self.destroyMeter(m);
                _ = self.meters.swapRemove(i);
                changed = true;
            } else {
                i += 1;
            }
        }
        for (targets) |t| {
            if (self.find(t) != null) continue;
            const m = self.createMeter(t) catch |e| {
                log.warn("meter for node {d} failed: {s}", .{ t.id, @errorName(e) });
                continue;
            };
            self.meters.append(self.alloc, m) catch {
                self.destroyMeter(m);
                continue;
            };
            changed = true;
        }
        return changed;
    }

    pub fn find(self: *Manager, t: Target) ?*Meter {
        for (self.meters.items) |m| {
            if (m.target.id == t.id and m.target.sink == t.sink) return m;
        }
        return null;
    }

    /// The displayed level for a node, or null when it has no meter.
    pub fn level(self: *Manager, id: u32) ?[2]f32 {
        for (self.meters.items) |m| {
            if (m.target.id == id) return m.level;
        }
        return null;
    }

    /// Decay every meter towards silence; call once per UI frame with the
    /// frame's duration in seconds. Peaks seen since the last tick win.
    pub fn tick(self: *Manager, dt: f32) void {
        const k: f32 = if (dt > 0) @exp(-dt / decay_tau) else 1;
        for (self.meters.items) |m| {
            for (0..2) |c| {
                m.level[c] = @max(m.raw[c], m.level[c] * k);
                m.raw[c] = 0;
            }
        }
    }

    // ── internals ───────────────────────────────────────────────────────────

    fn createMeter(self: *Manager, t: Target) !*Meter {
        const m = try self.alloc.create(Meter);
        errdefer self.alloc.destroy(m);
        m.* = .{ .manager = self, .stream = undefined, .target = t };

        // WirePlumber resolves `target.object` against the target's
        // `object.serial`, not its node id (this is also what the pulse
        // layer passes as a pulse index). Fall back to the id when the node
        // is not in our graph yet.
        const serial: u64 = if (self.client.g.findNode(t.id)) |n|
            (if (n.serial != 0) n.serial else n.id)
        else
            t.id;
        var id_buf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrintSentinel(&id_buf, "{d}", .{serial}, 0) catch return error.NameTooLong;
        const sink_str: [*:0]const u8 = if (t.sink) "true" else "false";
        const props = pw.pw_properties_new(
            "media.type",
            "Audio",
            "media.category",
            "Capture",
            "media.role",
            "Production",
            "application.name",
            graph.meter_app_name,
            "application.id",
            "org.eventhorizon.AudioCenter",
            "node.name",
            "eh-audio-center-meter",
            "node.description",
            "Event Horizon Audio Center meter",
            graph.meter_marker_key,
            "true",
            // Peak detection: the adapter hands us per-sample magnitudes.
            "stream.monitor",
            "true",
            // Don't keep an idle device awake just to draw its meter.
            "node.passive",
            "in-follow",
            "stream.capture.sink",
            sink_str,
            "target.object",
            id_str.ptr,
            @as(?[*:0]const u8, null),
        );
        if (props == null) return error.NoMemory;

        const stream = pw.pw_stream_new(self.client.core, "eh-audio-center-meter", props) orelse {
            pw.pw_properties_free(props.?);
            return error.StreamFailed;
        };
        m.stream = stream;
        _ = pw.pw_stream_add_listener(stream, &m.hook, &stream_events, m);

        const fmt = pod.audioEnumFormat(&m.fmt_buf, 48000, 2);
        var params: [1]?*const pw.spa_pod = .{@ptrCast(fmt)};
        const flags = pw.PW_STREAM_FLAG_AUTOCONNECT | pw.PW_STREAM_FLAG_MAP_BUFFERS | pw.PW_STREAM_FLAG_DONT_RECONNECT;
        _ = pw.pw_stream_connect(stream, pw.PW_DIRECTION_INPUT, pw.PW_ID_ANY, flags, &params, 1);
        return m;
    }

    fn destroyMeter(self: *Manager, m: *Meter) void {
        pw.pw_stream_destroy(m.stream);
        self.alloc.destroy(m);
    }

    fn containsTarget(targets: []const Target, t: Target) bool {
        for (targets) |o| {
            if (o.id == t.id and o.sink == t.sink) return true;
        }
        return false;
    }

    fn onProcess(data: ?*anyopaque) callconv(.c) void {
        const m: *Meter = @ptrCast(@alignCast(data.?));
        // The server may have queued more than one buffer since the last
        // frame; drain them all and keep the largest peak.
        while (pw.pw_stream_dequeue_buffer(m.stream)) |pb| {
            defer _ = pw.pw_stream_queue_buffer(m.stream, pb);
            const buf = pb.buffer orelse continue;
            const datas = buf.datas orelse continue;
            if (buf.n_datas == 0) continue;
            const d = &datas[0];
            const chunk = d.chunk orelse continue;
            const data_ptr = d.data orelse continue;
            const bytes: usize = chunk.size;
            if (bytes == 0) continue;
            const stride: usize = if (chunk.stride > 0) @intCast(chunk.stride) else 8;
            const nchan: usize = if (m.channels > 0) m.channels else @max(stride / 4, 1);
            if (nchan == 0) continue;
            if (m.format != 0 and m.format != pod.AUDIO_FORMAT_F32_LE) {
                if (!m.warned_format) {
                    m.warned_format = true;
                    log.warn("meter for node {d}: negotiated format 0x{x}, peaks disabled", .{ m.target.id, m.format });
                }
                continue;
            }
            const frames = bytes / stride;
            if (frames == 0) continue;
            const samples: [*]const f32 = @ptrCast(@alignCast(data_ptr));
            var peak: [2]f32 = .{ 0, 0 };
            for (0..frames) |f| {
                for (0..@min(nchan, 2)) |c| {
                    const v = @abs(samples[f * nchan + c]);
                    if (v > peak[c]) peak[c] = v;
                }
            }
            if (nchan == 1) peak[1] = peak[0];
            if (!m.debugged) {
                m.debugged = true;
                log.debug("meter node {d}: buffer size={d} stride={d} nchan={d} peaks L={d:.6} R={d:.6}", .{
                    m.target.id, bytes, stride, nchan, peak[0], peak[1],
                });
            }
            for (0..2) |c| {
                if (peak[c] > m.raw[c]) m.raw[c] = peak[c];
            }
        }
    }

    fn onParamChanged(data: ?*anyopaque, id: u32, param: ?*const pw.spa_pod) callconv(.c) void {
        const m: *Meter = @ptrCast(@alignCast(data.?));
        if (id != pod.PARAM_Format) return;
        const raw = param orelse return;
        const bytes: [*]const u8 = @ptrCast(raw);
        const sz = std.mem.readInt(u32, bytes[0..4], .little);
        if (sz < 8 or sz > 64 * 1024) return;
        const p: *const pod.Pod = @ptrCast(raw);
        if (pod.findProp(p, pod.FORMAT_AUDIO_format)) |f| m.format = pod.valueId(f);
        if (pod.findProp(p, pod.FORMAT_AUDIO_rate)) |r| m.rate = pod.valueInt(r);
        if (pod.findProp(p, pod.FORMAT_AUDIO_channels)) |c| m.channels = @intCast(@max(pod.valueInt(c), 0));
        if (m.format != 0 and !m.debugged) {
            m.debugged = true;
            log.debug("meter node {d}: negotiated format=0x{x} rate={d} channels={d}", .{ m.target.id, m.format, m.rate, m.channels });
        }
    }

    fn onStateChanged(data: ?*anyopaque, old: pw.pw_stream_state, state: pw.pw_stream_state, err: ?[*:0]const u8) callconv(.c) void {
        _ = old;
        if (state == pw.PW_STREAM_STATE_ERROR) {
            const m: *Meter = @ptrCast(@alignCast(data.?));
            log.warn("meter for node {d} error: {s}", .{ m.target.id, if (err) |e| std.mem.span(e) else "?" });
        }
    }

    const stream_events = pw.pw_stream_events{
        .state_changed = onStateChanged,
        .param_changed = onParamChanged,
        .process = onProcess,
    };
};

test "meter manager creates and reaps streams per target" {
    // The manager talks to a live core, so only the pure helper is unit
    // tested here; the stream wiring is exercised by `--meter` live probes.
    const a = Target{ .id = 5 };
    const b = Target{ .id = 9, .sink = true };
    const targets = [_]Target{ a, b };
    try std.testing.expect(Manager.containsTarget(&targets, a));
    try std.testing.expect(Manager.containsTarget(&targets, b));
    try std.testing.expect(!Manager.containsTarget(&targets, .{ .id = 5, .sink = true }));
    try std.testing.expect(!Manager.containsTarget(&targets, .{ .id = 6 }));
}
