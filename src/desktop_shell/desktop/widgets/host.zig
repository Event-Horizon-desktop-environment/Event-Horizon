const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const widget = @import("widget.zig");
const logz = @import("../../../logz.zig");

const clock = @import("clock.zig");
const weather = @import("weather.zig");
const system_monitor = @import("system_monitor.zig");
const weather_fancy = @import("weather_fancy.zig");
const calendar = @import("calendar.zig");
const media = @import("media.zig");
const media_compact = @import("media_compact.zig");
const world_clock = @import("world_clock.zig");
const fetch = @import("fetch.zig");
const cider = @import("cider.zig");

// Desktop widget host.
// `desktop/widgets/shared/desktop_widget_host.{hpp,cpp}`. Same design:
// one instance per config (matched by `id`), widgets rebuilt when the
// painted fields move, hover tracked by index, per-output + disabled-slot
// filtering at paint/hit time, clip + translate + scale per widget.
//
// Every widget module below provides the same surface:
//   `State`, `stateFromConfig(cfg) State`, `refresh(*State, io)`,
//   `paint(*const State, cr, Ctx)`, `size(*const State) [2]i32`,
//   and optionally `click`, `motion`, `ticks`, `anim` (host defaults apply
//   when absent via `@hasDecl`).

pub const Kind = enum {
    clock,
    weather,
    system_monitor,
    weather_fancy,
    calendar,
    media,
    media_compact,
    world_clock,
    fetch,
    cider,
};

pub const AnyWidget = union(Kind) {
    clock: clock.State,
    weather: weather.State,
    system_monitor: system_monitor.State,
    weather_fancy: weather_fancy.State,
    calendar: calendar.State,
    media: media.State,
    media_compact: media_compact.State,
    world_clock: world_clock.State,
    fetch: fetch.State,
    cider: cider.State,
};

fn kindFor(t: dw_data.WidgetType) Kind {
    return switch (t) {
        .clock => .clock,
        .weather => .weather,
        .system_monitor => .system_monitor,
        .weather_fancy => .weather_fancy,
        .calendar => .calendar,
        .media => .media,
        .media_compact => .media_compact,
        .world_clock => .world_clock,
        .fetch => .fetch,
        .cider => .cider,
    };
}

fn makeWidget(k: Kind, cfg: dw_data.WidgetConfig) AnyWidget {
    return switch (k) {
        .clock => .{ .clock = clock.stateFromConfig(cfg) },
        .weather => .{ .weather = weather.stateFromConfig(cfg) },
        .system_monitor => .{ .system_monitor = system_monitor.stateFromConfig(cfg) },
        .weather_fancy => .{ .weather_fancy = weather_fancy.stateFromConfig(cfg) },
        .calendar => .{ .calendar = calendar.stateFromConfig(cfg) },
        .media => .{ .media = media.stateFromConfig(cfg) },
        .media_compact => .{ .media_compact = media_compact.stateFromConfig(cfg) },
        .world_clock => .{ .world_clock = world_clock.stateFromConfig(cfg) },
        .fetch => .{ .fetch = fetch.stateFromConfig(cfg) },
        .cider => .{ .cider = cider.stateFromConfig(cfg) },
    };
}

fn initWidget(w: *AnyWidget, gpa: std.mem.Allocator, io: std.Io) void {
    switch (w.*) {
        .fetch => |*st| fetch.initState(st, gpa, io),
        else => {},
    }
}

fn deinitWidget(w: *AnyWidget) void {
    switch (w.*) {
        .fetch => |*st| fetch.deinitState(st),
        else => {},
    }
}

fn refreshWidget(w: *AnyWidget, io: std.Io) void {
    switch (w.*) {
        .clock => |*s| clock.refresh(s, io),
        .weather => |*s| weather.refresh(s, io),
        .system_monitor => |*s| system_monitor.refresh(s, io),
        .weather_fancy => |*s| weather_fancy.refresh(s, io),
        .calendar => |*s| calendar.refresh(s, io),
        .media => |*s| media.refresh(s, io),
        .media_compact => |*s| media_compact.refresh(s, io),
        .world_clock => |*s| world_clock.refresh(s, io),
        .fetch => |*s| fetch.refresh(s, io),
        .cider => |*s| cider.refresh(s, io),
    }
}

