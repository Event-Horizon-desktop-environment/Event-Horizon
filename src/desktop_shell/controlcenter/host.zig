//! Control-center popup host: the layer surface the dock's
//! control-center slot opens. Owns the `State`, the arena-duplicated
//! `Snapshot`, the computed `Layout` + mixer rows, and the SHM paint.
//!
//! Paint and hit share one layout (`layout.computeLayout`), so clicks land
//! on the pixels. Backend writes (volume, mute, device
//! switch, wifi connect, bluetooth pair, media keys) are reported back to
//! the dock as `Action`s; the dock applies them to live services where a
//! Zig backend exists and otherwise updates the local snapshot so the UI
//! still moves under the pointer.

const std = @import("std");
const wl = @import("../../wl/c.zig").wl;
const layer = @import("../../wl/surface/layer.zig");
const shm_mod = @import("../../wl/buffer/shm.zig");
const cairo = shm_mod.cairo;
const cc_state = @import("state.zig");
const cc_layout = @import("layout.zig");
const cc_data = @import("data.zig");
const cc_hit = @import("hit.zig");
const cc_paint = @import("paint.zig");
const chrome = @import("../widgets/shared/chrome_colors.zig");
const ns = @import("../common/namespaces.zig");
const schema = @import("../../config/schema.zig");

pub const popup_w: i32 = 460;
const gap_above_dock: f64 = 6.0;

