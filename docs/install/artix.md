# Installing on Artix Linux

This guide covers Artix Linux (and other Arch-based systems). Event Horizon is a Wayland desktop shell (not a compositor), so you need a supported Wayland compositor (Hyprland, Niri, Sway, Mango, Labwc, etc.) installed and working.

Artix is Arch-based and uses `pacman`, so the build dependencies are the same as Arch. The main difference is the **init system** (runit, OpenRC, dinit, or s6) — enable runtime services using your init’s tools instead of `systemctl` where applicable.

## Prerequisites

- A working Wayland session/compositor
- `git`, `sudo` (or root) access
- Internet access (to fetch Zig 0.16.0 if your system Zig is too old)

## Step 1: Install dependencies

```bash
sudo pacman -Syu
sudo pacman -S --needed git base-devel pam \
  pkgconf wayland wayland-protocols libxkbcommon \
  cairo pango librsvg libwebp pipewire \
  curl xz zenity
```

Notes:
- **PAM:** required for the lock screen (install `pam` if not already present).
- **Zig version:** Event Horizon requires Zig >= 0.16.0. `./build.sh` will use a system Zig if compatible, otherwise it downloads Zig 0.16.0 to `~/.cache/event-horizon/`.
- **zenity:** used for file/folder picker dialogs (e.g. wallpaper selection/palette generation).

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
- `./build.sh` detects Arch-family systems and can install missing build dependencies via `pacman` (Artix is treated as Arch-family in most cases).
- Build without installing: `./build.sh --no-install` (outputs to `.zig-out-release/bin`).
- See [../build-sh.md](../build-sh.md) for all options.

## Step 4: Optional runtime services

Install/enable services you want the shell to integrate with (features hide if unavailable):
- **PipeWire/WirePlumber** for audio/mixer
- **NetworkManager** (or your preferred network stack) for network UI
- **BlueZ** (`bluez`, `bluez-utils`/init scripts packages as needed) for Bluetooth
- **UPower** for battery info
- **Polkit** and an agent for privilege prompts
- **udisks2** for disk/mount handling
- **power-profiles-daemon** if desired

Enable/start them using your Artix init system (runit: symlink to `/run/runit/service/` or your service dir; OpenRC: `rc-update add ...`; dinit/s6: use their respective service management).

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
