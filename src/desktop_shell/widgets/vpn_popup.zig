//! `desktop_shell/widgets/popup/vpn/vpn_popup.{hpp,cpp,tpp}` — the VPN
//! connections card the dock's VPN slot opens.
//!
//! A fixed 320 px-wide card: shadow + dark glass, a `VPN Connections` header
//! with a close button, and one 44 px pill row per connection (status dot,
//! truncated name, `Connect`/`Disconnect` button, delete button). An empty
//! list paints a centred `No VPN connections` line instead of rows.
//!
//! What could not come across verbatim, and why:
//!
//! * **NetworkManager calls.** Toggles and removes
//!   connections inline (`activate/deactivate/removeVpnConnection` plus a
//!   `refresh()`), straight off the system bus. The Zig shell has no NM VPN
//!   verbs yet (`controlcenter/live_network.zig` covers state, devices and
//!   access points only), so `toggleEntry`/`removeEntry` mutate the entry
//!   cache around its service calls and hand the
//!   caller a `Verb` (`activate`/`deactivate`/`remove` plus the uuid) for
//!   the host to execute — the same split `media_popup.zig` uses for MPRIS.
//!   Paint takes the host's connection snapshot in and reconciles the cache
//!   against it, keyed off the live `nm.state()` snapshot.
//! * **The entry UUIDs.** Entries are keyed by uuid, so `Store.syncEntries` takes `{uuid,
//!   name, active}` triples and the old `Model.setList(names, active_name)`
//!   helper is gone — its one test is replaced by the sync tests below.
//!
//! Every rectangle below has one definition shared by the paint and the
//! hit-test, so a button that moves on screen moves under the pointer too
//! (the `media_popup.zig` rule).

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const schema = @import("../../config/schema.zig");
const chrome_colors = @import("./shared/chrome_colors.zig");
const helpers = @import("../shared/cairo_helpers.zig");
const glyphs = @import("../common/material_glyph.zig");

pub const popup_w: f64 = 320.0;

const k_pad: f64 = 16.0;
const k_corner: f64 = 20.0;
const k_row_h: f64 = 44.0;
const k_btn_w: f64 = 84.0;
const k_btn_h: f64 = 26.0;
const k_dot_r: f64 = 4.0;
const k_header_h: f64 = 48.0;
const k_remove_sz: f64 = 22.0;

const k_shad_dx: f64 = 2.0;
const k_shad_dy: f64 = 4.0;
const k_shad_alpha: f64 = 0.28;

/// Optimistic-toggle reconciliation window: a pending entry whose
/// authoritative state disagrees for longer than this stops being pending.
pub const pending_timeout_ns: i64 = 8 * std.time.ns_per_s;

/// Monotonic nanoseconds — the source the pending window measures against.
pub fn monotonicNs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * std.time.ns_per_s +
        @as(i64, @intCast(@max(ts.nsec, 0)));
}

// Entry cache

/// One `VpnConnectionInfo` as the card sees it, plus the optimistic-toggle
/// bookkeeping from `PopupVpnEntry`.
pub const Entry = struct {
    uuid: []u8,
    name: []u8,
    active: bool = false,
    pending: bool = false,
    pending_since_ns: i64 = 0,
};

/// One authoritative connection, as handed in by the host each frame.
pub const Connection = struct {
    uuid: []const u8,
    name: []const u8,
    active: bool = false,
};

/// What the host must do on the system bus after a click. The cache is
/// already updated optimistically; the verb is the service call made
/// in the same breath (`activate/deactivate/removeVpnConnection`,
/// plus a `refresh()` after a removal).
pub const Verb = enum { none, activate, deactivate, remove };

/// What a click decided. `reopen` never fires —
/// mapped to the same redraw as `redraw`, and
/// `vpn_popup_click_action` only ever answers `close`, `redraw` or `none` —
/// but the variant is kept so the vocabulary matches one for one.
pub const Click = enum { none, close, redraw, reopen };

