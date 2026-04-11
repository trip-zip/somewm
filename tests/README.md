# somewm Test Suite

This directory contains the test suite for somewm, including both unit tests and integration tests.

## Test Types

### Unit Tests (`spec/`)

Unit tests test individual Lua modules in isolation using the busted framework. These tests run quickly and don't require a running compositor.

**Location**: `spec/`
**Framework**: busted
**Runner**: `tests/run-unit.sh`

### Check Mode Tests (`tests/test-check-mode.sh`)

Check mode tests validate `somewm --check` behavior by creating temporary config fixtures and verifying output and exit codes. These tests don't start the compositor — they invoke the binary directly as a CLI tool.

**Location**: `tests/test-check-mode.sh`
**Framework**: Shell script with assert helpers
**Runner**: `make test-check`

Covers: X11 pattern detection, require scanning, comment filtering, syntax errors, report formatting, and exit codes.

### Integration Tests (`tests/`)

Integration tests run somewm in headless mode and execute test scenarios via IPC. These tests verify that the compositor behaves correctly as a whole system.

**Location**: `tests/test-*.lua`
**Framework**: Custom step-wise runner (`tests/_runner.lua`)
**Runner**: `tests/run-integration.sh`

## Running Tests

### Run All Tests

```bash
make test
```

### Run Unit Tests Only

```bash
make test-unit
```

Example output:
```
Running unit tests...
●●●●●●●●●●●●
12 successes / 0 failures / 0 errors / 0 pending : 0.001234 seconds
```

### Run Check Mode Tests Only

```bash
make test-check
```

### Run Integration Tests Only

```bash
make test-integration
```

Example output:
```
Running integration tests...
=== Running test-simple.lua ===
PASS: test-simple.lua

================================
Test Summary:
  Total:  1
  Passed: 1
  Failed: 0
================================
```

### Run Specific Test

```bash
# Unit test
busted spec/gears/math_spec.lua

# Integration test
bash tests/run-integration.sh tests/test-simple.lua
```

### Verbose Mode

```bash
VERBOSE=1 make test-unit
VERBOSE=1 make test-integration
```

## Writing Tests

### Writing Unit Tests

Create a new file in `spec/` matching the module structure:

```lua
-- spec/gears/string_spec.lua
local gstring = require("gears.string")

describe("gears.string", function()
    describe("startswith", function()
        it("returns true for matching prefix", function()
            assert.is_true(gstring.startswith("hello", "hel"))
        end)

        it("returns false for non-matching prefix", function()
            assert.is_false(gstring.startswith("hello", "bye"))
        end)
    end)
end)
```

