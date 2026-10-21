//! Native template renderer core for `{{ }}` substitution:
//! (`replace_namespace_placeholders`, `resolve_color_token`,
//! `generate_base16`, `lighten_argb`, `process_template`) plus the
//! `[templates.NAME]` entry parser. File orchestration (bundle merge,
//! post-hooks) is a later layer; this one is pure string transforms.
//!
//! Fidelity notes:
//!   * A garbage `| lighten:` amount is treated as no filter. Throwing there
//!     would unwind out of template rendering
//!     entirely — crashing theming over a template typo is not parity worth
//!     keeping. Well-formed amounts parse identically (longest-prefix,
//!     like `strtof`).
//!   * `lighten_argb` is `f32` throughout.

const std = @import("std");

pub const RoleEntry = struct {
    name: []const u8,
    index: u8,
};

pub const role_map = [_]RoleEntry{
    .{ .name = "primary", .index = 0 },
    .{ .name = "on_primary", .index = 1 },
    .{ .name = "primary_container", .index = 2 },
    .{ .name = "on_primary_container", .index = 3 },
    .{ .name = "secondary", .index = 4 },
    .{ .name = "on_secondary", .index = 5 },
    .{ .name = "secondary_container", .index = 6 },
    .{ .name = "on_secondary_container", .index = 7 },
    .{ .name = "tertiary", .index = 8 },
    .{ .name = "on_tertiary", .index = 9 },
    .{ .name = "tertiary_container", .index = 10 },
    .{ .name = "on_tertiary_container", .index = 11 },
    .{ .name = "error", .index = 12 },
    .{ .name = "on_error", .index = 13 },
    .{ .name = "error_container", .index = 14 },
    .{ .name = "on_error_container", .index = 15 },
    .{ .name = "surface", .index = 16 },
    .{ .name = "on_surface", .index = 17 },
    .{ .name = "surface_variant", .index = 18 },
    .{ .name = "on_surface_variant", .index = 19 },
    .{ .name = "surface_dim", .index = 20 },
    .{ .name = "surface_bright", .index = 21 },
    .{ .name = "surface_container_lowest", .index = 22 },
    .{ .name = "surface_container_low", .index = 23 },
    .{ .name = "surface_container", .index = 24 },
    .{ .name = "surface_container_high", .index = 25 },
    .{ .name = "surface_container_highest", .index = 26 },
    .{ .name = "inverse_surface", .index = 27 },
    .{ .name = "inverse_on_surface", .index = 28 },
    .{ .name = "inverse_primary", .index = 29 },
    .{ .name = "outline", .index = 30 },
    .{ .name = "outline_variant", .index = 31 },
    .{ .name = "shadow", .index = 32 },
    .{ .name = "scrim", .index = 33 },
    .{ .name = "surface_tint", .index = 34 },
    .{ .name = "primary_fixed", .index = 35 },
    .{ .name = "primary_fixed_dim", .index = 36 },
    .{ .name = "on_primary_fixed", .index = 37 },
    .{ .name = "on_primary_fixed_variant", .index = 38 },
    .{ .name = "secondary_fixed", .index = 39 },
    .{ .name = "secondary_fixed_dim", .index = 40 },
    .{ .name = "on_secondary_fixed", .index = 41 },
    .{ .name = "on_secondary_fixed_variant", .index = 42 },
    .{ .name = "tertiary_fixed", .index = 43 },
    .{ .name = "tertiary_fixed_dim", .index = 44 },
    .{ .name = "on_tertiary_fixed", .index = 45 },
    .{ .name = "on_tertiary_fixed_variant", .index = 46 },
};

pub fn roleIndex(name: []const u8) ?u8 {
    for (role_map) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.index;
    }
    return null;
}

/// `resolve_color_token`: role names index the 47-role set; the three
/// specials and the unknown-name fallback match exactly.
pub fn resolveColorToken(roles: [47]u32, name: []const u8, is_dark: bool) u32 {
    if (roleIndex(name)) |i| return roles[i];
    if (std.mem.eql(u8, name, "background")) return if (is_dark) 0xFF000000 else 0xFFFFFFFF;
    if (std.mem.eql(u8, name, "on_background")) return if (is_dark) 0xFFFFFFFF else 0xFF000000;
    if (std.mem.eql(u8, name, "source_color")) return 0;
    return if (is_dark) 0xFFFFFFFF else 0xFF000000;
}

