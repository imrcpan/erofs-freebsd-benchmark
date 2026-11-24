#!/bin/sh
# Measurement loop shared by all boards.
#
# run_matrix <fs list> <workload name> <rdbench args>
#
# For every round, every variant is mounted fresh, the workload runs once on
# the cold mount and once more on the warm mount, then the variant is
# unmounted. Variants alternate inside a round so slow drift of the machine
# does not favour one of them. All results go to $OUT/raw.csv.

# parse_result <rdbench output line>: print "files,bytes,secs,errors".
parse_result() {
	echo "$1" | awk '{
		for (i = 1; i <= NF; i++) {
			split($i, a, "=")
			v[a[1]] = a[2]
		}
		printf "%s,%s,%s,%s\n", v["files"], v["bytes"], v["secs"], v["errors"]
	}'
}

# Run one workload on the mounted file system and append a row.
record() {
	board=$1 workload=$2 fs=$3 state=$4 run=$5
	shift 5
	line=$("$RDBENCH" -r "$DATA_ROOT" "$@") || log "warning: rdbench reported errors"
	res=$(parse_result "$line")
	echo "$board,$workload,$fs,$state,$run,$res" >>"$OUT/raw.csv"
	log "board $board $workload $fs $state run $run: $line"
}

run_matrix() {
	fslist=$1 workload=$2
	shift 2
	if [ "$("$RDBENCH" -n -m "$META/manifest.txt" -r /nonexistent "$@" 2>/dev/null | awk '{split($1, a, "="); print a[2]}')" = 0 ]; then
		case " $* " in
		*" -w "*) ;;
		*) log "board $BOARD_ID $workload: no files match, skipped"; return 0 ;;
		esac
	fi
	round=1
	while [ $round -le "$RUNS" ]; do
		for fs in $fslist; do
			if ! fs_present "$fs"; then
				[ $round -eq 1 ] && log "$fs: not present, skipped"
				continue
			fi
			fs_mount "$fs" || { log "$fs: mount failed"; continue; }
			record "$BOARD_ID" "$workload" "$fs" cold $round "$@"
			record "$BOARD_ID" "$workload" "$fs" warm $round "$@"
			fs_umount "$fs" || die "$fs: cannot unmount"
		done
		round=$((round + 1))
	done
}

# Check that every variant returns exactly the dataset: each file is read and
# compared with the hash in the manifest. Not timed.
verify_all() {
	bad=0
	for fs in $FS_ALL; do
		fs_present "$fs" || continue
		log "verifying $fs"
		fs_mount "$fs" || { log "$fs: mount failed"; bad=1; continue; }
		if ! "$RDBENCH" -v -r "$DATA_ROOT" -m "$META/manifest.txt" -b 1048576 >/dev/null; then
			log "$fs: CONTENT MISMATCH"
			bad=1
		fi
		fs_umount "$fs" || die "$fs: cannot unmount"
	done
	return $bad
}
