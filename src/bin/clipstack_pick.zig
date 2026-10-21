//! `horizon-clipstack-pick` — the Super+V clipboard picker.
//!
//! One layer-shell overlay (full-screen, transparent, click-outside
//! dismisses) with a centered history card. Keyboard-driven: type to
//! filter, Up/Down/PageUp/PageDown/Home/End to move, Enter to paste,
//! Ctrl+S to save, Delete to remove, Ctrl+Delete to wipe, Esc to close.
//! Clicking a row selects it; clicking the selected row pastes it.
//!
//! Enter pastes without a helper tool: the entry's bytes are published on
//! the picker's own data-control device, the process waits for the ClipStack
//! daemon to take the selection over (so the clipboard outlives this
//! window), destroys its surface so the previous window regains keyboard
//! focus, and injects Ctrl+V through `zwp_virtual_keyboard_v1`
//! (`wl/input/virtual_keyboard.zig`). `--no-paste` turns only the injection
//! off, `--select <id> [--paste]` does the same headlessly for scripts.
//!
//! Text renders through the shared pango layout, image rows decode a
//! thumbnail with the vendored stb_image — no clipboard tool, no picker
//! helper, no external process of any kind.

const std = @import("std");
const linux = std.os.linux;
const eh = @import("eh");
const wl = eh.wl_c.wl;
const clip = eh.clipboard;
const capture = eh.clipstack_capture;
const store_mod = eh.clipstack_store;
const pick_mod = eh.clipstack_picker;
const vk = eh.virtual_keyboard;
const cairo = eh.wl_shm.cairo;
const text_layout = eh.text_layout;
const logz = eh.logz;

const xkb = eh.wl_seat.xkb;

pub const usage =
    \\usage: horizon-clipstack-pick [--no-paste | --select <id> [--paste]]
    \\
    \\  (no arguments)        open the history picker; Enter pastes
    \\  --no-paste            open the picker; Enter only copies
    \\  --select <id>         publish entry <id> without opening a window
    \\  --paste               with --select: also inject Ctrl+V
    \\
;

const sym_escape: u32 = xkb.XKB_KEY_Escape;
const sym_return: u32 = xkb.XKB_KEY_Return;
const sym_kp_enter: u32 = xkb.XKB_KEY_KP_Enter;
const sym_up: u32 = xkb.XKB_KEY_Up;
const sym_down: u32 = xkb.XKB_KEY_Down;
const sym_page_up: u32 = xkb.XKB_KEY_Page_Up;
const sym_page_down: u32 = xkb.XKB_KEY_Page_Down;
const sym_home: u32 = xkb.XKB_KEY_Home;
const sym_end: u32 = xkb.XKB_KEY_End;
const sym_backspace: u32 = xkb.XKB_KEY_BackSpace;
const sym_delete: u32 = xkb.XKB_KEY_Delete;
const sym_s: u32 = xkb.XKB_KEY_s;

// Card metrics (logical pixels).
const card_max_w: f64 = 760.0;
const row_h: f64 = 52.0;
const header_h: f64 = 64.0;
const footer_h: f64 = 44.0;
const max_visible: usize = 9;
const thumb_px: f64 = 40.0;
const max_thumbs: usize = 32;

// Fixed dark palette. Theme integration (chrome colors from the wallpaper
// palette) is deliberately out of scope for the first cut; the card reads
// like the shell's other popups and the constants sit in one place.
const col_backdrop = [4]f64{ 0, 0, 0, 0.35 };
const col_card = [4]f64{ 0.086, 0.090, 0.106, 0.98 };
const col_border = [4]f64{ 1, 1, 1, 0.07 };
const col_text = [4]f64{ 0.90, 0.91, 0.93, 1 };
const col_dim = [4]f64{ 0.58, 0.60, 0.66, 1 };
const col_accent = [4]f64{ 0.48, 0.64, 0.97, 0.24 };
const col_hover = [4]f64{ 1, 1, 1, 0.06 };

fn wallMs() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

fn napMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

const Thumb = struct {
    id: u64,
    cover: eh.mpris_art.Cover,
};

const Layout = struct {
    card_x: f64,
    card_y: f64,
    card_w: f64,
    card_h: f64,
    list_y: f64,
    visible: usize,
    footer_y: f64,
};

fn layoutFor(w: i32, h: i32, rows: usize) Layout {
    const wf: f64 = @floatFromInt(@max(w, 320));
    const hf: f64 = @floatFromInt(@max(h, 240));
    const visible: usize = @max(1, @min(rows, max_visible));
    const cw = @min(card_max_w, wf - 80.0);
    const ch = header_h + @as(f64, @floatFromInt(visible)) * row_h + footer_h;
    const cx = (wf - cw) / 2.0;
    const cy = (hf - ch) / 2.0;
    return .{
        .card_x = cx,
        .card_y = cy,
        .card_w = cw,
        .card_h = ch,
        .list_y = cy + header_h,
        .visible = visible,
        .footer_y = cy + ch - footer_h + 12.0,
    };
}

