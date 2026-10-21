const std = @import("std");
const app_mod = @import("app.zig");
const common = @import("common.zig");

// Embed lifecycle + window geometry — Zig port of
// src/ux/settings/common/embed/settings_embed*.{hpp,cpp} (geometry/state only;
// Wayland/xdg-toplevel plumbing stays in wl/surface/layer.zig).
// Same design: 900x980 window, sidebar 260px, content inset, open animation
// presentT 0->1, single-instance toggle.

pub const default_w: i32 = 900;
pub const default_h: i32 = 980;

pub const ContentGeom = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub fn contentGeom(width: i32, height: i32) ContentGeom {
    const x: i32 = common.spacing_l + common.sidebar_w + common.spacing_l;
    return .{
        .x = x,
        .y = common.content_top,
        .w = width - x - common.spacing_l,
        .h = height - common.content_top - common.spacing_l,
    };
}

pub const EmbedState = struct {
    visible: bool = false,
    present_t: f32 = 1.0,
    open_mono_ms: u64 = 0,

    pub fn toggle(self: *EmbedState, now_ms: u64) void {
        self.visible = !self.visible;
        if (self.visible) {
            self.present_t = 0.0;
            self.open_mono_ms = now_ms;
        } else {
            self.present_t = 1.0;
        }
    }

    pub fn tickOpenAnim(self: *EmbedState, now_ms: u64) void {
        if (!self.visible) return;
        const dt: f32 = @as(f32, @floatFromInt(now_ms -% self.open_mono_ms)) / 180.0;
        self.present_t = @min(1.0, @max(0.0, dt));
    }
};

pub fn clampTab(tab: i32) i32 {
    // Mirrors settings_app.cpp fallbacks: removed layout page 3 -> monitors 7.
    if (tab == 3) return 7;
    if (app_mod.tabTitle(tab) != null) return tab;
    // Solo ids not in sidebar subs (taskflip/workspaces/dashboard) are valid.
    if (tab == 60 or tab == 61 or tab == 62) return tab;
    return 0;
}

test "settings-embed: geom + toggle + clamp" {
    const t = std.testing;
    const g = contentGeom(900, 980);
    try t.expectEqual(@as(i32, 292), g.x);
    try t.expectEqual(@as(i32, 592), g.w);
    var e = EmbedState{};
    e.toggle(1000);
    try t.expect(e.visible);
    e.tickOpenAnim(1090);
    try t.expectApproxEqAbs(@as(f32, 0.5), e.present_t, 0.01);
    try t.expectEqual(@as(i32, 7), clampTab(3));
    try t.expectEqual(@as(i32, 0), clampTab(999));
}
