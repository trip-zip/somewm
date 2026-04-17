---------------------------------------------------------------------------
--- Test: drain on an invalidated object is safe
--
-- The event queue holds a registry ref to a userdata. Between queueing
-- and draining, the underlying C object can be invalidated (e.g. a
-- client is unmanaged). Drain must not crash on such events.
--
-- Scenario:
--   1. Queue a property::geometry on a client.
--   2. Immediately kill the client. client_unmanage() invalidates the
--      C-side (XDGShell: surface.xdg = NULL; X11: window = XCB_NONE).
--   3. The drain pass following this step must not crash. The queued
--      signal is expected to be silently dropped by client_checker()
--      returning false (common/luaobject.c luaA_object_emit_signal).
--
-- The test exercises the "registry ref outlives C state" path that is
-- otherwise untested. The fact that subsequent Lua steps run at all
-- proves drain survived.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local my_client
local handler_calls = 0

local steps = {
    function(count)
        if count == 1 then
            test_client("invalid_obj_test")
        end
        my_client = utils.find_client_by_class("invalid_obj_test")
        return my_client and true or nil
    end,

    function()
        my_client.floating = true
        my_client:geometry({x = 100, y = 100, width = 400, height = 300})
        my_client:connect_signal("property::geometry", function()
            handler_calls = handler_calls + 1
        end)
        return true
    end,

    function()
        handler_calls = 0
        return true
    end,

    -- Queue a property::geometry event, then invalidate the client
    -- before the drain that would fire it.
    function()
        my_client:geometry({x = 101, y = 100, width = 400, height = 300})
        -- Event is queued; handler has not fired.
        assert(handler_calls == 0,
            string.format(
                "regression: handler fired synchronously (got %d)",
                handler_calls))
        -- Kill the client. client_unmanage() runs synchronously on
        -- destroy; the Lua userdata survives via our registry ref,
        -- but the C object is invalid.
        my_client:kill()
        return true
    end,

    -- Drain happens here. Acceptable outcomes:
    --   A) handler fired before invalidation (handler_calls == 1)
    --   B) client_checker returned false, drain silently dropped
    --      the event (handler_calls == 0)
    -- The critical invariant is NO CRASH. If we got here, drain survived.
    function()
        io.stderr:write(string.format(
            "[TEST] Post-drain: handler_calls=%d, client.valid=%s\n",
            handler_calls,
            my_client and tostring(my_client.valid) or "nil"))
        assert(handler_calls <= 1,
            string.format(
                "regression: handler fired more than once (got %d)",
                handler_calls))
        return true
    end,

    -- Let several more drain cycles pass so client_unmanage's own
    -- queued signals (mouse::leave, list) flush through. If any of
    -- those crashed, we would not reach this step.
    function() return true end,
    function() return true end,
    function() return true end,

    function()
        io.stderr:write(
            "[TEST] PASS: drain survived an invalidated-object event\n")
        return true
    end,
}

runner.run_steps(steps)
