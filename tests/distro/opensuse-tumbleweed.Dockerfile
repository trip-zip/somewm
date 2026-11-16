FROM opensuse/tumbleweed
# The distro default is Lua 5.5, but lua55-lgi fails to load with "attempt to assign to const variable 'en'".
ENV LUA_PKG=lua5.4 LUA_BIN=lua5.4
RUN zypper --non-interactive refresh && \
    zypper --non-interactive install --no-recommends \
    gcc gcc-c++ git meson ninja pkgconf-pkg-config make \
    wlroots-devel wayland-devel wayland-protocols-devel \
    libdrm-devel libxkbcommon-devel libpixman-1-0-devel libinput-devel \
    dbus-1-devel libgbm-devel Mesa-libEGL-devel Mesa-libGLESv2-devel \
    libxcb-devel xcb-util-wm-devel \
    lua54 lua54-devel lua54-lgi \
    cairo-devel pango-devel gdk-pixbuf-devel librsvg-devel glib2-devel \
    libffi-devel pam-devel dejavu-fonts \
    lua54-busted google-noto-sans-cjk-fonts google-noto-sans-kr-mono-fonts \
    typelib-1_0-Gtk-3_0 \
    dbus-1 Mesa-dri bc wlr-randr grim foot xterm xwayland zsh sudo
# Run busted with Lua 5.4 because the distro's launcher follows the unversioned lua alternative.
RUN printf '#!/bin/sh\nexec lua5.4 /usr/bin/busted-5.4 "$@"\n' \
    > /usr/local/bin/busted && chmod +x /usr/local/bin/busted
