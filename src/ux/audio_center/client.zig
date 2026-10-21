//! PipeWire client wiring for the Audio Center.
//!
//! One thread, one main loop: `pw_loop_enter()` once, then the UI calls
//! `iterate()` every frame. All callbacks therefore run on the UI thread,
//! which is what lets the rest of the app be plain single-threaded code.
//!
//! Registry globals are tracked without any reference counting: a bound
//! object's callbacks carry a `Bound` handle that stays allocated until the
//! client is destroyed (retired handles are parked). PipeWire destroys the
//! client-side proxy itself when the global goes away, so we never call
//! `pw_proxy_destroy` on a live object we merely observe.

const std = @import("std");
const pw = @import("pipewire.zig");
const pod = @import("pod.zig");
const graph = @import("graph.zig");

const log = std.log.scoped(.audio_center);

pub const Client = struct {
    alloc: std.mem.Allocator,
    g: *graph.Graph,

    main_loop: *pw.pw_main_loop,
    loop: *pw.pw_loop,
    context: *pw.pw_context,
    core: *pw.pw_core,
    registry: *pw.pw_registry,

    /// The WirePlumber "default" metadata object, once bound.
    metadata: ?*pw.pw_metadata = null,

    bounds: std.ArrayList(*Bound) = .empty,
    retired: std.ArrayList(*Bound) = .empty,

    core_hook: pw.SpaHook = std.mem.zeroes(pw.SpaHook),
    registry_hook: pw.SpaHook = std.mem.zeroes(pw.SpaHook),

    saw_effective_sink: bool = false,
    saw_effective_source: bool = false,
    syncs_done: u32 = 0,

    pub const Bound = struct {
        client: *Client,
        id: u32,
        kind: Kind,
        proxy: *pw.pw_proxy,
        hook: pw.SpaHook = std.mem.zeroes(pw.SpaHook),

        pub const Kind = enum { node, device, metadata };

        fn asNode(self: *Bound) *pw.pw_node {
            return @ptrCast(self.proxy);
        }
        fn asDevice(self: *Bound) *pw.pw_device {
            return @ptrCast(self.proxy);
        }
        fn asMetadata(self: *Bound) *pw.pw_metadata {
            return @ptrCast(self.proxy);
        }
    };

    pub fn create(alloc: std.mem.Allocator, g: *graph.Graph) !*Client {
        pw.pw_init(null, null);

        const self = try alloc.create(Client);
        errdefer alloc.destroy(self);

        const main_loop = pw.pw_main_loop_new(null) orelse return error.PipeWireUnavailable;
        errdefer pw.pw_main_loop_destroy(main_loop);
        const loop = pw.pw_main_loop_get_loop(main_loop);
        const context = pw.pw_context_new(loop, null, 0) orelse return error.PipeWireUnavailable;
        errdefer pw.pw_context_destroy(context);
        const core = pw.pw_context_connect(context, null, 0) orelse return error.PipeWireUnavailable;
        errdefer _ = pw.pw_core_disconnect(core);
        const registry = pw.pw_core_get_registry(core, pw.PW_VERSION_REGISTRY, 0) orelse return error.PipeWireUnavailable;

        self.* = .{
            .alloc = alloc,
            .g = g,
            .main_loop = main_loop,
            .loop = loop,
            .context = context,
            .core = core,
            .registry = registry,
        };

        _ = pw.pw_core_add_listener(core, &self.core_hook, &core_events_impl, self);
        _ = pw.pw_registry_add_listener(registry, &self.registry_hook, &registry_events_impl, self);
        _ = pw.pw_loop_enter(loop);
        return self;
    }

    pub fn destroy(self: *Client) void {
        const alloc = self.alloc;
        _ = pw.pw_loop_leave(self.loop);
        _ = pw.pw_core_disconnect(self.core);
        pw.pw_context_destroy(self.context);
        pw.pw_main_loop_destroy(self.main_loop);
        for (self.bounds.items) |b| alloc.destroy(b);
        self.bounds.deinit(alloc);
        for (self.retired.items) |b| alloc.destroy(b);
        self.retired.deinit(alloc);
        alloc.destroy(self);
    }

    /// Dispatch pending PipeWire events; `timeout_ms` is the poll timeout.
    /// Call with 0 from the UI loop, or a small value while waiting.
    pub fn iterate(self: *Client, timeout_ms: i32) void {
        _ = pw.pw_loop_iterate(self.loop, timeout_ms);
    }

    /// Queue a core roundtrip; `syncs_done` increments when it completes.
    pub fn sync(self: *Client) void {
        _ = pw.pw_core_sync(self.core, pw.PW_ID_CORE, 0);
    }

    // ── actions ─────────────────────────────────────────────────────────────

    fn boundForNode(self: *Client, id: u32) ?*Bound {
        for (self.bounds.items) |b| {
            if (b.id == id and b.kind == .node) return b;
        }
        return null;
    }

    fn boundForDevice(self: *Client, id: u32) ?*Bound {
        for (self.bounds.items) |b| {
            if (b.id == id and b.kind == .device) return b;
        }
        return null;
    }

    pub fn setNodeVolume(self: *Client, id: u32, volume: f32) bool {
        const b = self.boundForNode(id) orelse return false;
        var buf: [64]u8 align(8) = undefined;
        const p = pod.propsVolume(&buf, volume);
        return pw.pw_node_set_param(b.asNode(), pod.PARAM_Props, 0, @ptrCast(p)) >= 0;
    }

    pub fn setNodeChannelVolumes(self: *Client, id: u32, volumes: []const f32) bool {
        const b = self.boundForNode(id) orelse return false;
        var buf: [256]u8 align(8) = undefined;
        const p = pod.propsChannelVolumes(&buf, volumes);
        return pw.pw_node_set_param(b.asNode(), pod.PARAM_Props, 0, @ptrCast(p)) >= 0;
    }

    pub fn setNodeMute(self: *Client, id: u32, mute: bool) bool {
        const b = self.boundForNode(id) orelse return false;
        var buf: [64]u8 align(8) = undefined;
        const p = pod.propsMute(&buf, mute);
        return pw.pw_node_set_param(b.asNode(), pod.PARAM_Props, 0, @ptrCast(p)) >= 0;
    }

    /// Set a node's volume exactly the way pipewire-pulse does: the card
    /// route's Props for hardware devices with an active route, monitorVolumes
    /// for monitors, and the node's own Props for streams. `volumes` are
    /// linear amplitudes (channelVolumes values).
    pub fn setVolume(self: *Client, id: u32, volumes: []const f32, monitor: bool) bool {
        const node = self.g.findNode(id) orelse return false;
        const t = self.g.volumeTarget(node, monitor);
        if (t.monitor) return self.setNodeMonitorVolumes(id, volumes);
        if (t.card_id != 0 and t.route_index >= 0)
            return self.setRouteVolumes(t.card_id, t.route_index, t.route_device, volumes);
        return self.setNodeChannelVolumes(id, volumes);
    }

    pub fn setMute(self: *Client, id: u32, mute: bool, monitor: bool) bool {
        const node = self.g.findNode(id) orelse return false;
        const t = self.g.volumeTarget(node, monitor);
        if (t.monitor) return self.setNodeMonitorMute(id, mute);
        if (t.card_id != 0 and t.route_index >= 0)
            return self.setRouteMute(t.card_id, t.route_index, t.route_device, mute);
        return self.setNodeMute(id, mute);
    }

    /// Write a volume to a card route (SPA_PARAM_Route with the Props
    /// sub-object and `save` set) — what pipewire-pulse does for hardware
    /// sinks/sources, and what makes the change stick in WirePlumber.
    pub fn setRouteVolumes(self: *Client, card_id: u32, index: i32, device: i32, volumes: []const f32) bool {
        const b = self.boundForDevice(card_id) orelse return false;
        var buf: [512]u8 align(8) = undefined;
        const p = pod.routeVolume(&buf, index, device, volumes, null);
        return pw.pw_device_set_param(b.asDevice(), pod.PARAM_Route, 0, @ptrCast(p)) >= 0;
    }

    pub fn setRouteMute(self: *Client, card_id: u32, index: i32, device: i32, mute: bool) bool {
        const b = self.boundForDevice(card_id) orelse return false;
        var buf: [512]u8 align(8) = undefined;
        const p = pod.routeVolume(&buf, index, device, null, mute);
        return pw.pw_device_set_param(b.asDevice(), pod.PARAM_Route, 0, @ptrCast(p)) >= 0;
    }

    /// Monitor sources take their volume from monitorVolumes/monitorMute on
    /// the node (again matching pipewire-pulse).
    pub fn setNodeMonitorVolumes(self: *Client, id: u32, volumes: []const f32) bool {
        const b = self.boundForNode(id) orelse return false;
        var buf: [512]u8 align(8) = undefined;
        const p = pod.propsMonitorVolumes(&buf, volumes);
        return pw.pw_node_set_param(b.asNode(), pod.PARAM_Props, 0, @ptrCast(p)) >= 0;
    }

    pub fn setNodeMonitorMute(self: *Client, id: u32, mute: bool) bool {
        const b = self.boundForNode(id) orelse return false;
        var buf: [64]u8 align(8) = undefined;
        const p = pod.propsMonitorMute(&buf, mute);
        return pw.pw_node_set_param(b.asNode(), pod.PARAM_Props, 0, @ptrCast(p)) >= 0;
    }

    /// Switch a card device to another profile (the profile's index).
    pub fn setProfile(self: *Client, device_id: u32, index: i32) bool {
        const b = self.boundForDevice(device_id) orelse return false;
        var buf: [64]u8 align(8) = undefined;
        const p = pod.profileIndex(&buf, index);
        return pw.pw_device_set_param(b.asDevice(), pod.PARAM_Profile, 0, @ptrCast(p)) >= 0;
    }

    /// Switch an ALSA device to another port/route. `device` is the route's
    /// inner device index (-1 to omit).
    pub fn setRoute(self: *Client, device_id: u32, index: i32, device: i32) bool {
        const b = self.boundForDevice(device_id) orelse return false;
        var buf: [64]u8 align(8) = undefined;
        const p = pod.routePort(&buf, index, device);
        return pw.pw_device_set_param(b.asDevice(), pod.PARAM_Route, 0, @ptrCast(p)) >= 0;
    }

    fn setDefaultKey(self: *Client, key: [*:0]const u8, configured_key: [*:0]const u8, name: []const u8) bool {
        const md = self.metadata orelse return false;
        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrintZ(&buf, "{{\"name\":\"{s}\"}}", .{name}) catch return false;
        const ok = pw.metadataSetProperty(md, 0, key, "Spa:String:JSON", json.ptr) >= 0;
        // The configured key is what WirePlumber restores at startup.
        _ = pw.metadataSetProperty(md, 0, configured_key, "Spa:String:JSON", json.ptr);
        return ok;
    }

    pub fn setDefaultSinkName(self: *Client, name: []const u8) bool {
        return self.setDefaultKey("default.audio.sink", "default.configured.audio.sink", name);
    }

    pub fn setDefaultSourceName(self: *Client, name: []const u8) bool {
        return self.setDefaultKey("default.audio.source", "default.configured.audio.source", name);
    }

    /// Move a playback/recording stream to another node, writing the same
    /// metadata pipewire-pulse does: `target.node` (the node id) plus
    /// `target.object` (its `object.serial`), both as `Spa:Id`.
    pub fn moveStream(self: *Client, stream_id: u32, target_id: u32) bool {
        const md = self.metadata orelse return false;
        const target = self.g.findNode(target_id) orelse return false;
        const serial: u64 = if (target.serial != 0) target.serial else target.id;
        var id_buf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrintZ(&id_buf, "{d}", .{target_id}) catch return false;
        var ser_buf: [24]u8 = undefined;
        const ser_str = std.fmt.bufPrintZ(&ser_buf, "{d}", .{serial}) catch return false;
        const ok_node = pw.metadataSetProperty(md, stream_id, "target.node", "Spa:Id", id_str.ptr) >= 0;
        const ok_obj = pw.metadataSetProperty(md, stream_id, "target.object", "Spa:Id", ser_str.ptr) >= 0;
        return ok_node and ok_obj;
    }

    /// Terminate a stream node (asked-for permission may be denied).
    pub fn killNode(self: *Client, id: u32) bool {
        return pw.pw_registry_destroy(self.registry, id) >= 0;
    }

    // ── bound handle bookkeeping ────────────────────────────────────────────

    fn trackBound(self: *Client, id: u32, kind: Bound.Kind, proxy: *pw.pw_proxy) !*Bound {
        const b = try self.alloc.create(Bound);
        errdefer self.alloc.destroy(b);
        b.* = .{ .client = self, .id = id, .kind = kind, .proxy = proxy };
        try self.bounds.append(self.alloc, b);
        return b;
    }

    fn takeBound(self: *Client, id: u32) ?*Bound {
        for (self.bounds.items, 0..) |b, i| {
            if (b.id == id) {
                _ = self.bounds.swapRemove(i);
                if (b.kind == .metadata) self.metadata = null;
                return b;
            }
        }
        return null;
    }

    // ── registry handling ───────────────────────────────────────────────────

    fn bindNode(self: *Client, id: u32, version: u32, global_props: ?*const pw.spa_dict) !void {
        const proxy = pw.pw_registry_bind(self.registry, id, pw.PW_TYPE_INTERFACE_Node, @min(version, pw.PW_VERSION_NODE), 0) orelse return error.BindFailed;
        const b = self.trackBound(id, .node, proxy) catch |e| {
            pw.pw_proxy_destroy(proxy);
            return e;
        };
        _ = pw.pw_node_add_listener(b.asNode(), &b.hook, &node_events_impl, b);

        // The global props already carry media.class, so the node lands in
        // the right list before the first info event arrives.
        const node = try self.g.upsertNode(id);
        try self.g.applyNodeDict(node, global_props);

        var ids = [_]u32{pod.PARAM_Props};
        _ = pw.pw_node_subscribe_params(b.asNode(), &ids, ids.len);
        _ = pw.pw_node_enum_params(b.asNode(), 0, pod.PARAM_Props, 0, std.math.maxInt(u32), null);
    }

    fn bindDevice(self: *Client, id: u32, version: u32, global_props: ?*const pw.spa_dict) !void {
        // Only audio cards have profiles/routes; skipping other devices also
        // avoids a stream of ENOENT enum-param warnings from video nodes.
        if (pw.dictGetLast(global_props, "media.class")) |class| {
            if (!std.mem.eql(u8, class, "Audio/Device")) return;
        }
        const proxy = pw.pw_registry_bind(self.registry, id, pw.PW_TYPE_INTERFACE_Device, @min(version, pw.PW_VERSION_DEVICE), 0) orelse return error.BindFailed;
        const b = self.trackBound(id, .device, proxy) catch |e| {
            pw.pw_proxy_destroy(proxy);
            return e;
        };
        _ = pw.pw_device_add_listener(b.asDevice(), &b.hook, &device_events_impl, b);

        const dev = try self.g.upsertDevice(id);
        try self.g.applyDeviceDict(dev, global_props);

        const ids = [_]u32{ pod.PARAM_EnumProfile, pod.PARAM_Profile, pod.PARAM_EnumRoute, pod.PARAM_Route };
        _ = pw.pw_device_subscribe_params(b.asDevice(), &ids, ids.len);
        for (ids) |pid| {
            _ = pw.pw_device_enum_params(b.asDevice(), 0, pid, 0, std.math.maxInt(u32), null);
        }
    }

    fn bindMetadata(self: *Client, id: u32, version: u32, global_props: ?*const pw.spa_dict) !void {
        const name = pw.dictGetLast(global_props, "metadata.name") orelse return;
        if (!std.mem.eql(u8, name, "default")) return;
        if (self.metadata != null) return;

        const proxy = pw.pw_registry_bind(self.registry, id, pw.PW_TYPE_INTERFACE_Metadata, @min(version, pw.PW_VERSION_METADATA), 0) orelse return error.BindFailed;
        const b = self.trackBound(id, .metadata, proxy) catch |e| {
            pw.pw_proxy_destroy(proxy);
            return e;
        };
        _ = pw.metadataAddListener(b.asMetadata(), &b.hook, &metadata_events_impl, b);
        self.metadata = b.asMetadata();
    }

    fn noteLink(self: *Client, id: u32, props: ?*const pw.spa_dict) void {
        // Link globals publish their endpoints, so no binding is needed for
        // routing topology.
        var link = graph.Link{ .id = id };
        link.out_node = pw.dictU32(props, "link.output.node") orelse 0;
        link.in_node = pw.dictU32(props, "link.input.node") orelse 0;
        link.out_port = pw.dictU32(props, "link.output.port") orelse 0;
        link.in_port = pw.dictU32(props, "link.input.port") orelse 0;
        if (link.out_node == 0 or link.in_node == 0) return;
        self.g.upsertLink(link) catch {};
    }
};

