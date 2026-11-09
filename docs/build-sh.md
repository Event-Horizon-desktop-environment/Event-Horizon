# build.sh

`build.sh` is the supported way to build and install Event Horizon. It lives in the root of the repository. This page explains what it does from the moment you press Enter, what every option means, and what to do when it stops.

If you only want to get Event Horizon installed, use the guide for your distribution instead ([Arch](install/arch.md), [Fedora](install/fedora.md), [Debian](install/debian.md)). Come back here when you want to know why it did something.

## The short version

```bash
./build.sh
```

With no options the script does these things in order:

1. Checks that the libraries Event Horizon needs are installed, and installs the missing ones with your package manager.
2. Finds a Zig compiler that is version 0.16.0 or newer, and downloads one if it cannot.
3. Looks at your CPU and picks the highest x86-64 level it supports.
4. Builds everything in `ReleaseFast` mode.
5. Installs the result to `/usr`, asking for administrator rights once.

Run it from a normal user account, from inside the repository folder, and do not put `sudo` in front of it. The script asks for privilege itself, only for the install step. If you run the whole thing as root, your build cache ends up owned by root and later builds as your normal user will fail in confusing ways.

## Options

Options can go in any order. Options that take a value accept either a space or an equals sign, so `--cpu v3` and `--cpu=v3` are the same.

| Option | What it does |
|---|---|
| `--cpu LEVEL` | Choose the CPU level to build for. See the section below. |
| `--prefix PATH` | Install under `PATH` instead of `/usr`. Must be an absolute path. |
| `--no-install` | Build only. Nothing outside the repository folder is touched. |
| `--skip-deps` | Never call the package manager. Also written `--no-deps`. |
| `--deps-only` | Install the build dependencies and stop. No build, no install. |
| `--jobs N` | Use at most N parallel build jobs. N must be a whole number. |
| `--zig PATH` | Use this Zig executable instead of looking for one. |
| `-h`, `--help` | Print the built-in help and exit. |

Two environment variables do the same job as options. `ZIG` is the same as `--zig`, and `EH_CPU` is the same as `--cpu`. If you give both the variable and the option, the option wins.

If you give an option the script does not know, or leave off a value that an option needs, it stops immediately with an error and does nothing else.

### --cpu

This controls which instruction set the finished program is allowed to use. A higher level is faster on a CPU that supports it, but a program built for a higher level will crash on a CPU that does not.

| Value | Meaning |
|---|---|
| `v2` | x86-64-v2. Practically every x86-64 CPU from the last fifteen years or so. |
| `v3` | x86-64-v3. Needs AVX2. Most CPUs from roughly 2015 onward. |
| `v4` | x86-64-v4. Needs AVX-512. Common on recent AMD Zen 4 and newer, and some Intel server and workstation chips. |
| `native` | Whatever the machine running the build supports, no more and no less. |
| `baseline` | The plain minimum x86-64 with no extensions. Runs anywhere. |

The full names `x86_64_v2`, `x86_64_v3` and `x86_64_v4` are accepted as well. The older names `v1`, `x86_64` and `x86_64_v1` are treated as `baseline`. Anything else is an error.

If you do not pass `--cpu`, the script reads the flags line of `/proc/cpuinfo` and picks the highest level whose requirements are all present. For v4 it wants all of avx512f, avx512bw, avx512cd, avx512dq and avx512vl. For v3 it wants avx2, bmi1, bmi2, fma, f16c, movbe and xsave, plus lzcnt. For v2 it wants ssse3, sse4_1, sse4_2, popcnt, cx16 and lahf_lm. If none match, it builds for `baseline`.

The important consequence is that automatic detection builds for the machine you are on. If you build on a v4 machine and copy the result to a v3 machine, it will not run. Use `--cpu v3` or `--cpu v2` when the build is going to another computer.

On a CPU that is not x86-64, such as an ARM machine, only `native` and `baseline` are allowed. Asking for v2, v3 or v4 is an error. With no `--cpu` given, the script lets Zig pick its own native default.

### --prefix

The install location. The default is `/usr`. Under the prefix, the script puts:

