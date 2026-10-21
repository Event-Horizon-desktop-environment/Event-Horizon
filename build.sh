#!/usr/bin/env bash
#
# Event Horizon build + install script.
#
#   ./build.sh                 detect the best x86-64 level, build, install to /usr
#   ./build.sh --cpu v3        force x86-64-v3
#   ./build.sh --no-install    build only (zig-out/bin)
#   ./build.sh --skip-deps     never call the package manager
#
# The final install asks for privilege through pkexec (falling back to sudo
# when pkexec is unavailable) and writes binaries to /usr/bin.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

readonly ZIG_MIN_VERSION="0.16.0"
readonly OPTIMIZE="ReleaseFast"
readonly CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/event-horizon"
readonly ZIG_CACHE_DIR="$CACHE_ROOT/zig-$ZIG_MIN_VERSION"

PREFIX="/usr"
INSTALL_BINARIES=(
    horizon
    eh-ipc
    horizon-wallpaper
    horizon-dock
    horizon-settings
    horizon-audio-center
    horizon-overview
    horizon-desktop-widgets
    horizon-notifications
    horizon-polkit-agent
    horizon-taskbar
    horizon-desktop
    horizonClipboardDaemon
    horizon-clipstack
    horizon-clipstack-pick
)

DO_DEPS=1
DO_INSTALL=1
DEPS_ONLY=0
CPU_REQUEST=""
JOBS=""
ZIG_BIN="${ZIG:-}"
DISTRO_FAMILY="unknown"
PKGS=()

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Event Horizon build script

Usage: ./build.sh [options]

Options:
  --cpu LEVEL        x86-64 level: v2, v3, v4, native, or baseline.
                     Default: auto-detect the highest level this CPU supports.
  --prefix PATH      Install prefix (default: /usr). Binaries go to PATH/bin.
  --no-install       Build only; leave everything in zig-out/.
  --skip-deps        Do not install missing system packages.
  --deps-only        Install dependencies and exit.
  --jobs N           Limit parallel build jobs (passed to zig build -jN).
  --zig PATH         Use a specific Zig executable.
  -h, --help         Show this help.

Environment:
  ZIG                Same as --zig.
  EH_CPU             Same as --cpu.

Examples:
  ./build.sh
  ./build.sh --cpu v3
  ./build.sh --no-install --jobs 8
  ./build.sh --deps-only
EOF
}