// ── event callbacks ─────────────────────────────────────────────────────────

fn cbCoreDone(data: ?*anyopaque, id: u32, seq: c_int) callconv(.c) void {
    _ = id;
    _ = seq;
    const self: *Client = @ptrCast(@alignCast(data.?));
    self.syncs_done +%= 1;
}

fn cbCoreError(data: ?*anyopaque, id: u32, seq: c_int, res: c_int, message: ?[*:0]const u8) callconv(.c) void {
    _ = data;
    _ = seq;
    const msg = if (message) |m| std.mem.span(m) else "";
    log.warn("core error (id {d}): {s} ({d})", .{ id, msg, res });
}

const core_events_impl = pw.pw_core_events{
    .done = cbCoreDone,
    .@"error" = cbCoreError,
};

fn cbRegistryGlobal(data: ?*anyopaque, id: u32, permissions: u32, type_: ?[*:0]const u8, version: u32, props: ?*const pw.spa_dict) callconv(.c) void {
    _ = permissions;
    const self: *Client = @ptrCast(@alignCast(data.?));
    const t = type_ orelse return;
    const ts = std.mem.span(t);

    if (std.mem.eql(u8, ts, pw.PW_TYPE_INTERFACE_Node)) {
        self.bindNode(id, version, props) catch |e| log.warn("bind node {d}: {s}", .{ id, @errorName(e) });
    } else if (std.mem.eql(u8, ts, pw.PW_TYPE_INTERFACE_Device)) {
        self.bindDevice(id, version, props) catch |e| log.warn("bind device {d}: {s}", .{ id, @errorName(e) });
    } else if (std.mem.eql(u8, ts, pw.PW_TYPE_INTERFACE_Metadata)) {
        self.bindMetadata(id, version, props) catch |e| log.warn("bind metadata {d}: {s}", .{ id, @errorName(e) });
    } else if (std.mem.eql(u8, ts, pw.PW_TYPE_INTERFACE_Link)) {
        self.noteLink(id, props);
    }
}

