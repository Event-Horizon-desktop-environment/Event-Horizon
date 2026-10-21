const std = @import("std");
const rows_mod = @import("rows.zig");
const mon = @import("monitors_state.zig");
const Field = rows_mod.Field;

// Monitors page — the live card list the Monitors tab paints.
//
// Form geometry builds per frame from the row list (which rows exist depends on the compositor and the
// selected output's capabilities). Here the same decision is made once, up
// front, into `Page`: a fixed set of row/card buffers that `ui_content` hands
// to the generic renderer. Paint, hit-test and scroll height all read the
// same buffers, exactly like the static pages in `rows_*.zig`.
//
// Every value lives in `monitors_state.State` (strings on the `MonitorRow`),
// not in `Settings`; `ui_content.Content` routes the `monitor_*` Field
// variants through `fieldInt` / `setFieldInt` and friends below.

pub const max_cards: usize = 8;
pub const max_rows: usize = 32;
/// Bump arena for combo option strings + the slices that point at them.
pub const max_opts: usize = 128;
pub const opt_cap: usize = 24;

pub const toolbar_buttons = [_][]const u8{ "Refresh", "Restart portals", "Apply", "Revert" };

/// Indices into `toolbar_buttons`, so the window's action dispatch names the
/// button rather than repeating a bare number.
pub const tool_refresh: usize = 0;
pub const tool_portals: usize = 1;
pub const tool_apply: usize = 2;
pub const tool_revert: usize = 3;

pub const canvas_aux_buttons = [_][]const u8{ "Center view", "Align top" };

pub const help_text = "Drag outputs on the canvas. Apply writes config and reloads the compositor.";

// Transform/orientation label tables.
pub const tf_labels = [_][]const u8{ "0° normal", "90°", "180°", "270°", "Flip", "Flip 90°", "Flip 180°", "Flip 270°" };
pub const tri_labels = [_][]const u8{ "Auto", "Force on", "Force off" };
pub const eotf_labels = [_][]const u8{ "Follow", "sRGB", "Gamma 2.2" };
pub const bitdepth_labels = [_][]const u8{ "Default", "10-bit" };
const vrr_labels_short = [_][]const u8{ "Off", "On" };
const vrr_labels_full = [_][]const u8{ "Off", "On", "On-demand" };

