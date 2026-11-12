{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    zig_0_16
    pkg-config
    wayland
    wayland-protocols
    wayland-scanner
    libxkbcommon
    cairo
    pango
    librsvg
    libwebp
    pipewire
    pam
    curl
    xz
    zenity
    git
  ];

  shellHook = ''
    echo "Event Horizon dev shell (nix-shell)"
    echo "Zig: $(zig version 2>/dev/null || echo 'not found')"
    echo "Build: ./build.sh --no-install --skip-deps   (or: zig build)"
  '';
}
