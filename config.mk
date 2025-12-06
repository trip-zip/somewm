_VERSION = 0.8-dev
VERSION  = `git describe --tags --dirty 2>/dev/null || echo $(_VERSION)`

PKG_CONFIG = pkg-config

# paths
PREFIX = /usr/local
MANDIR = $(PREFIX)/share/man
DATADIR = $(PREFIX)/share
SYSCONFDIR = $(PREFIX)/etc

WLR_INCS = `$(PKG_CONFIG) --cflags wlroots-0.19`
WLR_LIBS = `$(PKG_CONFIG) --libs wlroots-0.19`

# Lua integration - REQUIRED (not optional)
# Try LuaJIT first (5.1 compatible + JIT), then fall back to Lua 5.4, 5.3, 5.2, 5.1
LUA_PKG := $(shell \
	if pkg-config --exists luajit 2>/dev/null; then \
		echo luajit; \
	elif pkg-config --exists lua5.4 2>/dev/null; then \
		echo lua5.4; \
	elif pkg-config --exists lua-5.4 2>/dev/null; then \
		echo lua-5.4; \
	elif pkg-config --exists lua5.3 2>/dev/null; then \
		echo lua5.3; \
	elif pkg-config --exists lua-5.3 2>/dev/null; then \
		echo lua-5.3; \
	elif pkg-config --exists lua5.2 2>/dev/null; then \
		echo lua5.2; \
	elif pkg-config --exists lua-5.2 2>/dev/null; then \
		echo lua-5.2; \
	elif pkg-config --exists lua5.1 2>/dev/null; then \
		echo lua5.1; \
	elif pkg-config --exists lua-5.1 2>/dev/null; then \
		echo lua-5.1; \
	elif pkg-config --exists lua 2>/dev/null; then \
		echo lua; \
	else \
		echo ""; \
	fi)

# Fail build if Lua not found
ifeq ($(LUA_PKG),)
    $(error Lua (5.1-5.4 or LuaJIT) is required but not found. Install lua development packages.)
endif

LUA_CFLAGS := $(shell pkg-config --cflags $(LUA_PKG))
LUA_LIBS   := $(shell pkg-config --libs $(LUA_PKG))

# Cairo, Pango, and GdkPixbuf for widget rendering (required for Lua widget system)
CAIRO_CFLAGS := $(shell pkg-config --cflags cairo cairo-xlib pangocairo gdk-pixbuf-2.0 2>/dev/null)
CAIRO_LIBS := $(shell pkg-config --libs cairo cairo-xlib pangocairo gdk-pixbuf-2.0 2>/dev/null)

# GLib for main loop integration (required for gears.timer via LGI)
GLIB_CFLAGS := $(shell pkg-config --cflags glib-2.0 2>/dev/null)
GLIB_LIBS := $(shell pkg-config --libs glib-2.0 2>/dev/null)

# Allow using an alternative wlroots installation
# This has to have all the includes required by wlroots, e.g:
# Assuming wlroots git repo is "${PWD}/wlroots" and you only ran "meson setup build && ninja -C build"
#WLR_INCS = -I/usr/include/pixman-1 -I/usr/include/elogind -I/usr/include/libdrm \
#	-I$(PWD)/wlroots/include
# Set -rpath to avoid using the wrong library.
#WLR_LIBS = -Wl,-rpath,$(PWD)/wlroots/build -L$(PWD)/wlroots/build -lwlroots-0.19

# Assuming you ran "meson setup --prefix ${PWD}/0.19 build && ninja -C build install"
#WLR_INCS = -I/usr/include/pixman-1 -I/usr/include/elogind -I/usr/include/libdrm \
#	-I$(PWD)/wlroots/0.19/include/wlroots-0.19
#WLR_LIBS = -Wl,-rpath,$(PWD)/wlroots/0.19/lib64 -L$(PWD)/wlroots/0.19/lib64 -lwlroots-0.19

XWAYLAND =
XLIBS =
# Uncomment to build XWayland support
XWAYLAND = -DXWAYLAND
XLIBS = xcb xcb-icccm

# somewm uses C99 features, but wlroots' headers use anonymous unions (C11).
# To avoid warnings about them, we do not use -std=c99 and instead of using the
# gmake default 'CC=c99', we use cc.
CC = cc
