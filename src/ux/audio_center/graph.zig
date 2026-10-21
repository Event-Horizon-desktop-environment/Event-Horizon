//! Live PipeWire graph model for the Audio Center.
//!
//! Owns the snapshot of nodes (sinks, sources, playback/recording streams),
//! devices (cards with profiles and routes), links (used to resolve which
//! device a stream is currently routed to) and the WirePlumber defaults
//! published through the "default" metadata object.
//!
//! Everything here is plain data + small functions so the whole thing is
//! unit-testable without a PipeWire daemon: the client feeds it registry and
//! param events, the UI reads it.

const std = @import("std");
const pw = @import("pipewire.zig");
const pod = @import("pod.zig");

pub const Str = struct {
    b: []u8 = &.{},

    pub fn get(self: *const Str) []const u8 {
        return self.b;
    }

    pub fn set(self: *Str, alloc: std.mem.Allocator, v: []const u8) !void {
        if (std.mem.eql(u8, self.b, v)) return;
        const n = try alloc.dupe(u8, v);
        if (self.b.len > 0) alloc.free(self.b);
        self.b = n;
    }

    pub fn deinit(self: *Str, alloc: std.mem.Allocator) void {
        if (self.b.len > 0) alloc.free(self.b);
        self.b = &.{};
    }
};

pub const Role = enum {
    sink,
    source,
    stream_playback,
    stream_record,
    other,

    pub fn isDevice(self: Role) bool {
        return self == .sink or self == .source;
    }
    pub fn isStream(self: Role) bool {
        return self == .stream_playback or self == .stream_record;
    }
};

/// Classify a node by its `media.class`.
pub fn roleForClass(class: []const u8) Role {
    if (std.mem.eql(u8, class, "Audio/Sink")) return .sink;
    if (std.mem.eql(u8, class, "Audio/Source")) return .source;
    if (std.mem.eql(u8, class, "Stream/Output/Audio")) return .stream_playback;
    if (std.mem.eql(u8, class, "Stream/Input/Audio")) return .stream_record;
    return .other;
}

/// Marker application name for our own meter capture streams; they are
/// hidden from the Recording list exactly like pavucontrol hides its own
/// peak-detect streams.
pub const meter_app_name = "Event Horizon Audio Center";
pub const meter_marker_key = "eh.audio_center.meter";

pub const max_channels = 8;

pub const Node = struct {
    id: u32 = 0,
    role: Role = .other,

    media_class: Str = .{},
    node_name: Str = .{},
    desc: Str = .{},
    nick: Str = .{},
    app_name: Str = .{},
    app_id: Str = .{},
    app_binary: Str = .{},
    app_icon: Str = .{},
    media_name: Str = .{},
    device_icon: Str = .{},

    device_id: u32 = pw.PW_ID_ANY,
    client_id: u32 = pw.PW_ID_ANY,
    /// `object.serial` — the id the pulse layer exposes (and what
    /// `target.object` must carry for moves).
    serial: u64 = 0,
    /// `card.profile.device` — the PCM index a hardware node maps to on its
    /// card; pipewire-pulse matches the card's active route by this value.
    card_profile_device: i32 = -1,
    state: pw.pw_node_state = pw.PW_NODE_STATE_CREATING,

    volume: f32 = 1.0,
    mute: bool = false,
    volumes: [max_channels]f32 = .{0} ** max_channels,
    chan_pos: [max_channels]u32 = .{0} ** max_channels,
    volume_count: u8 = 0,
    monitor_volumes: [max_channels]f32 = .{0} ** max_channels,
    monitor_volume_count: u8 = 0,
    monitor_mute: bool = false,
    have_props: bool = false,
    is_meter: bool = false,

    pub fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        self.media_class.deinit(alloc);
        self.node_name.deinit(alloc);
        self.desc.deinit(alloc);
        self.nick.deinit(alloc);
        self.app_name.deinit(alloc);
        self.app_id.deinit(alloc);
        self.app_binary.deinit(alloc);
        self.app_icon.deinit(alloc);
        self.media_name.deinit(alloc);
        self.device_icon.deinit(alloc);
        self.* = undefined;
    }

    pub fn isHardware(self: *const Node) bool {
        return self.device_id != pw.PW_ID_ANY;
    }

    /// `node.description` -> `node.nick` -> `node.name`, the same fallback
    /// order PipeWire tooling uses.
    pub fn displayName(self: *const Node) []const u8 {
        if (self.desc.b.len > 0) return self.desc.b;
        if (self.nick.b.len > 0) return self.nick.b;
        return self.node_name.b;
    }

    /// Label shown bold on stream rows: the application, falling back to the
    /// media title and finally the node name.
    pub fn streamTitle(self: *const Node) []const u8 {
        if (self.app_name.b.len > 0) return self.app_name.b;
        if (self.media_name.b.len > 0) return self.media_name.b;
        return self.displayName();
    }

    /// Secondary stream line (media title), empty when it repeats the title.
    pub fn streamSubtitle(self: *const Node) []const u8 {
        if (self.media_name.b.len == 0) return "";
        if (self.app_name.b.len == 0) return "";
        if (std.mem.eql(u8, self.media_name.b, self.app_name.b)) return "";
        return self.media_name.b;
    }

    /// Per-channel display volume as a 0..1.5+ ratio in the "pulse" scale,
    /// i.e. the cubic root of the linear amplitude PipeWire applies.
    pub fn channelVolume(self: *const Node, i: usize) f32 {
        if (i >= self.volume_count) return 0;
        return amplitudeRatio(self.volumes[i]);
    }
};

