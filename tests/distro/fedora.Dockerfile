FROM fedora:latest
ENV LUA_PKG=lua LUA_BIN=lua
RUN dnf install -y \
    gcc gcc-c++ bash git meson ninja-build pkgconf-pkg-config procps-ng redhat-rpm-config \
    wlroots-devel wayland-devel wayland-protocols-devel \
    libdrm-devel libxkbcommon-devel pixman-devel libinput-devel dbus-devel \
    mesa-libgbm-devel libglvnd-devel libxcb-devel xcb-util-wm-devel \
    lua lua-devel lua-lgi \
    cairo-devel pango-devel gdk-pixbuf2-devel librsvg2-devel glib2-devel \
    libffi-devel pam-devel dejavu-sans-fonts \
    luarocks google-noto-sans-cjk-fonts gtk3 dbus-daemon mesa-dri-drivers \
    mesa-libEGL libglvnd-gles bc wlr-randr grim foot xterm xorg-x11-server-Xwayland zsh
RUN luarocks --lua-version=5.5 --tree=/usr/local install busted 2.3.0-1
# tests/check-lua-compat.sh searches for lua5.5, but Fedora installs only lua.
RUN ln -s /usr/bin/lua /usr/local/bin/lua5.5
