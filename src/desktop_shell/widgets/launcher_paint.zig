//! The launcher panel's paint: the card, the search field, the category
//! pills, the scrollable body and the power strip along the bottom.
//!
//! The body is expensive enough — a few dozen pango layouts and icon blits —
//! that it is rendered once into its own image surface and blitted back at an
//! offset on every frame. That surface is rebuilt only when the model says it
//! changed, so scrolling and caret blinking cost one blit.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const text = @import("../../text/layout.zig");
const helpers = @import("../shared/cairo_helpers.zig");
const layout = @import("launcher_layout.zig");
const chrome = @import("shared/chrome_colors.zig");
const cat = @import("../../services/app_catalog.zig");
const icon_cache = @import("../common/icon_cache.zig");
const icon_disk = @import("../common/icon_disk.zig");
const icon_lookup = @import("../common/icon_lookup.zig");
const icon_raster = @import("../common/icon_raster.zig");
const svg_icons = @import("../../ux/shared/svg_icons.zig");

const k_placeholder = "Search for an app\u{2026}";
const k_hint = "Esc to close";
const k_empty_all = "No applications";
const k_empty_filter = "No matching applications";

const power_titles = [layout.power_count][]const u8{
    "",
    "End this session?",
    "Restart this computer?",
    "Shut down this computer?",
    // The nightlight toggle never opens the card; the slot is here so the
    // table stays indexed by the footer's button order.
    "",
};
const power_body = "Unsaved work will be lost.";
const btn_cancel = "Cancel";
const btn_go = "Continue";

// Text

pub fn makeLayout(cr: ?*cairo.cairo_t, desc: []const u8) text.Layout {
    var l = text.Layout.createForCairo(cr);
    l.setFont(desc);
    return l;
}

pub fn fontDesc(buf: []u8, weight: []const u8, px: f64) []const u8 {
    const size: i32 = @intFromFloat(@trunc(px));
    if (weight.len == 0) return std.fmt.bufPrint(buf, "Inter {d}", .{size}) catch "Inter 13";
    return std.fmt.bufPrint(buf, "Inter {s} {d}", .{ weight, size }) catch "Inter 13";
}

/// Top edge that puts a run of text on `mid`. Pango draws from the top-left
/// of the layout, so every centred run in this file goes through here.
pub fn midTop(l: *text.Layout, mid: f64) f64 {
    const sz = l.pixelSize();
    return mid - @as(f64, @floatFromInt(sz.h)) * 0.5;
}

pub fn drawRun(c: ?*cairo.cairo_t, l: *text.Layout, x: f64, top: f64, a: f64) void {
    const cr = c orelse return;
    cairo.cairo_move_to(cr, x, top);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, a);
    l.show(cr);
}

/// Width the run currently set on `l` measures to, in pixels.
pub fn runWidth(l: *text.Layout) f64 {
    const sz = l.pixelSize();
    return @floatFromInt(sz.w);
}

pub fn firstRune(s: []const u8) []const u8 {
    if (s.len == 0) return "";
    var i: usize = 1;
    while (i < s.len and (s[i] & 0xC0) == 0x80) i += 1;
    return s[0..i];
}

/// Drops whole runes from the end of `s` until it measures no wider than
/// `max_w`. Only ever runs on a search box, so the query is short.
pub fn shrinkTo(l: *text.Layout, s: []const u8, max_w: f64) []const u8 {
    var end = s.len;
    while (end > 0) {
        l.setText(s[0..end]);
        if (runWidth(l) <= max_w) return s[0..end];
        end -= 1;
        while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    }
    l.setText("");
    return "";
}

// Paint resources

pub const Pixels = struct {
    data: []u8 = &.{},
    w: i32 = 0,
    h: i32 = 0,
    /// Cairo surface over `data`, built once on first use so paints never
    /// pay create/destroy per cell per frame.
    surf: ?*cairo.cairo_surface_t = null,
};

const icon_px: i32 = 64;
const icon_cache_ceiling: usize = 512;

/// Milliseconds on the monotonic clock. Only ever samples the prefetch
/// budget — the paint path does not read a clock at all.
fn nowMs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 + @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