/// The "pulse" display ratio for a linear amplitude (slider position).
pub fn amplitudeRatio(amplitude: f32) f32 {
    if (amplitude <= 0) return 0;
    return std.math.cbrt(amplitude);
}

/// Linear amplitude for a "pulse" display ratio (what channelVolumes store).
pub fn ratioAmplitude(ratio: f32) f32 {
    if (ratio <= 0) return 0;
    return ratio * ratio * ratio;
}

/// Control-tool clients whose streams pavucontrol hides from the Recording
/// tab (its own peak-detect meters and the GNOME/KDE mixers).
pub fn isControlToolApp(app_id: []const u8) bool {
    return std.mem.eql(u8, app_id, "org.PulseAudio.pavucontrol") or
        std.mem.eql(u8, app_id, "org.gnome.VolumeControl") or
        std.mem.eql(u8, app_id, "org.kde.kmixd");
}

/// The volume/mute a device row shows, and the object a write must go to.
pub const VolumeTarget = struct {
    n_volumes: u8 = 0,
    volumes: [max_channels]f32 = .{0} ** max_channels,
    mute: bool = false,
    /// Card route that owns the volume (0 = node Props are the target).
    card_id: u32 = 0,
    route_index: i32 = -1,
    route_device: i32 = -1,
    monitor: bool = false,
};

pub const Route = struct {
    index: i32 = 0,
    direction: u32 = 0,
    name: Str = .{},
    desc: Str = .{},
    priority: i32 = 0,
    available: u32 = pod.availability_unknown,
    device: i32 = -1,
    /// Profiles this route belongs to (enum-route `profiles` array).
    profiles: [8]i32 = .{-1} ** 8,
    n_profiles: u8 = 0,
    /// Card devices (PCMs) this route applies to (enum-route `devices`).
    devices: [8]i32 = .{-1} ** 8,
    n_devices: u8 = 0,

    pub fn deinit(self: *Route, alloc: std.mem.Allocator) void {
        self.name.deinit(alloc);
        self.desc.deinit(alloc);
    }

    pub fn label(self: *const Route) []const u8 {
        if (self.desc.b.len > 0) return self.desc.b;
        return self.name.b;
    }

    /// The port filter pipewire-pulse applies before showing routes for a
    /// sink/source: right direction, part of the active profile and relevant
    /// to the node's current `card.profile.device`.
    pub fn visibleFor(self: *const Route, direction: u32, active_profile: i32, card_device: i32) bool {
        if (self.direction != direction) return false;
        if (self.n_profiles > 0 and active_profile >= 0 and !containsInt(self.profiles[0..self.n_profiles], active_profile)) return false;
        if (self.n_devices > 0 and card_device >= 0 and !containsInt(self.devices[0..self.n_devices], card_device)) return false;
        return true;
    }

    fn containsInt(haystack: []const i32, needle: i32) bool {
        for (haystack) |v| {
            if (v == needle) return true;
        }
        return false;
    }
};

pub const Profile = struct {
    index: i32 = 0,
    name: Str = .{},
    desc: Str = .{},
    priority: i32 = 0,
    available: u32 = pod.availability_unknown,

    pub fn deinit(self: *Profile, alloc: std.mem.Allocator) void {
        self.name.deinit(alloc);
        self.desc.deinit(alloc);
    }

    pub fn label(self: *const Profile) []const u8 {
        if (self.desc.b.len > 0) return self.desc.b;
        return self.name.b;
    }
};

/// A card's currently selected route (SPA_PARAM_Route), including the
/// `props` sub-object that carries the volume for hardware devices.
pub const RouteVolume = struct {
    index: i32 = -1,
    device: i32 = -1,
    has_props: bool = false,
    n_volumes: u8 = 0,
    volumes: [max_channels]f32 = .{0} ** max_channels,
    mute: bool = false,
};

pub const Device = struct {
    id: u32 = 0,
    media_class: Str = .{},
    device_name: Str = .{},
    desc: Str = .{},
    nick: Str = .{},
    api: Str = .{},
    icon: Str = .{},
    active_profile: i32 = -1,
    active_route: i32 = -1,
    /// Active route per direction: 0 = input (sources), 1 = output (sinks).
    active_in: RouteVolume = .{},
    active_out: RouteVolume = .{},
    routes: std.ArrayList(Route) = .empty,
    profiles: std.ArrayList(Profile) = .empty,

    pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
        self.media_class.deinit(alloc);
        self.device_name.deinit(alloc);
        self.desc.deinit(alloc);
        self.nick.deinit(alloc);
        self.api.deinit(alloc);
        self.icon.deinit(alloc);
        for (self.routes.items) |*r| r.deinit(alloc);
        self.routes.deinit(alloc);
        for (self.profiles.items) |*p| p.deinit(alloc);
        self.profiles.deinit(alloc);
        self.* = undefined;
    }

    pub fn activeRouteFor(self: *const Device, direction: u32) *const RouteVolume {
        return if (direction == 0) &self.active_in else &self.active_out;
    }

    pub fn displayName(self: *const Device) []const u8 {
        if (self.desc.b.len > 0) return self.desc.b;
        if (self.nick.b.len > 0) return self.nick.b;
        return self.device_name.b;
    }

    pub fn isAudioCard(self: *const Device) bool {
        return std.mem.eql(u8, self.media_class.b, "Audio/Device");
    }

    pub fn findRoute(self: *const Device, index: i32, direction: u32) ?*const Route {
        for (self.routes.items) |*r| {
            if (r.index == index and r.direction == direction) return r;
        }
        return null;
    }

    pub fn findProfile(self: *const Device, index: i32) ?*const Profile {
        for (self.profiles.items) |*p| {
            if (p.index == index) return p;
        }
        return null;
    }
};

