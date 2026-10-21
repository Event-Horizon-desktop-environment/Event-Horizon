//! Recorded compositor IPC fixtures, exposed to the rest of the build as one
//! module.
//!
//! These are checked-in recordings of a live Hyprland session, PII scrubbed,
//! so replay tests drive the real payload shapes rather than hand-written
//! approximations.
//!
//! They live outside `src/`, and Zig's package path for every module in this
//! build starts at that module's root file — which is inside `src/`. A plain
//! `@embedFile("../../testdata/…")` from a source file is therefore rejected as
//! reaching outside the package, so the build wires this file in as the
//! `testdata` module instead (see `shellModule` in `build.zig`).

pub const hyprland = struct {
    pub const workspaces = @embedFile("backends/hyprland/workspaces.json");
    pub const monitors = @embedFile("backends/hyprland/monitors.json");
    pub const clients = @embedFile("backends/hyprland/clients.json");
    pub const status = @embedFile("backends/hyprland/status.json");
    pub const events = @embedFile("backends/hyprland/events.jsonl");
};
