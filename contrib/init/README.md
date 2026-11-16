# Init / session integration

Event Horizon (`horizon`) is a **desktop shell supervisor** intended to run inside a user Wayland session. In most setups it should be started by your compositor (e.g. Hyprland `exec-once = horizon`, Sway/Niri startup config, etc.), not as a system boot service.

## systemd (user session)

No dedicated systemd user unit is required for normal use. Start `horizon` from your compositor autostart. If you use systemd user services for optional components (PipeWire, portals, etc.), Event Horizon can interact with them when present.

## OpenRC / runit / dinit / s6 (and other non-systemd inits)

- Start `horizon` from your compositor’s autostart in a logged-in Wayland session with `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY` set.
- If your session uses **elogind** (common on OpenRC/runit systems), `loginctl`/inhibitor functionality may be available depending on setup. Event Horizon’s idle/lock integration is best-effort and will fall back where systemd-specific tools are unavailable.
- Do not run `horizon` as a root system service; it needs access to the user’s Wayland session.

Example snippets in this directory are provided as starting points only and may need adaptation for your distro/init and session manager.
