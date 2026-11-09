# Using Event Horizon

This page covers everyday running of the shell: starting it, the command line tools, where settings live, how idle and the lock screen behave, where the logs are, and what to do when something is wrong.

## Starting the shell

Run this from inside a Wayland session:

```bash
horizon
```

Do not run it from a plain TTY or from X11. It needs a compositor to talk to.

`horizon` is a supervisor. It does not draw anything itself. It starts the other programs, watches them, and restarts any that crash. The ones it keeps alive are the wallpaper, desktop, dock, taskbar, notifications, the polkit agent, clipboard history and the idle manager. The settings app, the lock screen and the overview start only when something asks for them.

A few more options:

```bash
horizon --both       # start the full shell, the same as no option
horizon --help
horizon --version
```

Whether the dock and taskbar are actually shown is controlled by settings, not by `horizon`. The dock follows `[dock] show_dock`, which is on by default. The taskbar follows `[taskbar] enabled`, which is off by default. You can change both in the settings app.

If a component crashes, the supervisor restarts it. The first few restarts are immediate, and after repeated crashes it backs off, waiting one second, then five, then thirty. If a program is stuck in that loop, its log in `~/EH-logs/` will show why.

## Autostart

Normally your compositor should start `horizon` for you. Add the matching line to your compositor's config.

**Hyprland, classic config.** In `~/.config/hypr/hyprland.conf`:

```conf
exec-once = horizon
```

**Hyprland, Lua config.** In a file loaded at startup:

```lua
hl.on("hyprland.start", function()
    hl.exec_cmd("horizon")
end)
```

**Niri.** In `~/.config/niri/config.kdl`:

```kdl
spawn-at-startup "horizon";
```

**Sway.** In `~/.config/sway/config`:

```conf
exec horizon
```

**Mango.** In `~/.config/mango/config.conf`:

```conf
exec-once=horizon
```

**Labwc.** In `~/.config/labwc/autostart`:

```sh
horizon &
```

**Zoolander.** In your Lua config, inside the startup handler:

```lua
zl.on("startup", function()
    zl.exec_command("horizon")
end)
```

My complete Hyprland and Zoolander setups, including everything else they start, are explained in [hyprland-setup.md](hyprland-setup.md) and [zoolander-setup.md](zoolander-setup.md).

## Keys the shell handles itself

Event Horizon reads the keyboard directly, so a few shortcuts work even if your compositor has nothing bound to them.

| Keys | What happens |
|---|---|
| Tap the Super key by itself | Opens the app menu. Pressing any other key while Super is held cancels it. |
| Super+S | Opens or closes the settings app. |
| Super+Tab | Opens or closes the overview. |
| Super+Shift+S | Region screenshot with a live preview. |
| Print Screen on its own | Screenshot of the monitor under the cursor. |
| Alt+Print Screen | Screenshot of every monitor stitched into one wide image. |

Print Screen with Super or Ctrl held is left to your compositor, so a bind there will not capture twice.

If these do nothing, the shell may not be able to read your keyboard device. Check the log of the `horizon` process in `~/EH-logs/`, and make sure your user is allowed to read input devices.

If your compositor also binds one of these key combinations, you can get both actions at once. In my Hyprland config, for example, Super+S toggles a scratch workspace and Super+Tab is bound to the overview. That is worth knowing when you copy bits of config between machines.

## The eh-ipc tool

The supervisor listens on a socket at `$XDG_RUNTIME_DIR/event-horizon-ipc.sock`. `eh-ipc` sends it one command and prints the answer. If you need a different socket location, set `EH_IPC_SOCKET`.

```bash
eh-ipc ping              # answers pong if the shell is running
eh-ipc version
eh-ipc status            # state of every component: running, idle, restarting, disabled
eh-ipc help              # list the commands
eh-ipc lock              # start the lock screen
eh-ipc overview-toggle   # show or hide the overview
eh-ipc overview-open     # show it, and do nothing if it is already open
eh-ipc overview-close    # hide it, and do nothing if it is already closed
eh-ipc screenshot ...    # take a screenshot, arguments below
```

These are the commands that exist in version 0.1.4. The list printed by `eh-ipc help` is always the authority for the version you have installed. In particular, there is no `dashboard-toggle` command, even though my sample configs bind Alt+Tab to one. See the notes in the setup docs.

If `eh-ipc` says `Is Event Horizon running?`, the supervisor is not running, or `EH_IPC_SOCKET` points at the wrong place.

## Screenshots

`eh-ipc screenshot` hands its arguments to the shell's own screenshot mode, which you can also call directly as `horizon --eh-screenshot`. Both forms accept the same arguments.

```bash
horizon --eh-screenshot shot.png                     # the monitor under the cursor
horizon --eh-screenshot --select shot.png            # draw a region with the mouse
horizon --eh-screenshot --geometry 800x600+100+50 shot.png
horizon --eh-screenshot --around-mouse 400x300 shot.png
horizon --eh-screenshot --all-monitors panorama.png
horizon --eh-screenshot --list-windows
horizon --eh-screenshot --window <id> window.png
```

Useful extras:

| Flag | Effect |
|---|---|
| `--cursor` | Include the mouse pointer in the image. |
| `--output NAME` | Capture a particular monitor, such as `DP-1`. |
| `--no-clipboard` | Do not copy the result to the clipboard. |
| `--slurp` | Use the external `slurp` tool to pick the region instead of the built-in picker. |
| `--preview` | Show a preview before saving. This is what the shell's own key shortcuts use. |

