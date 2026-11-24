#!/bin/sh
# Board 4: golden image. Walk the whole dataset (AOSP system, enwik8, silesia,
# calgary; see erofsstress-freebsd/genimage) in directory order and read every
# file. Directory lookups are part of the measurement.
BOARD_ID=4
board_main() {
	run_matrix "$FS_CROSS" golden-walk \
	    -w -m "$META/manifest.txt" -b "$BS_LARGE"
}
