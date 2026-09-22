local runner = require("_runner")
local utils = require("_utils")
local golden = require("_clay_example")
local checks = golden.batch()
local awful = require("awful")

local binary = assert(utils.binary_or_skip("./build-test/test-transient-client"))
local s = screen[1]
local report = os.tmpname()
local last
local steps = {
    function()
        s.selected_tag.layout = awful.layout.suit.tile
        s.selected_tag.master_width_factor = 0.5
        s.selected_tag.master_count = 1
        s.selected_tag.column_count = 1
        s.selected_tag.gap_single_client = false
        s.selected_tag.gap = 8
        awful.spawn({ binary, "CLIENT_A", report })
        return true
    end,
}
local function mapped(name)
    return function(count)
        local c = utils.find_client_by_class(name)
        if not c then
            assert(count < 30, name .. " did not map")
            return
        end
        c.floating = false
        c.border_width = 1
        c.shadow = false
        awful.titlebar(c, { size = 24 })
        local ordered = awful.client.tiled(s)
        for i = 1, #ordered do
            local want = utils.find_client_by_class("CLIENT_" .. string.char(64+i))
            local current = awful.client.tiled(s)[i]
            if current ~= want then current:swap(want) end
        end
        last = nil
        return true
    end
end
local function check(name)
    return function(count)
        local dump = awesome._clay_tree(s)
        if dump == last and dump:find("converted", 1, true) then
            checks.check(name, dump)
            return true
        end
        last = dump
        assert(count < 30, "tree did not settle")
    end
end
steps[#steps + 1] = mapped("CLIENT_A")
steps[#steps + 1] = check("client-titlebar")
steps[#steps + 1] = function()
    local c = utils.find_client_by_class("CLIENT_A")
    for _, spec in ipairs{{"top",24,"#ff0000"},{"left",10,"#00ff00"},
            {"right",12,"#0000ff"},{"bottom",16,"#ffff00"}} do
        awful.titlebar(c,{position=spec[1],size=spec[2],bg_normal=spec[3],bg_focus=spec[3]})
    end
    last=nil
    return true
end
steps[#steps + 1] = check("clients-can-also-have-n-titlebars")
steps[#steps + 1] = function(n)
    local f=assert(io.open(report)); local size=f:read("*a"); f:close()
    if size ~= "1256 678\n" then assert(n<30,"four-titlebar configure: "..size); return end
    golden.pixel(100,12,"#ff0000"); golden.pixel(5,100,"#00ff00")
    golden.pixel(1272,100,"#0000ff"); golden.pixel(100,710,"#ffff00")
    golden.pixel(100,100,"#404040")
    io.stderr:write("[PASS] all four titlebar pixels; client received solved surface 1256x678\n")
    local c=utils.find_client_by_class("CLIENT_A")
    for _, position in ipairs{"left","right","bottom"} do awful.titlebar.hide(c,position) end
    os.remove(report)
    return true
end
steps[#steps + 1] = function() awful.spawn({ binary, "CLIENT_B" }); return true end
steps[#steps + 1] = mapped("CLIENT_B")
steps[#steps + 1] = check("client-gaps")
steps[#steps + 1] = function() awful.spawn({ binary, "CLIENT_C" }); return true end
steps[#steps + 1] = mapped("CLIENT_C")
steps[#steps + 1] = check("nested-client-layouts")
steps[#steps + 1] = checks.finish
runner.run_steps(steps)
