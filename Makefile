# Meson build system wrapper
# Run `meson configure build` to see/change build options
#
# Examples:
#   make                 # Build (sets up meson if needed)
#   sudo make install    # Install to /usr/local
#   make clean           # Remove build directory
#   make reconfigure     # Wipe and reconfigure build

.PHONY: all install clean setup reconfigure asan

all:
	@test -d build || meson setup build
	ninja -C build

# Build with AddressSanitizer + UndefinedBehaviorSanitizer for debugging
asan:
	@test -d build-asan || meson setup build-asan -Db_sanitize=address,undefined
	ninja -C build-asan

install:
	meson install -C build

clean:
	rm -rf build build-asan

# Just setup (useful for IDE integration)
setup:
	meson setup build

# Wipe and reconfigure
reconfigure:
	rm -rf build
	meson setup build

# === Testing Targets ===

.PHONY: test test-unit test-integration test-compat test-all

test: test-unit

test-unit:
	@echo "Running unit tests..."
	@bash tests/run-unit.sh

test-integration: all
	@echo "Running integration tests..."
	@SOMEWM=build/somewm SOMEWM_CLIENT=build/somewm-client bash tests/run-integration.sh

test-compat: all
	@echo "Running AwesomeWM compatibility tests..."
	@SOMEWM=build/somewm SOMEWM_CLIENT=build/somewm-client bash tests/run-integration.sh tests/compatibility/test-*.lua

test-all: test-unit test-integration test-compat