/// Rasterized application icons, keyed by icon name. One size suits both the
/// grid and the list because both draw scaled.
///
/// Paints only ever read this cache: a name it cannot answer paints the
/// letter tile and raises `pending`, and the host's tick prefetcher resolves
/// it — through the shared icon index, then a per-user disk cache, and only
/// then a raster — off the keystroke path. That split is what keeps a search
/// for apps whose icons have never been decoded in this process cheap on the
/// first frame.
pub const Icons = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dirs: [][]const u8 = undefined,
    path_set: bool = false,
    theme: []const u8 = "hicolor",
    map: std.StringHashMapUnmanaged(Pixels) = .{},
    disk: icon_disk.Disk = undefined,
    disk_init: bool = false,
    /// A paint asked for a name the cache cannot answer. The prefetcher
    /// keeps working while this is set and clears it once every name the
    /// hits need is resolved (or remembered as having no icon).
    pending: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Icons {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Icons) void {
        self.clear();
        self.map.deinit(self.gpa);
        if (self.path_set) {
            icon_lookup.freeDirs(self.gpa, self.dirs);
            self.path_set = false;
        }
        if (self.disk_init) self.disk.deinit();
    }

    /// Takes ownership of `dirs`. The search path changes with the icon-theme
    /// setting, so a stale one has to go rather than be reused. The disk
    /// cache is opened here rather than in `init`, because model tests build
    /// a menu with no I/O at all.
    pub fn setPath(self: *Icons, dirs: [][]const u8, theme: []const u8) void {
        if (self.path_set) icon_lookup.freeDirs(self.gpa, self.dirs);
        self.dirs = dirs;
        self.path_set = true;
        self.theme = theme;
        if (!self.disk_init) {
            self.disk = icon_disk.Disk.init(self.gpa, self.io);
            self.disk_init = true;
        }
        self.clear();
    }

    pub fn clear(self: *Icons) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.surf) |sf| cairo.cairo_surface_destroy(sf);
            self.gpa.free(e.value_ptr.data);
            self.gpa.free(e.key_ptr.*);
        }
        self.map.clearRetainingCapacity();
    }

    /// Paint-safe lookup: cache only. Never probes the filesystem, never
    /// decodes. A name nobody has asked for raises `pending` and paints the
    /// letter tile until the tick warms it; a name known to have no icon
    /// answers null too, but asks for nothing — that is how a search stops
    /// re-resolving an app whose theme has no art for it.
    pub fn getCached(self: *Icons, name: []const u8) ?*const Pixels {
        if (name.len == 0) return null;
        const e = self.map.getPtr(name) orelse {
            self.pending = true;
            return null;
        };
        if (e.data.len == 0 or e.w <= 0 or e.h <= 0) return null;
        if (e.surf != null) return e;
        // Pixels cached but no surface yet: wrapping the buffer is
        // microseconds and decodes nothing, so it rides the paint.
        const sf = cairo.cairo_image_surface_create_for_data(
            @constCast(e.data.ptr),
            cairo.CAIRO_FORMAT_ARGB32,
            e.w,
            e.h,
            e.w * 4,
        );
        if (cairo.cairo_surface_status(sf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(sf);
            return null;
        }
        e.surf = sf;
        return e;
    }

    /// Lazily resolve one name: shared index path, then disk cache, then a
    /// raster. Misses are remembered with an empty entry so a paint never
    /// re-asks. Only the tick prefetcher calls this; paints go through
    /// `getCached`.
    pub fn resolve(self: *Icons, name: []const u8) ?*const Pixels {
        if (name.len == 0 or !self.path_set) return null;
        if (self.map.getPtr(name)) |p| return if (p.data.len == 0) null else p;
        if (self.map.count() >= icon_cache_ceiling) self.clear();
        // The shared cache answers the probe from its theme-directory index —
        // an in-memory hash hit — instead of `icon_lookup.lookupAny`, which
        // walks the filesystem ladder with thousands of `access()` calls per
        // miss. Its path is borrowed and outlives this call; the fallback
        // probe's path is freed with `Found`, so it is copied out before the
        // probe is released.
        var owned_fpath: ?[]u8 = null;
        defer if (owned_fpath) |p| self.gpa.free(p);
        const fpath: []const u8 = blk: {
            if (icon_cache.shared()) |ic| {
                break :blk ic.pathFor(.app, name, icon_px) orelse {
                    self.rememberMiss(name);
                    return null;
                };
            }
            const f = icon_lookup.lookupAny(self.gpa, self.io, self.dirs, self.theme, name, @intCast(icon_px)) orelse {
                self.rememberMiss(name);
                return null;
            };
            defer icon_lookup.freeFound(self.gpa, f);
            owned_fpath = self.gpa.dupe(u8, f.path) catch return null;
            break :blk owned_fpath.?;
        };
        // Disk before raster: a previous process already paid for this
        // decode. The key rides the source file's stat, so an edited theme
        // file invalidates itself.
        if (self.disk_init) {
            var hex: [16]u8 = undefined;
            if (self.disk.key(self.theme, name, fpath, icon_px, &hex)) |dk| {
                if (self.disk.load(dk)) |saved| {
                    return self.putPixels(name, saved.pixels, saved.w, saved.h);
                }
            }
        }
        const px = (if (std.mem.endsWith(u8, fpath, ".svg"))
            icon_raster.loadSvg(self.gpa, fpath, icon_px)
        else
            icon_raster.loadPng(self.gpa, fpath)) orelse {
            self.rememberMiss(name);
            return null;
        };
        const stored = self.putPixels(name, px.data, px.w, px.h) orelse return null;
        if (self.disk_init) {
            var hex: [16]u8 = undefined;
            if (self.disk.key(self.theme, name, fpath, icon_px, &hex)) |dk| {
                self.disk.save(dk, stored.data, stored.w, stored.h);
            }
        }
        return stored;
    }

    /// Resolve uncached hit icons until `budget_ms` runs out. True means at
    /// least one fresh icon landed and the next frame can show it; hits order
    /// is relevance order, so the page facing the user warms first. Reaching
    /// the end of the list means every name the hits need is known, which
    /// lowers `pending`.
    pub fn prefetch(self: *Icons, budget_ms: u64, hits: []const usize, entries: []const cat.Entry) bool {
        if (!self.path_set) return false;
        const t0 = nowMs();
        var changed = false;
        for (hits) |idx| {
            if (idx >= entries.len) continue;
            const e = entries[idx];
            const name = if (e.icon.len > 0) e.icon else e.name;
            if (name.len == 0 or self.map.getPtr(name) != null) continue;
            if (nowMs() - t0 >= budget_ms) return changed;
            if (self.resolve(name) != null) changed = true;
        }
        self.pending = false;
        return changed;
    }

    /// Store resolved pixels under `name`, taking ownership of `data`.
    fn putPixels(self: *Icons, name: []const u8, data: []u8, w: i32, h: i32) ?*const Pixels {
        const key = self.gpa.dupe(u8, name) catch {
            self.gpa.free(data);
            return null;
        };
        const gop = self.map.getOrPut(self.gpa, key) catch {
            self.gpa.free(key);
            self.gpa.free(data);
            return null;
        };
        if (gop.found_existing) {
            self.gpa.free(key);
            self.gpa.free(data);
            return if (gop.value_ptr.data.len == 0) null else gop.value_ptr;
        }
        gop.value_ptr.* = .{ .data = data, .w = w, .h = h };
        return gop.value_ptr;
    }

    /// Remember a name that has no icon, so a repeat asks nothing more.
    fn rememberMiss(self: *Icons, name: []const u8) void {
        const key = self.gpa.dupe(u8, name) catch return;
        const gop = self.map.getOrPut(self.gpa, key) catch {
            self.gpa.free(key);
            return;
        };
        if (gop.found_existing) {
            self.gpa.free(key);
            return;
        }
        gop.value_ptr.* = .{};
    }
};

