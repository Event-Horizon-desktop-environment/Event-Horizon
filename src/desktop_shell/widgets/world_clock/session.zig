//! World clock state for the taskbar widget and its popup: the persisted
//! settings (clock list, 24-hour, seconds, pin), the rotating face's index
//! and slide animation, the popup's transient state, and the time math the
//! painters share.
//!
//! This module is plain data and arithmetic over the IANA database in
//! `tzdata.zig` — no cairo, no surfaces — so the rotation rules, the
//! formatting and the settings round-trip are testable without a window.
//! Rendering lives in `face.zig` / `panel.zig`; the taskbar owns the
//! surfaces and the timers.
//!
//! The reduced-motion port knob is the `EH_REDUCED_MOTION` environment
//! variable (any value but `0`): it skips every animation and makes the
//! rotation swap instantly, standing in for the reference's
//! `prefers-reduced-motion` media query.

const std = @import("std");
const tzdata = @import("tzdata.zig");
const config = @import("../../../config.zig");

pub const max_clocks = 40;
pub const shift_step = 30;
pub const shift_limit = 720;

pub const slide_out_ms: u64 = 140;
pub const slide_in_ms: u64 = 200;
pub const rotate_seconds: u32 = 5;

/// One add-pane entry. The name is what rows show; the id is the zone.
pub const Preset = struct { name: []const u8, id: []const u8 };

/// The 34 city presets, in the reference's order.
pub const presets = [_]Preset{
    .{ .name = "Honolulu", .id = "Pacific/Honolulu" },
    .{ .name = "Anchorage", .id = "America/Anchorage" },
    .{ .name = "Los Angeles", .id = "America/Los_Angeles" },
    .{ .name = "Denver", .id = "America/Denver" },
    .{ .name = "Chicago", .id = "America/Chicago" },
    .{ .name = "New York", .id = "America/New_York" },
    .{ .name = "Toronto", .id = "America/Toronto" },
    .{ .name = "Mexico City", .id = "America/Mexico_City" },
    .{ .name = "São Paulo", .id = "America/Sao_Paulo" },
    .{ .name = "Buenos Aires", .id = "America/Argentina/Buenos_Aires" },
    .{ .name = "Reykjavik", .id = "Atlantic/Reykjavik" },
    .{ .name = "London", .id = "Europe/London" },
    .{ .name = "Lisbon", .id = "Europe/Lisbon" },
    .{ .name = "Paris", .id = "Europe/Paris" },
    .{ .name = "Berlin", .id = "Europe/Berlin" },
    .{ .name = "Rome", .id = "Europe/Rome" },
    .{ .name = "Athens", .id = "Europe/Athens" },
    .{ .name = "Istanbul", .id = "Europe/Istanbul" },
    .{ .name = "Cairo", .id = "Africa/Cairo" },
    .{ .name = "Lagos", .id = "Africa/Lagos" },
    .{ .name = "Nairobi", .id = "Africa/Nairobi" },
    .{ .name = "Moscow", .id = "Europe/Moscow" },
    .{ .name = "Dubai", .id = "Asia/Dubai" },
    .{ .name = "Karachi", .id = "Asia/Karachi" },
    .{ .name = "Mumbai", .id = "Asia/Kolkata" },
    .{ .name = "Dhaka", .id = "Asia/Dhaka" },
    .{ .name = "Bangkok", .id = "Asia/Bangkok" },
    .{ .name = "Singapore", .id = "Asia/Singapore" },
    .{ .name = "Hong Kong", .id = "Asia/Hong_Kong" },
    .{ .name = "Shanghai", .id = "Asia/Shanghai" },
    .{ .name = "Seoul", .id = "Asia/Seoul" },
    .{ .name = "Tokyo", .id = "Asia/Tokyo" },
    .{ .name = "Sydney", .id = "Australia/Sydney" },
    .{ .name = "Auckland", .id = "Pacific/Auckland" },
};

const default_clocks = [_][]const u8{
    "Europe/London", "America/New_York", "Asia/Tokyo", "Australia/Sydney",
};

pub fn presetName(id: []const u8) ?[]const u8 {
    for (presets) |p| {
        if (std.mem.eql(u8, p.id, id)) return p.name;
    }
    return null;
}

const weekday_names = [_][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};
const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

pub fn weekdayName(w: u32) []const u8 {
    return weekday_names[w % 7];
}

pub fn monthName(m: u32) []const u8 {
    if (m < 1 or m > 12) return "";
    return month_names[m - 1];
}

/// One clock's time split into the pieces the row and the widget paint:
/// `hm` (`21:42`, or `9:42` in 12-hour mode), `ss` (`:07`, only when asked)
/// and `ap` (`PM`, only in 12-hour mode).
pub const TimeVec = struct {
    hm_buf: [12]u8 = undefined,
    hm_len: usize = 0,
    ss_buf: [4]u8 = undefined,
    ss_len: usize = 0,
    ap_buf: [4]u8 = undefined,
    ap_len: usize = 0,

    pub fn hm(self: *const TimeVec) []const u8 {
        return self.hm_buf[0..self.hm_len];
    }
    pub fn ss(self: *const TimeVec) []const u8 {
        return self.ss_buf[0..self.ss_len];
    }
    pub fn ap(self: *const TimeVec) []const u8 {
        return self.ap_buf[0..self.ap_len];
    }
};

