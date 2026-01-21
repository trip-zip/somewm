local timer = require("gears.timer")
local gtable = require("gears.table")

local runner = {
    quit_awesome_on_error = os.getenv('TEST_PAUSE_ON_ERRORS') ~= '1',
}

-- Async module for coroutine-based tests (loaded lazily)
local async = nil

local verbose = os.getenv('VERBOSE') == '1'

-- Persistent mode: don't quit compositor after test
-- Set by shell script or test harness
local persistent_mode = false

--- Enable persistent mode (don't quit after test completion).
-- Call this before running tests in persistent mode.
function runner.set_persistent(enabled)
    persistent_mode = enabled
end

--- Check if running in persistent mode.
-- @treturn boolean True if persistent mode is enabled
function runner.is_persistent()
    return persistent_mode
end

-- Was the runner started already?
local running = false

-- This is used if a test causes errors before starting the runner
timer.start_new(1, function()
    if not running then
        io.stderr:write("Error: run_steps() was never called.\n")
        if not runner.quit_awesome_on_error then
            io.stderr:write("Keeping awesome open...\n")
            return  -- keep awesome open on error.
        end
        awesome.quit()
    end
end)

runner.step_kill_clients = function(step)
    if step == 1 then
        for _,c in ipairs(client.get()) do
            c:kill()
        end
    end
    if #client.get() == 0 then
        return true
    end
end

--- Print a message if verbose mode is enabled.
-- @tparam string message The message to print.
function runner.verbose(message)
    if verbose then
        io.stderr:write(message .. "\n")
    end
end

--- When using run_direct(), this function indicates that the test is now done.
-- @tparam[opt=nil] string message An error message explaining the test failure, if it failed.
function runner.done(message)
    if message then
        io.stderr:write("Error: " .. message .. "\n")
        if not runner.quit_awesome_on_error then
            io.stderr:write("Keeping awesome open...\n")
            return
        end
    end

    local client_count = #client.get()
    if client_count > 0 then
        io.stderr:write(string.format(
            "NOTE: there were %d clients left after the test.\n", client_count))

        -- Remove any clients (unless in persistent mode where _state.reset handles this)
        if not persistent_mode then
            for _,c in ipairs(client.get()) do
                c:kill()
            end
        end
    end

    if not message then
        io.stderr:write("Test finished successfully.\n")
    end

    -- In persistent mode, don't quit - just reset the running flag
    if persistent_mode then
        running = false
        return
    end

    awesome.quit()
end

--- This function is called to indicate that a test does not use the run_steps()
-- facility, but instead runs something else directly.
function runner.run_direct()
    -- In persistent mode, reset running flag to allow multiple tests
    if persistent_mode and running then
        running = false
    end
    assert(not running, "API abuse: Test was started twice")
    running = true
end

--- Reset runner state for a new test (used in persistent mode).
-- This is called by state.reset() to prepare for the next test.
function runner.reset_state()
    running = false
    if async then
        async._set_coroutine(nil)
    end
end

--- Start some step-wise tests. The given steps are called in order until all
-- succeeded. Each step is a function that can return true/false to indicate
-- success/failure, but can also return nothing if it needs to be called again
-- later.
function runner.run_steps(steps, options)
    options = gtable.crush({
        kill_clients=true,
        wait_per_step=2,  -- how long to wait per step in seconds.
    }, options or {})
    -- Setup timer/timeout to limit waiting for signal and quitting awesome.
    local t = timer({timeout=0})
    local wait=options.wait_per_step / 0.1
    local step=1
    local step_count=0
    runner.run_direct()

    if options.kill_clients then
        -- Add a final step to kill all clients and wait for them to finish.
        -- Ref: https://github.com/awesomeWM/awesome/pull/1904#issuecomment-312793006
        steps[#steps + 1] = runner.step_kill_clients
    end

    t:connect_signal("timeout", function() timer.delayed_call(function()
        local step_func = steps[step]
        step_count = step_count + 1
        local step_as_string = step..'/'..#steps..' (@'..step_count..')'

        io.flush()  -- for "tail -f".
        runner.verbose(string.format('Running step %s..\n', step_as_string))

        -- Call the current step's function.
        local success, result = xpcall(function()
            return step_func(step_count)
        end, debug.traceback)

        if not success then
            runner.done('running function for step '
                        ..step_as_string..': '..tostring(result)..'!')
            t:stop()
        elseif result then
            -- true: test succeeded.
            if step < #steps then
                -- Next step.
                step = step+1
                step_count = 0
                wait = options.wait_per_step / 0.1
                t.timeout = 0
                t:again()
            else
                -- All steps finished, we are done.
                runner.done()
            end
        else
            -- Append filename/lnum of failed step function.
            local step_info = debug.getinfo(step_func)
            local step_loc = string.format("%s:%d", step_info["short_src"], step_info["linedefined"])
            step_as_string = step_as_string .. " ("..step_loc..")"

            if result == false then
                runner.done("Step "..step_as_string.." failed (returned false).")
            else
                -- No result yet, run this step again.
                wait = wait-1
                if wait > 0 then
                    t.timeout = 0.1
                    t:again()
                else
                    runner.done("timeout waiting for signal in step "
                                ..step_as_string..".")
                    t:stop()
                end
            end
        end
    end) end)
    t:start()
end

--- Run a test using async/coroutine style.
-- This provides a cleaner API than run_steps() for tests that need
-- to wait for events. The test function runs as a coroutine and can
-- use async.wait_for_* functions to yield until events occur.
--
-- @tparam function test_fn The test function to run
-- @tparam[opt] table options Options table
-- @tparam[opt=true] boolean options.kill_clients Kill all clients after test
-- @usage
--     runner.run_async(function()
--         test_client("myapp")
--         local c = async.wait_for_client("myapp", 5)
--         assert(c, "Client did not appear")
--         runner.done()
--     end)
function runner.run_async(test_fn, options)
    options = gtable.crush({
        kill_clients = true,
    }, options or {})

    runner.run_direct()

    -- Load async module if not already loaded
    if not async then
        async = require("_async")
    end

    -- Wrap test function to handle completion
    local wrapped = function()
        local success, err = xpcall(test_fn, debug.traceback)
        if not success then
            runner.done("Test error: " .. tostring(err))
        end
        -- Note: test_fn should call runner.done() on success
    end

    -- Create coroutine for the test
    local co = coroutine.create(wrapped)

    -- Register with async module so wait_for_* functions can resume it
    async._set_coroutine(co)

    -- Start the coroutine (uses delayed_call to ensure event loop is running)
    timer.delayed_call(function()
        local ok, err = coroutine.resume(co)
        if not ok then
            runner.done("Failed to start test: " .. tostring(err))
        end
    end)
end

return runner

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
