# Established repeat finders that the scoreboard races against (intents/beat_existing_tools.md).
{ pkgs }:
{
	# PILER-CR (Edgar 2007), CRISPR array finder. The tarball also ships prebuilt
	# binaries; they are deleted so the build is from source.
	pilercr = pkgs.stdenv.mkDerivation {
		pname = "pilercr";
		version = "1.06";
		src = pkgs.fetchurl {
			url = "https://www.drive5.com/pilercr/pilercr1.06.tar.gz";
			hash = "sha256-UBdfeqFxZ0zaW6JVYx80D5zH+A6MwlE1pMuFcUfZEGg=";
		};
		# Upstream links -static and predates C++11; -w silences its legacy warnings.
		postPatch = ''
			rm -f pilercr pilercr.exe
			substituteInPlace Makefile \
				--replace-fail "LDLIBS = -lm -static" "LDLIBS = -lm" \
				--replace-fail "CFLAGS = -O3 -DNDEBUG=1" "CFLAGS = -O3 -DNDEBUG=1 -std=gnu++98 -fpermissive -w"
		'';
		installPhase = "install -Dm755 pilercr $out/bin/pilercr";
	};

	# MinCED (Skennerton), CRISPR array finder derived from CRT.
	minced = pkgs.stdenv.mkDerivation {
		pname = "minced";
		version = "0.4.2";
		src = pkgs.fetchFromGitHub {
			owner = "ctSkennerton";
			repo = "minced";
			rev = "0.4.2";
			hash = "sha256-e1/unI4i0ikpG9ltfSlQYGeyHpy+hBM3yC6eMm7XXF8=";
		};
		nativeBuildInputs = [ pkgs.jdk pkgs.makeWrapper ];
		buildPhase = "make minced.jar";
		installPhase = ''
			install -Dm644 minced.jar $out/share/minced/minced.jar
			makeWrapper ${pkgs.jre}/bin/java $out/bin/minced --add-flags "-jar $out/share/minced/minced.jar"
		'';
	};

	# Tandem Repeats Finder (Benson 1999), from nixpkgs.
	trf = pkgs.trf;
}