const P = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
    conn: *eh.wl_conn.Connection,
    bound: *eh.wl_conn.Connection.Bound,
    display: *wl.wl_display,
    svc: *clip.Service,
    store: *store_mod.Store,
    model: pick_mod.Model = .{},
    labels: std.ArrayList([]u8) = .empty,
    thumbs: std.ArrayList(Thumb) = .empty,
    layer: eh.wl_layer.Surface = .{},
    shm: eh.wl_shm.ShmPair = undefined,
    scratch_surf: ?*cairo.cairo_surface_t = null,
    scratch_cr: ?*cairo.cairo_t = null,
    surface_w: i32 = 0,
    surface_h: i32 = 0,
    configured: bool = false,
    want_paint: bool = false,
    auto_paste: bool = true,
    hover: ?usize = null,
    done: bool = false,
    exit_code: u8 = 0,

    fn deinit(self: *P) void {
        for (self.labels.items) |l| self.gpa.free(l);
        self.labels.deinit(self.gpa);
        for (self.thumbs.items) |*t| t.cover.deinit(self.gpa);
        self.thumbs.deinit(self.gpa);
        self.model.deinit(self.gpa);
        self.shm.deinit();
        if (self.scratch_cr) |cr| cairo.cairo_destroy(cr);
        if (self.scratch_surf) |s| cairo.cairo_surface_destroy(s);
        self.layer.destroy();
    }
};

/// Rebuild rows from the store: fresh labels (trimmed to the card width),
/// fresh image thumbnails, then re-apply the filter.
fn rebuild(p: *P) void {
    for (p.labels.items) |l| p.gpa.free(l);
    p.labels.clearRetainingCapacity();
    for (p.thumbs.items) |*t| t.cover.deinit(p.gpa);
    p.thumbs.clearRetainingCapacity();

    if (p.scratch_surf == null) {
        p.scratch_surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1, 1);
        if (p.scratch_surf) |s| p.scratch_cr = cairo.cairo_create(s);
    }

    const metas_opt = p.store.list(p.gpa) catch null;
    defer if (metas_opt) |ms| store_mod.freeMetas(p.gpa, ms);

    var rows: std.ArrayList(pick_mod.Row) = .empty;
    defer rows.deinit(p.gpa);
    const now = wallMs();
    if (metas_opt) |metas| for (metas) |*m| {
        var label = pick_mod.labelFor(p.gpa, m, now - m.captured_ms) catch continue;
        if (p.scratch_cr) |cr| {
            var l = text_layout.Layout.createForCairo(cr);
            defer l.destroy();
            l.setFont("Inter 14");
            const trimmed = trimToWidth(&l, label, card_max_w - 150.0);
            if (trimmed.len < label.len) {
                const with_dots = std.fmt.allocPrint(p.gpa, "{s}…", .{trimmed}) catch null;
                if (with_dots) |wd| {
                    p.gpa.free(label);
                    label = wd;
                }
            }
        }
        p.labels.append(p.gpa, label) catch {
            p.gpa.free(label);
            continue;
        };
        rows.append(p.gpa, .{
            .id = m.id,
            .kind = m.kind,
            .captured_ms = m.captured_ms,
            .size = m.size,
            .label = label,
        }) catch continue;

        if (m.kind == .image and p.thumbs.items.len < max_thumbs) {
            if (loadThumb(p, m.id)) |cover| {
                p.thumbs.append(p.gpa, .{ .id = m.id, .cover = cover }) catch {
                    var cov = cover;
                    cov.deinit(p.gpa);
                };
            }
        }
    };
    p.model.setRows(p.gpa, rows.items) catch {};
}

fn loadThumb(p: *P, id: u64) ?eh.mpris_art.Cover {
    var entry = p.store.load(p.gpa, id) catch return null;
    defer entry.deinit(p.gpa);
    const png = entry.dataFor(capture.mime_png) orelse return null;
    return eh.mpris_art.decode(p.gpa, png);
}

fn thumbFor(p: *P, id: u64) ?*const eh.mpris_art.Cover {
    for (p.thumbs.items) |*t| {
        if (t.id == id) return &t.cover;
    }
    return null;
}

