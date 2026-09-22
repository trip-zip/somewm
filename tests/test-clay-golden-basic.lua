---------------------------------------------------------------------------
-- Test: the basic desktop's declared tree matches its golden
--
-- The board's first example: one output, a top wibar with left, centre and
-- right widgets, a workarea, and a tiled client with a titlebar. The golden
-- under tests/goldens/basic-desktop.txt is the shape the example states, in
-- the dump's own words; this test declares the fixture, waits for the tree
-- to settle, and compares. See tests/_clay_golden.lua for what is compared.
--
-- Run: make test-one TEST=tests/test-clay-golden-basic.lua
-- Record an accepted shape: SOMEWM_GOLDEN=record
---------------------------------------------------------------------------
local runner = require("_runner")
local utils = require("_utils")
local golden = require("_clay_example")
local awful = require("awful")
local wibox = require("wibox")

local TEST_CLIENT = utils.binary_or_skip("./build-test/test-transient-client")
if not TEST_CLIENT then
    return
end

local s = screen[1]
local bar, c, pid, last

local steps = {
    function()
        s.selected_tag.layout = awful.layout.suit.tile
        s.selected_tag.gap = 0
        bar = awful.wibar({ position = "top", screen = s, height = 28 })
        bar:setup({
            layout = wibox.layout.align.horizontal,
            expand = "outside",
            {
                layout = wibox.layout.fixed.horizontal,
                { widget = wibox.widget.textbox, text = "menu" },
                { widget = wibox.widget.textbox, text = "tags" },
            },
            { widget = wibox.widget.textbox, text = "clock" },
            { widget = wibox.widget.textbox, text = "status" },
        })
        pid = awful.spawn(TEST_CLIENT)
        return true
    end,
    function(count)
        c = utils.find_client_by_class("transient_test_parent")
        if c then
            c.floating = false
            c.border_width = 1
            c.shadow = false
            awful.titlebar(c, { size = 24 })
            return true
        end
        assert(count < 30, "the client never mapped")
    end,
    -- Settled: two dumps in a row agree, and the bar has converted.
    function(count)
        local dump = awesome._clay_tree(s)
        if dump:find("converted", 1, true) and dump == last then
            golden.check("basic-desktop", dump)
            return true
        end
        last = dump
        assert(count < 30, "the tree never settled")
    end,
    function(count)
        if count == 1 then
            bar.visible = false
            if pid then
                awful.spawn("kill " .. pid)
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
