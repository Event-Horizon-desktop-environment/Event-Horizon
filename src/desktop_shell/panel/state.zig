//! Panel runtime state — port of the `PanelApp` fields in
//! `src/desktop_shell/panel/core/panel.hpp:116-249` that are pure logic.
//!
//! Wayland objects (`wl_display`, layer surfaces, SHM buffers, tray bus) stay
//! in the binary (`bin/panel.zig`); this file owns the state machine the C++
//! threads through every handler: reveal/auto-hide slide, hover/press,
//! popup open state, tooltips, context-hide, and the scaled-icon LRU.

const std = @import("std");
const types = @import("types.zig");

/// Hover/press sentinel: no slot (`panel.hpp:128-129` hoverSlot/pressedSlot).
pub const no_slot: i32 = -1;

/// Media hover zone sentinel: not over media (`panel.cpp:215-218`).
pub const media_zone_none: i32 = -2;

/// Auto-hide slide state (`panel.hpp:219-225`, `panel.cpp:580-596`).
pub const Slide = struct {
    reveal: bool = true,
    offset_px: f64 = 0,
    target_px: f64 = 0,

    /// One vsync step toward the target (`diff * 0.35`, settle at 0.5px).
    /// Returns true while still moving so the caller chains another frame.
    pub fn step(self: *Slide, hide_target: f64) bool {
        self.target_px = hide_target;
        const diff = hide_target - self.offset_px;
        if (@abs(diff) > 0.5) {
            self.offset_px += diff * 0.35;
            return true;
        }
        self.offset_px = hide_target;
        return false;
    }
};

/// Popup open state (`panel.hpp:184-202`).
pub const Popup = struct {
    kind: types.PopupKind = .none,
    anchor_x: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    hover_item: i32 = -1,
    /// Kind dismissed by the current press: a release on the owning slot must
    /// not reopen it (toggle-close, `panel.hpp:243-245`).
    press_dismissed: types.PopupKind = .none,

    pub fn isOpen(self: Popup) bool {
        return self.kind != .none;
    }

    pub fn open(self: *Popup, kind: types.PopupKind, anchor_x: i32, w: i32, h: i32) void {
        self.kind = kind;
        self.anchor_x = anchor_x;
        self.w = w;
        self.h = h;
        self.hover_item = -1;
    }

    pub fn close(self: *Popup) void {
        self.kind = .none;
        self.hover_item = -1;
    }

    /// `panel_toggle_closed` (`panel.cpp:1245`).
    pub fn toggleClosed(self: Popup, kind: types.PopupKind) bool {
        return self.press_dismissed == kind;
    }
};

/// Tooltip state (`panel.hpp:227-236`, `panel.cpp:929-958`).
pub const Tooltip = struct {
    hover_slot: i32 = -1,
    shown_slot: i32 = -1,
    hover_start_ms: u64 = 0,
    text: []const u8 = "",

    pub fn cancel(self: *Tooltip) void {
        self.hover_slot = -1;
        self.shown_slot = -1;
        self.text = "";
    }

    /// Whether `now_ms` has waited out the 500 ms hover delay
    /// (`kPanelTooltipDelayMs`, `panel.cpp:952`).
    pub fn due(self: Tooltip, hover: i32, now_ms: u64) bool {
        if (hover < 0 or hover != self.hover_slot) return false;
        if (self.shown_slot == hover) return false;
        return now_ms >= self.hover_start_ms + tooltip_delay_ms;
    }
};

pub const tooltip_delay_ms: u64 = 500;
pub const tooltip_pad_h: i32 = 10;
pub const tooltip_pad_v: i32 = 6;

/// Context-hide state (`panel.hpp:222-224`, `panel.cpp:891-915`).
pub const ContextHide = struct {
    last_active_ws: i32 = -1,
    reveal_until_ms: u64 = 0,
};

/// Bounded FIFO icon-scale cache — port of `PanelScaledIconCache`
/// (`panel.hpp:65-94`, `panel_paint.cpp:30-69`): 128 entries, FIFO eviction,
/// hit/miss counters. Keyed by source id + target size (the C++ keys on the
/// source surface pointer; Zig callers pass the surface address as `src_id`).
pub const ScaledIconCache = struct {
    pub const cap: usize = 128;
    pub const Key = struct {
        src_id: u64,
        w: i32,
        h: i32,
    };

    keys: [cap]Key = undefined,
    len: usize = 0,
    start: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn find(self: *ScaledIconCache, src_id: u64, w: i32, h: i32) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const k = self.keys[(self.start + i) % cap];
            if (k.src_id == src_id and k.w == w and k.h == h) {
                self.hits += 1;
                return true;
            }
        }
        self.misses += 1;
        return false;
    }

    pub fn insert(self: *ScaledIconCache, src_id: u64, w: i32, h: i32) void {
        const k = Key{ .src_id = src_id, .w = w, .h = h };
        if (self.len < cap) {
            self.keys[(self.start + self.len) % cap] = k;
            self.len += 1;
            return;
        }
        // Full: evict the oldest (FIFO, `panel_paint.cpp:58-65`).
        self.keys[self.start] = k;
        self.start = (self.start + 1) % cap;
    }

    pub fn clear(self: *ScaledIconCache) void {
        self.len = 0;
        self.start = 0;
    }
};

