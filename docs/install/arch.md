# Installing on Arch Linux

This guide covers Arch Linux and the distributions the build script treats as Arch: CachyOS, EndeavourOS, Manjaro and Garuda. It goes from a working Arch install with a Wayland compositor to a running Event Horizon shell.

If you are on Fedora or a Debian family system, use [the Fedora guide](fedora.md) or [the Debian guide](debian.md) instead.

## Before you start

You need three things already in place.

A working Wayland compositor. Event Horizon does not include one. Install Hyprland, Niri, Sway, Mango or Labwc from the Arch repositories or the AUR, log in to it once, and make sure you can open a terminal. If you want to use my Hyprland or Zoolander config, read [hyprland-setup.md](../hyprland-setup.md) or [zoolander-setup.md](../zoolander-setup.md) after you finish here.

An internet connection, because the build script may download the Zig compiler.

A regular user account with `sudo` rights. You will run the build as that user, not as root.

## Step 1: Update the system

Arch does not support partial upgrades, so bring everything up to date before installing new packages.

```bash
sudo pacman -Syu
```

Reboot if the update replaced the kernel.

## Step 2: Install git and the base build tools

```bash
sudo pacman -S --needed git base-devel
```

`git` is for downloading the source. `base-devel` is the usual set of build tools. Zig brings its own compiler, but several of the libraries below expect the standard toolchain to be present.

## Step 3: Install PAM

The lock screen checks your password through PAM, and the build needs the PAM development files. On Arch the `pam` package contains both, and it is almost always installed already because it is part of the base system. Run this anyway. It does nothing if it is present.

```bash
sudo pacman -S --needed pam
```

This is the one package the build script does not install for you, so do not skip it.

## Step 4: Install the build dependencies (optional)

The script installs these for you if they are missing, so you can skip to Step 5. If you prefer to see what is going on, or you want to install them yourself first, this is the exact list the script uses on Arch:

```bash
sudo pacman -S --needed pkgconf wayland wayland-protocols libxkbcommon \
  cairo pango librsvg libwebp pipewire curl xz zenity
```

Here is what each one is for.

| Package | Why Event Horizon needs it |
|---|---|
| `pkgconf` | Lets the build find the other libraries. |
| `wayland`, `wayland-protocols` | Talking to the compositor. |
| `libxkbcommon` | Keyboard handling. |
| `cairo`, `pango` | Drawing the interface and text. |
| `librsvg` | Drawing SVG icons. |
| `libwebp` | Wallpaper thumbnails. |
| `pipewire` | The sound mixer. |
| `curl`, `xz` | Downloading and unpacking Zig. |
| `zenity` | The folder and file picker dialogs. Without it you cannot choose a wallpaper folder, and the color palette is never generated. |

You do not need to install Zig yourself. The build script uses the one on your system if it is version 0.16.0 or newer, and otherwise downloads the official 0.16.0 release into `~/.cache/event-horizon/`.

## Step 5: Get the source

```bash
git clone https://github.com/Event-Horizon-desktop-environment/Event-Horizon.git
cd Event-Horizon
```

## Step 6: Build and install

```bash
./build.sh
```

Run it as your normal user. When the build finishes, a password prompt appears for the install step. Enter your password once. The script then copies the programs to `/usr/bin`, the icons and theme templates to `/usr/share`, and prints a final line saying it is installed.

The script builds for the highest CPU level your processor supports. That is a good default if you are only installing on this machine. Several Arch-based distributions already assume a recent CPU, and CachyOS in particular ships packages for x86-64-v3 and v4. If you are going to copy the result to another machine, add `--cpu v3` or `--cpu v2`. All the options are explained in [build-sh.md](../build-sh.md).

If the prompt for your password never appears, you may be on a plain TTY or an SSH session with no graphical authentication agent. Either run the script from a terminal inside your desktop session, or build with `./build.sh --no-install` and read the manual install notes in [build-sh.md](../build-sh.md#manual-install).

## Step 7: Install the services Event Horizon talks to

Event Horizon uses a few system services. All of them are optional, and the matching parts of the shell hide themselves if the service is missing. Install what you want.

```bash
sudo pacman -S --needed pipewire-pulse wireplumber networkmanager bluez bluez-utils upower polkit udisks2 power-profiles-daemon
```

What each is for:

| Package | What it enables |
|---|---|
| `pipewire-pulse`, `wireplumber` | Volume control and the sound mixer. My configs also call `wpctl`, which comes with WirePlumber. |
| `networkmanager` | The Wi-Fi, wired and VPN pages and the network popup. |
| `bluez`, `bluez-utils` | Bluetooth. |
| `upower` | Battery information. |
| `polkit` | Administrator prompts, shown by Event Horizon's own password dialog. |
| `udisks2` | Mounted drive handling. |
| `power-profiles-daemon` | Switching between power profiles. |

Turn on the ones that need to be running:

```bash
sudo systemctl enable --now NetworkManager bluetooth upower
```

Skip any of those you do not want. If your desktop already uses a different network manager, do not install NetworkManager just for this.

## Step 8: Start the shell

The quick test is to run it from a terminal inside your Wayland session:

```bash
horizon
```

The dock should appear. In another terminal you can check that everything started:

```bash
eh-ipc status
```

To have it start by itself every time, add one line to your compositor's config. The line for each compositor is in [usage.md](../usage.md#autostart). For example, on Hyprland the line is `exec-once = horizon` in the classic config.

## Step 9: Open the settings

```bash
horizon-settings
```

If you have not set a wallpaper yet, do that first. Choosing a wallpaper is what makes the shell generate its color palette, so the theme looks right only after you pick one.

## Updating later

```bash
cd Event-Horizon
git pull
./build.sh
```

Then log out and back in so the new programs are the ones running.

## If something goes wrong

| Problem | Fix |
|---|---|
| The build stops complaining about `pam` or `security/pam_appl.h` | Run `sudo pacman -S --needed pam` and try again. |
| `wayland-scanner` not found | `sudo pacman -S --needed wayland` |
| `pkg-config` cannot find `librsvg-2.0`, `cairo`, `pangocairo`, `libwebp` or `libpipewire-0.3` | Install the matching package from Step 4. |
| `horizon` runs but nothing appears | Run `eh-ipc status`. Also check that all programs were installed to the same folder. |
| No wallpaper picker window | Install `zenity`. |
| No audio devices in the sound mixer | Make sure PipeWire is running: `systemctl --user status pipewire`. |

More fixes are in [usage.md](../usage.md#troubleshooting). The logs are in `~/EH-logs/`.