fn paintWidget(w: *AnyWidget, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    switch (w.*) {
        .clock => |*s| clock.paint(s, cr, ctx),
        .weather => |*s| weather.paint(s, cr, ctx),
        .system_monitor => |*s| system_monitor.paint(s, cr, ctx),
        .weather_fancy => |*s| weather_fancy.paint(s, cr, ctx),
        .calendar => |*s| calendar.paint(s, cr, ctx),
        .media => |*s| media.paint(s, cr, ctx),
        .media_compact => |*s| media_compact.paint(s, cr, ctx),
        .world_clock => |*s| world_clock.paint(s, cr, ctx),
        .fetch => |*s| fetch.paint(s, cr, ctx),
        .cider => |*s| cider.paint(s, cr, ctx),
    }
}

fn sizeWidget(w: *const AnyWidget) [2]i32 {
    return switch (w.*) {
        .clock => |*s| clock.size(s),
        .weather => |*s| weather.size(s),
        .system_monitor => |*s| system_monitor.size(s),
        .weather_fancy => |*s| weather_fancy.size(s),
        .calendar => |*s| calendar.size(s),
        .media => |*s| media.size(s),
        .media_compact => |*s| media_compact.size(s),
        .world_clock => |*s| world_clock.size(s),
        .fetch => |*s| fetch.size(s),
        .cider => |*s| cider.size(s),
    };
}

fn clickWidget(w: *AnyWidget, x: f64, y: f64) bool {
    return switch (w.*) {
        .clock => |*s| if (@hasDecl(clock, "click")) clock.click(s, x, y) else false,
        .weather => |*s| if (@hasDecl(weather, "click")) weather.click(s, x, y) else false,
        .system_monitor => |*s| if (@hasDecl(system_monitor, "click")) system_monitor.click(s, x, y) else false,
        .weather_fancy => |*s| if (@hasDecl(weather_fancy, "click")) weather_fancy.click(s, x, y) else false,
        .calendar => |*s| if (@hasDecl(calendar, "click")) calendar.click(s, x, y) else false,
        .media => |*s| if (@hasDecl(media, "click")) media.click(s, x, y) else false,
        .media_compact => |*s| if (@hasDecl(media_compact, "click")) media_compact.click(s, x, y) else false,
        .world_clock => |*s| if (@hasDecl(world_clock, "click")) world_clock.click(s, x, y) else false,
        .fetch => |*s| if (@hasDecl(fetch, "click")) fetch.click(s, x, y) else false,
        .cider => |*s| if (@hasDecl(cider, "click")) cider.click(s, x, y) else false,
    };
}

fn motionWidget(w: *AnyWidget, x: f64, y: f64) void {
    switch (w.*) {
        .clock => |*s| if (@hasDecl(clock, "motion")) clock.motion(s, x, y),
        .weather => |*s| if (@hasDecl(weather, "motion")) weather.motion(s, x, y),
        .system_monitor => |*s| if (@hasDecl(system_monitor, "motion")) system_monitor.motion(s, x, y),
        .weather_fancy => |*s| if (@hasDecl(weather_fancy, "motion")) weather_fancy.motion(s, x, y),
        .calendar => |*s| if (@hasDecl(calendar, "motion")) calendar.motion(s, x, y),
        .media => |*s| if (@hasDecl(media, "motion")) media.motion(s, x, y),
        .media_compact => |*s| if (@hasDecl(media_compact, "motion")) media_compact.motion(s, x, y),
        .world_clock => |*s| if (@hasDecl(world_clock, "motion")) world_clock.motion(s, x, y),
        .fetch => |*s| if (@hasDecl(fetch, "motion")) fetch.motion(s, x, y),
        .cider => |*s| if (@hasDecl(cider, "motion")) cider.motion(s, x, y),
    }
}

