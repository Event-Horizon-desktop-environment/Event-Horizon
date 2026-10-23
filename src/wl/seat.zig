const std = @import("std");
const wl = @import("connection.zig").wl;

pub const xkb = @cImport(@cInclude("xkbcommon/xkbcommon.h"));

pub const KeyEvent = struct {
    keycode: u32 = 0,
    state: u32 = 0,
    sym: u32 = xkb.XKB_KEY_NoSymbol,
    utf8_len: usize = 0,
    utf8: [128]u8 = [_]u8{0} ** 128,
    /// Effective modifiers at the keystroke. The shell dispatches very few
    /// chorded bindings; these three are all the launcher's rail needs to
    /// tell a shortcut from a printable character.
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
};

pub const Seat = struct {
    alloc: std.mem.Allocator,
    seat: ?*wl.wl_seat = null,
    pointer: ?*wl.wl_pointer = null,
    keyboard: ?*wl.wl_keyboard = null,
    focus_surface: ?*wl.wl_surface = null,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    xkb_ctx: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,
    last_button_serial: u32 = 0,

    on_pointer_motion: ?*const fn (ctx: *anyopaque, x: f64, y: f64) void = null,
    on_pointer_button: ?*const fn (ctx: *anyopaque, button: u32, state: u32) void = null,
    on_pointer_axis: ?*const fn (ctx: *anyopaque, delta_px: f64) void = null,
    /// Detailed wheel event: raw axis value plus the physical detent count
    /// when the compositor reports one (axis_discrete / axis_value120).
    /// Clients that need one card per notch use this instead of the raw
    /// `on_pointer_axis` callback, whose axis units are compositor-defined.
    on_pointer_axis_detail: ?*const fn (ctx: *anyopaque, axis: u32, delta: f64, steps: i32) void = null,
    /// Finger-release (and wheel-stop) notifications. Added for trackpad
    /// 1:1 scrolling; the discrete `on_pointer_axis` path is untouched.
    on_pointer_axis_stop: ?*const fn (ctx: *anyopaque, axis: u32) void = null,
    /// Last `axis_source` seen (wheel/finger/continuous/tilt): lets the
    /// axis callback tell a finger glide from a wheel notch.
    axis_source: u32 = 0,
    /// Pending discrete count for the axis event in this frame. The
    /// protocol pairs every axis_discrete / axis_value120 with one axis
    /// event, so `ptrAxis` carries the count through and clears it.
    axis_steps: i32 = 0,
    axis_steps_pending: bool = false,
    on_pointer_leave: ?*const fn (ctx: *anyopaque) void = null,
    on_pointer_enter: ?*const fn (ctx: *anyopaque, x: f64, y: f64) void = null,
    on_key: ?*const fn (ctx: *anyopaque, ev: *const KeyEvent) void = null,
    cb_ctx: *anyopaque = undefined,

    const Self = @This();

    fn seatCaps(data: ?*anyopaque, seat: ?*wl.wl_seat, caps: u32) callconv(.c) void {
        _ = seat;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if ((caps & wl.WL_SEAT_CAPABILITY_POINTER) != 0 and self.pointer == null) {
            self.pointer = wl.wl_seat_get_pointer(self.seat);
            if (self.pointer) |p| _ = wl.wl_pointer_add_listener(p, &pointer_listener, self);
        } else if ((caps & wl.WL_SEAT_CAPABILITY_POINTER) == 0 and self.pointer != null) {
            wl.wl_pointer_release(self.pointer);
            self.pointer = null;
        }
        if ((caps & wl.WL_SEAT_CAPABILITY_KEYBOARD) != 0 and self.keyboard == null) {
            self.keyboard = wl.wl_seat_get_keyboard(self.seat);
            if (self.keyboard) |k| _ = wl.wl_keyboard_add_listener(k, &keyboard_listener, self);
        } else if ((caps & wl.WL_SEAT_CAPABILITY_KEYBOARD) == 0 and self.keyboard != null) {
            wl.wl_keyboard_release(self.keyboard);
            self.keyboard = null;
        }
    }

    fn seatName(data: ?*anyopaque, seat: ?*wl.wl_seat, name: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = seat;
        _ = name;
    }

    const seat_listener = wl.wl_seat_listener{
        .capabilities = seatCaps,
        .name = seatName,
    };

    fn ptrEnter(data: ?*anyopaque, ptr: ?*wl.wl_pointer, serial: u32, surface: ?*wl.wl_surface, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
        _ = ptr;
        _ = serial;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.focus_surface = surface;
        self.pointer_x = wl.wl_fixed_to_double(sx);
        self.pointer_y = wl.wl_fixed_to_double(sy);
        if (self.on_pointer_enter) |h| h(self.cb_ctx, wl.wl_fixed_to_double(sx), wl.wl_fixed_to_double(sy));
    }

    fn ptrLeave(data: ?*anyopaque, ptr: ?*wl.wl_pointer, serial: u32, surface: ?*wl.wl_surface) callconv(.c) void {
        _ = ptr;
        _ = serial;
        _ = surface;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.focus_surface = null;
        if (self.on_pointer_leave) |h| h(self.cb_ctx);
    }

    fn ptrMotion(data: ?*anyopaque, ptr: ?*wl.wl_pointer, time: u32, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
        _ = ptr;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.pointer_x = wl.wl_fixed_to_double(sx);
        self.pointer_y = wl.wl_fixed_to_double(sy);
        if (self.on_pointer_motion) |h| h(self.cb_ctx, self.pointer_x, self.pointer_y);
    }

    fn ptrButton(data: ?*anyopaque, ptr: ?*wl.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        _ = ptr;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.last_button_serial = serial;
        if (self.on_pointer_button) |h| h(self.cb_ctx, button, state);
    }

    fn ptrAxis(data: ?*anyopaque, ptr: ?*wl.wl_pointer, time: u32, axis: u32, value: wl.wl_fixed_t) callconv(.c) void {
        _ = ptr;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        const steps = if (self.axis_steps_pending) self.axis_steps else 0;
        self.axis_steps = 0;
        self.axis_steps_pending = false;
        if (self.on_pointer_axis_detail) |h| {
            h(self.cb_ctx, axis, wl.wl_fixed_to_double(value), steps);
        } else if (self.on_pointer_axis) |h| {
            h(self.cb_ctx, wl.wl_fixed_to_double(value));
        }
    }

    fn noteSteps(self: *Self, steps: i32) void {
        if (steps == 0) return;
        // One detent count for the axis event in this frame. A compositor
        // may send both axis_discrete and axis_value120 for the same notch;
        // they carry the same count, so overwriting is deliberate.
        self.axis_steps = steps;
        self.axis_steps_pending = true;
    }

    fn ptrAxisDiscrete(data: ?*anyopaque, ptr: ?*wl.wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
        _ = ptr;
        _ = axis;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.noteSteps(discrete);
    }

    fn ptrAxisValue120(data: ?*anyopaque, ptr: ?*wl.wl_pointer, axis: u32, value120: i32) callconv(.c) void {
        _ = ptr;
        _ = axis;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        // 120 units is one physical detent. High-resolution deltas below
        // one detent fall back to the raw axis path.
        self.noteSteps(@divTrunc(value120, 120));
    }

    fn noopPtr(_: ?*anyopaque, _: ?*wl.wl_pointer) callconv(.c) void {}
    fn noopPtrU(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32) callconv(.c) void {}
    fn noopPtrUU(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}

    fn ptrAxisSource(data: ?*anyopaque, ptr: ?*wl.wl_pointer, axis_source: u32) callconv(.c) void {
        _ = ptr;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.axis_source = axis_source;
    }

    fn ptrAxisStop(data: ?*anyopaque, ptr: ?*wl.wl_pointer, time: u32, axis: u32) callconv(.c) void {
        _ = ptr;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (self.on_pointer_axis_stop) |h| h(self.cb_ctx, axis);
    }

    const pointer_listener = wl.wl_pointer_listener{
        .enter = ptrEnter,
        .leave = ptrLeave,
        .motion = ptrMotion,
        .button = ptrButton,
        .axis = ptrAxis,
        .frame = noopPtr,
        .axis_source = ptrAxisSource,
        .axis_stop = ptrAxisStop,
        .axis_discrete = ptrAxisDiscrete,
        .axis_value120 = ptrAxisValue120,
        .axis_relative_direction = noopPtrUU,
    };

    fn kbKeymap(data: ?*anyopaque, kb: ?*wl.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        _ = kb;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        defer _ = std.os.linux.close(fd);
        if (format != wl.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
        const map_size: usize = size;
        const map_str = std.os.linux.mmap(null, map_size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (std.os.linux.errno(map_str) != .SUCCESS) return;
        defer _ = std.os.linux.munmap(@ptrFromInt(map_str), map_size);
        self.ensureXkb();
        if (self.xkb_ctx) |ctx| {
            const new_map = xkb.xkb_keymap_new_from_string(ctx, @ptrFromInt(map_str), xkb.XKB_KEYMAP_FORMAT_TEXT_V1, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS);
            if (new_map == null) return;
            const new_state = xkb.xkb_state_new(new_map);
            if (new_state == null) {
                xkb.xkb_keymap_unref(new_map);
                return;
            }
            if (self.xkb_state) |old| xkb.xkb_state_unref(old);
            if (self.xkb_keymap) |old| xkb.xkb_keymap_unref(old);
            self.xkb_keymap = new_map;
            self.xkb_state = new_state;
        }
    }

    fn kbKey(data: ?*anyopaque, kb: ?*wl.wl_keyboard, serial: u32, time: u32, keycode: u32, state: u32) callconv(.c) void {
        _ = kb;
        _ = serial;
        _ = time;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        var ev = KeyEvent{ .keycode = keycode, .state = state };
        if (self.xkb_state) |xstate| {
            const code = keycode + 8;
            ev.sym = xkb.xkb_state_key_get_one_sym(xstate, code);
            const n = xkb.xkb_state_key_get_utf8(xstate, code, &ev.utf8, ev.utf8.len);
            ev.utf8_len = if (n > 0) @intCast(n) else 0;
            ev.ctrl = modActive(xstate, xkb.XKB_MOD_NAME_CTRL);
            ev.alt = modActive(xstate, xkb.XKB_MOD_NAME_ALT);
            ev.meta = modActive(xstate, xkb.XKB_MOD_NAME_LOGO);
        }
        if (self.on_key) |h| h(self.cb_ctx, &ev);
    }

    fn kbModifiers(data: ?*anyopaque, kb: ?*wl.wl_keyboard, serial: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        _ = kb;
        _ = serial;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (self.xkb_state) |st| {
            _ = xkb.xkb_state_update_mask(st, depressed, latched, locked, 0, 0, group);
        }
    }

    fn noopKb(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface, _: ?*wl.wl_array) callconv(.c) void {}
    fn noopKb2(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {}
    fn noopKbII(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

    const keyboard_listener = wl.wl_keyboard_listener{
        .keymap = kbKeymap,
        .enter = noopKb,
        .leave = noopKb2,
        .key = kbKey,
        .modifiers = kbModifiers,
        .repeat_info = noopKbII,
    };

    pub fn init(alloc: std.mem.Allocator) Seat {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Seat) void {
        self.unbind();
        if (self.xkb_state) |s| xkb.xkb_state_unref(s);
        if (self.xkb_keymap) |m| xkb.xkb_keymap_unref(m);
        if (self.xkb_ctx) |c| xkb.xkb_context_unref(c);
    }

    fn ensureXkb(self: *Seat) void {
        if (self.xkb_ctx == null) {
            self.xkb_ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS);
        }
    }

    pub fn bind(self: *Seat, seat: ?*wl.wl_seat) void {
        if (seat == null) return;
        if (self.seat != null) self.unbind();
        self.seat = seat;
        _ = wl.wl_seat_add_listener(seat, &seat_listener, self);
    }

    pub fn unbind(self: *Seat) void {
        if (self.keyboard) |k| {
            wl.wl_keyboard_release(k);
            self.keyboard = null;
        }
        if (self.pointer) |p| {
            wl.wl_pointer_release(p);
            self.pointer = null;
        }
        self.seat = null;
        self.focus_surface = null;
    }
};

/// Whether a named modifier is held in the current state — what turns a
/// `Shift+1` into a chord test rather than a printable-character test.
fn modActive(state: *xkb.xkb_state, name: [*:0]const u8) bool {
    return xkb.xkb_state_mod_name_is_active(state, name, xkb.XKB_STATE_MODS_EFFECTIVE) != 0;
}

test "seat: default state is unbound" {
    const t = std.testing;
    var s = Seat.init(t.allocator);
    defer s.deinit();
    try t.expect(s.seat == null);
    try t.expect(s.pointer == null);
    try t.expect(s.keyboard == null);
    try t.expectEqual(@as(u32, 0), s.last_button_serial);
}
