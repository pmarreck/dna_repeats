# Direction: beat existing repeat finders

Status: accepted (Peter, 2026-09-26: "I want to beat all of them", with the
choices below answered the same day).

## Outcome

For each established tool, run its own task on public genomes. dna_repeats
wins against a tool when it is faster than that tool at equal or better recall
against a published annotation, with precision reported alongside.

## Decisions (Peter, 2026-09-26)

- Scoreboard: both speed and accuracy, judged per opponent on that opponent's task.
- Scope: approximate matching (mismatches) and reverse-complement repeats are now
  in scope; INTENT.md's non-goals were revised accordingly.
- First opponent: CRISPR array finders (MinCED, PILER-CR, CRT), the closest match
  to the gap-bounded model. Later: Tandem Repeats Finder, then exact-repeat
  tools (Vmatch, MUMmer repeat-match) on speed.

## Constraints

- Benchmarks use public genomes and public annotations only. The private sample
  ($HOME/Documents/dna_sample.txt) never enters the scoreboard or the repo.
- Every claimed win is reproducible from one command, with tool versions,
  inputs (by accession and checksum), machine and commit recorded.
- PCRE2 has no fuzzy matching, so mismatch tolerance needs its own technique
  (for example exact seeds from the regex, then bounded-mismatch extension).
  It must stay checkable against an independent oracle, as chain_packing is.

## Open questions

- Which annotation is ground truth for CRISPR arrays (CRISPRCasdb or another
  curated set), and how an array counts as found (repeat consensus match,
  position overlap threshold).
- How many mismatches per copy the approximate mode allows by default.
