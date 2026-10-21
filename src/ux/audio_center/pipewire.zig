//! Hand-written bindings for libpipewire-0.3 (1.6.9) — only the surface the
//! Audio Center needs. Every struct mirrors the installed header exactly
//! (field order and types matter for the C ABI), which is why this file is a
//! deliberate transcription rather than an @cImport: translate-c cannot
//! digest the SPA headers, and we only need a fraction of the API.

const std = @import("std");

// ── spa/utils/hook.h ────────────────────────────────────────────────────────

pub const spa_list = extern struct {
    next: ?*spa_list,
    prev: ?*spa_list,
};

pub const spa_callbacks = extern struct {
    funcs: ?*const anyopaque,
    data: ?*anyopaque,
};

pub const SpaHook = extern struct {
    link: spa_list,
    cb: spa_callbacks,
    removed: ?*const fn (hook: *SpaHook) callconv(.c) void,
    priv: ?*anyopaque,
};

/// spa/utils/hook.h — every client-side object starts with this interface.
pub const spa_interface = extern struct {
    type_: ?[*:0]const u8,
    version: u32,
    cb: spa_callbacks,
};

// ── spa/utils/dict.h ────────────────────────────────────────────────────────

pub const spa_dict_item = extern struct {
    key: ?[*:0]const u8,
    value: ?[*:0]const u8,
};

pub const spa_dict = extern struct {
    flags: u32,
    n_items: u32,
    items: ?[*]const spa_dict_item,
};

// ── spa/pod/pod.h ───────────────────────────────────────────────────────────

pub const spa_pod = extern struct {
    size: u32,
    pod_type: u32,
};

pub const spa_pod_object_body = extern struct {
    type_: u32,
    id: u32,
};

pub const spa_pod_prop = extern struct {
    key: u32,
    flags: u32,
    value: spa_pod,
};

pub const spa_param_info = extern struct {
    id: u32,
    flags: u32,
    user: u32,
    seq: i32,
    padding: [4]u32,
};

// ── spa/buffer/buffer.h ─────────────────────────────────────────────────────

pub const spa_chunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

pub const spa_data = extern struct {
    type: u32,
    flags: u32,
    fd: i32,
    mapoffset: u32,
    maxsize: u32,
    data: ?*anyopaque,
    chunk: ?*spa_chunk,
};

pub const spa_buffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?*anyopaque,
    datas: ?[*]spa_data,
};

// ── pipewire/pipewire.h, main-loop.h, loop.h, context.h, core.h ─────────────

pub const pw_main_loop = opaque {};
pub const pw_loop = opaque {};
pub const pw_context = opaque {};
pub const pw_core = opaque {};
pub const pw_registry = opaque {};
pub const pw_proxy = opaque {};
pub const pw_node = opaque {};
pub const pw_device = opaque {};
pub const pw_metadata = opaque {};
pub const pw_stream = opaque {};
pub const pw_properties = opaque {};

pub extern fn pw_init(argc: ?*c_int, argv: ?*?[*]?[*:0]u8) void;
pub extern fn pw_deinit() void;

pub extern fn pw_main_loop_new(properties: ?*pw_properties) ?*pw_main_loop;
pub extern fn pw_main_loop_destroy(loop: *pw_main_loop) void;
pub extern fn pw_main_loop_get_loop(loop: *pw_main_loop) *pw_loop;

pub extern fn pw_loop_enter(loop: *pw_loop) c_int;
pub extern fn pw_loop_leave(loop: *pw_loop) c_int;
pub extern fn pw_loop_iterate(loop: *pw_loop, timeout: c_int) c_int;

pub extern fn pw_context_new(loop: ?*pw_loop, properties: ?*pw_properties, user_data_size: usize) ?*pw_context;
pub extern fn pw_context_destroy(context: *pw_context) void;
pub extern fn pw_context_connect(context: *pw_context, properties: ?*pw_properties, user_data_size: usize) ?*pw_core;

