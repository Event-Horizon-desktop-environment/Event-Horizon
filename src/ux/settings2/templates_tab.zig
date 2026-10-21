//! Settings ▸ Appearance ▸ Templates — the roster redesign.
//!
//! A self-painted live page (like the Sound and Bluetooth tabs): the whole
//! scrollable region is the page's own, so the grouped rows, filter bar,
//! detail panels and footer share one geometry pass between paint, hit-test
//! and the scroll height (`layout` below). The tab has no card list in
//! `rows.zig` any more — this page owns the surface end to end.
//!
//! Structure follows the mockup's roster:
//!
//!   header       APPEARANCE / Templates tri-line + "Enable detected" and
//!                "Regenerate all" actions on the title row
//!   filter bar   text field + All / Enabled / Disabled / Off-system segments
//!   groups       one glass card per application family; the header carries
//!                a disclosure chevron, the row count and a group switch
//!                (turning it on enables every row it lists)
//!   rows         initial chip, name, output path, status text, details
//!                chevron, per-template switch
//!   details      single-open panel under a row: output path, template file,
//!                post-apply hook, "Apply now"
//!   footer       "N templates are for applications not detected" + Show all
//!   recipes      the "Use base.toml recipes" switch, kept from the old page
//!
//! Detection and status are real: the gate rules from `color/apply.zig` are
//! ported in `templates_registry.zig` and run through the probes below
//! (PATH binaries, session env, config dirs). A row's "Applied N ago" comes
//! from the output file's mtime, re-stat'ed on a 5 s throttle and shortly
//! after any toggle flips (the shell re-applies appearance.toml on its
//! watcher, so the mtimes move a beat later).
//!
//! Expansion/filter/detail state is session-only, like the wallpaper page's
//! view state; the switches themselves persist through
//! `[appearance.matugen_templates]` (the window's `flushAppearanceTab`).

