//! `desktop_shell/widgets/bluetooth/bluetooth_paint.{hpp,cpp}` — the
//! Bluetooth dock slot (glyph, dimmed when off, accent when connected, with
//! an optional `NN%`/`N devices` label) plus the full 360 px device popup
//! (power toggle, connected/remembered/nearby groups, per-row
//! Connect/Disconnect/Pair + Forget, scan footer).
//!
//! What could not come across verbatim, and why:
//!
//! * **No BlueZ service object.** Mediation (poll thread, change callbacks,
//!   it (poll thread, change callbacks, auto-reconnect, `connecting`
//!   tracking). The Zig shell has no BlueZ service object —
//!   `controlcenter/live_bluetooth.zig` publishes a `query()` snapshot —
//!   so every function here takes the already-resolved `Snapshot` +
//!   `[]Device` in, and every mutating click answers a `Verb` the host
//!   executes (`setPowered`, `deviceVerb[Thread]`, `removeDevice`,
//!   `setDiscovery` all exist on `live_bluetooth`). Same split as the VPN
//!   popup's NM verbs. The `connecting` flag is host-managed: set it when
//!   the host fires `connect`, clear it when the device reports connected.
//! * **The lifecycle statics.** `bluetooth_widget_init/poll/shutdown` keep
//!   their names and contract (refcount, 4 s battery-refresh stamp, 150 ms
//!   immediate-draw gate, 64-entry text-cache trim), but the change flags
//!   are plain bools — the dock loop is single-threaded, so no atomics —
//!   and the host raises them when its own query observes movement.
//! * **`EH_BLUETOOTH_DEBUG`.** The five fixtures (`connected`, `off`,
//!   `noadapter`, `scanning`, `empty`, anything else behaving like
//!   `connected`) are ported as `debugDevices` data the host can feed in
//!   instead of a live query; `debugMode()` reads the variable like the
//!   `debug_full_state`.
//! * **Kind classification.** `iconKind`/`codKind`/`kindGlyph`
//!   map icon names, then the Class of
//!   Device major/minor table. They read the `icon`/`class_code` fields
//!   the `live_bluetooth` walk now captures.
//!
//! Every popup rectangle has one definition shared by the paint and the
//! hit-test, so a button that moves on screen moves under the pointer too
//! (the `media_popup.zig` rule).

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const schema = @import("../../../config/schema.zig");
const pill = @import("../shared/pill.zig");
const chrome_colors = @import("../shared/chrome_colors.zig");
const wset = @import("../shared/widget_settings.zig");
const measure = @import("../shared/measure_scratch.zig");
const helpers = @import("../../shared/cairo_helpers.zig");
const glyphs = @import("../../common/material_glyph.zig");
const dock_widgets = @import("../../dock/widgets.zig");
const live_bt = @import("../../controlcenter/live_bluetooth.zig");

pub const popup_w: f64 = 360.0;

const k_max_rows: usize = 7;
const k_header_h: f64 = 56.0;
const k_status_h: f64 = 34.0;
const k_row_h: f64 = 48.0;
const k_section_h: f64 = 26.0;
const k_footer_gap: f64 = 10.0;
const k_scan_h: f64 = 40.0;
const k_bottom_pad: f64 = 14.0;

const k_shad_alpha: f64 = 0.28;

/// Battery refresh debounce from `bluetooth_widget_poll` (late
/// `Battery1` interfaces and silent percentage updates).
pub const battery_refresh_s: i64 = 4;
/// Immediate-draw gate from `bluetooth_widget_needs_immediate_draw`.
pub const immediate_draw_gate_ms: i64 = 150;
/// Text-cache trim threshold from `bluetooth_widget_poll`.
pub const text_cache_trim_at: usize = 64;

/// Monotonic milliseconds, for hosts without their own clock.
pub fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
        @divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), 1000000);
}

// Model

pub const DeviceKind = enum {
    unknown,
    headset,
    headphones,
    earbuds,
    speaker,
    microphone,
    mouse,
    keyboard,
    phone,
    computer,
    gamepad,
    watch,
    tv,
};

/// Icon name to device kind, via the freedesktop `Icon` name table.
/// See https://specifications.freedesktop.org/icon-naming-spec/latest/
pub fn iconKind(icon: []const u8) DeviceKind {
    const table = [_]struct { name: []const u8, kind: DeviceKind }{
        .{ .name = "audio-card", .kind = .speaker },
        .{ .name = "audio-headphones", .kind = .headphones },
        .{ .name = "audio-headset", .kind = .headset },
        .{ .name = "audio-speakers", .kind = .speaker },
        .{ .name = "computer", .kind = .computer },
        .{ .name = "input-gaming", .kind = .gamepad },
        .{ .name = "input-keyboard", .kind = .keyboard },
        .{ .name = "input-mouse", .kind = .mouse },
        .{ .name = "phone", .kind = .phone },
        .{ .name = "video-display", .kind = .tv },
    };
    for (table) |e| if (std.mem.eql(u8, icon, e.name)) return e.kind;
    return .unknown;
}

/// Class-of-Device major/minor table, used when the
/// `Icon` name says nothing.
pub fn codKind(cod: u32) DeviceKind {
    const major = (cod >> 8) & 0x1f;
    const minor = (cod >> 2) & 0x3f;
    if (major == 0x01) return .computer;
    if (major == 0x02) return .phone;
    if (major == 0x07) return .watch;
    if (major == 0x08) return .gamepad;
    if (major == 0x05) {
        const sub = minor >> 2;
        if (sub == 1) return .keyboard;
        if (sub == 2) return .mouse;
        if (sub == 3) return .gamepad;
        return .unknown;
    }
    if (major != 0x04) return .unknown;
    const av = minor >> 4;
    if (av == 1) return .headphones;
    if (av == 2) return .speaker;
    if (av == 4) return .microphone;
    if (av == 6) return .tv;
    return if ((minor & 0x04) != 0) .headset else .unknown;
}

/// One distinct glyph name per kind — the shared Lucide bank turns each
/// into its SVG. Audio devices do not
/// collapse: A2DP sinks are headphones, HSP/HFP voice links are
/// headset_mic, LE buds are earbuds — only actual speakers get speaker.
pub fn kindGlyph(kind: DeviceKind) []const u8 {
    return switch (kind) {
        .headset => "headset_mic",
        .headphones => "headphones",
        .earbuds => "earbuds",
        .speaker => "speaker",
        .microphone => "mic",
        .mouse => "mouse",
        .keyboard => "keyboard",
        .phone => "smartphone",
        .computer => "computer",
        .gamepad => "gamepad",
        .watch => "watch",
        .tv => "tv",
        .unknown => "bluetooth",
    };
}

/// `bluetooth_device_kind_name` — the human name used in the Settings
/// tab's status line ("Headphones · Connected · AA:BB…"). The default
/// for unknown kinds is "Device", not "Unknown".
pub fn kindName(kind: DeviceKind) []const u8 {
    return switch (kind) {
        .headset => "Headset",
        .headphones => "Headphones",
        .earbuds => "Earbuds",
        .speaker => "Speaker",
        .microphone => "Microphone",
        .mouse => "Mouse",
        .keyboard => "Keyboard",
        .phone => "Phone",
        .computer => "Computer",
        .gamepad => "Gamepad",
        .watch => "Watch",
        .tv => "TV",
        .unknown => "Device",
    };
}

/// `bluetooth_device_kind_glyph` for a live device: icon first, Class
/// fallback, the same as `make_device`.
pub fn deviceKindGlyph(icon: []const u8, has_class: bool, class_code: u32) []const u8 {
    const by_icon = iconKind(icon);
    if (by_icon != .unknown) return kindGlyph(by_icon);
    if (has_class) return kindGlyph(codKind(class_code));
    return kindGlyph(.unknown);
}

pub const Device = struct {
    path: []const u8 = "",
    address: []const u8 = "",
    alias: []const u8 = "",
    kind: DeviceKind = .unknown,
    paired: bool = false,
    connected: bool = false,
    connecting: bool = false,
    /// -1 when the device reports no battery.
    battery_pct: i32 = -1,
};

pub const Snapshot = struct {
    available: bool = false,
    powered: bool = false,
    connected: bool = false,
    scanning: bool = false,
    paired_count: i32 = 0,
    connected_count: i32 = 0,
};

/// `bluetooth_snapshot` counts — `connected` needs power. The lowest
/// connected battery lives in `minConnectedBattery`, computed in a separate loop.
pub fn summarize(devices: []const Device, available: bool, powered: bool, scanning: bool) Snapshot {
    var snap = Snapshot{ .available = available, .powered = powered, .scanning = scanning };
    for (devices) |*d| {
        if (d.paired) snap.paired_count += 1;
        if (d.connected) snap.connected_count += 1;
    }
    snap.connected = powered and snap.connected_count > 0;
    return snap;
}

/// Lowest connected-device battery, or -1 when none report one. Kept
/// separate so the slot label and the popup share it without recomputing
/// the whole summary.
pub fn minConnectedBattery(devices: []const Device) i32 {
    var battery: i32 = -1;
    for (devices) |*d| {
        if (!d.connected or d.battery_pct < 0) continue;
        if (battery < 0 or d.battery_pct < battery) battery = d.battery_pct;
    }
    return battery;
}

