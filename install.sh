#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Installs the btusb early-ACL-hold fix with DKMS, so it is rebuilt for every new kernel.
# Usage: sudo ./install.sh [--reload]
#   --reload  reload btusb now (Bluetooth devices disconnect for a few seconds);
#             without it the fix takes effect on the next boot.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

RELOAD=0
for arg in "$@"; do
	case $arg in
	--reload) RELOAD=1 ;;
	*) echo "usage: sudo ./install.sh [--reload]"; exit 2 ;;
	esac
done

NAME=$(sed -n 's/^PACKAGE_NAME="\(.*\)"$/\1/p' dkms.conf)
VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' dkms.conf)
KVER=$(uname -r)
log() { echo "==> $*"; }

if command -v dnf >/dev/null; then
	log "Installing build dependencies (dnf)"
	if ! dnf -y install dkms "kernel-devel-$KVER" gcc make binutils patch curl xz elfutils-libelf-devel; then
		echo "Could not install kernel-devel for the running kernel $KVER."
		echo "Update the kernel (sudo dnf upgrade kernel*), reboot and run this script again."
		exit 1
	fi
else
	for tool in dkms gcc make objdump patch curl modinfo; do
		command -v "$tool" >/dev/null || { echo "Missing '$tool'. Install dkms, the headers for kernel $KVER, gcc, make, binutils, patch and curl, then run again."; exit 1; }
	done
	[ -d "/lib/modules/$KVER/build" ] || { echo "Missing kernel headers for $KVER (/lib/modules/$KVER/build)."; exit 1; }
fi

# Remove copies installed by hand before this repository existed.
for old in /lib/modules/*/updates/btusb.ko; do
	if [ ! -f "$old" ] || ! modinfo -F parm "$old" 2>/dev/null | grep -q '^early_acl_hold_ms:'; then
		continue
	fi
	kv=$(basename "$(dirname "$(dirname "$old")")")
	log "Removing manually installed $old"
	rm -f "$old"
	depmod -a "$kv"
done

# Replace any previously added version.
for added in $(dkms status -m "$NAME" 2>/dev/null | sed -n "s|^$NAME/\([^,: ]*\).*|\1|p" | sort -u); do
	log "Removing $NAME/$added from DKMS"
	dkms remove -m "$NAME" -v "$added" --all || true
	rm -rf "/usr/src/$NAME-$added"
done
rm -rf "/usr/src/$NAME-$VERSION"
install -d "/usr/src/$NAME-$VERSION/patches"
install -m 0644 dkms.conf "/usr/src/$NAME-$VERSION/"
install -m 0755 build.sh "/usr/src/$NAME-$VERSION/"
install -m 0644 patches/*.patch "/usr/src/$NAME-$VERSION/patches/"

log "Building for kernel $KVER"
dkms add -m "$NAME" -v "$VERSION"
if ! dkms install -m "$NAME" -v "$VERSION" -k "$KVER"; then
	echo "Build failed; see the log above. The stock btusb driver stays in use."
	exit 1
fi
# Also prepare any newer kernel that is installed but not booted yet.
for dir in /lib/modules/*/; do
	kv=$(basename "$dir")
	if [ "$kv" = "$KVER" ] || [ ! -d "$dir/build" ]; then
		continue
	fi
	[ "$(printf '%s\n%s\n' "$KVER" "$kv" | sort -V | tail -1)" = "$kv" ] || continue
	log "Building for installed kernel $kv"
	dkms install -m "$NAME" -v "$VERSION" -k "$kv" || echo "Warning: build for $kv failed; it will use the stock driver."
done

log "btusb for $KVER now resolves to $(modinfo -k "$KVER" -n btusb)"
if [ "$RELOAD" = 1 ]; then
	log "Reloading btusb (Bluetooth devices reconnect in a few seconds)"
	modprobe -r btusb && modprobe btusb
	sleep 2
	log "Loaded early_acl_hold_ms=$(cat /sys/module/btusb/parameters/early_acl_hold_ms)"
else
	log "Done. Reboot (or run with --reload) to start using the fixed driver."
fi
