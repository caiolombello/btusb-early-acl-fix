#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Removes the btusb early-ACL-hold fix; the distro's stock driver is used again.
# Usage: sudo ./uninstall.sh [--reload]
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
NAME=$(sed -n 's/^PACKAGE_NAME="\(.*\)"$/\1/p' dkms.conf)
for added in $(dkms status -m "$NAME" 2>/dev/null | sed -n "s|^$NAME/\([^,: ]*\).*|\1|p" | sort -u); do
	dkms remove -m "$NAME" -v "$added" --all
	rm -rf "/usr/src/$NAME-$added"
done
echo "==> btusb now resolves to $(modinfo -n btusb)"
if [ "${1:-}" = --reload ]; then
	modprobe -r btusb && modprobe btusb
	echo "==> Stock btusb reloaded"
else
	echo "==> Reboot (or run with --reload) to go back to the stock driver."
fi