/// Longest prefix of `s` that fits `max_w` when laid out, on a UTF-8
/// boundary.
fn trimToWidth(l: *text_layout.Layout, s: []const u8, max_w: f64) []const u8 {
    l.setText(s);
    if (@as(f64, @floatFromInt(l.pixelSize().w)) <= max_w) return s;
    var end: usize = 0;
    while (end < s.len) {
        const step = std.unicode.utf8ByteSequenceLength(s[end]) catch 1;
        const next = @min(s.len, end + step);
        l.setText(s[0..next]);
        if (@as(f64, @floatFromInt(l.pixelSize().w)) > max_w) break;
        end = next;
    }
    return s[0..end];
}

/// One text run with its top at `y_top`, clipped to `max_w`.
fn drawText(
    cr: ?*cairo.cairo_t,
    font_px: i32,
    x: f64,
    y_top: f64,
    max_w: f64,
    rgba: [4]f64,
    text: []const u8,
) void {
    if (text.len == 0) return;
    var fbuf: [32]u8 = undefined;
    const font = std.fmt.bufPrint(&fbuf, "Inter {d}", .{font_px}) catch return;
    var l = text_layout.Layout.createForCairo(cr);
    defer l.destroy();
    l.setFont(font);
    const shown = trimToWidth(&l, text, max_w);
    if (shown.len == 0) return;
    l.setText(shown);
    const c = cr orelse return;
    cairo.cairo_set_source_rgba(c, rgba[0], rgba[1], rgba[2], rgba[3]);
    cairo.cairo_move_to(c, x, y_top);
    l.show(c);
}

/// Vertically centered variant for rows, pills and headers.
fn drawTextCentered(
    cr: ?*cairo.cairo_t,
    font_px: i32,
    x: f64,
    y_center: f64,
    max_w: f64,
    rgba: [4]f64,
    text: []const u8,
) void {
    if (text.len == 0) return;
    var fbuf: [32]u8 = undefined;
    const font = std.fmt.bufPrint(&fbuf, "Inter {d}", .{font_px}) catch return;
    var l = text_layout.Layout.createForCairo(cr);
    defer l.destroy();
    l.setFont(font);
    l.setText(text);
    const sz = l.pixelSize();
    const h: f64 = @floatFromInt(sz.h);
    drawText(cr, font_px, x, y_center - h / 2.0, max_w, rgba, text);
}

fn kindTag(kind: store_mod.Kind) []const u8 {
    return switch (kind) {
        .text => "TXT",
        .files => "FILE",
        .image => "IMG",
        .other => "MIME",
    };
}

fn kindColor(kind: store_mod.Kind) [4]f64 {
    return switch (kind) {
        .text => .{ 0.49, 0.83, 0.63, 1 },
        .files => .{ 0.48, 0.64, 0.97, 1 },
        .image => .{ 0.94, 0.71, 0.42, 1 },
        .other => .{ 0.63, 0.65, 0.70, 1 },
    };
}