pub const Action = union(enum) {
    none,
    toggle_network_expanded,
    toggle_bluetooth_expanded,
    toggle_mixer_expanded,
    toggle_output_devices,
    toggle_input_devices,
    set_output_volume: f64,
    set_input_volume: f64,
    toggle_output_mute,
    toggle_input_mute,
    set_mixer_volume: struct { stream_id: i32, is_input: bool, t: f64 },
    select_output_device: i32,
    select_input_device: i32,
    select_network_row: i32,
    select_bluetooth_row: i32,
    forget_bluetooth_row: i32,
    submit_wifi_password,
    cancel_wifi_password,
    media_button: usize,
    dismiss,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    shm: shm_mod.ShmBuffer,
    surface: layer.Surface = .{},
    arena: std.heap.ArenaAllocator,

    state: cc_state.State = .{},
    snap: cc_data.Snapshot = .{},
    layout: cc_layout.Layout = .{},
    mix_rows: std.ArrayList(cc_layout.MixerRow) = .empty,
    counts: cc_layout.Counts = .{},
    cfg: ?*const schema.ShellConfig = null,

    open: bool = false,
    buf_w: i32 = 0,
    buf_h: i32 = 0,
    popup_w_px: i32 = popup_w,
    /// Fit-to-output factor (output height / 1440, clamped). The panel is
    /// authored at a fixed natural size; this scales the whole surface up/down
    /// via one `cairo_scale` so a shorter output gets a smaller control center
    /// while the slider/drag/hit logic stays in natural coordinates.
    fit: f64 = 1.0,
    /// Last placement, reused when the surface is recreated after a height
    /// change (an expanding panel, a new device/stream row, the Wi-Fi
    /// password prompt) — mirrors `pear/host.zig`'s fields.
    last_margin_left: i32 = 0,
    last_margin_bottom: i32 = 0,
    /// The clock the last `relayout` ran with. `configured` has no caller
    /// clock of its own and an animation interpolates against real time,
    /// so it reuses this rather than resolving against epoch 0 (which would
    /// land on the stale `from` side of an ease that is already over).
    last_now_ms: u64 = 0,
    /// Wayland objects for surface recreation (borrowed from the dock;
    /// valid while the popup is open).
    compositor: ?*wl.wl_compositor = null,
    shell: ?*wl.zwlr_layer_shell_v1 = null,
    output: ?*wl.wl_output = null,

    dragging_output: bool = false,
    dragging_input: bool = false,
    dragging_mixer: bool = false,
    drag_stream_id: i32 = -1,
    drag_is_input: bool = false,

    /// Wi-Fi password entry (keeping
    /// `wifiPendingSsid`/`wifiPassword` on the state; fixed buffers here so
    /// layout/paint stay allocator-free). Mirrored into the snapshot for
    /// paint on every mutation via `syncPw`.
    pw_ssid: [96]u8 = undefined,
    pw_ssid_len: usize = 0,
    pw: [128]u8 = undefined,
    pw_len: usize = 0,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .gpa = gpa,
            .shm = shm_mod.ShmBuffer.init(gpa),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Self) void {
        self.reset();
        self.arena.deinit();
        self.shm.deinit();
    }

    pub fn reset(self: *Self) void {
        self.surface.destroy();
        self.surface.configured_width = 0;
        self.surface.configured_height = 0;
        self.mix_rows.deinit(self.gpa);
        self.mix_rows = .empty;
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.gpa);
        self.snap = .{};
        self.layout = .{};
        self.counts = .{};
        self.cfg = null;
        self.open = false;
        self.buf_w = 0;
        self.buf_h = 0;
        // `place()` must not resurrect a surface after close.
        self.compositor = null;
        self.shell = null;
        self.output = null;
        self.dragging_output = false;
        self.dragging_input = false;
        self.dragging_mixer = false;
        self.drag_stream_id = -1;
        self.pw_ssid_len = 0;
        self.pw_len = 0;
    }

    fn dupeOpt(arena: std.mem.Allocator, s: []const u8) []const u8 {
        if (s.len == 0) return "";
        return arena.dupe(u8, s) catch "";
    }

    /// Deep-copy a snapshot into the host arena so paint/refresh never
    /// dangles after the dock's temporaries are freed.
    pub fn setSnapshot(self: *Self, src: cc_data.Snapshot) void {
        // Fresh arena per snapshot: tick updates would otherwise grow it
        // without bound (the old strings die with the old arena; `snap` is
        // overwritten below before anyone can read them).
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = self.arena.allocator();
        var dst = cc_data.Snapshot{
            .net = .{
                .connected = src.net.connected,
                .ethernet = src.net.ethernet,
                .wifi = src.net.wifi,
                .iface = dupeOpt(a, src.net.iface),
                .ssid = dupeOpt(a, src.net.ssid),
                .wifi_signal_pct = src.net.wifi_signal_pct,
            },
            .bt = src.bt,
            .out = .{
                .muted = src.out.muted,
                .volume_pct = src.out.volume_pct,
                .fill_t_override = src.out.fill_t_override,
                .device_name = dupeOpt(a, src.out.device_name),
            },
            .in = .{
                .muted = src.in.muted,
                .volume_pct = src.in.volume_pct,
                .fill_t_override = src.in.fill_t_override,
                .device_name = dupeOpt(a, src.in.device_name),
            },
            .media = .{
                .active = src.media.active,
                .title = dupeOpt(a, src.media.title),
                .artist = dupeOpt(a, src.media.artist),
                .playing = src.media.playing,
                .can_go_previous = src.media.can_go_previous,
                .can_go_next = src.media.can_go_next,
                .can_play_pause = src.media.can_play_pause,
                .has_art = src.media.has_art,
                .art_argb = if (src.media.art_argb.len > 0) a.dupe(u8, src.media.art_argb) catch "" else "",
                .art_w = src.media.art_w,
                .art_h = src.media.art_h,
            },
            .weather = .{
                .available = src.weather.available,
                .location = dupeOpt(a, src.weather.location),
                .temp = src.weather.temp,
                .feels_like = src.weather.feels_like,
                .humidity_pct = src.weather.humidity_pct,
                .wind_kmh = src.weather.wind_kmh,
                .visibility_m = src.weather.visibility_m,
                .icon = dupeOpt(a, src.weather.icon),
                .fahrenheit = src.weather.fahrenheit,
            },
            .wifi_error = dupeOpt(a, src.wifi_error),
            .wifi_password_prompt = src.wifi_password_prompt,
            .bt_error = dupeOpt(a, src.bt_error),
        };
        // Lists: copy element-wise so inner strings are arena-owned too.
        if (src.aps.len > 0) {
            if (a.dupe(cc_data.WifiAp, src.aps)) |buf| {
                for (src.aps, 0..) |ap, i| buf[i] = .{
                    .active = ap.active,
                    .ssid = dupeOpt(a, ap.ssid),
                    .signal_pct = ap.signal_pct,
                    .needs_password = ap.needs_password,
                };
                dst.aps = buf;
            } else |_| {}
        }
        if (src.bt_devs.len > 0) {
            if (a.dupe(cc_data.BluetoothDevice, src.bt_devs)) |buf| {
                for (src.bt_devs, 0..) |d, i| buf[i] = .{
                    .address = dupeOpt(a, d.address),
                    .alias = dupeOpt(a, d.alias),
                    .paired = d.paired,
                    .connected = d.connected,
                    .kind = dupeOpt(a, d.kind),
                    .battery_pct = d.battery_pct,
                };
                dst.bt_devs = buf;
            } else |_| {}
        }
        if (src.out_devs.len > 0) {
            if (a.dupe(cc_data.OutputDevice, src.out_devs)) |buf| {
                for (src.out_devs, 0..) |d, i| buf[i] = .{
                    .sink_name = dupeOpt(a, d.sink_name),
                    .display_name = dupeOpt(a, d.display_name),
                    .is_default = d.is_default,
                };
                dst.out_devs = buf;
            } else |_| {}
        }
        if (src.in_devs.len > 0) {
            if (a.dupe(cc_data.InputDevice, src.in_devs)) |buf| {
                for (src.in_devs, 0..) |d, i| buf[i] = .{
                    .source_name = dupeOpt(a, d.source_name),
                    .display_name = dupeOpt(a, d.display_name),
                    .is_default = d.is_default,
                };
                dst.in_devs = buf;
            } else |_| {}
        }
        if (src.out_streams.len > 0) {
            if (a.dupe(cc_data.MixerStream, src.out_streams)) |buf| {
                for (src.out_streams, 0..) |st, i| buf[i] = .{
                    .sink_input_id = st.sink_input_id,
                    .volume_pct = st.volume_pct,
                    .muted = st.muted,
                    .app_name = dupeOpt(a, st.app_name),
                    .icon_argb = if (st.icon_argb.len > 0) a.dupe(u8, st.icon_argb) catch "" else "",
                    .icon_w = st.icon_w,
                    .icon_h = st.icon_h,
                };
                dst.out_streams = buf;
            } else |_| {}
        }
        if (src.in_streams.len > 0) {
            if (a.dupe(cc_data.MixerStream, src.in_streams)) |buf| {
                for (src.in_streams, 0..) |st, i| buf[i] = .{
                    .sink_input_id = st.sink_input_id,
                    .volume_pct = st.volume_pct,
                    .muted = st.muted,
                    .app_name = dupeOpt(a, st.app_name),
                    .icon_argb = if (st.icon_argb.len > 0) a.dupe(u8, st.icon_argb) catch "" else "",
                    .icon_w = st.icon_w,
                    .icon_h = st.icon_h,
                };
                dst.in_streams = buf;
            } else |_| {}
        }
        if (src.weather.forecast.len > 0) {
            if (a.dupe(cc_data.ForecastDay, src.weather.forecast)) |buf| {
                for (src.weather.forecast, 0..) |d, i| buf[i] = .{
                    .day = dupeOpt(a, d.day),
                    .hi = d.hi,
                    .lo = d.lo,
                    .icon = dupeOpt(a, d.icon),
                };
                dst.weather.forecast = buf;
            } else |_| {}
        }
        self.snap = dst;
        self.syncPw();
        self.counts = .{
            .net_rows = @intCast(@min(src.aps.len, 8)),
            .bt_rows = @intCast(@min(src.bt_devs.len, 8)),
            .out_dev_rows = @intCast(@min(src.out_devs.len, 12)),
            .in_dev_rows = @intCast(@min(src.in_devs.len, 12)),
            .mix_total_out = @intCast(src.out_streams.len),
            .mix_total_in = @intCast(src.in_streams.len),
            .wifi_error = src.wifi_error.len > 0,
            .wifi_password_prompt = src.wifi_password_prompt,
        };
    }

    /// Mirror the password buffers into the snapshot paint reads.
    fn syncPw(self: *Self) void {
        const a = self.arena.allocator();
        self.snap.wifi_pending_ssid = if (self.pw_ssid_len > 0)
            a.dupe(u8, self.pw_ssid[0..self.pw_ssid_len]) catch ""
        else
            "";
        self.snap.wifi_password = if (self.pw_len > 0)
            a.dupe(u8, self.pw[0..self.pw_len]) catch ""
        else
            "";
        self.snap.wifi_password_prompt = self.pw_ssid_len > 0;
        // The network panel must be open to show the prompt row; counts grow
        // with it so layout reserves the 56 px.
        self.counts.wifi_password_prompt = self.pw_ssid_len > 0;
    }

    /// Open the password prompt for `ssid` (network row press on a secured
    /// AP). Replaces any previous pending entry.
    pub fn promptPassword(self: *Self, ssid: []const u8) void {
        const n = @min(ssid.len, self.pw_ssid.len);
        @memcpy(self.pw_ssid[0..n], ssid[0..n]);
        self.pw_ssid_len = n;
        self.pw_len = 0;
        self.state.network_expanded = true;
        self.syncPw();
    }

    pub fn cancelPassword(self: *Self) void {
        self.pw_ssid_len = 0;
        self.pw_len = 0;
        self.syncPw();
    }

    pub fn pendingSsid(self: *const Self) []const u8 {
        return self.pw_ssid[0..self.pw_ssid_len];
    }

    pub fn pendingPassword(self: *const Self) []const u8 {
        return self.pw[0..self.pw_len];
    }

    /// `resolve_anims = false` is the *animated* form painted and
    /// hits with (`cc_compute_layout(W, state, nowMs)`): panel heights
    /// interpolate between their flags over the 200 ms ease, and the anim
    /// fields are cleared here once they have run out. `true` is the
    /// resting form that only *sizes the surface* — "Size with animations resolved
    /// to their targets so the surface is born at its resting height;
    /// paint/hit keep using the interpolated form."
    pub fn relayout(self: *Self, now_ms: u64, resolve_anims: bool) void {
        self.last_now_ms = now_ms;
        self.mix_rows.clearRetainingCapacity();
        self.layout = cc_layout.computeLayout(
            @floatFromInt(self.popup_w_px),
            &self.state,
            self.counts,
            now_ms,
            resolve_anims,
            self.gpa,
            &self.mix_rows,
        );
    }

    /// True while a panel expand/collapse is still easing. The dock pumps
    /// frames until this goes false (`onAnimTick`); the frame pump picks
    /// up subsequent frames after a toggle.
    pub fn animActive(self: *const Self) bool {
        const s = &self.state;
        return s.net_anim_start_ms != 0 or s.bt_anim_start_ms != 0 or s.weather_anim_start_ms != 0;
    }

    /// Open under the dock. `width_px` is the panel width
    /// (620 × ui-scale for legacy).
    /// `margin_left` positions the panel above the spawning slot
    /// (`compute_popup_position`: centered on the slot anchor, clamped to
    /// the dock and output); the surface anchors bottom|left.
    /// Returns false when the compositor refused the surface.
    pub fn openControlCenter(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        output: ?*wl.wl_output,
        dock_w: i32,
        dock_h: i32,
        width_px: i32,
        margin_left: i32,
        margin_bottom: i32,
        fit: f64,
        cfg: *const schema.ShellConfig,
        snap: cc_data.Snapshot,
        now_ms: u64,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0) return false;
        if (width_px <= 0) return false;
        self.reset();
        self.cfg = cfg;
        self.fit = if (fit > 0.0) fit else 1.0;
        self.setSnapshot(snap);
        if (!self.surface.create(compositor, shell, output, .overlay, ns.control_center)) {
            // A refused open leaves the host exactly as closed as it was.
            self.reset();
            return false;
        }
        // Width commits only once the surface exists (see above).
        self.popup_w_px = width_px;
        self.last_margin_left = margin_left;
        self.last_margin_bottom = margin_bottom;
        self.compositor = compositor;
        self.shell = shell;
        self.output = output;
        self.relayout(now_ms, true);
        // Bottom|left:
        // the left margin was computed from the spawning slot's anchor X so
        // the panel lands above its widget instead of screen-centered.
        self.surface.setAnchor(layer.Anchor.bottom | layer.Anchor.left);
        self.surface.setExclusiveZone(-1);
        self.surface.setMargins(0, 0, @max(0, margin_bottom), @max(0, margin_left));
        self.surface.setSize(
            @intCast(@as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(self.popup_w_px)) * self.fit)))),
            @intCast(@as(i32, @intFromFloat(@ceil(self.layout.total_h * self.fit)))),
        );
        // On-demand keyboard for the Wi-Fi password prompt.
        self.surface.setKeyboardInteractivity(1);
        self.surface.commit();
        self.open = true;
        return true;
    }

    /// (Re)create the layer surface at the layout's *resting* height. Every
    /// expansion changes the height — network/bluetooth panels, the two
    /// device dropdowns, the mixer, the password prompt — and a layer
    /// surface sized once at open would clip all of it, so resize here means:
    /// destroy + recreate at the new
    /// height, then let the compositor configure and repaint through the
    /// normal path. Placement (bottom|left, slot-anchored margins) is
    /// restored from the last open so the panel stays over its widget.
    /// The height is resolved (`resolve_anims = true`) so a surface born
    /// mid-ease is already tall enough for the ease to play into it —
    /// paint then uses the interpolated form against the same state.
    pub fn place(self: *Self, now_ms: u64) bool {
        if (self.compositor == null or self.shell == null) return false;
        self.relayout(now_ms, true);
        self.surface.destroy();
        self.surface.configured_width = 0;
        self.surface.configured_height = 0;
        self.buf_w = 0;
        self.buf_h = 0;
        self.open = false;
        if (!self.surface.create(self.compositor, self.shell, self.output, .overlay, ns.control_center)) return false;
        self.surface.setAnchor(layer.Anchor.bottom | layer.Anchor.left);
        self.surface.setExclusiveZone(-1);
        self.surface.setMargins(0, 0, @max(0, self.last_margin_bottom), @max(0, self.last_margin_left));
        self.surface.setSize(
            @intCast(@as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(self.popup_w_px)) * self.fit)))),
            @intCast(@as(i32, @intFromFloat(@ceil(self.layout.total_h * self.fit)))),
        );
        // On-demand keyboard for the Wi-Fi password prompt.
        self.surface.setKeyboardInteractivity(1);
        self.surface.commit();
        self.open = true;
        return true;
    }

    pub fn configured(self: *Self, wlshm: ?*wl.wl_shm) void {
        const w: i32 = @intCast(self.surface.configured_width);
        const h: i32 = @intCast(self.surface.configured_height);
        if (w <= 0 or h <= 0) return;
        // `buf_w`/`buf_h` stay logical (refresh draws in them); only the buffer
        // is allocated at device pixels.
        if (!self.shm.ensure(wlshm, "dock-cc", w * self.surface.scale, h * self.surface.scale)) return;
        self.buf_w = w;
        self.buf_h = h;
        // The compositor may hand back a different width; recover the natural
        // (unscaled) width so the layout/paint/hit arithmetic stays in natural
        // coordinates — only the surface and buffer carry the fit scale.
        self.popup_w_px = @intFromFloat(@round(@as(f64, @floatFromInt(w)) / self.fit));
        self.relayout(self.last_now_ms, false);
        self.refresh();
    }

    /// The surface can be taller than the card it holds: a collapse leaves
    /// the taller surface standing so the ease plays unclipped, and an
    /// expand is born at the resting height before its ease catches up. It
    /// is anchored bottom above the dock, so the card is pinned to the
    /// *bottom* of the buffer — flush with the dock — and the leftover
    /// strip falls above it. At rest this is zero, so nothing moves; mid-ease
    /// it keeps the panel glued to the dock instead of lifting off it, and
    /// makes the settle-recreate land on the exact pixels it replaced.
    fn cardOffsetY(self: *const Self) f64 {
        return @max(0.0, @as(f64, @floatFromInt(self.buf_h)) / self.fit - self.layout.total_h);
    }

    pub fn refresh(self: *Self) void {
        if (!self.open or self.buf_w <= 0 or self.buf_h <= 0) return;
        const cfg = self.cfg orelse return;
        const cr = self.shm.cr orelse return;
        cairo.cairo_save(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
        cairo.cairo_paint(cr);
        // Scale the whole frame to the output's device pixels. Everything
        // below draws in logical coordinates (buf_w/buf_h, cardOffsetY);
        // cairo rasterises at the buffer's native resolution so HiDPI stays
        // crisp. Scale before the translate so the offset scales with it.
        cairo.cairo_identity_matrix(cr);
        const csc: f64 = @floatFromInt(self.surface.scale);
        cairo.cairo_scale(cr, csc * self.fit, csc * self.fit);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        cairo.cairo_translate(cr, 0.0, self.cardOffsetY());
        cc_paint.paint(cr, @floatFromInt(self.popup_w_px), .{
            .cfg = cfg,
            .state = &self.state,
            .layout = self.layout,
            .mix_rows = self.mix_rows.items,
            .snap = self.snap,
            .now_ms = self.last_now_ms,
        });
        cairo.cairo_restore(cr);
        self.surface.attach(self.shm.wlBuffer(), 0, 0);
        self.surface.setBufferScale(self.surface.scale);
        self.surface.damage(0, 0, self.buf_w, self.buf_h);
        self.shm.markBusy();
        self.surface.commit();
    }

    fn hoverClear(self: *Self) void {
        self.state.clearHover();
    }

    /// Pointer press inside the popup (surface coordinates). Starts slider
    /// drags inline and returns toggle/button actions for the dock to apply.
    pub fn press(self: *Self, px_in: f64, py_surf: f64) Action {
        // Surface → natural coordinates (undo the fit scale), then surface →
        // card coordinates (`cardOffsetY`), so input tracks the translated
        // paint exactly.
        const px = px_in / self.fit;
        const py = py_surf / self.fit - self.cardOffsetY();
        const l = self.layout;
        // Mute icons first (small target inside the card).
        if (cc_hit.audioMuteHit(l, true, px, py)) return .toggle_output_mute;
        if (cc_hit.audioMuteHit(l, false, px, py)) return .toggle_input_mute;
        // Sliders start a drag and jump to the pointer.
        if (cc_hit.audioSliderHit(l, true, px, py)) |t| {
            self.dragging_output = true;
            self.state.audio_drag_active = true;
            self.state.audio_drag_visual_t = t;
            return .{ .set_output_volume = t };
        }
        if (cc_hit.audioSliderHit(l, false, px, py)) |t| {
            self.dragging_input = true;
            self.state.input_drag_active = true;
            self.state.input_drag_visual_t = t;
            return .{ .set_input_volume = t };
        }
        // Mixer rows (expanded or the single collapsed row).
        for (self.mix_rows.items) |r| {
            const list = if (r.is_input) self.snap.in_streams else self.snap.out_streams;
            if (r.stream_idx < 0 or @as(usize, @intCast(r.stream_idx)) >= list.len) continue;
            const st = list[@intCast(r.stream_idx)];
            // Same measured origin as paint (`mixer_slider_xw`).
            var nbuf: [256]u8 = undefined;
            const sx = cc_paint.mixerSliderX(@floatFromInt(self.popup_w_px), st.app_name, &nbuf);
            if (cc_hit.mixerRowHit(r.y, sx, @floatFromInt(self.popup_w_px), px, py)) |t| {
                self.dragging_mixer = true;
                self.drag_stream_id = st.sink_input_id;
                self.drag_is_input = r.is_input;
                return .{ .set_mixer_volume = .{ .stream_id = st.sink_input_id, .is_input = r.is_input, .t = t } };
            }
        }
        // Cards toggle their panels.
        if (cc_hit.networkCardHit(l, px, py)) return .toggle_network_expanded;
        if (cc_hit.bluetoothCardHit(l, px, py)) return .toggle_bluetooth_expanded;
        if (cc_hit.audioCardHit(l, true, px, py)) return .toggle_output_devices;
        if (cc_hit.audioCardHit(l, false, px, py)) return .toggle_input_devices;
        if (cc_hit.mixerHeaderHit(l, px, py)) return .toggle_mixer_expanded;
        // Bluetooth forget (×) precedes the row body.
        if (cc_hit.bluetoothRowHit(l, px, py)) |i| {
            const devs = self.snap.bt_devs;
            const paired = if (i >= 0 and @as(usize, @intCast(i)) < devs.len) devs[@intCast(i)].paired else false;
            if (cc_hit.bluetoothForgetHit(l, i, paired, px, py)) return .{ .forget_bluetooth_row = i };
            return .{ .select_bluetooth_row = i };
        }
        // Rows select.
        if (cc_hit.networkRowHit(l, px, py)) |i| return .{ .select_network_row = i };
        if (cc_hit.outputDeviceRowHit(l, px, py)) |i| return .{ .select_output_device = i };
        if (cc_hit.inputDeviceRowHit(l, px, py)) |i| return .{ .select_input_device = i };
        if (cc_hit.mediaButtonHit(l, px, py)) |i| return .{ .media_button = i };
        if (cc_hit.weatherCardHit(l, px, py)) return .dismiss;
        return .none;
    }

    /// Scroll over a slider nudges it ±5%.
    pub fn scroll(self: *Self, px_in: f64, py_surf: f64, delta_px: f64) ?Action {
        if (delta_px == 0) return null;
        const px = px_in / self.fit;
        const py = py_surf / self.fit - self.cardOffsetY(); // surface → card
        const step: f64 = if (delta_px > 0) 0.05 else -0.05;
        const l = self.layout;
        if (cc_hit.audioSliderHit(l, true, px, py) != null) {
            const cur = volumeT(self.snap.out.volume_pct, self.snap.out.fill_t_override);
            const t = std.math.clamp(cur + step, 0.0, 1.0);
            self.state.audio_drag_visual_t = t;
            return .{ .set_output_volume = t };
        }
        if (cc_hit.audioSliderHit(l, false, px, py) != null) {
            const cur = volumeT(self.snap.in.volume_pct, self.snap.in.fill_t_override);
            const t = std.math.clamp(cur + step, 0.0, 1.0);
            self.state.input_drag_visual_t = t;
            return .{ .set_input_volume = t };
        }
        for (self.mix_rows.items) |r| {
            const list = if (r.is_input) self.snap.in_streams else self.snap.out_streams;
            if (r.stream_idx < 0 or @as(usize, @intCast(r.stream_idx)) >= list.len) continue;
            const st = list[@intCast(r.stream_idx)];
            var nbuf: [256]u8 = undefined;
            const sx = cc_paint.mixerSliderX(@floatFromInt(self.popup_w_px), st.app_name, &nbuf);
            if (cc_hit.mixerRowHit(r.y, sx, @floatFromInt(self.popup_w_px), px, py) != null) {
                const cur: f64 = @as(f64, @floatFromInt(st.volume_pct)) / 100.0;
                const t = std.math.clamp(cur + step, 0.0, 1.0);
                return .{ .set_mixer_volume = .{ .stream_id = st.sink_input_id, .is_input = r.is_input, .t = t } };
            }
        }
        return null;
    }

    fn volumeT(pct: i32, fill_override: f64) f64 {
        if (fill_override >= 0.0 and fill_override <= 1.0) return fill_override;
        return std.math.clamp(@as(f64, @floatFromInt(pct)) / 100.0, 0.0, 1.0);
    }

    /// Keyboard for the Wi-Fi password prompt (printable append, BackSpace,
    /// Enter to join, Esc to cancel/close). `sym` is the XKB keysym,
    /// `text` the decoded UTF-8 bytes, `pressed` true on key-down.
    /// Returns an action for the dock, or null when the key is not for us.
    pub fn key(self: *Self, sym: u32, text: []const u8, pressed: bool) ?Action {
        if (!pressed) return null;
        // XK_Escape.
        if (sym == 0xff1b) {
            if (self.pw_ssid_len > 0) {
                self.cancelPassword();
                return .cancel_wifi_password;
            }
            return .dismiss;
        }
        if (self.pw_ssid_len == 0) return null;
        // XK_Return / XK_KP_Enter.
        if (sym == 0xff0d or sym == 0xff8d) return .submit_wifi_password;
        // XK_BackSpace.
        if (sym == 0xff08) {
            if (self.pw_len > 0) {
                self.pw_len -= 1;
                // Rewind one full UTF-8 sequence, not one byte.
                while (self.pw_len > 0 and (self.pw[self.pw_len] & 0xC0) == 0x80) self.pw_len -= 1;
                self.syncPw();
            }
            return .none;
        }
        if (text.len > 0 and self.pw_len < self.pw.len) {
            const take = @min(text.len, self.pw.len - self.pw_len);
            @memcpy(self.pw[self.pw_len .. self.pw_len + take], text[0..take]);
            self.pw_len += take;
            self.syncPw();
            return .none;
        }
        return null;
    }

    pub fn dragTo(self: *Self, px_in: f64) ?Action {
        const px = px_in / self.fit;
        const l = self.layout;
        if (self.dragging_output) {
            const g = cc_hit.audioSliderGeom(l, true);
            const t = cc_layout.sliderTFromX(g.track_x, g.track_w, px);
            self.state.audio_drag_visual_t = t;
            return .{ .set_output_volume = t };
        }
        if (self.dragging_input) {
            const g = cc_hit.audioSliderGeom(l, false);
            const t = cc_layout.sliderTFromX(g.track_x, g.track_w, px);
            self.state.input_drag_visual_t = t;
            return .{ .set_input_volume = t };
        }
        if (self.dragging_mixer) {
            // The dragged row may have scrolled out of (or vanished from) the
            // snapshot mid-drag — without the stream there is no name to
            // measure the origin from, so the drag idles until release.
            const list = if (self.drag_is_input) self.snap.in_streams else self.snap.out_streams;
            const stream: cc_data.MixerStream = for (list) |s| {
                if (s.sink_input_id == self.drag_stream_id) break s;
            } else return null;
            var nbuf: [256]u8 = undefined;
            const sx = cc_paint.mixerSliderX(@floatFromInt(self.popup_w_px), stream.app_name, &nbuf);
            const sw = @max(60.0, @as(f64, @floatFromInt(self.popup_w_px)) - 28.0 - sx);
            const t = cc_layout.sliderTFromX(sx, sw, px);
            return .{ .set_mixer_volume = .{ .stream_id = self.drag_stream_id, .is_input = self.drag_is_input, .t = t } };
        }
        return null;
    }

    pub fn release(self: *Self) void {
        self.dragging_output = false;
        self.dragging_input = false;
        self.dragging_mixer = false;
        self.drag_stream_id = -1;
        self.state.resetDrag();
    }

    /// Pointer motion: hover highlight for cards/rows + drag continuation.
    /// Returns true when a repaint is needed.
    pub fn motion(self: *Self, px_in: f64, py_surf: f64) bool {
        if (self.dragging_output or self.dragging_input or self.dragging_mixer) return true;
        const px = px_in / self.fit;
        const py = py_surf / self.fit - self.cardOffsetY(); // surface → card
        const l = self.layout;
        const old_t = self.state.hover_target;
        const old_i = self.state.hover_row_idx;
        self.hoverClear();
        if (cc_hit.networkCardHit(l, px, py)) {
            self.state.hover_target = .network_card;
        } else if (cc_hit.bluetoothCardHit(l, px, py)) {
            self.state.hover_target = .bluetooth_card;
        } else if (cc_hit.audioMuteHit(l, true, px, py)) {
            self.state.hover_target = .output_audio_mute;
        } else if (cc_hit.audioMuteHit(l, false, px, py)) {
            self.state.hover_target = .input_audio_mute;
        } else if (cc_hit.audioSliderHit(l, true, px, py) != null) {
            self.state.hover_target = .output_audio_slider;
        } else if (cc_hit.audioSliderHit(l, false, px, py) != null) {
            self.state.hover_target = .input_audio_slider;
        } else if (cc_hit.networkRowHit(l, px, py)) |i| {
            self.state.hover_target = .network_row;
            self.state.hover_row_idx = i;
        } else if (cc_hit.bluetoothRowHit(l, px, py)) |i| {
            self.state.hover_target = .bluetooth_row;
            self.state.hover_row_idx = i;
        } else if (cc_hit.outputDeviceRowHit(l, px, py)) |i| {
            self.state.hover_target = .output_device_row;
            self.state.hover_row_idx = i;
        } else if (cc_hit.inputDeviceRowHit(l, px, py)) |i| {
            self.state.hover_target = .input_device_row;
            self.state.hover_row_idx = i;
        } else if (cc_hit.mixerHeaderHit(l, px, py)) {
            self.state.hover_target = .mixer_card;
        } else if (cc_hit.mediaButtonHit(l, px, py)) |i| {
            self.state.hover_target = switch (i) {
                0 => .media_prev,
                1 => .media_play_pause,
                else => .media_next,
            };
        } else if (cc_hit.weatherCardHit(l, px, py)) {
            self.state.hover_target = .weather_card;
        }
        return old_t != self.state.hover_target or old_i != self.state.hover_row_idx;
    }
};

