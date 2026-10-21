const std = @import("std");
const math = @import("math.zig");
const power = @import("power.zig");
const glyphs = @import("glyphs.zig");

pub const Kind = enum { none, math, power, glyph, windows };

pub const Result = struct {
    kind: Kind,
    title: []const u8,
    subtitle: []const u8 = "",
    value: f64 = 0,
};

pub fn classify(query: []const u8) Kind {
    if (query.len == 0) return .none;
    var has_digit = false;
    var mathy = true;
    for (query) |c| {
        if (c >= '0' and c <= '9') has_digit = true;
        if (!((c >= '0' and c <= '9') or c == ' ' or c == '\t' or c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or c == '^' or c == '(' or c == ')' or c == '.')) {
            mathy = false;
        }
    }
    if (has_digit and mathy and math.evaluate(query) != null) return .math;
    return .windows;
}

pub fn queryMath(query: []const u8) ?Result {
    const v = math.evaluate(query) orelse return null;
    return .{ .kind = .math, .title = query, .value = v };
}

test "spotlight: classify routes math vs windows" {
    const t = std.testing;
    try t.expectEqual(Kind.math, classify("2+2*2"));
    try t.expectEqual(Kind.windows, classify("firefox"));
    try t.expectEqual(Kind.none, classify(""));
    const r = queryMath("10/4").?;
    try t.expectEqual(@as(f64, 2.5), r.value);
    try t.expect(queryMath("nope") == null);
    _ = power;
    _ = glyphs;
}
