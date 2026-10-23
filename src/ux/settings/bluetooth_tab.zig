//! Settings ▸ Bluetooth tab — self-painting Page fed by live BlueZ
//! (`controlcenter/live_bluetooth.zig`), a direct port of
//! `src/ux/settings/settings_tab_bluetooth/settings_tab_bluetooth.cpp`.
//!
//! Three cards: ADAPTER (power + auto-reconnect toggles), DISCOVERY
//! (scan status + Scan/Stop pill) and DEVICES (sectioned live rows with
//! kind glyph, alias, battery, status line and Forget/action pills).
//! One sectioned plan drives paint, click and hover so the geometry can
//! never drift between the three passes — the C++ rule, kept.
//!
//! The page queries BlueZ synchronously (throttled to 500 ms); slow verbs (`Connect`/`Pair`) run in detached
//! threads via `live_bluetooth` and report back through the module-level
//! verb mailbox, which clears the row's spinner and surfaces failures in
//! the Discovery status line through the friendly-error map.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const live_bt = @import("../../desktop_shell/controlcenter/live_bluetooth.zig");
const bt_paint = @import("../../desktop_shell/widgets/bluetooth/bluetooth_paint.zig");

pub const tab_id: i32 = 47;

const k_content_top: i32 = common.content_top; // 16
const k_card_pad: i32 = common.card_pad; // 16
const k_card_gap: i32 = common.card_gap; // 12
const k_spacing_s: i32 = common.spacing_s; // 8
const k_spacing_xl: i32 = common.spacing_xl; // 24
const k_slider_row_h: i32 = common.slider_row_h; // 68

const k_dev_row_h: i32 = 64;
const k_power_card_h: i32 = 52 + 2 * k_slider_row_h + k_spacing_xl; // 212
const k_btn_row_h: i32 = 36;
const k_btn_h: i32 = 28;
const k_sec_h: i32 = 30;

const k_card_top: i32 = k_content_top; // 16
const k_body_top: i32 = k_card_top + 52; // 68
const k_power_card_top: i32 = k_card_top;
const k_scan_card_top: i32 = k_power_card_top + k_power_card_h + k_card_gap; // 240
const k_scan_body_top: i32 = k_scan_card_top + 52; // 292
const k_scan_card_h: i32 = 52 + k_btn_row_h + k_spacing_xl; // 112
const k_dev_card_top: i32 = k_scan_card_top + k_scan_card_h + k_card_gap; // 364
const k_dev_list_top: i32 = k_dev_card_top + 52; // 416

const k_toggle_w: i32 = 52;
const k_toggle_h: i32 = 26;
const k_scan_btn_w: i32 = 120;

/// Displayed rows are capped at 12 (paired/connected fill first, so scan
/// noise can never evict them); +3 section headers fits with room.
const k_max_rows: usize = 12;
const k_max_entries: usize = 16;

// ---------------------------------------------------------------------------
// Pure helpers (mirroring the C++ static helpers; all unit-tested)
// ---------------------------------------------------------------------------

/// Battery level → material glyph (the dock-widget ladder, shared).
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

pub fn batteryColor(pct: i32) struct { r: f64, g: f64, b: f64 } {
    if (pct <= 20) return .{ .r = 1.00, .g = 0.43, .b = 0.38 };
    if (pct <= 50) return .{ .r = 0.96, .g = 0.72, .b = 0.30 };
    return .{ .r = 0.45, .g = 0.85, .b = 0.50 };
}

/// RSSI → friendly signal quality (dBm numbers mean nothing to most users).
pub fn signalName(rssi: i16) []const u8 {
    if (rssi >= -60) return "Excellent";
    if (rssi >= -70) return "Good";
    if (rssi >= -80) return "Fair";
    return "Weak";
}

/// Display-order rank: in-flight/connected first, then remembered
/// (paired), then nearby unpaired.
pub fn rank(connected: bool, connecting: bool, paired: bool) u8 {
    if (connected or connecting) return 0;
    if (paired) return 1;
    return 2;
}

fn hasName(alias: []const u8, address: []const u8) bool {
    return alias.len > 0 and !std.mem.eql(u8, alias, address);
}

/// Primary action label per device state. Unpaired devices pair (BlueZ
/// rejects Connect for those); connecting rows get a disabled pill.
pub fn actionLabel(connected: bool, connecting: bool, paired: bool) []const u8 {
    if (connected) return "Disconnect";
    if (connecting) return "Connecting\u{2026}";
    if (paired) return "Connect";
    return "Pair";
}

/// Raw BlueZ D-Bus errors mean nothing to users ("org.bluez.Error.X").
/// Map the common ones to actionable one-liners; fall back to truncated
/// raw. `buf` receives the truncation (and the one long mapping).
pub fn friendlyError(buf: []u8, raw: []const u8) []const u8 {
    if (std.mem.indexOf(u8, raw, "AuthenticationRejected") != null)
        return std.fmt.bufPrint(buf, "Headphones refused pairing (not in pairing mode) \u{2014} hold them in pairing mode until the LED flashes, forget the PC on the buds if listed, Forget here, then Pair once.", .{}) catch raw;
    if (std.mem.indexOf(u8, raw, "AuthenticationFailed") != null)
        return "Authentication failed \u{2014} retry pairing with the device in pairing mode.";
    if (std.mem.indexOf(u8, raw, "AuthenticationCanceled") != null)
        return "Pairing canceled \u{2014} retry when ready.";
    if (std.mem.indexOf(u8, raw, "AlreadyExists") != null)
        return "Already paired \u{2014} use Connect instead of Pair.";
    if (std.mem.indexOf(u8, raw, "NotAvailable") != null)
        return "Device not available \u{2014} make sure it is powered and in range.";
    if (std.mem.indexOf(u8, raw, "Failed") != null and std.mem.indexOf(u8, raw, "Pair") != null)
        return "Pairing failed \u{2014} put the device in pairing mode and retry.";
    const n = @min(raw.len, buf.len, 96);
    @memcpy(buf[0..n], raw[0..n]);
    return buf[0..n];
}

/// Second-line status: kind, connection state, signal/last-used hints,
/// address. The address disambiguates same-name devices and aids
/// debugging. `extra_buf` is scratch for the composed hint.
pub fn statusText(
    buf: []u8,
    extra_buf: []u8,
    kind: []const u8,
    connected: bool,
    connecting: bool,
    paired: bool,
    has_rssi: bool,
    rssi: i16,
    address: []const u8,
    last_addr: []const u8,
) []const u8 {
    var extra: []const u8 = "";
    if (connected) {
        if (has_rssi) extra = std.fmt.bufPrint(extra_buf, " \u{b7} Signal {s}", .{signalName(rssi)}) catch "";
    } else if (connecting) {
        // no extra; "Connecting…" is the message
    } else if (paired) {
        const is_last = last_addr.len > 0 and std.mem.eql(u8, address, last_addr);
        if (is_last and has_rssi)
            extra = " \u{b7} Last used \u{b7} In range"
        else if (is_last)
            extra = " \u{b7} Last used"
        else if (has_rssi)
            extra = std.fmt.bufPrint(extra_buf, " \u{b7} In range \u{b7} Signal {s}", .{signalName(rssi)}) catch "";
    } else {
        if (has_rssi)
            extra = std.fmt.bufPrint(extra_buf, " \u{b7} Signal {s}", .{signalName(rssi)}) catch ""
        else
            extra = " \u{b7} Nearby";
    }
    const addr = if (address.len > 0) address else "?";
    if (connected)
        return std.fmt.bufPrint(buf, "{s} \u{b7} Connected{s} \u{b7} {s}", .{ kind, extra, addr }) catch "";
    if (connecting)
        return std.fmt.bufPrint(buf, "{s} \u{b7} Connecting\u{2026} \u{b7} {s}", .{ kind, addr }) catch "";
    if (paired)
        return std.fmt.bufPrint(buf, "{s} \u{b7} Paired{s} \u{b7} {s}", .{ kind, extra, addr }) catch "";
    return std.fmt.bufPrint(buf, "{s}{s} \u{b7} {s}", .{ kind, extra, addr }) catch "";
}