| What | Where |
|---|---|
| The programs | `PREFIX/bin` |
| Icons | `PREFIX/share/icons/hicolor/scalable/apps` |
| Theme templates for the color engine | `PREFIX/share/event-horizon` |
| The license file | `PREFIX/share/licenses/event-horizon/LICENSE` |

The shell finds its theme templates by walking up from the location of the running program and looking for a `share/event-horizon` folder, so a custom prefix works. If you use one, make sure `PREFIX/bin` is on your `PATH` so you can type `horizon`. You can also point the shell at a template folder yourself with the `EH_MATUGEN_ROOT` environment variable.

`--prefix` only matters when installing. With `--no-install` it has no effect.

### --no-install

Build only. The finished programs are left in `.zig-out-release/bin` inside the repository. Nothing is installed, no password is asked for, and no files outside the repository are changed, except the Zig download described below if one was needed.

This is the right option when you are testing, when you are building for another machine, or when you want to look at what was built before putting it on your system.

To run the shell straight from that folder, remember that `horizon` starts its parts from the folder it lives in:

```bash
./.zig-out-release/bin/horizon
```

### --skip-deps

Tells the script never to run `pacman`, `dnf`, `apt-get` or `zypper`. If something it needs is missing, it stops and tells you what is missing instead of installing it. Use this if you manage packages yourself, or if you are on a distribution the script does not recognize.

### --deps-only

Install the build dependencies, then stop. Nothing is built and nothing is installed. It is handy when you want to set up a machine first and build later.

### --jobs

Limits how many things the compiler builds at once. It is passed to Zig as `-jN`. By default Zig uses every CPU core, which is fastest but can make a small machine unresponsive or run it out of memory. If your machine struggles during the build, try `--jobs 4` or lower.

### --zig

Use a specific Zig compiler. The script checks that it is version 0.16.0 or newer. If it is not, the script stops with an error. It does not quietly fall back to another Zig, because you asked for that one specifically.

## What happens, step by step

### 1. Dependencies

The script checks for `pkg-config` and `wayland-scanner`, then asks `pkg-config` whether it can find each of these libraries: wayland-client, wayland-protocols, xkbcommon, cairo, pangocairo, librsvg-2.0, libwebp and libpipewire-0.3.

If everything is found, it says so and moves on. If anything is missing, it prints the list. With `--skip-deps` it stops there. Otherwise it works out which distribution family you are on by reading `/etc/os-release`, and installs a fixed list of packages with the matching package manager.

| Family | Recognized as | Installed with |
|---|---|---|
| Arch | arch, manjaro, endeavouros, cachyos, garuda | `pacman -S --needed --noconfirm` |
| Fedora | fedora, rhel, centos, rocky, almalinux | `dnf install -y` |
| Debian | debian, ubuntu, linuxmint, pop, pika, zorin, elementary | `apt-get update`, then `apt-get install -y` |
| SUSE | suse, opensuse, sles | `zypper --non-interactive install` |

The script looks at both the `ID` and `ID_LIKE` lines, so a derivative of one of these usually matches. On any other distribution it stops and asks you to install the packages by hand. After installing it checks again, and stops with an error if anything is still missing.

Two things about this step are worth knowing.

First, the check does not look for PAM. The lock screen needs the PAM development files to compile, but neither the dependency check nor the package lists include them. On a machine without them the dependency step reports success and then the build fails partway through. Install the PAM development package yourself before running the script. The exact package name for each distribution is in the install guides.

Second, the check is only about libraries `pkg-config` can see. `zenity`, which the wallpaper folder picker and file dialogs need, is in the install lists, but it is only installed when something else on the check was missing. If all the libraries are already present, the script will not install `zenity` for you. Without it (or `kdialog` or `yad`) you cannot choose a wallpaper folder, which means no wallpaper image is picked and the color palette is never generated. Install it yourself if you are unsure.

### 2. Zig

Event Horizon needs Zig 0.16.0 or newer. The script looks in this order and takes the first that works:

1. The Zig you named with `--zig` or `ZIG`. If it is too old, that is an error.
2. A `zig` on your `PATH`, if it is new enough. If it is too old, the script warns and keeps looking.
3. A copy it downloaded on an earlier run, kept in `~/.cache/event-horizon/zig-0.16.0/` (it respects `XDG_CACHE_HOME` if you have set that).
4. A fresh download.

