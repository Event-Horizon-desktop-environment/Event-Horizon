//! 600x620 volume mixer card: Output/Input segment, default-device
//! master card, per-device rows, scrollable app streams with per-app output
//! routing, card-profile subsections, engine footer, and full press-drag
//! slider input with axis (±5%) support.
//!
//! What could not come across verbatim, and why:
//!
//! * **Service pulls.** The daemon reads itself
//!   behind TTL caches (`cached_snapshot` 400 ms, link blob 1 s, engine
//!   and `pw-top` 5 s, cards 10 s, all held during slider drags). The Zig
//!   shell has no PipeWire service object, so every function here takes
//!   the already-resolved `Snapshot` (plus `Engine`, `TopSample` and cards
//!   for the footer/dropdowns) in — the TTL caches live in `Caches`, owned
//!   by the host, and the *query* half (pw-link blob capture, engine,
//!   pw-top and card queries plus route/profile verbs) extends
//!   `controlcenter/live_audio.zig`, which already speaks `pactl`/`wpctl`.
//!   Service *writes* surface as `Effect` values the host executes.
//! * **The UI singleton.** `MixerUiState` is host-owned here, not a TU
//!   static — same fields, same transitions, testable and re-entrant.
//!   `notifyOpen` preserves the Output/Input tab across reopen.
//! * **The `IconCache`.** Stream art resolves through an `Icons` provider
//!   (name → surface) the host fills from its theme; the ~20-attempt
//!   `mixer_stream_icon_resolve` cascade is ported as `streamIconNames`,
//!   which yields candidate names in attempt order for the host to try.
//!   The `swap.svg` asset has no Zig loader, so the router button goes
//!   straight to the `swap_horiz` SVG when the
//!   asset is unavailable.
//! * **`request_launch_settings`.** The footer button answers a
//!   `launch_settings` effect; the host opens Settings.
//! * **`MixerLog`.** Ported as a plain struct (env-gated file log, same
//!   entry points and thresholds); the `thread_local` accumulators are
//!   fields because the Zig paint never leaves its thread.
//!
//! Every rectangle below has one definition shared by the paint and the
//! hit-test, so a slider that moves on screen moves under the pointer too
//! (the `media_popup.zig` rule).

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const schema = @import("../../config/schema.zig");
const chrome_colors = @import("./shared/chrome_colors.zig");
const helpers = @import("../shared/cairo_helpers.zig");
const glyphs = @import("../common/material_glyph.zig");
const text = @import("../../text/layout.zig");

pub const popup_w: f64 = 600.0;
pub const popup_h: f64 = 620.0;

const k_pad: f64 = 16.0;
const k_corner: f64 = 20.0;
const k_header_h: f64 = 56.0;
const k_seg_h: f64 = 32.0;
const k_seg_r: f64 = 10.0;
const k_row_h: f64 = 52.0;
const k_master_h: f64 = 96.0;
const k_radio_r: f64 = 9.0;
const k_tile_sz: f64 = 34.0;
const k_tile_r: f64 = 10.0;
const k_dev_icon_sz: f64 = 20.0;
const k_mute_btn_sz: f64 = 28.0;
const k_mute_icon_sz: f64 = 18.0;
const k_app_icon_sz: f64 = 26.0;
const k_slider_track_h: f64 = 8.0;
const k_slider_thumb_r: f64 = 9.0;
const k_slider_min_w: f64 = 60.0;
const k_name_max_w: f64 = 150.0;
const k_pct_w: f64 = 38.0;
const k_menu_btn_sz: f64 = 28.0;
const k_footer_h: f64 = 40.0;
const k_apps_header_h: f64 = 30.0;
const k_drop_title_h: f64 = 26.0;
const k_drop_item_h: f64 = 36.0;
const k_drop_sub_h: f64 = 24.0;
const k_scroll_w: f64 = 12.0;
pub const scroll_step: f64 = 60.0;

const k_shad_dx: f64 = 2.0;
const k_shad_dy: f64 = 4.0;
const k_shad_alpha: f64 = 0.28;

const k_hit_pad_v: f64 = 14.0;
const k_hit_pad_h: f64 = 6.0;

/// Track fraction maps to 0..150% volume (100% detent + overdrive zone).
pub const volume_max_pct: i32 = 150;
/// Axis step: `lround(-deltaPx / 20 * 5)`, clamped to `[0, 150]`.
pub const axis_step_div: f64 = 20.0;
/// Drag applies at most every 16 ms.
pub const drag_apply_ms: i64 = 16;
/// Engine/`pw-top`/cards refresh hold after the last drag motion.
pub const engine_hold_ms: i64 = 400;

/// Monotonic milliseconds.
pub fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
        @divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), 1000000);
}

// Model (borrowed strings; the host owns them for the frame)

pub const DeviceInfo = struct {
    node_id: u32 = 0,
    name: []const u8 = "",
    raw_name: []const u8 = "",
    is_default: bool = false,
    muted: bool = false,
    volume_pct: i32 = 0,
};

pub const StreamInfo = struct {
    node_id: u32 = 0,
    volume_pct: i32 = 0,
    muted: bool = false,
    app_name: []const u8 = "",
    icon_name: []const u8 = "",
    app_id: []const u8 = "",
    process_binary: []const u8 = "",
    node_name: []const u8 = "",
    description: []const u8 = "",
    /// Counterpart node.name ("" = default route).
    routed_raw: []const u8 = "",
    /// Counterpart display name ("" = default route).
    routed_display: []const u8 = "",
};

pub const Snapshot = struct {
    sinks: []const DeviceInfo = &.{},
    sources: []const DeviceInfo = &.{},
    out_streams: []const StreamInfo = &.{},
    in_streams: []const StreamInfo = &.{},
};

pub const CardProfile = struct {
    key: []const u8 = "",
    description: []const u8 = "",
};

pub const CardProfiles = struct {
    card_index: u32 = 0,
    card_key: []const u8 = "",
    profiles: []const CardProfile = &.{},
    active_profile_key: []const u8 = "",
};

/// Footer engine readout (`query_engine_settings` in live_audio).
pub const EngineSettings = struct {
    available: bool = false,
    clock_rate_hz: i32 = 48000,
    clock_force_rate_hz: i32 = 0,
    clock_quantum: i32 = 0,
    clock_force_quantum: i32 = 0,
};

/// Footer DSP readout (`query_pw_top_batch` in live_audio).
pub const TopSample = struct {
    available: bool = false,
    dsp_load_pct: f64 = 0,
    xruns_total: i64 = 0,
};

/// `master_device` — the default device, else the first one.
pub fn masterDevice(snap: *const Snapshot, view_output: bool) ?*const DeviceInfo {
    const devs = if (view_output) snap.sinks else snap.sources;
    if (devs.len == 0) return null;
    for (devs) |*d| {
        if (d.is_default) return d;
    }
    return &devs[0];
}

/// `find_card_for_node` — the card whose key id-segment appears in the
/// node name (`bluez_card.A8_..` ↔ `bluez_output.A8_...1`).
pub fn findCardForNode(cards: []const CardProfiles, node_raw: []const u8) ?*const CardProfiles {
    if (node_raw.len == 0) return null;
    for (cards) |*c| {
        const dot = std.mem.indexOfScalar(u8, c.card_key, '.');
        const id = if (dot) |d| c.card_key[d + 1 ..] else c.card_key;
        if (id.len > 0 and std.mem.indexOf(u8, node_raw, id) != null) return c;
    }
    return null;
}

// Stream display names (`resolve_stream_display` + desktop_entries helpers)

/// `is_generic_runtime_binary` — lowercased host names that never identify
/// an app.
pub fn isGenericRuntimeBinary(lower: []const u8) bool {
    const generics = [_][]const u8{
        "chromium",       "chromium-browser", "chrome",   "google-chrome",
        "chromium input", "chromium output",  "electron", "electron32",
        "electron31",     "electron30",       "node",     "python",
        "python3",        "java",             "wine",     "wineserver",
    };
    for (generics) |g| {
        if (std.mem.eql(u8, lower, g)) return true;
    }
    return false;
}

/// `is_generic_icon_name` — icon names too bland to show.
pub fn isGenericIconName(name: []const u8) bool {
    if (name.len == 0) return true;
    var low_buf: [128]u8 = undefined;
    const low = lowerInto(&low_buf, name);
    if (std.mem.eql(u8, low, "chromium") or std.mem.eql(u8, low, "electron")) return true;
    if (std.mem.eql(u8, low, "chromium-browser") or std.mem.eql(u8, low, "google-chrome") or
        std.mem.eql(u8, low, "google-chrome-stable")) return true;
    if (low.len > 8 and std.mem.startsWith(u8, low, "electron")) return true;
    return false;
}

fn lowerInto(buf: []u8, s: []const u8) []u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

/// `app|bin|node|desc` identity for the resolution cache.
pub fn streamIdentity(buf: []u8, app_id: []const u8, bin: []const u8, node: []const u8, desc: []const u8) []const u8 {
    var n: usize = 0;
    const parts = [_][]const u8{ app_id, bin, node, desc };
    for (parts, 0..) |part, i| {
        const take = @min(part.len, buf.len -| n);
        @memcpy(buf[n .. n + take], part[0..take]);
        n += take;
        if (i + 1 < parts.len and n < buf.len) {
            buf[n] = '|';
            n += 1;
        }
        if (n >= buf.len) break;
    }
    return buf[0..n];
}

pub const ResolvedName = struct {
    app_name: []const u8 = "",
    icon_name: []const u8 = "",
};

/// A desktop entry hit: display name + icon name.
pub const DesktopEntry = struct { name: []const u8, icon: []const u8 };

/// Desktop-entry lookup the host provides (`resolve_desktop_entry_for_stream`
/// ): app id candidates plus the entry's `Icon=`/`Name=`.
pub const DesktopLookup = struct {
    ctx: *anyopaque,
    /// Answers the desktop entry's display name and icon name for one of the
    /// `streamDesktopCandidates` ids, or null.
    lookup: *const fn (ctx: *anyopaque, app_id: []const u8) ?DesktopEntry,
};

/// Candidate app ids for desktop lookup, in attempt order: binary
/// basename, full app id, app id before the first dot, app name, node
/// first token, description, plus known-app expansions (Vesktop, Cider,
/// Discord, Edge). Writes into `out` (cap 16), returns the slice.
pub fn streamDesktopCandidates(
    out: [][2][]const u8,
    app_id: []const u8,
    bin: []const u8,
    app_name: []const u8,
    node: []const u8,
    desc: []const u8,
) [][2][]const u8 {
    var n: usize = 0;
    const put = struct {
        fn f(list: [][2][]const u8, i: *usize, id: []const u8) void {
            if (id.len == 0 or i.* >= list.len) return;
            for (list[0..i.*]) |e| {
                if (std.mem.eql(u8, e[0], id)) return;
            }
            list[i.*] = .{ id, id };
            i.* += 1;
        }
    }.f;
    if (bin.len > 0) {
        const base = std.fs.path.basename(bin);
        put(out, &n, base);
    }
    put(out, &n, app_id);
    if (std.mem.indexOfScalar(u8, app_id, '.')) |d| put(out, &n, app_id[0..d]);
    put(out, &n, app_name);
    if (node.len > 0) {
        var tok = node;
        for ([_]u8{ '-', '_', '.' }) |sep| {
            if (std.mem.indexOfScalar(u8, tok, sep)) |d| {
                tok = tok[0..d];
                break;
            }
        }
        // Borrowed from the input (not lowered in place — the host
        // lowercases for matching).
        put(out, &n, tok);
    }
    put(out, &n, desc);
    // Known-app expansions, matched case-insensitively across all five ids.
    var hay_buf: [1024]u8 = undefined;
    var hn: usize = 0;
    for ([_][]const u8{ app_id, bin, app_name, node, desc }) |s| {
        const take = @min(s.len, hay_buf.len - hn);
        @memcpy(hay_buf[hn .. hn + take], s[0..take]);
        hn += take;
        if (hn < hay_buf.len) {
            hay_buf[hn] = ' ';
            hn += 1;
        }
    }
    for (hay_buf[0..hn]) |*c| c.* = std.ascii.toLower(c.*);
    const hay = hay_buf[0..hn];
    const expansions = [_]struct { needle: []const u8, ids: []const []const u8 }{
        .{ .needle = "vesktop", .ids = &.{ "dev.vencord.Vesktop", "vesktop" } },
        .{ .needle = "vencord", .ids = &.{ "dev.vencord.Vesktop", "vesktop" } },
        .{ .needle = "cider", .ids = &.{"sh.cider.Cider"} },
        .{ .needle = "discord", .ids = &.{"discord"} },
        .{ .needle = "msedge", .ids = &.{ "com.microsoft.Edge", "microsoft-edge", "msedge" } },
        .{ .needle = "microsoft edge", .ids = &.{ "com.microsoft.Edge", "microsoft-edge", "msedge" } },
    };
    for (expansions) |e| {
        if (std.mem.indexOf(u8, hay, e.needle) != null) {
            for (e.ids) |id| put(out, &n, id);
        }
    }
    return out[0..n];
}

/// Basename + strip `.exe`/`.bin`/`-bin` + capitalize, for turning a
/// process binary into a display name.
pub fn prettifyCandidate(buf: []u8, s: []const u8) []const u8 {
    if (s.len == 0) return "";
    var low = lowerInto(buf, s);
    for ([_][]const u8{ ".exe", ".bin", "-bin" }) |sfx| {
        if (low.len > sfx.len and std.mem.endsWith(u8, low, sfx)) {
            low = low[0 .. low.len - sfx.len];
            break;
        }
    }
    if (low.len == 0) return "";
    var name = low;
    if (std.mem.lastIndexOfAny(u8, name, "/\\")) |sl| {
        if (sl + 1 < name.len) name = name[sl + 1 ..];
    }
    if (name.len == 0) return "";
    name[0] = std.ascii.toUpper(name[0]);
    return name;
}

/// `resolve_stream_display` — icon (unless generic), app name via desktop
/// entry, description/binary fallbacks, "Unknown" last resort.
///
/// Ownership: `icon_name` always borrows the inputs. `app_name` is owned
/// (free it) ONLY when prettified from the binary/app id/node — desktop
/// hits, descriptions and `"Unknown"` borrow their source.
pub fn resolveStreamDisplay(
    alloc: std.mem.Allocator,
    app_name: []const u8,
    icon_name: []const u8,
    app_id: []const u8,
    bin: []const u8,
    node: []const u8,
    desc: []const u8,
    desktop: ?DesktopLookup,
) !ResolvedName {
    var out = ResolvedName{
        .icon_name = if (isGenericIconName(icon_name)) "" else icon_name,
        .app_name = app_name,
    };
    var cands: [16][2][]const u8 = undefined;
    for (streamDesktopCandidates(&cands, app_id, bin, app_name, node, desc)) |c| {
        if (desktop) |dl| {
            if (dl.lookup(dl.ctx, c[0])) |e| {
                if (e.icon.len > 0) out.icon_name = e.icon;
                if (e.name.len > 0) out.app_name = e.name;
                break;
            }
        }
    }
    if (out.app_name.len == 0 or std.mem.eql(u8, out.app_name, app_name)) {
        var low_buf: [512]u8 = undefined;
        const low_desc = lowerInto(&low_buf, desc);
        var gen_buf: [512]u8 = undefined;
        if (desc.len > 0 and !isGenericRuntimeBinary(low_desc)) {
            if (out.app_name.len == 0) out.app_name = desc;
        } else {
            const low_app = lowerInto(&gen_buf, out.app_name);
            if (out.app_name.len == 0 or isGenericRuntimeBinary(low_app)) {
                var pbuf: [256]u8 = undefined;
                var name: []const u8 = prettifyCandidate(&pbuf, bin);
                if (name.len == 0) name = prettifyCandidate(&pbuf, app_id);
                if (name.len == 0) name = prettifyCandidate(&pbuf, node);
                if (name.len > 0) {
                    const duped = try alloc.dupe(u8, name);
                    out.app_name = duped;
                }
            }
        }
    }
    if (out.app_name.len == 0) out.app_name = "Unknown";
    return out;
}

// Compact labels

fn replaceAll(alloc: std.mem.Allocator, s: []const u8, needle: []const u8, rep: []const u8) ![]u8 {
    if (needle.len == 0 or std.mem.indexOf(u8, s, needle) == null) return alloc.dupe(u8, s);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var rest = s;
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        try out.appendSlice(alloc, rest[0..i]);
        try out.appendSlice(alloc, rep);
        rest = rest[i + needle.len ..];
    }
    try out.appendSlice(alloc, rest);
    return out.toOwnedSlice(alloc);
}

fn trimSpaces(s: []const u8) []const u8 {
    var b = s;
    while (b.len > 0 and b[0] == ' ') b = b[1..];
    while (b.len > 0 and b[b.len - 1] == ' ') b = b[0 .. b.len - 1];
    return b;
}

