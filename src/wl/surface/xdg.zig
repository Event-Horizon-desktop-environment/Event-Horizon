const std = @import("std");
const wl = @import("../c.zig").wl;

/// Managed toplevel window — Zig counterpart of the layer-shell surface in
/// `layer.zig`, but for apps that must behave like windows: movable,
/// resizable, focusable, stacked and decorated by the compositor. The
/// settings app uses this so Hyprland can place and move it like any other
/// window (the layer-shell variant was pinned and unmovable).
///
/// Configure flow per xdg-shell: the first commit after creation triggers
/// `xdg_toplevel.configure(0,0)` + `xdg_surface.configure`; the client picks
/// its size (0 = "client's choice"), acks the serial, then commits a buffer.
/// Later configures carry the size the compositor wants (resize).
pub const Toplevel = struct {
    wl_surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    toplevel: ?*wl.xdg_toplevel = null,
    configured: bool = false,
    closed: bool = false,
    /// Last size the compositor asked for; 0x0 means "client decides".
    pending_w: i32 = 0,
    pending_h: i32 = 0,
    /// Effective client size after the latest configure.
    width: i32 = 0,
    height: i32 = 0,
    last_serial: u32 = 0,
    /// Output scale the compositor prefers for this surface (1 = none, 2 = 2x
    /// HiDPI). Drives both the buffer allocation and the cairo transform, so
    /// paint code stays in logical coordinates.
    scale: i32 = 1,
    on_configure: ?*const fn (ctx: *anyopaque, w: i32, h: i32) void = null,
    on_closed: ?*const fn (ctx: *anyopaque) void = null,
    on_scale: ?*const fn (ctx: *anyopaque, scale: i32) void = null,
    ctx: *anyopaque = undefined,

    const Self = @This();

    fn toplevelConfigure(
        data: ?*anyopaque,
        toplevel: ?*wl.xdg_toplevel,
        width: i32,
        height: i32,
        states: ?*wl.wl_array,
    ) callconv(.c) void {
        _ = toplevel;
        _ = states;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.pending_w = width;
        self.pending_h = height;
    }

    fn toplevelClose(data: ?*anyopaque, toplevel: ?*wl.xdg_toplevel) callconv(.c) void {
        _ = toplevel;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.closed = true;
        if (self.on_closed) |cb| cb(self.ctx);
    }

    /// v4+ hint: the compositor's max bounds — informational only.
    fn toplevelConfigureBounds(
        data: ?*anyopaque,
        toplevel: ?*wl.xdg_toplevel,
        width: i32,
        height: i32,
    ) callconv(.c) void {
        _ = data;
        _ = toplevel;
        _ = width;
        _ = height;
    }

    /// v5+ list of supported capabilities (fullscreen/maximize/etc).
    fn toplevelWmCapabilities(
        data: ?*anyopaque,
        toplevel: ?*wl.xdg_toplevel,
        capabilities: ?*wl.wl_array,
    ) callconv(.c) void {
        _ = data;
        _ = toplevel;
        _ = capabilities;
    }

    const toplevel_listener = wl.xdg_toplevel_listener{
        .configure = toplevelConfigure,
        .close = toplevelClose,
        .configure_bounds = toplevelConfigureBounds,
        .wm_capabilities = toplevelWmCapabilities,
    };
    fn surfaceConfigure(data: ?*anyopaque, xdg_surface: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        // Ack must happen before the next commit; the size from the
        // toplevel's configure (arrived first) becomes effective here.
        if (xdg_surface) |xs| wl.xdg_surface_ack_configure(xs, serial);
        self.last_serial = serial;
        if (self.pending_w > 0 and self.pending_h > 0) {
            self.width = self.pending_w;
            self.height = self.pending_h;
        }
        self.configured = true;
        if (self.on_configure) |cb| cb(self.ctx, self.width, self.height);
    }

    const xdg_surface_listener = wl.xdg_surface_listener{
        .configure = surfaceConfigure,
    };

    /// wl_surface events: we only care about the compositor telling us the
    /// output scale it wants. Everything else (enter/leave, transform) is
    /// informational for a double-buffered shm client.
    fn surfaceEnter(data: ?*anyopaque, surface: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = output;
    }
    fn surfaceLeave(data: ?*anyopaque, surface: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = output;
    }
    fn surfacePreferredBufferScale(
        data: ?*anyopaque,
        surface: ?*wl.wl_surface,
        factor: i32,
    ) callconv(.c) void {
        _ = surface;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        const s: i32 = @max(1, factor);
        if (s == self.scale) return;
        self.scale = s;
        if (self.on_scale) |cb| cb(self.ctx, s);
    }
    fn surfacePreferredBufferTransform(
        data: ?*anyopaque,
        surface: ?*wl.wl_surface,
        transform: u32,
    ) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = transform;
    }

    const wl_surface_listener = wl.wl_surface_listener{
        .enter = surfaceEnter,
        .leave = surfaceLeave,
        .preferred_buffer_scale = surfacePreferredBufferScale,
        .preferred_buffer_transform = surfacePreferredBufferTransform,
    };

    /// Create the surface pair and the toplevel; caller commits to get the
    /// initial configure. `width`/`height` seed the client-side size until
    /// the compositor suggests one.
    pub fn create(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        wm_base: ?*wl.xdg_wm_base,
        width: i32,
        height: i32,
        title: []const u8,
        app_id: []const u8,
    ) bool {
        self.width = width;
        self.height = height;
        const comp = compositor orelse return false;
        const wm = wm_base orelse return false;
        const surf = wl.wl_compositor_create_surface(comp);
        if (surf == null) return false;
        self.wl_surface = surf;
        const xs = wl.xdg_wm_base_get_xdg_surface(wm, surf);
        if (xs == null) return false;
        self.xdg_surface = xs;
        const tl = wl.xdg_surface_get_toplevel(xs);
        if (tl == null) return false;
        self.toplevel = tl;

        var tbuf: [64]u8 = undefined;
        var abuf: [64]u8 = undefined;
        const tstr = std.fmt.bufPrintZ(&tbuf, "{s}", .{title}) catch "Settings";
        const astr = std.fmt.bufPrintZ(&abuf, "{s}", .{app_id}) catch "horizon-settings";
        wl.xdg_toplevel_set_title(tl, tstr.ptr);
        wl.xdg_toplevel_set_app_id(tl, astr.ptr);

        _ = wl.xdg_toplevel_add_listener(tl, &toplevel_listener, self);
        _ = wl.xdg_surface_add_listener(xs, &xdg_surface_listener, self);
        _ = wl.wl_surface_add_listener(surf, &wl_surface_listener, self);
        // Initial commit without a buffer: the compositor replies with the
        // first configure.
        wl.wl_surface_commit(surf);
        return true;
    }

    pub fn setMinSize(self: *Self, w: i32, h: i32) void {
        if (self.toplevel) |tl| wl.xdg_toplevel_set_min_size(tl, w, h);
    }

    /// Tell the compositor the attached buffer already carries `scale` device
    /// pixels per logical unit, so it scans it out without re-scaling.
    pub fn setBufferScale(self: *Self, scale: i32) void {
        if (self.wl_surface) |s| wl.wl_surface_set_buffer_scale(s, scale);
    }

    pub fn attach(self: *Self, buffer: ?*wl.wl_buffer, x: i32, y: i32) void {
        if (self.wl_surface) |s| wl.wl_surface_attach(s, buffer, x, y);
    }

    pub fn damage(self: *Self, x: i32, y: i32, w: i32, h: i32) void {
        if (self.wl_surface) |s| wl.wl_surface_damage(s, x, y, w, h);
    }

    pub fn commit(self: *Self) void {
        if (self.wl_surface) |s| wl.wl_surface_commit(s);
    }

    pub fn destroy(self: *Self) void {
        if (self.toplevel) |tl| {
            wl.xdg_toplevel_destroy(tl);
            self.toplevel = null;
        }
        if (self.xdg_surface) |xs| {
            wl.xdg_surface_destroy(xs);
            self.xdg_surface = null;
        }
        if (self.wl_surface) |s| {
            wl.wl_surface_destroy(s);
            self.wl_surface = null;
        }
        self.configured = false;
        self.closed = false;
    }
};

test "wl-xdg: default toplevel is unconfigured until create" {
    const t = std.testing;
    var top = Toplevel{};
    try t.expect(!top.configured);
    try t.expectEqual(@as(i32, 0), top.pending_w);
    // create without globals fails cleanly (no protocol objects made).
    try t.expect(!top.create(null, null, 900, 980, "Settings", "horizon-settings"));
    top.destroy();
}
