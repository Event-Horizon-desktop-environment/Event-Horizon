const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const host_mod = @import("host.zig");
const wc_popup = @import("../../../ux/shared/world_clock_popup.zig");
const widget = @import("widget.zig");

// Desktop widget layer glue: pointer/button handling plus the widget paint pass.
//
// Same design: a `Host` fed from `desktop_widgets_layout.txt`, left-drag
// moves widgets (clamped to >= 0), right-drag on a widget resizes it
// (`scale = start + dx/200`, clamped 0.25..4), both commit on release;
// widget clicks go to the widget first, hover tracks by index. The
// on-desktop world-clock settings dialog reuses the settings-tab popup
// module (`world_clock_popup.Popup`) with its own scaling,
// copy, but its trigger (`worldclock.settings` IPC) has no sender in the
// tree, so one dialog implementation serves both.
//
// This module owns no surfaces: the desktop process calls `paintWidgets`
// with its widget-layer cairo context per output, and `tickSecond` /
// `animIntervalMs` from its timers.

pub const Host = host_mod.Host;

pub const Layer = struct {
    host: Host = undefined,
    inited: bool = false,
    left_down: bool = false,
    drag_idx: i32 = -1,
    drag_off_x: f64 = 0,
    drag_off_y: f64 = 0,
    resize_idx: i32 = -1,
    resize_start_x: f64 = 0,
    resize_start_scale: f64 = 1.0,
    wc: wc_popup.Popup = .{},
    wc_arena: std.heap.ArenaAllocator = undefined,

    pub fn init(self: *Layer, gpa: std.mem.Allocator) void {
        if (self.inited) return;
        self.* = .{
            .host = Host.init(gpa),
            .wc_arena = std.heap.ArenaAllocator.init(gpa),
            .inited = true,
        };
    }

    pub fn deinit(self: *Layer) void {
        self.host.deinit();
        if (self.inited) self.wc_arena.deinit();
        self.inited = false;
    }

    /// Reload configs + disabled slots from disk (call on start and on
    /// `config.applied` / after the settings tab saves).
    pub fn reload(self: *Layer, io: std.Io, alloc: std.mem.Allocator, disabled: []const []const u8) void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const configs = dw_data.load(alloc, io, arena.allocator());
        self.host.setConfigs(configs, io);
        self.host.setDisabledSlots(disabled);
    }

    /// Paint every visible widget for `output` into the widget-layer
    /// context, then the resize indicator.
    /// (clear-to-transparent happens in the layer surface setup).
    pub fn paintWidgets(self: *Layer, cr: ?*cairo.cairo_t, layer_w: i32, layer_h: i32, output: []const u8, ctx: widget.Ctx) void {
        self.host.paintAll(cr, layer_w, layer_h, output, ctx);
        self.host.paintResizeIndicators(cr, self.resize_idx, output, ctx);
    }

    /// Pointer motion in layer coordinates. Returns true when the layer
    /// must repaint.
    pub fn motion(self: *Layer, x: f64, y: f64, output: []const u8) bool {
        if (self.left_down and self.drag_idx >= 0) {
            self.host.setWidgetPosition(self.drag_idx, @max(0, @as(i32, @intFromFloat(@round(x - self.drag_off_x)))), @max(0, @as(i32, @intFromFloat(@round(y - self.drag_off_y)))));
            return true;
        }
        if (self.resize_idx >= 0) {
            const scale = std.math.clamp(self.resize_start_scale + (x - self.resize_start_x) / 200.0, 0.25, 4.0);
            self.host.setWidgetScale(self.resize_idx, scale);
            return true;
        }
        return self.host.handleMotion(x, y, output) or self.host.hoveredWidget() >= 0;
    }

    pub const PressResult = enum { ignored, consumed, start_drag };

    /// Left press: widget click first, else arm a drag. Right press: arm a
    /// resize when it hits a widget. Returns whether the layer consumed it
    /// (a drag arm consumes; anything else falls through to marquee/menus).
    pub fn press(self: *Layer, x: f64, y: f64, output: []const u8, right: bool, alloc: std.mem.Allocator) PressResult {
        if (right) {
            const hit = self.host.hitTest(x, y, output);
            if (hit >= 0) {
                self.resize_idx = hit;
                self.resize_start_x = x;
                self.resize_start_scale = self.host.configScale(hit);
                return .consumed;
            }
            return .ignored;
        }
        self.left_down = true;
        const hit = self.host.hitTest(x, y, output);
        if (hit >= 0) {
            if (self.host.widgetClick(hit, x, y, output)) return .consumed;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const configs = self.host.copyConfigs(arena.allocator());
            if (hit < configs.len) {
                self.drag_idx = hit;
                self.drag_off_x = x - @as(f64, @floatFromInt(configs[@intCast(hit)].pos_x));
                self.drag_off_y = y - @as(f64, @floatFromInt(configs[@intCast(hit)].pos_y));
                return .consumed;
            }
        }
        return .ignored;
    }

    /// Button release. `save` runs when a drag or resize committed (the
    /// caller writes the returned configs via `dw_data.save`).
    pub fn release(self: *Layer, left: bool, right: bool, alloc: std.mem.Allocator) ?[]dw_data.WidgetConfig {
        if (left) {
            self.left_down = false;
            if (self.drag_idx >= 0) {
                self.drag_idx = -1;
                return self.host.copyConfigs(alloc);
            }
        }
        if (right and self.resize_idx >= 0) {
            self.resize_idx = -1;
            return self.host.copyConfigs(alloc);
        }
        return null;
    }

    /// 1s tick: refresh ticking widgets. Returns the smallest animation
    /// cadence any widget currently needs (0 = none).
    /// arms/disarms its animation timer from this).
    pub fn tickSecond(self: *Layer, io: std.Io) u32 {
        self.host.onSecondTick(io);
        return self.host.animIntervalMs();
    }

    // -- on-desktop world-clock settings (IPC `worldclock.settings`) --

    pub fn worldClockOpen(self: *Layer, io: std.Io) void {
        self.wc_arena.deinit();
        self.wc_arena = std.heap.ArenaAllocator.init(self.host.gpa);
        const a = self.wc_arena.allocator();
        self.wc.reset();
        wc_popup.loadConfig(a, io, &self.wc.cities, &self.wc.tzs);
        if (self.wc.cities.items.len == 0) {
            for ([_][]const u8{ "Cupertino", "Tokyo", "Sydney", "Paris" }) |c| {
                self.wc.cities.append(a, c) catch break;
            }
            for ([_][]const u8{ "America/Los_Angeles", "Asia/Tokyo", "Australia/Sydney", "Europe/Paris" }) |z| {
                self.wc.tzs.append(a, z) catch break;
            }
        }
        if (self.wc.tz_list.items.len == 0)
            wc_popup.enumerateZoneinfo(a, io, &self.wc.tz_list);
        self.wc.open = true;
        self.wc.just_opened = true;
    }

    pub fn worldClockClose(self: *Layer) void {
        self.wc.open = false;
        self.wc.just_opened = false;
    }
};

