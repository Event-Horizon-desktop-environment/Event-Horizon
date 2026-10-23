//! Fullscreen workspace overview surface.
//!
//! One overlay layer surface per open: dimmed output, a centered workspace
//! card per workspace holding its window tiles, the top search bar, the
//! bottom apps pill, and the quick-select rail. The dock owns the data —
//! windows arrive as borrowed snapshots, icons through a lookup — so this
//! file never touches a backend and never outlives a paint.

const std = @import("std");
const layer = @import("../../wl/surface/layer.zig");
const shm_mod = @import("../../wl/buffer/shm.zig");
const wl = @import("../../wl/c.zig").wl;
const cairo_helpers = @import("../shared/cairo_helpers.zig");
const ns = @import("../common/namespaces.zig");
const seat_mod = @import("../../wl/seat.zig");
const types = @import("types.zig");
const lay = @import("layout.zig");
const pick = @import("pick.zig");
const paint = @import("paint.zig");
const dw = @import("../dock/widgets_paint.zig");
const tiles = @import("tiles.zig");
const strip = @import("strip.zig");
const backdrop = @import("backdrop.zig");
const apps_mod = @import("apps.zig");
const gridpaint = @import("grid_paint.zig");
const gridmod = @import("grid.zig");
const logz = @import("../../logz.zig");

fn nowMs() u64 {
    return nowUs() / 1000;
}

fn nowUs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000000 + @as(u64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000)));
}

fn ms(us: u64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

/// How close to the screen edge a dragged window must get before the strip
/// starts advancing (scaled by the shell UI scale), and the peak speed in
/// cards per second once the pointer is hard against the edge.
const drag_edge_zone: f64 = 64.0;
const drag_edge_cards_per_s: f64 = 2.2;

const Layout = types.Layout;
const Colors = types.Colors;

pub const Win = struct {
    addr: []const u8 = "",
    app_id: []const u8 = "",
    title: []const u8 = "",
    focused: bool = false,
    box: types.WinBox = .{},
};

pub const Card = struct {
    id: i32 = 0,
    label: []const u8 = "",
    active: bool = false,
    /// The monitor this workspace sits on, borrowed like the label: the
    /// key the shot store answers by.
    monitor: []const u8 = "",
    wins: []Win = &.{},
};

pub const Action = union(enum) {
    none,
    refresh,
    dismiss,
    focus: usize,
    close_win: usize,
    select_ws: i32,
    add_ws,
    apps,
    launch_app: usize,
    launch_modal: usize,
    move_win: struct { flat: usize, ws: i32 },
    move_win_new: usize,
    swap_wins: struct { a: usize, b: usize },
    ctx_menu: struct { x: f64, y: f64, path: []const u8 },
    ctx_dock: []const u8,
    ctx_taskbar: []const u8,
};

pub const IconLookup = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, app_id: []const u8) ?tiles.IconPx,
};

/// Where a window's captured frame comes from at paint time. The capture
/// store answers by window address; a miss falls back to the tinted tile.
pub const FrameLookup = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, addr: []const u8) ?tiles.LiveFrame,
};