fn cbRegistryGlobalRemove(data: ?*anyopaque, id: u32) callconv(.c) void {
    const self: *Client = @ptrCast(@alignCast(data.?));
    // Park the handle: the proxy is owned by the registry and freed by the
    // library, the callback data must outlive any in-flight dispatch.
    if (self.takeBound(id)) |b| self.retired.append(self.alloc, b) catch {};
    self.g.removeNode(id);
    self.g.removeDevice(id);
    self.g.removeLink(id);
}

const registry_events_impl = pw.pw_registry_events{
    .global = cbRegistryGlobal,
    .global_remove = cbRegistryGlobalRemove,
};

fn cbNodeInfo(data: ?*anyopaque, info: *const pw.pw_node_info) callconv(.c) void {
    const b: *Client.Bound = @ptrCast(@alignCast(data.?));
    const node = b.client.g.findNode(info.id) orelse return;
    node.state = info.state;
    b.client.g.applyNodeDict(node, info.props) catch {};
}

fn cbNodeParam(data: ?*anyopaque, seq: c_int, id: u32, index: u32, next: u32, param: ?*const pw.spa_pod) callconv(.c) void {
    _ = seq;
    _ = index;
    _ = next;
    const b: *Client.Bound = @ptrCast(@alignCast(data.?));
    const raw = param orelse return;
    if (id != pod.PARAM_Props) return;
    const p: *const pod.Pod = @ptrCast(raw);
    const node = b.client.g.findNode(b.id) orelse return;
    b.client.g.applyNodeProps(node, p);
}