const std = @import("std");
const app_mod = @import("app.zig");
const common = @import("common.zig");
const tmpl = @import("templates_registry.zig");
const ui_paint = @import("ui_paint.zig");
const vmx = @import("../../desktop_shell/widgets/volume_mixer.zig");
const wl_seat = @import("../../wl/seat.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const linux = std.os.linux;
const xkb = wl_seat.xkb;

pub const tab_id: i32 = app_mod.TabId.appearance_templates;

pub fn ownsTab(tab: i32) bool {
    return tab == tab_id;
}

/// Content-column geometry, passed in rather than read from `Content` so
/// this module stays free of a cycle back into `ui_content`.
pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

pub const Action = union(enum) {
    /// Page-only state changed (filter, segment, expansion, details).
    repaint,
    /// `Settings` changed: the window flushes
    /// `[appearance.matugen_templates]` (or the recipes flag) and repaints.
    persist,
};

// ---------------------------------------------------------------------------
// Metrics — the mockup's roster, mapped onto the settings content column
// (which is ~498px wide, not the mockup's 820px page).
// ---------------------------------------------------------------------------

const k_action_h: i32 = 30;
const k_filter_h: i32 = 34;
const k_seg_h: i32 = 30;
const k_group_gap: i32 = 10;
const k_group_hdr_h: i32 = 46;
const k_row_h: i32 = 52;
const k_pad: i32 = 16;
const k_switch_w: i32 = 52;
const k_switch_h: i32 = 26;
const k_group_switch_w: i32 = 44;
const k_group_switch_h: i32 = 24;
const k_details_w: i32 = 24;
const k_detail_h: i32 = 186;
const k_detail_gap: i32 = 4;
const k_detail_box_h: i32 = 26;
const k_footer_h: i32 = 38;
const k_recipes_h: i32 = 56;
const k_empty_h: i32 = 92;
const k_seg_pad: i32 = 12;

/// The widest group's row count — Terminal's eight — sizes the per-group
/// row slots at compile time. Pinned to the registry by a test.
const k_max_group_rows: usize = blk: {
    var best: usize = 0;
    for (0..tmpl.group_count) |gi| {
        var n: usize = 0;
        for (tmpl.templates) |t| {
            if (t.group == gi) n += 1;
        }
        if (n > best) best = n;
    }
    break :blk best;
};

const Rect = common.Rect;

fn inRect(px: f64, py: f64, r: Rect) bool {
    return common.pointInRect(px, py, r);
}

// ---------------------------------------------------------------------------
// Layout — one deterministic pass shared by paint, hit and the scroll height.
// ---------------------------------------------------------------------------

pub const RowGeom = struct {
    /// Index into `templates_registry.templates`.
    tpl: u8 = 0,
    y: i32 = 0,
    open: bool = false,
};

pub const GroupGeom = struct {
    group: u8 = 0,
    y: i32 = 0,
    h: i32 = 0,
    open: bool = true,
    rows: [k_max_group_rows]RowGeom = [_]RowGeom{.{}} ** k_max_group_rows,
    n: u8 = 0,
};

pub const Layout = struct {
    x: i32 = 0,
    w: i32 = 0,
    actions_y: i32 = 0,
    enable_btn: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    regen_btn: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    filter: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    seg: [4]Rect = [_]Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 4,
    summary_y: i32 = 0,
    groups_y: i32 = 0,
    groups: [tmpl.group_count]GroupGeom = [_]GroupGeom{.{}} ** tmpl.group_count,
    n_groups: u8 = 0,
    empty_y: i32 = 0,
    empty_h: i32 = 0,
    footer_y: i32 = 0,
    footer_h: i32 = 0,
    show_all: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    recipes_y: i32 = 0,
    recipes: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    recipes_switch: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    bottom: i32 = 0,
};

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    settings: *app_mod.Settings = undefined,
    inited: bool = false,

    // --- detection + status caches ------------------------------------
    env_bufs: tmpl.EnvBufs = .{},
    env: tmpl.Env = .{},
    detected: [tmpl.template_count]bool = [_]bool{true} ** tmpl.template_count,
    have_detect: bool = false,
    status: [tmpl.template_count]tmpl.StatusInfo = [_]tmpl.StatusInfo{.{}} ** tmpl.template_count,
    have_status: bool = false,
    stat_ms: i64 = 0,
    last_sig: u64 = 0,
    restat_at_ms: i64 = -1,

    // --- view state (session-only) -------------------------------------
    filter: [64]u8 = undefined,
    filter_len: usize = 0,
    filter_focus: bool = false,
    segment: tmpl.Segment = .all,
    show_all: bool = false,
    open_slot: i32 = -1,
    expanded: [tmpl.group_count]bool = [_]bool{true} ** tmpl.group_count,

    pub fn init(self: *Page, gpa: std.mem.Allocator, io: std.Io, settings: *app_mod.Settings) void {
        self.alloc = gpa;
        self.io = io;
        self.settings = settings;
        self.inited = true;
        self.refreshDetect();
    }

    pub fn deinit(self: *Page) void {
        self.inited = false;
    }

    /// Per-frame (active tab only): first-pass detection, then the throttled
    /// status re-stat. A toggle flip schedules a re-stat past the shell's
    /// apply delay (the watcher renders appearance.toml on its own clock).
    pub fn sync(self: *Page) void {
        if (!self.inited) return;
        if (!self.have_detect) {
            self.refreshDetect();
            return;
        }
        const now = vmx.nowMs();
        const cur_sig = self.sig();
        if (cur_sig != self.last_sig) {
            self.last_sig = cur_sig;
            self.restat_at_ms = now + 1200;
        }
        if (self.restat_at_ms >= 0) {
            if (now >= self.restat_at_ms) {
                self.restat_at_ms = -1;
                self.refreshStatus();
            }
            return;
        }
        if (now - self.stat_ms >= 5000) self.refreshStatus();
    }

    // -----------------------------------------------------------------------
    // Probes — the production side of `templates_registry.Probes`.
    // -----------------------------------------------------------------------

    fn probes(self: *Page) tmpl.Probes {
        return .{
            .ctx = @ptrCast(self),
            .envFn = sysEnv,
            .binFn = sysBin,
            .pathFn = sysPath,
            .mtimeFn = sysMtime,
        };
    }

    fn refreshDetect(self: *Page) void {
        const pr = self.probes();
        self.env = tmpl.fillEnv(pr, &self.env_bufs);
        for (&self.detected, &tmpl.templates) |*d, *t| {
            d.* = tmpl.detected(pr, t, self.env);
        }
        self.have_detect = true;
        self.refreshStatus();
    }

    fn refreshStatus(self: *Page) void {
        if (!self.inited) return;
        const pr = self.probes();
        for (&self.status, &tmpl.templates) |*si, *t| {
            const enabled = self.settings.matugen_templates[t.slot];
            si.* = tmpl.statusInfo(pr, t, self.env, enabled);
        }
        self.have_status = true;
        self.stat_ms = vmx.nowMs();
        self.last_sig = self.sig();
    }

    /// Enabled bits + the recipes flag — a cheap "did anything the apply
    /// pass reads change" signature.
    fn sig(self: *const Page) u64 {
        var s: u64 = 0;
        for (&tmpl.templates) |*t| {
            if (self.settings.matugen_templates[t.slot]) s |= @as(u64, 1) << @intCast(t.slot);
        }
        if (self.settings.matugen_base_recipes) s |= @as(u64, 1) << 40;
        return s;
    }

    // -----------------------------------------------------------------------
    // Filter / segment predicates
    // -----------------------------------------------------------------------

    fn filterText(self: *const Page) []const u8 {
        return self.filter[0..self.filter_len];
    }

    fn matchesText(self: *const Page, t: *const tmpl.Config) bool {
        const f = self.filterText();
        if (f.len == 0) return true;
        return containsIgnoreCase(t.label, f) or
            containsIgnoreCase(t.input, f) or
            containsIgnoreCase(t.output, f);
    }

    fn rowPassesSegment(self: *const Page, i: usize) bool {
        const t = &tmpl.templates[i];
        const enabled = self.settings.matugen_templates[t.slot];
        return switch (self.segment) {
            .all => true,
            .enabled => enabled,
            .disabled => !enabled,
            .off_system => !self.detected[i],
        };
    }

    fn rowShown(self: *const Page, i: usize) bool {
        if (!self.matchesText(&tmpl.templates[i])) return false;
        if (!self.rowPassesSegment(i)) return false;
        // Undetected rows stay out of the roster until "Show all" — the
        // footer advertises them, and the Off-system segment lists them.
        if (!self.show_all and self.segment != .off_system and !self.detected[i]) return false;
        return true;
    }

    pub fn countFor(self: *const Page, seg: tmpl.Segment) usize {
        return switch (seg) {
            .all => tmpl.template_count,
            .enabled => blk: {
                var n: usize = 0;
                for (&tmpl.templates) |*t| {
                    if (self.settings.matugen_templates[t.slot]) n += 1;
                }
                break :blk n;
            },
            .disabled => blk: {
                var n: usize = 0;
                for (&tmpl.templates) |*t| {
                    if (!self.settings.matugen_templates[t.slot]) n += 1;
                }
                break :blk n;
            },
            .off_system => blk: {
                var n: usize = 0;
                for (self.detected) |d| {
                    if (!d) n += 1;
                }
                break :blk n;
            },
        };
    }

    // -----------------------------------------------------------------------
    // Layout
    // -----------------------------------------------------------------------

    fn layout(self: *const Page, g: Geo) Layout {
        const x: i32 = g.content_x + 8;
        const w: i32 = g.content_w - 16;
        const top: i32 = common.content_top;
        var lay = Layout{ .x = x, .w = w };

        // No page header: the sidebar already names the page, so the roster
        // opens straight into the filter bar (user feedback: the tri-line
        // duplicated the rail and read as clutter).
        const filter_y: i32 = top;
        var seg_w: [4]i32 = undefined;
        for (0..4) |i| {
            const seg: tmpl.Segment = @enumFromInt(i);
            var cnt_buf: [12]u8 = undefined;
            const cnt = std.fmt.bufPrint(&cnt_buf, "{d}", .{self.countFor(seg)}) catch "";
            const label_w = ui_paint.measureTextWidth(tmpl.segmentLabel(seg), 12, 500);
            const count_w = ui_paint.measureTextWidth(cnt, 11, 500);
            seg_w[i] = 2 * k_seg_pad + label_w + 5 + count_w;
        }
        const seg_y = filter_y + k_filter_h + 8;
        var sx = x;
        for (0..4) |i| {
            lay.seg[i] = .{ .x = sx, .y = seg_y, .w = seg_w[i], .h = k_seg_h };
            sx += seg_w[i] + 2;
        }
        lay.filter = .{ .x = x, .y = filter_y, .w = w, .h = k_filter_h };

        // Toolbar row: the roster summary on the left, the two page actions
        // right-aligned (the title row has no room for them at this width).
        lay.actions_y = seg_y + k_seg_h + 12;
        const enable_w = ui_paint.measureTextWidth("Enable detected", 12, 500) + 36;
        const regen_w = ui_paint.measureTextWidth("Regenerate all", 12, 600) + 36;
        lay.regen_btn = .{ .x = x + w - regen_w, .y = lay.actions_y, .w = regen_w, .h = k_action_h };
        lay.enable_btn = .{
            .x = lay.regen_btn.x - 8 - enable_w,
            .y = lay.actions_y,
            .w = enable_w,
            .h = k_action_h,
        };
        lay.summary_y = lay.actions_y + 20;
        lay.groups_y = lay.actions_y + k_action_h + 12;

        // Group cards top-down.
        const filtering = self.filter_len > 0 or self.segment != .all;
        var y = lay.groups_y;
        for (0..tmpl.group_count) |gi| {
            var gg = GroupGeom{ .group = @intCast(gi) };
            var n: u8 = 0;
            for (&tmpl.templates, 0..) |*t, i| {
                if (t.group != gi or !self.rowShown(i)) continue;
                if (n >= k_max_group_rows) break;
                gg.rows[n] = .{ .tpl = @intCast(i) };
                n += 1;
            }
            if (n == 0) continue;
            gg.n = n;
            gg.open = filtering or self.expanded[gi];
            gg.y = y;
            if (!gg.open) {
                gg.h = k_group_hdr_h;
            } else {
                var ry = y + k_group_hdr_h;
                for (gg.rows[0..n]) |*r| {
                    r.y = ry;
                    r.open = self.open_slot >= 0 and tmpl.templates[r.tpl].slot == self.open_slot;
                    ry += k_row_h + (if (r.open) k_detail_h + k_detail_gap else 0);
                }
                gg.h = ry - y;
            }
            y += gg.h + k_group_gap;
            lay.groups[lay.n_groups] = gg;
            lay.n_groups += 1;
        }

        var list_bottom = lay.groups_y;
        if (lay.n_groups > 0) {
            const last = lay.groups[lay.n_groups - 1];
            list_bottom = last.y + last.h;
        } else {
            lay.empty_y = lay.groups_y;
            lay.empty_h = k_empty_h;
            list_bottom = lay.groups_y + k_empty_h;
        }

        // Footer: how many rows the roster is holding back.
        const hidden = self.countFor(.off_system);
        lay.footer_y = list_bottom + 10;
        lay.footer_h = if (hidden > 0) k_footer_h else 0;
        const show_label = if (self.show_all) "Detected only" else "Show all";
        const show_w = ui_paint.measureTextWidth(show_label, 12, 600) + 16;
        lay.show_all = .{
            .x = x + w - show_w,
            .y = lay.footer_y + @divTrunc(k_footer_h - 26, 2),
            .w = show_w,
            .h = 26,
        };
        if (lay.footer_h == 0) lay.show_all = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

        // Base-recipes switch, kept from the pre-redesign page.
        lay.recipes_y = lay.footer_y + lay.footer_h + 10;
        lay.recipes = .{ .x = x, .y = lay.recipes_y, .w = w, .h = k_recipes_h };
        lay.recipes_switch = .{
            .x = x + w - k_pad - k_switch_w,
            .y = lay.recipes_y + @divTrunc(k_recipes_h - k_switch_h, 2),
            .w = k_switch_w,
            .h = k_switch_h,
        };
        lay.bottom = lay.recipes_y + k_recipes_h + common.spacing_l;
        return lay;
    }

    pub fn totalHeight(self: *Page, g: Geo) i32 {
        if (!self.inited) return 0;
        return self.layout(g).bottom;
    }

    // -----------------------------------------------------------------------
    // Hit testing
    // -----------------------------------------------------------------------

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        if (!self.inited) return null;
        const lay = self.layout(g);

        if (inRect(px, ly, lay.regen_btn)) return .persist;
        if (inRect(px, ly, lay.enable_btn)) {
            self.enableDetected();
            return .persist;
        }
        if (inRect(px, ly, lay.filter)) {
            self.filter_focus = true;
            return .repaint;
        }
        for (lay.seg, 0..) |r, i| {
            if (inRect(px, ly, r)) {
                self.filter_focus = false;
                self.segment = @enumFromInt(i);
                return .repaint;
            }
        }

        for (lay.groups[0..lay.n_groups]) |gg| {
            const gsw = groupSwitchRect(lay, gg);
            if (inRect(px, ly, gsw)) {
                self.toggleGroup(gg);
                return .persist;
            }
            const hdr = Rect{ .x = lay.x, .y = gg.y, .w = lay.w, .h = k_group_hdr_h };
            if (inRect(px, ly, hdr)) {
                self.expanded[gg.group] = !self.expanded[gg.group];
                return .repaint;
            }
            if (!gg.open) continue;
            for (gg.rows[0..gg.n]) |r| {
                const t = &tmpl.templates[r.tpl];
                if (r.open) {
                    const pb = detailBtnRect(lay, r);
                    if (inRect(px, ly, pb)) return .persist;
                }
                const sw = rowSwitchRect(lay, r);
                if (inRect(px, ly, sw)) {
                    self.settings.matugen_templates[t.slot] = !self.settings.matugen_templates[t.slot];
                    return .persist;
                }
                const dc = detailsChevronRect(lay, r);
                if (inRect(px, ly, dc)) {
                    self.open_slot = if (self.open_slot == t.slot) -1 else t.slot;
                    return .repaint;
                }
                const row_rect = Rect{ .x = lay.x, .y = r.y, .w = lay.w, .h = k_row_h };
                if (inRect(px, ly, row_rect)) {
                    self.settings.matugen_templates[t.slot] = !self.settings.matugen_templates[t.slot];
                    return .persist;
                }
            }
        }

        if (lay.footer_h > 0 and inRect(px, ly, lay.show_all)) {
            self.show_all = !self.show_all;
            return .repaint;
        }
        if (inRect(px, ly, lay.recipes)) {
            self.settings.matugen_base_recipes = !self.settings.matugen_base_recipes;
            return .persist;
        }
        if (self.filter_focus) {
            self.filter_focus = false;
            return .repaint;
        }
        return null;
    }

    /// "Enable detected" re-detects first (the user may have just installed
    /// something) and then switches on every template whose gate passes.
    fn enableDetected(self: *Page) void {
        self.refreshDetect();
        for (&tmpl.templates, 0..) |*t, i| {
            if (self.detected[i]) self.settings.matugen_templates[t.slot] = true;
        }
    }

    fn toggleGroup(self: *Page, gg: GroupGeom) void {
        const all_on = self.groupState(gg) == .on;
        const target = !all_on;
        for (gg.rows[0..gg.n]) |r| {
            const t = &tmpl.templates[r.tpl];
            self.settings.matugen_templates[t.slot] = target;
        }
    }

    const GroupState = enum { off, on, mixed };

    fn groupState(self: *const Page, gg: GroupGeom) GroupState {
        var on: usize = 0;
        for (gg.rows[0..gg.n]) |r| {
            if (self.settings.matugen_templates[tmpl.templates[r.tpl].slot]) on += 1;
        }
        if (on == 0) return .off;
        if (on == gg.n) return .on;
        return .mixed;
    }

    // -----------------------------------------------------------------------
    // Keyboard — the filter field owns focus while it is active.
    // -----------------------------------------------------------------------

    pub fn key(self: *Page, sym: u32, utf8: []const u8) bool {
        if (!self.filter_focus) return false;
        switch (sym) {
            xkb.XKB_KEY_Escape => {
                self.filter_focus = false;
                self.filter_len = 0;
                return true;
            },
            xkb.XKB_KEY_BackSpace => {
                if (self.filter_len > 0) {
                    self.filter_len -= 1;
                    // Step back over UTF-8 continuation bytes.
                    while (self.filter_len > 0 and (self.filter[self.filter_len] & 0xC0) == 0x80) {
                        self.filter_len -= 1;
                    }
                }
                return true;
            },
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                self.filter_focus = false;
                return true;
            },
            else => {
                for (utf8) |ch| {
                    if (ch < 0x20 or ch >= 0x7f) continue;
                    if (self.filter_len >= self.filter.len) break;
                    self.filter[self.filter_len] = ch;
                    self.filter_len += 1;
                }
                return true;
            },
        }
    }

    // -----------------------------------------------------------------------
    // Paint
    // -----------------------------------------------------------------------

    pub fn paint(self: *Page, cr: ?*cairo.cairo_t, g: Geo, px: f64, ly: f64, glass_ov: f64) void {
        const c = cr orelse return;
        if (!self.inited) return;
        const lay = self.layout(g);
        const now_s = wallNowS();

        self.paintActions(c, lay, px, ly);
        self.paintFilter(c, lay, px, ly);
        self.paintSummary(c, lay);

        if (lay.empty_h > 0) self.paintEmpty(c, lay);
        for (lay.groups[0..lay.n_groups]) |gg| {
            self.paintGroup(c, lay, gg, px, ly, glass_ov, now_s);
        }
        if (lay.footer_h > 0) self.paintFooter(c, lay, px, ly);
        self.paintRecipes(c, lay, px, ly);
    }

    fn paintActions(self: *Page, c: *cairo.cairo_t, lay: Layout, px: f64, ly: f64) void {
        _ = self;
        ui_paint.paintBtn(
            c,
            lay.enable_btn.x,
            lay.enable_btn.y,
            lay.enable_btn.w,
            lay.enable_btn.h,
            "Enable detected",
            inRect(px, ly, lay.enable_btn),
        );
        paintAccentBtn(c, lay.regen_btn, "Regenerate all", inRect(px, ly, lay.regen_btn));
    }

    fn paintFilter(self: *const Page, c: *cairo.cairo_t, lay: Layout, px: f64, ly: f64) void {
        const t = common.Theme;
        const f = lay.filter;

        // Field.
        ui_paint.roundRect(c, @floatFromInt(f.x), @floatFromInt(f.y), @floatFromInt(f.w), @floatFromInt(f.h), 9);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, if (self.filter_focus) 0.07 else 0.045);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_line_width(c, 1.0);
        if (self.filter_focus) {
            cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.85);
        } else {
            cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.35);
        }
        cairo.cairo_stroke(c);

        const text_y: f64 = @floatFromInt(f.y + 22);
        const text_x: f64 = @floatFromInt(f.x + 12);
        const max_w: f64 = @floatFromInt(f.w - 24);
        const ft = self.filterText();
        if (ft.len == 0) {
            ui_paint.showTextW(c, text_x, text_y, "Filter templates", 12, 400, max_w, t.text_r, t.text_g, t.text_b, 0.38);
        } else {
            ui_paint.showTextW(c, text_x, text_y, ft, 12, 500, max_w, t.text_r, t.text_g, t.text_b, 0.92);
        }

        // Caret.
        if (self.filter_focus) {
            const tw = ui_paint.measureTextWidth(ft, 12, 500);
            const caret_x = text_x + @as(f64, @floatFromInt(@min(tw + 1, f.w - 24)));
            cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.9);
            cairo.cairo_rectangle(c, caret_x, @floatFromInt(f.y + 9), 1.2, @floatFromInt(f.h - 18));
            cairo.cairo_fill(c);
        }

        // Segment strip.
        const first = lay.seg[0];
        const strip_x: i32 = first.x - 4;
        const strip_w: i32 = lay.seg[3].x + lay.seg[3].w + 4 - strip_x;
        ui_paint.roundRect(
            c,
            @floatFromInt(strip_x),
            @floatFromInt(first.y - 2),
            @floatFromInt(strip_w),
            @floatFromInt(first.h + 4),
            10,
        );
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.035);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.30);
        cairo.cairo_stroke(c);

        for (lay.seg, 0..) |r, i| {
            const seg: tmpl.Segment = @enumFromInt(i);
            const active = self.segment == seg;
            const hot = inRect(px, ly, r);
            if (active or hot) {
                ui_paint.roundRect(c, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 7);
                if (active) {
                    cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.16);
                } else {
                    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.05);
                }
                cairo.cairo_fill(c);
            }
            var cnt_buf: [12]u8 = undefined;
            const cnt = std.fmt.bufPrint(&cnt_buf, "{d}", .{self.countFor(seg)}) catch "";
            const label = tmpl.segmentLabel(seg);
            const ly_base: f64 = @floatFromInt(r.y + 20);
            const lx: f64 = @floatFromInt(r.x + k_seg_pad);
            const lw = ui_paint.measureTextWidth(label, 12, 500);
            ui_paint.showText(c, lx, ly_base, label, 12, 500, t.text_r, t.text_g, t.text_b, if (active) 0.95 else 0.55);
            ui_paint.showText(
                c,
                lx + @as(f64, @floatFromInt(lw + 5)),
                ly_base,
                cnt,
                11,
                500,
                t.text_r,
                t.text_g,
                t.text_b,
                if (active) 0.65 else 0.35,
            );
        }
    }

    fn paintSummary(self: *const Page, c: *cairo.cairo_t, lay: Layout) void {
        const t = common.Theme;
        var buf: [160]u8 = undefined;
        const enabled = self.countFor(.enabled);
        const text = std.fmt.bufPrint(&buf, "{d} of {d} enabled", .{ enabled, tmpl.template_count }) catch "";
        const max_w = @max(0, lay.enable_btn.x - lay.x - 12);
        ui_paint.showTextW(
            c,
            @floatFromInt(lay.x),
            @floatFromInt(lay.summary_y),
            text,
            12,
            400,
            @floatFromInt(max_w),
            t.text_r,
            t.text_g,
            t.text_b,
            0.45,
        );
    }

    fn paintEmpty(_: *const Page, c: *cairo.cairo_t, lay: Layout) void {
        const t = common.Theme;
        ui_paint.card(
            c,
            @floatFromInt(lay.x),
            @floatFromInt(lay.empty_y),
            @floatFromInt(lay.w),
            @floatFromInt(lay.empty_h),
            0.78,
        );
        ui_paint.showText(
            c,
            @floatFromInt(lay.x + k_pad),
            @floatFromInt(lay.empty_y + 38),
            "No templates match the current filters.",
            13,
            500,
            t.text_r,
            t.text_g,
            t.text_b,
            0.7,
        );
        ui_paint.showTextW(
            c,
            @floatFromInt(lay.x + k_pad),
            @floatFromInt(lay.empty_y + 60),
            "Clear the filter or switch back to All.",
            11,
            400,
            @floatFromInt(lay.w - 2 * k_pad),
            t.text_r,
            t.text_g,
            t.text_b,
            0.4,
        );
    }

    fn paintGroup(
        self: *Page,
        c: *cairo.cairo_t,
        lay: Layout,
        gg: GroupGeom,
        px: f64,
        ly: f64,
        glass_ov: f64,
        now_s: i64,
    ) void {
        const t = common.Theme;
        ui_paint.card(c, @floatFromInt(lay.x), @floatFromInt(gg.y), @floatFromInt(lay.w), @floatFromInt(gg.h), glass_ov);

        // Header: chevron, name, count, group switch.
        chevron(c, @floatFromInt(lay.x + 20), @floatFromInt(gg.y + @divTrunc(k_group_hdr_h, 2)), 4, gg.open, 0.5);

        const group_label = tmpl.groups[gg.group].label;
        const label_h: i32 = @intCast(ui_paint.textSizePx(c, group_label, 13, 600).h);
        const label_y: f64 = @floatFromInt(gg.y + @divTrunc(k_group_hdr_h + label_h, 2) - 2);
        ui_paint.showText(c, @floatFromInt(lay.x + 36), label_y, group_label, 13, 600, t.text_r, t.text_g, t.text_b, 0.92);
        const lw = ui_paint.measureTextWidth(group_label, 13, 600);
        var cnt_buf: [12]u8 = undefined;
        const cnt = std.fmt.bufPrint(&cnt_buf, "{d}", .{gg.n}) catch "";
        ui_paint.showText(
            c,
            @floatFromInt(lay.x + 36 + lw + 8),
            label_y,
            cnt,
            11,
            500,
            t.text_r,
            t.text_g,
            t.text_b,
            0.38,
        );
        paintGroupSwitch(c, groupSwitchRect(lay, gg), self.groupState(gg));
        if (!gg.open) return;

        var first = true;
        for (gg.rows[0..gg.n]) |r| {
            const tp = &tmpl.templates[r.tpl];
            const row_rect = Rect{ .x = lay.x, .y = r.y, .w = lay.w, .h = k_row_h };
            const row_hot = inRect(px, ly, row_rect);
            if (row_hot) {
                ui_paint.roundRect(
                    c,
                    @floatFromInt(lay.x + 6),
                    @floatFromInt(r.y + 1),
                    @floatFromInt(lay.w - 12),
                    @floatFromInt(k_row_h - 2),
                    10,
                );
                cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.035);
                cairo.cairo_fill(c);
            }
            if (!first) {
                cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.06);
                cairo.cairo_set_line_width(c, 1.0);
                cairo.cairo_move_to(c, @floatFromInt(lay.x + k_pad), @floatFromInt(r.y));
                cairo.cairo_line_to(c, @floatFromInt(lay.x + lay.w - k_pad), @floatFromInt(r.y));
                cairo.cairo_stroke(c);
            }
            first = false;

            const enabled = self.settings.matugen_templates[tp.slot];

            // Name + path, centered as one two-line block. No initial chip:
            // the letter tiles read as extra icons (user feedback).
            const text_x: i32 = lay.x + k_pad;
            const name_h: i32 = @intCast(ui_paint.textSizePx(c, tp.label, 13, 600).h);
            const path_h: i32 = @intCast(ui_paint.textSizePx(c, "Ag", 11, 400).h);
            const block_top: i32 = r.y + @divTrunc(k_row_h - (name_h + 3 + path_h), 2);
            const name_base: i32 = block_top + name_h - 2;
            const path_base: i32 = block_top + name_h + 3 + path_h - 2;
            const dc = detailsChevronRect(lay, r);
            const status_right = dc.x - 10;
            var path_buf: [512]u8 = undefined;
            var root_buf: [512]u8 = undefined;
            var disp_buf: [512]u8 = undefined;
            const raw = tmpl.activeOutput(self.probes(), tp, self.env, &path_buf, &root_buf) orelse tp.output;
            const disp = tmpl.displayPath(&disp_buf, self.env, raw);
            const path_max = @max(0, status_right - text_x - 8);
            ui_paint.showText(
                c,
                @floatFromInt(text_x),
                @floatFromInt(name_base),
                tp.label,
                13,
                600,
                t.text_r,
                t.text_g,
                t.text_b,
                if (enabled) 0.92 else 0.55,
            );
            ui_paint.showTextW(
                c,
                @floatFromInt(text_x),
                @floatFromInt(path_base),
                disp,
                11,
                400,
                @floatFromInt(path_max),
                t.text_r,
                t.text_g,
                t.text_b,
                if (enabled) 0.42 else 0.3,
            );

            // Status, right-aligned before the details chevron.
            if (self.have_status) {
                var st_buf: [24]u8 = undefined;
                const st = self.status[r.tpl];
                const st_text = tmpl.Status.text(&st_buf, st.status, st.mtime, now_s);
                const st_w = ui_paint.measureTextWidth(st_text, 12, 400);
                const st_x = @max(text_x + 60, status_right - st_w);
                const st_a: f64 = switch (st.status) {
                    .applied => 0.55,
                    .pending => 0.38,
                    .disabled => 0.36,
                    .not_detected => 0.36,
                };
                ui_paint.showText(
                    c,
                    @floatFromInt(st_x),
                    @floatFromInt(name_base),
                    st_text,
                    12,
                    400,
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    st_a,
                );
            }

            // Details chevron + switch.
            chevron(c, @floatFromInt(dc.x + @divTrunc(dc.w, 2)), @floatFromInt(dc.y + @divTrunc(dc.h, 2)), 4, r.open, if (r.open) 0.8 else 0.45);
            const sw = rowSwitchRect(lay, r);
            ui_paint.paintSwitch(c, sw.x, sw.y, sw.w, sw.h, enabled);

            if (r.open) self.paintDetail(c, lay, r, tp, px, ly);
        }
    }

    fn paintDetail(self: *Page, c: *cairo.cairo_t, lay: Layout, r: RowGeom, tp: *const tmpl.Config, px: f64, ly: f64) void {
        const t = common.Theme;
        const panel = detailRect(lay, r);
        ui_paint.roundRect(c, @floatFromInt(panel.x), @floatFromInt(panel.y), @floatFromInt(panel.w), @floatFromInt(panel.h), 10);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.035);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.22);
        cairo.cairo_stroke(c);

        var path_buf: [512]u8 = undefined;
        var root_buf: [512]u8 = undefined;
        var disp_buf: [512]u8 = undefined;
        const raw = tmpl.activeOutput(self.probes(), tp, self.env, &path_buf, &root_buf) orelse tp.output;
        const out_disp = tmpl.displayPath(&disp_buf, self.env, raw);
        const labels = [_][]const u8{ "OUTPUT PATH", "TEMPLATE FILE", "POST-APPLY HOOK" };
        const values = [_][]const u8{
            out_disp,
            tp.input,
            if (tp.hook.len > 0) tp.hook else "—",
        };

        const fx = panel.x + 12;
        const fw = panel.w - 24;
        for (labels, 0..) |label, i| {
            const row_y = panel.y + 15 + @as(i32, @intCast(i)) * 44;
            ui_paint.showText(c, @floatFromInt(fx + 2), @floatFromInt(row_y), label, 10, 600, t.text_r, t.text_g, t.text_b, 0.4);
            const box_y = row_y + 5;
            ui_paint.roundRect(c, @floatFromInt(fx), @floatFromInt(box_y), @floatFromInt(fw), @floatFromInt(k_detail_box_h), 7);
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.03);
            cairo.cairo_fill_preserve(c);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.30);
            cairo.cairo_stroke(c);
            ui_paint.showTextW(
                c,
                @floatFromInt(fx + 10),
                @floatFromInt(box_y + 18),
                values[i],
                12,
                400,
                @floatFromInt(fw - 20),
                t.text_r,
                t.text_g,
                t.text_b,
                0.88,
            );
        }

        const pb = detailBtnRect(lay, r);
        ui_paint.paintBtn(c, pb.x, pb.y, pb.w, pb.h, "Apply now", inRect(px, ly, pb));
    }

    fn paintFooter(self: *const Page, c: *cairo.cairo_t, lay: Layout, px: f64, ly: f64) void {
        const t = common.Theme;
        var buf: [160]u8 = undefined;
        const off = self.countFor(.off_system);
        const text = if (self.show_all)
            std.fmt.bufPrint(&buf, "Showing every template · {d} are for apps not on this system.", .{off}) catch ""
        else
            std.fmt.bufPrint(&buf, "{d} of {d} templates are for apps not detected.", .{ off, tmpl.template_count }) catch "";
        ui_paint.showTextW(
            c,
            @floatFromInt(lay.x),
            @floatFromInt(lay.footer_y + 22),
            text,
            12,
            400,
            @floatFromInt(lay.w - lay.show_all.w - 12),
            t.text_r,
            t.text_g,
            t.text_b,
            0.42,
        );

        const label = if (self.show_all) "Detected only" else "Show all";
        const hot = inRect(px, ly, lay.show_all);
        const lw = ui_paint.measureTextWidth(label, 12, 600);
        const tx = lay.show_all.x + lay.show_all.w - lw;
        ui_paint.showText(
            c,
            @floatFromInt(tx),
            @floatFromInt(lay.show_all.y + 18),
            label,
            12,
            600,
            t.acc_r,
            t.acc_g,
            t.acc_b,
            if (hot) 1.0 else 0.85,
        );
        if (hot) {
            cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.8);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_move_to(c, @floatFromInt(tx), @floatFromInt(lay.show_all.y + 22));
            cairo.cairo_line_to(c, @floatFromInt(tx + lw), @floatFromInt(lay.show_all.y + 22));
            cairo.cairo_stroke(c);
        }
    }

    fn paintRecipes(self: *const Page, c: *cairo.cairo_t, lay: Layout, px: f64, ly: f64) void {
        const t = common.Theme;
        ui_paint.card(
            c,
            @floatFromInt(lay.recipes.x),
            @floatFromInt(lay.recipes.y),
            @floatFromInt(lay.recipes.w),
            @floatFromInt(lay.recipes.h),
            0.78,
        );
        ui_paint.showText(
            c,
            @floatFromInt(lay.recipes.x + k_pad),
            @floatFromInt(lay.recipes.y + 24),
            "Use base.toml recipes",
            13,
            600,
            t.text_r,
            t.text_g,
            t.text_b,
            0.9,
        );
        ui_paint.showTextW(
            c,
            @floatFromInt(lay.recipes.x + k_pad),
            @floatFromInt(lay.recipes.y + 41),
            "Merge the bundled base recipes into every apply.",
            11,
            400,
            @floatFromInt(lay.w - k_pad * 2 - k_switch_w - 12),
            t.text_r,
            t.text_g,
            t.text_b,
            0.42,
        );
        ui_paint.paintSwitch(
            c,
            lay.recipes_switch.x,
            lay.recipes_switch.y,
            lay.recipes_switch.w,
            lay.recipes_switch.h,
            self.settings.matugen_base_recipes,
        );
        _ = inRect(px, ly, lay.recipes); // hover tint is already the card's own
    }
};

