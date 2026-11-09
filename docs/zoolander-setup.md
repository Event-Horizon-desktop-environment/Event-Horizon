# My Zoolander setup

Zoolander is a Wayland compositor that is configured with Lua. This page explains the Zoolander configuration I run Event Horizon with. It is the same setup as my [Hyprland one](hyprland-setup.md), rewritten for Zoolander, so if you have read that page, most of this will look familiar. The files are in the `zoolander` folder.

Zoolander is a separate project from Event Horizon, with its own documentation at <https://docs.otter-shell.org/zoolander/overview>. Read that for how Zoolander itself works. This page only covers my configuration and how Event Horizon fits with it.

## Event Horizon and Zoolander

Zoolander support arrived in Event Horizon 0.1.2 and is still a work in progress. What works today:

| Area | What Event Horizon does with Zoolander |
|---|---|
| Detection | Recognizes a Zoolander session from its environment markers, desktop hints and control socket. It checks for Zoolander before Hyprland, because the two share some variables. |
| Monitors | The Monitors page in settings reads resolution, refresh rate, scale, rotation, HDR and VRR support, bit depth and EDID information from the compositor. Changes are written back to `~/.config/zoolander/monitors.lua` as `zl.output_rule` entries. |
| Safe display changes | Display and presentation changes show a 15 second "Keep these settings?" prompt. If you do not confirm, the old settings come back by themselves. This also survives a restart, so a bad display change cannot lock you out. |
| Settings pages | A Zoolander section in settings has pages for Keyboard, Mouse and Touchpad, Windows and Borders, Effects, Animations, Decorations, Workspaces and Layouts, and XWayland. They read and write the matching Lua setters and leave your comments and computed values alone. |
| Overview | The overview builds its workspace and window list from the compositor's control socket, including named workspaces, monitor placement and window geometry. Clicking a workspace switches to it. |
| Reloading | After a settings change, Event Horizon reloads the Zoolander config through the control socket first, and falls back to `zoolanderctl` if the socket is not available. Failures are logged and shown in the interface. |
| Clipboard | Clipboard and primary selection use separate sources, because Zoolander rejects a source already bound to a selection. This is what makes screenshot copying work. |

## Using it

Install Zoolander by following its own instructions, then back up any config you have and copy this folder into place:

```bash
mv ~/.config/zoolander ~/.config/zoolander.backup
cp -r zoolander ~/.config/zoolander
```

Log out and choose a Zoolander session, or start it however you normally start it. Event Horizon starts from the config, so you do not need to launch it by hand.

