#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Builds btusb.ko with the early-ACL-hold patch for one kernel.
# Usage: build.sh <kernelver> [kernel_build_dir]
# DKMS runs it from its build directory (MAKE[0] in dkms.conf); output: ./btusb.ko
#
# 1. Downloads drivers/bluetooth/btusb.c and its local headers for the kernel's
#    upstream tag (kernel.org, GitHub mirror as fallback).
# 2. Builds that source unmodified and compares it with the distro's own btusb
#    module, so a distro-patched or mismatched source is never installed.
# 3. Applies the first patch in patches/ that fits the source exactly and builds
#    the module (the btusb code changed between kernel versions).
#
# Optional settings in /etc/btusb-early-acl.conf:
#   SOURCE_TAG=v7.2.11   force the upstream tag to download
#   SKIP_VERIFY=1        build even if the source does not match the distro module
set -euo pipefail

KVER=${1:?usage: build.sh <kernelver> [kernel_build_dir]}
KDIR=${2:-/lib/modules/$KVER/build}
HERE=$(pwd)
CONF=/etc/btusb-early-acl.conf
SOURCE_TAG=""
SKIP_VERIFY=0
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

log() { echo "btusb-early-acl: $*"; }
die() { echo "btusb-early-acl: ERROR: $*" >&2; exit 1; }

upstream_tag() {
	local v=$1
	# Fedora release candidates look like 7.3.0-0.rc2.<...>.fc45
	if [[ $v =~ ^([0-9]+)\.([0-9]+)\.0-0\.rc([0-9]+) ]]; then
		echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}-rc${BASH_REMATCH[3]}"
	elif [[ $v =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
		if [ "${BASH_REMATCH[4]:-0}" = 0 ]; then
			echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
		else
			echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[4]}"
		fi
	else
		return 1
	fi
}

fetch() { # fetch <path in kernel tree> <destination>
	curl -fsSL --retry 3 --connect-timeout 20 -o "$2" \
		"https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/$1?h=$TAG" ||
	curl -fsSL --retry 3 --connect-timeout 20 -o "$2" \
		"https://raw.githubusercontent.com/gregkh/linux/$TAG/$1" ||
	die "could not download $1 for $TAG"
}

build_in() { # build_in <dir>
	echo 'obj-m := btusb.o' > "$1/Kbuild"
	# shellcheck disable=SC2086
	if ! make -C "$KDIR" M="$1" $LLVM_FLAG modules > "$1/build.log" 2>&1; then
		cat "$1/build.log" >&2
		die "build failed in $1"
	fi
}

# Fingerprints used to compare two builds of btusb.ko
code_hash() { objdump -d --no-show-raw-insn "$1" | sed 1,3d | sha256sum; }
ids_hash() { { modinfo -F alias "$1" | sort; modinfo -F parm "$1" | sort; } | sha256sum; }

for tool in curl make objdump modinfo patch sha256sum; do
	command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

[ -d "$KDIR" ] || die "kernel headers for $KVER not found at $KDIR"
if grep -qs 'drivers/bluetooth/btusb.ko' "/lib/modules/$KVER/modules.builtin"; then
	die "btusb is built into kernel $KVER; an external module cannot replace it"
fi
TAG=${SOURCE_TAG:-$(upstream_tag "$KVER")} || die "cannot map kernel $KVER to an upstream tag; set SOURCE_TAG in $CONF"
LLVM_FLAG=""
grep -qs '^CONFIG_CC_IS_CLANG=y' "$KDIR/.config" && LLVM_FLAG="LLVM=1"

rm -rf src stock patched btusb.ko stock-installed.ko
mkdir -p src stock patched

log "kernel $KVER, upstream source $TAG"
if ! (fetch drivers/bluetooth/btusb.c src/btusb.c) 2> /dev/null; then
	(fetch drivers/bluetooth/btusb_main.c src/btusb_main.c) 2> /dev/null &&
		die "btusb is split into several files in $TAG (Linux 7.4+); this version of the fix does not support it yet"
	die "could not download drivers/bluetooth/btusb.c for $TAG"
fi
sed -n 's/^#include "\([^"/]*\.h\)"$/\1/p' src/btusb.c > src/headers.list
while read -r header; do
	fetch "drivers/bluetooth/$header" "src/$header"
done < src/headers.list
rm src/headers.list
cp src/* stock/
cp src/* patched/

# Compare the unmodified upstream source with the distro's module. Once installed,
# DKMS moves that module to its original_module archive.
STOCK=$(find "/lib/modules/$KVER/kernel/drivers/bluetooth" \
	"/var/lib/dkms/btusb-early-acl/original_module/$KVER" \
	-name 'btusb.ko*' ! -name '*.origin' -print -quit 2>/dev/null || true)
if [ -z "$STOCK" ]; then
	[ "$SKIP_VERIFY" = 1 ] || die "stock btusb module for $KVER not found; cannot verify the source (SKIP_VERIFY=1 in $CONF to override)"
	log "WARNING: no stock btusb module to compare with; continuing because SKIP_VERIFY=1"
else
	case $STOCK in
	*.xz) xz -dc ;;
	*.zst) zstd -dcq ;;
	*.gz) gzip -dc ;;
	*) cat ;;
	esac < "$STOCK" > stock-installed.ko
	build_in "$HERE/stock"
	if [ "$(code_hash stock-installed.ko)" = "$(code_hash stock/btusb.ko)" ]; then
		log "verified: unmodified $TAG source builds code identical to $STOCK"
	elif [ "$(ids_hash stock-installed.ko)" = "$(ids_hash stock/btusb.ko)" ]; then
		log "WARNING: same device IDs and parameters as $STOCK, but the generated code differs (different compiler, or distro changes); continuing"
	elif [ "$SKIP_VERIFY" = 1 ]; then
		log "WARNING: $TAG source does not match $STOCK; continuing because SKIP_VERIFY=1"
	else
		die "upstream $TAG btusb.c does not match the btusb module of kernel $KVER (distro patches?). Nothing was built; the stock driver stays in use. To override, set SKIP_VERIFY=1 or SOURCE_TAG=... in $CONF"
	fi
fi

# DKMS refuses to replace an in-tree module that has the same version string.
sed -i 's/^#define VERSION "\([^"]*\)"$/#define VERSION "\1.1-earlyacl"/' patched/btusb.c
PATCH=""
for candidate in "$HERE"/patches/*.patch; do
	if patch -d patched -p3 -F0 -s -f --dry-run < "$candidate" > /dev/null 2>&1; then
		PATCH=$candidate
		break
	fi
done
[ -n "$PATCH" ] || die "no patch in patches/ applies to $TAG btusb.c; look for an updated version of this fix"
patch -d patched -p3 -F0 -s --no-backup-if-mismatch < "$PATCH"
log "applied $(basename "$PATCH")"
build_in "$HERE/patched"
modinfo -F parm patched/btusb.ko | grep -q '^early_acl_hold_ms:' || die "patched module lacks early_acl_hold_ms"
cp patched/btusb.ko "$HERE/btusb.ko"
log "built $HERE/btusb.ko (version $(modinfo -F version btusb.ko))"
