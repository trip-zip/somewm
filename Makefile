# Meson build system wrapper
# Run `meson configure build` to see/change build options
#
# Examples:
#   make                 # Build (sets up meson if needed)
#   sudo make install    # Install to /usr/local
#   make clean           # Remove build directory
#   make reconfigure     # Wipe and reconfigure build

-include .local.mk

.PHONY: all install clean setup reconfigure test asan

all:
	@test -d build || meson setup build $(MESON_OPTS)
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

# Run tests (placeholder - update when test framework is ready)
test:
	@echo "Tests not yet integrated with meson build"
