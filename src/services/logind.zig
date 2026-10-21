const std = @import("std");

pub const SleepKind = enum { sleep, shutdown, reboot };

pub fn parsePrepareForSleep(body: []const u8) ?bool {
    for (body) |c| {
        if (c == '1') return true;
        if (c == '0') return false;
    }
    return null;
}

pub fn inhibitWhat() []const u8 {
    return "sleep:shutdown";
}

pub fn inhibitWho() []const u8 {
    return "EventHorizon";
}

pub fn inhibitWhy() []const u8 {
    return "shell session management";
}

test "logind: sleep signal + inhibit strings" {
    const t = std.testing;
    try t.expect(parsePrepareForSleep("1") == true);
    try t.expect(parsePrepareForSleep("0") == false);
    try t.expect(parsePrepareForSleep("") == null);
    try t.expectEqualStrings("sleep:shutdown", inhibitWhat());
}
