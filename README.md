<img width="3200" height="960" alt="Event Horizon banner" src="https://github.com/user-attachments/assets/709ddf5b-cf76-4e9b-8a48-1a4c43434a42" />

# Event Horizon

**A Wayland-native desktop shell written in Zig.**

Event Horizon runs as a layer-shell client alongside an existing Wayland
compositor and provides the pieces a desktop needs: dock and taskbar, desktop
icons and widgets, launcher and overview, control center, notifications,
lock screen, OSD, wallpaper, settings, clipboard history, screenshots, and
audio control. The shell, its UI toolkit, and the Material You color engine are
implemented in Zig and build with one tool.

Supported compositors: **Hyprland**, **Niri**, **Sway**, **Mango**, and
**Labwc**, with protocol fallbacks for other wlroots-based compositors.

- Zig **0.16.0** or newer
- Linux + Wayland
- MIT licensed

> **Status:** Zig implementation, version `0.1.0` (see `src/version.zig`).
> The old C++/Meson tree has been replaced; the Zig build is the only build.

## What's included

| Area | Components |
|---|---|
| Panels | Dock, taskbar, launcher menu, workspace strip, tray, pinned apps |
| Desktop | Desktop icons, folders, drag and drop, desktop widgets (clock, calendar, weather, media, system monitor, world clock) |
| Overlays | Overview, Spotlight search, launchpad, task switcher, control center, OSD, power confirmation |
| Session | Layer-shell lock screen with PAM authentication, idle inhibition, night light |
| Notifications | `org.freedesktop.Notifications` daemon, toast host, notification rules |
| Wallpaper | Per-output wallpaper engine, slideshow, crossfade, thumbnail cache, palette extraction |
| Theming | Native Material You color engine, matugen-compatible templates, GTK/Qt/terminal/browser themes |
| Settings | Full settings app, per-component TOML persistence, live config reload |
| Utilities | ClipStack clipboard history, screenshot picker, Audio Center, polkit agent |
| Plumbing | Unix-socket IPC, D-Bus clients, compositor backends, global key handling |

Many features degrade gracefully when their service is unavailable (for
example, battery and Bluetooth widgets simply hide when UPower or BlueZ is not
running).

## Build and install

### Quick install (recommended)

`build.sh` is the supported build and install path. It handles the native
dependencies, picks a CPU target, builds with `ReleaseFast`, and installs the
shell system-wide:

```bash
git clone https://github.com/Event-Horizon-desktop-environment/Event-Horizon-Shell.git
cd Event-Horizon-Shell
./build.sh
```

What the script does:

1. Checks for `pkg-config`, `wayland-scanner`, Wayland, xkbcommon, Cairo,
   Pango, librsvg, libwebp, and PipeWire development packages. Missing
   packages are installed with `pacman`, `dnf`, `apt`, or `zypper`.
2. Uses Zig 0.16.0 or newer. If the system Zig is missing or too old, the
   official 0.16.0 tarball is downloaded to
   `~/.cache/event-horizon/zig-0.16.0/`.
3. Detects the best x86-64 level from `/proc/cpuinfo` (`x86_64_v2`,
   `x86_64_v3`, or `x86_64_v4`) and builds with
   `zig build -Doptimize=ReleaseFast -Dcpu=...`.
4. Installs the shell binaries to `/usr/bin`, the icon theme to
   `/usr/share/icons/hicolor`, matugen templates to
   `/usr/share/event-horizon/matugen`, and the license to
   `/usr/share/licenses/event-horizon`.

The install step requests privilege with `pkexec` (or `sudo` when `pkexec` is
not available). `horizon-panel` is not part of the build or install.

Useful options:

| Option | Effect |
|---|---|
| `--cpu v2\|v3\|v4` | Force an x86-64 level instead of auto-detecting |
| `--no-install` | Build into `zig-out/bin` but do not touch `/usr` |
| `--skip-deps` | Do not call the package manager |
| `--deps-only` | Install dependencies and exit |
| `--prefix PATH` | Install under a different prefix (default `/usr`) |
| `--jobs N` | Limit parallel build jobs |
| `--zig PATH` | Use a specific Zig executable |

Examples:

```bash
./build.sh --cpu v3                 # more portable than the detected maximum
./build.sh --no-install --jobs 8    # build only
./build.sh --deps-only              # install dependencies, then stop
```

> **CPU portability:** auto-detection builds for this machine's highest
> supported level. A `v4` binary will not run on a `v3` CPU. Use `--cpu v3` or
> `--cpu v2` when you need to copy the result to older machines.

### Manual build

If you prefer to drive Zig directly:

```bash
zig build -Doptimize=ReleaseFast                       # native/default CPU
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v2
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v3
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v4
```

Outputs are written to `zig-out/bin/`. `ReleaseFast` is recommended; the
default Debug build is considerably slower and larger.

The manual build expects these development packages:

| Dependency | Used for |
|---|---|
| Zig 0.16.0+ | Compiler and build system |
| `pkg-config` | Locating native libraries |
| `wayland-client`, `wayland-protocols`, `wayland-scanner` | Wayland client and protocol code generation |
| `libxkbcommon` | Keyboard handling |
| `cairo` | CPU rendering |
| `pango` / `pangocairo` | Text layout |
| `librsvg` | SVG icon rendering |
| `libwebp` | Wallpaper thumbnails |
| `libpipewire-0.3` | Audio Center and tests |

Representative install commands (package names vary by release):

```bash
# Arch Linux
sudo pacman -S --needed zig pkgconf wayland wayland-protocols libxkbcommon \
  cairo pango librsvg libwebp pipewire

# Fedora
sudo dnf install zig pkgconf-pkg-config wayland-devel wayland-protocols-devel \
  libxkbcommon-devel cairo-devel pango-devel librsvg2-devel libwebp-devel \
  pipewire-devel

# Debian / Ubuntu
sudo apt install pkg-config libwayland-dev wayland-protocols libxkbcommon-dev \
  libcairo2-dev libpango1.0-dev librsvg2-dev libwebp-dev libpipewire-0.3-dev
```

Debian and Ubuntu usually lag behind on Zig. `build.sh` downloads Zig 0.16.0
automatically when needed; for a manual build, install a newer release from
<https://ziglang.org/download/>.

### Manual install

For a user-local install:

```bash
zig build -Doptimize=ReleaseFast --prefix ~/.local
zig build install-icons --prefix ~/.local/share
export PATH="$HOME/.local/bin:$PATH"
```

For a system-wide install, use `./build.sh`; it installs the binaries and
runtime data together, and never picks up stale files from `zig-out/`.

> **Important:** the `horizon` supervisor starts its component binaries from
> the directory containing `horizon` itself — not from `PATH`. Install all
> binaries together, or run them straight out of `zig-out/bin/`.

### Run

```bash
horizon                 # start the shell supervisor
horizon --both          # explicit full shell
horizon --help
horizon --version
```

Start it from inside a Wayland session. The supervisor keeps the wallpaper,
desktop, dock, taskbar, notifications, polkit agent, and ClipStack daemons
alive, serves the IPC socket, and applies night-light settings. Whether the
dock and taskbar are shown is controlled by `[dock] show_dock` and
`[taskbar] enabled`; the taskbar is disabled by default.

### Autostart

**Hyprland** — `~/.config/hypr/hyprland.conf`:

```conf
exec-once = horizon
```

**Niri** — `~/.config/niri/config.kdl`:

```kdl
spawn-at-startup "horizon";
```

**Sway** — `~/.config/sway/config`:

```conf
exec horizon
```

**Mango** — `~/.config/mango/config.conf`:

```conf
exec-once=horizon
```

**Labwc** — `~/.config/labwc/autostart`:

```sh
horizon &
```

## Binaries

`zig build` installs these binaries:

| Binary | Build step | Purpose |
|---|---|---|
| `horizon` | `horizon` | Shell supervisor and entry point |
| `eh-ipc` | `ipc` | One-shot IPC client |
| `horizon-dock` | `dock` | Standalone dock |
| `horizon-taskbar` | `taskbar` | Standalone taskbar |
| `horizon-desktop` | `desktop` | Desktop surface and icons |
| `horizon-desktop-widgets` | `desktop-widgets` | Desktop widget host |
| `horizon-settings` | `settings2` | Settings application |
| `horizon-overview` | `overview` | Workspace/window overview |
| `horizon-notifications` | `notifications` | Notification service and toast host |
| `horizon-polkit-agent` | `polkit-agent` | PolicyKit authentication agent |
| `horizon-wallpaper` | default | Wallpaper renderer |
| `horizon-clipstack` | `clipstack` | Clipboard history daemon |
| `horizon-clipstack-pick` | `clipstack-pick` | Clipboard picker (`Super+V`) |
| `horizonClipboardDaemon` | `clipboard` | Selection owner for screenshot copies |
| `horizon-audio-center` | `audio-center` | PipeWire mixer and routing app |

### Other build steps

```bash
zig build test                     # unit tests
zig build run                      # build and launch the supervisor
zig build horizon                  # shell supervisor only
zig build dock
zig build taskbar
zig build desktop
zig build desktop-widgets
zig build settings2                # produces horizon-settings
zig build overview
zig build notifications
zig build polkit-agent
zig build clipboard
zig build clipstack
zig build clipstack-pick
zig build audio-center
zig build install-icons --prefix ~/.local/share
```

## IPC

The supervisor listens on `$XDG_RUNTIME_DIR/event-horizon-ipc.sock`
(override with `EH_IPC_SOCKET`). The bundled client speaks the legacy
line protocol:

```bash
eh-ipc ping
eh-ipc version
eh-ipc status          # per-component state: running, idle, restarting, disabled
eh-ipc help
eh-ipc overview-toggle # toggle the overview (also bound to Super+Tab in the shell)
eh-ipc overview-open   # idempotent open
eh-ipc overview-close  # idempotent close
eh-ipc screenshot --select shot.png
```

`eh-ipc screenshot ...` forwards its arguments to `horizon --eh-screenshot`.

## Screenshots

