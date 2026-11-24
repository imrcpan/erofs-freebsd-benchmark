#!/bin/sh
# Common helpers shared by host (Linux) and target (FreeBSD) scripts.
# POSIX sh only, so that it runs unmodified on both systems.

# Filesystem variants. The first group is the uncompressed cross-filesystem
# comparison, the second group is the erofs-only compression comparison.
# Each name is also the GPT label of the partition holding its image.
FS_CROSS="erofs-none ufs zfs ext4"
FS_EROFS="erofs-none erofs-lz4 erofs-lz4hc erofs-lzma erofs-deflate erofs-zstd"
FS_ALL="erofs-none erofs-lz4 erofs-lz4hc erofs-lzma erofs-deflate erofs-zstd ufs zfs ext4"

log() {
	printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

die() {
	log "error: $*"
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# Directory containing the scripts, resolved from $0 of the entry point.
script_dir() {
	(cd "$(dirname "$1")" && pwd)
}

# Parameters shared by the host and the target.
BENCH_POOL=bench
LARGE_MIN=16777216	# files of at least 16 MiB are "large"
SMALL_MAX=65536		# files below 64 KiB are "small"
BS_LARGE=131072
BS_SMALL=131072
SHUFFLE_SEED=20240601

# Print the tool used to hash and list files, built from tools/rdbench.c.
build_rdbench() {
	# $1 = output path, $2 = scripts dir
	cc -O2 -o "$1" "$2/tools/rdbench.c" || die "cannot build rdbench"
}
