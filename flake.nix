{
  description = "SomeWM - AwesomeWM ported to Wayland";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      targetArchs = nixpkgs.lib.systems.flakeExposed;
      forAll =
        f:
        nixpkgs.lib.genAttrs targetArchs (
          system:
          f system (import nixpkgs { inherit system; })
        );
    in
    {
      packages = forAll (
        system: pkgs: rec {
          somewm = pkgs.callPackage ./package.nix { };
          default = somewm;
        }
      );

      apps = forAll (
        system: pkgs: {
          default = {
            type = "app";
            program = "${self.packages.${system}.somewm}/bin/somewm";
          };
          somewm-client = {
            type = "app";
            program = "${self.packages.${system}.somewm}/bin/somewm-client";
          };
        }
      );

      devShells = forAll (
        system: pkgs: {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.somewm ];
          };
        }
      );
    };
}
