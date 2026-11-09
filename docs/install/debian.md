# Installing on Debian and Ubuntu

This guide covers Debian and the systems the build script treats as part of its family: Ubuntu, Linux Mint, Pop!_OS, PikaOS, Zorin OS and elementary OS. It goes from a working install with a Wayland compositor to a running Event Horizon shell.

If you are on Arch or Fedora, use [the Arch guide](arch.md) or [the Fedora guide](fedora.md) instead.

## Before you start

You need three things already in place.

A working Wayland compositor. Event Horizon does not include one. Sway is in the Debian archive and can be installed with `sudo apt install sway`. Hyprland, Niri, Mango and Labwc may or may not be packaged for your release, so check your distribution or the compositor's own install instructions. Log in to the compositor once and make sure you can open a terminal. If you want to use my Hyprland or Zoolander config, read [hyprland-setup.md](../hyprland-setup.md) or [zoolander-setup.md](../zoolander-setup.md) after you finish here.

An internet connection. This matters more on Debian than elsewhere, because Debian and Ubuntu usually carry an older Zig than Event Horizon needs. The build script will download the official Zig 0.16.0 for you, but only if it can reach ziglang.org.

A regular user account with `sudo` rights. You will run the build as that user, not as root.

## Step 1: Update the system

```bash
sudo apt update
sudo apt upgrade
```

Reboot if the update replaced the kernel.

## Step 2: Install git and the build tools

```bash
sudo apt install git build-essential
```

## Step 3: Install PAM

The lock screen checks your password through PAM, and the build needs the PAM development files. On Debian and Ubuntu that is the `libpam0g-dev` package.

```bash
sudo apt install libpam0g-dev
```

This is the one package the build script does not install for you, so do not skip it. If you do, the dependency step will say everything is fine and then the build will fail partway through.

## Step 4: Install the build dependencies (optional)

The script installs these for you if they are missing, so you can skip to Step 5. If you prefer to see what is going on, or you want to install them yourself first, this is the exact list the script uses on Debian:

```bash
sudo apt install pkg-config libwayland-dev libwayland-bin wayland-protocols \
  libxkbcommon-dev libcairo2-dev libpango1.0-dev librsvg2-dev libwebp-dev \
  libpipewire-0.3-dev curl xz-utils zenity
```

Here is what each one is for.

| Package | Why Event Horizon needs it |
|---|---|
| `pkg-config` | Lets the build find the other libraries. |
| `libwayland-dev`, `wayland-protocols` | Talking to the compositor. |
| `libwayland-bin` | Provides `wayland-scanner` on Debian, which the build runs. If this is missing, the build says `wayland-scanner` is not found. |
| `libxkbcommon-dev` | Keyboard handling. |
| `libcairo2-dev`, `libpango1.0-dev` | Drawing the interface and text. |
| `librsvg2-dev` | Drawing SVG icons. |
| `libwebp-dev` | Wallpaper thumbnails. |
| `libpipewire-0.3-dev` | The sound mixer. |
| `curl`, `xz-utils` | Downloading and unpacking Zig. |
| `zenity` | The folder and file picker dialogs. Without it you cannot choose a wallpaper folder, and the color palette is never generated. |

You do not need to install Zig yourself, and you should not try to use the one from `apt`. It is almost certainly too old. The build script checks, and if the system Zig is below 0.16.0 it prints a warning and downloads the official release into `~/.cache/event-horizon/zig-0.16.0/`. Nothing is installed system-wide.

Older releases such as stable Debian and Ubuntu LTS can ship older versions of PipeWire and the Wayland libraries. If `pkg-config` cannot find `libpipewire-0.3` after you install the package, the release is probably too old. Upgrading to a newer release is the cleanest fix.

## Step 5: Get the source

```bash
git clone https://github.com/Event-Horizon-desktop-environment/Event-Horizon.git
cd Event-Horizon
```

## Step 6: Build and install

```bash
./build.sh
```

Run it as your normal user. If anything is missing, the script runs `apt-get update` and `apt-get install` for you, which asks for your password. When the build finishes, a password prompt appears for the install step. Enter your password. The script then copies the programs to `/usr/bin`, the icons and theme templates to `/usr/share`, and prints a final line saying it is installed.

The script builds for the highest CPU level your processor supports. That is a good default if you are only installing on this machine. If you are going to copy the result to another machine, add `--cpu v3` or `--cpu v2`. All the options are explained in [build-sh.md](../build-sh.md).

If the prompt for your password never appears, you may be on a plain TTY or an SSH session with no graphical authentication agent. Either run the script from a terminal inside your desktop session, or build with `./build.sh --no-install` and read the manual install notes in [build-sh.md](../build-sh.md#manual-install).

## Step 7: Install the services Event Horizon talks to

Event Horizon uses a few system services. All of them are optional, and the matching parts of the shell hide themselves if the service is missing. A desktop install of Debian or Ubuntu already has most of them. Install what you are missing.

```bash
sudo apt install pipewire-pulse wireplumber network-manager bluez upower policykit-1 udisks2 power-profiles-daemon
```

On recent releases the `policykit-1` package has been split up. If `apt` says it cannot find it, install `polkitd` and `pkexec` instead.

What each is for:

| Package | What it enables |
|---|---|
| `pipewire-pulse`, `wireplumber` | Volume control and the sound mixer. My configs also call `wpctl`, which comes with WirePlumber. |
| `network-manager` | The Wi-Fi, wired and VPN pages and the network popup. |
| `bluez` | Bluetooth. |
| `upower` | Battery information. |
| `policykit-1` (or `polkitd` and `pkexec`) | Administrator prompts, shown by Event Horizon's own password dialog. |
| `udisks2` | Mounted drive handling. |
| `power-profiles-daemon` | Switching between power profiles. |

Debian normally starts services as soon as they are installed. If one is not running, start it with `sudo systemctl enable --now NetworkManager bluetooth upower`.

## Step 8: Start the shell

The quick test is to run it from a terminal inside your Wayland session:

```bash
horizon
```

The dock should appear. In another terminal you can check that everything started:

```bash
eh-ipc status
```

To have it start by itself every time, add one line to your compositor's config. The line for each compositor is in [usage.md](../usage.md#autostart).

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
| The build stops complaining about `pam` or `security/pam_appl.h` | Run `sudo apt install libpam0g-dev` and try again. |
| `wayland-scanner` not found | `sudo apt install libwayland-bin` |
| `pkg-config` cannot find `librsvg-2.0`, `cairo`, `pangocairo`, `libwebp` or `libpipewire-0.3` | Install the matching `-dev` package from Step 4. |
| `horizon` runs but nothing appears | Run `eh-ipc status`. Also check that all programs were installed to the same folder. |
| No wallpaper picker window | `sudo apt install zenity` |
| No audio devices in the sound mixer | Make sure PipeWire is running: `systemctl --user status pipewire`. |
| The Zig download fails | Check that your machine can reach ziglang.org, or download Zig 0.16.0 yourself from there and pass it with `--zig /path/to/zig`. |

More fixes are in [usage.md](../usage.md#troubleshooting). The logs are in `~/EH-logs/`.