/// Adapts a `live_bluetooth` query into widget devices (classifying kinds
/// on the way). The returned slice borrows the query's strings; the host
/// owns both lifetimes.
pub fn devicesFromQueried(alloc: std.mem.Allocator, q: *const live_bt.Queried) ![]Device {
    var out = try alloc.alloc(Device, q.device_list.items.len);
    for (q.device_list.items, 0..) |*d, i| {
        out[i] = .{
            .path = d.path,
            .address = d.address,
            .alias = d.alias,
            .kind = blk: {
                const by_icon = iconKind(d.icon);
                if (by_icon != .unknown) break :blk by_icon;
                if (d.has_class) break :blk codKind(d.class_code);
                break :blk .unknown;
            },
            .paired = d.paired,
            .connected = d.connected,
            .battery_pct = d.battery_pct,
        };
    }
    return out;
}

/// Adapts a query snapshot: `available` is "BlueZ answered at all".
pub fn snapshotFromQueried(q: *const live_bt.Queried, devices: []const Device) Snapshot {
    return summarize(devices, true, q.snap.powered, q.snap.discovering);
}

// Debug fixtures (`EH_BLUETOOTH_DEBUG`)

pub const DebugMode = enum { connected, off, noadapter, scanning, empty };

/// Parses the variable; any other non-empty value behaves like `connected`.
pub fn debugModeFrom(env: ?[]const u8) ?DebugMode {
    const v = env orelse return null;
    if (v.len == 0) return null;
    if (std.mem.eql(u8, v, "off")) return .off;
    if (std.mem.eql(u8, v, "noadapter")) return .noadapter;
    if (std.mem.eql(u8, v, "scanning")) return .scanning;
    if (std.mem.eql(u8, v, "empty")) return .empty;
    return .connected;
}

pub fn debugMode() ?DebugMode {
    const p = std.c.getenv("EH_BLUETOOTH_DEBUG") orelse return null;
    return debugModeFrom(std.mem.span(p));
}

const DebugDev = struct {
    path: []const u8,
    address: []const u8,
    alias: []const u8,
    kind: DeviceKind,
    paired: bool,
    connected: bool,
    battery_pct: i32,
};

