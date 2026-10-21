//! Root for the standalone `horizon-taskbar` process. The real main lives
//! in `bin/taskbar.zig`; this file exists so its relative imports stay
//! inside the module package.

const tb = @import("bin/taskbar.zig");

pub const main = tb.main;
