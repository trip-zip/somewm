---------------------------------------------------------------------------
--- Test: XWayland _NET_WM_WINDOW_TYPE detection
--
-- Verifies that XWayland clients with _NET_WM_WINDOW_TYPE set (without
-- transient_for) get the correct client.type in Lua. This exercises the
-- property_update_xwayland_properties() window type detection path.
--
-- Regression test for #337: XWayland dialogs tile instead of float because
-- _NET_WM_WINDOW_TYPE was never read for non-transient X11 clients.
---------------------------------------------------------------------------

local runner = require("_runner")
local x11_client = require("_x11_client")

-- Skip if headless (XWayland needs a display)
local function is_headless()
    local backend = os.getenv("WLR_BACKENDS")
    return backend == "headless"
end

if is_headless() then
    io.stderr:write("SKIP: XWayland dialog type test requires visual mode\n")
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

-- Resolve helper script path
local script_dir = debug.getinfo(1, "S").source:match("@(.*/)")
local helper_path = script_dir .. "helpers/x11_window_type.py"

-- Test cases: each entry is { class, window_type_arg, expected_lua_type }
local test_cases = {
    { class = "xw_type_dialog",  type_arg = "dialog",  expected = "dialog" },
    { class = "xw_type_splash",  type_arg = "splash",  expected = "splash" },
    { class = "xw_type_utility", type_arg = "utility", expected = "utility" },
    { class = "xw_type_normal",  type_arg = "normal",  expected = "normal" },
}

local current_test = 1
local helper_pid = nil
local my_client = nil
local manage_count = 0

client.connect_signal("request::manage", function(c)
    if current_test <= #test_cases then
        local tc = test_cases[current_test]
        if x11_client.is_xwayland(c) and c.class == tc.class then
            manage_count = manage_count + 1
            my_client = c
        end
    end
end)

-- Build steps: for each test case, spawn -> wait -> verify -> cleanup
local steps = {}

for i, tc in ipairs(test_cases) do
    -- Spawn helper with the window type
    steps[#steps + 1] = function(count)
        if count == 1 then
            current_test = i
            my_client = nil
            local cmd = string.format(
                "python3 %s %s %s", helper_path, tc.class, tc.type_arg
            )
            io.stderr:write(string.format(
                "[TEST] Spawning X11 window: class=%s type=%s\n",
                tc.class, tc.type_arg
            ))
            helper_pid = awful.spawn(cmd)
            if not helper_pid or type(helper_pid) ~= "number" or helper_pid <= 0 then
                error("Failed to spawn helper: " .. tostring(helper_pid))
            end
        end
        return true
    end

    -- Wait for client to appear
    steps[#steps + 1] = function(count)
        if my_client then
            return true
        end
        if count > 80 then
            error(string.format(
                "X11 client did not appear: class=%s", tc.class
            ))
        end
        return nil
    end

    -- Verify the type
    steps[#steps + 1] = function()
        assert(my_client.valid,
            string.format("client must be valid: class=%s", tc.class))
        assert(x11_client.is_xwayland(my_client),
            string.format("client must be XWayland: class=%s", tc.class))
        assert(my_client.type == tc.expected,
            string.format(
                "regression #337: expected type '%s', got '%s' for class=%s",
                tc.expected, tostring(my_client.type), tc.class
            ))

        io.stderr:write(string.format(
            "[TEST] PASS: class=%s type=%s (expected %s)\n",
            tc.class, my_client.type, tc.expected
        ))
        return true
    end

    -- Kill helper and wait for unmanage
    steps[#steps + 1] = function(count)
        if count == 1 then
            os.execute("kill " .. helper_pid .. " 2>/dev/null")
        end

        -- Wait for client to disappear or timeout
        if not my_client or not my_client.valid then
            return true
        end
        if count > 30 then
            os.execute("kill -9 " .. helper_pid .. " 2>/dev/null")
            return true
        end
        return nil
    end
end

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