pub const ClickResult = struct {
    click: Click = .none,
    verb: Verb = .none,
    /// Entry index the verb applies to (`uuid()` reads its uuid).
    index: usize = 0,
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(alloc: std.mem.Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        self.freeAll();
        self.entries.deinit(self.alloc);
    }

    pub fn count(self: *const Store) usize {
        return self.entries.items.len;
    }

    pub fn name(self: *const Store, idx: usize) []const u8 {
        return self.entries.items[idx].name;
    }

    pub fn uuid(self: *const Store, idx: usize) []const u8 {
        return self.entries.items[idx].uuid;
    }

    pub fn isActive(self: *const Store, idx: usize) bool {
        return self.entries.items[idx].active;
    }

    /// `vpn_popup_sync_entries` — rebuilds the cache from the authoritative
    /// list, preserving pending entries until they confirm or time out.
    /// `now_ns` is injected (not read) so the reconciliation is testable.
    pub fn syncEntries(self: *Store, conns: []const Connection, now_ns: i64) !void {
        var next = std.ArrayList(Entry).empty;
        errdefer {
            for (next.items) |*e| {
                self.alloc.free(e.uuid);
                self.alloc.free(e.name);
            }
            next.deinit(self.alloc);
        }
        for (conns) |c| {
            if (self.findByUuid(c.uuid)) |old| {
                var e = Entry{
                    .uuid = try self.alloc.dupe(u8, old.uuid),
                    .name = try self.alloc.dupe(u8, old.name),
                    .active = old.active,
                    .pending = old.pending,
                    .pending_since_ns = old.pending_since_ns,
                };
                errdefer {
                    self.alloc.free(e.uuid);
                    self.alloc.free(e.name);
                }
                // A renamed connection still reconciles by uuid.
                if (!std.mem.eql(u8, e.name, c.name)) {
                    self.alloc.free(e.name);
                    e.name = try self.alloc.dupe(u8, c.name);
                }
                if (e.pending and (now_ns - e.pending_since_ns >= pending_timeout_ns or e.active == c.active)) {
                    e.pending = false;
                }
                if (!e.pending) e.active = c.active;
                try next.append(self.alloc, e);
            } else {
                try next.append(self.alloc, .{
                    .uuid = try self.alloc.dupe(u8, c.uuid),
                    .name = try self.alloc.dupe(u8, c.name),
                    .active = c.active,
                });
            }
        }
        self.freeAll();
        self.entries.deinit(self.alloc);
        self.entries = next;
    }

    fn findByUuid(self: *const Store, id: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.uuid, id)) return e;
        }
        return null;
    }

    fn freeAll(self: *Store) void {
        for (self.entries.items) |*e| {
            self.alloc.free(e.uuid);
            self.alloc.free(e.name);
        }
        self.entries.clearRetainingCapacity();
    }

    /// `PopupVpnEntry::toggle` minus the service call: flips the state,
    /// marks the entry pending from `now_ns`, and tells the host which
    /// verb to run. Null verb (`.none`) when `idx` is out of range.
    pub fn toggleEntry(self: *Store, idx: usize, now_ns: i64) Verb {
        if (idx >= self.entries.items.len) return .none;
        const e = &self.entries.items[idx];
        e.active = !e.active;
        e.pending = true;
        e.pending_since_ns = now_ns;
        return if (e.active) .activate else .deactivate;
    }

    /// `vpn_popup_remove_entry` minus the service calls: drops the entry
    /// and tells the host to remove + refresh. `.none` out of range.
    pub fn removeEntry(self: *Store, idx: usize) Verb {
        if (idx >= self.entries.items.len) return .none;
        const e = self.entries.orderedRemove(idx);
        self.alloc.free(e.uuid);
        self.alloc.free(e.name);
        return .remove;
    }
};

// Geometry (one definition for paint and hit-test)

/// `vpn_popup_height` — `Pad + Header + max(n,1) rows + Pad`.
pub fn heightFor(vpn_count: usize) f64 {
    return k_pad + k_header_h + @as(f64, @floatFromInt(@max(vpn_count, 1))) * k_row_h + k_pad;
}

/// The header close button: 24x24 at the top right.
pub fn closeRect() [4]f64 {
    return .{ popup_w - k_pad - 24.0, k_pad, 24.0, 24.0 };
}

