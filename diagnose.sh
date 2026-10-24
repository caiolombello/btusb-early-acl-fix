#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Checks whether this machine shows the early-ACL race and whether the fix is active.
# No root needed on most distros (reads the kernel log and sysfs).
set -uo pipefail

echo "Kernel: $(uname -r)"
echo
echo "USB Bluetooth adapters:"
found=0
for intf in /sys/bus/usb/devices/*:1.0; do
	[ "$(cat "$intf/bInterfaceClass" 2>/dev/null)" = e0 ] || continue
	dev=${intf%:1.0}
	printf '  %s:%s  %s %s\n' "$(cat "$dev/idVendor")" "$(cat "$dev/idProduct")" \
		"$(cat "$dev/manufacturer" 2>/dev/null)" "$(cat "$dev/product" 2>/dev/null)"
	found=1
done
[ "$found" = 1 ] || echo "  (none found)"
echo

if journalctl -k -b -q --no-pager >/dev/null 2>&1; then
	klog=$(journalctl -k -b -q --no-pager -o short-monotonic)
else
	klog=$(dmesg 2>/dev/null) || { echo "Cannot read the kernel log (try with sudo)."; klog=""; }
fi
# Only count what happened since the currently running btusb was loaded.
klog=$(awk '/registered new interface driver btusb/ {buf=""} {buf=buf $0 "\n"} END {printf "%s", buf}' <<< "$klog")
dropped=$(grep -c 'ACL packet for unknown connection handle' <<< "$klog")
held=$(grep -c 'Delivered early ACL for handle' <<< "$klog")
echo "Since btusb was loaded: $dropped dropped early packet(s), $held packet(s) saved by the fix"
grep -E 'ACL packet for unknown connection handle|Delivered early ACL|Early ACL for unknown' <<< "$klog" | tail -5 | sed 's/^/  /'
echo

if [ -r /sys/module/btusb/parameters/early_acl_hold_ms ]; then
	echo "Fix: ACTIVE (early_acl_hold_ms=$(cat /sys/module/btusb/parameters/early_acl_hold_ms))"
elif [ -d /sys/module/btusb ]; then
	echo "Fix: not loaded (stock btusb is running)"
else
	echo "Fix: btusb is not loaded"
fi
echo
if [ "$dropped" -gt 0 ] && [ ! -r /sys/module/btusb/parameters/early_acl_hold_ms ]; then
	echo "This machine drops ACL data that arrives before the connection is registered."
	echo "If a Bluetooth LE mouse/keyboard freezes ~30 s after connecting, install the fix: sudo ./install.sh --reload"
elif [ "$dropped" -gt 0 ]; then
	echo "The fix is loaded but packets were still dropped. Try a longer hold:"
	echo "  echo 100 | sudo tee /sys/module/btusb/parameters/early_acl_hold_ms"
elif [ "$held" -gt 0 ]; then
	echo "The fix is working: early packets were delivered instead of dropped."
else
	echo "No early packets seen yet. Connect the Bluetooth device and run this again."
fi