fn ticksWidget(w: *const AnyWidget) bool {
    return switch (w.*) {
        .clock => |*s| if (@hasDecl(clock, "ticks")) clock.ticks(s) else false,
        .weather => |*s| if (@hasDecl(weather, "ticks")) weather.ticks(s) else false,
        .system_monitor => |*s| if (@hasDecl(system_monitor, "ticks")) system_monitor.ticks(s) else false,
        .weather_fancy => |*s| if (@hasDecl(weather_fancy, "ticks")) weather_fancy.ticks(s) else false,
        .calendar => |*s| if (@hasDecl(calendar, "ticks")) calendar.ticks(s) else false,
        .media => |*s| if (@hasDecl(media, "ticks")) media.ticks(s) else false,
        .media_compact => |*s| if (@hasDecl(media_compact, "ticks")) media_compact.ticks(s) else false,
        .world_clock => |*s| if (@hasDecl(world_clock, "ticks")) world_clock.ticks(s) else false,
        .fetch => |*s| if (@hasDecl(fetch, "ticks")) fetch.ticks(s) else false,
        .cider => |*s| if (@hasDecl(cider, "ticks")) cider.ticks(s) else false,
    };
}

fn animWidget(w: *const AnyWidget) u32 {
    return switch (w.*) {
        .clock => |*s| if (@hasDecl(clock, "anim")) clock.anim(s) else 0,
        .weather => |*s| if (@hasDecl(weather, "anim")) weather.anim(s) else 0,
        .system_monitor => |*s| if (@hasDecl(system_monitor, "anim")) system_monitor.anim(s) else 0,
        .weather_fancy => |*s| if (@hasDecl(weather_fancy, "anim")) weather_fancy.anim(s) else 0,
        .calendar => |*s| if (@hasDecl(calendar, "anim")) calendar.anim(s) else 0,
        .media => |*s| if (@hasDecl(media, "anim")) media.anim(s) else 0,
        .media_compact => |*s| if (@hasDecl(media_compact, "anim")) media_compact.anim(s) else 0,
        .world_clock => |*s| if (@hasDecl(world_clock, "anim")) world_clock.anim(s) else 0,
        .fetch => |*s| if (@hasDecl(fetch, "anim")) fetch.anim(s) else 0,
        .cider => |*s| if (@hasDecl(cider, "anim")) cider.anim(s) else 0,
    };
}

