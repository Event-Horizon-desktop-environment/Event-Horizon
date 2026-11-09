# Development notes

This page is for people who want to build by hand, work on the code, or understand how the repository is laid out. If you just want to install Event Horizon, use the guide for your distribution and [build-sh.md](build-sh.md).

## Building by hand

`build.sh` is a wrapper around `zig build`. If you want to drive Zig yourself, you need Zig 0.16.0 or newer and the same development libraries the script would install. Check [build-sh.md](build-sh.md) and your distro guide for package names. Do not forget PAM.

```bash
zig build -Doptimize=ReleaseFast                       # this machine's default CPU target
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v2
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v3
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v4
```

The programs end up in `zig-out/bin/`. Always use `ReleaseFast` when you want to actually run the shell. The default Debug build is much slower and larger.

The libraries the build needs are these:

| Dependency | Used for |
|---|---|
| Zig 0.16.0 or newer | Compiler and build system |
| `pkg-config` | Finding the native libraries |
| `wayland-client`, `wayland-protocols`, `wayland-scanner` | Talking to the compositor and generating protocol code |
| `libxkbcommon` | Keyboard handling |
| `cairo` | Drawing |
| `pango` and `pangocairo` | Text layout |
| `librsvg` | SVG icons |
| `libwebp` | Wallpaper thumbnails |
| `libpipewire-0.3` | The sound mixer, and the tests |
| `pam` | Lock screen authentication |
| `curl` or `wget`, `tar`, `xz` | Downloading Zig when needed |
| `zenity`, or `kdialog`, or `yad` | At runtime, for file and folder dialogs |

### A user-local install without the script

```bash
zig build -Doptimize=ReleaseFast --prefix ~/.local
zig build install-icons --prefix ~/.local/share
export PATH="$HOME/.local/bin:$PATH"
```

One rule to remember: `horizon` starts its parts from the folder that `horizon` itself lives in, and does not search `PATH`. Install all the programs together, or run them directly out of `zig-out/bin/`.

For a system-wide install use `./build.sh`. It installs the programs and the runtime data together and never picks up stale files left in `zig-out/`.

## Programs and build steps

Each program has its own build step, so you can rebuild just one while working on it.

| Program | Build step | Purpose |
|---|---|---|
| `horizon` | `horizon` | Supervisor and entry point |
| `eh-ipc` | `ipc` | One-shot IPC client |
| `horizon-dock` | `dock` | The dock |
| `horizon-taskbar` | `taskbar` | The taskbar |
| `horizon-desktop` | `desktop` | Desktop surface and icons |
| `horizon-desktop-widgets` | `desktop-widgets` | Desktop widget host |
| `horizon-settings` | `settings2` | The settings app |
| `horizon-overview` | `overview` | Workspace and window overview |
| `horizon-notifications` | `notifications` | Notification service and popups |
| `horizon-polkit-agent` | `polkit-agent` | PolicyKit authentication agent |
| `horizon-wallpaper` | `wallpaper` | Wallpaper renderer |
| `horizon-clipstack` | `clipstack` | Clipboard history service |
| `horizon-clipstack-pick` | `clipstack-pick` | Clipboard picker |
| `horizon-idle` | `idle` | Idle timers, screen blanking, suspend, hibernate |
| `horizon-lock` | `lock` | Lock screen |
| `horizonClipboardDaemon` | `clipboard` | Holds the clipboard for screenshots |
| `horizon-audio-center` | `audio-center` | Sound mixer and routing |

Other steps:

```bash
zig build test                          # unit tests
zig build run                           # build and start the supervisor
zig build install-icons --prefix ~/.local/share
```

## Tests

```bash
zig build test
zig build test -Doptimize=ReleaseSafe
```

The default test root is `src/tests.zig`. You can pick another with `-Dtest-root=path/to/root.zig`. The tests build the same protocol bindings and native libraries as the shell, including PipeWire.

There are separate security tests for the bundled image decoder and the screenshot writer:

```bash
python3 scripts/test_image_security.py
zig build test -Dtest-root=src/security_tests.zig
```

The Python script needs a C compiler with AddressSanitizer and UndefinedBehaviorSanitizer. A second script, `scripts/test_install_security.py`, checks the install branches of `build.sh`.

Image loading has hard limits that act as security controls. Cover art is limited to 4 megapixels and wallpapers to 16 megapixels. The decoder allows at most 128 MiB for a single allocation and 256 MiB across all decoders at once. Images over these limits are rejected before they are shown. PNG decompression must match the declared image exactly, including interlaced images. Please do not loosen these numbers.

## Repository layout

```text
build.sh                  Dependency setup, CPU detection, build and install
build.zig                 The build graph and every program target
build.zig.zon             Package metadata, with the minimum Zig version
protocols/                Wayland protocol XML files, copied from upstream
matugen/                  Theme configs and templates for other applications
assets/                   Icons, fonts, branding and interface artwork
third_party/stb/          Image decode and encode headers
src/
    main.zig              Process entry and command line handling
    cli.zig               Argument parsing
    bootstrap/            Supervisor, starting components, screenshot mode
    backends/             Hyprland, Niri, Sway, Mango and Labwc support
    config/               TOML parser, layered loader, schema, file watchers
    desktop_shell/        Dock, taskbar, desktop, overlays, widgets, shell interface
    services/             D-Bus clients: notifications, tray, audio, polkit, media
    wl/                   Wayland connection, layer surfaces, capture, input
    wallpaper/            Decoding, rendering, slideshow, thumbnails
    color/                The Material You color engine and theme templates
    clipstack/            Clipboard history storage, capture and picker
    m3/                   Material 3 widget toolkit and design tokens
    text/                 Text measurement and layout
    ux/                   Settings, sound mixer, shared application interface
```

Rendering is done on the CPU. Cairo and Pango draw into shared-memory buffers, librsvg draws icons, and libwebp handles thumbnails. There is no GTK, Qt or GPU toolkit in the shell.

Settings live in TOML under `~/.config/Event-Horizon/` and are described in [usage.md](usage.md#configuration-files).

Each program is its own process with its own Wayland connection. If you add a new one, it has to be added in several places: the program list in `build.zig`, the list of installed programs in `build.sh`, the table above, and, if the program is optional, the spawn rules in `src/bootstrap/spawn.zig`.