pub const RowGeom = struct {
    row_y: f64,
    mid_y: f64,
    pill: [4]f64,
    /// `Connect`/`Disconnect` button.
    btn: [4]f64,
    /// Delete button.
    remove: [4]f64,
    dot_cx: f64,
    /// Maximum name advance: button left edge minus the text origin.
    name_max_adv: f64,
    text_x: f64,
};

/// Row `idx` geometry. `pillR` follows (`max(2, min(rowH,
/// innerW) * 0.22)`).
pub fn rowGeom(idx: usize) RowGeom {
    const row_y = k_pad + k_header_h + @as(f64, @floatFromInt(idx)) * k_row_h;
    const mid_y = row_y + k_row_h * 0.5;
    const rem_x = popup_w - k_pad - k_remove_sz;
    const btn_x = rem_x - 6.0 - k_btn_w;
    const dot_cx = k_pad + 16.0;
    return .{
        .row_y = row_y,
        .mid_y = mid_y,
        .pill = .{ k_pad, row_y, popup_w - k_pad * 2.0, k_row_h },
        .btn = .{ btn_x, mid_y - k_btn_h * 0.5, k_btn_w, k_btn_h },
        .remove = .{ rem_x, mid_y - k_remove_sz * 0.5, k_remove_sz, k_remove_sz },
        .dot_cx = dot_cx,
        .name_max_adv = btn_x - 6.0 - (dot_cx + 16.0),
        .text_x = dot_cx + 16.0,
    };
}

fn inRect(px: f64, py: f64, r: [4]f64) bool {
    return px >= r[0] and px < r[0] + r[2] and py >= r[1] and py < r[1] + r[3];
}

/// `utf8_pop_back` — drops one codepoint off the end.
pub fn utf8PopBack(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if ((s[i] & 0xc0) != 0x80) return s[0..i];
    }
    return s[0..0];
}

/// `truncate_to_width` — shortens `s` until `adv(s) <= max_adv`, never
/// below 3 bytes of payload (floor at 4, which keeps
/// at least a stub of multibyte text). Pure and pointer-free so tests can
/// drive it with a fake advance function.
pub fn truncateToWidth(
    s: []const u8,
    max_adv: f64,
    adv: *const fn (ctx: *anyopaque, s: []const u8) f64,
    ctx: *anyopaque,
) []const u8 {
    var out = s;
    while (true) {
        if (adv(ctx, out) <= max_adv or out.len < 4) break;
        const shorter = utf8PopBack(out);
        if (shorter.len == out.len) break;
        out = shorter;
    }
    return out;
}

fn cairoAdvance(ctx: *anyopaque, s: []const u8) f64 {
    const cr: ?*cairo.cairo_t = @ptrCast(ctx);
    var zbuf: [1024:0]u8 = [_:0]u8{0} ** 1024;
    const n = @min(s.len, 1023);
    @memcpy(zbuf[0..n], s[0..n]);
    var ex: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(cr, &zbuf, &ex);
    return ex.x_advance;
}

/// `vpn_popup_click_action` — outside the card or on the close box closes;
/// the remove button wins over the connect button on its row. Toggle and
/// remove mutate the store (optimistically) and report the
/// verb for the host; either answers `redraw`.
pub fn click(store: *Store, x: f64, y: f64, now_ns: i64) ClickResult {
    const h = heightFor(store.count());
    if (x < 0 or x >= popup_w or y < 0 or y >= h) return .{ .click = .close };
    if (inRect(x, y, closeRect())) return .{ .click = .close };
    for (0..store.count()) |vi| {
        const g = rowGeom(vi);
        if (inRect(x, y, g.remove)) {
            const verb = store.removeEntry(vi);
            return .{ .click = .redraw, .verb = verb, .index = vi };
        }
        if (inRect(x, y, g.btn)) {
            const verb = store.toggleEntry(vi, now_ns);
            return .{ .click = .redraw, .verb = verb, .index = vi };
        }
    }
    return .{};
}

// Paint

