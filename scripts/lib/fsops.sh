#!/bin/sh
# Mount and unmount the file system variants on FreeBSD. The images are read
# straight from the partitions the user gave (part_dev). Every mount is
# read-only and nothing is written to the partitions.
#
# After fs_mount, DATA_ROOT is the directory holding the dataset.

MNT=${MNT:-/mnt/bench}

fs_mount() {
	fs=$1
	mkdir -p "$MNT"
	case $fs in
	erofs-*)
		mount -t erofs -o ro "$(part_dev "$fs")" "$MNT" || return 1
		DATA_ROOT=$MNT
		;;
	ufs)
		mount -t ufs -o ro "$(part_dev "$fs")" "$MNT" || return 1
		DATA_ROOT=$MNT
		;;
	ext4)
		mount -t ext2fs -o ro "$(part_dev "$fs")" "$MNT" || return 1
		DATA_ROOT=$MNT
		;;
	zfs)
		zpool import -o readonly=on -o cachefile=none -d "$(part_dev "$fs")" \
		    -R "$MNT" "$BENCH_POOL" || return 1
		DATA_ROOT=$(zfs get -H -o value mountpoint "$BENCH_POOL")
		;;
	*)
		return 1
		;;
	esac
}

# Unmounting (or exporting the pool) drops the cached data of the file system,
# so the next mount starts cold.
fs_umount() {
	fs=$1
	tries=0
	while [ $tries -lt 10 ]; do
		case $fs in
		zfs) zpool export -f "$BENCH_POOL" 2>/dev/null && return 0 ;;
		*) umount "$MNT" 2>/dev/null && return 0 ;;
		esac
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

# True if a partition was given for the variant and, when --mount selected
# targets, the variant is one of them.
fs_present() {
	[ -n "$(part_dev "$1")" ] || return 1
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
