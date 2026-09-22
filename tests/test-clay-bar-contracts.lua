-- Check visibility order, frame timing and shadows.
local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local example = require('_clay_example')
local s = screen[1]
local a, b, signals, old_y = nil, nil, 0, nil
local function changed() signals = signals + 1 end
local function wait(fn)
    return function(n)
        local ok, err = pcall(fn)
        if ok then return true end
        assert(n < 30, err)
    end
end
runner.run_steps{
    function()
        require('gears.wallpaper').set('#ffffff')
        local function bar(color)
            return awful.wibar{screen=s,position='top',height=20,bg=color,
                widget=wibox.widget.textbox(''),shadow={enabled=true,radius=8,
                    offset_x=0,offset_y=8,spread=0,opacity=1,color='#ff00ff'}}
        end
        a=bar('#ff0000'); b=bar('#0000ff')
        return true
    end,
    wait(function()
        assert(a.y==0 and b.y==20 and s.workarea.y==40)
        example.pixel(100,10,'#ff0000');example.pixel(100,30,'#0000ff')
        example.pixel(100,41,'#ffffff');example.pixel(100,47,'#ffffff')
        local dump=awesome._clay_tree(s)
        assert(not dump:find('shadow',1,true),'flow wibar unexpectedly declares a shadow')
        example.save('bar-order-before',dump)
        s:connect_signal('property::workarea',changed)
    end),
    function()
        old_y=s.workarea.y; a.visible=false
        assert(s.workarea.y==old_y and signals==0,'workarea changed synchronously')
        return true
    end,
    wait(function()
        assert(b.y==0 and s.workarea.y==20 and signals>0,'hide did not settle and signal')
        example.pixel(100,10,'#0000ff');example.pixel(100,30,'#ffffff')
        local dump=awesome._clay_tree(s)
        local _,count=dump:gsub('WIBAR screen','')
        assert(count==1,'hidden bar must be absent, without a placeholder')
        example.save('bar-hidden',dump)
    end),
    function() a.visible=true;return true end,
    wait(function()
        assert(b.y==0 and a.y==20 and s.workarea.y==40,'shown bar must become innermost')
        example.pixel(100,10,'#0000ff');example.pixel(100,30,'#ff0000')
        example.save('bar-order-after',awesome._clay_tree(s))
        io.stderr:write('[PASS] visibility order and pixels; hidden bar absent; workarea signals after frame; no flow-bar shadow\n')
    end),
    function()
        s:disconnect_signal('property::workarea',changed)
        a:remove();b:remove();return true
    end,
}