fn setToyFont(cr: ?*cairo.cairo_t, size: f64, bold: bool) void {
    cairo.cairo_select_font_face(
        cr,
        "Inter",
        cairo.CAIRO_FONT_SLANT_NORMAL,
        if (bold) cairo.CAIRO_FONT_WEIGHT_BOLD else cairo.CAIRO_FONT_WEIGHT_NORMAL,
    );
    cairo.cairo_set_font_size(cr, size);
}

fn showText(cr: ?*cairo.cairo_t, s: []const u8, x: f64, y: f64) void {
    var zbuf: [1024:0]u8 = [_:0]u8{0} ** 1024;
    const n = @min(s.len, 1023);
    @memcpy(zbuf[0..n], s[0..n]);
    cairo.cairo_move_to(cr, x, y);
    cairo.cairo_show_text(cr, &zbuf);
}

/// `dock_vpn_popup_paint` — the host hands in its authoritative snapshot
/// (read off the live `nm.state()` snapshot) plus the pointer for hover.
/// A null `cr` measures nothing and paints nothing.
pub fn paint(
    cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    store: *Store,
    conns: []const Connection,
    pointer: ?[2]f64,
) void {
    const c = cr orelse return;
    store.syncEntries(conns, monotonicNs()) catch return;
    const n = store.count();
    const h = heightFor(n);
    const mc = chrome_colors.of(sc);
    const card_alpha = @as(f64, sc.appearance.overlay_opacity_widget_card);

    cairo.cairo_save(c);
    defer cairo.cairo_restore(c);

    helpers.roundedRect(c, k_shad_dx, k_shad_dy, popup_w, h, k_corner);
    // Scaled with the card: 0% must leave nothing, shadow included.
    cairo.cairo_set_source_rgba(c, 0, 0, 0, k_shad_alpha * card_alpha);
    cairo.cairo_fill(c);

    helpers.roundedRect(c, 0, 0, popup_w, h, k_corner);
    cairo.cairo_set_source_rgba(c, mc.dock_fill.r * 0.30, mc.dock_fill.g * 0.30, mc.dock_fill.b * 0.30, 0.92 * card_alpha);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    const px: f64 = if (pointer) |p| p[0] else -1.0;
    const py: f64 = if (pointer) |p| p[1] else -1.0;

    const cb = closeRect();
    const cb_hover = inRect(px, py, cb);
    helpers.roundedRect(c, cb[0], cb[1], cb[2], cb[3], 7.0);
    cairo.cairo_set_source_rgba(c, 0.3, 0.3, 0.35, if (cb_hover) 0.75 else 0.45);
    cairo.cairo_fill(c);
    _ = glyphs.draw(c, "close", cb[0] + cb[2] * 0.5, cb[1] + cb[3] * 0.5, 14, mc.text.r, mc.text.g, mc.text.b, if (cb_hover) 1.0 else 0.85);

    cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.92);
    setToyFont(c, 14, true);
    showText(c, "VPN Connections", k_pad, k_pad + 30);

    if (n == 0) {
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.5);
        setToyFont(c, 13, false);
        const msg = "No VPN connections";
        var zbuf: [64:0]u8 = [_:0]u8{0} ** 64;
        @memcpy(zbuf[0..msg.len], msg);
        var ex: cairo.cairo_text_extents_t = undefined;
        cairo.cairo_text_extents(c, &zbuf, &ex);
        showText(c, msg, (popup_w - ex.x_advance) * 0.5, k_pad + k_header_h + k_row_h * 0.5 + 4);
        return;
    }

    const ctx_ptr: *anyopaque = @ptrCast(c);
    for (0..n) |vi| {
        const g = rowGeom(vi);
        const active = store.isActive(vi);
        const pill_r = @max(2.0, @min(k_row_h, popup_w - k_pad * 2.0) * 0.22);

        helpers.roundedRect(c, g.pill[0], g.pill[1], g.pill[2], g.pill[3], pill_r);
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.07);
        cairo.cairo_fill(c);

        if (inRect(px, py, g.pill)) {
            helpers.roundedRect(c, g.pill[0], g.pill[1], g.pill[2], g.pill[3], pill_r);
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.18);
            cairo.cairo_fill_preserve(c);
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.35);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_stroke(c);
        }

        if (active) {
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.85);
        } else {
            cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.35);
        }
        cairo.cairo_arc(c, g.dot_cx, g.mid_y, k_dot_r, 0, 2 * std.math.pi);
        cairo.cairo_fill(c);

        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 1.0);
        setToyFont(c, 13, false);
        const shown = truncateToWidth(store.name(vi), g.name_max_adv, &cairoAdvance, ctx_ptr);
        showText(c, shown, g.text_x, g.mid_y + 5);

        const rem_hover = inRect(px, py, g.remove);
        helpers.roundedRect(c, g.remove[0], g.remove[1], g.remove[2], g.remove[3], 5.0);
        cairo.cairo_set_source_rgba(c, 0.85, 0.25, 0.20, if (rem_hover) 0.40 else 0.20);
        cairo.cairo_fill(c);
        _ = glyphs.draw(c, "delete", g.remove[0] + k_remove_sz * 0.5, g.remove[1] + k_remove_sz * 0.5, 12, mc.text.r, mc.text.g, mc.text.b, if (rem_hover) 0.85 else 0.55);

        const btn_hover = inRect(px, py, g.btn);
        helpers.roundedRect(c, g.btn[0], g.btn[1], g.btn[2], g.btn[3], 6.0);
        if (active) {
            cairo.cairo_set_source_rgba(c, 0.85, 0.25, 0.20, if (btn_hover) 0.85 else 0.65);
        } else {
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, if (btn_hover) 0.85 else 0.65);
        }
        cairo.cairo_fill(c);

        const lbl: []const u8 = if (active) "Disconnect" else "Connect";
        cairo.cairo_set_source_rgba(c, 1, 1, 1, if (btn_hover) 1.0 else 0.90);
        setToyFont(c, 11, false);
        var zbuf: [16:0]u8 = [_:0]u8{0} ** 16;
        @memcpy(zbuf[0..lbl.len], lbl);
        var te: cairo.cairo_text_extents_t = undefined;
        cairo.cairo_text_extents(c, &zbuf, &te);
        showText(c, lbl, g.btn[0] + (k_btn_w - te.x_advance) * 0.5, g.btn[1] + k_btn_h * 0.5 + te.height * 0.35);
    }
}