For a download, it needs `curl` or `wget`, plus `tar` and `xz`. If those are missing it installs them with the package manager, unless you passed `--skip-deps`, in which case it stops. It fetches the official 0.16.0 release for your architecture from ziglang.org, supporting x86-64 and ARM64. It unpacks into the cache folder, checks the version, and uses it. On any other architecture it stops, because it has no download for it.

This downloaded Zig is only used by the build script. It does not install anything into your system and nothing else uses it.

### 3. CPU level

Decided as described under `--cpu` above, and printed as a line such as `CPU target: x86_64_v3`.

### 4. Build

The script runs Zig with these arguments:

```text
zig build --cache-dir .zig-cache-release --prefix .zig-out-release -Doptimize=ReleaseFast -Dcpu=<level> -j<N>
```

The `-Dcpu` part is left out when there is no CPU level, and `-j` is left out when you did not pass `--jobs`. `ReleaseFast` is fixed. There is no option to change it, because a Debug build is far slower and bigger and is not meant for running the shell.

The release build has its own cache folder (`.zig-cache-release`) and output folder (`.zig-out-release`) inside the repository, so it never interferes with the `.zig-cache` and `zig-out` folders used for day-to-day development. Both are ignored by git. If you ever want to force a completely clean build, delete `.zig-cache-release` and run the script again.

At this point Zig itself runs `pkg-config` and `wayland-scanner`. This is where a missing development library, including PAM, shows up as an error.

### 5. Install

This step is skipped with `--no-install` or `--deps-only`.

The script first builds the icon files into a temporary folder as your normal user. Then it makes one privileged call that does all the installing together. This is on purpose: every privileged call is a separate password prompt, and an earlier version of the script asked four or five times.

Privilege comes from `pkexec` if it is available, then `sudo`, and if you are already root it just runs the commands. If neither `pkexec` nor `sudo` exists, it stops. Note that `pkexec` needs a polkit authentication agent running to show the password box. On a normal desktop session that is already there. If you are working from a bare TTY or over SSH, there may be no agent, and the prompt will fail. In that case use `--no-install`, or read the manual install section at the end of this page.

Inside the privileged call, the script does the following, stopping at the first failure:

1. Refuses to continue if `PREFIX/share` is a symbolic link. This is a safety check against writing files through a link to somewhere else.
2. Installs each of the 17 programs listed below into `PREFIX/bin` with permissions 755.
3. Installs the icons into `PREFIX/share/icons/hicolor/scalable/apps`, owned by root, permissions 644. It checks that none of those folders are symbolic links first.
4. Replaces the theme template folder `PREFIX/share/event-horizon`. It copies the new tree into a private staging folder, rejects it if it contains any symbolic link, sets root ownership and standard permissions, deletes the old folder, and moves the new one into place.
5. Installs the license to `PREFIX/share/licenses/event-horizon/LICENSE`.
6. If `gtk-update-icon-cache` exists, refreshes the icon cache. A failure here is ignored.

When it finishes it prints `Installed. Run 'horizon' from your Wayland session.`

### The 17 installed programs

| Program | What it is |
|---|---|
| `horizon` | The supervisor. Starts and watches everything else. |
| `eh-ipc` | Small command line tool for talking to the running shell. |
| `horizon-wallpaper` | Draws the wallpaper. |
| `horizon-dock` | The dock. |
| `horizon-taskbar` | The optional taskbar. |
| `horizon-desktop` | Desktop icons and folders. |
| `horizon-desktop-widgets` | Widgets that sit on the desktop. |
| `horizon-settings` | The settings app. |
| `horizon-overview` | The workspace and window overview. |
| `horizon-notifications` | Notification service and popups. |
| `horizon-polkit-agent` | The password prompt for administrator actions. |
| `horizon-audio-center` | The sound mixer and routing app. |
| `horizon-clipstack` | Clipboard history service. |
| `horizon-clipstack-pick` | The clipboard history picker. |
| `horizonClipboardDaemon` | Holds the clipboard for screenshots. |
| `horizon-idle` | Idle timers, screen blanking, suspend. |
| `horizon-lock` | The lock screen. |

Note that `horizonClipboardDaemon` really is spelled that way, with no hyphen.

## Common ways to run it

