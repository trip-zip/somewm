---------------------------------------------------------------------------
-- Test: a layer surface with an exclusive zone is a bar in the output's flow
--
-- The board's "Layer shell" example: a surface anchored top, left and right
-- with an exclusive zone is a LAYER_BAR under OUTPUT, grow by the zone
-- (protocol), holding its surface leaf; the workarea starts below it, under
-- the wibar declared before it; and nothing in the dump is derived.
--
-- Run: make test-one TEST=tests/test-clay-layer-bar.lua
---------------------------------------------------------------------------
local runner = require("_runner")
local example = require("_clay_example")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")

local TEST_LAYER_CLIENT = utils.binary_or_skip("./build-test/test-layer-client")
if not TEST_LAYER_CLIENT then
    return
end

local s = screen[1]
local bar, pid

local function dump_line(pattern)
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if line:find(pattern) then
            return line
        end
    end
    return nil
end

local steps = {
    function()
        bar = awful.wibar({ position = "top", screen = s, height = 28, bg = "#00ff00" })
        bar:setup({ widget = wibox.widget.textbox, text = "bar" })
        require("gears.wallpaper").set("#000000")
        pid = awful.spawn(string.format(
            "%s --namespace test-layer-bar --keyboard none"
                .. " --anchor top,left,right --size 0,40 --exclusive-zone 40",
            TEST_LAYER_CLIENT))
        return true
    end,
    function(count)
        local line = dump_line("^      LAYER_BAR test%-layer%-bar ")
        local leaf = dump_line("^        layer%.surface test%-layer%-bar ")
        if not line or not leaf then
            assert(count < 30, "the layer bar never joined the flow:\n"
                .. awesome._clay_tree(s))
            return nil
        end
        assert(line:find(" w=grow h=fixed(40) protocol ", 1, true),
            "the slot is not grow by the zone: " .. line)
        assert(leaf:find(" w=grow h=fixed(40) protocol ", 1, true),
            "the leaf is not grow by the surface height: " .. leaf)
        local roots = dump_line("^  roots ")
        assert(roots:find("derived 0", 1, true), "something is derived: " .. roots)
        local wa = s.workarea
        assert(wa.y == s.geometry.y + 28 + 40 and wa.height == s.geometry.height - 68,
            string.format("the workarea is %dx%d+%d+%d", wa.width, wa.height, wa.x, wa.y))
        -- The layer bar is outermost, as wlroots arranged exclusive zones
        -- before wibar struts; the wibar sits under it.
        local geo = bar:geometry()
        assert(geo.y == s.geometry.y + 40 and geo.height == 28
            and geo.width == s.geometry.width,
            string.format("the wibar is %dx%d+%d+%d", geo.width, geo.height, geo.x, geo.y))
        example.check("layer-shell-bar", awesome._clay_tree(s))
        example.pixel(100,20,"#808080")
        example.pixel(100,50,"#00ff00")
        example.pixel(100,80,"#000000")
        io.stderr:write("[PASS] exclusive layer bar golden and surface/wibar/workarea pixels\n")
        return true
    end,
    function(count)
        if count == 1 then
            bar.visible = false
            -- The client blocks in wl_display_dispatch; a plain TERM only
            -- sets its flag.
            awful.spawn("kill -9 " .. pid)
        end
        if not dump_line("test%-layer%-bar") then
            return true
        end
        assert(count < 30, "the layer surface never left the tree")
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