fn debugDevicesFor(mode: DebugMode) struct { snap: Snapshot, devs: []const DebugDev } {
    return switch (mode) {
        .off => .{
            .snap = .{ .available = true, .powered = false },
            .devs = &.{
                .{ .path = "/org/bluez/hci0/dev_50_50_50_00_00_01", .address = "50:50:50:00:00:01", .alias = "WH-1000XM5", .kind = .headphones, .paired = true, .connected = false, .battery_pct = 78 },
                .{ .path = "/org/bluez/hci0/dev_50_50_50_00_00_02", .address = "50:50:50:00:00:02", .alias = "MX Master 3S", .kind = .mouse, .paired = true, .connected = false, .battery_pct = 34 },
                .{ .path = "/org/bluez/hci0/dev_50_50_50_00_00_03", .address = "50:50:50:00:00:03", .alias = "HHKB Professional", .kind = .keyboard, .paired = true, .connected = false, .battery_pct = -1 },
            },
        },
        .noadapter => .{ .snap = .{}, .devs = &.{} },
        .scanning => .{
            .snap = .{ .available = true, .powered = true, .scanning = true },
            .devs = &.{
                .{ .path = "/org/bluez/hci0/dev_50_50_50_00_00_04", .address = "50:50:50:00:00:04", .alias = "Studio Speaker", .kind = .speaker, .paired = false, .connected = false, .battery_pct = -1 },
                .{ .path = "/org/bluez/hci0/dev_50_50_50_00_00_05", .address = "50:50:50:00:00:05", .alias = "USB Dongle", .kind = .unknown, .paired = false, .connected = false, .battery_pct = -1 },
            },
        },
        .empty => .{ .snap = .{ .available = true, .powered = true }, .devs = &.{} },
        .connected => .{
            .snap = .{ .available = true, .powered = true, .connected = true },
            .devs = &.{
                .{ .path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01", .address = "AA:BB:CC:DD:EE:01", .alias = "WH-1000XM5", .kind = .headphones, .paired = true, .connected = true, .battery_pct = 78 },
                .{ .path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_02", .address = "AA:BB:CC:DD:EE:02", .alias = "MX Master 3S", .kind = .mouse, .paired = true, .connected = true, .battery_pct = 34 },
                .{ .path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_03", .address = "AA:BB:CC:DD:EE:03", .alias = "AirPods Pro", .kind = .earbuds, .paired = true, .connected = true, .battery_pct = 100 },
                .{ .path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_04", .address = "AA:BB:CC:DD:EE:04", .alias = "HHKB Professional", .kind = .keyboard, .paired = true, .connected = false, .battery_pct = -1 },
                .{ .path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_05", .address = "AA:BB:CC:DD:EE:05", .alias = "DualSense", .kind = .gamepad, .paired = true, .connected = true, .battery_pct = -1 },
                .{ .path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_06", .address = "AA:BB:CC:DD:EE:06", .alias = "Studio Speaker", .kind = .speaker, .paired = false, .connected = false, .battery_pct = -1 },
            },
        },
    };
}

/// Debug snapshot: the canned counts (5 paired / 4 connected for the
/// fleet) for the debug fixture.
pub fn debugSnapshot(mode: DebugMode) Snapshot {
    return switch (mode) {
        .off => .{ .available = true, .powered = false },
        .noadapter => .{},
        .scanning => .{ .available = true, .powered = true, .scanning = true },
        .empty => .{ .available = true, .powered = true },
        .connected => .{ .available = true, .powered = true, .connected = true, .paired_count = 5, .connected_count = 4 },
    };
}

/// Debug devices as owned `Device`s.
pub fn debugDevices(alloc: std.mem.Allocator, mode: DebugMode) ![]Device {
    const f = debugDevicesFor(mode);
    var out = try alloc.alloc(Device, f.devs.len);
    for (f.devs, 0..) |*d, i| {
        out[i] = .{
            .path = d.path,
            .address = d.address,
            .alias = d.alias,
            .kind = d.kind,
            .paired = d.paired,
            .connected = d.connected,
            .battery_pct = d.battery_pct,
        };
    }
    return out;
}

// Lifecycle

var g_refcount: i32 = 0;
var g_running: bool = false;
var g_state_changed: bool = false;
var g_immediate_changed: bool = false;
var g_last_battery_refresh_ms: i64 = 0;
var g_last_draw_ms: i64 = 0;

/// `bluetooth_widget_init` — refcounted; the first consumer marks the
/// widget live. There is no service thread in the Zig shell (the host
/// queries BlueZ itself), so this only gates the poll below.
pub fn bluetoothWidgetInit() void {
    const prev = g_refcount;
    g_refcount = prev + 1;
    if (prev > 0) return;
    g_running = true;
}

/// `bluetooth_widget_shutdown` — the last consumer stops the widget.
pub fn bluetoothWidgetShutdown() void {
    if (g_refcount <= 0) return;
    const prev = g_refcount;
    g_refcount = prev - 1;
    if (prev > 1) return;
    g_running = false;
}

/// The host calls this when its own BlueZ query observes movement.
pub fn markChanged(immediate: bool) void {
    g_state_changed = true;
    if (immediate) g_immediate_changed = true;
}

pub const PollResult = struct { changed: bool, battery_refresh_due: bool };

/// `bluetooth_widget_poll` — answers whether the item set moved since the
/// last call, trims the text cache past 64 entries, and reports when a
/// battery re-read is due (4 s). The host performs the re-read itself with
/// `live_bluetooth.query`, and should only act on `battery_refresh_due`
/// while connected (gated the same way).
pub fn bluetoothWidgetPoll(now_ms: i64) PollResult {
    if (g_text_ready and g_text.count() > text_cache_trim_at) {
        resetText();
    }
    var out = PollResult{ .changed = false, .battery_refresh_due = false };
    if (!g_running) return out;
    if (g_state_changed) {
        g_state_changed = false;
        out.changed = true;
    }
    if (now_ms - g_last_battery_refresh_ms >= battery_refresh_s * 1000) {
        g_last_battery_refresh_ms = now_ms;
        out.battery_refresh_due = true;
    }
    return out;
}

/// `bluetooth_widget_needs_immediate_draw` — at most ~6 FPS for
/// BlueZ-triggered redraws.
pub fn bluetoothWidgetNeedsImmediateDraw(now_ms: i64) bool {
    if (now_ms - g_last_draw_ms < immediate_draw_gate_ms) return false;
    if (g_immediate_changed) {
        g_immediate_changed = false;
        g_last_draw_ms = now_ms;
        return true;
    }
    return false;
}

/// Drops every module-level cache, kept for the life of the
/// process; `reset` exists for tests and for a host that wants a clean slate.
pub fn reset() void {
    resetText();
    g_refcount = 0;
    g_running = false;
    g_state_changed = false;
    g_immediate_changed = false;
    g_last_battery_refresh_ms = 0;
    g_last_draw_ms = 0;
}

// Mediated operations (delegates to live_bluetooth)

/// `bluetooth_start_discovery` / `bluetooth_stop_discovery`.
pub fn setDiscovery(alloc: std.mem.Allocator, adapter_path: []const u8, start: bool) void {
    live_bt.setDiscovery(alloc, adapter_path, start);
}

/// `bluetooth_set_powered`.
pub fn setPowered(alloc: std.mem.Allocator, on: bool) bool {
    return live_bt.setPowered(alloc, on);
}

/// `bluetooth_connect_device` — slow verb, detached thread.
pub fn connectDevice(path: []const u8, adapter_path: []const u8) void {
    live_bt.deviceVerbThread(path, "Connect", adapter_path);
}

/// `bluetooth_disconnect_device` — fast verb, inline.
pub fn disconnectDevice(alloc: std.mem.Allocator, path: []const u8) bool {
    return live_bt.deviceVerb(alloc, path, "Disconnect", 5000);
}

/// `bluetooth_pair_device` — slow verb, detached thread.
pub fn pairDevice(path: []const u8, adapter_path: []const u8) void {
    live_bt.deviceVerbThread(path, "Pair", adapter_path);
}

/// `bluetooth_forget_device` — `RemoveDevice` on the adapter, then the
/// host re-reads.
pub fn forgetDevice(alloc: std.mem.Allocator, adapter_path: []const u8, path: []const u8) bool {
    return live_bt.removeDevice(alloc, adapter_path, path);
}

// Slot label

pub const LabelKind = enum { none, count, battery };

pub const SlotLabel = struct {
    kind: LabelKind = .none,
    /// `NN%` or `N device(s)`; empty when `kind` is `none`.
    text: [32]u8 = [_]u8{0} ** 32,
    len: usize = 0,
    pct: i32 = 0,

    pub fn str(self: *const SlotLabel) []const u8 {
        return self.text[0..self.len];
    }
};

/// `make_slot_label` — `NN%` for the lowest reporting connected battery,
/// else `N device(s)`, else nothing.
pub fn makeSlotLabel(devices: []const Device, connected: bool, connected_count: i32) SlotLabel {
    var out = SlotLabel{};
    if (!connected or connected_count <= 0) return out;
    var min_pct: i32 = 101;
    var with_battery: i32 = 0;
    for (devices) |*d| {
        if (!d.connected or d.battery_pct < 0) continue;
        with_battery += 1;
        if (d.battery_pct < min_pct) min_pct = d.battery_pct;
    }
    if (with_battery > 0) {
        out.kind = .battery;
        out.pct = std.math.clamp(min_pct, 0, 100);
        const s = std.fmt.bufPrint(&out.text, "{d}%", .{out.pct}) catch "";
        out.len = s.len;
    } else {
        out.kind = .count;
        const s = std.fmt.bufPrint(&out.text, "{d} {s}", .{
            connected_count,
            if (connected_count == 1) "device" else "devices",
        }) catch "";
        out.len = s.len;
    }
    return out;
}

/// `bt_battery_glyph` — the battery ladder for a device percentage.
pub fn batteryGlyph(pct: i32) []const u8 {
    if (pct >= 95) return "battery_full";
    if (pct >= 80) return "battery_6_bar";
    if (pct >= 60) return "battery_5_bar";
    if (pct >= 40) return "battery_4_bar";
    if (pct >= 20) return "battery_3_bar";
    if (pct >= 10) return "battery_2_bar";
    if (pct >= 5) return "battery_1_bar";
    return "battery_0_bar";
}

pub const BatteryRgb = struct { r: f64, g: f64, b: f64 };

/// `bt_battery_color` — red ≤ 20, amber ≤ 50, green above.
pub fn batteryColor(pct: i32) BatteryRgb {
    if (pct <= 20) return .{ .r = 1.0, .g = 0.43, .b = 0.38 };
    if (pct <= 50) return .{ .r = 0.96, .g = 0.72, .b = 0.30 };
    return .{ .r = 0.45, .g = 0.85, .b = 0.50 };
}

/// `dock_ui_scale(sc.dock)` — the dock module owns the formula.
fn uiScale(sc: *const schema.ShellConfig) f64 {
    return dock_widgets.uiScale(sc);
}

/// `widget_list_contains_bluetooth`.
pub fn widgetListContainsBluetooth(sc: *const schema.ShellConfig, list: []const []const u8) bool {
    return wset.listContainsImpl(sc, list, "bluetooth");
}

// Text measuring + cache

const TextSizes = struct {
    text: [40]u8 = [_]u8{0} ** 40,
    text_len: usize = 0,
    w: i32 = 0,
    h: i32 = 0,

    fn matches(self: *const TextSizes, txt: []const u8) bool {
        return self.text_len == txt.len and std.mem.eql(u8, self.text[0..self.text_len], txt);
    }

    fn set(self: *TextSizes, txt: []const u8, w: i32, h: i32) void {
        const n = @min(txt.len, self.text.len);
        @memcpy(self.text[0..n], txt[0..n]);
        self.text_len = n;
        self.w = w;
        self.h = h;
    }
};

var g_text: std.StringHashMap(TextSizes) = undefined;
var g_text_ready: bool = false;

fn textMap() *std.StringHashMap(TextSizes) {
    if (!g_text_ready) {
        g_text = std.StringHashMap(TextSizes).init(std.heap.page_allocator);
        g_text_ready = true;
    }
    return &g_text;
}

fn resetText() void {
    if (!g_text_ready) return;
    var it = g_text.keyIterator();
    while (it.next()) |k| std.heap.page_allocator.free(k.*);
    g_text.clearRetainingCapacity();
}

/// Widget glyph paint — every ligature name resolves through the shared
/// Lucide bank (`common/material_glyph.zig`), so nothing here depends on
/// the Material Symbols font.
fn drawMaterialGlyph(cr: ?*cairo.cairo_t, cx: f64, cy: f64, px: f64, ligature: []const u8, r: f64, g: f64, b: f64, a: f64) void {
    _ = glyphs.draw(cr, ligature, cx, cy, px, r, g, b, a);
}

// Slot

/// `dock_bluetooth_slot_width` — icon plus padding without a label, else
/// the glyph run plus label plus pads, floored at `max(icon*1.25, 40*us)`.
pub fn dockBluetoothSlotWidth(
    measure_cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
    bar_height: f64,
    snap: *const Snapshot,
    devices: []const Device,
) f64 {
    _ = bar_height;
    const us = uiScale(sc);
    const show_label = wset.settingBool(sc, instance_id, "show_label", false);
    if (!show_label) return icon_ref_px + 4.0 * us;
    const lbl = makeSlotLabel(devices, snap.connected, snap.connected_count);
    if (lbl.kind == .none) return icon_ref_px + 4.0 * us;

    const mcr = measure_cr orelse measure.measureCr();
    const font_px = std.math.clamp(icon_ref_px * 0.38, 11.0 * us, 15.0 * us);
    const ms = labelSize(mcr, instance_id, lbl.str(), font_px);
    const pad_x = 6.0 * us;
    const gap = 6.0 * us;
    const min_w = @max(icon_ref_px * 1.25, 40.0 * us);
    return @max(min_w, icon_ref_px + gap + @as(f64, @floatFromInt(ms.w)) + pad_x * 2.0);
}

pub const Measured = struct { w: i32, h: i32 };

/// The shared label measure behind the width and paint paths: the cached
/// width/height for this instance's current text, measuring on a miss, with
/// slightly different height semantics (font
/// size in the width path, measured height in paint); measuring both here
/// keeps one cache and the paint's numbers are the ones that matter.
fn labelSize(mcr: ?*cairo.cairo_t, instance_id: []const u8, txt: []const u8, font_px: f64) Measured {
    const m = textMap();
    if (m.getPtr(instance_id)) |e| {
        if (e.matches(txt)) return .{ .w = e.w, .h = e.h };
    }
    const ms: Measured = blk: {
        const c = mcr orelse break :blk .{ .w = 0, .h = 0 };
        var l = text.Layout.createForCairo(c);
        defer l.destroy();
        var fbuf: [32]u8 = undefined;
        const fd = std.fmt.bufPrint(&fbuf, "Inter {d}", .{@as(i32, @intFromFloat(font_px))}) catch "Inter 12";
        l.setFont(fd);
        l.setWrap(text.WRAP_WORD_CHAR);
        l.setText(txt);
        const s = l.pixelSize();
        break :blk .{ .w = s.w, .h = s.h };
    };
    if (m.getPtr(instance_id)) |e| {
        e.set(txt, ms.w, ms.h);
    } else {
        const owned = std.heap.page_allocator.dupe(u8, instance_id) catch return ms;
        m.put(owned, .{}) catch {
            std.heap.page_allocator.free(owned);
            return ms;
        };
        if (m.getPtr(owned)) |e| e.set(txt, ms.w, ms.h);
    }
    return ms;
}

/// `paint_bluetooth_slot` — pill, optional hover wash, glyph (dimmed when
/// off, accent when connected), optional label. A null `cr` measures
/// nothing and paints nothing.
pub fn paintBluetoothSlot(
    cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    x: f64,
    y: f64,
    slot_w: f64,
    slot_h: f64,
    icon_ref_px: f64,
    snap: *const Snapshot,
    devices: []const Device,
    hovered: bool,
    pressed: bool,
) void {
    const c = cr orelse return;
    const us = uiScale(sc);
    const show_label = wset.settingBool(sc, instance_id, "show_label", false);
    const mc = chrome_colors.of(sc);
    const active = snap.available and snap.powered;
    const fg_opacity: f64 = if (active) 1.0 else 0.55;
    var fg = mc.text;
    if (active and snap.connected) fg = mc.accent;
    const glyph: []const u8 = if (active) "bluetooth" else "bluetooth_disabled";
    const glyph_px = icon_ref_px * 0.52;

    cairo.cairo_save(c);
    defer cairo.cairo_restore(c);
    pill.paintPill(c, x, y, slot_w, slot_h);
    if (hovered or pressed) {
        helpers.roundedRect(c, x, y, slot_w, slot_h, pill.cornerRadius(slot_h, slot_w));
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, if (pressed) 0.14 else 0.08);
        cairo.cairo_fill(c);
    }

    const lbl = makeSlotLabel(devices, snap.connected, snap.connected_count);
    if (lbl.kind == .none or !show_label) {
        drawMaterialGlyph(c, x + slot_w * 0.5, y + slot_h * 0.5, glyph_px, glyph, fg.r, fg.g, fg.b, fg_opacity);
        return;
    }

    const font_px = std.math.clamp(icon_ref_px * 0.38, 11.0 * us, 15.0 * us);
    var fbuf: [32]u8 = undefined;
    const fd = std.fmt.bufPrint(&fbuf, "Inter {d}", .{@as(i32, @intFromFloat(font_px))}) catch "Inter 12";
    var lo = text.Layout.createForCairo(c);
    defer lo.destroy();
    lo.setFont(fd);
    lo.setWrap(text.WRAP_WORD_CHAR);
    lo.setText(lbl.str());
    const cached = labelSize(c, instance_id, lbl.str(), font_px);

    var lab = mc.text;
    if (lbl.kind == .battery) {
        const col = batteryColor(lbl.pct);
        lab = .{ .r = col.r, .g = col.g, .b = col.b };
    }
    const gap = 6.0 * us;
    const total_inner = icon_ref_px + gap + @as(f64, @floatFromInt(cached.w));
    const inner_x = x + (slot_w - total_inner) * 0.5;
    drawMaterialGlyph(c, inner_x + icon_ref_px * 0.5, y + slot_h * 0.5, glyph_px, glyph, fg.r, fg.g, fg.b, fg_opacity);

    cairo.cairo_set_source_rgba(c, lab.r, lab.g, lab.b, fg_opacity);
    cairo.cairo_move_to(c, inner_x + icon_ref_px + gap, y + (slot_h - @as(f64, @floatFromInt(cached.h))) * 0.5);
    lo.show(c);
}

// Popup layout (one definition for paint and hit-test)

pub const PopupItem = struct {
    header: bool = false,
    label: []const u8 = "",
    dev: usize = 0,
    body: [4]f64 = .{ 0, 0, 0, 0 },
    tile: [4]f64 = .{ 0, 0, 0, 0 },
    battery: [4]f64 = .{ 0, 0, 0, 0 },
    action: [4]f64 = .{ 0, 0, 0, 0 },
    forget: [4]f64 = .{ 0, 0, 0, 0 },
};

pub const PopupLayout = struct {
    w: f64 = 0,
    h: f64 = 0,
    header: [4]f64 = .{ 0, 0, 0, 0 },
    icon_tile: [4]f64 = .{ 0, 0, 0, 0 },
    toggle: [4]f64 = .{ 0, 0, 0, 0 },
    close_btn: [4]f64 = .{ 0, 0, 0, 0 },
    status: [4]f64 = .{ 0, 0, 0, 0 },
    items: []PopupItem = &.{},
    scan: [4]f64 = .{ 0, 0, 0, 0 },
    /// Device rows only (excludes section headers).
    shown: usize = 0,
};

fn inRect(px: f64, py: f64, r: [4]f64) bool {
    return px >= r[0] and px < r[0] + r[2] and py >= r[1] and py < r[1] + r[3];
}

/// `plan_popup_items` — connected, remembered, nearby, in that order, with
/// section headers only when more than one group is non-empty, capped at 7
/// device rows. Indices point into `devices`.
pub fn planPopupItems(alloc: std.mem.Allocator, snap: *const Snapshot, devices: []const Device) ![]PopupItem {
    var out = std.ArrayList(PopupItem).empty;
    errdefer out.deinit(alloc);
    if (!snap.available or !snap.powered) return out.toOwnedSlice(alloc);
    var groups: usize = 0;
    for ([_]bool{
        hasGroup(devices, .connected),
        hasGroup(devices, .remembered),
        hasGroup(devices, .nearby),
    }) |g| groups += if (g) 1 else 0;
    const show_headers = groups > 1;
    var budget: usize = k_max_rows;
    const kinds = [_]struct { group: DeviceGroup, label: []const u8 }{
        .{ .group = .connected, .label = "CONNECTED" },
        .{ .group = .remembered, .label = "REMEMBERED DEVICES" },
        .{ .group = .nearby, .label = "NEARBY DEVICES" },
    };
    for (kinds) |k| {
        var header_done = false;
        for (devices, 0..) |*d, i| {
            if (!inGroup(d, k.group)) continue;
            // Headers do not consume the row budget, but a group that opens
            // with no budget left contributes nothing at all.
            if (budget == 0) break;
            if (!header_done and show_headers) {
                try out.append(alloc, .{ .header = true, .label = k.label });
                header_done = true;
            }
            try out.append(alloc, .{ .dev = i });
            budget -= 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Device buckets for the popup groups.
pub const DeviceGroup = enum { connected, remembered, nearby };

fn inGroup(d: *const Device, group: DeviceGroup) bool {
    return switch (group) {
        .connected => d.connected,
        .remembered => !d.connected and d.paired,
        .nearby => !d.connected and !d.paired,
    };
}

fn hasGroup(devices: []const Device, group: DeviceGroup) bool {
    for (devices) |*d| {
        if (inGroup(d, group)) return true;
    }
    return false;
}

/// `popup_height_for_state`, ceiled.
pub fn popupHeightFor(alloc: std.mem.Allocator, us: f64, snap: *const Snapshot, devices: []const Device) !f64 {
    var h = 16.0 * us + k_header_h * us;
    if (!snap.available) {
        return @ceil(h + k_status_h * us + k_bottom_pad * us);
    }
    h += k_status_h * us;
    if (snap.powered) {
        const items = try planPopupItems(alloc, snap, devices);
        defer alloc.free(items);
        for (items) |*it| h += (if (it.header) k_section_h else k_row_h) * us;
        h += k_footer_gap * us + k_scan_h * us + k_bottom_pad * us;
    } else {
        h += k_bottom_pad * us;
    }
    return @ceil(h);
}

/// `popup_height` — the public entry; `us` comes from the dock scale.
pub fn popupHeight(alloc: std.mem.Allocator, sc: *const schema.ShellConfig, snap: *const Snapshot, devices: []const Device) !f64 {
    return popupHeightFor(alloc, uiScale(sc), snap, devices);
}

/// `build_popup_layout` — fills every rectangle the paint and the click
/// handler share.
pub fn buildPopupLayout(
    alloc: std.mem.Allocator,
    snap: *const Snapshot,
    devices: []const Device,
    us: f64,
    w: f64,
    h: f64,
) !PopupLayout {
    var lay = PopupLayout{ .w = w, .h = h };
    const pad = 16.0 * us;
    const header_h = k_header_h * us;
    const close_d = 28.0 * us;
    const tog_w = 46.0 * us;
    const tog_h = 26.0 * us;
    const tile_d = 34.0 * us;

    lay.header = .{ pad, pad, w - 2.0 * pad, header_h };
    lay.icon_tile = .{ pad, pad + (header_h - tile_d) * 0.5, tile_d, tile_d };
    lay.close_btn = .{ w - pad - close_d, pad + (header_h - close_d) * 0.5, close_d, close_d };
    lay.toggle = .{ lay.close_btn[0] - 8.0 * us - tog_w, pad + (header_h - tog_h) * 0.5, tog_w, tog_h };
    lay.status = .{ pad, pad + header_h, w - 2.0 * pad, k_status_h * us };

    const items = try planPopupItems(alloc, snap, devices);
    errdefer alloc.free(items);
    lay.items = items;
    var list_y = lay.status[1] + lay.status[3];
    const row_h = k_row_h * us;
    const section_h = k_section_h * us;
    for (lay.items) |*it| {
        if (it.header) {
            it.body = .{ pad + 2.0 * us, list_y, w - 2.0 * pad - 4.0 * us, section_h };
            list_y += section_h;
            continue;
        }
        const d = devices[it.dev];
        const ry = list_y;
        it.body = .{ pad, ry, w - 2.0 * pad, row_h };
        const tile_s = 32.0 * us;
        it.tile = .{ pad + 1.0 * us, ry + (row_h - tile_s) * 0.5, tile_s, tile_s };
        const act_h = 30.0 * us;
        const act_w: f64 = @as(f64, if (d.connected) 84.0 else if (d.paired) 62.0 else 46.0) * us;
        it.action = .{ w - pad - act_w, ry + (row_h - act_h) * 0.5, act_w, act_h };
        if (d.paired) {
            const fog_w = 26.0 * us;
            it.forget = .{ it.action[0] - 6.0 * us - fog_w, ry + (row_h - fog_w) * 0.5, fog_w, fog_w };
        }
        if (d.battery_pct >= 0) {
            const bat_w = 44.0 * us;
            const ref_x: f64 = if (it.forget[2] > 0) it.forget[0] else it.action[0];
            it.battery = .{ ref_x - 6.0 * us - bat_w, ry, bat_w, row_h };
        }
        lay.shown += 1;
        list_y += row_h;
    }

    if (snap.available and snap.powered) {
        const s_w = w - 2.0 * pad;
        const s_h = k_scan_h * us;
        lay.scan = .{ pad, h - k_bottom_pad * us - s_h, s_w, s_h };
    }
    return lay;
}

pub fn freePopupLayout(alloc: std.mem.Allocator, lay: *PopupLayout) void {
    alloc.free(lay.items);
    lay.items = &.{};
    lay.shown = 0;
}

// Popup clicks

pub const Click = enum { none, close, redraw, reopen };

/// A service verb the host must run for the click (`live_bluetooth`
/// covers all four). `reopen` answers also carry one (power/scan toggles
/// re-open the card so the new state paints).
pub const Verb = enum { none, set_powered, connect, disconnect, pair, forget, start_discovery, stop_discovery };

pub const ClickResult = struct {
    click: Click = .none,
    verb: Verb = .none,
    /// Device index the verb applies to, or whether to power on.
    index: usize = 0,
    power_on: bool = false,
};

/// `bluetooth_popup_click_action` — hit-tests the shared layout, mutates
/// nothing itself (service calls stay with the host, which also skips them
/// in debug fixtures (service calls are skipped there), and reports what
/// the host should do.
pub fn clickAction(
    alloc: std.mem.Allocator,
    sc: *const schema.ShellConfig,
    snap: *const Snapshot,
    devices: []const Device,
    x: f64,
    y: f64,
) !ClickResult {
    const us = uiScale(sc);
    const h = try popupHeightFor(alloc, us, snap, devices);
    if (x < 0 or x >= popup_w or y < 0 or y >= h) return .{ .click = .close };
    var lay = try buildPopupLayout(alloc, snap, devices, us, popup_w, h);
    defer freePopupLayout(alloc, &lay);

    if (inRect(x, y, lay.close_btn)) return .{ .click = .close };
    if (snap.available and inRect(x, y, lay.toggle)) {
        return .{ .click = .reopen, .verb = .set_powered, .power_on = !snap.powered };
    }
    for (lay.items) |*it| {
        if (it.header) continue;
        const d = devices[it.dev];
        if (it.forget[2] > 0 and inRect(x, y, it.forget)) {
            return .{ .click = .redraw, .verb = .forget, .index = it.dev };
        }
        if (inRect(x, y, it.action)) {
            return .{
                .click = .redraw,
                .verb = if (d.connected) .disconnect else if (d.paired) .connect else .pair,
                .index = it.dev,
            };
        }
    }
    if (lay.scan[2] > 0 and inRect(x, y, lay.scan)) {
        return .{
            .click = .reopen,
            .verb = if (snap.scanning) .stop_discovery else .start_discovery,
        };
    }
    return .{};
}

// Popup paint

fn setToyFont(cr: ?*cairo.cairo_t, size: f64, bold: bool) void {
    cairo.cairo_select_font_face(
        cr,
        "Inter",
        cairo.CAIRO_FONT_SLANT_NORMAL,
        if (bold) cairo.CAIRO_FONT_WEIGHT_BOLD else cairo.CAIRO_FONT_WEIGHT_NORMAL,
    );
    cairo.cairo_set_font_size(cr, size);
}

fn showText(cr: ?*cairo.cairo_t, s: []const u8, x: f64, y: f64) void {
    var zbuf: [1024:0]u8 = [_:0]u8{0} ** 1024;
    const n = @min(s.len, 1023);
    @memcpy(zbuf[0..n], s[0..n]);
    cairo.cairo_move_to(cr, x, y);
    cairo.cairo_show_text(cr, &zbuf);
}

fn textExtents(cr: ?*cairo.cairo_t, s: []const u8) cairo.cairo_text_extents_t {
    var zbuf: [1024:0]u8 = [_:0]u8{0} ** 1024;
    const n = @min(s.len, 1023);
    @memcpy(zbuf[0..n], s[0..n]);
    var te: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(cr, &zbuf, &te);
    return te;
}

/// `dock_bluetooth_popup_paint` — the whole card. A null `cr` paints
/// nothing (the host still syncs state before calling).
pub fn paintPopup(
    alloc: std.mem.Allocator,
    cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    snap: *const Snapshot,
    devices: []const Device,
    pointer: ?[2]f64,
) !void {
    const c = cr orelse return;
    const us = uiScale(sc);
    const h = try popupHeightFor(alloc, us, snap, devices);
    const w = popup_w;
    const mc = chrome_colors.of(sc);
    const card_alpha: f64 = sc.appearance.overlay_opacity_widget_card;
    const px: f64 = if (pointer) |p| p[0] else -1.0;
    const py: f64 = if (pointer) |p| p[1] else -1.0;

    var lay = try buildPopupLayout(alloc, snap, devices, us, w, h);
    defer freePopupLayout(alloc, &lay);

    cairo.cairo_save(c);
    defer cairo.cairo_restore(c);
    helpers.roundedRect(c, 2.0 * us, 4.0 * us, w, h, 20.0 * us);
    // Scaled with the card: 0% must leave nothing, shadow included.
    cairo.cairo_set_source_rgba(c, 0, 0, 0, k_shad_alpha * card_alpha);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
    cairo.cairo_save(c);
    defer cairo.cairo_restore(c);

    helpers.roundedRect(c, 0, 0, w, h, 20.0 * us);
    cairo.cairo_set_source_rgba(c, mc.dock_fill.r * 0.30, mc.dock_fill.g * 0.30, mc.dock_fill.b * 0.30, 0.92 * card_alpha);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    const pad = 16.0 * us;
    const powered = snap.available and snap.powered;
    helpers.roundedRect(c, lay.icon_tile[0], lay.icon_tile[1], lay.icon_tile[2], lay.icon_tile[3], 10.0 * us);
    if (powered) {
        cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.18);
    } else {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.07);
    }
    cairo.cairo_fill(c);
    {
        const gr: f64 = if (powered) mc.accent.r else 0.65;
        const gg: f64 = if (powered) mc.accent.g else 0.68;
        const gb: f64 = if (powered) mc.accent.b else 0.72;
        const glyph: []const u8 = if (snap.scanning) "bluetooth_searching" else if (powered) "bluetooth" else "bluetooth_disabled";
        _ = glyphs.draw(c, glyph, lay.icon_tile[0] + lay.icon_tile[2] * 0.5, lay.icon_tile[1] + lay.icon_tile[3] * 0.5, 18.0 * us, gr, gg, gb, 0.95);
    }

    cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.95);
    setToyFont(c, 15.0 * us, true);
    showText(c, "Bluetooth", lay.icon_tile[0] + lay.icon_tile[2] + 10.0 * us, lay.header[1] + lay.header[3] * 0.5 + 5.5 * us);

    const close_hov = inRect(px, py, lay.close_btn);
    helpers.roundedRect(c, lay.close_btn[0], lay.close_btn[1], lay.close_btn[2], lay.close_btn[3], 7.0 * us);
    cairo.cairo_set_source_rgba(c, 0.3, 0.3, 0.35, if (close_hov) 0.70 else 0.35);
    cairo.cairo_fill(c);
    _ = glyphs.draw(c, "close", lay.close_btn[0] + lay.close_btn[2] * 0.5, lay.close_btn[1] + lay.close_btn[3] * 0.5, 14.0 * us, mc.text.r, mc.text.g, mc.text.b, if (close_hov) 1.0 else 0.85);

    if (snap.available) {
        const tog_hov = inRect(px, py, lay.toggle);
        helpers.roundedRect(c, lay.toggle[0], lay.toggle[1], lay.toggle[2], lay.toggle[3], lay.toggle[3] * 0.5);
        if (snap.powered) {
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, if (tog_hov) 1.0 else 0.85);
        } else {
            cairo.cairo_set_source_rgba(c, 0.15, 0.15, 0.18, if (tog_hov) 0.55 else 0.40);
        }
        cairo.cairo_fill(c);
        if (!snap.powered) {
            helpers.roundedRect(c, lay.toggle[0] + 0.5, lay.toggle[1] + 0.5, lay.toggle[2] - 1.0, lay.toggle[3] - 1.0, lay.toggle[3] * 0.5 - 0.5);
            cairo.cairo_set_source_rgba(c, mc.outline.r, mc.outline.g, mc.outline.b, 0.6);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_stroke(c);
        }
        const th = lay.toggle[3] - 6.0 * us;
        const tx: f64 = if (snap.powered) lay.toggle[0] + lay.toggle[2] - 3.0 * us - th else lay.toggle[0] + 3.0 * us;
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 1.0);
        cairo.cairo_arc(c, tx + th * 0.5, lay.toggle[1] + lay.toggle[3] * 0.5, th * 0.5, 0, 2.0 * std.math.pi);
        cairo.cairo_fill(c);
    }

    {
        var status_buf: [64]u8 = undefined;
        // Singular/plural handled explicitly with a ternary.
        const status: []const u8 = if (!snap.available)
            "No Bluetooth adapter found"
        else if (!snap.powered)
            "Bluetooth is off"
        else if (snap.scanning)
            "Scanning for devices…"
        else if (snap.connected_count > 0)
            std.fmt.bufPrint(&status_buf, "On · {d} {s}", .{
                snap.connected_count,
                if (snap.connected_count == 1) "device" else "devices",
            }) catch "On"
        else
            "On · no devices connected";
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.6);
        setToyFont(c, 12.0 * us, false);
        showText(c, status, lay.status[0], lay.status[1] + lay.status[3] * 0.5 + 4.5 * us);
    }

    if (lay.shown > 0) {
        const dy = lay.status[1] + lay.status[3];
        cairo.cairo_set_source_rgba(c, mc.outline.r, mc.outline.g, mc.outline.b, 0.16);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_move_to(c, pad + 2.0 * us, dy);
        cairo.cairo_line_to(c, w - pad - 2.0 * us, dy);
        cairo.cairo_stroke(c);
    }

    if (lay.shown > 0) {
        cairo.cairo_save(c);
        const first = lay.items[0].body;
        var last = first;
        for (lay.items) |*it| last = it.body;
        cairo.cairo_rectangle(c, first[0], first[1], first[2], last[1] + last[3] - first[1]);
        cairo.cairo_clip(c);
        defer cairo.cairo_restore(c);

        for (lay.items) |*it| {
            if (it.header) {
                cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.42);
                setToyFont(c, 10.0 * us, true);
                showText(c, it.label, it.body[0], it.body[1] + it.body[3] * 0.5 + 3.5 * us);
                continue;
            }
            const d = devices[it.dev];
            const row_hov = inRect(px, py, it.body);

            if (d.connected or row_hov) {
                helpers.roundedRect(c, it.body[0], it.body[1], it.body[2], it.body[3], 10.0 * us);
                if (d.connected) {
                    cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.14);
                } else {
                    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.07);
                }
                cairo.cairo_fill(c);
            }

            helpers.roundedRect(c, it.tile[0], it.tile[1], it.tile[2], it.tile[3], 9.0 * us);
            if (d.connected) {
                cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.20);
            } else {
                cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.08);
            }
            cairo.cairo_fill(c);

            var gr: f64 = 0.75;
            var gg: f64 = 0.78;
            var gb: f64 = 0.82;
            if (d.connecting) {
                gr = 0.96;
                gg = 0.72;
                gb = 0.30;
            } else if (d.connected) {
                gr = mc.accent.r;
                gg = mc.accent.g;
                gb = mc.accent.b;
            }
            _ = glyphs.draw(c, kindGlyph(d.kind), it.tile[0] + it.tile[2] * 0.5, it.tile[1] + it.tile[3] * 0.5, 16.0 * us, gr, gg, gb, 0.95);

            const label: []const u8 = if (d.alias.len > 0) d.alias else d.address;
            var text_right = w - pad;
            if (it.battery[2] > 0) text_right = it.battery[0];
            if (it.forget[2] > 0) text_right = @min(text_right, it.forget[0]);
            text_right = @min(text_right, it.action[0]);
            const name_x = it.tile[0] + it.tile[2] + 10.0 * us;
            const name_max_w = @max(24.0, text_right - 8.0 * us - name_x);
            const line_gap = 4.0 * us;

            var pl = text.Layout.createForCairo(c);
            defer pl.destroy();
            var pbuf: [48]u8 = undefined;
            pl.setFont(std.fmt.bufPrint(&pbuf, "Inter Medium {d}", .{@as(i32, @intFromFloat(13.0 * us))}) catch "Inter Medium 13");
            pl.setText(label);
            pl.setWidthUnits(@intFromFloat(name_max_w * text.PANGO_SCALE));
            pl.setEllipsize(text.ELLIPSIZE_END);
            const name_ink = inkExtents(&pl);

            const sub: []const u8 = if (d.connected) "Connected" else if (d.connecting) "Connecting…" else if (d.paired) "Paired" else "Not paired";
            var sl = text.Layout.createForCairo(c);
            defer sl.destroy();
            var sbuf: [48]u8 = undefined;
            sl.setFont(std.fmt.bufPrint(&sbuf, "Inter {d}", .{@as(i32, @intFromFloat(11.0 * us))}) catch "Inter 11");
            sl.setText(sub);
            sl.setWidthUnits(@intFromFloat(name_max_w * text.PANGO_SCALE));
            sl.setEllipsize(text.ELLIPSIZE_END);
            const sub_ink = inkExtents(&sl);

            const block_h: f64 = @as(f64, @floatFromInt(name_ink.h)) + line_gap + @as(f64, @floatFromInt(sub_ink.h));
            const block_top = it.body[1] + (it.body[3] - block_h) * 0.5;

            cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, if (d.connected) 0.95 else 0.80);
            cairo.cairo_move_to(c, name_x, block_top - @as(f64, @floatFromInt(name_ink.y)));
            pl.show(c);

            if (d.connecting) {
                cairo.cairo_set_source_rgba(c, 0.96, 0.72, 0.30, 0.5);
            } else {
                cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.5);
            }
            cairo.cairo_save(c);
            cairo.cairo_rectangle(c, name_x, block_top + @as(f64, @floatFromInt(name_ink.h)) + line_gap, name_max_w, @as(f64, @floatFromInt(sub_ink.h)) + 4.0 * us);
            cairo.cairo_clip(c);
            cairo.cairo_move_to(c, name_x, block_top + @as(f64, @floatFromInt(name_ink.h)) + line_gap - @as(f64, @floatFromInt(sub_ink.y)));
            sl.show(c);
            cairo.cairo_restore(c);

            if (it.battery[2] > 0 and d.battery_pct >= 0) {
                var bbuf: [8]u8 = undefined;
                const btxt = std.fmt.bufPrint(&bbuf, "{d}%", .{d.battery_pct}) catch "?";
                const col = batteryColor(d.battery_pct);
                setToyFont(c, 11.0 * us, true);
                const te = textExtents(c, btxt);
                const gsz = 15.0 * us;
                const end_x = it.battery[0] + it.battery[2];
                const cy = it.body[1] + it.body[3] * 0.5;
                const glyph_cx = end_x - te.x_advance - 3.0 * us - gsz * 0.5;
                _ = glyphs.draw(c, batteryGlyph(d.battery_pct), glyph_cx, cy, gsz, col.r, col.g, col.b, 1.0);
                cairo.cairo_set_source_rgba(c, col.r, col.g, col.b, 0.95);
                cairo.cairo_move_to(c, end_x - te.x_advance, cy + te.height * 0.35);
                showText(c, btxt, end_x - te.x_advance, cy + te.height * 0.35);
            }

            {
                const action_label: []const u8 = if (d.connected) "Disconnect" else if (d.paired) "Connect" else "Pair";
                const act_hov = inRect(px, py, it.action);
                helpers.roundedRect(c, it.action[0], it.action[1], it.action[2], it.action[3], it.action[3] * 0.5);
                if (d.connected) {
                    cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, if (act_hov) 1.0 else 0.88);
                } else {
                    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, if (act_hov) 0.22 else 0.13);
                }
                cairo.cairo_fill(c);
                setToyFont(c, 11.0 * us, false);
                const ate = textExtents(c, action_label);
                const atx = it.action[0] + (it.action[2] - ate.x_advance) * 0.5;
                const aty = it.action[1] + it.action[3] * 0.5 + ate.height * 0.35;
                if (d.connected) {
                    cairo.cairo_set_source_rgba(c, 1, 1, 1, if (act_hov) 1.0 else 0.92);
                } else {
                    cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.9);
                }
                showText(c, action_label, atx, aty);
            }

            if (it.forget[2] > 0) {
                const fog_hov = inRect(px, py, it.forget);
                helpers.roundedRect(c, it.forget[0], it.forget[1], it.forget[2], it.forget[3], 6.0 * us);
                cairo.cairo_set_source_rgba(
                    c,
                    if (fog_hov) 0.90 else 0.55,
                    if (fog_hov) 0.35 else 0.55,
                    if (fog_hov) 0.30 else 0.60,
                    if (fog_hov) 0.30 else 0.10,
                );
                cairo.cairo_fill(c);
                _ = glyphs.draw(c, "delete", it.forget[0] + it.forget[2] * 0.5, it.forget[1] + it.forget[3] * 0.5, 14.0 * us, mc.text.r, mc.text.g, mc.text.b, if (fog_hov) 0.95 else 0.55);
            }
        }
        cairo.cairo_restore(c);

        const dy = blk: {
            var last_y: f64 = 0;
            var last_h: f64 = 0;
            for (lay.items) |*bit| {
                last_y = bit.body[1];
                last_h = bit.body[3];
            }
            break :blk last_y + last_h;
        };
        cairo.cairo_set_source_rgba(c, mc.outline.r, mc.outline.g, mc.outline.b, 0.16);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_move_to(c, pad + 2.0 * us, dy);
        cairo.cairo_line_to(c, w - pad - 2.0 * us, dy);
        cairo.cairo_stroke(c);
    }

    if (lay.scan[2] > 0) {
        const scan_hov = inRect(px, py, lay.scan);
        helpers.roundedRect(c, lay.scan[0], lay.scan[1], lay.scan[2], lay.scan[3], lay.scan[3] * 0.5);
        if (snap.scanning) {
            cairo.cairo_set_source_rgba(c, 0.85, 0.27, 0.22, if (scan_hov) 1.0 else 0.85);
        } else {
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, if (scan_hov) 1.0 else 0.88);
        }
        cairo.cairo_fill(c);

        const scan_label: []const u8 = if (snap.scanning) "Stop scan" else "Scan for devices";
        const scan_glyph: []const u8 = if (snap.scanning) "close" else "add";
        cairo.cairo_set_source_rgba(c, 1, 1, 1, if (scan_hov) 1.0 else 0.92);
        setToyFont(c, 12.0 * us, true);
        const ste = textExtents(c, scan_label);
        const glyph_sz = 16.0 * us;
        const total_glyph = glyph_sz + 6.0 * us + ste.x_advance;
        const start_x = lay.scan[0] + (lay.scan[2] - total_glyph) * 0.5;
        const cy = lay.scan[1] + lay.scan[3] * 0.5;
        _ = glyphs.draw(c, scan_glyph, start_x + glyph_sz * 0.5, cy, glyph_sz, 1, 1, 1, if (scan_hov) 1.0 else 0.92);
        showText(c, scan_label, start_x + glyph_sz + 6.0 * us, cy + ste.height * 0.35);
    }
}

