//! The wide weather card: the hero reading, four stat chips and the five-day
//! forecast columns. One painter, shared by the dock's weather popup and the
//! desktop weather widget, so the two cannot drift apart.
//!
//! The vertical flow is measured once and consumed by both the height query
//! and the paint, so a popup can never size its layer differently from the
//! card it is about to draw.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const text = @import("../../text/layout.zig");
const measure = @import("shared/measure_scratch.zig");
const helpers = @import("../shared/cairo_helpers.zig");
const chrome = @import("shared/chrome_colors.zig");
const svg_icons = @import("../../ux/shared/svg_icons.zig");

/// One forecast column, already reduced to what the card draws.
pub const Day = struct {
    icon: []const u8 = "cloud",
    hi: i32 = 0,
    lo: i32 = 0,
    /// 0=Sun. The label is looked up from this, so a host never has to
    /// allocate a weekday name.
    wday: u8 = 0,
};

/// The reading the card paints. The host fills this before opening the popup;
/// every string is borrowed and has to outlive the card. All the defaults are
/// the "no reading yet" picture: dashes, a cloud, four empty chips.
pub const State = struct {
    available: bool = false,
    temp: i32 = 0,
    hi: i32 = 0,
    lo: i32 = 0,
    feels_like: i32 = 0,
    humidity_pct: i32 = 0,
    wind_kmh: i32 = 0,
    visibility_m: i32 = 0,
    icon: []const u8 = "cloud",
    /// Everything before the first comma of the resolved place name.
    city: []const u8 = "",
    condition: []const u8 = "",
    days: [5]Day = @splat(.{}),
    n_days: u8 = 0,
};

pub var state: State = .{};

/// The popup's width (340px).
pub const width: f64 = 340.0;

const k_pad: f64 = 20.0;
const k_radius: f64 = 26.0;
const k_chip_h: f64 = 66.0;
const k_col_h: f64 = 78.0;
const k_chip_gap: f64 = 8.0;
const k_col_gap: f64 = 8.0;
const k_bottom_pad: f64 = 16.0;

/// The chip icon's box, and how far below that box's middle its centre sits.
/// The card asks for a little air above each icon; `k_chip_icon_dy` is the
/// one number on this card that leaves the block metrics, and only the icon
/// moves: label and value keep their positions.
const k_chip_icon_h: f64 = 15.0;
const k_chip_icon_dy: f64 = 3.0;

/// Where one chip's icon centre lands, given the icon box's top.
fn chipIconY(icon_box_y: f64) f64 {
    return icon_box_y + k_chip_icon_h * 0.5 + k_chip_icon_dy;
}

const k_wday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

pub fn wdayName(w: u8) []const u8 {
    return if (w < 7) k_wday_names[w] else "";
}

// The strings

pub const Strings = struct {
    city: []const u8 = "",
    temp: []const u8 = "--",
    cond: []const u8 = "",
    hl: []const u8 = "--",
    feels: []const u8 = "--",
    humid: []const u8 = "--",
    wind: []const u8 = "--",
    vis: []const u8 = "--",
};

