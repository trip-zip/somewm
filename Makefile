.POSIX:
.SUFFIXES:

include config.mk
-include config.local.mk

# flags for compiling
WLROOTS_VERSION = $(shell $(PKG_CONFIG) --modversion wlroots-0.19 2>/dev/null || $(PKG_CONFIG) --modversion wlroots 2>/dev/null || echo "unknown")

SOMECPPFLAGS = -I. -DWLR_USE_UNSTABLE -D_POSIX_C_SOURCE=200809L \
	-DVERSION=\"$(VERSION)\" \
	-DDATADIR=\"$(DATADIR)\" \
	-DSYSCONFDIR=\"$(SYSCONFDIR)\" \
	-DWLROOTS_VERSION=\"$(WLROOTS_VERSION)\" \
	-DWITH_DBUS \
	$(XWAYLAND)
SOMEDEVCFLAGS = -g -O1 -D_FORTIFY_SOURCE=2 -Wpedantic -Wall -Wextra \
	-Wdeclaration-after-statement -Wno-unused-parameter -Wshadow -Wunused-macros \
	-Werror=strict-prototypes -Werror=implicit -Werror=return-type \
	-Werror=incompatible-pointer-types -Wfloat-conversion -Werror=pedantic -Werror

# AddressSanitizer support (set ASAN=1 in config.mk or command line)
ifdef ASAN
SOMEDEVCFLAGS += -fsanitize=address,undefined -fno-omit-frame-pointer
LDFLAGS += -fsanitize=address,undefined
endif

# CFLAGS / LDFLAGS
PKGS      = wayland-server xkbcommon libinput dbus-1 libdrm $(XLIBS)
SOMECPPFLAGS += $(LUA_CFLAGS) $(CAIRO_CFLAGS) $(GLIB_CFLAGS)
SOMECFLAGS = `$(PKG_CONFIG) --cflags $(PKGS)` $(WLR_INCS) $(SOMECPPFLAGS) $(SOMEDEVCFLAGS) $(CFLAGS)
LDLIBS    = `$(PKG_CONFIG) --libs $(PKGS)` $(WLR_LIBS) $(LUA_LIBS) $(CAIRO_LIBS) $(GLIB_LIBS) -lm $(LIBS)

# Common utilities from AwesomeWM (now in common/ directory)
COMMONOBJS = common/luaclass.o common/luaobject.o common/lualib.o common/buffer.o common/util.o

# Lua object files (always required)
# Files at top level match AwesomeWM structure
LUAOBJS = luaa.o root.o mouse.o spawn.o keygrabber.o mousegrabber.o selection.o \
          objects/tag.o objects/client.o objects/screen.o objects/drawable.o \
          objects/drawin.o objects/signal.o objects/timer.o objects/key.o \
          objects/keybinding.o objects/awesome.o objects/button.o objects/wibox.o \
          objects/ipc.o objects/selection_getter.o objects/selection_acquire.o \
          objects/selection_transfer.o objects/selection_watcher.o \
          objects/systray.o

all: check-lgi somewm somewm-client

# Build-time LGI check - verifies lgi is installed for the detected Lua version
lgi-check: lgi-check.c
	$(CC) $(LUA_CFLAGS) -o $@ $< $(LUA_LIBS)

check-lgi: lgi-check
	@./lgi-check || exit 1

.PHONY: check-lgi

somewm: somewm.o somewm_api.o util.o ipc.o color.o draw.o stack.o banning.o ewmh.o window.o event.o strut.o property.o dbus.o $(COMMONOBJS) $(LUAOBJS)
	$(CC) somewm.o somewm_api.o util.o ipc.o color.o draw.o stack.o banning.o ewmh.o window.o event.o strut.o property.o dbus.o $(COMMONOBJS) $(LUAOBJS) $(SOMECFLAGS) $(LDFLAGS) $(LDLIBS) -o $@
somewm-client: somewm-client.o
	$(CC) somewm-client.o $(LDFLAGS) -o $@