/// Adapter summary for the power-card description. An rfkill block is
/// called out explicitly: powering on and scanning both fail while
/// blocked, and without this the failure looks like a broken button.
pub fn adapterDesc(
    buf: []u8,
    available: bool,
    powered: bool,
    rf_soft: bool,
    rf_hard: bool,
    paired_count: i32,
    connected_count: i32,
) []const u8 {
    if (!available) return "No adapter found";
    if (rf_soft or rf_hard)
        return std.fmt.bufPrint(buf, "Blocked ({s}) \u{b7} run: rfkill unblock bluetooth", .{if (rf_hard) "hard block" else "soft block"}) catch "";
    if (powered)
        return std.fmt.bufPrint(buf, "Powered on \u{b7} {d} paired \u{b7} {d} connected", .{ paired_count, connected_count }) catch "";
    return std.fmt.bufPrint(buf, "Powered off \u{b7} {d} remembered", .{paired_count}) catch "";
}

/// Devices card cat label: plain "DEVICES", or the C++ `N OF M SHOWN`
/// flag when the page's row cap truncates the list (the C++ scrolls the
/// full list, so this only fires past `k_max_rows` devices).
pub fn devicesCatLabel(buf: []u8, shown: usize, total: usize) []const u8 {
    if (total > shown)
        return std.fmt.bufPrint(buf, "DEVICES \u{b7} {d} OF {d} SHOWN", .{ shown, total }) catch "DEVICES";
    return "DEVICES";
}

// ---------------------------------------------------------------------------
// Sectioned plan — shared by paint, click and hover
// ---------------------------------------------------------------------------

pub const Entry = struct {
    header: bool,
    label: []const u8,
    /// Index into the display-order list (not the row slice).
    dev: i32,
};

/// One device row for the paint/click/hover model. Strings borrow from
/// the page's last query.
pub const Row = struct {
    path: []const u8,
    address: []const u8,
    alias: []const u8,
    kind: bt_paint.DeviceKind,
    paired: bool,
    connected: bool,
    connecting: bool,
    has_rssi: bool,
    rssi: i16,
    /// -1 when the device reports no battery.
    battery_pct: i32,
};

/// Rank comparator: group order first, named devices before MAC-only
/// beacons within the nearby group. The index tiebreak keeps the sort
/// stable, matching `std::stable_sort` in the C++.
fn rowBefore(a: Row, b: Row, ai: usize, bi: usize) bool {
    const ra = rank(a.connected, a.connecting, a.paired);
    const rb = rank(b.connected, b.connecting, b.paired);
    if (ra != rb) return ra < rb;
    if (ra == 2) {
        const na = hasName(a.alias, a.address);
        const nb = hasName(b.alias, b.address);
        if (na != nb) return na;
    }
    return ai < bi;
}

/// Sort row indices into display order (`bt_tab_ordered_devices`).
pub fn orderRows(alloc: std.mem.Allocator, rows_in: []const Row) ![]u32 {
    const idx = try alloc.alloc(u32, rows_in.len);
    errdefer alloc.free(idx);
    for (rows_in, 0..) |_, i| idx[i] = @intCast(i);
    // Insertion sort — device lists are tiny and this stays stable.
    var i: usize = 1;
    while (i < idx.len) : (i += 1) {
        const cur = idx[i];
        var j: usize = i;
        while (j > 0 and rowBefore(rows_in[cur], rows_in[idx[j - 1]], cur, idx[j - 1])) : (j -= 1) {
            idx[j] = idx[j - 1];
        }
        idx[j] = cur;
    }
    return idx;
}

/// Split the ordered list into CONNECTED / REMEMBERED DEVICES / NEARBY
/// DEVICES groups (headers only when more than one group is present).
/// `out` receives header+row entries; the return is the count.
pub fn planRows(out: []Entry, ordered: []const u32, rows: []const Row) usize {
    var n: usize = 0;
    var has = [3]bool{ false, false, false };
    for (ordered) |i| {
        has[rank(rows[i].connected, rows[i].connecting, rows[i].paired)] = true;
    }
    const groups: u8 = @as(u8, @intFromBool(has[0])) +
        @as(u8, @intFromBool(has[1])) +
        @as(u8, @intFromBool(has[2]));
    const show_headers = groups > 1;
    var last_rank: i32 = -1;
    for (ordered, 0..) |_, ord| {
        const i = ordered[ord];
        const r: i32 = @intCast(rank(rows[i].connected, rows[i].connecting, rows[i].paired));
        if (show_headers and r != last_rank) {
            if (n < out.len) {
                out[n] = .{
                    .header = true,
                    .label = if (r == 0) "CONNECTED" else if (r == 1) "REMEMBERED DEVICES" else "NEARBY DEVICES",
                    .dev = -1,
                };
                n += 1;
            }
            last_rank = r;
        }
        if (n < out.len) {
            out[n] = .{ .header = false, .label = "", .dev = @intCast(ord) };
            n += 1;
        }
    }
    return n;
}

/// Scroll/clip extent of the device-list content: 60 when empty (the
/// C++ empty-card slack), else 24 + rows and headers.
pub fn contentHeight(plan: []const Entry) i32 {
    if (plan.len == 0) return 60;
    var h: i32 = k_spacing_xl;
    for (plan) |e| h += if (e.header) k_sec_h else k_dev_row_h;
    return h;
}

// ---------------------------------------------------------------------------
// Actions — returned to the window, which owns `Settings` and persistence
// ---------------------------------------------------------------------------

pub const Action = union(enum) {
    /// Backend work happened in the page; repaint is all that is needed.
    repaint,
    /// Power toggle (the page already ran the BlueZ write).
    toggle_power,
    /// Persist `bt_auto_reconnect` (the page already flipped its snap).
    toggle_reconnect,
    /// Scan/stop discovery (the page already issued the verb).
    toggle_scan,
    /// Forget the device at this display-order index (page ran RemoveDevice).
    forget: usize,
    /// Connect/Disconnect/Pair the device at this display-order index
    /// (page started the verb).
    verb: usize,
};

/// Content-column geometry, passed in rather than read from `Content` so
/// this module stays free of a cycle back into `ui_content`.
pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

fn inRect(px: f64, py: f64, x: i32, y: i32, w: i32, h: i32) bool {
    return common.pointInRect(px, py, .{ .x = x, .y = y, .w = w, .h = h });
}