/// The eight runs the card draws. The
/// scratch owns every buffer, so the card never allocates and `Strings` stays
/// valid until the scratch is filled again.
pub const Scratch = struct {
    temp_buf: [16]u8 = undefined,
    hl_buf: [32]u8 = undefined,
    feels_buf: [16]u8 = undefined,
    humid_buf: [16]u8 = undefined,
    wind_buf: [24]u8 = undefined,
    vis_buf: [24]u8 = undefined,
    day_bufs: [5][16]u8 = undefined,

    pub fn fill(self: *Scratch, s: *const State) Strings {
        var out: Strings = .{ .cond = s.condition };
        // Everything before the first comma — "Berlin, Berlin" shows as
        // "Berlin" (cut at the first comma).
        const comma = std.mem.indexOfScalar(u8, s.city, ',') orelse s.city.len;
        out.city = s.city[0..comma];
        if (!s.available) return out;
        out.temp = std.fmt.bufPrint(&self.temp_buf, "{d}\u{00b0}", .{s.temp}) catch "--";
        out.hl = std.fmt.bufPrint(&self.hl_buf, "H:{d}\u{00b0}  L:{d}\u{00b0}", .{ s.hi, s.lo }) catch "--";
        out.feels = std.fmt.bufPrint(&self.feels_buf, "{d}\u{00b0}", .{s.feels_like}) catch "--";
        out.humid = std.fmt.bufPrint(&self.humid_buf, "{d}%", .{s.humidity_pct}) catch "--";
        out.wind = std.fmt.bufPrint(&self.wind_buf, "{d} km/h", .{s.wind_kmh}) catch "--";
        out.vis = if (s.visibility_m >= 1000)
            std.fmt.bufPrint(&self.vis_buf, "{d:.0} km", .{@as(f64, @floatFromInt(s.visibility_m)) / 1000.0}) catch "--"
        else
            std.fmt.bufPrint(&self.vis_buf, "{d} m", .{s.visibility_m}) catch "--";
        return out;
    }

    /// The `21°/13°` run for one forecast column.
    pub fn dayRange(self: *Scratch, i: usize, hi: i32, lo: i32) []const u8 {
        if (i >= self.day_bufs.len) return "--";
        return std.fmt.bufPrint(&self.day_bufs[i], "{d}\u{00b0}/{d}\u{00b0}", .{ hi, lo }) catch "--";
    }
};

/// The short weekday label for one forecast column, written into `buf` so it
/// cannot alias the column's temperature run.
pub fn dayLabel(buf: []u8, wday: u8) []const u8 {
    const s = wdayName(wday);
    const n = @min(s.len, buf.len);
    if (n > 0) @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

// Pango

/// One throwaway layout carrying an "Inter <weight> <px>" description. The caller owns it.
fn makeLayout(cr: ?*cairo.cairo_t, desc: []const u8) text.Layout {
    var l = text.Layout.createForCairo(cr);
    l.setFont(desc);
    return l;
}

fn fontDesc(buf: []u8, weight: []const u8, px: f64) []const u8 {
    if (weight.len == 0) {
        return std.fmt.bufPrint(buf, "Inter {d}", .{pxToInt(px)}) catch "Inter 13";
    }
    return std.fmt.bufPrint(buf, "Inter {s} {d}", .{ weight, pxToInt(px) }) catch "Inter 13";
}

fn pxToInt(px: f64) i32 {
    return @intFromFloat(@trunc(px));
}

// Flow

const Flow = struct {
    city_y: f64 = 0,
    temp_y: f64 = 0,
    cond_y: f64 = 0,
    hl_y: f64 = 0,
    chips_y: f64 = 0,
    fore_title_y: f64 = 0,
    cols_y: f64 = 0,
    temp_h: f64 = 0,
    total_h: f64 = 0,
};

/// `fancy_weather_flow` — one vertical pass, driven by measured text heights.
/// It measures through the shared scratch context, so the number it returns
/// does not depend on the surface the card will land on.
fn flowOf(s: Strings, scratch_cr: ?*cairo.cairo_t) Flow {
    const cr = scratch_cr orelse return .{ .total_h = 380.0 };

    var buf: [32]u8 = undefined;
    var city_l = makeLayout(cr, fontDesc(&buf, "SemiBold", 15.0));
    defer city_l.destroy();
    var temp_l = makeLayout(cr, fontDesc(&buf, "Light", 56.0));
    defer temp_l.destroy();
    var cond_l = makeLayout(cr, fontDesc(&buf, "", 14.0));
    defer cond_l.destroy();
    var hl_l = makeLayout(cr, fontDesc(&buf, "", 13.0));
    defer hl_l.destroy();
    var title_l = makeLayout(cr, fontDesc(&buf, "SemiBold", 12.0));
    defer title_l.destroy();

    city_l.setText(s.city);
    const city_sz = city_l.pixelSize();
    temp_l.setText(s.temp);
    const temp_sz = temp_l.pixelSize();
    cond_l.setText(s.cond);
    const cond_sz = cond_l.pixelSize();
    hl_l.setText(s.hl);
    const hl_sz = hl_l.pixelSize();
    title_l.setText("5-Day Forecast");
    const title_sz = title_l.pixelSize();

    var f: Flow = .{};
    f.temp_h = @as(f64, @floatFromInt(temp_sz.h));
    var y: f64 = k_pad;
    f.city_y = y;
    if (s.city.len > 0) y += @as(f64, @floatFromInt(city_sz.h)) + 2.0;
    f.temp_y = y;
    y += @as(f64, @floatFromInt(temp_sz.h)) + 2.0;
    f.cond_y = y;
    y += @as(f64, @floatFromInt(cond_sz.h)) + 2.0;
    f.hl_y = y;
    y += @as(f64, @floatFromInt(hl_sz.h)) + 12.0;
    f.chips_y = y;
    y += k_chip_h + 12.0;
    f.fore_title_y = y;
    y += @as(f64, @floatFromInt(title_sz.h)) + 6.0;
    f.cols_y = y;
    y += k_col_h;
    f.total_h = @ceil(y + k_bottom_pad);
    return f;
}

/// The card's height for the current reading — what a popup host sizes its
/// layer with before the first real paint.
pub fn cardHeight(s: *const State) f64 {
    var scratch: Scratch = .{};
    const strs = scratch.fill(s);
    const cr = measure.measureCr();
    return flowOf(strs, cr).total_h;
}

// Drawing

fn showAt(cr: ?*cairo.cairo_t, l: *text.Layout, x: f64, y: f64, cc: chrome.Chrome, a: f64) void {
    const c = cr orelse return;
    cairo.cairo_move_to(c, x, y);
    cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, a);
    l.show(c);
}