# ASAN/UBSAN instrumented build for memory debugging
# Set ASAN=1 in config.mk to always build with ASAN
# Or use: make ASAN=1 (one-time build with ASAN)
#
# To run with ASAN: ASAN_OPTIONS=detect_leaks=0 ./somewm
# (detect_leaks=0 avoids false positives from Lua GC)
somewm.o: somewm.c client.h config.mk somewm_types.h objects/keygrabber.h cursor-shape-v1-protocol.h \
	pointer-constraints-unstable-v1-protocol.h wlr-layer-shell-unstable-v1-protocol.h \
	wlr-output-power-management-unstable-v1-protocol.h xdg-shell-protocol.h
somewm_api.o: somewm_api.c somewm_api.h somewm_types.h client.h
util.o: util.c util.h
ipc.o: ipc.c ipc.h util.h
color.o: color.c color.h util.h
draw.o: draw.c draw.h util.h
stack.o: stack.c stack.h somewm_types.h client.h util.h
property.o: property.c property.h objects/client.h objects/luaa.h globalconf.h
somewm-client.o: somewm-client.c
dbus.o: dbus.c dbus.h objects/luaa.h common/signal.h x11_compat.h
	$(CC) $(CPPFLAGS) $(SOMECFLAGS) -Wno-declaration-after-statement -Wno-float-conversion -Wno-missing-field-initializers -o $@ -c $<

# Top-level file dependencies (match AwesomeWM structure)
luaa.o: luaa.c objects/luaa.h objects/tag.h objects/client.h objects/screen.h objects/drawable.h objects/drawin.h objects/signal.h objects/timer.h objects/spawn.h objects/keybinding.h objects/keygrabber.h objects/awesome.h objects/root.h objects/button.h objects/selection_getter.h objects/selection_acquire.h objects/selection_transfer.h objects/selection_watcher.h selection.h globalconf.h window.h dbus.h
root.o: root.c objects/root.h objects/luaa.h objects/keybinding.h objects/key.h objects/button.h somewm_api.h globalconf.h objects/drawable.h
mouse.o: mouse.c objects/mouse.h objects/luaa.h somewm_api.h somewm_types.h objects/client.h objects/screen.h
spawn.o: spawn.c objects/spawn.h objects/luaa.h objects/signal.h
keygrabber.o: keygrabber.c objects/keygrabber.h somewm_types.h
mousegrabber.o: mousegrabber.c objects/mousegrabber.h somewm_types.h globalconf.h somewm_api.h

# Objects remaining in objects/ directory
objects/tag.o: objects/tag.c objects/tag.h objects/luaa.h somewm_api.h
objects/client.o: objects/client.c objects/client.h objects/luaa.h somewm_api.h somewm_types.h
objects/screen.o: objects/screen.c objects/screen.h objects/drawin.h objects/luaa.h objects/signal.h somewm_api.h somewm_types.h util.h
objects/drawable.o: objects/drawable.c objects/drawable.h objects/luaa.h util.h
objects/drawin.o: objects/drawin.c objects/drawin.h objects/drawable.h objects/screen.h objects/luaa.h objects/signal.h somewm_api.h util.h
objects/signal.o: objects/signal.c objects/signal.h objects/luaa.h objects/screen.h somewm_types.h
objects/timer.o: objects/timer.c objects/timer.h objects/luaa.h somewm_api.h
objects/key.o: objects/key.c objects/key.h common/luaclass.h common/luaobject.h objects/luaa.h util.h
objects/keybinding.o: objects/keybinding.c objects/keybinding.h objects/luaa.h somewm_api.h
objects/awesome.o: objects/awesome.c objects/awesome.h objects/luaa.h somewm_api.h
objects/button.o: objects/button.c objects/button.h common/luaclass.h common/luaobject.h objects/luaa.h objects/drawin.h somewm_api.h util.h
objects/wibox.o: objects/wibox.c objects/wibox.h objects/luaa.h somewm_api.h somewm_types.h
objects/ipc.o: objects/ipc.c objects/ipc.h objects/luaa.h
objects/systray.o: objects/systray.c objects/systray.h common/luaclass.h common/luaobject.h objects/luaa.h globalconf.h util.h