// ---------------------------------------------------------------------------
// Geometry helpers shared by paint and hit.
// ---------------------------------------------------------------------------

fn groupSwitchRect(lay: Layout, gg: GroupGeom) Rect {
    return .{
        .x = lay.x + lay.w - k_pad - k_group_switch_w,
        .y = gg.y + @divTrunc(k_group_hdr_h - k_group_switch_h, 2),
        .w = k_group_switch_w,
        .h = k_group_switch_h,
    };
}

fn rowSwitchRect(lay: Layout, r: RowGeom) Rect {
    return .{
        .x = lay.x + lay.w - k_pad - k_switch_w,
        .y = r.y + @divTrunc(k_row_h - k_switch_h, 2),
        .w = k_switch_w,
        .h = k_switch_h,
    };
}

fn detailsChevronRect(lay: Layout, r: RowGeom) Rect {
    return .{
        .x = lay.x + lay.w - k_pad - k_switch_w - 8 - k_details_w,
        .y = r.y + @divTrunc(k_row_h - k_details_w, 2),
        .w = k_details_w,
        .h = k_details_w,
    };
}

fn detailRect(lay: Layout, r: RowGeom) Rect {
    return .{
        .x = lay.x + 12,
        .y = r.y + k_row_h + k_detail_gap,
        .w = lay.w - 24,
        .h = k_detail_h,
    };
}

