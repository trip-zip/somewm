-- Test: the declare pass draws windows in the band their stacking attribute
-- names, and a transient that sets none inherits its parent's.
--
-- awesome._test_declare_order(screen) solves the screen's Clay tree again and
-- returns the clients and drawins it would draw, bottom first, so the
-- assertions read the real draw order rather than inferring it from
-- attributes.

local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")

local TEST_TRANSIENT_CLIENT =
    utils.binary_or_skip("./build-test/test-transient-client")
if not TEST_TRANSIENT_CLIENT then
    return
end

local s = screen[1]
local bar
local parent_client
local child_client
local proc_pid

-- Position in the draw order, bottom first.
local function order_index(object)
    local order = awesome._test_declare_order(s)
    for i, o in ipairs(order) do
        if o == object then
            return i
        end
    end
    return nil
end

local function assert_above(a, b, what)
    local ia, ib = order_index(a), order_index(b)
    assert(ia and ib, what .. ": not everything is declared")
    assert(ia > ib, string.format("%s: expected above (%d vs %d)",
        what, ia, ib))
    io.stderr:write("[PASS] " .. what .. "\n")
end

local steps = {
    -- A plain wibox sits in the wibox band, above normal clients. It only
    -- declares once it has drawn, so wait for it to enter the order.
    function(count)
        if count == 1 then
            local w = wibox({
                x = 0, y = 0, width = 100, height = 20,
                visible = true,
                screen = s,
            })
            w:setup({ widget = wibox.widget.textbox, text = "bar" })
            bar = w.drawin
        end
        if order_index(bar) then
            return true
        end
    end,

    function(count)
        if count == 1 then
            proc_pid = awful.spawn(TEST_TRANSIENT_CLIENT)
        end
        parent_client = utils.find_client_by_class("transient_test_parent")
        if parent_client then
            return true
        end
    end,

    function(count)
        if count == 1 then
            awesome.kill(proc_pid, 10) -- SIGUSR1: create the transient child
        end
        for _, c in ipairs(client.get()) do
            if c.transient_for == parent_client then
                child_client = c
                return true
            end
        end
    end,

    -- With no stacking attribute of its own, the child inherits its parent's
    -- normal band: above the parent, below the wibox.
    function()
        assert_above(child_client, parent_client, "plain transient above parent")
        assert_above(bar, child_client, "wibox above plain transient")
        return true
    end,

    -- ontop on the child wins over the parent's placement, as in AwesomeWM.
    function()
        child_client.ontop = true
        assert_above(child_client, bar, "ontop transient above wibox")
        return true
    end,

    -- Back to inheriting, and now the parent is the one that is ontop: the
    -- child follows it above the wibox without setting anything itself.
    function()
        child_client.ontop = false
        parent_client.ontop = true
        assert_above(child_client, parent_client, "inheriting child above parent")
        assert_above(child_client, bar, "inheriting child above wibox")
        return true
    end,

    function(count)
        if count == 1 then
            bar.visible = false
            if proc_pid then
                awful.spawn("kill " .. proc_pid)
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