pub const Instance = struct {
    config: dw_data.WidgetConfig,
    widget: AnyWidget,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    instances: std.ArrayListUnmanaged(Instance) = .empty,
    hovered: i32 = -1,
    disabled: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Output name -> widget fit factor, recorded during `paintAll` (the
    /// only call that sees the layer height). Hit/click/motion/resize see
    /// just the output name, so they read the factor back from here.
    /// `name` borrows the surface's `output_name` (outlives this host).
    fits: std.ArrayListUnmanaged(OutputFit) = .empty,

    const OutputFit = struct { name: []const u8, scale: f64 };

    /// Logical height the widget base sizes were authored for. `fit` scales
    /// a widget's base size by `layer_h / ref_height` so it keeps the same
    /// fraction of the screen at any resolution (720p -> 0.5, 4K -> 1.5),
    /// in logical pixels, so HiDPI stays sharp. Clamped to keep widgets
    /// usable on extreme outputs.
    const ref_height: f64 = 1440.0;

    pub fn init(gpa: std.mem.Allocator) Host {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Host) void {
        self.fits.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Record `output`'s fit factor from its layer height. Called each paint.
    fn noteFit(self: *Host, output: []const u8, layer_h: i32) void {
        const s: f64 = if (layer_h > 0)
            std.math.clamp(@as(f64, @floatFromInt(layer_h)) / ref_height, 0.25, 3.0)
        else
            1.0;
        for (self.fits.items) |*f| {
            if (std.mem.eql(u8, f.name, output)) {
                if (f.scale != s) {
                    logz.log("widgets: {s} fit {:.2} -> {:.2} (layer {}px / ref {}px)", .{ output, f.scale, s, layer_h, @as(i32, @intFromFloat(ref_height)) });
                }
                f.scale = s;
                return;
            }
        }
        logz.log("widgets: {s} fit {:.2} (layer {}px / ref {}px)", .{ output, s, layer_h, @as(i32, @intFromFloat(ref_height)) });
        self.fits.append(self.gpa, .{ .name = output, .scale = s }) catch {};
    }

    /// Fit factor for an output; 1.0 before its first paint (matches the
    /// unscaled base sizing) and for unknown/empty output names.
    fn fitFor(self: *const Host, output: []const u8) f64 {
        for (self.fits.items) |f| {
            if (std.mem.eql(u8, f.name, output)) return f.scale;
        }
        return 1.0;
    }

    fn dupeConfig(self: *Host, c: dw_data.WidgetConfig) dw_data.WidgetConfig {
        const a = self.arena.allocator();
        var out = c;
        out.id = a.dupe(u8, c.id) catch c.id;
        out.widget_id = a.dupe(u8, c.widget_id) catch c.widget_id;
        out.time_format = a.dupe(u8, c.time_format) catch c.time_format;
        out.output_name = a.dupe(u8, c.output_name) catch c.output_name;
        return out;
    }

    /// Reconcile instances with `configs`, matching by `id`. Widgets whose
    /// painted fields moved are rebuilt; the rest keep their live state.
    pub fn setConfigs(self: *Host, configs: []const dw_data.WidgetConfig, io: std.Io) void {
        const a = self.arena.allocator();
        var kept: std.ArrayListUnmanaged(Instance) = .empty;
        defer kept.deinit(a);
        for (self.instances.items) |*inst| {
            var found = false;
            for (configs) |c| {
                if (std.mem.eql(u8, c.id, inst.config.id)) {
                    found = true;
                    break;
                }
            }
            if (found) {
                kept.append(a, inst.*) catch continue;
            } else {
                deinitWidget(&inst.widget);
            }
        }
        self.instances.clearRetainingCapacity();
        for (kept.items) |inst| self.instances.append(a, inst) catch break;

        for (configs) |c| {
            var at: ?usize = null;
            for (self.instances.items, 0..) |*inst, i| {
                if (std.mem.eql(u8, inst.config.id, c.id)) {
                    at = i;
                    break;
                }
            }
            if (at) |i| {
                const inst = &self.instances.items[i];
                const changed = inst.config.pos_x != c.pos_x or inst.config.pos_y != c.pos_y or
                    inst.config.wtype != c.wtype or !std.mem.eql(u8, inst.config.time_format, c.time_format) or
                    inst.config.font_size != c.font_size or inst.config.show_seconds != c.show_seconds or
                    inst.config.show_date != c.show_date or inst.config.scale != c.scale;
                inst.config = self.dupeConfig(c);
                if (changed) {
                    deinitWidget(&inst.widget);
                    inst.widget = makeWidget(kindFor(c.wtype), inst.config);
                    initWidget(&inst.widget, self.gpa, io);
                    refreshWidget(&inst.widget, io);
                }
            } else {
                const owned = self.dupeConfig(c);
                var w = makeWidget(kindFor(c.wtype), owned);
                initWidget(&w, self.gpa, io);
                refreshWidget(&w, io);
                self.instances.append(a, .{ .config = owned, .widget = w }) catch continue;
            }
        }
        self.hovered = -1;
    }

    pub fn setDisabledSlots(self: *Host, slots: []const []const u8) void {
        self.disabled.clearRetainingCapacity();
        for (slots) |s| self.disabled.append(self.arena.allocator(), s) catch break;
        self.hovered = -1;
    }

    fn slotDisabled(self: *const Host, config: dw_data.WidgetConfig) bool {
        if (self.disabled.items.len == 0) return false;
        const wid = dw_data.slotId(config);
        for (self.disabled.items) |d| {
            if (std.mem.eql(u8, d, wid)) return true;
        }
        return false;
    }

    pub fn onSecondTick(self: *Host, io: std.Io) void {
        for (self.instances.items) |*inst| {
            if (ticksWidget(&inst.widget)) refreshWidget(&inst.widget, io);
        }
    }

    pub fn animIntervalMs(self: *const Host) u32 {
        var best: u32 = 0;
        for (self.instances.items) |*inst| {
            const iv = animWidget(&inst.widget);
            if (iv != 0 and (best == 0 or iv < best)) best = iv;
        }
        return best;
    }

    fn scaledSize(inst: *const Instance, fit: f64) [2]i32 {
        const wh = sizeWidget(&inst.widget);
        const s = inst.config.scale * fit;
        return .{
            @intFromFloat(@round(@as(f64, @floatFromInt(wh[0])) * s)),
            @intFromFloat(@round(@as(f64, @floatFromInt(wh[1])) * s)),
        };
    }

    fn visible(self: *const Host, inst: *const Instance, output: []const u8) bool {
        if (self.slotDisabled(inst.config)) return false;
        if (inst.config.output_name.len > 0 and !std.mem.eql(u8, inst.config.output_name, output)) return false;
        return true;
    }

    pub fn paintAll(self: *Host, cr: ?*cairo.cairo_t, layer_w: i32, layer_h: i32, output: []const u8, ctx: widget.Ctx) void {
        const c = cr orelse return;
        self.noteFit(output, layer_h);
        const fit = self.fitFor(output);
        for (self.instances.items) |*inst| {
            if (!self.visible(inst, output)) continue;
            const x = inst.config.pos_x;
            const y = inst.config.pos_y;
            const wh = scaledSize(inst, fit);
            if (x + wh[0] < 0 or x >= layer_w or y + wh[1] < 0 or y >= layer_h) continue;
            cairo.cairo_save(c);
            cairo.cairo_rectangle(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(wh[0]), @floatFromInt(wh[1]));
            cairo.cairo_clip(c);
            cairo.cairo_translate(c, @floatFromInt(x), @floatFromInt(y));
            const s = inst.config.scale * fit;
            if (s != 1.0) cairo.cairo_scale(c, s, s);
            paintWidget(&inst.widget, c, ctx);
            cairo.cairo_restore(c);
        }
    }

    pub fn paintResizeIndicators(self: *const Host, cr: ?*cairo.cairo_t, resize_idx: i32, output: []const u8, ctx: widget.Ctx) void {
        const c = cr orelse return;
        if (resize_idx < 0 or resize_idx >= self.instances.items.len) return;
        const inst = &self.instances.items[@intCast(resize_idx)];
        if (!self.visible(inst, output)) return;
        const fit = self.fitFor(output);
        const wh = sizeWidget(&inst.widget);
        const s = inst.config.scale * fit;
        const rx: f64 = @as(f64, @floatFromInt(inst.config.pos_x)) + @as(f64, @floatFromInt(wh[0])) * s;
        const ry: f64 = @as(f64, @floatFromInt(inst.config.pos_y)) + @as(f64, @floatFromInt(wh[1])) * s;
        const hs = 10.0;
        cairo.cairo_save(c);
        cairo.cairo_move_to(c, rx, ry);
        cairo.cairo_line_to(c, rx - hs, ry);
        cairo.cairo_line_to(c, rx, ry - hs);
        cairo.cairo_close_path(c);
        cairo.cairo_set_source_rgba(c, ctx.acc_r, ctx.acc_g, ctx.acc_b, 0.85);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, 0.9);
        cairo.cairo_set_line_width(c, 1.5);
        cairo.cairo_move_to(c, rx, ry);
        cairo.cairo_line_to(c, rx - hs, ry);
        cairo.cairo_move_to(c, rx, ry);
        cairo.cairo_line_to(c, rx, ry - hs);
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);
    }

    pub fn hitTest(self: *const Host, x: f64, y: f64, output: []const u8) i32 {
        const fit = self.fitFor(output);
        for (self.instances.items, 0..) |*inst, i| {
            if (!self.visible(inst, output)) continue;
            const wh = scaledSize(inst, fit);
            if (x >= @as(f64, @floatFromInt(inst.config.pos_x)) and
                x < @as(f64, @floatFromInt(inst.config.pos_x + wh[0])) and
                y >= @as(f64, @floatFromInt(inst.config.pos_y)) and
                y < @as(f64, @floatFromInt(inst.config.pos_y + wh[1])))
            {
                return @intCast(i);
            }
        }
        return -1;
    }

    pub fn handleClick(self: *Host, x: f64, y: f64, output: []const u8) bool {
        return self.hitTest(x, y, output) >= 0;
    }

    pub fn widgetClick(self: *Host, index: i32, x: f64, y: f64, output: []const u8) bool {
        if (index < 0 or index >= self.instances.items.len) return false;
        const inst = &self.instances.items[@intCast(index)];
        const s = inst.config.scale * self.fitFor(output);
        const lx = (x - @as(f64, @floatFromInt(inst.config.pos_x))) / s;
        const ly = (y - @as(f64, @floatFromInt(inst.config.pos_y))) / s;
        return clickWidget(&inst.widget, lx, ly);
    }

    pub fn widgetMotion(self: *Host, index: i32, x: f64, y: f64, output: []const u8) void {
        if (index < 0 or index >= self.instances.items.len) return;
        const inst = &self.instances.items[@intCast(index)];
        const s = inst.config.scale * self.fitFor(output);
        const lx = (x - @as(f64, @floatFromInt(inst.config.pos_x))) / s;
        const ly = (y - @as(f64, @floatFromInt(inst.config.pos_y))) / s;
        motionWidget(&inst.widget, lx, ly);
    }

    /// Hover routing. Returns true when the hovered index moved.
    pub fn handleMotion(self: *Host, x: f64, y: f64, output: []const u8) bool {
        const hit = self.hitTest(x, y, output);
        const changed = hit != self.hovered;
        if (changed) {
            if (self.hovered >= 0) {
                const old = &self.instances.items[@intCast(self.hovered)];
                motionWidget(&old.widget, -1, -1);
            }
            self.hovered = hit;
        }
        if (hit >= 0) self.widgetMotion(hit, x, y, output);
        return changed;
    }

    pub fn hoveredWidget(self: *const Host) i32 {
        return self.hovered;
    }

    pub fn setWidgetPosition(self: *Host, index: i32, x: i32, y: i32) void {
        if (index < 0 or index >= self.instances.items.len) return;
        const inst = &self.instances.items[@intCast(index)];
        inst.config.pos_x = x;
        inst.config.pos_y = y;
    }

    pub fn setWidgetScale(self: *Host, index: i32, scale: f64) void {
        if (index < 0 or index >= self.instances.items.len) return;
        self.instances.items[@intCast(index)].config.scale = scale;
    }

    pub fn configScale(self: *const Host, index: i32) f64 {
        if (index < 0 or index >= self.instances.items.len) return 1.0;
        return self.instances.items[@intCast(index)].config.scale;
    }

    pub fn instanceCount(self: *const Host) usize {
        return self.instances.items.len;
    }

    /// Current configs, copied into `alloc` (the layer hands these to
    /// `dw_data.save` after a drag/resize commits).
    pub fn copyConfigs(self: *const Host, alloc: std.mem.Allocator) []dw_data.WidgetConfig {
        const out = alloc.alloc(dw_data.WidgetConfig, self.instances.items.len) catch return &.{};
        for (self.instances.items, 0..) |*inst, i| out[i] = inst.config;
        return out;
    }
};