pub extern fn pw_core_disconnect(core: *pw_core) c_int;
pub extern fn pw_core_get_registry(core: *pw_core, version: u32, user_data_size: usize) ?*pw_registry;
pub extern fn pw_core_sync(core: *pw_core, id: u32, seq: c_int) c_int;

pub extern fn pw_registry_bind(registry: *pw_registry, id: u32, type_: [*:0]const u8, version: u32, user_data_size: usize) ?*pw_proxy;
pub extern fn pw_registry_destroy(registry: *pw_registry, id: u32) c_int;

pub extern fn pw_properties_new(key: ?[*:0]const u8, ...) ?*pw_properties;
pub extern fn pw_properties_free(properties: *pw_properties) void;

pub const PW_ID_CORE: u32 = 0;
pub const PW_ID_ANY: u32 = 0xffffffff;

pub const PW_TYPE_INTERFACE_Node = "PipeWire:Interface:Node";
pub const PW_TYPE_INTERFACE_Device = "PipeWire:Interface:Device";
pub const PW_TYPE_INTERFACE_Metadata = "PipeWire:Interface:Metadata";
pub const PW_TYPE_INTERFACE_Link = "PipeWire:Interface:Link";

pub const PW_VERSION_CORE: u32 = 4; // current protocol version of core
pub const PW_VERSION_REGISTRY: u32 = 3;
pub const PW_VERSION_NODE: u32 = 3;
pub const PW_VERSION_DEVICE: u32 = 3;
pub const PW_VERSION_METADATA: u32 = 3;
pub const PW_VERSION_LINK: u32 = 3;
pub const PW_VERSION_STREAM: u32 = 3;

pub const PW_VERSION_CORE_EVENTS: u32 = 1;
pub const PW_VERSION_REGISTRY_EVENTS: u32 = 0;
pub const PW_VERSION_NODE_EVENTS: u32 = 0;
pub const PW_VERSION_DEVICE_EVENTS: u32 = 0;
pub const PW_VERSION_METADATA_EVENTS: u32 = 0;
pub const PW_VERSION_STREAM_EVENTS: u32 = 2;

// ── info structs ────────────────────────────────────────────────────────────

pub const pw_core_info = extern struct {
    id: u32,
    cookie: u32,
    user_name: ?[*:0]const u8,
    host_name: ?[*:0]const u8,
    version: ?[*:0]const u8,
    name: ?[*:0]const u8,
    change_mask: u64,
    props: ?*spa_dict,
};

pub const pw_node_state = c_int;
pub const PW_NODE_STATE_ERROR: pw_node_state = -1;
pub const PW_NODE_STATE_CREATING: pw_node_state = 0;
pub const PW_NODE_STATE_SUSPENDED: pw_node_state = 1;
pub const PW_NODE_STATE_IDLE: pw_node_state = 2;
pub const PW_NODE_STATE_RUNNING: pw_node_state = 3;

pub const pw_node_info = extern struct {
    id: u32,
    max_input_ports: u32,
    max_output_ports: u32,
    change_mask: u64,
    n_input_ports: u32,
    n_output_ports: u32,
    state: pw_node_state,
    @"error": ?[*:0]const u8,
    props: ?*spa_dict,
    params: ?[*]spa_param_info,
    n_params: u32,
};

pub const pw_device_info = extern struct {
    id: u32,
    change_mask: u64,
    props: ?*spa_dict,
    params: ?[*]spa_param_info,
    n_params: u32,
};

pub const pw_link_info = extern struct {
    id: u32,
    output_node_id: u32,
    output_port_id: u32,
    input_node_id: u32,
    input_port_id: u32,
    change_mask: u64,
    state: c_int,
    @"error": ?[*:0]const u8,
    format: ?*spa_pod,
    props: ?*spa_dict,
};

// ── events structs (order is ABI) ───────────────────────────────────────────

