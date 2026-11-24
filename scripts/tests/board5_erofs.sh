#!/bin/sh
# Board 5: erofs against itself, uncompressed against every compression
# algorithm. Same workloads as boards 1, 3 and 4, plus an image size table.
BOARD_ID=5
board_main() {
	run_matrix "$FS_EROFS" golden-walk \
	    -w -m "$META/manifest.txt" -b "$BS_LARGE"
	run_matrix "$FS_EROFS" large \
	    -m "$META/manifest.txt" -l "$LARGE_MIN" -o seq -b "$BS_LARGE"
	run_matrix "$FS_EROFS" small-rand \
	    -m "$META/manifest.txt" -u "$SMALL_MAX" -o shuffle \
	    -R "$SHUFFLE_SEED" -b "$BS_SMALL"

	# Image sizes come from the layout written on the host.
	total=$(awk -F'\t' '{s += $1} END {print s + 0}' "$META/manifest.txt")
	{
		echo ""
		echo "### board 5: erofs image sizes (dataset $total bytes)"
		echo ""
		echo "| variant | image bytes | ratio to dataset |"
		echo "|---|---|---|"
		awk -F'|' -v total="$total" '$1 ~ /^erofs-/ {
			printf "| %s | %d | %.3f |\n", $1, $5, $5 / total
		}' "$META/layout.txt"
	} >>"$OUT/extra.md"
}