test "cc-host: open needs a compositor, press maps cards to actions" {
    const t = std.testing;
    var h = Host.init(t.allocator);
    defer h.deinit();
    // No compositor: refuses without latching open.
    var cfg: schema.ShellConfig = .{};
    try t.expect(!h.openControlCenter(null, null, null, 800, 60, 620, 100, 90, 1.0, &cfg, .{}, 0));
    try t.expect(!h.open);

    // Drive the model without a surface.
    h.setSnapshot(.{
        .net = .{ .connected = true, .ethernet = true, .iface = "eth0" },
        .out = .{ .volume_pct = 80, .device_name = "Heavys H1H" },
        .in = .{ .volume_pct = 60, .device_name = "UMC202HD" },
    });
    h.cfg = &cfg;
    h.relayout(0, false);
    try t.expect(h.layout.total_h > 600);
    try t.expect(h.press(30, 30) == .toggle_network_expanded);
    try t.expect(h.press(300, 30) == .toggle_bluetooth_expanded);
    const g = cc_hit.audioSliderGeom(h.layout, true);
    try t.expect(h.press(g.track_x + 10, g.track_y) == .set_output_volume);
    h.release();
    try t.expect(!h.dragging_output);
}

test "cc-host: scroll nudges the slider under the pointer" {
    const t = std.testing;
    var h = Host.init(t.allocator);
    defer h.deinit();
    var cfg: schema.ShellConfig = .{};
    h.setSnapshot(.{ .out = .{ .volume_pct = 80 } });
    h.cfg = &cfg;
    h.relayout(0, false);
    const g = cc_hit.audioSliderGeom(h.layout, true);
    const up = h.scroll(g.track_x + 4, g.track_y, 15.0).?;
    try t.expect(up == .set_output_volume);
    try t.expectApproxEqAbs(@as(f64, 0.85), up.set_output_volume, 1e-9);
    const dn = h.scroll(g.track_x + 4, g.track_y, -30.0).?;
    try t.expectApproxEqAbs(@as(f64, 0.75), dn.set_output_volume, 1e-9);
    try t.expect(h.scroll(5, 5, 15.0) == null);
}