pub const Page = struct {
    cards: [max_cards]rows_mod.Card = undefined,
    cards_len: usize = 0,
    row_buf: [max_rows]rows_mod.Row = undefined,
    rows_len: usize = 0,
    opts_buf: [max_opts][opt_cap]u8 = undefined,
    opt_slices: [max_opts][]const u8 = undefined,
    opts_len: usize = 0,

    pub fn cardsSlice(self: *const Page) []const rows_mod.Card {
        return self.cards[0..self.cards_len];
    }

    /// Copy `s` into the arena and hand back a stable slice.
    fn pushStr(self: *Page, s: []const u8) []const u8 {
        if (self.opts_len >= max_opts) return "";
        const i = self.opts_len;
        self.opts_len += 1;
        const n = @min(s.len, opt_cap);
        @memcpy(self.opts_buf[i][0..n], s[0..n]);
        self.opt_slices[i] = self.opts_buf[i][0..n];
        return self.opt_slices[i];
    }

    /// Reserve `n` arena entries; the returned slice is stable for the frame.
    fn reserveOpts(self: *Page, n: usize) [][]const u8 {
        const start = self.opts_len;
        const take = @min(n, max_opts -| start);
        self.opts_len += take;
        return self.opt_slices[start .. start + take];
    }

    fn pushRow(self: *Page, r: rows_mod.Row) void {
        if (self.rows_len >= max_rows) return;
        self.row_buf[self.rows_len] = r;
        self.rows_len += 1;
    }

    fn pushCard(self: *Page, title: []const u8, subtitle: []const u8, first_row: usize) void {
        if (self.cards_len >= max_cards) return;
        self.cards[self.cards_len] = .{
            .title = title,
            .subtitle = subtitle,
            .rows = self.row_buf[first_row..self.rows_len],
        };
        self.cards_len += 1;
    }

    /// Rebuild the card list from `s` — one page per frame.
    pub fn build(self: *Page, s: *mon.State) void {
        self.cards_len = 0;
        self.rows_len = 0;
        self.opts_len = 0;

        // Toolbar + canvas + pills card (toolbar at kContentTop+56, the
        // arrange canvas under it, the output pills under that).
        var r = self.rows_len;
        self.pushRow(.{ .toolbar = .{ .buttons = &toolbar_buttons } });
        self.pushRow(.{ .info = help_text });
        self.pushRow(.{ .canvas = .{} });
        self.pushPills(s);
        self.pushCard("", "", r);
        const sel: usize = @min(s.selected, s.outputs_len -| 1);
        if (s.outputs_len == 0) {
            // No outputs (unsupported compositor, no hyprctl, empty config):
            // one card carrying the status line instead of the whole form.
            r = self.rows_len;
            self.pushRow(.{ .info = if (s.status.empty()) "No outputs reported by the compositor." else s.status.slice() });
            self.pushCard("Monitors", "No output is available to configure.", r);
            return;
        }

        const row = &s.outputs[sel];
        const caps = s.capsForIdx(sel);

        // Header: output name on the title band, enable switch as a row.
        r = self.rows_len;
        self.pushRow(.{ .toggle = .{
            .label = "Enabled",
            .desc = "Turn this output on or off.",
            .field = .monitor_enabled,
        } });
        self.pushCard(row.name.slice(), "Enable or disable this output.", r);

        // Display: resolution, refresh rate, VRR.
        const show_vrr = s.kind == .hyprland or s.kind == .mango or
            (s.kind == .niri and caps != null and caps.?.vrr_capable);
        r = self.rows_len;
        {
            var res_opts = self.reserveOpts(mon.max_res);
            var res_n: usize = 0;
            if (caps) |c| {
                var i: usize = 0;
                while (i < c.n_res and res_n < res_opts.len) : (i += 1) {
                    res_opts[res_n] = self.pushStr(c.resolution(i));
                    res_n += 1;
                }
            }
            if (res_n == 0) {
                res_opts[0] = self.pushStr(if (row.resolution.empty()) "—" else row.resolution.slice());
                res_n = 1;
            }
            self.pushRow(.{ .combo = .{
                .label = "Resolution",
                .desc = "Mode the output drives.",
                .field = .monitor_mode_idx,
                .options = res_opts[0..res_n],
            } });

            var hz_vals = self.reserveOpts(mon.max_hz);
            var hz_labs = self.reserveOpts(mon.max_hz);
            var hz_n: usize = 0;
            if (caps) |c| {
                const ri = c.findResolution(row.resolution.slice()) orelse 0;
                const list = c.hzList(ri);
                var i: usize = 0;
                while (i < list.len and hz_n < hz_vals.len) : (i += 1) {
                    var b: [24]u8 = undefined;
                    hz_vals[hz_n] = self.pushStr(mon.fmtG(&b, list[i]));
                    var lb: [32]u8 = undefined;
                    const lab = std.fmt.bufPrint(&lb, "{s} Hz", .{hz_vals[hz_n]}) catch "";
                    hz_labs[hz_n] = self.pushStr(lab);
                    hz_n += 1;
                }
            }
            if (hz_n == 0) {
                hz_vals[0] = self.pushStr(if (row.refresh_rate.empty()) "—" else row.refresh_rate.slice());
                hz_labs[0] = hz_vals[0];
                hz_n = 1;
            }
            self.pushRow(.{ .combo = .{
                .label = "Refresh rate",
                .desc = "Timing for the selected resolution.",
                .field = .monitor_refresh_idx,
                .options = hz_vals[0..hz_n],
                .labels = hz_labs[0..hz_n],
            } });
            if (show_vrr) {
                const opts: []const []const u8 = if (s.kind == .mango) &vrr_labels_short else &vrr_labels_full;
                self.pushRow(.{ .combo = .{
                    .label = "VRR",
                    .desc = "Variable refresh rate range for the output.",
                    .field = .monitor_vrr_idx,
                    .options = opts,
                } });
            }
        }
        self.pushCard("Display", "Mode and timing for the selected output.", r);

        // Scale & transform.
        r = self.rows_len;
        self.pushRow(.{ .slider = .{
            .label = "Scale",
            .desc = "Fractional scaling applied to the output.",
            .field = .monitor_scale_pct,
            .min = 100,
            .max = 200,
            .fmt = .scale,
        } });
        self.pushRow(.{ .combo = .{
            .label = "Transform",
            .desc = "Rotation and flip applied to the output.",
            .field = .monitor_transform_idx,
            .options = &tf_labels,
        } });
        self.pushCard("Scale & transform", "Fractional scaling and rotation for the output.", r);

        // Color: bit depth (Hyprland/Niri), CM preset (Hyprland), ICC profile.
        const show_bit = s.supportsBitdepthUi() and s.kind != .mango;
        const show_cm = s.supportsColorHdrUi();
        if (show_bit or show_cm) {
            r = self.rows_len;
            if (show_bit) {
                self.pushRow(.{ .combo = .{
                    .label = "Bit depth",
                    .desc = "Panel bit depth. 10-bit needs compositor support.",
                    .field = .monitor_bitdepth_idx,
                    .options = &bitdepth_labels,
                } });
            }
            if (show_cm) {
                self.pushRow(.{ .combo = .{
                    .label = "Color management",
                    .desc = "Colour space preset applied to the output.",
                    .field = .monitor_cm_idx,
                    .options = &mon.cm_labels,
                } });
            }
            self.pushRow(.{ .info = iccInfo(row) });
            self.pushCard("Color", "Bit depth, colour space and ICC profile.", r);
        }

        // HDR (+ the wide/EOTF strip when the full panel does not apply).
        if (hdrPanelVisible(s, row, caps)) {
            r = self.rows_len;
            self.pushRow(.{ .combo = .{
                .label = "HDR support",
                .desc = "Advertise HDR to clients on this output.",
                .field = .monitor_hdr_support_idx,
                .options = &tri_labels,
            } });
            self.pushRow(.{ .combo = .{
                .label = "Wide color gamut",
                .desc = "Advertise a wide colour gamut to clients.",
                .field = .monitor_wide_idx,
                .options = &tri_labels,
            } });
            self.pushRow(.{ .combo = .{
                .label = "SDR EOTF",
                .desc = "Transfer function used for SDR content on an HDR output.",
                .field = .monitor_eotf_idx,
                .options = &eotf_labels,
            } });
            self.pushRow(.{ .slider = .{
                .label = "SDR brightness",
                .field = .monitor_sdr_brightness,
                .min = 10,
                .max = 200,
                .fmt = .div100,
            } });
            self.pushRow(.{ .slider = .{
                .label = "SDR saturation",
                .field = .monitor_sdr_saturation,
                .min = 0,
                .max = 200,
                .fmt = .div100,
            } });
            self.pushCard("HDR", "HDR signalling and the SDR fallback curve.", r);

            r = self.rows_len;
            self.pushRow(.{ .slider = .{ .label = "SDR min luminance", .field = .monitor_sdr_min_lum, .min = 0, .max = 100, .fmt = .div10000 } });
            self.pushRow(.{ .slider = .{ .label = "SDR max luminance", .field = .monitor_sdr_max_lum, .min = 80, .max = 400, .fmt = .nits } });
            self.pushRow(.{ .slider = .{ .label = "Min luminance (HDR)", .field = .monitor_hdr_min_lum, .min = 0, .max = 100, .fmt = .div10000 } });
            self.pushRow(.{ .slider = .{ .label = "Max luminance", .field = .monitor_hdr_max_lum, .min = 0, .max = 2000, .fmt = .nits } });
            self.pushRow(.{ .slider = .{ .label = "Max average luminance", .field = .monitor_hdr_avg_lum, .min = 0, .max = 2000, .fmt = .nits } });
            self.pushCard("Luminance", "Panel luminance limits reported to clients.", r);
        } else if (wideEotfStripVisible(s, row, caps)) {
            r = self.rows_len;
            self.pushRow(.{ .combo = .{
                .label = "Wide color gamut",
                .desc = "Advertise a wide colour gamut to clients.",
                .field = .monitor_wide_idx,
                .options = &tri_labels,
            } });
            self.pushRow(.{ .combo = .{
                .label = "SDR EOTF",
                .desc = "Transfer function used for SDR content.",
                .field = .monitor_eotf_idx,
                .options = &eotf_labels,
            } });
            self.pushCard("Color", "Wide gamut and the SDR transfer function.", r);
        }

        // Status line (drawn under the form).
        r = self.rows_len;
        self.pushRow(.{ .info = statusLine(s) });
        self.pushCard("", "", r);
    }

    fn pushPills(self: *Page, s: *mon.State) void {
        const names = self.reserveOpts(mon.max_outputs);
        var n: usize = 0;
        for (s.outputs[0..s.outputs_len]) |*o| {
            if (n >= names.len) break;
            names[n] = o.name.slice();
            n += 1;
        }
        self.pushRow(.{ .pills = .{ .pills = names[0..n] } });
    }
};