pub const Link = struct {
    id: u32 = 0,
    out_node: u32 = 0,
    out_port: u32 = 0,
    in_node: u32 = 0,
    in_port: u32 = 0,
    state: i32 = 0,
};

pub const ID_ANY = pw.PW_ID_ANY;

pub const Graph = struct {
    alloc: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    devices: std.ArrayList(Device) = .empty,
    links: std.ArrayList(Link) = .empty,

    default_sink: Str = .{},
    default_source: Str = .{},

    /// Bumped on every mutation; the window repaints when it changes.
    generation: u64 = 1,
    /// True once the first metadata snapshot arrived.
    have_defaults: bool = false,

    pub fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |*n| n.deinit(self.alloc);
        self.nodes.deinit(self.alloc);
        for (self.devices.items) |*d| d.deinit(self.alloc);
        self.devices.deinit(self.alloc);
        self.links.deinit(self.alloc);
        self.default_sink.deinit(self.alloc);
        self.default_source.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn touch(self: *Graph) void {
        self.generation +%= 1;
    }

    // ── lookup ──────────────────────────────────────────────────────────────

    pub fn findNode(self: *Graph, id: u32) ?*Node {
        for (self.nodes.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    pub fn findDevice(self: *Graph, id: u32) ?*Device {
        for (self.devices.items) |*d| {
            if (d.id == id) return d;
        }
        return null;
    }

    pub fn findLink(self: *Graph, id: u32) ?*Link {
        for (self.links.items) |*l| {
            if (l.id == id) return l;
        }
        return null;
    }

    /// Where a device row's volume/mute actually lives, mirroring
    /// pipewire-pulse exactly: the active card route's `props` when the route
    /// carries them (`card.profile.device` matching), else the node's own
    /// Props. Monitor sources read the node's monitorVolumes instead.
    pub fn volumeTarget(self: *Graph, node: *const Node, monitor: bool) VolumeTarget {
        var t = VolumeTarget{
            .n_volumes = node.volume_count,
            .volumes = node.volumes,
            .mute = node.mute,
        };
        if (monitor) {
            t.monitor = true;
            t.n_volumes = node.monitor_volume_count;
            t.volumes = node.monitor_volumes;
            t.mute = node.monitor_mute;
            return t;
        }
        if (node.device_id == pw.PW_ID_ANY or node.card_profile_device < 0) return t;
        const dev = self.findDevice(node.device_id) orelse return t;
        const dir: u32 = if (node.role == .source) 0 else 1;
        var rv = dev.activeRouteFor(dir);
        if (rv.device != node.card_profile_device) {
            const other = dev.activeRouteFor(if (dir == 0) 1 else 0);
            if (other.device == node.card_profile_device) rv = other else return t;
        }
        if (rv.index < 0) return t;
        t.card_id = dev.id;
        t.route_index = rv.index;
        t.route_device = rv.device;
        if (rv.has_props and rv.n_volumes > 0) {
            t.n_volumes = rv.n_volumes;
            t.volumes = rv.volumes;
            t.mute = rv.mute;
        }
        return t;
    }

    // ── mutations ───────────────────────────────────────────────────────────

    pub fn upsertNode(self: *Graph, id: u32) !*Node {
        if (self.findNode(id)) |n| return n;
        try self.nodes.append(self.alloc, .{ .id = id });
        return &self.nodes.items[self.nodes.items.len - 1];
    }

    pub fn upsertDevice(self: *Graph, id: u32) !*Device {
        if (self.findDevice(id)) |d| return d;
        try self.devices.append(self.alloc, .{ .id = id });
        return &self.devices.items[self.devices.items.len - 1];
    }

    pub fn removeNode(self: *Graph, id: u32) void {
        for (self.nodes.items, 0..) |*n, i| {
            if (n.id == id) {
                n.deinit(self.alloc);
                _ = self.nodes.swapRemove(i);
                self.touch();
                return;
            }
        }
    }

    pub fn removeDevice(self: *Graph, id: u32) void {
        for (self.devices.items, 0..) |*d, i| {
            if (d.id == id) {
                d.deinit(self.alloc);
                _ = self.devices.swapRemove(i);
                self.touch();
                return;
            }
        }
    }

    pub fn removeLink(self: *Graph, id: u32) void {
        for (self.links.items, 0..) |*l, i| {
            if (l.id == id) {
                _ = self.links.swapRemove(i);
                self.touch();
                return;
            }
        }
    }

    pub fn upsertLink(self: *Graph, link: Link) !void {
        if (self.findLink(link.id)) |l| {
            l.* = link;
        } else {
            try self.links.append(self.alloc, link);
        }
        self.touch();
    }

    /// Track a node global only when the media class is one we show.
    pub fn nodeTracked(self: *const Graph, id: u32) bool {
        return self.findNodeConst(id) != null;
    }

    fn findNodeConst(self: *const Graph, id: u32) ?*const Node {
        for (self.nodes.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    // ── props application ───────────────────────────────────────────────────

    pub fn applyNodeDict(self: *Graph, node: *Node, dict: ?*const pw.spa_dict) !void {
        const a = self.alloc;
        if (pw.dictGetLast(dict, "media.class")) |v| try node.media_class.set(a, v);
        if (pw.dictGetLast(dict, "node.name")) |v| try node.node_name.set(a, v);
        if (pw.dictGetLast(dict, "node.description")) |v| try node.desc.set(a, v);
        if (pw.dictGetLast(dict, "node.nick")) |v| try node.nick.set(a, v);
        if (pw.dictGetLast(dict, "application.name")) |v| try node.app_name.set(a, v);
        if (pw.dictGetLast(dict, "application.id")) |v| try node.app_id.set(a, v);
        if (pw.dictGetLast(dict, "application.process.binary")) |v| try node.app_binary.set(a, v);
        if (pw.dictGetLast(dict, "application.icon-name")) |v| try node.app_icon.set(a, v);
        if (pw.dictGetLast(dict, "media.name")) |v| try node.media_name.set(a, v);
        if (pw.dictGetLast(dict, "device.icon_name")) |v| try node.device_icon.set(a, v);
        if (pw.dictGetLast(dict, "card.profile.device")) |v| {
            node.card_profile_device = std.fmt.parseInt(i32, v, 10) catch -1;
        }
        if (pw.dictGetLast(dict, "object.serial")) |v| {
            node.serial = std.fmt.parseInt(u64, v, 10) catch 0;
        }
        if (pw.dictGetLast(dict, "device.id")) |v| {
            node.device_id = std.fmt.parseInt(u32, v, 10) catch pw.PW_ID_ANY;
        }
        if (pw.dictGetLast(dict, "client.id")) |v| {
            node.client_id = std.fmt.parseInt(u32, v, 10) catch pw.PW_ID_ANY;
        }
        if (node.media_class.b.len > 0) node.role = roleForClass(node.media_class.b);
        const marker = pw.dictGetLast(dict, meter_marker_key);
        if (marker) |m| {
            node.is_meter = std.mem.eql(u8, m, "true") or std.mem.eql(u8, m, "1");
        } else if (std.mem.eql(u8, node.app_name.b, meter_app_name)) {
            node.is_meter = true;
        }
        self.touch();
    }

    pub fn applyDeviceDict(self: *Graph, dev: *Device, dict: ?*const pw.spa_dict) !void {
        const a = self.alloc;
        if (pw.dictGetLast(dict, "media.class")) |v| try dev.media_class.set(a, v);
        if (pw.dictGetLast(dict, "device.name")) |v| try dev.device_name.set(a, v);
        if (pw.dictGetLast(dict, "device.description")) |v| try dev.desc.set(a, v);
        if (pw.dictGetLast(dict, "device.nick")) |v| try dev.nick.set(a, v);
        if (pw.dictGetLast(dict, "device.api")) |v| try dev.api.set(a, v);
        if (pw.dictGetLast(dict, "device.icon_name")) |v| try dev.icon.set(a, v);
        self.touch();
    }

    /// Apply a SPA_PARAM_Props pod (volume, mute, channelVolumes, channelMap).
    pub fn applyNodeProps(self: *Graph, node: *Node, p: *const pod.Pod) void {
        if (pod.objectType(p) != pod.OBJECT_Props) return;
        if (pod.findProp(p, pod.PROP_volume)) |vp| node.volume = pod.valueFloat(vp);
        if (pod.findProp(p, pod.PROP_mute)) |mp| node.mute = pod.valueBool(mp);
        if (pod.findProp(p, pod.PROP_channelVolumes)) |cv| {
            const vals = pod.valueFloatArray(cv);
            const n = @min(vals.len, max_channels);
            for (0..n) |i| node.volumes[i] = vals[i];
            node.volume_count = @intCast(n);
        }
        if (pod.findProp(p, pod.PROP_channelMap)) |cm| {
            const vals = pod.valueIdArray(cm);
            const n = @min(vals.len, max_channels);
            for (0..n) |i| node.chan_pos[i] = vals[i];
        }
        if (pod.findProp(p, pod.PROP_monitorVolumes)) |mv| {
            const vals = pod.valueFloatArray(mv);
            const n = @min(vals.len, max_channels);
            for (0..n) |i| node.monitor_volumes[i] = vals[i];
            node.monitor_volume_count = @intCast(n);
        }
        if (pod.findProp(p, pod.PROP_monitorMute)) |mm| node.monitor_mute = pod.valueBool(mm);
        node.have_props = true;
        self.touch();
    }

    /// Apply a SPA_PARAM_Profile pod to a device (active profile).
    pub fn applyDeviceProfile(self: *Graph, dev: *Device, p: *const pod.Pod) void {
        if (pod.objectType(p) != pod.OBJECT_ParamProfile) return;
        if (pod.objectId(p) == pod.PARAM_Profile) {
            if (pod.findProp(p, pod.PROFILE_index)) |ip| {
                dev.active_profile = pod.valueInt(ip);
                self.touch();
            }
            return;
        }
        if (pod.objectId(p) != pod.PARAM_EnumProfile) return;
        const index = if (pod.findProp(p, pod.PROFILE_index)) |ip| pod.valueInt(ip) else return;
        for (dev.profiles.items) |*pr| {
            if (pr.index == index) {
                if (pod.findProp(p, pod.PROFILE_name)) |np| pr.name.set(self.alloc, pod.valueString(np)) catch {};
                if (pod.findProp(p, pod.PROFILE_description)) |dp| pr.desc.set(self.alloc, pod.valueString(dp)) catch {};
                if (pod.findProp(p, pod.PROFILE_priority)) |pp| pr.priority = pod.valueInt(pp);
                if (pod.findProp(p, pod.PROFILE_available)) |ap| pr.available = pod.valueId(ap);
                self.touch();
                return;
            }
        }
        var prof = Profile{ .index = index };
        if (pod.findProp(p, pod.PROFILE_name)) |np| prof.name.set(self.alloc, pod.valueString(np)) catch {};
        if (pod.findProp(p, pod.PROFILE_description)) |dp| prof.desc.set(self.alloc, pod.valueString(dp)) catch {};
        if (pod.findProp(p, pod.PROFILE_priority)) |pp| prof.priority = pod.valueInt(pp);
        if (pod.findProp(p, pod.PROFILE_available)) |ap| prof.available = pod.valueId(ap);
        dev.profiles.append(self.alloc, prof) catch {};
        self.touch();
    }

    /// Apply a SPA_PARAM_Route / SPA_PARAM_EnumRoute pod to a device.
    pub fn applyDeviceRoute(self: *Graph, dev: *Device, p: *const pod.Pod) void {
        if (pod.objectType(p) != pod.OBJECT_ParamRoute) return;
        switch (pod.objectId(p)) {
            pod.PARAM_EnumRoute => self.applyDeviceRouteEnum(dev, p),
            pod.PARAM_Route => self.applyDeviceRouteActive(dev, p),
            else => {},
        }
    }

    fn applyDeviceRouteEnum(self: *Graph, dev: *Device, p: *const pod.Pod) void {
        const index = if (pod.findProp(p, pod.ROUTE_index)) |ip| pod.valueInt(ip) else return;
        const direction = if (pod.findProp(p, pod.ROUTE_direction)) |dp| pod.valueId(dp) else 0;
        for (dev.routes.items) |*r| {
            if (r.index == index and r.direction == direction) {
                self.updateRouteFields(r, p);
                self.touch();
                return;
            }
        }
        var route = Route{ .index = index, .direction = direction };
        self.updateRouteFields(&route, p);
        dev.routes.append(self.alloc, route) catch {};
        self.touch();
    }

    /// The active SPA_PARAM_Route carries the selected route plus, for
    /// hardware devices, the `props` object holding the volume/mute that the
    /// pulse layer reads and writes (pavucontrol sliders live there).
    fn applyDeviceRouteActive(self: *Graph, dev: *Device, p: *const pod.Pod) void {
        const index = if (pod.findProp(p, pod.ROUTE_index)) |ip| pod.valueInt(ip) else return;
        const direction = if (pod.findProp(p, pod.ROUTE_direction)) |dp| pod.valueId(dp) else 0;

        var rv = RouteVolume{ .index = index };
        if (pod.findProp(p, pod.ROUTE_device)) |dv| rv.device = pod.valueInt(dv);
        if (pod.findProp(p, pod.ROUTE_props)) |pp| {
            if (pp.value.pod_type == pod.TYPE_OBJECT) {
                rv.has_props = true;
                const inner: *const pod.Pod = &pp.value;
                if (pod.findProp(inner, pod.PROP_channelVolumes)) |cv| {
                    const vals = pod.valueFloatArray(cv);
                    const n = @min(vals.len, max_channels);
                    for (0..n) |i| rv.volumes[i] = vals[i];
                    rv.n_volumes = @intCast(n);
                }
                if (pod.findProp(inner, pod.PROP_mute)) |mp| rv.mute = pod.valueBool(mp);
            }
        }
        if (direction == 0) dev.active_in = rv else dev.active_out = rv;
        dev.active_route = index;
        self.touch();
    }

    fn updateRouteFields(self: *Graph, r: *Route, p: *const pod.Pod) void {
        if (pod.findProp(p, pod.ROUTE_name)) |np| r.name.set(self.alloc, pod.valueString(np)) catch {};
        if (pod.findProp(p, pod.ROUTE_description)) |dp| r.desc.set(self.alloc, pod.valueString(dp)) catch {};
        if (pod.findProp(p, pod.ROUTE_priority)) |pp| r.priority = pod.valueInt(pp);
        if (pod.findProp(p, pod.ROUTE_available)) |ap| r.available = pod.valueId(ap);
        if (pod.findProp(p, pod.ROUTE_device)) |dvp| r.device = pod.valueInt(dvp);
        if (pod.findProp(p, pod.ROUTE_profiles)) |pf| {
            const vals = pod.valueIntArray(pf);
            const n = @min(vals.len, r.profiles.len);
            for (0..n) |i| r.profiles[i] = vals[i];
            r.n_profiles = @intCast(n);
        }
        if (pod.findProp(p, pod.ROUTE_devices)) |dv| {
            const vals = pod.valueIntArray(dv);
            const n = @min(vals.len, r.devices.len);
            for (0..n) |i| r.devices[i] = vals[i];
            r.n_devices = @intCast(n);
        }
    }

    /// Drop routes/profiles that were not seen in the latest enumeration
    /// round. `seen` marks indices by `(index, direction)` for routes and by
    /// index for profiles.
    pub fn pruneRoutes(self: *Graph, dev: *Device, seen: []const Route) void {
        var i: usize = 0;
        while (i < dev.routes.items.len) {
            const r = dev.routes.items[i];
            var found = false;
            for (seen) |s| {
                if (s.index == r.index and s.direction == r.direction) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                dev.routes.items[i].deinit(self.alloc);
                _ = dev.routes.swapRemove(i);
                self.touch();
            } else i += 1;
        }
    }

    pub fn pruneProfiles(self: *Graph, dev: *Device, seen: []const i32) void {
        var i: usize = 0;
        while (i < dev.profiles.items.len) {
            const p = dev.profiles.items[i];
            var found = false;
            for (seen) |s| {
                if (s == p.index) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                dev.profiles.items[i].deinit(self.alloc);
                _ = dev.profiles.swapRemove(i);
                self.touch();
            } else i += 1;
        }
    }

    pub fn setDefaultSink(self: *Graph, name: []const u8) !void {
        try self.default_sink.set(self.alloc, name);
        self.have_defaults = true;
        self.touch();
    }

    pub fn setDefaultSource(self: *Graph, name: []const u8) !void {
        try self.default_source.set(self.alloc, name);
        self.have_defaults = true;
        self.touch();
    }

    /// Resolve the default sink node from its name.
    pub fn defaultSinkNode(self: *Graph) ?*Node {
        if (self.default_sink.b.len == 0) return null;
        for (self.nodes.items) |*n| {
            if (n.role == .sink and std.mem.eql(u8, n.node_name.b, self.default_sink.b)) return n;
        }
        return null;
    }

    pub fn defaultSourceNode(self: *Graph) ?*Node {
        if (self.default_source.b.len == 0) return null;
        for (self.nodes.items) |*n| {
            if (n.role == .source and std.mem.eql(u8, n.node_name.b, self.default_source.b)) return n;
        }
        return null;
    }

    /// Which sink is a playback stream currently linked to (first link into a
    /// sink node wins — mirrors "the device the stream plays on").
    pub fn sinkForStream(self: *Graph, stream_id: u32) ?u32 {
        for (self.links.items) |l| {
            if (l.out_node != stream_id) continue;
            if (self.findNode(l.in_node)) |n| {
                if (n.role == .sink) return n.id;
            }
        }
        return null;
    }

    /// Which source a recording stream is currently linked from.
    pub fn sourceForStream(self: *Graph, stream_id: u32) ?u32 {
        for (self.links.items) |l| {
            if (l.in_node != stream_id) continue;
            if (self.findNode(l.out_node)) |n| {
                if (n.role == .source) return n.id;
            }
        }
        return null;
    }

    /// Sinks in stable display order, plus iteration helpers for the UI.
    pub fn countRole(self: *const Graph, role: Role) usize {
        var n: usize = 0;
        for (self.nodes.items) |*node| {
            if (node.role == role) n += 1;
        }
        return n;
    }
};

// ── metadata value parsing ──────────────────────────────────────────────────

/// Extract the first `"name"` string out of a WirePlumber metadata value
/// such as `{"name":"bluez_output.A8_99_DC_57_EF_0D.1"}`. Returns a slice of
/// `value` (no allocation).
pub fn metadataName(value: []const u8) ?[]const u8 {
    const key = "\"name\"";
    const kpos = std.mem.indexOf(u8, value, key) orelse return null;
    var i = kpos + key.len;
    while (i < value.len and (value[i] == ' ' or value[i] == ':')) i += 1;
    if (i >= value.len or value[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < value.len) : (i += 1) {
        if (value[i] == '\\') {
            i += 1;
            continue;
        }
        if (value[i] == '"') return value[start..i];
    }
    return null;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "role classification follows media.class" {
    try testing.expectEqual(Role.sink, roleForClass("Audio/Sink"));
    try testing.expectEqual(Role.source, roleForClass("Audio/Source"));
    try testing.expectEqual(Role.stream_playback, roleForClass("Stream/Output/Audio"));
    try testing.expectEqual(Role.stream_record, roleForClass("Stream/Input/Audio"));
    try testing.expectEqual(Role.other, roleForClass("Stream/Input/Audio/Internal"));
    try testing.expectEqual(Role.other, roleForClass("Midi/Bridge"));
}

test "metadata name extraction" {
    try testing.expectEqualStrings("bluez_output.A8_99_DC_57_EF_0D.1", metadataName("{\"name\":\"bluez_output.A8_99_DC_57_EF_0D.1\"}").?);
    try testing.expectEqualStrings("alsa no quotes", metadataName("{\"name\" : \"alsa no quotes\"}").?);
    try testing.expectEqualStrings("a\\\"b", metadataName("{\"name\":\"a\\\"b\"}").?);
    try testing.expect(metadataName("{\"index\":2}") == null);
    try testing.expect(metadataName("") == null);
}

fn dictOf(comptime pairs: []const [2][:0]const u8) [pairs.len]pw.spa_dict_item {
    var items: [pairs.len]pw.spa_dict_item = undefined;
    inline for (pairs, 0..) |p, i| {
        items[i] = .{ .key = p[0].ptr, .value = p[1].ptr };
    }
    return items;
}

test "node dict application and fallbacks" {
    const items = dictOf(&.{
        .{ "media.class", "Stream/Output/Audio" },
        .{ "node.name", "output.vesktop" },
        .{ "application.name", "Vesktop" },
        .{ "media.name", "Overworld Theme" },
        .{ "application.process.binary", "vesktop" },
        .{ "device.id", "0" },
        .{ "client.id", "222" },
    });
    var dict = pw.spa_dict{ .flags = 0, .n_items = items.len, .items = &items };

    var g = Graph.init(testing.allocator);
    defer g.deinit();
    const node = try g.upsertNode(206);
    try g.applyNodeDict(node, &dict);
    try testing.expectEqual(Role.stream_playback, node.role);
    try testing.expectEqualStrings("Vesktop", node.streamTitle());
    try testing.expectEqualStrings("Overworld Theme", node.streamSubtitle());
    try testing.expectEqual(@as(u32, 0), node.device_id);
    try testing.expectEqual(@as(u32, 222), node.client_id);
    try testing.expect(!node.is_meter);

    // Re-apply with fewer props: existing values persist, fallbacks still win.
    var small = pw.spa_dict{ .flags = 0, .n_items = 2, .items = &items };
    small.items = items[0..2].ptr;
    const node2 = try g.upsertNode(207);
    try g.applyNodeDict(node2, &small);
    try testing.expectEqual(Role.stream_playback, node2.role);
    try testing.expectEqualStrings("output.vesktop", node2.displayName());
    try testing.expectEqualStrings("output.vesktop", node2.streamTitle());
}

test "meter streams are recognised by marker or app name" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    const items_a = dictOf(&.{
        .{ "media.class", "Stream/Input/Audio" },
        .{ "application.name", "Event Horizon Audio Center" },
    });
    const items_b = dictOf(&.{
        .{ "media.class", "Stream/Input/Audio" },
        .{ "application.name", "Something Else" },
        .{ "eh.audio_center.meter", "true" },
    });
    var da = pw.spa_dict{ .flags = 0, .n_items = items_a.len, .items = &items_a };
    var db = pw.spa_dict{ .flags = 0, .n_items = items_b.len, .items = &items_b };
    const na = try g.upsertNode(1);
    try g.applyNodeDict(na, &da);
    const nb = try g.upsertNode(2);
    try g.applyNodeDict(nb, &db);
    try testing.expect(na.is_meter);
    try testing.expect(nb.is_meter);
}

test "props pod application (volume, mute, channels)" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    const node = try g.upsertNode(121);
    node.role = .sink;

    var buf: [256]u8 align(8) = undefined;
    var b = pod.Builder.init(&buf);
    b.beginObject(pod.OBJECT_Props, pod.PARAM_Props);
    b.propFloat(pod.PROP_volume, 0.65);
    b.propBool(pod.PROP_mute, true);
    b.propFloatArray(pod.PROP_channelVolumes, &.{ 0.274625, 0.274625 });
    b.propIdArray(pod.PROP_channelMap, &.{ 3, 4 });
    const p = b.endObject();
    g.applyNodeProps(node, p);

    try testing.expectApproxEqAbs(@as(f32, 0.65), node.volume, 1e-6);
    try testing.expect(node.mute);
    try testing.expectEqual(@as(u8, 2), node.volume_count);
    try testing.expectApproxEqAbs(@as(f32, 0.65), node.channelVolume(0), 1e-5);
    try testing.expectEqual(@as(u32, 4), node.chan_pos[1]);
}

test "route and profile pods fill device tables" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    const dev = try g.upsertDevice(49);
    try dev.media_class.set(testing.allocator, "Audio/Device");

    var buf: [512]u8 align(8) = undefined;
    var b = pod.Builder.init(&buf);
    b.beginObject(pod.OBJECT_ParamRoute, pod.PARAM_EnumRoute);
    b.propInt(pod.ROUTE_index, 0);
    b.propId(pod.ROUTE_direction, 1);
    b.propString(pod.ROUTE_name, "analog-stereo");
    b.propString(pod.ROUTE_description, "Analog Stereo");
    b.propId(pod.ROUTE_available, pod.availability_yes);
    g.applyDeviceRoute(dev, b.endObject());
    try testing.expectEqual(@as(usize, 1), dev.routes.items.len);
    try testing.expectEqualStrings("Analog Stereo", dev.routes.items[0].label());
    try testing.expectEqual(@as(u32, pod.availability_yes), dev.routes.items[0].available);

    var b2 = pod.Builder.init(&buf);
    b2.beginObject(pod.OBJECT_ParamProfile, pod.PARAM_EnumProfile);
    b2.propInt(pod.PROFILE_index, 131073);
    b2.propString(pod.PROFILE_name, "HiFi");
    b2.propString(pod.PROFILE_description, "Hi-Fi (2.0)");
    b2.propId(pod.PROFILE_available, pod.availability_yes);
    g.applyDeviceProfile(dev, b2.endObject());
    try testing.expectEqual(@as(usize, 1), dev.profiles.items.len);
    try testing.expectEqualStrings("Hi-Fi (2.0)", dev.profiles.items[0].label());

    var b3 = pod.Builder.init(&buf);
    b3.beginObject(pod.OBJECT_ParamProfile, pod.PARAM_Profile);
    b3.propInt(pod.PROFILE_index, 131073);
    g.applyDeviceProfile(dev, b3.endObject());
    try testing.expectEqual(@as(i32, 131073), dev.active_profile);
}

test "active route carries the pulse volume target" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    const dev = try g.upsertDevice(47);
    var buf: [512]u8 align(8) = undefined;

    // Active output route: index 0, device 4, props with channelVolumes.
    var b = pod.Builder.init(&buf);
    b.beginObject(pod.OBJECT_ParamRoute, pod.PARAM_Route);
    b.propInt(pod.ROUTE_index, 0);
    b.propId(pod.ROUTE_direction, 1);
    b.propInt(pod.ROUTE_device, 4);
    var inner: [256]u8 align(8) = undefined;
    var ib = pod.Builder.init(&inner);
    ib.beginObject(pod.OBJECT_Props, pod.PARAM_Props);
    ib.propFloatArray(pod.PROP_channelVolumes, &.{ 0.5, 0.25 });
    ib.propBool(pod.PROP_mute, true);
    const props = ib.endObject();
    b.propPodBody(pod.ROUTE_props, props);
    g.applyDeviceRoute(dev, b.endObject());

    try testing.expectEqual(@as(i32, 0), dev.active_out.index);
    try testing.expectEqual(@as(i32, 4), dev.active_out.device);
    try testing.expect(dev.active_out.has_props);
    try testing.expectEqual(@as(u8, 2), dev.active_out.n_volumes);
    try testing.expectEqual(@as(f32, 0.25), dev.active_out.volumes[1]);
    try testing.expect(dev.active_out.mute);

    // Sink on that card+device: the route's props win over the node's.
    const sink = try g.upsertNode(53);
    sink.role = .sink;
    sink.device_id = 47;
    sink.card_profile_device = 4;
    sink.volume_count = 2;
    sink.volumes = .{ 1.0, 1.0, 0, 0, 0, 0, 0, 0 };
    const t = g.volumeTarget(sink, false);
    try testing.expectEqual(@as(u32, 47), t.card_id);
    try testing.expectEqual(@as(i32, 0), t.route_index);
    try testing.expectEqual(@as(i32, 4), t.route_device);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, t.volumes[0..t.n_volumes]);
    try testing.expect(t.mute);

    // A node on a different PCM has no route: node props are the target.
    sink.card_profile_device = 5;
    const t2 = g.volumeTarget(sink, false);
    try testing.expectEqual(@as(u32, 0), t2.card_id);
    try testing.expectEqual(@as(i32, -1), t2.route_index);
    try testing.expectEqual(@as(f32, 1.0), t2.volumes[0]);

    // Monitor volumes come from the node's monitor props.
    sink.card_profile_device = 4;
    sink.monitor_volume_count = 1;
    sink.monitor_volumes = .{ 0.25, 0, 0, 0, 0, 0, 0, 0 };
    sink.monitor_mute = true;
    const tm = g.volumeTarget(sink, true);
    try testing.expect(tm.monitor);
    try testing.expectEqual(@as(f32, 0.25), tm.volumes[0]);
    try testing.expect(tm.mute);
}

test "route port visibility mirrors the pulse port filter" {
    var r = Route{ .index = 3, .direction = 1, .n_devices = 1, .n_profiles = 1 };
    r.devices[0] = 4;
    r.profiles[0] = 1;
    try testing.expect(r.visibleFor(1, 1, 4));
    try testing.expect(!r.visibleFor(1, 1, 5)); // wrong card device
    try testing.expect(!r.visibleFor(1, 2, 4)); // not in active profile
    try testing.expect(!r.visibleFor(0, 1, 4)); // wrong direction

    // Routes without arrays are never filtered out.
    const bare = Route{ .index = 0, .direction = 0 };
    try testing.expect(bare.visibleFor(0, 9, 9));
}

test "links resolve stream routing and defaults resolve nodes" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    const sink = try g.upsertNode(121);
    sink.role = .sink;
    try sink.node_name.set(testing.allocator, "bluez_output.A8.1");
    const stream = try g.upsertNode(206);
    stream.role = .stream_playback;

    try g.upsertLink(.{ .id = 184, .out_node = 206, .in_node = 121 });
    try g.upsertLink(.{ .id = 212, .out_node = 206, .in_node = 209 }); // meter capture

    try testing.expectEqual(@as(u32, 121), g.sinkForStream(206).?);
    try testing.expectEqual(@as(?u32, null), g.sourceForStream(206));

    try g.setDefaultSink("bluez_output.A8.1");
    try testing.expectEqual(@as(u32, 121), g.defaultSinkNode().?.id);

    g.removeLink(184);
    try testing.expectEqual(@as(?u32, null), g.sinkForStream(206));
}

test "route pruning drops stale ports" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    const dev = try g.upsertDevice(47);
    var buf: [256]u8 align(8) = undefined;

    for ([_]i32{ 0, 1, 2 }) |idx| {
        var b = pod.Builder.init(&buf);
        b.beginObject(pod.OBJECT_ParamRoute, pod.PARAM_EnumRoute);
        b.propInt(pod.ROUTE_index, idx);
        b.propId(pod.ROUTE_direction, 0);
        g.applyDeviceRoute(dev, b.endObject());
    }
    try testing.expectEqual(@as(usize, 3), dev.routes.items.len);
    const seen = [_]Route{ .{ .index = 0, .direction = 0 }, .{ .index = 2, .direction = 0 } };
    g.pruneRoutes(dev, &seen);
    try testing.expectEqual(@as(usize, 2), dev.routes.items.len);
    try testing.expect(dev.findRoute(1, 0) == null);
}
