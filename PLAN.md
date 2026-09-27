# PLAN

Completed items retire to docs/PLAN_LOG.md. Split out of the pcre2 fork on 2026-09-24 (history kept via git subtree split).

Decision (Peter, 2026-09-26): the CLI may import the Zig core directly here; no C FFI/C CLI layer is required for this project.
Decision (Peter, 2026-09-26): correctness is determined in Zig Debug mode (./test runs zig build test -Doptimize=Debug); benchmarks run ReleaseFast only.

## Now

- [x] -o is now safe: output resolving to the input (paths, symlinks) is refused with exit 2; file output goes to an unnamed temp (File.Atomic) renamed only on success, so failed runs never create or truncate the target. Hard links to the input are not detected. (done 2026-09-26 18:40 EDT)
- [x] Candidate scan uses an existence-only pattern (no capture history/chain): poly-A 40K 1205 -> 12 ms, linear (./bm poly-A gate); normal input ~8% faster; identical candidates by construction and by the exhaustive differentials. (done 2026-09-26 18:50 EDT)
- [x] Fixed default --max-len 50 (Peter, 2026-09-26: MinCED/PILER-CR/TRF all use fixed bounds); O(n^2) longestNonOverlappingRepeat removed; parser rejects min > max, min 0, and any length/gap (including the widened scan gap) past PCRE2's 65535 quantifier limit. (done 2026-09-26 19:35 EDT)
- [ ] Precision idea from PILER-CR: spacer length uniformity (min/max >= 0.75) and repeat conservation; validate on held-out #2.
- [x] Precision (tuned on dev + held-out #1 only): --crispr spacers 26..64 (MinCED min, PILER-CR max), repeat conservation >= 0.9 on the seed unit (PILER-CR -mincons), consensus unit extension (80% agreement), shared-10-mer spacer filter <= 0.2 of pairs alongside the positional one, length cap with an 8-base consensus margin. Dev 24/25 96.0%; held-out #1 68/71 97.1%. Frozen before scoring held-out #2. (done 2026-09-26 20:50 EDT)
- [x] HELD-OUT #2 (clean, 30 genomes, 70 EL4 arrays, code frozen at 4226a2f): dna-repeats 65/70 recall, 98.6% precision, 2.55 s, 18.0 MB; MinCED 64/70, 95.8%, 17.89 s, 466.7 MB; PILER-CR 66/70, 94.9%, 26.14 s, 19.0 MB. dna-repeats dominates MinCED on all four; on the frontier with PILER-CR (it recalls one more). (done 2026-09-26 20:55 EDT)
- [x] Negative control (dev genomes, bases shuffled, seed 1): MinCED 0, PILER-CR 0, dna-repeats 0 arrays (3.76 s/287 MB, 4.82 s/13.7 MB, 0.51 s/8.0 MB). Scorer fixes: predictions on truth-less sequences count as wrong; an empty truth file no longer reads predictions as truth; numeric totals on empty input. Dinucleotide-preserving shuffle would be more realistic (not done). (done 2026-09-26 21:25 EDT)
- [x] Divergence sweep (20 planted arrays per rate, substitutions only): recall at 0/2/4/6/8/10/12/15%: MinCED 20/19/20/17/8/3/3/0, PILER-CR 20/14/9/9/2/0/0/0, dna-repeats 20/20/18/13/6/3/0/0; precision 100% for all; dna-repeats 0.02 s vs 0.3 s. Weakness: exact seeds >= 23 bases. (done 2026-09-26 21:30 EDT)
- [ ] Divergence: seed at ~16 bases in --crispr mode, require the consensus-extended unit >= 23; validate on dev, divergence sweep and a fresh held-out #3.
- [x] Greedy peel of seed runs (coverage index, O(log n) overlap) keeps welded neighbor arrays apart; union region and deduplicated copies on merge; unit reported from the exact seed. Dev 24/25 88.9%; held-out #1 (now contaminated) 68/71 85.0%. (done 2026-09-26 17:55 EDT)
- [x] Memory: release builds drop the unused 256 KB per-thread signal stack (46.1 -> 14.4 MB on the 6.5 Mb genome, below PILER-CR 19.7 MB); ./bm gates -j 64 vs -j 1 peak RSS (<= 4 MB extra) on 1.2 Mb; bench/gen-corpus streams in O(N) with byte-identical output. (done 2026-09-26 18:25 EDT)
- [x] Normalize in place (record names owned; multi-record in-place test): peak 14.4 -> 8.2 MB on the 6.5 Mb genome, 6.2 MB on M. tuberculosis; output byte-identical on all dev genomes. (done 2026-09-26 21:08 EDT)
- [ ] Memory next: keep only seed runs per length, u32 positions; fix the two OOM-path leaks with a failing-allocator sweep.
- [ ] Review: overflow at max_gap + (max_len - lo); validate --max-gap/--max-len <= 65535; worker errors lose their type.
- [ ] Review: scoreboard hides tool failures, score.awk drops predictions on truth-less sequences, log lacks tool versions/input checksums/dirty flag.
- [ ] Review: help text stale (FASTA, IUPAC, -j default, columns); explore ships in the package; differential_test.zig tests an old pattern; bench/gen-corpus is quadratic; full report in CODE_REVIEW.md.
- [ ] Review (tests): array merge (phase C) untested, 4 mutations survived: add overlapping-candidate tests for copy counts and coordinates; budget boundary test at budget+1 mismatches; left-flank extendable case; threshold equality boundaries; spacer-identity filter pinned alone.
- [ ] Review (tests): finder exhaustive tests ~2 min (munmap churn from the testing allocator): per-subject arena, run families.zig tests once as a module, drop Finder.families-only tests covered by the pruned differential; byte classifier tests should check each byte's class, not bucket totals; CLI stderr assertions and missing cases (-j, JSON across records, empty/N-only records, min-len > max-len).
- [x] Step 1a: MinCED 0.4.2 and PILER-CR 1.06 build from source in nix/opponents.nix (TRF from nixpkgs); smoke-tested on Aquifex aeolicus. (done 2026-09-26 13:08 EDT)
- [x] Step 1b: nix/benchdata.nix pins 8 genomes and derives CRISPRCasdb truth (46 arrays, 25 at evidence level 4; starts are 1-based). (done 2026-09-26 13:20 EDT)
- [x] FASTA input: per-record search, record column/field, IUPAC -> N never matched (oracle agrees, exhaustive {A,C,N} differential). E. coli 4.6 Mb in 0.11 s wall. (done 2026-09-26 13:25 EDT)
- [x] Step 2: bench/scoreboard + tested scorer. First run: MinCED 24/25, 92.3%, 3.81 s, 294 MB; PILER-CR 24/25, 100%, 6.07 s, 19 MB; dna-repeats raw 24/25, 4.4%, 0.76 s, 45 MB. The array all miss (P. furiosus 275806) has <3 good copies. (done 2026-09-26 13:32 EDT)
- [x] Step 3: --crispr array caller (runs within spacer bounds, distinct spacers, merged nested lengths; cluster filters: spacer identity <= 0.6, not extendable at the length cap). Scoreboard: 22/25, 97.0% precision, 0.70 s, 46 MB (MinCED 24/25 92.3% 3.81 s; PILER-CR 24/25 100% 6.07 s). (done 2026-09-26 14:20 EDT)
- [x] Seed-and-extend through degraded copies (Hamming <= 15% of unit), similar-spacer-pair fraction <= 0.2 (a duplicated spacer no longer vetoes an array), unit self-similarity <= 0.7. Dev scoreboard: 24/25, 92.3%, 0.62 s, 46 MB; dominates MinCED (24/25, 92.3%, 4.25 s, 296 MB); PILER-CR 24/25, 100%, 6.31 s, 18.7 MB. Tuned on dev genomes: not a claim until held-out. (done 2026-09-26 15:00 EDT)
- [ ] Step 4: reverse-complement strand.
- [ ] Step 5: bounded-mismatch copies with an independent oracle; then rerun the scoreboard. Treat N and partial IUPAC codes (R, Y, ...) as free mismatches there; exact mode keeps N never-matching (Peter asked, 2026-09-26).
- [x] Held-out set #1 (30 genomes, 71 EL4 arrays, rule fixed first): MinCED 67/71 98.5% 15.42 s 307 MB; PILER-CR 64/71 94.6% 22.09 s 19.7 MB; dna-repeats (filters frozen at ccae987) 66/71 86.8% 2.75 s 46 MB. All three on the Pareto frontier; any filter change now must be judged on held-out set #2 (next 30 by the same rule). (done 2026-09-26 15:10 EDT)
- [ ] After the PCRE2 path matures: measure a pure-Zig finder's performance ceiling against the fork and report to Peter (Peter, 2026-09-26: fork first).
- [ ] Exploratory, measure + TDD (Peter, 2026-09-26): pure-Zig candidate scan (rolling 2-bit k-mers, recent-position table, O(n)), differential-tested against the regex scan on all small inputs and the genomes; report the measured speedup.
- [ ] Exploratory, measure + TDD: 2-bit base packing (32 bases per u64) for unit equality and popcount Hamming in seed extension.
- [ ] Exploratory, measure + TDD: SIMD (@Vector) window search for unit copies in extension and scan; compare against scalar and PCRE2 JIT.
- [ ] Final report (Peter, 2026-09-26): Pareto chart of every tool across speed, precision, recall and divergent-copy tolerance, reproducible from bench/scoreboard, with findings and anything new; publish as an artifact.
- [ ] Best-in-class biotech CLI: standard outputs (GFF3, BED, FASTA of spacers), --crispr preset, clear docs/README, packaging (Nix, static binaries; consider Bioconda).
- [x] Split the finder, oracle and CLI out of the pcre2 fork into this repository with history; pin the fork by commit bc340132 and build through Nix. (done 2026-09-24 21:50 EDT)
- [x] CLI conventions: --about, -o/--output with -/@stdout/@stderr, --no-color/--no-ansi/NO_COLOR, --ascii/--simple, TTY progress (--progress/--no-progress), debug banner, tests/cli suite as the Nix cli check in ./test. (done 2026-09-25 23:55 EDT)
- [ ] Show Peter the rendered progress bar (Unicode and --ascii) and encode the approved look as exact assertions.
- [x] Real terminal width: COLUMNS, then TIOCGWINSZ / Windows console buffer, then 80; verified in a 50-column pty. (done 2026-09-26 01:08 EDT)
- [ ] CLI follow-ups: JSON metadata (stats) on stderr; Windows /o-style aliases.
- [ ] Default --max-len: longestNonOverlappingRepeat is O(n^2) (0.94 s at 46400 bases vs 47 ms search) and a large bound widens the candidate gap. Peter to pick: fixed default (e.g. 25), required flag, or an O(n log n) suffix-array bound.
- [ ] NEXT after CLI: run lengths 25 down to 8 (one capture-history regex per length, max gap 300, non-overlapping copies; nested shorter repeats are kept) on the corpus, privately; the CLI loop already does this (Peter, 2026-09-25 23:44/23:50 EDT).
- [x] PCRE2 JIT for the finder (compile-time anchoring): 483 -> 96 ms, 5.0x, synthetic 2900-base corpus, lengths 8..25, gap 300, ReleaseFast, hyperfine. (done 2026-09-26 00:02 EDT)
- [x] Unanchored scan per length: 91.3 -> 86.4 ms (1.06x). (done 2026-09-26 00:04 EDT)
- [x] Candidate-start pruning: one min-length scan with gap D+(max-min) bounds every length's chain starts; lengths probe only those (anchored JIT). 88.1 -> 10.4 ms (8.4x), output identical on sample and synthetic; ~46x vs the interpreter. (done 2026-09-26 00:12 EDT)
- [x] Parallel: chunked candidate scan (exact truncated windows, exhaustive boundary test) and a per-length worker pool; -j/--threads, auto stays 1 thread under 16K bases. 92800 bases: 269.5 -> 48.0 ms wall (5.6x), user +5%; 2900 unchanged at 10.6 ms. (done 2026-09-26 00:48 EDT)
- [ ] Efficiency, remaining: at 2900 bases 1.2 of 10.6 ms is process start and ~5.5 ms the single O(n*D) candidate scan; a cheaper gap formulation inside the regex is the next lever. Show Peter before going further.
- [x] Peter's "array of multiple matches" is capture history, which the finder already uses via Api.events; nothing further to adopt. (done 2026-09-25 23:50 EDT)
- [ ] Label families by maximality and Pareto (length vs count) dominance.
- [x] ./bm: linear-scaling gate (N..8N, 11600-92800 bases, ratio 1.93-2.00) and two-sided 25% per-machine ndjson gate on user time; both gates mutation-checked. (done 2026-09-26 00:20 EDT)
- [ ] ./bm: add the longestNonOverlappingRepeat bound (default --max-len path) to the scaling gate.
- [x] Cross-platform matrix as the Nix cross check in ./test: x86_64/aarch64 linux-musl (static), aarch64-macos, x86_64/aarch64 windows-gnu, JIT on. Static x86_64 and aarch64 (qemu) output identical to native. (done 2026-09-26 01:00 EDT)
- [ ] Run the Windows (wine) and macOS binaries, not just build them; wire Mechatron Prime CI (mechatron-ci skill) once Peter wants CI here.
- [x] Repin the fork to 5f6c6088 (capture-history event limit, PCRE2_ERROR_CAPTURE_HISTORY_LIMIT); 58 tests green. (done 2026-09-25 23:35 EDT)
- [ ] Repin the fork when capture-history changes; the deps hash in flake.nix must be regenerated with it.
