{
  lib,
  stdenv,
  cairo,
  dbus,
  gdk-pixbuf,
  glib,
  gobject-introspection,
  harfbuzz,
  libdrm,
  libinput,
  librsvg,
  libxcb,
  libxcb-util,
  libxcb-wm,
  libxkbcommon,
  luajit,
  makeWrapper,
  meson,
  ninja,
  pango,
  pkg-config,
  wayland,
  wayland-protocols,
  wayland-scanner,
  wlroots_0_19,
  xwayland,
  gtk3Support ? true,
  gtk3 ? null,
  extraGIPackages ? [ ],
  extraLuaPackages ? (_: [ ]),
}:

assert gtk3Support -> gtk3 != null;

let
  luaEnv = luajit.withPackages (
    ps:
    with ps;
    [
      lgi
      ldbus
    ]
    ++ (extraLuaPackages ps)
  );
in
stdenv.mkDerivation {
  pname = "somewm";
  version = "dev";

  src = ./.;

  strictDeps = true;

  nativeBuildInputs = [
    gobject-introspection
    makeWrapper
    meson
    ninja
    pkg-config
    wayland-scanner
  ];

  buildInputs =
    [
      cairo
      dbus
      gdk-pixbuf
      glib
      harfbuzz
      libdrm
      libinput
      librsvg
      libxkbcommon
      luajit
      luaEnv
      pango
      wayland
      wayland-protocols
      wlroots_0_19
      libxcb
      libxcb-wm
      libxcb-util
      xwayland
    ]
    ++ lib.optional gtk3Support gtk3;

  postFixup =
    let
      giPackages =
        [
          gdk-pixbuf
          glib.out
          gobject-introspection
          harfbuzz.out
          librsvg.out
          pango.out
        ]
        ++ lib.optional gtk3Support gtk3.out
        ++ extraGIPackages;
      giTypelibPath = lib.strings.concatMapStringsSep ":" (p: "${p}/lib/girepository-1.0") giPackages;
    in
    ''
      wrapProgram $out/bin/somewm \
        --prefix GI_TYPELIB_PATH : "${giTypelibPath}" \
        --add-flags "--search ${luaEnv}/lib/lua/${luaEnv.luaversion}" \
        --add-flags "--search ${luaEnv}/share/lua/${luaEnv.luaversion}"
    '';

  meta = with lib; {
    description = "AwesomeWM ported to Wayland - 100% Lua API compatible";
    homepage = "https://github.com/trip-zip/somewm";
    license = licenses.gpl3;
    platforms = platforms.linux;
    mainProgram = "somewm";
  };
}