fn detailBtnRect(lay: Layout, r: RowGeom) Rect {
    const panel = detailRect(lay, r);
    return .{
        .x = panel.x + panel.w - 12 - 108,
        .y = panel.y + k_detail_h - 12 - 26,
        .w = 108,
        .h = 26,
    };
}

// ---------------------------------------------------------------------------
// Painting primitives local to this page.
// ---------------------------------------------------------------------------

/// Filled accent pill (the mockup's "Regenerate all"), label in the window
/// surface colour so it reads on both light and dark accents.
fn paintAccentBtn(c: *cairo.cairo_t, r: Rect, label: []const u8, hovered: bool) void {
    const t = common.Theme;
    const xf: f64 = @floatFromInt(r.x);
    const yf: f64 = @floatFromInt(r.y);
    const wf: f64 = @floatFromInt(r.w);
    const hf: f64 = @floatFromInt(r.h);
    ui_paint.glassBox(c, xf, yf, wf, hf, hf / 2.0, t.acc_r, t.acc_g, t.acc_b, if (hovered) 1.0 else 0.92);
    if (hovered) {
        ui_paint.roundRect(c, xf, yf, wf, hf, hf / 2.0);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.10);
        cairo.cairo_fill(c);
    }
    const ts = ui_paint.textSizePx(c, label, 12, 600);
    const tw: f64 = @floatFromInt(ts.w);
    const th: f64 = @floatFromInt(ts.h);
    const lx = xf + (wf - tw) / 2.0;
    const top = yf + (hf - th) / 2.0;
    ui_paint.showText(c, lx, top + th - 2.0, label, 12, 600, t.bg_r, t.bg_g, t.bg_b, 0.95);
}