/// Where a workspace's screen shot comes from at paint time. The shots
/// store answers by monitor name; a miss falls back to the card's fill.
pub const ShotLookup = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, monitor: []const u8) ?tiles.LiveFrame,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    surface: layer.Surface = .{},
    shm: shm_mod.ShmPair,
    frame_buf: ?*shm_mod.ShmBuffer = null,
    open: bool = false,
    buf_w: i32 = 0,
    buf_h: i32 = 0,
    ui: f64 = 1,
    layout: Layout = .{},
    colors: Colors = .{},
    cards: []Card = &.{},
    scroll: f64 = 0,
    /// Layout knobs from `[appearance]`, set by the owner before open:
    /// axis the strip flows along, card scale (0.2..0.8), card gap px,
    /// close-button px, search-bar px. Defaults mirror the schema.
    axis: types.Axis = .vertical,
    card_scale: f64 = 0.5,
    card_gap: f64 = 24,
    close_sz: f64 = 34,
    search_w: f64 = 420,
    /// Where the scroll is easing to. Wheel ticks move the target a whole
    /// card; `scrollTick` glides `scroll` after it every pulse, so motion
    /// is smooth instead of teleporting a card per tick.
    scroll_target: f64 = 0,
    apps_scroll_target: f64 = 0,
    modal_scroll_target: f64 = 0,
    /// Pending card snap after a finger glide lifts: applied once the
    /// settle delay passes, so a chained gesture keeps flowing instead
    /// of snapping mid-motion. Zero when nothing is pending.
    snap_at_ms: u64 = 0,
    /// Rail scroll position and target: the thumb column glides exactly
    /// like the cards once it outgrows the strip.
    qs_scroll: f64 = 0,
    qs_scroll_target: f64 = 0,
    qs_wheel_accum: f64 = 0,
    /// Trackpad settle delay before the snap above applies.
    scroll_delay_ms: f64 = 200,
    /// Vsync pulse hook: fired from the frame callback with the
    /// compositor's timestamp. Set alongside `frame_ctx` by the owner.
    on_frame: ?*const fn (ctx: *anyopaque, time_ms: u32) void = null,
    frame_ctx: *anyopaque = undefined,
    /// Outstanding frame callback, if any. At most one: each commit that
    /// wants a follow-up requests it, and the callback re-arms only
    /// while work remains.
    frame_cb: ?*wl.wl_callback = null,
    wheel_accum: f64 = 0,
    hovered_ws: i32 = -1,
    hovered_win: i32 = -1,
    close_hovered: bool = false,
    hovered_qs: i32 = -1,
    icons: ?IconLookup = null,
    frames: ?FrameLookup = null,
    shots: ?ShotLookup = null,
    /// Pre-scaled capture surfaces: every shot and frame is scaled once
    /// per target size, then blitted 1:1, instead of rescaling the
    /// compositor-sized copies on the CPU every paint.
    scaled: tiles.ScaledCache = undefined,
    /// The card fill-plus-glass baked once per card size. Every card
    /// shares one size, so one blit replaces five gradient repaints.
    card_chrome: ?*cairo.cairo_surface_t = null,
    card_chrome_w: i32 = 0,
    card_chrome_h: i32 = 0,
    /// Chrome plus the wallpaper fitted over it, composed once per card
    /// size and wallpaper generation: one blit per card per paint
    /// instead of two.
    card_base: ?*cairo.cairo_surface_t = null,
    card_base_w: i32 = 0,
    card_base_h: i32 = 0,
    card_base_wpgen: u64 = 0,
    /// The desktop wallpaper as a card-sized frame, borrowed from the shots
    /// store. Occupied cards paint it behind their tiles; empty cards fall
    /// back to it when their monitor has no shot.
    wallpaper_frame: ?tiles.LiveFrame = null,
    wallpaper: []const u8 = "",
    app_theme: []const u8 = "",
    base: backdrop.Backdrop,
    show_apps: bool = false,
    /// Appearance → Opacity: `overlay_opacity_launchpad` as a 0–1 scale for
    /// the launchpad page (the apps grid, its search field, dots, back
    /// button). `bin/overview.zig` sets it from the loaded config at boot —
    /// the process is spawned fresh per toggle. 1.0 is the default look.
    launchpad_alpha: f64 = 1.0,
    /// Appearance → Opacity "Overview": the alpha the backdrop (wallpaper
    /// capture and its dim) is painted through — 0% shows the live desktop,
    /// 100% the designed cover. `bin/overview.zig` supplies it at boot.
    overview_alpha: f64 = 1.0,
    apps: apps_mod.Apps,
    apps_wheel_accum: f64 = 0,
    /// Press/drag machine. A press records its target; 8px of motion turns
    /// it into a drag with a floating ghost, release decides the drop.
    button_pressed: bool = false,
    press_x: f64 = 0,
    press_y: f64 = 0,
    press_ws: i32 = -1,
    press_win: i32 = -1,
    press_app: i32 = -1,
    press_app_modal: bool = false,
    drag_active: bool = false,
    drag_grab_dx: f64 = 0,
    drag_grab_dy: f64 = 0,
    drop_ws: i32 = -1,
    drop_win: i32 = -1,
    drop_add: bool = false,
    drop_cell: i32 = -1,
    drop_center: bool = false,
    drop_px: f64 = 0,
    drop_py: f64 = 0,
    /// Ctrl held at press: the one gesture that still makes a new folder
    /// from an app-onto-app drop (plain drops only reorder or move in).
    drop_ctrl: bool = false,
    /// Drag edge auto-scroll: while a window drag hovers near the strip's
    /// leading/trailing screen edge, the strip keeps advancing so off-screen
    /// workspaces stay reachable without releasing the tile. `drag_edge_dir`
    /// is -1 toward earlier cards, +1 toward later; `drag_edge_t` is 0..1
    /// penetration into the edge zone and drives the speed ramp.
    drag_edge_dir: i32 = 0,
    drag_edge_t: f64 = 0,
    hovered_search: bool = false,
    hovered_apps_btn: bool = false,
    /// Shuffle snapshot: pre-drop cell origins by item key + start ms.
    shuffle_keys: std.ArrayList([]const u8) = .empty,
    shuffle_x: std.ArrayList(f64) = .empty,
    shuffle_y: std.ArrayList(f64) = .empty,
    shuffle_modal: bool = false,
    shuffle_start_ms: u64 = 0,
    shuffle_buf: [64]gridpaint.ShuffleFrom = undefined,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Self {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .shm = shm_mod.ShmPair.init(gpa),
            .base = backdrop.Backdrop.init(gpa),
            .apps = apps_mod.Apps.init(gpa, io),
            .scaled = tiles.ScaledCache.init(gpa),
        };
    }

    pub fn deinit(self: *Self) void {
        self.reset();
        self.scaled.deinit();
        self.dropCardChrome();
        self.dropCardBase();
        self.shuffle_keys.deinit(self.gpa);
        self.shuffle_x.deinit(self.gpa);
        self.shuffle_y.deinit(self.gpa);
        self.arena.deinit();
        self.shm.deinit();
        self.base.deinit();
        self.apps.deinit();
    }

    pub fn reset(self: *Self) void {
        self.surface.destroy();
        if (self.frame_cb) |cb| {
            wl.wl_callback_destroy(cb);
            self.frame_cb = null;
        }
        self.open = false;
        self.buf_w = 0;
        self.buf_h = 0;
        self.cards = &.{};
        self.scroll = 0;
        self.scroll_target = 0;
        self.apps_scroll_target = 0;
        self.modal_scroll_target = 0;
        self.qs_scroll = 0;
        self.qs_scroll_target = 0;
        self.qs_wheel_accum = 0;
        _ = self.arena.reset(.free_all);
        if (self.wallpaper.len > 0) self.gpa.free(self.wallpaper);
        self.wallpaper = "";
        if (self.app_theme.len > 0) self.gpa.free(self.app_theme);
        self.app_theme = "";
        self.hovered_ws = -1;
        self.hovered_win = -1;
        self.close_hovered = false;
        self.hovered_qs = -1;
        self.hovered_search = false;
        self.hovered_apps_btn = false;
        self.button_pressed = false;
        self.drag_active = false;
        self.press_ws = -1;
        self.press_win = -1;
        self.press_app = -1;
        self.drop_ws = -1;
        self.drop_win = -1;
        self.drop_add = false;
        self.drop_cell = -1;
        self.drag_edge_dir = 0;
        self.drag_edge_t = 0;
        self.clearShuffle();
        self.show_apps = false;
        self.apps_wheel_accum = 0;
        self.frame_buf = null;
    }

    fn clearShuffle(self: *Self) void {
        for (self.shuffle_keys.items) |k| self.gpa.free(k);
        self.shuffle_keys.clearRetainingCapacity();
        self.shuffle_x.clearRetainingCapacity();
        self.shuffle_y.clearRetainingCapacity();
        self.shuffle_start_ms = 0;
    }

    /// Theme the launchpad resolves icons with. Kept here (owned) so
    /// typing can enter search without asking the dock mid-keystroke.
    pub fn setAppTheme(self: *Self, theme: []const u8) void {
        if (self.app_theme.len > 0) self.gpa.free(self.app_theme);
        self.app_theme = self.gpa.dupe(u8, theme) catch "";
    }

    /// Enter or leave the launchpad. Entering ensures the catalog, lays
    /// the grid out for the matches, and starts at the top.
    pub fn toggleApps(self: *Self, theme: []const u8) void {
        self.show_apps = !self.show_apps;
        self.apps.closeCtx();
        if (!self.show_apps) {
            self.apps.hovered = -1;
            return;
        }
        const t0 = nowMs();
        self.apps.ensureLoaded(theme);
        self.apps.clearQuery();
        self.apps.refresh();
        self.apps.closeFolder();
        self.apps.rename.cancel();
        self.apps.hovered = -1;
        self.apps.scroll = 0;
        self.apps_wheel_accum = 0;
        self.relayout();
        logz.log("overview: apps catalog ready in {d}ms, {d} entries", .{ nowMs() - t0, self.apps.catalog.entries.len });
    }

    fn layoutAppsGrid(self: *Self) void {
        gridmod.computeGrid(
            &self.layout.grid,
            @floatFromInt(self.buf_w),
            @floatFromInt(self.buf_h),
            self.layout.search_y,
            self.layout.ui,
            @intCast(self.apps.folders.items.len),
            0,
        );
        self.apps.scroll = @min(self.apps.scroll, self.layout.grid.scroll_max);
        if (self.apps.modalOpen()) {
            gridmod.computeModal(
                &self.layout.modal,
                @floatFromInt(self.buf_w),
                @floatFromInt(self.buf_h),
                self.layout.ui,
                @intCast(self.apps.modalCount()),
            );
            self.apps.modal_scroll = @min(self.apps.modal_scroll, self.layout.modal.scroll_max);
        }
    }

    /// Grid being interacted with: folder modal when open, else main.
    fn activeCount(self: *Self) usize {
        return if (self.apps.modalOpen()) self.apps.modalCount() else self.apps.folders.items.len;
    }

    pub fn openHost(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        output: ?*wl.wl_output,
        ui: f64,
        wallpaper: []const u8,
    ) bool {
        self.reset();
        self.ui = ui;
        if (wallpaper.len > 0) {
            self.wallpaper = self.gpa.dupe(u8, wallpaper) catch "";
        }
        if (!self.surface.create(compositor, shell, output, .overlay, ns.overview)) {
            self.reset();
            return false;
        }
        self.surface.setAnchor(layer.Anchor.top | layer.Anchor.bottom | layer.Anchor.left | layer.Anchor.right);
        self.surface.setExclusiveZone(-1);
        self.surface.setSize(0, 0);
        self.surface.setKeyboardInteractivity(2);
        self.surface.commit();
        self.open = true;
        return true;
    }

    pub fn configured(self: *Self, wlshm: ?*wl.wl_shm, w: i32, h: i32) void {
        if (!self.open or w <= 0 or h <= 0) return;
        self.buf_w = w;
        self.buf_h = h;
        // `buf_w`/`buf_h` stay logical (relayout and paint draw in them); only
        // the buffer is allocated at device pixels.
        if (!self.shm.ensure(wlshm, "overview", w * self.surface.scale, h * self.surface.scale)) return;
        self.base.ensure(self.wallpaper);
        self.relayout();
        self.refresh();
    }

    fn relayout(self: *Self) void {
        lay.compute(
            &self.layout,
            @floatFromInt(self.buf_w),
            @floatFromInt(self.buf_h),
            @intCast(self.cards.len),
            self.ui,
            self.axis,
            @min(0.8, @max(0.2, self.card_scale)),
            @min(80.0, @max(8.0, self.card_gap)),
            @min(60.0, @max(20.0, self.close_sz)),
            @min(800.0, @max(200.0, self.search_w)),
        );
        self.centerActive();
        self.layoutAppsGrid();
        // A relayout can shrink the rail's scroll range; keep the rail
        // offsets inside it so thumbs never strand off-strip.
        self.qs_scroll_target = @min(self.layout.strip.scroll_max, @max(0.0, self.qs_scroll_target));
        self.qs_scroll = @min(self.layout.strip.scroll_max, @max(0.0, self.qs_scroll));
    }

    /// Centers the active card in the strip. Runs on data and on configure:
    /// either one re-pitches the strip, and a scroll from the old pitch
    /// would strand the cards off-screen.
    fn centerActive(self: *Self) void {
        var active: i32 = 0;
        for (self.cards, 0..) |c, i| {
            if (c.active) active = @intCast(i);
        }
        self.scroll = @as(f64, @floatFromInt(active)) * self.layout.pitch;
        self.scroll_target = self.scroll;
    }

    /// Glide every scroll position a step toward its target. True when
    /// anything moved this step — the owner repaints, and keeps its pulse
    /// running while `scrollActive` still holds.
    pub fn scrollTick(self: *Self, dt_s: f64) bool {
        const rate = 32.0;
        const eps = 0.25;
        const factor = std.math.exp(-rate * @max(0.0, dt_s));
        var moved = false;
        moved = easeTowards(&self.scroll, self.scroll_target, factor, eps) or moved;
        moved = easeTowards(&self.apps.scroll, self.apps_scroll_target, factor, eps) or moved;
        moved = easeTowards(&self.apps.modal_scroll, self.modal_scroll_target, factor, eps) or moved;
        moved = easeTowards(&self.qs_scroll, self.qs_scroll_target, factor, eps) or moved;
        return moved;
    }

    /// True while any scroll position still chases its target.
    pub fn scrollActive(self: *const Self) bool {
        return self.scroll != self.scroll_target or
            self.apps.scroll != self.apps_scroll_target or
            self.apps.modal_scroll != self.modal_scroll_target or
            self.qs_scroll != self.qs_scroll_target;
    }

    fn easeTowards(pos: *f64, target: f64, factor: f64, eps: f64) bool {
        if (pos.* == target) return false;
        pos.* = target + (pos.* - target) * factor;
        if (@abs(pos.* - target) <= eps) pos.* = target;
        return true;
    }

    /// Deep copy borrowed cards into the arena. Resets hover and centers
    /// the active card in the strip.
    pub fn setCards(self: *Self, cards: []const Card) void {
        _ = self.arena.reset(.free_all);
        const al = self.arena.allocator();
        const out = al.alloc(Card, cards.len) catch {
            self.cards = &.{};
            return;
        };
        for (cards, 0..) |c, i| {
            const wins = al.alloc(Win, c.wins.len) catch {
                self.cards = &.{};
                return;
            };
            for (c.wins, 0..) |w, j| {
                wins[j] = .{
                    .addr = al.dupe(u8, w.addr) catch "",
                    .app_id = al.dupe(u8, w.app_id) catch "",
                    .title = al.dupe(u8, w.title) catch "",
                    .focused = w.focused,
                    .box = w.box,
                };
            }
            out[i] = .{
                .id = c.id,
                .label = al.dupe(u8, c.label) catch "",
                .monitor = al.dupe(u8, c.monitor) catch "",
                .active = c.active,
                .wins = wins,
            };
        }
        self.cards = out;
        self.hovered_ws = -1;
        self.hovered_win = -1;
        self.close_hovered = false;
        self.hovered_qs = -1;
        self.wheel_accum = 0;
        self.relayout();
    }

    /// Windows across all cards, in card order — the flat index actions use.
    pub fn flatCount(self: *const Self) usize {
        var n: usize = 0;
        for (self.cards) |c| n += c.wins.len;
        return n;
    }

    /// Card/window position of a flat index, or null past the end.
    pub fn flatLoc(self: *const Self, flat: usize) ?[2]usize {
        var f = flat;
        for (self.cards, 0..) |c, i| {
            if (f < c.wins.len) return .{ i, f };
            f -= c.wins.len;
        }
        return null;
    }

    /// Nearest card to the scroll, clamped into range.
    pub fn selected(self: *const Self) i32 {
        const n: i32 = @intCast(self.cards.len);
        if (n == 0 or self.layout.pitch <= 0.0) return 0;
        const sel: i32 = @intFromFloat(@round(self.scroll / self.layout.pitch));
        return @min(n - 1, @max(0, sel));
    }

    fn maxScroll(self: *const Self) f64 {
        const n: i32 = @intCast(self.cards.len);
        if (n <= 0) return 0.0;
        return @as(f64, @floatFromInt(n - 1)) * self.layout.pitch;
    }

    /// Finger glide: 1:1 motion straight onto the scroll target, no
    /// notches. Any pending snap is cancelled — the gesture is still
    /// going. Wheel notches keep using `wheel`.
    pub fn panFinger(self: *Self, delta: f64) bool {
        if (!self.open or self.layout.pitch <= 0.0) return false;
        self.snap_at_ms = 0;
        if (self.show_apps) {
            const g = if (self.apps.modalOpen()) &self.layout.modal else &self.layout.grid;
            const sc = if (self.apps.modalOpen()) &self.modal_scroll_target else &self.apps_scroll_target;
            const next = @min(g.scroll_max, @max(0.0, sc.* + delta * 0.4));
            if (next == sc.*) return false;
            sc.* = next;
            return true;
        }
        if (self.cards.len == 0) return false;
        const max = @as(f64, @floatFromInt(@as(i32, @intCast(self.cards.len)) - 1)) * self.layout.pitch;
        const next = @min(@max(max, 0.0), @max(0.0, self.scroll_target + delta * 0.008 * self.layout.pitch));
        if (next == self.scroll_target) return false;
        self.scroll_target = next;
        return true;
    }

    /// A finger glide lifted: schedule the snap to the nearest card once
    /// the settle delay passes. True when a snap is now pending.
    pub fn axisStop(self: *Self, now_ms: u64) bool {
        if (!self.open or self.cards.len == 0) return false;
        const delay: u64 = @intCast(@max(0, @as(i64, @intFromFloat(self.scroll_delay_ms))));
        self.snap_at_ms = now_ms + delay;
        return true;
    }

    /// Apply a due snap: cards settle to the nearest whole card. The grid
    /// stays free wherever the fingers left it.
    pub fn snapTargets(self: *Self) bool {
        if (self.cards.len == 0 or self.layout.pitch <= 0.0) return false;
        const n: i32 = @intCast(self.cards.len);
        const sel = @min(n - 1, @max(0, @as(i32, @intFromFloat(@round(self.scroll_target / self.layout.pitch)))));
        const next = @as(f64, @floatFromInt(sel)) * self.layout.pitch;
        if (next == self.scroll_target) return false;
        self.scroll_target = next;
        return true;
    }

    /// Wheel notch over the rail: one thumb per notch onto the rail
    /// target. No-op while everything fits (scroll_max is zero).
    pub fn wheelRail(self: *Self, delta: f64) bool {
        self.qs_wheel_accum += delta / 15.0;
        const steps: i32 = @intFromFloat(@trunc(self.qs_wheel_accum));
        if (steps == 0) return false;
        self.qs_wheel_accum = @min(2.0, @max(-2.0, self.qs_wheel_accum - @as(f64, @floatFromInt(steps))));
        return self.wheelRailSteps(steps);
    }

    /// Discrete wheel detents over the rail, bypassing axis-unit guessing.
    pub fn wheelRailSteps(self: *Self, steps: i32) bool {
        const max = self.layout.strip.scroll_max;
        if (!self.open or max <= 0.0 or steps == 0) return false;
        const st = self.layout.strip;
        const step = (if (st.horizontal) st.thumb_w else st.thumb_h) + st.gap;
        const n = @min(2, @max(-2, steps));
        const next = @min(max, @max(0.0, self.qs_scroll_target + @as(f64, @floatFromInt(n)) * step));
        if (next == self.qs_scroll_target) return false;
        self.qs_scroll_target = next;
        return true;
    }

    /// Finger glide over the rail: 1:1 pixels onto the rail target.
    pub fn panRail(self: *Self, delta: f64) bool {
        const max = self.layout.strip.scroll_max;
        if (!self.open or max <= 0.0) return false;
        self.snap_at_ms = 0;
        const next = @min(max, @max(0.0, self.qs_scroll_target + delta));
        if (next == self.qs_scroll_target) return false;
        self.qs_scroll_target = next;
        return true;
    }

    /// The wheel walks the strip one card per notch: a notch is ~15 axis
    /// units, so raw deltas accumulate into whole steps and a fling can
    /// never bank more than two cards ahead. Steps land on the scroll
    /// target and the positions glide after it (see `scrollTick`).
    pub fn wheel(self: *Self, delta: f64) bool {
        if (!self.open) return false;
        self.wheel_accum += delta / 15.0;
        const steps: i32 = @intFromFloat(@trunc(self.wheel_accum));
        if (steps == 0) return false;
        self.wheel_accum = @min(2.0, @max(-2.0, self.wheel_accum - @as(f64, @floatFromInt(steps))));
        return self.wheelSteps(steps);
    }

    /// Discrete wheel detents: one physical notch equals one step, with no
    /// dependence on the compositor's axis-unit scale. A fling still never
    /// banks more than two cards ahead.
    pub fn wheelSteps(self: *Self, steps: i32) bool {
        if (!self.open or steps == 0) return false;
        if (self.show_apps) {
            const rows = @min(2, @max(-2, steps));
            // An open folder scrolls its own modal grid. Steps queue onto
            // the target so a second tick mid-glide extends the glide.
            const g = if (self.apps.modalOpen()) &self.layout.modal else &self.layout.grid;
            const sc = if (self.apps.modalOpen()) &self.modal_scroll_target else &self.apps_scroll_target;
            const next = @min(g.scroll_max, @max(0.0, sc.* + @as(f64, @floatFromInt(rows)) * g.cell_h));
            if (next == sc.*) return false;
            sc.* = next;
            return true;
        }
        if (self.cards.len == 0 or self.layout.pitch <= 0.0) return false;
        const n: i32 = @intCast(self.cards.len);
        // Steps queue onto the target, never onto the live position, so a
        // second tick mid-glide extends the glide instead of jumping it.
        const from: i32 = @as(i32, @intFromFloat(@round(self.scroll_target / self.layout.pitch)));
        const sel = @min(n - 1, @max(0, from + @min(2, @max(-2, steps))));
        const next = @as(f64, @floatFromInt(sel)) * self.layout.pitch;
        if (next == self.scroll_target) return false;
        self.scroll_target = next;
        return true;
    }

    fn tileAt(self: *const Self, card: usize, idx: usize) types.Rect {
        const r = lay.cardRect(&self.layout, @intCast(card), self.scroll);
        const n: i32 = @intCast(self.cards[card].wins.len);
        return pick.tileRect(&self.layout, r, self.cards[card].wins[idx].box, @intCast(idx), n);
    }

    fn closeAt(self: *const Self, tile: types.Rect, mx: f64, my: f64) bool {
        const bs = self.layout.close_sz * 0.72;
        return mx >= tile.x + tile.w - bs * 0.5 and mx <= tile.x + tile.w + bs * 0.5 and
            my >= tile.y - bs * 0.5 and my <= tile.y + bs * 0.5;
    }

    /// Card index holding a flat window index, for keyboard hover sync.
    fn flatCard(self: *Self, flat: usize) ?usize {
        if (self.flatLoc(flat)) |loc| return loc[0];
        return null;
    }

    /// Tile rect for a flat window index, for drag-grab offsets.
    fn tileForFlat(self: *Self, flat: usize) ?types.Rect {
        var f = flat;
        for (self.cards, 0..) |c, i| {
            if (f < c.wins.len) return self.tileAt(i, f);
            f -= c.wins.len;
        }
        return null;
    }

    /// Search field hit, shared by motion and press so the two agree.
    fn searchHit(self: *Self, mx: f64, my: f64) bool {
        const sx = self.layout.center_x - self.layout.search_w * 0.5;
        return mx >= sx and mx <= sx + self.layout.search_w and
            my >= self.layout.search_y and my <= self.layout.search_y + self.layout.search_h;
    }

    /// Folder title hit zone: the strip above the modal box.
    fn titleHit(self: *Self, mx: f64, my: f64) bool {
        if (!self.apps.modalOpen()) return false;
        const mbox = gridmod.modalBox(&self.layout.modal, self.layout.ui);
        return mx >= mbox.x and mx <= mbox.x + mbox.w and
            my >= mbox.y - 44.0 * self.layout.ui and my <= mbox.y;
    }

    /// Snapshot pre-drop cell origins for the shuffle animation. Call
    /// BEFORE mutating folders or grid order.
    fn beginShuffle(self: *Self, modal: bool) void {
        self.clearShuffle();
        self.shuffle_modal = modal;
        const g = if (modal) &self.layout.modal else &self.layout.grid;
        const sc = if (modal) self.apps.modal_scroll else self.apps.scroll;
        const n: usize = if (modal) self.apps.modalCount() else self.apps.folders.items.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = gridmod.cellRect(g, @intCast(i), sc);
            const skey: []const u8 = if (modal) blk: {
                const p = self.apps.modalItemPath(i);
                break :blk std.fmt.allocPrint(self.gpa, "a:{s}", .{p}) catch continue;
            } else blk: {
                if (i >= self.apps.folders.items.len) continue;
                break :blk self.gpa.dupe(u8, self.apps.folders.items[i].key) catch continue;
            };
            errdefer self.gpa.free(skey);
            self.shuffle_keys.append(self.gpa, skey) catch {
                self.gpa.free(skey);
                continue;
            };
            self.shuffle_x.append(self.gpa, r.x) catch continue;
            self.shuffle_y.append(self.gpa, r.y) catch continue;
        }
        self.shuffle_start_ms = nowMs();
    }

    /// Recompute the workspace/tile/add-slot under a dragged window using
    /// the live scroll. Called on motion and again while edge auto-scroll
    /// slides the strip under a stationary pointer.
    fn updateWindowDrop(self: *Self) void {
        const mx = self.drop_px;
        const my = self.drop_py;
        // Window drag targets: another card, another tile on the same card,
        // a quick-select thumb, or the strip's add slot (which wins over all).
        const n: i32 = @intCast(self.cards.len);
        self.hovered_qs = -1;
        self.drop_ws = -1;
        self.drop_win = -1;
        self.drop_add = pick.pickStripAdd(&self.layout.strip, n, mx, my, self.qs_scroll);
        if (self.drop_add) {
            self.hovered_qs = types.strip_add_idx;
            return;
        }
        // The quick-select thumbs are workspace targets too: dropping a
        // window straight onto one moves it there without scrolling the
        // main strip to hunt for the card.
        const qs = pick.pickStrip(&self.layout.strip, n, mx, my, self.qs_scroll);
        if (qs >= 0) {
            self.hovered_qs = qs;
            if (qs != self.press_ws) self.drop_ws = qs;
            return;
        }
        self.drop_ws = pick.pickWorkspace(&self.layout, n, mx, my, self.scroll);
        if (self.drop_ws == self.press_ws) self.drop_ws = -1;
        if (self.drop_ws < 0 and self.press_ws >= 0) {
            const ci: usize = @intCast(self.press_ws);
            if (ci < self.cards.len) {
                for (0..self.cards[ci].wins.len) |j| {
                    if (!self.tileAt(ci, j).contains(mx, my)) continue;
                    var f: usize = 0;
                    var k: usize = 0;
                    while (k < ci) : (k += 1) f += self.cards[k].wins.len;
                    const flat: i32 = @intCast(f + j);
                    if (flat != self.press_win) self.drop_win = flat;
                    break;
                }
            }
        }
    }

    /// Arm edge auto-scroll when a dragged window reaches the end of the
    /// strip axis. Direction follows the strip, not the pointer: the bottom
    /// edge advances a vertical strip, the right edge a horizontal one.
    fn updateDragEdge(self: *Self, mx: f64, my: f64) void {
        self.drag_edge_dir = 0;
        self.drag_edge_t = 0;
        if (!self.drag_active or self.show_apps or self.press_win < 0) return;
        if (self.cards.len < 2 or self.layout.pitch <= 0.0) return;
        if (mx < 0.0 or my < 0.0) return;
        const zone = @min(120.0, drag_edge_zone * self.layout.ui);
        const vertical = self.layout.axis == .vertical;
        const pos = if (vertical) my else mx;
        const extent: f64 = @floatFromInt(if (vertical) self.buf_h else self.buf_w);
        if (extent <= zone * 2.0) return;
        if (pos < zone) {
            self.drag_edge_dir = -1;
            self.drag_edge_t = @min(1.0, (zone - pos) / zone);
        } else if (pos > extent - zone) {
            self.drag_edge_dir = 1;
            self.drag_edge_t = @min(1.0, (pos - (extent - zone)) / zone);
        }
    }

    /// Advance the strip while a window drag sits in an edge zone. The
    /// pointer can stay still: the live scroll glides after the target and
    /// the drop hit-test follows it, so releasing drops into whichever
    /// workspace is under the pointer at that moment.
    pub fn edgeScrollTick(self: *Self, dt_s: f64) bool {
        if (!self.open or !self.drag_active or self.drag_edge_dir == 0) return false;
        if (self.show_apps or self.cards.len < 2 or self.layout.pitch <= 0.0) return false;
        const speed = drag_edge_cards_per_s * (0.25 + 0.75 * @min(1.0, @max(0.0, self.drag_edge_t)));
        const step = @as(f64, @floatFromInt(self.drag_edge_dir)) * speed * self.layout.pitch * @max(0.0, dt_s);
        const max = self.maxScroll();
        const next = @min(max, @max(0.0, self.scroll_target + step));
        if (next == self.scroll_target) return false;
        self.scroll_target = next;
        // The pointer has not moved, but the card under it has.
        self.updateWindowDrop();
        return true;
    }

    /// Pointer moved; true when pixels changed.
    pub fn motion(self: *Self, mx: f64, my: f64) bool {
        if (!self.open) return false;
        // Drag threshold: 8px of motion turns the press into a drag.
        if (self.button_pressed and !self.drag_active) {
            const dx = mx - self.press_x;
            const dy = my - self.press_y;
            if (dx * dx + dy * dy > 64.0) {
                self.drag_active = true;
                if (self.show_apps and self.press_app >= 0) {
                    const modal = self.press_app_modal;
                    const g = if (modal) &self.layout.modal else &self.layout.grid;
                    const sc = if (modal) self.apps.modal_scroll else self.apps.scroll;
                    const cell = gridmod.cellRect(g, self.press_app, sc);
                    if (cell.w > 0.0) {
                        self.drag_grab_dx = self.press_x - cell.x;
                        self.drag_grab_dy = self.press_y - cell.y;
                    } else {
                        self.drag_grab_dx = 0;
                        self.drag_grab_dy = 0;
                    }
                    if (!modal) self.apps.hovered = self.press_app;
                } else if (!self.show_apps and self.press_win >= 0) {
                    if (self.tileForFlat(@intCast(self.press_win))) |t| {
                        self.drag_grab_dx = self.press_x - t.x;
                        self.drag_grab_dy = self.press_y - t.y;
                    } else {
                        self.drag_grab_dx = 0;
                        self.drag_grab_dy = 0;
                    }
                    // A drag that crosses the threshold already at the edge
                    // must arm auto-scroll now; no further motion may come.
                    self.drop_px = mx;
                    self.drop_py = my;
                    self.updateDragEdge(mx, my);
                    self.updateWindowDrop();
                }
                return true;
            }
        }
        if (self.drag_active) {
            self.drop_px = mx;
            self.drop_py = my;
            self.updateDragEdge(mx, my);
            if (self.show_apps and self.press_app >= 0) {
                const modal = self.press_app_modal;
                const g = if (modal) &self.layout.modal else &self.layout.grid;
                const n: i32 = @intCast(if (modal) self.apps.modalCount() else self.apps.folders.items.len);
                const sc = if (modal) self.apps.modal_scroll else self.apps.scroll;
                const dst = gridmod.pickCell(g, mx, my, n, sc);
                if (modal) {
                    if (dst == self.apps.modal_hovered) return true;
                    self.apps.modal_hovered = dst;
                    return true;
                }
                if (dst != self.apps.hovered) self.apps.hovered = dst;
                self.drop_cell = dst;
                return true;
            }
            self.updateWindowDrop();
            return true;
        }
        // Context menu hover wins while open.
        if (self.apps.ctx_open) {
            const row = self.apps.ctxHit(mx, my, self.layout.ui);
            if (row != self.apps.ctx_hover) {
                self.apps.ctx_hover = row;
                return true;
            }
            return false;
        }
        if (self.searchHit(mx, my) != self.hovered_search) {
            self.hovered_search = !self.hovered_search;
            return true;
        }
        if (appsHit(&self.layout, mx, my) != self.hovered_apps_btn) {
            self.hovered_apps_btn = !self.hovered_apps_btn;
            return true;
        }
        if (self.show_apps) {
            const modal = self.apps.modalOpen();
            const g = if (modal) &self.layout.modal else &self.layout.grid;
            const n: i32 = @intCast(if (modal) self.apps.modalCount() else self.apps.folders.items.len);
            const sc = if (modal) self.apps.modal_scroll else self.apps.scroll;
            const h = gridmod.pickCell(g, mx, my, n, sc);
            if (modal) {
                if (h == self.apps.modal_hovered) return false;
                self.apps.modal_hovered = h;
                return true;
            }
            if (h == self.apps.hovered) return false;
            self.apps.hovered = h;
            return true;
        }
        var ws: i32 = -1;
        var win: i32 = -1;
        var close = false;
        var qs: i32 = -1;
        const n: i32 = @intCast(self.cards.len);
        var i: i32 = n - 1;
        while (i >= 0) : (i -= 1) {
            const ci: usize = @intCast(i);
            if (!lay.cardRect(&self.layout, i, self.scroll).contains(mx, my)) continue;
            ws = i;
            for (0..self.cards[ci].wins.len) |j| {
                if (self.tileAt(ci, j).contains(mx, my)) {
                    // Flat index counts from the first card, like the strip.
                    var f: usize = 0;
                    var k: usize = 0;
                    while (k < ci) : (k += 1) f += self.cards[k].wins.len;
                    win = @intCast(f + j);
                    close = self.closeAt(self.tileAt(ci, j), mx, my);
                    break;
                }
            }
            break;
        }
        if (ws < 0) {
            qs = pick.pickStrip(&self.layout.strip, n, mx, my, self.qs_scroll);
            if (qs < 0 and pick.pickStripAdd(&self.layout.strip, @intCast(self.cards.len), mx, my, self.qs_scroll)) qs = types.strip_add_idx;
        }
        if (ws == self.hovered_ws and win == self.hovered_win and close == self.close_hovered and qs == self.hovered_qs) return false;
        self.hovered_ws = ws;
        self.hovered_win = win;
        self.close_hovered = close;
        self.hovered_qs = qs;
        return true;
    }

    pub fn press(self: *Self, mx: f64, my: f64, button: u32, down: bool) Action {
        if (!self.open) return .none;
        // Right-click: pin/unpin context menu over app cells (either grid).
        // Folders (empty path) get no menu.
        if (button == 0x111) {
            if (!down) return .none;
            if (self.apps.ctx_open) self.apps.closeCtx();
            if (self.show_apps) {
                const modal = self.apps.modalOpen();
                const g = if (modal) &self.layout.modal else &self.layout.grid;
                const n: i32 = @intCast(if (modal) self.apps.modalCount() else self.apps.folders.items.len);
                const sc = if (modal) self.apps.modal_scroll else self.apps.scroll;
                const idx = gridmod.pickCell(g, mx, my, n, sc);
                var path: []const u8 = "";
                if (idx >= 0) {
                    path = if (modal) self.apps.modalItemPath(@intCast(idx)) else self.apps.gridItemPath(@intCast(idx));
                }
                if (path.len > 0) return .{ .ctx_menu = .{ .x = mx, .y = my, .path = path } };
            }
            return .none;
        }
        if (button != 0x110) return .none;
        if (!down) return self.release(mx, my);
        // In the launchpad the pill is the way back; everywhere else
        // it is the way in.
        if (appsHit(&self.layout, mx, my)) return .apps;
        if (self.searchHit(mx, my)) return .apps;
        // An open context menu eats the press: inside activates the row
        // under it, outside dismisses (swallowing, so nothing launches).
        if (self.apps.ctx_open) {
            const row = self.apps.ctxHit(mx, my, self.layout.ui);
            if (row >= 0) {
                const act = self.apps.ctxAction(row);
                const app = self.apps.ctx_app;
                self.apps.closeCtx();
                if (act == 0 and app.len > 0) return .{ .ctx_dock = app };
                if (act == 1 and app.len > 0) return .{ .ctx_taskbar = app };
                return .refresh;
            }
            self.apps.closeCtx();
            return .refresh;
        }
        if (self.show_apps) {
            if (self.titleHit(mx, my)) {
                if (self.apps.modalOpen()) {
                    const f = self.apps.folders.folders[@intCast(self.apps.open_folder)];
                    self.apps.rename.start(f.name);
                    return .refresh;
                }
            }
            const modal = self.apps.modalOpen();
            const g = if (modal) &self.layout.modal else &self.layout.grid;
            const n: i32 = @intCast(if (modal) self.apps.modalCount() else self.apps.folders.items.len);
            const sc = if (modal) self.apps.modal_scroll else self.apps.scroll;
            const idx = gridmod.pickCell(g, mx, my, n, sc);
            if (idx >= 0) {
                self.button_pressed = true;
                self.press_app = idx;
                self.press_app_modal = modal;
                self.press_x = mx;
                self.press_y = my;
                self.drag_active = false;
                self.drop_cell = -1;
                return .none;
            }
            // Backdrop click closes an open folder; otherwise nothing.
            if (modal) {
                self.apps.closeFolder();
                return .refresh;
            }
            return .none;
        }
        const n: i32 = @intCast(self.cards.len);
        const qs = pick.pickStrip(&self.layout.strip, n, mx, my, self.qs_scroll);
        if (qs >= 0 and qs < n) return .{ .select_ws = self.cards[@intCast(qs)].id };
        if (pick.pickStripAdd(&self.layout.strip, @intCast(self.cards.len), mx, my, self.qs_scroll)) return .add_ws;
        var i: i32 = n - 1;
        while (i >= 0) : (i -= 1) {
            const ci: usize = @intCast(i);
            if (!lay.cardRect(&self.layout, i, self.scroll).contains(mx, my)) continue;
            var f: usize = 0;
            var k: usize = 0;
            while (k < ci) : (k += 1) f += self.cards[k].wins.len;
            for (0..self.cards[ci].wins.len) |j| {
                const t = self.tileAt(ci, j);
                if (self.closeAt(t, mx, my)) return .{ .close_win = f + j };
                if (t.contains(mx, my)) {
                    self.button_pressed = true;
                    self.press_ws = i;
                    self.press_win = @intCast(f + j);
                    self.press_x = mx;
                    self.press_y = my;
                    self.drag_active = false;
                    self.drop_ws = -1;
                    self.drop_win = -1;
                    return .none;
                }
            }
            return .{ .select_ws = self.cards[ci].id };
        }
        return .dismiss;
    }

    /// Release: clicks activate, drags drop. Folders themselves never drag.
    fn release(self: *Self, mx: f64, my: f64) Action {
        if (!self.button_pressed) return .none;
        self.button_pressed = false;
        defer self.clearPress();
        if (self.drag_active) {
            self.drag_active = false;
            // Edge auto-scroll may have slid the strip since the last motion
            // event; hit-test the drop one final time against where the
            // pointer is now, then settle between cards.
            if (!self.show_apps) {
                self.updateWindowDrop();
                _ = self.snapTargets();
            }
            if (self.show_apps and self.press_app >= 0) {
                if (self.press_app_modal) {
                    // Modal drag: outside the box removes the app from the
                    // folder; inside cancels.
                    if (self.apps.modalOpen()) {
                        const mbox = gridmod.modalBox(&self.layout.modal, self.layout.ui);
                        if (mx < mbox.x or mx > mbox.x + mbox.w or my < mbox.y or my > mbox.y + mbox.h) {
                            self.apps.removeModalCell(@intCast(self.press_app));
                            return .refresh;
                        }
                    }
                    return .none;
                }
                // Main-grid drag: dropping onto a folder tile moves the app
                // in; anywhere else reorders (dock-style insertion). Making
                // a brand-new folder takes Ctrl held over another app, so a
                // plain reorder can never turn into an accidental folder.
                const dst = gridmod.pickCell(&self.layout.grid, mx, my, @intCast(self.apps.folders.items.len), self.apps.scroll);
                if (dst >= 0 and dst != self.press_app) {
                    const cell = gridmod.cellRect(&self.layout.grid, dst, self.apps.scroll);
                    if (cell.w > 0.0 and cell.h > 0.0) {
                        const fx = (mx - cell.x) / cell.w;
                        const fy = (my - cell.y) / cell.h;
                        const center = fx > 0.2 and fx < 0.8 and fy > 0.2 and fy < 0.8;
                        const src: usize = @intCast(self.press_app);
                        const di: usize = @intCast(dst);
                        if (self.apps.folders.items[src].folder) return .none;
                        const dst_folder = self.apps.folders.items[di].folder;
                        self.beginShuffle(false);
                        if (center and (dst_folder or self.drop_ctrl)) {
                            self.apps.dropCell(src, di);
                        } else {
                            self.apps.reorderCell(src, di, fx > 0.5);
                        }
                        self.apps.hovered = -1;
                        return .refresh;
                    }
                }
                return .none;
            }
            if (self.press_win >= 0) {
                if (self.drop_add) {
                    return .{ .move_win_new = @intCast(self.press_win) };
                } else if (self.drop_ws >= 0 and self.drop_ws != self.press_ws) {
                    return .{ .move_win = .{ .flat = @intCast(self.press_win), .ws = self.drop_ws } };
                } else if (self.drop_win >= 0) {
                    const a: usize = @intCast(self.press_win);
                    const b: usize = @intCast(self.drop_win);
                    if (a != b) return .{ .swap_wins = .{ .a = a, .b = b } };
                }
            }
            return .none;
        }
        if (self.show_apps and self.press_app >= 0) {
            const modal = self.press_app_modal;
            const idx: usize = @intCast(self.press_app);
            if (modal) {
                if (self.apps.modalAppIndex(idx)) |cat| return .{ .launch_modal = cat };
                return .none;
            }
            if (self.apps.activateCell(idx, false)) |cat| return .{ .launch_app = cat };
            // Folder opened (not launched).
            self.relayoutAppsGrid();
            return .refresh;
        }
        if (self.press_win >= 0) return .{ .focus = @intCast(self.press_win) };
        return .none;
    }

    fn clearPress(self: *Self) void {
        self.press_ws = -1;
        self.press_win = -1;
        self.press_app = -1;
        self.press_app_modal = false;
        self.drop_ws = -1;
        self.drop_win = -1;
        self.drop_add = false;
        self.drop_cell = -1;
        self.drag_edge_dir = 0;
        self.drag_edge_t = 0;
    }

    /// Recompute the apps grids after a folder mutation (reorder already
    /// rebuilt via saveFolders path; this covers the rest).
    fn relayoutAppsGrid(self: *Self) void {
        self.layoutAppsGrid();
        self.apps.hovered = -1;
        self.apps.modal_hovered = -1;
    }

    pub fn key(self: *Self, sym: u32, pressed: bool, text: []const u8) Action {
        if (!self.open or !pressed) return .none;
        const xkb = seat_mod.xkb;
        if (self.show_apps) return self.appsKey(sym, text);
        if (sym == xkb.XKB_KEY_Escape) return .dismiss;
        if (sym == xkb.XKB_KEY_Return or sym == xkb.XKB_KEY_KP_Enter) {
            const n = self.flatCount();
            if (self.hovered_win >= 0 and @as(usize, @intCast(self.hovered_win)) < n) {
                return .{ .focus = @intCast(self.hovered_win) };
            }
            const sel = self.selected();
            if (sel >= 0 and sel < self.cards.len) return .{ .select_ws = self.cards[@intCast(sel)].id };
            return .none;
        }
        if (sym == xkb.XKB_KEY_Tab or sym == xkb.XKB_KEY_Right) {
            if (self.cycleWin(1)) return .refresh;
            return .none;
        }
        if (sym == xkb.XKB_KEY_Left) {
            if (self.cycleWin(-1)) return .refresh;
            return .none;
        }
        if (sym == xkb.XKB_KEY_Down) {
            if (self.stepWin(1)) return .refresh;
            return .none;
        }
        if (sym == xkb.XKB_KEY_Up) {
            if (self.stepWin(-1)) return .refresh;
            return .none;
        }
        // Printable text anywhere summons the launchpad already searching.
        if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
            const t0 = nowMs();
            if (!self.show_apps) self.toggleApps(self.app_theme);
            self.apps.typeText(text);
            self.relayout();
            logz.log("overview: search model {d}ms hits={d}", .{ nowMs() - t0, self.apps.hits.items.len });
            return .refresh;
        }
        return .none;
    }

    /// Cycle window hover across cards, wrapping. Returns whether it moved.
    fn cycleWin(self: *Self, d: i32) bool {
        const n: i32 = @intCast(self.flatCount());
        if (n <= 0) return false;
        var sel: i32 = if (self.hovered_win < 0) (if (d > 0) 0 else n - 1) else self.hovered_win;
        sel = @mod(sel + d, n);
        if (sel == self.hovered_win) return false;
        self.hovered_win = sel;
        if (self.flatCard(@intCast(sel))) |ci| self.hovered_ws = @intCast(ci);
        return true;
    }

    /// Step window hover without wrapping.
    fn stepWin(self: *Self, d: i32) bool {
        const n: i32 = @intCast(self.flatCount());
        if (n <= 0) return false;
        const sel = @min(n - 1, @max(0, @max(0, self.hovered_win) + d));
        if (sel == self.hovered_win) return false;
        self.hovered_win = sel;
        if (self.flatCard(@intCast(sel))) |ci| self.hovered_ws = @intCast(ci);
        return true;
    }

    fn appsKey(self: *Self, sym: u32, text: []const u8) Action {
        const xkb = seat_mod.xkb;
        if (sym == xkb.XKB_KEY_F2 and self.apps.modalOpen()) {
            const f = self.apps.folders.folders[@intCast(self.apps.open_folder)];
            self.apps.rename.start(f.name);
            return .refresh;
        }
        if (sym == xkb.XKB_KEY_Escape) {
            if (self.apps.ctx_open) {
                self.apps.closeCtx();
                return .refresh;
            }
            if (self.apps.rename.active) {
                self.apps.rename.cancel();
                return .refresh;
            }
            if (self.apps.modalOpen()) {
                self.apps.closeFolder();
                self.apps.modal_hovered = -1;
                return .refresh;
            }
            if (self.apps.query.items.len > 0) {
                self.apps.clearQuery();
                self.relayout();
                return .refresh;
            }
            // Empty query: out of the overview entirely, not one
            // step back to the workspaces.
            return .dismiss;
        }
        if (sym == xkb.XKB_KEY_Return or sym == xkb.XKB_KEY_KP_Enter) {
            if (self.apps.rename.active) {
                self.apps.commitRename();
                self.relayout();
                return .refresh;
            }
            if (self.apps.modalOpen()) {
                if (self.apps.modal_hovered >= 0) {
                    if (self.apps.modalAppIndex(@intCast(self.apps.modal_hovered))) |cat| {
                        return .{ .launch_modal = cat };
                    }
                }
                return .none;
            }
            if (self.apps.hovered >= 0) {
                if (self.apps.activateCell(@intCast(self.apps.hovered), false)) |cat| {
                    return .{ .launch_app = cat };
                }
                // Folder opened (not launched).
                self.relayoutAppsGrid();
                return .refresh;
            }
            const n = self.activeCount();
            if (n > 0) {
                if (self.apps.activateCell(0, false)) |cat| return .{ .launch_app = cat };
                self.relayoutAppsGrid();
                return .refresh;
            }
            return .none;
        }
        if (sym == xkb.XKB_KEY_BackSpace) {
            if (self.apps.rename.active) {
                self.apps.rename.backspace();
                return .refresh;
            }
            self.apps.backspace();
            self.relayout();
            return .refresh;
        }
        if (self.apps.rename.active) {
            self.apps.rename.typeText(text);
            return .refresh;
        }
        if (self.show_apps) {
            const n: i32 = @intCast(self.activeCount());
            if (n > 0) {
                if (sym == xkb.XKB_KEY_Right or sym == xkb.XKB_KEY_Tab) {
                    if (self.moveAppHover(1, true)) return .refresh;
                    return .none;
                }
                if (sym == xkb.XKB_KEY_Left) {
                    if (self.moveAppHover(-1, true)) return .refresh;
                    return .none;
                }
                if (sym == xkb.XKB_KEY_Down or sym == xkb.XKB_KEY_Page_Down) {
                    const g = self.activeGrid();
                    var step: i32 = @max(g.cols, 1);
                    if (sym == xkb.XKB_KEY_Page_Down) step *= @max(g.rows, 1);
                    if (self.moveAppHover(step, false)) return .refresh;
                    return .none;
                }
                if (sym == xkb.XKB_KEY_Up or sym == xkb.XKB_KEY_Page_Up) {
                    const g = self.activeGrid();
                    var step: i32 = @max(g.cols, 1);
                    if (sym == xkb.XKB_KEY_Page_Up) step *= @max(g.rows, 1);
                    if (self.moveAppHover(-step, false)) return .refresh;
                    return .none;
                }
            }
        }
        if (text.len == 0 or text[0] < 0x20 or text[0] == 0x7f) return .none;
        self.apps.typeText(text);
        self.relayout();
        return .refresh;
    }

    fn activeGrid(self: *Self) *const types.Grid {
        return if (self.apps.modalOpen()) &self.layout.modal else &self.layout.grid;
    }

    fn moveAppHover(self: *Self, d: i32, wrap: bool) bool {
        const n: i32 = @intCast(self.activeCount());
        if (n <= 0) return false;
        const modal = self.apps.modalOpen();
        const cur = if (modal) self.apps.modal_hovered else self.apps.hovered;
        var h: i32 = undefined;
        if (wrap) {
            const base = if (cur < 0) (if (d > 0) 0 else n - 1) else cur;
            h = @mod(base + d, n);
        } else {
            const base = if (cur < 0) (if (d > 0) 0 else n - 1) else cur;
            h = @min(n - 1, @max(0, base + d));
        }
        if (modal) {
            if (h == self.apps.modal_hovered) return false;
            self.apps.modal_hovered = h;
        } else {
            if (h == self.apps.hovered) return false;
            self.apps.hovered = h;
        }
        self.ensureAppVisible(h);
        return true;
    }

    fn ensureAppVisible(self: *Self, idx: i32) void {
        const modal = self.apps.modalOpen();
        const g = if (modal) &self.layout.modal else &self.layout.grid;
        const sc = if (modal) self.modal_scroll_target else self.apps_scroll_target;
        const r = gridmod.cellRect(g, idx, sc);
        const top = g.start_y;
        const view_h = @as(f64, @floatFromInt(g.rows)) * g.cell_h;
        const max = g.scroll_max;
        if (r.y < top) {
            const nv = @max(0.0, sc - (top - r.y));
            if (modal) self.modal_scroll_target = nv else self.apps_scroll_target = nv;
        } else if (r.y + r.h > top + view_h) {
            const nv = @min(max, sc + (r.y + r.h - top - view_h));
            if (modal) self.modal_scroll_target = nv else self.apps_scroll_target = nv;
        }
    }

    pub fn refresh(self: *Self) void {
        if (!self.open or self.buf_w <= 0 or self.buf_h <= 0) return;
        const buf = self.shm.acquire() orelse return;
        const cr = buf.cr orelse return;
        self.frame_buf = buf;
        const t0 = nowMs();
        self.draw(cr);
        const paint_ms = nowMs() - t0;
        // The user asked for the number: every slow frame says what it cost.
        if (paint_ms > 8) logz.log("overview: paint {d}ms", .{paint_ms});
        self.surface.attach(buf.wlBuffer(), 0, 0);
        self.surface.setBufferScale(self.surface.scale);
        self.surface.damage(0, 0, self.buf_w, self.buf_h);
        buf.markBusy();
        self.frame_buf = null;
        // Pace the pulse off the compositor: the frame callback fires at
        // vsync, so animations track the display instead of a fixed tick.
        // Request it before the commit it belongs to — requested after,
        // it waits for the *next* commit and the chain idles until some
        // unrelated event (pointer motion) paints again.
        self.requestFrame();
        self.surface.commit();
    }

    /// Owner hook for the vsync pulse: runs in the frame callback with the
    /// compositor's timestamp, so dt is one real display interval.
    /// (Fields live with the rest of the struct state above.)
    /// At most one frame callback is ever outstanding; each commit that
    /// wants a follow-up calls `requestFrame`, and the callback re-arms
    /// only while work remains — silence when idle.
    pub fn requestFrame(self: *Self) void {
        if (self.frame_cb != null) return;
        if (self.on_frame == null) return;
        const surf = self.surface.wl_surface orelse return;
        const cb = wl.wl_surface_frame(surf);
        if (cb == null) return;
        _ = wl.wl_callback_add_listener(cb, &frame_listener, self);
        self.frame_cb = cb;
    }

    fn frameDone(data: ?*anyopaque, cb: ?*wl.wl_callback, time: u32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (cb) |c| wl.wl_callback_destroy(c);
        self.frame_cb = null;
        if (self.on_frame) |h| h(self.frame_ctx, time);
    }

    const frame_listener = wl.wl_callback_listener{ .done = frameDone };

    fn draw(self: *Self, cr: ?*cairo.cairo_t) void {
        const w: f64 = @floatFromInt(self.buf_w);
        const h: f64 = @floatFromInt(self.buf_h);
        // Scale the whole frame to the output's device pixels. Everything
        // below draws in logical coordinates (buf_w/buf_h); cairo rasterises
        // at the buffer's native resolution so HiDPI stays crisp.
        cairo.cairo_identity_matrix(cr);
        const osc: f64 = @floatFromInt(self.surface.scale);
        cairo.cairo_scale(cr, osc, osc);
        var t = nowUs();
        self.base.paint(cr, w, h, self.colors.bg, self.overview_alpha);
        const base_us = nowUs() - t;
        var body_us: u64 = 0;
        var cchrome_us: u64 = 0;
        var live_us: u64 = 0;
        var tint_us: u64 = 0;
        var icon_us: u64 = 0;
        var title_us: u64 = 0;
        var label_us: u64 = 0;
        var ghost_us: u64 = 0;
        if (self.show_apps) {
            // The launchpad is its own page: grid, dots and the way back.
            // No cards behind it. `launchpad_alpha` is the Appearance →
            // Opacity "Launchpad" knob (1.0 at defaults).
            paint.paintSearch(cr, &self.layout, self.colors, self.launchpad_alpha, self.apps.query.items);
            self.paintApps(cr);
            paint.paintAppsBtn(cr, &self.layout, self.colors, self.launchpad_alpha, false, true);
            const apps_us = nowUs() - t - base_us;
            logz.log("overview: stages base={d:.1} apps={d:.1} total={d:.1}", .{ ms(base_us), ms(apps_us), ms(nowUs() - t) });
            return;
        }
        const sel = self.selected();
        var flat: usize = 0;
        // Cards never paint over the search bar: a scrolled card above
        // the search is culled (flat indices still advance, so window
        // numbering stays aligned with the unculled math).
        const search_bottom = self.layout.search_y + self.layout.search_h + 12.0 * self.ui;
        for (self.cards, 0..) |card, ci| {
            const r = lay.cardRect(&self.layout, @intCast(ci), self.scroll);
            const cflat = flat;
            flat += card.wins.len;
            if (r.x + r.w < 0.0 or r.x > w) continue;
            if (r.y + r.h < search_bottom or r.y > h) continue;
            // Cards always sit on the wallpaper. A desktop copy would
            // paint other workspaces' windows onto this card, so empty
            // cards take the wallpaper too — the monitor shot only ever
            // backs the rail, never a card.
            const bg_kind: tiles.SrcKind = .wallpaper;
            const bg_id: u64 = 0;
            const bg: ?tiles.LiveFrame = self.wallpaper_frame;
            const t_chrome = nowUs();
            const chrome = self.cardChrome(r.w, r.h);
            cchrome_us += nowUs() - t_chrome;
            t = nowUs();
            paint.paintCardBody(cr, r, self.colors, self.ui, 1.0, @as(i32, @intCast(ci)) == sel, false, self.drag_active and !self.show_apps and @as(i32, @intCast(ci)) == self.drop_ws, &self.scaled, bg_kind, bg_id, bg, chrome, self.cardBase(r.w, r.h));
            body_us += nowUs() - t;
            for (card.wins, 0..) |win, j| {
                // Lifted tile stays empty; the ghost paints it floating.
                if (self.drag_active and !self.show_apps and @as(i32, @intCast(cflat + j)) == self.press_win) continue;
                const tt = self.tileAt(ci, j);
                const hov = @as(i32, @intCast(cflat + j)) == self.hovered_win;
                const live = if (self.frames) |lk| lk.call(lk.ctx, win.addr) else null;
                t = nowUs();
                if (live) |fr| {
                    tiles.paintFrameCached(&self.scaled, cr, .window, tiles.hashId(win.addr), tt, fr, 1.0, 12.0 * self.ui);
                    if (win.focused) tiles.paintFocusRing(cr, tt, self.ui, self.colors, 1.0);
                } else {
                    tiles.paintTile(cr, tt, self.colors, self.ui, tiles.appTint(win.app_id), 1.0, win.focused, hov);
                }
                const after_tile = nowUs();
                if (live != null) live_us += after_tile - t else tint_us += after_tile - t;
                if (self.icons) |lk| {
                    if (win.app_id.len > 0) {
                        t = nowUs();
                        if (lk.call(lk.ctx, win.app_id)) |px| tiles.paintTileIcon(cr, tt, self.ui, px, 1.0);
                        icon_us += nowUs() - t;
                    }
                }
                t = nowUs();
                tiles.paintTitlePill(cr, tt, self.ui, win.title, 1.0);
                title_us += nowUs() - t;
                if (hov) tiles.paintClose(cr, tt, self.layout.close_sz, self.ui, self.close_hovered, 1.0);
            }
            t = nowUs();
            if (card.wins.len == 0) {
                tiles.paintCardLabel(cr, r, self.ui, self.colors, "Empty", 1.0);
            } else {
                tiles.paintCardLabel(cr, r, self.ui, self.colors, card.label, 1.0);
            }
            label_us += nowUs() - t;
        }
        t = nowUs();
        if (self.drag_active and !self.show_apps and self.press_win >= 0) {
            if (self.flatLoc(@intCast(self.press_win))) |loc| {
                const ci, const wi = loc;
                if (ci < self.cards.len and wi < self.cards[ci].wins.len) {
                    const win = self.cards[ci].wins[wi];
                    const g0 = self.tileAt(ci, wi);
                    // Ghost rides the grab point at 1.05 about its center.
                    const gx = self.drop_px - self.drag_grab_dx;
                    const gy = self.drop_py - self.drag_grab_dy;
                    const gcx = gx + g0.w * 0.5;
                    const gcy = gy + g0.h * 0.5;
                    cairo.cairo_save(cr);
                    cairo.cairo_translate(cr, gcx, gcy);
                    cairo.cairo_scale(cr, 1.05, 1.05);
                    cairo.cairo_translate(cr, -gcx, -gcy);
                    var gt = g0;
                    gt.x = gx;
                    gt.y = gy;
                    const glive = if (self.frames) |lk| lk.call(lk.ctx, win.addr) else null;
                    if (glive) |fr| {
                        tiles.paintFrameCached(&self.scaled, cr, .window, tiles.hashId(win.addr), gt, fr, 0.9, 12.0 * self.ui);
                        if (win.focused) tiles.paintFocusRing(cr, gt, self.ui, self.colors, 0.9);
                    } else {
                        tiles.paintTile(cr, gt, self.colors, self.ui, tiles.appTint(win.app_id), 0.9, win.focused, false);
                    }
                    if (self.icons) |lk| {
                        if (win.app_id.len > 0) {
                            if (lk.call(lk.ctx, win.app_id)) |px| tiles.paintTileIcon(cr, gt, self.ui, px, 0.9);
                        }
                    }
                    tiles.paintTitlePill(cr, gt, self.ui, win.title, 0.9);
                    cairo.cairo_restore(cr);
                }
            }
        }
        ghost_us += nowUs() - t;
        t = nowUs();
        paint.paintSearch(cr, &self.layout, self.colors, 1.0, "");
        paint.paintAppsBtn(cr, &self.layout, self.colors, 1.0, false, false);
        const chrome_us = nowUs() - t;
        t = nowUs();
        self.paintRail(cr);
        const rail_us = nowUs() - t;
        logz.log("overview: stages base={d:.1} body={d:.1} cchrome={d:.1} live={d:.1} tint={d:.1} icon={d:.1} title={d:.1} label={d:.1} ghost={d:.1} chrome={d:.1} rail={d:.1}", .{
            ms(base_us),
            ms(body_us),
            ms(cchrome_us),
            ms(live_us),
            ms(tint_us),
            ms(icon_us),
            ms(title_us),
            ms(label_us),
            ms(ghost_us),
            ms(chrome_us),
            ms(rail_us),
        });
    }

    /// The card fill-plus-glass for this card size, baked once. Cards
    /// share one size per layout, so the gradients repaint never again.
    fn cardChrome(self: *Self, w: f64, h: f64) ?*cairo.cairo_surface_t {
        const iw: i32 = @intFromFloat(@ceil(w));
        const ih: i32 = @intFromFloat(@ceil(h));
        if (iw <= 0 or ih <= 0) return null;
        if (self.card_chrome) |s| {
            if (self.card_chrome_w == iw and self.card_chrome_h == ih) return s;
        }
        self.dropCardChrome();
        const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, iw, ih);
        if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(surf);
            return null;
        }
        const c = cairo.cairo_create(surf);
        const bg = self.colors.card_bg;
        cairo.cairo_set_source_rgba(c, bg[0], bg[1], bg[2], 0.9);
        cairo_helpers.roundedRect(c, 0, 0, w, h, 24.0 * self.ui);
        cairo.cairo_fill(c);
        dw.paintGlassLayers(c, 0, 0, w, h, 1.0, 24.0 * self.ui);
        cairo.cairo_destroy(c);
        if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(surf);
            return null;
        }
        self.card_chrome = surf;
        self.card_chrome_w = iw;
        self.card_chrome_h = ih;
        return surf;
    }

    fn dropCardChrome(self: *Self) void {
        if (self.card_chrome) |s| {
            cairo.cairo_surface_destroy(s);
            self.card_chrome = null;
        }
        self.card_chrome_w = 0;
        self.card_chrome_h = 0;
    }

    /// Chrome with the wallpaper fitted over it, composed once. Cards
    /// share one size and one wallpaper, so every card blits this single
    /// surface and the per-paint cost stops scaling with card count.
    fn cardBase(self: *Self, w: f64, h: f64) ?*cairo.cairo_surface_t {
        const iw: i32 = @intFromFloat(@ceil(w));
        const ih: i32 = @intFromFloat(@ceil(h));
        if (iw <= 0 or ih <= 0) return null;
        const wpgen = if (self.wallpaper_frame) |fr| fr.gen else 0;
        if (self.card_base) |s| {
            if (self.card_base_w == iw and self.card_base_h == ih and self.card_base_wpgen == wpgen) return s;
        }
        self.dropCardBase();
        const chrome = self.cardChrome(w, h) orelse return null;
        const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, iw, ih);
        if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(surf);
            return null;
        }
        const c = cairo.cairo_create(surf);
        cairo.cairo_set_source_surface(c, chrome, 0, 0);
        cairo.cairo_paint(c);
        if (self.wallpaper_frame) |fr| {
            const f = tiles.fittedSurface(&self.scaled, .wallpaper, 0, w, h, fr);
            if (f.surf) |fs| {
                cairo.cairo_set_source_surface(c, fs, f.dx, f.dy);
                cairo.cairo_paint(c);
            }
        }
        cairo.cairo_destroy(c);
        if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(surf);
            return null;
        }
        self.card_base = surf;
        self.card_base_w = iw;
        self.card_base_h = ih;
        self.card_base_wpgen = wpgen;
        return surf;
    }

    fn dropCardBase(self: *Self) void {
        if (self.card_base) |s| {
            cairo.cairo_surface_destroy(s);
            self.card_base = null;
        }
        self.card_base_w = 0;
        self.card_base_h = 0;
        self.card_base_wpgen = 0;
    }

    fn gridIcon(ctx: *anyopaque, icon: []const u8) ?*cairo.cairo_surface_t {
        const a: *apps_mod.Apps = @ptrCast(@alignCast(ctx));
        return a.surfCached(icon);
    }

    /// Whether the last grid paint left icons unresolved. The tick
    /// keeps running while true so the grid completes off the input path.
    pub fn iconsPending(self: *const Self) bool {
        return self.open and self.show_apps and self.apps.icon_pending;
    }

    /// Tick work: warm uncached icons within budget. True when a repaint
    /// is owed to show what landed. Card windows resolve through the same
    /// cache, so their classes ride along with the grid's names.
    pub fn fillIcons(self: *Self) bool {
        if (!self.iconsPending()) return false;
        var extra: [64][]const u8 = undefined;
        var n_extra: usize = 0;
        for (self.cards) |card| {
            for (card.wins) |win| {
                if (n_extra >= extra.len) break;
                if (win.app_id.len == 0) continue;
                extra[n_extra] = win.app_id;
                n_extra += 1;
            }
            if (n_extra >= extra.len) break;
        }
        _ = self.apps.prefetch(25, extra[0..n_extra]);
        return true;
    }

    fn paintApps(self: *Self, cr: ?*cairo.cairo_t) void {
        var cells: [256]gridpaint.Cell = undefined;
        var n: usize = 0;
        for (self.apps.folders.items, 0..) |it, i| {
            if (n >= cells.len) break;
            if (it.folder) {
                if (it.index >= self.apps.folders.folders.len) continue;
                const f = self.apps.folders.folders[it.index];
                var cell = gridpaint.Cell{ .name = f.name, .folder = true, .key = it.key };
                var m: usize = 0;
                for (f.members) |p| {
                    if (m >= 4) break;
                    const icon = self.apps.memberIcon(p);
                    if (icon.len == 0) continue;
                    cell.members[m] = icon;
                    m += 1;
                }
                cell.member_count = m;
                cells[n] = cell;
            } else {
                if (self.apps.gridAppIndex(i)) |cat_idx| {
                    const e = self.apps.catalog.entries[cat_idx];
                    cells[n] = .{ .name = e.name, .icon = e.icon, .key = it.key };
                } else continue;
            }
            n += 1;
        }
        const icons = gridpaint.GridIcons{ .ctx = &self.apps, .get = gridIcon };
        self.apps.icon_pending = false;
        self.apps.dbg_resolves = 0;
        self.apps.dbg_resolve_ms = 0;
        self.apps.dbg_disk_hits = 0;
        if (n == 0) {
            gridpaint.paintEmpty(cr, &self.layout.grid, self.layout.w, self.layout.ui, self.colors, self.launchpad_alpha);
            return;
        }
        const drag = self.gridDrag(false);
        gridpaint.paintGrid(cr, &self.layout.grid, self.layout.ui, self.colors, cells[0..n], self.apps.hovered, self.apps.scroll, self.launchpad_alpha, icons, drag);
        if (drag.active) {
            if (self.gridGhostCell()) |gcell| {
                gridpaint.paintGhost(cr, &self.layout.grid, self.layout.ui, self.colors, gcell, drag.ghost_x, drag.ghost_y, self.launchpad_alpha, icons);
            }
        }
        if (self.apps.dbg_resolves > 0) {
            logz.log("overview: grid icons {d} resolves ({d} disk) {d}ms", .{ self.apps.dbg_resolves, self.apps.dbg_disk_hits, self.apps.dbg_resolve_ms });
        }
        gridpaint.paintPageDots(cr, &self.layout.grid, self.layout.w, self.layout.ui, self.colors, self.apps.scroll, self.launchpad_alpha);
        if (self.apps.modalOpen()) self.paintModal(cr, icons);
        if (self.apps.ctx_open) {
            gridpaint.paintCtxMenu(cr, self.layout.ui, self.colors, self.apps.ctx_rect, self.apps.ctx_labels.items, self.apps.ctx_hover, self.launchpad_alpha);
        }
    }

    /// Drag state for one grid paint: ghost origin follows the pointer,
    /// insert marker sits at the hovered cell's edge, shuffle offsets ease
    /// cells from their pre-drop origins for 200ms.
    fn gridDrag(self: *Self, modal: bool) gridpaint.Drag {
        var drag = gridpaint.Drag{ .now_ms = nowMs() };
        if (!self.drag_active or self.press_app < 0 or self.press_app_modal != modal) return drag;
        drag.active = true;
        drag.drag_idx = self.press_app;
        drag.ghost_x = self.drop_px - self.drag_grab_dx;
        drag.ghost_y = self.drop_py - self.drag_grab_dy;
        if (!modal and self.drop_cell >= 0 and self.drop_cell != self.press_app) {
            const cell = gridmod.cellRect(&self.layout.grid, self.drop_cell, self.apps.scroll);
            if (cell.w > 0.0) {
                const edge = (self.drop_px - cell.x) / cell.w > 0.5;
                drag.insert_show = true;
                drag.ins_x = if (edge) cell.x + cell.w else cell.x;
                drag.ins_y = cell.y + 8.0 * self.layout.ui;
                drag.ins_h = cell.h - 16.0 * self.layout.ui;
            }
        }
        if (self.shuffle_keys.items.len > 0 and self.shuffle_modal == modal and
            nowMs() - self.shuffle_start_ms < 250)
        {
            drag.shuffle_start_ms = self.shuffle_start_ms;
            drag.shuffle = self.shuffleView();
        }
        return drag;
    }

    /// Shuffle snapshot as paint-borrowed entries.
    fn shuffleView(self: *Self) []gridpaint.ShuffleFrom {
        const m = @min(self.shuffle_keys.items.len, self.shuffle_buf.len);
        var i: usize = 0;
        while (i < m) : (i += 1) {
            self.shuffle_buf[i] = .{
                .key = self.shuffle_keys.items[i],
                .x = self.shuffle_x.items[i],
                .y = self.shuffle_y.items[i],
            };
        }
        return self.shuffle_buf[0..m];
    }

    /// Ghost content for the lifted cell.
    fn gridGhostCell(self: *Self) ?gridpaint.Cell {
        if (self.press_app < 0) return null;
        if (self.press_app_modal) {
            if (!self.apps.modalOpen()) return null;
            const m = self.apps.folders.folders[@intCast(self.apps.open_folder)].members;
            const mi: usize = @intCast(self.press_app);
            if (mi >= m.len) return null;
            if (self.apps.entryByPath(m[mi])) |e| {
                return .{ .name = e.name, .icon = e.icon };
            }
            return null;
        }
        const pi: usize = @intCast(self.press_app);
        if (pi >= self.apps.folders.items.len) return null;
        const it = self.apps.folders.items[pi];
        if (it.folder) {
            if (it.index >= self.apps.folders.folders.len) return null;
            const f = self.apps.folders.folders[it.index];
            var cell = gridpaint.Cell{ .name = f.name, .folder = true, .key = it.key };
            var mc: usize = 0;
            for (f.members) |p| {
                if (mc >= 4) break;
                const icon = self.apps.memberIcon(p);
                if (icon.len == 0) continue;
                cell.members[mc] = icon;
                mc += 1;
            }
            cell.member_count = mc;
            return cell;
        }
        if (self.apps.gridAppIndex(pi)) |cat_idx| {
            const e = self.apps.catalog.entries[cat_idx];
            return .{ .name = e.name, .icon = e.icon, .key = it.key };
        }
        return null;
    }

    fn paintModal(self: *Self, cr: ?*cairo.cairo_t, icons: gridpaint.GridIcons) void {
        var cells: [256]gridpaint.Cell = undefined;
        var n: usize = 0;
        const m = self.apps.folders.folders[@intCast(self.apps.open_folder)].members;
        for (m) |p| {
            if (n >= cells.len) break;
            if (self.apps.entryByPath(p)) |e| {
                cells[n] = .{ .name = e.name, .icon = e.icon };
                n += 1;
            }
        }
        var title: [128]u8 = undefined;
        const t = self.apps.folderTitle(&title);
        const drag = self.gridDrag(true);
        gridpaint.paintModal(cr, &self.layout.modal, self.layout.w, self.layout.h, self.layout.ui, self.colors, t, cells[0..n], self.apps.modal_hovered, self.apps.modal_scroll, self.launchpad_alpha, icons, drag);
        if (drag.active) {
            if (self.gridGhostCell()) |gcell| {
                gridpaint.paintGhost(cr, &self.layout.modal, self.layout.ui, self.colors, gcell, drag.ghost_x, drag.ghost_y, self.launchpad_alpha, icons);
            }
        }
    }

    fn paintRail(self: *Self, cr: ?*cairo.cairo_t) void {
        var thumbs: [32]strip.Thumb = undefined;
        var idbuf: [64][]const u8 = undefined;
        var addrbuf: [64][]const u8 = undefined;
        var used: usize = 0;
        const n = @min(self.cards.len, thumbs.len);
        for (self.cards[0..n], 0..) |card, i| {
            const m = @min(card.wins.len, idbuf.len - used);
            for (card.wins[0..m], 0..) |win, k| {
                idbuf[used + k] = win.app_id;
                addrbuf[used + k] = win.addr;
            }
            const live_shot = if (self.shots) |lk| lk.call(lk.ctx, card.monitor) else null;
            // Empty thumbs sit on the wallpaper like empty cards do — a
            // desktop copy would paint other workspaces' windows onto
            // them. Occupied thumbs keep the monitor shot behind live
            // window cells.
            var shot_kind: tiles.SrcKind = .monitor;
            var shot_id: u64 = tiles.hashId(card.monitor);
            var shot = live_shot;
            if (card.wins.len == 0) {
                if (self.wallpaper_frame) |wp| {
                    shot = wp;
                    shot_kind = .wallpaper;
                    shot_id = 0;
                }
            }
            thumbs[i] = .{
                .app_ids = idbuf[used .. used + m],
                .addrs = addrbuf[used .. used + m],
                .label = card.label,
                .active = card.active,
                .monitor = card.monitor,
                .shot = shot,
                .shot_kind = shot_kind,
                .shot_id = shot_id,
            };
            used += m;
        }
        const frames: ?tiles.FrameLookup = if (self.frames) |f| .{ .ctx = f.ctx, .call = f.call } else null;
        const drop_qs: i32 = if (self.drag_active and !self.show_apps and self.drop_ws >= 0 and self.hovered_qs == self.drop_ws) self.hovered_qs else -1;
        strip.paintStrip(cr, &self.scaled, &self.layout.strip, self.ui, self.colors, thumbs[0..n], frames, self.qs_scroll, self.selected(), self.hovered_qs, drop_qs, 1.0);
    }
};

