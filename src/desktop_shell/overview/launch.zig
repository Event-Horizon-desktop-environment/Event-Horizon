//! Launch modes for the standalone `horizon-overview` process.
//!
//! The dock and taskbar spawn the binary with no arguments and rely on the
//! singleton lock's toggle semantics. IPC (`overview-open`/`overview-close`)
//! and the supervisor's Super+Tab path need explicit modes, so both sides
//! share this parser: the supervisor writes the flag, the overview reads it.

const std = @import("std");

pub const Mode = enum { toggle, open, close };

/// Parse `argv` (including `argv[0]`). No recognised flag means toggle.
pub fn fromArgs(args: []const []const u8) Mode {
    if (args.len < 2) return .toggle;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--open")) return .open;
        if (std.mem.eql(u8, a, "--close")) return .close;
        if (std.mem.eql(u8, a, "--toggle")) return .toggle;
    }
    return .toggle;
}

/// Parse the word form used by the generic `overview <mode>` IPC command.
/// Returns null for anything else so the handler can answer with usage.
pub fn fromWord(word: []const u8) ?Mode {
    if (std.mem.eql(u8, word, "toggle")) return .toggle;
    if (std.mem.eql(u8, word, "open")) return .open;
    if (std.mem.eql(u8, word, "close")) return .close;
    return null;
}

pub fn flag(mode: Mode) [:0]const u8 {
    return switch (mode) {
        .toggle => "--toggle",
        .open => "--open",
        .close => "--close",
    };
}

test "overview launch: flags parse, no flag and junk mean toggle" {
    const t = std.testing;
    try t.expectEqual(Mode.toggle, fromArgs(&.{"horizon-overview"}));
    try t.expectEqual(Mode.toggle, fromArgs(&.{ "horizon-overview", "--toggle" }));
    try t.expectEqual(Mode.open, fromArgs(&.{ "horizon-overview", "--open" }));
    try t.expectEqual(Mode.close, fromArgs(&.{ "horizon-overview", "--close" }));
    try t.expectEqual(Mode.open, fromArgs(&.{ "horizon-overview", "--open", "--close" }));
    try t.expectEqual(Mode.toggle, fromArgs(&.{ "horizon-overview", "--bogus" }));
    try t.expectEqual(Mode.toggle, fromArgs(&.{}));
}

test "overview launch: IPC words and flags round-trip" {
    const t = std.testing;
    try t.expectEqual(Mode.toggle, fromWord("toggle").?);
    try t.expectEqual(Mode.open, fromWord("open").?);
    try t.expectEqual(Mode.close, fromWord("close").?);
    try t.expect(fromWord("") == null);
    try t.expect(fromWord("OPEN") == null);
    try t.expectEqualStrings("--toggle", flag(.toggle));
    try t.expectEqualStrings("--open", flag(.open));
    try t.expectEqualStrings("--close", flag(.close));
}