/// Append a formatted chunk to a fixed buffer at offset `n`, advancing it.
/// Returns false on overflow (`std.io.fixedBufferStream` is gone in this
/// toolchain; `bufPrint` into the remaining slice gives the same truncation).
fn appendFmt(buf: []u8, n: *usize, comptime fmt: []const u8, args: anytype) bool {
    const out = std.fmt.bufPrint(buf[n.*..], fmt, args) catch return false;
    n.* += out.len;
    return true;
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    inited: bool = false,

    // --- live state (refreshed from BlueZ, throttled) ------
    have_query: bool = false,
    last_query_ms: i64 = 0,
    powered: bool = false,
    available: bool = false,
    scanning: bool = false,
    rf_soft: bool = false,
    rf_hard: bool = false,
    adapter_path: []const u8 = "",
    paired_count: i32 = 0,
    connected_count: i32 = 0,
    /// Full device-list length (the page caps rows at `k_max_rows` while the
    /// C++ scrolls everything — the cat label flags the truncation).
    total_count: i32 = 0,

    /// Rows for this frame; strings borrow `last_q` (or `debug_devs`).
    rows: [k_max_rows]Row = undefined,
    rows_len: usize = 0,
    /// Display-order indices into `rows`.
    order: [k_max_rows]u32 = undefined,
    order_len: usize = 0,
    /// Sectioned plan (labels are literals; `dev` indexes `order`).
    entries: [k_max_entries]Entry = undefined,
    entries_len: usize = 0,

    /// The raw query backing `rows` (its strings live here).
    last_q: ?live_bt.Queried = null,
    /// `EH_BLUETOOTH_DEBUG` fixture devices, owned while active.
    debug_devs: ?[]bt_paint.Device = null,

    /// A Connect/Pair verb is in flight for this path (spinner + disabled
    /// pill), with a deadline so a lost worker cannot wedge the row.
    busy_path: [128]u8 = undefined,
    busy_path_len: u16 = 0,
    busy_deadline_ms: i64 = 0,
    /// Last seen verb-mailbox sequence.
    verb_seq: u64 = 0,

    /// Last verb error (raw BlueZ text), shown in the Discovery status
    /// line until it ages out after 2 minutes.
    err_buf: [256]u8 = undefined,
    err_len: u16 = 0,
    err_ms: i64 = 0,

    /// `last_connected` from the memory file, updated when a Connect
    /// settles — drives the "Last used" hint and the auto-reconnect desc.
    last_addr: [24]u8 = undefined,
    last_addr_len: u8 = 0,
    /// `ever_connected` addresses preserved across saves (the dock's
    /// future auto-reconnect reads them).
    ever: [8][24]u8 = undefined,
    ever_lens: [8]u8 = undefined,
    ever_len: usize = 0,

    /// `bt_auto_reconnect`, borrowed from Settings each frame.
    auto_reconnect: bool = true,

    /// Hovered device row (display-order index), -1 when none — the
    /// page's own `settingsBluetoothHoverRow`.
    hover_row: i32 = -1,

    pub fn init(self: *Page, alloc: std.mem.Allocator, io: std.Io) void {
        self.* = .{};
        self.alloc = alloc;
        self.io = io;
        self.inited = true;
        self.loadMemory();
        self.refresh(true);
    }

    pub fn deinit(self: *Page) void {
        if (!self.inited) return;
        self.freeSources();
        self.inited = false;
    }

    fn freeSources(self: *Page) void {
        if (self.last_q) |*q| {
            q.deinit();
            self.last_q = null;
        }
        if (self.debug_devs) |d| {
            self.alloc.free(d);
            self.debug_devs = null;
        }
        self.adapter_path = "";
        self.rows_len = 0;
        self.order_len = 0;
        self.entries_len = 0;
        self.total_count = 0;
    }

    /// Borrow this frame's auto-reconnect flag (the window syncs it from
    /// `Settings` before the frame).
    pub fn sync(self: *Page, auto_reconnect: bool) void {
        self.auto_reconnect = auto_reconnect;
    }

    /// `refresh_if_needed` — a live query at most every 500 ms unless
    /// forced (first paint, or after a verb wrote to BlueZ).
    pub fn refresh(self: *Page, force: bool) void {
        if (!force and self.have_query and bt_paint.nowMs() - self.last_query_ms < 500) return;
        self.last_query_ms = bt_paint.nowMs();
        self.pollVerbResult();
        self.freeSources();

        if (std.c.getenv("EH_BLUETOOTH_DEBUG") != null) {
            self.refreshDebug();
        } else {
            self.refreshLive();
        }

        self.rebuildOrder();
    }

    fn refreshLive(self: *Page) void {
        const q = live_bt.query(self.alloc) orelse {
            // BlueZ did not answer: no adapter, no devices.
            self.available = false;
            self.powered = false;
            self.scanning = false;
            return;
        };
        self.last_q = q;
        self.have_query = true;
        self.available = q.snap.adapter_path.len > 0;
        self.powered = q.snap.powered;
        self.scanning = q.snap.discovering;
        self.adapter_path = q.snap.adapter_path;
        const rf = live_bt.rfkillBlocked(self.io, self.alloc);
        self.rf_soft = rf.soft;
        self.rf_hard = rf.hard;

        // Adapter summary counts over the full device list (the C++ counts
        // every device, not just the rows that fit the cap).
        self.paired_count = 0;
        self.connected_count = 0;
        self.total_count = @intCast(q.device_list.items.len);
        for (q.device_list.items) |*d| {
            if (d.paired) self.paired_count += 1;
            if (d.connected) self.connected_count += 1;
        }

        // Pass 1: connected or paired — a scan flood of anonymous beacons
        // must never evict the devices the user cares about. Pass 2 fills
        // the rest up to the row cap.
        self.fillRows(q.device_list.items);
    }

    /// Two-pass row fill with paired/connected priority (shared core of the
    /// live refresh; unit-tested below with adversarial walk order).
    fn fillRows(self: *Page, items: []const live_bt.Device) void {
        for (items) |*d| {
            if (!d.connected and !d.paired) continue;
            self.pushLiveRow(d);
        }
        for (items) |*d| {
            if (d.connected or d.paired) continue;
            self.pushLiveRow(d);
        }
    }

    /// One live-query device into the row list (shared by both fill passes).
    fn pushLiveRow(self: *Page, d: *const live_bt.Device) void {
        if (self.rows_len >= k_max_rows) return;
        const kind = blk: {
            const by_icon = bt_paint.classifyIcon(d.icon);
            if (by_icon != .unknown) break :blk by_icon;
            if (d.has_class) break :blk bt_paint.classifyClass(d.class_code);
            break :blk .unknown;
        };
        self.pushRow(d.path, d.address, d.alias, kind, d.paired, d.connected, d.rssi != 0, d.rssi, d.battery_pct);
    }

    /// One row into the list (cap enforced). Strings borrow the query.
    fn pushRow(
        self: *Page,
        path: []const u8,
        address: []const u8,
        alias: []const u8,
        kind: bt_paint.DeviceKind,
        paired: bool,
        connected: bool,
        has_rssi: bool,
        rssi: i16,
        battery_pct: i32,
    ) void {
        if (self.rows_len >= k_max_rows) return;
        self.rows[self.rows_len] = .{
            .path = path,
            .address = address,
            .alias = alias,
            .kind = kind,
            .paired = paired,
            .connected = connected,
            .connecting = !connected and self.busyFor(path),
            .has_rssi = has_rssi,
            .rssi = rssi,
            .battery_pct = battery_pct,
        };
        self.rows_len += 1;
    }

    /// Debug fixtures (`EH_BLUETOOTH_DEBUG`) — the same canned states the
    /// dock widget honours, so the tab can be exercised without hardware.
    fn refreshDebug(self: *Page) void {
        const mode = bt_paint.debugMode() orelse {
            self.available = false;
            return;
        };
        const snap = bt_paint.debugSnapshot(mode);
        const devs = bt_paint.debugDevices(self.alloc, mode) catch {
            self.available = false;
            return;
        };
        self.debug_devs = devs;
        self.have_query = true;
        self.available = snap.available;
        self.powered = snap.powered;
        self.scanning = snap.scanning;
        self.adapter_path = if (snap.available) "/org/bluez/hci0" else "";
        self.rf_soft = false;
        self.rf_hard = false;
        self.paired_count = snap.paired_count;
        self.connected_count = snap.connected_count;
        self.total_count = @intCast(devs.len);

        for (devs) |*d| {
            self.pushRow(d.path, d.address, d.alias, d.kind, d.paired, d.connected, false, 0, d.battery_pct);
        }
    }

    /// Is a verb still in flight for `path` (within its deadline)? An
    /// expired slot is cleared so the row cannot wedge.
    fn busyFor(self: *Page, path: []const u8) bool {
        if (self.busy_path_len == 0) return false;
        if (bt_paint.nowMs() > self.busy_deadline_ms) {
            self.busy_path_len = 0;
            return false;
        }
        return std.mem.eql(u8, self.busy_path[0..self.busy_path_len], path);
    }

    fn setBusy(self: *Page, path: []const u8, deadline_ms: i64) void {
        const n = @min(path.len, self.busy_path.len);
        @memcpy(self.busy_path[0..n], path[0..n]);
        self.busy_path_len = @intCast(n);
        self.busy_deadline_ms = bt_paint.nowMs() + deadline_ms;
    }

    /// Consume a completed async verb: clear the spinner for its path,
    /// record a failure, and remember a successful Connect's address.
    fn pollVerbResult(self: *Page) void {
        const r = live_bt.pollVerbResult(self.verb_seq) orelse return;
        self.verb_seq = r.seq;
        if (self.busy_path_len == r.path_len and
            std.mem.eql(u8, self.busy_path[0..self.busy_path_len], r.path[0..r.path_len]))
        {
            self.busy_path_len = 0;
        }
        if (!r.ok) {
            if (r.err_len > 0) self.setErr(r.err[0..r.err_len]);
            return;
        }
        if (std.mem.eql(u8, r.verb[0..r.verb_len], "Connect")) {
            // `mark_connected_locked` parity: remember which device was
            // last connected for the "Last used" hint.
            for (self.rows_()) |*row| {
                if (std.mem.eql(u8, row.path, r.path[0..r.path_len])) {
                    self.rememberConnected(row.address);
                    break;
                }
            }
        }
    }

    fn setErr(self: *Page, raw: []const u8) void {
        const n = @min(raw.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], raw[0..n]);
        self.err_len = @intCast(n);
        self.err_ms = bt_paint.nowMs();
    }

    /// The last verb error, or empty once it has aged out (2 minutes).
    fn lastErr(self: *Page) []const u8 {
        if (self.err_len == 0) return "";
        if (bt_paint.nowMs() - self.err_ms > 120_000) {
            self.err_len = 0;
            return "";
        }
        return self.err_buf[0..self.err_len];
    }

    /// The memory file's `last_connected` address, or empty.
    pub fn lastConnected(self: *const Page) []const u8 {
        return self.last_addr[0..self.last_addr_len];
    }

    fn rows_(self: *Page) []Row {
        return self.rows[0..self.rows_len];
    }

    fn rebuildOrder(self: *Page) void {
        const rows = self.rows_();
        if (rows.len > k_max_rows) {
            self.order_len = 0;
            self.entries_len = 0;
            return;
        }
        // Stable display order (insertion sort on the tiny index list).
        var i: usize = 0;
        while (i < rows.len) : (i += 1) self.order[i] = @intCast(i);
        i = 1;
        while (i < rows.len) : (i += 1) {
            const cur = self.order[i];
            var j: usize = i;
            while (j > 0 and rowBefore(rows[cur], rows[self.order[j - 1]], cur, self.order[j - 1])) : (j -= 1) {
                self.order[j] = self.order[j - 1];
            }
            self.order[j] = cur;
        }
        self.order_len = rows.len;

        const ordered = self.order[0..self.order_len];
        self.entries_len = planRows(&self.entries, ordered, rows);
        // NOTE: paired/connected/total counts stay as refreshLive /
        // refreshDebug set them over the FULL list (the C++ service-walk
        // counts) — they must not be re-derived from the capped rows.
    }

    /// Page-coordinate bottom of the tab (follows the paint-pass card
    /// stack) so the scroll clamp knows the true extent once the list is
    /// uncapped — `bluetooth_tab_content_bottom`.
    pub fn totalHeight(self: *Page, g: Geo) i32 {
        _ = g;
        if (!self.inited) return 0;
        // The extent must reflect the live list even before the first
        // paint of a frame; throttled, so this is at most one query per
        // 500 ms like everything else here.
        self.refresh(false);
        const bottom = k_dev_card_top + 52 + contentHeight(self.entries[0..self.entries_len]);
        return @max(0, bottom - k_content_top + 12);
    }

    // -----------------------------------------------------------------
    // Memory file (`~/.local/state/event-horizon/bluetooth/bluetooth.toml`)
    // -----------------------------------------------------------------

    /// The C++ BluezService memory path: `last_connected` drives the
    /// "Last used" hint and the auto-reconnect description.
    fn memoryPath(buf: []u8) ?[]const u8 {
        if (std.c.getenv("XDG_STATE_HOME")) |x| {
            const s = std.mem.span(x);
            if (s.len > 0)
                return std.fmt.bufPrint(buf, "{s}/event-horizon/bluetooth/bluetooth.toml", .{s}) catch null;
        }
        const home = std.c.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(
            buf,
            "{s}/.local/state/event-horizon/bluetooth/bluetooth.toml",
            .{std.mem.span(home)},
        ) catch null;
    }

    fn loadMemory(self: *Page) void {
        var path_buf: [512]u8 = undefined;
        const path = memoryPath(&path_buf) orelse return;
        const cwd = std.Io.Dir.cwd();
        const data = cwd.readFileAlloc(self.io, path, self.alloc, .limited(1 << 16)) catch return;
        defer self.alloc.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line_s| {
            const line = std.mem.trim(u8, line_s, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.startsWith(u8, line, "last_connected")) {
                if (quotedValue(line)) |addr| {
                    const n = @min(addr.len, self.last_addr.len);
                    @memcpy(self.last_addr[0..n], addr[0..n]);
                    self.last_addr_len = @intCast(n);
                }
            } else if (std.mem.startsWith(u8, line, "ever_connected")) {
                // Every quoted item on the line is an address.
                var pos: usize = 0;
                self.ever_len = 0;
                while (self.ever_len < self.ever.len) : (pos = if (std.mem.indexOfScalarPos(u8, line, pos, '"')) |q| q + 1 else break) {
                    const q1 = std.mem.indexOfScalarPos(u8, line, pos, '"') orelse break;
                    const q2 = std.mem.indexOfScalarPos(u8, line, q1 + 1, '"') orelse break;
                    if (q2 <= q1 + 1) break;
                    const addr = line[q1 + 1 .. q2];
                    const n = @min(addr.len, self.ever[self.ever_len].len);
                    @memcpy(self.ever[self.ever_len][0..n], addr[0..n]);
                    self.ever_lens[self.ever_len] = @intCast(n);
                    self.ever_len += 1;
                }
            }
        }
    }

    /// First `"…"` value on a `key = "value"` line.
    fn quotedValue(line: []const u8) ?[]const u8 {
        const q1 = std.mem.indexOfScalar(u8, line, '"') orelse return null;
        const q2 = std.mem.indexOfScalarPos(u8, line, q1 + 1, '"') orelse return null;
        if (q2 <= q1 + 1) return null;
        return line[q1 + 1 .. q2];
    }

    /// `mark_connected_locked` + `save_persisted_state_locked`: record the
    /// address a Connect settled on, appending it to `ever_connected`, so
    /// "Last used" and the dock's auto-reconnect can see it.
    fn rememberConnected(self: *Page, address: []const u8) void {
        if (address.len == 0) return;
        const n = @min(address.len, self.last_addr.len);
        @memcpy(self.last_addr[0..n], address[0..n]);
        self.last_addr_len = @intCast(n);
        var seen = false;
        for (self.ever[0..self.ever_len], 0..) |*e, i| {
            if (std.mem.eql(u8, e[0..self.ever_lens[i]], address)) {
                seen = true;
                break;
            }
        }
        if (!seen and self.ever_len < self.ever.len) {
            const m = @min(address.len, self.ever[self.ever_len].len);
            @memcpy(self.ever[self.ever_len][0..m], address[0..m]);
            self.ever_lens[self.ever_len] = @intCast(m);
            self.ever_len += 1;
        }
        self.saveMemory();
    }

    fn saveMemory(self: *Page) void {
        var path_buf: [512]u8 = undefined;
        const path = memoryPath(&path_buf) orelse return;
        var out_buf: [1024]u8 = undefined;
        var n: usize = 0;
        if (!appendFmt(&out_buf, &n, "# Event Horizon Bluetooth memory (auto-generated)\n", .{})) return;
        if (!appendFmt(&out_buf, &n, "last_connected = \"{s}\"\n", .{self.last_addr[0..self.last_addr_len]})) return;
        if (!appendFmt(&out_buf, &n, "ever_connected = [", .{})) return;
        for (self.ever[0..self.ever_len], 0..) |*e, i| {
            if (i > 0 and !appendFmt(&out_buf, &n, ", ", .{})) return;
            if (!appendFmt(&out_buf, &n, "\"{s}\"", .{e[0..self.ever_lens[i]]})) return;
        }
        if (!appendFmt(&out_buf, &n, "]\n", .{})) return;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(self.io, dir) catch {};
        cwd.writeFile(self.io, .{ .sub_path = path, .data = out_buf[0..n] }) catch {};
    }

    // -----------------------------------------------------------------
    // Paint
    // -----------------------------------------------------------------

    pub fn paint(
        self: *Page,
        cr: ?*cairo.cairo_t,
        g: Geo,
        px: f64,
        ly: f64,
        glass_ov: f64,
    ) void {
        const c = cr orelse return;
        if (!self.inited) return;
        self.refresh(false);
        self.updateHover(g, px, ly);

        const t = common.Theme;
        const cx: i32 = g.content_x + 8;
        const cw: i32 = g.content_w - 16;
        const card_x: f64 = @floatFromInt(cx);
        const card_w: f64 = @floatFromInt(cw);

        // --- Power card (ADAPTER) ---------------------------------------
        var desc_buf: [192]u8 = undefined;
        const bt_desc = adapterDesc(
            &desc_buf,
            self.available,
            self.powered,
            self.rf_soft,
            self.rf_hard,
            self.paired_count,
            self.connected_count,
        );
        ui_paint.card(c, card_x, @floatFromInt(k_power_card_top), card_w, @floatFromInt(k_power_card_h), glass_ov);
        ui_paint.catLabel(c, card_x + k_card_pad, k_power_card_top + 22, "ADAPTER");
        var y: i32 = k_body_top;
        ui_paint.settingLabel(c, card_x + k_card_pad, @floatFromInt(y), "Bluetooth", bt_desc);
        ui_paint.paintSwitch(
            c,
            cx + cw - k_toggle_w - k_spacing_xl,
            y - 20,
            k_toggle_w,
            k_toggle_h,
            self.available and self.powered,
        );
        y += k_slider_row_h;

        // Auto-reconnect description names the remembered device so the
        // memory is visible instead of a vague promise.
        var recon_buf: [192]u8 = undefined;
        const recon_desc: []const u8 = blk: {
            const last = self.lastConnected();
            if (last.len == 0) break :blk "Reconnect devices you have used before when they are in range";
            var last_name: []const u8 = last;
            for (self.rows_()) |*r| {
                if (std.mem.eql(u8, r.address, last) and r.alias.len > 0) {
                    last_name = r.alias;
                    break;
                }
            }
            break :blk std.fmt.bufPrint(
                &recon_buf,
                "Reconnect {s} and other used devices when in range",
                .{last_name},
            ) catch "Reconnect devices you have used before when they are in range";
        };
        ui_paint.settingLabel(c, card_x + k_card_pad, @floatFromInt(y), "Auto-reconnect", recon_desc);
        ui_paint.paintSwitch(
            c,
            cx + cw - k_toggle_w - k_spacing_xl,
            y - 20,
            k_toggle_w,
            k_toggle_h,
            self.auto_reconnect,
        );

        if (!self.available) return;

        // --- Discovery card ---------------------------------------------
        ui_paint.card(c, card_x, @floatFromInt(k_scan_card_top), card_w, @floatFromInt(k_scan_card_h), glass_ov);
        ui_paint.catLabel(c, card_x + k_card_pad, k_scan_card_top + 22, "DISCOVERY");

        const btn_x = cx + cw - k_scan_btn_w - k_card_pad;
        const btn_y = k_scan_body_top;

        // Left-side status: error (red) > powered-off hint > scanning >
        // empty > counts.
        {
            const status_max_w: f64 = @floatFromInt(@max(24, btn_x - 10 - (cx + k_card_pad)));
            const status_y: f64 = @floatFromInt(k_scan_body_top + 20);
            const err = self.lastErr();
            if (err.len > 0) {
                var fb: [512]u8 = undefined;
                const short_err = friendlyError(&fb, err);
                ui_paint.showTextW(c, card_x + k_card_pad, status_y, short_err, 12, 400, status_max_w, 1.00, 0.43, 0.38, 0.92);
            } else if (!self.powered) {
                ui_paint.showTextW(c, card_x + k_card_pad, status_y, "Turn Bluetooth on to scan", 12, 400, status_max_w, t.text_r, t.text_g, t.text_b, 0.55);
            } else if (self.scanning) {
                ui_paint.showTextW(c, card_x + k_card_pad, status_y, "Scanning for devices\u{2026}", 12, 400, status_max_w, t.text_r, t.text_g, t.text_b, 0.75);
            } else if (self.rows_len == 0) {
                ui_paint.showTextW(c, card_x + k_card_pad, status_y, "Scan to find nearby devices", 12, 400, status_max_w, t.text_r, t.text_g, t.text_b, 0.55);
            } else {
                var found_buf: [64]u8 = undefined;
                const found = std.fmt.bufPrint(
                    &found_buf,
                    "{d} device{s} found \u{b7} scan for more",
                    .{ self.rows_len, if (self.rows_len == 1) "" else "s" },
                ) catch "";
                ui_paint.showTextW(c, card_x + k_card_pad, status_y, found, 12, 400, status_max_w, t.text_r, t.text_g, t.text_b, 0.55);
            }
        }

        const scan_lbl: []const u8 = if (self.scanning) "Stop scan" else "Scan";
        const scan_hov = inRect(px, ly, btn_x, btn_y, k_scan_btn_w, k_btn_h);
        if (self.powered) {
            ui_paint.paintBtn(c, btn_x, btn_y, k_scan_btn_w, k_btn_h, scan_lbl, scan_hov);
        } else {
            ui_paint.paintBtnDisabled(c, btn_x, btn_y, k_scan_btn_w, k_btn_h, scan_lbl);
        }

        // --- Devices card -----------------------------------------------
        const plan = self.entries[0..self.entries_len];
        const dev_content_h: i32 = if (self.powered) contentHeight(plan) else 60;
        const dev_card_h: i32 = 52 + dev_content_h;
        ui_paint.card(c, card_x, @floatFromInt(k_dev_card_top), card_w, @floatFromInt(dev_card_h), glass_ov);
        var devcat_buf: [64]u8 = undefined;
        ui_paint.catLabel(c, card_x + k_card_pad, k_dev_card_top + 22, devicesCatLabel(
            &devcat_buf,
            self.rows_len,
            @as(usize, @intCast(@max(self.total_count, 0))),
        ));

        if (!self.powered) {
            ui_paint.showText(c, card_x + k_card_pad, k_dev_list_top + 24, "Bluetooth is off \u{2014} turn it on to manage devices", 13, 400, t.text_r, t.text_g, t.text_b, 0.42);
        } else if (plan.len == 0) {
            const empty_msg: []const u8 = if (self.scanning)
                "Scanning for devices..."
            else
                "No devices found \u{2014} scan to discover nearby devices";
            ui_paint.showText(c, card_x + k_card_pad, k_dev_list_top + 24, empty_msg, 13, 400, t.text_r, t.text_g, t.text_b, 0.42);
        } else {
            cairo.cairo_save(c);
            cairo.cairo_rectangle(
                c,
                card_x,
                @floatFromInt(k_dev_list_top),
                card_w,
                @floatFromInt(dev_card_h - 52),
            );
            cairo.cairo_clip(c);

            var cursor_y: i32 = k_dev_list_top;
            for (plan) |entry| {
                if (entry.header) {
                    ui_paint.showText(
                        c,
                        card_x + k_card_pad,
                        @as(f64, @floatFromInt(cursor_y)) + @as(f64, @floatFromInt(k_sec_h)) * 0.5 + 4.0,
                        entry.label,
                        10,
                        700,
                        t.text_r,
                        t.text_g,
                        t.text_b,
                        0.42,
                    );
                    cursor_y += k_sec_h;
                    continue;
                }
                const row = self.rows[self.order[@intCast(entry.dev)]];
                const row_y = cursor_y;
                cursor_y += k_dev_row_h;

                if (entry.dev == self.hover_row) {
                    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.05);
                    cairo.cairo_rectangle(c, card_x, @floatFromInt(row_y), card_w, @floatFromInt(k_dev_row_h));
                    cairo.cairo_fill(c);
                }

                // Device type glyph (amber while an operation is in flight).
                var g_r = t.text_r;
                var g_g = t.text_g;
                var g_b = t.text_b;
                var g_a: f64 = 0.80;
                if (row.connecting) {
                    g_r = 0.96;
                    g_g = 0.72;
                    g_b = 0.30;
                    g_a = 0.95;
                }
                ui_paint.glyph(
                    c,
                    card_x + k_card_pad + 14.0,
                    @as(f64, @floatFromInt(row_y)) + @as(f64, @floatFromInt(k_dev_row_h)) * 0.5,
                    18.0,
                    bt_paint.kindGlyph(row.kind),
                    g_r,
                    g_g,
                    g_b,
                    g_a,
                );

                // Action buttons, right-aligned and vertically centred.
                // Sized from the measured label (the m3 auto-expand rule
                // from the C++) so the painted pills and the hit rects
                // agree.
                const act_h: i32 = 24;
                const act_y: i32 = row_y + @divTrunc(k_dev_row_h - act_h, 2);
                var act_x: i32 = cx + cw - k_card_pad - k_spacing_s;
                var btn_area_left: i32 = act_x;

                // Forget clears the BlueZ object even when unpaired: a
                // stale cached device (bond lost, headphones still holding
                // the old key) can only be re-paired after RemoveDevice.
                // Hidden only while an op is in flight.
                if (!row.connecting) {
                    const forget_w = settingsBtnW("Forget");
                    act_x -= forget_w;
                    btn_area_left = act_x;
                    const fov = inRect(px, ly, act_x, act_y, forget_w, act_h);
                    ui_paint.paintBtn(c, act_x, act_y, forget_w, act_h, "Forget", fov);
                    // C++ steps 10px left between the pills (the initial
                    // right inset stays kSpacingS).
                    act_x -= 10;
                }
                {
                    const lbl = actionLabel(row.connected, row.connecting, row.paired);
                    const conn_w = settingsBtnW(lbl);
                    act_x -= conn_w;
                    btn_area_left = @min(btn_area_left, act_x);
                    const cov = !row.connecting and inRect(px, ly, act_x, act_y, conn_w, act_h);
                    if (row.connecting) {
                        ui_paint.paintBtnDisabled(c, act_x, act_y, conn_w, act_h, lbl);
                    } else {
                        ui_paint.paintBtn(c, act_x, act_y, conn_w, act_h, lbl, cov);
                    }
                }

                // Device alias + battery — the level sits inline, right
                // after the name.
                const alias_x = card_x + k_card_pad + 40.0;
                const alias_max_w = @max(24.0, @as(f64, @floatFromInt(btn_area_left)) - 10.0 - alias_x);
                const name_baseline = @as(f64, @floatFromInt(row_y)) + 26.0;
                if (row.battery_pct >= 0) {
                    var bat_buf: [8]u8 = undefined;
                    const bat_txt = std.fmt.bufPrint(&bat_buf, "{d}%", .{row.battery_pct}) catch "";
                    const bat_txt_w: f64 = @floatFromInt(ui_paint.textWidthPx(c, bat_txt, 11, 400));
                    const bat_block_w = 8.0 + 14.0 + 4.0 + bat_txt_w; // gap icon gap text
                    const name_w = @max(24.0, alias_max_w - bat_block_w);
                    ui_paint.showTextW(c, alias_x, name_baseline, row.alias, 14, 400, name_w, t.text_r, t.text_g, t.text_b, 0.93);
                    const alias_w: f64 = @floatFromInt(ui_paint.textWidthPx(c, row.alias, 14, 400));
                    const drawn_name_w = @min(alias_w, name_w);
                    const bat = batteryColor(row.battery_pct);
                    ui_paint.glyph(
                        c,
                        alias_x + drawn_name_w + 8.0 + 7.0,
                        name_baseline - 7.0,
                        14.0,
                        batteryGlyph(row.battery_pct),
                        bat.r,
                        bat.g,
                        bat.b,
                        0.92,
                    );
                    ui_paint.showText(
                        c,
                        alias_x + drawn_name_w + 8.0 + 14.0 + 4.0,
                        name_baseline,
                        bat_txt,
                        11,
                        400,
                        bat.r,
                        bat.g,
                        bat.b,
                        0.92,
                    );
                } else {
                    ui_paint.showTextW(c, alias_x, name_baseline, row.alias, 14, 400, alias_max_w, t.text_r, t.text_g, t.text_b, 0.93);
                }

                // Kind + state + signal/last-used + address.
                var status_buf: [192]u8 = undefined;
                var extra_buf: [96]u8 = undefined;
                const status = statusText(
                    &status_buf,
                    &extra_buf,
                    bt_paint.kindName(row.kind),
                    row.connected,
                    row.connecting,
                    row.paired,
                    row.has_rssi,
                    row.rssi,
                    row.address,
                    self.lastConnected(),
                );
                if (row.connecting)
                    ui_paint.showTextW(c, card_x + k_card_pad + 40.0, @as(f64, @floatFromInt(row_y)) + 48, status, 11, 400, alias_max_w, 0.96, 0.72, 0.30, 0.85)
                else
                    ui_paint.showTextW(c, card_x + k_card_pad + 40.0, @as(f64, @floatFromInt(row_y)) + 48, status, 11, 400, alias_max_w, t.text_r, t.text_g, t.text_b, 0.46);
            }
            cairo.cairo_restore(c);
        }
    }

    /// `bt_tab_hover_row` — display-order index under the pointer, -1
    /// outside the list. Driven from the shared sectioned plan so it can
    /// never drift from what the paint pass draws.
    fn updateHover(self: *Page, g: Geo, px: f64, ly: f64) void {
        const cx: i32 = g.content_x + 8;
        self.hover_row = -1;
        var y: i32 = k_dev_list_top;
        for (self.entries[0..self.entries_len]) |entry| {
            if (entry.header) {
                y += k_sec_h;
                continue;
            }
            // C++ hover rect: `cardX + kCardPad`, `contentW - 4*kCardPad`.
            if (inRect(px, ly, cx + k_card_pad, y, g.content_w - 4 * k_card_pad, k_dev_row_h)) {
                self.hover_row = entry.dev;
                return;
            }
            y += k_dev_row_h;
        }
    }

    // -----------------------------------------------------------------
    // Hit test (geometry matches the paint pass)
    // -----------------------------------------------------------------

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        if (!self.inited) return null;
        const cx: i32 = g.content_x + 8;
        const cw: i32 = g.content_w - 16;

        // Power toggle. Async: BlueZ
        // SetPowered can block for seconds on adapter init, so flip the
        // snap optimistically, write off the UI thread, and let the
        // periodic refresh correct it.
        if (inRect(px, ly, cx + cw - k_toggle_w - k_spacing_xl, k_body_top - 20, k_toggle_w, k_toggle_h)) {
            const on = !(self.available and self.powered);
            self.powered = on;
            if (std.c.getenv("EH_BLUETOOTH_DEBUG") == null)
                live_bt.setPoweredThread(self.alloc, self.adapter_path, on);
            return .toggle_power;
        }

        // Auto-reconnect toggle.
        if (inRect(px, ly, cx + cw - k_toggle_w - k_spacing_xl, k_body_top + k_slider_row_h - 20, k_toggle_w, k_toggle_h)) {
            self.auto_reconnect = !self.auto_reconnect;
            return .toggle_reconnect;
        }

        if (!self.available) return null;

        // Scan button (stays clickable while scanning so the scan can be
        // stopped). Async: flip the
        // snap optimistically so the pill flips to "Stop scan" at once, and
        // let the periodic refresh confirm `Discovering` from BlueZ.
        if (self.powered and inRect(px, ly, cx + cw - k_scan_btn_w - k_card_pad, k_scan_body_top, k_scan_btn_w, k_btn_h)) {
            self.scanning = !self.scanning;
            if (std.c.getenv("EH_BLUETOOTH_DEBUG") == null)
                live_bt.setDiscovery(self.alloc, self.adapter_path, self.scanning);
            return .toggle_scan;
        }

        if (!self.powered) return null;

        // Device list buttons (geometry matches the paint pass).
        var y: i32 = k_dev_list_top;
        for (self.entries[0..self.entries_len]) |entry| {
            if (entry.header) {
                y += k_sec_h;
                continue;
            }
            const row = self.rows[self.order[@intCast(entry.dev)]];
            const row_y = y;
            y += k_dev_row_h;
            // In-flight rows are not clickable until the operation settles.
            if (row.connecting) continue;
            const act_h: i32 = 24;
            const act_y: i32 = row_y + @divTrunc(k_dev_row_h - act_h, 2);
            var act_x: i32 = cx + cw - k_card_pad - k_spacing_s;

            // Forget button (paired or not — clears stale BlueZ objects).
            {
                const forget_w = settingsBtnW("Forget");
                act_x -= forget_w;
                if (inRect(px, ly, act_x, act_y, forget_w, act_h)) {
                    _ = live_bt.removeDevice(self.alloc, self.adapter_path, row.path);
                    self.refresh(true);
                    return .{ .forget = @intCast(entry.dev) };
                }
                // 10px gap between the pills (matches paint).
                act_x -= 10;
            }

            // Primary action: Disconnect / Connect / Pair.
            {
                const lbl = actionLabel(row.connected, row.connecting, row.paired);
                const conn_w = settingsBtnW(lbl);
                act_x -= conn_w;
                if (inRect(px, ly, act_x, act_y, conn_w, act_h)) {
                    if (row.connected) {
                        // Disconnect is fast; run it inline.
                        _ = live_bt.deviceVerbErr(self.alloc, row.path, "Disconnect", 10000);
                        self.refresh(true);
                    } else if (row.paired) {
                        live_bt.deviceVerbThread(row.path, "Connect", self.adapter_path);
                        self.setBusy(row.path, 25000);
                        self.refresh(true);
                    } else {
                        live_bt.deviceVerbThread(row.path, "Pair", self.adapter_path);
                        self.setBusy(row.path, 25000);
                        self.refresh(true);
                    }
                    return .{ .verb = @intCast(entry.dev) };
                }
            }
        }

        return null;
    }
};

