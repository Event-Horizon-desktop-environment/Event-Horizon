//! The dock's popups: the right-click menu's row model, the three content
//! cards (calendar, weather, media) a widget slot opens, and the start menu.
//! All of them share one layer surface, one buffer and one pointer route, so
//! the dock only has to know about a single extra surface.
//!
//! The start menu is the odd one out: it takes the keyboard while it is up, so
//! its layer surface asks for exclusive `keyboard_interactivity` and every
//! keystroke the seat sees arrives here with no `wl_keyboard.enter` of its own.
//!
//! The surface placement is the interesting part, and it is decided per kind.
//!
//! The cards share one trick: each is anchored `.bottom` with no left or
//! right anchor — exactly like the dock — and built *as wide as the dock*. Two
//! bottom-anchored, horizontally centred surfaces of equal width land on the
//! same x within the output, so the card can then be drawn at any local x it
//! likes with no output geometry in sight. That sidesteps the question of
//! which output the dock is on, which is a question a client cannot ask: the
//! compositor picks one at `get_layer_surface` time and never says which.
//! The vertical half needs no output either — the dock's bottom edge is the
//! output's bottom edge, so `dock_h - pointer_y` *is* the pointer's height
//! above the output, which is what a bottom margin is measured in.
//!
//! The start menu cannot use that trick, because it is deliberately narrower
//! than the dock and has to sit over one particular slot rather than in the
//! middle. It is instead created on the *same output as the dock itself* and
//! pushed into the bottom-left corner with a computed left margin, which is
//! the only way to name "just left of the panel" in layer-shell terms. That
//! needs to know where the dock starts on its output, so it is the one popup
//! that has an output to reason about; `popup_position.place` does the
//! arithmetic and the cards carry on as they were.

const std = @import("std");
const reflection = @import("../../compat/reflection.zig");
const wl = @import("../../wl/c.zig").wl;
const layer = @import("../../wl/surface/layer.zig");
const shm_mod = @import("../../wl/buffer/shm.zig");
const cairo = shm_mod.cairo;
const pmp = @import("../shared/popup_menu_paint.zig");
const helpers = @import("../shared/cairo_helpers.zig");
const popup_position = @import("../shared/popup_position.zig");
const cal_card = @import("../widgets/calendar_card.zig");
const wx_card = @import("../widgets/weather_fancy_card.zig");
const chrome = @import("../widgets/shared/chrome_colors.zig");
const launcher_layout = @import("../widgets/launcher_layout.zig");
const launcher_paint = @import("../widgets/launcher_paint.zig");
const launcher_rail_paint = @import("../widgets/launcher_rail_paint.zig");
const launcher_menu = @import("launcher_menu.zig");
const media_card = @import("../widgets/media/media_popup.zig");
const bt_card = @import("../widgets/bluetooth/bluetooth_paint.zig");
const vpn_card = @import("../widgets/vpn_popup.zig");
const mixer_card = @import("../widgets/volume_mixer.zig");
const lay_card = @import("../widgets/popup/layout/layout_popup.zig");
const wc_session = @import("../widgets/world_clock/session.zig");
const wc_panel = @import("../widgets/world_clock/panel.zig");
const schema = @import("../../config/schema.zig");
const overlay = @import("../../config/overlay.zig");
const ns = @import("../common/namespaces.zig");
const desktop_actions = @import("../../services/desktop_actions.zig");

/// The row type lives with the chrome that paints it; the popup only adds
/// ids, surface placement and hit-testing on top.
pub const Row = pmp.Row;
pub const isSeparator = pmp.isSeparator;

/// Popup action enum.
pub const Action = enum(i32) {
    close_one = 1,
    close_all = 2,
    pin_toggle = 3,
    minimize_one = 4,
    minimize_all = 5,
    toggle_maximize = 6,
    toggle_fullscreen = 7,
};

/// A row id back to its `Action`. Ids outside the enum are the window band,
/// the desktop-action band and `new_window`, none of which mean anything here.
pub fn actionFromId(id: i32) ?Action {
    inline for (reflection.enumFields(Action)) |f| {
        if (id == @as(i32, @intCast(f.value))) return @enumFromInt(f.value);
    }
    return null;
}

/// `popup_open_for_app` hands desktop actions the 1000 band and one row per
/// window the 2000 band; `New Window` gets a fixed 3000. Anything else in a
/// menu comes from one of those two, or from a tray `com.canonical.dbusmenu`
/// item id, which is its own numbering entirely.
pub const desktop_action_first: i32 = 1000;
pub const window_first: i32 = 2000;
pub const window_band: i32 = 1000;
pub const new_window: i32 = 3000;

pub fn isWindowId(id: i32) bool {
    return id >= window_first and id < window_first + window_band;
}

pub fn windowIndex(id: i32) ?usize {
    if (!isWindowId(id)) return null;
    return @intCast(id - window_first);
}

pub fn isDesktopActionId(id: i32) bool {
    return id >= desktop_action_first and id < window_first;
}

/// `none` — nothing open. `.app` / `.tray` — a right-click menu over rows.
/// `.calendar`, `.weather` and `.media_player` — the content cards a widget
/// slot opens; the first two answer a click with the nav buttons or
/// "dismiss", the last one with whichever control it landed on.
/// `.bluetooth` and `.vpn` — the two list cards a status slot opens; they
/// answer with a verb for the host to run on the bus (BlueZ / nmcli),
/// split between "what was hit" and "what to do".
/// `.volume_mixer` is the third of those cards, fixed at 600×620 and fed
/// entirely by state the dock pushes into it.
/// `.launcher` — the start menu, and `.world_clock` — the world clock's
/// panel, which are the two that hold the keyboard while they are up.
pub const Kind = enum { none, app, tray, calendar, weather, launcher, media_player, bluetooth, vpn, volume_mixer, layout, world_clock };
const gap_above_dock: f64 = 6.0;

/// `zwlr_layer_shell_v1`'s value for "give this surface the keyboard". The
/// enum does not travel through the protocol bindings, so it is spelled out.
const kb_exclusive: u32 = 2;

/// What a card click decided. `.prev_month` / `.next_month` redraw the card
/// in place; `.dismiss` tears it down. The `media_*` answers are the control
/// the click landed on — the dock turns each one into a call on the player,
/// and a `.media_seek` also carries the fraction the host worked out.
pub const CardClick = enum {
    none,
    prev_month,
    next_month,
    dismiss,
    media_shuffle,
    media_prev,
    media_play,
    media_next,
    media_repeat,
    media_seek,
    /// `.bluetooth` / `.vpn`: the hit-test landed on a control and the verb
    /// it asks for is parked in `bt_click` / `vpn_click`, exactly the way
    /// `.media_seek` carries its fraction. The host reads the verb, runs it
    /// on the bus, and re-syncs.
    bluetooth,
    vpn,
    /// `.volume_mixer`: same deal — the click resolved inside the card and
    /// its `Effect` (plus the tab-switch flag) is parked in `mx_click`. The
    /// volume/mute/route write itself is the host's to run.
    volume_mixer,
    /// `.layout`: the click resolved *inside* the card, which applied the
    /// swap itself on the way through. There is no verb left for the host to run, only
    /// a redraw.
    layout,
};

/// The mixer card's snapshot before the first landing arrives: every list is
/// empty, so the card draws its empty state rather than reading anything the
/// host has not pushed yet.
const mx_empty_snapshot: mixer_card.Snapshot = .{};

/// Wall-clock milliseconds: the panel's header date, row times and the
/// switch animations are real time, while the dock's own clock is monotonic.
/// `std.time` carries only constants in this Zig; the epoch comes from a
/// REALTIME `clock_gettime`, the same read `services/tray_menu.zig` makes.
fn epochMs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    const s: u64 = @intCast(@max(ts.sec, 0));
    const n: u64 = @intCast(@max(ts.nsec, 0));
    return s * 1000 + n / 1_000_000;
}

