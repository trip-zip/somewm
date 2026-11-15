FROM alpine:latest
ENV LUA_PKG=lua5.4 LUA_BIN=lua5.4
RUN apk add --no-cache \
    build-base abuild bash git meson samurai pkgconf \
    wlroots0.20-dev wayland-dev wayland-protocols \
    libdrm-dev libxkbcommon-dev pixman-dev libinput-dev dbus-dev mesa-dev \
    libxcb-dev xcb-util-wm-dev lua5.4 lua5.4-dev lua5.4-lgi \
    cairo-dev pango-dev gdk-pixbuf-dev librsvg-dev glib-dev libffi-dev \
    linux-pam-dev font-dejavu \
    lua5.4-busted font-noto-cjk gtk+3.0 dbus mesa-dri-gallium \
    bc coreutils util-linux-misc findutils wlr-randr grim foot xterm xwayland zsh sudo
# tests/run-unit.sh calls busted, but lua5.4-busted only installs busted-5.4.
RUN ln -s /usr/bin/busted-5.4 /usr/local/bin/busted