pub fn timeVec(c: tzdata.Civil, h24: bool, with_secs: bool) TimeVec {
    var v = TimeVec{};
    if (h24) {
        const s = std.fmt.bufPrint(&v.hm_buf, "{d:0>2}:{d:0>2}", .{ c.h, c.mi }) catch "";
        v.hm_len = s.len;
    } else {
        var h12 = c.h % 12;
        if (h12 == 0) h12 = 12;
        const s = std.fmt.bufPrint(&v.hm_buf, "{d}:{d:0>2}", .{ h12, c.mi }) catch "";
        v.hm_len = s.len;
        const ap = if (c.h >= 12) "PM" else "AM";
        @memcpy(v.ap_buf[0..2], ap);
        v.ap_len = 2;
    }
    if (with_secs) {
        const s = std.fmt.bufPrint(&v.ss_buf, ":{d:0>2}", .{c.s}) catch "";
        v.ss_len = s.len;
    }
    return v;
}

/// `dur` from the reference: `+8h`, `−5h`, `+5h 30m`, `+45m`; `same time`
/// at zero. The minus is U+2212.
pub fn durText(buf: []u8, m: i32) []const u8 {
    const a: u32 = @intCast(@abs(m));
    if (a == 0) return "same time";
    const h = a / 60;
    const r = a % 60;
    const sign = if (m < 0) "\u{2212}" else "+";
    const s = if (h > 0 and r > 0)
        std.fmt.bufPrint(buf, "{s}{d}h {d}m", .{ sign, h, r })
    else if (h > 0)
        std.fmt.bufPrint(buf, "{s}{d}h", .{ sign, h })
    else
        std.fmt.bufPrint(buf, "{s}{d}m", .{ sign, r }) catch return buf[0..0];
    return s catch buf[0..0];
}

/// `dayLabel` from the reference: Today / Tomorrow / Yesterday / `+N days`.
pub fn dayLabel(buf: []u8, d: i32) []const u8 {
    const fixed: ?[]const u8 = switch (d) {
        0 => "Today",
        1 => "Tomorrow",
        -1 => "Yesterday",
        else => null,
    };
    if (fixed) |s| {
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }
    const sign = if (d > 0) "+" else "\u{2212}";
    return std.fmt.bufPrint(buf, "{s}{d} days", .{ sign, @abs(d) }) catch buf[0..0];
}

/// A cubic-bezier timing function evaluated at `t` (the CSS `ease-in` is
/// `(0.42, 0, 1, 1)`, the popup curve is `(0.2, 0.7, 0.2, 1)`).
pub fn bezierEase(x1: f64, y1: f64, x2: f64, y2: f64, t_in: f64) f64 {
    const t = std.math.clamp(t_in, 0.0, 1.0);
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    var lo: f64 = 0.0;
    var hi: f64 = 1.0;
    var s: f64 = t;
    for (0..24) |_| {
        s = (lo + hi) * 0.5;
        if (bezierAxis(x1, x2, s) < t) lo = s else hi = s;
    }
    return bezierAxis(y1, y2, s);
}

fn bezierAxis(p1: f64, p2: f64, t: f64) f64 {
    const u = 1.0 - t;
    return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t;
}

// Panel (popup) transient state

pub const Focus = union(enum) {
    /// Nothing focused yet: the resting state after opening the popup.
    none,
    pin: usize,
    del: usize,
    slider,
    reset,
    sw_h24,
    sw_sec,
};

pub const HoverTarget = union(enum) {
    none,
    row_pin: usize,
    row_del: usize,
    reset,
    sw_h24,
    sw_sec,
    slider,
};

pub const Panel = struct {
    open_ms: u64 = 0,
    shift_min: i32 = 0,
    focus: Focus = .none,
    focus_visible: bool = false,
    hover: HoverTarget = .none,
    /// The row the pointer is over, for the row background and the action
    /// fade; -1 when none. The fade also tracks which row it came from.
    hover_row: i32 = -1,
    prev_hover_row: i32 = -1,
    hover_ms: u64 = 0,
    dragging_slider: bool = false,
    /// Scroll offset of the city list, in natural pixels.
    scroll_list: f64 = 0,
    /// Timestamps for the small transitions: switch thumbs (150ms).
    sw_h24_ms: u64 = 0,
    sw_sec_ms: u64 = 0,
};

pub const SlidePhase = enum { out, in };

pub const Slide = struct {
    active: bool = false,
    phase: SlidePhase = .out,
    start_ms: u64 = 0,
    dir: i32 = 1,
    from: usize = 0,
    to: usize = 0,
};

pub const SlideFx = struct {
    /// Vertical offset as a fraction of the text block height (positive is
    /// downward), already multiplied by the direction.
    dy: f64 = 0,
    alpha: f64 = 1,
};

pub const TickResult = struct {
    second: bool = false,
    minute: bool = false,
    /// The widget's city advanced (or the swap happened): repaint the bar.
    face: bool = false,
};

/// One stored clock: the zone id, owned. Display names are derived.
const Clock = struct {
    id: []u8,
};