/// The shell's glyph ladder: every name resolves through the Lucide SVG
/// bank (`ux/shared/lucide_icons.zig`). Answering false means the name has
/// no mapping — the one case a caller may want a shape of its own, since
/// drawing nothing beats a wrong mark.
fn glyph(cr: ?*cairo.cairo_t, name: []const u8, cx: f64, cy: f64, px: f64, cc: chrome.Chrome, a: f64) bool {
    return svg_icons.draw(cr, name, cx, cy, px, cc.accent.r, cc.accent.g, cc.accent.b, a, false);
}

/// The four chip glyphs, hand-built out of paths — the floor under `chipIcon`
/// for a hypothetical name whose SVG failed to rasterize. A hand-drawn 15 px
/// mark beats leaving the chip icon-less.
fn chipGlyph(cr: ?*cairo.cairo_t, i: usize, cx: f64, cy: f64, px: f64, cc: chrome.Chrome, a: f64) void {
    const c = cr orelse return;
    const h = px * 0.5;
    cairo.cairo_save(c);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_line_join(c, cairo.CAIRO_LINE_JOIN_ROUND);
    cairo.cairo_set_line_width(c, @max(1.3, px * 0.11));
    cairo.cairo_set_source_rgba(c, cc.accent.r, cc.accent.g, cc.accent.b, a);
    switch (i) {
        // Thermometer: a stem with a bulb.
        0 => {
            cairo.cairo_new_path(c);
            cairo.cairo_arc(c, cx, cy + h * 0.62, h * 0.34, 0.0, 2.0 * std.math.pi);
            cairo.cairo_move_to(c, cx, cy - h * 0.75);
            cairo.cairo_line_to(c, cx, cy + h * 0.4);
            cairo.cairo_stroke(c);
            cairo.cairo_new_path(c);
            cairo.cairo_arc(c, cx, cy + h * 0.62, h * 0.18, 0.0, 2.0 * std.math.pi);
            cairo.cairo_fill(c);
        },
        // Droplet.
        1 => {
            cairo.cairo_move_to(c, cx, cy - h);
            cairo.cairo_curve_to(c, cx + h, cy - h * 0.1, cx + h * 0.75, cy + h, cx, cy + h);
            cairo.cairo_curve_to(c, cx - h * 0.75, cy + h, cx - h, cy - h * 0.1, cx, cy - h);
            cairo.cairo_fill(c);
        },
        // Wind: three swept lines.
        2 => {
            var k: i32 = 0;
            while (k < 3) : (k += 1) {
                const dy = @as(f64, @floatFromInt(k - 1)) * h * 0.55;
                cairo.cairo_move_to(c, cx - h, cy + dy);
                cairo.cairo_line_to(c, cx + h * 0.55, cy + dy);
                cairo.cairo_stroke(c);
            }
        },
        // Visibility: an eye.
        else => {
            cairo.cairo_save(c);
            cairo.cairo_translate(c, cx, cy);
            cairo.cairo_scale(c, h, h * 0.62);
            cairo.cairo_new_path(c);
            cairo.cairo_arc(c, 0.0, 0.0, 1.0, 0.0, std.math.pi);
            cairo.cairo_restore(c);
            cairo.cairo_stroke(c);
            cairo.cairo_save(c);
            cairo.cairo_translate(c, cx, cy);
            cairo.cairo_scale(c, h, h * 0.62);
            cairo.cairo_new_path(c);
            cairo.cairo_arc(c, 0.0, 0.0, 1.0, std.math.pi, 2.0 * std.math.pi);
            cairo.cairo_restore(c);
            cairo.cairo_stroke(c);
            cairo.cairo_new_path(c);
            cairo.cairo_arc(c, cx, cy, h * 0.26, 0.0, 2.0 * std.math.pi);
            cairo.cairo_fill(c);
        },
    }
    cairo.cairo_restore(c);
}

