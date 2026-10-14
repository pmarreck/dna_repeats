# PLAN

Completed items retire to docs/PLAN_LOG.md. Split out of the pcre2 fork on 2026-09-24 (history kept via git subtree split).

Decision (BDFN, Benevolent Dictator For Now, 2026-09-26; reconfirmed 2026-10-01): the CLI imports the Zig core directly; no C FFI until someone requests one.
Decision (BDFN, 2026-09-26): correctness is determined in Zig Debug mode (./test runs zig build test -Doptimize=Debug); benchmarks run ReleaseFast only.
Status: parked by BDFN on 2026-09-29; resume only on explicit direction.

## Now

- [ ] ART (BDFN, 2026-09-28): run on the relevant genomes and try to exceed the Anthropic ART preprint; scope answered 2026-09-28 (reproduce plus array-first census, metagenomic viral contigs, prodigal and HMMER). Results so far in intents/art_search.md.
	- [ ] ART 5b: IMG/VR v4.1 census, blocked until BDFN has JGI access (MGV, INPHARED, GPD and the shuffled controls are done).
	- [x] ART 5g: do family 3 spacers (crAss orphan CRISPR arrays) match other MGV genomes (exact 25-mers, both strands), i.e. do they target competing phages? (moot 2026-09-29 00:10 EDT: only 1 of 283 family-3 regions holds a CRISPR array; the label came from the representative alone)
	- [x] ART 5h: art-screen labels per member, not per representative (fraction of members matching Rfam, tRNA, CRISPR), test first; rerun the MGV screen and fix the counts in intents/art_search.md. (done 2026-09-29 00:25 EDT, 6764ead; MGV v2: 37 known, 56 CRISPR, 687 unexplained of 780)
	- [x] ART 5i: family 1 (585 arrays) hits RAGATH-1-hammerhead in 133 members: check the rest below gathering threshold (cmscan -E 0.01) and whether each copy is one ribozyme. (done 2026-09-29 14:15 EDT: one hammerhead per array in 149 of 585, inside a spacer; known RNA class)
	- [ ] Long-period repeat census (BDFN, 2026-09-28): units of 50..500 nt, copies up to several kb apart, across the same phage collections; cluster families and screen out known element classes (coding repeats, rRNA, insertion sequences) before calling anything novel. After the ART census.
	- [ ] ART 6: findings report and README section.
- [x] Auto thread count: default (all 128) is 15% slower than -j 48 on held-out #3 (589 vs 511 ms; knee near 32). Measure per phase (scan chunks vs per-length pool, which cannot use more threads than lengths) and cap accordingly. (done 2026-09-29 14:45 EDT via the chunk floor, a2f4e08)
- [ ] Release binaries for the 5 targets (gh release).
- [ ] Precision idea from PILER-CR: spacer length uniformity (min/max >= 0.75) and repeat conservation; validate on held-out #2.
- [x] Memory next: keep only seed runs per length, u32 positions; fix the two OOM-path leaks with a failing-allocator sweep. (closed 2026-09-29 14:55 EDT: leaks fixed in 9db1715; u32 positions measured at ~1.5% of peak, see CR14)
- [ ] Test speed: finder exhaustive tests take ~2 min per binary and the finder module is tested in three binaries; try a per-subject arena and testing the finder in one binary.
- [ ] CLI test cases for an empty record and an N-only record (the 2026-09-26 review's other items are done: limits, help text, explore, differential, gen-corpus, byte classifier).
- [ ] Step 4: reverse-complement strand.
- [ ] Step 5: bounded-mismatch copies with an independent oracle; then rerun the scoreboard. Treat N and partial IUPAC codes (R, Y, ...) as free mismatches there; exact mode keeps N never-matching (BDFN, 2026-09-26).
- [ ] Step 5 idea (BDFN, 2026-09-28): packed 2-bit sub-words as exact pigeonhole seeds for mismatch copies (m mismatches in a k-mer leave an exact piece of k/(m+1) bases); a lone 4-base byte filter would pass ~30% of random windows, too weak alone.
- [ ] Pure-Zig family finder: measure against the capture-history regex now that the prefilter is Zig (regex families are 28% of one-thread time on E. coli).
- [ ] Exploratory, measure + TDD: 2-bit base packing (32 bases per u64) for unit equality and popcount Hamming in seed extension.
- [ ] Exploratory, measure + TDD: SIMD (@Vector) window search for unit copies in extension and scan; compare against scalar and PCRE2 JIT.
- [ ] Best-in-class biotech CLI: standard outputs (GFF3, BED, FASTA of spacers) and packaging (static binaries; consider Bioconda).
- [ ] Progress bar redesign: BDFN (2026-10-01) wants a nicer look, for example braille characters; render samples, get approval, then encode the approved look (Unicode and --ascii) as exact assertions.
- [ ] Windows /o-style option aliases (approved by BDFN 2026-10-01), CLI tests first.
- [ ] JSON metadata (stats) on stderr; flag name not yet decided.
- [ ] Label families by maximality and Pareto (length vs count) dominance.
- [ ] Run the Windows (wine) and macOS binaries, not just build them; wire Mechatron Prime CI (the project's continuous-integration service; mechatron-ci skill) once BDFN wants CI here.
- [ ] Repin the fork when capture-history changes; the deps hash in flake.nix must be regenerated with it.

## Code review 2026-09-28 (Grok, at cc8e504; findings double-checked)
- [x] CR10b: on a quiet machine, log held-out #3 scoreboard rows for the f348b1b caller and regenerate docs/img charts; rerun the ART censuses (MGV, INPHARED, GPD) with it and update intents/art_search.md counts. (done 2026-09-29 11:52 EDT: quiet-machine scoreboard, thread sweep, E. coli timing, verify sample, charts)
- [x] BDFN 2026-09-29: the README headline and chart show the 128-thread time, but -j 48 was faster: make the default thread count pick the fast setting (see Auto thread count), then report the default. (done 2026-09-29 14:45 EDT: 128K scan-chunk floor makes the default the fastest setting)
- [x] BDFN 2026-09-29: the held-out chart gets a separate column with dna-repeats' multiplier over the best previous tool per axis (e.g. "44x"). (done 2026-09-29 14:45 EDT; tested in tests/bench/run)
- [x] CR8c: per-length exact candidates (lengthCandidates: one window scan per start for all lengths, tested against the definition); identical output, verify 47/47; E. coli one thread --crispr 139 -> 118 ms, --art 1196 -> 831 ms user; held-out #3 one thread 3.72 -> 3.32 s, multi-thread unchanged. (done 2026-09-29 14:25 EDT)
- [x] CR14 (backlog): u32 positions with a >4 GiB record guard; keep only needed family headers in callArrays (main.zig:207). (closed 2026-09-29 14:55 EDT, measured: on CP048835.1 (9.56 Mb, peak 12.3 MB at --crispr -j 1) all positions are 0.36 MB as usize, so u32 saves ~1.5%; family headers ~0.44 MB; the peak is the input genome, ~1 byte per base. Not worth the refactor.)
