//! Text handling for Hyprland IPC payloads: splitting `event>>a,b,c` arguments
//! and parsing the fields inside them.
//!
//! String-split and integer-parse helpers (`splitByN`/`decodeInt`/`findIdForName`). The expected values
//! in the tests below pin exact accept/reject edges —
//! whole-field digits and `sscanf`-style prefixes — because the two
//! accept and reject subtly different inputs and the event stream does not care
//! which one we picked.
//!
//! Everything here is pure string work: no sockets, no state.

const std = @import("std");
const win_id = @import("hyprland_win_id.zig");

/// Splits `data` on at most `count - 1` commas. The last slot keeps the rest of
/// the line, so a window title containing commas survives as one field.
///
/// Fields the line does not carry come back as empty slices rather than an
/// error, which is what every caller's "parse it or silently drop the event"
/// check expects.
pub fn splitByN(comptime count: usize, data: []const u8) [count][]const u8 {
    var out: [count][]const u8 = @splat("");
    if (count == 0) return out;
    var start: usize = 0;
    var n: usize = 0;
    while (n + 1 < count) : (n += 1) {
        const comma = std.mem.indexOfScalarPos(u8, data, start, ',') orelse break;
        out[n] = data[start..comma];
        start = comma + 1;
    }
    out[n] = data[start..];
    return out;
}

/// A window address through the shared parser: one implementation covers both
/// the `0x`-prefixed and bare forms, accepting exactly the same inputs in
/// either spelling.
pub fn decodeHex(val: []const u8) ?u64 {
    return win_id.parseHexAddr(val);
}

/// Whole-field 32-bit integer parse. The whole field must be digits (an
/// optional `-` in front), it must fit, and there is no `+`: `"+1"` is rejected
/// here even though `sscanf` in `findIdForName` would take it.
pub fn decodeInt(val: []const u8) ?i32 {
    if (val.len == 0) return null;
    var s = val;
    const negative = s[0] == '-';
    if (negative) {
        s = s[1..];
        if (s.len == 0) return null;
    }
    var magnitude: u64 = 0;
    for (s) |ch| {
        const digit = std.fmt.charToDigit(ch, 10) catch return null;
        magnitude = std.math.mul(u64, magnitude, 10) catch return null;
        magnitude = std.math.add(u64, magnitude, digit) catch return null;
    }
    if (negative) {
        if (magnitude > 2147483648) return null;
        if (magnitude == 2147483648) return -2147483648;
        return -@as(i32, @intCast(magnitude));
    }
    if (magnitude > 2147483647) return null;
    return @intCast(magnitude);
}

/// The workspace id behind a region id, as `sscanf("%ld", …)` read it: leading
/// whitespace skipped, an optional sign, digits until the first non-digit, and
/// the result rejected unless it lands in `[0, 2147483647]`.
///
/// So `"2abc"` is workspace 2 and `"0x2"` is workspace 0 (the `x` stops the
/// scan), while `"2.5"` is also workspace 2 — looser than `decodeInt`, which
/// is why the two are separate functions. The `> 0` check the
/// caller makes afterwards is what keeps workspace 0 from being focused.
pub fn findIdForName(id: []const u8) i32 {
    var i: usize = 0;
    while (i < id.len and std.ascii.isWhitespace(id[i])) i += 1;
    if (i >= id.len) return -1;

    const negative = id[i] == '-';
    if (id[i] == '+' or id[i] == '-') i += 1;
    const digits_start = i;

    var value: i64 = 0;
    while (i < id.len and std.ascii.isDigit(id[i])) : (i += 1) {
        // `long` saturates rather than wrapping; anything past the `int` range
        // is rejected by the bounds check below either way.
        value = std.math.mul(i64, value, 10) catch std.math.maxInt(i64);
        value = std.math.add(i64, value, @as(i64, id[i] - '0')) catch std.math.maxInt(i64);
    }
    if (i == digits_start) return -1;

    const parsed: i64 = if (negative) -value else value;
    if (parsed < 0 or parsed > 2147483647) return -1;
    return @intCast(parsed);
}