const k_chip_labels = [_][]const u8{ "Feels Like", "Humidity", "Wind", "Visibility" };

/// `glyphs[]` — the material name each chip asks for; all four are mapped
/// in `lucide_icons.zig` (thermometer, droplets, wind, eye).
pub const chip_icons = [_][]const u8{ "thermostat", "humidity_percentage", "air", "visibility" };

/// One chip's icon through the shared ladder. False means the name has no
/// mapping and the caller falls back to `chipGlyph`'s hand-built path so the
/// chip still carries a mark of the right shape.
fn chipIcon(cr: ?*cairo.cairo_t, i: usize, cx: f64, cy: f64, px: f64, cc: chrome.Chrome, a: f64) bool {
    if (i >= chip_icons.len) return false;
    return glyph(cr, chip_icons[i], cx, cy, px, cc, a);
}

/// `paint_fancy_weather_card` — the whole card at (0,0)-(w, flow). Returns the
/// height it actually used so a host that owns its surface can grow to fit.
/// `card_alpha` is `overlay_opacity_widget_card`, multiplied into
/// this very fill (`0.92 * sc.appearance.overlayOpacityWidgetCard`) so the
/// compositor's namespace blur reads through the glass.
pub fn paintCard(
    cr: ?*cairo.cairo_t,
    w: f64,
    cc: chrome.Chrome,
    card_alpha: f64,
    s: *const State,
) f64 {
    const c = cr orelse return 0.0;
    var scratch: Scratch = .{};
    const strs = scratch.fill(s);
    const flow = flowOf(strs, measure.measureCr());
    const h = flow.total_h;
    const dim: f64 = if (s.available) 1.0 else 0.45;

    var buf: [48]u8 = undefined;

    cairo.cairo_save(c);

    // Dark glass card, one fill and one hairline so the corners stay crisp.
    helpers.roundedRect(c, 0.0, 0.0, w, h, k_radius);
    cairo.cairo_set_source_rgba(
        c,
        cc.dock_fill.r * 0.30,
        cc.dock_fill.g * 0.30,
        cc.dock_fill.b * 0.30,
        0.92 * card_alpha,
    );
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    // Hero text block.
    var city_l = makeLayout(c, fontDesc(&buf, "SemiBold", 15.0));
    defer city_l.destroy();
    var temp_l = makeLayout(c, fontDesc(&buf, "Light", 56.0));
    defer temp_l.destroy();
    var cond_l = makeLayout(c, fontDesc(&buf, "", 14.0));
    defer cond_l.destroy();
    var hl_l = makeLayout(c, fontDesc(&buf, "", 13.0));
    defer hl_l.destroy();

    if (strs.city.len > 0) {
        city_l.setText(strs.city);
        showAt(c, &city_l, k_pad, flow.city_y, cc, 0.78 * dim);
    }
    temp_l.setText(strs.temp);
    showAt(c, &temp_l, k_pad, flow.temp_y, cc, 0.96 * dim);
    cond_l.setText(strs.cond);
    showAt(c, &cond_l, k_pad, flow.cond_y, cc, 0.70 * dim);
    hl_l.setText(strs.hl);
    showAt(c, &hl_l, k_pad, flow.hl_y, cc, 0.70 * dim);

    // Hero glyph on the right, centred on the temperature block, in a soft
    // accent halo.
    const hero = if (s.available and s.icon.len > 0) s.icon else "cloud";
    const hero_cx = w - k_pad - 30.0;
    const hero_cy = flow.temp_y + flow.temp_h * 0.5;
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, hero_cx, hero_cy, 34.0, 0.0, 2.0 * std.math.pi);
    cairo.cairo_set_source_rgba(c, cc.accent.r, cc.accent.g, cc.accent.b, 0.14 * dim);
    cairo.cairo_fill(c);
    _ = glyph(c, hero, hero_cx, hero_cy, 52.0, cc, 0.92 * dim);

    // Stat chips.
    var lab_l = makeLayout(c, fontDesc(&buf, "", 9.0));
    defer lab_l.destroy();
    var val_l = makeLayout(c, fontDesc(&buf, "SemiBold", 13.0));
    defer val_l.destroy();
    var val_sm_l = makeLayout(c, fontDesc(&buf, "SemiBold", 11.0));
    defer val_sm_l.destroy();

    const values = [4][]const u8{ strs.feels, strs.humid, strs.wind, strs.vis };
    const chip_w = (w - k_pad * 2.0 - k_chip_gap * 3.0) / 4.0;
    for (0..4) |i| {
        const sx = k_pad + @as(f64, @floatFromInt(i)) * (chip_w + k_chip_gap);
        helpers.roundedRect(c, sx, flow.chips_y, chip_w, k_chip_h, 14.0);
        cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.08);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.12);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_stroke(c);

        lab_l.setText(k_chip_labels[i]);
        const lab_sz = lab_l.pixelSize();
        // Shrink-to-fit so a long value ("12 km/h", "42 km") never crowds the
        // edge.
        val_l.setText(values[i]);
        var val_sz = val_l.pixelSize();
        var use_l = &val_l;
        if (@as(f64, @floatFromInt(val_sz.w)) > chip_w - 16.0) {
            val_sm_l.setText(values[i]);
            val_sz = val_sm_l.pixelSize();
            use_l = &val_sm_l;
        }

        const lab_h = @as(f64, @floatFromInt(lab_sz.h));
        const val_h = @as(f64, @floatFromInt(val_sz.h));
        const block_h = k_chip_icon_h + 6.0 + lab_h + 3.0 + val_h;
        const block_y = flow.chips_y + (k_chip_h - block_h) * 0.5;
        const label_y = block_y + k_chip_icon_h + 6.0;
        const value_y = label_y + lab_h + 3.0;

        const icon_cx = sx + chip_w * 0.5;
        const icon_cy = chipIconY(block_y);
        if (!chipIcon(c, i, icon_cx, icon_cy, k_chip_icon_h, cc, 0.85 * dim)) {
            chipGlyph(c, i, icon_cx, icon_cy, k_chip_icon_h, cc, 0.85 * dim);
        }
        showAt(
            c,
            &lab_l,
            sx + (chip_w - @as(f64, @floatFromInt(lab_sz.w))) * 0.5,
            label_y,
            cc,
            0.60 * dim,
        );
        cairo.cairo_move_to(
            c,
            sx + (chip_w - @as(f64, @floatFromInt(val_sz.w))) * 0.5,
            value_y,
        );
        cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.92 * dim);
        use_l.show(c);
    }

    // Five-day forecast columns.
    var title_l = makeLayout(c, fontDesc(&buf, "SemiBold", 12.0));
    defer title_l.destroy();
    title_l.setText("5-Day Forecast");
    showAt(c, &title_l, k_pad, flow.fore_title_y, cc, 0.80 * dim);

    var day_l = makeLayout(c, fontDesc(&buf, "SemiBold", 11.0));
    defer day_l.destroy();
    var tmp_l = makeLayout(c, fontDesc(&buf, "", 11.0));
    defer tmp_l.destroy();

    const col_w = (w - k_pad * 2.0 - k_col_gap * 4.0) / 5.0;
    var label_buf: [8]u8 = undefined;
    for (0..5) |i| {
        const cx = k_pad + @as(f64, @floatFromInt(i)) * (col_w + k_col_gap);
        const is_today = i == 0 and s.n_days > 0;
        helpers.roundedRect(c, cx, flow.cols_y, col_w, k_col_h, 14.0);
        if (is_today) {
            cairo.cairo_set_source_rgba(c, cc.accent.r, cc.accent.g, cc.accent.b, 0.22 * dim + 0.05);
        } else {
            cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.07);
        }
        cairo.cairo_fill_preserve(c);
        if (is_today) {
            cairo.cairo_set_source_rgba(c, cc.accent.r, cc.accent.g, cc.accent.b, 0.45);
        } else {
            cairo.cairo_set_source_rgba(c, cc.text.r, cc.text.g, cc.text.b, 0.10);
        }
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_stroke(c);

        if (i >= s.n_days) continue;
        const d = s.days[i];
        day_l.setText(dayLabel(&label_buf, d.wday));
        const day_sz = day_l.pixelSize();
        showAt(
            c,
            &day_l,
            cx + (col_w - @as(f64, @floatFromInt(day_sz.w))) * 0.5,
            flow.cols_y + 8.0,
            cc,
            if (is_today) 0.95 * dim else 0.75 * dim,
        );
        _ = glyph(c, d.icon, cx + col_w * 0.5, flow.cols_y + 38.0, 19.0, cc, 0.90 * dim);

        const run = scratch.dayRange(i, d.hi, d.lo);
        tmp_l.setText(run);
        const tmp_sz = tmp_l.pixelSize();
        showAt(
            c,
            &tmp_l,
            cx + (col_w - @as(f64, @floatFromInt(tmp_sz.w))) * 0.5,
            flow.cols_y + k_col_h - @as(f64, @floatFromInt(tmp_sz.h)) - 8.0,
            cc,
            0.85 * dim,
        );
    }

    cairo.cairo_restore(c);
    return h;
}