/// The JSON shape of the session's store, `<leaf>/world_clock.json`.
const Disk = struct {
    tz: []const []const u8 = &.{},
    h24: bool = true,
    sec: bool = false,
    pin: ?[]const u8 = null,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    tz: tzdata.Store,

    clocks: std.ArrayListUnmanaged(Clock) = .empty,
    h24: bool = true,
    sec: bool = false,
    pin_id: ?[]u8 = null,
    /// Settings changed since the last `save`.
    dirty: bool = false,

    // Runtime state (nothing below is persisted).
    idx: usize = 0,
    acc: u32 = 0,
    hover: bool = false,
    open: bool = false,
    reduce_motion: bool = false,
    slide: Slide = .{},
    last_sec: i64 = -1,
    p: Panel = .{},

    /// Scratch for `nameOf`'s derived names; callers must consume the slice
    /// before calling `nameOf` again.
    name_scratch: [160]u8 = undefined,

    /// Test hook: when set, settings live at this exact path instead of the
    /// config leaf.
    path_override: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Session {
        var s = Session{ .gpa = gpa, .io = io, .tz = tzdata.Store.init(gpa, io) };
        if (std.c.getenv("EH_REDUCED_MOTION")) |p| {
            const v = std.mem.span(p);
            if (!(v.len == 0 or std.mem.eql(u8, v, "0"))) s.reduce_motion = true;
        }
        return s;
    }

    pub fn deinit(self: *Session) void {
        self.clearClocks();
        self.clocks.deinit(self.gpa);
        self.setPinRaw(null);
        self.tz.deinit();
    }

    fn clearClocks(self: *Session) void {
        for (self.clocks.items) |c| self.gpa.free(c.id);
        self.clocks.clearRetainingCapacity();
    }

    fn appendClock(self: *Session, id: []const u8) bool {
        if (self.clocks.items.len >= max_clocks) return false;
        const id_dup = self.gpa.dupe(u8, id) catch return false;
        self.clocks.append(self.gpa, .{ .id = id_dup }) catch {
            self.gpa.free(id_dup);
            return false;
        };
        return true;
    }

    fn setPinRaw(self: *Session, id: ?[]const u8) void {
        if (self.pin_id) |p| self.gpa.free(p);
        self.pin_id = if (id) |v| self.gpa.dupe(u8, v) catch null else null;
    }

    /// Load settings from the shell config file; anything missing or broken
    /// falls back to the defaults, and unknown zones are dropped.
    pub fn load(self: *Session) void {
        self.clearClocks();
        self.h24 = true;
        self.sec = false;
        self.setPinRaw(null);
        self.idx = 0;

        var path_buf: [512]u8 = undefined;
        const path = self.configFilePath(&path_buf) orelse {
            self.installDefaults();
            return;
        };
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(1 << 16)) catch {
            self.installDefaults();
            return;
        };
        defer self.gpa.free(bytes);

        var parsed = std.json.parseFromSlice(Disk, self.gpa, bytes, .{ .ignore_unknown_fields = true }) catch {
            self.installDefaults();
            return;
        };
        defer parsed.deinit();
        const d = parsed.value;

        self.h24 = d.h24;
        self.sec = d.sec;
        const local = self.localId();
        for (d.tz) |id| {
            if (id.len == 0 or self.clocks.items.len >= max_clocks) continue;
            if (local.len > 0 and std.mem.eql(u8, id, local)) continue;
            if (self.containsStored(id)) continue;
            if (!self.tz.zoneKnown(id)) continue;
            _ = self.appendClock(id);
        }
        if (d.pin) |p| {
            if (self.containsWorking(p)) self.setPinRaw(p);
        }
        self.dirty = false;
    }

    /// Adopt the file only when it says something else than the session
    /// already holds, and report whether it did. Settings > Time rewrites the
    /// store while the shell runs (the watcher wakes every reader), but the
    /// session's *own* `save` — a popup switch — comes back through the same
    /// watcher: re-adopting that would reset the popup's cursor and re-measure
    /// the face for nothing, so an equal file is a no-op. A missing or
    /// unparseable file is left alone too: the writer owns it, and half-written
    /// JSON must not blank the widget.
    pub fn reload(self: *Session) bool {
        if (!self.diskDiffers()) return false;
        self.load();
        return true;
    }

    /// True when the store parses and differs from the session's settings,
    /// judged under the acceptance rules `load` applies: empty, local-zone,
    /// unknown-zone and duplicate ids drop, `max_clocks` caps the list, and
    /// the pin counts only when it names a working clock.
    fn diskDiffers(self: *Session) bool {
        var path_buf: [512]u8 = undefined;
        const path = self.configFilePath(&path_buf) orelse return false;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(1 << 16)) catch return false;
        defer self.gpa.free(bytes);
        var parsed = std.json.parseFromSlice(Disk, self.gpa, bytes, .{ .ignore_unknown_fields = true }) catch return false;
        defer parsed.deinit();
        const d = parsed.value;

        if (d.h24 != self.h24 or d.sec != self.sec) return true;
        const local = self.localId();
        var accepted: [max_clocks][]const u8 = undefined;
        var n: usize = 0;
        for (d.tz) |id| {
            if (n == accepted.len) break;
            if (id.len == 0) continue;
            if (local.len > 0 and std.mem.eql(u8, id, local)) continue;
            if (!self.tz.zoneKnown(id)) continue;
            var dup = false;
            for (accepted[0..n]) |seen| {
                if (std.mem.eql(u8, seen, id)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            accepted[n] = id;
            n += 1;
        }
        if (n != self.clocks.items.len) return true;
        for (self.clocks.items, 0..) |c, i| {
            if (!std.mem.eql(u8, c.id, accepted[i])) return true;
        }
        const disk_pin: ?[]const u8 = if (d.pin) |p| blk: {
            if (p.len == 0) break :blk null;
            if (local.len > 0 and std.mem.eql(u8, p, local)) break :blk p;
            for (accepted[0..n]) |seen| {
                if (std.mem.eql(u8, seen, p)) break :blk p;
            }
            break :blk null;
        } else null;
        const held: ?[]const u8 = self.pin_id;
        if (disk_pin == null or held == null) return (disk_pin == null) != (held == null);
        return !std.mem.eql(u8, disk_pin.?, held.?);
    }

    fn installDefaults(self: *Session) void {
        self.clearClocks();
        const local = self.localId();
        for (default_clocks) |id| {
            if (local.len > 0 and std.mem.eql(u8, id, local)) continue;
            _ = self.appendClock(id);
        }
        self.h24 = true;
        self.sec = false;
        self.setPinRaw(null);
        self.dirty = false;
    }

    /// Write settings back atomically; failures leave the file alone and
    /// never propagate.
    pub fn save(self: *Session) void {
        self.dirty = false;
        var path_buf: [512]u8 = undefined;
        const path = self.configFilePath(&path_buf) orelse return;
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\"tz\":[") catch return;
        for (self.clocks.items, 0..) |c, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.print("\"{s}\"", .{c.id}) catch return;
        }
        w.writeAll("],\"h24\":") catch return;
        w.writeAll(if (self.h24) "true" else "false") catch return;
        w.writeAll(",\"sec\":") catch return;
        w.writeAll(if (self.sec) "true" else "false") catch return;
        w.writeAll(",\"pin\":") catch return;
        if (self.pin_id) |p| {
            w.print("\"{s}\"", .{p}) catch return;
        } else {
            w.writeAll("null") catch return;
        }
        w.writeAll("}\n") catch return;

        const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
        const dir = path[0..dir_end];
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(self.io, dir) catch {};
        var tmp_buf: [560]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return;
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = aw.written() }) catch return;
        cwd.rename(tmp, cwd, path, self.io) catch {
            cwd.deleteFile(self.io, tmp) catch {};
        };
    }

    /// `$XDG_CONFIG_HOME/<leaf>/world_clock.json`, else `~/.config/...`,
    /// else `/tmp` — the same leaf the rest of the shell uses.
    fn configFilePath(self: *Session, buf: *[512]u8) ?[]const u8 {
        if (self.path_override) |p| return p;
        const leaf = config.leafName();
        if (std.c.getenv("XDG_CONFIG_HOME")) |p| {
            const s = std.mem.span(p);
            if (s.len > 0)
                return std.fmt.bufPrint(buf, "{s}/{s}/world_clock.json", .{ s, leaf }) catch null;
        }
        if (std.c.getenv("HOME")) |p| {
            const home = std.mem.span(p);
            if (home.len > 0)
                return std.fmt.bufPrint(buf, "{s}/.config/{s}/world_clock.json", .{ home, leaf }) catch null;
        }
        return std.fmt.bufPrint(buf, "/tmp/{s}/world_clock.json", .{leaf}) catch null;
    }

    // Working list

    /// The working list is the local zone first, then the stored clocks;
    /// entries equal to the local zone were dropped at load/add time.
    pub fn count(self: *const Session) usize {
        return 1 + self.clocks.items.len;
    }

    /// Zone id at working index `i`; `""` is the local zone.
    pub fn idAt(self: *const Session, i: usize) []const u8 {
        if (i == 0 or i > self.clocks.items.len) return "";
        return self.clocks.items[i - 1].id;
    }

    pub fn isLocal(id: []const u8) bool {
        return id.len == 0;
    }

    /// The local zone's IANA id, or "" when it cannot be told.
    pub fn localId(self: *Session) []const u8 {
        return self.tz.localId();
    }

    /// Display name: preset name, else the last path segment with
    /// underscores as spaces. `""` (the local marker) resolves through the
    /// local id. The returned slice lives in `name_scratch`, so consume it
    /// before calling again.
    pub fn nameOf(self: *Session, id: []const u8) []const u8 {
        const zid = if (id.len == 0) self.localId() else id;
        if (zid.len == 0) return "Local";
        if (presetName(zid)) |n| return n;
        const seg = if (std.mem.lastIndexOfScalar(u8, zid, '/')) |at| zid[at + 1 ..] else zid;
        const n = @min(seg.len, self.name_scratch.len);
        @memcpy(self.name_scratch[0..n], seg[0..n]);
        for (self.name_scratch[0..n]) |*ch| {
            if (ch.* == '_') ch.* = ' ';
        }
        return self.name_scratch[0..n];
    }

    pub fn current(self: *const Session) usize {
        const n = self.count();
        if (n == 0) return 0;
        // A pin holds the face on the pinned city regardless of `idx`.
        if (self.pin_id) |p| return self.indexOf(p);
        return self.idx % n;
    }

    pub fn currentId(self: *const Session) []const u8 {
        return self.idAt(self.current());
    }

    pub fn pinned(self: *const Session) bool {
        return self.pin_id != null;
    }

    pub fn containsStored(self: *const Session, id: []const u8) bool {
        for (self.clocks.items) |c| {
            if (std.mem.eql(u8, c.id, id)) return true;
        }
        return false;
    }

    /// Is this id already in the working list (stored or local)?
    pub fn containsWorking(self: *Session, id: []const u8) bool {
        const local = self.localId();
        if (local.len > 0 and std.mem.eql(u8, id, local)) return true;
        return self.containsStored(id);
    }

    // Mutations (callers save)

    pub fn setPin(self: *Session, id: ?[]const u8) void {
        if (id) |v| {
            if (self.pin_id) |p| {
                if (std.mem.eql(u8, p, v)) return;
            }
        } else if (self.pin_id == null) return;
        self.setPinRaw(id);
        if (id) |v| {
            // The widget shows the pinned city immediately, no slide.
            self.slide = .{};
            self.idx = self.indexOf(v);
        }
        self.dirty = true;
    }

    /// Toggle a pin on a working-list index; the local row pins the local
    /// zone's real id.
    pub fn togglePinAt(self: *Session, i: usize) void {
        const raw = self.idAt(i);
        const id = if (raw.len == 0) self.localId() else raw;
        if (id.len == 0) return; // unknown local id: nothing to pin
        if (self.pin_id) |p| {
            if (std.mem.eql(u8, p, id)) {
                self.setPin(null);
                return;
            }
        }
        self.setPin(id);
    }

    fn indexOf(self: *const Session, id: []const u8) usize {
        for (self.clocks.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.id, id)) return i + 1;
        }
        return 0;
    }

    /// Remove working-list index `i` (never 0). Clamps `idx`.
    pub fn removeAt(self: *Session, i: usize) void {
        if (i == 0 or i > self.clocks.items.len) return;
        const c = self.clocks.items[i - 1];
        if (self.pin_id) |p| {
            if (std.mem.eql(u8, p, c.id)) self.setPinRaw(null);
        }
        self.gpa.free(c.id);
        _ = self.clocks.orderedRemove(i - 1);
        if (self.idx >= self.count()) self.idx = self.count() - 1;
        self.slide = .{};
        self.dirty = true;
    }

    /// Append a preset city; refuses duplicates of the working list and
    /// unknown ids. Returns true when it was added.
    pub fn addCity(self: *Session, id: []const u8) bool {
        if (id.len == 0 or self.containsWorking(id)) return false;
        if (!self.tz.zoneKnown(id)) return false;
        if (!self.appendClock(id)) return false;
        self.dirty = true;
        return true;
    }

    pub fn setH24(self: *Session, v: bool) void {
        if (self.h24 == v) return;
        self.h24 = v;
        self.dirty = true;
    }

    pub fn setSec(self: *Session, v: bool) void {
        if (self.sec == v) return;
        self.sec = v;
        self.dirty = true;
    }

    /// Clamp to the slider's grid: -720..720 in 30-minute steps.
    pub fn setShift(self: *Session, m: i32) void {
        const clamped = std.math.clamp(m, -shift_limit, shift_limit);
        const stepped = @divTrunc(clamped + @divTrunc(shift_step, 2) * @as(i32, if (clamped < 0) -1 else 1), shift_step) * shift_step;
        self.p.shift_min = std.math.clamp(stepped, -shift_limit, shift_limit);
        self.acc = 0;
    }

    pub fn resetShift(self: *Session) void {
        self.p.shift_min = 0;
    }

    // Time math

    /// Zone offset in seconds at `t`; `""` is the local zone.
    pub fn offsetSec(self: *Session, id: []const u8, t: i64) i32 {
        return self.tz.zoneOffset(id, t);
    }

    pub fn wallOf(self: *Session, id: []const u8, t: i64) tzdata.Civil {
        return tzdata.civilFromEpoch(t + self.offsetSec(id, t));
    }

    /// Zone offset minus local offset at `t`, in minutes.
    pub fn relOffsetMin(self: *Session, id: []const u8, t: i64) i32 {
        const rel = @as(i64, self.offsetSec(id, t)) - @as(i64, self.offsetSec("", t));
        return @intCast(@divTrunc(rel, 60));
    }

    /// Zone calendar date minus local calendar date at `t`, in days.
    pub fn dayDiff(self: *Session, id: []const u8, t: i64) i32 {
        const z = self.wallOf(id, t);
        const l = self.wallOf("", t);
        const zd = tzdata.daysFromCivil(z.y, z.mo, z.d);
        const ld = tzdata.daysFromCivil(l.y, l.mo, l.d);
        return @intCast(zd - ld);
    }

    /// `Local`, or `<day label>, <relative offset>` (`same time` at zero).
    pub fn subline(self: *Session, buf: []u8, id: []const u8, t: i64) []const u8 {
        if (id.len == 0) return "Local";
        const dd = self.dayDiff(id, t);
        const day = dayLabel(buf, dd);
        var w = day.len;
        if (w + 2 > buf.len) return buf[0..w];
        @memcpy(buf[w..][0..2], ", ");
        w += 2;
        const rel = self.relOffsetMin(id, t);
        var dbuf: [24]u8 = undefined;
        const rel_text = durText(&dbuf, rel);
        const room = @min(rel_text.len, buf.len - w);
        @memcpy(buf[w..][0..room], rel_text[0..room]);
        return buf[0..(w + room)];
    }

    // Rotation

    /// Advance the automatic-rotation bookkeeping at most once per whole
    /// second. Returns what changed for the host's repaint decisions.
    pub fn tick(self: *Session, now_ms: u64) TickResult {
        const now_sec = @divFloor(@as(i64, @intCast(now_ms)), 1000);
        if (now_sec == self.last_sec) return .{};
        const minute = self.last_sec < 0 or @divFloor(self.last_sec, 60) != @divFloor(now_sec, 60);
        self.last_sec = now_sec;
        var res = TickResult{ .second = true, .minute = minute };

        if (self.hover or self.open or self.pinned() or self.count() < 2) {
            self.acc = 0;
        } else {
            self.acc += 1;
            if (self.acc >= rotate_seconds) {
                self.acc = 0;
                res.face = self.go(1, false, now_ms);
            }
        }
        return res;
    }

    /// Step the face by `dir` (+1 next, -1 previous). Manual steps clear a
    /// pin first. Ignored while a slide runs (the busy flag) or when there
    /// is only the local clock. Returns true when something changed.
    pub fn go(self: *Session, dir: i32, manual: bool, now_ms: u64) bool {
        const n = self.count();
        if (n < 2 or self.slide.active or dir == 0) return false;
        if (manual) {
            self.acc = 0;
            if (self.pinned()) self.setPin(null);
        }
        const cur = self.current();
        const next: usize = @intCast(@mod(@as(i64, @intCast(cur)) + @as(i64, dir), @as(i64, @intCast(n))));
        if (self.reduce_motion) {
            self.idx = next;
            return true;
        }
        self.slide = .{
            .active = true,
            .phase = .out,
            .start_ms = now_ms,
            .dir = dir,
            .from = cur,
            .to = next,
        };
        return true;
    }

    /// Advance the slide animation; returns whether it is still running.
    pub fn tickAnim(self: *Session, now_ms: u64) bool {
        const sl = &self.slide;
        if (!sl.active) return false;
        const dur: u64 = if (sl.phase == .out) slide_out_ms else slide_in_ms;
        if (now_ms >= sl.start_ms +| dur) {
            if (sl.phase == .out) {
                self.idx = sl.to;
                sl.phase = .in;
                sl.start_ms = now_ms;
            } else {
                sl.active = false;
            }
        }
        return sl.active;
    }

    /// The text block's current offset/alpha while a slide runs.
    pub fn slideFx(self: *const Session, now_ms: u64) SlideFx {
        const sl = &self.slide;
        if (!sl.active) return .{};
        const dur: u64 = if (sl.phase == .out) slide_out_ms else slide_in_ms;
        const t = std.math.clamp(@as(f64, @floatFromInt(now_ms -| sl.start_ms)) /
            @as(f64, @floatFromInt(dur)), 0.0, 1.0);
        const dirf: f64 = @floatFromInt(sl.dir);
        if (sl.phase == .out) {
            const e = bezierEase(0.42, 0.0, 1.0, 1.0, t); // ease-in
            return .{ .dy = -0.40 * dirf * e, .alpha = 1.0 - e };
        }
        const e = bezierEase(0.2, 0.7, 0.2, 1.0, t);
        return .{ .dy = 0.40 * dirf * (1.0 - e), .alpha = e };
    }

    // Open/close

    /// Opening: refresh immediately, stop the rotation count.
    pub fn openPopup(self: *Session, now_ms: u64) void {
        self.open = true;
        self.acc = 0;
        self.p.open_ms = now_ms;
        self.p.shift_min = 0;
        self.p.scroll_list = 0;
        self.p.hover = .none;
        self.p.hover_row = -1;
        self.p.prev_hover_row = -1;
        self.p.dragging_slider = false;
        self.p.focus = .none;
        self.p.focus_visible = false;
    }

    /// Closing clears the shift and the transient interaction state.
    pub fn closePopup(self: *Session) void {
        self.open = false;
        self.acc = 0;
        self.p.shift_min = 0;
        self.p.dragging_slider = false;
        self.p.hover = .none;
        self.p.hover_row = -1;
        self.p.prev_hover_row = -1;
    }

    /// The instant the popup shows: now plus the shift.
    pub fn popupInstant(self: *const Session, now_sec: i64) i64 {
        return now_sec + @as(i64, self.p.shift_min) * 60;
    }
};