fn iccInfo(row: *const mon.MonitorRow) []const u8 {
    if (row.icc.empty()) return "Color profile: none.";
    const path = row.icc.slice();
    const base = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const name = if (std.mem.lastIndexOfScalar(u8, path, '/') != null) path[base + 1 ..] else path;
    return name; // owned by the row's buffer; stable for the frame
}

/// The status strip: the state's own message, else the dirty marker.
fn statusLine(s: *mon.State) []const u8 {
    if (!s.status.empty()) return s.status.slice();
    if (s.dirty) return "Unsaved changes — press Apply to write the config, or Revert to discard them.";
    return "Configuration matches the compositor.";
}

/// Whether the HDR panel shows.
pub fn hdrPanelVisible(s: *mon.State, row: *const mon.MonitorRow, caps: ?*const mon.OutputCaps) bool {
    if (!s.supportsColorHdrUi()) return false;
    if (row.disabled) return false;
    if (caps) |c| if (c.hdr_hint) return true;
    if (row.cm.eql("hdr") or row.cm.eql("hdredid")) return true;
    return row.supports_hdr.eql("1");
}

/// Whether the wide-EOTF strip shows.
pub fn wideEotfStripVisible(s: *mon.State, row: *const mon.MonitorRow, caps: ?*const mon.OutputCaps) bool {
    if (!s.supportsColorHdrUi()) return false;
    if (row.disabled) return false;
    if (hdrPanelVisible(s, row, caps)) return false;
    return row.cm.eql("srgb");
}

