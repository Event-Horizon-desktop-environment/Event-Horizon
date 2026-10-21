//! Port of the C++ polkit auth dialog's paint (polkit_auth_dialog.cpp) onto
//! the Zig shell's widget stack: a compact fixed-width modal card whose height
//! is sized to content every frame, coloured by the wallpaper-driven chrome
//! palette, with m3 buttons and Lucide glyphs.
//!
//! There is no scrim: the compositor blurs behind the layer surface, so a
//! fullscreen surface smears the whole desktop. The binary sizes the surface
//! to `card + 2 * k_surf_pad` from the `Geo` this module returns.
//!
//! Rows with no content are measured as zero height and cost no space, so the
//! same function draws the initial "Authentication Required" card, prompt
//! variants and the note row without any layout branches in the caller.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const text = @import("../../text/layout.zig");
const chrome = @import("shared/chrome_colors.zig");
const helpers = @import("../shared/cairo_helpers.zig");
const m3_box = @import("../../m3/core/primitives/box.zig");
const m3_button = @import("../../m3/controls/containers/button.zig");
const glyph = @import("../common/material_glyph.zig");

/// Fixed card width (logical px); height follows content.
pub const k_card_w: f64 = 480.0;
/// Margin between the card and the layer surface edge.
pub const k_surf_pad: f64 = 8.0;
/// Icon box (logical px) for polkit's themed icon, and the raster size asked
/// of the theme lookup (covers 2x/3x output scales).
pub const k_icon_box: f64 = 22.0;
pub const k_icon_raster: u32 = 96;

/// Masked-field bullet cap, in characters.
const k_field_chars: usize = 120;

/// Interactive targets, in the C++ dialog's numbering.
pub const Hit = enum(u8) { none = 0, cancel = 1, auth = 2, close = 3 };

/// Everything the card renders for one frame.
pub const View = struct {
    /// Identity row ("" hides it); identity_subtitle is applied by the caller.
    identity: []const u8 = "",
    action_id: []const u8 = "",
    message: []const u8 = "",
    details: []const u8 = "",
    /// note precedence (error > info > failed) is resolved by the caller.
    note: []const u8 = "",
    note_is_error: bool = false,
    prompt_label: []const u8 = "Password:",
    field: []const u8 = "",
    echo_on: bool = false,
    /// Confirm is armed only when a live prompt can take the answer.
    can_submit: bool = false,
    hover: Hit = .none,
    press: Hit = .none,
};

/// Hit geometry for one frame, in logical surface pixels.
pub const Geo = struct {
    card_w: f64 = k_card_w,
    card_h: f64 = 0,
    close: [4]f64 = .{ 0, 0, 0, 0 },
    cancel: [4]f64 = .{ 0, 0, 0, 0 },
    auth: [4]f64 = .{ 0, 0, 0, 0 },
    field: [4]f64 = .{ 0, 0, 0, 0 },

    pub fn hitTest(self: *const Geo, x: f64, y: f64) Hit {
        if (inRect(x, y, self.close)) return .close;
        if (inRect(x, y, self.cancel)) return .cancel;
        if (inRect(x, y, self.auth)) return .auth;
        return .none;
    }
};

/// The action's themed icon, rasterized by the caller (null surface ⇒ lock
/// glyph fallback).
pub const Icon = struct {
    surface: ?*cairo.cairo_surface_t = null,
    w: i32 = 0,
    h: i32 = 0,
};

fn inRect(x: f64, y: f64, r: [4]f64) bool {
    return x >= r[0] and x < r[0] + r[2] and y >= r[1] and y < r[1] + r[3];
}

// -- pango row helpers (the C++ make_row_layout / draw_row pair) ------------

fn makeRow(cr: ?*cairo.cairo_t, s: []const u8, size: f64, weight: c_uint, max_w: f64, ellipsize: bool, max_lines: u32) text.Layout {
    var l = text.Layout.createForCairo(cr);
    var buf: [48]u8 = undefined;
    const desc: []const u8 = std.fmt.bufPrint(&buf, "Inter {d:.1}", .{size}) catch "Inter 12.0";
    l.setFont(desc);
    l.setWeight(weight);
    l.setText(s);
    if (max_w > 0) {
        l.setWidthUnits(@intFromFloat(max_w * text.PANGO_SCALE));
        l.setSingleParagraph(true);
    }
    if (ellipsize) l.setEllipsize(text.ELLIPSIZE_END);
    if (max_lines > 0) l.setMaxLines(max_lines);
    return l;
}

