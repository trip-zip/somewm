-- Client slots: boxes, client-side configures, and pixels must agree.
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]
local a,b,bar,old_height
local reports = {os.tmpname(), os.tmpname()}
local function box(role, c)
    for line in awesome._clay_tree(s):gmatch('[^\n]+') do
        if line:match('^%s*'..role..' '..c.class..' ') then
            local x,y,w,h=line:match(' box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            return {x=tonumber(x),y=tonumber(y),width=tonumber(w),height=tonumber(h)},line
        end
    end
    error('missing '..role..' '..c.class)
end
local function received(c, report)
    local f=assert(io.open(report)); local text=f:read('*a'); f:close()
    local w,h=text:match('(%d+) (%d+)')
    local leaf=box('SURFACE',c)
    assert(tonumber(w)==leaf.width and tonumber(h)==leaf.height,
        'client configure '..text..' differs from solved '..leaf.width..'x'..leaf.height)
    io.stderr:write('[CONFIGURE] '..c.class..' received '..w..'x'..h..' = solved SURFACE\n')
    return leaf
end
local function pixels(c)
    local image=surface(root.content())
    local frame=box('CLIENT',c)
    local title=box('TITLEBAR',c)
    local leaf=box('SURFACE',c)
    local function rgb(x,y)
        local r,g,b=capture.read(image,x,y)
        return string.format('#%02x%02x%02x',r,g,b)
    end
    assert(rgb(frame.x,frame.y)=='#ff0000','border pixel')
    assert(rgb(title.x+math.floor(title.width/2),title.y+4)=='#00ff00','titlebar pixel')
    assert(rgb(leaf.x+math.floor(leaf.width/2),leaf.y+math.floor(leaf.height/2))=='#404040','surface pixel')
    local g=c:geometry()
    assert(g.x==frame.x and g.y==frame.y and g.width+2==frame.width and g.height+2==frame.height,
        'c:geometry differs from solved CLIENT')
end
local function eventually(fn)
    return function(count)
        local ok,err=pcall(fn)
        if ok then return true end
        assert(count<30,err)
    end
end
runner.run_steps({
    function()
        local t=s.selected_tag
        t.layout=awful.layout.suit.tile; t.master_width_factor=0.5
        t.master_count=1; t.column_count=1; t.gap=8; t.gap_single_client=false
        bar=awful.wibar{screen=s,position='top',height=28,bg='#0000ff'}
        awful.spawn{binary,'slot_a',reports[1]}
        awful.spawn{binary,'slot_b',reports[2]}
        return true
    end,
    function(count)
        a=utils.find_client_by_class('slot_a'); b=utils.find_client_by_class('slot_b')
        if not a or not b then assert(count<30,'clients did not map'); return end
        for _,c in ipairs{a,b} do
            c.floating=false; c.shadow=false; c.border_width=1; c.border_color='#ff0000'
            awful.titlebar(c,{size=24,bg_normal='#00ff00',bg_focus='#00ff00'})
        end
        if awful.client.tiled(s)[1]~=a then a:swap(b) end
        return true
    end,
    eventually(function()
        local fa=box('CLIENT',a); local fb=box('CLIENT',b)
        assert(fa.x==8 and fa.y==36 and fb.x-fa.x-fa.width==8,'uniform gaps')
        assert(s.geometry.width-fb.x-fb.width==8,'right edge gap')
        pixels(a); pixels(b)
        old_height=received(a,reports[1]).height; received(b,reports[2])
        assert(awesome._clay_tree(s):find('derived 0',1,true),'tile derived count')
        io.stderr:write('[PASS] tile slots, geometry, pixels, gaps and received configures\n')
    end),
    function() bar.height=52; return true end,
    eventually(function()
        assert(received(a,reports[1]).height==old_height-24,'bar resize did not reflow A')
        assert(received(b,reports[2]).height==old_height-24,'bar resize did not reflow B')
        pixels(a); pixels(b)
        io.stderr:write('[PASS] changing bar height reflows and configures both surfaces\n')
    end),
    function() b:kill(); return true end,
    function(count) return count >= 3 and not b.valid or nil end,
    eventually(function()
        assert(not b.valid,'B still alive')
        local frame=box('CLIENT',a)
        assert(frame.x==0 and frame.y==52 and frame.width==s.geometry.width,'single client gap disabled')
        received(a,reports[1]); pixels(a)
        io.stderr:write('[PASS] gap_single_client=false removes padding\n')
    end),
    function()
        a:kill(); bar.visible=false
        for _,path in ipairs(reports) do os.remove(path) end
        return true
    end,
},{kill_clients=false})