/// Ink extents (not logical size) of a laid-out run, using the
/// `pango_layout_get_pixel_extents` block math.
fn inkExtents(lo: *text.Layout) struct { x: i32, y: i32, w: i32, h: i32 } {
    if (lo.layout) |l| {
        var ink: text.PangoRectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        text.pango_layout_get_pixel_extents(l, &ink, null);
        return .{
            .x = @intCast(@divFloor(ink.x, text.PANGO_SCALE_INT)),
            .y = @intCast(@divFloor(ink.y, text.PANGO_SCALE_INT)),
            .w = @intCast(@divFloor(ink.width, text.PANGO_SCALE_INT)),
            .h = @intCast(@divFloor(ink.height, text.PANGO_SCALE_INT)),
        };
    }
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

// Tests

fn dev(path: []const u8, alias: []const u8, kind: DeviceKind, paired: bool, connected: bool, battery: i32) Device {
    return .{ .path = path, .alias = alias, .kind = kind, .paired = paired, .connected = connected, .battery_pct = battery };
}

test "bluetooth: kind classification tables" {
    const t = std.testing;
    try t.expectEqual(DeviceKind.headphones, iconKind("audio-headphones"));
    try t.expectEqual(DeviceKind.headset, iconKind("audio-headset"));
    try t.expectEqual(DeviceKind.speaker, iconKind("audio-card"));
    try t.expectEqual(DeviceKind.mouse, iconKind("input-mouse"));
    try t.expectEqual(DeviceKind.keyboard, iconKind("input-keyboard"));
    try t.expectEqual(DeviceKind.gamepad, iconKind("input-gaming"));
    try t.expectEqual(DeviceKind.phone, iconKind("phone"));
    try t.expectEqual(DeviceKind.computer, iconKind("computer"));
    try t.expectEqual(DeviceKind.tv, iconKind("video-display"));
    try t.expectEqual(DeviceKind.unknown, iconKind("nope"));
    // Class of Device: computer, phone, headphones, headset bit, keyboard,
    // mouse, gamepad, watch.
    // `codKind` arms 4/6 (microphone/TV) are unreachable:
    // `minor` is 6 bits, so `minor >> 4` never exceeds 3.
    try t.expectEqual(DeviceKind.computer, codKind(0x0100));
    try t.expectEqual(DeviceKind.phone, codKind(0x0200 | 0x0C));
    // `codKind` arms 4/6 (microphone/TV) are unreachable:
    // `minor` is 6 bits, so `minor >> 4` never exceeds 3.
    try t.expectEqual(DeviceKind.headphones, codKind(0x0400 | (1 << 6)));
    try t.expectEqual(DeviceKind.speaker, codKind(0x0400 | (2 << 6)));
    try t.expectEqual(DeviceKind.unknown, codKind(0x0400 | (4 << 6)));
    try t.expectEqual(DeviceKind.unknown, codKind(0x0400 | (6 << 6)));
    try t.expectEqual(DeviceKind.headset, codKind(0x0400 | (0x04 << 2)));
    try t.expectEqual(DeviceKind.unknown, codKind(0x0400));
    try t.expectEqual(DeviceKind.keyboard, codKind(0x0500 | (1 << 4)));
    try t.expectEqual(DeviceKind.mouse, codKind(0x0500 | (2 << 4)));
    try t.expectEqual(DeviceKind.gamepad, codKind(0x0500 | (3 << 4)));
    try t.expectEqual(DeviceKind.gamepad, codKind(0x0800));
    try t.expectEqual(DeviceKind.watch, codKind(0x0700));
    try t.expectEqual(DeviceKind.unknown, codKind(0));
    // Glyphs do not collapse audio kinds.
    try t.expectEqualStrings("headset_mic", kindGlyph(.headset));
    try t.expectEqualStrings("headphones", kindGlyph(.headphones));
    try t.expectEqualStrings("earbuds", kindGlyph(.earbuds));
    try t.expectEqualStrings("bluetooth", kindGlyph(.unknown));
    try t.expectEqualStrings("headphones", deviceKindGlyph("audio-headphones", true, 0x0500));
    try t.expectEqualStrings("mouse", deviceKindGlyph("", true, 0x0500 | (2 << 4)));
    try t.expectEqualStrings("bluetooth", deviceKindGlyph("", false, 0));
}

test "bluetooth: slot label prefers min battery, else count" {
    const t = std.testing;
    const devs = [_]Device{
        dev("/a", "Phones", .headphones, true, true, 78),
        dev("/b", "Mouse", .mouse, true, true, 34),
        dev("/c", "Keys", .keyboard, true, false, -1),
    };
    var lbl = makeSlotLabel(&devs, true, 2);
    try t.expectEqual(LabelKind.battery, lbl.kind);
    try t.expectEqualStrings("34%", lbl.str());
    try t.expectEqual(@as(i32, 34), lbl.pct);
    const norep = [_]Device{dev("/c", "Keys", .keyboard, true, true, -1)};
    lbl = makeSlotLabel(&norep, true, 1);
    try t.expectEqual(LabelKind.count, lbl.kind);
    try t.expectEqualStrings("1 device", lbl.str());
    lbl = makeSlotLabel(&devs, false, 0);
    try t.expectEqual(LabelKind.none, lbl.kind);
    try t.expectEqualStrings("", lbl.str());
    try t.expectEqualStrings("battery_5_bar", batteryGlyph(75));
    try t.expectEqualStrings("battery_0_bar", batteryGlyph(3));
    const col = batteryColor(10);
    try t.expectEqual(BatteryRgb{ .r = 1.0, .g = 0.43, .b = 0.38 }, col);
}

test "bluetooth: debug fixtures cover the lookup tables" {
    const t = std.testing;
    try t.expectEqual(DebugMode.connected, debugModeFrom("anything-else").?);
    try t.expectEqual(DebugMode.off, debugModeFrom("off").?);
    try t.expectEqual(DebugMode.noadapter, debugModeFrom("noadapter").?);
    try t.expectEqual(DebugMode.scanning, debugModeFrom("scanning").?);
    try t.expectEqual(DebugMode.empty, debugModeFrom("empty").?);
    try t.expect(debugModeFrom(null) == null);
    try t.expect(debugModeFrom("") == null);
    const fleet = try debugDevices(t.allocator, .connected);
    defer t.allocator.free(fleet);
    try t.expectEqual(@as(usize, 6), fleet.len);
    try t.expectEqual(DeviceKind.earbuds, fleet[2].kind);
    try t.expectEqual(@as(i32, 100), fleet[2].battery_pct);
    const snap = debugSnapshot(.connected);
    try t.expect(snap.powered and snap.connected);
    try t.expectEqual(@as(i32, 4), snap.connected_count);
    try t.expectEqual(@as(i32, 34), minConnectedBattery(fleet));
    const off = try debugDevices(t.allocator, .off);
    defer t.allocator.free(off);
    try t.expectEqual(@as(usize, 3), off.len);
}

test "bluetooth: popup plans groups with headers and a 7-row budget" {
    const t = std.testing;
    const devs = [_]Device{
        dev("/a", "A", .headphones, true, true, -1),
        dev("/b", "B", .mouse, true, true, -1),
        dev("/c", "C", .keyboard, true, false, -1),
        dev("/d", "D", .speaker, false, false, -1),
    };
    const snap = Snapshot{ .available = true, .powered = true, .connected = true, .connected_count = 2 };
    const items = try planPopupItems(t.allocator, &snap, &devs);
    defer t.allocator.free(items);
    // Three groups → headers on, 2 + 1 + 1 rows + 3 headers.
    try t.expectEqual(@as(usize, 7), items.len);
    try t.expect(items[0].header);
    try t.expectEqualStrings("CONNECTED", items[0].label);
    try t.expect(!items[1].header and items[1].dev == 0);
    try t.expectEqualStrings("REMEMBERED DEVICES", items[3].label);
    try t.expectEqualStrings("NEARBY DEVICES", items[5].label);
    // One group → no headers.
    const solo = [_]Device{dev("/a", "A", .headphones, true, true, -1)};
    const solo_items = try planPopupItems(t.allocator, &snap, &solo);
    defer t.allocator.free(solo_items);
    try t.expectEqual(@as(usize, 1), solo_items.len);
    try t.expect(!solo_items[0].header);
    // Powered off → no rows at all.
    const off_snap = Snapshot{ .available = true, .powered = false };
    const off_items = try planPopupItems(t.allocator, &off_snap, &devs);
    defer t.allocator.free(off_items);
    try t.expectEqual(@as(usize, 0), off_items.len);
}

test "bluetooth: popup height follows state" {
    const t = std.testing;
    // Unavailable: 16 + 56 + 34 + 14, ceiled.
    const empty_snap = Snapshot{};
    try t.expectEqual(@as(f64, 120.0), try popupHeightFor(t.allocator, 1.0, &empty_snap, &.{}));
    const devs = [_]Device{dev("/a", "A", .headphones, true, true, -1)};
    const snap = Snapshot{ .available = true, .powered = true, .connected = true, .connected_count = 1 };
    // 16 + 56 + 34 + 48 + 10 + 40 + 14 = 218.
    try t.expectEqual(@as(f64, 218.0), try popupHeightFor(t.allocator, 1.0, &snap, &devs));
}

test "bluetooth: layout fills every shared rectangle" {
    const t = std.testing;
    const devs = [_]Device{
        dev("/a", "A", .headphones, true, true, 80),
        dev("/b", "B", .mouse, true, false, -1),
    };
    const snap = Snapshot{ .available = true, .powered = true, .connected = true, .connected_count = 1 };
    const h = try popupHeightFor(t.allocator, 1.0, &snap, &devs);
    var lay = try buildPopupLayout(t.allocator, &snap, &devs, 1.0, popup_w, h);
    defer freePopupLayout(t.allocator, &lay);
    try t.expectEqual(@as(usize, 2), lay.shown);
    try t.expectEqual([4]f64{ 16, 16, 328, 56 }, lay.header);
    // Two groups → headers: [H, A, H, B]. H = 16+56+34+26+48+26+48+10+40+14.
    try t.expectEqual(@as(f64, 318.0), lay.h);
    try t.expectEqual([4]f64{ 16, 318 - 14 - 40, 328, 40 }, lay.scan);
    const r0 = lay.items[1];
    try t.expect(!r0.header);
    try t.expect(r0.action[2] == 84.0);
    try t.expect(r0.forget[2] == 26.0);
    try t.expect(r0.battery[2] == 44.0);
    // Unpaired rows hide the forget button; unpaired action pills are narrow.
    // One group → no headers: the single device row is items[0].
    const solo = [_]Device{dev("/c", "C", .speaker, false, false, -1)};
    var lay2 = try buildPopupLayout(t.allocator, &snap, &solo, 1.0, popup_w, 218.0);
    defer freePopupLayout(t.allocator, &lay2);
    try t.expectEqual(@as(usize, 1), lay2.items.len);
    try t.expect(!lay2.items[0].header);
    try t.expect(lay2.items[0].forget[2] == 0.0);
    try t.expect(lay2.items[0].action[2] == 46.0);
}

test "bluetooth: clicks route to verbs" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator, "");
    defer loaded.deinit();
    const sc = &loaded.cfg;
    const devs = [_]Device{
        dev("/a", "A", .headphones, true, true, -1),
        dev("/b", "B", .mouse, true, false, -1),
    };
    const snap = Snapshot{ .available = true, .powered = true, .connected = true, .connected_count = 1 };
    // Outside closes.
    try t.expectEqual(Click.close, (try clickAction(t.allocator, sc, &snap, &devs, -1, 10)).click);
    // Toggle powers off and reopens.
    var lay = try buildPopupLayout(t.allocator, &snap, &devs, uiScale(sc), popup_w, try popupHeight(t.allocator, sc, &snap, &devs));
    defer freePopupLayout(t.allocator, &lay);
    const tg = try clickAction(t.allocator, sc, &snap, &devs, lay.toggle[0] + 1, lay.toggle[1] + 1);
    try t.expectEqual(Click.reopen, tg.click);
    try t.expectEqual(Verb.set_powered, tg.verb);
    try t.expect(!tg.power_on);
    // Connected row action disconnects.
    const r0 = lay.items[1];
    const dc = try clickAction(t.allocator, sc, &snap, &devs, r0.action[0] + 1, r0.action[1] + 1);
    try t.expectEqual(Click.redraw, dc.click);
    try t.expectEqual(Verb.disconnect, dc.verb);
    try t.expectEqual(@as(usize, 0), dc.index);
    // Paired row action connects (items are [H, A, H, B]).
    const r1 = lay.items[3];
    const cn = try clickAction(t.allocator, sc, &snap, &devs, r1.action[0] + 1, r1.action[1] + 1);
    try t.expectEqual(Click.redraw, cn.click);
    try t.expectEqual(Verb.connect, cn.verb);
    try t.expectEqual(@as(usize, 1), cn.index);
    // Forget button forgets.
    const fg = try clickAction(t.allocator, sc, &snap, &devs, r0.forget[0] + 1, r0.forget[1] + 1);
    try t.expectEqual(Verb.forget, fg.verb);
    // Scan footer toggles discovery.
    const sn = try clickAction(t.allocator, sc, &snap, &devs, lay.scan[0] + 1, lay.scan[1] + 1);
    try t.expectEqual(Click.reopen, sn.click);
    try t.expectEqual(Verb.start_discovery, sn.verb);
}

