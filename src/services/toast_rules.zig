const std = @import("std");
const notifs = @import("notifications.zig");
const cfg_notifs = @import("../config/schema2.zig");

pub const Decision = struct {
    show_toast: bool = true,
    save_history: bool = true,
    play_sound: bool = false,
    bypass_dnd: bool = false,
};

pub fn applyRules(rules: []const cfg_notifs.NotificationRule, app: []const u8, urgency: notifs.Urgency) Decision {
    var d = Decision{};
    for (rules) |r| {
        if (r.match.len > 0 and std.mem.indexOf(u8, app, r.match) == null) continue;
        const allowed = switch (urgency) {
            .low => r.allow_low,
            .normal => r.allow_normal,
            .critical => r.allow_critical,
        };
        if (!allowed) {
            d.show_toast = false;
            d.save_history = false;
            continue;
        }
        d.show_toast = d.show_toast and r.show_toast;
        d.save_history = d.save_history and r.save_history;
        d.play_sound = d.play_sound or r.play_sound;
        d.bypass_dnd = d.bypass_dnd or r.bypass_dnd;
    }
    return d;
}

test "toast-rules: match + urgency gate" {
    const t = std.testing;
    const rules = [_]cfg_notifs.NotificationRule{
        .{ .name = "w", .match = "work", .play_sound = true },
        .{ .name = "quiet", .match = "spam", .show_toast = false, .allow_normal = false },
    };
    const a = applyRules(&rules, "work-chat", .normal);
    try t.expect(a.show_toast and a.play_sound);
    const b = applyRules(&rules, "spam-app", .normal);
    try t.expect(!b.show_toast and !b.save_history);
    const c = applyRules(&rules, "other", .low);
    try t.expect(c.show_toast);
}