fn paint(p: *P) void {
    if (!p.configured or p.layer.wl_surface == null) return;
    const w = p.surface_w;
    const h = p.surface_h;
    if (w <= 0 or h <= 0) return;
    // `w`/`h` stay logical (`draw` paints in them under cairo_scale); only the
    // buffer is allocated at device pixels.
    if (!p.shm.ensure(p.bound.shm, "clipstack", w * @max(1, p.layer.scale), h * @max(1, p.layer.scale))) {
        logz.log("clipstack-pick: shm alloc failed {d}x{d}", .{ w, h });
        return;
    }
    p.shm.setReleaseHook(onShmRelease, p);
    const buf = p.shm.acquire() orelse {
        p.want_paint = true;
        return;
    };
    p.want_paint = false;
    const cr = buf.cr orelse return;

    cairo.cairo_save(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
    cairo.cairo_paint(cr);
    // Scale the frame to the output's device pixels. `draw` below paints in
    // logical coordinates (surface_w/surface_h from the configure); cairo
    // rasterises at the buffer's native resolution so HiDPI stays crisp.
    cairo.cairo_identity_matrix(cr);
    const csc: f64 = @floatFromInt(@max(1, p.layer.scale));
    cairo.cairo_scale(cr, csc, csc);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
    draw(p, cr);
    cairo.cairo_restore(cr);

    const wlbuf = buf.wlBuffer() orelse return;
    p.layer.attach(wlbuf, 0, 0);
    p.layer.setBufferScale(p.layer.scale);
    p.layer.damage(0, 0, w, h);
    buf.markBusy();
    p.layer.commit();
    _ = p.conn.flush();
}

fn draw(p: *P, cr: ?*cairo.cairo_t) void {
    const c = cr orelse return;
    const wf: f64 = @floatFromInt(p.surface_w);
    const hf: f64 = @floatFromInt(p.surface_h);
    const lay = layoutFor(p.surface_w, p.surface_h, p.model.count());

    // Backdrop dim; outside the card a click dismisses.
    cairo.cairo_set_source_rgba(c, col_backdrop[0], col_backdrop[1], col_backdrop[2], col_backdrop[3]);
    cairo.cairo_rectangle(c, 0, 0, wf, hf);
    cairo.cairo_fill(c);

    // Card: shadow, fill, hairline.
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.45);
    eh.cairo_helpers.roundedRect(c, lay.card_x, lay.card_y + 10.0, lay.card_w, lay.card_h, 16.0);
    cairo.cairo_fill(c);
    cairo.cairo_set_source_rgba(c, col_card[0], col_card[1], col_card[2], col_card[3]);
    eh.cairo_helpers.roundedRect(c, lay.card_x, lay.card_y, lay.card_w, lay.card_h, 16.0);
    cairo.cairo_fill(c);
    cairo.cairo_set_source_rgba(c, col_border[0], col_border[1], col_border[2], col_border[3]);
    eh.cairo_helpers.roundedRect(c, lay.card_x + 0.5, lay.card_y + 0.5, lay.card_w - 1.0, lay.card_h - 1.0, 16.0);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    // Header: title, right side the live filter (or a hint).
    drawTextCentered(cr, 16, lay.card_x + 20.0, lay.card_y + header_h / 2.0, lay.card_w - 380.0, col_text, "Clipboard history");
    if (p.model.query.items.len > 0) {
        drawTextCentered(cr, 14, lay.card_x + lay.card_w - 20.0 - 300.0, lay.card_y + header_h / 2.0, 300.0, col_text, p.model.query.items);
    } else {
        drawTextCentered(cr, 14, lay.card_x + lay.card_w - 20.0 - 300.0, lay.card_y + header_h / 2.0, 300.0, col_dim, "type to filter");
    }

    // Rows.
    var i: usize = 0;
    while (i < lay.visible) : (i += 1) {
        const row = p.model.rowAtVisible(i) orelse break;
        const y = lay.list_y + @as(f64, @floatFromInt(i)) * row_h;
        const selected = (p.model.scroll + i) == p.model.selected;
        const hovered = p.hover != null and p.hover.? == i;
        const inset: f64 = 8.0;
        if (selected) {
            cairo.cairo_set_source_rgba(c, col_accent[0], col_accent[1], col_accent[2], col_accent[3]);
            eh.cairo_helpers.roundedRect(c, lay.card_x + inset, y + 2.0, lay.card_w - inset * 2.0, row_h - 4.0, 8.0);
            cairo.cairo_fill(c);
        } else if (hovered) {
            cairo.cairo_set_source_rgba(c, col_hover[0], col_hover[1], col_hover[2], col_hover[3]);
            eh.cairo_helpers.roundedRect(c, lay.card_x + inset, y + 2.0, lay.card_w - inset * 2.0, row_h - 4.0, 8.0);
            cairo.cairo_fill(c);
        }

        const tx = lay.card_x + inset + 10.0;
        const ty = y + (row_h - thumb_px) / 2.0;
        if (thumbFor(p, row.id)) |cover| {
            paintThumb(cr, cover, tx, ty, thumb_px);
        } else {
            // Tag pill.
            const tag = kindTag(row.kind);
            const kc = kindColor(row.kind);
            cairo.cairo_set_source_rgba(c, kc[0], kc[1], kc[2], 0.18);
            eh.cairo_helpers.roundedRect(c, tx, y + row_h / 2.0 - 11.0, 40.0, 22.0, 11.0);
            cairo.cairo_fill(c);
            cairo.cairo_set_source_rgba(c, kc[0], kc[1], kc[2], 1.0);
            drawTextCentered(cr, 11, tx + 6.0, y + row_h / 2.0, 34.0, kc, tag);
        }

        const text_x = tx + thumb_px + 12.0;
        const text_w = lay.card_x + lay.card_w - 16.0 - text_x;
        cairo.cairo_save(c);
        cairo.cairo_rectangle(c, lay.card_x + inset, y, lay.card_w - inset * 2.0, row_h);
        cairo.cairo_clip(c);
        drawTextCentered(cr, 14, text_x, y + row_h / 2.0, text_w, if (selected) col_text else col_dim, row.label);
        cairo.cairo_restore(c);
    }

    if (p.model.count() == 0) {
        drawTextCentered(cr, 14, lay.card_x + 20.0, lay.list_y + row_h / 2.0, lay.card_w - 40.0, col_dim, "No clipboard history yet");
    }

    // Footer: key hints left, count right.
    const hint = if (p.auto_paste)
        "Enter paste · Ctrl+S save · Del remove · Ctrl+Del wipe · Esc close"
    else
        "Enter copy · Ctrl+S save · Del remove · Ctrl+Del wipe · Esc close";
    const footer_center = lay.card_y + lay.card_h - footer_h / 2.0;
    drawTextCentered(cr, 12, lay.card_x + 20.0, footer_center, lay.card_w - 160.0, col_dim, hint);
    var cbuf: [32]u8 = undefined;
    const count_text = std.fmt.bufPrint(&cbuf, "{d} of {d}", .{ p.model.count(), p.model.rows.items.len }) catch "";
    drawTextCentered(cr, 12, lay.card_x + lay.card_w - 110.0, footer_center, 90.0, col_dim, count_text);
}

