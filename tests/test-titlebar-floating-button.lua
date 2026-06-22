---------------------------------------------------------------------------
-- The titlebar floating button toggles the client's floating state.
--
-- Regression: awful.client.floating.toggle was removed as deprecated, but
-- titlebar.widget.floatingbutton still passed it as the button's click action.
-- A nil action makes titlebar.widget.button install a no-op handler, so the
-- button silently did nothing. The fix wires the toggle inline (cl.floating =
-- not state), like the maximize/close buttons. This clicks the button via the
-- awful.button :trigger() (press+release, exactly what a real click runs) and
-- asserts the floating state flips, then flips back.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local test_client = require("_client")

if not test_client.is_available() then
    return runner.skip("no terminal available for test clients")
end

runner.run_async(function()
    test_client("tbfloat")
    local c = async.wait_for_client("tbfloat", 10)
    assert(c, "client did not appear")

    c.floating = false  -- deterministic starting point

    local widget = awful.titlebar.widget.floatingbutton(c)
    local btn = widget.buttons[1]
    assert(btn and btn._is_awful_button, "floating button must carry an awful.button")

    btn:trigger()
    assert(c.floating == true, "clicking the floating button must enable floating")

    btn:trigger()
    assert(c.floating == false, "clicking again must disable floating")

    c:kill()
    runner.done()
end)