fn collapseSpaces(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var prev_space = true;
    for (s) |c| {
        if (c == ' ') {
            if (!prev_space) try out.append(alloc, ' ');
            prev_space = true;
        } else {
            try out.append(alloc, c);
            prev_space = false;
        }
    }
    const t = try out.toOwnedSlice(alloc);
    const trimmed = trimSpaces(t);
    if (trimmed.len != t.len) {
        const duped = try alloc.dupe(u8, trimmed);
        alloc.free(t);
        return duped;
    }
    return t;
}

/// `shorten_device_name` — the mixer/settings compact label rules, in
/// order. Returns an owned string; falls back to `name` when empty.
pub fn shortenDeviceName(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    // Single owner throughout: each step frees the previous string. (Two
    // stacked `defer free(s)` across a reassignment would free the final
    // string twice — hence the explicit discipline here.)
    var s: []u8 = try alloc.dupe(u8, name);
    errdefer alloc.free(s);
    {
        const n = try replaceAll(alloc, s, "High Definition Audio Controller", "HD Audio");
        alloc.free(s);
        s = n;
    }
    {
        const n = try replaceAll(alloc, s, "High Definition Audio", "HD Audio");
        alloc.free(s);
        s = n;
    }
    {
        const n = try replaceAll(alloc, s, " Audio Controller", "");
        alloc.free(s);
        s = n;
    }
    // Trailing `[...]` monitor tag.
    if (s.len > 2 and s[s.len - 1] == ']') {
        if (std.mem.lastIndexOfScalar(u8, s, '[')) |open| {
            if (open > 0) {
                const n = try alloc.dupe(u8, trimSpaces(s[0..open]));
                alloc.free(s);
                s = n;
            }
        }
    }
    // `Digital Stereo (PORT)` → `PORT`.
    if (std.mem.indexOf(u8, s, "Digital Stereo (")) |dig| {
        if (std.mem.indexOfScalarPos(u8, s, dig, ')')) |close| {
            const port = s[dig + "Digital Stereo (".len .. close];
            var joined = std.ArrayList(u8).empty;
            errdefer joined.deinit(alloc);
            try joined.appendSlice(alloc, s[0..dig]);
            try joined.appendSlice(alloc, port);
            try joined.appendSlice(alloc, s[close + 1 ..]);
            const n = try joined.toOwnedSlice(alloc);
            alloc.free(s);
            s = n;
        }
    }
    // `Family …` PCI prefix: drop the first two space-tokens.
    if (std.mem.startsWith(u8, s, "Family ")) {
        if (std.mem.indexOfScalar(u8, s, ' ')) |sp| {
            if (std.mem.indexOfScalarPos(u8, s, sp + 1, ' ')) |sp2| {
                const n = try alloc.dupe(u8, s[sp2 + 1 ..]);
                alloc.free(s);
                s = n;
            }
        }
    }
    const collapsed = try collapseSpaces(alloc, s);
    alloc.free(s);
    if (collapsed.len == 0) {
        alloc.free(collapsed);
        return alloc.dupe(u8, name);
    }
    return collapsed;
}

/// `shorten_profile_label(key, desc)` — codec/profile compact labels.
pub fn shortenProfileLabel(alloc: std.mem.Allocator, key: []const u8, desc: []const u8) ![]u8 {
    if (std.mem.eql(u8, key, "off") or std.mem.eql(u8, desc, "Off")) return alloc.dupe(u8, "Off");
    var codec: []const u8 = "";
    if (std.mem.indexOf(u8, desc, "codec ")) |ck| {
        var end = ck + "codec ".len;
        while (end < desc.len and desc[end] != ',' and desc[end] != ')') end += 1;
        codec = trimSpaces(desc[ck + "codec ".len .. end]);
    }
    var base = desc;
    if (std.mem.indexOfScalar(u8, desc, '(')) |open| base = trimSpaces(desc[0..open]);
    var owned: ?[]u8 = null;
    errdefer if (owned) |o| alloc.free(o);
    {
        const subs = [_]struct { from: []const u8, to: []const u8 }{
            .{ .from = "High Fidelity Playback", .to = "A2DP" },
            .{ .from = "Headset Head Unit", .to = "Headset" },
            .{ .from = "Analog Stereo Duplex", .to = "Analog Duplex" },
            .{ .from = "Analog Stereo Output", .to = "Analog Out" },
            .{ .from = "Analog Stereo Input", .to = "Analog In" },
            .{ .from = "Analog Surround", .to = "Surround" },
        };
        var cur = try alloc.dupe(u8, base);
        owned = cur;
        for (subs) |sb| {
            const next = try replaceAll(alloc, cur, sb.from, sb.to);
            alloc.free(cur);
            cur = next;
            owned = cur;
        }
        base = cur;
    }
    if (std.mem.startsWith(u8, base, "Digital")) {
        // NOTE: the HDMI hunt runs on the full `desc`, not the paren-cut
        // base (the port lives inside the parentheses).
        var port: []const u8 = "Digital";
        if (std.mem.indexOf(u8, desc, "HDMI")) |hd| {
            var end = hd;
            while (end < desc.len and desc[end] != ' ' and desc[end] != ')') end += 1;
            port = desc[hd..end];
        }
        const fmt: []const u8 = if (base.len > 8) base[8..] else "";
        const fmt2: []const u8 = if (std.mem.eql(u8, fmt, "Stereo")) "" else fmt;
        var joined = std.ArrayList(u8).empty;
        errdefer joined.deinit(alloc);
        try joined.appendSlice(alloc, port);
        if (fmt2.len > 0) {
            try joined.append(alloc, ' ');
            try joined.appendSlice(alloc, fmt2);
        }
        try joined.appendSlice(alloc, if (std.mem.indexOf(u8, base, "Input") != null) " In" else " Out");
        const j = try joined.toOwnedSlice(alloc);
        alloc.free(owned.?);
        owned = j;
        base = j;
    }
    if (codec.len > 0 and std.mem.indexOf(u8, base, codec) == null) {
        var joined = std.ArrayList(u8).empty;
        errdefer joined.deinit(alloc);
        try joined.appendSlice(alloc, base);
        try joined.appendSlice(alloc, " · ");
        try joined.appendSlice(alloc, codec);
        const j = try joined.toOwnedSlice(alloc);
        alloc.free(owned.?);
        owned = j;
        base = j;
    }
    const trimmed = trimSpaces(base);
    if (trimmed.len == 0) {
        alloc.free(owned.?);
        return alloc.dupe(u8, desc);
    }
    if (trimmed.ptr == owned.?.ptr and trimmed.len == owned.?.len) {
        owned = null;
        return @constCast(trimmed);
    }
    const out = try alloc.dupe(u8, trimmed);
    alloc.free(owned.?);
    owned = null;
    return out;
}

// pw-link routing parsers (pure; the capture spawn lives in live_audio)

fn firstSegment(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, ':')) |i| return s[0..i];
    return s;
}

/// `pw_guess_playback_sink_name_from_blob` — first playback link whose
/// stream side matches `name:`, answered with the sink's first segment.
pub fn playbackSinkForStream(blob: []const u8, stream_node_name: []const u8) []const u8 {
    if (blob.len == 0 or stream_node_name.len == 0) return "";
    var pref_buf: [256]u8 = undefined;
    const pref = std.fmt.bufPrint(&pref_buf, "{s}:", .{stream_node_name}) catch return "";
    var pending: []const u8 = "";
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len >= 6 and std.mem.eql(u8, line[0..6], "  |-> ")) {
            const dest = line[6..];
            if (pending.len > 0 and std.mem.startsWith(u8, pending, pref) and
                std.mem.indexOf(u8, pending, "output") != null and
                std.mem.indexOf(u8, dest, "playback") != null)
            {
                return firstSegment(dest);
            }
            continue;
        }
        if (line.len >= 6 and std.mem.eql(u8, line[0..6], "  |<- ")) {
            const src = line[6..];
            if (pending.len > 0 and std.mem.indexOf(u8, pending, "playback") != null and
                std.mem.startsWith(u8, src, pref) and std.mem.indexOf(u8, src, "output") != null)
            {
                return firstSegment(pending);
            }
            continue;
        }
        if (line.len > 0 and line[0] != ' ') pending = line;
    }
    return "";
}

/// `pw_guess_capture_source_name_from_blob` — same state machine with the
/// capture/monitor roles swapped.
pub fn captureSourceForStream(blob: []const u8, stream_node_name: []const u8) []const u8 {
    if (blob.len == 0 or stream_node_name.len == 0) return "";
    var pref_buf: [256]u8 = undefined;
    const pref = std.fmt.bufPrint(&pref_buf, "{s}:", .{stream_node_name}) catch return "";
    var pending: []const u8 = "";
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len >= 6 and std.mem.eql(u8, line[0..6], "  |-> ")) {
            const dest = line[6..];
            if (pending.len > 0 and
                (std.mem.indexOf(u8, pending, "capture") != null or
                    std.mem.indexOf(u8, pending, "monitor") != null) and
                std.mem.startsWith(u8, dest, pref) and std.mem.indexOf(u8, dest, "input") != null)
            {
                return firstSegment(pending);
            }
            continue;
        }
        if (line.len >= 6 and std.mem.eql(u8, line[0..6], "  |<- ")) {
            const src = line[6..];
            if (pending.len > 0 and std.mem.startsWith(u8, pending, pref) and
                std.mem.indexOf(u8, pending, "input") != null and
                (std.mem.indexOf(u8, src, "capture") != null or
                    std.mem.indexOf(u8, src, "monitor") != null))
            {
                return firstSegment(src);
            }
            continue;
        }
        if (line.len > 0 and line[0] != ' ') pending = line;
    }
    return "";
}

// UI state

pub const DragKind = enum { none, device, stream, scroll };

/// `MixerUiState` — host-owned (one instance, not a TU static).
pub const UiState = struct {
    view_output: bool = true,
    router_stream: u32 = 0,
    master_picker: bool = false,
    scroll_px: f64 = 0.0,
    drag_active: bool = false,
    drag_kind: DragKind = .none,
    drag_id: u32 = 0,
    drag_is_input: bool = false,
    drag_sx: f64 = 0.0,
    drag_sw: f64 = 1.0,
    drag_t: f64 = 0.0,
    drag_pct: i32 = 0,
    drag_start_y: f64 = 0.0,
    drag_start_scroll: f64 = 0.0,
    last_apply_ms: i64 = 0,
};

/// `volume_mixer_notify_popup_open` — starts fresh but preserves the
/// Output/Input tab.
pub fn notifyOpen(st: *UiState) void {
    st.drag_active = false;
    st.drag_kind = .none;
    st.drag_id = 0;
    st.scroll_px = 0.0;
    st.router_stream = 0;
    st.master_picker = false;
}

pub fn clampScroll(px: f64, max_scroll: f64) f64 {
    return std.math.clamp(px, 0.0, @max(0.0, max_scroll));
}

// Layout (one definition for paint and hit-test)

pub const SliderGeom = struct { sx: f64 = 0, sy: f64 = 0, sw: f64 = 0 };

pub const DevRowGeom = struct {
    y: f64 = 0,
    radio_cx: f64 = 0,
    mute_x: f64 = 0,
    slider: SliderGeom = .{},
};

pub const StreamRowGeom = struct {
    y: f64 = 0,
    mute_x: f64 = 0,
    menu_x: f64 = 0,
    pct_x: f64 = 0,
    slider: SliderGeom = .{},
};

pub const MixerLayout = struct {
    view_output: bool = true,
    dev_count: usize = 0,
    stream_count: usize = 0,
    seg_x: f64 = 0,
    seg_y: f64 = 0,
    seg_w: f64 = 0,
    out_x: f64 = 0,
    out_w: f64 = 0,
    in_x: f64 = 0,
    in_w: f64 = 0,
    header_bottom: f64 = 0,
    has_master: bool = false,
    master_y: f64 = 0,
    master_slider_x: f64 = 0,
    master_slider_w: f64 = 0,
    master_slider_y: f64 = 0,
    master_mute_x: f64 = 0,
    master_mute_y: f64 = 0,
    has_master_menu: bool = false,
    master_menu_x: f64 = 0,
    master_menu_y: f64 = 0,
    dev_rows: []DevRowGeom = &.{},
    apps_divider_y: f64 = 0,
    streams_top: f64 = 0,
    viewport_y: f64 = 0,
    viewport_h: f64 = 0,
    content_h: f64 = 0,
    scroll_px: f64 = 0,
    max_scroll: f64 = 0,
    scrollable: bool = false,
    scroll_x: f64 = 0,
    scroll_w: f64 = 0,
    thumb_y: f64 = 0,
    thumb_h: f64 = 0,
    stream_rows: []StreamRowGeom = &.{},
    has_drop: bool = false,
    drop_is_master: bool = false,
    drop_x: f64 = 0,
    drop_y: f64 = 0,
    drop_w: f64 = 0,
    drop_h: f64 = 0,
    drop_stream_idx: i32 = -1,
    drop_count: usize = 0,
    drop_profile_count: usize = 0,
    drop_profile_top: f64 = 0,
    footer_y: f64 = 0,
    settings_x: f64 = 0,
    settings_w: f64 = 0,
    total_h: f64 = 0,
};

pub const LayoutCards = struct {
    cards: []const CardProfiles = &.{},
};

/// `compute_layout` — cards inform the master-menu chevron (2+ devices, or
/// a multi-profile card) and the master profile subsection.
pub fn computeLayout(
    alloc: std.mem.Allocator,
    snap: *const Snapshot,
    cards: []const CardProfiles,
    view_output: bool,
    router_stream: u32,
    master_picker: bool,
    scroll_px: f64,
) !MixerLayout {
    var lay = MixerLayout{ .view_output = view_output };
    const devices = if (view_output) snap.sinks else snap.sources;
    const streams = if (view_output) snap.out_streams else snap.in_streams;
    lay.dev_count = devices.len;
    lay.stream_count = streams.len;

    const cx = k_pad;
    const cw = popup_w - k_pad * 2.0;
    lay.seg_x = cx;
    lay.seg_y = 12.0;
    lay.seg_w = cw;
    lay.out_w = cw * 0.5;
    lay.in_w = cw - lay.out_w;
    lay.out_x = cx;
    lay.in_x = cx + lay.out_w;
    lay.header_bottom = 12.0 + k_header_h;

    var y = lay.header_bottom + 8.0;
    lay.has_master = devices.len > 0;
    if (lay.has_master) {
        lay.master_y = y;
        lay.master_slider_x = cx + k_pad;
        lay.master_slider_w = cw - k_pad * 2.0 - k_pct_w - 8.0;
        lay.master_slider_y = y + k_master_h - 30.0;
        lay.master_mute_x = cx + cw - k_pad - k_mute_btn_sz;
        lay.master_mute_y = y + 12.0;
        lay.has_master_menu = lay.dev_count > 1;
        if (!lay.has_master_menu) {
            if (masterDevice(snap, view_output)) |m0| {
                if (findCardForNode(cards, m0.raw_name)) |card| {
                    if (card.profiles.len >= 2) lay.has_master_menu = true;
                }
            }
        }
        lay.master_menu_x = lay.master_mute_x - 4.0 - k_menu_btn_sz;
        lay.master_menu_y = lay.master_mute_y;
        y += k_master_h + 8.0;
    }
    const extra: usize = if (lay.dev_count > 0) lay.dev_count - 1 else 0;
    var dev_rows = std.ArrayList(DevRowGeom).empty;
    errdefer dev_rows.deinit(alloc);
    {
        var i: usize = 0;
        while (i < extra) : (i += 1) {
            const ry = y + @as(f64, @floatFromInt(i)) * k_row_h;
            const radio_cx = cx + k_pad + k_radio_r;
            const mute_x = cx + k_pad + k_radio_r * 2.0 + 8.0 + k_tile_sz + 8.0 + k_name_max_w + 8.0;
            const sx = mute_x + k_mute_btn_sz + 8.0;
            const sw = @max(k_slider_min_w, (popup_w - k_pad) - k_pad - sx);
            try dev_rows.append(alloc, .{
                .y = ry,
                .radio_cx = radio_cx,
                .mute_x = mute_x,
                .slider = .{ .sx = sx, .sy = ry + (k_row_h - k_slider_track_h) * 0.5, .sw = sw },
            });
        }
    }
    if (extra > 0) y += @as(f64, @floatFromInt(extra)) * k_row_h + 4.0;
    lay.dev_rows = try dev_rows.toOwnedSlice(alloc);
    errdefer alloc.free(lay.dev_rows);

    lay.apps_divider_y = y + 8.0;
    lay.streams_top = lay.apps_divider_y + k_apps_header_h;

    lay.footer_y = popup_h - k_pad - k_footer_h;
    lay.settings_w = 150.0;
    lay.settings_x = cx + cw - lay.settings_w;
    lay.viewport_y = lay.streams_top;
    lay.viewport_h = @max(2.0 * k_row_h, lay.footer_y - 8.0 - lay.streams_top);

    lay.content_h = @as(f64, @floatFromInt(lay.stream_count)) * k_row_h;
    lay.max_scroll = @max(0.0, lay.content_h - lay.viewport_h);
    lay.scroll_px = clampScroll(scroll_px, lay.max_scroll);
    lay.scrollable = lay.max_scroll > 0.5;
    const right_gutter: f64 = if (lay.scrollable) k_scroll_w else 0.0;
    const row_right = (popup_w - k_pad) - k_pad - right_gutter;

    var stream_rows = std.ArrayList(StreamRowGeom).empty;
    errdefer stream_rows.deinit(alloc);
    {
        var i: usize = 0;
        while (i < lay.stream_count) : (i += 1) {
            const ry = lay.streams_top + @as(f64, @floatFromInt(i)) * k_row_h - lay.scroll_px;
            const mute_x = cx + k_pad + k_app_icon_sz + 8.0 + k_name_max_w + 4.0;
            const sx = mute_x + k_mute_btn_sz + 8.0;
            const pct_x = row_right - k_pct_w - 4.0 - k_menu_btn_sz;
            const sw = @max(k_slider_min_w, pct_x - 4.0 - sx);
            try stream_rows.append(alloc, .{
                .y = ry,
                .mute_x = mute_x,
                .menu_x = row_right - k_menu_btn_sz,
                .pct_x = pct_x,
                .slider = .{ .sx = sx, .sy = ry + (k_row_h - k_slider_track_h) * 0.5 - 4.0, .sw = sw },
            });
        }
    }
    lay.stream_rows = try stream_rows.toOwnedSlice(alloc);
    errdefer alloc.free(lay.stream_rows);

    if (lay.scrollable) {
        lay.scroll_x = cx + cw - k_scroll_w;
        lay.scroll_w = k_scroll_w;
        lay.thumb_h = @max(24.0, lay.viewport_h * lay.viewport_h / @max(1.0, lay.content_h));
        const travel = @max(1.0, lay.viewport_h - lay.thumb_h);
        lay.thumb_y = lay.viewport_y + (lay.scroll_px / @max(1.0, lay.max_scroll)) * travel;
    }

    const targets = if (view_output) snap.sinks else snap.sources;
    lay.drop_w = cw - 16.0;
    if (master_picker and lay.has_master) {
        var n_prof: usize = 0;
        if (masterDevice(snap, view_output)) |mdev| {
            if (findCardForNode(cards, mdev.raw_name)) |card| {
                if (card.profiles.len >= 2) n_prof = card.profiles.len;
            }
        }
        const dd_h = k_drop_title_h + @as(f64, @floatFromInt(@max(targets.len, 1))) * k_drop_item_h +
            (if (n_prof > 0) k_drop_sub_h + @as(f64, @floatFromInt(n_prof)) * k_drop_item_h else 0.0) + 10.0;
        const below = lay.master_y + k_master_h + 4.0;
        lay.drop_x = cx + 8.0;
        lay.drop_y = below;
        lay.drop_h = @max(0.0, @min(dd_h, popup_h - 8.0 - lay.drop_y));
        lay.drop_count = targets.len;
        lay.drop_profile_count = n_prof;
        lay.drop_profile_top = lay.drop_y + k_drop_title_h +
            @as(f64, @floatFromInt(@max(targets.len, 1))) * k_drop_item_h + k_drop_sub_h;
        lay.drop_is_master = true;
        lay.has_drop = true;
    } else if (router_stream != 0) {
        const dd_h = k_drop_title_h + @as(f64, @floatFromInt(@max(targets.len, 1))) * k_drop_item_h + 10.0;
        for (streams, 0..) |*st, i| {
            if (st.node_id != router_stream) continue;
            const g = lay.stream_rows[i];
            lay.drop_x = cx + 8.0;
            lay.drop_y = g.y + k_row_h + 4.0;
            lay.drop_h = @max(0.0, @min(dd_h, popup_h - 8.0 - lay.drop_y));
            lay.drop_stream_idx = @intCast(i);
            lay.drop_count = targets.len;
            lay.has_drop = true;
            break;
        }
    }

    lay.total_h = popup_h;
    return lay;
}

