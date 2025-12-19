{ pkgs ? import <nixpkgs> {} }:

pkgs.stdenv.mkDerivation {
  pname = "somewm";
  version = "dev";

  src = ./.;

  strictDeps = true;

  nativeBuildInputs = with pkgs; [
    pkg-config
  ];

  buildInputs = with pkgs; [
    cairo
    dbus
    gdk-pixbuf
    glib
    libdrm
    libinput
    xorg.libxcb
    xorg.xcbutilwm
    xorg.xcbutil
    libxkbcommon
    luajit
    pango
    wayland
    wayland-scanner
    wayland-protocols
    wlroots_0_19
    xwayland
  ];

  # Skip install phase for testing
  installPhase = ''
    mkdir -p $out/bin
    cp somewm somewm-client $out/bin/
  '';
}
