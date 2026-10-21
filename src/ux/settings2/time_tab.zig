//! Time tab (tab 30): the `settings_tab_time` port plus the shared World
//! clocks editor.
//!
//! Cards, in the reference's order: TIME FORMAT (24-hour / seconds / date
//! toggles), DATE FORMAT (four-option dropdown, with the custom `strftime`
//! field when "Custom" is selected), PREVIEW (the live clock the settings
//! resolve to), NETWORK TIME (NTP switch, status, refresh, and the manual
//! clock editor when NTP is off) and TIMEZONE (system zone, override,
//! Change…/Reset/Set as System). The reference's zone picker modal is here
//! too, and doubles as the World clocks card's "Add city" picker.
//!
//! The World clocks card is the new home of "add a city": it edits
//! `<leaf>/world_clock.json` (the dock/taskbar widget's list) and
//! `<leaf>/WorldClock` (the desktop widget's list) together, so both widgets
//! always show the same cities.
//!
//! Self-painted like `bluetooth_tab`/`sound_tab`: `totalHeight` feeds the
//! scroll extent, `paint` draws the whole column, `hit` returns what the
//! window must persist, and the two modal dialogs run through the
//! window-space `modal*` calls before regular hit testing. System queries
//! (`timedatectl`) are throttled reads; the write actions run
//! `pkexec timedatectl …` blocking, exactly like the reference's
//! `accounts_run_priv`.

const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const app_mod = @import("app.zig");
const config = @import("../../config.zig");
const wc_popup = @import("world_clock_popup.zig");
const tzdata = @import("../../desktop_shell/widgets/world_clock/tzdata.zig");
const wc_session = @import("../../desktop_shell/widgets/world_clock/session.zig");
const clock_paint = @import("../../desktop_shell/widgets/clock/clock_paint.zig");
const xkb = @import("../../wl/seat.zig").xkb;
const cairo = @import("../../wl/buffer/shm.zig").cairo;

pub const tab_id: i32 = 30;
/// The World Clock page — the same `Page` in its second mode, so both rails
/// of the Time category share one city list, one picker and one pair of
/// stores (`world_clock.json` + `WorldClock`).
pub const wc_tab_id: i32 = 84;

/// True for both Time-category pages. The window and the content model ask
/// this instead of comparing against one id, the way `sound_tab.isSoundTab`
/// covers the Audio Center's four pages.
pub fn ownsTab(tab: i32) bool {
    return tab == tab_id or tab == wc_tab_id;
}

/// Which half of the Time category the page is showing: `system` is the
/// format / date / preview / network-time / timezone stack (tab 30),
/// `world` is the city editor alone (tab 84).
pub const Mode = enum { system, world };

// ---------------------------------------------------------------------------
// Metrics (same pitch as the shared row renderer)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Layout ruler. Every band below is one of the app-wide settings metrics
// (`rows.zig`), so the Time page sits on the same grid as the declarative
// pages: 52px title band, 60px two-line rows (title at +26, description at
// +42), 44px info rows, 30px controls. Right-hand controls share one lane:
// their right edge is always `card_pad` from the card edge.
// ---------------------------------------------------------------------------
const card_gap = common.card_gap;
const title_band: i32 = 52;
const row_band: i32 = 60;
const toggle_band: i32 = row_band;
const combo_band: i32 = row_band;
const info_band: i32 = 44;
/// Status line with a pill on the right: taller than an info row so the
/// 30px button keeps the same breathing room as a switch in a 60px band.
const status_band: i32 = 56;
/// Custom date-format band: title + description, then the input.
const custom_band: i32 = 104;
const preview_body: i32 = 104;
const manual_head_band: i32 = row_band;
const manual_band: i32 = row_band;
const city_row_h: i32 = row_band;
const wc_add_band: i32 = row_band;
const page_bottom_pad: i32 = 24;
/// One control height for inputs, pills and icon buttons.
const field_h: i32 = 30;
const btn_h: i32 = field_h;
/// Pills size to their label at this padding, with a floor so a short
/// label ("Reset") still reads as a button.
const btn_pad_x: i32 = 18;
const btn_min_w: i32 = 88;
/// Gap between two right-aligned pills sharing a lane.
const lane_gap: i32 = 8;
/// Gap between a right-aligned value and the pill lane beside it.
const value_gap: i32 = 16;
/// Horizontal room a right-aligned value may take before the label block on
/// its left is clipped: zone ids can be long, and a label must never run
/// under the control sharing its row.
const value_lane_w: f64 = 200.0;
const remove_btn: i32 = 28;
const custom_field_w: i32 = 360;
const manual_field_gap: i32 = 12;
const manual_field_w_date: i32 = 150;
const manual_field_w_time: i32 = 120;

// Modal zone picker (window space, like the reference's 480x400 dialog).
const dlg_w: f64 = 480.0;
const dlg_h: f64 = 400.0;
const dlg_row_h: f64 = 38.0;
const dlg_list_top: f64 = 92.0;
const dlg_list_bottom: f64 = 44.0;
const dlg_close_s: f64 = 26.0;

const query_ms: i64 = 2000;
const max_custom: usize = 64;
const max_picker_search: usize = 48;

const linux = std.os.linux;

fn nowMs() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(i64, @divTrunc(@max(ts.nsec, 0), 1_000_000));
}

/// 500 ms caret blink, like the popups.
fn caretOn() bool {
    return @mod(@divTrunc(nowMs(), 500), 2) == 0;
}

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

pub const date_format_labels = [_][]const u8{
    "Weekday + Day (Wed 21)",
    "Full Date (Wednesday, May 21, 2026)",
    "ISO 8601 (2026-05-21)",
    "Custom strftime",
};

/// `/usr/share/zoneinfo` walk filter: drop the duplicate subtrees and the
/// tab/version files the reference's picker also skipped; require a region
/// for everything but the bare `UTC` root.
pub fn keepZone(rel: []const u8) bool {
    if (std.mem.startsWith(u8, rel, "posix/") or
        std.mem.startsWith(u8, rel, "right/") or
        std.mem.startsWith(u8, rel, "SystemV/")) return false;
    const base = std.fs.path.basename(rel);
    if (base.len == 0 or base[0] == '.') return false;
    const junk = [_][]const u8{
        "localtime", "posixrules",  "zone.tab",          "zone1970.tab",
        "tzdata.zi", "leapseconds", "leap-seconds.list", "iso3166.tab",
    };
    for (junk) |j| {
        if (std.mem.eql(u8, rel, j) or std.mem.eql(u8, base, j)) return false;
    }
    if (std.mem.startsWith(u8, base, "+VERSION")) return false;
    if (std.mem.indexOfScalar(u8, rel, '/') == null) return std.mem.eql(u8, rel, "UTC");
    return true;
}

fn foldEq(a: u8, b: u8) bool {
    const x = if (a == '_') ' ' else std.ascii.toLower(a);
    const y = if (b == '_') ' ' else std.ascii.toLower(b);
    return x == y;
}

/// Case-insensitive substring with `_` folding to a space, so "new york"
/// finds `America/New_York`.
pub fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and foldEq(hay[i + j], needle[j])) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

/// "America/New_York" -> "New York (America)".
pub fn prettyZone(buf: []u8, tz: []const u8) []const u8 {
    var city_buf: [96]u8 = undefined;
    const city = prettyCity(&city_buf, tz);
    const slash = std.mem.lastIndexOfScalar(u8, tz, '/') orelse
        return std.fmt.bufPrint(buf, "{s}", .{city}) catch tz;
    const area = tz[0..slash];
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ city, area }) catch tz;
}

/// City label for a zone: the preset's name when it has one, else the zone
/// tail with underscores turned into spaces.
pub fn prettyCity(buf: []u8, tz: []const u8) []const u8 {
    if (wc_session.presetName(tz)) |n| {
        const m = @min(n.len, buf.len);
        @memcpy(buf[0..m], n[0..m]);
        return buf[0..m];
    }
    const tail = if (std.mem.lastIndexOfScalar(u8, tz, '/')) |i| tz[i + 1 ..] else tz;
    const n = @min(tail.len, buf.len);
    for (tail[0..n], 0..) |ch, i| buf[i] = if (ch == '_') ' ' else ch;
    return buf[0..n];
}

/// `YYYY-MM-DD` with real digits.
pub fn validDateField(s: []const u8) bool {
    if (s.len != 10) return false;
    for (s, 0..) |ch, i| {
        if (i == 4 or i == 7) {
            if (ch != '-') return false;
        } else if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// `HH:MM` or `HH:MM:SS`, digits and colons only.
pub fn validTimeField(s: []const u8) bool {
    if (s.len != 5 and s.len != 8) return false;
    for (s, 0..) |ch, i| {
        if (i == 2) {
            if (ch != ':') return false;
        } else if (i == 5) {
            if (s.len == 8 and ch != ':') return false;
        } else if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// One line of `HH:MM[[:]SS] [AM/PM]` for a resolved civil time.
pub fn timeText(buf: []u8, c: tzdata.Civil, h24: bool, with_secs: bool) []const u8 {
    if (h24) {
        if (with_secs)
            return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ c.h, c.mi, c.s }) catch "";
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ c.h, c.mi }) catch "";
    }
    var h12 = c.h % 12;
    if (h12 == 0) h12 = 12;
    const ap: []const u8 = if (c.h < 12) "AM" else "PM";
    if (with_secs)
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2} {s}", .{ h12, c.mi, c.s, ap }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ h12, c.mi, ap }) catch "";
}

fn monthName(m: u32) []const u8 {
    return wc_session.monthName(m);
}

fn weekdayName(w: u32) []const u8 {
    return wc_session.weekdayName(w);
}

/// The preview date line for a format index; index 3 renders the pattern
/// through the same `strftime` table the clocks use (scratch-buffer bound).
pub fn dateText(buf: []u8, idx: i32, c: tzdata.Civil, custom: []const u8) []const u8 {
    switch (idx) {
        0 => {
            const wd = weekdayName(c.wday);
            const short = if (wd.len >= 3) wd[0..3] else wd;
            return std.fmt.bufPrint(buf, "{s} {d}", .{ short, c.d }) catch "";
        },
        1 => return std.fmt.bufPrint(buf, "{s}, {s} {d}, {d}", .{
            weekdayName(c.wday), monthName(c.mo), c.d, c.y,
        }) catch "",
        2 => {
            // Zig prints `+` for a signed int under `0>` fill — format the
            // year unsigned so the date reads `2026-05-21`, not `+2026-05-21`.
            const y: u32 = if (c.y < 0) 0 else @intCast(c.y);
            return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, c.mo, c.d }) catch "";
        },
        else => {
            if (custom.len == 0) return "";
            const bt = clock_paint.BrokenTime{
                .year = c.y,
                .mon = @intCast(if (c.mo > 0) c.mo - 1 else 0),
                .mday = @intCast(@max(c.d, 1)),
                .wday = @intCast(c.wday % 7),
                .hour = @intCast(c.h % 24),
                .min = @intCast(c.mi % 60),
                .sec = @intCast(c.s % 60),
            };
            var fba = std.heap.FixedBufferAllocator.init(buf);
            return clock_paint.renderCustom(fba.allocator(), bt, custom) catch "";
        },
    }
}

// ---------------------------------------------------------------------------
// World-clock files
// ---------------------------------------------------------------------------

fn leafPath(buf: []u8, name: []const u8) ?[]const u8 {
    const leaf = config.leafName();
    if (std.c.getenv("XDG_CONFIG_HOME")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ s, leaf, name }) catch null;
    }
    if (std.c.getenv("HOME")) |p| {
        const home = std.mem.span(p);
        if (home.len > 0) return std.fmt.bufPrint(buf, "{s}/.config/{s}/{s}", .{ home, leaf, name }) catch null;
    }
    return std.fmt.bufPrint(buf, "/tmp/{s}/{s}", .{ leaf, name }) catch null;
}

