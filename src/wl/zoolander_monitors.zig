//! Zig port of `otr/zl_json/monitors.otr`: parse the `monitors-json` reply
//! that the Zoolander compositor emits over its control IPC socket.
//!
//! Top-level shape: `{ "version": 1, "outputs": [ <Output> ... ] }`.
//! Every field the settings app reads is modelled below; absent optional
//! fields decode to their zero value / null.

const std = @import("std");

/// One output's reported capabilities and current state.
pub const Output = struct {
    name: []const u8 = "",
    focused: bool = false,
    enabled: bool = false,
    primary: bool = false,
    make: []const u8 = "",
    model: []const u8 = "",
    serial: []const u8 = "",
    x: i32 = 0,
    y: i32 = 0,
    logical_width: i32 = 0,
    logical_height: i32 = 0,
    scale: f64 = 1.0,
    transform: []const u8 = "normal",
    mode: ?*Mode = null,
    physical_mm: [2]u32 = .{ 0, 0 },
    modes: []Mode = &[_]Mode{},
    vrr: Toggle = .{},
    tearing_capable: bool = false,
    hdr: Hdr = .{},
    bit_depth: u32 = 8,
    ten_bit_capable: bool = false,
    max_bpc: ?*Bpc = null,
    edid: ?*Edid = null,
    render: ?*Render = null,
};

/// One advertised video mode.
pub const Mode = struct {
    width: u32 = 0,
    height: u32 = 0,
    refresh_mhz: u32 = 0,
    preferred: bool = false,
};

/// A two-state capability: `capable` / `enabled`.
pub const Toggle = struct {
    capable: bool = false,
    enabled: bool = false,
};

/// HDR capability and state.
pub const Hdr = struct {
    capable: bool = false,
    enabled: bool = false,
    transfer: []const u8 = "sdr",
};

/// Connector max bits-per-channel range.
pub const Bpc = struct {
    min: u32 = 0,
    max: u32 = 0,
};

/// EDID block (present only for enabled outputs with an EDID).
pub const Edid = struct {
    primaries: [3][2]f64 = undefined,
    white: [2]f64 = undefined,
    gamma: f64 = 0.0,
    max_luminance: f64 = 0.0,
    min_luminance: f64 = 0.0,
    max_avg_luminance: ?f64 = null,
};

/// Per-output render pipeline state.
pub const Render = struct {
    transfer: []const u8 = "srgb",
    reference_luminance: f64 = 0.0,
    max_luminance: f64 = 0.0,
    sdr_brightness: f64 = 1.0,
    sdr_saturation: f64 = 1.0,
    sdr_min_luminance: f64 = 0.0,
    sdr_max_luminance: f64 = 100.0,
    sdr_eotf: []const u8 = "srgb",
};

/// The whole reply: a version gate plus the output list.
pub const Monitors = struct {
    version: u32 = 0,
    outputs: []Output = &[_]Output{},
};

/// Parse a `monitors-json` document. Requires `version == 1`.
pub fn parse(alloc: std.mem.Allocator, json: []const u8) !Monitors {
    const parsed = try std.json.parseFromSlice(Monitors, alloc, json, .{
        .ignore_unknown_fields = true,
    });
    if (parsed.value.version != 1) {
        parsed.deinit();
        return error.UnsupportedVersion;
    }
    const out = parsed.value;

    var result: Monitors = undefined;
    result.version = out.version;
    result.outputs = try alloc.alloc(Output, out.outputs.len);
    for (out.outputs, 0..) |src, i| {
        result.outputs[i] = try copyOutput(alloc, src);
    }
    defer parsed.deinit();
    return result;
}

fn copyOutput(alloc: std.mem.Allocator, src: Output) !Output {
    var dst = Output{};
    dst.name = try alloc.dupe(u8, src.name);
    dst.focused = src.focused;
    dst.enabled = src.enabled;
    dst.primary = src.primary;
    dst.make = try alloc.dupe(u8, src.make);
    dst.model = try alloc.dupe(u8, src.model);
    dst.serial = try alloc.dupe(u8, src.serial);
    dst.x = src.x;
    dst.y = src.y;
    dst.logical_width = src.logical_width;
    dst.logical_height = src.logical_height;
    dst.scale = src.scale;
    dst.transform = try alloc.dupe(u8, src.transform);
    if (src.mode) |m| {
        const slot = try alloc.create(Mode);
        slot.* = m.*;
        dst.mode = slot;
    }
    dst.physical_mm = src.physical_mm;
    dst.modes = try alloc.alloc(Mode, src.modes.len);
    for (src.modes, 0..) |m, j| {
        dst.modes[j] = m;
    }
    dst.vrr = src.vrr;
    dst.tearing_capable = src.tearing_capable;
    dst.hdr.capable = src.hdr.capable;
    dst.hdr.enabled = src.hdr.enabled;
    dst.hdr.transfer = try alloc.dupe(u8, src.hdr.transfer);
    dst.bit_depth = src.bit_depth;
    dst.ten_bit_capable = src.ten_bit_capable;
    if (src.max_bpc) |b| {
        const slot = try alloc.create(Bpc);
        slot.* = b.*;
        dst.max_bpc = slot;
    }
    if (src.edid) |e| {
        const slot = try alloc.create(Edid);
        slot.* = e.*;
        dst.edid = slot;
    }
    if (src.render) |r| {
        dst.render = try copyRender(alloc, r.*);
    }
    return dst;
}

