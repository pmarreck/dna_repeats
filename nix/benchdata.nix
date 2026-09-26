# Public scoreboard inputs, pinned by hash (intents/beat_existing_tools.md).
# Nothing here is committed as data: Nix fetches and derives it on demand.
{ pkgs }:
let
	# GenBank nucleotide accessions of well-studied CRISPR genomes, with FASTA hashes.
	genomeHashes = {
		"U00096.3" = "sha256-KKcWfYurYFcM1uPdrN3nXVxR22DhAJ+4wkHx2kRrYVI="; # E. coli K-12 MG1655
		"AE009950.1" = "sha256-nWBJaMyhCpUPV23OiMX7+lHrua6scmmVHa+SsqfXenc="; # Pyrococcus furiosus DSM 3638
		"AE006641.1" = "sha256-+PSPPlnHz097R2UiC/BPN4txDPpRQwLZbqNxz5qXuOY="; # Sulfolobus solfataricus P2
		"AL123456.3" = "sha256-eBuKliKIny9SU7wjy8sDeDFD2Pby+hTONChwcGr4eHM="; # M. tuberculosis H37Rv
		"AP008226.1" = "sha256-XENvQ4JtnATbmLrmluq/wJKQU9BxxNG+nlEZrWeaH9A="; # Thermus thermophilus HB8
		"CP000438.1" = "sha256-X3AaOmPeWoEnyLXr1z3Ri1FdUN11LxgMMb+9co23594="; # P. aeruginosa UCBPP-PA14
		"CP001956.1" = "sha256-ydy8YFbb51MfBx7PHpbT4PN5bQeFC+AfNOwgFdSOkVM="; # Haloferax volcanii DS2
		"CP000024.1" = "sha256-LU1AQMOtCdGBS4xPbdDMfHFcaB+6xoSR/T3ZI+F0P+k="; # S. thermophilus CNRZ1066
	};
	fetchGenome = acc: hash: pkgs.fetchurl {
		name = "${acc}.fa";
		url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${acc}&rettype=fasta&retmode=text";
		inherit hash;
	};
	# CRISPRCasdb full dump (PostgreSQL SQL, release of 2022-04-14).
	crisprcasdbDump = pkgs.fetchurl {
		name = "ccpp_db.zip";
		url = "https://crisprcas.i2bc.paris-saclay.fr/Home/DownloadFile?filename=ccpp_db.zip";
		hash = "sha256-+F8LFZyi2D78NvUuENZJtUNR5DHFeQqGETmkEcK4dQA=";
	};
in rec {
	genomes = pkgs.linkFarm "scoreboard-genomes"
		(pkgs.lib.mapAttrsToList (acc: hash: { name = "${acc}.fa"; path = fetchGenome acc hash; }) genomeHashes);

	# Ground truth, one CRISPR array per line for the genomes above:
	# accession, organism, start (as stored), length, orientation, evidence level, DR consensus.
	crisprTruth = pkgs.runCommand "crisprcasdb-truth.tsv" { nativeBuildInputs = [ pkgs.unzip pkgs.gawk ]; } ''
		unzip -p ${crisprcasdbDump} > dump.sql
		awk '/^COPY public\.(crisprlocus|sequence|strain|entity|region) / { split($2, a, "."); f = a[2] ".tsv"; on = 1; next }
			on && /^\\\.$/ { on = 0; close(f); next }
			on { print > f }' dump.sql
		awk -F'\t' -v want="${pkgs.lib.concatStringsSep " " (builtins.attrNames genomeHashes)}" '
			BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
			FNR == 1 { f++ }
			f == 1 && $4 == "Sequence" { acc[$1] = $5 }
			f == 1 && $4 == "Strain" { name[$1] = $5 }
			f == 2 { strain[$1] = $2 }
			f == 3 { dr[$1] = $2 }
			f == 4 && keep[acc[$2]] { print acc[$2] "\t" name[strain[$2]] "\t" $3 "\t" $4 "\t" $5 "\t" $7 "\t" dr[$8] }
		' entity.tsv sequence.tsv region.tsv crisprlocus.tsv | sort -k1,1 -k3,3n > $out
	'';
}
