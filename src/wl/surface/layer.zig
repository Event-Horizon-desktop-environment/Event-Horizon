const std = @import("std");
const wl = @import("../c.zig").wl;
const logz = @import("../../logz.zig");

pub const Layer = enum(u32) {
    background = 0,
    bottom = 1,
    top = 2,
    overlay = 3,
};

pub const Anchor = struct {
    pub const top: u32 = 1;
    pub const bottom: u32 = 2;
    pub const left: u32 = 4;
    pub const right: u32 = 8;
};

/// A layer-shell surface. `create` pins the protocol listener to this
/// struct's address — do not copy or move it afterwards (e.g. into an
/// ArrayList by value): configure/closed events would land in the dead
/// source slot while the copy reads stale `configured_*` forever.
pub const Surface = struct {
    wl_surface: ?*wl.wl_surface = null,
    layer_surface: ?*wl.zwlr_layer_surface_v1 = null,
    configured_width: u32 = 0,
    configured_height: u32 = 0,
    configured: bool = false,
    closed: bool = false,
    last_serial: u32 = 0,
    /// The anchor last requested and the size last requested, kept so every
    /// commit can be checked against the protocol's rule for zero extents.
    anchor: u32 = 0,
    last_w: u32 = 0,
    last_h: u32 = 0,
    /// Output scale the compositor prefers for this surface (1 = none, 2 = 2x
    /// HiDPI). Drives both the buffer allocation and the cairo transform, so
    /// paint code stays in logical coordinates.
    scale: i32 = 1,
    on_configure: ?*const fn (ctx: *anyopaque, w: u32, h: u32) void = null,
    on_closed: ?*const fn (ctx: *anyopaque) void = null,
    on_scale: ?*const fn (ctx: *anyopaque, scale: i32) void = null,
    ctx: *anyopaque = undefined,

    const Self = @This();

    fn onConfigure(data: ?*anyopaque, surf: ?*wl.zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.configured_width = width;
        self.configured_height = height;
        self.configured = true;
        self.last_serial = serial;
        if (surf) |s| wl.zwlr_layer_surface_v1_ack_configure(s, serial);
        if (self.on_configure) |h| h(self.ctx, width, height);
    }

    fn noteClosed(data: ?*anyopaque, surf: ?*wl.zwlr_layer_surface_v1) callconv(.c) void {
        _ = surf;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.closed = true;
        if (self.on_closed) |h| h(self.ctx);
    }

    const listener = wl.zwlr_layer_surface_v1_listener{
        .configure = onConfigure,
        .closed = noteClosed,
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
        logz.log("layer: surface {?} preferred_buffer_scale {} -> {}", .{ self.wl_surface, self.scale, s });
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

    pub fn create(
        self: *Surface,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        output: ?*wl.wl_output,
        layer: Layer,
        namespace: []const u8,
    ) bool {
        if (compositor == null or shell == null) return false;
        const ws = wl.wl_compositor_create_surface(compositor);
        if (ws == null) return false;
        errdefer wl.wl_surface_destroy(ws);
        var ns_buf: [128:0]u8 = @as([128:0]u8, @splat(0));
        const n = @min(namespace.len, 127);
        @memcpy(ns_buf[0..n], namespace[0..n]);
        const ls = wl.zwlr_layer_shell_v1_get_layer_surface(shell, ws, output, @intFromEnum(layer), &ns_buf);
        if (ls == null) {
            wl.wl_surface_destroy(ws);
            return false;
        }
        _ = wl.zwlr_layer_surface_v1_add_listener(ls, &listener, self);
        _ = wl.wl_surface_add_listener(ws, &wl_surface_listener, self);
        self.wl_surface = ws;
        self.layer_surface = ls;
        return true;
    }

    /// True when the anchor spans both edges of one axis — the only case the
    /// protocol lets that axis be zero ("stretch to the anchored edges").
    fn spansAxis(anchor: u32, lo: u32, hi: u32) bool {
        return (anchor & lo) != 0 and (anchor & hi) != 0;
    }

    /// `w`/`h` with any illegal zero raised to one pixel: a surface anchored
    /// to a single horizontal edge must commit a width of at least 1, or the
    /// compositor answers `x == 0 but anchor doesn't have left and right` and
    /// drops the client (same for a single-sided vertical anchor).
    fn legalSize(self: *const Surface, w: u32, h: u32) [2]u32 {
        return .{
            if (spansAxis(self.anchor, Anchor.left, Anchor.right)) w else @max(1, w),
            if (spansAxis(self.anchor, Anchor.top, Anchor.bottom)) h else @max(1, h),
        };
    }

    pub fn setSize(self: *Surface, w: u32, h: u32) void {
        const l = self.legalSize(w, h);
        self.last_w = l[0];
        self.last_h = l[1];
        if (self.layer_surface) |ls| wl.zwlr_layer_surface_v1_set_size(ls, l[0], l[1]);
    }

    pub fn setAnchor(self: *Surface, anchor: u32) void {
        self.anchor = anchor;
        if (self.layer_surface) |ls| wl.zwlr_layer_surface_v1_set_anchor(ls, anchor);
        // A size set before the anchor may only now be recognisable as
        // illegal (or legal): re-assert it under the final anchor.
        if (self.layer_surface != null) self.setSize(self.last_w, self.last_h);
    }

    pub fn setExclusiveZone(self: *Surface, zone: i32) void {
        if (self.layer_surface) |ls| wl.zwlr_layer_surface_v1_set_exclusive_zone(ls, zone);
    }

    pub fn setMargins(self: *Surface, top: i32, right: i32, bottom: i32, left: i32) void {
        if (self.layer_surface) |ls| wl.zwlr_layer_surface_v1_set_margin(ls, top, right, bottom, left);
    }

    pub fn setKeyboardInteractivity(self: *Surface, mode: u32) void {
        if (self.layer_surface) |ls| wl.zwlr_layer_surface_v1_set_keyboard_interactivity(ls, mode);
    }

    pub fn attach(self: *Surface, buffer: ?*wl.wl_buffer, x: i32, y: i32) void {
        if (self.wl_surface) |s| wl.wl_surface_attach(s, buffer, x, y);
    }

    /// Tell the compositor the attached buffer already carries `scale` device
    /// pixels per logical unit, so it scans it out without re-scaling.
    pub fn setBufferScale(self: *Surface, scale: i32) void {
        if (self.wl_surface) |s| wl.wl_surface_set_buffer_scale(s, scale);
    }

    pub fn damage(self: *Surface, x: i32, y: i32, w: i32, h: i32) void {
        if (self.wl_surface) |s| wl.wl_surface_damage(s, x, y, w, h);
    }

    pub fn commit(self: *Surface) void {
        // A commit is where the compositor checks the layer surface's desired
        // size, so this is the choke point: a surface that was never sized
        // (or whose anchor only became known after its size) is corrected
        // here rather than costing the client its connection.
        if (self.layer_surface != null) {
            const l = self.legalSize(self.last_w, self.last_h);
            if (l[0] != self.last_w or l[1] != self.last_h) self.setSize(l[0], l[1]);
        }
        if (self.wl_surface) |s| wl.wl_surface_commit(s);
    }

    pub fn destroy(self: *Surface) void {
        // Detach the buffer and commit *before* tearing the role down: a
        // compositor that holds the dead surface's last frame for a beat
        // (or fades it out) would otherwise leave the old pixels stacked
        // under whatever replaces it — which shows up as a ghost of the
        // previous layout under the new one. Attach null before destroy.
        if (self.wl_surface) |s| {
            wl.wl_surface_attach(s, null, 0, 0);
            wl.wl_surface_damage_buffer(s, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            // Through `commit` so even a never-sized surface carries a legal
            // desired size on this final frame.
            self.commit();
        }
        if (self.layer_surface) |ls| {
            wl.zwlr_layer_surface_v1_destroy(ls);
            self.layer_surface = null;
        }
        if (self.wl_surface) |s| {
            wl.wl_surface_destroy(s);
            self.wl_surface = null;
        }
        self.configured = false;
        self.closed = false;
    }
};

test "layer: null guards" {
    const t = std.testing;
    var s = Surface{};
    defer s.destroy();
    try t.expect(!s.create(null, null, null, .top, "test"));
    try t.expect(!s.configured);
    s.setSize(100, 30);
    s.commit();
}

test "layer: a single-sided anchor never keeps a zero size" {
    const t = std.testing;
    var s = Surface{};
    defer s.destroy();
    // No compositor here, so assert the bookkeeping every commit reads.
    s.setSize(320, 40);
    try t.expectEqual(@as(u32, 320), s.last_w);
    try t.expectEqual(@as(u32, 40), s.last_h);
    // Bottom-only anchor: both extents must be at least a pixel, or the
    // compositor rejects the commit (and the client with it).
    s.setAnchor(Anchor.bottom);
    s.setSize(0, 0);
    try t.expectEqual(@as(u32, 1), s.last_w);
    try t.expectEqual(@as(u32, 1), s.last_h);
    // Spanning both horizontal edges makes a zero width legal again
    // ("stretch to the edges"); the vertical anchor is still single-sided.
    s.setAnchor(Anchor.top | Anchor.left | Anchor.right);
    s.setSize(0, 0);
    try t.expectEqual(@as(u32, 0), s.last_w);
    try t.expectEqual(@as(u32, 1), s.last_h);
}

test "layer: live single-sided anchor commit without a size survives" {
    // The bug this guards: a layer surface anchored to one edge only, with a
    // commit before any size (or a destroy before any size), made Hyprland
    // reject the commit with "x == 0 but anchor doesn't have left and right"
    // and drop the whole client. Skips without a compositor.
    const t = std.testing;
    const Conn = @import("../connection.zig").Connection;
    var conn = Conn.init(t.allocator);
    defer conn.deinit();
    if (!conn.connect(null)) return error.SkipZigTest;
    var bound = Conn.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    if (bound.compositor == null or bound.layer_shell == null) return error.SkipZigTest;

    var s = Surface{};
    defer s.destroy();
    try t.expect(s.create(bound.compositor, bound.layer_shell, null, .overlay, "eh-layer-clamp"));
    s.setAnchor(Anchor.bottom | Anchor.left);
    s.commit(); // never sized: the clamp has to cover it
    try t.expect(conn.roundtrip());
    s.destroy(); // and the null-buffer commit in destroy has to as well
    try t.expect(conn.roundtrip());
}

test "layer: live configure + shm paint round trip" {
    const t = std.testing;
    const Conn = @import("../connection.zig").Connection;
    const Shm = @import("../buffer/shm.zig");
    const Cairo = @import("../buffer/shm.zig").cairo;
    var conn = Conn.init(t.allocator);
    defer conn.deinit();
    if (!conn.connect(null)) return error.SkipZigTest;
    var bound = Conn.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    if (bound.compositor == null or bound.layer_shell == null or bound.shm == null) return error.SkipZigTest;

    var s = Surface{};
    defer s.destroy();
    try t.expect(s.create(bound.compositor, bound.layer_shell, null, .top, "eh-zigtest"));
    s.setSize(64, 16);
    s.setAnchor(Anchor.top | Anchor.left);
    s.commit();

    var ticks: u32 = 0;
    while (ticks < 100 and !s.configured) : (ticks += 1) {
        if (!conn.roundtrip()) break;
    }
    try t.expect(s.configured);

    var shm = Shm.ShmBuffer.init(t.allocator);
    defer shm.deinit();
    try t.expect(shm.ensure(bound.shm, "eh-zigtest", 64, 16));
    Cairo.cairo_set_source_rgb(shm.cr, 1.0, 0.0, 0.0);
    Cairo.cairo_paint(shm.cr.?);
    s.attach(shm.wlBuffer(), 0, 0);
    s.damage(0, 0, 64, 16);
    shm.markBusy();
    s.commit();
    ticks = 0;
    while (ticks < 100 and shm.busy) : (ticks += 1) {
        if (!conn.roundtrip()) break;
    }
    try t.expect(!shm.busy);
}
