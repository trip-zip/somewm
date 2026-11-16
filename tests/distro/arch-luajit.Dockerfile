FROM archlinux:latest
ENV LUA_PKG=luajit LUA_BIN=luajit
COPY arch-packages.txt /tmp/arch-packages.txt
RUN pacman -Syu --noconfirm --needed \
    $(cat /tmp/arch-packages.txt) luajit lua51-lgi lua51-busted
# lua51-busted installs its script under a versioned LuaRocks directory without a launcher.
RUN printf '#!/bin/sh\nexec luajit /usr/lib/luarocks/rocks-5.1/busted/*/bin/busted "$@"\n' \
    > /usr/local/bin/busted && chmod +x /usr/local/bin/busted