/// The offscreen surface the scrollable body is composed into. It holds one
/// screenful rather than the whole list: a catalog of a few hundred apps is
/// tens of thousands of pixels tall, and composing all of that on every open
/// is what made the panel take noticeable time to appear.
///
/// The rail panel keeps its own instance of this (`Resources.rail_body`): the
/// row pitch and the painter differ, so the two never share a surface.
pub const Body = struct {
    surf: ?*cairo.cairo_surface_t = null,
    cr: ?*cairo.cairo_t = null,
    w: i32 = 0,
    h: i32 = 0,
    gen: u64 = 0,
    list_mode: bool = false,
    /// Index of the first hit painted into the surface. Scrolling inside a
    /// row keeps it, so most frames reuse the surface as-is.
    first: usize = 0,

    pub fn deinit(self: *Body) void {
        if (self.cr) |c| cairo.cairo_destroy(c);
        if (self.surf) |s| cairo.cairo_surface_destroy(s);
        self.cr = null;
        self.surf = null;
        self.w = 0;
        self.h = 0;
        self.first = 0;
    }

    pub fn rebuild(self: *Body, w: i32, h: i32, gen: u64, list_mode: bool) void {
        self.deinit();
        const s = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
        if (cairo.cairo_surface_status(s) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(s);
            return;
        }
        const c = cairo.cairo_create(s);
        if (cairo.cairo_status(c) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_destroy(c);
            cairo.cairo_surface_destroy(s);
            return;
        }
        cairo.cairo_save(c);
        cairo.cairo_set_operator(c, cairo.CAIRO_OPERATOR_SOURCE);
        cairo.cairo_set_source_rgba(c, 0.0, 0.0, 0.0, 0.0);
        cairo.cairo_paint(c);
        cairo.cairo_restore(c);
        self.surf = s;
        self.cr = c;
        self.w = w;
        self.h = h;
        self.gen = gen;
        self.list_mode = list_mode;
    }
};

pub const Resources = struct {
    icons: Icons,
    body: Body = .{},
    /// The rail panel's own scroll cache. See `Body`.
    rail_body: Body = .{},

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Resources {
        return .{ .icons = Icons.init(gpa, io) };
    }

    pub fn deinit(self: *Resources) void {
        self.body.deinit();
        self.rail_body.deinit();
        self.icons.deinit();
    }

    /// Drop the cached scrollable body. The model calls this when the panel
    /// is resized or closed — the cache is keyed on geometry and a generation
    /// it cannot see from out here, so it has to be told.
    pub fn invalidateBody(self: *Resources) void {
        self.body.deinit();
        self.rail_body.deinit();
    }
};

// The model the paint reads

pub const View = struct {
    geo: layout.Geo,
    colors: chrome.Chrome = .{},
    res: *Resources,
    /// Which panel this frame is: the reference one above, or the App menu's
    /// rail. The rail carries its own geometry and painter.
    style: layout.Style = .classic,
    rgeo: layout.RailGeo = .{},
    /// Rail-only: the category indicator's current position, and the tooltip
    /// fade's alpha. Both are the model's tweens, already eased.
    bar_y: f64 = 0,
    tip_a: f64 = 0,
    /// Rail-only footer note; empty means the footer shows the highlighted
    /// app's description.
    toast: []const u8 = "",
    query: []const u8 = "",
    entries: []const cat.Entry = &.{},
    /// Catalog indices in display order.
    hits: []const usize = &.{},
    /// Bumped by the model whenever `hits` changes; keys the body cache.
    gen: u64 = 0,

    sel: i32 = -1,
    hover_row: i32 = -1,
    hover_pill: i32 = -1,
    sel_pill: i32 = -1,
    hover_power: i32 = -1,
    pill_w: [layout.pill_count]f64 = @splat(0.0),

    buckets: [cat.bucket_count]u32 = @splat(0),
    total: u32 = 0,

    focused: bool = false,
    caret_on: bool = false,
    scroll: f64 = 0,
    list_mode: bool = false,
    /// Night mode is on: the footer's last button draws the moon instead of
    /// the sun (C++ `s_nightlight_active`).
    night_on: bool = false,
    /// Power button awaiting confirmation, or -1.
    confirm: i32 = -1,

    /// The row a right press opened the menu on, or -1 when it is closed.
    ctx_row: i32 = -1,
    /// Where that press landed: the menu's anchor, in card coordinates.
    ctx_ax: f64 = 0,
    ctx_ay: f64 = 0,
    /// Menu item under the pointer, or -1.
    ctx_hover: i32 = -1,
    /// The menu's item reads "Unpin from dock" when the row is pinned.
    ctx_pinned: bool = false,
};

// Paint

/// `eh_app_drawer_paint`'s backdrop — the card, its chrome, and everything
/// drawn on it. `card_alpha` is `cardA` (`overlayOpacityWidgetCard *
/// overlay_surface_alpha_scale(AppDrawer)`) multiplied into the fill's
/// nominal 0.92, which is what lets the compositor's namespace blur read
/// through the glass.
pub fn paint(cr: ?*cairo.cairo_t, v: View, card_alpha: f64) void {
    const c = cr orelse return;
    const g = v.geo;

    cairo.cairo_save(c);
    helpers.roundedRect(c, 0.0, 0.0, g.w, g.h, layout.card_r);
    cairo.cairo_set_source_rgba(c, v.colors.dock_fill.r * 0.30, v.colors.dock_fill.g * 0.30, v.colors.dock_fill.b * 0.30, 0.92 * card_alpha);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
    helpers.roundedRect(c, 0.0, 0.0, g.w, g.h, layout.card_r);
    cairo.cairo_clip(c);

    paintSearch(c, v);
    paintDivider(c, g.body.x, g.divider_y, g.body.w, 0.08);
    paintPills(c, v);
    paintBody(c, v);
    paintFooter(c, v);
    if (v.ctx_row >= 0) paintCtxMenu(c, v);
    if (v.confirm >= 0) paintConfirm(c, v);

    cairo.cairo_restore(c);
}

