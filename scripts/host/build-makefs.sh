#!/bin/sh
# Build the FreeBSD makefs tool on a Linux host, using the bootstrap build of
# a FreeBSD source tree. makefs creates the UFS and ZFS images.
#
# usage: build-makefs.sh <freebsd src tree> <build dir>
# result: <build dir>/bin/makefs
#
# Host requirements: clang, clang-cpp (unversioned name), lld, python3, bc, time.
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/common.sh"

[ $# -eq 2 ] || die "usage: build-makefs.sh <freebsd src tree> <build dir>"
src=$(cd "$1" && pwd)
build=$2
mkdir -p "$build/bin" "$build/obj"
build=$(cd "$build" && pwd)

if [ -x "$build/bin/makefs" ]; then
	log "makefs already built: $build/bin/makefs"
	exit 0
fi

[ -f "$src/tools/build/make.py" ] || die "not a FreeBSD source tree: $src"
for c in clang clang-cpp ld.lld python3 bc time; do
	command -v "$c" >/dev/null 2>&1 ||
	    die "missing host command: $c (clang-cpp may need: ln -s /usr/bin/clang-cpp-<ver> /usr/bin/clang-cpp)"
done

# The stages must run in this order: _worldtmp creates the directory tree
# that _legacy and _bootstrap-tools install into.
for stage in _worldtmp _legacy _bootstrap-tools; do
	log "makefs bootstrap stage $stage"
	(cd "$src" && MAKEOBJDIRPREFIX="$build/obj" ./tools/build/make.py \
	    --cross-bindir=/usr/bin TARGET=amd64 TARGET_ARCH=amd64 \
	    WITH_DISK_IMAGE_TOOLS_BOOTSTRAP=yes "$stage") \
	    >"$build/bootstrap$stage.log" 2>&1 ||
	    die "stage $stage failed, see $build/bootstrap$stage.log"
done

made=$(find "$build/obj" -path '*/legacy/bin/makefs' -type f | head -n 1)
[ -n "$made" ] || die "makefs was not produced"
cp "$made" "$build/bin/makefs"
log "built $build/bin/makefs"