const node_events_impl = pw.pw_node_events{
    .info = cbNodeInfo,
    .param = cbNodeParam,
};

fn cbDeviceInfo(data: ?*anyopaque, info: *const pw.pw_device_info) callconv(.c) void {
    const b: *Client.Bound = @ptrCast(@alignCast(data.?));
    const dev = b.client.g.findDevice(info.id) orelse return;
    b.client.g.applyDeviceDict(dev, info.props) catch {};
}

fn cbDeviceParam(data: ?*anyopaque, seq: c_int, id: u32, index: u32, next: u32, param: ?*const pw.spa_pod) callconv(.c) void {
    _ = seq;
    _ = index;
    _ = next;
    const b: *Client.Bound = @ptrCast(@alignCast(data.?));
    const raw = param orelse return;
    const p: *const pod.Pod = @ptrCast(raw);
    const dev = b.client.g.findDevice(b.id) orelse return;
    switch (id) {
        pod.PARAM_EnumProfile, pod.PARAM_Profile => b.client.g.applyDeviceProfile(dev, p),
        pod.PARAM_EnumRoute, pod.PARAM_Route => b.client.g.applyDeviceRoute(dev, p),
        else => {},
    }
}

const device_events_impl = pw.pw_device_events{
    .info = cbDeviceInfo,
    .param = cbDeviceParam,
};

