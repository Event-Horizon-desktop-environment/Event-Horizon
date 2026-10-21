const std = @import("std");

pub const Mods = struct {
    super: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
};

pub const Shortcut = struct {
    mods: Mods = .{},
    key: []const u8 = "",
};

fn lowerKey(k: []const u8, buf: []u8) []const u8 {
    return std.ascii.lowerString(buf[0..@min(k.len, buf.len)], k[0..@min(k.len, buf.len)]);
}

pub fn parse(s: []const u8) ?Shortcut {
    if (s.len == 0) return null;
    var sc = Shortcut{};
    var it = std.mem.splitScalar(u8, s, '+');
    var kb: [32]u8 = undefined;
    var found_key = false;
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) return null;
        const low = lowerKey(part, &kb);
        if (std.mem.eql(u8, low, "super") or std.mem.eql(u8, low, "meta") or std.mem.eql(u8, low, "win")) {
            sc.mods.super = true;
        } else if (std.mem.eql(u8, low, "alt")) {
            sc.mods.alt = true;
        } else if (std.mem.eql(u8, low, "ctrl") or std.mem.eql(u8, low, "control")) {
            sc.mods.ctrl = true;
        } else if (std.mem.eql(u8, low, "shift")) {
            sc.mods.shift = true;
        } else {
            if (found_key) return null;
            sc.key = part;
            found_key = true;
        }
    }
    if (!found_key) return null;
    return sc;
}

test "shortcuts: parse combos" {
    const t = std.testing;
    const a = parse("Super+Space").?;
    try t.expect(a.mods.super);
    try t.expectEqualStrings("Space", a.key);
    const b = parse("Ctrl+Shift+T").?;
    try t.expect(b.mods.ctrl and b.mods.shift);
    try t.expect(parse("") == null);
    try t.expect(parse("Super+") == null);
    try t.expect(parse("A+B") == null);
}
