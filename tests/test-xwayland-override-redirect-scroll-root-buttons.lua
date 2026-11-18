---------------------------------------------------------------------------
--- Scrolling over an X11 override_redirect window that does not want focus,
--- such as a popup menu, fired the root scroll bindings.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local gears = require("gears")
local utils = require("_utils")

if utils.is_headless() then
    return runner.skip("XWayland tests require visual mode (HEADLESS=0)")
end
if not os.execute("which python3 >/dev/null 2>&1") then
    return runner.skip("python3 not available for X11 helper")
end
local POINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not POINTER then return runner.skip("test helpers not built") end

local script_dir = debug.getinfo(1, "S").source:match("@(.*/)")
local HELPER = script_dir .. "helpers/x11_override_redirect.py"

local function scroll(x, y, dir)
    local s = screen[1].geometry
    local done, status, err
    awful.spawn.easy_async({ POINTER, "scroll", tostring(x - s.x), tostring(y - s.y),
        tostring(s.width), tostring(s.height), dir }, function(_, stderr, _, code)
        done, status, err = true, code, stderr
    end)
    assert(async.wait_for_condition(function() return done end, 5, 0.01),
        "virtual pointer scroll timed out")
    assert(status == 0, "virtual pointer failed: " .. tostring(err))
end

runner.run_async(function()
    local scrolls = 0
    local original_buttons = root.buttons()
    root.buttons(gears.table.join(
        awful.button({}, 4, function() scrolls = scrolls + 1 end),
        awful.button({}, 5, function() scrolls = scrolls + 1 end)))

    local s = screen[1].geometry
    local pid = awful.spawn({ "python3", HELPER, "or_scroll_popup",
        tostring(s.x + 300), tostring(s.y + 200), "200", "150", "POPUP_MENU" })
    assert(type(pid) == "number", "failed to spawn X11 helper: " .. tostring(pid))
    local popup
    assert(async.wait_for_condition(function()
        for _, c in ipairs(client.get()) do
            if c.name == "or_scroll_popup" then popup = c end
        end
        return popup ~= nil
    end, 10, 0.05), "override_redirect popup did not appear")

    -- Control: a scroll over the empty desktop reaches the root bindings.
    scroll(s.x + 100, s.y + 100, "down")
    assert(async.wait_for_condition(function() return scrolls == 1 end, 3, 0.01),
        "scroll over the desktop must trigger root buttons")

    local g = popup:geometry()
    local x, y = g.x + g.width / 2, g.y + g.height / 2
    scroll(x, y, "down")
    scroll(x, y, "up")
    -- A desktop scroll afterwards proves the popup scrolls were processed.
    scroll(s.x + 100, s.y + 100, "up")
    assert(async.wait_for_condition(function() return scrolls >= 2 end, 3, 0.01),
        "second desktop scroll did not arrive")
    assert(scrolls == 2, "scroll over an override_redirect popup triggered root buttons ("
        .. scrolls .. " root scrolls, expected 2)")

    awesome.kill(pid, 15)
    assert(async.wait_for_condition(function() return not popup.valid end, 5, 0.05),
        "X11 helper did not exit")
    root.buttons = original_buttons
    runner.done()
end)