/// The panel's owned runtime: slide + popup + tooltip + context-hide plus the
/// pointer/slot fields the handlers share (`panel.hpp:124-245`).
pub const State = struct {
    enabled: bool = false,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    hover_slot: i32 = no_slot,
    pressed_slot: i32 = no_slot,
    press_button: u32 = 0,
    hover_lift_px: f64 = 0,
    media_hover_zone: i32 = media_zone_none,
    slide: Slide = .{},
    popup: Popup = .{},
    tooltip: Tooltip = .{},
    context_hide: ContextHide = .{},
    icons: ScaledIconCache = .{},
    last_bar_x: f64 = 0,
    last_bar_y: f64 = 0,
    last_bar_w: f64 = 0,
    last_bar_h: f64 = 0,

    /// `panel_apply_autohide_state` (`panel.cpp:878-889`): auto-hide off
    /// snaps the bar visible; on starts hidden.
    pub fn applyAutohide(self: *State, auto_hide: bool, bar_h: i32) void {
        if (!auto_hide) {
            self.slide.offset_px = 0;
            self.slide.target_px = 0;
            self.slide.reveal = true;
        } else {
            self.slide.reveal = false;
            self.slide.target_px = @floatFromInt(bar_h);
            self.slide.offset_px = self.slide.target_px;
        }
    }

    pub fn onPointerLeave(self: *State, auto_hide: bool, bar_h: i32) void {
        self.hover_slot = no_slot;
        self.pressed_slot = no_slot;
        self.tooltip.cancel();
        if (auto_hide) {
            self.slide.reveal = false;
            self.slide.target_px = @floatFromInt(bar_h);
        }
    }

    pub fn onPointerEnter(self: *State, auto_hide: bool) void {
        if (auto_hide) {
            self.slide.reveal = true;
            self.slide.target_px = 0;
        }
    }
};

test "panel-state: autohide snap matches panel_apply_autohide_state" {
    const t = std.testing;
    var st = State{};
    st.applyAutohide(false, 36);
    try t.expect(st.slide.reveal);
    try t.expectEqual(@as(f64, 0), st.slide.offset_px);
    st.applyAutohide(true, 36);
    try t.expect(!st.slide.reveal);
    try t.expectEqual(@as(f64, 36), st.slide.offset_px);
    st.onPointerEnter(true);
    try t.expect(st.slide.reveal);
    st.onPointerLeave(true, 36);
    try t.expectEqual(@as(i32, -1), st.hover_slot);
    try t.expect(!st.slide.reveal);
}

test "panel-state: slide eases along the frame chain" {
    const t = std.testing;
    var s = Slide{ .offset_px = 36, .reveal = false };
    var moving = true;
    var n: usize = 0;
    while (moving and n < 100) : (n += 1) moving = s.step(0);
    try t.expect(!moving);
    try t.expectEqual(@as(f64, 0), s.offset_px);
}

test "panel-state: popup toggle-close + tooltip delay" {
    const t = std.testing;
    var p = Popup{};
    try t.expect(!p.isOpen());
    p.open(.calendar, 500, 320, 340);
    try t.expect(p.isOpen());
    p.press_dismissed = .calendar;
    try t.expect(p.toggleClosed(.calendar));
    try t.expect(!p.toggleClosed(.tray));
    p.close();
    try t.expect(!p.isOpen());

    var tt = Tooltip{ .hover_slot = 3, .hover_start_ms = 1000 };
    try t.expect(!tt.due(3, 1200));
    try t.expect(tt.due(3, 1500));
    try t.expect(!tt.due(4, 2000));
}

test "panel-state: icon cache is a 128-entry FIFO with counters" {
    const t = std.testing;
    var c = ScaledIconCache{};
    try t.expect(!c.find(1, 22, 22));
    c.insert(1, 22, 22);
    try t.expect(c.find(1, 22, 22));
    try t.expectEqual(@as(u64, 1), c.hits);
    try t.expectEqual(@as(u64, 1), c.misses);
    var i: u64 = 2;
    while (i < 200) : (i += 1) c.insert(i, 22, 22);
    try t.expectEqual(@as(usize, 128), c.len);
    try t.expect(!c.find(1, 22, 22)); // evicted
}
