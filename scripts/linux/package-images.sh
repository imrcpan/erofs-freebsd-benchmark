#!/bin/sh
# Pack the uncompressed erofs, ext4, ufs and zfs images into split archives.
#
# usage: scripts/linux/package-images.sh <image dir> <output dir>
#   <image dir>   holds erofs-none.img, ext4.img, ufs.img, zfs.img
#                 (the img directory written by build-images.sh)
# output: <output dir>/benchmark-images.tar.gz.01, .02, ...
#         Each part is at most 1000000000 bytes. The archive holds
#         benchmark.erofs, benchmark.ext4, benchmark.ufs and benchmark.zfs.
#
# Unpack with: cat benchmark-images.tar.gz.* | tar -xzf -
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/common.sh"

PART_BYTES=1000000000

[ $# -eq 2 ] || die "usage: package-images.sh <image dir> <output dir>"
imgdir=$(cd "$1" && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)

# The name inside the archive for each source image.
pairs="erofs-none:erofs ext4:ext4 ufs:ufs zfs:zfs"
stage=$(mktemp -d "$out/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM HUP

names=
for p in $pairs; do
	src=$imgdir/${p%%:*}.img
	name=benchmark.${p##*:}
	[ -s "$src" ] || die "missing image: $src"
	ln -s "$src" "$stage/$name"
	names="$names $name"
done

rm -f "$out"/benchmark-images.tar.gz.*
log "packing$names"
# -h follows the links; --sparse keeps the holes of the images cheap to read.
# shellcheck disable=SC2086
tar -C "$stage" -h --sparse -cf - $names | gzip -6 -c |
    split -b "$PART_BYTES" -d -a 2 --numeric-suffixes=1 - "$out/benchmark-images.tar.gz."

parts=$(ls "$out"/benchmark-images.tar.gz.* 2>/dev/null)
[ -n "$parts" ] || die "no archive produced"
for f in $parts; do
	size=$(stat -c %s "$f")
	[ "$size" -le "$PART_BYTES" ] || die "$f is larger than $PART_BYTES bytes"
	log "$(basename "$f") $size bytes"
done

# Check that the parts form a valid archive with the expected members.
got=$(cat $parts | tar -tzf - | sort | tr '\n' ' ')
want=$(for n in $names; do echo "$n"; done | sort | tr '\n' ' ')
[ "$got" = "$want" ] || die "archive members differ: got '$got', want '$want'"
log "done: $out"
