# Installing on Gentoo

This guide covers building and running Event Horizon on Gentoo Linux. Event Horizon is a Wayland desktop shell (not a compositor), so you need a supported Wayland compositor (Hyprland, Niri, Sway, Mango, Labwc, etc.) installed and working.

> Package names/USE flags can vary by overlay and profile. Adjust as needed for your system.

## Prerequisites

- A working Wayland session/compositor
- `git`, a working toolchain, and `sudo`/root access for installing packages
- Internet access (to fetch Zig 0.16.0 if your system Zig is too old)

## Step 1: Install dependencies

Event Horizon needs Zig (>= 0.16.0), `pkg-config`, Wayland development files, and several libraries (cairo, pango, librsvg, libwebp, PipeWire, libxkbcommon, PAM, etc.).

Example (package atoms may differ on your system/overlays):

```bash
sudo emerge --ask --verbose \
  dev-vcs/git \
  dev-util/pkgconf \
  dev-lang/zig \
  dev-libs/wayland \
  dev-libs/wayland-protocols \
  dev-util/wayland-scanner \
  x11-libs/libxkbcommon \
  x11-libs/cairo \
  x11-libs/pango \
  gnome-base/librsvg \
  media-libs/libwebp \
  media-video/pipewire \
  sys-libs/pam \
  net-misc/curl \
  app-arch/xz-utils \
  gnome-extra/zenity
```

Notes:
- **Zig version:** Event Horizon requires Zig >= 0.16.0. If Gentoo’s `dev-lang/zig` is older, `./build.sh` can download the official Zig 0.16.0 into `~/.cache/event-horizon/` (recommended: keep using the script’s managed Zig rather than forcing a system install).
- **PAM:** required for the lock screen (headers/libs must be available at build time).
- **zenity:** used for file/folder picker dialogs (e.g. wallpaper selection). Without it, wallpaper picking/palette generation may not work as expected.
- **PipeWire:** required for the sound mixer; ensure PipeWire (and wireplumber/pulse compatibility if you use them) is running in your session.

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
- If you want to build without installing: `./build.sh --no-install` (outputs to `.zig-out-release/bin`).
- To avoid automatic dependency installation attempts: `./build.sh --skip-deps`.
- CPU tuning options and more: see [../build-sh.md](../build-sh.md).

> `./build.sh` has built-in dependency handling for some distros; on Gentoo you may need to install dependencies yourself (as above) and use `--skip-deps` if the script doesn’t recognize Portage.

## Step 4: Optional runtime services

Install/enable services you want the shell to integrate with (features hide if unavailable):
- **NetworkManager** (`net-misc/networkmanager`) for network UI
- **BlueZ** (`net-wireless/bluez`) for Bluetooth
- **UPower** (`sys-power/upower`) for battery info
- **Polkit** (`sys-auth/polkit`) for privilege prompts
- **udisks2** (`sys-fs/udisks`) for disk/mount handling
- **power-profiles-daemon** if available for your setup

Enable services per your init system (OpenRC/systemd).

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

If `pkg-config` can’t find a library, install the corresponding development package and ensure the `.pc` file is visible in `PKG_CONFIG_PATH` (if non-standard).
