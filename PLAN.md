# PLAN

Completed items retire to docs/PLAN_LOG.md. Split out of the pcre2 fork on 2026-09-24 (history kept via git subtree split).

## Now

- [x] Split the finder, oracle and CLI out of the pcre2 fork into this repository with history; pin the fork by commit bc340132 and build through Nix. (done 2026-09-24 21:50 EDT)
- [ ] CLI conventions: --about, @stdout/-o, --no-color/--ascii, stderr progress on a TTY, and a Bash CLI suite under tests/cli wired into ./test.
- [ ] Label families by maximality and Pareto (length vs count) dominance.
- [ ] ./bm: scaling-ratio gate at N,2N,4N,8N for the finder and the LNRS bound, ndjson log per machine.
- [ ] Cross-platform build matrix (Linux/macOS/Windows, aarch64/x86_64) as a Nix check.
- [ ] Repin the fork when capture-history changes; the deps hash in flake.nix must be regenerated with it.