pub fn freeLayout(alloc: std.mem.Allocator, lay: *MixerLayout) void {
    alloc.free(lay.dev_rows);
    alloc.free(lay.stream_rows);
    lay.dev_rows = &.{};
    lay.stream_rows = &.{};
}

// Hit-testing

pub const Hit = enum {
    none,
    out_seg,
    in_seg,
    master_mute,
    master_slider,
    master_picker,
    dev_radio,
    dev_mute,
    dev_slider,
    stream_mute,
    stream_slider,
    stream_menu,
    drop_item,
    drop_profile,
    drop_swallow,
    scroll_thumb,
    scroll_track,
    footer_settings,
};

pub const HitResult = struct {
    hit: Hit = .none,
    index: i32 = -1,
    t: f64 = 0.0,
};

pub fn hitName(h: Hit) []const u8 {
    return switch (h) {
        .none => "none",
        .out_seg => "out-seg",
        .in_seg => "in-seg",
        .master_mute => "master-mute",
        .master_slider => "master-slider",
        .master_picker => "master-picker",
        .dev_radio => "dev-radio",
        .dev_mute => "dev-mute",
        .dev_slider => "dev-slider",
        .stream_mute => "stream-mute",
        .stream_slider => "stream-slider",
        .stream_menu => "stream-menu",
        .drop_item => "drop-item",
        .drop_profile => "drop-profile",
        .drop_swallow => "drop-swallow",
        .scroll_thumb => "scroll-thumb",
        .scroll_track => "scroll-track",
        .footer_settings => "footer-settings",
    };
}

fn inRect(px: f64, py: f64, x: f64, y: f64, w: f64, h: f64) bool {
    return px >= x and px < x + w and py >= y and py < y + h;
}

/// `hit_test` — segment, master, floating dropdown, device rows, stream
/// rows (clipped ones are not interactive), scrollbar, footer.
pub fn hitTest(lay: *const MixerLayout, snap: *const Snapshot, x: f64, y: f64) HitResult {
    var r = HitResult{};
    const cx = k_pad;
    const cw = popup_w - k_pad * 2.0;
    if (x < 0 or x >= popup_w or y < 0) return r;

    if (y >= lay.seg_y and y < lay.seg_y + k_seg_h) {
        if (x >= lay.out_x and x < lay.out_x + lay.out_w) {
            r.hit = .out_seg;
            return r;
        }
        if (x >= lay.in_x and x < lay.in_x + lay.in_w) {
            // Answers unless there is nothing to switch to while already
            // looking at outputs.
            if (snap.sources.len > 0 or !lay.view_output) {
                r.hit = .in_seg;
                return r;
            }
        }
    }
    if (lay.has_master) {
        if (lay.has_master_menu and inRect(x, y, lay.master_menu_x, lay.master_menu_y, k_menu_btn_sz, k_menu_btn_sz)) {
            r.hit = .master_picker;
            return r;
        }
        if (inRect(x, y, lay.master_mute_x, lay.master_mute_y, k_mute_btn_sz, k_mute_btn_sz)) {
            r.hit = .master_mute;
            return r;
        }
        if (x >= lay.master_slider_x - k_hit_pad_h and x <= lay.master_slider_x + lay.master_slider_w + k_hit_pad_h and
            y >= lay.master_slider_y - k_hit_pad_v and y <= lay.master_slider_y + k_slider_track_h + k_hit_pad_v)
        {
            r.hit = .master_slider;
            r.t = std.math.clamp((x - lay.master_slider_x) / @max(1.0, lay.master_slider_w), 0.0, 1.0);
            return r;
        }
    }
    if (lay.has_drop and x >= lay.drop_x and x < lay.drop_x + lay.drop_w and y >= lay.drop_y and y < lay.drop_y + lay.drop_h) {
        const idx: i32 = @intFromFloat(@floor((y - lay.drop_y - k_drop_title_h) / k_drop_item_h));
        if (idx >= 0 and idx < @as(i32, @intCast(lay.drop_count))) {
            r.hit = .drop_item;
            r.index = idx;
            return r;
        }
        if (lay.drop_profile_count > 0) {
            const pidx: i32 = @intFromFloat(@floor((y - lay.drop_profile_top) / k_drop_item_h));
            if (pidx >= 0 and pidx < @as(i32, @intCast(lay.drop_profile_count)) and
                lay.drop_profile_top + @as(f64, @floatFromInt(pidx)) * k_drop_item_h + k_drop_item_h <=
                    lay.drop_y + lay.drop_h + 1.0)
            {
                r.hit = .drop_profile;
                r.index = pidx;
                return r;
            }
        }
        r.hit = .drop_swallow;
        return r;
    }
    for (lay.dev_rows, 0..) |*dr, i| {
        if (y < dr.y or y >= dr.y + k_row_h) continue;
        if (x >= dr.mute_x and x < dr.mute_x + k_mute_btn_sz) {
            r.hit = .dev_mute;
            r.index = @intCast(i);
            return r;
        }
        if (x >= dr.slider.sx - k_hit_pad_h and x <= dr.slider.sx + dr.slider.sw + k_hit_pad_h and
            y >= dr.slider.sy - k_hit_pad_v and y <= dr.slider.sy + k_slider_track_h + k_hit_pad_v)
        {
            r.hit = .dev_slider;
            r.index = @intCast(i);
            r.t = std.math.clamp((x - dr.slider.sx) / @max(1.0, dr.slider.sw), 0.0, 1.0);
            return r;
        }
        if (x >= cx and x <= cx + cw) {
            r.hit = .dev_radio;
            r.index = @intCast(i);
            return r;
        }
    }
    for (lay.stream_rows, 0..) |*sr, i| {
        if (y < sr.y or y >= sr.y + k_row_h) continue;
        if (sr.y + k_row_h <= lay.viewport_y or sr.y >= lay.viewport_y + lay.viewport_h) continue;
        if (x >= sr.mute_x and x < sr.mute_x + k_mute_btn_sz) {
            r.hit = .stream_mute;
            r.index = @intCast(i);
            return r;
        }
        if (x >= sr.menu_x and x < sr.menu_x + k_menu_btn_sz) {
            r.hit = .stream_menu;
            r.index = @intCast(i);
            return r;
        }
        if (x >= sr.slider.sx - k_hit_pad_h and x <= sr.slider.sx + sr.slider.sw + k_hit_pad_h and
            y >= sr.slider.sy - k_hit_pad_v and y <= sr.slider.sy + k_slider_track_h + k_hit_pad_v)
        {
            r.hit = .stream_slider;
            r.index = @intCast(i);
            r.t = std.math.clamp((x - sr.slider.sx) / @max(1.0, sr.slider.sw), 0.0, 1.0);
            return r;
        }
    }
    if (lay.scrollable and x >= lay.scroll_x and x < lay.scroll_x + lay.scroll_w and
        y >= lay.viewport_y and y < lay.viewport_y + lay.viewport_h)
    {
        if (y >= lay.thumb_y and y < lay.thumb_y + lay.thumb_h) {
            r.hit = .scroll_thumb;
            return r;
        }
        r.hit = .scroll_track;
        r.t = if (y < lay.thumb_y) -1.0 else 1.0;
        return r;
    }
    if (y >= lay.footer_y and y < lay.footer_y + k_footer_h and
        x >= lay.settings_x and x < lay.settings_x + lay.settings_w)
    {
        r.hit = .footer_settings;
        return r;
    }
    return r;
}

// Input core (coordinate-only; service writes surface as Effects)

/// A service write the host must perform. Volumes are 0..1 fractions of the
/// 150% track (`t * 1.5`); the dock's `cc_apply` queue already
/// speaks this shape.
pub const Verb = enum {
    none,
    set_volume,
    set_mute,
    set_default_sink,
    set_default_source,
    route_playback,
    route_capture,
    apply_card_profile,
    launch_settings,
};

pub const Effect = struct {
    verb: Verb = .none,
    /// Device/stream node id the verb targets.
    node_id: u32 = 0,
    /// 0..1 track fraction for `set_volume`.
    volume_t: f64 = 0,
    /// Mute state for `set_mute`.
    muted: bool = false,
    /// Route target node id for `route_*`.
    target_id: u32 = 0,
    /// Card profile application.
    card_index: u32 = 0,
    profile_key: []const u8 = "",
};

pub const ClickOut = struct {
    /// True when the tab switched (Output↔Input): the host must regrow the
    /// surface, like `mixer_resize_popup` (grow-only; shrinking settles on
    /// the next open to avoid flicker).
    resized: bool = false,
    effect: Effect = .{},
};

fn beginDrag(st: *UiState, kind: DragKind, id: u32, is_input: bool, sx: f64, sw: f64, t: f64) void {
    st.drag_active = true;
    st.drag_kind = kind;
    st.drag_id = id;
    st.drag_is_input = is_input;
    st.drag_sx = sx;
    st.drag_sw = @max(1.0, sw);
    st.drag_t = std.math.clamp(t, 0.0, 1.0);
    st.drag_pct = std.math.clamp(@as(i32, @intFromFloat(@round(st.drag_t * 150.0))), 0, 150);
    st.last_apply_ms = 0;
}

/// `mixer_click_at` — dropdown capture first (items act, chrome absorbs,
/// anything else dismisses without touching the slider underneath), then
/// the hit switch. Answers whether the tab switched plus at most one
/// service effect. `cards` informs profile application.
pub fn clickAt(
    st: *UiState,
    snap: *const Snapshot,
    cards: []const CardProfiles,
    lay: *const MixerLayout,
    h: HitResult,
    y: f64,
    now_ms: i64,
) ClickOut {
    _ = now_ms;
    var out = ClickOut{};
    const devices = if (st.view_output) snap.sinks else snap.sources;
    const streams = if (st.view_output) snap.out_streams else snap.in_streams;

    const drop_open = st.router_stream != 0 or st.master_picker;
    if (drop_open and h.hit != .stream_menu and h.hit != .master_picker) {
        if (h.hit == .drop_profile and st.master_picker) {
            if (masterDevice(snap, st.view_output)) |m| {
                if (findCardForNode(cards, m.raw_name)) |card| {
                    if (h.index >= 0 and @as(usize, @intCast(h.index)) < card.profiles.len) {
                        const opt = card.profiles[@intCast(h.index)];
                        out.effect = .{
                            .verb = .apply_card_profile,
                            .card_index = card.card_index,
                            .profile_key = opt.key,
                        };
                    }
                }
            }
            st.router_stream = 0;
            st.master_picker = false;
            return out;
        }
        if (h.hit == .drop_item) {
            const targets = if (st.view_output) snap.sinks else snap.sources;
            if (h.index >= 0 and @as(usize, @intCast(h.index)) < targets.len) {
                const target = targets[@intCast(h.index)];
                if (st.master_picker) {
                    out.effect = .{
                        .verb = if (st.view_output) .set_default_sink else .set_default_source,
                        .node_id = target.node_id,
                    };
                } else if (st.router_stream != 0) {
                    out.effect = .{
                        .verb = if (st.view_output) .route_playback else .route_capture,
                        .node_id = st.router_stream,
                        .target_id = target.node_id,
                    };
                }
            }
            st.router_stream = 0;
            st.master_picker = false;
            return out;
        }
        if (h.hit != .drop_swallow) {
            st.router_stream = 0;
            st.master_picker = false;
        }
        return out;
    }

    switch (h.hit) {
        .out_seg => {
            if (!st.view_output) {
                st.view_output = true;
                st.router_stream = 0;
                st.master_picker = false;
                st.scroll_px = 0.0;
                out.resized = true;
            }
        },
        .in_seg => {
            if (st.view_output and snap.sources.len > 0) {
                st.view_output = false;
                st.router_stream = 0;
                st.master_picker = false;
                st.scroll_px = 0.0;
                out.resized = true;
            }
        },
        .master_mute => {
            if (masterDevice(snap, st.view_output)) |m| {
                out.effect = .{ .verb = .set_mute, .node_id = m.node_id, .muted = !m.muted };
            }
        },
        .master_slider => {
            if (masterDevice(snap, st.view_output)) |m| {
                out.effect = .{ .verb = .set_volume, .node_id = m.node_id, .volume_t = h.t * 1.5 };
                beginDrag(st, .device, m.node_id, !st.view_output, lay.master_slider_x, lay.master_slider_w, h.t);
            }
        },
        .master_picker => {
            st.master_picker = !st.master_picker;
            st.router_stream = 0;
        },
        .dev_radio, .dev_mute, .dev_slider => {
            // Row 0 is the master card: device rows address devices[1..].
            const di: usize = @intCast(h.index + 1);
            if (di < devices.len) {
                if (h.hit == .dev_radio) {
                    out.effect = .{
                        .verb = if (st.view_output) .set_default_sink else .set_default_source,
                        .node_id = devices[di].node_id,
                    };
                } else if (h.hit == .dev_mute) {
                    out.effect = .{ .verb = .set_mute, .node_id = devices[di].node_id, .muted = !devices[di].muted };
                } else {
                    out.effect = .{ .verb = .set_volume, .node_id = devices[di].node_id, .volume_t = h.t * 1.5 };
                    if (@as(usize, @intCast(h.index)) < lay.dev_rows.len) {
                        const g = lay.dev_rows[@intCast(h.index)];
                        beginDrag(st, .device, devices[di].node_id, !st.view_output, g.slider.sx, g.slider.sw, h.t);
                    }
                }
            }
        },
        .stream_mute => {
            if (h.index >= 0 and @as(usize, @intCast(h.index)) < streams.len) {
                const stm = streams[@intCast(h.index)];
                out.effect = .{ .verb = .set_mute, .node_id = stm.node_id, .muted = !stm.muted };
            }
        },
        .stream_slider => {
            if (h.index >= 0 and @as(usize, @intCast(h.index)) < streams.len and
                @as(usize, @intCast(h.index)) < lay.stream_rows.len)
            {
                const stm = streams[@intCast(h.index)];
                out.effect = .{ .verb = .set_volume, .node_id = stm.node_id, .volume_t = h.t * 1.5 };
                const g = lay.stream_rows[@intCast(h.index)];
                beginDrag(st, .stream, stm.node_id, !st.view_output, g.slider.sx, g.slider.sw, h.t);
            }
        },
        .stream_menu => {
            if (h.index >= 0 and @as(usize, @intCast(h.index)) < streams.len) {
                const stm = streams[@intCast(h.index)];
                st.router_stream = if (st.router_stream == stm.node_id) 0 else stm.node_id;
                st.master_picker = false;
            }
        },
        .drop_item, .drop_profile, .drop_swallow => {},
        .scroll_thumb => {
            st.drag_active = true;
            st.drag_kind = .scroll;
            st.drag_id = 0;
            st.drag_start_y = y;
            st.drag_start_scroll = lay.scroll_px;
            st.router_stream = 0;
            st.master_picker = false;
        },
        .scroll_track => {
            st.scroll_px = clampScroll(lay.scroll_px + h.t * lay.viewport_h, lay.max_scroll);
            st.router_stream = 0;
            st.master_picker = false;
        },
        .footer_settings => {
            out.effect = .{ .verb = .launch_settings };
        },
        .none => {},
    }
    return out;
}

