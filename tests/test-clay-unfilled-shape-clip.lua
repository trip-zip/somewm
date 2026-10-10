-- A shaped background with no fill, taller than its bar, is clipped by the
-- bar: its scene buffer takes the clipped size, like every other raster leaf.
local runner=require('_runner')
local wibox=require('wibox')
local gears=require('gears')
runner.run_async(function()
    local s=screen[1]
    local child=wibox.container.background(nil,'#ff0000')
    child.forced_width=20;child.forced_height=54
    local bar=wibox{screen=s,x=0,y=0,width=1280,height=28,visible=true,bg='#204080',
        widget=wibox.layout.fixed.horizontal(wibox.container.margin(wibox.container.background(child,nil,gears.shape.circle),4,4,4,4))}
    awesome._test_redeclare()
    local dump=awesome._clay_tree(s)
    assert(dump:find('derived 0 legacy 0',1,true),'header')
    local line=assert(dump:match('\n( *%x+ CUSTOM [^\n]*widget wibox.container.background[^\n]*)'),dump)
    io.stderr:write('[UNFILLED SHAPE] '..line..'\n')
    assert(not dump:find('[tree!=scene]',1,true),line)
    assert(line:find('box 4,4 20x54 rbox 4,4 20x24 widget wibox.container.background',1,true),line)
    assert(awesome._test_redeclare()==0)
    bar.visible=false
    runner.done()
end)