const dark_base16_roles = [_]u8{ 20, 22, 23, 24, 25, 17, 19, 0, 12, 8, 4, 2, 6, 3, 7, 14 };
const light_base16_roles = [_]u8{ 21, 26, 25, 24, 23, 17, 19, 0, 12, 8, 4, 2, 6, 3, 7, 14 };

pub fn generateBase16(roles: [47]u32, is_dark: bool) [16]u32 {
    const map = if (is_dark) dark_base16_roles else light_base16_roles;
    var out: [16]u32 = undefined;
    for (map, 0..) |ri, i| out[i] = roles[ri];
    return out;
}

pub const event16_map = [_]u8{ 0, 8, 11, 10, 13, 14, 12, 5, 3, 8, 11, 10, 13, 14, 12, 7 };

fn clampf(v: f32, lo: f32, hi: f32) f32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

pub fn lightenArgb(c: u32, amount: f32) u32 {
    const r: f32 = @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(c & 0xFF)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt((c >> 24) & 0xFF)) / 255.0;
    const cmax = @max(r, @max(g, b));
    const cmin = @min(r, @min(g, b));
    var l = (cmax + cmin) / 2.0;
    var h: f32 = 0.0;
    var s: f32 = 0.0;
    if (cmax != cmin) {
        const d = cmax - cmin;
        s = if (l > 0.5) d / (2.0 - cmax - cmin) else d / (cmax + cmin);
        if (cmax == r) {
            h = (g - b) / d + (if (g < b) @as(f32, 6.0) else @as(f32, 0.0));
        } else if (cmax == g) {
            h = (b - r) / d + 2.0;
        } else {
            h = (r - g) / d + 4.0;
        }
        h /= 6.0;
    }
    l = clampf(l + amount / 100.0, 0.0, 1.0);

    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const rr = hue2rgb(p, q, h + 1.0 / 3.0);
    const gg = hue2rgb(p, q, h);
    const bb = hue2rgb(p, q, h - 1.0 / 3.0);
    return (@as(u32, toByte(a)) << 24) | (@as(u32, toByte(rr)) << 16) | (@as(u32, toByte(gg)) << 8) | @as(u32, toByte(bb));
}

fn hue2rgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

fn toByte(v: f32) u8 {
    const i: i32 = @intFromFloat(v * 255.0 + 0.5);
    return @intCast(std.math.clamp(i, 0, 255));
}

/// `strtof` prefix semantics: longest leading float, null when nothing parses.
fn parseFloatPrefix(s: []const u8) ?f32 {
    var end: usize = s.len;
    while (end > 0) {
        if (std.fmt.parseFloat(f32, s[0..end])) |v| return v else |_| {}
        end -= 1;
    }
    return null;
}

pub const LookupFn = *const fn (?*anyopaque, []const u8, bool) u32;

/// Both `{{ns.` and `{{ ns.` passes, chained: the second scans the first's
/// output, exactly like an in-place walk. Replacements are never
/// rescanned.
pub fn replaceNamespace(
    alloc: std.mem.Allocator,
    content: []const u8,
    ns: []const u8,
    lookup: LookupFn,
    ctx: ?*anyopaque,
    is_dark: bool,
) ![]u8 {
    // Built byte-wise: `{{` in a *format* string would collapse to one brace.
    var opens: [128]u8 = undefined;
    if (ns.len + 4 > opens.len) return error.NoSpaceLeft;
    opens[0] = '{';
    opens[1] = '{';
    @memcpy(opens[2..][0..ns.len], ns);
    opens[2 + ns.len] = '.';
    const open_plain = opens[0 .. 3 + ns.len];
    const first = try replaceOnePass(alloc, content, open_plain, lookup, ctx, is_dark);
    defer alloc.free(first);
    opens[2] = ' ';
    @memcpy(opens[3..][0..ns.len], ns);
    opens[3 + ns.len] = '.';
    const open_spaced = opens[0 .. 4 + ns.len];
    return replaceOnePass(alloc, first, open_spaced, lookup, ctx, is_dark);
}