// Tests

fn conn(uuid: []const u8, name: []const u8, active: bool) Connection {
    return .{ .uuid = uuid, .name = name, .active = active };
}

test "vpn-popup: sync adds, drops and renames by uuid" {
    const t = std.testing;
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.syncEntries(&[_]Connection{ conn("u1", "work", false), conn("u2", "home", true) }, 0);
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expectEqualStrings("home", s.name(1));
    try t.expect(s.isActive(1));
    // Rename + drop + add, keyed by uuid.
    try s.syncEntries(&[_]Connection{ conn("u2", "cabin", true), conn("u3", "lab", false) }, 0);
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expectEqualStrings("cabin", s.name(0));
    try t.expectEqualStrings("lab", s.name(1));
}

test "vpn-popup: pending survives until confirm or timeout" {
    const t = std.testing;
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.syncEntries(&[_]Connection{conn("u1", "work", false)}, 0);
    try t.expectEqual(Verb.activate, s.toggleEntry(0, 0));
    try t.expect(s.isActive(0));
    // Authoritative state still says off, 1s later: pending wins.
    try s.syncEntries(&[_]Connection{conn("u1", "work", false)}, std.time.ns_per_s);
    try t.expect(s.isActive(0));
    // Confirmed on: pending clears.
    try s.syncEntries(&[_]Connection{conn("u1", "work", true)}, 2 * std.time.ns_per_s);
    try t.expect(s.isActive(0));
    try t.expect(!s.entries.items[0].pending);
    // Disagree past the 8s window: pending clears, authority wins.
    try t.expectEqual(Verb.deactivate, s.toggleEntry(0, 3 * std.time.ns_per_s));
    try s.syncEntries(&[_]Connection{conn("u1", "work", true)}, 12 * std.time.ns_per_s);
    try t.expect(s.isActive(0));
    try t.expect(!s.entries.items[0].pending);
    // Out of range is a no-op.
    try t.expectEqual(Verb.none, s.toggleEntry(9, 0));
    try t.expectEqual(Verb.none, s.removeEntry(9));
}

