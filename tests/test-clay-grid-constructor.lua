-- Public grid geometry, holes, mutations and original pointer delivery.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local awful = require('awful')
local example = require('_clay_example')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

runner.run_async(function()
    local g=wibox.layout.grid()
    g.column_count=3; g.spacing=5
    g.minimum_column_width=10; g.minimum_row_height=20
    g.expand={horizontal=true,vertical=false}
    local ws={}
    for i=1,7 do
        ws[i]=wibox.container.background(nil,'#ff0000')
        ws[i].forced_width=10; ws[i].forced_height=20
        g:add(ws[i])
    end
    local bar=wibox{screen=screen[1],x=100,y=100,width=310,height=100,
        visible=true,ontop=true,bg='#204080',widget=g}
    local calls={}
    for _,w in ipairs{g,ws[7]} do
        w:connect_signal('button::press',function(original,x,y,button,_,area)
            assert(original==w and area.widget==w)
            assert(button==1)
            assert(x==2 and y==(w==g and 52 or 2), 'wrong local input coordinates')
            calls[#calls+1]=w
        end)
    end
    local function area(w,x,y,width,height)
        local found
        for _,hit in ipairs(bar:find_widgets(x+2,y+2)) do
            if hit.widget==w then
                assert(hit.x==x and hit.y==y and hit.width==width and hit.height==height,
                    'wrong original-widget allocation')
                found=true
            end
        end
        assert(found,'original widget absent from cell')
    end
    local function no_widget(x,y)
        for _,hit in ipairs(bar:find_widgets(x,y)) do
            for _,w in ipairs(ws) do assert(hit.widget~=w,'spacer has widget input') end
        end
        local r,green,b=capture.read(surface(root.content()),bar.x+x,bar.y+y)
        assert(r==32 and green==64 and b==128,'spacer/gap paints')
    end
    async.sleep(.3)
    for i,w in ipairs(ws) do area(w,((i-1)%3)*105,math.floor((i-1)/3)*25,100,20) end
    no_widget(110,55); no_widget(215,55); no_widget(102,5)
    example.save('constructor-seven',awesome._clay_tree(screen[1]))
    awful.spawn{pointer,'click','102','152','1280','720','left'}
    async.sleep(.3)
    assert(#calls==2 and calls[1]==g and calls[2]==ws[7],'original parent/child input order')
    ws[2].visible=false
    async.sleep(.2)
    no_widget(110,5); area(ws[3],210,0,100,20)
    ws[2].visible=true
    async.sleep(.2)
    area(ws[2],105,0,100,20)
    g:remove(ws[2])
    async.sleep(.2)
    no_widget(110,5); area(ws[3],210,0,100,20)
    g:add_widget_at(ws[2],1,2)
    bar.width=400
    async.sleep(.2)
    area(ws[2],135,0,130,20); area(ws[7],0,50,130,20)
    example.save('constructor-resized',awesome._clay_tree(screen[1]))
    g.orientation='horizontal'; g.row_count=4
    local extra=wibox.container.background(nil,'#00ff00'); g:add(extra)
    async.sleep(.2)
    local pos=g:get_widget_position(extra)
    assert(pos.row==4 and pos.col==1,'horizontal membership did not follow existing API')
    area(extra,0,75,130,20)
    g.column_count=4; bar.width=415
    async.sleep(.2)
    area(ws[3],210,0,100,20); area(extra,0,75,100,20)
    example.save('constructor-count-orientation',awesome._clay_tree(screen[1]))
    bar.visible=false
    -- Authored cell floors survive a host smaller than the grid on both axes.
    -- The host clips overflow; native cells retain their intentional extent.
    local small=wibox.layout.grid()
    small.column_count=3; small.row_count=2; small.spacing=5; small.expand=true
    small.minimum_column_width=10; small.minimum_row_height=20
    local child=wibox.container.background(nil,'#ff0000')
    child.forced_width=10; child.forced_height=20; small:add(child)
    local host=wibox{screen=screen[1],x=100,y=100,width=25,height=25,
        visible=true,bg='#204080',widget=small}
    async.sleep(.2)
    local found
    for _,hit in ipairs(host:find_widgets(5,5)) do
        if hit.widget==child then
            assert(hit.width==10 and hit.height==20,'authored floors lost under shortage')
            found=true
        end
    end
    assert(found,'original widget absent under shortage')
    for _,hit in ipairs(host:find_widgets(17,5)) do
        assert(hit.widget~=child,'empty minimum-sized cell has child input')
    end
    example.pixel(105,105,'#ff0000'); example.pixel(117,105,'#204080')
    example.save('constructor-shortage',awesome._clay_tree(screen[1]))
    host.visible=false
    io.stderr:write('[PASS] constructor geometry/pixels/holes/gaps/resizing/mutations; original lookup and real pointer parent/child/local coordinates\n')
    runner.done()
end)