test "bluetooth: summarize counts and lifecycle flags" {
    const t = std.testing;
    const devs = [_]Device{
        dev("/a", "A", .headphones, true, true, 50),
        dev("/b", "B", .mouse, true, false, -1),
    };
    const snap = summarize(&devs, true, true, false);
    try t.expect(snap.powered and snap.connected);
    try t.expectEqual(@as(i32, 2), snap.paired_count);
    try t.expectEqual(@as(i32, 1), snap.connected_count);
    try t.expectEqualStrings("bluetooth", kindGlyph(.unknown));
    var loaded2 = try schema.loadText(t.allocator,
        \\[widget.bt]
        \\type = "bluetooth"
    );
    defer loaded2.deinit();
    try t.expect(widgetListContainsBluetooth(&loaded2.cfg, &.{"bt"}));
    try t.expect(!widgetListContainsBluetooth(&loaded2.cfg, &.{"media"}));
    // Lifecycle: init gates the poll, shutdown stops it.
    bluetoothWidgetInit();
    const p1 = bluetoothWidgetPoll(5000);
    try t.expect(p1.battery_refresh_due);
    markChanged(true);
    const p2 = bluetoothWidgetPoll(1001);
    try t.expect(p2.changed);
    try t.expect(bluetoothWidgetNeedsImmediateDraw(2000));
    try t.expect(!bluetoothWidgetNeedsImmediateDraw(2001));
    bluetoothWidgetShutdown();
    const p3 = bluetoothWidgetPoll(9000);
    try t.expect(!p3.changed);
    reset();
}