See [busted documentation](https://olivinelabs.com/busted/) for more details.

### Writing Integration Tests

Create a new file `tests/test-*.lua` using the step-wise runner:

```lua
local runner = require("_runner")

local steps = {
    -- Step 1: Setup
    function()
        print("Step 1: Setup complete")
        return true  -- Move to next step
    end,

    -- Step 2: Perform action
    function(step_count)
        if step_count < 5 then
            return  -- Wait and retry (nil = retry)
        end
        print("Step 2: Action complete")
        return true  -- Success
    end,

    -- Step 3: Verify
    function()
        assert(condition, "verification message")
        print("Step 3: Verified")
        return true
    end,
}

runner.run_steps(steps)
```

**Step return values**:
- `true`: Step succeeded, move to next step
- `false`: Step failed, test fails
- `nil`: Step needs more time, will be retried

## Test Environment

### Unit Test Environment

Unit tests run with mocked globals defined in `spec/preload.lua`:
- `awesome` global with basic API
- `screen`, `client`, `mouse`, `root` mocks
- `beautiful` initialized with dummy theme

### Integration Test Environment

Integration tests run in an isolated environment:
- **Config**: Minimal test config (`tests/rc.lua`)
- **Backend**: Headless Wayland (`WLR_BACKENDS=headless`)
- **Runtime**: Isolated `XDG_RUNTIME_DIR` (won't conflict with running compositor)
- **IPC**: Communicates via `somewm-client eval`

## Test Infrastructure

### Unit Test Files

- `.busted` - Busted configuration
- `spec/preload.lua` - Test environment setup with mocks
- `spec/gears/` - Unit tests for gears modules
- `tests/run-unit.sh` - Unit test runner script

### Integration Test Files

- `tests/_runner.lua` - Step-wise test runner (from AwesomeWM)
- `tests/rc.lua` - Minimal test configuration
- `tests/test-*.lua` - Integration test files
- `tests/run-integration.sh` - Integration test runner script

## Troubleshooting

### Unit Tests

**Error: `module 'X' not found`**
- Check `LUA_PATH` includes `lua/` directory
- Verify module file exists at correct path

**Error: `attempt to call nil value`**
- Check if global is mocked in `spec/preload.lua`
- Add missing mock if needed

### Integration Tests

**Error: `Timeout waiting for somewm socket`**
- Check if `XDG_RUNTIME_DIR` is set (should be automatic)
- Check compositor logs for startup errors

**Error: `IPC connection test failed`**
- Compositor may have crashed during startup
- Check last 50 lines of log (shown in error output)

**Test hangs forever**
- Test steps might not be returning `true`
- Add `print()` statements to debug step execution
- Check test doesn't have infinite retry loop

**Memory leak warnings**
- LeakSanitizer warnings from system libraries (fontconfig/pango) are expected
- These are library-internal caches, not actual leaks
- Can be ignored for test purposes

## CI Integration

To run tests in CI:

```bash
# Install dependencies
pacman -S busted lua luajit

# Run tests
make test

# With coverage (unit tests only)
COVERAGE=1 make test-unit
```

## Adding Tests from AwesomeWM

To port AwesomeWM tests:

1. Copy test file from AwesomeWM's [`tests/`](https://github.com/awesomeWM/awesome/tree/master/tests) or [`spec/`](https://github.com/awesomeWM/awesome/tree/master/spec)
2. Update any X11-specific code to use Wayland equivalents
3. Remove client spawning tests (not yet supported in headless mode)
4. Run and fix any API differences

## Known Limitations

- No client spawning in headless mode yet (planned)
- Some AwesomeWM tests may need adaptation for Wayland
- D-Bus features not fully tested in headless mode

## Profiling

### Setup

Build the bench binary and install it as your compositor:

```bash
make build-bench
sudo cp build-bench/somewm /usr/local/bin/somewm
```

Then restart your session. When you're done profiling, switch back to the dev
build with `sudo make install`.

### Quick profile

```bash
make profile              # 30s C flamegraph
make profile-lua          # 30s C flamegraph + Lua function breakdown
make profile DURATION=60  # longer capture
```

Use the compositor normally during the capture. Open the resulting SVG in a
browser (click to zoom, Ctrl+F to search).

### Before/after comparison

```bash
# 1. Save a baseline
make profile-save LABEL=before-change

# 2. Make your changes, rebuild, restart
make build-bench && sudo cp build-bench/somewm /usr/local/bin/somewm
# ... restart session ...

# 3. Capture again and generate differential flamegraph
make profile-diff LABEL=before-change
```

The diff flamegraph shows red (more CPU) and blue (less CPU).

### Repeatable scripted workload

For controlled comparison without manual interaction, the scripted workload
drives a fixed sequence of tag switches, focus changes, geometry updates, and
property toggles:

```bash
tests/bench/profile-workload.sh --save before
# ... make changes, rebuild, restart ...
tests/bench/profile-workload.sh --diff before
```

### Lua profiling

`make profile-lua` captures both C and Lua profiles. You can also start/stop
the Lua profiler manually via IPC:

```bash
somewm-client eval "require('jit.p').start('Gli1', '/tmp/lua-profile.txt')"
# ... use compositor ...
somewm-client eval "require('jit.p').stop()"
cat /tmp/lua-profile.txt
```

The output shows stack frames with sample counts, compatible with FlameGraph
tools: `flamegraph.pl < /tmp/lua-profile.txt > lua-flamegraph.svg`

### Tips

- The profiler warns if the running binary was rebuilt since startup (causes
  unresolved C function names). Restart the compositor to fix.
- System library symbols (pixman, wlroots, cairo) are resolved via debuginfod.
- Profile the bench build, not the ASAN build. ASAN adds ~17% overhead that
  distorts the profile.

### Memory profiling

```bash
# Allocation tracking (start compositor under heaptrack)
heaptrack ./build-bench/somewm

# Or attach to running compositor
heaptrack --pid $(pidof somewm)
```

### Bench-instrumented build

Build with `make build-bench` to get per-stage frame timing, render phase timing,
C/Lua boundary crossing counts, and input latency accessible via `awesome.bench_stats()`:

```bash
make build-bench
./build-bench/somewm  # Run as your compositor

# Query stats from another terminal
somewm-client eval "
  local s = awesome.bench_stats()
  for k,v in pairs(s.stages) do
    print(k, string.format('avg=%.1fus p99=%.1fus', v.avg_us, v.p99_us))
  end
  print(string.format('render: avg=%.1fus p99=%.1fus', s.render.avg_us, s.render.p99_us))
  print('crossings/frame avg=' .. s.crossings_per_frame.avg)
"
```

### Interpreting perf output

The self-time view (`perf report --no-children`) shows where CPU is actually spent:

```bash
perf report --stdio --no-children --percent-limit 0.3 -g none
```

The children view (default) shows inclusive time, where percentages overlap because they
include callees. A function at 50% doesn't mean it uses 50% of CPU -- it means 50% of
samples had that function somewhere in the call stack.

## Future Work

- Add client spawning support (native Wayland clients like `foot`)
- Port full AwesomeWM test suite
- Add C-level tests (unit tests for C code)
- Add visual regression tests
- CI/CD integration

