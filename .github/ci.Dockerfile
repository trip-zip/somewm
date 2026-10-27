# CI image for the Build & Test matrix. One image per Lua variant, built by
# the "image" job in workflows/ci.yml and tagged by this file's hash, so a
# change here is rebuilt on the run that makes it.
#
# Packages come from the Ubuntu image's own mirror at build time, so a slow
# runner mirror costs one rebuild instead of every run.
FROM ubuntu:26.04

ARG LUA_INTERPRETER
ARG LUA_DEV_PACKAGE

# The hosted runners export LANG=C.UTF-8 and the compositor adopts it at
# startup; test-prompt-unicode asserts that it did.
ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC LANG=C.UTF-8

RUN ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime \
 && echo Etc/UTC > /etc/timezone \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
      sudo \
      fonts-noto-cjk \
      wlr-randr \
      grim \
      dpkg-dev \
      ninja-build \
      python3-pip \
      pkg-config \
      wayland-protocols \
      libwayland-dev \
      libxkbcommon-dev \
      libinput-dev \
      libdbus-1-dev \
      dbus \
      libglib2.0-bin \
      bc \
      libdrm-dev \
      libgbm-dev \
      libegl-dev \
      libgles-dev \
      libpixman-1-dev \
      libudev-dev \
      libseat-dev \
      libxcb1-dev \
      libxcb-icccm4-dev \
      libxcb-composite0-dev \
      libxcb-render0-dev \
      libxcb-render-util0-dev \
      libxcb-res0-dev \
      libxcb-ewmh-dev \
      libxcb-errors-dev \
      libxcb-xfixes0-dev \
      libxcb-xinput-dev \
      libxcb-util-dev \
      libxcb-dri3-dev \
      libxcb-present-dev \
      libxcb-shm0-dev \
      hwdata \
      libdisplay-info-dev \
      libliftoff-dev \
      ${LUA_INTERPRETER} \
      ${LUA_DEV_PACKAGE} \
      lua-busted \
      lua-lgi \
      luarocks \
      libcairo2-dev \
      libpango1.0-dev \
      libgdk-pixbuf-2.0-dev \
      librsvg2-dev \
      libglib2.0-dev \
      libgirepository1.0-dev \
      gir1.2-pango-1.0 \
      gir1.2-gdk-3.0 \
      gir1.2-rsvg-2.0 \
      libxml2-dev \
      bison \
      foot \
      xterm \
      xwayland \
      zsh \
 && python3 -m pip install --upgrade --break-system-packages meson \
 && rm -rf /var/lib/apt/lists/*

# Ubuntu ships lgi and busted for Lua 5.1 and 5.3 only, so the 5.2 image
# builds them from source into /usr/local, where they shadow the 5.3 ones.
RUN if [ "$LUA_INTERPRETER" = lua5.2 ]; then \
      set -eu; \
      sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources; \
      apt-get update; \
      cd /tmp; \
      apt-get source lua-lgi; \
      cd lua-lgi-*/; \
      make -C lgi LUA_VERSION=5.2 PREFIX=/usr/local LUA_CFLAGS="$(pkg-config --cflags lua5.2)" VERSION=0.9.2; \
      make -C lgi install LUA_VERSION=5.2 PREFIX=/usr/local LUA_CFLAGS="$(pkg-config --cflags lua5.2)" VERSION=0.9.2; \
      luarocks --lua-version=5.2 --tree=/usr/local install busted 2.3.0-1; \
      rm -rf /tmp/lua-lgi* /var/lib/apt/lists/*; \
    fi
