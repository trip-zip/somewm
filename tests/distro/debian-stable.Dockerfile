FROM debian:13
ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
ENV WRAP_MODE=nopromote
ENV LUA_PKG=lua5.3 LUA_BIN=lua5.3
COPY debian-packages.txt /tmp/debian-packages.txt
RUN apt-get update && apt-get install -y --no-install-recommends \
    $(cat /tmp/debian-packages.txt)
