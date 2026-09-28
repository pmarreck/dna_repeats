# dna-repeats

Fast, accurate detection of CRISPR arrays and other gap-separated DNA repeats.

On 30 bacterial and archaeal genomes held out from all development, dna-repeats found
more of the curated CRISPR arrays than [MinCED](https://github.com/ctSkennerton/minced)
and [PILER-CR](https://www.drive5.com/pilercr/), reported fewer false ones, got the
repeat sequence exactly right more often, and did it 3.6 to 5.9 times faster on one core
while using 1.7 to 33 times less memory. With all cores it scans those 30 genomes in about
half a second.

![Held-out set #3: recall, precision, exact repeat sequence, time on one core and peak memory for dna-repeats, MinCED and PILER-CR](docs/img/heldout3.svg)

| Held-out set #3, one thread | Recall | Precision | Exact repeat | Time | Peak memory |
|---|---|---|---|---|---|
| **dna-repeats** | **68/73** | **95.9%** | **83.3%** | **4.13 s** | **14.0 MB** |
| MinCED 0.4.2 | 67/73 | 94.4% | 76.1% | 14.74 s | 461.2 MB |
| PILER-CR 1.06 | 63/73 | 94.7% | 73.2% | 24.23 s | 24.0 MB |

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
One thread on held-out #3: dna-repeats 4.12 s, 14 MB; 3.7x faster than MinCED, 5.7x faster than PILER-CR; ...
VERIFIED: 22 of 22 expected results reproduced exactly.
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

Built by Peter Marreck with Claude (Anthropic).