// Tests

const testing = std.testing;

test "world-clock session: slide fx endpoints" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();

    // Idle: no offset, full opacity.
    const idle = s.slideFx(1000);
    try testing.expectEqual(@as(f64, 0.0), idle.dy);
    try testing.expectEqual(@as(f64, 1.0), idle.alpha);

    // Next: out ends at -40% and clear.
    s.slide = .{ .active = true, .phase = .out, .start_ms = 0, .dir = 1, .to = 1 };
    const out_end = s.slideFx(slide_out_ms);
    try testing.expectApproxEqAbs(@as(f64, -0.40), out_end.dy, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out_end.alpha, 1e-6);

    // In: starts at +40% and clear, rests at zero and opaque.
    s.slide = .{ .active = true, .phase = .in, .start_ms = 0, .dir = 1, .from = 1, .to = 1 };
    const in_start = s.slideFx(0);
    try testing.expectApproxEqAbs(@as(f64, 0.40), in_start.dy, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), in_start.alpha, 1e-6);
    const in_end = s.slideFx(slide_in_ms);
    try testing.expectApproxEqAbs(@as(f64, 0.0), in_end.dy, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.0), in_end.alpha, 1e-6);

    // Previous mirrors: out ends up, in comes from above.
    s.slide = .{ .active = true, .phase = .out, .start_ms = 0, .dir = -1, .to = 0 };
    try testing.expectApproxEqAbs(@as(f64, 0.40), s.slideFx(slide_out_ms).dy, 1e-6);
    s.slide = .{ .active = true, .phase = .in, .start_ms = 0, .dir = -1 };
    try testing.expectApproxEqAbs(@as(f64, -0.40), s.slideFx(0).dy, 1e-6);
}

