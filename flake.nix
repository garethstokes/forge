{
  description = "crucible — Haskell library workspace";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAll (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # GHC 9.6 — matches the ghc = "9.6.5" pin in zinc.toml.
          # zinc manages all Haskell deps itself; Nix only provides the compiler
          # and the source-preprocessors zinc shells out to (alex, happy, hsc2hs).
          ghc = pkgs.haskell.compiler.ghc96;
        in
        {
          default = pkgs.mkShell {
            packages = [
              ghc
              pkgs.git
              pkgs.haskellPackages.alex
              pkgs.haskellPackages.happy
            ];
          };
        });
    };
}