/// `m3_xs_label_w + 24` — the C++ sizes the pill from the measured label
/// so the m3 auto-expand in setGeometry never fires (it would push the
/// right-aligned pills into each other). Measured on a scratch surface,
/// the same font the painted pill uses, so paint and hit agree.
fn settingsBtnW(label: []const u8) i32 {
    return ui_paint.measureTextWidth(label, 12, 500) + 24;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "settings-bluetooth: status text formats" {
    const t = std.testing;
    var buf: [192]u8 = undefined;
    var extra: [96]u8 = undefined;
    const s1 = statusText(&buf, &extra, "Headphones", true, false, true, true, -55, "AA:BB", "");
    try t.expectEqualStrings("Headphones \u{b7} Connected \u{b7} Signal Excellent \u{b7} AA:BB", s1);
    const s2 = statusText(&buf, &extra, "Mouse", false, true, true, false, 0, "CC:DD", "");
    try t.expectEqualStrings("Mouse \u{b7} Connecting\u{2026} \u{b7} CC:DD", s2);
    const s3 = statusText(&buf, &extra, "Keyboard", false, false, true, true, -70, "EE:FF", "EE:FF");
    try t.expectEqualStrings("Keyboard \u{b7} Paired \u{b7} Last used \u{b7} In range \u{b7} EE:FF", s3);
    const s4 = statusText(&buf, &extra, "Gamepad", false, false, true, true, -75, "11:22", "33:44");
    try t.expectEqualStrings("Gamepad \u{b7} Paired \u{b7} In range \u{b7} Signal Fair \u{b7} 11:22", s4);
    const s5 = statusText(&buf, &extra, "Device", false, false, false, false, 0, "55:66", "");
    try t.expectEqualStrings("Device \u{b7} Nearby \u{b7} 55:66", s5);
    const s6 = statusText(&buf, &extra, "Speaker", false, false, false, false, 0, "", "");
    try t.expectEqualStrings("Speaker \u{b7} Nearby \u{b7} ?", s6);
}

test "settings-bluetooth: action labels" {
    const t = std.testing;
    try t.expectEqualStrings("Disconnect", actionLabel(true, false, true));
    try t.expectEqualStrings("Connecting\u{2026}", actionLabel(false, true, true));
    try t.expectEqualStrings("Connect", actionLabel(false, false, true));
    try t.expectEqualStrings("Pair", actionLabel(false, false, false));
}

test "settings-bluetooth: friendly error mapping" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const a = friendlyError(&buf, "org.bluez.Error.AuthenticationRejected: Rejected");
    try t.expect(std.mem.indexOf(u8, a, "refused pairing") != null);
    const b = friendlyError(&buf, "org.bluez.Error.AlreadyExists: exists");
    try t.expectEqualStrings("Already paired \u{2014} use Connect instead of Pair.", b);
    const c = friendlyError(&buf, "Pair failed: org.bluez.Error.Failed: nope");
    try t.expectEqualStrings("Pairing failed \u{2014} put the device in pairing mode and retry.", c);
    const d = friendlyError(&buf, "org.bluez.Error.NotReady: very long detail that runs past the cap");
    try t.expect(d.len <= 96);
    try t.expect(std.mem.startsWith(u8, d, "org.bluez.Error.NotReady"));
}