fn paintThumb(cr: ?*cairo.cairo_t, cover: *const eh.mpris_art.Cover, x: f64, y: f64, box: f64) void {
    const c = cr orelse return;
    if (!cover.present()) return;
    const cw: f64 = @floatFromInt(cover.w);
    const ch: f64 = @floatFromInt(cover.h);
    const scale = @max(box / cw, box / ch);
    const dw = cw * scale;
    const dh = ch * scale;
    const surf = cairo.cairo_image_surface_create_for_data(cover.pixels.ptr, cairo.CAIRO_FORMAT_ARGB32, cover.w, cover.h, cover.w * 4);
    defer cairo.cairo_surface_destroy(surf);
    cairo.cairo_save(c);
    eh.cairo_helpers.roundedRect(c, x, y, box, box, 8.0);
    cairo.cairo_clip(c);
    cairo.cairo_translate(c, x + (box - dw) / 2.0, y + (box - dh) / 2.0);
    cairo.cairo_scale(c, scale, scale);
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
}

fn onShmRelease(ctx: *anyopaque) void {
    const p: *P = @ptrCast(@alignCast(ctx));
    if (p.want_paint) paint(p);
}

fn onConfigure(ctx: *anyopaque, w: u32, h: u32) void {
    const p: *P = @ptrCast(@alignCast(ctx));
    p.surface_w = @intCast(w);
    p.surface_h = @intCast(h);
    p.configured = true;
    p.hover = null;
    paint(p);
}

fn onClosed(ctx: *anyopaque) void {
    const p: *P = @ptrCast(@alignCast(ctx));
    p.done = true;
}

fn ctrlHeld(p: *P) bool {
    const seat = p.bound.seat_obj orelse return false;
    const st = seat.xkb_state orelse return false;
    return xkb.xkb_state_mod_name_is_active(st, xkb.XKB_MOD_NAME_CTRL, xkb.XKB_STATE_MODS_EFFECTIVE) == 1;
}

fn selectedId(p: *P) ?u64 {
    const row = p.model.selectedRow() orelse return null;
    return row.id;
}

fn saveSelected(p: *P) void {
    const id = selectedId(p) orelse return;
    const home = p.home orelse {
        logz.err("clipstack-pick: HOME unset; cannot save", .{});
        return;
    };
    var entry = p.store.load(p.gpa, id) catch |e| {
        logz.err("clipstack-pick: save: load {d} failed: {s}", .{ id, @errorName(e) });
        return;
    };
    defer entry.deinit(p.gpa);
    const dir = std.fs.path.join(p.gpa, &.{ home, "Pictures", "ClipStack" }) catch return;
    defer p.gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(p.io, dir) catch {};

    var nbuf: [64]u8 = undefined;
    var pbuf: [512]u8 = undefined;
    if (entry.dataFor(capture.mime_png)) |png| {
        const name = std.fmt.bufPrint(&nbuf, "clip-{d}.png", .{id}) catch return;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, name }) catch return;
        if (writeWhole(p, path, png)) logz.log("clipstack-pick: saved {s} ({d} bytes)", .{ path, png.len });
    } else {
        const payload = entry.largest() orelse return;
        const name = std.fmt.bufPrint(&nbuf, "clip-{d}.txt", .{id}) catch return;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, name }) catch return;
        if (writeWhole(p, path, payload.data)) logz.log("clipstack-pick: saved {s} ({d} bytes)", .{ path, payload.data.len });
    }
}

fn writeWhole(p: *P, path: []const u8, bytes: []const u8) bool {
    const file = std.Io.Dir.cwd().createFile(p.io, path, .{}) catch |e| {
        logz.err("clipstack-pick: save: create {s}: {s}", .{ path, @errorName(e) });
        return false;
    };
    var wbuf: [64 * 1024]u8 = undefined;
    var wr = file.writer(p.io, &wbuf);
    wr.interface.writeAll(bytes) catch {
        file.close(p.io);
        return false;
    };
    wr.end() catch {
        file.close(p.io);
        return false;
    };
    file.close(p.io);
    return true;
}