// Value accessors — the Field routing the generic renderer asks for.

/// Scale ticks from a 0.25..8 parse, then the UI's 1.0..2.0 window.
pub fn scaleTicks(row: *const mon.MonitorRow) i32 {
    const v = mon_tab_clamp_scale(monitorsParseScale(row.scale.slice()));
    return @intFromFloat(@round(v * 100.0));
}

fn monitorsParseScale(s: []const u8) f64 {
    const v = std.fmt.parseFloat(f64, s) catch return 1.0;
    if (!std.math.isFinite(v)) return 1.0;
    return std.math.clamp(v, 0.25, 8.0);
}

fn mon_tab_clamp_scale(v: f64) f64 {
    return std.math.clamp(v, 1.0, 2.0);
}

fn parseFloatD(s: []const u8, dflt: f64) f64 {
    const v = std.fmt.parseFloat(f64, s) catch return dflt;
    return if (std.math.isFinite(v)) v else dflt;
}

fn parseIntD(s: []const u8, dflt: i32) i32 {
    return std.fmt.parseInt(i32, s, 10) catch dflt;
}

fn setG(dest: anytype, v: f64) void {
    var b: [32]u8 = undefined;
    dest.set(mon.fmtG(&b, v));
}

fn setI(dest: anytype, v: i32) void {
    var b: [16]u8 = undefined;
    dest.set(std.fmt.bufPrint(&b, "{d}", .{v}) catch "");
}

/// Tri-state auto field: option 0 clears the key (compositor
/// default), 1 forces on, 2 forces off.
fn setTriAuto(dest: anytype, v: i32) void {
    switch (std.math.clamp(v, 0, 2)) {
        1 => dest.set("1"),
        2 => dest.set("-1"),
        else => dest.clear(),
    }
}

/// Tri-state selector. Takes the row's `Str` (its `empty`/
/// `eql` checks), not a raw slice.
pub fn triAutoSel(s: anytype) usize {
    if (s.empty() or s.eql("0")) return 0;
    if (s.eql("1")) return 1;
    return 2;
}

/// SDR-EOTF selector.
pub fn sdrEotfSel(s: anytype) usize {
    if (s.empty()) return 0;
    return @intCast(std.math.clamp(parseIntD(s.slice(), 0), 0, 2));
}

fn selectedRow(s: *mon.State) ?*mon.MonitorRow {
    if (s.outputs_len == 0) return null;
    return &s.outputs[@min(s.selected, s.outputs_len - 1)];
}

pub fn isMonitorField(f: Field) bool {
    return switch (f) {
        .monitor_sel,
        .monitor_enabled,
        .monitor_mode_idx,
        .monitor_refresh_idx,
        .monitor_scale_pct,
        .monitor_transform_idx,
        .monitor_vrr_idx,
        .monitor_bitdepth_idx,
        .monitor_cm_idx,
        .monitor_hdr_support_idx,
        .monitor_wide_idx,
        .monitor_eotf_idx,
        .monitor_sdr_brightness,
        .monitor_sdr_saturation,
        .monitor_sdr_min_lum,
        .monitor_sdr_max_lum,
        .monitor_hdr_min_lum,
        .monitor_hdr_max_lum,
        .monitor_hdr_avg_lum,
        => true,
        else => false,
    };
}

pub fn fieldBool(s: *mon.State, f: Field) bool {
    const row = selectedRow(s) orelse return false;
    return switch (f) {
        .monitor_enabled => !row.disabled,
        else => false,
    };
}

pub fn setFieldBool(s: *mon.State, f: Field, v: bool) void {
    const row = selectedRow(s) orelse return;
    switch (f) {
        .monitor_enabled => {
            row.disabled = !v;
            s.dirty = true;
        },
        else => {},
    }
}