pub const pw_core_events = extern struct {
    version: u32 = PW_VERSION_CORE_EVENTS,
    info: ?*const fn (data: ?*anyopaque, info: *const pw_core_info) callconv(.c) void = null,
    done: ?*const fn (data: ?*anyopaque, id: u32, seq: c_int) callconv(.c) void = null,
    ping: ?*const fn (data: ?*anyopaque, id: u32, seq: c_int) callconv(.c) void = null,
    @"error": ?*const fn (data: ?*anyopaque, id: u32, seq: c_int, res: c_int, message: ?[*:0]const u8) callconv(.c) void = null,
    remove_id: ?*const fn (data: ?*anyopaque, id: u32) callconv(.c) void = null,
    bound_id: ?*const fn (data: ?*anyopaque, id: u32, global_id: u32) callconv(.c) void = null,
    add_mem: ?*const fn (data: ?*anyopaque, id: u32, type_: u32, fd: c_int, flags: u32) callconv(.c) void = null,
    remove_mem: ?*const fn (data: ?*anyopaque, id: u32) callconv(.c) void = null,
    bound_props: ?*const fn (data: ?*anyopaque, id: u32, global_id: u32, props: ?*const spa_dict) callconv(.c) void = null,
};

pub const pw_registry_events = extern struct {
    version: u32 = PW_VERSION_REGISTRY_EVENTS,
    global: ?*const fn (data: ?*anyopaque, id: u32, permissions: u32, type_: ?[*:0]const u8, version: u32, props: ?*const spa_dict) callconv(.c) void = null,
    global_remove: ?*const fn (data: ?*anyopaque, id: u32) callconv(.c) void = null,
};

pub const pw_node_events = extern struct {
    version: u32 = PW_VERSION_NODE_EVENTS,
    info: ?*const fn (data: ?*anyopaque, info: *const pw_node_info) callconv(.c) void = null,
    param: ?*const fn (data: ?*anyopaque, seq: c_int, id: u32, index: u32, next: u32, param: ?*const spa_pod) callconv(.c) void = null,
};

pub const pw_device_events = extern struct {
    version: u32 = PW_VERSION_DEVICE_EVENTS,
    info: ?*const fn (data: ?*anyopaque, info: *const pw_device_info) callconv(.c) void = null,
    param: ?*const fn (data: ?*anyopaque, seq: c_int, id: u32, index: u32, next: u32, param: ?*const spa_pod) callconv(.c) void = null,
};

pub const pw_link_events = extern struct {
    version: u32 = 0,
    info: ?*const fn (data: ?*anyopaque, info: *const pw_link_info) callconv(.c) void = null,
};

pub const pw_metadata_events = extern struct {
    version: u32 = PW_VERSION_METADATA_EVENTS,
    property: ?*const fn (data: ?*anyopaque, subject: u32, key: ?[*:0]const u8, type_: ?[*:0]const u8, value: ?[*:0]const u8) callconv(.c) c_int = null,
};

/// pipewire/extensions/metadata.h — the metadata interface is an *extension*:
/// its client methods are header-inline calls through the object's method
/// table and are not exported as symbols, so they are reimplemented here
/// following `spa_api_method_r`.
pub const pw_metadata_methods = extern struct {
    version: u32,
    add_listener: ?*const fn (object: ?*anyopaque, listener: *SpaHook, events: *const pw_metadata_events, data: ?*anyopaque) callconv(.c) c_int,
    set_property: ?*const fn (object: ?*anyopaque, subject: u32, key: ?[*:0]const u8, type_: ?[*:0]const u8, value: ?[*:0]const u8) callconv(.c) c_int,
    clear: ?*const fn (object: ?*anyopaque) callconv(.c) c_int,
};

const ENOTSUP: c_int = -38;

fn metadataMethods(md: *pw_metadata) ?*const pw_metadata_methods {
    const iface: *const spa_interface = @ptrCast(@alignCast(md));
    const funcs = iface.cb.funcs orelse return null;
    return @ptrCast(@alignCast(funcs));
}