pub const Host = struct {
    gpa: std.mem.Allocator,
    shm: shm_mod.ShmPair,
    surface: layer.Surface = .{},

    /// Owns every label. Rebuilt from scratch on each open so an old menu's
    /// strings cannot outlive the surface they were painted onto.
    arena: std.heap.ArenaAllocator,

    kind: Kind = .none,
    items: std.ArrayListUnmanaged(pmp.Row) = .empty,

    /// `.calendar` — the month on screen and the day the ring marks, plus the
    /// colours the card was opened with so `refresh` never has to reach back
    /// into a config that may have been swapped underneath it.
    cal_display: cal_card.Date = .{},
    cal_selected: cal_card.Date = .{},
    /// The real current date, kept apart from `cal_selected` so stepping
    /// through months does not stop marking today.
    cal_today: cal_card.Date = .{},
    card_colors: chrome.Chrome = .{},
    /// `.app`/`.tray` — the overlay-opacity scale for this menu's kind, read
    /// off the config the dock opens the menu with. It rides here (rather
    /// than being looked up per frame) for the same reason `card_colors`
    /// does: a menu keeps painting correctly even if the config underneath
    /// it is swapped while it is up.
    menu_alpha: f64 = 1.0,
    /// `.calendar`/`.weather`/`.launcher` — `overlay_opacity_widget_card`,
    /// the multiplier on those cards' nominal 0.92 fill (the launcher folds
    /// in its app-drawer scale as well), read off the config the dock opens
    /// the popup with. The same bargain as `menu_alpha`: the card keeps
    /// painting at the opacity it was opened with even if the config is
    /// swapped underneath it while it is up. It is what lets the compositor's
    /// namespace blur read through the glass.
    card_alpha: f64 = 1.0,
    /// Horizontal centre of the card inside the popup buffer. The buffer is
    /// as wide as the dock, so this is where the slot's own centre was.
    card_cx: i32 = 0,
    /// The height the card was *opened* with, for the two cards whose row
    /// count decides it: when the live reading moves it, the dock re-opens
    /// rather than painting past the end of a buffer sized for the old one.
    /// The fixed cards never consult it.
    card_h: i32 = 0,

    /// `.media_player` — the track the card is showing, pushed in by the dock
    /// on every media poll. The host paints it and answers clicks from it but
    /// never reaches for the bus itself, which keeps D-Bus off this side of
    /// the popup entirely.
    media: media_card.Input = .{},
    /// Which control the pointer is over. Carried alongside `media` so a
    /// motion that changes nothing does not cost a repaint.
    media_hover: media_card.Hover = .none,
    /// What a `.media_seek` click asked for, stored with the action so the
    /// dock does not have to redo the geometry a second time.
    media_seek_frac: f64 = 0.0,

    /// `.bluetooth` — the snapshot and device rows the card shows, pushed
    /// in by the dock from its live BlueZ query. Borrowed, like `media`:
    /// the dock owns both lifetimes and re-syncs while the card is up.
    bt_snap: bt_card.Snapshot = .{},
    bt_devs: []const bt_card.Device = &.{},
    /// What the last `.bluetooth` hit-test asked the host to do on the bus.
    bt_click: bt_card.ClickResult = .{},

    /// `.vpn` — the entry cache (owned by the dock, which has the
    /// allocator) and the authoritative connection list each frame reconciles
    /// against, plus the verb the last click reported.
    vpn_store: ?*vpn_card.Store = null,
    vpn_conns: []const vpn_card.Connection = &.{},
    vpn_click: vpn_card.ClickResult = .{},

    /// `.volume_mixer` — borrowed from the dock's landing the way the three
    /// above borrow their lists: the snapshot and the card/profile table live
    /// in `cc_live_mixer.Data`, which the dock keeps alive (and re-pushes)
    /// while the card is up, and the footer readouts are copies of it. Only
    /// the widget's own UI, pointer and last-click state live here.
    mx_snap: *const mixer_card.Snapshot = &mx_empty_snapshot,
    mx_cards: []const mixer_card.CardProfiles = &.{},
    mx_engine: mixer_card.EngineSettings = .{},
    mx_top: mixer_card.TopSample = .{},
    mx_icons: ?mixer_card.StreamIcons = null,
    mx_ui: mixer_card.UiState = .{},
    mx_view: mixer_card.View = .{},
    mx_click: mixer_card.ClickOut = .{},

    /// The config the two widget cards measure and colour from. Borrowed
    /// from the dock for as long as the card is up — the same lifetime the
    /// `cc_bt`/VPN lists above already assume.
    widget_cfg: ?*const schema.ShellConfig = null,
    /// Pointer position in *card* coordinates while it is over a
    /// `.bluetooth` / `.vpn` card, which paint hover-states straight from it
    /// (the media card keeps a parsed `Hover` instead — its zones are few
    /// enough to name).
    widget_ptr: ?[2]f64 = null,

    /// `.app` — the slot's launch id, and the handles the window rows point
    /// at. Handles are kept as *identity keys*: a click always resolves them
    /// back through `ForeignToplevels.find`, so a window that closed while the
    /// menu was open is a miss instead of a dangling proxy.
    app_key: []const u8 = "",
    chosen: ?*wl.zwlr_foreign_toplevel_handle_v1 = null,
    windows: []?*wl.zwlr_foreign_toplevel_handle_v1 = &.{},
    /// `.app` — the entry's `[Desktop Action ...]` rows, the ones the menu
    /// puts above Pin. Borrowed from the arena like `windows` is, so a click
    /// on row `desktop_action_first + i` only has to reach for
    /// `app_actions[i].exec`.
    app_actions: []const desktop_actions.Action = &.{},
    /// `.app` — the entry's own `Exec`, which is what gates "New Window".
    app_exec: []const u8 = "",

    /// `.tray` — what a `com.canonical.dbusmenu` click is addressed to.
    service: []const u8 = "",
    item_path: []const u8 = "",
    menu_path: []const u8 = "",

    /// `.launcher` — the model this surface is showing. Owned by the dock,
    /// which has the allocator and the `std.Io` a catalog scan needs; the host
    /// only borrows it for as long as the surface is up.
    launcher: ?*launcher_menu.Menu = null,
    /// `.world_clock` — the widget session whose panel this is, borrowed for
    /// as long as the surface is up (the dock owns it for the process's
    /// lifetime), plus the geometry measured at open time so the paint and
    /// the dock's hit tests work off the same numbers. The panel is authored
    /// at scale 1; `wc_us` is the widget's own `scaleOf(icon)`.
    wc: ?*wc_session.Session = null,
    wc_us: f64 = 1.0,
    wc_geom: wc_panel.Geom = .{},
    /// The scale the surface was opened at. The calendar and the weather card
    /// are drawn at 1 so their fixed cell geometry stays in step with their
    /// hit tests; the right-click menu follows the dock's UI scale. Keeping it
    /// here is what lets `configured` and `refresh` stop being told twice.
    scale: f64 = 1.0,
    /// Fit-to-output factor (output height / 1440, clamped) pushed in by the
    /// dock before it opens a card. The card is authored at a fixed natural
    /// size; this scales the whole card — drawing *and* surface height — down
    /// on a short output while keeping it centred on its slot (`card_cx` stays
    /// in dock coordinates). The right-click menu and launcher ignore it (the
    /// menu already follows the dock's own UI scale).
    fit: f64 = 1.0,

    open: bool = false,
    /// Menu geometry inside the popup buffer, in surface pixels.
    menu_x: i32 = 0,
    menu_w: i32 = 0,
    menu_h: i32 = 0,
    buf_w: i32 = 0,
    buf_h: i32 = 0,
    /// A frame is owed: `refresh` had to drop one because the compositor held
    /// both buffers. The release hook repaints it the moment a buffer comes
    /// back, so a freshly opened popup never sits blank waiting for an
    /// unrelated pointer event to draw its first picture.
    pending: bool = false,

    measure_surf: ?*cairo.cairo_surface_t = null,
    measure: ?*cairo.cairo_t = null,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .gpa = gpa,
            .shm = shm_mod.ShmPair.init(gpa),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Self) void {
        self.reset();
        self.arena.deinit();
        if (self.measure) |m| cairo.cairo_destroy(m);
        if (self.measure_surf) |s| cairo.cairo_surface_destroy(s);
        self.measure = null;
        self.measure_surf = null;
        self.shm.deinit();
    }

    /// Tear down whatever is open and hand back a clean slate for the next
    /// menu. Called on open (so a stale menu cannot be clicked into) and on
    /// close.
    pub fn reset(self: *Self) void {
        self.closeSurface();
        self.items.deinit(self.gpa);
        self.items = .empty;
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.gpa);
        self.kind = .none;
        self.app_key = "";
        self.chosen = null;
        self.windows = &.{};
        self.app_actions = &.{};
        self.app_exec = "";
        self.service = "";
        self.item_path = "";
        self.menu_path = "";
        self.cal_display = .{};
        self.cal_selected = .{};
        self.cal_today = .{};
        self.card_colors = .{};
        self.menu_alpha = 1.0;
        self.card_alpha = 1.0;
        self.card_cx = 0;
        self.card_h = 0;
        self.media = .{};
        self.media_hover = .none;
        self.media_seek_frac = 0.0;
        self.bt_snap = .{};
        self.bt_devs = &.{};
        self.bt_click = .{};
        self.vpn_store = null;
        self.vpn_conns = &.{};
        self.vpn_click = .{};
        self.widget_cfg = null;
        self.widget_ptr = null;
        self.launcher = null;
        self.wc = null;
        self.wc_us = 1.0;
        self.wc_geom = .{};
        self.scale = 1.0;
        self.menu_x = 0;
        self.menu_w = 0;
        self.menu_h = 0;
        self.buf_w = 0;
        self.buf_h = 0;
    }

    fn closeSurface(self: *Self) void {
        self.surface.destroy();
        // `destroy` leaves these alone, and a stale configure from the last
        // menu would otherwise size this one's buffer.
        self.surface.configured_width = 0;
        self.surface.configured_height = 0;
        self.buf_w = 0;
        self.buf_h = 0;
        self.open = false;
        self.pending = false;
    }

    pub fn push(self: *Self, label: []const u8, id: i32, enabled: bool) !void {
        const owned = try self.arena.allocator().dupe(u8, label);
        try self.items.append(self.gpa, .{ .label = owned, .id = id, .enabled = enabled });
    }

    pub fn pushAction(self: *Self, label: []const u8, a: Action, enabled: bool) !void {
        try self.push(label, @intFromEnum(a), enabled);
    }

    /// For labels that already live in the arena — `tray_menu.fetchTopLevel`
    /// hands them over pre-copied, so duping again would be pure waste.
    pub fn pushBorrowed(self: *Self, label: []const u8, id: i32, enabled: bool) !void {
        try self.items.append(self.gpa, .{ .label = label, .id = id, .enabled = enabled });
    }

    pub fn pushSeparator(self: *Self) !void {
        try self.items.append(self.gpa, .{ .id = -1, .enabled = false });
    }

    pub fn labelFor(self: *Self, id: i32) ?[]const u8 {
        for (self.items.items) |r| {
            if (r.id == id) return r.label;
        }
        return null;
    }

    fn measureCtx(self: *Self) ?*cairo.cairo_t {
        if (self.measure) |m| return m;
        const s = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1, 1);
        if (cairo.cairo_surface_status(s) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(s);
            return null;
        }
        self.measure_surf = s;
        self.measure = cairo.cairo_create(s);
        return self.measure;
    }

    /// Row under a pointer position given in *popup surface* coordinates, or
    /// null when the pointer is over the transparent strip beside the menu.
    pub fn rowAt(self: *Self, x: i32, y: i32, us: f64) ?usize {
        if (x < self.menu_x or x >= self.menu_x + self.menu_w) return null;
        return pmp.rowAt(y, self.items.items, us);
    }

    /// Move the hover pill. Returns true when the painted state changed, so
    /// the caller knows whether a repaint is worth it — motion can arrive far
    /// faster than the menu changes. The media card answers the same question
    /// about its own controls instead of about rows.
    pub fn hoverAt(self: *Self, x: i32, y: i32, us: f64) bool {
        if (self.kind == .media_player) return self.mediaHoverAt(x, y);
        if (self.kind == .volume_mixer) return self.mixerHoverAt(x, y);
        if (self.kind == .bluetooth or self.kind == .vpn or self.kind == .layout) return self.widgetHoverAt(x, y);
        const hit = self.rowAt(x, y, us);
        var changed = false;
        for (self.items.items, 0..) |*r, i| {
            const want = if (hit) |h|
                h == i and r.enabled and !pmp.isSeparator(r.*)
            else
                false;
            if (r.hover != want) {
                r.hover = want;
                changed = true;
            }
        }
        return changed;
    }

    pub fn clearHover(self: *Self) bool {
        if (self.kind == .media_player) return self.setMediaHover(.none);
        if (self.kind == .volume_mixer) {
            if (self.widget_ptr == null and !self.mx_view.on_popup) return false;
            self.widget_ptr = null;
            self.mx_view.on_popup = false;
            self.mx_view.px = -1;
            self.mx_view.py = -1;
            return true;
        }
        if ((self.kind == .bluetooth or self.kind == .vpn or self.kind == .layout) and self.widget_ptr != null) {
            self.widget_ptr = null;
            return true;
        }
        var changed = false;
        for (self.items.items) |*r| {
            if (r.hover) {
                r.hover = false;
                changed = true;
            }
        }
        return changed;
    }

    /// Pointer position in *card* coordinates: the buffer is as wide as the
    /// dock, so subtracting where the card starts is the whole conversion.
    fn cardLocal(self: *Self, x: i32, y: i32) [2]f64 {
        const left = @as(f64, @floatFromInt(self.card_cx)) - self.cardWidth() * self.fit * 0.5;
        return .{
            (@as(f64, @floatFromInt(x)) - left) / self.fit,
            @as(f64, @floatFromInt(y)) / self.fit,
        };
    }

    /// The two widget cards paint hover straight from the pointer, so all
    /// motion has to do is remember where it was. Rounded to whole pixels:
    /// sub-pixel jitter would otherwise repaint a card that draws nothing
    /// different.
    fn widgetHoverAt(self: *Self, x: i32, y: i32) bool {
        const p = self.cardLocal(x, y);
        const rx = @round(p[0]);
        const ry = @round(p[1]);
        if (self.widget_ptr) |cur| {
            if (@round(cur[0]) == rx and @round(cur[1]) == ry) return false;
        }
        self.widget_ptr = .{ rx, ry };
        return true;
    }

    /// The mixer card paints hover straight off the pointer too, but it also
    /// wants the *unrounded* position (`View.px/py` feeds the widget's own
    /// `hovering`) and whether that position is inside the card at all — a
    /// pointer parked in the buffer beside the card hovers nothing. Rounded
    /// coords still ride in `widget_ptr` so the two-card hover cache above
    /// and `clearHover` keep working unchanged.
    fn mixerHoverAt(self: *Self, x: i32, y: i32) bool {
        const p = self.cardLocal(x, y);
        const rx = @round(p[0]);
        const ry = @round(p[1]);
        const inside = p[0] >= 0.0 and p[0] < mixer_card.popup_w and
            p[1] >= 0.0 and p[1] < @as(f64, @floatFromInt(@max(self.card_h, 0)));
        var changed = false;
        if (self.widget_ptr) |cur| {
            if (@round(cur[0]) != rx or @round(cur[1]) != ry) changed = true;
        } else changed = true;
        self.widget_ptr = .{ rx, ry };
        const v = &self.mx_view;
        if (v.px != p[0] or v.py != p[1] or v.on_popup != inside) changed = true;
        v.px = p[0];
        v.py = p[1];
        v.on_popup = inside;
        return changed;
    }

    /// Rest the pointer over the media card's controls. Reports whether the
    /// hover actually moved, because motion arrives faster than the card
    /// changes and an unpainted change is still a change worth drawing.
    fn mediaHoverAt(self: *Self, x: i32, y: i32) bool {
        const p = self.cardLocal(x, y);
        const want = media_card.hitTest(p[0], p[1], self.media.realActive(), media_card.geometry);
        return self.setMediaHover(want);
    }

    fn setMediaHover(self: *Self, want: media_card.Hover) bool {
        if (self.media_hover == want) return false;
        self.media_hover = want;
        self.media.hover = want;
        return true;
    }

    /// Size the menu and place the layer surface under the pointer. Returns
    /// false when there is nothing to show or the compositor refused.
    pub fn present(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        ptr_x: i32,
        ptr_y: i32,
        us: f64,
    ) bool {
        if (self.items.items.len == 0) return false;
        if (dock_w <= 0 or dock_h <= 0) return false;
        // The menu scales through `us`, never through the card fit — clearing
        // it here stops a card's fit from leaking in (`reset` doesn't touch it
        // and the menu and a card can share one host across opens).
        self.fit = 1.0;

        const cr = self.measureCtx();
        // Clamp the menu to `600*us`; the extra dock-width bound is
        // the same guard as before — a tray icon near the right end would
        // otherwise hang off — and only ever binds on a small output.
        const max_w = @min(@as(f64, @floatFromInt(600)) * us, @as(f64, @floatFromInt(dock_w)) - 16.0);
        // A running window's title is a row, and titles run pages long
        // (`buildAppMenu` passes them through as `popup_open_for_app` does):
        // trim each label to the cap's text budget before the width is
        // decided, so the cut lands in the model with a trailing `…` and the
        // menu is sized to what is left to draw rather than to the clamp's
        // ceiling. `min_w` can never bind an over-budget menu — a label wide
        // enough to need the cap is already wider than `min_w` — so the
        // budget below is the one width a clamped menu can actually hold.
        pmp.ellipsizeRows(
            self.arena.allocator(),
            cr,
            self.items.items,
            max_w - @as(f64, @floatFromInt(pmp.pad_h)) * 2.0 * us,
            us,
        );
        const widest = pmp.widestLabel(cr, self.items.items, us);
        const want = @as(f64, @floatFromInt(pmp.pad_h)) * 2.0 * us + widest;
        const min_w = @as(f64, @floatFromInt(160)) * us;
        self.menu_w = @intFromFloat(std.math.round(std.math.clamp(want, min_w, @max(min_w, max_w))));
        self.menu_h = pmp.menuHeight(self.items.items, us);

        // Centre the menu on the pointer, then pull it back inside the dock's
        // own width — a tray icon near the right end would otherwise hang off.
        const lo = 8;
        const hi = @max(lo, dock_w - self.menu_w - 8);
        self.menu_x = std.math.clamp(ptr_x - @divTrunc(self.menu_w, 2), lo, hi);

        // The pointer's *y* never enters the placement: the menu hangs off the
        // output's bottom edge, not off the pointer.
        _ = ptr_y;
        // Separate namespaces per menu kind:
        // a tray icon's menu and an app slot's menu are separate namespaces so
        // a Hyprland rule can blur one without the other.
        const menu_ns: []const u8 = switch (self.kind) {
            .tray => ns.tray_menu,
            else => ns.dock_context_menu,
        };
        return self.placeSurface(compositor, shell, dock_w, dock_h, dock_w, self.menu_h, null, us, false, menu_ns);
    }

    /// The calendar card: a fixed-size panel drawn centred on the clock slot
    /// rather than on the pointer, which is what makes it read as "the clock's
    /// popup" instead of "a menu that happens to be a grid". Everything else
    /// about the surface is the menu's, so the two cannot end up on different
    /// layers or with different lifetimes.
    pub fn openCalendar(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        slot_cx: i32,
        today_d: cal_card.Date,
        colors: chrome.Chrome,
        card_alpha: f64,
        fit: f64,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0) return false;
        // `calSelectedDate = now`, `calDisplayDate` normalised to the 1st —
        // the month the card opens on is the month the ring starts in. `kind`
        // is only committed once the surface exists, so a compositor refusal
        // leaves the host exactly as closed as it was.
        self.fit = fit;
        self.cal_selected = today_d;
        self.cal_display = .{ .year = today_d.year, .month = today_d.month, .day = 1 };
        self.cal_today = today_d;
        self.card_colors = colors;
        self.card_alpha = card_alpha;
        // The card renders at scale 1 — its cell geometry is fixed in card
        // pixels so `cellAt` and `paintCard` are the same arithmetic.
        self.card_cx = centreFor(slot_cx, dock_w, cal_card.width, self.fit);
        if (!self.placeSurface(compositor, shell, dock_w, dock_h, dock_w, cardHeight(), null, 1.0, false, ns.calendar)) {
            return false;
        }
        self.kind = .calendar;
        return true;
    }

    /// The weather card. Its height depends on the reading — a card with a
    /// forecast is taller than one with dashes — so it is measured here,
    /// right before the layer surface asks for it. Colours *and* opacity ride
    /// in the way the calendar's do: reading both off `sc`, and a
    /// host that never passes them would paint the config's themeless
    /// defaults at full opacity.
    pub fn openWeather(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        slot_cx: i32,
        colors: chrome.Chrome,
        card_alpha: f64,
        fit: f64,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0) return false;
        const h: i32 = @intFromFloat(@round(wx_card.cardHeight(&wx_card.state)));
        if (h <= 0) return false;
        self.fit = fit;
        self.card_colors = colors;
        self.card_alpha = card_alpha;
        self.card_cx = centreFor(slot_cx, dock_w, wx_card.width, self.fit);
        // `PopupKind::Weather` maps to the generic
        // `kPopupNamespace`, not a weather-specific one.
        if (!self.placeSurface(compositor, shell, dock_w, dock_h, dock_w, h, null, 1.0, false, ns.popup)) {
            return false;
        }
        self.kind = .weather;
        // Natural (pre-fit) height: the card draws inside a `cairo_scale(fit)`
        // frame, so its shadow needs the unscaled height, not `buf_h`.
        self.card_h = h;
        return true;
    }

    /// The world clock card's layer margin: the card's bottom edge sits
    /// `16px` (at the widget's scale) above the widget slot's top edge, and
    /// the invisible ring the surface carries under the card comes off that
    /// margin so the *card* — not the ring — keeps the standoff.
    fn wcBottomMargin(dock_h: i32, slot_top: i32, us: f64, fit: f64) i32 {
        const ring = wc_panel.k_shadow_pad * us * fit;
        const below_widget: f64 = @floatFromInt(dock_h - slot_top);
        return @intFromFloat(@round(@max(0.0, below_widget + 16.0 * us - ring)));
    }

    /// The world-clock panel (the spec's popup): a variable-height card whose
    /// header, clock rows and switches come out of the widget's own session,
    /// centred on its slot the way the other widget cards are. The height
    /// depends on the row count, the add pane and the search results, so it is
    /// measured here, right before the layer surface asks for it. It is the
    /// second card that takes the keyboard: the search field wants typing and
    /// the panel wants the arrow keys.
    pub fn openWorldClock(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        slot_cx: i32,
        slot_top: i32,
        out_w: i32,
        origin_x: i32,
        session: *wc_session.Session,
        us: f64,
        max_h: f64,
        colors: chrome.Chrome,
        fit: f64,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0 or us <= 0.0) return false;
        self.fit = fit;
        self.card_colors = colors;
        self.wc = session;
        self.wc_us = us;
        var g = wc_panel.compute(session, max_h);
        // The card is laid out in *output* coordinates. The popup surface
        // spans the whole output — a dock narrower than the screen would
        // otherwise shove a widget-end card sideways (the clamp to the
        // dock's width) instead of letting it hang over the wallpaper
        // beside the dock, the way the control center's placement does.
        // `slot_cx` is dock-local; `origin_x` is the dock surface's origin
        // on the output.
        const span: i32 = if (out_w > 0) @max(out_w, dock_w) else dock_w;
        // Never wider than the screen it opens on (32 px of air each side).
        g.w = @max(200.0, @min(g.w, @as(f64, @floatFromInt(span)) / us - 32.0));
        self.wc_geom = g;
        // The card's natural size is the panel plus its (invisible) shadow
        // margin — the same 24 px ring the taskbar keeps, now only as the
        // "outside this press closes" border.
        const cw = (g.w + wc_panel.k_shadow_pad * 2.0) * us;
        const ch = (g.total_h + wc_panel.k_shadow_pad * 2.0) * us;
        self.card_cx = centreFor(origin_x + slot_cx, span, cw, self.fit);
        // The spec places this one off its *widget* rather than off the dock:
        // the card's bottom edge sits 16px (at the widget's scale) above the
        // slot's top edge — the same standoff the taskbar keeps. The ring
        // under the card is surface, not card, so the layer margin has to come
        // up short of that standoff by exactly the ring.
        const margin = wcBottomMargin(dock_h, slot_top, us, self.fit);
        if (!self.placeSurface(
            compositor,
            shell,
            dock_w,
            dock_h,
            span,
            @intFromFloat(@round(ch)),
            margin,
            1.0,
            true,
            ns.popup,
        )) {
            self.wc = null;
            return false;
        }
        self.kind = .world_clock;
        self.card_h = @intFromFloat(@round(ch));
        return true;
    }

    /// The bluetooth card. Its height depends on how many device rows the
    /// live reading has, so it is measured here, right before the layer
    /// surface asks for it — the same reason the weather card measures late.
    /// The dock owns the snapshot and device list and keeps them refreshed
    /// while the card is up; the card only borrows.
    pub fn openBluetooth(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        slot_cx: i32,
        cfg: *const schema.ShellConfig,
        snap: *const bt_card.Snapshot,
        devices: []const bt_card.Device,
        fit: f64,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0) return false;
        const h: f64 = bt_card.popupHeight(self.gpa, cfg, snap, devices) catch return false;
        if (h <= 0.0) return false;
        self.fit = fit;
        self.card_cx = centreFor(slot_cx, dock_w, bt_card.popup_w, self.fit);
        const hi: i32 = @intFromFloat(@round(h));
        if (!self.placeSurface(compositor, shell, dock_w, dock_h, dock_w, hi, null, 1.0, false, ns.popup)) {
            return false;
        }
        self.kind = .bluetooth;
        self.card_h = hi;
        return true;
    }

    /// The window-layout card. Its height is not decided here at all: the
    /// widget computes it from how many layouts the running compositor
    /// actually has — a short column of tall rows for Hyprland's four, a
    /// two-column grid for Mango's fourteen — so the card is as tall as that
    /// answer and no taller. Nothing has to be borrowed to draw it either:
    /// the entries come out of `layout_paint`'s own table, and the live
    /// reading behind the current one is cached there.
    pub fn openLayout(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        slot_cx: i32,
        fit: f64,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0) return false;
        const h: f64 = @floatFromInt(lay_card.heightPx());
        if (h <= 0.0) return false;
        self.fit = fit;
        self.card_cx = centreFor(slot_cx, dock_w, lay_card.popup_w, self.fit);
        const hi: i32 = @intFromFloat(@round(h));
        if (!self.placeSurface(compositor, shell, dock_w, dock_h, dock_w, hi, null, 1.0, false, ns.popup)) {
            return false;
        }
        self.kind = .layout;
        self.card_h = hi;
        return true;
    }

    /// The VPN card. Fixed rows (one per saved connection, or the empty
    /// message), so its height comes straight off the count the dock last
    /// synced. Same borrowing rules as the bluetooth card.
    pub fn openVpn(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        slot_cx: i32,
        count: usize,
        fit: f64,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0) return false;
        const h: f64 = vpn_card.heightFor(count);
        self.fit = fit;
        self.card_cx = centreFor(slot_cx, dock_w, vpn_card.popup_w, self.fit);
        const hi: i32 = @intFromFloat(@round(h));
        if (!self.placeSurface(compositor, shell, dock_w, dock_h, dock_w, hi, null, 1.0, false, ns.popup)) {
            return false;
        }
        self.kind = .vpn;
        self.card_h = hi;
        return true;
    }

    /// The mixer card. Fixed 600×620 — the app list scrolls inside its own
    /// viewport rather than growing the popup, which is why this is the one
    /// card with no content-driven height — centred on its slot like the
    /// others, with the state behind it (snapshot, cards, footer readouts)
    /// pushed in by the dock before and while it is up.
    pub fn openVolumeMixer(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        slot_cx: i32,
        fit: f64,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0) return false;
        self.fit = fit;
        self.card_cx = centreFor(slot_cx, dock_w, mixer_card.popup_w, self.fit);
        const hi: i32 = @intFromFloat(@round(mixer_card.popup_h));
        if (!self.placeSurface(compositor, shell, dock_w, dock_h, dock_w, hi, null, 1.0, false, ns.popup)) {
            return false;
        }
        // A reopen keeps the Output/Input tab
        // — while the drag, the scroll and the dropdowns all start over.
        mixer_card.notifyOpen(&self.mx_ui);
        self.mx_view = .{ .popup_h = @as(f64, @floatFromInt(hi)) };
        self.kind = .volume_mixer;
        self.card_h = hi;
        return true;
    }

    /// The media card. Fixed size like the calendar, centred on the media
    /// slot, and — unlike either of them — carrying live state the dock keeps
    /// refreshed while it is up.
    pub fn openMediaPlayer(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        slot_cx: i32,
        colors: chrome.Chrome,
        fit: f64,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0) return false;
        self.fit = fit;
        self.card_colors = colors;
        self.media = .{};
        self.media_hover = .none;
        self.media_seek_frac = 0.0;
        self.card_cx = centreFor(slot_cx, dock_w, media_card.width, self.fit);
        const h: i32 = @intFromFloat(@round(media_card.height));
        if (!self.placeSurface(compositor, shell, dock_w, dock_h, dock_w, h, null, 1.0, false, ns.popup)) {
            return false;
        }
        self.kind = .media_player;
        return true;
    }

    /// The start menu. Unlike the cards it is not centred on a slot: it is a
    /// fixed-size panel in the middle of the output, which is what stops its
    /// position from depending on how many slots happen to be pinned. It is
    /// also the only popup that asks for the keyboard.
    /// The start menu's placement problem, stated the way layer-shell needs
    /// to hear it. Unlike the cards it has to sit over one particular slot
    /// rather than in the middle of the surface, so it cannot lean on being
    /// as wide as the dock: it needs to know where the dock *is*.
    pub const Placement = struct {
        /// The slot's centre, in the dock's own surface coordinates.
        anchor_x: f64,
        /// The dock's configured width, where its left edge sits on the
        /// output, and that output's width. `output_w` is 0 whenever the
        /// compositor chose the output and will not say which one — a state
        /// that has to work, not an error, so the clamp simply falls back to
        /// keeping the panel inside the dock.
        layer_w: f64,
        layer_origin_x: f64,
        output_w: f64 = 0,
        /// The dock's height, which is also how far the panel must be lifted
        /// to clear it.
        dock_h: i32,
    };

    /// The margins a popup was actually asked for. Layer-shell gives no
    /// feedback about where a surface ended up, so what was *requested* is
    /// the only thing anyone can inspect after the fact.
    pub const Settled = struct { margin_left: i32, margin_bottom: i32 };

    pub fn openLauncher(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        output: ?*wl.wl_output,
        p: Placement,
        m: *launcher_menu.Menu,
        card_alpha: f64,
        fit: f64,
    ) ?Settled {
        if (p.layer_w <= 0 or p.dock_h <= 0) return null;
        // The model owns the natural size: the App menu's rail panel is a
        // different card from the reference drawer (540x420 against 760x620),
        // and the layout that answers for it is the one about to be drawn.
        const size = m.preferredSize();
        const w: f64 = size.w;
        const h: f64 = size.h;
        // The panel is drawn at the output's fit factor: the surface is this
        // much smaller than the natural `preferred_w`/`preferred_h`, the paint
        // is wrapped in a matching `cairo_scale(fit)`, and the model stays in
        // natural space (`m.sizeTo(w, h)`) so its layout constants are undist-
        // urbed. `fit` is clamped by the caller like every other surface.
        const f: f64 = if (fit > 0.0) fit else 1.0;
        const sw: f64 = @round(w * f);
        const sh: f64 = @round(h * f);
        const gap: i32 = @intFromFloat(std.math.round(gap_above_dock));
        const pos = popup_position.place(.{
            .anchor_x = p.anchor_x,
            .popup_w = sw,
            .layer_w = p.layer_w,
            .layer_origin_x = p.layer_origin_x,
            .output_w = p.output_w,
            .bottom_clearance = @floatFromInt(@max(0, p.dock_h) + gap),
        });
        const settled = Settled{
            .margin_left = @intFromFloat(@round(pos.margin_left)),
            .margin_bottom = @intFromFloat(@round(pos.margin_bottom)),
        };
        if (!self.placeAtCorner(
            compositor,
            shell,
            output,
            @intFromFloat(sw),
            @intFromFloat(sh),
            settled.margin_left,
            settled.margin_bottom,
        )) {
            return null;
        }
        // Only once the surface exists: a compositor refusal must leave the
        // host exactly as closed as it was, model included.
        self.kind = .launcher;
        self.launcher = m;
        self.card_alpha = card_alpha;
        self.fit = f;
        m.fit = f;
        m.sizeTo(w, h);
        return settled;
    }

    /// The start menu's surface: exactly as big as the panel, anchored into
    /// the bottom-left corner and pushed out by the two margins `place`
    /// worked out. Being the panel rather than a window onto it is the whole
    /// point — there is no transparent strip beside it to swallow a click
    /// meant for whatever sits behind, which is the one promise the
    /// as-wide-as-the-dock trick the cards use cannot make.
    ///
    /// It is created on the dock's own output: margins are measured from the
    /// output's edge, so a popup on a *different* output would be positioned
    /// against the wrong screen entirely.
    fn placeAtCorner(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        output: ?*wl.wl_output,
        content_w: i32,
        content_h: i32,
        margin_left: i32,
        margin_bottom: i32,
    ) bool {
        if (!self.surface.create(compositor, shell, output, .overlay, ns.app_drawer)) return false;
        self.surface.setAnchor(layer.Anchor.bottom | layer.Anchor.left);
        self.surface.setExclusiveZone(-1);
        self.surface.setKeyboardInteractivity(kb_exclusive);
        self.surface.setMargins(0, 0, margin_bottom, margin_left);
        self.surface.setSize(@intCast(content_w), @intCast(content_h));
        self.scale = 1.0;
        // Default the card fit to neutral; `openLauncher` overrides this with
        // the output's fit factor immediately after the surface exists, since
        // the launcher is the one surface whose own size tracks that fit.
        self.fit = 1.0;
        self.surface.commit();
        self.open = true;
        return true;
    }

    /// Where to put a `w`-wide card so it stays inside a `dock_w`-wide
    /// surface: as close to the slot's own centre as the edges allow.
    /// Clamp a card's centre so the card stays inside the dock-wide surface.
    /// `w` is the card's *natural* width and `fit` the output factor it is
    /// painted at: every card draws inside a `cairo_scale(fit)` frame, so the
    /// card lands in the surface at `w × fit` pixels wide and the edge margins
    /// must come from that painted width. Clamping on the natural width would
    /// shove a fit-shrunk card back toward the middle far harder than the
    /// screen requires, leaving it off its slot on any output under 1440 tall.
    fn centreFor(slot_cx: i32, dock_w: i32, w: f64, fit: f64) i32 {
        const half = @divTrunc(@as(i32, @intFromFloat(@round(w * fit))), 2);
        const lo = half + 8;
        const hi = @max(lo, dock_w - half - 8);
        return std.math.clamp(slot_cx, lo, hi);
    }

    /// The card's height in whole surface pixels.
    pub fn cardHeight() i32 {
        return @intFromFloat(@round(cal_card.height));
    }

    /// The shared layer-surface placement. `content_w`/`content_h` are how big
    /// the drawn content is; the buffer is exactly that, so unlike the
    /// right-click menu there is no transparent strip to paint around it.
    /// `bottom_margin` names the distance from the output's bottom edge
    /// directly for the one card that is placed off its widget rather than off
    /// the dock (the world clock); `null` keeps the dock-relative `dock_h + gap`
    /// every other card uses.
    fn placeSurface(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        dock_w: i32,
        dock_h: i32,
        content_w: i32,
        content_h: i32,
        bottom_margin: ?i32,
        us: f64,
        keyboard: bool,
        namespace: []const u8,
    ) bool {
        _ = dock_w;
        if (!self.surface.create(compositor, shell, null, .overlay, namespace)) return false;
        self.surface.setAnchor(layer.Anchor.bottom);
        self.surface.setExclusiveZone(-1);
        if (keyboard) self.surface.setKeyboardInteractivity(kb_exclusive);
        // Anchoring to the *output's* bottom edge is what lifts the popup
        // clear of the dock: the dock's own bottom edge is that same edge, so
        // `dock_h + gap` clears it wherever the pointer sat inside it. Deriving
        // this from the pointer instead is what made the menu cover the icons.
        const gap: i32 = @intFromFloat(std.math.round(gap_above_dock * us));
        self.surface.setMargins(0, 0, bottom_margin orelse @max(0, dock_h + gap), 0);
        // Width comes from the caller — dock-wide for most cards, output-wide
        // for the world clock so a widget at the dock's end can still be
        // centred on (which may place the card over the wallpaper beside a
        // narrow dock). Only the height is fit-scaled — the card is drawn
        // inside a `cairo_scale(fit)` frame that shrinks it to match. The
        // menu and launcher leave `fit` at 1.0 and are unaffected.
        const h_fit: i32 = @intFromFloat(std.math.round(@as(f64, @floatFromInt(content_h)) * self.fit));
        self.surface.setSize(@intCast(content_w), @max(1, h_fit));
        self.scale = us;
        // Bound here rather than in `init` because `init` returns the struct
        // by value — the hook would keep an address nothing lives at. Every
        // open re-asserts it; the hook itself rides the buffers across
        // `ensure`'s reallocs.
        self.shm.setReleaseHook(onShmRelease, self);
        self.surface.commit();
        self.open = true;
        return true;
    }

    /// A click inside the card. Menus answer with a row id; the calendar has
    /// no rows, so it answers with the two nav buttons and "dismiss".
    pub fn cardClick(self: *Self, x: i32, y: i32) CardClick {
        // The card is drawn inside a `cairo_scale(fit)` frame centred on
        // `card_cx`; convert the surface pointer back to natural card
        // coordinates so every hit-test below stays in card space.
        const cw = self.cardWidth();
        const left = @as(f64, @floatFromInt(self.card_cx)) - cw * self.fit * 0.5;
        const lx = (@as(f64, @floatFromInt(x)) - left) / self.fit;
        const ly: f64 = @as(f64, @floatFromInt(y)) / self.fit;
        switch (self.kind) {
            .calendar => switch (cal_card.navHit(cal_card.width, lx, ly, 1.0)) {
                -1 => return .prev_month,
                1 => return .next_month,
                else => {},
            },
            .media_player => {
                const want = media_card.hitTest(lx, ly, self.media.realActive(), media_card.geometry);
                _ = self.setMediaHover(want);
                return switch (want) {
                    .shuffle => .media_shuffle,
                    .prev => .media_prev,
                    .play => .media_play,
                    .next => .media_next,
                    .repeat => .media_repeat,
                    .seekbar => blk: {
                        self.media_seek_frac =
                            media_card.seekFraction(lx, media_card.geometry) orelse 0.0;
                        break :blk .media_seek;
                    },
                    // `.none` and the unused `.close`: a click that landed on
                    // empty card is a click that dismisses.
                    else => .dismiss,
                };
            },
            .bluetooth => {
                const cfg = self.widget_cfg orelse return .dismiss;
                self.bt_click = bt_card.clickAction(self.gpa, cfg, &self.bt_snap, self.bt_devs, lx, ly) catch .{};
                return switch (self.bt_click.click) {
                    // A click on the card's own background answers nothing;
                    // the card stays up.
                    .none => .none,
                    .close => .dismiss,
                    .redraw, .reopen => .bluetooth,
                };
            },
            .vpn => {
                const store = self.vpn_store orelse return .dismiss;
                self.vpn_click = vpn_card.click(store, lx, ly, vpn_card.monotonicNs());
                return switch (self.vpn_click.click) {
                    .none => .none,
                    .close => .dismiss,
                    .redraw, .reopen => .vpn,
                };
            },
            .volume_mixer => {
                // A click in the buffer beside the card closes it, exactly as
                // `dock_volume_mixer_popup_handle_click` does — and it has to
                // be checked first, since the hit test only knows card
                // coordinates, not how big the card is.
                const hmax = @as(f64, @floatFromInt(@max(self.card_h, 0)));
                if (lx < 0.0 or lx >= mixer_card.popup_w or ly < 0.0 or ly >= hmax) return .dismiss;
                const ui = &self.mx_ui;
                // The layout the paint derives from this same state, rebuilt
                // here so the hit zones line up with what is on screen.
                var lay = mixer_card.computeLayout(
                    self.gpa,
                    self.mx_snap,
                    self.mx_cards,
                    ui.view_output,
                    ui.router_stream,
                    ui.master_picker,
                    ui.scroll_px,
                ) catch return .dismiss;
                defer mixer_card.freeLayout(self.gpa, &lay);
                const h = mixer_card.hitTest(&lay, self.mx_snap, lx, ly);
                self.mx_click = mixer_card.clickAt(
                    ui,
                    self.mx_snap,
                    self.mx_cards,
                    &lay,
                    h,
                    ly,
                    @divFloor(vpn_card.monotonicNs(), std.time.ns_per_ms),
                );
                // Background and absorbed rows answer nothing and leave the
                // card up. A tab switch grows the surface, and any write the
                // widget formulated is the host's to run.
                if (self.mx_click.resized or self.mx_click.effect.verb != .none) return .volume_mixer;
                return .none;
            },
            .layout => return switch (lay_card.clickAction(lx, ly)) {
                // The widget applied the swap itself inside the hit test;
                // the host only learns whether to redraw
                // or close.
                .none => .none,
                .close => .dismiss,
                .redraw => .layout,
            },
            // The weather card has no controls: any click
            // inside it closes it.
            else => {},
        }
        return .dismiss;
    }

    /// The card's natural (pre-fit) width. Anything fixed reads its module's
    /// constant; the weather card is the fallback.
    fn cardWidth(self: *const Self) f64 {
        return switch (self.kind) {
            .calendar => cal_card.width,
            .media_player => media_card.width,
            .bluetooth => bt_card.popup_w,
            .vpn => vpn_card.popup_w,
            .volume_mixer => mixer_card.popup_w,
            .layout => lay_card.popup_w,
            .world_clock => (self.wc_geom.w + wc_panel.k_shadow_pad * 2.0) * self.wc_us,
            else => wx_card.width,
        };
    }

    /// -1 for the left button, +1 for the right. Wraps across the year in
    /// both directions.
    pub fn stepMonth(self: *Self, dir: i32) void {
        if (dir < 0) {
            if (self.cal_display.month == 1) {
                self.cal_display.month = 12;
                self.cal_display.year -= 1;
            } else {
                self.cal_display.month -= 1;
            }
        } else if (dir > 0) {
            if (self.cal_display.month == 12) {
                self.cal_display.month = 1;
                self.cal_display.year += 1;
            } else {
                self.cal_display.month += 1;
            }
        }
    }

    /// First configure: allocate the buffer the compositor asked for and put
    /// the menu into it. A layer surface must commit before it is configured,
    /// so this is the first moment a buffer can exist.
    pub fn configured(self: *Self, wlshm: ?*wl.wl_shm) void {
        const w: i32 = @intCast(self.surface.configured_width);
        const h: i32 = @intCast(self.surface.configured_height);
        if (w <= 0 or h <= 0) return;
        // `buf_w`/`buf_h` stay logical (paint draws in them); only the buffer
        // is allocated at device pixels.
        if (!self.shm.ensure(wlshm, "dock-menu", w * self.surface.scale, h * self.surface.scale)) return;
        self.buf_w = w;
        self.buf_h = h;
        self.refresh();
    }

    /// Repaint and present whatever the buffer currently holds.
    pub fn refresh(self: *Self) void {
        if (!self.open or self.buf_w <= 0 or self.buf_h <= 0) return;
        // Drawn into a buffer the compositor has let go of: the menu
        // repaints on every hover, and painting into the one on screen is
        // what makes it flicker under a moving pointer. Both held means this
        // frame waits — owed, so `onShmRelease` puts it out the moment the
        // compositor hands a buffer back, rather than whenever the next
        // unrelated pointer event happens to arrive.
        const buf = self.shm.acquire() orelse {
            self.pending = true;
            return;
        };
        self.pending = false;
        const cr = buf.cr orelse return;
        self.paint(cr);
        self.surface.attach(buf.wlBuffer(), 0, 0);
        self.surface.setBufferScale(self.surface.scale);
        self.surface.damage(0, 0, self.buf_w, self.buf_h);
        buf.markBusy();
        self.surface.commit();
    }

    /// A buffer came back from the compositor. If a frame was owed when the
    /// pair was fully held, this is what finally draws it — without this, a
    /// popup opened while the last one's frames were still in flight would
    /// stay empty until the pointer moved somewhere it happened to repaint.
    fn onShmRelease(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.pending) return;
        self.pending = false;
        if (self.open) self.refresh();
    }

    fn paint(self: *Self, cr: ?*cairo.cairo_t) void {
        const us = self.scale;
        cairo.cairo_save(cr);
        // The strip beside the content has to be genuinely transparent, not
        // black: this surface is wider than the content on purpose, and alpha
        // 0 is also what lets the clicks it eats fall through visually.
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
        cairo.cairo_paint(cr);
        // Scale the whole frame to the output's device pixels. Everything
        // below draws in logical coordinates (buf_w/buf_h); cairo rasterises
        // at the buffer's native resolution so HiDPI stays crisp. (`us` above
        // is the popup's own layout scale, unrelated to output DPI.)
        cairo.cairo_identity_matrix(cr);
        const psc: f64 = @floatFromInt(self.surface.scale);
        cairo.cairo_scale(cr, psc, psc);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        switch (self.kind) {
            .launcher => {
                // The panel is the whole buffer, so there is nothing to centre
                // and no shadow to put behind it — the surface stops at the
                // card's own rounded edge. The surface is `fit` smaller than
                // the natural `geo` the layout is authored in, so the whole
                // panel draws inside a matching `cairo_scale(fit)` frame from
                // the origin (it is anchored to the bottom-left corner).
                cairo.cairo_save(cr);
                cairo.cairo_scale(cr, self.fit, self.fit);
                if (self.launcher) |m| {
                    // One `View`, two panels: the App menu asked for the rail,
                    // the drawer and the start menu keep the reference card.
                    const view = m.view();
                    if (view.style == .rail) {
                        launcher_rail_paint.paint(cr, view, self.card_alpha);
                    } else {
                        launcher_paint.paint(cr, view, self.card_alpha);
                    }
                }
                cairo.cairo_restore(cr);
            },
            .calendar, .weather => {
                const cw = self.cardWidth();
                const ch: f64 = switch (self.kind) {
                    .calendar => cal_card.height,
                    // Natural height: `buf_h` is fit-scaled, the card draws in
                    // a `cairo_scale(fit)` frame so its shadow needs card space.
                    else => @floatFromInt(@max(self.card_h, 0)),
                };
                // Frame the card: translate to its slot centre, scale by the
                // output fit, then shift back by half the *natural* width so
                // the card draws centred and fit-sized. Everything below
                // stays in natural card coordinates.
                cairo.cairo_translate(cr, @floatFromInt(self.card_cx), 0.0);
                cairo.cairo_scale(cr, self.fit, self.fit);
                cairo.cairo_translate(cr, -cw * 0.5, 0.0);
                // A soft drop shadow under the panel, the same one every card
                // in the shell puts behind itself, with per-card numbers.
                // own numbers per card — the calendar's is tighter and
                // lighter than the weather's — and the difference shows now
                // that the fill on top of it is translucent enough to read
                // the shadow through.
                const sh_y: f64 = if (self.kind == .calendar) 3.0 else 4.0;
                const sh_r: f64 = if (self.kind == .calendar) 24.0 else 26.0;
                const sh_a: f64 = if (self.kind == .calendar) 0.22 else 0.28;
                helpers.roundedRect(cr, 2.0, sh_y, cw, ch, sh_r);
                cairo.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, sh_a);
                cairo.cairo_fill(cr);
                switch (self.kind) {
                    .calendar => cal_card.paintCard(
                        cr,
                        cal_card.width,
                        cal_card.height,
                        1.0,
                        self.card_colors,
                        self.card_alpha,
                        self.cal_display,
                        self.cal_selected,
                        self.cal_today,
                    ),
                    else => _ = wx_card.paintCard(
                        cr,
                        wx_card.width,
                        self.card_colors,
                        self.card_alpha,
                        &wx_card.state,
                    ),
                }
            },
            .media_player => {
                // Same frame as the rest: centre on the slot, scale by fit,
                // then hand the paint a natural-space left edge (half the
                // card's width back from centre).
                const cw = media_card.width;
                cairo.cairo_save(cr);
                cairo.cairo_translate(cr, @floatFromInt(self.card_cx), 0.0);
                cairo.cairo_scale(cr, self.fit, self.fit);
                // Widget-card scale, read live off the pushed config (the C++
                // card paints `0.92 * overlayOpacityWidgetCard` at draw time).
                // 1.0 when no config was pushed in, as before.
                const card_alpha = if (self.widget_cfg) |cfg|
                    overlay.widgetCardAlpha(&cfg.appearance)
                else
                    1.0;
                media_card.paint(cr, -cw * 0.5, 0.0, self.card_colors, card_alpha, self.media);
                cairo.cairo_restore(cr);
            },
            .bluetooth => {
                // The card brings its own shadow and colours (it reads the
                // config the dock pushed in), so only the centring is left —
                // and the pointer, which it hover-tests row by row.
                if (self.widget_cfg) |cfg| {
                    cairo.cairo_translate(cr, @floatFromInt(self.card_cx), 0.0);
                    cairo.cairo_scale(cr, self.fit, self.fit);
                    cairo.cairo_translate(cr, -bt_card.popup_w * 0.5, 0.0);
                    bt_card.paintPopup(self.gpa, cr, cfg, &self.bt_snap, self.bt_devs, self.widget_ptr) catch {};
                }
            },
            .vpn => {
                if (self.widget_cfg) |cfg| {
                    if (self.vpn_store) |store| {
                        cairo.cairo_translate(cr, @floatFromInt(self.card_cx), 0.0);
                        cairo.cairo_scale(cr, self.fit, self.fit);
                        cairo.cairo_translate(cr, -vpn_card.popup_w * 0.5, 0.0);
                        vpn_card.paint(cr, cfg, store, self.vpn_conns, self.widget_ptr);
                    }
                }
            },
            .volume_mixer => {
                // Centred like the rest, and it brings its own shadow, chrome
                // and colours from the config the dock pushed in. What it
                // paints *with* — snapshot, card/profile table, footer
                // readouts — is all borrowed state the dock pushed the moment
                // a landing arrived; the widget never asks for anything.
                if (self.widget_cfg) |cfg| {
                    cairo.cairo_translate(cr, @floatFromInt(self.card_cx), 0.0);
                    cairo.cairo_scale(cr, self.fit, self.fit);
                    cairo.cairo_translate(cr, -mixer_card.popup_w * 0.5, 0.0);
                    const aux = mixer_card.Aux{
                        .engine = self.mx_engine,
                        .top = self.mx_top,
                        .cards = self.mx_cards,
                        .icons = self.mx_icons,
                    };
                    mixer_card.mixerPaint(
                        self.gpa,
                        cr,
                        cfg,
                        self.mx_snap,
                        &self.mx_ui,
                        &self.mx_view,
                        &aux,
                        null,
                        null,
                    ) catch {};
                }
            },
            .layout => {
                // Centred like the rest, and it brings its own shadow and
                // chrome from the config the dock pushed in. The pointer it
                // hover-tests is the whole interaction surface: the card is
                // one wall of cells, with no rows or buttons of its own.
                if (self.widget_cfg) |cfg| {
                    cairo.cairo_translate(cr, @floatFromInt(self.card_cx), 0.0);
                    cairo.cairo_scale(cr, self.fit, self.fit);
                    cairo.cairo_translate(cr, -lay_card.popup_w * 0.5, 0.0);
                    lay_card.paint(cr, cfg, self.widget_ptr);
                }
            },
            .world_clock => {
                // Same frame as the cards: centre on the slot, scale by the
                // output fit, then by the widget's own scale — the panel is
                // authored at `us = 1` and brings its fill, rounding, rows
                // and switches itself. It needs no shadow of its own (the
                // spec's popup sits flush), so nothing is painted beside it.
                if (self.wc) |s| {
                    const cw = (self.wc_geom.w + wc_panel.k_shadow_pad * 2.0) * self.wc_us;
                    cairo.cairo_save(cr);
                    cairo.cairo_translate(cr, @floatFromInt(self.card_cx), 0.0);
                    cairo.cairo_scale(cr, self.fit, self.fit);
                    cairo.cairo_translate(cr, -cw * 0.5, 0.0);
                    cairo.cairo_scale(cr, self.wc_us, self.wc_us);
                    // The plate's alpha is the Appearance → Opacity "World
                    // clock" knob — the single authority for this surface,
                    // like Calendar and Weather for their cards. Read off
                    // the pushed config at paint time so a drag moves a
                    // panel that is already up; 1.0 when none was pushed.
                    const wc_bg: f64 = if (self.widget_cfg) |cfg|
                        overlay.scale(&cfg.appearance, .world_clock)
                    else
                        1.0;
                    wc_panel.paint(cr, s, &self.wc_geom, self.card_colors, wc_bg, epochMs());
                    cairo.cairo_restore(cr);
                }
            },
            else => {
                cairo.cairo_translate(cr, @floatFromInt(self.menu_x), 0);
                pmp.paintMenu(cr, self.menu_w, self.items.items, us, self.card_colors, self.menu_alpha);
            },
        }
        cairo.cairo_restore(cr);
    }
};

