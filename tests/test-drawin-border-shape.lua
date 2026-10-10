local runner = require('_runner')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local wibox = require('wibox')
local shape = require('gears.shape')
local box, below
local function pixel(x, y, color)
    local r, g, b = capture.read(surface(root.content()), box.x + x, box.y + y)
    assert(string.format('#%02x%02x%02x', r, g, b) == color,
        string.format('pixel %d,%d: #%02x%02x%02x expected %s', x,y,r,g,b,color))
end
runner.run_steps {
    function()
        screen[1].scale = 1
        below = wibox { x=40, y=40, width=100, height=100, screen=screen[1],
            visible=true, shadow=false, bg='#0000ff', border_width=0 }
        box = wibox { x=50, y=50, width=40, height=40, screen=screen[1],
            visible=true, shadow=false, bg='#ff0000', border_width=4,
            border_color='#00ff00', shape=function(cr,w,h) shape.rounded_rect(cr,w,h,12) end }
        return true
    end,
    function(count)
        if count < 5 then return end
        assert(box.drawin.shape == 8, 'rounded shape is a content radius')
        pixel(20,20,'#ff0000')
        pixel(-4,-4,'#0000ff')
        pixel(20,-2,'#00ff00')
        box.shape = shape.circle
        return true
    end,
    function(count)
        if count < 5 then return end
        assert(type(box.drawin.shape) == 'function', 'circle is a path recorder')
        pixel(20,20,'#ff0000')
        pixel(0,0,'#0000ff')
        pixel(20,-2,'#00ff00')
        surface.apply_shape_bounding(box, shape.partially_rounded_rect, true, false, true, false, 12)
        return true
    end,
    function(count)
        if count < 5 then return end
        assert(type(box.drawin.shape) == 'function', 'surface helper sets the wibox shape')
        pixel(-4,-4,'#0000ff')
        pixel(39,0,'#ff0000')
        box.shape = nil
        return true
    end,
    function(count)
        if count < 5 then return end
        assert(box.drawin.shape == nil, 'nil clears the shape')
        pixel(0,0,'#ff0000')
        box.visible, below.visible = false, false
        return true
    end,
}
