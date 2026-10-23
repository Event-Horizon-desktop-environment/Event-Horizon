const std = @import("std");
const linux = std.os.linux;
const wl = @import("../connection.zig").wl;

const gamma = @import("../c.zig").wl;

pub const transition_duration_ms: i64 = 1500;

pub const Rgb = struct {
    r: f64,
    g: f64,
    b: f64,
};

pub fn kelvinToRgb(kelvin: i32) Rgb {
    const temp = @as(f64, @floatFromInt(@max(1000, @min(10000, kelvin)))) / 100.0;
    var mul = Rgb{ .r = 0, .g = 0, .b = 0 };
    if (temp <= 66.0) {
        mul.r = 1.0;
        mul.g = @max(0.0, @min(1.0, (99.4708025861 * std.math.log(f64, std.math.e, temp) - 161.1195681661) / 255.0));
        if (temp <= 19.0) {
            mul.b = 0.0;
        } else {
            mul.b = @max(0.0, @min(1.0, (138.5177312231 * std.math.log(f64, std.math.e, temp - 10.0) - 305.0447927307) / 255.0));
        }
    } else {
        mul.r = @max(0.0, @min(1.0, 329.698727446 * std.math.pow(f64, temp - 60.0, -0.1332047592) / 255.0));
        mul.g = @max(0.0, @min(1.0, 288.1221695283 * std.math.pow(f64, temp - 60.0, -0.0755148492) / 255.0));
        mul.b = 1.0;
    }
    return mul;
}

pub fn fillRamp(ramp: []u16, size: u32, mul: Rgb) void {
    std.debug.assert(ramp.len >= 3 * size);
    const scale = 65535.0 / @as(f64, @floatFromInt(size - 1));
    var i: u32 = 0;
    while (i < size) : (i += 1) {
        const base = @as(f64, @floatFromInt(i)) * scale;
        ramp[i] = @intFromFloat(@max(0.0, @min(65535.0, mul.r * base)));
        ramp[size + i] = @intFromFloat(@max(0.0, @min(65535.0, mul.g * base)));
        ramp[2 * size + i] = @intFromFloat(@max(0.0, @min(65535.0, mul.b * base)));
    }
}

const OutputGamma = struct {
    output: ?*wl.wl_output,
    control: ?*gamma.zwlr_gamma_control_v1 = null,
    gamma_size: u32 = 0,
    ready: bool = false,
    /// The service the size handshake has to reach back into, so the first
    /// ramp is pushed the moment the output reports its table size.
    owner: *GammaService,
};

fn onGammaSize(data: ?*anyopaque, ctrl: ?*gamma.zwlr_gamma_control_v1, size: u32) callconv(.c) void {
    _ = ctrl;
    const og: *OutputGamma = @ptrCast(@alignCast(data orelse return));
    og.gamma_size = size;
    og.ready = true;
    // The cold->warm transition is already walking by now; without this the
    // display would only pick the ramp up on the next tick (C++ does the
    // same apply in `on_gamma_size`).
    if (og.owner.enabled and og.owner.display_temperature >= 0) {
        og.owner.applyToOutput(og);
    }
}

fn onGammaFailed(data: ?*anyopaque, ctrl: ?*gamma.zwlr_gamma_control_v1) callconv(.c) void {
    _ = ctrl;
    const og: *OutputGamma = @ptrCast(@alignCast(data orelse return));
    og.ready = false;
}

const gamma_listener = gamma.zwlr_gamma_control_v1_listener{
    .gamma_size = onGammaSize,
    .failed = onGammaFailed,
};

