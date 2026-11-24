#!/bin/sh
# Download the golden image dataset on a Linux host. This follows the layout
# of erofsstress-freebsd/genimage but does not need sudo or a loop mount:
#   <dir>/aosp_system  files of the Android 11 GSI system.img
#   <dir>/enwik8       enwik8
#   <dir>/silesia      silesia corpus
#   <dir>/calgary      calgary corpus
#
# usage: fetch-dataset.sh [-p full|small] <dataset dir> <download cache dir>
#   full   all four sets
#   small  silesia and calgary only (for quick runs, no Android image)
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/common.sh"

profile=full
while getopts p: o; do
	case $o in
	p) profile=$OPTARG ;;
	*) die "usage: fetch-dataset.sh [-p full|small] <dataset dir> <cache dir>" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || die "usage: fetch-dataset.sh [-p full|small] <dataset dir> <cache dir>"
dataset=$1
cache=$2

need_cmd curl
need_cmd unzip
mkdir -p "$cache"

AOSP_URL=https://dl.google.com/developers/android/rvc/images/gsi/aosp_arm64-exp-RP1A.200720.009-6720564-019b517d.zip

# download <url> <file>: resumable, keeps the file in the cache.
download() {
	[ -s "$2" ] && return 0
	log "downloading $1"
	curl -fSL --progress-bar --retry 3 -C - -o "$2.part" "$1" || die "download failed: $1"
	mv "$2.part" "$2"
}

# unpack <zip> <destination>: extract into a fresh directory, then rename.
unpack() {
	[ -d "$2" ] && return 0
	rm -rf "$2.tmp"
	mkdir -p "$2.tmp"
	unzip -q "$1" -d "$2.tmp" || die "unzip failed: $1"
	mv "$2.tmp" "$2"
}

mkdir -p "$dataset"

download https://mattmahoney.net/dc/calgary.zip "$cache/calgary.zip"
unpack "$cache/calgary.zip" "$dataset/calgary"
download https://mattmahoney.net/dc/silesia.zip "$cache/silesia.zip"
unpack "$cache/silesia.zip" "$dataset/silesia"

if [ "$profile" = full ]; then
	download https://mattmahoney.net/dc/enwik8.zip "$cache/enwik8.zip"
	unpack "$cache/enwik8.zip" "$dataset/enwik8"

	if [ ! -d "$dataset/aosp_system" ]; then
		need_cmd debugfs
		download "$AOSP_URL" "$cache/gsi.zip"
		rm -rf "$cache/gsi" "$dataset/aosp_system.tmp"
		mkdir -p "$cache/gsi" "$dataset/aosp_system.tmp"
		unzip -q "$cache/gsi.zip" system.img -d "$cache/gsi" ||
		    die "system.img not found in the GSI zip"
		img=$cache/gsi/system.img
		# Sparse images start with the magic 3a ff 26 ed.
		if [ "$(head -c 4 "$img" | od -An -tx1 | tr -d ' ')" = 3aff26ed ]; then
			need_cmd simg2img
			simg2img "$img" "$img.raw"
			mv "$img.raw" "$img"
		fi
		# rdump copies the tree without mounting the image.
		debugfs -R "rdump / $dataset/aosp_system.tmp" "$img" ||
		    die "debugfs rdump failed"
		mv "$dataset/aosp_system.tmp" "$dataset/aosp_system"
		rm -rf "$cache/gsi"
	fi
fi

log "dataset ready in $dataset"
