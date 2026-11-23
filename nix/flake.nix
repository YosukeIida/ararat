{
  description = "Ararat dev shell (Rust core, REA with Ghidra)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, nixpkgs-unstable, ... }:
    let
      systems = [ "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # REA admits Ghidra 12.1 or newer only; 26.05 still has 12.0.4.
          unstable = nixpkgs-unstable.legacyPackages.${system};
        in
        {
          # Why not mkShellNoCC (to keep nix's apple-sdk from hiding Xcode's swift): nixpkgs' rustc
          # still links with -liconv and nix's clang wrapper, which then fail without that SDK.
          default = pkgs.mkShell {
            packages = with pkgs; [
              cargo
              rustc
              clippy
              rustfmt
              rust-analyzer
              resvg
              # REA needs ^22.23.4 || ^24.22.1 || >=26.12.1; nodejs_24 on 26.05 is still 24.21.
              nodejs_22
              unstable.ghidra
              unstable.openjdk21
            ];
            GHIDRA_INSTALL_DIR = "${unstable.ghidra}/lib/ghidra";
            JAVA_HOME = unstable.openjdk21.home;
          };
        }
      );
    };
}
