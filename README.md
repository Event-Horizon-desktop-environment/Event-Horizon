<img width="3200" height="960" alt="Event Horizon banner" src="https://github.com/user-attachments/assets/709ddf5b-cf76-4e9b-8a48-1a4c43434a42" />

# Event Horizon

Event Horizon is a desktop shell for Wayland, written in Zig. It is not a compositor and it does not replace the one you already run. It sits on top of it and supplies the parts of a desktop that a bare compositor leaves out: a dock, an app launcher, desktop icons and widgets, notifications, a lock screen, wallpaper handling, a settings app, clipboard history, screenshots and a sound mixer.

It works with Hyprland, Niri, Sway, Mango and Labwc, and has early support for Zoolander. Other wlroots-based compositors mostly work through protocol fallbacks, though those are the least tested.

Event Horizon is young software. The current version is 0.1.4, there are rough edges, and the Zoolander support is still being built out. If something is broken, the logs described below will usually tell you why, and bug reports are welcome.

## What you need

A Linux machine, a Wayland session, and one of the compositors above already installed and working. Nothing else has to be set up by hand if you use the build script: it installs the development packages it needs and fetches the right version of Zig on its own. The one exception is PAM, which the script does not install for you. Each distro guide below covers it.

The code is MIT licensed.

## Install

Pick the guide for your distribution. Each one is a complete walkthrough from a fresh machine to a running shell.

| Your distro | Guide |
|---|---|
| Arch, CachyOS, EndeavourOS, Manjaro, Garuda | [docs/install/arch.md](docs/install/arch.md) |
| Artix Linux (and other Arch-based, OpenRC/runit/dinit/s6) | [docs/install/artix.md](docs/install/artix.md) |
| Fedora, and RHEL-like systems | [docs/install/fedora.md](docs/install/fedora.md) |
| Debian, Ubuntu, Mint, Pop!_OS, PikaOS | [docs/install/debian.md](docs/install/debian.md) |
| openSUSE / SUSE-family | [docs/install/opensuse.md](docs/install/opensuse.md) |
| NixOS | [docs/install/nixos.md](docs/install/nixos.md) |
| Gentoo (OpenRC/systemd) | [docs/install/gentoo.md](docs/install/gentoo.md) |
| Void Linux (runit) | [docs/install/void.md](docs/install/void.md) |

If you just want the short version and you already have the development packages, it is three commands:

```bash
git clone https://github.com/visadaking/Event-Horizon.git
cd Event-Horizon
./build.sh
```

> **Note:** `./build.sh` installs to `/usr` and expects a mutable FHS layout. On NixOS (and other source-based or non-FHS setups) prefer the distro-specific guide (e.g. `--no-install` builds, Nix dev shell/flake, or local install paths).

The script builds an optimized binary tuned for your CPU and then installs it to `/usr`. It asks for your password once, at the very end. Do not run it with `sudo` yourself.

If you would rather build without installing anything, run `./build.sh --no-install`. Every option the script understands is explained in [docs/build-sh.md](docs/build-sh.md).

## Starting it

Run `horizon` from inside a Wayland session. Normally you want your compositor to start it for you, which takes one line in the compositor config. The line for each supported compositor is in [docs/usage.md](docs/usage.md#autostart).

The `horizon` program is a supervisor. It starts the wallpaper, desktop, dock, notifications, polkit agent and clipboard history, keeps them running, and restarts any that crash. To check on them:

```bash
eh-ipc status
```

Open the settings app with `horizon-settings`. Almost everything in the shell can be changed there, and changes apply live without a restart.

## My own setup

The repository includes the configs I run Event Horizon with, written up so you can copy them or learn from them.

| Document | What it covers |
|---|---|
| [docs/hyprland-setup.md](docs/hyprland-setup.md) | The Hyprland config, file by file, and every keybind |
| [docs/zoolander-setup.md](docs/zoolander-setup.md) | The Zoolander config, file by file, and every keybind |

## Everything else

| Document | What it covers |
|---|---|
| [docs/build-sh.md](docs/build-sh.md) | How `build.sh` works, step by step, with every option |
| [docs/usage.md](docs/usage.md) | Autostart, the IPC tool, screenshots, config files, idle and lock, logs, troubleshooting |
| [docs/development.md](docs/development.md) | Manual builds, the list of programs, project layout, tests |

## When something goes wrong

Every Event Horizon process writes a log file in `~/EH-logs/`, named after the process, for example `~/EH-logs/horizon-dock-zig.log`. That is the first place to look. The second is `eh-ipc status`, which shows which parts of the shell are running, idle, restarting or disabled. The troubleshooting table in [docs/usage.md](docs/usage.md#troubleshooting) lists the common failures and their fixes.

## Supporting the project

If Event Horizon is useful to you and you want to chip in, you can do it through [PayPal](https://paypal.me/gamedev1909) or [Ko-fi](https://ko-fi.com/tlv). Nobody has to, and the shell is not going to nag you about it.

## Credits

Event Horizon uses work from several other projects.

The color engine is a port of [material-color-utilities](https://github.com/material-foundation/material-color-utilities) (Apache-2.0), which lives under `src/color/mcu/`. Image decoding and PNG writing use [stb](https://github.com/nothings/stb) (public domain or MIT), vendored in `third_party/stb/`. Icons come from [Lucide](https://lucide.dev) (ISC). The interface typeface is [Inter](https://rsms.me/inter/) (SIL OFL). The theme templates in `matugen/` follow the conventions of [matugen](https://github.com/InioX/matugen) and work with the built-in color engine. The Wayland protocol files in `protocols/` come from their upstream projects.

## License

GPL. See [LICENSE](LICENSE).