test "world-clock session: rotation counts to five and pauses" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();
    _ = s.addCity("Asia/Tokyo");
    if (s.count() < 2) return; // needs the system tz database
    s.reduce_motion = false;

    // Hover pauses and resets acc.
    s.hover = true;
    _ = s.tick(1000);
    try testing.expectEqual(@as(u32, 0), s.acc);
    s.hover = false;

    // Four seconds of counting leaves the face alone; the fifth advances.
    _ = s.tick(2000);
    _ = s.tick(3000);
    _ = s.tick(4000);
    _ = s.tick(5000);
    try testing.expectEqual(@as(u32, 4), s.acc);
    try testing.expectEqual(@as(usize, 0), s.current());

    const r = s.tick(6000);
    try testing.expect(r.face);
    try testing.expectEqual(@as(u32, 0), s.acc);
    try testing.expect(s.slide.active);
    try testing.expectEqual(@as(usize, 1), s.slide.to);

    // Open pauses too, and a running slide stays busy.
    s.open = true;
    _ = s.tick(7000);
    try testing.expectEqual(@as(u32, 0), s.acc);
    try testing.expect(!s.go(1, false, 7000));
}

test "world-clock session: manual step clears pin and wraps" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();
    _ = s.addCity("Asia/Tokyo");
    if (s.count() < 2) return;
    s.reduce_motion = true;

    s.setPin("Asia/Tokyo");
    try testing.expect(s.pinned());
    try testing.expectEqual(@as(usize, 1), s.current());

    // Manual next clears the pin and wraps to the local row.
    try testing.expect(s.go(1, true, 0));
    try testing.expect(!s.pinned());
    try testing.expectEqual(@as(usize, 0), s.idx);

    // Previous wraps to the last stored clock.
    try testing.expect(s.go(-1, true, 0));
    try testing.expectEqual(@as(usize, 1), s.current());

    // A single clock cannot step, auto or manual.
    s.removeAt(1);
    try testing.expect(!s.go(1, false, 0));
    try testing.expect(!s.go(-1, true, 0));
}

