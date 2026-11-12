# Copyright 2026
# Distributed under the terms of the GNU General Public License v3

EAPI=8

inherit git-r3

DESCRIPTION="Event Horizon - Wayland desktop shell written in Zig"
HOMEPAGE="https://github.com/visadaking/Event-Horizon"
EGIT_REPO_URI="https://github.com/visadaking/Event-Horizon.git"

LICENSE="GPL-3"
SLOT="0"
KEYWORDS=""
IUSE="pipewire"

# Zig >= 0.16.0 required. If system zig is too old, build manually with upstream Zig.
BDEPEND="
	>=dev-lang/zig-0.16.0
	dev-util/pkgconf
	dev-util/wayland-scanner
	virtual/pkgconfig
"
RDEPEND="
	dev-libs/wayland
	dev-libs/wayland-protocols
	x11-libs/libxkbcommon
	x11-libs/cairo
	x11-libs/pango
	gnome-base/librsvg
	media-libs/libwebp
	sys-libs/pam
	pipewire? ( media-video/pipewire )
	gnome-extra/zenity
"
DEPEND="${RDEPEND}"

src_compile() {
	# Release build; adjust CPU target as desired
	zig build -Doptimize=ReleaseFast --prefix "${S}/.dest/usr" || die "zig build failed"
}

src_install() {
	if [[ -d "${S}/.dest/usr" ]]; then
		cp -a "${S}/.dest/usr/." "${ED}/usr/" || die
	else
		# fallback: install known binaries if zig build used default prefix
		dobin zig-out/bin/horizon \
			zig-out/bin/eh-ipc \
			zig-out/bin/horizon-wallpaper \
			zig-out/bin/horizon-dock \
			zig-out/bin/horizon-settings \
			zig-out/bin/horizon-audio-center \
			zig-out/bin/horizon-overview \
			zig-out/bin/horizon-desktop-widgets \
			zig-out/bin/horizon-notifications \
			zig-out/bin/horizon-polkit-agent \
			zig-out/bin/horizon-taskbar \
			zig-out/bin/horizon-desktop \
			zig-out/bin/horizonClipboardDaemon \
			zig-out/bin/horizon-clipstack \
			zig-out/bin/horizon-clipstack-pick \
			zig-out/bin/horizon-idle \
			zig-out/bin/horizon-lock || die "install binaries failed"
	fi

	dodoc README.md CHANGELOG.md docs/usage.md || die
}

pkg_postinst() {
	elog "Event Horizon is a Wayland desktop shell (not a compositor)."
	elog "Run 'horizon' inside a supported Wayland session and see docs/usage.md."
	elog "Logs are written to ~/EH-logs/; check status with 'eh-ipc status'."
}
