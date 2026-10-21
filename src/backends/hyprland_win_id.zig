//! Hyprland window addresses, standalone.
//!
//! A window id is a heap address in hex, and the same window shows up in the
//! IPC stream as `0x55dc86b61e60`, in the toplevel-mapping protocol as two
//! 32-bit halves, and in a UI string as whatever a caller found first. Every
//! comparison goes through the canonical form so those spellings line up.

const std = @import("std");

/// Longest canonical id: `u64` is 16 hex digits, no prefix, no padding.
pub const addr_buf_len = 16;

/// Lowercase hex, unpadded, no `0x`. Returns an empty
/// slice when `buf` is too short, which `addr_buf_len` bytes never is.
pub fn fmtAddress(buf: []u8, addr: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{x}", .{addr}) catch buf[0..0];
}

/// Hex parse over base 16 after dropping a leading `0x`/`0X`. The whole
/// field has to be digits: trailing garbage, a sign, an empty stem (a bare
/// `0x`) and an overflowing value all come back as `null` rather than a
/// truncated number.
pub fn parseHexAddr(in: []const u8) ?u64 {
    if (in.len == 0) return null;
    var s = in;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) s = s[2..];
    if (s.len == 0) return null;
    var result: u64 = 0;
    for (s) |ch| {
        const digit = std.fmt.charToDigit(ch, 16) catch return null;
        result = std.math.mul(u64, result, 16) catch return null;
        result = std.math.add(u64, result, digit) catch return null;
    }
    return result;
}

/// The form a window id is stored and compared in: lowercase hex, no prefix —
/// or an empty slice when `raw` does not parse at all.
pub fn canonicalWindowId(buf: []u8, raw: []const u8) []const u8 {
    const parsed = parseHexAddr(raw) orelse return buf[0..0];
    return fmtAddress(buf, parsed);
}

/// Whether two ids name the same window. Anything that does not parse never
/// matches, which keeps a garbage id from pairing with an empty canonical one.
pub fn idMatch(a: []const u8, b: []const u8) bool {
    var a_buf: [addr_buf_len]u8 = undefined;
    var b_buf: [addr_buf_len]u8 = undefined;
    const ca = canonicalWindowId(&a_buf, a);
    const cb = canonicalWindowId(&b_buf, b);
    return ca.len > 0 and std.mem.eql(u8, ca, cb);
}

// Tests

test "hyprland-win-id: canonical form is lowercase hex without a prefix" {
    const t = std.testing;
    var buf: [addr_buf_len]u8 = undefined;

    try t.expectEqualStrings("55dc86b61e60", fmtAddress(&buf, 0x55dc86b61e60));
    try t.expectEqualStrings("0", fmtAddress(&buf, 0));
    try t.expectEqualStrings("ffffffffffffffff", fmtAddress(&buf, std.math.maxInt(u64)));

    // Every spelling of one address canonicalises the same way...
    try t.expectEqualStrings("55dc86b61e60", canonicalWindowId(&buf, "0x55dc86b61e60"));
    try t.expectEqualStrings("55dc86b61e60", canonicalWindowId(&buf, "0X55DC86B61E60"));
    try t.expectEqualStrings("55dc86b61e60", canonicalWindowId(&buf, "55dc86b61e60"));
    // ...and a non-number canonicalises to nothing rather than to garbage.
    try t.expectEqual(@as(usize, 0), canonicalWindowId(&buf, "").len);
    try t.expectEqual(@as(usize, 0), canonicalWindowId(&buf, "not-an-address").len);
    try t.expectEqual(@as(usize, 0), canonicalWindowId(&buf, "0x").len);
    try t.expectEqual(@as(usize, 0), canonicalWindowId(&buf, "12zz").len);
    try t.expectEqual(@as(usize, 0), canonicalWindowId(&buf, "-1").len);
}

test "hyprland-win-id: idMatch compares canonical forms" {
    const t = std.testing;
    try t.expect(idMatch("0x55dc86b61e60", "55DC86B61E60"));
    try t.expect(idMatch("0", "00"));
    try t.expect(!idMatch("0x55dc86b61e60", "0x55dc86b61e61"));
    // An unparsable side must never match — including the other unparsable one.
    try t.expect(!idMatch("garbage", "garbage"));
    try t.expect(!idMatch("", ""));
    try t.expect(!idMatch("0x55dc86b61e60", "garbage"));
}
