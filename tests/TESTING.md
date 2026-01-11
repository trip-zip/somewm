# Writing Tests for somewm

## TDD Workflow

1. Write a failing test that defines the behavior you want
2. Run it: `make test-one TEST=tests/test-my-feature.lua`
3. Watch it fail (red)
4. Implement the feature in C or Lua
5. Run again, watch it pass (green)
6. ASAN catches any memory bugs automatically

## Running Tests

```bash
# Single test with ASAN + verbose output (TDD loop)
make test-one TEST=tests/test-focus.lua

# All tests with ASAN (default, catches memory bugs)
make test

# All tests without ASAN (faster, for quick smoke test)
make test-fast

# Unit tests only (busted, no compositor)
make test-unit
```

## Test Structure

Tests use a step-based runner. Each step is a function that returns:
- `true` - step passed, continue to next step
- `false` - step failed, test aborts with error
- `nil` - step incomplete, retry in 100ms (up to 2 seconds by default)

**IMPORTANT**: Every test must call `runner.run_steps(steps)` at the end. This eventually calls `awesome.quit()` to exit the compositor. Without this, the test will hang until timeout (10 seconds for `test-one`).

### Basic Template

```lua
local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

-- Skip if no terminal available for test clients
if not test_client.is_available() then
    io.stderr:write("SKIP: No terminal available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local steps = {
    -- Step 1: Spawn a client
    function(count)
        if count == 1 then
            test_client("my_app")
        end
        -- Wait for client to appear
        return utils.find_client_by_class("my_app") ~= nil
    end,

    -- Step 2: Verify behavior
    function()
        utils.assert_focus("my_app")
        utils.assert_client_count(1)
        return true
    end,
}

runner.run_steps(steps)
```

## Example: Defining Expected Behavior (TDD)

Write the test FIRST, defining what SHOULD happen:

```lua
local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local my_client

local steps = {
    -- Spawn client
    function(count)
        if count == 1 then
            test_client("my_app")
        end
        my_client = utils.find_client_by_class("my_app")
        return my_client ~= nil
    end,

    -- Define expected behavior: new client should get focus
    function()
        utils.assert_focus("my_app")
        return true
    end,

    -- Kill the client
    function(count)
        if count == 1 then
            my_client:kill()
        end
        return not my_client.valid
    end,

    -- Define expected behavior: focus should be nil after killing only client
    function()
        utils.assert_focus(nil)
        return true
    end,
}

runner.run_steps(steps)
```

## Verifying Signals (Not Just Final State)

Tests should verify signals fire correctly, not just that the final state is correct:

```lua
local utils = require("_utils")

-- Create a signal tracker
local tracker = utils.create_signal_tracker()
tracker:connect("focus")
tracker:connect("unfocus")

-- ... spawn clients, do operations ...

-- Verify signal counts
utils.assert_signal_count(tracker, "focus", 2)   -- Exactly 2 focus events
utils.assert_signal_count(tracker, "unfocus", 1) -- Exactly 1 unfocus event

-- Print summary for debugging
tracker:print_summary()
```

## Assertion Helpers

The `_utils.lua` module provides these assertion helpers:

```lua
-- Assert focus is on specific client class (or nil for no focus)
utils.assert_focus("my_app")
utils.assert_focus(nil)

-- Assert exact client count
utils.assert_client_count(3)

-- Assert signal emission count
utils.assert_signal_count(tracker, "focus", 2)

-- Generic assertion with message
utils.assert_true(condition, "error message")
```

## Debug Helpers

When tests fail, use these to understand state:

```lua
-- Print current focus
utils.debug_focused()

-- Print focus history
utils.debug_focus_history()       -- Brief
utils.debug_focus_history(true)   -- Verbose

-- Print all clients
utils.debug_clients()             -- Brief
utils.debug_clients(true)         -- With geometry
```

## Common Patterns

### Spawn and Wait

```lua
function(count)
    if count == 1 then
        test_client("my_class")
    end
    local c = utils.find_client_by_class("my_class")
    return c ~= nil
end
```

### Wait for Focus

```lua
utils.step_wait_for_focus("my_class")
```

### Kill All Clients

```lua
utils.step_kill_all_clients()
```

### Activate a Client

```lua
utils.activate_client(c)  -- Uses request::activate signal
```

## Test File Location

- Integration tests: `tests/test-*.lua`
- Unit tests: `spec/*_spec.lua`
- Test helpers: `tests/_runner.lua`, `tests/_client.lua`, `tests/_utils.lua`

## Debugging Failed Tests

```bash
# Run with verbose output
VERBOSE=1 ./tests/run-integration.sh tests/test-my-feature.lua

# Or use make target
make test-one TEST=tests/test-my-feature.lua
```

ASAN will print memory errors (use-after-free, buffer overflow, etc.) directly to stderr.
