//! Clock face with a digital readout.
//!
//! Like `DatePicker`, this is a display mock rather than an interactive
//! control: it draws a surface disc, twelve hour ticks, an hour and a minute
//! hand, and prints the time beneath. `setHour` clamps to 1–12, so the picker
//! is inherently 12-hour with no AM/PM indicator —
//! one.
//!
//! Both hands are measured from twelve o'clock: the angle for a hand is
//! `n * π/6` for hours (30° each) and `n * π/30` for minutes (6° each), then
//! offset by -π/2 so zero points up rather than to the right. The centre dot
//! is drawn by *reusing* the minute hand's fill colour rather than setting a
//! new source, which is why it comes out accent-coloured.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// M3 Time Picker — simple clock-face + digital display.
pub const TimePicker = struct {
    /// Face radius as a fraction of the shorter side.
    pub const kFaceFrac: f32 = 0.35;
    /// Hand and tick lengths are fractions of the face radius.
    pub const kTickInner: f32 = 0.85;
    pub const kTickOuter: f32 = 0.92;
    pub const kHourLen: f32 = 0.5;
    pub const kMinuteLen: f32 = 0.7;
    /// Centre cap radius.
    pub const kCenterR: f32 = 4.0;
    pub const kHourWidth: f32 = 3.0;
    pub const kMinuteWidth: f32 = 2.0;
    pub const kTickWidth: f32 = 1.0;

    hour: i32 = 12,
    minute: i32 = 0,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 300.0,

    accent_r: f32 = 0.769,
    accent_g: f32 = 0.659,
    accent_b: f32 = 0.941,
    surface_r: f32 = 0.102,
    surface_g: f32 = 0.075,
    surface_b: f32 = 0.188,
    text_r: f32 = 1.0,
    text_g: f32 = 1.0,
    text_b: f32 = 1.0,
    outline_r: f32 = 0.478,
    outline_g: f32 = 0.416,
    outline_b: f32 = 0.588,

    pub fn setGeometry(self: *TimePicker, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *TimePicker, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *TimePicker, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *TimePicker, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *TimePicker, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    /// Clamped to 1–12 — this picker is 12-hour only.
    pub fn setHour(self: *TimePicker, h: i32) void {
        self.hour = std.math.clamp(h, 1, 12);
    }

    /// Clamped to 0–59.
    pub fn setMinute(self: *TimePicker, m: i32) void {
        self.minute = std.math.clamp(m, 0, 59);
    }

    pub fn paint(self: *TimePicker, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        const cx = self.x + self.w * 0.5;
        const cy = self.y + self.h * 0.5;
        const face_r = @min(self.w, self.h) * kFaceFrac;

        cairo.cairo_save(cr);

        // Clock face — a flat surface disc.
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_arc(cr, cx, cy, face_r, 0.0, 2.0 * std.math.pi);
        cairo.cairo_fill(cr);

        // Twelve tick marks, just inside the rim.
        cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, 0.3);
        cairo.cairo_set_line_width(cr, kTickWidth);
        var i: usize = 0;
        while (i < 12) : (i += 1) {
            const a = @as(f32, @floatFromInt(i)) * std.math.pi / 6.0 - std.math.pi / 2.0;
            const r1 = face_r * kTickInner;
            const r2 = face_r * kTickOuter;
            cairo.cairo_move_to(cr, cx + r1 * @cos(a), cy + r1 * @sin(a));
            cairo.cairo_line_to(cr, cx + r2 * @cos(a), cy + r2 * @sin(a));
            cairo.cairo_stroke(cr);
        }

        // Hour hand — accent, 3dp wide, reaching half-way out.
        // `% 12` so a clamped 12 lands on twelve o'clock rather than a full
        // rotation past it.
        const ha = @as(f32, @floatFromInt(@rem(self.hour, 12))) * std.math.pi / 6.0 - std.math.pi / 2.0;
        cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
        cairo.cairo_set_line_width(cr, kHourWidth);
        cairo.cairo_move_to(cr, cx, cy);
        cairo.cairo_line_to(cr, cx + face_r * kHourLen * @cos(ha), cy + face_r * kHourLen * @sin(ha));
        cairo.cairo_stroke(cr);

        // Minute hand — reuses the accent source, so no colour is set here.
        const ma = @as(f32, @floatFromInt(self.minute)) * std.math.pi / 30.0 - std.math.pi / 2.0;
        cairo.cairo_set_line_width(cr, kMinuteWidth);
        cairo.cairo_move_to(cr, cx, cy);
        cairo.cairo_line_to(cr, cx + face_r * kMinuteLen * @cos(ma), cy + face_r * kMinuteLen * @sin(ma));
        cairo.cairo_stroke(cr);

        // Centre cap — filled with whatever the minute hand left selected.
        cairo.cairo_arc(cr, cx, cy, kCenterR, 0.0, 2.0 * std.math.pi);
        cairo.cairo_fill(cr);

        // Digital readout, "HH:MM", in the bottom band.
        cairo.cairo_select_font_face(
            cr,
            "Sans",
            cairo.CAIRO_FONT_SLANT_NORMAL,
            cairo.CAIRO_FONT_WEIGHT_NORMAL,
        );
        cairo.cairo_set_font_size(cr, 24);
        cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, 0.93);
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:0>2}:{d:0>2}", .{ self.hour, self.minute }) catch "";
        // The x offset is a hard-coded -28, an estimate of the readout
        // width at 24pt — not a measured centring.
        cairo.cairo_move_to(cr, cx - 28, self.y + self.h - 20);
        if (text.len != 0) cairo.cairo_show_text(cr, text.ptr);

        cairo.cairo_restore(cr);
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-time-picker: hour is clamped to 12-hour, minute to 0-59" {
    const t = testing;
    var tp = TimePicker{};
    tp.setHour(0);
    try t.expectEqual(@as(i32, 1), tp.hour);
    tp.setHour(23);
    try t.expectEqual(@as(i32, 12), tp.hour);
    tp.setMinute(99);
    try t.expectEqual(@as(i32, 59), tp.minute);
    tp.setMinute(-4);
    try t.expectEqual(@as(i32, 0), tp.minute);
}

test "m3-time-picker: paints across the dial, including hour 12" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 300);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .{ @as(i32, 12), @as(i32, 0) }, .{ @as(i32, 3), @as(i32, 15) }, .{ @as(i32, 6), @as(i32, 45) } }) |pair| {
        var tp = TimePicker{};
        tp.setGeometry(0, 0, 180, 280);
        tp.setHour(pair[0]);
        tp.setMinute(pair[1]);
        tp.paint(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = TimePicker{};
    degenerate.paint(null);
}
