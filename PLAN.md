# PLAN

Completed items retire to docs/PLAN_LOG.md. Split out of the pcre2 fork on 2026-09-24 (history kept via git subtree split).

Decision (Peter, 2026-09-26): the CLI may import the Zig core directly here; no C FFI/C CLI layer is required for this project.
Decision (Peter, 2026-09-26): correctness is determined in Zig Debug mode (./test runs zig build test -Doptimize=Debug); benchmarks run ReleaseFast only.

## Now

- [ ] ART (Peter, 2026-09-28): run on the relevant genomes and try to exceed the Anthropic ART preprint. Feasibility: MarsHill (MW248466.1) array found upstream of the RT (5 copies, 14-nt core -> 35-nt consensus) but CRISPR filters reject it (conservation 0.897, spacer 10-mer sharing 0.33); scope questions pending with Peter.
	- [ ] ART 3: pin INPHARED (all GenBank phage genomes) and scan it; time and memory for the whole collection.
	- [ ] ART 5b: census runs: MGV done; INPHARED done (done 2026-09-28 12:00 EDT); shuffled MGV control done (0f17fa9); GPD done (no ART-like array); IMG/VR v4.1 when Peter has JGI access.
	- [x] ART 5f: ECF-sigma lead (families 3, 4): orientation and distance of the sigma gene to the array, host range, whether the repeats carry ECF promoter motifs (-35 AAC, -10 CGT). (done 2026-09-29 00:00 EDT: array sits upstream of the sigma gene in 265/283 and 247/258; crAss-like phages only)
	- [x] ART 5g: do family 3 spacers (crAss orphan CRISPR arrays) match other MGV genomes (exact 25-mers, both strands), i.e. do they target competing phages? (moot 2026-09-29 00:10 EDT: only 1 of 283 family-3 regions holds a CRISPR array; the label came from the representative alone)
	- [ ] ART 5h: art-screen labels per member, not per representative (fraction of members matching Rfam, tRNA, CRISPR), test first; rerun the MGV screen and fix the counts in intents/art_search.md.
	- [ ] Long-period repeat census (Peter, 2026-09-28): units of 50..500 nt, copies up to several kb apart, across the same phage collections; cluster families and screen out known element classes (coding repeats, rRNA, insertion sequences) before calling anything novel. After the ART census.
	- [ ] ART 6: findings report and README section.
- [ ] Auto thread count: default (all 128) is 15% slower than -j 48 on held-out #3 (589 vs 511 ms; knee near 32). Measure per phase (scan chunks vs per-length pool, which cannot use more threads than lengths) and cap accordingly.
- [ ] Release binaries for the 5 targets (gh release).
- [ ] Precision idea from PILER-CR: spacer length uniformity (min/max >= 0.75) and repeat conservation; validate on held-out #2.
- [ ] Memory next: keep only seed runs per length, u32 positions; fix the two OOM-path leaks with a failing-allocator sweep.
- [ ] Review: overflow at max_gap + (max_len - lo); validate --max-gap/--max-len <= 65535; worker errors lose their type.
- [ ] Review: help text stale (FASTA, IUPAC, -j default, columns); explore ships in the package; differential_test.zig tests an old pattern; bench/gen-corpus is quadratic; full report in CODE_REVIEW.md.
- [ ] Review (tests): finder exhaustive tests ~2 min (munmap churn from the testing allocator): per-subject arena, run families.zig tests once as a module, drop Finder.families-only tests covered by the pruned differential; byte classifier tests should check each byte's class, not bucket totals; CLI stderr assertions and missing cases (-j, JSON across records, empty/N-only records, min-len > max-len).
- [ ] Step 4: reverse-complement strand.
- [ ] Step 5: bounded-mismatch copies with an independent oracle; then rerun the scoreboard. Treat N and partial IUPAC codes (R, Y, ...) as free mismatches there; exact mode keeps N never-matching (Peter asked, 2026-09-26).
- [ ] Step 5 idea (Peter, 2026-09-28): packed 2-bit sub-words as exact pigeonhole seeds for mismatch copies (m mismatches in a k-mer leave an exact piece of k/(m+1) bases); a lone 4-base byte filter would pass ~30% of random windows, too weak alone.
- [ ] Pure-Zig family finder: measure against the capture-history regex now that the prefilter is Zig (regex families are 28% of one-thread time on E. coli).
- [ ] Exploratory, measure + TDD: 2-bit base packing (32 bases per u64) for unit equality and popcount Hamming in seed extension.
- [ ] Exploratory, measure + TDD: SIMD (@Vector) window search for unit copies in extension and scan; compare against scalar and PCRE2 JIT.
- [ ] Best-in-class biotech CLI: standard outputs (GFF3, BED, FASTA of spacers) and packaging (static binaries; consider Bioconda).
- [ ] Show Peter the rendered progress bar (Unicode and --ascii) and encode the approved look as exact assertions.
- [ ] CLI follow-ups: JSON metadata (stats) on stderr; Windows /o-style aliases.
- [ ] Label families by maximality and Pareto (length vs count) dominance.
- [ ] Run the Windows (wine) and macOS binaries, not just build them; wire Mechatron Prime CI (mechatron-ci skill) once Peter wants CI here.
- [ ] Repin the fork when capture-history changes; the deps hash in flake.nix must be regenerated with it.