fn tomlLookup(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trim(u8, line[key.len..], " \t");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        var val = std.mem.trim(u8, rest[1..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val = val[1 .. val.len - 1];
        return val;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Page state
// ---------------------------------------------------------------------------

const Focus = enum { none, custom, date, time };
const PickerMode = enum { system_tz, add_city };

pub const Picker = struct {
    open: bool = false,
    mode: PickerMode = .system_tz,
    buf: [max_picker_search]u8 = undefined,
    len: usize = 0,
    focus: bool = true,
    hover: i32 = -1,
    arm: i32 = -1,
    scroll: f64 = 0,
    zones: std.ArrayListUnmanaged([]const u8) = .empty,
    filtered: std.ArrayListUnmanaged([]const u8) = .empty,
    zones_loaded: bool = false,
};

/// What the window must do after a page press. Settings changed by keys go
/// through `takeDirty` instead (the window checks it after `key`).
pub const Action = enum { redraw, persist };

pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_w: i32,
    win_h: i32,
    scroll_px: i32,
};

/// Card tops and heights for one frame; `paint` and `hit` share it so the
/// two can never disagree about where a card sits.
const Stack = struct {
    g: Geo,
    fmt_top: i32,
    date_top: i32,
    prev_top: i32,
    net_top: i32,
    tz_top: i32,
    wc_top: i32,
    date_h: i32,
    net_h: i32,
    tz_h: i32,
    wc_h: i32,
};

pub const Page = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    inited: bool = false,
    settings: *app_mod.Settings = undefined,

    /// Set when a `Settings` field changed; the window flushes `[time]`.
    dirty: bool = false,

    /// Which Time-category page this instance is showing; the content model
    /// keeps it in sync with the active tab (`ownsTab`). One instance serves
    /// both pages so the city editor, the picker and the two stores stay
    /// shared.
    mode: Mode = .system,

    // Live system state (throttled `timedatectl` reads).
    tz_store: tzdata.Store = undefined,
    query_enabled: bool = true,
    queried: bool = false,
    last_query_ms: i64 = 0,
    have_timedatectl: bool = true,
    sys_tz_buf: [96]u8 = undefined,
    sys_tz_len: usize = 0,
    ntp_on: bool = false,
    ntp_synced: bool = false,
    ntp_msg_buf: [192]u8 = undefined,
    ntp_msg_len: usize = 0,
    ntp_msg_err: bool = false,
    tz_msg_buf: [192]u8 = undefined,
    tz_msg_len: usize = 0,
    tz_msg_err: bool = false,

    // Input state.
    focus: Focus = .none,
    combo_open: bool = false,
    combo_hover: i32 = 3,
    custom_buf: [max_custom]u8 = undefined,
    custom_len: usize = 0,
    date_buf: [10]u8 = undefined,
    date_len: usize = 0,
    time_buf: [8]u8 = undefined,
    time_len: usize = 0,

    /// Page-owned copy of the picked override; `Settings.time_timezone`
    /// borrows it until the next pick (the config seed owns its own copy).
    tz_hold: ?[]u8 = null,

    // World clocks (both files, kept in sync).
    wc_tzs: std.ArrayListUnmanaged([]const u8) = .empty,
    wc_labels: std.ArrayListUnmanaged([]const u8) = .empty,
    wc_h24: bool = true,
    wc_sec: bool = false,
    wc_pin: ?[]u8 = null,
    wc_loaded: bool = false,
    json_path_override: ?[]const u8 = null,
    wc_path_override: ?[]const u8 = null,

    picker: Picker = .{},

    date_scratch: [512]u8 = undefined,

    pub fn init(self: *Page, gpa: std.mem.Allocator, io: std.Io, settings: *app_mod.Settings) void {
        self.gpa = gpa;
        self.io = io;
        self.settings = settings;
        self.tz_store = tzdata.Store.init(gpa, io);
        self.inited = true;
    }

    pub fn deinit(self: *Page) void {
        for (self.wc_tzs.items) |z| self.gpa.free(z);
        self.wc_tzs.deinit(self.gpa);
        for (self.wc_labels.items) |l| self.gpa.free(l);
        self.wc_labels.deinit(self.gpa);
        if (self.wc_pin) |p| self.gpa.free(p);
        if (self.tz_hold) |p| self.gpa.free(p);
        for (self.picker.zones.items) |z| self.gpa.free(z);
        self.picker.zones.deinit(self.gpa);
        self.picker.filtered.deinit(self.gpa);
        self.tz_store.deinit();
        self.inited = false;
    }

    pub fn takeDirty(self: *Page) bool {
        const d = self.dirty;
        self.dirty = false;
        return d;
    }

    /// Switch between the Time category's two pages. Only the shared
    /// transient state is dropped: the living `open` flags belong to one
    /// page's controls each (the World Clock picker vs. the System Time
    /// date-format dropdown), so a tab switch closes them the way clicking
    /// elsewhere would — committing a custom-format edit into `Settings`
    /// rather than losing it. World-clock rows, labels and the stores are
    /// untouched (both pages show the same list).
    pub fn setMode(self: *Page, m: Mode) void {
        if (self.mode == m) return;
        self.mode = m;
        self.picker.open = false;
        self.combo_open = false;
        self.moveFocus(.none);
    }

    // -----------------------------------------------------------------
    // World-clock files
    // -----------------------------------------------------------------

    fn ensureLoaded(self: *Page) void {
        if (self.wc_loaded) return;
        self.wc_loaded = true;

        var path_buf: [512]u8 = undefined;
        const json_path = self.json_path_override orelse leafPath(&path_buf, "world_clock.json");
        if (json_path) |path| {
            if (std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(1 << 16))) |bytes| {
                defer self.gpa.free(bytes);
                const Disk = struct {
                    tz: []const []const u8 = &.{},
                    h24: bool = true,
                    sec: bool = false,
                    pin: ?[]const u8 = null,
                };
                if (std.json.parseFromSlice(Disk, self.gpa, bytes, .{ .ignore_unknown_fields = true })) |parsed| {
                    defer parsed.deinit();
                    for (parsed.value.tz) |id| self.wcAppend(id, null);
                    self.wc_h24 = parsed.value.h24;
                    self.wc_sec = parsed.value.sec;
                    if (parsed.value.pin) |p| {
                        if (self.wc_pin) |old| self.gpa.free(old);
                        self.wc_pin = self.gpa.dupe(u8, p) catch null;
                    }
                } else |_| {}
            } else |_| {}
        }

        // The WorldClock pairs carry the labels (and any city only that file
        // knows about — nothing gets lost on the first save).
        if (self.wc_path_override orelse leafPath(&path_buf, "WorldClock")) |path| {
            if (std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(1 << 16))) |text| {
                defer self.gpa.free(text);
                var idx: usize = 1;
                while (idx <= wc_session.max_clocks) : (idx += 1) {
                    var key_buf: [48]u8 = undefined;
                    const tk = std.fmt.bufPrint(&key_buf, "city_{d}_tz", .{idx}) catch break;
                    const tz = tomlLookup(text, tk) orelse break;
                    var lb_buf: [48]u8 = undefined;
                    const lk = std.fmt.bufPrint(&lb_buf, "city_{d}_label", .{idx}) catch break;
                    self.wcAppend(tz, tomlLookup(text, lk));
                }
            } else |_| {}
        }
    }

    fn wcHas(self: *const Page, tz: []const u8) bool {
        for (self.wc_tzs.items) |z| {
            if (std.mem.eql(u8, z, tz)) return true;
        }
        return false;
    }

    /// Append a city, keeping the two lists parallel. A `label` of null (or
    /// empty) derives one from the zone.
    fn wcAppend(self: *Page, tz: []const u8, label: ?[]const u8) void {
        if (tz.len == 0 or self.wcHas(tz)) return;
        if (self.wc_tzs.items.len >= wc_session.max_clocks) return;
        const tz_dup = self.gpa.dupe(u8, tz) catch return;
        var label_buf: [96]u8 = undefined;
        const derived = prettyCity(&label_buf, tz);
        const use = if (label) |l| (if (l.len > 0) l else derived) else derived;
        const label_dup = self.gpa.dupe(u8, use) catch {
            self.gpa.free(tz_dup);
            return;
        };
        self.wc_tzs.append(self.gpa, tz_dup) catch {
            self.gpa.free(tz_dup);
            self.gpa.free(label_dup);
            return;
        };
        self.wc_labels.append(self.gpa, label_dup) catch {
            self.gpa.free(label_dup);
        };
    }

    fn wcRemove(self: *Page, idx: usize) void {
        if (idx >= self.wc_tzs.items.len) return;
        self.gpa.free(self.wc_tzs.items[idx]);
        _ = self.wc_tzs.orderedRemove(idx);
        if (idx < self.wc_labels.items.len) {
            self.gpa.free(self.wc_labels.items[idx]);
            _ = self.wc_labels.orderedRemove(idx);
        }
        self.saveWorldClocks();
    }

    fn writeAtomic(self: *Page, path: []const u8, data: []const u8) void {
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(self.io, dir) catch {};
        var tmp_buf: [560]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return;
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = data }) catch return;
        cwd.rename(tmp, cwd, path, self.io) catch {
            cwd.deleteFile(self.io, tmp) catch {};
        };
    }

    /// Write both stores from the merged list; `h24`/`sec`/`pin` in the JSON
    /// are preserved from the load (the dock/taskbar widget owns them).
    fn saveWorldClocks(self: *Page) void {
        var path_buf: [512]u8 = undefined;
        if (self.json_path_override orelse leafPath(&path_buf, "world_clock.json")) |path| {
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            const w = &aw.writer;
            w.writeAll("{\"tz\":[") catch return;
            for (self.wc_tzs.items, 0..) |tz, i| {
                if (i > 0) w.writeAll(",") catch return;
                w.print("\"{s}\"", .{tz}) catch return;
            }
            w.writeAll("],\"h24\":") catch return;
            w.writeAll(if (self.wc_h24) "true" else "false") catch return;
            w.writeAll(",\"sec\":") catch return;
            w.writeAll(if (self.wc_sec) "true" else "false") catch return;
            w.writeAll(",\"pin\":") catch return;
            if (self.wc_pin) |p| {
                w.print("\"{s}\"", .{p}) catch return;
            } else {
                w.writeAll("null") catch return;
            }
            w.writeAll("}\n") catch return;
            self.writeAtomic(path, aw.written());
        }

        if (self.wc_path_override orelse leafPath(&path_buf, "WorldClock")) |path| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.gpa);
            for (self.wc_tzs.items, 0..) |tz, i| {
                const label = if (i < self.wc_labels.items.len) self.wc_labels.items[i] else tz;
                var line_buf: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "city_{d}_tz = \"{s}\"\ncity_{d}_label = \"{s}\"\n", .{ i + 1, tz, i + 1, label }) catch continue;
                buf.appendSlice(self.gpa, line) catch continue;
            }
            self.writeAtomic(path, buf.items);
        }
    }

    // -----------------------------------------------------------------
    // System clock
    // -----------------------------------------------------------------

    fn clearNtpMsg(self: *Page) void {
        self.ntp_msg_len = 0;
        self.ntp_msg_err = false;
    }

    fn setNtpMsg(self: *Page, msg: []const u8, err: bool) void {
        const n = @min(msg.len, self.ntp_msg_buf.len);
        @memcpy(self.ntp_msg_buf[0..n], msg[0..n]);
        self.ntp_msg_len = n;
        self.ntp_msg_err = err;
    }

    fn clearTzMsg(self: *Page) void {
        self.tz_msg_len = 0;
        self.tz_msg_err = false;
    }

    fn setTzMsg(self: *Page, msg: []const u8, err: bool) void {
        const n = @min(msg.len, self.tz_msg_buf.len);
        @memcpy(self.tz_msg_buf[0..n], msg[0..n]);
        self.tz_msg_len = n;
        self.tz_msg_err = err;
    }

    /// `timedatectl show` for the zone + NTP flags, at most every
    /// `query_ms` unless forced. Best-effort: a missing/unhappy service just
    /// leaves the last reading in place and the card says so.
    pub fn querySystem(self: *Page, force: bool) void {
        if (!self.query_enabled) return;
        const now = nowMs();
        if (!force and self.queried and now - self.last_query_ms < query_ms) return;
        self.last_query_ms = now;
        self.queried = true;
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "timedatectl", "show", "-p", "Timezone", "-p", "NTP", "-p", "NTPSynchronized" },
        }) catch {
            self.have_timedatectl = false;
            return;
        };
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            self.have_timedatectl = false;
            return;
        }
        self.have_timedatectl = true;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "Timezone=")) {
                const v = std.mem.trim(u8, line["Timezone=".len..], " \t\r");
                const n = @min(v.len, self.sys_tz_buf.len);
                @memcpy(self.sys_tz_buf[0..n], v[0..n]);
                self.sys_tz_len = n;
            } else if (std.mem.startsWith(u8, line, "NTP=")) {
                self.ntp_on = std.mem.eql(u8, std.mem.trim(u8, line["NTP=".len..], " \t\r"), "yes");
            } else if (std.mem.startsWith(u8, line, "NTPSynchronized=")) {
                self.ntp_synced = std.mem.eql(u8, std.mem.trim(u8, line["NTPSynchronized=".len..], " \t\r"), "yes");
            }
        }
    }

    fn runPriv(self: *Page, argv: []const []const u8) bool {
        const res = std.process.run(self.gpa, self.io, .{ .argv = argv }) catch return false;
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        return res.term == .exited and res.term.exited == 0;
    }

    /// The system timezone the clocks resolve to: the override when set and
    /// known, else the local zone.
    pub fn effectiveZone(self: *const Page) []const u8 {
        if (self.settings.time_timezone.len > 0) return self.settings.time_timezone;
        return self.sysTz();
    }

    pub fn sysTz(self: *const Page) []const u8 {
        return self.sys_tz_buf[0..self.sys_tz_len];
    }

    /// Civil time `settings` resolve to right now (override zone or local).
    pub fn previewCivil(self: *Page, now_sec: i64) tzdata.Civil {
        const tz = self.settings.time_timezone;
        const off = self.tz_store.zoneOffset(tz, now_sec);
        return tzdata.civilFromEpoch(now_sec + off);
    }

    pub fn cityCivil(self: *Page, tz: []const u8, now_sec: i64) tzdata.Civil {
        const off = self.tz_store.zoneOffset(tz, now_sec);
        return tzdata.civilFromEpoch(now_sec + off);
    }

    fn setTimezoneOverride(self: *Page, tz: []const u8) void {
        const dup = self.gpa.dupe(u8, tz) catch return;
        if (self.tz_hold) |old| self.gpa.free(old);
        self.tz_hold = dup;
        self.settings.time_timezone = dup;
        self.dirty = true;
    }

    fn setNtp(self: *Page, on: bool) void {
        self.clearNtpMsg();
        const ok = self.runPriv(&.{ "pkexec", "timedatectl", "set-ntp", if (on) "true" else "false" });
        self.querySystem(true);
        if (!ok) self.setNtpMsg("Could not change the NTP setting (administrator authentication may be required).", true);
    }

    fn setSystemTz(self: *Page, tz: []const u8) void {
        if (tz.len == 0) return;
        self.clearTzMsg();
        const ok = self.runPriv(&.{ "pkexec", "timedatectl", "set-timezone", tz });
        self.querySystem(true);
        if (ok) {
            var buf: [160]u8 = undefined;
            self.setTzMsg(std.fmt.bufPrint(&buf, "System timezone set to {s}.", .{tz}) catch "System timezone set.", false);
        } else {
            self.setTzMsg("Could not set the system timezone (administrator authentication may be required).", true);
        }
    }

    fn runSetClock(self: *Page) void {
        self.clearNtpMsg();
        const date = self.date_buf[0..self.date_len];
        const time = self.time_buf[0..self.time_len];
        if (!validDateField(date) or !validTimeField(time)) {
            self.setNtpMsg("Enter the date as YYYY-MM-DD and the time as HH:MM:SS.", true);
            return;
        }
        var arg_buf: [40]u8 = undefined;
        const arg = std.fmt.bufPrint(&arg_buf, "{s} {s}{s}", .{
            date,
            time,
            if (time.len == 5) ":00" else "",
        }) catch return;
        const ok = self.runPriv(&.{ "pkexec", "timedatectl", "set-time", arg });
        self.querySystem(true);
        if (ok) {
            self.setNtpMsg("System clock set.", false);
        } else {
            self.setNtpMsg("Could not set the clock (administrator authentication may be required).", true);
        }
    }

    // -----------------------------------------------------------------
    // Input state helpers
    // -----------------------------------------------------------------

    fn seedCustom(self: *Page) void {
        const cur = self.settings.time_custom_format;
        const n = @min(cur.len, self.custom_buf.len);
        @memcpy(self.custom_buf[0..n], cur[0..n]);
        self.custom_len = n;
    }

    fn commitCustom(self: *Page) void {
        self.settings.time_custom_format = self.custom_buf[0..self.custom_len];
        self.dirty = true;
    }

    fn moveFocus(self: *Page, next: Focus) void {
        if (self.focus == .custom and next != .custom) self.commitCustom();
        if (next == .custom and self.focus != .custom) self.seedCustom();
        self.focus = next;
    }

    fn seedManualFields(self: *Page) void {
        const c = self.previewCivil(clock_paint.nowSeconds());
        // Same unsigned-year rule as `dateText` (no `+` sign).
        const y: u32 = if (c.y < 0) 0 else @intCast(c.y);
        const d = std.fmt.bufPrint(&self.date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, c.mo, c.d }) catch "";
        self.date_len = d.len;
        const tm = std.fmt.bufPrint(&self.time_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ c.h, c.mi, c.s }) catch "";
        self.time_len = tm.len;
    }

    fn setDateFormat(self: *Page, idx: i32) void {
        self.settings.time_date_format = std.math.clamp(idx, 0, 3);
        self.dirty = true;
        if (self.settings.time_date_format == 3) self.seedCustom();
    }

    fn popByte(buf: []u8, len: *usize) void {
        if (len.* == 0) return;
        var end = len.* - 1;
        while (end > 0 and (buf[end] & 0xC0) == 0x80) end -= 1;
        len.* = end;
    }

    // -----------------------------------------------------------------
    // Stack / geometry
    // -----------------------------------------------------------------

    pub fn cardX(g: Geo) i32 {
        return g.content_x + 8;
    }

    pub fn cardW(g: Geo) i32 {
        return g.content_w - 16;
    }

    fn stack(self: *Page, g: Geo) Stack {
        const wc_rows: i32 = @intCast(@max(self.wc_tzs.items.len, 1));
        const wc_h = title_band + wc_rows * city_row_h + wc_add_band;
        // World Clock page: the city editor is the whole page, top-aligned
        // at the content top like every other settings page.
        if (self.mode == .world) {
            return .{
                .g = g,
                .fmt_top = 0,
                .date_top = 0,
                .prev_top = 0,
                .net_top = 0,
                .tz_top = 0,
                .wc_top = common.content_top,
                .date_h = 0,
                .net_h = 0,
                .tz_h = 0,
                .wc_h = wc_h,
            };
        }
        const fmt_top = common.content_top;
        const fmt_h = title_band + 3 * toggle_band;
        const date_top = fmt_top + fmt_h + card_gap;
        const date_h = title_band + combo_band +
            (if (self.settings.time_date_format == 3) custom_band else 0);
        const prev_top = date_top + date_h + card_gap;
        const prev_h = title_band + preview_body;
        const net_top = prev_top + prev_h + card_gap;
        const net_h = title_band + toggle_band + status_band +
            (if (!self.ntp_on) manual_head_band + manual_band else 0) +
            (if (self.ntp_msg_len > 0) info_band else 0);
        const tz_top = net_top + net_h + card_gap;
        const tz_h = title_band + 2 * toggle_band + (if (self.tz_msg_len > 0) info_band else 0);
        const wc_top = tz_top + tz_h + card_gap;
        return .{
            .g = g,
            .fmt_top = fmt_top,
            .date_top = date_top,
            .prev_top = prev_top,
            .net_top = net_top,
            .tz_top = tz_top,
            .wc_top = wc_top,
            .date_h = date_h,
            .net_h = net_h,
            .tz_h = tz_h,
            .wc_h = wc_h,
        };
    }

    pub fn totalHeight(self: *Page, g: Geo) i32 {
        if (!self.inited) return 0;
        self.ensureLoaded();
        // Only the System Time page reads the system clock service; each
        // World Clock row is plain tzdata and never needs `timedatectl`.
        if (self.mode == .system) self.querySystem(false);
        const s = self.stack(g);
        const bottom = if (self.mode == .world) s.wc_top + s.wc_h else s.tz_top + s.tz_h;
        return bottom + page_bottom_pad;
    }

    // --- rect helpers (shared by paint and hit) ------------------------

    fn rowBand(s: Stack, top: i32, band: i32) common.Rect {
        return .{ .x = cardX(s.g), .y = top, .w = cardW(s.g), .h = band };
    }

    fn fmtRowRect(s: Stack, i: i32) common.Rect {
        return rowBand(s, s.fmt_top + title_band + i * toggle_band, toggle_band);
    }

    fn switchRect(r: common.Rect) common.Rect {
        return .{
            .x = r.x + r.w - common.card_pad - common.toggle_w,
            .y = r.y + @divTrunc(r.h - common.toggle_h, 2),
            .w = common.toggle_w,
            .h = common.toggle_h,
        };
    }

    fn comboRect(s: Stack) common.Rect {
        return .{
            .x = cardX(s.g) + cardW(s.g) - common.card_pad - common.settings_combo_w,
            .y = s.date_top + title_band + @divTrunc(combo_band - common.settings_combo_h, 2),
            .w = common.settings_combo_w,
            .h = common.settings_combo_h,
        };
    }

    fn customRect(s: Stack) common.Rect {
        return .{
            .x = cardX(s.g) + common.card_pad,
            .y = s.date_top + title_band + combo_band + 54,
            .w = @min(cardW(s.g) - 2 * common.card_pad, custom_field_w),
            .h = field_h,
        };
    }

    /// Width of an outlined pill sized to its label (same padding for all).
    fn btnW(label: []const u8) i32 {
        return @max(btn_min_w, ui_paint.measureTextWidth(label, 12, 500) + 2 * btn_pad_x);
    }

    /// Right-aligned pill in a band: its right edge is `card_pad` from the
    /// card edge — the same lane as the switches and the combo boxes.
    fn btnRight(s: Stack, y: i32, band: i32, w: i32) common.Rect {
        return .{
            .x = cardX(s.g) + cardW(s.g) - common.card_pad - w,
            .y = y + @divTrunc(band - btn_h, 2),
            .w = w,
            .h = btn_h,
        };
    }

    /// Same lane, pushed left by `gap` — the left pill of a pair.
    fn btnRightAt(s: Stack, y: i32, band: i32, w: i32, gap: i32) common.Rect {
        const r = btnRight(s, y, band, w);
        return .{ .x = r.x - gap, .y = r.y, .w = r.w, .h = r.h };
    }

    fn ntpSwitchRect(s: Stack) common.Rect {
        return switchRect(rowBand(s, s.net_top + title_band, toggle_band));
    }

    fn ntpRefreshRect(s: Stack) common.Rect {
        const y = s.net_top + title_band + toggle_band;
        return btnRight(s, y, status_band, btnW("Refresh"));
    }

    fn manualHeadTop(s: Stack) i32 {
        return s.net_top + title_band + toggle_band + status_band;
    }

    fn manualFieldsTop(s: Stack) i32 {
        return manualHeadTop(s) + manual_head_band;
    }

    fn manualDateRect(s: Stack) common.Rect {
        const y = manualFieldsTop(s) + @divTrunc(manual_band - field_h, 2);
        return .{ .x = cardX(s.g) + common.card_pad, .y = y, .w = manual_field_w_date, .h = field_h };
    }

    fn manualTimeRect(s: Stack) common.Rect {
        const dr = manualDateRect(s);
        return .{ .x = dr.x + dr.w + manual_field_gap, .y = dr.y, .w = manual_field_w_time, .h = field_h };
    }

    fn manualSetRect(s: Stack) common.Rect {
        const tr = manualTimeRect(s);
        return .{
            .x = tr.x + tr.w + value_gap,
            .y = manualFieldsTop(s) + @divTrunc(manual_band - btn_h, 2),
            .w = btnW("Set Clock"),
            .h = btn_h,
        };
    }

    fn tzChangeRect(s: Stack) common.Rect {
        return btnRight(s, s.tz_top + title_band, toggle_band, btnW("Change…"));
    }

    fn tzResetRect(s: Stack) common.Rect {
        return btnRight(s, s.tz_top + title_band + toggle_band, toggle_band, btnW("Reset"));
    }

    fn tzSetSysRect(s: Stack) common.Rect {
        const reset = tzResetRect(s);
        return btnRightAt(
            s,
            s.tz_top + title_band + toggle_band,
            toggle_band,
            btnW("Set as System"),
            reset.w + lane_gap,
        );
    }

    fn wcRowRect(s: Stack, i: usize) common.Rect {
        return .{
            .x = cardX(s.g),
            .y = s.wc_top + title_band + @as(i32, @intCast(i)) * city_row_h,
            .w = cardW(s.g),
            .h = city_row_h,
        };
    }

    fn wcRemoveRect(s: Stack, i: usize) common.Rect {
        const r = wcRowRect(s, i);
        return .{
            .x = r.x + r.w - common.card_pad - remove_btn,
            .y = r.y + @divTrunc(r.h - remove_btn, 2),
            .w = remove_btn,
            .h = remove_btn,
        };
    }

    /// First-row y of the World clocks list, then the add button under it.
    fn wcListTop(s: Stack) i32 {
        return s.wc_top + title_band;
    }

    fn wcAddButtonRect(s: Stack, rows: usize) common.Rect {
        const top = wcListTop(s) + @as(i32, @intCast(rows)) * city_row_h;
        return .{
            .x = cardX(s.g) + common.card_pad,
            .y = top + @divTrunc(wc_add_band - btn_h, 2),
            .w = btnW("Add city"),
            .h = btn_h,
        };
    }

    // -----------------------------------------------------------------
    // Paint
    // -----------------------------------------------------------------

    pub fn paint(
        self: *Page,
        c: ?*cairo.cairo_t,
        g: Geo,
        px: f64,
        py: f64,
        glass_ov: f64,
    ) void {
        const cr = c orelse return;
        if (!self.inited) return;
        self.ensureLoaded();
        const s = self.stack(g);
        const x = cardX(g);
        const w = cardW(g);

        // The two Time pages never share a frame: System Time is the
        // format / date / preview / network / timezone stack, World Clock is
        // the shared city editor alone.
        if (self.mode == .world) {
            self.paintWcCard(cr, s, x, w, glass_ov, px, py);
        } else {
            const now_sec = clock_paint.nowSeconds();
            self.paintFormatCard(cr, s, x, w, glass_ov);
            self.paintDateCard(cr, s, x, w, glass_ov, px, py);
            self.paintPreviewCard(cr, s, x, w, glass_ov, now_sec);
            self.paintNetCard(cr, s, x, w, glass_ov, px, py);
            self.paintTzCard(cr, s, x, w, glass_ov, px, py);
            // The open dropdown floats above every card; the modal above
            // that (undone from the scroll translate, exactly like the
            // Desktop Widgets popup).
            if (self.combo_open) self.paintDateDropdown(cr, s, px, py);
        }
        // The picker is a window-space dialog (its dim veil covers the whole
        // frame and `modalDown/Up` hit-test in window space), so it paints
        // above both pages, outside the content clip.
        if (self.picker.open) {
            cairo.cairo_save(cr);
            cairo.cairo_translate(cr, 0, @as(f64, @floatFromInt(g.scroll_px)));
            // Drop the caller's content-column clip: otherwise a narrow
            // window cuts the dialog in half while the invisible part stays
            // clickable (the window-centred layout doesn't know about the
            // sidebar).
            cairo.cairo_reset_clip(cr);
            self.paintPicker(cr, g.win_w, g.win_h, px, py - @as(f64, @floatFromInt(g.scroll_px)));
            cairo.cairo_restore(cr);
        }
    }

    fn divider(cr: *cairo.cairo_t, x: i32, w: i32, y: i32) void {
        const t = common.Theme;
        cairo.cairo_save(cr);
        cairo.cairo_set_line_width(cr, 1.0);
        cairo.cairo_set_source_rgba(cr, t.outline_r, t.outline_g, t.outline_b, 0.15);
        cairo.cairo_move_to(cr, @floatFromInt(x + common.card_pad + 8), @floatFromInt(y));
        cairo.cairo_line_to(cr, @floatFromInt(x + w - common.card_pad - 8), @floatFromInt(y));
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
    }

    /// A two-line row label clipped to `clip_w` px, so it can never run under
    /// the control sharing its lane.
    fn labelClipped(
        cr: *cairo.cairo_t,
        x: f64,
        y: f64,
        label: []const u8,
        desc: []const u8,
        clip_w: f64,
    ) void {
        if (clip_w <= 4.0) return;
        cairo.cairo_save(cr);
        cairo.cairo_rectangle(cr, x, y - 20.0, clip_w, 46.0);
        cairo.cairo_clip(cr);
        ui_paint.settingLabel(cr, x, y, label, desc);
        cairo.cairo_restore(cr);
    }

    /// One-line text right-aligned at `right_x`, hard-clipped to `avail`.
    fn textRight(
        cr: *cairo.cairo_t,
        right_x: f64,
        y: f64,
        text: []const u8,
        avail: f64,
        size: f32,
        weight: c_uint,
        r: f64,
        g: f64,
        b: f64,
        a: f64,
    ) void {
        if (text.len == 0 or avail <= 4.0) return;
        const tw: f64 = @floatFromInt(ui_paint.measureTextWidth(text, size, weight));
        const x = @max(right_x - avail, right_x - tw);
        cairo.cairo_save(cr);
        cairo.cairo_rectangle(cr, right_x - avail, y - @as(f64, size) * 1.4, avail, @as(f64, size) * 2.0);
        cairo.cairo_clip(cr);
        ui_paint.showText(cr, x, y, text, size, weight, r, g, b, a);
        cairo.cairo_restore(cr);
    }

    /// One-line text left-anchored with the same hard clip.
    fn textClipped(
        cr: *cairo.cairo_t,
        x: f64,
        y: f64,
        text: []const u8,
        clip_w: f64,
        size: f32,
        weight: c_uint,
        r: f64,
        g: f64,
        b: f64,
        a: f64,
    ) void {
        if (text.len == 0 or clip_w <= 4.0) return;
        cairo.cairo_save(cr);
        cairo.cairo_rectangle(cr, x, y - @as(f64, size) * 1.4, clip_w, @as(f64, size) * 2.0);
        cairo.cairo_clip(cr);
        ui_paint.showText(cr, x, y, text, size, weight, r, g, b, a);
        cairo.cairo_restore(cr);
    }

    fn paintToggleRow(
        cr: *cairo.cairo_t,
        r: common.Rect,
        title: []const u8,
        desc: []const u8,
        on: bool,
    ) void {
        ui_paint.settingLabel(cr, @floatFromInt(r.x + common.card_pad), @as(f64, @floatFromInt(r.y)) + 26, title, desc);
        const sw = switchRect(r);
        ui_paint.paintSwitch(cr, sw.x, sw.y, sw.w, sw.h, on);
    }

    fn paintFormatCard(self: *Page, cr: *cairo.cairo_t, s: Stack, x: i32, w: i32, ov: f64) void {
        ui_paint.card(cr, @floatFromInt(x), @floatFromInt(s.fmt_top), @floatFromInt(w), @floatFromInt(title_band + 3 * toggle_band), ov);
        ui_paint.catLabel(cr, @floatFromInt(x + common.card_pad), @floatFromInt(s.fmt_top + 21), "Time format");
        const titles = [_][]const u8{ "Use 24-hour format", "Show seconds", "Show date" };
        const descs = [_][]const u8{
            "Show the clock on a 24-hour cycle.",
            "Display seconds in the clock (e.g. 14:30:45).",
            "Display the date below the time.",
        };
        const on = [_]bool{
            self.settings.time_use_24h,
            self.settings.time_show_seconds,
            self.settings.time_show_date,
        };
        var i: i32 = 0;
        while (i < 3) : (i += 1) {
            const r = fmtRowRect(s, i);
            if (i > 0) divider(cr, x, w, r.y);
            paintToggleRow(cr, r, titles[@intCast(i)], descs[@intCast(i)], on[@intCast(i)]);
        }
    }

    fn paintDateCard(self: *Page, cr: *cairo.cairo_t, s: Stack, x: i32, w: i32, ov: f64, px: f64, py: f64) void {
        ui_paint.card(cr, @floatFromInt(x), @floatFromInt(s.date_top), @floatFromInt(w), @floatFromInt(s.date_h), ov);
        ui_paint.catLabel(cr, @floatFromInt(x + common.card_pad), @floatFromInt(s.date_top + 21), "Date format");
        const r = rowBand(s, s.date_top + title_band, combo_band);
        ui_paint.settingLabel(
            cr,
            @floatFromInt(r.x + common.card_pad),
            @as(f64, @floatFromInt(r.y)) + 26,
            "Date format",
            "How the date line under the clock reads.",
        );
        const cr_rect = comboRect(s);
        const idx = std.math.clamp(self.settings.time_date_format, 0, 3);
        const hov = common.pointInRect(px, py, cr_rect);
        paintFieldBox(cr, cr_rect, date_format_labels[@intCast(idx)], "", hov or self.combo_open, "expand_more");
        if (idx == 3) {
            divider(cr, x, w, r.y + combo_band);
            const fr = customRect(s);
            ui_paint.settingLabel(
                cr,
                @floatFromInt(fr.x),
                @as(f64, @floatFromInt(s.date_top + title_band + combo_band)) + 26.0,
                "Custom format",
                "strftime pattern, e.g. %A, %B %d, %Y.",
            );
            paintTextField(cr, fr, self.custom_buf[0..self.custom_len], "%A, %B %d, %Y", self.focus == .custom);
        }
    }

    /// Shared input-box chrome: soft surface, outline on hover/focus, label
    /// (or placeholder), and a trailing chevron for dropdowns.
    fn paintFieldBox(
        cr: *cairo.cairo_t,
        r: common.Rect,
        text: []const u8,
        placeholder: []const u8,
        active: bool,
        chevron: []const u8,
    ) void {
        const t = common.Theme;
        const xf: f64 = @floatFromInt(r.x);
        const yf: f64 = @floatFromInt(r.y);
        const wf: f64 = @floatFromInt(r.w);
        const hf: f64 = @floatFromInt(r.h);
        ui_paint.glassBox(cr, xf, yf, wf, hf, 8, 1, 1, 1, if (active) 0.12 else 0.05);
        cairo.cairo_save(cr);
        ui_paint.roundRect(cr, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, 7.5);
        cairo.cairo_set_line_width(cr, 1.0);
        if (active) {
            cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 0.75);
        } else {
            cairo.cairo_set_source_rgba(cr, t.outline_r, t.outline_g, t.outline_b, 0.55);
        }
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
        const text_x = xf + 12.0;
        // Box text sits 8px above the bottom edge — the rule the other tabs'
        // field painters (and the C++ `settings_paint_combo_closed`) use. An
        // "h/2 + k" anchor reads high in these pills because `showText` is
        // bottom-anchored, not centre-anchored.
        const baseline = yf + hf - 8.0;
        const chev_w: f64 = if (chevron.len > 0) 18.0 else 0.0;
        cairo.cairo_save(cr);
        cairo.cairo_rectangle(cr, text_x, yf + 4.0, wf - 24.0 - chev_w, hf - 8.0);
        cairo.cairo_clip(cr);
        if (text.len == 0 and placeholder.len > 0) {
            ui_paint.showText(cr, text_x, baseline, placeholder, 12, 400, t.text_r, t.text_g, t.text_b, 0.35);
        } else {
            ui_paint.showText(cr, text_x, baseline, text, 12, 400, t.text_r, t.text_g, t.text_b, 0.9);
        }
        cairo.cairo_restore(cr);
        if (chevron.len > 0) {
            ui_paint.glyph(cr, xf + wf - 14.0, yf + hf * 0.5, 16, chevron, t.text_r, t.text_g, t.text_b, 0.9);
        }
    }

    fn paintTextField(cr: *cairo.cairo_t, r: common.Rect, text: []const u8, placeholder: []const u8, focused: bool) void {
        paintFieldBox(cr, r, text, placeholder, focused, "");
        if (focused and caretOn()) {
            const t = common.Theme;
            const text_w = ui_paint.measureTextWidth(text, 12, 400);
            const cx = @as(f64, @floatFromInt(r.x)) + 12.0 + @as(f64, @floatFromInt(text_w)) + 1.5;
            cairo.cairo_set_line_width(cr, 1.4);
            cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.85);
            cairo.cairo_move_to(cr, cx, @as(f64, @floatFromInt(r.y)) + 7.0);
            cairo.cairo_line_to(cr, cx, @as(f64, @floatFromInt(r.y + r.h)) - 7.0);
            cairo.cairo_stroke(cr);
        }
    }

    fn paintPreviewCard(self: *Page, cr: *cairo.cairo_t, s: Stack, x: i32, w: i32, ov: f64, now_sec: i64) void {
        const t = common.Theme;
        ui_paint.card(cr, @floatFromInt(x), @floatFromInt(s.prev_top), @floatFromInt(w), @floatFromInt(title_band + preview_body), ov);
        ui_paint.catLabel(cr, @floatFromInt(x + common.card_pad), @floatFromInt(s.prev_top + 21), "Preview");
        // The sample sits on the same left edge as every label in the page;
        // its zone tag shares the sample's baseline on the right edge.
        const body = s.prev_top + title_band;
        const lx: f64 = @floatFromInt(x + common.card_pad);
        const rx: f64 = @floatFromInt(x + w - common.card_pad);
        const c = self.previewCivil(now_sec);
        var time_buf: [32]u8 = undefined;
        const time_s = timeText(&time_buf, c, self.settings.time_use_24h, self.settings.time_show_seconds);
        ui_paint.showText(cr, lx, @floatFromInt(body + 52), time_s, 30, 600, t.text_r, t.text_g, t.text_b, 0.97);
        if (self.settings.time_show_date) {
            var date_buf: [192]u8 = undefined;
            const date_s = dateText(&date_buf, self.settings.time_date_format, c, self.settings.time_custom_format);
            ui_paint.showText(cr, lx, @floatFromInt(body + 80), date_s, 13, 400, t.text_r, t.text_g, t.text_b, 0.62);
        }
        const zone = if (self.settings.time_timezone.len > 0) self.settings.time_timezone else self.sysTz();
        const zone_s = if (zone.len > 0) zone else "(system timezone)";
        const tw: f64 = @floatFromInt(ui_paint.measureTextWidth(time_s, 30, 600));
        textRight(cr, rx, @floatFromInt(body + 52), zone_s, rx - lx - tw - 24.0, 12, 400, t.text_r, t.text_g, t.text_b, 0.45);
    }

    fn ntpStatusText(self: *const Page) []const u8 {
        if (!self.have_timedatectl and self.queried) return "timedatectl is not available on this system.";
        if (self.ntp_on and self.ntp_synced) return "Synchronized with a network time server.";
        if (self.ntp_on) return "Waiting for NTP synchronization…";
        return "Manual clock — the system will not synchronize automatically.";
    }

    fn paintNetCard(self: *Page, cr: *cairo.cairo_t, s: Stack, x: i32, w: i32, ov: f64, px: f64, py: f64) void {
        const t = common.Theme;
        ui_paint.card(cr, @floatFromInt(x), @floatFromInt(s.net_top), @floatFromInt(w), @floatFromInt(s.net_h), ov);
        ui_paint.catLabel(cr, @floatFromInt(x + common.card_pad), @floatFromInt(s.net_top + 21), "Network time");
        const row = rowBand(s, s.net_top + title_band, toggle_band);
        paintToggleRow(cr, row, "Use network time (NTP)", "Synchronize the clock with network time servers.", self.ntp_on);
        // Status line + refresh pill, one lane.
        const infoTop = row.y + toggle_band;
        divider(cr, x, w, infoTop);
        const rr = ntpRefreshRect(s);
        const status = self.ntpStatusText();
        textClipped(
            cr,
            @floatFromInt(x + common.card_pad),
            @floatFromInt(infoTop + 33),
            status,
            @as(f64, @floatFromInt(rr.x - 16 - (x + common.card_pad))),
            13,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.7,
        );
        ui_paint.paintBtn(cr, rr.x, rr.y, rr.w, rr.h, "Refresh", common.pointInRect(px, py, rr));
        // Manual clock editor while NTP is off.
        if (!self.ntp_on) {
            const head = manualHeadTop(s);
            divider(cr, x, w, head);
            ui_paint.settingLabel(
                cr,
                @floatFromInt(x + common.card_pad),
                @as(f64, @floatFromInt(head)) + 26,
                "Manual clock",
                "Applies `timedatectl set-time` (needs authentication).",
            );
            const dr = manualDateRect(s);
            const tr = manualTimeRect(s);
            paintTextField(cr, dr, self.date_buf[0..self.date_len], "YYYY-MM-DD", self.focus == .date);
            paintTextField(cr, tr, self.time_buf[0..self.time_len], "HH:MM:SS", self.focus == .time);
            const sr = manualSetRect(s);
            ui_paint.paintBtn(cr, sr.x, sr.y, sr.w, sr.h, "Set Clock", common.pointInRect(px, py, sr));
        }
        // Trailing message band (after a toggle attempt, or the set result).
        if (self.ntp_msg_len > 0) {
            const my = s.net_top + s.net_h - info_band;
            divider(cr, x, w, my);
            const r_col: f64 = if (self.ntp_msg_err) 1.0 else 0.55;
            const g_col: f64 = if (self.ntp_msg_err) 0.55 else 0.9;
            const b_col: f64 = if (self.ntp_msg_err) 0.5 else 0.6;
            textClipped(
                cr,
                @floatFromInt(x + common.card_pad),
                @floatFromInt(my + 27),
                self.ntp_msg_buf[0..self.ntp_msg_len],
                @floatFromInt(cardW(s.g) - 2 * common.card_pad),
                13,
                400,
                r_col,
                g_col,
                b_col,
                0.95,
            );
        }
    }

    fn tzValue(self: *Page, buf: []u8) []const u8 {
        const tz = self.settings.time_timezone;
        if (tz.len == 0) return "Using system timezone";
        if (!self.tz_store.zoneKnown(tz)) {
            return std.fmt.bufPrint(buf, "{s} (unknown timezone)", .{tz}) catch tz;
        }
        return tz;
    }

    fn paintTzCard(self: *Page, cr: *cairo.cairo_t, s: Stack, x: i32, w: i32, ov: f64, px: f64, py: f64) void {
        const t = common.Theme;
        ui_paint.card(cr, @floatFromInt(x), @floatFromInt(s.tz_top), @floatFromInt(w), @floatFromInt(s.tz_h), ov);
        ui_paint.catLabel(cr, @floatFromInt(x + common.card_pad), @floatFromInt(s.tz_top + 21), "Timezone");
        const label_x: f64 = @floatFromInt(x + common.card_pad);
        // System row: label block, the reported value, the Change… pill.
        const sys_row = rowBand(s, s.tz_top + title_band, toggle_band);
        const change = tzChangeRect(s);
        const sys_right: f64 = @as(f64, @floatFromInt(change.x - value_gap));
        const sys_txt = self.sysTz();
        const sys_s = if (sys_txt.len > 0) sys_txt else "Unknown";
        textRight(cr, sys_right, @as(f64, @floatFromInt(sys_row.y)) + 34, sys_s, value_lane_w, 12, 400, t.text_r, t.text_g, t.text_b, 0.7);
        labelClipped(
            cr,
            label_x,
            @as(f64, @floatFromInt(sys_row.y)) + 26,
            "System timezone",
            "Reported by the system clock service.",
            sys_right - value_lane_w - 16.0 - label_x,
        );
        ui_paint.paintBtn(cr, change.x, change.y, change.w, change.h, "Change…", common.pointInRect(px, py, change));
        // Override row: the value (accent when set) and the two pills that
        // act on it, all on the same right lane.
        const ov_row = rowBand(s, s.tz_top + title_band + toggle_band, toggle_band);
        divider(cr, x, w, ov_row.y);
        const has_ov = self.settings.time_timezone.len > 0;
        var val_buf: [128]u8 = undefined;
        const val = self.tzValue(&val_buf);
        var val_right: f64 = @as(f64, @floatFromInt(ov_row.x + ov_row.w - common.card_pad));
        if (has_ov) {
            const reset = tzResetRect(s);
            const setsys = tzSetSysRect(s);
            ui_paint.paintBtn(cr, reset.x, reset.y, reset.w, reset.h, "Reset", common.pointInRect(px, py, reset));
            ui_paint.paintBtn(cr, setsys.x, setsys.y, setsys.w, setsys.h, "Set as System", common.pointInRect(px, py, setsys));
            val_right = @as(f64, @floatFromInt(setsys.x - value_gap));
        }
        textRight(
            cr,
            val_right,
            @as(f64, @floatFromInt(ov_row.y)) + 34,
            val,
            value_lane_w,
            12,
            if (has_ov) 500 else 400,
            if (has_ov) t.acc_r else t.text_r,
            if (has_ov) t.acc_g else t.text_g,
            if (has_ov) t.acc_b else t.text_b,
            if (has_ov) 0.95 else 0.6,
        );
        labelClipped(
            cr,
            label_x,
            @as(f64, @floatFromInt(ov_row.y)) + 26,
            "Timezone override",
            "Clocks and cities follow this zone instead of the system one.",
            val_right - value_lane_w - 16.0 - label_x,
        );
        if (self.tz_msg_len > 0) {
            const my = s.tz_top + s.tz_h - info_band;
            divider(cr, x, w, my);
            const err = self.tz_msg_err;
            const r_col = if (err) @as(f64, 1.0) else @as(f64, 0.55);
            const g_col = if (err) @as(f64, 0.55) else @as(f64, 0.9);
            const b_col = if (err) @as(f64, 0.5) else @as(f64, 0.6);
            textClipped(
                cr,
                @floatFromInt(x + common.card_pad),
                @floatFromInt(my + 27),
                self.tz_msg_buf[0..self.tz_msg_len],
                @floatFromInt(cardW(s.g) - 2 * common.card_pad),
                13,
                400,
                r_col,
                g_col,
                b_col,
                0.95,
            );
        }
    }

    fn paintWcCard(self: *Page, cr: *cairo.cairo_t, s: Stack, x: i32, w: i32, ov: f64, px: f64, py: f64) void {
        const t = common.Theme;
        ui_paint.card(cr, @floatFromInt(x), @floatFromInt(s.wc_top), @floatFromInt(w), @floatFromInt(s.wc_h), ov);
        ui_paint.catLabel(cr, @floatFromInt(x + common.card_pad), @floatFromInt(s.wc_top + 21), "World clocks");
        ui_paint.showText(
            cr,
            @floatFromInt(x + common.card_pad),
            @floatFromInt(s.wc_top + 38),
            "Cities shown by the dock and desktop world-clock widgets.",
            11,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.46,
        );
        const now_sec = clock_paint.nowSeconds();
        if (self.wc_tzs.items.len == 0) {
            ui_paint.settingLabel(
                cr,
                @floatFromInt(x + common.card_pad),
                @as(f64, @floatFromInt(wcListTop(s))) + 26,
                "No cities yet",
                "Add one below to show it in both world-clock widgets.",
            );
        }
        for (self.wc_tzs.items, 0..) |tz, i| {
            const r = wcRowRect(s, i);
            if (i > 0) divider(cr, x, w, r.y);
            if (common.pointInRect(px, py, r)) {
                ui_paint.glassBox(cr, @floatFromInt(r.x + 8), @floatFromInt(r.y + 2), @floatFromInt(r.w - 16), @floatFromInt(r.h - 4), 8, t.text_r, t.text_g, t.text_b, 0.04);
            }
            const rem = wcRemoveRect(s, i);
            const label = if (i < self.wc_labels.items.len) self.wc_labels.items[i] else tz;
            labelClipped(
                cr,
                @floatFromInt(r.x + common.card_pad),
                @as(f64, @floatFromInt(r.y)) + 26,
                label,
                tz,
                @as(f64, @floatFromInt(rem.x)) - value_gap - 120.0 - @as(f64, @floatFromInt(r.x + common.card_pad)),
            );
            const c = self.cityCivil(tz, now_sec);
            var tb: [32]u8 = undefined;
            const ts = timeText(&tb, c, self.settings.time_use_24h, false);
            textRight(
                cr,
                @as(f64, @floatFromInt(rem.x - value_gap)),
                @as(f64, @floatFromInt(r.y)) + 38,
                ts,
                120.0,
                13,
                500,
                t.text_r,
                t.text_g,
                t.text_b,
                0.85,
            );
            const hov = common.pointInRect(px, py, rem);
            ui_paint.glassBox(cr, @floatFromInt(rem.x), @floatFromInt(rem.y), @floatFromInt(remove_btn), @floatFromInt(remove_btn), 8, t.bg_r, t.bg_g, t.bg_b, if (hov) 0.96 else 0.9);
            cairo.cairo_save(cr);
            cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, if (hov) 0.9 else 0.52);
            cairo.cairo_set_line_width(cr, 2.0);
            const inset = 9.0;
            const rxf: f64 = @floatFromInt(rem.x);
            const ryf: f64 = @floatFromInt(rem.y);
            cairo.cairo_move_to(cr, rxf + inset, ryf + inset);
            cairo.cairo_line_to(cr, rxf + @as(f64, @floatFromInt(remove_btn)) - inset, ryf + @as(f64, @floatFromInt(remove_btn)) - inset);
            cairo.cairo_move_to(cr, rxf + @as(f64, @floatFromInt(remove_btn)) - inset, ryf + inset);
            cairo.cairo_line_to(cr, rxf + inset, ryf + @as(f64, @floatFromInt(remove_btn)) - inset);
            cairo.cairo_stroke(cr);
            cairo.cairo_restore(cr);
        }
        const add = wcAddButtonRect(s, @max(self.wc_tzs.items.len, 1));
        ui_paint.paintBtn(cr, add.x, add.y, add.w, add.h, "Add city", common.pointInRect(px, py, add));
        ui_paint.showText(
            cr,
            @floatFromInt(add.x + add.w + value_gap),
            @as(f64, @floatFromInt(add.y)) + 19,
            "Stored in world_clock.json and WorldClock.",
            11,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.4,
        );
    }

    fn paintDateDropdown(self: *Page, cr: *cairo.cairo_t, s: Stack, px: f64, py: f64) void {
        const t = common.Theme;
        const r = comboRect(s);
        const idx = std.math.clamp(self.settings.time_date_format, 0, 3);
        var i: i32 = 0;
        while (i < 4) : (i += 1) {
            const ry = r.y + r.h + 2 + i * common.settings_dd_row_h;
            const hov = px >= @as(f64, @floatFromInt(r.x)) and px < @as(f64, @floatFromInt(r.x + r.w)) and
                py >= @as(f64, @floatFromInt(ry)) and py < @as(f64, @floatFromInt(ry + common.settings_dd_row_h));
            if (i == idx or hov) {
                ui_paint.glassBox(cr, @floatFromInt(r.x + 4), @floatFromInt(ry), @floatFromInt(r.w - 8), @floatFromInt(common.settings_dd_row_h), 6, t.acc_r, t.acc_g, t.acc_b, if (i == idx) 0.22 else 0.12);
            }
            ui_paint.showText(cr, @floatFromInt(r.x + 14), @floatFromInt(ry + 18), date_format_labels[@intCast(i)], 12, if (i == idx) 600 else 400, t.text_r, t.text_g, t.text_b, if (i == idx) 0.95 else 0.8);
        }
    }

    // -----------------------------------------------------------------
    // Hit testing (layout space)
    // -----------------------------------------------------------------

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        if (!self.inited) return null;
        if (self.picker.open) return null;
        self.ensureLoaded();
        const s = self.stack(g);

        // World Clock page: the city rows and the add button are the whole
        // page (the picker above them self-routes through the modal* API).
        if (self.mode == .world) {
            for (self.wc_tzs.items, 0..) |_, wi| {
                if (common.pointInRect(px, ly, wcRemoveRect(s, wi))) {
                    self.wcRemove(wi);
                    return .redraw;
                }
            }
            if (common.pointInRect(px, ly, wcAddButtonRect(s, @max(self.wc_tzs.items.len, 1)))) {
                self.openPicker(.add_city);
                return .redraw;
            }
            // Nothing else here is clickable; still land a pending System
            // Time edit if one is waiting.
            return if (self.takeDirty()) .persist else .redraw;
        }

        // The open dropdown swallows: rows first, then the trigger toggles,
        // then any other click just closes it.
        if (self.combo_open) {
            const cr_rect = comboRect(s);
            var i: i32 = 0;
            while (i < 4) : (i += 1) {
                const ry = cr_rect.y + cr_rect.h + 2 + i * common.settings_dd_row_h;
                if (px >= @as(f64, @floatFromInt(cr_rect.x)) and px < @as(f64, @floatFromInt(cr_rect.x + cr_rect.w)) and
                    ly >= @as(f64, @floatFromInt(ry)) and ly < @as(f64, @floatFromInt(ry + common.settings_dd_row_h)))
                {
                    self.combo_open = false;
                    self.setDateFormat(i);
                    return .persist;
                }
            }
            self.combo_open = false;
            return .redraw;
        }

        // Time-format toggles: the whole band.
        var i: i32 = 0;
        while (i < 3) : (i += 1) {
            const r = fmtRowRect(s, i);
            if (common.pointInRect(px, ly, r)) {
                self.moveFocus(.none);
                switch (i) {
                    0 => self.settings.time_use_24h = !self.settings.time_use_24h,
                    1 => self.settings.time_show_seconds = !self.settings.time_show_seconds,
                    else => self.settings.time_show_date = !self.settings.time_show_date,
                }
                self.dirty = true;
                return .persist;
            }
        }

        // Date format combo trigger + custom field.
        if (common.pointInRect(px, ly, comboRect(s))) {
            self.moveFocus(.none);
            self.combo_open = true;
            self.combo_hover = self.settings.time_date_format;
            return .redraw;
        }
        if (self.settings.time_date_format == 3 and common.pointInRect(px, ly, customRect(s))) {
            self.moveFocus(.custom);
            return .redraw;
        }

        // Network time.
        if (common.pointInRect(px, ly, ntpSwitchRect(s))) {
            self.moveFocus(.none);
            self.setNtp(!self.ntp_on);
            return if (self.takeDirty()) .persist else .redraw;
        }
        if (common.pointInRect(px, ly, ntpRefreshRect(s))) {
            self.moveFocus(.none);
            self.clearNtpMsg();
            self.querySystem(true);
            return .redraw;
        }
        if (!self.ntp_on) {
            if (common.pointInRect(px, ly, manualDateRect(s))) {
                if (self.focus != .date) self.seedManualFields();
                self.moveFocus(.date);
                return .redraw;
            }
            if (common.pointInRect(px, ly, manualTimeRect(s))) {
                if (self.focus != .time) self.seedManualFields();
                self.moveFocus(.time);
                return .redraw;
            }
            if (common.pointInRect(px, ly, manualSetRect(s))) {
                self.moveFocus(.none);
                self.runSetClock();
                return .redraw;
            }
        }

        // Timezone.
        if (common.pointInRect(px, ly, tzChangeRect(s))) {
            self.moveFocus(.none);
            self.openPicker(.system_tz);
            return .redraw;
        }
        if (self.settings.time_timezone.len > 0) {
            if (common.pointInRect(px, ly, tzResetRect(s))) {
                self.moveFocus(.none);
                self.setTimezoneOverrideClean();
                self.clearTzMsg();
                return .persist;
            }
            if (common.pointInRect(px, ly, tzSetSysRect(s))) {
                self.moveFocus(.none);
                self.setSystemTz(self.settings.time_timezone);
                return .redraw;
            }
        }

        // A press anywhere else clears focus (committing the custom field).
        self.moveFocus(.none);
        return if (self.takeDirty()) .persist else .redraw;
    }

    fn setTimezoneOverrideClean(self: *Page) void {
        if (self.tz_hold) |old| self.gpa.free(old);
        self.tz_hold = null;
        self.settings.time_timezone = "";
        self.dirty = true;
    }

    fn openPicker(self: *Page, mode: PickerMode) void {
        self.picker.mode = mode;
        self.picker.open = true;
        self.picker.len = 0;
        self.picker.hover = -1;
        self.picker.arm = -1;
        self.picker.scroll = 0;
        self.picker.focus = true;
        self.ensureZones();
        self.pickerRebuild();
    }

    fn ensureZones(self: *Page) void {
        if (self.picker.zones_loaded) return;
        self.picker.zones_loaded = true;
        var all: std.ArrayListUnmanaged([]const u8) = .empty;
        defer all.deinit(self.gpa);
        wc_popup.enumerateZoneinfo(self.gpa, self.io, &all);
        for (all.items) |z| {
            if (!keepZone(z)) {
                self.gpa.free(z);
                continue;
            }
            self.picker.zones.append(self.gpa, z) catch {
                self.gpa.free(z);
                break;
            };
        }
    }

    fn pickerRebuild(self: *Page) void {
        self.picker.filtered.clearRetainingCapacity();
        const needle = self.picker.buf[0..self.picker.len];
        for (self.picker.zones.items) |z| {
            if (needle.len == 0 or containsFold(z, needle)) {
                self.picker.filtered.append(self.gpa, z) catch break;
            }
        }
    }

    fn pickerVisibleH() f64 {
        return dlg_h - dlg_list_top - dlg_list_bottom;
    }

    fn pickerLayout(win_w: i32, win_h: i32) struct { x: f64, y: f64 } {
        const wf: f64 = @floatFromInt(win_w);
        const hf: f64 = @floatFromInt(win_h);
        return .{
            .x = @max(0.0, (wf - dlg_w) * 0.5),
            .y = @max(24.0, (hf - dlg_h) * 0.5),
        };
    }

    fn pickerMaxScroll(self: *const Page) f64 {
        const content = @as(f64, @floatFromInt(self.picker.filtered.items.len)) * dlg_row_h;
        return @max(0.0, content - pickerVisibleH());
    }

    /// Row index under a window-space point, or a control code: -3 close,
    /// -4 search, -1 none.
    fn pickerItemAt(self: *const Page, win_w: i32, win_h: i32, px: f64, py: f64) i32 {
        const l = pickerLayout(win_w, win_h);
        const inside = px >= l.x and px <= l.x + dlg_w and py >= l.y and py <= l.y + dlg_h;
        if (!inside) return -1;
        const close_x = l.x + dlg_w - 22.0 - dlg_close_s;
        const close_y = l.y + 22.0;
        if (px >= close_x and px <= close_x + dlg_close_s and py >= close_y and py <= close_y + dlg_close_s) return -3;
        if (px >= l.x + 16.0 and px <= l.x + dlg_w - 16.0 and py >= l.y + 46.0 and py <= l.y + 80.0) return -4;
        const list_x0 = l.x + 8.0;
        const list_x1 = l.x + dlg_w - 16.0;
        const list_y0 = l.y + dlg_list_top;
        const list_y1 = list_y0 + pickerVisibleH();
        if (px >= list_x0 and px < list_x1 and py >= list_y0 and py < list_y1) {
            const idx = @as(i32, @intFromFloat(@divFloor(py - list_y0 + self.picker.scroll, dlg_row_h)));
            const n: i32 = @intCast(self.picker.filtered.items.len);
            if (idx >= 0 and idx < n) return idx;
            return -1;
        }
        return -1;
    }

    pub fn modalActive(self: *const Page) bool {
        return self.picker.open;
    }

    pub fn modalDown(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (!self.picker.open) return false;
        const l = pickerLayout(win_w, win_h);
        const inside = px >= l.x and px <= l.x + dlg_w and py >= l.y and py <= l.y + dlg_h;
        if (!inside) {
            self.picker.open = false;
            return true;
        }
        self.picker.arm = self.pickerItemAt(win_w, win_h, px, py);
        if (self.picker.arm == -4) self.picker.focus = true;
        return true;
    }

    pub fn modalUp(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (!self.picker.open) return false;
        const armed = self.picker.arm;
        self.picker.arm = -1;
        const item = self.pickerItemAt(win_w, win_h, px, py);
        if (item == -3 and armed == -3) {
            self.picker.open = false;
            return true;
        }
        if (item >= 0 and item == armed) self.pickerApply(item);
        return true;
    }

    pub fn modalMotion(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) void {
        if (!self.picker.open) return;
        self.picker.hover = self.pickerItemAt(win_w, win_h, px, py);
        if (self.picker.hover < 0) self.picker.hover = -1;
    }

    pub fn modalAxis(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64, delta: f64) bool {
        if (!self.picker.open) return false;
        const l = pickerLayout(win_w, win_h);
        const inside = px >= l.x and px <= l.x + dlg_w and py >= l.y and py <= l.y + dlg_h;
        if (!inside) return false;
        self.picker.scroll = std.math.clamp(
            self.picker.scroll + delta * 48.0,
            0.0,
            self.pickerMaxScroll(),
        );
        return true;
    }

    fn pickerApply(self: *Page, idx: i32) void {
        const n: i32 = @intCast(self.picker.filtered.items.len);
        if (idx < 0 or idx >= n) return;
        const tz = self.picker.filtered.items[@intCast(idx)];
        switch (self.picker.mode) {
            .system_tz => {
                self.setTimezoneOverride(tz);
                var buf: [200]u8 = undefined;
                self.setTzMsg(std.fmt.bufPrint(&buf, "Timezone override set to {s}.", .{tz}) catch "Timezone override set.", false);
                self.picker.open = false;
            },
            .add_city => {
                if (self.wcHas(tz)) {
                    self.picker.open = false;
                    return;
                }
                self.wcAppend(tz, null);
                self.saveWorldClocks();
                self.picker.open = false;
            },
        }
    }

    fn pickerSetHover(self: *Page, idx: i32) void {
        const n: i32 = @intCast(self.picker.filtered.items.len);
        if (n == 0) {
            self.picker.hover = -1;
            return;
        }
        self.picker.hover = std.math.clamp(idx, 0, n - 1);
        const visible = pickerVisibleH();
        const top = @as(f64, @floatFromInt(self.picker.hover)) * dlg_row_h;
        if (top < self.picker.scroll) self.picker.scroll = top;
        if (top + dlg_row_h > self.picker.scroll + visible) self.picker.scroll = top + dlg_row_h - visible;
        self.picker.scroll = std.math.clamp(self.picker.scroll, 0.0, self.pickerMaxScroll());
    }

    fn pickerKey(self: *Page, sym: u32, text: []const u8) bool {
        switch (sym) {
            xkb.XKB_KEY_Escape => {
                self.picker.open = false;
                return true;
            },
            xkb.XKB_KEY_Up => {
                const start = if (self.picker.hover < 0) 0 else self.picker.hover;
                self.pickerSetHover(start - 1);
                return true;
            },
            xkb.XKB_KEY_Down => {
                const start = if (self.picker.hover < 0) -1 else self.picker.hover;
                self.pickerSetHover(start + 1);
                return true;
            },
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                const idx = if (self.picker.hover >= 0) self.picker.hover else 0;
                self.pickerApply(idx);
                return true;
            },
            xkb.XKB_KEY_BackSpace => {
                if (self.picker.len > 0) {
                    const before = self.picker.len;
                    popByte(&self.picker.buf, &self.picker.len);
                    if (self.picker.len != before) {
                        self.pickerRebuild();
                        self.pickerSetHover(0);
                    }
                }
                return true;
            },
            else => {
                if (text.len == 0) return true;
                if (text[0] < 0x20) return true;
                const room = self.picker.buf.len - self.picker.len;
                const n = @min(room, text.len);
                if (n > 0) {
                    @memcpy(self.picker.buf[self.picker.len .. self.picker.len + n], text[0..n]);
                    self.picker.len += n;
                    self.pickerRebuild();
                    self.pickerSetHover(0);
                }
                return true;
            },
        }
    }

    // -----------------------------------------------------------------
    // Keys (layout-level: custom / manual fields, dropdown)
    // -----------------------------------------------------------------

    pub fn key(self: *Page, sym: u32, text: []const u8) bool {
        if (!self.inited) return false;
        if (self.picker.open) return self.pickerKey(sym, text);
        if (self.combo_open) {
            switch (sym) {
                xkb.XKB_KEY_Escape => self.combo_open = false,
                xkb.XKB_KEY_Up => if (self.combo_hover > 0) {
                    self.combo_hover -= 1;
                },
                xkb.XKB_KEY_Down => if (self.combo_hover < 3) {
                    self.combo_hover += 1;
                },
                xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                    self.setDateFormat(self.combo_hover);
                    self.combo_open = false;
                },
                else => {},
            }
            return true;
        }
        switch (self.focus) {
            .none => return false,
            .custom => {
                switch (sym) {
                    xkb.XKB_KEY_Escape, xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => self.moveFocus(.none),
                    xkb.XKB_KEY_BackSpace => popByte(&self.custom_buf, &self.custom_len),
                    else => {
                        if (text.len > 0 and text[0] >= 0x20) {
                            const room = self.custom_buf.len - self.custom_len;
                            const n = @min(room, text.len);
                            if (n > 0) {
                                @memcpy(self.custom_buf[self.custom_len .. self.custom_len + n], text[0..n]);
                                self.custom_len += n;
                            }
                        }
                    },
                }
                return true;
            },
            .date => {
                switch (sym) {
                    xkb.XKB_KEY_Escape => self.moveFocus(.none),
                    xkb.XKB_KEY_Tab => self.moveFocus(.time),
                    xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                        self.runSetClock();
                        self.moveFocus(.none);
                    },
                    xkb.XKB_KEY_BackSpace => popByte(&self.date_buf, &self.date_len),
                    else => {
                        if (text.len > 0 and (std.ascii.isDigit(text[0]) or text[0] == '-')) {
                            const room = self.date_buf.len - self.date_len;
                            const n = @min(room, text.len);
                            if (n > 0) {
                                @memcpy(self.date_buf[self.date_len .. self.date_len + n], text[0..n]);
                                self.date_len += n;
                            }
                        }
                    },
                }
                return true;
            },
            .time => {
                switch (sym) {
                    xkb.XKB_KEY_Escape => self.moveFocus(.none),
                    xkb.XKB_KEY_Tab => self.moveFocus(.date),
                    xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                        self.runSetClock();
                        self.moveFocus(.none);
                    },
                    xkb.XKB_KEY_BackSpace => popByte(&self.time_buf, &self.time_len),
                    else => {
                        if (text.len > 0 and (std.ascii.isDigit(text[0]) or text[0] == ':')) {
                            const room = self.time_buf.len - self.time_len;
                            const n = @min(room, text.len);
                            if (n > 0) {
                                @memcpy(self.time_buf[self.time_len .. self.time_len + n], text[0..n]);
                                self.time_len += n;
                            }
                        }
                    },
                }
                return true;
            },
        }
    }

    // -----------------------------------------------------------------
    // Picker paint
    // -----------------------------------------------------------------

    fn paintPicker(self: *Page, cr: *cairo.cairo_t, win_w: i32, win_h: i32, px: f64, py: f64) void {
        const t = common.Theme;
        const l = pickerLayout(win_w, win_h);
        const wf: f64 = @floatFromInt(win_w);
        const hf: f64 = @floatFromInt(win_h);
        // Dim veil.
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.38);
        cairo.cairo_rectangle(cr, 0, 0, wf, hf);
        cairo.cairo_fill(cr);
        // Panel.
        ui_paint.glassBox(cr, l.x, l.y, dlg_w, dlg_h, 16, t.bg_r, t.bg_g, t.bg_b, 0.96);
        ui_paint.showText(cr, l.x + 20.0, l.y + 30.0, if (self.picker.mode == .system_tz) "Select timezone" else "Add a world clock city", 16, 600, t.text_r, t.text_g, t.text_b, 0.95);
        // Close.
        const close_x = l.x + dlg_w - 22.0 - dlg_close_s;
        const close_y = l.y + 22.0;
        const hov_close = self.picker.hover == -3;
        ui_paint.glassBox(cr, close_x, close_y, dlg_close_s, dlg_close_s, 6, t.bg_r, t.bg_g, t.bg_b, if (hov_close) 0.30 else 0.08);
        ui_paint.glyph(cr, close_x + dlg_close_s * 0.5, close_y + dlg_close_s * 0.5, 20, "close", t.text_r, t.text_g, t.text_b, 1.0);
        // Search field: leading glyph, so drawn by hand rather than through
        // `paintFieldBox`.
        const sf_x = l.x + 16.0;
        const sf_y = l.y + 46.0;
        const sf_w = dlg_w - 32.0;
        const sf_h = 34.0;
        ui_paint.glassBox(cr, sf_x, sf_y, sf_w, sf_h, 8, 1, 1, 1, if (self.picker.focus) 0.12 else 0.05);
        cairo.cairo_save(cr);
        ui_paint.roundRect(cr, sf_x + 0.5, sf_y + 0.5, sf_w - 1.0, sf_h - 1.0, 7.5);
        cairo.cairo_set_line_width(cr, 1.0);
        if (self.picker.focus) {
            cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 0.75);
        } else {
            cairo.cairo_set_source_rgba(cr, t.outline_r, t.outline_g, t.outline_b, 0.55);
        }
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
        ui_paint.glyph(cr, sf_x + 18.0, sf_y + sf_h * 0.5, 17.0, "search", t.text_r, t.text_g, t.text_b, 0.5);
        const search_txt = self.picker.buf[0..self.picker.len];
        const text_x = sf_x + 36.0;
        // Same bottom - 8 rule as every other box in the page.
        const baseline = sf_y + sf_h - 8.0;
        cairo.cairo_save(cr);
        cairo.cairo_rectangle(cr, text_x - 2.0, sf_y + 4.0, sf_w - 52.0, sf_h - 8.0);
        cairo.cairo_clip(cr);
        if (search_txt.len == 0) {
            ui_paint.showText(cr, text_x, baseline, "Type a city or region…", 12, 400, t.text_r, t.text_g, t.text_b, 0.35);
        } else {
            ui_paint.showText(cr, text_x, baseline, search_txt, 12, 400, t.text_r, t.text_g, t.text_b, 0.9);
        }
        cairo.cairo_restore(cr);
        if (self.picker.focus and caretOn()) {
            const tw = ui_paint.measureTextWidth(search_txt, 12, 400);
            const cx = text_x + @as(f64, @floatFromInt(tw)) + 1.5;
            cairo.cairo_set_line_width(cr, 1.4);
            cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.85);
            cairo.cairo_move_to(cr, cx, sf_y + 8.0);
            cairo.cairo_line_to(cr, cx, sf_y + sf_h - 8.0);
            cairo.cairo_stroke(cr);
        }
        // List.
        const list_x0 = l.x + 8.0;
        const list_x1 = l.x + dlg_w - 16.0;
        const list_y0 = l.y + dlg_list_top;
        const view_h = pickerVisibleH();
        cairo.cairo_save(cr);
        cairo.cairo_rectangle(cr, list_x0, list_y0, list_x1 - list_x0, view_h);
        cairo.cairo_clip(cr);
        if (self.picker.filtered.items.len == 0) {
            ui_paint.showText(cr, list_x0 + 12.0, list_y0 + 34.0, "No timezones match.", 12, 400, t.text_r, t.text_g, t.text_b, 0.5);
        }
        const first: i64 = @intFromFloat(@divFloor(self.picker.scroll, dlg_row_h));
        var i = @max(first, 0);
        while (i < @as(i64, @intCast(self.picker.filtered.items.len))) : (i += 1) {
            const ry = list_y0 + @as(f64, @floatFromInt(i)) * dlg_row_h - self.picker.scroll;
            if (ry > list_y0 + view_h) break;
            const tz = self.picker.filtered.items[@intCast(i)];
            const row_y = ry;
            const hov = self.picker.hover == @as(i32, @intCast(i)) and
                px >= list_x0 and px < list_x1 and py >= list_y0 and py < list_y0 + view_h;
            if (hov) {
                ui_paint.glassBox(cr, list_x0 + 4.0, row_y + 2.0, list_x1 - list_x0 - 8.0, dlg_row_h - 4.0, 8, t.text_r, t.text_g, t.text_b, 0.07);
            }
            const current = self.pickerCurrent(tz);
            var lb: [128]u8 = undefined;
            const label = prettyZone(&lb, tz);
            ui_paint.showText(cr, list_x0 + 14.0, row_y + 24.0, label, 13, if (current) 700 else 400, t.text_r, t.text_g, t.text_b, if (current) 0.95 else 0.8);
            if (current) {
                ui_paint.glyph(cr, list_x1 - 18.0, row_y + dlg_row_h * 0.5, 18.0, "check", t.acc_r, t.acc_g, t.acc_b, 0.95);
            }
        }
        cairo.cairo_restore(cr);
        // Scrollbar.
        const max = self.pickerMaxScroll();
        if (max > 0.0) {
            const frac = view_h / (view_h + max);
            const bar_h = @max(30.0, view_h * frac);
            const t_off = self.picker.scroll / max;
            const bar_y = list_y0 + t_off * (view_h - bar_h);
            ui_paint.glassBox(cr, list_x1 - 2.0, bar_y, 4.0, bar_h, 2.0, t.text_r, t.text_g, t.text_b, 0.25);
        }
        // Footer hint.
        ui_paint.showText(
            cr,
            l.x + 20.0,
            l.y + dlg_h - 18.0,
            "Esc to close · Enter selects · type to filter",
            10,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.4,
        );
    }

    fn pickerCurrent(self: *Page, tz: []const u8) bool {
        return switch (self.picker.mode) {
            .system_tz => blk: {
                const cur = self.effectiveZone();
                break :blk cur.len > 0 and std.mem.eql(u8, cur, tz);
            },
            .add_city => self.wcHas(tz),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "settings-time: zone filter drops the duplicate subtrees and tab files" {
    const t = std.testing;
    try t.expect(keepZone("America/New_York"));
    try t.expect(keepZone("UTC"));
    try t.expect(!keepZone("posix/America/New_York"));
    try t.expect(!keepZone("right/UTC"));
    try t.expect(!keepZone("SystemV/EST5EDT"));
    try t.expect(!keepZone("localtime"));
    try t.expect(!keepZone("zone.tab"));
    try t.expect(!keepZone("posixrules"));
    try t.expect(!keepZone("+VERSION"));
    try t.expect(!keepZone("GMT"));
}

test "settings-time: folded search finds underscored zones" {
    const t = std.testing;
    try t.expect(containsFold("America/New_York", "new york"));
    try t.expect(containsFold("America/New_York", "NEW_YORK"));
    try t.expect(containsFold("Asia/Tokyo", "tok"));
    try t.expect(!containsFold("Asia/Tokyo", "berlin"));
}

test "settings-time: pretty labels" {
    const t = std.testing;
    var buf: [96]u8 = undefined;
    try t.expectEqualStrings("New York (America)", prettyZone(&buf, "America/New_York"));
    try t.expectEqualStrings("UTC", prettyZone(&buf, "UTC"));
    try t.expectEqualStrings("Buenos Aires (America/Argentina)", prettyZone(&buf, "America/Argentina/Buenos_Aires"));
    try t.expectEqualStrings("Paris", prettyCity(&buf, "Europe/Paris"));
    try t.expectEqualStrings("Kiritimati", prettyCity(&buf, "Pacific/Kiritimati"));
}

test "settings-time: manual field validation" {
    const t = std.testing;
    try t.expect(validDateField("2026-05-21"));
    try t.expect(!validDateField("2026-5-21"));
    try t.expect(!validDateField("20260521"));
    try t.expect(validTimeField("14:30"));
    try t.expect(validTimeField("14:30:45"));
    try t.expect(!validTimeField("4:30"));
    try t.expect(!validTimeField("14-30"));
}

test "settings-time: preview formatting follows the toggles" {
    const t = std.testing;
    const c = tzdata.Civil{ .y = 2026, .mo = 5, .d = 21, .h = 14, .mi = 30, .s = 45, .wday = 3 };
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("14:30:45", timeText(&buf, c, true, true));
    try t.expectEqualStrings("14:30", timeText(&buf, c, true, false));
    try t.expectEqualStrings("2:30 PM", timeText(&buf, c, false, false));
    var dbuf: [192]u8 = undefined;
    try t.expectEqualStrings("Wed 21", dateText(&dbuf, 0, c, ""));
    try t.expectEqualStrings("Wednesday, May 21, 2026", dateText(&dbuf, 1, c, ""));
    try t.expectEqualStrings("2026-05-21", dateText(&dbuf, 2, c, ""));
    try t.expectEqualStrings("2026/05/21", dateText(&dbuf, 3, c, "%Y/%m/%d"));
}

test "settings-time: world-clock files round-trip both stores" {
    const t = std.testing;
    const alloc = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    const json_path = try std.fs.path.join(alloc, &.{ root, "world_clock.json" });
    defer alloc.free(json_path);
    const wc_path = try std.fs.path.join(alloc, &.{ root, "WorldClock" });
    defer alloc.free(wc_path);

    var settings = app_mod.Settings{};
    var page = Page{};
    page.init(alloc, std.testing.io, &settings);
    page.query_enabled = false;
    defer page.deinit();
    page.json_path_override = json_path;
    page.wc_path_override = wc_path;

    page.ensureLoaded();
    try t.expectEqual(@as(usize, 0), page.wc_tzs.items.len);

    page.wcAppend("Europe/Paris", null);
    page.wcAppend("America/New_York", null);
    page.wcAppend("Europe/Paris", null); // duplicate is dropped
    try t.expectEqual(@as(usize, 2), page.wc_tzs.items.len);
    page.saveWorldClocks();

    const json = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, json_path, alloc, .limited(1 << 16));
    defer alloc.free(json);
    try t.expect(std.mem.indexOf(u8, json, "\"tz\":[\"Europe/Paris\",\"America/New_York\"]") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"h24\":true") != null);

    const wc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, wc_path, alloc, .limited(1 << 16));
    defer alloc.free(wc);
    try t.expect(std.mem.indexOf(u8, wc, "city_1_tz = \"Europe/Paris\"") != null);
    try t.expect(std.mem.indexOf(u8, wc, "city_2_tz = \"America/New_York\"") != null);
    try t.expect(std.mem.indexOf(u8, wc, "city_2_label = \"New York\"") != null);

    // A second page loads the merged list back.
    var page2 = Page{};
    page2.init(alloc, std.testing.io, &settings);
    page2.query_enabled = false;
    defer page2.deinit();
    page2.json_path_override = json_path;
    page2.wc_path_override = wc_path;
    page2.ensureLoaded();
    try t.expectEqual(@as(usize, 2), page2.wc_tzs.items.len);
    try t.expectEqualStrings("Europe/Paris", page2.wc_tzs.items[0]);
    try t.expectEqualStrings("New York", page2.wc_labels.items[1]);

    // Removing the first city drops it from both files.
    page2.wcRemove(0);
    try t.expectEqual(@as(usize, 1), page2.wc_tzs.items.len);
    const json2 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, json_path, alloc, .limited(1 << 16));
    defer alloc.free(json2);
    try t.expect(std.mem.indexOf(u8, json2, "Europe/Paris") == null);
}

