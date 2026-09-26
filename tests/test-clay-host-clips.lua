local runner = require('_runner')
local wibox = require('wibox')
local awful = require('awful')
local example = require('_clay_example')
local s = screen.primary
local hosts, scroll, scroll_host, decorated = {}, nil, nil, nil

local function make_hosts()
    for i = 1, 120 do
        local row = wibox.layout.fixed.horizontal()
        row:add(wibox.widget {bg='#ff0000', forced_width=80, forced_height=24,
            widget=wibox.container.background})
        hosts[i] = wibox {screen=s, x=10+((i-1)%12)*90, y=80+math.floor((i-1)/12)*40,
            width=40, height=24, bg='#0000ff', visible=true, widget=row}
    end
end

runner.run_steps {
    function()
        require('gears.wallpaper').set('#ffffff')
        make_hosts()
        scroll = wibox.container.scroll.horizontal(wibox.widget {
            bg='#00ff00', forced_width=300, forced_height=20,
            widget=wibox.container.background}, 20, 100, 40, false, 100)
        scroll_host = wibox {screen=s,x=10,y=520,width=100,height=20,
            visible=true,widget=scroll}
        decorated = awful.popup {screen=s,x=200,y=520,visible=true,ontop=true,
            placement=awful.placement.bottom_left,
            border_width=2,border_color='#0000ff',shadow=false,bg='#ffffff',
            -- Two pixels of border padding on each side leave 40x24 inside.
            minimum_width=44,maximum_width=44,minimum_height=28,maximum_height=28,
            widget=wibox.widget {bg='#ff0000',forced_width=80,forced_height=24,
                widget=wibox.container.background}}
        return true
    end,
    function(n)
        if n < 5 then return end
        local p = scroll._private
        local record = p.content and p.content.id and {p.drawable:_clay_scroll_get(p.content.id)} or {}
        assert(#record==6, 'scroll declared after hosts lost its native record')
        example.save('host-clips-budget',awesome._clay_tree(s))
        for _,i in ipairs{1,99,100,101,120} do
            local h=hosts[i]
            example.pixel(h.x+39,h.y+12,'#ff0000')
            example.pixel(h.x+40,h.y+12,'#ffffff')
            mouse.coords{x=h.x+41,y=h.y+12}
            mouse.coords{x=h.x+41,y=h.y+12}
            assert(mouse.object_under_pointer()~=h.drawin, 'clipped overflow accepted input')
        end
        local g=decorated:geometry()
        example.pixel(g.x+39,g.y+12,'#ff0000')
        example.pixel(g.x+40,g.y+12,'#0000ff')
        example.pixel(g.x+42,g.y+12,'#ffffff')
        for _,h in ipairs(hosts) do h.visible=false end
        hosts={}
        make_hosts()
        return true
    end,
    function(n)
        if n < 5 then return end
        local p=scroll._private
        assert(#{p.drawable:_clay_scroll_get(p.content.id)}==6,
            'replacing host identities exhausted persistent clip records')
        example.pixel(hosts[101].x+40,hosts[101].y+12,'#ffffff')
        assert(not awesome._clay_tree(s):find('[tree!=scene]',1,true))
        for _,h in ipairs(hosts) do h.visible=false end
        scroll:pause(); scroll_host.visible=false; decorated.visible=false
        io.stderr:write('[PASS] 120 hosts stay clipped, scrolling takes priority, decorated content stays inside its border, and replacement retains the desktop\n')
        return true
    end,
}
