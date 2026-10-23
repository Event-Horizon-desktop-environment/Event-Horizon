//! Simple calendar grid with month
//! header.
//!
//! This is a static display rather than a real calendar: it lays out days 1–28
//! in four fixed rows of seven, and the day/month fields are clamped on the
//! way in (`day` to 1–31, `month` to 1–12) with no check that the day is
//! valid for the month. There is no notion of which weekday the first falls
//! on, and no month navigation wired up. A static mock for the picker
//! dialog rather than a working date control.
//!
//! Text goes through cairo toy text, not pango, and the selected day's number
//! is drawn in pure white over an accent disc.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// M3 Date Picker — simple calendar grid with month navigation.
pub const DatePicker = struct {
    /// Inner padding on each side; the grid is inset by it.
    pub const kPad: f32 = 16.0;
    /// Row height.
    pub const kCellH: f32 = 36.0;
    /// Header height, where the month/year title and weekday row sit.
    pub const kHeaderH: f32 = 48.0;
    /// `corner.small`-ish radius used for the selected disc.
    pub const kRadius: f32 = 8.0;
    /// The grid always shows this many days — four rows of seven.
    pub const kDayCount: u32 = 28;
    pub const kColumnCount: f32 = 7.0;

    /// Single-letter weekday labels, Sunday first —
    /// whose duplicate "T"/"S" entries are intentional (Tue/Thu, Sat/Sun).
    pub const kDayNames = [_][]const u8{ "S", "M", "T", "W", "T", "F", "S" };

    day: i32 = 1,
    month: i32 = 1,
    year: i32 = 2025,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 360.0,

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

    pub fn setGeometry(self: *DatePicker, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *DatePicker, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *DatePicker, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *DatePicker, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *DatePicker, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    /// Clamped to 1–31 with no month-length check.
    pub fn setDay(self: *DatePicker, d: i32) void {
        self.day = std.math.clamp(d, 1, 31);
    }

    /// Clamped to 1–12.
    pub fn setMonth(self: *DatePicker, m: i32) void {
        self.month = std.math.clamp(m, 1, 12);
    }

    /// No range check — stores whatever year it is given.
    pub fn setYear(self: *DatePicker, y: i32) void {
        self.year = y;
    }

    pub fn xPos(self: *const DatePicker) f32 {
        return self.x;
    }

    pub fn yPos(self: *const DatePicker) f32 {
        return self.y;
    }

    pub fn width(self: *const DatePicker) f32 {
        return self.w;
    }

    pub fn height(self: *const DatePicker) f32 {
        return self.h;
    }

    pub fn paint(self: *DatePicker, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        const pad = kPad;
        const cell_h = kCellH;
        const cell_w = (self.w - pad * 2.0) / kColumnCount;
        const header_h = kHeaderH;

        cairo.cairo_save(cr);

        // Container — an opaque surface rectangle, not a rounded Box.
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_rectangle(cr, self.x, self.y, self.w, self.h);
        cairo.cairo_fill(cr);

        // Month/year header as "M/YYYY".
        cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, 0.93);
        cairo.cairo_select_font_face(
            cr,
            "Sans",
            cairo.CAIRO_FONT_SLANT_NORMAL,
            cairo.CAIRO_FONT_WEIGHT_NORMAL,
        );
        cairo.cairo_set_font_size(cr, 18);
        var buf: [32]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&buf, "{d}/{d}", .{ self.month, self.year }, 0) catch "";
        cairo.cairo_move_to(cr, self.x + pad, self.y + 28);
        if (title.len != 0) cairo.cairo_show_text(cr, title.ptr);

        // Weekday labels, each nudged toward its column's centre.
        cairo.cairo_set_font_size(cr, 12);
        for (kDayNames, 0..) |name, i| {
            cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, 0.46);
            const dx = self.x + pad + @as(f32, @floatFromInt(i)) * cell_w + (cell_w - 6.0) * 0.5;
            cairo.cairo_move_to(cr, dx, self.y + header_h);
            cairo.cairo_show_text(cr, name.ptr);
        }

        // Day cells — always four rows of seven, days 1 to 28.
        const grid_y = self.y + header_h + 8.0;
        var d: u32 = 1;
        while (d <= kDayCount) : (d += 1) {
            const row: f32 = @floatFromInt((d - 1) / 7);
            const col: f32 = @floatFromInt((d - 1) % 7);
            const dx = self.x + pad + col * cell_w;
            const dy = grid_y + row * cell_h;

            if (@as(i32, @intCast(d)) == self.day) {
                // Accent disc behind the number, then pure white text on top.
                cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
                cairo.cairo_arc(cr, dx + cell_w * 0.5, dy + cell_h * 0.5, cell_h * 0.4, 0.0, 2.0 * std.math.pi);
                cairo.cairo_fill(cr);
                cairo.cairo_set_source_rgba(cr, 1, 1, 1, 1);
            } else {
                cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, 0.66);
            }

            cairo.cairo_set_font_size(cr, 14);
            var dbuf: [8]u8 = undefined;
            const dtext = std.fmt.bufPrintSentinel(&dbuf, "{d}", .{d}, 0) catch continue;
            // Hard-coded nudge of -5/+5 (half-glyph estimate).
            cairo.cairo_move_to(cr, dx + cell_w * 0.5 - 5, dy + cell_h * 0.5 + 5);
            cairo.cairo_show_text(cr, dtext.ptr);
        }

        cairo.cairo_restore(cr);
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-date-picker: day and month clamp on the way in" {
    const t = testing;
    var dp = DatePicker{};
    dp.setDay(0);
    try t.expectEqual(@as(i32, 1), dp.day);
    dp.setDay(99);
    try t.expectEqual(@as(i32, 31), dp.day);
    dp.setMonth(0);
    try t.expectEqual(@as(i32, 1), dp.month);
    dp.setMonth(13);
    try t.expectEqual(@as(i32, 12), dp.month);
    // The year takes whatever it is given — no range check.
    dp.setYear(1904);
    try t.expectEqual(@as(i32, 1904), dp.year);
}

test "m3-date-picker: paints the grid, header and selection" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 260, 360);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var dp = DatePicker{};
    dp.setGeometry(0, 0, 240, 340);
    dp.setMonth(10);
    dp.setYear(2026);
    dp.setDay(14);
    dp.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Out-of-range values must still paint — the clamps make it impossible
    // to build a grid the renderer cannot draw.
    var odd = DatePicker{};
    odd.setGeometry(0, 0, 240, 340);
    odd.setDay(31);
    odd.setMonth(12);
    odd.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = DatePicker{};
    degenerate.paint(null);
}
