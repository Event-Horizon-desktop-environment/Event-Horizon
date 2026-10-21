//! Pear popup host: the compact panel's layer surface. Owns the pear
//! `State`, an arena-duplicated snapshot (only what the compact layout
//! paints — no weather, no mixer), the computed `Layout`, and SHM paint.
//!
//! Fully separated from `controlcenter/host.zig`: paint and hit share one
//! layout here too, and slow verbs (wifi connect, bluetooth) run in threads
//! owned by the dock.

const std = @import("std");
const wl = @import("../../wl/c.zig").wl;
const layer = @import("../../wl/surface/layer.zig");
const shm_mod = @import("../../wl/buffer/shm.zig");
const cairo = shm_mod.cairo;
const pear_state = @import("state.zig");
const pear_layout = @import("layout.zig");
const pear_config = @import("config.zig");
const pear_data = @import("data.zig");
const pear_hit = @import("hit.zig");
const pear_paint = @import("paint.zig");
const cc_data = @import("../controlcenter/data.zig");
const ns = @import("../common/namespaces.zig");
const chrome = @import("../widgets/shared/chrome_colors.zig");
const schema = @import("../../config/schema.zig");

pub const popup_w: i32 = 360;
const gap_above_dock: f64 = 6.0;

pub const Action = union(enum) {
    none,
    open_networks_overlay,
    close_networks_overlay,
    toggle_wifi,
    select_network_row: i32,
    open_bt_overlay,
    close_bt_overlay,
    select_bluetooth_row: i32,
    forget_bluetooth_row: i32,
    submit_wifi_password,
    cancel_wifi_password,
    toggle_bluetooth_power,
    open_settings,
    toggle_dnd,
    run_device_link,
    toggle_night_color,
    toggle_color_scheme,
    run_camera,
    toggle_redeye,
    run_cmd1,
    run_cmd2,
    set_output_volume: f64,
    set_input_volume: f64,
    set_brightness: f64,
    toggle_output_mute,
    toggle_input_mute,
    toggle_output_devices,
    toggle_input_devices,
    select_output_device: i32,
    select_input_device: i32,
    media_button: usize,
    dismiss,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    shm: shm_mod.ShmBuffer,
    surface: layer.Surface = .{},
    arena: std.heap.ArenaAllocator,

    state: pear_state.State = .{},
    pconfig: pear_config.Config = .{},
    widget_id: []const u8 = "",
    snap: cc_data.Snapshot = .{},
    layout: pear_layout.Layout = .{},
    toggles: [7]pear_layout.Toggle = undefined,
    cfg: ?*const schema.ShellConfig = null,

    open: bool = false,
    buf_w: i32 = 0,
    buf_h: i32 = 0,
    popup_w_px: i32 = popup_w,
    /// Last placement, reused when the surface is recreated after a height
    /// change (overlay open/close, device panels).
    last_margin_left: i32 = 0,
    last_margin_bottom: i32 = 0,
    /// Wayland objects for surface recreation (borrowed from the dock; valid
    /// while the popup is open).
    compositor: ?*wl.wl_compositor = null,
    shell: ?*wl.zwlr_layer_shell_v1 = null,
    output: ?*wl.wl_output = null,

    dragging_vol: bool = false,
    dragging_in: bool = false,
    dragging_bri: bool = false,

    pw_ssid: [96]u8 = undefined,
    pw_ssid_len: usize = 0,
    pw: [128]u8 = undefined,
    pw_len: usize = 0,
    flags: Flags = .{},

    /// View flags owned by the dock (DND, night light, theme darkness,
    /// redeye, brightness). Set via `setFlags` before `refresh`; the
    /// snapshot itself is refreshed through `setSnapshot`.
    pub const Flags = struct {
        dnd: bool = false,
        night: bool = false,
        dark: bool = true,
        redeye: bool = false,
        brightness_pct: i32 = -1,
    };

    pub fn setFlags(self: *Self, f: Flags) void {
        self.flags = f;
    }

    fn view(self: *const Self) pear_data.View {
        return .{
            .snap = self.snap,
            .dnd_on = self.flags.dnd,
            .night_on = self.flags.night,
            .is_dark = self.flags.dark,
            .redeye_on = self.flags.redeye,
            .brightness_pct = self.flags.brightness_pct,
        };
    }

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
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.gpa);
        self.snap = .{};
        self.layout = .{};
        self.cfg = null;
        self.compositor = null;
        self.shell = null;
        self.output = null;
        self.open = false;
        self.buf_w = 0;
        self.buf_h = 0;
        self.dragging_vol = false;
        self.dragging_in = false;
        self.dragging_bri = false;
        self.pw_ssid_len = 0;
        self.pw_len = 0;
        if (self.widget_id.len > 0) {
            self.gpa.free(self.widget_id);
            self.widget_id = "";
        }
    }

    fn dupeOpt(arena: std.mem.Allocator, s: []const u8) []const u8 {
        if (s.len == 0) return "";
        return arena.dupe(u8, s) catch "";
    }

    /// Deep-copy what the compact layout paints (no weather, no mixer).
    pub fn setSnapshot(self: *Self, src: cc_data.Snapshot) void {
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
            .wifi_error = dupeOpt(a, src.wifi_error),
            .wifi_password_prompt = src.wifi_password_prompt,
            .bt_error = dupeOpt(a, src.bt_error),
        };
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
        self.snap = dst;
        self.syncPw();
    }

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
    }

    pub fn promptPassword(self: *Self, ssid: []const u8) void {
        const n = @min(ssid.len, self.pw_ssid.len);
        @memcpy(self.pw_ssid[0..n], ssid[0..n]);
        self.pw_ssid_len = n;
        self.pw_len = 0;
        self.state.networks_overlay = true;
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

    pub fn counts(self: *const Self) pear_layout.Counts {
        return .{
            .out_dev_total = @intCast(self.snap.out_devs.len),
            .in_dev_total = @intCast(self.snap.in_devs.len),
            .wifi_aps = @intCast(self.snap.aps.len),
            .bt_devices = @intCast(self.snap.bt_devs.len),
        };
    }

    pub fn relayout(self: *Self, ui_scale: f64, bri_available: bool) void {
        self.layout = pear_layout.computeLayout(
            @floatFromInt(self.popup_w_px),
            self.state.output_devices_expanded,
            self.state.input_devices_expanded,
            self.state.overlay(),
            self.pconfig,
            ui_scale,
            self.counts(),
            bri_available,
            &self.toggles,
        );
    }

    /// Open under the dock above the spawning slot. `width_px` is
    /// 360 × combined scale; margins position like the legacy host.
    pub fn openPear(
        self: *Self,
        compositor: ?*wl.wl_compositor,
        shell: ?*wl.zwlr_layer_shell_v1,
        output: ?*wl.wl_output,
        dock_w: i32,
        dock_h: i32,
        width_px: i32,
        margin_left: i32,
        margin_bottom: i32,
        cfg: *const schema.ShellConfig,
        widget_id: []const u8,
        snap: cc_data.Snapshot,
        ui_scale: f64,
        bri_available: bool,
    ) bool {
        if (dock_w <= 0 or dock_h <= 0) return false;
        if (width_px <= 0) return false;
        self.reset();
        self.cfg = cfg;
        self.pconfig = pear_config.load(cfg, widget_id);
        self.widget_id = self.gpa.dupe(u8, widget_id) catch "";
        self.setSnapshot(snap);
        if (!self.surface.create(compositor, shell, output, .overlay, ns.control_center)) {
            // A refused open leaves the host exactly as closed as it was.
            self.reset();
            return false;
        }
        self.popup_w_px = width_px;
        self.last_margin_left = margin_left;
        self.last_margin_bottom = margin_bottom;
        self.compositor = compositor;
        self.shell = shell;
        self.output = output;
        self.relayout(ui_scale, bri_available);
        if (!self.place()) {
            self.reset();
            return false;
        }
        self.open = true;
        return true;
    }

    /// (Re)create the layer surface at the current layout height. Used on
    /// open and whenever expansion changes the height: a layer surface cannot be resized, only recreated, and the
    /// compositor configures + repaints through the normal path after.
    pub fn place(self: *Self) bool {
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
        self.surface.setSize(@intCast(self.popup_w_px), @intCast(@as(i32, @intFromFloat(@ceil(self.layout.total_h)))));
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
        if (!self.shm.ensure(wlshm, "dock-pear", w * self.surface.scale, h * self.surface.scale)) return;
        self.buf_w = w;
        self.buf_h = h;
        self.popup_w_px = w;
        // ui_scale/bri unknown here; keep last layout (open sized it).
        self.refresh();
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
        // below draws in logical coordinates (buf_w/buf_h); cairo rasterises
        // at the buffer's native resolution so HiDPI stays crisp.
        cairo.cairo_identity_matrix(cr);
        const prsc: f64 = @floatFromInt(self.surface.scale);
        cairo.cairo_scale(cr, prsc, prsc);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        const st = self.state;
        var hm: pear_paint.Hov = .none;
        var hi: i32 = -1;
        switch (st.hover_target) {
            .none => {},
            .network_card => hm = .network_card,
            .bluetooth_card => hm = .bluetooth_card,
            .settings_row => hm = .settings_row,
            .dnd_card => hm = .dnd_card,
            .toggle => {
                hm = .toggle_card;
                hi = st.hover_toggle_idx;
            },
            .volume_slider => hm = .volume_slider,
            .volume_mute => hm = .volume_mute,
            .input_slider => hm = .input_slider,
            .input_mute => hm = .input_mute,
            .output_device_row => {
                hm = .output_device_row;
                hi = st.hover_row_idx;
            },
            .input_device_row => {
                hm = .input_device_row;
                hi = st.hover_row_idx;
            },
            .brightness_slider => hm = .brightness_slider,
            .media_prev => hm = .media_prev,
            .media_play_pause => hm = .media_play_pause,
            .media_next => hm = .media_next,
            .media_card => hm = .media_card,
            .networks_back => hm = .networks_back,
            .wifi_toggle => hm = .wifi_toggle,
            .network_row => {
                hm = .network_row;
                hi = st.hover_row_idx;
            },
            .bt_device_row => {
                hm = .bt_device_row;
                hi = st.hover_row_idx;
            },
        }
        pear_paint.paint(cr, @floatFromInt(self.popup_w_px), .{
            .cfg = cfg,
            .pear = self.pconfig,
            .overlay = self.state.overlay(),
            .hover_main = hm,
            .hover_idx = hi,
            .layout = self.layout,
            .view = self.view(),
        });
        cairo.cairo_restore(cr);
        self.surface.attach(self.shm.wlBuffer(), 0, 0);
        self.surface.setBufferScale(self.surface.scale);
        self.surface.damage(0, 0, self.buf_w, self.buf_h);
        self.shm.markBusy();
        self.surface.commit();
    }

    /// Pointer press inside the popup (surface coordinates).
    pub fn press(self: *Self, px: f64, py: f64) Action {
        const l = self.layout;
        const ov = self.state.overlay();
        if (ov != .none) {
            if (pear_hit.backHit(l, ov, px, py)) return switch (ov) {
                .bluetooth => .close_bt_overlay,
                else => .close_networks_overlay,
            };
            if (ov == .bluetooth) {
                if (pear_hit.btPowerToggleHit(l, ov, px, py)) return .toggle_bluetooth_power;
                if (pear_hit.btCtlHit(l, ov, px, py)) |hit| return switch (hit.ctl) {
                    .forget => .{ .forget_bluetooth_row = hit.idx },
                    .action => .{ .select_bluetooth_row = hit.idx },
                };
                return .none;
            }
            if (pear_hit.wifiToggleHit(l, ov, px, py)) return .toggle_wifi;
            if (pear_hit.networkRowHit(l, ov, px, py)) |i| return .{ .select_network_row = i };
            return .none;
        }
        if (pear_hit.volumeMuteHit(l, .none, px, py)) return .toggle_output_mute;
        if (pear_hit.inputMuteHit(l, .none, px, py)) return .toggle_input_mute;
        if (pear_hit.volumeSliderHit(l, .none, px, py)) |t| {
            self.dragging_vol = true;
            self.dragging_in = false;
            self.dragging_bri = false;
            self.state.vol_drag_active = true;
            self.state.vol_drag_t = t;
            self.state.in_drag_active = false;
            self.state.bri_drag_active = false;
            return .{ .set_output_volume = t };
        }
        if (pear_hit.inputSliderHit(l, .none, px, py)) |t| {
            self.dragging_in = true;
            self.dragging_vol = false;
            self.dragging_bri = false;
            self.state.in_drag_active = true;
            self.state.in_drag_t = t;
            self.state.vol_drag_active = false;
            self.state.bri_drag_active = false;
            return .{ .set_input_volume = t };
        }
        if (pear_hit.brightnessSliderHit(l, .none, px, py)) |t| {
            self.dragging_bri = true;
            self.dragging_vol = false;
            self.dragging_in = false;
            self.state.bri_drag_active = true;
            self.state.bri_drag_t = t;
            self.state.vol_drag_active = false;
            self.state.in_drag_active = false;
            return .{ .set_brightness = t };
        }
        if (pear_hit.networkCardHit(l, .none, px, py)) return .open_networks_overlay;
        // The bluetooth card opens its page (power lives in the page's
        // header checkbox, like the networks page's radio).
        if (pear_hit.bluetoothCardHit(l, .none, px, py)) return .open_bt_overlay;
        if (pear_hit.settingsRowHit(l, .none, px, py)) return .open_settings;
        if (pear_hit.dndCardHit(l, .none, px, py)) return .toggle_dnd;
        if (pear_hit.toggleHit(l, .none, px, py)) |i| {
            if (i < l.toggles.len) {
                return switch (l.toggles[i]) {
                    .device_link => .run_device_link,
                    .night_color => .toggle_night_color,
                    .color_scheme => .toggle_color_scheme,
                    .camera => .run_camera,
                    .redeye => .toggle_redeye,
                    .cmd1 => .run_cmd1,
                    .cmd2 => .run_cmd2,
                };
            }
        }
        if (pear_hit.outputDeviceRowHit(l, .none, px, py)) |i| return .{ .select_output_device = i };
        if (pear_hit.inputDeviceRowHit(l, .none, px, py)) |i| return .{ .select_input_device = i };
        // Card bodies outside slider/mute toggle the device switchers.
        if (l.show_volume and pear_hit.volumeRowHit(l, .none, px, py)) return .toggle_output_devices;
        if (l.show_input and pear_hit.inputRowHit(l, .none, px, py)) return .toggle_input_devices;
        if (pear_hit.mediaButtonHit(l, .none, px, py)) |i| return .{ .media_button = i };
        return .none;
    }

    pub fn dragTo(self: *Self, px: f64) ?Action {
        const l = self.layout;
        if (self.dragging_vol) {
            const g = pear_hit.volumeSliderGeom(l);
            const t = pear_hit.layoutSliderT(g.track_x, g.track_w, px);
            self.state.vol_drag_t = t;
            return .{ .set_output_volume = t };
        }
        if (self.dragging_in) {
            const g = pear_hit.inputSliderGeom(l);
            const t = pear_hit.layoutSliderT(g.track_x, g.track_w, px);
            self.state.in_drag_t = t;
            return .{ .set_input_volume = t };
        }
        if (self.dragging_bri) {
            const g = pear_hit.brightnessSliderGeom(l);
            const t = pear_hit.layoutSliderT(g.track_x, g.track_w, px);
            self.state.bri_drag_t = t;
            return .{ .set_brightness = t };
        }
        return null;
    }

    pub fn release(self: *Self) void {
        self.dragging_vol = false;
        self.dragging_in = false;
        self.dragging_bri = false;
        self.state.resetDrag();
    }

    /// Hover tracking. Returns true when a repaint is needed.
    pub fn motion(self: *Self, px: f64, py: f64) bool {
        if (self.dragging_vol or self.dragging_in or self.dragging_bri) return true;
        const l = self.layout;
        const ov = self.state.overlay();
        const old_m = self.state.hover_target;
        const old_r = self.state.hover_row_idx;
        const old_t = self.state.hover_toggle_idx;
        self.state.clearHover();
        if (ov != .none) {
            if (pear_hit.backHit(l, ov, px, py)) {
                self.state.hover_target = .networks_back;
            } else if (ov == .bluetooth) {
                if (pear_hit.btPowerToggleHit(l, ov, px, py)) {
                    self.state.hover_target = .wifi_toggle;
                } else if (pear_hit.btCtlHit(l, ov, px, py)) |hit| {
                    self.state.hover_target = .bt_device_row;
                    self.state.hover_row_idx = hit.idx;
                }
            } else if (pear_hit.wifiToggleHit(l, ov, px, py)) {
                self.state.hover_target = .wifi_toggle;
            } else if (pear_hit.networkRowHit(l, ov, px, py)) |i| {
                self.state.hover_target = .network_row;
                self.state.hover_row_idx = i;
            }
            return old_m != self.state.hover_target or old_r != self.state.hover_row_idx;
        }
        if (pear_hit.networkCardHit(l, .none, px, py)) {
            self.state.hover_target = .network_card;
        } else if (pear_hit.bluetoothCardHit(l, .none, px, py)) {
            self.state.hover_target = .bluetooth_card;
        } else if (pear_hit.settingsRowHit(l, .none, px, py)) {
            self.state.hover_target = .settings_row;
        } else if (pear_hit.dndCardHit(l, .none, px, py)) {
            self.state.hover_target = .dnd_card;
        } else if (pear_hit.toggleHit(l, .none, px, py)) |i| {
            self.state.hover_target = .toggle;
            self.state.hover_toggle_idx = @intCast(i);
        } else if (pear_hit.volumeMuteHit(l, .none, px, py)) {
            self.state.hover_target = .volume_mute;
        } else if (pear_hit.volumeSliderHit(l, .none, px, py) != null) {
            self.state.hover_target = .volume_slider;
        } else if (pear_hit.inputMuteHit(l, .none, px, py)) {
            self.state.hover_target = .input_mute;
        } else if (pear_hit.inputSliderHit(l, .none, px, py) != null) {
            self.state.hover_target = .input_slider;
        } else if (pear_hit.brightnessSliderHit(l, .none, px, py) != null) {
            self.state.hover_target = .brightness_slider;
        } else if (pear_hit.outputDeviceRowHit(l, .none, px, py)) |i| {
            self.state.hover_target = .output_device_row;
            self.state.hover_row_idx = i;
        } else if (pear_hit.inputDeviceRowHit(l, .none, px, py)) |i| {
            self.state.hover_target = .input_device_row;
            self.state.hover_row_idx = i;
        } else if (pear_hit.mediaButtonHit(l, .none, px, py)) |i| {
            self.state.hover_target = switch (i) {
                0 => .media_prev,
                1 => .media_play_pause,
                else => .media_next,
            };
        }
        return old_m != self.state.hover_target or old_r != self.state.hover_row_idx or old_t != self.state.hover_toggle_idx;
    }

    /// Keyboard for the overlay password prompt. Same keys as legacy.
    pub fn key(self: *Self, sym: u32, txt: []const u8, pressed: bool) ?Action {
        if (!pressed) return null;
        if (sym == 0xff1b) {
            if (self.pw_ssid_len > 0) {
                self.cancelPassword();
                return .cancel_wifi_password;
            }
            return .dismiss;
        }
        if (self.pw_ssid_len == 0) return null;
        if (sym == 0xff0d or sym == 0xff8d) return .submit_wifi_password;
        if (sym == 0xff08) {
            if (self.pw_len > 0) {
                self.pw_len -= 1;
                while (self.pw_len > 0 and (self.pw[self.pw_len] & 0xC0) == 0x80) self.pw_len -= 1;
                self.syncPw();
            }
            return .none;
        }
        if (txt.len > 0 and self.pw_len < self.pw.len) {
            const take = @min(txt.len, self.pw.len - self.pw_len);
            @memcpy(self.pw[self.pw_len .. self.pw_len + take], txt[0..take]);
            self.pw_len += take;
            self.syncPw();
            return .none;
        }
        return null;
    }

    /// Scroll over a slider row nudges it ±5%.
    pub fn scroll(self: *Self, px: f64, py: f64, delta_px: f64) ?Action {
        if (delta_px == 0) return null;
        const step: f64 = if (delta_px > 0) 0.05 else -0.05;
        const l = self.layout;
        // Scroll never reaches the overlay pages (they have no sliders).
        const ov = self.state.overlay();
        if (pear_hit.volumeSliderHit(l, ov, px, py) != null) {
            const cur = volT(self.snap.out.volume_pct, self.snap.out.fill_t_override);
            const t = std.math.clamp(cur + step, 0.0, 1.0);
            self.state.vol_drag_t = t;
            return .{ .set_output_volume = t };
        }
        if (pear_hit.inputSliderHit(l, ov, px, py) != null) {
            const cur = volT(self.snap.in.volume_pct, self.snap.in.fill_t_override);
            const t = std.math.clamp(cur + step, 0.0, 1.0);
            self.state.in_drag_t = t;
            return .{ .set_input_volume = t };
        }
        if (pear_hit.brightnessSliderHit(l, ov, px, py) != null) {
            const cur: f64 = 0.5;
            const t = std.math.clamp(cur + step, 0.0, 1.0);
            self.state.bri_drag_t = t;
            return .{ .set_brightness = t };
        }
        return null;
    }

    fn volT(pct: i32, fill_override: f64) f64 {
        if (fill_override >= 0.0 and fill_override <= 1.0) return fill_override;
        return std.math.clamp(@as(f64, @floatFromInt(pct)) / 100.0, 0.0, 1.0);
    }
};

