//! Root for the standalone `horizon-overview` process. The real main lives
//! in `bin/overview.zig`; this file exists so its relative imports stay
//! inside the module package.

const ov = @import("bin/overview.zig");

pub const main = ov.main;
