# Installing on openSUSE

This guide covers openSUSE (Tumbleweed/Leap) and SUSE-family systems. Event Horizon is a Wayland desktop shell (not a compositor), so you need a supported Wayland compositor (Hyprland, Niri, Sway, Mango, Labwc, etc.) installed and working.

## Prerequisites

- A working Wayland session/compositor
- `git`, `sudo` (or root) access
- Internet access (to fetch Zig 0.16.0 if your system Zig is too old)

## Step 1: Install dependencies

`./build.sh` already detects SUSE-family systems and can install dependencies via `zypper`, but it does **not** install PAM development files. Install PAM headers first, then the rest:

```bash
sudo zypper refresh
sudo zypper install -y pam-devel
sudo zypper install -y \
  git pkg-config \
  wayland-devel wayland-protocols-devel \
  libxkbcommon-devel cairo-devel pango-devel librsvg-devel libwebp-devel \
  pipewire-devel \
  curl xz zenity
```

Notes:
- **Zig version:** Event Horizon requires Zig >= 0.16.0. If openSUSE’s `zig` package is older/unavailable, `./build.sh` can download the official Zig 0.16.0 into `~/.cache/event-horizon/`.
- **PAM:** `pam-devel` is required for the lock screen build.
- **zenity:** used for file/folder picker dialogs (e.g. wallpaper selection/palette generation).
- Package names can vary slightly between Tumbleweed and Leap; adjust if `zypper` reports missing names.

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

## Step 4: Optional runtime services

Install/enable services you want the shell to integrate with (features hide if unavailable):
- **PipeWire/WirePlumber** for audio/mixer
- **NetworkManager** for network UI
- **BlueZ** (`bluez`) for Bluetooth
- **UPower** for battery info
- **Polkit** and an agent for privilege prompts
- **udisks2** for disk/mount handling
- **power-profiles-daemon** if desired

Enable/start services via `systemctl` as appropriate for your openSUSE setup.

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