fn replaceOnePass(
    alloc: std.mem.Allocator,
    content: []const u8,
    open: []const u8,
    lookup: LookupFn,
    ctx: ?*anyopaque,
    is_dark: bool,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, open)) |found| {
        const end = std.mem.indexOfPos(u8, content, found, "}}") orelse break;
        // Unclosed tail copies verbatim.
        var token = content[found + open.len .. end];
        while (token.len > 0 and token[0] == ' ') token = token[1..];
        while (token.len > 0 and token[token.len - 1] == ' ') token = token[0 .. token.len - 1];

        // `| lighten: N` filter.
        // NOTE: no trailing trim here — keeping `main_part` raw, so
        // `red | lighten` formats as default-hex there too. Mirrored.
        var main_part = token;
        var filter_amount: f32 = 0.0;
        var has_filter = false;
        if (std.mem.indexOfScalar(u8, token, '|')) |pipe| {
            main_part = token[0..pipe];
            var filter_str = token[pipe + 1 ..];
            while (filter_str.len > 0 and filter_str[0] == ' ') filter_str = filter_str[1..];
            if (std.mem.indexOfScalar(u8, filter_str, ':')) |colon| {
                if (std.mem.eql(u8, filter_str[0..colon], "lighten")) {
                    var val = filter_str[colon + 1 ..];
                    while (val.len > 0 and val[0] == ' ') val = val[1..];
                    if (parseFloatPrefix(val)) |v| {
                        filter_amount = v;
                        has_filter = true;
                    }
                }
            }
        }

        const split = splitFmt(main_part) orelse {
            try out.appendSlice(alloc, content[pos .. end + 2]);
            pos = end + 2;
            continue;
        };
        const fmt = split.fmt;
        const mode = split.mode;
        const token_name = split.token_name;

        var token_is_dark = is_dark;
        if (std.mem.eql(u8, mode, "default")) {
            // resolved by is_dark already
        } else if (std.mem.eql(u8, mode, "dark")) {
            token_is_dark = true;
        } else if (std.mem.eql(u8, mode, "light")) {
            token_is_dark = false;
        } else {
            try out.appendSlice(alloc, content[pos .. end + 2]);
            pos = end + 2;
            continue;
        }

        try out.appendSlice(alloc, content[pos..found]);
        var color = lookup(ctx, token_name, token_is_dark);
        if (has_filter) color = lightenArgb(color, filter_amount);
        var fbuf: [32]u8 = undefined;
        const replacement: []const u8 = if (std.mem.eql(u8, fmt, "hex_stripped"))
            std.fmt.bufPrint(&fbuf, "{x:0>6}", .{color & 0x00FFFFFF}) catch ""
        else if (std.mem.eql(u8, fmt, "red"))
            std.fmt.bufPrint(&fbuf, "{d}", .{(color >> 16) & 0xFF}) catch ""
        else if (std.mem.eql(u8, fmt, "green"))
            std.fmt.bufPrint(&fbuf, "{d}", .{(color >> 8) & 0xFF}) catch ""
        else if (std.mem.eql(u8, fmt, "blue"))
            std.fmt.bufPrint(&fbuf, "{d}", .{color & 0xFF}) catch ""
        else if (std.mem.eql(u8, fmt, "rgb"))
            std.fmt.bufPrint(&fbuf, "{d}, {d}, {d}", .{ (color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF }) catch ""
        else
            std.fmt.bufPrint(&fbuf, "#{x:0>6}", .{color & 0x00FFFFFF}) catch "";
        try out.appendSlice(alloc, replacement);
        pos = end + 2;
    }
    try out.appendSlice(alloc, content[pos..]);
    return out.toOwnedSlice(alloc);
}

const ColorsCtx = struct {
    roles_dark: *const [47]u32,
    roles_light: *const [47]u32,
    source_color: u32,
};

