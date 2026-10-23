const std = @import("std");

pub const wl = @import("c.zig").wl;

pub const ConnectionState = enum { disconnected, connecting, connected };

pub const Global = struct {
    name: u32,
    interface: []const u8,
    version: u32,
};

pub const Connection = struct {
    alloc: std.mem.Allocator,
    display: ?*wl.wl_display = null,
    registry: ?*wl.wl_registry = null,
    state: ConnectionState = .disconnected,
    display_name: ?[]const u8 = null,
    globals: std.ArrayList(Global),

    const Self = @This();

    fn onGlobal(data: ?*anyopaque, reg: ?*wl.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        _ = reg;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (interface == null) return;
        const ifname = std.mem.span(interface);
        self.globals.append(self.alloc, .{
            .name = name,
            .interface = self.alloc.dupe(u8, ifname) catch return,
            .version = version,
        }) catch {};
    }

    fn onGlobalRemove(data: ?*anyopaque, reg: ?*wl.wl_registry, name: u32) callconv(.c) void {
        _ = reg;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        for (self.globals.items, 0..) |g, i| {
            if (g.name == name) {
                self.alloc.free(g.interface);
                _ = self.globals.orderedRemove(i);
                return;
            }
        }
    }

    const registry_listener = wl.wl_registry_listener{
        .global = onGlobal,
        .global_remove = onGlobalRemove,
    };

    pub fn init(alloc: std.mem.Allocator) Connection {
        return .{ .alloc = alloc, .globals = .empty };
    }

    pub fn deinit(self: *Connection) void {
        self.disconnect();
        for (self.globals.items) |g| self.alloc.free(g.interface);
        self.globals.deinit(self.alloc);
        if (self.display_name) |n| self.alloc.free(n);
    }

    pub fn displayName(self: *const Connection, fallback: []const u8) []const u8 {
        return self.display_name orelse fallback;
    }

    pub fn connect(self: *Connection, name: ?[*:0]const u8) bool {
        if (self.display != null) self.disconnect();
        self.state = .connecting;
        const d = wl.wl_display_connect(name);
        if (d == null) {
            self.state = .disconnected;
            return false;
        }
        self.display = d;
        const reg = wl.wl_display_get_registry(d);
        if (reg == null) {
            self.disconnect();
            return false;
        }
        self.registry = reg;
        _ = wl.wl_registry_add_listener(reg, &registry_listener, self);
        if (wl.wl_display_roundtrip(d) < 0) {
            self.disconnect();
            return false;
        }
        self.state = .connected;
        return true;
    }

    pub fn roundtrip(self: *Connection) bool {
        if (self.display) |d| return wl.wl_display_roundtrip(d) >= 0;
        return false;
    }

    /// Ask for a fresh `ext_foreign_toplevel_list_v1`.
    ///
    /// The protocol dumps the windows that already exist exactly once, right
    /// after the object is bound — and `App.init` round-trips immediately
    /// after `bindAll`, so that dump lands before any client has had the
    /// chance to attach a listener and is dropped on the floor. Binding a
    /// second list object makes the compositor send the whole thing again, to
    /// a proxy we *can* listen on.
    pub fn rebindToplevelList(self: *Connection, bound: *Bound) void {
        const reg = self.registry orelse return;
        for (self.globals.items) |g| {
            if (!std.mem.eql(u8, g.interface, "ext_foreign_toplevel_list_v1")) continue;
            if (bound.foreign_toplevel_list) |old| wl.ext_foreign_toplevel_list_v1_destroy(old);
            const fresh = wl.wl_registry_bind(reg, g.name, &wl.ext_foreign_toplevel_list_v1_interface, 1);
            bound.foreign_toplevel_list = @ptrCast(fresh);
            return;
        }
    }

    /// Ask for a fresh `zwlr_foreign_toplevel_manager_v1`, for exactly the
    /// reason `rebindToplevelList` exists: the manager announces every
    /// existing toplevel once, right after the bind, and `bindAll`'s roundtrip
    /// eats that dump before anyone has attached a listener. Focus requests go
    /// through the handles this second manager hands out, so it has to be the
    /// one the listener is on.
    pub fn rebindForeignToplevelManager(self: *Connection, bound: *Bound) void {
        const reg = self.registry orelse return;
        for (self.globals.items) |g| {
            if (!std.mem.eql(u8, g.interface, "zwlr_foreign_toplevel_manager_v1")) continue;
            if (bound.foreign_toplevel_manager) |old| {
                wl.zwlr_foreign_toplevel_manager_v1_stop(old);
                wl.zwlr_foreign_toplevel_manager_v1_destroy(old);
            }
            const fresh = wl.wl_registry_bind(reg, g.name, &wl.zwlr_foreign_toplevel_manager_v1_interface, @min(g.version, 3));
            bound.foreign_toplevel_manager = @ptrCast(fresh);
            return;
        }
    }

    /// Push buffered requests to the compositor. Everything the shell draws
    /// goes out through `wl_surface_commit`, and without a flush (or a
    /// roundtrip, which flushes as a side effect) those commits sit in the
    /// client buffer — the surface never changes on screen.
    pub fn flush(self: *Connection) bool {
        if (self.display) |d| return wl.wl_display_flush(d) >= 0;
        return false;
    }

    pub fn displayFd(self: *Connection) i32 {
        if (self.display) |d| return wl.wl_display_get_fd(d);
        return -1;
    }

    pub fn hasInterface(self: *const Connection, interface: []const u8) bool {
        for (self.globals.items) |g| {
            if (std.mem.eql(u8, g.interface, interface)) return true;
        }
        return false;
    }

    pub fn disconnect(self: *Connection) void {
        self.unbindAll();
        if (self.registry) |r| {
            wl.wl_registry_destroy(r);
            self.registry = null;
        }
        if (self.display) |d| {
            wl.wl_display_disconnect(d);
            self.display = null;
        }
        for (self.globals.items) |g| self.alloc.free(g.interface);
        self.globals.clearRetainingCapacity();
        self.state = .disconnected;
    }

    pub const Bound = struct {
        compositor: ?*wl.wl_compositor = null,
        shm: ?*wl.wl_shm = null,
        seat: ?*wl.wl_seat = null,
        seat_obj: ?*SeatObj = null,
        layer_shell: ?*wl.zwlr_layer_shell_v1 = null,
        xdg_output_manager: ?*wl.zxdg_output_manager_v1 = null,
        xdg_wm_base: ?*wl.xdg_wm_base = null,
        ext_data_control: ?*anyopaque = null,
        wlr_data_control: ?*anyopaque = null,
        virtual_keyboard_manager: ?*wl.zwp_virtual_keyboard_manager_v1 = null,
        activation: ?*wl.xdg_activation_v1 = null,
        idle_inhibit_manager: ?*wl.zwp_idle_inhibit_manager_v1 = null,
        session_lock_manager: ?*wl.ext_session_lock_manager_v1 = null,
        gamma_manager: ?*wl.zwlr_gamma_control_manager_v1 = null,
        workspace_manager: ?*wl.ext_workspace_manager_v1 = null,
        foreign_toplevel_list: ?*wl.ext_foreign_toplevel_list_v1 = null,
        foreign_toplevel_manager: ?*wl.zwlr_foreign_toplevel_manager_v1 = null,
        toplevel_export: ?*wl.hyprland_toplevel_export_manager_v1 = null,
        focus_grab_manager: ?*wl.hyprland_focus_grab_manager_v1 = null,
        screencopy: ?*wl.zwlr_screencopy_manager_v1 = null,
        ext_image_copy_capture: ?*wl.ext_image_copy_capture_manager_v1 = null,
        ext_output_capture_source: ?*wl.ext_output_image_capture_source_manager_v1 = null,
        ext_toplevel_capture_source: ?*wl.ext_foreign_toplevel_image_capture_source_manager_v1 = null,
        outputs: std.ArrayList(*OutputObj) = .empty,
    };

    const SeatObj = @import("seat.zig").Seat;
    const OutputObj = @import("output.zig").Output;

    fn wm_base_ping_fn(
        data: ?*anyopaque,
        wm_base: ?*wl.xdg_wm_base,
        serial: u32,
    ) callconv(.c) void {
        _ = data;
        if (wm_base) |w| wl.xdg_wm_base_pong(w, serial);
    }

    const wm_base_ping_listener = wl.xdg_wm_base_listener{ .ping = wm_base_ping_fn };

    pub fn bindAll(self: *Connection, bound: *Bound) void {
        const reg = self.registry orelse return;
        for (self.globals.items) |g| {
            if (std.mem.eql(u8, g.interface, "wl_compositor")) {
                if (bound.compositor == null) {
                    bound.compositor = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.wl_compositor_interface, @min(g.version, 6)));
                }
            } else if (std.mem.eql(u8, g.interface, "wl_shm")) {
                if (bound.shm == null) {
                    bound.shm = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.wl_shm_interface, 1));
                }
            } else if (std.mem.eql(u8, g.interface, "wl_seat")) {
                if (bound.seat == null) {
                    bound.seat = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.wl_seat_interface, @min(g.version, 9)));
                    if (bound.seat) |s| {
                        const so = self.alloc.create(SeatObj) catch continue;
                        so.* = SeatObj.init(self.alloc);
                        so.bind(s);
                        bound.seat_obj = so;
                    }
                }
            } else if (std.mem.eql(u8, g.interface, "wl_output")) {
                const o = wl.wl_registry_bind(reg, g.name, &wl.wl_output_interface, @min(g.version, 4));
                if (o != null) {
                    const oo = self.alloc.create(OutputObj) catch continue;
                    oo.* = OutputObj.init(self.alloc);
                    oo.attach(@ptrCast(o));
                    bound.outputs.append(self.alloc, oo) catch {
                        self.alloc.destroy(oo);
                        continue;
                    };
                }
            } else if (std.mem.eql(u8, g.interface, "zxdg_output_manager_v1")) {
                if (bound.xdg_output_manager == null) {
                    bound.xdg_output_manager = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.zxdg_output_manager_v1_interface, @min(g.version, 3)));
                }
            } else if (std.mem.eql(u8, g.interface, "zwlr_layer_shell_v1")) {
                if (bound.layer_shell == null) {
                    bound.layer_shell = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.zwlr_layer_shell_v1_interface, @min(g.version, 4)));
                }
            } else if (std.mem.eql(u8, g.interface, "xdg_wm_base")) {
                if (bound.xdg_wm_base == null) {
                    const wm = wl.wl_registry_bind(reg, g.name, &wl.xdg_wm_base_interface, @min(g.version, 6));
                    if (wm != null) {
                        bound.xdg_wm_base = @ptrCast(wm);
                        // Pings must be answered or the compositor drops us.
                        _ = wl.xdg_wm_base_add_listener(bound.xdg_wm_base, &wm_base_ping_listener, bound.xdg_wm_base);
                    }
                }
            } else if (std.mem.eql(u8, g.interface, "ext_data_control_manager_v1")) {
                if (bound.ext_data_control == null) {
                    bound.ext_data_control = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.ext_data_control_manager_v1_interface, @min(g.version, 1)));
                }
            } else if (std.mem.eql(u8, g.interface, "zwlr_data_control_manager_v1")) {
                if (bound.wlr_data_control == null) {
                    bound.wlr_data_control = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.zwlr_data_control_manager_v1_interface, @min(g.version, 2)));
                }
            } else if (std.mem.eql(u8, g.interface, "zwp_virtual_keyboard_manager_v1")) {
                if (bound.virtual_keyboard_manager == null) {
                    bound.virtual_keyboard_manager = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.zwp_virtual_keyboard_manager_v1_interface, @min(g.version, 1)));
                }
            } else if (std.mem.eql(u8, g.interface, "xdg_activation_v1")) {
                if (bound.activation == null) {
                    bound.activation = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.xdg_activation_v1_interface, 1));
                }
            } else if (std.mem.eql(u8, g.interface, "zwp_idle_inhibit_manager_v1")) {
                if (bound.idle_inhibit_manager == null) {
                    bound.idle_inhibit_manager = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.zwp_idle_inhibit_manager_v1_interface, 1));
                }
            } else if (std.mem.eql(u8, g.interface, "ext_workspace_manager_v1")) {
                if (bound.workspace_manager == null) {
                    bound.workspace_manager = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.ext_workspace_manager_v1_interface, 1));
                }
            } else if (std.mem.eql(u8, g.interface, "ext_foreign_toplevel_list_v1")) {
                if (bound.foreign_toplevel_list == null) {
                    bound.foreign_toplevel_list = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.ext_foreign_toplevel_list_v1_interface, 1));
                }
            } else if (std.mem.eql(u8, g.interface, "zwlr_foreign_toplevel_manager_v1")) {
                // v1..v3 all work; the shell only ever calls `activate` and
                // reads `title`/`app_id`/`state`, which v1 already has.
                if (bound.foreign_toplevel_manager == null) {
                    bound.foreign_toplevel_manager = @ptrCast(
                        wl.wl_registry_bind(reg, g.name, &wl.zwlr_foreign_toplevel_manager_v1_interface, @min(g.version, 3)),
                    );
                }
            } else if (std.mem.eql(u8, g.interface, "ext_session_lock_manager_v1")) {
                if (bound.session_lock_manager == null) {
                    bound.session_lock_manager = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.ext_session_lock_manager_v1_interface, 1));
                }
            } else if (std.mem.eql(u8, g.interface, "hyprland_toplevel_export_manager_v1")) {
                if (bound.toplevel_export == null) {
                    bound.toplevel_export = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.hyprland_toplevel_export_manager_v1_interface, @min(g.version, 2)));
                }
            } else if (std.mem.eql(u8, g.interface, "hyprland_focus_grab_manager_v1")) {
                if (bound.focus_grab_manager == null) {
                    bound.focus_grab_manager = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.hyprland_focus_grab_manager_v1_interface, 1));
                }
            } else if (std.mem.eql(u8, g.interface, "zwlr_screencopy_manager_v1")) {
                if (bound.screencopy == null) {
                    bound.screencopy = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.zwlr_screencopy_manager_v1_interface, @min(g.version, 3)));
                }
            } else if (std.mem.eql(u8, g.interface, "ext_image_copy_capture_manager_v1")) {
                if (bound.ext_image_copy_capture == null) {
                    bound.ext_image_copy_capture = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.ext_image_copy_capture_manager_v1_interface, @min(g.version, 1)));
                }
            } else if (std.mem.eql(u8, g.interface, "ext_output_image_capture_source_manager_v1")) {
                if (bound.ext_output_capture_source == null) {
                    bound.ext_output_capture_source = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.ext_output_image_capture_source_manager_v1_interface, 1));
                }
            } else if (std.mem.eql(u8, g.interface, "ext_foreign_toplevel_image_capture_source_manager_v1")) {
                if (bound.ext_toplevel_capture_source == null) {
                    bound.ext_toplevel_capture_source = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1));
                }
            } else if (std.mem.eql(u8, g.interface, "zwlr_gamma_control_manager_v1")) {
                if (bound.gamma_manager == null) {
                    bound.gamma_manager = @ptrCast(wl.wl_registry_bind(reg, g.name, &wl.zwlr_gamma_control_manager_v1_interface, 1));
                }
            }
        }
        _ = wl.wl_display_roundtrip(self.display);
        // Logical geometry is a two-step handshake: the outputs only exist
        // (with names/modes) after the roundtrip above, and the zxdg_output
        // answers land on a second one. Without it the screenshot paths
        // would place regions in mode pixels instead of logical space.
        if (bound.xdg_output_manager) |mgr| {
            for (bound.outputs.items) |o| o.attachXdg(mgr);
            _ = wl.wl_display_roundtrip(self.display);
        }
    }

    pub fn unbindAll(self: *Connection) void {
        _ = self;
    }

    pub fn freeBound(self: *Connection, bound: *Bound) void {
        if (bound.seat_obj) |so| {
            so.unbind();
            so.deinit();
            self.alloc.destroy(so);
            bound.seat_obj = null;
        }
        for (bound.outputs.items) |o| {
            o.deinit();
            self.alloc.destroy(o);
        }
        bound.outputs.deinit(self.alloc);
        bound.* = .{};
    }
};

test "wl: default connection is disconnected" {
    const t = std.testing;
    var c = Connection.init(t.allocator);
    defer c.deinit();
    try t.expectEqual(ConnectionState.disconnected, c.state);
    try t.expectEqualStrings("wayland-0", c.displayName("wayland-0"));
    try t.expect(!c.roundtrip());
    try t.expectEqual(@as(i32, -1), c.displayFd());
}

test "wl: connect to live compositor and list globals" {
    const t = std.testing;
    var c = Connection.init(t.allocator);
    defer c.deinit();
    if (!c.connect(null)) return error.SkipZigTest;
    try t.expectEqual(ConnectionState.connected, c.state);
    try t.expect(c.globals.items.len > 0);
    try t.expect(c.hasInterface("wl_compositor"));
    try t.expect(c.hasInterface("wl_seat"));
    try t.expect(c.hasInterface("wl_output"));
    try t.expect(c.displayFd() >= 0);
    try t.expect(c.roundtrip());
}
