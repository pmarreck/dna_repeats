# Code Review -- dna_repeats
**Date:** 2026-09-26
**Reviewer:** Claude (deep-code-review skill; five parallel reviewers)
**Scope:** Full codebase audit at c0a468f..67cf80f. Dimensions 11 (FFI) and 13 (database) do not apply: no C FFI (Peter approved the Zig-direct CLI) and no database. Memory was the lead dimension at Peter's request.

## Summary

| Severity | Count | Fixed since the review |
|---|---|---|
| CRITICAL | 5 | 4 |
| WARNING | ~30 | 2 |
| ADVISORY | ~45 | 0 |

## Critical issues and status

| Finding | Status |
|---|---|
| Per-thread 256 KB signal stack zero-filled for every thread: 46 MB peak on a 6.5 Mb genome | Fixed in 67cf80f (14.4 MB); ./bm gates -j 64 vs -j 1 peak RSS |
| `-o` truncates before reading: `-o X` with input X destroyed X; failed runs left empty outputs | Fixed in f20ec64 and c5a2e4c (refuse same file, atomic rename for regular files, direct writes for devices and pipes) |
| Candidate scan walked the whole capture-history chain per start: quadratic in tandem runs | Fixed in 4204b04 (existence-only pattern; poly-A 100x faster; ./bm poly-A gate) |
| Default `--max-len` bound is O(n^2), computed twice, inflated by N runs past PCRE2's quantifier limit | Open: default needs Peter's decision (PLAN.md) |
| Array merge (phase C) untested: four mutations survived | Open (PLAN.md) |

The full findings of each reviewer follow, verbatim, with file:line references at the reviewed commit.


---

## dna_repeats memory review (dimension 10 + memory half of 7)

Reviewed at c0a468f. Binary: `nix build .#default` (ReleaseFast). Machine: 128 CPUs.
Peak RSS from GNU time 1.10 `%M`; heap from heaptrack 1.5. Experiments were built in a
scratch copy (`git archive HEAD`), never in the repo.

## Where the 46 MB goes (measured, CP000438.1, 6.63 MB file, 6.54 Mb, `--crispr`)

| -j  | RSS      | wall   |
|-----|----------|--------|
| 1   | 14.4 MB  | 3.74 s |
| 8   | 15.4 MB  | 0.51 s |
| 25  | 20.5 MB  | 0.19 s |
| 64  | 30.8 MB  | 0.12 s |
| 128 | 46.1 MB  | 0.10 s |

About 250 KB of RSS per thread. heaptrack shows an identical **heap** peak (17.24 MB) at
-j 1 and -j 128, so the per-thread cost is not malloc. `MALLOC_ARENA_MAX=1` changes
nothing (47.1 MB at -j 128), so it is not glibc arenas either. It is static TLS (below).

Of the -j 1 baseline, heaptrack attributes 6.63 MB to the raw file buffer and 6.63 MB to
`clean_buf`; everything else on the heap (starts, families, Packer maps) is under 0.5 MB
on this genome.

Measured fixes (scratch builds, byte-identical `--crispr` output checked with `cmp`):

| build                           | CP000438.1 j=1 / j=128 | U00096.3 j=1 / j=128 | AL123456.3 j=1 / j=128 |
|---------------------------------|------------------------|----------------------|------------------------|
| HEAD                            | 14.4 / 46.1 MB         | 12.3 / 43.0 MB       | 16.4 / 43.0 MB         |
| + no TLS signal stack           | 15.5 / 14.4 MB         | 11.3 / 10.3 MB       | 14.4 / 11.3 MB         |
| + normalize in place (no clean_buf) | 8.2 / 7.2 MB       | 7.2 / 6.2 MB         | 13.4 / 7.2 MB          |

(RSS jitters by about 1 MB run to run; the in-place build corrupts record names, see finding 2,
so its TSV was compared from column 2 on and matched.)

---

## Findings

