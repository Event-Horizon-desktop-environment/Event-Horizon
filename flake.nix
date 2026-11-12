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
        zig = pkgs.zig_0_16;
        buildInputs = with pkgs; [
          wayland
          wayland-protocols
          libxkbcommon
          cairo
          pango
          librsvg
          libwebp
          pipewire
          pam
        ];
        nativeBuildInputs = with pkgs; [
          zig
          pkg-config
          wayland-scanner
          makeWrapper
        ];
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "event-horizon";
          version = "0.1.5";
          src = self;

          inherit nativeBuildInputs buildInputs;

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            zig build -Doptimize=ReleaseFast -p $out
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            # zig build -p installs binaries to $out/bin; ensure data/assets are available if expected
            if [ -d assets ]; then
              mkdir -p $out/share/event-horizon
              cp -r assets $out/share/event-horizon/ 2>/dev/null || true
            fi
            if [ -d matugen ]; then
              mkdir -p $out/share/event-horizon
              cp -r matugen $out/share/event-horizon/ 2>/dev/null || true
            fi
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Event Horizon Wayland desktop shell";
            homepage = "https://github.com/Event-Horizon-desktop-environment/Event-Horizon";
            license = licenses.gpl3Only;
            platforms = platforms.linux;
            mainProgram = "horizon";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = buildInputs ++ nativeBuildInputs ++ (with pkgs; [ curl xz zenity git ]);

          shellHook = ''
            echo "Event Horizon dev shell"
            echo "Zig: $(zig version 2>/dev/null || echo 'not found')"
            echo "Build: ./build.sh --no-install --skip-deps   (or: zig build)"
          '';
        };
      }
    );
}