fn paintDivider(c: ?*cairo.cairo_t, x: f64, y: f64, w: f64, a: f64) void {
    const cr = c orelse return;
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, a);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_move_to(cr, x, y + 0.5);
    cairo.cairo_line_to(cr, x + w, y + 0.5);
    cairo.cairo_stroke(cr);
}

fn paintSearch(c: ?*cairo.cairo_t, v: View) void {
    const cr = c orelse return;
    const g = v.geo;
    const f = g.search;
    const empty = v.query.len == 0;

    helpers.roundedRect(cr, f.x, f.y, f.w, f.h, layout.field_r);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.07);
    cairo.cairo_fill_preserve(cr);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, if (empty) 0.12 else 0.30);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);

    const mid = f.y + f.h * 0.5;
    const glyph_cx = f.x + 30.0;
    paintMagnifier(cr, glyph_cx, mid, 8.0, if (empty) 0.55 else 1.0);

    var buf: [32]u8 = undefined;
    var l = makeLayout(cr, fontDesc(&buf, "", 15.0));
    defer l.destroy();

    const text_x = f.x + 52.0;
    var hint_w: f64 = 0;
    var hint = makeLayout(cr, fontDesc(&buf, "", 12.0));
    defer hint.destroy();
    hint.setText(k_hint);
    hint_w = runWidth(&hint);
    const right_edge = f.x + f.w - 14.0;
    drawRun(cr, &hint, right_edge - hint_w, midTop(&hint, mid), 0.35);

    var caret_x = text_x + 1.5;
    if (empty) {
        l.setText(k_placeholder);
        drawRun(cr, &l, text_x, midTop(&l, mid), 0.38);
    } else {
        const max_w = @max(0.0, right_edge - hint_w - 16.0 - text_x);
        const shown = shrinkTo(&l, v.query, max_w);
        l.setText(shown);
        const w = runWidth(&l);
        drawRun(cr, &l, text_x, midTop(&l, mid), 0.95);
        caret_x = text_x + w + 1.5;
    }

    if (v.focused and v.caret_on) {
        cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.90);
        cairo.cairo_set_line_width(cr, 1.5);
        cairo.cairo_move_to(cr, caret_x, mid - 10.0);
        cairo.cairo_line_to(cr, caret_x, mid + 10.0);
        cairo.cairo_stroke(cr);
    }
}

fn paintPills(c: ?*cairo.cairo_t, v: View) void {
    const cr = c orelse return;
    const g = v.geo;
    var offsets: [layout.pill_count]f64 = undefined;
    layout.pillOffsets(&offsets, &v.pill_w, g.body.w, v.sel_pill);

    const mid = g.pills_y + layout.pill_h * 0.5;
    var buf: [48]u8 = undefined;
    var label = makeLayout(cr, fontDesc(&buf, "", 12.0));
    defer label.destroy();
    var count_l = makeLayout(cr, fontDesc(&buf, "", 12.0));
    defer count_l.destroy();

    for (0..layout.pill_count) |i| {
        const w = v.pill_w[i];
        if (w <= 0) continue;
        const x = g.body.x + offsets[i];
        const is_sel = v.sel_pill == @as(i32, @intCast(i));
        const is_hot = v.hover_pill == @as(i32, @intCast(i));
        helpers.roundedRect(cr, x, g.pills_y, w, layout.pill_h, layout.pill_r);
        if (is_sel) {
            cairo.cairo_set_source_rgba(cr, v.colors.accent.r, v.colors.accent.g, v.colors.accent.b, 0.95);
            cairo.cairo_fill(cr);
        } else {
            cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, if (is_hot) 0.14 else 0.08);
            cairo.cairo_fill_preserve(cr);
            cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, if (is_hot) 0.22 else 0.12);
            cairo.cairo_set_line_width(cr, 1.0);
            cairo.cairo_stroke(cr);
        }

        const count = if (i == 0) v.total else v.buckets[i - 1];
        const lbl: []const u8 = if (i == 0) "All" else cat.bucket_labels[i - 1];
        var cbuf: [16]u8 = undefined;
        const ctext = std.fmt.bufPrint(&cbuf, "{d}", .{count}) catch "0";

        label.setText(lbl);
        count_l.setText(ctext);
        const total_w = runWidth(&label) + 6.0 + runWidth(&count_l);
        const tx = x + (w - total_w) * 0.5;
        const top = midTop(&label, mid);
        const label_a: f64 = if (is_sel) 0.98 else 0.82;
        const count_a: f64 = if (is_sel) 0.75 else 0.45;
        drawRun(cr, &label, tx, top, label_a);
        drawRun(cr, &count_l, tx + runWidth(&label) + 6.0, top, count_a);
    }
}

fn paintFooter(c: ?*cairo.cairo_t, v: View) void {
    const cr = c orelse return;
    const g = v.geo;
    paintDivider(cr, g.body.x, g.footer_divider_y, g.body.w, 0.08);
    for (0..layout.power_count) |i| {
        // The nightlight toggle is set off from the four power actions the
        // way the C++ panel did: a hairline just past the last power button.
        if (i == layout.nightlight_idx) paintFooterSeparator(cr, v);
        paintFooterButton(cr, v, i);
    }
}

