{
  description = "Manifest — the Unit-of-Work layer Haskell never had.";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAll (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.haskell.compiler.ghc9101
              pkgs.git
              pkgs.haskellPackages.alex
              pkgs.haskellPackages.happy
              pkgs.haskellPackages.markdown-unlit  # -pgmL: compiles ```haskell blocks of .lhs tutorials
              pkgs.pkg-config
              pkgs.postgresql      # libpq headers + initdb/postgres/pg_ctl
              pkgs.zlib
            ];
            shellHook = ''
              # libpq lib dir on both paths so the test exe's `-lpq` links
              # (zinc doesn't yet emit extra-libraries into package.conf; see
              # zinc bd issue on external system-lib linking).
              export LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.postgresql ]}''${LIBRARY_PATH:+:$LIBRARY_PATH}
              export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.zlib pkgs.postgresql ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            '';
          };
        });
    };
}
