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
	# Held-out set #2: the next 30 by the same rule (positions 31-60), pinned before any
	# result on it was seen, after held-out #1 was used to diagnose a bug.
	heldout2Hashes = {
		"CM002029.1" = "sha256-GVYCc6t1JKwzzkSAOREyMc+chz61lKYyzdJ8Xcn7HAk=";
		"CP051845.1" = "sha256-SZtHxV/Rzjbbyl4O+04hYbItsRRFEzUvm30Zh50L8Lc=";
		"CP050440.1" = "sha256-wBQkEPx6eTCaDS3pcvLdSfgGKWffzeTD4eorBi7dwbg=";
		"CP064674.1" = "sha256-YuxAW/eEFSGYbnanLunyqy0dH55amTBY07DNG5KVpPA=";
		"CP043473.1" = "sha256-u21g8FmZNJuF7lXPfrZFJPK6pNbnzprz/xfXk78BY34=";
		"CP018787.1" = "sha256-cbrlHe4yK2pwl3+Bbp5NDKKzG8qMEqRJpDAuaQh4rKo=";
		"CP021137.1" = "sha256-eEdSMl8sgGjEE56qiw3tfjZJW9OLjI/KJZ8C1MH3Tuc=";
		"CP085589.1" = "sha256-JtfAuSpPxfqZksaL6fEeT006w9wyKlMrl6W/bafMd/I=";
		"CP057055.1" = "sha256-5iqrgB2jsduQ6D5JZhbTnrlHraBisTQ1qJU+MrFsda8=";
		"CP091659.1" = "sha256-bVOKHURZCnegPFY75Ibgv68PTLR0XFEAsc3UvqFW/6U=";
		"CP016826.1" = "sha256-3dBDQUtKLyGe8GjEHeURcGKhT0wCfR6L3WvThVQtgjg=";
		"CP016625.1" = "sha256-Q22inbRnFi/Qqe78setYg44XbG1DAJZyP/prs1f65/w=";
		"CP091822.1" = "sha256-AL+l3BmMKN4WFLl95UebKI8GphvyjdJwT1tcRAIrf7c=";
		"CP061239.1" = "sha256-aA1De3NyAIcnEJFsL5JNz2hZxJ/XRDCPWWU6FJYdWw8=";
		"CP082582.1" = "sha256-mJazt86RvWt+6mzHZLPeZUzjSrFEkzFb3huW8EaPfxE=";
		"CP029553.1" = "sha256-TlETs2fPWBT9SvOenvqdndF6WgE17xTsTDsmWl3lmRM=";
		"CP009577.1" = "sha256-FKmII3KI/2cq0qxVDXq4wMPsP09BUryB/a9Jj7OZCc0=";
		"CP022127.1" = "sha256-TWQ1g81SoGrJz3SxZ6rmiJZiY0U3B5D1M2sVyC8sNyk=";
		"CP004014.1" = "sha256-RFyG+XwpR/NXLHD29N0NUs6s+fQt3MnoKCQSl/dDq0g=";
		"CP009196.1" = "sha256-eEGRP0xp6EQb7jyLrUXySOmD0rrsROD7P5VaRQHEjdY=";
		"CP057879.1" = "sha256-3D8bLqGFNjFFAG4miW3LR63ePjeC5OD6KXgWyy2m8zY=";
		"CP020620.1" = "sha256-j2LdezBisVPBpA9Fv0teDB4SycNE8n63EntPe3rbNh0=";
		"CP028398.1" = "sha256-LsDAOp/yaEPqF6iKnsdsJWLt1fWbIddFEw2JqRdFtPU=";
		"CP074328.1" = "sha256-J5nP82wF6e5OThg2WtvN1YndC+vJQ+KQfXEjoCvTVhY=";
		"CP040900.1" = "sha256-kxluo2B6VI+svYkovQYuUlial+zZJwcHzPZ2gQi2S10=";
		"CP026202.1" = "sha256-CaE6EasHDfmOg5G3joe9VMTTqrAkQh/4DzJo4V4VJEg=";
		"CP062204.1" = "sha256-M9B4TM3yAWdq4Mmf0O1i0D5HhIpTx/gHCDcr4gIGImI=";
		"CP058072.1" = "sha256-p6RHKoFyO4EfKReCb7fIUThL6pyv8proUoCtASI6i6s=";
		"CP072021.1" = "sha256-5inYaVzsF3uSyebfETviAP8EUy4yVr7WWbcKsdz41LM=";
		"CP001363.1" = "sha256-tCy4WAAXaA33EBrUa52H3xlDoi6Pyb/wcETVm5w+grc=";

	};
	# Held-out set #3: positions 61-90 by the same rule, pinned 2026-09-26 23:20 EDT before any
	# result on it was seen, after held-out #2 had been scored once and the seeding changed.
	heldout3Hashes = {
		"CP037831.1" = "sha256-S8KjIfkerfvBTsiWpTbDDnxlShxI8T2kVQBp0Cr1PCg=";
		"CP031703.1" = "sha256-jX3cZdHO0Nky6R/D0QL+N5Xlwna0DBwuCIPm/4aeh8Y=";
		"OU015584.1" = "sha256-LrfQkdMgsh3J7LeUbaAzUGAQjZOJkn5i2qtgN26gyIc=";
		"CP027717.1" = "sha256-UB3RR6wpOeSDRuYvjFenHtv4fV/Q7NYOJAw2xQ+HPPk=";
		"CP045694.1" = "sha256-uw3gI4cGsRRbok24OfDUNrkS6Ac2idem2um0tdw98nA=";
		"CP076098.1" = "sha256-XoV8B6LBiki4Od7xFtXh/tzdIbphOcRMAXuqmYiCpn0=";
		"CP021202.1" = "sha256-ePlTWpmJJgD5MFhknfw7coomCML1fV9FF7j+4INuvw4=";
		"LR698974.1" = "sha256-wHd3iqLwqIrQqWOBCkW8JSW2xkGvZvga0w2jcmQu4U0=";
		"CP088443.1" = "sha256-o/73n2XdyKhQWuIQ4WNbZOlBBFa61VjiGHknWENS96c=";
		"CP007011.1" = "sha256-gKGj0vkOEjCpg7f6HAlmXWXHHCwlcjwX1qG+EccUqr8=";
		"CP002038.1" = "sha256-Rm8BdlslUqlPMoo8zadfbxThCt2r1w+0DeCf5/MAKuk=";
		"CP070954.1" = "sha256-LlRmjx+jx5C6IRfMcI3fesdGW3yR4JZ5S5ioK4Faaww=";
		"CP070897.1" = "sha256-wxKl/UBAgPDW9eejbBk+Zw7/vtAcZXMRrqX3lR/VkL8=";
		"OU917922.1" = "sha256-ya9f7JdHcI12peIdCjgNmNN4uGNNrpHjumFYPUdx2nc=";
		"CP084332.1" = "sha256-uw5+xSXNryQfr/Rpz0+e2dcMa7J1gZYCrja7lhpPbZ8=";
		"AP014724.1" = "sha256-Ujh2uQLnMBgfZLXyobyT9bEwGLtiOt0pHLg20K+aPbQ=";
		"CP033336.1" = "sha256-Fbpfn+k9hxhROhyFLXIwkP0D71geixcCbcusJw40xbg=";
		"CP017518.1" = "sha256-Mh/Ezh1mzknK5tEBjPILUYjIFvUgU80r58UQsDAzk0M=";
		"AP025205.2" = "sha256-9l8zwZM1PwnpfGbDuENe29IOs06tn3m91UyfLIHxJCE=";
		"CP050447.1" = "sha256-KZXjDaqihkfnwdOG1FswnXyZ5o8QXk55uTmnZ/jB6ac=";
		"CP085753.1" = "sha256-/ztr1EQuxDCFWJr5oQ90Ueb9egPsOyYZApwxuT6b7k8=";
		"CP007776.2" = "sha256-Z9I+5fv745O/qFfh9S/9YOcoITBHs2WLv/V53wEqsBc=";
		"CP070376.1" = "sha256-ZZq3vt1pPM+jfcdnBN020D9+KKsQtufXyJxQ24wnJ/k=";
		"AE017222.1" = "sha256-qoKC/dgQCY+WKgflwH5OEXQBM1cuu0OJNKwZm0U2YV0=";
		"CP048835.1" = "sha256-5+gPeNsEgI/S2pOFk/qTLbaZPbuH3+OFNPddrM9Ei7w=";
		"CP003119.1" = "sha256-L4l8L+F3crb7baRdThR7ix9/2X/ckHBU4uGZGjKfk/4=";
		"CP073630.1" = "sha256-Y4FqPmgef6v5KxOjCEwJAU55PoyhCHlmU0Sv+s2oQRU=";
		"CP071133.1" = "sha256-M/ielr/DiE9ZtBS6XYJkYB7AYVCantEyF6d/E7iR4AU=";
		"CP006716.1" = "sha256-7gE/Qw6hnZ1psyDHdvY/MSUFIrZUwnRTbn4+iDZebAw=";
		"CP047529.1" = "sha256-64OLCRE6kt5axMd5S5pD7tJHJviUOsvfjNyfSVY5X+M=";
	};
	# Phage genomes with ART loci named in Yoon et al. 2026 (intents/art_search.md): the tuning
	# and held-out sets for the --art preset, fixed on 2026-09-28 before tuning.
	artHashes = {
		"MW248466.1" = "sha256-r4zHpDqZJPZeZJvjE2WJ2t3a4sKzZmWOaxZF1No25sY=";
		"MW218148.1" = "sha256-dsmEX2THhkGCVnvgOyzs5E9MlVqTLs+M7El9se/97lE=";
		"MW349129.1" = "sha256-4zX/ek5cMHji/6jckkdFoa1r8dsbSPFh9ubBgVQMJ4k=";
		"OR836606.1" = "sha256-vw1GQntqaH/RKmSU2TtqyZxohXpCijq746Qhq6RRPZY=";
		"LC680885.1" = "sha256-XH71+y+ugUJsP/mdpnnyW0VIKVrviUN/wV/Fo0pRWns=";
		"MN091626.1" = "sha256-LI8Rkx4UkxPNp3yzn7BH8MdrUm8BUycl/p5bcdkDkWo=";
		"MZ779063.1" = "sha256-EORkznJxDvyXPB9kyR0CN+eMvIdKgrlIORL03pc08iA=";
		"MZ422438.1" = "sha256-S+LOPC7EhtYUEAZh2J//8qhyHjCSMlGaKRKV2dbchag=";
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
	heldout2Genomes = genomeFarm "scoreboard-heldout2-genomes" heldout2Hashes;
	heldout2Truth = mkTruth "crisprcasdb-heldout2-truth.tsv" heldout2Hashes;
	heldout3Genomes = genomeFarm "scoreboard-heldout3-genomes" heldout3Hashes;
	heldout3Truth = mkTruth "crisprcasdb-heldout3-truth.tsv" heldout3Hashes;
	artGenomes = genomeFarm "art-genomes" artHashes;
	# myRT reverse transcriptase class models (Mestre et al. 2022, NAR 50:e29): 45 profiles for 41 classes.
	myrtHmm = "${pkgs.fetchFromGitHub { owner = "mgtools"; repo = "myRT"; rev = "fa8e3624adf4c4e57ebf3350c06d626f805e42f7"; hash = "sha256-eWaOZCBQllOf6DTvn6tP09xjk15V5xDMaxHyrR0fVOU="; }}/Models/HMM/RVT-All.hmm";
	# Pfam RVT_1 (PF00078.33), the general reverse transcriptase profile, for linking arrays to RTs.
	pfamRvt1 = pkgs.runCommand "PF00078.hmm" { nativeBuildInputs = [ pkgs.gzip ]; } ''
		gunzip -c ${pkgs.fetchurl { name = "PF00078.hmm.gz"; url = "https://www.ebi.ac.uk/interpro/wwwapi//entry/pfam/PF00078?annotation=hmm"; hash = "sha256-AzDT0bMx4iWhSw6z4IUlmp1lU/bfSVK9xuaO+QqoJWM="; }} > $out
	'';
	# Rfam 15.0 covariance models, cmpress-ed for cmscan, plus the clan table for --clanin.
	rfam = pkgs.runCommand "rfam-15.0" { nativeBuildInputs = [ pkgs.gzip (import ./infernal.nix { inherit pkgs; }) ]; } ''
		mkdir -p $out
		gunzip -c ${pkgs.fetchurl { url = "https://ftp.ebi.ac.uk/pub/databases/Rfam/15.0/Rfam.cm.gz"; hash = "sha256-+Ihe4b33oIXJpor5S+aNI+Y9pkfY+fCYNdIqIY0r/p8="; }} > $out/Rfam.cm
		cp ${pkgs.fetchurl { url = "https://ftp.ebi.ac.uk/pub/databases/Rfam/15.0/Rfam.clanin"; hash = "sha256-dnPBBcpP6lLu4ZwBunuptedu7UkOwSbfCaA5sq6PXRE="; }} $out/Rfam.clanin
		cmpress $out/Rfam.cm
	'';
	infernal = import ./infernal.nix { inherit pkgs; };
	# Pfam-A 38.2, hmmpress-ed for hmmscan: gene context of repeat families (bench/art-context-run).
	pfamA = pkgs.runCommand "pfam-a-38.2" { nativeBuildInputs = [ pkgs.gzip pkgs.hmmer ]; } ''
		mkdir -p $out
		gunzip -c ${pkgs.fetchurl { url = "https://ftp.ebi.ac.uk/pub/databases/Pfam/releases/Pfam38.2/Pfam-A.hmm.gz"; hash = "sha256-LYIIe2xcYNdizHZ/mOgmCycxNMIVq378z3RAYUpOXas="; }} > $out/Pfam-A.hmm
		hmmpress $out/Pfam-A.hmm
	'';
	# Negative control: the dev genomes with each record's bases shuffled (seed 1), so no real
	# repeat survives; every array a tool reports on them is a false positive.
	shuffledGenomes = pkgs.runCommand "scoreboard-shuffled-genomes" { nativeBuildInputs = [ pkgs.gawk pkgs.bash ]; } ''
		mkdir -p $out
		for f in ${genomeFarm "scoreboard-genomes" devHashes}/*.fa; do
			bash ${../bench/shuffle-fasta} 1 < "$f" > "$out/$(basename "$f")"
		done
	'';
	emptyTruth = pkgs.writeText "empty-truth.tsv" "";
}