fn rowHeight(cr: ?*cairo.cairo_t, s: []const u8, size: f64, weight: c_uint, max_w: f64, ellipsize: bool, max_lines: u32) f64 {
    if (s.len == 0) return 0;
    var l = makeRow(cr, s, size, weight, max_w, ellipsize, max_lines);
    defer l.destroy();
    return @floatFromInt(l.pixelSize().h);
}

fn drawRow(cr: ?*cairo.cairo_t, s: []const u8, size: f64, weight: c_uint, max_w: f64, ellipsize: bool, max_lines: u32, color: [4]f64, x: f64, y_top: f64) void {
    if (s.len == 0) return;
    const c = cr orelse return;
    var l = makeRow(c, s, size, weight, max_w, ellipsize, max_lines);
    defer l.destroy();
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x, y_top);
    cairo.cairo_set_source_rgba(c, color[0], color[1], color[2], color[3]);
    l.show(c);
    cairo.cairo_restore(c);
}

fn rowPixelWidth(cr: ?*cairo.cairo_t, s: []const u8, size: f64, weight: c_uint, max_w: f64) f64 {
    if (s.len == 0) return 0;
    var l = makeRow(cr, s, size, weight, max_w, true, 0);
    defer l.destroy();
    return @floatFromInt(l.pixelSize().w);
}

fn colorOf(rgb: chrome.Rgb, a: f64) [4]f64 {
    return .{ rgb.r, rgb.g, rgb.b, a };
}

/// Mask hidden input: one bullet per UTF-8 character, capped.
fn maskedInto(buf: []u8, field: []const u8) []const u8 {
    var n: usize = 0;
    for (field) |ch| {
        if ((ch & 0xC0) != 0x80) n += 1;
    }
    if (n > k_field_chars) n = k_field_chars;
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(buf[i * 3 ..][0..3], "\u{2022}");
    return buf[0 .. n * 3];
}