test "settings-bluetooth: battery ladder and colours" {
    const t = std.testing;
    try t.expectEqualStrings("battery_full", batteryGlyph(100));
    try t.expectEqualStrings("battery_6_bar", batteryGlyph(90));
    try t.expectEqualStrings("battery_5_bar", batteryGlyph(70));
    try t.expectEqualStrings("battery_4_bar", batteryGlyph(50));
    try t.expectEqualStrings("battery_3_bar", batteryGlyph(30));
    try t.expectEqualStrings("battery_2_bar", batteryGlyph(15));
    try t.expectEqualStrings("battery_1_bar", batteryGlyph(7));
    try t.expectEqualStrings("battery_0_bar", batteryGlyph(0));
    const low = batteryColor(10);
    try t.expectApproxEqAbs(@as(f64, 1.00), low.r, 0.001);
    const mid = batteryColor(40);
    try t.expectApproxEqAbs(@as(f64, 0.96), mid.r, 0.001);
    const high = batteryColor(80);
    try t.expectApproxEqAbs(@as(f64, 0.45), high.r, 0.001);
}

test "settings-bluetooth: signal names" {
    const t = std.testing;
    try t.expectEqualStrings("Excellent", signalName(-50));
    try t.expectEqualStrings("Good", signalName(-65));
    try t.expectEqualStrings("Fair", signalName(-75));
    try t.expectEqualStrings("Weak", signalName(-90));
}