fn paintFooterSeparator(cr: *cairo.cairo_t, v: View) void {
    const g = v.geo;
    const sep_x = g.powerSeparatorX();
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.14);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_move_to(cr, sep_x, g.power[0].y + 4.0);
    cairo.cairo_line_to(cr, sep_x, g.power[0].y + layout.power_sz - 4.0);
    cairo.cairo_stroke(cr);
}

/// The Material names of the four power actions, the order the C++ panel
/// kept: lock, log out, restart, shut down.
const power_glyphs = [layout.nightlight_idx][]const u8{
    "lock", "logout", "restart_alt", "power_settings_new",
};

/// One footer button: the hover pill plus its glyph. The glyphs come from
/// the shared icon bank, so a name that loses its mapping draws nothing —
/// `material glyph`'s tests pin the names the footer needs.
fn paintFooterButton(cr: *cairo.cairo_t, v: View, i: usize) void {
    const r = v.geo.power[i];
    const hot = v.hover_power == @as(i32, @intCast(i));
    helpers.roundedRect(cr, r.x, r.y, r.w, r.h, layout.power_r);
    if (hot) {
        cairo.cairo_set_source_rgba(cr, v.colors.accent.r, v.colors.accent.g, v.colors.accent.b, 0.20);
        cairo.cairo_fill(cr);
    } else {
        cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.03);
        cairo.cairo_fill(cr);
    }
    // The nightlight button is the moon while night mode is on and the sun
    // while it is off, exactly the C++ `dark_mode`/`light_mode` swap.
    const name = if (i == layout.nightlight_idx)
        (if (v.night_on) "dark_mode" else "light_mode")
    else
        power_glyphs[i];
    _ = svg_icons.draw(
        cr,
        name,
        r.x + r.w * 0.5,
        r.y + r.h * 0.5,
        power_glyph_px,
        1.0,
        1.0,
        1.0,
        if (hot) 0.92 else 0.62,
        false,
    );
}

/// The C++ drew its Material ligatures at 22px inside the 32px buttons.
const power_glyph_px: f64 = 22.0;

/// The menu a right press asked for. Drawn after everything else in the card,
/// because it is the one thing meant to sit on top of the list: a near-opaque
/// panel of the dock's own fill, a faint outline, and the accent pill under
/// the item the pointer is on.
pub fn paintCtxMenu(c: ?*cairo.cairo_t, v: View) void {
    const cr = c orelse return;
    const r = layout.ctxRect(v.geo, v.ctx_ax, v.ctx_ay);
    const d = v.colors.dock_fill;

    helpers.roundedRect(cr, r.x, r.y, r.w, r.h, layout.ctx_r);
    cairo.cairo_set_source_rgba(cr, d.r, d.g, d.b, 0.98);
    cairo.cairo_fill_preserve(cr);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.35);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);

    const y0 = r.y + layout.ctx_pad;
    if (v.ctx_hover == 0) {
        helpers.roundedRect(
            cr,
            r.x + layout.ctx_inset,
            y0 + 1.0,
            r.w - layout.ctx_inset * 2.0,
            layout.ctx_item_h - 2.0,
            layout.ctx_item_r,
        );
        cairo.cairo_set_source_rgba(cr, v.colors.accent.r, v.colors.accent.g, v.colors.accent.b, 0.25);
        cairo.cairo_fill(cr);
    }

    var buf: [48]u8 = undefined;
    var l = makeLayout(cr, fontDesc(&buf, "", 13.0));
    defer l.destroy();
    l.setText(if (v.ctx_pinned) "Unpin from dock" else "Pin to dock");
    // The reference sets its baseline a shade below centre; the label is run
    // the same way so it does not sit a pixel high against it.
    drawRun(cr, &l, r.x + layout.ctx_text_x, midTop(&l, y0 + layout.ctx_item_h * 0.5 + 1.5), 0.96);
}

// The scrollable body

/// How far one item of the list sits from the next.
fn bodyPitch(v: View) f64 {
    return if (v.list_mode) layout.row_h else layout.cell_h + layout.grid_gap;
}

/// How many hits one row of the list takes: a column in the grid, one per
/// line in the rows.
fn bodyStride(v: View) usize {
    return if (v.list_mode) 1 else layout.cols;
}

/// The index of the first hit that reaches the viewport — the row the scroll
/// is inside, times the columns that row takes.
fn firstVisible(v: View) usize {
    if (v.hits.len == 0) return 0;
    const row: usize = @intFromFloat(@floor(@max(0.0, v.scroll) / bodyPitch(v)));
    return @min(row * bodyStride(v), v.hits.len - 1);
}

fn ensureBody(v: View) ?*cairo.cairo_surface_t {
    const res = v.res;
    const cw: i32 = @intFromFloat(@ceil(v.geo.body.w));
    const ch: i32 = @intFromFloat(@ceil(@max(1.0, v.geo.body.h)));
    const first = firstVisible(v);
    const b = &res.body;
    if (b.cr == null or b.w != cw or b.h != ch or b.gen != v.gen or
        b.list_mode != v.list_mode or b.first != first)
    {
        b.rebuild(cw, ch, v.gen, v.list_mode);
        b.first = first;
        if (b.cr) |bcr| paintBodyContent(bcr, v, first);
    }
    return b.surf;
}

fn paintBody(c: ?*cairo.cairo_t, v: View) void {
    const cr = c orelse return;
    const g = v.geo;
    cairo.cairo_save(cr);
    cairo.cairo_rectangle(cr, g.body.x, g.body.y, g.body.w, g.body.h);
    cairo.cairo_clip(cr);
    if (ensureBody(v)) |surf| {
        // The scroll is already inside the surface — it was composed at the
        // offset the viewport asks for.
        cairo.cairo_set_source_surface(cr, surf, g.body.x, g.body.y);
        cairo.cairo_paint(cr);
    }
    cairo.cairo_restore(cr);
}

