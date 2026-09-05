#!/bin/sh

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Installs Steam and selkies-bwrap into a Debian-based image or system.
#
# Steam's launcher package comes from Valve's repository, which the package
# itself registers, together with the 32-bit host libraries the 32-bit client
# and games need and the libraries Steam's metapackages only recommend but
# games reach for (Vulkan, EGL, video acceleration and XKB of both
# architectures). fakechroot is installed for the hosts that deny ptrace.
# steamdeps, the client's dependency check, would drive apt through pkexec at
# every start; the system carries what it checks for, so it is diverted to a
# stub that answers that everything is there. selkies-bwrap is installed
# beside this script's copy, or downloaded from the repository when run alone,
# and Steam's own launcher is diverted so that every way of starting Steam --
# the menu entry, a steam:// link, a shell -- names it. Without that, Steam's
# requirements check finds no working bubblewrap and refuses to start with
# "Steam now requires user namespaces to be enabled".
#
# Run as root, or under fakeroot in a rootless image build.

set -eu

prefix="${PREFIX:-/usr/local}"
ref="${SELKIES_BWRAP_REF:-main}"
here="$(dirname "$(readlink -f "$0")")"
export DEBIAN_FRONTEND=noninteractive

apt_install() {
    apt-get install --no-install-recommends -y "$@"
}

command -v curl > /dev/null 2>&1 || { apt-get update && apt_install curl ca-certificates; }

if ! dpkg --print-foreign-architectures | grep -qx i386; then
    dpkg --add-architecture i386
fi

curl -o /tmp/steam-launcher.deb -fsSL --retry 5 --retry-all-errors --retry-delay 3 --retry-connrefused --retry-max-time 180 \
    "https://repo.steampowered.com/steam/archive/stable/steam_latest.deb"
apt-get update
apt_install /tmp/steam-launcher.deb
rm -f /tmp/steam-launcher.deb
apt-get update
apt_install \
    steam-libs-amd64 \
    steam-libs-i386 \
    libfakechroot \
    libfakechroot:i386 \
    libvulkan1 \
    libvulkan1:i386 \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    libegl1:i386 \
    libgles2:i386 \
    libglx-mesa0:i386 \
    libva2:i386 \
    libva-drm2:i386 \
    libva-x11-2:i386 \
    libxkbcommon-x11-0:i386 \
    libfontconfig1:i386 \
    libxss1:i386 \
    libasound2-plugins:i386 \
    python3

if [ ! -e /usr/bin/steamdeps.distrib ]; then
    dpkg-divert --rename --divert /usr/bin/steamdeps.distrib /usr/bin/steamdeps
fi
printf '#!/bin/sh\nexit 0\n' > /usr/bin/steamdeps
chmod 755 /usr/bin/steamdeps

mkdir -p "${prefix}/bin"
if [ -f "${here}/selkies-bwrap" ]; then
    install -m 755 "${here}/selkies-bwrap" "${prefix}/bin/selkies-bwrap"
else
    curl -o "${prefix}/bin/selkies-bwrap" -fsSL --retry 5 --retry-delay 3 --retry-connrefused --retry-max-time 180 \
        "https://raw.githubusercontent.com/selkies-project/selkies-bwrap/${ref}/selkies-bwrap"
    chmod 755 "${prefix}/bin/selkies-bwrap"
fi

# The launcher is a symbolic link to the client's own script; diverting it
# leaves the package free to update the script, and an already-set BWRAP wins
# so that a session can still choose another one. The client reads its own
# package name out of argv[0] and refuses to start under any other, so the
# replacement passes the original name on.
if [ ! -e /usr/bin/steam.distrib ]; then
    dpkg-divert --rename --divert /usr/bin/steam.distrib /usr/bin/steam
fi
cat > /usr/bin/steam <<EOF
#!/bin/bash
# Start Steam with a bubblewrap that works without user namespaces.
BWRAP="\${BWRAP:-${prefix}/bin/selkies-bwrap}"
export BWRAP
exec -a steam /usr/bin/steam.distrib "\$@"
EOF
chmod 755 /usr/bin/steam

apt-get clean
rm -rf /var/lib/apt/lists/*
echo "selkies-bwrap installed at ${prefix}/bin/selkies-bwrap and wired into /usr/bin/steam"