```bash
horizon --eh-screenshot shot.png                    # output under the cursor
horizon --eh-screenshot --select shot.png           # draw a region
horizon --eh-screenshot --geometry 800x600+100+50 shot.png
horizon --eh-screenshot --around-mouse 400x300 shot.png
horizon --eh-screenshot --all-monitors panorama.png
horizon --eh-screenshot --list-windows
horizon --eh-screenshot --window <id> window.png
```

Useful flags: `--cursor`, `--output NAME`, `--no-clipboard`, and `--slurp`
for the external `slurp` picker. By default the PNG is written to disk and
also handed to the clipboard daemon, so it can be pasted immediately.

## Configuration

All settings live under the XDG config directory:

```text
~/.config/Event-Horizon/
├── settings.toml
└── <component>/<component>.toml
```

The settings app writes these files. Files are watched and reloaded live, so
hand edits are supported. The loader merges, in order:

1. `~/.config/Event-Horizon/*.toml` (sorted by filename)
2. `~/.config/Event-Horizon/settings.toml`
3. `~/.config/Event-Horizon/<component>/<component>.toml`

Later layers win. Run `horizon-settings` to edit everything with the UI.

For testing against a separate profile without touching your live config:

```bash
EH_ZIG_ISOLATED=1 horizon
```

This uses `~/.config/Event-Horizon-zig` instead.

## Logs and troubleshooting

Each process writes to `~/EH-logs/<tag>.log`, for example
`~/EH-logs/EventHorizon-zig.log` and `~/EH-logs/horizon-dock-zig.log`. Files
rotate at 64 MiB to `<file>.old`.

Common failures:

| Symptom | Fix |
|---|---|
| `wayland-scanner` not found | Install `wayland` / `wayland-protocols` |
| `pkg-config` can't find `librsvg-2.0`, `cairo`, `pangocairo`, `libwebp`, or `libpipewire-0.3` | Install the matching `-dev` / `-devel` packages |
| `zig version` is below 0.16.0 | Install a newer Zig from ziglang.org |
| `horizon` runs but no bar appears | Confirm every binary is in the same directory as `horizon`; run `eh-ipc status` |
| IPC client says `Is Event Horizon running?` | The supervisor is not running, or `EH_IPC_SOCKET` points at the wrong socket |
| Audio Center has no devices | Make sure PipeWire is running |

## Project layout

```text
build.sh                  Dependency setup, CPU detection, build, and install
build.zig                 Zig build graph and all binary targets
build.zig.zon             Package metadata (minimum Zig 0.16.0)
protocols/                Vendored Wayland protocol XML
matugen/                  Compatible configs and output templates
assets/                   Icons, fonts, branding, UI artwork
third_party/stb/          stb image decode/encode headers
src/
├── main.zig              Process entry and CLI dispatch
├── cli.zig               Argument parsing
├── bootstrap/            Supervisor, child spawning, screenshot mode
├── backends/             Hyprland, Niri, Sway, Mango, Labwc backends
├── config/               TOML parser, layered loader, schema, watchers
├── desktop_shell/        Dock, taskbar, desktop, overlays, widgets, shell UI
├── services/             D-Bus clients, notifications, tray, audio, polkit, media
├── wl/                   Wayland connection, layer surfaces, capture, input
├── wallpaper/            Decoding, rendering, slideshow, thumbnails
├── color/                Material You engine and theme templates
├── clipstack/            Clipboard history storage, capture, picker
├── m3/                   Material 3 widget toolkit and design tokens
├── text/                 Text measurement and layout
└── ux/                   Settings, Audio Center, disk tools, shared app UI
```

## Tests

```bash
zig build test
zig build test -Doptimize=ReleaseSafe
```

Security regressions for the vendored image decoder and screenshot writer:

```bash
python3 scripts/test_image_security.py  # C compiler with ASan/UBSan required
zig build test -Dtest-root=src/security_tests.zig
```

Image loading limits cover art to 4 megapixels (4 × 1024²) and wallpapers to
16 megapixels. The stb decoder also limits individual allocations to 128 MiB
and all simultaneous decoder allocations to 256 MiB. Images exceeding these
limits are rejected before display. PNG inflation must match the declared
raster exactly, including interlaced passes.

The default test root is `src/tests.zig`. A different root can be selected
with `-Dtest-root=path/to/root.zig`. Tests build the same protocol bindings
and native libraries as the shell, including PipeWire.

## Credits

- [material-color-utilities](https://github.com/material-foundation/material-color-utilities)
  (Apache-2.0) — ported to Zig under `src/color/mcu/`.
- [stb](https://github.com/nothings/stb) (public domain / MIT) — vendored under
  `third_party/stb/` for image decode and PNG encode.
- [Lucide](https://lucide.dev) (ISC) — icon set under `assets/UI/` and the
  settings apps.
- [Inter](https://rsms.me/inter/) (SIL OFL) — bundled UI typeface under
  `assets/fonts/inter/`.
- [matugen](https://github.com/InioX/matugen) template conventions — the
  configs and templates under `matugen/` are compatible with the native
  color engine.
- Wayland protocol definitions in `protocols/` come from their respective
  upstream projects.

## License

MIT — see [LICENSE](LICENSE).