The programs the config calls are the same as in the Hyprland setup: `alacritty`, `ptyxis`, `nautilus`, `thunar`, `zed`, `gedit`, `pavucontrol`, `better-control`, `gnome-system-monitor`, `fuzzel`, `wlogout`, `grim`, `hyprpicker`, `brightnessctl`, `wpctl`, `yad` and `gnome-keyring-daemon`. See the table in [the Hyprland page](hyprland-setup.md#programs-the-config-expects) for what each is used for. This config does not need `hypridle`, `hyprswitch` or `jq`.

Three helper scripts are referenced but not included in this repository.

| Path | Used by |
|---|---|
| `~/.config/ags/scripts/record-script.sh` | The three screen recording binds. |
| `~/.config/quickshell/scripts/switchwall.sh` | Ctrl+Super+T, the wallpaper chooser. |
| `~/.local/bin/fuzzel-emoji` | Super+Period, the emoji picker. |

Unlike the Hyprland setup, workspace switching here does not depend on a script. It is done directly in Lua.

## Reloading

Saving `init.lua` or any other `.lua` file next to it reloads the whole configuration right away. You can also reload by hand with Ctrl+Super+Alt+R, which runs `zoolanderctl reload`.

## How the config is organized

`init.lua` is the entry point. Each of the other files handles one concern.

```text
zoolander/
    init.lua            Entry point. Loads everything, in order.
    colors.lua          Event Horizon color values, shared with window_style.lua.
    layout.lua          Tiling layout.
    input.lua           Keyboard and pointer.
    presentation.lua    Tearing, HDR, X11 scaling.
    window_style.lua    Borders, rounding.
    ssd.lua             Server-side window decorations.
    blur.lua            Blur settings.
    dim.lua             Dimming.
    animations.lua      Window animation.
    bell.lua            Terminal bell sound.
    autostart.lua       Programs started at login.
    keybinds.lua        All keybinds.
    windows.lua         Window and layer rules.
    monitors.lua        Monitor layout.
    env.lua             Environment variables and default apps.
```

The load order in `init.lua` is `colors`, `layout`, `input`, `presentation`, `window_style`, `ssd`, `blur`, `dim`, `animations`, `bell`, `autostart`, `keybinds`, `windows`, `monitors`, `env`. After that, `init.lua` turns animations on with the `ease_in_out_cubic` curve.

## What each file does

### colors.lua

Returns a small table of colors for `window_style.lua` to use. Colors are written as `#RRGGBBAA`, which is a normal hex color followed by a transparency value.

| Name | Value | Meaning |
|---|---|---|
| `active_border` | `#abc7ffeb` | Start color of the focused window border. |
| `active_border_end` | `#8ca3d1b3` | End color of the gradient. |
| `active_border_angle` | 45 | Gradient direction in degrees. |
| `inactive_border` | `#8c919d6b` | Border on windows that are not focused. |

### layout.lua

Sets the layout to dwindle, which splits the screen in half each time you open a window, with a ratio of 0.62. A comment in the file describes that number as Event Horizon's scrolling column ratio. Smart resizing is turned on, so dragging a window edge adjusts the neighboring window the way you would expect.

### input.lua

Keyboard: US layout, Num Lock on at start, 250 ms before repeat and then 35 repeats per second. Pointer: flat acceleration (no acceleration curve), sensitivity 0, and focus follows click. That last one differs from my Hyprland setup, where focus follows the mouse as it moves. In Zoolander you click a window to focus it.

### presentation.lua

Allows screen tearing, which can reduce input lag in games that ask for it. Sets HDR to `auto`. Turns on "force zero scaling" for X11 apps so they are not blurry on scaled monitors.

### window_style.lua

Borders are 0 pixels wide, so there are none to see. The border colors are still set from `colors.lua`, so they take effect if you raise `border_size`. Corners are rounded by 11 pixels with a `rounding_power` of 10, which gives the squarer, smoother corner shape.

### ssd.lua

Server-side decorations are off, meaning Zoolander does not draw title bars on windows. Apps that draw their own are left to do it.

### blur.lua

Blur behind translucent windows and shell surfaces: size 4, four passes, with the same noise, contrast, brightness and vibrancy values as the Hyprland setup. Popups and input method windows are blurred as well.

### dim.lua

Dimming strength 0.24, 0.1 for special workspaces and 0.4 for the area around them. These are the same numbers as my Hyprland config.

### animations.lua

One animation: windows opening. It lasts 180 ms, uses the `ease_out_cubic` curve and slides in by 20 percent.

### bell.lua

Turns off the bell sound.

### autostart.lua

Runs once at the start of a session, and not when you reload the config. It does these things:

| Command | What it does |
|---|---|
| `dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE` | Tells D-Bus and systemd which session is running, so portals find Zoolander. |
| `gnome-keyring-daemon --start --components=secrets` | Starts the secrets store. |
| `horizon` | Starts Event Horizon. |
| `xhost +local:` | Allows local X11 programs to open windows. |
| `ptyxis` | Opens a terminal at login. |

As in the Hyprland setup, do not start the portal programs by hand. They are started through D-Bus, and duplicates cause `Failed to request bus name (File exists)` errors. The `xhost +local:` line turns off X11 access control for local users, so remove it if you do not need it.

### env.lua

Zoolander does not set any `XDG_*` variable by itself, so this file does. `XDG_CURRENT_DESKTOP` is set to `Zoolander` and `XDG_SESSION_TYPE` to `wayland`. It also tells Qt, Firefox and Electron apps to use Wayland, sets Qt's theme to `qt6ct`, and sets the cursor theme to Bibata-Modern-Classic at size 24. The `XCURSOR_THEME` setting is also the cursor Zoolander itself draws. The last block sets the default app names (`terminal`, `fileManager`, `browser`, `codeEditor`, `textEditor`, `volumeMixer`, `settingsApp`, `taskManager`) that the shell and scripts read.

### windows.lua

Window and layer rules.

| Rule | Effect |
|---|---|
| Epic Games Launcher (matched by `app_id`) | Floats, which stops the layout from resizing it over and over. |
| `^(event-horizon-.*)$` layer blur, alpha 0 | Blurs every Event Horizon surface. One wildcard stands in for the long list used in the Hyprland setup, because Zoolander holds at most 32 layer rules. |
| `event-horizon-desktop-shell` layer blur, alpha 1 | Stops the desktop backdrop from blurring. It is added after the wildcard so it wins. |
| `horizon-vinyl`, `dock`, `dock-launcher` layer blur, alpha 0 | Blurs those surfaces too. |

The extra blur rules from the Hyprland config for `ptyxis`, `otter-monitor`, `otter-term`, `cider` and `nautilus` were not carried over.

### monitors.lua

Four `zl.output_rule` entries.

| Output | Mode | Position | Notes |
|---|---|---|---|
| `DP-2` | 2560x1440 at 180 Hz | 0,0 | Left. VRR off, HDR auto, 8-bit. |
| `DP-1` | 2560x1440 at 239.97 Hz | 2560,0 | Middle. Primary monitor. VRR always on, HDR off, 10-bit. |
| `DP-3` | 2560x1440 at 180 Hz | 5120,0 | Right. VRR off, HDR auto, 8-bit. |
| `output` | 1920x1080 at 60 Hz | 7680,0 | The drawing tablet display, see the quirks section. |

Each of the three main monitors also sets an sRGB color profile and brightness values for SDR content (`sdr_min_luminance`, `sdr_max_luminance` and `sdr_eotf` set to `gamma24`), plus the panel's HDR brightness limits (`min_luminance`, `max_luminance`, `max_avg_luminance`).

To use this on your machine, change the output names to yours and set the sizes and positions you want. You can read the real names and modes from the Monitors page in the Event Horizon settings app. That page also writes this file for you, so you may prefer to set monitors there and let it generate the entries.

## Keybinds

All of these are in `keybinds.lua`. The top of that file builds a small `bind` helper so combos can be written the way Hyprland writes them, for example `bind("SUPER + SHIFT + Q", action)`. It understands the modifiers `SHIFT`, `CTRL`, `ALT` and `SUPER`, named keys such as `Tab` and `Page_Up`, function keys, single letters, mouse buttons written `mouse:273`, and the scroll wheel as `mouse_up` and `mouse_down`. If you add a binding with a key name the helper does not know, it stops with an `unknown key in bind` error.

Super is the Windows or Command key. Binds marked locked work while the screen is locked, and repeating ones keep firing while the keys are held.

### Audio and brightness

| Keys | Action |
|---|---|
| Volume Up | Raise volume 5 percent, capped at 100 percent. Locked, repeating. |
| Volume Down | Lower volume 5 percent. Locked, repeating. |
| Mute key | Sets the volume to 0 percent. It does not toggle mute. Locked. |
| Super+Shift+M | Volume to 0 percent. Locked. |
| Alt+Mute key | Toggle the microphone mute. Locked. |
| Super+Mute key | Toggle the microphone mute. Locked. |
| Brightness Up | Raise brightness 5 percent. Locked, repeating. |
| Brightness Down | Lower brightness 5 percent. Locked, repeating. |

### Apps and tools

| Keys | Action |
|---|---|
| Super+L | `alacritty`. |
| Super+T | `ptyxis` in a new window, with a blur workaround. |
| Super+Z | `zed`. |
| Super+E | `nautilus`. |
| Super+Alt+E | `thunar`. |
| Super+X | `gedit`. |
| Super+I | `better-control`. |
| Ctrl+Super+V | `pavucontrol`. |
| Ctrl+Shift+Escape | `gnome-system-monitor`. |
| Super+Alt+Slash | Toggle `fuzzel`. |
| Super+Period | Toggle the emoji picker script. |
| Super+V | Toggle the clipboard history picker. |
| Super+Shift+C | Color picker with `hyprpicker`, copies the color. |
| Ctrl+Super+T | Choose a wallpaper image, then run the wallpaper script. |

### Screenshots and recording

| Keys | Action |
|---|---|
| Super+Shift+S | Choose a region and copy it to the clipboard. |
| Super+Print | Screenshot with a preview, saved as `/tmp/eh-screenshot.png`. |
| Super+Ctrl+Print | Full screenshot with `grim` into `~/Pictures/Screenshots`, named with the date and time. Locked. |
| Ctrl+Print | Screenshot of the monitor that has focus, saved as `/tmp/eh-screenshot.png`, not copied to the clipboard. Locked. |
| Super+Alt+R | Recording script. Locked. |
| Ctrl+Alt+R | Recording script, fullscreen. Locked. |
| Super+Shift+Alt+R | Recording script, fullscreen with sound. Locked. |

### Session

| Keys | Action |
|---|---|
| Super+K | Lock the session. |
| Super+Shift+L | Suspend. Locked. |
| Ctrl+Shift+Alt+Delete | Toggle the `wlogout` menu. |
| Ctrl+Shift+Alt+Super+Delete | Power off immediately. |
| Ctrl+Super+Alt+R | Reload the Zoolander config (`zoolanderctl reload`). |
| Super+Alt+B | HDR toggle, but see the quirks section. |

### Windows

| Keys | Action |
|---|---|
| Super+Left bracket, Right bracket | Focus left or right. |
| Super+Up, Super+Down | Focus up or down. |
| Super+Shift+arrow keys | Move the window in that direction. |
| Middle mouse button, held and dragged | Move the window. No modifier needed. |
| Super+right mouse button, dragged | Resize the window. |
| Alt+F4, Super+Q | Close the window. |
| Super+F | Toggle fullscreen. |
| Super+Alt+Space | Toggle floating. |
| Super+P | Toggle pin, so the window shows on every workspace. |
| Super+Minus, Super+Semicolon | Make the window 100 pixels narrower. Repeating. |
| Super+Equal, Super+Apostrophe | Make the window 100 pixels wider. Repeating. |

The resize binds work in steps of 100 pixels, set by `RESIZE_STEP` at the top of that part of the file. The Hyprland setup changed the split ratio by 10 percent instead.

### Workspaces

Workspaces in Zoolander have names, and in this config they are the numbers 1 to 10.

| Keys | Action |
|---|---|
| Super+1 to Super+9, Super+0 | Go to workspace 1 to 9, and 10 for the 0 key. |
| Super+Alt+1 to Super+Alt+0 | Send the window to that workspace and stay where you are. |
| The same on the numpad | Both Super+number and Super+Alt+number also work on the numpad. Each numpad key has two key codes, depending on Num Lock, and both are bound, so Num Lock does not matter. |
| Super+scroll up, Super+scroll down | Next or previous workspace. |
| Super+Page Down, Super+Page Up | Next or previous workspace. |
| Ctrl+Super+scroll, Ctrl+Super+Left and Right, Ctrl+Super+Page Down and Up, Ctrl+Super+Left bracket and Right bracket, Ctrl+Super+Alt+Left and Right | Next or previous workspace. |
| Ctrl+Super+Down, Ctrl+Super+Up | Jump five workspaces forward or back. |
| Super+Shift+scroll, Super+Alt+scroll | Send the window to the next or previous workspace, and follow it. |
| Super+Alt+Page Down and Up, Super+Shift+Page Down and Up | Send the window to the next or previous workspace, and follow it. |
| Ctrl+Super+Shift+Left and Right | Send the window to the previous or next workspace, and follow it. |
| Super+S, Ctrl+Super+S, Super+side mouse button | Show or hide the special (scratch) workspace. |

Hyprland has several different ways to step through workspaces (`+1`, `r+1`, `m+1`). Zoolander does not, so in this config they all do the same thing. Each one reads the number of the workspace that is active on the focused monitor, adds or subtracts the step, and goes there. The result never drops below 1, it does not wrap around, and it does not skip empty workspaces.

### Event Horizon

| Keys | Action |
|---|---|
| Super+Tab | Open or close the overview. |
| Alt+Tab | Calls `eh-ipc dashboard-toggle`, which does not exist in 0.1.4. See the quirks section. |
| Super+9 | Start `horizon`. |
| Super+7 | Kill `horizon` with `pkill -9`. |

### What was not carried over from the Hyprland setup

Window groups, the maximize bind, the fake-fullscreen bind, the `hyprctl kill` bind, the 640x480 resize bind, the binds that send windows to the special workspace, and every leftover QuickShell bind. Hyprland-specific tools such as `hypridle` and `hyprswitch` are also not started.

## Known quirks

These will surprise you if you do not know about them. None of them stop Zoolander from starting.

Super+7 and Super+9 are bound twice. The workspace loop binds them to workspaces 7 and 9, and the Event Horizon section at the end of the file binds the same keys to killing and starting `horizon`. The safest fix is to move the start and kill binds to keys that workspaces do not use.

The HDR toggle always turns HDR off. The code flips a variable called `hdr_forced`, but then calls `zl.set_presentation({ hdr = "off" })` either way, so pressing Super+Alt+B never turns anything on. The comment above it says it should switch between forced HDR and SDR. The two values used in this config are `"off"` and `"auto"`. The value for forcing HDR on is described in the Zoolander documentation.

Alt+Tab does nothing useful. `eh-ipc dashboard-toggle` is not a command in 0.1.4. Run `eh-ipc help` to see what your version offers.

The tablet display rule uses the output name `output`, which looks like a placeholder, because real outputs are named like `HDMI-A-1`. Replace it with the real name of the tablet's connection, or it may never match anything.

`autostart.lua` opens a `ptyxis` terminal every time you log in.

The mute key only sets the volume to 0 percent. If you want a real toggle, bind it to `wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle`.

Super+S is claimed by the shell itself to open settings (see [usage.md](usage.md#keys-the-shell-handles-itself)), and this config also uses Super+S for the special workspace.