/// Slider value as one int per field.
pub fn fieldInt(s: *mon.State, f: Field) i32 {
    if (f == .monitor_sel) return @intCast(@min(s.selected, s.outputs_len -| 1));
    const row = selectedRow(s) orelse return 0;
    return switch (f) {
        .monitor_mode_idx => @intCast(resIx(s, row)),
        .monitor_refresh_idx => @intCast(hzIx(s, row)),
        .monitor_scale_pct => scaleTicks(row),
        .monitor_transform_idx => @intCast(std.math.clamp(parseIntD(row.transform.slice(), 0), 0, 7)),
        .monitor_vrr_idx => @intCast(std.math.clamp(parseIntD(row.vrr.slice(), 0), 0, vrrMax(s))),
        .monitor_bitdepth_idx => @intFromBool(row.bitdepth.eql("10")),
        .monitor_cm_idx => @intCast(cmIx(row)),
        .monitor_hdr_support_idx => @intCast(triAutoSel(row.supports_hdr)),
        .monitor_wide_idx => @intCast(triAutoSel(row.supports_wide_color)),
        .monitor_eotf_idx => @intCast(sdrEotfSel(row.sdr_eotf)),
        .monitor_sdr_brightness => @intFromFloat(@round(std.math.clamp(parseFloatD(row.sdrbrightness.slice(), 1.0), 0.1, 2.0) * 100.0)),
        .monitor_sdr_saturation => @intFromFloat(@round(std.math.clamp(parseFloatD(row.sdrsaturation.slice(), 1.0), 0.0, 2.0) * 100.0)),
        .monitor_sdr_min_lum => @intFromFloat(@round(std.math.clamp(parseFloatD(row.sdr_min_luminance.slice(), 0.0), 0.0, 0.01) * 10000.0)),
        .monitor_sdr_max_lum => std.math.clamp(parseIntD(row.sdr_max_luminance.slice(), 200), 80, 400),
        .monitor_hdr_min_lum => @intFromFloat(@round(std.math.clamp(parseFloatD(row.min_luminance.slice(), 0.0), 0.0, 0.01) * 10000.0)),
        .monitor_hdr_max_lum => std.math.clamp(parseIntD(row.max_luminance.slice(), 600), 0, 2000),
        .monitor_hdr_avg_lum => std.math.clamp(parseIntD(row.max_avg_luminance.slice(), 400), 0, 2000),
        else => 0,
    };
}

pub fn setFieldInt(s: *mon.State, f: Field, v: i32) void {
    if (f == .monitor_sel) {
        s.selected = if (s.outputs_len == 0) 0 else @intCast(std.math.clamp(v, 0, @as(i32, @intCast(s.outputs_len - 1))));
        return;
    }
    const row = selectedRow(s) orelse return;
    switch (f) {
        .monitor_scale_pct => setG(&row.scale, @as(f64, @floatFromInt(std.math.clamp(v, 100, 200))) / 100.0),
        .monitor_transform_idx => setI(&row.transform, std.math.clamp(v, 0, 7)),
        .monitor_vrr_idx => setI(&row.vrr, std.math.clamp(v, 0, vrrMax(s))),
        .monitor_bitdepth_idx => row.bitdepth.set(if (v != 0) "10" else ""),
        // Tri-auto ("Auto"/"Force on"/"Force off") and the SDR EOTF picker
        // write their own magic strings, not the option index.
        .monitor_hdr_support_idx => setTriAuto(&row.supports_hdr, v),
        .monitor_wide_idx => setTriAuto(&row.supports_wide_color, v),
        .monitor_eotf_idx => row.sdr_eotf.set(switch (std.math.clamp(v, 0, 2)) {
            0 => "",
            1 => "1",
            else => "2",
        }),
        .monitor_sdr_brightness => setG(&row.sdrbrightness, @as(f64, @floatFromInt(std.math.clamp(v, 10, 200))) / 100.0),
        .monitor_sdr_saturation => setG(&row.sdrsaturation, @as(f64, @floatFromInt(std.math.clamp(v, 0, 200))) / 100.0),
        .monitor_sdr_min_lum => setG(&row.sdr_min_luminance, @as(f64, @floatFromInt(std.math.clamp(v, 0, 100))) / 10000.0),
        .monitor_sdr_max_lum => setI(&row.sdr_max_luminance, std.math.clamp(v, 80, 400)),
        .monitor_hdr_min_lum => setG(&row.min_luminance, @as(f64, @floatFromInt(std.math.clamp(v, 0, 100))) / 10000.0),
        .monitor_hdr_max_lum => setI(&row.max_luminance, std.math.clamp(v, 0, 2000)),
        .monitor_hdr_avg_lum => setI(&row.max_avg_luminance, std.math.clamp(v, 0, 2000)),
        else => return,
    }
    s.dirty = true;
}

fn vrrMax(s: *mon.State) i32 {
    return if (s.kind == .mango) 1 else 2;
}

fn resIx(s: *mon.State, row: *const mon.MonitorRow) usize {
    const caps = s.capsFor(row.name.slice()) orelse return 0;
    return caps.findResolution(row.resolution.slice()) orelse 0;
}

fn hzIx(s: *mon.State, row: *const mon.MonitorRow) usize {
    const caps = s.capsFor(row.name.slice()) orelse return 0;
    const ri = caps.findResolution(row.resolution.slice()) orelse 0;
    const list = caps.hzList(ri);
    for (list, 0..) |hz, i| {
        var b: [24]u8 = undefined;
        if (std.mem.eql(u8, mon.fmtG(&b, hz), row.refresh_rate.slice())) return i;
    }
    return 0;
}