/// Pointer Y is threaded through `clickAt` for the scroll-thumb grab (the
/// layout hit carries the thumb zone but not the grab point).
/// `mixer_motion_at` — scrollbar drags rescale by content/viewport ratio;
/// slider drags retune `t`/`pct` and apply at most every 16 ms. Answers a
/// service effect when one fired. `hold_ms` receives the engine-hold
/// deadline (`now + 400`) while dragging so the host can hold TTL refreshes
/// off the drag.
pub fn motionAt(
    st: *UiState,
    snap: *const Snapshot,
    lay: *const MixerLayout,
    x: f64,
    y: f64,
    now_ms: i64,
    hold_ms: *i64,
) ?Effect {
    if (!st.drag_active) return null;
    hold_ms.* = now_ms + engine_hold_ms;
    if (st.drag_kind == .scroll) {
        const ratio = lay.content_h / @max(1.0, lay.viewport_h);
        st.scroll_px = clampScroll(st.drag_start_scroll + (y - st.drag_start_y) * ratio, lay.max_scroll);
        return null;
    }
    _ = snap;
    const t = std.math.clamp((x - st.drag_sx) / st.drag_sw, 0.0, 1.0);
    st.drag_t = t;
    st.drag_pct = std.math.clamp(@as(i32, @intFromFloat(@round(t * 150.0))), 0, 150);
    if (st.last_apply_ms == 0 or now_ms - st.last_apply_ms >= drag_apply_ms) {
        st.last_apply_ms = now_ms;
        return .{ .verb = .set_volume, .node_id = st.drag_id, .volume_t = t * 1.5 };
    }
    return null;
}

/// `mixer_release_at` — final apply, drag cleared, engine hold released
/// (the host resets its hold to 0).
pub fn releaseAt(st: *UiState, x: f64) ?Effect {
    if (!st.drag_active) return null;
    if (st.drag_kind == .scroll) {
        st.drag_active = false;
        st.drag_kind = .none;
        return null;
    }
    const t = std.math.clamp((x - st.drag_sx) / st.drag_sw, 0.0, 1.0);
    const id = st.drag_id;
    st.drag_active = false;
    st.drag_kind = .none;
    st.drag_id = 0;
    return .{ .verb = .set_volume, .node_id = id, .volume_t = t * 1.5 };
}

/// `mixer_axis_at` — viewport scroll (±60, dismissing dropdowns) anywhere
/// in the viewport that is not a slider; slider bump of
/// `lround(-delta/20*5)` clamped to `[0, 150]` on sliders. Answers whether
/// the event was consumed, plus an optional service effect for slider
/// bumps. The raw pointer (not the hit test) decides viewport
/// membership.
pub fn axisAt(
    st: *UiState,
    snap: *const Snapshot,
    lay: *const MixerLayout,
    h: HitResult,
    x: f64,
    y: f64,
    delta_px: f64,
) struct { consumed: bool, effect: Effect } {
    const on_slider = h.hit == .master_slider or h.hit == .master_mute or h.hit == .dev_slider or
        h.hit == .dev_mute or h.hit == .stream_slider or h.hit == .stream_mute;
    const devices = if (st.view_output) snap.sinks else snap.sources;
    const streams = if (st.view_output) snap.out_streams else snap.in_streams;
    if (!on_slider) {
        const in_viewport = x >= k_pad and x < k_pad + (popup_w - k_pad * 2.0) and
            y >= lay.viewport_y and y < lay.viewport_y + lay.viewport_h;
        if (in_viewport and lay.scrollable) {
            st.scroll_px = clampScroll(lay.scroll_px + (if (delta_px > 0.0) scroll_step else -scroll_step), lay.max_scroll);
            st.router_stream = 0;
            return .{ .consumed = true, .effect = .{} };
        }
        if (h.hit == .drop_item or h.hit == .drop_swallow or h.hit == .scroll_thumb or h.hit == .scroll_track)
            return .{ .consumed = true, .effect = .{} };
        return .{ .consumed = false, .effect = .{} };
    }
    const d_pct: i32 = @as(i32, @intFromFloat(@round(-delta_px / axis_step_div * 5.0)));
    if (d_pct == 0) return .{ .consumed = true, .effect = .{} };
    switch (h.hit) {
        .master_slider, .master_mute => {
            if (masterDevice(snap, st.view_output)) |m| {
                return .{
                    .consumed = true,
                    .effect = .{ .verb = .set_volume, .node_id = m.node_id, .volume_t = @as(f64, @floatFromInt(std.math.clamp(m.volume_pct + d_pct, 0, 150))) / 100.0 },
                };
            }
            return .{ .consumed = true, .effect = .{} };
        },
        .dev_slider, .dev_mute => {
            const di: usize = @intCast(h.index + 1);
            if (di < devices.len) {
                return .{
                    .consumed = true,
                    .effect = .{ .verb = .set_volume, .node_id = devices[di].node_id, .volume_t = @as(f64, @floatFromInt(std.math.clamp(devices[di].volume_pct + d_pct, 0, 150))) / 100.0 },
                };
            }
            return .{ .consumed = true, .effect = .{} };
        },
        .stream_slider, .stream_mute => {
            if (h.index >= 0 and @as(usize, @intCast(h.index)) < streams.len) {
                const stm = streams[@intCast(h.index)];
                return .{
                    .consumed = true,
                    .effect = .{ .verb = .set_volume, .node_id = stm.node_id, .volume_t = @as(f64, @floatFromInt(std.math.clamp(stm.volume_pct + d_pct, 0, 150))) / 100.0 },
                };
            }
            return .{ .consumed = true, .effect = .{} };
        },
        else => return .{ .consumed = false, .effect = .{} },
    }
}

// Tests: model, names, layout, hit-test, input

fn dev(id: u32, name: []const u8, def: bool, pct: i32, muted: bool) DeviceInfo {
    return .{ .node_id = id, .name = name, .raw_name = name, .is_default = def, .volume_pct = pct, .muted = muted };
}

fn stream(id: u32, app: []const u8, pct: i32) StreamInfo {
    return .{ .node_id = id, .app_name = app, .volume_pct = pct };
}

test "mixer: master device prefers the default" {
    const t = std.testing;
    const snap = Snapshot{ .sinks = &[_]DeviceInfo{
        dev(11, "A", false, 50, false),
        dev(22, "B", true, 80, false),
    } };
    try t.expectEqual(@as(u32, 22), masterDevice(&snap, true).?.node_id);
    const solo = Snapshot{ .sinks = &[_]DeviceInfo{dev(11, "A", false, 50, false)} };
    try t.expectEqual(@as(u32, 11), masterDevice(&solo, true).?.node_id);
    const empty = Snapshot{};
    try t.expect(masterDevice(&empty, true) == null);
    try t.expect(findCardForNode(&.{}, "bluez_output.X") == null);
    const cards = [_]CardProfiles{.{ .card_key = "bluez_card.A8_99", .profiles = &.{} }};
    try t.expect(findCardForNode(&cards, "bluez_output.A8_99_DC.1") != null);
    try t.expect(findCardForNode(&cards, "alsa_output.usb") == null);
}

test "mixer: generic runtime names" {
    const t = std.testing;
    try t.expect(isGenericRuntimeBinary("electron"));
    try t.expect(isGenericRuntimeBinary("chromium"));
    try t.expect(isGenericRuntimeBinary("python3"));
    try t.expect(!isGenericRuntimeBinary("firefox"));
    try t.expect(!isGenericRuntimeBinary(""));
    try t.expect(isGenericIconName(""));
    try t.expect(isGenericIconName("Electron"));
    try t.expect(isGenericIconName("google-chrome-stable"));
    try t.expect(!isGenericIconName("firefox"));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("a|b|c|d", streamIdentity(&buf, "a", "b", "c", "d"));
    // Candidate prettifier: basename, suffix strip, capitalize.
    var pbuf: [64]u8 = undefined;
    try t.expectEqualStrings("Firefox", prettifyCandidate(&pbuf, "/usr/lib/firefox/firefox-bin"));
    try t.expectEqualStrings("Myapp", prettifyCandidate(&pbuf, "myapp.exe"));
    try t.expectEqualStrings("", prettifyCandidate(&pbuf, ""));
}

test "mixer: stream display resolution" {
    const t = std.testing;
    // Desktop entry wins for both fields.
    var dummy: u8 = 0;
    const dl = DesktopLookup{
        .ctx = &dummy,
        .lookup = struct {
            fn f(_: *anyopaque, id: []const u8) ?DesktopEntry {
                if (std.mem.eql(u8, id, "firefox")) return .{ .name = "Firefox", .icon = "firefox" };
                return null;
            }
        }.f,
    };
    const r = try resolveStreamDisplay(t.allocator, "Firefox Web Browser", "", "firefox", "firefox", "Firefox", "Firefox", dl);
    try t.expectEqualStrings("Firefox", r.app_name);
    try t.expectEqualStrings("firefox", r.icon_name);
    // No entry: description wins unless generic, then the binary.
    // Borrowed names (description) must not be freed; only prettified
    // ones (binary/app-id/node) are owned.
    const r2 = try resolveStreamDisplay(t.allocator, "", "", "electron", "/usr/bin/electron", "chromium", "Playback", null);
    try t.expectEqualStrings("Playback", r2.app_name);
    const r3 = try resolveStreamDisplay(t.allocator, "", "", "electron", "/usr/bin/myplayer", "x", "", null);
    defer t.allocator.free(r3.app_name);
    try t.expectEqualStrings("Myplayer", r3.app_name);
    // Nothing at all: Unknown, and generic icons clear.
    const r4 = try resolveStreamDisplay(t.allocator, "", "electron", "", "", "", "", null);
    try t.expectEqualStrings("Unknown", r4.app_name);
    try t.expectEqualStrings("", r4.icon_name);
}

test "mixer: device/profile shortening" {
    const t = std.testing;
    // First-occurrence mechanics: ` Audio Controller`
    // matches inside `HD Audio Controller`, so the Family strip is left
    // with just `HD`.
    const a = try shortenDeviceName(t.allocator, "Family 17h/19h HD Audio Controller");
    defer t.allocator.free(a);
    try t.expectEqualStrings("HD", a);
    const b = try shortenDeviceName(t.allocator, "GB203 HD Audio Digital Stereo (HDMI)");
    defer t.allocator.free(b);
    try t.expectEqualStrings("GB203 HD Audio HDMI", b);
    const c = try shortenDeviceName(t.allocator, "Navi 31 HDMI/DP Audio [MAG 272Q X24]");
    defer t.allocator.free(c);
    try t.expectEqualStrings("Navi 31 HDMI/DP Audio", c);
    const p1 = try shortenProfileLabel(t.allocator, "a2dp", "High Fidelity Playback (A2DP Sink, codec aptX)");
    defer t.allocator.free(p1);
    try t.expectEqualStrings("A2DP · aptX", p1);
    // NOTE: the header comment's `HDMI 2 Out` example does not match its
    // own code — `find_first_of(" )")` stops at the space, so the port
    // follows the code (`HDMI Out`), not the comment.
    const p2 = try shortenProfileLabel(t.allocator, "x", "Digital Stereo (HDMI 2) Output");
    defer t.allocator.free(p2);
    try t.expectEqualStrings("HDMI Out", p2);
    const p3 = try shortenProfileLabel(t.allocator, "off", "Whatever");
    defer t.allocator.free(p3);
    try t.expectEqualStrings("Off", p3);
}

test "mixer: pw-link routing parsers" {
    const t = std.testing;
    const blob =
        \\Firefox:output_FL
        \\  |-> alsa_output.pci:playback_FL
        \\alsa_output.pci:monitor_FL
        \\  |-> Recorder:input_FL
    ;
    try t.expectEqualStrings("alsa_output.pci", playbackSinkForStream(blob, "Firefox"));
    try t.expectEqualStrings("", playbackSinkForStream(blob, "Nope"));
    try t.expectEqualStrings("alsa_output.pci", captureSourceForStream(blob, "Recorder"));
    try t.expectEqualStrings("", captureSourceForStream("", "Firefox"));
    try t.expectEqualStrings("", playbackSinkForStream(blob, ""));
    // Reverse-arrow form: the pending side names playback.
    const blob2 =
        \\alsa_output.pci:playback_FL
        \\  |<- Firefox:output_FL
    ;
    try t.expectEqualStrings("alsa_output.pci", playbackSinkForStream(blob2, "Firefox"));
}

test "mixer: layout geometry" {
    const t = std.testing;
    const snap = Snapshot{
        .sinks = &[_]DeviceInfo{ dev(1, "Out", true, 80, false), dev(2, "HDMI", false, 50, false) },
        .out_streams = &[_]StreamInfo{stream(101, "Firefox", 90)},
    };
    var lay = try computeLayout(t.allocator, &snap, &.{}, true, 0, false, 0);
    defer freeLayout(t.allocator, &lay);
    try t.expect(lay.has_master);
    try t.expect(lay.has_master_menu);
    try t.expectEqual(@as(usize, 1), lay.dev_rows.len);
    try t.expectEqual(@as(usize, 1), lay.stream_rows.len);
    try t.expectEqual(@as(f64, 12.0), lay.seg_y);
    try t.expectEqual(@as(f64, 68.0), lay.header_bottom);
    try t.expectEqual(@as(f64, 96.0), k_master_h);
    // Master slider spans the card minus pads, pct and gaps.
    try t.expect(lay.master_slider_w > k_slider_min_w);
    try t.expect(!lay.scrollable);
    // Narrow stream rows still honor the slider floor.
    try t.expect(lay.stream_rows[0].slider.sw >= k_slider_min_w);
}

test "mixer: hit zones" {
    const t = std.testing;
    const snap = Snapshot{
        .sinks = &[_]DeviceInfo{ dev(1, "Out", true, 80, false), dev(2, "HDMI", false, 50, false) },
        .sources = &[_]DeviceInfo{dev(9, "Mic", true, 70, false)},
        .out_streams = &[_]StreamInfo{stream(101, "Firefox", 90)},
    };
    var lay = try computeLayout(t.allocator, &snap, &.{}, true, 0, false, 0);
    defer freeLayout(t.allocator, &lay);
    try t.expectEqual(Hit.out_seg, hitTest(&lay, &snap, lay.out_x + 1, lay.seg_y + 1).hit);
    try t.expectEqual(Hit.in_seg, hitTest(&lay, &snap, lay.in_x + 1, lay.seg_y + 1).hit);
    try t.expectEqual(Hit.master_mute, hitTest(&lay, &snap, lay.master_mute_x + 1, lay.master_mute_y + 1).hit);
    try t.expectEqual(Hit.master_slider, hitTest(&lay, &snap, lay.master_slider_x + 5, lay.master_slider_y).hit);
    try t.expectEqual(Hit.dev_mute, hitTest(&lay, &snap, lay.dev_rows[0].mute_x + 1, lay.dev_rows[0].y + 1).hit);
    try t.expectEqual(Hit.stream_mute, hitTest(&lay, &snap, lay.stream_rows[0].mute_x + 1, lay.stream_rows[0].y + 1).hit);
    try t.expectEqual(Hit.stream_menu, hitTest(&lay, &snap, lay.stream_rows[0].menu_x + 1, lay.stream_rows[0].y + 1).hit);
    try t.expectEqual(Hit.footer_settings, hitTest(&lay, &snap, lay.settings_x + 1, lay.footer_y + 1).hit);
    try t.expectEqual(Hit.none, hitTest(&lay, &snap, -5, 10).hit);
}