fn colorsLookup(ctx: ?*anyopaque, name: []const u8, token_is_dark: bool) u32 {
    const c: *ColorsCtx = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, name, "source_color")) return c.source_color;
    return if (token_is_dark)
        resolveColorToken(c.roles_dark.*, name, true)
    else
        resolveColorToken(c.roles_light.*, name, false);
}

const Base16Ctx = struct {
    dark: *const [16]u32,
    light: *const [16]u32,
};

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn base16Lookup(ctx: ?*anyopaque, name: []const u8, token_is_dark: bool) u32 {
    const c: *Base16Ctx = @ptrCast(@alignCast(ctx.?));
    const b = if (token_is_dark) c.dark.* else c.light.*;
    if (name.len == 6 and std.mem.startsWith(u8, name, "base")) {
        const hi = hexDigit(name[4]) orelse return 0;
        const lo = hexDigit(name[5]) orelse return 0;
        const idx: usize = @as(usize, hi) * 16 + lo;
        if (idx < 16) return b[idx];
    }
    return 0;
}

/// `stoi` prefix semantics: longest leading run of digits, null when none.
fn stoiPrefix(s: []const u8) ?i32 {
    // Leading whitespace is skipped; signs never occur in template
    // indices, and only the digit run matters for the range check below.
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var v: i32 = 0;
    var digits: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + @as(i32, @intCast(s[i] - '0'));
        digits += 1;
    }
    if (digits == 0) return null;
    return v;
}

fn event16Lookup(ctx: ?*anyopaque, name: []const u8, token_is_dark: bool) u32 {
    const c: *Base16Ctx = @ptrCast(@alignCast(ctx.?));
    const b = if (token_is_dark) c.dark.* else c.light.*;
    if (name.len >= 5 and std.mem.startsWith(u8, name, "color")) {
        if (stoiPrefix(name[5..])) |idx| {
            if (idx >= 0 and idx < 16) return b[event16_map[@intCast(idx)]];
        }
    }
    return 0;
}

/// All three namespaces over one template body. Explicit light/dark
/// placeholders resolve against their own mode's palette, so dual-scheme
/// templates render completely in a single pass.
pub fn processTemplate(
    alloc: std.mem.Allocator,
    content: []const u8,
    roles_dark: *const [47]u32,
    base16_dark: *const [16]u32,
    roles_light: *const [47]u32,
    base16_light: *const [16]u32,
    source_color: u32,
    is_dark: bool,
) ![]u8 {
    var cc = ColorsCtx{ .roles_dark = roles_dark, .roles_light = roles_light, .source_color = source_color };
    const pass1 = try replaceNamespace(alloc, content, "colors", colorsLookup, &cc, is_dark);
    defer alloc.free(pass1);
    var bc = Base16Ctx{ .dark = base16_dark, .light = base16_light };
    const pass2 = try replaceNamespace(alloc, pass1, "base16", base16Lookup, &bc, is_dark);
    defer alloc.free(pass2);
    return replaceNamespace(alloc, pass2, "event16", event16Lookup, &bc, is_dark);
}

/// `token.mode.fmt` split on the last two dots; null when fewer than two.
fn splitFmt(main_part: []const u8) ?struct { fmt: []const u8, mode: []const u8, token_name: []const u8 } {
    const ld = std.mem.lastIndexOfScalar(u8, main_part, '.') orelse return null;
    const sd = std.mem.lastIndexOfScalar(u8, main_part[0..ld], '.') orelse return null;
    return .{ .fmt = main_part[ld + 1 ..], .mode = main_part[sd + 1 .. ld], .token_name = main_part[0..sd] };
}

pub const TemplateEntry = struct {
    name: []u8 = &.{},
    input_path: []u8 = &.{},
    output_path: []u8 = &.{},

    pub fn deinit(self: *TemplateEntry, alloc: std.mem.Allocator) void {
        if (self.name.len > 0) alloc.free(self.name);
        if (self.input_path.len > 0) alloc.free(self.input_path);
        if (self.output_path.len > 0) alloc.free(self.output_path);
        self.* = .{};
    }
};

