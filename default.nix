{ pkgs ? import <nixpkgs> {} }:

let
  # LuaJIT with lgi for Lua GObject Introspection bindings
  luaEnv = pkgs.luajit.withPackages (ps: with ps; [
    lgi
  ]);
in
pkgs.stdenv.mkDerivation {
  pname = "somewm";
  version = "dev";

  src = ./.;

  strictDeps = true;

  nativeBuildInputs = with pkgs; [
    meson
    ninja
    pkg-config
    gobject-introspection  # Required for lgi typelib discovery
    makeWrapper
  ];

  buildInputs = with pkgs; [
    # Core dependencies
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
    pango
    wayland
    wayland-scanner
    wayland-protocols
    wlroots_0_19
    xwayland

    # Lua
    luajit
    luaEnv

    # GTK3 - required by some third-party Lua libs like bling
    # that use Gtk.IconTheme for icon lookups
    gtk3
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp somewm somewm-client $out/bin/
    runHook postInstall
  '';

  # Wrap somewm to set up GI_TYPELIB_PATH for lgi
  # Third-party libs (like bling) may require additional typelibs
  postFixup = ''
    wrapProgram $out/bin/somewm \
      --prefix GI_TYPELIB_PATH : "${pkgs.pango.out}/lib/girepository-1.0" \
      --prefix GI_TYPELIB_PATH : "${pkgs.gdk-pixbuf}/lib/girepository-1.0" \
      --prefix GI_TYPELIB_PATH : "${pkgs.glib.out}/lib/girepository-1.0" \
      --prefix GI_TYPELIB_PATH : "${pkgs.gtk3}/lib/girepository-1.0" \
      --prefix GI_TYPELIB_PATH : "${pkgs.gobject-introspection}/lib/girepository-1.0" \
      --add-flags "--search ${luaEnv}/share/lua/5.1" \
      --add-flags "--search ${luaEnv}/lib/lua/5.1"
  '';

  meta = with pkgs.lib; {
    description = "AwesomeWM ported to Wayland - 100% Lua API compatible";
    homepage = "https://github.com/trip-zip/somewm";
    license = licenses.gpl3;
    platforms = platforms.linux;
    mainProgram = "somewm";
  };
}
