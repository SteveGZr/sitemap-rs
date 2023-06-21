{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05";
    flake-utils.url = "github:numtide/flake-utils";

    # Wir wollen aktuelle Versionen des Rust-Compilers verwenden.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Crane ist ein Build-System für Rust mit besserem Caching.
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        rust = pkgs.rust-bin.stable.latest.default;
        craneLib = (crane.mkLib pkgs).overrideToolchain rust;
        dbScripts = import db/scripts.nix { inherit pkgs; };

        # Wir teilen unseren Quellcode in mehrere Teile für besseres Caching.
        rustSrc = pkgs.lib.cleanSourceWith {
          src = pkgs.lib.cleanSource ./.;
          filter = path: type:
            (craneLib.filterCargoSources path type) ||
            (builtins.match ".*CHANGES\.md$" path != null) ||
            (builtins.match ".*sqlx-data\.json$" path != null);
        };

        commonRustArgs = rec {
          src = rustSrc;
          buildInputs = with pkgs; [ openssl ];
          nativeBuildInputs = with pkgs; [ pkg-config ];

          cargoArtifacts = craneLib.buildDepsOnly {
            inherit src buildInputs nativeBuildInputs;
            pname = "atlas-deps";
            version = "0.1.0";
          };
        };
      in {
        packages = rec {
          atlas = craneLib.buildPackage (commonRustArgs // {
            pname = "atlas";
            version = "0.1.0";
            doCheck = false; # Tests werden mit `atlas-tests` ausgeführt
          });

          atlas-lints = import ./lints.nix {
            inherit pkgs rust;
          };

          atlas-tests = import ./tests.nix {
            inherit pkgs dbScripts craneLib commonRustArgs;
          };

          ociImage = pkgs.dockerTools.buildImage {
            name = "atlas";
            tag = "latest";
            created = "now";
            copyToRoot = [
              atlas
              dbScripts.with-database-url
              dbScripts.atlas-mysql
              dbScripts.atlas-hard-reset
              dbScripts.atlas-recreate-db-routines
              dbScripts.atlas-migrate
              pkgs.mysql
            ] ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.busybox ]);
            config = {
              Cmd = [
                "with-database-url"
                "atlas"
                "--port=80"
              ];
              Volumes = {
                "/tmp" = {};
                "/var/atlas/sitemaps" = {};
              };
              Env = [
                "SITEMAPS_DIRECTORY=/var/atlas/sitemaps"
              ];
            };
          };

          testOciImage = pkgs.dockerTools.buildImage {
            name = "atlas-tests";
            tag = "latest";
            created = "now";
            copyToRoot = with pkgs.dockerTools; [
              usrBinEnv
              binSh
            ];
            config = {
              Cmd = [
                "${dbScripts.with-database-url}/bin/with-database-url"
                "${atlas-tests}/bin/atlas-tests"
              ];
              Volumes = {
                  "/tmp" = {};
                  "/var/atlas/sitemaps" = {};
              };
              Env = [
                "SITEMAPS_DIRECTORY=/var/atlas/sitemaps"
              ];
            };
          };
        } // dbScripts;

        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages."${system}".atlas ];
          buildInputs = (with pkgs; [
            bacon
            cargo-edit
            cargo-expand
            cargo-machete
            cargo-nextest
            cargo-watch
            just
            rust-analyzer
            sqlx-cli
          ]) ++ (builtins.attrValues dbScripts);
        };
      }
    );
}