fn parseQuotedValue(line: []const u8, key: []const u8, alloc: std.mem.Allocator) ?[]u8 {
    const pos = std.mem.indexOf(u8, line, key) orelse return null;
    const after = line[pos + key.len ..];
    if (!std.mem.startsWith(u8, after, " = ")) return null;
    const rest = after[" = ".len..];
    if (rest.len == 0) return null;
    const q = rest[0];
    if (q != '\'' and q != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, rest, 1, q) orelse return null;
    return alloc.dupe(u8, rest[1..end]) catch null;
}

/// The `[templates.NAME]` section parser: headers open entries, any other
/// `[` line closes the section, `input_path`/`output_path` fill once each
/// (first wins), and entries missing either path are dropped.
pub fn parseTemplateEntries(
    alloc: std.mem.Allocator,
    toml_body: []const u8,
) !std.ArrayList(TemplateEntry) {
    var entries = std.ArrayList(TemplateEntry).empty;
    errdefer {
        for (entries.items) |*e| e.deinit(alloc);
        entries.deinit(alloc);
    }
    var current: ?usize = null;
    var lines = std.mem.splitScalar(u8, toml_body, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > 12 and std.mem.startsWith(u8, line, "[templates.") and line[line.len - 1] == ']') {
            const name = line["[templates.".len .. line.len - 1];
            if (name.len == 0) {
                current = null;
                continue;
            }
            try entries.append(alloc, .{});
            const idx = entries.items.len - 1;
            entries.items[idx].name = try alloc.dupe(u8, name);
            current = idx;
            continue;
        }
        if (line.len > 0 and line[0] == '[') {
            current = null;
            continue;
        }
        const ci = current orelse continue;
        if (entries.items[ci].input_path.len == 0) {
            if (parseQuotedValue(line, "input_path", alloc)) |v| {
                entries.items[ci].input_path = v;
            }
        }
        if (entries.items[ci].output_path.len == 0) {
            if (parseQuotedValue(line, "output_path", alloc)) |v| {
                entries.items[ci].output_path = v;
            }
        }
    }
    // Drop entries missing either path (swap-remove from the back).
    var i = entries.items.len;
    while (i > 0) {
        i -= 1;
        if (entries.items[i].input_path.len == 0 or entries.items[i].output_path.len == 0) {
            var e = entries.orderedRemove(i);
            e.deinit(alloc);
        }
    }
    return entries;
}

test "templates: role map covers all 47 roles" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 47), role_map.len);
    try t.expectEqual(@as(?u8, 0), roleIndex("primary"));
    try t.expectEqual(@as(?u8, 46), roleIndex("on_tertiary_fixed_variant"));
    try t.expectEqual(@as(?u8, null), roleIndex("nope"));
    var roles: [47]u32 = undefined;
    for (0..47) |i| roles[i] = 0xFF000000 | @as(u32, @intCast(i));
    try t.expectEqual(@as(u32, 0xFF000003), resolveColorToken(roles, "on_primary_container", true));
    try t.expectEqual(@as(u32, 0xFF000000), resolveColorToken(roles, "background", true));
    try t.expectEqual(@as(u32, 0xFFFFFFFF), resolveColorToken(roles, "background", false));
    try t.expectEqual(@as(u32, 0xFFFFFFFF), resolveColorToken(roles, "on_background", true));
    try t.expectEqual(@as(u32, 0), resolveColorToken(roles, "source_color", true));
    try t.expectEqual(@as(u32, 0xFFFFFFFF), resolveColorToken(roles, "whatever", true));
    try t.expectEqual(@as(u32, 0xFF000000), resolveColorToken(roles, "whatever", false));
}

test "templates: base16 maps both modes" {
    const t = std.testing;
    var roles: [47]u32 = undefined;
    for (0..47) |i| roles[i] = 0xFF000000 | @as(u32, @intCast(100 + i));
    const dark = generateBase16(roles, true);
    const light = generateBase16(roles, false);
    try t.expectEqual(roles[20], dark[0x00]);
    try t.expectEqual(roles[21], light[0x00]);
    try t.expectEqual(roles[17], dark[0x05]);
    try t.expectEqual(roles[17], light[0x05]);
    try t.expectEqual(roles[14], dark[0x0F]);
    try t.expectEqual(roles[14], light[0x0F]);
    try t.expectEqual(roles[25], dark[0x04]);
    try t.expectEqual(roles[23], light[0x04]);
}