test "bluetooth: paint runs headless" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[widget.bt]
        \\show_label = "true"
    );
    defer loaded.deinit();
    const sc = &loaded.cfg;
    const devs = [_]Device{
        dev("/a", "WH-1000XM5", .headphones, true, true, 78),
        dev("/b", "MX Master 3S", .mouse, true, false, -1),
    };
    const snap = Snapshot{ .available = true, .powered = true, .connected = true, .connected_count = 1 };
    // Slot + popup painters tolerate a null context.
    paintBluetoothSlot(null, sc, "bt", 0, 0, 120, 40, 30.0, &snap, &devs, false, false);
    try paintPopup(t.allocator, null, sc, &snap, &devs, null);
    // Widths stay inside their clamps without a measuring context.
    const w = dockBluetoothSlotWidth(null, sc, "bt", 30.0, 100.0, &snap, &devs);
    try t.expect(w >= 30.0 * 1.25);
    // Real surface: everything paints without error.
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 360, 400);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintBluetoothSlot(cr, sc, "bt", 0, 0, 120, 40, 30.0, &snap, &devs, true, false);
    try paintPopup(t.allocator, cr, sc, &snap, &devs, .{ 300.0, 20.0 });
    const w2 = dockBluetoothSlotWidth(cr, sc, "bt", 30.0, 100.0, &snap, &devs);
    try t.expect(w2 >= 30.0 * 1.25);
}
