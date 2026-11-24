#!/bin/sh
# Download the kernel asset of the latest erofs-freebsd release on a Linux
# host. The asset is matched by the pattern erofs_freebsd_kernel_amd64_*.tar.gz;
# its name suffix (a commit id) is never assumed.
#
# usage: fetch-kernel.sh <output dir>
# result: <output dir>/<asset name>, the path is printed on stdout
set -e

here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/common.sh"

[ $# -eq 1 ] || die "usage: fetch-kernel.sh <output dir>"
need_cmd curl
need_cmd python3
mkdir -p "$1"

api=https://api.github.com/repos/imrcpan/erofs-freebsd-releases/releases/latest
url=$(curl -fsSL "$api" | python3 -c '
import fnmatch, json, sys
for a in json.load(sys.stdin).get("assets", []):
    if fnmatch.fnmatch(a["name"], "erofs_freebsd_kernel_amd64_*.tar.gz"):
        print(a["browser_download_url"])
        break
') || die "cannot query the latest release"
[ -n "$url" ] || die "no kernel asset in the latest release"

file=$1/$(basename "$url")
if [ ! -s "$file" ]; then
	log "downloading $url"
	curl -fSL --retry 3 -o "$file.part" "$url" || die "download failed"
	mv "$file.part" "$file"
fi
log "kernel release: $file"
echo "$file"