pub const GammaService = struct {
    alloc: std.mem.Allocator,
    manager: ?*gamma.zwlr_gamma_control_manager_v1 = null,
    outputs: std.ArrayList(OutputGamma),
    enabled: bool = false,
    target_temperature: i32 = -1,
    display_temperature: i32 = -1,
    transition_from: i32 = 0,
    transition_to: i32 = 0,
    transition_start_ms: i64 = 0,
    in_transition: bool = false,

    pub fn init(alloc: std.mem.Allocator) GammaService {
        return .{ .alloc = alloc, .outputs = .empty };
    }

    pub fn deinit(self: *GammaService) void {
        self.destroyAllControls();
        self.outputs.deinit(self.alloc);
    }

    /// Turn the whole service on or off — the C++ `GammaService::set_enabled`
    /// line for line. Enabling starts a 6500K warm-up toward the target (or
    /// 4000K if none was ever set); disabling destroys the controls, which
    /// hands the output back to the compositor's own ramp in one step.
    pub fn setEnabled(self: *GammaService, on: bool, now_ms: i64) void {
        self.enabled = on;
        if (self.manager == null) return;
        if (on) {
            const target = if (self.target_temperature >= 0) self.target_temperature else 4000;
            self.target_temperature = target;
            self.transition_from = 6500;
            self.transition_to = target;
            self.transition_start_ms = now_ms;
            self.display_temperature = 6500;
            self.in_transition = true;
            for (self.outputs.items) |*og| {
                if (og.control == null) self.createControl(og);
            }
        } else {
            self.in_transition = false;
            self.display_temperature = -1;
            self.destroyAllControls();
        }
    }

    fn destroyAllControls(self: *GammaService) void {
        for (self.outputs.items) |*og| {
            if (og.control) |c| gamma.zwlr_gamma_control_v1_destroy(c);
            og.control = null;
            og.gamma_size = 0;
            og.ready = false;
        }
    }

    pub fn setTemperature(self: *GammaService, kelvin: i32, animate: bool, now_ms: i64) void {
        const clamped = @max(1000, @min(10000, kelvin));
        if (clamped == self.target_temperature and self.display_temperature >= 0) return;
        self.target_temperature = clamped;
        if (!self.enabled or self.manager == null) return;
        const from = if (self.display_temperature > 0) self.display_temperature else 6500;
        if (animate and from != self.target_temperature) {
            self.transition_from = from;
            self.transition_to = self.target_temperature;
            self.transition_start_ms = now_ms;
            self.display_temperature = from;
            self.in_transition = true;
            for (self.outputs.items) |*og| {
                if (og.control == null) self.createControl(og);
            }
        } else {
            self.in_transition = false;
            for (self.outputs.items) |*og| {
                if (og.control == null) self.createControl(og);
            }
            self.display_temperature = self.target_temperature;
            self.applyCurrent();
        }
    }

    pub fn onTimerTick(self: *GammaService, now_ms: i64) void {
        if (!self.in_transition) return;
        const elapsed = now_ms - self.transition_start_ms;
        if (elapsed >= transition_duration_ms) {
            self.display_temperature = self.transition_to;
            self.in_transition = false;
            self.applyCurrent();
            return;
        }
        const t = @as(f64, @floatFromInt(elapsed)) / @as(f64, transition_duration_ms);
        self.display_temperature = @intFromFloat(@round(@as(f64, @floatFromInt(self.transition_from)) + @as(f64, @floatFromInt(self.transition_to - self.transition_from)) * t));
        self.applyCurrent();
    }

    pub fn addOutput(self: *GammaService, output: ?*wl.wl_output) !void {
        for (self.outputs.items) |*og| {
            if (og.output == output) return;
        }
        try self.outputs.append(self.alloc, .{ .output = output, .owner = self });
        if (self.enabled and self.target_temperature >= 0) {
            self.createControl(&self.outputs.items[self.outputs.items.len - 1]);
            self.applyCurrent();
        }
    }

    pub fn removeOutput(self: *GammaService, output: ?*wl.wl_output) void {
        for (self.outputs.items, 0..) |*og, i| {
            if (og.output == output) {
                if (og.control) |c| gamma.zwlr_gamma_control_v1_destroy(c);
                _ = self.outputs.orderedRemove(i);
                return;
            }
        }
    }

    fn createControl(self: *GammaService, og: *OutputGamma) void {
        const mgr = self.manager orelse return;
        const ctrl = gamma.zwlr_gamma_control_manager_v1_get_gamma_control(mgr, og.output);
        if (ctrl == null) return;
        og.control = ctrl;
        og.gamma_size = 0;
        og.ready = false;
        _ = gamma.zwlr_gamma_control_v1_add_listener(ctrl, &gamma_listener, og);
    }

    fn applyCurrent(self: *GammaService) void {
        for (self.outputs.items) |*og| self.applyToOutput(og);
    }

    fn applyToOutput(self: *GammaService, og: *OutputGamma) void {
        if (!self.enabled or self.display_temperature < 0) return;
        if (og.control == null or og.gamma_size == 0 or !og.ready) return;
        const table_bytes: usize = 3 * og.gamma_size * @sizeOf(u16);
        var tag: [64:0]u8 = @as([64:0]u8, @splat(0));
        @memcpy(tag[0..5], "gamma");
        const fd_rc = linux.memfd_create(&tag, linux.MFD.CLOEXEC);
        if (linux.errno(fd_rc) != .SUCCESS) return;
        const fd: i32 = @intCast(fd_rc);
        if (linux.errno(linux.ftruncate(fd, @intCast(table_bytes))) != .SUCCESS) {
            _ = linux.close(fd);
            return;
        }
        const map_rc = linux.mmap(null, table_bytes, .{ .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(map_rc) != .SUCCESS) {
            _ = linux.close(fd);
            return;
        }
        const ramp: [*]u16 = @ptrFromInt(map_rc);
        fillRamp(ramp[0 .. 3 * og.gamma_size], og.gamma_size, kelvinToRgb(self.display_temperature));
        _ = linux.munmap(@ptrCast(ramp), table_bytes);
        gamma.zwlr_gamma_control_v1_set_gamma(og.control, fd);
        _ = linux.close(fd);
    }
};

test "nightlight: 6500K is near white" {
    const t = std.testing;
    const m = kelvinToRgb(6500);
    try t.expect(m.r > 0.95 and m.g > 0.95 and m.b > 0.95);
    const warm = kelvinToRgb(3000);
    try t.expect(warm.r >= warm.g and warm.g >= warm.b);
    const cool = kelvinToRgb(9000);
    try t.expect(cool.b >= cool.g and cool.g >= cool.r);
    const lo = kelvinToRgb(-500);
    const lo2 = kelvinToRgb(1000);
    try t.expectEqual(lo.r, lo2.r);
}

test "nightlight: fill ramp endpoints and monotonicity" {
    const t = std.testing;
    const size: u32 = 256;
    var ramp: [768]u16 = undefined;
    fillRamp(&ramp, size, .{ .r = 1.0, .g = 0.5, .b = 0.25 });
    try t.expectEqual(@as(u16, 0), ramp[0]);
    try t.expectEqual(@as(u16, 65535), ramp[size - 1]);
    try t.expectEqual(@as(u16, 32767), ramp[2 * size - 1]);
    var i: u32 = 1;
    while (i < size) : (i += 1) {
        try t.expect(ramp[i] >= ramp[i - 1]);
    }
}

test "nightlight: transition interpolates with fake clock" {
    const t = std.testing;
    var g = GammaService.init(t.allocator);
    defer g.deinit();
    g.enabled = true;
    g.manager = @ptrFromInt(0x1000);
    g.setTemperature(6500, false, 0);
    try t.expect(!g.in_transition);
    try t.expectEqual(@as(i32, 6500), g.display_temperature);
    g.setTemperature(4000, true, 1000);
    try t.expect(g.in_transition);
    g.onTimerTick(1000 + 750);
    const mid = g.display_temperature;
    try t.expect(mid < 6500 and mid > 4000);
    g.onTimerTick(1000 + 1500);
    try t.expect(!g.in_transition);
    try t.expectEqual(@as(i32, 4000), g.display_temperature);
}

test "nightlight: set_enabled flips state and starts the warm-up" {
    const t = std.testing;
    var g = GammaService.init(t.allocator);
    defer g.deinit();

    // No display behind the manager: the flag still flips, nothing else may
    // be touched (the compositor is free to lack gamma control).
    g.setEnabled(true, 0);
    try t.expect(g.enabled);
    try t.expect(!g.in_transition);
    try t.expectEqual(@as(i32, -1), g.display_temperature);

    // With a manager (and no outputs) enabling starts the 6500K ramp from
    // cold; the tick walks it toward the target and finishes.
    g.manager = @ptrFromInt(0x1000);
    g.setEnabled(false, 0);
    try t.expect(!g.enabled);
    g.target_temperature = 4000;
    g.setEnabled(true, 0);
    try t.expect(g.enabled);
    try t.expect(g.in_transition);
    try t.expectEqual(@as(i32, 6500), g.display_temperature);
    try t.expectEqual(@as(i32, 4000), g.transition_to);
    g.onTimerTick(transition_duration_ms);
    try t.expect(!g.in_transition);
    try t.expectEqual(@as(i32, 4000), g.display_temperature);

    // Turning it off drops the ramp straight away — the controls go, which
    // is what puts the compositor's own gamma back.
    g.setEnabled(false, transition_duration_ms);
    try t.expect(!g.enabled);
    try t.expect(!g.in_transition);
    try t.expectEqual(@as(i32, -1), g.display_temperature);
}
