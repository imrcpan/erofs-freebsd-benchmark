#!/bin/sh
# One step on the Linux host: dataset, makefs and the disk image.
#
# usage: bench build-image [-p full|small] [-w work dir] [-s freebsd src tree]
#                          [-m makefs]
#   -p  dataset profile, full (default) or small (silesia and calgary only)
#   -w  work directory, default ./bench-work
#   -s  FreeBSD source tree used to bootstrap makefs; when omitted and no
#       makefs is given, erofs-freebsd is cloned into the work directory
#   -m  use this makefs binary instead of building one
#
# The disk image is written to <work dir>/out/bench.img.
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/common.sh"

profile=full
work=./bench-work
src=
makefs=
while getopts p:w:s:m:h o; do
	case $o in
	p) profile=$OPTARG ;;
	w) work=$OPTARG ;;
	s) src=$OPTARG ;;
	m) makefs=$OPTARG ;;
	h) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) exit 2 ;;
	esac
done
mkdir -p "$work"
work=$(cd "$work" && pwd)

"$here/host/fetch-dataset.sh" -p "$profile" "$work/dataset" "$work/cache"

if [ -z "$makefs" ]; then
	if [ -z "$src" ] && [ ! -x "$work/build/bin/makefs" ]; then
		need_cmd git
		src=$work/src
		[ -d "$src/.git" ] || git clone --depth 1 \
		    https://github.com/imrcpan/erofs-freebsd "$src"
	fi
	"$here/host/build-makefs.sh" "${src:-$work/src}" "$work/build"
	makefs=$work/build/bin/makefs
fi

"$here/host/build-images.sh" -m "$makefs" "$work/dataset" "$work/out"
log "disk image: $work/out/bench.img"