fn copyRender(alloc: std.mem.Allocator, src: Render) !*Render {
    const slot = try alloc.create(Render);
    slot.transfer = try alloc.dupe(u8, src.transfer);
    slot.reference_luminance = src.reference_luminance;
    slot.max_luminance = src.max_luminance;
    slot.sdr_brightness = src.sdr_brightness;
    slot.sdr_saturation = src.sdr_saturation;
    slot.sdr_min_luminance = src.sdr_min_luminance;
    slot.sdr_max_luminance = src.sdr_max_luminance;
    slot.sdr_eotf = try alloc.dupe(u8, src.sdr_eotf);
    return slot;
}

/// Ask a running Zoolander for its output list. `zoolanderctl monitors-json`
/// prints a status line before the JSON document, so the first `{` starts it.
pub fn query(alloc: std.mem.Allocator, io: std.Io) !Monitors {
    const res = try std.process.run(alloc, io, .{
        .argv = &.{ "zoolanderctl", "monitors-json" },
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }
    if (res.term != .exited or res.term.exited != 0) return error.QueryFailed;
    const start = std.mem.indexOfScalar(u8, res.stdout, '{') orelse return error.Shape;
    return parse(alloc, res.stdout[start..]);
}

pub fn deinit(monitors: *Monitors, alloc: std.mem.Allocator) void {
    for (monitors.outputs) |*o| {
        alloc.free(o.name);
        alloc.free(o.make);
        alloc.free(o.model);
        alloc.free(o.serial);
        alloc.free(o.transform);
        alloc.free(o.hdr.transfer);
        if (o.mode) |m| alloc.destroy(m);
        alloc.free(o.modes);
        if (o.max_bpc) |b| alloc.destroy(b);
        if (o.edid) |e| alloc.destroy(e);
        if (o.render) |r| {
            alloc.free(r.transfer);
            alloc.free(r.sdr_eotf);
            alloc.destroy(r);
        }
    }
    alloc.free(monitors.outputs);
}

test "zoolander-monitors: parse enabled output with modes and EDID" {
    const t = std.testing;
    const json =
        \\{ "version": 1,
        \\  "outputs": [
        \\    {
        \\      "name": "DP-2",
        \\      "focused": true,
        \\      "enabled": true,
        \\      "primary": true,
        \\      "make": "Dell",
        \\      "model": "U2720Q",
        \\      "serial": "ABC123",
        \\      "x": 0,
        \\      "y": 0,
        \\      "logical_width": 3840,
        \\      "logical_height": 2160,
        \\      "scale": 1.5,
        \\      "transform": "normal",
        \\      "mode": { "width": 3840, "height": 2160, "refresh_mhz": 60000, "preferred": true },
        \\      "physical_mm": [600, 340],
        \\      "modes": [
        \\        { "width": 3840, "height": 2160, "refresh_mhz": 60000, "preferred": true },
        \\        { "width": 1920, "height": 1080, "refresh_mhz": 144000, "preferred": false }
        \\      ],
        \\      "vrr": { "capable": true, "enabled": true },
        \\      "tearing_capable": true,
        \\      "hdr": { "capable": true, "enabled": true, "transfer": "pq" },
        \\      "bit_depth": 10,
        \\      "ten_bit_capable": true,
        \\      "max_bpc": { "min": 8, "max": 10 },
        \\      "edid": {
        \\        "primaries": [[0.64,0.33],[0.30,0.60],[0.15,0.06]],
        \\        "white": [0.3127,0.3290],
        \\        "gamma": 2.2,
        \\        "max_luminance": 1000.0,
        \\        "min_luminance": 0.0005,
        \\        "max_avg_luminance": 500.0
        \\      },
        \\      "render": {
        \\        "transfer": "pq",
        \\        "reference_luminance": 203.0,
        \\        "max_luminance": 1000.0,
        \\        "sdr_brightness": 1.0,
        \\        "sdr_saturation": 1.0,
        \\        "sdr_min_luminance": 0.0,
        \\        "sdr_max_luminance": 100.0,
        \\        "sdr_eotf": "srgb"
        \\      }
        \\    },
        \\    {
        \\      "name": "HDMI-A-1",
        \\      "focused": false,
        \\      "enabled": false,
        \\      "primary": false,
        \\      "x": 3840,
        \\      "y": 0,
        \\      "logical_width": 0,
        \\      "logical_height": 0,
        \\      "scale": 1.0,
        \\      "transform": "normal",
        \\      "mode": null,
        \\      "physical_mm": [0, 0],
        \\      "modes": [],
        \\      "vrr": { "capable": false, "enabled": false },
        \\      "tearing_capable": false,
        \\      "hdr": { "capable": false, "enabled": false, "transfer": "sdr" },
        \\      "bit_depth": 8,
        \\      "ten_bit_capable": false,
        \\      "max_bpc": null,
        \\      "edid": null,
        \\      "render": null
        \\    }
        \\  ]
        \\}
    ;
    var mons = try parse(t.allocator, json);
    defer deinit(&mons, t.allocator);

    try t.expectEqual(@as(u32, 1), mons.version);
    try t.expectEqual(@as(usize, 2), mons.outputs.len);

    const dp = mons.outputs[0];
    try t.expectEqualStrings("DP-2", dp.name);
    try t.expect(dp.focused);
    try t.expect(dp.enabled);
    try t.expect(dp.primary);
    try t.expectEqualStrings("Dell", dp.make);
    try t.expectEqualStrings("U2720Q", dp.model);
    try t.expectEqualStrings("ABC123", dp.serial);
    try t.expectEqual(@as(i32, 0), dp.x);
    try t.expectEqual(@as(i32, 0), dp.y);
    try t.expectEqual(@as(i32, 3840), dp.logical_width);
    try t.expectEqual(@as(i32, 2160), dp.logical_height);
    try t.expect(std.math.approxEqAbs(f64, 1.5, dp.scale, 0.001));
    try t.expectEqualStrings("normal", dp.transform);
    try t.expect(dp.mode != null);
    try t.expectEqual(@as(u32, 3840), dp.mode.?.width);
    try t.expectEqual(@as(u32, 2160), dp.mode.?.height);
    try t.expectEqual(@as(u32, 60000), dp.mode.?.refresh_mhz);
    try t.expect(dp.mode.?.preferred);
    try t.expectEqual(@as(u32, 600), dp.physical_mm[0]);
    try t.expectEqual(@as(u32, 340), dp.physical_mm[1]);
    try t.expectEqual(@as(usize, 2), dp.modes.len);
    try t.expect(dp.vrr.capable);
    try t.expect(dp.vrr.enabled);
    try t.expect(dp.tearing_capable);
    try t.expect(dp.hdr.capable);
    try t.expect(dp.hdr.enabled);
    try t.expectEqualStrings("pq", dp.hdr.transfer);
    try t.expectEqual(@as(u32, 10), dp.bit_depth);
    try t.expect(dp.ten_bit_capable);
    try t.expect(dp.max_bpc != null);
    try t.expectEqual(@as(u32, 8), dp.max_bpc.?.min);
    try t.expectEqual(@as(u32, 10), dp.max_bpc.?.max);
    try t.expect(dp.edid != null);
    try t.expect(std.math.approxEqAbs(f64, 0.64, dp.edid.?.primaries[0][0], 0.001));
    try t.expect(std.math.approxEqAbs(f64, 1000.0, dp.edid.?.max_luminance, 0.001));
    try t.expect(dp.edid.?.max_avg_luminance != null);
    try t.expect(std.math.approxEqAbs(f64, 500.0, dp.edid.?.max_avg_luminance.?, 0.001));
    try t.expect(dp.render != null);
    try t.expectEqualStrings("pq", dp.render.?.transfer);

    const hdmi = mons.outputs[1];
    try t.expectEqualStrings("HDMI-A-1", hdmi.name);
    try t.expect(!hdmi.enabled);
    try t.expect(hdmi.mode == null);
    try t.expect(hdmi.modes.len == 0);
    try t.expect(!hdmi.vrr.capable);
    try t.expect(!hdmi.hdr.capable);
    try t.expectEqual(@as(u32, 8), hdmi.bit_depth);
    try t.expect(hdmi.max_bpc == null);
    try t.expect(hdmi.edid == null);
    try t.expect(hdmi.render == null);
}

test "zoolander-monitors: wrong version is rejected" {
    const t = std.testing;
    const json =
        \\{ "version": 2, "outputs": [] }
    ;
    try t.expectError(error.UnsupportedVersion, parse(t.allocator, json));
}
