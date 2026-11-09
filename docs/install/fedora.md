# Installing on Fedora

This guide covers Fedora, and the Red Hat style systems the build script treats the same way: RHEL, CentOS, Rocky Linux and AlmaLinux. It goes from a working install with a Wayland compositor to a running Event Horizon shell. The steps were written with Fedora in mind. On the enterprise distributions, some package names or versions may differ, and the script's own check will tell you what it could not find.

If you are on Arch or a Debian family system, use [the Arch guide](arch.md) or [the Debian guide](debian.md) instead.

## Before you start

You need three things already in place.

A working Wayland compositor. Event Horizon does not include one. Install Hyprland, Niri, Sway, Mango or Labwc, log in to it once, and make sure you can open a terminal. Fedora's default GNOME session is not a supported compositor for Event Horizon, so you will be switching sessions at the login screen. If you want to use my Hyprland or Zoolander config, read [hyprland-setup.md](../hyprland-setup.md) or [zoolander-setup.md](../zoolander-setup.md) after you finish here.

An internet connection, because the build script may download the Zig compiler.

A regular user account with `sudo` rights. You will run the build as that user, not as root.

## Step 1: Update the system

```bash
sudo dnf upgrade --refresh
```

Reboot if the update replaced the kernel.

## Step 2: Install git

```bash
sudo dnf install git
```

## Step 3: Install PAM

The lock screen checks your password through PAM, and the build needs the PAM development files. On Fedora that is the `pam-devel` package.

```bash
sudo dnf install pam-devel
```

This is the one package the build script does not install for you, so do not skip it. If you do, the dependency step will say everything is fine and then the build will fail partway through.

## Step 4: Install the build dependencies (optional)

The script installs these for you if they are missing, so you can skip to Step 5. If you prefer to see what is going on, or you want to install them yourself first, this is the exact list the script uses on Fedora:

```bash
sudo dnf install pkgconf-pkg-config wayland-devel wayland-protocols-devel \
  libxkbcommon-devel cairo-devel pango-devel librsvg2-devel libwebp-devel \
  pipewire-devel curl xz zenity
```

Here is what each one is for.

| Package | Why Event Horizon needs it |
|---|---|
| `pkgconf-pkg-config` | Lets the build find the other libraries. |
| `wayland-devel`, `wayland-protocols-devel` | Talking to the compositor. |
| `libxkbcommon-devel` | Keyboard handling. |
| `cairo-devel`, `pango-devel` | Drawing the interface and text. |
| `librsvg2-devel` | Drawing SVG icons. |
| `libwebp-devel` | Wallpaper thumbnails. |
| `pipewire-devel` | The sound mixer. |
| `curl`, `xz` | Downloading and unpacking Zig. |
| `zenity` | The folder and file picker dialogs. Without it you cannot choose a wallpaper folder, and the color palette is never generated. |

You do not need to install Zig yourself. The build script uses the one on your system if it is version 0.16.0 or newer, and otherwise downloads the official 0.16.0 release into `~/.cache/event-horizon/`. Fedora's packaged Zig may or may not be new enough on your release, and the script handles either case.

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

The script builds for the highest CPU level your processor supports. That is a good default if you are only installing on this machine. If you are going to copy the result to another machine, add `--cpu v3` or `--cpu v2`. All the options are explained in [build-sh.md](../build-sh.md).

If the prompt for your password never appears, you may be on a plain TTY or an SSH session with no graphical authentication agent. Either run the script from a terminal inside your desktop session, or build with `./build.sh --no-install` and read the manual install notes in [build-sh.md](../build-sh.md#manual-install).

### A note about SELinux

Fedora runs SELinux in enforcing mode by default. Event Horizon installs ordinary programs into `/usr/bin` and does not need any special SELinux setup. If something fails mysteriously only on Fedora, check `sudo ausearch -m avc -ts recent` for denials before assuming the shell is at fault.

## Step 7: Install the services Event Horizon talks to

Event Horizon uses a few system services. All of them are optional, and the matching parts of the shell hide themselves if the service is missing. A standard Fedora install already has most of them. Install what you are missing.

```bash
sudo dnf install pipewire-pulseaudio wireplumber NetworkManager bluez upower polkit udisks2 power-profiles-daemon
```

What each is for:

| Package | What it enables |
|---|---|
| `pipewire-pulseaudio`, `wireplumber` | Volume control and the sound mixer. My configs also call `wpctl`, which comes with WirePlumber. |
| `NetworkManager` | The Wi-Fi, wired and VPN pages and the network popup. |
| `bluez` | Bluetooth. |
| `upower` | Battery information. |
| `polkit` | Administrator prompts, shown by Event Horizon's own password dialog. |
| `udisks2` | Mounted drive handling. |
| `power-profiles-daemon` | Switching between power profiles. |

Turn on the ones that need to be running:

```bash
sudo systemctl enable --now NetworkManager bluetooth upower
```

Fedora usually has these running already. If a service is already active, that command does no harm.

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
| The build stops complaining about `pam` or `security/pam_appl.h` | Run `sudo dnf install pam-devel` and try again. |
| `wayland-scanner` not found | `sudo dnf install wayland-devel` |
| `pkg-config` cannot find `librsvg-2.0`, `cairo`, `pangocairo`, `libwebp` or `libpipewire-0.3` | Install the matching `-devel` package from Step 4. |
| `horizon` runs but nothing appears | Run `eh-ipc status`. Also check that all programs were installed to the same folder. |
| No wallpaper picker window | `sudo dnf install zenity` |
| No audio devices in the sound mixer | Make sure PipeWire is running: `systemctl --user status pipewire`. |

More fixes are in [usage.md](../usage.md#troubleshooting). The logs are in `~/EH-logs/`.
