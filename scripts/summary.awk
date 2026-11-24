# Summarise raw.csv into markdown tables.
# input columns: board,workload,fs,state,run,files,bytes,secs,errors
# usage: awk -F, -f summary.awk raw.csv
function isort(arr, n,    i, j, t) {
	for (i = 2; i <= n; i++) {
		t = arr[i]
		for (j = i - 1; j >= 1 && arr[j] > t; j--)
			arr[j + 1] = arr[j]
		arr[j + 1] = t
	}
}
NR > 1 {
	grp = $1 "," $2
	if (!(grp in gseen)) { gseen[grp] = 1; gorder[++ng] = grp }
	fs = $3
	if (!((grp, fs) in fseen)) { fseen[grp, fs] = 1; forder[grp, ++nf[grp]] = fs }
	k = grp "," fs "," $4
	n[k]++
	mibs = ($8 > 0) ? $7 / $8 / 1048576 : 0
	val[k, n[k]] = mibs
	files[grp] = $6
	bytes[grp] = $7
	if ($9 != 0) err[k] = 1
}
END {
	for (g = 1; g <= ng; g++) {
		grp = gorder[g]
		split(grp, p, ",")
		printf "\n### board %s: %s (%d files, %.1f MiB)\n\n", p[1], p[2], files[grp], bytes[grp] / 1048576
		print "| fs | cold MiB/s median (min-max) | warm MiB/s median (min-max) | runs |"
		print "|---|---|---|---|"
		for (i = 1; i <= nf[grp]; i++) {
			fs = forder[grp, i]
			row = "| " fs " |"
			for (s = 1; s <= 2; s++) {
				st = (s == 1) ? "cold" : "warm"
				k = grp "," fs "," st
				cnt = n[k]
				for (j = 1; j <= cnt; j++) tmp[j] = val[k, j]
				isort(tmp, cnt)
				med = (cnt % 2) ? tmp[(cnt + 1) / 2] : (tmp[cnt / 2] + tmp[cnt / 2 + 1]) / 2
				row = row sprintf(" %.1f (%.1f-%.1f)%s |", med, tmp[1], tmp[cnt], err[k] ? " ERR" : "")
			}
			print row " " n[grp "," fs ",cold"] " |"
		}
	}
}
