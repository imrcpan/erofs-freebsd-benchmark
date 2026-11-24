#!/bin/sh
# Board 3: the same small files in a seeded random order. The order is the
# same for every file system and every run.
BOARD_ID=3
board_main() {
	run_matrix "$FS_CROSS" small-rand \
	    -m "$META/manifest.txt" -u "$SMALL_MAX" -o shuffle \
	    -R "$SHUFFLE_SEED" -b "$BS_SMALL"
}