test "popup: window id band round-trips" {
    const t = std.testing;
    try t.expect(isWindowId(window_first));
    try t.expect(isWindowId(window_first + 999));
    try t.expect(!isWindowId(window_first + 1000));
    try t.expect(!isWindowId(window_first - 1));
    try t.expectEqual(@as(usize, 0), windowIndex(window_first).?);
    try t.expectEqual(@as(usize, 7), windowIndex(window_first + 7).?);
    try t.expect(windowIndex(new_window) == null);
    try t.expect(isDesktopActionId(desktop_action_first));
    try t.expect(!isDesktopActionId(window_first));
    try t.expect(!isDesktopActionId(@intFromEnum(Action.pin_toggle)));
}

test "popup: world clock margin keeps the widget standoff" {
    const t = std.testing;
    // A dock like DP-1's: the layer surface is 78px tall (72px bar + its
    // 6px gap) and the 44px slot starts 20px down (6px inset + 14px of
    // centring). The margin must put the card's bottom edge `16us` above the
    // widget's top edge, so the ring inside the surface is what makes the
    // raw margin look smaller than the standoff.
    const us = 1.158;
    const m = Host.wcBottomMargin(78, 20, us, 1.0);
    try t.expect(m > 0 and m < 78);
    const card_bottom: f64 = @as(f64, @floatFromInt(m)) + wc_panel.k_shadow_pad * us;
    try t.expectApproxEqAbs(@as(f64, 58.0) + 16.0 * us, card_bottom, 0.5);
    // A widget flush with the bottom edge has no room for the standoff, so
    // the margin floors at zero rather than going negative.
    try t.expectEqual(@as(i32, 0), Host.wcBottomMargin(78, 78, us, 1.0));
    try t.expectEqual(@as(i32, 0), Host.wcBottomMargin(78, 78, 0.0, 0.0));
}

