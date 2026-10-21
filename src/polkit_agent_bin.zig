//! Root for the standalone `horizon-polkit-agent` process. The real main lives
//! in `bin/polkit_agent.zig`; this file exists so its relative imports stay
//! inside the module package.

const agent = @import("bin/polkit_agent.zig");

pub const main = agent.main;