### 1. CRITICAL 🔥 256 KB static-TLS signal stack per thread, zero-filled by glibc on every spawn
- **Location**: /home/pmarreck/Code/dna_repeats/src/main.zig:1-10 (no `std_options`); threads spawned at /home/pmarreck/Code/dna_repeats/src/finder.zig:187 and :299
- **Issue**: Zig 0.16's default `std.options.signal_stack_size = 1 << 18` puts a `threadlocal var signal_stack: [262144]u8` in `.tbss` (`Thread.maybeAttachSignalStack.global.signal_stack`, readelf: TLS memsz 0x40015). glibc memsets each new thread's TLS block, so each thread touches 256 KB.
- **Detail**: Measured, it accounts for the whole thread-count slope: 128 candidate-scan chunks (`@min(128, 6.5M/16384)`) + 24 length helpers, about 32 MB. In ReleaseFast the stack serves no purpose: `std.debug.default_enable_segfault_handler = runtime_safety and ...` is false, so no handler ever runs on it. Fix (measured: CP000438.1 -j 128 46.1 → 14.4 MB, output identical, wall unchanged):
  ```zig
  pub const std_options: std.Options = .{
      .signal_stack_size = if (std.debug.default_enable_segfault_handler) 1 << 18 else null,
  };
  ```
  This keeps stack-overflow traces in Debug/ReleaseSafe (build.zig's own default is ReleaseSafe, which would still pay 256 KB/thread; a second fix there is to cap threads, see plan). Because this is a `std_options` default that silently returns with any future std upgrade or a new executable, it is worth a test that asserts the TLS segment size (e.g. a CLI test running `readelf -lW` / checking RSS at -j 1 vs -j 64 stays within a small delta).

### 2. WARNING ‼️ Input held twice: raw file plus a same-size normalized copy
- **Location**: /home/pmarreck/Code/dna_repeats/src/main.zig:109-119
- **Issue**: `raw` (readFileAlloc) and `clean_buf = gpa.alloc(u8, raw.len)` both live for the whole run; `raw` is only needed for record names.
- **Detail**: Measured 6.63 MB each on CP000438.1; removing `clean_buf` takes -j 128 from 14.4 to 7.2 MB. Normalization never writes ahead of the read cursor (`n <= pos` in `parseFasta`, `n <= i` in `normalize`), so `parseFasta(gpa, raw, raw, ...)` is safe for sequence bytes. **Lifetime hazard if done naively**: `Record.name` borrows `raw` (/home/pmarreck/Code/dna_repeats/src/normalize.zig:54-55), and later sequence writes overwrite earlier header bytes. The measured in-place build printed `GCTTTTCA` as the record name for U00096.3. Fix: dupe each name into a small side allocation (or an arena) before continuing, and add a two-record FASTA test that asserts both names survive in-place normalization. A streaming parse (64 KB reader buffer writing directly into one `stat`-sized sequence buffer) reaches the same 1x footprint without the in-place subtlety. Secondary: `readFileAlloc` grows via `appendRemaining`, reserving a 9.95 MB capacity for a 6.63 MB file (heaptrack); only touched pages count as RSS, so this is virtual, not resident.

### 3. WARNING ‼️ Every family of every length is materialized, then copied again, before array calling
- **Location**: /home/pmarreck/Code/dna_repeats/src/finder.zig:176-195 (all lengths' slots held at once), /home/pmarreck/Code/dna_repeats/src/main.zig:174-176 (`all` copies every `Family` header), /home/pmarreck/Code/dna_repeats/src/arrays.zig:47-63 (`runs`)
- **Issue**: In `--crispr` mode the caller only needs runs of >= 2 copies whose spacers are within bounds, but all families (usize positions, one malloc each) are kept, then `all` duplicates their 24-byte headers, then `runs` (48 bytes each) is built on top.
- **Detail**: Small on CP000438.1 (4,210 families, 10,523 positions) but not on repeat-rich genomes. AL123456.3 (M. tuberculosis, 4.47 MB): 63,300 families, 164,043 positions. heaptrack at -j 1 (in-place build): 1.31 MB in 63,300 position slices (plus about 1 MB of malloc chunk headers, estimated at 16 B each), 2.46 MB peak for an ArrayList growing over 21 reallocs from `main` (by size and count this matches `all`; symbolization was folded, so attribution is inferred), 1.90 MB over 5 calls also from main (consistent with `runs`), 1.83 MB in `familiesByLength`. That is about 7 MB of family bookkeeping, which is why AL123456.3 stays at 13.4 MB at -j 1 even after fixes 1 and 2. Fixes, cheapest first: (a) pass `results.per_length` to `callArrays` as `[]const []const Family` and drop `all` (saves about 1.5-2.5 MB here); (b) in array mode, have each worker reduce its length's families to seed runs (positions within spacer bounds, >= 2 copies) and free the rest before returning, so only candidate runs survive; (c) store positions as `u32` (finding 5).

### 4. ADVISORY ⚠️ -j 1 is heavier than -j 128 on a family-heavy genome
- **Location**: /home/pmarreck/Code/dna_repeats/src/finder.zig:117-125, :131-136 (per-length Packer map/list growth and free interleaved with 63k long-lived small allocations)
- **Issue**: Measured AL123456.3 in-place build: 13.4 MB at -j 1 vs 7.2 MB at -j 128 with the same heap peak (14.41 MB heaptrack).
- **Detail**: Estimated cause is glibc main-arena fragmentation: each length's `covered_until` map and `out` list grow and are freed while that length's position slices stay pinned between them, so freed space cannot be returned or reused for larger requests. Finding 3(b) removes most of it. Alternatively, give each length an arena for Packer scratch (map + positions) and copy only the surviving positions out into one contiguous per-length buffer (one allocation per length instead of one per family).

### 5. ADVISORY ⚠️ usize (8 bytes) for positions and starts where u32 suffices
- **Location**: /home/pmarreck/Code/dna_repeats/src/families.zig:22-24 (`Family.positions: []usize`), /home/pmarreck/Code/dna_repeats/src/finder.zig:234-258 (`starts`), :109 (`Packer.positions`)
- **Issue**: Positions never exceed the record length; u32 covers 4.29 Gb records.
- **Detail**: Estimated savings: AL123456.3 positions 1.31 → 0.66 MB; `Family` shrinks from 24 to 16 bytes (u32 len + slice) or 12 with a u32 offset/count into a shared buffer. Candidate starts are small here (about 215 KB of ArrayList growth on CP000438.1, measured), and `candidateStartsParallel` briefly holds them twice (per-chunk lists + concatenated `all`, /home/pmarreck/Code/dna_repeats/src/finder.zig:283-317); u32 halves both. Worth doing with finding 3, not alone. Needs a guard (error or u64 fallback) for records over 4 Gb.

### 6. ADVISORY ⚠️ Leak on OOM: position slice duped before append
- **Location**: /home/pmarreck/Code/dna_repeats/src/finder.zig:124
- **Issue**: `try self.out.append(gpa, .{ ..., .positions = try gpa.dupe(usize, ...) })` evaluates the dupe first; if the append then fails, the duped slice is owned by nobody.
- **Detail**: Only on OutOfMemory. Fix: `try self.out.ensureUnusedCapacity(gpa, 1);` before the dupe, then `appendAssumeCapacity`. A `std.testing.FailingAllocator` sweep over `familiesAt` (fail index 0..N) would catch this and finding 7 mechanically.

### 7. ADVISORY ⚠️ Leak on OOM: extended copies lost if `cands.append` fails
- **Location**: /home/pmarreck/Code/dna_repeats/src/arrays.zig:84-85
- **Issue**: `copies` from `extend` is appended into `cands` with `try`; on failure the deferred cleanup at :69-72 frees only what is already in `cands`.
- **Detail**: Only on OutOfMemory. Fix: `try cands.ensureUnusedCapacity(gpa, 1)` before `extend`, or `errdefer gpa.free(copies)` scoped to the append. Same FailingAllocator sweep as finding 6.

### Checked and clean
- `familiesByLength` / `candidateStartsParallel` error paths: the join `defer` is registered after the `errdefer results.deinit`, so workers are joined before slots are freed; failed lengths leave `&.{}` slots that free cleanly.
- `Finder.compile`: `errdefer pcre2_code_free_8` covers a failed match-data allocation; `deinit` frees code (and its JIT memory) and match data.
- Capture history (fork): events live in `match_data->history`, grown on demand and freed with the match data (pcre2_match_data.c:109-110); the Packer copies positions out before the next match, so no borrowed-event lifetime issue. Per-thread history storage is proportional to one chain and negligible.
- Per-thread PCRE2 compile + JIT (128 in the candidate scan, 25 for lengths): JIT code comes from sljit's shared 64 KB exec chunks (2 such mmaps seen in strace); negligible.
- Thread stacks: 16 MiB `MAP_STACK` mmaps per thread are virtual only; RSS after fix 1 shows no per-thread slope.
- heaptrack "leaked" 704 B at -j 128 is glibc `_dl_allocate_tls` bookkeeping, not project code; -j 1 reports 0 B.

## Ranked plan to get under PILER-CR's 19.7 MB

1. **Drop the TLS signal stack outside safety builds** (finding 1). One declaration in main.zig. Measured 46.1 → 14.4 MB on the 6.6 Mb genome at default -j, 43.0 → 11.3 MB on AL123456.3. This alone beats 19.7 MB on every genome tried. Add a regression gate (RSS at -j 64 within about 2 MB of -j 1, or a TLS-size check) so a std upgrade cannot bring it back silently.
2. **Normalize in place and copy record names** (finding 2), with a multi-record name-survival test. Measured 14.4 → 7.2 MB (CP000438.1), 10.3 → 6.2 MB (U00096.3). Peak becomes roughly 1.1x the input size.
3. **Stop materializing all families in array mode** (finding 3a then 3b), plus u32 positions (finding 5). Targets repeat-rich genomes: estimated 5-7 MB off AL123456.3 at -j 1 (13.4 MB measured now), which also removes the -j 1 fragmentation anomaly (finding 4).
4. **Optional for ReleaseSafe builds**: cap the candidate-scan chunk count (e.g. 16-32); -j 32 already reaches 0.15 s vs 0.10 s at 128, and it bounds any per-thread cost that returns.
5. **Fix the two OOM leaks** (findings 6, 7) behind a FailingAllocator sweep test.

---

## Algorithmic complexity review: dna_repeats

All timings come from the release build (`nix build .#default`, /nix/store/wjiclc22...-dna-repeats-0.1.0) run with `-j 1 --no-progress` on this Linux box. Corpora came from `bench/gen-corpus N 1`, plus synthetic poly-A and an exact period-30 tandem array.

## CRITICAL 🔥 — default `--max-len` bound is O(n^2), and main computes it twice
**Location:** src/families.zig:328-339 (`longestNonOverlappingRepeat`), called from src/main.zig:150 and src/main.zig:161
**Issue:** When `--max-len` is omitted, every run does n^2/2 byte comparisons before any searching starts. For plain (non-FASTA) input it does them twice.
**Detail:** Measured on gen-corpus with the auto bound versus `--max-len 20`:

| n | auto | --max-len 20 |
|---|---|---|
| 50k | 2.32 s | 0.16 s |
| 100k | 8.57 s | 0.32 s |
| 200k | 33.84 s | 0.67 s |

The auto time grows 4x per doubling. At 200k, the "families in 17107 ms" line covers only the second call. The line-150 banner call spends the other ~16.7 s computing the same number. Extrapolating, a 248 Mb chromosome needs about 1.5e6 times the 200k cost, which is months. Gigabase and metagenome inputs cannot finish.
The bound also ignores D. On real genomes the global longest non-overlapping repeat is a segmental duplication tens to hundreds of kb long. That makes the number of lengths Λ = max_len - min_len + 1 enormous, and it widens the candidate-scan gap to D + Λ (see the next finding). Both multiply the rest of the pipeline.
**Fix:** (1) Compute the bound once: hoist it out of the banner and reuse it in the loop. (2) Replace the O(n^2) shift scan with a suffix array + LCP pass (O(n log n), or O(n) with SA-IS). Checking non-overlap is a small adjustment over adjacent SA entries. (3) Better still, make the bound gap-aware, because a family needs two copies at shift s in [L, L+D]. Note that this predicate is not monotone in L, so binary search does not apply; it needs an SA/LCP formulation, or a length cap derived from D. Also update the doc comment, which does not mention the double call.

## CRITICAL 🔥 — candidate scan walks the whole chain at every start: O(m^2) on tandem arrays
**Location:** src/finder.zig:245-258 (`scanStarts`), pattern built at src/finder.zig:38; doc at src/finder.zig:233
**Issue:** The candidate scan only needs to know whether a start has at least one copy within the widened gap. Its pattern uses the possessive `(...)++` capture-history chain, so each unanchored match walks every copy to the end of the repeat before `from = start + 1`.
**Detail:** Inside a tandem or low-complexity run of length m, every offset is a chain start. Each start walks O(m) bytes, so the total is O(m^2). Measured with `--max-len 20`:

| input | 20k | 40k | 80k |
|---|---|---|---|
| exact period-30 tandem | 0.60 s | 2.33 s | — |
| poly-A | 0.29 s | 1.33 s | 4.79 s |

The 10k tandem took 0.15 s. The cost is independent of Λ: poly-A 80k takes 4.66 s at `--max-len 8` and 4.70 s at `--max-len 40`. That rules out the per-length pass and identifies the candidate scan as the culprit. A 3 Mb alpha-satellite array extrapolates to about 3.6 h for that array alone. The chunked parallel scan bounds each chunk's walk to its own span, but a large array is still quadratic within its chunk. The doc comment "one unanchored scan at min_len" hides this cost. It also hides the O(n·(D + max_len - min_len)) lazy-gap cost on non-repetitive input: at 100k with max-len 20, gap 100/400/1600 took 0.07/0.32/1.50 s.
**Fix:** Compile a separate existence-only scan pattern with no `(*CAPTURE_HISTORY)` and no `++`, for example `(?=([ACGT]{L}).{0,G}?\1)`. Each attempt then costs O(G·L) worst case and O(G) typical, independent of chain length, and it keeps the superset guarantee, since that guarantee needs only one hit. Optionally replace the scan with a k-mer next-occurrence pass: a 2-bit packed u64 key for min_len ≤ 32 and one hash-map pass. That is O(n) and independent of D. INTENT.md pins PCRE2 as the matcher, not the prefilter, but Peter should decide whether that is allowed.

## WARNING ‼️ — widened gap D + (max_len - min_len) destroys the prefilter for wide length ranges
**Location:** src/finder.zig:239, src/finder.zig:278
**Issue:** One scan at min_len with gap D + Λ - 1 costs O(n·(D+Λ)), and its selectivity collapses as Λ grows.
**Detail:** At 100k, gap 400: max-len 20 took 0.32 s and max-len 200 took 1.84 s. At gap 1600, max-len 200 took 10.0 s. Once the widened gap approaches 4^min_len (65,536 for min_len 8), almost every offset becomes a candidate. The auto bound on a real genome easily reaches that. From then on, every per-length pass in `familiesAt` probes nearly all n offsets, so the total becomes O(Λ·n·D).
**Fix:** Band the length range. Run one candidate scan per band [a, b] with b - a ≤ D (or another fixed width), so the widened gap stays ≤ 2D, and feed each band's lengths only that band's starts. Scan work becomes O((Λ/D)·n·D) = O(Λ·n) instead of O(n·(D+Λ)) per scan, and the prefilter stays selective.

## WARNING ‼️ — array extension re-walks the same array once per seed group: O(g·k)
**Location:** src/arrays.zig:73-87 (group loop calling `extend`), src/arrays.zig:144-178
**Issue:** Each group of overlapping runs extends outward independently. A degraded array whose exact-copy seeds break into g disjoint groups is therefore scanned g times across its full k copies, and the duplicates are only collapsed later in stage C.
**Detail:** If every ~3rd copy is mutated, g ≈ k/3 and the total is O(k^2·W·L), where W = max_spacer - min_spacer + 1. This is harmless for CRISPR (k ≤ a few hundred, W = 53). In plain `--arrays` mode, `min_spacer` defaults to 0 and `max_spacer` is `max_gap` (400). A degraded satellite array with thousands of copies then pays O(k^2) extensions, each probing up to 401 windows.
**Fix:** Process groups in start order. When a run starts before the previous candidate's extended end, fold it into that candidate (or skip extending it) instead of extending again. Stage C already merges overlapping candidates, so the change only affects which run seeds the extension. Check this against the scoreboard, because the "most copies, then longest" choice could shift.

## WARNING ‼️ — `callArrays` complexity comment is wrong
**Location:** src/arrays.zig:44
**Issue:** The comment claims "O(F log F + sum of k^2 * spacer length)". That omits the extension term O(Σ groups · extended copies · W · L), which is quadratic in copies per the previous finding, and `selfSimilarity` at O(L^2) per array.
**Fix:** Change it to `O(F log F + Σ_groups (extended copies · W · L) + Σ_arrays (k^2 · spacer + L^2))`, or fix the extension redundancy and state the resulting bound.

## ADVISORY ⚠️ — the O(k^2) spacer check runs before cheaper filters and never exits early
**Location:** src/arrays.zig:104-107, src/arrays.zig:188-207
**Issue:** `similarSpacerFraction` (O(k^2·spacer)) is evaluated before `selfSimilarity` (O(L^2)) and `extendable` (O(k)) in the `and` chain. It also always computes every pair.
**Detail:** For k = 10^4 (a satellite region that reaches stage C in `--arrays` mode), that is 5e7 pairs times the spacer length. Rejecting early is exact. The total pair count is known in advance ((k-1)(k-2)/2), so the loop can return as soon as `similar` exceeds `max_fraction · total` (reject), or as soon as `similar + remaining` can no longer exceed it (accept).
**Fix:** Reorder the conjuncts to min_copies, selfSimilarity, extendable, then spacers, and add both early exits. Worst-case O(k^2) remains, but that case needs a fraction near the threshold.

## ADVISORY ⚠️ — `hamming` has no early exit at the mismatch budget
**Location:** src/arrays.zig:180-184 (used at :156 and :172)
**Issue:** Every extension probe compares all L bytes even after the budget is exceeded.
**Detail:** On a random window the budget (floor(0.15·L), 4 for L = 29) is exceeded after about (budget+1)/0.75 ≈ 7 bytes, so the full compare does about 4x the necessary work. The complexity order is unchanged.
**Fix:** Pass the budget in and return as soon as `d > budget`.

## ADVISORY ⚠️ — the `families()` doc says covered starts are skipped before matching, but in the unanchored path they are not
**Location:** src/finder.zig:60-64, src/finder.zig:73-80
**Issue:** In `families()`, `pcre2_match` runs, and so walks the full chain, before `packer.covered` is checked. Every start inside an accepted member still costs a full chain walk: O(m^2) on tandem runs, the same shape as the candidate scan. "O(n) chain-start attempts" understates this.
**Detail:** `families()` is reached only through `findFamilies`, which is test-only. main uses `familiesAt`, which does check `covered` first. The practical impact is test time and a misleading comment.
**Fix:** Correct the comment to say the check happens after the match in this path, and state the O(Σ chain length) cost. Alternatively, have `findFamilies` go through candidateStarts + familiesAt.

## ADVISORY ⚠️ — `familiesAt` costs O(m·P) per length on period-P tandem arrays
**Location:** src/finder.zig:87-101
**Issue:** The `covered` skip removes starts with the same unit, but each of the P rotation phases walks its own chain. Every chain step lazily scans about P - L gap offsets.
**Detail:** The work is O(m·P·Λ) against O(m·Λ) output positions. Growth is linear in m, but for a 171-bp alpha satellite that is a constant factor of about 170. The doc comment "one anchored match per candidate start" omits the per-match cost O(steps·(D+1)·L).
**Fix:** This is inherent to the regex design, so only the doc comment needs changing: "each match O(chain steps · (D+1)) with O(L) backreference compares".

## ADVISORY ⚠️ — memory is O(8n) at gigabase scale
**Location:** src/main.zig:112-119, src/finder.zig:311
**Issue:** The whole file is held twice (`raw` + `clean_buf`), and candidate starts are stored as `usize`, 8 bytes each. When the widened gap makes most offsets candidates (the widened-gap finding above), starts alone reach 8n bytes, about 24 GB for 3 Gbp.
**Fix:** Once the scan is chunked, store starts as u32 offsets relative to each record (records are < 4 Gbp), or stream candidates per band. Normalizing in place into `raw` would save the second copy.

## Checked and acceptable
- Per-length recompilation (finder.zig:223): the backreference length has to be in the pattern, so recompiling is unavoidable. With Λ = 193 it is not the visible cost; the run time grows with Λ·S·D, not with compile count.
- Packer `StringHashMap` keyed by subject slices (finder.zig:108-125): `covered` hashes L bytes per candidate per length. The anchored match already reads ≥ L bytes, so hashing has the same order and does not dominate. The map is bounded by that length's output families. A 2-bit packed u64 key for L ≤ 32 would be a constant-factor tweak.
- Sorting in `callArrays` (O(F log F)) and stage A/B/C grouping are linear sweeps.
- `selfSimilarity` is O(L^2) per reported array and trivial at L ≤ 47.
- The fixed-bound pipeline is linear in n on random input: gen-corpus with `--max-len 20` took 0.16/0.32/0.67 s at 50k/100k/200k.

---

## dna_repeats review: dimensions 1 (inconsistent/incomplete functionality) and 12 (error handling)

Commit reviewed: c0a468f (yolo). Binaries: `zig build` (ReleaseSafe default) and a Debug build in the scratchpad.

## CRITICAL 🔥 `-o` pointing at the input file silently destroys the input
- **Location:** src/main.zig:83-93 (output created) vs src/main.zig:109-116 (input read)
- **Issue:** The output file is created (truncated) before the input is read. `dna-repeats --crispr x.txt -o x.txt` truncates `x.txt`, then reads 0 bases, prints `0 arrays` and exits 0. Verified: a 379-byte input became 0 bytes, rc=0.
- **Detail:** The same ordering also truncates or creates an existing output file when the input then fails (missing file, invalid byte). Verified: `-o created.tsv` with a nonexistent input left an empty `created.tsv`. Fix: read and validate the input first, then create the output. Better still, write to a temp file in the output directory and rename it on success. Also refuse when output and input resolve to the same file (compare dev/inode).

## WARNING ‼️ The reported array unit is a degraded copy, not the exact seed unit
- **Location:** src/arrays.zig:109 (`unit_pos = best.copies[0]`), with src/arrays.zig:106 and :223-229
- **Issue:** `extend` prepends degraded (Hamming-matched) copies on the left, so `copies[0]` is often a mismatched copy. The TSV/JSON `unit` column, `selfSimilarity` and `extendable` then all use that degraded copy instead of the exact unit the run was seeded with. Verified: a planted 26-base DR with the first copy carrying 3 substitutions reports `unit GTATCAGTAGACCGTAATCGTGTCAT` (the mutant), not `GTTTCAGTAGAACGTAATCGTGTCAT`.
- **Detail:** This defeats the planned "repeat consensus accuracy" dimension, and the filter verdicts depend on which copy happens to come first. Fix: keep the seed run's exact copy position (`run.copies[0]`) in `Cand` and use it for `unit_pos`, `selfSimilarity` and the `extendable` reference base. A per-column majority consensus over the copies would be better still. No arrays.zig test covers the unit when the first copy is degraded.

## WARNING ‼️ The default `--max-len` counts N runs as repeats, and large bounds fail with a mislabeled error
- **Location:** src/families.zig:329-340 (`longestNonOverlappingRepeat`), src/main.zig:161, src/finder.zig:38/278/331-333
- **Issue:** `longestNonOverlappingRepeat` treats `N == N` as a match, so a FASTA scaffold gap of k Ns sets the default max length to about k/2. Verified: 300 bases + 2000 N + the same 300 bases searched 993 lengths (8..1000). With a 132 kb N gap, max_len ≈ 66000, which exceeds PCRE2's 65535 quantifier limit. The run ends with `error: MatchFailed`, rc=1, after 7 s. Verified.
- **Detail:** Three separate defects:
  1. N should break the run: `run = if (a == b and a != 'N') ...`. The oracle's `bruteLongestNonOverlappingRepeat` needs the same rule, and the exhaustive test should add N to its alphabet.
  2. `--max-gap` > 65535, `--max-len` > 65535, or `max_gap + (max_len - min_len)` > 65535 fail at `pcre2_compile` with no validation or context. Verified: `--max-gap 70000` and `--max-len 70000` each end with a bare `error: Compile`, rc=1. Validate these bounds in `parseArgs` or `main` and print a message naming the option and the limit.
  3. `ScanChunk.run` (finder.zig:331) and `Pool.work` (finder.zig:213) swallow the real error (Compile, OutOfMemory) and the caller reports `MatchFailed`. Store the first error in the chunk/pool (for example, an `?Error` set with a cmpxchg) and return it.

## WARNING ‼️ `max_gap + (max_len - lo)` overflows
- **Location:** src/finder.zig:278 (also :239)
- **Issue:** `--max-gap 18446744073709551615` panics with `integer overflow` in Debug and ReleaseSafe (verified, rc=134). In ReleaseFast (the package build) it wraps to a small gap, and only the later compile failure stops a wrong candidate set.
- **Detail:** Use `std.math.add` and return a clear error, or cap the options at the PCRE2 limit during parsing (see the previous finding).

## WARNING ‼️ The scoreboard silently hides tool failures and corrupts timing on a non-zero exit
- **Location:** bench/scoreboard:25-39, :57-60
- **Issue:** Each adapter pipes the tool into awk with `2>/dev/null`. The pipeline status is awk's, so a crash (for example dna-repeats `error: MatchFailed`) yields zero predictions for that genome with no warning. It is scored as missed arrays. If any adapter does exit non-zero, GNU time writes `Command exited with non-zero status N` as the first line of `-o`. `read -r s kb` then reads `s=Command`, awk adds 0 to the wall time, and `[ "$kb" -gt "$peak" ]` prints `integer expected`. Verified with the devshell's time 1.10.
- **Detail:** Run each adapter with `set -o pipefail` inside the `bash -c`, keep stderr in `$work`, and fail the scoreboard (or mark that tool's row invalid) on a non-zero status. Parse the time file with `tail -1`.

## WARNING ‼️ score.awk ignores predictions on sequences absent from the truth file
- **Location:** bench/score.awk:84, :92-117
- **Issue:** `accs` is filled only from truth rows, so predictions for any other accession never enter `predictions` or `correct`. Verified: truth has only A, and two Z predictions still give `predictions=1 correct=1`.
- **Detail:** This is latent on the current sets (one record per genome, and every genome has truth rows). The planned negative controls (CRISPR-free and shuffled genomes) and multi-record FASTA (plasmids, contigs) would report inflated precision. Add prediction accessions to `accs` too.

## WARNING ‼️ The scoreboard log omits provenance that the intent requires
- **Location:** bench/scoreboard:48, :68-71; intents/beat_existing_tools.md "Constraints"
- **Issue:** The intent says every claimed win records "tool versions, inputs (by accession and checksum), machine and commit". The ndjson has commit, machine and set, but no tool versions, genome or truth store paths or checksums, and no dirty-tree flag (`git rev-parse --short HEAD` on a modified tree mislabels the run).
- **Detail:** Log the `$genomes`/`$truth`/tool store paths (Nix hashes pin the inputs), each tool's version, and `git status --porcelain` emptiness.

## ADVISORY ⚠️ Plain input computes the O(n²) default bound twice
- **Location:** src/main.zig:150 and :161
- **Issue:** For plain input without `--max-len`, `longestNonOverlappingRepeat` runs once for the summary line and again for the search. PLAN measures it at 0.94 s at 46,400 bases, so this doubles the dominant cost. Verified by reading.
- **Detail:** Compute it once per record and reuse the value. The FASTA summary prints `lengths N..auto` and never reports the per-record bounds actually used. Printing them per record, or after the search, would make the plain and FASTA paths consistent.

## ADVISORY ⚠️ The FASTA "sequence before header" error is unreachable; the CLI test covers the plain path
- **Location:** src/main.zig:122-130, src/normalize.zig:283-286, tests/cli/run:156-159
- **Issue:** FASTA is detected only when the first non-whitespace byte is `>`, so `parseFasta` never sees sequence before a header and `error.MissingHeader` is dead code from the CLI. The test `fasta-sequence-before-header` actually asserts the plain-mode message `invalid byte 0x3e at input offset 5`, which gives a FASTA user no hint of the real problem. Also, ` >x` (a space before `>`) is detected as FASTA, but `parseFasta` requires `>` in column 0 and rejects it as `invalid byte 0x3e at input offset 1`. Verified.
- **Detail:** Either detect FASTA by the presence of a `>` at a line start, or make the plain-mode error say "'>' found: FASTA headers must come first". Keep the detection and parser trims consistent.

## ADVISORY ⚠️ Help text disagrees with the implementation
- **Location:** src/cli.zig:7-31
- **Issue:**
  - `-j` says "default: one per CPU", but main.zig:166 uses 1 thread for records under 16384 bases.
  - `Input:` says anything other than whitespace, `-` or letters is an error. FASTA input and its IUPAC→N rule are not mentioned.
  - The `TSV columns` line describes only plain families mode. FASTA adds a leading record column, and `--arrays` output is `[record,] start, end, copies, unit_length, unit` in 1-based inclusive coordinates. Neither is documented.
  - `--min-copies` and `--min-spacer` are silently ignored without `--arrays`.
  - `--min-len 0` is accepted and the summary prints `lengths 0..` although 1 is the real minimum. `--max-len < --min-len` silently yields nothing.
- **Detail:** Update the usage text, and reject or warn on array-only options and empty length ranges. Parse errors print only `BadNumber` or `MissingValue` without the offending option or value.

## ADVISORY ⚠️ Array merging reports the best candidate's span, not the union the doc promises
- **Location:** src/arrays.zig:39-43, :34, :95-112
- **Issue:** The doc says overlapping runs "collapse into a single region spanning their union", and `unit_len` is "Longest unit among the merged families". The code outputs `best.start/best.end` and selects `best` by most copies first. Any part of a lesser overlapping candidate outside `best` is dropped, and if `best` fails a filter, the whole group is discarded even when another candidate would pass. Verified by reading.
- **Detail:** Either report `[cands[i].start, end)` or correct the doc comments to describe the actual rule.

## ADVISORY ⚠️ Unhandled I/O errors surface as bare error names
- **Location:** src/main.zig:112, :204 and the `try stderr.*` calls
- **Issue:** A stdin read failure prints `error: ReadFailed` (verified with `- < /`). Writing to a closed pipe prints `error: WriteFailed`, rc=1 (verified with `| head -1` on a 2.75 Mb input). File reads, by contrast, get `cannot read PATH: Err`.
- **Detail:** Wrap the stdin read like the file path is wrapped. Treat a broken pipe on stdout as a quiet exit, as Unix filters do.

## ADVISORY ⚠️ FASTA record names are not validated
- **Location:** src/normalize.zig:269-270
- **Issue:** A bare `>` header produces an empty record name, so the TSV gets an empty first column. Duplicate names are accepted, which makes records indistinguishable in output and in score.awk. Verified with two `>` records.
- **Detail:** Warn on empty or duplicate names, or fall back to `record_N`.

## ADVISORY ⚠️ Multi-record progress resets per record while elapsed time is global
- **Location:** src/main.zig:158-170
- **Issue:** `painter.paint(0, lengths)` restarts done/total for every record, but `started` is set once. From the second record on, the ETA (elapsed × remaining / done) mixes earlier records' time into this record's rate.
- **Detail:** Count the total over all records, or reset `started` per record.

## ADVISORY ⚠️ Small leaks on OOM paths
- **Location:** src/finder.zig:124, src/families.zig:77 (oracle)
- **Issue:** `out.append(gpa, .{ .positions = try gpa.dupe(...) })` leaks the dupe when `append` fails. Same pattern in the oracle's `chain_packing` branch with `c`.
- **Detail:** Dupe first with `errdefer gpa.free`, then append.

## ADVISORY ⚠️ `./bm` scaling failure skips the baseline, so the next size can cascade
- **Location:** bm:48-53
- **Issue:** On a ratio failure, `continue` skips `prev_user=$user_ms` and the log append. The next N is compared against the N/4 time, so its ratio is about 4 and it fails too.
- **Detail:** Update `prev_user` (and still log) before `continue`.

---

## Test coverage review (dimensions 2, 3, 4): dna_repeats

Reviewed at HEAD 67cf80f. Another session committed f8d7d2c and 67cf80f while this review ran, so the arrays.zig mutation results below were rerun against f8d7d2c's arrays.zig (unchanged in 67cf80f). The mutation harness ran `zig test arrays.zig` in Debug on a scratch copy. No repository files were modified.

Measured on this machine, `zig build test -Doptimize=Debug --summary all`, full suite, parallel: 2m45s wall, 2m38s user, 1m15s sys. Per binary: finder 2m, cli 21s, arrays 19s, differential 18s, families 10s, normalize 33ms.

## Mutation results for arrays.zig (f8d7d2c)

Killed: the spacer-identity, self-similarity, max_unit, min_copies and min_spacer filters; left and right extension; the extension max_spacer window (+20); extendable-left-only; Coverage overlap and merge; seed ordering; unit_pos from copies[0]; the self-similarity p range; max_unit `>=` changed to `>`.

Survived (every test still passed):
budget+1, budget*2, removal of the seed max_spacer check, extendable returning only `right`, phase-C `best` never updated, phase-C union copy counting disabled (`copies += 0`), start taken from `best`, end taken from `best`, and the equality boundaries of spacer identity (`>`→`>=`), the similar fraction (`<=`→`<`) and self-similarity (`<=`→`<`).

---

### 🔥 CRITICAL: Phase C (merging candidates after extension) has no test that exercises it
- **Location:** src/arrays.zig:91-116 (union copy counting at 101-105, `best` choice at 106, region at 113)
- **Issue:** Disabling union copy counting, freezing `best`, or taking start/end from `best` all survive. No test produces two candidates that overlap after extension. In "a degraded middle copy is bridged", the first seed extends right through all 7 copies and the second seed is skipped by Coverage, so phase C only ever sees one candidate.
- **Detail:** This merge code was just rewritten in f8d7d2c ("union regions") and now decides the copy count and coordinates that the scoreboard scores, yet no test binds it. Add a fixture where two seeds do not overlap but their extensions do. One way: degrade a copy so that one seed's rightward extension stops one copy short while the other seed's leftward extension reaches into it. Assert `copies`, `start`, `end` and `unit_len` exactly. Then confirm that each of the four surviving mutations fails the new test.

### ‼️ WARNING: The mismatch budget boundary is untested
- **Location:** src/arrays.zig:201, :217; test "a copy past max_copy_mismatches is not counted" (:447, `degraded(9)`)
- **Issue:** `<= budget + 1` and even `<= budget * 2` both survive. For the 23-base dr the budget is floor(0.15*23)=3. The tests accept 2 and 3 mismatches and reject 9, so any threshold from 3 to 8 passes.
- **Detail:** Change the reject case to `degraded(4)` (budget+1). The accept side at exactly 3 is already covered by the bridging test. Add a second unit length whose budget has a different floor (e.g. 20 → 3, 27 → 4) so the `@floor` is pinned too.

### ‼️ WARNING: The left-extendability branch of the max_unit filter is untested
- **Location:** src/arrays.zig:268-276 (`extendable`), test at :389
- **Issue:** `return right;` survives. The only cap test builds a repeat that extends on both sides, so the left-flank check is never needed.
- **Detail:** Treat `extendable` as a classifier over its four cases (left only, right only, both, neither) with a hand fixture for each, including copies at offset 0 and at subject end. The specificity side also needs a case: a unit of exactly max_unit that is not extendable must still be called an array.

### ‼️ WARNING: The "identical spacers" test is not bound to the filter it names
- **Location:** src/arrays.zig:343
- **Issue:** Removing the spacer-identity filter alone leaves this test green (only "near-identical spacers" fails). Removing the max_unit filter alone also leaves it green. With identical spacers, unit+spacer forms a longer extendable repeat, so either filter rejects the case.
- **Detail:** The redundancy is fine as defense in depth, but the test does not verify spacer identity. Either rename it, or set `max_unit` to maxInt in this test so that only the spacer filter can reject it. Separately, the `>`/`<=` equality boundaries at :248, :109 and :110 are untested (the mutations survive). Pin each with a fixture that sits exactly on the threshold, e.g. 3 spacers where exactly 1 of 5 pairs is similar gives fraction 0.2.

### ⚠️ ADVISORY: The seed max_spacer check cannot fail under any current caller
- **Location:** src/arrays.zig:55
- **Issue:** Removing `gap > params.max_spacer` survives. Both `callOn` (:305, families built with `max_gap = params.max_spacer`) and main.zig (`max_spacer = cfg.max_gap`) guarantee that no family gap exceeds max_spacer.
- **Detail:** Either document the invariant and drop the check, or have one test build families with a wider gap than `max_spacer` so the branch is exercised.

### ‼️ WARNING: The CLI test "fasta-sequence-before-header" passes for the wrong reason, and the MissingHeader message cannot be reached
- **Location:** tests/cli/run:156; src/main.zig:149-152 (MissingHeader arm)
- **Issue:** main only calls `parseFasta` when the first non-whitespace byte is `>`. `'ACGT\n>x'` is therefore parsed as plain sequence and rejected at the `>` byte with "invalid byte 0x3e". The test asserts that generic message, which locks in the worse diagnostic. The "sequence before the first FASTA header" message can never print: any input main sends to parseFasta starts with a header after whitespace that parseFasta also skips.
- **Detail:** Decide the intended behavior. Either detect a `>` at the start of a line anywhere in the input and report MissingHeader (then assert that message), or delete the dead branch and rename the test.

### ‼️ WARNING: The finder's error paths have no tests, and they crash the CLI
- **Location:** src/finder.zig:38-41 (Compile), :76/:97/:253 (MatchFailed), :193 and :213-216 (Pool.failed), :308 and :331-333 (ScanChunk.failed); src/main.zig:189, :192
- **Issue:** None of these branches runs in any test. They are reachable from the CLI today: `--max-gap 70000` prints `error: Compile` plus a stack trace (rc 1), and `--max-gap 18446744073709551615 --max-len 5` panics with integer overflow at finder.zig:278 (rc 134). The worker pool also turns every worker error into `MatchFailed` (:193, :308), so a Compile failure in a worker gets the wrong name. A test would expose that.
- **Detail:** `candidateStarts(..., max_gap = 70000)` is a failing test available right now, and so is `familiesByLength` with threads 1 and 4. Assert the error value. Add CLI cases for an oversized `--max-gap` / `--max-len` that expect a one-line error and rc 2 (after validation is added; PLAN.md already lists the 65535 bound).

### ‼️ WARNING: The costliest test verifies a code path production never runs
- **Location:** src/finder.zig:525-547 ("finder equals the chain_packing oracle on every small subject"), :338-342 `findFamilies`, :65-82 `Finder.families`
- **Issue:** `Finder.families` and `findFamilies` are used only by tests (checked with rg over src/, bench/, bm). Production uses `candidateStartsParallel` + `familiesAt`. Measured alone, this test adds about 125 s to the build-test wall time; the pruned differential, which covers the production path, adds about 83 s.
- **Detail:** Keep the pruned differential as the oracle check for production. Drop the unpruned differential, or shrink it to a few hand cases while `findFamilies` stays the reference for the parallel test. Alternatively, make the parallel test compare against the oracle directly and delete `findFamilies`.

### ‼️ WARNING: Exhaustive differentials spend their time in the testing allocator's page churn
- **Location:** src/finder.zig:346-359, :371-387, :389-411, :525-547
- **Issue:** Under strace, a 30 s window of the finder test binary made 445,384 `munmap` and 222,708 `mmap` calls. The stack traces point to `DebugAllocator.alloc/free → PageAllocator.map/unmap`: std.testing.allocator maps a fresh 128 KiB bucket page and unmaps it on every alloc/free cycle of the oracle and the Packer. JIT compilation is not the bottleneck. Caching the 12 finders per (len, d) changed nothing (2m28s → 2m22s). Swapping the allocator to `smp_allocator` for that test cut it from about 125 s to about 60 s.
- **Detail:** Give each subject an `ArenaAllocator` over `testing.allocator` (one chunk per subject, with leak checking kept at the arena level). Or run the exhaustive loops with a fast allocator and keep leak detection in the small hand tests. Coverage stays the same and the time drops by at least half.

### ‼️ WARNING: families.zig's tests run five times per `./test`
- **Location:** build.zig:25-81 (arrays, cli, finder and differential modules each `@import("families.zig")` as a file); arrays tests run twice for the same reason (via cli.zig)
- **Issue:** The summary shows 13 families tests inside every binary: 14 = 1+13, 21 = 8+13, 25 = 12+13, 39 = 14+12+13. The families binary alone takes 10 s ("rules only diverge" and the brute-force LNR sweep are exhaustive), so about 40 s of CPU per run repeats work.
- **Detail:** Make families.zig (and arrays.zig) a named module (`b.createModule` + `addImport("families", ...)`) so each file's tests compile into one binary only.

### ‼️ WARNING: differential_test.zig tests a stale pattern
- **Location:** src/differential_test.zig:11-13, :46
- **Issue:** It compiles `(?=(?<unit>[ACGT]{L})(?:(?>[ACGT]{0,D}?...` with a match-time `PCRE2_ANCHORED | ch.option`. Production uses `(*CAPTURE_HISTORY)(?s)` with DOTALL `.` gaps and compile-time anchoring (finder.zig:38). Over the `{A,C}` alphabet the two agree, so the test cannot detect a problem specific to the production pattern (for example N inside gaps). Everything it checks is already covered by the finder differential, which runs the real pattern over `{A,C,N}`. It costs about 18 s of wall time, 10 s of it from the duplicated families tests.
- **Detail:** Delete it, or point it at `Finder.initAnchored` so it checks the real pattern's chain against `fam.chainAt` from every start. That per-start chain comparison is the one unique thing it does.

### ‼️ WARNING: The CLI suite does not assert on everything its header promises
- **Location:** tests/cli/run:3 ("asserts on all three"), with cases throughout
- **Issue:** Most cases never check stderr (short-help, unknown-option, missing-file, stdin-*, path-with-spaces, output-*, json, the fasta-json and every crispr/arrays case). None asserts the arrays summary line ("N arrays in"). Several skip rc or stdout. Missing cases:
  - `--crispr`/`--arrays` on plain (non-FASTA) input: the 5-column record-less TSV path through main.
  - `--arrays` without `--crispr`.
  - `-j N` and `--threads` (output equal to `-j 1`; `-j 0` and `-j` with no value → rc 2 and the error name).
  - JSON across records: `first` is shared across records (main.zig:205, :218), but fasta-json-record-field has families in only one record, so cross-record comma joining is never tested. Assert `jq length` on a two-record input with hits in both, for families and arrays.
  - An empty JSON result (`[\n]`) passing through `jq`.
  - Empty input, a zero-length record (`>a\n>b\nACGT`) and an N-only record.
  - `--min-len` greater than `--max-len`, which is silently accepted and prints "lengths 40..4".
  - MissingValue, BadNumber and ExtraInput through main.
  - `-o` pointing at the input file, which PLAN.md now lists as CRITICAL. No test protects against it.
- **Detail:** Add the cases above and give every case the rc + stdout + stderr triple the header claims. For summaries, match a regex on `$err` as the tsv case already does.

### ⚠️ ADVISORY: `&& pass || fail` chains double-count
- **Location:** tests/cli/run:52-53 (about), :80-83 (tsv), :111-112 (output-later-wins), :127-130 (forced-progress-ascii), :136-137
- **Issue:** When an `expect_*` fails it has already called `fail`, and the trailing `|| fail`/`|| pass` then fires as well. In forced-progress-ascii a failing case prints both FAIL and ok, and `passes` is incremented. The exit code stays correct, but the counts and log lines are wrong.
- **Detail:** Use an `if expect... ; then pass; fi` form, or have each case record one verdict.

### ‼️ WARNING: Byte classifiers assert counts, not membership
- **Location:** src/normalize.zig:112-127, :162-182
- **Issue:** Both tests visit all 256 bytes (good) but compare only bucket totals. A regression that swaps two bytes of the same size class passes, e.g. accepting 'U' while rejecting 'T', or treating 'n' as a base while 'X' becomes ambiguous. The mapped value (uppercase letter, or 'N') is not checked per byte either.
- **Detail:** Build the expected table independently: a literal 256-entry expected output (keep, skip, reject, or map-to-X), generated from the documented set, not the switch. Then assert each byte's class and output. That is the "classifier over sets" rule applied fully.

### ⚠️ ADVISORY: The color/progress truth-table test re-implements the function
- **Location:** src/cli.zig:410-430
- **Issue:** `want_color`/`want_progress` repeat the same `switch` as `resolveColor`/`resolveProgress`, so the test shares any error in the logic. `Tristate.on` for color is also unreachable, since no flag sets it (cli.zig:102-106), which means the test checks a state the program never enters.
- **Detail:** Replace the computed expectation with a literal 12-row table. Either add `--color` or drop `.on` from the color path.

### ⚠️ ADVISORY: Progress renderer branches are untested
- **Location:** src/cli.zig:161-190
- **Issue:** The minute format (`3m07s`), `total == 0`, `done > total` (ETA --), and the narrow-width truncation branch (`bar == 0`, :189) never run. The widths tested (40/60/100) all leave room for the bar.
- **Detail:** Add cases at width 10 and width 0 and at elapsed 187000 ms. Exact assertions still wait on Peter's approval of the rendered look (PLAN.md).

### ⚠️ ADVISORY: Scorer fixtures miss the cases that bias precision
- **Location:** tests/bench/run; bench/score.awk:14-17, :36-40
- **Issue:** No fixture has a prediction on an accession missing from truth. Those predictions are silently dropped (`accs` is filled from truth only), which inflates precision. The review note in PLAN.md confirms this. There are also no fixtures for overlapping truth arrays (overlaps are summed, so one prediction can reach "inside" through double counting) or for coverage of exactly 50%.
- **Detail:** Add a fixture for each case. The first should fail today.

### ⚠️ ADVISORY: The debug banner is never asserted
- **Location:** flake.nix:75 (`MUTE_DEBUG_STATUS=1` for the whole suite); src/main.zig:85
- **Issue:** The CLI suite runs a Debug build with the banner muted and never checks that it appears when the variable is unset.
- **Detail:** Add one case that runs with `env -u MUTE_DEBUG_STATUS` and expects "DEBUG BUILD" on stderr only when the binary under test is a Debug build.

---

## dna_repeats review: dimensions 5, 6, 8, 9 (structure)

Reviewed at c0a468f. Read every tracked source, script and Nix file. Two measurements were taken (noted inline); everything else is from reading.

## Dimension 5: Superfluous or duplicated functionality

### ‼️ WARNING: the default O(n^2) length bound runs twice for plain input
- **Location:** src/main.zig:150 and src/main.zig:161
- **Issue:** When input is plain (not FASTA) and `--max-len` is absent, the stderr banner calls `fam.longestNonOverlappingRepeat(records[0].seq)`, and the record loop then calls it again on the same sequence.
- **Detail:** PLAN.md measures this function at 0.94 s for 46,400 bases (quadratic), against 47 ms for the search itself, so the default path pays that cost twice. Fix: compute `max_len` once per record before the banner (for plain input there is one record), and pass the value to both the banner and the loop.

### ‼️ WARNING: `explore` ships in the release package and all five cross builds
- **Location:** build.zig:10-21 (`b.installArtifact(explore)`); confirmed in `result/bin/` (holds `dna-repeats` and `explore`)
- **Issue:** A dev-only tool for comparing rule semantics is installed next to the product. The `cross` check builds it for all five targets.
- **Detail:** Drop `installArtifact` and keep the `zig build explore` run step. Only the run step needs the artifact.

### ‼️ WARNING: differential_test.zig checks a pattern that production no longer uses
- **Location:** src/differential_test.zig:10-13, 46; src/families.zig:149-162 (`chainAt`, `firstOccurrence`)
- **Issue:** `buildPattern` builds the pattern the fork originally used: no `(*CAPTURE_HISTORY)` verb (history is enabled through `ch.option` at match time), an `[ACGT]` gap class, and match-time `PCRE2_ANCHORED`. `Finder.compile` (finder.zig:38) uses DOTALL `.` gaps, the verb, and compile-time anchoring.
- **Detail:** The finder's own exhaustive oracle tests (finder.zig:389, 525) already cover the production pattern, so this file mainly tests a copy that has drifted. `chainAt` and `firstOccurrence` exist only to serve it. Pick one: (a) make `Finder` expose its pattern builder and have the differential test use it (it would then check per-start chains of the real pattern, which is still useful), or (b) delete the file together with `chainAt`/`firstOccurrence`. The fork's docs already hold the history.

### ‼️ WARNING: the unanchored `Finder.families` / `findFamilies` path exists only for tests
- **Location:** src/finder.zig:22-27, 60-82, 337-342
- **Issue:** `main` only uses `initAnchored` + `familiesAt` (through `familiesByLength`) and `scanStarts` (through `candidateStarts*`). `Finder.families` and `findFamilies` are `pub` but are called only from finder.zig tests.
- **Detail:** They work as a second reference implementation. The exhaustive test at :525 checks that path, and :389 checks the path production actually runs. That is valid, but the public API should say so: make them file-private or document them as test references. The scan loop in `families` (:71-80) is also a near copy of `scanStarts` (:248-257). `families` could call `scanStarts`-style iteration through one shared "next match start" helper.

### ⚠️ ADVISORY: four rejected family rules plus their helpers remain in the oracle module
- **Location:** src/families.zig:8-19, 49-66, 80-90, 164-205; src/explore.zig (whole file)
- **Issue:** Peter picked `chain_packing` on 2026-09-24, and INTENT.md points to the fork's OVERLAP_SEMANTICS.md for the rejected rules. `all_occurrences`, `regex_union`, `maximal_chains`, `greedy_packing`, `pack`, `dedupSorted`, `isChainSuccessor` and `appendSplit` are used only by families.zig tests and explore.zig. explore.zig's "disagree without overlap" count (:62-68) repeats the test at families.zig:297-323.
- **Detail:** This code costs little and records the decision, so keeping it is defensible. If it stays, say in the module doc that only `chain_packing` is live. If it goes, the oracle shrinks to about 60 lines, which is easier to audit as an independent control.

### ⚠️ ADVISORY: `seenEarlier` and `firstOccurrence` are the same loop
- **Location:** src/families.zig:109-115 and 156-162
- **Detail:** `seenEarlier(s, len, p) == (firstOccurrence(s, len, p) != p)`. Keep one.

### ⚠️ ADVISORY: family writers come in record/no-record pairs; array writers take `?[]const u8`
- **Location:** src/cli.zig:223-234 (`writeTsv`/`writeTsvRecord`), 262-274 (`writeJsonFamily`/`writeJsonFamilyRecord`); src/main.zig:198, 200
- **Detail:** `writeArraysTsv`/`writeJsonArray` already take `record: ?[]const u8`. Converting the family writers the same way removes two functions and the `if (is_fasta) ... else ...` branches in main. The "first element gets `\n`, later ones `,\n`" JSON loop is also written twice in main (:182-186, :195-199). One small `JsonList` helper with `first` state would cover both.

### ⚠️ ADVISORY: two identical spawn/run/join scaffolds
- **Location:** src/finder.zig:182-192 and 294-304
- **Detail:** Both allocate `helpers`, keep a `spawned` counter, `defer`-join on error, run slot 0 on the caller, join explicitly, then zero `spawned`. A `runOnThreads(ctx, n, func)` helper would remove the duplication and the subtle `spawned = 0` trick. The hand-rolled pool itself is the approach ZIG_RECENT_API_CHANGES.md §12 recommends over `std.Io.Group`.

### ⚠️ ADVISORY: pipeline stages B and C in arrays.zig are the same interval-grouping loop over two near-identical structs
- **Location:** src/arrays.zig:73-87 vs 95-112; `Run` (:117-126) vs `Cand` (:129-138)
- **Detail:** Both loops sweep sorted intervals, merge overlaps, and pick "most copies, then longest". The two structs differ only in whether `copies` is const, and each has its own `lessByStart`. One `Span` struct (`copies: []const usize`, with ownership tracked by the caller) and one `bestOfOverlapping(items, i) struct { best, next }` helper would halve this code.

### ⚠️ ADVISORY: four copies of the Park-Miller LCG
- **Location:** src/finder.zig:414 (`lcgSubject`), src/arrays.zig:236 (`fillRandom`), bench/gen-corpus:11-24, tests/cli/run:164 (`rnd`)
- **Detail:** The awk and Bash copies are justified: they must produce the same bytes from any awk. The two Zig copies could share a small test-support module, or use `std.Random.DefaultPrng` seeded per test, which is equally deterministic. `arrays.zig` `plant` (:247) is also `plantWith` (:372) with no alternate copy.

### ⚠️ ADVISORY: `bm` and `bench/scoreboard` duplicate the machine-id and ndjson plumbing
- **Location:** bm:27-31, bench/scoreboard:45-49
- **Detail:** The `cpu=`/`machine=`/`commit=`/`when=` lines are identical. A drift in either file would silently split one machine's history across two ids. Move them into one sourced `bench/machine-env` (or a `bench/machine-id` script). score.awk:18 defines `overlap()`, but the recall loop (:30-31) recomputes the same clamp inline.

### ⚠️ ADVISORY: `trf` is packaged but no scoreboard adapter uses it
- **Location:** nix/opponents.nix:42; bench/scoreboard:42
- **Detail:** It is a planned opponent (intent: "Later: Tandem Repeats Finder"), so this is harmless. It should carry a "not yet scored" comment so nobody assumes the scoreboard covers it.

## Dimension 6: Suboptimal, inconcise or disorganized code

### ‼️ WARNING: bench/gen-corpus is quadratic in N
- **Location:** bench/gen-corpus:13-25 (`out = out seg`, `length(out)` on every iteration)
- **Issue:** Measured with gawk 5.4.1: 23,200 bases in 0.26 s user, 46,400 in 1.04 s, 92,800 in 4.36 s (each doubling costs 4x). A run at 742,400 bases did not finish in 115 s.
- **Detail:** `./bm` generates 11,600-92,800 bases, so it pays about 6 s of setup today. The "Scale (gigabases)" scoreboard dimension would make this generator unusable. Fix: keep the running length in a counter, and store bases in an array (or print in 60-column lines as they are produced, keeping only the last ~320 bases for copy-back).

### ‼️ WARNING: worker failures are always reported as `MatchFailed`
- **Location:** src/finder.zig:213-216, 193; src/finder.zig:331-333, 308
- **Issue:** `Pool.work` and `ScanChunk.run` catch any `Error` (including `OutOfMemory` and `Compile`) and set a bool. The caller then returns `error.MatchFailed`.
- **Detail:** An OOM on a large genome would print "MatchFailed", which misleads the user and whoever debugs it. Store the first error (`?Error`, written once through an atomic flag, or one error slot per worker) and return it.

### ‼️ WARNING: `main()` is a 157-line function doing six jobs
- **Location:** src/main.zig:58-215
- **Detail:** It handles argument setup, output-destination selection, input reading, format detection and parsing, banner rendering, the per-record search, two output formats × two modes, and the summary. Pieces that can be pure could move to cli.zig and be unit-tested: the banner (currently only covered by the CLI regex), the `lengths` count (:162, which duplicates `familiesByLength`'s `total` at finder.zig:175), and the "families or arrays for one record" writer. Suggested split in main: `openOutput`, `readInput`, `parseRecords`, `searchRecord`, `writeSummary`. The invalid-byte message is also written twice (:132, :137).

### ⚠️ ADVISORY: the `MissingHeader` branch in main cannot be reached, and the CLI test named after it tests something else
- **Location:** src/main.zig:122-130; tests/cli/run:156-159
- **Detail:** `parseFasta` runs only when the first byte that is not `" \t\r\n"` is `>`. Every line before that is whitespace, and `parseFasta` skips whitespace, so `MissingHeader` can never occur. The `fasta-sequence-before-header` test actually goes through the plain-input path ("invalid byte 0x3e"). Either rename the test to say what it covers (plain input containing `>`), or remove the dead arm from main. The case stays covered in normalize.zig.

### ⚠️ ADVISORY: numeric options are parsed three times and dispatched twice
- **Location:** src/cli.zig:116-138
- **Detail:** Each numeric flag re-runs `eql` to find out which flag it was, after already matching it. A `std.StaticStringMap(Opt)` from flag spellings to an enum, followed by one `switch`, is shorter and gives every flag a single place. The `--crispr` preset values (23, 47, 20, 72) are unnamed and repeat `arrays.Params` defaults (arrays.zig:11-12) and the scoreboard's raw baseline (bench/scoreboard:37). A `pub const crispr_preset` would make one source of truth.

### ⚠️ ADVISORY: dead first loop in an arrays test
- **Location:** src/arrays.zig:302 and 304
- **Detail:** The first `for (1..4)` copy is overwritten by the identical loop two lines later, after `dr` is planted. Delete line 302.

### ⚠️ ADVISORY: build.zig repeats the pcre2 wiring four lines at a time, and one comment sits in the wrong place
- **Location:** build.zig:56-58, 68-70, 88-90; the comment at :34
- **Detail:** `addImport("pcre2_c")`, `addImport("pcre2_capture_history")` and `linkLibrary` appear three times. A `withPcre2(mod)` helper would remove that. The "Differential test against the fork's real matcher" comment sits above the shared dependency setup, not above the differential module. The version is written as "0.1.0" in build.zig:96 and twice in flake.nix (:16, :38), and as "0.0.0" in build.zig.zon:3. Read it from one place: `@import("build.zig.zon").version` works in 0.16 build scripts.

## Dimension 8: Files without clear purpose, and stale notes or comments

### ‼️ WARNING: user-facing help describes behavior that has changed
- **Location:** src/cli.zig:10, 16, 20, 30
- **Detail:**
  - "anything else is an error" omits FASTA and the IUPAC-to-N rule.
  - `--arrays ... distinct spacers` is stale: one duplicated spacer is allowed now, and degraded copies are extended.
  - `-j` says "default: one per CPU", but auto stays single-threaded under 16K bases (main.zig:166).
  - The TSV column line leaves out the FASTA record column and the array layout (1-based start, end, copies, unit length, unit).

  This is the text the biotech users in the intent will read.

### ⚠️ ADVISORY: stale doc comments
- src/arrays.zig:39-44: `callArrays` says "pairwise-distinct spacers". The filters are now the similar-pair fraction, unit self-similarity, extendability at the length cap, and seed-and-extend. Its complexity line leaves out `extend`.
- src/arrays.zig:320: `put` says "Copy `n` bases starting at `from` in `src`", but the parameters are `(buf, at, bases)`.
- src/arrays.zig:402: the test name uses `max_copy_mismatches`, but the field is `max_copy_mismatch_fraction`.
- src/finder.zig:22-24: `Finder.init` says "for an unanchored scan (`families`)", but `scanStarts` is its production user.
- src/finder.zig:1, src/families.zig:9-11 and 280, src/normalize.zig:1, src/differential_test.zig:10: these cite "handoff section N", a document that stayed in the pcre2 fork. Either link `docs/capture_history/...` in the fork by commit or drop the references.
- bench/scoreboard:35: "Naive baseline ... (step 3 replaces this)". Step 3 is done, and the baseline still runs by default (:42). Say it is kept as a reference row, or drop it from the default tool list.

### ⚠️ ADVISORY: stale dirtree notes
- `src/main.zig`: "calls finder per length". It now runs a candidate scan, the length pool and the array caller.
- `src/arrays.zig`: "distinct spacers". Stale for the same reason as the doc comment above.
- `nix/benchdata.nix`: "8 CRISPR genomes". It also pins the 30 held-out genomes and their truth.
- `test`: "Runs all Zig tests and the release build". It also runs the `cli` check (CLI suite and score.awk fixtures) and the `cross` check.
- `build.zig`: lists "oracle, normalizer, finder, CLI and differential tests". It omits arrays and the `explore` executable.
- `bench`: mentions only gen-corpus and ndjson, not scoreboard/score.awk. No notes for `docs/PLAN_LOG.md`, `tests/bench`, `bench/scoreboard-*.ndjson` or `.dirtree-state`.

### ⚠️ ADVISORY: docs/PLAN_LOG.md is an empty log while PLAN.md holds about 17 checked items
- **Location:** docs/PLAN_LOG.md (header only); PLAN.md:9-40
- **Detail:** PLAN.md's first line says completed items retire to PLAN_LOG.md, but none have. The file currently serves no purpose. Run the planning-work retirement scripts or delete the promise.

### ⚠️ ADVISORY: the tracked `ZIG_RECENT_API_CHANGES.md` symlink points outside the repo
- **Location:** ZIG_RECENT_API_CHANGES.md -> `../Obsidian Vaults/Peter Marreck/...`
- **Detail:** It resolves only inside Peter's `~/Code`, so it is a dangling file for any other clone, including the one Mechatron CI would use. The same applies to `AGENTS.md -> ../AGENTS.md`, which the brief allows. Consider leaving it untracked, the way `/inbox/` is.

### ⚠️ ADVISORY: the `cli` Nix check also runs the scorer tests
- **Location:** flake.nix:71-78
- **Detail:** `tests/bench/run` has nothing to do with the CLI. Split it into a `scorer` check, or rename the check (e.g. `scripts`), so a failure's name points at the right suite.

## Dimension 9: Not using language features

### ⚠️ ADVISORY: Nix binds `nixpkgs.legacyPackages.${system}` seven times
- **Location:** flake.nix:12, 62, 63, 72, 73, 81, 82
- **Detail:** Add `pkgsFor = system: nixpkgs.legacyPackages.${system};` (or `forSystems (system: let pkgs = ...; in ...)`) once. `zigDeps` is also defined inside `package system mode`, so each of the four modes re-evaluates an identical derivation. Nix deduplicates by hash, so this costs nothing at runtime. Lifting it to per-system makes clear that there is only one fetch, and hence one hash to update when the fork is repinned.

### ⚠️ ADVISORY: counter `while` loops where ranged `for` fits
- **Location:** e.g. finder.zig:374-375, 394, 403-406, 457-458, 539-542; families.zig:302-309; explore.zig:42-54; main.zig:190-191; arrays.zig:163-164
- **Detail:** `for (min_len..max_len + 1) |len|` removes a mutable counter and the off-by-one surface. `arrays.extend` builds the left side by walking `left` backwards into `all`. Appending, then `std.mem.reverse` on the prefix (or `insertSlice(0, ...)`), says what it means. The exhaustive enumeration triple-loop (alphabet^n × len × d) appears in finder.zig twice, families.zig once and explore.zig once. A comptime-parameterized `forEachSubject(alphabet, max_n, ctx, fn)` test helper would remove about 40 lines.

### ⚠️ ADVISORY: positions are `usize` everywhere
- **Location:** families.zig:24 (`positions: []usize`), finder.zig candidate starts, arrays.zig
- **Detail:** Positions within a record never exceed a single chromosome (under 2^32). `u32` halves the memory of the candidate-start array and of every family. That matters for the "Scale: gigabases" and "peak memory" scoreboard dimensions (currently 46 MB). This is a design choice for later, not a defect now.

### ⚠️ ADVISORY: a fixed-capacity array in a test helper can overflow
- **Location:** src/families.zig:231 (`var mine: [16][]const usize`)
- **Detail:** More than 16 families of one unit gives an out-of-bounds write: a panic in Debug, undefined behavior in release test builds. Use an `ArrayList` or `testing.allocator`. The same pattern appears in differential_test.zig:47 (`engine: [16]usize`), which is safe only because n ≤ 9.