/// Group switch with a third "mixed" state — off/on/mixed (knob left, right,
/// centred) so a partly-enabled family reads correctly before the first
/// click resolves it to all-on.
fn paintGroupSwitch(c: *cairo.cairo_t, r: Rect, st: Page.GroupState) void {
    const t = common.Theme;
    const xf: f64 = @floatFromInt(r.x);
    const yf: f64 = @floatFromInt(r.y);
    const wf: f64 = @floatFromInt(r.w);
    const hf: f64 = @floatFromInt(r.h);
    if (st == .off) {
        ui_paint.glassBox(c, xf, yf, wf, hf, hf / 2.0, 1, 1, 1, 0.06);
        cairo.cairo_save(c);
        ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, hf / 2.0 - 0.5);
        cairo.cairo_set_line_width(c, 1.2);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.7);
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);
    } else {
        const a: f64 = if (st == .on) 1.0 else 0.55;
        ui_paint.glassBox(c, xf, yf, wf, hf, hf / 2.0, t.acc_r, t.acc_g, t.acc_b, a);
    }
    const knob_r: f64 = hf * 0.34;
    const kx = switch (st) {
        .off => xf + hf * 0.5,
        .on => xf + wf - hf * 0.5,
        .mixed => xf + wf * 0.5,
    };
    ui_paint.glassBox(c, kx - knob_r, yf + hf / 2.0 - knob_r, knob_r * 2, knob_r * 2, knob_r, 1, 1, 1, 1.0);
}