test "world-clock session: tick anim swaps at phase end" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();
    s.slide = .{ .active = true, .phase = .out, .start_ms = 100, .dir = 1, .from = 0, .to = 1 };
    try testing.expect(s.tickAnim(100 + slide_out_ms - 1));
    try testing.expectEqual(@as(usize, 0), s.idx);
    try testing.expect(s.tickAnim(100 + slide_out_ms));
    try testing.expectEqual(@as(usize, 1), s.idx);
    try testing.expect(s.slide.active);
    try testing.expectEqual(SlidePhase.in, s.slide.phase);
    try testing.expect(!s.tickAnim(100 + slide_out_ms + slide_in_ms));
    try testing.expect(!s.slide.active);
}

test "world-clock session: time vector and duration text" {
    const c = tzdata.Civil{ .y = 2026, .mo = 10, .d = 18, .h = 21, .mi = 42, .s = 7, .wday = 0 };
    const v24 = timeVec(c, true, true);
    try testing.expectEqualStrings("21:42", v24.hm());
    try testing.expectEqualStrings(":07", v24.ss());
    try testing.expectEqualStrings("", v24.ap());

    const v12 = timeVec(c, false, false);
    try testing.expectEqualStrings("9:42", v12.hm());
    try testing.expectEqualStrings("PM", v12.ap());
    try testing.expectEqualStrings("", v12.ss());

    // Midnight is 12:xx AM; noon is 12:xx PM; 24-hour pads.
    const mid = tzdata.Civil{ .y = 2026, .mo = 1, .d = 2, .h = 0, .mi = 5, .s = 0, .wday = 5 };
    try testing.expectEqualStrings("00:05", timeVec(mid, true, false).hm());
    try testing.expectEqualStrings("12:05", timeVec(mid, false, false).hm());
    try testing.expectEqualStrings("AM", timeVec(mid, false, false).ap());
    const noon = tzdata.Civil{ .y = 2026, .mo = 1, .d = 2, .h = 12, .mi = 0, .s = 0, .wday = 5 };
    try testing.expectEqualStrings("12:00", timeVec(noon, false, false).hm());
    try testing.expectEqualStrings("PM", timeVec(noon, false, false).ap());

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("+8h", durText(&buf, 480));
    try testing.expectEqualStrings("\u{2212}5h", durText(&buf, -300));
    try testing.expectEqualStrings("+5h 30m", durText(&buf, 330));
    try testing.expectEqualStrings("\u{2212}2h 30m", durText(&buf, -150));
    try testing.expectEqualStrings("+45m", durText(&buf, 45));
    try testing.expectEqualStrings("same time", durText(&buf, 0));

    try testing.expectEqualStrings("Today", dayLabel(&buf, 0));
    try testing.expectEqualStrings("Tomorrow", dayLabel(&buf, 1));
    try testing.expectEqualStrings("Yesterday", dayLabel(&buf, -1));
    try testing.expectEqualStrings("+2 days", dayLabel(&buf, 2));
    try testing.expectEqualStrings("\u{2212}3 days", dayLabel(&buf, -3));
}