// Tests

/// Test-only: blank the frame the way the popup host does before a card
/// paints, so any ink counted afterwards is a glyph's own.
fn clearFrame(cr: ?*cairo.cairo_t) void {
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
}

/// Test-only: the alpha of every pixel of an ARGB frame, row-major.
fn grabAlpha(surf: ?*cairo.cairo_surface_t, w: i32, h: i32, out: []u8) void {
    _ = cairo.cairo_surface_flush(surf);
    const data: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const stride: i32 = @intCast(cairo.cairo_image_surface_get_stride(surf));
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const src = @as(usize, @intCast(y * stride + x * 4 + 3));
            out[@as(usize, @intCast(y * w + x))] = data[src];
        }
    }
}

/// Test-only: how wide the ink on an ARGB frame is, 0 when there is none.
fn inkWidth(surf: ?*cairo.cairo_surface_t, w: i32, h: i32) i32 {
    var px: [96 * 24]u8 = undefined;
    std.debug.assert(w >= 0 and h >= 0 and @as(usize, @intCast(w * h)) <= px.len);
    grabAlpha(surf, w, h, &px);
    var min_x: i32 = w;
    var max_x: i32 = -1;
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            if (px[@as(usize, @intCast(y * w + x))] <= 8) continue;
            min_x = @min(min_x, x);
            max_x = @max(max_x, x);
        }
    }
    if (max_x < 0) return 0;
    return max_x - min_x + 1;
}

