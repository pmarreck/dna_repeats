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

## Results

- 2026-09-28, preset frozen at commit 714484a (every value from the paper's methods, none
  fitted): tuning set 3 of 3 arrays found upstream of the RT (MarsHill 5 copies, SA1 3
  copies where the paper shows 5, Madawaska 5 copies).
- Held-out set, scored once: 4 of 5 by the rule fixed beforehand. LY01, S6, PALS_2 and
  UFV_DC4 each have a 5-copy array upstream of the RT (RT located by tblastn with the
  MarsHill RT). LPJP1 has none: no exact repeat of 10 or more bases recurs three times at
  array spacing in the 6 kb upstream of its RT. The paper does not report an array for
  LPJP1 (it names arrays only for the seven Staphylococcus phages, and only 28 of its 95
  ART RT clusters carry one), so including it was our assumption; among loci where the
  paper reports an array, 4 of 4. Generalization beyond the Staphylococcus clade is untested.
- MGV census (189,680 human-gut viral genomes, 8.8 GB; 5.5 min on 64 workers): 26,418
  arrays under --art, 7,240 non-coding, 2,013 upstream of a Pfam RVT_1 RT; 142 both
  (coding fraction < 0.5, upstream), in 14 repeat families, none similar to a known ART
  repeat. Families 1, 2, 3, 5, 6, 7 overlap DGR template or variable repeats wherever MGV
  annotates a DGR (likely DGR-associated). Family 4: 15 arrays in 13 vOTUs of Prevotella
  phages, repeat CAATTATCGTACTGC (4-6 copies, period ~210 nt), 3-6 kb upstream of one RT
  lineage (91-100% identical, 422 aa, domain from residue 64); not ART (no homology to the
  MarsHill RT, normal N-terminus), not the annotated DGR RT; partly overlaps genes (0.37-0.46).
  Co-occurrence may be shared ancestry; RT class not yet assigned (next: myRT references).
- Family 4 RT class (myRT RVT-All.hmm, mgtools/myRT fa8e362): UG27 (E ~ 1e-115) for all 15;
  control: the MarsHill ART RT scores closest to retrons (E 1.1e-33), as the paper places it.
  UG27 RTs in Bacteroidetes/Firmicutes gut viruses with an associated ncRNA are described in
  Mestre et al. 2022 (NAR 50:6084), and arrays of ncRNAs in UG27 systems in a bioRxiv
  preprint of 2026-09-22 ("Coevolutionary mining of prokaryotic non-coding elements with a
  genome language model"). Family 4 is therefore a rediscovery by the array-first census,
  not a new system.
- MGV rerun with myRT classes: the 142 non-coding arrays upstream of an RT are 124 DGR, 16 UG27,
  2 group II intron; none retron-like (ART). No new ART members in human gut viruses (MGV).
- All 7,240 non-coding MGV arrays cluster into 451 families, but single linkage chains short
  repeats: the largest "family" (3,898 arrays, 1,071 vOTUs; a near-perfect inverted repeat) is
  a chaining artifact until art-cluster compares members with a centroid. Smaller families
  recur across many vOTUs with no RT (e.g. 301 arrays in 58 vOTUs, 37-nt repeat, period ~150);
  they need screening against known element classes (terminators, REP/BIME-like, Rfam) before
  any is called new.
- art-cluster now uses greedy centroid clustering (commit 10e8c91): MGV's 7,240 non-coding
  arrays form 834 families, the largest 585 arrays in 28 vOTUs; the 3,898-array chain is gone.
- Known-element screen (bench/art-screen, commit 24e2ffe): each family's representative array
  against Rfam 15.0 (Infernal 1.1.5 cmscan, gathering thresholds), ARAGORN tRNA/tmRNA, and
  dna-repeats --crispr. Of 834 families: 38 known RNA (mostly tRNA arrays, e.g. 392 arrays in
  116 vOTUs), 67 CRISPR (MinCED 0.4.2 agrees on 59 of the 69 it and we flag), 729 unexplained.
  The ART preset sees CRISPR arrays at double period: copies ~67 nt apart violate the 60-nt
  minimum spacer, so it chains every second repeat. The earlier "301 arrays in 58 vOTUs, 37-nt
  repeat" family is such a phage-encoded CRISPR array (36-nt repeat, 29-30-nt spacers).
  Unexplained families spread over at most 34 vOTUs; the top ones (e.g. GTGTGTCCAATTATT, 42
  arrays in 34 vOTUs) are candidates, not findings, until their gene context is checked.
- INPHARED 14Apr2025 census (34,062 phage genomes, 2.1 Gb; 2 min on 64 workers): 9,274
  arrays, 2,389 non-coding. The retron-class (ART-like) arrays upstream of an RT are exactly the
  paper's 7 Staphylococcus phage loci plus our LPJP1 locus (MZ422438:181312-181985); no other
  phage in INPHARED carries one. Also 1 non-coding array upstream of a UG2-class RT (CP103976).
  Array-first search over all isolated phages recovers the paper's RT-first result with no
  additional retron-class hits.
- Shuffled control (commit 0f17fa9 fixed two census bugs it exposed): a 10% MGV sample (18,968
  records, every 10th) gives 2,633 arrays and 234 RT-upstream; the same records shuffled
  (mononucleotide, per-record seeds) give 3 arrays, all minimal (3 copies of 15-nt AT-rich
  units), and 0 RT-upstream.
- GPD census (Gut Phage Database, 142,809 genomes; 5 min on 64 workers): 15,291 arrays, 4,249
  non-coding, 587 upstream of an RT: 549 DGR, 30 UG27, 5 retron-class, 1 GII-I, 1 GII-II, 1 UG12.
  No non-coding retron-class (ART-like) array. The 5 retron-class arrays are 2-5 kb upstream and
  54-94% inside predicted genes. One lead: uvig_591988 and uvig_579515 share a 27-nt repeat with a
  near-palindromic core (TGAGCCTTTTAACGTCATGCTCAGGAC, 4 copies, ~5 kb upstream, coding 0.59);
  unverified (the coding call may be Prodigal over-calling), not a finding.
- Dinucleotide control (bench/shuffle-fasta-di, commit b7b879a): the same 10% MGV sample with
  every record shuffled preserving exact dinucleotide counts gives 8 arrays (vs 2,633 real, 3
  mononucleotide-shuffled), all 15-16-nt low-complexity units with 3-4 copies, and 0
  RT-upstream: about 0.3% of the sample's array calls are expected under this null.
