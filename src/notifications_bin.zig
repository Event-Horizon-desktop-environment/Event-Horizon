//! Root for the standalone `horizon-notifications` process. The real main lives
//! in `bin/notifications.zig`; this file exists so its relative imports stay
//! inside the module package.

const notif = @import("bin/notifications.zig");

pub const main = notif.main;