/// Draws the slice of the list that reaches the viewport, in body-local
/// coordinates. Items keep the absolute coordinates they were laid out with
/// and the context moves instead, so neither painter has to know about the
/// scroll.
fn paintBodyContent(cr: ?*cairo.cairo_t, v: View, first: usize) void {
    if (v.hits.len == 0) {
        paintEmpty(cr, v);
        return;
    }
    const pitch = bodyPitch(v);
    const stride = bodyStride(v);
    const shift = @as(f64, @floatFromInt(first / stride)) * pitch;
    cairo.cairo_save(cr);
    cairo.cairo_translate(cr, 0.0, -shift);
    var i = first;
    while (i < v.hits.len) : (i += 1) {
        // The row that starts below the fold is the last that can show at all;
        // anything after it would be composed and clipped straight away.
        const y = @as(f64, @floatFromInt(i / stride)) * pitch - shift;
        if (y >= v.geo.body.h) break;
        if (v.list_mode) {
            paintRow(cr, v, v.hits[i], i);
        } else {
            paintCell(cr, v, v.hits[i], i);
        }
    }
    cairo.cairo_restore(cr);
}

fn paintEmpty(cr: ?*cairo.cairo_t, v: View) void {
    const c = cr orelse return;
    var buf: [32]u8 = undefined;
    var l = makeLayout(c, fontDesc(&buf, "", 13.0));
    defer l.destroy();
    l.setText(if (v.query.len == 0) k_empty_all else k_empty_filter);
    const w = runWidth(&l);
    drawRun(c, &l, (v.geo.body.w - w) * 0.5, 64.0 - @as(f64, @floatFromInt(l.pixelSize().h)), 0.50);
}

fn litIndex(v: View) i32 {
    return if (v.hover_row >= 0) v.hover_row else v.sel;
}

fn paintCell(cr: ?*cairo.cairo_t, v: View, idx: usize, i: usize) void {
    const c = cr orelse return;
    const g = v.geo;
    const col: usize = i % layout.cols;
    const row: usize = i / layout.cols;
    const x = @as(f64, @floatFromInt(col)) * g.cell_pitch;
    const y = @as(f64, @floatFromInt(row)) * (layout.cell_h + layout.grid_gap);
    const lit = litIndex(v);
    const is_sel = lit == @as(i32, @intCast(i)) and v.sel == @as(i32, @intCast(i));

    if (lit == @as(i32, @intCast(i))) {
        helpers.roundedRect(c, x, y, g.cell_w, layout.cell_h, layout.cell_r);
        if (is_sel) {
            cairo.cairo_set_source_rgba(c, v.colors.accent.r, v.colors.accent.g, v.colors.accent.b, 0.28);
            cairo.cairo_fill_preserve(c);
            cairo.cairo_set_source_rgba(c, v.colors.accent.r, v.colors.accent.g, v.colors.accent.b, 0.55);
            cairo.cairo_set_line_width(c, 1.5);
            cairo.cairo_stroke(c);
        } else {
            cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.10);
            cairo.cairo_fill(c);
        }
    }

    const e = v.entries[idx];
    const icon_x = x + (g.cell_w - layout.icon_grid) * 0.5;
    const icon_y = y + 4.0;
    if (!paintIcon(c, v, e, icon_x, icon_y, layout.icon_grid)) {
        paintFallback(c, e.name, icon_x, icon_y, layout.icon_grid, 14.0, 24.0);
    }

    var lbuf: [80]u8 = undefined;
    const lines = layout.labelLines(&lbuf, e.name);
    var buf: [32]u8 = undefined;
    var l = makeLayout(c, fontDesc(&buf, "", 11.0));
    defer l.destroy();
    const block_top = icon_y + layout.icon_grid + 7.0;
    const max_w = g.cell_w - 8.0;
    if (lines[1].len == 0) {
        l.setText(shrinkTo(&l, lines[0], max_w));
        const w = runWidth(&l);
        drawRun(c, &l, x + (g.cell_w - w) * 0.5, block_top + 6.0, 0.88);
    } else {
        var n: usize = 0;
        while (n < 2) : (n += 1) {
            l.setText(shrinkTo(&l, lines[n], max_w));
            const w = runWidth(&l);
            drawRun(c, &l, x + (g.cell_w - w) * 0.5, block_top + @as(f64, @floatFromInt(n)) * 13.0 + 1.0, 0.88);
        }
    }
}

fn paintRow(cr: ?*cairo.cairo_t, v: View, idx: usize, i: usize) void {
    const c = cr orelse return;
    const g = v.geo;
    const y = @as(f64, @floatFromInt(i)) * layout.row_h;
    const lit = litIndex(v);
    if (lit == @as(i32, @intCast(i))) {
        helpers.roundedRect(c, 4.0, y + 2.0, g.body.w - 8.0, 60.0, layout.row_r);
        cairo.cairo_set_source_rgba(c, v.colors.accent.r, v.colors.accent.g, v.colors.accent.b, 0.18);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_source_rgba(c, v.colors.accent.r, v.colors.accent.g, v.colors.accent.b, 0.35);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_stroke(c);
    }

    const e = v.entries[idx];
    if (!paintIcon(c, v, e, 12.0, y + 9.0, layout.icon_row)) {
        paintFallback(c, e.name, 12.0, y + 9.0, layout.icon_row, 12.0, 17.0);
    }

    const sub: []const u8 = if (e.comment.len > 0) e.comment else e.generic;
    const text_x = 70.0;
    const max_w = g.body.w - text_x - 8.0;
    var buf: [40]u8 = undefined;
    var name_l = makeLayout(c, fontDesc(&buf, "Bold", 13.5));
    defer name_l.destroy();
    var sub_l = makeLayout(c, fontDesc(&buf, "", 11.0));
    defer sub_l.destroy();

    name_l.setText(shrinkTo(&name_l, e.name, max_w));
    const name_h: f64 = @floatFromInt(name_l.pixelSize().h);
    var block_h = name_h;
    if (sub.len > 0) {
        sub_l.setText(shrinkTo(&sub_l, sub, max_w));
        block_h += 3.0 + @as(f64, @floatFromInt(sub_l.pixelSize().h));
    }
    var top = y + (layout.row_h - block_h) * 0.5;
    drawRun(c, &name_l, text_x, top, 0.95);
    if (sub.len > 0) {
        top += name_h + 3.0;
        drawRun(c, &sub_l, text_x, top, 0.55);
    }
}

