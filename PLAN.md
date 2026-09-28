# PLAN

Completed items retire to docs/PLAN_LOG.md. Split out of the pcre2 fork on 2026-09-24 (history kept via git subtree split).

Decision (Peter, 2026-09-26): the CLI may import the Zig core directly here; no C FFI/C CLI layer is required for this project.
Decision (Peter, 2026-09-26): correctness is determined in Zig Debug mode (./test runs zig build test -Doptimize=Debug); benchmarks run ReleaseFast only.

## Now

- [x] Public-readiness audit: no private data in any tracked file or commit that is not already public; symlinks are relative; the pcre2 fork is public. (done 2026-09-28 08:30 EDT)
- [x] Repo public with MIT license, README credits and the tools-first framing (Peter approved wording). (done 2026-09-28 09:13 EDT)
- [ ] ART (Peter, 2026-09-28): run on the relevant genomes and try to exceed the Anthropic ART preprint. Feasibility: MarsHill (MW248466.1) array found upstream of the RT (5 copies, 14-nt core -> 35-nt consensus) but CRISPR filters reject it (conservation 0.897, spacer 10-mer sharing 0.33); scope questions pending with Peter.
	- [x] ART 1: --art preset from the paper's parameters (seeds 12, repeats 15..49, 100..450 nt spacing, conservation 0.8, spacer-sharing filter off), TDD. (done 2026-09-28 09:35 EDT, 714484a)
	- [x] ART 2: tuning 3/3; held-out once 4/5 (LPJP1 has no array we or the paper report; 4/4 where the paper reports one); results in intents/art_search.md. (done 2026-09-28 09:42 EDT)
	- [x] ART 2b: 8 ART genomes pinned (artGenomes); bench/art-check (strand-aware window, tested as a classifier); bench/verify checks all 8 (31 of 31 verified). (done 2026-09-28 10:05 EDT)
	- [ ] ART 3: pin INPHARED (all GenBank phage genomes) and scan it; time and memory for the whole collection.
	- [x] ART 4: bench/art-census (dna-repeats --art, prodigal on ±8 kb windows, Pfam RVT_1 hmmsearch, bench/art-link tested on fixtures). On the 8 known genomes: all 8 have an array upstream of an RT, including LPJP1's second RT (array 518 bp upstream, 4 copies, 35 nt), which the RT-first held-out check missed; under 1 s total. (done 2026-09-28 10:25 EDT)
	- [x] ART 5a: bench/art-cluster (repeat families on both strands, containment identity >= 0.8, labeled with bench/art_known.tsv); tested, 2 mutants killed. (done 2026-09-28 10:15 EDT)
	- [ ] ART 5b: census runs: INPHARED 14Apr2025 (0.64 GB gz), GPD (1.55 GB gz), MGV v1.0 (8.8 GB) downloading to ~/Documents/dna_repeats_output/art (private, not committed); shuffled-genome control; IMG/VR v4.1 when Peter has JGI access.
	- [ ] ART 6: findings report and README section.
- [x] Time split after the k-mer scan (E. coli 4.6 Mb, one thread, 138 ms): Zig prefilter 98 ms (71%), capture-history regex families ~38 ms (28%), arrays ~1 ms. The regex still finds every family. (2026-09-28 08:15 EDT)
- [x] Easy to use and to confirm (Peter, 2026-09-28): README with SVG charts (bench/charts from the log), nix run, usage, bench/verify (22 deterministic results vs bench/expected.tsv; a planted wrong value fails it). (done 2026-09-28 08:40 EDT)
- [ ] Auto thread count: default (all 128) is 15% slower than -j 48 on held-out #3 (589 vs 511 ms; knee near 32). Measure per phase (scan chunks vs per-length pool, which cannot use more threads than lengths) and cap accordingly.
- [ ] Release binaries for the 5 targets (gh release).
- [ ] Precision idea from PILER-CR: spacer length uniformity (min/max >= 0.75) and repeat conservation; validate on held-out #2.
- [ ] Memory next: keep only seed runs per length, u32 positions; fix the two OOM-path leaks with a failing-allocator sweep.
- [ ] Review: overflow at max_gap + (max_len - lo); validate --max-gap/--max-len <= 65535; worker errors lose their type.
- [ ] Review: help text stale (FASTA, IUPAC, -j default, columns); explore ships in the package; differential_test.zig tests an old pattern; bench/gen-corpus is quadratic; full report in CODE_REVIEW.md.
- [ ] Review (tests): finder exhaustive tests ~2 min (munmap churn from the testing allocator): per-subject arena, run families.zig tests once as a module, drop Finder.families-only tests covered by the pruned differential; byte classifier tests should check each byte's class, not bucket totals; CLI stderr assertions and missing cases (-j, JSON across records, empty/N-only records, min-len > max-len).
- [ ] Step 4: reverse-complement strand.
- [ ] Step 5: bounded-mismatch copies with an independent oracle; then rerun the scoreboard. Treat N and partial IUPAC codes (R, Y, ...) as free mismatches there; exact mode keeps N never-matching (Peter asked, 2026-09-26).
- [ ] Pure-Zig family finder: measure against the capture-history regex now that the prefilter is Zig (regex families are 28% of one-thread time on E. coli).
- [ ] Exploratory, measure + TDD: 2-bit base packing (32 bases per u64) for unit equality and popcount Hamming in seed extension.
- [ ] Exploratory, measure + TDD: SIMD (@Vector) window search for unit copies in extension and scan; compare against scalar and PCRE2 JIT.
- [x] Final report (Peter, 2026-09-26): published as a public artifact, https://claude.ai/artifact/YDA9CSb9S3wHVikR2ge4Te (held-out #3 five-axis small multiples, divergence curves, all sets, method, limits, reproduction). Keep it updated as results change. (done 2026-09-28 02:30 EDT)
- [ ] Best-in-class biotech CLI: standard outputs (GFF3, BED, FASTA of spacers) and packaging (static binaries; consider Bioconda).
- [ ] Show Peter the rendered progress bar (Unicode and --ascii) and encode the approved look as exact assertions.
- [ ] CLI follow-ups: JSON metadata (stats) on stderr; Windows /o-style aliases.
- [ ] Label families by maximality and Pareto (length vs count) dominance.
- [ ] Run the Windows (wine) and macOS binaries, not just build them; wire Mechatron Prime CI (mechatron-ci skill) once Peter wants CI here.
- [ ] Repin the fork when capture-history changes; the deps hash in flake.nix must be regenerated with it.
