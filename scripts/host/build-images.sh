#!/bin/sh
# Build one raw disk image that holds every file system variant, each in its
# own GPT partition labelled with the variant name. The image is later written
# to the disk of the FreeBSD machine (dd) and read through /dev/gpt/<label>.
# Nothing is ever copied into the partitions on the FreeBSD side.
#
# usage: build-images.sh [-m makefs] [-v "variants"] [-n] <dataset dir> <output dir>
#   -v  build only these variants (default: all)
#   -n  build the file system images only, no disk image
# output: <output dir>/img/<variant>.img  one image per variant
#         <output dir>/bench.img          the whole disk (not with -n)
#         <output dir>/meta/layout.txt    label|type|partition bytes|image bytes
#         <output dir>/meta/manifest.txt  size, hash and path of every file
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/common.sh"

makefs=${MAKEFS:-}
variants=$FS_ALL
nodisk=0
usage="usage: build-images.sh [-m makefs] [-v variants] [-n] <dataset dir> <output dir>"
while getopts m:v:n o; do
	case $o in
	m) makefs=$OPTARG ;;
	v) variants=$OPTARG ;;
	n) nodisk=1 ;;
	*) die "$usage" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || die "$usage"
for v in $variants; do
	case " $FS_ALL " in
	*" $v "*) ;;
	*) die "unknown variant: $v" ;;
	esac
done
dataset=$(cd "$1" && pwd)
out=$2
mkdir -p "$out/img" "$out/meta"
out=$(cd "$out" && pwd)

[ -n "$makefs" ] && [ -x "$makefs" ] || die "makefs not found, use -m or build it with build-makefs.sh"
for c in mkfs.erofs mkfs.ext4 truncate dd tar du; do need_cmd "$c"; done
[ "$nodisk" -eq 1 ] || need_cmd sgdisk

MIB=1048576
META_MIB=16
# Extra settings for the erofs variants. Compression levels are the defaults
# of mkfs.erofs unless noted; keep them here so that they are documented.
erofs_opts() {
	case $1 in
	erofs-none)    echo "" ;;
	erofs-lz4)     echo "-zlz4" ;;
	erofs-lz4hc)   echo "-zlz4hc,level=9" ;;
	erofs-lzma)    echo "-zlzma,level=6" ;;
	erofs-deflate) echo "-zdeflate,level=1" ;;
	erofs-zstd)    echo "-zzstd,level=3" ;;
	esac
}

filebytes() { stat -c %s "$1"; }
roundup_mib() { echo $((($1 + MIB - 1) / MIB * MIB)); }

rdbench=$out/rdbench
build_rdbench "$rdbench" "$here"

log "creating manifest"
"$rdbench" -G "$dataset" >"$out/meta/manifest.txt" || die "manifest failed"
content=$(awk -F'\t' '{s += $1} END {print s + 0}' "$out/meta/manifest.txt")
nfiles=$(wc -l <"$out/meta/manifest.txt")
log "dataset: $nfiles files, $content bytes"

# Image sizes for formats that need a size up front: 6% plus 64 MiB headroom.
fixed=$(roundup_mib $((content + content / 16 + 64 * MIB)))
# makefs zfs needs more room for block pointers and padding.
zfs_size=$(roundup_mib $((content + content / 5 + 128 * MIB)))

for fs in $variants; do
	img=$out/img/$fs.img
	[ -s "$img" ] && { log "$fs: image exists, reusing"; continue; }
	log "$fs: building image"
	rm -f "$img"
	case $fs in
	erofs-*)
		# shellcheck disable=SC2046
		mkfs.erofs -T0 --quiet $(erofs_opts "$fs") "$img" "$dataset" ||
		    die "mkfs.erofs failed for $fs"
		;;
	ufs)
		"$makefs" -t ffs -o version=2,bsize=32768,fsize=4096,label=ufs \
		    -b 3% -f 5% "$img" "$dataset" || die "makefs ffs failed"
		;;
	zfs)
		"$makefs" -t zfs -s "$zfs_size" \
		    -o poolname="$BENCH_POOL",rootpath=/,ashift=12 \
		    "$img" "$dataset" || die "makefs zfs failed"
		;;
	ext4)
		# FreeBSD ext2fs reads ext4 extents but not 64bit or metadata_csum.
		truncate -s "$fixed" "$img"
		mkfs.ext4 -F -q -t ext4 -b 4096 -m 0 \
		    -O ^has_journal,^64bit,^metadata_csum,^orphan_file \
		    -E root_owner=0:0 -d "$dataset" "$img" ||
		    die "mkfs.ext4 failed"
		;;
	esac
done

if [ "$nodisk" -eq 1 ]; then
	log "done: images in $out/img"
	exit 0
fi

# Partition layout: meta first, then every variant, 1 MiB aligned. A ZFS image
# must fill its partition exactly, because ZFS keeps labels at the end of the
# device; the ZFS image size is already a multiple of 1 MiB.
layout=$out/meta/layout.txt
: >"$layout"
start=$MIB
meta_bytes=$((META_MIB * MIB))
start=$((start + meta_bytes))
for fs in $FS_ALL; do
	isz=$(filebytes "$out/img/$fs.img")
	psz=$(roundup_mib "$isz")
	[ "$fs" = zfs ] && [ "$psz" -ne "$isz" ] && die "zfs image is not 1 MiB aligned"
	printf '%s|%s|%s|%s|%s\n' "$fs" "${fs%%-*}" "$start" "$psz" "$isz" >>"$layout"
	start=$((start + psz))
done
disk_bytes=$((start + MIB))

disk=$out/bench.img
log "creating disk image $disk ($disk_bytes bytes)"
rm -f "$disk"
truncate -s "$disk_bytes" "$disk"
sgdisk -Z "$disk" >/dev/null 2>&1 || true
sgdisk -n "1:2048:+$((META_MIB * 1024))K" -c 1:meta -t 1:8300 "$disk" >/dev/null ||
    die "sgdisk failed"
idx=2
while IFS='|' read -r fs type pstart psz isz; do
	sgdisk -n "$idx:$((pstart / 512)):+$((psz / 1024))K" -c "$idx:$fs" \
	    -t "$idx:8300" "$disk" >/dev/null || die "sgdisk failed for $fs"
	log "$fs: writing partition $idx"
	dd if="$out/img/$fs.img" of="$disk" bs=$MIB seek=$((pstart / MIB)) \
	    conv=notrunc,sparse status=none || die "dd failed for $fs"
	idx=$((idx + 1))
done <"$layout"

# The meta partition holds a tar with the layout and the manifest.
meta_tar=$out/meta.tar
tar -C "$out/meta" -cf "$meta_tar" layout.txt manifest.txt
[ "$(filebytes "$meta_tar")" -le "$meta_bytes" ] || die "meta data does not fit the meta partition"
dd if="$meta_tar" of="$disk" bs=$MIB seek=1 conv=notrunc status=none

sgdisk -p "$disk"
log "done: $disk"
