const std = @import("std");
const eh = @import("eh");

// horizon-settings entry: 900x980 settings window, 260px sidebar with 7
// categories, card content, search, scroll. Sole writer of config.toml.
// The window itself is ux/settings/window.zig (layer-shell + Cairo).

pub fn main(init: std.process.Init) !u8 {
    return eh.settings_window.run(init);
}
