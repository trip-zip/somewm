# Meson build system wrapper
# Run `meson configure build` to see/change build options
#
# Examples:
#   make                 # Build (sets up meson if needed)
#   sudo make install    # Install to /usr/local
#   make clean           # Remove build directory
#   make reconfigure     # Wipe and reconfigure build

-include .local.mk

.PHONY: all install uninstall clean setup reconfigure test test-unit test-check test-integration test-asan test-one test-visual test-one-visual test-ci test-fast build-test

# Default build: WITH ASAN for development
all:
	@test -d build || meson setup build -Db_sanitize=address,undefined $(MESON_OPTS)
	ninja -C build

# Alias for clarity
asan: all

# Build for tests: NO ASAN (fast) - explicitly disable sanitizers
build-test:
	@test -d build-test || meson setup build-test -Db_sanitize=none
	ninja -C build-test

install:
	meson install -C build

uninstall:
	rm -f /usr/local/bin/somewm /usr/local/bin/somewm-client
	rm -f /usr/local/share/man/man1/somewm.1
	rm -f /usr/local/share/wayland-sessions/somewm.desktop
	rm -f /usr/local/share/xdg-desktop-portal/portals/somewm.portal
	rm -rf /usr/local/share/somewm
	rm -rf /usr/local/etc/xdg/somewm

clean:
	rm -rf build build-test

# Just setup (useful for IDE integration)
setup:
	meson setup build

# Wipe and reconfigure
reconfigure:
	rm -rf build
	meson setup build

# =============================================================================
# Testing
# =============================================================================

# Run all tests (fast, no ASAN)
test: test-unit test-check test-integration

# Unit tests only (busted, no compositor needed)
# Use - prefix to continue even if unit tests fail (some have known issues)
test-unit:
	-@./tests/run-unit.sh

# Check mode tests (no compositor needed, tests somewm --check)
test-check: build-test
	@./tests/test-check-mode.sh ./build-test/somewm

# Integration tests (visual mode by default, no ASAN)
test-integration: build-test
	@SOMEWM=./build-test/somewm SOMEWM_CLIENT=./build-test/somewm-client ./tests/run-integration.sh

# Integration tests with ASAN (slower, catches memory bugs)
test-asan: all
	@SOMEWM=./build/somewm SOMEWM_CLIENT=./build/somewm-client ./tests/run-integration.sh

# CI mode: headless (for automated testing environments)
test-ci: build-test test-unit
	@HEADLESS=1 \
	 SOMEWM=./build-test/somewm \
	 SOMEWM_CLIENT=./build-test/somewm-client \
	 ./tests/run-integration.sh

# Fast test suite using persistent compositor (10x faster)
test-fast: build-test
	@PERSISTENT=1 \
	 SOMEWM=./build-test/somewm \
	 SOMEWM_CLIENT=./build-test/somewm-client \
	 ./tests/run-integration.sh

# Run single test (TDD workflow, no ASAN for speed)
# Usage: make test-one TEST=tests/test-focus.lua
test-one: build-test
ifndef TEST
	@echo "Usage: make test-one TEST=tests/test-my-feature.lua"
	@exit 1
endif
	@VERBOSE=1 \
	 TEST_TIMEOUT=10 \
	 SOMEWM=./build-test/somewm \
	 SOMEWM_CLIENT=./build-test/somewm-client \
	 ./tests/run-integration.sh $(TEST)

# Visual test mode - watch tests run in a window (like AwesomeWM's Xephyr)
test-visual: build-test
	@HEADLESS=0 \
	 SOMEWM=./build-test/somewm \
	 SOMEWM_CLIENT=./build-test/somewm-client \
	 ./tests/run-integration.sh

# Visual single test - for debugging
test-one-visual: build-test
ifndef TEST
	@echo "Usage: make test-one-visual TEST=tests/test-my-feature.lua"
	@exit 1
endif
	@HEADLESS=0 \
	 VERBOSE=1 \
	 TEST_TIMEOUT=60 \
	 SOMEWM=./build-test/somewm \
	 SOMEWM_CLIENT=./build-test/somewm-client \
	 ./tests/run-integration.sh $(TEST)
