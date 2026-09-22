-- Verify the three align modes in a flow wibar using colored widget regions.
local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local capture = require('_widget_capture')
local example = require('_clay_example')
local s = screen[1]
local bar, last, steps = nil, nil, {}
for _, mode in ipairs{'inside','outside','none'} do
    steps[#steps+1] = function()
        if bar then bar:remove() end
        local function region(color)
            return {capture.leaf_widget(40,nil,color),bg=color,widget=wibox.container.background}
        end
        bar = awful.wibar{screen=s,position='top',height=20,bg='#ffffff'}
        bar:setup{layout=wibox.layout.align.horizontal,expand=mode,
            region('#ff0000'),region('#00ff00'),region('#0000ff')}
        last=nil
        return true
    end
    steps[#steps+1] = function(n)
        local dump=awesome._clay_tree(s)
        if dump~=last or not dump:find('converted',1,true) then
            last=dump;assert(n<15,'align did not settle');return
        end
        example.pixel(20,10,'#ff0000');example.pixel(640,10,'#00ff00')
        example.pixel(1260,10,'#0000ff')
        local left=mode=='inside' and '#00ff00' or mode=='outside' and '#ff0000' or '#ffffff'
        local right=mode=='inside' and '#00ff00' or mode=='outside' and '#0000ff' or '#ffffff'
        example.pixel(100,10,left);example.pixel(1180,10,right)
        example.save('align-'..mode,dump)
        io.stderr:write('[PASS] '..mode..' colored regions agree with fit/grow intent\n')
        return true
    end
end
steps[#steps+1]=function()bar:remove();return true end
runner.run_steps(steps)
