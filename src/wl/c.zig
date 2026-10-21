pub const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-client-protocol.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("idle-inhibit-unstable-v1-client-protocol.h");
    @cInclude("ext-session-lock-v1-client-protocol.h");
    @cInclude("xdg-activation-v1-client-protocol.h");
    @cInclude("ext-idle-notify-v1-client-protocol.h");
    @cInclude("wlr-gamma-control-unstable-v1-client-protocol.h");
    @cInclude("ext-data-control-v1-client-protocol.h");
    @cInclude("wlr-data-control-unstable-v1-client-protocol.h");
    @cInclude("virtual-keyboard-unstable-v1-client-protocol.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("wlr-foreign-toplevel-management-unstable-v1-client-protocol.h");
    @cInclude("ext-foreign-toplevel-list-v1-client-protocol.h");
    @cInclude("ext-workspace-v1-client-protocol.h");
    @cInclude("dwl-ipc-unstable-v2-client-protocol.h");
    @cInclude("hyprland-toplevel-export-v1-client-protocol.h");
    @cInclude("wlr-screencopy-unstable-v1-client-protocol.h");
    @cInclude("ext-image-copy-capture-v1-client-protocol.h");
    @cInclude("ext-image-capture-source-v1-client-protocol.h");
    // Logical output layout (global origin + logical size). wl_output only
    // carries mode pixels and a transform/geometry origin; screenshots need
    // the compositor's logical coordinate space to place regions and convert
    // them to output-local pixels.
    @cInclude("xdg-output-unstable-v1-client-protocol.h");
});
