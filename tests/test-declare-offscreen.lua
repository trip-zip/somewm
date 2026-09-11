---------------------------------------------------------------------------
-- Test: a box that has moved off its output is still declared
--
-- Boxes enter the Clay tree output-local, but the nodes they reconcile into
-- are not confined to the output: a floating client mid-drag and a wibox
-- overhanging an edge both render on the neighbor while their box is still
-- relative to the output that declared them. Clay's own culling drops any
-- element whose box lies entirely outside the layout dimensions, which would
-- delete both instead of drawing them, so the bands run with culling off.
--
-- awesome._test_declare_order(screen) solves the screen's tree again and
-- returns what it would draw, so absence here is exactly the vanishing.
---------------------------------------------------------------------------

local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")

local TEST_CLIENT = utils.binary_or_skip("./build-test/test-transient-client")
if not TEST_CLIENT then
    return
end

local s = screen[1]
local geo = s.geometry
local bar
local c

local function declared(object)
    for _, o in ipairs(awesome._test_declare_order(s)) do
        if o == object then
            return true
        end
    end
    return false
end

local function assert_declared(object, what)
    assert(declared(object), what .. ": not declared")
    io.stderr:write("[PASS] " .. what .. "\n")
end

local steps = {
    -- A wibox only declares once it has drawn, so wait for it to appear.
    function(count)
        if count == 1 then
            local w = wibox({
                x = geo.x, y = geo.y, width = 100, height = 20,
                bg = "#000000", visible = true, screen = s,
            })
            w:setup({ widget = wibox.widget.textbox, text = "bar" })
            bar = w.drawin
        end
        return declared(bar) or nil
    end,

    -- Past the right edge, then past the left: still drawn, because the
    -- neighbor output is where those pixels belong.
    function()
        bar.x = geo.x + geo.width + 200
        assert_declared(bar, "wibox past the right edge")
        bar.x = geo.x - bar.width - 200
        assert_declared(bar, "wibox past the left edge")
        return true
    end,

    function(count)
        if count == 1 then
            awful.spawn(TEST_CLIENT)
        end
        c = utils.find_client_by_class("transient_test_parent")
        return c and true or nil
    end,

    -- A floating client carries user-authoritative geometry and does not
    -- clamp to its monitor, so dragging it clear of the output must not
    -- delete it before c.screen catches up.
    function()
        c.floating = true
        c:geometry({
            x = geo.x + geo.width + 200, y = geo.y,
            width = 200, height = 200,
        })
        assert_declared(c, "floating client past the right edge")
        return true
    end,

    -- The wibox must not outlive the test: a visible drawin left behind
    -- hangs the quit, and test-transient-client needs the same kill dance
    -- as tests/test-declare-order.lua.
    function(count)
        if count == 1 then
            bar.visible = false
            for _, cl in ipairs(client.get()) do
                cl:kill()
            end
        end
        if #client.get() == 0 then
            return true
        end
        if count >= 10 then
            os.execute("pkill -9 test-transient-client 2>/dev/null")
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