fn requestPaint(p: *P) void {
    if (p.configured and !p.done) paint(p);
}

fn removeSelected(p: *P) void {
    const id = selectedId(p) orelse return;
    p.store.remove(id);
    rebuild(p);
    requestPaint(p);
}

fn wipeAll(p: *P) void {
    const n = p.store.wipe();
    logz.log("clipstack-pick: wiped {d} entries", .{n});
    rebuild(p);
    requestPaint(p);
}

/// Publish entry `id`, optionally inject Ctrl+V, then leave. Shared by the
/// UI's Enter/click path and the `--select` headless mode.
fn choose(p: *P, id: u64, do_paste: bool) void {
    var entry = p.store.load(p.gpa, id) catch |e| {
        logz.err("clipstack-pick: cannot load entry {d}: {s}", .{ id, @errorName(e) });
        p.exit_code = 1;
        p.done = true;
        return;
    };
    defer entry.deinit(p.gpa);

    var items: [store_mod.max_payloads]clip.Service.DataItem = undefined;
    const n = @min(entry.payloads.len, items.len);
    for (entry.payloads[0..n], 0..) |pl, i| {
        items[i] = .{ .mime = pl.mime, .data = pl.data };
    }
    if (!p.svc.copyDataMulti(items[0..n])) {
        logz.err("clipstack-pick: could not publish the selection", .{});
        p.exit_code = 1;
        p.done = true;
        return;
    }
    _ = p.conn.flush();

    // Wait for the ClipStack daemon to take the selection over — the
    // clipboard must still answer once this process is gone. A missing
    // daemon just burns the short timeout and the paste works as long as
    // the target application pastes before we exit.
    var tries: usize = 0;
    while (tries < 25 and p.svc.ownsSelection()) : (tries += 1) {
        _ = p.conn.roundtrip();
        napMs(10);
    }

    // Give the keyboard back before typing.
    if (p.layer.wl_surface != null) {
        p.layer.destroy();
        _ = p.conn.flush();
        _ = p.conn.roundtrip();
        _ = p.conn.roundtrip();
    }

    if (do_paste) {
        var kbd = vk.Keyboard.create(p.gpa, p.bound.virtual_keyboard_manager, p.bound.seat);
        defer kbd.destroy();
        if (kbd.ready()) {
            kbd.pressCtrlV();
            _ = p.conn.flush();
            _ = p.conn.roundtrip();
            napMs(180);
            logz.log("clipstack-pick: pasted id={d} ({d} payloads)", .{ id, n });
        } else {
            logz.log("clipstack-pick: no virtual keyboard; id={d} copied only", .{id});
        }
    } else {
        logz.log("clipstack-pick: copied id={d} ({d} payloads)", .{ id, n });
    }
    p.exit_code = 0;
    p.done = true;
}

fn onKey(ctx: *anyopaque, ev: *const eh.wl_seat.KeyEvent) void {
    const p: *P = @ptrCast(@alignCast(ctx));
    if (p.done or ev.state != 1) return;
    const ctrl = ctrlHeld(p);
    const sym = ev.sym;

    if (sym == sym_escape) {
        p.done = true;
        return;
    }
    if (sym == sym_return or sym == sym_kp_enter) {
        if (selectedId(p)) |id| choose(p, id, p.auto_paste);
        return;
    }
    if (sym == sym_up or sym == sym_down or sym == sym_page_up or sym == sym_page_down or
        sym == sym_home or sym == sym_end)
    {
        const page: isize = @intCast(@max(1, layoutFor(p.surface_w, p.surface_h, p.model.count()).visible));
        if (sym == sym_up) p.model.move(-1);
        if (sym == sym_down) p.model.move(1);
        if (sym == sym_page_up) p.model.move(-page);
        if (sym == sym_page_down) p.model.move(page);
        if (sym == sym_home) p.model.selected = 0;
        if (sym == sym_end and p.model.count() > 0) p.model.selected = p.model.count() - 1;
        p.model.clampScroll(@intCast(page));
        p.hover = null;
        requestPaint(p);
        return;
    }
    if (sym == sym_backspace) {
        p.model.backspace();
        p.model.refilter(p.gpa) catch {};
        requestPaint(p);
        return;
    }
    if (sym == sym_delete) {
        if (ctrl) {
            wipeAll(p);
        } else {
            removeSelected(p);
        }
        return;
    }
    if (ctrl) {
        if (sym == sym_s) saveSelected(p);
        return;
    }
    if (ev.utf8_len > 0) {
        p.model.typeBytes(p.gpa, ev.utf8[0..ev.utf8_len]) catch {};
        p.model.refilter(p.gpa) catch {};
        requestPaint(p);
    }
}

