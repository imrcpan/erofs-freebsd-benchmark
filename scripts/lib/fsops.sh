#!/bin/sh
# Mount and unmount the file system variants on FreeBSD. The images are read
# from the partitions the user gave or from the image files. Every mount is
# read-only and nothing is written to the partitions.
#
# After fs_mount, DATA_ROOT is the directory holding the dataset.

MNT=${MNT:-/mnt/bench}
# IMAGE_MODE=file: the unpacked image files are attached with mdconfig and
# mounted read-only (bench run --mount). IMAGE_MODE=part: the images were
# written into the partitions given with -p.
IMAGE_MODE=${IMAGE_MODE:-part}
MD_UNIT=
DEV=

# fs_attach <variant>: set DEV to the device that holds the variant.
fs_attach() {
	DEV=
	MD_UNIT=
	if [ "$IMAGE_MODE" = file ]; then
		f=$(image_file "$1") || return 1
		MD_UNIT=$(mdconfig -a -t vnode -o readonly -f "$f") || return 1
		DEV=/dev/$MD_UNIT
	else
		DEV=$(part_dev "$1")
	fi
	[ -n "$DEV" ]
}

fs_detach() {
	[ -n "$MD_UNIT" ] || return 0
	mdconfig -d -u "${MD_UNIT#md}" || return 1
	MD_UNIT=
}

# fs_mount <variant>: mount read-only, set DATA_ROOT to the dataset directory
# and report where it is mounted.
fs_mount() {
	fs=$1
	mkdir -p "$MNT"
	fs_attach "$fs" || return 1
	case $fs in
	erofs-*) mount -t erofs -o ro "$DEV" "$MNT" || { fs_detach; return 1; } ;;
	ufs) mount -t ufs -o ro "$DEV" "$MNT" || { fs_detach; return 1; } ;;
	ext4) mount -t ext2fs -o ro "$DEV" "$MNT" || { fs_detach; return 1; } ;;
	zfs)
		zpool import -o readonly=on -o cachefile=none -d "$DEV" \
		    -R "$MNT" "$BENCH_POOL" || { fs_detach; return 1; }
		;;
	*) fs_detach; return 1 ;;
	esac
	if [ "$fs" = zfs ]; then
		DATA_ROOT=$(zfs get -H -o value mountpoint "$BENCH_POOL")
	else
		DATA_ROOT=$MNT
	fi
	log "$fs: $DEV mounted at $DATA_ROOT"
}

# Unmounting (or exporting the pool) drops the cached data of the file system,
# so the next mount starts cold.
fs_umount() {
	fs=$1
	tries=0
	while [ $tries -lt 10 ]; do
		case $fs in
		zfs) zpool export -f "$BENCH_POOL" 2>/dev/null && { fs_detach; return; } ;;
		*) umount "$MNT" 2>/dev/null && { fs_detach; return; } ;;
		esac
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

# Undo a half finished run: called on exit and on signals.
fs_cleanup() {
	zpool list -H -o name 2>/dev/null | grep -q -x "$BENCH_POOL" &&
	    zpool export -f "$BENCH_POOL" 2>/dev/null
	mount | grep -q " on $MNT " && umount -f "$MNT" 2>/dev/null
	fs_detach 2>/dev/null
	return 0
}

# True if the variant has an image to use: a file (--mount) or a partition
# (-p), and, when --mount selected targets, the variant is one of them.
fs_present() {
	if [ "$IMAGE_MODE" = file ]; then
		f=$(image_file "$1") && [ -s "$f" ] || return 1
	else
		[ -n "$(part_dev "$1")" ] || return 1
	fi
	[ -z "${MEASURE:-}" ] && return 0
	case " $MEASURE " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

# Print a description of the kernel and tunables.
fs_describe() {
	# Diagnostics only; a missing sysctl must not abort the run.
	uname -a || true
	freebsd-version -ku 2>/dev/null || true
	sysctl -n hw.model hw.ncpu hw.physmem 2>/dev/null || true
	sysctl vfs.read_max vfs.zfs.arc.max vfs.zfs.prefetch.disable 2>/dev/null || true
	kldstat -v 2>/dev/null | grep -i -E "erofs|zfs|ext2fs" | head -n 5 || true
}
