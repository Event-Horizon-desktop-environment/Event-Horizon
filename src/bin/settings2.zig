const std = @import("std");
const eh = @import("eh");

// settings entry — the redesigned UX (design B: rail and list).
// 900x980 window, 80px icon rail + 224px page list + content with a fixed
// page header (eyebrow + h1). Ported from ux/settings into ux/settings2 so
// the original horizon-settings binary stays untouched while the redesign
// lands. Sole writer of config.toml, same as the original.

pub fn main(init: std.process.Init) !u8 {
    return eh.settings2_window.run(init);
}
