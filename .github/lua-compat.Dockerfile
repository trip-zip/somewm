# Image for the lua-compat job: every interpreter tests/check-lua-compat.sh
# requires. Separate from ci.Dockerfile because installing extra lua5.x
# packages into a test leg repoints the lua alternative and breaks busted.
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends luajit lua5.1 lua5.2 lua5.3 lua5.4 \
 && rm -rf /var/lib/apt/lists/*
