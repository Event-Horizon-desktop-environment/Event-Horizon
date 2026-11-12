# Installing on Void Linux

This guide covers building and running Event Horizon on Void Linux (xbps). Event Horizon is a Wayland desktop shell (not a compositor), so you need a supported Wayland compositor (Hyprland, Niri, Sway, Mango, Labwc, etc.) installed and working.

## Prerequisites

- A working Wayland session/compositor
- `git`, `sudo` (or root) access
- Internet access (to fetch Zig 0.16.0 if your system Zig is too old)

## Step 1: Install dependencies

Install the build tools and libraries Event Horizon links against:

```bash
sudo xbps-install -Su
sudo xbps-install -S \
  git base-devel pkg-config \
  zig \
  wayland-devel wayland-protocols \
  libxkbcommon-devel \
  cairo-devel pango-devel librsvg-devel libwebp-devel \
  pipewire-devel \
  pam-devel \
  curl xz \
  zenity
```

Notes:
- **Zig version:** Event Horizon requires Zig >= 0.16.0. If Void’s `zig` package is older, `./build.sh` can download the official Zig 0.16.0 into `~/.cache/event-horizon/` (use `--skip-deps` if needed and let the script manage Zig, or pass a compatible Zig with `--zig /path/to/zig`).
- **PAM:** required for the lock screen (`pam-devel` provides headers; runtime PAM is part of the base system).
- **zenity:** used for file/folder picker dialogs (e.g. wallpaper selection/palette generation).
- **wayland-scanner:** typically provided by `wayland-devel` on Void.

## Step 2: Get the source

```bash
git clone https://github.com/visadaking/Event-Horizon.git
cd Event-Horizon
```

## Step 3: Build and install

```bash
./build.sh
```

- Run as your normal user (not root). The script may prompt for privileges for the final install step (to `/usr`).
- Build without installing: `./build.sh --no-install` (outputs to `.zig-out-release/bin`).
- Skip automatic dependency installation: `./build.sh --skip-deps`.
- CPU tuning and more options: see [../build-sh.md](../build-sh.md).

> `./build.sh` may not auto-detect `xbps` for dependency installation; if so, install dependencies manually (Step 1) and run with `--skip-deps`.

## Step 4: Optional runtime services

Install/enable services you want the shell to integrate with (features hide if unavailable):
- **PipeWire/WirePlumber** for audio/mixer (`pipewire`, `wireplumber`, and session setup as per Void docs)
- **NetworkManager** (`NetworkManager`) for network UI
- **BlueZ** (`bluez`) for Bluetooth
- **UPower** (`upower`) for battery info
- **Polkit** (`polkit`) and an agent for privilege prompts
- **udisks2** (`udisks2`) for disk/mount handling
- **power-profiles-daemon** (`power-profiles-daemon`) if desired

Enable runit services as appropriate (e.g. symlink service dirs to `/var/service/`).

## Step 5: Start Event Horizon

From inside your Wayland session:

```bash
horizon
```

Or add it to your compositor autostart (see [../usage.md](../usage.md#autostart)).

Useful commands:
- `eh-ipc status` — check component status
- `horizon-settings` — open settings

## Updating

```bash
cd Event-Horizon
git pull
./build.sh
```

Log out and back in so the new binaries are used.

## Troubleshooting

- Logs: `~/EH-logs/`
- Status: `eh-ipc status`
- Common issues and fixes: [../usage.md](../usage.md#troubleshooting)

If the build reports missing libraries, verify the corresponding `*-devel` packages are installed and `pkg-config` can locate them.