test "fancy-weather-card: the strings are the specified set" {
    const t = std.testing;
    var s: Scratch = .{};
    var w: State = .{
        .available = true,
        .temp = 17,
        .hi = 19,
        .lo = 9,
        .feels_like = 15,
        .humidity_pct = 71,
        .wind_kmh = 12,
        .visibility_m = 24000,
        .city = "Berlin, Berlin",
        .condition = "Light rain",
    };
    const strs = s.fill(&w);
    try t.expectEqualStrings("Berlin", strs.city);
    try t.expectEqualStrings("17\u{00b0}", strs.temp);
    try t.expectEqualStrings("Light rain", strs.cond);
    try t.expectEqualStrings("H:19\u{00b0}  L:9\u{00b0}", strs.hl);
    try t.expectEqualStrings("15\u{00b0}", strs.feels);
    try t.expectEqualStrings("71%", strs.humid);
    try t.expectEqualStrings("12 km/h", strs.wind);
    try t.expectEqualStrings("24 km", strs.vis);

    // Sub-kilometre visibility prints metres instead.
    w.visibility_m = 850;
    const strs2 = s.fill(&w);
    try t.expectEqualStrings("850 m", strs2.vis);
}

test "fancy-weather-card: without a reading every run is a dash" {
    const t = std.testing;
    var s: Scratch = .{};
    const w: State = .{ .city = "Lisbon, Lisbon", .condition = "Weather unavailable" };
    const strs = s.fill(&w);
    try t.expectEqualStrings("--", strs.temp);
    try t.expectEqualStrings("--", strs.hl);
    try t.expectEqualStrings("--", strs.feels);
    try t.expectEqualStrings("--", strs.humid);
    try t.expectEqualStrings("--", strs.wind);
    try t.expectEqualStrings("--", strs.vis);
    // The two borrowed strings still come through.
    try t.expectEqualStrings("Lisbon", strs.city);
    try t.expectEqualStrings("Weather unavailable", strs.cond);
}

