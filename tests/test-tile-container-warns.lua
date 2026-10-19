---------------------------------------------------------------------------
-- Test: wibox.container.tile draws one copy and warns once
--
-- A tile with tiled true, its default, shows its widget once in the dump,
-- placed as wibox.container.place places it, and logs one warning naming
-- tiled. A tile with tiled false is a place and logs nothing.
--
-- Run: make test-one TEST=tests/test-tile-container-warns.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")

local s = screen[1]
local bar, column

local function tiled_warnings()
    io.stderr:flush()
    local f = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG"))))
    local text = f:read("*a")
    f:close()
    local _, n = text:gsub("wibox%.clay: wibox%.container%.tile tiled is true and one copy is drawn", "")
    return n
end

local function count_text(dump, text)
    local _, n = dump:gsub(" text \"" .. text .. "\" ", "")
    return n
end

runner.run_steps {
    function()
        column = wibox.layout.fixed.vertical()
        column:add(wibox.widget {
            widget = wibox.container.tile, tiled = false,
            wibox.widget.textbox("tileoffprobe"),
        })
        bar = wibox { screen = s, x = 0, y = 0, width = 300, height = 120,
            visible = true, bg = "#101010", widget = column }
        return true
    end,
    function(count)
        if count_text(awesome._clay_tree(s), "tileoffprobe") == 0 then
            assert(count < 50, "the untiled tile never reached the dump")
            return nil
        end
        assert(tiled_warnings() == 0, "a tile with tiled false warned")
        for _ = 1, 2 do
            column:add(wibox.widget {
                widget = wibox.container.tile,
                wibox.widget.textbox("tileonprobe"),
            })
        end
        return true
    end,
    function(count)
        local dump = awesome._clay_tree(s)
        local shown = count_text(dump, "tileonprobe")
        if shown == 0 then
            assert(count < 50, "the tiled tiles never reached the dump")
            return nil
        end
        assert(shown == 2, "each of two tiles shows its widget once, got " .. shown)
        assert(tiled_warnings() == 1, "expected one tiled warning, got " .. tiled_warnings())
        for line in dump:gmatch("[^\n]* text \"tileonprobe\" [^\n]*") do
            io.stderr:write("matched:" .. line .. "\n")
        end
        io.stderr:write(dump .. "\n")
        bar.visible = false
        return true
    end,
}
