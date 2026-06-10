{
  description = "crucible — Haskell library workspace";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAll (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # GHC 9.10.1 — matches the ghc = "9.10.1" pin in zinc.toml (aligned
          # with sibling project manifest for shared-types interop).
          # zinc manages all Haskell deps itself; Nix only provides the compiler
          # and the source-preprocessors zinc shells out to (alex, happy, hsc2hs).
          ghc = pkgs.haskell.compiler.ghc9101;
        in
        {
          default = pkgs.mkShell {
            packages = [
              ghc
              pkgs.git
              pkgs.haskellPackages.alex
              pkgs.haskellPackages.happy
              pkgs.zlib
            ];
            # Template Haskell (e.g. neat-interpolation's [text| |] quasiquoter)
            # loads the package closure at compile time and needs libz.so on the
            # loader path; zinc builds zlib but does not expose its shared lib.
            shellHook = ''
              export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.zlib ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            '';
          };
        });
    };
}