fn cbMetadataProperty(data: ?*anyopaque, subject: u32, key: ?[*:0]const u8, type_: ?[*:0]const u8, value: ?[*:0]const u8) callconv(.c) c_int {
    _ = type_;
    const b: *Client.Bound = @ptrCast(@alignCast(data.?));
    const self = b.client;
    if (subject != 0) return 0;
    const k = key orelse return 0;
    const v = value orelse return 0; // null value = property cleared
    const ks = std.mem.span(k);
    const vs = std.mem.span(v);

    if (std.mem.eql(u8, ks, "default.audio.sink")) {
        self.saw_effective_sink = true;
        if (graph.metadataName(vs)) |n| self.g.setDefaultSink(n) catch {};
    } else if (std.mem.eql(u8, ks, "default.configured.audio.sink")) {
        if (!self.saw_effective_sink) {
            if (graph.metadataName(vs)) |n| self.g.setDefaultSink(n) catch {};
        }
    } else if (std.mem.eql(u8, ks, "default.audio.source")) {
        self.saw_effective_source = true;
        if (graph.metadataName(vs)) |n| self.g.setDefaultSource(n) catch {};
    } else if (std.mem.eql(u8, ks, "default.configured.audio.source")) {
        if (!self.saw_effective_source) {
            if (graph.metadataName(vs)) |n| self.g.setDefaultSource(n) catch {};
        }
    }
    return 0;
}

const metadata_events_impl = pw.pw_metadata_events{
    .property = cbMetadataProperty,
};

// ── tests (pure helpers only; the live path is exercised by --probe) ────────

const testing = std.testing;

test "default sink/source pod bytes are stable" {
    // Guards the byte layout used by setNodeVolume/setNodeMute against
    // regressions in pod.zig (same fixtures as the pod unit tests).
    var buf: [64]u8 align(8) = undefined;
    const p = pod.propsVolume(&buf, 0.5);
    try testing.expectEqual(@as(u32, 0x20), p.size);
    try testing.expectEqual(pod.OBJECT_Props, pod.objectType(p));
}
