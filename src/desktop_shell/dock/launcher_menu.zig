//! The launcher's model: the query, the ranked hit list under it, the
//! selection and the scroll, and what each click and key press does about
//! them. The popup host asks for a `paint.View` and hands back the decisions
//! here as small values; nothing in this file owns a surface or a process
//! table.
//!
//! The same model drives two panels. The reference panel — category pills,
//! a grid or a list, the power strip — is what the App drawer and the start
//! menu open. The App menu opens the rail panel: a 540x420 card with the
//! categories on a rail, a list-only body and a footer. Which one is open
//! changes the geometry the pointer is measured against and which keys are
//! honoured; the catalog, the ranking and the scroll are shared.
//!
//! The list is rebuilt from the catalog on every keystroke. That sounds
//! expensive and is not: it is one pass over a few hundred entries, and the
//! expensive part of a repaint — the pango layouts and the icon blits — is
//! cached separately behind the generation counter the rebuild bumps.

const std = @import("std");
const seat_mod = @import("../../wl/seat.zig");
const cat = @import("../../services/app_catalog.zig");
const autostart = @import("../../services/autostart.zig");
const layout = @import("../widgets/launcher_layout.zig");
const paint = @import("../widgets/launcher_paint.zig");
const measure = @import("../widgets/shared/measure_scratch.zig");
const chrome = @import("../widgets/shared/chrome_colors.zig");
const anim = @import("anim.zig");

/// Time constant of the scroll's exponential approach, and the interval the
/// caret blinks at. Both are picked so the motion reads as smooth rather than
/// as either a jump or a crawl.
const scroll_tau_ns: u64 = 40_000_000;
const caret_period_ns: u64 = 530_000_000;
/// Far enough past the time constant that the remaining distance is invisible.
const scroll_settle_ns: u64 = 400_000_000;
/// Below this the animation would be chasing sub-pixel rounding forever.
const scroll_epsilon: f64 = 0.25;
/// The rail's own motion, straight from the design: the category indicator
/// slides between buttons over 180 ms of ease-out, a tooltip fades in over
/// 120 ms, and an action's footer note stays for 1.4 s.
const bar_ns: u64 = 180 * std.time.ns_per_ms;
const tip_ns: u64 = 120 * std.time.ns_per_ms;
const toast_ns: u64 = 1400 * std.time.ns_per_ms;

const max_pattern: usize = 128;
const pill_label_px: f64 = 12.0;
const pill_gap_text: f64 = 6.0;

/// The panel this model is driving; see `launcher_layout.Style`.
pub const Style = layout.Style;

pub const Op = enum {
    /// Nothing decided. The frame may still want redrawing.
    none,
    /// Close the popup. The input that asked for it is swallowed.
    close,
    /// Start the entry `Decision.hit` indexes into the hit list.
    launch,
    /// Start it without closing the panel (`Ctrl+Enter` on the rail). The
    /// model has already written "Opening …" into the footer note, which is
    /// the whole reason a keep-open launch is worth a decision of its own.
    launch_keep,
    /// Keyboard focus moved into the search field.
    focus_field,
    /// Show the confirmation card for power button `Decision.hit`.
    ask_power,
    /// Run power button `Decision.hit` and close.
    run_power,
    /// Flip the nightlight from the footer toggle. The host owns the switch
    /// (the config write and the reload) and repaints.
    toggle_night,
    /// The rail's Reload-shell button: the host re-reads its config and
    /// repaints. The panel stays up.
    reload_shell,
    /// The rail's theme toggle. The host flips `matugen_mode` the way the
    /// pear centre's Scheme tile does and repaints in the new palette.
    toggle_theme,
    /// The model changed under the pointer or the keys; repaint.
    repaint,
    /// The row menu's item: add the app of the row at `Decision.hit` to, or
    /// take it out of, the dock's pin list. The menu closes with this.
    ctx_pin,
};

pub const Decision = struct {
    op: Op = .none,
    hit: i32 = -1,
};

const Ranked = struct { idx: usize, sc: u32 };

fn rankBefore(_: void, a: Ranked, b: Ranked) bool {
    if (a.sc != b.sc) return a.sc > b.sc;
    // The catalog is already ordered by name, so falling back to the index is
    // falling back to the name — and it keeps ties from shuffling per keystroke.
    return a.idx < b.idx;
}

fn setIf(field: *i32, want: i32) bool {
    if (field.* == want) return false;
    field.* = want;
    return true;
}

