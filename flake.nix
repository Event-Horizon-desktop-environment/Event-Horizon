{
  description = "Event Horizon Wayland desktop shell - dev/build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
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

          # help pkg-config/zig find libs in the shell when needed
          shellHook = ''
            echo "Event Horizon dev shell"
            echo "Zig: $(zig version 2>/dev/null || echo 'not found')"
            echo "Build: ./build.sh --no-install --skip-deps   (or: zig build)"
          '';
        };
      }
    );
}