fn testRow(alias: []const u8, address: []const u8, connected: bool, paired: bool) Row {
    return .{
        .path = "",
        .address = address,
        .alias = alias,
        .kind = .headphones,
        .paired = paired,
        .connected = connected,
        .connecting = false,
        .has_rssi = false,
        .rssi = 0,
        .battery_pct = -1,
    };
}

test "settings-bluetooth: ordering ranks connected first, named before MAC" {
    const t = std.testing;
    const rows = [_]Row{
        testRow("Beacon", "11:11", false, false),
        testRow("Buds", "22:22", false, true),
        testRow("", "33:33", false, false), // anonymous LE beacon
        testRow("Mouse", "44:44", true, true),
    };
    const ord = try orderRows(t.allocator, &rows);
    defer t.allocator.free(ord);
    try t.expectEqual(@as(usize, 4), ord.len);
    try t.expectEqual(@as(u32, 3), ord[0]); // connected first
    try t.expectEqual(@as(u32, 1), ord[1]); // paired next
    try t.expectEqual(@as(u32, 0), ord[2]); // named nearby before MAC-only
    try t.expectEqual(@as(u32, 2), ord[3]);
}

test "settings-bluetooth: plan headers only with multiple groups" {
    const t = std.testing;
    var buf: [8]Entry = undefined;
    // One group (paired only) → no headers.
    const rows = [_]Row{
        testRow("Buds", "22:22", false, true),
        testRow("Mouse", "44:44", false, true),
    };
    const n1 = planRows(&buf, &.{ 0, 1 }, &rows);
    try t.expectEqual(@as(usize, 2), n1);
    try t.expect(!buf[0].header);
    // Two groups → a header per group.
    const rows2 = [_]Row{
        testRow("Buds", "22:22", true, true),
        testRow("Mouse", "44:44", false, true),
    };
    const n2 = planRows(&buf, &.{ 0, 1 }, &rows2);
    try t.expectEqual(@as(usize, 4), n2);
    try t.expect(buf[0].header);
    try t.expectEqualStrings("CONNECTED", buf[0].label);
    try t.expectEqual(@as(i32, 0), buf[1].dev);
    try t.expect(buf[2].header);
    try t.expectEqualStrings("REMEMBERED DEVICES", buf[2].label);
    try t.expectEqual(@as(i32, 1), buf[3].dev);
}

