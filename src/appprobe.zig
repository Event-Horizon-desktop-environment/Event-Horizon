const std = @import("std");
const app_mod = @import("ux/settings2/app.zig");
const rows = @import("ux/settings2/rows.zig");
pub fn main() !void {
    std.debug.print("n_cats={d}\n", .{app_mod.sidebar_categories.len});
    for (app_mod.sidebar_categories) |cat| {
        std.debug.print("cat {d} subs={d} cards0={d}\n", .{ cat.id, cat.subs.len, rows.cardsFor(cat.id, 0).len });
        for (cat.subs) |s| {
            std.debug.print("  sub {d} cards={d}\n", .{ s.tab_id, rows.cardsFor(s.tab_id, 0).len });
        }
    }
}