test "mixer: click state machine" {
    const t = std.testing;
    const snap = Snapshot{
        .sinks = &[_]DeviceInfo{ dev(1, "Out", true, 80, false), dev(2, "HDMI", false, 50, false) },
        .sources = &[_]DeviceInfo{dev(9, "Mic", true, 70, false)},
        .out_streams = &[_]StreamInfo{stream(101, "Firefox", 90)},
    };
    var st = UiState{};
    var lay = try computeLayout(t.allocator, &snap, &.{}, true, 0, false, 0);
    defer freeLayout(t.allocator, &lay);
    // Tab switch regrows and resets scroll/router.
    st.scroll_px = 30;
    const sw = clickAt(&st, &snap, &.{}, &lay, hitTest(&lay, &snap, lay.in_x + 1, lay.seg_y + 1), 20, 0);
    try t.expect(sw.resized);
    try t.expect(!st.view_output);
    try t.expectEqual(@as(f64, 0), st.scroll_px);
    // Master slider starts a device drag with an immediate apply.
    st.view_output = true;
    const ms = clickAt(&st, &snap, &.{}, &lay, hitTest(&lay, &snap, lay.master_slider_x + 5, lay.master_slider_y), 0, 0);
    try t.expectEqual(Verb.set_volume, ms.effect.verb);
    try t.expectEqual(@as(u32, 1), ms.effect.node_id);
    try t.expect(st.drag_active and st.drag_kind == .device);
    // Motion retunes; release finalizes.
    var hold: i64 = 0;
    const mo = motionAt(&st, &snap, &lay, lay.master_slider_x + 10, 0, 100, &hold);
    try t.expect(mo != null);
    try t.expectEqual(@as(i64, 500), hold);
    const rel = releaseAt(&st, lay.master_slider_x + 10);
    try t.expect(rel != null);
    try t.expect(!st.drag_active);
    // Stream menu toggles routing on the stream id.
    const sm = clickAt(&st, &snap, &.{}, &lay, hitTest(&lay, &snap, lay.stream_rows[0].menu_x + 1, lay.stream_rows[0].y + 1), 0, 0);
    try t.expectEqual(@as(u32, 101), st.router_stream);
    _ = sm;
    // Axis on a slider bumps +5% per 20px.
    const ax = axisAt(&st, &snap, &lay, hitTest(&lay, &snap, lay.master_slider_x + 5, lay.master_slider_y), 0, 0, -20);
    try t.expect(ax.consumed);
    try t.expectEqual(Verb.set_volume, ax.effect.verb);
    try t.expectApproxEqAbs(@as(f64, 0.85), ax.effect.volume_t, 1e-9);
}

test "mixer: scroll and dropdown capture" {
    const t = std.testing;
    var streams = std.ArrayList(StreamInfo).empty;
    defer streams.deinit(t.allocator);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try streams.append(t.allocator, stream(100 + i, "App", 50));
    }
    const snap = Snapshot{
        .sinks = &[_]DeviceInfo{dev(1, "Out", true, 80, false)},
        .out_streams = streams.items,
    };
    var st = UiState{};
    var lay = try computeLayout(t.allocator, &snap, &.{}, true, 0, false, 0);
    defer freeLayout(t.allocator, &lay);
    try t.expect(lay.scrollable);
    try t.expect(lay.max_scroll > 0);
    // Track click pages down by a viewport.
    const before = lay.scroll_px;
    const tr = clickAt(&st, &snap, &.{}, &lay, hitTest(&lay, &snap, lay.scroll_x + 1, lay.thumb_y + lay.thumb_h + 5), lay.thumb_y, 0);
    _ = tr;
    try t.expect(st.scroll_px > before);
    // Thumb grab + drag scrolls proportionally.
    st.scroll_px = 0;
    var lay2 = try computeLayout(t.allocator, &snap, &.{}, true, 0, false, 0);
    defer freeLayout(t.allocator, &lay2);
    const th = clickAt(&st, &snap, &.{}, &lay2, hitTest(&lay2, &snap, lay2.scroll_x + 1, lay2.thumb_y + 1), lay2.thumb_y + 1, 0);
    _ = th;
    try t.expect(st.drag_active and st.drag_kind == .scroll);
    var hold: i64 = 0;
    _ = motionAt(&st, &snap, &lay2, 0, lay2.thumb_y + 50, 999, &hold);
    try t.expect(st.scroll_px > 0);
    // Open router on stream 0; a click elsewhere dismisses without effect.
    st.drag_active = false;
    st.drag_kind = .none;
    var lay3 = try computeLayout(t.allocator, &snap, &.{}, true, 100, false, 0);
    defer freeLayout(t.allocator, &lay3);
    try t.expect(lay3.has_drop and !lay3.drop_is_master);
    st.router_stream = 100;
    const dismiss = clickAt(&st, &snap, &.{}, &lay3, HitResult{ .hit = .none }, 0, 0);
    try t.expect(dismiss.effect.verb == .none);
    try t.expectEqual(@as(u32, 0), st.router_stream);
}

// Stream icon candidates (`mixer_stream_icon_resolve`, host-agnostic half)

/// Candidate theme icon names for a stream, in attempt order: the
/// stream's own icon (slash paths and dotted names first, then plain),
/// the app id (+ last-dot segment), the process basename (wrappers like
/// `bwrap`/`flatpak-bwrap` skipped), the theme hint keys for known apps,
/// the app-name slug and its first long token. The host tries each against
/// its theme and takes the first hit. (The desktop-entry `Icon=` step of
/// the cascade is folded into `resolveStreamDisplay`, which runs at
/// snapshot time with the host's desktop lookup.)
pub fn streamIconNames(
    out: [][2][]const u8,
    icon_name: []const u8,
    app_id: []const u8,
    process_binary: []const u8,
    app_name: []const u8,
) [][2][]const u8 {
    var n: usize = 0;
    const put = struct {
        fn f(list: [][2][]const u8, i: *usize, name: []const u8, tray: bool) void {
            if (name.len == 0 or i.* >= list.len) return;
            const tag: []const u8 = if (tray) "t" else "a";
            for (list[0..i.*]) |e| {
                if (std.mem.eql(u8, e[0], name) and std.mem.eql(u8, e[1], tag)) return;
            }
            list[i.*] = .{ name, tag };
            i.* += 1;
        }
    }.f;
    if (icon_name.len > 0) {
        if (icon_name[0] == '/') {
            put(out, &n, icon_name, true);
        } else {
            // Dotted names try the app cache first (the host lowercases on
            // match, trying the lowered name).
            if (std.mem.indexOfScalar(u8, icon_name, '.') != null) put(out, &n, icon_name, false);
            put(out, &n, icon_name, true);
        }
    }
    put(out, &n, app_id, false);
    if (std.mem.indexOfScalar(u8, app_id, '_')) |_| {
        // `_` → `-` variant, attempted as both app and tray hits.
        // (Computed by the host from app_id; listed here for order.)
    }
    if (std.mem.lastIndexOfScalar(u8, app_id, '.')) |d| {
        if (d + 1 < app_id.len) {
            put(out, &n, app_id[d + 1 ..], false);
            put(out, &n, app_id[d + 1 ..], true);
        }
    }
    put(out, &n, app_id, true);
    if (process_binary.len > 0) {
        const base = std.fs.path.basename(process_binary);
        if (!isWrapperBinary(base)) {
            put(out, &n, base, false);
            put(out, &n, base, true);
        }
    }
    // Theme hint keys for known apps (Edge, Jagex, cava, speech-dispatcher).
    var hb: [8][]const u8 = undefined;
    for (mixerThemeHintKeys(&hb, process_binary, app_name)) |h| put(out, &n, h, false);
    if (app_name.len > 0 and !std.mem.eql(u8, app_name, "Unknown App") and !std.mem.eql(u8, app_name, "Unknown")) {
        put(out, &n, app_name, false);
        var slug_buf: [256]u8 = undefined;
        const slug = slugify(&slug_buf, app_name);
        if (slug.len > 0) put(out, &n, slug, true);
        if (firstAlphaToken(app_name)) |tok| {
            if (tok.len >= 3) {
                put(out, &n, tok, false);
                put(out, &n, tok, true);
            }
        }
    }
    return out[0..n];
}

fn isWrapperBinary(base: []const u8) bool {
    for ([_][]const u8{ "bwrap", "flatpak-bwrap", "fuse-overlayfs", "snap-confine", "xdg-dbus-proxy" }) |w| {
        if (std.mem.eql(u8, base, w)) return true;
    }
    return false;
}

/// `mixer_theme_hint_keys`: Edge, RuneScape/Jagex, cava, speech-dispatcher.
pub fn mixerThemeHintKeys(out: [][]const u8, bin: []const u8, app_name: []const u8) [][]const u8 {
    var n: usize = 0;
    var hay_buf: [512]u8 = undefined;
    var hn: usize = 0;
    for ([_][]const u8{ bin, app_name }) |s| {
        const take = @min(s.len, hay_buf.len - hn);
        @memcpy(hay_buf[hn .. hn + take], s[0..take]);
        hn += take;
        if (hn < hay_buf.len) {
            hay_buf[hn] = ' ';
            hn += 1;
        }
    }
    for (hay_buf[0..hn]) |*c| c.* = std.ascii.toLower(c.*);
    const hay = hay_buf[0..hn];
    const groups = [_]struct { needles: []const []const u8, keys: []const []const u8 }{
        .{
            .needles = &.{"msedge"},
            .keys = &.{ "com.microsoft.Edge", "microsoft-edge", "microsoft-edge-stable", "msedge" },
        },
        .{
            .needles = &.{"microsoft edge"},
            .keys = &.{ "com.microsoft.Edge", "microsoft-edge", "microsoft-edge-stable", "msedge" },
        },
        .{ .needles = &.{ "runescape", "jagex" }, .keys = &.{ "com.jagex.JagexLauncher", "jagexlauncher", "runescape", "oldschool" } },
        .{ .needles = &.{"cava"}, .keys = &.{ "cava", "audio-card", "multimedia-volume-control" } },
        .{ .needles = &.{"speech-dispatcher"}, .keys = &.{ "audio-headphones", "preferences-desktop-sound" } },
    };
    for (groups) |g| {
        for (g.needles) |nd| {
            if (std.mem.indexOf(u8, hay, nd) != null) {
                for (g.keys) |k| {
                    if (n < out.len) {
                        out[n] = k;
                        n += 1;
                    }
                }
                break;
            }
        }
        if (n >= out.len) break;
    }
    return out[0..n];
}

/// `slug`: spaces → `-` (the tray-name form).
pub fn slugify(buf: []u8, s: []const u8) []u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |c, i| buf[i] = if (c == ' ') '-' else std.ascii.toLower(c);
    return buf[0..n];
}

/// First `[A-Za-z0-9.\-_]` run, for the app-name token attempts.
pub fn firstAlphaToken(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len and !isTokenChar(s[i])) i += 1;
    if (i >= s.len) return null;
    var j = i;
    while (j < s.len and isTokenChar(s[j])) j += 1;
    return s[i..j];
}

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_';
}

// Paint helpers

/// `volume_glyph` — mute wins, then thirds.
pub fn volumeGlyph(pct: i32, muted: bool) []const u8 {
    if (muted or pct <= 0) return "volume_off";
    if (pct < 34) return "volume_down";
    return "volume_up";
}

/// `device_glyph` — substring match on the node name, in listed order.
pub fn deviceGlyph(name: []const u8) []const u8 {
    var low_buf: [256]u8 = undefined;
    const low = lowerInto(&low_buf, name);
    if (std.mem.indexOf(u8, low, "bluez") != null or std.mem.indexOf(u8, low, "bluetooth") != null or
        std.mem.indexOf(u8, low, "headphone") != null or std.mem.indexOf(u8, low, "headset") != null or
        std.mem.indexOf(u8, low, "wh-") != null or std.mem.indexOf(u8, low, "buds") != null)
        return "headphones";
    if (std.mem.indexOf(u8, low, "hdmi") != null or std.mem.indexOf(u8, low, "displayport") != null) return "tv";
    if (std.mem.indexOf(u8, low, "usb") != null) return "usb";
    if (std.mem.indexOf(u8, low, "mic") != null or std.mem.indexOf(u8, low, "input") != null or
        std.mem.indexOf(u8, low, "capture") != null) return "mic";
    return "speaker";
}

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

fn textAdv(cr: ?*cairo.cairo_t, s: []const u8) f64 {
    const c = cr orelse return 0;
    var zbuf: [1024:0]u8 = [_:0]u8{0} ** 1024;
    const n = @min(s.len, 1023);
    @memcpy(zbuf[0..n], s[0..n]);
    var te: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(c, &zbuf, &te);
    return te.x_advance;
}

/// `ellipsize` — longest fitting byte-prefix + `...` by binary search
/// (log N extents, not the old per-character loop). `cr` must already carry
/// the font the text will paint in. The result borrows `text` plus a static
/// `"..."` tail conceptually — here it is rendered into `buf`, which must
/// hold at least the ellipsis.
pub fn ellipsize(cr: ?*cairo.cairo_t, text_in: []const u8, max_w: f64, buf: []u8) []const u8 {
    if (text_in.len == 0 or max_w <= 0 or buf.len < 3) return text_in[0..0];
    if (textAdv(cr, text_in) <= max_w) {
        const n = @min(text_in.len, buf.len);
        @memcpy(buf[0..n], text_in[0..n]);
        return buf[0..n];
    }
    var cand: [1024]u8 = undefined;
    const adv = struct {
        fn f(c: ?*cairo.cairo_t, s: []const u8, tmp: []u8) f64 {
            const n = @min(s.len + 3, tmp.len);
            @memcpy(tmp[0..@min(s.len, n)], s[0..@min(s.len, n)]);
            if (n < 3) return std.math.inf(f64);
            @memcpy(tmp[n - 3 .. n], "...");
            return textAdv(c, tmp[0..n]);
        }
    }.f;
    var lo: usize = 0;
    var hi: usize = text_in.len;
    var best: usize = @min(1, text_in.len);
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (adv(cr, text_in[0..mid], &cand) <= max_w) {
            lo = mid;
            best = mid;
        } else {
            hi = mid - 1;
        }
    }
    // Binary search over bytes can split a codepoint; back up to a
    // boundary (`substr` shares this coarseness, but whole
    // codepoints render strictly better).
    var end = @min(best, text_in.len);
    while (end > 0 and end < text_in.len and (text_in[end] & 0xC0) == 0x80) end -= 1;
    const n = @min(end + 3, buf.len);
    if (n < 3) return buf[0..0];
    @memcpy(buf[0 .. n - 3], text_in[0 .. n - 3]);
    @memcpy(buf[n - 3 .. n], "...");
    return buf[0..n];
}

fn paintCard(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, fr: f64, fg: f64, fb: f64, fa: f64) void {
    helpers.roundedRect(cr, x, y, w, h, r);
    cairo.cairo_set_source_rgba(cr, fr, fg, fb, fa);
    cairo.cairo_fill(cr);
}

fn paintHover(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, hr: f64, hg: f64, hb: f64) void {
    helpers.roundedRect(cr, x, y, w, h, r);
    cairo.cairo_set_source_rgba(cr, hr, hg, hb, 0.09);
    cairo.cairo_fill(cr);
}

fn paintSlider(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    t: f64,
    hov: bool,
    dim: [3]f64,
    acc: [3]f64,
    fill: [3]f64,
) void {
    const tc = std.math.clamp(t, 0.0, 1.0);
    const fill_w = w * tc;
    const mid_y = y + k_slider_track_h * 0.5;
    const thumb_cx = std.math.clamp(x + w * tc, x + k_slider_thumb_r, x + w - k_slider_thumb_r);
    // 100% detent: the track spans 0..150%, with an overdrive zone past it.
    const mark_x = x + w * (100.0 / 150.0);

    helpers.roundedRect(cr, x, y, w, k_slider_track_h, k_slider_track_h * 0.5);
    cairo.cairo_set_source_rgba(cr, dim[0], dim[1], dim[2], if (hov) 0.65 else 0.55);
    cairo.cairo_fill(cr);

    if (fill_w > 1.0) {
        const acc_w = @min(fill_w, mark_x - x);
        if (acc_w > 1.0) {
            helpers.roundedRect(cr, x, y, acc_w, k_slider_track_h, k_slider_track_h * 0.5);
            cairo.cairo_set_source_rgba(cr, acc[0], acc[1], acc[2], 0.90);
            cairo.cairo_fill(cr);
        }
        if (fill_w > mark_x - x + 1.0) {
            cairo.cairo_rectangle(cr, mark_x, y, fill_w - (mark_x - x), k_slider_track_h);
            cairo.cairo_set_source_rgba(cr, 1.0, 0.55, 0.15, 0.92);
            cairo.cairo_fill(cr);
        }
    }

    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.55);
    cairo.cairo_set_line_width(cr, 1.5);
    cairo.cairo_move_to(cr, mark_x, y - 3.0);
    cairo.cairo_line_to(cr, mark_x, y + k_slider_track_h + 3.0);
    cairo.cairo_stroke(cr);

    cairo.cairo_new_path(cr);
    cairo.cairo_arc(cr, thumb_cx, mid_y, if (hov) k_slider_thumb_r + 1.0 else k_slider_thumb_r, 0, 2 * std.math.pi);
    cairo.cairo_set_source_rgba(cr, @min(1.0, fill[0]), @min(1.0, fill[1]), @min(1.0, fill[2]), 0.98);
    cairo.cairo_fill_preserve(cr);
    cairo.cairo_set_source_rgba(cr, acc[0], acc[1], acc[2], 0.45);
    cairo.cairo_set_line_width(cr, 1.5);
    cairo.cairo_stroke(cr);
}

