FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
ENV WRAP_MODE=nopromote
ENV LUA_PKG=lua5.3 LUA_BIN=lua5.3
COPY debian-packages.txt /tmp/debian-packages.txt
# Ubuntu 24.04 has no libxcb-errors-dev package. wlroots makes it optional.
RUN apt-get update && apt-get install -y --no-install-recommends \
    $(sed '/^libxcb-errors-dev$/d' /tmp/debian-packages.txt)
