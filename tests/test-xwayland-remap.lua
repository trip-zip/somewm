---------------------------------------------------------------------------
--- Test: XWayland unmap/remap lifecycle (close-to-tray pattern)
--
-- Verifies that an XWayland client can unmap (close to tray) and remap
-- (re-open from tray) without crashing the compositor. This exercises the
-- full lifecycle: manage → unmanage → re-manage.
--
-- Regression test for: XWayland crash when Discord unmaps and remaps its
-- window (Lua reference released on unmap, nil push on remap).
--
-- NOTE: Requires visual mode (not headless) and python3.
---------------------------------------------------------------------------

local runner = require("_runner")
local x11_client = require("_x11_client")

-- Skip if headless (XWayland needs a display)
local function is_headless()
    local backend = os.getenv("WLR_BACKENDS")
    return backend == "headless"
end

if is_headless() then
    io.stderr:write("SKIP: XWayland remap test requires visual mode (HEADLESS=0)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Skip if python3 not available
local python3_check = os.execute("which python3 >/dev/null 2>&1")
if not python3_check then
    io.stderr:write("SKIP: python3 not available for X11 helper\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local awful = require("awful")

local CLASS = "xw_remap_test"
local helper_pid = nil
local my_client = nil

-- Track manage/unmanage events
local manage_count = 0
local unmanage_count = 0

client.connect_signal("manage", function(c)
    if x11_client.is_xwayland(c) and
       (c.class == CLASS or c.class == CLASS:lower()) then
        manage_count = manage_count + 1
        my_client = c
        io.stderr:write(string.format(
            "[TEST] manage #%d: class=%s valid=%s\n",
            manage_count, tostring(c.class), tostring(c.valid)
        ))
    end
end)

client.connect_signal("unmanage", function(c)
    if x11_client.is_xwayland(c) and
       (c.class == CLASS or c.class == CLASS:lower()) then
        unmanage_count = unmanage_count + 1
        io.stderr:write(string.format(
            "[TEST] unmanage #%d\n", unmanage_count
        ))
    end
end)

-- Resolve helper script path
local script_dir = debug.getinfo(1, "S").source:match("@(.*/)")
local helper_path = script_dir .. "helpers/x11_unmap_remap.py"

local steps = {
    -- Step 1: Spawn the X11 helper
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning X11 remap helper...\n")
            helper_pid = awful.spawn("python3 " .. helper_path .. " " .. CLASS)
            io.stderr:write(string.format("[TEST] Helper PID: %s\n", tostring(helper_pid)))

            if not helper_pid or type(helper_pid) ~= "number" or helper_pid <= 0 then
                error("Failed to spawn X11 helper: " .. tostring(helper_pid))
            end
        end
        return true
    end,

    -- Step 2: Wait for X11 client to appear (initial map)
    function(count)
        if manage_count >= 1 and my_client then
            io.stderr:write("[TEST] X11 client appeared\n")
            return true
        end

        if count > 80 then
            error("X11 client did not appear within timeout")
        end
        return nil
    end,

    -- Step 3: Verify initial client state
    function()
        assert(my_client.valid, "Client must be valid after initial map")
        assert(x11_client.is_xwayland(my_client), "Client must be XWayland")
        assert(my_client.class == CLASS or my_client.class == CLASS:lower(),
            "Client class mismatch: " .. tostring(my_client.class))
        assert(my_client.name ~= nil, "Client must have a name")

        io.stderr:write(string.format(
            "[TEST] PASS: initial client valid (class=%s name=%s)\n",
            my_client.class, my_client.name
        ))
        return true
    end,

    -- Step 4: Send SIGUSR1 to unmap the window (close-to-tray)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Sending SIGUSR1 (unmap)...\n")
            os.execute("kill -USR1 " .. helper_pid)
        end
        return true
    end,

    -- Step 5: Wait for unmanage signal
    function(count)
        if unmanage_count >= 1 then
            io.stderr:write("[TEST] Client unmanaged (close-to-tray)\n")
            return true
        end

        if count > 80 then
            error("Client did not unmanage within timeout")
        end
        return nil
    end,

    -- Step 6: Brief pause, then send SIGUSR2 to remap (re-open from tray)
    function(count)
        -- Wait a few ticks so the compositor fully processes the unmap
        if count < 5 then
            return nil
        end

        if count == 5 then
            io.stderr:write("[TEST] Sending SIGUSR2 (remap)...\n")
            os.execute("kill -USR2 " .. helper_pid)
        end
        return true
    end,

    -- Step 7: Wait for client to reappear (re-manage) — THE REGRESSION POINT
    -- If the Lua reference was improperly released on unmap, the compositor
    -- will crash here (SEGV or Lua panic) when mapnotify tries to push the
    -- client object.
    function(count)
        if manage_count >= 2 and my_client then
            io.stderr:write("[TEST] Client re-managed after remap\n")
            return true
        end

        if count > 80 then
            error("Client did not reappear after remap within timeout")
        end
        return nil
    end,

    -- Step 8: Verify re-managed client is fully valid
    -- These assertions catch the regression: if the Lua object was
    -- invalidated on unmap, accessing properties would crash or return nil.
    function()
        assert(my_client.valid,
            "REGRESSION: re-mapped client must be valid (Lua ref kept alive)")
        assert(x11_client.is_xwayland(my_client),
            "REGRESSION: re-mapped client must be XWayland (window ID restored)")
        assert(my_client.class == CLASS or my_client.class == CLASS:lower(),
            "REGRESSION: re-mapped client class mismatch: " .. tostring(my_client.class))
        assert(my_client.name ~= nil,
            "REGRESSION: re-mapped client name is nil (property_update crashed?)")

        -- Verify we can read various properties without crashing
        local _ = my_client.type
        local _ = my_client.pid
        local _ = my_client.screen

        io.stderr:write(string.format(
            "[TEST] PASS: re-mapped client valid (class=%s name=%s)\n",
            my_client.class, my_client.name
        ))

        assert(manage_count == 2, "Expected exactly 2 manage signals, got " .. manage_count)
        assert(unmanage_count == 1, "Expected exactly 1 unmanage signal, got " .. unmanage_count)

        return true
    end,

    -- Step 9: Cleanup — kill helper, verify final unmanage
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Killing helper for cleanup...\n")
            os.execute("kill " .. helper_pid .. " 2>/dev/null")
        end

        if unmanage_count >= 2 or count > 30 then
            io.stderr:write("[TEST] All XWayland remap tests PASSED\n")
            return true
        end

        return nil
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