test "settings-bluetooth: content height" {
    const t = std.testing;
    var empty: [0]Entry = .{};
    try t.expectEqual(@as(i32, 60), contentHeight(&empty));
    const one_row = [_]Entry{.{ .header = false, .label = "", .dev = 0 }};
    try t.expectEqual(@as(i32, 24 + 64), contentHeight(&one_row));
    const header_row = [_]Entry{
        .{ .header = true, .label = "X", .dev = -1 },
        .{ .header = false, .label = "", .dev = 0 },
    };
    try t.expectEqual(@as(i32, 24 + 30 + 64), contentHeight(&header_row));
}

test "settings-bluetooth: adapter description" {
    const t = std.testing;
    var buf: [192]u8 = undefined;
    try t.expectEqualStrings("No adapter found", adapterDesc(&buf, false, false, false, false, 0, 0));
    try t.expectEqualStrings("Powered on \u{b7} 3 paired \u{b7} 1 connected", adapterDesc(&buf, true, true, false, false, 3, 1));
    try t.expectEqualStrings("Powered off \u{b7} 3 remembered", adapterDesc(&buf, true, false, false, false, 3, 0));
    const blocked = adapterDesc(&buf, true, false, true, false, 3, 0);
    try t.expect(std.mem.indexOf(u8, blocked, "soft block") != null);
    try t.expect(std.mem.indexOf(u8, blocked, "rfkill unblock bluetooth") != null);
    const hard = adapterDesc(&buf, true, false, false, true, 0, 0);
    try t.expect(std.mem.indexOf(u8, hard, "hard block") != null);
}