# Selection module (AwesomeWM clipboard API)
selection.o: selection.c selection.h globalconf.h common/lualib.h
objects/selection_getter.o: objects/selection_getter.c objects/selection_getter.h common/luaobject.h common/lualib.h globalconf.h
objects/selection_acquire.o: objects/selection_acquire.c objects/selection_acquire.h objects/selection_transfer.h common/luaobject.h common/lualib.h globalconf.h
objects/selection_transfer.o: objects/selection_transfer.c objects/selection_transfer.h common/luaobject.h common/lualib.h globalconf.h
objects/selection_watcher.o: objects/selection_watcher.c objects/selection_watcher.h common/luaobject.h common/lualib.h globalconf.h

# Common library dependencies
common/luaclass.o: common/luaclass.c common/luaclass.h common/luaobject.h common/signal.h objects/luaa.h util.h
common/luaobject.o: common/luaobject.c common/luaobject.h common/luaclass.h objects/signal.h util.h
common/util.o: common/util.c util.h

# wayland-scanner is a tool which generates C headers and rigging for Wayland
# protocols, which are specified in XML. wlroots requires you to rig these up
# to your build system yourself and provide them in the include path.
WAYLAND_SCANNER   = `$(PKG_CONFIG) --variable=wayland_scanner wayland-scanner`
WAYLAND_PROTOCOLS = `$(PKG_CONFIG) --variable=pkgdatadir wayland-protocols`

cursor-shape-v1-protocol.h:
	$(WAYLAND_SCANNER) enum-header \
		$(WAYLAND_PROTOCOLS)/staging/cursor-shape/cursor-shape-v1.xml $@
pointer-constraints-unstable-v1-protocol.h:
	$(WAYLAND_SCANNER) enum-header \
		$(WAYLAND_PROTOCOLS)/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml $@
wlr-layer-shell-unstable-v1-protocol.h:
	$(WAYLAND_SCANNER) enum-header \
		protocols/wlr-layer-shell-unstable-v1.xml $@
wlr-output-power-management-unstable-v1-protocol.h:
	$(WAYLAND_SCANNER) server-header \
		protocols/wlr-output-power-management-unstable-v1.xml $@
xdg-shell-protocol.h:
	$(WAYLAND_SCANNER) server-header \
		$(WAYLAND_PROTOCOLS)/stable/xdg-shell/xdg-shell.xml $@