while (($#)); do
    case "$1" in
        --cpu)
            [[ $# -ge 2 ]] || die "--cpu needs a value"
            CPU_REQUEST="$2"
            shift 2
            ;;
        --cpu=*)
            CPU_REQUEST="${1#*=}"
            shift
            ;;
        --prefix)
            [[ $# -ge 2 ]] || die "--prefix needs a value"
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#*=}"
            shift
            ;;
        --no-install)
            DO_INSTALL=0
            shift
            ;;
        --skip-deps|--no-deps)
            DO_DEPS=0
            shift
            ;;
        --deps-only)
            DEPS_ONLY=1
            DO_INSTALL=0
            shift
            ;;
        --jobs)
            [[ $# -ge 2 ]] || die "--jobs needs a value"
            JOBS="$2"
            shift 2
            ;;
        --jobs=*)
            JOBS="${1#*=}"
            shift
            ;;
        --zig)
            [[ $# -ge 2 ]] || die "--zig needs a path"
            ZIG_BIN="$2"
            shift 2
            ;;
        --zig=*)
            ZIG_BIN="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac
done

if [[ -z "$CPU_REQUEST" && -n "${EH_CPU:-}" ]]; then
    CPU_REQUEST="$EH_CPU"
fi

[[ "$PREFIX" = /* ]] || die "--prefix must be an absolute path"
[[ -z "$JOBS" || "$JOBS" =~ ^[0-9]+$ ]] || die "--jobs must be a number"

run_privileged() {
    if ((EUID == 0)); then
        "$@"
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "pkexec and sudo are both unavailable; run this script as root"
    fi
}

version_ge() {
    local have="$1" want="$2"
    have="${have%%[!0-9.]*}"
    want="${want%%[!0-9.]*}"
    local h1=0 h2=0 h3=0 w1=0 w2=0 w3=0
    IFS=. read -r h1 h2 h3 <<<"$have"
    IFS=. read -r w1 w2 w3 <<<"$want"
    h1=${h1:-0}; h2=${h2:-0}; h3=${h3:-0}
    w1=${w1:-0}; w2=${w2:-0}; w3=${w3:-0}
    ((h1 > w1)) && return 0
    ((h1 < w1)) && return 1
    ((h2 > w2)) && return 0
    ((h2 < w2)) && return 1
    ((h3 >= w3))
}

zig_version_ok() {
    local bin="$1" version
    [[ -x "$bin" ]] || return 1
    version="$("$bin" version 2>/dev/null)" || return 1
    version_ge "$version" "$ZIG_MIN_VERSION"
}

detect_distro() {
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"
        like="${ID_LIKE:-}"
    fi

    case " $id $like " in
        *arch*|*manjaro*|*endeavouros*|*cachyos*|*garuda*)
            DISTRO_FAMILY="arch"
            ;;
        *fedora*|*rhel*|*centos*|*rocky*|*almalinux*)
            DISTRO_FAMILY="fedora"
            ;;
        *debian*|*ubuntu*|*linuxmint*|*pop*|*pika*|*zorin*|*elementary*)
            DISTRO_FAMILY="debian"
            ;;
        *suse*|*opensuse*|*sles*)
            DISTRO_FAMILY="suse"
            ;;
        *)
            DISTRO_FAMILY="unknown"
            ;;
    esac
}

distro_packages() {
    case "$DISTRO_FAMILY" in
        arch)
            PKGS=(
                pkgconf wayland wayland-protocols libxkbcommon cairo pango
                librsvg libwebp pipewire curl xz
            )
            ;;
        fedora)
            PKGS=(
                pkgconf-pkg-config wayland-devel wayland-protocols-devel
                libxkbcommon-devel cairo-devel pango-devel librsvg2-devel
                libwebp-devel pipewire-devel curl xz
            )
            ;;
        debian)
            PKGS=(
                pkg-config libwayland-dev libwayland-bin wayland-protocols
                libxkbcommon-dev libcairo2-dev libpango1.0-dev librsvg2-dev
                libwebp-dev libpipewire-0.3-dev curl xz-utils
            )
            ;;
        suse)
            PKGS=(
                pkg-config wayland-devel wayland-protocols-devel
                libxkbcommon-devel cairo-devel pango-devel librsvg-devel
                libwebp-devel pipewire-devel curl xz
            )
            ;;
        *)
            die "unsupported distro; install the Wayland/Cairo/Pango/librsvg/libwebp/PipeWire development packages manually"
            ;;
    esac
}

install_packages() {
    distro_packages
    log "Installing system packages with the ${DISTRO_FAMILY} package manager"
    case "$DISTRO_FAMILY" in
        arch)
            run_privileged pacman -S --needed --noconfirm "${PKGS[@]}"
            ;;
        fedora)
            run_privileged dnf install -y "${PKGS[@]}"
            ;;
        debian)
            run_privileged sh -c 'apt-get update && apt-get install -y "$@"' sh "${PKGS[@]}"
            ;;
        suse)
            run_privileged zypper --non-interactive install "${PKGS[@]}"
            ;;
    esac
}

missing_dependencies() {
    local missing=() package
    command -v pkg-config >/dev/null 2>&1 || missing+=("pkg-config")
    command -v wayland-scanner >/dev/null 2>&1 || missing+=("wayland-scanner")

    if command -v pkg-config >/dev/null 2>&1; then
        for package in \
            wayland-client \
            wayland-protocols \
            xkbcommon \
            cairo \
            pangocairo \
            librsvg-2.0 \
            libwebp \
            libpipewire-0.3
        do
            pkg-config --exists "$package" 2>/dev/null || missing+=("$package")
        done
    fi

    ((${#missing[@]} == 0)) || printf '%s\n' "${missing[@]}"
}

dependencies_ready() {
    [[ -z "$(missing_dependencies)" ]]
}

ensure_dependencies() {
    local missing
    if dependencies_ready; then
        log "Build dependencies are installed"
        return
    fi

    missing="$(missing_dependencies | paste -sd ', ' -)"
    warn "Missing build dependencies: $missing"

    ((DO_DEPS == 1)) || die "install the missing packages or rerun without --skip-deps"
    detect_distro
    install_packages

    if ! dependencies_ready; then
        missing="$(missing_dependencies | paste -sd ', ' -)"
        die "dependencies are still missing: $missing"
    fi
    log "Build dependencies installed"
}

ensure_download_tools() {
    local need=0
    command -v tar >/dev/null 2>&1 || need=1
    command -v xz >/dev/null 2>&1 || need=1
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        need=1
    fi
    if ((need == 1)); then
        ((DO_DEPS == 1)) || die "need curl or wget, tar, and xz to download Zig"
        detect_distro
        install_packages
    fi
    command -v tar >/dev/null 2>&1 || die "tar is required"
    command -v xz >/dev/null 2>&1 || die "xz is required"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
        die "curl or wget is required to download Zig"
}

fetch_url() {
    local url="$1" output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 20 --progress-bar -o "$output" "$url"
    else
        wget -O "$output" "$url"
    fi
}

download_zig() {
    local arch zig_arch url tmp archive zig_path
    case "$(uname -m)" in
        x86_64) zig_arch="x86_64" ;;
        aarch64|arm64) zig_arch="aarch64" ;;
        *) die "no Zig download configured for architecture $(uname -m)" ;;
    esac

    ensure_download_tools

    tmp="$(mktemp -d)"
    archive="$tmp/zig.tar.xz"

    log "Downloading Zig $ZIG_MIN_VERSION for $zig_arch"
    for url in \
        "https://ziglang.org/download/$ZIG_MIN_VERSION/zig-$zig_arch-linux-$ZIG_MIN_VERSION.tar.xz" \
        "https://ziglang.org/download/$ZIG_MIN_VERSION/zig-linux-$zig_arch-$ZIG_MIN_VERSION.tar.xz"
    do
        if fetch_url "$url" "$archive"; then
            break
        fi
        rm -f "$archive"
    done
    [[ -s "$archive" ]] || die "could not download Zig $ZIG_MIN_VERSION"

    tar -xJf "$archive" -C "$tmp"
    zig_path="$(find "$tmp" -maxdepth 3 -type f -name zig -print -quit)"
    [[ -n "$zig_path" ]] || die "the downloaded archive does not contain a zig binary"

    rm -rf "$ZIG_CACHE_DIR"
    mkdir -p "$ZIG_CACHE_DIR"
    cp -a "$(dirname "$zig_path")/." "$ZIG_CACHE_DIR/"
    chmod +x "$ZIG_CACHE_DIR/zig"
    rm -rf "$tmp"

    ZIG_BIN="$ZIG_CACHE_DIR/zig"
    zig_version_ok "$ZIG_BIN" || die "downloaded Zig failed its version check"
    log "Using Zig $("$ZIG_BIN" version) from $ZIG_BIN"
}

ensure_zig() {
    local system_zig=""
    if [[ -n "$ZIG_BIN" ]]; then
        zig_version_ok "$ZIG_BIN" || die "$ZIG_BIN is not Zig $ZIG_MIN_VERSION or newer"
        return
    fi

    if command -v zig >/dev/null 2>&1; then
        system_zig="$(command -v zig)"
        if zig_version_ok "$system_zig"; then
            ZIG_BIN="$system_zig"
            log "Using Zig $("$ZIG_BIN" version) from $ZIG_BIN"
            return
        fi
        warn "system Zig is $("$system_zig" version 2>/dev/null || echo unknown); need $ZIG_MIN_VERSION or newer"
    fi

    if [[ -x "$ZIG_CACHE_DIR/zig" ]] && zig_version_ok "$ZIG_CACHE_DIR/zig"; then
        ZIG_BIN="$ZIG_CACHE_DIR/zig"
        log "Using cached Zig $("$ZIG_BIN" version) from $ZIG_BIN"
        return
    fi

    download_zig
}

normalize_cpu() {
    local value="$1"
    case "$value" in
        v1|baseline|x86_64|x86_64_v1) printf 'baseline\n' ;;
        v2|v3|v4) printf 'x86_64_%s\n' "$value" ;;
        x86_64_v2|x86_64_v3|x86_64_v4) printf '%s\n' "$value" ;;
        native) printf 'native\n' ;;
        *) die "unknown CPU level: $value (use v2, v3, v4, native, or baseline)" ;;
    esac
}

detect_cpu_model() {
    local flags
    if [[ "$(uname -m)" != "x86_64" ]]; then
        printf '\n'
        return
    fi

    flags="$(awk '/^flags/{print; exit}' /proc/cpuinfo 2>/dev/null || true)"
    if [[ -z "$flags" ]]; then
        printf 'baseline\n'
        return
    fi

    has_all() {
        local flag
        for flag in "$@"; do
            grep -qw -- "$flag" <<<"$flags" || return 1
        done
    }
    has_any() {
        local flag
        for flag in "$@"; do
            grep -qw -- "$flag" <<<"$flags" && return 0
        done
        return 1
    }

    # x86-64-v4: AVX-512 foundation + byte/word, conflict detection,
    # doubleword/quadword, and vector length.
    if has_all avx512f avx512bw avx512cd avx512dq avx512vl; then
        printf 'x86_64_v4\n'
    # x86-64-v3: AVX2 + BMI1/BMI2, FMA, F16C, MOVBE, LZCNT, XSAVE.
    elif has_all avx2 bmi1 bmi2 fma f16c movbe xsave && has_any lzcnt abm; then
        printf 'x86_64_v3\n'
    # x86-64-v2: SSE3, SSSE3, SSE4.1/4.2, POPCNT, CMPXCHG16B, LAHF/SAHF.
    elif has_all ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm && has_any sse3 pni; then
        printf 'x86_64_v2\n'
    else
        printf 'baseline\n'
    fi
}

choose_cpu() {
    if [[ -n "$CPU_REQUEST" ]]; then
        if [[ "$(uname -m)" != "x86_64" ]]; then
            case "$CPU_REQUEST" in
                native|baseline) ;;
                *) die "CPU levels v2/v3/v4 only apply to x86_64; use --cpu native on $(uname -m)" ;;
            esac
        fi
        normalize_cpu "$CPU_REQUEST"
    else
        detect_cpu_model
    fi
}

build_shell() {
    local cpu_model="$1"
    local args=(build "-Doptimize=$OPTIMIZE")

    if [[ -n "$cpu_model" ]]; then
        args+=("-Dcpu=$cpu_model")
    fi
    if [[ -n "$JOBS" ]]; then
        args+=("-j$JOBS")
    fi

    log "Building Event Horizon ($OPTIMIZE${cpu_model:+, cpu=$cpu_model})"
    "$ZIG_BIN" "${args[@]}"
}

install_system() {
    local stage
    log "Installing ${#INSTALL_BINARIES[@]} binaries to $PREFIX/bin"
    run_privileged sh -c '
        set -e
        repo=$1
        prefix=$2
        shift 2
        install -d "$prefix/bin"
        for name in "$@"; do
            install -m755 "$repo/zig-out/bin/$name" "$prefix/bin/$name"
        done
    ' sh "$SCRIPT_DIR" "$PREFIX" "${INSTALL_BINARIES[@]}"

    # Stage icons without root, then copy the tree in one privileged step.
    stage="$(mktemp -d)"
    cleanup_stage() { rm -rf "$stage"; }
    trap cleanup_stage EXIT
    "$ZIG_BIN" build install-icons --prefix "$stage" >/dev/null
    if [[ -d "$stage/icons" ]]; then
        log "Installing icon theme to $PREFIX/share/icons"
        run_privileged sh -c '
            set -e
            stage=$1
            prefix=$2
            install -d "$prefix/share/icons"
            cp -a "$stage/icons/." "$prefix/share/icons/"
        ' sh "$stage" "$PREFIX"
    fi

    if [[ -d "$SCRIPT_DIR/zig-out/share/event-horizon" ]]; then
        log "Installing matugen templates to $PREFIX/share/event-horizon"
        run_privileged sh -c '
            set -e
            source_dir=$1
            prefix=$2
            install -d "$prefix/share/event-horizon"
            cp -a "$source_dir/." "$prefix/share/event-horizon/"
        ' sh "$SCRIPT_DIR/zig-out/share/event-horizon" "$PREFIX"
    fi

    if [[ -f "$SCRIPT_DIR/zig-out/share/licenses/event-horizon/LICENSE" ]]; then
        run_privileged install -Dm644 \
            "$SCRIPT_DIR/zig-out/share/licenses/event-horizon/LICENSE" \
            "$PREFIX/share/licenses/event-horizon/LICENSE"
    fi

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        run_privileged gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
    fi

    rm -rf "$stage"
    trap - EXIT
    log "Installed. Run 'horizon' from your Wayland session."
}

log "Event Horizon build"
log "Repository: $SCRIPT_DIR"

ensure_dependencies
if ((DEPS_ONLY == 1)); then
    log "Dependencies installed; exiting because of --deps-only"
    exit 0
fi

ensure_zig
CPU_MODEL="$(choose_cpu)"
if [[ -n "$CPU_MODEL" ]]; then
    log "CPU target: $CPU_MODEL"
else
    log "CPU target: Zig native default"
fi

build_shell "$CPU_MODEL"

if ((DO_INSTALL == 1)); then
    install_system
else
    log "Build complete: $SCRIPT_DIR/zig-out/bin"
fi