test "popup: row ids map back to the actions they came from" {
    const t = std.testing;
    inline for (reflection.enumFields(Action)) |f| {
        const got = actionFromId(f.value).?;
        try t.expectEqual(@as(i32, @intCast(f.value)), @intFromEnum(got));
    }
    // The three id bands that are not fixed actions.
    try t.expect(actionFromId(window_first) == null);
    try t.expect(actionFromId(new_window) == null);
    try t.expect(actionFromId(desktop_action_first) == null);
    try t.expect(actionFromId(-1) == null);
    try t.expect(actionFromId(0) == null);
}

test "popup: menu host builds, hits and tears down without a compositor" {
    const t = std.testing;
    var h = Host.init(t.allocator);
    defer h.deinit();

    try h.pushAction("Pin", .pin_toggle, true);
    try h.pushSeparator();
    try h.push("Window", window_first, true);
    try h.push("Nope", window_first + 1, false);
    try t.expectEqual(@as(usize, 4), h.items.items.len);
    try t.expect(h.kind == .none);

    // No output, no compositor: `present` has to fail cleanly, and `reset`
    // must still leave the host reusable.
    try t.expect(!h.present(null, null, 400, 74, 200, 40, 1.0));

    h.kind = .app;
    const us = 1.0;
    const wide = pmp.menuHeight(h.items.items, us);
    try t.expect(wide > 0);
    h.menu_x = 10;
    h.menu_w = 200;
    try t.expectEqual(@as(usize, 0), h.rowAt(20, 10, us).?);
    try t.expect(h.rowAt(5, 10, us) == null);
    try t.expect(h.rowAt(300, 10, us) == null);

    try t.expect(h.hoverAt(20, 10, us));
    try t.expect(h.items.items[0].hover);
    try t.expect(!h.hoverAt(20, 10, us));
    try t.expect(h.clearHover());
    try t.expect(!h.items.items[0].hover);

    h.reset();
    try t.expectEqual(@as(usize, 0), h.items.items.len);
    try t.expect(!h.open);
}