test "world-clock session: easing endpoints" {
    try testing.expectApproxEqAbs(@as(f64, 0.0), bezierEase(0.42, 0.0, 1.0, 1.0, 0.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), bezierEase(0.42, 0.0, 1.0, 1.0, 1.0), 1e-9);
    const mid = bezierEase(0.42, 0.0, 1.0, 1.0, 0.5);
    try testing.expect(mid > 0.0 and mid < 0.5); // ease-in is slow at the start
    try testing.expectApproxEqAbs(@as(f64, 1.0), bezierEase(0.2, 0.7, 0.2, 1.0, 1.0), 1e-9);
    const fast = bezierEase(0.2, 0.7, 0.2, 1.0, 0.25);
    try testing.expect(fast > 0.25); // front-loaded
}

test "world-clock session: names and presets" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();
    try testing.expectEqualStrings("Singapore", s.nameOf("Asia/Singapore"));
    try testing.expectEqualStrings("Buenos Aires", s.nameOf("America/Argentina/Buenos_Aires"));
    try testing.expectEqualStrings("Hong Kong", s.nameOf("Asia/Hong_Kong"));
    try testing.expectEqualStrings("Somewhere Else", s.nameOf("Etc/Somewhere_Else"));
    try testing.expectEqual(@as(usize, 34), presets.len);
}