test "settings-time: picker geometry keeps rows inside the dialog" {
    const t = std.testing;
    var settings = app_mod.Settings{};
    var page = Page{};
    page.init(t.allocator, std.testing.io, &settings);
    page.query_enabled = false;
    defer page.deinit();
    page.picker.open = true;
    page.picker.mode = .add_city;
    page.picker.buf[0] = 'p';
    page.picker.buf[1] = 'a';
    page.picker.len = 2;
    page.pickerRebuild(); // empty zones list: just must not crash

    // A press on the backdrop closes; a press inside the panel is consumed.
    const l = Page.pickerLayout(900, 700);
    try t.expect(page.modalDown(900, 700, 5.0, 5.0));
    _ = page.modalUp(900, 700, 5.0, 5.0);
    try t.expect(!page.picker.open);
    page.picker.open = true;
    try t.expect(page.modalDown(900, 700, l.x + 40.0, l.y + 200.0));
    try t.expect(page.modalUp(900, 700, l.x + 40.0, l.y + 200.0));
    try t.expect(page.picker.open);
}

test "settings-time: stack and controls stay consistent" {
    const t = std.testing;
    var settings = app_mod.Settings{};
    var page = Page{};
    page.init(t.allocator, std.testing.io, &settings);
    page.query_enabled = false;
    defer page.deinit();
    const g = Geo{ .content_x = 386, .content_w = 498, .win_w = 900, .win_h = 700, .scroll_px = 0 };
    const s = page.stack(g);
    try t.expect(s.date_top > s.fmt_top);
    try t.expect(s.prev_top > s.date_top);
    try t.expect(s.net_top > s.prev_top);
    try t.expect(s.tz_top > s.net_top);
    try t.expect(s.wc_top > s.tz_top);
    // The NTP switch sits in the first Network-time band.
    const sw = Page.ntpSwitchRect(s);
    try t.expectEqual(s.net_top + title_band + @divTrunc(toggle_band - common.toggle_h, 2), sw.y);
    // The custom band only exists for the Custom format.
    settings.time_date_format = 3;
    const s2 = page.stack(g);
    try t.expectEqual(s.date_h + custom_band, s2.date_h);
    // The add-city button is under the rows: rows end at `wcListTop + n *
    // city_row_h`, then the add band centers the button in it.
    const add = Page.wcAddButtonRect(s2, 2);
    try t.expectEqual(Page.wcListTop(s2) + 2 * city_row_h + @divTrunc(wc_add_band - btn_h, 2), add.y);
}