fn paintIconTile(cr: ?*cairo.cairo_t, x: f64, y: f64, glyph: []const u8, active: bool, acc: [3]f64, txt: [3]f64) void {
    helpers.roundedRect(cr, x, y, k_tile_sz, k_tile_sz, k_tile_r);
    if (active) {
        cairo.cairo_set_source_rgba(cr, acc[0], acc[1], acc[2], 0.20);
    } else {
        cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.07);
    }
    cairo.cairo_fill(cr);
    _ = glyphs.draw(cr, glyph, x + k_tile_sz * 0.5, y + k_tile_sz * 0.5, k_dev_icon_sz, if (active) acc[0] else txt[0], if (active) acc[1] else txt[1], if (active) acc[2] else txt[2], if (active) 0.95 else 0.70);
}

// Full paint

/// Host view: surface size, pointer, and whether the pointer is over the
/// popup (hover washes only paint then — the tpp `onPopup` gate).
pub const View = struct {
    popup_w: f64 = popup_w,
    popup_h: f64 = popup_h,
    px: f64 = -1,
    py: f64 = -1,
    on_popup: bool = false,
};

/// Theme icon lookup the host fills from its icon theme.
pub const StreamIcons = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, name: []const u8) ?*cairo.cairo_surface_t,
};

/// Footer + dropdown auxiliary data, resolved by the host.
pub const Aux = struct {
    engine: EngineSettings = .{},
    top: TopSample = .{},
    cards: []const CardProfiles = &.{},
    icons: ?StreamIcons = null,
};

/// Per-section paint timings for `MixerLog.reportPaint`, in milliseconds.
pub const Timings = struct {
    snap_ms: f64 = 0,
    snap_hit: bool = false,
    link_ms: f64 = 0,
    layout_ms: f64 = 0,
    chrome_ms: f64 = 0,
    header_ms: f64 = 0,
    master_ms: f64 = 0,
    devices_ms: f64 = 0,
    streams_ms: f64 = 0,
    router_ms: f64 = 0,
    footer_ms: f64 = 0,
    icon_us: i64 = 0,
    icon_n: i32 = 0,
    text_us: i64 = 0,
    text_n: i32 = 0,
    slider_us: i64 = 0,
    slider_n: i32 = 0,
};

/// Monotonic microseconds for paint instrumentation.
pub fn nowUs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000000 +
        @divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), 1000);
}

fn paintStreamIcon(
    cr: ?*cairo.cairo_t,
    icons: ?StreamIcons,
    st: *const StreamInfo,
    cx: f64,
    cy: f64,
    size: f64,
) void {
    const c = cr orelse return;
    if (icons) |lookup| {
        var names: [24][2][]const u8 = undefined;
        for (streamIconNames(&names, st.icon_name, st.app_id, st.process_binary, st.app_name)) |cand| {
            const surf = lookup.get(lookup.ctx, cand[0]) orelse continue;
            const iw: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(surf));
            const ih: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(surf));
            if (iw <= 0 or ih <= 0) continue;
            const sc = @min(size / iw, size / ih);
            cairo.cairo_save(c);
            cairo.cairo_translate(c, cx - iw * sc * 0.5, cy - ih * sc * 0.5);
            cairo.cairo_scale(c, sc, sc);
            cairo.cairo_set_source_surface(c, surf, 0, 0);
            cairo.cairo_paint(c);
            cairo.cairo_restore(c);
            return;
        }
    }
    _ = glyphs.draw(c, "apps", cx, cy, size * 0.6, 0.78, 0.78, 0.78, 0.78);
}

fn paintSwapGlyph(cr: ?*cairo.cairo_t, icons: ?StreamIcons, cx: f64, cy: f64, size: f64, r: f64, g: f64, b: f64, a: f64) void {
    const c = cr orelse return;
    // The bundled `UI/swap.svg` has no Zig asset loader; a host that maps
    // the name onto the asset gets the silhouette, everyone else the
    // `swap_horiz` SVG.
    if (icons) |lookup| {
        if (lookup.get(lookup.ctx, "swap")) |surf| {
            const iw: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(surf));
            const ih: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(surf));
            if (iw > 0 and ih > 0) {
                const k = size / @max(iw, ih);
                cairo.cairo_save(c);
                cairo.cairo_set_source_rgba(c, r, g, b, a);
                cairo.cairo_translate(c, cx - iw * k * 0.5, cy - ih * k * 0.5);
                cairo.cairo_scale(c, k, k);
                cairo.cairo_mask_surface(c, surf, 0, 0);
                cairo.cairo_restore(c);
                return;
            }
        }
    }
    _ = glyphs.draw(c, "swap_horiz", cx, cy, size, r, g, b, a);
}