fn cmIx(row: *const mon.MonitorRow) usize {
    for (mon.cm_labels, 0..) |k, i| {
        if (row.cm.eql(k)) return i;
    }
    return 0;
}

pub fn fieldComboIndex(s: *mon.State, f: Field, options: []const []const u8) usize {
    if (options.len == 0) return 0;
    if (f == .monitor_mode_idx or f == .monitor_refresh_idx) {
        const row = selectedRow(s) orelse return 0;
        const cur = if (f == .monitor_mode_idx) row.resolution.slice() else row.refresh_rate.slice();
        for (options, 0..) |o, i| {
            if (std.mem.eql(u8, o, cur)) return i;
        }
        return 0;
    }
    const v = fieldInt(s, f);
    if (v < 0 or v >= options.len) return 0;
    return @intCast(v);
}

pub fn setFieldComboIndex(s: *mon.State, f: Field, options: []const []const u8, ix: usize) void {
    if (ix >= options.len) return;
    const row = selectedRow(s) orelse return;
    switch (f) {
        // `monitors_pick_resolution_ix`: the mode changes and the refresh
        // rate snaps to the first rate that resolution offers.
        .monitor_mode_idx => {
            row.resolution.set(options[ix]);
            if (s.capsFor(row.name.slice())) |caps| {
                const ri = caps.findResolution(options[ix]) orelse 0;
                const list = caps.hzList(ri);
                if (list.len > 0) {
                    var b: [24]u8 = undefined;
                    row.refresh_rate.set(mon.fmtG(&b, list[0]));
                }
            }
            s.dirty = true;
        },
        .monitor_refresh_idx => {
            row.refresh_rate.set(options[ix]);
            s.dirty = true;
        },
        .monitor_transform_idx,
        .monitor_vrr_idx,
        .monitor_bitdepth_idx,
        .monitor_eotf_idx,
        .monitor_hdr_support_idx,
        .monitor_wide_idx,
        => setFieldInt(s, f, @intCast(ix)),
        .monitor_cm_idx => {
            row.cm.set(options[ix]);
            s.dirty = true;
        },
        else => {},
    }
}

// Tests

fn testState(n: usize) mon.State {
    var s = mon.State{};
    // `.unknown` keeps the base form to Display + Scale & transform; tests
    // that need the Hyprland-only rows set `.hyprland` themselves.
    s.kind = .unknown;
    s.outputs_len = n;
    for (s.outputs[0..n], 0..) |*o, i| {
        var b: [16]u8 = undefined;
        o.name.set(std.fmt.bufPrint(&b, "DP-{d}", .{i + 1}) catch "DP-1");
        o.resolution.set("2560x1440");
        o.refresh_rate.set("144");
        o.position.set("0x0");
        o.scale.set("1");
        o.transform.set("0");
    }
    return s;
}

test "settings-monitors-page: builds cards from the state" {
    const t = std.testing;
    var s = testState(2);
    var page = Page{};
    page.build(&s);
    const cards = page.cardsSlice();
    // Toolbar/canvas/pills, header, Display, Scale & transform, status.
    try t.expectEqual(@as(usize, 5), cards.len);
    // Untitled card: rows plus the 16px embedded-widget pad.
    try t.expectEqual(
        rows_mod.toolbar_h + rows_mod.info_row_h + rows_mod.canvas_h + rows_mod.pills_h + 16,
        rows_mod.cardHeight(cards[0]),
    );
    try t.expectEqualStrings("DP-1", cards[1].title);
    try t.expectEqual(@as(usize, 1), cards[1].rows.len);
    try t.expect(cards[1].rows[0] == .toggle);
    try t.expectEqualStrings("Display", cards[2].title);
    // No caps and no VRR (unknown compositor) -> resolution + refresh only.
    try t.expectEqual(@as(usize, 2), cards[2].rows.len);
    try t.expectEqual(@as(usize, 2), cards[3].rows.len);
    try t.expectEqualStrings("Scale & transform", cards[3].title);
    // Scroll height matches the shared card walk.
    try t.expectEqual(rows_mod.contentHeightOf(cards, 0), pageHeight(&page));
    try t.expect(pageHeight(&page) > rows_mod.canvas_h);
}

fn pageHeight(page: *const Page) i32 {
    const cards = page.cardsSlice();
    var h: i32 = 0;
    for (cards, 0..) |c, i| {
        h += rows_mod.cardHeight(c);
        if (i + 1 < cards.len) h += rows_mod.card_gap;
    }
    return h;
}

test "settings-monitors-page: no outputs falls back to a status card" {
    const t = std.testing;
    var s = mon.State{};
    s.kind = .unknown;
    s.status.set("Compositor not supported");
    var page = Page{};
    page.build(&s);
    const cards = page.cardsSlice();
    try t.expectEqual(@as(usize, 2), cards.len);
    try t.expectEqualStrings("Monitors", cards[1].title);
    try t.expectEqual(@as(usize, 1), cards[1].rows.len);
    try t.expectEqualStrings("Compositor not supported", cards[1].rows[0].info);
}

