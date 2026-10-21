#!/usr/bin/env python3
"""gen_lucide_icons.py — vendor Lucide SVGs for the settings app.

The settings UI historically drew Material Symbols ligatures; several names
missing from the bundled font (`dock_to_top`, `panel`, ...) rendered as text
or dots. Lucide (ISC license, https://lucide.dev) has a clean SVG for every
icon the app asks for, so each material glyph name is mapped to a Lucide
icon here and vendored into src/ux/settings/lucide/.

Outputs (regenerate with:  python3 scripts/gen_lucide_icons.py  — network
required only for regeneration; the vendored files are committed):

  src/ux/settings/lucide/<name>.svg   vendored icons (deduped by lucide name)
  src/ux/settings/lucide/LICENSE.txt  Lucide ISC license
  src/ux/settings/lucide_icons.zig    generated lookup table

Each material name maps through a candidate list — the first name that
exists in the Lucide repo wins, so renames/removals upstream fail loudly
instead of shipping a broken icon.
"""

import os
import sys
import urllib.error
import urllib.request

SRC = "https://raw.githubusercontent.com/lucide-icons/lucide/main/icons/{}.svg"
LICENSE_SRC = "https://raw.githubusercontent.com/lucide-icons/lucide/main/LICENSE"

HERE = os.path.dirname(os.path.abspath(__file__))
# Both copies stay in sync: `shared` serves the shell binaries (dock,
# taskbar, widgets), `settings2` serves the settings app. Same table, same
# vendored SVGs.
OUT_DIRS = [
    os.path.normpath(os.path.join(HERE, "..", "src", "ux", "shared")),
    os.path.normpath(os.path.join(HERE, "..", "src", "ux", "settings2")),
]