const cairo = shm_mod.cairo;

fn appsHit(l: *const Layout, mx: f64, my: f64) bool {
    return l.apps_btn.contains(mx, my);
}

test "overview-host: press maps tiles, gaps select, outside dismisses" {
    const t = std.testing;
    var h = Host.init(t.allocator, t.io);
    defer h.deinit();
    h.buf_w = 1920;
    h.buf_h = 1080;
    const wins = [_]Win{ .{ .app_id = "a", .title = "one" }, .{ .app_id = "b", .title = "two" } };
    const cards = [_]Card{
        .{ .id = 1, .label = "1", .active = true, .wins = @constCast(&wins) },
        .{ .id = 2, .label = "2", .wins = &.{} },
    };
    h.setCards(&cards);
    h.open = true;
    try t.expectEqual(@as(usize, 2), h.flatCount());
    try t.expectEqual([2]usize{ 0, 1 }, h.flatLoc(1).?);
    try t.expect(h.flatLoc(2) == null);
    try t.expectEqual(@as(i32, 0), h.selected());
    const t0 = h.tileAt(0, 0);
    // Press records, release activates (click); drags never launch.
    try t.expect(h.press(t0.x + 2, t0.y + 2, 0x110, true) == .none);
    switch (h.press(t0.x + 2, t0.y + 2, 0x110, false)) {
        .focus => |i| try t.expectEqual(@as(usize, 0), i),
        else => return error.TestUnexpectedResult,
    }
    try t.expect(h.motion(t0.x + 2, t0.y + 2));
    try t.expectEqual(@as(i32, 0), h.hovered_win);
    try t.expectEqual(@as(i32, 0), h.hovered_ws);
    try t.expect(!h.motion(t0.x + 2, t0.y + 2));
    try t.expect(h.key(seat_mod.xkb.XKB_KEY_Escape, true, "") == .dismiss);
    try t.expect(h.press(2, 2, 0x110, true) == .dismiss);
    // Second card gap selects by workspace id.
    const c1 = lay.cardRect(&h.layout, 1, h.scroll);
    switch (h.press(c1.x + 4, c1.y + 4, 0x110, true)) {
        .select_ws => |id| try t.expectEqual(@as(i32, 2), id),
        else => return error.TestUnexpectedResult,
    }
    // One notch (15 units) moves exactly one card and a double notch
    // moves two; the strip ends clamp. Motion eases toward the target,
    // so each glide settles before asserting where it landed.
    try t.expect(h.wheel(15.0));
    try t.expect(h.scrollActive());
    while (h.scrollActive()) _ = h.scrollTick(1.0);
    try t.expectEqual(@as(i32, 1), h.selected());
    try t.expect(!h.wheel(7.5));
    // Halves accumulate into a full step back; the far end clamps.
    try t.expect(h.wheel(-22.5));
    while (h.scrollActive()) _ = h.scrollTick(1.0);
    try t.expectEqual(@as(i32, 0), h.selected());
    try t.expect(!h.wheel(-15.0));
    // A fling past the end clamps to no move, not a wrap.
    try t.expect(!h.wheel(-150.0));
    try t.expectEqual(@as(i32, 0), h.selected());
    try t.expectEqual(@as(f64, 0), h.scroll);
    // Printable text anywhere summons the launchpad already searching.
    switch (h.key(0, true, "fi")) {
        .refresh => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expect(h.show_apps);
    try t.expectEqualStrings("fi", h.apps.query.items);
    // Esc with a query clears it and stays; empty query exits outright.
    switch (h.key(seat_mod.xkb.XKB_KEY_Escape, true, "")) {
        .refresh => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqual(@as(usize, 0), h.apps.query.items.len);
    try t.expect(h.show_apps);
    switch (h.key(seat_mod.xkb.XKB_KEY_Escape, true, "")) {
        .dismiss => {},
        else => return error.TestUnexpectedResult,
    }
}

test "overview-host: dragging a window to the edge scrolls the strip" {
    const t = std.testing;
    var h = Host.init(t.allocator, t.io);
    defer h.deinit();
    h.buf_w = 1920;
    h.buf_h = 1080;
    const wins = [_]Win{.{ .app_id = "a", .title = "one" }};
    const cards = [_]Card{
        .{ .id = 1, .label = "1", .active = true, .wins = @constCast(&wins) },
        .{ .id = 2, .label = "2", .wins = &.{} },
        .{ .id = 3, .label = "3", .wins = &.{} },
    };
    h.setCards(&cards);
    h.open = true;
    // Grab the tile on card 0, then drag straight to the bottom edge in one
    // motion: the threshold branch must arm auto-scroll without another move.
    const tile = h.tileAt(0, 0);
    try t.expect(h.press(tile.x + 2, tile.y + 2, 0x110, true) == .none);
    _ = h.motion(tile.x + 2, 1075);
    try t.expect(h.drag_active);
    try t.expectEqual(@as(i32, 1), h.drag_edge_dir);
    const before = h.scroll_target;
    try t.expect(h.edgeScrollTick(0.1));
    try t.expect(h.scroll_target > before);
    // Keeping the pointer parked at the edge keeps advancing until the last
    // workspace is centered.
    for (0..120) |_| {
        _ = h.edgeScrollTick(0.1);
        _ = h.scrollTick(0.1);
    }
    try t.expectEqual(@as(i32, 2), h.selected());
    // Top edge runs the other way.
    _ = h.motion(tile.x + 2, 2);
    try t.expectEqual(@as(i32, -1), h.drag_edge_dir);
    const back = h.scroll_target;
    try t.expect(h.edgeScrollTick(0.1));
    try t.expect(h.scroll_target < back);
}

test "overview-host: dropping a window on a quick-select thumb moves it" {
    const t = std.testing;
    const wins = [_]Win{.{ .app_id = "a", .title = "one" }};
    const cards = [_]Card{
        .{ .id = 1, .label = "1", .active = true, .wins = @constCast(&wins) },
        .{ .id = 2, .label = "2", .wins = &.{} },
        .{ .id = 3, .label = "3", .wins = &.{} },
    };
    // The strip sits at the bottom for a horizontal layout and on the left
    // for a vertical one; both must accept the drop.
    for ([_]types.Axis{ .horizontal, .vertical }) |axis| {
        var h = Host.init(t.allocator, t.io);
        defer h.deinit();
        h.buf_w = 1920;
        h.buf_h = 1080;
        h.axis = axis;
        h.setCards(&cards);
        h.open = true;
        const tile = h.tileAt(0, 0);
        try t.expect(h.press(tile.x + 2, tile.y + 2, 0x110, true) == .none);
        // Drag straight to the third workspace's thumb.
        const thumb = pick.stripThumb(&h.layout.strip, 3, 2, h.qs_scroll);
        const tx = thumb.x + thumb.w * 0.5;
        const ty = thumb.y + thumb.h * 0.5;
        _ = h.motion(tx, ty);
        try t.expect(h.drag_active);
        try t.expectEqual(@as(i32, 2), h.drop_ws);
        try t.expectEqual(@as(i32, 2), h.hovered_qs);
        switch (h.press(tx, ty, 0x110, false)) {
            .move_win => |m| {
                try t.expectEqual(@as(usize, 0), m.flat);
                try t.expectEqual(@as(i32, 2), m.ws);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "overview-host: folders open, drag reorders, ctx menu pins" {
    const t = std.testing;
    const cat = @import("../../services/app_catalog.zig");
    var h = Host.init(t.allocator, t.io);
    defer h.deinit();
    h.buf_w = 1920;
    h.buf_h = 1080;
    h.open = true;
    // Fake catalog: two utilities + one game, no filesystem reads.
    const entries = [_]cat.Entry{
        .{ .id = "one", .path = "/a/one.desktop", .name = "One", .categories = "Utility;", .exec = "one", .icon = "one" },
        .{ .id = "two", .path = "/a/two.desktop", .name = "Two", .categories = "Utility;", .exec = "two", .icon = "two" },
        .{ .id = "three", .path = "/a/three.desktop", .name = "Three", .categories = "Game;", .exec = "three", .icon = "three" },
    };
    h.apps.loaded = true;
    h.apps.catalog.entries = @constCast(&entries);
    h.show_apps = true;
    h.apps.refresh();
    h.relayout();
    // Two utilities form an auto folder; the game stays loose.
    try t.expectEqual(@as(usize, 1), h.apps.folders.folders.len);
    try t.expectEqual(@as(usize, 2), h.apps.folders.items.len);
    // Release on the folder opens it (no launch).
    const c0 = gridmod.cellRect(&h.layout.grid, 0, 0);
    try t.expect(h.press(c0.x + 4, c0.y + 4, 0x110, true) == .none);
    switch (h.press(c0.x + 4, c0.y + 4, 0x110, false)) {
        .refresh => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expect(h.apps.modalOpen());
    // Release on a modal cell launches it by catalog index.
    const m0 = gridmod.cellRect(&h.layout.modal, 0, 0);
    try t.expect(h.press(m0.x + 4, m0.y + 4, 0x110, true) == .none);
    switch (h.press(m0.x + 4, m0.y + 4, 0x110, false)) {
        .launch_modal => {},
        else => return error.TestUnexpectedResult,
    }
    // Right-click on a loose app opens the pin menu (folder closed, so
    // the main grid is the target). The binary opens the menu from the
    // action; the test simulates that call.
    h.apps.closeFolder();
    const c1 = gridmod.cellRect(&h.layout.grid, 1, 0);
    const cx = c1.x + 4;
    const cy = c1.y + 4;
    switch (h.press(cx, cy, 0x111, true)) {
        .ctx_menu => |m| h.apps.openCtx(m.x, m.y, 1920, 1080, 1.0, m.path, false, false),
        else => return error.TestUnexpectedResult,
    }
    try t.expect(h.apps.ctx_open);
    h.apps.closeCtx();
    // Small motion stays a click; 8px+ becomes a drag.
    h.apps.closeFolder();
    try t.expect(h.press(c1.x + 4, c1.y + 4, 0x110, true) == .none);
    try t.expect(!h.drag_active);
    _ = h.motion(c1.x + 6, c1.y + 6);
    try t.expect(!h.drag_active);
    _ = h.motion(c1.x + 40, c1.y + 40);
    try t.expect(h.drag_active);
}

test "overview-host: rename commits, drag-out removes, reorder persists" {
    const t = std.testing;
    const cat = @import("../../services/app_catalog.zig");
    var h = Host.init(t.allocator, t.io);
    defer h.deinit();
    h.buf_w = 1920;
    h.buf_h = 1080;
    h.open = true;
    const entries = [_]cat.Entry{
        .{ .id = "one", .path = "/a/one.desktop", .name = "One", .categories = "Utility;", .exec = "one", .icon = "one" },
        .{ .id = "two", .path = "/a/two.desktop", .name = "Two", .categories = "Utility;", .exec = "two", .icon = "two" },
    };
    h.apps.loaded = true;
    h.apps.catalog.entries = @constCast(&entries);
    h.show_apps = true;
    h.apps.refresh();
    h.relayout();
    try t.expectEqual(@as(usize, 1), h.apps.folders.folders.len);
    // Release on the folder cell opens the modal.
    const c0 = gridmod.cellRect(&h.layout.grid, 0, 0);
    try t.expect(h.press(c0.x + 4, c0.y + 4, 0x110, true) == .none);
    _ = h.press(c0.x + 4, c0.y + 4, 0x110, false);
    try t.expect(h.apps.modalOpen());
    // Title click starts inline rename; typing + Return commits it.
    const mbox = gridmod.modalBox(&h.layout.modal, 1.0);
    try t.expect(h.press(mbox.x + 10, mbox.y - 10, 0x110, true) == .refresh);
    try t.expect(h.apps.rename.active);
    switch (h.key(0, true, "X")) {
        .refresh => {},
        else => return error.TestUnexpectedResult,
    }
    switch (h.key(seat_mod.xkb.XKB_KEY_Return, true, "")) {
        .refresh => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expect(!h.apps.rename.active);
    // Modal drag-out release removes the app from the folder.
    const m0 = gridmod.cellRect(&h.layout.modal, 0, 0);
    try t.expect(h.press(m0.x + 4, m0.y + 4, 0x110, true) == .none);
    _ = h.motion(m0.x + 400, m0.y + 400);
    try t.expect(h.drag_active);
    switch (h.press(10, 10, 0x110, false)) {
        .refresh => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqual(@as(usize, 1), h.apps.folders.folders[0].members.len);
}

test "overview-host: plain center drop reorders, ctrl drop makes a folder" {
    const t = std.testing;
    const cat = @import("../../services/app_catalog.zig");
    var h = Host.init(t.allocator, t.io);
    defer h.deinit();
    h.buf_w = 1920;
    h.buf_h = 1080;
    h.open = true;
    // Three single-category apps, spread across buckets, so nothing folders.
    const entries = [_]cat.Entry{
        .{ .id = "one", .path = "/a/one.desktop", .name = "One", .categories = "Utility;", .exec = "one", .icon = "one" },
        .{ .id = "two", .path = "/a/two.desktop", .name = "Two", .categories = "Network;", .exec = "two", .icon = "two" },
        .{ .id = "three", .path = "/a/three.desktop", .name = "Three", .categories = "Game;", .exec = "three", .icon = "three" },
    };
    h.apps.loaded = true;
    h.apps.catalog.entries = @constCast(&entries);
    h.show_apps = true;
    h.apps.refresh();
    h.relayout();
    try t.expectEqual(@as(usize, 0), h.apps.folders.folders.len);
    try t.expectEqual(@as(usize, 3), h.apps.folders.items.len);
    // Plain drop in the center of cell 2 moves app 0 after it, no folder.
    const c0 = gridmod.cellRect(&h.layout.grid, 0, 0);
    const c2 = gridmod.cellRect(&h.layout.grid, 2, 0);
    try t.expect(h.press(c0.x + 4, c0.y + 4, 0x110, true) == .none);
    _ = h.motion(c2.x + c2.w * 0.5, c2.y + c2.h * 0.5);
    try t.expect(h.drag_active);
    _ = h.press(c2.x + c2.w * 0.5, c2.y + c2.h * 0.5, 0x110, false);
    try t.expectEqual(@as(usize, 0), h.apps.folders.folders.len);
    // Order is now two, one, three (app 0 dropped before cell 2).
    try t.expect(std.mem.eql(u8, "/a/two.desktop", h.apps.gridItemPath(0)));
    try t.expect(std.mem.eql(u8, "/a/one.desktop", h.apps.gridItemPath(1)));
    // Same drop with Ctrl held makes the folder.
    try t.expect(h.press(c0.x + 4, c0.y + 4, 0x110, true) == .none);
    h.drop_ctrl = true;
    _ = h.motion(c2.x + c2.w * 0.5, c2.y + c2.h * 0.5);
    _ = h.press(c2.x + c2.w * 0.5, c2.y + c2.h * 0.5, 0x110, false);
    h.drop_ctrl = false;
    try t.expectEqual(@as(usize, 1), h.apps.folders.folders.len);
    try t.expectEqual(@as(usize, 2), h.apps.folders.folders[0].members.len);
}

test "overview-host: finger glides 1:1 and snaps to a card on lift" {
    const t = std.testing;
    var h = Host.init(t.allocator, t.io);
    defer h.deinit();
    h.open = true;
    const cards = [_]Card{
        .{ .id = 1, .label = "1", .active = true, .wins = &.{} },
        .{ .id = 2, .label = "2", .wins = &.{} },
        .{ .id = 3, .label = "3", .wins = &.{} },
    };
    h.setCards(&cards);
    h.layout.pitch = 1000;
    // 62.5 units * 0.008 * pitch lands mid-card: continuous, no notch.
    try t.expect(h.panFinger(62.5));
    try t.expectEqual(@as(f64, 500.0), h.scroll_target);
    try t.expectEqual(@as(f64, 0.0), h.scroll);
    // Motion cancels a pending snap; lift schedules one after the delay.
    h.snap_at_ms = 123;
    try t.expect(h.panFinger(31.25));
    try t.expectEqual(@as(u64, 0), h.snap_at_ms);
    try t.expect(h.axisStop(1000));
    try t.expectEqual(@as(u64, 1200), h.snap_at_ms);
    // The snap itself goes to the nearest whole card; the glide follows.
    try t.expect(h.snapTargets());
    try t.expectEqual(@as(f64, 1000.0), h.scroll_target);
    while (h.scrollActive()) _ = h.scrollTick(1.0);
    try t.expectEqual(@as(f64, 1000.0), h.scroll);
    try t.expectEqual(@as(i32, 1), h.selected());
    // Past the end clamps instead of wrapping.
    try t.expect(h.panFinger(100000.0));
    try t.expectEqual(@as(f64, 2000.0), h.scroll_target);
    try t.expect(!h.panFinger(100000.0));
}

test "overview-host: tall rail scrolls on its own target" {
    const t = std.testing;
    var h = Host.init(t.allocator, t.io);
    defer h.deinit();
    h.open = true;
    // A wheel notch does nothing while everything fits.
    try t.expect(!h.wheelRail(15.0));
    h.layout.strip.scroll_max = 1000;
    h.layout.strip.horizontal = false;
    h.layout.strip.thumb_h = 100;
    h.layout.strip.gap = 8;
    // One notch moves one thumb; fingers glide 1:1 pixels.
    try t.expect(h.wheelRail(15.0));
    try t.expectEqual(@as(f64, 108.0), h.qs_scroll_target);
    try t.expect(h.panRail(50.0));
    try t.expectEqual(@as(f64, 158.0), h.qs_scroll_target);
    // Clamps at both ends, glides to rest.
    try t.expect(h.panRail(100000.0));
    try t.expectEqual(@as(f64, 1000.0), h.qs_scroll_target);
    try t.expect(!h.panRail(1.0));
    while (h.scrollActive()) _ = h.scrollTick(1.0);
    try t.expectEqual(@as(f64, 1000.0), h.qs_scroll);
}