/// Disclosure chevron drawn as two strokes: `>` closed, `v` open.
fn chevron(c: *cairo.cairo_t, cx: f64, cy: f64, half: f64, down: bool, alpha: f64) void {
    const t = common.Theme;
    cairo.cairo_set_line_width(c, 1.5);
    cairo.cairo_set_line_cap(c, 1); // CAIRO_LINE_CAP_ROUND
    cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, alpha);
    if (down) {
        cairo.cairo_move_to(c, cx - half, cy - half * 0.5);
        cairo.cairo_line_to(c, cx, cy + half * 0.5);
        cairo.cairo_line_to(c, cx + half, cy - half * 0.5);
    } else {
        cairo.cairo_move_to(c, cx - half * 0.5, cy - half);
        cairo.cairo_line_to(c, cx + half * 0.5, cy);
        cairo.cairo_line_to(c, cx - half * 0.5, cy + half);
    }
    cairo.cairo_stroke(c);
}

// ---------------------------------------------------------------------------
// Runtime probes (process env, PATH, filesystem).
// ---------------------------------------------------------------------------

fn sysEnv(_: ?*anyopaque, name: []const u8) []const u8 {
    var buf: [128]u8 = undefined;
    const n = @min(name.len, buf.len - 1);
    @memcpy(buf[0..n], name[0..n]);
    buf[n] = 0;
    const z: [*:0]const u8 = @ptrCast(&buf);
    const raw = std.c.getenv(z) orelse return "";
    return std.mem.span(raw);
}