test "world-clock session: popup has no add pane" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();
    // The add pane is gone: opening settles on no focus with the list at
    // the top and no shift.
    s.openPopup(1000);
    try testing.expect(s.p.focus == .none);
    try testing.expectEqual(@as(f64, 0.0), s.p.scroll_list);
    try testing.expectEqual(@as(i32, 0), s.p.shift_min);
    s.closePopup();
    try testing.expect(s.p.focus == .none);

    // The preset table still backs the settings app's Time tab: names
    // resolve and `addCity` appends, refusing dupes and unknown zones.
    try testing.expectEqualStrings("Tokyo", presetName("Asia/Tokyo").?);
    _ = s.addCity("Asia/Tokyo");
    if (s.count() < 2) return; // local zone is Tokyo: nothing was added
    try testing.expect(s.containsStored("Asia/Tokyo"));
    try testing.expect(s.dirty);
    try testing.expect(!s.addCity("Asia/Tokyo"));
    try testing.expect(!s.addCity("Not/AZone"));
}

test "world-clock session: shift clamps to the grid" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();
    s.setShift(0);
    try testing.expectEqual(@as(i32, 0), s.p.shift_min);
    s.setShift(45);
    try testing.expectEqual(@as(i32, 60), s.p.shift_min);
    s.setShift(-10);
    try testing.expectEqual(@as(i32, 0), s.p.shift_min);
    s.setShift(10000);
    try testing.expectEqual(@as(i32, 720), s.p.shift_min);
    s.setShift(-10000);
    try testing.expectEqual(@as(i32, -720), s.p.shift_min);
    s.resetShift();
    try testing.expectEqual(@as(i32, 0), s.p.shift_min);
}

test "world-clock session: tick aligns to whole seconds" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Session.init(testing.allocator, threaded.io());
    defer s.deinit();
    const a = s.tick(1_500);
    try testing.expect(a.second);
    try testing.expect(a.minute); // first tick of a fresh session
    const b = s.tick(1_900);
    try testing.expect(!b.second);
    const c = s.tick(2_000);
    try testing.expect(c.second);
    try testing.expect(!c.minute); // 1.5s to 2.0s stays in the same minute
    const d = s.tick(61_000);
    try testing.expect(d.minute); // 2s to 61s crosses a minute boundary
}

test "world-clock session: settings JSON round-trip" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/wc.json", .{tmp.sub_path});

    var s = Session.init(testing.allocator, io);
    defer s.deinit();
    s.path_override = path;
    _ = s.addCity("Asia/Tokyo");
    s.setH24(false);
    s.setSec(true);
    s.setPin("Asia/Tokyo");
    s.save();

    var s2 = Session.init(testing.allocator, io);
    defer s2.deinit();
    s2.path_override = path;
    s2.load();
    try testing.expect(!s2.h24);
    try testing.expect(s2.sec);
    try testing.expect(s2.pinned());
    try testing.expectEqualStrings("Asia/Tokyo", s2.pin_id.?);
    try testing.expect(s2.containsStored("Asia/Tokyo"));
    try testing.expectEqualStrings("Asia/Tokyo", s2.currentId());
}

test "world-clock session: load drops unknown zones, dupes and stray pins" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/wc2.json", .{tmp.sub_path});

    const doc =
        \\{"tz":["Not/AZone","Asia/Tokyo","Asia/Tokyo","Asia/Singapore"],"h24":true,"sec":false,"pin":"Europe/Paris"}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = doc });

    var s = Session.init(testing.allocator, io);
    defer s.deinit();
    s.path_override = path;
    s.load();
    // Unknown and duplicate entries drop; the stray pin clears.
    try testing.expect(s.containsStored("Asia/Tokyo"));
    try testing.expect(s.containsStored("Asia/Singapore"));
    try testing.expect(!s.containsStored("Not/AZone"));
    try testing.expectEqual(@as(usize, 3), s.count());
    try testing.expect(!s.pinned());
}

test "world-clock session: reload adopts the file, ignores its own state" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/wc5.json", .{tmp.sub_path});

    var s = Session.init(testing.allocator, io);
    defer s.deinit();
    s.path_override = path;

    // Nothing on disk yet: nothing to adopt, and the session keeps its state.
    try testing.expect(!s.reload());

    // Settings > Time writes the store: the session adopts it whole.
    const doc =
        \\{"tz":["Asia/Tokyo","Asia/Singapore"],"h24":false,"sec":true,"pin":"Asia/Singapore"}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = doc });
    try testing.expect(s.reload());
    try testing.expect(s.containsStored("Asia/Tokyo"));
    try testing.expect(!s.h24);
    try testing.expect(s.sec);
    try testing.expectEqualStrings("Asia/Singapore", s.pin_id.?);

    // A second pass over the same file is a no-op: the session's own saves
    // come back through the watcher the same way, and must not reset it.
    try testing.expect(!s.reload());

    // Same list, new order, is a real change.
    const doc2 =
        \\{"tz":["Asia/Singapore","Asia/Tokyo"],"h24":false,"sec":true,"pin":"Asia/Singapore"}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = doc2 });
    try testing.expect(s.reload());
    try testing.expectEqualStrings("Asia/Singapore", s.clocks.items[0].id);

    // Half-written JSON is left alone: the writer owns the file.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{ oops" });
    try testing.expect(!s.reload());
    try testing.expect(s.containsStored("Asia/Tokyo"));
}

test "world-clock session: malformed settings fall back to defaults" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/wc3.json", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{ not json" });

    var s = Session.init(testing.allocator, io);
    defer s.deinit();
    s.path_override = path;
    s.load();
    try testing.expect(s.h24);
    try testing.expect(!s.sec);
    // The defaults install at least one clock when the tz database is
    // readable; without it the local row alone remains.
    try testing.expect(s.count() >= 1);
}
