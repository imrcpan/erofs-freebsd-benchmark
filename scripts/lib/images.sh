#!/bin/sh
# Get the benchmark images and write them to partitions. FreeBSD only.
#
#   images_fetch   <dir>           download the parts of the latest release
#   images_extract <dir>           unpack the parts into <dir>
#   images_write   <dir>           dd the images into the partitions from -p
#   images_manifest                list the dataset from the erofs partition
#
# The release holds benchmark.erofs, benchmark.ext4, benchmark.ufs and
# benchmark.zfs. Each image is written straight into the partition the user
# gave for its variant (-p <variant>=<device>); the benchmark then mounts the
# partitions read-only.

IMAGES_REPO=imrcpan/erofs-freebsd-benchmark
IMAGES_PART=benchmark-images.tar.gz
# image file name : variant
IMAGES_MAP="benchmark.erofs:erofs-none benchmark.ufs:ufs benchmark.zfs:zfs benchmark.ext4:ext4"

images_have_parts() {
	ls "$1"/$IMAGES_PART.[0-9]* >/dev/null 2>&1
}

images_have_images() {
	for m in $IMAGES_MAP; do
		[ -s "$1/${m%%:*}" ] || return 1
	done
}

# Download benchmark-images.tar.gz.01, .02, ... of the latest release into
# <dir>. Nothing is downloaded when the parts or the unpacked images are there.
images_fetch() {
	dir=$1
	mkdir -p "$dir"
	if images_have_images "$dir"; then
		log "images already unpacked in $dir, skipping the download"
		return 0
	fi
	if images_have_parts "$dir"; then
		log "release parts already in $dir, skipping the download"
		return 0
	fi
	need_cmd fetch
	api=https://api.github.com/repos/$IMAGES_REPO/releases/latest
	log "querying $api"
	json=$(fetch -q -o - "$api") || die "cannot query the latest release"
	urls=$(echo "$json" | tr ',' '\n' |
	    sed -n 's|.*"browser_download_url": *"\([^"]*/'"$IMAGES_PART"'\.[0-9][0-9]*\)".*|\1|p' |
	    sort)
	[ -n "$urls" ] || die "the latest release of $IMAGES_REPO has no $IMAGES_PART.* assets"
	for url in $urls; do
		name=${url##*/}
		log "downloading $name"
		# A part only gets its final name when it is complete.
		rm -f "$dir/$name.part"
		fetch -q -o "$dir/$name.part" "$url" || die "download failed: $url"
		mv "$dir/$name.part" "$dir/$name"
	done
}

# Unpack the parts into <dir>, via a temporary directory so that a failed
# unpack never leaves a half written image behind.
images_extract() {
	dir=$1
	if images_have_images "$dir"; then
		log "images already unpacked in $dir"
		return 0
	fi
	images_have_parts "$dir" || die "no $IMAGES_PART.* in $dir"
	tmp=$dir/.unpack
	rm -rf "$tmp"
	mkdir -p "$tmp"
	log "unpacking the release parts"
	cat "$dir"/$IMAGES_PART.[0-9]* | tar -xzf - -C "$tmp" ||
	    die "unpacking failed (are all parts present?)"
	for m in $IMAGES_MAP; do
		[ -s "$tmp/${m%%:*}" ] || die "the release has no ${m%%:*}"
		mv "$tmp/${m%%:*}" "$dir/${m%%:*}"
	done
	rm -rf "$tmp"
}

# image_file <variant> prints the path of the unpacked image of the variant.
image_file() {
	for m in $IMAGES_MAP; do
		[ "${m##*:}" = "$1" ] && { echo "$IMAGES_DIR/${m%%:*}"; return 0; }
	done
	return 1
}

# The partitions are given by the user, one per variant: PARTS holds words
# "<variant>=<device>", for example "erofs-none=/dev/ada1p4 ufs=/dev/ada1p5".
# part_dev <variant> prints the device, or nothing.
part_dev() {
	for w in $PARTS; do
		[ "${w%%=*}" = "$1" ] && { echo "${w#*=}"; return 0; }
	done
	return 0
}

# Check the partitions given with -p before anything is written: the variants
# are known, each device exists, is not in use and is big enough for its image.
images_check_parts() {
	dir=$1
	[ -n "$PARTS" ] || die "no partitions given; use -p <variant>=<device>, see bench run -h"
	for w in $PARTS; do
		v=${w%%=*}
		dev=${w#*=}
		case " $IMAGES_MAP " in
		*:$v\ *|*:$v) ;;
		*) die "unknown variant in -p: $v (use erofs-none, ufs, zfs, ext4)" ;;
		esac
		[ -c "$dev" ] || die "$dev is not a disk device"
		mount | awk '{print $1}' | grep -q -x "$dev" && die "$dev is mounted"
		zpool status -P 2>/dev/null | grep -q -w -F "$dev" && die "$dev belongs to a ZFS pool"
		for m in $IMAGES_MAP; do
			[ "${m##*:}" = "$v" ] || continue
			bytes=$(stat -f %z "$dir/${m%%:*}")
			have=$(diskinfo "$dev" | awk '{print $3}')
			[ "$have" -ge "$bytes" ] ||
			    die "$dev is $have bytes, the $v image is $bytes bytes"
		done
	done
	# The same device twice would overwrite one image with another.
	dups=$(for w in $PARTS; do echo "${w#*=}"; done | sort | uniq -d)
	[ -z "$dups" ] || die "the same device is used twice: $dups"
	[ -n "$(part_dev erofs-none)" ] ||
	    die "erofs-none is required, its dataset listing is the reference for the other variants"
}

# Write each image straight into its partition. The contents of the partitions
# are destroyed.
images_write() {
	dir=$1
	images_check_parts "$dir"
	mib=1048576
	for m in $IMAGES_MAP; do
		file=$dir/${m%%:*}
		v=${m##*:}
		dev=$(part_dev "$v")
		[ -n "$dev" ] || { log "$v: no partition given, skipped"; continue; }
		bytes=$(stat -f %z "$file")
		log "$v: writing $bytes bytes to $dev, its contents are destroyed"
		dd if="$file" of="$dev" bs=1m 2>/dev/null || die "dd failed for $v"
		# Old ZFS labels near the end of a larger partition would confuse an
		# import, so clear the last 2 MiB when that does not touch the image.
		psize=$(diskinfo "$dev" | awk '{print $3}')
		if [ $((psize - bytes)) -ge $((2 * mib)) ] && [ $((psize % mib)) -eq 0 ]; then
			dd if=/dev/zero of="$dev" bs=1m seek=$((psize / mib - 2)) count=2 2>/dev/null ||
			    die "cannot clear the end of $dev"
		fi
	done
	sync
}

# Write the manifest (size, hash, path of every file) read from the erofs
# image. The other file systems are checked against it afterwards, so a file
# system that returns different data than erofs is caught.
images_manifest() {
	fs_mount erofs-none || die "cannot mount erofs-none to list the dataset"
	"$RDBENCH" -G "$DATA_ROOT" >"$META/manifest.txt" ||
	    { fs_umount erofs-none; die "listing the dataset failed"; }
	fs_umount erofs-none || die "cannot unmount erofs-none"
	n=$(wc -l <"$META/manifest.txt" | tr -d ' ')
	[ "$n" -gt 0 ] || die "the dataset is empty"
	log "dataset: $n files"
}