/// `exeOnPath`: every `PATH` dir, `access(…, X_OK)` on the candidate.
fn sysBin(_: ?*anyopaque, name: []const u8) bool {
    if (name.len == 0) return false;
    const path_env = sysEnv(null, "PATH");
    if (path_env.len == 0) return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    var cand: [4096]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0 or dir.len + 1 + name.len + 1 > cand.len) continue;
        @memcpy(cand[0..dir.len], dir);
        cand[dir.len] = '/';
        @memcpy(cand[dir.len + 1 ..][0..name.len], name);
        cand[dir.len + 1 + name.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&cand);
        if (linux.access(z, linux.X_OK) == 0) return true;
    }
    return false;
}

fn sysPath(ctx: ?*anyopaque, p: []const u8) bool {
    const self: *Page = @ptrCast(@alignCast(ctx.?));
    _ = std.Io.Dir.cwd().statFile(self.io, p, .{}) catch return false;
    return true;
}

fn sysMtime(ctx: ?*anyopaque, p: []const u8) i64 {
    const self: *Page = @ptrCast(@alignCast(ctx.?));
    const st = std.Io.Dir.cwd().statFile(self.io, p, .{}) catch return 0;
    const ns: i128 = st.mtime.nanoseconds;
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, std.time.ns_per_s));
}

/// Wall clock in seconds — the same epoch the file mtimes use.
fn wallNowS() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @intCast(@max(ts.sec, 0));
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_geo = Geo{ .content_x = common.content_x, .content_w = 498, .win_h = 980 };

fn testPage(settings: *app_mod.Settings) Page {
    var p = Page{};
    p.io = std.testing.io;
    p.settings = settings;
    p.inited = true;
    p.filter = undefined;
    return p;
}

test "templates page: group row cap fits the registry" {
    const t = std.testing;
    var s = app_mod.Settings{};
    const p = testPage(&s);
    var counts = [_]usize{0} ** tmpl.group_count;
    for (tmpl.templates) |tp| counts[tp.group] += 1;
    var max_rows: usize = 0;
    for (counts) |c| max_rows = @max(max_rows, c);
    try t.expectEqual(max_rows, k_max_group_rows);
    _ = p;
}

test "templates page: layout stacks every open group without overlap" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    const lay = p.layout(test_geo);

    try t.expectEqual(@as(u8, tmpl.group_count), lay.n_groups);
    try t.expect(lay.bottom > 1500);
    var prev_bottom: i32 = lay.groups_y;
    for (lay.groups[0..lay.n_groups]) |gg| {
        try t.expect(gg.y >= prev_bottom);
        try t.expect(gg.h > k_group_hdr_h);
        prev_bottom = gg.y + gg.h;
    }
    // The scroll extent ends below the last card.
    try t.expect(lay.bottom > prev_bottom);
    try t.expectEqual(lay.bottom, p.totalHeight(test_geo));
}

test "templates page: a closed group collapses to its header" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    p.expanded[0] = false;
    const lay = p.layout(test_geo);
    const g0 = lay.groups[0];
    try t.expect(!g0.open);
    try t.expectEqual(k_group_hdr_h, g0.h);
    // And the next group starts a gap below it.
    try t.expect(lay.groups[1].y == g0.y + g0.h + k_group_gap);
}

test "templates page: an open detail panel grows its group by the panel" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    const closed = p.layout(test_geo).groups[0].h;
    p.open_slot = tmpl.templates[p.layout(test_geo).groups[0].rows[0].tpl].slot;
    const open = p.layout(test_geo).groups[0].h;
    try t.expectEqual(closed + k_detail_h + k_detail_gap, open);
    // The panel is single-open: opening a second row closes the first.
    const lay = p.layout(test_geo);
    const other = lay.groups[0].rows[1];
    try t.expect( p.hit(test_geo, @floatFromInt(lay.x + 100), @floatFromInt(other.y + 10)) != null);
}

