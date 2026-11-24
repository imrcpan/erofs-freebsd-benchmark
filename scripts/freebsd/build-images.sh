#!/bin/sh
# Build one image with the system makefs. Runs on FreeBSD only (the CI uses a
# FreeBSD virtual machine for this, one job per variant).
#
# usage: build-images.sh -v ufs|zfs <dataset dir> <output file>
#
# The image parameters are the same as in host/build-images.sh, which builds
# the other variants on Linux; keep the two in sync.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/common.sh"

[ "$(uname -s)" = FreeBSD ] || die "this script only runs on FreeBSD"
usage="usage: build-images.sh -v ufs|zfs <dataset dir> <output file>"
variant=
while getopts v: o; do
	case $o in
	v) variant=$OPTARG ;;
	*) die "$usage" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] && [ -n "$variant" ] || die "$usage"
dataset=$(cd "$1" && pwd)
out=$2
need_cmd makefs

MIB=1048576
roundup_mib() { echo $((($1 + MIB - 1) / MIB * MIB)); }

rm -f "$out"
case $variant in
ufs)
	log "ufs: building $out"
	makefs -t ffs -o version=2,bsize=32768,fsize=4096,label=ufs \
	    -b 3% -f 5% "$out" "$dataset" || die "makefs ffs failed"
	;;
zfs)
	content=$(find "$dataset" -type f -exec stat -f %z {} + |
	    awk '{s += $1} END {print s + 0}')
	log "zfs: dataset $content bytes"
	# makefs zfs needs more room for block pointers and padding.
	zfs_size=$(roundup_mib $((content + content / 5 + 128 * MIB)))
	log "zfs: building $out"
	makefs -t zfs -s "$zfs_size" \
	    -o poolname="$BENCH_POOL",rootpath=/,ashift=12 \
	    "$out" "$dataset" || die "makefs zfs failed"
	;;
*)
	die "unknown variant: $variant"
	;;
esac
ls -l "$out"