test "popup: the calendar card opens on today's month and steps both ways" {
    const t = std.testing;
    var h = Host.init(t.allocator);
    defer h.deinit();

    const d = cal_card.Date{ .year = 2026, .month = 12, .day = 31 };
    // No compositor: `openCalendar` has to refuse without leaving a kind set.
    // The colours and the opacity ride along regardless — `card_colors`
    // always has — so what the popup is *painted* like travels together;
    // a refusal just leaves them to the reset that follows.
    try t.expect(!h.openCalendar(null, null, 1280, 74, 600, d, .{}, 0.18, 1.0));
    try t.expect(h.kind == .none);
    try t.expectEqual(@as(f64, 0.18), h.card_alpha);
    h.reset();
    try t.expectEqual(@as(f64, 1.0), h.card_alpha);

    // Drive the model the way the dock does, minus the surface.
    h.kind = .calendar;
    h.cal_selected = d;
    h.cal_display = .{ .year = d.year, .month = d.month, .day = 1 };
    h.cal_today = d;
    h.stepMonth(1);
    try t.expect(h.cal_display.month == 1 and h.cal_display.year == 2027);
    h.stepMonth(-1);
    h.stepMonth(-1);
    try t.expect(h.cal_display.month == 11 and h.cal_display.year == 2026);
    h.stepMonth(0);
    try t.expect(h.cal_display.month == 11);

    // A click on a nav button answers without dismissing; anywhere else is a
    // dismiss. The card is 320 wide, so put its left edge at 0 and click the
    // buttons through `cardClick`'s own translation.
    h.card_cx = 160;
    h.buf_w = 1280;
    const nav = cal_card.navGeom(cal_card.width, 1.0);
    try t.expect(h.cardClick(@as(i32, @intFromFloat(nav.next_x + 4)), @as(i32, @intFromFloat(nav.nav_y + 4))) == .next_month);
    try t.expect(h.cardClick(@as(i32, @intFromFloat(nav.prev_x + 4)), @as(i32, @intFromFloat(nav.nav_y + 4))) == .prev_month);
    try t.expect(h.cardClick(160, 300) == .dismiss);
    // A menu host answers every click with a dismiss too.
    h.kind = .none;
    try t.expect(h.cardClick(160, 300) == .dismiss);

    h.reset();
    try t.expect(h.cal_display.year == 1970);
}