By default the image is written to disk and also handed to the clipboard daemon, so you can paste it straight away.

## Configuration files

Everything lives under your XDG config folder:

```text
~/.config/Event-Horizon/
    settings.toml
    <component>/<component>.toml
```

You rarely need to edit these by hand, because the settings app writes them. If you do edit them, the shell watches the files and reloads them live, so there is no restart.

The shell reads and merges the files in this order, with later ones winning:

1. Every `*.toml` file directly in `~/.config/Event-Horizon/`, sorted by file name.
2. `~/.config/Event-Horizon/settings.toml`
3. `~/.config/Event-Horizon/<component>/<component>.toml`

So a value in a component file overrides the same value in `settings.toml`.

### Trying things safely

To test without touching your real configuration, start the shell in an isolated profile:

```bash
EH_ZIG_ISOLATED=1 horizon
```

This uses `~/.config/Event-Horizon-zig` instead of `~/.config/Event-Horizon`. Setting the variable to `0` or leaving it empty turns it off.

### Environment variables

| Variable | What it does |
|---|---|
| `EH_IPC_SOCKET` | Use a different path for the IPC socket. |
| `EH_ZIG_ISOLATED` | Use the separate config folder described above. |
| `EH_LOCK_PAM_SERVICE` | Choose which PAM service the lock screen authenticates against. The default is `login`. |
| `EH_MATUGEN_ROOT` | Point the color engine at a particular folder of theme templates. |

## Idle, sleep and the lock screen

The idle manager is `horizon-idle`. It reads two parts of the config, `[power]` and `[idle.behavior.*]`.

If you have not written any `[idle.behavior.*]` entries, it works out two timers from `[power]`. The display turns off after `display_sleep_timeout` minutes. The machine suspends after `idle_suspend_timeout` minutes, and it starts the lock screen a few seconds before suspending. Both of these are on the Power page of the settings app.

If you want more control, write behaviors yourself. When you do, yours win:

```toml
[idle.behavior.lock]
timeout = 300           # seconds
command = "lock"

[idle.behavior.sleep]
timeout = 1800
command = "suspend"     # or "hibernate"
resume_command = "dpms:on"

[idle.behavior.custom]
timeout = 60
command = "notify-send idle"
```

The commands the idle manager understands on its own are `lock`, `suspend` (or `sleep`), `hibernate`, `dpms:off`, `dpms:on`, `dpms:standby` and `dpms:suspend`. Anything else is run as a shell command. For screen blanking it tries `wlopm`, then `hyprctl`, then `swaymsg`, using the first that is installed. If you use another compositor, install `wlopm`.

The idle manager also watches for the system's sleep signal. If something outside Event Horizon suspends the machine, such as closing a laptop lid, it starts the lock screen first.

The lock screen is `horizon-lock`. It locks every monitor using the standard session-lock protocol and checks your password through PAM. It uses the same wallpaper and clock format as your desktop, so the two match. It exits by itself after you unlock. You can start it any time with `eh-ipc lock` or by running `horizon-lock`.

By default it authenticates against the PAM service named `login`, which every distribution has. If you want a dedicated PAM configuration, set `EH_LOCK_PAM_SERVICE` to its name.

## Logs

Every process writes its own log to `~/EH-logs/<name>.log`. Examples are `~/EH-logs/EventHorizon-zig.log` and `~/EH-logs/horizon-dock-zig.log`. When a log reaches 64 MiB it is moved to `<name>.log.old` and a fresh one is started.

When something misbehaves, the order to follow is: run `eh-ipc status` to see which part is unhappy, then read that part's log.

## Troubleshooting

| Symptom | What to do |
|---|---|
| `wayland-scanner` not found during the build | Install the Wayland package for your distro. It is `libwayland-bin` on Debian. |
| `pkg-config` cannot find `librsvg-2.0`, `cairo`, `pangocairo`, `libwebp` or `libpipewire-0.3` | Install the matching `-dev` or `-devel` package. |
| Build fails mentioning PAM | Install the PAM development package. It is `pam-devel` on Fedora and `libpam0g-dev` on Debian. |
| The build says Zig is too old | Let `build.sh` download Zig, or install 0.16.0 or newer from ziglang.org. |
| `horizon` runs but no dock appears | Run `eh-ipc status`. Make sure every program was installed to the same folder as `horizon`. Check that `[dock] show_dock` has not been turned off. |
| `eh-ipc` says `Is Event Horizon running?` | The supervisor is not running, or `EH_IPC_SOCKET` points at the wrong socket. |
| The sound mixer shows no devices | PipeWire is not running. |
| The wallpaper page does not let you choose a folder | Install `zenity`. `kdialog` or `yad` also work. |
| The colors never change to match the wallpaper | A wallpaper has to be chosen first. Without a folder picker, none can be, so see the previous row. |
| Battery or Bluetooth widgets are missing | The shell hides them when UPower or BlueZ are not running. Install and start them. |
| Screen never turns off when idle | Install `wlopm` if you are not on Hyprland or Sway. |
| The lock screen rejects the right password | Try another PAM service with `EH_LOCK_PAM_SERVICE`. |
