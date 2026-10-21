const std = @import("std");
const wl = @import("c.zig").wl;

pub const Output = struct {
    alloc: std.mem.Allocator,
    obj: ?*wl.wl_output = null,
    name: []const u8 = "",
    description: []const u8 = "",
    width: i32 = 0,
    height: i32 = 0,
    refresh_mhz: i32 = 0,
    scale: i32 = 1,
    current_mode: bool = false,
    done: bool = false,
    /// `wl_output.geometry` position — the fallback layout origin when no
    /// `zxdg_output_v1` is available (it cannot express fractional layouts).
    geo_x: i32 = 0,
    geo_y: i32 = 0,
    /// `zxdg_output_v1` logical position/size; `have_logical` marks the
    /// values as received rather than defaulted.
    xdg: ?*wl.zxdg_output_v1 = null,
    logical_x: i32 = 0,
    logical_y: i32 = 0,
    logical_w: i32 = 0,
    logical_h: i32 = 0,
    have_logical: bool = false,

    const Self = @This();

    /// One output's rectangle in the compositor's global logical space —
    /// the coordinate system layer-shell surfaces and `--geometry` speak.
    pub const Rect = struct {
        output: ?*wl.wl_output = null,
        name: []const u8 = "",
        x: i32 = 0,
        y: i32 = 0,
        w: i32 = 0,
        h: i32 = 0,
    };

    fn onGeometry(data: ?*anyopaque, o: ?*wl.wl_output, x: i32, y: i32, pw: i32, ph: i32, subpixel: i32, make: [*c]const u8, model: [*c]const u8, transform: i32) callconv(.c) void {
        _ = o;
        _ = pw;
        _ = ph;
        _ = subpixel;
        _ = make;
        _ = model;
        _ = transform;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.geo_x = x;
        self.geo_y = y;
    }

    fn onMode(data: ?*anyopaque, o: ?*wl.wl_output, flags: u32, w: i32, h: i32, refresh: i32) callconv(.c) void {
        _ = o;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if ((flags & wl.WL_OUTPUT_MODE_CURRENT) != 0) {
            self.width = w;
            self.height = h;
            self.refresh_mhz = refresh;
            self.current_mode = true;
        }
    }

    fn onDone(data: ?*anyopaque, o: ?*wl.wl_output) callconv(.c) void {
        _ = o;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.done = true;
    }

    fn onScale(data: ?*anyopaque, o: ?*wl.wl_output, factor: i32) callconv(.c) void {
        _ = o;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (factor > 0) self.scale = factor;
    }

    fn onName(data: ?*anyopaque, o: ?*wl.wl_output, name: [*c]const u8) callconv(.c) void {
        _ = o;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (name == null) return;
        const s = std.mem.span(name);
        if (self.name.len > 0) self.alloc.free(self.name);
        self.name = self.alloc.dupe(u8, s) catch return;
    }

    fn onDescription(data: ?*anyopaque, o: ?*wl.wl_output, desc: [*c]const u8) callconv(.c) void {
        _ = o;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (desc == null) return;
        const s = std.mem.span(desc);
        if (self.description.len > 0) self.alloc.free(self.description);
        self.description = self.alloc.dupe(u8, s) catch return;
    }

    const listener = wl.wl_output_listener{
        .geometry = onGeometry,
        .mode = onMode,
        .done = onDone,
        .scale = onScale,
        .name = onName,
        .description = onDescription,
    };

    pub fn init(alloc: std.mem.Allocator) Output {
        return .{ .alloc = alloc };
    }

    pub fn attach(self: *Output, obj: ?*wl.wl_output) void {
        self.obj = obj;
        if (obj) |o| _ = wl.wl_output_add_listener(o, &listener, self);
    }

    fn onXdgPosition(data: ?*anyopaque, _: ?*wl.zxdg_output_v1, x: i32, y: i32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.logical_x = x;
        self.logical_y = y;
        self.have_logical = true;
    }

    fn onXdgSize(data: ?*anyopaque, _: ?*wl.zxdg_output_v1, w: i32, h: i32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.logical_w = w;
        self.logical_h = h;
        self.have_logical = true;
    }

    fn onXdgDone(_: ?*anyopaque, _: ?*wl.zxdg_output_v1) callconv(.c) void {}
    fn onXdgName(_: ?*anyopaque, _: ?*wl.zxdg_output_v1, _: [*c]const u8) callconv(.c) void {}
    fn onXdgDescription(_: ?*anyopaque, _: ?*wl.zxdg_output_v1, _: [*c]const u8) callconv(.c) void {}

    const xdg_listener = wl.zxdg_output_v1_listener{
        .logical_position = onXdgPosition,
        .logical_size = onXdgSize,
        .done = onXdgDone,
        .name = onXdgName,
        .description = onXdgDescription,
    };

    /// Ask the compositor for this output's logical rectangle. Optional: an
    /// old compositor without xdg-output still works through `rect()`'s
    /// wl_output fallback.
    pub fn attachXdg(self: *Output, mgr: ?*wl.zxdg_output_manager_v1) void {
        if (self.xdg != null or self.obj == null or mgr == null) return;
        const x = wl.zxdg_output_manager_v1_get_xdg_output(mgr, self.obj);
        if (x == null) return;
        self.xdg = x;
        _ = wl.zxdg_output_v1_add_listener(x, &xdg_listener, self);
    }

    /// The output's rectangle in global logical coordinates. Prefers the
    /// xdg-output values (exact, supports fractional layouts) and falls back
    /// to geometry position + mode/scale the way the C++ shell does.
    pub fn rect(self: *const Self) Rect {
        const scale: i32 = if (self.scale > 0) self.scale else 1;
        var r = Rect{
            .output = self.obj,
            .name = self.name,
            .x = if (self.have_logical) self.logical_x else self.geo_x,
            .y = if (self.have_logical) self.logical_y else self.geo_y,
            .w = if (self.have_logical and self.logical_w > 0) self.logical_w else @divTrunc(@max(self.width, 1), scale),
            .h = if (self.have_logical and self.logical_h > 0) self.logical_h else @divTrunc(@max(self.height, 1), scale),
        };
        if (r.w <= 0) r.w = @max(self.width, 1);
        if (r.h <= 0) r.h = @max(self.height, 1);
        return r;
    }

    pub fn deinit(self: *Output) void {
        if (self.name.len > 0) self.alloc.free(self.name);
        if (self.description.len > 0) self.alloc.free(self.description);
        if (self.xdg) |x| wl.zxdg_output_v1_destroy(x);
        if (self.obj) |o| wl.wl_output_release(o);
    }
};

test "output: defaults sane without compositor" {
    const t = std.testing;
    var o = Output.init(t.allocator);
    defer o.deinit();
    o.attach(null);
    try t.expectEqual(@as(i32, 1), o.scale);
    try t.expect(!o.done);
}
