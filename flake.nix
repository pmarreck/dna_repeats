{
	description = "Gap-constrained DNA repeat-family finder built on PCRE2 capture history";
	inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
	outputs = { self, nixpkgs }:
		let
			systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
			forSystems = nixpkgs.lib.genAttrs systems;
			package = system: checked:
				let
					pkgs = nixpkgs.legacyPackages.${system};
					# Fixed-output fetch of the whole Zig dependency tree (the pcre2 fork, pinned by commit).
					zigDeps = pkgs.stdenv.mkDerivation {
						pname = "dna-repeats-zig-deps";
						version = "0.1.0";
						src = self;
						nativeBuildInputs = [ pkgs.zig pkgs.git pkgs.cacert ];
						outputHashMode = "recursive";
						outputHashAlgo = "sha256";
						outputHash = "sha256-LF1PnI9kzYgD8Nkpug4+Ys+lWW7uTHbeV73e7NhYMik=";
						dontConfigure = true;
						dontFixup = true;
						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-fetch
							export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
							export GIT_SSL_CAINFO=$SSL_CERT_FILE
							zig build --fetch=all
						'';
						installPhase = ''
							mkdir -p $out
							cp -r "$ZIG_GLOBAL_CACHE_DIR/p" $out/p
						'';
					};
				in pkgs.stdenv.mkDerivation {
					pname = "dna-repeats";
					version = "0.1.0";
					src = self;
					strictDeps = true;
					nativeBuildInputs = [ pkgs.zig ];
					dontConfigure = true;
					dontFixup = checked;
					buildPhase = ''
						runHook preBuild
						export HOME=$TMPDIR
						export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
						mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
						cp -r ${zigDeps}/p "$ZIG_GLOBAL_CACHE_DIR/"
						chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
						zig build ${if checked then "test --summary all" else "-Doptimize=ReleaseFast --prefix $out"}
						runHook postBuild
					'';
					installPhase = if checked then "mkdir -p $out; touch $out/passed" else "true";
				};
		in {
			packages = forSystems (system: { default = package system false; });
			checks = forSystems (system: {
				test = package system true;
				build = self.packages.${system}.default;
			});
			devShells = forSystems (system: {
				default = nixpkgs.legacyPackages.${system}.mkShell {
					packages = [ nixpkgs.legacyPackages.${system}.zig nixpkgs.legacyPackages.${system}.hyperfine ];
				};
			});
		};
}