pub fn paintIcon(c: ?*cairo.cairo_t, v: View, e: cat.Entry, x: f64, y: f64, box: f64) bool {
    const cr = c orelse return false;
    const name = if (e.icon.len > 0) e.icon else e.name;
    const px = v.res.icons.getCached(name) orelse return false;
    const surf = px.surf orelse return false;
    const iw: f64 = @floatFromInt(px.w);
    const ih: f64 = @floatFromInt(px.h);
    const scale = @min(box / iw, box / ih);
    const dx = x + (box - iw * scale) * 0.5;
    const dy = y + (box - ih * scale) * 0.5;
    cairo.cairo_save(cr);
    cairo.cairo_translate(cr, dx, dy);
    cairo.cairo_scale(cr, scale, scale);
    cairo.cairo_set_source_surface(cr, surf, 0.0, 0.0);
    cairo.cairo_pattern_set_extend(cairo.cairo_get_source(cr), cairo.CAIRO_EXTEND_NONE);
    cairo.cairo_paint(cr);
    cairo.cairo_restore(cr);
    return true;
}

/// The tile an entry with no icon of its own shows: a rounded plate with the
/// first character of its name on it.
pub fn paintFallback(c: ?*cairo.cairo_t, name: []const u8, x: f64, y: f64, box: f64, r: f64, font_px: f64) void {
    const cr = c orelse return;
    helpers.roundedRect(cr, x, y, box, box, r);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.10);
    cairo.cairo_fill(cr);
    const glyph = firstRune(name);
    if (glyph.len == 0) return;
    var buf: [32]u8 = undefined;
    var l = makeLayout(cr, fontDesc(&buf, "", font_px));
    defer l.destroy();
    l.setText(glyph);
    const w = runWidth(&l);
    const h: f64 = @floatFromInt(l.pixelSize().h);
    drawRun(cr, &l, x + (box - w) * 0.5, y + (box - h) * 0.5, 0.80);
}

// The confirmation card

pub fn paintConfirm(c: ?*cairo.cairo_t, v: View) void {
    const cr = c orelse return;
    const g = v.geo;
    const m = layout.modalOf(g);
    const idx: usize = @intCast(@max(0, v.confirm));

    cairo.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.45);
    cairo.cairo_paint(cr);

    helpers.roundedRect(cr, m.box.x, m.box.y, m.box.w, m.box.h, 24.0);
    cairo.cairo_set_source_rgba(cr, v.colors.dock_fill.r * 0.35, v.colors.dock_fill.g * 0.35, v.colors.dock_fill.b * 0.35, 0.98);
    cairo.cairo_fill_preserve(cr);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.14);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);

    var buf: [40]u8 = undefined;
    var title = makeLayout(cr, fontDesc(&buf, "SemiBold", 16.0));
    defer title.destroy();
    title.setText(power_titles[idx]);
    drawRun(cr, &title, m.box.x + (m.box.w - runWidth(&title)) * 0.5, m.title_y, 0.95);

    var body = makeLayout(cr, fontDesc(&buf, "", 13.0));
    defer body.destroy();
    body.setText(power_body);
    drawRun(cr, &body, m.box.x + (m.box.w - runWidth(&body)) * 0.5, m.body_y, 0.60);

    var lab = makeLayout(cr, fontDesc(&buf, "SemiBold", 14.0));
    defer lab.destroy();

    helpers.roundedRect(cr, m.cancel.x, m.cancel.y, m.cancel.w, m.cancel.h, 12.0);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.10);
    cairo.cairo_fill(cr);
    lab.setText(btn_cancel);
    drawRun(cr, &lab, m.cancel.x + (m.cancel.w - runWidth(&lab)) * 0.5, m.cancel.y + (m.cancel.h - @as(f64, @floatFromInt(lab.pixelSize().h))) * 0.5, 0.85);

    helpers.roundedRect(cr, m.confirm.x, m.confirm.y, m.confirm.w, m.confirm.h, 12.0);
    cairo.cairo_set_source_rgba(cr, v.colors.accent.r, v.colors.accent.g, v.colors.accent.b, 0.92);
    cairo.cairo_fill(cr);
    lab.setText(btn_go);
    const on_light = (v.colors.accent.r + v.colors.accent.g + v.colors.accent.b) / 3.0 > 0.55;
    drawRun(cr, &lab, m.confirm.x + (m.confirm.w - runWidth(&lab)) * 0.5, m.confirm.y + (m.confirm.h - @as(f64, @floatFromInt(lab.pixelSize().h))) * 0.5, if (on_light) 0.12 else 0.98);
}

// Drawn icons

pub fn paintMagnifier(c: ?*cairo.cairo_t, cx: f64, cy: f64, r: f64, a: f64) void {
    const cr = c orelse return;
    cairo.cairo_set_line_width(cr, 2.0);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, a);
    cairo.cairo_new_path(cr);
    cairo.cairo_arc(cr, cx - 1.5, cy - 1.5, r, 0.0, 2.0 * std.math.pi);
    cairo.cairo_stroke(cr);
    cairo.cairo_move_to(cr, cx + 4.5, cy + 4.5);
    cairo.cairo_line_to(cr, cx + 10.0, cy + 10.0);
    cairo.cairo_stroke(cr);
}