/// The `dispatch` command for focusing a workspace. Under the lua config
/// provider the plain form is rejected outright, so callers need both spellings
/// and the session's verdict on which one applies.
pub fn jumpCommand(buf: []u8, lua: bool, ws_id: i32) ?[]const u8 {
    if (lua) {
        return std.fmt.bufPrint(buf, "dispatch hl.dsp.focus({{workspace = {}}})", .{ws_id}) catch null;
    }
    return std.fmt.bufPrint(buf, "dispatch workspace {}", .{ws_id}) catch null;
}

// Tests

test "hyprland-ws-codec: splitByN keeps the tail intact and pads the gaps" {
    const t = std.testing;

    const two = splitByN(2, "DP-2,2");
    try t.expectEqualStrings("DP-2", two[0]);
    try t.expectEqualStrings("2", two[1]);

    // One field: the whole line, no commas consumed.
    const one = splitByN(1, "0xabc");
    try t.expectEqualStrings("0xabc", one[0]);

    // The last field swallows everything after the (count-1)-th comma.
    const four = splitByN(4, "0x1,2,otter-term,Fixture, Window Title");
    try t.expectEqualStrings("0x1", four[0]);
    try t.expectEqualStrings("2", four[1]);
    try t.expectEqualStrings("otter-term", four[2]);
    try t.expectEqualStrings("Fixture, Window Title", four[3]);

    const three = splitByN(3, "a,b,c");
    try t.expectEqualStrings("a", three[0]);
    try t.expectEqualStrings("b", three[1]);
    try t.expectEqualStrings("c", three[2]);

    // Short and empty payloads pad out rather than throwing or reading past
    // the end — `decodeInt("")` is how the caller notices.
    const short = splitByN(3, "a");
    try t.expectEqualStrings("a", short[0]);
    try t.expectEqualStrings("", short[1]);
    try t.expectEqualStrings("", short[2]);

    const empty = splitByN(2, "");
    try t.expectEqualStrings("", empty[0]);
    try t.expectEqualStrings("", empty[1]);
}

test "hyprland-ws-codec: decodeHex parses bare and 0x-prefixed hex" {
    const t = std.testing;
    // Value table covering both spellings plus the rejects; see the module comment.
    try t.expect(decodeHex("") == null);
    try t.expectEqual(@as(u64, 26), decodeHex("0x1a").?);
    try t.expectEqual(@as(u64, 26), decodeHex("0X1A").?);
    try t.expectEqual(@as(u64, 26), decodeHex("1a").?);
    try t.expect(decodeHex("0x") == null);
    try t.expect(decodeHex("x1") == null);
    try t.expectEqual(@as(u64, 0), decodeHex("0").?);
    try t.expectEqual(@as(u64, 0), decodeHex("00").?);
    try t.expect(decodeHex("-1") == null);
    try t.expect(decodeHex("+1") == null);
    try t.expectEqual(@as(u64, 94405641248352), decodeHex("0x55dc86b61e60").?);
    try t.expectEqual(@as(u64, 0xffff), decodeHex("ffff").?);
    try t.expectEqual(@as(u64, std.math.maxInt(u64)), decodeHex("ffffffffffffffff").?);
    try t.expect(decodeHex("10000000000000000") == null); // 2^64, out of range
    try t.expect(decodeHex("fffffffffffffffff") == null); // 68 bits, out of range
    try t.expectEqual(@as(u64, 1), decodeHex("0000000000000000000000001").?);
    try t.expect(decodeHex(" 1a") == null);
    try t.expect(decodeHex("1a ") == null);
    try t.expectEqual(@as(u64, 94405641248352), decodeHex("0x55DC86B61E60").?);
}

