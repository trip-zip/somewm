# Meson build system wrapper
# Run `meson configure build` to see/change build options
#
# Examples:
#   make                 # Build (sets up meson if needed)
#   sudo make install    # Install to /usr/local
#   make clean           # Remove build directory
#   make reconfigure     # Wipe and reconfigure build

.PHONY: all install clean setup reconfigure test

all:
	@test -d build || meson setup build
	ninja -C build

install:
	meson install -C build

clean:
	rm -rf build

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
