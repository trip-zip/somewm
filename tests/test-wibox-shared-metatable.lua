-- Every wibox shares one metatable; reads and writes still reach its drawin.
local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local cairo = require('lgi').cairo

local a, b

runner.run_steps {
    function()
        local s = awful.screen.focused()
        a = wibox { x = 10, y = 10, width = 100, height = 50, visible = true, screen = s }
        b = wibox { x = 20, y = 20, width = 100, height = 50, visible = true, screen = s }
        assert(getmetatable(a) == getmetatable(b), 'two wiboxes share one metatable')
        assert(getmetatable(a).__index and getmetatable(a).__newindex, 'the shared metatable forwards')
        return true
    end,
    function()
        a.x = 42
        assert(a.drawin.x == 42, 'x reaches the drawin: got ' .. tostring(a.drawin.x))
        assert(rawget(a, 'x') == nil, 'x is not stored on the wibox table')
        assert(b.drawin.x == 20, 'the other wibox keeps its x: got ' .. tostring(b.drawin.x))
        a.visible = false
        assert(a.drawin.visible == false, 'visible reaches the drawin')
        assert(a.visible == false, 'visible reads back through the drawin')
        return true
    end,
    function()
        a.not_a_drawin_key = 7
        assert(rawget(a, 'not_a_drawin_key') == 7, 'a key the drawin does not own is stored on the wibox')
        assert(b.not_a_drawin_key == nil, 'and only on that wibox')
        return true
    end,
    function()
        a.shape_bounding = cairo.ImageSurface.create(cairo.Format.A1, 1, 1)._native
        assert(rawget(a, 'shape_bounding') == nil, 'a forced key is not stored on the wibox table')
        assert(a.drawin.shape_bounding ~= nil, 'a forced key reaches the drawin')
        return true
    end,
    function()
        b.visible = false
        a, b = nil, nil
        return true
    end,
}
