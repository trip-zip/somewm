# How to use SomeWM with Nix

## Building

With flakes enabled:

```bash
nix build github:trip-zip/somewm     # build from GitHub
nix build                             # build from local checkout
nix run github:trip-zip/somewm        # run directly
```

Without flakes (`nix-build`):

```bash
nix-build                             # uses default.nix wrapper
```

## NixOS Integration

Add SomeWM as a flake input in your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    somewm = {
      url = "github:trip-zip/somewm";
      # Optional: use your nixpkgs instead of somewm's pinned version.
      # Comment this out if the build breaks.
      # inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, somewm, ... }@inputs: {
    # ... your outputs
  };
}
```

The package is at `somewm.packages.${system}.somewm`. A convenient way to
use it is via an overlay so it feels like any other package:

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [
    (_: prev: {
      somewm = inputs.somewm.packages.${prev.stdenv.hostPlatform.system}.default;
    })
  ];
};
```

## Development

```bash
nix develop    # enter a shell with all build dependencies
```

## Customization

The derivation accepts several override parameters via `callPackage` /
`.override`:

- **`extraGIPackages`** - list of packages whose `girepository` typelibs
  are added to `GI_TYPELIB_PATH`.
- **`extraLuaPackages`** - function receiving `luaPackages` as argument;
  returned packages are made available to the Lua interpreter.
- **`gtk3Support`** - boolean (default `true`). Set to `false` to omit
  GTK3 (disables icon lookups in libs like bling).

Example override:

```nix
pkgs.somewm.override {
  extraLuaPackages = ps: [ ps.luafilesystem ];
  extraGIPackages = [ pkgs.networkmanager ];
}
```