clean:
	rm -f somewm somewm-client lgi-check *.o common/*.o objects/*.o *-protocol.h

dist: clean
	mkdir -p somewm-$(VERSION)
	cp -R LICENSE* Makefile CHANGELOG.md README.md client.h \
		config.mk protocols somewm.1 somewm.c somewm_types.h somewm_api.h somewm_api.c \
		util.c util.h somewm.desktop \
		somewm-$(VERSION)
	tar -caf somewm-$(VERSION).tar.gz somewm-$(VERSION)
	rm -rf somewm-$(VERSION)

install: somewm somewm-client
	mkdir -p $(DESTDIR)$(PREFIX)/bin
	rm -f $(DESTDIR)$(PREFIX)/bin/somewm
	cp -f somewm $(DESTDIR)$(PREFIX)/bin
	chmod 755 $(DESTDIR)$(PREFIX)/bin/somewm
	cp -f somewm-client $(DESTDIR)$(PREFIX)/bin
	chmod 755 $(DESTDIR)$(PREFIX)/bin/somewm-client
	mkdir -p $(DESTDIR)$(MANDIR)/man1
	cp -f somewm.1 $(DESTDIR)$(MANDIR)/man1
	chmod 644 $(DESTDIR)$(MANDIR)/man1/somewm.1
	mkdir -p $(DESTDIR)$(DATADIR)/wayland-sessions
	cp -f somewm.desktop $(DESTDIR)$(DATADIR)/wayland-sessions/somewm.desktop
	chmod 644 $(DESTDIR)$(DATADIR)/wayland-sessions/somewm.desktop
	mkdir -p $(DESTDIR)$(DATADIR)/somewm/lua
	cp -r lua/* $(DESTDIR)$(DATADIR)/somewm/lua/
	chmod 755 $(DESTDIR)$(DATADIR)/somewm/lua
	find $(DESTDIR)$(DATADIR)/somewm/lua -type d -exec chmod 755 {} \;
	find $(DESTDIR)$(DATADIR)/somewm/lua -type f -exec chmod 644 {} \;
	mkdir -p $(DESTDIR)$(DATADIR)/somewm
	cp -f somewmrc.lua $(DESTDIR)$(DATADIR)/somewm/somewmrc.lua
	chmod 644 $(DESTDIR)$(DATADIR)/somewm/somewmrc.lua
	mkdir -p $(DESTDIR)$(DATADIR)/somewm/themes
	cp -r themes/* $(DESTDIR)$(DATADIR)/somewm/themes/
	find $(DESTDIR)$(DATADIR)/somewm/themes -type d -exec chmod 755 {} \;
	find $(DESTDIR)$(DATADIR)/somewm/themes -type f -exec chmod 644 {} \;
	mkdir -p $(DESTDIR)$(DATADIR)/somewm/icons
	cp -r icons/* $(DESTDIR)$(DATADIR)/somewm/icons/
	find $(DESTDIR)$(DATADIR)/somewm/icons -type f -exec chmod 644 {} \;
	mkdir -p $(DESTDIR)$(SYSCONFDIR)/xdg/somewm
	cp -f somewmrc.lua $(DESTDIR)$(SYSCONFDIR)/xdg/somewm/rc.lua
	chmod 644 $(DESTDIR)$(SYSCONFDIR)/xdg/somewm/rc.lua

install-local:
	$(MAKE) clean
	$(MAKE) somewm somewm-client DATADIR=$(HOME)/.local/share SYSCONFDIR=$(HOME)/.local/etc
	$(MAKE) install PREFIX=$(HOME)/.local DATADIR=$(HOME)/.local/share SYSCONFDIR=$(HOME)/.local/etc
install-session:
	mkdir -p /usr/share/wayland-sessions
	cp -f somewm.desktop /usr/share/wayland-sessions/somewm.desktop
	chmod 644 /usr/share/wayland-sessions/somewm.desktop

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/somewm $(DESTDIR)$(PREFIX)/bin/somewm-client \
		$(DESTDIR)$(MANDIR)/man1/somewm.1 \
		$(DESTDIR)$(DATADIR)/wayland-sessions/somewm.desktop \
		$(DESTDIR)$(DATADIR)/somewm/somewmrc.lua \
		$(DESTDIR)$(SYSCONFDIR)/xdg/somewm/rc.lua
	rm -rf $(DESTDIR)$(DATADIR)/somewm/lua
	rm -rf $(DESTDIR)$(DATADIR)/somewm/themes
	rm -rf $(DESTDIR)$(DATADIR)/somewm/icons
	rmdir $(DESTDIR)$(DATADIR)/somewm 2>/dev/null || true
	rmdir $(DESTDIR)$(SYSCONFDIR)/xdg/somewm 2>/dev/null || true

uninstall-local:
	$(MAKE) uninstall PREFIX=$(HOME)/.local DATADIR=$(HOME)/.local/share SYSCONFDIR=$(HOME)/.local/etc

uninstall-session:
	rm -f /usr/share/wayland-sessions/somewm.desktop

.SUFFIXES: .c .o
.c.o:
	$(CC) $(CPPFLAGS) $(SOMECFLAGS) -o $@ -c $<

# === Testing Targets ===

.PHONY: test test-unit test-integration test-compat test-compat-verbose test-all

test: test-unit

test-unit:
	@echo "Running unit tests..."
	@bash tests/run-unit.sh

test-integration:
	@echo "Running integration tests..."
	@bash tests/run-integration.sh

test-compat:
	@echo "Running AwesomeWM compatibility tests..."
	@bash tests/run-integration.sh tests/compatibility/test-*.lua

test-compat-verbose:
	@echo "Running AwesomeWM compatibility tests (verbose)..."
	@VERBOSE=1 bash tests/run-integration.sh tests/compatibility/test-*.lua

test-all: test-unit test-integration test-compat

check: test

# Coverage (optional)
coverage:
	@echo "Running tests with coverage..."
	@COVERAGE=1 bash tests/run-unit.sh
	@echo "Coverage report generated in luacov.report.out"
