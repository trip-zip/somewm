-- Authored square bounds, rectangular paint and original occurrence areas.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local example = require('_clay_example')
local surface = require('gears.surface')
local capture = require('_widget_capture')
local shape = require('gears.shape')

runner.run_async(function()
    local s = screen[1]
    s.scale = tonumber(os.getenv('SOMEWM_TEXT_TEST_SCALE') or '1')
    async.sleep(.1)
    local checkbox = wibox.widget.checkbox(true)
    checkbox.color, checkbox.bg = '#00ff00', '#0000ff'
    checkbox.border_width = 0
    local child = wibox.container.background(wibox.widget.textbox('A B C D E F G H'), '#ffff00')
    local chart = wibox.container.arcchart(child)
    chart.values, chart.colors, chart.thickness = {1}, {'#ff0000'}, 5
    local host = wibox {screen=s,x=100,y=100,width=240,height=100,visible=true,bg='#204080'}
    local function node(w, occurrence)
        local entry = assert(host._drawable._clay_wired[w])[occurrence or 1]
        return assert(entry.element)
    end
    local function box(w, x, y, width, height, occurrence)
        local n = node(w, occurrence)
        local b = assert(n.box)
        assert(b.x == x and b.y == y and b.width == width and b.height == height,
            string.format('box %g,%g %gx%g expected %g,%g %gx%g',b.x,b.y,b.width,b.height,x,y,width,height))
        local found
        for _, hit in ipairs(host:find_widgets(x+width/2,y+height/2)) do
            if hit.widget == w and hit.x == x and hit.y == y then
                assert(hit.width == width and hit.height == height)
                found = true
            end
        end
        assert(found, 'original widget occurrence is absent from lookup')
        return n
    end
    local function pixel(x,y,hex)
        local r,g,b = capture.read(surface(root.content()),host.x+x,host.y+y)
        assert(math.abs(r-tonumber(hex:sub(2,3),16)) <= 12
            and math.abs(g-tonumber(hex:sub(4,5),16)) <= 12
            and math.abs(b-tonumber(hex:sub(6,7),16)) <= 12,
            string.format('pixel %g,%g = #%02x%02x%02x expected %s',x,y,r,g,b,hex))
    end
    local function square_box(width,height)
        local line = assert(awesome._clay_tree(s):match('[^\n]* %- spacer[^\n]*'))
        local actual_width,actual_height = line:match('box %-?%d+,%-?%d+ (%d+)x(%d+)')
        assert(tonumber(actual_width)==width and tonumber(actual_height)==height,line)
    end
    local function settle(name)
        async.sleep(.15)
        example.save(name,awesome._clay_tree(s))
    end
    for _, vertical in ipairs {false,true} do
        host.width, host.height = vertical and 100 or 240, vertical and 240 or 100
        for _, widget in ipairs {checkbox,chart} do
            local left = wibox.widget.textbox('left')
            if vertical then left.forced_height=160 else left.forced_width=160 end
            host.widget = (vertical and wibox.layout.flex.vertical or wibox.layout.flex.horizontal)(left,widget)
            settle((vertical and 'column-' or 'row-') .. (widget==chart and 'arc' or 'checkbox'))
            local extent = widget == chart and 100 or 80
            local n = box(widget,vertical and 0 or 160,vertical and 160 or 0,vertical and 100 or extent,vertical and extent or 100)
            assert(not n.last_frame_size and not n.wmin and not n.hmin,
                'rectangular allocation acquired a square minimum')
            if widget==chart then
                local inner=n.children[1]
                assert(inner.square and inner.wmin==90 and inner.hmin==90)
                box(child,vertical and 5 or 165,vertical and 165 or 5,90,90)
                pixel(vertical and 50 or 200,vertical and 200 or 50,'#ffff00')
                pixel(vertical and 16 or 166,vertical and 166 or 16,'#204080')
            else
                assert(n.square and n.w=='grow' and n.h=='grow')
                pixel(vertical and 40 or 200,vertical and 200 or 40,'#00ff00')
            end
        end
    end
    host.width,host.height,host.widget=200,40,wibox.container.margin(checkbox)
    settle('checkbox-wide')
    box(checkbox,0,0,200,40)
    pixel(20,20,'#00ff00');pixel(100,20,'#204080')
    checkbox.checked=false
    settle('checkbox-unchecked');pixel(20,20,'#0000ff')
    checkbox.shape=shape.circle
    settle('checkbox-circle');pixel(1,1,'#204080');pixel(20,20,'#0000ff')
    host.width,host.height=40,200
    settle('checkbox-tall');box(checkbox,0,0,40,200)
    pixel(20,20,'#0000ff');pixel(20,100,'#204080')

    host.width,host.height,host.widget=200,100,wibox.container.margin(chart)
    chart.thickness,chart.border_width=6,2
    chart.paddings={left=4,right=0,top=2,bottom=2}
    settle('arc-asymmetric')
    box(chart,0,0,200,100);box(child,64,12,76,76)
    pixel(102,30,'#ffff00');pixel(74,22,'#204080')
    host.width=80
    settle('arc-resized');box(child,14,22,56,56)
    chart.widget=nil
    settle('arc-empty')
    square_box(56,56)
    chart.widget=child
    chart.thickness,chart.border_width,chart.paddings=5,0,0
    host.width,host.height=8,8
    settle('arc-zero-inner')
    square_box(0,0)
    for _, hit in ipairs(host:find_widgets(4,4)) do
        assert(hit.widget~=child, 'zero inner space exposes the child to input')
    end

    for _, widget in ipairs {checkbox,chart} do
        for _, forced in ipairs {{60,false},{false,30},{60,30}} do
            widget.forced_width,widget.forced_height=forced[1] or nil,forced[2] or nil
            host.width,host.height=240,100
            host.widget=wibox.layout.fixed.horizontal(widget)
            settle('forced-row-'..tostring(widget==chart)..'-'..tostring(forced[1])..'-'..tostring(forced[2]))
            box(widget,0,0,forced[1] or forced[2] or 100,100)
            local n=node(widget)
            assert((n.w or 'fit')==(forced[1] or 'fit'))
            assert(n.hmin==(forced[2] or nil))
        end
        widget.forced_width,widget.forced_height=nil,nil
    end
    host.width,host.height=200,40
    host.widget=wibox.layout.flex.horizontal(checkbox,checkbox)
    settle('checkbox-occurrences')
    local first=box(checkbox,0,0,100,40,1)
    local second=box(checkbox,100,0,100,40,2)
    assert(first.occurrence~=second.occurrence)
    host.width=300
    settle('checkbox-occurrences-resized')
    assert(box(checkbox,0,0,150,40,1).occurrence==first.occurrence)
    assert(box(checkbox,150,0,150,40,2).occurrence==second.occurrence)
    host.width,host.widget=200,wibox.layout.flex.horizontal(chart,chart)
    settle('arc-occurrences')
    box(chart,0,0,100,40,1);box(chart,100,0,100,40,2)
    box(child,35,5,30,30,1);box(child,135,5,30,30,2)
    host.visible=false
    io.stderr:write('[PASS] authored square bounds, art, padding, zero space, forced axes and occurrence input scale=',s.scale,'\n')
    runner.done()
end)