fn env(name: [:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    const s = std.mem.span(p);
    return if (s.len == 0) null else s;
}

pub const Menu = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    catalog: cat.Catalog,
    res: paint.Resources,
    geo: layout.Geo,
    colors: chrome.Chrome = .{},
    /// Output fit factor (output height / 1440, clamped) the panel is drawn
    /// at. The surface is this factor smaller than `geo`; the paint is wrapped
    /// in a matching `cairo_scale(fit)`, so every handler that takes a pointer
    /// coordinate divides by it first — `geo` stays in the natural 1440-space
    /// the layout constants are authored in.
    fit: f64 = 1.0,

    /// Which panel this model is driving. The rail is list-only; the style
    /// owns that bit, so nothing else about the model flips with it.
    style: layout.Style = .classic,
    /// The rail panel's geometry. Both geos are kept current by `sizeTo`;
    /// only the open style's is ever hit-tested.
    rgeo: layout.RailGeo = .{},
    /// Rail-only: the category indicator's slide and the tooltip fade. Both
    /// are driven by `tick`, which is what keeps an idle panel from
    /// spinning — nothing else in the rail moves on its own.
    bar: anim.Tween = .{},
    tip: anim.Tween = .{},
    /// Rail-only footer note ("Opening Foo", "Shell reloaded"). Empty means
    /// the footer shows the highlighted app's description instead.
    toast: [96]u8 = @splat(0),
    toast_len: usize = 0,
    toast_until_ns: u64 = 0,

    query: std.ArrayListUnmanaged(u8) = .empty,
    hits: std.ArrayListUnmanaged(usize) = .empty,
    ranked: std.ArrayListUnmanaged(Ranked) = .empty,

    sel: i32 = -1,
    hover_row: i32 = -1,
    hover_pill: i32 = -1,
    hover_power: i32 = -1,
    /// -1 is "All"; `i` is `bucket[i - 1]`. Survives a close, the way a
    /// remembered category should.
    sel_pill: i32 = -1,
    focused: bool = true,
    caret_on: bool = true,
    confirm: i32 = -1,
    gen: u64 = 0,

    /// The row a right press opened the menu on, or -1 while it is closed.
    ctx_row: i32 = -1,
    /// Where that press landed: the menu's anchor, in card coordinates.
    ctx_ax: f64 = 0,
    ctx_ay: f64 = 0,
    /// The menu item under the pointer, or -1.
    ctx_hover: i32 = -1,
    /// Whether the row the menu sits on is already in the dock's pin list.
    /// The model never reads the dock's config, so the panel answers this
    /// with the press that opened the menu.
    ctx_pinned: bool = false,

    buckets: [cat.bucket_count]u32 = @splat(0),
    total: u32 = 0,
    pill_w: [layout.pill_count]f64 = @splat(0.0),
    pill_x: [layout.pill_count]f64 = @splat(0.0),

    target: f64 = 0,
    current: f64 = 0,
    scroll_from: f64 = 0,
    scroll_ns: u64 = 0,
    scrolling: bool = false,

    list_mode: bool = false,
    /// The nightlight toggle in the footer: the paint shows the moon while
    /// night mode is on and the sun while it is off (C++ parity). Owned by
    /// the host's config; the menu only carries it to the paint.
    night_on: bool = false,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Self {
        return .{
            .gpa = gpa,
            .io = io,
            .catalog = .{ .arena = std.heap.ArenaAllocator.init(gpa) },
            .res = paint.Resources.init(gpa, io),
            .geo = layout.Geo.of(layout.preferred_w, layout.preferred_h),
            .rgeo = layout.RailGeo.of(layout.rail_w, layout.rail_h),
        };
    }

    pub fn deinit(self: *Self) void {
        self.res.deinit();
        self.catalog.deinit();
        self.query.deinit(self.gpa);
        self.hits.deinit(self.gpa);
        self.ranked.deinit(self.gpa);
    }

    /// Re-scan and re-present. Called every time the menu opens, which is what
    /// makes an application installed a second ago appear without a restart,
    /// and what wipes a half-typed query left behind by an abrupt close.
    pub fn open(self: *Self) void {
        self.reset();
        self.catalog.deinit();
        self.catalog = cat.load(self.gpa, self.io) catch cat.Catalog{
            .arena = std.heap.ArenaAllocator.init(self.gpa),
        };
        const c = self.catalog.counts();
        self.buckets = c.buckets;
        self.total = c.total;
        self.layoutPills();
        self.refresh();
    }

    /// The state a fresh open starts from. The remembered category is
    /// deliberately *not* cleared; the query is, because a half-typed search
    /// from last time is never what the user came back for.
    pub fn reset(self: *Self) void {
        self.query.clearRetainingCapacity();
        self.hits.clearRetainingCapacity();
        self.ranked.clearRetainingCapacity();
        self.sel = -1;
        self.hover_row = -1;
        self.hover_pill = -1;
        self.hover_power = -1;
        self.confirm = -1;
        self.ctx_row = -1;
        self.ctx_hover = -1;
        self.ctx_pinned = false;
        self.focused = true;
        self.caret_on = true;
        self.target = 0;
        self.current = 0;
        self.scrolling = false;
        // The rail's own transient state: a half-shown note or a sliding
        // indicator must not survive a close.
        self.toast_len = 0;
        self.toast_until_ns = 0;
        self.tip.jump(0.0);
        self.bar.jump(self.barTarget());
        self.res.invalidateBody();
    }

    pub fn sizeTo(self: *Self, w: f64, h: f64) void {
        self.geo = layout.Geo.of(w, h);
        self.rgeo = layout.RailGeo.of(w, h);
        self.relayoutOffsets();
        self.clampScroll();
        // A resize is not a category switch: the indicator teleports to its
        // button rather than sliding across the new geometry.
        self.bar.jump(self.barTarget());
        self.res.invalidateBody();
    }

    pub fn setColors(self: *Self, c: chrome.Chrome) void {
        self.colors = c;
    }

    /// Grid or one-row-per-app list, from `appearance.launchpad_view_mode`.
    /// The body cache keys on the mode, so the first paint after a flip
    /// rebuilds it; the scroll clamps to the new (much taller) extent.
    pub fn setListMode(self: *Self, on: bool) void {
        if (self.list_mode == on) return;
        self.list_mode = on;
        self.clampScroll();
        self.bump();
    }

    /// Point the model at one of the two panels. The rail is list-only, so
    /// the style owns that bit; the category and the scroll mean the same
    /// thing in both and survive the switch untouched.
    pub fn setStyle(self: *Self, s: Style) void {
        if (self.style == s) return;
        self.style = s;
        if (s == .rail) self.list_mode = true;
        self.clampScroll();
        self.bar.jump(self.barTarget());
        self.tip.jump(0.0);
        self.res.invalidateBody();
        self.bump();
    }

    /// The panel's natural size — what the host asks the compositor for and
    /// then hands back through `sizeTo`.
    pub fn preferredSize(self: *const Self) struct { w: f64, h: f64 } {
        return if (self.style == .rail)
            .{ .w = layout.rail_w, .h = layout.rail_h }
        else
            .{ .w = layout.preferred_w, .h = layout.preferred_h };
    }

    /// The nightlight state the footer toggle paints. The host re-reads it
    /// from the config after every reload; the menu never writes it.
    pub fn setNight(self: *Self, on: bool) void {
        self.night_on = on;
    }

    pub fn view(self: *Self) paint.View {
        return .{
            .geo = self.geo,
            .colors = self.colors,
            .res = &self.res,
            .style = self.style,
            .rgeo = self.rgeo,
            .bar_y = self.bar.value,
            .tip_a = self.tip.value,
            .toast = self.toast[0..self.toast_len],
            .query = self.query.items,
            .entries = self.catalog.entries,
            .hits = self.hits.items,
            .gen = self.gen,
            .sel = self.sel,
            .hover_row = self.hover_row,
            .hover_pill = self.hover_pill,
            .sel_pill = self.sel_pill,
            .hover_power = self.hover_power,
            .pill_w = self.pill_w,
            .buckets = self.buckets,
            .total = self.total,
            .focused = self.focused,
            .caret_on = self.caret_on,
            .scroll = self.current,
            .list_mode = self.list_mode,
            .night_on = self.night_on,
            .confirm = self.confirm,
            .ctx_row = self.ctx_row,
            .ctx_ax = self.ctx_ax,
            .ctx_ay = self.ctx_ay,
            .ctx_hover = self.ctx_hover,
            .ctx_pinned = self.ctx_pinned,
        };
    }

    pub fn hitEntry(self: *Self, hit: i32) ?*const cat.Entry {
        if (hit < 0 or hit >= @as(i32, @intCast(self.hits.items.len))) return null;
        return &self.catalog.entries[self.hits.items[@intCast(hit)]];
    }

    // -----------------------------------------------------------------
    // The list
    // -----------------------------------------------------------------

    pub fn refresh(self: *Self) void {
        var pat_buf: [max_pattern]u8 = undefined;
        const raw = std.mem.trim(u8, self.query.items, " \t");
        const pat = foldInto(&pat_buf, raw);

        self.ranked.clearRetainingCapacity();
        for (self.catalog.entries, 0..) |*e, i| {
            if (self.sel_pill > 0 and @as(i32, @intCast(@intFromEnum(e.bucket))) + 1 != self.sel_pill) continue;
            const sc = cat.score(pat, e);
            if (sc == 0) continue;
            self.ranked.append(self.gpa, .{ .idx = i, .sc = sc }) catch continue;
        }
        std.mem.sort(Ranked, self.ranked.items, {}, rankBefore);

        self.hits.clearRetainingCapacity();
        for (self.ranked.items) |r| self.hits.append(self.gpa, r.idx) catch {};

        if (self.sel >= @as(i32, @intCast(self.hits.items.len))) self.sel = -1;
        // The rail's "one highlight always": an open with no pointer history
        // still lights the first result, which is also what Enter starts.
        // The reference panel keeps its "nothing highlighted until you ask"
        // behaviour, so this is behind the style.
        if (self.style == .rail and self.sel < 0 and self.hits.items.len > 0) self.sel = 0;
        self.clampScroll();
        self.gen += 1;
    }

    /// Warm the icons the current hits need, off the keystroke path. Called
    /// from the host's tick, which stays alive while the menu is up; a tick
    /// that landed at least one icon retires the cached body so the next
    /// frame draws it. `budget_ms` bounds one tick's work.
    pub fn prefetchIcons(self: *Self, budget_ms: u64) bool {
        if (!self.res.icons.prefetch(budget_ms, self.hits.items, self.catalog.entries)) return false;
        self.bump();
        return true;
    }

    /// Pick a category pill (or rail button — the same eight slots) and
    /// re-rank under it. On the rail the highlight lands on the first result
    /// and the indicator slides to the new button; the reference panel drops
    /// the highlight and lets Enter take the first app anyway.
    pub fn pickPill(self: *Self, i: i32) bool {
        // "All" is spelled -1 by the callers that walk the ring (Alt+1, the
        // category arrows) and 0 by the ones that number the buttons; both
        // name the same slot.
        const want: i32 = if (i < 0) 0 else i;
        if (want >= @as(i32, @intCast(layout.pill_count)) or want == self.sel_pill) return false;
        self.sel_pill = want;
        self.sel = if (self.style == .rail) 0 else -1;
        self.refresh();
        if (self.style == .rail) self.bar.begin(self.barTarget(), anim.monotonicNs(), bar_ns);
        return true;
    }

    /// Where the category indicator wants to be for the current category.
    fn barTarget(self: *const Self) f64 {
        const i: usize = if (self.sel_pill < 0) 0 else @intCast(self.sel_pill);
        return self.rgeo.barY(@min(i, layout.strip_cat_count - 1));
    }

    /// Put a note in the footer for the design's 1.4 s. `tick` retires it and
    /// `reset` clears it, so a note can never outlive the open it belongs to.
    pub fn note(self: *Self, text: []const u8) void {
        var end = @min(text.len, self.toast.len);
        // Cut on a rune boundary so the note is always valid UTF-8.
        if (end < text.len) {
            while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
        }
        @memcpy(self.toast[0..end], text[0..end]);
        self.toast_len = end;
        self.toast_until_ns = anim.monotonicNs() + toast_ns;
    }

    fn layoutPills(self: *Self) void {
        const cr = measure.measureCr() orelse return;
        var buf: [64]u8 = undefined;
        var l = paint.makeLayout(cr, paint.fontDesc(&buf, "", pill_label_px));
        defer l.destroy();
        for (0..layout.pill_count) |i| {
            const lbl: []const u8 = if (i == 0) "All" else cat.bucket_labels[i - 1];
            const count = if (i == 0) self.total else self.buckets[i - 1];
            var cbuf: [16]u8 = undefined;
            const ctext = std.fmt.bufPrint(&cbuf, "{d}", .{count}) catch "0";
            l.setText(lbl);
            const lw = paint.runWidth(&l);
            l.setText(ctext);
            const cw = paint.runWidth(&l);
            self.pill_w[i] = lw + pill_gap_text + cw + layout.pill_pad_x * 2.0;
        }
        self.relayoutOffsets();
    }

    fn relayoutOffsets(self: *Self) void {
        layout.pillOffsets(&self.pill_x, &self.pill_w, self.geo.body.w, self.sel_pill);
    }

    // -----------------------------------------------------------------
    // Pointer
    // -----------------------------------------------------------------

    /// Follow the pointer. Returns true when what would be painted changed,
    /// because pointer motion outruns the frame rate by a wide margin.
    pub fn hoverAt(self: *Self, sx: f64, sy: f64) bool {
        // The surface is `fit` smaller than `geo`; convert the pointer into
        // the natural space the layout is authored in.
        const lx = sx / self.fit;
        const ly = sy / self.fit;
        // The confirmation card owns the panel while it is up, and nothing
        // about it depends on the pointer. Saying "nothing changed" here is
        // not a shortcut — it is what keeps a pointer sweeping over the card
        // from redrawing the whole panel per motion event.
        if (self.confirm >= 0) return false;
        const g = self.geo;
        // The menu owns the pointer while it is up: the rows behind it stop
        // lighting, which is also what keeps an open menu from retiring the
        // cached body every time the pointer crosses the list underneath.
        if (self.ctx_row >= 0) {
            const r = layout.ctxRect(g, self.ctx_ax, self.ctx_ay);
            return setIf(&self.ctx_hover, layout.ctxPick(r, lx, ly));
        }
        if (self.style == .rail) return self.hoverRail(lx, ly);
        const zone = layout.zoneAt(g, lx, ly);
        var changed = false;

        var pill: i32 = -1;
        if (zone == .pill) {
            if (layout.pillIndexAt(g, &self.pill_x, &self.pill_w, lx, ly)) |p| pill = p;
        }
        changed = setIf(&self.hover_pill, pill) or changed;

        var power: i32 = -1;
        if (zone == .power) {
            if (layout.powerIndexAt(g, lx, ly)) |p| power = @intCast(p);
        }
        changed = setIf(&self.hover_power, power) or changed;

        var row: i32 = -1;
        if (zone == .row) {
            if (self.indexAt(lx, ly)) |r| row = r;
        }
        if (setIf(&self.hover_row, row)) {
            self.bump();
            changed = true;
        }
        return changed;
    }

    /// The rail's pointer tracking. The mockup moves the highlight with the
    /// mouse, so hovering a row *is* selecting it — the two never disagree,
    /// and the highlight stays where it was left when the pointer leaves the
    /// panel. Rail buttons light without moving the selection.
    fn hoverRail(self: *Self, lx: f64, ly: f64) bool {
        var changed = false;

        var cat_hov: i32 = -1;
        if (layout.railCatAt(self.rgeo, lx, ly)) |i| cat_hov = @intCast(i);
        changed = setIf(&self.hover_pill, cat_hov) or changed;

        var sess: i32 = -1;
        if (layout.railSessAt(self.rgeo, lx, ly)) |i| sess = @intCast(i);
        changed = setIf(&self.hover_power, sess) or changed;

        // One tooltip serves whichever button is lit; moving between two of
        // them retargets the same fade instead of flashing it off and on.
        const want: f64 = if (cat_hov >= 0 or sess >= 0) 1.0 else 0.0;
        if (self.tip.to != want or (!self.tip.running and self.tip.value != want)) {
            self.tip.begin(want, anim.monotonicNs(), tip_ns);
            changed = true;
        }

        const was = self.sel;
        if (layout.railRowIndexAt(self.rgeo, lx, ly, self.current, self.hits.items.len)) |row| {
            self.setSel(@intCast(row));
        }
        return changed or self.sel != was;
    }

    /// The row highlights are drawn into the cached body rather than over it,
    /// so anything that moves the lit row has to retire that cache. Only a
    /// change of *row* does — motion inside one cell costs nothing, which is
    /// what keeps a pointer sweeping across the grid from redrawing the whole
    /// list per event.
    fn bump(self: *Self) void {
        self.gen += 1;
    }

    fn setSel(self: *Self, v: i32) void {
        if (self.sel == v) return;
        self.sel = v;
        self.bump();
    }

    pub fn clearHover(self: *Self) bool {
        var changed = false;
        changed = setIf(&self.hover_row, -1) or changed;
        changed = setIf(&self.hover_pill, -1) or changed;
        changed = setIf(&self.hover_power, -1) or changed;
        changed = setIf(&self.ctx_hover, -1) or changed;
        return changed;
    }

    /// The hit index under a point in *card* coordinates, or null in the gap
    /// between grid cells and in the padding below the last row.
    pub fn indexAt(self: *Self, sx: f64, sy: f64) ?i32 {
        const lx = sx / self.fit;
        const ly = sy / self.fit;
        const n = self.hits.items.len;
        const idx = if (self.list_mode)
            layout.rowIndexAt(self.geo, lx, ly, self.current, n)
        else
            layout.cellIndexAt(self.geo, lx, ly, self.current, n);
        return if (idx) |i| @intCast(i) else null;
    }

    /// What a press that reached the panel was. Only the two buttons the rest
    /// of the shell dispatches are answered; anything else is dropped, the way
    /// the reference panel drops a middle click.
    pub const Press = struct {
        /// 1 = left, 2 = middle, 3 = right, as the dock reads them.
        btn: u8,
        /// Whether the row under the pointer is already in the dock's pin
        /// list. The model never reads the dock's config, so the panel
        /// answers this with the press itself.
        pinned: bool = false,
    };

    pub fn click(self: *Self, sx: f64, sy: f64, press: Press) Decision {
        const lx = sx / self.fit;
        const ly = sy / self.fit;
        const g = self.geo;
        if (self.confirm >= 0) {
            return switch (layout.modalHit(g, lx, ly)) {
                .confirm => blk: {
                    const idx = self.confirm;
                    self.confirm = -1;
                    break :blk .{ .op = .run_power, .hit = idx };
                },
                // Cancel, and any click on the scrim behind the card.
                else => blk: {
                    self.confirm = -1;
                    break :blk Decision{};
                },
            };
        }
        if (self.style == .rail) return self.clickRail(lx, ly, press);
        if (press.btn == 3) {
            // A right press on a row asks for that row's menu, and asks again
            // from the new place if one is already up. Elsewhere it is dropped
            // and leaves the menu alone, so a menu outlives a right press in
            // the gap beside the list.
            if (layout.zoneAt(g, lx, ly) != .row) return .{};
            const row = self.indexAt(lx, ly) orelse return .{};
            self.ctx_row = row;
            self.ctx_ax = lx;
            self.ctx_ay = ly;
            self.ctx_hover = -1;
            self.ctx_pinned = press.pinned;
            return .{ .op = .repaint };
        }
        if (press.btn != 1) return .{};

        if (self.ctx_row >= 0) {
            const r = layout.ctxRect(g, self.ctx_ax, self.ctx_ay);
            if (layout.ctxPick(r, lx, ly) >= 0) {
                const row = self.ctx_row;
                self.ctx_row = -1;
                self.ctx_hover = -1;
                return .{ .op = .ctx_pin, .hit = row };
            }
            // Missing the menu only closes it, and the press then falls
            // through to the panel underneath: a click that dismisses a menu
            // still does whatever that click would have done anyway.
            self.ctx_row = -1;
            self.ctx_hover = -1;
        }
        switch (layout.zoneAt(g, lx, ly)) {
            .search => {
                self.focused = true;
                return .{ .op = .focus_field };
            },
            .pill => {
                const i = layout.pillIndexAt(g, &self.pill_x, &self.pill_w, lx, ly) orelse return .{};
                return if (self.pickPill(i)) .{ .op = .repaint } else .{};
            },
            .row => {
                const i = self.indexAt(lx, ly) orelse return .{};
                self.setSel(i);
                return .{ .op = .launch, .hit = i };
            },
            .power => {
                const i: i32 = @intCast(layout.powerIndexAt(g, lx, ly) orelse return .{});
                // Locking is not worth a modal; the three session actions
                // are; the nightlight toggle just flips.
                if (i == 0) return .{ .op = .run_power, .hit = i };
                if (i == layout.nightlight_idx) return .{ .op = .toggle_night, .hit = i };
                self.confirm = i;
                return .{ .op = .ask_power, .hit = i };
            },
            // Clicking the panel around the list keeps it open, the way the
            // rest of the shell's popups that hold state behave.
            .none => return .{},
        }
    }

    /// The rail's press routing: the strip buttons, then the search field,
    /// then the list. The row menu survives from the reference panel; the
    /// footer's Enter hint is a hint, not a button.
    fn clickRail(self: *Self, lx: f64, ly: f64, press: Press) Decision {
        const g = self.rgeo;
        if (press.btn == 3) {
            // A right press on a row asks for that row's menu. Elsewhere it
            // is dropped and leaves a menu already up alone.
            const row = layout.railRowIndexAt(g, lx, ly, self.current, self.hits.items.len) orelse return .{};
            self.ctx_row = @intCast(row);
            self.ctx_ax = lx;
            self.ctx_ay = ly;
            self.ctx_hover = -1;
            self.ctx_pinned = press.pinned;
            return .{ .op = .repaint };
        }
        if (press.btn != 1) return .{};

        if (self.ctx_row >= 0) {
            const r = layout.ctxRect(self.geo, self.ctx_ax, self.ctx_ay);
            if (layout.ctxPick(r, lx, ly) >= 0) {
                const row = self.ctx_row;
                self.ctx_row = -1;
                self.ctx_hover = -1;
                return .{ .op = .ctx_pin, .hit = row };
            }
            // Missing the menu only closes it; the press falls through to
            // the panel underneath, exactly as it does on the classic panel.
            self.ctx_row = -1;
            self.ctx_hover = -1;
        }
        if (layout.railCatAt(g, lx, ly)) |i| {
            _ = self.pickPill(@intCast(i));
            return .{ .op = .repaint };
        }
        if (layout.railSessAt(g, lx, ly)) |i| return self.sessionAction(i);
        if (g.search.contains(lx, ly)) {
            self.focused = true;
            return .{ .op = .focus_field };
        }
        if (layout.railRowIndexAt(g, lx, ly, self.current, self.hits.items.len)) |row| {
            const hit: i32 = @intCast(row);
            self.setSel(hit);
            return .{ .op = .launch, .hit = hit };
        }
        // The rail strip's gaps, the section header, the footer: a press
        // there keeps the panel open.
        return .{};
    }

    /// The rail's bottom group, in `strip_sess` order: lock, log out, reload,
    /// power, theme. The two that end the session confirm the way the
    /// reference panel's footer does; the two that stay in the panel leave
    /// the note to the host, which knows what actually happened.
    fn sessionAction(self: *Self, i: usize) Decision {
        return switch (i) {
            0 => .{ .op = .run_power, .hit = 0 },
            1 => blk: {
                self.confirm = 1;
                break :blk .{ .op = .ask_power, .hit = 1 };
            },
            2 => .{ .op = .reload_shell },
            3 => blk: {
                self.confirm = 3;
                break :blk .{ .op = .ask_power, .hit = 3 };
            },
            4 => .{ .op = .toggle_theme },
            else => .{},
        };
    }

    /// The scroll wheel. `delta_px` is already in panel pixels, positive
    /// downwards, so scrolling down means a larger offset. Panel pixels are
    /// `fit` smaller than the natural space `target` lives in, so the delta
    /// is converted the same way a pointer coordinate is.
    pub fn axis(self: *Self, delta_px: f64) bool {
        const d = delta_px / self.fit;
        if (d == 0.0) return false;
        self.target += d;
        self.clampScroll();
        return true;
    }

    // -----------------------------------------------------------------
    // Keyboard
    // -----------------------------------------------------------------

    pub fn key(self: *Self, ev: *const seat_mod.KeyEvent) Decision {
        const xkb = seat_mod.xkb;
        if (ev.state != 1) return .{};

        if (self.confirm >= 0) {
            return switch (ev.sym) {
                xkb.XKB_KEY_Escape => blk: {
                    self.confirm = -1;
                    break :blk .{ .op = .repaint };
                },
                xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => blk: {
                    const idx = self.confirm;
                    self.confirm = -1;
                    break :blk .{ .op = .run_power, .hit = idx };
                },
                else => .{},
            };
        }

        if (self.style == .rail) return self.keyRail(ev);

        switch (ev.sym) {
            xkb.XKB_KEY_Escape => return .{ .op = .close },
            xkb.XKB_KEY_BackSpace => {
                if (!self.focused) return .{};
                self.popRune();
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                if (self.sel >= 0) return .{ .op = .launch, .hit = self.sel };
                if (self.hits.items.len > 0) {
                    self.setSel(0);
                    return .{ .op = .launch, .hit = 0 };
                }
                return .{};
            },
            xkb.XKB_KEY_Up => {
                const step: i32 = if (self.list_mode) 1 else @intCast(layout.cols);
                if (!self.focused and (self.sel < 0 or self.sel < step)) {
                    self.focused = true;
                    return .{ .op = .focus_field };
                }
                self.moveVert(-1);
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_Down => {
                if (self.focused) {
                    self.focused = false;
                    if (self.sel < 0 and self.hits.items.len > 0) self.setSel(0);
                    self.ensureSelVisible();
                    return .{ .op = .repaint };
                }
                self.moveVert(1);
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_Left => {
                self.moveHoriz(-1);
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_Right => {
                self.moveHoriz(1);
                return .{ .op = .repaint };
            },
            else => {
                if (!self.focused or ev.utf8_len == 0) return .{};
                const ch = ev.utf8[0..ev.utf8_len];
                if (ch[0] < 0x20 or ch[0] == 0x7f) return .{};
                self.query.appendSlice(self.gpa, ch) catch return .{};
                self.sel = -1;
                self.refresh();
                return .{ .op = .repaint };
            },
        }
    }

    /// The rail's keys. Modifier combinations are answered first, so a chord
    /// is never read as a printable character; the rest is the mockup's list
    /// of behaviours: the arrows wrap, Escape clears before it closes, and
    /// typing anywhere in the panel finds the search field.
    fn keyRail(self: *Self, ev: *const seat_mod.KeyEvent) Decision {
        const xkb = seat_mod.xkb;
        if (ev.alt) {
            switch (ev.sym) {
                xkb.XKB_KEY_Left => return self.stepCat(-1),
                xkb.XKB_KEY_Right => return self.stepCat(1),
                xkb.XKB_KEY_1,
                xkb.XKB_KEY_2,
                xkb.XKB_KEY_3,
                xkb.XKB_KEY_4,
                xkb.XKB_KEY_5,
                xkb.XKB_KEY_6,
                xkb.XKB_KEY_7,
                xkb.XKB_KEY_8,
                => {
                    const i: i32 = @intCast(ev.sym - @as(u32, @intCast(xkb.XKB_KEY_1)));
                    _ = self.pickPill(if (i == 0) -1 else i);
                    return .{ .op = .repaint };
                },
                xkb.XKB_KEY_l => return self.sessionAction(0),
                xkb.XKB_KEY_o => return self.sessionAction(1),
                xkb.XKB_KEY_r => return self.sessionAction(2),
                xkb.XKB_KEY_p => return self.sessionAction(3),
                else => return .{},
            }
        }
        if (ev.ctrl) {
            switch (ev.sym) {
                xkb.XKB_KEY_n => {
                    self.moveVertRail(1);
                    return .{ .op = .repaint };
                },
                xkb.XKB_KEY_p => {
                    self.moveVertRail(-1);
                    return .{ .op = .repaint };
                },
                xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => return self.launchRail(true),
                else => return .{},
            }
        }
        switch (ev.sym) {
            xkb.XKB_KEY_Escape => {
                // First press clears a search and takes the field back; the
                // second closes the panel.
                if (self.query.items.len == 0) return .{ .op = .close };
                self.query.clearRetainingCapacity();
                self.sel = 0;
                self.focused = true;
                self.refresh();
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_BackSpace => {
                if (!self.focused) return .{};
                self.popRune();
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => return self.launchRail(false),
            xkb.XKB_KEY_Down => {
                self.moveVertRail(1);
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_Up => {
                self.moveVertRail(-1);
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_Page_Down => {
                const step: i32 = @intCast(self.rgeo.pageRows());
                self.movePageRail(step);
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_Page_Up => {
                const step: i32 = -@as(i32, @intCast(self.rgeo.pageRows()));
                self.movePageRail(step);
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_Home => {
                self.jumpSel(false);
                return .{ .op = .repaint };
            },
            xkb.XKB_KEY_End => {
                self.jumpSel(true);
                return .{ .op = .repaint };
            },
            else => {
                if (ev.meta or ev.utf8_len == 0) return .{};
                const ch = ev.utf8[0..ev.utf8_len];
                if (ch[0] < 0x20 or ch[0] == 0x7f) return .{};
                // Typing anywhere in the panel starts a search: the field
                // follows the keystroke whether or not it held the focus.
                self.focused = true;
                self.query.appendSlice(self.gpa, ch) catch return .{};
                self.sel = 0;
                self.refresh();
                return .{ .op = .repaint };
            },
        }
    }

    /// The rail's vertical moves wrap in both directions: while there are
    /// results the highlight always exists, so there is no edge to stop at.
    fn moveVertRail(self: *Self, dir: i32) void {
        const n: i32 = @intCast(self.hits.items.len);
        if (n == 0) return;
        const next = if (self.sel < 0)
            (if (dir < 0) n - 1 else 0)
        else
            @mod(self.sel + dir, n);
        self.stepSel(next);
    }

    /// A page move clamps at the ends: wrapping by a page reads as a jump to
    /// the other end, which is never what paging is for.
    fn movePageRail(self: *Self, dir: i32) void {
        const n: i32 = @intCast(self.hits.items.len);
        if (n == 0) return;
        const next = if (self.sel < 0)
            (if (dir < 0) n - 1 else 0)
        else
            std.math.clamp(self.sel + dir, 0, n - 1);
        self.stepSel(next);
    }

    fn jumpSel(self: *Self, end: bool) void {
        const n: i32 = @intCast(self.hits.items.len);
        if (n == 0) return;
        self.stepSel(if (end) n - 1 else 0);
    }

    /// A keyboard move takes the highlight out of the field, the way the
    /// mockup's ArrowDown does, and keeps it on screen.
    fn stepSel(self: *Self, next: i32) void {
        self.focused = false;
        self.setSel(next);
        self.ensureSelVisible();
    }

    /// Alt+Left / Alt+Right walk the rail's categories and wrap.
    fn stepCat(self: *Self, dir: i32) Decision {
        const n: i32 = @intCast(layout.strip_cat_count);
        const cur: i32 = if (self.sel_pill < 0) 0 else self.sel_pill;
        const next = @mod(cur + dir, n);
        _ = self.pickPill(if (next == 0) -1 else next);
        return .{ .op = .repaint };
    }

    /// Enter, or a press on a row: start the highlighted app, or the first
    /// result when nothing is highlighted. `keep` leaves the panel up and
    /// writes the mockup's "Opening …" note into the footer.
    fn launchRail(self: *Self, keep: bool) Decision {
        var hit = self.sel;
        if (hit < 0) {
            if (self.hits.items.len == 0) return .{};
            hit = 0;
            self.setSel(0);
        }
        if (keep) {
            if (self.hitEntry(hit)) |e| {
                var buf: [160]u8 = undefined;
                const name = layout.truncRunes(e.name, 120);
                const text = std.fmt.bufPrint(&buf, "Opening {s}", .{name}) catch "Opening";
                self.note(text);
            }
            return .{ .op = .launch_keep, .hit = hit };
        }
        return .{ .op = .launch, .hit = hit };
    }

    fn moveVert(self: *Self, dir: i32) void {
        const n: i32 = @intCast(self.hits.items.len);
        if (n == 0) return;
        const step: i32 = if (self.list_mode) 1 else @intCast(layout.cols);
        const next = if (self.sel < 0)
            (if (dir < 0) n - 1 else 0)
        else
            std.math.clamp(self.sel + dir * step, 0, n - 1);
        self.setSel(next);
        self.ensureSelVisible();
    }

    fn moveHoriz(self: *Self, dir: i32) void {
        if (self.list_mode) return;
        const n: i32 = @intCast(self.hits.items.len);
        if (n == 0) return;
        const next = if (self.sel < 0)
            (if (dir < 0) n - 1 else 0)
        else
            std.math.clamp(self.sel + dir, 0, n - 1);
        self.setSel(next);
        self.ensureSelVisible();
    }

    fn popRune(self: *Self) void {
        const q = self.query.items;
        if (q.len == 0) return;
        var end = q.len - 1;
        while (end > 0 and (q[end] & 0xC0) == 0x80) end -= 1;
        self.query.shrinkRetainingCapacity(end);
        self.sel = -1;
        self.refresh();
    }

    // -----------------------------------------------------------------
    // Scrolling
    // -----------------------------------------------------------------

    fn clampScroll(self: *Self) void {
        const max = if (self.style == .rail)
            self.rgeo.maxScroll(self.hits.items.len)
        else
            self.geo.maxScroll(self.hits.items.len, self.list_mode);
        self.target = std.math.clamp(self.target, 0.0, max);
    }

    /// Keep the selection inside the visible band by moving the scroll rather
    /// than by scrolling the *content*: the target is what animates, so the
    /// list glides to it instead of jumping a whole page.
    fn ensureSelVisible(self: *Self) void {
        if (self.sel < 0) return;
        var top: f64 = 0;
        var h: f64 = 0;
        var band: f64 = self.geo.body.h;
        if (self.style == .rail) {
            top = @as(f64, @floatFromInt(self.sel)) * layout.rail_row_h;
            h = layout.rail_row_h;
            band = self.rgeo.body.h;
        } else if (self.list_mode) {
            top = @as(f64, @floatFromInt(self.sel)) * layout.row_h;
            h = layout.row_h;
        } else {
            const row = @divTrunc(@as(usize, @intCast(self.sel)), layout.cols);
            top = @as(f64, @floatFromInt(row)) * (layout.cell_h + layout.grid_gap);
            h = layout.cell_h;
        }
        // The reference is the destination, not the position in flight: two
        // moves pressed before a frame lands (End then Home) have to leave
        // the scroll aimed at the second one, not stuck on the first.
        if (top < self.target) {
            self.target = top;
        } else if (top + h > self.target + band) {
            self.target = top + h - band;
        }
        self.clampScroll();
    }

    /// Advance the caret blink and the scroll's approach. Returns true when
    /// the next frame would differ, which is the dock's whole reason to draw
    /// one: nothing else about this menu changes on its own.
    pub fn tick(self: *Self) bool {
        const now = anim.monotonicNs();
        var changed = false;

        if (self.current != self.target) {
            if (!self.scrolling) {
                self.scrolling = true;
                self.scroll_from = self.current;
                self.scroll_ns = now;
            }
            const elapsed = now -| self.scroll_ns;
            const f = 1.0 - @exp(-@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(scroll_tau_ns)));
            self.current = self.scroll_from + (self.target - self.scroll_from) * f;
            if (@abs(self.target - self.current) < scroll_epsilon or elapsed > scroll_settle_ns) {
                self.current = self.target;
                self.scrolling = false;
            }
            changed = true;
        } else {
            self.scrolling = false;
        }

        const want = self.focused and (@divTrunc(now, caret_period_ns) % 2 == 0);
        if (want != self.caret_on) {
            self.caret_on = want;
            changed = true;
        }

        // The rail's indicator slide and tooltip fade, and the footer note's
        // expiry. None of them runs unless the rail started it, which is why
        // a classic panel's tick still asks for nothing.
        if (self.bar.running) {
            _ = self.bar.step(now);
            changed = true;
        }
        if (self.tip.running) {
            _ = self.tip.step(now);
            changed = true;
        }
        if (self.toast_len > 0 and now >= self.toast_until_ns) {
            self.toast_len = 0;
            changed = true;
        }
        return changed;
    }

    // -----------------------------------------------------------------
    // Power
    // -----------------------------------------------------------------

    /// Ask the session manager to do what button `idx` stands for. The order
    /// inside each group is "the tool this desktop is most likely to have";
    /// the first one that spawns wins and the rest are not tried.
    pub fn runPower(io: std.Io, idx: i32) void {
        const lock = [_][]const []const u8{
            &[_][]const u8{ "loginctl", "lock-session" },
            &[_][]const u8{"hyprlock"},
            &[_][]const u8{"swaylock"},
        };
        const reboot = [_][]const []const u8{
            &[_][]const u8{ "systemctl", "reboot" },
            &[_][]const u8{ "shutdown", "-r", "now" },
        };
        const halt = [_][]const []const u8{
            &[_][]const u8{ "systemctl", "poweroff" },
            &[_][]const u8{ "shutdown", "-h", "now" },
        };
        switch (idx) {
            0 => firstOf(io, &lock),
            1 => logout(io),
            2 => firstOf(io, &reboot),
            3 => firstOf(io, &halt),
            else => {},
        }
    }
};

fn firstOf(io: std.Io, cands: []const []const []const u8) void {
    for (cands) |argv| {
        autostart.spawnDetached(io, argv) catch continue;
        return;
    }
}

/// Ending a session has no portable command — each compositor has its own
/// exit request — so the running one is sniffed from its own environment
/// variable and anything else falls back to asking the session manager to
/// terminate the login that owns the display.
fn logout(io: std.Io) void {
    if (env("HYPRLAND_INSTANCE_SIGNATURE") != null) {
        const hypr = [_][]const []const u8{&[_][]const u8{ "hyprctl", "dispatch", "exit" }};
        firstOf(io, &hypr);
        return;
    }
    if (env("NIRI_SOCKET") != null) {
        const niri = [_][]const []const u8{&[_][]const u8{ "niri", "msg", "action", "quit" }};
        firstOf(io, &niri);
        return;
    }
    if (env("SWAYSOCK") != null) {
        const sway = [_][]const []const u8{&[_][]const u8{ "swaymsg", "exit" }};
        firstOf(io, &sway);
        return;
    }
    const user = env("USER") orelse return;
    const fall = [_][]const []const u8{&[_][]const u8{ "loginctl", "terminate-user", user }};
    firstOf(io, &fall);
}

/// Pretend the scroll's easing began right at boot, so one tick lands on the
/// target. Tests ask for the settled state this way rather than waiting out
/// four time constants of real time.
fn settleNow(m: *Menu) void {
    m.scrolling = m.current != m.target;
    m.scroll_from = m.current;
    m.scroll_ns = 0;
}

fn foldInto(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

test "launcher-menu: an empty catalog answers every request without crashing" {
    const t = std.testing;
    var m = Menu.init(t.allocator, undefined);
    defer m.deinit();

    // No scan, no compositor, no icon path — the model has to stay usable
    // with nothing in it, because that is the state a machine with no
    // applications installed is in.
    m.sizeTo(layout.preferred_w, layout.preferred_h);
    m.refresh();
    try t.expectEqual(@as(i32, -1), m.sel);
    try t.expectEqual(@as(usize, 0), m.hits.items.len);
    try t.expect(m.hitEntry(0) == null);

    // Arrow keys on an empty list move nothing and ask for nothing.
    var down = seat_mod.KeyEvent{ .state = 1, .sym = seat_mod.xkb.XKB_KEY_Down };
    try t.expect(m.key(&down).op == .repaint);
    var enter = seat_mod.KeyEvent{ .state = 1, .sym = seat_mod.xkb.XKB_KEY_Return };
    try t.expect(m.key(&enter).op == .none);
    var esc = seat_mod.KeyEvent{ .state = 1, .sym = seat_mod.xkb.XKB_KEY_Escape };
    try t.expect(m.key(&esc).op == .close);

    // A key release is not a keystroke.
    var up_release = seat_mod.KeyEvent{ .state = 0, .sym = seat_mod.xkb.XKB_KEY_Down };
    try t.expect(m.key(&up_release).op == .none);
}

test "launcher-menu: pills filter, the escape hatch is the search box, and the modal owns the panel" {
    const t = std.testing;
    var m = Menu.init(t.allocator, undefined);
    defer m.deinit();

    // Three entries in the catalog, standing in for a real scan.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_]struct { name: []const u8, bucket: cat.Bucket }{
        .{ .name = "Alpha Editor", .bucket = .productivity },
        .{ .name = "Beta Player", .bucket = .media },
        .{ .name = "Gamma Tool", .bucket = .other },
    };
    var entries: [names.len]cat.Entry = undefined;
    var fold_buf: [64]u8 = undefined;
    for (names, 0..) |n, i| {
        entries[i] = .{
            .name = try a.dupe(u8, n.name),
            .fold = try a.dupe(u8, std.ascii.lowerString(&fold_buf, n.name)),
            .bucket = n.bucket,
        };
    }
    m.catalog.entries = &entries;
    m.total = 3;
    m.buckets[@intFromEnum(cat.Bucket.productivity)] = 1;
    m.buckets[@intFromEnum(cat.Bucket.media)] = 1;
    m.refresh();

    try t.expectEqual(@as(usize, 3), m.hits.items.len);

    // A word from the middle of a name narrows the list to one entry.
    try m.query.appendSlice(t.allocator, "player");
    m.refresh();
    try t.expectEqual(@as(usize, 1), m.hits.items.len);
    try t.expectEqualStrings("Beta Player", m.catalog.entries[m.hits.items[0]].name);
    m.query.clearRetainingCapacity();
    m.refresh();

    // Choosing a category narrows without touching the query.
    try t.expect(m.pickPill(@intFromEnum(cat.Bucket.media) + 1));
    try t.expectEqual(@as(usize, 1), m.hits.items.len);
    try t.expect(m.pickPill(0));
    try t.expectEqual(@as(usize, 3), m.hits.items.len);
    try t.expect(!m.pickPill(0));

    // A grid cell is a launch; the power strip opens the confirmation card,
    // and once it is up the list behind it is unreachable.
    const g = m.geo;
    try t.expectEqual(Op.launch, m.click(g.body.x + 4, g.body.y + 4, .{ .btn = 1 }).op);
    const ask = m.click(g.power[2].x + 4, g.power[2].y + 4, .{ .btn = 1 });
    try t.expectEqual(Op.ask_power, ask.op);
    try t.expectEqual(@as(i32, 2), ask.hit);
    try t.expectEqual(@as(i32, 2), m.confirm);
    // The card owns the panel now: the list under it does not light up, and
    // neither does anything else, so no motion is worth a frame.
    try t.expect(!m.hoverAt(g.body.x + 4, g.body.y + 4));
    try t.expectEqual(@as(i32, -1), m.hover_row);

    // Confirming hands the button back to the caller and clears the card.
    const modal = layout.modalOf(g);
    const go = m.click(modal.confirm.x + 4, modal.confirm.y + 4, .{ .btn = 1 });
    try t.expectEqual(Op.run_power, go.op);
    try t.expectEqual(@as(i32, 2), go.hit);
    try t.expectEqual(@as(i32, -1), m.confirm);

    // The lock button fires straight away.
    try t.expectEqual(Op.run_power, m.click(g.power[0].x + 4, g.power[0].y + 4, .{ .btn = 1 }).op);
    // The nightlight toggle (last, past the separator) flips without a
    // modal and without touching the confirmation card.
    const night = m.click(g.power[layout.nightlight_idx].x + 4, g.power[layout.nightlight_idx].y + 4, .{ .btn = 1 });
    try t.expectEqual(Op.toggle_night, night.op);
    try t.expectEqual(@as(i32, layout.nightlight_idx), night.hit);
    try t.expectEqual(@as(i32, -1), m.confirm);
    // List mode and the night state ride the view straight to the paint.
    m.setListMode(true);
    try t.expect(m.view().list_mode);
    m.setNight(true);
    try t.expect(m.view().night_on);
    m.setListMode(false);
    m.setNight(false);
    try t.expect(!m.view().list_mode);
    try t.expect(!m.view().night_on);
    // Clicking the panel around the list keeps the menu open.
    try t.expectEqual(Op.none, m.click(4.0, 400.0, .{ .btn = 1 }).op);

    // Hovering follows the pointer and only reports real change.
    try t.expect(m.hoverAt(g.body.x + 4, g.body.y + 4));
    try t.expectEqual(@as(i32, 0), m.hover_row);
    try t.expect(!m.hoverAt(g.body.x + 4, g.body.y + 4));
    try t.expect(m.clearHover());

    // A right press on a row asks for that row's menu, and the press carries
    // the answer to whether the row is already pinned.
    const rx = g.body.x + 4;
    const ry = g.body.y + 4;
    try t.expectEqual(Op.repaint, m.click(rx, ry, .{ .btn = 3, .pinned = true }).op);
    try t.expectEqual(@as(i32, 0), m.ctx_row);
    try t.expect(m.ctx_pinned);

    const mr = layout.ctxRect(g, m.ctx_ax, m.ctx_ay);
    try t.expectEqual(@as(i32, 0), layout.ctxPick(mr, mr.x + 6, mr.y + layout.ctx_pad + 4));
    try t.expectEqual(@as(i32, -1), layout.ctxPick(mr, 0.0, 0.0));
    // The menu is kept inside the card whatever corner it was asked from.
    const edge = layout.ctxRect(g, g.w - 4.0, g.h - 4.0);
    try t.expect(edge.x + edge.w <= g.w - layout.margin);
    try t.expect(edge.y + edge.h <= g.h - layout.margin);

    // While it is up the menu is the only thing the pointer lights; the list
    // behind it does not highlight under an open menu.
    try t.expect(m.hoverAt(mr.x + 6, mr.y + layout.ctx_pad + 4));
    try t.expectEqual(@as(i32, 0), m.ctx_hover);
    try t.expect(!m.hoverAt(mr.x + 6, mr.y + layout.ctx_pad + 4));
    try t.expect(m.hoverAt(rx, ry));
    try t.expectEqual(@as(i32, -1), m.ctx_hover);
    try t.expectEqual(@as(i32, -1), m.hover_row);

    // A press in the menu's padding only closes it — and then falls through
    // to the list underneath, doing what a press there would have done.
    const miss = m.click(mr.x + 6, mr.y + 2.0, .{ .btn = 1 });
    try t.expectEqual(@as(i32, -1), m.ctx_row);
    try t.expectEqual(Op.launch, miss.op);

    // A press on the item hands the row back with the menu closed.
    try t.expectEqual(Op.repaint, m.click(rx, ry, .{ .btn = 3 }).op);
    try t.expect(!m.ctx_pinned);
    const took = m.click(mr.x + 6, mr.y + layout.ctx_pad + 4, .{ .btn = 1 });
    try t.expectEqual(Op.ctx_pin, took.op);
    try t.expectEqual(@as(i32, 0), took.hit);
    try t.expectEqual(@as(i32, -1), m.ctx_row);

    // A right press anywhere but a row asks for nothing at all.
    try t.expectEqual(Op.none, m.click(4.0, 400.0, .{ .btn = 3 }).op);
    try t.expectEqual(@as(i32, -1), m.ctx_row);

    // Opening the panel again starts without one.
    try t.expectEqual(Op.repaint, m.click(rx, ry, .{ .btn = 3 }).op);
    m.reset();
    try t.expectEqual(@as(i32, -1), m.ctx_row);
    try t.expectEqual(@as(i32, -1), m.ctx_hover);
}

test "launcher-menu: the scroll stays inside the content and eases toward its target" {
    const t = std.testing;
    var m = Menu.init(t.allocator, undefined);
    defer m.deinit();
    m.sizeTo(layout.preferred_w, layout.preferred_h);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: [30]cat.Entry = undefined;
    for (&entries, 0..) |*e, i| {
        const name = try std.fmt.allocPrint(a, "App {d:0>2}", .{i});
        e.* = .{ .name = name, .fold = try std.fmt.allocPrint(a, "app {d:0>2}", .{i}) };
    }
    m.catalog.entries = &entries;
    m.total = 30;
    m.refresh();

    // The 30-cell grid is five rows tall, of which about four fit.
    const max = m.geo.maxScroll(m.hits.items.len, false);
    try t.expect(max > 0);

    // A wheel nudge moves the target and leaves the view where it was.
    try t.expect(m.axis(120.0));
    try t.expect(m.target > 0);
    try t.expectEqual(@as(f64, 0.0), m.current);

    // The easing closes in on the target. Pretending the animation started
    // right at boot is how the test asks for the settled state instead of
    // waiting four time constants for it.
    settleNow(&m);
    try t.expect(m.tick());
    try t.expectApproxEqAbs(m.target, m.current, layout.grid_gap);

    // An absurd amount of wheel clamps rather than running away.
    try t.expect(m.axis(1.0e9));
    try t.expectApproxEqAbs(max, m.target, 1e-9);
    try t.expect(m.axis(-1.0e9));
    try t.expectApproxEqAbs(@as(f64, 0.0), m.target, 1e-9);
    settleNow(&m);
    _ = m.tick();

    // Selecting the last cell pulls the content up until that row is whole.
    m.focused = false;
    m.sel = 29;
    var down = seat_mod.KeyEvent{ .state = 1, .sym = seat_mod.xkb.XKB_KEY_Down };
    _ = m.key(&down);
    try t.expectEqual(@as(i32, 29), m.sel);
    const last_row_bottom = 4.0 * (layout.cell_h + layout.grid_gap) + layout.cell_h;
    try t.expect(m.target > 0);
    try t.expect(m.target + m.geo.body.h >= last_row_bottom);

    // With nothing left in flight, a tick asks for no frame at all.
    settleNow(&m);
    _ = m.tick();
    try t.expect(!m.tick());
}

/// A 4×4 red PNG for the icon-tick test below.
const menu_test_png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP47+DwHxkzkC4AAExPJ+HpZx/DAAAAAElFTkSuQmCC";

test "launcher-menu: the tick prefetcher retires the body cache only when an icon lands" {
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
    const icon_path = try std.fs.path.join(t.allocator, &.{ theme_dir, "eh-menu-warm.png" });
    defer t.allocator.free(icon_path);
    var png_buf: [256]u8 = undefined;
    const n = try std.base64.standard.Decoder.calcSizeForSlice(menu_test_png_b64);
    try std.base64.standard.Decoder.decode(png_buf[0..n], menu_test_png_b64);
    try cwd.writeFile(io, .{ .sub_path = icon_path, .data = png_buf[0..n] });

    var m = Menu.init(t.allocator, io);
    defer m.deinit();
    const dirs = try t.allocator.alloc([]const u8, 1);
    dirs[0] = try t.allocator.dupe(u8, root);
    m.res.icons.setPath(dirs, "hicolor");

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries = [_]cat.Entry{.{
        .name = try a.dupe(u8, "Warm Me"),
        .fold = try a.dupe(u8, "warm me"),
        .icon = try a.dupe(u8, "eh-menu-warm"),
    }};
    m.catalog.entries = &entries;
    m.total = 1;
    m.refresh();

    // The keystroke's frame never waits for the raster: the paint path marks
    // pending, and a tick whose budget is spent before resolving anything
    // changes no generation.
    try t.expect(m.res.icons.getCached("eh-menu-warm") == null);
    try t.expect(m.res.icons.pending);
    const gen_before = m.gen;
    try t.expect(!m.prefetchIcons(0));
    try t.expectEqual(gen_before, m.gen);

    // The tick that lands the pixels retires the cached body, so the next
    // frame draws the icon instead of the letter tile.
    const gen = m.gen;
    try t.expect(m.prefetchIcons(1000));
    try t.expect(m.gen > gen);

    // With every hit name known, another tick changes nothing — no repaint.
    const settled = m.gen;
    try t.expect(!m.prefetchIcons(1000));
    try t.expectEqual(settled, m.gen);
    try t.expect(m.res.icons.getCached("eh-menu-warm") != null);
}

// ---------------------------------------------------------------------------
// The rail panel
// ---------------------------------------------------------------------------

fn keyTap(sym: u32) seat_mod.KeyEvent {
    return .{ .state = 1, .sym = sym };
}

fn keyChord(sym: u32, ctrl: bool, alt: bool) seat_mod.KeyEvent {
    return .{ .state = 1, .sym = sym, .ctrl = ctrl, .alt = alt };
}

/// A printable keystroke: `sym` is the character's own keysym, which is what
/// an XKB map reports for the unshifted letters and digits.
fn keyChar(ch: u8) seat_mod.KeyEvent {
    var ev = seat_mod.KeyEvent{ .state = 1, .sym = ch };
    ev.utf8[0] = ch;
    ev.utf8_len = 1;
    return ev;
}

const RailEntrySpec = struct { name: []const u8, bucket: cat.Bucket };
/// Five entries over four categories, with two names sharing a prefix so the
/// ranking can be told apart from the catalog's own order.
const rail_spec = [_]RailEntrySpec{
    .{ .name = "Player Beta", .bucket = .media },
    .{ .name = "Beta Player", .bucket = .media },
    .{ .name = "Alpha Notes", .bucket = .productivity },
    .{ .name = "Gamma Paint", .bucket = .creativity },
    .{ .name = "Player Server", .bucket = .developer },
};

fn railCatalog(m: *Menu, arena: std.mem.Allocator, spec: []const RailEntrySpec) !void {
    const entries = try arena.alloc(cat.Entry, spec.len);
    var fold_buf: [128]u8 = undefined;
    for (spec, 0..) |s, i| {
        entries[i] = .{
            .name = try arena.dupe(u8, s.name),
            .fold = try arena.dupe(u8, std.ascii.lowerString(&fold_buf, s.name)),
            .bucket = s.bucket,
        };
    }
    m.catalog.entries = entries;
    m.total = @intCast(spec.len);
    m.buckets = @splat(0);
    for (spec) |s| m.buckets[@intFromEnum(s.bucket)] += 1;
}

/// Open the rail the way the host does: point the model at it, give it its
/// own natural size, then re-rank.
fn railOpen(m: *Menu) void {
    m.setStyle(.rail);
    m.sizeTo(layout.rail_w, layout.rail_h);
    m.refresh();
}

fn sessionY(g: layout.RailGeo, i: usize) f64 {
    return g.sess[i].y + g.sess[i].h * 0.5;
}

test "launcher-menu: the rail opens lit, filters under the query, and ranks prefixes first" {
    const t = std.testing;
    var m = Menu.init(t.allocator, undefined);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try railCatalog(&m, arena.allocator(), &rail_spec);

    // The rail's own natural size, and a list-only body whatever the drawer's
    // view mode was left at.
    m.setListMode(false);
    railOpen(&m);
    try t.expectEqual(@as(f64, layout.rail_w), m.preferredSize().w);
    try t.expectEqual(@as(f64, layout.rail_h), m.preferredSize().h);
    try t.expect(m.list_mode);
    const v = m.view();
    try t.expectEqual(layout.Style.rail, v.style);
    try t.expectEqual(layout.rail_w, v.rgeo.w);
    try t.expectApproxEqAbs(m.bar.value, v.bar_y, 1e-9);
    try t.expectApproxEqAbs(m.tip.value, v.tip_a, 1e-9);

    // One highlight always: the open lights the first result even though
    // nothing has been hovered or pressed yet.
    try t.expectEqual(rail_spec.len, m.hits.items.len);
    try t.expectEqual(@as(i32, 0), m.sel);

    // Typing anywhere in the panel starts a search — the field never held the
    // focus — and a prefix match ranks above a substring one.
    m.focused = false;
    for ("play") |c| try t.expectEqual(Op.repaint, m.key(&keyChar(c)).op);
    try t.expect(m.focused);
    try t.expectEqualStrings("play", m.query.items);
    try t.expectEqual(@as(usize, 3), m.hits.items.len);
    try t.expectEqualStrings("Player Beta", m.catalog.entries[m.hits.items[0]].name);
    try t.expectEqualStrings("Player Server", m.catalog.entries[m.hits.items[1]].name);
    try t.expectEqualStrings("Beta Player", m.catalog.entries[m.hits.items[2]].name);
    try t.expectEqual(@as(i32, 0), m.sel);

    // A category narrows under the same query instead of replacing it, and
    // the indicator starts sliding to that button.
    const media_pill = @intFromEnum(cat.Bucket.media) + 1;
    try t.expect(m.pickPill(media_pill));
    try t.expectEqualStrings("play", m.query.items);
    try t.expectEqual(@as(i32, media_pill), m.sel_pill);
    try t.expectEqual(@as(usize, 2), m.hits.items.len);
    try t.expectEqual(@as(i32, 0), m.sel);
    try t.expectApproxEqAbs(m.rgeo.barY(@intCast(media_pill)), m.bar.to, 1e-9);
    try t.expect(m.bar.running);

    // Back to All: the rest of the matches return. Picking the category that
    // is already on changes nothing.
    try t.expect(m.pickPill(0));
    try t.expectEqual(@as(i32, 0), m.sel_pill);
    try t.expectEqual(@as(usize, 3), m.hits.items.len);
    try t.expect(!m.pickPill(0));

    // A query that matches nothing leaves no highlight, nothing to start and
    // an empty footer note.
    m.query.clearRetainingCapacity();
    try m.query.appendSlice(t.allocator, "zzz");
    m.refresh();
    try t.expectEqual(@as(usize, 0), m.hits.items.len);
    try t.expectEqual(@as(i32, -1), m.sel);
    try t.expectEqual(Op.none, m.key(&keyTap(seat_mod.xkb.XKB_KEY_Return)).op);
    try t.expectEqual(Op.repaint, m.key(&keyTap(seat_mod.xkb.XKB_KEY_Down)).op);
    try t.expectEqualStrings("", m.view().toast);

    // Escape clears the search and takes the field back; only the second
    // press closes the panel.
    try t.expectEqual(Op.repaint, m.key(&keyTap(seat_mod.xkb.XKB_KEY_Escape)).op);
    try t.expectEqual(@as(usize, 0), m.query.items.len);
    try t.expect(m.focused);
    try t.expectEqual(@as(i32, 0), m.sel);
    try t.expectEqual(Op.close, m.key(&keyTap(seat_mod.xkb.XKB_KEY_Escape)).op);

    // Pointing the same model back at the reference panel returns its size.
    m.setStyle(.classic);
    try t.expectEqual(@as(f64, layout.preferred_w), m.preferredSize().w);
    try t.expectEqual(@as(f64, layout.preferred_h), m.preferredSize().h);
}

test "launcher-menu: the rail wraps its arrows, clamps its pages, and answers the chords" {
    const t = std.testing;
    const xkb = seat_mod.xkb;
    var m = Menu.init(t.allocator, undefined);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Twenty rows: a page is a real move and the scroll has somewhere to go.
    var entries: [20]cat.Entry = undefined;
    for (&entries, 0..) |*e, i| {
        const name = try std.fmt.allocPrint(a, "Row {d:0>2}", .{i});
        e.* = .{
            .name = name,
            .fold = try std.fmt.allocPrint(a, "row {d:0>2}", .{i}),
            .bucket = .other,
        };
    }
    m.catalog.entries = &entries;
    m.total = 20;
    m.buckets = @splat(0);
    m.buckets[@intFromEnum(cat.Bucket.other)] = 20;
    railOpen(&m);

    try t.expectEqual(@as(usize, 7), m.rgeo.pageRows());

    // Down walks one row, and the highlight is drawn into the cached body,
    // so moving it retires that cache.
    const gen_before = m.gen;
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Down)).op);
    try t.expectEqual(@as(i32, 1), m.sel);
    try t.expect(m.gen > gen_before);

    // Up from the first wraps to the last, and Down from the last wraps back.
    m.sel = 0;
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Up)).op);
    try t.expectEqual(@as(i32, 19), m.sel);
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Down)).op);
    try t.expectEqual(@as(i32, 0), m.sel);

    // A page clamps at the ends instead of wrapping.
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Page_Down)).op);
    try t.expectEqual(@as(i32, 7), m.sel);
    m.sel = 18;
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Page_Down)).op);
    try t.expectEqual(@as(i32, 19), m.sel);
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Page_Up)).op);
    try t.expectEqual(@as(i32, 12), m.sel);
    m.sel = 0;
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Page_Up)).op);
    try t.expectEqual(@as(i32, 0), m.sel);

    // Home and End take the ends, and End asks the scroll to follow.
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_End)).op);
    try t.expectEqual(@as(i32, 19), m.sel);
    try t.expect(m.target > 0);
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Home)).op);
    try t.expectEqual(@as(i32, 0), m.sel);
    try t.expectApproxEqAbs(@as(f64, 0.0), m.target, 1e-9);

    // Ctrl+N and Ctrl+P are the same walks.
    try t.expectEqual(Op.repaint, m.key(&keyChord(xkb.XKB_KEY_n, true, false)).op);
    try t.expectEqual(@as(i32, 1), m.sel);
    try t.expectEqual(Op.repaint, m.key(&keyChord(xkb.XKB_KEY_p, true, false)).op);
    try t.expectEqual(@as(i32, 0), m.sel);

    // Alt+1..8 pick the categories by number — Alt+8 is the "Other" bucket
    // these rows are all in, Alt+1 is All — and the highlight lands on the
    // first result under whichever it is. The arrows walk the ring with a
    // wrap at both ends.
    try t.expectEqual(Op.repaint, m.key(&keyChord(xkb.XKB_KEY_8, false, true)).op);
    try t.expectEqual(@as(i32, layout.pill_count - 1), m.sel_pill);
    try t.expectEqual(@as(usize, 20), m.hits.items.len);
    try t.expectEqual(@as(i32, 0), m.sel);
    try t.expectEqual(Op.repaint, m.key(&keyChord(xkb.XKB_KEY_1, false, true)).op);
    try t.expectEqual(@as(i32, 0), m.sel_pill);
    try t.expectEqual(Op.repaint, m.key(&keyChord(xkb.XKB_KEY_Left, false, true)).op);
    try t.expectEqual(@as(i32, @intCast(layout.strip_cat_count - 1)), m.sel_pill);
    try t.expectEqual(Op.repaint, m.key(&keyChord(xkb.XKB_KEY_Right, false, true)).op);
    try t.expectEqual(@as(i32, 0), m.sel_pill);

    // Alt+L and Alt+R are the strip's Lock and Reload shell — never text.
    try t.expectEqual(Op.run_power, m.key(&keyChord(xkb.XKB_KEY_l, false, true)).op);
    try t.expectEqual(Op.reload_shell, m.key(&keyChord(xkb.XKB_KEY_r, false, true)).op);
    try t.expectEqual(@as(usize, 0), m.query.items.len);

    // Alt+O is Log out and Alt+P is Power: both ask first, and the card owns
    // the keys while it is up — Escape cancels, Return runs it.
    const ask = m.key(&keyChord(xkb.XKB_KEY_o, false, true));
    try t.expectEqual(Op.ask_power, ask.op);
    try t.expectEqual(@as(i32, 1), ask.hit);
    try t.expectEqual(@as(i32, 1), m.confirm);
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Escape)).op);
    try t.expectEqual(@as(i32, -1), m.confirm);
    _ = m.key(&keyChord(xkb.XKB_KEY_o, false, true));
    const go = m.key(&keyTap(xkb.XKB_KEY_Return));
    try t.expectEqual(Op.run_power, go.op);
    try t.expectEqual(@as(i32, 1), go.hit);
    try t.expectEqual(@as(i32, -1), m.confirm);
    const power = m.key(&keyChord(xkb.XKB_KEY_p, false, true));
    try t.expectEqual(Op.ask_power, power.op);
    try t.expectEqual(@as(i32, 3), power.hit);
    _ = m.key(&keyTap(xkb.XKB_KEY_Escape));
    try t.expectEqual(@as(i32, -1), m.confirm);
}