test "vpn-popup: remove drops the entry" {
    const t = std.testing;
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.syncEntries(&[_]Connection{ conn("u1", "a", false), conn("u2", "b", false) }, 0);
    try t.expectEqual(Verb.remove, s.removeEntry(0));
    try t.expectEqual(@as(usize, 1), s.count());
    try t.expectEqualStrings("b", s.name(0));
}

test "vpn-popup: geometry matches the specified constants" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 16 + 48 + 44 + 16), heightFor(1));
    try t.expectEqual(@as(f64, 16 + 48 + 44 + 16), heightFor(0));
    try t.expectEqual(@as(f64, 16 + 48 + 3 * 44 + 16), heightFor(3));
    const g = rowGeom(0);
    try t.expectEqual(@as(f64, 64.0), g.row_y);
    try t.expectEqual(@as(f64, 320 - 16 - 22), g.remove[0]);
    try t.expectEqual(@as(f64, 320 - 16 - 22 - 6 - 84), g.btn[0]);
    const cb = closeRect();
    try t.expectEqual([4]f64{ 320 - 16 - 24, 16, 24, 24 }, cb);
}

test "vpn-popup: clicks route to close, remove, toggle or nothing" {
    const t = std.testing;
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.syncEntries(&[_]Connection{conn("u1", "work", false)}, 0);
    // Outside the card closes.
    try t.expectEqual(Click.close, (click(&s, -1, 10, 0)).click);
    try t.expectEqual(Click.close, (click(&s, 10, 9999, 0)).click);
    // Close box closes.
    const cb = closeRect();
    try t.expectEqual(Click.close, (click(&s, cb[0] + 1, cb[1] + 1, 0)).click);
    // Connect button toggles and reports the verb.
    const g = rowGeom(0);
    const tb = click(&s, g.btn[0] + 1, g.btn[1] + 1, 0);
    try t.expectEqual(Click.redraw, tb.click);
    try t.expectEqual(Verb.activate, tb.verb);
    try t.expectEqual(@as(usize, 0), tb.index);
    // Delete button removes and reports the verb.
    const rb = click(&s, g.remove[0] + 1, g.remove[1] + 1, 0);
    try t.expectEqual(Click.redraw, rb.click);
    try t.expectEqual(Verb.remove, rb.verb);
    try t.expectEqual(@as(usize, 0), s.count());
    // Dead space is a no-op.
    try t.expectEqual(Click.none, (click(&s, 4, 4, 0)).click);
}

test "vpn-popup: utf8 truncation keeps whole codepoints and the 3-byte floor" {
    const t = std.testing;
    const adv = struct {
        fn f(_: *anyopaque, s: []const u8) f64 {
            return @floatFromInt(s.len);
        }
    }.f;
    var ctx: u8 = 0;
    // "é" is 2 bytes: popping it removes both, never a half.
    try t.expectEqualStrings("ab", truncateToWidth("abé", 3, adv, &ctx));
    try t.expectEqualStrings("abé", truncateToWidth("abé", 4, adv, &ctx));
    // Floor at 4: a 3-byte string never truncates further.
    try t.expectEqualStrings("abc", truncateToWidth("abc", 0, adv, &ctx));
}

test "vpn-popup: paint tolerates null and paints rows for real" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator, "");
    defer loaded.deinit();
    var s = Store.init(t.allocator);
    defer s.deinit();
    // Null context: no crash, entries still reconcile.
    try s.syncEntries(&[_]Connection{conn("u1", "work", false)}, 0);
    paint(null, &loaded.cfg, &s, &[_]Connection{conn("u1", "work", false)}, null);
    try t.expectEqual(@as(usize, 1), s.count());

    // Real cairo surface: header, one row and the empty branch all paint.
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 320, 200);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paint(cr, &loaded.cfg, &s, &[_]Connection{ conn("u1", "work", false), conn("u2", "cabin", true) }, .{ 300.0, 20.0 });
    try t.expectEqual(@as(usize, 2), s.count());
    paint(cr, &loaded.cfg, &s, &.{}, null);
    try t.expectEqual(@as(usize, 0), s.count());
}