test "settings-monitors-page: pills carry the output names" {
    const t = std.testing;
    var s = testState(3);
    var page = Page{};
    page.build(&s);
    const pills = page.cardsSlice()[0].rows[3].pills;
    try t.expectEqual(@as(usize, 3), pills.pills.len);
    try t.expectEqualStrings("DP-2", pills.pills[1]);
}

test "settings-monitors-page: field routing mutates the row and marks dirty" {
    const t = std.testing;
    var s = testState(1);
    var page = Page{};
    page.build(&s);

    try t.expect(isMonitorField(.monitor_scale_pct));
    try t.expect(!isMonitorField(.dock_radius));

    setFieldInt(&s, .monitor_scale_pct, 150);
    try t.expect(s.dirty);
    try t.expectEqualStrings("1.5", s.outputs[0].scale.slice());
    try t.expectEqual(@as(i32, 150), fieldInt(&s, .monitor_scale_pct));
    // Out-of-range ticks clamp into the 1.0..2.0 window.
    setFieldInt(&s, .monitor_scale_pct, 9999);
    try t.expectEqualStrings("2", s.outputs[0].scale.slice());

    setFieldInt(&s, .monitor_transform_idx, 3);
    try t.expectEqual(@as(i32, 3), fieldInt(&s, .monitor_transform_idx));
    setFieldInt(&s, .monitor_transform_idx, 99);
    try t.expectEqual(@as(i32, 7), fieldInt(&s, .monitor_transform_idx));

    setFieldInt(&s, .monitor_bitdepth_idx, 1);
    try t.expectEqualStrings("10", s.outputs[0].bitdepth.slice());
    setFieldInt(&s, .monitor_bitdepth_idx, 0);
    try t.expect(s.outputs[0].bitdepth.empty());

    setFieldBool(&s, .monitor_enabled, false);
    try t.expect(s.outputs[0].disabled);
    try t.expect(!fieldBool(&s, .monitor_enabled));
    setFieldBool(&s, .monitor_enabled, true);
    try t.expect(!s.outputs[0].disabled);
}

test "settings-monitors-page: luminance sliders cover the specified range" {
    const t = std.testing;
    var s = testState(1);
    const row = &s.outputs[0];

    // kind 0: sdrbrightness, empty -> 1.0, "%.2f", ticks = round(d*100).
    try t.expectEqual(@as(i32, 100), fieldInt(&s, .monitor_sdr_brightness));
    row.sdrbrightness.set("1.25");
    try t.expectEqual(@as(i32, 125), fieldInt(&s, .monitor_sdr_brightness));
    row.sdrbrightness.set("9");
    try t.expectEqual(@as(i32, 200), fieldInt(&s, .monitor_sdr_brightness)); // clamped 0.1..2.0

    // kind 2: sdr_min_luminance, "%.4f" of a 0..0.01 value -> 0..100 ticks.
    row.sdr_min_luminance.set("0.005");
    try t.expectEqual(@as(i32, 50), fieldInt(&s, .monitor_sdr_min_lum));

    // kind 3: sdr_max_luminance, nits, 80..400, default 200.
    try t.expectEqual(@as(i32, 200), fieldInt(&s, .monitor_sdr_max_lum));
    row.sdr_max_luminance.set("350");
    try t.expectEqual(@as(i32, 350), fieldInt(&s, .monitor_sdr_max_lum));

    // kind 5/6: max / max-average luminance, 0..2000, defaults 600 / 400.
    try t.expectEqual(@as(i32, 600), fieldInt(&s, .monitor_hdr_max_lum));
    try t.expectEqual(@as(i32, 400), fieldInt(&s, .monitor_hdr_avg_lum));
    row.max_luminance.set("1000");
    try t.expectEqual(@as(i32, 1000), fieldInt(&s, .monitor_hdr_max_lum));

    // Round trip through the setter writes the value back as a plain number.
    setFieldInt(&s, .monitor_sdr_max_lum, 300);
    try t.expectEqualStrings("300", row.sdr_max_luminance.slice());
    setFieldInt(&s, .monitor_sdr_min_lum, 25);
    try t.expectEqualStrings("0.0025", row.sdr_min_luminance.slice());
    try t.expectEqual(@as(i32, 25), fieldInt(&s, .monitor_sdr_min_lum));
}