test "launcher-menu: the rail's pointer is its highlight and its strip is its session" {
    const t = std.testing;
    const xkb = seat_mod.xkb;
    var m = Menu.init(t.allocator, undefined);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try railCatalog(&m, arena.allocator(), &rail_spec);
    railOpen(&m);

    const g = m.rgeo;
    const row_h = layout.rail_row_h;
    const row_x = g.body.x + 40.0;

    // Hovering a row moves the highlight there — the two never disagree —
    // and the same spot a second time changes nothing.
    try t.expect(m.hoverAt(row_x, g.body.y + row_h * 1.5));
    try t.expectEqual(@as(i32, 1), m.sel);
    try t.expect(!m.hoverAt(row_x, g.body.y + row_h * 1.5));

    // A rail button lights without touching the highlight, and starts the
    // tooltip fade; the tick drives it and says a frame is owed while it
    // runs.
    const cat_rect = g.cat[1];
    try t.expect(m.hoverAt(cat_rect.x + cat_rect.w * 0.5, cat_rect.y + cat_rect.h * 0.5));
    try t.expectEqual(@as(i32, 1), m.hover_pill);
    try t.expectEqual(@as(i32, 1), m.sel);
    try t.expectEqual(@as(f64, 1.0), m.tip.to);
    try t.expect(m.tip.running);
    try t.expect(m.tick());
    _ = m.tip.step(anim.monotonicNs() + tip_ns);
    try t.expect(!m.tip.running);
    try t.expectApproxEqAbs(@as(f64, 1.0), m.tip.value, 1e-9);

    // Wandering off the strip fades it back out and moves the highlight.
    try t.expect(m.hoverAt(row_x, g.body.y + row_h * 2.5));
    try t.expectEqual(@as(i32, -1), m.hover_pill);
    try t.expectEqual(@as(f64, 0.0), m.tip.to);
    try t.expectEqual(@as(i32, 2), m.sel);
    try t.expect(m.tick());
    _ = m.tip.step(anim.monotonicNs() + tip_ns);
    try t.expectApproxEqAbs(@as(f64, 0.0), m.tip.value, 1e-9);

    // A press on a row starts it; a press in the search field only focuses.
    const hit = m.click(row_x, g.body.y + row_h * 0.5, .{ .btn = 1 });
    try t.expectEqual(Op.launch, hit.op);
    try t.expectEqual(@as(i32, 0), hit.hit);
    try t.expectEqual(Op.focus_field, m.click(g.search.x + 4.0, g.search.y + 4.0, .{ .btn = 1 }).op);

    // The strip in `strip_sess` order: Lock runs, Log out asks, Reload shell
    // and the theme toggle stay in the panel, Power asks.
    const sx = g.sess[0].x + g.sess[0].w * 0.5;
    try t.expectEqual(Op.run_power, m.click(sx, sessionY(g, 0), .{ .btn = 1 }).op);
    const ask = m.click(sx, sessionY(g, 1), .{ .btn = 1 });
    try t.expectEqual(Op.ask_power, ask.op);
    try t.expectEqual(@as(i32, 1), ask.hit);
    try t.expectEqual(@as(i32, 1), m.confirm);
    // The card owns the panel: the pointer lights nothing while it is up and
    // a press on the scrim behind it only cancels.
    try t.expect(!m.hoverAt(row_x, g.body.y + row_h * 0.5));
    const dismiss = m.click(4.0, 4.0, .{ .btn = 1 });
    try t.expectEqual(Op.none, dismiss.op);
    try t.expectEqual(@as(i32, -1), m.confirm);
    // Confirming with the pointer runs the button the card was asked for.
    _ = m.click(sx, sessionY(g, 1), .{ .btn = 1 });
    const card = layout.modalOf(m.geo);
    const go = m.click(card.confirm.x + 4.0, card.confirm.y + 4.0, .{ .btn = 1 });
    try t.expectEqual(Op.run_power, go.op);
    try t.expectEqual(@as(i32, 1), go.hit);
    try t.expectEqual(@as(i32, -1), m.confirm);
    try t.expectEqual(Op.reload_shell, m.click(sx, sessionY(g, 2), .{ .btn = 1 }).op);
    const power = m.click(sx, sessionY(g, 3), .{ .btn = 1 });
    try t.expectEqual(Op.ask_power, power.op);
    try t.expectEqual(@as(i32, 3), power.hit);
    _ = m.key(&keyTap(xkb.XKB_KEY_Escape));
    try t.expectEqual(Op.toggle_theme, m.click(sx, sessionY(g, 4), .{ .btn = 1 }).op);

    // A right press on a row opens the pin menu in the rail's own space, and
    // its one item hands the row back with the menu closed.
    const press = m.click(row_x, g.body.y + row_h * 0.5, .{ .btn = 3, .pinned = true });
    try t.expectEqual(Op.repaint, press.op);
    try t.expectEqual(@as(i32, 0), m.ctx_row);
    try t.expect(m.ctx_pinned);
    const menu = layout.ctxRect(m.geo, m.ctx_ax, m.ctx_ay);
    const took = m.click(menu.x + 6.0, menu.y + layout.ctx_pad + 4.0, .{ .btn = 1 });
    try t.expectEqual(Op.ctx_pin, took.op);
    try t.expectEqual(@as(i32, 0), took.hit);
    try t.expectEqual(@as(i32, -1), m.ctx_row);
    // A right press off the rows asks for nothing.
    try t.expectEqual(Op.none, m.click(4.0, g.body.y + 4.0, .{ .btn = 3 }).op);

    // Enter starts the highlight and closes; Ctrl+Enter starts it and keeps
    // the panel, with the mockup's note standing in for the footer.
    _ = m.hoverAt(row_x, g.body.y + row_h * 1.5);
    try t.expectEqual(Op.launch, m.key(&keyTap(xkb.XKB_KEY_Return)).op);
    const kept = m.key(&keyChord(xkb.XKB_KEY_Return, true, false));
    try t.expectEqual(Op.launch_keep, kept.op);
    try t.expectEqual(@as(i32, 1), kept.hit);
    try t.expectEqualStrings("Opening Beta Player", m.view().toast);
    try t.expect(m.toast_until_ns > anim.monotonicNs());
    // The note outlives a tick…
    _ = m.tick();
    try t.expectEqualStrings("Opening Beta Player", m.view().toast);
    // …and retires on the one that reaches its deadline.
    m.toast_until_ns = 0;
    try t.expect(m.tick());
    try t.expectEqual(@as(usize, 0), m.view().toast.len);

    // Opening the panel again starts with a clean footer.
    m.reset();
    try t.expectEqual(@as(usize, 0), m.view().toast.len);
}

