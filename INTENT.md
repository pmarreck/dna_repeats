# dna_repeats

## Purpose (Peter, 2026-09-23/24)

Find gap-constrained repeat families in A/C/G/T strings: for each fixed length
L, groups of exact, non-overlapping occurrences of one unit where consecutive
occurrences are at most D bases apart. Shorter families with more occurrences
are reported alongside longer ones.

The family rule is `chain_packing` (Peter, 2026-09-24): each start's lazy,
bounded-gap regex chain is accepted in start order, skipping any start that
lies inside an accepted member of the same unit. The other candidate rules and
the counterexamples that ruled them out are recorded in the pcre2 fork's
`docs/capture_history/OVERLAP_SEMANTICS.md`.

## Constraints

- The matcher is Peter's PCRE2 fork (`github.com/pmarreck/pcre2`, branch
  `capture-history`), used through its opt-in capture history. This project
  pins it by commit in `build.zig.zon`; no DNA-specific code belongs in PCRE2.
- Input normalization is strict: ASCII whitespace and `-` are removed, letters
  uppercased, and any other byte is an error, never silently dropped.
- FASTA input (first non-whitespace byte `>`) is searched per record; there,
  IUPAC ambiguity codes become N, which keeps its position but never matches
  (2026-09-26, following Peter's N question; wildcard matching belongs to the
  mismatch mode).
- The local corpus `$HOME/Documents/dna_sample.txt` is read-only and must not
  be published or committed. Derived copies stay private.
- Speed improvements are hypotheses until measured.

## How success is verified

- A simple quadratic enumeration oracle (`src/families.zig`) defines each rule.
- The PCRE2-backed finder must equal the `chain_packing` oracle exhaustively
  over small subjects (`src/finder.zig` tests).
- `./test` runs every Zig test through Nix against the pinned fork.

## Scope changes

Approximate matching and reverse-complement repeats became goals on 2026-09-26
(Peter), as part of [beating existing repeat finders](intents/beat_existing_tools.md).
Biological annotation remains out of scope unless Peter adds it.
