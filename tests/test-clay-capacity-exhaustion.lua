local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local example = require('_clay_example')
local s = screen[1]

local function frame()
    return tonumber(awesome._clay_tree(s):match(' frames (%d+)'))
end

local function realized()
    return awesome._clay_tree(s):match('  realized:\n(.*)')
end

runner.run_async(function()
    local old = wibox.widget { text='retained text', forced_width=160, forced_height=40,
        widget=wibox.widget.textbox }
    local p = awful.popup { screen=s, visible=true, x=30, y=40, shadow=false, bg="#aa2211",
        widget=wibox.container.margin(old,4,4,4,4) }
    assert(async.wait_for_condition(function() return p._drawable._clay_tree ~= nil end,2,.01))
    async.sleep(.05)
    local tree = p._drawable._clay_tree
    local pixels = realized()
    example.pixel(p.x+10,p.y+p.height-2,"#aa2211")
    local width,height = p.width,p.height
    local targets = p._drawable:find_widgets(5,5)
    assert(#targets>0)
    local publications,stages=0,0
    p.drawable:connect_signal('clay::solved',function() publications=publications+1 end)
    p.drawable:connect_signal('clay::_settle',function() stages=stages+1 end)
    local before=frame()
    awesome._test_clay_failure(s,2,32768)
    p.widget=wibox.widget.calendar.year({year=2026},'monospace 11')
    assert(async.wait_for_condition(function() return frame()>before and stages>0 end,2,.01))
    async.sleep(.1)
    assert(publications==0,'an intermediate grid solve published geometry')
    assert(p._drawable._clay_tree==tree,'failed input replaced the public tree')
    assert(p.width==width and p.height==height,'failed input resized the popup')
    assert(realized()==pixels,'failed solve changed retained scene nodes')
    example.pixel(p.x+10,p.y+p.height-2,"#aa2211")
    local after=p._drawable:find_widgets(5,5)
    assert(#after==#targets and after[#after].widget==targets[#targets].widget,
        'failed replacement changed pointer targets')
    local idle=frame()
    async.sleep(.25)
    assert(frame()==idle,'capacity failure scheduled another failed frame')

    awesome._test_clay_failure(s,1,32768)
    p.widget=nil
    before=frame()
    assert(async.wait_for_condition(function() return frame()>before end,2,.01))
    assert(p._drawable._clay_tree==tree,'failed removal dropped committed Lua mappings')
    assert(realized()==pixels,'failed removal changed pixels')
    assert(p._drawable:find_widgets(5,5)[#targets].widget==old,'failed removal lost native payload')

    awesome._test_clay_failure(s,0,0)
    local replacement=wibox.widget { text='recovered',forced_width=180,forced_height=45,
        widget=wibox.widget.textbox }
    p.widget=wibox.container.margin(replacement,4,4,4,4)
    assert(async.wait_for_condition(function() return publications>0 and p.width==188 end,2,.01))
    assert(p._drawable._clay_tree~=tree)
    local recovered=p._drawable:find_widgets(5,5)
    assert(recovered[#recovered].widget==replacement,'recovery retained old input mappings')
    assert(not awesome._clay_tree(s):find('[tree!=scene]',1,true))
    local overflow = wibox.layout.overflow.vertical()
    for _ = 1, 50 do
        overflow:add(wibox.widget {forced_height=20, bg='#33aa22', widget=wibox.container.background})
    end
    local scrolling = wibox {screen=s, x=20, y=200, width=160, height=100,
        visible=true, widget=overflow}
    awesome._test_redeclare()
    overflow.scroll_factor=.5
    awesome._test_redeclare()
    local saved_scroll = {overflow._private.drawable:_clay_scroll_get(overflow._private.content.id)}
    assert(saved_scroll[2] and saved_scroll[2]<0)
    local showing = true
    s.selected_tag.layout = {name='capacity-transition', arrange=function() end,
        _clay=function()
            return {role='WORKAREA', direction='row', children=showing and {
                {role='SIDEBAR', w={fixed=240}, h='grow', transition={duration=2,
                    properties='width', enter='collapse', exit='collapse'}}} or {}}
        end}
    awful.layout.arrange(s)
    async.sleep(.1)
    local transition_dump = awesome._clay_tree(s)
    local width_now = tonumber(transition_dump:match('SIDEBAR [^\n]-box %-?%d+,%-?%d+ (%d+)x'))
    assert(width_now and width_now>0 and width_now<240, 'fixture did not start a transition')
    awesome._test_clay_failure(s,1,32768)
    awesome._test_redeclare()
    local frozen=realized()
    local frozen_frame=frame()
    async.sleep(.25)
    assert(frame()==frozen_frame and realized()==frozen, 'failed transition kept advancing')
    local failed_scroll = {overflow._private.drawable:_clay_scroll_get(overflow._private.content.id)}
    assert(failed_scroll[2]==saved_scroll[2], 'failed transition lost scrolling')
    awesome._test_clay_failure(s,0,0)
    showing=false
    awful.layout.arrange(s)
    async.sleep(.1)
    assert(not awesome._clay_tree(s):find('[tree!=scene]',1,true))
    local recovered_scroll = {overflow._private.drawable:_clay_scroll_get(overflow._private.content.id)}
    assert(recovered_scroll[2]==saved_scroll[2], 'transition recovery lost scrolling')
    scrolling.visible=false
    p.visible=false
    runner.done()
end)