test "launcher: the card is translucent, so the compositor's blur reads" {
    const t = std.testing;
    var res = Resources.init(t.allocator, std.testing.io);
    defer res.deinit();
    const geo = layout.Geo.of(layout.preferred_w, layout.preferred_h);
    const w: i32 = @intFromFloat(geo.w);
    const h: i32 = @intFromFloat(geo.h);
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    // The start menu's surface *is* the card, so clearing to transparency
    // here is the whole backdrop — exactly what the host does per frame.
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);

    const v = View{ .geo = geo, .res = &res };
    paint(cr, v, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    _ = cairo.cairo_surface_flush(surf);
    const data: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const stride: i32 = @intCast(cairo.cairo_image_surface_get_stride(surf));
    // Right margin at mid-height: `margin` is 20 and every element stops
    // there, the corner radius only bites within `card_r` of the top and
    // bottom edges, and the hairline stroke sits at the very edge — card
    // fill alone, no glyph.
    const x: i32 = w - 4;
    const y: i32 = @divTrunc(h, 2);
    const idx = @as(usize, @intCast(y)) * @as(usize, @intCast(stride)) + @as(usize, @intCast(x)) * 4;
    const full = data[idx + 3];
    // 0.92 nominal fill over a cleared buffer — never the solid 255 the
    // panel painted before `card_alpha` reached this paint.
    try t.expect(full > 225 and full < 245);

    // Widget-card alpha: live 0.18 times the app-drawer scale
    // (live 0.56) — a tenth of nominal opacity over the blurred backdrop.
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
    paint(cr, v, 0.18 * 0.56);
    _ = cairo.cairo_surface_flush(surf);
    const thin = data[idx + 3];
    try t.expect(thin > 15 and thin < 35 and thin < full);
}

/// A 4×4 red PNG, premultiplication baked in by the decoder either way. The
/// disk/shared layers key on the file's stat, so its bytes only have to
/// decode.
const test_png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP47+DwHxkzkC4AAExPJ+HpZx/DAAAAAElFTkSuQmCC";

test "launcher: a paint never decodes; the tick prefetcher warms names off the path" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);
    // The standard theme layout: the name lives loose in the theme directory.
    // The probe walks relative paths, so the temp root works as-is; the name
    // does not exist in any real theme, so the answer can only come from here.
    const theme_dir = try std.fs.path.join(t.allocator, &.{ root, "hicolor" });
    defer t.allocator.free(theme_dir);
    try cwd.createDirPath(io, theme_dir);
    const icon_path = try std.fs.path.join(t.allocator, &.{ theme_dir, "eh-prefetch-warm.png" });
    defer t.allocator.free(icon_path);
    var png_buf: [256]u8 = undefined;
    const n = try std.base64.standard.Decoder.calcSizeForSlice(test_png_b64);
    try std.base64.standard.Decoder.decode(png_buf[0..n], test_png_b64);
    try cwd.writeFile(io, .{ .sub_path = icon_path, .data = png_buf[0..n] });

    var res = Resources.init(t.allocator, io);
    defer res.deinit();
    const dirs = try t.allocator.alloc([]const u8, 1);
    dirs[0] = try t.allocator.dupe(u8, root);
    res.icons.setPath(dirs, "hicolor"); // takes ownership of dirs

    // A paint asks, gets nothing, and says so — and the ask is answered from
    // the in-memory map alone, so nothing was decoded for it.
    try t.expect(res.icons.getCached("eh-prefetch-warm") == null);
    try t.expect(res.icons.pending);
    try t.expectEqual(@as(usize, 0), res.icons.map.count());

    // The tick prefetcher resolves it, reports the work, and lowers pending.
    const entries = [_]cat.Entry{.{ .name = "Warm Me", .icon = "eh-prefetch-warm" }};
    const hits = [_]usize{0};
    try t.expect(res.icons.prefetch(1000, &hits, &entries));
    try t.expect(!res.icons.pending);

    // The paint now answers from cache, and the surface is made once.
    const px = res.icons.getCached("eh-prefetch-warm") orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(i32, 4), px.w);
    try t.expectEqual(@as(i32, 4), px.h);
    const surf = px.surf orelse return error.TestUnexpectedResult;
    try t.expect(res.icons.getCached("eh-prefetch-warm").?.surf == surf);

    // Nothing uncached is left, so a second pass is silent.
    try t.expect(!res.icons.prefetch(1000, &hits, &entries));

    // A name with no icon anywhere is remembered: it is in the map with no
    // pixels, a repaint asks for nothing, and the tick is not pinned.
    res.icons.pending = false;
    const gone = [_]cat.Entry{.{ .name = "Absent", .icon = "eh-prefetch-absent" }};
    try t.expect(!res.icons.prefetch(1000, &hits, &gone));
    try t.expect(res.icons.map.getPtr("eh-prefetch-absent") != null);
    try t.expect(res.icons.getCached("eh-prefetch-absent") == null);
    try t.expect(!res.icons.pending);
}

test "launcher: the footer glyph names all resolve to vendored SVGs" {
    const t = std.testing;
    // The C++ footer drew Material ligatures; the port resolves the same
    // names through the shared icon bank. A name that loses its mapping
    // would vanish from the footer, so it has to fail here instead.
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    for (power_glyphs) |name| {
        try t.expect(svg_icons.draw(cr, name, 32, 32, power_glyph_px, 1, 1, 1, 1, false));
    }
    for ([_][]const u8{ "dark_mode", "light_mode" }) |name| {
        try t.expect(svg_icons.draw(cr, name, 32, 32, power_glyph_px, 1, 1, 1, 1, false));
    }
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
