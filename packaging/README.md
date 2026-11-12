# Packaging

This directory contains distro-specific packaging scaffolding for this fork.

- `gentoo/event-horizon/event-horizon-9999.ebuild` — Gentoo live ebuild template (Portage overlay/local repo). Adjust dependencies/USE flags and install paths as needed for your overlay and Event Horizon release.
- `void/srcpkgs/event-horizon/template` — Void Linux (xbps-src) template. Update `checksum`, build/install steps, and dependencies as needed for the target version/commit.

These are provided as starting points for NixOS/Gentoo/Void users and may require tweaks to match upstream build/install layout, required Zig version, and system policies.
