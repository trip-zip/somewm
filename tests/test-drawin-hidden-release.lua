-- A bar hidden and collected between a real press and its release takes no
-- release and does not crash; a later bar still takes both.
local runner=require('_runner')
local async=require('_async')
local awful=require('awful')
local wibox=require('wibox')
local clay=require('wibox.clay')
local pointer=assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

local function make_bar(s,position)
    local leaf=wibox.widget.base.make_widget()
    clay.describe_widget(leaf,function() return {w='grow',h='grow',bg={1,0,0,1}} end)
    local margin=wibox.container.margin(leaf,8,8,8,8)
    local bar=awful.wibar{screen=s,position=position,stretch=true,height=40,
        bg='#0000ff',widget=margin}
    local counts={presses=0,releases=0}
    leaf:connect_signal('button::press',function(_,x,y,button,modifiers)
        assert(x==2 and y==2 and button==1 and #modifiers==0)
        counts.presses=counts.presses+1
    end)
    leaf:connect_signal('button::release',function()
        counts.releases=counts.releases+1
    end)
    return bar,margin,leaf,counts
end

runner.run_async(function()
    local s=screen[1]
    local bar,margin,leaf,counts=make_bar(s,'bottom')
    async.sleep(0.2)
    awful.spawn{pointer,'click',tostring(bar.x+10),tostring(bar.y+10),'1280','720','left'}
    async.sleep(0.15)
    assert(counts.presses==1)
    bar.visible=false
    bar,margin,leaf=nil,nil,nil
    collectgarbage('collect')
    collectgarbage('collect')
    async.sleep(0.3)
    assert(counts.releases==0,'a release reached the hidden bar')

    local top,_,_,top_counts=make_bar(s,'top')
    async.sleep(0.2)
    awful.spawn{pointer,'click',tostring(top.x+10),tostring(top.y+10),'1280','720','left'}
    async.sleep(0.3)
    assert(top_counts.presses==1,'top bar presses: '..top_counts.presses)
    assert(top_counts.releases==1,'top bar releases: '..top_counts.releases)
    top.visible=false
    runner.done()
end)
