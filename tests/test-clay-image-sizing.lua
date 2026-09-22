-- Natural images use the current native allocation, including on the first frame.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local clay = require('wibox.clay')
local example = require('_clay_example')
local capture = require('_widget_capture')
local cairo = require('lgi').cairo
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

local function source(color)
    local s = cairo.ImageSurface(cairo.Format.ARGB32, 20, 10)
    local c = cairo.Context(s); c:set_source_rgb(color, 1 - color, 0); c:paint()
    return s
end
local function binding(node, widget)
    if clay.bindings then
        for _, b in clay.bindings(node) do if b.widget == widget then return node end end
    elseif node.widget == widget then return node end
    for _, child in ipairs(node.children or {}) do
        local found = binding(child, widget); if found then return found end
    end
end
local function image_box()
    for line in awesome._clay_tree(screen[1]):gmatch('[^\n]+') do
        if line:match('^    %x+ .* image 20x10 ') then
            local x,y,w,h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            return {x=tonumber(x), y=tonumber(y), width=tonumber(w), height=tonumber(h)}, line
        end
    end
    error('no solved image element')
end

runner.run_async(function()
    local retained = {}
    _image_sizing_hosts = retained
    for _, kind in ipairs {'builtin', 'adhoc'} do
        local src, capped = source(1), false
        local icon
        if kind == 'builtin' then icon = wibox.widget.imagebox(src)
        else
            icon = wibox.widget.base.make_widget(nil,nil,{enable_properties=true})
            clay.describe_widget(icon, function()
                return {specs={{image=src._native, class='image', aspect=2,
                    image_width=20, image_height=10, wmax=capped and 20 or icon._private.forced_width, hmax=capped and 10 or icon._private.forced_height}}}
            end, 'intrinsic-image')
        end
        local margin = wibox.container.margin(icon,0,0,0,0)
        local text = wibox.widget.textbox('independently allocated text')
        text.font = 'monospace 10'
        local row = wibox.layout.fixed.horizontal(margin,text)
        row:fill_space(true)
        local bar = wibox {x=100,y=100,width=400,height=24,screen=screen[1],visible=true,
            bg='#0000ff', widget=row}
        retained[#retained+1] = bar
        local events, click_y, token = {}, 2, nil
        for i,w in ipairs {margin,icon} do
            for _,sig in ipairs {'button::press','button::release'} do
                w:connect_signal(sig,function(original,x,y,button,mods,area)
                    assert(original==w and area.widget==w and x==2 and y==click_y)
                    assert(button==1 and #mods==0)
                    events[#events+1]=sig..i
                end)
            end
        end
        local phases = {
            {'cold',24,false,nil,48,24}, {'larger',48,false,nil,96,48},
            {'smaller',12,false,nil,24,12}, {'restored',24,false,nil,48,24},
            {'upscale-off',24,true,nil,20,10}, {'resize-off',24,true,nil,20,10},
            {'forced-width',24,false,40,40,20}, {'forced-height',24,false,nil,24,12,12}, {'forced-tall',24,false,nil,96,48,48}, {'forced-restored',24,false,nil,48,24},
        }
        for _,p in ipairs(phases) do
            bar.height=p[2]; capped=p[3]; icon.forced_width=p[4]; icon.forced_height=p[7]
            if kind=='builtin' then
                icon.resize=true; icon.upscale=not capped
                if p[1]=='resize-off' then icon.resize=false end
            else icon:emit_signal('widget::layout_changed') end
            awesome._test_redeclare()
            local first,line=image_box()
            example.save('image-sizing-'..kind..'-'..p[1]..'-first',awesome._clay_tree(screen[1]))
            assert(first.width==p[5] and first.height==p[6], kind..'-'..p[1]..': '..line)
            local hits={}
            click_y=p[6]<p[2] and p[2]-2 or 2
            for _,hit in ipairs(bar:find_widgets(2,click_y)) do hits[hit.widget]=hit end
            for _,w in ipairs {margin,icon} do
                capture.assert_box(assert(hits[w]),{x=0,y=0,width=p[5],height=math.max(p[2],20,p[7] or 0)},'original allocation')
            end
            local text_hit
            for _,hit in ipairs(bar:find_widgets(p[5]+2,2)) do if hit.widget==text then text_hit=hit end end
            capture.assert_box(assert(text_hit),{x=p[5],y=0,width=400-p[5],height=math.max(p[2],20,p[7] or 0)},'independent text')
            local node=assert(binding(bar._drawable._clay_tree,icon))
            if token then assert(node.occurrence==token,'original occurrence changed') end
            token=node.occurrence
            async.sleep(0.1)
            local settled=image_box()
            assert(first.width==settled.width and first.height==settled.height,'image converged over frames')
            example.pixel(102,102,'#ff0000')
            if p[6]<p[2] then example.pixel(102,100+click_y,'#0000ff') end
            events={}
            awful.spawn {pointer,'click','102',tostring(100+click_y),'1280','720','left'}
            for _=1,30 do if #events==4 then break end; async.sleep(0.02) end
            assert(table.concat(events,',')=='button::press1,button::press2,button::release1,button::release2', table.concat(events,','))
            example.save('image-sizing-'..kind..'-'..p[1],awesome._clay_tree(screen[1]))
        end
        src=source(0)
        if kind=='builtin' then icon.image=src else icon:emit_signal('widget::redraw_needed') end
        awesome._test_redeclare(); async.sleep(0.1)
        example.pixel(102,102,'#00ff00')
        example.save('image-sizing-'..kind..'-replacement',awesome._clay_tree(screen[1]))
        if kind=='builtin' then
            screen[1].inspector=true; async.sleep(0.1)
            example.save('image-sizing-inspector',awesome._clay_tree(screen[1]))
            screen[1].inspector=false
        end
        bar.visible=false
    end
    io.stderr:write('[PASS] native image first frame, resize, caps, forced axis, source replacement, original areas and real parent/child input\n')
    runner.done()
end)
