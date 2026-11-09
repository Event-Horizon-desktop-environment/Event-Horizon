# My Hyprland setup

This page explains the Hyprland configuration I run Event Horizon with. It is meant to be read next to the files themselves, which are in the `hypr` folder. You can copy the whole thing, copy pieces of it, or just use it to see how the pieces fit together.

The config is written in Lua, which Hyprland supports as an alternative to the older `hyprland.conf` format. The entry point is `hyprland.lua`, and everything else is pulled in from there with `require`. If your Hyprland does not have Lua configuration support yet, none of this will load, and you will want to translate the ideas into the classic format instead.

## Using it

Back up whatever you have first, then copy the folder into place:

```bash
mv ~/.config/hypr ~/.config/hypr.backup
cp -r hypr ~/.config/hypr
```

Before you log in with it, read the next two sections. The config calls a number of programs and a few helper scripts, and some of those are not part of this repository.

### Programs the config expects

None of these are required for Hyprland to start, but the keybind that uses a missing program will simply do nothing.

| Program | Used for |
|---|---|
| `horizon` and the rest of Event Horizon | The shell itself. See [the install guides](../README.md#install). |
| `alacritty` | Terminal on Super+L. |
| `ptyxis` | Terminal on Super+T. |
| `nautilus`, `thunar` | File managers on Super+E and Super+Alt+E. |
| `zed`, `gedit` | Code editor and text editor. |
| `google-chrome-stable` | The default browser variable. |
| `pavucontrol`, `better-control`, `gnome-system-monitor` | Volume mixer, settings app, task manager. |
| `fuzzel` | Launcher and emoji picker. |
| `wlogout` | The fallback power menu. |
| `grim` | Full-screen screenshots saved to the Pictures folder. |
| `hyprpicker` | Color picker. |
| `jq` | Reads the active monitor for one screenshot bind. |
| `yad` | File chooser for the wallpaper bind. |
| `brightnessctl` | Brightness keys. |
| `wpctl` (from WirePlumber) | Volume and microphone keys. |
| `hypridle` | Idle handling, started at login. |
| `hyprswitch` | Window switcher, started at login. |
| `gnome-keyring-daemon` | Stores secrets for apps that ask. |
| `xhost` | Lets X11 programs connect. |

### Helper scripts that are not included

Five of the binds point at scripts that live outside this repository. They came from earlier setups of mine, and you will have to supply your own or remove the binds.

| Path | Used by |
|---|---|
| `~/.config/hypr/hyprland/scripts/workspace_action.sh` | Super+1 to 0, Super+Alt+1 to 0, and the same on the numpad. |
| `~/.config/hypr/hyprhdr.py` | Super+Alt+B, the HDR toggle. |
| `~/.config/ags/scripts/record-script.sh` | The three screen recording binds. |
| `~/.config/quickshell/scripts/switchwall.sh` | Ctrl+Super+T, the wallpaper chooser. |
| `~/.local/bin/fuzzel-emoji` | Super+Period, the emoji picker. |

The first one matters most. Without `workspace_action.sh`, the number keys do not switch workspaces. If you do not want a script, replace those binds with Hyprland's own workspace actions.

A number of other binds call `qs` or `quickshell`. Those are left over from when I ran a QuickShell-based shell before Event Horizon, and nothing in this repository provides them. They are listed in the keybind section below, marked as leftovers.

## How the config is organized

```text
hypr/
    hyprland.lua            Entry point. Loads everything else, in order.
    monitors.lua            Monitor layout. Loaded.
    workspaces.lua          Placeholder comment only. Loaded.
    eh-monitors.lua         Old generated monitor file. NOT loaded.
    eh/
        colors.lua          Event Horizon color values. Loaded.
    hyprland/
        env.lua             Environment variables. Loaded.
        variables.lua       Default app names. Loaded.
        render.lua          Rendering and color management. Loaded.
        general.lua         Gaps, borders, layout, snapping. Loaded.
        input.lua           Keyboard, mouse, touchpad, tablet. Loaded.
        decoration.lua      Rounding, blur, glow, shadow. Loaded.
        misc.lua            Everything that does not fit elsewhere. Loaded.
        xwayland.lua        X11 compatibility. Loaded.
        binds.lua           How binds behave. Loaded.
        layout.lua          Scrolling layout column sizes. Loaded.
        animations.lua      Animation settings. Loaded.
        execs.lua           Programs started at login. Loaded.
        rules.lua           Blur rules for shell surfaces. Loaded.
        epic.lua            Epic Games Launcher fix. Loaded.
        keybinds.lua        All keybinds. Loaded.
        tablet-fix.lua      Drawing tablet monitor. Loaded.
        cursor.lua          Cursor options. NOT loaded.
        group.lua           Window group options. NOT loaded.
        dwindle.lua         Dwindle layout options. NOT loaded.
        master.lua          Master layout options. NOT loaded.
        scrolling.lua       Scrolling layout options. NOT loaded.
        gestures.lua        Touchpad gestures. NOT loaded.
        opengl.lua          OpenGL options. NOT loaded.
        quirks.lua          Quirks options. NOT loaded.
```

### Load order

`hyprland.lua` loads the files in this order: `env`, `variables`, `render`, `general`, `input`, `decoration`, `misc`, `xwayland`, `binds`, `layout`, `animations`, `execs`, `rules`, `epic`, `keybinds`, `eh/colors`, `workspaces`, `monitors`, `tablet-fix`.

When two files set the same option, the one loaded later wins.

### Files that are not loaded

Eight files in `hyprland/` exist but are not required by `hyprland.lua`: `cursor`, `group`, `dwindle`, `master`, `scrolling`, `gestures`, `opengl` and `quirks`. Hyprland is simply running with its own defaults for those settings. They are the files Event Horizon's settings app generates when you use its Hyprland pages. If you want one to take effect, add a line to `hyprland.lua`, for example:

```lua
require("hyprland/cursor")
```

If you load both `layout.lua` and `scrolling.lua`, they set some of the same scrolling options (the column width is 0.62 in one and 0.4 in the other). Whichever you load last wins.

`eh-monitors.lua` is an older generated monitor file. It is not loaded, and you should not load it. It has unquoted values such as `output = DP-1` and `mode = 2560x1440@120`, which are not valid Lua, so requiring it would make the config fail. The same mistake was a bug in Event Horizon 0.1.2 that was fixed. You can delete the file.

### Which files Event Horizon rewrites

Most files in `hyprland/` start with the comment `managed by Event Horizon`. That means they are written by the Hyprland pages in the Event Horizon settings app, and if you edit them by hand, a later change in the settings app can overwrite your edit. Two files are marked as not managed, and are safe to edit: `epic.lua` and `tablet-fix.lua`. If you want a hand-written change that survives, put it in one of those, or in a new file that you load from `hyprland.lua`.

## What each file does

### monitors.lua

This describes my three main monitors, side by side, left to right.

| Output | Mode | Position | Notes |
|---|---|---|---|
| `DP-2` | 2560x1440 at 180 Hz | 0x0 | Left monitor |
| `DP-1` | 2560x1440 at 239.97 Hz | 2560x0 | Middle monitor, with HDR values set |
| `DP-3` | 2560x1440 at 180 Hz | 5120x0 | Right monitor |

All three use the sRGB color mode and no mirroring. The `sdrbrightness`, `sdrsaturation`, `sdr_min_luminance` and `sdr_max_luminance` values control how ordinary (SDR) content looks on a screen that is running in HDR mode. The `min_luminance`, `max_luminance` and `max_avg_luminance` values on the middle monitor describe what that panel can do in HDR.

To use this on your machine, you must change the output names to match yours. Run `hyprctl monitors` inside Hyprland to see them. Then set the resolution, refresh rate and position for each. The position is where the top-left corner of that screen sits in one big shared coordinate space, so a second 2560-wide monitor to the right of the first goes at `2560x0`.

### tablet-fix.lua

A drawing tablet with a built-in display (a Kamvas 12) is connected over HDMI. It is placed at `7680x0`, to the right of the three monitors, at 1920x1080 and 60 Hz with scale 1. The scale is forced to 1 so that the Wayland coordinates and the X11 coordinates agree, and the pen lines up with the cursor. The total width of everything is 9600 pixels.

The same setting is written twice, once for `HDMI-A-1` and once for `HDMI-A-2`, because the tablet shows up under a different port name from one boot to the next. A rule for an output that is not plugged in is harmless. If you do not have a tablet, delete the `require("hyprland/tablet-fix")` line at the end of `hyprland.lua`.

### workspaces.lua

Contains only a comment saying it will be overwritten by `nwg-displays` if you use that tool. It does nothing by itself.

### eh/colors.lua

Returns three colors from the Event Horizon palette, as plain hex strings: `primary`, `outline` and `error`. A comment at the top shows how to use them for window borders and group borders. In my config nothing uses them right now, because window borders are turned off. The file is there for when you want colored borders that follow your wallpaper.

### hyprland/env.lua

Environment variables for everything Hyprland starts. It says this is a Wayland session under Hyprland and tells Qt, Firefox, Chromium and Electron apps to use Wayland where they can. Qt apps are told to use the `qt6ct` theme, and to leave window decorations to the compositor. The cursor size is 24. `SSH_ASKPASS_REQUIRE` is set to `never` so that SSH does not pop up a graphical password prompt.

### hyprland/variables.lua

Sets `terminal`, `fileManager`, `browser`, `codeEditor`, `textEditor`, `volumeMixer`, `settingsApp` and `taskManager` to the programs I use. The shell and some scripts read these when they need to open "the default" of something. Change them to your own choices.

### hyprland/render.lua

Rendering and color management. It turns on color management, direct scanout (level 2), content type hints and the newer render scheduling, and sets a 16-bit floating point pipeline for HDR (`use_fp16 = 2`). Most of these values were chosen for my high refresh rate monitors, and you can leave them alone unless you have a reason.

### hyprland/general.lua

The basic window behavior. Borders and all gaps are 0, so windows fill the screen edge to edge. The layout is dwindle. Screen tearing is allowed, which can reduce input lag in games that ask for it. Windows can be resized by dragging their edges. Windows snap to each other and to screen edges when dragged: 10 pixels between windows and 7 pixels from monitor edges, while respecting gaps.

### hyprland/input.lua

Keyboard: US layout, Num Lock on at start, a 250 ms delay before repeating and then 35 repeats per second. Mouse: adaptive acceleration with zero sensitivity offset, and natural scrolling off. Focus follows the mouse (`follow_mouse = 1`). Touchpad: natural scrolling on, tap to click, click by finger count, disable while typing, half-speed scrolling, and drag with tap. The tablet and touchscreen sections are at their defaults, with the touchscreen enabled.

### hyprland/decoration.lua

How windows look. Corners are rounded by 11 pixels. Opacity is 1 for active, inactive and fullscreen windows. Blur is on, with a size of 4, four passes, and slight noise, contrast and brightness adjustments, and it also blurs popups and input method windows. Blur sees through to the wallpaper (xray) so it is cheaper to draw. A soft purple glow is on (`0xee7d5fa3`, range 3). Shadows and motion blur are off. Dimming of inactive windows is off, though the strength values are set for when you turn it on.

### hyprland/misc.lua

Hyprland's logo and splash are turned off. Adaptive sync (VRR) is off. Window swallowing is off, though a regular expression for terminals is ready. Lock screen restore is allowed so a crashed lock screen can be recovered. The mouse wakes a sleeping screen, and the keyboard does not. Unfocused windows render at 1 frame per second.

### hyprland/xwayland.lua

X11 apps are enabled, with "force zero scaling" on, so X11 programs are not blurry-scaled on scaled monitors.

### hyprland/binds.lua

How binds behave, not the binds themselves. Workspace cycling is allowed, special workspaces are not hidden when you change workspace, and the mouse is not passed through when a bind consumes it.

### hyprland/layout.lua

Sets options for the scrolling layout: columns 0.62 of the screen wide, a single column goes fullscreen, focus scrolls to the selected column, and the preset column widths are 0.333, 0.5, 0.62, 0.75 and 1.0. The active layout is dwindle (set in `general.lua`), so this only matters if you switch to scrolling.

### hyprland/animations.lua

Animations are on, with workspace wraparound. Three animations are customized: windows opening, layers (such as popups and shell surfaces) opening, and window movement. All use speed 3 and the default curve, and the first two slide.

### hyprland/execs.lua

Everything started at login, once Hyprland is ready:

| Command | What it does |
|---|---|
| `horizon` | Starts Event Horizon. |
| `hyprswitch init &` | Starts the window switcher service. |
| `gnome-keyring-daemon --start --components=secrets` | Starts the secrets store for saved passwords. |
| `hypridle` | Starts Hyprland's idle daemon. |
| `horizon-clipstack` | Starts clipboard history. |
| `hyprctl setcursor Bibata-Modern-Classic 24` | Sets the cursor theme and size. |
| `xhost +local: &` | Allows local X11 programs to open windows. |
| `dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE` | Tells D-Bus and systemd which session is running. |

The last line is important. Portals (the system that lets sandboxed apps open file choosers and take screenshots) start themselves through D-Bus, and they need to know they are in a Hyprland session. Do not start the portal programs yourself from this file. If you do, two copies fight over the same D-Bus name and the system units fail with `Failed to request bus name (File exists)`.

Two lines deserve a second look. The supervisor already keeps `horizon-clipstack` running, so starting it here too is likely redundant. And `xhost +local:` disables X11 access control for local users, which is convenient and also less safe than leaving it alone. Remove it if you do not run X11 programs as other users.

### hyprland/rules.lua

All of this file is layer rules, which apply to shell surfaces such as the dock and popups, not to ordinary windows. For every Event Horizon surface (dock, panels, spotlight, settings, app drawer, tray, control center, context menus, calendar, popups, taskbar, toasts, on-screen display, launchpad, polkit dialog, widgets, overview and dashboard) it turns on blur, and sets `ignore_alpha = 0` so that everything, including fully transparent pixels, is blurred behind them. The one exception is `event-horizon-desktop-shell`, which is the desktop backdrop and has blur turned off.

The file does the same for a few other things I run: `horizon-vinyl`, `dock`, `dock-launcher`, `ptyxis`, `otter-monitor`, `otter-term`, `cider` and `nautilus`. For `cider` and `nautilus` the xray option is also off, so their blur shows what is actually behind them and not only the wallpaper.

### hyprland/epic.lua

A window rule for the Epic Games Launcher. It makes the launcher float, centers it, sizes it to 1280x720 and turns off blur for it. Without this, its embedded web view shows see-through holes and the tiling layout keeps resizing it.

## Keybinds

All of these are in `hyprland/keybinds.lua`. "Super" is the Windows or Command key. Binds marked locked still work when the screen is locked, and binds marked repeating keep firing while you hold the keys.

### Audio and brightness

| Keys | Action |
|---|---|
| Volume Up | Raise volume 5 percent, capped at 100 percent. Locked, repeating. |
| Volume Down | Lower volume 5 percent. Locked, repeating. |
| Mute key | Sets the volume to 0 percent. It does not toggle mute, so pressing it again does not restore the volume. Locked. |
| Super+Shift+M | Same as the mute key: volume to 0 percent. Locked. |
| Alt+Mute key | Toggle the microphone mute. Locked. |
| Super+Mute key | Toggle the microphone mute. Locked. |
| Brightness Up | Raise brightness 5 percent. Locked, repeating. |
| Brightness Down | Lower brightness 5 percent. Locked, repeating. |

### Apps

| Keys | Action |
|---|---|
| Super+L | Open `alacritty`. |
| Super+T | Open `ptyxis` in a new window, with a setting that works around a blur issue. |
| Super+Z | Code editor (`zed`). |
| Super+E | File manager (`nautilus`). |
| Super+Alt+E | `thunar`. |
| Super+X | Text editor (`gedit`). |
| Super+I | Settings app (`better-control`). |
| Ctrl+Super+V | Volume mixer (`pavucontrol`). |
| Ctrl+Shift+Escape | Task manager (`gnome-system-monitor`). |
| Super+Alt+Slash | Toggle `fuzzel`. |
| Super+Period | Toggle the emoji picker script. |
| Super+V | Toggle the clipboard history picker. |
| Super+Shift+C | Color picker, copies the color to the clipboard. |
| Ctrl+Super+T | Choose a wallpaper image with a file dialog, then run the wallpaper script. |

### Screenshots and recording

| Keys | Action |
|---|---|
| Super+Shift+S | Choose a region and copy it to the clipboard. |
| Super+Print | Screenshot with a preview, saved as `/tmp/eh-screenshot.png`. |
| Super+Ctrl+Print | Full screenshot with `grim`, saved in `~/Pictures/Screenshots` with the date and time in the name. Locked. |
| Ctrl+Print | Screenshot of the monitor with the active workspace, saved as `/tmp/eh-screenshot.png`, not copied to the clipboard. Locked. |
| Super+Alt+R | Start the recording script. Locked. |
| Ctrl+Alt+R | Recording script, fullscreen. Locked. |
| Super+Shift+Alt+R | Recording script, fullscreen with sound. Locked. |

### Session

| Keys | Action |
|---|---|
| Super+K | Lock the session (`loginctl lock-session`). |
| Super+Shift+L | Suspend. There are two binds on this key, see the quirks section. Locked. |
| Ctrl+Shift+Alt+Delete | Toggle the `wlogout` power menu. |
| Ctrl+Shift+Alt+Super+Delete | Power off immediately. |
| Ctrl+Super+Alt+R | Reload the Hyprland config. |
| Super+9 | Start `horizon`. |
| Super+7 | Kill `horizon` with `pkill -9`. |

### Windows

| Keys | Action |
|---|---|
| Super+Left bracket, Right bracket | Focus the window to the left or right. |
| Super+Up, Super+Down | Focus the window above or below. |
| Super+Shift+arrow keys | Move the window in that direction. |
| Middle mouse button, held and dragged | Move the window. No modifier key is needed. |
| Super+right mouse button, dragged | Resize the window. |
| Alt+F4, Super+Q | Close the window. |
| Super+Shift+Alt+Q | Kill a window with `hyprctl kill`. You click the window to kill. |
| Super+F | Fullscreen. |
| Super+D | Maximize, without going fullscreen. |
| Super+Alt+F | Tell the app it is fullscreen without actually making it fill the screen. |
| Super+Alt+Space | Toggle floating. |
| Super+P | Pin the window so it shows on every workspace. |
| Super+Minus, Super+Semicolon | Shrink the split by 10 percent. Repeating. |
| Super+Equal, Super+Apostrophe | Grow the split by 10 percent. Repeating. |
| Ctrl+Super+Backslash | Resize the active window to exactly 640x480. |
| Super+G | Toggle a window group. |
| Super+C | Switch to the next tab in a group. |
| Super+H | Move the window out of its group. |
| Super+Alt+B | Run the HDR toggle script. |

### Workspaces

| Keys | Action |
|---|---|
| Super+1 to Super+0 | Go to workspace 1 to 10, through the helper script. Works with the number row and the numpad. |
| Super+Alt+1 to Super+Alt+0 | Move the window to that workspace without following it, through the helper script. Number row and numpad. |
| Super+scroll up, Super+scroll down | Next or previous workspace. |
| Super+Page Down, Super+Page Up | Next or previous workspace. |
| Ctrl+Super+scroll, Ctrl+Super+Left and Right, Ctrl+Super+Page Down and Up | Step through workspaces using Hyprland's relative `r` mode. |
| Ctrl+Super+Alt+Left and Right | Step using the `m` mode, which is relative to the current monitor. |
| Ctrl+Super+Left bracket, Right bracket | Previous or next workspace by number. |
| Ctrl+Super+Up, Down | Jump five workspaces back or forward. |
| Super+S, Ctrl+Super+S, Super+side mouse button | Show or hide the special (scratch) workspace. |
| Super+Alt+S | Send the window to the special workspace and stay where you are. |
| Ctrl+Super+Shift+Up | Send the window to the special workspace. |
| Ctrl+Super+Shift+Left and Right | Send the window to the previous or next workspace. |
| Super+Shift+scroll | Send the window to the previous or next workspace. |
| Super+Alt+scroll | Send the window to the previous or next workspace. |
| Super+Alt+Page Down and Up | Send the window to the next or previous workspace. |
| Super+Shift+Page Down and Up | Send the window to the next or previous workspace, relative mode. |

For exactly what the `r` and `m` prefixes do with empty workspaces, see Hyprland's own documentation of the workspace dispatcher.

### Event Horizon

| Keys | Action |
|---|---|
| Super+Tab | Open or close the overview (`eh-ipc overview-toggle`). |
| Alt+Tab | Calls `eh-ipc dashboard-toggle`. See the quirks section. |
| Super+Shift+S | Region screenshot (listed above). |
| Super+V | Clipboard history (listed above). |

### Leftover QuickShell binds

These belong to a QuickShell setup I used before. The programs they call are not in this repository, so on a clean machine they do nothing. They are still in the file, and several collide with binds above.

| Keys | What it calls |
|---|---|
| Alt+Shift+Tab | `qs ipc call overview toggle` |
| Super+Slash | `quickshell ipc call cheatsheet toggle` |
| Super+Tab | `quickshell --overview` |
| Super+B | `quickshell --toggle-bar` |
| Super+M | `quickshell ipc call simpleMediaPlayer toggle` |
| Super+K | `quickshell --toggle-keyboard` |
| Super+Shift+D | `quickshell ipc call dash toggle` |
| Ctrl+Alt+Delete | `quickshell --toggle-power` |
| Super+A | `qs ipc call appDrawerPopout toggle` |
| Super+R | `qs ipc call settings toggle` |
| Super+0 | `qs &` |
| Super+P | `qs ipc call pikapack toggle` |
| Super+W | `qs ipc call weather toggle` |
| Super+Y | `qs ipc call setting toggle` |
| Super+L | `qs ipc call Spotlight toggle` |
| Super+C | `qs ipc call calendar toggle` |

## Known quirks

These are things in the config as it stands that will surprise you. None of them stop Hyprland from starting.

Several keys are bound twice. Super+L opens both `alacritty` and the QuickShell spotlight. Super+K locks the session and also calls QuickShell's keyboard toggle. Super+Shift+L has one bind that locks and another that suspends. Super+C switches group tabs and also toggles the QuickShell calendar. Super+P pins a window and also toggles a QuickShell panel. Super+Tab has both a QuickShell overview and the Event Horizon overview. Hyprland registers every one of these, so the result on those keys can be more than one action. If you copy this config, remove the QuickShell lines and decide which bind you want for each key.

Super+7 and Super+9 are doing two jobs. They are the workspace 7 and workspace 9 keys, and they are also the keys that kill and start `horizon`. Super+0 is workspace 10 and also runs `qs &`. The safest fix is to move the shell start and kill binds to keys not used by workspaces.

Super+S is also taken by the shell itself. Event Horizon opens its settings on Super+S by reading the keyboard directly (see [usage.md](usage.md#keys-the-shell-handles-itself)), and this config also uses Super+S for the special workspace.

The mute key only sets the volume to 0 percent. If you expect a toggle, change the bind to `wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle`.

Alt+Tab calls `eh-ipc dashboard-toggle`, but version 0.1.4 of `eh-ipc` has no such command. The bind does nothing useful today.

One layer rule is misspelled. The blur line for the terminal uses the namespace `ptyxis`, but the line that sets `ignore_alpha` uses `pytixs`, so that second rule never matches anything.

Nothing loads `eh/colors.lua` into a setting, so those colors are unused for now.
