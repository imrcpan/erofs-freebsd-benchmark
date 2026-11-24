#!/bin/sh
# dangerous-install-kernel.sh - replace the kernel of this FreeBSD machine with
# the kernel of an erofs-freebsd release.
#
# usage: dangerous-install-kernel.sh -f /path/to/kernel.tar.gz
#
# The tarball comes from https://github.com/imrcpan/erofs-freebsd-releases
# (latest release, erofs_freebsd_kernel_amd64_*.tar.gz). It must hold
# boot/kernel/ with the kernel and all of its modules.
#
# What it does, on the running machine and without asking:
#   1. checks the tarball and unpacks it next to /boot (same file system)
#   2. runs kldxref on the new kernel directory
#   3. moves /boot/kernel to /boot/kernel.old (a previous kernel.old is removed)
#   4. moves the new directory to /boot/kernel
# It does not reboot. The old kernel stays bootable as kernel.old.
#
# This only runs on FreeBSD and needs root.
set -eu

prog=dangerous-install-kernel.sh

err() {
	echo "$prog: error: $*" >&2
	exit 1
}

info() {
	echo "$prog: $*" >&2
}

usage() {
	echo "usage: $prog -f /path/to/kernel.tar.gz" >&2
	exit 2
}

[ "$(uname -s)" = FreeBSD ] ||
    err "this script only runs on FreeBSD, this system is $(uname -s)"

file=
while getopts f: opt; do
	case $opt in
	f) file=$OPTARG ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] && [ -n "$file" ] || usage

[ "$(id -u)" -eq 0 ] || err "must run as root"
[ -f "$file" ] && [ -r "$file" ] || err "no such file: $file"
[ -d /boot/kernel ] || err "/boot/kernel does not exist, refusing to continue"

# Look at the member list before unpacking anything.
list=$(mktemp /var/tmp/kernel-list.XXXXXX) || err "mktemp failed"
stage=
cleanup() {
	rm -f "$list"
	if [ -n "$stage" ] && [ -d "$stage" ]; then
		chflags -R noschg "$stage" 2>/dev/null || true
		rm -rf "$stage"
	fi
}
trap cleanup EXIT INT TERM HUP

tar -tzf "$file" >"$list" 2>/dev/null || err "not a readable tar.gz: $file"
if grep -q -E '^/|(^|/)\.\.(/|$)' "$list"; then
	err "tarball has absolute or parent-relative paths: $file"
fi
grep -q -x -E 'boot/kernel/kernel' "$list" ||
    err "tarball has no boot/kernel/kernel: $file"

# Unpack on the file system of /boot, so that the final step is a rename.
stage=$(mktemp -d /boot/kernel.new.XXXXXX) || err "cannot create a directory in /boot"
info "unpacking $file"
tar -xzf "$file" -C "$stage" boot/kernel || err "unpacking failed"
new=$stage/boot/kernel
[ -f "$new/kernel" ] || err "unpacked tree has no kernel"

# The kernel must be an ELF file of a sensible size.
magic=$(head -c 4 "$new/kernel" | od -An -tx1 | tr -d ' \n')
[ "$magic" = 7f454c46 ] || err "boot/kernel/kernel is not an ELF file"
size=$(stat -f %z "$new/kernel")
[ "$size" -gt 1048576 ] || err "boot/kernel/kernel is too small ($size bytes)"

kldxref "$new" || err "kldxref failed on the new kernel"

info "new kernel:"
tar -xzOf "$file" build-info.txt 2>/dev/null | sed 's/^/    /' >&2 || true

# Warn about things that make the new kernel not boot or not match.
if grep -s -E '^[[:space:]]*kernel[[:space:]]*=' /boot/loader.conf \
    /boot/loader.conf.local >/dev/null; then
	info "warning: loader.conf selects a kernel by name; the loader will not boot /boot/kernel by default"
fi
if [ -n "$(ls -A /boot/modules 2>/dev/null)" ]; then
	info "warning: /boot/modules holds modules built for the old kernel"
fi

# Swap. If the second move fails, put the old kernel back.
if [ -e /boot/kernel.old ]; then
	chflags -R noschg /boot/kernel.old 2>/dev/null || true
	rm -rf /boot/kernel.old || err "cannot remove /boot/kernel.old"
fi
mv /boot/kernel /boot/kernel.old || err "cannot move /boot/kernel away"
if ! mv "$new" /boot/kernel; then
	mv /boot/kernel.old /boot/kernel
	err "cannot move the new kernel into place; the old kernel is restored"
fi

info "installed: /boot/kernel is the new kernel, /boot/kernel.old is the previous one"
info "reboot to use it; to boot the old kernel once: nextboot -k kernel.old"
