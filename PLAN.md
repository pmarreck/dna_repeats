# PLAN

Completed items retire to docs/PLAN_LOG.md. Split out of the pcre2 fork on 2026-09-24 (history kept via git subtree split).

## Now

- [x] Split the finder, oracle and CLI out of the pcre2 fork into this repository with history; pin the fork by commit bc340132 and build through Nix. (done 2026-09-24 21:50 EDT)
- [x] CLI conventions: --about, -o/--output with -/@stdout/@stderr, --no-color/--no-ansi/NO_COLOR, --ascii/--simple, TTY progress (--progress/--no-progress), debug banner, tests/cli suite as the Nix cli check in ./test. (done 2026-09-25 23:55 EDT)
- [ ] Show Peter the rendered progress bar (Unicode and --ascii) and encode the approved look as exact assertions.
- [ ] CLI follow-ups: JSON metadata (stats) on stderr, real terminal width via ioctl instead of COLUMNS/80, Windows /o-style aliases.
- [ ] NEXT after CLI: run lengths 25 down to 8 (one capture-history regex per length, max gap 300, non-overlapping copies; nested shorter repeats are kept) on the corpus, privately; the CLI loop already does this (Peter, 2026-09-25 23:44/23:50 EDT).
- [ ] Make the single-regex finder as efficient as possible; measure before/after with hyperfine (Peter, 2026-09-25).
- [x] Peter's "array of multiple matches" is capture history, which the finder already uses via Api.events; nothing further to adopt. (done 2026-09-25 23:50 EDT)
- [ ] Label families by maximality and Pareto (length vs count) dominance.
- [ ] ./bm: scaling-ratio gate at N,2N,4N,8N for the finder and the LNRS bound, ndjson log per machine.
- [ ] Cross-platform build matrix (Linux/macOS/Windows, aarch64/x86_64) as a Nix check.
- [x] Repin the fork to 5f6c6088 (capture-history event limit, PCRE2_ERROR_CAPTURE_HISTORY_LIMIT); 58 tests green. (done 2026-09-25 23:35 EDT)
- [ ] Repin the fork when capture-history changes; the deps hash in flake.nix must be regenerated with it.