test "settings-desktop-layer: drag + resize gestures" {
    const t = std.testing;
    const io = std.testing.io;
    var l = Layer{};
    l.init(t.allocator);
    defer l.deinit();
    l.host.setConfigs(&.{
        .{ .id = "cal-1", .wtype = .calendar, .pos_x = 400, .pos_y = 20 },
    }, io);
    // Left press on the widget arms a drag.
    try t.expect(l.press(410, 30, "", false, t.allocator) == .consumed);
    try t.expect(l.motion(420, 40, ""));
    try t.expectEqual(@as(i32, 410), l.host.instances.items[0].config.pos_x);
    // Release commits (caller saves the returned configs).
    const committed = l.release(true, false, t.allocator);
    try t.expect(committed != null);
    defer t.allocator.free(committed.?);
    try t.expectEqual(@as(i32, 410), committed.?[0].pos_x);
    // Right press arms resize; moving right grows the scale.
    try t.expect(l.press(410, 30, "", true, t.allocator) == .consumed);
    try t.expect(l.motion(510, 30, ""));
    try t.expect(l.host.configScale(0) > 1.0);
    const committed2 = l.release(false, true, t.allocator);
    try t.expect(committed2 != null);
    defer t.allocator.free(committed2.?);
    // Click on empty space is ignored.
    try t.expect(l.press(5, 5, "", false, t.allocator) == .ignored);
}