test "fancy-weather-card: column runs and weekday labels" {
    const t = std.testing;
    var s: Scratch = .{};
    try t.expectEqualStrings("21\u{00b0}/13\u{00b0}", s.dayRange(0, 21, 13));
    try t.expectEqualStrings("-4\u{00b0}/-9\u{00b0}", s.dayRange(4, -4, -9));
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("Sun", dayLabel(&buf, 0));
    try t.expectEqualStrings("Sat", dayLabel(&buf, 6));
    try t.expectEqualStrings("", dayLabel(&buf, 7));
    try t.expectEqualStrings("", wdayName(99));
}

test "fancy-weather-card: the height is positive with and without a reading" {
    const t = std.testing;
    const empty = cardHeight(&.{});
    try t.expect(empty > 0.0);
    const full = cardHeight(&State{
        .available = true,
        .temp = 21,
        .hi = 24,
        .lo = 14,
        .city = "Springfield, Illinois",
        .condition = "Partly cloudy",
        .n_days = 5,
    });
    try t.expect(full > 0.0);
    // A city adds a line; a reading adds the chips and the columns.
    try t.expect(full > empty);
}

test "fancy-weather-card: the card is translucent, so the compositor's blur reads" {
    const t = std.testing;
    const w: i32 = @intFromFloat(width);
    const h: i32 = @intFromFloat(@round(cardHeight(&.{})));
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    // The popup host clears its frame to genuine transparency before every
    // card paints, so the fill composites onto alpha 0 the way it does live.
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);

    _ = paintCard(cr, width, .{}, 1.0, &.{});
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    _ = cairo.cairo_surface_flush(surf);
    const data: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const stride: i32 = @intCast(cairo.cairo_image_surface_get_stride(surf));
    // Cairo's ARGB32 is little-endian premultiplied: byte 3 is alpha. `k_pad`
    // is 20 and every string starts there, so the left margin at mid-height
    // is card fill alone — no glyph, no hairline (that sits at x = 0 ± 0.5).
    const x: i32 = 4;
    const y: i32 = @divTrunc(h, 2);
    const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(stride)) + @as(usize, @intCast(x)) * 4;
    const full = data[idx + 3];
    // 0.92 nominal fill over a cleared buffer: opaque, but *not* the solid
    // 255 the card painted before the alpha knob was plumbed through.
    try t.expect(full > 225 and full < 245);

    // The widget-card knob is what the blur reads through: at the live 0.18
    // the card keeps a fifth of its ink, so the namespace blur dominates it.
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
    _ = paintCard(cr, width, .{}, 0.18, &.{});
    _ = cairo.cairo_surface_flush(surf);
    const thin = data[idx + 3];
    try t.expect(thin > 30 and thin < 55 and thin < full);
}

