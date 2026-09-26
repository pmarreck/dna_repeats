# Public scoreboard inputs, pinned by hash (intents/beat_existing_tools.md).
# Nothing here is committed as data: Nix fetches and derives it on demand.
{ pkgs }:
let
	# Development genomes: filters and thresholds are tuned on these only.
	devHashes = {
		"U00096.3" = "sha256-KKcWfYurYFcM1uPdrN3nXVxR22DhAJ+4wkHx2kRrYVI="; # E. coli K-12 MG1655
		"AE009950.1" = "sha256-nWBJaMyhCpUPV23OiMX7+lHrua6scmmVHa+SsqfXenc="; # Pyrococcus furiosus DSM 3638
		"AE006641.1" = "sha256-+PSPPlnHz097R2UiC/BPN4txDPpRQwLZbqNxz5qXuOY="; # Sulfolobus solfataricus P2
		"AL123456.3" = "sha256-eBuKliKIny9SU7wjy8sDeDFD2Pby+hTONChwcGr4eHM="; # M. tuberculosis H37Rv
		"AP008226.1" = "sha256-XENvQ4JtnATbmLrmluq/wJKQU9BxxNG+nlEZrWeaH9A="; # Thermus thermophilus HB8
		"CP000438.1" = "sha256-X3AaOmPeWoEnyLXr1z3Ri1FdUN11LxgMMb+9co23594="; # P. aeruginosa UCBPP-PA14
		"CP001956.1" = "sha256-ydy8YFbb51MfBx7PHpbT4PN5bQeFC+AfNOwgFdSOkVM="; # Haloferax volcanii DS2
		"CP000024.1" = "sha256-LU1AQMOtCdGBS4xPbdDMfHFcaB+6xoSR/T3ZI+F0P+k="; # S. thermophilus CNRZ1066
	};
	# Held-out genomes (rule in intents/beat_existing_tools.md): CRISPRCasdb sequences with
	# an evidence-level-4 array, dev accessions excluded, first 30 by SHA-256 of the accession.
	heldoutHashes = {
		"CM001015.1" = "sha256-l1rnQcr6y1AnmkxJ9rffP17dr3QZQVo1FOJ9n4A16eg=";
		"CP029946.1" = "sha256-jF/VBkAak6G1tE+00T5rbDqNWGUSXbMYnHaekjaUe0E=";
		"CP065999.1" = "sha256-NU5pVXOnDkGYXCV96bYG+9ScwJUHjBh3zxfMKlKfMG8=";
		"CP057640.1" = "sha256-2Hw3Ra2qkrJ6n5aZBBIV+mW/EPeKNf+BMvJFSNh3qwg=";
		"CP075276.1" = "sha256-L7qac9jbf0fKK8cHUnLMZFQ917yZJRFvAOLoOYwaTJw=";
		"CP091506.1" = "sha256-j5NN53z4lhHj6oJOxN6+nzXb6BTP250yqHv5+R4adfA=";
		"CP050726.1" = "sha256-Hpp5H/dQOXBL8KsVDBmP5tlCxhKc/kQzBD2O1unpQd0=";
		"CP034177.1" = "sha256-fcZx46eXgidnXct00sORk3iV2VfMcFvtVyl7xK5hYJ0=";
		"CP076323.1" = "sha256-2VDvggOolFlSeg2nX+jYb6Qv2dVOdE+EG+mI07aSZVw=";
		"CP024992.1" = "sha256-ssIBZ+R9NdRMRk5u3yyobRYt/LpeAz5nBJR05SPbylY=";
		"CP002736.1" = "sha256-wjbn/Fpbc5IOslhyUqT/14BefmgPEVS50uucuMELKLQ=";
		"CP009575.1" = "sha256-iLKaiDydcj+/ff4bnI0jvAkQRtsDxdxTU5YlwIpd96g=";
		"CP029476.1" = "sha256-oO4fY7FsKGNCPp+6HB1wahZ/0fmpDUDReUM06rtIFuQ=";
		"CP047675.1" = "sha256-kHwEWSYMYKgrQel/cMAkUrSPjt4l6XFTy1zjnkEPOuk=";
		"CP057927.1" = "sha256-On0PWT84KdWjOoiHQkYAF+r2VJQEGYiJ/t4cFp359Po=";
		"CP022283.1" = "sha256-zDlHll0vv+dgaEaK57EgDHvAti+8IfeIdLY3OQ7DSbQ=";
		"CP007267.2" = "sha256-5M0vGsViL5zUfGpIcHGqKIRWOHJthxASQmlnfAAnMHM=";
		"CP044410.1" = "sha256-dunj27NhL2f6Cv0MaBx4+jtWgnp0o4PrDXY/B1qEQJo=";
		"CP067988.1" = "sha256-QeMkminH3GZ4S0urI+WejikwQn5mEh0xlarqmLt8W04=";
		"LR698986.1" = "sha256-5v173tc/4J10zgNfh/Qdia2AFhDEp5HSMeaLq+Szvy0=";
		"CP025452.1" = "sha256-/aZ9hwN+31DKCRFRvwzHw7E/qjgWTYFWzWKjEHyADzA=";
		"CP058306.1" = "sha256-gQyVbuAsgvphGxzCOk9Zja2kdLAO9hgd0ks3MMr68pw=";
		"CP086164.1" = "sha256-D2nIMmvLCwVPUlrT52yhkWn17vTRwXRX1jVIc9pSJpk=";
		"CP047550.1" = "sha256-fwL9F5uLf9VbGEvD+1BwS6wP3v47XJNPso60yf8UenU=";
		"CP016827.1" = "sha256-8ArTMdrsdFit0nLO8uF8abXsvb+T2h4x3NR16o3YXQo=";
		"CP023470.1" = "sha256-2w+R0jOqr+mm4ZWXyPEqvfy1pZnAnAyMQQvdkBqKHaY=";
		"CP007121.1" = "sha256-QUuBMrSwd1h50OxYG3+POTKsdI4DFapqExlrU3DvgBQ=";
		"CP020828.1" = "sha256-Iy/nZqKoSiqe9SQ9px4g7bdShz1q/eVwDbmpNlovphg=";
		"CP075895.1" = "sha256-/4bJyGF//NZFja4FTl8Ev/5rRz6AOnkcq973Hzfo2gQ=";
		"CP017762.1" = "sha256-yULqPvZQhGhyx4uCXHn4V7GwUN5cFYG5g9TcVGQvFoA=";
	};
	fetchGenome = acc: hash: pkgs.fetchurl {
		name = "${acc}.fa";
		url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${acc}&rettype=fasta&retmode=text";
		# NCBI allows ~3 requests/s without an API key and answers 429 beyond that.
		curlOptsList = [ "--retry" "12" "--retry-delay" "5" "--retry-all-errors" ];
		inherit hash;
	};
	genomeFarm = name: hashes: pkgs.linkFarm name
		(pkgs.lib.mapAttrsToList (acc: hash: { name = "${acc}.fa"; path = fetchGenome acc hash; }) hashes);
	# CRISPRCasdb full dump (PostgreSQL SQL, release of 2022-04-14).
	crisprcasdbDump = pkgs.fetchurl {
		name = "ccpp_db.zip";
		url = "https://crisprcas.i2bc.paris-saclay.fr/Home/DownloadFile?filename=ccpp_db.zip";
		hash = "sha256-+F8LFZyi2D78NvUuENZJtUNR5DHFeQqGETmkEcK4dQA=";
	};
	# Ground truth, one CRISPR array per line for the given accessions:
	# accession, organism, start (1-based), length, orientation, evidence level, DR consensus.
	mkTruth = name: hashes: pkgs.runCommand name { nativeBuildInputs = [ pkgs.unzip pkgs.gawk ]; } ''
		unzip -p ${crisprcasdbDump} > dump.sql
		awk '/^COPY public\.(crisprlocus|sequence|strain|entity|region) / { split($2, a, "."); f = a[2] ".tsv"; on = 1; next }
			on && /^\\\.$/ { on = 0; close(f); next }
			on { print > f }' dump.sql
		awk -F'\t' -v want="${pkgs.lib.concatStringsSep " " (builtins.attrNames hashes)}" '
			BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
			FNR == 1 { f++ }
			f == 1 && $4 == "Sequence" { acc[$1] = $5 }
			f == 1 && $4 == "Strain" { name[$1] = $5 }
			f == 2 { strain[$1] = $2 }
			f == 3 { dr[$1] = $2 }
			f == 4 && keep[acc[$2]] { print acc[$2] "\t" name[strain[$2]] "\t" $3 "\t" $4 "\t" $5 "\t" $7 "\t" dr[$8] }
		' entity.tsv sequence.tsv region.tsv crisprlocus.tsv | sort -k1,1 -k3,3n > $out
	'';
in {
	genomes = genomeFarm "scoreboard-genomes" devHashes;
	crisprTruth = mkTruth "crisprcasdb-truth.tsv" devHashes;
	heldoutGenomes = genomeFarm "scoreboard-heldout-genomes" heldoutHashes;
	heldoutTruth = mkTruth "crisprcasdb-heldout-truth.tsv" heldoutHashes;
}
