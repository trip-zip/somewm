{
  lib,
  stdenv,
  fetchurl,
  cairo,
  dbus,
  gdk-pixbuf,
  glib,
  glslang,
  gobject-introspection,
  harfbuzz,
  hwdata,
  lcms2,
  libdisplay-info,
  libdrm,
  libgbm,
  libGL,
  libinput,
  libliftoff,
  librsvg,
  libxcb,
  libxcb-errors,
  libxcb-render-util,
  libxcb-util,
  libxcb-wm,
  libxkbcommon,
  luajit,
  makeWrapper,
  meson,
  ninja,
  pam,
  pango,
  pixman,
  pkg-config,
  seatd,
  wayland,
  wayland-protocols,
  wayland-scanner,
  xwayland,
  gtk3Support ? true,
  gtk3 ? null,
  wrapGAppsHook3,
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

  # The tarball subprojects/wlroots.wrap names, so meson builds it without a download.
  wlrootsSrc = fetchurl {
    url = "https://gitlab.freedesktop.org/wlroots/wlroots/-/releases/0.20.2/downloads/wlroots-0.20.2.tar.gz";
    sha256 = "80c567d2ed4efb2cfa6b077f22c7a710d9c78ba4e185a75e8694001114af0733";
  };
in
stdenv.mkDerivation {
  pname = "somewm";
  version = "dev";

  src = ./.;

  strictDeps = true;

  nativeBuildInputs = [
    glslang
    gobject-introspection
    makeWrapper
    meson
    ninja
    pkg-config
    wayland-scanner
    wrapGAppsHook3
  ];

  buildInputs = [
    cairo
    dbus
    gdk-pixbuf
    glib
    harfbuzz
    hwdata
    lcms2
    libdisplay-info
    libdrm
    libgbm
    libGL
    libinput
    libliftoff
    librsvg
    libxkbcommon
    luajit
    luaEnv
    pam
    pango
    pixman
    seatd
    wayland
    wayland-protocols
    wayland-scanner
    libxcb
    libxcb-errors
    libxcb-render-util
    libxcb-wm
    libxcb-util
    xwayland
  ]
  ++ lib.optional gtk3Support gtk3;

  preConfigure = ''
    mkdir -p subprojects/packagecache
    cp ${wlrootsSrc} subprojects/packagecache/wlroots-0.20.2.tar.gz
  '';

  mesonFlags = [ "-Dsystemd=disabled" ];

  # wlroots is linked in; its headers, static library and .pc are not installed.
  mesonInstallFlags = [ "--skip-subprojects" ];

  postFixup =
    let
      giPackages = [
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
        --prefix LUA_PATH : "${luaEnv}/share/lua/${luaEnv.luaversion}/?.lua;${luaEnv}/share/lua/${luaEnv.luaversion}/?/init.lua" \
        --prefix LUA_CPATH : "${luaEnv}/lib/lua/${luaEnv.luaversion}/?.so"
    '';

  passthru.providedSessions = [ "somewm" ];

  meta = with lib; {
    description = "AwesomeWM ported to Wayland - 100% Lua API compatible";
    homepage = "https://github.com/trip-zip/somewm";
    license = licenses.gpl3;
    platforms = platforms.linux;
    mainProgram = "somewm";
  };
}