pub fn metadataAddListener(md: *pw_metadata, listener: *SpaHook, events: *const pw_metadata_events, data: ?*anyopaque) c_int {
    const f = metadataMethods(md) orelse return ENOTSUP;
    const m = f.add_listener orelse return ENOTSUP;
    const iface: *const spa_interface = @ptrCast(@alignCast(md));
    return m(iface.cb.data, listener, events, data);
}

pub fn metadataSetProperty(md: *pw_metadata, subject: u32, key: [*:0]const u8, type_: ?[*:0]const u8, value: ?[*:0]const u8) c_int {
    const f = metadataMethods(md) orelse return ENOTSUP;
    const m = f.set_property orelse return ENOTSUP;
    const iface: *const spa_interface = @ptrCast(@alignCast(md));
    return m(iface.cb.data, subject, key, type_, value);
}

pub const pw_stream_state = c_int;
pub const PW_STREAM_STATE_ERROR: pw_stream_state = -1;
pub const PW_STREAM_STATE_UNCONNECTED: pw_stream_state = 0;
pub const PW_STREAM_STATE_CONNECTING: pw_stream_state = 1;
pub const PW_STREAM_STATE_PAUSED: pw_stream_state = 2;
pub const PW_STREAM_STATE_STREAMING: pw_stream_state = 3;

