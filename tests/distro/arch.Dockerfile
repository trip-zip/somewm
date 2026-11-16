FROM archlinux:latest
ENV LUA_PKG=lua5.4 LUA_BIN=lua5.4
COPY arch-packages.txt /tmp/arch-packages.txt
RUN pacman -Syu --noconfirm --needed \
    $(cat /tmp/arch-packages.txt) lua54 lua54-lgi lua54-busted
# lua54-busted installs its script under a versioned LuaRocks directory without a launcher.
RUN printf '#!/bin/sh\nexec lua5.4 /usr/lib/luarocks/rocks-5.4/busted/*/bin/busted "$@"\n' \
    > /usr/local/bin/busted && chmod +x /usr/local/bin/busted
