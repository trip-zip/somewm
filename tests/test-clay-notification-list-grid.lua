-- naughty.list.notifications over a grid declares from authored values: the
-- wibox decides the grid's width, so each entry takes a third of it.
local runner=require('_runner')
local async=require('_async')
local naughty=require('naughty')
local wibox=require('wibox')
local example=require('_clay_example')
runner.run_async(function()
    local notifications={}
    for i=1,3 do
        notifications[i]=naughty.notification{title='title '..i,message='message '..i,timeout=0}
    end
    local grid=wibox.layout.grid();grid.column_count=3;grid.spacing=6
    local list=naughty.list.notifications{base_layout=grid}
    local host=wibox{screen=screen[1],x=100,y=300,width=606,height=120,visible=true,
        bg='#204080',widget=list}
    -- The list fills its layout on a delayed call.
    assert(async.wait_for_condition(function()
        awesome._test_redeclare()
        return awesome._clay_tree(screen[1]):find('"title 3"',1,true)
    end,2,.01),'the list never declared its entries')
    local dump=awesome._clay_tree(screen[1])
    assert(dump:match('roots flow 1 floating %d+ derived 0 '),'derived size')
    assert(dump:find(' w=percent(0.333333) user ',1,true),'list entries are not a third of the grid')
    for i=1,3 do assert(dump:find('"title '..i..'"',1,true),'entry '..i..' is not declared') end
    assert(awesome._test_redeclare()==0,'the next frame changed the scene')
    example.save('notification-list-grid',dump)
    host.visible=false
    for _,n in ipairs(notifications) do n:destroy() end
    runner.done()
end)