/// Draw the card centred in a `w`x`h` logical surface and return the hit
/// geometry. `alloc` is per-frame scratch (the meta row needs a join).
pub fn paint(alloc: std.mem.Allocator, cr: ?*cairo.cairo_t, w: f64, h: f64, view: View, ch: chrome.Chrome, icon: Icon) Geo {
    var geo = Geo{};
    const c = cr orelse return geo;
    if (w <= 0 or h <= 0) return geo;

    const card_w = k_card_w;
    const pad: f64 = 16.0;
    const content_w = card_w - 2.0 * pad;

    const t_col = colorOf(ch.text, 1.0);
    const a_col = colorOf(ch.accent, 1.0);
    const e_col = colorOf(ch.notif_ol, 1.0);

    // No scrim: clear so only the card paints.
    cairo.cairo_set_operator(c, cairo.CAIRO_OPERATOR_CLEAR);
    cairo.cairo_paint(c);
    cairo.cairo_set_operator(c, cairo.CAIRO_OPERATOR_OVER);

    // Meta: identity, then the action id.
    var meta_owned: ?[]u8 = null;
    defer if (meta_owned) |m| alloc.free(m);
    var meta: []const u8 = view.identity;
    if (view.action_id.len > 0) {
        if (meta.len > 0) {
            meta_owned = std.fmt.allocPrint(alloc, "{s}  ·  {s}", .{ view.identity, view.action_id }) catch null;
            if (meta_owned) |m| meta = m;
        } else {
            meta = view.action_id;
        }
    }

    const message = view.message;
    const details = view.details;
    const note = view.note;
    const note_is_error = view.note_is_error;
    const prompt_label = if (view.prompt_label.len == 0) "Password:" else view.prompt_label;

    const title_max_w = content_w - 32.0 - 28.0;
    const title_h = rowHeight(c, "Authentication Required", 15.0, 600, title_max_w, true, 0);
    const header_h: f64 = 26.0;
    const meta_h = rowHeight(c, meta, 11.5, 500, content_w, true, 0);
    const msg_h = rowHeight(c, message, 12.5, 400, content_w, true, 3);
    const det_h = rowHeight(c, details, 11.0, 400, content_w, true, 2);
    const note_h = rowHeight(c, note, 11.5, if (note_is_error) 700 else 400, content_w, true, 0);
    const field_h: f64 = 34.0;
    const btn_h: f64 = 34.0;

    var card_h = pad + header_h + 12.0;
    if (meta_h > 0) card_h += meta_h + 6.0;
    if (msg_h > 0) card_h += msg_h + 6.0;
    if (det_h > 0) card_h += det_h + 6.0;
    if (note_h > 0) card_h += note_h + 6.0;
    card_h += 10.0 + field_h + 12.0 + btn_h + pad;
    geo.card_h = card_h;

    const cx = (w - card_w) * 0.5;
    const cy = (h - card_h) * 0.5;

    // Card: wallpaper-surface fill + the shared m3 glass treatment (sheen,
    // rim light, drop shadow all come from the Box).
    {
        var box = m3_box.Box{};
        box.setColor(@floatCast(ch.panel_fill.r), @floatCast(ch.panel_fill.g), @floatCast(ch.panel_fill.b), 0.96);
        box.setRadius(14.0);
        box.setGeometry(@floatCast(cx), @floatCast(cy), @floatCast(card_w), @floatCast(card_h));
        box.setGlassy(true);
        box.paint(c);
    }

    // Header: the action's themed icon (lock fallback) + title + close.
    {
        const icon_cx = cx + pad + 11.0;
        const icon_cy = cy + pad + 13.0;
        var drew_icon = false;
        if (icon.surface) |surf| {
            if (icon.w > 0 and icon.h > 0) {
                const iw: f64 = @floatFromInt(icon.w);
                const ih: f64 = @floatFromInt(icon.h);
                const sc = @min(k_icon_box / iw, k_icon_box / ih);
                const dw = iw * sc;
                const dh = ih * sc;
                cairo.cairo_save(c);
                cairo.cairo_translate(c, icon_cx - dw * 0.5, icon_cy - dh * 0.5);
                cairo.cairo_scale(c, dw / iw, dh / ih);
                cairo.cairo_set_source_surface(c, surf, 0, 0);
                cairo.cairo_paint(c);
                cairo.cairo_restore(c);
                drew_icon = true;
            }
        }
        if (!drew_icon) {
            _ = glyph.draw(c, "lock", icon_cx, icon_cy, 20.0, a_col[0], a_col[1], a_col[2], 0.95);
        }
    }

    drawRow(c, "Authentication Required", 15.0, 600, title_max_w, true, 0, colorOf(ch.text, 0.97), cx + pad + 32.0, cy + pad + (header_h - title_h) * 0.5);

    const close_sz: f64 = 24.0;
    geo.close = .{ cx + card_w - pad - close_sz, cy + pad + 1.0, close_sz, close_sz };
    helpers.pathRoundedRect(c, geo.close[0], geo.close[1], geo.close[2], geo.close[3], 7.0);
    cairo.cairo_set_source_rgba(c, ch.drawer_dim.r, ch.drawer_dim.g, ch.drawer_dim.b, 0.45);
    cairo.cairo_fill(c);
    if (view.press == .close) {
        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.3);
        helpers.pathRoundedRect(c, geo.close[0], geo.close[1], geo.close[2], geo.close[3], 7.0);
        cairo.cairo_fill(c);
    } else if (view.hover == .close) {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.15);
        helpers.pathRoundedRect(c, geo.close[0], geo.close[1], geo.close[2], geo.close[3], 7.0);
        cairo.cairo_fill(c);
    }
    _ = glyph.draw(c, "close", geo.close[0] + close_sz * 0.5, geo.close[1] + close_sz * 0.5, 16.0, t_col[0], t_col[1], t_col[2], 0.88);

    // Content rows, top to bottom. Empty rows were measured as zero height and
    // cost nothing.
    var row_y = cy + pad + header_h + 12.0;
    if (meta_h > 0) {
        drawRow(c, meta, 11.5, 500, content_w, true, 0, colorOf(ch.accent, 0.92), cx + pad, row_y);
        row_y += meta_h + 6.0;
    }
    if (msg_h > 0) {
        drawRow(c, message, 12.5, 400, content_w, true, 3, colorOf(ch.text, 0.80), cx + pad, row_y);
        row_y += msg_h + 6.0;
    }
    if (det_h > 0) {
        drawRow(c, details, 11.0, 400, content_w, true, 2, colorOf(ch.text, 0.45), cx + pad, row_y);
        row_y += det_h + 6.0;
    }
    if (note_h > 0) {
        const col = if (note_is_error) e_col else colorOf(ch.text, 0.60);
        drawRow(c, note, 11.5, if (note_is_error) 700 else 400, content_w, true, 0, col, cx + pad, row_y);
        row_y += note_h + 6.0;
    }
    row_y += 10.0;

    // Password field. GNOME Shell shows the prompt as placeholder hint text;
    // bullets mask hidden input, the caret sits at the end.
    const field_x = cx + pad;
    const field_y = row_y;
    const field_w = content_w;
    geo.field = .{ field_x, field_y, field_w, field_h };
    helpers.pathRoundedRect(c, field_x, field_y, field_w, field_h, 10.0);
    cairo.cairo_set_source_rgba(c, ch.dock_fill.r * 0.4, ch.dock_fill.g * 0.4, ch.dock_fill.b * 0.4, 0.75);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, a_col[0], a_col[1], a_col[2], 0.8);
    cairo.cairo_set_line_width(c, 1.4);
    cairo.cairo_stroke(c);

    var mask_buf: [k_field_chars * 3]u8 = undefined;
    var echo_buf: [k_field_chars]u8 = undefined;
    var shown: []const u8 = "";
    if (!view.echo_on) {
        shown = maskedInto(&mask_buf, view.field);
    } else {
        shown = view.field;
        if (shown.len > k_field_chars) {
            @memcpy(echo_buf[0 .. k_field_chars - 3], shown[0 .. k_field_chars - 3]);
            @memcpy(echo_buf[k_field_chars - 3 ..][0..3], "...");
            shown = echo_buf[0..k_field_chars];
        }
    }
    const text_max_w = field_w - 20.0;
    const field_text = if (shown.len == 0) prompt_label else shown;
    const field_text_h = rowHeight(c, field_text, 13.0, 400, text_max_w, true, 0);
    const field_text_y = field_y + (field_h - field_text_h) * 0.5;
    if (shown.len == 0) {
        drawRow(c, prompt_label, 13.0, 400, text_max_w, true, 0, colorOf(ch.text, 0.40), field_x + 10.0, field_text_y);
    } else {
        drawRow(c, shown, 13.0, 400, text_max_w, true, 0, colorOf(ch.text, 0.95), field_x + 10.0, field_text_y);
    }
    {
        const text_w = if (shown.len == 0) 0.0 else @min(rowPixelWidth(c, shown, 13.0, 400, text_max_w), text_max_w);
        cairo.cairo_set_source_rgba(c, a_col[0], a_col[1], a_col[2], 0.9);
        cairo.cairo_rectangle(c, field_x + 10.0 + text_w + 1.5, field_y + (field_h - 15.0) * 0.5, 1.5, 15.0);
        cairo.cairo_fill(c);
    }

    // Buttons: DE-standard m3 pair, right-aligned. Confirm is armed only when
    // a live prompt can take the answer (matches the empty-submit guards).
    const btn_y = field_y + field_h + 12.0;
    const btn_gap: f64 = 8.0;
    const btn_right = cx + card_w - pad;

    var btn_cancel = m3_button.Button{};
    btn_cancel.setMinSize(0, 0);
    btn_cancel.setLabel("Cancel");
    btn_cancel.setStyle(.outlined);
    btn_cancel.setSize(.s);
    btn_cancel.setAccentColor(@floatCast(ch.accent.r), @floatCast(ch.accent.g), @floatCast(ch.accent.b));
    btn_cancel.setSurfaceColor(@floatCast(ch.panel_fill.r), @floatCast(ch.panel_fill.g), @floatCast(ch.panel_fill.b));
    btn_cancel.setGeometry(0, 0, 0, @floatCast(btn_h));
    const cancel_w: f64 = btn_cancel.width();

    var btn_auth = m3_button.Button{};
    btn_auth.setMinSize(0, 0);
    btn_auth.setLabel("Confirm");
    btn_auth.setStyle(.filled);
    btn_auth.setSize(.s);
    btn_auth.setAccentColor(@floatCast(ch.accent.r), @floatCast(ch.accent.g), @floatCast(ch.accent.b));
    btn_auth.setGeometry(0, 0, 0, @floatCast(btn_h));
    const auth_w: f64 = btn_auth.width();

    geo.auth = .{ btn_right - auth_w, btn_y, auth_w, btn_h };
    geo.cancel = .{ geo.auth[0] - btn_gap - cancel_w, btn_y, cancel_w, btn_h };

    btn_cancel.setGeometry(@floatCast(geo.cancel[0]), @floatCast(geo.cancel[1]), @floatCast(geo.cancel[2]), @floatCast(geo.cancel[3]));
    btn_cancel.setHovered(view.hover == .cancel);
    btn_cancel.setPressed(view.press == .cancel);
    btn_auth.setGeometry(@floatCast(geo.auth[0]), @floatCast(geo.auth[1]), @floatCast(geo.auth[2]), @floatCast(geo.auth[3]));
    btn_auth.setEnabled(view.can_submit);
    btn_auth.setHovered(view.can_submit and view.hover == .auth);
    btn_auth.setPressed(view.can_submit and view.press == .auth);
    btn_cancel.paintStatic(c);
    btn_auth.paintStatic(c);

    return geo;
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

