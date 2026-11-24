#!/bin/sh
# Install the erofs-freebsd release kernel on the FreeBSD target as
# /boot/kernel.erofs and make it the default kernel. The old kernel stays in
# /boot/kernel. The release holds boot/kernel/ with the kernel and erofs.ko
# built from the same tree.
#
# usage: install-kernel.sh <erofs_freebsd_kernel_amd64_*.tar.gz>
#        install-kernel.sh -r        go back to the previous default kernel
set -e

here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/common.sh"

[ "$(id -u)" -eq 0 ] || die "needs root"
if [ "$1" = -r ]; then
	sysrc -f /boot/loader.conf -x kernel
	log "default kernel restored, reboot to use it"
	exit 0
fi
[ $# -eq 1 ] && [ -f "$1" ] || die "usage: install-kernel.sh <kernel tar.gz> | -r"

tmp=$(mktemp -d /var/tmp/kernrel.XXXXXX)
tar -xzf "$1" -C "$tmp" boot/kernel || die "cannot unpack $1"
[ -f "$tmp/boot/kernel/kernel" ] || die "no kernel in $1"
# A debug kernel (WITNESS) makes the numbers meaningless; refuse it.
if strings -a "$tmp/boot/kernel/kernel" | grep -q "WITNESS option enabled"; then
	rm -rf "$tmp"
	die "$1 holds a debug kernel; use the erofs_freebsd_kernel_amd64_*.tar.gz release"
fi
rm -rf /boot/kernel.erofs
mv "$tmp/boot/kernel" /boot/kernel.erofs
rm -rf "$tmp"
kldxref /boot/kernel.erofs
sysrc -f /boot/loader.conf kernel=kernel.erofs
log "kernel.erofs installed, reboot to use it"