```bash
./build.sh                          # build and install, tuned for this machine
./build.sh --cpu v3                 # build and install, runs on any v3 or newer CPU
./build.sh --no-install --jobs 8    # build only, using 8 jobs
./build.sh --deps-only              # install libraries and stop
./build.sh --skip-deps --no-install # build only, no package manager at all
./build.sh --zig ~/zig/zig          # use a particular compiler
./build.sh --prefix /usr/local      # install under /usr/local
EH_CPU=v2 ./build.sh                # same as --cpu v2
```

## Updating

Pull the new code and run the script again.

```bash
git pull
./build.sh
```

The existing install is overwritten. Your settings in `~/.config/Event-Horizon/` are not touched. Restart the shell afterwards so the new programs are the ones running. The simplest way is to log out and back in.

## Uninstalling

The script has no uninstall option. To remove what it installed with the default prefix, delete the programs, the icons, the template folder and the license. Look at what the icon command matches before deleting it.

```bash
sudo rm -f /usr/bin/horizon /usr/bin/eh-ipc /usr/bin/horizon-wallpaper \
  /usr/bin/horizon-dock /usr/bin/horizon-taskbar /usr/bin/horizon-desktop \
  /usr/bin/horizon-desktop-widgets /usr/bin/horizon-settings \
  /usr/bin/horizon-overview /usr/bin/horizon-notifications \
  /usr/bin/horizon-polkit-agent /usr/bin/horizon-audio-center \
  /usr/bin/horizon-clipstack /usr/bin/horizon-clipstack-pick \
  /usr/bin/horizonClipboardDaemon /usr/bin/horizon-idle /usr/bin/horizon-lock

ls /usr/share/icons/hicolor/scalable/apps/event-horizon-*.svg
sudo rm -f /usr/share/icons/hicolor/scalable/apps/event-horizon-*.svg

sudo rm -rf /usr/share/event-horizon /usr/share/licenses/event-horizon
```

Your personal data stays where it is until you remove it yourself. That is the config in `~/.config/Event-Horizon/`, the logs in `~/EH-logs/`, and the clipboard history in `~/.local/share/event-horizon/`.

## Manual install

If you cannot or do not want to use the script's install step, you can build with the script and copy the files yourself, or drive Zig directly. Driving Zig directly is covered in [development.md](development.md#building-by-hand). For a copy-by-hand install, build with `./build.sh --no-install`, then copy the programs from `.zig-out-release/bin` into one folder on your `PATH`. All the programs have to end up together in the same folder, because `horizon` starts its parts from the folder it lives in and not by searching `PATH`.

## Troubleshooting the script

| What you see | What it means and what to do |
|---|---|
| `unsupported distro; install the Wayland/Cairo/Pango/librsvg/libwebp/PipeWire development packages manually` | The script does not recognize your distribution. Install the packages yourself and run with `--skip-deps`. |
| `dependencies are still missing: ...` | The package manager ran but the libraries are still not visible to `pkg-config`. Check that the installs really worked and that package names exist on your release. |
| `install the missing packages or rerun without --skip-deps` | You passed `--skip-deps` and something is missing. Install it, or drop the option. |
| `X is not Zig 0.16.0 or newer` | The Zig you named is too old. Use a newer one, or drop `--zig` and let the script manage Zig. |
| `could not download Zig 0.16.0` | No network, or ziglang.org was unreachable. Check your connection and try again. |
| `--cpu needs a value`, `--jobs needs a value`, and similar | You left off the value after an option. |
| `--prefix must be an absolute path` | Start the path with `/`. |
| `--jobs must be a number` | Use a plain whole number. |
| `unknown CPU level` | Use one of v2, v3, v4, native or baseline. |
| `CPU levels v2/v3/v4 only apply to x86_64` | You are on a non-x86 machine. Use `--cpu native`. |
| `pkexec and sudo are both unavailable` | Install one of them, or run the install as root some other way. |
| The build fails and mentions `pam` or `security/pam_appl.h` | The PAM development package is missing. Install it (see your distro guide) and run again. |
| The build fails with `pkg-config` errors about a library | Install the matching `-dev` or `-devel` package. |
| After installing, `horizon` runs but no bar appears | Run `eh-ipc status`, and see [usage.md](usage.md#troubleshooting). |
