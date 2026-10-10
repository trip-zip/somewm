local runner = require('_runner')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local shape = require('gears.shape')
local awful = require('awful')
local wibox = require('wibox')
local cairo = require('lgi').cairo
local s = screen[1]
local RED, GREEN, BLUE = '#ff0000', '#00ff00', '#0000ff'
local failures, cases = {}, {}
local below_clicks, circle_clicks = 0, 0
local function check(ok, message)
    if not ok then
        failures[#failures + 1] = message
        io.stderr:write('[FAIL] ' .. message .. '\n')
    end
end
local function warnings()
    io.stderr:flush()
    local f = assert(io.open(assert(os.getenv('SOMEWM_TEST_LOG'))))
    local text = f:read('*a')
    f:close()
    local _, count = text:gsub('drawin: shape masks are not read, set wibox.shape', '')
    return count
end
local function click(x, y)
    awful.spawn { './build-test/test-virtual-pointer-client', 'click',
        tostring(cases[1].box.x + x), tostring(cases[1].box.y + y),
        tostring(s.geometry.width), tostring(s.geometry.height) }
end
runner.run_steps {
    function()
        s.scale = 1
        for i, args in ipairs {
            { width=40, height=40, shape=shape.circle },
            { width=40, height=40, shape=shape.circle, border_width=4 },
            { width=60, height=20, shape=shape.rounded_bar },
            { width=40, height=40, shape=function(cr, w, h)
                shape.partially_rounded_rect(cr, w, h, true, false, true, false, 12)
              end, border_width=2 },
            { width=40, height=40, shape=function(cr, w, h)
                shape.rounded_rect(cr, w, h, 12)
              end, border_width=2 },
        } do
            local x, y = s.geometry.x + 100 + (i - 1) * 110, s.geometry.y + 100
            local below = wibox { screen=s, x=x-10, y=y-10, width=100, height=100,
                visible=true, bg=BLUE, shadow=false, border_width=0 }
            args.x, args.y, args.screen = x, y, s
            args.visible, args.bg, args.shadow, args.border_color = true, RED, false, GREEN
            args.border_width = args.border_width or 0
            local box
            if i == 4 then
                args.widget = capture.leaf_widget(40, 40, RED)
                box = awful.popup(args)
            else
                box = wibox(args)
            end
            cases[i] = { box=box, below=below }
        end
        cases[1].below:buttons { awful.button({}, 1, function() below_clicks = below_clicks + 1 end) }
        cases[1].box:buttons { awful.button({}, 1, function() circle_clicks = circle_clicks + 1 end) }
        return true
    end,
    function(count)
        if count < 5 then return end
        local shot = surface(root.content())
        for i, case in ipairs(cases) do
            local box = case.box
            local function pixel(x, y, hex, alternate)
                local r, g, b = capture.read(shot, box.x + x, box.y + y)
                local function matches(c)
                    return math.abs(r-tonumber(c:sub(2,3),16)) <= 12
                        and math.abs(g-tonumber(c:sub(4,5),16)) <= 12
                        and math.abs(b-tonumber(c:sub(6,7),16)) <= 12
                end
                check(matches(hex) or alternate and matches(alternate),
                    string.format('case %d pixel %d,%d: #%02x%02x%02x expected %s', i,x,y,r,g,b,hex))
            end
            pixel(box.width/2, box.height/2, RED)
            pixel(0, 0, BLUE)
            if i == 4 then
                pixel(box.width-1, 0, RED, GREEN)
            else
                pixel(box.width-1, 0, BLUE)
                pixel(0, box.height-1, BLUE)
                pixel(box.width-1, box.height-1, BLUE)
            end
            if i == 2 then pixel(20, 2-box.border_width, GREEN) end
            check(type(box.drawin.shape) == (i == 5 and 'number' or 'function'),
                'case ' .. i .. ' drawin shape type')
        end
        local rounded = cases[5].box
        local found = false
        for line in awesome._clay_tree(s):gmatch('[^\n]+') do
            if line:find('WIBOX ', 1, true) and line:find('radius 10', 1, true) then
                found = not line:find(' custom', 1, true)
            end
        end
        check(found and rounded.drawin.shape == 10, 'rounded frame keeps native radius without custom data')
        local before = warnings()
        local mask = cairo.ImageSurface.create(cairo.Format.A1, 40, 40)
        for _, key in ipairs { 'shape_bounding', 'shape_clip', 'shape_input' } do
            cases[1].box[key] = mask._native
            check(cases[1].box.drawin[key] == nil, key .. ' getter is nil')
        end
        mask:finish()
        collectgarbage('collect')
        check(warnings() - before == 1, 'mask setters warn once per drawin')
        click(1, 1)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(below_clicks == 1 and circle_clicks == 0, 'corner click reaches blue wibox')
        click(20, 20)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(below_clicks == 1 and circle_clicks == 1, 'centre click reaches circle')
        cases[1].box.input_passthrough = true
        check(cases[1].box.drawin.input_passthrough == true, 'passthrough reaches drawin')
        click(20, 20)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(below_clicks == 2 and circle_clicks == 1, 'passthrough centre reaches blue wibox')
        for _, case in ipairs(cases) do case.box.visible=false; case.below.visible=false end
        assert(#failures == 0, table.concat(failures, '\n'))
        return true
    end,
}
