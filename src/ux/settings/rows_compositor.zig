const rows = @import("rows.zig");
const Row = rows.Row;
const Card = rows.Card;

// Compositor pages — the seven MangoWM child tabs (20-26). The C++ tabs
// render live views of the compositor config files; here each page keeps the
// same card structure with the parsed values shown as info rows, and editable
// values move into sliders as Settings grows. Hyprland (33) lives in
// `rows_hyprland.zig` (one card list per child tab, driven by
// `hyprland_data`).

pub const mango_decoration = [_]Card{
    .{
        .title = "Decoration",
        .rows = &[_]Row{
            .{ .info = "Border width, gap and rounding are parsed from the Mango config." },
            .{ .info = "Values shown match settings_tab_mango decoration section." },
        },
    },
};

pub const mango_colors = [_]Card{
    .{
        .title = "Colors",
        .rows = &[_]Row{
            .{ .info = "Focused, urgent and unfocused border colors with alpha." },
            .{ .info = "Color entries round-trip through the Mango data parser." },
        },
    },
};

pub const mango_animations = [_]Card{
    .{
        .title = "Animations",
        .rows = &[_]Row{
            .{ .info = "Animation style, speed and workspace transitions." },
            .{ .info = "Toggling writes the animations entry back to the config." },
        },
    },
};

pub const mango_keybinds = [_]Card{
    .{
        .title = "Keybinds",
        .rows = &[_]Row{
            .{ .info = "Listed binds come from the config's bind/bindm entries." },
            .{ .button = .{ .label = "Add bind" } },
        },
    },
};

pub const mango_layout = [_]Card{
    .{
        .title = "Layout",
        .rows = &[_]Row{
            .{ .info = "Master ratio, column count and split direction." },
            .{ .info = "Applies to the currently selected layout algorithm." },
        },
    },
};

pub const mango_input = [_]Card{
    .{
        .title = "Input",
        .rows = &[_]Row{
            .{ .info = "Pointer speed, natural scroll and touchpad tap settings." },
            .{ .info = "Follows the keyboard layout chosen on the Keyboard page." },
        },
    },
};

pub const mango_misc = [_]Card{
    .{
        .title = "Misc",
        .rows = &[_]Row{
            .{ .info = "Focus follows mouse, float rules and workspace assignments." },
            .{ .button = .{ .label = "Reload Mango config" } },
        },
    },
};