test "hyprland-ws-codec: decodeInt parses whole-field integers" {
    const t = std.testing;
    try t.expect(decodeInt("") == null);
    try t.expectEqual(@as(i32, 0), decodeInt("0").?);
    try t.expectEqual(@as(i32, 2), decodeInt("2").?);
    try t.expectEqual(@as(i32, -1), decodeInt("-1").?);
    try t.expect(decodeInt("+1") == null); // from_chars takes no plus sign
    try t.expectEqual(@as(i32, 1), decodeInt("01").?);
    try t.expectEqual(@as(i32, 2147483647), decodeInt("2147483647").?);
    try t.expect(decodeInt("2147483648") == null);
    try t.expectEqual(@as(i32, -2147483648), decodeInt("-2147483648").?);
    try t.expect(decodeInt("-2147483649") == null);
    try t.expect(decodeInt("99999999999999999999") == null);
    try t.expect(decodeInt("1 ") == null); // no trailing garbage
    try t.expect(decodeInt(" 1") == null); // no leading whitespace
    try t.expect(decodeInt("1a") == null);
    try t.expect(decodeInt("2abc") == null);
    try t.expect(decodeInt("-") == null);
    try t.expect(decodeInt("+") == null);
    try t.expect(decodeInt("0x10") == null);
    try t.expect(decodeInt("9223372036854775808") == null);
}

test "hyprland-ws-codec: findIdForName matches sscanf %ld plus the int range check" {
    const t = std.testing;
    try t.expectEqual(@as(i32, -1), findIdForName(""));
    try t.expectEqual(@as(i32, -1), findIdForName(" "));
    try t.expectEqual(@as(i32, 2), findIdForName("2"));
    try t.expectEqual(@as(i32, -1), findIdForName("-1")); // negative ids rejected
    try t.expectEqual(@as(i32, 0), findIdForName("0"));
    try t.expectEqual(@as(i32, 7), findIdForName(" 7"));
    try t.expectEqual(@as(i32, 7), findIdForName("  7"));
    try t.expectEqual(@as(i32, 7), findIdForName("+7")); // sscanf does take a plus
    try t.expectEqual(@as(i32, 2), findIdForName("2abc")); // scan stops at 'a'
    try t.expectEqual(@as(i32, -1), findIdForName("abc"));
    try t.expectEqual(@as(i32, 2147483647), findIdForName("2147483647"));
    try t.expectEqual(@as(i32, -1), findIdForName("2147483648"));
    try t.expectEqual(@as(i32, -1), findIdForName("-2"));
    try t.expectEqual(@as(i32, 2), findIdForName("2.5"));
    try t.expectEqual(@as(i32, 9), findIdForName("\t9"));
    try t.expectEqual(@as(i32, 11), findIdForName("\n11"));
    try t.expectEqual(@as(i32, -1), findIdForName("99999999999999999999999999"));
    try t.expectEqual(@as(i32, 2), findIdForName("2 3"));
    try t.expectEqual(@as(i32, 0), findIdForName("0x2")); // stops at 'x', gives 0
    try t.expectEqual(@as(i32, -1), findIdForName("18446744073709551615"));
    try t.expectEqual(@as(i32, -1), findIdForName("-"));
}

test "hyprland-ws-codec: jumpCommand picks the syntax the session understands" {
    const t = std.testing;
    var buf: [80]u8 = undefined;

    const lua = jumpCommand(&buf, true, 3).?;
    try t.expectEqualStrings("dispatch hl.dsp.focus({workspace = 3})", lua);

    // The plain form is what Hyprland wants until the config provider is lua —
    // it is also the form that fails against a live lua session, which is the
    // whole reason this has to be a runtime choice.
    const plain = jumpCommand(&buf, false, 3).?;
    try t.expectEqualStrings("dispatch workspace 3", plain);

    try t.expect(jumpCommand(buf[0..8], true, 3) == null); // no truncation
}