test "cc-host: password prompt types, submits and cancels" {
    const t = std.testing;
    var h = Host.init(t.allocator);
    defer h.deinit();
    var cfg: schema.ShellConfig = .{};
    h.setSnapshot(.{});
    h.cfg = &cfg;
    h.relayout(0, false);
    try t.expect(!h.snap.wifi_password_prompt);
    h.promptPassword("Cafe WiFi");
    try t.expect(h.snap.wifi_password_prompt);
    try t.expectEqualStrings("Cafe WiFi", h.pendingSsid());
    try t.expect(h.key(0x0061, "a", true).? == .none);
    try t.expect(h.key(0x0062, "b", true).? == .none);
    try t.expectEqualStrings("ab", h.pendingPassword());
    try t.expect(h.key(0xff08, "", true).? == .none);
    try t.expectEqualStrings("a", h.pendingPassword());
    try t.expect(h.key(0xff0d, "", true).? == .submit_wifi_password);
    try t.expect(h.key(0xff1b, "", true).? == .cancel_wifi_password);
    try t.expect(!h.snap.wifi_password_prompt);
    // No prompt: keys are not ours (Esc still dismisses the popup).
    try t.expect(h.key(0x0061, "a", true) == null);
    try t.expect(h.key(0xff1b, "", true).? == .dismiss);
}