fn hoverRow(p: *P, x: f64, y: f64) ?usize {
    const lay = layoutFor(p.surface_w, p.surface_h, p.model.count());
    if (x < lay.card_x or x > lay.card_x + lay.card_w) return null;
    if (y < lay.list_y) return null;
    const rel = y - lay.list_y;
    const idx: usize = @intFromFloat(rel / row_h);
    if (idx >= lay.visible) return null;
    if (p.model.rowAtVisible(idx) == null) return null;
    return idx;
}

fn inCard(p: *P, x: f64, y: f64) bool {
    const lay = layoutFor(p.surface_w, p.surface_h, p.model.count());
    return x >= lay.card_x and x <= lay.card_x + lay.card_w and y >= lay.card_y and y <= lay.card_y + lay.card_h;
}

fn onMotion(ctx: *anyopaque, x: f64, y: f64) void {
    const p: *P = @ptrCast(@alignCast(ctx));
    const row = hoverRow(p, x, y);
    if (row != p.hover) {
        p.hover = row;
        requestPaint(p);
    }
}

fn onLeave(ctx: *anyopaque) void {
    const p: *P = @ptrCast(@alignCast(ctx));
    if (p.hover != null) {
        p.hover = null;
        requestPaint(p);
    }
}

fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
    const p: *P = @ptrCast(@alignCast(ctx));
    if (p.done or button != 1 or state != 1) return;
    const seat = p.bound.seat_obj orelse return;
    const x = seat.pointer_x;
    const y = seat.pointer_y;
    const row = hoverRow(p, x, y);
    if (row) |i| {
        const idx = p.model.scroll + i;
        if (idx == p.model.selected) {
            if (selectedId(p)) |id| choose(p, id, p.auto_paste);
            return;
        }
        p.model.selected = idx;
        requestPaint(p);
        return;
    }
    if (!inCard(p, x, y)) p.done = true;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    logz.init(io, init.environ_map.get("HOME"), "horizon-clipstack-pick-zig");
    defer logz.deinit();

    const args = init.minimal.args.toSlice(arena) catch &.{};
    var auto_paste = true;
    var select_id: ?u64 = null;
    var cli_paste = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_file = std.Io.File.stdout();
            var stdout = stdout_file.writer(io, &stdout_buf);
            try stdout.interface.print("{s}", .{usage});
            stdout.interface.flush() catch {};
            return 0;
        } else if (std.mem.eql(u8, a, "--no-paste")) {
            auto_paste = false;
        } else if (std.mem.eql(u8, a, "--paste")) {
            cli_paste = true;
        } else if (std.mem.eql(u8, a, "--select")) {
            if (i + 1 >= args.len) {
                logz.err("clipstack-pick: --select needs an id", .{});
                return 2;
            }
            select_id = std.fmt.parseInt(u64, args[i + 1], 10) catch {
                logz.err("clipstack-pick: bad id '{s}'", .{args[i + 1]});
                return 2;
            };
            i += 1;
        } else {
            logz.err("clipstack-pick: unknown argument '{s}'", .{a});
            logz.err("{s}", .{usage});
            return 2;
        }
    }

    const dir = store_mod.defaultDir(arena, init.environ_map.get("XDG_DATA_HOME"), init.environ_map.get("HOME")) orelse {
        logz.err("clipstack-pick: no store directory", .{});
        return 1;
    };
    var store = store_mod.Store.open(io, gpa, dir) catch |e| {
        logz.err("clipstack-pick: cannot open store {s}: {s}", .{ dir, @errorName(e) });
        return 1;
    };
    defer store.deinit();

    // -- one-instance toggle --------------------------------------------------
    // Two launchers drive this binary: the Super+V binding (`pkill ... ||`)
    // and the dock/taskbar widget (plain exec; `launchExec` has no shell).
    // Both mean "toggle the panel". The lockfile implements it: take the
    // `.pick.lock` in the store dir to open; if another picker holds it,
    // SIGTERM that holder and exit here — no surface ever flashes. Headless
    // `--select` runs never lock, so scripts queue freely. This is a
    // separate file from the daemon's `.lock`; pid reuse in the tiny window
    // between a holder's death and the next rewrite is accepted (and the
    // flock failure means the holder was alive a moment before).
    var pick_lock: ?std.Io.File = null;
    if (select_id == null) {
        const lock_file = store.dir.createFile(io, ".pick.lock", .{ .truncate = false }) catch {
            logz.err("clipstack-pick: cannot create .pick.lock in store dir", .{});
            return 1;
        };
        const lrc = std.os.linux.flock(lock_file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
        if (std.os.linux.errno(lrc) != .SUCCESS) {
            // Toggling closed: the current holder's pid sits in the file.
            lock_file.close(io);
            if (store.dir.readFileAlloc(io, ".pick.lock", arena, .limited(32))) |raw| {
                var end: usize = 0;
                while (end < raw.len and raw[end] >= '0' and raw[end] <= '9') : (end += 1) {}
                if (end > 0) {
                    const pid = std.fmt.parseInt(i32, raw[0..end], 10) catch 0;
                    if (pid > 1) {
                        std.posix.kill(pid, .TERM) catch {};
                        logz.log("clipstack-pick: toggled out running pid={d}", .{pid});
                    }
                }
            } else |_| {}
            return 0;
        }
        var lbuf: [16]u8 = undefined;
        const lpid = std.fmt.bufPrint(&lbuf, "{d}\n", .{std.os.linux.getpid()}) catch "\n";
        var lwr_buf: [64]u8 = undefined;
        var lwr = lock_file.writer(io, &lwr_buf);
        lwr.interface.writeAll(lpid) catch {};
        lwr.interface.flush() catch {};
        pick_lock = lock_file;
    }
    defer if (pick_lock) |lf| {
        lf.close(io);
        store.dir.deleteFile(io, ".pick.lock") catch {};
    };

    var conn = eh.wl_conn.Connection.init(gpa);
    defer conn.deinit();
    if (!conn.connect(null)) {
        logz.err("clipstack-pick: cannot connect to Wayland", .{});
        return 1;
    }
    var bound = eh.wl_conn.Connection.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    const display = conn.display orelse {
        logz.err("clipstack-pick: no display", .{});
        return 1;
    };
    const choice = eh.clipboard_daemon.chooseBackend(&bound) orelse {
        logz.err("clipstack-pick: no data-control protocol available", .{});
        return 1;
    };
    const seat = bound.seat orelse {
        logz.err("clipstack-pick: no wl_seat available", .{});
        return 1;
    };
    var svc = clip.Service.init(gpa);
    defer svc.deinit();
    if (!svc.bind(choice.manager, choice.backend, seat, display)) {
        logz.err("clipstack-pick: data-control bind failed", .{});
        return 1;
    }

    var p = P{
        .gpa = gpa,
        .io = io,
        .home = init.environ_map.get("HOME"),
        .conn = &conn,
        .bound = &bound,
        .display = display,
        .svc = &svc,
        .store = &store,
        .auto_paste = auto_paste,
    };
    p.shm = eh.wl_shm.ShmPair.init(gpa);
    defer p.deinit();

    if (select_id) |id| {
        choose(&p, id, cli_paste);
        return p.exit_code;
    }

    if (bound.compositor == null or bound.layer_shell == null) {
        logz.err("clipstack-pick: compositor does not offer layer-shell", .{});
        return 1;
    }
    if (!p.layer.create(bound.compositor, bound.layer_shell, null, .overlay, "clipstack")) {
        logz.err("clipstack-pick: layer surface create failed", .{});
        return 1;
    }
    p.layer.setAnchor(eh.wl_layer.Anchor.top | eh.wl_layer.Anchor.bottom | eh.wl_layer.Anchor.left | eh.wl_layer.Anchor.right);
    p.layer.setExclusiveZone(-1);
    p.layer.setSize(0, 0);
    p.layer.setKeyboardInteractivity(2);
    p.layer.on_configure = onConfigure;
    p.layer.on_closed = onClosed;
    p.layer.ctx = &p;

    rebuild(&p);

    if (bound.seat_obj) |seat_obj| {
        seat_obj.on_key = onKey;
        seat_obj.on_pointer_motion = onMotion;
        seat_obj.on_pointer_button = onButton;
        seat_obj.on_pointer_leave = onLeave;
        seat_obj.cb_ctx = &p;
    }

    p.layer.commit();
    _ = conn.flush();
    var ticks: u32 = 0;
    while (ticks < 100 and !p.layer.configured and !p.done) : (ticks += 1) {
        if (!conn.roundtrip()) break;
    }
    if (!p.layer.configured) {
        logz.err("clipstack-pick: surface never configured", .{});
        return 1;
    }
    logz.log("clipstack-pick: open entries={d} paste={d}", .{ p.model.rows.items.len, @intFromBool(p.auto_paste) });
    while (!p.done) {
        if (wl.wl_display_dispatch(display) < 0) break;
        if (p.want_paint) paint(&p);
    }
    logz.log("clipstack-pick: exit code={d}", .{p.exit_code});
    return p.exit_code;
}