test "desktop-host: configs reconcile by id" {
    const t = std.testing;
    var h = Host.init(t.allocator);
    defer h.deinit();
    h.setConfigs(&.{
        .{ .id = "clock-1", .wtype = .clock, .pos_x = 10, .pos_y = 20 },
        .{ .id = "cal-1", .wtype = .calendar },
    }, std.testing.io);
    try t.expectEqual(@as(usize, 2), h.instanceCount());
    try t.expectEqual(@as(i32, 10), h.instances.items[0].config.pos_x);
    // Drop one, move the other: the survivor keeps its slot, the dropped
    // instance goes away.
    h.setConfigs(&.{
        .{ .id = "cal-1", .wtype = .calendar, .pos_x = 5, .pos_y = 6 },
    }, std.testing.io);
    try t.expectEqual(@as(usize, 1), h.instanceCount());
    try t.expectEqual(@as(i32, 5), h.instances.items[0].config.pos_x);
    // Same id + same fields keeps the live widget (pointer stability is
    // what lets a drag survive a config refresh).
    const before = &h.instances.items[0].widget;
    h.setConfigs(&.{
        .{ .id = "cal-1", .wtype = .calendar, .pos_x = 5, .pos_y = 6 },
    }, std.testing.io);
    try t.expect(before == &h.instances.items[0].widget);
}