test "templates page: text filter keeps only matching rows and forces groups open" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    p.expanded[1] = false;
    const needle = "kitty";
    @memcpy(p.filter[0..needle.len], needle);
    p.filter_len = needle.len;

    const lay = p.layout(test_geo);
    try t.expectEqual(@as(u8, 1), lay.n_groups);
    try t.expectEqual(@as(u8, 1), lay.groups[0].group);
    try t.expectEqual(@as(u8, 2), lay.groups[0].n);
    try t.expect(lay.groups[0].open); // filtering overrides the stored collapse
}

test "templates page: off-system rows hide by default and return with Show all" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    p.detected[0] = false; // Niri
    const hidden = p.layout(test_geo);
    try t.expectEqual(@as(u8, 2), hidden.groups[0].n);
    try t.expect(hidden.footer_h > 0);
    try t.expectEqual(@as(usize, 1), p.countFor(.off_system));

    p.show_all = true;
    const shown = p.layout(test_geo);
    try t.expectEqual(@as(u8, 3), shown.groups[0].n);

    // The Off-system segment always lists them.
    p.show_all = false;
    p.segment = .off_system;
    const off = p.layout(test_geo);
    try t.expectEqual(@as(u8, 1), off.n_groups);
    try t.expectEqual(@as(u8, 1), off.groups[0].n);
}

test "templates page: empty result paints the empty card" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    p.segment = .disabled; // everything is on by default
    const lay = p.layout(test_geo);
    try t.expectEqual(@as(u8, 0), lay.n_groups);
    try t.expectEqual(k_empty_h, lay.empty_h);
    try t.expect(lay.bottom > lay.empty_y + k_empty_h);
}

test "templates page: row switch, group switch and header toggles" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    var lay = p.layout(test_geo);

    // Row switch: the first row's switch flips its settings bit.
    const r0 = lay.groups[0].rows[0];
    const slot0 = tmpl.templates[r0.tpl].slot;
    const sw = rowSwitchRect(lay, r0);
    const act = p.hit(test_geo, @floatFromInt(sw.x + 5), @floatFromInt(sw.y + 5));
    try t.expect(act != null and act.? == .persist);
    try t.expect(!s.matugen_templates[slot0]);

    // Group header: expands/collapses without touching switches.
    const g0 = lay.groups[0];
    const before = p.expanded[0];
    const hdr_act = p.hit(test_geo, @floatFromInt(lay.x + 100), @floatFromInt(g0.y + 20));
    try t.expect(hdr_act != null and hdr_act.? == .repaint);
    try t.expectEqual(!before, p.expanded[0]);

    // Group switch: after re-layout the header switch sets the whole family.
    p.expanded[0] = true;
    lay = p.layout(test_geo);
    const gsw = groupSwitchRect(lay, lay.groups[0]);
    const gact = p.hit(test_geo, @floatFromInt(gsw.x + 5), @floatFromInt(gsw.y + 5));
    try t.expect(gact != null and gact.? == .persist);
    for (lay.groups[0].rows[0..lay.groups[0].n]) |r| {
        try t.expect(s.matugen_templates[tmpl.templates[r.tpl].slot]);
    }
    // The mixed → all-on click leaves the group uniformly on.
    try t.expectEqual(Page.GroupState.on, p.groupState(lay.groups[0]));
}

test "templates page: details chevron opens a single panel" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    var lay = p.layout(test_geo);
    const r0 = lay.groups[0].rows[0];
    const dc = detailsChevronRect(lay, r0);
    const act = p.hit(test_geo, @floatFromInt(dc.x + 5), @floatFromInt(dc.y + 5));
    try t.expect(act != null and act.? == .repaint);
    try t.expectEqual(tmpl.templates[r0.tpl].slot, @as(usize, @intCast(p.open_slot)));
    lay = p.layout(test_geo);
    try t.expect(lay.groups[0].rows[0].open);

    // Clicking the same chevron again closes it.
    const dc2 = detailsChevronRect(lay, lay.groups[0].rows[0]);
    _ = p.hit(test_geo, @floatFromInt(dc2.x + 5), @floatFromInt(dc2.y + 5));
    try t.expectEqual(@as(i32, -1), p.open_slot);
}

test "templates page: base recipes row toggles the recipes flag" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    const lay = p.layout(test_geo);
    try t.expect(s.matugen_base_recipes);
    const act = p.hit(test_geo, @floatFromInt(lay.recipes.x + 40), @floatFromInt(lay.recipes.y + 20));
    try t.expect(act != null and act.? == .persist);
    try t.expect(!s.matugen_base_recipes);
}

test "templates page: filter keyboard (type, backspace, escape)" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    try t.expect(!p.key(xkb.XKB_KEY_BackSpace, ""));
    p.filter_focus = true;
    try t.expect(p.key(xkb.XKB_KEY_a, "a"));
    try t.expect(p.key(xkb.XKB_KEY_b, "b"));
    try t.expectEqualStrings("ab", p.filterText());
    try t.expect(p.key(xkb.XKB_KEY_BackSpace, ""));
    try t.expectEqualStrings("a", p.filterText());
    try t.expect(p.key(xkb.XKB_KEY_Escape, ""));
    try t.expectEqualStrings("", p.filterText());
    try t.expect(!p.filter_focus);
    // Non-printable input is dropped, not stored.
    p.filter_focus = true;
    _ = p.key(xkb.XKB_KEY_Left, "");
    try t.expectEqualStrings("", p.filterText());
}

test "templates page: segment counts and selection" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    try t.expectEqual(@as(usize, 37), p.countFor(.all));
    try t.expectEqual(@as(usize, 37), p.countFor(.enabled));
    try t.expectEqual(@as(usize, 0), p.countFor(.disabled));
    try t.expectEqual(@as(usize, 0), p.countFor(.off_system));

    const lay = p.layout(test_geo);
    const seg1 = lay.seg[2]; // Disabled
    const act = p.hit(test_geo, @floatFromInt(seg1.x + 4), @floatFromInt(seg1.y + 4));
    try t.expect(act != null and act.? == .repaint);
    try t.expectEqual(tmpl.Segment.disabled, p.segment);
}

test "templates page: filter matches label, template file and output path" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var p = testPage(&s);
    const niri = tmpl.bySlot(0);
    try t.expect(p.matchesText(niri)); // empty filter matches everything
    p.filter[0] = 'n';
    p.filter[1] = 'i';
    p.filter_len = 2;
    try t.expect(p.matchesText(niri));
    p.filter[0] = 'g';
    p.filter[1] = 't';
    p.filter[2] = 'k';
    p.filter_len = 3;
    var saw_gtk = false;
    for (&tmpl.templates) |*tp| {
        if (std.mem.indexOf(u8, tp.output, "gtk-4.0") == null) continue;
        saw_gtk = true;
        try t.expect(p.matchesText(tp));
    }
    try t.expect(saw_gtk);
}