test "launcher-menu: the rail's scroll follows the highlight and clamps at the ends" {
    const t = std.testing;
    const xkb = seat_mod.xkb;
    var m = Menu.init(t.allocator, undefined);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: [40]cat.Entry = undefined;
    for (&entries, 0..) |*e, i| {
        const name = try std.fmt.allocPrint(a, "App {d:0>2}", .{i});
        e.* = .{
            .name = name,
            .fold = try std.fmt.allocPrint(a, "app {d:0>2}", .{i}),
            .bucket = .other,
        };
    }
    m.catalog.entries = &entries;
    m.total = 40;
    m.buckets = @splat(0);
    m.buckets[@intFromEnum(cat.Bucket.other)] = 40;
    railOpen(&m);

    const max = m.rgeo.maxScroll(m.hits.items.len);
    try t.expect(max > 0);

    // End pulls the content up just far enough for the last row to be whole,
    // which is the end of the scroll.
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_End)).op);
    try t.expectEqual(@as(i32, 39), m.sel);
    try t.expectApproxEqAbs(max, m.target, 1e-9);
    settleNow(&m);
    _ = m.tick();
    try t.expectApproxEqAbs(m.target, m.current, layout.rail_row_h);
    try t.expect(!m.tick());

    // Home walks back to the top.
    try t.expectEqual(Op.repaint, m.key(&keyTap(xkb.XKB_KEY_Home)).op);
    try t.expectEqual(@as(i32, 0), m.sel);
    try t.expectApproxEqAbs(@as(f64, 0.0), m.target, 1e-9);

    // The wheel moves the rail's target and clamps both ways.
    try t.expect(m.axis(1.0e9));
    try t.expectApproxEqAbs(max, m.target, 1e-9);
    try t.expect(m.axis(-1.0e9));
    try t.expectApproxEqAbs(@as(f64, 0.0), m.target, 1e-9);
}
