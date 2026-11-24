#!/bin/sh
# Board 2: small files (< SMALL_MAX) read one after another in manifest
# (sorted path) order, uncompressed variants of all file systems.
BOARD_ID=2
board_main() {
	run_matrix "$FS_CROSS" small-seq \
	    -m "$META/manifest.txt" -u "$SMALL_MAX" -o seq -b "$BS_SMALL"
}
