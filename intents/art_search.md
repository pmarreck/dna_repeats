# Direction: array-first search for ART-like repeat arrays

Status: accepted (Peter, 2026-09-28). Relation to INTENT.md: a second opponent task for
the scoreboard, after CRISPR finders; same evidence discipline.

## Background

Anthropic's preprint "Autonomous AI agents discover reverse transcriptases with tandem
repeat arrays" (Yoon et al., 2026; announced 2026-09-23) reports array-associated
reverse transcriptases (ART) in jumbo phages: an RT with a long N-terminus, a partner gene
downstream, and upstream a non-coding array of 3 to 21 copies of a 15 to 49 nt repeat
(palindromic core of about 15 nt, less conserved edges) separated by 120 to 220 nt
spacers, spanning 0.3 to 4.1 kb. Their search was RT-first: about 950 agents over 21 hours
and 210 million tokens surveyed RT loci across 1.9 billion protein clusters (Logan, ENA,
JGI, NCBI), giving 95 ART RT clusters, 28 with a detected array. Arrays were only looked
for upstream of RTs.

## Outcomes (Peter chose "both")

1. Reproduce and extend: an array-first scan of public phage genomes recovers the paper's
   GenBank ART arrays and reports further ART-like arrays next to RTs, with the time and
   cost of the scan.
2. Census: every array with the ART architecture, whatever gene lies beside it, with
   repeats clustered by sequence similarity (both strands) to find repeats that are the
   same as or similar to the ART repeats, and new families of related repeats
   (Peter, 2026-09-28: "it would be fascinating if we found more interesting repeats of
   either the same sequences or similar").

## Scope and constraints

- Data: public phage genomes (GenBank, via the INPHARED collection), public metagenomic
  viral catalogs that need no login (Gut Phage Database, MGV), and IMG/VR v4.1 once Peter
  has JGI access. Pinned by hash; not committed.
- Tools: dna-repeats finds arrays; prodigal (gene calls) and HMMER (RT profile) link arrays
  to RTs (Peter approved, 2026-09-28).
- Claims stay computational: "candidates", never "discoveries". There is no lab work.
  Coverage of our data differs from theirs, so comparisons are stated per data set.

## How success is verified

- Known ART loci in GenBank phages (paper, Methods): SA1 MW218148.1, MarsHill MW248466.1,
  Madawaska MW349129.1, LY01 OR836606.1, S6 LC680885.1, PALS_2 MN091626.1,
  UFV_DC4 MZ779063.1, and Listeria phage LPJP1 MZ422438.1.
- Split fixed on 2026-09-28 09:35 EDT before any tuning: tuning set MarsHill, SA1,
  Madawaska; held-out set LY01, S6, PALS_2, UFV_DC4, LPJP1. The held-out set is scored once
  with the preset frozen.
- An array counts as recovered when it lies upstream of the annotated RT within 6 kb, as
  in the paper's delimitation window.
- Negative control: shuffled phage genomes give no arrays.
