{
  description = "Den Shell - Modern POSIX shell written in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        den = pkgs.callPackage ./default.nix { };
      in
      {
        packages = {
          default = den;
          den = den;
        };

        apps = {
          default = {
            type = "app";
            program = "${den}/bin/den";
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ den ];
        };
      }
    );
}