# material glyph name -> lucide candidate names, first hit wins.
MAP = {
    # sidebar + search + rows
    "account_circle": ["circle-user-round", "user-round", "user-circle"],
    "app_registration": ["list-checks", "list"],
    "apps": ["layout-grid"],
    "bluetooth": ["bluetooth"],
    "border_style": ["square"],
    "calendar_month": ["calendar"],
    "colorize": ["brush", "paintbrush"],
    "dashboard": ["layout-dashboard"],
    "dark_mode": ["moon"],
    "desktop_windows": ["monitor"],
    "display_settings": ["monitor-cog", "monitor"],
    "dock_to_bottom": ["panel-bottom"],
    "dock_to_top": ["panel-top"],
    "grid_view": ["grid-3x3", "grid-2x2"],
    "keyboard": ["keyboard"],
    "lan": ["network", "ethernet-port", "cable"],
    "monitor": ["monitor"],
    "monitoring": ["activity"],
    "mouse": ["mouse"],
    "music_note": ["eighth-note", "eighth-notes"],
    "notifications": ["bell"],
    "palette": ["palette"],
    "photo_library": ["images"],
    "play_arrow": ["play"],
    "power_settings_new": ["power"],
    "public": ["globe"],
    "push_pin": ["pin"],
    "schedule": ["clock"],
    "settings": ["settings"],
    "tune": ["sliders-horizontal"],
    "view_module": ["blocks", "layout-grid"],
    "volume_up": ["volume-2"],
    "vpn_key": ["key-round", "key"],
    "wallpaper": ["image"],
    "wb_sunny": ["sun"],
    "widgets": ["component", "boxes"],
    "wifi": ["wifi"],
    # direct draw calls
    "search": ["search"],
    "close": ["x"],
    "expand_more": ["chevron-down"],
    # material_glyphs.zig (shell widget glyphs mirrored by the app)
    "cloud": ["cloud"],
    "memory": ["memory-stick", "cpu"],
    "partly_cloudy_day": ["cloud-sun"],
    "battery_full": ["battery-full", "battery"],
    "terminal": ["terminal"],
    # dock weather slot — the WMO codes map to these material names, and the
    # Material Symbols font is not installed, so they must be Lucide too.
    "sunny": ["sun"],
    "foggy": ["cloud-fog", "cloud", "cloudy"],
    "rainy": ["cloud-rain", "cloud-drizzle"],
    "weather_snowy": ["cloud-snow"],
    "thunderstorm": ["cloud-lightning"],
    "nightlight": ["moon"],
    "partly_cloudy_night": ["cloud-moon", "cloud"],
    # media card transport buttons (control center + pear): the real
    # prev / play-pause / next shapes, not three play triangles.
    "skip_previous": ["skip-back"],
    "skip_next": ["skip-forward"],
    "pause": ["pause"],
    # control-center popup aliases (state variants reuse the base shape;
    # tint and the exact shapes carry the difference).
    "signal_wifi_off": ["wifi"],
    "volume_off": ["volume-2"],
    "volume_down": ["volume-2"],
    "mic": ["mic"],
    "mic_off": ["mic-off"],
    "bluetooth_disabled": ["bluetooth"],
    "expand_less": ["chevron-down"],
    "lock": ["lock", "key-round"],
    # Launcher footer: the door-out arrow, and the nightlight state pair
    # (`dark_mode` above is the moon; `light_mode` is the sun).
    "logout": ["log-out"],
    "light_mode": ["sun"],
    "radio_checked": ["square"],
    "radio_unchecked": ["square"],
    "cloud_off": ["cloud"],
    # widget-board glyphs
    "menu": ["menu"],
    # `trash-2` was removed from upstream Lucide (identical geometry to
    # `trash`); keep it first so it is picked up again if it comes back.
    "delete": ["trash-2", "trash"],
    "rocket_launch": ["rocket"],
    "system_update": ["refresh-cw", "rotate-cw"],
    "system_update_alt": ["refresh-cw"],
    "download": ["arrow-down-to-line", "download"],
    "arrow_downward": ["arrow-down-to-line"],
    "install_desktop": ["monitor-down", "download"],
    "autorenew": ["rotate-cw", "refresh-cw"],
    "restart_alt": ["rotate-cw", "refresh-cw"],
    "horizontal_rule": ["minus"],
    # Window-layout switcher (`widgets/layout/layout_paint.cpp`): the union
    # table's Material names, which the slot and its popup both draw.
    "account_tree": ["network"],
    "view_sidebar": ["panel-left"],
    "view_column": ["columns-3"],
    "fullscreen": ["maximize"],
    "view_agenda": ["rows-3"],
    "view_stream": ["rows-4"],
    "splitscreen": ["square-split-horizontal"],
    "vertical_split": ["separator-vertical"],
    "horizontal_split": ["separator-horizontal"],
    "layers": ["layers"],
    "space_dashboard": ["layout-dashboard"],
    "check": ["check"],
    # Shell widget glyph banks (bluetooth / battery / media / volume /
    # overview / taskbar / weather card). The Material Symbols font is gone
    # from the Zig shell entirely, so every runtime name must resolve here.
    "battery": ["battery"],
    "battery_0_bar": ["battery"],
    "battery_1_bar": ["battery-low"],
    "battery_2_bar": ["battery-low"],
    "battery_3_bar": ["battery-medium"],
    "battery_4_bar": ["battery-medium"],
    "battery_5_bar": ["battery-full"],
    "battery_6_bar": ["battery-full"],
    "battery_charging_full": ["battery-charging"],
    "battery_unknown": ["battery-warning", "battery"],
    "bluetooth_searching": ["bluetooth-searching", "bluetooth"],
    "add": ["plus"],
    "album": ["disc-3", "disc-album", "disc"],
    "arrow_back": ["arrow-left"],
    "circle": ["circle"],
    "repeat": ["repeat"],
    "repeat_one": ["repeat-1", "repeat"],
    "shuffle": ["shuffle"],
    "star": ["star"],
    "swap_horiz": ["arrow-left-right", "arrow-right-left"],
    "usb": ["usb"],
    # Bluetooth device kinds.
    "computer": ["monitor"],
    "earbuds": ["earbuds", "headphones"],
    "gamepad": ["gamepad-2", "gamepad"],
    "headphones": ["headphones"],
    "headset_mic": ["headset", "headphones"],
    "phone": ["smartphone"],
    "smartphone": ["smartphone"],
    "speaker": ["speaker"],
    "tv": ["tv"],
    "watch": ["watch"],
    # Weather card chips.
    "thermostat": ["thermometer"],
    "humidity_percentage": ["droplets"],
    "visibility": ["eye"],
    "air": ["wind"],
    # Settings extras that predate the unified table.
    "blocks": ["blocks"],
    "component": ["component"],
    # Taskbar/dock clipboard + settings empty-state and remove buttons.
    "content_paste": ["clipboard-list", "clipboard"],
    "remove": ["minus"],
    "search_off": ["search-x", "search-slash", "search"],
    # m3 navigation fixtures (Home/Library/You/More/Radio demo rows).
    "home": ["house"],
    "person": ["user-round", "user"],
    "library_music": ["list-music", "eighth-notes"],
    "more_horiz": ["ellipsis"],
    "radio": ["radio"],
}