test "templates: lighten matches the probe values" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0xFF72A4F7), lightenArgb(0xFF4285F4, 10.0));
    try t.expectEqual(@as(u32, 0xFF333333), lightenArgb(0xFF000000, 20.0));
    try t.expectEqual(@as(u32, 0xFFB3B3B3), lightenArgb(0xFFFFFFFF, -30.0));
    try t.expectEqual(@as(u32, 0xFF6A462D), lightenArgb(0xFF563925, 5.5));
}

test "templates: placeholders render across namespaces" {
    const t = std.testing;
    const alloc = t.allocator;
    var roles_dark: [47]u32 = undefined;
    var roles_light: [47]u32 = undefined;
    for (0..47) |i| {
        roles_dark[i] = 0xFF000000 | @as(u32, @intCast(i));
        roles_light[i] = 0xFF111111 | @as(u32, @intCast(i));
    }
    const b16_dark = generateBase16(roles_dark, true);
    const b16_light = generateBase16(roles_light, false);
    const got = try processTemplate(
        alloc,
        "a={{colors.primary.dark.hex}} b={{ colors.on_surface.light.hex }} " ++
            "c={{base16.base0A.default.hex}} d={{event16.color5.default.hex_stripped}} " ++
            "e={{colors.primary.dark.red}} f={{colors.shadow.default.rgb}} " ++
            "g={{colors.primary.dark.hex | lighten: 10}} h={{colors.nope.dark.hex}} " ++
            "i={{colors.primary.bogus.hex}} j={{colors.primary.dark.hex",
        &roles_dark,
        &b16_dark,
        &roles_light,
        &b16_light,
        0xFF123456,
        true,
    );
    defer alloc.free(got);
    // primary=0 -> FF000000; on_surface light=roles_light[17]=0xFF111111|17;
    // base0A dark=b16_dark[10]=roles_dark[4]=0xFF000004;
    // event16 color5 -> base16[3]=roles_dark[24]=0xFF000018 stripped;
    // red of primary=0; rgb of shadow=roles_dark[32]=0,0,32;
    // lighten is over hex (trailing space) so it renders default hex of the
    // lightened primary; unknown names fall back to white in dark mode;
    // unknown modes and unclosed placeholders pass through verbatim.
    const want =
        "a=#000000 b=#111111 " ++
        "c=#000004 d=000007 " ++
        "e=0 f=0, 0, 32 " ++
        "g=#1a1a1a h=#ffffff " ++
        "i={{colors.primary.bogus.hex}} j={{colors.primary.dark.hex";
    try t.expectEqualStrings(want, got);
}

test "templates: entry parser keeps complete sections only" {
    const t = std.testing;
    const alloc = t.allocator;
    const body =
        "[templates.kitty]\n" ++
        "input_path = 'kitty.conf'\n" ++
        "output_path = '~/.config/kitty/kitty.conf'\n" ++
        "[templates.half]\n" ++
        "input_path = 'x'\n" ++
        "[other]\n" ++
        "input_path = 'y'\n" ++
        "[templates.gtk]\n" ++
        "output_path = \"a\"\n" ++
        "input_path = \"b\"\n";
    var entries = try parseTemplateEntries(alloc, body);
    defer {
        for (entries.items) |*e| e.deinit(alloc);
        entries.deinit(alloc);
    }
    try t.expectEqual(@as(usize, 2), entries.items.len);
    try t.expectEqualStrings("kitty", entries.items[0].name);
    try t.expectEqualStrings("kitty.conf", entries.items[0].input_path);
    try t.expectEqualStrings("~/.config/kitty/kitty.conf", entries.items[0].output_path);
    try t.expectEqualStrings("gtk", entries.items[1].name);
    try t.expectEqualStrings("b", entries.items[1].input_path);
    try t.expectEqualStrings("a", entries.items[1].output_path);
}