test "pear-host: cards, toggles and overlay route to actions" {
    const t = std.testing;
    var h = Host.init(t.allocator);
    defer h.deinit();
    var cfg: schema.ShellConfig = .{};
    try t.expect(!h.openPear(null, null, null, 800, 60, 360, 0, 0, &cfg, "pear_center", .{}, 1.0, false));
    try t.expect(!h.open);

    h.setSnapshot(.{
        .net = .{ .connected = true, .ethernet = true, .iface = "eth0" },
        .out = .{ .volume_pct = 80, .device_name = "Speakers" },
        .in = .{ .volume_pct = 60, .device_name = "Mic" },
    });
    h.cfg = &cfg;
    h.pconfig = pear_config.load(&cfg, "pear_center");
    h.popup_w_px = 360;
    h.relayout(1.0, false);
    try t.expect(h.press(30, 30) == .open_networks_overlay);
    // Toggles row: night_color is first with defaults.
    const tx = pear_layout.toggleX(h.layout, 0) + 4;
    try t.expect(h.press(tx, h.layout.tog_y + 4) == .toggle_night_color);
    const g = pear_hit.volumeSliderGeom(h.layout);
    const a = h.press(g.track_x + 10, g.track_y);
    try t.expect(a == .set_output_volume);
    h.release();
    // Overlay routing.
    h.state.networks_overlay = true;
    h.relayout(1.0, false);
    try t.expect(h.press(h.layout.pad + 4, h.layout.pad + 4) == .close_networks_overlay);
    // The bluetooth card opens its own page; its header checkbox is the
    // power and the back arrow leaves the page.
    h.state.networks_overlay = false;
    h.relayout(1.0, false);
    try t.expect(h.press(h.layout.bt_x + 10, h.layout.row1_y + 10) == .open_bt_overlay);
    h.state.bt_overlay = true;
    h.relayout(1.0, false);
    try t.expect(h.press(h.layout.pad + 4, h.layout.pad + 4) == .close_bt_overlay);
    try t.expect(h.press(h.layout.w - h.layout.pad - 20, h.layout.pad + 10) == .toggle_bluetooth_power);
    // Device rows come straight off the snapshot (empty here: the page body
    // says so, and no row action is produced).
    try t.expect(h.press(h.layout.pad + 20, h.layout.pad + 60) == .none);
    h.state.bt_overlay = false;
}

test "pear-host: brightness scroll and password keys" {
    const t = std.testing;
    var h = Host.init(t.allocator);
    defer h.deinit();
    var cfg: schema.ShellConfig = .{};
    h.setSnapshot(.{});
    h.cfg = &cfg;
    h.pconfig = pear_config.load(&cfg, "pear_center");
    h.popup_w_px = 360;
    h.relayout(1.0, true);
    try t.expect(h.layout.show_brightness);
    const g = pear_hit.brightnessSliderGeom(h.layout);
    const up = h.scroll(g.track_x + 4, g.track_y, 20.0).?;
    try t.expect(up == .set_brightness);
    h.promptPassword("Cafe");
    try t.expect(h.snap.wifi_password_prompt);
    try t.expect(h.key(0x0078, "x", true).? == .none);
    try t.expectEqualStrings("x", h.pendingPassword());
    try t.expect(h.key(0xff0d, "", true).? == .submit_wifi_password);
}