def fetch(url):
    with urllib.request.urlopen(url, timeout=20) as r:
        return r.read().decode("utf-8")


def main():
    resolved = {}  # material -> lucide name
    blobs = {}  # lucide name -> svg text
    failures = []

    for material in sorted(MAP):
        for candidate in MAP[material]:
            try:
                svg = fetch(SRC.format(candidate))
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    continue
                raise
            if "<svg" not in svg:
                continue
            resolved[material] = candidate
            blobs.setdefault(candidate, svg)
            break
        else:
            failures.append((material, MAP[material]))

    if failures:
        for material, cands in failures:
            print(f"ERROR: no lucide icon found for {material} (tried: {', '.join(cands)})",
                  file=sys.stderr)
        sys.exit(1)

    try:
        license_text = fetch(LICENSE_SRC)
    except Exception as e:  # noqa: BLE001 — license is committed; warn only
        print(f"warning: could not refresh LICENSE.txt ({e})", file=sys.stderr)
        license_text = None

    lines = [
        "// Generated by scripts/gen_lucide_icons.py — do not edit by hand.",
        "// Lucide icons (ISC License, https://lucide.dev) vendored in lucide/.",
        "// Maps each material glyph name the settings app draws to its SVG.",
        "// State variants (`mic_off`, `signal_wifi_off`, `volume_off`, …) resolve",
        "// to their base shape: the tint carries the state, not a second drawing.",
        "",
        "pub const Entry = struct {",
        "    material: []const u8,",
        "    lucide: []const u8,",
        "    svg: []const u8,",
        "};",
        "",
        "pub const map = [_]Entry{",
    ]
    for material in sorted(resolved):
        lucide = resolved[material]
        lines.append(
            f'    .{{ .material = "{material}", .lucide = "{lucide}", '
            f'.svg = @embedFile("lucide/{lucide}.svg") }},'
        )
    lines.append("};")
    lines.append("")

    for out_dir in OUT_DIRS:
        svg_dir = os.path.join(out_dir, "lucide")
        os.makedirs(svg_dir, exist_ok=True)
        for name, svg in blobs.items():
            with open(os.path.join(svg_dir, name + ".svg"), "w") as f:
                f.write(svg)
        if license_text is not None:
            with open(os.path.join(svg_dir, "LICENSE.txt"), "w") as f:
                f.write(license_text)
        with open(os.path.join(out_dir, "lucide_icons.zig"), "w") as f:
            f.write("\n".join(lines))

    print(f"vendored {len(blobs)} svg files, {len(resolved)} material mappings")


if __name__ == "__main__":
    main()
