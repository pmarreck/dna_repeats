# Infernal 1.1.5 (Nawrocki & Eddy 2013), covariance-model RNA search; cmscan screens
# recurring non-coding repeat families against Rfam. Not packaged in nixpkgs.
{ pkgs }:
pkgs.stdenv.mkDerivation {
	pname = "infernal";
	version = "1.1.5";
	src = pkgs.fetchurl {
		url = "http://eddylab.org/infernal/infernal-1.1.5.tar.gz";
		hash = "sha256-rU3a4C+STKfIW8jEp5yfh1r435autyZwL6mFy+dSSX8=";
	};
	nativeBuildInputs = [ pkgs.perl ];
	enableParallelBuilding = true;
}