test "desktop-host: hit, motion, disabled slots, output filter" {
    const t = std.testing;
    var h = Host.init(t.allocator);
    defer h.deinit();
    h.setConfigs(&.{
        .{ .id = "clock-1", .wtype = .clock, .pos_x = 10, .pos_y = 20 },
        .{ .id = "cal-1", .wtype = .calendar, .pos_x = 400, .pos_y = 20 },
    }, std.testing.io);
    // Clock has no painted size yet (0x0 until first paint); calendar is
    // 320x370 at (400,20).
    try t.expectEqual(@as(i32, 1), h.hitTest(410, 30, ""));
    try t.expectEqual(@as(i32, -1), h.hitTest(5, 5, ""));
    try t.expect(h.handleMotion(410, 30, ""));
    try t.expectEqual(@as(i32, 1), h.hoveredWidget());
    try t.expect(!h.handleMotion(411, 31, ""));
    // Disabled slot hides from hit-testing.
    h.setDisabledSlots(&.{"calendar"});
    try t.expectEqual(@as(i32, -1), h.hitTest(410, 30, ""));
    h.setDisabledSlots(&.{});
    try t.expectEqual(@as(i32, 1), h.hitTest(410, 30, ""));
    // Output-pinned instances only hit on their output.
    h.setConfigs(&.{
        .{ .id = "cal-1", .wtype = .calendar, .pos_x = 400, .pos_y = 20, .output_name = "DP-1" },
    }, std.testing.io);
    try t.expectEqual(@as(i32, -1), h.hitTest(410, 30, ""));
    try t.expectEqual(@as(i32, 0), h.hitTest(410, 30, "DP-1"));
    // Drag + scale setters feed the layer's pointer handling.
    h.setWidgetPosition(0, 7, 8);
    try t.expectEqual(@as(i32, 7), h.instances.items[0].config.pos_x);
    h.setWidgetScale(0, 2.0);
    try t.expectEqual(@as(f64, 2.0), h.configScale(0));
    try t.expectEqual(@as(f64, 1.0), h.configScale(9));
}

test "desktop-host: paint culls offscreen + disabled, clips the rest" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 800, 600);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    var h = Host.init(t.allocator);
    defer h.deinit();
    h.setConfigs(&.{
        .{ .id = "cal-1", .wtype = .calendar, .pos_x = 0, .pos_y = 0 },
        .{ .id = "off-1", .wtype = .calendar, .pos_x = 900, .pos_y = 0 },
    }, std.testing.io);
    const ctx = widget.Ctx{ .io = std.testing.io };
    h.paintAll(cr, 800, 600, "", ctx);
    h.paintResizeIndicators(cr, 0, "", ctx);
    h.paintResizeIndicators(cr, 99, "", ctx);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    try t.expectEqual(@as(u32, 0), h.animIntervalMs());
    h.onSecondTick(std.testing.io);
}