pub const pw_stream_events = extern struct {
    version: u32 = PW_VERSION_STREAM_EVENTS,
    destroy: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (data: ?*anyopaque, old: pw_stream_state, state: pw_stream_state, err: ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const fn (data: ?*anyopaque, id: u32, control: ?*const anyopaque) callconv(.c) void = null,
    io_changed: ?*const fn (data: ?*anyopaque, id: u32, area: ?*anyopaque, size: u32) callconv(.c) void = null,
    param_changed: ?*const fn (data: ?*anyopaque, id: u32, param: ?*const spa_pod) callconv(.c) void = null,
    add_buffer: ?*const fn (data: ?*anyopaque, buffer: *pw_buffer) callconv(.c) void = null,
    remove_buffer: ?*const fn (data: ?*anyopaque, buffer: *pw_buffer) callconv(.c) void = null,
    process: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
    drained: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
    command: ?*const fn (data: ?*anyopaque, command: ?*const anyopaque) callconv(.c) void = null,
    trigger_done: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
};

pub const pw_buffer = extern struct {
    buffer: ?*spa_buffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
    time: i64,
};

// ── object methods ──────────────────────────────────────────────────────────

pub extern fn pw_core_add_listener(core: *pw_core, listener: *SpaHook, events: *const pw_core_events, data: ?*anyopaque) c_int;
pub extern fn pw_registry_add_listener(registry: *pw_registry, listener: *SpaHook, events: *const pw_registry_events, data: ?*anyopaque) c_int;
pub extern fn pw_proxy_add_listener(proxy: *pw_proxy, listener: *SpaHook, events: *const anyopaque, data: ?*anyopaque) c_int;
pub extern fn pw_proxy_destroy(proxy: *pw_proxy) void;
pub extern fn pw_proxy_get_bound_id(proxy: *pw_proxy) u32;

pub extern fn pw_node_add_listener(node: *pw_node, listener: *SpaHook, events: *const pw_node_events, data: ?*anyopaque) c_int;
pub extern fn pw_node_subscribe_params(node: *pw_node, ids: [*]const u32, n_ids: u32) c_int;
pub extern fn pw_node_enum_params(node: *pw_node, seq: c_int, id: u32, start: u32, num: u32, filter: ?*const spa_pod) c_int;
pub extern fn pw_node_set_param(node: *pw_node, id: u32, flags: u32, param: ?*const spa_pod) c_int;

pub extern fn pw_device_add_listener(device: *pw_device, listener: *SpaHook, events: *const pw_device_events, data: ?*anyopaque) c_int;
pub extern fn pw_device_subscribe_params(device: *pw_device, ids: [*]const u32, n_ids: u32) c_int;
pub extern fn pw_device_enum_params(device: *pw_device, seq: c_int, id: u32, start: u32, num: u32, filter: ?*const spa_pod) c_int;
pub extern fn pw_device_set_param(device: *pw_device, id: u32, flags: u32, param: ?*const spa_pod) c_int;

pub extern fn pw_link_add_listener(link: *pw_proxy, listener: *SpaHook, events: *const pw_link_events, data: ?*anyopaque) c_int;

// (metadata add_listener/set_property live above as vtable calls — the
// metadata interface is an extension without exported symbols.)

pub const PW_DIRECTION_INPUT: u32 = 0;
pub const PW_DIRECTION_OUTPUT: u32 = 1;

pub const PW_STREAM_FLAG_NONE: u32 = 0;
pub const PW_STREAM_FLAG_AUTOCONNECT: u32 = 1 << 0;
pub const PW_STREAM_FLAG_INACTIVE: u32 = 1 << 1;
pub const PW_STREAM_FLAG_MAP_BUFFERS: u32 = 1 << 2;
pub const PW_STREAM_FLAG_DRIVER: u32 = 1 << 3;
pub const PW_STREAM_FLAG_RT_PROCESS: u32 = 1 << 4;
pub const PW_STREAM_FLAG_NO_CONVERT: u32 = 1 << 5;
pub const PW_STREAM_FLAG_EXCLUSIVE: u32 = 1 << 6;
pub const PW_STREAM_FLAG_DONT_RECONNECT: u32 = 1 << 7;
pub const PW_STREAM_FLAG_ALLOC_BUFFERS: u32 = 1 << 8;
pub const PW_STREAM_FLAG_TRIGGER: u32 = 1 << 9;

pub extern fn pw_stream_new_simple(loop: *pw_loop, name: [*:0]const u8, props: ?*pw_properties, events: *const pw_stream_events, data: ?*anyopaque) ?*pw_stream;
pub extern fn pw_stream_new(core: *pw_core, name: [*:0]const u8, props: ?*pw_properties) ?*pw_stream;
pub extern fn pw_stream_add_listener(stream: *pw_stream, listener: *SpaHook, events: *const pw_stream_events, data: ?*anyopaque) c_int;
pub extern fn pw_stream_destroy(stream: *pw_stream) void;
pub extern fn pw_stream_connect(stream: *pw_stream, direction: u32, target_id: u32, flags: u32, params: ?[*]const ?*const spa_pod, n_params: u32) c_int;
pub extern fn pw_stream_dequeue_buffer(stream: *pw_stream) ?*pw_buffer;
pub extern fn pw_stream_queue_buffer(stream: *pw_stream, buffer: *pw_buffer) c_int;
pub extern fn pw_stream_get_node_id(stream: *pw_stream) u32;
pub extern fn pw_stream_set_active(stream: *pw_stream, active: bool) c_int;

// ── helpers ─────────────────────────────────────────────────────────────────

/// Look up a key in a SPA dict, returning the value as a plain slice.
pub fn dictGet(dict: ?*const spa_dict, key: []const u8) ?[]const u8 {
    const d = dict orelse return null;
    const items = d.items orelse return null;
    for (items[0..d.n_items]) |item| {
        const k = item.key orelse continue;
        if (std.mem.eql(u8, std.mem.span(k), key)) {
            const v = item.value orelse return null;
            return std.mem.span(v);
        }
    }
    return null;
}

/// SPA dictionaries may carry duplicate keys; the last one wins for the
/// live-updated props we read (same rule as pw-dump's use_last).
pub fn dictGetLast(dict: ?*const spa_dict, key: []const u8) ?[]const u8 {
    const d = dict orelse return null;
    const items = d.items orelse return null;
    var found: ?[]const u8 = null;
    for (items[0..d.n_items]) |item| {
        const k = item.key orelse continue;
        if (std.mem.eql(u8, std.mem.span(k), key)) found = std.mem.span(item.value orelse "");
    }
    return found;
}

pub fn dictU32(dict: ?*const spa_dict, key: []const u8) ?u32 {
    const s = dictGet(dict, key) orelse return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}