test "settings-monitors-page: tri-auto and EOTF selectors" {
    const t = std.testing;
    var s = testState(1);
    const row = &s.outputs[0];
    try t.expectEqual(@as(usize, 0), triAutoSel(row.supports_hdr));
    row.supports_hdr.set("1");
    try t.expectEqual(@as(usize, 1), triAutoSel(row.supports_hdr));
    row.supports_hdr.set("-1");
    try t.expectEqual(@as(usize, 2), triAutoSel(row.supports_hdr));

    setFieldComboIndex(&s, .monitor_hdr_support_idx, &tri_labels, 1);
    try t.expectEqualStrings("1", row.supports_hdr.slice());
    setFieldComboIndex(&s, .monitor_hdr_support_idx, &tri_labels, 0);
    try t.expect(row.supports_hdr.empty());
    setFieldComboIndex(&s, .monitor_wide_idx, &tri_labels, 2);
    try t.expectEqualStrings("-1", row.supports_wide_color.slice());

    try t.expectEqual(@as(usize, 0), sdrEotfSel(row.sdr_eotf));
    setFieldComboIndex(&s, .monitor_eotf_idx, &eotf_labels, 2);
    try t.expectEqual(@as(i32, 2), fieldInt(&s, .monitor_eotf_idx));
    try t.expectEqualStrings("2", row.sdr_eotf.slice());
}

test "settings-monitors-page: resolution pick snaps the refresh rate" {
    const t = std.testing;
    var s = testState(1);
    var caps = mon.OutputCaps{};
    caps.addMode(2560, 1440, 144);
    caps.addMode(2560, 1440, 60);
    caps.addMode(1920, 1080, 60);
    caps.addMode(1920, 1080, 240);
    caps.sortModes();
    s.pushCap("DP-1", caps);

    var page = Page{};
    page.build(&s);
    // 2 resolutions, descending by pixel area.
    const res = page.cardsSlice()[2].rows[0].combo;
    try t.expectEqual(@as(usize, 2), res.options.len);
    try t.expectEqualStrings("2560x1440", res.options[0]);

    setFieldComboIndex(&s, .monitor_mode_idx, res.options, 1);
    try t.expectEqualStrings("1920x1080", s.outputs[0].resolution.slice());
    // First rate of the picked resolution wins.
    try t.expectEqualStrings("240", s.outputs[0].refresh_rate.slice());
    try t.expect(s.dirty);

    page.build(&s);
    const hz = page.cardsSlice()[2].rows[1].combo;
    try t.expectEqual(@as(usize, 2), hz.options.len);
    try t.expectEqualStrings("240 Hz", hz.labels[0]);
    try t.expectEqual(@as(usize, 0), fieldComboIndex(&s, .monitor_refresh_idx, hz.options));
    setFieldComboIndex(&s, .monitor_refresh_idx, hz.options, 1);
    try t.expectEqualStrings("60", s.outputs[0].refresh_rate.slice());
    // Out-of-range picks are a no-op.
    setFieldComboIndex(&s, .monitor_refresh_idx, hz.options, 9);
    try t.expectEqualStrings("60", s.outputs[0].refresh_rate.slice());
}

test "settings-monitors-page: HDR panels follow the specified visibility rules" {
    const t = std.testing;
    var s = testState(1);
    var caps = mon.OutputCaps{};
    caps.hdr_hint = true;

    // Not Hyprland → no HDR panel at all.
    var page = Page{};
    page.build(&s);
    try t.expect(!hdrPanelVisible(&s, &s.outputs[0], s.capsFor("DP-1")));
    try t.expectEqual(@as(usize, 5), page.cardsSlice().len);

    // Hyprland + a caps table that hints HDR → the full form.
    s.kind = .hyprland;
    s.pushCap("DP-1", caps);
    try t.expect(hdrPanelVisible(&s, &s.outputs[0], s.capsFor("DP-1")));
    page.build(&s);
    // Toolbar, header, Display (now with VRR), Scale, Color, HDR, Luminance,
    // status — the full Hyprland form.
    try t.expectEqual(@as(usize, 8), page.cardsSlice().len);
    try t.expectEqualStrings("HDR", page.cardsSlice()[5].title);
    try t.expectEqualStrings("Luminance", page.cardsSlice()[6].title);
    try t.expectEqual(@as(usize, 5), page.cardsSlice()[6].rows.len);

    // A disabled output hides the HDR panel entirely.
    s.outputs[0].disabled = true;
    try t.expect(!hdrPanelVisible(&s, &s.outputs[0], s.capsFor("DP-1")));
    page.build(&s);
    try t.expectEqual(@as(usize, 6), page.cardsSlice().len);

    // cm=srgb with no HDR hint falls back to the wide/EOTF strip.
    s.outputs[0].disabled = false;
    caps.hdr_hint = false;
    s.pushCap("DP-1", caps);
    s.outputs[0].cm.set("srgb");
    try t.expect(!hdrPanelVisible(&s, &s.outputs[0], s.capsFor("DP-1")));
    try t.expect(wideEotfStripVisible(&s, &s.outputs[0], s.capsFor("DP-1")));
    page.build(&s);
    try t.expectEqual(@as(usize, 7), page.cardsSlice().len);
    try t.expectEqual(@as(usize, 2), page.cardsSlice()[5].rows.len);
}