test "settings-time: the two Time pages share the page, not the layout" {
    const t = std.testing;
    var settings = app_mod.Settings{};
    var page = Page{};
    page.init(t.allocator, std.testing.io, &settings);
    page.query_enabled = false;
    defer page.deinit();
    const g = Geo{ .content_x = 386, .content_w = 498, .win_w = 900, .win_h = 700, .scroll_px = 0 };

    // Both Time-category tabs resolve to this page; nothing else does.
    try t.expect(ownsTab(30) and ownsTab(84));
    try t.expect(!ownsTab(31) and !ownsTab(83));

    // System Time: the city card is laid out below the timezone card (and
    // no longer painted); the page bottom is the timezone card's.
    const sys = page.stack(g);
    try t.expect(sys.wc_top > sys.tz_top);
    try t.expectEqual(sys.tz_top + sys.tz_h + page_bottom_pad, page.totalHeight(g));

    // World Clock: the city card is the whole page, top-aligned, and the
    // page bottom is that card's.
    page.setMode(.world);
    try t.expectEqual(Mode.world, page.mode);
    const wc = page.stack(g);
    try t.expectEqual(common.content_top, wc.wc_top);
    try t.expectEqual(wc.wc_top + wc.wc_h + page_bottom_pad, page.totalHeight(g));
    // Rows and the add button stay inside the card.
    page.wcAppend("Europe/Paris", null);
    page.wcAppend("America/New_York", null);
    const wc3 = page.stack(g);
    const row = Page.wcRowRect(wc3, 1);
    try t.expect(row.y + row.h <= wc3.wc_top + wc3.wc_h);
    const add3 = Page.wcAddButtonRect(wc3, 2);
    try t.expect(add3.y + add3.h <= wc3.wc_top + wc3.wc_h);

    // Switching pages drops the other page's transient controls: an open
    // picker (World Clock) or dropdown (System Time) never leaks across.
    page.picker.open = true;
    page.combo_open = true;
    page.setMode(.system);
    try t.expect(!page.picker.open and !page.combo_open);
    try t.expectEqual(Mode.system, page.mode);
}
