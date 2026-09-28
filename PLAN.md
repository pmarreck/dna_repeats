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
	- [ ] ART 2b: pin the 8 genomes in nix/benchdata.nix and add an ART check to bench/verify.
	- [ ] ART 3: pin INPHARED (all GenBank phage genomes) and scan it; time and memory for the whole collection.
	- [ ] ART 4: link arrays to RTs: prodigal gene calls near arrays, HMMER with an RT profile built from MarsHill RT homologs as in the paper.
	- [ ] ART 5: census and repeat clustering (both strands) for repeats the same as or similar to ART repeats; add GPD and MGV; IMG/VR v4.1 when Peter has JGI access.
	- [ ] ART 6: findings report and README section.
- [x] Time split after the k-mer scan (E. coli 4.6 Mb, one thread, 138 ms): Zig prefilter 98 ms (71%), capture-history regex families ~38 ms (28%), arrays ~1 ms. The regex still finds every family. (2026-09-28 08:15 EDT)
- [x] Easy to use and to confirm (Peter, 2026-09-28): README with SVG charts (bench/charts from the log), nix run, usage, bench/verify (22 deterministic results vs bench/expected.tsv; a planted wrong value fails it). (done 2026-09-28 08:40 EDT)
- [ ] Auto thread count: default (all 128) is 15% slower than -j 48 on held-out #3 (589 vs 511 ms; knee near 32). Measure per phase (scan chunks vs per-length pool, which cannot use more threads than lengths) and cap accordingly.
- [ ] Release binaries for the 5 targets (gh release).
- [ ] Precision idea from PILER-CR: spacer length uniformity (min/max >= 0.75) and repeat conservation; validate on held-out #2.
- [x] Arrays report the majority consensus unit instead of one seed copy (Array.unit owned; unit_pos removed; writers no longer take the subject). Coordinates identical on dev + held-outs #1/#3; the unit changed on 28 of 169 arrays; exact match to CRISPRCasdb's DR consensus 123 -> 143 of 164 overlapping arrays (mean positional distance 1.79 -> 1.54). (done 2026-09-28 01:15 EDT)
- [x] DR accuracy on the scoreboard: adapters emit each tool's repeat unit; score.awk scores predictions overlapping a truth array with a DR by Levenshtein distance on the closer strand (DR line: scored, exact, edit); logged as dr_scored/dr_exact/dr_edit. (done 2026-09-28 01:35 EDT) Held-out #3 exact DR / mean edit: dna-repeats 60/72 83.3% / 0.51; MinCED 51/67 76.1% / 0.72; PILER-CR 52/71 73.2% / 0.45. Dev: PILER-CR 96.6% / 0.03, dna-repeats 87.5% / 0.13, MinCED 75.0% / 0.83. CRISPRCasdb's DR comes from CRISPRCasFinder, so this is agreement with its boundary convention.
- [x] Scoreboard: a tool failing on any genome prints its stderr and the genome, is counted (failures) and exits 1 (was: stderr discarded, crash scored as "found nothing"); rows log tool_path, input_sha256, dirty; only requested tools are built; MINCED_BIN/PILERCR_BIN/DNAREPEATS_BIN/SCOREBOARD_LOG overrides; tested with fake tools in tests/bench/run. (done 2026-09-27 23:35 EDT)
- [ ] Memory next: keep only seed runs per length, u32 positions; fix the two OOM-path leaks with a failing-allocator sweep.
- [ ] Review: overflow at max_gap + (max_len - lo); validate --max-gap/--max-len <= 65535; worker errors lose their type.
- [ ] Review: help text stale (FASTA, IUPAC, -j default, columns); explore ships in the package; differential_test.zig tests an old pattern; bench/gen-corpus is quadratic; full report in CODE_REVIEW.md.
- [x] Array caller tests: mutation sweep of 22 mutants (merge, budgets, every filter threshold, X-drop, consensus ties, re-extension, peel order): all killed (was 18 of 22 surviving). Merge, filter decision and X-drop extracted as pure functions (mergeFrom, accepted, XDrop) and tested as classifiers; dead `extendable` filter removed (reached 8 times on dev+held-outs, never true). Output identical to before on 136 runs (dev, held-out #1, #3; both presets). (done 2026-09-28 00:58 EDT)
- [ ] Review (tests): finder exhaustive tests ~2 min (munmap churn from the testing allocator): per-subject arena, run families.zig tests once as a module, drop Finder.families-only tests covered by the pruned differential; byte classifier tests should check each byte's class, not bucket totals; CLI stderr assertions and missing cases (-j, JSON across records, empty/N-only records, min-len > max-len).
- [ ] Step 4: reverse-complement strand.
- [ ] Step 5: bounded-mismatch copies with an independent oracle; then rerun the scoreboard. Treat N and partial IUPAC codes (R, Y, ...) as free mismatches there; exact mode keeps N never-matching (Peter asked, 2026-09-26).
- [ ] Pure-Zig family finder: measure against the capture-history regex now that the prefilter is Zig (regex families are 28% of one-thread time on E. coli).
- [x] Pure-Zig candidate scan (src/kmer_scan.zig; Peter, 2026-09-26): 2-bit rolling k-mer codes in a sliding window, vectorized search ahead; lengths <= 31 (regex beyond, and as the differential oracle: exhaustive {A,C,N} <= 7 bases, long ACGTN at lengths 8/18/31 and gaps 0-400; 4 mutants killed). The regex scan was 98% of single-thread time. Held-out #3 single-threaded 59.0 -> 4.65 s (12.7x; MinCED 15.9 s, PILER-CR 24.9 s); 64 threads 1.86 -> 0.34 s. Output byte-identical on 144 runs. (done 2026-09-28 01:55 EDT) Scoreboard at d78b492, one thread (dnarepeats_1t) vs opponents: held-out #3 4.13 s / 14.0 MB vs MinCED 14.74 s / 461.2 MB, PILER-CR 24.23 s / 24.0 MB; held-out #2 4.59 s vs 15.80 / 24.99 s; recall and precision unchanged everywhere. Held-out #2 exact DR: 92.9% vs 78.3% / 68.9%.
- [ ] Exploratory, measure + TDD: 2-bit base packing (32 bases per u64) for unit equality and popcount Hamming in seed extension.
- [ ] Exploratory, measure + TDD: SIMD (@Vector) window search for unit copies in extension and scan; compare against scalar and PCRE2 JIT.
- [x] Final report (Peter, 2026-09-26): published as a public artifact, https://claude.ai/artifact/YDA9CSb9S3wHVikR2ge4Te (held-out #3 five-axis small multiples, divergence curves, all sets, method, limits, reproduction). Keep it updated as results change. (done 2026-09-28 02:30 EDT)
- [ ] Best-in-class biotech CLI: standard outputs (GFF3, BED, FASTA of spacers) and packaging (static binaries; consider Bioconda).
- [ ] Show Peter the rendered progress bar (Unicode and --ascii) and encode the approved look as exact assertions.
- [ ] CLI follow-ups: JSON metadata (stats) on stderr; Windows /o-style aliases.
- [ ] Label families by maximality and Pareto (length vs count) dominance.
- [ ] Run the Windows (wine) and macOS binaries, not just build them; wire Mechatron Prime CI (mechatron-ci skill) once Peter wants CI here.
- [ ] Repin the fork when capture-history changes; the deps hash in flake.nix must be regenerated with it.