test "fancy-weather-card: the chips ask for the material glyphs" {
    const t = std.testing;
    // `glyphs[]` in chip-loop order.
    try t.expectEqual(@as(usize, 4), chip_icons.len);
    try t.expectEqualStrings("thermostat", chip_icons[0]);
    try t.expectEqualStrings("humidity_percentage", chip_icons[1]);
    try t.expectEqualStrings("air", chip_icons[2]);
    try t.expectEqualStrings("visibility", chip_icons[3]);
    try t.expectEqualStrings("Feels Like", k_chip_labels[0]);
    try t.expectEqualStrings("Humidity", k_chip_labels[1]);
    try t.expectEqualStrings("Wind", k_chip_labels[2]);
    try t.expectEqualStrings("Visibility", k_chip_labels[3]);
    // Every chip name is mapped in the Lucide bank, so the SVG pass draws
    // the whole row.
    for (chip_icons) |n| try t.expect(svg_icons.lucideName(n) != null);
}

test "fancy-weather-card: the chip icon rides low, so the row keeps air above it" {
    const t = std.testing;
    // The block starts with a 15 px icon box with the mark on its middle;
    // this card drops it three pixels further. Everything else in the block — the
    // 6 px to the label, the 3 px to the value — is untouched.
    try t.expectEqual(15.0, k_chip_icon_h);
    try t.expectEqual(10.5, chipIconY(0.0));
    try t.expectEqual(327.0, chipIconY(316.5));
    try t.expectEqual(k_chip_icon_h * 0.5 + k_chip_icon_dy, chipIconY(0.0));
}

test "fancy-weather-card: chip icons come from the glyph ladder, not the paths" {
    const t = std.testing;
    const w: i32 = 24;
    const h: i32 = 24;
    var lit_px: [24 * 24]u8 = undefined;
    var path_px: [24 * 24]u8 = undefined;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    for (0..chip_icons.len) |i| {
        // What the chip loop calls. False here would mean the SVG bank had
        // no raster for the name and the hand-built path took over — the
        // row this card used to draw.
        clearFrame(cr);
        try t.expect(chipIcon(cr, i, 12.0, 12.0, 15.0, .{}, 1.0));
        grabAlpha(surf, w, h, &lit_px);
        var inked: usize = 0;
        for (lit_px) |v| {
            if (v > 8) inked += 1;
        }
        try t.expect(inked > 0);

        // The path it replaced is a real mark too, just a *different* one —
        // which is what pins the card to the ladder: swapping the call back
        // makes these two stop differing.
        clearFrame(cr);
        chipGlyph(cr, i, 12.0, 12.0, 15.0, .{}, 1.0);
        grabAlpha(surf, w, h, &path_px);
        var diff: usize = 0;
        for (lit_px, path_px) |a, b| {
            if (a != b) diff += 1;
        }
        try t.expect(diff > 32);
    }
}

test "fancy-weather-card: the chip SVG lands inside its icon box, not as text" {
    const t = std.testing;
    // The vendored SVG paints a mark sized like an icon — "thermostat" as
    // literal text would run ~70 px wide at 15 px, and only a real icon
    // lands inside the 24 px box. So the proof the bank carries the name is
    // a narrow ink run from `chipIcon` itself.
    const w: i32 = 96;
    const h: i32 = 24;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    clearFrame(cr);
    try t.expect(chipIcon(cr, 0, 48.0, 12.0, 15.0, .{}, 1.0));
    const wide = inkWidth(surf, w, h);
    try t.expect(wide > 0 and wide <= 24);
}
