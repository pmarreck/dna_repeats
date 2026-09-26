# Score CRISPR array predictions against CRISPRCasdb truth (intents/beat_existing_tools.md).
# usage: awk -f bench/score.awk TRUTH.tsv PREDICTIONS.tsv
#   TRUTH: accession, organism, start (1-based), length, orientation, evidence level, DR
#   PREDICTIONS: accession, start, end (1-based, inclusive)
# Recall: a level-4 array is recalled when the union of predictions covers >= half its bases.
# Precision: a prediction is correct when >= half its bases lie inside any truth array
# (any evidence level, so finding a lower-evidence candidate is not penalized).
# Output: one line per truth accession (sorted), then TOTAL.
BEGIN { FS = OFS = "\t"; MIN_FRACTION = 0.5 }
FNR == NR {
	n = ++nt[$1]; ts[$1, n] = $3; te[$1, n] = $3 + $4 - 1; tel[$1, n] = $6
	accs[$1] = 1
	next
}
{
	n = ++np[$1]; ps[$1, n] = $2; pe[$1, n] = $3
}
function overlap(a1, a2, b1, b2) { return (a2 < b1 || b2 < a1) ? 0 : (a2 < b2 ? a2 : b2) - (a1 > b1 ? a1 : b1) + 1 }
END {
	for (acc in accs) order[++na] = acc
	# insertion sort keeps this portable across awks
	for (i = 2; i <= na; i++) { v = order[i]; for (j = i - 1; j > 0 && order[j] > v; j--) order[j + 1] = order[j]; order[j + 1] = v }
	for (k = 1; k <= na; k++) {
		acc = order[k]; el4 = 0; recalled = 0; correct = 0
		for (t = 1; t <= nt[acc]; t++) {
			if (tel[acc, t] != 4) continue
			el4++
			split("", covered)
			for (p = 1; p <= np[acc]; p++) {
				lo = ps[acc, p] > ts[acc, t] ? ps[acc, p] : ts[acc, t]
				hi = pe[acc, p] < te[acc, t] ? pe[acc, p] : te[acc, t]
				for (x = lo; x <= hi; x++) covered[x] = 1
			}
			c = 0; for (x in covered) c++
			if (c >= MIN_FRACTION * (te[acc, t] - ts[acc, t] + 1)) recalled++
		}
		for (p = 1; p <= np[acc]; p++) {
			inside = 0
			for (t = 1; t <= nt[acc]; t++) inside += overlap(ps[acc, p], pe[acc, p], ts[acc, t], te[acc, t])
			if (inside >= MIN_FRACTION * (pe[acc, p] - ps[acc, p] + 1)) correct++
		}
		print acc, "el4=" el4, "recalled=" recalled, "predictions=" (np[acc] + 0), "correct=" correct
		T_el4 += el4; T_rec += recalled; T_pred += np[acc]; T_cor += correct
	}
	print "TOTAL", "el4=" T_el4, "recalled=" T_rec, "predictions=" (T_pred + 0), "correct=" T_cor
}
