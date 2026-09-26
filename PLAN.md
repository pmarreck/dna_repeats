# PLAN

Completed items retire to docs/PLAN_LOG.md. Split out of the pcre2 fork on 2026-09-24 (history kept via git subtree split).

## Now

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