test "paint: card height grows with content and buttons stay right-aligned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 496, 400);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    const ch = chrome.Chrome{};
    const bare = paint(arena.allocator(), cr, 496, 400, .{}, ch, .{});
    // 16 + 26 + 12 + 10 + 34 + 12 + 34 + 16
    try testing.expectApproxEqAbs(@as(f64, 160.0), bare.card_h, 0.01);
    // Buttons right-aligned against the card edge.
    const right = 496 - k_surf_pad - 16.0;
    try testing.expectApproxEqAbs(right, bare.auth[0] + bare.auth[2], 0.01);
    try testing.expectApproxEqAbs(8.0, bare.auth[0] - (bare.cancel[0] + bare.cancel[2]), 0.01);

    const full = paint(arena.allocator(), cr, 496, 400, .{
        .identity = "matt@host",
        .action_id = "org.freedesktop.udisks2.filesystem-mount",
        .message = "Authentication is required to mount the drive.",
        .details = "polkit.caller-pid=4242",
        .note = "Authentication failed — try again",
        .note_is_error = true,
        .prompt_label = "Password:",
        .field = "hunter2",
        .can_submit = true,
        .hover = .auth,
    }, ch, .{});
    // Every populated row adds real height.
    try testing.expect(full.card_h > bare.card_h + 60.0);
    // The field is a full-width row above the buttons.
    try testing.expectApproxEqAbs(bare.field[2], full.field[2], 0.01);
    try testing.expect(full.field[1] > bare.field[1] + 50.0);
    try testing.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}

