# Score CRISPR array predictions against CRISPRCasdb truth (intents/beat_existing_tools.md).
# usage: awk -f bench/score.awk TRUTH.tsv PREDICTIONS.tsv
#   TRUTH: accession, organism, start (1-based), length, orientation, evidence level, DR
#   PREDICTIONS: accession, start, end (1-based, inclusive)[, repeat unit]
# Recall: a level-4 array is recalled when the union of predictions covers >= half its bases.
# Precision: a prediction is correct when >= half its bases lie inside the union of truth arrays
# (any evidence level, so finding a lower-evidence candidate is not penalized).
# Repeat accuracy: a prediction with a unit overlapping a truth array with a DR scores its
# Levenshtein distance to that DR on the closer strand.
# Output: one line per truth accession (sorted), then DR (scored, exact, summed edit), then TOTAL.
BEGIN { FS = OFS = "\t"; MIN_FRACTION = 0.5 }
FILENAME == ARGV[1] { # not FNR == NR: an empty truth file would make predictions read as truth
	n = ++nt[$1]; ts[$1, n] = $3; te[$1, n] = $3 + $4 - 1; tel[$1, n] = $6; tdr[$1, n] = toupper($7)
	accs[$1] = 1
	next
}
{
	n = ++np[$1]; ps[$1, n] = $2; pe[$1, n] = $3; pu[$1, n] = toupper($4)
	accs[$1] = 1 # a prediction on a sequence without truth still counts (as wrong)
}
function overlap(a1, a2, b1, b2) { return (a2 < b1 || b2 < a1) ? 0 : (a2 < b2 ? a2 : b2) - (a1 > b1 ? a1 : b1) + 1 }
# Reverse complement of an A/C/G/T string (anything else maps to N).
function revcomp(s,   i, o, c) {
	o = ""
	for (i = length(s); i >= 1; i--) { c = substr(s, i, 1); o = o (c == "A" ? "T" : c == "C" ? "G" : c == "G" ? "C" : c == "T" ? "A" : "N") }
	return o
}
# Levenshtein distance, two-row dynamic programming. complexity: O(len(a) * len(b)).
function lev(a, b,   i, j, la, lb, prev, cur, cost, v) {
	la = length(a); lb = length(b)
	for (j = 0; j <= lb; j++) prev[j] = j
	for (i = 1; i <= la; i++) {
		cur[0] = i
		for (j = 1; j <= lb; j++) {
			cost = substr(a, i, 1) != substr(b, j, 1)
			v = prev[j - 1] + cost
			if (prev[j] + 1 < v) v = prev[j] + 1
			if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1
			cur[j] = v
		}
		for (j = 0; j <= lb; j++) prev[j] = cur[j]
	}
	return prev[lb]
}
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
			split("", covered) # union of truth bases inside the prediction, each counted once
			for (t = 1; t <= nt[acc]; t++) {
				lo = ps[acc, p] > ts[acc, t] ? ps[acc, p] : ts[acc, t]
				hi = pe[acc, p] < te[acc, t] ? pe[acc, p] : te[acc, t]
				for (x = lo; x <= hi; x++) covered[x] = 1
			}
			inside = 0; for (x in covered) inside++
			if (inside >= MIN_FRACTION * (pe[acc, p] - ps[acc, p] + 1)) correct++
			# Repeat accuracy against the first overlapping truth array that has a DR.
			if (pu[acc, p] != "") for (t = 1; t <= nt[acc]; t++) {
				if (tdr[acc, t] == "" || !overlap(ps[acc, p], pe[acc, p], ts[acc, t], te[acc, t])) continue
				d = lev(pu[acc, p], tdr[acc, t]); d2 = lev(revcomp(pu[acc, p]), tdr[acc, t])
				if (d2 < d) d = d2
				T_dr++; T_dr_exact += d == 0; T_dr_edit += d
				break
			}
		}
		print acc, "el4=" el4, "recalled=" recalled, "predictions=" (np[acc] + 0), "correct=" correct
		T_el4 += el4; T_rec += recalled; T_pred += np[acc]; T_cor += correct
	}
	print "DR", "scored=" (T_dr + 0), "exact=" (T_dr_exact + 0), "edit=" (T_dr_edit + 0)
	print "TOTAL", "el4=" (T_el4 + 0), "recalled=" (T_rec + 0), "predictions=" (T_pred + 0), "correct=" (T_cor + 0)
}