test "settings-bluetooth: devices cat label flags truncation" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("DEVICES", devicesCatLabel(&buf, 1, 1));
    try t.expectEqualStrings("DEVICES", devicesCatLabel(&buf, 0, 0));
    try t.expectEqualStrings("DEVICES \u{b7} 12 OF 15 SHOWN", devicesCatLabel(&buf, 12, 15));
}

test "settings-bluetooth: priority fill keeps paired rows past the cap" {
    const t = std.testing;
    var p = Page{};
    // Adversarial walk order: a flood of unpaired beacons first, the one
    // paired headset last — a first-N fill evicts it, the two-pass fill
    // must keep it.
    var devs = @as([14]live_bt.Device, @splat(.{}));
    for (devs[0..13]) |*d| {
        d.address = "BE:AC:ON:00:00:00";
        d.alias = "beacon";
    }
    devs[13] = .{ .address = "AA:BB:CC:DD:EE:FF", .alias = "Headset", .paired = true };
    p.fillRows(&devs);
    try t.expectEqual(k_max_rows, p.rows_len);
    var kept = false;
    for (p.rows_()) |*r| {
        if (r.paired) kept = true;
    }
    try t.expect(kept);
}

test "settings-bluetooth: page paints the connected fixture" {
    const t = std.testing;
    // The debug fixture exercises the whole paint path (cards, rows,
    // glyphs, pills, status lines) without a BlueZ daemon.
    const c = @import("c_stdlib");
    const prev_ptr = c.getenv("EH_BLUETOOTH_DEBUG");
    var prev_buf: [64:0]u8 = @as([64:0]u8, @splat(0));
    var have_prev = false;
    if (prev_ptr) |pv| {
        const s = std.mem.span(pv);
        const n = @min(s.len, 63);
        @memcpy(prev_buf[0..n], s[0..n]);
        prev_buf[n] = 0;
        have_prev = true;
    }
    _ = c.setenv("EH_BLUETOOTH_DEBUG", "connected", 1);
    defer {
        if (have_prev) {
            _ = c.setenv("EH_BLUETOOTH_DEBUG", &prev_buf, 1);
        } else _ = c.unsetenv("EH_BLUETOOTH_DEBUG");
    }

    var p = Page{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();
    try t.expect(p.available);
    try t.expect(p.powered);
    try t.expect(p.rows_len >= 5);
    try t.expectEqual(@as(i32, 5), p.paired_count);
    try t.expectEqual(@as(i32, 4), p.connected_count);
    // Connected rows sort first, paired-only after.
    try t.expect(p.rows[p.order[0]].connected);

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 700, 900);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    p.paint(cr, .{ .content_x = 292, .content_w = 592, .win_h = 900 }, -1, -1, 1.0);
    // Scroll extent covers the card stack.
    try t.expect(p.totalHeight(.{ .content_x = 292, .content_w = 592, .win_h = 900 }) > 400);
}

test "settings-bluetooth: tab id stays wired" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 47), tab_id);
}
