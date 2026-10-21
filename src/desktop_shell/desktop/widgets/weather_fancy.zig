const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const weather_svc = @import("../../../services/weather.zig");
const card = @import("../../widgets/weather_fancy_card.zig");
const chrome = @import("../../widgets/shared/chrome_colors.zig");
const widget = @import("widget.zig");

// Desktop weather-fancy widget.
// design: the shared 340-wide fancy card (`weather_fancy_card.paintCard`),
// height measured at paint time, fed from the weather service reading.

pub const State = struct {
    widget_id: []const u8 = "",
    height: i32 = 380,
};

pub fn stateFromConfig(cfg: dw_data.WidgetConfig) State {
    return .{ .widget_id = cfg.id };
}

pub fn refresh(s: *State, io: std.Io) void {
    _ = io;
    _ = s;
}

pub fn ticks(s: *const State) bool {
    _ = s;
    return true;
}

pub fn size(s: *const State) [2]i32 {
    return .{ 340, s.height };
}

pub fn paint(s: *State, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    const c = cr orelse return;
    var r = weather_svc.Reading{};
    const has = weather_svc.take(&r);
    var st = card.State{};
    if (has and r.available) {
        st.available = true;
        st.temp = r.temp;
        st.hi = r.hi;
        st.lo = r.lo;
        st.feels_like = r.feels_like;
        st.humidity_pct = r.humidity_pct;
        st.wind_kmh = r.wind_kmh;
        st.visibility_m = r.visibility_m;
        st.icon = r.glyph;
        const full = r.placeName();
        st.city = if (std.mem.indexOfScalar(u8, full, ',')) |ci| full[0..ci] else full;
        st.condition = r.conditionText();
        const n: usize = @min(r.n_days, st.days.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            st.days[i] = .{ .icon = r.days[i].glyph, .hi = r.days[i].hi, .lo = r.days[i].lo, .wday = r.days[i].wday };
        }
        st.n_days = @intCast(n);
    }
    const cc = chrome.Chrome{
        .dock_fill = .{ .r = ctx.dock_fill_r, .g = ctx.dock_fill_g, .b = ctx.dock_fill_b },
        .accent = .{ .r = ctx.acc_r, .g = ctx.acc_g, .b = ctx.acc_b },
        .text = .{ .r = ctx.text_r, .g = ctx.text_g, .b = ctx.text_b },
    };
    const h = card.paintCard(c, card.width, cc, ctx.overlay_widget_card, &st);
    s.height = @intFromFloat(@ceil(h));
}
