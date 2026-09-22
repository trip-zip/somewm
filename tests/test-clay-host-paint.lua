-- Shared host rules, original input and paint across built-in/custom widgets.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local clay = require('wibox.clay')
local shape = require('gears.shape')
local example = require('_clay_example')
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))
local s = screen[1]

runner.run_async(function()
    require('gears.wallpaper').set('#ffffff')
    local missing, receipts, measurements = {}, {}, {}
    local function measure(name, start, memory)
        awesome._test_redeclare()
        measurements[#measurements+1] = string.format('%s cpu_us=%.0f lua_kib_delta=%.3f',
            name,(os.clock()-start)*1000000,collectgarbage('count')-memory)
        local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
        if dir then
            local f = assert(io.open(dir..'/measurements.txt','w'))
            f:write(table.concat(measurements,'\n'),'\n'); f:close()
        end
    end
    local function leaf(custom)
        if not custom then return wibox.container.background(nil, '#0000ff') end
        local widget = wibox.widget.base.make_widget(nil, nil, {enable_properties=true})
        clay.describe_widget(widget, function()
            return {bg=clay.solid_rgba('#0000ff'), radius=0}
        end, 'custom.host-content')
        return widget
    end
    local function save(name, host, widget, folded)
        local node = assert(host._drawable._clay_wired[widget][1].element)
        assert(node.box.x == 0 and node.box.y == 0)
        assert(node.box.width == host.width and node.box.height == host.height,
            name..': widget '..node.box.width..'x'..node.box.height..' host '..host.width..'x'..host.height)
        if (node == host._drawable._clay_tree) ~= folded then
            missing[#missing+1] = name
        end
        example.save(name, awesome._clay_tree(s))
    end
    for _, custom in ipairs{false, true} do
        local kind = custom and 'custom' or 'builtin'
        for _, edge in ipairs{'top','bottom','left','right'} do
            local measured = not custom and edge == 'top'
            local memory, start = collectgarbage('count'), os.clock()
            local widget = leaf(custom)
            local bar = awful.wibar {screen=s, position=edge, width=32, height=32,
                bg='#ff0000', widget=widget, margins={left=3,right=5,top=7,bottom=9}}
            if measured then measure('cold',start,memory) end
            async.sleep(0.15)
            if measured then measure('unchanged',os.clock(),collectgarbage('count')) end
            local token = bar._drawable._clay_wired[widget][1].id
            local presses, releases = 0, 0
            widget:buttons {awful.button({},1,function() end)}
            for _, signal in ipairs{'button::press','button::release'} do
                widget:connect_signal(signal, function(original,x,y,button,mods,area)
                    assert(original==widget and area.widget==widget and button==1)
                    assert(x==12 and y==12, x..','..y)
                    assert(area.width==bar.width and area.height==bar.height)
                    if signal=='button::press' then presses=presses+1 else releases=releases+1 end
                end)
            end
            example.pixel(bar.x+12,bar.y+12,'#0000ff')
            example.pixel(bar.x-1,bar.y+12,'#ffffff')
            save('host-'..kind..'-'..edge,bar,widget,true)
            awful.spawn{pointer,'click',tostring(bar.x+12),tostring(bar.y+12),'1280','720','left'}
            async.sleep(0.3)
            assert(presses==1 and releases==1, 'original press/release missing')

            -- Translucent content exposes the separate red host paint.
            memory, start = collectgarbage('count'), os.clock()
            widget.opacity=0.5
            if measured then measure('one-opacity-change',start,memory) end
            async.sleep(0.15)
            local r,g,b=require('_widget_capture').read(require('gears.surface')(root.content()),bar.x+12,bar.y+12)
            assert(r>=127 and r<=128 and g==0 and b>=127 and b<=128)
            save('host-'..kind..'-'..edge..'-alpha',bar,widget,false)
            widget.opacity=1
            bar.opacity=0.5
            async.sleep(0.15)
            r,g,b=require('_widget_capture').read(require('gears.surface')(root.content()),bar.x+12,bar.y+12)
            assert(r>=126 and r<=128 and g>=62 and g<=64 and b>=190 and b<=192,
                string.format('per-command host opacity: %d,%d,%d',r,g,b))
            save('host-'..kind..'-'..edge..'-host-alpha',bar,widget,false)
            bar.opacity=1
            bar.shape=function(cr,w,h) shape.rounded_rect(cr,w,h,8) end
            async.sleep(0.15)
            assert(bar._drawable._clay_wired[widget][1].id==token)
            example.pixel(bar.x,bar.y,'#ffffff')
            example.pixel(bar.x+12,bar.y+12,'#0000ff')
            save('host-'..kind..'-'..edge..'-rounded',bar,widget,true)
            receipts[#receipts+1]=kind..' '..edge..': pixels, inset, opacity, shape, area, token and real input'
            awful.spawn{pointer,'move','640','360','1280','720'}
            async.sleep(0.1)
            bar:remove()
            async.sleep(0.1)
        end
    end

    -- Opaque content covers a FIT host, but padding keeps the text's own area.
    local text=wibox.widget.textbox('Canonical')
    local padding=wibox.container.margin(text,8,8,4,4)
    local content=wibox.container.background(padding,'#0000ff')
    local popup=awful.popup {screen=s,visible=true,ontop=true,bg='#ff0000',
        border_width=0,shadow=false,placement=awful.placement.top_left,
        offset={x=100,y=100},widget=content}
    async.sleep(0.2)
    save('host-popup-opaque',popup,content,true)
    local node=popup._drawable._clay_wired[text][1].element
    assert(node.box.x==8 and node.box.y==4)
    example.pixel(popup.x+2,popup.y+2,'#0000ff')
    content.opacity=0.5
    async.sleep(0.2)
    save('host-popup-alpha',popup,content,false)
    popup.visible=false
    for _, receipt in ipairs(receipts) do io.stderr:write('[PASS] '..receipt..'\n') end
    assert(#missing==0,'missing canonical host contributions: '..table.concat(missing,', '))
    runner.done()
end)