test "paint: hit geometry and hitTest agree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 496, 300);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    const geo = paint(arena.allocator(), cr, 496, 300, .{ .can_submit = true }, chrome.Chrome{}, .{});
    const cx = (496.0 - k_card_w) * 0.5;
    const cy = (300.0 - geo.card_h) * 0.5;

    // Dead space inside the card: no target.
    try testing.expectEqual(Hit.none, geo.hitTest(cx + 10.0, cy + 5.0));

    const close_mid = .{ geo.close[0] + 12.0, geo.close[1] + 12.0 };
    try testing.expectEqual(Hit.close, geo.hitTest(close_mid[0], close_mid[1]));

    const auth_mid = .{ geo.auth[0] + geo.auth[2] * 0.5, geo.auth[1] + geo.auth[3] * 0.5 };
    try testing.expectEqual(Hit.auth, geo.hitTest(auth_mid[0], auth_mid[1]));
    const cancel_mid = .{ geo.cancel[0] + geo.cancel[2] * 0.5, geo.cancel[1] + geo.cancel[3] * 0.5 };
    try testing.expectEqual(Hit.cancel, geo.hitTest(cancel_mid[0], cancel_mid[1]));

    try testing.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}

test "paint: masked bullets and echo truncation" {
    var buf: [k_field_chars * 3]u8 = undefined;
    try testing.expectEqualStrings("•••", maskedInto(&buf, "abc"));
    // Multi-byte characters count once.
    try testing.expectEqualStrings("••", maskedInto(&buf, "é✓"));
    // Cap enforced.
    const long = "x" ** 200;
    try testing.expectEqual(k_field_chars * 3, maskedInto(&buf, long).len);
}
