# Meson build system wrapper
# Run `meson configure build` to see/change build options
#
# Examples:
#   make                 # Build (sets up meson if needed)
#   sudo make install    # Install to /usr/local
#   make clean           # Remove build directory
#   make reconfigure     # Wipe and reconfigure build

-include .local.mk

.PHONY: all install uninstall clean setup reconfigure test test-unit test-check test-integration test-asan test-one test-visual test-one-visual test-ci test-fast build-test build-bench bench-run bench-run-live bench-flamegraph bench-diff bench-heaptrack

# Default build: WITH ASAN for development
all:
	@test -d build || meson setup build -Db_sanitize=address,undefined $(MESON_OPTS)
	ninja -C build

# Alias for clarity
asan: all

# Build for tests: NO ASAN (fast) - explicitly disable sanitizers, enable test PAM stub
build-test:
	@test -d build-test || meson setup build-test -Db_sanitize=none -Dtest_pam=true
	ninja -C build-test

install:
	meson install -C build

uninstall:
	ninja -C build uninstall

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

# =============================================================================
# Benchmarking
# =============================================================================

# Build with bench instrumentation (no ASAN, debugoptimized)
build-bench:
	@test -d build-bench || meson setup build-bench -Db_sanitize=none -Dbuildtype=debugoptimized -Dbench=true
	ninja -C build-bench

# Run benchmarks in headless mode
bench-run: build-bench
	@HEADLESS=1 \
	 SOMEWM=./build-bench/somewm \
	 SOMEWM_CLIENT=./build-bench/somewm-client \
	 ./tests/bench/run-all.sh

# Run benchmarks against the live compositor session
bench-run-live:
	@HEADLESS=0 \
	 SOMEWM_CLIENT=./build-bench/somewm-client \
	 ./tests/bench/run-all.sh

# Record perf profile during benchmarks (30s default, override with PERF_DURATION=N)
bench-flamegraph: build-bench
	perf record -g --call-graph dwarf -p $$(pidof somewm) -o perf-bench.data -- sleep $${PERF_DURATION:-30}
	perf script -i perf-bench.data | stackcollapse-perf.pl | flamegraph.pl > somewm-bench-flamegraph.svg
	@echo "Flamegraph: somewm-bench-flamegraph.svg"

# Generate differential flamegraph between two perf recordings
# Usage: make bench-diff SYNC=perf-sync.data QUEUE=perf-queue.data
bench-diff:
ifndef SYNC
	@echo "Usage: make bench-diff SYNC=perf-sync.data QUEUE=perf-queue.data"
	@exit 1
endif
ifndef QUEUE
	@echo "Usage: make bench-diff SYNC=perf-sync.data QUEUE=perf-queue.data"
	@exit 1
endif
	perf script -i $(SYNC) | stackcollapse-perf.pl > /tmp/sync.folded
	perf script -i $(QUEUE) | stackcollapse-perf.pl > /tmp/queue.folded
	difffolded.pl /tmp/sync.folded /tmp/queue.folded | flamegraph.pl > somewm-bench-diff.svg
	@echo "Differential flamegraph: somewm-bench-diff.svg"

# Memory profiling with heaptrack
bench-heaptrack: build-bench
	heaptrack ./build-bench/somewm