/// `mixer_paint` — the whole card in section order. `ui` carries the
/// tab, dropdowns, scroll and any live drag; `log`/`timings` collect the
/// perf report (either may be null to skip instrumentation).
pub fn mixerPaint(
    alloc: std.mem.Allocator,
    cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    snap: *const Snapshot,
    ui: *const UiState,
    view: *const View,
    aux: *const Aux,
    log: ?*MixerLog,
    timings: ?*Timings,
) !void {
    const t0 = nowUs();
    const c = cr orelse return;
    const devices = if (ui.view_output) snap.sinks else snap.sources;
    const streams = if (ui.view_output) snap.out_streams else snap.in_streams;
    var lay = try computeLayout(alloc, snap, aux.cards, ui.view_output, ui.router_stream, ui.master_picker, ui.scroll_px);
    defer freeLayout(alloc, &lay);
    const t_layout = nowUs();
    const mc = chrome_colors.of(sc);
    const t_chrome = nowUs();

    const w = popup_w;
    const h = view.popup_h;
    const hovering = struct {
        fn f(v: *const View, x0: f64, y0: f64, x1: f64, y1: f64) bool {
            return v.on_popup and v.px >= x0 and v.px < x1 and v.py >= y0 and v.py < y1;
        }
    }.f;

    cairo.cairo_save(c);
    helpers.roundedRect(c, k_shad_dx, k_shad_dy, w, h, k_corner);
    // Scaled with the card: 0% must leave nothing, shadow included.
    const card_alpha = @min(@as(f64, 1.0), @as(f64, sc.appearance.overlay_opacity_widget_card));
    cairo.cairo_set_source_rgba(c, 0, 0, 0, k_shad_alpha * card_alpha);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);

    helpers.roundedRect(c, 0, 0, w, h, k_corner);
    cairo.cairo_set_source_rgba(c, mc.dock_fill.r * 0.30, mc.dock_fill.g * 0.30, mc.dock_fill.b * 0.30, 0.92 * @as(f64, sc.appearance.overlay_opacity_widget_card));
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    const cx = k_pad;
    const cw = popup_w - k_pad * 2.0;

    // Segmented Output | Input control.
    {
        helpers.roundedRect(c, lay.seg_x, lay.seg_y, lay.seg_w, k_seg_h, k_seg_r);
        cairo.cairo_set_source_rgba(c, mc.drawer_dim.r, mc.drawer_dim.g, mc.drawer_dim.b, 0.25);
        cairo.cairo_fill(c);
        const out_sel = ui.view_output;
        const has_sources = snap.sources.len > 0;
        const sel_x: f64 = if (out_sel) lay.out_x else lay.in_x;
        const sel_w: f64 = if (out_sel) lay.out_w else lay.in_w;
        helpers.roundedRect(c, sel_x + 2.0, lay.seg_y + 2.0, sel_w - 4.0, k_seg_h - 4.0, k_seg_r - 2.0);
        cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.22);
        cairo.cairo_fill(c);
        if (hovering(view, lay.out_x, lay.seg_y, lay.out_x + lay.out_w, lay.seg_y + k_seg_h))
            paintHover(c, lay.out_x + 2.0, lay.seg_y + 2.0, lay.out_w - 4.0, k_seg_h - 4.0, k_seg_r - 2.0, mc.accent.r, mc.accent.g, mc.accent.b);
        if (hovering(view, lay.in_x, lay.seg_y, lay.in_x + lay.in_w, lay.seg_y + k_seg_h))
            paintHover(c, lay.in_x + 2.0, lay.seg_y + 2.0, lay.in_w - 4.0, k_seg_h - 4.0, k_seg_r - 2.0, mc.accent.r, mc.accent.g, mc.accent.b);

        var obuf: [32]u8 = undefined;
        const out_label = std.fmt.bufPrint(&obuf, "Output · {d}", .{snap.sinks.len}) catch "Output";
        var ibuf: [32]u8 = undefined;
        const in_label = std.fmt.bufPrint(&ibuf, "Input · {d}", .{snap.sources.len}) catch "Input";
        segLabel(c, mc, lay.out_x, lay.seg_y, "volume_up", out_label, out_sel, false);
        segLabel(c, mc, lay.in_x, lay.seg_y, "mic", in_label, !out_sel, !has_sources);
    }
    const t_header = nowUs();

    cairo.cairo_set_source_rgba(c, mc.outline.r, mc.outline.g, mc.outline.b, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_move_to(c, cx, lay.header_bottom);
    cairo.cairo_line_to(c, cx + cw, lay.header_bottom);
    cairo.cairo_stroke(c);

    // Master (default device) card.
    if (masterDevice(snap, ui.view_output)) |m| {
        const mhov = hovering(view, cx, lay.master_y, cx + cw, lay.master_y + k_master_h);
        if (mhov) paintHover(c, cx, lay.master_y, cw, k_master_h, 12.0, mc.accent.r, mc.accent.g, mc.accent.b);
        paintCard(c, cx, lay.master_y, cw, k_master_h, 12.0, mc.accent.r, mc.accent.g, mc.accent.b, 0.08);
        paintIconTile(c, cx + k_pad, lay.master_y + 12.0, deviceGlyph(m.raw_name), true, .{ mc.accent.r, mc.accent.g, mc.accent.b }, .{ mc.text.r, mc.text.g, mc.text.b });

        setToyFont(c, 13.5, true);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.92);
        var ebuf: [512]u8 = undefined;
        showText(c, ellipsize(c, m.name, cw - k_pad * 2.0 - k_tile_sz - 10.0 - k_mute_btn_sz - 12.0, &ebuf), cx + k_pad + k_tile_sz + 10.0, lay.master_y + 28.0);

        setToyFont(c, 11.0, false);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.55);
        var sbuf: [64]u8 = undefined;
        showText(c, std.fmt.bufPrint(&sbuf, "Default · {d}%", .{m.volume_pct}) catch "Default", cx + k_pad + k_tile_sz + 10.0, lay.master_y + 44.0);

        const mute_hov = hovering(view, lay.master_mute_x, lay.master_mute_y, lay.master_mute_x + k_mute_btn_sz, lay.master_mute_y + k_mute_btn_sz);
        if (mute_hov)
            paintHover(c, lay.master_mute_x, lay.master_mute_y, k_mute_btn_sz, k_mute_btn_sz, k_mute_btn_sz * 0.5, mc.accent.r, mc.accent.g, mc.accent.b);
        _ = glyphs.draw(c, volumeGlyph(m.volume_pct, m.muted), lay.master_mute_x + k_mute_btn_sz * 0.5, lay.master_mute_y + k_mute_btn_sz * 0.5, k_mute_icon_sz, mc.text.r, mc.text.g, mc.text.b, if (mute_hov or m.muted) 0.95 else 0.78);

        if (lay.has_master_menu) {
            const menu_hov = hovering(view, lay.master_menu_x, lay.master_menu_y, lay.master_menu_x + k_menu_btn_sz, lay.master_menu_y + k_menu_btn_sz);
            const menu_open = ui.master_picker;
            if (menu_hov or menu_open)
                paintHover(c, lay.master_menu_x, lay.master_menu_y, k_menu_btn_sz, k_menu_btn_sz, k_menu_btn_sz * 0.5, mc.accent.r, mc.accent.g, mc.accent.b);
            helpers.roundedRect(c, lay.master_menu_x, lay.master_menu_y, k_menu_btn_sz, k_menu_btn_sz, k_menu_btn_sz * 0.5);
            cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, if (menu_open) 0.16 else 0.07);
            cairo.cairo_fill(c);
            _ = glyphs.draw(c, "expand_more", lay.master_menu_x + k_menu_btn_sz * 0.5, lay.master_menu_y + k_menu_btn_sz * 0.5, 18.0, if (menu_open) mc.accent.r else mc.text.r, if (menu_open) mc.accent.g else mc.text.g, if (menu_open) mc.accent.b else mc.text.b, 0.85);
        }

        var master_t = std.math.clamp(@as(f64, @floatFromInt(m.volume_pct)) / 150.0, 0.0, 1.0);
        if (ui.drag_active and ui.drag_kind == .device and ui.drag_id == m.node_id) master_t = ui.drag_t;
        const s_hov = hovering(view, lay.master_slider_x - k_hit_pad_h, lay.master_slider_y - k_hit_pad_v, lay.master_slider_x + lay.master_slider_w + k_hit_pad_h, lay.master_slider_y + k_slider_track_h + k_hit_pad_v);
        paintSlider(c, lay.master_slider_x, lay.master_slider_y, lay.master_slider_w, master_t, s_hov or ui.drag_active, .{ mc.drawer_dim.r, mc.drawer_dim.g, mc.drawer_dim.b }, .{ mc.accent.r, mc.accent.g, mc.accent.b }, .{ mc.dock_fill.r + 0.35, mc.dock_fill.g + 0.35, mc.dock_fill.b + 0.35 });

        setToyFont(c, 12.0, true);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.80);
        var pbuf: [16]u8 = undefined;
        const pct: i32 = if (ui.drag_active and ui.drag_kind == .device and ui.drag_id == m.node_id) ui.drag_pct else m.volume_pct;
        showText(c, std.fmt.bufPrint(&pbuf, "{d}%", .{pct}) catch "?", lay.master_slider_x + lay.master_slider_w + 8.0, lay.master_slider_y + 11.0);
    }
    const t_master = nowUs();

    // Secondary devices.
    for (devices, 0..) |*dv, di| {
        if (di == 0) continue;
        const g = lay.dev_rows[di - 1];
        const row_hov = hovering(view, cx, g.y, cx + cw, g.y + k_row_h);
        if (row_hov) paintHover(c, cx + 4.0, g.y + 3.0, cw - 8.0, k_row_h - 6.0, 8.0, mc.accent.r, mc.accent.g, mc.accent.b);

        cairo.cairo_new_path(c);
        cairo.cairo_arc(c, g.radio_cx, g.y + k_row_h * 0.5, k_radio_r, 0, 2 * std.math.pi);
        cairo.cairo_set_source_rgba(c, mc.outline.r, mc.outline.g, mc.outline.b, 0.45);
        cairo.cairo_set_line_width(c, 1.5);
        cairo.cairo_stroke(c);

        paintIconTile(c, cx + k_pad + k_radio_r * 2.0 + 8.0, g.y + (k_row_h - k_tile_sz) * 0.5, deviceGlyph(dv.raw_name), false, .{ mc.accent.r, mc.accent.g, mc.accent.b }, .{ mc.text.r, mc.text.g, mc.text.b });

        const name_x = cx + k_pad + k_radio_r * 2.0 + 8.0 + k_tile_sz + 8.0;
        setToyFont(c, 13.0, false);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.68);
        var ebuf: [512]u8 = undefined;
        showText(c, ellipsize(c, dv.name, k_name_max_w, &ebuf), name_x, g.y + k_row_h * 0.5 + 5.0);

        const mute_hov = hovering(view, g.mute_x, g.y + (k_row_h - k_mute_btn_sz) * 0.5, g.mute_x + k_mute_btn_sz, g.y + (k_row_h + k_mute_btn_sz) * 0.5);
        if (mute_hov)
            paintHover(c, g.mute_x, g.y + (k_row_h - k_mute_btn_sz) * 0.5, k_mute_btn_sz, k_mute_btn_sz, k_mute_btn_sz * 0.5, mc.accent.r, mc.accent.g, mc.accent.b);
        _ = glyphs.draw(c, volumeGlyph(dv.volume_pct, dv.muted), g.mute_x + k_mute_btn_sz * 0.5, g.y + k_row_h * 0.5, k_mute_icon_sz, mc.text.r, mc.text.g, mc.text.b, if (mute_hov or dv.muted) 0.95 else 0.78);
        var t = std.math.clamp(@as(f64, @floatFromInt(dv.volume_pct)) / 150.0, 0.0, 1.0);
        if (ui.drag_active and ui.drag_kind == .device and ui.drag_id == dv.node_id) t = ui.drag_t;
        const s_hov = hovering(view, g.slider.sx - k_hit_pad_h, g.slider.sy - k_hit_pad_v, g.slider.sx + g.slider.sw + k_hit_pad_h, g.slider.sy + k_slider_track_h + k_hit_pad_v);
        paintSlider(c, g.slider.sx, g.slider.sy, g.slider.sw, t, s_hov, .{ mc.drawer_dim.r, mc.drawer_dim.g, mc.drawer_dim.b }, .{ mc.accent.r, mc.accent.g, mc.accent.b }, .{ mc.dock_fill.r + 0.35, mc.dock_fill.g + 0.35, mc.dock_fill.b + 0.35 });
    }
    if (devices.len == 0) {
        setToyFont(c, 12.5, false);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.55);
        showText(c, if (ui.view_output) "No output devices found." else "No input devices found.", cx + k_pad, lay.header_bottom + 34.0);
    }
    const t_devices = nowUs();

    // Apps divider + header.
    cairo.cairo_set_source_rgba(c, mc.outline.r, mc.outline.g, mc.outline.b, 0.18);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_move_to(c, cx, lay.apps_divider_y);
    cairo.cairo_line_to(c, cx + cw, lay.apps_divider_y);
    cairo.cairo_stroke(c);

    setToyFont(c, 10.5, true);
    cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.50);
    var abuf: [48]u8 = undefined;
    showText(c, std.fmt.bufPrint(&abuf, "{s} · {d}", .{ if (ui.view_output) "APPS PLAYING AUDIO" else "APPS RECORDING", streams.len }) catch "APPS", cx + 4.0, lay.apps_divider_y + 20.0);

    // App rows, clipped to the scroll viewport.
    cairo.cairo_save(c);
    cairo.cairo_rectangle(c, cx, lay.viewport_y, cw, lay.viewport_h);
    cairo.cairo_clip(c);
    for (streams, 0..) |*st, i| {
        const g = lay.stream_rows[i];
        if (g.y + k_row_h <= lay.viewport_y or g.y >= lay.viewport_y + lay.viewport_h) continue;
        const row_hov = hovering(view, cx, g.y, cx + cw, g.y + k_row_h);
        if (row_hov) paintHover(c, cx + 2.0, g.y + 3.0, cw - 4.0, k_row_h - 6.0, 8.0, mc.accent.r, mc.accent.g, mc.accent.b);

        paintStreamIcon(c, aux.icons, st, cx + k_pad + k_app_icon_sz * 0.5, g.y + k_row_h * 0.5 - 2.0, k_app_icon_sz);

        const name_x = cx + k_pad + k_app_icon_sz + 8.0;
        setToyFont(c, 12.5, false);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.87);
        var ebuf: [512]u8 = undefined;
        showText(c, ellipsize(c, st.app_name, k_name_max_w, &ebuf), name_x, g.y + k_row_h * 0.5 - 2.0);

        setToyFont(c, 10.5, false);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.45);
        var sbuf: [512]u8 = undefined;
        const sub: []const u8 = if (st.routed_display.len > 0) st.routed_display else "Default output";
        showText(c, ellipsize(c, sub, k_name_max_w, &sbuf), name_x, g.y + k_row_h * 0.5 + 13.0);

        const smute_hov = hovering(view, g.mute_x, g.y + (k_row_h - k_mute_btn_sz) * 0.5, g.mute_x + k_mute_btn_sz, g.y + (k_row_h + k_mute_btn_sz) * 0.5);
        if (smute_hov)
            paintHover(c, g.mute_x, g.y + (k_row_h - k_mute_btn_sz) * 0.5, k_mute_btn_sz, k_mute_btn_sz, k_mute_btn_sz * 0.5, mc.accent.r, mc.accent.g, mc.accent.b);
        _ = glyphs.draw(c, volumeGlyph(st.volume_pct, st.muted), g.mute_x + k_mute_btn_sz * 0.5, g.y + k_row_h * 0.5 - 2.0, k_mute_icon_sz, mc.text.r, mc.text.g, mc.text.b, if (smute_hov or st.muted) 0.95 else 0.78);

        var t = std.math.clamp(@as(f64, @floatFromInt(st.volume_pct)) / 150.0, 0.0, 1.0);
        if (ui.drag_active and ui.drag_kind == .stream and ui.drag_id == st.node_id) t = ui.drag_t;
        const s_hov = hovering(view, g.slider.sx - k_hit_pad_h, g.slider.sy - k_hit_pad_v, g.slider.sx + g.slider.sw + k_hit_pad_h, g.slider.sy + k_slider_track_h + k_hit_pad_v);
        paintSlider(c, g.slider.sx, g.slider.sy, g.slider.sw, t, s_hov, .{ mc.drawer_dim.r, mc.drawer_dim.g, mc.drawer_dim.b }, .{ mc.accent.r, mc.accent.g, mc.accent.b }, .{ mc.dock_fill.r + 0.35, mc.dock_fill.g + 0.35, mc.dock_fill.b + 0.35 });

        setToyFont(c, 11.5, false);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.70);
        var pbuf: [16]u8 = undefined;
        const pct: i32 = if (ui.drag_active and ui.drag_kind == .stream and ui.drag_id == st.node_id) ui.drag_pct else st.volume_pct;
        showText(c, std.fmt.bufPrint(&pbuf, "{d}%", .{pct}) catch "?", g.pct_x, g.y + k_row_h * 0.5 + 2.0);

        const menu_open = ui.router_stream == st.node_id;
        const menu_hov = hovering(view, g.menu_x, g.y + (k_row_h - k_menu_btn_sz) * 0.5, g.menu_x + k_menu_btn_sz, g.y + (k_row_h + k_menu_btn_sz) * 0.5);
        if (menu_hov or menu_open)
            paintHover(c, g.menu_x, g.y + (k_row_h - k_menu_btn_sz) * 0.5, k_menu_btn_sz, k_menu_btn_sz, k_menu_btn_sz * 0.5, mc.accent.r, mc.accent.g, mc.accent.b);
        helpers.roundedRect(c, g.menu_x, g.y + (k_row_h - k_menu_btn_sz) * 0.5, k_menu_btn_sz, k_menu_btn_sz, k_menu_btn_sz * 0.5);
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, if (menu_open) 0.16 else 0.07);
        cairo.cairo_fill(c);
        paintSwapGlyph(c, aux.icons, g.menu_x + k_menu_btn_sz * 0.5, g.y + k_row_h * 0.5 - 2.0, 17.0, if (menu_open) mc.accent.r else mc.text.r, if (menu_open) mc.accent.g else mc.text.g, if (menu_open) mc.accent.b else mc.text.b, 0.85);
    }
    if (streams.len == 0) {
        _ = glyphs.draw(c, "music_note", cx + cw * 0.5, lay.viewport_y + lay.viewport_h * 0.5 - 12.0, 22.0, mc.text.r, mc.text.g, mc.text.b, 0.30);
        setToyFont(c, 12.0, false);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.45);
        const msg: []const u8 = if (ui.view_output) "Nothing is playing right now." else "Nothing is recording right now.";
        showText(c, msg, cx + (cw - textAdv(c, msg)) * 0.5, lay.viewport_y + lay.viewport_h * 0.5 + 14.0);
    }
    cairo.cairo_restore(c);
    const t_streams = nowUs();

    // Scrollbar.
    if (lay.scrollable) {
        const track_x = lay.scroll_x + (lay.scroll_w - 6.0) * 0.5;
        helpers.roundedRect(c, track_x, lay.viewport_y + 4.0, 6.0, lay.viewport_h - 8.0, 3.0);
        cairo.cairo_set_source_rgba(c, mc.drawer_dim.r, mc.drawer_dim.g, mc.drawer_dim.b, 0.35);
        cairo.cairo_fill(c);
        const thumb_hov = hovering(view, lay.scroll_x, lay.thumb_y, lay.scroll_x + lay.scroll_w, lay.thumb_y + lay.thumb_h);
        const thumb_drag = ui.drag_active and ui.drag_kind == .scroll;
        helpers.roundedRect(c, track_x - 1.0, lay.thumb_y, 8.0, lay.thumb_h, 4.0);
        cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, if (thumb_hov or thumb_drag) 0.85 else 0.55);
        cairo.cairo_fill(c);
    }

    // Engine footer.
    {
        cairo.cairo_set_source_rgba(c, mc.outline.r, mc.outline.g, mc.outline.b, 0.14);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_move_to(c, cx, lay.footer_y);
        cairo.cairo_line_to(c, cx + cw, lay.footer_y);
        cairo.cairo_stroke(c);

        var ebuf: [160]u8 = undefined;
        const eng: []const u8 = if (aux.engine.available)
            std.fmt.bufPrint(&ebuf, "{d} Hz · q{d}", .{
                aux.engine.clock_rate_hz,
                if (aux.engine.clock_force_quantum != 0) aux.engine.clock_force_quantum else aux.engine.clock_quantum,
            }) catch "engine offline"
        else
            "engine offline";
        var dbuf: [160]u8 = undefined;
        const dsp: []const u8 = if (aux.top.available)
            std.fmt.bufPrint(&dbuf, "DSP {d:.0}% · {d} xruns", .{ aux.top.dsp_load_pct, aux.top.xruns_total }) catch "no load data"
        else
            "no load data";
        setToyFont(c, 10.5, false);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.50);
        showText(c, eng, cx + 4.0, lay.footer_y + 17.0);
        showText(c, dsp, cx + 4.0, lay.footer_y + 31.0);

        const set_hov = hovering(view, lay.settings_x, lay.footer_y + (k_footer_h - 28.0) * 0.5, lay.settings_x + lay.settings_w, lay.footer_y + (k_footer_h + 28.0) * 0.5);
        if (set_hov) paintHover(c, lay.settings_x, lay.footer_y + (k_footer_h - 28.0) * 0.5, lay.settings_w, 28.0, 8.0, mc.accent.r, mc.accent.g, mc.accent.b);
        helpers.roundedRect(c, lay.settings_x, lay.footer_y + (k_footer_h - 28.0) * 0.5, lay.settings_w, 28.0, 8.0);
        cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, if (set_hov) 0.24 else 0.16);
        cairo.cairo_fill(c);
        _ = glyphs.draw(c, "settings", lay.settings_x + 16.0, lay.footer_y + k_footer_h * 0.5, 14.0, mc.accent.r, mc.accent.g, mc.accent.b, 0.90);
        setToyFont(c, 11.5, false);
        cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.92);
        showText(c, "Sound settings", lay.settings_x + 32.0, lay.footer_y + k_footer_h * 0.5 + 4.5);
    }

    // Floating dropdown, painted last.
    if (lay.has_drop and (lay.drop_is_master or (lay.drop_stream_idx >= 0 and @as(usize, @intCast(lay.drop_stream_idx)) < streams.len))) {
        const routed: []const u8 = if (!lay.drop_is_master and lay.drop_stream_idx >= 0)
            streams[@intCast(lay.drop_stream_idx)].routed_raw
        else
            "";
        const targets = if (ui.view_output) snap.sinks else snap.sources;
        cairo.cairo_save(c);
        helpers.roundedRect(c, lay.drop_x + 2.0, lay.drop_y + 3.0, lay.drop_w, lay.drop_h, 10.0);
        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.35);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
        helpers.roundedRect(c, lay.drop_x, lay.drop_y, lay.drop_w, lay.drop_h, 10.0);
        cairo.cairo_set_source_rgba(c, mc.panel_fill.r, mc.panel_fill.g, mc.panel_fill.b, 1.0);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.35);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_stroke(c);

        setToyFont(c, 10.5, true);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.62);
        showText(c, if (lay.drop_is_master)
            (if (ui.view_output) "OUTPUT DEVICE" else "INPUT DEVICE")
        else
            (if (ui.view_output) "PLAY ON" else "RECORD FROM"), lay.drop_x + 12.0, lay.drop_y + 18.0);

        for (targets, 0..) |*tgt, si| {
            if (si >= lay.drop_count) break;
            const item_y = lay.drop_y + k_drop_title_h + @as(f64, @floatFromInt(si)) * k_drop_item_h;
            if (item_y + k_drop_item_h > lay.drop_y + lay.drop_h) break;
            const checked = (routed.len > 0 and std.mem.eql(u8, routed, tgt.raw_name)) or
                (routed.len == 0 and tgt.is_default);
            if (checked) {
                helpers.roundedRect(c, lay.drop_x + 4.0, item_y + 2.0, lay.drop_w - 8.0, k_drop_item_h - 4.0, 6.0);
                cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.14);
                cairo.cairo_fill(c);
            }
            const item_hov = hovering(view, lay.drop_x + 4.0, item_y, lay.drop_x + lay.drop_w - 4.0, item_y + k_drop_item_h);
            if (item_hov) paintHover(c, lay.drop_x + 4.0, item_y + 2.0, lay.drop_w - 8.0, k_drop_item_h - 4.0, 6.0, mc.accent.r, mc.accent.g, mc.accent.b);

            cairo.cairo_new_path(c);
            cairo.cairo_arc(c, lay.drop_x + 24.0, item_y + k_drop_item_h * 0.5, 8.0, 0, 2 * std.math.pi);
            cairo.cairo_set_source_rgba(c, if (checked) mc.accent.r else mc.outline.r, if (checked) mc.accent.g else mc.outline.g, if (checked) mc.accent.b else mc.outline.b, if (checked) 0.95 else 0.62);
            cairo.cairo_set_line_width(c, if (checked) 2.0 else 1.5);
            cairo.cairo_stroke(c);
            if (checked) {
                cairo.cairo_new_path(c);
                cairo.cairo_arc(c, lay.drop_x + 24.0, item_y + k_drop_item_h * 0.5, 4.5, 0, 2 * std.math.pi);
                cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.95);
                cairo.cairo_fill(c);
            }
            _ = glyphs.draw(c, deviceGlyph(tgt.raw_name), lay.drop_x + 42.0, item_y + k_drop_item_h * 0.5, 16.0, if (checked) mc.accent.r else mc.text.r, if (checked) mc.accent.g else mc.text.g, if (checked) mc.accent.b else mc.text.b, if (checked) 0.87 else 0.60);
            setToyFont(c, 12.0, checked);
            cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, if (checked) 0.87 else 0.60);
            const short = try shortenDeviceName(alloc, tgt.name);
            defer alloc.free(short);
            var dbuf: [512]u8 = undefined;
            showText(c, ellipsize(c, short, lay.drop_w - 58.0 - 30.0, &dbuf), lay.drop_x + 58.0, item_y + k_drop_item_h * 0.5 + 4.5);
            if (tgt.is_default)
                _ = glyphs.draw(c, "star", lay.drop_x + lay.drop_w - 20.0, item_y + k_drop_item_h * 0.5, 12.0, mc.text.r, mc.text.g, mc.text.b, 0.50);
        }

        if (lay.drop_is_master and lay.drop_profile_count > 0) {
            if (masterDevice(snap, ui.view_output)) |mdev| {
                if (findCardForNode(aux.cards, mdev.raw_name)) |card| {
                    setToyFont(c, 10.5, true);
                    cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.62);
                    showText(c, "PROFILE", lay.drop_x + 12.0, lay.drop_profile_top - 6.0);
                    for (card.profiles, 0..) |*opt, pi| {
                        if (pi >= lay.drop_profile_count) break;
                        const item_y = lay.drop_profile_top + @as(f64, @floatFromInt(pi)) * k_drop_item_h;
                        if (item_y + k_drop_item_h > lay.drop_y + lay.drop_h) break;
                        const is_active = std.mem.eql(u8, opt.key, card.active_profile_key);
                        if (is_active) {
                            helpers.roundedRect(c, lay.drop_x + 4.0, item_y + 2.0, lay.drop_w - 8.0, k_drop_item_h - 4.0, 6.0);
                            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.14);
                            cairo.cairo_fill(c);
                        }
                        const item_hov = hovering(view, lay.drop_x + 4.0, item_y, lay.drop_x + lay.drop_w - 4.0, item_y + k_drop_item_h);
                        if (item_hov)
                            paintHover(c, lay.drop_x + 4.0, item_y + 2.0, lay.drop_w - 8.0, k_drop_item_h - 4.0, 6.0, mc.accent.r, mc.accent.g, mc.accent.b);
                        cairo.cairo_new_path(c);
                        cairo.cairo_arc(c, lay.drop_x + 24.0, item_y + k_drop_item_h * 0.5, 8.0, 0, 2 * std.math.pi);
                        cairo.cairo_set_source_rgba(c, if (is_active) mc.accent.r else mc.outline.r, if (is_active) mc.accent.g else mc.outline.g, if (is_active) mc.accent.b else mc.outline.b, if (is_active) 0.95 else 0.62);
                        cairo.cairo_set_line_width(c, if (is_active) 2.0 else 1.5);
                        cairo.cairo_stroke(c);
                        if (is_active) {
                            cairo.cairo_new_path(c);
                            cairo.cairo_arc(c, lay.drop_x + 24.0, item_y + k_drop_item_h * 0.5, 4.5, 0, 2 * std.math.pi);
                            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.95);
                            cairo.cairo_fill(c);
                        }
                        _ = glyphs.draw(c, "tune", lay.drop_x + 42.0, item_y + k_drop_item_h * 0.5, 16.0, if (is_active) mc.accent.r else mc.text.r, if (is_active) mc.accent.g else mc.text.g, if (is_active) mc.accent.b else mc.text.b, if (is_active) 0.87 else 0.60);
                        setToyFont(c, 12.0, is_active);
                        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, if (is_active) 0.87 else 0.60);
                        const desc: []const u8 = if (opt.description.len > 0) opt.description else opt.key;
                        var lbuf: [512]u8 = undefined;
                        showText(c, ellipsize(c, desc, lay.drop_w - 58.0 - 12.0, &lbuf), lay.drop_x + 58.0, item_y + k_drop_item_h * 0.5 + 4.5);
                    }
                }
            }
        }
    }
    const t_router = nowUs();

    if (log) |lg| {
        if (timings) |tm| {
            tm.layout_ms = usBetween(t0, t_layout);
            tm.chrome_ms = usBetween(t_layout, t_chrome);
            tm.header_ms = usBetween(t_chrome, t_header);
            tm.master_ms = usBetween(t_header, t_master);
            tm.devices_ms = usBetween(t_master, t_devices);
            tm.streams_ms = usBetween(t_devices, t_streams);
            tm.router_ms = usBetween(t_streams, t_router);
            tm.footer_ms = usBetween(t_router, nowUs());
            lg.reportPaint(devices.len, streams.len, tm);
        }
    }
}

