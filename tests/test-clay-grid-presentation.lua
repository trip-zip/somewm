-- A grid presents in the frame that declares it: wrapped text, a nested grid
-- and a width change each reach their final dump and pixels in one frame.
local runner=require('_runner')
local wibox=require('wibox')
local example=require('_clay_example')
local tidy=require('_clay_tidy')
runner.run_async(function()
    local g=wibox.layout.grid();g.column_count=2;g.spacing=5
    g.expand=true
    local t=wibox.widget.textbox('aa aa aa aa aa');t.font='monospace 10';t.wrap='word'
    local inner=wibox.layout.grid();inner.column_count=2;inner.spacing=2
    inner.homogeneous=false
    inner:add(tidy.leaf(10,10,'#ff0000'),tidy.leaf(10,10,'#00ff00'))
    g:add(t,inner)
    local host=wibox{screen=screen[1],x=100,y=100,width=200,height=80,visible=true,bg='#204080',widget=g}
    local function frame(label)
        awesome._test_redeclare()
        local first=awesome._clay_tree(screen[1])
        assert(first:match('roots flow 1 floating %d+ derived 0 '),label..': derived size')
        local pixels=require('gears.surface')(root.content())
        local mutations=awesome._test_redeclare()
        assert(mutations==0,label..': the next frame changed the scene')
        local after=awesome._clay_tree(screen[1])
        local function shape(dump) return (dump:gsub('frames %d+',''):gsub('\n  commands [^\n]*','')) end
        assert(shape(first)==shape(after),label..': the next frame solved a different tree')
        local capture=require('_widget_capture')
        for y=host.y,host.y+host.height-1,7 do for x=host.x,host.x+host.width-1,7 do
            local r,gg,b=capture.read(pixels,x,y)
            local ar,ag,ab=capture.read(require('gears.surface')(root.content()),x,y)
            assert(r==ar and gg==ag and b==ab,label..': pixels changed on the next frame')
        end end
        example.save('presentation-'..label,first)
        -- Percent cells: half of 200 less the gap.
        local box
        for _,hit in ipairs(host:find_widgets(2,2)) do if hit.widget==t then box=hit end end
        assert(box and box.x==0 and box.width==98,label..': text cell')
        return first
    end
    frame('initial')
    t.text='aa aa aa aa aa aa aa aa aa aa aa aa';frame('text-grow')
    t.text='aa aa aa aa aa';frame('text-restore')
    host.width=300;awesome._test_redeclare()
    host.width=200;frame('width-restore')
    host.visible=false
    runner.done()
end)
