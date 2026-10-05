{
  description = "worktigre - Git worktree manager with fzf integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages = {
          worktigre = pkgs.callPackage ./default.nix {};
          default = self.packages.${system}.worktigre;
        };

        # `nix flake check` builds the package, including its install check
        checks.worktigre = self.packages.${system}.worktigre;

        # `nix develop`: tools for the tests (./tests/run.sh) and the lint
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ bats shellcheck fzf gum jq git zsh ];
        };
      }
    ) // {
      overlays.default = final: prev: {
        worktigre = final.callPackage ./default.nix {};
      };
    };
}
