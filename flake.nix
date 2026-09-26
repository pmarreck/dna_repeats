{
	description = "Gap-constrained DNA repeat-family finder built on PCRE2 capture history";
	inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
	outputs = { self, nixpkgs }:
		let
			systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
			forSystems = nixpkgs.lib.genAttrs systems;
			# mode: "build" (ReleaseFast package), "test" (zig build test) or "cross" (every release target).
			crossTargets = [ "x86_64-linux-musl" "aarch64-linux-musl" "aarch64-macos" "x86_64-windows-gnu" "aarch64-windows-gnu" ];
			package = system: mode:
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
						outputHash = "sha256-KgwuZxL3Y6ahiD/qCIlc1jS/jvdjYsZw8m4cSe5S948=";
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
					pname = "dna-repeats${if mode == "build" then "" else "-" + mode}";
					version = "0.1.0";
					src = self;
					strictDeps = true;
					nativeBuildInputs = [ pkgs.zig ];
					dontConfigure = true;
					dontFixup = mode != "build";
					buildPhase = ''
						runHook preBuild
						export HOME=$TMPDIR
						export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
						mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
						cp -r ${zigDeps}/p "$ZIG_GLOBAL_CACHE_DIR/"
						chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
						${{
							test = "zig build test --summary all";
							build = "zig build -Doptimize=ReleaseFast --prefix $out";
							cross = nixpkgs.lib.concatMapStringsSep "\n" (t: "zig build -Doptimize=ReleaseFast -Dtarget=${t} --prefix $out/${t}") crossTargets;
						}.${mode}}
						runHook postBuild
					'';
					installPhase = if mode == "test" then "mkdir -p $out; touch $out/passed" else "true";
				};
		in {
			packages = forSystems (system: { default = package system "build"; });
			checks = forSystems (system: {
				test = package system "test";
				# Cross-compile the release build for every supported OS/arch.
				cross = package system "cross";
				build = self.packages.${system}.default;
				# CLI surface suite against the ReleaseFast package.
				cli = nixpkgs.legacyPackages.${system}.runCommand "dna-repeats-cli-tests" {
					nativeBuildInputs = with nixpkgs.legacyPackages.${system}; [ bash jq gnugrep coreutils ];
				} ''
					bash ${./tests/cli/run} ${self.packages.${system}.default}/bin/dna-repeats
					touch $out
				'';
			});
			devShells = forSystems (system: {
				default = nixpkgs.legacyPackages.${system}.mkShell {
					packages = with nixpkgs.legacyPackages.${system}; [ zig hyperfine jq ];
				};
			});
		};
}
