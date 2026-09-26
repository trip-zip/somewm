-- Original parent/child objects must retain real pointer delivery and areas.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local tidy = require('_clay_tidy')
local example = require('_clay_example')
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

runner.run_async(function()
    local label = wibox.widget.textbox('Click')
    local background = wibox.container.background(label, '#0000ff')
    local calls, presses, releases = {}, {}, {}
    local right, shifted = 0, 0
    for index, widget in ipairs{background,label} do
        widget:buttons {
            awful.button({},1,function() calls[#calls+1]=index end),
            awful.button({},3,function() right=right+1 end),
            awful.button({'Shift'},1,function() shifted=shifted+1 end),
        }
        for _, event in ipairs{'button::press','button::release'} do
            widget:connect_signal(event,function(original,x,y,button,modifiers,area)
                assert(original==widget and area.widget==widget, 'input lost original Lua object')
                assert(button==1 or button==3, 'unexpected pointer button')
                assert(#modifiers==0, 'test pointer unexpectedly has modifiers')
                assert(x==2 and y==2, 'incorrect local input coordinates: '..x..','..y)
                assert(area.widget_width==area.width and area.widget_height==area.height)
                local list=event=='button::press' and presses or releases
                list[#list+1]=index
            end)
        end
    end
    local popup=tidy.popup(background)
    async.sleep(0.3)
    local hits=popup:find_widgets(2,2)
    local found={}
    for _, hit in ipairs(hits) do
        if hit.widget==background or hit.widget==label then found[hit.widget]=hit end
    end
    assert(found[background] and found[label], 'lookup lost an original widget')
    for _, field in ipairs{'x','y','width','height'} do
        assert(found[background][field]==found[label][field], 'identical areas disagree: '..field)
    end
    local function click(button)
        awful.spawn{pointer,'click',tostring(popup.x+2),tostring(popup.y+2),
            '1280','720',button}
        async.sleep(0.3)
    end
    click('left')
    assert(table.concat(calls,',')=='1,2', 'parent/child left-button delivery or order changed')
    assert(table.concat(presses,',')=='1,2' and table.concat(releases,',')=='1,2',
        'parent and child must each receive press and release once')
    assert(right==0 and shifted==0, 'button/modifier filtering leaked')
    click('right')
    assert(right==2 and shifted==0 and #calls==2, 'right click did not respect button filters')
    assert(table.concat(presses,',')=='1,2,1,2' and table.concat(releases,',')=='1,2,1,2')
    example.save('tidy-input-parent-child',awesome._clay_tree(screen[1]))
    io.stderr:write('[PASS] real left/right clicks: original parent then child, press/release once, local2,2; wrong-button/Shift filters stay silent; lookup objects and areas agree\n')
    popup.visible=false
    runner.done()
end)
