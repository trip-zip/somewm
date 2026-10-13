-- Recursive signals follow every original Lua placement path after compiling.
local runner = require('_runner')
local wibox = require('wibox')
local tidy = require('_clay_tidy')
local host, shared, left, right, row
local counts = {}
runner.run_steps {
    function()
        shared=tidy.leaf(20,20,'#ff0000')
        left=wibox.container.background(shared,'#0000ff')
        right=wibox.container.margin(shared,8,8,0,0)
        row=wibox.layout.fixed.horizontal(left,right)
        for name,widget in pairs{shared=shared,left=left,right=right,row=row} do
            widget:connect_signal('tidy::ancestor',function(original,value)
                assert(original==widget and value=='payload')
                counts[name]=(counts[name] or 0)+1
            end)
        end
        host=wibox {screen=screen[1],x=100,y=100,width=200,height=40,
            visible=true,widget=row}
        return true
    end,
    function(n)
        if n<3 then return end
        assert(row:get_children()[1]==left and row:get_children()[2]==right)
        assert(left:get_children()[1]==shared and right:get_children()[1]==shared)
        shared:emit_signal_recursive('tidy::ancestor','payload')
        assert(counts.shared==2 and counts.left==1 and counts.right==1 and counts.row==2,
            string.format('recursive paths: shared=%s left=%s right=%s row=%s',
                tostring(counts.shared),tostring(counts.left),tostring(counts.right),tostring(counts.row)))
        io.stderr:write('[PASS] original child-list identity and recursive signals on both placement paths; common ancestors receive the documented per-path delivery\n')
        host.visible=false
        return true
    end,
}
