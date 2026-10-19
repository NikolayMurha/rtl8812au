#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_RELEASE="${1:-$(uname -r)}"
OUTPUT_DIR="${2:-$ROOT_DIR/dist}"
BUILD_JOBS="${BUILD_JOBS:-3}"
MODULE_NAME="88XXau_wfb"
MODULE_PATH="$ROOT_DIR/$MODULE_NAME.ko"
KERNEL_BUILD_DIR="/lib/modules/$KERNEL_RELEASE/build"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This package must be built on Linux for the target kernel." >&2
  exit 1
fi

for command in make dpkg-deb modinfo; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is missing: $command" >&2
    exit 1
  fi
done

if [[ ! -f "$KERNEL_BUILD_DIR/Makefile" ]]; then
  echo "Kernel headers are missing: $KERNEL_BUILD_DIR/Makefile" >&2
  exit 1
fi

if [[ ! "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "BUILD_JOBS must be a positive integer." >&2
  exit 1
fi

DRIVER_VERSION="$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"/\1/p' "$ROOT_DIR/dkms.conf")"
if [[ -z "$DRIVER_VERSION" ]]; then
  echo "Unable to read PACKAGE_VERSION from dkms.conf." >&2
  exit 1
fi

DEB_ARCH="$(dpkg --print-architecture)"
KERNEL_ID="$(printf '%s' "$KERNEL_RELEASE" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9.+-]/-/g')"
PACKAGE_NAME="lf-wfb-rtl8812au-kmod-$KERNEL_ID"
PACKAGE_FILE="${PACKAGE_NAME}_${DRIVER_VERSION}_${DEB_ARCH}.deb"

echo "Building $MODULE_NAME for $KERNEL_RELEASE with $BUILD_JOBS jobs"
make -C "$ROOT_DIR" -j"$BUILD_JOBS" KVER="$KERNEL_RELEASE" KSRC="$KERNEL_BUILD_DIR"

if [[ ! -f "$MODULE_PATH" ]]; then
  echo "Kernel module was not produced: $MODULE_PATH" >&2
  exit 1
fi

MODULE_VERMAGIC="$(modinfo -F vermagic "$MODULE_PATH")"
if [[ "$MODULE_VERMAGIC" != "$KERNEL_RELEASE "* && "$MODULE_VERMAGIC" != "$KERNEL_RELEASE" ]]; then
  echo "Module vermagic does not match $KERNEL_RELEASE: $MODULE_VERMAGIC" >&2
  exit 1
fi

PACKAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$PACKAGE_ROOT"' EXIT

install -D -m 0644 \
  "$MODULE_PATH" \
  "$PACKAGE_ROOT/lib/modules/$KERNEL_RELEASE/updates/dkms/$MODULE_NAME.ko"
install -d -m 0755 "$PACKAGE_ROOT/DEBIAN"

cat >"$PACKAGE_ROOT/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $DRIVER_VERSION
Section: kernel
Priority: optional
Architecture: $DEB_ARCH
Maintainer: LegitForce <support@legitforce.com>
Depends: kmod
Description: WFB-NG RTL8812AU module for Linux $KERNEL_RELEASE
 Prebuilt 88XXau_wfb kernel module for the exact target kernel.
EOF

cat >"$PACKAGE_ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
depmod -a "$KERNEL_RELEASE"
EOF

cat >"$PACKAGE_ROOT/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
if [ -d "/lib/modules/$KERNEL_RELEASE" ]; then
  depmod -a "$KERNEL_RELEASE"
fi
EOF

chmod 0755 "$PACKAGE_ROOT/DEBIAN/postinst" "$PACKAGE_ROOT/DEBIAN/postrm"
mkdir -p "$OUTPUT_DIR"
dpkg-deb --root-owner-group --build "$PACKAGE_ROOT" "$OUTPUT_DIR/$PACKAGE_FILE"

echo "$OUTPUT_DIR/$PACKAGE_FILE"
