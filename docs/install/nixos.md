# Installing on NixOS

This guide covers building and running Event Horizon on NixOS. NixOS is declarative and does not use a mutable `/usr` in the usual way, so the standard `./build.sh` install flow (which installs to `/usr`) is **not** the recommended path. Instead, build in a dev shell and install to a user/system path managed by Nix or your home directory.

Event Horizon is a Wayland desktop shell (not a compositor). You still need a supported Wayland compositor (Hyprland, Niri, Sway, Mango, Labwc, etc.) running in your session.

## Prerequisites

- A working Wayland compositor/session
- `git`
- Nix with flakes enabled (recommended), or classic `nix-shell`
- PAM available on the system (for the lock screen). On NixOS this is provided by the system PAM configuration/packages.

## Option 1: Flake dev shell (recommended)

This fork includes a `flake.nix` with a development shell that provides Zig (>= 0.16.0) and the native libraries needed to build Event Horizon.

```bash
git clone https://github.com/visadaking/Event-Horizon.git
cd Event-Horizon

# enter the dev environment
nix develop

# build without installing to /usr
./build.sh --no-install --skip-deps
# or build with zig directly:
# zig build -Doptimize=ReleaseFast
```

Build outputs (with `--no-install`) are placed in `.zig-out-release/` by `build.sh`. If you use `zig build` directly, outputs go to `zig-out/` by default.

## Option 2: Classic `nix-shell`

A `shell.nix` is also provided:

```bash
git clone https://github.com/visadaking/Event-Horizon.git
cd Event-Horizon
nix-shell
./build.sh --no-install --skip-deps
```

## Installing the binaries

Because `/usr` is not mutable on NixOS, install the built programs to a location in your `PATH` (for example `~/.local/bin`) and the data files to appropriate XDG/system locations, or package/manage them declaratively.

### Manual user-local install (from build output)

After building:

```bash
# binaries
install -Dm755 .zig-out-release/bin/* ~/.local/bin/ 2>/dev/null || \
  install -Dm755 zig-out/bin/* ~/.local/bin/

# ensure ~/.local/bin is in PATH (add to your shell/profile or Nix config)
export PATH="$HOME/.local/bin:$PATH"
```

You will also need the runtime data/assets the shell expects (icons, theme templates, etc.) installed to locations it can find (typically under `/usr/share` in upstream assumptions). If the shell cannot find its data files when installed outside `/usr`, prefer running from a Nix package/derivation that installs into the Nix store and sets paths appropriately, or adjust install paths to match what the binaries expect.

> **Tip:** For a fully declarative setup, consider creating a Nix derivation/package for Event Horizon in your configuration/flake (using the provided dev dependencies as `nativeBuildInputs`/`buildInputs`) and adding it to `environment.systemPackages` or Home Manager.

## Runtime services and dependencies

Event Horizon integrates with common desktop services (all optional; features hide if unavailable):
- **PipeWire / WirePlumber** (audio/mixer): `services.pipewire.enable = true;` etc.
- **NetworkManager** (network UI): `networking.networkmanager.enable = true;`
- **Bluetooth**: `hardware.bluetooth.enable = true;`
- **UPower** (battery): `services.upower.enable = true;`
- **Polkit** (privilege prompts): `security.polkit.enable = true;` (and run a polkit agent if needed)
- **udisks2** (disks): `services.udisks2.enable = true;`
- **power-profiles-daemon**: `services.power-profiles-daemon.enable = true;`
- **zenity** (file/folder pickers, wallpaper selection/palette generation): include `zenity` in your user/system packages

## Starting Event Horizon

Run from within your Wayland session:

```bash
horizon
```

Or autostart it from your compositor config (see [../usage.md](../usage.md#autostart)). Check status with `eh-ipc status` and open settings with `horizon-settings`.

## Logs and troubleshooting

- Logs: `~/EH-logs/` (one file per process)
- Status: `eh-ipc status`
- Troubleshooting: [../usage.md](../usage.md#troubleshooting)

Notes for NixOS:
- If Zig in nixpkgs is older than 0.16.0 on your channel, use a newer channel, `nixpkgs-unstable`, or a Zig-providing flake/input that supplies >= 0.16.0.
- The lock screen requires working PAM; ensure your NixOS PAM configuration is intact.
- `./build.sh` without `--no-install` will attempt to install into `/usr` and is not suitable for NixOS.
