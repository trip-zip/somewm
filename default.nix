# Thin wrapper for `nix-build` compatibility.
# The flake uses package.nix directly via callPackage.
{ pkgs ? import <nixpkgs> {} }:
pkgs.callPackage ./package.nix { }
