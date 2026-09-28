# dna-repeats

Fast, accurate detection of CRISPR arrays and other gap-separated DNA repeats.

On 30 bacterial and archaeal genomes held out from all development, dna-repeats found
more of the curated CRISPR arrays than [MinCED](https://github.com/ctSkennerton/minced)
and [PILER-CR](https://www.drive5.com/pilercr/), reported fewer false ones, got the
repeat sequence exactly right more often, and did it 3.6 to 5.9 times faster on one core
while using 1.7 to 35 times less memory. Neither MinCED nor PILER-CR can use more than one
thread; dna-repeats uses every core by default and scans those 30 genomes in about half a
second, 27 to 44 times faster than either.

![Held-out set #3: recall, precision, exact repeat sequence, time on one core and peak memory for dna-repeats, MinCED and PILER-CR](docs/img/heldout3.svg)

| Held-out set #3 | Recall | Precision | Exact repeat | Time | Peak memory |
|---|---|---|---|---|---|
| **dna-repeats**, one thread | **68/73** | **95.9%** | **83.3%** | **4.15 s** | **14.0 MB** |
| **dna-repeats**, 128 threads (default) | **68/73** | **95.9%** | **83.3%** | **0.56 s** | **11.0 MB** |
| MinCED 0.4.2 (single-threaded) | 67/73 | 94.4% | 76.1% | 15.07 s | 488.2 MB |
| PILER-CR 1.06 (single-threaded) | 63/73 | 94.7% | 73.2% | 24.61 s | 24.3 MB |

Times are wall-clock for all 30 genomes on a 64-core AMD Threadripper 3990X (128 hardware
threads). Results are identical at every thread count. More threads stop paying off past
about 48 here: a thread sweep measured 4.19 s at 1, 616 ms at 16, 511 ms at 48 and 589 ms
at 128 (hyperfine, 5 runs each), so `-j 48` is the fastest setting on this machine.

Arrays in old or decaying CRISPR loci carry mutated repeat copies. On synthetic arrays
whose every repeat copy was mutated at a fixed rate, dna-repeats finds as many as or more
than either tool at every rate up to 10% (MinCED does better at 12%):

![Planted arrays found out of 20 as each repeat copy is mutated, for dna-repeats, dna-repeats --sensitive, MinCED and PILER-CR](docs/img/divergence.svg)

The full write-up, with every scored set, methods and limits, is in the
[findings report](https://claude.ai/artifact/YDA9CSb9S3wHVikR2ge4Te).

## Quick start

With [Nix](https://nixos.org/download) (flakes enabled), no install needed:

```sh
nix run github:pmarreck/dna_repeats -- --crispr genome.fa
```

To build from a clone (the binary lands in `result/bin/dna-repeats`):

```sh
git clone https://github.com/pmarreck/dna_repeats && cd dna_repeats
./build
```

## Usage

Find CRISPR arrays in a genome (FASTA, one or many records, or plain sequence):

```sh
dna-repeats --crispr genome.fa
```

```
U00096.3	2877701	2878463	13	29	CGGTTTATCCCCGCTGGCGCGGGGAACTC	2877701,2877762,...
U00096.3	2904014	2904407	7	28	GGTTTATCCCCGCTGGCGCGGGGAACAC	2904014,2904075,...
```

Columns: record, start and end (1-based, inclusive), copies, repeat length, consensus
repeat, and the start of every copy. That is *E. coli* K-12's two CRISPR arrays, found in
15 ms using all cores (138 ms on one). A summary goes to stderr, so stdout stays clean for pipes.

| Task | Command |
|---|---|
| Find more degraded arrays (seeds from 14 bases; a few more false ones) | `dna-repeats --crispr --sensitive genome.fa` |
| JSON output | `dna-repeats --crispr --json genome.fa` |
| Write to a file (written atomically; never overwrites the input) | `dna-repeats --crispr -o arrays.tsv genome.fa` |
| Read stdin | `zcat genome.fa.gz \| dna-repeats --crispr -` |
| One thread, or a fixed number | `dna-repeats --crispr -j 1 genome.fa` |
| Every repeat family, not just arrays | `dna-repeats --min-len 12 --max-len 30 --max-gap 300 seq.fa` |

Family output lists length, copy count, the repeated unit and its 0-based start offsets.
Ambiguity codes (N, R, Y, ...) are kept as N and never match. Run `dna-repeats --help`
for every option.

## Confirm the findings yourself

One command downloads the pinned genomes and CRISPRCasdb, runs all three tools and checks
the results:

```sh
git clone https://github.com/pmarreck/dna_repeats && cd dna_repeats
bench/verify
```

```
One thread on held-out #3: dna-repeats 4.11 s, 13 MB; 3.6x faster than MinCED, 5.8x faster than PILER-CR; ...
All 128 CPUs: dna-repeats 0.54 s, 27x faster than MinCED, 44x faster than PILER-CR.
VERIFIED: 23 of 23 expected results reproduced exactly.
```

It reruns held-out set #3, a negative control (the development genomes with their bases
shuffled, where every reported array is false; all tools report none) and the divergence
sweep, and compares every recall, prediction count and repeat match with
[`bench/expected.tsv`](bench/expected.tsv). Times depend on your machine and are
reported, not checked. MinCED and PILER-CR are built from source at their published
versions; the genomes are fetched from NCBI and pinned by hash in
[`nix/benchdata.nix`](nix/benchdata.nix).

For other sets and tools, `bench/scoreboard --set dev|heldout2|heldout3|shuffled`
prints the table and logs every run with its commit, tool paths and an input checksum.

### How the test genomes were chosen

Ground truth is [CRISPRCasdb](https://crisprcas.i2bc.paris-saclay.fr/) (release
2022-04-14), arrays at its highest evidence level (4). The held-out rule was written down
before any held-out result existed: every CRISPRCasdb sequence with a level-4 array,
development genomes excluded, ordered by the SHA-256 of its accession, 30 at a time.
Tuning happened only on 8 development genomes. Held-out #1 was later used to diagnose a
bug, so it counts as development data; held-out #2 and #3 were each scored once with the
code frozen. The rule and history are in
[`intents/beat_existing_tools.md`](intents/beat_existing_tools.md).

A curated array counts as found when predictions cover at least half its bases; a
prediction counts as correct when at least half of it lies inside any CRISPRCasdb array.

## How it works

1. **Where can a repeat start?** A pure-Zig prefilter packs every 18-base window
   (14 with `--sensitive`) into 2 bits per base and finds the few positions whose window
   occurs again within the allowed gap. On *E. coli* that is 2,548 of 4.6 million.
2. **Which repeats are there?** For each repeat length, one PCRE2 regular expression
   collects every copy of a repeat at those positions in a single match. Standard PCRE2
   reports only the last capture of a repeated group; this project uses a
   [PCRE2 fork](https://github.com/pmarreck/pcre2/tree/capture-history) with capture
   history, which returns all of them.
3. **Which repeats form CRISPR arrays?** Runs of exact copies within CRISPR spacer bounds
   become seeds; each extends through copies with up to 15% mismatches. The repeat grows to
   the columns most copies agree on, and the consensus is used to extend again. Filters
   reject tandem repeats, spacers that share sequence, internally periodic units and
   poorly conserved copies.

On one thread on *E. coli*, step 1 takes 71% of the time, step 2 28% and step 3 1%. The
prefilter used to be a second regular expression and took 98%; the Zig version gives
exactly the same positions (checked against the regex on every short input and on real
genomes) 12.7 times faster.

## Limits

- CRISPRCasdb's arrays come from CRISPRCasFinder, so the scores measure agreement with that
  curation, including its boundary conventions. Some "false" predictions may be real arrays
  the database lacks.
- MinCED and PILER-CR ran with their default settings. Each held-out set has 30 genomes, so
  differences of one or two arrays could reverse on another sample.
- Repeat copies with insertions or deletions are not handled yet, and an array is found only
  if neighboring copies share an exact run of 18 bases (14 with `--sensitive`). CRISPRCasFinder and CRT have not been compared.

## Development

```sh
./test     # unit tests in Zig Debug mode, CLI tests, benchmark-script tests, cross builds
./bm       # scaling, speed and memory gates (ReleaseFast)
```

## Who built this

[Peter Marreck](https://github.com/pmarreck) designed and directed this project and wrote
it with Claude Opus 5.5 (Anthropic) as a pair programmer. It began the day after Anthropic
published [Claude discovers a novel enzyme
system](https://www.anthropic.com/news/claude-discovers-novel-enzyme-system) (23 September
2026), in which Claude found array-associated reverse transcriptases: phage systems that
carry "a long array of evenly spaced DNA repeat sequences reminiscent of CRISPR arrays". That
search pointed Claude directly at the data, with roughly 950 agents working for 21 hours and
210 million tokens, and human involvement "limited to the initial prompt and the lab work".

Peter took the opposite approach: steer Claude to build a better tool first, with the data in
mind, and only then point the tool at the data. The result detects exactly this kind of
structure, arrays of evenly spaced repeats, in about 0.14 seconds per bacterial genome on
one core, and anyone can rerun and check it. Peter's contributions shaped the results:

- **The core idea.** Peter added a capture-history feature to
  [his fork of PCRE2](https://github.com/pmarreck/pcre2/tree/capture-history), so one match
  of a repeated group returns every capture instead of only the last, and proposed using a
  single such regular expression to find all copies of a repeat at once. That is still how
  dna-repeats finds repeat families.
- **The search design.** Scan each repeat length in turn, from long to short, with a
  bounded gap between copies so run time stays predictable, keeping shorter repeats nested
  inside longer ones as their own results.
- **The goal and the yardstick.** Peter set out to beat the existing tools, chose CRISPR
  finders as the first opponents and CRISPRCasdb's highest-evidence arrays as ground truth,
  and defined the win as a point on a multidimensional chart (recall, precision, speed,
  memory and tolerance of divergent copies) rather than one headline number.
- **The pure-Zig speedup.** Peter predicted that code written specifically for DNA could
  beat the regex engine and asked for 2-bit base packing to be explored. The 2-bit k-mer
  prefilter that came out of it made the single-threaded run 12.7 times faster.
- **The multicore numbers.** Peter asked for results on one core and on all of them, guessed
  that fewer than all 128 threads might be faster (48 was, by 15%), and asked whether the
  competing tools run multithreaded (neither does).
- **Engineering discipline.** Test-driven development throughout, correctness checked in
  Zig's Debug mode and benchmarks run only in its fastest mode, attention to memory use, a
  `--sensitive` mode for degraded arrays, and a single command anyone can run to confirm
  the findings.

## License

[MIT](LICENSE), copyright 2026 Peter Marreck.
