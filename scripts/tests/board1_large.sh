#!/bin/sh
# Board 1: sequential read of large files (>= LARGE_MIN), uncompressed
# variants of all file systems.
BOARD_ID=1
board_main() {
	run_matrix "$FS_CROSS" large \
	    -m "$META/manifest.txt" -l "$LARGE_MIN" -o seq -b "$BS_LARGE"
}
