//! `[dock] islands` specs, shared by the dock's layout and the Settings
//! editor.
//!
//! One spec groups slots into a single floating pill. Specs are the entries
//! of `[dock] islands`:
//!
//!   * `'media'` — that widget alone (the original form);
//!   * `'media+clock'` — both widgets, linked into one pill when they are
//!     adjacent in the strip;
//!   * `'@left'`, `'@center'`, `'@right'` — every widget in that section,
//!     as one island. A section spec can be combined with ids, so
//!     `'@center+media'` links a left-section media widget to the center
//!     block when the two meet.
//!
//! Order is significant: the first spec that matches a slot owns it. That
//! lets a whole-section spec take precedence while explicit groups keep the
//! widgets outside that section together.

const std = @import("std");

pub const Section = enum(u2) {
    left = 0,
    center = 1,
    right = 2,

    pub fn tag(self: Section) []const u8 {
        return switch (self) {
            .left => "@left",
            .center => "@center",
            .right => "@right",
        };
    }

    pub fn fromCol(col: usize) Section {
        return switch (col) {
            0 => .left,
            1 => .center,
            else => .right,
        };
    }

    pub fn fromTag(part: []const u8) ?Section {
        if (std.mem.eql(u8, part, "@left")) return .left;
        if (std.mem.eql(u8, part, "@center")) return .center;
        if (std.mem.eql(u8, part, "@right")) return .right;
        return null;
    }
};

/// Whether `spec` puts `token` in the island group for `section`.
/// Empty members (stray `+`) are ignored.
pub fn specMatches(spec: []const u8, token: []const u8, section: Section) bool {
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (Section.fromTag(part)) |sec| {
            if (sec == section) return true;
        } else if (std.mem.eql(u8, part, token)) {
            return true;
        }
    }
    return false;
}

/// Index of the first spec that owns `token` in `section`, or null when the
/// widget shares the bar. Equal indexes mean "same island".
pub fn groupIndex(specs: []const []const u8, token: []const u8, section: Section) ?usize {
    for (specs, 0..) |spec, i| {
        if (specMatches(spec, token, section)) return i;
    }
    return null;
}

/// Whether every id in `ids` belongs to the same island group.
pub fn sectionIslanded(specs: []const []const u8, ids: []const []const u8, section: Section) bool {
    if (ids.len == 0) return hasSectionTag(specs, section);
    const first = groupIndex(specs, ids[0], section) orelse return false;
    for (ids[1..]) |id| {
        const group = groupIndex(specs, id, section) orelse return false;
        if (group != first) return false;
    }
    return true;
}

pub fn hasSectionTag(specs: []const []const u8, section: Section) bool {
    for (specs) |spec| {
        var it = std.mem.splitScalar(u8, spec, '+');
        while (it.next()) |part| {
            if (Section.fromTag(part)) |sec| {
                if (sec == section) return true;
            }
        }
    }
    return false;
}

test "island specs: widgets, linked groups and section tags" {
    const t = std.testing;
    const specs = [_][]const u8{ "media+clock", "@center" };
    try t.expect(specMatches(specs[0], "media", .left));
    try t.expect(specMatches(specs[0], "clock", .right));
    try t.expect(!specMatches(specs[0], "weather", .left));
    try t.expectEqual(@as(?usize, 0), groupIndex(&specs, "media", .left));
    try t.expectEqual(@as(?usize, 0), groupIndex(&specs, "clock", .center));
    try t.expectEqual(@as(?usize, 1), groupIndex(&specs, "trash", .center));
    try t.expectEqual(@as(?usize, null), groupIndex(&specs, "trash", .right));

    try t.expect(sectionIslanded(&specs, &.{ "overview", "trash" }, .center));
    try t.expect(!sectionIslanded(&specs, &.{ "overview", "clock" }, .center));
    try t.expect(sectionIslanded(&specs, &.{ "media", "clock" }, .left));
    try t.expect(!sectionIslanded(&specs, &.{ "media", "weather" }, .right));
    try t.expect(hasSectionTag(&specs, .center));
}

test "island specs: a section can be linked with explicit widgets" {
    const t = std.testing;
    const specs = [_][]const u8{"@center+media"};
    try t.expectEqual(@as(?usize, 0), groupIndex(&specs, "clock", .center));
    try t.expectEqual(@as(?usize, 0), groupIndex(&specs, "media", .left));
    try t.expectEqual(@as(?usize, null), groupIndex(&specs, "weather", .left));
}