## Code review 2026-09-28 (Grok, at cc8e504; findings double-checked)
- [x] CR1b: update the published findings report artifact like the README (both precision readings; it still says fewer false ones). (done 2026-09-28 23:45 EDT, artifact version 2)
- [x] CR7: finder worker errors keep their cause (OutOfMemory, Compile, MatchFailed) instead of always MatchFailed; negative pcre2_match codes named. (done 2026-09-28 17:22 EDT)
- [x] CR8: kmer_scan hot loop is O(n * gap) on misses; sliding window multiset for expected O(n), scaling-ratio gate, then remeasure the prefilter share. (done 2026-09-28 23:40 EDT: O(n) hash window built and measured, slower at the CRISPR gap; kept the vectorized scan, documented why, kept its new reference test)
- [x] CR9: (explore no longer installed, 9db1715) make the differential test exercise the production Finder pattern (CAPTURE_HISTORY, DOTALL gap, JIT) or say what it pins. (done 2026-09-28 19:05 EDT)
- [x] CR10: split the "identical spacers are not an array" test so each of its three filters has its own failing case; add inclusive-edge spacer bound tests (min_spacer, max_spacer). (done 2026-09-28 18:40 EDT, f348b1b; found and fixed the min_spacer contract bug)
- [ ] CR10b: on a quiet machine, log held-out #3 scoreboard rows for the f348b1b caller and regenerate docs/img charts; rerun the ART censuses (MGV, INPHARED, GPD) with it and update intents/art_search.md counts.
- [x] CR8b: profile --art on one thread (1.2 s on E. coli vs 0.14 s for --crispr) to find where its time goes before optimizing anything. (done 2026-09-29 00:00 EDT: E. coli one thread user 1.19 s; --max-len 12 0.29 s, 24 0.58 s: the per-length family step dominates, not the prefilter)
- [ ] CR8c: per-length candidate narrowing for wide length ranges (--art 12..49): a start with no L-mer copy in range has no (L+1)-mer copy, so each length probes only the previous length's hits; differential-test against the current path, then measure.
- [x] CR12: divergence opponent rows (e69d2e8) predate plant-arrays and lack input_sha256; rerun MinCED and PILER-CR on the pinned generator and add them to bench/verify. (done 2026-09-28 23:50 EDT: MinCED and PILER-CR rows reproduced from the pinned generator; verify now 47 checks)
- [x] CR13: advisories (OOM leaks fixed in 9db1715): negative named-group lookup cast (finder.zig:51); JIT NOMEMORY ignored (finder.zig:45); normalize FASTA byte classifier per byte, not bucket totals. (done 2026-09-28 18:53 EDT)
- [ ] CR14 (backlog): u32 positions with a >4 GiB record guard; keep only needed family headers in callArrays (main.zig:207).
