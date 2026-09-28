# Direction: beat existing repeat finders

Status: accepted (Peter, 2026-09-26: "I want to beat all of them", with the
choices below answered the same day).

## Outcome (Peter, 2026-09-26)

1. Reach a Pareto-optimal point on a multidimensional chart against existing
   tools: undominated on raw speed, precision, recall (legitimate findings), and
   ability to find more divergent copies, even if not best on every dimension
   (best on all would be ideal). Each tool is judged on its own task using public
   genomes and published annotation.
2. Deliver reproducible measurements and a final report of findings: results
   against existing tooling, victories, and anything new or interesting.
3. Deliver a best-in-class, user-friendly CLI for the biotech community.

Scoreboard dimensions (Peter's: speed, precision, recall, divergent-copy tolerance;
he asked for field-appropriate additions, 2026-09-26, marked "added"):
- Peak memory (Peter, 2026-09-26: be well-behaved).
- Boundary accuracy (added): predicted array start/end and copy count vs truth.
- Repeat consensus accuracy (added): predicted DR vs the annotated consensus.
- Spacer extraction (added): spacers are what downstream users analyze (phage matching).
- Negative controls (added): false arrays on shuffled genomes and CRISPR-free genomes.
- Divergence robustness (added): recall as planted arrays are mutated at rising rates.
- Fragmented input (added): contigs and metagenome assemblies, where arrays are cut off.
- Scale (added): throughput on metagenome-sized inputs (gigabases).
- Orientation (added, later): which strand the array is transcribed from.

## Soft goals (Peter, 2026-09-26)

- Bring positive attention to AI, and to Claude specifically, as a powerful tool in
  this space.
- Bring positive attention to Peter as an AI-collaborating human. He tends to avoid
  the spotlight, so when results are genuinely new and interesting, push him to post
  them. Claims must be backed by the scoreboard; overstating would defeat both goals.

## Decisions (Peter, 2026-09-26)

- Scoreboard: both speed and accuracy, judged per opponent on that opponent's task.
- Scope: approximate matching (mismatches) and reverse-complement repeats are now
  in scope; INTENT.md's non-goals were revised accordingly.
- First opponent: CRISPR array finders (MinCED, PILER-CR, CRT), the closest match
  to the gap-bounded model. Later: Tandem Repeats Finder, then exact-repeat
  tools (Vmatch, MUMmer repeat-match) on speed.
- Ground truth for CRISPR arrays: CRISPRCasdb (highest evidence level). It was built
  with CRISPRCasFinder, so the scoreboard also reports pairwise tool agreement to
  expose that bias.

## Constraints

- Benchmarks use public genomes and public annotations only. Peter's private sample
  never enters the scoreboard or the repo.
- Every claimed win is reproducible from one command, with tool versions,
  inputs (by accession and checksum), machine and commit recorded.
- PCRE2 has no fuzzy matching, so mismatch tolerance needs its own technique
  (for example exact seeds from the regex, then bounded-mismatch extension).
  It must stay checkable against an independent oracle, as chain_packing is.

## Held-out validation (rule fixed 2026-09-26 15:05 EDT, before any held-out result was seen)

Filters and thresholds are tuned only on the 8 development genomes in nix/benchdata.nix.
Claims are scored on a held-out set: every CRISPRCasdb sequence with at least one
evidence-level-4 array, excluding the development accessions, ordered by the SHA-256
of its accession string, first 30. The set is pinned in nix/benchdata.nix like the
development genomes. Changing a filter after seeing held-out results means picking
a fresh held-out set by the same rule (next 30), and saying so in the report.

Held-out #1 was used on 2026-09-26 to diagnose the welded-arrays bug, so it is now
development data. Held-out #2 (positions 31-60; 30 genomes, 70 evidence-level-4 arrays)
was pinned in nix/benchdata.nix before any result on it was seen.
Held-out #2 was scored once (code frozen at 4226a2f); the seeding then changed (shorter
seeds, consensus re-extension), which was tuned on dev, held-out #1 and synthetic
divergence sets only. Held-out #3 (positions 61-90; 30 genomes, 73 evidence-level-4
arrays) was pinned on 2026-09-26 23:20 EDT, before any result on it was seen, and is
scored once with the code frozen at the commit that pins it.

## Open questions

- How an array counts as found. Provisional (agent proposal, 2026-09-26, in
  bench/score.awk): recall = level-4 arrays whose bases are >= 50% covered by the
  union of predictions; precision = predictions with >= 50% of their bases inside
  any CRISPRCasdb array, any level.
- How many mismatches per copy the approximate mode allows by default.