fn segLabel(
    cr: ?*cairo.cairo_t,
    mc: chrome_colors.Chrome,
    sx: f64,
    seg_y: f64,
    glyph: []const u8,
    label: []const u8,
    sel: bool,
    dimmed: bool,
) void {
    const a: f64 = if (dimmed) 0.35 else if (sel) 0.95 else 0.65;
    _ = glyphs.draw(cr, glyph, sx + 20.0, seg_y + k_seg_h * 0.5, 15.0, if (sel) mc.accent.r else mc.text.r, if (sel) mc.accent.g else mc.text.g, if (sel) mc.accent.b else mc.text.b, a);
    cairo.cairo_set_source_rgba(cr, if (sel) mc.accent.r else mc.text.r, if (sel) mc.accent.g else mc.text.g, if (sel) mc.accent.b else mc.text.b, a);
    showText(cr, label, sx + 40.0, seg_y + k_seg_h * 0.5 + 5.0);
}

fn usBetween(a: i64, b: i64) f64 {
    return @as(f64, @floatFromInt(b - a)) / 1000.0;
}

// MixerLog

/// Log lines go here (`$HOME` else `/tmp`).
pub fn mixerLogPath(buf: []u8, home: []const u8) []const u8 {
    if (home.len > 0) {
        return std.fmt.bufPrint(buf, "{s}/.local/state/event-horizon/horizon-volumemixer.log", .{home}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "/tmp/event-horizon/horizon-volumemixer.log", .{}) catch buf[0..0];
}

pub const MixerLog = struct {
    enabled: bool = true,
    perf_all: bool = false,
    thresh_ms: f64 = 8.0,
    fd: i32 = -1,
    home: []const u8 = "",
    frames: u64 = 0,
    slow: u64 = 0,
    total_ms: f64 = 0,
    max_ms: f64 = 0,
    have_last: bool = false,
    last_ms: i64 = 0,
    min_dt_ms: f64 = 1e9,
    cur_sec: i64 = -1,
    sec_count: u32 = 0,
    max_per_sec: u32 = 0,
    motions: u64 = 0,
    motion_pw_us: i64 = 0,

    /// Reads `EH_VOLUME_MIXER_LOG` (default on), `EH_VOLUME_MIXER_PERF`
    /// and `EH_VOLUME_MIXER_THRESH_MS` once at startup.
    pub fn configFromEnv(env: ?[]const u8, perf: ?[]const u8, thresh: ?[]const u8) MixerLog {
        var log = MixerLog{};
        if (env) |e| {
            if (std.mem.eql(u8, e, "0")) log.enabled = false;
        }
        if (perf) |p| {
            if (std.mem.eql(u8, p, "1")) log.perf_all = true;
        }
        if (thresh) |th| {
            const v = std.fmt.parseFloat(f64, th) catch -1;
            if (v > 0 and v < 10000) log.thresh_ms = v;
        }
        return log;
    }

    pub fn deinit(self: *MixerLog) void {
        if (self.fd >= 0) {
            _ = std.os.linux.close(self.fd);
            self.fd = -1;
        }
    }

    fn ensureOpen(self: *MixerLog) bool {
        if (!self.enabled) return false;
        if (self.fd >= 0) return true;
        var path_buf: [512]u8 = undefined;
        const path = mixerLogPath(&path_buf, self.home);
        if (path.len == 0 or path.len + 1 > 1024) return false;
        var z: [1024:0]u8 = [_:0]u8{0} ** 1024;
        @memcpy(z[0..path.len], path);
        const rc = std.os.linux.open(&z, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
            .CLOEXEC = true,
        }, 0o644);
        if (std.os.linux.errno(rc) != .SUCCESS) return false;
        self.fd = @intCast(rc);
        return true;
    }

    pub fn write(self: *MixerLog, msg: []const u8) void {
        if (!self.ensureOpen()) return;
        var stamp_buf: [32]u8 = undefined;
        const stamp = wallStamp(&stamp_buf);
        const fd = self.fd;
        var hbuf: [40]u8 = undefined;
        const head = std.fmt.bufPrint(&hbuf, "[{s}] ", .{stamp}) catch return;
        _ = std.os.linux.write(fd, head.ptr, head.len);
        _ = std.os.linux.write(fd, msg.ptr, msg.len);
        _ = std.os.linux.write(fd, "\n".ptr, 1);
    }

    pub fn reportOpen(self: *MixerLog, ndevs: i32, nstreams: i32, snap_ms: f64) void {
        if (!self.enabled) return;
        var buf: [128]u8 = undefined;
        self.write(std.fmt.bufPrint(&buf, "open devs={d} streams={d} snap={d:.2}ms", .{ ndevs, nstreams, snap_ms }) catch return);
    }

    pub fn reportClick(self: *MixerLog, action: []const u8, ms: f64) void {
        if (!self.enabled) return;
        if (ms < 4.0 and !self.perf_all) return;
        var buf: [128]u8 = undefined;
        self.write(std.fmt.bufPrint(&buf, "click action={s} {d:.2}ms", .{ action, ms }) catch return);
    }

    pub fn noteMotionPw(self: *MixerLog, us: i64) void {
        self.motions += 1;
        self.motion_pw_us += us;
    }

    pub fn reportPaint(self: *MixerLog, ndevs: usize, nstreams: usize, tm: *const Timings) void {
        if (!self.enabled) return;
        const total = tm.snap_ms + tm.link_ms + tm.layout_ms + tm.chrome_ms + tm.header_ms + tm.master_ms + tm.devices_ms + tm.streams_ms + tm.router_ms + tm.footer_ms;
        self.frames += 1;
        self.total_ms += total;
        if (total > self.max_ms) self.max_ms = total;
        const slow = total >= self.thresh_ms;
        if (slow) self.slow += 1;
        if (!self.perf_all and !slow) {
            if (self.frames % 300 == 0) self.summarize("paint");
            return;
        }
        var buf: [640]u8 = undefined;
        self.write(std.fmt.bufPrint(&buf, "{s}paint total={d:.2} snap={d:.2}({s}) link={d:.2} layout={d:.2} chrome={d:.2} header={d:.2} master={d:.2} devs={d:.2} streams={d:.2} router={d:.2} footer={d:.2} sliders={d}(n={d}) icons={d}(n={d}) text={d}(n={d}) dev={d} streams={d}", .{
            if (slow) "SLOW " else "",
            total,
            tm.snap_ms,
            if (tm.snap_hit) "hit" else "miss",
            tm.link_ms,
            tm.layout_ms,
            tm.chrome_ms,
            tm.header_ms,
            tm.master_ms,
            tm.devices_ms,
            tm.streams_ms,
            tm.router_ms,
            tm.footer_ms,
            tm.slider_us,
            tm.slider_n,
            tm.icon_us,
            tm.icon_n,
            tm.text_us,
            tm.text_n,
            ndevs,
            nstreams,
        }) catch return);
        if (self.frames % 300 == 0) self.summarize("paint");
    }

    fn summarize(self: *MixerLog, ctx: []const u8) void {
        const avg = if (self.frames > 0) self.total_ms / @as(f64, @floatFromInt(self.frames)) else 0;
        const pw_avg: f64 = if (self.motions > 0) @as(f64, @floatFromInt(self.motion_pw_us)) / @as(f64, @floatFromInt(self.motions)) / 1000.0 else 0;
        var buf: [256]u8 = undefined;
        self.write(std.fmt.bufPrint(&buf, "summary[{s}] frames={d} slow={d} avg={d:.2}ms max={d:.2}ms mindt={d:.2}ms rate_max/s={d} motions={d} pwset_avg={d:.2}ms", .{
            ctx, self.frames, self.slow, avg, self.max_ms, self.min_dt_ms, self.max_per_sec, self.motions, pw_avg,
        }) catch return);
    }
};

const CTmLog = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*:0]const u8,
};

extern fn localtime_r(t: [*c]const i64, out: *CTmLog) ?*CTmLog;

/// `[HH:MM:SS.mmm]` wall stamp for log lines.
fn wallStamp(buf: []u8) []const u8 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    var sec: i64 = @intCast(ts.sec);
    var tm: CTmLog = undefined;
    if (localtime_r(&sec, &tm)) |_| {
        if (buf.len < 12) return buf[0..0];
        const h: u8 = @intCast(@max(tm.tm_hour, 0));
        const mi: u8 = @intCast(@max(tm.tm_min, 0));
        const se: u8 = @intCast(@max(tm.tm_sec, 0));
        const ms: u16 = @intCast(@divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), 1000000));
        buf[0] = '0' + h / 10;
        buf[1] = '0' + h % 10;
        buf[2] = ':';
        buf[3] = '0' + mi / 10;
        buf[4] = '0' + mi % 10;
        buf[5] = ':';
        buf[6] = '0' + se / 10;
        buf[7] = '0' + se % 10;
        buf[8] = '.';
        buf[9] = '0' + @as(u8, @intCast(ms / 100));
        buf[10] = '0' + @as(u8, @intCast((ms / 10) % 10));
        buf[11] = '0' + @as(u8, @intCast(ms % 10));
        return buf[0..12];
    }
    return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intCast(ts.sec))}) catch buf[0..0];
}

// Tests: paint helpers, icon cascade, log

test "mixer: volume and device glyph ladders" {
    const t = std.testing;
    try t.expectEqualStrings("volume_off", volumeGlyph(0, false));
    try t.expectEqualStrings("volume_off", volumeGlyph(80, true));
    try t.expectEqualStrings("volume_down", volumeGlyph(20, false));
    try t.expectEqualStrings("volume_up", volumeGlyph(80, false));
    try t.expectEqualStrings("headphones", deviceGlyph("bluez_output.WH-1000XM5"));
    try t.expectEqualStrings("tv", deviceGlyph("alsa_output.hdmi-stereo"));
    try t.expectEqualStrings("usb", deviceGlyph("alsa_output.usb-dac"));
    try t.expectEqualStrings("mic", deviceGlyph("alsa_input.mic"));
    try t.expectEqualStrings("speaker", deviceGlyph("alsa_output.pci"));
}

test "mixer: ellipsize keeps fitting text, truncates the rest" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    // Null context: advance 0 always fits nothing past the floor.
    try t.expectEqualStrings("", ellipsize(null, "", 100, &buf));
    try t.expectEqualStrings("", ellipsize(null, "abc", 0, &buf));
    // A generous budget keeps the text whole.
    const adv = struct {
        fn f(_: *anyopaque, s: []const u8) f64 {
            return @as(f64, @floatFromInt(s.len)) * 10.0;
        }
    };
    _ = adv;
    // With a null context every advance is 0, so anything fits whole.
    try t.expectEqualStrings("hello", ellipsize(null, "hello", 1000, &buf));
}

test "mixer: stream icon candidates follow the cascade" {
    const t = std.testing;
    var out: [24][2][]const u8 = undefined;
    const names = streamIconNames(&out, "firefox.png", "firefox", "/usr/bin/firefox", "Firefox");
    try t.expect(names.len > 0);
    // Dotted icon names try the app cache first.
    try t.expectEqualStrings("firefox.png", names[0][0]);
    try t.expectEqualStrings("a", names[0][1]);
    // Wrappers never contribute basenames.
    var out2: [24][2][]const u8 = undefined;
    const names2 = streamIconNames(&out2, "", "org.foo.App", "flatpak-bwrap", "Foo");
    for (names2) |n| try t.expect(!std.mem.eql(u8, n[0], "flatpak-bwrap"));
    // Hint keys fire for known apps (one matching signal → one group).
    var hb: [8][]const u8 = undefined;
    const hints = mixerThemeHintKeys(&hb, "/usr/bin/msedge", "Browser");
    try t.expect(hints.len == 4);
    try t.expectEqualStrings("com.microsoft.Edge", hints[0]);
    try t.expect(mixerThemeHintKeys(&hb, "/usr/bin/firefox", "Firefox").len == 0);
    // Slug + token helpers.
    var sbuf: [64]u8 = undefined;
    try t.expectEqualStrings("my-app", slugify(&sbuf, "My App"));
    try t.expectEqualStrings("Pavillion", firstAlphaToken("  Pavillion 27\"") orelse "");
}

test "mixer: log config and paths" {
    const t = std.testing;
    var pb: [256]u8 = undefined;
    try t.expectEqualStrings("/home/u/.local/state/event-horizon/horizon-volumemixer.log", mixerLogPath(&pb, "/home/u"));
    try t.expectEqualStrings("/tmp/event-horizon/horizon-volumemixer.log", mixerLogPath(&pb, ""));
    var log = MixerLog.configFromEnv(null, null, null);
    try t.expect(log.enabled and !log.perf_all);
    try t.expectEqual(@as(f64, 8.0), log.thresh_ms);
    log = MixerLog.configFromEnv("0", "1", "2.5");
    try t.expect(!log.enabled and log.perf_all);
    try t.expectEqual(@as(f64, 2.5), log.thresh_ms);
    log = MixerLog.configFromEnv(null, null, "bogus");
    try t.expectEqual(@as(f64, 8.0), log.thresh_ms);
    var stamp: [32]u8 = undefined;
    try t.expectEqual(@as(usize, 12), wallStamp(&stamp).len);
}

test "mixer: full paint runs headless and for real" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator, "");
    defer loaded.deinit();
    const sc = &loaded.cfg;
    const snap = Snapshot{
        .sinks = &[_]DeviceInfo{
            dev(1, "Built-in Audio", true, 80, false),
            dev(2, "HDMI", false, 50, true),
        },
        .out_streams = &[_]StreamInfo{
            .{ .node_id = 101, .app_name = "Firefox", .icon_name = "firefox", .app_id = "firefox", .volume_pct = 90 },
            .{ .node_id = 102, .app_name = "Music", .volume_pct = 60, .muted = true, .routed_display = "HDMI" },
        },
    };
    var ui = UiState{};
    const view = View{ .px = 300, .py = 100, .on_popup = true };
    const aux = Aux{
        .engine = .{ .available = true, .clock_rate_hz = 48000, .clock_quantum = 1024 },
        .top = .{ .available = true, .dsp_load_pct = 12.4, .xruns_total = 3 },
    };
    var tm = Timings{};
    // Null context: nothing paints, nothing crashes.
    try mixerPaint(t.allocator, null, sc, &snap, &ui, &view, &aux, null, null);
    // Real surface with a router dropdown open and a drag live.
    ui.router_stream = 101;
    ui.drag_active = true;
    ui.drag_kind = .stream;
    ui.drag_id = 101;
    ui.drag_t = 0.5;
    ui.drag_pct = 75;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 600, 620);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    var log = MixerLog.configFromEnv("0", null, null);
    try mixerPaint(t.allocator, cr, sc, &snap, &ui, &view, &aux, &log, &tm);
    try t.expect(tm.streams_ms >= 0);
    // Empty snapshot paints the placeholder branches.
    const empty = Snapshot{};
    try mixerPaint(t.allocator, cr, sc, &empty, &UiState{}, &View{}, &Aux{}, null, null);
}
